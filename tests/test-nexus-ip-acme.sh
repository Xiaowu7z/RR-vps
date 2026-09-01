#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d /run/rr-nexus-ip-acme-test.XXXXXX)
TLS_SERVER_PID=""
cleanup() {
    [ -z "$TLS_SERVER_PID" ] || kill "$TLS_SERVER_PID" 2>/dev/null || true
    [ -z "$TLS_SERVER_PID" ] || wait "$TLS_SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [ "${1:-}" = "${2:-}" ] || fail "expected '${2:-}', got '${1:-}'"; }

CA="$TMP/ca"
mkdir -m 700 "$CA"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CA/root.key" >/dev/null 2>&1
openssl req -x509 -new -key "$CA/root.key" -days 365 -subj '/CN=RR test root' \
    -out "$CA/root.crt" >/dev/null 2>&1

make_pair() {
    local generation="$1" address="$2" serial="$3" ext=""
    ext="$CA/$generation.ext"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "$CA/$generation.key" >/dev/null 2>&1
    openssl req -new -key "$CA/$generation.key" -subj "/CN=$address" \
        -out "$CA/$generation.csr" >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:%s\n' \
        "$address" > "$ext"
    openssl x509 -req -in "$CA/$generation.csr" -CA "$CA/root.crt" \
        -CAkey "$CA/root.key" -set_serial "$serial" -days 30 -extfile "$ext" \
        -out "$CA/$generation.leaf" >/dev/null 2>&1
    cp "$CA/$generation.leaf" "$CA/$generation.crt"
    printf '\n' >> "$CA/$generation.crt"
    cat "$CA/root.crt" >> "$CA/$generation.crt"
    chmod 600 "$CA/$generation.crt" "$CA/$generation.key"
}
make_pair 1 8.8.8.8 101
make_pair 2 8.8.8.8 102
make_pair 6 2606:4700:4700::1111 103

MOCK="$TMP/lego"
cat > "$MOCK" <<'MOCKEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then
    printf 'lego version 5.4.0 linux/amd64\n'
    exit 0
fi
[ "${1:-}" = run ] || exit 40
shift
path='' address='' name='' webroot=''
accept=0 profile=0 http=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --accept-tos) accept=1; shift ;;
        --email) [ -n "${2:-}" ]; shift 2 ;;
        --domains) address="$2"; shift 2 ;;
        --cert.name) name="$2"; shift 2 ;;
        --path) path="$2"; shift 2 ;;
        --profile) [ "$2" = shortlived ]; profile=1; shift 2 ;;
        --http) http=1; shift ;;
        --http.webroot) webroot="$2"; shift 2 ;;
        --renew-days|--renew-force|--ari-disable) exit 41 ;;
        *) exit 42 ;;
    esac
done
[ "$accept:$profile:$http" = 1:1:1 ]
[ "$address" = 8.8.8.8 ] && [ "$name" = rr-nexus-ip ]
[ -d "$webroot/.well-known/acme-challenge" ]
printf 'run\n' >> "$MOCK_CALLS"
mkdir -p "$path/accounts" "$path/certificates"
printf 'account-preserved\n' > "$path/accounts/registration.json"
[ "${MOCK_LEGO_FAIL:-0}" != 1 ] || exit 44
generation=$(cat "$MOCK_GENERATION")
cp "$MOCK_CA/$generation.crt" "$path/certificates/rr-nexus-ip.crt"
cp "$MOCK_CA/$generation.key" "$path/certificates/rr-nexus-ip.key"
MOCKEOF
chmod 755 "$MOCK"
export MOCK_CALLS="$TMP/calls" MOCK_GENERATION="$TMP/generation" MOCK_CA="$CA"
: > "$MOCK_CALLS"
printf '1\n' > "$MOCK_GENERATION"

export NEXUS_IP_ACME_STATE_ROOT="$TMP/state"
export NEXUS_IP_ACME_ACTIVE_STORE="$TMP/state/active"
export NEXUS_IP_ACME_CANDIDATE_STORE="$TMP/state/candidate"
export NEXUS_IP_ACME_CONFIG="$TMP/state/config.json"
export NEXUS_IP_ACME_JOURNAL="$TMP/state/publication.json"
export NEXUS_IP_ACME_OWNER_MARKER="$TMP/state/.rr-nexus-ip-acme-owner"
export NEXUS_IP_ACME_WEBROOT="$TMP/webroot"
export NEXUS_IP_ACME_WEBROOT_MARKER="$TMP/webroot/.rr-nexus-ip-acme-owner"
export NEXUS_IP_ACME_LIVE_CERT="$TMP/live/ip.crt"
export NEXUS_IP_ACME_LIVE_KEY="$TMP/live/ip.key"
export NEXUS_IP_ACME_PENDING="$TMP/live/.ip-cert-pending"
export NEXUS_IP_ACME_NGINX_AVAILABLE="$TMP/nginx/available/rr-nexus-ip-acme-http.conf"
export NEXUS_IP_ACME_NGINX_ENABLED="$TMP/nginx/enabled/rr-nexus-ip-acme-http.conf"
export NEXUS_IP_ACME_SERVICE_FILE="$TMP/systemd/rr-nexus-ip-acme.service"
export NEXUS_IP_ACME_TIMER_FILE="$TMP/systemd/rr-nexus-ip-acme.timer"
export NEXUS_IP_ACME_LEGO_BIN="$MOCK"
export NEXUS_IP_ACME_LEGO_MARKER="$TMP/lego.install"
export NEXUS_CONFIG_FILE="$TMP/nexus.json"
export NEXUS_NGINX_AVAILABLE_DIR="$TMP/nginx/available"
export NEXUS_NGINX_ENABLED_DIR="$TMP/nginx/enabled"
export RR_CA_BUNDLE="$CA/root.crt"
export RR_RESTORE_ACTIVE="$TMP/restore-active"
export RR_TEST_IP_ACME=1 RR_TEST_IP_ACME_SKIP_NGINX_RELOAD=1
export RR_TEST_IP_ACME_SKIP_HTTP_PROBE=1

