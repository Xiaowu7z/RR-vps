#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
from __future__ import annotations

import base64
import concurrent.futures
import io
import json
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import rr_nexus


class RemoteAddConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = rr_nexus.Store(Path(self.directory.name) / "nexus.db")
        if hasattr(rr_nexus, "STATE"):
            self.addCleanup(setattr, rr_nexus, "STATE", rr_nexus.STATE)
        else:
            self.addCleanup(delattr, rr_nexus, "STATE")
        rr_nexus.STATE = SimpleNamespace(
            store=self.store, config=SimpleNamespace(mode="local")
        )

    @staticmethod
    def credential(address, port=443):
        payload = {"v": 1, "a": address, "p": port, "t": "a" * 64,
                   "n": "cross-test", "i": 1_800_000_000}
        encoded = base64.urlsafe_b64encode(rr_nexus.json_compact(payload))
        # The actual parser runs on these bytes. Only the remote TLS probe,
        # including the peer's HMAC decision, is replaced in this test.
        return "rrmgr1." + encoded.rstrip(b"=").decode("ascii") + "." + "A" * 43

    def add(self, address, port=443):
        body = rr_nexus.json_compact({
            "name": "cross-test", "cred": self.credential(address, port)
        })
        handler = object.__new__(rr_nexus.Handler)
        handler.client_address = ("127.0.0.1", 54321)
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler.wfile = io.BytesIO()
        handler.request_version = "HTTP/1.1"
        handler.requestline = "POST /api/remote-servers HTTP/1.1"
        handler.command = "POST"
        # Execute the production handler, JSON reader, response writer,
        # credential parser, Store connections, and audit implementation.
        handler.handle_remote_servers_add({"username": "cross_admin"})
        headers, payload = handler.wfile.getvalue().split(b"\r\n\r\n", 1)
        return int(headers.splitlines()[0].split()[1]), json.loads(payload)

    def rows(self):
        with self.store.connect() as connection:
            return [dict(row) for row in connection.execute(
                "SELECT id,addr,port FROM remote_servers ORDER BY id"
            )]

    def audit_count(self):
        with self.store.connect() as connection:
            return connection.execute(
                "SELECT COUNT(*) FROM audit_log WHERE action='remote_server_add'"
            ).fetchone()[0]

    def run_parallel(self, endpoints):
        barrier = threading.Barrier(len(endpoints))

        def probe(address, port, credential, method, path, body):
            parsed = rr_nexus.remote_cred_parse(credential)
            self.assertEqual((parsed["a"], parsed["p"]), (address, port))
            self.assertEqual((method, path, body), ("GET", "/api/overview", None))
            # Every contender has passed the initial SELECT before any probe
            # returns. This deterministically exercises the stale preflight.
            barrier.wait(timeout=10)
            return 200, {"devices": {"total": 0}}

        with patch.object(rr_nexus.Handler, "remote_http_call", staticmethod(probe)):
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=len(endpoints)
            ) as executor:
                futures = [executor.submit(self.add, *item) for item in endpoints]
                return [future.result(timeout=30) for future in futures]

    def test_same_target_reserves_one_row_and_reports_the_winner(self):
        results = self.run_parallel([("duplicate.example.test", 443)] * 8)
        self.assertEqual([status for status, _ in results].count(200), 1)
        self.assertEqual([status for status, _ in results].count(409), 7)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(self.audit_count(), 1)
        for status, body in results:
            if status == 409:
                self.assertEqual(body["error"], "already_exists")
                self.assertEqual(body["server_id"], rows[0]["id"])

    def test_address_and_port_both_identify_a_target(self):
        endpoints = [("one.example.test", 443), ("one.example.test", 8443),
                     ("two.example.test", 443)]
        results = self.run_parallel(endpoints)
        self.assertTrue(all(status == 200 for status, _ in results), results)
        self.assertEqual({(row["addr"], row["port"]) for row in self.rows()},
                         set(endpoints))

    def test_valid_long_domain_is_not_truncated_or_duplicated(self):
        address = ".".join(["a" * 60, "b" * 60, "c" * 30, "test"])
        self.assertGreater(len(address), 128)
        results = self.run_parallel([(address, 443)] * 4)
        self.assertEqual([status for status, _ in results].count(200), 1)
        self.assertEqual([status for status, _ in results].count(409), 3)
        self.assertEqual([row["addr"] for row in self.rows()], [address])

    def test_last_capacity_slot_is_not_oversubscribed(self):
        limit = rr_nexus.REMOTE_MAX_SERVERS
        with self.store.connect() as connection:
            connection.executemany(
                "INSERT INTO remote_servers(name,cred,addr,port,created_at) "
                "VALUES(?,?,?,?,?)",
                [("existing", "existing-key", f"existing-{i}.example.test", 443,
                  "2026-09-08T00:00:00+00:00") for i in range(limit - 1)],
            )
        results = self.run_parallel([
            (f"contender-{i}.example.test", 443) for i in range(8)
        ])
        self.assertEqual([status for status, _ in results].count(200), 1)
        rejected = [(status, body) for status, body in results if status != 200]
        self.assertEqual(len(rejected), 7)
        self.assertTrue(all(status == 400 and body["error"] == "limit_reached"
                            for status, body in rejected), rejected)
        self.assertEqual(len(self.rows()), limit)
        self.assertEqual(self.audit_count(), 1)
        def unexpected_probe(*args):
            self.fail("an already full inventory must reject before TLS")
        with patch.object(rr_nexus.Handler, "remote_http_call",
                          staticmethod(unexpected_probe)):
            status, body = self.add("beyond-capacity.example.test")
            self.assertEqual((status, body["error"]), (400, "limit_reached"))
            status, body = self.add("existing-0.example.test")
            self.assertEqual((status, body["error"]), (409, "already_exists"))

    def test_failed_probe_leaves_no_reservation_and_can_be_retried(self):
        for result in [(0, {"error": "unreachable"}),
                       (403, {"error": "invalid_remote_cred"})]:
            with patch.object(rr_nexus.Handler, "remote_http_call",
                              staticmethod(lambda *args: result)):
                status, body = self.add("retry.example.test")
            self.assertEqual((status, body["error"]), (400, "cred_rejected"))
            self.assertEqual(self.rows(), [])
            self.assertEqual(self.audit_count(), 0)
        with patch.object(rr_nexus.Handler, "remote_http_call",
                          staticmethod(lambda *args: (200, {}))):
            self.assertEqual(self.add("retry.example.test")[0], 200)
        self.assertEqual(len(self.rows()), 1)

    def test_network_probe_does_not_hold_a_database_writer_lock(self):
        def probe(*args):
            # A separate real connection must be able to write while the
            # endpoint is waiting on its remote peer; no TLS wait may retain
            # the database writer reservation.
            connection = sqlite3.connect(self.store.path, timeout=0)
            try:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute(
                    "UPDATE notification_settings SET enabled=enabled WHERE id=1"
                )
                connection.rollback()
            finally:
                connection.close()
            return 200, {}

        with patch.object(rr_nexus.Handler, "remote_http_call", staticmethod(probe)):
            self.assertEqual(self.add("unlocked.example.test")[0], 200)


unittest.main(verbosity=2)
PY
