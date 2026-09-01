#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus" python3 - <<'PY'
from __future__ import annotations

import concurrent.futures
import io
import sqlite3
import sys
import tempfile
import threading
import types
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace


# This focused persistence test never hashes a password.  Keep it runnable on
# minimal developer machines; the full validator still exercises real Argon2.
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


def create_admin(store: rr_nexus.Store, username: str) -> int:
    timestamp = "2026-08-27T00:00:00+00:00"
    with store.connect() as connection:
        cursor = connection.execute(
            "INSERT INTO admins(username,password_hash,created_at,updated_at) "
            "VALUES(?,?,?,?)",
            (username, "unused-test-hash", timestamp, timestamp),
        )
        return int(cursor.lastrowid)


def create_bound_session(
    state: rr_nexus.NexusState,
    admin_id: int,
    remote_ip: str,
) -> tuple[str, str, int]:
    with state.store.connect() as connection:
        row = connection.execute(
            "SELECT security_version FROM admins WHERE id=?",
            (admin_id,),
        ).fetchone()
    assert row is not None
    security_version = int(row["security_version"])
    created = state.create_session(admin_id, remote_ip, security_version)
    assert created is not None
    token, csrf = created
    return token, csrf, security_version


def consume_concurrently(
    state: rr_nexus.NexusState,
    token: str,
    session_hash: str,
    admin_id: int,
    purpose: str,
    now: int,
    contenders: int = 16,
) -> list[bool]:
    barrier = threading.Barrier(contenders)

    def consume() -> bool:
        barrier.wait(timeout=10)
        return state.consume_step_up_ticket(
            token, session_hash, admin_id, purpose, now=now
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=contenders) as executor:
        futures = [executor.submit(consume) for _ in range(contenders)]
        return [future.result(timeout=30) for future in futures]


assert rr_nexus.STEP_UP_TTL_SECONDS == 300

