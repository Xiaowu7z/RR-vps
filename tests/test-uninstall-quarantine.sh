#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

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
export RR_UPDATE_EXTERNAL_HELPER="$TEST_ROOT/bin/rr-update-external-state"
export RR_IPV6_STATE_FILE="$TEST_ROOT/no-ipv6"
export RR_UPDATE_LOCK_FILE="$TEST_ROOT/run/rr-update.lock"
export RR_UPDATE_RECOVER_SOURCE_ONLY=1
export RR_TEST_RAW_RULE="$TEST_ROOT/raw-rule"
export RR_TEST_ACTIVE_UNIT="$TEST_ROOT/active-unit"
export RR_TEST_ENABLED_UNIT="$TEST_ROOT/enabled-unit"
export RR_TEST_HELPER_LOG="$TEST_ROOT/helper.log"
export RR_TEST_DELETE_FAIL="$TEST_ROOT/delete-fail"
export RR_TEST_QUERY_FAIL="$TEST_ROOT/query-fail"
export RR_TEST_STOP_FAIL="$TEST_ROOT/stop-fail"
export RR_TEST_DAEMON_FAIL="$TEST_ROOT/daemon-fail"
export RR_TEST_SYSTEMD_QUERY_FAIL="$TEST_ROOT/systemd-query-fail"
export RR_TEST_QUARANTINE_DROPIN="$TEST_ROOT/quarantine-dropin"
export RR_TEST_HEALTH_STOP_FAIL="$TEST_ROOT/health-stop-fail"
export RR_TEST_HEALTH_DISABLE_FAIL="$TEST_ROOT/health-disable-fail"
export RR_TEST_SYNC_FAIL="$TEST_ROOT/sync-fail"
export RR_TEST_SUBSCRIPTION_REMAINS="$TEST_ROOT/subscription-remains"
export RR_TEST_SUBSCRIPTION_STOP_FAIL="$TEST_ROOT/subscription-stop-fail"
export RR_TEST_OPERATION_LOG="$TEST_ROOT/release-operations"
RR_TEST_RECREATE_PATH=""
RR_TEST_HEALTH_LOAD_STATE=loaded
RR_TEST_HEALTH_ACTIVE_STATE=inactive
RR_TEST_HEALTH_UNIT_FILE_STATE=disabled

# shellcheck source=../scripts/update-recover.sh
source "$REPO_ROOT/scripts/update-recover.sh"
# shellcheck source=../modules/95-install.sh
source "$REPO_ROOT/modules/95-install.sh"

RED=""
RESET=""

systemctl() {
    if [ -s "$RR_TEST_OPERATION_LOG" ] || [ -e "$RR_TEST_OPERATION_LOG" ]; then
        printf 'systemctl:%s\n' "$*" >> "$RR_TEST_OPERATION_LOG"
    fi
    case "$*" in
        "show -p LoadState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n'
            return ;;
        "show -p ActiveState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            [ -e "$RR_TEST_ACTIVE_UNIT" ] && printf 'active\n' || printf 'inactive\n'
            return ;;
        "show -p UnitFileState --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            if [ -e "$RR_TEST_ENABLED_UNIT" ]; then
                printf 'enabled\n'
            elif [ -e "$RR_QUARANTINE_UNIT" ]; then
                printf 'disabled\n'
            fi
            return ;;
        "show -p FragmentPath --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            [ ! -e "$RR_QUARANTINE_UNIT" ] || printf '%s\n' "$RR_QUARANTINE_UNIT"
            return ;;
        "show -p DropInPaths --value rr-subscription-quarantine.service")
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            [ ! -e "$RR_TEST_QUARANTINE_DROPIN" ] || \
                printf '%s\n' "$RR_TEST_QUARANTINE_DROPIN"
            return ;;
    esac
    case "${1:-}:${2:-}" in
        is-active:--quiet) [ -e "$RR_TEST_ACTIVE_UNIT" ] ;;
        is-enabled:--quiet) [ -e "$RR_TEST_ENABLED_UNIT" ] ;;
        disable:--now)
            rm -f -- "$RR_TEST_ACTIVE_UNIT" "$RR_TEST_ENABLED_UNIT"
            ;;
        disable:argo-rr-health.timer|disable:argo-rr-health.service)
            [ ! -e "$RR_TEST_HEALTH_DISABLE_FAIL" ]
            ;;
        stop:argo-rr-health.timer|stop:argo-rr-health.service)
            [ ! -e "$RR_TEST_HEALTH_STOP_FAIL" ]
            ;;
        stop:rr-subscription-quarantine.service)
            [ ! -e "$RR_TEST_STOP_FAIL" ] || return 1
            rm -f -- "$RR_TEST_ACTIVE_UNIT"
            ;;
        daemon-reload:*) [ ! -e "$RR_TEST_DAEMON_FAIL" ] ;;
        show:--property=LoadState)
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            if [ "${4:-}" = rr-subscription-quarantine.service ]; then
                [ -e "$RR_QUARANTINE_UNIT" ] && printf 'loaded\n' || printf 'not-found\n'
            else
                printf '%s\n' "$RR_TEST_HEALTH_LOAD_STATE"
            fi
            ;;
        show:--property=ActiveState)
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            if [ "${4:-}" = rr-subscription-quarantine.service ]; then
                [ -e "$RR_TEST_ACTIVE_UNIT" ] && printf 'active\n' || printf 'inactive\n'
            else
                printf '%s\n' "$RR_TEST_HEALTH_ACTIVE_STATE"
            fi
            ;;
        show:--property=UnitFileState)
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            if [ "${4:-}" = rr-subscription-quarantine.service ]; then
                if [ -e "$RR_TEST_ENABLED_UNIT" ]; then
                    printf 'enabled\n'
                elif [ -e "$RR_QUARANTINE_UNIT" ]; then
                    printf 'disabled\n'
                fi
            else
                printf '%s\n' "$RR_TEST_HEALTH_UNIT_FILE_STATE"
            fi
            ;;
        *) return 0 ;;
    esac
}

