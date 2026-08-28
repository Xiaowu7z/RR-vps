#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

RR_LIB_DIR="$ROOT_DIR"
RR_REPOSITORY="example/rr-vps"
# shellcheck source=../modules/85-nexus.sh
source "$ROOT_DIR/modules/85-nexus.sh"

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
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
bootstrap_acme = location(http_bootstrap, r"location /\.well-known/acme-challenge/")
assert "root /var/www/rr-nexus-certbot;" in bootstrap_acme
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
printf '%s\n' old-target > "${NEXUS_NGINX_SITE}.port"
printf '%s\n' old-bootstrap > "$NEXUS_NGINX_SITE"
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
printf '%s\n' old-target > "${NEXUS_NGINX_SITE}.port"
printf '%s\n' old-bootstrap > "$NEXUS_NGINX_SITE"
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

printf '1..%d\n' "$pass_count"