set +u
source "$ROOT/modules/20-config.sh"
source "$ROOT/modules/85-nexus.sh"
source "$ROOT/modules/86-nexus-ip-acme.sh"
set -u

# modules/85 defines these deployment paths unconditionally; redirect its
# read-only TLS-site context into the isolated fixture after loading it.
NEXUS_CONFIG_FILE="$TMP/nexus.json"
NEXUS_NGINX_AVAILABLE_DIR="$TMP/nginx/available"
NEXUS_NGINX_ENABLED_DIR="$TMP/nginx/enabled"
NEXUS_CERT_DIR="$TMP/live"
is_valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

mkdir -m 700 "$TMP/live"
mkdir -m 755 "$TMP/nginx" "$TMP/nginx/available" "$TMP/nginx/enabled" "$TMP/systemd"
mock_sha=$(sha256sum "$MOCK" | awk '{print $1}')
mock_size=$(stat -c %s "$MOCK")
case "$(uname -m)" in
    x86_64)
        mock_arch=amd64
        NEXUS_IP_ACME_LEGO_AMD64_BINARY_SIZE="$mock_size"
        NEXUS_IP_ACME_LEGO_AMD64_BINARY_SHA256="$mock_sha"
        ;;
    aarch64|arm64)
        mock_arch=arm64
        NEXUS_IP_ACME_LEGO_ARM64_BINARY_SIZE="$mock_size"
        NEXUS_IP_ACME_LEGO_ARM64_BINARY_SHA256="$mock_sha"
        ;;
    *) fail 'unsupported test architecture' ;;
esac
nexus_ip_acme_write_lego_marker "$mock_arch"
printf '%s\n' \
    '{"mode":"public","domain":"8.8.8.8","public_port":18443,"certificate_mode":"pending-acme-ip"}' \
    > "$NEXUS_CONFIG_FILE"
chmod 600 "$NEXUS_CONFIG_FILE"

# External service commands are mocked, but their order/state is recorded.
NGINX_ACTIVE=0
IP_TIMER_ENABLED=0
IP_TIMER_ACTIVE=0
IP_SERVICE_ACTIVE=0
IP_SERVICE_EXEC_STOP=""
SYSTEMCTL_SHOW_FAIL=0
SYSTEMCTL_LOG="$TMP/systemctl.log"
: > "$SYSTEMCTL_LOG"
systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    local command="${1:-}" name="${2:-}" property=""
    case "$command:$name" in
        show:rr-nexus-ip-acme.service|show:rr-nexus-ip-acme.timer)
            property="${4:-}"
            if [ "$name" = rr-nexus-ip-acme.service ]; then
                case "$property" in
                    LoadState) [ -f "$NEXUS_IP_ACME_SERVICE_FILE" ] && printf 'loaded\n' || printf 'not-found\n' ;;
                    FragmentPath) [ -f "$NEXUS_IP_ACME_SERVICE_FILE" ] && printf '%s\n' "$NEXUS_IP_ACME_SERVICE_FILE" || printf '\n' ;;
                    DropInPaths) printf '\n' ;;
                    Type) printf 'oneshot\n' ;;
                    User|Group) printf 'root\n' ;;
                    UMask) printf '0077\n' ;;
                    SuccessExitStatus) printf '75\n' ;;
                    UnitFileState) [ -f "$NEXUS_IP_ACME_SERVICE_FILE" ] && printf 'static\n' || printf '\n' ;;
                    ExecStart) printf '{ path=%s ; argv[]=%s --nexus-ip-acme-renew ; }\n' "$NEXUS_IP_ACME_RR_BIN" "$NEXUS_IP_ACME_RR_BIN" ;;
                    ExecCondition)
                        printf '%s\n' "{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /run/rr-vps/update-maintenance ] && [ ! -L /run/rr-vps/update-maintenance ] && [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] ; ignore_errors=no ; }"
                        ;;
                    ExecStartPre|ExecStartPost|ExecReload|ExecStopPost) printf '\n' ;;
                    ExecStop) printf '%s\n' "$IP_SERVICE_EXEC_STOP" ;;
                    Environment|EnvironmentFiles|PassEnvironment|UnsetEnvironment) printf '\n' ;;
                    ActiveState) [ "$IP_SERVICE_ACTIVE" = 1 ] && printf 'activating\n' || printf 'inactive\n' ;;
                    SubState) [ "$IP_SERVICE_ACTIVE" = 1 ] && printf 'start\n' || printf 'dead\n' ;;
                    MainPID) printf '0\n' ;;
                    *) return 1 ;;
                esac
            else
                case "$property" in
                    LoadState) [ -f "$NEXUS_IP_ACME_TIMER_FILE" ] && printf 'loaded\n' || printf 'not-found\n' ;;
                    FragmentPath) [ -f "$NEXUS_IP_ACME_TIMER_FILE" ] && printf '%s\n' "$NEXUS_IP_ACME_TIMER_FILE" || printf '\n' ;;
                    DropInPaths) printf '\n' ;;
                    Unit) printf 'rr-nexus-ip-acme.service\n' ;;
                    OnActiveUSec) printf '15min\n' ;;
                    OnUnitActiveUSec) printf '12h\n' ;;
                    RandomizedDelayUSec) printf '30min\n' ;;
                    Persistent) printf 'no\n' ;;
                    UnitFileState)
                        if [ -f "$NEXUS_IP_ACME_TIMER_FILE" ]; then
                            [ "$IP_TIMER_ENABLED" = 1 ] && printf 'enabled\n' || printf 'disabled\n'
                        else
                            printf '\n'
                        fi
                        ;;
                    ActiveState) [ "$IP_TIMER_ACTIVE" = 1 ] && printf 'active\n' || printf 'inactive\n' ;;
                    SubState) [ "$IP_TIMER_ACTIVE" = 1 ] && printf 'waiting\n' || printf 'dead\n' ;;
                    *) return 1 ;;
                esac
            fi
            [ "$SYSTEMCTL_SHOW_FAIL" = 0 ] || return 1
            ;;
        is-active:--quiet)
            case "${3:-}" in
                nginx) [ "$NGINX_ACTIVE" = 1 ] ;;
                rr-nexus-ip-acme.timer) [ "$IP_TIMER_ACTIVE" = 1 ] ;;
                rr-nexus-ip-acme.service) [ "$IP_SERVICE_ACTIVE" = 1 ] ;;
                *) return 1 ;;
            esac
            ;;
        is-enabled:--quiet)
            [ "${3:-}" = rr-nexus-ip-acme.timer ] && [ "$IP_TIMER_ENABLED" = 1 ]
            ;;
        is-enabled:rr-nexus-ip-acme.service)
            [ -f "$NEXUS_IP_ACME_SERVICE_FILE" ] && printf 'static\n' && return 1
            printf 'not-found\n'
            return 4
            ;;
        is-enabled:rr-nexus-ip-acme.timer)
            if [ -f "$NEXUS_IP_ACME_TIMER_FILE" ]; then
                if [ "$IP_TIMER_ENABLED" = 1 ]; then printf 'enabled\n'; return 0; fi
                printf 'disabled\n'
                return 1
            fi
            printf 'not-found\n'
            return 4
            ;;
        start:nginx) NGINX_ACTIVE=1 ;;
        enable:--now)
            [ "${3:-}" = rr-nexus-ip-acme.timer ] || return 1
            IP_TIMER_ENABLED=1
            IP_TIMER_ACTIVE=1
            ;;
        disable:--now)
            [ "${3:-}" = rr-nexus-ip-acme.timer ] || return 1
            IP_TIMER_ENABLED=0
            IP_TIMER_ACTIVE=0
            ;;
        disable:rr-nexus-ip-acme.service) : ;;
        stop:rr-nexus-ip-acme.service) IP_SERVICE_ACTIVE=0 ;;
        reset-failed:rr-nexus-ip-acme.service) IP_SERVICE_ACTIVE=0 ;;
        daemon-reload:*) : ;;
        *) return 1 ;;
    esac
}
nginx() {
    [ "${1:-}" = -t ] || [ "${1:-}:${2:-}" = -s:reload ]
}

