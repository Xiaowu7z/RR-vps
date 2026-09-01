#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
NEXUS_NGINX_TRUST_ROOT="$TEST_ROOT"

RR_LIB_DIR="$ROOT_DIR"
RR_REPOSITORY="example/rr-vps"
RED="" YELLOW="" GREEN="" CYAN="" RESET=""
# shellcheck source=../modules/85-nexus.sh
source "$ROOT_DIR/modules/85-nexus.sh"

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

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

reset_firewall_mock() {
    declare -gA FW_STATE=()
    declare -gA OTHER_NEEDED=()
    FW_FAIL_CLOSE_PORT=""
    FW_FAIL_CLOSE_STATUS=1
    FW_FAIL_OPEN_PORT=""
    FW_FAIL_OPEN_STATUS=1
    FW_FORCE_POST_OPEN_FAILURE=false
}

rr_validate_protocol_firewall() {
    local key="${1}/${2}" desired="$3"
    if [ "$desired" = open ] && [ "${FW_STATE[$key]:-closed}" = open ] && \
       [ "$FW_FORCE_POST_OPEN_FAILURE" = true ]; then
        FW_FORCE_POST_OPEN_FAILURE=false
        return 1
    fi
    [ "${FW_STATE[$key]:-closed}" = "$desired" ]
}

open_protocol_firewall() {
    local key="${1}/${2}"
    if [ "$1" = "$FW_FAIL_OPEN_PORT" ]; then
        return "$FW_FAIL_OPEN_STATUS"
    fi
    FW_STATE[$key]=open
}

close_protocol_firewall() {
    local key="${1}/${2}"
    if [ "$1" = "$FW_FAIL_CLOSE_PORT" ]; then
        return "$FW_FAIL_CLOSE_STATUS"
    fi
    FW_STATE[$key]=closed
}

rr_firewall_protocol_tuple_needed_after_updates() {
    local key="${1}/${2}"
    [ "${OTHER_NEEDED[$key]:-false}" = true ] && return 0
    return 1
}

(
    reset_firewall_mock
    FW_STATE[80/tcp]=open
    FW_STATE[18443/tcp]=closed
    http_created=unset
    panel_created=unset
    nexus_firewall_open_accounted 80 tcp http_created
    nexus_firewall_open_accounted 18443 tcp panel_created
    [ "$http_created" = false ] || fail 'pre-existing HTTP allow was claimed by this run'
    [ "$panel_created" = true ] || fail 'new panel allow was not accounted'
    nexus_firewall_compensate_public_opens "$http_created" "$panel_created" 18443
    [ "${FW_STATE[80/tcp]}" = open ] || fail 'compensation removed a pre-existing HTTP allow'
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'compensation retained this-run panel allow'

    nexus_firewall_open_accounted 18443 tcp panel_created
    OTHER_NEEDED[18443/tcp]=true
    nexus_firewall_compensate_public_opens false "$panel_created" 18443
    [ "${FW_STATE[18443/tcp]}" = open ] || fail 'shared panel tuple was closed'

    NAIVE_ENABLED=true
    NAIVE_DOMAIN=naive.example.test
    nexus_firewall_tuple_needed_without_nexus 80 tcp ||
        fail 'Naive HTTP-01 renewal was not counted as a port-80 consumer'
    NAIVE_ENABLED=false
    SUB_ACCESS_MODE=https
    SUB_DOMAIN=sub.example.test
    nexus_firewall_tuple_needed_without_nexus 80 tcp ||
        fail 'subscription HTTP-01 renewal was not counted as a port-80 consumer'
)
pass 'firewall accounting preserves pre-existing, shared and ACME port-80 consumers'

