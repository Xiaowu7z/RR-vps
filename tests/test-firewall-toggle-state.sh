#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# Only query/status code is exercised here. All external backends and the two
# transaction entrypoints are fixtures; no firewall/service writes hit the host.
export RR_FIREWALL_QUARANTINE_DIR="$TEST_ROOT/quarantine"
export RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/marker"
mkdir -p "$RR_FIREWALL_QUARANTINE_DIR"
FIREWALL_COMMENT=argo-rr-managed
FIREWALL_BLOCK_COMMENT=argo-rr-managed-block
# shellcheck source=../modules/10-system.sh
source modules/10-system.sh
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
is_valid_port() { [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
SSH_PORT=22
SSH_CONNECTION=
PORT_UNDER_TEST=24443
PROTO_UNDER_TEST=tcp
nexus_fw_known_ports() { printf '%s:%s:test-node\n' "$PORT_UNDER_TEST" "$PROTO_UNDER_TEST"; }
ss() { printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:* users:(("sing-box",pid=1,fd=3))\n' "$PORT_UNDER_TEST"; }
systemctl() { return 0; }
sshd() { return 0; }
netfilter_fixture() {
    local backend="$1" action="" chain="" port="" proto="" comment="" target=""
    shift
    [ ! -e "$TEST_ROOT/$backend.error" ] || return 4
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -w|-t|-m) shift 2 ;;
            -S|-C) action="$1"; shift; chain="${1:-}"; [ "$#" -eq 0 ] || shift ;;
            -p) proto="$2"; shift 2 ;;
            --dport) port="$2"; shift 2 ;;
            --comment) comment="$2"; shift 2 ;;
            -j) target="$2"; shift 2 ;;
            *) return 4 ;;
        esac
    done
    case "$action" in
        -S)
            if [ "$chain" = ufw6-user-input ]; then
                [ "$UFW_ACTIVE" = 1 ] && [ "$UFW_IPV6" = 1 ]
            else
                printf '%s\n' '-P INPUT ACCEPT'
                cat "$TEST_ROOT/$backend.rules"
            fi
            ;;
        -C)
            grep -Fqx -- "-A INPUT -p $proto --dport $port -m comment --comment $comment -j $target" "$TEST_ROOT/$backend.rules"
            ;;
        *) return 4 ;;
    esac
}
iptables() { netfilter_fixture iptables "$@"; }
ip6tables() { netfilter_fixture ip6tables "$@"; }
ufw() {
    [ ! -e "$TEST_ROOT/ufw.error" ] || return 4
    [ "${1:-}" = status ] || return 4
    if [ "$UFW_ACTIVE" = 0 ]; then
        printf '%s\n' 'Status: inactive'
        return 0
    fi
    printf '%s\n' 'Status: active'
    awk -F '|' '{ printf "%s/%s%s %s Anywhere # %s\n", $2, $3, $4 == 6 ? " (v6)" : "", $1, $5 }' "$TEST_ROOT/ufw.rules"
}
reset_fixture() {
    rm -f "$TEST_ROOT/iptables.error" "$TEST_ROOT/ip6tables.error" "$TEST_ROOT/ufw.error" "$RR_FIREWALL_QUARANTINE_FILE"
    : > "$TEST_ROOT/iptables.rules"
    : > "$TEST_ROOT/ip6tables.rules"
    : > "$TEST_ROOT/ufw.rules"
    : > "$TEST_ROOT/writes"
    UFW_ACTIVE=0
    UFW_IPV6=1
    FIREWALL_MODE=netfilter
    PORT_UNDER_TEST=24443
    PROTO_UNDER_TEST=tcp
}
raw_rule() {
    local backend="$1" desired="$2" marker="$FIREWALL_COMMENT" target=ACCEPT
    if [ "$desired" = closed ]; then marker="$FIREWALL_BLOCK_COMMENT"; target=DROP; fi
    printf '%s\n' "-A INPUT -p $PROTO_UNDER_TEST --dport $PORT_UNDER_TEST -m comment --comment $marker -j $target" >> "$TEST_ROOT/$backend.rules"
}
ufw_rule() {
    local family="$1" desired="$2" marker="$FIREWALL_COMMENT" action=ALLOW
    if [ "$desired" = closed ]; then marker="$FIREWALL_BLOCK_COMMENT"; action=DENY; fi
    printf '%s|%s|%s|%s|%s\n' "$action" "$PORT_UNDER_TEST" "$PROTO_UNDER_TEST" "$family" "$marker" >> "$TEST_ROOT/ufw.rules"
}
set_managed_state() {
    : > "$TEST_ROOT/iptables.rules"
    : > "$TEST_ROOT/ip6tables.rules"
    : > "$TEST_ROOT/ufw.rules"
    if [ "$FIREWALL_MODE" != ufw ]; then
        raw_rule iptables "$1"; raw_rule ip6tables "$1"
    fi
    if [ "$FIREWALL_MODE" != netfilter ]; then
        ufw_rule 4 "$1"; [ "$UFW_IPV6" = 0 ] || ufw_rule 6 "$1"
    fi
}
# The real transaction implementation has its own fault-injection suite. These
# writers record that toggle delegates correctly and change only fixture data.
open_protocol_firewall() { printf 'open %s %s\n' "$1" "$2" >> "$TEST_ROOT/writes"; set_managed_state open; }
close_protocol_firewall() { printf 'closed %s %s\n' "$1" "$2" >> "$TEST_ROOT/writes"; set_managed_state closed; }
expect_state() {
    local actual=0
    if nexus_fw_port_open "$PORT_UNDER_TEST" "$PROTO_UNDER_TEST"; then actual=0; else actual=$?; fi
    [ "$actual" = "$1" ] || fail "expected state $1, got $actual ($FIREWALL_MODE/$PROTO_UNDER_TEST)"
}
expect_json() {
    local value=""
    value=$(nexus_fw_ports_json)
    python3 -c 'import json,sys; p=json.loads(sys.argv[1])[0]; assert p["managed_state"] == sys.argv[2]; assert p["open"] == json.loads(sys.argv[3])' "$value" "$1" "$2"
}

