#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
eval "$runtime_constants"
# shellcheck disable=SC1091
source modules/10-system.sh
# shellcheck disable=SC1091
source modules/30-singbox.sh
# shellcheck disable=SC1091
source modules/60-update.sh
# shellcheck disable=SC1091
source modules/70-protocols.sh
# shellcheck disable=SC1091
source modules/85-nexus.sh

pass_count=0
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$*"
}

APT_CALLS=0
CURL_CALLS=0
DPKG_CALLS=0
PIP_CALLS=0
CERTBOT_CALLS=0
SYS_ARCH=amd64
apt-get() { APT_CALLS=$((APT_CALLS + 1)); return 1; }
curl() { CURL_CALLS=$((CURL_CALLS + 1)); return 1; }
dpkg() { DPKG_CALLS=$((DPKG_CALLS + 1)); return 1; }
certbot() { CERTBOT_CALLS=$((CERTBOT_CALLS + 1)); return 1; }
cloudflared() { printf '%s\n' 'cloudflared version 2024.1.0'; }
nexus_dependencies_available() { return 1; }
nexus_install_verified_pypi_wheel() { PIP_CALLS=$((PIP_CALLS + 1)); return 1; }

RR_UPDATE_TRANSACTION=1
if install_deps >/dev/null 2>&1; then fail 'transaction install_deps unexpectedly succeeded'; fi
if install_cloudflared >/dev/null 2>&1; then fail 'transaction install_cloudflared unexpectedly succeeded'; fi
if install_singbox >/dev/null 2>&1; then fail 'transaction install_singbox unexpectedly succeeded'; fi
if nexus_install_dependencies >/dev/null 2>&1; then fail 'transaction nexus dependencies unexpectedly succeeded'; fi
if nexus_enable_public_https panel.example.invalid admin@example.invalid 443 >/dev/null 2>&1; then
    fail 'transaction Nexus certificate provisioning unexpectedly succeeded'
fi
missing_le_root=$(mktemp -d)
missing_naive_target=$(mktemp -d)
rm -rf "$missing_naive_target"
RR_LE_LIVE_ROOT="$missing_le_root"
RR_NAIVE_CERT_DIR="$missing_naive_target"
if ensure_naive_certificate naive.example.invalid admin@example.invalid >/dev/null 2>&1; then
    fail 'transaction Naive certificate provisioning unexpectedly succeeded'
fi
[ ! -e "$missing_naive_target" ] || fail 'transaction created Naive certificate state before rejecting it'
rm -rf "$missing_le_root"
[ "$APT_CALLS" -eq 0 ] && [ "$CURL_CALLS" -eq 0 ] && [ "$DPKG_CALLS" -eq 0 ] || \
    fail 'transaction dependency guards invoked apt/curl/dpkg'
[ "$PIP_CALLS" -eq 0 ] && [ "$CERTBOT_CALLS" -eq 0 ] || \
    fail 'transaction dependency guards invoked pip/certbot'
pass 'transaction dependency guards fail closed before install or download'

RR_UPDATE_TRANSACTION=0
if install_deps >/dev/null 2>&1; then fail 'mocked normal install_deps unexpectedly succeeded'; fi
[ "$APT_CALLS" -gt 0 ] || fail 'normal install_deps no longer invokes apt'
APT_CALLS=0
if install_cloudflared >/dev/null 2>&1; then fail 'mocked normal cloudflared install unexpectedly succeeded'; fi
[ "$CURL_CALLS" -gt 0 ] || fail 'normal cloudflared install no longer invokes download path'
CURL_CALLS=0
if install_singbox >/dev/null 2>&1; then fail 'mocked normal sing-box install unexpectedly succeeded'; fi
[ "$CURL_CALLS" -gt 0 ] || fail 'normal sing-box install no longer invokes download path'
APT_CALLS=0
if nexus_install_dependencies >/dev/null 2>&1; then fail 'mocked normal Nexus dependency install unexpectedly succeeded'; fi
[ "$APT_CALLS" -gt 0 ] || fail 'normal Nexus dependency install no longer invokes apt'
pass 'ordinary installation paths retain package and download behavior'