# Existing pair APIs are exercised for the live transaction.  The gate mock
# proves a clean host starts Nginx for HTTP-01 before the TLS gate is installed.
GATE_READY=0
GATE_LOG="$TMP/gate.log"
: > "$GATE_LOG"
nexus_install_ip_certificate_gate() {
    [ "$NGINX_ACTIVE" = 1 ] || fail 'certificate gate installed before HTTP-only Nginx start'
    GATE_READY=1
    printf 'gate\n' >> "$GATE_LOG"
}
nexus_ip_certificate_gate_artifacts_are_current() { [ "$GATE_READY" = 1 ]; }
nexus_nginx_exec_condition_set_is_exact() { [ "$GATE_READY" = 1 ]; }
nexus_ip_certificate_gate_allows() { [ "$GATE_READY" = 1 ]; }

# Global-only policy, canonicalization and IPv6 URL semantics.
nexus_ip_acme_is_global_address 8.8.8.8 || fail 'global IPv4 rejected'
nexus_ip_acme_is_global_address 2606:4700:4700::1111 || fail 'global IPv6 rejected'
for bad in 127.0.0.1 10.0.0.1 ::1 fc00::1 fe80::1 2001:db8::1 example.com; do
    ! nexus_ip_acme_is_global_address "$bad" || fail "accepted non-global $bad"
done
eq "$(nexus_ip_acme_normalize_address 2606:4700:4700:0:0:0:0:1111)" \
    '2606:4700:4700::1111'
eq "$(nexus_ip_acme_public_url 2606:4700:4700:0:0:0:0:1111 443 /sub/x)" \
    'https://[2606:4700:4700::1111]/sub/x'
nexus_ip_acme_pair_is_trusted "$CA/6.crt" "$CA/6.key" \
    2606:4700:4700:0:0:0:0:1111 || fail 'expanded IPv6 did not match canonical SAN'
! nexus_ip_acme_public_url 10.0.0.1 80 /sub/x >/dev/null || fail 'private/HTTP fallback'

# Immutable lego anchors and real v5 CLI version form.
nexus_ip_acme_lego_marker_is_current || fail 'lego ownership marker rejected'
grep -Fq '"$binary" --version' "$ROOT/modules/86-nexus-ip-acme.sh" || fail 'wrong lego version syntax'
grep -Fq 'd3adf89392d606ce84d485c1cc20832edd42ace6ff9ced9dd3670d9d8b8aca38' \
    "$ROOT/modules/86-nexus-ip-acme.sh" || fail 'amd64 pin absent'
grep -Fq 'a86e946e0415e14e28d6dfe3c95914b088b3f5f6e13209e07e2e8c3a64d7280b' \
    "$ROOT/modules/86-nexus-ip-acme.sh" || fail 'arm64 pin absent'

