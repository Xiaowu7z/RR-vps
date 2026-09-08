#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import rr_nexus


class NumericQueryBoundaryTests(unittest.TestCase):
    def enter_context(self, context):
        result = context.__enter__()
        self.addCleanup(context.__exit__, None, None, None)
        return result

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.store = rr_nexus.Store(Path(temporary.name) / "nexus.db")
        self.traffic = SimpleNamespace(
            collect_server_traffic=Mock(), status_snapshot=lambda: {"available": False}
        )
        state = SimpleNamespace(store=self.store, config=SimpleNamespace(mode="local"),
                                traffic=self.traffic)
        self.enter_context(patch.object(rr_nexus, "STATE", state, create=True))
        self.enter_context(patch.object(rr_nexus, "network_interfaces", return_value=[]))
        self.enter_context(patch.object(rr_nexus.Handler, "_deferred_sync"))
        self.enter_context(patch.object(rr_nexus.Handler, "log_request"))
        self.key = b"boundary-test-key" * 2
        # Keep the production parser, HMAC comparison, failure reservations,
        # remote dispatcher, JSON readers/writers, and SQLite Store. Only key
        # storage is isolated from /var/lib and the root-only security lock.
        self.enter_context(patch.object(rr_nexus, "remote_key_load_or_create",
                                       return_value=self.key))
        payload = {"v": 1, "a": "boundary.example.test", "p": 443,
                   "t": "a" * 64, "n": "boundary", "i": 1800000000}
        encoded = base64.urlsafe_b64encode(rr_nexus.json_compact(payload)).rstrip(b"=")
        signed = b"rrmgr1." + encoded
        signature = hmac.new(self.key, signed, hashlib.sha256).digest()
        self.credential = (signed + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode()
        self.device_id = "dev_0123456789ab"
        with self.store.connect() as db:
            db.execute(
                "INSERT INTO devices(id,name,credential,subscription_token,quota_bytes,"
                "used_bytes,uploaded_bytes,downloaded_bytes,created_at,updated_at) "
                "VALUES(?,?,?,?,?,?,?,?,?,?)",
                (self.device_id, "existing", "test-uuid", "test-token", 1000,
                 50, 20, 30, rr_nexus.utc_now(), rr_nexus.utc_now()),
            )
            db.execute(
                "INSERT INTO device_templates(name,quota_bytes,created_at,updated_at) "
                "VALUES(?,?,?,?)", ("existing", 1000, rr_nexus.utc_now(), rr_nexus.utc_now())
            )

    @staticmethod
    def handler(body, path="/api/remote/call"):
        raw = rr_nexus.json_compact(body)
        handler = object.__new__(rr_nexus.Handler)
        handler.client_address = ("127.0.0.1", 54321)
        handler.headers = {"Content-Length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        handler.wfile = io.BytesIO()
        handler.request_version = "HTTP/1.1"
        handler.requestline = f"POST {path} HTTP/1.1"
        handler.command = "POST"
        handler.path = path
        return handler

    @staticmethod
    def response(handler):
        headers, body = handler.wfile.getvalue().split(b"\r\n\r\n", 1)
        return int(headers.splitlines()[0].split()[1]), json.loads(body)

    def remote(self, method, path, body=None, credential=None):
        handler = self.handler({"cred": self.credential if credential is None else credential,
                                "method": method, "path": path, "body": body or {}})
        handler.handle_remote_call()
        return self.response(handler)

    def local(self, handler_name, body, *args):
        handler = self.handler(body)
        getattr(handler, handler_name)({"username": "boundary_admin"}, *args)
        return self.response(handler)

    def data_snapshot(self):
        with self.store.connect() as db:
            return {table: [tuple(row) for row in db.execute(f"SELECT * FROM {table}")]
                    for table in ("devices", "device_templates", "server_traffic_policy")}

    def quota_routes(self):
        return [
            ("POST", "/api/devices", "handle_create_device", (), "quota_gb", "invalid_quota"),
            ("PATCH", f"/api/devices/{self.device_id}", "handle_update_device",
             (self.device_id,), "quota_gb", "invalid_quota"),
            ("POST", f"/api/devices/{self.device_id}/reset", "handle_reset_device",
             (self.device_id,), "quota_gb", "invalid_quota"),
            ("POST", "/api/device-templates", "handle_device_template_create", (),
             "quota_gb", "invalid_template_value"),
            ("PATCH", "/api/device-templates/1", "handle_device_template_update", (1,),
             "quota_gb", "invalid_template_value"),
            ("PATCH", "/api/server/traffic-policy", "handle_update_server_traffic_policy", (),
             "quota_gb", "invalid_server_quota"),
            ("PATCH", "/api/server/traffic-policy", "handle_update_server_traffic_policy", (),
             "current_used_gb", "invalid_current_usage"),
            ("POST", "/api/server/traffic-policy/reset", "handle_reset_server_traffic_policy", (),
             "initial_used_gb", "invalid_initial_usage"),
        ]

    def test_invalid_numbers_return_400_locally_and_remotely_without_data_changes(self):
        before = self.data_snapshot()
        for method, path, handler_name, args, field, error in self.quota_routes():
            for value in (float("nan"), float("inf"), float("-inf"),
                          "NaN", "Infinity", "-Infinity", "1e309", 10 ** 400):
                body = {"name": "boundary", field: value}
                with self.subTest(path=path, field=field, value_type=type(value).__name__):
                    self.assertEqual(self.local(handler_name, body, *args),
                                     (400, {"error": error}))
                    self.assertEqual(self.remote(method, path, body), (400, {"error": error}))
                    self.assertEqual(self.data_snapshot(), before)
        self.traffic.collect_server_traffic.assert_not_called()

    def test_template_integer_fields_reject_non_finite_inputs(self):
        for field in ("expiry_days", "reset_max"):
            for value in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(field=field, value=value):
                    self.assertEqual(
                        self.local("handle_device_template_create", {"name": "boundary", field: value}),
                        (400, {"error": "invalid_template_value"}),
                    )

    def test_finite_quota_boundaries_and_fractional_usage_still_work(self):
        validator = self.handler({})
        for value in (0, 0.125, 10240):
            with self.subTest(quota=value):
                values, error = validator.validate_device_payload({"name": "boundary", "quota_gb": value})
                self.assertEqual(error, "")
                self.assertEqual(values["quota_bytes"], int(value * 1024**3))
                status, body = self.local("handle_reset_device", {"quota_gb": value}, self.device_id)
                self.assertEqual((status, body["ok"]), (200, True))
        status, body = self.local("handle_update_server_traffic_policy",
                                  {"quota_gb": 0.125, "current_used_gb": 0.0625})
        self.assertEqual(status, 200)
        self.assertEqual(body["policy"]["quota_bytes"], 134217728)
        self.assertEqual(body["policy"]["initial_used_bytes"], 67108864)
        self.assertEqual(self.local("handle_reset_server_traffic_policy", {"initial_used_gb": 0})[0], 200)
        self.assertEqual(self.local("handle_device_template_create", {"name": "fractional", "quota_gb": 0.125})[0], 201)

    def test_history_query_uses_the_same_real_sqlite_windows_as_local_routes(self):
        now = 1800000000
        self.enter_context(patch.object(rr_nexus, "epoch_now", return_value=now))
        with self.store.connect() as db:
            for age in (0, 2, 10, 40):
                bucket = now - age * 86400
                db.execute("INSERT INTO traffic_samples(bucket,uploaded_bytes,downloaded_bytes) VALUES(?,?,?)",
                           (bucket, 11, 22))
                db.execute("INSERT INTO system_samples(bucket,cpu_percent,memory_percent,disk_percent,load1) VALUES(?,?,?,?,?)",
                           (bucket, 1.0, 2.0, 3.0, 0.5))
        for endpoint in ("traffic", "metrics"):
            for suffix, window, count in (("", "24h", 1), ("?range=7d", "7d", 2),
                                          ("?range=30d", "30d", 3), ("?range=%37d", "7d", 2),
                                          ("?range=invalid", "24h", 1)):
                path = f"/api/{endpoint}{suffix}"
                with self.subTest(path=path):
                    local = self.handler({}, path)
                    _, _, query = local.parse_path()
                    getattr(local, f"handle_{endpoint}")(query)
                    expected = self.response(local)
                    actual = self.remote("GET", path)
                    self.assertEqual(actual, expected)
                    self.assertEqual(actual[0], 200)
                    self.assertEqual(actual[1]["range"], window)
                    self.assertEqual(len(actual[1]["samples"]), count)
                    with self.store.connect() as db:
                        audit = db.execute("SELECT target FROM audit_log WHERE action='remote_call' ORDER BY id DESC LIMIT 1").fetchone()
                    self.assertEqual(audit["target"], f"GET {path}")

    def test_history_queries_require_the_original_credential_verification(self):
        prefix, signature = self.credential.rsplit(".", 1)
        tampered = prefix + "." + ("A" if signature[0] != "A" else "B") + signature[1:]
        status, body = self.remote("GET", "/api/traffic?range=7d", credential=tampered)
        self.assertEqual((status, body["error"]), (403, "invalid_remote_cred"))
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM remote_failures").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM audit_log WHERE action='remote_call'").fetchone()[0], 0)

    def test_queries_do_not_bypass_the_remote_route_allowlist(self):
        self.assertEqual(self.remote("GET", "/api/security?range=7d"),
                         (404, {"error": "remote_unsupported"}))


unittest.main(verbosity=2)
PY
