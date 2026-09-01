#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-install-rollback-boundary.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'install-core rollback boundary regression: FAIL: %s\n' "$*" >&2
    exit 1
}

function_body() {
    local source_file="$1" function_name="$2"
    awk -v function_name="$function_name" '
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
    ' "$source_file"
}

make_phase() {
    local transaction="$1" phase="$2"
    mkdir -p "$transaction"
    chmod 700 "$transaction"
    printf '%s\n' "$phase" > "$transaction/phase"
    chmod 600 "$transaction/phase"
}

printf '%s\n' '[1/11] cleanup preserves a committed transaction even if the active flag is stale'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_reconcile_committed_writer_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_cleanup)"

    RR_TX_ROOT="$TEST_ROOT/committed-cleanup/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    TX_DIR="$RR_TX_ROOT/transactions/tx"
    BACKUP_DIR="$TX_DIR/backup"
    RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/committed-cleanup/update-maintenance"
    make_phase "$TX_DIR" committed
    mkdir -p "$BACKUP_DIR"
    printf '%s\n' "$TX_DIR" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$RR_UPDATE_MAINTENANCE_FILE"
    printf '%s\n' "$TX_DIR" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    rollback_log="$TEST_ROOT/committed-cleanup/rollback.log"
    rr_rollback() { printf '%s\n' rollback >> "$rollback_log"; }
    rr_restore_committed_subscription_state() { printf '%s\n' restore-subscription >> "$rollback_log"; }
    rr_verify_update_writer_state() { printf '%s\n' verify-writers >> "$rollback_log"; return 1; }
    rr_error() { :; }
    TRANSACTION_ACTIVE=true
    ROLLBACK_FAILED=false
    KEEP_TRANSACTION=false
    RR_UPDATE_WRITERS_FROZEN=false
    RR_HEALTH_MONITOR_FROZEN=false
    RR_UPDATE_MAINTENANCE_ACTIVE=true
    STAGE_ROOT=""
    NEW_RUNTIME=""
    NEW_LAUNCHER=""
    OLD_RUNTIME=""

    set +e
    rr_reconcile_committed_writer_state "$BACKUP_DIR"
    reconcile_status=$?
    rr_cleanup "$reconcile_status"
    cleanup_status=$?
    set -e
    [ "$reconcile_status" -ne 0 ] && [ "$cleanup_status" -ne 0 ] ||
        fail 'cleanup lost the committed writer-verification failure'
    [ "$(cat "$rollback_log")" = $'restore-subscription\nverify-writers' ] ||
        fail 'committed writer failure crossed its boundary or entered rollback'
    [ "$TRANSACTION_ACTIVE" = false ] && [ "$KEEP_TRANSACTION" = true ] || \
        fail 'cleanup did not retain committed transaction state for finalizer retry'
    [ "$(cat "$TX_DIR/phase")" = committed ] && [ -f "$RR_ACTIVE_TX" ] || \
        fail 'cleanup removed committed transaction evidence'
    [ "$(cat "$RR_UPDATE_MAINTENANCE_FILE")" = "$TX_DIR" ] ||
        fail 'cleanup removed committed maintenance evidence'
    [ ! -e "$TX_DIR/committed-settled" ] ||
        fail 'writer verification failure published settled evidence'
)

printf '%s\n' '[2/11] direct rollback also refuses a trusted committed phase'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_rollback)"
    RR_TX_ROOT="$TEST_ROOT/committed-direct/update"
    TX_DIR="$RR_TX_ROOT/transactions/tx"
    make_phase "$TX_DIR" committed
    TRANSACTION_ACTIVE=true
    ROLLBACK_FAILED=false
    KEEP_TRANSACTION=false
    operation_log="$TEST_ROOT/committed-direct/operations"
    rr_error() { :; }
    rr_quiesce_health_monitor_for_rollback() {
        printf '%s\n' quiesce >> "$operation_log"
        return 1
    }

    rr_rollback || fail 'committed rollback guard returned an unexpected failure'
    [ ! -e "$operation_log" ] || fail 'direct committed rollback reached host mutation'
    [ "$TRANSACTION_ACTIVE" = false ] && [ "$KEEP_TRANSACTION" = true ] || \
        fail 'direct committed rollback did not retain transaction evidence'
)

