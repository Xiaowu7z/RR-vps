#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

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
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
nexus_ip_acme_normalize_address() {
    local value="${1:-}" destination="${2:-}"
    [ "$value" = 8.8.8.8 ] || return 1
    if [ -n "$destination" ]; then
        printf -v "$destination" '%s' "$value"
    else
        printf '%s\n' "$value"
    fi
}
nexus_ip_acme_is_global_address() { [ "${1:-}" = 8.8.8.8 ]; }
nexus_ip_acme_email_is_valid() { [ "${1:-}" = ops@example.test ]; }
nexus_service_start_preflight() { return 0; }
nexus_local_backend_health_check() { return 0; }

reset_case() {
    local name="$1"
    CASE_ROOT="$TEST_ROOT/$name"
    NEXUS_DATA_DIR="$CASE_ROOT/data"
    NEXUS_CONFIG_FILE="$CASE_ROOT/etc/nexus.json"
    NEXUS_DB_FILE="$NEXUS_DATA_DIR/nexus.db"
    NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
    NEXUS_SERVICE_FILE="$CASE_ROOT/systemd/rr-nexus.service"
    NEXUS_APP="$CASE_ROOT/lib/rr_nexus.py"
    NEXUS_CERT_DIR="$CASE_ROOT/certs"
    NEXUS_IP_ACME_STATE_ROOT="$NEXUS_DATA_DIR/ip-acme"
    NEXUS_IP_ACME_UNINSTALL_INTENT="$NEXUS_DATA_DIR/ip-acme-uninstall-intent.json"
    mkdir -m 700 -p "$(dirname -- "$NEXUS_CONFIG_FILE")" "$NEXUS_DATA_DIR" \
        "$NEXUS_SUB_ROOT" "$NEXUS_CERT_DIR"
    mkdir -m 755 -p "$(dirname -- "$NEXUS_SERVICE_FILE")" \
        "$(dirname -- "$NEXUS_APP")"
    printf 'service\n' > "$NEXUS_SERVICE_FILE"
    printf 'app\n' > "$NEXUS_APP"
    printf 'db\n' > "$NEXUS_DB_FILE"
    printf 'subscription-bytes\n' > "$NEXUS_SUB_ROOT/dev_live.txt"
    chmod 600 "$NEXUS_CONFIG_FILE" 2>/dev/null || true
    LOAD_STATE=loaded
    ACTIVE_STATE=active
    SUB_STATE=running
    UNIT_FILE_STATE=enabled
    MAIN_PID=101
    STARTED_AT=1000
    RUNTIME_CERTIFICATE_MODE=pending-acme-ip
    RESTART_MODE=both
    RESTART_STATUS=0
    RESTART_LOG="$CASE_ROOT/restarts.log"
    CURL_LOG="$CASE_ROOT/curl.log"
    DEACTIVATE_LOG="$CASE_ROOT/deactivate.log"
    DISARM_LOG="$CASE_ROOT/disarm.log"
    : > "$RESTART_LOG"
    : > "$CURL_LOG"
    : > "$DEACTIVATE_LOG"
    : > "$DISARM_LOG"
    NEXUS_SERVICE_GENERATION_ATTEMPTS=1
    NEXUS_SERVICE_GENERATION_WAIT_SECONDS=0
}

write_public_config() {
    local certificate_mode="${1:-pending-acme-ip}"
    jq -n --arg certificate_mode "$certificate_mode" '{
        mode: "public",
        domain: "8.8.8.8",
        acme_email: "ops@example.test",
        public_port: 18443,
        subscription_access_mode: "local",
        subscription_domain: "",
        certificate_mode: $certificate_mode
    }' > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
}

