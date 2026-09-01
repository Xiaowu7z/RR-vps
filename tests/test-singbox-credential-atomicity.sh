#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source modules/30-singbox.sh
# shellcheck disable=SC1091
source modules/20-config.sh

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
RED=""
GREEN=""
YELLOW=""
RESET=""

make_pair() {
    local directory="$1" common_name="$2"
    install -d -m 700 "$directory"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj "/CN=$common_name" -keyout "$directory/key.pem" \
        -out "$directory/cert.pem" >/dev/null 2>&1
    chmod 600 "$directory/key.pem" "$directory/cert.pem"
}

printf '%s\n' '[1/7] pair marker blocks restart across caught and SIGKILL windows'
pair_root="$test_root/pairs"
target="$pair_root/target"
old_pair="$pair_root/old"
new_pair="$pair_root/new"
install -d -m 700 "$target"
make_pair "$old_pair" old.example.invalid
make_pair "$new_pair" new.example.invalid
cp "$old_pair/cert.pem" "$target/cert.pem"
cp "$old_pair/key.pem" "$target/key.pem"
chmod 600 "$target/cert.pem" "$target/key.pem"
marker="$target/.pair-pending"
missing_naive="$pair_root/missing-naive"

cp "$new_pair/cert.pem" "$pair_root/candidate-cert"
cp "$new_pair/key.pem" "$pair_root/candidate-key"
if RR_TEST_FAULTS=1 RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST=1 \
    rr_publish_certificate_pair "$pair_root/candidate-cert" \
        "$pair_root/candidate-key" "$target/cert.pem" "$target/key.pem" \
        "$marker" rr_certificate_private_key_pair_matches; then
    echo 'Caught first-publish fault was accepted.' >&2
    exit 1
fi
[ -f "$marker" ] && [ ! -L "$marker" ]
set +e
rr_singbox_certificate_start_gate_for_paths \
    "$target/cert.pem" "$target/key.pem" "$marker" \
    "$missing_naive/cert.pem" "$missing_naive/key.pem" "$missing_naive/.pair-pending"
gate_status=$?
set -e
[ "$gate_status" -eq 78 ] || {
    echo 'Pending mismatched pair did not return the restart-prevent status.' >&2
    exit 1
}

cp "$new_pair/cert.pem" "$pair_root/candidate-cert"
cp "$new_pair/key.pem" "$pair_root/candidate-key"
rr_publish_certificate_pair "$pair_root/candidate-cert" \
    "$pair_root/candidate-key" "$target/cert.pem" "$target/key.pem" \
    "$marker" rr_certificate_private_key_pair_matches
rr_singbox_certificate_start_gate_for_paths \
    "$target/cert.pem" "$target/key.pem" "$marker" \
    "$missing_naive/cert.pem" "$missing_naive/key.pem" "$missing_naive/.pair-pending"

make_pair "$pair_root/crash" crash.example.invalid
cp "$pair_root/crash/cert.pem" "$pair_root/candidate-cert"
cp "$pair_root/crash/key.pem" "$pair_root/candidate-key"
RR_TEST_FAULTS=1 RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST=1 \
bash -c '
    source modules/30-singbox.sh
    rr_publish_certificate_pair "$1" "$2" "$3" "$4" "$5" \
        rr_certificate_private_key_pair_matches
' _ "$pair_root/candidate-cert" "$pair_root/candidate-key" \
    "$target/cert.pem" "$target/key.pem" "$marker" &
crash_pid=$!
if wait "$crash_pid"; then
    echo 'Pair publisher unexpectedly survived SIGKILL injection.' >&2
    exit 1
else
    crash_status=$?
    [ "$crash_status" -eq 137 ] || exit 1
fi
[ -f "$marker" ] && [ ! -L "$marker" ]
set +e
rr_singbox_certificate_start_gate_for_paths \
    "$target/cert.pem" "$target/key.pem" "$marker" \
    "$missing_naive/cert.pem" "$missing_naive/key.pem" "$missing_naive/.pair-pending"
