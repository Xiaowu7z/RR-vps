#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE_95="$ROOT_DIR/modules/95-install.sh"
TMP=$(mktemp -d /run/rr-uninstall-ip-acme.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'this ownership test must run as root'

export RR_LIB_DIR="$ROOT_DIR"
export RR_REPOSITORY=Xiaowu7z/RR-vps
RED=
RESET=

# Loading module 95 only declares functions.  Its two small unit-proof helpers
# are exercised with a deterministic systemctl facade below.
# shellcheck source=../modules/95-install.sh
source "$MODULE_95"

SERVICE_LOAD=loaded
SERVICE_ACTIVE=inactive
SERVICE_FILE_STATE=static
SERVICE_FRAGMENT="$TMP/systemd/rr-nexus-ip-acme.service"
SERVICE_DROPINS=
TIMER_LOAD=loaded
TIMER_ACTIVE=active
TIMER_FILE_STATE=enabled
TIMER_FRAGMENT="$TMP/systemd/rr-nexus-ip-acme.timer"
TIMER_DROPINS=

systemctl() {
    local command="${1:-}" unit="${2:-}" property="" prefix=""
    [ "$command" = show ] || return 0
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -p|--property)
                [ "$#" -ge 2 ] || return 1
                property="$2"
                shift 2
                ;;
            --value) shift ;;
            *) return 1 ;;
        esac
    done
    case "$unit" in
        rr-nexus-ip-acme.service) prefix=SERVICE ;;
        rr-nexus-ip-acme.timer) prefix=TIMER ;;
        *) return 1 ;;
    esac
    case "$property" in
        LoadState) eval 'printf "%s\n" "${'"$prefix"'_LOAD}"' ;;
        ActiveState) eval 'printf "%s\n" "${'"$prefix"'_ACTIVE}"' ;;
        UnitFileState) eval 'printf "%s\n" "${'"$prefix"'_FILE_STATE}"' ;;
        FragmentPath) eval 'printf "%s\n" "${'"$prefix"'_FRAGMENT}"' ;;
        DropInPaths) eval 'printf "%s\n" "${'"$prefix"'_DROPINS}"' ;;
        *) return 1 ;;
    esac
}

nexus_ip_acme_unit_is_current() {
    local path="${1:-}" kind="${2:-}"
    [ -f "$path" ] && [ ! -L "$path" ] && \
        [ "$(cat -- "$path")" = "exact-${kind}" ]
}

mkdir -p "$TMP/systemd"
printf '%s\n' exact-service > "$SERVICE_FRAGMENT"
printf '%s\n' exact-timer > "$TIMER_FRAGMENT"
rr_uninstall_ip_acme_unit_is_safe "$SERVICE_FRAGMENT" service \
    rr-nexus-ip-acme.service || fail 'exact service unit was rejected'
rr_uninstall_ip_acme_unit_is_safe "$TIMER_FRAGMENT" timer \
    rr-nexus-ip-acme.timer || fail 'exact timer unit was rejected'

printf '%s\n' exact-service '# foreign ExecStop=/bin/false' > "$SERVICE_FRAGMENT"
if rr_uninstall_ip_acme_unit_is_safe "$SERVICE_FRAGMENT" service \
        rr-nexus-ip-acme.service; then
    fail 'same-marker but modified service unit was accepted'
fi
printf '%s\n' exact-service > "$SERVICE_FRAGMENT"

SERVICE_DROPINS=/etc/systemd/system/rr-nexus-ip-acme.service.d/foreign.conf
if rr_uninstall_ip_acme_unit_is_safe "$SERVICE_FRAGMENT" service \
        rr-nexus-ip-acme.service; then
    fail 'foreign effective service drop-in was accepted'
fi
SERVICE_DROPINS=
SERVICE_FRAGMENT=/etc/systemd/system/foreign.service
if rr_uninstall_ip_acme_unit_is_safe "$TMP/systemd/rr-nexus-ip-acme.service" \
        service rr-nexus-ip-acme.service; then
    fail 'foreign effective FragmentPath was accepted'
fi
SERVICE_FRAGMENT="$TMP/systemd/rr-nexus-ip-acme.service"

mv -- "$SERVICE_FRAGMENT" "$SERVICE_FRAGMENT.real"
ln -s -- "$SERVICE_FRAGMENT.real" "$SERVICE_FRAGMENT"
if rr_uninstall_ip_acme_unit_is_safe "$SERVICE_FRAGMENT" service \
        rr-nexus-ip-acme.service; then
    fail 'symlinked service fragment was accepted'
fi
unlink -- "$SERVICE_FRAGMENT"
mv -- "$SERVICE_FRAGMENT.real" "$SERVICE_FRAGMENT"

rm -f -- "$SERVICE_FRAGMENT" "$TIMER_FRAGMENT"
SERVICE_LOAD=not-found
SERVICE_ACTIVE=inactive
SERVICE_FILE_STATE=not-found
SERVICE_FRAGMENT=
TIMER_LOAD=not-found
TIMER_ACTIVE=inactive
TIMER_FILE_STATE=not-found
TIMER_FRAGMENT=
rr_uninstall_ip_acme_unit_is_safe "$TMP/systemd/rr-nexus-ip-acme.service" \
    service rr-nexus-ip-acme.service || fail 'fully absent service was rejected'