run_migrating_rollback() (
    local name="$1" systemctl_failure="${2:-false}"
    local restore_query_failure="${3:-false}" global_sync_failure="${4:-false}"
    local service_state_mismatch="${5:-false}"
    local write_phase_body=""
    # shellcheck disable=SC2294
    write_phase_body=$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_write_phase)
    write_phase_body=${write_phase_body/rr_write_phase()/rr_test_production_write_phase()}
    # shellcheck disable=SC2294
    eval "$write_phase_body"
    rr_write_phase() {
        printf 'phase:%s\n' "$1" >> "$operation_log"
        rr_test_production_write_phase "$@"
    }
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_quiesce_health_monitor_for_rollback)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_close_inherited_installer_lock_fds)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_run_with_delegated_update_lock)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_sync_host_state_before_terminal)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_format_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_legacy_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_previous_transaction_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_active_transaction)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_republish_active_pointer_for_retry)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_clear_active_transaction_pointer)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_rollback)"

    case_root="$TEST_ROOT/$name"
    RR_TX_ROOT="$case_root/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    TX_DIR="$RR_TX_ROOT/transactions/tx"
    BACKUP_DIR="$TX_DIR/backup"
    RR_LIB_DIR="$case_root/live-runtime"
    OLD_RUNTIME="$TX_DIR/old-runtime"
    RR_LAUNCHER="$case_root/rr"
    RR_RECOVERY_HELPER="$case_root/rr-update-recover"
    RR_UPDATE_EXTERNAL_HELPER="$case_root/rr-update-external-state"
    operation_log="$case_root/operations"
    mkdir -p "$BACKUP_DIR" "$RR_LIB_DIR" "$OLD_RUNTIME"
    make_phase "$TX_DIR" migrating
    printf '%s\n' old > "$OLD_RUNTIME/sentinel"
    printf '%s\n' candidate > "$RR_LIB_DIR/sentinel"
    printf '%s\n' "$TX_DIR" > "$RR_ACTIVE_TX"
    chmod 600 "$RR_ACTIVE_TX"
    : > "$operation_log"
    cat > "$RR_RECOVERY_HELPER" <<'EOF'