printf '%s\n' '[1/8] TCP/UDP double toggle with a listener that remains active'
for mode in netfilter ufw dual; do
    for proto in tcp udp; do
        reset_fixture
        FIREWALL_MODE="$mode"; PROTO_UNDER_TEST="$proto"
        [ "$mode" = netfilter ] || UFW_ACTIVE=1
        set_managed_state open
        expect_state 0; expect_json open 1
        result=$(nexus_fw_toggle "$PORT_UNDER_TEST" "$proto")
        [[ "$result" == *'"action":"closed"'* ]] || fail 'first toggle did not close'
        expect_state 1; expect_json closed 0
        result=$(nexus_fw_toggle "$PORT_UNDER_TEST" "$proto")
        [[ "$result" == *'"action":"opened"'* ]] || fail 'second toggle did not reopen'
        expect_state 0; expect_json open 1
        [ "$(cat "$TEST_ROOT/writes")" = "$(printf 'closed %s %s\nopen %s %s' "$PORT_UNDER_TEST" "$proto" "$PORT_UNDER_TEST" "$proto")" ] || fail 'wrong writer order'
    done
done

printf '%s\n' '[2/8] listener/unowned rule is unmanaged; missing rules still allow initial setup'
reset_fixture
expect_state 3; expect_json unmanaged null
printf '%s\n' '-A INPUT -p tcp --dport 24443 -m comment --comment user-owned -j ACCEPT' > "$TEST_ROOT/iptables.rules"
expect_state 3
result=$(nexus_fw_toggle "$PORT_UNDER_TEST" tcp)
[[ "$result" == *'"action":"opened"'* ]] || fail 'unmanaged port could not enter the existing open transaction'

printf '%s\n' '[3/8] conflicting and partial IPv4/IPv6 rules are not guessed'
for mode in netfilter ufw dual; do
    reset_fixture; FIREWALL_MODE="$mode"; [ "$mode" = netfilter ] || UFW_ACTIVE=1
    set_managed_state open
    if [ "$mode" = ufw ]; then ufw_rule 6 closed; else raw_rule ip6tables closed; fi
    expect_state 2; expect_json indeterminate null
    if nexus_fw_toggle "$PORT_UNDER_TEST" tcp > "$TEST_ROOT/result"; then fail 'conflicting state was toggled'; fi
    [ "$(cat "$TEST_ROOT/result")" = '{"ok":false,"error":"firewall_state_unavailable"}' ] || fail 'unknown state did not return explicit error'
    [ ! -s "$TEST_ROOT/writes" ] || fail 'unknown state mutated firewall'
    set_managed_state open
    if [ "$mode" = ufw ]; then sed -i '/|6|/d' "$TEST_ROOT/ufw.rules"; else : > "$TEST_ROOT/ip6tables.rules"; fi
    expect_state 2
    set_managed_state open
    if [ "$mode" = ufw ]; then
        sed -i '/|6|/d' "$TEST_ROOT/ufw.rules"; ufw_rule 6 closed
    else
        : > "$TEST_ROOT/ip6tables.rules"; raw_rule ip6tables closed
    fi
    expect_state 2
done

printf '%s\n' '[4/8] backend query failures stay unknown and do not write'
for backend in iptables ip6tables ufw; do
    reset_fixture; set_managed_state open
    : > "$TEST_ROOT/$backend.error"
    expect_state 2
    if nexus_fw_toggle "$PORT_UNDER_TEST" tcp >/dev/null; then fail 'unreadable backend was toggled'; fi
    [ ! -s "$TEST_ROOT/writes" ] || fail 'unreadable backend caused mutation'
done
reset_fixture; FIREWALL_MODE=ufw; UFW_ACTIVE=1; UFW_IPV6=0
set_managed_state open; expect_state 0
set_managed_state closed; expect_state 1

