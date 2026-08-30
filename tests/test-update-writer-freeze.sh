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

printf '%s\n' '[1/13] an all-inactive writer snapshot is a successful state capture'
eval "$(extract_function rr_unit_activity_matches)"
eval "$(extract_function rr_unit_file_state_matches)"
eval "$(extract_function rr_capture_unit_activity_state)"
eval "$(extract_function rr_capture_unit_file_state)"
eval "$(extract_function rr_capture_update_writer_state)"
systemctl() {
    case "$1:${2:-}" in
        show:--property=LoadState) printf '%s\n' not-found ;;
        show:--property=ActiveState) printf '%s\n' inactive ;;
        show:--property=UnitFileState) printf '%s' '' ;;
        *) return 1 ;;
    esac
}
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

RR_HEALTH_STATE_CAPTURED=false
systemctl() { return 1; }
if rr_capture_update_writer_state; then
    fail 'systemd query failure was persisted as an all-inactive writer snapshot'
fi
[ "$RR_HEALTH_STATE_CAPTURED" = false ] || \
    fail 'failed writer capture published partial health evidence'

printf '%s\n' '[2/13] repeated health freezes preserve the first observed enabled state'
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
    local property="${2:-}" unit="${4:-}"
    case "$1:$property:$unit" in
        show:--property=LoadState:*) printf '%s\n' loaded ;;
        show:--property=ActiveState:argo-rr-health.timer)
            [ "$health_timer_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
            ;;
        show:--property=ActiveState:argo-rr-health.service)
            [ "$health_service_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
            ;;
        show:--property=UnitFileState:argo-rr-health.timer)
            [ "$health_enabled" = true ] && printf '%s\n' enabled || printf '%s\n' disabled
            ;;
        stop:argo-rr-health.timer:argo-rr-health.service)
            health_timer_active=false
            health_service_active=false
            ;;
        *)
            case "$*" in
        'stop argo-rr-health.timer argo-rr-health.service')
            health_timer_active=false
            health_service_active=false
            ;;
                *) return 1 ;;
            esac
            ;;
    esac
}
rr_error() { :; }
rr_freeze_health_monitor
health_enabled=false
rr_freeze_health_monitor
[ "$RR_HEALTH_TIMER_WAS_ENABLED" = true ] || fail 'second freeze overwrote the initial enabled state'

RR_HEALTH_STATE_CAPTURED=false
RR_HEALTH_MONITOR_FROZEN=false
systemctl() { return 1; }
if rr_freeze_health_monitor; then
    fail 'health freeze accepted a systemd query failure'
