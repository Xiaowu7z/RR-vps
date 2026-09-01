#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus" python3 - <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import types
from pathlib import Path
from types import SimpleNamespace


try:
    import argon2  # noqa: F401
except ImportError:
    argon2_module = types.ModuleType("argon2")
    argon2_exceptions = types.ModuleType("argon2.exceptions")

    class PasswordHasher:
        def __init__(self, *args, **kwargs):
            pass

    class InvalidHash(Exception):
        pass

    class VerifyMismatchError(Exception):
        pass

    argon2_module.PasswordHasher = PasswordHasher
    argon2_exceptions.InvalidHash = InvalidHash
    argon2_exceptions.VerifyMismatchError = VerifyMismatchError
    sys.modules["argon2"] = argon2_module
    sys.modules["argon2.exceptions"] = argon2_exceptions

import rr_nexus


DEVICE_ID = "dev_0123456789ab"
TOKEN = "secret-token-never-log"
IPV4 = "8.8.8.8"
IPV6 = "2606:4700:4700::1111"
SPECS = [
    ("Sing-box 官方", "json", ".json"),
    ("mihomo", "mihomo", "-mihomo.yaml"),
    ("Clash Verge", "clash-verge", "-clash-verge.yaml"),
    ("FlClash", "flclash", "-flclash.yaml"),
    ("v2rayN", "v2rayn", "-v2rayn.txt"),
    ("v2rayNG", "v2rayng", "-v2rayng.txt"),
    ("Shadowrocket", "sr", "-sr.txt"),
    ("NekoBox", "nekobox", "-nekobox.txt"),
    ("通用链接", "txt", ".txt"),
]


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    config_path = root / "nexus.json"
    subscription_root = root / "subscriptions"
    published_root = root / "published"
    cert = root / "ip.crt"
    key = root / "ip.key"
    pending = root / ".ip-cert-pending"
    ca_bundle = root / "system-ca.pem"
    subscription_root.mkdir()
    published_root.mkdir()
    cert.write_text("test certificate fixture\n", encoding="ascii")
    key.write_text("test private key fixture\n", encoding="ascii")
    ca_bundle.write_text("test system CA fixture\n", encoding="ascii")
    for _name, _route, suffix in SPECS:
        (subscription_root / f"{DEVICE_ID}{suffix}").write_text(
            "fixture\n", encoding="utf-8"
        )

    rr_nexus.CONFIG_PATH = config_path
    rr_nexus.NEXUS_IP_CERT_PATH = cert
    rr_nexus.NEXUS_IP_KEY_PATH = key
    rr_nexus.NEXUS_IP_CERT_PENDING_PATH = pending
    rr_nexus.REMOTE_KEY_PATH = root / "remote.key"
    rr_nexus.REMOTE_SECURITY_LOCK_PATH = root / "nexus-security.lock"
    rr_nexus.os.environ["RR_CA_BUNDLE"] = str(ca_bundle)

    cert_state = {
        "identity": IPV4,
        "trust": True,
        "valid": True,
        "matching_key": True,
    }
    calls: list[list[str]] = []
    qr_payloads: list[str] = []

    class Result:
        def __init__(self, returncode: int = 0, stdout: bytes = b"") -> None:
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = b""

    def fake_decode(_path: str) -> dict:
        return {"subjectAltName": (("IP Address", cert_state["identity"]),)}

    def fake_run(arguments, **_kwargs):
        argv = [str(value) for value in arguments]
        calls.append(argv)
        if argv[0] == "qrencode":
            qr_payloads.append(argv[-1])
            return Result(stdout=b"\x89PNG\r\n\x1a\nfixture")
        assert argv[0] == "openssl", argv
        if "-checkend" in argv:
            return Result(0 if cert_state["valid"] else 1)
        if argv[1:3] == ["x509", "-in"] and "-pubkey" in argv:
            return Result(stdout=b"matched public key\n")
        if argv[1:3] == ["pkey", "-in"]:
            stdout = b"matched public key\n" if cert_state["matching_key"] else b"wrong key\n"
            return Result(stdout=stdout)
        if argv[1] == "verify":
            return Result(0 if cert_state["trust"] else 1)
        raise AssertionError(argv)

    rr_nexus.ssl._ssl._test_decode_cert = fake_decode
    rr_nexus.subprocess.run = fake_run

    def activate(
        domain: str,
        certificate_mode: str | None = rr_nexus.NEXUS_IP_CERTIFICATE_MODE,
        *,
        mode: str = "public",
        sub_port: int = 0,
    ) -> rr_nexus.NexusConfig:
        payload = {
            "mode": mode,
            "listen": "127.0.0.1",
            "port": 7900,
            "public_port": 8443,
            "domain": domain,
            "database": str(root / "nexus.db"),
            "subscription_root": str(subscription_root),
            "published_subscription_root": str(published_root),
            "stats_port": 39091,
            # The public identity must come from domain, never this mutable SSH
            # convenience address.
            "ssh_host": "9.9.9.9",
            "sub_port": sub_port,
            "subscription_access_mode": "local",
            "subscription_domain": "",
        }
        if certificate_mode is not None:
            payload["certificate_mode"] = certificate_mode
        config_path.write_text(json.dumps(payload), encoding="utf-8")
        config = rr_nexus.NexusConfig.load()
        rr_nexus.STATE = SimpleNamespace(config=config)
        cert_state["identity"] = domain
        cert_state["trust"] = True
        cert_state["valid"] = True
        cert_state["matching_key"] = True
        return config

    handler = object.__new__(rr_nexus.Handler)
    device = {"id": DEVICE_ID, "subscription_token": TOKEN}

    # The short-lived IP profile is checked at six hours, never at the
    # seven-day DNS threshold which would reject every 160-hour IP certificate.
    config = activate(IPV4)
    calls.clear()
    assert rr_nexus.remote_cert_check(config) == (True, "")
    checkend = next(argv for argv in calls if "-checkend" in argv)
    assert checkend[checkend.index("-checkend") + 1] == "21600", checkend
    verify = next(argv for argv in calls if len(argv) > 1 and argv[1] == "verify")
    assert verify[verify.index("-CAfile") + 1] == str(ca_bundle), verify
    assert "-purpose" in verify and "sslserver" in verify, verify

    # Every personal format is served through the authenticated panel route.
    primary, urls = handler._device_subscription_urls(device)
    expected_base = f"https://{IPV4}:8443/sub/{DEVICE_ID}/{TOKEN}"
    assert primary == expected_base + "/txt", primary
    assert len(urls) == len(SPECS) == 9, urls
    assert [item["format"] for item in urls] == [name for name, _route, _suffix in SPECS]
    assert [item["url"] for item in urls] == [
        f"{expected_base}/{route}" for _name, route, _suffix in SPECS
    ]
    assert all("9.9.9.9" not in item["url"] for item in urls)
    assert all(item["url"].startswith("https://") for item in urls)
    assert all("-k" not in item["url"] for item in urls)

    # IPv6 literals are the exact certificate identity and are bracketed only
    # at the URL serialization boundary.
    config = activate(IPV6)
    primary, urls = handler._device_subscription_urls(device)
    expected_base = f"https://[{IPV6}]:8443/sub/{DEVICE_ID}/{TOKEN}"
    assert primary == expected_base + "/txt", primary
    assert len(urls) == 9
    assert config.access_url == f"https://[{IPV6}]:8443"

    # All nine QR selections and the authenticated remote raw compatibility
    # path rebuild/whitelist the same trusted URLs server-side.
    handler.device_record = lambda _device_id: device
    handler.subscription_file = lambda _device_id: subscription_root / f"{DEVICE_ID}.txt"
    qr_payloads.clear()
    for index, item in enumerate(urls):
        status, png = handler._qr_png_bytes(DEVICE_ID, {"sub_index": [str(index)]})
        assert status == 200 and png == b"\x89PNG\r\n\x1a\nfixture", (status, png, index)
        assert qr_payloads[-1] == item["url"]
    handler._remote_session = {"remote": True}
    for item in urls:
        status, png = handler._qr_png_bytes(DEVICE_ID, {"raw": [item["url"]]})
        assert status == 200 and png == b"\x89PNG\r\n\x1a\nfixture", (status, png, item)
        assert qr_payloads[-1] == item["url"]

    # Remote-management credentials retain the raw IP certificate identity;
    # the HTTPS caller brackets IPv6 and relies on normal CA verification.
    rr_nexus.remote_key_load_or_create = lambda: b"R" * 32
    credential, reason = rr_nexus.remote_cred_issue("IPv6 server", config)
    assert reason == "" and credential
    parsed = rr_nexus.remote_cred_parse(credential)
    assert parsed and parsed["a"] == IPV6 and parsed["p"] == 8443, parsed
    posted: list[str] = []

    def fake_https_post(url, data, headers, timeout):
        posted.append(url)
        assert b'"cred"' in data
        return 200, b"{}"

    rr_nexus.https_post = fake_https_post
    status, payload = rr_nexus.Handler.remote_http_call(
        IPV6, 8443, credential, "GET", "/api/overview", None
    )
    assert status == 200 and payload == {}
    assert posted == [f"https://[{IPV6}]:8443/api/remote/call"]

    # A mode bit cannot bypass SAN, key, validity, system trust or the
    # publication journal.  Every failure suppresses all public URLs.
    config = activate(IPV4)
    failure_mutations = (
        ("identity", "1.1.1.1"),
        ("matching_key", False),
        ("trust", False),
        ("valid", False),
    )
    for key_name, bad_value in failure_mutations:
        activate(IPV4)
        cert_state[key_name] = bad_value
        assert not rr_nexus.remote_cert_check(rr_nexus.STATE.config)[0], key_name
        assert handler._device_subscription_urls(device) == ("", []), key_name

    activate(IPV4)
    pending.write_text("rr-nexus-ip-cert-pending-v1\n", encoding="ascii")
    assert not rr_nexus.remote_cert_check(rr_nexus.STATE.config)[0]
    assert handler._device_subscription_urls(device) == ("", [])
    pending.unlink()

    # Missing/legacy mode, private/multicast/mapped literals and the historical
    # "ip" sentinel must not publish even if certificate-shaped files exist.
    for domain, certificate_mode in (
        (IPV4, None),
        (IPV4, "legacy-self-signed"),
        (IPV4, "pending"),
        ("10.0.0.8", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
        ("224.0.0.1", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
        ("ff02::1", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
        ("::ffff:8.8.8.8", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
        ("fe80::1%1", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
        ("ip", rr_nexus.NEXUS_IP_CERTIFICATE_MODE),
    ):
        activate(domain, certificate_mode)
        assert not rr_nexus.remote_cert_check(rr_nexus.STATE.config)[0]
        assert handler._device_subscription_urls(device) == ("", []), (
            domain,
            certificate_mode,
        )
        denied: list[tuple[int, dict]] = []
        handler.send_json = lambda status, payload, *_args: denied.append(
            (int(status), payload)
        )
        handler.device_record = lambda _device_id: (_ for _ in ()).throw(
            AssertionError("untrusted public route reached token lookup")
        )
        handler.handle_public_subscription(DEVICE_ID, TOKEN, "txt")
        assert denied == [(404, {"error": "not_found"})], (
            domain,
            certificate_mode,
            denied,
        )

print("Nexus trusted IP subscription URL regression passed")
PY
