#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source modules/10-system.sh
# shellcheck disable=SC1091
source modules/55-resilience.sh

# IP-ACME restore/rearm has a dedicated state-machine suite.  This file keeps
# its rollback fixtures focused on watchdog, systemd gate, and writer scope.
rr_restore_replace_target_ip_acme_state() { return 0; }
rr_restore_rearm_target_ip_acme() { return 0; }

rr_test_restore_marker_view_systemctl() {
    local property="" unit=""
    if [ "${1:-}" = --version ]; then
        printf '%s\n' 'systemd 253'
        return 0
    fi
    [ "${1:-}" = show ] && [[ "${2:-}" == --property=* ]] && \
        [ "${3:-}" = --value ] || return 1
    property="${2#--property=}"
    unit="${4:-}"
    case "$property" in
        DynamicUser|PrivateUsers|PrivateMounts|RootEphemeral)
            printf '%s\n' no
            ;;
        ProtectSystem)
            printf '%s\n' no
            ;;
        ProtectHome)
            case "$unit" in
                rr-nexus.service|cloudflared.service) printf '%s\n' yes ;;
                *) printf '%s\n' no ;;
            esac
            ;;
        User|Group|RootDirectory|RootImage|MountImages|ExtensionImages|\
        ExtensionDirectories|TemporaryFileSystem|BindPaths|BindReadOnlyPaths|\
        InaccessiblePaths|JoinsNamespaceOf|ReadOnlyPaths|ReadWritePaths|\
        EnvironmentFiles|PassEnvironment|UnsetEnvironment|PAMName|\
        SystemCallFilter|Environment|Conditions|Asserts)
            printf '\n'
            ;;
        *) return 1 ;;
    esac
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

export RR_FIREWALL_LOCK_FILE="$test_root/run/firewall.lock"
export RR_FIREWALL_QUARANTINE_DIR="$test_root/firewall-quarantine"
export RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
RR_BACKUP_WORK_DIR="$test_root/state"
RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
RR_RESTORE_LIVE_MARKER="$test_root/run/restore-live"
RR_RESTORE_WATCH_REQUEST="$test_root/run/restore-watch-request"
RR_RESTORE_LOCK_FILE="$test_root/run/rr-update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$test_root/legacy/rr-update.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$test_root/run/legacy-update-bridge"
RR_RESTORE_LIVE_LOCK_FILE="$test_root/run/rr-restore-live.lock"
RR_RESTORE_WATCH_TIMEOUT=5
mkdir -p "$RR_BACKUP_WORK_DIR" "$test_root/run" "$(dirname "$RR_LEGACY_UPDATE_LOCK_FILE")"
install -d -m 700 "$RR_FIREWALL_QUARANTINE_DIR"

stage="$RR_BACKUP_WORK_DIR/restore.good"
other_stage="$RR_BACKUP_WORK_DIR/restore.other"
install -d -m 700 "$stage" "$other_stage"

printf '%s\n' '[1/9] service gate validates exact durable markers'
rr_restore_service_gate
rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage"
if rr_restore_service_gate; then
    echo 'Gate allowed an active restore without a ready marker.' >&2
    exit 1
fi
rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage"
rr_restore_service_gate
rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$other_stage"
if rr_restore_service_gate; then
    echo 'Gate accepted a ready marker for a different stage.' >&2
    exit 1
fi
printf '%s\n%s\n' "$stage" trailing > "$RR_RESTORE_RUNTIME_READY"
if rr_restore_service_gate; then
    echo 'Gate accepted a multi-line ready marker.' >&2
    exit 1
fi
rm -f "$RR_RESTORE_RUNTIME_READY"
ln -s "$stage" "$RR_RESTORE_RUNTIME_READY"
if rr_restore_service_gate; then
    echo 'Gate accepted a symlink ready marker.' >&2
    exit 1
fi
rm -f "$RR_RESTORE_RUNTIME_READY"
printf '%s\n%s\n' "$stage" trailing > "$RR_RESTORE_ACTIVE"
if rr_restore_service_gate; then
    echo 'Gate accepted a multi-line active marker.' >&2
    exit 1
fi
rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage"

printf '%s\n' '[2/9] live owner gate closes as soon as its lock is released'
rr_restore_publish_marker "$RR_RESTORE_LIVE_MARKER" "$stage"
exec {live_fd}>"$RR_RESTORE_LIVE_LOCK_FILE"
flock -n "$live_fd"
rr_restore_service_gate
exec {live_fd}>&-
if rr_restore_service_gate; then
    echo 'Gate stayed open after the live restore owner disappeared.' >&2
    exit 1
fi
rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"
rr_restore_clear_marker "$RR_RESTORE_ACTIVE"

printf '%s\n' '[2b/9] long-lived children cannot inherit the restore live lock'
fd_test_root="$test_root/live-fd-inheritance"
fd_test_lock="$fd_test_root/restore-live.lock"
fd_test_ready="$fd_test_root/ready"
fd_test_child_pid="$fd_test_root/child.pid"
install -d -m 700 "$fd_test_root"
RR_RESTORE_LIVE_LOCK_FILE="$fd_test_lock" \
RR_RESTORE_LOCK_FILE="$fd_test_root/update.lock" \
RR_LEGACY_UPDATE_LOCK_FILE="$fd_test_root/legacy.lock" \
RR_LEGACY_UPDATE_BRIDGE_FILE="$fd_test_root/missing-bridge" \
bash -c '
    source modules/10-system.sh
    source modules/55-resilience.sh
    spawn_long_lived_child() {
        sleep 30 >/dev/null 2>&1 &
        printf "%s\n" "$!" > "$1"
    }
    rr_secure_lock_prepare "$RR_RESTORE_LIVE_LOCK_FILE"
    exec {owner_fd}>>"$RR_RESTORE_LIVE_LOCK_FILE"
    rr_secure_lock_fd_is_safe "$RR_RESTORE_LIVE_LOCK_FILE" "$owner_fd"
    flock -n "$owner_fd"
    rr_run_without_inherited_update_lock_fds \
        spawn_long_lived_child "$1"
    touch "$2"
    sleep 30
' _ "$fd_test_child_pid" "$fd_test_ready" &
fd_test_parent=$!
for _attempt in $(seq 1 80); do
    [ -s "$fd_test_child_pid" ] && [ -e "$fd_test_ready" ] && break
    sleep 0.05
done
[ -s "$fd_test_child_pid" ] && [ -e "$fd_test_ready" ] || {
    echo 'Restore live-lock inheritance fixture did not start.' >&2
    exit 1
}
fd_test_child=$(cat "$fd_test_child_pid")
[[ "$fd_test_child" =~ ^[0-9]+$ ]] && kill -0 "$fd_test_child" 2>/dev/null || {
    echo 'Long-lived inheritance fixture exited before the owner crash.' >&2
    exit 1
}
kill -KILL "$fd_test_parent"
if wait "$fd_test_parent" 2>/dev/null; then
    echo 'Restore live-lock owner unexpectedly survived SIGKILL.' >&2
    exit 1
fi
flock -n "$fd_test_lock" true || {
    echo 'A long-lived child retained the restore live-lock FD after owner SIGKILL.' >&2
    exit 1
}
kill "$fd_test_child" 2>/dev/null || true
wait "$fd_test_child" 2>/dev/null || true

printf '%s\n' '[3/9] watcher exits cleanly when no transaction is active'
rr_restore_watch_active
armed_stage="$RR_BACKUP_WORK_DIR/restore.armed"
install -d -m 700 "$armed_stage"
rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$armed_stage"
rr_restore_watch_active
[ ! -e "$armed_stage" ] || { echo 'Pre-active decrypted stage was left behind.' >&2; exit 1; }

