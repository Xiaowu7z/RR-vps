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

printf '%s\n' '[1/15] an all-inactive writer snapshot is a successful state capture'
eval "$(extract_function rr_unit_activity_matches)"
eval "$(extract_function rr_unit_file_state_matches)"
eval "$(extract_function rr_capture_unit_activity_state)"
eval "$(extract_function rr_capture_unit_file_state)"
eval "$(extract_function rr_capture_ip_acme_update_state)"
eval "$(extract_function rr_capture_update_writer_state)"
RR_IP_ACME_STATE_ROOT="$TEST_ROOT/absent-ip-acme"
RR_IP_ACME_WAS_PRESENT=true
RR_IP_ACME_WAS_READY=true
RR_IP_ACME_TIMER_WAS_ACTIVE=true
RR_IP_ACME_TIMER_WAS_ENABLED=true
rr_ip_acme_legacy_absent_state_is_exact() { return 0; }
rr_capture_ip_acme_update_state || fail 'absent IP-ACME state was not captured'
[ "$RR_IP_ACME_WAS_PRESENT" = false ] && \
    [ "$RR_IP_ACME_WAS_READY" = false ] && \
    [ "$RR_IP_ACME_TIMER_WAS_ACTIVE" = false ] && \
    [ "$RR_IP_ACME_TIMER_WAS_ENABLED" = false ] || \
    fail 'absent IP-ACME capture retained stale writer state'
systemctl() {
    case "$1:${2:-}" in
        show:--property=LoadState) printf '%s\n' not-found ;;
        show:--property=ActiveState) printf '%s\n' inactive ;;
        show:--property=UnitFileState) printf '%s' '' ;;
        *) return 1 ;;
    esac
}
rr_subscription_running() { return 1; }
rr_capture_ip_acme_update_state() {
    RR_IP_ACME_WAS_PRESENT=false
    RR_IP_ACME_WAS_READY=false
    RR_IP_ACME_TIMER_WAS_ACTIVE=false
    RR_IP_ACME_TIMER_WAS_ENABLED=false
}
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
    [ "$RR_SUBSCRIPTION_WAS_ACTIVE" = false ] && \
    [ "$RR_IP_ACME_WAS_PRESENT" = false ] && \
    [ "$RR_IP_ACME_WAS_READY" = false ] && \
    [ "$RR_IP_ACME_TIMER_WAS_ACTIVE" = false ] && \
    [ "$RR_IP_ACME_TIMER_WAS_ENABLED" = false ] || \
    fail 'inactive writer state was not preserved exactly'

RR_HEALTH_STATE_CAPTURED=false
systemctl() { return 1; }
if rr_capture_update_writer_state; then
    fail 'systemd query failure was persisted as an all-inactive writer snapshot'
fi
[ "$RR_HEALTH_STATE_CAPTURED" = false ] || \
    fail 'failed writer capture published partial health evidence'