systemctl() {
    local property="" argument=""
    case "${1:-}" in
        show)
            for argument in "$@"; do
                case "$argument" in --property=*) property="${argument#--property=}" ;; esac
            done
            case "$property" in
                LoadState) printf '%s\n' "$LOAD_STATE" ;;
                ActiveState) printf '%s\n' "$ACTIVE_STATE" ;;
                SubState) printf '%s\n' "$SUB_STATE" ;;
                UnitFileState) printf '%s\n' "$UNIT_FILE_STATE" ;;
                FragmentPath) printf '%s\n' "$NEXUS_SERVICE_FILE" ;;
                MainPID) printf '%s\n' "$MAIN_PID" ;;
                ExecMainStartTimestampMonotonic) printf '%s\n' "$STARTED_AT" ;;
                *) return 1 ;;
            esac
            ;;
        restart)
            printf 'restart\n' >> "$RESTART_LOG"
            case "$RESTART_MODE" in
                both) MAIN_PID=$((MAIN_PID + 1)); STARTED_AT=$((STARTED_AT + 100)) ;;
                pid-only) MAIN_PID=$((MAIN_PID + 1)) ;;
                time-only) STARTED_AT=$((STARTED_AT + 100)) ;;
                freeze) ;;
                *) return 9 ;;
            esac
            RUNTIME_CERTIFICATE_MODE=$(jq -r '.certificate_mode // "none"' \
                "$NEXUS_CONFIG_FILE")
            return "$RESTART_STATUS"
            ;;
        *) return 0 ;;
    esac
}

sqlite3() {
    [ "${1:-}" = -readonly ] || return 1
    printf 'dev_live\ttoken_generation_1234567890\n'
}

curl() {
    local output="" config_stdin=false argument="" config_line=""
    local active_error=not_found
    [ "$RUNTIME_CERTIFICATE_MODE" = acme-ip-shortlived ] && \
        active_error=subscription_not_found
    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            --output) output="${2:-}"; shift 2 ;;
            --config)
                [ "${2:-}" = - ] || return 1
                config_stdin=true
                shift 2
                ;;
            *) shift ;;
        esac
    done
    if [ "$config_stdin" = true ]; then
        IFS= read -r config_line || return 1
        [ "$config_line" = \
          'url = "http://127.0.0.1:7900/sub/dev_live/token_generation_1234567890/txt"' ] || \
            return 1
        [ "$RUNTIME_CERTIFICATE_MODE" = acme-ip-shortlived ] || return 1
        printf 'real-token\n' >> "$CURL_LOG"
        printf 'subscription-bytes\n' > "$output"
        printf '200'
        return 0
    fi
    printf '%s\n' "$active_error" >> "$CURL_LOG"
    printf '{"error":"%s"}\n404' "$active_error"
}

(
    reset_case exact-generation
    write_public_config pending-acme-ip
    [ "$(nexus_service_runtime_generation)" = 101:1000 ] || \
        fail 'exact active generation was not returned'
    for mutation in load active sub enabled pid timestamp; do
        LOAD_STATE=loaded ACTIVE_STATE=active SUB_STATE=running UNIT_FILE_STATE=enabled
        MAIN_PID=101 STARTED_AT=1000
        case "$mutation" in
            load) LOAD_STATE=not-found ;;
            active) ACTIVE_STATE=activating ;;
            sub) SUB_STATE=start ;;
            enabled) UNIT_FILE_STATE=static ;;
            pid) MAIN_PID=1 ;;
            timestamp) STARTED_AT=0 ;;
        esac
        ! nexus_service_runtime_generation >/dev/null || \
            fail "generation accepted invalid $mutation state"
    done
)
pass 'runtime generation requires exact load/active/running/enabled/PID/timestamp state'

(
    reset_case strict-restart
    write_public_config pending-acme-ip
    [ "$(nexus_restart_service_generation_checked 101:1000)" = 102:1100 ] || \
        fail 'two-field restart generation was not accepted'
    MAIN_PID=201 STARTED_AT=2000 RESTART_MODE=pid-only
    ! nexus_restart_service_generation_checked 201:2000 >/dev/null || \
        fail 'PID-only change was accepted as a generation'
    MAIN_PID=301 STARTED_AT=3000 RESTART_MODE=time-only
    ! nexus_restart_service_generation_checked 301:3000 >/dev/null || \
        fail 'timestamp-only change was accepted as a generation'
    MAIN_PID=401 STARTED_AT=4000 RESTART_MODE=both RESTART_STATUS=7
    set +e
    nexus_restart_service_generation_checked 401:4000 >/dev/null
    status=$?
    set -e
    [ "$status" -eq 7 ] || fail 'failed systemctl restart was accepted'
)
pass 'restart proves both generation fields advance and preserves command failure'

