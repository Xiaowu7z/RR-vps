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
export RR_QUARANTINE_GUARD_STATE="$TEST_ROOT/guard-state/guard-state"
export RR_QUARANTINE_GUARD_SELF="$TEST_ROOT/guard-bin/subscription-quarantine-guard"
export RR_RECOVERY_SELF="$TEST_ROOT/bin/rr-update-recover"
export RR_IPV6_STATE_FILE="$TEST_ROOT/no-ipv6"
export RR_HEALTH_TIMER_FILE="$TEST_ROOT/systemd/argo-rr-health.timer"
export RR_HEALTH_SERVICE_FILE="$TEST_ROOT/systemd/argo-rr-health.service"
export RR_HEALTH_RESTART_HELPER="$TEST_ROOT/bin/auto_update_sub.py"
export RR_UPDATE_LOCK_FILE="$TEST_ROOT/run/rr-update.lock"
export RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/run/legacy-rr-update.lock"
export RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/run/legacy-update-bridge"
export RR_UPDATE_RECOVER_SOURCE_ONLY=1
export RR_TEST_QUARANTINE_STOP_FAIL="$TEST_ROOT/quarantine-stop-fail"
export RR_TEST_QUARANTINE_QUERY_FAIL="$TEST_ROOT/quarantine-query-fail"
export RR_TEST_QUARANTINE_ENABLED="$TEST_ROOT/quarantine-enabled"
export RR_TEST_QUARANTINE_FAILED="$TEST_ROOT/quarantine-failed"
export RR_TEST_QUARANTINE_RESET_FAIL="$TEST_ROOT/quarantine-reset-fail"
RR_TEST_QUARANTINE_UNIT_FILE_STATE=""
RR_TEST_QUARANTINE_FRAGMENT_PATH=""
RR_TEST_QUARANTINE_DROP_IN_PATHS=""
# shellcheck source=../scripts/update-recover.sh
source "$REPO_ROOT/scripts/update-recover.sh"
eval "$(declare -f rr_quarantine_guard_cleanup_uninstalled_runtime | \
    sed '1s/rr_quarantine_guard_cleanup_uninstalled_runtime/rr_test_production_guard_cleanup_uninstalled_runtime/')"
eval "$(declare -f rr_quarantine_install_guard_self | \
    sed '1s/rr_quarantine_install_guard_self/rr_test_production_install_guard_self/')"

SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
FIREWALL_LOG="$TEST_ROOT/firewall.log"
systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$*" in
        *"enable --now rr-subscription-quarantine.service"*)
            mkdir -p "$(dirname "$RR_QUARANTINE_READY")"
            (umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
            : > "$RR_TEST_QUARANTINE_ENABLED"
            ;;
        "is-active --quiet rr-subscription-quarantine.service")
            [ -e "$RR_QUARANTINE_READY" ]; return
            ;;
        "is-enabled --quiet rr-subscription-quarantine.service")
            [ -e "$RR_TEST_QUARANTINE_ENABLED" ]; return
            ;;
        "show -p LoadState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_QUERY_FAIL" ] || return 1
            [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n'
            ;;
        "show -p ActiveState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_QUERY_FAIL" ] || return 1
            if [ -e "$RR_QUARANTINE_READY" ]; then
                printf 'active\n'
            elif [ -e "$RR_TEST_QUARANTINE_FAILED" ]; then
                printf 'failed\n'
            else
                printf 'inactive\n'
            fi
            ;;
        "show -p UnitFileState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_QUERY_FAIL" ] || return 1
            if [ ! -e "$RR_QUARANTINE_UNIT" ]; then
                :
            elif [ -n "$RR_TEST_QUARANTINE_UNIT_FILE_STATE" ]; then
                printf '%s\n' "$RR_TEST_QUARANTINE_UNIT_FILE_STATE"
            elif [ -e "$RR_TEST_QUARANTINE_ENABLED" ]; then
                printf 'enabled\n'
            else
                printf 'disabled\n'
            fi
            ;;
        "show -p FragmentPath --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_QUERY_FAIL" ] || return 1
            if [ -n "$RR_TEST_QUARANTINE_FRAGMENT_PATH" ]; then
                printf '%s\n' "$RR_TEST_QUARANTINE_FRAGMENT_PATH"
            elif [ -e "$RR_QUARANTINE_UNIT" ]; then
                printf '%s\n' "$RR_QUARANTINE_UNIT"
            fi
            ;;
        "show -p DropInPaths --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_QUERY_FAIL" ] || return 1
            printf '%s' "$RR_TEST_QUARANTINE_DROP_IN_PATHS"
            ;;
        "stop rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_STOP_FAIL" ] || return 1
            rm -f -- "$RR_QUARANTINE_READY"
            ;;
        "disable --now rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_STOP_FAIL" ] || return 1
            [ -e "$RR_QUARANTINE_UNIT" ] || return 1
            rm -f -- "$RR_QUARANTINE_READY" "$RR_TEST_QUARANTINE_ENABLED"
            : > "$RR_TEST_QUARANTINE_FAILED"
            ;;
        "reset-failed rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_QUARANTINE_RESET_FAIL" ] || return 1
            rm -f -- "$RR_TEST_QUARANTINE_FAILED"
            ;;
        "disable rr-subscription-quarantine.service")
            rm -f -- "$RR_TEST_QUARANTINE_ENABLED"
            ;;
        "show -p LoadState --value argo-rr-health.timer"|\
        "show -p LoadState --value argo-rr-health.service") printf 'not-found\n' ;;
        "show -p ActiveState --value argo-rr-health.timer"|\
        "show -p ActiveState --value argo-rr-health.service") printf 'inactive\n' ;;
        "show -p UnitFileState --value argo-rr-health.timer"|\
        "show -p UnitFileState --value argo-rr-health.service") : ;;
    esac
    return 0
}
rr_stop_subscription_servers() { printf 'stop-subscription\n' >> "$SYSTEMCTL_LOG"; }
rr_quarantine_add_firewall_rules() { printf 'add:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_firewall_rules() { printf 'delete:%s\n' "$1" >> "$FIREWALL_LOG"; }
sleep() { :; }

reset_case() {
    rm -rf "$RR_TX_ROOT/transactions" "$RR_LIB_DIR" "$RR_QUARANTINE_FILE" \
        "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" "$RR_CONFIG_FILE" \
        "$(dirname "$RR_QUARANTINE_GUARD_STATE")" \
        "$(dirname "$RR_QUARANTINE_GUARD_SELF")" \
        "$(dirname "$RR_RECOVERY_SELF")"
    rm -f -- "$RR_TEST_QUARANTINE_STOP_FAIL" "$RR_TEST_QUARANTINE_QUERY_FAIL" \
        "$RR_TEST_QUARANTINE_ENABLED" "$RR_TEST_QUARANTINE_FAILED" \
        "$RR_TEST_QUARANTINE_RESET_FAIL" \
        "$RR_LEGACY_UPDATE_LOCK_FILE" \
        "$RR_LEGACY_UPDATE_BRIDGE_FILE"
    RR_TEST_QUARANTINE_UNIT_FILE_STATE=""
    RR_TEST_QUARANTINE_FRAGMENT_PATH=""
    RR_TEST_QUARANTINE_DROP_IN_PATHS=""
    mkdir -p "$RR_TX_ROOT/transactions" "$RR_LIB_DIR/modules" \
        "$(dirname "$RR_QUARANTINE_READY")" "$(dirname "$RR_RECOVERY_SELF")"
    install -o 0 -g 0 -m 755 "$REPO_ROOT/scripts/update-recover.sh" "$RR_RECOVERY_SELF"
    : > "$SYSTEMCTL_LOG"
    : > "$FIREWALL_LOG"
}

prepare_transaction() {
    local name="$1" version="$2" port="$3"
    CURRENT_TX="$RR_TX_ROOT/transactions/$name"
    mkdir -p "$CURRENT_TX/backup"
    chmod 700 "$CURRENT_TX" "$CURRENT_TX/backup"
    printf 'SCRIPT_VERSION="%s"\n' "$version" > "$RR_LIB_DIR/modules/00-runtime.sh"
    printf 'SUB_PORT=%s\nKEEP_DATA=unchanged\n' "$port" > "$RR_CONFIG_FILE"
    cp "$RR_CONFIG_FILE" "$CURRENT_TX/backup/argo_vmess.conf"
    : > "$CURRENT_TX/backup/had_argo_vmess.conf"
    printf 'original-backup\n' > "$CURRENT_TX/backup/sentinel"
    rr_snapshot_rollback_metadata "$CURRENT_TX"
}

printf '%s\n' '[1/20] snapshot records the old runtime SemVer and subscription port'
reset_case
prepare_transaction old 7.1.0 18080
[ "$(cat "$CURRENT_TX/backup/rollback-runtime-version")" = 7.1.0 ]
[ "$(cat "$CURRENT_TX/backup/rollback-subscription-port")" = 18080 ]
[ "$(cat "$CURRENT_TX/backup/rollback-metadata-complete")" = 1 ]
[ "$(stat -c '%a' "$CURRENT_TX/backup/rollback-runtime-version")" = 600 ]
broken_tx="$RR_TX_ROOT/transactions/broken-marker"
mkdir -p "$broken_tx/backup"
chmod 700 "$broken_tx" "$broken_tx/backup"
ln -s "$TEST_ROOT/missing-marker" "$RR_QUARANTINE_FILE"
if rr_snapshot_rollback_metadata "$broken_tx"; then
    echo 'Snapshot ignored a broken quarantine-marker symlink.' >&2
    exit 1
fi
[ ! -e "$broken_tx/backup/rollback-metadata-complete" ]
rm -f -- "$RR_QUARANTINE_FILE"

printf '%s\n' '[2/20] pre-7.1.1 rollback is quarantined without touching other services or backup data'
: > "$CURRENT_TX/backup/subscription_was_running"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = quarantined ]
rr_quarantine_marker_read
[ "$RR_QUARANTINE_STATE" = quarantined ]
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ]
[ "$RR_QUARANTINE_PORT" = 18080 ]
[ "$RR_QUARANTINE_RESUME" = 1 ]
grep -Fq "ExecStart=$RR_QUARANTINE_GUARD_SELF quarantine-guard" "$RR_QUARANTINE_UNIT"
grep -Fxq 'Restart=on-failure' "$RR_QUARANTINE_UNIT"
[ -f "$RR_QUARANTINE_GUARD_STATE" ]
[ -x "$RR_QUARANTINE_GUARD_SELF" ]
grep -Fxq 'original-backup' "$CURRENT_TX/backup/sentinel"
grep -Fxq 'KEEP_DATA=unchanged' "$RR_CONFIG_FILE"
if grep -Eq '(^| )(sing-box|rr-nexus)( |$)' "$SYSTEMCTL_LOG"; then
    echo 'Subscription rollback policy touched an unrelated service.' >&2
    exit 1
