#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/rr-update-loopback.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077
fail() { printf 'update loopback migration: FAIL: %s\n' "$*" >&2; exit 1; }
source "$repo/modules/10-system.sh"
source "$repo/modules/60-update.sh"
RR_FIREWALL_LOCK_FILE="$fixture/locks/firewall.lock"
RR_FIREWALL_TX_ROOT="$fixture/update"
RR_FIREWALL_ACTIVE_TX="$RR_FIREWALL_TX_ROOT/active"
tx="$RR_FIREWALL_TX_ROOT/transactions/20260913T120000Z-1"
mkdir -p "$tx/backup/external-state/items" "$fixture/locks"
printf '%s\n' "$tx" > "$RR_FIREWALL_ACTIVE_TX"
printf '2\n' > "$tx/transaction-format"
printf 'migrating\n' > "$tx/phase"
: > "$tx/backup/external_state_required"
write_snapshot() {
    python3 - "$repo/scripts/update-external-state.py" "$tx" "$1" "${2:-current}" <<'PY'
import hashlib, importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('external', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tx = pathlib.Path(sys.argv[2]); current = sys.argv[4] == 'current'
state = {'version':m.VERSION,
         'paths':[{'path':p, 'kind':'missing'} for p in
                  (m.MANAGED_PATHS if current else m.LEGACY_MANAGED_PATHS)],
         'services':{n:{'enabled':False, 'active':False} for n in m.SERVICES},
         'firewall':{'ufw':{'state':sys.argv[3]}}}
if current:
    state['firewall_guard'] = {n:{'enabled':False, 'active':False} for n in m.FIREWALL_GUARD_UNITS}
raw = json.dumps(state).encode()
root = tx / 'backup/external-state'
(root/'state.json').write_bytes(raw)
(root/'complete').write_text(m.VERSION+' '+hashlib.sha256(raw).hexdigest()+'\n')
PY
}
fixture_ufw=inactive
rr_current_ufw_state() { printf '%s\n' "$fixture_ufw"; }
RR_UPDATE_TRANSACTION=1
write_snapshot inactive
if rr_update_loopback_migration_is_protected; then fail 'missing firewall lock was accepted'; fi
rr_firewall_lock_acquire || fail 'could not acquire real private firewall lock'
rr_update_loopback_migration_is_protected || fail 'sealed migrating transaction was rejected'
printf 'committed\n' > "$tx/phase"
if rr_update_loopback_migration_is_protected; then fail 'committed transaction allowed candidate writes'; fi
printf 'migrating\n' > "$tx/phase"
write_snapshot inactive legacy
if rr_update_loopback_migration_is_protected; then fail 'old snapshot without guard rollback files accepted'; fi
write_snapshot inactive
printf ' ' >> "$tx/backup/external-state/state.json"
if rr_update_loopback_migration_is_protected 2>/dev/null; then fail 'tampered snapshot accepted'; fi
write_snapshot active
fixture_ufw=active
if rr_update_loopback_migration_is_protected; then fail 'active UFW allowed candidate raw writes'; fi
write_snapshot inactive
if rr_update_loopback_migration_is_protected; then fail 'changed UFW state accepted'; fi
fixture_ufw=inactive
RR_UPDATE_TRANSACTION=0
if rr_update_loopback_migration_is_protected; then fail 'ordinary call got candidate write privilege'; fi
RR_UPDATE_TRANSACTION=1
rr_firewall_lock_release
printf 'SEALED_UPDATE_LOOPBACK_BOUNDARY_OK\n'

# Exercise the real post-update function and locks, stopping at the existing
# missing-core rejection. No service is launched. Guard migration and the
# loopback repair must occur before any candidate listener can be generated.
CONFIG_FILE="$fixture/config"
printf 'fixture\n' > "$CONFIG_FILE"
SINGBOX_BIN="$fixture/missing-core"
SUB_PORT=20382
SUB_ACCESS_MODE=local
NAIVE_ENABLED=false
INSTALL_COMPLETE=true
check_supported_os() { :; }
systemctl() { :; }
sleep() { :; }
stop_subscription_servers() { :; }
migrate_config_schema() { :; }
load_config_with_defaults() { :; }
is_valid_port() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && [ "$1" -le 65535 ]; }
any_node_protocol_enabled() { return 0; }
rr_firewall_install_fail_closed_supervisor() {
    rr_firewall_lock_is_held || return 1
    printf 'guard\n' >> "$fixture/order"
}
rr_reconcile_local_subscription_loopback() {
    rr_update_loopback_migration_is_protected || return 1
    RR_FIREWALL_FINALIZE_REQUIRED=true
    printf 'loopback\n' >> "$fixture/order"
}
get_singbox_version() { printf 'core\n' >> "$fixture/order"; return 1; }
install_singbox() { fail 'candidate unexpectedly installed a core'; }
if post_update_migrate >/dev/null 2>&1; then fail 'missing-core candidate unexpectedly succeeded'; fi
[ "$(cat "$fixture/order")" = "$(printf 'guard\nloopback\ncore')" ] || fail 'candidate migration order differs'
[ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ] || fail 'loopback persistence finalization was lost'
if rr_firewall_lock_is_held; then fail 'migration leaked firewall lock'; fi
printf 'CANDIDATE_GUARD_AND_LOOPBACK_BEFORE_RUNTIME_OK\n'

: > "$fixture/order"
INSTALL_COMPLETE=false
any_node_protocol_enabled() { return 1; }
post_update_migrate || fail 'failed first-install host cannot update its script'
[ ! -s "$fixture/order" ] || fail 'incomplete first install touched firewall or runtime'
printf 'INCOMPLETE_FIRST_INSTALL_REMAINS_UPDATABLE_OK\n'
