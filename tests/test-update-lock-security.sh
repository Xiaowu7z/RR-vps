#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf '%s\n' 'update lock security regressions require root' >&2
    exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# This runner maps only uid/gid 0, so physical chown fixtures cannot represent
# hostile ownership.  Override only the two marked stat calls; every ordinary
# path and every fd identity check still reaches the real stat(1).
stat() {
    local -a arguments=("$@")
    local last_index=$(($# - 1))
    local path="${arguments[$last_index]}"
    local argument=""
    if [[ "$path" == */wrong-owner/update.lock ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%h ]; then
                printf '%s\n' 65534:1
                return 0
            fi
        done
    fi
    if [[ "$path" == */wrong-parent ]]; then
        for argument in "${arguments[@]}"; do
            if [ "$argument" = %u:%g ]; then
                printf '%s\n' 65534:65534
                return 0
            fi
        done
    fi
    command stat "${arguments[@]}"
}

extract_function() {
    local source_file="$1" function_name="$2"
    awk -v function_name="$function_name" '
        $0 ~ "^" function_name "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$source_file"
}

run_helper_security_matrix() (
    local label="$1" source_file="$2" prepare_function="$3" fd_function="$4"
    local case_root="$test_root/helpers/$label"
    local lock_file="" target="" fd="" contender_fd="" held_fd=""

    mkdir -p "$case_root"
    chmod 700 "$case_root"
    # shellcheck disable=SC2294
    eval "$(extract_function "$source_file" "$prepare_function")"
    # shellcheck disable=SC2294
    eval "$(extract_function "$source_file" "$fd_function")"
    declare -F "$prepare_function" >/dev/null || fail "$label prepare helper was not extracted"
    declare -F "$fd_function" >/dev/null || fail "$label fd helper was not extracted"

    # Missing files are created atomically and existing safe files are repaired
    # to the one-link, root-owned 0600 contract.
    mkdir -m 700 "$case_root/create"
    lock_file="$case_root/create/update.lock"
    "$prepare_function" "$lock_file" || fail "$label rejected a safe absent lock"
    [ "$(stat -c '%u:%g:%a:%h' "$lock_file")" = 0:0:600:1 ] || \
        fail "$label created a lock with unsafe metadata"
    exec {fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$fd" || fail "$label rejected matching lock fd"
    exec {fd}>&-

    mkdir -m 700 "$case_root/repair"
    lock_file="$case_root/repair/update.lock"
    : > "$lock_file"
    chmod 0666 "$lock_file"
    "$prepare_function" "$lock_file" || fail "$label did not repair safe root-owned lock metadata"
    [ "$(stat -c '%u:%g:%a:%h' "$lock_file")" = 0:0:600:1 ] || \
        fail "$label left repaired lock metadata unsafe"

    # The dedicated /run/rr-vps/locks directory is always narrowed to 0700.
    # This prevents a low-privilege process from pre-creating lock names even
    # if an earlier installation accidentally left the directory writable.
    mkdir -m 0777 "$case_root/writable-parent"
    "$prepare_function" "$case_root/writable-parent/update.lock" || \
        fail "$label could not repair a root-owned writable parent"
    [ "$(stat -c '%u:%g:%a' "$case_root/writable-parent")" = 0:0:700 ] || \
        fail "$label did not privatize a writable lock parent"
    mkdir -m 1777 "$case_root/sticky-parent"
    "$prepare_function" "$case_root/sticky-parent/update.lock" || \
        fail "$label could not repair a root-owned sticky parent"
    [ "$(stat -c '%u:%g:%a' "$case_root/sticky-parent")" = 0:0:700 ] || \
        fail "$label preserved legacy shared-directory permissions"

    mkdir -m 700 "$case_root/wrong-parent"
    if "$prepare_function" "$case_root/wrong-parent/update.lock"; then
        fail "$label accepted a non-root lock parent"
    fi

    mkdir -m 700 "$case_root/real-parent"
    ln -s real-parent "$case_root/linked-parent"
    if "$prepare_function" "$case_root/linked-parent/update.lock"; then
        fail "$label accepted a symlink lock parent"
    fi

    mkdir -m 0777 "$case_root/preoccupied-parent"
    printf '%s\n' target > "$case_root/preoccupied-target"
    chmod 0644 "$case_root/preoccupied-target"
    ln -s ../preoccupied-target "$case_root/preoccupied-parent/update.lock"
    if "$prepare_function" "$case_root/preoccupied-parent/update.lock"; then
        fail "$label accepted a preoccupied lock name"
    fi
    [ "$(stat -c '%u:%g:%a' "$case_root/preoccupied-parent")" = 0:0:700 ] || \
        fail "$label did not close a previously writable parent"
    [ "$(stat -c %a "$case_root/preoccupied-target")" = 644 ] || \
        fail "$label mutated a preoccupation target"

    # No link or special-file form may be repaired in place: rejecting before
    # chown/chmod avoids mutating an attacker-selected target.
    mkdir -m 700 "$case_root/symlink"
    target="$case_root/symlink/target"
    printf '%s\n' target > "$target"
    chmod 0644 "$target"
    ln -s target "$case_root/symlink/update.lock"
    if "$prepare_function" "$case_root/symlink/update.lock"; then
        fail "$label accepted a symlink lock"
    fi
    [ "$(stat -c %a "$target")" = 644 ] || fail "$label mutated a symlink target"

    mkdir -m 700 "$case_root/fifo"
    mkfifo "$case_root/fifo/update.lock"
    if "$prepare_function" "$case_root/fifo/update.lock"; then
        fail "$label accepted a FIFO lock"
    fi

    mkdir -m 700 "$case_root/hardlink"
    : > "$case_root/hardlink/update.lock"
    ln "$case_root/hardlink/update.lock" "$case_root/hardlink/alias.lock"
    if "$prepare_function" "$case_root/hardlink/update.lock"; then
        fail "$label accepted a multiply-linked lock"
    fi

    mkdir -m 700 "$case_root/wrong-owner"
    : > "$case_root/wrong-owner/update.lock"
    if "$prepare_function" "$case_root/wrong-owner/update.lock"; then
        fail "$label accepted a non-root lock owner"
    fi

    # The fd verifier must bind the opened descriptor to the same inode and to
    # the complete ownership/mode/link-count tuple.
    mkdir -m 700 "$case_root/fd-identity"
    lock_file="$case_root/fd-identity/update.lock"
    "$prepare_function" "$lock_file" || fail "$label could not prepare fd fixture"
    exec {fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$fd" || fail "$label rejected initial fd identity"
    chmod 0644 "$lock_file"
    if "$fd_function" "$lock_file" "$fd"; then
        fail "$label accepted unsafe fd permissions"
    fi
    chmod 0600 "$lock_file"
    mv "$lock_file" "$case_root/fd-identity/opened.lock"
    : > "$lock_file"
    chmod 0600 "$lock_file"
    chown 0:0 "$lock_file"
    if "$fd_function" "$lock_file" "$fd"; then
        fail "$label accepted a path replaced after open"
    fi
    exec {fd}>&-

    # Each helper pair must cooperate with the same kernel flock and release it
    # cleanly after both descriptors close.
    mkdir -m 700 "$case_root/contention"
    lock_file="$case_root/contention/update.lock"
    "$prepare_function" "$lock_file" || fail "$label could not prepare contention fixture"
    exec {held_fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$held_fd" || fail "$label rejected holder fd"
    flock -n "$held_fd" || fail "$label could not acquire an available lock"
    exec {contender_fd}>>"$lock_file"
    "$fd_function" "$lock_file" "$contender_fd" || fail "$label rejected contender fd"
    if flock -n "$contender_fd"; then
        fail "$label allowed a second lock holder"
    fi
    exec {contender_fd}>&-
    exec {held_fd}>&-
    exec {contender_fd}>>"$lock_file"
    flock -n "$contender_fd" || fail "$label did not release the lock after close"
    exec {contender_fd}>&-
)

printf '%s\n' '[1/6] all independently shipped Bash lock helpers enforce one contract'
run_helper_security_matrix \
    installer scripts/install-core.sh rr_prepare_update_lock_file rr_update_lock_fd_is_safe
run_helper_security_matrix \
    recovery scripts/update-recover.sh rr_prepare_update_lock_file rr_update_lock_fd_is_safe
run_helper_security_matrix \
    resilience modules/55-resilience.sh rr_secure_lock_prepare rr_secure_lock_fd_is_safe
run_helper_security_matrix \
    nexus modules/85-nexus.sh nexus_prepare_sync_lock nexus_sync_lock_fd_is_safe

printf '%s\n' '[2/6] standalone recovery distinguishes available, busy and delegated locks'
(
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_prepare_update_lock_file)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_update_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function scripts/update-recover.sh rr_acquire_update_lock)"
    rr_recover_log() { :; }

    recovery_root="$test_root/recovery-acquire"
    mkdir -m 700 "$recovery_root"
    RR_UPDATE_LOCK_FILE="$recovery_root/update.lock"
    RR_UPDATE_RECOVERY_LOCK_FD=""
    rr_acquire_update_lock || fail 'recovery rejected an available secure lock'
    [ -n "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'recovery did not retain its acquired lock fd'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_UPDATE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'recovery positive acquisition left unsafe metadata'
    exec {RR_UPDATE_RECOVERY_LOCK_FD}>&-
    RR_UPDATE_RECOVERY_LOCK_FD=""

    exec {holder_fd}>>"$RR_UPDATE_LOCK_FILE"
    flock -n "$holder_fd" || fail 'recovery busy fixture could not take lock'
    if rr_acquire_update_lock; then
        fail 'recovery ignored a busy shared lock'
    fi
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'recovery leaked a failed contender fd'
    exec {holder_fd}>&-

    delegated_target="$recovery_root/delegated-target"
    printf '%s\n' unsafe > "$delegated_target"
    ln -s delegated-target "$recovery_root/delegated.lock"
    RR_UPDATE_LOCK_FILE="$recovery_root/delegated.lock"
    RR_UPDATE_LOCK_HELD=1
    rr_acquire_update_lock || fail 'recovery rejected an explicitly delegated parent lock'
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] || fail 'delegated recovery unexpectedly opened another fd'
)

printf '%s\n' '[3/6] Nexus sync serializes callbacks, releases errors and reuses delegation'
(
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_prepare_sync_lock)"
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_sync_lock_fd_is_safe)"
    # shellcheck disable=SC2294
    eval "$(extract_function modules/85-nexus.sh nexus_with_sync_lock)"

    nexus_root="$test_root/nexus-sync"
    callback_log="$nexus_root/callback.log"
    mkdir -m 700 "$nexus_root"
    NEXUS_SYNC_LOCK_FILE="$nexus_root/sync.lock"
    NEXUS_SYNC_LOCK_WAIT_SECONDS=1

    nexus_test_callback() {
        printf '%s\n' "$1" >> "$callback_log"
        return "${2:-0}"
    }
    nexus_nested_callback() {
        nexus_with_sync_lock nexus_test_callback nested 0
    }

    nexus_with_sync_lock nexus_test_callback positive 0 || fail 'Nexus rejected available sync lock'
    grep -Fxq positive "$callback_log" || fail 'Nexus did not run locked callback'
    [ "$(stat -c '%u:%g:%a:%h' "$NEXUS_SYNC_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'Nexus created unsafe sync lock metadata'

    set +e
    nexus_with_sync_lock nexus_test_callback callback-error 23
    callback_status=$?
    set -e
    [ "$callback_status" -eq 23 ] || fail 'Nexus lost callback failure status'
    exec {after_error_fd}>>"$NEXUS_SYNC_LOCK_FILE"
    flock -n "$after_error_fd" || fail 'Nexus retained sync lock after callback failure'
    exec {after_error_fd}>&-

    : > "$callback_log"
    exec {nexus_holder_fd}>>"$NEXUS_SYNC_LOCK_FILE"
    flock -n "$nexus_holder_fd" || fail 'Nexus busy fixture could not take lock'
    set +e
    nexus_with_sync_lock nexus_test_callback should-not-run 0 >/dev/null 2>&1
    busy_status=$?
    set -e
    [ "$busy_status" -eq 75 ] || fail "Nexus busy lock returned $busy_status instead of 75"
    [ ! -s "$callback_log" ] || fail 'Nexus ran callback without acquiring busy lock'
    exec {nexus_holder_fd}>&-

    unsafe_target="$nexus_root/unsafe-target"
    printf '%s\n' unsafe > "$unsafe_target"
    ln -s unsafe-target "$nexus_root/delegated.lock"
    NEXUS_SYNC_LOCK_FILE="$nexus_root/delegated.lock"
    RR_NEXUS_SYNC_LOCK_HELD=true
    nexus_with_sync_lock nexus_nested_callback || fail 'Nexus nested delegated lock deadlocked'
    grep -Fxq nested "$callback_log" || fail 'Nexus delegated callback did not execute'
)

printf '%s\n' '[4/6] backup and restore share the update lock and delegate recovery safely'
(
    # shellcheck disable=SC1091
    source modules/55-resilience.sh
    resilience_root="$test_root/resilience-calls"
    mkdir -m 700 "$resilience_root"
    RR_RESTORE_LOCK_FILE="$resilience_root/update.lock"
    RR_BACKUP_WORK_DIR="$resilience_root/work"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    recovery_log="$resilience_root/recovery.log"
    rr_ensure_resilience_dependencies() { return 0; }
    rr_backup_prepare_work_dir() { return 0; }
    rr_backup_prune_stale_stages() { fail 'resilience test passed its stop sentinel'; }
    rr_restore_recover_active() {
        [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ] || fail 'resilience omitted lock delegation marker'
        printf '%s\n' delegated >> "$recovery_log"
        return 1
    }

    set +e
    rr_backup_create "$resilience_root/unused.rrbak" >/dev/null 2>&1
    backup_status=$?
    set -e
    [ "$backup_status" -eq 1 ] || fail 'backup positive lock sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'backup did not acquire and delegate the shared lock'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_RESTORE_LOCK_FILE")" = 0:0:600:1 ] || \
        fail 'backup call path left unsafe lock metadata'

    : > "$recovery_log"
    exec {resilience_holder_fd}>>"$RR_RESTORE_LOCK_FILE"
    flock -n "$resilience_holder_fd" || fail 'resilience busy fixture could not take lock'
    set +e
    rr_backup_create "$resilience_root/busy.rrbak" >/dev/null 2>&1
    busy_backup_status=$?
    set -e
    [ "$busy_backup_status" -eq 1 ] || fail 'backup ignored busy shared lock'
    [ ! -s "$recovery_log" ] || fail 'backup delegated recovery without owning busy lock'

    input_backup="$resilience_root/input.rrbak"
    printf '%s\n' fixture > "$input_backup"
    set +e
    rr_restore_backup "$input_backup" >/dev/null 2>&1
    busy_restore_status=$?
    set -e
    [ "$busy_restore_status" -eq 1 ] || fail 'restore ignored busy shared lock'
    [ ! -s "$recovery_log" ] || fail 'restore delegated recovery without owning busy lock'
    exec {resilience_holder_fd}>&-

    set +e
    rr_restore_backup "$input_backup" >/dev/null 2>&1
    restore_status=$?
    set -e
    [ "$restore_status" -eq 1 ] || fail 'restore positive lock sentinel returned unexpected status'
    grep -Fxq delegated "$recovery_log" || fail 'restore did not acquire and delegate the shared lock'
)

make_worker_lock_harness() {
    local output="$1" lock_path="$2"
    python3 - modules/90-auto-update.sh "$output" "$lock_path" <<'PY'
from __future__ import annotations

import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
output = pathlib.Path(sys.argv[2])
lock_path = sys.argv[3]
start_marker = "    cat > \"$worker_tmp\" <<'PYEOF'\n"
start = source.index(start_marker) + len(start_marker)
end = source.index("\n\ndef log(msg):", start)
preamble = source[start:end]
expected = 'UPDATE_LOCK_PATH = "/run/rr-vps/locks/update.lock"'
if preamble.count(expected) != 1:
    raise SystemExit("worker lock constant changed; update the security harness")
preamble = preamble.replace(expected, f'''UPDATE_LOCK_PATH = {lock_path!r}

# User namespaces used by some local runners map only uid/gid 0.  Permit the
# test harness to present alternate lstat ownership without changing worker
# logic; the normal path leaves os.lstat untouched.
_real_lstat = os.lstat
_lock_lstat_count = 0
def _fixture_lstat(path):
    global _lock_lstat_count
    if path == UPDATE_LOCK_PATH:
        _lock_lstat_count += 1
        if (
            os.environ.get("RR_LOCK_TEST_SWAP_ON_SECOND_LSTAT") == "1"
            and _lock_lstat_count == 2
        ):
            os.replace(UPDATE_LOCK_PATH + ".replacement", UPDATE_LOCK_PATH)
    result = _real_lstat(path)
    if path == os.path.dirname(UPDATE_LOCK_PATH) and os.environ.get(
        "RR_LOCK_TEST_FAKE_PARENT_UID"
    ):
        fields = list(result)
        fields[4] = int(os.environ["RR_LOCK_TEST_FAKE_PARENT_UID"])
        return os.stat_result(fields)
    if path == UPDATE_LOCK_PATH and (
        os.environ.get("RR_LOCK_TEST_FAKE_UID")
        or os.environ.get("RR_LOCK_TEST_FAKE_GID")
    ):
        fields = list(result)
        if os.environ.get("RR_LOCK_TEST_FAKE_UID"):
            fields[4] = int(os.environ["RR_LOCK_TEST_FAKE_UID"])
        if os.environ.get("RR_LOCK_TEST_FAKE_GID"):
            fields[5] = int(os.environ["RR_LOCK_TEST_FAKE_GID"])
        return os.stat_result(fields)
    return result
os.lstat = _fixture_lstat''')
preamble += '''\n\nwith open(os.environ["RR_LOCK_TEST_SENTINEL"], "w", encoding="utf-8") as sentinel:\n    sentinel.write("lock-acquired\\n")\n'''
output.write_text(preamble, encoding="utf-8")
output.chmod(0o700)
PY
}

run_worker_case() {
    local harness="$1" sentinel="$2" expected_status="$3" delegated="${4:-0}"
    local fake_uid="${5:-}" fake_gid="${6:-}" fake_parent_uid="${7:-}"
    local swap_on_second_lstat="${8:-0}"
    local worker_status=0
    rm -f -- "$sentinel"
    set +e
    RR_LOCK_TEST_SENTINEL="$sentinel" RR_WORKER_LOCK_HELD="$delegated" \
        RR_LOCK_TEST_FAKE_UID="$fake_uid" RR_LOCK_TEST_FAKE_GID="$fake_gid" \
        RR_LOCK_TEST_FAKE_PARENT_UID="$fake_parent_uid" \
        RR_LOCK_TEST_SWAP_ON_SECOND_LSTAT="$swap_on_second_lstat" \
        python3 "$harness" >/dev/null 2>&1
    worker_status=$?
    set -e
    [ "$worker_status" -eq "$expected_status" ] || \
        fail "worker returned $worker_status instead of $expected_status for $(basename "$harness")"
}

printf '%s\n' '[5/6] generated Python worker rejects hostile locks and handles busy/delegated runs'
worker_root="$test_root/worker"
mkdir -m 700 "$worker_root"

positive_parent="$worker_root/positive"
positive_lock="$positive_parent/update.lock"
positive_harness="$worker_root/positive.py"
positive_sentinel="$worker_root/positive.reached"
mkdir -m 700 "$positive_parent"
make_worker_lock_harness "$positive_harness" "$positive_lock"
run_worker_case "$positive_harness" "$positive_sentinel" 0
[ -s "$positive_sentinel" ] || fail 'worker did not proceed after acquiring available lock'
[ "$(stat -c '%u:%g:%a:%h' "$positive_lock")" = 0:0:600:1 ] || \
    fail 'worker created unsafe lock metadata'
[ "$(stat -c '%u:%g:%a' "$positive_parent")" = 0:0:700 ] || \
    fail 'worker did not create a private lock directory'
chmod 0666 "$positive_lock"
run_worker_case "$positive_harness" "$positive_sentinel" 0
[ "$(stat -c %a "$positive_lock")" = 600 ] || fail 'worker did not normalize lock mode'

sticky_parent="$worker_root/sticky"
sticky_lock="$sticky_parent/update.lock"
sticky_harness="$worker_root/sticky.py"
sticky_sentinel="$worker_root/sticky.reached"
mkdir -m 1777 "$sticky_parent"
make_worker_lock_harness "$sticky_harness" "$sticky_lock"
run_worker_case "$sticky_harness" "$sticky_sentinel" 0
[ -s "$sticky_sentinel" ] || fail 'worker rejected root-owned sticky lock parent'
[ "$(stat -c '%u:%g:%a' "$sticky_parent")" = 0:0:700 ] || \
    fail 'worker did not privatize legacy sticky lock parent'

writable_parent="$worker_root/writable-parent"
writable_harness="$worker_root/writable-parent.py"
writable_sentinel="$worker_root/writable-parent.reached"
mkdir -m 0777 "$writable_parent"
make_worker_lock_harness "$writable_harness" "$writable_parent/update.lock"
run_worker_case "$writable_harness" "$writable_sentinel" 0
[ -s "$writable_sentinel" ] || fail 'worker could not repair root-owned writable parent'
[ "$(stat -c '%u:%g:%a' "$writable_parent")" = 0:0:700 ] || \
    fail 'worker left a writable lock parent'

preoccupied_parent="$worker_root/preoccupied-parent"
preoccupied_lock="$preoccupied_parent/update.lock"
preoccupied_target="$worker_root/preoccupied-target"
preoccupied_harness="$worker_root/preoccupied-parent.py"
preoccupied_sentinel="$worker_root/preoccupied-parent.reached"
mkdir -m 0777 "$preoccupied_parent"
printf '%s\n' target > "$preoccupied_target"
chmod 0644 "$preoccupied_target"
ln -s ../preoccupied-target "$preoccupied_lock"
make_worker_lock_harness "$preoccupied_harness" "$preoccupied_lock"
run_worker_case "$preoccupied_harness" "$preoccupied_sentinel" 1
[ ! -e "$preoccupied_sentinel" ] || fail 'worker accepted a preoccupied lock name'
[ "$(stat -c '%u:%g:%a' "$preoccupied_parent")" = 0:0:700 ] || \
    fail 'worker did not close a previously writable parent'
[ "$(stat -c %a "$preoccupied_target")" = 644 ] || \
    fail 'worker mutated a preoccupation target'

linked_real_parent="$worker_root/linked-real-parent"
linked_parent="$worker_root/linked-parent"
linked_harness="$worker_root/linked-parent.py"
linked_sentinel="$worker_root/linked-parent.reached"
mkdir -m 700 "$linked_real_parent"
ln -s linked-real-parent "$linked_parent"
make_worker_lock_harness "$linked_harness" "$linked_parent/update.lock"
run_worker_case "$linked_harness" "$linked_sentinel" 1
[ ! -e "$linked_sentinel" ] || fail 'worker proceeded through symlink lock parent'

foreign_parent="$worker_root/foreign-parent"
foreign_harness="$worker_root/foreign-parent.py"
foreign_sentinel="$worker_root/foreign-parent.reached"
mkdir -m 700 "$foreign_parent"
make_worker_lock_harness "$foreign_harness" "$foreign_parent/update.lock"
run_worker_case "$foreign_harness" "$foreign_sentinel" 1 0 '' '' 65534
[ ! -e "$foreign_sentinel" ] || fail 'worker proceeded through non-root lock parent'

for hostile_type in symlink fifo hardlink wrong-owner wrong-group; do
    hostile_parent="$worker_root/$hostile_type"
    hostile_lock="$hostile_parent/update.lock"
    hostile_harness="$worker_root/$hostile_type.py"
    hostile_sentinel="$worker_root/$hostile_type.reached"
    mkdir -m 700 "$hostile_parent"
    case "$hostile_type" in
        symlink)
            printf '%s\n' target > "$hostile_parent/target"
            ln -s target "$hostile_lock"
            ;;
        fifo) mkfifo "$hostile_lock" ;;
        hardlink)
            : > "$hostile_lock"
            ln "$hostile_lock" "$hostile_parent/alias.lock"
            ;;
        wrong-owner)
            : > "$hostile_lock"
            ;;
        wrong-group)
            : > "$hostile_lock"
            ;;
    esac
    make_worker_lock_harness "$hostile_harness" "$hostile_lock"
    case "$hostile_type" in
        wrong-owner) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 0 65534 ;;
        wrong-group) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 0 '' 65534 ;;
        *) run_worker_case "$hostile_harness" "$hostile_sentinel" 1 ;;
    esac
    [ ! -e "$hostile_sentinel" ] || fail "worker proceeded through $hostile_type lock"
