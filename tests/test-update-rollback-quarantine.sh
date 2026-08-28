#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
GUARD_PID=""
cleanup() {
    if [ -n "$GUARD_PID" ]; then
        kill "$GUARD_PID" >/dev/null 2>&1 || true
        wait "$GUARD_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

export RR_TX_ROOT="$TEST_ROOT/update"
export RR_ACTIVE_TX="$RR_TX_ROOT/active"
export RR_LIB_DIR="$TEST_ROOT/runtime"
export RR_LAUNCHER="$TEST_ROOT/rr"
export RR_CONFIG_FILE="$TEST_ROOT/argo_vmess.conf"
export RR_QUARANTINE_FILE="$RR_TX_ROOT/subscription-quarantine"
export RR_QUARANTINE_UNIT="$TEST_ROOT/systemd/rr-subscription-quarantine.service"
export RR_QUARANTINE_READY="$TEST_ROOT/run/quarantine.ready"
export RR_RECOVERY_SELF="$TEST_ROOT/bin/rr-update-recover"
export RR_IPV6_STATE_FILE="$TEST_ROOT/no-ipv6"
export RR_UPDATE_LOCK_FILE="$TEST_ROOT/run/rr-update.lock"
export RR_UPDATE_RECOVER_SOURCE_ONLY=1
# shellcheck source=../scripts/update-recover.sh
source "$REPO_ROOT/scripts/update-recover.sh"

SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
FIREWALL_LOG="$TEST_ROOT/firewall.log"
systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$*" in
        *"enable --now rr-subscription-quarantine.service"*)
            mkdir -p "$(dirname "$RR_QUARANTINE_READY")"
            printf 'ready\n' > "$RR_QUARANTINE_READY"
            ;;
    esac
    return 0
}
rr_stop_subscription_servers() { printf 'stop-subscription\n' >> "$SYSTEMCTL_LOG"; }
rr_quarantine_add_firewall_rules() { printf 'add:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_firewall_rules() { printf 'delete:%s\n' "$1" >> "$FIREWALL_LOG"; }
sleep() { :; }

reset_case() {
    rm -rf "$RR_TX_ROOT/transactions" "$RR_LIB_DIR" "$RR_QUARANTINE_FILE" \
        "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" "$RR_CONFIG_FILE"
    mkdir -p "$RR_TX_ROOT/transactions" "$RR_LIB_DIR/modules" "$(dirname "$RR_QUARANTINE_READY")"
    : > "$SYSTEMCTL_LOG"
    : > "$FIREWALL_LOG"
}

prepare_transaction() {
    local name="$1" version="$2" port="$3"
    CURRENT_TX="$RR_TX_ROOT/transactions/$name"
    mkdir -p "$CURRENT_TX/backup"
    printf 'SCRIPT_VERSION="%s"\n' "$version" > "$RR_LIB_DIR/modules/00-runtime.sh"
    printf 'SUB_PORT=%s\nKEEP_DATA=unchanged\n' "$port" > "$RR_CONFIG_FILE"
    cp "$RR_CONFIG_FILE" "$CURRENT_TX/backup/argo_vmess.conf"
    : > "$CURRENT_TX/backup/had_argo_vmess.conf"
    printf 'original-backup\n' > "$CURRENT_TX/backup/sentinel"
    rr_snapshot_rollback_metadata "$CURRENT_TX"
}

printf '%s\n' '[1/9] snapshot records the old runtime SemVer and subscription port'
reset_case
prepare_transaction old 7.1.0 18080
[ "$(cat "$CURRENT_TX/backup/rollback-runtime-version")" = 7.1.0 ]
[ "$(cat "$CURRENT_TX/backup/rollback-subscription-port")" = 18080 ]
[ "$(cat "$CURRENT_TX/backup/rollback-metadata-complete")" = 1 ]
[ "$(stat -c '%a' "$CURRENT_TX/backup/rollback-runtime-version")" = 600 ]

printf '%s\n' '[2/9] pre-7.1.1 rollback is quarantined without touching other services or backup data'
: > "$CURRENT_TX/backup/subscription_was_running"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = quarantined ]
rr_quarantine_marker_read
[ "$RR_QUARANTINE_STATE" = quarantined ]
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ]
[ "$RR_QUARANTINE_PORT" = 18080 ]
[ "$RR_QUARANTINE_RESUME" = 1 ]
grep -Fq "ExecStart=$RR_RECOVERY_SELF quarantine-guard" "$RR_QUARANTINE_UNIT"
grep -Fxq 'original-backup' "$CURRENT_TX/backup/sentinel"
grep -Fxq 'KEEP_DATA=unchanged' "$RR_CONFIG_FILE"
if grep -Eq '(^| )(sing-box|rr-nexus)( |$)' "$SYSTEMCTL_LOG"; then
    echo 'Subscription rollback policy touched an unrelated service.' >&2
    exit 1
