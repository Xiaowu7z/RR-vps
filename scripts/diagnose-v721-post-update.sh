#!/bin/bash
# Inspect the released candidate's read-only prerequisites on a rolled-back host.
# Never run migration, recovery, service starts/stops, firewall edits or renewal.
set -eo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 SYSTEMD_PAGER=cat
[ "${EUID:-$(id -u)}" = 0 ] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/rr-bundle.tar.gz \
    -o "$work/bundle.tar.gz"
printf '%s  %s\n' f00fc713dc63e43ca60da1c5f936d17263d58776445567b0dc8f3a2af7f8f9d3 \
    "$work/bundle.tar.gz" | sha256sum -c -
tar -xzf "$work/bundle.tar.gz" -C "$work"
candidate="$work/rr-bundle"
source "$candidate/modules/00-runtime.sh"
RR_LIB_DIR="$candidate"
for module in 09-systemd.sh 10-system.sh 20-config.sh 30-singbox.sh 85-nexus.sh; do
    source "$candidate/modules/$module"
done
probe() {
    local name="$1" result=0
    shift
    ( "$@" ) >"$work/probe.log" 2>&1 || result=$?
    printf 'CHECK %s rc=%s\n' "$name" "$result"
    if [ "$name" = certbot_lineage ] && [ "$result" != 0 ]; then
        sed -n '/^LINEAGE_REASON /p' "$work/probe.log" | head -1
    fi
}
probe config_read load_config_with_defaults
load_config_with_defaults >/dev/null 2>&1 || exit 1
for key in VM_ENABLED VM_TLS_ENABLED VL_ENABLED HY2_ENABLED TU5_ENABLED AN_ENABLED NAIVE_ENABLED SUB_ACCESS_MODE TUNNEL_MODE; do
    value="${!key}"
    case "$value" in true|false|local|https|1|2|'') printf 'FEATURE %s=%s\n' "$key" "$value" ;; *) printf 'FEATURE %s=other\n' "$key" ;; esac
done
probe nginx_config timeout --kill-after=2 15 nginx -t
probe singbox_config timeout --kill-after=2 15 "$SINGBOX_BIN" check -c /etc/sing-box/config.json
probe nexus_dependencies nexus_dependencies_available
probe nexus_target_core nexus_core_supports_traffic
# A target-core mismatch identifies a required core upgrade, not the failed gate.
python3 - "$NEXUS_CONFIG_FILE" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print('NEXUS', json.dumps({k: v.get(k) for k in ('mode','port','public_port','certificate_mode')}))
PY
mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE")
domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE")
port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE")
if [ "$mode" = public ] && is_valid_domain "$domain"; then
    probe domain_certificate subscription_certificate_pair_valid \
        "/etc/letsencrypt/live/$domain/fullchain.pem" \
        "/etc/letsencrypt/live/$domain/privkey.pem" "$domain"
    # Reuse the exact released read-only validator, exposing only its exception
    # reason. Hide paths/long identifiers; never print account JSON or PEM data.
    python3 - "$candidate/modules/20-config.sh" "$work/lineage.py" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
body = text.split('rr_certbot_webroot_lineage_is_renewable() {',1)[1]
body = body.split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
prefix = '''import re, sys
def report(kind, value, trace):
    message = re.sub(r'/[^\\s:;]+', '<path>', str(value))
    message = re.sub(r'[A-Za-z0-9_-]{32,}', '<identifier>', message)
    print('LINEAGE_REASON ' + kind.__name__ + ': ' + message[:220], file=sys.stderr)
sys.excepthook = report
'''
Path(sys.argv[2]).write_text(prefix + body)
PY
    probe certbot_lineage timeout --kill-after=2 20 python3 "$work/lineage.py" \
        "$domain" /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive \
        /etc/letsencrypt/renewal /etc/letsencrypt/accounts /var/www/rr-nexus-certbot
    if is_valid_port "$port"; then
        probe public_proxy_health curl -fsS --connect-timeout 2 --max-time 8 \
            --resolve "$domain:$port:127.0.0.1" "https://$domain:$port/healthz"
    fi
    systemctl show certbot.timer certbot.service -p Id -p LoadState -p ActiveState -p UnitFileState --no-pager
fi
printf 'READ_ONLY_POST_UPDATE_DIAGNOSTIC_COMPLETE\n'
