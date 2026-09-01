#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-cert-reload-pending.XXXXXX)
LOCK_HOLDER_PID=""
PRODUCTION_PENDING_DIR=/var/lib/rr-vps/cert-reload-pending
PRODUCTION_STATE_BEFORE="$TEST_ROOT/production-state.before"
PRODUCTION_STATE_AFTER="$TEST_ROOT/production-state.after"
PRODUCTION_STATE_PATHS=(
    /run/rr-vps/locks
    /run/rr-vps/locks/update.lock
    /run/rr-vps/locks/firewall.lock
    /run/rr-vps/locks/nexus-security.lock
    /run/rr-vps/locks/nexus-sync.lock
    /run/lock/rr-update.lock
    /run/rr-vps/legacy-update-bridge
    /run/rr-vps/locks/restore-live.lock
    /var/lib/rr-vps/cert-reload-pending
)
snapshot_production_state() {
    local output="$1" path="" metadata="" digest=""
    : > "$output"
    for path in "${PRODUCTION_STATE_PATHS[@]}"; do
        if [ -L "$path" ]; then
            printf '%s|symlink|%s|%s\n' "$path" \
                "$(stat -c '%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path")" \
                "$(readlink -- "$path")" >> "$output"
        elif [ -e "$path" ]; then
            metadata=$(stat -c '%F:%d:%i:%u:%g:%a:%h:%s:%Y:%Z' -- "$path")
            digest=-
            [ -f "$path" ] && digest=$(sha256sum -- "$path" | awk '{print $1}')
            printf '%s|present|%s|%s\n' "$path" "$metadata" "$digest" >> "$output"
        else
            printf '%s|absent\n' "$path" >> "$output"
        fi
    done
}
assert_production_pending_absent() {
    [ ! -e "$PRODUCTION_PENDING_DIR" ] && [ ! -L "$PRODUCTION_PENDING_DIR" ] || {
        printf 'Pending regression refuses existing production path: %s\n' \
            "$PRODUCTION_PENDING_DIR" >&2
        return 1
    }
}
assert_production_update_lock_absent() {
    [ ! -e /run/rr-vps/locks/update.lock ] && \
        [ ! -L /run/rr-vps/locks/update.lock ] || {
        printf 'Pending regression refuses production update lock.\n' >&2
        return 1
    }
}
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$LOCK_HOLDER_PID" ]; then
        kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
        wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    fi
    if ! assert_production_pending_absent; then
        status=1
    fi
    if ! assert_production_update_lock_absent; then
        status=1
    fi
    if ! snapshot_production_state "$PRODUCTION_STATE_AFTER" || \
       ! cmp -s -- "$PRODUCTION_STATE_BEFORE" "$PRODUCTION_STATE_AFTER"; then
        printf 'Pending regression changed a production lock/pending path.\n' >&2
        status=1
    fi
    rm -rf -- "$TEST_ROOT"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
assert_production_pending_absent
assert_production_update_lock_absent

fail() {
    printf 'certificate reload pending regression: FAIL: %s\n' "$*" >&2
    exit 1
}

RR_CERT_RELOAD_PENDING_DIR="$TEST_ROOT/pending"
RR_LE_LIVE_ROOT="$TEST_ROOT/live"
RR_RESTORE_LOCK_FILE="$TEST_ROOT/locks/update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/legacy/rr-update.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/locks/legacy-update-bridge"
RR_RESTORE_LIVE_LOCK_FILE="$TEST_ROOT/locks/restore-live.lock"
CONFIG_FILE="$TEST_ROOT/argo_vmess.conf"
NEXUS_CONFIG_FILE="$TEST_ROOT/nexus.json"
RR_LAUNCHER="$TEST_ROOT/rr-never"
SUB_PID_FILE="$TEST_ROOT/subscription.pid"
RR_CERT_RELOAD_NGINX_BIN="$TEST_ROOT/nginx-never"
RR_CERT_RELOAD_SYSTEMCTL_BIN="$TEST_ROOT/systemctl-never"
RR_CERT_RELOAD_TEST_PROBE=/bin/true
export RR_CERT_RELOAD_PENDING_DIR RR_LE_LIVE_ROOT RR_RESTORE_LOCK_FILE \
    RR_LEGACY_UPDATE_LOCK_FILE RR_LEGACY_UPDATE_BRIDGE_FILE \
    RR_RESTORE_LIVE_LOCK_FILE CONFIG_FILE NEXUS_CONFIG_FILE RR_LAUNCHER \
    SUB_PID_FILE RR_CERT_RELOAD_NGINX_BIN RR_CERT_RELOAD_SYSTEMCTL_BIN \
    RR_CERT_RELOAD_TEST_PROBE
snapshot_production_state "$PRODUCTION_STATE_BEFORE"

# shellcheck source=/dev/null
source "$REPO_ROOT/modules/55-resilience.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/60-update.sh"
install -d -o 0 -g 0 -m 700 "$RR_CERT_RELOAD_PENDING_DIR" \
    "$RR_LE_LIVE_ROOT" "$(dirname -- "$RR_LEGACY_UPDATE_LOCK_FILE")"