#!/bin/bash
printf 'normal\n' > "$2/rollback-subscription-status"
EOF
    chmod 755 "$RR_RECOVERY_HELPER"

    timer_active=true
    timer_enabled=true
    service_active=true
    restore_started=false
    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$operation_log"
        if [ "$systemctl_failure" = true ] || \
           { [ "$restore_query_failure" = true ] && [ "$restore_started" = true ]; }; then
            return 1
        fi
        case "$1:${2:-}" in
            show:--property=LoadState)
                if [ "${4:-}" = argo-rr-health.service ] && \
                   [ "$service_state_mismatch" = true ]; then
                    printf '%s\n' not-found
                else
                    printf '%s\n' loaded
                fi
                ;;
            show:--property=ActiveState)
                unit="${4:-}"
                if [ "$unit" = argo-rr-health.timer ]; then
                    [ "$timer_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
                elif [ "$service_state_mismatch" = true ]; then
                    printf '%s\n' inactive
                else
                    [ "$service_active" = true ] && printf '%s\n' active || printf '%s\n' inactive
                fi
                ;;
            show:--property=UnitFileState)
                if [ "${4:-}" = argo-rr-health.service ] && \
                   [ "$service_state_mismatch" = true ]; then
                    printf '%s\n' enabled
                else
                    [ "$timer_enabled" = true ] && printf '%s\n' enabled || printf '%s\n' disabled
                fi
                ;;
            disable:--now)
                timer_active=false
                timer_enabled=false
                ;;
            stop:argo-rr-health.service)
                service_active=false
                ;;
            *) ;;
        esac
        return 0
    }
    sync() {
        if [ "$#" -eq 0 ]; then
            printf '%s\n' sync:global >> "$operation_log"
            [ "$global_sync_failure" != true ]
            return
        fi
        printf 'sync:%s\n' "$*" >> "$operation_log"
        return 0
    }
    rr_error() { :; }
    rr_stop_subscription_servers() { printf '%s\n' stop-subscription >> "$operation_log"; }
    rr_restore_file() {
        restore_started=true
        printf 'restore-file:%s\n' "$1" >> "$operation_log"
    }
    rr_restore_dir() { printf 'restore-dir:%s\n' "$1" >> "$operation_log"; }
    rr_restore_sqlite() { printf 'restore-db:%s\n' "$1" >> "$operation_log"; }
    # IP-ACME directory replay is covered by the dedicated update/restore
    # suite; this fixture isolates the health-writer rollback boundary.
    rr_restore_ip_acme_update_directories() { return 0; }
    rr_install_restore_external_state_if_required() { return 0; }
    rr_restore_update_writer_state() {
        if [ "$restore_query_failure" = true ]; then
            systemctl show --property=LoadState --value sing-box >/dev/null 2>&1
        else
            return 0
        fi
    }
    rr_freeze_update_writers() {
        printf '%s\n' freeze-writers >> "$operation_log"
        RR_UPDATE_WRITERS_FROZEN=true
        RR_HEALTH_MONITOR_FROZEN=true
        return 0
    }
    rr_clear_update_maintenance_marker() { return 0; }
    sleep() { :; }
    TRANSACTION_ACTIVE=true
    RUNTIME_REPLACED=true
    ROLLBACK_FAILED=false
    KEEP_TRANSACTION=false
    RR_UPDATE_WRITERS_FROZEN=true
    RR_HEALTH_MONITOR_FROZEN=true

    set +e
    rr_rollback
    rollback_status=$?
    set -e
    if [ "$systemctl_failure" = true ] || [ "$service_state_mismatch" = true ]; then
        [ "$rollback_status" -ne 0 ] || fail 'unsafe health unit state was accepted'
        [ "$(cat "$TX_DIR/phase")" = recovery_failed ] || \
            fail 'health freeze failure did not retain recovery_failed evidence'
        [ -d "$OLD_RUNTIME" ] && [ "$(cat "$RR_LIB_DIR/sentinel")" = candidate ] || \
            fail 'health freeze failure mutated old/live runtime directories'
        ! grep -q '^restore-' "$operation_log" || \
            fail 'health freeze failure continued into file restoration'
        [ "$KEEP_TRANSACTION" = true ] && [ "$ROLLBACK_FAILED" = true ] || \
            fail 'health freeze failure did not retain transaction state'
        return 0
    fi
    if [ "$restore_query_failure" = true ]; then
        [ "$rollback_status" -ne 0 ] || fail 'writer restore bus/query failure was accepted'
        [ "$(cat "$TX_DIR/phase")" = recovery_failed ] || \
            fail 'writer restore query failure published a terminal phase'
        [ -f "$RR_ACTIVE_TX" ] || fail 'writer restore query failure cleared active evidence'
        [ "$KEEP_TRANSACTION" = true ] && [ "$ROLLBACK_FAILED" = true ] || \
            fail 'writer restore query failure did not retain transaction state'
        ! grep -Eq '^phase:rolled_back(_degraded)?$' "$operation_log" || \
            fail 'writer restore query failure briefly published a rollback terminal'
        return 0
    fi
    if [ "$global_sync_failure" = true ]; then
        [ "$rollback_status" -ne 0 ] || fail 'failed global sync was accepted'
        [ "$(cat "$TX_DIR/phase")" = recovery_failed ] || \
            fail 'failed global sync published a terminal rollback phase'
        [ -f "$RR_ACTIVE_TX" ] || fail 'failed global sync cleared active evidence'
        [ "$KEEP_TRANSACTION" = true ] && [ "$ROLLBACK_FAILED" = true ] && \
            [ "$RR_UPDATE_WRITERS_FROZEN" = true ] || \
            fail 'failed global sync did not retain a frozen recoverable transaction'
        ! grep -Eq '^phase:rolled_back(_degraded)?$' "$operation_log" || \
            fail 'failed global sync briefly published a terminal phase'
        return 0
    fi
    [ "$rollback_status" -eq 0 ] || fail 'strict health quiesce rejected a valid rollback'
    [ "$(cat "$RR_LIB_DIR/sentinel")" = old ] || fail 'valid rollback did not restore old runtime'
    disable_line=$(grep -n '^systemctl:disable --now argo-rr-health.timer$' \
        "$operation_log" | head -n 1 | cut -d: -f1)
    stop_line=$(grep -n '^systemctl:stop argo-rr-health.service$' \
        "$operation_log" | head -n 1 | cut -d: -f1)
    restore_line=$(grep -n '^restore-file:' "$operation_log" | head -n 1 | cut -d: -f1)
    [[ "$disable_line" =~ ^[0-9]+$ && "$stop_line" =~ ^[0-9]+$ && \
       "$restore_line" =~ ^[0-9]+$ ]] || fail 'health freeze/restore ordering evidence is incomplete'
    [ "$disable_line" -lt "$restore_line" ] && [ "$stop_line" -lt "$restore_line" ] || \
        fail 'old files could be restored before candidate health writers stopped'
    sync_line=$(grep -n '^sync:global$' "$operation_log" | tail -n 1 | cut -d: -f1)
    terminal_line=$(grep -n '^phase:rolled_back$' "$operation_log" | tail -n 1 | cut -d: -f1)
    [[ "$sync_line" =~ ^[0-9]+$ && "$terminal_line" =~ ^[0-9]+$ ]] || \
        fail 'rollback durability ordering evidence is incomplete'
    [ "$restore_line" -lt "$sync_line" ] && [ "$sync_line" -lt "$terminal_line" ] || \
        fail 'rollback terminal phase was published before restored host state was durable'
)

