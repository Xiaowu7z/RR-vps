#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

load_modules_for_tests() {
    local runtime_constants=""
    local module_file=""
    # Load the production constants without executing the root-only runtime
    # gate.  GitHub Actions deliberately runs validation as an unprivileged
    # user; the real rr/install entrypoints still source the complete file.
    runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
    eval "$runtime_constants"
    for module_file in modules/*.sh; do
        [ "$module_file" = "modules/00-runtime.sh" ] && continue
        # shellcheck disable=SC1090
        source "$module_file"
    done
}

echo "[1/13] Bash and Python syntax"
bash -n install.sh rr modules/*.sh scripts/*.sh
find nexus -type f -name '*.py' -print0 | xargs -0 python3 -m py_compile
python3 -m py_compile scripts/rebuild-bundle.py scripts/update-external-state.py
if command -v node >/dev/null 2>&1; then
    node --check nexus/static/app.js
    node --check nexus/static/admin.js
fi

echo "[2/13] Combined module loading"
bash -c '
    for module_file in modules/*.sh; do
        [ "$module_file" = "modules/00-runtime.sh" ] && continue
        source "$module_file"
    done
    for required_function in \
        main_menu install_main do_update post_update_migrate \
        ensure_runtime_health rr_run_health_check generate_node_and_sub protocol_menu uninstall_all \
        nexus_menu sync_nexus_devices nexus_protocol_users; do
        declare -F "$required_function" >/dev/null || {
            echo "Missing function: $required_function" >&2
            exit 1
        }
    done
'

echo "[3/13] Fresh-install port selection regression"
(
    load_modules_for_tests
    PORT=0
    SUB_PORT=0
    VL_PORT=0
    AN_PORT=0
    HY2_PORT=0
    TU5_PORT=0

    tcp_port_in_use() { return 1; }
    udp_port_in_use() { return 1; }
    initial_port_available 23456 tcp
    initial_port_available 23457 udp

    PORT=23456
    if initial_port_available 23456 tcp; then
        echo "Already allocated TCP port was accepted." >&2
        exit 1
    fi
    PORT=0
    tcp_port_in_use() { return 0; }
    if initial_port_available 23458 tcp; then
        echo "Occupied TCP port was accepted." >&2
        exit 1
    fi

    tcp_port_in_use() { return 1; }
    selected_port=""
    prompt_initial_port selected_port "回归测试" tcp <<< ""
    is_valid_port "$selected_port"

    # Naive 首装必须能接受真实域名。函数缺失会被 Bash 当作 127，导致
    # 安装向导把每次输入都判为无效并无限等待。
    is_valid_domain naive.example.com
    is_valid_domain A-b.example.co.uk
    is_valid_domain xn--fsqu00a.xn--0zwm56d
    for invalid_domain in '' localhost 203.0.113.1 .example.com example.com. \
        bad_label.example.com bad..example.com -bad.example.com bad_.example.com; do
        if is_valid_domain "$invalid_domain"; then
            echo "Invalid Naive domain was accepted: $invalid_domain" >&2
            exit 1
        fi
    done
)

# 安装依赖不能为了持久化 RR 的 iptables 规则而删除用户已有的 UFW。
# 用模拟 apt 验证两个分支，避免测试本身改动 CI 主机的软件包。
(
    load_modules_for_tests
    apt_log=$(mktemp)
    trap 'rm -f "$apt_log"' EXIT
    apt-get() { printf '%s\n' "$*" >> "$apt_log"; }
    debconf-set-selections() { :; }
    systemctl() { :; }
    vnstat() { :; }
    modprobe() { :; }
    sysctl() {
        [ "${1:-}" = -n ] && printf '%s\n' cubic
        return 0
    }

    rr_ufw_installed() { return 0; }
    install_deps >/dev/null
    if grep -q 'iptables-persistent' "$apt_log"; then
        echo "Existing UFW would be replaced by iptables-persistent." >&2
        exit 1
    fi

    : > "$apt_log"
    rr_ufw_installed() { return 1; }
    install_deps >/dev/null
    grep -q 'install -y iptables-persistent' "$apt_log" || {
        echo "No firewall persistence backend was installed without UFW." >&2
        exit 1
    }
)

# Naive 首装证书必须先真正启动 ACME Webroot，再调用 certbot；同时不得
# 为签证书强杀占用 80 端口的其他服务。
(
    load_modules_for_tests
    naive_root=$(mktemp -d)
    trap 'rm -rf "$naive_root"' EXIT
    RR_NAIVE_ACME_WEBROOT="$naive_root/webroot"
    RR_NAIVE_ACME_NGINX_SITE="$naive_root/sites-available/rr-naive-acme.conf"
    RR_NAIVE_ACME_NGINX_ENABLED="$naive_root/sites-enabled/rr-naive-acme.conf"
    RR_LE_LIVE_ROOT="$naive_root/letsencrypt/live"
    RR_NAIVE_CERT_DIR="$naive_root/certs"
    call_log="$naive_root/calls"
    : > "$call_log"

    tcp_port_in_use() { return 1; }
    nginx() {
        [ "${1:-}" = -t ] || return 1
        printf '%s\n' nginx-test >> "$call_log"
    }
    certbot() {
        printf 'certbot:%s\n' "$*" >> "$call_log"
        mkdir -p "$RR_LE_LIVE_ROOT/naive.example.com"
        printf '%s\n' certificate > "$RR_LE_LIVE_ROOT/naive.example.com/fullchain.pem"
        printf '%s\n' private-key > "$RR_LE_LIVE_ROOT/naive.example.com/privkey.pem"
    }
    openssl() {
        case "$*" in
            *'-checkend '*) return 0 ;;
            *'-pubkey -noout'*) printf '%s\n' 'PUBLIC KEY' ;;
            *'pkey '*' -pubout'*) printf '%s\n' 'PUBLIC KEY' ;;
            *) return 1 ;;
        esac
    }
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    certificate_chain_is_trusted() { return 0; }
    rr_certbot_webroot_lineage_is_renewable() {
        printf 'lineage:%s\n' "$1" >> "$call_log"
        return 0
    }
    rr_enable_certbot_renewal_runtime() {
        [ "${1:-}" = naive.example.com ] || return 1
        printf 'renewal-runtime:%s\n' "$1" >> "$call_log"
        return 0
    }
    systemctl() {
        if [ "${1:-}" = is-active ]; then
            return 1
        fi
        printf 'systemctl:%s\n' "$*" >> "$call_log"
    }
    open_protocol_firewall() { printf 'firewall:%s:%s\n' "$1" "$2" >> "$call_log"; }
    deploy_naive_cert_hook() { printf '%s\n' deploy-hook >> "$call_log"; }

    ensure_naive_certificate naive.example.com ""
    [ -L "$RR_NAIVE_ACME_NGINX_ENABLED" ]
    grep -Fq 'server_name naive.example.com;' "$RR_NAIVE_ACME_NGINX_SITE"
    grep -Fq "root $RR_NAIVE_ACME_WEBROOT;" "$RR_NAIVE_ACME_NGINX_SITE"
    grep -Fq 'systemctl:enable --now nginx' "$call_log"
    grep -Fq 'firewall:80:tcp' "$call_log"
    [ $(( 8#$(stat -c %a "$(dirname "$RR_NAIVE_ACME_WEBROOT")") & 1 )) -eq 1 ]
    certbot_line=$(grep -n '^certbot:' "$call_log" | cut -d: -f1)
    lineage_line=$(grep -n '^lineage:naive.example.com$' "$call_log" | tail -1 | cut -d: -f1)
    runtime_line=$(grep -n '^renewal-runtime:naive\.example\.com$' "$call_log" | cut -d: -f1)
    deploy_line=$(grep -n '^deploy-hook$' "$call_log" | cut -d: -f1)
    firewall_line=$(grep -n '^firewall:80:tcp$' "$call_log" | cut -d: -f1)
    [ "$firewall_line" -lt "$certbot_line" ]
    grep -Eq '^certbot:.*--cert-name naive\.example\.com([[:space:]]|$)' "$call_log"
    [ "$certbot_line" -lt "$lineage_line" ]
    [ "$lineage_line" -lt "$runtime_line" ]
    [ "$runtime_line" -lt "$deploy_line" ]
    [ "$(stat -c %a "$RR_NAIVE_CERT_DIR/fullchain.pem")" = 600 ]
    [ "$(stat -c %a "$RR_NAIVE_CERT_DIR/privkey.pem")" = 600 ]

    conflict_root="$naive_root/conflict"
    RR_NAIVE_ACME_WEBROOT="$conflict_root/webroot"
    RR_NAIVE_ACME_NGINX_SITE="$conflict_root/sites-available/rr-naive-acme.conf"
    RR_NAIVE_ACME_NGINX_ENABLED="$conflict_root/sites-enabled/rr-naive-acme.conf"
    tcp_port_in_use() { return 0; }
    ss() { printf '%s\n' 'LISTEN 0 511 0.0.0.0:80 users:(("apache2",pid=1,fd=3))'; }
    if prepare_naive_acme_webroot naive.example.com; then
        echo "Naive ACME setup accepted port 80 owned by a non-Nginx service." >&2
        exit 1
    fi
    [ ! -e "$RR_NAIVE_ACME_NGINX_SITE" ]
)

# NaiveProxy 和订阅 HTTPS 采用同一信任边界：SAN、期限和私钥都匹配仍
# 不足以接受自签叶子证书，必须能锚定目标机信任的 CA。
(
    load_modules_for_tests
    cert_root=$(mktemp -d)
    trap 'rm -rf "$cert_root"' EXIT
    RR_CA_BUNDLE="$cert_root/ca.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj '/CN=RR Naive validation CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$cert_root/ca.key" -out "$RR_CA_BUNDLE" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -subj '/CN=naive.example.test' \
        -addext 'subjectAltName=DNS:naive.example.test' \
        -keyout "$cert_root/trusted.key" -out "$cert_root/trusted.csr" >/dev/null 2>&1
    openssl x509 -req -days 30 -in "$cert_root/trusted.csr" \
        -CA "$RR_CA_BUNDLE" -CAkey "$cert_root/ca.key" \
        -CAserial "$cert_root/ca.srl" -CAcreateserial -copy_extensions copy \
        -out "$cert_root/trusted.crt" >/dev/null 2>&1
    naive_certificate_pair_valid "$cert_root/trusted.crt" \
        "$cert_root/trusted.key" naive.example.test

    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj '/CN=naive.example.test' \
        -addext 'subjectAltName=DNS:naive.example.test' \
        -keyout "$cert_root/self-signed.key" \
        -out "$cert_root/self-signed.crt" >/dev/null 2>&1
    if naive_certificate_pair_valid "$cert_root/self-signed.crt" \
        "$cert_root/self-signed.key" naive.example.test; then
        echo "Naive certificate validation accepted a matching self-signed leaf." >&2
        exit 1
    fi
)

# A trusted hand-copied leaf is not a renewable Certbot lineage.  Keep the
# proof on every reuse/update path and pin new issuance to the requested name.
python3 - <<'PY'
from pathlib import Path

config = Path("modules/20-config.sh").read_text(encoding="utf-8")
singbox = Path("modules/30-singbox.sh").read_text(encoding="utf-8")
nexus = Path("modules/85-nexus.sh").read_text(encoding="utf-8")
update = Path("modules/60-update.sh").read_text(encoding="utf-8")
installer = Path("modules/95-install.sh").read_text(encoding="utf-8")
hook_script = Path("scripts/naive-cert-hook.sh").read_text(encoding="utf-8")

validator = config[
    config.index("rr_certbot_webroot_lineage_is_renewable() {"):
    config.index("\ndeploy_subscription_cert_hook() {")
]
for token in (
    "https://acme-v02.api.letsencrypt.org/directory",
    "live member is not a root-owned symlink",
    "mixed archive generations",
    "private_key.json",
    "regr.json",
    "meta.json",
    "webroot_map",
    "authenticator",
    "acme_renewal_info",
    "parse_certificate_pem",
    "MAX_CERTIFICATES = 16",
    "verify_direct_issuer",
    "pass_fds=(child_fd, issuer_fd)",
    "fullchain.pem is not the exact cert.pem plus chain.pem",
    "leaf certificate SAN policy is not exact",
    '["pkey", "-check", "-noout", "-passin", "pass:"]',
    "privkey.pem does not match cert.pem",
    "jwk_integer",
    "account RSA key has invalid CRT parameters",
    '"pkey", "-inform", "DER", "-check", "-noout"',
    "renewal account id does not match the account JWK",
    "usedforsecurity=False",
    "secret file is accessible by group/other",
):
    assert token in validator

subscription = config[config.index("start_subscription_server() {"):]
pair = subscription.index("subscription_certificate_pair_valid")
lineage = subscription.index(
    'rr_certbot_webroot_lineage_is_renewable "$SUB_DOMAIN"', pair
)
runtime = subscription.index("rr_certbot_renewal_runtime_is_ready", lineage)
hook = subscription.index("rr_certificate_deploy_hook_is_current", runtime)
assert pair < lineage < runtime < hook
assert 'rr_certbot_renewal_runtime_is_ready "$SUB_DOMAIN"' in subscription[runtime:hook]

ensure = singbox[
    singbox.index("ensure_naive_certificate() {"):
    singbox.index("\nrr_certificate_deploy_hook_is_current() {")
]
update_pair = ensure.index("if ! naive_certificate_pair_valid")
update_lineage = ensure.index(
    'rr_certbot_webroot_lineage_is_renewable "$naive_domain"', update_pair
)
update_runtime = ensure.index("rr_certbot_renewal_runtime_is_ready", update_lineage)
assert 'rr_certbot_renewal_runtime_is_ready "$naive_domain"' in ensure[
    update_runtime:update_runtime + 256
]
update_sync = ensure.index("sync_naive_certificate_pair", update_runtime)
reuse_pair = ensure.index("if naive_certificate_pair_valid", update_sync)
reuse_lineage = ensure.index(
    'rr_certbot_webroot_lineage_is_renewable "$naive_domain"', reuse_pair
)
certbot = ensure.index("certbot certonly", reuse_lineage)
assert '--cert-name "$naive_domain"' in ensure[certbot:]
post_pair = ensure.index("naive_certificate_pair_valid", certbot)
post_lineage = ensure.index(
    'rr_certbot_webroot_lineage_is_renewable "$naive_domain"', post_pair
)
post_runtime = ensure.index("rr_enable_certbot_renewal_runtime", post_lineage)
assert 'rr_enable_certbot_renewal_runtime "$naive_domain"' in ensure[
    post_runtime:post_runtime + 256
]
post_sync = ensure.index("sync_naive_certificate_pair", post_runtime)
assert update_pair < update_lineage < update_runtime < update_sync < reuse_pair < reuse_lineage
assert certbot < post_pair < post_lineage < post_sync

post_update = update[
    update.index("post_update_migrate() {"):
    update.index("\nensure_runtime_health() {")
]
naive_branch = post_update[post_update.index('if [ "${NAIVE_ENABLED:-false}" = true ]; then'):]
assert 'ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL" || return 1' in naive_branch
assert "deploy_naive_cert_hook || return 1" not in naive_branch.split("fi", 1)[0]

enable = nexus[
    nexus.index("nexus_enable_public_https() {"):
    nexus.index("\nnexus_remove_public_proxy() {")
]
nexus_certbot = enable.index("certbot certonly")
assert '--cert-name "$domain"' in enable[nexus_certbot:]
nexus_pair = enable.index("subscription_certificate_pair_valid", nexus_certbot)
nexus_lineage = enable.index(
    'rr_certbot_webroot_lineage_is_renewable "$domain"', nexus_pair
)
nexus_hook = enable.index("nexus_certificate_deploy_hook_is_ready", nexus_lineage)
nexus_runtime = enable.index("rr_enable_certbot_renewal_runtime", nexus_hook)
assert nexus_certbot < nexus_pair < nexus_lineage < nexus_hook < nexus_runtime
assert 'rr_enable_certbot_renewal_runtime "$domain"' in enable[
    nexus_runtime:nexus_runtime + 256
]
nexus_final_runtime = enable.index(
    'rr_certbot_renewal_runtime_is_ready "$domain"', nexus_runtime
)
assert enable.index("systemctl reload nginx", nexus_runtime) < nexus_final_runtime

reconcile = nexus[
    nexus.index("nexus_reconcile_public_proxy() {"):
    nexus.index("\nnexus_public_proxy_health_check() {")
]
reconcile_pair = reconcile.index("subscription_certificate_pair_valid")
reconcile_lineage = reconcile.index(
    'rr_certbot_webroot_lineage_is_renewable "$domain"', reconcile_pair
)
reconcile_hook = reconcile.index("nexus_certificate_deploy_hook_is_ready", reconcile_lineage)
reconcile_http = reconcile.index(
    "nexus_firewall_open_accounted 80 tcp http_created", reconcile_hook
)
reconcile_panel = reconcile.index(
    'nexus_firewall_open_accounted "$port" tcp panel_created', reconcile_http
)
reconcile_runtime = reconcile.index(
    'rr_certbot_renewal_runtime_is_ready "$domain"', reconcile_hook
)
assert reconcile_pair < reconcile_lineage < reconcile_hook
assert reconcile_hook < reconcile_http < reconcile_panel < reconcile_runtime

for token in (
    'NEXUS_CONFIG_FILE="${RR_CERT_HOOK_NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}"',
    'certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem"',
    'openssl pkey -in "$private_key" -check -noout -passin pass:',
    '"$NGINX_BIN" -t',
    '"$NGINX_BIN" -s reload',
):
    assert token in hook_script
nexus_reload = hook_script[
    hook_script.index("reload_nexus_certificate() {"):
    hook_script.index("\n# One renewed lineage can serve several RR consumers.")
]
assert nexus_reload.index("certificate_pair_valid") < nexus_reload.index('"$NGINX_BIN" -t')
assert nexus_reload.count('"$NGINX_BIN" -s reload') == 1
aggregate = hook_script[hook_script.index("hook_failed=0"):]
assert 'deploy_naive_certificate || hook_failed=1' in aggregate
assert 'refresh_subscription_certificate || hook_failed=1' in aggregate
assert 'reload_nexus_certificate || hook_failed=1' in aggregate
assert 'return "$hook_failed"' in aggregate

repair = installer[
    installer.index("_install_repair_existing() {"):
    installer.index("\n_install_prompt_identity() {")
]
repair_cert = repair[repair.index('if [ "$NAIVE_ENABLED" = "true" ]; then'):]
assert "ensure_naive_certificate" in repair_cert
assert "return 1" in repair_cert[:repair_cert.index("\n    fi")]
PY

# IP 直连模式只能切换 RR 自己的 Nginx 站点。发行版 default 和用户站点
# 必须原样保留；nginx -t 失败时还必须恢复旧 RR 配置及 unit 状态。
run_nexus_ip_nginx_case() (
    local case_name="$1"
    local nginx_test_rc="$2"
    local expect_success="$3"
    local update_transaction="${4:-0}"
    local cert_mode="${5:-644}"
    local key_mode="${6:-600}"
    local cert_identity_before=""
    local key_identity_before=""
    local fixture_stat_bin=""
    local original_cert_address="192.0.2.11"
    load_modules_for_tests
    nexus_nginx_tmp=$(mktemp -d)
    trap 'rm -rf "$nexus_nginx_tmp"' EXIT
    # The fixture lives below the shared /tmp parent.  Bind the ownership
    # proof to this private root, matching the dedicated Nginx tests, rather
    # than weakening the production default trust root (/).
    NEXUS_NGINX_TRUST_ROOT="$nexus_nginx_tmp"
    NEXUS_NGINX_AVAILABLE_DIR="$nexus_nginx_tmp/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$nexus_nginx_tmp/sites-enabled"
    NEXUS_CERT_DIR="$nexus_nginx_tmp/certs"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    NEXUS_IP_CERT_GATE_SCRIPT="$nexus_nginx_tmp/runtime/nexus-ip-cert-gate"
    NEXUS_IP_CERT_GATE_DROPIN="$nexus_nginx_tmp/systemd/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf"
    NEXUS_RESTORE_GATE_DROPIN="$nexus_nginx_tmp/systemd/nginx.service.d/zzzz-rr-restore-gate.conf"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$NEXUS_CERT_DIR" "$nexus_nginx_tmp/before"

    [ "$update_transaction" != 1 ] || original_cert_address="192.0.2.10"
    printf '%s\n' 'distro default' > "$NEXUS_NGINX_AVAILABLE_DIR/default"
    printf '%s\n' 'user site' > "$NEXUS_NGINX_AVAILABLE_DIR/unrelated.conf"
    nexus_emit_nginx_domain_http_site_v711 old.example.com > "$NEXUS_NGINX_SITE"
    nexus_emit_nginx_domain_custom_site old.example.com 19443 \
        /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
    nexus_emit_nginx_ip_site "$original_cert_address" 19443 \
        legacy-self-signed true > "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    command openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
        -keyout "$NEXUS_CERT_DIR/ip.key" -out "$NEXUS_CERT_DIR/ip.crt" \
        -subj "/CN=${original_cert_address}" \
        -addext "subjectAltName=IP:${original_cert_address}" >/dev/null 2>&1
    chmod "$cert_mode" "$NEXUS_CERT_DIR/ip.crt"
    chmod "$key_mode" "$NEXUS_CERT_DIR/ip.key"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/default" "$NEXUS_NGINX_ENABLED_DIR/default"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/unrelated.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/unrelated.conf"
    ln -s "$NEXUS_NGINX_SITE" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
    ln -s "${NEXUS_NGINX_SITE}.port" "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
    cp -a "$NEXUS_NGINX_AVAILABLE_DIR/default" \
        "$NEXUS_NGINX_AVAILABLE_DIR/unrelated.conf" "$NEXUS_NGINX_SITE" \
        "${NEXUS_NGINX_SITE}.port" "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_CERT_DIR/ip.crt" "$NEXUS_CERT_DIR/ip.key" "$nexus_nginx_tmp/before/"

    nginx_active=true
    nginx_enabled=false
    nexus_firewall_state=closed
    [ "$update_transaction" != 1 ] && [ "$expect_success" = true ] && nginx_active=false
    RR_UPDATE_TRANSACTION="$update_transaction"
    apt-get() { :; }
    nginx() {
        [ "${1:-}" = -t ] || return 1
        return "$nginx_test_rc"
    }
    systemctl() {
        case "${1:-}" in
            daemon-reload) return 0 ;;
            show)
                case "$*" in
                    'show nginx.service --property=LoadState --value')
                        printf '%s\n' loaded
                        ;;
                    'show nginx.service --property=DropInPaths --value')
                        printf '%s\n' "$NEXUS_IP_CERT_GATE_DROPIN"
                        ;;
                    'show nginx.service --property=ExecCondition --value')
                        printf '{ path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n' \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" \
                            "$NEXUS_CERT_DIR/ip.crt" \
                            "$NEXUS_CERT_DIR/ip.key" \
                            "$NEXUS_CERT_DIR/.ip-cert-pending"
                        ;;
                    *) return 1 ;;
                esac
                ;;
            is-active) [ "$nginx_active" = true ] ;;
            is-enabled) [ "$nginx_enabled" = true ] ;;
            enable)
                nginx_enabled=true
                if [ "${2:-}" = --now ]; then
                    nginx_active=true
                fi
                ;;
            disable) nginx_enabled=false ;;
            start|restart) nginx_active=true ;;
            stop) nginx_active=false ;;
            reload) [ "$nginx_active" = true ] ;;
            *) return 1 ;;
        esac
    }
    rr_validate_protocol_firewall() {
        [ "$1" = 18443 ] && [ "$2" = tcp ] && \
            [ "$nexus_firewall_state" = "$3" ]
    }
    open_protocol_firewall() { nexus_firewall_state=open; }
    close_protocol_firewall() { nexus_firewall_state=closed; }
    rr_firewall_protocol_tuple_needed_after_updates() { return 1; }
    # A regression fixture must never arm the host-wide emergency quarantine.
    # Negative cases assert the fail-closed status without mutating real paths.
    nexus_firewall_fail_closed() { return 3; }
    if [ "$update_transaction" = 1 ]; then
        # The production contract is root:root, while pre-push validation may
        # run as an unprivileged developer.  Map only these private fixtures'
        # uid/gid fields; preserve their real type, inode, mode, and link count.
        fixture_stat_bin=$(type -P stat)
        stat() {
            local target="${!#}" value="" device="" inode="" mode="" links=""
            if [ "$target" = "$NEXUS_CERT_DIR/ip.crt" ] || \
               [ "$target" = "$NEXUS_CERT_DIR/ip.key" ]; then
                case "${2:-}" in
                    '%u:%g:%a:%h')
                        value=$("$fixture_stat_bin" "$@") || return 1
                        IFS=: read -r _ _ mode links <<< "$value"
                        printf '0:0:%s:%s\n' "$mode" "$links"
                        return
                        ;;
                    '%d:%i:%u:%g:%a:%h')
                        value=$("$fixture_stat_bin" "$@") || return 1
                        IFS=: read -r device inode _ _ mode links <<< "$value"
                        printf '%s:%s:0:0:%s:%s\n' "$device" "$inode" "$mode" "$links"
                        return
                        ;;
                esac
            fi
            "$fixture_stat_bin" "$@"
        }
        certificate_identity_matches() { return 0; }
        certificate_private_key_matches() { return 0; }
        cert_identity_before=$(stat -c '%d:%i:%u:%g:%a:%h' "$NEXUS_CERT_DIR/ip.crt")
        key_identity_before=$(stat -c '%d:%i:%u:%g:%a:%h' "$NEXUS_CERT_DIR/ip.key")
    fi

    if [ "$expect_success" = true ]; then
        nexus_enable_public_ip_https 192.0.2.10 18443
        [ "$nginx_active" = true ]
        if [ "$update_transaction" = 1 ]; then
            [ "$nginx_enabled" = false ]
            [ "$(stat -c %a "$NEXUS_CERT_DIR/ip.crt")" = "$cert_mode" ]
            [ "$(stat -c %a "$NEXUS_CERT_DIR/ip.key")" = "$key_mode" ]
            [ "$(stat -c '%d:%i:%u:%g:%a:%h' "$NEXUS_CERT_DIR/ip.crt")" = \
                "$cert_identity_before" ]
            [ "$(stat -c '%d:%i:%u:%g:%a:%h' "$NEXUS_CERT_DIR/ip.key")" = \
                "$key_identity_before" ]
        else
            [ "$nginx_enabled" = true ]
        fi
        [ ! -e "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf" ]
        [ ! -e "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf" ]
        [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf")" = \
            "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" ]
        grep -Fq 'listen 18443 ssl;' "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
        grep -Fq 'location ^~ /sub/' "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
        grep -Fq 'location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$' \
            "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
        [ "$(grep -Fc 'error_log /dev/null crit;' \
            "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf")" -ge 3 ]
    else
        if nexus_enable_public_ip_https 192.0.2.10 18443; then
            echo "A failed Nginx validation was reported as a successful Nexus switch." >&2
            exit 1
        fi
        [ "$nginx_active" = true ] && [ "$nginx_enabled" = false ]
        cmp -s "$nexus_nginx_tmp/before/rr-nexus-ip.conf" \
            "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
        cmp -s "$nexus_nginx_tmp/before/ip.crt" "$NEXUS_CERT_DIR/ip.crt"
        cmp -s "$nexus_nginx_tmp/before/ip.key" "$NEXUS_CERT_DIR/ip.key"
        [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf")" = "$NEXUS_NGINX_SITE" ]
        [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf")" = \
            "${NEXUS_NGINX_SITE}.port" ]
        [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf")" = \
            "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" ]
    fi

    # These are deliberately outside the RR namespace and must be byte- and
    # link-identical on both commit and rollback paths.
    cmp -s "$nexus_nginx_tmp/before/default" "$NEXUS_NGINX_AVAILABLE_DIR/default"
    cmp -s "$nexus_nginx_tmp/before/unrelated.conf" \
        "$NEXUS_NGINX_AVAILABLE_DIR/unrelated.conf"
    cmp -s "$nexus_nginx_tmp/before/rr-nexus.conf" "$NEXUS_NGINX_SITE"
    cmp -s "$nexus_nginx_tmp/before/rr-nexus.conf.port" "${NEXUS_NGINX_SITE}.port"
    [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/default")" = \
        "$NEXUS_NGINX_AVAILABLE_DIR/default" ]
    [ "$(readlink "$NEXUS_NGINX_ENABLED_DIR/unrelated.conf")" = \
        "$NEXUS_NGINX_AVAILABLE_DIR/unrelated.conf" ]
)
run_nexus_ip_nginx_case success 0 true
run_nexus_ip_nginx_case nginx-test-failure 1 false
run_nexus_ip_nginx_case legacy-0600-update 0 true 1 600 600
run_nexus_ip_nginx_case current-0644-update 0 true 1 644 600
run_nexus_ip_nginx_case unsafe-cert-mode 0 false 1 640 600
run_nexus_ip_nginx_case unsafe-key-mode 0 false 1 644 644

# 更新候选只能复用 root 所有的普通单链接证书文件。证书兼容 7.1.0
# 的 0600 与当前 0644；私钥始终只能是 0600。
(
    load_modules_for_tests
    certificate_root=$(mktemp -d)
    trap 'rm -rf "$certificate_root"' EXIT
    cert="$certificate_root/ip.crt"
    key="$certificate_root/ip.key"
    real_stat_bin=$(type -P stat)
    mocked_nonroot=""

    stat() {
        local target="${!#}" value="" mode="" links=""
        if { [ "$target" = "$cert" ] || [ "$target" = "$key" ]; } && \
           [ "${2:-}" = '%u:%g:%a:%h' ]; then
            value=$("$real_stat_bin" "$@") || return 1
            IFS=: read -r _ _ mode links <<< "$value"
            if [ "$target" = "$mocked_nonroot" ]; then
                printf '65534:65534:%s:%s\n' "$mode" "$links"
            else
                printf '0:0:%s:%s\n' "$mode" "$links"
            fi
            return
        fi
        "$real_stat_bin" "$@"
    }

    make_safe_pair() {
        rm -f -- "$cert" "$key" "$certificate_root/extra-link" \
            "$certificate_root/cert-target" "$certificate_root/key-target"
        printf '%s\n' certificate > "$cert"
        printf '%s\n' private-key > "$key"
        chmod 644 "$cert"
        chmod 600 "$key"
    }

    make_safe_pair
    nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    chmod 600 "$cert"
    nexus_update_ip_certificate_files_are_safe "$cert" "$key"

    chmod 640 "$cert"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    chmod 644 "$key"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    ln "$cert" "$certificate_root/extra-link"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    mv "$cert" "$certificate_root/cert-target"
    ln -s "$certificate_root/cert-target" "$cert"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    ln "$key" "$certificate_root/extra-link"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    mv "$key" "$certificate_root/key-target"
    ln -s "$certificate_root/key-target" "$key"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    rm -f -- "$cert"
    mkfifo "$cert"
    chmod 644 "$cert"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    rm -f -- "$key"
    mkfifo "$key"
    chmod 600 "$key"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    make_safe_pair
    mocked_nonroot="$cert"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    mocked_nonroot="$key"
    ! nexus_update_ip_certificate_files_are_safe "$cert" "$key"
    unset -f stat
)

# 更新/回滚后的订阅 worker 可能没有 PID 文件，旧目录也可能已经被删除。
# 进程回收必须同时证明 root UID、精确 argv，以及 live cwd 或内核可证明的
# deleted cwd；不能广泛 pkill、仅信任状态文件或仅匹配“(deleted)”字符串。
(
    load_modules_for_tests
    subscription_test_root=$(mktemp -d)
    trap 'rm -rf "$subscription_test_root"' EXIT
    RR_PROC_ROOT="$subscription_test_root/proc"
    SUB_ROOT="$subscription_test_root/sub-root"
    mkdir -p "$RR_PROC_ROOT/1234" "$RR_PROC_ROOT/2345" "$RR_PROC_ROOT/3456" \
        "$RR_PROC_ROOT/4567" "$RR_PROC_ROOT/5678" "$RR_PROC_ROOT/6789" \
        "$RR_PROC_ROOT/7890" "$SUB_ROOT" "${SUB_ROOT} (deleted)" \
        "$subscription_test_root/other-root"
    for root_pid in 1234 2345 3456 5678 6789 7890; do
        printf 'Name:\tpython3\nUid:\t0\t0\t0\t0\n' > "$RR_PROC_ROOT/$root_pid/status"
    done
    printf 'Name:\tpython3\nUid:\t1000\t1000\t1000\t1000\n' > \
        "$RR_PROC_ROOT/4567/status"

    printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 > "$RR_PROC_ROOT/1234/cmdline"
    ln -s "$SUB_ROOT" "$RR_PROC_ROOT/1234/cwd"
    printf '%s\0' /usr/bin/python3.10 /usr/local/lib/rr/nexus/sub_server.py 18081 \
        > "$RR_PROC_ROOT/2345/cmdline"
    ln -s "${SUB_ROOT} (deleted)" "$RR_PROC_ROOT/2345/cwd"
    printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 \
        > "$RR_PROC_ROOT/3456/cmdline"
    ln -s "${SUB_ROOT} (deleted)" "$RR_PROC_ROOT/3456/cwd"
    printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 \
        > "$RR_PROC_ROOT/4567/cmdline"
    ln -s "${SUB_ROOT} (deleted)" "$RR_PROC_ROOT/4567/cwd"
    printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 > "$RR_PROC_ROOT/5678/cmdline"
    ln -s "$subscription_test_root/other-root" "$RR_PROC_ROOT/5678/cwd"
    printf '%s\0' python3 -c pass /usr/local/lib/rr/nexus/sub_server.py 18081 \
        > "$RR_PROC_ROOT/6789/cmdline"
    ln -s "$SUB_ROOT" "$RR_PROC_ROOT/6789/cwd"
    printf '%s\0' python3.10 -m http.server 18081 --bind 127.0.0.1 \
        > "$RR_PROC_ROOT/7890/cmdline"
    ln -s "${SUB_ROOT} (deleted)" "$RR_PROC_ROOT/7890/cwd"

    # Ordinary symlinks cannot model procfs' still-open unlinked inode.  Only
    # the marked fake proc entries report st_nlink=0; PID 3456 points at a real
    # literal directory named "sub-root (deleted)" and must remain excluded.
    stat() {
        local path="${!#}"
        if [ "${1:-}" = -Lc ] && [ "${2:-}" = %h ]; then
            case "$path" in
                "$RR_PROC_ROOT/2345/cwd"|"$RR_PROC_ROOT/4567/cwd"|"$RR_PROC_ROOT/7890/cwd")
                    printf '%s\n' 0
                    return 0
                    ;;
            esac
        fi
        command stat "$@"
    }
    : > "$subscription_test_root/killed"
    kill() {
        if [ "${1:-}" = -0 ]; then
            [ -d "$RR_PROC_ROOT/${2:-}" ]
            return
        fi
        printf '%s\n' "$1" >> "$subscription_test_root/killed"
        rm -rf "$RR_PROC_ROOT/$1"
    }

    [ "$(managed_subscription_pids)" = $'1234\n2345\n7890' ]
    subscription_server_running
    is_subscription_pid 2345
    ! is_subscription_pid 3456
    ! is_subscription_pid 4567
    ! is_subscription_pid 6789
    SUB_PID_FILE="$subscription_test_root/current.pid"
    SUB_BIND_STATE_FILE="$subscription_test_root/current.bind"
    : > "$SUB_PID_FILE"
    : > "$SUB_BIND_STATE_FILE"
    sleep() { :; }
    stop_subscription_servers
    [ "$(cat "$subscription_test_root/killed")" = $'1234\n2345\n7890' ]
    [ -d "$RR_PROC_ROOT/3456" ]
    [ -d "$RR_PROC_ROOT/4567" ]
    [ -d "$RR_PROC_ROOT/5678" ]
    [ -d "$RR_PROC_ROOT/6789" ]
    [ ! -e "$SUB_PID_FILE" ]
    [ ! -e "$SUB_BIND_STATE_FILE" ]
)

# 冻结安装器和独立恢复器不能依赖运行时模块，因此各自携带同一身份判定。
# 对两份真实函数运行同一 fixture，防止后续只修主模块而遗漏更新/回滚路径。
subscription_extract_function() {
    local source_file="$1" function_name="$2"
    awk -v signature="${function_name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$source_file"
}
for subscription_identity_source in scripts/install-core.sh scripts/update-recover.sh; do
    (
        eval "$(subscription_extract_function "$subscription_identity_source" \
            rr_subscription_process_matches)"
        eval "$(subscription_extract_function "$subscription_identity_source" \
            rr_subscription_pid_is_managed)"
        eval "$(subscription_extract_function "$subscription_identity_source" \
            rr_managed_subscription_pids)"

        identity_root=$(mktemp -d)
        trap 'rm -rf "$identity_root"' EXIT
        RR_PROC_ROOT="$identity_root/proc"
        RR_SUB_ROOT="$identity_root/sub-root"
        RR_LIB_DIR=/usr/local/lib/rr
        mkdir -p "$RR_PROC_ROOT/101" "$RR_PROC_ROOT/102" "$RR_PROC_ROOT/103" \
            "$RR_PROC_ROOT/104" "$RR_PROC_ROOT/105" "$RR_SUB_ROOT" \
            "${RR_SUB_ROOT} (deleted)"
        for root_pid in 101 102 104 105; do
            printf 'Name:\tpython3\nUid:\t0\t0\t0\t0\n' > "$RR_PROC_ROOT/$root_pid/status"
        done
        printf 'Name:\tpython3\nUid:\t1000\t1000\t1000\t1000\n' > \
            "$RR_PROC_ROOT/103/status"
        printf '%s\0' python3.10 /usr/local/lib/rr/nexus/sub_server.py 18081 \
            > "$RR_PROC_ROOT/101/cmdline"
        printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 \
            > "$RR_PROC_ROOT/102/cmdline"
        printf '%s\0' python3 /usr/local/lib/rr/nexus/sub_server.py 18081 \
            > "$RR_PROC_ROOT/103/cmdline"
        printf '%s\0' python3 -c pass /usr/local/lib/rr/nexus/sub_server.py 18081 \
            > "$RR_PROC_ROOT/104/cmdline"
        printf '%s\0' python3.10 -m http.server 18081 --bind 127.0.0.1 \
            > "$RR_PROC_ROOT/105/cmdline"
        for deleted_pid in 101 102 103; do
            ln -s "${RR_SUB_ROOT} (deleted)" "$RR_PROC_ROOT/$deleted_pid/cwd"
        done
        ln -s "$RR_SUB_ROOT" "$RR_PROC_ROOT/104/cwd"
        ln -s "$RR_SUB_ROOT" "$RR_PROC_ROOT/105/cwd"
        stat() {
            local path="${!#}"
            if [ "${1:-}" = -Lc ] && [ "${2:-}" = %h ] && \
               { [ "$path" = "$RR_PROC_ROOT/101/cwd" ] || \
                 [ "$path" = "$RR_PROC_ROOT/103/cwd" ]; }; then
                printf '%s\n' 0
                return 0
            fi
            command stat "$@"
        }
        [ "$(rr_managed_subscription_pids)" = $'101\n105' ] || {
            printf 'Subscription identity drift in %s.\n' \
                "$subscription_identity_source" >&2
            exit 1
        }
    )
done
unset -f subscription_extract_function

# Nexus 公网 IP 安装后的健康检查必须使用真实存在的地址构造函数，且
# IPv6 URL 必须带方括号。
(
    load_modules_for_tests
    nexus_url_root=$(mktemp -d)
    trap 'rm -rf "$nexus_url_root"' EXIT
    NEXUS_CONFIG_FILE="$nexus_url_root/nexus.json"
    printf '%s\n' '{"mode":"public","domain":"203.0.113.8","ssh_host":"203.0.113.8","public_port":10443}' > "$NEXUS_CONFIG_FILE"
    [ "$(nexus_panel_url)" = 'https://203.0.113.8:10443' ]
    printf '%s\n' '{"mode":"public","domain":"2001:db8::8","ssh_host":"2001:db8::8","public_port":10443}' > "$NEXUS_CONFIG_FILE"
    [ "$(nexus_panel_url)" = 'https://[2001:db8::8]:10443' ]
    printf '%s\n' '{"mode":"public","domain":"panel.example.com","ssh_host":"203.0.113.8","public_port":443}' > "$NEXUS_CONFIG_FILE"
    [ "$(nexus_panel_url)" = 'https://panel.example.com' ]
    if grep -q 'nexus_access_url' modules/85-nexus.sh; then
        echo "Nexus install still calls the nonexistent nexus_access_url helper." >&2
        exit 1
    fi
)

echo "[4/13] Fresh-install snapshot regression"
version_function=$(awk '
    /^rr_version_ge\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' install.sh)
(
    eval "$version_function"
    rr_version_ge 7.0.2 7.0.2
    rr_version_ge 7.0.3 7.0.2
    if rr_version_ge 7.0.1 7.0.2; then
        echo "Bootstrap downgrade comparison accepted an older version." >&2
        exit 1
    fi
)
snapshot_function=$(awk '
    /^rr_snapshot_runtime\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' scripts/install-core.sh)
install_snapshot_test_stubs() {
    rr_set_private_marker() {
        local target="$1"
        (umask 077; : > "$target") && chmod 600 "$target"
    }
    rr_write_transaction_format() { printf '2\n' > "$TX_DIR/transaction-format"; }
    rr_capture_update_writer_state() {
        RR_SINGBOX_WAS_ACTIVE=false
        RR_SINGBOX_WAS_ENABLED=false
        RR_NEXUS_WAS_ACTIVE=false
        RR_NEXUS_WAS_ENABLED=false
        RR_SUBSCRIPTION_WAS_ACTIVE=false
        RR_HEALTH_TIMER_WAS_ENABLED=false
        RR_HEALTH_TIMER_WAS_ACTIVE=false
        RR_HEALTH_SERVICE_WAS_ACTIVE=false
        systemctl is-active --quiet sing-box 2>/dev/null && RR_SINGBOX_WAS_ACTIVE=true
        systemctl is-enabled --quiet sing-box 2>/dev/null && RR_SINGBOX_WAS_ENABLED=true
        systemctl is-active --quiet rr-nexus 2>/dev/null && RR_NEXUS_WAS_ACTIVE=true
        systemctl is-enabled --quiet rr-nexus 2>/dev/null && RR_NEXUS_WAS_ENABLED=true
        systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && RR_HEALTH_TIMER_WAS_ENABLED=true
        systemctl is-active --quiet argo-rr-health.timer 2>/dev/null && RR_HEALTH_TIMER_WAS_ACTIVE=true
        systemctl is-active --quiet argo-rr-health.service 2>/dev/null && RR_HEALTH_SERVICE_WAS_ACTIVE=true
        rr_subscription_running && RR_SUBSCRIPTION_WAS_ACTIVE=true
        RR_HEALTH_STATE_CAPTURED=true
    }
    rr_persist_update_writer_state() {
        [ "$RR_SINGBOX_WAS_ACTIVE" = true ] && : > "$BACKUP_DIR/singbox_was_running"
        [ "$RR_SINGBOX_WAS_ENABLED" = true ] && : > "$BACKUP_DIR/singbox_was_enabled"
        [ "$RR_NEXUS_WAS_ACTIVE" = true ] && : > "$BACKUP_DIR/nexus_was_running"
        [ "$RR_NEXUS_WAS_ENABLED" = true ] && : > "$BACKUP_DIR/nexus_was_enabled"
        [ "$RR_SUBSCRIPTION_WAS_ACTIVE" = true ] && : > "$BACKUP_DIR/subscription_was_running"
        [ "$RR_HEALTH_TIMER_WAS_ENABLED" = true ] && : > "$BACKUP_DIR/health_timer_was_enabled"
        [ "$RR_HEALTH_TIMER_WAS_ACTIVE" = true ] && : > "$BACKUP_DIR/health_timer_was_running"
        [ "$RR_HEALTH_SERVICE_WAS_ACTIVE" = true ] && : > "$BACKUP_DIR/health_service_was_running"
        : > "$BACKUP_DIR/writer_state_complete"
    }
    rr_create_update_maintenance_marker() { RR_UPDATE_MAINTENANCE_ACTIVE=true; }
    rr_freeze_update_writers() {
        RR_HEALTH_MONITOR_FROZEN=true
        RR_UPDATE_WRITERS_FROZEN=true
    }
    rr_snapshot_external_state() { return 0; }
}
(
    eval "$snapshot_function"
    install_snapshot_test_stubs
    RR_TX_ROOT=$(mktemp -d)
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    mkdir -p "$RR_TX_ROOT/transactions"
    BACKUP_DIR=""
    TX_DIR=""
    RR_LIB_DIR="/nonexistent/rr-runtime"
    RR_LAUNCHER="/nonexistent/rr"
    rr_prepare_recovery_runtime() { return 0; }
    rr_discard_previous_transaction() { return 0; }
    rr_prune_stale_transactions() { return 0; }
    rr_freeze_health_monitor() {
        RR_HEALTH_TIMER_WAS_ENABLED=false
        systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && RR_HEALTH_TIMER_WAS_ENABLED=true
        RR_HEALTH_MONITOR_FROZEN=true
    }
    rr_write_phase() { printf '%s\n' "$1" > "$TX_DIR/phase"; }
    rr_backup_file() { return 0; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    rr_subscription_running() { return 1; }
    systemctl() { return 1; }
    pgrep() { return 1; }

    rr_snapshot_runtime
    [ -d "$BACKUP_DIR" ]
    [ ! -e "$BACKUP_DIR/singbox_was_running" ]
    [ ! -e "$BACKUP_DIR/nexus_was_running" ]
    [ ! -e "$BACKUP_DIR/health_timer_was_enabled" ]
    rm -rf "$RR_TX_ROOT"
)
(
    eval "$snapshot_function"
    install_snapshot_test_stubs
    RR_TX_ROOT=$(mktemp -d)
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    mkdir -p "$RR_TX_ROOT/transactions"
    BACKUP_DIR=""
    TX_DIR=""
    RR_LIB_DIR="/nonexistent/rr-runtime"
    RR_LAUNCHER="/nonexistent/rr"
    rr_prepare_recovery_runtime() { return 0; }
    rr_discard_previous_transaction() { return 0; }
    rr_prune_stale_transactions() { return 0; }
    rr_freeze_health_monitor() {
        RR_HEALTH_TIMER_WAS_ENABLED=false
        systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && RR_HEALTH_TIMER_WAS_ENABLED=true
        RR_HEALTH_MONITOR_FROZEN=true
    }
    rr_write_phase() { printf '%s\n' "$1" > "$TX_DIR/phase"; }
    rr_backup_file() { return 0; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    rr_subscription_running() { return 0; }
    systemctl() { return 0; }
    pgrep() { return 0; }

    rr_snapshot_runtime
    [ -e "$BACKUP_DIR/singbox_was_running" ]
    [ -e "$BACKUP_DIR/nexus_was_running" ]
    [ -e "$BACKUP_DIR/health_timer_was_enabled" ]
    rm -rf "$RR_TX_ROOT"
)
(
    eval "$snapshot_function"
    install_snapshot_test_stubs
    RR_TX_ROOT=$(mktemp -d)
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    mkdir -p "$RR_TX_ROOT/transactions"
    BACKUP_DIR=""
    TX_DIR=""
    RR_LIB_DIR="/nonexistent/rr-runtime"
    RR_LAUNCHER="/nonexistent/rr"
    rr_prepare_recovery_runtime() { return 0; }
    rr_discard_previous_transaction() { return 0; }
    rr_prune_stale_transactions() { return 0; }
    rr_freeze_health_monitor() {
        RR_HEALTH_TIMER_WAS_ENABLED=false
        systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && RR_HEALTH_TIMER_WAS_ENABLED=true
        RR_HEALTH_MONITOR_FROZEN=true
    }
    rr_write_phase() { printf '%s\n' "$1" > "$TX_DIR/phase"; }
    rr_backup_file() { return 1; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    rr_subscription_running() { return 1; }
    systemctl() { return 1; }
    pgrep() { return 1; }

    if rr_snapshot_runtime; then
        echo "Snapshot unexpectedly ignored a real backup failure." >&2
        exit 1
    fi
    rm -rf "$RR_TX_ROOT"
)

# A normal (catchable) failure after the old runtime was moved but before the
# replacement became live must restore the old directory.  Relying only on the
# RUNTIME_REPLACED flag loses both copies during EXIT cleanup.
rollback_function=$(awk '
    /^rr_rollback\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' scripts/install-core.sh)
update_failure_diag_function=$(awk '
    /^rr_emit_update_failure_diag\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' scripts/install-core.sh)
(
    eval "$update_failure_diag_function"
    eval "$rollback_function"
    rollback_root=$(mktemp -d)
    RR_LIB_DIR="$rollback_root/live-runtime"
    OLD_RUNTIME="$rollback_root/transaction/old-runtime"
    BACKUP_DIR="$rollback_root/transaction/backup"
    RR_LAUNCHER="$rollback_root/rr"
    RR_ACTIVE_TX="$rollback_root/active"
    RR_TX_ROOT="$rollback_root/update-root"
    TX_DIR="$rollback_root/transaction"
    mkdir -p "$OLD_RUNTIME/modules" "$BACKUP_DIR"
    printf '%s\n' old-runtime > "$OLD_RUNTIME/modules/sentinel"
    TRANSACTION_ACTIVE=true
    RUNTIME_REPLACED=false
    ROLLBACK_FAILED=false
    systemctl() { return 0; }
    rr_stop_subscription_servers() { return 0; }
    rr_error() { return 0; }
    rr_restore_file() { return 0; }
    rr_restore_dir() { return 0; }
    rr_restore_sqlite() { return 0; }
    rr_restore_ip_acme_update_directories() { return 0; }
    rr_install_restore_external_state_if_required() { return 0; }
    rr_read_trusted_phase() { printf '%s\n' runtime_swapped; }
    rr_quiesce_health_monitor_for_rollback() { return 0; }
    rr_sync_host_state_before_terminal() { return 0; }
    rr_clear_active_transaction_pointer() { return 0; }
    rr_write_phase() { return 0; }

    rr_rollback
    [ -f "$RR_LIB_DIR/modules/sentinel" ]
    [ ! -e "$OLD_RUNTIME" ]
    rm -rf "$rollback_root"
)

echo "[5/13] Fresh-install crypto material regression"
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-config"
    rm -f "$CONFIG_FILE"
    VL_ENABLED=true
    HY2_ENABLED=false
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    SHORT_ID=""
    if validate_subscription_crypto_material >/dev/null 2>&1; then
        echo "Empty Reality material was accepted." >&2
        exit 1
    fi
    PRIVATE_KEY=$(printf 'A%.0s' {1..43})
    PUBLIC_KEY=$(rr_reality_public_from_private "$PRIVATE_KEY")
    SHORT_ID=0123abcd
    validate_subscription_crypto_material
    PUBLIC_KEY=$(printf 'a%.0s' {1..43})
    if validate_subscription_crypto_material >/dev/null 2>&1; then
        echo "Mismatched Reality private/public keys were accepted." >&2
        exit 1
    fi
    PUBLIC_KEY=$(rr_reality_public_from_private "$PRIVATE_KEY")

    # T10/A10：HY2 证书 pin 缺失必须降级（停用 HY2 并继续），不得整体判拒回滚。
    VL_ENABLED=false
    HY2_ENABLED=true
    CERT_SHA256=""
    if ! validate_subscription_crypto_material >/dev/null 2>&1; then
        echo "Missing Hysteria2 pin must degrade, not reject." >&2
        exit 1
    fi
    [ "$HY2_ENABLED" = "false" ] || {
        echo "Hysteria2 was not disabled on missing pin." >&2
        exit 1
    }
    CERT_SHA256=$(printf 'b%.0s' {1..64})
    HY2_ENABLED=true
    validate_subscription_crypto_material
    [ "$HY2_ENABLED" = "true" ] || {
        echo "Valid Hysteria2 pin was degraded unexpectedly." >&2
        exit 1
    }
    rm -f "$CONFIG_FILE"
)

# Portable restores must never accept executable cron/unit payloads.  Those
# files are regenerated from the manifest-verified runtime after data restore.
(
    load_modules_for_tests
    backup_guard_tmp=$(mktemp -d)
    trap 'rm -rf "$backup_guard_tmp"' EXIT
    malicious_cron="$backup_guard_tmp/malicious-cron"
    printf '%s\n' '* * * * * /bin/sh -c id # auto_update_sub.py' > "$malicious_cron"
    crontab() {
        if [ "${1:-}" = "-l" ]; then
            return 1
        fi
        cp "$1" "$backup_guard_tmp/installed-cron"
    }
    if rr_restore_crontab "$malicious_cron"; then
        echo "A backup-supplied cron command was accepted." >&2
        exit 1
    fi
    rr_auto_update_cron_line > "$backup_guard_tmp/safe-cron"
    rr_restore_crontab "$backup_guard_tmp/safe-cron"
    cmp -s "$backup_guard_tmp/safe-cron" "$backup_guard_tmp/installed-cron"

    crontab() {
        [ "${1:-}" = -l ] && return 1
        return 42
    }
    if rr_restore_crontab "$backup_guard_tmp/safe-cron"; then
        echo "A failed crontab install was reported as restored." >&2
        exit 1
    fi
    : > "$backup_guard_tmp/empty-cron"
    crontab() {
        if [ "${1:-}" = -l ]; then
            rr_auto_update_cron_line
            return 0
        fi
        [ "${1:-}" = -r ] && return 42
        return 0
    }
    if rr_restore_crontab "$backup_guard_tmp/empty-cron"; then
        echo "A failed crontab removal was reported as restored." >&2
        exit 1
    fi

    mkdir -p "$backup_guard_tmp/tree/rootfs/etc/systemd/system"
    printf '%s\n' '[Service]' 'ExecStart=/bin/sh -c id' > \
        "$backup_guard_tmp/tree/rootfs/etc/systemd/system/rr-nexus.service"
    if rr_restore_apply_tree "$backup_guard_tmp/tree"; then
        echo "A backup-supplied systemd unit was accepted." >&2
        exit 1
    fi

    # A portable manifest must use canonical relative names and cover every
    # restored data file.  `sha256sum -c` alone accepts absolute paths and can
    # be redirected to devices such as /dev/zero.
    mkdir -p "$backup_guard_tmp/payload/rootfs/etc"
    printf '%s\n' safe > "$backup_guard_tmp/payload/rootfs/etc/argo_vmess.conf"
    : > "$backup_guard_tmp/payload/crontab.txt"
    (
        cd "$backup_guard_tmp/payload"
        sha256sum rootfs/etc/argo_vmess.conf crontab.txt > manifest.sha256
    )
    rr_restore_verify_manifest "$backup_guard_tmp/payload" 2
    cp "$backup_guard_tmp/payload/manifest.sha256" "$backup_guard_tmp/good-manifest"
    rm -f "$backup_guard_tmp/payload/crontab.txt"
    if rr_restore_verify_manifest "$backup_guard_tmp/payload" 2 2>/dev/null; then
        echo "A format 2 restore accepted a missing authenticated crontab." >&2
        exit 1
    fi
    : > "$backup_guard_tmp/payload/crontab.txt"
    grep -v '  crontab.txt$' "$backup_guard_tmp/good-manifest" > \
        "$backup_guard_tmp/payload/manifest.sha256"
    if rr_restore_verify_manifest "$backup_guard_tmp/payload" 2 2>/dev/null; then
        echo "A format 2 manifest omitted the authenticated crontab entry." >&2
        exit 1
    fi
    cp "$backup_guard_tmp/good-manifest" "$backup_guard_tmp/payload/manifest.sha256"
    printf '%s\n' changed > "$backup_guard_tmp/payload/crontab.txt"
    if rr_restore_verify_manifest "$backup_guard_tmp/payload" 2 2>/dev/null; then
        echo "A changed format 2 crontab passed its manifest digest." >&2
        exit 1
    fi
    : > "$backup_guard_tmp/payload/crontab.txt"
    printf '%064d  /etc/os-release\n' 0 > "$backup_guard_tmp/payload/manifest.sha256"
    if rr_restore_verify_manifest "$backup_guard_tmp/payload" 2 2>/dev/null; then
        echo "A restore manifest accepted an absolute path." >&2
        exit 1
    fi
    cp "$backup_guard_tmp/good-manifest" "$backup_guard_tmp/payload/manifest.sha256"
    printf '%s\n' unlisted > "$backup_guard_tmp/payload/rootfs/etc/unlisted.conf"
    if rr_restore_verify_manifest "$backup_guard_tmp/payload" 2 2>/dev/null; then
        echo "A restore manifest failed to reject an unlisted payload file." >&2
        exit 1
    fi
    rm -f "$backup_guard_tmp/payload/rootfs/etc/unlisted.conf"

    # Format 1 backups are still portable: their authenticated crontab was not
    # listed historically, while every rootfs file must remain covered.
    (
        cd "$backup_guard_tmp/payload"
        sha256sum rootfs/etc/argo_vmess.conf > manifest.sha256
    )
    rr_restore_verify_manifest "$backup_guard_tmp/payload" 1

    mkdir -p "$backup_guard_tmp/private-tree/rootfs/etc/rr-naive"
    printf '%s\n' private > "$backup_guard_tmp/private-tree/rootfs/etc/rr-naive/privkey.pem"
    install() {
        [ "$1" = -m ] && [ "$2" = 600 ] || {
            echo "A restored private key was not forced to mode 600." >&2
            return 1
        }
    }
    mkdir() { return 0; }
    chmod() {
        [ "$1" = 700 ] || {
            echo "A restored private directory was not forced to mode 700." >&2
            return 1
        }
    }
    mv() { return 0; }
    rr_restore_apply_tree "$backup_guard_tmp/private-tree"
)

# Portable restore keeps the destination subscription access plane.  A source
# HTTPS domain and listener must not be imported onto a local-only target.
(
    load_modules_for_tests
    network_restore_tmp=$(mktemp -d)
    trap 'rm -rf "$network_restore_tmp"' EXIT
    rollback="$network_restore_tmp/rollback"
    CONFIG_FILE="$network_restore_tmp/argo_vmess.conf"
    mkdir -p "$rollback"
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=7
INSTALL_COMPLETE=true
SUB_PORT=19090
SUB_ACCESS_MODE=local
SUB_DOMAIN=''
SUB_PUBLIC_PORT_IPV4=29090
SUB_PUBLIC_PORT_IPV6=39090
ENTRY_IP_MODE=ipv4
OUTBOUND_IP_MODE=prefer_ipv4
ENTRY_IPV4_ADDRESS=192.0.2.10
ENTRY_IPV6_ADDRESS=''
EOF
    rr_restore_capture_target_network "$rollback"

    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=7
INSTALL_COMPLETE=true
SUB_PORT=8443
SUB_ACCESS_MODE=https
SUB_DOMAIN=source-sub.example.com
SUB_PUBLIC_PORT_IPV4=443
SUB_PUBLIC_PORT_IPV6=443
ENTRY_IP_MODE=ipv6
OUTBOUND_IP_MODE=ipv6_only
ENTRY_IPV4_ADDRESS=''
ENTRY_IPV6_ADDRESS=2001:db8::20
EOF
    rr_restore_apply_target_network_config "$rollback"
    load_config_with_defaults
    [ "$SUB_PORT" = 19090 ] && [ "$SUB_ACCESS_MODE" = local ] && \
        [ -z "$SUB_DOMAIN" ] && [ "$SUB_PUBLIC_PORT_IPV4" = 29090 ] && \
        [ "$SUB_PUBLIC_PORT_IPV6" = 39090 ] && [ "$ENTRY_IP_MODE" = ipv4 ] && \
        [ "$OUTBOUND_IP_MODE" = prefer_ipv4 ] && \
        [ "$ENTRY_IPV4_ADDRESS" = 192.0.2.10 ] && \
        [ -z "$ENTRY_IPV6_ADDRESS" ] || {
            echo "A portable restore replaced the target subscription access plane." >&2
            exit 1
        }

    sed -i 's/^TARGET_SUB_ACCESS_MODE=.*/TARGET_SUB_ACCESS_MODE=https/' \
        "$rollback/target-network"
    sed -i 's/^TARGET_SUB_DOMAIN=.*/TARGET_SUB_DOMAIN=not-a-domain/' \
        "$rollback/target-network"
    if rr_restore_apply_target_network_config "$rollback"; then
        echo "An invalid target subscription access snapshot was accepted." >&2
        exit 1
    fi
)