done

swap_parent="$worker_root/inode-swap"
swap_lock="$swap_parent/update.lock"
swap_harness="$worker_root/inode-swap.py"
swap_sentinel="$worker_root/inode-swap.reached"
mkdir -m 700 "$swap_parent"
printf '%s\n' original > "$swap_lock"
printf '%s\n' replacement > "$swap_lock.replacement"
chmod 0600 "$swap_lock" "$swap_lock.replacement"
make_worker_lock_harness "$swap_harness" "$swap_lock"
run_worker_case "$swap_harness" "$swap_sentinel" 1 0 '' '' '' 1
[ ! -e "$swap_sentinel" ] || fail 'worker accepted an inode replaced after open'
grep -Fxq replacement "$swap_lock" || fail 'worker inode-swap fixture did not execute'

busy_parent="$worker_root/busy"
busy_lock="$busy_parent/update.lock"
busy_harness="$worker_root/busy.py"
busy_sentinel="$worker_root/busy.reached"
mkdir -m 700 "$busy_parent"
: > "$busy_lock"
chmod 0600 "$busy_lock"
make_worker_lock_harness "$busy_harness" "$busy_lock"
exec {worker_holder_fd}>>"$busy_lock"
flock -n "$worker_holder_fd" || fail 'worker busy fixture could not take lock'
run_worker_case "$busy_harness" "$busy_sentinel" 0
[ ! -e "$busy_sentinel" ] || fail 'busy standalone worker performed post-lock work'