printf '%s\n' '[3/11] rollback re-freezes a candidate-reenabled health timer before old restore'
run_migrating_rollback health-success false

printf '%s\n' '[4/11] systemctl query/bus failure blocks rollback before old runtime mutation'
run_migrating_rollback health-query-failure true

printf '%s\n' '[5/11] inconsistent absent-but-enabled health service blocks rollback'
run_migrating_rollback health-state-mismatch false false false true

printf '%s\n' '[6/11] generic inactive and disabled checks reject query errors but accept absent units'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_unit_activity_matches)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_wait_unit_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_unit_file_state_matches)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_restore_unit_state)"
    sleep() { :; }
    systemctl() { return 1; }
    if rr_wait_unit_state missing.service inactive; then
        fail 'systemctl query failure masqueraded as an inactive unit'
    fi
    if rr_unit_file_state_matches missing.service disabled; then
        fail 'systemctl query failure masqueraded as a disabled unit'
    fi
    if rr_restore_unit_state missing.service "$TEST_ROOT/no-active" "$TEST_ROOT/no-enabled"; then
        fail 'writer restore accepted a systemctl bus failure'
    fi
    systemctl() {
        case "$1:${2:-}" in
            show:--property=LoadState) printf '%s\n' not-found ;;
            show:--property=ActiveState) printf '%s\n' inactive ;;
            show:--property=UnitFileState) printf '%s' '' ;;
            *) return 1 ;;
        esac
    }
    rr_wait_unit_state missing.service inactive || fail 'a proven absent unit was not inactive'
    rr_unit_file_state_matches missing.service disabled || fail 'a proven absent unit was not disabled'
    rr_restore_unit_state missing.service "$TEST_ROOT/no-active" "$TEST_ROOT/no-enabled" || \
        fail 'writer restore rejected a proven absent unit'
)

printf '%s\n' '[7/11] writer restore query failure retains maintenance and active evidence'
run_migrating_rollback writer-restore-query-failure false true false

printf '%s\n' '[8/11] failed global durability barrier never publishes or clears a terminal rollback'
run_migrating_rollback rollback-sync-failure false false true