# Portable Nexus restore keeps the destination access plane.  A public source
# must neither expose a blank target nor replace a local target's access
# settings, and a newly restored Nexus must remain enabled after reboot.
(
    load_modules_for_tests
    nexus_restore_tmp=$(mktemp -d)
    trap 'rm -rf "$nexus_restore_tmp"' EXIT
    payload="$nexus_restore_tmp/payload"
    blank_rollback="$nexus_restore_tmp/blank-rollback"
    local_rollback="$nexus_restore_tmp/local-rollback"
    live_dir="$nexus_restore_tmp/live"
    systemctl_log="$nexus_restore_tmp/systemctl.log"
    mkdir -p "$payload/rootfs/etc/rr-nexus/certs" "$blank_rollback/rootfs" \
        "$local_rollback/rootfs/etc/rr-nexus" "$live_dir"
    NEXUS_CONFIG_FILE="$live_dir/nexus.json"
    NEXUS_SERVICE_FILE="$live_dir/rr-nexus.service"
    NEXUS_SERVICE_GUARD_DROPIN="$nexus_restore_tmp/systemd/rr-nexus.service.d/40-rr-nexus-guards.conf"

    jq -n '{
        mode:"public", listen:"127.0.0.1", port:7900,
        domain:"source-panel.example.com",
        database:"/var/lib/rr-nexus/nexus.db",
        subscription_root:"/var/lib/rr-nexus/subscriptions",
        published_subscription_root:"/tmp/sub_server/nexus",
        stats_port:39091, ssh_host:"198.51.100.9", public_port:443,
        sub_port:8443, traffic_mode:"upload",
        acme_email:"source-acme@example.com"
    }' > "$payload/rootfs/etc/rr-nexus/nexus.json"
    printf '%s\n' source-certificate > "$payload/rootfs/etc/rr-nexus/certs/ip.crt"

    nexus_enabled=false
    nexus_running=false
    systemctl_enable_works=true
    systemctl() {
        printf '%s\n' "$*" >> "$systemctl_log"
        case "$*" in
            "enable rr-nexus")
                [ "$systemctl_enable_works" = true ] && nexus_enabled=true
                return 0
                ;;
            "disable rr-nexus") nexus_enabled=false; return 0 ;;
            "start rr-nexus") nexus_running=true; return 0 ;;
            "stop rr-nexus") nexus_running=false; return 0 ;;
            "is-enabled --quiet rr-nexus") [ "$nexus_enabled" = true ] ;;
            "show --property=LoadState --value rr-nexus")
                if [ -e "$NEXUS_SERVICE_FILE" ]; then
                    printf '%s\n' loaded
                else
                    printf '%s\n' not-found
                fi
                return 0
                ;;
            "show --property=ActiveState --value rr-nexus")
                [ "$nexus_running" = true ] && printf '%s\n' active || printf '%s\n' inactive
                return 0
                ;;
            "show --property=UnitFileState --value rr-nexus")
                if [ ! -e "$NEXUS_SERVICE_FILE" ]; then
                    printf '\n'
                elif [ "$nexus_enabled" = true ]; then
                    printf '%s\n' enabled
                else
                    printf '%s\n' disabled
                fi
                return 0
                ;;
            *) return 0 ;;
        esac
    }
    # This fixture covers portable access-state retention, not service guard
    # installation.  Keep that orthogonal preflight entirely inside the mock.
    rr_nexus_service_start_preflight() { return 0; }

    # The generic portable tree application must not install the source
    # nexus.json or its source-machine certificate files at all.
    (
        install() {
            echo "Portable tree attempted to install source Nexus access state: $*" >&2
            return 97
        }
        rr_restore_apply_tree "$payload" portable
    )

    rr_restore_capture_target_nexus_state "$blank_rollback"
    [ ! -e "$blank_rollback/target_nexus_was_present" ]
    rr_restore_apply_target_nexus_state "$blank_rollback" "$payload"
    jq -e '
        .mode == "local" and .domain == "" and .public_port == 7900 and
        (has("acme_email") | not) and .traffic_mode == "upload"
    ' "$NEXUS_CONFIG_FILE" >/dev/null || {
        echo "A public Nexus source exposed or replaced a blank target access plane." >&2
        exit 1
    }
    if cmp -s "$payload/rootfs/etc/rr-nexus/nexus.json" "$NEXUS_CONFIG_FILE"; then
        echo "The source nexus.json was installed verbatim on a blank target." >&2
        exit 1
    fi
    proxy_was_removed=false
    nexus_remove_public_proxy() { proxy_was_removed=true; }
    nexus_enable_public_https() {
        echo "Blank-target restore attempted to create a public Nexus proxy." >&2
        return 1
    }
    nexus_enable_public_ip_https() {
        echo "Blank-target restore attempted to create a public Nexus IP proxy." >&2
        return 1
    }
    nexus_reconcile_public_proxy
    [ "$proxy_was_removed" = true ] || {
        echo "Blank-target restore did not reconcile Nexus to local-only access." >&2
        exit 1
    }

    : > "$NEXUS_SERVICE_FILE"
    rr_restore_finalize_nexus_enablement "$blank_rollback"
    [ "$nexus_enabled" = true ] && [ "$nexus_running" = true ]
    grep -Fxq 'enable rr-nexus' "$systemctl_log"
    grep -Fxq 'show --property=UnitFileState --value rr-nexus' "$systemctl_log"
    # Simulate the boot decision: an enabled restored unit is selected again
    # after all transient running state is lost.
    nexus_running=false
    if systemctl is-enabled --quiet rr-nexus; then
        nexus_running=true
    fi
    [ "$nexus_running" = true ] || {
        echo "A blank-target Nexus restore would disappear after reboot." >&2
        exit 1
    }

    # Repeat with an existing local target.  Only the four access-plane fields
    # come from the target; portable data such as traffic_mode still comes from
    # the authenticated source config.
    jq -n '{
        mode:"local", listen:"127.0.0.1", port:7900, domain:"",
        database:"/var/lib/rr-nexus/nexus.db",
        subscription_root:"/var/lib/rr-nexus/subscriptions",
        published_subscription_root:"/tmp/sub_server/nexus",
        stats_port:39092, ssh_host:"203.0.113.8", public_port:24888,
        sub_port:9443, traffic_mode:"both",
        acme_email:"target-acme@example.net"
    }' > "$NEXUS_CONFIG_FILE"
    nexus_enabled=false
    nexus_running=false
    rr_restore_capture_target_nexus_state "$local_rollback"
    cp "$NEXUS_CONFIG_FILE" "$local_rollback/rootfs/etc/rr-nexus/nexus.json"
    rm -f "$NEXUS_CONFIG_FILE"
    rr_restore_apply_target_nexus_state "$local_rollback" "$payload"
    jq -e '
        .mode == "local" and .domain == "" and .public_port == 24888 and
        .acme_email == "target-acme@example.net" and .traffic_mode == "upload"
    ' "$NEXUS_CONFIG_FILE" >/dev/null || {
        echo "A public Nexus source replaced the local target access plane." >&2
        exit 1
    }
    rr_restore_finalize_nexus_enablement "$local_rollback"
    [ "$nexus_enabled" = false ] || {
        echo "Restore changed an existing target's disabled Nexus state." >&2
        exit 1
    }

    # Rollback restores both possible original enable states exactly, and an
    # enable operation that does not survive is rejected by the strict
    # UnitFileState verification gate.
    nexus_enabled=true
    rr_restore_restore_nexus_enablement "$local_rollback"
    [ "$nexus_enabled" = false ]
    : > "$local_rollback/nexus_was_enabled"
    rr_restore_restore_nexus_enablement "$local_rollback"
    [ "$nexus_enabled" = true ]
    systemctl_enable_works=false
    nexus_enabled=false
    if rr_restore_set_nexus_enablement true; then
        echo "A failed rr-nexus enable verification was accepted." >&2
        exit 1
    fi

    # Exercise the rollback orchestration with an exact local config snapshot,
    # not merely the enablement helper in isolation.
    rollback_stage="$nexus_restore_tmp/restore.exact"
    rollback_tree="$rollback_stage/rollback"
    install -d -m 700 "$rollback_stage"
    mkdir -p "$rollback_tree/rootfs/etc/rr-nexus"
    cp "$local_rollback/rootfs/etc/rr-nexus/nexus.json" \
        "$rollback_tree/rootfs/etc/rr-nexus/nexus.json"
    : > "$rollback_tree/complete"
    chmod 600 "$rollback_tree/complete"
    printf '%s\n' candidate > "$NEXUS_CONFIG_FILE"
    nexus_enabled=true
    systemctl_enable_works=true
    RR_BACKUP_WORK_DIR="$nexus_restore_tmp"
    RR_RESTORE_ACTIVE="$nexus_restore_tmp/active"
    RR_RESTORE_RUNTIME_READY="$nexus_restore_tmp/runtime-ready"
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$rollback_stage"
    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    # IP-ACME replay has dedicated transaction tests.  This fixture isolates
    # portable Nexus access-state and enablement rollback semantics.
    rr_restore_replace_target_ip_acme_state() { return 0; }
    rr_restore_rearm_target_ip_acme() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() {
        cp "$1/rootfs/etc/rr-nexus/nexus.json" "$NEXUS_CONFIG_FILE"
    }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    rr_restore_rollback_stage "$rollback_stage"
    cmp -s "$rollback_tree/rootfs/etc/rr-nexus/nexus.json" "$NEXUS_CONFIG_FILE" || {
        echo "Nexus rollback did not restore the exact original config." >&2
        exit 1
    }
    [ "$nexus_enabled" = false ] || {
        echo "Nexus rollback did not restore the original disabled state." >&2
        exit 1
    }
)