(
    reset_case promotion
    write_public_config pending-acme-ip
    nexus_commit_ip_acme_active_generation 101:1000 || \
        fail 'pending generation promotion failed'
    [ "$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE")" = \
      acme-ip-shortlived ] || fail 'disk config was not promoted'
    [ "$RUNTIME_CERTIFICATE_MODE" = acme-ip-shortlived ] || \
        fail 'new process did not load active config'
    [ "$(wc -l < "$RESTART_LOG")" -eq 1 ] || fail 'promotion restart count wrong'
    grep -Fxq real-token "$CURL_LOG" || \
        fail 'real personal subscription token was not exercised'
)
pass 'promotion restarts once and proves a real personal /sub token'

(
    reset_case promotion-rollback
    write_public_config pending-acme-ip
    # The active route discriminator is forced closed. The second restart
    # loads the restored pending config and proves /sub closed again.
    curl() {
        if [ "$RUNTIME_CERTIFICATE_MODE" = acme-ip-shortlived ]; then
            printf '{"error":"not_found"}\n404'
        else
            printf '{"error":"not_found"}\n404'
        fi
    }
    nexus_deactivate_public_access() { printf 'closed\n' >> "$DEACTIVATE_LOG"; }
    set +e
    nexus_commit_ip_acme_active_generation 101:1000
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail 'proved promotion rollback status was not 1'
    [ "$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE")" = pending-acme-ip ] || \
        fail 'failed promotion did not restore pending config'
    [ "$RUNTIME_CERTIFICATE_MODE" = pending-acme-ip ] || \
        fail 'failed promotion left an active runtime generation'
    grep -Fxq closed "$DEACTIVATE_LOG" || \
        fail 'failed promotion did not close public access before rollback'
    [ "$(wc -l < "$RESTART_LOG")" -eq 2 ] || \
        fail 'failed promotion did not perform a closed rollback restart'
)
pass 'failed promotion restores pending config and a proved closed process'

(
    reset_case promotion-kill-window
    write_public_config pending-acme-ip
    printf 'public-proxy\n' > "$CASE_ROOT/public-proxy"
    printf 'public-firewall\n' > "$CASE_ROOT/public-firewall"
    printf 'recoverable-account\n' > "$NEXUS_DATA_DIR/acme-store-marker"
    curl() { printf '{"error":"not_found"}\n404'; }
    nexus_deactivate_public_access() {
        unlink "$CASE_ROOT/public-proxy" && \
            unlink "$CASE_ROOT/public-firewall"
    }
    nexus_set_certificate_mode() {
        local expected="$1" next="$2" current="" temporary=""
        current=$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE") || return 1
        [ "$current" = "$expected" ] || return 1
        temporary=$(mktemp "$(dirname -- "$NEXUS_CONFIG_FILE")/.mode.XXXXXX") || \
            return 1
        jq --arg next "$next" '.certificate_mode=$next' \
            "$NEXUS_CONFIG_FILE" > "$temporary" || return 1
        nexus_publish_config_candidate "$temporary" "$NEXUS_CONFIG_FILE" || \
            return 1
        if [ "$expected:$next" = \
          acme-ip-shortlived:pending-acme-ip ]; then
            kill -KILL "$BASHPID"
        fi
    }
    set +e
    (nexus_commit_ip_acme_active_generation 101:1000) >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 137 ] || fail 'rollback kill injection did not reach the window'
    [ "$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE")" = pending-acme-ip ] || \
        fail 'kill injection did not persist pending mode'
    [ ! -e "$CASE_ROOT/public-proxy" ] && \
        [ ! -e "$CASE_ROOT/public-firewall" ] || \
        fail 'rollback kill left a public path to the stale active process'
    [ "$(wc -l < "$RESTART_LOG")" -eq 1 ] || \
        fail 'rollback unexpectedly restarted before injected kill'
    grep -Fxq recoverable-account "$NEXUS_DATA_DIR/acme-store-marker" || \
        fail 'rollback kill discarded recoverable ACME state'
)
pass 'promotion rollback closes public access before pending rename kill window'

