#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

RR_LIB_DIR="$REPO_ROOT"
RR_REPOSITORY="example/rr-vps"
# shellcheck disable=SC1091
source modules/85-nexus.sh

echo "[1/5] executable timeout entrypoints"
python3 - modules/60-update.sh <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
# A backslash-newline is shell lexical continuation, not a command boundary.
semantic_source = re.sub(r"\\\r?\n", " ", source)
for command in ("--sync-devices", "--sync-subscriptions"):
    pattern = (
        r'timeout\s+--kill-after=5\s+150\s+"\$RR_LAUNCHER"\s+'
        + re.escape(command)
        + r'(?=\s|[;&|])'
    )
    assert re.search(pattern, semantic_source), (
        f"missing bounded executable {command} entrypoint"
    )
assert not re.search(
    r'timeout\s+(?:--[^\s]+\s+)*[0-9]+\s+'
    r'(?:sync_nexus_devices|generate_node_and_sub)(?=\s|[;&|])',
    semantic_source,
), "timeout still invokes a non-exported shell function"
PY

echo "[2/5] cross-process lock and atomic tree exchange"
NEXUS_SYNC_LOCK_FILE="$test_root/sync.lock"
lock_log="$test_root/lock.log"
locked_probe() {
    printf 'start:%s\n' "$1" >> "$lock_log"
    sleep 0.15
    printf 'end:%s\n' "$1" >> "$lock_log"
}
nexus_with_sync_lock locked_probe first &
first_pid=$!
nexus_with_sync_lock locked_probe second &
second_pid=$!
wait "$first_pid" "$second_pid"
python3 - "$lock_log" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 4, lines
assert lines[0].startswith("start:") and lines[1] == lines[0].replace("start:", "end:")
assert lines[2].startswith("start:") and lines[3] == lines[2].replace("start:", "end:")
PY

tree_target="$test_root/tree"
tree_stage="${tree_target}.stage.test"
mkdir "$tree_target" "$tree_stage"
printf '%s\n' old > "$tree_target/value"
printf '%s\n' new > "$tree_stage/value"
nexus_atomic_exchange_tree "$tree_stage" "$tree_target"
[ "$(<"$tree_target/value")" = new ]
[ "$(<"$tree_stage/value")" = old ]

echo "[3/5] failed staging preserves the published generation"
NEXUS_DATA_DIR="$test_root/failure/private-parent"
NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
SUB_ROOT="$test_root/failure/public-parent"
mkdir -p "$NEXUS_SUB_ROOT" "$SUB_ROOT/nexus"
printf '%s\n' private-old > "$NEXUS_SUB_ROOT/sentinel"
printf '%s\n' public-old > "$SUB_ROOT/nexus/sentinel"
ensure_subscription_root() { mkdir -p "$SUB_ROOT"; }
_generate_nexus_device_subscriptions_into_stage() {
    printf '%s\n' private-new > "$NEXUS_SUB_ROOT/sentinel"
    printf '%s\n' public-new > "$RR_NEXUS_PUBLISH_ROOT/sentinel"
    return 1
}
if _generate_nexus_device_subscriptions_staged; then
    echo "failed staged generation was published" >&2
    exit 1
fi
[ "$(<"$NEXUS_SUB_ROOT/sentinel")" = private-old ]
[ "$(<"$SUB_ROOT/nexus/sentinel")" = public-old ]
unset -f _generate_nexus_device_subscriptions_into_stage
# shellcheck disable=SC1091
source modules/85-nexus.sh

echo "[4/5] Python inflight handoff has no lost-update window"
stub_root="$test_root/python-stubs"
mkdir -p "$stub_root/argon2"
printf '%s\n' \
    'class PasswordHasher:' \
    '    def __init__(self, *args, **kwargs): pass' \
    '    def hash(self, value): return "stub"' \
    '    def verify(self, digest, value): return True' \
    '    def check_needs_rehash(self, digest): return False' \
    > "$stub_root/argon2/__init__.py"
printf '%s\n' \
    'class InvalidHash(Exception): pass' \
    'class VerifyMismatchError(Exception): pass' \
    > "$stub_root/argon2/exceptions.py"
PYTHONPATH="$stub_root:$REPO_ROOT/nexus" python3 - <<'PY'
import threading
import types

import rr_nexus

assert rr_nexus.DEVICE_SYNC_TIMEOUT_SECONDS == 300

class GapLock:
    """Pause the leader immediately after its second critical section."""

    def __init__(self):
        self.lock = threading.Lock()
        self.exits = 0
        self.gap = threading.Event()
        self.release = threading.Event()

    def __enter__(self):
        self.lock.acquire()
        return self

    def __exit__(self, *unused):
        self.exits += 1
        pause = self.exits == 2
        self.lock.release()
        if pause:
            self.gap.set()
            assert self.release.wait(2)

state = object.__new__(rr_nexus.NexusState)
state._sync_state_lock = GapLock()
state._sync_inflight = False
state._sync_pending = False
calls = 0
calls_lock = threading.Lock()
second_started = threading.Event()

def do_sync_once(self):
    global calls
    with calls_lock:
        calls += 1
        if calls == 2:
            second_started.set()
    return True, ""

state._do_sync_once = types.MethodType(do_sync_once, state)
results = []
leader = threading.Thread(target=lambda: results.append(state.sync_devices()))
leader.start()
assert state._sync_state_lock.gap.wait(2)
follower = threading.Thread(target=lambda: results.append(state.sync_devices()))
follower.start()
try:
    assert second_started.wait(2), "the update arriving at inflight handoff was lost"
