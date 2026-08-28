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

printf '%s\n' '[1/6] a normal health pass owns the root-only shared transaction lock'
rr_run_health_check
[ "$(cat "$health_runs")" = 1 ] || fail 'normal health pass did not receive delegated lock ownership'
[ -d "$TEST_ROOT/locks" ] || fail 'root-only lock directory was not created'
[ "$(stat -c '%u:%g:%a' "$TEST_ROOT/locks")" = 0:0:700 ] || fail 'lock directory mode/owner is unsafe'
[ "$(stat -c '%u:%g:%a:%h' "$RR_RESTORE_LOCK_FILE")" = 0:0:600:1 ] || fail 'lock file mode/owner/link count is unsafe'

printf '%s\n' '[2/6] a timer firing during update/backup skips without mutating or retry-failing'
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

printf '%s\n' '[3/6] an installer re-entry must explicitly delegate its already-held lock'
RR_UPDATE_LOCK_HELD=1 rr_run_health_check
[ "$(cat "$health_runs")" = 1 ] || fail 'delegated installer re-entry did not run the health body'
: > "$TEST_ROOT/release-holder"
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""

printf '%s\n' '[4/6] an unsafe lock path fails closed before health mutations'
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
eval "$(extract_function rr_freeze_health_monitor)"
eval "$(extract_function rr_resume_health_monitor_after_abort)"
eval "$(extract_function rr_snapshot_runtime)"
declare -F rr_freeze_health_monitor >/dev/null || fail 'installer freeze helper is missing'
declare -F rr_snapshot_runtime >/dev/null || fail 'installer snapshot function is missing'

printf '%s\n' '[5/6] installer stops timer and in-flight service before its first snapshot read'
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
    case "${1:-} ${2:-} ${3:-}" in
        'is-enabled --quiet argo-rr-health.timer')
            [ "$mock_timer_enabled" = true ]
            ;;
        'is-active --quiet argo-rr-health.timer')
            [ "$mock_timer_active" = true ]
            ;;
        'is-active --quiet argo-rr-health.service')
            [ "$mock_service_active" = true ]
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

printf '%s\n' '[6/6] a pre-switch abort restores the timer and production call sites delegate re-entry'
: > "$RR_HEALTH_TIMER_FILE"
rr_resume_health_monitor_after_abort || fail 'abort did not restore the enabled health timer'
[ "$RR_HEALTH_MONITOR_FROZEN" = false ] || fail 'abort left health monitor marked frozen'
grep -Fxq resume-health "$operation_log" || fail 'abort never re-enabled the saved timer state'
grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$RR_LAUNCHER" --health-check' "$REPO_ROOT/scripts/install-core.sh" || \
    fail 'installer rollback no longer delegates the shared lock to health re-entry'
grep -Fq 'RR_UPDATE_LOCK_HELD=1 "$RR_LAUNCHER" --post-update' "$REPO_ROOT/scripts/install-core.sh" || \
    fail 'installer migration re-entry no longer declares shared-lock ownership'
grep -Fq 'rr_run_health_check' "$REPO_ROOT/rr" || fail 'launcher health entry bypasses the lock wrapper'

printf '%s\n' 'health transaction lock regression: PASS'