rr_uninstall_ip_acme_unit_is_absent rr-nexus-ip-acme.service || \
    fail 'post-uninstall absent service proof was rejected'

SERVICE_LOAD=loaded
SERVICE_ACTIVE=active
SERVICE_FILE_STATE=static
if rr_uninstall_ip_acme_unit_is_safe "$TMP/systemd/rr-nexus-ip-acme.service" \
        service rr-nexus-ip-acme.service; then
    fail 'stale loaded service without a fixed fragment was accepted'
fi
SERVICE_LOAD=not-found
SERVICE_ACTIVE=inactive
SERVICE_FILE_STATE=masked
if rr_uninstall_ip_acme_unit_is_absent rr-nexus-ip-acme.service; then
    fail 'masked unit was reported disabled/not-found'
fi
SERVICE_FILE_STATE=not-found

mkdir -p "$TMP/parent-proof/inner"
printf '%s\n' preserve > "$TMP/parent-proof/inner/artifact"
rr_uninstall_ip_acme_parent_chain_is_safe \
    "$TMP/parent-proof/inner/artifact" || \
    fail 'canonical root-owned fixed parent chain was rejected'

ln -s -- "$TMP/parent-proof" "$TMP/parent-link"
if rr_uninstall_ip_acme_parent_chain_is_safe \
        "$TMP/parent-link/inner/artifact"; then
    fail 'intermediate parent symlink passed fixed-path ownership proof'
fi
[ "$(cat -- "$TMP/parent-proof/inner/artifact")" = preserve ] || \
    fail 'intermediate parent symlink proof modified its external target'
if rr_uninstall_ip_acme_existing_parent_chains_are_safe \
        "$TMP/parent-link/inner/absent-artifact"; then
    fail 'absent final path skipped its intermediate symlink parent proof'
fi
unlink -- "$TMP/parent-link"

chmod 775 "$TMP/parent-proof/inner"
if rr_uninstall_ip_acme_parent_chain_is_safe \
        "$TMP/parent-proof/inner/artifact"; then
    fail 'group-writable immediate parent passed fixed-path ownership proof'
fi
if rr_uninstall_ip_acme_existing_parent_chains_are_safe \
        "$TMP/parent-proof/inner/absent-artifact"; then
    fail 'absent final path skipped its writable parent proof'
fi
chmod 755 "$TMP/parent-proof/inner"

# Exercise the complete non-mutating preflight block with the real module-85
# and module-86 ownership predicates.  Every foreign collision must fail and
# remain byte-for-byte present.
# shellcheck source=../modules/85-nexus.sh
source "$ROOT_DIR/modules/85-nexus.sh"
# shellcheck source=../modules/86-nexus-ip-acme.sh
source "$ROOT_DIR/modules/86-nexus-ip-acme.sh"

is_valid_port() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

NEXUS_CONFIG_FILE="$TMP/nexus/nexus.json"
NEXUS_DATA_DIR="$TMP/nexus-data"
NEXUS_IP_ACME_STATE_ROOT="$TMP/ip-acme/state"
NEXUS_IP_ACME_ACTIVE_STORE="$NEXUS_IP_ACME_STATE_ROOT/active"
NEXUS_IP_ACME_CANDIDATE_STORE="$NEXUS_IP_ACME_STATE_ROOT/candidate"
NEXUS_IP_ACME_CONFIG="$NEXUS_IP_ACME_STATE_ROOT/config.json"
NEXUS_IP_ACME_JOURNAL="$NEXUS_IP_ACME_STATE_ROOT/publication.json"
NEXUS_IP_ACME_OWNER_MARKER="$NEXUS_IP_ACME_STATE_ROOT/.rr-nexus-ip-acme-owner"
NEXUS_IP_ACME_WEBROOT="$TMP/ip-acme/webroot"
NEXUS_IP_ACME_WEBROOT_MARKER="$NEXUS_IP_ACME_WEBROOT/.rr-nexus-ip-acme-owner"
NEXUS_IP_ACME_SERVICE_FILE="$TMP/ip-acme/systemd/rr-nexus-ip-acme.service"
NEXUS_IP_ACME_TIMER_FILE="$TMP/ip-acme/systemd/rr-nexus-ip-acme.timer"
NEXUS_IP_ACME_NGINX_AVAILABLE="$TMP/ip-acme/nginx/available/rr-nexus-ip-acme-http.conf"
NEXUS_IP_ACME_NGINX_ENABLED="$TMP/ip-acme/nginx/enabled/rr-nexus-ip-acme-http.conf"
NEXUS_IP_ACME_LEGO_BIN="$TMP/ip-acme/bin/lego"
NEXUS_IP_ACME_LEGO_MARKER="$TMP/ip-acme/bin/lego.install"
NEXUS_IP_ACME_LIVE_CERT="$TMP/ip-acme/certs/ip.crt"
NEXUS_IP_ACME_LIVE_KEY="$TMP/ip-acme/certs/ip.key"
NEXUS_IP_ACME_PENDING="$TMP/ip-acme/certs/.ip-cert-pending"
NEXUS_IP_CERT_GATE_SCRIPT="$TMP/ip-acme/bin/nexus-ip-cert-gate"
NEXUS_IP_CERT_GATE_DROPIN="$TMP/ip-acme/systemd/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf"
NEXUS_NGINX_AVAILABLE_DIR="$TMP/ip-acme/proxy/available"
NEXUS_NGINX_ENABLED_DIR="$TMP/ip-acme/proxy/enabled"
NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"