(
    reset_firewall_mock
    FW_FAIL_OPEN_PORT=18443
    FW_FAIL_OPEN_STATUS=2
    FAIL_CLOSED_CALLS=0
    PROXY_ACTIVE=true
    nexus_remove_public_proxy() { PROXY_ACTIVE=false; }
    rr_firewall_fail_closed_stop_nodes() {
        FAIL_CLOSED_CALLS=$((FAIL_CLOSED_CALLS + 1))
        return 2
    }
    panel_created=false
    set +e
    nexus_firewall_open_accounted 18443 tcp panel_created
    open_status=$?
    set -e
    [ "$open_status" -eq 2 ] && [ "$panel_created" = false ] ||
        fail 'low-level indeterminate open acquired false per-run ownership'
    set +e
    nexus_abort_public_activation "$open_status" false "$panel_created" \
        18443 true
    abort_status=$?
    set -e
    [ "$abort_status" -eq 2 ] && [ "$FAIL_CLOSED_CALLS" -eq 1 ] ||
        fail 'unowned indeterminate open did not enter durable fail-closed isolation'
    [ "$PROXY_ACTIVE" = false ] || fail 'fail-closed path retained proxy'
)
pass 'unowned firewall status 2 invokes the common durable fail-closed path'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/domain-enable"
    RR_NAIVE_ACME_WEBROOT="$case_root/webroot"
    RR_LE_LIVE_ROOT="$case_root/live"
    mkdir -p "$RR_LE_LIVE_ROOT/panel.example.test"
    printf '%s\n' certificate > \
        "$RR_LE_LIVE_ROOT/panel.example.test/fullchain.pem"
    PROXY_ACTIVE=false
    REMOVE_CALLS=0
    FW_STATE[80/tcp]=open
    FW_STATE[18443/tcp]=closed
    apt-get() { return 0; }
    tcp_port_in_use() { return 1; }
    pgrep() { return 1; }
    nexus_write_nginx_site() { PROXY_ACTIVE=true; }
    nexus_write_nginx_custom_port() { PROXY_ACTIVE=true; }
    nexus_remove_public_proxy() { PROXY_ACTIVE=false; REMOVE_CALLS=$((REMOVE_CALLS + 1)); }
    systemctl() { return 0; }
    certbot() { return 0; }
    subscription_certificate_pair_valid() { return 0; }
    rr_certbot_webroot_lineage_is_renewable() { return 0; }
    nexus_certificate_deploy_hook_is_ready() { return 0; }
    rr_enable_certbot_renewal_runtime() { return 0; }
    nginx() { return 0; }
    rr_certbot_renewal_runtime_is_ready() { return 1; }
    if nexus_enable_public_https panel.example.test admin@example.test 18443; then
        fail 'domain activation reported success after final runtime failure'
    fi
    [ "$PROXY_ACTIVE" = false ] && [ "$REMOVE_CALLS" -ge 1 ] ||
        fail 'failed domain activation retained its proxy'
    [ "${FW_STATE[80/tcp]}" = open ] || fail 'domain failure removed pre-existing port 80'
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'domain failure retained new panel allow'
)
pass 'domain enable compensates panel firewall after a later readiness failure'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/domain-reconcile"
    NEXUS_CONFIG_FILE="$case_root/nexus.json"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    RR_LE_LIVE_ROOT="$case_root/live"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$RR_LE_LIVE_ROOT/panel.example.test"
    printf '%s\n' '{"mode":"public","domain":"panel.example.test","public_port":18443}' \
        > "$NEXUS_CONFIG_FILE"
    printf '%s\n' old-site > "${NEXUS_NGINX_SITE}.port"
    printf '%s\n' certificate > \
        "$RR_LE_LIVE_ROOT/panel.example.test/fullchain.pem"
    PROXY_ACTIVE=true
    FW_STATE[80/tcp]=closed
    FW_STATE[18443/tcp]=closed
    subscription_certificate_pair_valid() { return 0; }
    rr_certbot_webroot_lineage_is_renewable() { return 0; }
    nexus_certificate_deploy_hook_is_ready() { return 0; }
    nexus_write_nginx_custom_port() { PROXY_ACTIVE=true; }
    systemctl() { return 0; }
    nexus_remove_public_proxy() { PROXY_ACTIVE=false; }
    rr_certbot_renewal_runtime_is_ready() { return 1; }
    if nexus_reconcile_public_proxy; then
        fail 'domain reconcile reported success after final runtime failure'
    fi
    [ "$PROXY_ACTIVE" = false ] || fail 'failed domain reconcile retained proxy'
    [ "${FW_STATE[80/tcp]}" = closed ] || fail 'domain reconcile retained new HTTP allow'
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'domain reconcile retained new panel allow'
)
pass 'domain reconcile compensates both sequential firewall opens'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/ip-rollback"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    NEXUS_CERT_DIR="$case_root/certs"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$NEXUS_CERT_DIR"
    printf '%s\n' certificate > "$NEXUS_CERT_DIR/ip.crt"
    printf '%s\n' private-key > "$NEXUS_CERT_DIR/ip.key"
    chmod 644 "$NEXUS_CERT_DIR/ip.crt"
    chmod 600 "$NEXUS_CERT_DIR/ip.key"
    FW_STATE[18443/tcp]=closed
    FW_FORCE_POST_OPEN_FAILURE=true
    FAIL_CLOSED_CALLS=0
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    apt-get() { return 0; }
    nginx() { [ "${1:-}" = -t ]; }
    nexus_remove_ip_certificate_gate() { return 0; }
    systemctl() {
        case "${1:-}" in
            is-active|is-enabled|enable|disable|reload|restart|start|stop|daemon-reload) return 0 ;;
            *) return 1 ;;
        esac
    }
    rr_firewall_fail_closed_stop_nodes() {
        FAIL_CLOSED_CALLS=$((FAIL_CLOSED_CALLS + 1))
        return 2
    }
    nexus_install_ip_certificate_gate() { return 0; }
    nexus_ip_certificate_gate_allows() { return 0; }
    set +e
    nexus_enable_public_ip_https 192.0.2.10 18443
    ip_status=$?
    set -e
    [ "$ip_status" -eq 1 ] ||
        fail 'proved IP firewall compensation retained an indeterminate status'
    [ "$FAIL_CLOSED_CALLS" -eq 0 ] ||
        fail 'proved IP compensation unnecessarily stopped other RR services'
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'IP rollback retained this-run panel allow'
    [ ! -e "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf" ] ||
        fail 'IP rollback retained the candidate proxy'
)
pass 'writer-success/post-validate failure downgrades only after proved compensation'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/local-transition"
    NEXUS_CONFIG_FILE="$case_root/nexus.json"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
    printf '%s\n' '{"mode":"local","domain":"","public_port":19000}' > \
        "$NEXUS_CONFIG_FILE"
    nexus_emit_nginx_domain_custom_site panel.example.test 18443 \
        /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
    chmod 644 "${NEXUS_NGINX_SITE}.port"
    ln -s "${NEXUS_NGINX_SITE}.port" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-port.conf"
    FW_STATE[80/tcp]=open
    FW_STATE[18443/tcp]=open
    OTHER_NEEDED[80/tcp]=true
    nginx() { [ "${1:-}" = -t ]; }
    systemctl() {
        case "$*" in
            'is-active --quiet nginx'|'reload nginx') return 0 ;;
            *) return 1 ;;
        esac
    }
    nexus_reconcile_public_proxy
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'local transition retained old panel allow'
    [ "${FW_STATE[80/tcp]}" = open ] || fail 'local transition removed shared port 80'
    [ ! -e "${NEXUS_NGINX_SITE}.port" ] || fail 'local transition retained public site'
)
pass 'public-to-local reconcile removes retired proxy/firewall and preserves shared HTTP'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/uninstall-success"
    NEXUS_CONFIG_FILE="$case_root/etc/rr-nexus/nexus.json"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$(dirname "$NEXUS_CONFIG_FILE")" "$NEXUS_DATA_DIR" \
        "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
    printf '%s\n' '{"mode":"public","domain":"panel.example.test","public_port":18443}' \
        > "$NEXUS_CONFIG_FILE"
    printf '%s\n' service > "$NEXUS_SERVICE_FILE"
    nexus_emit_nginx_domain_custom_site panel.example.test 18443 \
        /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
    chmod 644 "${NEXUS_NGINX_SITE}.port"
    FW_STATE[80/tcp]=open
    FW_STATE[18443/tcp]=open
    OTHER_NEEDED[80/tcp]=true
    NEXUS_ACTIVE=true
    nginx() { [ "${1:-}" = -t ]; }
    nexus_remove_ip_certificate_gate() { return 0; }
    systemctl() {
        case "$*" in
            'disable --now rr-nexus') NEXUS_ACTIVE=false ;;
            'is-active --quiet rr-nexus') [ "$NEXUS_ACTIVE" = true ] && return 0 || return 3 ;;
            'is-active --quiet nginx'|'reload nginx'|'daemon-reload') ;;
            *) return 1 ;;
        esac
    }
    sleep() { :; }
    nexus_uninstall <<< $'y\nY\n'
    [ ! -e "$(dirname "$NEXUS_CONFIG_FILE")" ] || fail 'successful uninstall retained config evidence'
    [ ! -e "$NEXUS_SERVICE_FILE" ] || fail 'successful uninstall retained service file'
    [ "${FW_STATE[18443/tcp]}" = closed ] || fail 'uninstall retained panel allow'
    [ "${FW_STATE[80/tcp]}" = open ] || fail 'uninstall removed shared HTTP allow'
)
pass 'uninstall snapshots, stops, removes proxy and reconciles all public tuples'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/uninstall-failure"
    NEXUS_CONFIG_FILE="$case_root/etc/rr-nexus/nexus.json"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$(dirname "$NEXUS_CONFIG_FILE")" "$NEXUS_DATA_DIR" \
        "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR"
    printf '%s\n' '{"mode":"public","domain":"panel.example.test","public_port":18443}' \
        > "$NEXUS_CONFIG_FILE"
    printf '%s\n' service > "$NEXUS_SERVICE_FILE"
    nexus_emit_nginx_domain_custom_site panel.example.test 18443 \
        /var/www/rr-nexus-certbot true > "${NEXUS_NGINX_SITE}.port"
    chmod 644 "${NEXUS_NGINX_SITE}.port"
    FW_STATE[80/tcp]=open
    FW_STATE[18443/tcp]=open
    FW_FAIL_CLOSE_PORT=18443
    FW_FAIL_CLOSE_STATUS=2
    NEXUS_ACTIVE=true
    nginx() { [ "${1:-}" = -t ]; }
    systemctl() {
        case "$*" in
            'disable --now rr-nexus') NEXUS_ACTIVE=false ;;
            'is-active --quiet rr-nexus') [ "$NEXUS_ACTIVE" = true ] && return 0 || return 3 ;;
            'is-active --quiet nginx'|'reload nginx'|'daemon-reload') ;;
            *) return 1 ;;
        esac
    }
    rr_firewall_fail_closed_stop_nodes() {
        printf '%s\n' failclosed-called >&2
        return 2
    }
    sleep() { :; }
    set +e
    uninstall_output=$(nexus_uninstall <<< $'y\nY\n' 2>&1)
    uninstall_status=$?
    set -e
    [ "$uninstall_status" -eq 2 ] || fail 'uninstall collapsed indeterminate firewall failure'
    [ -f "$NEXUS_CONFIG_FILE" ] || fail 'failed uninstall deleted ownership config'
    [ -f "$NEXUS_SERVICE_FILE" ] || fail 'failed uninstall deleted retryable service metadata'
    compgen -G "$NEXUS_DATA_DIR/.uninstall-config.*" >/dev/null ||
        fail 'failed uninstall did not preserve its config snapshot'
    [[ "$uninstall_output" == *failclosed-called* ]] ||
        fail 'indeterminate uninstall did not enter common fail-closed isolation'
    [[ "$uninstall_output" != *'RR Nexus 已卸载'* ]] || fail 'failed uninstall printed success'
)
pass 'uninstall preserves evidence and never reports success on firewall status 2'

