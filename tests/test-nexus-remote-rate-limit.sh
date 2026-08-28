#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus" python3 - <<'PY'
from __future__ import annotations

import concurrent.futures
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import types
from pathlib import Path
from types import SimpleNamespace


# The focused test does not execute password hashing.  Keep it runnable on
# minimal developer machines while CI still exercises the real dependency in
# scripts/validate-7.1.py.
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


def run_concurrently(addresses: list[str]) -> list[tuple[bool, int]]:
    barrier = threading.Barrier(len(addresses))

    def reserve(address: str) -> tuple[bool, int]:
        barrier.wait(timeout=10)
        return rr_nexus.reserve_remote_failure(address)

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(addresses)) as executor:
        futures = [executor.submit(reserve, address) for address in addresses]
        return [future.result(timeout=30) for future in futures]


with tempfile.TemporaryDirectory() as directory:
    database = Path(directory) / "nexus.db"
    store = rr_nexus.Store(database)
    rr_nexus.STATE = SimpleNamespace(
        store=store,
        config=SimpleNamespace(mode="local"),
    )

    # The failure journal and its composite lookup index are part of the
    # persistent limiter contract; no migration or in-memory counter is needed.
    with store.connect() as connection:
        columns = {
            row[1]: row[2]
            for row in connection.execute("PRAGMA table_info(remote_failures)")
        }
        index_columns = {
            row[2]
            for row in connection.execute(
                "PRAGMA index_info(idx_remote_failures_ip)"
            )
        }
    assert columns["remote_ip"] == "TEXT"
    assert columns["failed_at"] == "INTEGER"
    assert index_columns == {"remote_ip", "failed_at"}
    assert rr_nexus.remote_cred_verify(
        "rrmgr1.é." + "A" * 43
    ) is None, "non-ASCII credential must fail closed before HMAC encoding"

    # Start more invalid calls than one IP is allowed.  BEGIN IMMEDIATE must
    # serialize the count-and-insert decision: exactly LIMIT calls reserve a
    # slot, every later contender is rejected, and the table cannot overshoot.
    request_count = rr_nexus.REMOTE_FAIL_LIMIT * 3
    address = "203.0.113.40"
    results = run_concurrently([address] * request_count)
    accepted = [result for result in results if result[0]]
    rejected = [result for result in results if not result[0]]
    assert len(accepted) == rr_nexus.REMOTE_FAIL_LIMIT, results
    assert len(rejected) == request_count - rr_nexus.REMOTE_FAIL_LIMIT, results
    assert all(1 <= retry <= rr_nexus.REMOTE_FAIL_WINDOW for _, retry in rejected)
    with store.connect() as connection:
        stored = connection.execute(
            "SELECT COUNT(*) FROM remote_failures WHERE remote_ip=?", (address,)
        ).fetchone()[0]
    assert stored == rr_nexus.REMOTE_FAIL_LIMIT

    accepted_slot, retry_after = rr_nexus.reserve_remote_failure(address)
    assert not accepted_slot
    assert 1 <= retry_after <= rr_nexus.REMOTE_FAIL_WINDOW

    # Model the precise TOCTOU window at the endpoint: this request observed an
    # unlocked preflight before its peers filled the journal.  The authoritative
    # reservation must still turn the invalid credential into 429, not 403.
    handler = object.__new__(rr_nexus.Handler)
    handler.client_address = (address, 443)
    handler.headers = {}
    handler.remote_failure_state = lambda: (False, 0)
    handler.read_json_body = lambda: {"cred": "invalid"}
    responses = []
    handler.send_json = lambda status, payload, headers=None: responses.append(
        (status, payload, headers)
    )
    original_verify = rr_nexus.remote_cred_verify
    rr_nexus.remote_cred_verify = lambda _credential: None
    try:
        handler.handle_remote_call()
    finally:
        rr_nexus.remote_cred_verify = original_verify
    assert len(responses) == 1
    assert responses[0][0] == rr_nexus.HTTPStatus.TOO_MANY_REQUESTS
    assert responses[0][1]["error"] == "too_many_attempts"
    assert responses[0][2] == {
        "Retry-After": str(responses[0][1]["retry_after"])
    }

    # Retry-After is the time until the oldest row leaves the sliding window,
    # not the time since the newest failure.  Widely spaced failures must not
    # tell clients to wait an extra full window.
    retry_clock = 1_900_000_000
    with store.connect() as connection:
        connection.execute("DELETE FROM remote_failures")
        connection.executemany(
            "INSERT INTO remote_failures(remote_ip,failed_at) VALUES(?,?)",
            [
                (
                    address,
                    retry_clock - rr_nexus.REMOTE_FAIL_WINDOW + 1 + index,
                )
                for index in range(rr_nexus.REMOTE_FAIL_LIMIT)
            ],
        )
    locked, retry_after = rr_nexus.remote_failure_state(address, now=retry_clock)
    assert locked and retry_after == 1, retry_after
    accepted_slot, retry_after = rr_nexus.reserve_remote_failure(
        address, now=retry_clock
    )
    assert not accepted_slot and retry_after == 1, retry_after

    other_accepted, other_retry = rr_nexus.reserve_remote_failure("203.0.113.41")
    assert other_accepted and other_retry == 0

    # Exercise the global cap with a deliberately small runtime value.  All IPs
    # remain below their per-IP limit, so pruning—not rejection—must keep the
    # persistent journal bounded even while writers contend.
    original_max_rows = rr_nexus.REMOTE_FAILURE_MAX_ROWS
    test_max_rows = rr_nexus.REMOTE_FAIL_LIMIT + 7
    rr_nexus.REMOTE_FAILURE_MAX_ROWS = test_max_rows
    try:
        with store.connect() as connection:
            connection.execute("DELETE FROM remote_failures")
        cap_addresses = [f"2001:db8::{index + 1}" for index in range(test_max_rows * 3)]
        cap_results = run_concurrently(cap_addresses)
        assert all(accepted and retry == 0 for accepted, retry in cap_results)
        with store.connect() as connection:
            total = connection.execute(
                "SELECT COUNT(*) FROM remote_failures"
            ).fetchone()[0]
        assert total <= test_max_rows, (total, test_max_rows)
    finally:
        rr_nexus.REMOTE_FAILURE_MAX_ROWS = original_max_rows

    # Remote-management credentials may be issued only when the configured
    # public domain has a matching, non-expiring, key-matched chain anchored in
    # the selected system CA bundle.  A merely present/self-signed PEM fails.
    cert_root = Path(directory) / "certificates"
    live_root = Path(directory) / "live"
    domain = "panel.example.test"
    lineage = live_root / domain
    cert_root.mkdir()
    lineage.mkdir(parents=True)
    run = lambda arguments: subprocess.run(  # noqa: E731
        arguments, check=True, capture_output=True, timeout=15
    )
    run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "365", "-subj", "/CN=RR test root",
        "-keyout", str(cert_root / "ca.key"), "-out", str(cert_root / "ca.crt"),
    ])
    run([
        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-subj", f"/CN={domain}", "-keyout", str(lineage / "privkey.pem"),
        "-out", str(cert_root / "leaf.csr"),
    ])
    extension = cert_root / "server.ext"
    extension.write_text(
        f"subjectAltName=DNS:{domain}\nextendedKeyUsage=serverAuth\n",
        encoding="ascii",
    )
    run([
        "openssl", "x509", "-req", "-days", "30",
        "-in", str(cert_root / "leaf.csr"),
        "-CA", str(cert_root / "ca.crt"), "-CAkey", str(cert_root / "ca.key"),
        "-CAcreateserial", "-extfile", str(extension),
        "-out", str(cert_root / "leaf.crt"),
    ])
    (lineage / "fullchain.pem").write_bytes(
        (cert_root / "leaf.crt").read_bytes() + (cert_root / "ca.crt").read_bytes()
    )
    rr_nexus.LETSENCRYPT_LIVE_ROOT = live_root
    os.environ["RR_CA_BUNDLE"] = str(cert_root / "ca.crt")
    public_config = SimpleNamespace(mode="public", domain=domain, public_port=443)
    assert rr_nexus.remote_cert_check(public_config) == (True, "")

    self_signed = lineage / "fullchain.pem"
    run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "30", "-subj", f"/CN={domain}",
        "-addext", f"subjectAltName=DNS:{domain}",
        "-keyout", str(lineage / "privkey.pem"), "-out", str(self_signed),
    ])
    trusted, reason = rr_nexus.remote_cert_check(public_config)
    assert not trusted and "CA" in reason, (trusted, reason)

    with sqlite3.connect(database) as connection:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"

print("Nexus remote failure limiter concurrency regression passed")
PY