FIREWALL_MUTATIONS=0
RULE_PRESENT=true
rr_ufw_backend_state() { return 1; }
rr_netfilter_backend_state() { [ "$1" = iptables ]; }
rr_netfilter_rule_state() {
    local _backend="$1" _port="$2" _proto="$3" comment="$4" target="$5"
    [ "$RULE_PRESENT" = true ] && [ "$comment" = "$FIREWALL_COMMENT" ] && [ "$target" = ACCEPT ]
}
rr_reconcile_netfilter_protocol_rule() {
    FIREWALL_MUTATIONS=$((FIREWALL_MUTATIONS + 1))
    return 0
}
save_firewall() {
    FIREWALL_MUTATIONS=$((FIREWALL_MUTATIONS + 1))
    return 0
}

RR_UPDATE_TRANSACTION=1
open_protocol_firewall 443 tcp || fail 'transaction rejected an existing expected firewall rule'
[ "$FIREWALL_MUTATIONS" -eq 0 ] || fail 'transaction mutated/persisted an existing firewall rule'
RULE_PRESENT=false
if open_protocol_firewall 443 tcp >/dev/null 2>&1; then fail 'transaction accepted a missing firewall rule'; fi
[ "$FIREWALL_MUTATIONS" -eq 0 ] || fail 'transaction repaired a missing firewall rule'
RR_UPDATE_TRANSACTION=0
open_protocol_firewall 443 tcp || fail 'ordinary firewall reconciliation failed'
[ "$FIREWALL_MUTATIONS" -gt 0 ] || fail 'ordinary firewall reconciliation was disabled'
pass 'transaction firewall path is read-only while ordinary reconciliation remains enabled'

HOP_WRITES=0
HOP_PRESENT=true
iptables() {
    local argument=""
    for argument in "$@"; do
        case "$argument" in -A|-I|-D) HOP_WRITES=$((HOP_WRITES + 1)); return 1 ;; esac
    done
    [ "$HOP_PRESENT" = true ]
}
ENTRY_IP_MODE=ipv4
RR_UPDATE_TRANSACTION=1
rr_validate_hop_rules HY2 8443 20000:20010 || fail 'existing hop rule failed read-only validation'
[ "$HOP_WRITES" -eq 0 ] || fail 'hop validation wrote a NAT rule'
HOP_PRESENT=false
if rr_validate_hop_rules HY2 8443 20000:20010 >/dev/null 2>&1; then
    fail 'missing hop rule passed read-only validation'
fi
[ "$HOP_WRITES" -eq 0 ] || fail 'missing hop rule was repaired during transaction'
pass 'transaction hop-port validation never mutates NAT rules'

transaction_config=$(mktemp)
trap 'rm -f "$transaction_config"' EXIT
printf '%s\n' 'INSTALL_COMPLETE=true' > "$transaction_config"
CONFIG_FILE="$transaction_config"
SINGBOX_BIN=/nonexistent/rr-sing-box
INSTALL_CALLS=0
check_supported_os() { return 0; }
systemctl() { return 0; }
stop_subscription_servers() { return 0; }
migrate_config_schema() { return 0; }
load_config_with_defaults() {
    INSTALL_COMPLETE=true
    NAIVE_ENABLED=false
    return 0
}
any_node_protocol_enabled() { return 0; }
get_singbox_version() { return 1; }
install_singbox() { INSTALL_CALLS=$((INSTALL_CALLS + 1)); return 1; }

RR_UPDATE_TRANSACTION=1
if post_update_migrate >/dev/null 2>&1; then fail 'transaction with a missing core unexpectedly succeeded'; fi
[ "$INSTALL_CALLS" -eq 0 ] || fail 'post-update transaction called the core installer'
RR_UPDATE_TRANSACTION=0
if post_update_migrate >/dev/null 2>&1; then fail 'mocked ordinary migration unexpectedly succeeded'; fi
[ "$INSTALL_CALLS" -eq 1 ] || fail 'ordinary migration no longer reaches core repair'
pass 'post-update migration fails before core installation only in transaction mode'

