#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-uninstall-cert-hook.XXXXXX)
PRODUCTION_BEFORE="$TEST_ROOT/production.before"
PRODUCTION_AFTER="$TEST_ROOT/production.after"
PRODUCTION_PATHS=(
    /etc/letsencrypt/renewal-hooks/deploy
    /etc/letsencrypt/renewal-hooks/deploy/rr-certificates.sh
    /etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh
)

snapshot_production() {
    local output="$1" path="" metadata="" digest=""
    : > "$output"
    for path in "${PRODUCTION_PATHS[@]}"; do
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

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if ! snapshot_production "$PRODUCTION_AFTER" || \
       ! cmp -s -- "$PRODUCTION_BEFORE" "$PRODUCTION_AFTER"; then
        printf 'Uninstall certificate hook test changed a production path.\n' >&2
        status=1
    fi
    rm -rf -- "$TEST_ROOT"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'uninstall certificate hook regression: FAIL: %s\n' "$*" >&2
    exit 1
}

RR_RUNTIME_DIR="$TEST_ROOT/runtime"
RR_LE_RENEW_HOOK_DIR="$TEST_ROOT/letsencrypt/renewal-hooks/deploy"
export RR_RUNTIME_DIR RR_LE_RENEW_HOOK_DIR
snapshot_production "$PRODUCTION_BEFORE"
install -d -o 0 -g 0 -m 755 "$RR_RUNTIME_DIR/scripts"
install -d -o 0 -g 0 -m 700 "$RR_LE_RENEW_HOOK_DIR"
install -o 0 -g 0 -m 755 "$REPO_ROOT/scripts/naive-cert-hook.sh" \
    "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/modules/95-install.sh"

current_hook="$RR_LE_RENEW_HOOK_DIR/rr-certificates.sh"
legacy_hook="$RR_LE_RENEW_HOOK_DIR/rr-naive-cert.sh"
expected_current_hook_sha256=f908141e58c8f9abce04c6190072ef878dac768bbd8ba8b100f561847ce7c7ff
actual_current_hook_sha256=$(sha256sum -- \
    "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" | awk '{print $1}')
[ "$actual_current_hook_sha256" = "$expected_current_hook_sha256" ] || \
    fail "current hook hash drifted: ${actual_current_hook_sha256}"

clear_fixture_hooks() {
    rm -f -- "$current_hook" "$legacy_hook"
    chmod 700 "$RR_LE_RENEW_HOOK_DIR"
}

printf '%s\n' '[1/7] exact hash-anchored current RR hook is removed and source is retained'
install -o 0 -g 0 -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
    "$current_hook"
rr_uninstall_certificate_hooks_are_owned || fail 'exact current hook was rejected'
rr_uninstall_remove_owned_certificate_hooks || fail 'exact current hook was not removed'
[ ! -e "$current_hook" ] && [ -s "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" ] || \
    fail 'normal cleanup removed the wrong file'

printf '%s\n' '[2/7] third-party same-name hook is retained and cleanup refuses'
cat > "$current_hook" <<'EOF'
#!/bin/bash
printf '%s\n' third-party-hook
EOF
chown 0:0 "$current_hook"
chmod 700 "$current_hook"
third_party_digest=$(sha256sum "$current_hook")
if rr_uninstall_certificate_hooks_are_owned; then
    fail 'third-party same-name hook was claimed as RR-owned'
fi
if rr_uninstall_remove_owned_certificate_hooks; then
    fail 'third-party same-name hook was deleted'
fi
[ "$third_party_digest" = "$(sha256sum "$current_hook")" ] || \
    fail 'third-party same-name hook changed during refusal'

printf '%s\n' '[3/7] tampered RR hook, source, and unsafe metadata are retained'
clear_fixture_hooks
install -o 0 -g 0 -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
    "$current_hook"
printf '%s\n' '# tampered' >> "$current_hook"
tampered_digest=$(sha256sum "$current_hook")
if rr_uninstall_remove_owned_certificate_hooks; then
    fail 'tampered RR hook was removed'
fi
[ "$tampered_digest" = "$(sha256sum "$current_hook")" ] || \
    fail 'tampered RR hook changed during refusal'
install -o 0 -g 0 -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
    "$current_hook"
chmod 755 "$current_hook"
if rr_uninstall_remove_owned_certificate_hooks; then
    fail 'wrong-mode current hook was removed'
fi
[ -f "$current_hook" ] || fail 'wrong-mode hook was not retained'
cat > "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" <<'EOF'
#!/bin/bash
printf '%s\n' synchronized-tampering
EOF
chown 0:0 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
chmod 755 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"
install -o 0 -g 0 -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
    "$current_hook"
synchronized_digest=$(sha256sum "$current_hook")
if rr_uninstall_remove_owned_certificate_hooks; then
    fail 'identically tampered runtime source and hook were claimed as RR-owned'
fi
[ "$synchronized_digest" = "$(sha256sum "$current_hook")" ] || \
    fail 'synchronized-tampering refusal changed the hook'
install -o 0 -g 0 -m 755 "$REPO_ROOT/scripts/naive-cert-hook.sh" \
    "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh"