# The durable restore marker must cover the service-freeze window as well as
# file replacement.  An interruption before mutation restarts the untouched
# original runtime; an interruption after mutation enters full rollback.
(
    load_modules_for_tests
    recovery_tmp=$(mktemp -d)
    trap 'rm -rf "$recovery_tmp"' EXIT
    RR_BACKUP_WORK_DIR="$recovery_tmp"
    RR_RESTORE_ACTIVE="$recovery_tmp/active"
    RR_RESTORE_RUNTIME_READY="$recovery_tmp/runtime-ready"
    RR_RESTORE_LOCK_HELD=1
    recovery_log="$recovery_tmp/recovery.log"
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_resume_snapshot_writers() {
        local rollback="$1"
        printf '%s,%s,%s,%s,%s\n' \
            "$([ -f "$rollback/singbox_was_running" ] && printf true || printf false)" \
            "$([ -f "$rollback/nexus_was_running" ] && printf true || printf false)" \
            "$([ -f "$rollback/subscription_was_running" ] && printf true || printf false)" \
            "$([ -f "$rollback/argo_was_running" ] && printf true || printf false)" \
            "$([ -f "$rollback/health_timer_was_enabled" ] && printf true || printf false)" \
            >> "$recovery_log"
    }

    phase_index=0
    for phase in freezing frozen prepared pre_recovery_failed; do
        phase_index=$((phase_index + 1))
        stage="$recovery_tmp/restore.p${phase_index}"
        install -d -m 700 "$stage"
        mkdir -p "$stage/rollback"
        : > "$stage/rollback/singbox_was_running"
        : > "$stage/rollback/subscription_was_running"
        : > "$stage/rollback/health_timer_was_enabled"
        rr_restore_write_phase "$stage" "$phase"
        rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage"
        rr_restore_recover_active
        [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -e "$stage" ] || {
            echo "Pre-mutation restore recovery did not clean phase $phase." >&2
            exit 1
        }
    done
    [ "$(wc -l < "$recovery_log")" -eq 4 ]
    if grep -Fvxq 'true,false,true,false,true' "$recovery_log"; then
        echo "Pre-mutation restore recovery changed the original service state." >&2
        exit 1
    fi

    # A failed early resume must remain in the early-resume branch.  Treating
    # it as a full rollback could clear the live tree and apply a partial
    # snapshot created before the freeze completed.
    retry_stage="$recovery_tmp/restore.retry"
    install -d -m 700 "$retry_stage"
    mkdir -p "$retry_stage/rollback"
    rr_restore_write_phase "$retry_stage" frozen
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$retry_stage"
    resume_should_fail=true
    rr_restore_resume_snapshot_writers() { [ "$resume_should_fail" != true ]; }
    if rr_restore_recover_active 2>/dev/null; then
        echo "A failed pre-mutation service resume was reported as recovered." >&2
        exit 1
    fi
    [ "$(cat "$retry_stage/phase")" = pre_recovery_failed ]
    [ -e "$RR_RESTORE_ACTIVE" ] && [ -d "$retry_stage" ]
    resume_should_fail=false
    rr_restore_recover_active
    [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -e "$retry_stage" ]

    # Corrupt transaction pointers/phases fail closed and preserve evidence.
    victim="$recovery_tmp/victim"
    mkdir -p "$victim"
    install -d -m 700 "$recovery_tmp/restore.good"
    printf '%s\n' keep > "$victim/sentinel"
    for invalid_pointer in '' \
        "$recovery_tmp/restore.good/../victim" \
        "$recovery_tmp/restore.missing"; do
        printf '%s\n' "$invalid_pointer" > "$RR_RESTORE_ACTIVE"
        chmod 600 "$RR_RESTORE_ACTIVE"
        if rr_restore_recover_active 2>/dev/null; then
            echo "An invalid active restore pointer was accepted: $invalid_pointer" >&2
            exit 1
        fi
        [ -f "$victim/sentinel" ] && [ -e "$RR_RESTORE_ACTIVE" ]
    done
    rm -f "$RR_RESTORE_ACTIVE"
    printf '%s\n' "$recovery_tmp/restore.good" > "$recovery_tmp/active-target"
    chmod 600 "$recovery_tmp/active-target"
    ln -s "$recovery_tmp/active-target" "$RR_RESTORE_ACTIVE"
    if rr_restore_recover_active 2>/dev/null; then
        echo "A symlink active restore pointer was accepted." >&2
        exit 1
    fi
    rm -f "$RR_RESTORE_ACTIVE" "$recovery_tmp/active-target"

    for bad_phase in '' unknown; do
        phase_stage="$recovery_tmp/restore.phase"
        install -d -m 700 "$phase_stage"
        rr_restore_write_phase "$phase_stage" "$bad_phase"
        rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$phase_stage"
        if rr_restore_recover_active 2>/dev/null; then
            echo "An unsafe restore phase was accepted: ${bad_phase:-empty}" >&2
            exit 1
        fi
        [ -d "$phase_stage" ] && [ -e "$RR_RESTORE_ACTIVE" ]
        rm -f "$RR_RESTORE_ACTIVE"
        rm -rf "$phase_stage"
    done

    partial_stage="$recovery_tmp/restore.partial"
    install -d -m 700 "$partial_stage"
    mkdir -p "$partial_stage/rollback/rootfs"
    if rr_restore_rollback_stage "$partial_stage" 2>/dev/null; then
        echo "A partial rollback snapshot was accepted." >&2
        exit 1
    fi
    rm -rf "$partial_stage"

    for terminal_phase in committed rolled_back aborted; do
        terminal_stage="$recovery_tmp/restore.terminal"
        install -d -m 700 "$terminal_stage"
        rr_restore_write_phase "$terminal_stage" "$terminal_phase"
        rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$terminal_stage"
        rr_restore_recover_active
        [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -e "$terminal_stage" ]
    done

    rollback_log="$recovery_tmp/rollback.log"
    rollback_should_fail=true
    rr_restore_rollback_stage() {
        printf '%s\n' "$1" >> "$rollback_log"
        [ "$rollback_should_fail" != true ] || return 1
        rm -f "$RR_RESTORE_ACTIVE"
    }
    retry_stage="$recovery_tmp/restore.rollbackretry"
    install -d -m 700 "$retry_stage"
    rr_restore_write_phase "$retry_stage" mutating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$retry_stage"
    if rr_restore_recover_active; then
        echo "A failed full rollback was reported as recovered." >&2
        exit 1
    fi
    [ -d "$retry_stage" ] && [ -e "$RR_RESTORE_ACTIVE" ]
    rollback_should_fail=false
    rr_restore_recover_active
    [ ! -e "$retry_stage" ] && [ ! -e "$RR_RESTORE_ACTIVE" ]

    phase_index=0
    for phase in mutating cleared applied migrating rolling_back recovery_failed; do
        phase_index=$((phase_index + 1))
        stage="$recovery_tmp/restore.r${phase_index}"
        install -d -m 700 "$stage"
        rr_restore_write_phase "$stage" "$phase"
        rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage"
        rr_restore_recover_active
        [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -e "$stage" ] || {
            echo "Post-mutation restore recovery did not roll back phase $phase." >&2
            exit 1
        }
    done
    [ "$(wc -l < "$rollback_log")" -eq 8 ]
)

