#!/bin/bash
# Certbot deploy hook for RR-vps managed NaiveProxy, subscription TLS and
# Nexus public-domain HTTPS.
set -u

CONFIG_FILE="${RR_CERT_HOOK_CONFIG_FILE:-/etc/argo_vmess.conf}"
NEXUS_CONFIG_FILE="${RR_CERT_HOOK_NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}"
NAIVE_TARGET_DIR="${RR_CERT_HOOK_NAIVE_TARGET_DIR:-/etc/rr-naive}"
LE_LIVE_ROOT="${RR_CERT_HOOK_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
RR_CLI="${RR_CERT_HOOK_CLI:-/usr/local/bin/rr}"
NGINX_BIN="${RR_CERT_HOOK_NGINX:-nginx}"
CA_BUNDLE="${RR_CERT_HOOK_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
CERT_RELOAD_PENDING_DIR="${RR_CERT_RELOAD_PENDING_DIR:-/var/lib/rr-vps/cert-reload-pending}"
CERT_RELOAD_TEST_PROBE="${RR_CERT_RELOAD_TEST_PROBE:-}"
NAIVE_DOMAIN=""
NAIVE_PORT=""
SUB_ACCESS_MODE="local"
SUB_DOMAIN=""
SUB_PORT=""
NEXUS_DOMAIN=""
NEXUS_PORT=""

[ -n "${RENEWED_LINEAGE:-}" ] || exit 0