printf '%s\n' '[2/15] repeated health freezes preserve the first observed enabled state'
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
    local sync_fault=false
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
    # Managed start identity has dedicated coverage.  This fixture exercises
    # captured writer-state replay and intentionally does not install units.
    rr_managed_service_start_is_safe() { return 0; }

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

    if [ "$wanted_failure" = sync-error ]; then
        sync_fault=true
        sync() {
            if [ "$#" -eq 0 ] && [ "$sync_fault" = true ]; then
                return 1
            fi
            command sync "$@"
        }
    fi

    if [ "$wanted_failure" = true ] || [ "$wanted_failure" = query-error ] || \
       [ "$wanted_failure" = incoherent ] || [ "$wanted_failure" = sync-error ]; then
        set +e
        main recover
        rc=$?
        set -e
        [ "$rc" -eq 1 ] || fail 'restart failure was reported as success'
        [ "$(cat "$tx/phase")" = "$recovery_phase" ] || \
            fail 'retryable pre-mutation failure did not preserve its original phase'
        [ -e "$RR_ACTIVE_TX" ] || fail 'restart failure removed active transaction evidence'
        [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || fail 'restart failure removed the maintenance marker'
        if [ "$recovery_phase" = state_recorded ]; then
            if grep -Eq '^(enable|disable|restart|stop) (rr-nexus|sing-box|argo-rr-health.timer)' \
                "$operation_log"; then
                fail 'state-record durability failure touched a service before freezing began'
            fi
            [ "${active[argo-rr-health.timer]:-false}" = true ] && \
                [ "${enabled[argo-rr-health.timer]:-false}" = true ] || \
                fail 'state-record durability failure changed the untouched health timer'
        else
            [ "${active[argo-rr-health.timer]:-false}" = false ] && \
                [ "${active[argo-rr-health.service]:-false}" = false ] && \
                [ "${enabled[argo-rr-health.timer]:-false}" = false ] || \
                fail 'restart failure left a health writer active or enabled'
        fi
        wanted_failure=false
        sync_fault=false
        main recover || fail 'retryable pre-mutation recovery did not succeed on a second boot'
        [ "$(cat "$tx/phase")" = aborted ] && [ ! -e "$RR_ACTIVE_TX" ] && \
            [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
            fail 'second recovery did not durably consume the retryable transaction'
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

printf '%s\n' '[3/15] state-record crash recovery touches no service before freezing begins'
run_recovery_case state-recorded false state_recorded
run_recovery_case state-recorded-sync sync-error state_recorded

printf '%s\n' '[4/15] pre-mutation crash recovery restores exact active/enabled state'
run_recovery_case restore-success false

printf '%s\n' '[5/15] a real SIGKILL leaves durable state that standalone recovery consumes'
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

printf '%s\n' '[6/15] recovery freezes health writers before a SIGKILL can interrupt runtime restore'
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

printf '%s\n' '[7/15] restart failure is fail-closed and retains transaction evidence'
run_recovery_case restore-failure true
run_recovery_case restore-query-error query-error
run_recovery_case restore-absent absent
run_recovery_case restore-incoherent incoherent

printf '%s\n' '[8/15] a committed crash retries finalization before clearing maintenance'
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
    rr_restore_recorded_writer_state() { return 0; }
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")" \
        "$(dirname "$RR_LAUNCHER")" "$RR_LIB_DIR/modules"
    chmod 700 "$tx" "$tx/backup"
    chmod 0755 "$RR_LIB_DIR" "$RR_LIB_DIR/modules"
    printf 'SCRIPT_VERSION="7.1.1"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
    chmod 0600 "$RR_LIB_DIR/modules/00-runtime.sh"
    printf '2\n' > "$tx/transaction-format"
    : > "$tx/backup/writer_state_complete"
    : > "$tx/backup/health_timer_was_enabled"
    chmod 600 "$tx/transaction-format" "$tx/backup/writer_state_complete" \
        "$tx/backup/health_timer_was_enabled"
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
    [ "$(cat "$tx/$RR_COMMITTED_SETTLED_NAME")" = "$RR_COMMITTED_SETTLED_VALUE" ] ||
        fail 'committed crash recovery did not publish durable settled evidence'
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
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 1 ] || \
        fail 'unsafe maintenance evidence triggered settled finalization'

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
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 1 ] ||
        fail 'settled durability retry re-ran candidate finalization'
    unset -f sync

    main recover || fail 'committed cleanup did not succeed after the durability fault cleared'
    [ "$(cat "$tx/phase")" = committed ] && [ -e "$RR_ACTIVE_TX" ] &&
        [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'committed cleanup retry changed its terminal phase or rollback pointer'
    [ ! -e "$restore_log" ] || fail 'second recovery restored or rolled back a committed candidate'
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 1 ] ||
        fail 'settled cleanup re-ran candidate finalization'

    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    export RR_TEST_FINALIZE_FAIL=1
    main recover || fail 'settled cleanup incorrectly depended on candidate finalization'
    [ "$(cat "$tx/phase")" = committed ] && [ -e "$RR_ACTIVE_TX" ] && \
        [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'settled cleanup changed its rollback window or retained maintenance'
    main recover || fail 'dormant settled recovery was not idempotent'
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 1 ] ||
        fail 'dormant settled recovery touched the candidate finalizer'

    chmod 0644 "$tx/$RR_COMMITTED_SETTLED_NAME"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail 'unsafe settled evidence was accepted'
    [ "$(wc -l < "$RR_TEST_FINALIZE_LOG")" -eq 1 ] && [ ! -e "$restore_log" ] ||
        fail 'unsafe settled evidence caused host-state mutation'
    chmod 0600 "$tx/$RR_COMMITTED_SETTLED_NAME"
)