sync() {
    printf 'sync:%s\n' "$*" >> "$RR_TEST_OPERATION_LOG"
    [ ! -e "$RR_TEST_SYNC_FAIL" ]
}

stop_subscription_servers() {
    printf '%s\n' stop-subscription >> "$RR_TEST_OPERATION_LOG"
    [ -z "$RR_TEST_RECREATE_PATH" ] || : > "$RR_TEST_RECREATE_PATH"
    [ ! -e "$RR_TEST_SUBSCRIPTION_STOP_FAIL" ]
}

subscription_server_running() {
    printf '%s\n' probe-subscription >> "$RR_TEST_OPERATION_LOG"
    [ -e "$RR_TEST_SUBSCRIPTION_REMAINS" ]
}

iptables() {
    case " $* " in
        *" -S PREROUTING "*)
            [ ! -e "$RR_TEST_QUERY_FAIL" ] || return 1
            if [ -e "$RR_TEST_RAW_RULE" ]; then
                if [ "$(cat "$RR_TEST_RAW_RULE" 2>/dev/null)" = foreign ]; then
                    printf '%s\n' '-A PREROUTING -p udp --dport 18081 -m comment --comment "rr-vps unsafe rollback subscription quarantine" -j ACCEPT'
                else
                    printf '%s\n' '-A PREROUTING ! -i lo -p tcp -m tcp --dport 18081 -m addrtype --dst-type LOCAL -m comment --comment "rr-vps unsafe rollback subscription quarantine" -j DROP'
                fi
            fi
            ;;
        *" -C PREROUTING "*)
            [ -e "$RR_TEST_RAW_RULE" ] &&
                [ "$(cat "$RR_TEST_RAW_RULE" 2>/dev/null)" != foreign ]
            ;;
        *" -D PREROUTING "*)
            [ ! -e "$RR_TEST_DELETE_FAIL" ] || return 1
            rm -f -- "$RR_TEST_RAW_RULE"
            ;;
        *" -I PREROUTING "*)
            : > "$RR_TEST_RAW_RULE"
            ;;
        *) return 1 ;;
    esac
}

ip6tables() {
    case " $* " in
        *" -S PREROUTING "*) return 0 ;;
        *) return 1 ;;
    esac
}

reset_case() {
    rm -rf -- "$RR_TX_ROOT" "$(dirname "$RR_QUARANTINE_UNIT")" \
        "$(dirname "$RR_QUARANTINE_READY")" "$(dirname "$RR_RECOVERY_SELF")" \
        "$(dirname "$RR_QUARANTINE_GUARD_STATE")" \
        "$(dirname "$RR_QUARANTINE_GUARD_SELF")" "$RR_LIB_DIR"
    rm -f -- "$RR_LAUNCHER"
    rm -f -- "$RR_TEST_RAW_RULE" "$RR_TEST_ACTIVE_UNIT" \
        "$RR_TEST_ENABLED_UNIT" "$RR_TEST_HELPER_LOG" "$RR_TEST_DELETE_FAIL" \
        "$RR_TEST_QUERY_FAIL" "$RR_TEST_STOP_FAIL"
    rm -f -- "$RR_TEST_DAEMON_FAIL"
    rm -f -- "$RR_TEST_SYSTEMD_QUERY_FAIL"
    rm -f -- "$RR_TEST_QUARANTINE_DROPIN"
    rm -f -- "$RR_TEST_SYNC_FAIL" "$RR_TEST_SUBSCRIPTION_REMAINS" \
        "$RR_TEST_SUBSCRIPTION_STOP_FAIL" "$RR_TEST_OPERATION_LOG"
    RR_TEST_RECREATE_PATH=""
    RR_UNINSTALL_RECOVERY_HELPER_SHA256=""
    RR_UNINSTALL_EXTERNAL_HELPER_SHA256=""
    RR_UNINSTALL_RUNTIME_MANIFEST_SHA256=""
    RR_UNINSTALL_UPDATE_GUARD_SHA256=""
    RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED=false
    mkdir -p -- "$RR_TX_ROOT" "$(dirname "$RR_QUARANTINE_UNIT")" \
        "$(dirname "$RR_QUARANTINE_READY")" "$(dirname "$RR_RECOVERY_SELF")"
    chmod 700 -- "$(dirname "$RR_RECOVERY_SELF")"
}