fi
resume_tx="$RR_TX_ROOT/transactions/resume-after-quarantine"
mkdir -p "$resume_tx/backup"
cp "$RR_CONFIG_FILE" "$resume_tx/backup/argo_vmess.conf"
: > "$resume_tx/backup/had_argo_vmess.conf"
rr_snapshot_rollback_metadata "$resume_tx"
[ -f "$resume_tx/backup/subscription_was_running" ]

printf '%s\n' '[3/9] 7.1.1+ rollback retains normal behavior and clears an old quarantine'
reset_case
prepare_transaction safe 7.1.1 18443
rr_quarantine_write_marker quarantined 7.1.0 18080
printf 'stale-unit\n' > "$RR_QUARANTINE_UNIT"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = normal ]
[ ! -e "$RR_QUARANTINE_FILE" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ -d "$CURRENT_TX/backup" ]

printf '%s\n' '[4/9] missing, forged, or inconsistent metadata fails safe'
reset_case
prepare_transaction forged 7.1.0 19090
printf '7.1.1\n' > "$CURRENT_TX/backup/rollback-runtime-version"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = quarantined ]
rr_quarantine_marker_read
[ "$RR_QUARANTINE_VERSION" = unknown ]

reset_case
CURRENT_TX="$RR_TX_ROOT/transactions/missing"
mkdir -p "$CURRENT_TX/backup"
printf 'SCRIPT_VERSION="7.1.1"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
printf 'SUB_PORT=not-a-port\n' > "$RR_CONFIG_FILE"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = degraded ]
rr_quarantine_marker_read
[ "$RR_QUARANTINE_STATE" = degraded ]
[ "$RR_QUARANTINE_PORT" = 0 ]

printf '%s\n' '[5/9] quarantine firewall operations are exact and never flush user rules'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    rule_log="$TEST_ROOT/rule.log"
    : > "$rule_log"
    iptables() {
        printf '%s\n' "$*" >> "$rule_log"
        case "$*" in *' -C '*) return 1 ;; *) return 0 ;; esac
    }
    rr_quarantine_rule add iptables 23456
    grep -Fq -- '-t raw -I PREROUTING 1 ! -i lo -p tcp --dport 23456' "$rule_log"
    grep -Fq -- '--comment rr-vps unsafe rollback subscription quarantine -j DROP' "$rule_log"
    if grep -Eq '(^| )(flush|-F|--flush)( |$)' "$rule_log"; then
        echo 'Quarantine attempted to flush unrelated firewall state.' >&2
        exit 1
    fi
)

