#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-update-firewall-finalize.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    printf 'update firewall finalize regression: FAIL: %s\n' "$*" >&2
    exit 1
}

runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' "$REPO_ROOT/modules/00-runtime.sh")
eval "$runtime_constants"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/10-system.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/55-resilience.sh"
RR_RESTORE_LOCK_FILE="$TEST_ROOT/locks/update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/legacy/rr-update.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/locks/legacy-update-bridge"

RR_FIREWALL_TX_ROOT="$TEST_ROOT/update"
RR_FIREWALL_ACTIVE_TX="$RR_FIREWALL_TX_ROOT/active"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/60-update.sh"

tx="$RR_FIREWALL_TX_ROOT/transactions/20260827T120000Z-123"
mkdir -p "$tx/backup/external-state"
chmod 700 "$RR_FIREWALL_TX_ROOT" "$RR_FIREWALL_TX_ROOT/transactions" \
    "$tx" "$tx/backup" "$tx/backup/external-state"
printf '%s\n' "$tx" > "$RR_FIREWALL_ACTIVE_TX"
chmod 600 "$RR_FIREWALL_ACTIVE_TX"
printf '%s\n' 2 > "$tx/transaction-format"
chmod 600 "$tx/transaction-format"
: > "$tx/backup/external_state_required"
chmod 600 "$tx/backup/external_state_required"

write_phase() {
    printf '%s\n' "$1" > "$tx/phase"
    chmod 600 "$tx/phase"
}

write_external_snapshot() {
    local state="$1" state_file="$tx/backup/external-state/state.json"
    local complete_file="$tx/backup/external-state/complete" digest=""
    printf '{"firewall":{"ufw":{"state":"%s"}},"version":"rr-update-external-state-v2"}\n' \
        "$state" > "$state_file"
    chmod 600 "$state_file"
    digest=$(sha256sum "$state_file" | awk '{print $1}')
    printf 'rr-update-external-state-v2 %s\n' "$digest" > "$complete_file"
    chmod 600 "$complete_file"
}

MOCK_UFW_STATE=inactive
ufw() {
    [ "${1:-}" = status ] || return 2
    printf 'Status: %s\n' "$MOCK_UFW_STATE"
}

SUB_ACCESS_MODE=local
SUB_PORT=15555
RECONCILE_CALLS=0
RECONCILE_RESULT=0
RECONCILE_TRANSACTION_STATE=""
load_config_with_defaults() {
    SUB_ACCESS_MODE=local
    SUB_PORT=15555
}
open_configured_firewall() {
    RECONCILE_CALLS=$((RECONCILE_CALLS + 1))
    RECONCILE_TRANSACTION_STATE="${RR_UPDATE_TRANSACTION:-unset}"
    return "$RECONCILE_RESULT"
}
rr_health_log() { :; }

printf '%s\n' '[1/6] migration records a durable root-only pending marker'
write_phase migrating
write_external_snapshot inactive
RR_FIREWALL_FINALIZE_REQUIRED=true
rr_record_firewall_finalize_pending || fail 'could not record pending finalization'
pending="$tx/$RR_FIREWALL_FINALIZE_PENDING_NAME"
[ "$(stat -c '%u:%g:%a:%h' "$pending")" = 0:0:600:1 ] || \
    fail 'pending evidence metadata is unsafe'
[ "$(cat "$pending")" = 'local-subscription-firewall-v1 15555' ] || \
    fail 'pending evidence content is wrong'

printf '%s\n' '[2/6] a failed committed finalizer cannot roll back or erase evidence'
write_phase committed
RECONCILE_RESULT=41
if RR_UPDATE_LOCK_HELD=1 rr_run_post_update_finalize normal; then
    fail 'failed firewall reconciliation was reported as success'
fi
[ "$(cat "$tx/phase")" = committed ] || fail 'finalizer rewrote the committed phase'
[ -f "$pending" ] || fail 'failed finalizer removed pending evidence'
[ -f "$tx/$RR_FIREWALL_FINALIZE_FAILED_NAME" ] || fail 'failed finalizer did not add failure evidence'
[ "$(cat "$RR_FIREWALL_ACTIVE_TX")" = "$tx" ] || fail 'failed finalizer cleared the active transaction'
[ "$RECONCILE_TRANSACTION_STATE" = 0 ] || fail 'post-commit reconciliation ran in transaction mode'

