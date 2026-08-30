#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-health-lock-test.XXXXXX)
LOCK_HOLDER_PID=""

cleanup() {
    if [ -n "$LOCK_HOLDER_PID" ]; then
        kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
        wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'health transaction lock regression: FAIL: %s\n' "$*" >&2
    exit 1
}

# These module files only declare constants and functions when sourced.  The
# real secure-lock implementation is used; only the health body is replaced by
# an observable stub.
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/55-resilience.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/60-update.sh"

RR_RESTORE_LOCK_FILE="$TEST_ROOT/locks/update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/legacy/rr-update.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/bridge/legacy-update-bridge"
mkdir -p "$(dirname "$RR_LEGACY_UPDATE_LOCK_FILE")"
: > "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
install -d -m 700 "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
printf '%s\n' "$RR_LEGACY_UPDATE_BRIDGE_VALUE" > "$RR_LEGACY_UPDATE_BRIDGE_FILE"
chmod 0600 "$RR_LEGACY_UPDATE_BRIDGE_FILE"
health_runs="$TEST_ROOT/health-runs"
health_logs="$TEST_ROOT/health-logs"
: > "$health_runs"
: > "$health_logs"

rr_health_log() {
    printf '%s\n' "$*" >> "$health_logs"
}

ensure_runtime_health() {
    printf '%s\n' "${RR_UPDATE_LOCK_HELD:-0}" >> "$health_runs"
}

printf '%s\n' '[1/9] a normal health pass owns the root-only shared transaction lock'
rr_run_health_check
[ "$(cat "$health_runs")" = 1 ] || fail 'normal health pass did not receive delegated lock ownership'
[ -d "$TEST_ROOT/locks" ] || fail 'root-only lock directory was not created'
[ "$(stat -c '%u:%g:%a' "$TEST_ROOT/locks")" = 0:0:700 ] || fail 'lock directory mode/owner is unsafe'
[ "$(stat -c '%u:%g:%a:%h' "$RR_RESTORE_LOCK_FILE")" = 0:0:600:1 ] || fail 'lock file mode/owner/link count is unsafe'

printf '%s\n' '[2/9] a timer firing during update/backup skips without mutating or retry-failing'
: > "$health_runs"
(
    exec 8>>"$RR_RESTORE_LOCK_FILE"
    flock 8
    : > "$TEST_ROOT/holder-ready"
    while [ ! -e "$TEST_ROOT/release-holder" ]; do
        sleep 0.05
    done
) &
LOCK_HOLDER_PID=$!
for _ in $(seq 1 100); do
    [ -e "$TEST_ROOT/holder-ready" ] && break
    sleep 0.02
done
[ -e "$TEST_ROOT/holder-ready" ] || fail 'could not establish a competing transaction lock'
rr_run_health_check || fail 'busy transaction lock should be an expected health skip'
[ ! -s "$health_runs" ] || fail 'health body ran while another transaction owned the lock'

printf '%s\n' '[3/9] an installer re-entry must explicitly delegate its already-held lock'
RR_UPDATE_LOCK_HELD=1 rr_run_health_check
[ "$(cat "$health_runs")" = 1 ] || fail 'delegated installer re-entry did not run the health body'
: > "$TEST_ROOT/release-holder"
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""

printf '%s\n' '[4/9] a nohup child cannot inherit either transaction lock fd'
nohup_pid_file="$TEST_ROOT/nohup.pid"
ensure_runtime_health() {
    nohup bash -c 'printf "%s\n" "$$" > "$1"; sleep 30' _ "$nohup_pid_file" \
        >/dev/null 2>&1 &
}
rr_run_health_check || fail 'health pass with a nohup child failed'
for _ in $(seq 1 100); do
    [ -s "$nohup_pid_file" ] && break
    sleep 0.02
done
[ -s "$nohup_pid_file" ] || fail 'nohup inheritance fixture did not start'
nohup_pid=$(cat "$nohup_pid_file")
kill -0 "$nohup_pid" 2>/dev/null || fail 'nohup child exited before lock contention proof'
flock -n "$RR_RESTORE_LOCK_FILE" -c true || fail 'nohup child inherited the new update lock fd'
flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" -c true || fail 'nohup child inherited the legacy update lock fd'
kill "$nohup_pid" >/dev/null 2>&1 || true

printf '%s\n' '[5/9] an unsafe lock path fails closed before health mutations'
: > "$health_runs"
mkdir -p "$TEST_ROOT/unsafe"
ln -s "$TEST_ROOT/attacker-target" "$TEST_ROOT/unsafe/update.lock"
RR_RESTORE_LOCK_FILE="$TEST_ROOT/unsafe/update.lock"
if rr_run_health_check; then
    fail 'symlink lock path was accepted'
