#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$ROOT_DIR/scripts/naive-cert-hook.sh"
TEST_ROOT=$(mktemp -d)
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
        printf 'Certificate hook test refuses existing production pending path: %s\n' \
            "$PRODUCTION_PENDING_DIR" >&2
        return 1
    }
}
assert_production_update_lock_absent() {
    [ ! -e /run/rr-vps/locks/update.lock ] && \
        [ ! -L /run/rr-vps/locks/update.lock ] || {
        printf 'Certificate hook test refuses production update lock.\n' >&2
        return 1
    }
}
cleanup_test() {
    local status=$?
    trap - EXIT HUP INT TERM
    if ! assert_production_pending_absent; then
        status=1
    fi
    if ! assert_production_update_lock_absent; then
        status=1
    fi
    if ! snapshot_production_state "$PRODUCTION_STATE_AFTER" || \
       ! cmp -s -- "$PRODUCTION_STATE_BEFORE" "$PRODUCTION_STATE_AFTER"; then
        printf 'Certificate hook test changed a production lock/pending path.\n' >&2
        status=1
    fi
    rm -rf -- "$TEST_ROOT"
    exit "$status"
}
trap cleanup_test EXIT HUP INT TERM
assert_production_pending_absent
assert_production_update_lock_absent

CONFIG="$TEST_ROOT/argo_vmess.conf"
NEXUS_CONFIG="$TEST_ROOT/nexus.json"
LIVE_ROOT="$TEST_ROOT/live"
NAIVE_TARGET="$TEST_ROOT/rr-naive"
CERT_RELOAD_PENDING_DIR="$TEST_ROOT/cert-reload-pending"
RR_LAUNCHER="$TEST_ROOT/rr-never"
RR_CERT_RELOAD_NGINX_BIN="$TEST_ROOT/nginx-never"
RR_CERT_RELOAD_SYSTEMCTL_BIN="$TEST_ROOT/systemctl-never"
LOCK_ROOT="$TEST_ROOT/locks"
UPDATE_LOCK="$LOCK_ROOT/update.lock"
LEGACY_LOCK="$TEST_ROOT/legacy-lock/rr-update.lock"
LEGACY_BRIDGE="$LOCK_ROOT/legacy-update-bridge"
LIVE_LOCK="$LOCK_ROOT/restore-live.lock"
RR_CERT_RELOAD_PENDING_DIR="$CERT_RELOAD_PENDING_DIR"
RR_RESTORE_LOCK_FILE="$UPDATE_LOCK"
RR_LEGACY_UPDATE_LOCK_FILE="$LEGACY_LOCK"
RR_LEGACY_UPDATE_BRIDGE_FILE="$LEGACY_BRIDGE"
RR_RESTORE_LIVE_LOCK_FILE="$LIVE_LOCK"
RR_LE_LIVE_ROOT="$LIVE_ROOT"
RR_NAIVE_CERT_DIR="$NAIVE_TARGET"
RR_CERT_RELOAD_TEST_PROBE=/bin/true
CONFIG_FILE="$CONFIG"
NEXUS_CONFIG_FILE="$NEXUS_CONFIG"
export RR_CERT_RELOAD_PENDING_DIR RR_RESTORE_LOCK_FILE \
    RR_LEGACY_UPDATE_LOCK_FILE RR_LEGACY_UPDATE_BRIDGE_FILE \
    RR_RESTORE_LIVE_LOCK_FILE RR_LE_LIVE_ROOT RR_NAIVE_CERT_DIR \
    RR_CERT_RELOAD_TEST_PROBE CONFIG_FILE NEXUS_CONFIG_FILE RR_LAUNCHER \
    RR_CERT_RELOAD_NGINX_BIN RR_CERT_RELOAD_SYSTEMCTL_BIN
CA_CERT="$TEST_ROOT/test-ca.crt"
CA_KEY="$TEST_ROOT/test-ca.key"
CA_SERIAL="$TEST_ROOT/test-ca.srl"
snapshot_production_state "$PRODUCTION_STATE_BEFORE"
mkdir -p "$LIVE_ROOT"
install -d -m 700 "$LOCK_ROOT" "$(dirname -- "$LEGACY_LOCK")"
printf '%s\n' rr-legacy-update-bridge-v1 > "$LEGACY_BRIDGE"
: > "$LEGACY_LOCK"
chmod 600 "$LEGACY_BRIDGE" "$LEGACY_LOCK"
printf '%s\n' '{"mode":"local"}' > "$NEXUS_CONFIG"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj '/CN=RR certificate hook test CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$CA_KEY" -out "$CA_CERT" >/dev/null 2>&1