# Nexus core release metadata, BUILD_INFO, and checksum files form one
# provenance chain.  Exercise it with the default mawk used by Debian 12 and
# Ubuntu 22.04, including malformed files that could otherwise mix versions.
(
    load_modules_for_tests
    checksum_tmp=$(mktemp -d)
    trap 'rm -rf "$checksum_tmp"' EXIT
    command -v mawk >/dev/null 2>&1 || {
        echo "mawk is required for the Nexus checksum portability regression." >&2
        exit 1
    }

    # The only accepted traffic core is the native 1.14.0 build whose source,
    # immutable releases, metadata, checksums and runtime identity all close on
    # the audited official commit.  There is no mutable/older fallback.
    [ "$NEXUS_CORE_TARGET_VERSION" = 1.14.0 ]
    [ "$NEXUS_CORE_TARGET_TAG" = v1.14.0 ]
    [ "$NEXUS_CORE_SOURCE_COMMIT" = \
        0b8995879f29a9b98ee027bc17b75e101445b238 ]
    [ "$NEXUS_CORE_UPSTREAM_RELEASE_ID" = 379452161 ]
    [ "$NEXUS_CORE_GO_VERSION" = go1.25.5 ]
    [ "$NEXUS_CORE_MIN_GO_VERSION" = 1.25.0 ]
    [ "$NEXUS_CORE_RELEASE_REVISION" = 1 ]

    version="$NEXUS_CORE_TARGET_VERSION"
    upstream_tag="$NEXUS_CORE_TARGET_TAG"
    release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"
    builder_commit=$(printf 'c%.0s' {1..40})
    asset_base="https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/"
    fixture_root="$checksum_tmp/exact-1.14"
    mkdir -p "$fixture_root"

    write_exact_core_binary() {
        local target="$1"
        local arch="$2"
        mkdir -p "$(dirname -- "$target")"
        cat > "$target" <<EOF
#!/bin/sh
printf '%s\n' \\
  'sing-box version ${NEXUS_CORE_TARGET_VERSION}' \\
  '' \\
  'Environment: ${NEXUS_CORE_GO_VERSION} linux/${arch}' \\
  'Tags: ${NEXUS_CORE_EXPECTED_BUILD_TAGS}' \\
  'Revision: ${NEXUS_CORE_SOURCE_COMMIT}' \\
  'CGO: disabled'
EOF
        chmod 755 "$target"
    }

    for fixture_arch in amd64 arm64; do
        fixture_dir="$fixture_root/sing-box-${version}-linux-${fixture_arch}"
        write_exact_core_binary "$fixture_dir/sing-box" "$fixture_arch"
        tar -czf "$fixture_root/rr-sing-box-${version}-linux-${fixture_arch}.tar.gz" \
            -C "$fixture_root" \
            "sing-box-${version}-linux-${fixture_arch}/sing-box"
        nexus_validate_traffic_core_binary "$fixture_dir/sing-box" "$fixture_arch"
    done
    sha256sum \
        "$fixture_root/rr-sing-box-${version}-linux-amd64.tar.gz" \
        "$fixture_root/rr-sing-box-${version}-linux-arm64.tar.gz" | \
        sed "s#  ${fixture_root}/#  #" > "$fixture_root/SHA256SUMS"

    cat > "$fixture_root/BUILD_INFO" <<EOF
SING_BOX_VERSION=${version}
SING_BOX_TAG=${upstream_tag}
SOURCE_COMMIT=${NEXUS_CORE_SOURCE_COMMIT}
RR_BUILDER_COMMIT=${builder_commit}
RR_CORE_RELEASE=${release_tag}
GO_VERSION=${NEXUS_CORE_GO_VERSION}
CGO_ENABLED=0
BUILD_TAG=with_v2ray_api
BUILD_TAGS=${NEXUS_CORE_EXPECTED_BUILD_TAGS}
SOURCE=https://github.com/SagerNet/sing-box/tree/${upstream_tag}
EOF
    jq -n --arg tag "$upstream_tag" \
        --argjson release_id "$NEXUS_CORE_UPSTREAM_RELEASE_ID" '{
            id: $release_id,
            tag_name: $tag,
            draft: false,
            prerelease: false,
            immutable: true,
            author: {login:"github-actions[bot]"},
            url: ("https://api.github.com/repos/SagerNet/sing-box/releases/" +
                ($release_id | tostring)),
            html_url: ("https://github.com/SagerNet/sing-box/releases/tag/" + $tag)
        }' > "$fixture_root/upstream.json"
    jq -n --arg tag "$release_tag" --arg target "$builder_commit" \
        --arg base "$asset_base" --arg version "$version" '{
            tag_name: $tag,
            target_commitish: $target,
            draft: false,
            prerelease: false,
            immutable: true,
            author: {login:"github-actions[bot]"},
            assets: [
                "BUILD_INFO", "SHA256SUMS",
                "rr-sing-box-\($version)-linux-amd64.tar.gz",
                "rr-sing-box-\($version)-linux-arm64.tar.gz"
            ] | map({
                name: ., browser_download_url: ($base + .), state:"uploaded",
                uploader:{login:"github-actions[bot]"}
            })
        }' > "$fixture_root/release.json"

    nexus_validate_upstream_core_release "$fixture_root/upstream.json"
    nexus_validate_traffic_core_release "$fixture_root/release.json" "$upstream_tag"
    nexus_validate_core_build_info \
        "$fixture_root/BUILD_INFO" "$version" "$release_tag" "$builder_commit"
    RR_AWK_BIN=mawk nexus_validate_core_checksums \
        "$fixture_root/SHA256SUMS" "$version"

    amd64_archive_source="$fixture_root/rr-sing-box-${version}-linux-amd64.tar.gz"
    arm64_archive_source="$fixture_root/rr-sing-box-${version}-linux-arm64.tar.gz"
    curl() {
        local output="" argument="" url=""
        while [ "$#" -gt 0 ]; do
            argument="$1"
            shift
            case "$argument" in
                -o) output="$1"; shift ;;
                https://*) url="$argument" ;;
            esac
        done
        case "$url" in
            "$NEXUS_CORE_UPSTREAM_API")
                cp "$fixture_root/upstream.json" "$output" ;;
            "${NEXUS_CORE_RELEASE_API}/${release_tag}")
                cp "$fixture_root/release.json" "$output" ;;
            "${asset_base}BUILD_INFO")
                cp "$fixture_root/BUILD_INFO" "$output" ;;
            "${asset_base}SHA256SUMS")
                cp "$fixture_root/SHA256SUMS" "$output" ;;
            "${asset_base}rr-sing-box-${version}-linux-amd64.tar.gz")
                cp "$amd64_archive_source" "$output" ;;
            "${asset_base}rr-sing-box-${version}-linux-arm64.tar.gz")
                cp "$arm64_archive_source" "$output" ;;
            *) return 1 ;;
        esac
    }
    for fixture_arch in amd64 arm64; do
        download_root="$checksum_tmp/download-${fixture_arch}"
        mkdir -p "$download_root"
        SYS_ARCH="$fixture_arch"
        nexus_download_traffic_core "$download_root"
        nexus_validate_traffic_core_binary "$download_root/sing-box" "$fixture_arch"
        [ "$(get_singbox_version "$download_root/sing-box")" = "$version" ]
    done
    [ "$(nexus_traffic_core_version)" = "$version" ]

    (
        curl() { return 1; }
        if nexus_traffic_core_version >/dev/null 2>&1; then
            echo "Transport failure silently selected a traffic core." >&2
            exit 1
        fi
    )
    cp "$amd64_archive_source" "$fixture_root/tampered-amd64.tar.gz"
    printf X | dd of="$fixture_root/tampered-amd64.tar.gz" \
        bs=1 seek=0 count=1 conv=notrunc status=none
    amd64_archive_source="$fixture_root/tampered-amd64.tar.gz"
    SYS_ARCH=amd64
    mkdir -p "$checksum_tmp/download-tampered"
    if nexus_download_traffic_core "$checksum_tmp/download-tampered" \
        >/dev/null 2>&1; then
        echo "A same-size tampered 1.14 archive was accepted." >&2
        exit 1
    fi
    amd64_archive_source="$fixture_root/rr-sing-box-${version}-linux-amd64.tar.gz"

    digest_a=$(printf 'a%.0s' {1..64})
    digest_b=$(printf 'b%.0s' {1..64})
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n%s  rr-sing-box-1.2.3-linux-arm64.tar.gz\n' \
        "$digest_a" "$digest_b" > "$checksum_tmp/good"
    RR_AWK_BIN=mawk nexus_validate_core_checksums "$checksum_tmp/good" 1.2.3

    : > "$checksum_tmp/empty"
    head -n 1 "$checksum_tmp/good" > "$checksum_tmp/one"
    cp "$checksum_tmp/good" "$checksum_tmp/blank"
    printf '\n' >> "$checksum_tmp/blank"
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\r\n%s  rr-sing-box-1.2.3-linux-arm64.tar.gz\r\n' \
        "$digest_a" "$digest_b" > "$checksum_tmp/crlf"
    printf '%s\trr-sing-box-1.2.3-linux-amd64.tar.gz\n%s\trr-sing-box-1.2.3-linux-arm64.tar.gz\n' \
        "$digest_a" "$digest_b" > "$checksum_tmp/tab"
    digest_upper=$(printf 'A%.0s' {1..64})
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n%s  rr-sing-box-1.2.3-linux-arm64.tar.gz\n' \
        "$digest_upper" "$digest_b" > "$checksum_tmp/uppercase"
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n' \
        "$digest_a" "$digest_b" > "$checksum_tmp/same-arch"
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n%s  rr-sing-box-1.2.4-linux-arm64.tar.gz\n' \
        "$digest_a" "$digest_b" > "$checksum_tmp/mixed-version"
    cp "$checksum_tmp/good" "$checksum_tmp/short"
    cp "$checksum_tmp/good" "$checksum_tmp/long"
    cp "$checksum_tmp/good" "$checksum_tmp/nonhex"
    cp "$checksum_tmp/good" "$checksum_tmp/extra"
    sed -i '1s/^a//' "$checksum_tmp/short"
    sed -i '1s/^/a/' "$checksum_tmp/long"
    sed -i '1s/^a/g/' "$checksum_tmp/nonhex"
    printf '%s  rr-sing-box-1.2.3-linux-amd64.tar.gz\n' "$digest_a" >> "$checksum_tmp/extra"
    for bad in empty one blank crlf tab uppercase same-arch mixed-version short long nonhex extra; do
        if RR_AWK_BIN=mawk nexus_validate_core_checksums "$checksum_tmp/$bad" 1.2.3; then
            echo "Invalid Nexus core checksum list was accepted: $bad" >&2
            exit 1
        fi
    done
    if RR_AWK_BIN=mawk nexus_validate_core_checksums "$checksum_tmp/good" 1.2.4; then
        echo "Nexus checksum validator accepted the wrong expected version." >&2
        exit 1
    fi

    version="$NEXUS_CORE_TARGET_VERSION"
    upstream_tag="$NEXUS_CORE_TARGET_TAG"
    release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"
    builder_commit=$(printf 'c%.0s' {1..40})
    source_commit="$NEXUS_CORE_SOURCE_COMMIT"
    asset_base="https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/"

    assert_bad_upstream_release() {
        local fixture="$1"
        if nexus_validate_upstream_core_release "$fixture"; then
            echo "Invalid official sing-box release metadata was accepted: ${fixture##*.}" >&2
            exit 1
        fi
    }
    jq '.tag_name = "v1.14.1"' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.tag"
    jq '.id += 1' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.id"
    jq '.draft = true' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.draft"
    jq '.prerelease = true' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.prerelease"
    jq '.immutable = false' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.mutable"
    jq '.author.login = "attacker"' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.author"
    jq '.url = "https://example.invalid/release"' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.url"
    jq '.html_url = "https://example.invalid/tag"' "$fixture_root/upstream.json" > "$checksum_tmp/upstream.html"
    for bad in tag id draft prerelease mutable author url html; do
        assert_bad_upstream_release "$checksum_tmp/upstream.$bad"
    done

    jq -n --arg tag "$release_tag" --arg target "$builder_commit" --arg base "$asset_base" \
        --arg version "$version" '{
            tag_name: $tag,
            target_commitish: $target,
            draft: false,
            prerelease: false,
            immutable: true,
            author: {login:"github-actions[bot]"},
            assets: [
                "BUILD_INFO", "SHA256SUMS",
                "rr-sing-box-\($version)-linux-amd64.tar.gz",
                "rr-sing-box-\($version)-linux-arm64.tar.gz"
            ] | map({
                name: ., browser_download_url: ($base + .), state:"uploaded",
                uploader:{login:"github-actions[bot]"}
            })
        }' > "$checksum_tmp/release.good"
    nexus_validate_traffic_core_release "$checksum_tmp/release.good" "$upstream_tag"

    assert_bad_core_release() {
        local fixture="$1"
        if nexus_validate_traffic_core_release "$fixture" "$upstream_tag"; then
            echo "Invalid Nexus core release metadata was accepted: ${fixture##*.}" >&2
            exit 1
        fi
    }
    jq '.tag_name = "rr-nexus-core-v1.14.1-r1"' "$checksum_tmp/release.good" > "$checksum_tmp/release.tag"
    jq '.target_commitish = "main"' "$checksum_tmp/release.good" > "$checksum_tmp/release.target"
    jq '.draft = true' "$checksum_tmp/release.good" > "$checksum_tmp/release.draft"
    jq '.prerelease = true' "$checksum_tmp/release.good" > "$checksum_tmp/release.prerelease"
    jq '.immutable = false' "$checksum_tmp/release.good" > "$checksum_tmp/release.mutable"
    jq '.assets = .assets[:-1]' "$checksum_tmp/release.good" > "$checksum_tmp/release.missing"
    jq '.assets += [{name:"unexpected", browser_download_url:"https://example.invalid/unexpected"}]' \
        "$checksum_tmp/release.good" > "$checksum_tmp/release.extra"
    jq '.assets[3] = .assets[2]' "$checksum_tmp/release.good" > "$checksum_tmp/release.duplicate"
    jq '.assets[0].browser_download_url = "https://example.invalid/BUILD_INFO"' \
        "$checksum_tmp/release.good" > "$checksum_tmp/release.url"
    jq '.author.login = "attacker"' "$checksum_tmp/release.good" > "$checksum_tmp/release.author"
    jq '.assets[0].state = "open"' "$checksum_tmp/release.good" > "$checksum_tmp/release.state"
    jq '.assets[0].uploader.login = "attacker"' \
        "$checksum_tmp/release.good" > "$checksum_tmp/release.uploader"
    for bad in tag target draft prerelease mutable missing extra duplicate url author state uploader; do
        assert_bad_core_release "$checksum_tmp/release.$bad"
    done

    cat > "$checksum_tmp/BUILD_INFO.good" <<EOF
