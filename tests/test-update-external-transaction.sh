#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-update-external-tx.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'update external transaction regression: FAIL: %s\n' "$*" >&2
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

line_in_function() {
    local source_file="$1" function_name="$2" pattern="$3"
    function_body "$source_file" "$function_name" | grep -n -- "$pattern" | head -n 1 | cut -d: -f1
}

printf '%s\n' '[1/5] durable helper installation and snapshot ordering precede candidate switching'
prepare_external=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_prepare_recovery_runtime 'mv -f "$external_tmp"')
prepare_recovery=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_prepare_recovery_runtime 'mv -f "$recovery_tmp"')
snapshot_external=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_snapshot_runtime 'rr_snapshot_external_state')
snapshot_prepared=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_snapshot_runtime 'rr_write_phase prepared')
install_snapshot=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_install_release 'rr_snapshot_runtime')
install_switch=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_install_release 'TRANSACTION_ACTIVE=true')
for value in "$prepare_external" "$prepare_recovery" "$snapshot_external" \
    "$snapshot_prepared" "$install_snapshot" "$install_switch"; do
    [[ "$value" =~ ^[0-9]+$ ]] || fail 'ordering evidence is incomplete'
done
[ "$prepare_external" -lt "$prepare_recovery" ] || \
    fail 'new recovery helper can become visible before its external-state dependency'
[ "$snapshot_external" -lt "$snapshot_prepared" ] || \
    fail 'transaction can become prepared without an external-state snapshot'
[ "$install_snapshot" -lt "$install_switch" ] || \
    fail 'candidate switching can start before all snapshots complete'

make_external_helper() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    apply_fixture="$target"
    # The fixture is created from a fixed printf, not user-controlled data.
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "external:%s\\n" "$1" >> "${MOCK_OPERATION_LOG:?}"' \
        '[ "${MOCK_EXTERNAL_FAIL:-}" != "$1" ]' > "$apply_fixture"
    chmod 755 "$apply_fixture"
}

run_restore_case() (
    local name="$1" format="$2" fail_operation="${3:-}"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$TEST_ROOT/$name/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_LIB_DIR="$TEST_ROOT/$name/runtime"
    export RR_LAUNCHER="$TEST_ROOT/$name/rr"
    export RR_CONFIG_FILE="$TEST_ROOT/$name/config"
    export RR_QUARANTINE_FILE="$RR_TX_ROOT/quarantine"
    export RR_QUARANTINE_UNIT="$TEST_ROOT/$name/quarantine.service"
    export RR_QUARANTINE_READY="$TEST_ROOT/$name/quarantine.ready"
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/$name/run/update-maintenance"
    export RR_UPDATE_EXTERNAL_HELPER="$TEST_ROOT/$name/bin/rr-update-external-state"
    export MOCK_OPERATION_LOG="$TEST_ROOT/$name/operations"
    export MOCK_EXTERNAL_FAIL="$fail_operation"
    mkdir -p "$RR_TX_ROOT/transactions" "$RR_LIB_DIR" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    : > "$MOCK_OPERATION_LOG"
    make_external_helper "$RR_UPDATE_EXTERNAL_HELPER"

    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx/backup"
    chmod 700 "$RR_TX_ROOT" "$RR_TX_ROOT/transactions" "$tx" "$tx/backup"
    printf 'runtime_swapped\n' > "$tx/phase"
    chmod 600 "$tx/phase"
    if [ "$format" = 2 ]; then
        printf '2\n' > "$tx/transaction-format"
        : > "$tx/backup/external_state_required"
        chmod 600 "$tx/transaction-format" "$tx/backup/external_state_required"
    fi

    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$MOCK_OPERATION_LOG"
        case "$*" in
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'loaded\n' ;;
            'show -p ActiveState --value argo-rr-health.timer'|\
            'show -p ActiveState --value argo-rr-health.service') printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer') printf 'disabled\n' ;;
            'show -p UnitFileState --value argo-rr-health.service') printf 'static\n' ;;
            'show -p LoadState --value '*) printf 'loaded\n' ;;
            'show -p ActiveState --value '*) printf 'inactive\n' ;;
            'show -p UnitFileState --value '*) printf 'disabled\n' ;;
        esac
        return 0
    }
    rr_stop_subscription_servers() {
        printf '%s\n' stop-subscription >> "$MOCK_OPERATION_LOG"
        return 0
    }
    rr_restore_file() { printf 'internal-file:%s\n' "$1" >> "$MOCK_OPERATION_LOG"; }
    rr_restore_dir() { printf 'internal-dir:%s\n' "$1" >> "$MOCK_OPERATION_LOG"; }
    rr_restore_database() { printf '%s\n' internal-db >> "$MOCK_OPERATION_LOG"; }
    rr_verify_restored_state() { printf '%s\n' internal-verify >> "$MOCK_OPERATION_LOG"; }
    rr_apply_rollback_subscription_policy() {
        printf '%s\n' subscription-policy >> "$MOCK_OPERATION_LOG"
        printf 'normal\n' > "$tx/rollback-subscription-status"
    }
    rr_restore_recorded_writer_state() {
        printf '%s\n' writer-restore >> "$MOCK_OPERATION_LOG"
    }
    rr_clear_update_maintenance_marker() { return 0; }

    set +e
    rr_restore_transaction "$tx" test
    rc=$?
    set -e
    if [ "$format" = 2 ] && [ -n "$fail_operation" ]; then
        [ "$rc" -eq 1 ] || fail 'external-state failure was reported as rollback success'
        [ "$(cat "$tx/phase")" = recovery_failed ] || \
            fail 'external-state failure did not retain recovery_failed evidence'
        ! grep -Fxq writer-restore "$MOCK_OPERATION_LOG" || \
            fail 'writers restarted after external-state restore failed'
        ! grep -Fxq subscription-policy "$MOCK_OPERATION_LOG" || \
            fail 'rollback policy mutated the firewall after external restore failed'
        return 0
    fi
    [ "$rc" -eq 0 ] || fail 'valid rollback transaction failed'
    [ "$(cat "$tx/phase")" = rolled_back ] || fail 'successful rollback phase is incorrect'
)