printf '%s\n' '[3b/9] live-marker cleanup faults isolate candidates and retain ACTIVE'
(
    fault_root="$test_root/watch-clear-live-fault"
    RR_BACKUP_WORK_DIR="$fault_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_LIVE_MARKER="$fault_root/run/restore-live"
    RR_RESTORE_WATCH_REQUEST="$fault_root/run/watch-request"
    fault_stage="$RR_BACKUP_WORK_DIR/restore.clearfault"
    fault_rollback="$fault_stage/rollback"
    isolation_log="$fault_root/isolation.log"
    operation_log="$fault_root/operations.log"
    install -d -m 700 "$fault_stage" "$fault_rollback" "$fault_root/run"
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$fault_stage"
    rr_restore_publish_marker "$RR_RESTORE_LIVE_MARKER" "$fault_stage"
    rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$fault_stage"
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$fault_stage"
    eval "$(declare -f rr_restore_clear_marker | \
        sed '1s/^rr_restore_clear_marker/rr_test_real_clear_marker/')"
    rr_restore_clear_marker() {
        printf 'clear:%s\n' "$1" >> "$operation_log"
        [ "$1" != "$RR_RESTORE_LIVE_MARKER" ] || return 1
        rr_test_real_clear_marker "$1"
    }
    rr_restore_stop_managed_runtime() {
        [ "$1" = "$fault_rollback" ] || return 1
        printf '%s\n' stop >> "$operation_log"
        printf '%s\n' "$1" > "$isolation_log"
    }
    if rr_restore_watch_active_locked; then
        echo 'Watcher accepted a failed LIVE marker cleanup.' >&2
        exit 1
    fi
    [ "$(cat "$isolation_log")" = "$fault_rollback" ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$fault_stage" ] && \
        [ -e "$RR_RESTORE_LIVE_MARKER" ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
        [ ! -L "$RR_RESTORE_RUNTIME_READY" ] || {
            echo 'LIVE cleanup fault did not isolate candidates and retain evidence.' >&2
            exit 1
        }
    ready_clear_line=$(grep -nF "clear:$RR_RESTORE_RUNTIME_READY" "$operation_log" | \
        tail -n 1 | cut -d: -f1)
    stop_line=$(grep -nFx stop "$operation_log" | cut -d: -f1)
    [ "$ready_clear_line" -lt "$stop_line" ] || {
        echo 'Watcher stopped candidates before durably removing READY.' >&2
        exit 1
    }
)

printf '%s\n' '[3c/9] unremovable READY publishes quarantine before stop and blocks late restart'
abort_ready_helper_count=$(declare -f rr_restore_abort_pre_mutation_stage | \
    grep -c 'rr_restore_close_runtime_ready_gate')
rollback_ready_helper_count=$(declare -f rr_restore_rollback_stage | \
    grep -c 'rr_restore_close_runtime_ready_gate')
[ "$abort_ready_helper_count" -eq 2 ] && \
    [ "$rollback_ready_helper_count" -eq 3 ] || {
    echo 'Abort/rollback READY failures do not share the durable close-or-quarantine helper.' >&2
    exit 1
}
(
    fault_root="$test_root/watch-ready-clear-fault"
    RR_BACKUP_WORK_DIR="$fault_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_LIVE_MARKER="$fault_root/run/restore-live"
    RR_RESTORE_WATCH_REQUEST="$fault_root/run/watch-request"
    fault_stage="$RR_BACKUP_WORK_DIR/restore.readyfault"
    fault_rollback="$fault_stage/rollback"
    operation_log="$fault_root/operations.log"
    install -d -m 700 "$fault_stage" "$fault_rollback" "$fault_root/run"
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$fault_stage"
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$fault_stage"
    eval "$(declare -f rr_restore_clear_marker | \
        sed '1s/^rr_restore_clear_marker/rr_test_real_clear_marker/')"
    rr_restore_clear_marker() {
        [ "$1" != "$RR_RESTORE_RUNTIME_READY" ] || return 1
        rr_test_real_clear_marker "$1"
    }
    sync() { return 1; }
    quarantine_active=false
    rr_firewall_publish_fail_closed_quarantine() {
        printf '%s\n' quarantine >> "$operation_log"
        quarantine_active=true
    }
    rr_firewall_fail_closed_quarantine_active() {
        [ "$quarantine_active" = true ]
    }
    rr_firewall_load_fail_closed_quarantine() {
        [ "$quarantine_active" = true ]
    }
    rr_firewall_quarantine_supervisor_effective() {
        [ "$quarantine_active" = true ]
    }
    rr_restore_stop_managed_runtime() {
        [ "$1" = "$fault_rollback" ] || return 1
        [ "$quarantine_active" = true ] || {
            echo 'Runtime stop preceded durable quarantine proof.' >&2
            return 1
        }
        printf '%s\n' stop >> "$operation_log"
    }
    rr_restore_watch_fail_closed "$fault_stage"
    [ -e "$RR_RESTORE_RUNTIME_READY" ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$fault_stage" ] && \
        [ "$quarantine_active" = true ] || {
            echo 'READY fault discarded evidence or failed to retain quarantine.' >&2
            exit 1
        }
    quarantine_line=$(grep -nFx quarantine "$operation_log" | cut -d: -f1)
    stop_line=$(grep -nFx stop "$operation_log" | cut -d: -f1)
    [ "$quarantine_line" -lt "$stop_line" ] || {
        echo 'Runtime stopped before quarantine became effective.' >&2
        exit 1
    }
    # READY still matches ACTIVE, so the restore gate alone would admit the
    # restart.  The independent quarantine is therefore the required second
    # gate and must make the combined decision fail closed.
    rr_restore_service_gate
    if rr_restore_service_gate && ! rr_firewall_fail_closed_quarantine_active; then
        echo 'A late managed restart crossed retained READY without quarantine.' >&2
        exit 1
    fi
)

printf '%s\n' '[4/9] watcher blocks on the update lock before recovery'
rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$stage"
lock_held="$test_root/lock-held"
recovered="$test_root/recovered"
flock "$RR_RESTORE_LOCK_FILE" bash -c 'touch "$1"; sleep 1' _ "$lock_held" &
holder_pid=$!
for _attempt in $(seq 1 40); do
    [ -f "$lock_held" ] && break
    sleep 0.05
done
[ -f "$lock_held" ] || { echo 'Lock holder did not start.' >&2; exit 1; }
(
    rr_restore_recover_active() {
        printf '%s\n' recovered > "$recovered"
        rr_restore_clear_marker "$RR_RESTORE_ACTIVE"
    }
    rr_restore_watch_active
) &
watcher_pid=$!
rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage"
sleep 0.15
[ ! -e "$recovered" ] || { echo 'Watcher recovered before acquiring the lock.' >&2; exit 1; }
kill -0 "$watcher_pid" 2>/dev/null || { echo 'Watcher did not wait for the lock.' >&2; exit 1; }
wait "$holder_pid"
wait "$watcher_pid"
[ -s "$recovered" ] || { echo 'Watcher did not recover after lock release.' >&2; exit 1; }

printf '%s\n' '[5/9] recovery and watchdog units install bounded gates'
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/systemd"
    manager_reloaded=false
    # Internal unit ownership/rendering has dedicated tests; this case proves
    # bounded unit content and the effective restore gate set.
    rr_restore_internal_unit_is_owned_or_absent() { return 0; }
    rr_restore_recovery_unit_is_owned() { return 0; }
    rr_restore_watchdog_unit_is_owned() { return 0; }
    systemctl() {
        rr_test_restore_marker_view_systemctl "$@" && return 0
        case "$*" in
            'daemon-reload') manager_reloaded=true ;;
            'show --property=LoadState --value '*)
                [ "$manager_reloaded" = true ] || return 1
                printf '%s\n' loaded ;;
            'show --property=DropInPaths --value '*)
                unit="${*: -1}"
                printf '%s\n' \
                    "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME" ;;
            'show --property=ExecCondition --value '*)
                printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' \
                    "$RR_RESTORE_GATE_EXEC_CONDITION" ;;
            'show --property=LoadState --value rr-restore-recovery.service')
                printf '%s\n' loaded ;;
            'show --property=ActiveState --value rr-restore-recovery.service')
                printf '%s\n' inactive ;;
            'show --property=UnitFileState --value rr-restore-recovery.service')
                printf '%s\n' enabled ;;
            *) return 0 ;;
        esac
    }
    rr_restore_prepare_recovery_unit
    grep -Fq 'ExecStart=/usr/local/bin/rr --recover-restore' \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service"
    grep -Fq 'TimeoutStartSec=30min' \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service"
    grep -Fq 'Type=exec' "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service"
    grep -Fq 'ExecStart=/usr/local/bin/rr --watch-restore' \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service"
    grep -Fq 'RuntimeMaxSec=3700' "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service"
    if grep -Eq '^Restart=' "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service"; then
        echo 'Watchdog unit contains an automatic retry loop.' >&2
        exit 1
    fi
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        dropin="$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
        [ -f "$dropin" ] && [ ! -L "$dropin" ]
        [ "$(wc -l < "$dropin")" -eq 2 ]
        if grep -Fxq 'ExecCondition=' "$dropin"; then
            echo 'Restore gate still resets pre-existing ExecCondition entries.' >&2
            exit 1
        fi
        grep -Fxq "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" "$dropin"
    done
)
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/hostile-systemd"
    stop_log="$test_root/hostile-stop.log"
    manager_reloaded=false
    rr_restore_internal_unit_is_owned_or_absent() { return 0; }
    rr_restore_recovery_unit_is_owned() { return 0; }
    rr_restore_watchdog_unit_is_owned() { return 0; }
    systemctl() {
        rr_test_restore_marker_view_systemctl "$@" && return 0
        case "$*" in
            'daemon-reload') manager_reloaded=true ;;
            'show --property=LoadState --value '*)
                [ "$manager_reloaded" = true ] || return 1
                printf '%s\n' loaded ;;
            'show --property=DropInPaths --value nginx.service')
                printf '%s %s\n' \
                    "$RR_RESTORE_SYSTEMD_DIR/nginx.service.d/$RR_RESTORE_GATE_DROPIN_NAME" \
                    '/run/systemd/system/nginx.service.d/zzzzz-hostile-reset.conf' ;;
            'show --property=DropInPaths --value '*)
                unit="${*: -1}"
                printf '%s\n' \
                    "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME" ;;
            'show --property=ExecCondition --value '*)
                printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=no }\n' \
                    "$RR_RESTORE_GATE_EXEC_CONDITION" ;;
            'show --property=ActiveState --value '*) printf '%s\n' inactive ;;
            stop\ *) printf '%s\n' "$*" >> "$stop_log" ;;
            *) return 0 ;;
        esac
    }
    if rr_restore_prepare_recovery_unit; then
        echo 'Recovery preparation accepted an effective later reset drop-in.' >&2
        exit 1
    fi
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        grep -Fxq "stop $unit" "$stop_log"
    done
)
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/combined-gates-systemd"
    RR_FIREWALL_QUARANTINE_DIR="$test_root/combined-gates-quarantine"
    RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
    install -d -m 700 "$RR_RESTORE_SYSTEMD_DIR" "$RR_FIREWALL_QUARANTINE_DIR"
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d"
        printf '%s\n' '[Service]' \
            "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" > \
            "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
        chmod 644 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
        if rr_restore_unit_uses_firewall_gate "$unit"; then
            printf '%s\n' '[Service]' \
                'ExecCondition=/usr/bin/test ! -e /var/lib/rr-vps/firewall-quarantine' \
                'ExecCondition=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine' > \
                "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
            chmod 644 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
        fi
        if rr_restore_unit_uses_nexus_gate "$unit"; then
            printf '%s\n' '[Service]' \
                "ExecCondition=$RR_RESTORE_NEXUS_GATE_EXEC_ARGV" > \
                "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
            chmod 644 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
        fi
    done
    omit_firewall_condition=false
    omit_nexus_condition=false
    ignore_restore_condition=false
    systemctl() {
        rr_test_restore_marker_view_systemctl "$@" && return 0
        unit="${*: -1}"
        case "$*" in
            'show --property=LoadState --value '*) printf '%s\n' loaded ;;
            'show --property=DropInPaths --value '*)
                printf '%s' "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
                if rr_restore_unit_uses_firewall_gate "$unit"; then
                    printf ' %s' "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
                fi
                if rr_restore_unit_uses_nexus_gate "$unit"; then
                    printf ' %s' "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
                fi
                printf '\n'
                ;;
            'show --property=ExecCondition --value '*)
                if [ "$ignore_restore_condition" = true ]; then
                    printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=yes }' \
                        "$RR_RESTORE_GATE_EXEC_CONDITION"
                else
                    printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=no }' \
                        "$RR_RESTORE_GATE_EXEC_CONDITION"
                fi
                if rr_restore_unit_uses_firewall_gate "$unit"; then
                    printf ' { path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/rr-vps/firewall-quarantine ; ignore_errors=no }'
                    [ "$omit_firewall_condition" = true ] || \
                        printf ' { path=/usr/bin/test ; argv[]=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine ; ignore_errors=no }'
                fi
                if rr_restore_unit_uses_nexus_gate "$unit"; then
                    [ "$omit_nexus_condition" = true ] || \
                        printf ' { path=%s ; argv[]=%s ; ignore_errors=no }' \
                            "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
                            "$RR_RESTORE_NEXUS_GATE_EXEC_ARGV"
                fi
                printf '\n'
                ;;
            *) return 0 ;;
        esac
    }
    rr_restore_effective_gate_set_is_exact || {
        echo 'Restore and firewall effective gate sets did not coexist.' >&2
        exit 1
    }
    ignore_restore_condition=true
    if rr_restore_effective_gate_is_exact sing-box.service; then
        echo 'Combined gate proof accepted an ignored -/usr/local/bin/rr --restore-service-gate condition.' >&2
        exit 1
    fi
    if rr_restore_effective_conditions_are_managed sing-box.service; then
        echo 'Managed-condition proof accepted an ignored -/usr/local/bin/rr --restore-service-gate condition.' >&2
        exit 1
    fi
    ignore_restore_condition=false
    omit_firewall_condition=true
    if rr_restore_effective_gate_is_exact sing-box.service; then
        echo 'Combined gate proof accepted a missing firewall condition.' >&2
        exit 1
    fi
    omit_firewall_condition=false
    omit_nexus_condition=true
    if rr_restore_effective_gate_is_exact nginx.service; then
        echo 'Combined gate proof accepted a missing Nexus certificate condition.' >&2
        exit 1
    fi
    omit_nexus_condition=false
    : > "$RR_FIREWALL_QUARANTINE_FILE"
    chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
    if rr_restore_preflight_gate_dropin_order; then
        echo 'Restore preflight accepted an active firewall quarantine.' >&2
        exit 1
    fi
    rm -f "$RR_FIREWALL_QUARANTINE_FILE"
    firewall_dropin="$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
    rm -f "$firewall_dropin"
    ln -s /run/missing-firewall-gate "$firewall_dropin"
    if rr_restore_preflight_gate_dropin_order; then
        echo 'Restore preflight accepted a dangling managed firewall gate.' >&2
        exit 1
    fi
)
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/admin-condition-systemd"
    admin_dir="$RR_RESTORE_SYSTEMD_DIR/sing-box.service.d"
    admin_dropin="$admin_dir/10-admin-condition.conf"
    install -d -m 755 "$admin_dir"
    printf '%s\n' '[Service]' 'ExecCondition=/usr/bin/test -e /run/admin-ready' > \
        "$admin_dropin"
    chmod 644 "$admin_dropin"
    systemctl() {
        unit="${*: -1}"
        case "$*" in
            'show --property=LoadState --value '*) printf '%s\n' loaded ;;
            'show --property=DropInPaths --value sing-box.service')
                printf '%s\n' "$admin_dropin" ;;
            'show --property=DropInPaths --value '*) printf '\n' ;;
            'show --property=ExecCondition --value sing-box.service')
                printf '%s\n' \
                    '{ path=/usr/bin/test ; argv[]=/usr/bin/test -e /run/admin-ready ; ignore_errors=no }' ;;
            'show --property=ExecCondition --value '*) printf '\n' ;;
            *) return 0 ;;
        esac
    }
    if rr_restore_preflight_gate_dropin_order; then
        echo 'Restore preflight accepted an unmanaged administrator ExecCondition.' >&2
        exit 1
    fi
    [ ! -e "$admin_dir/$RR_RESTORE_GATE_DROPIN_NAME" ] || {
        echo 'Restore wrote its gate before rejecting an administrator condition.' >&2
        exit 1
    }
    grep -Fxq 'ExecCondition=/usr/bin/test -e /run/admin-ready' "$admin_dropin"
)
(
    regeneration_root="$test_root/regeneration"
    CONFIG_FILE="$regeneration_root/argo_vmess.conf"
    NEXUS_CONFIG_FILE="$regeneration_root/nexus.json"
    NEXUS_SERVICE_FILE="$regeneration_root/rr-nexus.service"
    RR_SINGBOX_SERVICE_FILE="$regeneration_root/sing-box.service"
    RR_HEALTH_SERVICE_FILE="$regeneration_root/argo-rr-health.service"
    RR_HEALTH_TIMER_FILE="$regeneration_root/argo-rr-health.timer"
    RR_RESTORE_SYSTEMD_DIR="$regeneration_root/systemd"
    operation_log="$regeneration_root/operations"
    install -d -m 700 "$regeneration_root"
    : > "$CONFIG_FILE"
    : > "$NEXUS_CONFIG_FILE"
    write_singbox_systemd_unit() {
        : > "$RR_SINGBOX_SERVICE_FILE"
        printf '%s\n' write-singbox >> "$operation_log"
    }
    write_health_monitor_units() {
        : > "$RR_HEALTH_SERVICE_FILE"
        : > "$RR_HEALTH_TIMER_FILE"
        printf '%s\n' write-health >> "$operation_log"
    }
    nexus_write_service() {
        : > "$NEXUS_SERVICE_FILE"
        printf '%s\n' write-nexus >> "$operation_log"
    }
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d"
        printf '%s\n' '[Service]' \
            "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" > \
            "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
        chmod 644 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
    done
    manager_reloaded=false
    hostile_unit=""
    systemctl() {
        rr_test_restore_marker_view_systemctl "$@" && return 0
        case "$*" in
            'daemon-reload')
                manager_reloaded=true
                printf '%s\n' reload >> "$operation_log"
                ;;
            'show --property=LoadState --value '*)
                [ "$manager_reloaded" = true ] || {
                    printf '%s\n' not-found
                    return 0
                }
                case "$*" in
                    *sing-box.service)
                        [ -f "$RR_SINGBOX_SERVICE_FILE" ] && printf '%s\n' loaded || printf '%s\n' not-found ;;
                    *argo-rr-health.service)
                        [ -f "$RR_HEALTH_SERVICE_FILE" ] && printf '%s\n' loaded || printf '%s\n' not-found ;;
                    *argo-rr-health.timer)
                        [ -f "$RR_HEALTH_TIMER_FILE" ] && printf '%s\n' loaded || printf '%s\n' not-found ;;
                    *rr-nexus.service)
                        [ -f "$NEXUS_SERVICE_FILE" ] && printf '%s\n' loaded || printf '%s\n' not-found ;;
                    *nginx.service) printf '%s\n' loaded ;;
                    *) printf '%s\n' not-found ;;
                esac
                printf 'load:%s\n' "${*: -1}" >> "$operation_log"
                ;;
            'show --property=DropInPaths --value '*)
                unit="${*: -1}"
                case "$unit" in
                    sing-box.service|argo-rr-health.service|rr-nexus.service|nginx.service)
                        printf '%s' "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
                        [ "$unit" != "$hostile_unit" ] || \
                            printf ' /run/systemd/system/%s.d/zzzzz-hostile-reset.conf' "$unit"
                        printf '\n'
                        ;;
                    *) printf '\n' ;;
                esac
                ;;
            'show --property=ExecCondition --value '*)
                printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=no }\n' \
                    "$RR_RESTORE_GATE_EXEC_CONDITION"
                ;;
            'show --property=ActiveState --value '*) printf '%s\n' inactive ;;
            stop\ *) printf '%s\n' "$*" >> "$operation_log" ;;
            *) return 0 ;;
        esac
    }
    rr_restore_regenerate_runtime_files
    expected_regeneration=$(printf '%s\n' write-singbox write-health write-nexus reload \
        'load:sing-box.service' 'load:argo-rr-health.service' \
        'load:argo-rr-health.timer' 'load:rr-nexus.service')
    [ "$(head -n 8 "$operation_log")" = "$expected_regeneration" ] || {
        echo 'Trusted unit regeneration did not reload and prove every unit in order.' >&2
        exit 1
    }
    hostile_unit=sing-box.service
    if rr_restore_regenerate_runtime_files; then
        echo 'Runtime regeneration accepted a late-created Sing-box gate reset.' >&2
        exit 1
    fi
    grep -Fxq 'stop sing-box.service' "$operation_log"
)
(
    cloud_root="$test_root/late-cloudflared-gate"
    RR_RESTORE_SYSTEMD_DIR="$cloud_root/systemd"
    RR_CLOUDFLARED_SERVICE_FILE="$cloud_root/systemd/cloudflared.service"
    CONFIG_FILE="$cloud_root/missing-config"
    NEXUS_CONFIG_FILE="$cloud_root/missing-nexus"
    rollback="$cloud_root/rollback"
    operation_log="$cloud_root/operations"
    install -d -m 700 "$rollback" "$RR_RESTORE_SYSTEMD_DIR"
    : > "$rollback/cloudflared_service_was_present"
    printf '%s\n' '[Service]' 'ExecStart=/usr/bin/true' > "$rollback/cloudflared.service"
    rr_restore_rollback_claims_cloudflared() { return 0; }
    rr_restore_fixed_cloudflared_unit_is_owned() { return 0; }
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d"
        printf '%s\n' '[Service]' \
            "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" > \
            "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
        chmod 644 "$RR_RESTORE_SYSTEMD_DIR/${unit}.d/$RR_RESTORE_GATE_DROPIN_NAME"
    done
    systemctl() {
        case "$*" in
            'daemon-reload') : ;;
            'show --property=LoadState --value cloudflared.service') printf '%s\n' loaded ;;
            'show --property=LoadState --value '*) printf '%s\n' not-found ;;
            'show --property=DropInPaths --value cloudflared.service')
                printf '%s %s\n' \
                    "$RR_RESTORE_SYSTEMD_DIR/cloudflared.service.d/$RR_RESTORE_GATE_DROPIN_NAME" \
                    '/run/systemd/system/cloudflared.service.d/zzzzz-hostile-reset.conf'
                ;;
            'show --property=DropInPaths --value '*) printf '\n' ;;
            'show --property=ExecCondition --value '*)
                printf '{ path=/bin/sh ; argv[]=%s ; ignore_errors=no }\n' \
                    "$RR_RESTORE_GATE_EXEC_CONDITION"
                ;;
            'show --property=ActiveState --value cloudflared.service') printf '%s\n' inactive ;;
            'stop cloudflared.service') printf '%s\n' "$*" >> "$operation_log" ;;
            enable\ *) printf '%s\n' "$*" >> "$operation_log" ;;
            *) return 0 ;;
        esac
    }
    if rr_restore_apply_cloudflared_snapshot "$rollback"; then
        echo 'Cloudflared replay accepted a late-created effective gate reset.' >&2
        exit 1
    fi
    grep -Fxq 'stop cloudflared.service' "$operation_log"
    if grep -Fq 'enable cloudflared' "$operation_log"; then
        echo 'Cloudflared was enabled after its effective gate proof failed.' >&2
        exit 1
    fi
)
grep -Fq -- '--watch-restore)' rr
grep -Fq -- '--restore-service-gate)' rr
grep -Fq 'rr-restore-watchdog.service' modules/95-install.sh
grep -Fq 'zzzz-rr-restore-gate.conf' modules/95-install.sh