printf '%s\n' '[6/9] automatic/manual restore orchestration skips only the unsafe subscription restart'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_HEALTH_SERVICE_FILE="$TEST_ROOT/fake-health.service"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    : > "$RR_HEALTH_SERVICE_FILE"
    restore_log="$TEST_ROOT/restore-systemctl.log"
    rm -f "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"

    systemctl() {
        printf '%s\n' "$*" >> "$restore_log"
        case "$*" in
            *"enable --now rr-subscription-quarantine.service"*)
                mkdir -p "$(dirname "$RR_QUARANTINE_READY")"
                printf 'ready\n' > "$RR_QUARANTINE_READY"
                ;;
        esac
        return 0
    }
    rr_stop_subscription_servers() { :; }
    rr_quarantine_add_firewall_rules() { :; }
    rr_quarantine_remove_firewall_rules() { :; }
    rr_restore_file() {
        if [ "$1" = argo_vmess.conf ]; then
            cp "$RR_BACKUP/argo_vmess.conf" "$RR_CONFIG_FILE"
        fi
    }
    rr_restore_dir() { :; }
    rr_restore_database() { :; }
    rr_verify_restored_state() { :; }
    sleep() { :; }

    prepare_restore() {
        local name="$1" version="$2" port="$3"
        RESTORE_TX="$RR_TX_ROOT/transactions/$name"
        rm -rf "$RR_LIB_DIR" "$RESTORE_TX"
        mkdir -p "$RR_LIB_DIR/modules" "$RESTORE_TX/backup"
        printf 'SCRIPT_VERSION="%s"\n' "$version" > "$RR_LIB_DIR/modules/00-runtime.sh"
        printf 'SUB_PORT=%s\nRESTORE_SENTINEL=present\n' "$port" > "$RR_CONFIG_FILE"
        cp "$RR_CONFIG_FILE" "$RESTORE_TX/backup/argo_vmess.conf"
        : > "$RESTORE_TX/backup/had_argo_vmess.conf"
        : > "$RESTORE_TX/backup/subscription_was_running"
        : > "$RESTORE_TX/backup/health_timer_was_enabled"
        : > "$RESTORE_TX/backup/singbox_was_running"
        : > "$RESTORE_TX/backup/nexus_was_running"
        rr_snapshot_rollback_metadata "$RESTORE_TX"
        mv "$RR_LIB_DIR" "$RESTORE_TX/old-runtime"
        mkdir -p "$RR_LIB_DIR/modules"
        printf 'SCRIPT_VERSION="9.9.9"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
        printf 'runtime_swapped\n' > "$RESTORE_TX/phase"
        printf '%s\n' "$RESTORE_TX" > "$RR_ACTIVE_TX"
    }

    prepare_restore legacy-restore 7.1.0 24567
    : > "$restore_log"
    set +e
    rr_restore_transaction "$RESTORE_TX" 'test interrupted update'
    legacy_rc=$?
    set -e
    [ "$legacy_rc" -eq 3 ]
    [ "$(cat "$RESTORE_TX/phase")" = rolled_back_degraded ]
    [ "$(cat "$RESTORE_TX/rollback-subscription-status")" = quarantined ]
    [ ! -e "$RR_ACTIVE_TX" ]
    grep -Fq 'RESTORE_SENTINEL=present' "$RR_CONFIG_FILE"
    if grep -Fq 'start --no-block argo-rr-health.service' "$restore_log"; then
        echo 'Unsafe rollback queued the legacy subscription health restart.' >&2
        exit 1
    fi
    grep -Fq 'restart --no-block sing-box' "$restore_log"
    grep -Fq 'restart --no-block rr-nexus' "$restore_log"

    prepare_restore safe-restore 7.1.1 24568
    : > "$restore_log"
    rr_restore_transaction "$RESTORE_TX" 'test manual rollback'
    [ "$(cat "$RESTORE_TX/phase")" = rolled_back ]
    [ "$(cat "$RESTORE_TX/rollback-subscription-status")" = normal ]
    grep -Fq 'start --no-block argo-rr-health.service' "$restore_log"
    [ ! -e "$RR_QUARANTINE_FILE" ]
)

