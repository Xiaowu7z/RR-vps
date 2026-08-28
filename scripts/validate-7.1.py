#!/usr/bin/env python3
"""Focused security/backup regression tests for the 7.1 control plane."""

from __future__ import annotations

import base64
import hashlib
import http.cookiejar
import io
import json
import sys
import tempfile
import sqlite3
import threading
import urllib.error
import urllib.request
from contextlib import redirect_stderr
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "nexus"))

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

from rr_nexus_lib.backup_crypto import decrypt, encrypt  # noqa: E402
import rr_nexus_lib.notifications as notifications_module  # noqa: E402
from rr_nexus_lib.notifications import NotificationManager  # noqa: E402
from rr_nexus_lib.security import (  # noqa: E402
    b64url_decode,
    b64url_encode,
    decode_cbor,
    totp_code,
    verify_authentication,
    verify_totp,
)


def test_totp() -> None:
    # RFC 6238 SHA-1 vector, encoded as base32.
    secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    assert totp_code(secret, 59, digits=8) == "94287082"
    current = totp_code(secret, 1_700_000_000)
    assert verify_totp(secret, current, 1_700_000_000)
    assert verify_totp(secret, current, 1_700_000_030)  # one-step drift
    assert not verify_totp(secret, "00000x", 1_700_000_000)


