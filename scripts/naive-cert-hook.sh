#!/bin/bash
# Certbot deploy hook for RR-vps managed NaiveProxy and subscription TLS.
set -u

CONFIG_FILE="${RR_CERT_HOOK_CONFIG_FILE:-/etc/argo_vmess.conf}"
NAIVE_TARGET_DIR="${RR_CERT_HOOK_NAIVE_TARGET_DIR:-/etc/rr-naive}"
LE_LIVE_ROOT="${RR_CERT_HOOK_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
RR_CLI="${RR_CERT_HOOK_CLI:-/usr/local/bin/rr}"
SYSTEMCTL_BIN="${RR_CERT_HOOK_SYSTEMCTL:-systemctl}"
NAIVE_DOMAIN=""
SUB_ACCESS_MODE="local"
SUB_DOMAIN=""

[ -r "$CONFIG_FILE" ] || exit 0
[ -n "${RENEWED_LINEAGE:-}" ] || exit 0

parsed_config=$(mktemp /tmp/rr-cert-hook.XXXXXX) || exit 1
trap 'rm -f "$parsed_config"' EXIT HUP INT TERM
if ! python3 - "$CONFIG_FILE" > "$parsed_config" <<'PY'
import re
import sys

allowed = {"NAIVE_DOMAIN", "SUB_ACCESS_MODE", "SUB_DOMAIN"}
values: dict[str, list[str]] = {key: [] for key in allowed}
with open(sys.argv[1], "r", encoding="utf-8") as config:
    for raw in config:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key not in allowed:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key].append(value)

if any(len(items) > 1 for items in values.values()):
    raise SystemExit("duplicate RR certificate setting")

domain_re = re.compile(
    r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}"
)
naive_domain = values["NAIVE_DOMAIN"][0] if values["NAIVE_DOMAIN"] else ""
sub_mode = values["SUB_ACCESS_MODE"][0] if values["SUB_ACCESS_MODE"] else "local"
sub_domain = values["SUB_DOMAIN"][0] if values["SUB_DOMAIN"] else ""
if naive_domain and not domain_re.fullmatch(naive_domain):
    raise SystemExit("invalid NAIVE_DOMAIN")
if sub_mode not in {"local", "https"}:
    raise SystemExit("invalid SUB_ACCESS_MODE")
if sub_mode == "https":
    if not domain_re.fullmatch(sub_domain):
        raise SystemExit("invalid SUB_DOMAIN")
else:
    sub_domain = ""
print(naive_domain)
print(sub_mode)
print(sub_domain)
PY
then
    exit 1
fi
mapfile -t parsed_values < "$parsed_config"
[ "${#parsed_values[@]}" -eq 3 ] || exit 1
NAIVE_DOMAIN="${parsed_values[0]}"
SUB_ACCESS_MODE="${parsed_values[1]}"
SUB_DOMAIN="${parsed_values[2]}"

certificate_pair_valid() {
    local certificate="$1" private_key="$2" domain="$3" cert_public="" key_public=""
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    python3 - "$certificate" "$domain" >/dev/null 2>&1 <<'PY' || return 1
import ssl
import sys
import ipaddress

decoded = ssl._ssl._test_decode_cert(sys.argv[1])
identity = sys.argv[2].strip()
try:
    expected_ip = ipaddress.ip_address(identity.strip("[]"))
except ValueError:
    expected_ip = None
matched = False
for kind, value in decoded.get("subjectAltName", ()):
    if expected_ip is None and kind == "DNS" and value.lower() == identity.lower():
        matched = True
    elif expected_ip is not None and kind == "IP Address":
        try:
            matched = ipaddress.ip_address(value) == expected_ip
        except ValueError:
            matched = False
    if matched:
        break
raise SystemExit(0 if matched else 1)
PY
    openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    cert_public=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    key_public=$(openssl pkey -in "$private_key" -pubout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    [[ "$cert_public" =~ ^[0-9a-f]{64}$ ]] && [ "$cert_public" = "$key_public" ]
}

lineage_matches_domain() {
    local domain="$1" expected="" renewed=""
    [ -n "$domain" ] || return 1
    expected=$(readlink -f -- "${LE_LIVE_ROOT}/${domain}" 2>/dev/null) || return 1
    renewed=$(readlink -f -- "$RENEWED_LINEAGE" 2>/dev/null) || return 1
    [ "$renewed" = "$expected" ]
}

if lineage_matches_domain "$NAIVE_DOMAIN"; then
    certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem" \
        "$RENEWED_LINEAGE/privkey.pem" "$NAIVE_DOMAIN" || exit 1
    install -d -m 700 "$NAIVE_TARGET_DIR" || exit 1
    cert_tmp=$(mktemp "$NAIVE_TARGET_DIR/.fullchain.XXXXXX") || exit 1
    key_tmp=$(mktemp "$NAIVE_TARGET_DIR/.privkey.XXXXXX") || {
        rm -f "$cert_tmp"
        exit 1
    }
    if ! install -m 600 "$RENEWED_LINEAGE/fullchain.pem" "$cert_tmp" || \
       ! install -m 600 "$RENEWED_LINEAGE/privkey.pem" "$key_tmp"; then
        rm -f "$cert_tmp" "$key_tmp"
        exit 1
    fi
    mv -f "$key_tmp" "$NAIVE_TARGET_DIR/privkey.pem" || {
        rm -f "$cert_tmp" "$key_tmp"
        exit 1
    }
    mv -f "$cert_tmp" "$NAIVE_TARGET_DIR/fullchain.pem" || {
        rm -f "$cert_tmp"
        exit 1
    }
    # Certbot must see a deploy failure.  Silently accepting a failed reload
    # leaves the daemon serving the old certificate until an unrelated
    # restart, potentially past expiry.
    "$SYSTEMCTL_BIN" try-restart sing-box >/dev/null 2>&1 || exit 1
fi

if [ "$SUB_ACCESS_MODE" = https ] && lineage_matches_domain "$SUB_DOMAIN"; then
    certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem" \
        "$RENEWED_LINEAGE/privkey.pem" "$SUB_DOMAIN" || exit 1
    [ -x "$RR_CLI" ] || exit 1
    "$RR_CLI" --refresh-subscription >/dev/null 2>&1 || exit 1
fi

exit 0
