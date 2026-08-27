#!/usr/bin/env python3
"""Focused security/backup regression tests for the 7.1 control plane."""

from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import sqlite3
from contextlib import redirect_stderr
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
                CREATE TABLE devices (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL, credential TEXT NOT NULL UNIQUE,
                  subscription_token TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1,
                  quota_bytes INTEGER NOT NULL DEFAULT 0, used_bytes INTEGER NOT NULL DEFAULT 0,
                  uploaded_bytes INTEGER NOT NULL DEFAULT 0, downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                  traffic_updated_at TEXT, expires_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
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
        assert {"totp_secret", "totp_pending_secret", "totp_enabled"} <= admin_columns
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
    print("RR-vps 7.1 security and backup tests passed")