fi
resume_tx="$RR_TX_ROOT/transactions/resume-after-quarantine"
mkdir -p "$resume_tx/backup"
chmod 700 "$resume_tx" "$resume_tx/backup"
cp "$RR_CONFIG_FILE" "$resume_tx/backup/argo_vmess.conf"
: > "$resume_tx/backup/had_argo_vmess.conf"
rr_snapshot_rollback_metadata "$resume_tx"
[ -f "$resume_tx/backup/subscription_was_running" ]

printf '%s\n' '[3/20] 7.1.1+ rollback retains normal behavior and clears an old quarantine'
reset_case
prepare_transaction safe 7.1.1 18443
rr_quarantine_write_marker quarantined 7.1.0 18080
printf 'stale-unit\n' > "$RR_QUARANTINE_UNIT"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = normal ]
[ ! -e "$RR_QUARANTINE_FILE" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ -d "$CURRENT_TX/backup" ]
grep -Fxq 'reset-failed rr-subscription-quarantine.service' "$SYSTEMCTL_LOG"
rr_quarantine_guard_unit_state_read
rr_quarantine_guard_unit_state_is_absent

reset_case
prepare_transaction failed-cache 7.1.1 18443
rr_quarantine_write_marker quarantined 7.1.0 18080
printf 'stale-unit\n' > "$RR_QUARANTINE_UNIT"
: > "$RR_TEST_QUARANTINE_RESET_FAIL"
if rr_apply_rollback_subscription_policy "$CURRENT_TX" >/dev/null 2>&1; then
    echo 'A persistent failed unit cache was accepted before firewall release.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
if grep -q '^delete:' "$FIREWALL_LOG"; then
    echo 'A failed unit-cache reset released the quarantine firewall.' >&2
    exit 1
fi
rm -f -- "$RR_TEST_QUARANTINE_RESET_FAIL"
rr_apply_rollback_subscription_policy "$CURRENT_TX"
[ "$(cat "$CURRENT_TX/rollback-subscription-status")" = normal ]
[ ! -e "$RR_QUARANTINE_FILE" ]
grep -Fxq 'delete:18080' "$FIREWALL_LOG"
rr_quarantine_guard_unit_state_read
rr_quarantine_guard_unit_state_is_absent

printf '%s\n' '[4/20] missing, forged, or inconsistent metadata fails safe'
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
chmod 700 "$CURRENT_TX" "$CURRENT_TX/backup"
printf 'SCRIPT_VERSION="7.1.1"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
printf 'SUB_PORT=not-a-port\n' > "$RR_CONFIG_FILE"
if rr_apply_rollback_subscription_policy "$CURRENT_TX"; then
    echo 'Rollback without a verified subscription port was accepted.' >&2
    exit 1
fi
[ ! -e "$CURRENT_TX/rollback-subscription-status" ]
rr_quarantine_marker_read
[ "$RR_QUARANTINE_STATE" = degraded ]
[ "$RR_QUARANTINE_PORT" = 0 ]

(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    runtime_root="$TEST_ROOT/trusted-runtime"
    runtime_file="$runtime_root/modules/00-runtime.sh"
    mkdir -p "$runtime_root/modules"
    chmod 0755 "$runtime_root" "$runtime_root/modules"
    printf 'SCRIPT_VERSION="7.1.1"\n' > "$runtime_file"
    chmod 0600 "$runtime_file"
    [ "$(rr_trusted_runtime_version "$runtime_root")" = 7.1.1 ] || {
        echo 'A strict runtime version fixture was rejected.' >&2
        exit 1
    }
    chmod 0777 "$runtime_root/modules"
    if rr_trusted_runtime_version "$runtime_root" >/dev/null 2>&1; then
        echo 'A runtime below a writable modules directory was trusted.' >&2
        exit 1
    fi
    chmod 0755 "$runtime_root/modules"
    printf 'SCRIPT_VERSION="7.0.0"\n' > "$runtime_file.replacement"
    chmod 0600 "$runtime_file.replacement"
    runtime_stat_counter_file="$TEST_ROOT/runtime-stat-count"
    printf '0\n' > "$runtime_stat_counter_file"
    stat() {
        local path="" argument="" runtime_stat_count=0
        path="${!#}"
        if [ "$path" = "$runtime_file" ]; then
            for argument in "$@"; do
                if [ "$argument" = '%d:%i:%u:%g:%a:%h' ]; then
                    runtime_stat_count=$(cat "$runtime_stat_counter_file")
                    runtime_stat_count=$((runtime_stat_count + 1))
                    printf '%s\n' "$runtime_stat_count" > "$runtime_stat_counter_file"
                    if [ "$runtime_stat_count" -eq 2 ]; then
                        mv -- "$runtime_file" "$runtime_file.opened"
                        mv -- "$runtime_file.replacement" "$runtime_file"
                    fi
                    break
                fi
            done
        fi
        command stat "$@"
    }
    if rr_trusted_runtime_version "$runtime_root" >/dev/null 2>&1; then
        echo 'A runtime version path swapped after fd binding was trusted.' >&2
        exit 1
    fi
)