(
    case_root="$TEST_ROOT/install-order"
    CONFIG_FILE="$case_root/argo.conf"
    NEXUS_CONFIG_FILE="$case_root/nexus.json"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_DB_FILE="$case_root/nexus.db"
    NEXUS_APP="$case_root/rr_nexus.py"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_INSTALL_TRANSACTION_ROOT="$NEXUS_DATA_DIR/install-transactions"
    mkdir -p "$case_root"
    printf '%s\n' INSTALL_COMPLETE=true > "$CONFIG_FILE"
    printf '%s\n' '# app' > "$NEXUS_APP"
    PUBLIC_ACTIVE=true
    DEACTIVATE_CALLS=0
    DOMAIN_ACTIVATIONS=0
    IP_ACTIVATIONS=0
    load_config_with_defaults() { INSTALL_COMPLETE=true; }
    nexus_install_dependencies() { return 0; }
    select_entry_ip() { ENTRY_IP_RAW=192.0.2.10; }
    nexus_choose_port() { printf '%s\n' 18443; }
    nexus_choose_stats_port() { printf '%s\n' 39091; }
    nexus_deactivate_public_access() { PUBLIC_ACTIVE=false; DEACTIVATE_CALLS=$((DEACTIVATE_CALLS + 1)); }
    nexus_write_config() {
        printf '{"mode":"%s","domain":"%s","public_port":%s}\n' "$1" "$2" "$3" \
            > "$NEXUS_CONFIG_FILE"
    }
    dig() { printf '%s\n' 192.0.2.10; }
    nexus_prompt_admin() { return 1; }
    nexus_enable_public_https() { DOMAIN_ACTIVATIONS=$((DOMAIN_ACTIVATIONS + 1)); PUBLIC_ACTIVE=true; }
    nexus_enable_public_ip_https() { IP_ACTIVATIONS=$((IP_ACTIVATIONS + 1)); PUBLIC_ACTIVE=true; }
    nexus_abort_install_transaction() { rm -f "$NEXUS_CONFIG_FILE"; return 1; }
    sleep() { :; }
    set +e
    nexus_install <<< $'2\npanel.example.test\nadmin@example.test\n' \
        > "$case_root/install.output" 2>&1
    install_status=$?
    set -e
    install_output=$(< "$case_root/install.output")
    [ "$install_status" -ne 0 ] || fail 'admin failure was reported as install success'
    [ "$DEACTIVATE_CALLS" -eq 1 ] && [ "$PUBLIC_ACTIVE" = false ] ||
        fail 'install did not withdraw old public access before backend/admin setup'
    [ "$DOMAIN_ACTIVATIONS" -eq 0 ] && [ "$IP_ACTIVATIONS" -eq 0 ] ||
        fail 'install activated public HTTPS before administrator readiness'
    [ ! -e "$NEXUS_CONFIG_FILE" ] || fail 'failed fresh install retained public config'
    [[ "$install_output" != *'RR Nexus 已安装并启用'* ]] || fail 'failed install printed success'
)
pass 'install defers public activation and rolls back metadata on later setup failure'

(
    case_root="$TEST_ROOT/install-unhealthy"
    CONFIG_FILE="$case_root/argo.conf"
    NEXUS_CONFIG_FILE="$case_root/etc/rr-nexus/nexus.json"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_DB_FILE="$case_root/nexus.db"
    NEXUS_APP="$case_root/rr_nexus.py"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_INSTALL_TRANSACTION_ROOT="$NEXUS_DATA_DIR/install-transactions"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    mkdir -p "$case_root" "$NEXUS_NGINX_AVAILABLE_DIR" \
        "$NEXUS_NGINX_ENABLED_DIR"
    printf '%s\n' INSTALL_COMPLETE=true > "$CONFIG_FILE"
    printf '%s\n' '# app' > "$NEXUS_APP"
    NEXUS_ACTIVE=false
    NEXUS_ENABLED=false
    NEXUS_PID=0
    NEXUS_STARTED=0
    CURL_CALLS=0
    NGINX_TEST_CALLS=0
    DOMAIN_ACTIVATIONS=0
    IP_ACTIVATIONS=0
    load_config_with_defaults() { INSTALL_COMPLETE=true; }
    nexus_is_installed() { return 1; }
    nexus_install_dependencies() { return 0; }
    select_entry_ip() { ENTRY_IP_RAW=192.0.2.10; }
    nexus_choose_port() { printf '%s\n' 18443; }
    nexus_choose_stats_port() { printf '%s\n' 39091; }
    nexus_deactivate_public_access() { return 0; }
    nexus_write_config() {
        mkdir -p "$(dirname "$NEXUS_CONFIG_FILE")"
        printf '{"mode":"%s","domain":"%s","public_port":%s}\n' \
            "$1" "$2" "$3" > "$NEXUS_CONFIG_FILE"
    }
    nexus_prompt_admin() { return 0; }
    nexus_enable_traffic_engine() { return 0; }
    generate_nexus_device_subscriptions() { return 0; }
    nexus_write_service() { printf '%s\n' service > "$NEXUS_SERVICE_FILE"; }
    nexus_service_start_preflight() { return 0; }
    nexus_enable_public_https() { DOMAIN_ACTIVATIONS=$((DOMAIN_ACTIVATIONS + 1)); }
    nexus_enable_public_ip_https() { IP_ACTIVATIONS=$((IP_ACTIVATIONS + 1)); }
    ss() { return 1; }
    curl() { CURL_CALLS=$((CURL_CALLS + 1)); return 1; }
    nginx() {
        [ "$#" -eq 1 ] && [ "$1" = -t ] || return 2
        NGINX_TEST_CALLS=$((NGINX_TEST_CALLS + 1))
    }
    sleep() { :; }
    systemctl() {
        local property="" argument=""
        case "$*" in
            'daemon-reload') return 0 ;;
            'enable rr-nexus') NEXUS_ENABLED=true; return 0 ;;
            'restart rr-nexus')
                NEXUS_ACTIVE=true
                NEXUS_PID=$((NEXUS_PID + 101))
                NEXUS_STARTED=$((NEXUS_STARTED + 1000))
                return 0
                ;;
            'disable --now rr-nexus.service')
                NEXUS_ACTIVE=false
                NEXUS_ENABLED=false
                NEXUS_PID=0
                return 0
                ;;
            'is-active --quiet rr-nexus'|'is-active --quiet rr-nexus.service')
                [ "$NEXUS_ACTIVE" = true ] && return 0 || return 3
                ;;
            'is-enabled --quiet rr-nexus.service')
                [ "$NEXUS_ENABLED" = true ] && return 0 || return 1
                ;;
            'is-active --quiet nginx') return 3 ;;
        esac
        if [ "${1:-}" = show ]; then
            for argument in "$@"; do
                case "$argument" in
                    --property=*) property="${argument#--property=}" ;;
                esac
            done
            case "$property" in
                LoadState) printf 'loaded\n' ;;
                ActiveState)
                    [ "$NEXUS_ACTIVE" = true ] && printf 'active\n' || \
                        printf 'inactive\n'
                    ;;
                SubState)
                    [ "$NEXUS_ACTIVE" = true ] && printf 'running\n' || \
                        printf 'dead\n'
                    ;;
                UnitFileState)
                    [ "$NEXUS_ENABLED" = true ] && printf 'enabled\n' || \
                        printf 'disabled\n'
                    ;;
                FragmentPath) printf '%s\n' "$NEXUS_SERVICE_FILE" ;;
                MainPID) printf '%s\n' "$NEXUS_PID" ;;
                ExecMainStartTimestampMonotonic) printf '%s\n' "$NEXUS_STARTED" ;;
                *) return 1 ;;
            esac
            return 0
        fi
        return 1
    }
    set +e
    nexus_install <<< $'1\n' > "$case_root/install.output" 2>&1
    install_status=$?
    set -e
    install_output=$(< "$case_root/install.output")
    [ "$install_status" -ne 0 ] || fail 'active-but-unhealthy backend was reported as install success'
    [ "$CURL_CALLS" -eq 10 ] || fail 'backend health proof was not bounded to ten attempts'
    [ "$NGINX_TEST_CALLS" -eq 1 ] || fail 'install abort did not prove the empty proxy state'
    [ "$NEXUS_ACTIVE" = false ] || fail 'unhealthy backend remained active after install abort'
    [ ! -e "$NEXUS_CONFIG_FILE" ] && [ ! -e "$NEXUS_SERVICE_FILE" ] ||
        fail 'unhealthy fresh install retained candidate metadata'
    [ "$DOMAIN_ACTIVATIONS" -eq 0 ] && [ "$IP_ACTIVATIONS" -eq 0 ] ||
        fail 'unhealthy backend was exposed through a public proxy'
    [[ "$install_output" != *'RR Nexus 已安装并启用'* ]] ||
        fail 'unhealthy backend printed install success'
)
pass 'active-but-unhealthy backend aborts install before public exposure or success'