fi
[ "$RR_HEALTH_STATE_CAPTURED" = false ] || \
    fail 'failed health freeze published partial pre-freeze state'

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
        case "$*" in
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'loaded\n'; return 0 ;;
            'show -p ActiveState --value argo-rr-health.timer')
                [ "${active[argo-rr-health.timer]:-false}" = true ] && printf 'active\n' || printf 'inactive\n'
                return 0 ;;
            'show -p ActiveState --value argo-rr-health.service')
                [ "${active[argo-rr-health.service]:-false}" = true ] && printf 'active\n' || printf 'inactive\n'
                return 0 ;;
            'show -p UnitFileState --value argo-rr-health.timer')
                [ "${enabled[argo-rr-health.timer]:-false}" = true ] && printf 'enabled\n' || printf 'disabled\n'
                return 0 ;;
            'show -p UnitFileState --value argo-rr-health.service') printf 'static\n'; return 0 ;;
            'show -p LoadState --value '*)
                unit="${5:-}"
                if [ "$wanted_failure" = query-error ] && [ "$unit" = rr-nexus ]; then return 1; fi
                if { [ "$wanted_failure" = absent ] && [ "$unit" = sing-box ]; } || \
                   { [ "$wanted_failure" = incoherent ] && [ "$unit" = rr-nexus ]; }; then
                    printf 'not-found\n'
                else
                    printf 'loaded\n'
                fi
                return 0 ;;
            'show -p ActiveState --value '*)
                unit="${5:-}"
                if [ "$wanted_failure" = query-error ] && [ "$unit" = rr-nexus ]; then return 1; fi
                [ "${active[$unit]:-false}" = true ] && printf 'active\n' || printf 'inactive\n'
                return 0 ;;
            'show -p UnitFileState --value '*)
                unit="${5:-}"
                if [ "$wanted_failure" = query-error ] && [ "$unit" = rr-nexus ]; then return 1; fi
                if [ "$wanted_failure" = absent ] && [ "$unit" = sing-box ]; then return 0; fi
                if [ "$wanted_failure" = incoherent ] && [ "$unit" = rr-nexus ]; then
                    printf 'enabled\n'
                    return 0
                fi
                [ "${enabled[$unit]:-false}" = true ] && printf 'enabled\n' || printf 'disabled\n'
                return 0 ;;
        esac
        case "$command $option" in
            'is-active --quiet') [ "${active[$unit]:-false}" = true ] ;;
            'is-enabled --quiet') [ "${enabled[$unit]:-false}" = true ] ;;
            'enable rr-nexus'|'enable sing-box'|'enable argo-rr-health.timer')
                unit="$option"; enabled[$unit]=true ;;
            'disable rr-nexus'|'disable sing-box'|'disable argo-rr-health.timer')
                unit="$option"; enabled[$unit]=false ;;
            'disable --now')
                if [ "$unit" = argo-rr-health.timer ]; then
                    enabled[$unit]=false
                    active[$unit]=false
                fi
                ;;
            'restart rr-nexus'|'restart sing-box'|'restart argo-rr-health.timer')
                unit="$option"
                if [ "$wanted_failure" = true ] && [ "$unit" = rr-nexus ]; then
                    return 1
                fi
                active[$unit]=true
                ;;
            'stop rr-nexus'|'stop sing-box')
                unit="$option"; active[$unit]=false ;;
            'stop argo-rr-health.timer')
                active[argo-rr-health.timer]=false
                ;;
            'stop argo-rr-health.service')
                active[argo-rr-health.service]=false
                ;;
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
        chmod 600 "$tx/phase" "$RR_ACTIVE_TX" "$RR_UPDATE_MAINTENANCE_FILE"
    fi

    if [ "$wanted_failure" = true ] || [ "$wanted_failure" = query-error ] || \
       [ "$wanted_failure" = incoherent ]; then
        set +e
        main recover
        rc=$?
        set -e
        [ "$rc" -eq 1 ] || fail 'restart failure was reported as success'
        [ "$(cat "$tx/phase")" = recovery_failed ] || fail 'restart failure did not set recovery_failed'
        [ -e "$RR_ACTIVE_TX" ] || fail 'restart failure removed active transaction evidence'
        [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'restart failure removed the maintenance marker'
        [ "${active[argo-rr-health.timer]:-false}" = false ] && \
            [ "${active[argo-rr-health.service]:-false}" = false ] && \
            [ "${enabled[argo-rr-health.timer]:-false}" = false ] || \
            fail 'restart failure left a health writer active or enabled'
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

printf '%s\n' '[3/13] state-record crash recovery touches no service before freezing begins'
run_recovery_case state-recorded false state_recorded

printf '%s\n' '[4/13] pre-mutation crash recovery restores exact active/enabled state'
run_recovery_case restore-success false

printf '%s\n' '[5/13] a real SIGKILL leaves durable state that standalone recovery consumes'
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

printf '%s\n' '[6/13] recovery freezes health writers before a SIGKILL can interrupt runtime restore'
kill_root="$TEST_ROOT/recovery-sigkill"
kill_tx="$kill_root/update/transactions/tx"
kill_timer_active="$kill_root/health-timer-active"
kill_timer_enabled="$kill_root/health-timer-enabled"
kill_service_active="$kill_root/health-service-active"
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$kill_root/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_LIB_DIR="$kill_root/runtime"
    export RR_LAUNCHER="$kill_root/rr"
    export RR_UPDATE_MAINTENANCE_FILE="$kill_root/run/update-maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    mkdir -p "$kill_tx/backup" "$kill_tx/old-runtime/modules" \
        "$RR_LIB_DIR/modules" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    : > "$kill_timer_active"
    : > "$kill_timer_enabled"
    : > "$kill_service_active"
    printf 'runtime_swapped\n' > "$kill_tx/phase"
    printf '%s\n' "$kill_tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$kill_tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    printf 'candidate\n' > "$RR_LIB_DIR/modules/sentinel"
    printf 'old\n' > "$kill_tx/old-runtime/modules/sentinel"

    systemctl() {
        case "$*" in
            'disable --now argo-rr-health.timer')
                rm -f -- "$kill_timer_enabled" "$kill_timer_active" ;;
            'stop argo-rr-health.timer') rm -f -- "$kill_timer_active" ;;
            'stop argo-rr-health.service') rm -f -- "$kill_service_active" ;;
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'loaded\n' ;;
            'show -p ActiveState --value argo-rr-health.timer')
                [ -e "$kill_timer_active" ] && printf 'active\n' || printf 'inactive\n' ;;
            'show -p ActiveState --value argo-rr-health.service')
                [ -e "$kill_service_active" ] && printf 'active\n' || printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer')
                [ -e "$kill_timer_enabled" ] && printf 'enabled\n' || printf 'disabled\n' ;;
            'show -p UnitFileState --value argo-rr-health.service') printf 'static\n' ;;
            *) return 0 ;;
        esac
    }
    rr_stop_subscription_servers() { :; }
    mv() {
        if [ "${1:-}" = "$kill_tx/old-runtime" ] && [ "${2:-}" = "$RR_LIB_DIR" ]; then
            kill -KILL "$BASHPID"
        fi
        command mv "$@"
    }
    rr_restore_transaction "$kill_tx" 'SIGKILL recovery fixture'
) &
kill_pid=$!
set +e
wait "$kill_pid" 2>/dev/null
kill_rc=$?
set -e
[ "$kill_rc" -eq 137 ] || fail 'runtime-restore SIGKILL fixture did not terminate as expected'
[ ! -e "$kill_timer_active" ] && [ ! -e "$kill_timer_enabled" ] && \
    [ ! -e "$kill_service_active" ] || \
    fail 'SIGKILL interrupted runtime restore before health writers were durably frozen'
[ -d "$kill_tx/old-runtime" ] && compgen -G "$kill_tx/failed-runtime-*" >/dev/null || \
    fail 'SIGKILL fixture did not reach the runtime restoration boundary'
[ -e "$kill_root/update/active" ] && [ -e "$kill_root/run/update-maintenance" ] || \
    fail 'runtime-restore SIGKILL discarded transaction evidence'

printf '%s\n' '[7/13] restart failure is fail-closed and retains transaction evidence'
run_recovery_case restore-failure true
run_recovery_case restore-query-error query-error
run_recovery_case restore-absent absent
run_recovery_case restore-incoherent incoherent

