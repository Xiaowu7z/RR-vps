#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-update-writers.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'update writer freeze regression: FAIL: %s\n' "$*" >&2
    exit 1
}

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

printf '%s\n' '[1/8] an all-inactive writer snapshot is a successful state capture'
eval "$(extract_function rr_capture_update_writer_state)"
systemctl() { return 1; }
rr_subscription_running() { return 1; }
RR_HEALTH_STATE_CAPTURED=false
rr_capture_update_writer_state || fail 'inactive writers were reported as a snapshot failure'
[ "$RR_HEALTH_STATE_CAPTURED" = true ] || fail 'health state was not marked captured'
[ "$RR_HEALTH_TIMER_WAS_ENABLED" = false ] && \
    [ "$RR_HEALTH_TIMER_WAS_ACTIVE" = false ] && \
    [ "$RR_HEALTH_SERVICE_WAS_ACTIVE" = false ] && \
    [ "$RR_SINGBOX_WAS_ACTIVE" = false ] && \
    [ "$RR_SINGBOX_WAS_ENABLED" = false ] && \
    [ "$RR_NEXUS_WAS_ACTIVE" = false ] && \
    [ "$RR_NEXUS_WAS_ENABLED" = false ] && \
    [ "$RR_SUBSCRIPTION_WAS_ACTIVE" = false ] || \
    fail 'inactive writer state was not preserved exactly'

printf '%s\n' '[2/8] repeated health freezes preserve the first observed enabled state'
eval "$(extract_function rr_freeze_health_monitor)"
RR_HEALTH_MONITOR_FROZEN=false
RR_HEALTH_TIMER_WAS_ENABLED=false
RR_HEALTH_TIMER_WAS_ACTIVE=false
RR_HEALTH_SERVICE_WAS_ACTIVE=false
RR_HEALTH_STATE_CAPTURED=false
health_enabled=true
health_timer_active=true
health_service_active=true
systemctl() {
    case "$*" in
        'is-enabled --quiet argo-rr-health.timer') [ "$health_enabled" = true ] ;;
        'is-active --quiet argo-rr-health.timer') [ "$health_timer_active" = true ] ;;
        'is-active --quiet argo-rr-health.service') [ "$health_service_active" = true ] ;;
        'stop argo-rr-health.timer argo-rr-health.service')
            health_timer_active=false
            health_service_active=false
            ;;
        *) return 1 ;;
    esac
}
rr_error() { :; }
rr_freeze_health_monitor
health_enabled=false
rr_freeze_health_monitor
[ "$RR_HEALTH_TIMER_WAS_ENABLED" = true ] || fail 'second freeze overwrote the initial enabled state'

snapshot_body=$(awk '/^rr_snapshot_runtime\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' \
    "$REPO_ROOT/scripts/install-core.sh")
freeze_line=$(printf '%s\n' "$snapshot_body" | grep -n 'rr_freeze_update_writers' | head -n1 | cut -d: -f1)
active_line=$(printf '%s\n' "$snapshot_body" | grep -n 'mv -f .*RR_ACTIVE_TX' | head -n1 | cut -d: -f1)
external_line=$(printf '%s\n' "$snapshot_body" | grep -n 'rr_snapshot_external_state' | head -n1 | cut -d: -f1)
key_line=$(printf '%s\n' "$snapshot_body" | grep -n 'remote.key remote.key' | head -n1 | cut -d: -f1)
db_line=$(printf '%s\n' "$snapshot_body" | grep -n 'rr_backup_sqlite .*nexus.db' | head -n1 | cut -d: -f1)
[[ "$active_line" =~ ^[0-9]+$ && "$freeze_line" =~ ^[0-9]+$ && \
   "$external_line" =~ ^[0-9]+$ && "$key_line" =~ ^[0-9]+$ && \
   "$db_line" =~ ^[0-9]+$ ]] || \
    fail 'snapshot ordering evidence is incomplete'
[ "$active_line" -lt "$freeze_line" ] || fail 'a writer can be stopped before the recoverable active pointer exists'
[ "$freeze_line" -lt "$key_line" ] && [ "$freeze_line" -lt "$db_line" ] || \
    fail 'Nexus key/database are copied before writers are frozen'