# A directory-fsync error after the settled rename is ambiguous: the valid
# marker is already live.  The first recovery must retain maintenance without
# freezing writers, and the retry must consume the marker without replaying
# finalization or the old writer snapshot.
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/settled-publish-fault/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/settled-publish-fault/run/update-maintenance"
    export RR_QUARANTINE_FILE="$RR_TX_ROOT/quarantine"
    export RR_QUARANTINE_UNIT="$TEST_ROOT/settled-publish-fault/quarantine.service"
    export RR_QUARANTINE_READY="$TEST_ROOT/settled-publish-fault/quarantine.ready"
    export RR_QUARANTINE_GUARD_STATE="$TEST_ROOT/settled-publish-fault/guard-state"
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    marker_parent=$(dirname "$RR_UPDATE_MAINTENANCE_FILE")
    mkdir -p "$tx/backup" "$marker_parent"
    chmod 700 "$tx" "$tx/backup" "$marker_parent"
    printf '2\n' > "$tx/transaction-format"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    : > "$tx/backup/writer_state_complete"
    chmod 600 "$tx/transaction-format" "$tx/phase" "$RR_ACTIVE_TX" \
        "$RR_UPDATE_MAINTENANCE_FILE" "$tx/backup/writer_state_complete"

    finalize_calls=0
    writer_restore_calls=0
    freeze_calls=0
    sync_fault=true
    mv_fault=none
    rr_finalize_committed_candidate() { finalize_calls=$((finalize_calls + 1)); }
    rr_restore_recorded_writer_state() { writer_restore_calls=$((writer_restore_calls + 1)); }
    rr_recovery_fail_with_health_frozen() { freeze_calls=$((freeze_calls + 1)); return 1; }
    rr_quarantine_artifact_evidence_present() { return 1; }
    systemctl() { fail "settled publication fault touched systemd: $*"; }
    sync() {
        if [ "$sync_fault" = true ] && [ "$*" = "-f $tx" ] && \
           [ -e "$tx/$RR_COMMITTED_SETTLED_NAME" ]; then
            return 1
        fi
        command sync "$@"
    }
    mv() {
        local destination="${@: -1}"
        if [ "$destination" = "$RR_TX_ROOT/transactions/direct-valid/$RR_COMMITTED_SETTLED_NAME" ] || \
           [ "$destination" = "$RR_TX_ROOT/transactions/direct-unsafe/$RR_COMMITTED_SETTLED_NAME" ]; then
            command mv "$@" || return
            case "$mv_fault" in
                valid) return 1 ;;
                unsafe) chmod 0644 "$destination"; return 1 ;;
            esac
        fi
        command mv "$@"
    }

    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$freeze_calls" -eq 0 ] && \
        [ "$finalize_calls" -eq 1 ] && [ "$writer_restore_calls" -eq 1 ] ||
        fail 'post-rename settled fsync fault froze writers or skipped committed work'
    rr_committed_settled_state "$tx" ||
        fail 'post-rename settled fsync fault lost its strict visible marker'
    [ -e "$RR_ACTIVE_TX" ] && [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'post-rename settled fsync fault discarded active or maintenance evidence'

    sync_fault=false
    main recover || fail 'valid visible settled marker was not retryable'
    [ "$freeze_calls" -eq 0 ] && [ "$finalize_calls" -eq 1 ] && \
        [ "$writer_restore_calls" -eq 1 ] && [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'settled retry froze or replayed committed writer/finalizer state'

    for direct_case in valid unsafe; do
        direct_tx="$RR_TX_ROOT/transactions/direct-$direct_case"
        mkdir -p "$direct_tx"
        chmod 700 "$direct_tx"
        mv_fault="$direct_case"
        set +e
        rr_publish_committed_settled "$direct_tx"
        direct_rc=$?
        set -e
        if [ "$direct_case" = valid ]; then
            [ "$direct_rc" -eq 2 ] && rr_committed_settled_state "$direct_tx" ||
                fail 'mv ambiguity with a strict marker was not classified as visible'
        else
            [ "$direct_rc" -eq 1 ] ||
                fail 'unsafe post-mv settled evidence was classified as safely visible'
        fi
    done
)

# Settled format-2 recovery needs only trusted live control metadata.  Its
# backup is retained solely for an explicit manual rollback, so missing backup
# evidence must not take down a healthy committed candidate during boot.
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/settled-format2/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/settled-format2/run/update-maintenance"
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx"
    chmod 700 "$tx"
    printf '2\n' > "$tx/transaction-format"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$RR_COMMITTED_SETTLED_VALUE" > "$tx/$RR_COMMITTED_SETTLED_NAME"
    chmod 600 "$tx/transaction-format" "$tx/phase" "$RR_ACTIVE_TX" \
        "$tx/$RR_COMMITTED_SETTLED_NAME"
    finalize_calls=0
    restore_calls=0
    freeze_calls=0
    systemctl_calls=0
    rr_finalize_committed_candidate() { finalize_calls=$((finalize_calls + 1)); return 97; }
    rr_restore_transaction() { restore_calls=$((restore_calls + 1)); return 97; }
    rr_freeze_health_writers_strict() { freeze_calls=$((freeze_calls + 1)); return 0; }
    systemctl() { systemctl_calls=$((systemctl_calls + 1)); return 1; }

    main recover || fail 'settled format-2 recovery depended on rollback backup metadata'
    [ "$finalize_calls" -eq 0 ] && [ "$restore_calls" -eq 0 ] && \
        [ "$freeze_calls" -eq 0 ] && [ "$systemctl_calls" -eq 0 ] ||
        fail 'settled format-2 fast path changed live writer or finalizer state'

    set +e
    main rollback
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$restore_calls" -eq 0 ] && \
        [ "$(cat "$tx/phase")" = committed ] ||
        fail 'manual rollback accepted a settled transaction with no safe backup'

    freeze_calls=0
    chmod 0644 "$tx/phase"
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$freeze_calls" -eq 1 ] && \
        [ "$finalize_calls" -eq 0 ] && [ "$restore_calls" -eq 0 ] ||
        fail 'settled fast path bypassed format-2 control metadata validation'
)

