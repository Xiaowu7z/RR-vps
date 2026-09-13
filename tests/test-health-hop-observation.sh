#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
baseline=${RR_HEALTH_HOP_BASELINE_ROOT:-$repo}
fixture=$(mktemp -d /tmp/rr-health-hop-observation.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077

fail() { printf 'health hop observation: FAIL: %s\n' "$*" >&2; exit 1; }

# The full official 7.2.1 health module is the input, not a reconstructed loop.
# A future release can point RR_HEALTH_HOP_BASELINE_ROOT at the verified old
# bundle. Current source contains the identical pinned module.
python3 - "$repo" "$baseline" "$fixture" <<'PY'
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys

repo, baseline, fixture = map(Path, sys.argv[1:])
helper = repo / 'scripts/patch-health-hop-observation.py'
spec = importlib.util.spec_from_file_location('patch_health_hop', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (baseline / 'modules/60-update.sh').read_bytes()
candidate = module.transform_bytes(source)
assert hashlib.sha256(candidate).hexdigest() == module.PATCHED_SHA256
assert candidate != source
assert candidate.count(module.NEW_OPERATION) == 1
assert candidate.replace(module.NEW_OPERATION, module.OLD_OPERATION, 1).replace(
    b'    local hop_label="" hop_enabled=false hop_port="" hop_specs=""\n',
    b'    local hop_label="" hop_enabled=false hop_port="" hop_specs=""\n'
    b'    local hop_repair_status=0\n', 1) == source
for unknown in (b'', source + b'\n', source.replace(b'ensure_runtime_health',
                                                    b'unknown_health', 1), candidate):
    try:
        module.transform_bytes(unknown)
    except ValueError:
        pass
    else:
        raise AssertionError('unknown/already-patched input was accepted')
result = subprocess.run([sys.executable, str(helper)], input=source,
                        capture_output=True, check=True)
assert result.stdout == candidate and not result.stderr
result = subprocess.run([sys.executable, str(helper)], input=source + b'\n',
                        capture_output=True)
assert result.returncode == 1 and not result.stdout
(fixture / 'candidate-60-update.sh').write_bytes(candidate)
print('PATCH_IDENTITY_AND_CLI_OK')
PY
bash -n "$fixture/candidate-60-update.sh"

# Execute the actual patched health function and the actual production hop
# validator/first-match parser. All unrelated health actions are fixtures.
# Backend observation is emulated; any writer/persistence/stop is a tripwire.
# shellcheck disable=SC1091
source "$baseline/modules/10-system.sh"
# shellcheck disable=SC1091
source "$baseline/modules/30-singbox.sh"
# shellcheck disable=SC1091
source "$fixture/candidate-60-update.sh"

CONFIG_FILE="$fixture/argo_vmess.conf"
NEXUS_SERVICE_FILE="$fixture/absent-nexus.service"
NEXUS_DB_FILE="$fixture/absent-nexus.db"
RR_LAUNCHER="$fixture/absent-launcher"
SUB_PID_FILE="$fixture/sub.pid"
SUB_ROOT="$fixture/subscriptions"
UUID=fixture-user
SINGBOX_BIN="$fixture/absent-singbox"
INSTALL_COMPLETE=true
SINGBOX_AUTO_RESTART=true
VM_ENABLED=false
VM_TLS_ENABLED=false
HY2_PORT=15551
TU5_PORT=24747
mkdir -p "$SUB_ROOT/$UUID"
printf 'fixture-config-preserved\n' > "$CONFIG_FILE"
printf '123\n' > "$SUB_PID_FILE"
printf 'fixture-subscription\n' > "$SUB_ROOT/$UUID/jhsub.txt"
printf '{}\n' > "$SUB_ROOT/$UUID/client.json"

rr_health_log() { printf '%s\n' "$*" >> "$fixture/health.log"; }
rr_firewall_fail_closed_quarantine_active() { return 1; }
rr_finalize_committed_firewall() { return 0; }
migrate_config_schema() { return 0; }
load_config_with_defaults() { return 0; }
rr_retry_certificate_reload_pending() { return 0; }
any_node_protocol_enabled() { return 0; }
ensure_singbox_service_guards() { return 0; }
ensure_nexus_service_guards() { return 0; }
singbox_orphan_pids() { return 0; }
managed_singbox_running() { return 0; }
get_singbox_version() { printf '1.14.0\n'; }
is_subscription_pid() { return 0; }
select_entry_ip() {
    printf 'address-observation\n' >> "$fixture/observations"
    ENTRY_IP_RAW=192.0.2.9
    # The real resolver may reload config globals. Prove those changes cannot
    # alter the enclosing health pass or skip its next configured protocol.
    HY2_PORT=9999
    TU5_ENABLED=false
    return 0
}
is_ip_version() { [ "$2" = 4 ]; }

forbidden() { printf '%s\n' "$*" >> "$fixture/writes"; return 90; }
install_hop_rules() { forbidden install_hop_rules; }
rr_firewall_batch_begin() { forbidden rr_firewall_batch_begin; }
rr_firewall_inflight_begin_locked() { forbidden rr_firewall_inflight_begin_locked; }
rr_firewall_publish_fail_closed_quarantine() { forbidden quarantine; }
save_firewall() { forbidden save_firewall; }
netfilter-persistent() { forbidden netfilter-persistent; }
stop_singbox_instances() { forbidden stop_singbox; }
restart_singbox() { forbidden restart_singbox; }
stop_subscription_servers() { forbidden stop_subscription; }
start_argo_tunnel() { forbidden start_argo; }
systemctl() {
    if [ "$#" -eq 3 ] && [ "$1" = is-active ] && \
       [ "$2" = --quiet ] && [ "$3" = sing-box ]; then
        return 0
    fi
    forbidden "systemctl $*"
}
backend() {
    local name="$1" action=""
    shift
    printf '%s %s\n' "$name" "$*" >> "$fixture/observations"
    if [ "$#" -lt 5 ] || [ "$1" != -w ] || [ "$2" != 5 ] || \
       [ "$3" != -t ] || [ "$4" != nat ]; then
        forbidden "backend $name $*"
        return 90
    fi
    action="$5"
    shift 5
    case "$action" in
        -C)
            [ "${backend_error:-}" != all ] || return 4
            grep -Fxq -- "-A $*" "$fixture/$name.nat"
            ;;
        -S)
            [ "$#" -eq 0 ] || { forbidden "backend $name unexpected-list-args"; return 90; }
            [ "${backend_error:-}" != "$name" ] || return 4
            cat "$fixture/$name.nat"
            ;;
        *) forbidden "backend $name $action $*" ;;
    esac
}
iptables() { backend iptables "$@"; }
ip6tables() { backend ip6tables "$@"; }