[ "$freeze_line" -lt "$external_line" ] && [ "$external_line" -lt "$key_line" ] && \
    [ "$external_line" -lt "$db_line" ] || \
    fail 'external state snapshot is not between writer freeze and sensitive internal copies'

run_recovery_case() (
    local case_name="$1" wanted_failure="${2:-false}"
    local recovery_phase="${3:-snapshotting}"
    local precreated="${4:-false}"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_TX_ROOT="$TEST_ROOT/$case_name/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_LIB_DIR="$TEST_ROOT/$case_name/runtime"
    export RR_LAUNCHER="$TEST_ROOT/$case_name/rr"
    export RR_CONFIG_FILE="$TEST_ROOT/$case_name/config"
    export RR_QUARANTINE_FILE="$RR_TX_ROOT/quarantine"
    export RR_QUARANTINE_UNIT="$TEST_ROOT/$case_name/quarantine.service"
    export RR_QUARANTINE_READY="$TEST_ROOT/$case_name/quarantine.ready"
    export RR_UPDATE_LOCK_HELD=1
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/$case_name/run/update-maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"

    declare -A active=([sing-box]=false [rr-nexus]=false [argo-rr-health.timer]=false)
    declare -A enabled=([sing-box]=false [rr-nexus]=false [argo-rr-health.timer]=false)
    operation_log="$TEST_ROOT/$case_name/operations"
    mkdir -p "$RR_TX_ROOT/transactions" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    : > "$operation_log"
    if [ "$recovery_phase" = state_recorded ]; then
        active[rr-nexus]=true
        enabled[rr-nexus]=true
        active[argo-rr-health.timer]=true
        enabled[argo-rr-health.timer]=true
    fi

    systemctl() {
        local command="${1:-}" option="${2:-}" unit="${3:-}"
        printf '%s\n' "$*" >> "$operation_log"
        case "$command $option" in
            'is-active --quiet') [ "${active[$unit]:-false}" = true ] ;;
            'is-enabled --quiet') [ "${enabled[$unit]:-false}" = true ] ;;
            'enable rr-nexus'|'enable sing-box'|'enable argo-rr-health.timer')
                unit="$option"; enabled[$unit]=true ;;
            'disable rr-nexus'|'disable sing-box'|'disable argo-rr-health.timer')
                unit="$option"; enabled[$unit]=false ;;
            'restart rr-nexus'|'restart sing-box'|'restart argo-rr-health.timer')
                unit="$option"
                if [ "$wanted_failure" = true ] && [ "$unit" = rr-nexus ]; then
                    return 1
                fi
                active[$unit]=true
                ;;
            'stop rr-nexus'|'stop sing-box'|'stop argo-rr-health.timer')
                unit="$option"; active[$unit]=false ;;
            'start --no-block') return 0 ;;
            *) return 0 ;;
        esac
    }
    rr_stop_subscription_servers() { return 0; }
    rr_subscription_running() { return 1; }
    sleep() { :; }

    tx="$RR_TX_ROOT/transactions/tx"
    if [ "$precreated" != true ]; then
        mkdir -p "$tx/backup"
        chmod 700 "$tx" "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
        : > "$tx/backup/writer_state_complete"
        : > "$tx/backup/nexus_was_running"
        : > "$tx/backup/nexus_was_enabled"
        : > "$tx/backup/health_timer_was_running"
        : > "$tx/backup/health_timer_was_enabled"
        chmod 600 "$tx/backup"/*
        printf '%s\n' "$recovery_phase" > "$tx/phase"
        printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
        printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
        chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    fi

    if [ "$wanted_failure" = true ]; then
        set +e
        main recover
        rc=$?
        set -e
        [ "$rc" -eq 1 ] || fail 'restart failure was reported as success'
        [ "$(cat "$tx/phase")" = recovery_failed ] || fail 'restart failure did not set recovery_failed'
        [ -e "$RR_ACTIVE_TX" ] || fail 'restart failure removed active transaction evidence'
        [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'restart failure removed the maintenance marker'
        return 0
    fi

    main recover
    if [ "$recovery_phase" = state_recorded ]; then
        if grep -Eq '^(enable|disable|restart|stop) (rr-nexus|sing-box|argo-rr-health.timer)$' "$operation_log"; then
            fail 'state-record crash recovery changed a service that had not been frozen'
        fi
        [ "${active[rr-nexus]}" = true ] && [ "${enabled[rr-nexus]}" = true ] || \
            fail 'state-record recovery changed untouched Nexus state'
    fi
    [ "${active[rr-nexus]}" = true ] && [ "${enabled[rr-nexus]}" = true ] || \
        fail 'active/enabled Nexus state was not restored'
    [ "${active[sing-box]}" = false ] && [ "${enabled[sing-box]}" = false ] || \
        fail 'inactive/disabled sing-box state was not preserved'
    [ "${active[argo-rr-health.timer]}" = true ] && \
        [ "${enabled[argo-rr-health.timer]}" = true ] || \
        fail 'health timer active/enabled state was not restored'
    [ "$(cat "$tx/phase")" = aborted ] || fail 'pre-mutation recovery did not end as aborted'
    [ ! -e "$RR_ACTIVE_TX" ] || fail 'successful pre-mutation recovery left active state'
    [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'successful recovery left maintenance marker'
)

printf '%s\n' '[3/8] state-record crash recovery touches no service before freezing begins'
run_recovery_case state-recorded false state_recorded

printf '%s\n' '[4/8] pre-mutation crash recovery restores exact active/enabled state'
run_recovery_case restore-success false

printf '%s\n' '[5/8] a real SIGKILL leaves durable state that standalone recovery consumes'
sig_root="$TEST_ROOT/sigkill"
sig_tx="$sig_root/update/transactions/tx"
sig_marker="$sig_root/run/update-maintenance"
(
    mkdir -p "$sig_tx/backup" "$(dirname "$sig_marker")"
    chmod 700 "$sig_tx" "$sig_tx/backup" "$(dirname "$sig_marker")"
    for marker in writer_state_complete nexus_was_running nexus_was_enabled \
        health_timer_was_running health_timer_was_enabled; do
        : > "$sig_tx/backup/$marker"
        chmod 600 "$sig_tx/backup/$marker"
        sync -f "$sig_tx/backup/$marker"
    done
    printf 'freezing\n' > "$sig_tx/phase"
    chmod 600 "$sig_tx/phase"
    printf '%s\n' "$sig_tx" > "$sig_root/update/active"
    chmod 600 "$sig_root/update/active"
    printf '%s\n' "$sig_tx" > "$sig_marker"
    chmod 600 "$sig_marker"
    sync -f "$sig_tx" && sync -f "$sig_root/update" && sync -f "$(dirname "$sig_marker")"
    kill -KILL "$BASHPID"
) &
sig_pid=$!
set +e
wait "$sig_pid" 2>/dev/null
sig_rc=$?
set -e
[ "$sig_rc" -eq 137 ] || fail 'SIGKILL fixture did not terminate as expected'
[ -f "$sig_root/update/active" ] && [ -f "$sig_marker" ] || fail 'SIGKILL lost durable recovery pointers'
run_recovery_case sigkill false freezing true

printf '%s\n' '[6/8] restart failure is fail-closed and retains transaction evidence'
run_recovery_case restore-failure true

printf '%s\n' '[7/8] a committed crash recovery only clears its maintenance marker'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/committed/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/committed/run/update-maintenance"
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    systemctl() { fail 'committed recovery touched service state'; }
    main recover
    [ "$(cat "$tx/phase")" = committed ] || fail 'committed phase was rewritten'
    [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'committed maintenance marker was not cleared'

    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx-forged" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'forged committed marker cleanup was reported as success'
    [ "$(cat "$tx/phase")" = committed ] || fail 'marker cleanup failure made a committed update rollback-eligible'
    [ -e "$RR_ACTIVE_TX" ] && [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'committed cleanup failure discarded recovery evidence'
)

printf '%s\n' '[8/8] maintenance state is root-only and bound to one transaction'
grep -Fq "0:0:600:1" "$REPO_ROOT/scripts/install-core.sh" || fail 'installer lacks strict maintenance marker mode check'
grep -Fq '[ "$owner" = "$TX_DIR" ]' "$REPO_ROOT/scripts/install-core.sh" || fail 'installer marker is not transaction-bound'
grep -Fq '[ "$owner" = "$tx" ]' "$REPO_ROOT/scripts/update-recover.sh" || fail 'recovery marker is not transaction-bound'

printf '%s\n' 'update writer freeze regression: PASS'
