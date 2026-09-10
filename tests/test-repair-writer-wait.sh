#!/usr/bin/env bash
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'ERROR: root required' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../modules/55-resilience.sh
source "$repo/modules/55-resilience.sh"
fixture=$(mktemp -d /root/rr-test-writer-wait.XXXXXX)
holder_pid=''
cleanup() {
    if [ -n "$holder_pid" ]; then
        kill "$holder_pid" 2>/dev/null || true
        wait "$holder_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
RR_RESTORE_LOCK_FILE="$fixture/locks/update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$fixture/legacy.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$fixture/legacy-marker"
RR_RESTORE_LIVE_LOCK_FILE="$fixture/restore-live.lock"
rr_secure_lock_prepare "$RR_RESTORE_LOCK_FILE"
# Extract the literal call used by the recovery helper; no service code loads.
python3 - "$repo/scripts/repair-v723-naive-first-install.sh" "$fixture/call.sh" <<'PY'
from pathlib import Path
import sys
lines = [line for line in Path(sys.argv[1]).read_text().splitlines()
         if line.startswith('rr_run_with_update_locks ')]
assert lines == ['rr_run_with_update_locks isolated 20 repair_locked </dev/null']
Path(sys.argv[2]).write_text(lines[0] + '\n')
PY
start_holder() {
    local delay="$1"
    rm -f -- "$fixture/ready" "$fixture/release"
    python3 - "$RR_RESTORE_LOCK_FILE" "$fixture" "$delay" <<'PY' &
import fcntl, sys, time
from pathlib import Path
root, delay = Path(sys.argv[2]), float(sys.argv[3])
with open(sys.argv[1], 'rb') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    (root / 'ready').touch()
    deadline = time.monotonic() + delay
    while time.monotonic() < deadline and not (root / 'release').exists():
        time.sleep(0.02)
PY
    holder_pid=$!
    local attempt
    for attempt in {1..100}; do
        [ ! -f "$fixture/ready" ] || return 0
        sleep 0.02
    done
    echo 'ERROR: lock holder failed to start' >&2
    return 1
}
finish_holder() {
    : >"$fixture/release"
    wait "$holder_pid"
    holder_pid=''
}
repair_locked() {
    [ "$RR_UPDATE_LOCK_OWNER:$RR_UPDATE_LOCK_FDS_CLOSED" = 0:1 ] || return 1
    local probe=0
    rr_inherited_update_lock_fds_present || probe=$?
    [ "$probe" = 1 ] || return 1
    printf 'called\n' >>"$fixture/callback"
    return "${callback_result:-0}"
}
# Real temporary contention must clear, and the isolated callback runs once.
start_holder 0.5
# shellcheck disable=SC1091
source "$fixture/call.sh"
finish_holder
[ "$(wc -l <"$fixture/callback")" = 1 ]
rm -- "$fixture/callback"
# A lock held beyond the actual 20-second bound must never enter the callback.
start_holder 30
result=0
# shellcheck disable=SC1091
source "$fixture/call.sh" || result=$?
[ "$result" = 75 ] && [ ! -e "$fixture/callback" ]
finish_holder
# Callback failure must not trigger a second attempt after host writes begin.
callback_result=75
result=0
# shellcheck disable=SC1091
source "$fixture/call.sh" || result=$?
[ "$result" = 75 ] && [ "$(wc -l <"$fixture/callback")" = 1 ]
printf '%s\n' 'REPAIR_WRITER_WAIT_PASS real_flock=true bounded_wait=20 callback_retry=false services_started=false'