printf '%s\n' '[5/20] quarantine firewall operations are exact and never flush user rules'
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
    exact_rule='-A PREROUTING ! -i lo -p tcp -m tcp --dport 23456 -m addrtype --dst-type LOCAL -m comment --comment "rr-vps unsafe rollback subscription quarantine" -j DROP'
    raw_v4="$exact_rule"
    raw_v6=""
    firewall_query_fails=false
    iptables() {
        [ "$firewall_query_fails" = false ] || return 1
        printf '%s\n' "$raw_v4"
    }
    ip6tables() { printf '%s\n' "$raw_v6"; }
    rm -f -- "$RR_IPV6_STATE_FILE"
    rr_quarantine_firewall_inventory_is_exact 23456 || {
        echo 'An exact IPv4 quarantine inventory was rejected.' >&2
        exit 1
    }
    raw_v4=$(printf '%s\n%s\n' "$exact_rule" "$exact_rule")
    if rr_quarantine_firewall_inventory_is_exact 23456; then
        echo 'Duplicate quarantine rules were accepted as exact.' >&2
        exit 1
    fi
    raw_v4="${exact_rule/23456/23457}"
    if rr_quarantine_firewall_inventory_is_exact 23456; then
        echo 'A quarantine rule for the wrong port was accepted.' >&2
        exit 1
    fi
    raw_v4="$exact_rule"
    firewall_query_fails=true
    if rr_quarantine_firewall_inventory_is_exact 23456; then
        echo 'An unreadable firewall inventory was accepted as exact.' >&2
        exit 1
    fi
    firewall_query_fails=false
    printf 'enabled\n' > "$RR_IPV6_STATE_FILE"
    if rr_quarantine_firewall_inventory_is_exact 23456; then
        echo 'IPv6 quarantine was accepted without its required exact rule.' >&2
        exit 1
    fi
    raw_v6="$exact_rule"
    rr_quarantine_firewall_inventory_is_exact 23456 || {
        echo 'Exact dual-stack quarantine inventory was rejected.' >&2
        exit 1
    }
)

printf '%s\n' '[6/20] automatic/manual restore orchestration skips only the unsafe subscription restart'
(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_HEALTH_SERVICE_FILE="$TEST_ROOT/fake-health.service"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    # Exact managed-unit identity is covered by the service ownership suites;
    # this fixture isolates rollback subscription orchestration.
    rr_managed_service_start_is_safe() { return 0; }
    : > "$RR_HEALTH_SERVICE_FILE"
    restore_log="$TEST_ROOT/restore-systemctl.log"
    quarantine_active="$TEST_ROOT/restore-quarantine-active"
    quarantine_enabled="$TEST_ROOT/restore-quarantine-enabled"
    rm -f "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
        "$RR_QUARANTINE_GUARD_STATE" "$RR_QUARANTINE_GUARD_SELF" \
        "$quarantine_active" "$quarantine_enabled"

    systemctl() {
        printf '%s\n' "$*" >> "$restore_log"
        case "$*" in
            *"enable --now rr-subscription-quarantine.service"*)
                mkdir -p "$(dirname "$RR_QUARANTINE_READY")"
                (umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
                : > "$quarantine_active"
                : > "$quarantine_enabled"
                ;;
            "is-active --quiet rr-subscription-quarantine.service")
                [ -e "$quarantine_active" ]; return ;;
            "is-enabled --quiet rr-subscription-quarantine.service")
                [ -e "$quarantine_enabled" ]; return ;;
            "show -p LoadState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n' ;;
            "show -p ActiveState --value rr-subscription-quarantine.service")
                [ -e "$quarantine_active" ] && printf 'active\n' || printf 'inactive\n' ;;
            "show -p UnitFileState --value rr-subscription-quarantine.service")
                if [ ! -e "$RR_QUARANTINE_UNIT" ]; then
                    :
                elif [ -e "$quarantine_enabled" ]; then
                    printf 'enabled\n'
                else
                    printf 'disabled\n'
                fi ;;
            "show -p FragmentPath --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf '%s\n' "$RR_QUARANTINE_UNIT" ;;
            "show -p DropInPaths --value rr-subscription-quarantine.service") : ;;
            "stop rr-subscription-quarantine.service")
                rm -f -- "$quarantine_active" "$RR_QUARANTINE_READY" ;;
            "disable --now rr-subscription-quarantine.service")
                rm -f -- "$quarantine_active" "$quarantine_enabled" \
                    "$RR_QUARANTINE_READY" ;;
            "disable rr-subscription-quarantine.service")
                rm -f -- "$quarantine_enabled" ;;
            "is-active --quiet argo-rr-health.timer"|\
            "is-active --quiet argo-rr-health.service"|\
            "is-enabled --quiet argo-rr-health.timer") return 1 ;;
            "show -p LoadState --value argo-rr-health.timer"|\
            "show -p LoadState --value argo-rr-health.service") printf 'loaded\n' ;;
            "show -p ActiveState --value argo-rr-health.timer"|\
            "show -p ActiveState --value argo-rr-health.service") printf 'inactive\n' ;;
            "show -p UnitFileState --value argo-rr-health.timer") printf 'disabled\n' ;;
            "show -p UnitFileState --value argo-rr-health.service") printf 'static\n' ;;
            "show -p LoadState --value "*) printf 'loaded\n' ;;
            "show -p ActiveState --value "*) printf 'inactive\n' ;;
            "show -p UnitFileState --value "*) printf 'disabled\n' ;;
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
        chmod 700 "$RESTORE_TX" "$RESTORE_TX/backup"
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