printf '%s\n' '[4/7] exact 6.6.x inline legacy hook remains uninstall-compatible'
clear_fixture_hooks
chmod 755 "$RR_LE_RENEW_HOOK_DIR"
cat > "$legacy_hook" <<'EOF'
#!/bin/bash
# RR-vps NaiveProxy 证书续签钩子：同步到 /etc/rr-naive 并重启 sing-box
for cert_dir in /etc/letsencrypt/live/*/; do
    domain=$(basename "$cert_dir")
    [ -f "$cert_dir/fullchain.pem" ] || continue
    cp -f "$cert_dir/fullchain.pem" /etc/rr-naive/fullchain.pem 2>/dev/null
    cp -f "$cert_dir/privkey.pem" /etc/rr-naive/privkey.pem 2>/dev/null
done
chmod 600 /etc/rr-naive/*.pem 2>/dev/null
systemctl restart sing-box >/dev/null 2>&1 || true
EOF
chown 0:0 "$legacy_hook"
chmod 700 "$legacy_hook"
[ "$(sha256sum "$legacy_hook" | awk '{print $1}')" = \
    360b767dae048b960794ab69a979ee9794619ee51166d7865e32febf75ff6fe4 ] || \
    fail 'legacy fixture hash drifted'
rr_uninstall_remove_owned_certificate_hooks || fail 'exact inline legacy hook was rejected'
[ ! -e "$legacy_hook" ] || fail 'exact inline legacy hook was retained'

printf '%s\n' '[5/7] current runtime content under legacy filename is removed'
chmod 700 "$RR_LE_RENEW_HOOK_DIR"
install -o 0 -g 0 -m 700 "$RR_RUNTIME_DIR/scripts/naive-cert-hook.sh" \
    "$legacy_hook"
rr_uninstall_remove_owned_certificate_hooks || \
    fail 'current RR content under legacy filename was rejected'
[ ! -e "$legacy_hook" ] || fail 'current legacy-named RR hook was retained'

printf '%s\n' '[6/7] uninstall preflights ownership before destructive isolation'
uninstall_body=$(sed -n '/^uninstall_all_locked() {/,/^}/p' \
    "$REPO_ROOT/modules/95-install.sh")
runtime_preflight_line=$(grep -n 'rr_uninstall_capture_runtime_ownership' \
    <<< "$uninstall_body" | head -n 1 | cut -d: -f1)
preflight_line=$(grep -n 'rr_uninstall_certificate_hooks_are_owned' \
    <<< "$uninstall_body" | head -n 1 | cut -d: -f1)
isolation_line=$(grep -n 'rr_firewall_stop_nodes_on_indeterminate_commit' \
    <<< "$uninstall_body" | head -n 1 | cut -d: -f1)
cleanup_line=$(grep -n 'rr_uninstall_remove_owned_certificate_hooks' \
    <<< "$uninstall_body" | head -n 1 | cut -d: -f1)
runtime_delete_line=$(grep -n 'rm -rf "$RR_LIB_DIR"' \
    <<< "$uninstall_body" | head -n 1 | cut -d: -f1)
[[ "$runtime_preflight_line" =~ ^[0-9]+$ && \
   "$preflight_line" =~ ^[0-9]+$ && "$isolation_line" =~ ^[0-9]+$ && \
   "$cleanup_line" =~ ^[0-9]+$ && "$runtime_delete_line" =~ ^[0-9]+$ ]] || \
    fail 'uninstall hook integration call sites are incomplete'
[ "$runtime_preflight_line" -lt "$preflight_line" ] && \
    [ "$preflight_line" -lt "$isolation_line" ] && \
    [ "$cleanup_line" -lt "$runtime_delete_line" ] || \
    fail 'uninstall hook proof/removal ordering is unsafe'

printf '%s\n' '[7/7] unowned hook aborts the complete uninstall before mutation'
install -o 0 -g 0 -m 700 /dev/stdin "$current_hook" <<'EOF'
#!/bin/bash
printf '%s\n' third-party-hook
EOF
third_party_digest=$(sha256sum "$current_hook")
CONFIG_FILE="$TEST_ROOT/argo_vmess.conf"
RR_LEGACY_RESTORE_LOCK_FILE="$TEST_ROOT/restore-live.lock"
RED=
RESET=
: > "$CONFIG_FILE"
load_config_with_defaults() { return 0; }
_uninstall_acquire_existing_legacy_lock() { return 0; }
rr_uninstall_capture_runtime_ownership() { return 0; }
_uninstall_quarantine_present() { return 1; }
rr_firewall_stop_nodes_on_indeterminate_commit() {
    : > "$TEST_ROOT/destructive-isolation-called"
    return 0
}
uninstall_status=0
uninstall_output=$(uninstall_all_locked 2>&1) || uninstall_status=$?
[ "$uninstall_status" -eq 2 ] || \
    fail "unowned hook returned $uninstall_status instead of safety refusal 2"
[[ "$uninstall_output" = *'[安全拒绝]'* && \
   "$uninstall_output" = *'完整卸载尚未开始'* ]] || \
    fail 'complete-uninstall refusal diagnostic was not explicit'
[ ! -e "$TEST_ROOT/destructive-isolation-called" ] || \
    fail 'complete uninstall mutated state before refusing the unowned hook'
[ "$third_party_digest" = "$(sha256sum "$current_hook")" ] || \
    fail 'complete-uninstall refusal changed the third-party hook'

echo 'Uninstall certificate hook regressions passed.'