with tempfile.TemporaryDirectory() as directory:
    rr_nexus.UPDATE_MAINTENANCE_PATH = Path(directory) / "update-maintenance"
    assert not rr_nexus.update_maintenance_active()
    database = Path(directory) / "nexus.db"
    store = rr_nexus.Store(database)
    state = object.__new__(rr_nexus.NexusState)
    state.store = store
    state.config = SimpleNamespace(mode="local", port=7900, public_port=7900)
    rr_nexus.STATE = state

    admin_id = create_admin(store, "stepup_admin")
    other_admin_id = create_admin(store, "other_admin")
    issued_at = 1_800_000_000
    session_token, csrf_token, _ = create_bound_session(
        state, admin_id, "192.0.2.10"
    )
    other_session_token, _, _ = create_bound_session(
        state, other_admin_id, "192.0.2.11"
    )
    peer_session_token, _, _ = create_bound_session(
        state, admin_id, "192.0.2.10"
    )
    session_hash = rr_nexus.sha256_text(session_token)
    other_session_hash = rr_nexus.sha256_text(other_session_token)
    peer_session_hash = rr_nexus.sha256_text(peer_session_token)
    with store.connect() as connection:
        connection.execute(
            "UPDATE sessions SET expires_at=? WHERE token_hash IN (?,?,?)",
            (
                issued_at + 3600,
                session_hash,
                other_session_hash,
                peer_session_hash,
            ),
        )
    purpose = "remote_issue"

    # A valid login session and CSRF token alone must stop at the route gate;
    # none of the persistent high-risk handlers may run without step-up.
    route_session = {
        "token_hash": session_hash,
        "admin_id": admin_id,
        "username": "stepup_admin",
        "csrf_token": csrf_token,
        "session_security_version": 0,
    }
    protected_posts = {
        "/api/change-password": "handle_change_password",
        "/api/security/totp/begin": "handle_totp_begin",
        "/api/security/totp/confirm": "handle_totp_confirm",
        "/api/security/totp/disable": "handle_totp_disable",
        "/api/security/passkeys/register/begin": "handle_passkey_register_begin",
        "/api/remote/issue": "handle_remote_issue",
        "/api/remote/revoke": "handle_remote_revoke",
    }
    for route, handler_name in protected_posts.items():
        request = object.__new__(rr_nexus.Handler)
        request.path = route
        request.headers = {"X-CSRF-Token": csrf_token}
        request.current_session = lambda: route_session
        responses = []
        request.send_json = lambda status, payload, extra_headers=None: responses.append(
            (status, payload)
        )
        setattr(
            request,
            handler_name,
            lambda *args, route=route: (_ for _ in ()).throw(
                AssertionError(f"unguarded high-risk handler ran: {route}")
            ),
        )
        request._dispatch_post()
        assert responses == [
            (rr_nexus.HTTPStatus.FORBIDDEN, {
                "error": "step_up_required",
                "message": "此操作需要重新验证当前密码与两步验证。",
            })
        ], (route, responses)

    request = object.__new__(rr_nexus.Handler)
    request.path = "/api/security/passkeys/credential-id"
    request.headers = {"X-CSRF-Token": csrf_token}
    request.current_session = lambda: route_session
    responses = []
    request.send_json = lambda status, payload, extra_headers=None: responses.append(
        (status, payload)
    )
    request.handle_passkey_delete = lambda *args: (_ for _ in ()).throw(
        AssertionError("unguarded passkey delete handler ran")
    )
    request.do_DELETE()
    assert responses and responses[0][0] == rr_nexus.HTTPStatus.FORBIDDEN
    assert responses[0][1]["error"] == "step_up_required"

    # A step-up-authorized Passkey ceremony belongs to the exact session that
    # began it.  Another same-admin/same-IP session cannot finish it, and
    # logout removes its outstanding continuation by foreign-key cascade.
    challenge_id, _ = state.create_webauthn_challenge(
        "register", "192.0.2.10", admin_id, session_hash
    )
    assert state.consume_webauthn_challenge(
        challenge_id, "register", "192.0.2.10", peer_session_hash
    ) is None
    assert state.consume_webauthn_challenge(
        challenge_id, "register", "192.0.2.10", session_hash
    ) is not None
    logout_challenge_id, _ = state.create_webauthn_challenge(
        "register", "192.0.2.10", admin_id, peer_session_hash
    )
    with store.connect() as connection:
        connection.execute(
            "DELETE FROM sessions WHERE token_hash=?", (peer_session_hash,)
        )
        assert connection.execute(
            "SELECT 1 FROM webauthn_challenges WHERE id=?",
            (logout_challenge_id,),
        ).fetchone() is None

    # Issuance itself requires the current password and, when configured, the
    # current TOTP.  Recovery-code or session possession alone is insufficient.
    class FakePasswordHasher:
        @staticmethod
        def verify(encoded: str, password: str) -> bool:
            if encoded == "unused-test-hash" and password == "current-password":
                return True
            raise rr_nexus.VerifyMismatchError("mismatch")

    state.password_hasher = FakePasswordHasher()
    state.client_is_locked = lambda *args: (False, 0)
    state.record_login_failure = lambda *args: None
    state.clear_login_failures = lambda *args: None
    with store.connect() as connection:
        connection.execute(
            "UPDATE admins SET totp_secret='current-secret',totp_enabled=1 WHERE id=?",
            (admin_id,),
        )
    original_verify_totp = rr_nexus.verify_totp
    rr_nexus.verify_totp = lambda secret, code: (
        secret == "current-secret" and code == "123456"
    )

    def issue_through_handler(password: str, otp: str):
        request = object.__new__(rr_nexus.Handler)
        request.client_address = ("192.0.2.10", 44321)
        request.headers = {}
        request.read_json = lambda: {
            "purpose": "remote_issue", "password": password, "otp": otp,
        }
        responses = []
        request.send_json = lambda status, payload, extra_headers=None: responses.append(
            (status, payload)
        )
        request.handle_step_up(route_session)
        assert len(responses) == 1
        return responses[0]

    try:
        status, payload = issue_through_handler("wrong-password", "123456")
        assert status == rr_nexus.HTTPStatus.FORBIDDEN
        assert payload["error"] == "step_up_verification_failed"
        status, payload = issue_through_handler("current-password", "")
        assert status == rr_nexus.HTTPStatus.FORBIDDEN
        assert payload["error"] == "step_up_verification_failed"
        status, payload = issue_through_handler("current-password", "123456")
        assert status == rr_nexus.HTTPStatus.OK
        assert state.consume_step_up_ticket(
            payload["ticket"], session_hash, admin_id, "remote_issue"
        )
    finally:
        rr_nexus.verify_totp = original_verify_totp

    # Tickets are bound to the administrator's authentication state.  A
    # password/TOTP/Passkey change invalidates already-issued tickets, and an
    # in-flight verifier that started before the change cannot mint a new one.
    state.password_hasher = FakePasswordHasher()
    stale_version_token = state.issue_step_up_ticket(
        session_hash,
        admin_id,
        "remote_issue",
        now=issued_at,
        expected_security_version=0,
    )
    with store.connect() as connection:
        connection.execute(
            "UPDATE admins SET security_version=security_version+1,totp_enabled=0 "
            "WHERE id=?",
            (admin_id,),
        )
    assert not state.step_up_ticket_valid(
        stale_version_token, session_hash, admin_id, "remote_issue", now=issued_at
    )
    assert not state.consume_step_up_ticket(
        stale_version_token, session_hash, admin_id, "remote_issue", now=issued_at
    )
    try:
        state.issue_step_up_ticket(
            session_hash,
            admin_id,
            "remote_issue",
            now=issued_at,
            expected_security_version=0,
        )
    except ValueError:
        pass
    else:
        raise AssertionError("stale security state minted a step-up ticket")

    # A persisted session row is unusable as soon as its issuance version no
    # longer equals the administrator's current authentication state.
    assert state.session(session_token) is None
    assert state.create_session(admin_id, "192.0.2.10", 0) is None
    with store.connect() as connection:
        connection.execute(
            "DELETE FROM sessions WHERE token_hash=?",
            (session_hash,),
        )

    racing_token, _, racing_version = create_bound_session(
        state, admin_id, "192.0.2.10"
    )
    assert racing_version == 1
    racing_hash = rr_nexus.sha256_text(racing_token)
    with store.connect() as connection:
        connection.execute(
            "UPDATE sessions SET expires_at=? WHERE token_hash=?",
            (issued_at + 3600, racing_hash),
        )
    racing_row = state.session(racing_token)
    assert racing_row is not None
    racing_session = dict(racing_row)

    class RacingPasswordHasher:
        @staticmethod
        def verify(encoded: str, password: str) -> bool:
            assert encoded == "unused-test-hash"
            assert password == "current-password"
            with store.connect() as connection:
                connection.execute(
                    "UPDATE admins SET security_version=security_version+1 WHERE id=?",
                    (admin_id,),
                )
            return True

    state.password_hasher = RacingPasswordHasher()
    request = object.__new__(rr_nexus.Handler)
    request.client_address = ("192.0.2.10", 44321)
    request.headers = {}
    request.read_json = lambda: {
        "purpose": "remote_issue", "password": "current-password", "otp": "",
    }
    race_responses = []
    request.send_json = lambda status, payload, extra_headers=None: race_responses.append(
        (status, payload)
    )
    request.handle_step_up(racing_session)
    assert race_responses == [
        (rr_nexus.HTTPStatus.CONFLICT, {"error": "security_state_changed"})
    ], race_responses
    assert state.session(racing_token) is None
    with store.connect() as connection:
        connection.execute(
            "DELETE FROM sessions WHERE token_hash=?",
            (racing_hash,),
        )

    session_token, csrf_token, current_version = create_bound_session(
        state, admin_id, "192.0.2.10"
    )
    assert current_version == 2
    session_hash = rr_nexus.sha256_text(session_token)
    with store.connect() as connection:
        connection.execute(
            "UPDATE sessions SET expires_at=? WHERE token_hash=?",
            (issued_at + 3600, session_hash),
        )

    # Tickets are scoped to all three authorization inputs.  A mismatch must
    # neither validate nor consume the ticket intended for the original scope.
    scoped_token = state.issue_step_up_ticket(
        session_hash, admin_id, purpose, now=issued_at
    )
    assert state.step_up_ticket_valid(
        scoped_token, session_hash, admin_id, purpose, now=issued_at
    )
    assert not state.step_up_ticket_valid(
        scoped_token, session_hash, admin_id, "remote_revoke", now=issued_at
    )
    assert not state.step_up_ticket_valid(
        scoped_token, other_session_hash, admin_id, purpose, now=issued_at
    )
    assert not state.step_up_ticket_valid(
        scoped_token, session_hash, other_admin_id, purpose, now=issued_at
    )
    assert not state.consume_step_up_ticket(
        scoped_token,
        session_hash,
        admin_id,
        "remote_revoke",
        now=issued_at,
    )
    assert not state.consume_step_up_ticket(
        scoped_token, other_session_hash, admin_id, purpose, now=issued_at
    )
    assert not state.consume_step_up_ticket(
        scoped_token, session_hash, other_admin_id, purpose, now=issued_at
    )
    assert state.consume_step_up_ticket(
        scoped_token, session_hash, admin_id, purpose, now=issued_at
    )
    assert not state.consume_step_up_ticket(
        scoped_token, session_hash, admin_id, purpose, now=issued_at
    )
    assert not state.step_up_ticket_valid(
        scoped_token, session_hash, admin_id, purpose, now=issued_at
    )

    # BEGIN IMMEDIATE (or an equivalent atomic delete) must guarantee exactly
    # one winner when several requests present the same one-time ticket.
    concurrent_token = state.issue_step_up_ticket(
        session_hash, admin_id, purpose, now=issued_at
    )
    concurrent_results = consume_concurrently(
        state,
        concurrent_token,
        session_hash,
        admin_id,
        purpose,
        issued_at,
    )
    assert concurrent_results.count(True) == 1, concurrent_results
    assert concurrent_results.count(False) == len(concurrent_results) - 1

    # The optional clock makes expiry deterministic: a ticket works immediately
    # before the five-minute boundary and is rejected at that boundary.
    expired_token = state.issue_step_up_ticket(
        session_hash, admin_id, purpose, now=issued_at
    )
    assert state.step_up_ticket_valid(
        expired_token,
        session_hash,
        admin_id,
        purpose,
        now=issued_at + rr_nexus.STEP_UP_TTL_SECONDS - 1,
    )
    expired_now = issued_at + rr_nexus.STEP_UP_TTL_SECONDS
    assert not state.step_up_ticket_valid(
        expired_token, session_hash, admin_id, purpose, now=expired_now
    )
    assert not state.consume_step_up_ticket(
        expired_token, session_hash, admin_id, purpose, now=expired_now
    )

    # Persist only a digest of the bearer credential.  Keep this ticket for the
    # following foreign-key cascade check as well.
    cascade_token = state.issue_step_up_ticket(
        session_hash, admin_id, "change_password", now=issued_at
    )
    with store.connect() as connection:
        columns = {
            row["name"] for row in connection.execute(
                "PRAGMA table_info(step_up_tokens)"
            )
        }
        assert {
            "token_hash",
            "session_hash",
            "admin_id",
            "purpose",
            "security_version",
            "expires_at",
        } <= columns, columns
        ticket_rows = connection.execute(
            "SELECT * FROM step_up_tokens"
        ).fetchall()
        assert len(ticket_rows) == 1, ticket_rows
        assert all(
            value != cascade_token
            for row in ticket_rows
            for value in tuple(row)
        ), "step-up bearer token was stored in plaintext"
        assert ticket_rows[0]["token_hash"] == rr_nexus.sha256_text(cascade_token)
        foreign_keys = connection.execute(
            "PRAGMA foreign_key_list(step_up_tokens)"
        ).fetchall()
        assert any(
            row["table"] == "sessions"
            and row["from"] == "session_hash"
            and row["to"] == "token_hash"
            and row["on_delete"].upper() == "CASCADE"
            for row in foreign_keys
        ), foreign_keys

        connection.execute(
            "DELETE FROM sessions WHERE token_hash=?", (session_hash,)
        )

    with store.connect() as connection:
        remaining = connection.execute(
            "SELECT COUNT(*) FROM step_up_tokens WHERE session_hash=?",
            (session_hash,),
        ).fetchone()[0]
    assert remaining == 0
    assert not state.step_up_ticket_valid(
        cascade_token,
        session_hash,
        admin_id,
        "change_password",
        now=issued_at,
    )

    # Deterministically pause an old-password login after Argon2 verification.
    # A concurrent password/factor rotation must win: the stale rehash cannot
    # overwrite the new hash and the old authentication snapshot cannot mint a
    # fresh 12-hour session after the revocation transaction commits.
    login_race_admin_id = create_admin(store, "login_race_admin")
    verify_started = threading.Event()
    release_verify = threading.Event()

    class BlockedRehashPasswordHasher:
        @staticmethod
        def verify(encoded: str, password: str) -> bool:
            assert encoded == "unused-test-hash"
            assert password == "old-password"
            verify_started.set()
            assert release_verify.wait(timeout=10)
            return True

        @staticmethod
        def check_needs_rehash(encoded: str) -> bool:
            assert encoded == "unused-test-hash"
            return True

        @staticmethod
        def hash(password: str) -> str:
            assert password == "old-password"
            return "stale-rehash-must-not-win"

    state.password_hasher = BlockedRehashPasswordHasher()
    stale_login = object.__new__(rr_nexus.Handler)
    stale_login.client_address = ("192.0.2.30", 44321)
    stale_login.headers = {}
    stale_login.read_json = lambda: {
        "username": "login_race_admin",
        "password": "old-password",
    }
    stale_login_responses = []
    stale_login.send_json = (
        lambda status, payload, extra_headers=None: stale_login_responses.append(
            (status, payload, extra_headers)
        )
    )
    stale_login_errors = []

    def run_stale_login() -> None:
        try:
            stale_login.handle_login()
        except BaseException as exc:
            stale_login_errors.append(exc)

    stale_login_thread = threading.Thread(target=run_stale_login)
    stale_login_thread.start()
    assert verify_started.wait(timeout=10)
    with store.connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute(
            "UPDATE admins SET password_hash=?,security_version=security_version+1 "
            "WHERE id=?",
            ("concurrent-new-password-hash", login_race_admin_id),
        )
        connection.execute(
            "DELETE FROM sessions WHERE admin_id=?",
            (login_race_admin_id,),
        )
    release_verify.set()
    stale_login_thread.join(timeout=10)
    assert not stale_login_thread.is_alive()
    assert not stale_login_errors, stale_login_errors
    assert stale_login_responses == [
        (
            rr_nexus.HTTPStatus.CONFLICT,
            {"error": "security_state_changed"},
            None,
        )
    ], stale_login_responses
    with store.connect() as connection:
        raced_admin = connection.execute(
            "SELECT password_hash,security_version FROM admins WHERE id=?",
            (login_race_admin_id,),
        ).fetchone()
        assert raced_admin["password_hash"] == "concurrent-new-password-hash"
        assert int(raced_admin["security_version"]) == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE admin_id=?",
            (login_race_admin_id,),
        ).fetchone()[0] == 0

    # Passkey verification is also deliberately paused after the credential
    # and admin version snapshot is read.  Deleting that Passkey must prevent
    # the in-flight assertion from switching to the newer admin version and
    # recreating a session.
    passkey_race_admin_id = create_admin(store, "passkey_race_admin")
    passkey_credential_id = "race-passkey-credential"
    with store.connect() as connection:
        connection.execute(
            "INSERT INTO webauthn_credentials("
            "credential_id,admin_id,name,public_key_pem,algorithm,sign_count,"
            "transports,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (
                passkey_credential_id,
                passkey_race_admin_id,
                "race key",
                b"test-public-key",
                -7,
                6,
                "",
                "2026-08-27T00:00:00+00:00",
            ),
        )
    passkey_challenge_id, _ = state.create_webauthn_challenge(
        "login", "192.0.2.31"
    )
    passkey_verify_started = threading.Event()
    release_passkey_verify = threading.Event()
    original_verify_authentication = rr_nexus.verify_authentication

    def blocked_passkey_verify(*_args, **_kwargs) -> int:
        passkey_verify_started.set()
        assert release_passkey_verify.wait(timeout=10)
        return 7

    rr_nexus.verify_authentication = blocked_passkey_verify
    passkey_login = object.__new__(rr_nexus.Handler)
    passkey_login.client_address = ("192.0.2.31", 44321)
    passkey_login.headers = {}
    passkey_login.read_json = lambda: {
        "challenge_id": passkey_challenge_id,
        "credential_id": passkey_credential_id,
        "client_data": "ignored-by-test",
        "authenticator_data": "ignored-by-test",
        "signature": "ignored-by-test",
    }
    passkey_login_responses = []
    passkey_login.send_json = (
        lambda status, payload, extra_headers=None: passkey_login_responses.append(
            (status, payload, extra_headers)
        )
    )
    passkey_login_errors = []

    def run_stale_passkey_login() -> None:
        try:
            passkey_login.handle_passkey_login_finish()
        except BaseException as exc:
            passkey_login_errors.append(exc)

    passkey_login_thread = threading.Thread(target=run_stale_passkey_login)
    passkey_login_thread.start()
    assert passkey_verify_started.wait(timeout=10)
    with store.connect() as connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute(
            "UPDATE admins SET security_version=security_version+1 WHERE id=?",
            (passkey_race_admin_id,),
        )
        connection.execute(
            "DELETE FROM webauthn_credentials WHERE credential_id=? AND admin_id=?",
            (passkey_credential_id, passkey_race_admin_id),
        )
        connection.execute(
            "DELETE FROM sessions WHERE admin_id=?",
            (passkey_race_admin_id,),
        )
    release_passkey_verify.set()
    passkey_login_thread.join(timeout=10)
    rr_nexus.verify_authentication = original_verify_authentication
    assert not passkey_login_thread.is_alive()
    assert not passkey_login_errors, passkey_login_errors
    assert passkey_login_responses == [
        (
            rr_nexus.HTTPStatus.CONFLICT,
            {"error": "security_state_changed"},
            None,
        )
    ], passkey_login_responses
    with store.connect() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE admin_id=?",
            (passkey_race_admin_id,),
        ).fetchone()[0] == 0

    # A copied current bearer must die together with every peer session after
    # an authentication-factor change.  Keeping the request's own row was not
    # sufficient: an attacker could already possess the exact same raw token.
    rotation_admin_id = create_admin(store, "rotation_admin")
    state.config.mode = "public"
    current_token, _, _ = create_bound_session(
        state, rotation_admin_id, "192.0.2.20"
    )
    copied_current_token = current_token
    peer_token, _, _ = create_bound_session(
        state, rotation_admin_id, "192.0.2.21"
    )
    current_row = state.session(current_token)
    assert current_row is not None
    current_session = dict(current_row)

    class RotationPasswordHasher:
        @staticmethod
        def hash(password: str) -> str:
            assert password == "new-secure-password"
            return "rotated-test-hash"

    state.password_hasher = RotationPasswordHasher()
    password_request = object.__new__(rr_nexus.Handler)
    password_request.client_address = ("192.0.2.20", 44321)
    password_request.headers = {}
    password_request.read_json = lambda: {
        "new_password": "new-secure-password",
    }
    password_responses = []
    password_request.send_json = (
        lambda status, payload, extra_headers=None: password_responses.append(
            (status, payload, extra_headers)
        )
    )
    password_request.handle_change_password(current_session)
    assert password_responses == [
        (
            rr_nexus.HTTPStatus.OK,
            {"ok": True, "reauth_required": True},
            {
                "Set-Cookie": (
                    f"{rr_nexus.SESSION_COOKIE_NAME}=; Path=/; Secure; "
                    "HttpOnly; SameSite=Strict; Max-Age=0"
                )
            },
        )
    ], password_responses
    assert state.session(copied_current_token) is None
    assert state.session(peer_token) is None
    with store.connect() as connection:
        rotated = connection.execute(
            "SELECT password_hash,security_version FROM admins WHERE id=?",
            (rotation_admin_id,),
        ).fetchone()
        assert rotated["password_hash"] == "rotated-test-hash"
        assert int(rotated["security_version"]) == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE admin_id=?",
            (rotation_admin_id,),
        ).fetchone()[0] == 0

    # Administrator reset reuses SQLite row ids after deleting every admin.
    # Preserve a monotonic authentication generation so an in-flight snapshot
    # of the former id=1/version=N identity cannot pass create_session after
    # that id is assigned to the replacement administrator.
    with store.connect() as connection:
        stale_admin = connection.execute(
            "SELECT id,security_version FROM admins ORDER BY id LIMIT 1"
        ).fetchone()
        previous_max_generation = int(connection.execute(
            "SELECT MAX(security_version) FROM admins"
        ).fetchone()[0])
    stale_admin_id = int(stale_admin["id"])
    stale_admin_generation = int(stale_admin["security_version"])

    class ResetPasswordHasher:
        @staticmethod
        def hash(password: str) -> str:
            assert password == "replacement-password"
            return "replacement-password-hash"

        @staticmethod
        def verify(encoded: str, password: str) -> bool:
            if (
                encoded == "replacement-password-hash"
                and password == "replacement-password"
            ):
                return True
            raise rr_nexus.VerifyMismatchError("mismatch")

        @staticmethod
        def check_needs_rehash(_encoded: str) -> bool:
            return False

    state.password_hasher = ResetPasswordHasher()
    original_state_class = rr_nexus.NexusState
    original_stdin = sys.stdin
    reset_output = io.StringIO()
    try:
        rr_nexus.NexusState = lambda _config: state
        sys.stdin = io.StringIO("replacement-password\n")
        with redirect_stdout(reset_output):
            reset_status = rr_nexus.initialize_admin(
                state.config, "replacement_admin"
            )
    finally:
        rr_nexus.NexusState = original_state_class
        sys.stdin = original_stdin
    assert reset_status == 0
    recovery_line = next(
        line
        for line in reset_output.getvalue().splitlines()
        if line.startswith("RR_NEXUS_RECOVERY_CODES=")
    )
    recovery_codes = recovery_line.split("=", 1)[1].split(",")
    assert len(recovery_codes) == 8

    with store.connect() as connection:
        replacement = connection.execute(
            "SELECT id,username,password_hash,security_version FROM admins"
        ).fetchone()
        assert connection.execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM recovery_codes WHERE admin_id=? AND used_at IS NULL",
            (replacement["id"],),
        ).fetchone()[0] == 8
    assert int(replacement["id"]) == stale_admin_id
    assert replacement["username"] == "replacement_admin"
    assert replacement["password_hash"] == "replacement-password-hash"
    replacement_generation = int(replacement["security_version"])
    assert replacement_generation == previous_max_generation + 1
    assert replacement_generation != stale_admin_generation
    assert state.create_session(
        stale_admin_id,
        "192.0.2.40",
        stale_admin_generation,
    ) is None

    replacement_login, replacement_method = state.authenticate_with_method(
        "replacement_admin", "replacement-password"
    )
    assert replacement_login is not None and replacement_method == "password"
    replacement_created = state.create_session(
        int(replacement["id"]),
        "192.0.2.40",
        replacement_generation,
    )
    assert replacement_created is not None
    replacement_token, _ = replacement_created
    replacement_session = state.session(replacement_token)
    assert replacement_session is not None
    assert replacement_session["username"] == "replacement_admin"
    assert (
        int(replacement_session["session_security_version"])
        == replacement_generation
    )

    recovery_login, recovery_method = state.authenticate_with_method(
        "replacement_admin", recovery_codes[0]
    )
    assert recovery_login is not None and recovery_method == "recovery"
    with store.connect() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM recovery_codes WHERE admin_id=? AND used_at IS NULL",
            (replacement["id"],),
        ).fetchone()[0] == 7

    source = Path(rr_nexus.__file__).read_text(encoding="utf-8")
    assert "DELETE FROM sessions WHERE admin_id=? AND token_hash<>?" not in source
    assert source.count('"reauth_required": True') >= 5

    with sqlite3.connect(database) as connection:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"

print("Nexus step-up ticket regression passed")
PY