SING_BOX_VERSION=${version}
SING_BOX_TAG=${upstream_tag}
SOURCE_COMMIT=${source_commit}
RR_BUILDER_COMMIT=${builder_commit}
RR_CORE_RELEASE=${release_tag}
GO_VERSION=${NEXUS_CORE_GO_VERSION}
CGO_ENABLED=0
BUILD_TAG=with_v2ray_api
BUILD_TAGS=${NEXUS_CORE_EXPECTED_BUILD_TAGS}
SOURCE=https://github.com/SagerNet/sing-box/tree/${upstream_tag}
EOF
    nexus_validate_core_build_info \
        "$checksum_tmp/BUILD_INFO.good" "$version" "$release_tag" "$builder_commit"
    assert_bad_build_info() {
        local fixture="$1"
        if nexus_validate_core_build_info \
            "$fixture" "$version" "$release_tag" "$builder_commit"; then
            echo "Invalid Nexus BUILD_INFO was accepted: ${fixture##*.}" >&2
            exit 1
        fi
    }
    sed 's/^SING_BOX_VERSION=.*/SING_BOX_VERSION=1.14.1/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.version"
    sed 's/^SING_BOX_TAG=.*/SING_BOX_TAG=v1.14.1/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.tag"
    sed 's/^SOURCE_COMMIT=.*/SOURCE_COMMIT=0000000000000000000000000000000000000000/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.source-commit"
    sed 's/^RR_BUILDER_COMMIT=.*/RR_BUILDER_COMMIT=0000000000000000000000000000000000000000/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.builder"
    sed 's/^RR_CORE_RELEASE=.*/RR_CORE_RELEASE=rr-nexus-core-v1.14.1-r1/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.release"
    sed 's/^GO_VERSION=.*/GO_VERSION=go9.9.9/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.go-version"
    sed 's/^CGO_ENABLED=.*/CGO_ENABLED=1/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.cgo"
    sed 's/^BUILD_TAG=.*/BUILD_TAG=with_quic/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.build-tag"
    sed 's/^BUILD_TAGS=.*/BUILD_TAGS=with_v2ray_api/' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.build-tags"
    sed 's#^SOURCE=.*#SOURCE=https://example.invalid/source#' \
        "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.source"
    cp "$checksum_tmp/BUILD_INFO.good" "$checksum_tmp/BUILD_INFO.duplicate"
    printf 'SING_BOX_TAG=%s\n' "$upstream_tag" >> "$checksum_tmp/BUILD_INFO.duplicate"
    sed 's/$/\r/' "$checksum_tmp/BUILD_INFO.good" > "$checksum_tmp/BUILD_INFO.crlf"
    grep -v '^SOURCE_COMMIT=' "$checksum_tmp/BUILD_INFO.good" > \
        "$checksum_tmp/BUILD_INFO.missing" || true
    for bad in version tag source-commit builder release go-version cgo build-tag \
        build-tags source duplicate crlf missing; do
        assert_bad_build_info "$checksum_tmp/BUILD_INFO.$bad"
    done
)

# T10/A10：无 schema 旧配置不得默认视为已安装活节点（INSTALL_COMPLETE 保守为 false）。
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-noschema.conf"
    cat > "$CONFIG_FILE" <<'EOF'
PORT=443
UUID=0fe4575e-644a-4b16-877d-0ddf493bc1d1
HY2_ENABLED=true
HY2_PORT=8444
EOF
    load_config_with_defaults
    [ "$INSTALL_COMPLETE" = "false" ] || {
        echo "No-schema config must not default to INSTALL_COMPLETE=true." >&2
        exit 1
    }
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=6
PORT=443
UUID=0fe4575e-644a-4b16-877d-0ddf493bc1d1
EOF
    load_config_with_defaults
    [ "$INSTALL_COMPLETE" = "true" ] || {
        echo "Schema config must keep INSTALL_COMPLETE=true default." >&2
        exit 1
    }
    rm -f "$CONFIG_FILE"
)

# T10/B1：掩码凭据回归——旧版单文件 rr 会把掩码（首6+...+尾4，如 3b6007...2114）
# 写进 /etc/argo_vmess.conf；掩码必须被识别、重生成真值并回写，永不进入配置。
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-mask.conf"
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=7
PORT=443
UUID=3b6007...2114
NAIVE_ENABLED=true
NAIVE_USER=abc123...a1b2
NAIVE_PASS=987654...wxyz
EOF
    load_config_with_defaults
    is_masked_credential "$UUID" || { echo "Masked UUID not detected." >&2; exit 1; }
    is_masked_credential "$NAIVE_USER" || { echo "Masked NAIVE_USER not detected." >&2; exit 1; }
    is_masked_credential "$NAIVE_PASS" || { echo "Masked NAIVE_PASS not detected." >&2; exit 1; }
    is_masked_credential "3b6007...2114" || { echo "Strict mask pattern not detected." >&2; exit 1; }
    if is_masked_credential "0fe4575e-644a-4b16-877d-0ddf493bc1d1"; then
        echo "Real UUID flagged as masked." >&2
        exit 1
    fi
    if is_masked_credential ""; then
        echo "Empty value flagged as masked." >&2
        exit 1
    fi
    ensure_credential_integrity
    is_valid_uuid "$UUID" || { echo "UUID was not regenerated to a real value." >&2; exit 1; }
    if is_masked_credential "$NAIVE_USER"; then
        echo "NAIVE_USER still masked." >&2
        exit 1
    fi
    if is_masked_credential "$NAIVE_PASS"; then
        echo "NAIVE_PASS still masked." >&2
        exit 1
    fi
    [ "$(grep '^UUID=' "$CONFIG_FILE" | cut -d= -f2)" = "$UUID" ] || {
        echo "Regenerated UUID was not written back to the config file." >&2
        exit 1
    }
    if grep -q '\.\.\.' "$CONFIG_FILE"; then
        echo "Mask still present in config file." >&2
        exit 1
    fi
    rm -f "$CONFIG_FILE"
)