: > "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 600 "$RR_LEGACY_UPDATE_LOCK_FILE"

write_lineage() {
    local domain="$1" directory=""
    directory="$RR_LE_LIVE_ROOT/$domain"
    install -d -o 0 -g 0 -m 700 "$directory"
    printf 'cert:%s\n' "$domain" > "$directory/cert.pem"
    printf 'key:%s\n' "$domain" > "$directory/privkey.pem"
    printf 'fullchain:%s\n' "$domain" > "$directory/fullchain.pem"
    chmod 600 "$directory"/*.pem
}

write_marker() {
    local consumer="$1" domain="$2" port="$3" lineage=""
    local cert_path="" key_path="" fullchain_path="" cert_hash="" key_hash=""
    local fullchain_hash="" generation="" marker=""
    lineage="$RR_LE_LIVE_ROOT/$domain"
    cert_path=$(readlink -f -- "$lineage/cert.pem")
    key_path=$(readlink -f -- "$lineage/privkey.pem")
    fullchain_path=$(readlink -f -- "$lineage/fullchain.pem")
    cert_hash=$(sha256sum -- "$lineage/cert.pem" | awk '{print $1}')
    key_hash=$(sha256sum -- "$lineage/privkey.pem" | awk '{print $1}')
    fullchain_hash=$(sha256sum -- "$lineage/fullchain.pem" | awk '{print $1}')
    generation=$(
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$cert_path" "$key_path" "$fullchain_path" \
            "$cert_hash" "$key_hash" "$fullchain_hash" | \
            sha256sum | awk '{print $1}'
    )
    marker="$RR_CERT_RELOAD_PENDING_DIR/${consumer}.pending"
    printf '%s\n' \
        "format=$RR_CERT_RELOAD_PENDING_FORMAT" \
        "consumer=$consumer" \
        "domain=$domain" \
        "port=$port" \
        "generation_sha256=$generation" \
        "cert_sha256=$cert_hash" \
        "key_sha256=$key_hash" \
        "fullchain_sha256=$fullchain_hash" > "$marker"
    chown 0:0 "$marker"
    chmod 600 "$marker"
}

for domain in naive.example.test sub.example.test panel.example.test; do
    write_lineage "$domain"
done

extract_rr_function() {
    local name="$1"
    awk -v signature="^${name}\\(\\) \\{" '
        $0 ~ signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/rr"
}

native_log="$TEST_ROOT/native-nginx.log"
native_nginx="$TEST_ROOT/native-nginx"
native_systemctl="$TEST_ROOT/native-systemctl"
cat > "$native_nginx" <<'EOF'
#!/bin/bash
printf 'nginx:%s\n' "$*" >> "$RR_PENDING_NATIVE_LOG"
if [ "$#" -eq 1 ] && [ "$1" = -t ]; then
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -s ] && [ "$2" = reload ]; then
    [ "${RR_PENDING_NATIVE_RELOAD_FAIL:-0}" != 1 ]
    exit $?
fi
exit 2
EOF
cat > "$native_systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl:%s\n' "$*" >> "$RR_PENDING_NATIVE_LOG"
[ "$#" -eq 3 ] && [ "$1" = is-active ] && [ "$2" = --quiet ] && \
    [ "$3" = nginx ]
EOF
chmod 755 "$native_nginx" "$native_systemctl"
RR_PENDING_NATIVE_LOG="$native_log"
RR_CERT_RELOAD_NGINX_BIN="$native_nginx"
RR_CERT_RELOAD_READONLY_SYSTEMCTL_BIN="$native_systemctl"
export RR_PENDING_NATIVE_LOG RR_CERT_RELOAD_NGINX_BIN \
    RR_CERT_RELOAD_READONLY_SYSTEMCTL_BIN
eval "$(extract_rr_function rr_certificate_nginx_service_control)"
RR_CERT_RELOAD_SYSTEMCTL_BIN=rr_certificate_nginx_service_control
printf '%s\n' \
    '{"mode":"public","domain":"panel.example.test","public_port":20443}' \
    > "$NEXUS_CONFIG_FILE"

printf '%s\n' '[1/7] pending Nexus retry never executes effective systemd ExecReload'
: > "$native_log"
write_marker nexus panel.example.test 20443
rr_retry_certificate_reload_pending || fail 'native Nexus compensation failed'
[ "$(cat "$native_log")" = $'nginx:-t\nnginx:-s reload\nsystemctl:is-active --quiet nginx' ] || \
    fail "unsafe or reordered Nexus control: $(tr '\n' ',' < "$native_log")"
[ ! -e "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending" ] || \
    fail 'proven native Nexus reload retained pending evidence'

printf '%s\n' '[2/7] native Nginx reload failure retains exact pending evidence'
: > "$native_log"
write_marker nexus panel.example.test 20443
export RR_PENDING_NATIVE_RELOAD_FAIL=1
if rr_retry_certificate_reload_pending; then
    fail 'failed native Nginx reload was accepted'
fi
unset RR_PENDING_NATIVE_RELOAD_FAIL
[ -f "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending" ] || \
    fail 'failed native Nginx reload removed pending evidence'
rm -f -- "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending"

action_log="$TEST_ROOT/actions.log"
health_log="$TEST_ROOT/health.log"
: > "$action_log"
: > "$health_log"
rr_health_log() { printf '%s\n' "$*" >> "$health_log"; }
rr_certificate_reload_retry_naive() {
    printf 'naive\n' >> "$action_log"
    return "${NAIVE_RETRY_STATUS:-1}"
}
rr_certificate_reload_retry_subscription() {
    printf 'subscription\n' >> "$action_log"
    return "${SUBSCRIPTION_RETRY_STATUS:-0}"
}
rr_certificate_reload_retry_nexus() {
    printf 'nexus\n' >> "$action_log"
    return "${NEXUS_RETRY_STATUS:-0}"
}

printf '%s\n' '[3/7] all consumers run and only proven successes clear'
write_marker naive naive.example.test 18443
write_marker subscription sub.example.test 19443
write_marker nexus panel.example.test 20443
if rr_retry_certificate_reload_pending; then
    fail 'aggregate retry hid the failing Naive consumer'
fi
[ "$(cat "$action_log")" = $'naive\nsubscription\nnexus' ] || \
    fail "one failure skipped a later certificate consumer: $(tr '\n' ',' < "$action_log")"
[ -f "$RR_CERT_RELOAD_PENDING_DIR/naive.pending" ] || \
    fail 'failed consumer marker was not retained'
[ ! -e "$RR_CERT_RELOAD_PENDING_DIR/subscription.pending" ] && \
    [ ! -e "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending" ] || \
    fail 'proven successful consumer markers were not cleared'

printf '%s\n' '[4/7] a later successful health retry clears the retained marker'
NAIVE_RETRY_STATUS=0
: > "$action_log"
rr_retry_certificate_reload_pending || fail 'later Naive retry failed'
[ "$(cat "$action_log")" = naive ] || fail 'later retry ran the wrong consumer'
[ ! -e "$RR_CERT_RELOAD_PENDING_DIR/naive.pending" ] || \
    fail 'later successful retry retained its marker'

printf '%s\n' '[5/7] tampered exact-path evidence is retained and never acted on'
write_marker subscription sub.example.test 19443
sed -i 's/^consumer=subscription$/consumer=attacker/' \
    "$RR_CERT_RELOAD_PENDING_DIR/subscription.pending"
: > "$action_log"
if rr_retry_certificate_reload_pending; then
    fail 'tampered marker was accepted'
fi
[ ! -s "$action_log" ] || fail 'tampered marker triggered a consumer action'
[ -f "$RR_CERT_RELOAD_PENDING_DIR/subscription.pending" ] || \
    fail 'tampered evidence was deleted'
rm -f -- "$RR_CERT_RELOAD_PENDING_DIR/subscription.pending"

printf '%s\n' '[6/7] malformed main config still permits independent Nexus compensation'
printf '%s\n' 'duplicate=broken' > "$CONFIG_FILE"
write_marker nexus panel.example.test 20443
: > "$action_log"
: > "$health_log"
rr_firewall_fail_closed_quarantine_active() { return 1; }
rr_finalize_committed_firewall() { return 0; }
migrate_config_schema() { return 1; }
load_config_with_defaults() { fail 'load ran after a failed migration'; }
HEALTH_CHECK_DONE=false
if rr_run_health_check; then
    fail 'malformed main config was hidden by a successful Nexus compensation'
fi
[ "$(cat "$action_log")" = nexus ] || \
    fail 'malformed main config starved the independent Nexus retry'
[ ! -e "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending" ] || \
    fail 'successful independent Nexus retry retained its marker'
grep -Fq '主配置迁移或读取失败' "$health_log" || \
    fail 'malformed main config was not reported'
rm -f -- "$CONFIG_FILE"

printf '%s\n' '[7/7] a busy shared transaction lock causes zero marker mutation'
write_marker nexus panel.example.test 20443
marker_before=$(sha256sum "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending")
: > "$action_log"
install -d -o 0 -g 0 -m 700 "$(dirname -- "$RR_RESTORE_LOCK_FILE")"
: > "$RR_RESTORE_LOCK_FILE"
chmod 600 "$RR_RESTORE_LOCK_FILE"
lock_ready="$TEST_ROOT/lock-ready"
flock "$RR_RESTORE_LOCK_FILE" bash -c 'touch "$1"; sleep 30' _ "$lock_ready" &
LOCK_HOLDER_PID=$!
for _attempt in $(seq 1 100); do
    [ -e "$lock_ready" ] && break
    sleep 0.02
done
[ -e "$lock_ready" ] || fail 'lock holder did not start'
ensure_runtime_health() { rr_retry_certificate_reload_pending; }
rr_run_health_check || fail 'busy timer pass should be an expected skip'
[ "$marker_before" = "$(sha256sum "$RR_CERT_RELOAD_PENDING_DIR/nexus.pending")" ] || \
    fail 'busy health pass changed pending evidence'
[ ! -s "$action_log" ] || fail 'busy health pass ran a consumer action'

echo 'Certificate reload pending regressions passed.'