printf '%s\n' '[2/5] format-2 rollback requires restore+verify before any writer restart'
run_restore_case format2-success 2
format2_log="$TEST_ROOT/format2-success/operations"
restore_line=$(grep -n '^external:restore$' "$format2_log" | cut -d: -f1)
verify_line=$(grep -n '^external:verify$' "$format2_log" | cut -d: -f1)
writer_line=$(grep -n '^writer-restore$' "$format2_log" | cut -d: -f1)
[[ "$restore_line" =~ ^[0-9]+$ && "$verify_line" =~ ^[0-9]+$ && \
   "$writer_line" =~ ^[0-9]+$ ]] || fail 'format-2 restore evidence is incomplete'
[ "$restore_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$writer_line" ] || \
    fail 'writers can restart before external restore and explicit verification finish'

printf '%s\n' '[3/5] external restore failure freezes writers and retains recovery evidence'
run_restore_case format2-failure 2 restore

printf '%s\n' '[4/5] legacy transaction remains recoverable without silently weakening format 2'
run_restore_case legacy-success legacy restore
legacy_log="$TEST_ROOT/legacy-success/operations"
! grep -q '^external:' "$legacy_log" || fail 'legacy recovery unexpectedly required a new helper'

printf '%s\n' '[5/5] committed finalization restores writers before settling and cannot roll back'
commit_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'rr_write_phase committed')
keep_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'KEEP_TRANSACTION=true')
quarantine_clear_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'clear-quarantine')
finalize_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    '--post-update-finalize')
writer_reconcile_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_install_release 'rr_reconcile_committed_writer_state')
subscription_restore_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_reconcile_committed_writer_state 'rr_restore_committed_subscription_state')
writer_verify_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" \
    rr_reconcile_committed_writer_state 'rr_verify_update_writer_state')
settle_sync_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'if ! sync')
settled_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'rr_publish_committed_settled')
clear_line=$(line_in_function "$REPO_ROOT/scripts/install-core.sh" rr_install_release \
    'rr_clear_update_maintenance_marker')
for value in "$commit_line" "$keep_line" "$quarantine_clear_line" "$finalize_line" \
    "$writer_reconcile_line" "$subscription_restore_line" "$writer_verify_line" "$settle_sync_line" \
    "$settled_line" "$clear_line"; do
    [[ "$value" =~ ^[0-9]+$ ]] || fail 'post-commit finalizer ordering evidence is incomplete'
done
[ "$commit_line" -lt "$keep_line" ] && [ "$keep_line" -lt "$quarantine_clear_line" ] && \
    [ "$quarantine_clear_line" -lt "$finalize_line" ] && \
    [ "$finalize_line" -lt "$writer_reconcile_line" ] && \
    [ "$writer_reconcile_line" -lt "$settle_sync_line" ] && \
    [ "$subscription_restore_line" -lt "$writer_verify_line" ] && \
    [ "$settle_sync_line" -lt "$settled_line" ] && \
    [ "$settled_line" -lt "$clear_line" ] || \
    fail 'finalizer is not protected by durable committed/KEEP state and maintenance'
install_release_body=$(sed -n '/^rr_install_release() {/,/^}/p' \
    "$REPO_ROOT/scripts/install-core.sh")
post_commit_cleanup=${install_release_body#*KEEP_TRANSACTION=true}
if grep -Fq 'rr_rollback' <<<"$post_commit_cleanup"; then
    fail 'post-commit cleanup can still roll a committed safe candidate back'
fi

printf '%s\n' 'update external transaction regression: PASS'