fi
[ ! -s "$health_runs" ] || fail 'health body ran through an unsafe lock path'
[ -s "$health_logs" ] || fail 'unsafe lock rejection was not recorded'

extract_function() {
    local name="$1"
    awk -v function_name="$name" '
        $0 ~ ("^" function_name "\\(\\) \\{") { copying=1 }
        copying {
            print
            line=$0
            opens=gsub(/\{/, "", line)
            line=$0
            closes=gsub(/\}/, "", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$REPO_ROOT/scripts/install-core.sh"
}

# Load just the installer helpers; sourcing install-core.sh itself would run an
# install.  This also makes accidental removal/renaming of the functions fail.
eval "$(extract_function rr_unit_activity_matches)"
eval "$(extract_function rr_unit_file_state_matches)"
eval "$(extract_function rr_capture_unit_activity_state)"
eval "$(extract_function rr_capture_unit_file_state)"
eval "$(extract_function rr_freeze_health_monitor)"
eval "$(extract_function rr_resume_health_monitor_after_abort)"
eval "$(extract_function rr_snapshot_runtime)"
declare -F rr_freeze_health_monitor >/dev/null || fail 'installer freeze helper is missing'
declare -F rr_snapshot_runtime >/dev/null || fail 'installer snapshot function is missing'

printf '%s\n' '[6/9] installer stops timer and in-flight service before its first snapshot read'
RR_TX_ROOT="$TEST_ROOT/transactions-root"
RR_ACTIVE_TX="$RR_TX_ROOT/active"
RR_LIB_DIR="$TEST_ROOT/live-runtime"
RR_LAUNCHER="$TEST_ROOT/rr"
RR_HEALTH_MONITOR_FROZEN=false
RR_HEALTH_TIMER_WAS_ENABLED=false
RR_HEALTH_TIMER_FILE="$TEST_ROOT/argo-rr-health.timer"
mkdir -p "$RR_TX_ROOT/transactions" "$RR_LIB_DIR"
operation_log="$TEST_ROOT/installer-operations"
: > "$operation_log"
mock_timer_enabled=true
mock_timer_active=true
mock_service_active=true

systemctl() {
    case "$*" in
        'show --property=LoadState --value argo-rr-health.timer'|\
        'show --property=LoadState --value argo-rr-health.service')
            printf '%s\n' loaded
            ;;
        'show --property=UnitFileState --value argo-rr-health.timer')
            [ "$mock_timer_enabled" = true ] && printf '%s\n' enabled || printf '%s\n' disabled
            ;;
        'show --property=ActiveState --value argo-rr-health.timer')
            [ "$mock_timer_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
            ;;
        'show --property=ActiveState --value argo-rr-health.service')
            [ "$mock_service_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
            ;;
        'stop argo-rr-health.timer argo-rr-health.service')
            printf '%s\n' stop-health >> "$operation_log"
            mock_timer_active=false
            mock_service_active=false
            ;;
        'enable --now argo-rr-health.timer')
            printf '%s\n' resume-health >> "$operation_log"
            mock_timer_enabled=true
            mock_timer_active=true
            ;;
        'disable --now argo-rr-health.timer')
            printf '%s\n' disable-health >> "$operation_log"
            mock_timer_enabled=false
            mock_timer_active=false
            ;;
        *) return 1 ;;
    esac
}
rr_error() { printf 'error:%s\n' "$*" >> "$operation_log"; }
rr_prepare_recovery_runtime() { printf '%s\n' prepare-recovery >> "$operation_log"; }
rr_discard_previous_transaction() { printf '%s\n' recover-old >> "$operation_log"; }
rr_prune_stale_transactions() { printf '%s\n' prune-old >> "$operation_log"; }
rr_write_transaction_format() { printf '%s\n' transaction-format >> "$operation_log"; }
rr_write_phase() { printf 'phase:%s\n' "$1" >> "$operation_log"; }
rr_snapshot_external_state() { printf '%s\n' snapshot-external >> "$operation_log"; }
rr_backup_file() { printf 'backup-file:%s\n' "$2" >> "$operation_log"; }
rr_backup_dir() { printf 'backup-dir:%s\n' "$2" >> "$operation_log"; }
rr_backup_sqlite() { printf 'backup-sqlite:%s\n' "$2" >> "$operation_log"; }
rr_subscription_running() { return 1; }
pgrep() { return 1; }