rr_certificate_hook_locked() {
local parsed_main="" parsed_nexus="" parsed_main_q="" parsed_nexus_q=""
local hook_failed=0 main_parse_failed=0 nexus_parse_failed=0
local -a main_values=() nexus_values=()
parsed_main=$(mktemp /tmp/rr-cert-hook-main.XXXXXX) || return 1
parsed_nexus=$(mktemp /tmp/rr-cert-hook-nexus.XXXXXX) || {
    rm -f -- "$parsed_main"
    return 1
}
printf -v parsed_main_q '%q' "$parsed_main"
printf -v parsed_nexus_q '%q' "$parsed_nexus"
trap "rm -f -- $parsed_main_q $parsed_nexus_q" EXIT HUP INT TERM

# Parse the node/subscription and Nexus ownership domains independently.  A
# malformed unrelated consumer must remain observable in the aggregate exit
# status, but can never starve a valid renewed lineage from publishing its own
# durable marker and attempting its own reload.
if ! python3 - "$CONFIG_FILE" > "$parsed_main" <<'PY'
import pathlib
import re
import sys

allowed = {
    "NAIVE_DOMAIN", "NAIVE_PORT", "SUB_ACCESS_MODE", "SUB_DOMAIN", "SUB_PORT"
}
values: dict[str, list[str]] = {key: [] for key in allowed}
config_path = pathlib.Path(sys.argv[1])
if config_path.is_file():
    with config_path.open("r", encoding="utf-8") as config:
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
naive_port = values["NAIVE_PORT"][0] if values["NAIVE_PORT"] else ""
sub_mode = values["SUB_ACCESS_MODE"][0] if values["SUB_ACCESS_MODE"] else "local"
sub_domain = values["SUB_DOMAIN"][0] if values["SUB_DOMAIN"] else ""
sub_port = values["SUB_PORT"][0] if values["SUB_PORT"] else ""
if naive_domain and not domain_re.fullmatch(naive_domain):
    raise SystemExit("invalid NAIVE_DOMAIN")
if naive_domain and (not naive_port.isdecimal() or not 1 <= int(naive_port) <= 65535):
    raise SystemExit("invalid NAIVE_PORT")
if naive_domain:
    naive_port = str(int(naive_port))
if sub_mode not in {"local", "https"}:
    raise SystemExit("invalid SUB_ACCESS_MODE")
if sub_mode == "https":
    if not domain_re.fullmatch(sub_domain):
        raise SystemExit("invalid SUB_DOMAIN")
    if not sub_port.isdecimal() or not 1 <= int(sub_port) <= 65535:
        raise SystemExit("invalid SUB_PORT")
    sub_port = str(int(sub_port))
else:
    sub_domain = ""
    sub_port = ""
print(naive_domain)
print(naive_port)
print(sub_mode)
print(sub_domain)
print(sub_port)
PY
then
    main_parse_failed=1
else
    mapfile -t main_values < "$parsed_main" || main_parse_failed=1
    [ "${#main_values[@]}" -eq 5 ] || main_parse_failed=1
fi
if [ "$main_parse_failed" -eq 0 ]; then
    NAIVE_DOMAIN="${main_values[0]}"
    NAIVE_PORT="${main_values[1]}"
    SUB_ACCESS_MODE="${main_values[2]}"
    SUB_DOMAIN="${main_values[3]}"
    SUB_PORT="${main_values[4]}"
else
    NAIVE_DOMAIN=""
    NAIVE_PORT=""
    SUB_ACCESS_MODE=local
    SUB_DOMAIN=""
    SUB_PORT=""
    hook_failed=1
fi

if ! python3 - "$NEXUS_CONFIG_FILE" > "$parsed_nexus" <<'PY'
import ipaddress
import json
import pathlib
import re
import sys

nexus_path = pathlib.Path(sys.argv[1])
domain_re = re.compile(
    r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}"
)
nexus_domain = ""
nexus_port = ""
if nexus_path.is_file():
    with nexus_path.open("r", encoding="utf-8") as nexus_source:
        nexus = json.load(nexus_source)
    if not isinstance(nexus, dict):
        raise SystemExit("invalid Nexus configuration")
    nexus_mode = nexus.get("mode", "local")
    if nexus_mode == "public":
        candidate = nexus.get("domain", "")
        if not isinstance(candidate, str):
            raise SystemExit("invalid Nexus domain")
        try:
            ipaddress.ip_address(candidate.strip("[]"))
        except ValueError:
            if not domain_re.fullmatch(candidate):
                raise SystemExit("invalid Nexus public domain")
            candidate_port = nexus.get("public_port", "")
            if isinstance(candidate_port, bool):
                raise SystemExit("invalid Nexus public port")
            candidate_port = str(candidate_port)
            if not candidate_port.isdecimal() or not 1 <= int(candidate_port) <= 65535:
                raise SystemExit("invalid Nexus public port")
            nexus_domain = candidate
            nexus_port = str(int(candidate_port))
    elif nexus_mode != "local":
        raise SystemExit("invalid Nexus mode")
print(nexus_domain)
print(nexus_port)
PY
then
    nexus_parse_failed=1
else
    mapfile -t nexus_values < "$parsed_nexus" || nexus_parse_failed=1
    [ "${#nexus_values[@]}" -eq 2 ] || nexus_parse_failed=1
fi
if [ "$nexus_parse_failed" -eq 0 ]; then
    NEXUS_DOMAIN="${nexus_values[0]}"
    NEXUS_PORT="${nexus_values[1]}"
else
    NEXUS_DOMAIN=""
    NEXUS_PORT=""
    hook_failed=1
fi