def test_webauthn_signature() -> None:
    challenge = b64url_encode(b"challenge-for-rr-nexus")
    origin = "https://panel.example.com"
    rp_id = "panel.example.com"
    client = json.dumps(
        {"type": "webauthn.get", "challenge": challenge, "origin": origin},
        separators=(",", ":"),
    ).encode()
    auth_data = hashlib.sha256(rp_id.encode()).digest() + bytes([0x05]) + (7).to_bytes(4, "big")
    private = ec.generate_private_key(ec.SECP256R1())
    signature = private.sign(auth_data + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256()))
    public_pem = private.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    assert verify_authentication(
        b64url_encode(client), b64url_encode(auth_data), b64url_encode(signature),
        challenge, origin, rp_id, public_pem, -7, 6,
    ) == 7
    no_uv = hashlib.sha256(rp_id.encode()).digest() + bytes([0x01]) + (8).to_bytes(4, "big")
    no_uv_signature = private.sign(no_uv + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256()))
    try:
        verify_authentication(
            b64url_encode(client), b64url_encode(no_uv), b64url_encode(no_uv_signature),
            challenge, origin, rp_id, public_pem, -7, 7,
        )
    except ValueError:
        pass
    else:
        raise AssertionError("WebAuthn assertion without user verification was accepted")
    try:
        verify_authentication(
            b64url_encode(client), b64url_encode(auth_data), b64url_encode(signature),
            challenge, "https://evil.example", rp_id, public_pem, -7, 6,
        )
    except ValueError:
        pass
    else:
        raise AssertionError("WebAuthn origin mismatch was accepted")
    try:
        decode_cbor(b"\x01\x01")
    except ValueError:
        pass
    else:
        raise AssertionError("CBOR trailing data was accepted")
    for truncated in (b"\x5f", b"\x9f", b"\xbf"):
        try:
            decode_cbor(truncated)
        except ValueError:
            pass
        else:
            raise AssertionError("truncated indefinite CBOR was accepted")
    for invalid in ("%%%", "你好"):
        try:
            b64url_decode(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid base64url was accepted")


def test_backup_aead() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source, encrypted, restored = root / "source", root / "backup.rrbak", root / "restored"
        source.write_bytes((b"RR-vps backup\x00private-key\n" * 50000) + b"stream-tail")
        password = b"correct horse battery staple"
        encrypt(source, encrypted, password)
        try:
            encrypt(source, encrypted, password)
        except FileExistsError:
            pass
        else:
            raise AssertionError("existing backup was overwritten")
        assert encrypted.read_bytes()[:7] == b"RRBAK1\x00"
        assert source.read_bytes() not in encrypted.read_bytes()
        decrypt(encrypted, restored, password)
        assert restored.read_bytes() == source.read_bytes()
        restored.unlink()
        damaged = bytearray(encrypted.read_bytes())
        damaged[-1] ^= 1
        encrypted.write_bytes(damaged)
        try:
            decrypt(encrypted, restored, password)
        except Exception:
            pass
        else:
            raise AssertionError("tampered encrypted backup was accepted")


def test_webhook_signature() -> None:
    captured: dict[str, object] = {}

    def fake_request(url: str, body: bytes, headers: dict[str, str]):
        captured.update(url=url, body=body, headers=headers)
        return True, "ok"

    original = NotificationManager._request
    NotificationManager._request = staticmethod(fake_request)
    try:
        ok, _ = NotificationManager._webhook(
            "https://hooks.example/rr", "shared-secret", {"event": "service_down"}
        )
        assert ok
        headers = captured["headers"]
        assert isinstance(headers, dict)
        assert str(headers["X-RR-Signature"]).startswith("sha256=")
    finally:
        NotificationManager._request = original

    original_https_post = notifications_module.https_post
    try:
        def failed_request(*_args, **_kwargs):
            raise OSError("https://api.telegram.org/botSECRET/sendMessage")

        notifications_module.https_post = failed_request
        ok, detail = NotificationManager._request(
            "https://api.telegram.org/botSECRET/sendMessage", b"{}", {}
        )
        assert not ok and "SECRET" not in detail
    finally:
        notifications_module.https_post = original_https_post


def test_nexus_703_schema_migration() -> None:
    import rr_nexus

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        database = root / "nexus.db"
        connection = sqlite3.connect(database)
        try:
            connection.executescript(
                """
                CREATE TABLE admins (
                  id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE,
                  password_hash TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
                CREATE TABLE sessions (
                  token_hash TEXT PRIMARY KEY,
                  admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
                  csrf_token TEXT NOT NULL, remote_ip TEXT NOT NULL,
                  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
                );
                CREATE TABLE devices (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL, credential TEXT NOT NULL UNIQUE,
                  subscription_token TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1,
                  quota_bytes INTEGER NOT NULL DEFAULT 0, used_bytes INTEGER NOT NULL DEFAULT 0,
                  uploaded_bytes INTEGER NOT NULL DEFAULT 0, downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                  traffic_updated_at TEXT, expires_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
                INSERT INTO admins(id,username,password_hash,created_at,updated_at)
                VALUES(1,'legacy-admin','legacy-hash','2026-01-01','2026-01-01');
                INSERT INTO sessions(
                  token_hash,admin_id,csrf_token,remote_ip,created_at,expires_at
                ) VALUES('legacy-session',1,'legacy-csrf','127.0.0.1',1,4102444800);
                """
            )
            connection.commit()
        finally:
            connection.close()
        config = rr_nexus.NexusConfig(
            mode="local", listen="127.0.0.1", port=7900, domain="",
            database=database, subscription_root=root / "subscriptions",
            published_subscription_root=root / "published", stats_port=39091,
            ssh_host="127.0.0.1", secure_cookie=False,
        )
        state = rr_nexus.NexusState(config)
        with state.store.connect() as connection:
            admin_columns = {row["name"] for row in connection.execute("PRAGMA table_info(admins)")}
            session_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(sessions)")
            }
            session_count = connection.execute(
                "SELECT COUNT(*) FROM sessions"
            ).fetchone()[0]
            foreign_key_errors = connection.execute(
                "PRAGMA foreign_key_check"
            ).fetchall()
            device_columns = {row["name"] for row in connection.execute("PRAGMA table_info(devices)")}
            tables = {
                row[0] for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            version = connection.execute(
                "SELECT version FROM schema_migrations WHERE version=710"
            ).fetchone()
            notification_events = json.loads(connection.execute(
                "SELECT events_json FROM notification_settings WHERE id=1"
            ).fetchone()[0])
        assert {
            "totp_secret", "totp_pending_secret", "totp_enabled", "security_version",
        } <= admin_columns
        assert "security_version" in session_columns
        assert session_count == 0
        assert foreign_key_errors == []
        assert "group_id" in device_columns
        assert {
            "device_groups", "device_templates", "system_samples", "notification_settings",
            "webauthn_credentials", "webauthn_challenges",
        } <= tables
        assert version and version[0] == 710
        assert "argo_domain_changed" in notification_events


def test_http_resource_limits() -> None:
    import rr_nexus
    import sub_server

    for server_type in (
        rr_nexus.BoundedThreadingHTTPServer,
        sub_server.BoundedThreadingHTTPServer,
    ):
        assert server_type.max_active_requests == 64
        assert server_type.request_timeout_seconds == 15
        assert server_type.daemon_threads is True
        assert server_type.request_queue_size == 64


def test_remote_input_bounds() -> None:
    import base64
    import rr_nexus

    assert rr_nexus.bounded_remote_number("9" * 100000, 500, integer=True) == 0
    assert rr_nexus.bounded_remote_number("125.5", 100) == 100
    assert rr_nexus.bounded_remote_number(float("nan"), 100) == 0
    payload = {"v": 1, "a": "panel.example.com", "p": 443, "t": "a" * 64}
    encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()
    assert rr_nexus.remote_cred_parse(f"rrmgr1.{encoded}.signature")["p"] == 443
    payload["a"] = "127.0.0.1:443"
    encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()
    assert rr_nexus.remote_cred_parse(f"rrmgr1.{encoded}.signature") is None
    assert rr_nexus.remote_cred_parse("x" * 5000) is None


def test_history_retention() -> None:
    import rr_nexus

    with tempfile.TemporaryDirectory() as directory:
        state = rr_nexus.NexusState(rr_nexus.NexusConfig(
            mode="local", listen="127.0.0.1", port=7900, domain="",
            database=Path(directory) / "nexus.db",
            subscription_root=Path(directory) / "subscriptions",
            published_subscription_root=Path(directory) / "published",
            stats_port=39091, ssh_host="127.0.0.1", secure_cookie=False,
        ))
        with state.store.connect() as connection:
            connection.execute(
                "INSERT INTO audit_log(created_at,actor,action,target,remote_ip,detail) "
                "VALUES('2000-01-01T00:00:00+00:00','test','old','x','local','')"
            )
            connection.execute(
                "INSERT INTO notification_log(created_at,event,severity,title,detail,delivered) "
                "VALUES('2000-01-01T00:00:00+00:00','old','info','old','',0)"
            )
        state.store.prune_history(force=True)
        with state.store.connect() as connection:
            assert connection.execute("SELECT COUNT(*) FROM audit_log").fetchone()[0] == 0
            assert connection.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0] == 0