(
    reset_case existing-success
    write_public_config pending-acme-ip
    printf 'recoverable-account\n' > "$NEXUS_DATA_DIR/acme-store-marker"
    nexus_ip_acme_install() { return 0; }
    nexus_ip_acme_disarm() { printf 'disarm\n' >> "$DISARM_LOG"; }
    nexus_enable_public_ip_https() { return 0; }
    nexus_public_proxy_health_check() { return 0; }
    nexus_firewall_open_accounted() { return 0; }
    nexus_deactivate_public_access() { printf 'closed\n' >> "$DEACTIVATE_LOG"; }
    nexus_activate_ip_acme_existing 8.8.8.8 ops@example.test || \
        fail 'existing pending activation failed'
    [ "$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE")" = \
      acme-ip-shortlived ] || fail 'existing activation did not publish active intent'
    [ "$RUNTIME_CERTIFICATE_MODE" = acme-ip-shortlived ] || \
        fail 'existing activation did not establish a new active generation'
    [ ! -s "$DEACTIVATE_LOG" ] && [ ! -s "$DISARM_LOG" ] || \
        fail 'successful existing activation ran failure compensation'
    grep -Fxq real-token "$CURL_LOG" || \
        fail 'existing activation did not prove the real subscription token'
)
pass 'existing pending install closes through active generation and real token proof'

(
    reset_case existing-failure
    write_public_config pending-acme-ip
    printf 'recoverable-account\n' > "$NEXUS_DATA_DIR/acme-store-marker"
    RESTART_MODE=freeze
    nexus_ip_acme_install() { return 0; }
    nexus_ip_acme_disarm() { printf 'disarm\n' >> "$DISARM_LOG"; }
    nexus_enable_public_ip_https() { return 0; }
    nexus_public_proxy_health_check() { return 0; }
    nexus_firewall_open_accounted() { return 0; }
    nexus_deactivate_public_access() { printf 'closed\n' >> "$DEACTIVATE_LOG"; }
    set +e
    nexus_activate_ip_acme_existing 8.8.8.8 ops@example.test
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail 'indeterminate activation failure was downgraded'
    [ "$(jq -r '.certificate_mode' "$NEXUS_CONFIG_FILE")" = pending-acme-ip ] || \
        fail 'existing activation failure lost pending intent'
    grep -Fxq closed "$DEACTIVATE_LOG" || fail 'failed activation kept public access'
    grep -Fxq recoverable-account "$NEXUS_DATA_DIR/acme-store-marker" || \
        fail 'failed activation discarded recoverable ACME state'
)
pass 'existing activation failure closes public access and preserves recovery state'

(
    reset_case uninstall-kill-window
    write_public_config acme-ip-shortlived
    RUNTIME_CERTIFICATE_MODE=acme-ip-shortlived
    mkdir -m 700 "$NEXUS_IP_ACME_STATE_ROOT"
    printf 'recoverable-account\n' > \
        "$NEXUS_IP_ACME_STATE_ROOT/recoverable-marker"
    printf 'public-proxy\n' > "$CASE_ROOT/public-proxy"
    printf 'public-firewall\n' > "$CASE_ROOT/public-firewall"
    nexus_ip_acme_owned_state_is_safe() { return 0; }
    nexus_ip_acme_uninstall() { fail 'core cleanup ran before kill injection'; }
    nexus_collect_configured_public_firewall_tuples() { return 0; }
    nexus_collect_managed_proxy_firewall_tuples() { return 0; }
    nexus_remove_public_proxy() { return 0; }
    nexus_reconcile_firewall_tuple_list() { return 0; }
    nexus_deactivate_public_access() {
        unlink "$CASE_ROOT/public-proxy" && \
            unlink "$CASE_ROOT/public-firewall"
    }
    eval "$(declare -f nexus_publish_local_runtime_config | \
        sed '1s/nexus_publish_local_runtime_config/nexus_publish_local_runtime_config_original/')"
    nexus_publish_local_runtime_config() {
        nexus_publish_local_runtime_config_original || return $?
        kill -KILL "$BASHPID"
    }
    set +e
    (nexus_uninstall_ip_acme_existing) >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 137 ] || fail 'local transition kill injection missed the window'
    [ "$(jq -r '.mode + ":" + .certificate_mode' "$NEXUS_CONFIG_FILE")" = \
      local:none ] || fail 'kill injection did not publish local intent'
    nexus_ip_acme_uninstall_intent_is_safe "$NEXUS_IP_ACME_UNINSTALL_INTENT" || \
        fail 'kill window lost durable uninstall retry authority'
    [ ! -e "$CASE_ROOT/public-proxy" ] && \
        [ ! -e "$CASE_ROOT/public-firewall" ] || \
        fail 'local publication kill left stale public reachability'
    grep -Fxq recoverable-account \
        "$NEXUS_IP_ACME_STATE_ROOT/recoverable-marker" || \
        fail 'local publication kill discarded ACME recovery state'
)
pass 'uninstall closes public access before local publication kill window'