certificate_pair_valid() {
    local certificate="$1" private_key="$2" domain="$3" cert_public="" key_public=""
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    python3 - "$certificate" "$domain" >/dev/null 2>&1 <<'PY' || return 1
import ssl
import sys

decoded = ssl._ssl._test_decode_cert(sys.argv[1])
identity = sys.argv[2].strip()
identities = decoded.get("subjectAltName", ())
exact = (
    len(identities) == 1
    and identities[0][0] == "DNS"
    and identities[0][1].lower() == identity.lower()
)
raise SystemExit(0 if exact else 1)
PY
    openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    openssl pkey -in "$private_key" -check -noout -passin pass: \
        >/dev/null 2>&1 || return 1
    cert_public=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    key_public=$(openssl pkey -in "$private_key" -pubout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    [[ "$cert_public" =~ ^[0-9a-f]{64}$ ]] && [ "$cert_public" = "$key_public" ] || return 1
    [ -s "$CA_BUNDLE" ] || return 1
    openssl verify -purpose sslserver -CAfile "$CA_BUNDLE" \
        -untrusted "$certificate" "$certificate" >/dev/null 2>&1
}

CERT_RELOAD_PENDING_FORMAT="rr-certificate-consumer-pending-v1"
CERT_RELOAD_MARKER_CONSUMER=""
CERT_RELOAD_MARKER_DOMAIN=""
CERT_RELOAD_MARKER_PORT=""
CERT_RELOAD_MARKER_GENERATION=""
CERT_RELOAD_MARKER_CERT_SHA256=""
CERT_RELOAD_MARKER_KEY_SHA256=""
CERT_RELOAD_MARKER_FULLCHAIN_SHA256=""

certificate_reload_safe_directory() {
    local directory="$1" expected_mode="$2" logical="" resolved="" metadata=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    logical=$(realpath -ms -- "$directory" 2>/dev/null) || return 1
    resolved=$(readlink -e -- "$directory" 2>/dev/null) || return 1
    [ "$directory" = "$logical" ] && [ "$logical" = "$resolved" ] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
    [ "$metadata" = "0:0:${expected_mode}" ]
}

certificate_reload_prepare_directory() {
    local directory="$CERT_RELOAD_PENDING_DIR" parent="" grandparent=""
    local parent_mode=""
    [[ "$directory" = /* ]] || return 1
    parent=$(dirname -- "$directory") || return 1
    if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then
        grandparent=$(dirname -- "$parent") || return 1
        [ "$grandparent" != "$parent" ] || return 1
        [ -d "$grandparent" ] && [ ! -L "$grandparent" ] || return 1
        [ "$(readlink -e -- "$grandparent" 2>/dev/null)" = \
            "$(realpath -ms -- "$grandparent" 2>/dev/null)" ] || return 1
        [ "$(stat -c '%u:%g' -- "$grandparent" 2>/dev/null)" = 0:0 ] || return 1
        parent_mode=$(stat -c '%a' -- "$grandparent" 2>/dev/null) || return 1
        (( (8#$parent_mode & 0022) == 0 )) || return 1
        mkdir -- "$parent" || return 1
        chown 0:0 "$parent" && chmod 700 "$parent" && \
            sync -f "$grandparent" || return 1
    fi
    certificate_reload_safe_directory "$parent" 700 || return 1
    if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
        mkdir -- "$directory" || return 1
        chown 0:0 "$directory" && chmod 700 "$directory" && \
            sync -f "$parent" || return 1
    fi
    certificate_reload_safe_directory "$directory" 700
}

certificate_reload_marker_read() {
    local marker="$1" expected_consumer="$2" size=""
    local -a lines=()
    case "$expected_consumer" in naive|subscription|nexus) ;; *) return 1 ;; esac
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    size=$(stat -c '%s' -- "$marker" 2>/dev/null) || return 1
    [ "$size" -gt 0 ] && [ "$size" -le 1024 ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 8 ] || return 1
    [ "${lines[0]}" = "format=${CERT_RELOAD_PENDING_FORMAT}" ] || return 1
    [ "${lines[1]}" = "consumer=${expected_consumer}" ] || return 1
    CERT_RELOAD_MARKER_CONSUMER="${lines[1]#consumer=}"
    CERT_RELOAD_MARKER_DOMAIN="${lines[2]#domain=}"
    CERT_RELOAD_MARKER_PORT="${lines[3]#port=}"
    CERT_RELOAD_MARKER_GENERATION="${lines[4]#generation_sha256=}"
    CERT_RELOAD_MARKER_CERT_SHA256="${lines[5]#cert_sha256=}"
    CERT_RELOAD_MARKER_KEY_SHA256="${lines[6]#key_sha256=}"
    CERT_RELOAD_MARKER_FULLCHAIN_SHA256="${lines[7]#fullchain_sha256=}"
    [ "${lines[2]}" = "domain=${CERT_RELOAD_MARKER_DOMAIN}" ] && \
        [[ "$CERT_RELOAD_MARKER_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 1
    [ "${lines[3]}" = "port=${CERT_RELOAD_MARKER_PORT}" ] && \
        [[ "$CERT_RELOAD_MARKER_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && \
        [ "$CERT_RELOAD_MARKER_PORT" -le 65535 ] || return 1
    [ "${lines[4]}" = "generation_sha256=${CERT_RELOAD_MARKER_GENERATION}" ] && \
        [[ "$CERT_RELOAD_MARKER_GENERATION" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "${lines[5]}" = "cert_sha256=${CERT_RELOAD_MARKER_CERT_SHA256}" ] && \
        [[ "$CERT_RELOAD_MARKER_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "${lines[6]}" = "key_sha256=${CERT_RELOAD_MARKER_KEY_SHA256}" ] && \
        [[ "$CERT_RELOAD_MARKER_KEY_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "${lines[7]}" = "fullchain_sha256=${CERT_RELOAD_MARKER_FULLCHAIN_SHA256}" ] && \
        [[ "$CERT_RELOAD_MARKER_FULLCHAIN_SHA256" =~ ^[0-9a-f]{64}$ ]]
}

certificate_reload_generation_read() {
    local lineage="$1" cert_path="" key_path="" fullchain_path=""
    cert_path=$(readlink -f -- "$lineage/cert.pem" 2>/dev/null) || return 1
    key_path=$(readlink -f -- "$lineage/privkey.pem" 2>/dev/null) || return 1
    fullchain_path=$(readlink -f -- "$lineage/fullchain.pem" 2>/dev/null) || return 1
    CERT_RELOAD_MARKER_CERT_SHA256=$(sha256sum -- "$lineage/cert.pem" | awk '{print $1}') || return 1
    CERT_RELOAD_MARKER_KEY_SHA256=$(sha256sum -- "$lineage/privkey.pem" | awk '{print $1}') || return 1
    CERT_RELOAD_MARKER_FULLCHAIN_SHA256=$(sha256sum -- "$lineage/fullchain.pem" | awk '{print $1}') || return 1
    [[ "$CERT_RELOAD_MARKER_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] && \
        [[ "$CERT_RELOAD_MARKER_KEY_SHA256" =~ ^[0-9a-f]{64}$ ]] && \
        [[ "$CERT_RELOAD_MARKER_FULLCHAIN_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    CERT_RELOAD_MARKER_GENERATION=$(
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$cert_path" "$key_path" "$fullchain_path" \
            "$CERT_RELOAD_MARKER_CERT_SHA256" \
            "$CERT_RELOAD_MARKER_KEY_SHA256" \
            "$CERT_RELOAD_MARKER_FULLCHAIN_SHA256" | sha256sum | awk '{print $1}'
    ) || return 1
    [[ "$CERT_RELOAD_MARKER_GENERATION" =~ ^[0-9a-f]{64}$ ]]
}

certificate_reload_marker_publish() {
    local consumer="$1" domain="$2" port="$3" marker="" temporary=""
    case "$consumer" in naive|subscription|nexus) ;; *) return 1 ;; esac
    certificate_reload_generation_read "$RENEWED_LINEAGE" || return 1
    certificate_reload_prepare_directory || return 1
    marker="$CERT_RELOAD_PENDING_DIR/${consumer}.pending"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        certificate_reload_marker_read "$marker" "$consumer" || return 1
        certificate_reload_generation_read "$RENEWED_LINEAGE" || return 1
    fi
    temporary=$(mktemp "$CERT_RELOAD_PENDING_DIR/.${consumer}.pending.XXXXXX") || \
        return 1
    if ! printf '%s\n' \
            "format=${CERT_RELOAD_PENDING_FORMAT}" \
            "consumer=${consumer}" \
            "domain=${domain}" \
            "port=${port}" \
            "generation_sha256=${CERT_RELOAD_MARKER_GENERATION}" \
            "cert_sha256=${CERT_RELOAD_MARKER_CERT_SHA256}" \
            "key_sha256=${CERT_RELOAD_MARKER_KEY_SHA256}" \
            "fullchain_sha256=${CERT_RELOAD_MARKER_FULLCHAIN_SHA256}" \
            > "$temporary" || \
       ! chown 0:0 "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$CERT_RELOAD_PENDING_DIR" || \
       ! certificate_reload_marker_read "$marker" "$consumer"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CERT_RELOAD_CRASH_AFTER_MARKER:-}" = "$consumer" ]; then
        kill -KILL "${BASHPID:-$$}"
    fi
}

certificate_reload_marker_clear() {
    local consumer="$1" marker=""
    local expected_generation="$CERT_RELOAD_MARKER_GENERATION"
    local expected_cert="$CERT_RELOAD_MARKER_CERT_SHA256"
    local expected_key="$CERT_RELOAD_MARKER_KEY_SHA256"
    local expected_fullchain="$CERT_RELOAD_MARKER_FULLCHAIN_SHA256"
    marker="$CERT_RELOAD_PENDING_DIR/${consumer}.pending"
    certificate_reload_marker_read "$marker" "$consumer" || return 1
    [ "$CERT_RELOAD_MARKER_GENERATION" = "$expected_generation" ] && \
        [ "$CERT_RELOAD_MARKER_CERT_SHA256" = "$expected_cert" ] && \
        [ "$CERT_RELOAD_MARKER_KEY_SHA256" = "$expected_key" ] && \
        [ "$CERT_RELOAD_MARKER_FULLCHAIN_SHA256" = "$expected_fullchain" ] || return 1
    rm -f -- "$marker" || return 1
    sync -f "$CERT_RELOAD_PENDING_DIR" || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ]
}

certificate_reload_tls_is_current() {
    local consumer="$1" domain="$2" port="$3" expected_leaf="" served_leaf=""
    local response="" endpoint=""
    if [ -n "$CERT_RELOAD_TEST_PROBE" ]; then
        [ -x "$CERT_RELOAD_TEST_PROBE" ] || return 1
        "$CERT_RELOAD_TEST_PROBE" "$consumer" "$domain" "$port" \
            "$RENEWED_LINEAGE/cert.pem"
        return $?
    fi
    command -v timeout >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || \
        return 1
    expected_leaf=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -outform DER \
        2>/dev/null | sha256sum | awk '{print $1}') || return 1
    [[ "$expected_leaf" =~ ^[0-9a-f]{64}$ ]] || return 1
    for endpoint in "127.0.0.1:${port}" "[::1]:${port}"; do
        response=$(timeout --kill-after=2 8 openssl s_client -connect "$endpoint" \
            -servername "$domain" -showcerts </dev/null 2>/dev/null) || continue
        served_leaf=$(printf '%s\n' "$response" | openssl x509 -outform DER \
            2>/dev/null | sha256sum | awk '{print $1}') || continue
        [ "$served_leaf" = "$expected_leaf" ] && return 0
    done
    return 1
}

PAIR_PENDING_VALUE="rr-certificate-pair-pending-v1"

pair_pending_is_exact() {
    local marker="$1" expected_size=$(( ${#PAIR_PENDING_VALUE} + 1 ))
    local -a lines=()
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h:%s' -- "$marker" 2>/dev/null)" = \
        "0:0:600:1:${expected_size}" ] || return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 1 ] && [ "${lines[0]}" = "$PAIR_PENDING_VALUE" ]
}

publish_pair_pending() {
    local marker="$1" directory="" temporary=""
    directory=$(dirname -- "$marker") || return 1
    install -d -o 0 -g 0 -m 700 -- "$directory" || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || return 1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        pair_pending_is_exact "$marker"
        return $?
    fi
    temporary=$(mktemp "$directory/.pair-pending.XXXXXX") || return 1
    if ! printf '%s\n' "$PAIR_PENDING_VALUE" > "$temporary" || \
       ! chown 0:0 "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$directory" || ! pair_pending_is_exact "$marker"; then
        rm -f -- "$temporary"
        return 1
    fi
}

clear_pair_pending() {
    local marker="$1" directory=""
    pair_pending_is_exact "$marker" || return 1
    directory=$(dirname -- "$marker") || return 1
    rm -f -- "$marker" || return 1
    sync -f "$directory" || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ]
}

publish_certificate_pair() {
    local certificate_source="$1" key_source="$2" certificate_target="$3"
    local key_target="$4" marker="$5" domain="$6" directory=""
    directory=$(dirname -- "$certificate_target") || return 1
    [ "$(dirname -- "$key_target")" = "$directory" ] && \
        [ "$(dirname -- "$marker")" = "$directory" ] || return 1
    certificate_pair_valid "$certificate_source" "$key_source" "$domain" || return 1
    sync -f "$certificate_source" && sync -f "$key_source" || return 1
    publish_pair_pending "$marker" || return 1
    mv -f -- "$key_source" "$key_target" || return 1
    sync -f "$directory" || return 1
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST:-0}" = 1 ]; then
        return 1
    fi
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST:-0}" = 1 ]; then
        kill -KILL "${BASHPID:-$$}"
    fi
    mv -f -- "$certificate_source" "$certificate_target" || return 1
    sync -f "$directory" || return 1
    certificate_pair_valid "$certificate_target" "$key_target" "$domain" || return 1
    clear_pair_pending "$marker"
}

lineage_matches_domain() {
    local domain="$1" expected="" renewed=""
    [ -n "$domain" ] || return 1
    expected=$(readlink -f -- "${LE_LIVE_ROOT}/${domain}" 2>/dev/null) || return 1
    renewed=$(readlink -f -- "$RENEWED_LINEAGE" 2>/dev/null) || return 1
    [ "$renewed" = "$expected" ]
}

deploy_naive_certificate() {
    local cert_tmp="" key_tmp="" marker="$NAIVE_TARGET_DIR/.pair-pending"
    certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem" \
        "$RENEWED_LINEAGE/privkey.pem" "$NAIVE_DOMAIN" || return 1
    certificate_reload_marker_publish naive "$NAIVE_DOMAIN" "$NAIVE_PORT" || \
        return 1
    install -d -m 700 "$NAIVE_TARGET_DIR" || return 1
    cert_tmp=$(mktemp "$NAIVE_TARGET_DIR/.fullchain.XXXXXX") || return 1
    key_tmp=$(mktemp "$NAIVE_TARGET_DIR/.privkey.XXXXXX") || {
        rm -f "$cert_tmp"
        return 1
    }
    if ! install -m 600 "$RENEWED_LINEAGE/fullchain.pem" "$cert_tmp" || \
       ! install -m 600 "$RENEWED_LINEAGE/privkey.pem" "$key_tmp"; then
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    fi
    # The live symlinks can rotate between the two reads.  Validate the
    # captured pair, not only the source names observed before copying.
    certificate_pair_valid "$cert_tmp" "$key_tmp" "$NAIVE_DOMAIN" || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    publish_certificate_pair "$cert_tmp" "$key_tmp" \
        "$NAIVE_TARGET_DIR/fullchain.pem" "$NAIVE_TARGET_DIR/privkey.pem" \
        "$marker" "$NAIVE_DOMAIN" || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    # Certbot must see a deploy failure.  Silently accepting a failed reload
    # leaves the daemon serving the old certificate until an unrelated
    # restart, potentially past expiry.
    # Never invoke systemctl directly from the hook.  The RR CLI authenticates
    # the isolated lock delegation, proves the complete effective unit, and
    # requires a new systemd generation before reporting success.  A rejected
    # identity therefore leaves the durable consumer marker for health retry.
    [ -x "$RR_CLI" ] || return 1
    "$RR_CLI" --reload-singbox-certificate >/dev/null 2>&1 || return 1
    certificate_reload_tls_is_current naive "$NAIVE_DOMAIN" "$NAIVE_PORT" || \
        return 1
    certificate_reload_marker_clear naive
}

refresh_subscription_certificate() {
    certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem" \
        "$RENEWED_LINEAGE/privkey.pem" "$SUB_DOMAIN" || return 1
    [ -x "$RR_CLI" ] || return 1
    certificate_reload_marker_publish subscription "$SUB_DOMAIN" "$SUB_PORT" || \
        return 1
    "$RR_CLI" --refresh-subscription >/dev/null 2>&1 || return 1
    certificate_reload_tls_is_current subscription "$SUB_DOMAIN" "$SUB_PORT" || \
        return 1
    certificate_reload_marker_clear subscription
}

reload_nexus_certificate() {
    certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem" \
        "$RENEWED_LINEAGE/privkey.pem" "$NEXUS_DOMAIN" || return 1
    certificate_reload_marker_publish nexus "$NEXUS_DOMAIN" "$NEXUS_PORT" || \
        return 1
    "$NGINX_BIN" -t >/dev/null 2>&1 || return 1
    # Do not execute the effective systemd ExecReload: an otherwise unrelated
    # Nginx drop-in can replace it.  The same Nginx binary that accepted the
    # complete configuration sends the native reload signal instead.  Failure
    # or an unchanged served leaf keeps the durable Nexus marker for retry.
    "$NGINX_BIN" -s reload >/dev/null 2>&1 || return 1
    certificate_reload_tls_is_current nexus "$NEXUS_DOMAIN" "$NEXUS_PORT" || \
        return 1
    certificate_reload_marker_clear nexus
}

# One renewed lineage can serve several RR consumers.  Attempt every matching
# consumer even when an earlier reload fails, then return one aggregate status
# to Certbot so the failure remains observable and retryable.
if lineage_matches_domain "$NAIVE_DOMAIN"; then
    deploy_naive_certificate || hook_failed=1
fi

if [ "$SUB_ACCESS_MODE" = https ] && lineage_matches_domain "$SUB_DOMAIN"; then
    refresh_subscription_certificate || hook_failed=1
fi

if lineage_matches_domain "$NEXUS_DOMAIN"; then
    reload_nexus_certificate || hook_failed=1
fi

return "$hook_failed"
}

RR_CERT_HOOK_LOCK_MODULE="${RR_CERT_HOOK_LOCK_MODULE:-/usr/local/lib/rr/modules/55-resilience.sh}"
[ -f "$RR_CERT_HOOK_LOCK_MODULE" ] && [ ! -L "$RR_CERT_HOOK_LOCK_MODULE" ] || exit 1
# The same shared+legacy update lock serializes certificate publication,
# daemon reloads, updater/restore mutations and the delegated subscription
# refresh.  `isolated` keeps both locks in the root parent while closing their
# descriptors in the callback, so the RR child can authenticate delegation
# without inheriting a long-lived lock FD.
# shellcheck source=/dev/null
source "$RR_CERT_HOOK_LOCK_MODULE" || exit 1
declare -F rr_run_with_update_locks >/dev/null 2>&1 || exit 1
hook_result=0
rr_run_with_update_locks isolated 0 rr_certificate_hook_locked || hook_result=$?
case "$hook_result" in
    0) exit 0 ;;
    75|76) exit 1 ;;
    *) exit "$hook_result" ;;
esac