printf '%s\n' '[8/13] a committed crash retries finalization before clearing maintenance'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/committed/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_LAUNCHER="$TEST_ROOT/committed/rr"
    export RR_LIB_DIR="$TEST_ROOT/committed/runtime"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/committed/run/update-maintenance"
    export RR_TEST_FINALIZE_LOG="$TEST_ROOT/committed/finalize.log"
    export RR_TEST_FINALIZE_FAIL=0
    source "$REPO_ROOT/scripts/update-recover.sh"
    restore_log="$TEST_ROOT/committed/restore.log"
    rr_restore_transaction() {
        printf '%s\n' restore-called >> "$restore_log"
        return 97
    }
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")" \
        "$(dirname "$RR_LAUNCHER")" "$RR_LIB_DIR/modules"
    chmod 700 "$tx" "$tx/backup"
    chmod 0755 "$RR_LIB_DIR" "$RR_LIB_DIR/modules"
    printf 'SCRIPT_VERSION="7.1.1"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
    chmod 0600 "$RR_LIB_DIR/modules/00-runtime.sh"
    : > "$tx/backup/health_timer_was_enabled"
    chmod 600 "$tx/backup/health_timer_was_enabled"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s %s\n" "${RR_UPDATE_LOCK_HELD:-}" "$*" >> "$RR_TEST_FINALIZE_LOG"' \
        'exit "${RR_TEST_FINALIZE_FAIL:-0}"' > "$RR_LAUNCHER"
    chmod 700 "$RR_LAUNCHER"
    (
        printf 'committed\n' > "$tx/phase"
        printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
        printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
        chmod 600 "$tx/phase" "$RR_ACTIVE_TX" "$RR_UPDATE_MAINTENANCE_FILE"
        sync -f "$tx/phase" && sync -f "$RR_ACTIVE_TX" && \
            sync -f "$RR_UPDATE_MAINTENANCE_FILE"
        kill -KILL "$BASHPID"
    ) &
    commit_pid=$!
    set +e
    wait "$commit_pid" 2>/dev/null
    commit_rc=$?
    set -e
    [ "$commit_rc" -eq 137 ] || fail 'committed finalization-window fixture did not SIGKILL'
    systemctl() {
        case "$*" in
            'is-active --quiet rr-subscription-quarantine.service'|\
            'is-enabled --quiet rr-subscription-quarantine.service') return 1 ;;
            'disable --now argo-rr-health.timer'|'stop argo-rr-health.timer'|\
            'disable argo-rr-health.service'|'stop argo-rr-health.service') return 0 ;;
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'not-found\n' ;;
            'show -p ActiveState --value argo-rr-health.timer'|\
            'show -p ActiveState --value argo-rr-health.service') printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer'|\
            'show -p UnitFileState --value argo-rr-health.service') : ;;
            'show -p LoadState --value rr-subscription-quarantine.service') printf 'not-found\n' ;;
            'show -p ActiveState --value rr-subscription-quarantine.service') printf 'inactive\n' ;;
            'show -p UnitFileState --value rr-subscription-quarantine.service') : ;;
            'enable argo-rr-health.timer'|'start --no-block argo-rr-health.timer'|\
            'stop --no-block sing-box'|'stop --no-block rr-nexus') return 0 ;;
            *) fail "committed recovery touched service state: $*" ;;
        esac
    }
    main recover
    [ "$(cat "$tx/phase")" = committed ] || fail 'committed phase was rewritten'
    [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'committed maintenance marker was not cleared'
    grep -Fxq '1 --post-update-finalize' "$RR_TEST_FINALIZE_LOG" || \
        fail 'committed crash recovery skipped candidate finalization'

    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx-forged" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$tx/phase" "$RR_ACTIVE_TX" "$RR_UPDATE_MAINTENANCE_FILE"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'forged committed marker cleanup was reported as success'
    [ "$(cat "$tx/phase")" = committed ] || fail 'marker cleanup failure made a committed update rollback-eligible'
    [ -e "$RR_ACTIVE_TX" ] && [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'committed cleanup failure discarded recovery evidence'
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 2 ] || \
        fail 'committed cleanup retry did not re-run finalization'

    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    sync() {
        [ "$#" -ne 0 ] && command sync "$@" && return
        return 1
    }
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'global terminal sync failure was reported as success'
    [ "$(cat "$tx/phase")" = committed ] && [ -e "$RR_ACTIVE_TX" ] &&
        [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'global terminal sync failure discarded active or maintenance evidence'
    [ ! -e "$restore_log" ] || fail 'terminal sync failure made a committed candidate rollback-eligible'
    unset -f sync

    main recover || fail 'committed cleanup did not succeed after the durability fault cleared'
    [ "$(cat "$tx/phase")" = committed ] && [ -e "$RR_ACTIVE_TX" ] &&
        [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'committed cleanup retry changed its terminal phase or rollback pointer'
    [ ! -e "$restore_log" ] || fail 'second recovery restored or rolled back a committed candidate'

    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    export RR_TEST_FINALIZE_FAIL=1
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'candidate finalization failure was reported as success'
    [ "$(cat "$tx/phase")" = committed ] && [ -e "$RR_ACTIVE_TX" ] && \
        [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'candidate finalization failure discarded committed recovery evidence'
)

printf '%s\n' '[9/13] aborted recovery is idempotent and requires a durable active unlink'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/aborted-terminal/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/aborted-terminal/run/update-maintenance"
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    parent="$RR_TX_ROOT"
    restore_log="$TEST_ROOT/aborted-terminal/restore.log"
    unlink_fail=false
    parent_sync_fail=false
    rr_restore_transaction() {
        printf '%s\n' restore-called >> "$restore_log"
        return 97
    }
    rm() {
        if [ "$unlink_fail" = true ] && [ "$*" = "-f -- $RR_ACTIVE_TX" ]; then
            return 1
        fi
        command rm "$@"
    }
    sync() {
        if [ "$parent_sync_fail" = true ] && [ "$*" = "-f $parent" ]; then
            return 1
        fi
        command sync "$@"
    }
    mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    chmod 700 "$RR_TX_ROOT" "$tx" "$tx/backup"
    printf '2\n' > "$tx/transaction-format"
    printf 'aborted\n' > "$tx/phase"
    : > "$tx/backup/writer_state_complete"
    chmod 600 "$tx/transaction-format" "$tx/phase" "$tx/backup/writer_state_complete"
    systemctl() {
        case "$*" in
            'is-active --quiet rr-subscription-quarantine.service'|\
            'is-enabled --quiet rr-subscription-quarantine.service') return 1 ;;
            'disable --now argo-rr-health.timer'|'stop argo-rr-health.timer'|\
            'disable argo-rr-health.service'|'stop argo-rr-health.service'|\
            'disable argo-rr-health.timer'|'stop --no-block argo-rr-health.timer'|\
            'disable sing-box'|'disable rr-nexus'|'stop sing-box'|'stop rr-nexus'|\
            'stop --no-block sing-box'|'stop --no-block rr-nexus') return 0 ;;
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'not-found\n' ;;
            'show -p LoadState --value sing-box'|\
            'show -p LoadState --value rr-nexus') printf 'loaded\n' ;;
            'show -p ActiveState --value argo-rr-health.timer'|\
            'show -p ActiveState --value argo-rr-health.service'|\
            'show -p ActiveState --value sing-box'|\
            'show -p ActiveState --value rr-nexus') printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer'|\
            'show -p UnitFileState --value argo-rr-health.service') : ;;
            'show -p UnitFileState --value sing-box'|\
            'show -p UnitFileState --value rr-nexus') printf 'disabled\n' ;;
            *) fail "aborted recovery touched unexpected service state: $*" ;;
        esac
    }
    rr_stop_subscription_servers() { return 0; }
    rr_subscription_running() { return 1; }

    publish_active() {
        printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
        chmod 600 "$RR_ACTIVE_TX"
    }

    publish_active
    unlink_fail=true
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = aborted ] && \
        [ -e "$RR_ACTIVE_TX" ] && [ -d "$tx" ] ||
        fail 'active unlink failure lost an aborted terminal transaction'
    [ ! -e "$restore_log" ] || fail 'aborted unlink failure entered rollback'

    unlink_fail=false
    main recover || fail 'aborted active unlink retry did not succeed'
    [ ! -e "$RR_ACTIVE_TX" ] && [ "$(cat "$tx/phase")" = aborted ] ||
        fail 'aborted retry did not durably clear its active pointer'
    main recover || fail 'already-consumed aborted recovery was not idempotent'
    [ ! -e "$restore_log" ] || fail 'idempotent aborted recovery entered rollback'

    publish_active
    parent_sync_fail=true
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = aborted ] && \
        [ -f "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ] && [ -d "$tx" ] && \
        [ "$(cat "$RR_ACTIVE_TX")" = "$tx" ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$RR_ACTIVE_TX")" = 0:0:600:1 ] ||
        fail 'active parent-fsync failure did not republish strict terminal evidence'
    [ ! -e "$restore_log" ] || fail 'active parent-fsync failure entered rollback'

    parent_sync_fail=false
    main recover || fail 'republished aborted pointer was not consumed safely'
    [ ! -e "$RR_ACTIVE_TX" ] && [ "$(cat "$tx/phase")" = aborted ] && \
        [ ! -e "$restore_log" ] ||
        fail 'republished aborted recovery regressed into rollback'
)