make_certificate() {
    local directory="$1" domain="$2" key_source="${3:-}"
    mkdir -p "$directory"
    if [ -n "$key_source" ]; then
        cp "$key_source" "$directory/privkey.pem"
        openssl req -new -key "$directory/privkey.pem" -subj "/CN=$domain" \
            -addext "subjectAltName=DNS:$domain" -out "$directory/request.csr" \
            >/dev/null 2>&1
        openssl x509 -req -days 30 -in "$directory/request.csr" \
            -CA "$CA_CERT" -CAkey "$CA_KEY" -CAserial "$CA_SERIAL" \
            -CAcreateserial -copy_extensions copy \
            -out "$directory/fullchain.pem" >/dev/null 2>&1
        rm -f "$directory/request.csr"
    else
        openssl req -newkey rsa:2048 -nodes \
            -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" \
            -keyout "$directory/privkey.pem" -out "$directory/request.csr" \
            >/dev/null 2>&1
        openssl x509 -req -days 30 -in "$directory/request.csr" \
            -CA "$CA_CERT" -CAkey "$CA_KEY" -CAserial "$CA_SERIAL" \
            -CAcreateserial -copy_extensions copy \
            -out "$directory/fullchain.pem" >/dev/null 2>&1
        rm -f "$directory/request.csr"
    fi
    cp "$directory/fullchain.pem" "$directory/cert.pem"
    chmod 600 "$directory/cert.pem" "$directory/fullchain.pem" \
        "$directory/privkey.pem"
}

make_self_signed_certificate() {
    local directory="$1" domain="$2"
    mkdir -p "$directory"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" \
        -keyout "$directory/privkey.pem" -out "$directory/fullchain.pem" \
        >/dev/null 2>&1
    chmod 600 "$directory/fullchain.pem" "$directory/privkey.pem"
}

make_public_matching_broken_rsa_key() {
    local source_key="$1" output_key="$2" der="$TEST_ROOT/broken-rsa.der"
    openssl rsa -in "$source_key" -traditional -outform DER \
        -out "$der" >/dev/null 2>&1
    python3 - "$der" "$output_key" <<'PY'
import base64
import pathlib
import sys

encoded = bytearray(pathlib.Path(sys.argv[1]).read_bytes())


def read_length(offset):
    first = encoded[offset]
    offset += 1
    if first < 128:
        return first, offset
    count = first & 0x7f
    if not count or count > 4:
        raise SystemExit("invalid PKCS#1 length")
    return int.from_bytes(encoded[offset:offset + count], "big"), offset + count


if not encoded or encoded[0] != 0x30:
    raise SystemExit("invalid PKCS#1 sequence")
sequence_length, offset = read_length(1)
if offset + sequence_length != len(encoded):
    raise SystemExit("invalid PKCS#1 sequence size")
for index in range(9):
    if offset >= len(encoded) or encoded[offset] != 0x02:
        raise SystemExit("invalid PKCS#1 integer")
    integer_length, start = read_length(offset + 1)
    end = start + integer_length
    if end > len(encoded):
        raise SystemExit("truncated PKCS#1 integer")
    if index == 6:
        encoded[end - 1] ^= 1
    offset = end
if offset != len(encoded):
    raise SystemExit("trailing PKCS#1 data")

payload = base64.b64encode(encoded)
pem = (
    b"-----BEGIN RSA PRIVATE KEY-----\n"
    + b"\n".join(payload[pos:pos + 64] for pos in range(0, len(payload), 64))
    + b"\n-----END RSA PRIVATE KEY-----\n"
)
pathlib.Path(sys.argv[2]).write_bytes(pem)
PY
    chmod 600 "$output_key"
}

run_hook() {
    local lineage="$1" rr_cli="${2:-/bin/true}" systemctl_bin="${3:-/bin/true}"
    local nginx_bin="${4:-/bin/true}" hook_log="${5:-$TEST_ROOT/hook.log}"
    RR_CERT_HOOK_CONFIG_FILE="$CONFIG" \
    RR_CERT_HOOK_NEXUS_CONFIG_FILE="$NEXUS_CONFIG" \
    RR_CERT_HOOK_NAIVE_TARGET_DIR="$NAIVE_TARGET" \
    RR_CERT_HOOK_LE_LIVE_ROOT="$LIVE_ROOT" \
    RR_CERT_HOOK_CA_BUNDLE="$CA_CERT" \
    RR_CERT_HOOK_CLI="$rr_cli" \
    RR_CERT_HOOK_SYSTEMCTL="$systemctl_bin" \
    RR_CERT_HOOK_NGINX="$nginx_bin" \
    RR_CERT_RELOAD_PENDING_DIR="$CERT_RELOAD_PENDING_DIR" \
    RR_CERT_RELOAD_TEST_PROBE=/bin/true \
    RR_CERT_HOOK_LOCK_MODULE="$ROOT_DIR/modules/55-resilience.sh" \
    RR_RESTORE_LOCK_FILE="$UPDATE_LOCK" \
    RR_LEGACY_UPDATE_LOCK_FILE="$LEGACY_LOCK" \
    RR_LEGACY_UPDATE_BRIDGE_FILE="$LEGACY_BRIDGE" \
    RR_RESTORE_LIVE_LOCK_FILE="$LIVE_LOCK" \
    RR_CERT_HOOK_TEST_LOG="$hook_log" \
    RR_TEST_FAULTS="${RR_TEST_FAULTS:-0}" \
    RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST="${RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST:-0}" \
    RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST="${RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST:-0}" \
    RR_TEST_CERT_RELOAD_CRASH_AFTER_MARKER="${RR_TEST_CERT_RELOAD_CRASH_AFTER_MARKER:-}" \
    RR_TEST_CERT_HOOK_UNKNOWN_SINGBOX_DROPIN="${RR_TEST_CERT_HOOK_UNKNOWN_SINGBOX_DROPIN:-0}" \
    RENEWED_LINEAGE="$lineage" \
        bash "$HOOK"
}

