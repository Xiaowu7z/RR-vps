#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$ROOT_DIR/scripts/naive-cert-hook.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

CONFIG="$TEST_ROOT/argo_vmess.conf"
LIVE_ROOT="$TEST_ROOT/live"
NAIVE_TARGET="$TEST_ROOT/rr-naive"
mkdir -p "$LIVE_ROOT"

make_certificate() {
    local directory="$1" domain="$2" key_source="${3:-}"
    mkdir -p "$directory"
    if [ -n "$key_source" ]; then
        cp "$key_source" "$directory/privkey.pem"
        openssl req -new -key "$directory/privkey.pem" -subj "/CN=$domain" \
            -addext "subjectAltName=DNS:$domain" -out "$directory/request.csr" \
            >/dev/null 2>&1
        openssl x509 -req -days 30 -in "$directory/request.csr" \
            -signkey "$directory/privkey.pem" -copy_extensions copy \
            -out "$directory/fullchain.pem" >/dev/null 2>&1
        rm -f "$directory/request.csr"
    else
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
            -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" \
            -keyout "$directory/privkey.pem" -out "$directory/fullchain.pem" \
            >/dev/null 2>&1
    fi
    chmod 600 "$directory/fullchain.pem" "$directory/privkey.pem"
}

run_hook() {
    local lineage="$1" rr_cli="${2:-/bin/true}" systemctl_bin="${3:-/bin/true}"
    RR_CERT_HOOK_CONFIG_FILE="$CONFIG" \
    RR_CERT_HOOK_NAIVE_TARGET_DIR="$NAIVE_TARGET" \
    RR_CERT_HOOK_LE_LIVE_ROOT="$LIVE_ROOT" \
    RR_CERT_HOOK_CLI="$rr_cli" \
    RR_CERT_HOOK_SYSTEMCTL="$systemctl_bin" \
    RENEWED_LINEAGE="$lineage" \
        bash "$HOOK"
}

printf '[1/7] exact Naive lineage, SAN, key and permissions\n'
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=naive.example.test
SUB_ACCESS_MODE=https
SUB_DOMAIN=sub.example.test
EOF
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
make_certificate "$LIVE_ROOT/sub.example.test" sub.example.test
run_hook "$LIVE_ROOT/naive.example.test" /bin/false /bin/true
cmp -s "$LIVE_ROOT/naive.example.test/fullchain.pem" "$NAIVE_TARGET/fullchain.pem"
cmp -s "$LIVE_ROOT/naive.example.test/privkey.pem" "$NAIVE_TARGET/privkey.pem"
[ "$(stat -c %a "$NAIVE_TARGET")" = 700 ]
[ "$(stat -c %a "$NAIVE_TARGET/fullchain.pem")" = 600 ]
[ "$(stat -c %a "$NAIVE_TARGET/privkey.pem")" = 600 ]

printf '[2/7] subscription lineage refresh is independent\n'
naive_digest=$(sha256sum "$NAIVE_TARGET/fullchain.pem")
run_hook "$LIVE_ROOT/sub.example.test" /bin/true /bin/false
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]
if run_hook "$LIVE_ROOT/sub.example.test" /bin/false /bin/false; then
    echo 'A failed subscription refresh was silently accepted.' >&2
    exit 1
fi

printf '[3/7] unrelated lineage is a no-op\n'
make_certificate "$LIVE_ROOT/unrelated.example.test" unrelated.example.test
run_hook "$LIVE_ROOT/unrelated.example.test" /bin/false /bin/false
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]

printf '[4/7] wrong SAN and mismatched key fail closed\n'
cp "$LIVE_ROOT/naive.example.test/fullchain.pem" "$TEST_ROOT/original-naive.crt"
make_certificate "$TEST_ROOT/wrong-san" attacker.example.test
cp "$TEST_ROOT/wrong-san/fullchain.pem" "$LIVE_ROOT/naive.example.test/fullchain.pem"
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A certificate with the wrong SAN was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]
cp "$TEST_ROOT/original-naive.crt" "$LIVE_ROOT/naive.example.test/fullchain.pem"
cp "$LIVE_ROOT/sub.example.test/privkey.pem" "$LIVE_ROOT/naive.example.test/privkey.pem"
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/true; then
    echo 'A certificate/private-key mismatch was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$NAIVE_TARGET/fullchain.pem")" = "$naive_digest" ]

printf '[5/7] invalid or duplicate config is rejected without sourcing\n'
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

printf '[6/7] daemon reload failure propagates to Certbot\n'
cat > "$CONFIG" <<'EOF'
NAIVE_DOMAIN=naive.example.test
SUB_ACCESS_MODE=local
SUB_DOMAIN=
EOF
# Restore a valid matching pair before exercising only the reload failure.
make_certificate "$LIVE_ROOT/naive.example.test" naive.example.test
if run_hook "$LIVE_ROOT/naive.example.test" /bin/true /bin/false; then
    echo 'A failed sing-box certificate reload was silently accepted.' >&2
    exit 1
fi

printf '[7/7] local subscription mode never refreshes a public service\n'
run_hook "$LIVE_ROOT/sub.example.test" /bin/false /bin/false

echo 'Certificate deploy hook regressions passed.'
