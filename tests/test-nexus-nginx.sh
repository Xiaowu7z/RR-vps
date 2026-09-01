#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
NEXUS_NGINX_TRUST_ROOT="$TEST_ROOT"

RR_LIB_DIR="$ROOT_DIR"
RR_REPOSITORY="example/rr-vps"
# shellcheck source=../modules/85-nexus.sh
source "$ROOT_DIR/modules/85-nexus.sh"

is_valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_ip_version() {
    local value="${1:-}" version="${2:-}"
    case "$version" in
        4) [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ;;
        6) [[ "$value" == *:* ]] ;;
        *) return 1 ;;
    esac
}

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

reset_case() {
    local name="$1"
    CASE_ROOT="$TEST_ROOT/$name"
    NEXUS_NGINX_AVAILABLE_DIR="$CASE_ROOT/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$CASE_ROOT/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
    NGINX_CALLS=0
    RELOAD_CALLS=0
    NGINX_FAIL_FIRST=false
    RELOAD_FAIL_FIRST=false
    NGINX_ACTIVE=true
}

seed_all_supported_sites() {
    nexus_emit_nginx_domain_http_site panel.example.com \
        /var/www/rr-nexus-certbot > "$NEXUS_NGINX_SITE"
    nexus_emit_nginx_domain_custom_site panel.example.com 18443 \
        /var/www/rr-nexus-certbot false > "${NEXUS_NGINX_SITE}.port"
    nexus_emit_nginx_ip_site 192.0.2.10 18443 acme-ip-shortlived false > \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    chmod 644 "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    ln -s "$NEXUS_NGINX_SITE" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
    ln -s "${NEXUS_NGINX_SITE}.port" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
}

nginx() {
    [ "${1:-}" = -t ] || return 1
    NGINX_CALLS=$((NGINX_CALLS + 1))
    if [ "$NGINX_FAIL_FIRST" = true ] && [ "$NGINX_CALLS" -eq 1 ]; then
        return 1
    fi
    return 0
}

systemctl() {
    case "${1:-}" in
        is-active) [ "$NGINX_ACTIVE" = true ] ;;
        reload)
            RELOAD_CALLS=$((RELOAD_CALLS + 1))
            if [ "$RELOAD_FAIL_FIRST" = true ] && [ "$RELOAD_CALLS" -eq 1 ]; then
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

reset_case generated-config
nexus_write_nginx_site panel.example.com 18443
nexus_write_nginx_custom_port panel.example.com 18443
python3 - "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" <<'PY'
import pathlib
import re
import sys

http_bootstrap = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
custom = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert "limit_req_zone $binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;" in custom
assert "limit_req zone=rr_nexus_login burst=5 nodelay;" in custom

tls_server, http_server = custom.split("\nserver {", 2)[1:]
assert "listen 18443 ssl;" in tls_server
assert "listen 80;" in http_server

def location(server: str, pattern: str) -> str:
    match = re.search(pattern + r"\s*\{(?P<body>.*?)\n    \}", server, re.S)
    assert match, pattern
    return match.group("body")

assert len(re.findall(r"^\s*location\b", http_bootstrap, re.M)) == 2
bootstrap_acme = location(http_bootstrap, r"location \^~ /\.well-known/acme-challenge/")
assert "root /var/www/rr-nexus-certbot;" in bootstrap_acme
assert "try_files $uri =404;" in bootstrap_acme
bootstrap_default = location(http_bootstrap, r"location /")
assert "return 444;" in bootstrap_default
assert "proxy_pass" not in http_bootstrap
assert "location = /api/login" not in http_bootstrap