printf '%s\n' '[10/13] normal terminal cleanup retries restore the recorded writer state'
for terminal_phase in committed rolled_back aborted; do
    (
        export RR_UPDATE_RECOVER_SOURCE_ONLY=1
        export RR_UPDATE_LOCK_HELD=1
        export RR_TX_ROOT="$TEST_ROOT/terminal-retry-$terminal_phase/update"
        export RR_ACTIVE_TX="$RR_TX_ROOT/active"
        export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/terminal-retry-$terminal_phase/run/update-maintenance"
        source "$REPO_ROOT/scripts/update-recover.sh"
        tx="$RR_TX_ROOT/transactions/tx"
        timer_active="$TEST_ROOT/terminal-retry-$terminal_phase/timer-active"
        timer_enabled="$TEST_ROOT/terminal-retry-$terminal_phase/timer-enabled"
        operation_log="$TEST_ROOT/terminal-retry-$terminal_phase/operations"
        fail_global_sync=true
        mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
        chmod 700 "$RR_TX_ROOT" "$tx" "$tx/backup"
        printf '%s\n' "$terminal_phase" > "$tx/phase"
        printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
        printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
        printf '2\n' > "$tx/transaction-format"
        : > "$tx/backup/writer_state_complete"
        : > "$tx/backup/health_timer_was_enabled"
        : > "$tx/backup/health_timer_was_running"
        chmod 600 "$tx/phase" "$RR_ACTIVE_TX" "$RR_UPDATE_MAINTENANCE_FILE" \
            "$tx/transaction-format" "$tx/backup/writer_state_complete" \
            "$tx/backup/health_timer_was_enabled" "$tx/backup/health_timer_was_running"
        : > "$timer_active"
        : > "$timer_enabled"
        : > "$operation_log"

        rr_finalize_committed_candidate() { return 0; }
        rr_stop_subscription_servers() { return 0; }
        rr_subscription_running() { return 1; }
        systemctl() {
            printf 'systemctl:%s\n' "$*" >> "$operation_log"
            case "$*" in
                'is-active --quiet rr-subscription-quarantine.service'|\
                'is-enabled --quiet rr-subscription-quarantine.service') return 1 ;;
                'disable --now argo-rr-health.timer')
                    rm -f -- "$timer_active" "$timer_enabled" ;;
                'stop argo-rr-health.timer') rm -f -- "$timer_active" ;;
                'disable argo-rr-health.service'|'stop argo-rr-health.service') : ;;
                'show -p LoadState --value argo-rr-health.timer'|\
                'show -p LoadState --value argo-rr-health.service') printf 'loaded\n' ;;
                'show -p LoadState --value sing-box'|\
                'show -p LoadState --value rr-nexus') printf 'loaded\n' ;;
                'show -p ActiveState --value argo-rr-health.timer')
                    [ -e "$timer_active" ] && printf 'active\n' || printf 'inactive\n' ;;
                'show -p ActiveState --value argo-rr-health.service'|\
                'show -p ActiveState --value sing-box'|\
                'show -p ActiveState --value rr-nexus') printf 'inactive\n' ;;
                'show -p UnitFileState --value argo-rr-health.timer')
                    [ -e "$timer_enabled" ] && printf 'enabled\n' || printf 'disabled\n' ;;
                'show -p UnitFileState --value argo-rr-health.service') printf 'static\n' ;;
                'show -p UnitFileState --value sing-box'|\
                'show -p UnitFileState --value rr-nexus') printf 'disabled\n' ;;
                'show -p LoadState --value rr-subscription-quarantine.service') printf 'not-found\n' ;;
                'show -p ActiveState --value rr-subscription-quarantine.service') printf 'inactive\n' ;;
                'show -p UnitFileState --value rr-subscription-quarantine.service') : ;;
                'enable argo-rr-health.timer') : > "$timer_enabled" ;;
                'restart argo-rr-health.timer') : > "$timer_active" ;;
                'disable sing-box'|'disable rr-nexus'|\
                'stop sing-box'|'stop rr-nexus') : ;;
                *) fail "unexpected terminal-retry systemctl operation: $*" ;;
            esac
        }
        sync() {
            if [ "$#" -eq 0 ] && [ "$fail_global_sync" = true ]; then
                printf 'sync:global\n' >> "$operation_log"
                return 1
            fi
            [ "$#" -ne 0 ] || printf 'sync:global\n' >> "$operation_log"
            command sync "$@"
        }

        set +e
        main recover
        rc=$?
        set -e
        [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = "$terminal_phase" ] ||
            fail "$terminal_phase durability failure changed the terminal phase"
        [ ! -e "$timer_active" ] && [ ! -e "$timer_enabled" ] ||
            fail "$terminal_phase durability failure did not freeze health writers"
        restore_line=$(grep -n '^systemctl:restart argo-rr-health.timer$' "$operation_log" | \
            head -n 1 | cut -d: -f1)
        sync_line=$(grep -n '^sync:global$' "$operation_log" | head -n 1 | cut -d: -f1)
        [[ "$restore_line" =~ ^[0-9]+$ && "$sync_line" =~ ^[0-9]+$ ]] && \
            [ "$restore_line" -lt "$sync_line" ] ||
            fail "$terminal_phase synchronized before restoring its recorded writer state"
        fail_global_sync=false
        main recover || fail "$terminal_phase terminal cleanup retry failed"
        [ -e "$timer_active" ] && [ -e "$timer_enabled" ] ||
            fail "$terminal_phase terminal cleanup retry left the health timer frozen"
        [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
            fail "$terminal_phase terminal cleanup retry retained maintenance"
        if [ "$terminal_phase" = committed ]; then
            [ -e "$RR_ACTIVE_TX" ] || fail 'committed retry discarded the rollback pointer'
        else
            [ ! -e "$RR_ACTIVE_TX" ] || fail "$terminal_phase retry retained the active pointer"
        fi
    )