printf '%s\n' '[7/20] in-process installer rollback consumes the same policy before health recovery'
(
    delegate_close_function=$(awk '
        /^rr_close_inherited_installer_lock_fds\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/scripts/install-core.sh")
    delegate_function=$(awk '
        /^rr_run_with_delegated_update_lock\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/scripts/install-core.sh")
    resume_function=$(awk '
        /^rr_resume_subscription_bounded\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/scripts/install-core.sh")
    rollback_function=$(awk '
        /^rr_rollback\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/scripts/install-core.sh")
    eval "$delegate_close_function"
    eval "$delegate_function"
    eval "$resume_function"
    eval "$rollback_function"
    immediate_root="$TEST_ROOT/immediate"
    RR_TX_ROOT="$immediate_root/update"
    RR_ACTIVE_TX="$RR_TX_ROOT/active"
    RR_RECOVERY_HELPER="$immediate_root/rr-update-recover"
    RR_LIB_DIR="$immediate_root/live-runtime"
    RR_LAUNCHER="$immediate_root/rr"
    RR_SUBSCRIPTION_SAFE_VERSION=7.1.1
    launch_log="$immediate_root/launcher.log"
    subscription_running_marker="$immediate_root/subscription-running"
    mkdir -p "$RR_TX_ROOT/transactions" "$immediate_root"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s|%s\n" "${RR_UPDATE_LOCK_HELD:-0}" "$*" >> "$RR_TEST_LAUNCH_LOG"' \
        '[ "${1:-}" = --refresh-subscription ] || exit 64' \
        ': > "$RR_TEST_SUBSCRIPTION_RUNNING"' > "$RR_LAUNCHER"
    chmod 700 "$RR_LAUNCHER"
    export RR_TEST_LAUNCH_LOG="$launch_log"
    export RR_TEST_SUBSCRIPTION_RUNNING="$subscription_running_marker"
    printf '%s\n' '#!/bin/bash' \
        'status=$(cat "$2/test-policy")' \
        'printf "%s\n" "$status" > "$2/rollback-subscription-status"' > "$RR_RECOVERY_HELPER"
    chmod 700 "$RR_RECOVERY_HELPER"

    systemctl() { :; }
    rr_stop_subscription_servers() { rm -f -- "$subscription_running_marker"; }
    rr_subscription_running() { [ -e "$subscription_running_marker" ]; }
    rr_error() { :; }
    rr_restore_file() { :; }
    rr_restore_dir() { :; }
    rr_restore_sqlite() { :; }
    rr_install_restore_external_state_if_required() { :; }
    rr_restore_ip_acme_update_directories() { :; }
    rr_read_trusted_phase() { printf 'runtime_swapped\n'; }
    rr_quiesce_health_monitor_for_rollback() { :; }
    rr_write_phase() { printf '%s\n' "$1" > "$TX_DIR/phase"; }
    rr_sync_host_state_before_terminal() { :; }

    prepare_immediate() {
        local name="$1" policy="$2"
        TX_DIR="$RR_TX_ROOT/transactions/$name"
        BACKUP_DIR="$TX_DIR/backup"
        OLD_RUNTIME="$TX_DIR/old-runtime"
        rm -rf "$TX_DIR" "$RR_LIB_DIR"
        mkdir -p "$OLD_RUNTIME/modules" "$BACKUP_DIR" "$RR_LIB_DIR/modules"
        chmod 700 "$TX_DIR" "$BACKUP_DIR"
        printf 'old\n' > "$OLD_RUNTIME/modules/sentinel"
        printf 'candidate\n' > "$RR_LIB_DIR/modules/sentinel"
        printf '%s\n' "$policy" > "$TX_DIR/test-policy"
        : > "$BACKUP_DIR/subscription_was_running"
        printf '%s\n' "$TX_DIR" > "$RR_ACTIVE_TX"
        TRANSACTION_ACTIVE=true
        RUNTIME_REPLACED=true
        ROLLBACK_FAILED=false
        KEEP_TRANSACTION=false
        rm -f -- "$launch_log" "$subscription_running_marker"
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
    grep -Fxq '1|--refresh-subscription' "$launch_log"
    [ -e "$subscription_running_marker" ]
    [ "$KEEP_TRANSACTION" = false ]
)

printf '%s\n' '[8/20] status exposes quarantine/degraded state instead of claiming a normal rollback'
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
rr_quarantine_sync_guard_state
rm -f -- "$RR_QUARANTINE_FILE"
state_only_json=$(main status)
python3 - "$state_only_json" <<'PY'
import json, sys
status = json.loads(sys.argv[1])
assert status["subscription_quarantine"]["active"] is True
assert status["subscription_quarantine"]["state"] == "degraded"
PY
ln -s "$TEST_ROOT/missing-marker-target" "$RR_QUARANTINE_FILE"
invalid_marker_json=$(main status)
python3 - "$invalid_marker_json" <<'PY'
import json, sys
status = json.loads(sys.argv[1])
assert status["subscription_quarantine"]["active"] is True
assert status["subscription_quarantine"]["state"] == "invalid"
PY
rm -f -- "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_GUARD_STATE"
lock_tx="$RR_TX_ROOT/transactions/lock-contention"
mkdir -p "$lock_tx/backup" "$(dirname "$RR_UPDATE_LOCK_FILE")"
chmod 700 "$lock_tx" "$lock_tx/backup"
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

printf '%s\n' '[9/20] guard blocks legacy servers and survives a pre-7.1.1 uninstall cleanup'
unset -f sleep
rr_quarantine_add_firewall_rules() { printf 'add:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_firewall_rules() { printf 'guard-delete:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_orphan_firewall_rules() { :; }
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
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
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
# Marker/helper deletion alone must retain the barrier while any old runtime
# remains. Once the legacy uninstaller has removed both runtime and launcher,
# the independent guard takes the new shared lock and self-cleans.
rm -f -- "$RR_QUARANTINE_FILE" "$RR_RECOVERY_SELF"
for _ in $(seq 1 20); do
    kill -0 "$GUARD_PID"
    /bin/sleep 0.05
done
rm -rf -- "$RR_LIB_DIR"
rm -f -- "$RR_LAUNCHER"
for _ in $(seq 1 100); do
    ! kill -0 "$GUARD_PID" 2>/dev/null && break
    /bin/sleep 0.05
done
wait "$GUARD_PID"
GUARD_PID=""
[ ! -e "$RR_QUARANTINE_READY" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ ! -e "$RR_QUARANTINE_GUARD_STATE" ]
[ ! -e "$RR_QUARANTINE_GUARD_SELF" ]
grep -Fxq "guard-delete:$port" "$FIREWALL_LOG"

printf '%s\n' '[10/20] firewall cleanup failures retain the reserved port'
reset_case
unset -f sleep
cleanup_allow="$TEST_ROOT/guard-cleanup-allow"
cleanup_attempts="$TEST_ROOT/guard-cleanup-attempts"
rm -f -- "$cleanup_allow" "$cleanup_attempts"
rr_quarantine_add_firewall_rules() { :; }
rr_quarantine_remove_firewall_rules() { printf 'guard-delete:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_orphan_firewall_rules() {
    printf 'attempt\n' >> "$cleanup_attempts"
    [ -e "$cleanup_allow" ]
}
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
rr_quarantine_write_marker quarantined 7.1.0 "$port"
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 100); do
    [ -f "$RR_QUARANTINE_READY" ] && break
    /bin/sleep 0.05
done
[ -f "$RR_QUARANTINE_READY" ]
rm -f -- "$RR_QUARANTINE_FILE" "$RR_RECOVERY_SELF"
for _ in $(seq 1 20); do
    [ ! -e "$cleanup_attempts" ]
    kill -0 "$GUARD_PID"
    /bin/sleep 0.05
done
rm -rf -- "$RR_LIB_DIR"
rm -f -- "$RR_LAUNCHER"
for _ in $(seq 1 100); do
    [ -s "$cleanup_attempts" ] && break
    /bin/sleep 0.05
done
[ -s "$cleanup_attempts" ]
kill -0 "$GUARD_PID"
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
    echo 'Cleanup failure released the quarantined subscription port.' >&2
    exit 1
fi
: > "$cleanup_allow"
for _ in $(seq 1 120); do
    ! kill -0 "$GUARD_PID" 2>/dev/null && break
    /bin/sleep 0.05
done
wait "$GUARD_PID"
GUARD_PID=""
[ ! -e "$RR_QUARANTINE_READY" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ ! -e "$RR_QUARANTINE_GUARD_STATE" ]
[ ! -e "$RR_QUARANTINE_GUARD_SELF" ]

printf '%s\n' '[11/20] locked self-clean failures retain the reserved port'
reset_case
unset -f sleep
finalize_allow="$TEST_ROOT/guard-finalize-allow"
finalize_attempts="$TEST_ROOT/guard-finalize-attempts"
rm -f -- "$finalize_allow" "$finalize_attempts"
rr_quarantine_guard_cleanup_uninstalled_runtime() {
    printf 'attempt\n' >> "$finalize_attempts"
    [ -e "$finalize_allow" ] || return 1
    rr_test_production_guard_cleanup_uninstalled_runtime "$@"
}
rr_quarantine_add_firewall_rules() { :; }
rr_quarantine_remove_firewall_rules() { :; }
rr_quarantine_remove_orphan_firewall_rules() { :; }
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
rr_quarantine_write_marker quarantined 7.1.0 "$port"
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 100); do
    [ -f "$RR_QUARANTINE_READY" ] && break
    /bin/sleep 0.05
done
[ -f "$RR_QUARANTINE_READY" ]
rm -f -- "$RR_QUARANTINE_FILE" "$RR_RECOVERY_SELF"
rm -rf -- "$RR_LIB_DIR"
rm -f -- "$RR_LAUNCHER"
for _ in $(seq 1 100); do
    [ -s "$finalize_attempts" ] && break
    /bin/sleep 0.05
done
[ -s "$finalize_attempts" ]
kill -0 "$GUARD_PID"
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
    echo 'Finalization failure released the quarantined subscription port.' >&2
    exit 1
fi
: > "$finalize_allow"
for _ in $(seq 1 120); do
    ! kill -0 "$GUARD_PID" 2>/dev/null && break
    /bin/sleep 0.05
done
wait "$GUARD_PID"
GUARD_PID=""
[ ! -e "$RR_QUARANTINE_READY" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ ! -e "$RR_QUARANTINE_GUARD_STATE" ]
[ ! -e "$RR_QUARANTINE_GUARD_SELF" ]

printf '%s\n' '[12/20] state-only guard restart replaces stale readiness before cleanup'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18112
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
(umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
rm -f -- "$RR_QUARANTINE_FILE" "$RR_LAUNCHER"
rm -rf -- "$RR_LIB_DIR"
if ( sync() { return 1; }; rr_test_production_guard_cleanup_uninstalled_runtime "$RR_QUARANTINE_READY" ); then
    echo 'Guard cleanup ignored a failed cross-filesystem durability barrier.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_READY" ] && [ -e "$RR_QUARANTINE_GUARD_STATE" ] &&
    [ -e "$RR_QUARANTINE_GUARD_SELF" ] || {
    echo 'Durability failure discarded the state-only guard barrier.' >&2
    exit 1
}
if (
    sync() { : > "$RR_LIB_DIR"; return 0; }
    rr_test_production_guard_cleanup_uninstalled_runtime "$RR_QUARANTINE_READY"
); then
    echo 'Guard cleanup ignored a runtime path that reappeared after sync.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_READY" ] && [ -e "$RR_QUARANTINE_GUARD_STATE" ] || {
    echo 'Post-sync reappearance discarded the guard barrier.' >&2
    exit 1
}

reset_case
unset -f sleep
read -r state_port marker_port < <(python3 - <<'PY'
import socket
sockets = []
ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    ports.append(sock.getsockname()[1])
    sockets.append(sock)
print(*ports)
for sock in sockets:
    sock.close()
PY
)
rr_quarantine_write_marker quarantined 7.1.0 "$state_port"
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
# Simulate power loss between the marker rename and the independent state
# rename. The reboot guard must bind the last durable guard-state port.
rr_quarantine_write_marker quarantined 7.0.9 "$marker_port"
rr_quarantine_add_firewall_rules() { :; }
rr_stop_subscription_servers() { :; }
rr_recover_log() { :; }
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 120); do
    [ "$(cat "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ] && break
    /bin/sleep 0.05
done
[ "$(cat "$RR_QUARANTINE_READY")" = ready ]
if python3 - "$state_port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
PY
then
    echo 'A marker/state crash mismatch left the durable guard-state port unreserved.' >&2
    exit 1
fi
/bin/sleep 0.1
kill -TERM "$GUARD_PID"
set +e
wait "$GUARD_PID" 2>/dev/null
guard_signal_status=$?
set -e
GUARD_PID=""
[ "$guard_signal_status" -eq 1 ] || {
    echo 'A direct guard TERM was reported as a clean service exit.' >&2
    exit 1
}
[ ! -e "$RR_QUARANTINE_READY" ]
# Simulate Restart=on-failure after the explicit nonzero signal result.  The
# new guard must immediately reserve the same durable state-only port again.
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 120); do
    [ "$(cat "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ] && break
    /bin/sleep 0.05
done
[ "$(cat "$RR_QUARANTINE_READY")" = ready ]
if python3 - "$state_port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
PY
then
    echo 'A restarted state-only guard did not reclaim its durable port.' >&2
    exit 1
fi
/bin/sleep 0.1
kill -TERM "$GUARD_PID"
set +e
wait "$GUARD_PID" 2>/dev/null
guard_signal_status=$?
set -e
GUARD_PID=""
[ "$guard_signal_status" -eq 1 ]

reset_case
unset -f sleep
restart_allow="$TEST_ROOT/guard-restart-allow"
restart_attempts="$TEST_ROOT/guard-restart-attempts"
rm -f -- "$restart_allow" "$restart_attempts"
rm -f -- "$RR_LEGACY_UPDATE_LOCK_FILE" "$RR_LEGACY_UPDATE_BRIDGE_FILE"
export restart_allow restart_attempts
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
rr_quarantine_write_marker quarantined 7.1.0 "$port"
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
printf 'stale\n' > "$RR_QUARANTINE_READY"
chmod 600 "$RR_QUARANTINE_READY"
exec {stale_ready_fd}<"$RR_QUARANTINE_READY"
stale_ready_inode=$(stat -c %i "$RR_QUARANTINE_READY")
rm -f -- "$RR_QUARANTINE_FILE" "$RR_RECOVERY_SELF"
(
    # Load the independently installed copy exactly as systemd would after an
    # old uninstaller deleted the primary recovery helper.
    # shellcheck source=/dev/null
    source "$RR_QUARANTINE_GUARD_SELF"
    systemctl() {
        case "$*" in
            'show -p LoadState --value argo-rr-health.timer'|\
            'show -p LoadState --value argo-rr-health.service') printf 'not-found\n' ;;
            'show -p ActiveState --value argo-rr-health.timer'|\
            'show -p ActiveState --value argo-rr-health.service') printf 'inactive\n' ;;
            'show -p UnitFileState --value argo-rr-health.timer'|\
            'show -p UnitFileState --value argo-rr-health.service') : ;;
        esac
        return 0
    }
    rr_quarantine_add_firewall_rules() { :; }
    rr_quarantine_remove_firewall_rules() { :; }
    rr_quarantine_remove_orphan_firewall_rules() {
        printf 'attempt\n' >> "$restart_attempts"
        while [ ! -e "$restart_allow" ]; do
            /bin/sleep 0.05
        done
    }
    rr_stop_subscription_servers() { :; }
    rr_subscription_running() { return 1; }
    rr_recover_log() { :; }
    rr_quarantine_guard
) &
GUARD_PID=$!
for _ in $(seq 1 120); do
    [ "$(cat "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ] && break
    /bin/sleep 0.05