tls_sub = location(tls_server, r"location \^~ /sub/")
assert "access_log off;" in tls_sub and "error_log /dev/null crit;" in tls_sub
assert "proxy_pass http://127.0.0.1:7900;" in tls_sub
tls_qr = location(tls_server, r"location ~ \^/api/\(devices/\[\^/\]\+/qr\|remote/qr\)/\?\$")
assert "access_log off;" in tls_qr and "error_log /dev/null crit;" in tls_qr
assert "proxy_pass http://127.0.0.1:7900;" in tls_qr and "return 404;" not in tls_qr
http_qr = location(http_server, r"location ~ \^/api/\(devices/\[\^/\]\+/qr\|remote/qr\)/\?\$")
assert "access_log off;" in http_qr and "error_log /dev/null crit;" in http_qr
assert "return 404;" in http_qr and "proxy_pass" not in http_qr
http_acme = location(http_server, r"location \^~ /\.well-known/acme-challenge/")
assert "root /var/www/rr-nexus-certbot;" in http_acme
assert "try_files $uri =404;" in http_acme
for route in ("location = /sub", "location ^~ /sub/"):
    start = http_server.index(route)
    body = http_server[start:http_server.index("\n    }", start)]
    assert "access_log off;" in body and "error_log /dev/null crit;" in body
    assert "return 404;" in body
PY
[ ! -e "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf" ]
[ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf")" = "${NEXUS_NGINX_SITE}.port" ]
pass "ACME bootstrap rejects non-challenge traffic and domain config keeps QR tokens out of logs"

reset_case validation-rollback
nexus_emit_nginx_domain_custom_site old.example.com 19443 \
    /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
nexus_emit_nginx_domain_http_site_v711 old.example.com > "$NEXUS_NGINX_SITE"
chmod 644 "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port"
ln -s "$NEXUS_NGINX_SITE" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
ln -s "${NEXUS_NGINX_SITE}.port" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
cp -a "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" "$CASE_ROOT/"
NGINX_FAIL_FIRST=true
if nexus_write_nginx_custom_port panel.example.com 18443; then
    printf '%s\n' 'nginx -t failure was reported as success' >&2
    exit 1
fi
cmp -s "$CASE_ROOT/rr-nexus.conf" "$NEXUS_NGINX_SITE"
cmp -s "$CASE_ROOT/rr-nexus.conf.port" "${NEXUS_NGINX_SITE}.port"
[ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf")" = "$NEXUS_NGINX_SITE" ]
[ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf")" = "${NEXUS_NGINX_SITE}.port" ]
[ "$NGINX_CALLS" -eq 2 ] && [ "$RELOAD_CALLS" -eq 1 ]
pass "failed syntax validation restores the exact former RR sites"

reset_case reload-rollback
nexus_emit_nginx_domain_custom_site old.example.com 19443 \
    /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
nexus_emit_nginx_domain_http_site_v711 old.example.com > "$NEXUS_NGINX_SITE"
chmod 644 "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port"
ln -s "$NEXUS_NGINX_SITE" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
ln -s "${NEXUS_NGINX_SITE}.port" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
cp -a "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" "$CASE_ROOT/"
RELOAD_FAIL_FIRST=true
if nexus_write_nginx_custom_port panel.example.com 18443; then
    printf '%s\n' 'nginx reload failure was reported as success' >&2
    exit 1
fi
cmp -s "$CASE_ROOT/rr-nexus.conf" "$NEXUS_NGINX_SITE"
cmp -s "$CASE_ROOT/rr-nexus.conf.port" "${NEXUS_NGINX_SITE}.port"
[ "$NGINX_CALLS" -eq 2 ] && [ "$RELOAD_CALLS" -eq 2 ]
pass "failed reload restores and reloads the former RR sites"

reset_case inactive-service
NGINX_ACTIVE=false
nexus_write_nginx_custom_port panel.example.com 18443
[ "$RELOAD_CALLS" -eq 0 ]
pass "offline Nginx is validated without a false reload failure"

reset_case exact-renderers
seed_all_supported_sites
nexus_nginx_managed_paths_are_owned || fail 'current renderers were not owned'
nexus_ip_nginx_site_is_exact 192.0.2.10 18443 acme-ip-shortlived \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" || \
    fail 'current trusted IP renderer was not exact'
nexus_emit_nginx_domain_http_site_v711 old.example.com > "$NEXUS_NGINX_SITE"
nexus_emit_nginx_domain_custom_site old.example.com 19443 \
    /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