done

terminal_branch=$(sed -n '/if \[ "$mode" = recover \] && \\/,/^        return 0$/p' \
    "$REPO_ROOT/scripts/update-recover.sh" | tail -n 95)
restore_line=$(grep -n 'rr_restore_recorded_writer_state' <<<"$terminal_branch" | tail -n 1 | cut -d: -f1)
sync_line=$(grep -n 'rr_prepare_terminal_transaction_cleanup' <<<"$terminal_branch" | tail -n 1 | cut -d: -f1)
marker_line=$(grep -n 'rr_clear_update_maintenance_marker' <<<"$terminal_branch" | tail -n 1 | cut -d: -f1)
active_line=$(grep -n 'rr_clear_active_transaction_pointer' <<<"$terminal_branch" | tail -n 1 | cut -d: -f1)
[[ "$restore_line" =~ ^[0-9]+$ && "$sync_line" =~ ^[0-9]+$ && \
   "$marker_line" =~ ^[0-9]+$ && "$active_line" =~ ^[0-9]+$ ]] && \
    [ "$restore_line" -lt "$sync_line" ] && [ "$sync_line" -lt "$marker_line" ] && \
    [ "$marker_line" -lt "$active_line" ] ||
    fail 'terminal cleanup is not ordered writer-restore, global-sync, maintenance, active'