printf '%s\n' '[5/8] quarantine and invalid/SSH requests retain their pre-write gates'
reset_fixture; set_managed_state open
: > "$RR_FIREWALL_QUARANTINE_FILE"
if nexus_fw_toggle "$PORT_UNDER_TEST" tcp > "$TEST_ROOT/result"; then fail 'quarantine gate bypassed'; fi
[[ "$(cat "$TEST_ROOT/result")" == *'"error":"firewall_quarantine_active"'* ]] || fail 'quarantine error changed'
rm -f "$RR_FIREWALL_QUARANTINE_FILE"
for request in '22 tcp' '0 tcp' '24443 sctp' '24444 tcp'; do
    read -r requested_port requested_proto <<< "$request"
    if nexus_fw_toggle "$requested_port" "$requested_proto" >/dev/null; then fail "invalid request succeeded: $request"; fi
done
[ ! -s "$TEST_ROOT/writes" ] || fail 'pre-write gate issued transaction'

printf '%s\n' '[6/8] SSH protection merges real listeners, socket activation and configuration'
(
    unset SSH_PORT
    SSH_CONNECTION='198.51.100.2 51000 203.0.113.4 47219'
    ss() {
        printf '%s\n' \
            'LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=7,fd=3))' \
            'LISTEN 0 4096 [::]:2223 [::]:* users:(("systemd",pid=1,fd=3),("sshd-session",pid=8,fd=3))' \
            'LISTEN 0 4096 0.0.0.0:12345 0.0.0.0:* users:(("not-sshd",pid=9,fd=3))'
    }
    systemctl() { printf '%s\n' '[::]:2224 (Stream) 0.0.0.0:2225 (Stream)'; }
    sshd() { printf '%s\n' 'port 2226' 'port 2222' 'port 0' 'port 65536'; }
    [ "$(rr_ssh_protected_ports)" = "$(printf '%s\n' 2222 2223 2224 2225 2226 47219)" ] || fail 'SSH evidence was missed or unrelated listener was protected'
    for protected in 2222 2223 2224 2225 2226 47219; do
        rr_port_is_ssh_protected "$protected" || fail "SSH port $protected was not recognized"
        if nexus_fw_toggle "$protected" tcp > "$TEST_ROOT/result"; then fail "actual SSH port $protected was toggled"; fi
        [[ "$(cat "$TEST_ROOT/result")" == *'"error":"ssh_port_protected"'* ]] || fail 'SSH rejection changed'
    done
    if rr_port_is_ssh_protected 12345; then fail 'non-SSH listener misidentified'; fi
)
(
    unset SSH_PORT SSH_CONNECTION
    ss() { return 1; }; systemctl() { return 1; }; sshd() { return 1; }
    [ "$(rr_ssh_protected_ports)" = 22 ] || fail 'missing SSH evidence lost compatibility fallback'
    SSH_CONNECTION='198.51.100.2 51000 203.0.113.4 47219 unexpected'
    [ "$(rr_ssh_protected_ports)" = 22 ] || fail 'malformed SSH connection evidence accepted'
)

printf '%s\n' '[7/8] exact rule lookup errors and dual authority disagreement remain unknown'
reset_fixture; FIREWALL_MODE=dual; UFW_ACTIVE=1; set_managed_state open
: > "$TEST_ROOT/ufw.rules"; ufw_rule 4 closed; ufw_rule 6 closed
expect_state 2
(
    reset_fixture; set_managed_state open
    real_netfilter_fixture=$(declare -f netfilter_fixture)
    eval "${real_netfilter_fixture/netfilter_fixture ()/readable_netfilter_fixture ()}"
    netfilter_fixture() { if [[ " $* " == *' -C '* ]]; then return 4; fi; readable_netfilter_fixture "$@"; }
    expect_state 2
)

printf '%s\n' '[8/8] rendering preserves legacy states and labels unknown/unmanaged precisely'
node - nexus/static/app.js <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('function renderFirewallPorts(ports) {');
const end = source.indexOf('\nasync function loadFirewall()', start);
const list = { innerHTML: '' };
const context = { $: () => list, $$: () => [], escapeHtml: String };
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
for (const [port, label, disabled] of [
  [{open: 1}, '放行中', false], [{open: 0}, '已关闭', false],
  [{open: null, managed_state: 'unmanaged'}, '未设置', false],
  [{open: null, managed_state: 'indeterminate'}, '状态未知', true],
  [{open: null, managed_state: 'future-unknown'}, '状态未知', true],
  [{open: 1, name: 'SSH 管理端口（保护）'}, '🔒 保护', true],
]) {
  context.renderFirewallPorts([{name: 'node', port: 24443, proto: 'tcp', ...port}]);
  assert.ok(list.innerHTML.includes(label), list.innerHTML);
  assert.equal(/<button[^>]*\sdisabled/.test(list.innerHTML), disabled);
}
console.log('Firewall rendering compatibility passed.');
JS
printf '%s\n' 'Firewall toggle state and SSH protection regressions passed.'