# A durable settled marker makes ordinary recovery a no-op, so manual
# rollback must leave committed before its first runtime mutation.  A later
# boot then resumes rolling_back instead of mistaking it for a dormant window.
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/manual-rolling/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/manual-rolling/run/update-maintenance"
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    marker_parent=$(dirname "$RR_UPDATE_MAINTENANCE_FILE")
    operation_log="$TEST_ROOT/manual-rolling/operations"
    mkdir -p "$tx/backup" "$marker_parent"
    chmod 700 "$RR_TX_ROOT" "$tx" "$tx/backup" "$marker_parent"
    printf '2\n' > "$tx/transaction-format"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$RR_COMMITTED_SETTLED_VALUE" > "$tx/$RR_COMMITTED_SETTLED_NAME"
    : > "$tx/backup/writer_state_complete"
    chmod 600 "$tx/transaction-format" "$tx/phase" "$RR_ACTIVE_TX" \
        "$tx/$RR_COMMITTED_SETTLED_NAME" "$tx/backup/writer_state_complete"
    rr_prepare_legacy_lock_for_rollback() { return 0; }
    restore_calls=0
    fail_marker_parent_sync=false
    fail_phase_tx_sync=false
    eval "$(declare -f rr_create_update_maintenance_marker | \
        sed '1s/rr_create_update_maintenance_marker/rr_create_update_maintenance_marker_real/')"
    rr_create_update_maintenance_marker() {
        printf '%s\n' create-maintenance >> "$operation_log"
        rr_create_update_maintenance_marker_real "$@"
    }
    eval "$(declare -f rr_recovery_write_phase | \
        sed '1s/rr_recovery_write_phase/rr_recovery_write_phase_real/')"
    rr_recovery_write_phase() {
        printf 'phase:%s\n' "$2" >> "$operation_log"
        rr_recovery_write_phase_real "$@"
    }
    sync() {
        if [ "$fail_marker_parent_sync" = true ] && \
           [ "$*" = "-f $marker_parent" ] && \
           [ -e "$RR_UPDATE_MAINTENANCE_FILE" ]; then
            return 1
        fi
        if [ "$fail_phase_tx_sync" = true ] && [ "$*" = "-f $tx" ] && \
           [ "$(cat "$tx/phase" 2>/dev/null || true)" = rolling_back ]; then
            return 1
        fi
        command sync "$@"
    }
    rr_restore_transaction() {
        restore_calls=$((restore_calls + 1))
        printf '%s\n' restore-runtime >> "$operation_log"
        rr_update_maintenance_marker_state "$tx" ||
            fail 'manual rollback reached runtime restore without a strict maintenance gate'
        [ "$(cat "$tx/phase")" = rolling_back ] ||
            fail 'manual rollback reached runtime restore before rolling_back was durable'
        return 0
    }

    # An unsafe parent must be rejected before chmod/marker/phase mutation.
    chmod 0777 "$marker_parent"
    : > "$operation_log"
    set +e
    main rollback
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(stat -c %a "$marker_parent")" = 777 ] && \
        [ "$(cat "$tx/phase")" = committed ] && [ "$restore_calls" -eq 0 ] && \
        [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'unsafe maintenance parent was modified or allowed rollback mutation'

    # If rename succeeds but the parent fsync fails, the visible marker is
    # retained.  No phase/runtime mutation is allowed until a retry durably
    # flushes that existing marker and its parent.
    chmod 0700 "$marker_parent"
    fail_marker_parent_sync=true
    : > "$operation_log"
    set +e
    main rollback
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = committed ] && \
        [ "$restore_calls" -eq 0 ] && [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] ||
        fail 'maintenance parent-fsync fault reached rollback phase or runtime mutation'

    fail_marker_parent_sync=false
    rr_ensure_update_maintenance_marker "$tx" ||
        fail 'visible maintenance marker could not be made durable on retry'
    rr_update_maintenance_marker_state "$tx" ||
        fail 'durable maintenance retry did not retain strict transaction ownership'

    # The rolling_back rename can be visible even if its transaction-directory
    # fsync reports failure.  That invocation must stop before restore; boot
    # recovery then treats the visible phase as in-progress and resumes only
    # after re-validating and flushing the maintenance gate.
    fail_phase_tx_sync=true
    : > "$operation_log"
    set +e
    main rollback
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = rolling_back ] && \
        [ "$restore_calls" -eq 0 ] ||
        fail 'rolling_back directory-fsync fault reached runtime restoration'
    [ "$(sed -n '1p' "$operation_log")" = create-maintenance ] && \
        [ "$(sed -n '2p' "$operation_log")" = phase:rolling_back ] && \
        [ "$(wc -l < "$operation_log")" -eq 2 ] ||
        fail 'phase durability failure did not stop between maintenance and runtime restore'

    fail_phase_tx_sync=false
    : > "$operation_log"
    main recover || fail 'boot recovery did not resume rolling_back'
    [ "$(cat "$tx/phase")" = rolling_back ] && [ "$restore_calls" -eq 1 ] && \
        [ "$(sed -n '1p' "$operation_log")" = create-maintenance ] && \
        [ "$(sed -n '2p' "$operation_log")" = restore-runtime ] ||
        fail 'rolling_back boot recovery skipped its durable gate or restore'
)