run_worker_case "$busy_harness" "$busy_sentinel" 0 1
[ -s "$busy_sentinel" ] || fail 'delegated worker did not reuse its parent lock'
exec {worker_holder_fd}>&-

printf '%s\n' '[6/6] production call sites preserve shared-lock and worker delegation wiring'
assert_fd_helper_contract() {
    local source_file="$1" function_name="$2" body=""
    body=$(extract_function "$source_file" "$function_name")
    grep -Fq 'local shell_pid="${BASHPID:-$$}"' <<< "$body" || \
        fail "$source_file expands BASHPID inside command substitution"
    grep -Fq 'local fd_path="/proc/$shell_pid/fd/$lock_fd"' <<< "$body" || \
        fail "$source_file does not bind fd inspection to the caller shell"
    grep -Fq '[ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"' <<< "$body" || \
        fail "$source_file lacks procfs namespace fallback for fd inspection"
    grep -Fq 'stat -Lc' <<< "$body" && grep -Fq -- '"$fd_path"' <<< "$body" || \
        fail "$source_file does not stat the precomputed fd path"
}

assert_fd_helper_contract scripts/install-core.sh rr_update_lock_fd_is_safe
assert_fd_helper_contract scripts/update-recover.sh rr_update_lock_fd_is_safe
assert_fd_helper_contract modules/55-resilience.sh rr_secure_lock_fd_is_safe
assert_fd_helper_contract modules/85-nexus.sh nexus_sync_lock_fd_is_safe