if rr_uninstall_emit_nexus_domain_http_site panel.example.com \
        /var/www/../foreign >/dev/null 2>&1 || \
   rr_uninstall_emit_nexus_domain_tls_site panel.example.com 8443 \
        /var/www/../foreign >/dev/null 2>&1; then
    fail 'uninstall renderer accepted a webroot module 85 cannot publish'
fi

# Keep the uninstall renderer coupled to the real module-85 writer.  The
# writer is run in an isolated temp tree with every service/certificate side
# effect stubbed; only its emitted Nginx bytes are compared.
(
    is_ip_version() { return 0; }
    is_global_ip_version() { return 0; }
    is_valid_port() { [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]]; }
    nexus_ip_acme_runtime_is_ready() { return 0; }
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    nexus_ip_certificate_pair_is_ready() { return 0; }
    nexus_install_ip_certificate_gate() { return 0; }
    nexus_ip_certificate_gate_allows() { return 0; }
    nexus_ip_acme_served_leaf_matches_live() { return 0; }
    nexus_firewall_open_accounted() {
        [ "$#" -lt 3 ] || printf -v "$3" '%s' true
    }
    systemctl() { return 0; }
    nginx() { return 0; }
    apt-get() { return 0; }

    render_root="$TMP/render-parity"
    NEXUS_NGINX_AVAILABLE_DIR="$render_root/available"
    NEXUS_NGINX_ENABLED_DIR="$render_root/enabled"
    NEXUS_CERT_DIR="$render_root/certs"
    NEXUS_CONFIG_FILE="$render_root/nexus.json"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$NEXUS_CERT_DIR"
    printf '%s\n' cert > "$NEXUS_CERT_DIR/ip.crt"
    printf '%s\n' key > "$NEXUS_CERT_DIR/ip.key"
    nexus_enable_public_ip_https 8.8.8.8 8443 '' acme-ip-shortlived || \
        fail 'module-85 IP site writer fixture failed'
    rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_CERT_DIR/ip.crt" \
        "$NEXUS_CERT_DIR/ip.key" acme-ip-shortlived > "$render_root/expected"
    cmp -s -- "$render_root/expected" \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" || \
        fail 'full-uninstall IP site renderer drifted from module 85'
    nexus_emit_nginx_ip_site 8.8.8.8 8443 legacy-self-signed true > \
        "$render_root/module85-ip-v711"
    rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_CERT_DIR/ip.crt" \
        "$NEXUS_CERT_DIR/ip.key" legacy-self-signed true > \
        "$render_root/uninstall-ip-v711"
    cmp -s -- "$render_root/module85-ip-v711" \
        "$render_root/uninstall-ip-v711" || \
        fail 'full-uninstall legacy IP renderer drifted from module 85'

    domain_root="$TMP/render-domain-parity"
    NEXUS_NGINX_AVAILABLE_DIR="$domain_root/available"
    NEXUS_NGINX_ENABLED_DIR="$domain_root/enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    RR_NAIVE_ACME_WEBROOT="$domain_root/webroot"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$RR_NAIVE_ACME_WEBROOT"
    nexus_write_nginx_site panel.example.com 8443 || \
        fail 'module-85 domain HTTP site writer fixture failed'
    rr_uninstall_emit_nexus_domain_http_site panel.example.com \
        "$RR_NAIVE_ACME_WEBROOT" > "$domain_root/expected-http"
    cmp -s -- "$domain_root/expected-http" "$NEXUS_NGINX_SITE" || \
        fail 'full-uninstall domain HTTP renderer drifted from module 85'
    nexus_write_nginx_custom_port panel.example.com 8443 || \
        fail 'module-85 domain TLS site writer fixture failed'
    rr_uninstall_emit_nexus_domain_tls_site panel.example.com 8443 \
        "$RR_NAIVE_ACME_WEBROOT" > "$domain_root/expected-tls"
    cmp -s -- "$domain_root/expected-tls" "${NEXUS_NGINX_SITE}.port" || \
        fail 'full-uninstall domain TLS renderer drifted from module 85'
    nexus_emit_nginx_domain_http_site_v711 panel.example.com > \
        "$domain_root/module85-http-v711"
    rr_uninstall_emit_nexus_domain_http_site panel.example.com \
        "$RR_NAIVE_ACME_WEBROOT" true > "$domain_root/uninstall-http-v711"
    cmp -s -- "$domain_root/module85-http-v711" \
        "$domain_root/uninstall-http-v711" || \
        fail 'full-uninstall legacy domain HTTP renderer drifted from module 85'
    nexus_emit_nginx_domain_custom_site panel.example.com 8443 \
        "$RR_NAIVE_ACME_WEBROOT" true > "$domain_root/module85-tls-v711"
    rr_uninstall_emit_nexus_domain_tls_site panel.example.com 8443 \
        "$RR_NAIVE_ACME_WEBROOT" true > "$domain_root/uninstall-tls-v711"
    cmp -s -- "$domain_root/module85-tls-v711" \
        "$domain_root/uninstall-tls-v711" || \
        fail 'full-uninstall legacy domain TLS renderer drifted from module 85'
)