gate_status=$?
set -e
[ "$gate_status" -eq 78 ]
rm -f "$marker"
ln -s "$target/missing-marker-target" "$marker"
set +e
rr_singbox_certificate_start_gate_for_paths \
    "$target/cert.pem" "$target/key.pem" "$marker" \
    "$missing_naive/cert.pem" "$missing_naive/key.pem" "$missing_naive/.pair-pending"
gate_status=$?
set -e
[ "$gate_status" -eq 78 ] || { echo 'Dangling pending marker was accepted.' >&2; exit 1; }

printf '%s\n' '[2/7] managed unit is atomically rewritten and effectively re-proved'
(
    RR_SINGBOX_SERVICE_FILE="$test_root/systemd/sing-box.service"
    RR_RESTORE_SYSTEMD_DIR="$test_root/systemd"
    install -d -m 755 "$(dirname "$RR_SINGBOX_SERVICE_FILE")"
    rr_render_singbox_systemd_unit_legacy_710 > "$RR_SINGBOX_SERVICE_FILE"
    manager_reloaded=false
    omit_gate=false
    ignore_gate=false
    override_exec=false
    unknown_dropin=false
    managed_dropins=false
    omit_firewall_condition=false
    singbox_system_call_filter='~'
    systemctl() {
        case "$*" in
            daemon-reload) manager_reloaded=true ;;
            'show --property=LoadState --value sing-box.service')
                printf '%s\n' loaded ;;
            'show --property=FragmentPath --value sing-box.service')
                printf '%s\n' "$RR_SINGBOX_SERVICE_FILE" ;;
            'show --property=ExecStartPre --value sing-box.service')
                if [ "$manager_reloaded" = true ]; then
                    [ "$omit_gate" = true ] || \
                        printf '{ path=/usr/local/bin/rr ; argv[]=/usr/local/bin/rr --singbox-certificate-gate ; ignore_errors=%s } ' \
                            "$([ "$ignore_gate" = true ] && printf yes || printf no)"
                fi
                printf '{ path=/usr/local/bin/sing-box ; argv[]=/usr/local/bin/sing-box check -c /etc/sing-box/config.json ; ignore_errors=no }\n'
                ;;
            'show --property=ExecStart --value sing-box.service')
                if [ "$override_exec" = true ]; then
                    printf '%s\n' '{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }'
                else
                    printf '%s\n' '{ path=/usr/local/bin/sing-box ; argv[]=/usr/local/bin/sing-box run -c /etc/sing-box/config.json ; ignore_errors=no }'
                fi
                ;;
            'show --property=ExecReload --value sing-box.service')
                printf '%s\n' '{ path=/bin/kill ; argv[]=/bin/kill -HUP $MAINPID ; ignore_errors=no }' ;;
            'show --property=User --value sing-box.service') printf '%s\n' root ;;
            'show --property=Group --value sing-box.service') printf '%s\n' root ;;
            'show --property=WorkingDirectory --value sing-box.service') printf '%s\n' /etc/sing-box ;;
            'show --property=DynamicUser --value sing-box.service') printf '%s\n' no ;;
            'show --property=PrivateUsers --value sing-box.service'|\
            'show --property=PrivateMounts --value sing-box.service') printf '%s\n' no ;;
            'show --property=PrivateNetwork --value sing-box.service') printf '%s\n' no ;;
            'show --property=RootDirectory --value sing-box.service'|\
            'show --property=RootImage --value sing-box.service'|\
            'show --property=Environment --value sing-box.service'|\
            'show --property=EnvironmentFiles --value sing-box.service'|\
            'show --property=PAMName --value sing-box.service'|\
            'show --property=Conditions --value sing-box.service'|\
            'show --property=Asserts --value sing-box.service') printf '\n' ;;
            'show --property=SystemCallFilter --value sing-box.service')
                printf '%s\n' "$singbox_system_call_filter" ;;
            'show --property=ExecCondition --value sing-box.service')
                if [ "$managed_dropins" = true ]; then
                    printf '%s' '{ path=/bin/sh ; argv[]=/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate ; ignore_errors=no }'
                    printf '%s' ' { path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/rr-vps/firewall-quarantine ; ignore_errors=no }'
                    [ "$omit_firewall_condition" = true ] || \
                        printf '%s' ' { path=/usr/bin/test ; argv[]=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine ; ignore_errors=no }'
                    printf '\n'
                else
                    printf '\n'
                fi
                ;;
            'show --property=DropInPaths --value sing-box.service')
                if [ "$unknown_dropin" = true ]; then
                    printf '%s\n' /etc/systemd/system/sing-box.service.d/10-override.conf
                elif [ "$managed_dropins" = true ]; then
                    printf '%s %s\n' \
                        "$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d/zzzz-rr-restore-gate.conf" \
                        "$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf"
                else
                    printf '\n'
                fi
                ;;
            'show --property=StartLimitIntervalUSec --value sing-box.service') printf '%s\n' 1min ;;
            'show --property=StartLimitBurst --value sing-box.service') printf '%s\n' 5 ;;
            'show --property=Restart --value sing-box.service') printf '%s\n' on-failure ;;
            'show --property=RestartPreventExitStatus --value sing-box.service')
                [ "$manager_reloaded" = true ] && printf '%s\n' 78 || printf '\n'
                ;;
            'show --property=ExecStartPost --value sing-box.service'|\
            'show --property=ExecStop --value sing-box.service'|\
            'show --property=ExecStopPost --value sing-box.service') printf '\n' ;;
            *) return 1 ;;
        esac
    }
    rr_singbox_legacy_service_is_owned || {
        echo 'Exact legacy unit failed its effective-identity proof.' >&2
        exit 1
    }
    singbox_system_call_filter='~@privileged'
    if rr_singbox_legacy_service_is_owned; then
        echo 'Legacy unit proof accepted a non-default system-call filter.' >&2
        exit 1
    fi
    singbox_system_call_filter='~'
    ensure_singbox_service_guards
    grep -Fxq 'ExecStartPre=/usr/local/bin/rr --singbox-certificate-gate' \
        "$RR_SINGBOX_SERVICE_FILE"
    grep -Fxq 'RestartPreventExitStatus=78' "$RR_SINGBOX_SERVICE_FILE"
    singbox_system_call_filter='~@privileged'
    if rr_singbox_service_guards_are_effective; then
        echo 'Current unit proof accepted a non-default system-call filter.' >&2
        exit 1
    fi
    singbox_system_call_filter='~'
    omit_gate=true
    if rr_singbox_service_guards_are_effective; then
        echo 'Effective unit proof accepted a missing certificate gate.' >&2
        exit 1
    fi
    omit_gate=false
    ignore_gate=true
    if rr_singbox_service_guards_are_effective; then
        echo 'Effective unit proof accepted an ignored certificate gate failure.' >&2
        exit 1
    fi
    ignore_gate=false
    override_exec=true
    if rr_singbox_service_guards_are_effective; then
        echo 'Effective unit proof accepted an overridden Sing-box ExecStart.' >&2
        exit 1
    fi
    override_exec=false
    unknown_dropin=true
    if rr_singbox_service_guards_are_effective; then
        echo 'Effective unit proof accepted an unknown service drop-in.' >&2
        exit 1
    fi
    unknown_dropin=false
    managed_dropins=true
    install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d"
    printf '%s\n' '[Service]' \
        "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" > \
        "$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d/zzzz-rr-restore-gate.conf"
    printf '%s\n' '[Service]' \
        'ExecCondition=/usr/bin/test ! -e /var/lib/rr-vps/firewall-quarantine' \
        'ExecCondition=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine' > \
        "$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf"
    chmod 644 "$RR_RESTORE_SYSTEMD_DIR"/sing-box.service.d/*.conf
    rr_singbox_service_guards_are_effective || {
        echo 'Exact restore/firewall/certificate gates did not coexist.' >&2
        exit 1
    }
    omit_firewall_condition=true
    if rr_singbox_service_guards_are_effective; then
        echo 'Combined gate proof accepted a missing firewall condition.' >&2
        exit 1
    fi
)
(
    RR_SINGBOX_SERVICE_FILE="$test_root/systemd-mv-fault/sing-box.service"
    install -d -m 755 "$(dirname "$RR_SINGBOX_SERVICE_FILE")"
    printf '%s\n' original-unit > "$RR_SINGBOX_SERVICE_FILE"
    before=$(sha256sum "$RR_SINGBOX_SERVICE_FILE")
    mv() { return 1; }
    if write_singbox_systemd_unit; then
        echo 'Unit writer accepted an atomic rename failure.' >&2
        exit 1
    fi
    [ "$(sha256sum "$RR_SINGBOX_SERVICE_FILE")" = "$before" ]
)

printf '%s\n' '[3/7] Reality private/public/short-id publish as one atomic config'
reality_root="$test_root/reality"
install -d -m 700 "$reality_root"
CONFIG_FILE="$reality_root/argo_vmess.conf"
private=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
public=$(rr_reality_public_from_private "$private")
other_private=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
other_public=$(rr_reality_public_from_private "$other_private")
short_id=1a2b3c4d
printf '%s\n' \
    "PRIVATE_KEY=$other_private" "PUBLIC_KEY=$other_public" 'SHORT_ID=deadbeef' \
    > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
SINGBOX_BIN="$reality_root/sing-box"
cat > "$SINGBOX_BIN" <<'EOF'
#!/bin/bash
case "$*" in
    'generate reality-keypair')
        printf 'PrivateKey: %s\nPublicKey: %s\n' "$TEST_REALITY_PRIVATE" "$TEST_REALITY_PUBLIC" ;;
    'generate rand --hex 4') printf '%s\n' "$TEST_REALITY_SHORT" ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$SINGBOX_BIN"
export TEST_REALITY_PRIVATE="$private" TEST_REALITY_PUBLIC="$public" \
    TEST_REALITY_SHORT="$short_id"
# The production function was sourced above.  A later same-name definition is
# an intentional fault-injection stub for the separate credential-repair case.
# shellcheck disable=SC2218
rotate_reality_keypair
[ "$(grep -c '^PRIVATE_KEY=' "$CONFIG_FILE")" -eq 1 ]
[ "$(grep -c '^PUBLIC_KEY=' "$CONFIG_FILE")" -eq 1 ]
[ "$(grep -c '^SHORT_ID=' "$CONFIG_FILE")" -eq 1 ]
grep -Fxq "PRIVATE_KEY=$private" "$CONFIG_FILE"
grep -Fxq "PUBLIC_KEY=$public" "$CONFIG_FILE"
grep -Fxq "SHORT_ID=$short_id" "$CONFIG_FILE"
[ "$(rr_reality_public_from_private "$private")" = "$public" ]

before=$(sha256sum "$CONFIG_FILE")
TEST_REALITY_PRIVATE="$other_private"
TEST_REALITY_PUBLIC="$other_public"
TEST_REALITY_SHORT=abcdef12
if RR_TEST_FAULTS=1 RR_TEST_REALITY_FAIL_BEFORE_COMMIT=1 rotate_reality_keypair; then
    echo 'Reality pre-commit failure was accepted.' >&2
    exit 1
fi
[ "$(sha256sum "$CONFIG_FILE")" = "$before" ]

RR_TEST_FAULTS=1 RR_TEST_REALITY_CRASH_BEFORE_COMMIT=1 \
CONFIG_FILE="$CONFIG_FILE" SINGBOX_BIN="$SINGBOX_BIN" \
TEST_REALITY_PRIVATE="$other_private" TEST_REALITY_PUBLIC="$other_public" \
TEST_REALITY_SHORT=abcdef12 bash -c '
    source modules/30-singbox.sh
    rotate_reality_keypair
' &
reality_crash_pid=$!
if wait "$reality_crash_pid"; then
    echo 'Reality publisher unexpectedly survived SIGKILL injection.' >&2
    exit 1
else
    reality_crash_status=$?
    [ "$reality_crash_status" -eq 137 ] || exit 1
fi
[ "$(sha256sum "$CONFIG_FILE")" = "$before" ]
# shellcheck disable=SC2218
rotate_reality_keypair
grep -Fxq "PRIVATE_KEY=$other_private" "$CONFIG_FILE"
grep -Fxq "PUBLIC_KEY=$other_public" "$CONFIG_FILE"
grep -Fxq 'SHORT_ID=abcdef12' "$CONFIG_FILE"

printf '%s\n' '[4/7] subscription/health validation rejects derived-key mismatch'
VL_ENABLED=true
PRIVATE_KEY="$private"
PUBLIC_KEY="$other_public"
SHORT_ID=01234567
if validate_subscription_crypto_material; then
    echo 'Reality public key unrelated to the configured private key was accepted.' >&2
    exit 1
fi

printf '%s\n' '[5/7] credential repair commits one durable generation and propagates writer faults'
credential_root="$test_root/credentials"
install -d -m 700 "$credential_root"
CONFIG_FILE="$credential_root/argo_vmess.conf"
credential_safe_sed_calls=0
credential_safe_sed_fail_at=0
safe_sed() {
    local key="$1" value="$2" encoded=""
    credential_safe_sed_calls=$((credential_safe_sed_calls + 1))
    if [ "$credential_safe_sed_fail_at" -gt 0 ] && \
       [ "$credential_safe_sed_calls" -eq "$credential_safe_sed_fail_at" ]; then
        return 1
    fi
    printf -v encoded '%q' "$value"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${encoded}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$encoded" >> "$CONFIG_FILE"
    fi
}
load_config_with_defaults() {
    read_config_whitelist
}
write_invalid_credentials() {
    printf '%s\n' \
        'UUID=masked...0000' \
        'SUB_TOKEN=short' \
        'NAIVE_ENABLED=true' \
        'NAIVE_USER=abcdef...1234' \
        'NAIVE_PASS=abcdef...5678' \
        'PRIVATE_KEY=' \
        'PUBLIC_KEY=' \
        'SHORT_ID=' \
        'CERT_SHA256=abcdef...1234' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    UUID='masked...0000'
    SUB_TOKEN=short
    NAIVE_ENABLED=true
    NAIVE_USER='abcdef...1234'
    NAIVE_PASS='abcdef...5678'
    PRIVATE_KEY=''
    PUBLIC_KEY=''
    SHORT_ID=''
    CERT_SHA256='abcdef...1234'
}
write_invalid_credentials
credential_before=$(sha256sum "$CONFIG_FILE")
credential_safe_sed_calls=0
credential_safe_sed_fail_at=2
if ensure_credential_integrity; then
    echo 'Credential repair accepted a safe_sed failure.' >&2
    exit 1
fi
[ "$(sha256sum "$CONFIG_FILE")" = "$credential_before" ]
[ "$UUID" = 'masked...0000' ]
[ "$SUB_TOKEN" = short ]

credential_safe_sed_calls=0
credential_safe_sed_fail_at=0
ensure_credential_integrity
is_valid_uuid "$UUID"
[[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{32}$ ]]
[[ "$NAIVE_USER" =~ ^np_[0-9a-f]{8}$ ]]
[[ "$NAIVE_PASS" =~ ^[A-Za-z0-9]{20}$ ]]
[ -z "$CERT_SHA256" ]
rr_credential_config_values_match "$CONFIG_FILE" \
    UUID "$UUID" SUB_TOKEN "$SUB_TOKEN" NAIVE_USER "$NAIVE_USER" \
    NAIVE_PASS "$NAIVE_PASS" CERT_SHA256 "$CERT_SHA256"

# A failure reported after rename must still reload the committed generation
# into memory before propagating the failure.
write_invalid_credentials
credential_safe_sed_calls=0
sync_calls=0
sync() {
    sync_calls=$((sync_calls + 1))
    [ "$sync_calls" -ne 2 ] || return 1
    command sync "$@"
}
if ensure_credential_integrity; then
    echo 'Credential repair accepted a directory-fsync failure.' >&2
    exit 1
fi
unset -f sync
is_valid_uuid "$UUID"
[[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{32}$ ]]
rr_credential_config_values_match "$CONFIG_FILE" UUID "$UUID" SUB_TOKEN "$SUB_TOKEN"

# Reality fallback clearing is subject to the same all-or-nothing writer.
printf '%s\n' \
    'UUID=11111111-1111-4111-8111-111111111111' \
    'SUB_TOKEN=abcdefghijklmnopqrstuvwxyzABCDEF' \
    'NAIVE_ENABLED=false' \
    'NAIVE_USER=' \
    'NAIVE_PASS=' \
    'PRIVATE_KEY=abcdef...1234' \
    'PUBLIC_KEY=abcdef...5678' \
    'SHORT_ID=abcdef...9abc' \
    'CERT_SHA256=' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
UUID=11111111-1111-4111-8111-111111111111
SUB_TOKEN=abcdefghijklmnopqrstuvwxyzABCDEF
NAIVE_ENABLED=false
NAIVE_USER=''
NAIVE_PASS=''
PRIVATE_KEY='abcdef...1234'
PUBLIC_KEY='abcdef...5678'
SHORT_ID='abcdef...9abc'
CERT_SHA256=''
rotate_reality_keypair() { return 1; }
credential_before=$(sha256sum "$CONFIG_FILE")
credential_safe_sed_calls=0
credential_safe_sed_fail_at=2
if ensure_credential_integrity >/dev/null 2>&1; then
    echo 'Reality fallback accepted a partial clear.' >&2
    exit 1
fi
[ "$(sha256sum "$CONFIG_FILE")" = "$credential_before" ]
credential_safe_sed_calls=0
credential_safe_sed_fail_at=0
ensure_credential_integrity >/dev/null 2>&1
[ -z "$PRIVATE_KEY" ] && [ -z "$PUBLIC_KEY" ] && [ -z "$SHORT_ID" ]
rr_credential_config_values_match "$CONFIG_FILE" \
    PRIVATE_KEY '' PUBLIC_KEY '' SHORT_ID ''

printf '%s\n' '[6/7] transaction rollback publishes a complete, durable file generation'
restore_contract=$(declare -f restore_config_transaction_snapshot)
[ "$(grep -c 'rr_restore_transaction_file_atomic' <<<"$restore_contract")" -eq 3 ] || {
    echo 'Transaction snapshot restore does not route all present files through the atomic publisher.' >&2
    exit 1
}
apply_contract=$(declare -f apply_config_transaction)
[ "$(grep -c 'rr_restore_transaction_file_atomic' <<<"$apply_contract")" -eq 1 ] || {
    echo 'safe_sed failure rollback does not route through the atomic publisher.' >&2
    exit 1
}
restore_root="$test_root/config-restore"
install -d -o 0 -g 0 -m 700 "$restore_root"
restore_snapshot="$restore_root/snapshot"
restore_target="$restore_root/argo_vmess.conf"
restore_old="$restore_root/old"
printf '%s\n' 'CONFIG_GENERATION=old' 'OLD_ONLY=true' > "$restore_old"
printf '%s\n' 'CONFIG_GENERATION=restored' 'RESTORED_ONLY=true' > "$restore_snapshot"
chown 0:0 "$restore_old" "$restore_snapshot"
chmod 600 "$restore_old"
chmod 640 "$restore_snapshot"

for restore_fault in copy file-fsync rename; do
    cp -p -- "$restore_old" "$restore_target"
    if RR_TEST_FAULTS=1 RR_TEST_CONFIG_RESTORE_FAULT="$restore_fault" \
        rr_restore_transaction_file_atomic "$restore_snapshot" "$restore_target"; then
        echo "Config restore accepted ${restore_fault} failure." >&2
        exit 1
    fi
    cmp -s -- "$restore_old" "$restore_target" || {
        echo "Config restore left a partial target after ${restore_fault} failure." >&2
        exit 1
    }
    [ "$(stat -c '%u:%g:%a:%h' -- "$restore_target")" = 0:0:600:1 ]
    if compgen -G "$restore_root/.argo_vmess.conf.rr-restore.*" >/dev/null; then
        echo "Config restore leaked a temporary file after ${restore_fault} failure." >&2
        exit 1
    fi
done

cp -p -- "$restore_old" "$restore_target"
if RR_TEST_FAULTS=1 RR_TEST_CONFIG_RESTORE_FAULT=dir-fsync \
    rr_restore_transaction_file_atomic "$restore_snapshot" "$restore_target"; then
    echo 'Config restore accepted a parent-directory fsync failure.' >&2
    exit 1
fi
cmp -s -- "$restore_snapshot" "$restore_target" || {
    echo 'Post-rename fsync failure did not leave one complete restored generation.' >&2
    exit 1
}
[ "$(stat -c '%u:%g:%a:%h' -- "$restore_target")" = 0:0:640:1 ]

cp -p -- "$restore_old" "$restore_target"
rr_restore_transaction_file_atomic "$restore_snapshot" "$restore_target"
cmp -s -- "$restore_snapshot" "$restore_target"
[ "$(stat -c '%u:%g:%a:%h' -- "$restore_target")" = 0:0:640:1 ]

printf '%s\n' '[7/7] restart requires command success and a new systemd generation'
# The interactive restart rollback is another writer of the same live JSON.
# Keep it on the atomic publisher and require a config proof before restart.
menu_contract=$(sed -n '/^sb_control_menu() {/,/^}/p' \
    "$REPO_ROOT/modules/99-menus.sh")
grep -Fq 'rr_restore_transaction_file_atomic \' <<<"$menu_contract" || {
    echo 'Menu restart rollback bypasses the durable atomic publisher.' >&2
    exit 1
}
grep -Fq '"$SINGBOX_BIN" check -c \' <<<"$menu_contract" || {
    echo 'Menu restart rollback does not validate the restored generation.' >&2
    exit 1
}
if grep -Eq 'cp([[:space:]]+-[^[:space:]]*[[:space:]]+|[[:space:]]+)-p[[:space:]]+/etc/sing-box/config\.json\.bak' \
        <<<"$menu_contract"; then
    echo 'Menu restart rollback still copies directly over the live config.' >&2
    exit 1
fi

restart_root="$test_root/restart"
RR_SINGBOX_SERVICE_FILE="$restart_root/sing-box.service"
install -d -m 700 "$restart_root"
printf '%s\n' '[Unit]' > "$RR_SINGBOX_SERVICE_FILE"
SINGBOX_BIN="$restart_root/sing-box"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$SINGBOX_BIN"
chmod 755 "$SINGBOX_BIN"
ensure_singbox_service_guards() { return 0; }
rr_singbox_service_guards_are_effective() { return 0; }
rr_firewall_fail_closed_quarantine_active() { return 1; }
managed_singbox_pids() { return 0; }
stop_singbox_instances() { return 0; }
sleep() { :; }
service_active=true
service_pid=4101
service_invocation=11111111111111111111111111111111
restart_result=0
start_result=0
advance_generation=true
systemctl() {
    case "$*" in
        'is-active --quiet sing-box'|'is-active --quiet sing-box.service')
            [ "$service_active" = true ] ;;
        'show --property=MainPID --value sing-box.service')
            printf '%s\n' "$service_pid" ;;
        'show --property=InvocationID --value sing-box.service')
            printf '%s\n' "$service_invocation" ;;
        'reset-failed sing-box') return 0 ;;
        'restart sing-box')
            [ "$restart_result" -eq 0 ] || return "$restart_result"
            if [ "$advance_generation" = true ]; then
                service_pid=$((service_pid + 1))
                service_invocation=22222222222222222222222222222222
            fi
            service_active=true
            ;;
        'start sing-box')
            [ "$start_result" -eq 0 ] || return "$start_result"
            if [ "$advance_generation" = true ]; then
                service_pid=5101
                service_invocation=33333333333333333333333333333333
            fi
            service_active=true
            ;;
        *) return 1 ;;
    esac
}

restart_result=1
if restart_singbox; then
    echo 'restart_singbox accepted a failed systemctl restart with old active state.' >&2
    exit 1
fi
restart_result=0
advance_generation=false
if restart_singbox; then
    echo 'restart_singbox accepted an unchanged InvocationID/MainPID.' >&2
    exit 1
fi
advance_generation=true
restart_singbox

service_pid=6101
service_invocation=44444444444444444444444444444444
restart_result=1
if restart_singbox_systemd_only; then
    echo 'Core-only restart accepted a failed systemctl restart.' >&2
    exit 1
fi
restart_result=0
advance_generation=false
if restart_singbox_systemd_only; then
    echo 'Core-only restart accepted an unchanged systemd generation.' >&2
    exit 1
fi
advance_generation=true
restart_singbox_systemd_only

service_active=false
service_pid=0
service_invocation=''
start_result=1
if restart_singbox; then
    echo 'restart_singbox accepted a failed systemctl start.' >&2
    exit 1
fi

printf '%s\n' 'Sing-box credential atomicity regressions passed'
