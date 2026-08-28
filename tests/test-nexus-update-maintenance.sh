#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PYTHONPATH="$REPO_ROOT/nexus" python3 - <<'PY'
from __future__ import annotations

import tempfile
from pathlib import Path
from types import SimpleNamespace

import rr_nexus


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    marker = root / "update-maintenance"
    database = root / "nexus.db"
    store = rr_nexus.Store(database)
    rr_nexus.UPDATE_MAINTENANCE_PATH = marker
    rr_nexus.STATE = SimpleNamespace(
        store=store,
        config=SimpleNamespace(database=database, mode="local"),
    )

    assert not rr_nexus.update_maintenance_active()

    request = object.__new__(rr_nexus.Handler)
    responses = []
    request.send_json = lambda status, payload, extra_headers=None: responses.append(
        (status, payload, extra_headers)
    )
    assert not request.reject_api_during_update("/api/session")

    marker.write_text("transaction\n", encoding="ascii")
    assert rr_nexus.update_maintenance_active()

    # Every API method is rejected before authentication, body parsing, remote
    # dispatch, or a database mutation can run.
    for method, path in (
        (request._dispatch_post, "/api/login"),
        (request._dispatch_patch, "/api/devices/dev_aaaaaaaaaaaa"),
        (request.do_DELETE, "/api/devices/dev_aaaaaaaaaaaa"),
    ):
        responses.clear()
        request.path = path
        request.parse_path = lambda path=path: (
            path,
            [part for part in path.split("/") if part],
            {},
        )
        method()
        assert len(responses) == 1, (path, responses)
        status, payload, headers = responses[0]
        assert status == rr_nexus.HTTPStatus.SERVICE_UNAVAILABLE
        assert payload["error"] == "update_maintenance"
        assert headers == {"Retry-After": "2"}

    # GET /api is gated, while healthz and static assets remain available for
    # the candidate health gate and for a useful maintenance page.
    responses.clear()
    request.path = "/api/session"
    request.parse_path = lambda: ("/api/session", ["api", "session"], {})
    request.current_session = lambda: (_ for _ in ()).throw(
        AssertionError("session lookup ran during maintenance")
    )
    request.do_GET()
    assert responses[0][0] == rr_nexus.HTTPStatus.SERVICE_UNAVAILABLE

    responses.clear()
    request.path = "/healthz"
    request.parse_path = lambda: ("/healthz", ["healthz"], {})
    request.do_GET()
    assert responses[0][0] == rr_nexus.HTTPStatus.OK
    assert responses[0][1]["ok"] is True

    served = []
    request.path = "/"
    request.parse_path = lambda: ("/", [], {})
    request.serve_static = lambda path: served.append(path)
    request.do_GET()
    assert served == ["/"]

    # Candidate background workers must not write the snapshotted database or
    # invoke the shell sync path before commit.
    collector = object.__new__(rr_nexus.TrafficCollector)
    collector.set_status = lambda available, status, error="": None
    collector.collect_server_traffic = lambda: (_ for _ in ()).throw(
        AssertionError("traffic collection ran during maintenance")
    )
    assert collector.collect_once(trigger_sync=True) == (
        True,
        "update_maintenance",
    )

    state = object.__new__(rr_nexus.NexusState)
    state._do_sync_once = lambda: (_ for _ in ()).throw(
        AssertionError("device sync ran during maintenance")
    )
    assert state.sync_devices() == (False, "update_maintenance")
    state._last_alert_check = 0
    state._alert_lock = None
    state.check_alerts_async()

    marker.unlink()
    assert not rr_nexus.update_maintenance_active()
    assert not request.reject_api_during_update("/api/session")

    # A malformed entry must fail closed rather than silently opening writes.
    marker.symlink_to(root / "missing")
    assert rr_nexus.update_maintenance_active()

print("nexus update maintenance regression tests passed")
PY