PREFLIGHT_SOURCE=$(awk '
    /# IP-ACME-PREFLIGHT-BEGIN/ { capture=1; next }
    /# IP-ACME-PREFLIGHT-END/ { capture=0 }
    capture { print }
' "$MODULE_95")
[ -n "$PREFLIGHT_SOURCE" ] || fail 'IP-ACME preflight block not found'
eval "run_ip_acme_uninstall_preflight() {
    local legacy_restore_lock_fd=\"\"
    local ip_acme_present=false ip_acme_address=\"\" ip_acme_email=\"\"
    local ip_acme_nexus_address=\"\" ip_acme_certificate_mode=\"\"
    local ip_acme_nexus_mode=\"\" ip_acme_nexus_port=\"\"
    local ip_acme_expected_site=\"\" ip_acme_actual_site=\"\" ip_acme_link_target=\"\"
    local ip_acme_state_root=\"\${NEXUS_IP_ACME_STATE_ROOT}\"
    local ip_acme_webroot=\"\${NEXUS_IP_ACME_WEBROOT}\"
    local ip_acme_service_file=\"\${NEXUS_IP_ACME_SERVICE_FILE}\"
    local ip_acme_timer_file=\"\${NEXUS_IP_ACME_TIMER_FILE}\"
    local ip_acme_nginx_available=\"\${NEXUS_IP_ACME_NGINX_AVAILABLE}\"
    local ip_acme_nginx_enabled=\"\${NEXUS_IP_ACME_NGINX_ENABLED}\"
    local ip_acme_lego_bin=\"\${NEXUS_IP_ACME_LEGO_BIN}\"
    local ip_acme_lego_marker=\"\${NEXUS_IP_ACME_LEGO_MARKER}\"
    local ip_cert_file=\"\${NEXUS_IP_ACME_LIVE_CERT}\"
    local ip_key_file=\"\${NEXUS_IP_ACME_LIVE_KEY}\"
    local ip_pending_file=\"\${NEXUS_IP_ACME_PENDING}\"
    local ip_gate_script=\"\${NEXUS_IP_CERT_GATE_SCRIPT}\"
    local ip_gate_dropin=\"\${NEXUS_IP_CERT_GATE_DROPIN}\"
    local ip_proxy_available_dir=\"\${NEXUS_NGINX_AVAILABLE_DIR}\"
    local ip_proxy_enabled_dir=\"\${NEXUS_NGINX_ENABLED_DIR}\"
    local ip_proxy_site=\"\" ip_proxy_enabled=\"\" ip_proxy_is_ip=false
    local ip_proxy_authority=absent ip_proxy_domain=\"\"
    local ip_proxy_webroot=\"\${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}\"
    local ip_proxy_intent=\"\" ip_proxy_intent_address=\"\"
    local ip_proxy_intent_port=\"\" ip_proxy_intent_mode=\"\"
    local ip_proxy_config_present=false
    local ip_cert_dir=\"\" ip_cert_pair_present=false ip_cert_cleanup_needed=false
    local ip_acme_preflight_status=0
    local -a ip_acme_owned_artifacts=()
    local -a ip_proxy_retired_paths=()
    ip_proxy_site=\"\$ip_proxy_available_dir/rr-nexus-ip.conf\"
    ip_proxy_enabled=\"\$ip_proxy_enabled_dir/rr-nexus-ip.conf\"
    ip_proxy_retired_paths=(
        \"\$ip_proxy_enabled_dir/rr-nexus.conf\"
        \"\${NEXUS_NGINX_SITE}\"
        \"\$ip_proxy_enabled_dir/rr-nexus-port.conf\"
        \"\${NEXUS_NGINX_SITE}.port\"
    )
$PREFLIGHT_SOURCE
    return 0
}"

run_ip_acme_uninstall_preflight || fail 'empty IP-ACME state did not pass preflight'

mkdir -p "$(dirname -- "$NEXUS_IP_ACME_NGINX_AVAILABLE")"
printf '%s\n' '# foreign challenge vhost' > "$NEXUS_IP_ACME_NGINX_AVAILABLE"
challenge_sha=$(sha256sum -- "$NEXUS_IP_ACME_NGINX_AVAILABLE")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'foreign HTTP-01 site passed full-uninstall preflight'
fi
[ "$(sha256sum -- "$NEXUS_IP_ACME_NGINX_AVAILABLE")" = "$challenge_sha" ] || \
    fail 'foreign HTTP-01 site was modified during preflight'
rm -f -- "$NEXUS_IP_ACME_NGINX_AVAILABLE"

mkdir -p "$(dirname -- "$NEXUS_CONFIG_FILE")" \
    "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
cat > "$NEXUS_CONFIG_FILE" <<'JSON'
{"mode":"public","domain":"8.8.8.8","ssh_host":"8.8.8.8","public_port":8443,"certificate_mode":"pending-acme-ip"}
JSON
chmod 600 "$NEXUS_CONFIG_FILE"
rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_IP_ACME_LIVE_CERT" \
    "$NEXUS_IP_ACME_LIVE_KEY" pending-acme-ip > \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
ln -s -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
run_ip_acme_uninstall_preflight || \
    fail 'exact current public-IP Nginx site was rejected'