printf '%s\n' '[9/11] prior aborted transactions are cleared durably before their directory is pruned'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_format_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_legacy_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_previous_transaction_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_active_transaction)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_republish_active_pointer_for_retry)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_clear_active_transaction_pointer)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_discard_previous_transaction)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_prune_stale_transactions)"

    RR_TX_ROOT="$TEST_ROOT/discard-aborted/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    tx="$RR_TX_ROOT/transactions/tx"
    unlink_fail=false
    parent_sync_fail=false
    republish_global_sync_fail=false
    parent_sync_failure_seen=false
    republish_global_sync_failure_seen=false
    mkdir -p "$tx"
    chmod 700 "$RR_TX_ROOT" "$tx"
    printf '2\n' > "$tx/transaction-format"
    printf 'aborted\n' > "$tx/phase"
    chmod 600 "$tx/transaction-format" "$tx/phase"
    publish_active() {
        printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
        chmod 600 "$RR_ACTIVE_TX"
    }
    rm() {
        if [ "$unlink_fail" = true ] && [ "$*" = "-f -- $RR_ACTIVE_TX" ]; then
            return 1
        fi
        command rm "$@"
    }
    sync() {
        if [ "$parent_sync_fail" = true ] && [ "$*" = "-f $RR_TX_ROOT" ]; then
            parent_sync_failure_seen=true
            return 1
        fi
        if [ "$#" -eq 0 ] && [ "$parent_sync_failure_seen" = true ] && \
           [ "$republish_global_sync_fail" = true ]; then
            republish_global_sync_failure_seen=true
            return 1
        fi
        command sync "$@"
    }

    publish_active
    unlink_fail=true
    if rr_discard_previous_transaction; then
        fail 'installer ignored an active-pointer unlink failure'
    fi
    [ -e "$RR_ACTIVE_TX" ] && [ -d "$tx" ] && [ "$(cat "$tx/phase")" = aborted ] ||
        fail 'unlink failure pruned aborted transaction evidence'

    unlink_fail=false
    rr_discard_previous_transaction || fail 'installer could not retry an aborted unlink'
    [ ! -e "$RR_ACTIVE_TX" ] && [ ! -e "$tx" ] ||
        fail 'successful aborted retry left its pointer or transaction directory'

    mkdir -p "$tx"
    chmod 700 "$RR_TX_ROOT" "$tx"
    printf '2\n' > "$tx/transaction-format"
    printf 'aborted\n' > "$tx/phase"
    chmod 600 "$tx/transaction-format" "$tx/phase"
    publish_active
    printf 'stale\n' > "${RR_ACTIVE_TX}.retry.STALE0"
    chmod 600 "${RR_ACTIVE_TX}.retry.STALE0"
    parent_sync_fail=true
    republish_global_sync_fail=true
    if rr_discard_previous_transaction; then
        fail 'installer ignored an active-parent fsync failure'
    fi
    [ -f "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ] && [ -d "$tx" ] && \
        [ "$(cat "$RR_ACTIVE_TX")" = "$tx" ] && [ "$(cat "$tx/phase")" = aborted ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$RR_ACTIVE_TX")" = 0:0:600:1 ] ||
        fail 'parent fsync failure did not republish strict terminal transaction evidence'
    [ "$republish_global_sync_failure_seen" = true ] ||
        fail 'republished pointer did not exercise the failing global durability fallback'
    [ "$(cat "${RR_ACTIVE_TX}.retry.STALE0")" = stale ] ||
        fail 'active-pointer republication collided with or removed a stale retry temporary'

    parent_sync_fail=false
    republish_global_sync_fail=false
    rr_discard_previous_transaction || fail 'installer did not consume the republished aborted pointer'
    [ ! -e "$RR_ACTIVE_TX" ] && [ ! -e "$tx" ] ||
        fail 'republished aborted retry left stale evidence'

    for corruption in symlink mode multiline; do
        command rm -rf -- "$tx"
        command rm -f -- "$RR_ACTIVE_TX"
        mkdir -p "$tx"
        chmod 700 "$RR_TX_ROOT" "$tx"
        printf '2\n' > "$tx/transaction-format"
        case "$corruption" in
            symlink)
                printf 'aborted\n' > "$TEST_ROOT/forged-phase"
                chmod 600 "$TEST_ROOT/forged-phase"
                ln -s "$TEST_ROOT/forged-phase" "$tx/phase"
                ;;
            mode)
                printf 'aborted\n' > "$tx/phase"
                chmod 0644 "$tx/phase"
                ;;
            multiline)
                printf 'aborted\ncommitted\n' > "$tx/phase"
                chmod 0600 "$tx/phase"
                ;;
        esac
        chmod 600 "$tx/transaction-format"
        publish_active
        if rr_discard_previous_transaction >/dev/null 2>&1; then
            fail "installer discarded a format-2 $corruption phase"
        fi
        [ -e "$RR_ACTIVE_TX" ] && [ -d "$tx" ] ||
            fail "format-2 $corruption phase lost active transaction evidence"
    done

    for unsafe_path in "$RR_TX_ROOT/transactions/../victim" \
        "$RR_TX_ROOT/transactions/nested/tx"; do
        command rm -f -- "$RR_ACTIVE_TX"
        canonical_unsafe=$(readlink -m -- "$unsafe_path")
        mkdir -p "$canonical_unsafe"
        chmod 700 "$canonical_unsafe"
        printf '2\n' > "$canonical_unsafe/transaction-format"
        printf 'aborted\n' > "$canonical_unsafe/phase"
        chmod 600 "$canonical_unsafe/transaction-format" "$canonical_unsafe/phase"
        printf '%s\n' "$unsafe_path" > "$RR_ACTIVE_TX"
        chmod 600 "$RR_ACTIVE_TX"
        if rr_discard_previous_transaction >/dev/null 2>&1; then
            fail "installer accepted a non-direct active transaction path: $unsafe_path"
        fi
        [ -f "$RR_ACTIVE_TX" ] && [ -d "$canonical_unsafe" ] && \
            [ "$(cat "$canonical_unsafe/phase")" = aborted ] ||
            fail "non-direct active transaction path lost protected evidence: $unsafe_path"
    done

    command rm -f -- "$RR_ACTIVE_TX"
    command rm -rf -- "$tx"
    stale_tx="$RR_TX_ROOT/transactions/stale"
    mkdir -p "$stale_tx"
    chmod 700 "$RR_TX_ROOT" "$stale_tx"
    printf '2\n' > "$stale_tx/transaction-format"
    printf 'aborted\nrolled_back\n' > "$stale_tx/phase"
    chmod 600 "$stale_tx/transaction-format" "$stale_tx/phase"
    rr_prune_stale_transactions || fail 'unsafe inactive metadata blocked later transactions'
    [ -d "$stale_tx" ] || fail 'stale pruning deleted unsafe terminal evidence'
    incomplete_tx="$RR_TX_ROOT/transactions/incomplete"
    mkdir -p "$incomplete_tx/backup"
    chmod 700 "$incomplete_tx" "$incomplete_tx/backup"
    printf '2\n' > "$incomplete_tx/transaction-format"
    chmod 600 "$incomplete_tx/transaction-format"
    rr_prune_stale_transactions || fail 'pre-phase SIGKILL orphan blocked later transactions'
    [ -d "$incomplete_tx" ] || fail 'pre-phase SIGKILL orphan was deleted as terminal'
)