nexus_emit_nginx_ip_site 192.0.2.9 19443 legacy-self-signed true > \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
nexus_nginx_managed_paths_are_owned || fail 'supported historical renderers were not owned'
nexus_ip_nginx_site_is_exact 192.0.2.9 19443 legacy-self-signed \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" || \
    fail 'historical IP renderer was not exact'
reset_case exact-absent
nexus_ip_nginx_site_is_exact 192.0.2.10 18443 pending-acme-ip \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" || \
    fail 'exact IP helper rejected its documented both-absent state'
pass "current and supported historical renderers have exact ownership proofs"

(
    reset_case trusted-ip-writer
    NEXUS_CERT_DIR="$CASE_ROOT/certs"
    mkdir -p "$NEXUS_CERT_DIR"
    printf '%s\n' certificate > "$NEXUS_CERT_DIR/ip.crt"
    printf '%s\n' private-key > "$NEXUS_CERT_DIR/ip.key"
    chmod 644 "$NEXUS_CERT_DIR/ip.crt"
    chmod 600 "$NEXUS_CERT_DIR/ip.key"
    is_global_ip_version() { is_ip_version "$@"; }
    nexus_ip_acme_runtime_is_ready() { return 0; }
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    nexus_install_ip_certificate_gate() { return 0; }
    nexus_ip_certificate_pair_is_ready() { return 0; }
    nexus_ip_certificate_gate_allows() { return 0; }
    SERVED_LEAF_CALLS=0
    nexus_ip_acme_served_leaf_matches_live() {
        [ "${1:-}" = 192.0.2.10 ] && [ "${2:-}" = 18443 ] || return 1
        SERVED_LEAF_CALLS=$((SERVED_LEAF_CALLS + 1))
    }
    nexus_firewall_open_accounted() {
        [ "$SERVED_LEAF_CALLS" -eq 1 ] || \
            fail 'trusted IP firewall opened before exact served-leaf proof'
        printf -v "$3" '%s' true
    }
    apt-get() { return 0; }
    systemctl() {
        case "$*" in
            'is-active --quiet nginx'|'enable --now nginx'|'reload nginx') return 0 ;;
            'is-enabled --quiet nginx') return 1 ;;
            *) return 1 ;;
        esac
    }
    owned_panel=false
    nexus_enable_public_ip_https 192.0.2.10 18443 owned_panel \
        acme-ip-shortlived || fail 'trusted IP writer failed'
    [ "$SERVED_LEAF_CALLS" -eq 1 ] || \
        fail 'trusted IP writer skipped exact served-leaf proof'
    [ "$owned_panel" = true ] || fail 'trusted IP writer lost firewall ownership output'
    cmp -s "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        <(nexus_emit_nginx_ip_site 192.0.2.10 18443 \
            acme-ip-shortlived false) || fail 'trusted IP writer diverged from renderer'
    nexus_ip_nginx_site_is_exact 192.0.2.10 18443 acme-ip-shortlived \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" || \
        fail 'trusted IP writer did not publish an exact site/link pair'
)
pass "trusted IP writer publishes the canonical exact renderer"