(
    case_root="$TEST_ROOT/install-proxy-unhealthy"
    CONFIG_FILE="$case_root/argo.conf"
    NEXUS_CONFIG_FILE="$case_root/nexus.json"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_DB_FILE="$case_root/nexus.db"
    NEXUS_APP="$case_root/rr_nexus.py"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_INSTALL_TRANSACTION_ROOT="$NEXUS_DATA_DIR/install-transactions"
    mkdir -p "$case_root"
    printf '%s\n' INSTALL_COMPLETE=true > "$CONFIG_FILE"
    printf '%s\n' '# app' > "$NEXUS_APP"
    PROXY_ACTIVE=false
    HTTP_ALLOW=false
    PANEL_ALLOW=false
    ABORT_PUBLIC_CALLS=0
    ABORT_INSTALL_CALLS=0
    load_config_with_defaults() { INSTALL_COMPLETE=true; }
    nexus_is_installed() { return 1; }
    nexus_install_dependencies() { return 0; }
    select_entry_ip() { ENTRY_IP_RAW=192.0.2.10; }
    nexus_choose_port() { printf '%s\n' 18443; }
    nexus_choose_stats_port() { printf '%s\n' 39091; }
    nexus_deactivate_public_access() { return 0; }
    nexus_write_config() {
        printf '{"mode":"%s","domain":"%s","public_port":%s}\n' \
            "$1" "$2" "$3" > "$NEXUS_CONFIG_FILE"
    }
    dig() { printf '%s\n' 192.0.2.10; }
    nexus_prompt_admin() { return 0; }
    nexus_enable_traffic_engine() { return 0; }
    generate_nexus_device_subscriptions() { return 0; }
    nexus_start_service() { return 0; }
    nexus_enable_public_https() {
        PROXY_ACTIVE=true
        HTTP_ALLOW=true
        PANEL_ALLOW=true
        printf -v "$4" '%s' true
        printf -v "$5" '%s' true
    }
    nexus_public_proxy_health_check() { return 1; }
    nexus_abort_public_activation() {
        ABORT_PUBLIC_CALLS=$((ABORT_PUBLIC_CALLS + 1))
        [ "$2" = true ] && [ "$3" = true ] && [ "$4" = 18443 ] || return 2
        PROXY_ACTIVE=false
        HTTP_ALLOW=false
        PANEL_ALLOW=false
        return 1
    }
    nexus_abort_install_transaction() {
        ABORT_INSTALL_CALLS=$((ABORT_INSTALL_CALLS + 1))
        rm -f "$NEXUS_CONFIG_FILE" "$NEXUS_SERVICE_FILE"
        rm -rf "$1"
        return 1
    }
    sleep() { :; }
    set +e
    nexus_install <<< $'2\npanel.example.test\nadmin@example.test\n' \
        > "$case_root/install.output" 2>&1
    install_status=$?
    set -e
    install_output=$(< "$case_root/install.output")
    [ "$install_status" -ne 0 ] || fail 'unhealthy public proxy was reported as install success'
    [ "$ABORT_PUBLIC_CALLS" -eq 1 ] && [ "$ABORT_INSTALL_CALLS" -eq 1 ] ||
        fail 'proxy health failure did not run public and install compensation'
    [ "$PROXY_ACTIVE" = false ] && [ "$HTTP_ALLOW" = false ] &&
        [ "$PANEL_ALLOW" = false ] ||
        fail 'proxy health failure retained this-run proxy/firewall state'
    [ ! -e "$NEXUS_CONFIG_FILE" ] || fail 'proxy health failure retained fresh install config'
    [[ "$install_output" != *'RR Nexus 已安装并启用'* ]] ||
        fail 'unhealthy public proxy printed install success'
)
pass 'public proxy health failure compensates owned firewall and aborts install'

(
    case_root="$TEST_ROOT/ip-cert-first-publish-crash"
    cert_dir="$case_root/certs"
    cert_file="$cert_dir/ip.crt"
    key_file="$cert_dir/ip.key"
    pending_file="$cert_dir/.ip-cert-pending"
    NEXUS_IP_CERT_GATE_SCRIPT="$case_root/lib/nexus-ip-cert-gate"
    NEXUS_RESTORE_GATE_DROPIN="$case_root/systemd/zzzz-rr-restore-gate.conf"
    NEXUS_IP_CERT_GATE_DROPIN="$case_root/systemd/zzzzzz-rr-nexus-ip-cert-gate.conf"
    mkdir -p "$cert_dir" "$(dirname "$NEXUS_RESTORE_GATE_DROPIN")"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$NEXUS_RESTORE_GATE_DROPIN"
    chmod 644 "$NEXUS_RESTORE_GATE_DROPIN"
    cert_tmp="$cert_dir/.ip.crt.candidate"
    key_tmp="$cert_dir/.ip.key.candidate"
    openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
        -keyout "$key_tmp" -out "$cert_tmp" -subj '/CN=192.0.2.10' \
        -addext 'subjectAltName=IP:192.0.2.10' >/dev/null 2>&1
    chmod 600 "$key_tmp"
    chmod 644 "$cert_tmp"
    NEXUS_GATE_MODE=baseline
    systemctl() {
        case "$*" in
            'daemon-reload') return 0 ;;
            'show nginx.service --property=LoadState --value') printf '%s\n' loaded ;;
            'show nginx.service --property=DropInPaths --value')
                case "$NEXUS_GATE_MODE" in
                    baseline) printf '%s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                        "$NEXUS_IP_CERT_GATE_DROPIN" ;;
                    clear) printf '%s %s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                        "$case_root/systemd/99-clear.conf" \
                        "$NEXUS_IP_CERT_GATE_DROPIN" ;;
                    extra) printf '%s %s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                        "$case_root/systemd/zzzzz-extra.conf" \
                        "$NEXUS_IP_CERT_GATE_DROPIN" ;;
                    later) printf '%s %s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                        "$NEXUS_IP_CERT_GATE_DROPIN" \
                        "$case_root/systemd/zzzzzzz-hostile-reset.conf" ;;
                esac ;;
            'show nginx.service --property=ExecCondition --value')
                case "$NEXUS_GATE_MODE" in
                    baseline)
                        printf "{ path=/bin/sh ; argv[]=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' ; ignore_errors=no ; } { path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" \
                            "$key_file" "$pending_file" ;;
                    clear)
                        printf '{ path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n' \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" \
                            "$key_file" "$pending_file" ;;
                    extra)
                        printf "{ path=/bin/sh ; argv[]=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' ; ignore_errors=no ; } { path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; } { path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" \
                            "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" \
                            "$key_file" "$pending_file" ;;
                    later) printf '%s\n' '' ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    certificate_identity_matches() { return 0; }
    certificate_private_key_matches() { return 0; }
    nexus_install_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'could not install first-publish reboot gate'
    for hostile_mode in clear extra later; do
        NEXUS_GATE_MODE="$hostile_mode"
        if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
            "$pending_file" true; then
            fail "Nginx gate admitted hostile ${hostile_mode} sibling/condition"
        fi
    done
    NEXUS_GATE_MODE=baseline
    set +e
    (
        mv() {
            local target="${*: -1}"
            command mv "$@" || return $?
            [ "$target" != "$key_file" ] || kill -KILL "$BASHPID"
        }
        nexus_publish_ip_certificate_pair "$cert_tmp" "$key_tmp" \
            "$cert_file" "$key_file" "$cert_dir" "$pending_file" \
            192.0.2.10
    ) >/dev/null 2>&1
    crash_status=$?
    set -e
    [ "$crash_status" -eq 137 ] || fail 'first-publish crash injection did not SIGKILL after key rename'
    nexus_ip_certificate_pending_is_trusted "$pending_file" ||
        fail 'first-publish crash lost durable pending evidence'
    [ -f "$key_file" ] && [ ! -e "$cert_file" ] ||
        fail 'first-publish crash fixture did not stop between the two renames'
    if "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" "$key_file" "$pending_file"; then
        fail 'reboot gate admitted a first-publish half certificate pair'
    fi
)
pass 'first-publish SIGKILL leaves durable evidence and reboot gate blocks Nginx'