write_runtime_manifest() {
    local relative="" target="" digest=""
    local -a relative_paths=(
        rr
        scripts/naive-cert-hook.sh
        scripts/update-recover.sh
        scripts/update-external-state.py
        modules/00-runtime.sh
        modules/95-install.sh
        nexus/rr_nexus.py
        nexus/rr_nexus_lib/security.py
        nexus/sub_server.py
        nexus/static/index.html
        nexus/static/app.css
        nexus/static/app.js
    )
    : > "$RR_LIB_DIR/manifest.sha256"
    for relative in "${relative_paths[@]}"; do
        if [ "$relative" = rr ]; then
            target="$RR_LAUNCHER"
        else
            target="$RR_LIB_DIR/$relative"
        fi
        digest=$(sha256sum -- "$target" | awk '{print $1}')
        printf '%s  %s\n' "$digest" "$relative" >> "$RR_LIB_DIR/manifest.sha256"
    done
    chmod 644 "$RR_LIB_DIR/manifest.sha256"
}

write_runtime_fixture() {
    local helper_mode="$1" path=""
    mkdir -p -- "$RR_LIB_DIR/scripts" "$RR_LIB_DIR/modules" \
        "$RR_LIB_DIR/nexus/rr_nexus_lib" "$RR_LIB_DIR/nexus/static" \
        "$(dirname "$RR_LAUNCHER")"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$RR_LAUNCHER"
    printf '%s\n' '#!/bin/bash' 'exit 0' > \
        "$RR_LIB_DIR/scripts/naive-cert-hook.sh"
    cat > "$RR_LIB_DIR/scripts/update-recover.sh" <<'HELPER'
#!/bin/bash
set -u
[ "${1:-}" = clear-quarantine ] || exit 2
printf '%s\n' "$1" >> "$RR_TEST_HELPER_LOG"
[ -z "${RR_TEST_OPERATION_LOG:-}" ] || printf '%s\n' clear-quarantine >> "$RR_TEST_OPERATION_LOG"
case "$RR_TEST_HELPER_MODE" in
    success)
        rm -f -- "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
            "$RR_QUARANTINE_READY" "$RR_QUARANTINE_GUARD_STATE" \
            "$RR_QUARANTINE_GUARD_SELF" "$RR_TEST_RAW_RULE" \
            "$RR_TEST_ACTIVE_UNIT" "$RR_TEST_ENABLED_UNIT"
        ;;
    partial)
        rm -f -- "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
            "$RR_QUARANTINE_READY" "$RR_QUARANTINE_GUARD_STATE" \
            "$RR_QUARANTINE_GUARD_SELF" "$RR_TEST_ACTIVE_UNIT" \
            "$RR_TEST_ENABLED_UNIT"
        ;;
    fail) exit 1 ;;
    *) exit 2 ;;
esac
HELPER
    printf '%s\n' '#!/usr/bin/env python3' 'raise SystemExit(0)' > \
        "$RR_LIB_DIR/scripts/update-external-state.py"
    printf '%s\n' '# runtime fixture' > "$RR_LIB_DIR/modules/00-runtime.sh"
    printf '%s\n' '# uninstall fixture' > "$RR_LIB_DIR/modules/95-install.sh"
    printf '%s\n' '# nexus fixture' > "$RR_LIB_DIR/nexus/rr_nexus.py"
    printf '%s\n' '# security fixture' > \
        "$RR_LIB_DIR/nexus/rr_nexus_lib/security.py"
    printf '%s\n' '# subscription fixture' > "$RR_LIB_DIR/nexus/sub_server.py"
    printf '%s\n' '<main>fixture</main>' > "$RR_LIB_DIR/nexus/static/index.html"
    printf '%s\n' 'body{}' > "$RR_LIB_DIR/nexus/static/app.css"
    printf '%s\n' 'void 0;' > "$RR_LIB_DIR/nexus/static/app.js"
    chmod 755 "$RR_LAUNCHER" "$RR_LIB_DIR/scripts/naive-cert-hook.sh" \
        "$RR_LIB_DIR/scripts/update-recover.sh" \
        "$RR_LIB_DIR/scripts/update-external-state.py" \
        "$RR_LIB_DIR/nexus/rr_nexus.py" \
        "$RR_LIB_DIR/nexus/rr_nexus_lib/security.py" \
        "$RR_LIB_DIR/nexus/sub_server.py"
    chmod 644 "$RR_LIB_DIR/modules/00-runtime.sh" \
        "$RR_LIB_DIR/modules/95-install.sh" "$RR_LIB_DIR/nexus/static/index.html" \
        "$RR_LIB_DIR/nexus/static/app.css" "$RR_LIB_DIR/nexus/static/app.js"
    write_runtime_manifest
    install -m 755 "$RR_LIB_DIR/scripts/update-recover.sh" "$RR_RECOVERY_SELF"
    install -m 755 "$RR_LIB_DIR/scripts/update-external-state.py" \
        "$RR_UPDATE_EXTERNAL_HELPER"
    export RR_TEST_HELPER_MODE="$helper_mode"
}

capture_and_remove_runtime() {
    rr_uninstall_capture_runtime_ownership
    rm -rf -- "$RR_LIB_DIR"
    rm -f -- "$RR_LAUNCHER"
}