done
[ "$(cat "$RR_QUARANTINE_READY")" = ready ]
[ "$(stat -c %i "$RR_QUARANTINE_READY")" != "$stale_ready_inode" ]
exec {stale_ready_fd}>&-
kill -0 "$GUARD_PID"
[ ! -e "$restart_attempts" ]
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
    echo 'State-only guard restart cleaned before reserving the port.' >&2
    exit 1
fi
rm -rf -- "$RR_LIB_DIR"
rm -f -- "$RR_LAUNCHER"
for _ in $(seq 1 120); do
    [ -s "$restart_attempts" ] && break
    /bin/sleep 0.05
done
[ -s "$restart_attempts" ]
[ "$(cat "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = rr-legacy-update-bridge-v1 ]
[ "$(stat -c '%U:%G:%a:%h' "$RR_LEGACY_UPDATE_BRIDGE_FILE")" = root:root:600:1 ]
[ "$(stat -c '%U:%G:%a:%h' "$RR_LEGACY_UPDATE_LOCK_FILE")" = root:root:600:1 ]
if (
    exec {legacy_contender_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$legacy_contender_fd"
); then
    echo 'State-only cleanup released the 7.1.0 compatibility flock before commit.' >&2
    exit 1
fi
: > "$restart_allow"
for _ in $(seq 1 120); do
    ! kill -0 "$GUARD_PID" 2>/dev/null && break
    /bin/sleep 0.05
done
wait "$GUARD_PID"
GUARD_PID=""
[ ! -e "$RR_QUARANTINE_READY" ]
[ ! -e "$RR_QUARANTINE_UNIT" ]
[ ! -e "$RR_QUARANTINE_GUARD_STATE" ]
[ ! -e "$RR_QUARANTINE_GUARD_SELF" ]

# A reboot can also leave an attacker-controlled inode at the predictable old
# lock path.  Cleanup must fail closed without repairing that inode, publishing
# a bridge, reaching firewall mutation, or releasing the socket reservation.
reset_case
unset -f sleep
unsafe_cleanup_callback="$TEST_ROOT/unsafe-cleanup-callback"
rm -f -- "$unsafe_cleanup_callback"
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
rr_quarantine_write_marker quarantined 7.1.0 "$port"
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
rm -f -- "$RR_QUARANTINE_FILE" "$RR_RECOVERY_SELF" "$RR_LAUNCHER"
rm -rf -- "$RR_LIB_DIR"
: > "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 0666 "$RR_LEGACY_UPDATE_LOCK_FILE"
unsafe_lock_inode=$(stat -c %i "$RR_LEGACY_UPDATE_LOCK_FILE")
rr_quarantine_add_firewall_rules() { :; }
rr_quarantine_remove_firewall_rules() { : > "$unsafe_cleanup_callback"; }
rr_quarantine_remove_orphan_firewall_rules() { : > "$unsafe_cleanup_callback"; }
rr_stop_subscription_servers() { :; }
rr_subscription_running() { return 1; }
rr_recover_log() { :; }
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 120); do
    [ "$(cat "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ] && break
    /bin/sleep 0.05