reset_case() {
    HEALTH_CHECK_DONE=false
    ENTRY_IP_MODE=ipv4
    HY2_ENABLED=true
    HY2_PORT=15551
    HY2_HOP_PORTS=23635:23846
    TU5_ENABLED=false
    TU5_PORT=24747
    TU5_HOP_PORTS=''
    backend_error=''
    : > "$fixture/writes"
    : > "$fixture/observations"
    : > "$fixture/health.log"
    for name in iptables ip6tables; do
        cat > "$fixture/$name.nat" <<'EOF'
-P PREROUTING ACCEPT
-P INPUT ACCEPT
-P OUTPUT ACCEPT
-P POSTROUTING ACCEPT
-A PREROUTING -p udp --dport 23635:23846 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 15551
EOF
    done
}

run_case() {
    local label="$1" expected="$2" result=0
    sha256sum "$CONFIG_FILE" "$fixture/iptables.nat" "$fixture/ip6tables.nat" \
        > "$fixture/before.sha256"
    ensure_runtime_health || result=$?
    [ "$result" -eq "$expected" ] || fail "$label returned $result (expected $expected)"
    [ ! -s "$fixture/writes" ] || fail "$label attempted $(cat "$fixture/writes")"
    sha256sum -c "$fixture/before.sha256" >/dev/null || fail "$label changed config/rules"
    if [ "$expected" -eq 0 ]; then
        [ "$HEALTH_CHECK_DONE" = true ] || fail "$label did not complete health"
        [ ! -s "$fixture/health.log" ] || fail "$label logged a failure"
    else
        [ "$HEALTH_CHECK_DONE" = false ] || fail "$label incorrectly marked healthy"
        grep -q '只读校验未通过' "$fixture/health.log" || fail "$label lacks actionable observation failure"
    fi
    printf 'HEALTH_HOP_CASE_OK %s\n' "$label"
}

reset_case
run_case healthy_tagged 0
grep -q 'iptables .* -C ' "$fixture/observations" || fail 'tuple was not observed'
grep -q 'ip6tables .* -S' "$fixture/observations" || fail 'IPv6 first-match was not observed'

reset_case
for name in iptables ip6tables; do
    sed -i 's/ -m comment --comment argo-rr-HY2//;s/-j REDIRECT --to-ports 15551/-j DNAT --to-destination :15551/' "$fixture/$name.nat"
done
run_case legacy_dnat 0

reset_case
sed -i '/^-A /d' "$fixture/ip6tables.nat"
run_case missing_ipv6_rule 1

reset_case
sed -i '/^-A /i -A PREROUTING -p udp --dport 23635:23846 -j FOREIGN' "$fixture/ip6tables.nat"
run_case shadowed_ipv6_rule 1

reset_case
for name in iptables ip6tables; do
    sed -i '/^-A /i -A PREROUTING -p tcp --dport 23635:23846 -j FOREIGN\n-A PREROUTING -p udp --dport 30000:31000 -j FOREIGN' "$fixture/$name.nat"
done
run_case disjoint_prior_rules 0

reset_case
backend_error=all
run_case backend_check_error 1

reset_case
backend_error=ip6tables
run_case backend_snapshot_error 1

reset_case
ENTRY_IP_MODE=auto
TU5_ENABLED=true
TU5_HOP_PORTS=25000:25010
for name in iptables ip6tables; do
    printf '%s\n' '-A PREROUTING -p udp --dport 25000:25010 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 24747' >> "$fixture/$name.nat"
done
run_case auto_resolver_scope_and_two_protocols 0
[ "$HY2_PORT" = 15551 ] && [ "$TU5_ENABLED" = true ] || fail 'resolver escaped observation scope'
grep -q 'argo-rr-TU5' "$fixture/observations" || fail 'auto resolver skipped next protocol'

reset_case
HY2_ENABLED=false
TU5_ENABLED=true
TU5_HOP_PORTS=''
run_case disabled_and_empty_hops 0
[ ! -s "$fixture/observations" ] || fail 'disabled/empty hops touched backend'

reset_case
(
    unset -f rr_validate_hop_rules
    run_case missing_validator 1
)

# Negative control: execute the same full pre-patch function against tripwires.
# It must attempt the old writer even when both NAT fixtures are already valid.
reset_case
(
    # shellcheck disable=SC1091
    source "$baseline/modules/60-update.sh"
    result=0
    ensure_runtime_health || result=$?
    [ "$result" -ne 0 ] || fail 'old health unexpectedly passed the writer tripwire'
    grep -Fxq install_hop_rules "$fixture/writes" || fail 'old behavior was not reproduced'
)
printf 'OLD_HEALTH_UNCONDITIONAL_WRITER_REPRODUCED\n'
printf 'HEALTH_HOP_OBSERVATION_TESTS_OK\n'