printf '[1/13] exact Naive lineage, SAN, key, trust and permissions\n'
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=naive.example.test
NAIVE_PORT=18443
SUB_ACCESS_MODE=https
SUB_DOMAIN=sub.example.test
SUB_PORT=19443
EOF
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
make_certificate "$LIVE_ROOT/sub.example.test" sub.example.test
run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/false
cmp -s "$LIVE_ROOT/naive.example.test/fullchain.pem" "$NAIVE_TARGET/fullchain.pem"
cmp -s "$LIVE_ROOT/naive.example.test/privkey.pem" "$NAIVE_TARGET/privkey.pem"
[ "$(stat -c %a "$NAIVE_TARGET")" = 700 ]
[ "$(stat -c %a "$NAIVE_TARGET/fullchain.pem")" = 600 ]
[ "$(stat -c %a "$NAIVE_TARGET/privkey.pem")" = 600 ]

printf '[2/13] subscription lineage refresh is independent\n'
naive_digest=$(sha256sum "$NAIVE_TARGET/fullchain.pem")
run_hook "$LIVE_ROOT/sub.example.test" /bin/true /bin/false
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]
if run_hook "$LIVE_ROOT/sub.example.test" /bin/false /bin/false; then
    echo 'A failed subscription refresh was silently accepted.' >&2
    exit 1
fi
[ -f "$CERT_RELOAD_PENDING_DIR/subscription.pending" ] || {
    echo 'A failed subscription refresh did not retain its pending marker.' >&2
    exit 1
}
rm -f -- "$CERT_RELOAD_PENDING_DIR/subscription.pending"
sync -f "$CERT_RELOAD_PENDING_DIR"

printf '[3/13] unrelated lineage is a no-op\n'
make_certificate "$LIVE_ROOT/unrelated.example.test" unrelated.example.test
run_hook "$LIVE_ROOT/unrelated.example.test" /bin/false /bin/false
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]

printf '[4/13] wrong SAN, mismatched key and inconsistent private key fail closed\n'
cp "$LIVE_ROOT/naive.example.test/fullchain.pem" "$TEST_ROOT/original-naive.crt"
cp "$LIVE_ROOT/naive.example.test/privkey.pem" "$TEST_ROOT/original-naive.key"
make_certificate "$TEST_ROOT/wrong-san" attacker.example.test
cp "$TEST_ROOT/wrong-san/fullchain.pem" "$LIVE_ROOT/naive.example.test/fullchain.pem"
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A certificate with the wrong SAN was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]
cp "$TEST_ROOT/original-naive.crt" "$LIVE_ROOT/naive.example.test/fullchain.pem"
make_public_matching_broken_rsa_key "$TEST_ROOT/original-naive.key" \
    "$LIVE_ROOT/naive.example.test/privkey.pem"
openssl pkey -in "$TEST_ROOT/original-naive.key" -pubout \
    > "$TEST_ROOT/original-naive.pub" 2>/dev/null
openssl pkey -in "$LIVE_ROOT/naive.example.test/privkey.pem" -pubout \
    > "$TEST_ROOT/broken-naive.pub" 2>/dev/null
cmp -s "$TEST_ROOT/original-naive.pub" "$TEST_ROOT/broken-naive.pub"
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A public-matching but internally inconsistent private key was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]
cp "$TEST_ROOT/original-naive.key" "$LIVE_ROOT/naive.example.test/privkey.pem"
cp "$LIVE_ROOT/sub.example.test/privkey.pem" "$LIVE_ROOT/naive.example.test/privkey.pem"
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A certificate/private-key mismatch was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]

printf '[5/13] matching self-signed certificate is rejected\n'
make_self_signed_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A matching self-signed certificate was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]