done
[ "$(cat "$RR_QUARANTINE_READY")" = ready ]
for _ in $(seq 1 40); do
    kill -0 "$GUARD_PID"
    /bin/sleep 0.05
done
[ ! -e "$unsafe_cleanup_callback" ]
[ ! -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ]
[ "$(stat -c %i "$RR_LEGACY_UPDATE_LOCK_FILE")" = "$unsafe_lock_inode" ]
[ "$(stat -c %a "$RR_LEGACY_UPDATE_LOCK_FILE")" = 666 ]
[ -e "$RR_QUARANTINE_READY" ] && [ -e "$RR_QUARANTINE_UNIT" ] && \
    [ -e "$RR_QUARANTINE_GUARD_STATE" ] && [ -e "$RR_QUARANTINE_GUARD_SELF" ]
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
    echo 'Unsafe legacy-lock preoccupation released the state-only guard port.' >&2
    exit 1
fi
kill -TERM "$GUARD_PID"
set +e
wait "$GUARD_PID" 2>/dev/null
guard_signal_status=$?
set -e
GUARD_PID=""
[ "$guard_signal_status" -eq 1 ]
rr_quarantine_remove_firewall_rules() { :; }
rr_quarantine_remove_orphan_firewall_rules() { :; }

printf '%s\n' '[13/20] quarantine replacement preserves the old barrier on stop or staging failure'
(
    reset_case
    unsafe_ancestor="$TEST_ROOT/unsafe-quarantine-ancestor"
    mkdir -p "$unsafe_ancestor"
    chmod 0777 "$unsafe_ancestor"
    RR_QUARANTINE_GUARD_SELF="$unsafe_ancestor/guard/subscription-quarantine-guard"
    if rr_test_production_install_guard_self; then
        echo 'A guard helper below a non-sticky writable ancestor was installed.' >&2
        exit 1
    fi
    RR_QUARANTINE_GUARD_STATE="$unsafe_ancestor/state/guard-state"
    rr_quarantine_write_marker quarantined 7.1.0 18081
    if rr_quarantine_sync_guard_state; then
        echo 'Guard state below a non-sticky writable ancestor was published.' >&2
        exit 1
    fi
    RR_QUARANTINE_UNIT="$unsafe_ancestor/systemd/rr-subscription-quarantine.service"
    if rr_quarantine_write_unit; then
        echo 'A quarantine unit below a non-sticky writable ancestor was published.' >&2
        exit 1
    fi
)
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
: > "$FIREWALL_LOG"
: > "$RR_TEST_QUARANTINE_STOP_FAIL"
if rr_activate_subscription_quarantine 7.0.9 19091 1 >/dev/null 2>&1; then
    echo 'Quarantine replacement accepted a failed guard stop.' >&2
    exit 1
fi
rr_quarantine_marker_read
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ]
[ "$RR_QUARANTINE_PORT" = 18081 ]
[ -e "$RR_QUARANTINE_READY" ]
if grep -Fq 'delete:18081' "$FIREWALL_LOG"; then
    echo 'Failed guard stop removed the old firewall barrier.' >&2
    exit 1
fi

reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
: > "$RR_TEST_QUARANTINE_ENABLED"
: > "$RR_TEST_QUARANTINE_QUERY_FAIL"
old_guard_sha=$(sha256sum "$RR_QUARANTINE_GUARD_SELF" | awk '{print $1}')
: > "$FIREWALL_LOG"
if rr_activate_subscription_quarantine 7.0.9 19091 1 >/dev/null 2>&1; then
    echo 'Quarantine replacement accepted an unprovable stopped state.' >&2
    exit 1
fi
[ "$(sha256sum "$RR_QUARANTINE_GUARD_SELF" | awk '{print $1}')" = "$old_guard_sha" ]
[ -e "$RR_QUARANTINE_READY" ] && [ -e "$RR_QUARANTINE_GUARD_STATE" ] && \
    [ -e "$RR_QUARANTINE_UNIT" ]
if grep -Fq 'delete:18081' "$FIREWALL_LOG"; then
    echo 'Guard state query failure removed the old firewall barrier.' >&2
    exit 1
fi

reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
: > "$FIREWALL_LOG"
rr_quarantine_install_guard_self() { return 1; }
if rr_activate_subscription_quarantine 7.0.9 19091 1 >/dev/null 2>&1; then
    echo 'Quarantine replacement accepted a guard staging failure.' >&2
    exit 1
fi
rr_quarantine_marker_read
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ]
[ "$RR_QUARANTINE_PORT" = 18081 ]
rr_quarantine_guard_state_read
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ]
[ "$RR_QUARANTINE_PORT" = 18081 ]
if grep -Fq 'delete:18081' "$FIREWALL_LOG"; then
    echo 'Guard staging failure removed the old firewall barrier.' >&2
    exit 1
fi
rr_quarantine_install_guard_self() { rr_test_production_install_guard_self "$@"; }

reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
printf 'legacy quarantine unit\n' > "$RR_QUARANTINE_UNIT"
(umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
: > "$RR_TEST_QUARANTINE_ENABLED"
: > "$SYSTEMCTL_LOG"
rr_quarantine_add_firewall_rules() { printf 'failed-add:%s\n' "$1" >> "$FIREWALL_LOG"; return 1; }
if rr_activate_subscription_quarantine 7.0.9 19091 1 >/dev/null 2>&1; then
    echo 'Quarantine replacement accepted a failed pre-handoff DROP.' >&2
    exit 1
fi
rr_quarantine_marker_read
[ "$RR_QUARANTINE_VERSION" = 7.1.0 ] && [ "$RR_QUARANTINE_PORT" = 18081 ]
[ -e "$RR_QUARANTINE_READY" ]
if grep -Fq 'stop rr-subscription-quarantine.service' "$SYSTEMCTL_LOG"; then
    echo 'Failed pre-handoff DROP stopped the old guard.' >&2
    exit 1
fi
rr_quarantine_add_firewall_rules() { printf 'add:%s\n' "$1" >> "$FIREWALL_LOG"; }

printf '%s\n' '[14/20] a ready file without persistent unit or firewall is not a barrier'
(
    reset_case
    systemctl() {
        case "$*" in
            "daemon-reload") return 0 ;;
            "enable --now rr-subscription-quarantine.service")
                mkdir -p "$(dirname "$RR_QUARANTINE_READY")"
                (umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
                return 1
                ;;
            "is-active --quiet rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_READY" ]; return ;;
            "is-enabled --quiet rr-subscription-quarantine.service") return 1 ;;
            "show -p LoadState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n' ;;
            "show -p ActiveState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_READY" ] && printf 'active\n' || printf 'inactive\n' ;;
            "show -p UnitFileState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'disabled\n' || : ;;
        esac
        return 0
    }
    rr_stop_subscription_servers() { :; }
    rr_quarantine_add_firewall_rules() { return 1; }
    if rr_activate_subscription_quarantine 7.1.0 19092 1 >/dev/null 2>&1; then
        echo 'A volatile ready file with no reboot-safe barrier was accepted.' >&2
        exit 1
    fi
    rr_quarantine_marker_read
    [ "$RR_QUARANTINE_STATE" = degraded ]
)

printf '%s\n' '[15/20] reusable guards have no gap and port changes use a DROP handoff'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081 0
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
rr_quarantine_write_unit
(umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
: > "$RR_TEST_QUARANTINE_ENABLED"
: > "$SYSTEMCTL_LOG"
: > "$FIREWALL_LOG"
rr_quarantine_firewall_inventory_is_exact() { [ "$1" = 18081 ]; }
ready_inode=$(stat -c %i "$RR_QUARANTINE_READY")
unit_digest=$(sha256sum "$RR_QUARANTINE_UNIT")
guard_digest=$(sha256sum "$RR_QUARANTINE_GUARD_SELF")
[ "$(stat -c '%u:%g:%a:%h' "$RR_RECOVERY_SELF")" = 0:0:755:1 ]
[ "$(stat -c '%u:%g:%a:%h' "$RR_QUARANTINE_GUARD_SELF")" = 0:0:700:1 ]
rr_quarantine_guard_helper_is_current || {
    echo 'The valid production 0755 recovery helper was rejected by its 0700 guard copy.' >&2
    exit 1
}
chmod 0777 "$(dirname "$RR_QUARANTINE_GUARD_SELF")"
if rr_quarantine_guard_helper_is_current; then
    echo 'A reusable guard below a non-sticky writable ancestor was trusted.' >&2
    exit 1
fi
chmod 0700 "$(dirname "$RR_QUARANTINE_GUARD_SELF")"
cp -- "$RR_QUARANTINE_UNIT" "$TEST_ROOT/strict-unit.saved"
printf 'tampered\n' >> "$RR_QUARANTINE_UNIT"
if rr_quarantine_existing_guard_is_reusable 18081; then
    echo 'A guard with tampered unit content was reused.' >&2
    exit 1
fi
mv -f -- "$TEST_ROOT/strict-unit.saved" "$RR_QUARANTINE_UNIT"
chmod 0600 "$RR_QUARANTINE_UNIT"
if rr_quarantine_existing_guard_is_reusable 18081; then
    echo 'A guard with unsafe unit metadata was reused.' >&2
    exit 1
fi
chmod 0644 "$RR_QUARANTINE_UNIT"
RR_TEST_QUARANTINE_FRAGMENT_PATH="$TEST_ROOT/foreign.service"
if rr_quarantine_existing_guard_is_reusable 18081; then
    echo 'A guard loaded from a foreign systemd fragment was reused.' >&2
    exit 1
fi
RR_TEST_QUARANTINE_FRAGMENT_PATH=""
RR_TEST_QUARANTINE_DROP_IN_PATHS="$TEST_ROOT/override.conf"
if rr_quarantine_existing_guard_is_reusable 18081; then
    echo 'A guard with a systemd drop-in override was reused.' >&2
    exit 1
fi
RR_TEST_QUARANTINE_DROP_IN_PATHS=""
rr_activate_subscription_quarantine 7.0.9 18081 1
[ "$(stat -c %i "$RR_QUARANTINE_READY")" = "$ready_inode" ]
[ "$(sha256sum "$RR_QUARANTINE_UNIT")" = "$unit_digest" ]
[ "$(sha256sum "$RR_QUARANTINE_GUARD_SELF")" = "$guard_digest" ]
if grep -Eq '(^| )(stop|enable --now|daemon-reload)( |$)' "$SYSTEMCTL_LOG"; then
    echo 'Reusable same-port guard was unnecessarily restarted.' >&2
    exit 1
fi
[ ! -s "$FIREWALL_LOG" ] || {
    echo 'Reusable same-port guard unnecessarily changed firewall state.' >&2
    exit 1
}
rr_quarantine_marker_read
[ "$RR_QUARANTINE_VERSION" = 7.0.9 ] && [ "$RR_QUARANTINE_PORT" = 18081 ] &&
    [ "$RR_QUARANTINE_RESUME" = 1 ]
cmp -s "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_GUARD_STATE"

reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_test_production_install_guard_self
rr_quarantine_sync_guard_state
rr_quarantine_write_unit
(umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
: > "$RR_TEST_QUARANTINE_ENABLED"
rm -f -- "$RR_QUARANTINE_FILE"
: > "$FIREWALL_LOG"
rr_quarantine_add_firewall_rules() { printf 'add:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_quarantine_remove_firewall_rules() { printf 'delete:%s\n' "$1" >> "$FIREWALL_LOG"; }
rr_activate_subscription_quarantine 7.1.0 19093 1
rr_quarantine_marker_read
[ "$RR_QUARANTINE_PORT" = 19093 ]
grep -Fxq 'add:18081' "$FIREWALL_LOG"
grep -Fxq 'add:19093' "$FIREWALL_LOG"
grep -Fxq 'delete:18081' "$FIREWALL_LOG"

printf '%s\n' '[16/20] runtime-only unit enablement is never accepted as a persistent guard'
(
    reset_case
    rr_quarantine_write_marker quarantined 7.1.0 18081
    rr_test_production_install_guard_self
    rr_quarantine_sync_guard_state
    rr_quarantine_write_unit
    (umask 077; printf 'ready\n' > "$RR_QUARANTINE_READY")
    : > "$RR_TEST_QUARANTINE_ENABLED"
    RR_TEST_QUARANTINE_UNIT_FILE_STATE=enabled-runtime
    if rr_quarantine_existing_guard_is_reusable; then
        echo 'Runtime-only unit enablement was accepted as a reboot-persistent guard.' >&2
        exit 1
    fi
    if rr_activate_subscription_quarantine 7.0.9 18081 1 >/dev/null 2>&1; then
        echo 'Activation accepted a guard that disappears on reboot.' >&2
        exit 1
    fi
    rr_quarantine_marker_read
    [ "$RR_QUARANTINE_STATE" = degraded ]
    [ -e "$RR_QUARANTINE_GUARD_STATE" ] && [ -e "$RR_QUARANTINE_GUARD_SELF" ]
)

printf '%s\n' '[17/20] a transient firewall-only barrier never replaces the persistent guard'
(
    reset_case
    systemctl() {
        case "$*" in
            "daemon-reload") return 0 ;;
            "enable --now rr-subscription-quarantine.service") return 1 ;;
            "is-active --quiet rr-subscription-quarantine.service"|\
            "is-enabled --quiet rr-subscription-quarantine.service") return 1 ;;
            "show -p LoadState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n' ;;
            "show -p ActiveState --value rr-subscription-quarantine.service") printf 'inactive\n' ;;
            "show -p UnitFileState --value rr-subscription-quarantine.service")
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'disabled\n' || : ;;
        esac
        return 0
    }
    rr_stop_subscription_servers() { :; }
    rr_quarantine_add_firewall_rules() { printf 'firewall-only:%s\n' "$1" >> "$FIREWALL_LOG"; }
    if rr_activate_subscription_quarantine 7.1.0 19094 1 >/dev/null 2>&1; then
        echo 'A transient firewall rule was accepted without an active, enabled, ready guard.' >&2
        exit 1
    fi
    grep -Fxq 'firewall-only:19094' "$FIREWALL_LOG"
    rr_quarantine_marker_read
    [ "$RR_QUARANTINE_STATE" = degraded ]
)