# Either independently pinned half of lego's binary/marker publication is
# recoverable. A binary-only crash never downloads; a marker-only crash may
# fetch only the exact pinned archive and publishes the exact extracted hash.
(
    half="$TMP/lego-binary-half"
    mkdir -m 755 "$half"
    cp "$MOCK" "$half/lego"
    chmod 755 "$half/lego"
    NEXUS_IP_ACME_LEGO_BIN="$half/lego"
    NEXUS_IP_ACME_LEGO_MARKER="$half/lego.install"
    curl() { fail 'binary-only lego recovery attempted a download'; }
    nexus_ip_acme_install_lego || fail 'binary-only lego recovery failed'
    nexus_ip_acme_lego_marker_is_current || fail 'binary-only recovery did not settle marker'
)
(
    half="$TMP/lego-marker-half"
    source_dir="$TMP/lego-archive-source"
    mkdir -m 755 "$half" "$source_dir"
    cp "$MOCK" "$source_dir/lego"
    chmod 755 "$source_dir/lego"
    HALF_ARCHIVE="$TMP/mock-lego.tar.gz"
    tar -czf "$HALF_ARCHIVE" -C "$source_dir" lego
    archive_size=$(stat -c %s "$HALF_ARCHIVE")
    archive_sha=$(sha256sum "$HALF_ARCHIVE" | awk '{print $1}')
    NEXUS_IP_ACME_LEGO_BIN="$half/lego"
    NEXUS_IP_ACME_LEGO_MARKER="$half/lego.install"
    if [ "$mock_arch" = amd64 ]; then
        NEXUS_IP_ACME_LEGO_AMD64_SIZE="$archive_size"
        NEXUS_IP_ACME_LEGO_AMD64_SHA256="$archive_sha"
    else
        NEXUS_IP_ACME_LEGO_ARM64_SIZE="$archive_size"
        NEXUS_IP_ACME_LEGO_ARM64_SHA256="$archive_sha"
    fi
    nexus_ip_acme_write_lego_marker "$mock_arch"
    curl() {
        local output=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then output="$2"; shift 2; else shift; fi
        done
        [ -n "$output" ] || return 1
        command cp "$HALF_ARCHIVE" "$output"
    }
    nexus_ip_acme_install_lego || fail 'marker-only lego recovery failed'
    nexus_ip_acme_lego_marker_is_current || fail 'marker-only recovery did not settle binary'
)

nexus_ip_acme_prepare_state_root
nexus_ip_acme_write_config 8.8.8.8 ops@example.com
nexus_ip_acme_prepare_webroot
nexus_ip_acme_install_nginx_http_site 8.8.8.8 || fail 'HTTP-01 site install failed'
[ "$NGINX_ACTIVE" = 1 ] || fail 'clean inactive Nginx was not started for HTTP-01'
grep -Fq 'server_name 8.8.8.8;' "$NEXUS_IP_ACME_NGINX_AVAILABLE" || fail 'IPv4 server_name wrong'
grep -Fq 'return 444;' "$NEXUS_IP_ACME_NGINX_AVAILABLE" || fail 'HTTP site exposes non-challenge path'

v6_site=$(nexus_ip_acme_emit_nginx_http_site 2606:4700:4700:0:0:0:0:1111)
grep -Fq 'server_name [2606:4700:4700::1111];' <<<"$v6_site" || fail 'IPv6 server_name not canonical/bracketed'

# Served-leaf decisions are bound to the exact module/85 renderer, not a
# handful of matching directives inside a foreign server block.
tls_site="$NEXUS_NGINX_AVAILABLE_DIR/rr-nexus-ip.conf"
tls_enabled="$NEXUS_NGINX_ENABLED_DIR/rr-nexus-ip.conf"
nexus_emit_nginx_ip_site 8.8.8.8 18443 pending-acme-ip > "$tls_site"
chmod 644 "$tls_site"
ln -s "$tls_site" "$tls_enabled"
nexus_ip_acme_tls_site_context_readonly 8.8.8.8 tls_state tls_port || \
    fail 'exact TLS site context rejected'
eq "$tls_state:$tls_port" 'present:18443'
printf '    proxy_pass http://attacker.invalid;\n' >> "$tls_site"
! nexus_ip_acme_tls_site_context_readonly 8.8.8.8 tls_state tls_port || \
    fail 'TLS site with extra directive accepted'
nexus_emit_nginx_ip_site 8.8.8.8 18443 pending-acme-ip > "$tls_site"
chmod 644 "$tls_site"
unlink "$tls_enabled"
unlink "$tls_site"

# Foreign site/link collisions are never adopted or replaced.
foreign="$TMP/nginx/available/foreign.conf"
printf 'foreign\n' > "$foreign"
old_available="$NEXUS_IP_ACME_NGINX_AVAILABLE" old_enabled="$NEXUS_IP_ACME_NGINX_ENABLED"
NEXUS_IP_ACME_NGINX_AVAILABLE="$foreign"
NEXUS_IP_ACME_NGINX_ENABLED="$TMP/nginx/enabled/foreign.conf"
! nexus_ip_acme_install_nginx_http_site 8.8.8.8 || fail 'foreign site was overwritten'
grep -Fxq foreign "$foreign" || fail 'foreign site changed'
NEXUS_IP_ACME_NGINX_AVAILABLE="$old_available"
NEXUS_IP_ACME_NGINX_ENABLED="$old_enabled"

unlink "$NEXUS_IP_ACME_NGINX_ENABLED"
ln -s "$foreign" "$NEXUS_IP_ACME_NGINX_ENABLED"
! nexus_ip_acme_install_nginx_http_site 8.8.8.8 || fail 'foreign enabled symlink was adopted'
[ "$(readlink "$NEXUS_IP_ACME_NGINX_ENABLED")" = "$foreign" ] || fail 'foreign symlink changed'
unlink "$NEXUS_IP_ACME_NGINX_ENABLED"
ln -s "$NEXUS_IP_ACME_NGINX_AVAILABLE" "$NEXUS_IP_ACME_NGINX_ENABLED"