(
    reset_case trusted-ip-old-served-leaf
    NEXUS_CERT_DIR="$CASE_ROOT/certs"
    mkdir -m 700 "$NEXUS_CERT_DIR"
    printf '%s\n' new-live-certificate > "$NEXUS_CERT_DIR/ip.crt"
    printf '%s\n' new-live-private-key > "$NEXUS_CERT_DIR/ip.key"
    chmod 644 "$NEXUS_CERT_DIR/ip.crt"
    chmod 600 "$NEXUS_CERT_DIR/ip.key"
    nexus_emit_nginx_ip_site 192.0.2.10 19443 legacy-self-signed true > \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
    cp -a "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$CASE_ROOT/original-ip-site"
    cp -a "$NEXUS_CERT_DIR/ip.crt" "$CASE_ROOT/original-ip.crt"
    cp -a "$NEXUS_CERT_DIR/ip.key" "$CASE_ROOT/original-ip.key"

    is_global_ip_version() { is_ip_version "$@"; }
    nexus_ip_acme_runtime_is_ready() { return 0; }
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    nexus_install_ip_certificate_gate() { return 0; }
    nexus_ip_certificate_pair_is_ready() { return 0; }
    nexus_ip_certificate_gate_allows() { return 0; }
    # Model a trusted old certificate for this same IP remaining in an old
    # Nginx worker after reload.  Module 86 separately exercises the real
    # CA/identity-valid A-vs-live-B leaf hash rejection.
    SERVED_LEAF_CALLS=0
    nexus_ip_acme_served_leaf_matches_live() {
        [ "${1:-}" = 192.0.2.10 ] && [ "${2:-}" = 18443 ] || return 2
        SERVED_LEAF_CALLS=$((SERVED_LEAF_CALLS + 1))
        return 1
    }
    FIREWALL_OPEN_CALLS=0
    nexus_firewall_open_accounted() {
        FIREWALL_OPEN_CALLS=$((FIREWALL_OPEN_CALLS + 1))
        return 0
    }
    nexus_firewall_compensate_public_opens() { return 0; }
    apt-get() { return 0; }
    systemctl() {
        case "$*" in
            'is-active --quiet nginx'|'enable --now nginx'|'reload nginx'|\
            'daemon-reload'|'disable nginx') return 0 ;;
            'is-enabled --quiet nginx') return 1 ;;
            *) return 1 ;;
        esac
    }

    if nexus_enable_public_ip_https 192.0.2.10 18443 '' \
        pending-acme-ip; then
        fail 'old valid same-IP served leaf was accepted as the live generation'
    fi
    [ "$SERVED_LEAF_CALLS" -eq 1 ] || \
        fail 'old served leaf was not checked exactly once'
    [ "$FIREWALL_OPEN_CALLS" -eq 0 ] || \
        fail 'panel firewall opened before rejecting the old served leaf'
    cmp -s "$CASE_ROOT/original-ip-site" \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" || \
        fail 'served-leaf failure did not restore the former IP site'
    [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf")" = \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" ] || \
        fail 'served-leaf failure did not restore the former enabled link'
    cmp -s "$CASE_ROOT/original-ip.crt" "$NEXUS_CERT_DIR/ip.crt" && \
        cmp -s "$CASE_ROOT/original-ip.key" "$NEXUS_CERT_DIR/ip.key" || \
        fail 'served-leaf failure did not restore the live certificate pair'
    nexus_ip_nginx_site_is_exact 192.0.2.10 19443 legacy-self-signed \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" || \
        fail 'served-leaf rollback did not converge to the exact former pair'
)
pass "old valid same-IP served leaf fails before firewall and rolls back exactly"

reset_case metadata-and-link
seed_all_supported_sites
chmod 600 "$NEXUS_NGINX_SITE"
if nexus_nginx_managed_paths_are_owned; then
    fail 'wrong regular-file metadata was accepted'
fi
chmod 644 "$NEXUS_NGINX_SITE"
unlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
ln -s "${NEXUS_NGINX_SITE}.port" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
if nexus_nginx_managed_paths_are_owned; then
    fail 'wrong enabled-link target was accepted'
fi
pass "ownership proof binds regular metadata and exact enabled-link targets"

for foreign_kind in domain-http domain-port ip-site; do
    reset_case "foreign-${foreign_kind}"
    seed_all_supported_sites
    case "$foreign_kind" in
        domain-http) foreign_path="$NEXUS_NGINX_SITE" ;;
        domain-port) foreign_path="${NEXUS_NGINX_SITE}.port" ;;
        ip-site) foreign_path="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" ;;
    esac
    printf 'foreign-%s\n' "$foreign_kind" > "$foreign_path"
    if nexus_remove_public_proxy; then
        fail "foreign ${foreign_kind} collision was deleted"
    else
        remove_status=$?
    fi
    [ "$remove_status" -eq 2 ] || fail "foreign ${foreign_kind} did not return status 2"
    grep -Fxq "foreign-${foreign_kind}" "$foreign_path" || \
        fail "foreign ${foreign_kind} bytes were not preserved"
    [ -L "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf" ] || \
        fail "foreign ${foreign_kind} preflight mutated an earlier managed path"