rr_snapshot_runtime || fail 'isolated installer snapshot failed'
first_stop=$(grep -n '^stop-health$' "$operation_log" | head -n 1 | cut -d: -f1)
external_snapshot=$(grep -n '^snapshot-external$' "$operation_log" | head -n 1 | cut -d: -f1)
first_backup=$(grep -n '^backup-' "$operation_log" | head -n 1 | cut -d: -f1)
[[ "$first_stop" =~ ^[0-9]+$ && "$external_snapshot" =~ ^[0-9]+$ && \
   "$first_backup" =~ ^[0-9]+$ ]] || fail 'snapshot ordering evidence is incomplete'
[ "$first_stop" -lt "$first_backup" ] || fail 'installer read snapshot data before freezing health writers'
[ "$first_stop" -lt "$external_snapshot" ] && [ "$external_snapshot" -lt "$first_backup" ] || \
    fail 'external state was not snapshotted between writer freeze and internal file reads'
[ -f "$BACKUP_DIR/health_timer_was_enabled" ] || fail 'snapshot lost the pre-update timer enabled state'
[ "$RR_HEALTH_MONITOR_FROZEN" = true ] || fail 'snapshot did not retain frozen state through switching'

printf '%s\n' '[7/9] a pre-switch abort restores the timer and production call sites delegate re-entry'
: > "$RR_HEALTH_TIMER_FILE"
rr_resume_health_monitor_after_abort || fail 'abort did not restore the enabled health timer'
[ "$RR_HEALTH_MONITOR_FROZEN" = false ] || fail 'abort left health monitor marked frozen'
grep -Fxq resume-health "$operation_log" || fail 'abort never re-enabled the saved timer state'
grep -Fq 'rr_resume_subscription_bounded' "$REPO_ROOT/scripts/install-core.sh" && \
grep -Fq '"$RR_LAUNCHER" --refresh-subscription' "$REPO_ROOT/scripts/install-core.sh" || \
    fail 'installer rollback no longer uses bounded subscription re-entry'
grep -Fq '"$RR_LAUNCHER" --post-update' "$REPO_ROOT/scripts/install-core.sh" || \
    fail 'installer migration re-entry no longer declares shared-lock ownership'
grep -Fq 'rr_run_health_check' "$REPO_ROOT/rr" || fail 'launcher health entry bypasses the lock wrapper'

printf '%s\n' '[8/9] a failed subscription resume re-freezes a restored health timer'
eval "$(extract_function rr_close_inherited_installer_lock_fds)"
eval "$(extract_function rr_resume_subscription_bounded)"
eval "$(extract_function rr_restore_update_writer_state)"
resume_failure_root="$TEST_ROOT/resume-failure"
resume_failure_backup="$resume_failure_root/backup"
resume_failure_launcher="$resume_failure_root/launcher"
resume_failure_log="$resume_failure_root/launcher.log"
resume_failure_stopped="$resume_failure_root/subscription-stopped"
resume_failure_quiesced="$resume_failure_root/health-quiesced"
mkdir -p "$resume_failure_backup"
: > "$resume_failure_backup/subscription_was_running"
: > "$resume_failure_backup/health_timer_was_running"
: > "$resume_failure_backup/health_timer_was_enabled"
printf '%s\n' '#!/bin/bash' \
    'printf "%s|%s\n" "${RR_UPDATE_LOCK_HELD:-0}" "$*" > "$RR_RESUME_FAILURE_LOG"' \
    'exit 0' > "$resume_failure_launcher"
chmod 700 "$resume_failure_launcher"
export RR_RESUME_FAILURE_LOG="$resume_failure_log"
RR_LAUNCHER="$resume_failure_launcher"
resume_health_active=false
rr_restore_unit_state() {
    if [ "$1" = argo-rr-health.timer ]; then
        resume_health_active=true
    fi
}
rr_restart_health_service_bounded() { :; }
rr_subscription_running() { return 1; }
rr_stop_subscription_servers() { : > "$resume_failure_stopped"; }
rr_quiesce_health_monitor_for_rollback() {
    resume_health_active=false
    : > "$resume_failure_quiesced"
}
if rr_restore_update_writer_state "$resume_failure_backup" normal; then
    fail 'a false-success subscription refresh was accepted by installer rollback'
fi
[ "$(cat "$resume_failure_log")" = '1|--refresh-subscription' ] ||
    fail 'installer rollback used the wrong subscription resume contract'
[ "$resume_health_active" = false ] && [ -e "$resume_failure_quiesced" ] ||
    fail 'subscription resume failure left the restored health timer active'