# Initial CA success: active store is committed before the live pair.
nexus_ip_acme_renew_locked || fail 'initial issuance failed'
eq "$(wc -l < "$MOCK_CALLS")" 1
eq "$(wc -l < "$GATE_LOG")" 1
active1=$(nexus_ip_acme_store_fingerprint "$NEXUS_IP_ACME_ACTIVE_STORE" 8.8.8.8 ops@example.com)
eq "$(nexus_ip_acme_live_fingerprint 8.8.8.8)" "$active1"
[ ! -e "$NEXUS_IP_ACME_JOURNAL" ] && [ ! -e "$NEXUS_IP_ACME_CANDIDATE_STORE" ] || \
    fail 'settled transaction left recovery state'
[ ! -e "$NEXUS_IP_ACME_PENDING" ] || fail 'settled transaction left pair pending'

# The normal renewal proof compares the leaf actually served by a trusted TLS
# handshake with the first leaf in the newly published live fullchain.
tls_test_port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)
openssl s_server -quiet -accept "127.0.0.1:$tls_test_port" \
    -cert "$CA/1.crt" -key "$CA/1.key" >/dev/null 2>&1 &
TLS_SERVER_PID=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    nexus_ip_acme_served_leaf_matches_live 8.8.8.8 "$tls_test_port" && break
    sleep 0.1
done
nexus_ip_acme_served_leaf_matches_live 8.8.8.8 "$tls_test_port" || \
    fail 'served trusted leaf did not match live leaf'
cp "$CA/2.crt" "$NEXUS_IP_ACME_LIVE_CERT"
cp "$CA/2.key" "$NEXUS_IP_ACME_LIVE_KEY"
chmod 644 "$NEXUS_IP_ACME_LIVE_CERT"
chmod 600 "$NEXUS_IP_ACME_LIVE_KEY"
! nexus_ip_acme_served_leaf_matches_live 8.8.8.8 "$tls_test_port" || \
    fail 'served old leaf matched a different live generation'
cp "$CA/1.crt" "$NEXUS_IP_ACME_LIVE_CERT"
cp "$CA/1.key" "$NEXUS_IP_ACME_LIVE_KEY"
chmod 644 "$NEXUS_IP_ACME_LIVE_CERT"
chmod 600 "$NEXUS_IP_ACME_LIVE_KEY"
kill "$TLS_SERVER_PID" 2>/dev/null || true
wait "$TLS_SERVER_PID" 2>/dev/null || true
TLS_SERVER_PID=""

# A failure before pair publication removes both exact live temp names; the
# private-key half cannot survive because GNU unlink is invoked one path at a time.
(
    copy_count=0
    nexus_ip_acme_live_fingerprint() { return 1; }
    cp() {
        copy_count=$((copy_count + 1))
        [ "$copy_count" -ne 2 ] || return 28
        command cp "$@"
    }
    ! nexus_ip_acme_publish_live 8.8.8.8 ops@example.com || \
        fail 'injected live temp copy failure accepted'
    ! find "$TMP/live" -maxdepth 1 -name '.ip-acme.*' -print -quit | grep -q . || \
        fail 'live certificate/private-key temp survived failure'
)

cp -a "$NEXUS_IP_ACME_ACTIVE_STORE" \
    "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.4242"
nexus_ip_acme_cleanup_candidate_stages || fail 'safe candidate stage cleanup failed'
[ ! -e "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.4242" ] || \
    fail 'safe candidate stage orphan survived cleanup'
ln -s "$NEXUS_IP_ACME_ACTIVE_STORE" \
    "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.4343"
! nexus_ip_acme_cleanup_candidate_stages || fail 'linked candidate stage was deleted'
[ -L "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.4343" ] || \
    fail 'foreign candidate stage link disappeared'
unlink "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.4343"

# CA failure and ENOSPC leave healthy live bytes untouched and retain account.
live_before=$(sha256sum "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY")
export MOCK_LEGO_FAIL=1
! nexus_ip_acme_renew_locked || fail 'CA failure accepted'
unset MOCK_LEGO_FAIL
eq "$(sha256sum "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY")" "$live_before"
[ "$(cat "$NEXUS_IP_ACME_CANDIDATE_STORE/accounts/registration.json")" = account-preserved ] || \
    fail 'failed candidate account discarded'

printf '2\n' > "$MOCK_GENERATION"
export RR_TEST_IP_ACME_FAULT=after_lego
calls=$(wc -l < "$MOCK_CALLS")
! nexus_ip_acme_renew_locked || fail 'after_lego crash accepted'
unset RR_TEST_IP_ACME_FAULT
eq "$(wc -l < "$MOCK_CALLS")" "$((calls + 1))"
calls=$(wc -l < "$MOCK_CALLS")
nexus_ip_acme_renew_locked || fail 'orphan CA result recovery failed'
eq "$(wc -l < "$MOCK_CALLS")" "$calls"
active2=$(nexus_ip_acme_store_fingerprint "$NEXUS_IP_ACME_ACTIVE_STORE" 8.8.8.8 ops@example.com)
[ "$active2" != "$active1" ] || fail 'new generation not committed'
eq "$(nexus_ip_acme_live_fingerprint 8.8.8.8)" "$active2"