printf '%s\n' '[9/15] aborted recovery is idempotent and requires a durable active unlink'
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

printf '%s\n' '[10/15] normal terminal cleanup retries restore the recorded writer state'
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

printf '%s\n' '[11/15] invalid evidence and systemd query errors fail closed with health writers frozen'
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
    assert_health_untouched() {
        [ -e "$timer_active" ] && [ -e "$timer_enabled" ] && [ -e "$service_active" ] ||
            fail "$1 changed a writer before the state_recorded freeze boundary"
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
    assert_health_untouched 'format-2 0644 state-recorded metadata'

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

printf '%s\n' '[12/15] recorded subscription state resumes through the narrow bounded entry point'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_TX_ROOT="$TEST_ROOT/subscription-resume/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_LIB_DIR="$TEST_ROOT/subscription-resume/runtime"
    export RR_LAUNCHER="$TEST_ROOT/subscription-resume/rr"
    export RR_CONFIG_FILE="$TEST_ROOT/subscription-resume/config"
    export RR_TEST_REFRESH_LOG="$TEST_ROOT/subscription-resume/refresh.log"
    export RR_TEST_SUBSCRIPTION_RUNNING="$TEST_ROOT/subscription-resume/running"
    export RR_TEST_SUBSCRIPTION_STOPPED="$TEST_ROOT/subscription-resume/stopped"
    backup="$RR_TX_ROOT/transactions/tx/backup"
    mkdir -p "$backup" "$RR_LIB_DIR"
    : > "$backup/writer_state_complete"
    : > "$backup/subscription_was_running"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s|%s\n" "${RR_UPDATE_LOCK_HELD:-0}" "$*" > "$RR_TEST_REFRESH_LOG"' \
        'case "${1:-}" in' \
        '  --health-check) exit 0 ;;' \
        '  --refresh-subscription)' \
        '    case "${RR_TEST_REFRESH_RESULT:-success}" in' \
        '      success) : > "$RR_TEST_SUBSCRIPTION_RUNNING" ;;' \
        '      partial-failure) : > "$RR_TEST_SUBSCRIPTION_RUNNING"; exit 124 ;;' \
        '      false-success) : ;;' \
        '      *) exit 64 ;;' \
        '    esac' \
        '    ;;' \
        '  *) exit 64 ;;' \
        'esac' > "$RR_LAUNCHER"
    chmod 700 "$RR_LAUNCHER"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"

    rr_restore_unit_state() { :; }
    rr_restart_health_service_bounded() { :; }
    rr_subscription_running() { [ -e "$RR_TEST_SUBSCRIPTION_RUNNING" ]; }
    rr_stop_subscription_servers() {
        : > "$RR_TEST_SUBSCRIPTION_STOPPED"
        rm -f -- "$RR_TEST_SUBSCRIPTION_RUNNING"
    }

    export RR_TEST_REFRESH_RESULT=success
    rr_restore_recorded_writer_state "$backup" normal ||
        fail 'standalone recovery did not resume a recorded subscription writer'
    [ "$(cat "$RR_TEST_REFRESH_LOG")" = '1|--refresh-subscription' ] ||
        fail 'standalone recovery used a broad or unlocked subscription entry point'
    [ -e "$RR_TEST_SUBSCRIPTION_RUNNING" ] ||
        fail 'successful subscription refresh did not satisfy the running postcondition'
    [ ! -e "$RR_TEST_SUBSCRIPTION_STOPPED" ] ||
        fail 'successful subscription refresh was stopped unexpectedly'

    rm -f -- "$RR_TEST_REFRESH_LOG" "$RR_TEST_SUBSCRIPTION_RUNNING" \
        "$RR_TEST_SUBSCRIPTION_STOPPED"
    export RR_TEST_REFRESH_RESULT=false-success
    if rr_restore_recorded_writer_state "$backup" normal; then
        fail 'a zero-exit refresh with no managed worker was accepted'
    fi
    [ "$(cat "$RR_TEST_REFRESH_LOG")" = '1|--refresh-subscription' ] &&
        [ -e "$RR_TEST_SUBSCRIPTION_STOPPED" ] ||
        fail 'a false-success refresh did not converge to the frozen failure state'

    rm -f -- "$RR_TEST_REFRESH_LOG" "$RR_TEST_SUBSCRIPTION_RUNNING" \
        "$RR_TEST_SUBSCRIPTION_STOPPED"
    export RR_TEST_REFRESH_RESULT=partial-failure
    if rr_restore_recorded_writer_state "$backup" normal; then
        fail 'a nonzero partial subscription refresh was accepted'
    fi
    [ -e "$RR_TEST_SUBSCRIPTION_STOPPED" ] &&
        [ ! -e "$RR_TEST_SUBSCRIPTION_RUNNING" ] ||
        fail 'a partial subscription refresh left its managed worker alive'

    rm -f -- "$RR_TEST_REFRESH_LOG" "$RR_TEST_SUBSCRIPTION_RUNNING" \
        "$RR_TEST_SUBSCRIPTION_STOPPED"
    mock_bin="$TEST_ROOT/subscription-resume/bin"
    systemd_run_log="$TEST_ROOT/subscription-resume/systemd-run.log"
    mkdir -p "$mock_bin"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s\n" "$*" > "$RR_TEST_SYSTEMD_RUN_LOG"' \
        'while [ "$#" -gt 0 ]; do' \
        '  if [ "$1" = -- ]; then shift; break; fi' \
        '  shift' \
        'done' \
        '[ "$#" -gt 0 ] || exit 64' \
        'exec "$@"' > "$mock_bin/systemd-run"
    chmod 700 "$mock_bin/systemd-run"
    export PATH="$mock_bin:$PATH"
    export RR_TEST_SYSTEMD_RUN_LOG="$systemd_run_log"
    export RR_TEST_REFRESH_RESULT=success
    export RR_UPDATE_RECOVERY_SERVICE=1
    systemctl() {
        [ "${1:-}:${2:-}" = is-active:--quiet ]
    }
    rr_restore_recorded_writer_state "$backup" normal ||
        fail 'systemd recovery did not resume subscription outside its oneshot cgroup'
    grep -Fq -- '--collect' "$systemd_run_log" &&
        grep -Fq -- '--scope' "$systemd_run_log" &&
        grep -Eq -- '--unit=rr-subscription-recovery-[0-9]+-[0-9]+\.scope([[:space:]]|$)' \
            "$systemd_run_log" &&
        grep -Fq -- "$RR_LAUNCHER --refresh-subscription" "$systemd_run_log" ||
        fail 'systemd recovery did not create the bounded subscription scope'
    if grep -Fq -- 'PIDFile=' "$systemd_run_log"; then
        fail 'subscription scope delegated ownership of the shared application PID file to systemd'
    fi
    [ "$(cat "$RR_TEST_REFRESH_LOG")" = '1|--refresh-subscription' ] &&
        [ -e "$RR_TEST_SUBSCRIPTION_RUNNING" ] &&
        [ -e "$RR_TEST_SUBSCRIPTION_STOPPED" ] ||
        fail 'transient subscription scope lost delegated refresh state'

    rm -f -- "$RR_TEST_SUBSCRIPTION_RUNNING" "$RR_TEST_SUBSCRIPTION_STOPPED"
    inactive_stop_log="$TEST_ROOT/subscription-resume/inactive-scope-stop.log"
    systemctl() {
        case "${1:-}:${2:-}" in
            is-active:--quiet) return 1 ;;
            stop:rr-subscription-recovery-*.scope)
                printf '%s\n' "$2" > "$inactive_stop_log"
                return 0
                ;;
            *) return 1 ;;
        esac
    }
    sleep() { :; }
    if rr_restore_recorded_writer_state "$backup" normal; then
        fail 'an inactive subscription scope was accepted as durable recovery'
    fi
    unset -f sleep
    grep -Eq '^rr-subscription-recovery-[0-9]+-[0-9]+\.scope$' \
        "$inactive_stop_log" &&
        [ -e "$RR_TEST_SUBSCRIPTION_STOPPED" ] &&
        [ ! -e "$RR_TEST_SUBSCRIPTION_RUNNING" ] ||
        fail 'inactive subscription scope did not converge to the stopped failure state'
    grep -Fq 'Environment=RR_UPDATE_RECOVERY_SERVICE=1' \
        "$REPO_ROOT/scripts/install-core.sh" &&
        grep -Fq 'UMask=0077' "$REPO_ROOT/scripts/install-core.sh" ||
        fail 'installed recovery unit does not select the cgroup-safe resume path'
)