printf '%s\n' '[6/9] restore systemd state is explicit and query failures fail closed'
(
    mock_load=loaded
    mock_active=active
    mock_file=enabled
    systemctl() {
        case "$*" in
            "show --property=LoadState --value "*) printf '%s\n' "$mock_load" ;;
            "show --property=ActiveState --value "*) printf '%s\n' "$mock_active" ;;
            "show --property=UnitFileState --value "*)
                if [ "$mock_load" != not-found ]; then
                    printf '%s\n' "$mock_file"
                fi
                return 0
                ;;
            *) return 0 ;;
        esac
    }
    captured_active=false
    captured_enabled=false
    rr_restore_capture_unit_activity_state example.service captured_active
    rr_restore_capture_unit_file_state example.service captured_enabled
    [ "$captured_active" = true ] && [ "$captured_enabled" = true ]

    mock_active=activating
    if rr_restore_capture_unit_activity_state example.service captured_active; then
        echo 'Restore snapshot accepted a transitional service state.' >&2
        exit 1
    fi
    mock_active=inactive
    mock_file=enabled-runtime
    if rr_restore_capture_unit_file_state example.service captured_enabled; then
        echo 'Restore snapshot promoted runtime-only enablement to persistent state.' >&2
        exit 1
    fi
    mock_load=not-found
    mock_active=inactive
    mock_file=""
    rr_restore_capture_unit_activity_state missing.service captured_active
    rr_restore_capture_unit_file_state missing.service captured_enabled
    [ "$captured_active" = false ] && [ "$captured_enabled" = false ]
    rr_restore_unit_activity_matches missing.service inactive
    rr_restore_unit_file_state_matches missing.service disabled

    mock_load=masked
    mock_active=inactive
    mock_file=masked
    if rr_restore_capture_unit_activity_state masked.service captured_active || \
       rr_restore_capture_unit_file_state masked.service captured_enabled; then
        echo 'Restore snapshot flattened a persistent unit mask.' >&2
        exit 1
    fi
    if rr_restore_reject_unrestorable_unit_states; then
        echo 'Restore preflight accepted a managed masked unit.' >&2
        exit 1
    fi
)
(
    systemctl() { return 125; }
    load_config_with_defaults() { return 0; }
    select_entry_ip() { return 0; }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    expected_argo_tunnel_running() { return 1; }
    if rr_restore_capture_unit_activity_state rr-nexus ignored; then
        echo 'Restore snapshot mapped a systemd query error to inactive.' >&2
        exit 1
    fi
    if rr_restore_freeze_writers; then
        echo 'Writer freeze accepted systemd query failure.' >&2
        exit 1
    fi
    if rr_restore_stop_managed_runtime; then
        echo 'Runtime stop accepted systemd query failure.' >&2
        exit 1
    fi
    NEXUS_CONFIG_FILE="$test_root/query-fail-nexus.json"
    NEXUS_SERVICE_FILE="$test_root/query-fail-nexus.service"
    : > "$NEXUS_CONFIG_FILE"
    : > "$NEXUS_SERVICE_FILE"
    if rr_restore_set_nexus_enablement false; then
        echo 'Nexus disable accepted systemd query failure.' >&2
        exit 1
    fi
    empty_rollback="$test_root/query-fail-rollback"
    mkdir -p "$empty_rollback"
    if rr_restore_resume_frozen_writers "$empty_rollback"; then
        echo 'Writer resume accepted systemd query failure as stopped state.' >&2
        exit 1
    fi
    RR_CF_TOKEN_FILE="$test_root/cloudflared-token"
    printf '%s\n' managed > "$RR_CF_TOKEN_FILE"
    TUNNEL_MODE=2
    if rr_restore_remove_managed_fixed_tunnel; then
        echo 'Cloudflared cleanup mapped a systemd query error to absence.' >&2
        exit 1
    fi
)
(
    runtime_log="$test_root/runtime-stop.log"
    nginx_state=active
    ignore_nginx_stop=false
    load_config_with_defaults() { TUNNEL_MODE=1; return 0; }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    expected_argo_tunnel_running() { return 1; }
    systemctl() {
        printf '%s\n' "$*" >> "$runtime_log"
        if [ "${1:-}" = stop ]; then
            if [ "$*" = 'stop rr-nexus sing-box nginx' ] && \
               [ "$ignore_nginx_stop" = false ]; then
                nginx_state=inactive
            fi
            return 0
        fi
        [ "${1:-}" = show ] || return 0
        property="${2#--property=}"
        unit="${4:-}"
        case "$property:$unit" in
            LoadState:*) printf '%s\n' loaded ;;
            ActiveState:nginx) printf '%s\n' "$nginx_state" ;;
            ActiveState:*) printf '%s\n' inactive ;;
            UnitFileState:*) printf '%s\n' disabled ;;
            *) return 1 ;;
        esac
    }
    rr_restore_stop_managed_runtime || {
        echo 'Runtime isolation failed to stop an active Nginx.' >&2
        exit 1
    }
    grep -Fxq 'stop rr-nexus sing-box nginx' "$runtime_log" || {
        echo 'Runtime isolation omitted Nginx from its stop set.' >&2
        exit 1
    }
    nginx_state=active
    ignore_nginx_stop=true
    if rr_restore_stop_managed_runtime; then
        echo 'Runtime isolation trusted a successful stop without proving Nginx inactive.' >&2
        exit 1
    fi
)
(
    abort_root="$test_root/pre-mutation-writer-scope"
    RR_BACKUP_WORK_DIR="$abort_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_WATCH_REQUEST="$abort_root/watch-request"
    RR_RESTORE_LIVE_MARKER="$abort_root/live-marker"
    abort_stage="$RR_BACKUP_WORK_DIR/restore.abortscope"
    rollback="$abort_stage/rollback"
    identity_dir="$abort_root/identity"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$abort_stage" "$rollback" \
        "$identity_dir"
    : > "$rollback/nexus_was_running"
    : > "$rollback/health_timer_was_running"
    chmod 600 "$rollback/nexus_was_running" "$rollback/health_timer_was_running"
    printf '%s\n' quick-pid-417 > "$identity_dir/quick.pid"
    printf '%s\n' quick.example.invalid > "$identity_dir/domain"
    printf '%s\n' quick-config-v1 > "$identity_dir/config"
    printf '%s\n' singbox-pid-912 > "$identity_dir/singbox.pid"
    printf '%s\n' nginx-pid-731 > "$identity_dir/nginx.pid"
    before_identity=$(sha256sum "$identity_dir"/* | sha256sum | awk '{print $1}')
    data_plane_mutated=false
    nexus_state=inactive
    health_timer_state=inactive
    health_service_state=inactive
    systemctl() {
        case "$*" in
            'start rr-nexus') nexus_state=active ;;
            'stop rr-nexus') nexus_state=inactive ;;
            'start argo-rr-health.timer') health_timer_state=active ;;
            'stop argo-rr-health.timer') health_timer_state=inactive ;;
            'stop argo-rr-health.service') health_service_state=inactive ;;
            *) data_plane_mutated=true; return 97 ;;
        esac
    }
    rr_restore_unit_activity_matches() {
        case "$1:$2" in
            rr-nexus:active) [ "$nexus_state" = active ] ;;
            rr-nexus:inactive) [ "$nexus_state" = inactive ] ;;
            argo-rr-health.timer:active) [ "$health_timer_state" = active ] ;;
            argo-rr-health.timer:inactive) [ "$health_timer_state" = inactive ] ;;
            argo-rr-health.service:inactive) [ "$health_service_state" = inactive ] ;;
            *) return 1 ;;
        esac
    }
    start_argo_tunnel() { data_plane_mutated=true; return 1; }
    stop_quick_argo_tunnel() { data_plane_mutated=true; return 1; }
    start_subscription_server() { data_plane_mutated=true; return 1; }
    stop_subscription_servers() { data_plane_mutated=true; return 1; }
    rr_restore_activate_nginx_state() { data_plane_mutated=true; return 1; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_nexus_service_start_preflight() { return 0; }
    rr_restore_write_phase "$abort_stage" frozen
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$abort_stage"
    rr_restore_abort_pre_mutation_stage "$abort_stage" || {
        echo 'Pre-mutation abort failed to resume only the frozen writers.' >&2
        exit 1
    }
    after_identity=$(sha256sum "$identity_dir"/* | sha256sum | awk '{print $1}')
    [ "$data_plane_mutated" = false ] && \
        [ "$before_identity" = "$after_identity" ] && \
        [ "$nexus_state" = active ] && [ "$health_timer_state" = active ] && \
        [ "$health_service_state" = inactive ] || {
            echo 'Pre-mutation abort changed an unfrozen data-plane PID/domain/config.' >&2
            exit 1
        }
)
(
    failure_root="$test_root/full-resume-preflight-failure"
    rollback="$failure_root/rollback"
    install -d -m 700 "$rollback"
    action_log="$failure_root/actions"
    : > "$action_log"
    load_config_with_defaults() { return 1; }
    select_entry_ip() { printf '%s\n' select >> "$action_log"; return 0; }
    systemctl() { printf 'systemctl:%s\n' "$*" >> "$action_log"; return 0; }
    start_subscription_server() { printf '%s\n' subscription-start >> "$action_log"; }
    stop_subscription_servers() { printf '%s\n' subscription-stop >> "$action_log"; }
    start_argo_tunnel() { printf '%s\n' argo-start >> "$action_log"; }
    stop_quick_argo_tunnel() { printf '%s\n' argo-stop >> "$action_log"; }
    if rr_restore_resume_frozen_writers "$rollback"; then
        echo 'Full data-plane resume accepted a config-load failure.' >&2
        exit 1
    fi
    [ ! -s "$action_log" ] || {
        echo 'Full data-plane resume acted after a config-load failure.' >&2
        exit 1
    }
    load_config_with_defaults() { return 0; }
    select_entry_ip() { return 1; }
    if rr_restore_resume_frozen_writers "$rollback"; then
        echo 'Full data-plane resume accepted an entry-IP proof failure.' >&2
        exit 1
    fi
    [ ! -s "$action_log" ] || {
        echo 'Full data-plane resume acted after an entry-IP proof failure.' >&2
        exit 1
    }
)
(
    ownership_root="$test_root/cloudflared-exact-ownership"
    RR_BACKUP_WORK_DIR="$ownership_root/state"
    CONFIG_FILE="$ownership_root/argo_vmess.conf"
    RR_CF_TOKEN_FILE="$ownership_root/token-dir/token"
    RR_CLOUDFLARED_BIN="$ownership_root/bin/cloudflared"
    RR_CLOUDFLARED_SERVICE_FILE="$ownership_root/systemd/cloudflared.service"
    RR_RESTORE_SYSTEMD_DIR="$ownership_root/systemd"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$(dirname -- "$RR_CF_TOKEN_FILE")"
    install -d -m 755 "$(dirname -- "$RR_CLOUDFLARED_BIN")" \
        "$(dirname -- "$RR_CLOUDFLARED_SERVICE_FILE")"
    printf '%s\n' 'CONFIG_VERSION=7' 'TUNNEL_MODE=2' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    printf '%s\n' token-v1 > "$RR_CF_TOKEN_FILE"
    chmod 600 "$RR_CF_TOKEN_FILE"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$RR_CLOUDFLARED_BIN"
    chmod 755 "$RR_CLOUDFLARED_BIN"
    rr_restore_render_fixed_cloudflared_service "$RR_CLOUDFLARED_BIN" > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    fixed_mode=2
    cloud_exec_ignore=no
    cloud_exec_reload=""
    cloud_exec_condition=""
    cloud_dynamic_user=no
    cloud_user=root
    cloud_group=root
    cloud_working_directory=""
    cloud_private_network=no
    load_config_with_defaults() { TUNNEL_MODE="$fixed_mode"; return 0; }
    systemctl() {
        case "$*" in
            '--version') printf '%s\n' 'systemd 253' ;;
            'show --property=LoadState --value cloudflared.service') printf '%s\n' loaded ;;
            'show --property=FragmentPath --value cloudflared.service')
                printf '%s\n' "$RR_CLOUDFLARED_SERVICE_FILE" ;;
            'show --property=DropInPaths --value cloudflared.service') printf '\n' ;;
            'show --property=ExecStart --value cloudflared.service')
                printf '{ path=%s ; argv[]=%s --no-autoupdate tunnel run --token-file %%d/rr-tunnel-token ; ignore_errors=%s }\n' \
                    "$RR_CLOUDFLARED_BIN" "$RR_CLOUDFLARED_BIN" \
                    "$cloud_exec_ignore" ;;
            'show --property=ExecStartPre --value cloudflared.service') printf '\n' ;;
            'show --property=ExecReload --value cloudflared.service')
                printf '%s\n' "$cloud_exec_reload" ;;
            'show --property=DynamicUser --value cloudflared.service')
                printf '%s\n' "$cloud_dynamic_user" ;;
            'show --property=User --value cloudflared.service')
                printf '%s\n' "$cloud_user" ;;
            'show --property=Group --value cloudflared.service')
                printf '%s\n' "$cloud_group" ;;
            'show --property=WorkingDirectory --value cloudflared.service')
                printf '%s\n' "$cloud_working_directory" ;;
            'show --property=PrivateNetwork --value cloudflared.service')
                printf '%s\n' "$cloud_private_network" ;;
            'show --property=RootDirectory --value cloudflared.service'|\
            'show --property=RootImage --value cloudflared.service') printf '\n' ;;
            'show --property=ExecCondition --value cloudflared.service')
                printf '%s\n' "$cloud_exec_condition" ;;
            *) rr_test_restore_marker_view_systemctl "$@" ;;
        esac
    }
    rr_restore_fixed_cloudflared_unit_is_owned || {
        echo 'Exact RR Cloudflared unit/effective identity was not recognized.' >&2
        exit 1
    }
    cloud_exec_ignore=yes
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        echo 'Cloudflared ownership accepted an ignored effective ExecStart.' >&2
        exit 1
    fi
    cloud_exec_ignore=no
    cloud_exec_reload='{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }'
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        echo 'Cloudflared ownership accepted an unexpected effective ExecReload.' >&2
        exit 1
    fi
    cloud_exec_reload=""
    cloud_user=nobody
    cloud_group=nogroup
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        echo 'Cloudflared ownership accepted a foreign effective runtime identity.' >&2
        exit 1
    fi
    cloud_user=root
    cloud_group=root
    cloud_private_network=yes
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        echo 'Cloudflared ownership accepted an unexpected private network.' >&2
        exit 1
    fi
    cloud_private_network=no
    cloud_exec_condition='{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }'
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        echo 'Cloudflared ownership accepted an unmanaged effective condition.' >&2
        exit 1
    fi
    cloud_exec_condition=""
    claim_stage="$RR_BACKUP_WORK_DIR/restore.exactclaim"
    claim_rollback="$claim_stage/rollback"
    install -d -m 700 "$claim_stage" "$claim_rollback/rootfs/etc/rr-cloudflared"
    cp -p -- "$RR_CLOUDFLARED_SERVICE_FILE" "$claim_rollback/cloudflared.service"
    rr_restore_write_cloudflared_claim "$claim_rollback"
    cp -p -- "$RR_CF_TOKEN_FILE" \
        "$claim_rollback/rootfs/etc/rr-cloudflared/token"
    rr_restore_rollback_claims_cloudflared "$claim_rollback" || {
        echo 'Hash-bound RR Cloudflared rollback claim was not recognized.' >&2
        exit 1
    }
    printf '%s\n' '# changed' >> "$claim_rollback/cloudflared.service"
    if rr_restore_rollback_claims_cloudflared "$claim_rollback"; then
        echo 'Cloudflared rollback claim accepted a changed unit snapshot.' >&2
        exit 1
    fi

    printf '%s\n' '[Unit]' 'Description=administrator tunnel' > \
        "$RR_CLOUDFLARED_SERVICE_FILE"
    chmod 644 "$RR_CLOUDFLARED_SERVICE_FILE"
    fixed_mode=1
    before_service=$(sha256sum "$RR_CLOUDFLARED_SERVICE_FILE")
    before_token=$(sha256sum "$RR_CF_TOKEN_FILE")
    if rr_restore_preflight_cloudflared_target "$ownership_root/imported-token"; then
        echo 'A third-party Cloudflared unit plus leftover RR token was claimed as owned.' >&2
        exit 1
    fi
    [ "$before_service" = "$(sha256sum "$RR_CLOUDFLARED_SERVICE_FILE")" ] && \
        [ "$before_token" = "$(sha256sum "$RR_CF_TOKEN_FILE")" ] || {
            echo 'Cloudflared ownership preflight mutated third-party evidence.' >&2
            exit 1
        }
)
(
    claim_root="$test_root/cloudflared-rollback-claim"
    RR_BACKUP_WORK_DIR="$claim_root/state"
    claim_stage="$RR_BACKUP_WORK_DIR/restore.cloudclaim"
    claim_rollback="$claim_stage/rollback"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$claim_stage" "$claim_rollback"
    printf '%s\n' '[Unit]' > "$claim_rollback/cloudflared.service"
    : > "$claim_rollback/cloudflared_service_was_present"
    chmod 600 "$claim_rollback/cloudflared.service" \
        "$claim_rollback/cloudflared_service_was_present"
    RR_CF_TOKEN_FILE="$claim_root/missing-token"
    TUNNEL_MODE=1
    cloudflared_state=active
    cloudflared_stop_calls=0
    load_config_with_defaults() { TUNNEL_MODE=1; return 1; }
    rr_restore_rollback_claims_cloudflared() {
        [ -f "$1/cloudflared_service_was_present" ]
    }
    rr_restore_fixed_cloudflared_unit_is_owned() {
        [ -f "$claim_rollback/cloudflared_service_was_present" ]
    }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    expected_argo_tunnel_running() { return 1; }
    systemctl() {
        if [ "$*" = 'stop cloudflared' ]; then
            cloudflared_stop_calls=$((cloudflared_stop_calls + 1))
            cloudflared_state=inactive
        fi
        return 0
    }
    rr_restore_unit_activity_matches() {
        if [ "$1" = cloudflared ]; then
            [ "$2" = "$cloudflared_state" ]
        else
            return 0
        fi
    }
    rr_restore_stop_managed_runtime "$claim_rollback" || {
        echo 'Safe rollback plus exact live ownership did not isolate Cloudflared.' >&2
        exit 1
    }
    [ "$cloudflared_stop_calls" -eq 1 ] && \
        [ "$cloudflared_state" = inactive ] || {
            echo 'Rollback Cloudflared marker was not treated as an ownership claim.' >&2
            exit 1
        }

    rm -f "$claim_rollback/cloudflared_service_was_present" \
        "$claim_rollback/cloudflared.service"
    cloudflared_state=active
    cloudflared_stop_calls=0
    rr_restore_stop_managed_runtime "$claim_rollback" || {
        echo 'A safe rollback without a Cloudflared claim failed runtime isolation.' >&2
        exit 1
    }
    [ "$cloudflared_stop_calls" -eq 0 ] && \
        [ "$cloudflared_state" = active ] || {
            echo 'Runtime isolation stopped an unclaimed third-party Cloudflared service.' >&2
            exit 1
        }
)
(
    resume_root="$test_root/cloudflared-resume-ownership"
    RR_BACKUP_WORK_DIR="$resume_root/state"
    resume_stage="$RR_BACKUP_WORK_DIR/restore.resume"
    resume_rollback="$resume_stage/rollback"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$resume_stage" "$resume_rollback"
    RR_CF_TOKEN_FILE="$resume_root/missing-token"
    resume_mode=1
    cloudflared_state=active
    cloudflared_stop_calls=0
    cloudflared_start_calls=0
    load_config_with_defaults() { TUNNEL_MODE="$resume_mode"; return 0; }
    rr_restore_rollback_claims_cloudflared() {
        [ -f "$1/cloudflared_service_was_present" ]
    }
    rr_restore_fixed_cloudflared_unit_is_owned() {
        [ -f "$resume_rollback/cloudflared_service_was_present" ]
    }
    select_entry_ip() { return 0; }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    rr_run_without_inherited_update_lock_fds() { "$@"; }
    start_argo_tunnel() {
        cloudflared_start_calls=$((cloudflared_start_calls + 1))
        cloudflared_state=active
    }
    expected_argo_tunnel_running() { [ "$cloudflared_state" = active ]; }
    systemctl() {
        case "$*" in
            'stop cloudflared')
                cloudflared_stop_calls=$((cloudflared_stop_calls + 1))
                cloudflared_state=inactive
                ;;
        esac
        return 0
    }
    rr_restore_unit_activity_matches() {
        if [ "$1" = cloudflared ]; then
            [ "$2" = "$cloudflared_state" ]
        else
            return 0
        fi
    }

    rr_restore_resume_frozen_writers "$resume_rollback" || {
        echo 'Resume failed while preserving an unclaimed third-party Cloudflared service.' >&2
        exit 1
    }
    [ "$cloudflared_stop_calls" -eq 0 ] && \
        [ "$cloudflared_state" = active ] || {
            echo 'Resume stopped an unclaimed third-party Cloudflared service.' >&2
            exit 1
        }

    printf '%s\n' '[Unit]' > "$resume_rollback/cloudflared.service"
    : > "$resume_rollback/cloudflared_service_was_present"
    chmod 600 "$resume_rollback/cloudflared.service" \
        "$resume_rollback/cloudflared_service_was_present"
    cloudflared_state=active
    cloudflared_stop_calls=0
    rr_restore_resume_frozen_writers "$resume_rollback" || {
        echo 'Resume rejected a safe stopped RR Cloudflared rollback state.' >&2
        exit 1
    }
    [ "$cloudflared_stop_calls" -eq 1 ] && \
        [ "$cloudflared_state" = inactive ] || {
            echo 'Resume did not stop Cloudflared owned by the safe rollback claim.' >&2
            exit 1
        }

    : > "$resume_rollback/argo_was_running"
    chmod 600 "$resume_rollback/argo_was_running"
    resume_mode=2
    cloudflared_state=inactive
    cloudflared_start_calls=0
    rr_restore_resume_frozen_writers "$resume_rollback" || {
        echo 'Resume rejected a safe running RR Cloudflared rollback state.' >&2
        exit 1
    }
    [ "$cloudflared_start_calls" -eq 1 ] && \
        [ "$cloudflared_state" = active ] || {
            echo 'Resume did not restart Cloudflared owned by the safe rollback claim.' >&2
            exit 1
        }

    rm -f "$resume_rollback/cloudflared_service_was_present" \
        "$resume_rollback/cloudflared.service"
    cloudflared_state=inactive
    cloudflared_start_calls=0
    if rr_restore_resume_frozen_writers "$resume_rollback"; then
        echo 'Resume started fixed Cloudflared without an ownership claim or live token.' >&2
        exit 1
    fi
    [ "$cloudflared_start_calls" -eq 0 ] && \
        [ "$cloudflared_state" = inactive ] || {
            echo 'Unclaimed fixed Cloudflared was started despite a failed ownership proof.' >&2
            exit 1
        }
)
(
    nexus_root="$test_root/nexus-final-state"
    NEXUS_CONFIG_FILE="$nexus_root/nexus.json"
    NEXUS_SERVICE_FILE="$nexus_root/rr-nexus.service"
    rollback="$nexus_root/rollback"
    install -d -m 700 "$rollback"
    : > "$NEXUS_CONFIG_FILE"
    : > "$NEXUS_SERVICE_FILE"
    : > "$rollback/target_nexus_was_present"
    nexus_enabled=true
    nexus_running=true
    suppress_start=false
    query_failure=false
    systemctl() {
        case "$*" in
            'enable rr-nexus') nexus_enabled=true ;;
            'disable rr-nexus') nexus_enabled=false ;;
            'start rr-nexus') [ "$suppress_start" = true ] || nexus_running=true ;;
            'stop rr-nexus') nexus_running=false ;;
            'show --property=LoadState --value rr-nexus')
                [ "$query_failure" = false ] || return 91
                printf '%s\n' loaded ;;
            'show --property=ActiveState --value rr-nexus')
                [ "$query_failure" = false ] || return 91
                [ "$nexus_running" = true ] && printf '%s\n' active || printf '%s\n' inactive ;;
            'show --property=UnitFileState --value rr-nexus')
                [ "$query_failure" = false ] || return 91
                [ "$nexus_enabled" = true ] && printf '%s\n' enabled || printf '%s\n' disabled ;;
            *) return 0 ;;
        esac
    }
    rr_restore_finalize_nexus_enablement "$rollback"
    [ "$nexus_enabled" = false ] && [ "$nexus_running" = false ] || {
        echo 'Existing stopped Nexus state was not restored exactly.' >&2
        exit 1
    }
    : > "$rollback/nexus_was_enabled"
    : > "$rollback/nexus_was_running"
    suppress_start=true
    if rr_restore_finalize_nexus_enablement "$rollback"; then
        echo 'Nexus finalizer accepted start success without an active service.' >&2
        exit 1
    fi
    suppress_start=false
    query_failure=true
    if rr_restore_finalize_nexus_enablement "$rollback"; then
        echo 'Nexus finalizer accepted an unprovable final service state.' >&2
        exit 1
    fi
)
restore_body=$(declare -f rr_restore_backup_locked)
preflight_line=$(grep -n 'rr_restore_reject_unrestorable_unit_states' <<<"$restore_body" | cut -d: -f1)
migration_line=$(grep -n 'rr_restore_migrate_legacy_fixed_token' <<<"$restore_body" | cut -d: -f1)
prepare_line=$(grep -n 'rr_restore_prepare_recovery_unit' <<<"$restore_body" | cut -d: -f1)
[[ "$preflight_line" =~ ^[0-9]+$ && "$migration_line" =~ ^[0-9]+$ && \
   "$prepare_line" =~ ^[0-9]+$ ]] && [ "$preflight_line" -lt "$migration_line" ] && \
    [ "$migration_line" -lt "$prepare_line" ] || {
        echo 'Masked-unit preflight no longer precedes every persistent restore mutation.' >&2
        exit 1
    }
(
    cloud_root="$test_root/cloud-activity"
    RR_BACKUP_WORK_DIR="$cloud_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_WATCH_REQUEST="$cloud_root/run/watch-request"
    RR_RESTORE_LIVE_MARKER="$cloud_root/run/live-marker"
    cloud_stage="$RR_BACKUP_WORK_DIR/restore.cloud"
    cloud_rollback="$cloud_stage/rollback"
    install -d -m 700 "$cloud_stage" "$cloud_rollback/rootfs" "$cloud_root/run"
    printf '%s\n' snapshot-v1 > "$cloud_rollback/complete"
    printf '%s\n' '[Unit]' > "$cloud_rollback/cloudflared.service"
    : > "$cloud_rollback/cloudflared_service_was_present"
    : > "$cloud_rollback/cloudflared_was_running"
    chmod 600 "$cloud_rollback/complete" \
        "$cloud_rollback/cloudflared.service" \
        "$cloud_rollback/cloudflared_service_was_present" \
        "$cloud_rollback/cloudflared_was_running"
    rr_restore_write_phase "$cloud_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$cloud_stage"
    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    systemctl() {
        case "$*" in
            'start cloudflared') return 0 ;;
            'show --property=LoadState --value cloudflared') printf '%s\n' loaded ;;
            'show --property=ActiveState --value cloudflared') printf '%s\n' failed ;;
            'show --property=UnitFileState --value cloudflared') printf '%s\n' enabled ;;
            *) return 0 ;;
        esac
    }
    if rr_restore_rollback_stage "$cloud_stage"; then
        echo 'Rollback accepted cloudflared start without active state.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$cloud_stage/phase")" = recovery_failed ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$cloud_stage" ] || {
            echo 'Cloudflared activity mismatch discarded rollback evidence.' >&2
            exit 1
        }
)
if grep -Fq 'systemctl cat cloudflared' modules/55-resilience.sh; then
    echo 'Restore still uses ambiguous systemctl cat absence detection.' >&2
    exit 1
fi
(
    cloud_fail_root="$test_root/cloudflared-apply-failure"
    RR_BACKUP_WORK_DIR="$cloud_fail_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    cloud_fail_stage="$RR_BACKUP_WORK_DIR/restore.cloudapplyfail"
    cloud_fail_rollback="$cloud_fail_stage/rollback"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$cloud_fail_stage" \
        "$cloud_fail_rollback/rootfs"
    printf '%s\n' snapshot-v1 > "$cloud_fail_rollback/complete"
    printf '%s\n' '[Unit]' > "$cloud_fail_rollback/cloudflared.service"
    : > "$cloud_fail_rollback/cloudflared_service_was_present"
    : > "$cloud_fail_rollback/cloudflared_was_running"
    chmod 600 "$cloud_fail_rollback/complete" \
        "$cloud_fail_rollback/cloudflared.service" \
        "$cloud_fail_rollback/cloudflared_service_was_present" \
        "$cloud_fail_rollback/cloudflared_was_running"
    rr_restore_rollback_claims_cloudflared() { return 0; }
    rr_restore_fixed_cloudflared_unit_is_owned() { return 0; }
    rr_restore_write_phase "$cloud_fail_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$cloud_fail_stage"
    cloudflared_state=active
    cloudflared_start_calls=0
    RR_CF_TOKEN_FILE="$cloud_fail_root/missing-token"
    TUNNEL_MODE=1
    load_config_with_defaults() { TUNNEL_MODE=1; return 1; }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    expected_argo_tunnel_running() { return 1; }
    systemctl() {
        case "$*" in
            'stop cloudflared') cloudflared_state=inactive ;;
            'start cloudflared'|'start cloudflared.service')
                cloudflared_start_calls=$((cloudflared_start_calls + 1))
                cloudflared_state=active
                ;;
        esac
        return 0
    }
    rr_restore_unit_activity_matches() {
        if [ "$1" = cloudflared ] || [ "$1" = cloudflared.service ]; then
            [ "$2" = "$cloudflared_state" ]
        else
            return 0
        fi
    }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 1; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    if rr_restore_rollback_stage "$cloud_fail_stage"; then
        echo 'Rollback accepted a failed original-tree replay.' >&2
        exit 1
    fi
    [ "$cloudflared_start_calls" -eq 0 ] && \
        [ "$cloudflared_state" = inactive ] && \
        [ "$(rr_restore_read_exact_marker "$cloud_fail_stage/phase")" = recovery_failed ] || {
            echo 'Failed tree replay started or retained Cloudflared.' >&2
            exit 1
        }
)
(
    cloud_start_root="$test_root/cloudflared-start-failure"
    RR_BACKUP_WORK_DIR="$cloud_start_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    cloud_start_stage="$RR_BACKUP_WORK_DIR/restore.cloudstartfail"
    cloud_start_rollback="$cloud_start_stage/rollback"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$cloud_start_stage" \
        "$cloud_start_rollback/rootfs"
    printf '%s\n' snapshot-v1 > "$cloud_start_rollback/complete"
    printf '%s\n' '[Unit]' > "$cloud_start_rollback/cloudflared.service"
    : > "$cloud_start_rollback/cloudflared_service_was_present"
    : > "$cloud_start_rollback/cloudflared_was_running"
    chmod 600 "$cloud_start_rollback/complete" \
        "$cloud_start_rollback/cloudflared.service" \
        "$cloud_start_rollback/cloudflared_service_was_present" \
        "$cloud_start_rollback/cloudflared_was_running"
    rr_restore_rollback_claims_cloudflared() { return 0; }
    rr_restore_fixed_cloudflared_unit_is_owned() { return 0; }
    rr_restore_write_phase "$cloud_start_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$cloud_start_stage"
    cloudflared_state=active
    cloudflared_start_calls=0
    cloudflared_stop_calls=0
    RR_CF_TOKEN_FILE="$cloud_start_root/missing-token"
    TUNNEL_MODE=1
    load_config_with_defaults() { TUNNEL_MODE=1; return 1; }
    stop_subscription_servers() { return 0; }
    subscription_server_running() { return 1; }
    stop_quick_argo_tunnel() { return 0; }
    expected_argo_tunnel_running() { return 1; }
    systemctl() {
        case "$*" in
            'stop cloudflared')
                cloudflared_stop_calls=$((cloudflared_stop_calls + 1))
                cloudflared_state=inactive
                return 0
                ;;
            'start cloudflared'|'start cloudflared.service')
                cloudflared_start_calls=$((cloudflared_start_calls + 1))
                cloudflared_state=active
                return 71
                ;;
        esac
        return 0
    }
    rr_restore_unit_activity_matches() {
        if [ "$1" = cloudflared ] || [ "$1" = cloudflared.service ]; then
            [ "$2" = "$cloudflared_state" ]
        else
            return 0
        fi
    }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    if rr_restore_rollback_stage "$cloud_start_stage"; then
        echo 'Rollback accepted a failed Cloudflared start.' >&2
        exit 1
    fi
    [ "$cloudflared_start_calls" -eq 1 ] && \
        [ "$cloudflared_stop_calls" -ge 2 ] && \
        [ "$cloudflared_state" = inactive ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] || {
            echo 'A start failure that left Cloudflared active was not re-isolated.' >&2
            exit 1
        }
)
[ "$(grep -c 'rr_restore_fixed_cloudflared_unit_is_owned' \
    modules/55-resilience.sh)" -ge 8 ]

printf '%s\n' '[7/9] signal rollback clears portable mode and empty-target mode is explicit'
rollback_scope_body=$(declare -f rr_restore_rollback_stage)
restore_scope_body=$(declare -f rr_restore_backup_locked)
restore_scope_contract_is_exact() {
    local rollback_code="$1" restore_code="$2"
    [[ "$rollback_code" == *'RR_PORTABLE_RESTORE=0 RR_PORTABLE_UFW_AUTHORITY=0 rr_restore_migrate_with_original_state "$rollback"'* ]] &&
        [[ "$restore_code" == *'RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" post_update_migrate'* ]]
}
restore_scope_contract_is_exact "$rollback_scope_body" "$restore_scope_body" || {
    echo 'Restore lost an explicit rollback or empty-target environment boundary.' >&2
    exit 1
}
rollback_scope_mutation="${rollback_scope_body/RR_PORTABLE_RESTORE=0 /}"
if restore_scope_contract_is_exact "$rollback_scope_mutation" "$restore_scope_body"; then
    echo 'Restore scope contract accepted deletion of the rollback portable-mode reset.' >&2
    exit 1
fi
rollback_ufw_scope_mutation="${rollback_scope_body/RR_PORTABLE_UFW_AUTHORITY=0 /}"
if restore_scope_contract_is_exact "$rollback_ufw_scope_mutation" "$restore_scope_body"; then
    echo 'Restore scope contract accepted deletion of the rollback UFW-authority reset.' >&2
    exit 1
fi
empty_target_scope_mutation="${restore_scope_body/RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 RR_PORTABLE_UFW_AUTHORITY=\"\$portable_ufw_authority\" post_update_migrate/RR_PORTABLE_RESTORE=1 RR_PORTABLE_UFW_AUTHORITY=\"\$portable_ufw_authority\" post_update_migrate}"
if restore_scope_contract_is_exact "$rollback_scope_body" "$empty_target_scope_mutation"; then
    echo 'Restore scope contract accepted deletion of the empty-target transaction reset.' >&2
    exit 1
fi
empty_target_ufw_scope_mutation="${restore_scope_body/RR_PORTABLE_UFW_AUTHORITY=\"\$portable_ufw_authority\" post_update_migrate/post_update_migrate}"
if restore_scope_contract_is_exact "$rollback_scope_body" "$empty_target_ufw_scope_mutation"; then
    echo 'Restore scope contract accepted deletion of the portable UFW-authority boundary.' >&2
    exit 1
fi
(
    scope_root="$test_root/signal-portable-scope"
    RR_BACKUP_WORK_DIR="$scope_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_WATCH_REQUEST="$scope_root/watch-request"
    RR_RESTORE_LIVE_MARKER="$scope_root/live-marker"
    scope_stage="$RR_BACKUP_WORK_DIR/restore.signal"
    scope_rollback="$scope_stage/rollback"
    portable_branch="$scope_root/portable-certificate-branch"
    original_hook_branch="$scope_root/original-hook-branch"
    migration_environment="$scope_root/migration-environment"
    RR_LE_LIVE_ROOT="$scope_root/letsencrypt/live"
    NAIVE_ENABLED=true
    NAIVE_DOMAIN=rollback-naive.invalid
    LE_EMAIL=""
    install -d -m 700 "$scope_root" "$RR_BACKUP_WORK_DIR" "$scope_stage" \
        "$scope_rollback" "$scope_rollback/rootfs" \
        "$scope_rollback/rootfs/etc/rr-naive" "$RR_LE_LIVE_ROOT"
    printf '%s\n' snapshot-v1 > "$scope_rollback/complete"
    : > "$scope_rollback/target_rr_was_present"
    chmod 600 "$scope_rollback/complete" "$scope_rollback/target_rr_was_present"
    rr_restore_write_phase "$scope_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$scope_stage"

    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    ensure_naive_certificate() {
        : > "$portable_branch"
        return 91
    }
    deploy_naive_cert_hook() {
        : > "$original_hook_branch"
    }
    post_update_migrate() {
        printf 'portable=%s transaction=%s lineage=%s\n' \
            "${RR_PORTABLE_RESTORE:-unset}" "${RR_UPDATE_TRANSACTION:-unset}" \
            "$([ -e "$RR_LE_LIVE_ROOT/$NAIVE_DOMAIN" ] && printf present || printf absent)" \
            > "$migration_environment"
        [ "$NAIVE_ENABLED" = true ] || return 92
        if [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then
            ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL"
        else
            deploy_naive_cert_hook
        fi
    }

    # TERM/HUP/INT traps execute in the same Bash process and therefore can
    # inherit this dynamic function-call environment.  Calling rollback under
    # the same scope directly makes the regression deterministic.
    RR_PORTABLE_RESTORE=1 rr_restore_rollback_stage "$scope_stage"
    [ -f "$original_hook_branch" ] && [ ! -e "$portable_branch" ] &&
        [ "$(cat "$migration_environment")" = \
          'portable=0 transaction=1 lineage=absent' ] || {
            echo 'Signal-style rollback inherited portable restore mode or lost transaction mode.' >&2
            exit 1
        }
)

printf '%s\n' '[8/9] terminal phases are durable and can never cross back into rollback'
(
    terminal_root="$test_root/terminal"
    RR_BACKUP_WORK_DIR="$terminal_root/state"
    RR_RESTORE_ACTIVE="$terminal_root/active/active"
    RR_RESTORE_RUNTIME_READY="$terminal_root/ready/runtime-ready"
    RR_RESTORE_WATCH_REQUEST="$terminal_root/watch/watch-request"
    RR_RESTORE_LIVE_MARKER="$terminal_root/live/live-marker"
    terminal_stage="$RR_BACKUP_WORK_DIR/restore.commit"
    terminal_other="$RR_BACKUP_WORK_DIR/restore.other"
    install -d -m 700 "$terminal_stage" "$terminal_other" \
        "$(dirname "$RR_RESTORE_ACTIVE")" "$(dirname "$RR_RESTORE_RUNTIME_READY")" \
        "$(dirname "$RR_RESTORE_WATCH_REQUEST")" "$(dirname "$RR_RESTORE_LIVE_MARKER")"
    rr_restore_write_phase "$terminal_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$terminal_stage"

    sync() {
        if [ "${1:-}" = -f ] && [[ "${2:-}" == */.rr-restore-marker.* ]]; then
            return 1
        fi
        command sync "$@"
    }
    if rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$terminal_other"; then
        echo 'Marker publication accepted a failed temporary-file fsync.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$terminal_stage" ] || {
        echo 'Failed marker temp fsync replaced the old durable marker.' >&2
        exit 1
    }
    unset -f sync

    sync() {
        if [ "${1:-}" = -f ] && [[ "${2:-}" == */.phase.* ]]; then
            return 1
        fi
        command sync "$@"
    }
    if rr_restore_write_phase "$terminal_stage" committed; then
        echo 'Phase publication accepted a failed temporary-file fsync.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$terminal_stage/phase")" = migrating ] || {
        echo 'Failed phase temp fsync replaced the old durable phase.' >&2
        exit 1
    }
    unset -f sync

    sync() {
        [ "$#" -ne 0 ] && command sync "$@" && return
        return 1
    }
    set +e
    rr_restore_commit_candidate "$terminal_stage"
    commit_status=$?
    set -e
    [ "$commit_status" -eq 1 ] && \
        [ "$(rr_restore_read_exact_marker "$terminal_stage/phase")" = migrating ] || {
            echo 'Pre-commit global sync failure crossed the commit boundary.' >&2
            exit 1
        }
    unset -f sync

    sync() {
        [ "$#" -eq 0 ] && return 0
        if [ "${1:-}" = -f ] && [ "${2:-}" = "$terminal_stage" ]; then
            return 1
        fi
        command sync "$@"
    }
    set +e
    rr_restore_commit_candidate "$terminal_stage"
    commit_status=$?
    set -e
    [ "$commit_status" -eq 2 ] && \
        [ "$(rr_restore_read_exact_marker "$terminal_stage/phase")" = committed ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$terminal_stage" ] || {
            echo 'Post-rename phase fsync failure remained rollback-eligible.' >&2
            exit 1
        }
    unset -f sync

    # Wrap only marker operations so every finalizer failure point and the
    # active-last ordering are exercised with the production phase primitive.
    eval "$(declare -f rr_restore_publish_marker | \
        sed '1s/^rr_restore_publish_marker/rr_test_real_publish_marker/')"
    eval "$(declare -f rr_restore_clear_marker | \
        sed '1s/^rr_restore_clear_marker/rr_test_real_clear_marker/')"
    marker_log="$terminal_root/marker-order"
    fail_marker=""
    rr_restore_publish_marker() {
        printf 'publish:%s\n' "$1" >> "$marker_log"
        rr_test_real_publish_marker "$@"
    }
    rr_restore_clear_marker() {
        printf 'clear:%s\n' "$1" >> "$marker_log"
        [ "$1" != "$fail_marker" ] || return 1
        rr_test_real_clear_marker "$@"
    }
    reset_terminal_case() {
        command rm -f -- "$RR_RESTORE_ACTIVE" "$RR_RESTORE_RUNTIME_READY" \
            "$RR_RESTORE_WATCH_REQUEST" "$RR_RESTORE_LIVE_MARKER" "$marker_log"
        rr_restore_write_phase "$terminal_stage" committed
        rr_test_real_publish_marker "$RR_RESTORE_ACTIVE" "$terminal_stage"
        rr_test_real_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$terminal_stage"
        rr_test_real_publish_marker "$RR_RESTORE_LIVE_MARKER" "$terminal_stage"
    }
    for fail_marker in "$RR_RESTORE_WATCH_REQUEST" "$RR_RESTORE_LIVE_MARKER" \
        "$RR_RESTORE_RUNTIME_READY" "$RR_RESTORE_ACTIVE"; do
        reset_terminal_case
        if rr_restore_finalize_terminal_stage "$terminal_stage"; then
            echo "Terminal finalizer ignored marker failure: $fail_marker" >&2
            exit 1
        fi
        [ "$(rr_restore_read_exact_marker "$terminal_stage/phase")" = committed ] && \
            [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$terminal_stage" ] || {
                echo "Terminal marker failure discarded committed evidence: $fail_marker" >&2
                exit 1
            }
    done

    fail_marker=""
    reset_terminal_case
    rr_restore_finalize_terminal_stage "$terminal_stage"
    expected_order=$(printf '%s\n' \
        "publish:$RR_RESTORE_RUNTIME_READY" \
        "clear:$RR_RESTORE_WATCH_REQUEST" \
        "clear:$RR_RESTORE_LIVE_MARKER" \
        "clear:$RR_RESTORE_RUNTIME_READY" \
        "clear:$RR_RESTORE_ACTIVE")
    [ "$(cat "$marker_log")" = "$expected_order" ] || {
        echo 'Terminal marker cleanup is not active-last.' >&2
        exit 1
    }
    [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -e "$RR_RESTORE_RUNTIME_READY" ] || {
        echo 'Successful terminal finalization retained a critical marker.' >&2
        exit 1
    }
)
(
    isolation_root="$test_root/terminal-isolation"
    RR_BACKUP_WORK_DIR="$isolation_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    RR_RESTORE_WATCH_REQUEST="$isolation_root/watch-request"
    RR_RESTORE_LIVE_MARKER="$isolation_root/live-marker"
    isolation_stage="$RR_BACKUP_WORK_DIR/restore.rollback"
    isolation_rollback="$isolation_stage/rollback"
    install -d -m 700 "$isolation_stage" "$isolation_rollback/rootfs"
    printf '%s\n' snapshot-v1 > "$isolation_rollback/complete"
    chmod 600 "$isolation_rollback/complete"
    rr_restore_write_phase "$isolation_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$isolation_stage"
    eval "$(declare -f rr_restore_clear_marker | \
        sed '1s/^rr_restore_clear_marker/rr_test_isolation_clear_marker/')"
    isolation_stop_calls=0
    snapshot_refreeze_calls=0
    isolation_bad_order=false
    isolation_order_log="$isolation_root/isolation-order.log"
    rr_restore_clear_marker() {
        if [ "$1" = "$RR_RESTORE_RUNTIME_READY" ]; then
            printf '%s\n' clear-ready >> "$isolation_order_log"
        fi
        rr_test_isolation_clear_marker "$@"
    }
    rr_restore_stop_managed_runtime() {
        isolation_stop_calls=$((isolation_stop_calls + 1))
        if [ -e "$RR_RESTORE_RUNTIME_READY" ] || [ -L "$RR_RESTORE_RUNTIME_READY" ]; then
            isolation_bad_order=true
            printf '%s\n' stop-ready-present >> "$isolation_order_log"
        else
            printf '%s\n' stop-isolated >> "$isolation_order_log"
        fi
        nginx_active=false
        return 0
    }
    rr_restore_freeze_writers() {
        snapshot_refreeze_calls=$((snapshot_refreeze_calls + 1))
        if [ -e "$RR_RESTORE_RUNTIME_READY" ] || [ -L "$RR_RESTORE_RUNTIME_READY" ]; then
            isolation_bad_order=true
            printf '%s\n' refreeze-ready-present >> "$isolation_order_log"
        else
            printf '%s\n' writers-refrozen >> "$isolation_order_log"
        fi
        return 0
    }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_migrate_with_original_state() { return 0; }
    sync() {
        [ "$#" -gt 0 ] && command sync "$@" && return
        return 1
    }
    if rr_restore_rollback_stage "$isolation_stage"; then
        echo 'Rollback accepted a failed terminal durability barrier.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$isolation_stage/phase")" = rolling_back ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$isolation_stage" ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] || {
            echo 'Failed rollback terminal publication left the service gate open.' >&2
            exit 1
        }
    [ "$isolation_stop_calls" -eq 2 ] && [ "$isolation_bad_order" = false ] || {
        echo 'Rollback terminal failure did not clear READY before re-isolating services.' >&2
        exit 1
    }

    abort_stage="$RR_BACKUP_WORK_DIR/restore.abort"
    install -d -m 700 "$abort_stage" "$abort_stage/rollback"
    rr_restore_write_phase "$abort_stage" prepared
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$abort_stage"
    rr_restore_resume_snapshot_writers() { return 0; }
    if rr_restore_abort_pre_mutation_stage "$abort_stage"; then
        echo 'Abort accepted a failed terminal durability barrier.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$abort_stage/phase")" = prepared ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$abort_stage" ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] || {
            echo 'Failed abort terminal publication left the service gate open.' >&2
            exit 1
        }
    [ "$isolation_stop_calls" -eq 2 ] && [ "$snapshot_refreeze_calls" -eq 1 ] && \
        [ "$isolation_bad_order" = false ] || {
        echo 'Abort terminal failure did not clear READY before refreezing writers.' >&2
        exit 1
    }

    resume_stage="$RR_BACKUP_WORK_DIR/restore.resumefailure"
    install -d -m 700 "$resume_stage" "$resume_stage/rollback"
    rr_restore_write_phase "$resume_stage" frozen
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$resume_stage"
    rr_restore_resume_snapshot_writers() { return 1; }
    if rr_restore_abort_pre_mutation_stage "$resume_stage"; then
        echo 'Abort accepted a writer-resume failure.' >&2
        exit 1
    fi
    [ "$(rr_restore_read_exact_marker "$resume_stage/phase")" = pre_recovery_failed ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$resume_stage" ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
        [ "$isolation_stop_calls" -eq 2 ] && \
        [ "$snapshot_refreeze_calls" -eq 2 ] && \
        [ "$isolation_bad_order" = false ] || {
            echo 'Writer-resume failure did not fail closed behind a cleared READY gate.' >&2
            exit 1
        }

    # Exercise the late branch after Nginx has crossed READY.  A firewall proof
    # failure must stop it again, retain ACTIVE evidence, and publish the
    # recovery_failed phase.
    late_stage="$RR_BACKUP_WORK_DIR/restore.latefailure"
    late_rollback="$late_stage/rollback"
    install -d -m 700 "$late_stage" "$late_rollback/rootfs"
    printf '%s\n' snapshot-v1 > "$late_rollback/complete"
    chmod 600 "$late_rollback/complete"
    rr_restore_write_phase "$late_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$late_stage"
    rr_restore_restore_nginx() {
        [ "${2:-}" != activate ] || nginx_active=true
        return 0
    }
    rr_restore_verify_firewall_snapshot() { return 1; }
    sync() {
        if [ "$#" -gt 0 ]; then
            command sync "$@"
        else
            return 0
        fi
    }
    isolation_stop_calls=0
    isolation_bad_order=false
    nginx_active=false
    if rr_restore_rollback_stage "$late_stage"; then
        echo 'Rollback accepted a late firewall verification failure.' >&2
        exit 1
    fi
    [ "$nginx_active" = false ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
        [ "$(rr_restore_read_exact_marker "$late_stage/phase")" = recovery_failed ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$late_stage" ] && \
        [ "$isolation_stop_calls" -eq 2 ] && \
        [ "$isolation_bad_order" = false ] || {
            echo 'Late rollback failure left Nginx exposed or discarded recovery evidence.' >&2
            exit 1
    }
)

(
    phase_fail_root="$test_root/rollback-phase-write-failure"
    RR_BACKUP_WORK_DIR="$phase_fail_root/state"
    RR_RESTORE_ACTIVE="$RR_BACKUP_WORK_DIR/active"
    RR_RESTORE_RUNTIME_READY="$RR_BACKUP_WORK_DIR/runtime-ready"
    phase_fail_stage="$RR_BACKUP_WORK_DIR/restore.phasefail"
    phase_fail_rollback="$phase_fail_stage/rollback"
    install -d -m 700 "$RR_BACKUP_WORK_DIR" "$phase_fail_stage" \
        "$phase_fail_rollback/rootfs"
    printf '%s\n' snapshot-v1 > "$phase_fail_rollback/complete"
    printf '%s\n' '[Unit]' > "$phase_fail_rollback/cloudflared.service"
    : > "$phase_fail_rollback/cloudflared_service_was_present"
    chmod 600 "$phase_fail_rollback/complete" \
        "$phase_fail_rollback/cloudflared.service" \
        "$phase_fail_rollback/cloudflared_service_was_present"
    rr_restore_write_phase "$phase_fail_stage" migrating
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$phase_fail_stage"
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$phase_fail_stage"

    reset_phase_failure_states() {
        singbox_active=true
        nexus_active=true
        nginx_active=true
        health_timer_active=true
        health_service_active=true
        subscription_active=true
        quick_argo_active=true
        cloudflared_state=active
        cloudflared_stop_calls=0
    }
    reset_phase_failure_states
    load_config_with_defaults() { TUNNEL_MODE=1; return 0; }
    rr_restore_rollback_claims_cloudflared() {
        [ -f "$1/cloudflared_service_was_present" ]
    }
    rr_restore_fixed_cloudflared_unit_is_owned() {
        [ -f "$phase_fail_rollback/cloudflared_service_was_present" ]
    }
    stop_subscription_servers() { subscription_active=false; }
    subscription_server_running() { [ "$subscription_active" = true ]; }
    stop_quick_argo_tunnel() { quick_argo_active=false; }
    expected_argo_tunnel_running() { [ "$quick_argo_active" = true ]; }
    systemctl() {
        case "$*" in
            'stop rr-nexus sing-box nginx')
                nexus_active=false
                singbox_active=false
                nginx_active=false
                ;;
            'stop argo-rr-health.timer argo-rr-health.service')
                health_timer_active=false
                health_service_active=false
                ;;
            'stop cloudflared')
                cloudflared_stop_calls=$((cloudflared_stop_calls + 1))
                cloudflared_state=inactive
                ;;
        esac
        return 0
    }
    rr_restore_unit_activity_matches() {
        local actual=false
        case "$1" in
            sing-box) actual="$singbox_active" ;;
            rr-nexus) actual="$nexus_active" ;;
            nginx) actual="$nginx_active" ;;
            argo-rr-health.timer) actual="$health_timer_active" ;;
            argo-rr-health.service) actual="$health_service_active" ;;
            cloudflared) actual="$cloudflared_state" ;;
            *) return 1 ;;
        esac
        case "$2:$actual" in
            active:true|active:active|inactive:false|inactive:inactive) return 0 ;;
            *) return 1 ;;
        esac
    }
    eval "$(declare -f rr_restore_write_phase | \
        sed '1s/^rr_restore_write_phase/rr_test_real_write_phase/')"
    rr_restore_write_phase() {
        [ "${2:-}" != rolling_back ] || return 1
        rr_test_real_write_phase "$@"
    }

    if rr_restore_rollback_stage "$phase_fail_stage"; then
        echo 'Rollback accepted a failed rolling_back phase publication.' >&2
        exit 1
    fi
    [ "$singbox_active" = false ] && [ "$nexus_active" = false ] && \
        [ "$nginx_active" = false ] && [ "$health_timer_active" = false ] && \
        [ "$health_service_active" = false ] && \
        [ "$cloudflared_state" = inactive ] && \
        [ "$cloudflared_stop_calls" -eq 1 ] && \
        [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
        [ "$(rr_restore_read_exact_marker "$phase_fail_stage/phase")" = migrating ] && \
        [ "$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE")" = "$phase_fail_stage" ] || {
            echo 'Phase-write failure did not isolate every claimed managed runtime or retain evidence.' >&2
            exit 1
        }

    rm -f "$phase_fail_rollback/cloudflared_service_was_present" \
        "$phase_fail_rollback/cloudflared.service"
    reset_phase_failure_states
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$phase_fail_stage"
    if rr_restore_rollback_stage "$phase_fail_stage"; then
        echo 'Rollback accepted a second failed rolling_back phase publication.' >&2
        exit 1
    fi
    [ "$singbox_active" = false ] && [ "$nexus_active" = false ] && \
        [ "$nginx_active" = false ] && [ "$health_timer_active" = false ] && \
        [ "$health_service_active" = false ] && \
        [ "$cloudflared_state" = active ] && \
        [ "$cloudflared_stop_calls" -eq 0 ] || {
            echo 'Phase-write failure stopped an unclaimed third-party Cloudflared service.' >&2
            exit 1
        }
)