printf '%s\n' '[11/13] invalid evidence and systemd query errors fail closed with health writers frozen'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/fail-closed/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/fail-closed/run/update-maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    timer_active="$TEST_ROOT/fail-closed/timer-active"
    timer_enabled="$TEST_ROOT/fail-closed/timer-enabled"
    service_active="$TEST_ROOT/fail-closed/service-active"
    query_fail=false
    absent_units=false
    invalid_load_state=false
    mkdir -p "$RR_TX_ROOT/transactions" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"

    systemctl() {
        case "$*" in
            'disable --now argo-rr-health.timer')
                rm -f -- "$timer_enabled" "$timer_active" ;;
            'stop argo-rr-health.timer') rm -f -- "$timer_active" ;;
            'stop argo-rr-health.service') rm -f -- "$service_active" ;;
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service')
                [ "$query_fail" = false ] || return 1
                if [ "$invalid_load_state" = true ]; then
                    printf 'error\n'
                elif [ "$absent_units" = true ]; then
                    printf 'not-found\n'
                else
                    printf 'loaded\n'
                fi ;;
            'show -p ActiveState --value argo-rr-health.timer')
                [ "$query_fail" = false ] || return 1
                [ -e "$timer_active" ] && printf 'active\n' || printf 'inactive\n' ;;
            'show -p ActiveState --value argo-rr-health.service')
                [ "$query_fail" = false ] || return 1
                [ -e "$service_active" ] && printf 'active\n' || printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer')
                [ "$query_fail" = false ] || return 1
                [ "$absent_units" = false ] || return 0
                [ -e "$timer_enabled" ] && printf 'enabled\n' || printf 'disabled\n' ;;
            'show -p UnitFileState --value argo-rr-health.service')
                [ "$query_fail" = false ] || return 1
                [ "$absent_units" = false ] || return 0
                printf 'static\n' ;;
            *) return 0 ;;
        esac
    }
    arm_health() { : > "$timer_active"; : > "$timer_enabled"; : > "$service_active"; }
    assert_health_frozen() {
        [ ! -e "$timer_active" ] && [ ! -e "$timer_enabled" ] && [ ! -e "$service_active" ] ||
            fail "$1 left a health writer active or enabled"
    }

    legacy_tx="$RR_TX_ROOT/transactions/legacy-0644"
    mkdir -p "$legacy_tx"
    chmod 700 "$legacy_tx"
    printf 'state_recorded\n' > "$legacy_tx/phase"
    printf '%s\n' "$legacy_tx" > "$RR_ACTIVE_TX"
    chmod 0644 "$legacy_tx/phase" "$RR_ACTIVE_TX"
    main recover || fail 'real 7.1.0-style 0644 active/phase metadata did not recover'
    [ ! -e "$RR_ACTIVE_TX" ] && [ "$(cat "$legacy_tx/phase")" = aborted ] ||
        fail 'legacy 0644 transaction was not completed safely'

    arm_health
    v2_tx="$RR_TX_ROOT/transactions/v2-0644"
    mkdir -p "$v2_tx"
    chmod 700 "$v2_tx"
    printf 'state_recorded\n' > "$v2_tx/phase"
    printf '2\n' > "$v2_tx/transaction-format"
    printf '%s\n' "$v2_tx" > "$RR_ACTIVE_TX"
    chmod 0644 "$v2_tx/phase" "$RR_ACTIVE_TX"
    chmod 0600 "$v2_tx/transaction-format"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -e "$RR_ACTIVE_TX" ] ||
        fail 'format-2 transaction accepted legacy 0644 active/phase metadata'
    assert_health_frozen 'format-2 0644 transaction metadata'

    arm_health
    missing_writer_state="$RR_TX_ROOT/transactions/missing-writer-state"
    mkdir -p "$missing_writer_state/backup"
    chmod 700 "$missing_writer_state" "$missing_writer_state/backup"
    printf '2\n' > "$missing_writer_state/transaction-format"
    printf 'committed\n' > "$missing_writer_state/phase"
    printf '%s\n' "$missing_writer_state" > "$RR_ACTIVE_TX"
    chmod 600 "$missing_writer_state/transaction-format" \
        "$missing_writer_state/phase" "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -e "$RR_ACTIVE_TX" ] && \
        [ "$(cat "$missing_writer_state/phase")" = committed ] ||
        fail 'format-2 terminal transaction accepted missing writer-state evidence'
    assert_health_frozen 'format-2 missing writer-state evidence'

    arm_health
    printf '%s\n' "$RR_TX_ROOT/transactions/missing-target" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'invalid active transaction was reported as absence'
    [ -e "$RR_ACTIVE_TX" ] || fail 'invalid active transaction evidence was removed'
    assert_health_frozen 'invalid active transaction'

    arm_health
    missing_backup="$RR_TX_ROOT/transactions/missing-backup"
    mkdir -p "$missing_backup"
    chmod 700 "$missing_backup"
    printf 'runtime_swapped\n' > "$missing_backup/phase"
    printf '%s\n' "$missing_backup" > "$RR_ACTIVE_TX"
    chmod 600 "$missing_backup/phase" "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'missing recovery backup was reported as success'
    [ "$(cat "$missing_backup/phase")" = recovery_failed ] || \
        fail 'missing recovery backup did not retain a failed phase'
    [ -e "$RR_ACTIVE_TX" ] || fail 'missing backup discarded active evidence'
    assert_health_frozen 'missing recovery backup'

    arm_health
    unsafe_format="$RR_TX_ROOT/transactions/unsafe-format"
    mkdir -p "$unsafe_format/backup"
    chmod 700 "$unsafe_format" "$unsafe_format/backup"
    printf 'runtime_swapped\n' > "$unsafe_format/phase"
    ln -s "$TEST_ROOT/fail-closed/forged-format" "$unsafe_format/transaction-format"
    printf '%s\n' "$unsafe_format" > "$RR_ACTIVE_TX"
    chmod 600 "$unsafe_format/phase" "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'unsafe transaction format was reported as success'
    [ "$(cat "$unsafe_format/phase")" = recovery_failed ] || \
        fail 'unsafe transaction format did not retain a failed phase'
    [ -L "$unsafe_format/transaction-format" ] && [ -e "$RR_ACTIVE_TX" ] || \
        fail 'unsafe transaction format evidence was removed'
    assert_health_frozen 'unsafe transaction format'

    metadata_tx="$RR_TX_ROOT/transactions/metadata"
    rm -rf -- "$metadata_tx"
    mkdir -p "$metadata_tx"
    chmod 700 "$metadata_tx"
    printf 'committed\n' > "$metadata_tx/phase"
    chmod 600 "$metadata_tx/phase"

    arm_health
    active_target="$TEST_ROOT/fail-closed/active-target"
    printf '%s\n' "$metadata_tx" > "$active_target"
    chmod 600 "$active_target"
    rm -f -- "$RR_ACTIVE_TX"
    ln -s "$active_target" "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -L "$RR_ACTIVE_TX" ] ||
        fail 'active-pointer symlink was accepted or removed'
    assert_health_frozen 'active-pointer symlink'

    arm_health
    rm -f -- "$RR_ACTIVE_TX"
    printf '%s\n%s\n' "$metadata_tx" "$metadata_tx" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(wc -l < "$RR_ACTIVE_TX")" -eq 2 ] ||
        fail 'multiline active pointer was accepted or rewritten'
    assert_health_frozen 'multiline active pointer'

    arm_health
    printf '%s\n' "$metadata_tx" > "$RR_ACTIVE_TX"
    chmod 0620 "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(stat -c %a "$RR_ACTIVE_TX")" = 620 ] ||
        fail 'group-writable active pointer was accepted or rewritten'
    assert_health_frozen 'group-writable active pointer'

    arm_health
    real_tx="$TEST_ROOT/fail-closed/real-transaction"
    linked_tx="$RR_TX_ROOT/transactions/linked"
    mkdir -p "$real_tx"
    chmod 700 "$real_tx"
    printf 'committed\n' > "$real_tx/phase"
    chmod 600 "$real_tx/phase"
    rm -f -- "$linked_tx" "$RR_ACTIVE_TX"
    ln -s "$real_tx" "$linked_tx"
    printf '%s\n' "$linked_tx" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -L "$linked_tx" ] ||
        fail 'symlink transaction directory was accepted or removed'
    assert_health_frozen 'symlink transaction directory'

    arm_health
    rm -f -- "$RR_ACTIVE_TX" "$metadata_tx/phase"
    printf '%s\n' "$metadata_tx" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    phase_target="$TEST_ROOT/fail-closed/phase-target"
    printf 'committed\n' > "$phase_target"
    chmod 600 "$phase_target"
    ln -s "$phase_target" "$metadata_tx/phase"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -L "$metadata_tx/phase" ] ||
        fail 'phase symlink was accepted as committed or removed'
    assert_health_frozen 'phase symlink'

    arm_health
    rm -f -- "$metadata_tx/phase"
    printf 'committed\nruntime_swapped\n' > "$metadata_tx/phase"
    chmod 600 "$metadata_tx/phase"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(wc -l < "$metadata_tx/phase")" -eq 2 ] ||
        fail 'multiline phase was accepted as committed or rewritten'
    assert_health_frozen 'multiline phase'

    arm_health
    printf '%s\n' "$metadata_tx" > "$RR_ACTIVE_TX"
    printf 'committed\n' > "$metadata_tx/phase"
    chmod 0600 "$RR_ACTIVE_TX"
    chmod 0620 "$metadata_tx/phase"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(stat -c %a "$metadata_tx/phase")" = 620 ] ||
        fail 'group-writable phase was accepted or rewritten'
    assert_health_frozen 'group-writable phase'

    absent_units=true
    rr_freeze_health_writers_strict ||
        fail 'absent systemd units with empty UnitFileState were not normalized safely'
    absent_units=false

    invalid_load_state=true
    if rr_freeze_health_writers_strict; then
        fail 'an unknown LoadState was accepted as proof that health writers are frozen'
    fi
    invalid_load_state=false

    arm_health
    query_fail=true
    if rr_freeze_health_writers_strict; then
        fail 'systemd query errors were accepted as proof that health writers are frozen'
    fi
    assert_health_frozen 'systemd query-error handling'
)