write_helper() {
    local mode="$1"
    write_runtime_fixture "$mode"
}

printf '%s\n' '[1/27] an absent quarantine needs no recovery helper'
reset_case
_uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"
[ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[2/27] a marker or symlink fails closed without a trusted helper'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'Quarantine was ignored without a recovery helper.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
rm -f -- "$RR_QUARANTINE_FILE"
ln -s "$TEST_ROOT/attacker-target" "$RR_QUARANTINE_FILE"
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'A symlink quarantine marker was ignored.' >&2
    exit 1
fi

printf '%s\n' '[3/27] unsafe helpers and writable ancestors are rejected'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
write_helper success
chmod 722 -- "$RR_RECOVERY_SELF"
if _uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"; then
    echo 'A group/other-writable recovery helper was trusted.' >&2
    exit 1
fi
chmod 755 -- "$RR_RECOVERY_SELF"
ln "$RR_RECOVERY_SELF" "$TEST_ROOT/recovery-hardlink"
if _uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"; then
    echo 'A multiply linked recovery helper was trusted.' >&2
    exit 1
fi
rm -f -- "$TEST_ROOT/recovery-hardlink"
mv "$RR_RECOVERY_SELF" "$RR_RECOVERY_SELF.real"
ln -s "$RR_RECOVERY_SELF.real" "$RR_RECOVERY_SELF"
if _uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"; then
    echo 'A symlink recovery helper was trusted.' >&2
    exit 1
fi
[ ! -e "$RR_TEST_HELPER_LOG" ]
rm -f -- "$RR_RECOVERY_SELF" "$RR_RECOVERY_SELF.real"
unsafe_parent="$TEST_ROOT/unsafe-parent"
mkdir -p -- "$unsafe_parent/helper-dir"
chmod 777 -- "$unsafe_parent"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$unsafe_parent/helper-dir/recover"
chmod 700 -- "$unsafe_parent/helper-dir"
chmod 755 -- "$unsafe_parent/helper-dir/recover"
if _uninstall_recovery_helper_is_trusted "$unsafe_parent/helper-dir/recover"; then
    echo 'A recovery helper below an unsafe ancestor was trusted.' >&2
    exit 1
fi

printf '%s\n' '[4/27] helper failure preserves quarantine evidence'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper fail
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'A failing recovery helper was accepted.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
[ "$(cat "$RR_TEST_HELPER_LOG")" = clear-quarantine ]

printf '%s\n' '[5/27] post-clear residue prevents destructive uninstall continuation'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
: > "$RR_TEST_RAW_RULE"
write_helper partial
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'Residual quarantine firewall state was accepted.' >&2
    exit 1
fi
[ -e "$RR_TEST_RAW_RULE" ]

printf '%s\n' '[6/27] a trusted helper must remove every quarantine artifact'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_uninstall_render_subscription_quarantine_unit > "$RR_QUARANTINE_UNIT"
chmod 644 "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
chmod 600 "$RR_QUARANTINE_READY"
: > "$RR_TEST_RAW_RULE"
: > "$RR_TEST_ACTIVE_UNIT"
: > "$RR_TEST_ENABLED_UNIT"
write_helper success
_uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"
if _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'A trusted helper left quarantine evidence behind.' >&2
    exit 1
fi

printf '%s\n' '[7/27] markerless exact RR firewall residue is discovered and removed'
reset_case
: > "$RR_TEST_RAW_RULE"
_uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"
rr_clear_subscription_quarantine
[ ! -e "$RR_TEST_RAW_RULE" ]
if _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'A fully cleared quarantine was still reported as present.' >&2
    exit 1
fi

printf '%s\n' '[8/27] firewall deletion failure remains visible and fails closed'
reset_case
printf 'unit\n' > "$RR_QUARANTINE_UNIT"
: > "$RR_TEST_RAW_RULE"
: > "$RR_TEST_DELETE_FAIL"
if rr_clear_subscription_quarantine >/dev/null 2>&1; then
    echo 'Firewall deletion failure was accepted.' >&2
    exit 1
fi
[ -e "$RR_TEST_RAW_RULE" ]
if ! _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'Firewall cleanup failure lost all retry evidence.' >&2
    exit 1
fi

printf '%s\n' '[9/27] a foreign same-comment rule is never broadened into deletion'
reset_case
printf 'unit\n' > "$RR_QUARANTINE_UNIT"
printf 'foreign\n' > "$RR_TEST_RAW_RULE"
if rr_clear_subscription_quarantine >/dev/null 2>&1; then
    echo 'A foreign same-comment firewall rule was treated as clean.' >&2
    exit 1
fi
[ "$(cat "$RR_TEST_RAW_RULE")" = foreign ]
[ -e "$RR_QUARANTINE_UNIT" ]

printf '%s\n' '[10/27] unreadable firewall or systemd state is quarantine evidence'
reset_case
: > "$RR_TEST_QUERY_FAIL"
if ! _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'An unreadable raw firewall table was treated as clean.' >&2
    exit 1
fi
reset_case
: > "$RR_TEST_SYSTEMD_QUERY_FAIL"
if ! _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'A systemd query failure with no visible files was treated as clean.' >&2
    exit 1
fi

printf '%s\n' '[11/27] direct suspend and clear commands respect the shared update lock'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE"
exec {held_update_fd}>>"$RR_UPDATE_LOCK_FILE"
flock -n "$held_update_fd"
if main suspend-quarantine >/dev/null 2>&1; then
    echo 'Direct quarantine suspend bypassed the shared update lock.' >&2
    exit 1
fi
if main clear-quarantine >/dev/null 2>&1; then
    echo 'Direct quarantine clear bypassed the shared update lock.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
exec {held_update_fd}>&-

printf '%s\n' '[12/27] suspend failure retains marker and readiness evidence'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
printf 'ready\n' > "$RR_QUARANTINE_READY"
: > "$RR_TEST_ACTIVE_UNIT"
: > "$RR_TEST_STOP_FAIL"
if rr_suspend_subscription_quarantine >/dev/null 2>&1; then
    echo 'A failed quarantine service stop was accepted.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
[ -e "$RR_QUARANTINE_READY" ]
[ -e "$RR_TEST_ACTIVE_UNIT" ]

printf '%s\n' '[13/27] pre-firewall finalization failure retains the exact barrier'
reset_case
rr_quarantine_write_marker quarantined 7.1.0 18081
printf 'unit\n' > "$RR_QUARANTINE_UNIT"
: > "$RR_TEST_RAW_RULE"
: > "$RR_TEST_DAEMON_FAIL"
if rr_clear_subscription_quarantine >/dev/null 2>&1; then
    echo 'A daemon-reload failure was accepted before firewall removal.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
[ -e "$RR_TEST_RAW_RULE" ]
if ! _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'Post-finalization failure lost all quarantine evidence.' >&2
    exit 1
fi

printf '%s\n' '[14/27] existing legacy locks are validated, contended and never recreated'
legacy_root="$TEST_ROOT/legacy-locks"
mkdir -p -- "$legacy_root"
chmod 700 -- "$legacy_root"
legacy_lock="$legacy_root/rr-update.lock"
: > "$legacy_lock"
chmod 0644 -- "$legacy_lock"
legacy_fd=""
_uninstall_acquire_existing_legacy_lock "$legacy_lock" legacy_fd
[ -n "$legacy_fd" ]
exec {legacy_contender_fd}>>"$legacy_lock"
if flock -n "$legacy_contender_fd"; then
    echo 'Legacy lock helper did not retain its acquired flock.' >&2
    exit 1
fi
exec {legacy_contender_fd}>&-
exec {legacy_fd}>&-
exec {legacy_contender_fd}>>"$legacy_lock"
flock -n "$legacy_contender_fd"
exec {legacy_contender_fd}>&-

exec {legacy_holder_fd}>>"$legacy_lock"
flock -n "$legacy_holder_fd"
legacy_fd=""
if _uninstall_acquire_existing_legacy_lock "$legacy_lock" legacy_fd; then
    echo 'Legacy lock helper ignored a busy 7.1.0 transaction.' >&2
    exit 1
fi
[ -z "$legacy_fd" ]
exec {legacy_holder_fd}>&-
absent_legacy="$legacy_root/absent.lock"
_uninstall_acquire_existing_legacy_lock "$absent_legacy" legacy_fd
[ -z "$legacy_fd" ]
[ ! -e "$absent_legacy" ]

printf '%s\n' '[15/27] health-unit proof rejects query, stop, disable and ambiguous states'
health_systemd_root="$TEST_ROOT/health-systemd"
RR_RESTORE_SYSTEMD_DIR="$health_systemd_root"
mkdir -p "$health_systemd_root"
: > "$health_systemd_root/argo-rr-health.timer"
_uninstall_health_unit_is_safely_stopped argo-rr-health.timer
: > "$RR_TEST_SYSTEMD_QUERY_FAIL"
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'A systemd bus/query failure was accepted as a stopped health unit.' >&2
    exit 1
fi
rm -f "$RR_TEST_SYSTEMD_QUERY_FAIL"
RR_TEST_HEALTH_ACTIVE_STATE=activating
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'An ambiguous health ActiveState was accepted.' >&2
    exit 1
fi
RR_TEST_HEALTH_ACTIVE_STATE=inactive
RR_TEST_HEALTH_UNIT_FILE_STATE=enabled
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'An enabled health unit was accepted before quarantine release.' >&2
    exit 1
fi
RR_TEST_HEALTH_UNIT_FILE_STATE=disabled
: > "$RR_TEST_HEALTH_STOP_FAIL"
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'A stop failure for an installed health unit was ignored.' >&2
    exit 1
fi
rm -f "$RR_TEST_HEALTH_STOP_FAIL"
: > "$RR_TEST_HEALTH_DISABLE_FAIL"
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'A disable failure for an installed health unit was ignored.' >&2
    exit 1
fi
rm -f "$RR_TEST_HEALTH_DISABLE_FAIL"
RR_TEST_HEALTH_ACTIVE_STATE=failed
RR_TEST_HEALTH_UNIT_FILE_STATE=static
_uninstall_health_unit_is_safely_stopped argo-rr-health.timer
RR_TEST_HEALTH_LOAD_STATE=error
if _uninstall_health_unit_is_safely_stopped argo-rr-health.timer; then
    echo 'An unknown health LoadState was accepted before quarantine release.' >&2
    exit 1
fi
RR_TEST_HEALTH_LOAD_STATE=loaded

printf '%s\n' '[16/27] a failed global durability barrier retains quarantine'
reset_case
release_systemd_root="$TEST_ROOT/release-systemd"
release_restart_helper="$TEST_ROOT/release-auto-update-sub.py"
mkdir -p "$release_systemd_root"
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper success
capture_and_remove_runtime
: > "$RR_TEST_SYNC_FAIL"
if _uninstall_release_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
    "$RR_QUARANTINE_READY" "$RR_LIB_DIR" "$RR_LAUNCHER" \
    "$release_systemd_root" "$release_restart_helper" >/dev/null 2>&1; then
    echo 'A failed global sync released quarantine.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ] && [ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[17/27] every runtime and health restart path must be absent'
reset_case
mkdir -p "$release_systemd_root"
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper success
capture_and_remove_runtime
ln -s "$TEST_ROOT/missing-health-target" "$release_systemd_root/argo-rr-health.timer"
if _uninstall_release_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
    "$RR_QUARANTINE_READY" "$RR_LIB_DIR" "$RR_LAUNCHER" \
    "$release_systemd_root" "$release_restart_helper" >/dev/null 2>&1; then
    echo 'A symlink health restart path was treated as absent.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ] && [ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[18/27] a surviving subscription process retains quarantine'
reset_case
rm -rf -- "$release_systemd_root"
mkdir -p "$release_systemd_root"
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper success
capture_and_remove_runtime
: > "$RR_TEST_SUBSCRIPTION_REMAINS"
if _uninstall_release_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
    "$RR_QUARANTINE_READY" "$RR_LIB_DIR" "$RR_LAUNCHER" \
    "$release_systemd_root" "$release_restart_helper" >/dev/null 2>&1; then
    echo 'A surviving subscription process released quarantine.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ] && [ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[19/27] restart paths are rechecked after process shutdown'
reset_case
rm -rf -- "$release_systemd_root"
mkdir -p "$release_systemd_root"
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper success
capture_and_remove_runtime
RR_TEST_RECREATE_PATH="$release_restart_helper"
if _uninstall_release_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
    "$RR_QUARANTINE_READY" "$RR_LIB_DIR" "$RR_LAUNCHER" \
    "$release_systemd_root" "$release_restart_helper" >/dev/null 2>&1; then
    echo 'A restart helper recreated during shutdown released quarantine.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ] && [ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[20/27] the durable release gate clears only after every proof succeeds'
reset_case
rm -rf -- "$release_systemd_root"
rm -f -- "$release_restart_helper"
mkdir -p "$release_systemd_root"
rr_quarantine_write_marker quarantined 7.1.0 18081
write_helper success
capture_and_remove_runtime
_uninstall_release_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
    "$RR_QUARANTINE_READY" "$RR_LIB_DIR" "$RR_LAUNCHER" \
    "$release_systemd_root" "$release_restart_helper"
[ ! -e "$RR_QUARANTINE_FILE" ]
sync_line=$(grep -n '^sync:$' "$RR_TEST_OPERATION_LOG" | head -n 1 | cut -d: -f1)
health_line=$(grep -n '^systemctl:show --property=LoadState --value argo-rr-health.timer$' \
    "$RR_TEST_OPERATION_LOG" | head -n 1 | cut -d: -f1)
stop_line=$(grep -n '^stop-subscription$' "$RR_TEST_OPERATION_LOG" | head -n 1 | cut -d: -f1)
probe_line=$(grep -n '^probe-subscription$' "$RR_TEST_OPERATION_LOG" | head -n 1 | cut -d: -f1)
clear_line=$(grep -n '^clear-quarantine$' "$RR_TEST_OPERATION_LOG" | head -n 1 | cut -d: -f1)
[[ "$sync_line" =~ ^[0-9]+$ && "$health_line" =~ ^[0-9]+$ && \
   "$stop_line" =~ ^[0-9]+$ && "$probe_line" =~ ^[0-9]+$ && \
   "$clear_line" =~ ^[0-9]+$ ]] || {
    echo 'Quarantine release ordering evidence is incomplete.' >&2
    exit 1
}
[ "$sync_line" -lt "$health_line" ] && [ "$health_line" -lt "$stop_line" ] && \
    [ "$stop_line" -lt "$probe_line" ] && [ "$probe_line" -lt "$clear_line" ]
[ "$(grep -c '^clear-quarantine$' "$RR_TEST_OPERATION_LOG")" -eq 1 ]

printf '%s\n' '[21/27] runtime ownership is captured from the exact manifest and rechecked'
reset_case
write_helper success
rr_uninstall_capture_runtime_ownership
[ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ]
[[ "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$RR_UNINSTALL_EXTERNAL_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$RR_UNINSTALL_RUNTIME_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
rr_uninstall_runtime_ownership_is_unchanged
printf '%s\n' '# post-capture tamper' >> \
    "$RR_LIB_DIR/scripts/update-recover.sh"
if rr_uninstall_runtime_ownership_is_unchanged; then
    echo 'A post-capture runtime mutation was accepted.' >&2
    exit 1
fi

printf '%s\n' '[22/27] malformed manifests and foreign deployed helpers fail closed'
reset_case
write_helper success
head -n 1 "$RR_LIB_DIR/manifest.sha256" >> "$RR_LIB_DIR/manifest.sha256"
if rr_uninstall_capture_runtime_ownership; then
    echo 'A duplicate manifest path was accepted.' >&2
    exit 1
fi
[ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = false ]
reset_case
write_helper success
printf '%s\n' '# foreign replacement' >> "$RR_UPDATE_EXTERNAL_HELPER"
if rr_uninstall_capture_runtime_ownership; then
    echo 'A foreign fixed-path external helper was accepted.' >&2
    exit 1
fi
reset_case
write_helper success
mv "$RR_LIB_DIR/manifest.sha256" "$RR_LIB_DIR/manifest.real"
ln -s "$RR_LIB_DIR/manifest.real" "$RR_LIB_DIR/manifest.sha256"
if rr_uninstall_capture_runtime_ownership; then
    echo 'A symlink runtime manifest was accepted.' >&2
    exit 1
fi

printf '%s\n' '[23/27] runtime inventory rejects undeclared files, directories and special paths'
reset_case
write_helper success
printf '%s\n' foreign > "$RR_LIB_DIR/foreign.conf"
if rr_uninstall_capture_runtime_ownership; then
    echo 'An undeclared runtime file was accepted for recursive deletion.' >&2
    exit 1
fi
reset_case
write_helper success
mkdir "$RR_LIB_DIR/foreign-empty-directory"
if rr_uninstall_capture_runtime_ownership; then
    echo 'An undeclared empty runtime directory was accepted.' >&2
    exit 1
fi
reset_case
write_helper success
mkfifo "$RR_LIB_DIR/foreign-fifo"
if rr_uninstall_capture_runtime_ownership; then
    echo 'A special runtime file was accepted.' >&2
    exit 1
fi
reset_case
write_helper success
ln -s "$RR_LIB_DIR/modules/00-runtime.sh" "$RR_LIB_DIR/foreign-link"
if rr_uninstall_capture_runtime_ownership; then
    echo 'An undeclared runtime symlink was accepted.' >&2
    exit 1
fi
reset_case
write_helper success
find() {
    command find "$@"
    return 1
}
if rr_uninstall_capture_runtime_ownership; then
    echo 'A failed runtime inventory walk was accepted.' >&2
    exit 1
fi
unset -f find

printf '%s\n' '[24/27] generated update guard and Python caches have a narrow inventory contract'
reset_case
write_helper success
cat > "$RR_LIB_DIR/modules/61-update-guard.sh" <<'GUARD'
RR_UPDATE_GUARD_VERSION="3"
do_update() {
    :
}
check_update() {
    :
}
GUARD
chmod 644 "$RR_LIB_DIR/modules/61-update-guard.sh"
mkdir "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__"
chmod 700 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__"
printf '\0pyc-fixture' > \
    "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/security.cpython-312.pyc"
chmod 600 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/security.cpython-312.pyc"
rr_uninstall_capture_runtime_ownership
[[ "$RR_UNINSTALL_UPDATE_GUARD_SHA256" =~ ^[0-9a-f]{64}$ ]]
chmod 644 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/security.cpython-312.pyc"
rr_uninstall_runtime_ownership_is_unchanged
chmod 666 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/security.cpython-312.pyc"
if rr_uninstall_runtime_ownership_is_unchanged; then
    echo 'A writable Python cache was accepted.' >&2
    exit 1
fi
chmod 600 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/security.cpython-312.pyc"
printf '%s\n' '# guard tamper' >> "$RR_LIB_DIR/modules/61-update-guard.sh"
if rr_uninstall_runtime_ownership_is_unchanged; then
    echo 'A post-capture update-guard mutation was accepted.' >&2
    exit 1
fi
reset_case
write_helper success
mkdir "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__"
printf '\0foreign' > \
    "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/foreign.cpython-312.pyc"
chmod 600 "$RR_LIB_DIR/nexus/rr_nexus_lib/__pycache__/foreign.cpython-312.pyc"
if rr_uninstall_capture_runtime_ownership; then
    echo 'A Python cache without a manifest source was accepted.' >&2
    exit 1
fi

printf '%s\n' '[25/27] every quarantine artifact and effective unit source is authenticated'
reset_case
write_helper success
_uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"
rr_quarantine_write_marker quarantined 7.1.0 18081
mkdir -p "$(dirname "$RR_QUARANTINE_GUARD_STATE")" \
    "$(dirname "$RR_QUARANTINE_GUARD_SELF")"
chmod 700 "$(dirname "$RR_QUARANTINE_GUARD_STATE")" \
    "$(dirname "$RR_QUARANTINE_GUARD_SELF")"
install -m 600 "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_GUARD_STATE"
install -m 700 "$RR_RECOVERY_SELF" "$RR_QUARANTINE_GUARD_SELF"
rr_uninstall_render_subscription_quarantine_unit > "$RR_QUARANTINE_UNIT"
chmod 644 "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
chmod 600 "$RR_QUARANTINE_READY"
rr_uninstall_subscription_quarantine_artifacts_are_owned
: > "$RR_TEST_QUARANTINE_DROPIN"
if rr_uninstall_subscription_quarantine_artifacts_are_owned; then
    echo 'An effective quarantine-unit drop-in was accepted.' >&2
    exit 1
fi
rm -f "$RR_TEST_QUARANTINE_DROPIN"
printf '%s\n' '# guard tamper' >> "$RR_QUARANTINE_GUARD_SELF"
if rr_uninstall_subscription_quarantine_artifacts_are_owned; then
    echo 'A tampered independent quarantine guard was accepted.' >&2
    exit 1
fi
install -m 700 "$RR_RECOVERY_SELF" "$RR_QUARANTINE_GUARD_SELF"
saved_quarantine_ready="$RR_QUARANTINE_READY"
RR_QUARANTINE_READY="$RR_QUARANTINE_FILE"
if rr_uninstall_subscription_quarantine_artifacts_are_owned; then
    echo 'Two quarantine artifact roles were allowed to share one path.' >&2
    exit 1
fi
RR_QUARANTINE_READY="$saved_quarantine_ready"

printf '%s\n' '[26/27] captured helper hashes remain authoritative after runtime deletion'
reset_case
write_helper success
capture_and_remove_runtime
_uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"
printf '%s\n' '# replacement' >> "$RR_RECOVERY_SELF"
if _uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"; then
    echo 'A post-runtime recovery-helper replacement was trusted.' >&2
    exit 1
fi
if rr_uninstall_remove_captured_runtime_helpers; then
    echo 'A changed captured helper was deleted.' >&2
    exit 1
fi
[ -e "$RR_RECOVERY_SELF" ] && [ -e "$RR_UPDATE_EXTERNAL_HELPER" ]
reset_case
write_helper success
capture_and_remove_runtime
rr_uninstall_remove_captured_runtime_helpers
[ ! -e "$RR_RECOVERY_SELF" ] && [ ! -e "$RR_UPDATE_EXTERNAL_HELPER" ]

printf '%s\n' '[27/27] destructive uninstall keeps quarantine until old restart paths are gone'

# Structural contract: the shared transaction lock and writer freeze must
# precede destructive cleanup, and quarantine release must follow runtime and
# health-unit removal while still preceding recovery-helper removal.
uninstall_wrapper=$(sed -n '/^uninstall_all() {/,/^}/p' "$REPO_ROOT/modules/95-install.sh")
uninstall_body=$(sed -n '/^uninstall_all_locked() {/,/^}/p' "$REPO_ROOT/modules/95-install.sh")
stop_line=$(grep -n 'stop_subscription_servers' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
clear_line=$(grep -n '_uninstall_release_subscription_quarantine' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
capture_line=$(grep -n 'rr_uninstall_capture_runtime_ownership' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
crash_gate_line=$(grep -n 'rr_firewall_stop_nodes_on_indeterminate_commit' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
runtime_recheck_line=$(grep -n 'rr_uninstall_runtime_ownership_is_unchanged' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
runtime_delete_line=$(grep -n 'rm -rf "\$RR_LIB_DIR" "\${RR_LAUNCHER:-/usr/local/bin/rr}"' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
sub_root_delete_line=$(grep -n 'rm -rf -- "\$SUB_ROOT"' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
helper_delete_line=$(grep -n 'rr_uninstall_remove_captured_runtime_helpers' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
[ "$capture_line" -lt "$crash_gate_line" ]
[ "$stop_line" -lt "$clear_line" ]
[ "$runtime_recheck_line" -lt "$runtime_delete_line" ]
[ "$runtime_delete_line" -lt "$clear_line" ]
[ "$clear_line" -lt "$sub_root_delete_line" ]
[ "$sub_root_delete_line" -lt "$helper_delete_line" ]
[ "$clear_line" -lt "$helper_delete_line" ]
if grep -Eq 'rm[^\n]*/run/rr-vps/locks/update\.lock' <<<"$uninstall_body"; then
    echo 'Uninstall unlinks its still-held update lock.' >&2
    exit 1
fi
if grep -Eq 'rm[^\n]*/run/lock/rr-(update|restore-live)\.lock' <<<"$uninstall_body"; then
    echo 'Uninstall still unlinks a possibly held legacy transaction lock.' >&2
    exit 1
fi
grep -Fq 'rr_run_with_update_locks direct 0 uninstall_all_locked' <<<"$uninstall_wrapper"
grep -Fq '_uninstall_acquire_existing_legacy_lock' <<<"$uninstall_body"
health_state_body=$(sed -n '/^_uninstall_health_unit_is_safely_stopped() {/,/^}/p' \
    "$REPO_ROOT/modules/95-install.sh")
grep -Fq 'LoadState' <<<"$health_state_body"
grep -Fq 'ActiveState' <<<"$health_state_body"
grep -Fq 'UnitFileState' <<<"$health_state_body"
grep -Fq 'releases/latest/download/install.sh' <<<"$uninstall_body"
if grep -Fq 'refs/heads/main/install.sh' <<<"$uninstall_body"; then
    echo 'Uninstall still recommends an unreleased main-branch bootstrap.' >&2
    exit 1
fi

printf '%s\n' 'uninstall quarantine regression: PASS'