printf '%s\n' '[10/11] settled format-2 retirement does not depend on rollback backup metadata'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_format_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_legacy_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_previous_transaction_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_active_transaction)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_private_value)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_committed_settled_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_republish_active_pointer_for_retry)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_clear_active_transaction_pointer)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_discard_previous_transaction)"

    RR_TX_ROOT="$TEST_ROOT/discard-settled/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    RR_LAUNCHER="$TEST_ROOT/discard-settled/rr"
    RR_RECOVERY_HELPER="$TEST_ROOT/discard-settled/recover"
    RR_COMMITTED_SETTLED_NAME=committed-settled
    RR_COMMITTED_SETTLED_VALUE=rr-update-committed-settled-v1
    RR_UPDATE_MAINTENANCE_ACTIVE=false
    tx="$RR_TX_ROOT/transactions/tx"
    operation_log="$TEST_ROOT/discard-settled/operations"
    mkdir -p "$tx"
    chmod 700 "$RR_TX_ROOT" "$tx"
    printf '2\n' > "$tx/transaction-format"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$RR_COMMITTED_SETTLED_VALUE" > "$tx/$RR_COMMITTED_SETTLED_NAME"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    chmod 600 "$tx/transaction-format" "$tx/phase" \
        "$tx/$RR_COMMITTED_SETTLED_NAME" "$RR_ACTIVE_TX"
    : > "$operation_log"
    rr_create_update_maintenance_marker() {
        printf '%s\n' maintenance >> "$operation_log"
    }
    rr_run_with_delegated_update_lock() {
        printf '%s\n' "$*" >> "$operation_log"
    }
    rr_error() { fail "$*"; }

    rr_discard_previous_transaction ||
        fail 'settled format-2 retirement required its missing rollback backup'
    [ ! -e "$RR_ACTIVE_TX" ] && [ ! -e "$tx" ] ||
        fail 'settled retirement retained its active pointer or transaction directory'
    grep -Fxq "$RR_LAUNCHER --post-update-finalize --retire-rollback" "$operation_log" ||
        fail 'settled retirement skipped rollback-window firewall retirement'
    grep -Fxq "$RR_RECOVERY_HELPER recover" "$operation_log" ||
        fail 'settled retirement skipped idempotent recovery cleanup'
    [ "$(grep -c -- '--post-update-finalize' "$operation_log")" -eq 1 ] ||
        fail 'settled retirement repeated candidate finalization'
)