printf '%s\n' '[3/6] inactive UFW/netfilter finalization is retryable and converges'
RECONCILE_RESULT=0
RR_UPDATE_LOCK_HELD=1 rr_run_post_update_finalize normal || fail 'retry did not converge'
[ "$RECONCILE_CALLS" -eq 2 ] || fail 'retry did not execute exactly one new reconciliation'
[ ! -e "$pending" ] || fail 'successful finalizer retained pending evidence'
[ ! -e "$tx/$RR_FIREWALL_FINALIZE_FAILED_NAME" ] || fail 'successful finalizer retained failure evidence'
[ -f "$tx/$RR_FIREWALL_FINALIZE_COMPLETE_NAME" ] || fail 'successful finalizer lacks durable completion evidence'
[ "$(cat "$tx/phase")" = committed ] || fail 'successful finalizer rewrote committed phase'

printf '%s\n' '[4/6] active UFW is deferred throughout the manual rollback window'
rm -f "$tx/$RR_FIREWALL_FINALIZE_COMPLETE_NAME"
write_phase migrating
RR_FIREWALL_FINALIZE_REQUIRED=true
rr_record_firewall_finalize_pending || fail 'could not recreate pending marker'
write_phase committed
write_external_snapshot active
MOCK_UFW_STATE=active
before_calls=$RECONCILE_CALLS
RR_UPDATE_LOCK_HELD=1 rr_run_post_update_finalize normal || fail 'active-UFW deferral failed'
[ "$RECONCILE_CALLS" -eq "$before_calls" ] || fail 'normal finalizer mutated active UFW'
[ -f "$pending" ] || fail 'active-UFW deferral removed pending evidence'
[ -f "$tx/$RR_FIREWALL_FINALIZE_DEFERRED_NAME" ] || fail 'active-UFW deferral lacks explicit evidence'
rr_finalize_committed_firewall health || fail 'health retry did not safely defer active UFW'
[ "$RECONCILE_CALLS" -eq "$before_calls" ] || fail 'health timer mutated active UFW'
[ "$(cat "$tx/phase")" = committed ] || fail 'active-UFW deferral changed rollback phase'

printf '%s\n' '[5/6] explicit rollback-window retirement permits active-UFW convergence'
RR_UPDATE_LOCK_HELD=1 rr_run_post_update_finalize retire-rollback || \
    fail 'explicit retirement did not converge active UFW'
[ "$RECONCILE_CALLS" -eq $((before_calls + 1)) ] || \
    fail 'explicit retirement did not perform one reconciliation'
[ ! -e "$pending" ] && [ ! -e "$tx/$RR_FIREWALL_FINALIZE_DEFERRED_NAME" ] || \
    fail 'explicit retirement retained stale pending evidence'
[ -f "$tx/$RR_FIREWALL_ROLLBACK_RETIRED_NAME" ] || \
    fail 'explicit retirement lacks durable rollback-retirement evidence'
if rr_manual_update_rollback_is_safe; then
    fail 'manual rollback remained advertised after active-UFW retirement'
fi
[ "$(cat "$tx/phase")" = committed ] || fail 'explicit retirement rewrote committed phase'

printf '%s\n' '[6/6] loopback proof and transaction path validation fail closed'
SUB_PID_FILE="$TEST_ROOT/subscription.pid"
SUB_BIND_STATE_FILE="$TEST_ROOT/subscription.bind"
SUB_ROOT="$TEST_ROOT/sub-root"
RR_PROC_ROOT="$TEST_ROOT/proc"
mkdir -p "$SUB_ROOT" "$RR_PROC_ROOT/4242"
printf '%s\n' 4242 > "$SUB_PID_FILE"
printf '%s\n' '15555|127.0.0.1|local||signature|local-http' > "$SUB_BIND_STATE_FILE"
printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 15555 --bind 127.0.0.1 \
    > "$RR_PROC_ROOT/4242/cmdline"
is_subscription_pid() { [ "$1" = 4242 ]; }
rr_local_subscription_loopback_ready || fail 'valid loopback-only worker was rejected'
printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 15555 --bind 0.0.0.0 \
    > "$RR_PROC_ROOT/4242/cmdline"
if rr_local_subscription_loopback_ready; then
    fail 'publicly bound subscription worker passed loopback proof'
fi
rm -f "$RR_FIREWALL_ACTIVE_TX"
ln -s "$tx" "$RR_FIREWALL_ACTIVE_TX"
if rr_finalize_committed_firewall health >/dev/null 2>&1; then
    fail 'health path treated an unsafe active-transaction symlink as absence'
fi
grep -Fq -- '--post-update-finalize)' "$REPO_ROOT/rr" || fail 'launcher finalizer entry is missing'

printf '%s\n' 'update firewall finalize regression: PASS'