grep -Fq 'RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    scripts/install-core.sh || fail 'installer default shared lock path regressed'
grep -Fq 'RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    scripts/update-recover.sh || fail 'recovery default shared lock path regressed'
grep -Fq 'RR_RESTORE_LOCK_FILE="${RR_RESTORE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"' \
    modules/55-resilience.sh || fail 'backup/restore default shared lock path regressed'
grep -Fq 'NEXUS_SYNC_LOCK_FILE="${RR_NEXUS_SYNC_LOCK_FILE:-/run/rr-vps/locks/nexus-sync.lock}"' \
    modules/85-nexus.sh || fail 'Nexus default sync lock path regressed'
grep -Fq 'UPDATE_LOCK_PATH = "/run/rr-vps/locks/update.lock"' modules/90-auto-update.sh || \
    fail 'worker default shared lock path regressed'
if rg -q '/run/lock/rr-update\.lock' \
    scripts/install-core.sh scripts/update-recover.sh modules/55-resilience.sh \
    modules/60-update.sh modules/85-nexus.sh modules/90-auto-update.sh; then
    fail 'legacy publicly writable /run/lock update path remains in a transaction caller'
fi
grep -Fq 'rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE"' scripts/install-core.sh || \
    fail 'installer no longer prepares the configured shared update lock'
grep -Fq 'rr_update_lock_fd_is_safe "$RR_UPDATE_LOCK_FILE" "$UPDATE_LOCK_FD"' \
    scripts/install-core.sh || fail 'installer no longer validates opened lock identity'
grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$RR_RECOVERY_HELPER" recover' scripts/install-core.sh || \
    fail 'installer recovery delegation marker is missing'
grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$RR_LAUNCHER" --health-check' scripts/install-core.sh || \
    fail 'installer health-check delegation marker is missing'
grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$RR_LAUNCHER" --post-update' scripts/install-core.sh || \
    fail 'installer post-update delegation marker is missing'
grep -Fq 'RR_RESTORE_LOCK_HELD=1 rr_restore_recover_active' modules/55-resilience.sh || \
    fail 'backup/watchdog recovery delegation marker is missing'
grep -Fq 'local RR_NEXUS_SYNC_LOCK_HELD=true' modules/85-nexus.sh || \
    fail 'Nexus nested sync delegation marker is missing'
grep -Fq 'RR_WORKER_LOCK_HELD=1 python3 /usr/local/bin/auto_update_sub.py' modules/60-update.sh || \
    fail 'post-update worker delegation marker is missing'

printf '%s\n' 'update lock security regressions: PASS'