[ -e "$resume_failure_stopped" ] ||
    fail 'subscription resume failure did not stop a partial managed worker'

printf '%s\n' '[9/9] bounded background workers cannot orphan installer lock descriptors'
eval "$(extract_function rr_restart_health_service_bounded)"
async_root="$TEST_ROOT/installer-async"
async_new_lock="$async_root/update.lock"
async_legacy_lock="$async_root/legacy.lock"
async_launcher="$async_root/launcher"
mkdir -p "$async_root"
: > "$async_new_lock"
: > "$async_legacy_lock"
chmod 600 "$async_new_lock" "$async_legacy_lock"
printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" "$$" > "$RR_ASYNC_CHILD_PID"' \
    'printf "%s|%s\n" "${RR_UPDATE_LOCK_HELD:-0}" "$*" > "$RR_ASYNC_ARGS"' \
    ': > "$RR_ASYNC_STARTED"' \
    'while [ ! -e "$RR_ASYNC_RELEASE" ]; do sleep 0.05; done' \
    > "$async_launcher"
chmod 700 "$async_launcher"

run_async_lock_case() {
    local mode="$1" started="" release="" child_pid_file="" args_file=""
    local parent_pid="" child_pid="" parent_status=0
    local new_released=false legacy_released=false
    started="$async_root/${mode}.started"
    release="$async_root/${mode}.release"
    child_pid_file="$async_root/${mode}.pid"
    args_file="$async_root/${mode}.args"
    rm -f -- "$started" "$release" "$child_pid_file" "$args_file"
    export RR_ASYNC_STARTED="$started" RR_ASYNC_RELEASE="$release" \
        RR_ASYNC_CHILD_PID="$child_pid_file" RR_ASYNC_ARGS="$args_file"
    (
        exec {UPDATE_LOCK_FD}>>"$async_new_lock"
        flock "$UPDATE_LOCK_FD"
        exec {LEGACY_UPDATE_LOCK_FD}<"$async_legacy_lock"
        flock "$LEGACY_UPDATE_LOCK_FD"
        if [ "$mode" = subscription ]; then
            RR_LAUNCHER="$async_launcher"
            rr_subscription_running() { return 0; }
            rr_stop_subscription_servers() { :; }
            rr_resume_subscription_bounded
        else
            rr_restart_health_service_bounded
        fi
    ) &
    parent_pid=$!
    for _ in $(seq 1 200); do
        [ -e "$started" ] && [ -s "$child_pid_file" ] && break
        sleep 0.02
    done
    [ -e "$started" ] && [ -s "$child_pid_file" ] || {
        kill "$parent_pid" >/dev/null 2>&1 || true
        fail "$mode bounded worker did not start"
    }
    if [ "$mode" = subscription ]; then
        [ "$(cat "$args_file")" = '1|--refresh-subscription' ] ||
            fail 'bounded subscription resume used the wrong launcher contract'
    fi
    child_pid=$(cat "$child_pid_file")
    kill -KILL "$parent_pid"
    set +e
    wait "$parent_pid" 2>/dev/null
    parent_status=$?
    set -e
    [ "$parent_status" -eq 137 ] || fail "$mode parent was not killed at the intended boundary"
    # A polling sleep already forked by the killed wrapper may live for at
    # most one 0.1-second interval.  The actual delegated worker remains
    # blocked until release, so a bounded retry distinguishes the two.
    for _ in $(seq 1 50); do
        flock -n "$async_new_lock" -c true && new_released=true
        flock -n "$async_legacy_lock" -c true && legacy_released=true
        [ "$new_released" = true ] && [ "$legacy_released" = true ] && break
        sleep 0.02
    done
    [ "$new_released" = true ] || fail "$mode orphan retained the new transaction lock"
    [ "$legacy_released" = true ] || fail "$mode orphan retained the legacy transaction lock"
    : > "$release"
    for _ in $(seq 1 200); do
        kill -0 "$child_pid" 2>/dev/null || break
        sleep 0.02
    done
    kill "$child_pid" >/dev/null 2>&1 || true
}

run_async_lock_case subscription
systemctl() {
    case "$*" in
        'start argo-rr-health.service')
            printf '%s\n' "$BASHPID" > "$RR_ASYNC_CHILD_PID"
            : > "$RR_ASYNC_STARTED"
            while [ ! -e "$RR_ASYNC_RELEASE" ]; do sleep 0.05; done
            ;;
        *) return 0 ;;
    esac
}
run_async_lock_case systemctl

printf '%s\n' 'health transaction lock regression: PASS'