finally:
    state._sync_state_lock.release.set()
leader.join(2)
follower.join(2)
assert not leader.is_alive() and not follower.is_alive()
assert calls == 2
assert state._sync_inflight is False and state._sync_pending is False
assert results == [(True, ""), (True, "")]
PY

echo "[5/5] 1/10/100/500-device generation is complete and bounded"
NEXUS_DATA_DIR="$test_root/load/private-parent"
NEXUS_DB_FILE="$NEXUS_DATA_DIR/nexus.db"
NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
NEXUS_CONFIG_FILE="$test_root/load/nexus.json"
SUB_ROOT="$test_root/load/public-parent"
NEXUS_SYNC_LOCK_FILE="$test_root/load/sync.lock"
mkdir -p "$NEXUS_SUB_ROOT" "$SUB_ROOT/nexus"
printf '%s\n' stale > "$NEXUS_SUB_ROOT/stale"
printf '%s\n' stale > "$SUB_ROOT/nexus/stale"
python3 - "$NEXUS_DB_FILE" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute(
        "CREATE TABLE devices (id TEXT PRIMARY KEY, credential TEXT, subscription_token TEXT, "
        "enabled INTEGER, expires_at TEXT, quota_bytes INTEGER, used_bytes INTEGER, created_at TEXT)"
    )
    db.executemany(
        "INSERT INTO devices VALUES (?,?,?,1,NULL,0,0,?)",
        [
            (
                f"dev_{number:012x}",
                f"00000000-0000-4000-8000-{number:012x}",
                f"token_{number:026d}",
                f"2026-01-01T00:00:{number:06d}Z",
            )
            for number in range(500)
        ],
    )
PY
printf '{}\n' > "$NEXUS_CONFIG_FILE"
UUID="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
NAIVE_PASS="server-password"
VM_ENABLED=false
VM_TLS_ENABLED=true
VL_ENABLED=false
HY2_ENABLED=false
TU5_ENABLED=false
AN_ENABLED=false
NAIVE_ENABLED=false
VL_PORT=0
HY2_PORT=0
TU5_PORT=0
AN_PORT=0
NAIVE_PORT=0
load_config_with_defaults() { return 0; }
ensure_subscription_root() { mkdir -p "$SUB_ROOT"; }
validate_subscription_crypto_material() { return 0; }
select_entry_ip() { ENTRY_IP_RAW=192.0.2.1; ENTRY_IP_URI=192.0.2.1; }
nexus_sync_subscription_endpoint() { return 0; }
is_valid_uuid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; }
generate_client_json() {
    local suffix=""
    [ "${2:-}" = vless ] && suffix=-vl
    mkdir -p "$RR_SUB_OUTPUT_DIR"
    printf '{"uuid":"%s","tag":"%s","user":"%s","password":"%s"}\n' \
        "$RR_CLIENT_UUID_OVERRIDE" "$RR_CLIENT_NAME_OVERRIDE" \
        "$RR_NAIVE_USER_OVERRIDE" "$RR_NAIVE_PASS_OVERRIDE" \
        > "$RR_SUB_OUTPUT_DIR/client${suffix}.json"
}
generate_clash_yaml() {
    mkdir -p "$RR_SUB_OUTPUT_DIR"
    printf 'uuid: %s\nname: %s\n' "$RR_CLIENT_UUID_OVERRIDE" \
        "$RR_CLIENT_NAME_OVERRIDE" > "$RR_SUB_OUTPUT_DIR/clash_meta.yaml"
}
start_epoch=$(date +%s)
for device_count in 1 10 100 500; do
    python3 - "$NEXUS_DB_FILE" "$device_count" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute(
        "UPDATE devices SET enabled=CASE WHEN rowid<=? THEN 1 ELSE 0 END",
        (int(sys.argv[2]),),
    )
PY
    case_started=$(date +%s%N)
    generate_nexus_device_subscriptions
    case_elapsed_ms=$(( ($(date +%s%N) - case_started) / 1000000 ))
    [ "$case_elapsed_ms" -lt 60000 ]
    [ ! -e "$NEXUS_SUB_ROOT/stale" ]
    [ ! -e "$SUB_ROOT/nexus/stale" ]
    [ "$(find "$NEXUS_SUB_ROOT" -maxdepth 1 -type f -name 'dev_*.txt' | wc -l)" \
        -eq $(( device_count * 5 )) ]
    [ "$(find "$SUB_ROOT/nexus" -maxdepth 1 -type f | wc -l)" \
        -eq $(( device_count * 11 + 1 )) ]
    printf 'devices=%d elapsed_ms=%d private_files=%d public_files=%d\n' \
        "$device_count" "$case_elapsed_ms" \
        "$(find "$NEXUS_SUB_ROOT" -maxdepth 1 -type f | wc -l)" \
        "$(find "$SUB_ROOT/nexus" -maxdepth 1 -type f | wc -l)"
done
elapsed=$(( $(date +%s) - start_epoch ))
jq -e '.uuid == "00000000-0000-4000-8000-00000000007b" and .tag == "RR-00000000"' \
    "$NEXUS_SUB_ROOT/dev_00000000007b.json" >/dev/null
cmp -s "$NEXUS_SUB_ROOT/dev_00000000007b.json" \
    "$SUB_ROOT/nexus/token_00000000000000000000000123.json"

echo "Nexus sync regression tests passed in ${elapsed}s for the full 1/10/100/500 matrix."