post_update_function=$(awk '
    /^post_update_migrate\(\) \{/ { capture = 1; depth = 0 }
    capture {
        print
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        if (depth == 0) exit
    }
' modules/60-update.sh)
(
    eval "$post_update_function"
    CONFIG_FILE="/tmp/rr-incomplete-config"
    : > "$CONFIG_FILE"
    check_supported_os() { return 0; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() { INSTALL_COMPLETE=false; return 0; }
    any_node_protocol_enabled() { return 1; }
    systemctl() { return 0; }
    stop_subscription_servers() { return 0; }
    sleep() { :; }
    post_update_migrate
    rm -f "$CONFIG_FILE"
)
(
    eval "$post_update_function"
    CONFIG_FILE="/tmp/rr-missing-config"
    rm -f "$CONFIG_FILE"
    check_supported_os() { return 0; }
    systemctl() {
        echo "Missing RR config triggered a service operation." >&2
        return 1
    }
    post_update_migrate
)

echo "[6/13] Subscription URL control-character regression"
(
    load_modules_for_tests
    rr_security_tmp=$(mktemp -d)
    mkdir "$rr_security_tmp/victim" "$rr_security_tmp/backup"
    printf '%s\n' protected > "$rr_security_tmp/victim/marker"
    ln -s "$rr_security_tmp/victim" "$rr_security_tmp/sub-root"
    SUB_ROOT="$rr_security_tmp/sub-root"
    if ensure_subscription_root >/dev/null 2>&1; then
        echo "Symlink subscription root was accepted." >&2
        exit 1
    fi
    [ "$(cat "$rr_security_tmp/victim/marker")" = protected ]
    [ -z "$(find "$rr_security_tmp/victim" -mindepth 1 ! -name marker -print -quit)" ]
    # 事务备份同样必须在读取目录内容前拒绝符号链接。
    rr_backup_dir_function=$(awk '
        /^rr_backup_dir\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' scripts/install-core.sh)
    eval "$rr_backup_dir_function"
    BACKUP_DIR="$rr_security_tmp/backup"
    rr_error() { :; }
    if rr_backup_dir "$SUB_ROOT" subscription; then
        echo "Updater backed up a symlink subscription root." >&2
        exit 1
    fi
    rm -rf "$rr_security_tmp"
    [ "$SUB_PID_FILE" = /run/rr-vps-subscription.pid ]
    [ "$SUB_BIND_STATE_FILE" = /run/rr-vps-subscription.bind ]
    [ "$ARGO_PID_FILE" = /run/rr-vps-argo-cloudflared.pid ]
    grep -Fq 'root_stat = os.lstat(SUB_ROOT)' modules/90-auto-update.sh

    # 常驻订阅进程必须在 sub_server.py 内容变化时重启。旧实现只比较
    # 端口和监听地址，导致热更新文件已替换但进程仍执行旧代码。
    rr_restart_tmp=$(mktemp -d)
    RR_LIB_DIR="$rr_restart_tmp/lib"
    SUB_ROOT="$rr_restart_tmp/root"
    SUB_PID_FILE="$rr_restart_tmp/sub.pid"
    SUB_BIND_STATE_FILE="$rr_restart_tmp/sub.bind"
    SUB_PORT=39291
    SUB_BIND_ADDRESS=127.0.0.1
    SUB_ACCESS_MODE=local
    SUB_DOMAIN=""
    SUB_TOKEN=0123456789abcdefghijklmnopqrstuv
    mkdir -p "$RR_LIB_DIR/nexus" "$SUB_ROOT"
    ensure_subscription_root() { return 0; }
    printf '%s\n' 'print("old")' > "$RR_LIB_DIR/nexus/sub_server.py"
    rr_old_signature=$(sha256sum "$RR_LIB_DIR/nexus/sub_server.py" | awk '{print $1}')
    printf '%s\n' 4242 > "$SUB_PID_FILE"
    printf '%s\n' "${SUB_PORT}|${SUB_BIND_ADDRESS}|local||${rr_old_signature}|local-http" > "$SUB_BIND_STATE_FILE"
    printf '%s\n' 'print("new")' > "$RR_LIB_DIR/nexus/sub_server.py"
    kill() { printf '%s\n' "$1" > "$rr_restart_tmp/killed"; }
    sleep() { :; }
    is_subscription_pid() { return 0; }
    nohup() { : > "$rr_restart_tmp/launched"; }
    start_subscription_server
    rr_new_signature=$(sha256sum "$RR_LIB_DIR/nexus/sub_server.py" | awk '{print $1}')
    [ "$(cat "$rr_restart_tmp/killed")" = 4242 ]
    [ -f "$rr_restart_tmp/launched" ]
    [ "$(cat "$SUB_BIND_STATE_FILE")" = "${SUB_PORT}|${SUB_BIND_ADDRESS}|local||${rr_new_signature}|local-http" ]
    rm -rf "$rr_restart_tmp"

    test_uuid="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
    UUID="$test_uuid"
    url=$(build_subscription_url "45.192.205.71" 39291 "$test_uuid" jhsub_encoded.txt)
    [ "$url" = "http://127.0.0.1:39291/${test_uuid}/jhsub_encoded.txt" ]
    encoded_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" encoded)
    raw_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" raw)
    client_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" client)
    clash_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" clash)
    mihomo_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" mihomo)
    verge_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" clash-verge)
    flclash_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" flclash)
    [ "$encoded_short_url" = "http://127.0.0.1:39291/s/${SUB_TOKEN}" ]
    [ "$raw_short_url" = "http://127.0.0.1:39291/r/${SUB_TOKEN}" ]
    [ "$client_short_url" = "http://127.0.0.1:39291/c/${SUB_TOKEN}" ]
    [ "$clash_short_url" = "http://127.0.0.1:39291/m/${SUB_TOKEN}" ]
    [ "$mihomo_short_url" = "http://127.0.0.1:39291/mm/${SUB_TOKEN}" ]
    [ "$verge_short_url" = "http://127.0.0.1:39291/vg/${SUB_TOKEN}" ]
    [ "$flclash_short_url" = "http://127.0.0.1:39291/fc/${SUB_TOKEN}" ]
    [ "${#encoded_short_url}" -lt "${#url}" ]
    SUB_ACCESS_MODE=https
    SUB_DOMAIN=sub.example.com
    [ "$(build_short_subscription_url '45.192.205.71' 443 "$test_uuid" raw)" = \
        "https://sub.example.com:443/r/${SUB_TOKEN}" ]
    [ "$(build_subscription_url '45.192.205.71' 443 "$test_uuid" jhsub.txt)" = \
        "https://sub.example.com:443/${test_uuid}/jhsub.txt" ]
    SUB_DOMAIN=""
    if build_short_subscription_url '45.192.205.71' 443 "$test_uuid" raw >/dev/null 2>&1; then
        echo "HTTPS subscription URL was emitted without a trusted domain." >&2
        exit 1
    fi
    SUB_ACCESS_MODE=local
    SUB_ROOT=$(mktemp -d)
    mkdir -p "$SUB_ROOT/$UUID"
    printf '%s' 'dGVzdA==' > "$SUB_ROOT/$UUID/jhsub_encoded.txt"
    printf '%s\n' 'vless://test' > "$SUB_ROOT/$UUID/jhsub.txt"
    printf '%s\n' '{}' > "$SUB_ROOT/$UUID/client.json"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/clash_meta.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-mihomo.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-clash-verge.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-flclash.yaml"
    create_short_subscription_alias
    short_token=$(subscription_short_token "$UUID")
    [ "$(readlink "$SUB_ROOT/s/$short_token")" = "../${UUID}/jhsub_encoded.txt" ]
    [ "$(readlink "$SUB_ROOT/r/$short_token")" = "../${UUID}/jhsub.txt" ]
    [ "$(readlink "$SUB_ROOT/c/$short_token")" = "../${UUID}/client.json" ]
    [ "$(readlink "$SUB_ROOT/m/$short_token")" = "../${UUID}/clash_meta.yaml" ]
    [ "$(readlink "$SUB_ROOT/mm/$short_token")" = "../${UUID}/client-mihomo.yaml" ]
    [ "$(readlink "$SUB_ROOT/vg/$short_token")" = "../${UUID}/client-clash-verge.yaml" ]
    [ "$(readlink "$SUB_ROOT/fc/$short_token")" = "../${UUID}/client-flclash.yaml" ]
    [ -f "$SUB_ROOT/index.html" ]
    for route in s r c m mm vg fc; do
        [ -f "$SUB_ROOT/$route/index.html" ]
    done
    rm -f "$SUB_ROOT/$UUID/clash_meta.yaml"
    create_short_subscription_alias
    [ ! -e "$SUB_ROOT/m/$short_token" ]
    rm -rf "$SUB_ROOT"
    if build_subscription_url $'45.192.\n205.71' 39291 "$test_uuid" jhsub.txt >/dev/null 2>&1; then
        echo "Control character in subscription host was accepted." >&2
        exit 1
    fi
    cert_test_root=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj '/CN=RR test root' \
        -keyout "$cert_test_root/ca.key" -out "$cert_test_root/ca.crt" \
        >/dev/null 2>&1
    RR_CA_BUNDLE="$cert_test_root/ca.crt"
    openssl req -newkey rsa:2048 -nodes -subj '/CN=sub.example.com' \
        -addext 'subjectAltName=DNS:sub.example.com' \
        -keyout "$cert_test_root/good.key" -out "$cert_test_root/good.csr" \
        >/dev/null 2>&1
    cat > "$cert_test_root/server.ext" <<'EOF'
subjectAltName=DNS:sub.example.com
extendedKeyUsage=serverAuth
EOF
    openssl x509 -req -days 30 -in "$cert_test_root/good.csr" \
        -CA "$cert_test_root/ca.crt" -CAkey "$cert_test_root/ca.key" \
        -CAcreateserial -extfile "$cert_test_root/server.ext" \
        -out "$cert_test_root/good-leaf.crt" >/dev/null 2>&1
    cat "$cert_test_root/good-leaf.crt" "$cert_test_root/ca.crt" \
        > "$cert_test_root/good.crt"
    subscription_certificate_pair_valid "$cert_test_root/good.crt" \
        "$cert_test_root/good.key" sub.example.com
    if subscription_certificate_pair_valid "$cert_test_root/good.crt" \
        "$cert_test_root/good.key" wrong.example.com; then
        echo "Subscription certificate with the wrong SAN was accepted." >&2
        exit 1
    fi
    openssl req -newkey rsa:2048 -nodes -subj '/CN=sub.example.com' \
        -keyout "$cert_test_root/short.key" -out "$cert_test_root/short.csr" \
        >/dev/null 2>&1
    openssl x509 -req -days 1 -in "$cert_test_root/short.csr" \
        -CA "$cert_test_root/ca.crt" -CAkey "$cert_test_root/ca.key" \
        -CAcreateserial -extfile "$cert_test_root/server.ext" \
        -out "$cert_test_root/short-leaf.crt" >/dev/null 2>&1
    cat "$cert_test_root/short-leaf.crt" "$cert_test_root/ca.crt" \
        > "$cert_test_root/short.crt"
    if subscription_certificate_pair_valid "$cert_test_root/short.crt" \
        "$cert_test_root/short.key" sub.example.com; then
        echo "Subscription certificate expiring within seven days was accepted." >&2
        exit 1
    fi
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj '/CN=sub.example.com' -addext 'subjectAltName=DNS:sub.example.com' \
        -keyout "$cert_test_root/self.key" -out "$cert_test_root/self.crt" \
        >/dev/null 2>&1
    if subscription_certificate_pair_valid "$cert_test_root/self.crt" \
        "$cert_test_root/self.key" sub.example.com; then
        echo "Self-signed subscription certificate was accepted as publicly trusted." >&2
        exit 1
    fi
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$cert_test_root/mismatch.key" >/dev/null 2>&1
    if subscription_certificate_pair_valid "$cert_test_root/good.crt" \
        "$cert_test_root/mismatch.key" sub.example.com; then
        echo "Subscription certificate with a mismatched private key was accepted." >&2
        exit 1
    fi
    rm -rf "$cert_test_root"
    qr_payload='vless://test@example.com:443?security=reality#RR-test'
    qrencode() {
        [ "$#" -eq 8 ] && [ "$1" = "-t" ] && [ "$2" = "ANSIUTF8" ] && \
            [ "$3" = "-l" ] && [ "$4" = "M" ] && [ "$5" = "-m" ] && \
            [ "$6" = "4" ] && [ "$7" = "--" ] && [ "$8" = "$qr_payload" ]
    }
    # shellcheck disable=SC2317
    render_terminal_qr "$qr_payload" "VLESS Reality 节点" >/dev/null
)

echo "[7/13] Ubuntu 22.04 Python and Argon2 compatibility"
if grep -En 'from datetime import.*\bUTC\b|datetime\.now\(UTC\)' nexus/rr_nexus.py; then
    echo "Python 3.11-only datetime.UTC usage was found." >&2
    exit 1
fi
argon2_stub=$(mktemp -d)
mkdir -p "$argon2_stub/argon2"
cat > "$argon2_stub/argon2/__init__.py" <<'PY'
class PasswordHasher:
    def __init__(self, *args, **kwargs):
        pass

    def hash(self, password):
        return "$argon2id$test"

    def verify(self, password_hash, password):
        return True

    def check_needs_rehash(self, password_hash):
        return False
PY
cat > "$argon2_stub/argon2/exceptions.py" <<'PY'
class InvalidHash(Exception):
    pass

class VerifyMismatchError(Exception):
    pass
PY
nexus_pythonpath="$argon2_stub:$PWD/nexus"
PYTHONPATH="$nexus_pythonpath" python3 nexus/rr_nexus.py --help >/dev/null
argon2_config="$argon2_stub/nexus.json"
argon2_db="$argon2_stub/nexus.db"
jq -n --arg database "$argon2_db" --arg subscriptions "$argon2_stub/subscriptions" \
    '{mode:"local",listen:"127.0.0.1",port:7900,domain:"",database:$database,subscription_root:$subscriptions}' \
    > "$argon2_config"
init_output=$(printf '%s\n' 'StrongPassword123!' | \
    PYTHONPATH="$nexus_pythonpath" RR_NEXUS_CONFIG="$argon2_config" \
    python3 nexus/rr_nexus.py --init-admin tester)
[[ "$init_output" == RR_NEXUS_RECOVERY_CODES=* ]]
recovery_payload="${init_output#RR_NEXUS_RECOVERY_CODES=}"
IFS=',' read -r -a recovery_values <<< "$recovery_payload"
[ "${#recovery_values[@]}" -eq 8 ]
for recovery_value in "${recovery_values[@]}"; do
    [[ "$recovery_value" =~ ^[A-F0-9]{32}$ ]]
done
PYTHONPATH="$nexus_pythonpath" RR_NEXUS_CONFIG="$argon2_config" python3 - "$argon2_db" <<'PY'
import base64
import importlib.util
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    assert connection.execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 1
    columns = {row[1] for row in connection.execute("PRAGMA table_info(devices)")}
    assert {
        "uploaded_bytes", "downloaded_bytes", "traffic_updated_at", "next_reset_at",
        "reset_anchor_day", "reset_max", "reset_count",
    } <= columns
    assert connection.execute("SELECT COUNT(*) FROM server_traffic_policy WHERE id=1").fetchone()[0] == 1

spec = importlib.util.spec_from_file_location("rr_nexus", "nexus/rr_nexus.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Argon2 uses 64 MiB per operation, so HTTP concurrency must not translate to
# unbounded memory concurrency.  Exercise the active limit, timeout response,
# and exception cleanup with a controllable fake hasher.
import threading
import time

real_password_hasher = module.PasswordHasher

class ControlledPasswordHasher:
    def __init__(self, **kwargs):
        self.active = 0
        self.peak = 0
        self.lock = threading.Lock()
        self.two_started = threading.Event()
        self.release = threading.Event()

    def _work(self):
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
            if self.active == 2:
                self.two_started.set()
        try:
            assert self.release.wait(2), "controlled password hash did not resume"
            return True
        finally:
            with self.lock:
                self.active -= 1

    def hash(self, password):
        self._work()
        return "$argon2id$controlled"

    def verify(self, password_hash, password):
        return self._work()

    def check_needs_rehash(self, password_hash):
        return False

module.PasswordHasher = ControlledPasswordHasher
limited_hasher = module.BoundedPasswordHasher(
    max_concurrent=2, max_waiters=1, wait_seconds=0.05
)
hash_errors = []

def run_controlled_hash():
    try:
        limited_hasher.hash("test-password")
    except BaseException as exc:
        hash_errors.append(exc)

hash_threads = [threading.Thread(target=run_controlled_hash) for _ in range(2)]
for thread in hash_threads:
    thread.start()
assert limited_hasher._hasher.two_started.wait(1), "two Argon2 workers did not start"
wait_started = time.monotonic()
try:
    limited_hasher.verify("$argon2id$controlled", "test-password")
except module.PasswordHashBusy:
    pass
else:
    raise AssertionError("Argon2 waiter did not time out")
wait_elapsed = time.monotonic() - wait_started
assert 0.04 <= wait_elapsed < 0.5, wait_elapsed
limited_hasher._hasher.release.set()
for thread in hash_threads:
    thread.join(timeout=1)
assert not hash_errors
assert limited_hasher._hasher.peak == 2

class RaisingPasswordHasher:
    def __init__(self, **kwargs):
        self.calls = 0

    def hash(self, password):
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("controlled hash failure")
        return "$argon2id$recovered"

    def verify(self, password_hash, password):
        return True

    def check_needs_rehash(self, password_hash):
        return False

module.PasswordHasher = RaisingPasswordHasher
exception_hasher = module.BoundedPasswordHasher(
    max_concurrent=1, max_waiters=0, wait_seconds=0.01
)
try:
    exception_hasher.hash("first")
except RuntimeError:
    pass
else:
    raise AssertionError("controlled hash failure was swallowed")
assert exception_hasher.hash("second") == "$argon2id$recovered"
module.PasswordHasher = real_password_hasher

# Overload must not become an invalid-credentials response: callers receive
# the same retryable 503 before any login-failure accounting or account branch.
busy_handler = object.__new__(module.Handler)
busy_handler._dispatch_post = lambda: (_ for _ in ()).throw(module.PasswordHashBusy())
busy_responses = []
busy_handler.send_json = lambda status, payload, headers=None: busy_responses.append(
    (status, payload, headers)
)
busy_handler.do_POST()
assert busy_responses == [
    (
        module.HTTPStatus.SERVICE_UNAVAILABLE,
        {
            "error": "authentication_temporarily_unavailable",
            "message": "身份验证暂时繁忙，请稍后重试。",
        },
        {"Retry-After": "1"},
    )
]

# 超限请求体必须在读取前以 413 拒绝，不能只读一个前缀后把它当成完整
# JSON，也不能在缺少 Content-Length 时阻塞等客户端主动断开。
import io

body_handler = object.__new__(module.Handler)
body_handler.rfile = io.BytesIO(b"{}")
body_handler.headers = {"Content-Length": str(module.MAX_BODY + 1)}
try:
    body_handler.read_json()
except module.RequestBodyTooLarge:
    pass
else:
    raise AssertionError("oversized normal API body was not rejected")
body_handler.headers = {"Content-Length": str(module.MAX_JSON_BODY_BYTES + 1)}
try:
    body_handler.read_json_body()
except module.RequestBodyTooLarge:
    pass
else:
    raise AssertionError("oversized remote/firewall API body was not rejected")
body_handler.headers = {}
assert body_handler.read_json() is None

# 反向代理来源地址只能接受 Nginx 覆盖写入的单个合法 IP。客户端构造的
# X-Forwarded-For 列表不能改变登录限速、远程钥匙限速或审计身份。
from types import SimpleNamespace

module.STATE = SimpleNamespace(config=SimpleNamespace(mode="public"))
ip_handler = object.__new__(module.Handler)
ip_handler.client_address = ("127.0.0.1", 12345)
ip_handler.headers = {"X-Forwarded-For": "8.8.8.8"}
assert ip_handler.remote_ip == "8.8.8.8"
ip_handler.headers = {"X-Forwarded-For": "198.51.100.10, 8.8.8.8"}
assert ip_handler.remote_ip == "127.0.0.1"
ip_handler.headers = {"X-Forwarded-For": "not-an-ip"}
assert ip_handler.remote_ip == "127.0.0.1"

# Webhook 与多服务器管理共用公开 HTTPS 出站门禁：阻止内网、回环、
# 链路本地和混合 DNS；连接必须钉在已校验 IP，且 3xx 不自动跟随。
from rr_nexus_lib import http_security

for unsafe_url in (
    "https://127.0.0.1/hook",
    "https://[::1]/hook",
    "https://169.254.169.254/latest/meta-data/",
    "https://10.0.0.1/hook",
    "https://user@example.com/hook",
    "http://8.8.8.8/hook",
):
    try:
        http_security.public_https_target(unsafe_url)
    except http_security.UnsafeTargetError:
        pass
    else:
        raise AssertionError(f"unsafe outbound target accepted: {unsafe_url}")

def fake_public_resolver(host, port, **kwargs):
    assert host == "hooks.example.com" and port == 9443
    return [(2, 1, 6, "", ("8.8.8.8", port))]

target = http_security.public_https_target(
    "https://hooks.example.com:9443/a/b?event=test", resolver=fake_public_resolver
)
assert target.addresses == ("8.8.8.8",)
assert target.request_target == "/a/b?event=test"

def fake_mixed_resolver(host, port, **kwargs):
    return [
        (2, 1, 6, "", ("8.8.8.8", port)),
        (2, 1, 6, "", ("127.0.0.1", port)),
    ]

try:
    http_security.public_https_target(
        "https://hooks.example.com:9443/hook", resolver=fake_mixed_resolver
    )
except http_security.UnsafeTargetError:
    pass
else:
    raise AssertionError("mixed public/private DNS answers were accepted")

connections = []
class FakeResponse:
    status = 302
    def getheader(self, name):
        return None
    def read(self, size):
        return b"redirect not followed"

class FakePinnedConnection:
    def __init__(self, host, port, connect_ip, timeout):
        connections.append((host, port, connect_ip, timeout))
    def request(self, method, path, body, headers):
        assert (method, path, body) == ("POST", "/hook", b"{}")
    def getresponse(self):
        return FakeResponse()
    def close(self):
        pass

real_pinned_connection = http_security._PinnedHTTPSConnection
http_security._PinnedHTTPSConnection = FakePinnedConnection
try:
    status, response_body = http_security.https_post(
        "https://hooks.example.com:9443/hook",
        b"{}",
        {"Content-Type": "application/json"},
        resolver=fake_public_resolver,
    )
finally:
    http_security._PinnedHTTPSConnection = real_pinned_connection
assert status == 302 and response_body == b"redirect not followed"
assert connections == [("hooks.example.com", 9443, "8.8.8.8", 10)]

status, remote_error = module.Handler.remote_http_call(
    "127.0.0.1", 443, "invalid", "GET", "/api/overview", None
)
assert status == 0 and remote_error["error"] == "unsafe_remote_target"

def field(number, wire, value):
    return module.encode_varint((number << 3) | wire) + value

def stat(name, value):
    encoded_name = name.encode()
    message = field(1, 2, module.encode_varint(len(encoded_name)) + encoded_name)
    message += field(2, 0, module.encode_varint(value))
    return field(1, 2, module.encode_varint(len(message)) + message)

payload = stat("user>>>dev_012345abcdef>>>traffic>>>uplink", 123)
payload += stat("user>>>dev_012345abcdef>>>traffic>>>downlink", 456)
payload += stat("inbound>>>ignored>>>traffic>>>uplink", 999)
counters = module.parse_query_stats_response(payload)
assert counters["user>>>dev_012345abcdef>>>traffic>>>uplink"] == 123
assert counters["user>>>dev_012345abcdef>>>traffic>>>downlink"] == 456
assert counters["inbound>>>ignored>>>traffic>>>uplink"] == 999

class FakeChannel:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def unary_unary(self, method, **kwargs):
        assert method == module.V2RAY_QUERY_METHOD
        assert kwargs["request_serializer"](b"x") == b"x"
        return self.call

    def call(self, request, timeout):
        assert request == b"\x10\x01\x1a\x07user>>>"
        assert timeout == 2.5
        return payload

class FakeGrpc:
    @staticmethod
    def insecure_channel(address):
        assert address == "127.0.0.1:39091"
        return FakeChannel()

module.grpc = FakeGrpc()
assert module.query_v2ray_stats("127.0.0.1:39091") == counters

config = module.NexusConfig.load()
assert config.port == 7900 and config.stats_port == 39091
assert config.ssh_host == "服务器IP"

# 二维码回归：域名模式必须走真证书 HTTPS；公网 IP/本地模式必须走主
# 订阅 HTTP 服务及其 NAT 公网端口；IPv6 URL 必须带方括号。
from pathlib import Path
from types import SimpleNamespace

config_path = Path(module.CONFIG_PATH)
base_config = {
    "listen": "127.0.0.1",
    "port": 7900,
    "database": sys.argv[1],
    "subscription_root": str(config_path.parent / "subscriptions"),
    "published_subscription_root": str(config_path.parent / "published" / "nexus"),
    "stats_port": 39091,
    "public_port": 9443,
    "sub_port": 39291,
    "subscription_access_mode": "local",
    "subscription_domain": "",
}
device = {
    "id": "dev_012345abcdef",
    "subscription_token": "test_subscription_token_123456",
    "enabled": 1,
    "expires_at": None,
    "quota_bytes": 0,
    "used_bytes": 0,
    "uploaded_bytes": 123,
    "downloaded_bytes": 456,
}
handler = object.__new__(module.Handler)
artifact_root = config_path.parent / "subscriptions"
artifact_root.mkdir(parents=True, exist_ok=True)
published_root = config_path.parent / "published" / "nexus"
published_root.mkdir(parents=True, exist_ok=True)
artifact_suffixes = [
    "-vl.json", ".yaml", "-mihomo.yaml", "-clash-verge.yaml", "-flclash.yaml",
    "-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt", ".txt", ".json",
]
for suffix in artifact_suffixes:
    (artifact_root / f"{device['id']}{suffix}").write_text("test", encoding="utf-8")
    (published_root / f"{device['subscription_token']}{suffix}").write_text("test", encoding="utf-8")

def write_config(**values):
    payload = dict(base_config)
    payload.update(values)
    config_path.write_text(json.dumps(payload), encoding="utf-8")
    module.STATE = SimpleNamespace(config=module.NexusConfig.load())

write_config(mode="local", domain="", ssh_host="2001:db8::99")
local_primary, local_urls = handler._device_subscription_urls(device)
assert local_primary == "http://127.0.0.1:39291/nexus/test_subscription_token_123456.txt"
assert len(local_urls) == 9
assert [item["format"] for item in local_urls] == [
    "Sing-box 官方", "mihomo", "Clash Verge", "FlClash", "v2rayN",
    "v2rayNG", "Shadowrocket", "NekoBox", "通用链接",
]
assert all(item["url"].startswith("http://127.0.0.1:39291/nexus/") for item in local_urls)
# 不存在的格式不能继续显示一个注定 404 的二维码。
(published_root / f"{device['subscription_token']}.json").unlink()
assert all(item["format"] != "Sing-box 官方" for item in handler._device_subscription_urls(device)[1])
(published_root / f"{device['subscription_token']}.json").write_text("test", encoding="utf-8")

write_config(mode="public", domain="45.192.205.71", ssh_host="45.192.205.71")
ip_primary, ip_urls = handler._device_subscription_urls(device)
assert ip_primary == "" and ip_urls == []

write_config(
    mode="public",
    domain="45.192.205.71",
    ssh_host="45.192.205.71",
    subscription_access_mode="https",
    subscription_domain="subscribe.example.com",
)
https_primary, https_urls = handler._device_subscription_urls(device)
assert https_primary == (
    "https://subscribe.example.com:39291/nexus/test_subscription_token_123456.txt"
)
assert all(item["url"].startswith("https://subscribe.example.com:39291/nexus/") for item in https_urls)

# 本地模式地址必须能经 SSH 转发后的 127.0.0.1 端口逐一下载，且内容与
# 刚发布的文件完全一致（覆盖 NekoBox 的 Base64 地址）。
import functools
import http.client
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import urllib.request

sub_spec = importlib.util.spec_from_file_location("rr_sub_server", "nexus/sub_server.py")
sub_module = importlib.util.module_from_spec(sub_spec)
sys.modules[sub_spec.name] = sub_module
sub_spec.loader.exec_module(sub_module)

# 真实 TLS 回归：服务端只能启用 TLS >=1.2；系统信任指定证书且 SNI/SAN
# 正确时可下载，明文 HTTP 打到同一公网端口不能得到订阅正文。
tls_root = Path(tempfile.mkdtemp(prefix="rr-sub-tls-"))
tls_key = tls_root / "server.key"
tls_cert = tls_root / "server.crt"
subprocess.run(
    [
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
        "-subj", "/CN=sub.example.test", "-addext", "subjectAltName=DNS:sub.example.test",
        "-keyout", str(tls_key), "-out", str(tls_cert),
    ],
    check=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
(tls_root / "index.html").write_text("tls-only", encoding="utf-8")
tls_policy = sub_module.build_tls_context(str(tls_cert), str(tls_key))
assert tls_policy.minimum_version == ssl.TLSVersion.TLSv1_2
tls_handler = functools.partial(sub_module.SubscriptionHandler, directory=str(tls_root))
tls_server = sub_module.BoundedThreadingHTTPServer(
    ("127.0.0.1", 0), tls_handler, ssl_context=tls_policy
)
tls_server.config_path = config_path
tls_thread = threading.Thread(target=tls_server.serve_forever, daemon=True)
tls_thread.start()
try:
    client_policy = ssl.create_default_context(cafile=str(tls_cert))
    with socket.create_connection(("127.0.0.1", tls_server.server_port), timeout=2) as raw:
        with client_policy.wrap_socket(raw, server_hostname="sub.example.test") as secure:
            assert secure.version() in {"TLSv1.2", "TLSv1.3"}
            secure.sendall(
                b"GET /index.html HTTP/1.1\r\nHost: sub.example.test\r\nConnection: close\r\n\r\n"
            )
            response = b""
            while True:
                chunk = secure.recv(4096)
                if not chunk:
                    break
                response += chunk
    assert b" 200 " in response.split(b"\r\n", 1)[0] and response.endswith(b"tls-only")
    assert b"Cache-Control: no-store, private, max-age=0\r\n" in response
    assert b"Pragma: no-cache\r\n" in response
    with socket.create_connection(("127.0.0.1", tls_server.server_port), timeout=2) as plain:
        plain.sendall(b"GET /index.html HTTP/1.0\r\n\r\n")
        try:
            cleartext_response = plain.recv(4096)
        except (ConnectionResetError, socket.timeout):
            cleartext_response = b""
    assert b"tls-only" not in cleartext_response
finally:
    tls_server.shutdown()
    tls_server.server_close()
    tls_thread.join(timeout=2)
    shutil.rmtree(tls_root)

with sqlite3.connect(sys.argv[1]) as connection:
    now = module.utc_now()
    connection.execute(
        "INSERT OR REPLACE INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,?,?,?, ?,?,?,?)",
        (
            device["id"], "订阅头测试", "sub-header-credential", device["subscription_token"],
            1000, 579, device["uploaded_bytes"], device["downloaded_bytes"], "2030-01-31", now, now,
        ),
    )
static_handler = functools.partial(sub_module.SubscriptionHandler, directory=str(published_root.parent))
static_server = sub_module.ThreadingHTTPServer(("127.0.0.1", 0), static_handler)
static_server.config_path = config_path
static_thread = threading.Thread(target=static_server.serve_forever, daemon=True)
static_thread.start()
try:
    # 主订阅、恢复订阅与 UUID 静态路由都经过 SimpleHTTPRequestHandler；
    # no-store 必须由统一 end_headers 覆盖，包括条件请求产生的 304。
    cache_probe = published_root.parent / "s" / "cache-probe.txt"
    cache_probe.parent.mkdir(parents=True, exist_ok=True)
    cache_probe.write_text("secret", encoding="utf-8")
    cache_connection = http.client.HTTPConnection(
        "127.0.0.1", static_server.server_port, timeout=2
    )
    cache_connection.request("GET", "/s/cache-probe.txt")
    cache_response = cache_connection.getresponse()
    assert cache_response.status == 200 and cache_response.read() == b"secret"
    assert cache_response.getheader("Cache-Control") == "no-store, private, max-age=0"
    assert cache_response.getheader("Pragma") == "no-cache"
    cache_connection.close()
    cache_connection = http.client.HTTPConnection(
        "127.0.0.1", static_server.server_port, timeout=2
    )
    cache_connection.request(
        "GET", "/s/cache-probe.txt",
        headers={"If-Modified-Since": "Wed, 31 Dec 2099 23:59:59 GMT"},
    )
    cache_response = cache_connection.getresponse()
    assert cache_response.status == 304 and cache_response.read() == b""
    assert cache_response.getheader("Cache-Control") == "no-store, private, max-age=0"
    assert cache_response.getheader("Pragma") == "no-cache"
    cache_connection.close()

    write_config(
        mode="local",
        domain="",
        ssh_host="127.0.0.1",
        sub_port=static_server.server_port,
    )
    live_ip_primary, live_ip_urls = handler._device_subscription_urls(device)
    assert live_ip_primary.startswith(f"http://127.0.0.1:{static_server.server_port}/nexus/")
    for item in live_ip_urls:
        with urllib.request.urlopen(item["url"], timeout=2) as response:
            assert response.status == 200 and response.read() == b"test"
            assert response.headers["Subscription-Userinfo"] == (
                "upload=123; download=456; total=1000; expire=1896134399"
            )
            assert response.headers["Profile-Update-Interval"] == "1"
            assert response.headers["Cache-Control"] == "no-store, private, max-age=0"
            assert response.headers["Pragma"] == "no-cache"

    # 有效订阅应在响应时动态插入首位信息项，源文件保持不变。URI/Base64
    # 使用 127.0.0.1:9 的 VMess 标记，确保 NekoBox 开启按“地址+端口+类型”
    # 去重后仍保留；Sing-box 与 mihomo 使用可连接的真实节点副本。
    info_raw = b"vless://id@example.com:443?security=reality#REAL\n"
    info_json = json.dumps({
        "outbounds": [
            {"type": "vless", "tag": "REAL", "server": "example.com", "server_port": 443, "uuid": "id"},
            {"type": "selector", "tag": "proxy", "default": "REAL", "outbounds": ["REAL"]},
        ]
    }).encode()
    info_yaml = b'''proxies:\n  - name: "REAL"\n    type: vless\n    server: example.com\n    port: 443\n\nproxy-groups:\n  - name: select\n    type: select\n    proxies:\n      - "REAL"\n'''
    (published_root / f"{device['subscription_token']}.txt").write_bytes(info_raw)
    for suffix in ("-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt"):
        (published_root / f"{device['subscription_token']}{suffix}").write_bytes(base64.b64encode(info_raw))
    (published_root / f"{device['subscription_token']}.json").write_bytes(info_json)
    (published_root / f"{device['subscription_token']}-mihomo.yaml").write_bytes(info_yaml)
    url_by_format = {item["format"]: item["url"] for item in live_ip_urls}

    def decode_info_marker(line):
        assert line.startswith("vmess://")
        encoded = line.removeprefix("vmess://")
        return json.loads(base64.b64decode(encoded + "=" * (-len(encoded) % 4)))

    with urllib.request.urlopen(url_by_format["通用链接"], timeout=2) as response:
        info_text = response.read().decode()
        info_lines = info_text.splitlines()
        assert info_lines[1].startswith("vless://") and len(info_lines) == 2
        marker = decode_info_marker(info_lines[0])
        assert marker["ps"].startswith("流量信息(勿选)｜已用")
        assert marker["add"] == "127.0.0.1" and marker["port"] == "9"
    for client_name in ("v2rayN", "v2rayNG", "Shadowrocket", "NekoBox"):
        with urllib.request.urlopen(url_by_format[client_name], timeout=2) as response:
            client_lines = base64.b64decode(response.read()).decode().splitlines()
            assert client_lines[1].startswith("vless://") and len(client_lines) == 2
            marker = decode_info_marker(client_lines[0])
            assert marker["ps"].startswith("流量信息(勿选)｜已用")
            # NekoBox 的去重键是协议类型+地址+端口；该组合必须与真实节点不同。
            assert (marker["add"], marker["port"]) == ("127.0.0.1", "9")
    with urllib.request.urlopen(url_by_format["Sing-box 官方"], timeout=2) as response:
        singbox_info = json.loads(response.read())
        assert singbox_info["outbounds"][0]["tag"].startswith("流量信息(勿选)｜已用")
        assert singbox_info["outbounds"][0]["server"] == "example.com"
        assert singbox_info["outbounds"][2]["outbounds"][0].startswith("流量信息(勿选)｜已用")
    with urllib.request.urlopen(url_by_format["mihomo"], timeout=2) as response:
        clash_info = response.read().decode()
        assert clash_info.index("流量信息(勿选)｜已用") < clash_info.index("REAL")
        assert clash_info.count("server: example.com") == 2
    assert (published_root / f"{device['subscription_token']}.txt").read_bytes() == info_raw

    # 公网域名路由由 rr_nexus 自身提供，必须和独立 sub_server 产生完全
    # 相同的标记，不能只修本地/公网 IP 模式。
    rr_body = module.enrich_subscription_content(
        base64.b64encode(info_raw), "device-nekobox.txt",
        {"used_bytes": 579, "quota_bytes": 1000, "expires_at": "2030-01-31"},
    )
    rr_lines = base64.b64decode(rr_body).decode().splitlines()
    assert decode_info_marker(rr_lines[0])["add"] == "127.0.0.1"

    # 单向计费时响应头也必须以 used_bytes 为准，否则客户端卡片会把真实
    # 下行量再次相加，和信息节点/面板额度出现不同数字。
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute(
            "UPDATE devices SET used_bytes=123,uploaded_bytes=123,downloaded_bytes=456 WHERE id=?",
            (device["id"],),
        )
    write_config(
        mode="local", domain="", ssh_host="127.0.0.1",
        sub_port=static_server.server_port, traffic_mode="upload",
    )
    with urllib.request.urlopen(url_by_format["NekoBox"], timeout=2) as response:
        assert response.headers["Subscription-Userinfo"] == (
            "upload=123; download=0; total=1000; expire=1896134399"
        )
        marker = decode_info_marker(base64.b64decode(response.read()).decode().splitlines()[0])
        assert "已用123B" in marker["ps"]
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute(
            "UPDATE devices SET used_bytes=579,uploaded_bytes=123,downloaded_bytes=456 WHERE id=?",
            (device["id"],),
        )
    write_config(
        mode="local", domain="", ssh_host="127.0.0.1",
        sub_port=static_server.server_port, traffic_mode="both",
    )

    # 额度用尽后仍返回空订阅和用量头，让客户端更新剩余流量，同时节点已被撤销。
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute("UPDATE devices SET used_bytes=quota_bytes WHERE id=?", (device["id"],))
    with urllib.request.urlopen(live_ip_primary, timeout=2) as response:
        assert response.status == 200 and response.read() == b""
        assert "total=1000" in response.headers["Subscription-Userinfo"]

    # SimpleHTTPRequestHandler 会在文件访问前折叠 dot-segment。授权判断必须对
    # 规范化路径 fail-closed，否则停用/到期/额度用尽的订阅可用 ../ 绕过。
    for bypass_path in (
        f"/x/../nexus/{device['subscription_token']}.txt",
        f"/x/%2e%2e/nexus/{device['subscription_token']}.txt",
    ):
        connection = http.client.HTTPConnection("127.0.0.1", static_server.server_port, timeout=2)
        connection.request("GET", bypass_path)
        bypass_response = connection.getresponse()
        bypass_body = bypass_response.read()
        connection.close()
        assert bypass_response.status == 404 and b"vless://" not in bypass_body, (
            bypass_path, bypass_response.status, bypass_body[:120]
        )

    # 配置或数据库暂时缺失时，个人订阅必须拒绝服务，不能退回静态文件。
    config_backup = config_path.read_bytes()
    config_path.write_text(json.dumps({"database": str(config_path.parent / "missing.db")}), encoding="utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", static_server.server_port, timeout=2)
    connection.request("GET", urllib.parse.urlsplit(live_ip_primary).path)
    missing_db_response = connection.getresponse()
    missing_db_body = missing_db_response.read()
    connection.close()
    assert missing_db_response.status == 503 and b"vless://" not in missing_db_body
    config_path.write_bytes(config_backup)
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute("UPDATE devices SET used_bytes=579 WHERE id=?", (device["id"],))
finally:
    static_server.shutdown()
    static_server.server_close()
    static_thread.join(timeout=2)

write_config(mode="public", domain="panel.example.com", ssh_host="45.192.205.71", public_port=443)
domain_primary, domain_urls = handler._device_subscription_urls(device)
assert domain_primary == "https://panel.example.com/sub/dev_012345abcdef/test_subscription_token_123456/txt"
assert len(domain_urls) == 9
assert [item["url"].rsplit("/", 1)[-1] for item in domain_urls] == [
    "json", "mihomo", "clash-verge", "flclash", "v2rayn",
    "v2rayng", "sr", "nekobox", "txt",
]

# 后端必须把每个节点/订阅的原文完整交给 qrencode，并使用 M 级纠错与
# 4 模块静区；无效订阅 URL、负索引和 qrencode 超时必须受控失败。
links = [
    "vmess://dGVzdA==",
    "vless://test@example.com:443?security=reality#VL",
    "hysteria2://test@example.com:8443?insecure=1#HY2",
    "tuic://test:test@example.com:8444#TUIC",
    "anytls://test@example.com:8445#AnyTLS",
    "naive+https://test:password@example.com:443#Naive",
    "naive+quic://test:password@example.com:443#Naive-H3",
]
links_path = artifact_root / "dev_012345abcdef.txt"
links_path.write_text("\n".join(links) + "\n", encoding="utf-8")
handler.device_record = lambda device_id: device if device_id == device["id"] else None
handler.subscription_file = lambda device_id: links_path
captured = []

def fake_run(argv, **kwargs):
    captured.append((argv, kwargs))
    return SimpleNamespace(returncode=0, stdout=b"\x89PNG\r\n\x1a\nqr")

real_run = module.subprocess.run
module.subprocess.run = fake_run
try:
    for index, expected in enumerate(links):
        status, png = handler._qr_png_bytes(device["id"], {"index": [str(index)]})
        assert status == module.HTTPStatus.OK and png.startswith(b"\x89PNG")
        argv, kwargs = captured[-1]
        assert argv[-2:] == ["--", expected]
        assert argv[argv.index("-l") + 1] == "M"
        assert argv[argv.index("-m") + 1] == "4"
        assert kwargs["timeout"] == 5
    for config_values, mode_urls in (
        ({"mode": "local", "domain": "", "ssh_host": "2001:db8::99"}, local_urls),
        ({"mode": "public", "domain": "45.192.205.71", "ssh_host": "45.192.205.71"}, ip_urls),
        ({"mode": "public", "domain": "panel.example.com", "ssh_host": "45.192.205.71", "public_port": 443}, domain_urls),
    ):
        write_config(**config_values)
        for sub_index, item in enumerate(mode_urls):
            status, _ = handler._qr_png_bytes(device["id"], {"sub_index": [str(sub_index)]})
            assert status == module.HTTPStatus.OK
            assert captured[-1][0][-1] == item["url"]
    assert handler._qr_png_bytes(device["id"], {"sub_index": ["-1"]})[0] == module.HTTPStatus.BAD_REQUEST
    assert handler._qr_png_bytes(device["id"], {"sub_index": ["999"]})[0] == module.HTTPStatus.BAD_REQUEST
    assert handler._qr_png_bytes(device["id"], {"raw": ["https://invalid.example/sub"]})[0] == module.HTTPStatus.BAD_REQUEST
    assert handler._qr_png_bytes(device["id"], {"index": ["-1"]})[0] == module.HTTPStatus.BAD_REQUEST
finally:
    module.subprocess.run = real_run

module.subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(module.subprocess.TimeoutExpired("qrencode", 5))
try:
    assert handler._qr_png_bytes(device["id"], {"index": ["0"]})[0] == module.HTTPStatus.INTERNAL_SERVER_ERROR
finally:
    module.subprocess.run = real_run

# 公网订阅路由必须逐格式返回精确文件，文件缺失时返回 404，绝不能回退
# 到通用 URI 原文冒充 JSON/YAML/Base64 订阅。
route_suffixes = {
    "txt": ".txt",
    "json": ".json",
    "yaml": ".yaml",
    "vl": "-vl.json",
    "mihomo": "-mihomo.yaml",
    "clash-verge": "-clash-verge.yaml",
    "flclash": "-flclash.yaml",
    "v2rayn": "-v2rayn.txt",
    "v2rayng": "-v2rayng.txt",
    "sr": "-sr.txt",
    "nekobox": "-nekobox.txt",
}
sent = []
handler.send_bytes = lambda status, body, content_type, **kwargs: sent.append((status, body, content_type, kwargs))
handler.send_json = lambda status, body: sent.append((status, body, "json"))
for route, suffix in route_suffixes.items():
    expected = ("payload:" + route).encode()
    artifact = artifact_root / f"{device['id']}{suffix}"
    artifact.write_bytes(expected)
    sent.clear()
    handler.handle_public_subscription(device["id"], device["subscription_token"], route)
    assert sent[0][:3] == (module.HTTPStatus.OK, expected, "text/plain; charset=utf-8")
    userinfo = sent[0][3]["extra_headers"]["Subscription-Userinfo"]
    assert userinfo == "upload=0; download=0; total=0; expire=0"

missing = artifact_root / f"{device['id']}-v2rayng.txt"
missing.unlink()
sent.clear()
handler.handle_public_subscription(device["id"], device["subscription_token"], "v2rayng")
assert sent and sent[0][0] == module.HTTPStatus.NOT_FOUND

# 纯备注修改必须只写管理数据库：不得触发流量采集、节点重启或订阅刷新。
store = module.Store(Path(sys.argv[1]))
with store.connect() as db:
    now = module.utc_now()
    db.execute(
        "INSERT OR REPLACE INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,0,0,0,0,NULL,?,?)",
        (device["id"], "旧管理备注", "01234567-89ab-4cde-8fab-0123456789ab", device["subscription_token"], now, now),
    )
    db.execute(
        "INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,0,0,0,0,NULL,?,?)",
        ("dev_deadbeef0000", "已存在备注", "11234567-89ab-4cde-8fab-0123456789ab", "other_subscription_token_123", now, now),
    )

class NoTrafficSync:
    def collect_once(self, **kwargs):
        raise AssertionError("name-only update collected traffic")

module.STATE = SimpleNamespace(config=module.NexusConfig.load(), store=store, traffic=NoTrafficSync())
rename_handler = object.__new__(module.Handler)
rename_handler.client_address = ("127.0.0.1", 12345)
rename_handler.headers = {}
rename_handler.read_json = lambda: {"name": "新管理备注"}
rename_handler._deferred_sync = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("name-only update synced nodes"))
rename_sent = []
rename_handler.send_json = lambda status, body: rename_sent.append((status, body))
rename_handler.handle_update_device({"username": "tester"}, device["id"])
assert rename_sent[-1][0] == module.HTTPStatus.OK
assert rename_sent[-1][1]["sync"] == "not_required"
with store.connect() as db:
    assert db.execute("SELECT name FROM devices WHERE id=?", (device["id"],)).fetchone()[0] == "新管理备注"

rename_handler.read_json = lambda: {"name": "已存在备注"}
rename_handler.handle_update_device({"username": "tester"}, device["id"])
assert rename_sent[-1][0] == module.HTTPStatus.CONFLICT
assert rename_sent[-1][1]["error"] == "duplicate_name"

# 每月自动重置：额度保持原值、用量归零、自然月日期不漂移，次数用尽后
# 由预先计算的 expires_at 到期。35 天宽限常量也必须锁定。
assert module.QUOTA_AUTO_DELETE_SECONDS == 35 * 86400
assert module.add_calendar_month(module.parse_date("2027-01-31"), 31).isoformat() == "2027-02-28"
assert module.add_calendar_month(module.parse_date("2027-02-28"), 31).isoformat() == "2027-03-31"
future = module.datetime.now(module.timezone.utc).date() + module.timedelta(days=10)
schedule_values, schedule_error = handler.validate_device_payload(
    {"name": "计划测试", "quota_gb": 10, "reset_at": future.isoformat(), "reset_max": 6}
)
assert not schedule_error
assert schedule_values["next_reset_at"] == future.isoformat()
assert schedule_values["reset_max"] == 6 and schedule_values["reset_count"] == 0
assert schedule_values["expires_at"] == module.add_calendar_months(future, 6, future.day).isoformat()
_, invalid_schedule = handler.validate_device_payload(
    {"name": "错误计划", "quota_gb": 10, "reset_at": "2020-01-01", "reset_max": 6}
)
assert invalid_schedule == "invalid_reset_schedule"

due = module.datetime.now(module.timezone.utc).date() - module.timedelta(days=1)
plan_expiry = module.add_calendar_months(due, 2, due.day)
with store.connect() as db:
    now = module.utc_now()
    db.execute(
        "INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,next_reset_at,reset_anchor_day,"
        "reset_max,reset_count,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "dev_aabbccddeeff", "月度计划", "monthly-credential", "monthly-sub-token",
            1000, 1000, 400, 600, plan_expiry.isoformat(), due.isoformat(), due.day, 2, 0, now, now,
        ),
    )

class ScheduledState:
    def __init__(self):
        self.store = store
        self.config = module.NexusConfig.load()
        self.sync_count = 0

    def sync_devices(self):
        self.sync_count += 1
        return True, "ok"

scheduled_state = ScheduledState()
collector = module.TrafficCollector(scheduled_state)
collector.apply_scheduled_resets(True)
with store.connect() as db:
    scheduled = db.execute(
        "SELECT quota_bytes,used_bytes,uploaded_bytes,downloaded_bytes,reset_count,next_reset_at "
        "FROM devices WHERE id='dev_aabbccddeeff'"
    ).fetchone()
assert scheduled["quota_bytes"] == 1000
assert scheduled["used_bytes"] == scheduled["uploaded_bytes"] == scheduled["downloaded_bytes"] == 0
assert scheduled["reset_count"] == 1
assert scheduled["next_reset_at"] == module.add_calendar_month(due, due.day).isoformat()
assert scheduled_state.sync_count == 1

# 服务器套餐使用宿主机网卡原始计数器；重启后沿用持久化基线，计数器回绕
# 或服务器重启时只重建基线，不能产生巨额假流量。
samples = iter([
    ("eth0", 1000, 2000),
    ("eth0", 1600, 2900),
    ("eth0", 1700, 3100),
    ("eth0", 50, 60),
])
real_counters = module.read_network_counters
real_interfaces = module.network_interfaces
module.read_network_counters = lambda configured="": next(samples)
module.network_interfaces = lambda: ["eth0"]
try:
    collector.collect_server_traffic()
    collector.collect_server_traffic()
    module.TrafficCollector(scheduled_state).collect_server_traffic()
    module.TrafficCollector(scheduled_state).collect_server_traffic()
finally:
    module.read_network_counters = real_counters
    module.network_interfaces = real_interfaces
with store.connect() as db:
    host = db.execute(
        "SELECT received_bytes,transmitted_bytes FROM server_traffic_policy WHERE id=1"
    ).fetchone()
assert host["received_bytes"] == 700 and host["transmitted_bytes"] == 1100

# 管理员可在不重开计费周期的情况下校准当前已用量。校准会清零历史网卡
# 差值并以输入值重立基线，后续采集只累加新流量；本地/远程共用该处理器。
class PolicyTraffic:
    def __init__(self):
        self.calls = 0

    def collect_server_traffic(self):
        self.calls += 1

policy_traffic = PolicyTraffic()
module.STATE = SimpleNamespace(config=module.NexusConfig.load(), store=store, traffic=policy_traffic)
policy_handler = object.__new__(module.Handler)
policy_handler.client_address = ("127.0.0.1", 12345)
policy_handler.headers = {}
policy_handler.read_json = lambda: {
    "quota_gb": 100,
    "current_used_gb": 50,
    "count_mode": "both",
    "interface_name": "eth0",
}
policy_sent = []
policy_handler.send_json = lambda status, body: policy_sent.append((status, body))
module.network_interfaces = lambda: ["eth0"]
try:
    policy_handler.handle_update_server_traffic_policy({"username": "tester"})
finally:
    module.network_interfaces = real_interfaces
assert policy_sent[-1][0] == module.HTTPStatus.OK
assert policy_sent[-1][1]["policy"]["used_bytes"] == 50 * 1024**3
assert policy_sent[-1][1]["policy"]["quota_bytes"] == 100 * 1024**3
assert policy_sent[-1][1]["policy"]["received_bytes"] == 0
assert policy_sent[-1][1]["policy"]["transmitted_bytes"] == 0
assert policy_traffic.calls == 2
PY
rm -rf "$argon2_stub"

if grep -En 'proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for' modules/85-nexus.sh; then
    echo "Nginx still appends an attacker-controlled X-Forwarded-For value." >&2
    exit 1
fi

echo "[8/13] RR Nexus per-device traffic helpers"
(
    load_modules_for_tests
    nexus_tmp=$(mktemp -d)
    NEXUS_DB_FILE="$nexus_tmp/nexus.db"
    NEXUS_CONFIG_FILE="$nexus_tmp/nexus.json"
    SINGBOX_BIN="$nexus_tmp/sing-box"
    SYS_ARCH=amd64
    write_test_core_identity() {
        local version_line="$1"
        local tags_line="$2"
        local revision_line="$3"
        local cgo_line="$4"
        cat > "$SINGBOX_BIN" <<EOF
#!/bin/sh
printf '%s\n' \\
  'sing-box version ${version_line}' \\
  '' \\
  'Environment: ${NEXUS_CORE_GO_VERSION} linux/${SYS_ARCH}' \\
  'Tags: ${tags_line}' \\
  '${revision_line}' \\
  '${cgo_line}'
EOF
        chmod 755 "$SINGBOX_BIN"
    }

    download_marker="$nexus_tmp/download-called"
    nexus_download_traffic_core() { : > "$download_marker"; return 1; }
    managed_singbox_running() { return 1; }
    build_singbox_config() { SINGBOX_CONFIG_CHANGED=false; return 0; }
    any_node_protocol_enabled() { return 1; }
    ensure_node_service_running() { return 0; }

    # Only the exact native, audited 1.14 identity is retained.  Semver alone
    # is not a trust signal: an older version, a forged high version, missing
    # revision, CGO build, or partial tag set must all enter the verified
    # download/upgrade transaction.
    write_test_core_identity \
        "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: disabled"
    nexus_core_supports_traffic
    nexus_enable_traffic_engine >/dev/null
    [ ! -e "$download_marker" ] || {
        echo "The exact audited sing-box 1.14 core was needlessly replaced." >&2
        exit 1
    }

    assert_core_requires_upgrade() {
        local reason="$1"
        rm -f "$download_marker"
        if nexus_core_supports_traffic; then
            echo "Invalid sing-box identity was accepted: $reason" >&2
            exit 1
        fi
        if nexus_enable_traffic_engine >/dev/null 2>&1; then
            echo "The mocked failed replacement unexpectedly succeeded: $reason" >&2
            exit 1
        fi
        [ -e "$download_marker" ] || {
            echo "Invalid sing-box identity did not trigger upgrade: $reason" >&2
            exit 1
        }
    }

    write_test_core_identity \
        1.13.19 "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: disabled"
    assert_core_requires_upgrade "legacy 1.13.19"
    write_test_core_identity \
        9.9.9 "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: disabled"
    assert_core_requires_upgrade "forged high version"
    write_test_core_identity \
        "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "" "CGO: disabled"
    assert_core_requires_upgrade "missing Revision"
    write_test_core_identity \
        "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: enabled"
    assert_core_requires_upgrade "CGO-enabled binary"
    write_test_core_identity \
        "$NEXUS_CORE_TARGET_VERSION" with_v2ray_api \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: disabled"
    assert_core_requires_upgrade "incomplete build tags"
    write_test_core_identity \
        "$NEXUS_CORE_TARGET_VERSION" "$NEXUS_CORE_EXPECTED_BUILD_TAGS" \
        "Revision: $NEXUS_CORE_SOURCE_COMMIT" "CGO: disabled"
    python3 - "$NEXUS_DB_FILE" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.executescript("""
        CREATE TABLE devices (
          id TEXT PRIMARY KEY, credential TEXT NOT NULL, enabled INTEGER NOT NULL, expires_at TEXT,
          quota_bytes INTEGER NOT NULL, used_bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL
        );
        INSERT INTO devices VALUES ('dev_012345abcdef','01234567-89ab-4cde-8fab-0123456789ab',1,NULL,0,0,'2026-01-01');
        INSERT INTO devices VALUES ('dev_deadbeef0000','11234567-89ab-4cde-8fab-0123456789ab',0,NULL,0,0,'2026-01-02');
        INSERT INTO devices VALUES ('dev_deadbeef0001','21234567-89ab-4cde-8fab-0123456789ab',1,NULL,100,100,'2026-01-03');
    """)
PY
    [ "$(nexus_traffic_user_names)" = '["dev_012345abcdef"]' ]
    jq -n --arg database "$NEXUS_DB_FILE" --arg subscriptions "$nexus_tmp/subscriptions" \
        '{mode:"local",listen:"127.0.0.1",port:7900,domain:"",database:$database,subscription_root:$subscriptions}' \
        > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
    for protocol in vmess vless hysteria2 tuic anytls; do
        nexus_protocol_users "$protocol" 'e219c8c7-b669-4c75-b33b-a9e5227a8a24' | \
            jq -e '.[1].name == "dev_012345abcdef"' >/dev/null
    done
    select_entry_ip() { ENTRY_IP_RAW="45.192.205.71"; return 0; }
    tcp_port_in_use() { return 1; }
    nexus_migrate_runtime_config
    [ "$(jq -r '.stats_port' "$NEXUS_CONFIG_FILE")" = "39091" ]
    [ "$(jq -r '.ssh_host' "$NEXUS_CONFIG_FILE")" = "45.192.205.71" ]
    [ "$(jq -r '.published_subscription_root' "$NEXUS_CONFIG_FILE")" = "/tmp/sub_server/nexus" ]
    [ "$(jq -r '.listen' "$NEXUS_CONFIG_FILE")" = "127.0.0.1" ]
    [ "$(jq -r '.port' "$NEXUS_CONFIG_FILE")" = "7900" ]
    [ "$(jq -r '.database' "$NEXUS_CONFIG_FILE")" = "/var/lib/rr-nexus/nexus.db" ]
    [ "$(jq -r '.subscription_root' "$NEXUS_CONFIG_FILE")" = "/var/lib/rr-nexus/subscriptions" ]
    rm -rf "$nexus_tmp"
)

echo "[9/13] RR Nexus personal subscription compatibility"
(
    load_modules_for_tests
    ensure_subscription_root() { return 0; }
    sub_tmp=$(mktemp -d)
    trap 'rm -rf "$sub_tmp"' EXIT
    NEXUS_DB_FILE="$sub_tmp/nexus.db"
    NEXUS_CONFIG_FILE="$sub_tmp/nexus.json"
    NEXUS_DATA_DIR="$sub_tmp/nexus-data"
    NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
    SUB_ROOT="$sub_tmp/published"
    mkdir -p "$SUB_ROOT"

    UUID="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
    device_credential="01234567-89ab-4cde-8fab-0123456789ab"
    device_id="dev_012345abcdef"
    sub_token="test_subscription_token_123456"
    PORT=20443
    VL_PORT=20444
    HY2_PORT=20445
    TU5_PORT=20446
    AN_PORT=20447
    NAIVE_PORT=20448
    VM_ENABLED=true
    VM_TLS_ENABLED=true
    VL_ENABLED=true
    HY2_ENABLED=true
    TU5_ENABLED=true
    AN_ENABLED=true
    NAIVE_ENABLED=true
    NAIVE_USER=rr-naive
    NAIVE_PASS=server-naive-password
    NAIVE_DOMAIN=naive.example.com
    NAIVE_MODE=both
    NAIVE_QUIC_CC=bbr
    PUBLIC_KEY=test-reality-public-key
    SHORT_ID=0123456789abcdef
    CERT_SHA256=$(printf 'a%.0s' {1..64})
    HY2_HOP_INTERVAL=30s
    HB_ENABLED=true
    HB_INTERVAL=30
    CLASH_ENABLED=true
    CDN_IP=www.bing.com
    ARGO_DOMAIN=argo.example.com
    ARGO_EDGE_PORT=443

    python3 - "$NEXUS_DB_FILE" "$device_id" "$device_credential" "$sub_token" <<'PY'
import sqlite3
import sys

database, device_id, credential, token = sys.argv[1:]
with sqlite3.connect(database) as connection:
    connection.executescript("""
        CREATE TABLE devices (
          id TEXT PRIMARY KEY, credential TEXT NOT NULL, name TEXT NOT NULL,
          subscription_token TEXT NOT NULL, enabled INTEGER NOT NULL,
          expires_at TEXT, quota_bytes INTEGER NOT NULL, used_bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL
        );
    """)
    connection.execute(
        "INSERT INTO devices VALUES (?,?,?,?,1,NULL,0,0,'2026-01-01')",
        (device_id, credential, "NekoBox 测试", token),
    )
PY
    printf '{"mode":"public"}\n' > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"

    load_config_with_defaults() { return 0; }
    validate_subscription_crypto_material() { return 0; }
    select_entry_ip() {
        ENTRY_IP_RAW="45.192.205.71"
        ENTRY_IP_URI="45.192.205.71"
        SUB_URL_PORT=39291
        return 0
    }
    nexus_sync_subscription_endpoint() { return 0; }
    get_hop_ports() { printf '%s\n' '21000:21010'; }

    generate_nexus_device_subscriptions

    raw_file="$NEXUS_SUB_ROOT/${device_id}.txt"
    neko_file="$NEXUS_SUB_ROOT/${device_id}-nekobox.txt"
    [ -s "$raw_file" ] && [ -s "$neko_file" ]
    base64 -d "$neko_file" > "$sub_tmp/nekobox-decoded.txt"
    cmp -s "$raw_file" "$sub_tmp/nekobox-decoded.txt"
    [ "$(wc -l < "$raw_file")" -eq 7 ]
    grep -Eq '^hysteria2://.*obfs=salamander&obfs-password=e219c8c7-b669-4c75-b33b-a9e5227a8a24' "$raw_file"
    grep -Eq '^tuic://.*insecure=1&allow_insecure=1' "$raw_file"
    jq -e --arg credential "$device_credential" '.outbounds[] | select(.type == "vless") | .uuid == $credential' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    jq -e '.outbounds | map(.type) | index("vmess") != null and index("vless") != null and index("hysteria2") != null and index("tuic") != null and index("anytls") != null and index("naive") != null' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    jq -e '.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds | index("naive-h2-RR-012345AB") != null and index("naive-h3-RR-012345AB") != null' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    # 固定 Argo/Naive 的 server 是域名。default_domain_resolver 若指向经
    # proxy detour 的 remote DoH，会在代理尚未建立时形成 DNS 自举闭环。
    jq -e '.dns.final == "remote" and
           (.dns.servers[] | select(.tag == "remote") | .detour == "proxy") and
           .route.default_domain_resolver == "local"' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    grep -Fq 'obfs: salamander' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fq 'obfs-password: "e219c8c7-b669-4c75-b33b-a9e5227a8a24"' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fxq 'keep-alive-idle: 30' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fxq 'keep-alive-interval: 30' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fq 'default-selected: "VMESS-RR-012345AB"' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    if grep -Eq '^    (keep-alive-idle|keep-alive-interval|default):' "$NEXUS_SUB_ROOT/${device_id}.yaml"; then
        echo "mihomo top-level/default fields are nested under a proxy or use the legacy invalid key." >&2
        exit 1
    fi
    for clash_suffix in -mihomo.yaml -clash-verge.yaml -flclash.yaml; do
        cmp -s "$NEXUS_SUB_ROOT/${device_id}.yaml" "$NEXUS_SUB_ROOT/${device_id}${clash_suffix}"
    done
    if command -v ruby >/dev/null 2>&1; then
        ruby -e 'require "yaml"; value=YAML.safe_load(File.read(ARGV[0]), aliases: false); abort unless value.is_a?(Hash) && value["proxies"].is_a?(Array)' \
            "$NEXUS_SUB_ROOT/${device_id}.yaml"
    fi

    python3 - "$raw_file" "$neko_file" "$device_credential" "$UUID" <<'PY'
import base64
import json
import sys
import urllib.parse

raw_path, encoded_path, credential, server_password = sys.argv[1:]
raw = open(raw_path, encoding="utf-8").read()
encoded = open(encoded_path, encoding="utf-8").read()
assert base64.b64decode(encoded).decode() == raw
assert "NekoBox 测试" not in raw
links = {line.split(":", 1)[0]: line for line in raw.splitlines()}
assert set(links) == {"vmess", "vless", "hysteria2", "tuic", "anytls", "naive+https", "naive+quic"}

vmess = json.loads(base64.b64decode(links["vmess"].removeprefix("vmess://")))
assert vmess["id"] == credential and vmess["allowInsecure"] == "1"
assert "RR-012345AB" in vmess["ps"]

def parsed(name):
    return urllib.parse.urlsplit(links[name].replace(f"{name}://", "https://", 1))

vless = parsed("vless")
assert vless.username == credential and urllib.parse.parse_qs(vless.query)["security"] == ["reality"]
hy2 = parsed("hysteria2")
hy2_query = urllib.parse.parse_qs(hy2.query)
assert hy2.username == credential
assert hy2_query["insecure"] == ["1"]
assert hy2_query["obfs-password"] == [server_password]
tuic = parsed("tuic")
assert tuic.username == credential and tuic.password == credential
assert urllib.parse.parse_qs(tuic.query)["allow_insecure"] == ["1"]
anytls = parsed("anytls")
assert anytls.username == credential and urllib.parse.parse_qs(anytls.query)["insecure"] == ["1"]
naive = urllib.parse.urlsplit(links["naive+https"].replace("naive+https://", "https://", 1))
naive_h3 = urllib.parse.urlsplit(links["naive+quic"].replace("naive+quic://", "https://", 1))
assert naive.username.startswith("dev_") and naive.password
assert naive_h3.username == naive.username and naive_h3.password == naive.password
assert urllib.parse.parse_qs(naive_h3.query)["congestion_control"] == ["bbr"]
for parsed_link in (vless, hy2, tuic, anytls, naive, naive_h3):
    assert "RR-012345AB" in urllib.parse.unquote(parsed_link.fragment)
PY

    for suffix in .txt .json .yaml -vl.json -mihomo.yaml -clash-verge.yaml -flclash.yaml -v2rayn.txt -v2rayng.txt -sr.txt -nekobox.txt; do
        cmp -s "$NEXUS_SUB_ROOT/${device_id}${suffix}" "$SUB_ROOT/nexus/${sub_token}${suffix}"
    done

    # NekoBox/Base64 订阅不能依赖 Sing-box/Clash 格式是否生成成功；失败的
    # 格式应从源目录与发布目录同步移除，不能继续暴露旧文件二维码。
    generate_client_json() { return 1; }
    generate_clash_yaml() { return 1; }
    generate_nexus_device_subscriptions
    [ -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" ]
    cmp -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" "$SUB_ROOT/nexus/${sub_token}-nekobox.txt"
    for suffix in .json .yaml -vl.json -mihomo.yaml -clash-verge.yaml -flclash.yaml; do
        [ ! -e "$NEXUS_SUB_ROOT/${device_id}${suffix}" ]
        [ ! -e "$SUB_ROOT/nexus/${sub_token}${suffix}" ]
    done
)

echo "[10/13] Release manifest coverage"
expected_paths=$(mktemp)
manifest_paths=$(mktemp)
trap 'rm -f "$expected_paths" "$manifest_paths"' EXIT
{
    echo rr
    echo scripts/naive-cert-hook.sh
    echo scripts/update-recover.sh
    echo scripts/update-external-state.py
    find modules -maxdepth 1 -type f -name '*.sh' -print
    find nexus -maxdepth 2 -type f \( -name '*.py' -o -name '*.html' -o -name '*.css' -o -name '*.js' \) -print
} | LC_ALL=C sort > "$expected_paths"
awk 'NF == 2 {print $2}' manifest.sha256 | LC_ALL=C sort > "$manifest_paths"
diff -u "$expected_paths" "$manifest_paths"

echo "[11/13] Release hashes"
sha256sum -c manifest.sha256

echo "[12/13] Deterministic release bundle"
python3 scripts/rebuild-bundle.py --check
bundle_paths=$(mktemp)
expected_bundle_paths=$(mktemp)
tar -tzf rr-bundle.tar.gz | LC_ALL=C sort > "$bundle_paths"
{
    sed 's#^#rr-bundle/#' "$manifest_paths"
    echo rr-bundle/manifest.sha256
} | LC_ALL=C sort > "$expected_bundle_paths"
diff -u "$expected_bundle_paths" "$bundle_paths"
rm -f "$bundle_paths" "$expected_bundle_paths"

echo "[13/13] RR Nexus static asset and update contract"
grep -Eq 'id="login-form"' nexus/static/index.html
grep -Eq 'id="device-grid"' nexus/static/index.html
grep -Eq 'id="traffic-chart"' nexus/static/index.html
grep -Eq 'id="ssh-command"' nexus/static/index.html
grep -Fq '面板优选质量不能只看排名' nexus/static/index.html
grep -Fq '适合移动、电信、联通三网优选' nexus/static/index.html
grep -Fq '请把 TOP 20 放进真实客户端逐个测试' nexus/static/index.html
grep -Fq '/optimizer.js?v=11' nexus/static/index.html
grep -Eq '/api/devices' nexus/static/app.js
grep -Eq '/api/traffic' nexus/static/app.js
grep -Fq '/api/server/traffic-policy' nexus/static/app.js
grep -Fq 'Subscription-Userinfo' nexus/rr_nexus.py nexus/sub_server.py
grep -Fq 'QUOTA_AUTO_DELETE_SECONDS = 35 * 86400' nexus/rr_nexus.py
grep -Fq 'id="server-traffic-form"' nexus/static/index.html
grep -Fq 'id="rs-server-traffic-form"' nexus/static/index.html
grep -Fq 'id="server-plan-current"' nexus/static/index.html
grep -Fq 'id="rs-server-plan-current"' nexus/static/index.html
grep -Fq 'current_used_gb' nexus/rr_nexus.py nexus/static/app.js
grep -Fq 'enrich_subscription_content' nexus/rr_nexus.py nexus/sub_server.py
grep -Fq 'name="reset_at"' nexus/static/index.html
grep -Fq 'ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L' nexus/static/app.js
grep -Fq 'ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L' modules/85-nexus.sh
! grep -Rq 'StrictHostKeyChecking=no\|UserKnownHostsFile=/dev/null' \
    README.md README_EN.md modules nexus scripts
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/40-subscription.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/85-nexus.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/90-auto-update.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/40-subscription.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/85-nexus.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/90-auto-update.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/40-subscription.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/85-nexus.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/90-auto-update.sh
grep -Fq 'generate_nexus_device_subscriptions || return 1' modules/40-subscription.sh
grep -Fq '"client-nekobox.txt"' modules/90-auto-update.sh
# D4：/nexus/ 目录枚举防护——原子发布的新一代目录也必须
# 生成空白 index.html，不能仅依赖旧的 Shell 目录初始化。
grep -Fq 'write(public_root / "index.html", b"")' modules/85-nexus.sh
# D9：面板设备订阅文案必须标注全协议（曾误写「仅 VMess」）
grep -Fq 'v2rayN（Windows）· 全协议' nexus/rr_nexus.py
grep -Fq 'v2rayNG（安卓）· 全协议' nexus/rr_nexus.py
grep -Fq 'SFA / SFI / SFM · VMess、Reality、HY2、TUIC、AnyTLS、Naive' nexus/rr_nexus.py
grep -Fq 'id="rename-dialog"' nexus/static/index.html
grep -Fq 'id="subscription-empty"' nexus/static/index.html
grep -Fq '当前没有可用的个人订阅地址。' nexus/static/index.html
! grep -Fq '当前没有可用的可信 HTTPS 个人订阅地址。' nexus/static/index.html
grep -Fq '公网 IP 模式还必须确保 TCP/80 可从公网访问' nexus/static/index.html
grep -Fq '$("#public-guide").classList.toggle("hidden", !isPublic)' nexus/static/app.js
! grep -Fq '$("#public-guide").classList.remove("hidden")' nexus/static/app.js
grep -Fq '/app.js?v=27' nexus/static/index.html
grep -Fq '/admin.js?v=4' nexus/static/index.html
if grep -Fq '?raw=' nexus/static/app.js || \
   grep -Fq 'qr_query["raw"]' nexus/rr_nexus.py; then
    echo "Nexus QR request still places a subscription token in the query string." >&2
    exit 1
fi
grep -Fq 'sync": "not_required"' nexus/rr_nexus.py
if grep -Eq 'read[[:space:]].*(-t|--timeout)|(^|[[:space:]])TMOUT=' rr modules/99-menus.sh; then
    echo "RR main menu contains an active input timeout and may drop an idle home page." >&2
    exit 1
fi
# D10：cron worker 必须用绝对路径调 rr，且 cron 条目必须补齐 PATH
grep -Fq '"/usr/local/bin/rr", "--sync-devices"' modules/90-auto-update.sh
grep -Fq 'PATH=/usr/local/bin:/usr/bin:/bin' modules/90-auto-update.sh
# 更新链路必须在 GitHub Raw 不可达时回退到官方 Contents API 和 CDN；
# bundle 高速更新也必须复用同一下载函数，不能另写仅支持 Raw 的 curl。
grep -Fq 'RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"' modules/00-runtime.sh install.sh
grep -Fq 'RR_RAW_BASE="https://github.com/${RR_REPOSITORY}/releases/latest/download"' modules/00-runtime.sh
grep -Fq 'RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@${RR_SOURCE_REF}"' install.sh scripts/install-core.sh
grep -Fq 'Accept: application/vnd.github.raw+json' modules/60-update.sh install.sh
grep -Fq 'rr_download_file "$bundle_url" "$bundle_tmp" 10' modules/60-update.sh
grep -Fq 'rr_download_file "$RR_BOOTSTRAP_URL" "$target_file" 10 true' modules/60-update.sh
grep -Fq 'rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" true' scripts/install-core.sh
grep -Fq 'RR_RELEASE_TAG="v' install.sh scripts/install-core.sh
grep -Fq 'complete_owned_draft_assets()' .github/workflows/release.yml
grep -Fq 'publish_draft_and_confirm()' .github/workflows/release.yml
grep -Fq 'api --method POST --input release-create-request.json \' .github/workflows/release.yml
grep -Fq '{tag_name:$tag,target_commitish:$target,name:$title,body:$body,' .github/workflows/release.yml
grep -Fq 'draft:true,prerelease:false}' .github/workflows/release.yml
grep -Fq 'assert_latest_product' .github/workflows/release.yml
grep -Fq 'assert_release_gate' .github/workflows/release.yml
grep -Fq 'assert_immutable_releases_enabled' .github/workflows/release.yml
grep -Fq 'assert_new_monotonic_version' .github/workflows/release.yml
grep -Fq 'IMMUTABLE_RELEASES_READ_TOKEN' .github/workflows/release.yml
grep -Fq 'X-GitHub-Api-Version: 2026-03-10' .github/workflows/release.yml
grep -Fq 'group: rr-vps-publish-${{ github.repository }}' .github/workflows/release.yml
grep -Fq -- '-F draft=false -f make_latest=true' .github/workflows/release.yml
grep -Fq "jq -e '.immutable == true'" .github/workflows/release.yml
grep -Fq '["install.sh", "manifest.sha256", "rr-bundle.tar.gz", "RELEASE_INFO", "SHA256SUMS"]' .github/workflows/release.yml
if grep -Fq 'RR_GITHUB_MIRROR' scripts/update-guard.sh; then
    echo "Update guard still allows a user mirror to provide executable trust anchors." >&2
    exit 1
fi
grep -Fq 'UPDATE_CHECK_ERROR="远程 manifest.sha256 格式无效"' modules/60-update.sh
grep -Fq 'rr_bundle_tree_is_valid "$bundle_stage/rr-bundle"' modules/60-update.sh
grep -Fq 'RR_BUNDLE_FILE="$bundle_tmp" bash "$bootstrap_tmp" --upgrade' modules/60-update.sh
grep -Fq 'rr_bundle_tree_is_valid "$PAYLOAD_DIR"' install.sh
grep -Fq 'rr_verify_restored_state || failed=true' scripts/update-recover.sh
grep -Fq 'RR_UPDATE_EXTERNAL_HELPER="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"' \
    scripts/install-core.sh scripts/update-recover.sh
grep -Fq 'rr_snapshot_external_state || return 1' scripts/install-core.sh
grep -Fq '"$RR_UPDATE_EXTERNAL_HELPER" restore "$BACKUP_DIR" --tx-root "$RR_TX_ROOT"' \
    scripts/install-core.sh
grep -Fq '"$RR_UPDATE_EXTERNAL_HELPER" verify "$BACKUP_DIR" --tx-root "$RR_TX_ROOT"' \
    scripts/install-core.sh
grep -Fq 'if ! rr_restore_external_state_if_required "$tx" "$RR_BACKUP"; then' \
    scripts/update-recover.sh
# 完整卸载必须走捕获哈希后的精确 helper 删除路径；helper 已不再作为
# 同一条 rm 命令的相邻参数出现，旧的相邻字符串断言会误报安全重构。
grep -Fq 'rr_uninstall_remove_captured_runtime_helpers()' modules/95-install.sh
grep -Fq 'local recovery_target="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"' \
    modules/95-install.sh
grep -Fq 'local external_target="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"' \
    modules/95-install.sh
grep -Fq 'unlink -- "$recovery_target"' modules/95-install.sh
grep -Fq 'unlink -- "$external_target"' modules/95-install.sh
grep -Fq 'if ! rr_uninstall_remove_captured_runtime_helpers; then' modules/95-install.sh
grep -Fq 'systemctl restart --no-block sing-box' scripts/update-recover.sh
grep -Fq 'systemctl start --no-block argo-rr-health.service' scripts/update-recover.sh
grep -Fq 'rr_subscription_running' scripts/install-core.sh
grep -Fq 'rr_stop_subscription_servers' scripts/install-core.sh scripts/update-recover.sh
grep -Fq 'managed_subscription_pids' modules/10-system.sh
if grep -Rq --exclude=validate.sh 'subscription_server\.py' scripts modules; then
    echo "Update or rollback still searches for the nonexistent subscription_server.py process." >&2
    exit 1
fi
grep -Fq 'NAIVE_QUIC_CC="${NAIVE_QUIC_CC:-bbr}"' modules/20-config.sh
grep -Fq '3) desired_naive_quic_cc=reno ;;' modules/70-protocols.sh
grep -Fxq 'rr_check_system || exit 1' install.sh
grep -Fq 'rr_backup_sqlite /var/lib/rr-nexus/nexus.db nexus.db' install.sh
grep -Fq 'rr_restore_sqlite nexus.db /var/lib/rr-nexus/nexus.db' install.sh
grep -Fq 'ROLLBACK_FAILED=true' install.sh
grep -Fq 'rr_version_ge "$release_version" "$installed_version"' install.sh
grep -Fq 'command -v timeout >/dev/null 2>&1' modules/60-update.sh
grep -Fq 'timeout --kill-after=5 150 "$RR_LAUNCHER" \' modules/60-update.sh
grep -Fq -- '--sync-devices >/dev/null 2>&1; then' modules/60-update.sh
grep -Fq -- '--sync-subscriptions >/dev/null 2>&1; then' modules/60-update.sh
grep -Fq 'nexus_download_traffic_core "$rr_core_dir"' modules/30-singbox.sh
grep -Fq 'archive_name="rr-sing-box-${version}-linux-${SYS_ARCH}.tar.gz"' modules/85-nexus.sh
grep -Fq 'NEXUS_CORE_RELEASE_REVISION=1' modules/85-nexus.sh
grep -Fq 'release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"' modules/85-nexus.sh
grep -Fq 'release_tag="rr-nexus-core-${tag}-r1"' .github/workflows/build-nexus-core.yml
grep -Fq '.draft == false and .prerelease == false and .immutable == true' modules/85-nexus.sh
grep -Fq 'nexus_validate_core_checksums "$checksums" "$version"' modules/85-nexus.sh
grep -Fq 'nexus_validate_core_build_info' modules/85-nexus.sh
grep -Fq 'SOURCE_COMMIT=${SOURCE_SHA}' .github/workflows/build-nexus-core.yml
grep -Fq 'RR_BUILDER_COMMIT=${BUILDER_SHA}' .github/workflows/build-nexus-core.yml
grep -Fq 'RR_CORE_RELEASE=${RELEASE_TAG}' .github/workflows/build-nexus-core.yml
grep -Fq 'adopt_or_create_draft()' .github/workflows/build-nexus-core.yml
grep -Fq 'ensure_draft_assets()' .github/workflows/build-nexus-core.yml
grep -Fq -- '-f "tag_name=${TAG}" -f "target_commitish=${BUILDER_SHA}"' \
    .github/workflows/build-nexus-core.yml
grep -Fq -- '-F draft=true -F prerelease=false -f make_latest=false' \
    .github/workflows/build-nexus-core.yml
grep -Fq -- '-F draft=false -f make_latest=false' .github/workflows/build-nexus-core.yml
grep -Fq 'assert_immutable_releases_enabled' .github/workflows/build-nexus-core.yml
grep -Fq 'IMMUTABLE_RELEASES_READ_TOKEN' .github/workflows/build-nexus-core.yml
grep -Fq 'X-GitHub-Api-Version: 2026-03-10' .github/workflows/build-nexus-core.yml
grep -Fq 'group: rr-vps-publish-${{ github.repository }}' .github/workflows/build-nexus-core.yml
if grep -Fq -- '--prerelease' .github/workflows/build-nexus-core.yml; then
    echo "Stable auxiliary core is still mislabeled as a prerelease." >&2
    exit 1
fi
grep -Fq '$run.head_branch == "main" and $run.event == "push"' .github/workflows/build-nexus-core.yml
grep -Fq '.draft == false and .prerelease == false' .github/workflows/build-nexus-core.yml
grep -Fq 'SOURCE_COMMIT=${SOURCE_SHA}' .github/workflows/build-nexus-core.yml
grep -Fq 'This immutable auxiliary release is consumed only by its versioned tag and never owns repository Latest.' \
    .github/workflows/build-nexus-core.yml
legacy_latest_claims=$(grep -Fc 'Latest release, refreshed' \
    .github/workflows/build-nexus-core.yml || true)
if [ "$legacy_latest_claims" -ne 2 ]; then
    echo "Unexpected repository-Latest advertising outside the two exact legacy bootstrap pins." >&2
    exit 1
fi
if grep -Eq 'gh release (upload|edit|delete-asset).*\brr-nexus-core|--clobber' \
    .github/workflows/build-nexus-core.yml; then
    echo "RR Nexus core workflow still mutates an existing release." >&2
    exit 1
fi
python3 - <<'PY'
from pathlib import Path
import re

release = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
core = Path(".github/workflows/build-nexus-core.yml").read_text(encoding="utf-8")
for name, workflow in (("product", release), ("core", core)):
    if "gh release create" in workflow:
        raise SystemExit(f"{name}: legacy non-reconcilable gh release creator remains")
    normalized = " ".join(re.sub(r"\\\s*\n\s*", " ", workflow).split())
    if 'api --method POST "/repos/${GITHUB_REPOSITORY}/releases"' not in normalized and \
       'api --method POST --input release-create-request.json "/repos/${GITHUB_REPOSITORY}/releases"' not in normalized:
        raise SystemExit(f"{name}: exact-ID API draft creator is missing")
    for required in (
        "publish_draft_and_confirm()",
        'api --method PATCH "/repos/${GITHUB_REPOSITORY}/releases/${draft_id}"',
        "verify_published_release()",
        ".immutable == true",
    ):
        if required not in normalized:
            raise SystemExit(f"{name}: publication contract missing {required!r}")

if "complete_owned_draft_assets()" not in release:
    raise SystemExit("product: resumable exact-slot asset uploader is missing")
for required in ("adopt_or_create_draft()", "ensure_draft_assets()"):
    if required not in core:
        raise SystemExit(f"core: resumable publication contract missing {required!r}")
PY
grep -Fq '/usr/local/bin/rr --update-now' nexus/rr_nexus.py
grep -Fq 'MAX_JSON_BODY_BYTES = 1024 * 1024' nexus/rr_nexus.py
if grep -Eq 'fuser[[:space:]]+-k|gh release delete[[:space:]]+rr-nexus-core|#skip[[:space:]]*\|\|' \
    modules/85-nexus.sh .github/workflows/build-nexus-core.yml install.sh; then
    echo "A destructive port/release action or skipped installer gate remains." >&2
    exit 1
fi
if grep -Fq 'post_update_migrate >/dev/null 2>&1 || true' modules/60-update.sh; then
    echo "Update migration failure is still being ignored." >&2
    exit 1
fi
# 新安装必须按 manifest 复制全部 Nexus 静态资源，不能只固定复制 app 三件套。
grep -Fq 'nexus/static/*.html|nexus/static/*.css|nexus/static/*.js)' install.sh
grep -Fq '"$NEW_RUNTIME/$relative_path" || return 1' install.sh
# D10：新实现每次只在空 staging tree 中生成当前有效设备，再原子
# 交换整棵私有/公开订阅树。因此已删设备及其拆分格式不可残留。
grep -Fq '"-v2rayng.txt", "-sr.txt", "-nekobox.txt",' modules/85-nexus.sh
grep -Fq 'nexus_atomic_exchange_tree "$private_stage" "$private_target"' modules/85-nexus.sh
grep -Fq 'nexus_atomic_exchange_tree "$published_stage" "$published_target"' modules/85-nexus.sh
if grep -Eq 'hysteria2://.*insecure=0' modules/40-subscription.sh modules/85-nexus.sh modules/90-auto-update.sh; then
    echo "Hysteria2 self-signed URI still disables insecure mode." >&2
    exit 1
fi

echo "RR-vps validation passed."
