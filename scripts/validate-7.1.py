#!/usr/bin/env python3
"""Focused security/backup regression tests for the 7.1 control plane."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import sqlite3
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "nexus"))

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

from rr_nexus_lib.backup_crypto import decrypt, encrypt  # noqa: E402
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

    original_urlopen = urllib.request.urlopen
    try:
        def failed_request(*_args, **_kwargs):
            raise urllib.error.URLError("https://api.telegram.org/botSECRET/sendMessage")

        urllib.request.urlopen = failed_request
        ok, detail = NotificationManager._request(
            "https://api.telegram.org/botSECRET/sendMessage", b"{}", {}
        )
        assert not ok and "SECRET" not in detail
    finally:
        urllib.request.urlopen = original_urlopen


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


if __name__ == "__main__":
    test_totp()
    test_webauthn_signature()
    test_backup_aead()
    test_webhook_signature()
    test_nexus_703_schema_migration()
    print("RR-vps 7.1 security and backup tests passed")