printf '1\n' > "$MOCK_GENERATION"
live_before=$(sha256sum "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY")
(
    nexus_ip_acme_write_journal() { return 28; }
    ! nexus_ip_acme_renew_locked
) || fail 'ENOSPC injection not rejected'
eq "$(sha256sum "$NEXUS_IP_ACME_LIVE_CERT" "$NEXUS_IP_ACME_LIVE_KEY")" "$live_before"
nexus_ip_acme_store_pair_is_trusted "$NEXUS_IP_ACME_CANDIDATE_STORE" 8.8.8.8 ops@example.com || \
    fail 'ENOSPC candidate destroyed'
nexus_ip_acme_recover_locked 8.8.8.8 || fail 'ENOSPC candidate recovery failed'

# Store-first crash recovery never invokes lego again.
printf '2\n' > "$MOCK_GENERATION"
export RR_TEST_IP_ACME_FAULT=after_store
calls=$(wc -l < "$MOCK_CALLS")
! nexus_ip_acme_renew_locked || fail 'after_store crash accepted'
unset RR_TEST_IP_ACME_FAULT
store_crash=$(nexus_ip_acme_store_fingerprint "$NEXUS_IP_ACME_ACTIVE_STORE" 8.8.8.8 ops@example.com)
[ "$(nexus_ip_acme_live_fingerprint 8.8.8.8)" != "$store_crash" ] || fail 'live changed before store fault'
nexus_ip_acme_recover_locked 8.8.8.8 || fail 'store-first recovery failed'
eq "$(wc -l < "$MOCK_CALLS")" "$((calls + 1))"
eq "$(nexus_ip_acme_live_fingerprint 8.8.8.8)" "$store_crash"

# Crash after only the key rename leaves pending fail-closed; recovery
# republishes both halves from active without CA activity.
printf '1\n' > "$MOCK_GENERATION"
calls=$(wc -l < "$MOCK_CALLS")
(
    nexus_publish_ip_certificate_pair() {
        nexus_ip_certificate_mark_pending "$5" "$6" || return 1
        mv -f -- "$2" "$4"
        sync -f "$5"
        return 73
    }
    ! nexus_ip_acme_renew_locked
) || fail 'key-half crash not rejected'
[ -e "$NEXUS_IP_ACME_PENDING" ] || fail 'pending marker absent after key-half crash'
! nexus_ip_certificate_pair_is_ready "$NEXUS_IP_ACME_LIVE_CERT" \
    "$NEXUS_IP_ACME_LIVE_KEY" 8.8.8.8 || fail 'mixed live pair considered ready'
nexus_ip_acme_recover_locked 8.8.8.8 || fail 'key-half recovery failed'
eq "$(wc -l < "$MOCK_CALLS")" "$((calls + 1))"
[ ! -e "$NEXUS_IP_ACME_PENDING" ] || fail 'pending marker survived recovery'

# Foreign webroot/state refusal and static 12-hour systemd contract.
foreign_root="$TMP/foreign-webroot"
mkdir -m 755 "$foreign_root"
printf 'foreign\n' > "$foreign_root/index.html"
save_root="$NEXUS_IP_ACME_WEBROOT" save_marker="$NEXUS_IP_ACME_WEBROOT_MARKER"
NEXUS_IP_ACME_WEBROOT="$foreign_root"
NEXUS_IP_ACME_WEBROOT_MARKER="$foreign_root/.rr-nexus-ip-acme-owner"
! nexus_ip_acme_prepare_webroot || fail 'foreign webroot adopted'
[ -f "$foreign_root/index.html" ] || fail 'foreign webroot deleted'
NEXUS_IP_ACME_WEBROOT="$save_root"
NEXUS_IP_ACME_WEBROOT_MARKER="$save_marker"

# Every ancestor is immutable in the path authority proof. A safe-looking
# immediate parent below a writable ancestor and a symlink component are both
# rejected before the first owner marker is written through them.
mkdir -m 777 "$TMP/writable-ancestor"
mkdir -m 700 "$TMP/writable-ancestor/child"
! nexus_ip_acme_parent_directory_is_safe \
    "$TMP/writable-ancestor/child/file" || fail 'writable higher ancestor accepted'
chmod 700 "$TMP/writable-ancestor"
outside="$TMP/outside-state"
mkdir -m 700 "$outside"
ln -s "$outside" "$TMP/state-link"
(
    NEXUS_IP_ACME_STATE_ROOT="$TMP/state-link/state"
    NEXUS_IP_ACME_ACTIVE_STORE="$TMP/state-link/state/active"
    NEXUS_IP_ACME_CANDIDATE_STORE="$TMP/state-link/state/candidate"
    NEXUS_IP_ACME_CONFIG="$TMP/state-link/state/config.json"
    NEXUS_IP_ACME_JOURNAL="$TMP/state-link/state/publication.json"
    NEXUS_IP_ACME_OWNER_MARKER="$TMP/state-link/state/.rr-nexus-ip-acme-owner"
    ! nexus_ip_acme_prepare_state_root || fail 'symlink ancestor state root accepted'
)
[ ! -e "$outside/state" ] && [ ! -L "$outside/state" ] || \
    fail 'state owner marker was written through symlink ancestor'
unlink "$TMP/state-link"

service=$(nexus_ip_acme_emit_service_unit)
timer=$(nexus_ip_acme_emit_timer_unit)
grep -Fq 'User=root' <<<"$service" && grep -Fq 'Group=root' <<<"$service" || fail 'service identity'
grep -Fq 'UMask=0077' <<<"$service" || fail 'service UMask'
grep -Fq 'SuccessExitStatus=75' <<<"$service" || fail 'maintenance exit is not successful'
grep -Fq "ExecCondition=/bin/sh -c '[ ! -e /run/rr-vps/update-maintenance ]" \
    <<<"$service" || fail 'service lacks pre-source update maintenance gate'