printf '[6/13] invalid or duplicate config is rejected without sourcing\n'
MUST_NOT_RUN="$TEST_ROOT/config-was-sourced"
cat > "$CONFIG" <<EOF
NAIVE_DOMAIN=naive.example.test
NAIVE_DOMAIN=attacker.example.test
SUB_ACCESS_MODE=local
SUB_DOMAIN=\$(touch $MUST_NOT_RUN)
EOF
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'Duplicate certificate settings were accepted.' >&2
    exit 1
fi
[ ! -e "$MUST_NOT_RUN" ]

printf '[7/13] daemon reload failure propagates to Certbot\n'
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=naive.example.test
NAIVE_PORT=18443
SUB_ACCESS_MODE=local
SUB_DOMAIN=
EOF
# Restore a valid matching pair before exercising only the reload failure.
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if run_hook "$LIVE_ROOT/naive.example.test" /bin/false /bin/true; then
    echo 'A failed sing-box certificate reload was silently accepted.' >&2
    exit 1
fi
[ -f "$CERT_RELOAD_PENDING_DIR/naive.pending" ] && \
    [ ! -L "$CERT_RELOAD_PENDING_DIR/naive.pending" ]

printf '[7b/13] the next locked health pass proves the live certificate and clears pending\n'
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/55-resilience.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/60-update.sh"
NAIVE_ENABLED=true
NAIVE_DOMAIN=naive.example.test
NAIVE_PORT=18443
health_retry_log="$TEST_ROOT/health-retry.log"
: > "$health_retry_log"
restart_singbox() {
    printf 'restart:%s:%s:%s:%s\n' \
        "${RR_UPDATE_LOCK_HELD:-0}" "${RR_RESTORE_LOCK_HELD:-0}" \
        "${RR_UPDATE_LOCK_OWNER:-}" "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" \
        >> "$health_retry_log"
    [ "${RR_UPDATE_LOCK_HELD:-0}:${RR_RESTORE_LOCK_HELD:-0}:\
${RR_UPDATE_LOCK_OWNER:-}:${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1:1:0:1 ]
}
managed_singbox_running() { return 0; }
rr_health_log() { printf 'health:%s\n' "$*" >> "$health_retry_log"; }
ensure_runtime_health() { rr_retry_certificate_reload_pending; }
if ! rr_run_health_check; then
    printf 'Locked health retry failed; log follows:\n' >&2
    cat "$health_retry_log" >&2
    exit 1
fi
[ ! -e "$CERT_RELOAD_PENDING_DIR/naive.pending" ] && \
    [ ! -L "$CERT_RELOAD_PENDING_DIR/naive.pending" ] || {
        printf 'Locked health retry did not clear the Naive marker.\n' >&2
        exit 1
    }
[ "$(cat "$health_retry_log")" = 'restart:1:1:0:1' ] || {
    printf 'Locked health retry used the wrong action context: %s\n' \
        "$(cat "$health_retry_log")" >&2
    exit 1
}

printf '[7c/13] SIGKILL after durable marker publication is recovered idempotently\n'
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
RR_TEST_FAULTS=1 RR_TEST_CERT_RELOAD_CRASH_AFTER_MARKER=naive \
    run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true &
reload_crash_pid=$!
if wait "$reload_crash_pid"; then
    echo 'Certificate hook unexpectedly survived the reload-marker SIGKILL.' >&2
    exit 1
else
    reload_crash_status=$?
    [ "$reload_crash_status" -eq 137 ] || {
        echo "Unexpected reload-marker crash status: $reload_crash_status" >&2
        exit 1
    }
fi
[ -f "$CERT_RELOAD_PENDING_DIR/naive.pending" ]
run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true
[ ! -e "$CERT_RELOAD_PENDING_DIR/naive.pending" ]

printf '[7d/13] a tampered pending marker blocks every certificate mutation\n'
if run_hook "$LIVE_ROOT/naive.example.test" /bin/false /bin/true; then
    echo 'The tamper fixture did not retain a reload marker.' >&2
    exit 1
fi
sed -i 's/^consumer=naive$/consumer=attacker/' \
    "$CERT_RELOAD_PENDING_DIR/naive.pending"
tamper_target_digest=$(sha256sum "$NAIVE_TARGET/fullchain.pem" \
    "$NAIVE_TARGET/privkey.pem")
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A tampered reload marker was silently replaced.' >&2
    exit 1
fi
[ "$tamper_target_digest" = "$(sha256sum "$NAIVE_TARGET/fullchain.pem" \
    "$NAIVE_TARGET/privkey.pem")" ]
rm -f -- "$CERT_RELOAD_PENDING_DIR/naive.pending"
sync -f "$CERT_RELOAD_PENDING_DIR"

printf '[7e/13] malformed Nexus JSON does not starve a valid Naive renewal\n'
printf '%s\n' '{"mode":"public",' > "$NEXUS_CONFIG"
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'Malformed Nexus JSON was not reflected in the aggregate hook status.' >&2
    exit 1
fi
cmp -s "$LIVE_ROOT/naive.example.test/fullchain.pem" \
    "$NAIVE_TARGET/fullchain.pem"
cmp -s "$LIVE_ROOT/naive.example.test/privkey.pem" \
    "$NAIVE_TARGET/privkey.pem"
[ ! -e "$CERT_RELOAD_PENDING_DIR/naive.pending" ] || {
    echo 'Valid Naive renewal did not complete beside malformed Nexus JSON.' >&2
    exit 1
}
printf '%s\n' '{"mode":"local"}' > "$NEXUS_CONFIG"

printf '[8/13] local subscription mode never refreshes a public service\n'
run_hook "$LIVE_ROOT/sub.example.test" /bin/false /bin/false

printf '[8b/13] Naive pair publication fails closed and retries after interruption\n'
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if RR_TEST_FAULTS=1 RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST=1 \
    run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A first-rename certificate publication fault was accepted.' >&2
    exit 1
fi
[ -f "$NAIVE_TARGET/.pair-pending" ] && [ ! -L "$NAIVE_TARGET/.pair-pending" ]
if openssl x509 -in "$NAIVE_TARGET/fullchain.pem" -pubkey -noout 2>/dev/null | \
   sha256sum | cmp -s - <(openssl pkey -in "$NAIVE_TARGET/privkey.pem" -pubout \
       2>/dev/null | sha256sum); then
    echo 'The first-rename fault fixture did not expose the guarded mismatch.' >&2
    exit 1
fi
run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true
[ ! -e "$NAIVE_TARGET/.pair-pending" ] && [ ! -L "$NAIVE_TARGET/.pair-pending" ]
cmp -s "$LIVE_ROOT/naive.example.test/fullchain.pem" "$NAIVE_TARGET/fullchain.pem"
cmp -s "$LIVE_ROOT/naive.example.test/privkey.pem" "$NAIVE_TARGET/privkey.pem"

make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
RR_TEST_FAULTS=1 RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST=1 \
    run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true &
crash_hook_pid=$!
if wait "$crash_hook_pid"; then
    echo 'Certificate hook unexpectedly survived the first-rename SIGKILL.' >&2
    exit 1
else
    crash_hook_status=$?
    [ "$crash_hook_status" -eq 137 ] || {
        echo "Unexpected certificate hook crash status: $crash_hook_status" >&2
        exit 1
    }
fi
[ -f "$NAIVE_TARGET/.pair-pending" ] && [ ! -L "$NAIVE_TARGET/.pair-pending" ]
run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true
[ ! -e "$NAIVE_TARGET/.pair-pending" ] && [ ! -L "$NAIVE_TARGET/.pair-pending" ]
cmp -s "$LIVE_ROOT/naive.example.test/fullchain.pem" "$NAIVE_TARGET/fullchain.pem"
cmp -s "$LIVE_ROOT/naive.example.test/privkey.pem" "$NAIVE_TARGET/privkey.pem"

NGINX_MOCK="$TEST_ROOT/nginx-mock"
SYSTEMCTL_MOCK="$TEST_ROOT/systemctl-mock"
cat > "$NGINX_MOCK" <<'EOF'
#!/bin/bash
printf 'nginx:%s\n' "$*" >> "$RR_CERT_HOOK_TEST_LOG"
case "$#:$1:${2:-}" in
    1:-t:) exit 0 ;;
    2:-s:reload) exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat > "$SYSTEMCTL_MOCK" <<'EOF'