printf '%s\n' foreign > "$NEXUS_NGINX_SITE"
retired_sha=$(sha256sum -- "$NEXUS_NGINX_SITE")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'foreign historical Nexus Nginx filename passed IP-mode preflight'
fi
[ "$(sha256sum -- "$NEXUS_NGINX_SITE")" = "$retired_sha" ] || \
    fail 'foreign historical Nexus Nginx site was modified'
rm -f -- "$NEXUS_NGINX_SITE"
printf '%s\n' '# foreign append' >> "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
ip_proxy_sha=$(sha256sum -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'foreign same-name public-IP Nginx site passed preflight'
fi
[ "$(sha256sum -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf")" = \
    "$ip_proxy_sha" ] || fail 'foreign public-IP Nginx site was modified'
rm -f -- "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" "$NEXUS_CONFIG_FILE"

# A supported 7.1 self-signed renderer remains attributable to an exact
# legacy-self-signed public-IP configuration; no other mode may claim it.
cat > "$NEXUS_CONFIG_FILE" <<'JSON'
{"mode":"public","domain":"8.8.8.8","ssh_host":"8.8.8.8","public_port":8443,"certificate_mode":"legacy-self-signed"}
JSON
chmod 600 "$NEXUS_CONFIG_FILE"
rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_IP_ACME_LIVE_CERT" \
    "$NEXUS_IP_ACME_LIVE_KEY" legacy-self-signed true > \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
ln -s -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
run_ip_acme_uninstall_preflight || \
    fail 'supported legacy public-IP proxy set was rejected'
rm -f -- "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" "$NEXUS_CONFIG_FILE"

# Local/absent Nexus state has no authority over any proxy filename.  This is
# the regression for the broad module-85 remover: the foreign file must make
# full uninstall refuse before its first mutation and must remain untouched.
cat > "$NEXUS_CONFIG_FILE" <<'JSON'
{"mode":"local","domain":"","ssh_host":"8.8.8.8","public_port":8443,"certificate_mode":"none"}
JSON
chmod 600 "$NEXUS_CONFIG_FILE"
printf '%s\n' foreign-local-site > "$NEXUS_NGINX_SITE"
chmod 644 "$NEXUS_NGINX_SITE"
local_foreign_sha=$(sha256sum -- "$NEXUS_NGINX_SITE")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'local Nexus mode authorized a foreign rr-nexus.conf deletion'
fi
[ "$(sha256sum -- "$NEXUS_NGINX_SITE")" = "$local_foreign_sha" ] || \
    fail 'local-mode preflight modified foreign rr-nexus.conf'
rm -f -- "$NEXUS_NGINX_SITE" "$NEXUS_CONFIG_FILE"

# A trusted durable IP-uninstall intent may authorize only the exact former
# IP vhost during a local:none retry; domain/custom names remain forbidden.
mkdir -p "$NEXUS_DATA_DIR"
cat > "$NEXUS_CONFIG_FILE" <<'JSON'
{"mode":"local","domain":"","ssh_host":"8.8.8.8","public_port":8443,"certificate_mode":"none"}
JSON
cat > "$NEXUS_DATA_DIR/ip-acme-uninstall-intent.json" <<'JSON'
{"rr_ip_acme_uninstall_intent":1,"mode":"public","domain":"8.8.8.8","acme_email":"admin@example.com","public_port":8443,"certificate_mode":"acme-ip-shortlived"}
JSON
chmod 600 "$NEXUS_CONFIG_FILE" \
    "$NEXUS_DATA_DIR/ip-acme-uninstall-intent.json"
rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_IP_ACME_LIVE_CERT" \
    "$NEXUS_IP_ACME_LIVE_KEY" acme-ip-shortlived > \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
ln -s -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
run_ip_acme_uninstall_preflight || \
    fail 'trusted IP uninstall intent did not authorize its exact former vhost'
# A crash may land between unlinking the available site and its enabled link.
# The remaining link is still attributable only when its metadata and literal
# target are exact, so the retry must be allowed to finish it.
unlink -- "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
run_ip_acme_uninstall_preflight || \
    fail 'trusted intent rejected an exact dangling enabled-link retry'
rr_uninstall_emit_nexus_ip_site 8443 "$NEXUS_IP_ACME_LIVE_CERT" \
    "$NEXUS_IP_ACME_LIVE_KEY" acme-ip-shortlived > \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
chmod 644 "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
printf '%s\n' foreign-intent-retired > "$NEXUS_NGINX_SITE"
chmod 644 "$NEXUS_NGINX_SITE"
intent_foreign_sha=$(sha256sum -- "$NEXUS_NGINX_SITE")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'IP uninstall intent authorized a foreign domain proxy filename'
fi
[ "$(sha256sum -- "$NEXUS_NGINX_SITE")" = "$intent_foreign_sha" ] || \
    fail 'intent retry modified a foreign domain proxy file'
rm -f -- "$NEXUS_NGINX_SITE" "$NEXUS_CONFIG_FILE" \
    "$NEXUS_DATA_DIR/ip-acme-uninstall-intent.json" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" \
    "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"

# Domain mode has a separate exact two-site/two-link contract.  This proves
# the expanded preflight does not make legitimate domain uninstall impossible.
RR_NAIVE_ACME_WEBROOT="$TMP/domain-webroot"
cat > "$NEXUS_CONFIG_FILE" <<'JSON'
{"mode":"public","domain":"panel.example.com","ssh_host":"8.8.8.8","public_port":8443,"certificate_mode":"certbot-domain"}
JSON
chmod 600 "$NEXUS_CONFIG_FILE"
rr_uninstall_emit_nexus_domain_http_site panel.example.com \
    "$RR_NAIVE_ACME_WEBROOT" > "$NEXUS_NGINX_SITE"
rr_uninstall_emit_nexus_domain_tls_site panel.example.com 8443 \
    "$RR_NAIVE_ACME_WEBROOT" > "${NEXUS_NGINX_SITE}.port"
chmod 644 "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port"
ln -s -- "$NEXUS_NGINX_SITE" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf"
ln -s -- "${NEXUS_NGINX_SITE}.port" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
run_ip_acme_uninstall_preflight || \
    fail 'exact current domain proxy set was rejected'
# The last supported 7.1 renderer is independently exact and remains bound to
# this same domain/port rather than being accepted by filename alone.
rr_uninstall_emit_nexus_domain_http_site panel.example.com \
    "$RR_NAIVE_ACME_WEBROOT" true > "$NEXUS_NGINX_SITE"
rr_uninstall_emit_nexus_domain_tls_site panel.example.com 8443 \
    "$RR_NAIVE_ACME_WEBROOT" true > "${NEXUS_NGINX_SITE}.port"
chmod 644 "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port"
run_ip_acme_uninstall_preflight || \
    fail 'supported legacy domain proxy set was rejected'
rm -f -- "$NEXUS_NGINX_ENABLED_DIR/rr-nexus.conf" \
    "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf" \
    "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" "$NEXUS_CONFIG_FILE"

mkdir -p "$(dirname -- "$NEXUS_IP_ACME_NGINX_ENABLED")"
foreign_site="$TMP/foreign-nginx-site"
printf '%s\n' foreign > "$foreign_site"
ln -s -- "$foreign_site" "$NEXUS_IP_ACME_NGINX_ENABLED"
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'foreign HTTP-01 enabled symlink passed preflight'
fi
[ -L "$NEXUS_IP_ACME_NGINX_ENABLED" ] && [ -f "$foreign_site" ] || \
    fail 'foreign HTTP-01 symlink or target was removed'
unlink -- "$NEXUS_IP_ACME_NGINX_ENABLED"

mkdir -p "$(dirname -- "$NEXUS_IP_CERT_GATE_DROPIN")"
printf '%s\n' '[Service]' 'ExecStop=/bin/foreign' > "$NEXUS_IP_CERT_GATE_DROPIN"
gate_sha=$(sha256sum -- "$NEXUS_IP_CERT_GATE_DROPIN")
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'foreign Nginx gate drop-in passed preflight'
fi
[ "$(sha256sum -- "$NEXUS_IP_CERT_GATE_DROPIN")" = "$gate_sha" ] || \
    fail 'foreign Nginx gate drop-in was modified during preflight'
rm -f -- "$NEXUS_IP_CERT_GATE_DROPIN"

mkdir -p "$(dirname -- "$NEXUS_IP_ACME_LIVE_CERT")"
foreign_cert="$TMP/foreign-cert"
printf '%s\n' foreign > "$foreign_cert"
ln -s -- "$foreign_cert" "$NEXUS_IP_ACME_LIVE_CERT"
if run_ip_acme_uninstall_preflight >/dev/null 2>&1; then
    fail 'symlinked live certificate passed preflight'
fi
[ -L "$NEXUS_IP_ACME_LIVE_CERT" ] && [ -f "$foreign_cert" ] || \
    fail 'symlinked live certificate or its target was removed'
unlink -- "$NEXUS_IP_ACME_LIVE_CERT"

# Execute the integration teardown block with owned temp artifacts.  Module
# 86's own transaction test covers its internals; this fixture proves module
# 95 sequences that exact teardown before proxy/gate/live cleanup and stops
# immediately if the core reports success but leaves any owned artifact.
TEARDOWN_SOURCE=$(awk '
    /# IP-ACME-TEARDOWN-BEGIN/ { capture=1; next }
    /# IP-ACME-TEARDOWN-END/ { capture=0 }
    capture { print }
' "$MODULE_95")
[ -n "$TEARDOWN_SOURCE" ] || fail 'IP-ACME teardown block not found'
(
    teardown_root="$TMP/teardown"
    teardown_log="$teardown_root/order"
    ip_cert_file="$teardown_root/certs/ip.crt"
    ip_key_file="$teardown_root/certs/ip.key"
    ip_pending_file="$teardown_root/certs/.ip-cert-pending"
    ip_gate_script="$teardown_root/gate/nexus-ip-cert-gate"
    ip_gate_dropin="$teardown_root/gate/nginx.conf"
    ip_acme_service_file="$teardown_root/core/rr-nexus-ip-acme.service"
    ip_acme_timer_file="$teardown_root/core/rr-nexus-ip-acme.timer"
    ip_acme_state_root="$teardown_root/core/state"
    ip_acme_webroot="$teardown_root/core/webroot"
    ip_acme_nginx_available="$teardown_root/core/challenge.conf"
    ip_acme_nginx_enabled="$teardown_root/core/challenge.enabled"
    ip_acme_lego_bin="$teardown_root/core/lego"
    ip_acme_lego_marker="$teardown_root/core/lego.install"
    ip_proxy_site="$teardown_root/proxy/available/rr-nexus-ip.conf"
    ip_proxy_enabled="$teardown_root/proxy/enabled/rr-nexus-ip.conf"
    ip_proxy_retired_paths=(
        "$teardown_root/proxy/available/rr-nexus.conf"
        "$teardown_root/proxy/enabled/rr-nexus.conf"
        "$teardown_root/proxy/available/rr-nexus-port.conf"
        "$teardown_root/proxy/enabled/rr-nexus-port.conf"
    )
    ip_proxy_available_dir="$teardown_root/proxy/available"
    ip_proxy_enabled_dir="$teardown_root/proxy/enabled"
    NEXUS_NGINX_SITE="$ip_proxy_available_dir/rr-nexus.conf"
    ip_proxy_authority=absent
    ip_proxy_domain=
    ip_proxy_webroot="$teardown_root/webroot"
    ip_acme_nexus_port=
    ip_acme_certificate_mode=
    ip_cert_dir="$teardown_root/certs"
    ip_acme_address=8.8.8.8
    ip_cert_pair_present=true
    ip_cert_cleanup_needed=true
    ip_acme_present=true
    legacy_restore_lock_fd=
    firewall_status=0
    stop_status=0
    LEAVE_CORE=false
    INJECT_FOREIGN_PROXY=false
    ip_acme_owned_artifacts=(
        "$ip_acme_state_root" "$ip_acme_webroot"
        "$ip_acme_service_file" "$ip_acme_timer_file"
        "$ip_acme_nginx_available" "$ip_acme_nginx_enabled"
        "$ip_acme_lego_bin" "$ip_acme_lego_marker"
    )

    prepare_owned_fixture() {
        rm -rf -- "$teardown_root"
        mkdir -p "$ip_cert_dir" "$(dirname -- "$ip_gate_script")" \
            "$ip_acme_state_root" "$ip_acme_webroot"
        for path in "$ip_acme_service_file" "$ip_acme_timer_file" \
            "$ip_acme_nginx_available" "$ip_acme_nginx_enabled" \
            "$ip_acme_lego_bin" "$ip_acme_lego_marker" \
            "$ip_cert_file" "$ip_key_file" "$ip_gate_script" \
            "$ip_gate_dropin"; do
            mkdir -p "$(dirname -- "$path")"
            printf '%s\n' owned > "$path"
        done
        printf '%s\n' rr-nexus-ip-cert-pending-v1 > "$ip_pending_file"
    }
    nexus_ip_acme_uninstall() {
        printf '%s\n' core >> "$teardown_log"
        local path=""
        for path in "${ip_acme_owned_artifacts[@]}"; do
            [ "$LEAVE_CORE" = true ] && \
                [ "$path" = "$ip_acme_nginx_available" ] && continue
            rm -rf -- "$path"
        done
        if [ "$INJECT_FOREIGN_PROXY" = true ]; then
            mkdir -p "$ip_proxy_available_dir"
            printf '%s\n' foreign-after-core > "$NEXUS_NGINX_SITE"
            chmod 644 "$NEXUS_NGINX_SITE"
        fi
    }
    nexus_remove_public_proxy() {
        printf '%s\n' proxy >> "$teardown_log"
    }
    nexus_remove_ip_certificate_gate() {
        printf '%s\n' gate >> "$teardown_log"
        rm -f -- "$ip_gate_script" "$ip_gate_dropin"
    }
    nexus_ip_certificate_pair_is_ready() { return 0; }
    nexus_ip_certificate_pending_is_trusted() {
        [ -f "${1:-}" ] && [ ! -L "${1:-}" ] && \
            [ "$(cat -- "$1")" = rr-nexus-ip-cert-pending-v1 ]
    }
    rr_uninstall_abort_fail_closed() { return 3; }

    eval "run_ip_acme_uninstall_teardown() {
$TEARDOWN_SOURCE
        return 0
    }"

    prepare_owned_fixture
    run_ip_acme_uninstall_teardown || fail 'owned IP-ACME teardown failed'
    [ "$(tr '\n' ' ' < "$teardown_log")" = 'core proxy gate ' ] || \
        fail 'IP-ACME teardown order was not core -> proxy -> gate/live'
    for path in "${ip_acme_owned_artifacts[@]}" "$ip_cert_file" \
        "$ip_key_file" "$ip_pending_file" "$ip_gate_script" \
        "$ip_gate_dropin"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || \
            fail "owned teardown artifact remained: $path"
    done

    prepare_owned_fixture
    LEAVE_CORE=true
    if run_ip_acme_uninstall_teardown >/dev/null 2>&1; then
        fail 'core residue did not fail the full-uninstall teardown closed'
    fi
    [ "$(tr '\n' ' ' < "$teardown_log")" = 'core ' ] || \
        fail 'teardown continued after core residue proof failed'
    [ -f "$ip_gate_dropin" ] && [ -f "$ip_cert_file" ] && \
        [ -f "$ip_key_file" ] || \
        fail 'gate/live pair changed after core residue failure'

    # The first preflight is not deletion authority forever: a foreign proxy
    # file introduced by a concurrent actor after the core teardown must be
    # detected by the proof immediately adjacent to the broad module-85 call.
    LEAVE_CORE=false
    INJECT_FOREIGN_PROXY=true
    prepare_owned_fixture
    if run_ip_acme_uninstall_teardown >/dev/null 2>&1; then
        fail 'foreign proxy introduced after core teardown was deleted'
    fi
    [ "$(tr '\n' ' ' < "$teardown_log")" = 'core ' ] || \
        fail 'teardown reached the proxy remover after a foreign exchange'
    [ "$(cat -- "$NEXUS_NGINX_SITE")" = foreign-after-core ] || \
        fail 'foreign proxy introduced after core teardown was modified'
    [ -f "$ip_gate_dropin" ] && [ -f "$ip_cert_file" ] && \
        [ -f "$ip_key_file" ] || \
        fail 'gate/live pair changed after foreign proxy rejection'

    # Simulate an attacker exchanging an already-proved intermediate parent
    # after preflight but immediately before the first core teardown call.
    # The just-in-time parent-chain proof must stop before module 86 receives
    # the textual path, and the real target behind the symlink must survive.
    LEAVE_CORE=false
    INJECT_FOREIGN_PROXY=false
    prepare_owned_fixture
    mv -- "$ip_cert_dir" "${ip_cert_dir}.real"
    ln -s -- "$(basename -- "${ip_cert_dir}.real")" "$ip_cert_dir"
    if run_ip_acme_uninstall_teardown >/dev/null 2>&1; then
        fail 'exchanged IP certificate parent passed teardown boundary proof'
    fi
    if [ -e "$teardown_log" ] && [ -s "$teardown_log" ]; then
        fail 'teardown reached the core after an intermediate parent exchange'
    fi
    [ -f "${ip_cert_dir}.real/ip.crt" ] && \
        [ -f "${ip_cert_dir}.real/ip.key" ] && \
        [ -f "${ip_cert_dir}.real/.ip-cert-pending" ] || \
        fail 'teardown modified the target behind an exchanged parent'
)

# Ordering is a security property: all IP-specific proofs and deletions must
# finish before the broad Nexus directories are cleared.
python3 - "$MODULE_95" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("uninstall_all_locked() {")
end = text.index("\n# ==========================================\n# 13.", start)
body = text[start:end]

def pos(needle: str) -> int:
    try:
        return body.index(needle)
    except ValueError as error:
        raise SystemExit(f"missing full-uninstall IP-ACME contract: {needle}") from error

preflight = pos("# IP-ACME-PREFLIGHT-BEGIN")
first_destructive = pos("rr_firewall_stop_nodes_on_indeterminate_commit")
teardown = pos("# IP-ACME-TEARDOWN-BEGIN")
core_uninstall = pos("if ! nexus_ip_acme_uninstall")
unit_absence = pos("rr_uninstall_ip_acme_unit_is_absent")
proxy_remove = pos("if ! nexus_remove_public_proxy")
gate_remove = pos("nexus_remove_ip_certificate_gate")
gate_call = pos('nexus_remove_ip_certificate_gate "$ip_cert_file"')
live_remove = pos('! unlink "$ip_key_file"')
try:
    absence_loop = body.index('for _rr_ip_cert_path in "$ip_cert_file"', live_remove)
except ValueError as error:
    raise SystemExit("missing post-removal IP artifact absence loop") from error
nexus_clear = pos("/etc/sing-box /etc/rr-nexus /etc/rr-naive")

if not (preflight < first_destructive < teardown < core_uninstall
        < unit_absence < proxy_remove < gate_remove < live_remove
        < absence_loop < nexus_clear):
    raise SystemExit("unsafe full-uninstall IP-ACME teardown ordering")

required = (
    "rr_uninstall_ip_acme_existing_parent_chains_are_safe",
    "rr_uninstall_nexus_proxy_set_is_safe",
    "nexus_ip_acme_state_tree_is_owned",
    "nexus_ip_acme_nginx_http_site_is_owned",
    "ip_acme_expected_site=$(nexus_ip_acme_emit_nginx_http_site",
    "nexus_ip_certificate_gate_dropin_is_current",
    "nexus_ip_certificate_pending_is_trusted",
    "nexus_ip_certificate_pair_is_ready",
    "rr_uninstall_ip_acme_unit_is_safe",
)
for needle in required:
    if body.find(needle, preflight, first_destructive) < 0:
        raise SystemExit(f"preflight ownership proof missing: {needle}")

parent_proof = "rr_uninstall_ip_acme_existing_parent_chains_are_safe"
try:
    before_core = body.index(parent_proof, teardown, core_uninstall)
    before_proxy = body.index(parent_proof, core_uninstall, proxy_remove)
    proxy_content_before = body.index(
        "rr_uninstall_nexus_proxy_set_is_safe", core_uninstall, proxy_remove
    )
    before_gate = body.index(parent_proof, proxy_remove, gate_call)
    before_key = body.index(parent_proof, gate_call, live_remove)
    before_cert = body.index(parent_proof, live_remove, absence_loop)
except ValueError as error:
    raise SystemExit("missing just-in-time IP-ACME parent-chain proof") from error
if not (teardown < before_core < core_uninstall < before_proxy
        < proxy_content_before < proxy_remove < gate_remove < before_gate
        < gate_call < before_key < live_remove < before_cert < absence_loop):
    raise SystemExit("unsafe IP-ACME parent-chain proof ordering")
PY

printf 'PASS: full uninstall IP-ACME ownership and fail-closed tests\n'