grep -Fq '[ ! -e /var/lib/rr-backup/active ]' <<<"$service" || \
    fail 'service lacks pre-source restore gate'
! grep -Fq '[Install]' <<<"$service" || fail 'service is not static'
grep -Fq 'OnUnitActiveSec=12h' <<<"$timer" || fail 'timer is not 12-hour'
grep -Fq 'OnActiveSec=15min' <<<"$timer" || fail 'timer first run is boot-relative'
! grep -Fq 'OnBootSec=' <<<"$timer" || fail 'timer can fire immediately on an old boot'
! grep -Fq 'Persistent=true' <<<"$timer" || fail 'monotonic timer incorrectly marked persistent'
! grep -Eqi 'self.?sign|http://|insecure' <<<"$service$timer" || fail 'insecure fallback in units'

# A timer/update race must exit before even entering the renewal/lock/CA
# callback chain while update maintenance exists.
maintenance="$TMP/update-maintenance"
printf 'busy\n' > "$maintenance"
(
    touched="$TMP/maintenance-side-effect"
    nexus_ip_acme_renew() { printf 'renew\n' >> "$touched"; }
    rr_run_with_update_locks() { printf 'lock\n' >> "$touched"; }
    nexus_ip_acme_run_lego_candidate() { printf 'ca\n' >> "$touched"; }
    status=0
    RR_UPDATE_MAINTENANCE_FILE="$maintenance" \
        nexus_ip_acme_service_entry || status=$?
    eq "$status" 75
    [ ! -e "$touched" ] || fail 'maintenance timer entered renewal/lock/CA path'
)
unlink "$maintenance"

# Install validates the HTTP site before consuming a prior publication journal.
(
    order="$TMP/install-order"
    : > "$order"
    nexus_ip_acme_install_nginx_http_site() {
        [ "${2:-}" = validate-only ] || return 1
        printf 'site\n' >> "$order"
    }
    nexus_ip_acme_recover_locked() {
        grep -Fxq site "$order" || return 1
        printf 'recover\n' >> "$order"
        NEXUS_IP_ACME_RECOVERED_PUBLICATION=1
    }
    nexus_ip_acme_install_units() { :; }
    nexus_ip_acme_install_locked 8.8.8.8 ops@example.com || \
        fail 'install did not establish HTTP site before recovery'
    eq "$(cat "$order")" $'site\nrecover'
)

nexus_ip_acme_disarm_locked || fail 'disarm should be idempotent before unit creation'
nexus_ip_acme_has_recoverable_state 8.8.8.8 || fail 'disarm destroyed recoverable CA state'
nexus_ip_acme_owned_state_is_safe 8.8.8.8 || fail 'owned state proof rejected valid tree'
nexus_ip_acme_install_units || fail 'exact unit installation failed'
[ "$IP_TIMER_ENABLED:$IP_TIMER_ACTIVE:$IP_SERVICE_ACTIVE" = 1:1:0 ] || \
    fail 'timer install triggered service or failed to arm'
nexus_ip_acme_timer_is_armed_exact || fail 'armed timer state was not exact'
nexus_ip_acme_service_is_quiescent_exact || fail 'service not quiescent after timer enable'
(
    SYSTEMCTL_SHOW_FAIL=1
    ! nexus_ip_acme_effective_service_is_exact || \
        fail 'D-Bus failure with expected output was accepted'
)
(
    IP_SERVICE_EXEC_STOP='{ path=/bin/evil ; argv[]=/bin/evil ; }'
    stop_log_start=$(wc -l < "$SYSTEMCTL_LOG")
    status=0
    nexus_ip_acme_disarm_locked || status=$?
    eq "$status" 2
    if tail -n "+$((stop_log_start + 1))" "$SYSTEMCTL_LOG" | \
        grep -Fq 'stop rr-nexus-ip-acme.service'; then
        fail 'foreign effective ExecStop ran before disarm refusal'
    fi
)

# runtime_is_ready is a pure observation: systemd `show` is allowed, but no
# daemon reload/start/enable or crash-temp cleanup may occur.
log_before=$(wc -l < "$SYSTEMCTL_LOG")
nexus_ip_acme_runtime_is_ready 8.8.8.8 || fail 'settled runtime proof failed'
tail -n "+$((log_before + 1))" "$SYSTEMCTL_LOG" | \
    grep -Eq '^(daemon-reload|enable|disable|start|stop|reset-failed)( |$)' && \
    fail 'read-only runtime proof mutated systemd'
printf 'orphan\n' > "$NEXUS_IP_ACME_STATE_ROOT/.rr-ip-acme.ABC123"
chmod 600 "$NEXUS_IP_ACME_STATE_ROOT/.rr-ip-acme.ABC123"
! nexus_ip_acme_runtime_is_ready 8.8.8.8 || fail 'runtime accepted recovery temp'
[ -f "$NEXUS_IP_ACME_STATE_ROOT/.rr-ip-acme.ABC123" ] || \
    fail 'read-only runtime proof cleaned recovery temp'
nexus_ip_acme_cleanup_atomic_files "$NEXUS_IP_ACME_STATE_ROOT" atomic