#!/bin/bash
printf 'systemctl:%s\n' "$*" >> "$RR_CERT_HOOK_TEST_LOG"
# Any invocation represents a foreign effective service-control identity.  The
# hook must use Nginx's native signal path and never reach this command.
exit 97
EOF
chmod 755 "$NGINX_MOCK" "$SYSTEMCTL_MOCK"

printf '[9/13] exact Nexus public-domain lineage validates then reloads Nginx once\n'
make_certificate "$LIVE_ROOT/panel.example.test" panel.example.test
printf '%s\n' \
    '{"mode":"public","domain":"panel.example.test","public_port":443}' \
    > "$NEXUS_CONFIG"
NEXUS_LOG="$TEST_ROOT/nexus.log"
: > "$NEXUS_LOG"
run_hook "$LIVE_ROOT/panel.example.test" /bin/false \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"
[ "$(grep -c '^nginx:-t$' "$NEXUS_LOG")" -eq 1 ]
[ "$(grep -c '^nginx:-s reload$' "$NEXUS_LOG")" -eq 1 ]
[ "$(grep -c '^systemctl:' "$NEXUS_LOG" || true)" -eq 0 ]
[ "$(sed -n '1p' "$NEXUS_LOG")" = 'nginx:-t' ]
[ "$(sed -n '2p' "$NEXUS_LOG")" = 'nginx:-s reload' ]
[ "$(wc -l < "$NEXUS_LOG")" -eq 2 ]