printf '%s\n' '[9/9] SIGKILL releases the lock and dispatches phase rollback'
sigkill_state="$test_root/sigkill-state"
sigkill_run="$test_root/sigkill-run"
sigkill_lock="$sigkill_run/rr-update.lock"
sigkill_legacy_lock="$sigkill_run/legacy-rr-update.lock"
sigkill_bridge="$sigkill_run/legacy-update-bridge"
sigkill_active="$sigkill_state/active"
sigkill_ready="$sigkill_state/runtime-ready"
sigkill_live="$sigkill_run/restore-live"
sigkill_request="$sigkill_run/restore-watch-request"
sigkill_live_lock="$sigkill_run/rr-restore-live.lock"
sigkill_stage="$sigkill_state/restore.crash"
sigkill_started="$test_root/sigkill-started"
sigkill_recovered="$test_root/sigkill-recovered"
install -d -m 700 "$sigkill_stage" "$sigkill_run"
mkdir -p "$sigkill_stage/rollback/rootfs"
printf '%s\n' snapshot-v1 > "$sigkill_stage/rollback/complete"
printf '%s\n' mutating > "$sigkill_stage/phase"
printf '%s\n' "$sigkill_stage" > "$sigkill_active"
chmod 600 "$sigkill_stage/rollback/complete" "$sigkill_stage/phase" "$sigkill_active"