(
    case_root="$TEST_ROOT/nginx-absent-cert-gate-proof"
    cert_file="$case_root/certs/ip.crt"
    key_file="$case_root/certs/ip.key"
    pending_file="$case_root/certs/.ip-cert-pending"
    NEXUS_IP_CERT_GATE_SCRIPT="$case_root/lib/nexus-ip-cert-gate"
    NEXUS_RESTORE_GATE_DROPIN="$case_root/systemd/zzzz-rr-restore-gate.conf"
    NEXUS_IP_CERT_GATE_DROPIN="$case_root/systemd/zzzzzz-rr-nexus-ip-cert-gate.conf"
    NGINX_LOAD_STATE=not-found
    NGINX_FRAGMENT_PATH=""
    NGINX_DROPIN_PATHS=""
    NGINX_EXEC_CONDITION=""
    systemctl() {
        case "$*" in
            'show nginx.service --property=LoadState --value')
                printf '%s\n' "$NGINX_LOAD_STATE" ;;
            'show nginx.service --property=FragmentPath --value')
                printf '%s\n' "$NGINX_FRAGMENT_PATH" ;;
            'show nginx.service --property=DropInPaths --value')
                printf '%s\n' "$NGINX_DROPIN_PATHS" ;;
            'show nginx.service --property=ExecCondition --value')
                printf '%s\n' "$NGINX_EXEC_CONDITION" ;;
            *) return 1 ;;
        esac
    }
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false ||
        fail 'an absent Nginx unit with empty effective state was rejected'

    NGINX_FRAGMENT_PATH=/usr/lib/systemd/system/nginx.service
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an absent Nginx unit retained a fragment path'
    fi
    NGINX_FRAGMENT_PATH=""
    NGINX_DROPIN_PATHS=/etc/systemd/system/nginx.service.d/foreign.conf
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an absent Nginx unit retained a drop-in path'
    fi
    NGINX_DROPIN_PATHS=""
    NGINX_EXEC_CONDITION='{ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; }'
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an absent Nginx unit retained a compiled ExecCondition'
    fi
    NGINX_EXEC_CONDITION=""
    NGINX_LOAD_STATE=masked
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an empty but non-absent/non-loaded Nginx state was accepted'
    fi
    NGINX_LOAD_STATE=not-found

    mkdir -p "$(dirname "$NEXUS_IP_CERT_GATE_SCRIPT")" \
        "$(dirname "$NEXUS_IP_CERT_GATE_DROPIN")"
    printf '%s\n' residual > "$NEXUS_IP_CERT_GATE_SCRIPT"
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an absent Nginx unit bypassed a residual gate script'
    fi
    unlink "$NEXUS_IP_CERT_GATE_SCRIPT"
    printf '%s\n' residual > "$NEXUS_IP_CERT_GATE_DROPIN"
    if nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false; then
        fail 'an absent Nginx unit bypassed a residual gate drop-in'
    fi
)
pass 'absent Nginx gate proof requires empty compiled state and no gate artifacts'

(
    reset_firewall_mock
    case_root="$TEST_ROOT/ip-cert-second-rename"
    NEXUS_NGINX_AVAILABLE_DIR="$case_root/sites-available"
    NEXUS_NGINX_ENABLED_DIR="$case_root/sites-enabled"
    NEXUS_NGINX_SITE="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus.conf"
    NEXUS_CERT_DIR="$case_root/certs"
    NEXUS_IP_CERT_GATE_SCRIPT="$case_root/lib/nexus-ip-cert-gate"
    NEXUS_RESTORE_GATE_DROPIN="$case_root/systemd/zzzz-rr-restore-gate.conf"
    NEXUS_IP_CERT_GATE_DROPIN="$case_root/systemd/zzzzzz-rr-nexus-ip-cert-gate.conf"
    cert_file="$NEXUS_CERT_DIR/ip.crt"
    key_file="$NEXUS_CERT_DIR/ip.key"
    pending_file="$NEXUS_CERT_DIR/.ip-cert-pending"
    mkdir -p "$NEXUS_NGINX_AVAILABLE_DIR" "$NEXUS_NGINX_ENABLED_DIR" \
        "$NEXUS_CERT_DIR" "$(dirname "$NEXUS_RESTORE_GATE_DROPIN")"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$NEXUS_RESTORE_GATE_DROPIN"
    chmod 644 "$NEXUS_RESTORE_GATE_DROPIN"
    openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
        -keyout "$key_file" -out "$cert_file" -subj '/CN=192.0.2.9' \
        -addext 'subjectAltName=IP:192.0.2.9' >/dev/null 2>&1
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    nexus_emit_nginx_ip_site 192.0.2.9 18443 legacy-self-signed true > \
        "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
    ln -s "$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf" \
        "$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
    FW_STATE[18443/tcp]=closed
    FAIL_CLOSED_CALLS=0
    apt-get() { return 0; }
    nginx() { [ "${1:-}" = -t ]; }
    certificate_identity_matches() {
        openssl x509 -in "$1" -noout -text 2>/dev/null | \
            grep -Fq "IP Address:$2"
    }
    certificate_private_key_matches() {
        local cert_modulus="" key_modulus=""
        cert_modulus=$(openssl x509 -in "$1" -noout -modulus 2>/dev/null) || return 1
        key_modulus=$(openssl rsa -in "$2" -noout -modulus 2>/dev/null) || return 1
        [ "$cert_modulus" = "$key_modulus" ]
    }
    systemctl() {
        case "$*" in
            'is-active --quiet nginx'|'is-enabled --quiet nginx'|'daemon-reload'|\
            'reload nginx'|'restart nginx'|'start nginx'|'stop nginx'|\
            'enable nginx'|'disable nginx') return 0 ;;
            'show nginx.service --property=LoadState --value') printf '%s\n' loaded ;;
            'show nginx.service --property=DropInPaths --value')
                printf '%s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                    "$NEXUS_IP_CERT_GATE_DROPIN" ;;
            'show nginx.service --property=ExecCondition --value')
                printf "{ path=/bin/sh ; argv[]=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' ; ignore_errors=no ; } { path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n" \
                    "$NEXUS_IP_CERT_GATE_SCRIPT" "$NEXUS_IP_CERT_GATE_SCRIPT" \
                    "$cert_file" "$key_file" "$pending_file"
                ;;
            *) return 1 ;;
        esac
    }
    rr_firewall_fail_closed_stop_nodes() {
        FAIL_CLOSED_CALLS=$((FAIL_CLOSED_CALLS + 1))
        return 2
    }
    mv() {
        local source="${*: -2:1}"
        local target="${*: -1}"
        if [[ "$source" == "$NEXUS_CERT_DIR/.ip.crt."* ]] && \
           [ "$target" = "$cert_file" ]; then
            return 1
        fi
        command mv "$@"
    }
    set +e
    nexus_enable_public_ip_https 192.0.2.10 18443
    ip_status=$?
    set -e
    [ "$ip_status" -eq 1 ] || fail 'second certificate rename failure was not determinate after rollback'
    [ "$FAIL_CLOSED_CALLS" -eq 0 ] || fail 'proved certificate rollback unnecessarily entered fail-closed'
    [ ! -e "$pending_file" ] && [ ! -L "$pending_file" ] ||
        fail 'proved second-rename rollback retained pending marker'
    certificate_identity_matches "$cert_file" 192.0.2.9 ||
        fail 'second-rename rollback did not restore the former certificate'
    certificate_private_key_matches "$cert_file" "$key_file" ||
        fail 'second-rename rollback restored a mismatched key/certificate pair'
    "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" "$key_file" "$pending_file" ||
        fail 'reboot gate rejected the proved restored pair'
    [ "${FW_STATE[18443/tcp]}" = closed ] ||
        fail 'certificate publication failure changed firewall state'
)
pass 'second certificate rename failure restores and proves the former pair'