printf '[9b/13] malformed main config does not starve a valid Nexus renewal\n'
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=naive.example.test
NAIVE_DOMAIN=attacker.example.test
SUB_ACCESS_MODE=invalid
EOF
: > "$NEXUS_LOG"
if run_hook "$LIVE_ROOT/panel.example.test" /bin/false \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"; then
    echo 'Malformed main config was not reflected in the aggregate hook status.' >&2
    exit 1
fi
[ "$(grep -c '^nginx:-t$' "$NEXUS_LOG")" -eq 1 ]
[ "$(grep -c '^nginx:-s reload$' "$NEXUS_LOG")" -eq 1 ]
[ "$(grep -c '^systemctl:' "$NEXUS_LOG" || true)" -eq 0 ]
[ ! -e "$CERT_RELOAD_PENDING_DIR/nexus.pending" ] || {
    echo 'Valid Nexus renewal did not complete beside malformed main config.' >&2
    exit 1
}
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=
SUB_ACCESS_MODE=local
SUB_DOMAIN=
EOF

printf '[10/13] invalid Nexus pair fails before any Nginx operation\n'
cp "$LIVE_ROOT/panel.example.test/fullchain.pem" "$TEST_ROOT/panel-original.crt"
cp "$TEST_ROOT/wrong-san/fullchain.pem" \
    "$LIVE_ROOT/panel.example.test/fullchain.pem"
: > "$NEXUS_LOG"
if run_hook "$LIVE_ROOT/panel.example.test" /bin/true \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"; then
    echo 'A Nexus lineage with an invalid certificate pair was accepted.' >&2
    exit 1
fi
[ ! -s "$NEXUS_LOG" ]
cp "$TEST_ROOT/panel-original.crt" "$LIVE_ROOT/panel.example.test/fullchain.pem"

printf '[11/13] local, IP and unrelated Nexus modes never reload Nginx\n'
printf '%s\n' '{"mode":"local"}' > "$NEXUS_CONFIG"
: > "$NEXUS_LOG"
run_hook "$LIVE_ROOT/panel.example.test" /bin/false \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"
[ ! -s "$NEXUS_LOG" ]
printf '%s\n' \
    '{"mode":"public","domain":"192.0.2.1","public_port":443}' \
    > "$NEXUS_CONFIG"
run_hook "$LIVE_ROOT/panel.example.test" /bin/false \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"
[ ! -s "$NEXUS_LOG" ]
printf '%s\n' \
    '{"mode":"public","domain":"panel.example.test","public_port":443}' \
    > "$NEXUS_CONFIG"
run_hook "$LIVE_ROOT/unrelated.example.test" /bin/false \
    "$SYSTEMCTL_MOCK" "$NGINX_MOCK" "$NEXUS_LOG"
[ ! -s "$NEXUS_LOG" ]

printf '[12/13] Nexus Nginx validation and reload failures propagate to Certbot\n'
if run_hook "$LIVE_ROOT/panel.example.test" /bin/true \
    /bin/true /bin/false "$NEXUS_LOG"; then
    echo 'A failed Nexus nginx -t was silently accepted.' >&2
    exit 1
fi
NGINX_RELOAD_FAIL="$TEST_ROOT/nginx-reload-fail"
cat > "$NGINX_RELOAD_FAIL" <<'EOF'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "$1" = -t ]; then
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -s ] && [ "$2" = reload ]; then
    exit 1
fi
exit 2
EOF
chmod 755 "$NGINX_RELOAD_FAIL"
if run_hook "$LIVE_ROOT/panel.example.test" /bin/true \
    /bin/true "$NGINX_RELOAD_FAIL" "$NEXUS_LOG"; then
    echo 'A failed Nexus Nginx reload was silently accepted.' >&2
    exit 1
fi

printf '[13/13] one consumer failure does not skip later matching consumers\n'
SHARED_DOMAIN=shared.example.test
make_certificate "$LIVE_ROOT/$SHARED_DOMAIN" "$SHARED_DOMAIN"
cat > "$CONFIG" <<EOF
NAIVE_DOMAIN=$SHARED_DOMAIN
NAIVE_PORT=18443
SUB_ACCESS_MODE=https
SUB_DOMAIN=$SHARED_DOMAIN
SUB_PORT=19443
EOF
printf '%s\n' \
    "{\"mode\":\"public\",\"domain\":\"$SHARED_DOMAIN\",\"public_port\":443}" \
    > "$NEXUS_CONFIG"