printf '%s\n' '[11/11] installer retires a legacy committed window without a v2 finalizer'
(
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_legacy_update_lock_mode_is_safe)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_path_is_direct_child)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_dir_is_strict)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_transaction_format_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_legacy_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_previous_transaction_phase)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_active_transaction)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_read_trusted_private_value)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_committed_settled_state)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_republish_active_pointer_for_retry)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_clear_active_transaction_pointer)"
    # shellcheck disable=SC2294
    eval "$(function_body "$REPO_ROOT/scripts/install-core.sh" rr_discard_previous_transaction)"

    RR_TX_ROOT="$TEST_ROOT/discard-legacy-committed/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    RR_LAUNCHER="$TEST_ROOT/discard-legacy-committed/old-rr"
    RR_RECOVERY_HELPER="$TEST_ROOT/discard-legacy-committed/recover"
    RR_COMMITTED_SETTLED_NAME=committed-settled
    RR_COMMITTED_SETTLED_VALUE=rr-update-committed-settled-v1
    RR_UPDATE_MAINTENANCE_ACTIVE=false
    tx="$RR_TX_ROOT/transactions/tx"
    operation_log="$TEST_ROOT/discard-legacy-committed/operations"
    mkdir -p "$tx"
    chmod 700 "$RR_TX_ROOT" "$tx"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    chmod 600 "$tx/phase" "$RR_ACTIVE_TX"
    : > "$operation_log"
    rr_create_update_maintenance_marker() {
        fail 'legacy committed retirement created a format-2 maintenance window'
    }
    rr_run_with_delegated_update_lock() {
        printf '%s\n' "$*" >> "$operation_log"
        [ "$1" = "$RR_RECOVERY_HELPER" ] && [ "${2:-}" = recover ]
    }
    rr_error() { fail "$*"; }

    rr_discard_previous_transaction ||
        fail 'installer could not retire a recovered 7.1.0 committed window'
    [ ! -e "$RR_ACTIVE_TX" ] && [ ! -e "$tx" ] ||
        fail 'legacy committed retirement retained its pointer or transaction directory'
    [ "$(cat "$operation_log")" = "$RR_RECOVERY_HELPER recover" ] ||
        fail 'legacy committed retirement invoked the old launcher or an unexpected helper'
    ! grep -Fq -- '--post-update-finalize' "$operation_log" ||
        fail 'legacy committed retirement invoked the unsupported v2 finalizer'
)

printf '%s\n' 'install-core rollback boundary regressions: PASS'