printf '%s\n' '[7/9] in-process installer rollback consumes the same policy before health recovery'
(
    rollback_function=$(awk '
        /^rr_rollback\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/scripts/install-core.sh")
    eval "$rollback_function"
    immediate_root="$TEST_ROOT/immediate"
    RR_TX_ROOT="$immediate_root/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    RR_RECOVERY_HELPER="$immediate_root/rr-update-recover"
    RR_LIB_DIR="$immediate_root/live-runtime"
    RR_LAUNCHER="$immediate_root/rr"
    RR_SUBSCRIPTION_SAFE_VERSION=7.1.1
    launch_log="$immediate_root/launcher.log"
    mkdir -p "$RR_TX_ROOT/transactions" "$immediate_root"
    printf '%s\n' '#!/bin/bash' 'printf "health\n" >> "$RR_TEST_LAUNCH_LOG"' > "$RR_LAUNCHER"
    chmod 700 "$RR_LAUNCHER"
    export RR_TEST_LAUNCH_LOG="$launch_log"
    printf '%s\n' '#!/bin/bash' \
        'status=$(cat "$2/test-policy")' \
        'printf "%s\n" "$status" > "$2/rollback-subscription-status"' > "$RR_RECOVERY_HELPER"
    chmod 700 "$RR_RECOVERY_HELPER"

    systemctl() { :; }
    rr_stop_subscription_servers() { :; }
    rr_error() { :; }
    rr_restore_file() { :; }
    rr_restore_dir() { :; }
    rr_restore_sqlite() { :; }
    rr_install_restore_external_state_if_required() { :; }
    rr_write_phase() { printf '%s\n' "$1" > "$TX_DIR/phase"; }

    prepare_immediate() {
        local name="$1" policy="$2"
        TX_DIR="$RR_TX_ROOT/transactions/$name"
        BACKUP_DIR="$TX_DIR/backup"
        OLD_RUNTIME="$TX_DIR/old-runtime"
        rm -rf "$TX_DIR" "$RR_LIB_DIR"
        mkdir -p "$OLD_RUNTIME/modules" "$BACKUP_DIR" "$RR_LIB_DIR/modules"
        printf 'old\n' > "$OLD_RUNTIME/modules/sentinel"
        printf 'candidate\n' > "$RR_LIB_DIR/modules/sentinel"
        printf '%s\n' "$policy" > "$TX_DIR/test-policy"
        : > "$BACKUP_DIR/subscription_was_running"
        printf '%s\n' "$TX_DIR" > "$RR_ACTIVE_TX"
        TRANSACTION_ACTIVE=true
        RUNTIME_REPLACED=true
        ROLLBACK_FAILED=false
        KEEP_TRANSACTION=false
        : > "$launch_log"
    }

    prepare_immediate unsafe quarantined
    rr_rollback
    [ "$(cat "$TX_DIR/phase")" = rolled_back_degraded ]
    [ "$KEEP_TRANSACTION" = true ]
    [ ! -s "$launch_log" ]
    [ -f "$RR_LIB_DIR/modules/sentinel" ]

    prepare_immediate safe normal
    rr_rollback
    [ "$(cat "$TX_DIR/phase")" = rolled_back ]
    grep -Fxq health "$launch_log"
    [ "$KEEP_TRANSACTION" = false ]
)

printf '%s\n' '[8/9] status exposes quarantine/degraded state instead of claiming a normal rollback'
reset_case
rr_quarantine_write_marker degraded unknown 0
status_json=$(main status)
python3 - "$status_json" <<'PY'
import json, sys
status = json.loads(sys.argv[1])
assert status["active"] is False
assert status["subscription_quarantine"] == {
    "active": True, "state": "degraded", "target_version": "unknown", "port": 0,
    "resume_subscription": 0
}
PY
lock_tx="$RR_TX_ROOT/transactions/lock-contention"
mkdir -p "$lock_tx/backup" "$(dirname "$RR_UPDATE_LOCK_FILE")"
printf 'runtime_swapped\n' > "$lock_tx/phase"
printf '%s\n' "$lock_tx" > "$RR_ACTIVE_TX"
exec {held_lock_fd}>"$RR_UPDATE_LOCK_FILE"
flock -n "$held_lock_fd"
set +e
main rollback >/dev/null 2>&1
lock_rc=$?
set -e
[ "$lock_rc" -eq 1 ]
[ -e "$RR_ACTIVE_TX" ]
exec {held_lock_fd}>&-
rm -f "$RR_ACTIVE_TX"

printf '%s\n' '[9/9] independent guard prevents a manually launched legacy HTTP server'
unset -f sleep
rr_quarantine_add_firewall_rules() { :; }
rr_stop_subscription_servers() { :; }
rr_recover_log() { :; }
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
rm -f "$RR_QUARANTINE_READY"
rr_quarantine_write_marker quarantined 7.1.0 "$port"
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 100); do
    [ -f "$RR_QUARANTINE_READY" ] && break
    /bin/sleep 0.05
done
[ -f "$RR_QUARANTINE_READY" ]
if python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
PY
then
    echo 'Legacy server could bind the quarantined public subscription port.' >&2
    exit 1
fi
python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.5)
raise SystemExit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0 else 1)
PY
kill "$GUARD_PID"
wait "$GUARD_PID" 2>/dev/null || true
GUARD_PID=""

printf '%s\n' 'rollback quarantine regression: PASS'