printf '%s\n' '[18/20] markerless raw-table evidence is visible and blocks replacement'
(
    reset_case
    rm -f -- "$RR_ACTIVE_TX"
    iptables() {
        case "$*" in
            "-w 5 -t raw -S PREROUTING")
                printf '%s\n' '-A PREROUTING ! -i lo -p tcp -m tcp --dport 19995 -m addrtype --dst-type LOCAL -m comment --comment "rr-vps unsafe rollback subscription quarantine" -j DROP'
                ;;
            *) return 0 ;;
        esac
    }
    status_json=$(main status)
    python3 - "$status_json" <<'PY'
import json, sys
status = json.loads(sys.argv[1])
assert status["subscription_quarantine"] == {
    "active": True, "state": "invalid", "target_version": "unknown", "port": 0,
    "resume_subscription": 0,
}
PY
    if rr_activate_subscription_quarantine 7.1.0 19996 1 >/dev/null 2>&1; then
        echo 'Activation ignored a markerless raw-table quarantine rule.' >&2
        exit 1
    fi
    [ ! -e "$RR_QUARANTINE_FILE" ] && [ ! -e "$RR_QUARANTINE_GUARD_STATE" ]
    iptables() { return 1; }
    rr_quarantine_artifact_evidence_present || {
        echo 'An unreadable raw table was treated as proof that quarantine is absent.' >&2
        exit 1
    }
)

printf '%s\n' '[19/20] committed boot recovery sweeps markerless raw rules before finalizing'
(
    reset_case
    export RR_UPDATE_LOCK_HELD=1
    export RR_UPDATE_MAINTENANCE_FILE="$TEST_ROOT/raw-only-committed/maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$REPO_ROOT/scripts/update-recover.sh"
    raw_rule="$TEST_ROOT/raw-only-committed/raw-rule"
    finalize_log="$TEST_ROOT/raw-only-committed/finalize.log"
    tx="$RR_TX_ROOT/transactions/raw-only-committed"
    mkdir -p "$tx/backup" "$RR_LIB_DIR/modules" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")" "$(dirname "$RR_LAUNCHER")"
    chmod 700 "$tx" "$tx/backup"
    printf 'SCRIPT_VERSION="7.1.1"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s %s\n" "${RR_UPDATE_LOCK_HELD:-}" "$*" >> "$RR_TEST_FINALIZE_LOG"' > "$RR_LAUNCHER"
    chmod 700 "$RR_LAUNCHER"
    export RR_TEST_FINALIZE_LOG="$finalize_log"
    : > "$raw_rule"
    printf 'committed\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    chmod 600 "$tx/phase" "$RR_ACTIVE_TX" "$RR_UPDATE_MAINTENANCE_FILE"

    systemctl() {
        case "$*" in
            "is-active --quiet rr-subscription-quarantine.service"|\
            "is-enabled --quiet rr-subscription-quarantine.service") return 1 ;;
            "show -p LoadState --value rr-subscription-quarantine.service") printf 'not-found\n' ;;
            "show -p ActiveState --value rr-subscription-quarantine.service") printf 'inactive\n' ;;
            "show -p UnitFileState --value rr-subscription-quarantine.service") : ;;
            *) return 0 ;;
        esac
    }
    rr_stop_subscription_servers() { :; }
    iptables() {
        case "$*" in
            "-w 5 -t raw -S PREROUTING")
                if [ -e "$raw_rule" ]; then
                    printf '%s\n' '-A PREROUTING ! -i lo -p tcp -m tcp --dport 19997 -m addrtype --dst-type LOCAL -m comment --comment "rr-vps unsafe rollback subscription quarantine" -j DROP'
                fi
                ;;
            *" -C PREROUTING "*) [ -e "$raw_rule" ] ;;
            *" -D PREROUTING "*) rm -f -- "$raw_rule" ;;
            *) return 0 ;;
        esac
    }
    main recover
    [ ! -e "$raw_rule" ] || { echo 'Committed recovery left a markerless raw rule.' >&2; exit 1; }
    grep -Fxq '1 --post-update-finalize' "$finalize_log"
    [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || {
        echo 'Committed recovery cleared neither maintenance nor finalization window.' >&2
        exit 1
    }
)

printf '%s\n' '[20/20] long-lived quarantine guard releases inherited recovery flock descriptors'
reset_case
rm -f -- "$RR_ACTIVE_TX"
rr_quarantine_write_marker degraded unknown 0
rr_quarantine_sync_guard_state
: > "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 0600 "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 0700 "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
printf 'rr-legacy-update-bridge-v1\n' > "$RR_LEGACY_UPDATE_BRIDGE_FILE"
chmod 0600 "$RR_LEGACY_UPDATE_BRIDGE_FILE"
RR_UPDATE_LOCK_HELD=0
rr_acquire_update_lock
(rr_quarantine_guard) &
GUARD_PID=$!
for _ in $(seq 1 120); do
    [ "$(cat "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ] && break
    /bin/sleep 0.05
done
[ "$(cat "$RR_QUARANTINE_READY")" = ready ]
kill -0 "$GUARD_PID"
rr_close_inherited_recovery_lock_fds
(
    exec {contender_fd}>>"$RR_UPDATE_LOCK_FILE"
    flock -n "$contender_fd"
) || {
    echo 'Long-lived quarantine guard retained the recovery flock.' >&2
    exit 1
}
(
    exec {legacy_contender_fd}<"$RR_LEGACY_UPDATE_LOCK_FILE"
    flock -n "$legacy_contender_fd"
) || {
    echo 'Long-lived quarantine guard retained the legacy recovery flock.' >&2
    exit 1
}
kill "$GUARD_PID" >/dev/null 2>&1 || true
wait "$GUARD_PID" 2>/dev/null || true
GUARD_PID=""

printf '%s\n' 'rollback quarantine regression: PASS'
