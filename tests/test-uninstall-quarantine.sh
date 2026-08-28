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
export RR_TEST_HEALTH_STOP_FAIL="$TEST_ROOT/health-stop-fail"
export RR_TEST_HEALTH_DISABLE_FAIL="$TEST_ROOT/health-disable-fail"
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
            printf '%s\n' "$RR_TEST_HEALTH_LOAD_STATE"
            ;;
        show:--property=ActiveState)
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            printf '%s\n' "$RR_TEST_HEALTH_ACTIVE_STATE"
            ;;
        show:--property=UnitFileState)
            [ ! -e "$RR_TEST_SYSTEMD_QUERY_FAIL" ] || return 1
            printf '%s\n' "$RR_TEST_HEALTH_UNIT_FILE_STATE"
            ;;
        *) return 0 ;;
    esac
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
        "$(dirname "$RR_QUARANTINE_GUARD_SELF")"
    rm -f -- "$RR_TEST_RAW_RULE" "$RR_TEST_ACTIVE_UNIT" \
        "$RR_TEST_ENABLED_UNIT" "$RR_TEST_HELPER_LOG" "$RR_TEST_DELETE_FAIL" \
        "$RR_TEST_QUERY_FAIL" "$RR_TEST_STOP_FAIL"
    rm -f -- "$RR_TEST_DAEMON_FAIL"
    mkdir -p -- "$RR_TX_ROOT" "$(dirname "$RR_QUARANTINE_UNIT")" \
        "$(dirname "$RR_QUARANTINE_READY")" "$(dirname "$RR_RECOVERY_SELF")"
    chmod 700 -- "$(dirname "$RR_RECOVERY_SELF")"
}

write_helper() {
    local mode="$1"
    cat > "$RR_RECOVERY_SELF" <<'HELPER'
#!/bin/bash
set -u
[ "${1:-}" = clear-quarantine ] || exit 2
printf '%s\n' "$1" >> "$RR_TEST_HELPER_LOG"
case "$RR_TEST_HELPER_MODE" in
    success)
        rm -f -- "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
            "$RR_QUARANTINE_READY" "$RR_TEST_RAW_RULE" \
            "$RR_TEST_ACTIVE_UNIT" "$RR_TEST_ENABLED_UNIT"
        ;;
    partial)
        rm -f -- "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" \
            "$RR_QUARANTINE_READY" "$RR_TEST_ACTIVE_UNIT" \
            "$RR_TEST_ENABLED_UNIT"
        ;;
    fail) exit 1 ;;
    *) exit 2 ;;
esac
HELPER
    chmod 700 -- "$RR_RECOVERY_SELF"
    export RR_TEST_HELPER_MODE="$mode"
}

printf '%s\n' '[1/16] an absent quarantine needs no recovery helper'
reset_case
_uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"
[ ! -e "$RR_TEST_HELPER_LOG" ]

printf '%s\n' '[2/16] a marker or symlink fails closed without a trusted helper'
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

printf '%s\n' '[3/16] unsafe helpers and writable ancestors are rejected'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
write_helper success
chmod 722 -- "$RR_RECOVERY_SELF"
if _uninstall_recovery_helper_is_trusted "$RR_RECOVERY_SELF"; then
    echo 'A group/other-writable recovery helper was trusted.' >&2
    exit 1
fi
chmod 700 -- "$RR_RECOVERY_SELF"
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
chmod 700 -- "$unsafe_parent/helper-dir" "$unsafe_parent/helper-dir/recover"
if _uninstall_recovery_helper_is_trusted "$unsafe_parent/helper-dir/recover"; then
    echo 'A recovery helper below an unsafe ancestor was trusted.' >&2
    exit 1
fi

printf '%s\n' '[4/16] helper failure preserves quarantine evidence'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
write_helper fail
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'A failing recovery helper was accepted.' >&2
    exit 1
fi
[ -e "$RR_QUARANTINE_FILE" ]
[ "$(cat "$RR_TEST_HELPER_LOG")" = clear-quarantine ]

printf '%s\n' '[5/16] post-clear residue prevents destructive uninstall continuation'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
: > "$RR_TEST_RAW_RULE"
write_helper partial
if _uninstall_clear_subscription_quarantine \
    "$RR_RECOVERY_SELF" "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" \
    >/dev/null 2>&1; then
    echo 'Residual quarantine firewall state was accepted.' >&2
    exit 1
fi
[ -e "$RR_TEST_RAW_RULE" ]

printf '%s\n' '[6/16] a trusted helper must remove every quarantine artifact'
reset_case
printf 'marker\n' > "$RR_QUARANTINE_FILE"
printf 'unit\n' > "$RR_QUARANTINE_UNIT"
printf 'ready\n' > "$RR_QUARANTINE_READY"
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

printf '%s\n' '[7/16] markerless exact RR firewall residue is discovered and removed'
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

printf '%s\n' '[8/16] firewall deletion failure remains visible and fails closed'
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

printf '%s\n' '[9/16] a foreign same-comment rule is never broadened into deletion'
reset_case
printf 'unit\n' > "$RR_QUARANTINE_UNIT"
printf 'foreign\n' > "$RR_TEST_RAW_RULE"
if rr_clear_subscription_quarantine >/dev/null 2>&1; then
    echo 'A foreign same-comment firewall rule was treated as clean.' >&2
    exit 1
fi
[ "$(cat "$RR_TEST_RAW_RULE")" = foreign ]
[ -e "$RR_QUARANTINE_UNIT" ]

printf '%s\n' '[10/16] an unreadable firewall backend is treated as quarantine evidence'
reset_case
: > "$RR_TEST_QUERY_FAIL"
if ! _uninstall_quarantine_present \
    "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY"; then
    echo 'An unreadable raw firewall table was treated as clean.' >&2
    exit 1
fi

printf '%s\n' '[11/16] direct suspend and clear commands respect the shared update lock'
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

printf '%s\n' '[12/16] suspend failure retains marker and readiness evidence'
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

printf '%s\n' '[13/16] pre-firewall finalization failure retains the exact barrier'
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

printf '%s\n' '[14/16] existing legacy locks are validated, contended and never recreated'
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

printf '%s\n' '[15/16] health-unit proof rejects query, stop, disable and ambiguous states'
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

printf '%s\n' '[16/16] destructive uninstall keeps quarantine until old restart paths are gone'

# Structural contract: the shared transaction lock and writer freeze must
# precede destructive cleanup, and quarantine release must follow runtime and
# health-unit removal while still preceding recovery-helper removal.
uninstall_wrapper=$(sed -n '/^uninstall_all() {/,/^}/p' "$REPO_ROOT/modules/95-install.sh")
uninstall_body=$(sed -n '/^uninstall_all_locked() {/,/^}/p' "$REPO_ROOT/modules/95-install.sh")
timer_line=$(grep -n '_uninstall_health_unit_is_safely_stopped argo-rr-health.timer' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
stop_line=$(grep -n 'stop_subscription_servers' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
clear_line=$(grep -n '_uninstall_clear_subscription_quarantine' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
runtime_delete_line=$(grep -n '"\$RR_LIB_DIR" /usr/local/bin/rr' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
helper_delete_line=$(grep -n '/usr/local/sbin/rr-update-recover' <<<"$uninstall_body" | head -n 1 | cut -d: -f1)
[ "$timer_line" -le "$stop_line" ]
[ "$stop_line" -lt "$clear_line" ]
[ "$runtime_delete_line" -lt "$clear_line" ]
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