RR_BACKUP_WORK_DIR="$sigkill_state" \
RR_RESTORE_LOCK_FILE="$sigkill_lock" \
RR_LEGACY_UPDATE_LOCK_FILE="$sigkill_legacy_lock" \
RR_LEGACY_UPDATE_BRIDGE_FILE="$sigkill_bridge" \
RR_RESTORE_LIVE_LOCK_FILE="$sigkill_live_lock" \
RR_RESTORE_LIVE_MARKER="$sigkill_live" \
RR_RESTORE_WATCH_REQUEST="$sigkill_request" \
RR_TEST_FAULTS=1 RR_TEST_CRASH_PHASE=mutating \
bash -c '
    source modules/10-system.sh
    source modules/55-resilience.sh
    exec 9>"$RR_RESTORE_LOCK_FILE"
    flock 9
    touch "$1"
    sleep 0.5
    rr_restore_test_phase mutating
' _ "$sigkill_started" &
crash_pid=$!
for _attempt in $(seq 1 40); do
    [ -f "$sigkill_started" ] && break
    sleep 0.05
done
[ -f "$sigkill_started" ] || { echo 'Crash fixture did not acquire the lock.' >&2; exit 1; }

(
    RR_BACKUP_WORK_DIR="$sigkill_state"
    RR_RESTORE_ACTIVE="$sigkill_active"
    RR_RESTORE_RUNTIME_READY="$sigkill_ready"
    RR_RESTORE_LOCK_FILE="$sigkill_lock"
    RR_LEGACY_UPDATE_LOCK_FILE="$sigkill_legacy_lock"
    RR_LEGACY_UPDATE_BRIDGE_FILE="$sigkill_bridge"
    RR_RESTORE_LIVE_LOCK_FILE="$sigkill_live_lock"
    RR_RESTORE_LIVE_MARKER="$sigkill_live"
    RR_RESTORE_WATCH_REQUEST="$sigkill_request"
    RR_RESTORE_WATCH_TIMEOUT=5
    rr_restore_stop_managed_runtime() { return 0; }
    rr_restore_set_nexus_enablement() { return 0; }
    rr_restore_remove_managed_fixed_tunnel() { return 0; }
    rr_restore_clear_derived_state() { return 0; }
    rr_restore_clear_managed_tree() { return 0; }
    rr_restore_apply_tree() { return 0; }
    rr_refresh_update_channel_constants() { return 0; }
    rr_restore_crontab() { return 0; }
    rr_restore_regenerate_runtime_files() { return 0; }
    rr_restore_require_effective_gates_or_isolate() { return 0; }
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
    rr_restore_verify_firewall_snapshot() { return 0; }
    rr_restore_restore_nexus_enablement() { return 0; }
    rr_restore_activate_nginx_state() { return 0; }
    rr_restore_migrate_with_original_state() {
        printf '%s\n' recovered > "$sigkill_recovered"
    }
    rr_restore_watch_active
) &
sigkill_watcher_pid=$!
if wait "$crash_pid"; then
    echo 'Fault injection process unexpectedly survived SIGKILL.' >&2
    exit 1
else
    crash_status=$?
    [ "$crash_status" -eq 137 ] || {
        echo "Unexpected crash exit status: $crash_status" >&2
        exit 1
    }
fi
wait "$sigkill_watcher_pid"
[ -s "$sigkill_recovered" ] || { echo 'SIGKILL did not dispatch rollback.' >&2; exit 1; }
[ ! -e "$sigkill_active" ] || { echo 'Recovered SIGKILL transaction stayed active.' >&2; exit 1; }
[ ! -e "$sigkill_stage" ] || { echo 'Recovered SIGKILL stage was not removed.' >&2; exit 1; }

printf '%s\n' 'restore watchdog regressions passed'