# A restore marker is accepted only with a real active-stage validator and an
# authenticated owner/delegation lock context; trusted restore writes/validates
# HTTP without starting the intentionally stopped Nginx.
restore_stage="$TMP/restore-stage"
mkdir -m 700 "$restore_stage"
printf 'applied\n' > "$restore_stage/phase"
chmod 600 "$restore_stage/phase"
printf '%s\n' "$restore_stage" > "$RR_RESTORE_ACTIVE"
chmod 600 "$RR_RESTORE_ACTIVE"
status=0
nexus_ip_acme_rearm 8.8.8.8 || status=$?
eq "$status" 75
(
    rr_inherited_update_lock_fds_present() { :; }
    rr_restore_active_stage() { printf '%s\n' "$restore_stage"; }
    rr_restore_read_exact_marker() { cat -- "$1"; }
    nexus_ip_acme_install_units() { :; }
    NGINX_ACTIVE=0
    restore_log_start=$(wc -l < "$SYSTEMCTL_LOG")
    RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
        RR_UPDATE_LOCK_OWNER=1 RR_UPDATE_LOCK_FDS_CLOSED=0 \
        nexus_ip_acme_rearm 8.8.8.8 || fail 'trusted restore rearm rejected'
    if tail -n "+$((restore_log_start + 1))" "$SYSTEMCTL_LOG" | \
        grep -Fq 'start nginx'; then
        fail 'trusted restore rearm started Nginx before READY'
    fi
)
unlink "$RR_RESTORE_ACTIVE"
rm -rf -- "$restore_stage"

nexus_ip_acme_disarm_locked || fail 'exact disarm failed'
nexus_ip_acme_timer_is_disarmed_exact || fail 'timer disable postcondition not exact'
(
    eval "$(declare -f systemctl | sed '1s/systemctl/original_systemctl/')"
    IP_TIMER_ENABLED=1
    systemctl() {
        if [ "${1:-}:${2:-}:${3:-}" = disable:--now:rr-nexus-ip-acme.timer ]; then
            IP_TIMER_ACTIVE=0
            return 0
        fi
        original_systemctl "$@"
    }
    status=0
    nexus_ip_acme_disarm_locked || status=$?
    eq "$status" 2
)
nexus_ip_acme_remove_owned_units || fail 'owned unit removal failed'
nexus_ip_acme_units_are_absent_exact || fail 'removed units not systemd not-found/disabled'
calls=$(wc -l < "$MOCK_CALLS")
(
    nexus_ip_acme_install_units() { :; }
    nexus_ip_acme_rearm_locked 8.8.8.8
) || fail 'no-CA rearm rejected settled state'
eq "$(wc -l < "$MOCK_CALLS")" "$calls"

printf 'foreign\n' > "$NEXUS_IP_ACME_STATE_ROOT/foreign"
! nexus_ip_acme_state_tree_is_owned || fail 'foreign state accepted as owned'
[ -f "$NEXUS_IP_ACME_STATE_ROOT/foreign" ] || fail 'foreign state deleted'
unlink "$NEXUS_IP_ACME_STATE_ROOT/foreign"

# Uninstall consumes only precisely validated crash orphans, proves systemd
# not-found/disabled, and removes every managed root/stage/half-install path.
state_stage="${NEXUS_IP_ACME_STATE_ROOT}.new"
mkdir -m 700 "$state_stage"
printf '%s\n' "$NEXUS_IP_ACME_OWNER_VALUE" > \
    "$state_stage/.rr-nexus-ip-acme-owner"
chmod 600 "$state_stage/.rr-nexus-ip-acme-owner"
webroot_stage="${NEXUS_IP_ACME_WEBROOT}.new"
mkdir -m 755 "$webroot_stage"
mkdir -m 755 "$webroot_stage/.well-known"
mkdir -m 755 "$webroot_stage/.well-known/acme-challenge"
printf '%s\n' "$NEXUS_IP_ACME_WEBROOT_VALUE" > \
    "$webroot_stage/.rr-nexus-ip-acme-owner"
chmod 600 "$webroot_stage/.rr-nexus-ip-acme-owner"
cp -a "$NEXUS_IP_ACME_ACTIVE_STORE" \
    "$NEXUS_IP_ACME_STATE_ROOT/candidate.new.5151"
printf 'state-temp\n' > "$NEXUS_IP_ACME_STATE_ROOT/.rr-ip-acme.ABC121"
printf 'key-temp\n' > "$TMP/live/.ip-acme.key.ABC122"
printf 'pending-temp\n' > "$TMP/live/.ip-cert-pending.ABC123"
printf 'http-temp\n' > "$TMP/nginx/available/.rr-ip-acme-http.ABC124"
printf 'unit-temp\n' > "$TMP/systemd/.rr-ip-acme-unit.ABC125"
printf 'lego-temp\n' > "$TMP/.rr-ip-acme.ABC126"
chmod 600 "$NEXUS_IP_ACME_STATE_ROOT/.rr-ip-acme.ABC121" \
    "$TMP/live/.ip-acme.key.ABC122" "$TMP/live/.ip-cert-pending.ABC123" \
    "$TMP/.rr-ip-acme.ABC126"
chmod 644 "$TMP/nginx/available/.rr-ip-acme-http.ABC124" \
    "$TMP/systemd/.rr-ip-acme-unit.ABC125"
nexus_ip_acme_uninstall_locked || fail 'full owned uninstall with crash orphans failed'
for removed in "$NEXUS_IP_ACME_STATE_ROOT" "$state_stage" \
    "$NEXUS_IP_ACME_WEBROOT" "$webroot_stage" "$NEXUS_IP_ACME_LEGO_BIN" \
    "$NEXUS_IP_ACME_LEGO_MARKER" "$NEXUS_IP_ACME_NGINX_AVAILABLE" \
    "$NEXUS_IP_ACME_NGINX_ENABLED" "$NEXUS_IP_ACME_SERVICE_FILE" \
    "$NEXUS_IP_ACME_TIMER_FILE"; do
    [ ! -e "$removed" ] && [ ! -L "$removed" ] || \
        fail "uninstall left managed path $removed"
done
nexus_ip_acme_units_are_absent_exact || fail 'uninstall left stale systemd enablement'

printf 'PASS: Nexus trusted public-IP ACME transaction tests\n'