(
    reset_case uninstall-retry
    write_public_config acme-ip-shortlived
    RUNTIME_CERTIFICATE_MODE=acme-ip-shortlived
    mkdir -m 700 "$NEXUS_IP_ACME_STATE_ROOT"
    printf 'cert\n' > "$NEXUS_CERT_DIR/ip.crt"
    printf 'key\n' > "$NEXUS_CERT_DIR/ip.key"
    printf 'pending\n' > "$NEXUS_CERT_DIR/.ip-cert-pending"
    chmod 600 "$NEXUS_CERT_DIR/ip.crt" "$NEXUS_CERT_DIR/ip.key" \
        "$NEXUS_CERT_DIR/.ip-cert-pending"
    CORE_CALLS="$CASE_ROOT/core-calls"
    : > "$CORE_CALLS"
    nexus_ip_acme_owned_state_is_safe() { return 0; }
    nexus_collect_configured_public_firewall_tuples() { return 0; }
    nexus_collect_managed_proxy_firewall_tuples() { return 0; }
    nexus_remove_public_proxy() { printf 'closed\n' >> "$DEACTIVATE_LOG"; }
    nexus_reconcile_firewall_tuple_list() { return 0; }
    nexus_remove_ip_certificate_gate() { return 0; }
    nexus_ip_acme_uninstall() {
        printf 'core\n' >> "$CORE_CALLS"
        if [ "$(wc -l < "$CORE_CALLS")" -eq 1 ]; then
            rm -rf -- "$NEXUS_IP_ACME_STATE_ROOT"
            return 1
        fi
        return 0
    }
    set +e
    nexus_uninstall_ip_acme_existing
    first_status=$?
    set -e
    [ "$first_status" -eq 1 ] || fail 'injected core cleanup failure was hidden'
    [ "$(jq -r '.mode + ":" + .certificate_mode' "$NEXUS_CONFIG_FILE")" = \
      local:none ] || fail 'uninstall did not commit the safe local generation'
    nexus_ip_acme_uninstall_intent_is_safe "$NEXUS_IP_ACME_UNINSTALL_INTENT" || \
        fail 'retry authority was not durably preserved'
    [ ! -e "$NEXUS_IP_ACME_STATE_ROOT" ] || fail 'injected partial core cleanup failed'

    nexus_uninstall_ip_acme_existing || fail 'local/none cleanup retry was rejected'
    [ "$(wc -l < "$CORE_CALLS")" -eq 2 ] || fail 'core cleanup was not retried'
    [ ! -e "$NEXUS_IP_ACME_UNINSTALL_INTENT" ] || \
        fail 'completed retry retained its intent journal'
    [ ! -e "$NEXUS_CERT_DIR/ip.crt" ] && [ ! -e "$NEXUS_CERT_DIR/ip.key" ] && \
        [ ! -e "$NEXUS_CERT_DIR/.ip-cert-pending" ] || \
        fail 'retry retained live certificate artifacts'
    ! find "$NEXUS_DATA_DIR" -maxdepth 1 -name '.uninstall-ip-acme-config.*' \
        -print -quit | grep -q . || fail 'random config snapshot leaked'
)
pass 'local/none uninstall safely resumes after partial core cleanup'

python3 - "$ROOT_DIR/modules/85-nexus.sh" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"^nexus_install\(\) \{(?P<body>.*?)^\}\n\nnexus_reset_admin\(\)",
    text,
    re.M | re.S,
)
assert match, "nexus_install body not found"
body = match.group("body")
start = body.index('nexus_start_service "$port"')
capture = body.index('install_backend_generation=$(nexus_service_active_generation)', start)
commit = body.index('nexus_commit_ip_acme_active_generation', capture)
assert start < capture < commit
assert 'nexus_set_certificate_mode pending-acme-ip acme-ip-shortlived' not in body[capture:]
assert 'nexus_service_stopped_disabled_is_exact' in text
PY
pass 'first install is wired through generation commit and exact failed-start retirement'

printf 'PASS: %d Nexus process-generation checks\n' "$pass_count"