(
    case_root="$TEST_ROOT/ip-cert-gate-cleanup"
    cert_dir="$case_root/certs"
    cert_file="$cert_dir/ip.crt"
    key_file="$cert_dir/ip.key"
    pending_file="$cert_dir/.ip-cert-pending"
    NEXUS_IP_CERT_GATE_SCRIPT="$case_root/lib/nexus-ip-cert-gate"
    NEXUS_RESTORE_GATE_DROPIN="$case_root/systemd/zzzz-rr-restore-gate.conf"
    NEXUS_IP_CERT_GATE_DROPIN="$case_root/systemd/zzzzzz-rr-nexus-ip-cert-gate.conf"
    mkdir -p "$cert_dir" "$(dirname "$NEXUS_RESTORE_GATE_DROPIN")"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$NEXUS_RESTORE_GATE_DROPIN"
    chmod 644 "$NEXUS_RESTORE_GATE_DROPIN"
    systemctl() {
        local have_nexus=false
        [ -e "$NEXUS_IP_CERT_GATE_DROPIN" ] && have_nexus=true
        case "$*" in
            'daemon-reload') return 0 ;;
            'show nginx.service --property=LoadState --value') printf '%s\n' loaded ;;
            'show nginx.service --property=DropInPaths --value')
                if [ "$have_nexus" = true ]; then
                    printf '%s %s\n' "$NEXUS_RESTORE_GATE_DROPIN" \
                        "$NEXUS_IP_CERT_GATE_DROPIN"
                else
                    printf '%s\n' "$NEXUS_RESTORE_GATE_DROPIN"
                fi
                ;;
            'show nginx.service --property=ExecCondition --value')
                if [ "$have_nexus" = true ]; then
                    printf "{ path=/bin/sh ; argv[]=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' ; ignore_errors=no ; } { path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n" \
                        "$NEXUS_IP_CERT_GATE_SCRIPT" \
                        "$NEXUS_IP_CERT_GATE_SCRIPT" "$cert_file" \
                        "$key_file" "$pending_file"
                else
                    printf "{ path=/bin/sh ; argv[]=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' ; ignore_errors=no ; }\n"
                fi
                ;;
            *) return 1 ;;
        esac
    }
    nexus_install_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'could not install gate cleanup fixture'
    printf '%s\n' tampered >> "$NEXUS_IP_CERT_GATE_SCRIPT"
    set +e
    nexus_remove_ip_certificate_gate "$cert_file" "$key_file" "$pending_file"
    remove_status=$?
    set -e
    [ "$remove_status" -eq 2 ] && [ -e "$NEXUS_IP_CERT_GATE_DROPIN" ] ||
        fail 'cleanup removed or accepted a tampered managed gate artifact'
    nexus_install_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'could not restore exact gate after tamper refusal'
    unlink "$NEXUS_IP_CERT_GATE_SCRIPT"
    nexus_remove_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'cleanup could not safely repair/remove a dangling script half'
    [ ! -e "$NEXUS_IP_CERT_GATE_SCRIPT" ] && \
        [ ! -e "$NEXUS_IP_CERT_GATE_DROPIN" ] ||
        fail 'cleanup retained exact managed gate artifacts'
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false || fail 'cleanup did not prove restore-only compiled gate set'
)
pass 'IP certificate gate cleanup rejects tamper and safely resolves dangling artifacts'

(
    case_root="$TEST_ROOT/ip-cert-gate-fresh"
    cert_file="$case_root/certs/ip.crt"
    key_file="$case_root/certs/ip.key"
    pending_file="$case_root/certs/.ip-cert-pending"
    NEXUS_IP_CERT_GATE_SCRIPT="$case_root/lib/nexus-ip-cert-gate"
    NEXUS_RESTORE_GATE_DROPIN="$case_root/systemd/zzzz-rr-restore-gate.conf"
    NEXUS_IP_CERT_GATE_DROPIN="$case_root/systemd/zzzzzz-rr-nexus-ip-cert-gate.conf"
    mkdir -p "$(dirname "$cert_file")" "$(dirname "$NEXUS_RESTORE_GATE_DROPIN")"
    systemctl() {
        local have_nexus=false
        [ -e "$NEXUS_IP_CERT_GATE_DROPIN" ] && have_nexus=true
        case "$*" in
            'daemon-reload') return 0 ;;
            'show nginx.service --property=LoadState --value') printf '%s\n' loaded ;;
            'show nginx.service --property=DropInPaths --value')
                [ "$have_nexus" = false ] || printf '%s\n' "$NEXUS_IP_CERT_GATE_DROPIN" ;;
            'show nginx.service --property=ExecCondition --value')
                if [ "$have_nexus" = true ]; then
                    printf '{ path=%s ; argv[]=%s %s %s %s ; ignore_errors=no ; }\n' \
                        "$NEXUS_IP_CERT_GATE_SCRIPT" "$NEXUS_IP_CERT_GATE_SCRIPT" \
                        "$cert_file" "$key_file" "$pending_file"
                else
                    printf '\n'
                fi ;;
            *) return 1 ;;
        esac
    }
    nexus_install_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'fresh host could not install the Nexus-only compiled gate'
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" true || fail 'fresh host did not prove the Nexus-only gate'
    nexus_remove_ip_certificate_gate "$cert_file" "$key_file" "$pending_file" ||
        fail 'fresh host could not remove the exact Nexus-only gate'
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false || fail 'fresh uninstall did not prove an empty gate set'
)
pass 'fresh IP mode supports Nexus-only gate install and exact empty cleanup'

(
    case_root="$TEST_ROOT/nexus-service-guards"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_SERVICE_GUARD_DROPIN="$case_root/rr-nexus.service.d/40-rr-nexus-guards.conf"
    mkdir -p "$case_root"
    printf '%s\n' '[Service]' > "$NEXUS_SERVICE_FILE"
    chmod 644 "$NEXUS_SERVICE_FILE"
    DAEMON_RELOAD_FAIL=false
    SHOW_CALLS=0
    systemctl() {
        case "$*" in
            'daemon-reload') [ "$DAEMON_RELOAD_FAIL" = false ] ;;
            'show rr-nexus.service --property=StartLimitIntervalUSec --value')
                SHOW_CALLS=$((SHOW_CALLS + 1)); printf '%s\n' 5min ;;
            'show rr-nexus.service --property=StartLimitBurst --value')
                SHOW_CALLS=$((SHOW_CALLS + 1)); printf '%s\n' 5 ;;
            'show rr-nexus.service --property=RestartPreventExitStatus --value')
                SHOW_CALLS=$((SHOW_CALLS + 1)); printf '%s\n' 3 ;;
            *) return 1 ;;
        esac
    }
    mv() {
        local target="${*: -1}"
        [ "$target" != "$NEXUS_SERVICE_GUARD_DROPIN" ] || return 1
        command mv "$@"
    }
    if ensure_nexus_service_guards; then
        fail 'service guard writer hid its atomic rename failure'
    fi
    [ ! -e "$NEXUS_SERVICE_GUARD_DROPIN" ] && [ "$SHOW_CALLS" -eq 0 ] ||
        fail 'rename failure published or claimed effective service guards'
)
pass 'Nexus service guard atomic rename failure is propagated'

(
    case_root="$TEST_ROOT/nexus-service-guard-reload"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_SERVICE_GUARD_DROPIN="$case_root/rr-nexus.service.d/40-rr-nexus-guards.conf"
    mkdir -p "$case_root"
    printf '%s\n' '[Service]' > "$NEXUS_SERVICE_FILE"
    chmod 644 "$NEXUS_SERVICE_FILE"
    DAEMON_RELOAD_FAIL=true
    SHOW_LOG="$case_root/show.log"
    # This case isolates the guard writer/reload barrier; the complete service
    # identity and process generation are covered by the dedicated generation
    # lifecycle regression.
    nexus_service_effective_identity_is_exact() { return 0; }
    systemctl() {
        case "$*" in
            'daemon-reload') [ "$DAEMON_RELOAD_FAIL" = false ] ;;
            'show rr-nexus.service --property=StartLimitIntervalUSec --value')
                printf '%s\n' interval >> "$SHOW_LOG"; printf '%s\n' 5min ;;
            'show rr-nexus.service --property=StartLimitBurst --value')
                printf '%s\n' burst >> "$SHOW_LOG"; printf '%s\n' 5 ;;
            'show rr-nexus.service --property=RestartPreventExitStatus --value')
                printf '%s\n' restart >> "$SHOW_LOG"; printf '%s\n' 3 ;;
            *) return 1 ;;
        esac
    }
    if ensure_nexus_service_guards; then
        fail 'service guard writer hid daemon-reload failure'
    fi
    [ -f "$NEXUS_SERVICE_GUARD_DROPIN" ] && [ ! -e "$SHOW_LOG" ] ||
        fail 'reload failure did not retain full retryable file or skipped proof barrier'
    DAEMON_RELOAD_FAIL=false
    ensure_nexus_service_guards || fail 'service guard retry did not prove effective properties'
    [ "$(wc -l < "$SHOW_LOG")" -eq 3 ] ||
        fail 'service guard retry skipped effective systemd properties'
    grep -Fxq 'RestartPreventExitStatus=3' "$NEXUS_SERVICE_GUARD_DROPIN" ||
        fail 'service guard exact file omitted RestartPreventExitStatus'
)
pass 'Nexus service guards require daemon-reload and exact effective properties'