done
pass "remove preflight preserves foreign domain, port and IP collisions"

reset_case foreign-domain-writer
printf '%s\n' foreign-domain > "$NEXUS_NGINX_SITE"
if nexus_write_nginx_site panel.example.com 18443; then
    fail 'domain writer overwrote a foreign same-name site'
else
    writer_status=$?
fi
[ "$writer_status" -eq 2 ] && [ "$NGINX_CALLS" -eq 0 ] && \
    grep -Fxq foreign-domain "$NEXUS_NGINX_SITE" || \
    fail 'domain writer mutated before foreign-collision refusal'
reset_case foreign-port-writer
printf '%s\n' foreign-port > "${NEXUS_NGINX_SITE}.port"
if nexus_write_nginx_custom_port panel.example.com 18443; then
    fail 'custom-port writer overwrote a foreign same-name site'
else
    writer_status=$?
fi
[ "$writer_status" -eq 2 ] && [ "$NGINX_CALLS" -eq 0 ] && \
    grep -Fxq foreign-port "${NEXUS_NGINX_SITE}.port" || \
    fail 'custom-port writer mutated before foreign-collision refusal'
(
    reset_case foreign-ip-writer
    printf '%s\n' foreign-ip > "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    APT_CALLS=0
    apt-get() { APT_CALLS=$((APT_CALLS + 1)); }
    if nexus_enable_public_ip_https 192.0.2.10 18443 '' legacy-self-signed; then
        fail 'IP writer overwrote a foreign same-name site'
    else
        writer_status=$?
    fi
    [ "$writer_status" -eq 2 ] && [ "$APT_CALLS" -eq 0 ] && \
        grep -Fxq foreign-ip "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" || \
        fail 'IP writer mutated before foreign-collision refusal'
)
pass "all public writers reject foreign collisions before their first mutation"

(
    reset_case delete-boundary-swap
    seed_all_supported_sites
    first_link="$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
    swapped_link="$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
    unlink() {
        local target="${*: -1}"
        command unlink "$@" || return $?
        if [ "$target" = "$first_link" ]; then
            command unlink "$swapped_link"
            printf '%s\n' foreign-mid-delete > "$swapped_link"
            chmod 644 "$swapped_link"
        fi
    }
    if nexus_remove_public_proxy; then
        fail 'mid-delete foreign swap was accepted'
    else
        remove_status=$?
    fi
    [ "$remove_status" -eq 2 ] && [ -f "$swapped_link" ] && \
        grep -Fxq foreign-mid-delete "$swapped_link" || \
        fail 'mid-delete foreign swap was not preserved'
    [ -L "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf" ] || \
        fail 'delete continued past the swapped path'
)
pass "each delete boundary revalidates and stops on a mid-operation swap"

(
    reset_case publish-boundary-swap
    seed_all_supported_sites
    publish_target="${NEXUS_NGINX_SITE}.port"
    python3() {
        if [ "$#" -eq 3 ] && [ "${1:-}" = - ] && \
           [ "${3:-}" = "$publish_target" ]; then
            printf '%s\n' foreign-at-publish > "$publish_target"
            chmod 644 "$publish_target"
        fi
        command python3 "$@"
    }
    if nexus_write_nginx_custom_port new.example.com 20443; then
        fail 'writer accepted a collision created at publish boundary'
    fi
    grep -Fxq foreign-at-publish "$publish_target" || \
        fail 'no-clobber publisher did not preserve the boundary collision'
)
pass "writer publication never rename-overwrites a boundary collision"

