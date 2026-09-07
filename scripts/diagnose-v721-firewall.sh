#!/bin/bash
# Read-only checks for a rolled-back 7.0.2 host. No recovery, rule changes,
# service operations, certificate renewal, or credential/configuration output.
set -eo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 SYSTEMD_PAGER=cat
[ "${EUID:-$(id -u)}" = 0 ] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
probe() {
    local name="$1" result=0
    shift
    ( "$@" ) > "$work/probe.log" 2>&1 || result=$?
    printf 'CHECK %s rc=%s\n' "$name" "$result"
}
rr --version
/usr/local/sbin/rr-update-recover status
systemctl show sing-box.service rr-nexus.service nginx.service certbot.timer \
    argo-rr-health.timer -p Id -p ActiveState -p SubState --no-pager
identity_backup=/root/rr-before-7.2.1.B05HIb
if [ -f "$identity_backup/verify-identities.py" ]; then
    printf '%s  %s\n' d33dca31a1cfb295491561bd8e77c106a103e8211b8cdf7e6c9f1f21e91924f3 \
        "$identity_backup/verify-identities.py" | sha256sum -c -
    probe identities_preserved python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
fi
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/rr-bundle.tar.gz -o "$work/bundle.tar.gz"
printf '%s  %s\n' f00fc713dc63e43ca60da1c5f936d17263d58776445567b0dc8f3a2af7f8f9d3 \
    "$work/bundle.tar.gz" | sha256sum -c -
tar -xzf "$work/bundle.tar.gz" -C "$work"
candidate="$work/rr-bundle"
for module in 00-runtime.sh 09-systemd.sh 10-system.sh 20-config.sh 30-singbox.sh 85-nexus.sh; do
    source "$candidate/modules/$module"
done
RR_LIB_DIR="$candidate"
load_config_with_defaults >/dev/null 2>&1 || { echo CONFIG_READ_FAILED; exit 1; }
diag_mode=unknown
if rr_firewall_filter_authority_mode diag_mode > "$work/authority.log" 2>&1; then
    printf 'FIREWALL_AUTHORITY=%s\n' "$diag_mode"
else
    printf 'FIREWALL_AUTHORITY=unproved\n'
fi
probe ufw_backend rr_ufw_backend_state
probe raw_rr_namespace_empty rr_netfilter_rr_namespace_is_empty
for port in 80 443; do
    probe "tcp_${port}_complete" rr_validate_protocol_firewall "$port" tcp open
    probe "tcp_${port}_inactive_ufw_disjoint" rr_inactive_ufw_protocol_is_disjoint "$port" tcp
    for backend in iptables ip6tables; do
        probe "${backend}_readable" rr_netfilter_backend_state "$backend"
        probe "${backend}_${port}_rr_allow_present" rr_netfilter_rule_state "$backend" "$port" tcp "$FIREWALL_COMMENT" ACCEPT
        probe "${backend}_${port}_rr_block_present" rr_netfilter_rule_state "$backend" "$port" tcp "$FIREWALL_BLOCK_COMMENT" DROP
        probe "${backend}_${port}_uncontested" rr_netfilter_protocol_is_uncontested "$backend" "$port" tcp
    done
    if [ "$diag_mode" = ufw ] || [ "$diag_mode" = dual ]; then
        probe "ufw_${port}_reachable" rr_ufw_protocol_policy_is_reachable "$port" tcp open "$diag_mode"
        probe "ufw_${port}_rr_allow_present" rr_ufw_rule_state "$port" tcp ALLOW "$FIREWALL_COMMENT"
        probe "ufw_${port}_rr_block_present" rr_ufw_rule_state "$port" tcp DENY "$FIREWALL_BLOCK_COMMENT" any
    fi
done
# Check the other enabled node ports now, so a later attempt does not merely
# advance to another missing rule. These validators only read firewall state.
for spec in "VM_ENABLED:PORT:tcp" "VL_ENABLED:VL_PORT:tcp" \
    "HY2_ENABLED:HY2_PORT:udp" "TU5_ENABLED:TU5_PORT:udp" \
    "AN_ENABLED:AN_PORT:tcp"; do
    IFS=: read -r flag key proto <<< "$spec"
    # Plain VMess behind Argo stays on loopback; it needs no public allow.
    if [ "$flag" = VM_ENABLED ] && [ "$VM_TLS_ENABLED" != true ]; then continue; fi
    if [ "${!flag}" = true ]; then
        port="${!key}"
        if is_valid_port "$port"; then
            probe "configured_${proto}_${port}" rr_validate_protocol_firewall "$port" "$proto" open
        fi
    fi
done
if [ "$NAIVE_ENABLED" = true ] && is_valid_port "$NAIVE_PORT"; then
    case "$NAIVE_MODE" in
        h2|both) probe "configured_tcp_${NAIVE_PORT}" rr_validate_protocol_firewall "$NAIVE_PORT" tcp open ;;
    esac
    case "$NAIVE_MODE" in
        h3|both) probe "configured_udp_${NAIVE_PORT}" rr_validate_protocol_firewall "$NAIVE_PORT" udp open ;;
    esac
fi
probe nginx_config timeout --kill-after=2 15 nginx -t
probe prepared_nginx_layout nexus_nginx_managed_paths_are_owned
domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE")
if is_valid_domain "$domain"; then
    probe prepared_webroot_lineage rr_certbot_webroot_lineage_is_renewable "$domain"
fi
# INPUT includes wildcard and range rules; filtering only the string 443
# would hide relevant conflicts. Bound output and leave unrelated chains out.
for backend in iptables ip6tables; do
    result=0
    "$backend" -w 5 -t filter -S INPUT > "$work/input.rules" 2>&1 || result=$?
    printf 'INPUT_RULES backend=%s rc=%s\n' "$backend" "$result"
    python3 - "$work/input.rules" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text(errors='replace').splitlines()
for line in lines[:100]:
    print(line[:1000])
if len(lines) > 100:
    print('INPUT_RULES_TRUNCATED total=' + str(len(lines)))
PY
done
if command -v ufw >/dev/null 2>&1; then
    printf 'UFW_STATUS_AND_ADDED\n'
    LC_ALL=C timeout 15 ufw status verbose 2>&1 | sed -n '1,70p' || true
    LC_ALL=C timeout 15 ufw show added 2>&1 | sed -n '1,70p' || true
fi
printf 'READ_ONLY_FIREWALL_DIAGNOSTIC_COMPLETE\n'