(
    case_root="$TEST_ROOT/nexus-config-atomic"
    NEXUS_CONFIG_FILE="$case_root/etc/nexus.json"
    NEXUS_DATA_DIR="$case_root/data"
    NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
    SUB_ROOT="$case_root/published"
    SUB_URL_PORT=443
    SUB_PORT=443
    SUB_ACCESS_MODE=local
    SUB_DOMAIN=""
    mkdir -p "$(dirname "$NEXUS_CONFIG_FILE")" "$NEXUS_DATA_DIR" \
        "$NEXUS_SUB_ROOT"
    printf '%s\n' '{"sentinel":"old"}' > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
    old_hash=$(sha256sum "$NEXUS_CONFIG_FILE" | awk '{print $1}')
    mv() {
        local target="${*: -1}"
        [ "$target" != "$NEXUS_CONFIG_FILE" ] || return 1
        command mv "$@"
    }
    if nexus_write_config local local 7900 9000 192.0.2.10 both; then
        fail 'config writer hid its atomic rename failure'
    fi
    [ "$(sha256sum "$NEXUS_CONFIG_FILE" | awk '{print $1}')" = "$old_hash" ] ||
        fail 'config rename failure changed the former live config'
    [ "$(stat -c '%u:%g:%a:%h' "$NEXUS_CONFIG_FILE")" = 0:0:600:1 ] ||
        fail 'config rename failure weakened former config metadata'
)
pass 'Nexus config publication preserves the old file on rename failure'

(
    case_root="$TEST_ROOT/nexus-config-callers"
    NEXUS_CONFIG_FILE="$case_root/nexus.json"
    SUB_ROOT="$case_root/published"
    SUB_URL_PORT=443
    SUB_PORT=443
    SUB_ACCESS_MODE=https
    SUB_DOMAIN=sub.example.test
    ENTRY_IP_RAW=192.0.2.20
    mkdir -p "$case_root"
    printf '%s\n' \
        '{"mode":"local","port":7900,"stats_port":9000,"domain":"local","ssh_host":"192.0.2.10","sub_port":8443}' \
        > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
    PUBLISH_ATTEMPTS=0
    nexus_publish_config_candidate() {
        PUBLISH_ATTEMPTS=$((PUBLISH_ATTEMPTS + 1))
        return 1
    }
    if nexus_sync_subscription_endpoint; then
        fail 'subscription endpoint sync hid config publication failure'
    fi
    select_entry_ip() { ENTRY_IP_RAW=192.0.2.20; return 0; }
    if nexus_migrate_runtime_config; then
        fail 'runtime config migration hid config publication failure'
    fi
    [ "$PUBLISH_ATTEMPTS" -eq 2 ] ||
        fail 'config callers skipped the common checked publication barrier'
)
pass 'Nexus config migration and endpoint sync propagate publication failure'

(
    case_root="$TEST_ROOT/nexus-singbox-rollback-indeterminate"
    SINGBOX_BIN="$case_root/bin/sing-box"
    NEXUS_SINGBOX_CONFIG_FILE="$case_root/etc/config.json"
    snapshot_dir="$case_root/snapshot"
    mkdir -p "$(dirname "$SINGBOX_BIN")" \
        "$(dirname "$NEXUS_SINGBOX_CONFIG_FILE")" "$snapshot_dir"
    printf '%s\n' old-binary > "$SINGBOX_BIN"
    printf '%s\n' '{"generation":"old"}' > "$NEXUS_SINGBOX_CONFIG_FILE"
    chmod 755 "$SINGBOX_BIN"
    chmod 600 "$NEXUS_SINGBOX_CONFIG_FILE"
    binary_state=""
    config_state=""
    nexus_capture_singbox_file_state "$SINGBOX_BIN" \
        "$snapshot_dir/sing-box.previous" binary_state ||
        fail 'could not capture old Sing-box binary fixture'
    nexus_capture_singbox_file_state "$NEXUS_SINGBOX_CONFIG_FILE" \
        "$snapshot_dir/config.previous" config_state ||
        fail 'could not capture old Sing-box config fixture'
    printf '%s\n' candidate-binary > "$SINGBOX_BIN"
    printf '%s\n' '{"generation":"candidate"}' > "$NEXUS_SINGBOX_CONFIG_FILE"
    chmod 755 "$SINGBOX_BIN"
    chmod 600 "$NEXUS_SINGBOX_CONFIG_FILE"
    FAIL_CLOSED_CALLS=0
    restart_singbox() { return 1; }
    nexus_singbox_runtime_generation() { printf '%s\n' 4242:100; }
    nexus_singbox_runtime_matches_restored_files() { return 1; }
    nexus_firewall_fail_closed() {
        FAIL_CLOSED_CALLS=$((FAIL_CLOSED_CALLS + 1))
        return 2
    }
    set +e
    nexus_restore_singbox_transaction "$snapshot_dir/sing-box.previous" \
        "$binary_state" "$snapshot_dir/config.previous" "$config_state" \
        true 'fault-injected mixed runtime'
    rollback_status=$?
    set -e
    [ "$rollback_status" -eq 2 ] && [ "$FAIL_CLOSED_CALLS" -eq 1 ] ||
        fail 'unproved rollback restart did not enter durable fail-closed isolation'
    grep -Fxq old-binary "$SINGBOX_BIN" ||
        fail 'fail-closed rollback did not restore exact old binary bytes first'
    grep -Fxq '{"generation":"old"}' "$NEXUS_SINGBOX_CONFIG_FILE" ||
        fail 'fail-closed rollback did not restore exact old config bytes first'
)
pass 'Sing-box rollback restart failure with mixed runtime propagates fail-closed status'

(
    case_root="$TEST_ROOT/nexus-service-writer-rename"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_SERVICE_GUARD_DROPIN="$case_root/rr-nexus.service.d/40-rr-nexus-guards.conf"
    NEXUS_APP="$case_root/rr_nexus.py"
    mkdir -p "$case_root"
    SYSTEMCTL_CALLS=0
    systemctl() { SYSTEMCTL_CALLS=$((SYSTEMCTL_CALLS + 1)); return 0; }
    mv() {
        local target="${*: -1}"
        [ "$target" != "$NEXUS_SERVICE_FILE" ] || return 1
        command mv "$@"
    }
    if nexus_write_service; then
        fail 'service writer hid its atomic rename failure'
    fi
    [ ! -e "$NEXUS_SERVICE_FILE" ] && [ "$SYSTEMCTL_CALLS" -eq 0 ] ||
        fail 'service rename failure published or reloaded an unproved unit'
)
pass 'Nexus service writer propagates atomic unit rename failure'