if (
    reset_case atomic-publish-crash-window
    ln() {
        local argument=""
        for argument in "$@"; do
            [ "$argument" != -s ] || {
                command ln "$@"
                return $?
            }
        done
        kill -KILL "$BASHPID"
    }
    nexus_write_nginx_site panel.example.com 18443 || exit 1
    [ "$(stat -c %h "$NEXUS_NGINX_SITE")" -eq 1 ] || exit 1
    if compgen -G "$NEXUS_NGINX_AVAILABLE_DIR/.rr-nexus.??????" >/dev/null; then
        exit 1
    fi
); then
    :
else
    fail 'candidate publication still used a crash-strandable hardlink window'
fi
pass "atomic no-replace publication cannot strand an nlink=2 generation"

reset_case atomic-publish-retry
set +e
(
    python3() {
        if [ "$#" -eq 3 ] && [ "${1:-}" = - ] && \
           [ "${3:-}" = "$NEXUS_NGINX_SITE" ]; then
            kill -KILL "$BASHPID"
        fi
        command python3 "$@"
    }
    nexus_write_nginx_site panel.example.com 18443
) >/dev/null 2>&1
crash_status=$?
set -e
[ "$crash_status" -eq 137 ] || fail 'pre-rename crash injection did not SIGKILL'
[ ! -e "$NEXUS_NGINX_SITE" ] && [ ! -L "$NEXUS_NGINX_SITE" ] || \
    fail 'pre-rename SIGKILL published a partial managed target'
nexus_write_nginx_site panel.example.com 18443 || \
    fail 'writer could not retry after pre-rename SIGKILL'
[ "$(stat -c %h "$NEXUS_NGINX_SITE")" -eq 1 ] && \
    nexus_nginx_managed_paths_are_owned || \
    fail 'retry did not converge to one exact target generation'
pass "SIGKILL before atomic rename remains retryable and converges to nlink=1"

reset_case foreign-hardlink
seed_all_supported_sites
ln "$NEXUS_NGINX_SITE" "$CASE_ROOT/foreign-hardlink"
if nexus_nginx_managed_paths_are_owned; then
    fail 'foreign hardlink was accepted as exact managed metadata'
fi
if nexus_remove_public_proxy; then
    fail 'remove deleted a managed name with a foreign hardlink peer'
else
    remove_status=$?
fi
[ "$remove_status" -eq 2 ] && [ -f "$NEXUS_NGINX_SITE" ] && \
    [ -f "$CASE_ROOT/foreign-hardlink" ] || \
    fail 'foreign hardlink refusal did not preserve both names'
pass "foreign hardlinks are never adopted as RR ownership"

reset_case writable-ancestor
seed_all_supported_sites
chmod 0777 "$CASE_ROOT"
if nexus_remove_public_proxy; then
    fail 'world-writable managed ancestor was accepted'
else
    remove_status=$?
fi
[ "$remove_status" -eq 2 ] && [ -L "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf" ] || \
    fail 'unsafe ancestor refusal mutated a managed path'
chmod 0755 "$CASE_ROOT"
pass "ownership proof rejects a writable intermediate ancestor"

(
    reset_case ancestor-mid-delete-swap
    seed_all_supported_sites
    first_link="$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
    enabled_real="${NEXUS_NGINX_ENABLED_DIR}.real"
    unlink() {
        local target="${*: -1}"
        command unlink "$@" || return $?
        if [ "$target" = "$first_link" ]; then
            command mv "$NEXUS_NGINX_ENABLED_DIR" "$enabled_real"
            command ln -s "$enabled_real" "$NEXUS_NGINX_ENABLED_DIR"
        fi
    }
    if nexus_remove_public_proxy; then
        fail 'mid-delete ancestor symlink exchange was accepted'
    else
        remove_status=$?
    fi
    [ "$remove_status" -eq 2 ] && \
        [ -L "$NEXUS_NGINX_ENABLED_DIR" ] && \
        [ -L "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" ] || \
        fail 'ancestor exchange was not detected before the next deletion'
)
pass "ancestor chain is re-proved after a mid-delete symlink exchange"

printf '1..%d\n' "$pass_count"