AGGREGATE_LOG="$TEST_ROOT/aggregate.log"
AGGREGATE_RR="$TEST_ROOT/aggregate-rr"
AGGREGATE_SYSTEMCTL="$TEST_ROOT/aggregate-systemctl"
cat > "$AGGREGATE_RR" <<'EOF'
#!/bin/bash
# The mock verifies the externally observable delegation contract directly.
# The production authenticator walks /proc ancestors; PID namespace translation
# in containerized CI can hide the outer lock owner even though the exact lock
# remains held, so its wiring is asserted against rr below instead of stubbed.
lock_fd_is_inherited() {
    local lock_identity="" fd="" fd_identity=""
    lock_identity=$(stat -Lc '%d:%i' -- "$1") || return 2
    for fd in /proc/$$/fd/*; do
        fd_identity=$(stat -Lc '%d:%i' -- "$fd" 2>/dev/null) || continue
        [ "$fd_identity" != "$lock_identity" ] || return 0
    done
    return 1
}
printf 'rr:%s\n' "$*" >> "$RR_CERT_HOOK_TEST_LOG"
[ "${RR_UPDATE_LOCK_HELD:-0}:${RR_RESTORE_LOCK_HELD:-0}:$RR_UPDATE_LOCK_OWNER:$RR_UPDATE_LOCK_FDS_CLOSED" = \
    1:1:0:1 ] || exit 91
if lock_fd_is_inherited "$RR_RESTORE_LOCK_FILE"; then exit 93; fi
if lock_fd_is_inherited "$RR_LEGACY_UPDATE_LOCK_FILE"; then exit 94; fi
if flock -n "$RR_RESTORE_LOCK_FILE" true; then exit 92; fi
if flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" true; then exit 95; fi
[ "$#" -eq 1 ] || exit 2
case "$1" in
    --reload-singbox-certificate)
        # Model the production effective-unit checker rejecting an unknown
        # drop-in.  The source assertions below bind this entry to
        # restart_singbox, whose real checker has its own mutation negatives.
        [ "${RR_TEST_CERT_HOOK_UNKNOWN_SINGBOX_DROPIN:-0}" != 1 ]
        ;;
    --refresh-subscription) exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat > "$AGGREGATE_SYSTEMCTL" <<'EOF'
#!/bin/bash
lock_fd_is_inherited() {
    local lock_identity="" fd="" fd_identity=""
    lock_identity=$(stat -Lc '%d:%i' -- "$1") || return 2
    for fd in /proc/$$/fd/*; do
        fd_identity=$(stat -Lc '%d:%i' -- "$fd" 2>/dev/null) || continue
        [ "$fd_identity" != "$lock_identity" ] || return 0
    done
    return 1
}
printf 'systemctl:%s\n' "$*" >> "$RR_CERT_HOOK_TEST_LOG"
[ "${RR_UPDATE_LOCK_HELD:-0}:${RR_RESTORE_LOCK_HELD:-0}:$RR_UPDATE_LOCK_OWNER:$RR_UPDATE_LOCK_FDS_CLOSED" = \
    1:1:0:1 ] || exit 91
if lock_fd_is_inherited "$RR_RESTORE_LOCK_FILE"; then exit 93; fi
if lock_fd_is_inherited "$RR_LEGACY_UPDATE_LOCK_FILE"; then exit 94; fi
if flock -n "$RR_RESTORE_LOCK_FILE" true; then exit 92; fi
if flock -n "$RR_LEGACY_UPDATE_LOCK_FILE" true; then exit 95; fi
# An unknown systemd drop-in may replace ExecReload.  No mutating or read-only
# systemctl call is needed for the native Nginx reload path.
exit 97
EOF
chmod 755 "$AGGREGATE_RR" "$AGGREGATE_SYSTEMCTL"
: > "$AGGREGATE_LOG"
if RR_TEST_CERT_HOOK_UNKNOWN_SINGBOX_DROPIN=1 \
    run_hook "$LIVE_ROOT/$SHARED_DOMAIN" "$AGGREGATE_RR" \
    "$AGGREGATE_SYSTEMCTL" "$NGINX_MOCK" "$AGGREGATE_LOG"; then
    echo 'An unknown Sing-box effective drop-in was silently accepted.' >&2
    exit 1
fi
[ "$(grep -c '^rr:--reload-singbox-certificate$' "$AGGREGATE_LOG")" -eq 1 ]
[ "$(grep -c '^rr:--refresh-subscription$' "$AGGREGATE_LOG")" -eq 1 ]
[ "$(grep -c '^nginx:-t$' "$AGGREGATE_LOG")" -eq 1 ]
[ "$(grep -c '^nginx:-s reload$' "$AGGREGATE_LOG")" -eq 1 ]
[ "$(grep -c '^systemctl:' "$AGGREGATE_LOG" || true)" -eq 0 ]
[ "$(sed -n '1p' "$AGGREGATE_LOG")" = 'rr:--reload-singbox-certificate' ]
[ "$(sed -n '2p' "$AGGREGATE_LOG")" = 'rr:--refresh-subscription' ]
[ "$(sed -n '3p' "$AGGREGATE_LOG")" = 'nginx:-t' ]
[ "$(sed -n '4p' "$AGGREGATE_LOG")" = 'nginx:-s reload' ]
[ "$(wc -l < "$AGGREGATE_LOG")" -eq 4 ]
[ -f "$CERT_RELOAD_PENDING_DIR/naive.pending" ] || {
    echo 'Rejected Sing-box identity did not retain the Naive pending marker.' >&2
    exit 1
}
[ ! -e "$CERT_RELOAD_PENDING_DIR/subscription.pending" ] && \
    [ ! -e "$CERT_RELOAD_PENDING_DIR/nexus.pending" ] || {
    echo 'A rejected Naive identity starved a later certificate consumer.' >&2
    exit 1
}

printf '[14/15] normal multi-consumer reloads preserve Naive, subscription, Nexus order\n'
: > "$AGGREGATE_LOG"
RR_TEST_CERT_HOOK_UNKNOWN_SINGBOX_DROPIN=0 \
    run_hook "$LIVE_ROOT/$SHARED_DOMAIN" "$AGGREGATE_RR" \
        "$AGGREGATE_SYSTEMCTL" "$NGINX_MOCK" "$AGGREGATE_LOG"
[ "$(cat "$AGGREGATE_LOG")" = $'rr:--reload-singbox-certificate\nrr:--refresh-subscription\nnginx:-t\nnginx:-s reload' ] || {
    echo 'Normal multi-consumer service-control order changed.' >&2
    exit 1
}
for pending_consumer in naive subscription nexus; do
    [ ! -e "$CERT_RELOAD_PENDING_DIR/${pending_consumer}.pending" ] || {
        echo "Successful ${pending_consumer} reload retained its pending marker." >&2
        exit 1
    }
done

grep -Fq 'rr_run_mutating_entrypoint rr_cli_reload_singbox_certificate' "$ROOT_DIR/rr"
grep -A12 '^rr_cli_reload_singbox_certificate() {' "$ROOT_DIR/rr" | \
    grep -Fq 'rr_singbox_service_guards_are_effective || return 1'
grep -A14 '^rr_cli_reload_singbox_certificate() {' "$ROOT_DIR/rr" | \
    grep -Fq 'restart_singbox'
grep -Fq '"$RR_CLI" --reload-singbox-certificate' "$HOOK"
if grep -Eq 'try-restart[[:space:]]+sing-box|systemctl.*reload[[:space:]]+nginx|SYSTEMCTL_BIN.*reload' "$HOOK"; then
    echo 'The deploy hook still contains a direct systemd mutation.' >&2
    exit 1
fi

printf '[15/15] a busy update/restore lock blocks every consumer mutation\n'
make_certificate "$LIVE_ROOT/$SHARED_DOMAIN" "$SHARED_DOMAIN"
locked_pair_digest=$(sha256sum "$NAIVE_TARGET/fullchain.pem" \
    "$NAIVE_TARGET/privkey.pem")
: > "$AGGREGATE_LOG"
install -d -m 700 "$LOCK_ROOT"
: > "$UPDATE_LOCK"
chmod 600 "$UPDATE_LOCK"
lock_ready="$TEST_ROOT/hook-lock-ready"
flock "$UPDATE_LOCK" bash -c 'touch "$1"; sleep 10' _ "$lock_ready" &
lock_holder=$!
for _attempt in $(seq 1 100); do
    [ -e "$lock_ready" ] && break
    sleep 0.02
done
[ -e "$lock_ready" ] || { echo 'Certificate hook lock holder did not start.' >&2; exit 1; }
if run_hook "$LIVE_ROOT/$SHARED_DOMAIN" "$AGGREGATE_RR" \
    "$AGGREGATE_SYSTEMCTL" "$NGINX_MOCK" "$AGGREGATE_LOG"; then
    echo 'Certificate hook mutated consumers while the update lock was busy.' >&2
    exit 1
fi
kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
[ "$locked_pair_digest" = "$(sha256sum "$NAIVE_TARGET/fullchain.pem" \
    "$NAIVE_TARGET/privkey.pem")" ] && [ ! -s "$AGGREGATE_LOG" ] || {
        echo 'A busy hook changed a pair, restarted a service or reloaded Nginx.' >&2
        exit 1
    }

echo 'Certificate deploy hook regressions passed.'