(
    case_root="$TEST_ROOT/nexus-service-writer-proof"
    NEXUS_SERVICE_FILE="$case_root/rr-nexus.service"
    NEXUS_SERVICE_GUARD_DROPIN="$case_root/rr-nexus.service.d/40-rr-nexus-guards.conf"
    NEXUS_APP="$case_root/rr_nexus.py"
    RR_RESTORE_SYSTEMD_DIR="$case_root"
    restore_dropin="$case_root/rr-nexus.service.d/zzzz-rr-restore-gate.conf"
    firewall_dropin="$case_root/rr-nexus.service.d/zzzzz-rr-firewall-quarantine.conf"
    firewall_marker="/var/lib/rr-vps/firewall-quarantine"
    hostile_dropin="$case_root/rr-nexus.service.d/zzzzzz-hostile-reset.conf"
    mkdir -p "$case_root/rr-nexus.service.d"
    printf '%s\n' \
        '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$restore_dropin"
    printf '%s\n' \
        '[Service]' \
        "ExecCondition=/usr/bin/test ! -e $firewall_marker" \
        "ExecCondition=/usr/bin/test ! -L $firewall_marker" \
        > "$firewall_dropin"
    printf '%s\n' '[Service]' 'ExecCondition=' > "$hostile_dropin"
    chmod 644 "$restore_dropin" "$firewall_dropin" "$hostile_dropin"
    DAEMON_RELOADS=0
    IDENTITY_MUTATION=baseline
    EFFECTIVE_GROUP=""
    systemctl() {
        local restore_record=""
        local firewall_record_a=""
        local firewall_record_b=""
        restore_record="{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate ; ignore_errors=no ; }"
        firewall_record_a="{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e $firewall_marker ; ignore_errors=no ; }"
        firewall_record_b="{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -L $firewall_marker ; ignore_errors=no ; }"
        case "$*" in
            'daemon-reload') DAEMON_RELOADS=$((DAEMON_RELOADS + 1)); return 0 ;;
            'show rr-nexus.service --property=StartLimitIntervalUSec --value')
                printf '%s\n' 5min ;;
            'show rr-nexus.service --property=StartLimitBurst --value')
                printf '%s\n' 5 ;;
            'show rr-nexus.service --property=RestartPreventExitStatus --value')
                printf '%s\n' 3 ;;
            'show rr-nexus.service --property=LoadState --value')
                printf '%s\n' loaded ;;
            'show rr-nexus.service --property=FragmentPath --value')
                printf '%s\n' "$NEXUS_SERVICE_FILE" ;;
            'show rr-nexus.service --property=DropInPaths --value')
                case "$IDENTITY_MUTATION" in
                    unknown_dropin|reset_dropin)
                        printf '%s %s %s %s\n' "$NEXUS_SERVICE_GUARD_DROPIN" \
                            "$restore_dropin" "$firewall_dropin" \
                            "$hostile_dropin" ;;
                    duplicate_dropin)
                        printf '%s %s %s %s\n' "$NEXUS_SERVICE_GUARD_DROPIN" \
                            "$restore_dropin" "$restore_dropin" \
                            "$firewall_dropin" ;;
                    reordered_dropins)
                        printf '%s %s %s\n' "$NEXUS_SERVICE_GUARD_DROPIN" \
                            "$firewall_dropin" "$restore_dropin" ;;
                    *)
                        printf '%s %s %s\n' "$NEXUS_SERVICE_GUARD_DROPIN" \
                            "$restore_dropin" "$firewall_dropin" ;;
                esac ;;
            'show rr-nexus.service --property=ExecStart --value')
                case "$IDENTITY_MUTATION" in
                    exec_start_ignore)
                        printf '{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 %s ; ignore_errors=yes ; }\n' \
                            "$NEXUS_APP" ;;
                    exec_start_duplicate)
                        printf '{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 %s ; ignore_errors=no ; } { path=/usr/bin/python3 ; argv[]=/usr/bin/python3 %s ; ignore_errors=no ; }\n' \
                            "$NEXUS_APP" "$NEXUS_APP" ;;
                    *)
                        printf '{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 %s ; ignore_errors=no ; }\n' \
                            "$NEXUS_APP" ;;
                esac ;;
            'show rr-nexus.service --property=ExecStartPre --value')
                if [ "$IDENTITY_MUTATION" = exec_start_pre ]; then
                    printf '%s\n' '{ path=/usr/bin/true ; argv[]=/usr/bin/true ; ignore_errors=no ; }'
                else
                    printf '\n'
                fi ;;
            'show rr-nexus.service --property=ExecReload --value')
                if [ "$IDENTITY_MUTATION" = exec_reload ]; then
                    printf '%s\n' '{ path=/usr/bin/true ; argv[]=/usr/bin/true ; ignore_errors=no ; }'
                else
                    printf '\n'
                fi ;;
            'show rr-nexus.service --property=User --value')
                [ "$IDENTITY_MUTATION" != user ] && printf '%s\n' root || \
                    printf '%s\n' nobody ;;
            'show rr-nexus.service --property=Group --value')
                [ "$IDENTITY_MUTATION" != group ] && printf '%s\n' "$EFFECTIVE_GROUP" || \
                    printf '%s\n' daemon ;;
            'show rr-nexus.service --property=WorkingDirectory --value')
                [ "$IDENTITY_MUTATION" != working_directory ] && \
                    printf '%s\n' "$RR_LIB_DIR/nexus" || printf '%s\n' /tmp ;;
            'show rr-nexus.service --property=DynamicUser --value')
                [ "$IDENTITY_MUTATION" != dynamic_user ] && printf '%s\n' no || \
                    printf '%s\n' yes ;;
            'show rr-nexus.service --property=PrivateNetwork --value')
                [ "$IDENTITY_MUTATION" != private_network ] && printf '%s\n' no || \
                    printf '%s\n' yes ;;
            'show rr-nexus.service --property=RootDirectory --value')
                [ "$IDENTITY_MUTATION" != root_directory ] && printf '\n' || \
                    printf '%s\n' /srv/chroot ;;
            'show rr-nexus.service --property=RootImage --value') printf '\n' ;;
            'show rr-nexus.service --property=Conditions --value') printf '\n' ;;
            'show rr-nexus.service --property=Asserts --value') printf '\n' ;;
            'show rr-nexus.service --property=ExecCondition --value')
                case "$IDENTITY_MUTATION" in
                    condition_reset)
                        printf '%s %s\n' "$firewall_record_a" "$firewall_record_b" ;;
                    condition_unknown)
                        printf '%s %s %s %s\n' "$restore_record" \
                            '{ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; }' \
                            "$firewall_record_a" "$firewall_record_b" ;;
                    condition_duplicate)
                        printf '%s %s %s %s\n' "$restore_record" \
                            "$restore_record" "$firewall_record_a" \
                            "$firewall_record_b" ;;
                    condition_ignore)
                        printf '%s %s %s\n' \
                            "${restore_record/ignore_errors=no/ignore_errors=yes}" \
                            "$firewall_record_a" "$firewall_record_b" ;;
                    condition_malformed)
                        printf '%s %s %s\n' "$restore_record" \
                            '{ path=/usr/bin/test ; ignore_errors=no ; }' \
                            "$firewall_record_b" ;;
                    *)
                        printf '%s %s %s\n' "$restore_record" \
                            "$firewall_record_a" "$firewall_record_b" ;;
                esac ;;
            *) return 1 ;;
        esac
    }
    nexus_write_service || fail 'service writer could not prove exact effective unit'
    [ "$DAEMON_RELOADS" -eq 2 ] ||
        fail 'service writer skipped unit or guard daemon-reload barrier'
    [ "$(stat -c '%u:%g:%a:%h' "$NEXUS_SERVICE_FILE")" = 0:0:644:1 ] ||
        fail 'service writer published unsafe unit metadata'
    grep -Fxq "ExecStart=/usr/bin/python3 $NEXUS_APP" "$NEXUS_SERVICE_FILE" ||
        fail 'service writer published an unexpected ExecStart'
    EFFECTIVE_GROUP=root
    nexus_service_effective_identity_is_exact ||
        fail 'service identity rejected systemd materializing the implicit root group'
    EFFECTIVE_GROUP=""
    for IDENTITY_MUTATION in \
        exec_start_ignore exec_start_duplicate exec_start_pre exec_reload \
        user group working_directory dynamic_user private_network root_directory \
        unknown_dropin reset_dropin duplicate_dropin reordered_dropins \
        condition_reset condition_unknown condition_duplicate condition_ignore \
        condition_malformed; do
        if nexus_service_effective_identity_is_exact; then
            fail "service identity admitted ${IDENTITY_MUTATION} mutation"
        fi
    done
    IDENTITY_MUTATION=baseline
    printf '%s\n' '# hostile unit content' >> "$NEXUS_SERVICE_FILE"
    if nexus_service_effective_identity_is_exact; then
        fail 'service identity admitted non-rendered on-disk unit bytes'
    fi
    nexus_emit_service_unit > "$NEXUS_SERVICE_FILE"
    printf '%s\n' '# hostile restore gate content' >> "$restore_dropin"
    if nexus_service_effective_identity_is_exact; then
        fail 'service identity admitted a tampered managed restore gate'
    fi
    printf '%s\n' \
        '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" \
        > "$restore_dropin"
    nexus_service_effective_identity_is_exact ||
        fail 'service identity did not recover after restoring exact managed bytes'
)
pass 'Nexus service ownership binds exact unit identity and managed effective gates'

printf '1..%d\n' "$pass_count"