(
    SECONDS=0
    HEALTH_PROBES=0
    HEALTH_SLEEPS=0
    systemctl() { [ "$*" = 'is-active --quiet rr-nexus' ]; }
    curl() {
        HEALTH_PROBES=$((HEALTH_PROBES + 1))
        [[ "$*" == *'http://127.0.0.1:7900/healthz'* ]]
        [ "$HEALTH_PROBES" -eq 3 ]
    }
    sleep() {
        HEALTH_SLEEPS=$((HEALTH_SLEEPS + 1))
        SECONDS=$((SECONDS + 1))
    }
    rr_wait_nexus_local_health 7900 ||
        fail 'bounded Nexus readiness rejected a delayed healthy listener'
    [ "$HEALTH_PROBES" -eq 3 ] && [ "$HEALTH_SLEEPS" -eq 2 ] ||
        fail 'bounded Nexus readiness did not retry only until success'
)
pass 'post-update Nexus readiness tolerates bounded Type=simple startup delay'

(
    SECONDS=0
    HEALTH_PROBES=0
    HEALTH_SLEEPS=0
    systemctl() { [ "$*" = 'is-active --quiet rr-nexus' ]; }
    curl() { HEALTH_PROBES=$((HEALTH_PROBES + 1)); return 1; }
    sleep() {
        HEALTH_SLEEPS=$((HEALTH_SLEEPS + 1))
        SECONDS=$((SECONDS + 10))
    }
    if rr_wait_nexus_local_health 7900; then
        fail 'bounded Nexus readiness accepted a permanently unavailable listener'
    fi
    [ "$HEALTH_PROBES" -ge 2 ] && [ "$HEALTH_PROBES" -le 4 ] &&
        [ "$HEALTH_SLEEPS" -eq "$HEALTH_PROBES" ] ||
        fail 'Nexus readiness deadline was not finite and deterministic'
)
pass 'post-update Nexus readiness remains fail-closed at its deadline'

(
    SECONDS=0
    SERVICE_CHECKS=0
    HEALTH_PROBES=0
    systemctl() {
        SERVICE_CHECKS=$((SERVICE_CHECKS + 1))
        [ "$SERVICE_CHECKS" -eq 1 ]
    }
    curl() { HEALTH_PROBES=$((HEALTH_PROBES + 1)); return 1; }
    sleep() { SECONDS=$((SECONDS + 1)); }
    if rr_wait_nexus_local_health 7900; then
        fail 'Nexus readiness accepted a service that exited during startup'
    fi
    [ "$SERVICE_CHECKS" -eq 2 ] && [ "$HEALTH_PROBES" -eq 1 ] ||
        fail 'Nexus readiness kept probing after the service exited'
)
pass 'post-update Nexus readiness rejects an exited service immediately'

(
    systemctl() { fail 'invalid Nexus port reached systemd'; }
    curl() { fail 'invalid Nexus port reached curl'; }
    if rr_wait_nexus_local_health invalid; then
        fail 'Nexus readiness accepted an invalid health port'
    fi
)

post_update_body=$(sed -n '/^post_update_migrate() {/,/^}/p' modules/60-update.sh)
wait_line=$(grep -nF 'rr_wait_nexus_local_health "$nexus_health_port"' \
    <<<"$post_update_body" | cut -d: -f1)
proxy_line=$(grep -nF 'nexus_public_proxy_health_check || return 1' \
    <<<"$post_update_body" | cut -d: -f1)
[[ "$wait_line" =~ ^[0-9]+$ && "$proxy_line" =~ ^[0-9]+$ ]] &&
    [ "$wait_line" -lt "$proxy_line" ] ||
    fail 'post-update migration no longer gates the public proxy on local Nexus readiness'
if grep -Fq 'curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:${nexus_health_port}/healthz"' \
    <<<"$post_update_body"; then
    fail 'post-update migration restored the racy one-shot Nexus health probe'
fi
pass 'post-update migration wires bounded local readiness before public proxy health'

printf 'update side-effect guard tests passed: %s\n' "$pass_count"