printf '%s\n' '[12/13] recovery bridges legacy locks and delegates both flock descriptors safely'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=0
    export RR_UPDATE_LOCK_FILE="$TEST_ROOT/delegated-lock/run/update.lock"
    export RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/delegated-lock/legacy/rr-update.lock"
    export RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/delegated-lock/private/legacy-update-bridge"
    export RR_TX_ROOT="$TEST_ROOT/delegated-lock/tx-root"
    export RR_LIB_DIR="$TEST_ROOT/delegated-lock/runtime"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    delegated="$TEST_ROOT/delegated-lock/launcher"
    daemon_pid_file="$TEST_ROOT/delegated-lock/daemon.pid"
    mkdir -p "$(dirname "$delegated")" "$(dirname "$RR_LEGACY_UPDATE_LOCK_FILE")"

    # Markerless public names are non-authoritative. Recovery neither creates
    # an absent one nor lets a hostile one deny current-version cleanup.
    rr_acquire_update_lock
    [ ! -e "$RR_LEGACY_UPDATE_LOCK_FILE" ] &&
        [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'recovery created or opened an absent predictable legacy lock'
    rr_close_inherited_recovery_lock_fds

    printf 'markerless-target\n' > "${RR_LEGACY_UPDATE_LOCK_FILE}.target"
    ln -s "${RR_LEGACY_UPDATE_LOCK_FILE}.target" "$RR_LEGACY_UPDATE_LOCK_FILE"
    rr_acquire_update_lock || fail 'markerless hostile public legacy name denied recovery'
    [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'markerless hostile public legacy name was opened'
    grep -Fxq markerless-target "${RR_LEGACY_UPDATE_LOCK_FILE}.target" ||
        fail 'markerless hostile public legacy target was modified'
    rr_close_inherited_recovery_lock_fds
    rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE"

    # Before a pre-7.1.1 runtime can be exposed, recovery must create and hold
    # the compatibility lock and atomically publish private same-boot evidence.
    rollback_tx="$RR_TX_ROOT/transactions/unsafe-target"
    mkdir -p "$rollback_tx/backup" "$rollback_tx/old-runtime/modules"
    chmod 0700 "$RR_TX_ROOT" "$RR_TX_ROOT/transactions" "$rollback_tx" \
        "$rollback_tx/backup" "$rollback_tx/old-runtime"
    printf '1\n' > "$rollback_tx/backup/rollback-metadata-complete"
    printf '7.1.0\n' > "$rollback_tx/backup/rollback-runtime-version"
    printf 'SCRIPT_VERSION="7.1.0"\n' > "$rollback_tx/old-runtime/modules/00-runtime.sh"
    chmod 0600 "$rollback_tx/backup/rollback-metadata-complete" \
        "$rollback_tx/backup/rollback-runtime-version" \
        "$rollback_tx/old-runtime/modules/00-runtime.sh"
    rr_acquire_update_lock
    rr_prepare_legacy_lock_for_rollback "$rollback_tx" ||
        fail 'unsafe rollback could not publish its same-boot legacy bridge'
    [ -n "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'unsafe rollback did not retain the legacy compatibility flock'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = 0:0:600:1 ] ||
        fail 'unsafe rollback published an unsafe legacy lock'
    [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = 0:0:600:1 ] &&
        [ "$(stat -c '%u:%g:%a' "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")")" = 0:0:700 ] &&
        [ "$(cat "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = rr-legacy-update-bridge-v1 ] ||
        fail 'unsafe rollback published an unsafe private legacy bridge marker'
    rr_close_inherited_recovery_lock_fds

    # Once private evidence exists, a missing public compatibility inode is a
    # fail-closed inconsistency and must release the already-acquired new lock.
    rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE"
    if rr_acquire_update_lock; then
        fail 'recovery accepted a private legacy marker with no public lock'
    fi
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] &&
        [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'marker-with-missing-lock failure leaked a recovery descriptor'
    flock -n "$RR_UPDATE_LOCK_FILE" -c true ||
        fail 'marker-with-missing-lock failure retained the new recovery lock'

    # With trusted private evidence, a safe 7.1.0-era 0644 inode is accepted
    # without metadata/content changes.
    printf 'legacy-sentinel\n' > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
    legacy_before=$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")
    legacy_digest=$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")
    rr_acquire_update_lock
    [ "$(stat -c '%d:%i:%u:%g:%a:%h:%s' "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_before" ] &&
        [ "$(sha256sum "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$legacy_digest" ] ||
        fail 'recovery mutated a safe existing legacy lock inode'
    rr_close_inherited_recovery_lock_fds

    # Legacy contention must release the already-acquired new lock too.
    exec {legacy_holder_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$legacy_holder_fd"
    if rr_acquire_update_lock; then
        fail 'recovery ignored an active legacy update holder'
    fi
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] &&
        [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'legacy contention leaked a recovery lock descriptor'
    flock -n "$RR_UPDATE_LOCK_FILE" -c true ||
        fail 'legacy contention retained the new recovery lock'
    exec {legacy_holder_fd}>&-

    # Hostile path types are rejected without touching their targets or
    # retaining the new lock acquired first.
    rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE"
    printf 'target-sentinel\n' > "${RR_LEGACY_UPDATE_LOCK_FILE}.target"
    ln -s "${RR_LEGACY_UPDATE_LOCK_FILE}.target" "$RR_LEGACY_UPDATE_LOCK_FILE"
    if rr_acquire_update_lock; then
        fail 'recovery accepted a symlink legacy lock'
    fi
    grep -Fxq target-sentinel "${RR_LEGACY_UPDATE_LOCK_FILE}.target" ||
        fail 'recovery mutated a hostile legacy lock target'
    [ -z "$RR_UPDATE_RECOVERY_LOCK_FD" ] &&
        [ -z "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD" ] ||
        fail 'hostile legacy lock leaked a recovery descriptor'
    rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE"
    : > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"
    ln "$RR_LEGACY_UPDATE_LOCK_FILE" "${RR_LEGACY_UPDATE_LOCK_FILE}.alias"
    if rr_acquire_update_lock; then
        fail 'recovery accepted a hard-linked legacy lock'
    fi
    [ "$(stat -c %h "$RR_LEGACY_UPDATE_LOCK_FILE")" -eq 2 ] ||
        fail 'recovery changed the hostile hard-linked inode'
    rm -f -- "${RR_LEGACY_UPDATE_LOCK_FILE}.alias" "$RR_LEGACY_UPDATE_LOCK_FILE"

    legacy_parent=$(dirname "$RR_LEGACY_UPDATE_LOCK_FILE")
    : > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0777 "$legacy_parent"
    if rr_acquire_update_lock; then
        fail 'recovery accepted a non-sticky world-writable legacy lock parent'
    fi
    [ "$(stat -c '%u:%g:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = 0:0:600:1 ] ||
        fail 'recovery mutated a lock in an unsafe legacy parent'
    chmod 2755 "$legacy_parent"
    if rr_acquire_update_lock; then
        fail 'recovery accepted a setgid legacy lock parent'
    fi
    chmod g-s "$legacy_parent"
    chmod 1777 "$legacy_parent"
    rr_acquire_update_lock || fail 'recovery rejected a root-owned sticky legacy lock parent'
    rr_close_inherited_recovery_lock_fds
    chmod 0700 "$legacy_parent"
    rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE"
    : > "$RR_LEGACY_UPDATE_LOCK_FILE"
    chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"

    export RR_TEST_DAEMON_PID_FILE="$daemon_pid_file"
    printf '%s\n' '#!/bin/bash' \
        'nohup bash -c '\''trap "exit 0" TERM; while :; do sleep 1; done'\'' >/dev/null 2>&1 &' \
        'printf "%s\n" "$!" > "$RR_TEST_DAEMON_PID_FILE"' > "$delegated"
    chmod 700 "$delegated"
    rr_acquire_update_lock
    rr_run_delegated_without_lock_fds 5 "$delegated"
    daemon_pid=$(cat "$daemon_pid_file")
    trap 'kill "$daemon_pid" >/dev/null 2>&1 || true' EXIT
    kill -0 "$daemon_pid" || fail 'delegated nohup fixture did not remain alive'
    rr_close_inherited_recovery_lock_fds
    (
        exec {contender_fd}>>"$RR_UPDATE_LOCK_FILE"
        flock -n "$contender_fd"
    ) || fail 'delegated nohup child retained the new recovery flock'
    (
        exec {legacy_contender_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
        flock -n "$legacy_contender_fd"
    ) || fail 'delegated nohup child retained the legacy recovery flock'
    kill "$daemon_pid" >/dev/null 2>&1 || true
    trap - EXIT
)

printf '%s\n' '[13/13] maintenance state is root-only and bound to one transaction'
grep -Fq "0:0:600:1" "$REPO_ROOT/scripts/install-core.sh" || fail 'installer lacks strict maintenance marker mode check'
grep -Fq '[ "$owner" = "$TX_DIR" ]' "$REPO_ROOT/scripts/install-core.sh" || fail 'installer marker is not transaction-bound'
grep -Fq '[ "$owner" = "$tx" ]' "$REPO_ROOT/scripts/update-recover.sh" || fail 'recovery marker is not transaction-bound'

printf '%s\n' 'update writer freeze regression: PASS'