printf '%s\n' '[13/15] recovery bridges legacy locks and delegates both flock descriptors safely'
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

printf '%s\n' '[14/15] maintenance state is root-only and bound to one transaction'
grep -Fq "0:0:600:1" "$REPO_ROOT/scripts/install-core.sh" || fail 'installer lacks strict maintenance marker mode check'
grep -Fq '[ "$owner" = "$marker_tx" ]' "$REPO_ROOT/scripts/install-core.sh" || fail 'installer marker is not transaction-bound'
grep -Fq '[ "$value" = "$tx" ]' "$REPO_ROOT/scripts/update-recover.sh" || fail 'recovery marker is not transaction-bound'

printf '%s\n' '[15/15] legacy committed recovery preserves the 7.1.0 terminal contract'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/update-recover.sh"
    unset RR_UPDATE_RECOVER_SOURCE_ONLY

    RR_TX_ROOT="$TEST_ROOT/legacy-committed/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    RR_LIB_DIR="$TEST_ROOT/legacy-committed/runtime"
    RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/legacy-committed/run/update-maintenance"
    RR_UPDATE_LOCK_HELD=1
    RR_UPDATE_LOCK_FDS_CLOSED=1
    tx="$RR_TX_ROOT/transactions/20260830T000000Z-710"
    mkdir -p "$tx/backup" "$RR_LIB_DIR/modules" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    chmod 700 "$RR_TX_ROOT" "$RR_TX_ROOT/transactions" "$tx" "$tx/backup" \
        "$RR_LIB_DIR" "$RR_LIB_DIR/modules" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    printf 'SCRIPT_VERSION="7.1.0"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
    printf '%s\n' committed > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_LIB_DIR/modules/00-runtime.sh" "$tx/phase" "$RR_ACTIVE_TX"

    finalize_calls=0
    writer_calls=0
    systemd_calls=0
    rr_finalize_committed_candidate() {
        finalize_calls=$((finalize_calls + 1))
        return 1
    }
    rr_restore_recorded_writer_state() {
        writer_calls=$((writer_calls + 1))
        return 1
    }
    rr_freeze_health_writers_strict() {
        writer_calls=$((writer_calls + 1))
        return 1
    }
    systemctl() {
        systemd_calls=$((systemd_calls + 1))
        return 1
    }

    main recover >/dev/null 2>&1 ||
        fail 'legacy committed recovery rejected an absent maintenance marker'
    [ -f "$RR_ACTIVE_TX" ] && [ "$(cat "$tx/phase")" = committed ] ||
        fail 'legacy committed recovery retired the old rollback window itself'
    [ "$finalize_calls" -eq 0 ] && [ "$writer_calls" -eq 0 ] &&
        [ "$systemd_calls" -eq 0 ] ||
        fail 'legacy committed recovery invoked a v2 finalizer or replayed writers'

    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    main recover >/dev/null 2>&1 ||
        fail 'legacy committed recovery could not clear its matching retry marker'
    [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] && [ -f "$RR_ACTIVE_TX" ] ||
        fail 'legacy committed retry did not converge marker-only residue safely'
    [ "$finalize_calls" -eq 0 ] && [ "$writer_calls" -eq 0 ] &&
        [ "$systemd_calls" -eq 0 ] ||
        fail 'legacy committed retry touched candidate or writer state'

    printf '%s\n' "$tx-forged" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    if main recover >/dev/null 2>&1; then
        fail 'legacy committed recovery accepted a mismatched maintenance marker'
    fi
    [ -f "$RR_UPDATE_MAINTENANCE_FILE" ] && [ -f "$RR_ACTIVE_TX" ] &&
        [ "$(cat "$tx/phase")" = committed ] ||
        fail 'unsafe legacy maintenance evidence was not retained fail-closed'
    [ "$finalize_calls" -eq 0 ] && [ "$writer_calls" -eq 0 ] &&
        [ "$systemd_calls" -eq 0 ] ||
        fail 'unsafe legacy evidence triggered finalization or writer mutation'
)

printf '%s\n' 'update writer freeze regression: PASS'