def test_request_log_redaction() -> None:
    import rr_nexus
    import sub_server

    secret_path = "/sub/dev_012345abcdef/secret-subscription-token/txt"
    for handler_type in (rr_nexus.Handler, sub_server.SubscriptionHandler):
        handler = object.__new__(handler_type)
        handler.client_address = ("203.0.113.10", 12345)
        output = io.StringIO()
        with redirect_stderr(output):
            handler.log_message('"%s" %s %s', f"GET {secret_path} HTTP/1.1", "404", "0")
        assert "secret-subscription-token" not in output.getvalue()
        if handler_type is rr_nexus.Handler:
            assert "HTTP 404" in output.getvalue()


def test_session_transport_isolation() -> None:
    """Both local and public sessions stay explicit to the browser origin."""
    import rr_nexus

    observed: dict[str, str] = {}

    class OtherLocalService(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            observed["cookie"] = self.headers.get("Cookie", "")
            observed["authorization"] = self.headers.get("Authorization", "")
            observed["path"] = self.path
            self.send_response(204)
            self.end_headers()

        def log_message(self, _format: str, *_args: object) -> None:
            pass

    def request_json(
        opener: urllib.request.OpenerDirector,
        url: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, object, dict[str, object]]:
        body = json.dumps(payload).encode() if payload is not None else None
        request_headers = dict(headers or {})
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            url, data=body, headers=request_headers, method=method
        )
        try:
            response = opener.open(request, timeout=10)
        except urllib.error.HTTPError as exc:
            response = exc
        raw = response.read()
        data = json.loads(raw) if raw else {}
        return int(response.status), response.headers, data

    original_state = getattr(rr_nexus, "STATE", None)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = rr_nexus.NexusConfig(
            mode="local", listen="127.0.0.1", port=7900, domain="",
            database=root / "nexus.db",
            subscription_root=root / "subscriptions",
            published_subscription_root=root / "published",
            stats_port=39091, ssh_host="127.0.0.1", secure_cookie=False,
        )
        state = rr_nexus.NexusState(config)
        password = "local tunnel password"
        now = rr_nexus.utc_now()
        with state.store.connect() as connection:
            admin_id = int(connection.execute(
                "INSERT INTO admins(username,password_hash,created_at,updated_at) VALUES(?,?,?,?)",
                ("admin", state.password_hasher.hash(password), now, now),
            ).lastrowid)
            legacy_token = "A" * 48
            old_public_token = "public." + "B" * 48
            epoch = rr_nexus.epoch_now()
            connection.execute(
                "INSERT INTO sessions(token_hash,admin_id,csrf_token,remote_ip,created_at,expires_at) "
                "VALUES(?,?,?,?,?,?)",
                (rr_nexus.sha256_text(legacy_token), admin_id, "legacy-csrf", "127.0.0.1", epoch, epoch + 3600),
            )
            connection.execute(
                "INSERT INTO sessions(token_hash,admin_id,csrf_token,remote_ip,created_at,expires_at) "
                "VALUES(?,?,?,?,?,?)",
                (
                    rr_nexus.sha256_text(old_public_token),
                    admin_id,
                    "old-public-csrf",
                    "127.0.0.1",
                    epoch,
                    epoch + 3600,
                ),
            )

        rr_nexus.STATE = state
        panel = rr_nexus.BoundedThreadingHTTPServer(("127.0.0.1", 0), rr_nexus.Handler)
        other = ThreadingHTTPServer(("127.0.0.1", 0), OtherLocalService)
        panel_thread = threading.Thread(target=panel.serve_forever, daemon=True)
        other_thread = threading.Thread(target=other.serve_forever, daemon=True)
        panel_thread.start()
        other_thread.start()
        panel_url = f"http://127.0.0.1:{panel.server_port}"
        other_url = f"http://127.0.0.1:{other.server_port}"
        assert panel.server_port != other.server_port

        # Model the browser rule behind the bug: a host-only cookie has no port
        # scope and is therefore attached to another 127.0.0.1 origin.
        model_jar = http.cookiejar.CookieJar()
        model_jar.set_cookie(http.cookiejar.Cookie(
            version=0, name="ambient_model", value="yes",
            port=None, port_specified=False,
            domain="127.0.0.1", domain_specified=False, domain_initial_dot=False,
            path="/", path_specified=True, secure=False, expires=None,
            discard=True, comment=None, comment_url=None, rest={}, rfc2109=False,
        ))
        model_opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(model_jar)
        )
        model_opener.open(other_url + "/cookie-model", timeout=10).read()
        assert observed["cookie"] == "ambient_model=yes"
        observed.clear()

        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        try:
            status, _, legacy_session = request_json(
                opener,
                panel_url + "/api/session",
                headers={"Authorization": f"Bearer {legacy_token}"},
            )
            assert status == 200 and not legacy_session["authenticated"]

            status, headers, login = request_json(
                opener,
                panel_url + "/api/login",
                method="POST",
                payload={"username": "admin", "password": password},
            )
            assert status == 200
            assert headers.get_all("Set-Cookie") is None
            token = str(login.get("token", ""))
            assert rr_nexus.SESSION_TOKEN_RE.fullmatch(token)

            # A browser cookie jar has nothing to attach to another localhost
            # port, and Authorization is explicit rather than ambient.
            opener.open(other_url + "/capture", timeout=10).read()
            assert observed == {"cookie": "", "authorization": "", "path": "/capture"}
            assert token not in observed["path"]

            # Even an injected legacy/new cookie cannot authenticate local
            # mode.  Only the bearer selected by this origin's JS succeeds.
            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers={
                    "Cookie": (
                        f"rr_nexus_session={token}; "
                        f"{rr_nexus.SESSION_COOKIE_NAME}={token}"
                    )
                },
            )
            assert status == 200 and not session["authenticated"]
            bearer = {"Authorization": f"Bearer {token}"}
            status, _, session = request_json(
                opener, panel_url + "/api/session", headers=bearer
            )
            assert status == 200 and session["authenticated"]
            csrf = str(session["csrf"])
            status, _, remote_servers = request_json(
                opener, panel_url + "/api/remote-servers", headers=bearer
            )
            assert status == 200 and remote_servers["servers"] == []

            # A new primary sends both selectors: new secondaries prefer the
            # exact short index, while old secondaries safely fall back to the
            # generic subscription selector instead of node index zero.
            with state.store.connect() as connection:
                cursor = connection.execute(
                    "INSERT INTO remote_servers(name,cred,addr,port,created_at) VALUES(?,?,?,?,?)",
                    ("old-peer", "test-credential", "203.0.113.10", 443, now),
                )
                remote_id = int(cursor.lastrowid)
            forwarded: dict[str, object] = {}
            remote_handler = object.__new__(rr_nexus.Handler)

            def fake_remote_call(
                _addr: str, _port: int, _cred: str, _method: str,
                _path: str, body: dict[str, str], **_kwargs: object,
            ) -> tuple[int, dict[str, str]]:
                forwarded.update(body)
                return 200, {"png_b64": base64.b64encode(b"PNG").decode()}

            remote_handler.remote_http_call = fake_remote_call
            remote_handler.send_bytes = lambda *_args, **_kwargs: None
            remote_handler.send_json = lambda *_args, **_kwargs: None
            remote_handler.handle_remote_qr({
                "server_id": [str(remote_id)],
                "device_id": ["dev_012345abcdef"],
                "sub_index": ["2"],
            })
            assert forwarded == {"sub_index": "2", "sub": "1"}

            qr_path = root / "qr-links.txt"
            qr_path.write_text("vless://node-zero\n", encoding="utf-8")
            qr_handler = object.__new__(rr_nexus.Handler)
            qr_handler.device_record = lambda _device_id: {"id": "dev_012345abcdef"}
            qr_handler.subscription_file = lambda _device_id: qr_path
            qr_handler._device_subscription_urls = lambda _device: (
                "https://panel.example/sub/generic",
                [
                    {"url": "https://panel.example/sub/format-zero"},
                    {"url": "https://panel.example/sub/format-one"},
                    {"url": "https://panel.example/sub/format-two"},
                ],
            )
            encoded_link: dict[str, str] = {}

            class QRResult:
                returncode = 0
                stdout = b"\x89PNG\r\n\x1a\nmock"

            original_run = rr_nexus.subprocess.run
            try:
                def fake_qrencode(argv: list[str], **_kwargs: object) -> QRResult:
                    encoded_link["value"] = argv[-1]
                    return QRResult()

                rr_nexus.subprocess.run = fake_qrencode
                qr_status, _ = qr_handler._qr_png_bytes(
                    "dev_012345abcdef",
                    {"sub_index": ["2"], "sub": ["1"]},
                )
                assert encoded_link["value"].endswith("/format-two")
                browser_raw_status, _ = qr_handler._qr_png_bytes(
                    "dev_012345abcdef",
                    {"raw": ["https://panel.example/sub/format-one"]},
                )
                qr_handler._remote_session = {"remote": True}
                old_primary_status, _ = qr_handler._qr_png_bytes(
                    "dev_012345abcdef",
                    {"raw": ["https://panel.example/sub/format-one"]},
                )
            finally:
                rr_nexus.subprocess.run = original_run
            assert qr_status == 200
            assert browser_raw_status == 400
            assert old_primary_status == 200
            assert encoded_link["value"].endswith("/format-one")
            with state.store.connect() as connection:
                connection.execute("DELETE FROM remote_servers WHERE id=?", (remote_id,))

            # Refresh and CSRF behavior remain intact with the bearer.
            status, _, refreshed = request_json(
                opener, panel_url + "/api/session", headers=bearer
            )
            assert status == 200 and refreshed["authenticated"]
            status, _, rejected = request_json(
                opener,
                panel_url + "/api/logout",
                method="POST",
                headers={**bearer, "X-CSRF-Token": "wrong"},
            )
            assert status == 403 and rejected["error"] == "invalid_csrf_token"
            status, headers, logged_out = request_json(
                opener,
                panel_url + "/api/logout",
                method="POST",
                headers={**bearer, "X-CSRF-Token": csrf},
            )
            assert status == 200 and logged_out["ok"]
            assert headers.get_all("Set-Cookie") is None
            status, _, session = request_json(
                opener, panel_url + "/api/session", headers=bearer
            )
            assert status == 200 and not session["authenticated"]

            # Public mode uses the same origin-explicit bearer transport.  A
            # new prefix makes pre-migration cookie sessions unusable even if
            # an attacker copies one into an Authorization header.
            state.config = replace(
                config,
                mode="public",
                domain="panel.example.com",
                secure_cookie=True,
            )
            status, headers, public_login = request_json(
                opener,
                panel_url + "/api/login",
                method="POST",
                payload={"username": "admin", "password": password},
            )
            assert status == 200
            public_token = str(public_login.get("token", ""))
            assert rr_nexus.SESSION_TOKEN_RE.fullmatch(public_token)
            assert public_token.startswith(rr_nexus.SESSION_TOKEN_PREFIX["public"])
            assert not public_token.startswith("public.")
            cleared = headers.get("Set-Cookie", "")
            assert cleared.startswith(rr_nexus.SESSION_COOKIE_NAME + "=;")
            assert "; Secure" in cleared and "; HttpOnly" in cleared
            assert "SameSite=Strict" in cleared and "Max-Age=0" in cleared
            assert "Domain=" not in cleared

            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers={"Authorization": f"Bearer {old_public_token}"},
            )
            assert status == 200 and not session["authenticated"]
            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers={"Cookie": f"{rr_nexus.SESSION_COOKIE_NAME}={public_token}"},
            )
            assert status == 200 and not session["authenticated"]
            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers={"Cookie": f"rr_nexus_session={public_token}"},
            )
            assert status == 200 and not session["authenticated"]
            public_bearer = {"Authorization": f"Bearer {public_token}"}
            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers=public_bearer,
            )
            assert status == 200 and session["authenticated"]
            status, _, remote_servers = request_json(
                opener,
                panel_url + "/api/remote-servers",
                headers=public_bearer,
            )
            assert status == 200 and remote_servers["servers"] == []
            status, headers, logged_out = request_json(
                opener,
                panel_url + "/api/logout",
                method="POST",
                headers={
                    **public_bearer,
                    "X-CSRF-Token": str(session["csrf"]),
                },
            )
            assert status == 200 and logged_out["ok"]
            cleared = headers.get("Set-Cookie", "")
            assert cleared.startswith(rr_nexus.SESSION_COOKIE_NAME + "=;")
            assert "; Secure" in cleared and "; HttpOnly" in cleared and "Max-Age=0" in cleared
            status, _, session = request_json(
                opener,
                panel_url + "/api/session",
                headers=public_bearer,
            )
            assert status == 200 and not session["authenticated"]

            app_source = (ROOT / "nexus/static/app.js").read_text(encoding="utf-8")
            assert "sessionStorage.setItem(LOCAL_SESSION_KEY" in app_source
            assert "localStorage.setItem(LOCAL_SESSION_KEY" not in app_source
            assert "requestUrl.origin === window.location.origin" in app_source
            assert "headers.Authorization = `Bearer ${requestToken}`" in app_source
            assert "requestEpoch === state.authEpoch" in app_source
            assert "popup.sessionStorage.removeItem(LOCAL_SESSION_KEY)" in app_source
            assert 'if (state.mode !== "local") setSessionToken("");' not in app_source
            assert "function completeSecurityChange(message)" in app_source
            assert '$$("dialog[open]").forEach(dialog => dialog.close())' in app_source
            assert "linksDialogGeneration" in app_source
            admin_source = (ROOT / "nexus/static/admin.js").read_text(encoding="utf-8")
            assert 'releaseAuthenticatedImage($("#totp-qr"))' in admin_source
            assert "totpSetupGeneration" in admin_source
            assert admin_source.count("completeSecurityChange(") >= 4
        finally:
            panel.shutdown()
            other.shutdown()
            panel.server_close()
            other.server_close()
            panel_thread.join(timeout=5)
            other_thread.join(timeout=5)
            if original_state is not None:
                rr_nexus.STATE = original_state
            else:
                del rr_nexus.STATE


if __name__ == "__main__":
    test_totp()
    test_webauthn_signature()
    test_backup_aead()
    test_webhook_signature()
    test_nexus_703_schema_migration()
    test_http_resource_limits()
    test_remote_input_bounds()
    test_history_retention()
    test_request_log_redaction()
    test_session_transport_isolation()
    print("RR-vps 7.1 security and backup tests passed")
