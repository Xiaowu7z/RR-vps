#!/bin/bash
# Standalone RR-vps transaction recovery.  The core installer copies this file
# outside the replaceable runtime before it starts mutating /usr/local/lib/rr.

set -u

RR_TX_ROOT="${RR_TX_ROOT:-/var/lib/rr-update}"
RR_ACTIVE_TX="${RR_ACTIVE_TX:-${RR_TX_ROOT}/active}"
RR_LIB_DIR="${RR_LIB_DIR:-/usr/local/lib/rr}"
RR_LAUNCHER="${RR_LAUNCHER:-/usr/local/bin/rr}"
RR_CONFIG_FILE="${RR_CONFIG_FILE:-/etc/argo_vmess.conf}"
RR_SUBSCRIPTION_SAFE_VERSION="7.1.1"
RR_POST_UPDATE_FINALIZE_VERSION="7.1.1"
RR_QUARANTINE_FILE="${RR_QUARANTINE_FILE:-${RR_TX_ROOT}/subscription-quarantine}"
RR_QUARANTINE_UNIT="${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}"
RR_QUARANTINE_READY="${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}"
RR_QUARANTINE_GUARD_STATE="${RR_QUARANTINE_GUARD_STATE:-/var/lib/rr-quarantine/guard-state}"
RR_QUARANTINE_GUARD_SELF="${RR_QUARANTINE_GUARD_SELF:-/usr/local/libexec/rr-vps/subscription-quarantine-guard}"
RR_RECOVERY_SELF="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"
RR_UPDATE_EXTERNAL_HELPER="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
RR_IPV6_STATE_FILE="${RR_IPV6_STATE_FILE:-/proc/net/if_inet6}"
RR_HEALTH_SERVICE_FILE="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
RR_HEALTH_TIMER_FILE="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
RR_HEALTH_RESTART_HELPER="${RR_HEALTH_RESTART_HELPER:-/usr/local/bin/auto_update_sub.py}"
RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"
RR_LEGACY_UPDATE_LOCK_FILE="${RR_LEGACY_UPDATE_LOCK_FILE:-/run/lock/rr-update.lock}"
RR_LEGACY_UPDATE_BRIDGE_FILE="${RR_LEGACY_UPDATE_BRIDGE_FILE:-/run/rr-vps/legacy-update-bridge}"
RR_UPDATE_MAINTENANCE_FILE="${RR_UPDATE_MAINTENANCE_FILE:-/run/rr-vps/update-maintenance}"
RR_COMMITTED_SETTLED_NAME="committed-settled"
RR_COMMITTED_SETTLED_VALUE="rr-update-committed-settled-v1"
RR_QUARANTINE_COMMENT="rr-vps unsafe rollback subscription quarantine"
RR_UPDATE_RECOVERY_LOCK_FD=""
RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""

rr_recover_log() {
    printf '[RR-vps recovery] %s\n' "$*" >&2
    logger -t rr-update-recovery "$*" 2>/dev/null || true
}

rr_close_inherited_recovery_lock_fds() {
    local lock_fd=""
    lock_fd="${RR_UPDATE_RECOVERY_LOCK_FD:-}"
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        exec {lock_fd}>&-
    fi
    RR_UPDATE_RECOVERY_LOCK_FD=""
    lock_fd="${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}"
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        exec {lock_fd}>&-
    fi
    RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""
}

rr_run_delegated_without_lock_fds() (
    local deadline="$1"
    shift
    rr_close_inherited_recovery_lock_fds
    if [ "$deadline" = 0 ]; then
        env RR_UPDATE_LOCK_HELD=1 "$@"
    else
        timeout --kill-after=5 "$deadline" env RR_UPDATE_LOCK_HELD=1 "$@"
    fi
)

rr_prepare_update_lock_file() {
    local lock_file="$1" lock_dir="" canonical=""
    lock_dir=$(dirname -- "$lock_file") || return 1
    if [ -e "$lock_dir" ] || [ -L "$lock_dir" ]; then
        [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
        [ "$(stat -c %u:%g -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    else
        mkdir -p -- "$lock_dir" || return 1
    fi
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] || return 1
    [ "$(stat -c %u:%g -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    chmod 0700 -- "$lock_dir" || return 1
    [ "$(stat -c %a -- "$lock_dir" 2>/dev/null)" = 700 ] || return 1
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
    fi
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    [ "$(stat -c %u:%h -- "$lock_file" 2>/dev/null)" = "0:1" ] || return 1
    chown 0:0 -- "$lock_file" || return 1
    chmod 0600 -- "$lock_file" || return 1
    [ "$(stat -c %u:%g:%a:%h -- "$lock_file" 2>/dev/null)" = "0:0:600:1" ]
}

rr_legacy_update_lock_mode_is_safe() {
    local mode="$1" mode_value=0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    # 7.1.0 normally left this inode as 0644. Preserve safe existing metadata,
    # but reject special/execute bits and group/other write access.
    (( (mode_value & 07133) == 0 ))
}

rr_legacy_update_lock_parent_mode_is_safe() {
    local mode="$1" mode_value=0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    # setuid/setgid are never expected on a lock directory. A world-writable
    # compatibility directory is acceptable only with the sticky bit (the
    # historical /run/lock contract).
    (( (mode_value & 06000) == 0 )) || return 1
    if (( (mode_value & 0002) != 0 )); then
        (( (mode_value & 01000) != 0 )) || return 1
    fi
}

rr_legacy_update_lock_path_is_safe() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    local owner_uid="" owner_gid="" mode="" links=""
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    IFS=: read -r owner_uid owner_gid mode links < <(
        stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null
    ) || return 1
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] && [ "$links" = 1 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_legacy_update_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" path_identity_after=""
    local fd_identity="" owner_uid="" owner_gid="" mode="" links=""
    local shell_pid="${BASHPID:-$$}" fd_path=""
    fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    rr_legacy_update_lock_path_is_safe "$lock_file" || return 1
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ -f "$fd_path" ] || return 1
    [ ! -L "$lock_file" ] || return 1
    path_identity_after=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] &&
        [ "$path_identity_after" = "$fd_identity" ] || return 1
    IFS=: read -r _ _ owner_uid owner_gid mode links <<<"$fd_identity"
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] && [ "$links" = 1 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_acquire_legacy_update_lock() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}" create_if_absent="${2:-existing-only}"
    local lock_dir="" canonical="" parent_mode=""
    [ -z "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ] || return 0
    case "$create_if_absent" in existing-only|create) ;; *) return 1 ;; esac
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        if [ "$create_if_absent" = existing-only ]; then
            # Standalone recovery normally bridges only a surviving same-boot
            # 7.1.0 lock. Conditional rollback below owns the only safe create.
            return 0
        fi
    fi
    lock_dir=$(dirname -- "$lock_file") || return 1
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    parent_mode=$(stat -c '%a' -- "$lock_dir" 2>/dev/null) || return 1
    rr_legacy_update_lock_parent_mode_is_safe "$parent_mode" || return 1
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] || return 1
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
    fi
    rr_legacy_update_lock_path_is_safe "$lock_file" || {
        rr_recover_log "unsafe 7.1.0 compatibility update lock"
        return 1
    }
    # Never truncate, chmod, chown, replace, or unlink an existing legacy
    # inode. Read-only open is sufficient for flock and preserves 0644 files.
    exec {RR_UPDATE_RECOVERY_LEGACY_LOCK_FD}<"$lock_file" || {
        RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""
        return 1
    }
    if ! rr_legacy_update_lock_fd_is_safe \
            "$lock_file" "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD"; then
        exec {RR_UPDATE_RECOVERY_LEGACY_LOCK_FD}>&-
        RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""
        rr_recover_log "7.1.0 compatibility update lock changed while opening"
        return 1
    fi
    if ! flock -n "$RR_UPDATE_RECOVERY_LEGACY_LOCK_FD"; then
        exec {RR_UPDATE_RECOVERY_LEGACY_LOCK_FD}>&-
        RR_UPDATE_RECOVERY_LEGACY_LOCK_FD=""
        rr_recover_log "another 7.1.0 install or update holds the compatibility lock"
        return 1
    fi
}

rr_legacy_update_bridge_evidence_present() {
    [ -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || [ -L "$RR_LEGACY_UPDATE_BRIDGE_FILE" ]
}

rr_legacy_update_bridge_parent_is_safe() {
    local marker_parent="" canonical=""
    marker_parent=$(dirname -- "$RR_LEGACY_UPDATE_BRIDGE_FILE") || return 1
    [ -d "$marker_parent" ] && [ ! -L "$marker_parent" ] || return 1
    canonical=$(readlink -f -- "$marker_parent" 2>/dev/null) || return 1
    [ "$canonical" = "$marker_parent" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$marker_parent" 2>/dev/null)" = 0:0:700 ]
}

rr_legacy_update_bridge_is_safe() {
    local marker_value=""
    rr_legacy_update_bridge_parent_is_safe || return 1
    marker_value=$(rr_read_trusted_private_line "$RR_LEGACY_UPDATE_BRIDGE_FILE") || return 1
    [ "$marker_value" = rr-legacy-update-bridge-v1 ]
}

rr_prepare_legacy_update_bridge_parent() {
    local marker_parent="" canonical="" owner="" mode="" mode_value=0
    marker_parent=$(dirname -- "$RR_LEGACY_UPDATE_BRIDGE_FILE") || return 1
    if [ -e "$marker_parent" ] || [ -L "$marker_parent" ]; then
        [ -d "$marker_parent" ] && [ ! -L "$marker_parent" ] || return 1
        canonical=$(readlink -f -- "$marker_parent" 2>/dev/null) || return 1
        [ "$canonical" = "$marker_parent" ] || return 1
        owner=$(stat -c '%u:%g' -- "$marker_parent" 2>/dev/null) || return 1
        [ "$owner" = 0:0 ] || return 1
        mode=$(stat -c '%a' -- "$marker_parent" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        # Only tighten an already root-owned, non-writable, non-special RR
        # runtime directory. Never repair an attacker-controlled parent.
        (( (mode_value & 07022) == 0 )) || return 1
    else
        (umask 077; mkdir -p -- "$marker_parent") || return 1
    fi
    chown 0:0 -- "$marker_parent" || return 1
    chmod 0700 -- "$marker_parent" || return 1
    rr_legacy_update_bridge_parent_is_safe
}

rr_publish_legacy_update_bridge() {
    local marker_parent="" temporary=""
    if rr_legacy_update_bridge_evidence_present; then
        rr_legacy_update_bridge_is_safe
        return
    fi
    rr_prepare_legacy_update_bridge_parent || return 1
    marker_parent=$(dirname -- "$RR_LEGACY_UPDATE_BRIDGE_FILE") || return 1
    temporary="$marker_parent/.legacy-update-bridge.${BASHPID:-$$}"
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || return 1
    if ! (umask 077; set -o noclobber; printf '%s\n' rr-legacy-update-bridge-v1 > "$temporary") 2>/dev/null; then
        return 1
    fi
    chown 0:0 -- "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    chmod 0600 -- "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    if [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] ||
       [ "$(rr_read_trusted_private_line "$temporary" 2>/dev/null || true)" != rr-legacy-update-bridge-v1 ] ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    # The 0700 canonical parent excludes an unprivileged replacement race.
    # Recheck absence immediately before the atomic same-directory rename.
    if rr_legacy_update_bridge_evidence_present ||
       ! mv -fT -- "$temporary" "$RR_LEGACY_UPDATE_BRIDGE_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "$marker_parent" || return 1
    rr_legacy_update_bridge_is_safe
}

rr_acquire_marked_legacy_update_lock() {
    if ! rr_legacy_update_bridge_evidence_present; then
        # A predictable public path is not authoritative. Without the private
        # same-boot marker, ignore it without changing or deleting the inode.
        return 0
    fi
    if ! rr_legacy_update_bridge_is_safe; then
        rr_recover_log "unsafe same-boot 7.1.0 compatibility marker"
        return 1
    fi
    if ! rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE" existing-only ||
       [ -z "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ]; then
        rr_recover_log "same-boot compatibility marker exists without an available trusted legacy lock"
        return 1
    fi
}

rr_quarantine_acquire_cleanup_legacy_bridge() {
    # A persistent guard can outlive every volatile /run marker across reboot,
    # while a restored 7.1.0 installer still serializes only on this public
    # compatibility lock.  Hold both lock domains in the fixed new->legacy
    # order before proving absence or committing quarantine cleanup.
    rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE" create || return 1
    [ -n "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ] || return 1
    rr_publish_legacy_update_bridge
}

rr_update_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" fd_identity=""
    local shell_pid="${BASHPID:-$$}"
    local fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [[ "$fd_identity" == *:0:0:600:1 ]]
}

rr_subscription_process_matches() {
    local process_dir="${1:-}"
    local expected_cwd="${2:-}"
    local expected_app="${3:-}"
    local uid_line="" python_name="" port="" process_cwd="" cwd_links=""
    local -a arguments=()
    [ -n "$process_dir" ] && [ -n "$expected_cwd" ] && [ -n "$expected_app" ] || return 1
    [ -r "$process_dir/status" ] && [ -r "$process_dir/cmdline" ] || return 1
    uid_line=$(awk '$1 == "Uid:" { print $2 ":" $3 ":" $4 ":" $5; exit }' \
        "$process_dir/status" 2>/dev/null) || return 1
    [ "$uid_line" = 0:0:0:0 ] || return 1
    mapfile -d '' -t arguments < "$process_dir/cmdline" 2>/dev/null || return 1
    [ "${#arguments[@]}" -ge 3 ] || return 1
    python_name="${arguments[0]##*/}"
    [[ "$python_name" =~ ^python3([.][0-9]+)?$ ]] || return 1
    if [ "${arguments[1]}" = "$expected_app" ]; then
        port="${arguments[2]}"
    elif [ "${#arguments[@]}" -ge 4 ] && [ "${arguments[1]}" = -m ] && \
         [ "${arguments[2]}" = http.server ]; then
        port="${arguments[3]}"
    else
        return 1
    fi
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    process_cwd=$(readlink -- "$process_dir/cwd" 2>/dev/null) || return 1
    [ "$process_cwd" = "$expected_cwd" ] && return 0
    [ "$process_cwd" = "${expected_cwd} (deleted)" ] || return 1
    cwd_links=$(stat -Lc '%h' -- "$process_dir/cwd" 2>/dev/null) || return 1
    [ "$cwd_links" = 0 ]
}

rr_subscription_pid_is_managed() {
    local pid="${1:-}"
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local subscription_root="${RR_SUB_ROOT:-/tmp/sub_server}"
    local expected_cwd=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    expected_cwd=$(readlink -f -- "$subscription_root" 2>/dev/null) || return 1
    rr_subscription_process_matches "$proc_root/$pid" "$expected_cwd" \
        "$RR_LIB_DIR/nexus/sub_server.py"
}

rr_managed_subscription_pids() {
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local process_dir="" pid=""
    for process_dir in "$proc_root"/[0-9]*; do
        pid="${process_dir##*/}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        rr_subscription_pid_is_managed "$pid" || continue
        printf '%s\n' "$pid" 2>/dev/null || return 0
    done
}

rr_subscription_running() {
    local pid=""
    while IFS= read -r pid; do
        [ -n "$pid" ] && return 0
    done < <(rr_managed_subscription_pids)
    return 1
}

rr_stop_subscription_servers() {
    local pid=""
    local stopped=true
    local attempt=0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        rr_subscription_pid_is_managed "$pid" || continue
        kill "$pid" 2>/dev/null || true
    done < <(rr_managed_subscription_pids)
    while [ "$attempt" -lt 20 ] && rr_subscription_running; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    rr_subscription_running && stopped=false
    rm -f /run/rr-vps-subscription.pid /run/rr-vps-subscription.bind \
        /tmp/sub_server.pid /tmp/sub_server.bind
    [ "$stopped" = true ]
}

rr_wait_unit_state() {
    local unit="$1" wanted="$2" attempt=0 load_state="" active_state=""
    case "$wanted" in active|inactive) ;; *) return 1 ;; esac
    while [ "$attempt" -lt 50 ]; do
        load_state=$(systemctl show -p LoadState --value "$unit" 2>/dev/null) || load_state=""
        active_state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null) || active_state=""
        if [ "$wanted" = active ] && [ "$load_state" = loaded ] &&
           [ "$active_state" = active ]; then
            return 0
        fi
        if [ "$wanted" = inactive ]; then
            case "$load_state:$active_state" in
                loaded:inactive|loaded:failed|masked:inactive|masked:failed|\
                not-found:inactive) return 0 ;;
            esac
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

rr_query_unit_file_state() {
    local unit="$1" load_state="" unit_file_state=""
    load_state=$(systemctl show -p LoadState --value "$unit" 2>/dev/null) || return 1
    unit_file_state=$(systemctl show -p UnitFileState --value "$unit" 2>/dev/null) || return 1
    if [ "$load_state" = not-found ] && [ -z "$unit_file_state" ]; then
        unit_file_state=not-found
    fi
    case "$load_state:$unit_file_state" in
        loaded:enabled|loaded:enabled-runtime|loaded:disabled|loaded:static|\
        masked:masked|not-found:not-found) printf '%s\n' "$unit_file_state" ;;
        *) return 1 ;;
    esac
}

rr_clear_update_maintenance_marker() {
    local tx="$1" parent="" marker_state=0
    if [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] && [ ! -L "$RR_UPDATE_MAINTENANCE_FILE" ]; then
        return 0
    fi
    if rr_update_maintenance_marker_state "$tx"; then
        marker_state=0
    else
        marker_state=$?
    fi
    [ "$marker_state" -eq 0 ] || return 1
    parent=$(dirname -- "$RR_UPDATE_MAINTENANCE_FILE") || return 1
    rm -f -- "$RR_UPDATE_MAINTENANCE_FILE" && sync -f "$parent"
}

rr_transaction_format_state() {
    local tx="$1" marker=""
    marker="$tx/transaction-format"
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 1
    fi
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$marker" 2>/dev/null)" = 0:0:600:1 ] && \
        [ "$(cat "$marker" 2>/dev/null)" = 2 ] || return 2
    return 0
}

rr_external_state_marker_is_safe() {
    local backup="$1" marker=""
    marker="$backup/external_state_required"
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$marker" 2>/dev/null)" = 0:0:600:1 ]
}

rr_restore_external_state_if_required() {
    local tx="$1" backup="$2" state=0
    if rr_transaction_format_state "$tx"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            rr_recover_log "legacy transaction has no external-state snapshot; using the 7.1.0 recovery contract"
            return 0
            ;;
        *)
            rr_recover_log "transaction format marker is unsafe; refusing a legacy fallback"
            return 1
            ;;
    esac
    rr_external_state_marker_is_safe "$backup" || {
        rr_recover_log "required external-state snapshot marker is missing or unsafe"
        return 1
    }
    [ -x "$RR_UPDATE_EXTERNAL_HELPER" ] && [ -f "$RR_UPDATE_EXTERNAL_HELPER" ] && \
        [ ! -L "$RR_UPDATE_EXTERNAL_HELPER" ] || {
        rr_recover_log "external-state recovery helper is unavailable or unsafe"
        return 1
    }
    rr_run_delegated_without_lock_fds 0 "$RR_UPDATE_EXTERNAL_HELPER" \
        restore "$backup" --tx-root "$RR_TX_ROOT" || return 1
    rr_run_delegated_without_lock_fds 0 "$RR_UPDATE_EXTERNAL_HELPER" \
        verify "$backup" --tx-root "$RR_TX_ROOT"
}

rr_restore_unit_state() {
    local unit="$1" active_marker="$2" enabled_marker="$3" unit_file_state=""
    if [ -f "$enabled_marker" ]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
        unit_file_state=$(rr_query_unit_file_state "$unit") || return 1
        [ "$unit_file_state" = enabled ] || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || true
        unit_file_state=$(rr_query_unit_file_state "$unit") || return 1
        case "$unit_file_state" in disabled|static|masked|not-found) ;; *) return 1 ;; esac
    fi
    if [ -f "$active_marker" ]; then
        systemctl restart "$unit" >/dev/null 2>&1 || return 1
        rr_wait_unit_state "$unit" active
    else
        systemctl stop "$unit" >/dev/null 2>&1 || true
        rr_wait_unit_state "$unit" inactive
    fi
}

rr_restart_health_service_bounded() {
    local pid="" attempt=0 status=0
    (
        rr_close_inherited_recovery_lock_fds
        systemctl start argo-rr-health.service >/dev/null 2>&1
    ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 300 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
        systemctl stop argo-rr-health.service >/dev/null 2>&1 || true
        rr_wait_unit_state argo-rr-health.service inactive || true
        return 1
    fi
    wait "$pid" || status=$?
    [ "$status" -eq 0 ]
}

rr_freeze_health_writers_strict() {
    local failed=false disable_failed=false service_disable_failed=false
    local timer_stop_failed=false service_stop_failed=false
    local timer_load_state="" service_load_state=""
    local timer_active_state="" service_active_state=""
    local timer_unit_file_state="" service_unit_file_state=""
    # Recovery must never allow the old health service to race restored files
    # or restart a legacy subscription while rollback/isolation is incomplete.
    systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || disable_failed=true
    systemctl stop argo-rr-health.timer >/dev/null 2>&1 || timer_stop_failed=true
    systemctl disable argo-rr-health.service >/dev/null 2>&1 || service_disable_failed=true
    systemctl stop argo-rr-health.service >/dev/null 2>&1 || service_stop_failed=true
    if { [ -e "$RR_HEALTH_TIMER_FILE" ] || [ -L "$RR_HEALTH_TIMER_FILE" ]; } &&
       { [ "$disable_failed" = true ] || [ "$timer_stop_failed" = true ]; }; then
        failed=true
    fi
    if { [ -e "$RR_HEALTH_SERVICE_FILE" ] || [ -L "$RR_HEALTH_SERVICE_FILE" ]; } &&
       { [ "$service_disable_failed" = true ] || [ "$service_stop_failed" = true ]; }; then
        failed=true
    fi
    timer_load_state=$(systemctl show -p LoadState --value argo-rr-health.timer 2>/dev/null) || failed=true
    service_load_state=$(systemctl show -p LoadState --value argo-rr-health.service 2>/dev/null) || failed=true
    timer_active_state=$(systemctl show -p ActiveState --value argo-rr-health.timer 2>/dev/null) || failed=true
    service_active_state=$(systemctl show -p ActiveState --value argo-rr-health.service 2>/dev/null) || failed=true
    timer_unit_file_state=$(systemctl show -p UnitFileState --value argo-rr-health.timer 2>/dev/null) || failed=true
    service_unit_file_state=$(systemctl show -p UnitFileState --value argo-rr-health.service 2>/dev/null) || failed=true
    if [ "$timer_load_state" = not-found ] && [ -z "$timer_unit_file_state" ]; then
        timer_unit_file_state=not-found
    fi
    if [ "$service_load_state" = not-found ] && [ -z "$service_unit_file_state" ]; then
        service_unit_file_state=not-found
    fi
    case "$timer_load_state:$timer_active_state:$timer_unit_file_state" in
        loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:disabled|loaded:failed:static|\
        masked:inactive:masked|masked:failed:masked|\
        not-found:inactive:not-found) ;;
        *) failed=true ;;
    esac
    case "$service_load_state:$service_active_state:$service_unit_file_state" in
        loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:disabled|loaded:failed:static|\
        masked:inactive:masked|masked:failed:masked|\
        not-found:inactive:not-found) ;;
        *) failed=true ;;
    esac
    [ "$failed" = false ]
}

rr_recovery_fail_with_health_frozen() {
    local tx="$1" message="$2" freeze_failed=false current_phase=""
    rr_freeze_health_writers_strict || freeze_failed=true
    if declare -F rr_read_trusted_phase >/dev/null 2>&1; then
        current_phase=$(rr_read_trusted_phase "$tx" 2>/dev/null || true)
    fi
    case "$current_phase" in
        committed|rolled_back|rolled_back_degraded|aborted)
            # A cleanup failure cannot make a terminal transaction eligible
            # for rollback again.  Keep the terminal phase and retry evidence.
            ;;
        *) rr_recovery_write_phase "$tx" recovery_failed || true ;;
    esac
    if [ "$freeze_failed" = true ]; then
        rr_recover_log "health writers could not be verified inactive and disabled after recovery failure"
    fi
    rr_recover_log "$message"
    return 1
}

rr_prepare_terminal_transaction_cleanup() {
    local tx="$1" terminal_phase="$2" failure_message="$3"
    # Recovery spans /usr, /etc, /var and /run. Flush every backing filesystem
    # before publishing a terminal phase or deleting the active/maintenance
    # evidence; directory-only fsyncs cannot close this power-loss window.
    if ! sync; then
        rr_recovery_fail_with_health_frozen "$tx" "$failure_message"
        return 1
    fi
    if ! rr_recovery_write_phase "$tx" "$terminal_phase"; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "could not durably publish terminal phase $terminal_phase; transaction evidence was retained"
        return 1
    fi
}

rr_finalize_committed_candidate() {
    [ -f "$RR_LAUNCHER" ] && [ -x "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ] || return 1
    rr_run_delegated_without_lock_fds 60 "$RR_LAUNCHER" --post-update-finalize
}

rr_resume_subscription_bounded() {
    if [ ! -f "$RR_LAUNCHER" ] || [ ! -x "$RR_LAUNCHER" ] || [ -L "$RR_LAUNCHER" ] ||
       ! rr_run_delegated_without_lock_fds 30 \
           "$RR_LAUNCHER" --refresh-subscription >/dev/null 2>&1 ||
       ! rr_subscription_running; then
        rr_stop_subscription_servers >/dev/null 2>&1 || true
        return 1
    fi
}

rr_restore_recorded_writer_state() {
    local backup="$1" subscription_policy="${2:-normal}" failed=false
    local resume_subscription=false
    if [ ! -f "$backup/writer_state_complete" ]; then
        if [ "$subscription_policy" != normal ]; then
            rr_freeze_health_writers_strict || failed=true
        elif [ -f "$backup/health_timer_was_enabled" ]; then
            systemctl enable argo-rr-health.timer >/dev/null 2>&1 || failed=true
            systemctl start --no-block argo-rr-health.timer >/dev/null 2>&1 || failed=true
        else
            systemctl disable argo-rr-health.timer >/dev/null 2>&1 || true
            systemctl stop --no-block argo-rr-health.timer >/dev/null 2>&1 || true
        fi
        if [ -f "$backup/singbox_was_running" ]; then
            systemctl restart --no-block sing-box >/dev/null 2>&1 || failed=true
        else
            systemctl stop --no-block sing-box >/dev/null 2>&1 || true
        fi
        if [ -f "$backup/nexus_was_running" ]; then
            systemctl restart --no-block rr-nexus >/dev/null 2>&1 || failed=true
        else
            systemctl stop --no-block rr-nexus >/dev/null 2>&1 || true
        fi
        if [ "$subscription_policy" = normal ] && \
           { [ -f "$backup/subscription_was_running" ] || [ -f "$backup/argo_was_running" ]; } && \
           [ -f "$RR_HEALTH_SERVICE_FILE" ]; then
            systemctl start --no-block argo-rr-health.service >/dev/null 2>&1 || failed=true
        fi
        [ "$failed" = false ]
        return
    fi
    if [ "$subscription_policy" = normal ] && [ -f "$backup/subscription_was_running" ]; then
        resume_subscription=true
    else
        rr_stop_subscription_servers || failed=true
        rr_subscription_running && failed=true
    fi
    rr_restore_unit_state sing-box "$backup/singbox_was_running" \
        "$backup/singbox_was_enabled" || failed=true
    rr_restore_unit_state rr-nexus "$backup/nexus_was_running" \
        "$backup/nexus_was_enabled" || failed=true
    if [ "$subscription_policy" = normal ]; then
        rr_restore_unit_state argo-rr-health.timer "$backup/health_timer_was_running" \
            "$backup/health_timer_was_enabled" || failed=true
        if [ -f "$backup/health_service_was_running" ]; then
            rr_restart_health_service_bounded || failed=true
        fi
    else
        rr_freeze_health_writers_strict || failed=true
    fi
    if [ "$resume_subscription" = true ]; then
        if [ "$failed" = false ]; then
            rr_resume_subscription_bounded || failed=true
        else
            rr_stop_subscription_servers >/dev/null 2>&1 || true
        fi
    fi
    [ "$failed" = false ]
}

rr_acquire_update_lock() {
    [ "${RR_UPDATE_LOCK_HELD:-0}" != 1 ] || return 0
    rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE" || {
        rr_recover_log "unsafe shared update lock file"
        return 1
    }
    exec {RR_UPDATE_RECOVERY_LOCK_FD}>>"$RR_UPDATE_LOCK_FILE" || {
        RR_UPDATE_RECOVERY_LOCK_FD=""
        return 1
    }
    if ! rr_update_lock_fd_is_safe "$RR_UPDATE_LOCK_FILE" "$RR_UPDATE_RECOVERY_LOCK_FD"; then
        exec {RR_UPDATE_RECOVERY_LOCK_FD}>&-
        RR_UPDATE_RECOVERY_LOCK_FD=""
        rr_recover_log "shared update lock changed while opening"
        return 1
    fi
    if ! flock -n "$RR_UPDATE_RECOVERY_LOCK_FD"; then
        rr_recover_log "another install, update, backup, or restore transaction holds the shared lock"
        exec {RR_UPDATE_RECOVERY_LOCK_FD}>&-
        RR_UPDATE_RECOVERY_LOCK_FD=""
        return 1
    fi
    if ! rr_acquire_marked_legacy_update_lock; then
        rr_close_inherited_recovery_lock_fds
        rr_recover_log "could not acquire the 7.1.0 compatibility update lock"
        return 1
    fi
}

rr_semver_is_valid() {
    [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

rr_version_ge() {
    rr_semver_is_valid "${1:-}" && rr_semver_is_valid "${2:-}" || return 1
    [ "$1" = "$2" ] ||
        [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
}

rr_runtime_version() {
    local runtime_file="$1" line="" count=0 version=""
    [ -f "$runtime_file" ] && [ ! -L "$runtime_file" ] || return 1
    while IFS= read -r line; do
        case "$line" in SCRIPT_VERSION=*) count=$((count + 1)); version="$line" ;; esac
    done < "$runtime_file"
    [ "$count" -eq 1 ] || return 1
    [[ "$version" =~ ^SCRIPT_VERSION=\"([^\"]+)\"$ ]] || return 1
    version="${BASH_REMATCH[1]}"
    rr_semver_is_valid "$version" || return 1
    printf '%s\n' "$version"
}

rr_config_subscription_port() {
    local config_file="$1" line="" count=0 value=""
    [ -f "$config_file" ] && [ ! -L "$config_file" ] || return 1
    while IFS= read -r line; do
        case "$line" in SUB_PORT=*) count=$((count + 1)); value="${line#SUB_PORT=}" ;; esac
    done < "$config_file"
    [ "$count" -eq 1 ] || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ] || return 1
    printf '%s\n' "$((10#$value))"
}

rr_transaction_dir_is_valid() {
    local tx="${1:-}" canonical="" transaction_name=""
    [ -n "$tx" ] && [ -d "$tx" ] && [ ! -L "$tx" ] || return 1
    [ "$(dirname "$tx")" = "$RR_TX_ROOT/transactions" ] || return 1
    transaction_name="${tx##*/}"
    [[ "$transaction_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    canonical=$(readlink -f "$tx" 2>/dev/null) || return 1
    [ "$canonical" = "$tx" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$tx" 2>/dev/null)" = 0:0:700 ]
}

rr_transaction_metadata_identity_is_safe() {
    local identity="$1" device="" inode="" owner_uid="" owner_gid="" mode="" links=""
    IFS=: read -r device inode owner_uid owner_gid mode links <<<"$identity"
    [ -n "$device" ] && [ -n "$inode" ] && [ "$owner_uid" = 0 ] &&
        [ "$owner_gid" = 0 ] && [ "$links" = 1 ] || return 1
    # Legacy 7.1.0 used the process umask and therefore commonly wrote 0644.
    # It remains safe to locate a transaction through a root-owned, single-link
    # metadata file with no special/execute/group-or-other-write bits. Format 2
    # enforces the newer exact 0600 contract after its marker is trusted.
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_transaction_v2_control_metadata_is_safe() {
    [ -f "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ] &&
        [ "$(stat -c '%u:%g:%a:%h' -- "$RR_ACTIVE_TX" 2>/dev/null)" = 0:0:600:1 ] &&
        [ -f "$1/phase" ] && [ ! -L "$1/phase" ] &&
        [ "$(stat -c '%u:%g:%a:%h' -- "$1/phase" 2>/dev/null)" = 0:0:600:1 ]
}

rr_transaction_v2_backup_metadata_is_safe() {
    [ -d "$1/backup" ] && [ ! -L "$1/backup" ] &&
        [ "$(readlink -f -- "$1/backup" 2>/dev/null)" = "$1/backup" ] &&
        [ "$(stat -c '%u:%g:%a' -- "$1/backup" 2>/dev/null)" = 0:0:700 ] &&
        [ -f "$1/backup/writer_state_complete" ] &&
        [ ! -L "$1/backup/writer_state_complete" ] &&
        [ "$(stat -c '%u:%g:%a:%h:%s' -- "$1/backup/writer_state_complete" 2>/dev/null)" = 0:0:600:1:0 ]
}

rr_transaction_v2_metadata_is_safe() {
    rr_transaction_v2_control_metadata_is_safe "$1" &&
        rr_transaction_v2_backup_metadata_is_safe "$1"
}

rr_read_trusted_phase() {
    local transaction="$1" phase_file="" phase="" phase_fd=""
    local shell_pid="${BASHPID:-$$}" fd_path="" path_identity="" fd_identity=""
    local -a phase_lines=()
    rr_transaction_dir_is_valid "$transaction" || return 1
    phase_file="$transaction/phase"
    [ -f "$phase_file" ] && [ ! -L "$phase_file" ] || return 1
    exec {phase_fd}<"$phase_file" || return 1
    fd_path="/proc/$shell_pid/fd/$phase_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$phase_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$phase_file" 2>/dev/null) || {
        exec {phase_fd}>&-
        return 1
    }
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || {
        exec {phase_fd}>&-
        return 1
    }
    if [ "$path_identity" != "$fd_identity" ] ||
       ! rr_transaction_metadata_identity_is_safe "$fd_identity" || [ -L "$phase_file" ]; then
        exec {phase_fd}>&-
        return 1
    fi
    mapfile -t phase_lines <&"$phase_fd"
    if [ "${#phase_lines[@]}" -ne 1 ]; then
        exec {phase_fd}>&-
        return 1
    fi
    phase="${phase_lines[0]}"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$phase_file" 2>/dev/null) || {
        exec {phase_fd}>&-
        return 1
    }
    exec {phase_fd}>&-
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$phase_file" ] || return 1
    case "$phase" in
        state_recorded|freezing|snapshotting|prepared|switching|runtime_swapped|migrating|rolling_back|\
        committed|rolled_back|rolled_back_degraded|recovery_failed|aborted) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$phase"
}

rr_read_trusted_private_line() {
    local value_file="$1" value_fd="" value=""
    local shell_pid="${BASHPID:-$$}" fd_path="" path_identity="" fd_identity=""
    local -a value_lines=()
    [ -f "$value_file" ] && [ ! -L "$value_file" ] || return 1
    exec {value_fd}<"$value_file" || return 1
    fd_path="/proc/$shell_pid/fd/$value_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$value_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$value_file" 2>/dev/null) || {
        exec {value_fd}>&-
        return 1
    }
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || {
        exec {value_fd}>&-
        return 1
    }
    if [ "$path_identity" != "$fd_identity" ] ||
       [[ "$fd_identity" != *:0:0:600:1 ]] || [ -L "$value_file" ]; then
        exec {value_fd}>&-
        return 1
    fi
    mapfile -t value_lines <&"$value_fd"
    if [ "${#value_lines[@]}" -ne 1 ]; then
        exec {value_fd}>&-
        return 1
    fi
    value="${value_lines[0]}"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$value_file" 2>/dev/null) || {
        exec {value_fd}>&-
        return 1
    }
    exec {value_fd}>&-
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$value_file" ] || return 1
    printf '%s\n' "$value"
}

rr_committed_settled_state() {
    local tx="$1" marker="" value=""
    marker="$tx/$RR_COMMITTED_SETTLED_NAME"
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 1
    fi
    value=$(rr_read_trusted_private_line "$marker") || return 2
    [ "$value" = "$RR_COMMITTED_SETTLED_VALUE" ] || return 2
    return 0
}

rr_publish_committed_settled() {
    local tx="$1" marker="" temporary="" state=0
    rr_transaction_dir_is_valid "$tx" || return 1
    marker="$tx/$RR_COMMITTED_SETTLED_NAME"
    if rr_committed_settled_state "$tx"; then
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    temporary=$(umask 077; mktemp "$tx/.${RR_COMMITTED_SETTLED_NAME}.XXXXXX") || return 1
    if ! printf '%s\n' "$RR_COMMITTED_SETTLED_VALUE" > "$temporary" ||
       ! chmod 0600 "$temporary" ||
       [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! mv -f -- "$temporary" "$marker"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        rr_committed_settled_state "$tx" && return 2
        return 1
    fi
    # After rename, a failure is ambiguous: the strict marker is already
    # visible even if its directory entry has not yet been reported durable.
    # Callers must retain maintenance/evidence, but must not freeze writers on
    # the assumption that the marker is absent.
    if ! sync -f "$tx"; then
        rr_committed_settled_state "$tx" && return 2
        return 1
    fi
    rr_committed_settled_state "$tx" || return 1
    return 0
}

rr_update_maintenance_marker_state() {
    local tx="$1" value=""
    if [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] && [ ! -L "$RR_UPDATE_MAINTENANCE_FILE" ]; then
        return 1
    fi
    value=$(rr_read_trusted_private_line "$RR_UPDATE_MAINTENANCE_FILE") || return 2
    [ "$value" = "$tx" ] || return 2
    return 0
}

rr_create_update_maintenance_marker() {
    local tx="$1" parent="" canonical="" temporary="" marker_state=0
    local owner_uid="" owner_gid="" mode="" mode_value=0
    rr_transaction_dir_is_valid "$tx" || return 1
    parent=$(dirname -- "$RR_UPDATE_MAINTENANCE_FILE") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    canonical=$(readlink -f -- "$parent" 2>/dev/null) || return 1
    [ "$canonical" = "$parent" ] || return 1
    IFS=: read -r owner_uid owner_gid mode < <(
        stat -c '%u:%g:%a' -- "$parent" 2>/dev/null
    ) || return 1
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 07022) == 0 )) || return 1
    chmod 0700 -- "$parent" || return 1
    [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ] || return 1
    if rr_update_maintenance_marker_state "$tx"; then
        sync -f "$RR_UPDATE_MAINTENANCE_FILE" && sync -f "$parent" &&
            rr_update_maintenance_marker_state "$tx"
        return
    else
        marker_state=$?
    fi
    [ "$marker_state" -eq 1 ] || return 1
    temporary=$(umask 077; mktemp "$parent/.update-maintenance.XXXXXX") || return 1
    if ! printf '%s\n' "$tx" > "$temporary" || ! chmod 0600 "$temporary" ||
       [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] ||
       ! sync -f "$temporary" ||
       ! mv -f -- "$temporary" "$RR_UPDATE_MAINTENANCE_FILE"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    sync -f "$RR_UPDATE_MAINTENANCE_FILE" || return 1
    sync -f "$parent" || return 1
    rr_update_maintenance_marker_state "$tx"
}

rr_ensure_update_maintenance_marker() {
    rr_create_update_maintenance_marker "$1"
}

rr_root_owned_safe_empty_marker() {
    local marker="$1" metadata="" owner_uid="" owner_gid="" mode="" links="" size=""
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h:%s' -- "$marker" 2>/dev/null) || return 1
    IFS=: read -r owner_uid owner_gid mode links size <<<"$metadata"
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] && [ "$links" = 1 ] && [ "$size" = 0 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_trusted_runtime_version() {
  (
    local runtime_root="$1" runtime_file="$1/modules/00-runtime.sh"
    local directory="" canonical="" owner_uid="" owner_gid="" mode="" mode_value=0
    local runtime_fd="" shell_pid="${BASHPID:-$$}" fd_path=""
    local path_identity="" fd_identity="" line="" count=0 version=""
    local -a runtime_lines=()
    for directory in "$runtime_root" "$runtime_root/modules"; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
        [ "$canonical" = "$directory" ] || return 1
        IFS=: read -r owner_uid owner_gid mode < <(
            stat -c '%u:%g:%a' -- "$directory" 2>/dev/null
        ) || return 1
        [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        (( (mode_value & 07022) == 0 )) || return 1
    done
    [ -f "$runtime_file" ] && [ ! -L "$runtime_file" ] || return 1
    exec {runtime_fd}<"$runtime_file" || return 1
    fd_path="/proc/$shell_pid/fd/$runtime_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$runtime_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$runtime_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$runtime_file" ] || return 1
    IFS=: read -r _ _ owner_uid owner_gid mode _ <<<"$fd_identity"
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode" || return 1
    [[ "$fd_identity" == *:1 ]] || return 1
    mapfile -t runtime_lines <&"$runtime_fd"
    for line in "${runtime_lines[@]}"; do
        case "$line" in
            SCRIPT_VERSION=*) count=$((count + 1)); version="$line" ;;
        esac
    done
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$runtime_file" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$runtime_file" ] || return 1
    [ "$count" -eq 1 ] || return 1
    case "$version" in 'SCRIPT_VERSION="'*'"') ;; *) return 1 ;; esac
    version="${version#SCRIPT_VERSION=\"}"
    version="${version%\"}"
    rr_semver_is_valid "$version" || return 1
    printf '%s\n' "$version"
  )
}

rr_trusted_rollback_target_version() {
    local tx="$1" backup="" canonical="" complete="" recorded="" actual=""
    rr_transaction_dir_is_valid "$tx" || return 1
    backup="$tx/backup"
    [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
    canonical=$(readlink -f -- "$backup" 2>/dev/null) || return 1
    [ "$canonical" = "$backup" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$backup" 2>/dev/null)" = 0:0:700 ] || return 1
    complete=$(rr_read_trusted_private_line "$backup/rollback-metadata-complete") || return 1
    [ "$complete" = 1 ] || return 1
    recorded=$(rr_read_trusted_private_line "$backup/rollback-runtime-version") || return 1
    if [ "$recorded" = none ]; then
        rr_root_owned_safe_empty_marker "$backup/runtime_did_not_exist" || return 1
        [ ! -e "$tx/old-runtime" ] && [ ! -L "$tx/old-runtime" ] || return 1
        printf 'none\n'
        return 0
    fi
    rr_semver_is_valid "$recorded" || return 1
    if [ -e "$tx/old-runtime" ] || [ -L "$tx/old-runtime" ]; then
        actual=$(rr_trusted_runtime_version "$tx/old-runtime") || return 1
    else
        actual=$(rr_trusted_runtime_version "$RR_LIB_DIR") || return 1
    fi
    [ "$actual" = "$recorded" ] || return 1
    printf '%s\n' "$recorded"
}

rr_prepare_legacy_lock_for_rollback() {
    local tx="$1" target_version=""
    target_version=$(rr_trusted_rollback_target_version "$tx") || return 1
    [ "$target_version" != none ] || return 0
    rr_version_ge "$target_version" "$RR_SUBSCRIPTION_SAFE_VERSION" && return 0
    if rr_legacy_update_bridge_evidence_present; then
        rr_legacy_update_bridge_is_safe || return 1
        if [ -z "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ]; then
            rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE" existing-only || return 1
        fi
        [ -n "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ]
        return
    fi
    rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE" create || return 1
    [ -n "${RR_UPDATE_RECOVERY_LEGACY_LOCK_FD:-}" ] || return 1
    # Publish the private same-boot evidence while the compatibility flock is
    # held, and before any pre-7.1.1 runtime or launcher can become visible.
    rr_publish_legacy_update_bridge
}

rr_write_private_value() {
    local target="$1" value="$2" temporary=""
    mkdir -p "$(dirname "$target")" || return 1
    temporary="$(dirname "$target")/.${target##*/}.$$"
    (umask 077; printf '%s\n' "$value" > "$temporary") &&
        chmod 600 "$temporary" && mv -f "$temporary" "$target"
}

rr_recovery_write_phase() {
    local tx="$1" phase="$2" temporary=""
    temporary="$tx/.phase.$$"
    (umask 077; printf '%s\n' "$phase" > "$temporary") && chmod 600 "$temporary" && \
        sync -f "$temporary" && mv -f "$temporary" "$tx/phase" && sync -f "$tx"
}

rr_snapshot_rollback_metadata() {
    local tx="$1" backup="" version="unknown" port="unknown"
    rr_transaction_dir_is_valid "$tx" || return 1
    backup="$tx/backup"
    [ -d "$backup" ] && [ ! -L "$backup" ] || return 1

    if [ -f "$backup/runtime_did_not_exist" ]; then
        version="none"
    else
        version=$(rr_runtime_version "$RR_LIB_DIR/modules/00-runtime.sh" 2>/dev/null || printf unknown)
    fi
    if [ -f "$backup/had_argo_vmess.conf" ]; then
        port=$(rr_config_subscription_port "$backup/argo_vmess.conf" 2>/dev/null || printf unknown)
    else
        port="none"
    fi
    rr_write_private_value "$backup/rollback-runtime-version" "$version" || return 1
    rr_write_private_value "$backup/rollback-subscription-port" "$port" || return 1
    # A quarantine deliberately stops the legacy process, so a later safe
    # upgrade must use the marker's pre-quarantine intent rather than mistake
    # the forced stop for the user's desired service state.
    if [ -e "$RR_QUARANTINE_FILE" ] || [ -L "$RR_QUARANTINE_FILE" ] ||
       [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        rr_quarantine_read_active_state || return 1
        if [ "$RR_QUARANTINE_RESUME" = 1 ]; then
            : > "$backup/subscription_was_running" || return 1
        else
            rm -f -- "$backup/subscription_was_running" || return 1
        fi
    fi
    rr_write_private_value "$backup/rollback-metadata-complete" 1
}

rr_quarantine_state_read() {
    local state_file="$1"
    local line="" key="" value="" seen_format=0 seen_state=0 seen_version=0 seen_port=0 seen_resume=0
    RR_QUARANTINE_STATE=""
    RR_QUARANTINE_VERSION=""
    RR_QUARANTINE_PORT=""
    RR_QUARANTINE_RESUME=""
    [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' "$state_file" 2>/dev/null)" = 0:0:600:1 ] || return 1
    [ "$(stat -c '%s' "$state_file" 2>/dev/null)" -le 512 ] || return 1
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        case "$key" in
            format) [ "$seen_format" -eq 0 ] && [ "$value" = 1 ] || return 1; seen_format=1 ;;
            state)
                [ "$seen_state" -eq 0 ] || return 1
                case "$value" in quarantined|degraded) RR_QUARANTINE_STATE="$value" ;; *) return 1 ;; esac
                seen_state=1
                ;;
            target_version)
                [ "$seen_version" -eq 0 ] || return 1
                if [ "$value" != unknown ]; then rr_semver_is_valid "$value" || return 1; fi
                RR_QUARANTINE_VERSION="$value"
                seen_version=1
                ;;
            port)
                [ "$seen_port" -eq 0 ] || return 1
                [[ "$value" =~ ^[0-9]+$ ]] || return 1
                [ "$value" = 0 ] || { [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ]; } || return 1
                RR_QUARANTINE_PORT="$((10#$value))"
                seen_port=1
                ;;
            resume_subscription)
                [ "$seen_resume" -eq 0 ] || return 1
                case "$value" in 0|1) RR_QUARANTINE_RESUME="$value" ;; *) return 1 ;; esac
                seen_resume=1
                ;;
            *) return 1 ;;
        esac
    done < "$state_file"
    [ "$seen_format" -eq 1 ] && [ "$seen_state" -eq 1 ] &&
        [ "$seen_version" -eq 1 ] && [ "$seen_port" -eq 1 ] && [ "$seen_resume" -eq 1 ]
}

rr_quarantine_marker_read() {
    rr_quarantine_state_read "$RR_QUARANTINE_FILE"
}

rr_quarantine_guard_state_read() {
    rr_quarantine_state_read "$RR_QUARANTINE_GUARD_STATE"
}

rr_quarantine_read_active_state() {
    local marker_present=false state_present=false
    local marker_state="" marker_version="" marker_port="" marker_resume=""
    if [ -e "$RR_QUARANTINE_FILE" ] || [ -L "$RR_QUARANTINE_FILE" ]; then
        marker_present=true
        rr_quarantine_marker_read || return 1
        marker_state="$RR_QUARANTINE_STATE"
        marker_version="$RR_QUARANTINE_VERSION"
        marker_port="$RR_QUARANTINE_PORT"
        marker_resume="$RR_QUARANTINE_RESUME"
    fi
    if [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        state_present=true
        rr_quarantine_guard_state_read || return 1
        if [ "$marker_present" = true ] &&
           { [ "$RR_QUARANTINE_STATE" != "$marker_state" ] ||
             [ "$RR_QUARANTINE_VERSION" != "$marker_version" ] ||
             [ "$RR_QUARANTINE_PORT" != "$marker_port" ] ||
             [ "$RR_QUARANTINE_RESUME" != "$marker_resume" ]; }; then
            return 1
        fi
    fi
    [ "$marker_present" = true ] || [ "$state_present" = true ] || return 1
    if [ "$marker_present" = true ]; then
        RR_QUARANTINE_STATE="$marker_state"
        RR_QUARANTINE_VERSION="$marker_version"
        RR_QUARANTINE_PORT="$marker_port"
        RR_QUARANTINE_RESUME="$marker_resume"
    fi
}

rr_quarantine_file_evidence_present() {
    local artifact=""
    for artifact in "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_GUARD_STATE" \
        "$RR_QUARANTINE_UNIT" "$RR_QUARANTINE_READY" "$RR_QUARANTINE_GUARD_SELF"; do
        if [ -e "$artifact" ] || [ -L "$artifact" ]; then
            return 0
        fi
    done
    return 1
}

rr_quarantine_firewall_evidence_present() {
    local backend="" rules="" line=""
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        # An unreadable raw table is unknown, not proof that the durable DROP
        # disappeared.  Treat it as evidence so recovery cannot publish a new
        # port or discard a committed transaction without an explicit retry.
        rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null) || return 0
        while IFS= read -r line; do
            [[ "$line" == *"$RR_QUARANTINE_COMMENT"* ]] || continue
            # Exact RR rules and malformed/foreign same-comment rules both
            # require the strict audit/cleanup path; neither means "absent".
            return 0
        done <<< "$rules"
    done
    return 1
}

rr_quarantine_guard_unit_state_read() {
    RR_QUARANTINE_UNIT_LOAD_STATE=$(systemctl show -p LoadState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    RR_QUARANTINE_UNIT_ACTIVE_STATE=$(systemctl show -p ActiveState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    RR_QUARANTINE_UNIT_FILE_STATE=$(systemctl show -p UnitFileState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    if [ "$RR_QUARANTINE_UNIT_LOAD_STATE" = not-found ] &&
       [ -z "$RR_QUARANTINE_UNIT_FILE_STATE" ]; then
        RR_QUARANTINE_UNIT_FILE_STATE=not-found
    fi
    case "$RR_QUARANTINE_UNIT_LOAD_STATE" in loaded|masked|not-found) ;; *) return 1 ;; esac
    case "$RR_QUARANTINE_UNIT_ACTIVE_STATE" in
        active|activating|deactivating|inactive|failed) ;;
        *) return 1 ;;
    esac
}

rr_quarantine_guard_unit_state_is_absent() {
    [ "$RR_QUARANTINE_UNIT_LOAD_STATE:$RR_QUARANTINE_UNIT_ACTIVE_STATE:$RR_QUARANTINE_UNIT_FILE_STATE" = \
        not-found:inactive:not-found ]
}

rr_quarantine_guard_unit_state_is_inactive() {
    case "$RR_QUARANTINE_UNIT_LOAD_STATE:$RR_QUARANTINE_UNIT_ACTIVE_STATE" in
        loaded:inactive|loaded:failed|masked:inactive|masked:failed|\
        not-found:inactive|not-found:failed) return 0 ;;
        *) return 1 ;;
    esac
}

rr_quarantine_guard_unit_state_is_disabled() {
    rr_quarantine_guard_unit_state_is_inactive || return 1
    case "$RR_QUARANTINE_UNIT_FILE_STATE" in
        disabled|static|masked|not-found) return 0 ;;
        *) return 1 ;;
    esac
}

rr_quarantine_artifact_evidence_present() {
    rr_quarantine_file_evidence_present && return 0
    rr_quarantine_firewall_evidence_present && return 0
    rr_quarantine_guard_unit_state_read || return 0
    ! rr_quarantine_guard_unit_state_is_absent
}

rr_quarantine_write_marker() {
    local state="$1" version="$2" port="$3" resume="${4:-0}" temporary="" tx_parent=""
    case "$state" in quarantined|degraded) ;; *) return 1 ;; esac
    if [ "$version" != unknown ]; then rr_semver_is_valid "$version" || return 1; fi
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" = 0 ] || { [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ]; } || return 1
    case "$resume" in 0|1) ;; *) return 1 ;; esac
    mkdir -p "$RR_TX_ROOT" || return 1
    chmod 700 "$RR_TX_ROOT" || return 1
    tx_parent=$(dirname -- "$RR_TX_ROOT") || return 1
    sync -f "$RR_TX_ROOT" && sync -f "$tx_parent" || return 1
    temporary="${RR_QUARANTINE_FILE}.tmp.$$"
    (umask 077; {
        printf 'format=1\n'
        printf 'state=%s\n' "$state"
        printf 'target_version=%s\n' "$version"
        printf 'port=%s\n' "$((10#$port))"
        printf 'resume_subscription=%s\n' "$resume"
    } > "$temporary") && chmod 600 "$temporary" && sync -f "$temporary" &&
        mv -f "$temporary" "$RR_QUARANTINE_FILE" && sync -f "$RR_TX_ROOT"
}

rr_quarantine_prepare_private_dir() {
    local directory="$1" canonical="" parent=""
    [[ "$directory" == /* ]] || return 1
    if [ -e "$directory" ] || [ -L "$directory" ]; then
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    else
        mkdir -p -- "$directory" || return 1
    fi
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
    chmod 0700 -- "$directory" || return 1
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || return 1
    rr_quarantine_source_ancestors_are_trusted "$directory/.rr-ancestor-check" || return 1
    parent=$(dirname -- "$directory") || return 1
    sync -f "$directory" && sync -f "$parent"
}

RR_QUARANTINE_STAGED_GUARD=""

rr_quarantine_source_ancestors_are_trusted() {
    local source="$1" canonical="" directory="" parent="" metadata=""
    local owner="" group="" mode="" mode_value=0
    [[ "$source" == /* ]] || return 1
    canonical=$(readlink -f -- "$source" 2>/dev/null) || return 1
    [ "$canonical" = "$source" ] || return 1
    directory=$(dirname -- "$source") || return 1
    while :; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
        IFS=: read -r owner group mode <<<"$metadata"
        [ "$owner" = 0 ] && [ "$group" = 0 ] || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        (( (mode_value & 06000) == 0 )) || return 1
        if (( (mode_value & 00022) != 0 && (mode_value & 01000) == 0 )); then
            return 1
        fi
        [ "$directory" != / ] || break
        parent=$(dirname -- "$directory") || return 1
        [ "$parent" != "$directory" ] || return 1
        directory="$parent"
    done
}

rr_quarantine_recovery_helper_is_trusted() {
    local source="${1:-$RR_RECOVERY_SELF}" metadata=""
    local owner="" group="" mode="" links=""
    rr_quarantine_source_ancestors_are_trusted "$source" || return 1
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    metadata=$(stat -c '%u %g %a %h' -- "$source" 2>/dev/null) || return 1
    read -r owner group mode links <<< "$metadata"
    [ "$owner" = 0 ] && [ "$group" = 0 ] && [ "$links" = 1 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 0022)) -eq 0 ] && [ $((8#$mode & 0100)) -ne 0 ] &&
        [ $((8#$mode & 07000)) -eq 0 ]
}

rr_quarantine_stage_guard_self() {
    local source="$RR_RECOVERY_SELF" guard_dir="" temporary=""
    rr_quarantine_recovery_helper_is_trusted "$source" || return 1
    bash -n "$source" || return 1
    guard_dir=$(dirname -- "$RR_QUARANTINE_GUARD_SELF") || return 1
    rr_quarantine_prepare_private_dir "$guard_dir" || return 1
    temporary="${RR_QUARANTINE_GUARD_SELF}.tmp.${BASHPID:-$$}"
    rm -f -- "$temporary" || return 1
    install -o 0 -g 0 -m 0700 -- "$source" "$temporary" || return 1
    sync -f "$temporary" || return 1
    [ -f "$temporary" ] && [ ! -L "$temporary" ] &&
        [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" = 0:0:700:1 ] || {
        rm -f -- "$temporary"
        return 1
    }
    RR_QUARANTINE_STAGED_GUARD="$temporary"
}

rr_quarantine_discard_staged_guard() {
    if [ -n "${RR_QUARANTINE_STAGED_GUARD:-}" ]; then
        rm -f -- "$RR_QUARANTINE_STAGED_GUARD" || return 1
    fi
    RR_QUARANTINE_STAGED_GUARD=""
}

rr_quarantine_publish_staged_guard() {
    local guard_dir="" staged="${RR_QUARANTINE_STAGED_GUARD:-}"
    [ -n "$staged" ] && [ -f "$staged" ] && [ ! -L "$staged" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$staged" 2>/dev/null)" = 0:0:700:1 ] || return 1
    guard_dir=$(dirname -- "$RR_QUARANTINE_GUARD_SELF") || return 1
    [ "$(dirname -- "$staged")" = "$guard_dir" ] || return 1
    mv -fT -- "$staged" "$RR_QUARANTINE_GUARD_SELF" || return 1
    RR_QUARANTINE_STAGED_GUARD=""
    sync -f "$guard_dir" || return 1
    [ -f "$RR_QUARANTINE_GUARD_SELF" ] && [ ! -L "$RR_QUARANTINE_GUARD_SELF" ] &&
        [ "$(stat -c '%u:%g:%a:%h' -- "$RR_QUARANTINE_GUARD_SELF" 2>/dev/null)" = 0:0:700:1 ]
}

rr_quarantine_install_guard_self() {
    case "${1:-publish}" in
        stage) rr_quarantine_stage_guard_self ;;
        publish)
            rr_quarantine_stage_guard_self || return 1
            rr_quarantine_publish_staged_guard || {
                rr_quarantine_discard_staged_guard >/dev/null 2>&1 || true
                return 1
            }
            ;;
        *) return 1 ;;
    esac
}

rr_quarantine_sync_guard_state() {
    local state_dir="" temporary=""
    rr_quarantine_marker_read || return 1
    state_dir=$(dirname -- "$RR_QUARANTINE_GUARD_STATE") || return 1
    rr_quarantine_prepare_private_dir "$state_dir" || return 1
    temporary="${RR_QUARANTINE_GUARD_STATE}.tmp.$$"
    rm -f -- "$temporary" || return 1
    install -o 0 -g 0 -m 0600 -- "$RR_QUARANTINE_FILE" "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -fT -- "$temporary" "$RR_QUARANTINE_GUARD_STATE" || return 1
    sync -f "$state_dir" || return 1
    [ -f "$RR_QUARANTINE_GUARD_STATE" ] && [ ! -L "$RR_QUARANTINE_GUARD_STATE" ] &&
        [ "$(stat -c '%u:%g:%a:%h' -- "$RR_QUARANTINE_GUARD_STATE" 2>/dev/null)" = 0:0:600:1 ]
}

rr_quarantine_rule() {
    local action="$1" backend="$2" port="$3"
    command -v "$backend" >/dev/null 2>&1 || return 1
    case "$action" in
        add)
            "$backend" -w 5 -t raw -C PREROUTING ! -i lo -p tcp --dport "$port" \
                -m addrtype --dst-type LOCAL -m comment --comment "$RR_QUARANTINE_COMMENT" \
                -j DROP >/dev/null 2>&1 ||
            "$backend" -w 5 -t raw -I PREROUTING 1 ! -i lo -p tcp --dport "$port" \
                -m addrtype --dst-type LOCAL -m comment --comment "$RR_QUARANTINE_COMMENT" \
                -j DROP >/dev/null 2>&1
            ;;
        delete)
            while "$backend" -w 5 -t raw -C PREROUTING ! -i lo -p tcp --dport "$port" \
                -m addrtype --dst-type LOCAL -m comment --comment "$RR_QUARANTINE_COMMENT" \
                -j DROP >/dev/null 2>&1; do
                "$backend" -w 5 -t raw -D PREROUTING ! -i lo -p tcp --dport "$port" \
                    -m addrtype --dst-type LOCAL -m comment --comment "$RR_QUARANTINE_COMMENT" \
                    -j DROP >/dev/null 2>&1 || return 1
            done
            ;;
        *) return 1 ;;
    esac
}

rr_quarantine_add_firewall_rules() {
    local port="$1" failed=false
    [ "$port" != 0 ] || return 1
    rr_quarantine_rule add iptables "$port" || failed=true
    if [ -s "$RR_IPV6_STATE_FILE" ]; then
        rr_quarantine_rule add ip6tables "$port" || failed=true
    fi
    [ "$failed" = false ]
}

rr_quarantine_remove_firewall_rules() {
    local port="$1" failed=false
    [ "$port" != 0 ] || return 0
    if command -v iptables >/dev/null 2>&1; then
        rr_quarantine_rule delete iptables "$port" || failed=true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        rr_quarantine_rule delete ip6tables "$port" || failed=true
    fi
    [ "$failed" = false ]
}

rr_quarantine_rule_line_port() {
    local line="$1" prefix="" suffix="" port=""
    prefix='-A PREROUTING ! -i lo -p tcp -m tcp --dport '
    suffix=" -m addrtype --dst-type LOCAL -m comment --comment \"${RR_QUARANTINE_COMMENT}\" -j DROP"
    if [[ "$line" != "$prefix"*"$suffix" ]]; then
        suffix=" -m addrtype --dst-type LOCAL -m comment --comment ${RR_QUARANTINE_COMMENT} -j DROP"
        [[ "$line" == "$prefix"*"$suffix" ]] || return 1
    fi
    port="${line#"$prefix"}"
    port="${port%"$suffix"}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || return 1
    printf '%s\n' "$((10#$port))"
}

rr_quarantine_firewall_backend_inventory_is_exact() {
    local backend="$1" port="$2" expected="$3"
    local rules="" line="" parsed_port="" count=0
    case "$expected" in 0|1) ;; *) return 1 ;; esac
    if ! command -v "$backend" >/dev/null 2>&1; then
        [ "$expected" -eq 0 ]
        return
    fi
    rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ "$line" == *"$RR_QUARANTINE_COMMENT"* ]] || continue
        parsed_port=$(rr_quarantine_rule_line_port "$line") || return 1
        [ "$parsed_port" = "$port" ] || return 1
        count=$((count + 1))
    done <<< "$rules"
    [ "$count" -eq "$expected" ]
}

rr_quarantine_firewall_inventory_is_exact() {
    local port="$1" ipv6_expected=0
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || return 1
    rr_quarantine_firewall_backend_inventory_is_exact iptables "$((10#$port))" 1 || return 1
    [ ! -s "$RR_IPV6_STATE_FILE" ] || ipv6_expected=1
    rr_quarantine_firewall_backend_inventory_is_exact \
        ip6tables "$((10#$port))" "$ipv6_expected"
}

rr_quarantine_audit_orphan_firewall_rules() {
    local backend="" rules="" line=""
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null) || return 1
        while IFS= read -r line; do
            [[ "$line" == *"$RR_QUARANTINE_COMMENT"* ]] || continue
            rr_quarantine_rule_line_port "$line" >/dev/null || return 1
        done <<< "$rules"
    done
}

rr_quarantine_remove_orphan_firewall_rules() {
    local backend="" rules="" remaining="" line="" port="" failed=false
    rr_quarantine_audit_orphan_firewall_rules || return 1
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        if ! rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null); then
            failed=true
            continue
        fi
        while IFS= read -r line; do
            [[ "$line" == *"$RR_QUARANTINE_COMMENT"* ]] || continue
            port=$(rr_quarantine_rule_line_port "$line") || { failed=true; continue; }
            # rr_quarantine_rule deletes only the exact RR-generated rule for
            # this port. A foreign rule that merely copies the comment is not
            # broadened into a deletion target.
            rr_quarantine_rule delete "$backend" "$port" || failed=true
        done <<< "$rules"
        if ! remaining=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null); then
            failed=true
        elif [[ "$remaining" == *"$RR_QUARANTINE_COMMENT"* ]]; then
            # Unknown or undeletable same-comment state must keep the guard in
            # degraded mode. Never claim success merely because `iptables -C`
            # could not distinguish absence from a backend/query failure.
            failed=true
        fi
    done
    [ "$failed" = false ]
}

rr_quarantine_render_unit() {
    [[ "$RR_QUARANTINE_GUARD_SELF" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$RR_QUARANTINE_GUARD_STATE" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$RR_QUARANTINE_FILE" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    cat <<EOF
[Unit]
Description=RR-vps unsafe rollback subscription quarantine
After=local-fs.target
Before=argo-rr-health.service
ConditionPathExists=|${RR_QUARANTINE_FILE}
ConditionPathExists=|${RR_QUARANTINE_GUARD_STATE}

[Service]
Type=notify
NotifyAccess=all
ExecStart=${RR_QUARANTINE_GUARD_SELF} quarantine-guard
Restart=on-failure
RestartSec=1
TimeoutStartSec=15
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

rr_quarantine_write_unit() {
    local temporary="" unit_dir=""
    [[ "$RR_QUARANTINE_UNIT" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    unit_dir=$(dirname -- "$RR_QUARANTINE_UNIT") || return 1
    mkdir -p "$unit_dir" || return 1
    rr_quarantine_source_ancestors_are_trusted "$RR_QUARANTINE_UNIT" || return 1
    temporary="${RR_QUARANTINE_UNIT}.tmp.$$"
    rr_quarantine_render_unit > "$temporary" || return 1
    chmod 644 "$temporary" && sync -f "$temporary" &&
        mv -fT "$temporary" "$RR_QUARANTINE_UNIT" && sync -f "$unit_dir"
}

rr_quarantine_unit_file_is_strict() {
    local canonical=""
    [ -f "$RR_QUARANTINE_UNIT" ] && [ ! -L "$RR_QUARANTINE_UNIT" ] || return 1
    canonical=$(readlink -f -- "$RR_QUARANTINE_UNIT" 2>/dev/null) || return 1
    [ "$canonical" = "$RR_QUARANTINE_UNIT" ] || return 1
    rr_quarantine_source_ancestors_are_trusted "$RR_QUARANTINE_UNIT" || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$RR_QUARANTINE_UNIT" 2>/dev/null)" = 0:0:644:1 ] || return 1
    cmp -s -- "$RR_QUARANTINE_UNIT" <(rr_quarantine_render_unit)
}

rr_quarantine_guard_cleanup_uninstalled_runtime() {
    local ready="$1" state_dir="" guard_dir="" failed=false cleanup_residue=false
    state_dir=$(dirname -- "$RR_QUARANTINE_GUARD_STATE") || return 1
    guard_dir=$(dirname -- "$RR_QUARANTINE_GUARD_SELF") || return 1
    [ ! -e "$RR_QUARANTINE_FILE" ] && [ ! -L "$RR_QUARANTINE_FILE" ] || return 1
    [ ! -e "$RR_LIB_DIR" ] && [ ! -L "$RR_LIB_DIR" ] || return 1
    [ ! -e "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ] || return 1
    rr_quarantine_guard_state_read || return 1
    rr_quarantine_acquire_cleanup_legacy_bridge || return 1
    rr_quarantine_audit_orphan_firewall_rules || return 1
    # A legacy uninstaller does not fsync its cross-filesystem unlinks. Flush
    # them globally, then prove the runtime and every health restart path are
    # still absent before releasing either the socket or precise DROP.
    sync || return 1
    [ ! -e "$RR_LIB_DIR" ] && [ ! -L "$RR_LIB_DIR" ] || return 1
    [ ! -e "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ] || return 1
    [ ! -e "$RR_HEALTH_TIMER_FILE" ] && [ ! -L "$RR_HEALTH_TIMER_FILE" ] || return 1
    [ ! -e "$RR_HEALTH_SERVICE_FILE" ] && [ ! -L "$RR_HEALTH_SERVICE_FILE" ] || return 1
    [ ! -e "$RR_HEALTH_RESTART_HELPER" ] && [ ! -L "$RR_HEALTH_RESTART_HELPER" ] || return 1
    rr_freeze_health_writers_strict || return 1
    rr_stop_subscription_servers || return 1
    rr_subscription_running && return 1
    [ ! -e "$RR_LIB_DIR" ] && [ ! -L "$RR_LIB_DIR" ] || return 1
    [ ! -e "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ] || return 1
    [ ! -e "$RR_HEALTH_TIMER_FILE" ] && [ ! -L "$RR_HEALTH_TIMER_FILE" ] || return 1
    [ ! -e "$RR_HEALTH_SERVICE_FILE" ] && [ ! -L "$RR_HEALTH_SERVICE_FILE" ] || return 1
    [ ! -e "$RR_HEALTH_RESTART_HELPER" ] && [ ! -L "$RR_HEALTH_RESTART_HELPER" ] || return 1
    # Keep the reboot-persistent unit and independent state intact until both
    # raw-table inventories have been removed. Before this cleanup commit,
    # every failure leaves the running socket plus the enabled unit untouched.
    rr_quarantine_remove_firewall_rules "$RR_QUARANTINE_PORT" || failed=true
    rr_quarantine_remove_orphan_firewall_rules || failed=true
    [ "$failed" = false ] || return 1
    # The old runtime, launcher and every health restart path were globally
    # synchronized absent above. Disabling this still-running unit is the
    # cleanup commit: after it, residual files are availability evidence only,
    # not authorization to expose an unsafe runtime. Never return the guard to
    # its retry loop with a disabled unit while claiming quarantine persists.
    systemctl disable rr-subscription-quarantine.service >/dev/null 2>&1 ||
        rr_recover_log "quarantine unit disable reported an error; completing committed cleanup against the durably absent runtime"
    while :; do
        cleanup_residue=false
        rm -f -- "$ready" || cleanup_residue=true
        rm -f -- "$RR_QUARANTINE_UNIT" || cleanup_residue=true
        systemctl daemon-reload >/dev/null 2>&1 || cleanup_residue=true
        if [ "$cleanup_residue" = false ]; then
            rm -f -- "$RR_QUARANTINE_GUARD_SELF" || cleanup_residue=true
        fi
        # The state is the final cleanup log and must outlive every executable
        # artifact deletion attempt so a partial retry retains exact port data.
        if [ "$cleanup_residue" = false ]; then
            rm -f -- "$RR_QUARANTINE_GUARD_STATE" || cleanup_residue=true
        fi
        [ "$cleanup_residue" = true ] || break
        rr_recover_log "uninstalled runtime is durably absent; retrying root-owned quarantine cleanup residue"
        sleep 1
    done
    rmdir -- "$state_dir" "$guard_dir" >/dev/null 2>&1 || true
    return 0
}

rr_quarantine_guard() {
    local port=0 ready="$RR_QUARANTINE_READY"
    local guard_pid="" child_status=0
    # The guard and its socket-reservation child are intentionally long-lived;
    # neither may keep a recovery transaction flock alive after its parent
    # finishes activation or recovery.
    rr_close_inherited_recovery_lock_fds
    if [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        rr_quarantine_guard_state_read
    else
        rr_quarantine_marker_read
    fi || {
        rr_recover_log "subscription quarantine state is absent, inconsistent, or invalid"
        return 1
    }
    port="$RR_QUARANTINE_PORT"
    rr_stop_subscription_servers || { rr_recover_log "could not stop the legacy subscription process"; return 1; }
    if [ "$port" != 0 ]; then
        rr_quarantine_add_firewall_rules "$port" ||
            rr_recover_log "raw firewall quarantine unavailable; the port reservation remains active"
    fi
    mkdir -p "$(dirname "$ready")" || return 1
    rm -f -- "$ready" || return 1
    rr_quarantine_guard_on_exit() {
        local exit_status=$?
        if [ -n "${guard_pid:-}" ]; then
            kill "$guard_pid" >/dev/null 2>&1 || true
            wait "$guard_pid" 2>/dev/null || true
        fi
        rm -f -- "$ready" || true
        return "$exit_status"
    }
    trap rr_quarantine_guard_on_exit EXIT
    # Install this before launching the reservation child so every unexpected
    # signal is visible to Restart=on-failure, including the startup window.
    trap 'exit 1' INT TERM HUP
    (
        rr_close_inherited_recovery_lock_fds
        exec python3 - "$port" "$ready" "${RR_PROC_ROOT:-/proc}" \
            "${RR_SUB_ROOT:-/tmp/sub_server}" "$RR_LIB_DIR" <<'PY'
import errno
import os
import re
import signal
import socket
import sys
import time

port = int(sys.argv[1])
ready, proc_root, subscription_root, runtime_root = sys.argv[2:]
sockets = []
released = False

def release_reservation(_signum, _frame):
    global released
    released = True

def reserve(family, address):
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port))
    except OSError as exc:
        sock.close()
        if family == socket.AF_INET6 and exc.errno in {
            errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPROTONOSUPPORT
        }:
            return
        raise
    sockets.append(sock)

def valid_port(raw):
    return 1 <= len(raw) <= 5 and raw.isdigit() and 1 <= int(raw) <= 65535

def managed_argv(process):
    with open(os.path.join(process, "cmdline"), "rb") as handle:
        arguments = handle.read(8192).split(b"\0")
    if arguments and not arguments[-1]:
        arguments.pop()
    if len(arguments) < 3 or not re.fullmatch(
        rb"python3(?:\.[0-9]+)?", os.path.basename(arguments[0])
    ):
        return False
    expected_app = os.fsencode(os.path.join(runtime_root, "nexus", "sub_server.py"))
    if arguments[1] == expected_app:
        return valid_port(arguments[2])
    return (
        len(arguments) >= 4
        and arguments[1:3] == [b"-m", b"http.server"]
        and valid_port(arguments[3])
    )

def root_owned_process(process):
    with open(os.path.join(process, "status"), "rb") as handle:
        for line in handle:
            fields = line.split()
            if fields and fields[0] == b"Uid:":
                return len(fields) >= 5 and fields[1:5] == [b"0"] * 4
    return False

def managed_cwd(process, expected):
    cwd_path = os.path.join(process, "cwd")
    actual = os.readlink(cwd_path)
    if actual == expected:
        return True
    return actual == f"{expected} (deleted)" and os.stat(cwd_path).st_nlink == 0

def stop_managed_servers():
    try:
        expected = os.path.realpath(subscription_root)
    except OSError:
        return
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return
    for entry in entries:
        if not entry.isdigit():
            continue
        process = os.path.join(proc_root, entry)
        try:
            if not root_owned_process(process) or not managed_argv(process):
                continue
            if not managed_cwd(process, expected):
                continue
            os.kill(int(entry), signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
            continue

signal.signal(signal.SIGUSR1, release_reservation)

if port:
    reserve(socket.AF_INET, "0.0.0.0")
    reserve(socket.AF_INET6, "::")
stop_managed_servers()
temporary = f"{ready}.tmp.{os.getpid()}"
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="ascii") as handle:
    handle.write("ready\n")
os.replace(temporary, ready)

notify_socket = os.environ.get("NOTIFY_SOCKET")
if notify_socket:
    address = "\0" + notify_socket[1:] if notify_socket.startswith("@") else notify_socket
    notifier = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        notifier.connect(address)
        notifier.sendall(b"READY=1")
    finally:
        notifier.close()

while not released:
    stop_managed_servers()
    time.sleep(0.05)
PY
    ) &
    guard_pid=$!
    for _ in $(seq 1 200); do
        [ -f "$ready" ] && [ ! -L "$ready" ] && break
        if ! kill -0 "$guard_pid" >/dev/null 2>&1; then
            wait "$guard_pid" 2>/dev/null
            child_status=$?
            [ "$child_status" -ne 0 ] || child_status=1
            guard_pid=""
            rm -f -- "$ready" || true
            trap - EXIT INT TERM HUP
            return "$child_status"
        fi
        sleep 0.05
    done
    if [ ! -f "$ready" ] || [ -L "$ready" ] ||
       [ "$(stat -c '%u:%g:%a:%h' -- "$ready" 2>/dev/null)" != 0:0:600:1 ]; then
        kill "$guard_pid" >/dev/null 2>&1 || true
        wait "$guard_pid" 2>/dev/null || true
        guard_pid=""
        rm -f -- "$ready" || true
        trap - EXIT INT TERM HUP
        rr_recover_log "subscription quarantine socket reservation did not become ready"
        return 1
    fi
    # Marker deletion alone is not authorization to remove the durable
    # barrier. A legacy uninstaller may finish without knowing the independent
    # state/unit, so self-clean only after both runtime and launcher are gone,
    # while holding the same lock as every new installer/uninstaller.
    while kill -0 "$guard_pid" >/dev/null 2>&1; do
        if [ ! -e "$RR_QUARANTINE_FILE" ] && [ ! -L "$RR_QUARANTINE_FILE" ] &&
           [ ! -e "$RR_LIB_DIR" ] && [ ! -L "$RR_LIB_DIR" ] &&
           [ ! -e "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ] &&
           rr_acquire_update_lock; then
            if rr_quarantine_guard_cleanup_uninstalled_runtime "$ready"; then
                kill -USR1 "$guard_pid" >/dev/null 2>&1 || true
                wait "$guard_pid" 2>/dev/null || true
                guard_pid=""
                rr_close_inherited_recovery_lock_fds
                trap - EXIT INT TERM HUP
                return 0
            fi
            rr_close_inherited_recovery_lock_fds
        fi
        sleep 1
    done
    wait "$guard_pid" 2>/dev/null
    child_status=$?
    guard_pid=""
    rm -f -- "$ready" || true
    trap - EXIT INT TERM HUP
    [ "$child_status" -ne 0 ] || child_status=1
    return "$child_status"
}

rr_suspend_subscription_quarantine() {
    if [ ! -e "$RR_QUARANTINE_FILE" ] && [ ! -L "$RR_QUARANTINE_FILE" ] &&
       [ ! -e "$RR_QUARANTINE_GUARD_STATE" ] && [ ! -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        rr_quarantine_artifact_evidence_present && return 1
        return 0
    fi
    rr_quarantine_read_active_state || return 1
    rr_quarantine_guard_unit_state_read || return 1
    if [ -e "$RR_QUARANTINE_UNIT" ] || [ -L "$RR_QUARANTINE_UNIT" ] ||
       ! rr_quarantine_guard_unit_state_is_absent; then
        if ! systemctl stop rr-subscription-quarantine.service >/dev/null 2>&1; then
            rr_recover_log "could not stop the subscription quarantine guard"
            return 1
        fi
    fi
    rr_quarantine_guard_unit_state_read || return 1
    if ! rr_quarantine_guard_unit_state_is_inactive; then
        rr_recover_log "subscription quarantine guard is still active after stop"
        return 1
    fi
    rm -f -- "$RR_QUARANTINE_READY" || return 1
    return 0
}

rr_quarantine_ready_is_strict() {
    [ "$(rr_read_trusted_private_line "$RR_QUARANTINE_READY" 2>/dev/null || true)" = ready ]
}

rr_quarantine_guard_helper_is_current() {
    local guard_metadata=""
    rr_quarantine_recovery_helper_is_trusted "$RR_RECOVERY_SELF" || return 1
    rr_quarantine_recovery_helper_is_trusted "$RR_QUARANTINE_GUARD_SELF" || return 1
    guard_metadata=$(stat -c '%u:%g:%a:%h' -- "$RR_QUARANTINE_GUARD_SELF" 2>/dev/null) || return 1
    [ "$guard_metadata" = 0:0:700:1 ] || return 1
    cmp -s -- "$RR_RECOVERY_SELF" "$RR_QUARANTINE_GUARD_SELF"
}

rr_quarantine_guard_unit_is_strict() {
    local fragment_path="" drop_in_paths=""
    rr_quarantine_guard_unit_state_read || return 1
    fragment_path=$(systemctl show -p FragmentPath --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    drop_in_paths=$(systemctl show -p DropInPaths --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    rr_quarantine_unit_file_is_strict &&
        [ "$RR_QUARANTINE_UNIT_LOAD_STATE" = loaded ] &&
        [ "$RR_QUARANTINE_UNIT_ACTIVE_STATE" = active ] &&
        [ "$RR_QUARANTINE_UNIT_FILE_STATE" = enabled ] &&
        [ "$fragment_path" = "$RR_QUARANTINE_UNIT" ] &&
        [ -z "$drop_in_paths" ]
}

rr_quarantine_existing_guard_is_reusable() {
    local port="${1:-${RR_QUARANTINE_PORT:-0}}"
    rr_quarantine_guard_helper_is_current && rr_quarantine_ready_is_strict &&
        rr_quarantine_guard_unit_is_strict &&
        rr_quarantine_firewall_inventory_is_exact "$port"
}

rr_runtime_is_subscription_safe_or_absent() {
    local version=""
    if [ ! -e "$RR_LIB_DIR" ] && [ ! -L "$RR_LIB_DIR" ] &&
       [ ! -e "$RR_LAUNCHER" ] && [ ! -L "$RR_LAUNCHER" ]; then
        return 0
    fi
    version=$(rr_trusted_runtime_version "$RR_LIB_DIR" 2>/dev/null) || return 1
    rr_version_ge "$version" "$RR_SUBSCRIPTION_SAFE_VERSION"
}

rr_clear_subscription_quarantine() {
    local port=0 failed=false
    local cleanup_failed=false state_dir="" guard_dir=""
    rr_runtime_is_subscription_safe_or_absent || {
        rr_recover_log "refusing to clear quarantine while an unsafe or unverified runtime remains installed"
        return 1
    }
    state_dir=$(dirname -- "$RR_QUARANTINE_GUARD_STATE") || return 1
    guard_dir=$(dirname -- "$RR_QUARANTINE_GUARD_SELF") || return 1
    if [ -e "$RR_QUARANTINE_FILE" ] || [ -L "$RR_QUARANTINE_FILE" ] ||
       [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        rr_quarantine_read_active_state || return 1
        port="$RR_QUARANTINE_PORT"
    fi
    # Audit every same-comment rule before stopping the durable guard or
    # deleting the exact barrier. A foreign rule or unreadable backend must
    # leave all existing isolation in place.
    rr_quarantine_audit_orphan_firewall_rules || return 1
    rr_stop_subscription_servers || return 1
    rr_quarantine_guard_unit_state_read || return 1
    if [ -e "$RR_QUARANTINE_UNIT" ] || [ -L "$RR_QUARANTINE_UNIT" ] ||
       ! rr_quarantine_guard_unit_state_is_absent; then
        systemctl disable --now rr-subscription-quarantine.service >/dev/null 2>&1 || return 1
    fi
    rr_quarantine_guard_unit_state_read || return 1
    rr_quarantine_guard_unit_state_is_disabled || return 1
    rm -f -- "$RR_QUARANTINE_READY" || return 1
    # Remove the unit and make that removal visible before releasing the
    # firewall. Any failure here leaves the durable rule/state untouched.
    rm -f -- "$RR_QUARANTINE_UNIT" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    [ "$port" = 0 ] || rr_quarantine_remove_firewall_rules "$port" || failed=true
    # Older affected uninstalls may have removed the marker before the exact
    # raw-table rule. Sweep only rules that can be re-derived as RR's precise
    # quarantine shape; never flush or rewrite a user chain.
    rr_quarantine_remove_orphan_firewall_rules || failed=true
    [ "$failed" = false ] || return 1
    # Keep the marker until last so every failed file cleanup retains the
    # trusted port/resume evidence needed for an exact retry.
    if [ "$cleanup_failed" = false ]; then
        rm -f -- "$RR_QUARANTINE_GUARD_SELF" || cleanup_failed=true
    fi
    if [ "$cleanup_failed" = false ]; then
        rm -f -- "$RR_QUARANTINE_GUARD_STATE" || cleanup_failed=true
    fi
    if [ "$cleanup_failed" = false ]; then
        rm -f -- "$RR_QUARANTINE_FILE" || cleanup_failed=true
    fi
    if [ "$cleanup_failed" != false ]; then
        if [ "$port" != 0 ] && ! rr_quarantine_add_firewall_rules "$port"; then
            rr_recover_log "quarantine cleanup failed and its exact firewall barrier could not be restored"
        fi
        return 1
    fi
    rmdir -- "$state_dir" "$guard_dir" >/dev/null 2>&1 || true
}

rr_activate_subscription_quarantine() {
    local version="$1" port="$2" resume="${3:-0}" state=quarantined attempt=0 old_port=0
    local guard_ready=false guard_enabled=false existing_state=false handoff_port=0
    if [ -e "$RR_QUARANTINE_FILE" ] || [ -L "$RR_QUARANTINE_FILE" ] ||
       [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
        rr_quarantine_read_active_state || return 1
        existing_state=true
        old_port="$RR_QUARANTINE_PORT"
        if [ "$old_port" = "$port" ] && [ "$port" != 0 ] &&
           rr_quarantine_existing_guard_is_reusable "$old_port"; then
            # Preserve the already-bound socket and persistent unit. Only the
            # version/resume metadata changes; there is no stop/start gap.
            rr_quarantine_write_marker quarantined "$version" "$port" "$resume" || return 1
            rr_quarantine_sync_guard_state || return 1
            sync || return 1
            return 0
        fi
        # Establish a precise DROP handoff before touching the old socket or
        # its durable state. If staging or stop fails, the old guard continues
        # to reserve the port and the extra DROP remains fail-closed.
        handoff_port="$old_port"
        [ "$handoff_port" != 0 ] || handoff_port="$port"
        [ "$handoff_port" != 0 ] || return 1
        rr_quarantine_add_firewall_rules "$handoff_port" || return 1
        [ "$RR_QUARANTINE_GUARD_SELF" != "$RR_RECOVERY_SELF" ] || return 1
        [ "$RR_QUARANTINE_GUARD_STATE" != "$RR_QUARANTINE_FILE" ] || return 1
        rr_quarantine_install_guard_self stage || return 1
        if ! rr_suspend_subscription_quarantine; then
            rr_quarantine_discard_staged_guard >/dev/null 2>&1 || true
            return 1
        fi
        if ! rr_quarantine_publish_staged_guard; then
            rr_quarantine_discard_staged_guard >/dev/null 2>&1 || true
            return 1
        fi
    elif rr_quarantine_artifact_evidence_present; then
        return 1
    fi
    rr_stop_subscription_servers || state=degraded
    [ "$port" != 0 ] || state=degraded
    [ "$RR_QUARANTINE_GUARD_SELF" != "$RR_RECOVERY_SELF" ] || return 1
    [ "$RR_QUARANTINE_GUARD_STATE" != "$RR_QUARANTINE_FILE" ] || return 1
    [ "$existing_state" = true ] || rr_quarantine_install_guard_self || return 1
    rr_quarantine_write_marker "$state" "$version" "$port" "$resume" || return 1
    rr_quarantine_sync_guard_state || return 1
    rr_quarantine_write_unit || return 1
    rm -f -- "$RR_QUARANTINE_READY" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if systemctl enable --now rr-subscription-quarantine.service >/dev/null 2>&1 &&
       rr_quarantine_guard_unit_is_strict; then
        guard_enabled=true
    else
        state=degraded
    fi
    while [ "$attempt" -lt 50 ] && [ ! -f "$RR_QUARANTINE_READY" ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if [ "$guard_enabled" = true ] &&
       rr_quarantine_guard_unit_is_strict && rr_quarantine_ready_is_strict; then
        guard_ready=true
    else
        state=degraded
    fi
    if [ "$port" != 0 ]; then
        if rr_quarantine_add_firewall_rules "$port"; then
            :
        else
            state=degraded
        fi
    fi
    # The old precise DROP remains as a fallback throughout the replacement.
    # Remove it only after the new guard and new-port policy are both ready.
    if [ "$state" = quarantined ] && [ "$old_port" != 0 ] && [ "$old_port" != "$port" ]; then
        rr_quarantine_remove_firewall_rules "$old_port" || state=degraded
    fi
    rr_quarantine_write_marker "$state" "$version" "$port" "$resume" || return 1
    rr_quarantine_sync_guard_state || return 1
    # Flush the cross-filesystem marker/state/helper/unit and systemd enablement
    # before rollback is allowed to enter a terminal phase.
    sync || return 1
    [ "$state" = quarantined ] || rr_recover_log "legacy subscription quarantine is DEGRADED; keep this host out of production"
    if [ "$port" = 0 ] || [ "$guard_ready" != true ]; then
        rr_recover_log "legacy subscription quarantine has no active, enabled, and ready persistent guard; writers remain frozen"
        return 1
    fi
    return 0
}

rr_rollback_target_is_subscription_safe() {
    local tx="$1" backup="" recorded="" restored=""
    backup="$tx/backup"
    [ -f "$backup/rollback-metadata-complete" ] || return 1
    [ "$(cat "$backup/rollback-metadata-complete" 2>/dev/null)" = 1 ] || return 1
    recorded=$(head -n 1 "$backup/rollback-runtime-version" 2>/dev/null || true)
    if [ "$recorded" = none ]; then
        [ -f "$backup/runtime_did_not_exist" ] && [ ! -e "$RR_LIB_DIR" ]
        return
    fi
    rr_semver_is_valid "$recorded" || return 1
    restored=$(rr_runtime_version "$RR_LIB_DIR/modules/00-runtime.sh" 2>/dev/null || true)
    [ "$restored" = "$recorded" ] || return 1
    rr_version_ge "$restored" "$RR_SUBSCRIPTION_SAFE_VERSION"
}

rr_write_rollback_subscription_status() {
    local tx="$1" status="$2"
    case "$status" in normal|quarantined|degraded) ;; *) return 1 ;; esac
    rr_write_private_value "$tx/rollback-subscription-status" "$status"
}

rr_apply_rollback_subscription_policy() {
    local tx="$1" backup="" version="unknown" recorded_version="" restored_version=""
    local snapshot_port="" restored_port="" port=0 status="" resume=0
    backup="$tx/backup"
    rr_transaction_dir_is_valid "$tx" || return 1
    if rr_rollback_target_is_subscription_safe "$tx"; then
        rr_clear_subscription_quarantine || return 1
        rr_write_rollback_subscription_status "$tx" normal
        return 0
    fi

    snapshot_port=$(head -n 1 "$backup/rollback-subscription-port" 2>/dev/null || true)
    restored_port=$(rr_config_subscription_port "$RR_CONFIG_FILE" 2>/dev/null || true)
    if [[ "$snapshot_port" =~ ^[0-9]+$ ]] && [ "$((10#$snapshot_port))" -ge 1 ] &&
       [ "$((10#$snapshot_port))" -le 65535 ] && [ "$restored_port" = "$((10#$snapshot_port))" ]; then
        port="$((10#$snapshot_port))"
    fi
    recorded_version=$(head -n 1 "$backup/rollback-runtime-version" 2>/dev/null || true)
    restored_version=$(rr_runtime_version "$RR_LIB_DIR/modules/00-runtime.sh" 2>/dev/null || true)
    if rr_semver_is_valid "$recorded_version" && [ "$recorded_version" = "$restored_version" ]; then
        version="$recorded_version"
    fi
    [ -f "$backup/subscription_was_running" ] && resume=1
    rr_activate_subscription_quarantine "$version" "$port" "$resume" || return 1
    rr_quarantine_marker_read || return 1
    status="$RR_QUARANTINE_STATE"
    rr_write_rollback_subscription_status "$tx" "$status"
}

rr_transaction_path() {
    local tx="" active_fd="" shell_pid="${BASHPID:-$$}" fd_path=""
    local path_identity="" fd_identity=""
    local -a active_lines=()
    [ -f "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ] || return 1
    exec {active_fd}<"$RR_ACTIVE_TX" || return 1
    fd_path="/proc/$shell_pid/fd/$active_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$active_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$RR_ACTIVE_TX" 2>/dev/null) || {
        exec {active_fd}>&-
        return 1
    }
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || {
        exec {active_fd}>&-
        return 1
    }
    if [ "$path_identity" != "$fd_identity" ] ||
       ! rr_transaction_metadata_identity_is_safe "$fd_identity" || [ -L "$RR_ACTIVE_TX" ]; then
        exec {active_fd}>&-
        return 1
    fi
    mapfile -t active_lines <&"$active_fd"
    if [ "${#active_lines[@]}" -ne 1 ]; then
        exec {active_fd}>&-
        return 1
    fi
    tx="${active_lines[0]}"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$RR_ACTIVE_TX" 2>/dev/null) || {
        exec {active_fd}>&-
        return 1
    }
    exec {active_fd}>&-
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$RR_ACTIVE_TX" ] || return 1
    rr_transaction_dir_is_valid "$tx" || return 1
    printf '%s\n' "$tx"
}

rr_active_transaction_evidence_present() {
    [ -e "$RR_ACTIVE_TX" ] || [ -L "$RR_ACTIVE_TX" ]
}

rr_republish_active_pointer_for_retry() {
    local expected="$1" parent="" temporary="" actual=""
    parent=$(dirname -- "$RR_ACTIVE_TX") || return 1
    [ "$parent" = "$RR_TX_ROOT" ] && [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ] || return 1
    rr_transaction_dir_is_valid "$expected" || return 1
    if rr_active_transaction_evidence_present; then
        actual=$(rr_transaction_path) || return 1
        [ "$actual" = "$expected" ] || return 1
        sync -f "$parent"
        return
    fi
    temporary=$(umask 077; mktemp "${RR_ACTIVE_TX}.retry.XXXXXX") || return 1
    if [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] ||
       ! printf '%s\n' "$expected" > "$temporary" || ! sync -f "$temporary" ||
       ! mv -f -- "$temporary" "$RR_ACTIVE_TX"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! sync -f "$parent"; then
        # The live strict pointer keeps this boot recoverable, but a broad sync
        # cannot substitute for a successfully reported directory fsync.
        sync || true
        return 1
    fi
    actual=$(rr_transaction_path) || return 1
    [ "$actual" = "$expected" ]
}

rr_clear_active_transaction_pointer() {
    local expected="$1" actual="" parent=""
    parent=$(dirname -- "$RR_ACTIVE_TX") || return 1
    if ! rr_active_transaction_evidence_present; then
        # Retrying an already-unlinked terminal pointer is safe only after the
        # parent directory itself can be flushed successfully.
        sync -f "$parent"
        return
    fi
    actual=$(rr_transaction_path) || return 1
    [ "$actual" = "$expected" ] || return 1
    rm -f -- "$RR_ACTIVE_TX" || return 1
    if sync -f "$parent"; then
        return 0
    fi
    rr_republish_active_pointer_for_retry "$expected" || true
    return 1
}

rr_restore_file() {
    local backup="$1" target="$2" temporary=""
    if [ -f "$RR_BACKUP/had_${backup}" ]; then
        mkdir -p "$(dirname "$target")" || return 1
        temporary="$(dirname "$target")/.rr-recovery.$$.tmp"
        cp -p "$RR_BACKUP/$backup" "$temporary" && mv -f "$temporary" "$target"
    else
        rm -f -- "$target"
    fi
}

rr_restore_dir() {
    local backup="$1" target="$2"
    rm -rf -- "$target" || return 1
    if [ -f "$RR_BACKUP/had_${backup}" ]; then
        if [ -L "$RR_BACKUP/$backup" ] || [ ! -d "$RR_BACKUP/$backup" ]; then
            rr_recover_log "refusing unsafe directory backup: ${backup}"
            return 1
        fi
        mkdir -p "$(dirname "$target")" || return 1
        cp -a "$RR_BACKUP/$backup" "$target"
    fi
}

rr_restore_database() {
    local target="/var/lib/rr-nexus/nexus.db"
    rm -f -- "$target" "${target}-wal" "${target}-shm" || return 1
    if [ -f "$RR_BACKUP/had_nexus.db" ]; then
        mkdir -p "$(dirname "$target")" || return 1
        install -m 600 "$RR_BACKUP/nexus.db" "$target"
    fi
}

rr_verify_restored_state() {
    if [ -f "$RR_BACKUP/had_rr_launcher" ] && [ ! -x "$RR_LAUNCHER" ]; then
        rr_recover_log "restored launcher is missing or not executable"
        return 1
    fi
    if [ ! -f "$RR_BACKUP/runtime_did_not_exist" ] && [ ! -d "$RR_LIB_DIR/modules" ]; then
        rr_recover_log "restored runtime is incomplete"
        return 1
    fi
    if [ -f "$RR_BACKUP/had_nexus.db" ]; then
        python3 - /var/lib/rr-nexus/nexus.db <<'PY' || return 1
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
try:
    row = db.execute("PRAGMA quick_check").fetchone()
    raise SystemExit(0 if row and row[0] == "ok" else 1)
finally:
    db.close()
PY
    fi
    if [ -f "$RR_BACKUP/singbox_was_running" ]; then
        [ -x /usr/local/bin/sing-box ] && [ -s /etc/sing-box/config.json ] || return 1
        /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || return 1
    fi
}

rr_restore_transaction() {
    local tx="$1" reason="${2:-automatic recovery}" failed_runtime="" subscription_stop_failed=false
    local subscription_policy="normal"
    RR_BACKUP="$tx/backup"
    rr_recover_log "$reason; restoring transaction $(basename "$tx")"
    if ! rr_freeze_health_writers_strict; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "could not freeze and verify health writers before restoring the old runtime"
        return 1
    fi
    if [ ! -d "$RR_BACKUP" ] || [ -L "$RR_BACKUP" ]; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "transaction backup is missing or unsafe; writers remain frozen and evidence is retained at $tx"
        return 1
    fi
    systemctl stop sing-box rr-nexus >/dev/null 2>&1 || true
    rr_stop_subscription_servers || subscription_stop_failed=true

    if [ -d "$tx/old-runtime" ]; then
        if [ -e "$RR_LIB_DIR" ]; then
            failed_runtime="$tx/failed-runtime-$(date +%s)"
            if ! mv "$RR_LIB_DIR" "$failed_runtime"; then
                rr_recovery_fail_with_health_frozen "$tx" \
                    "could not stage the failed candidate runtime; recovery evidence was retained"
                return 1
            fi
        fi
        mv "$tx/old-runtime" "$RR_LIB_DIR" || {
            [ -n "$failed_runtime" ] && [ -e "$failed_runtime" ] && mv "$failed_runtime" "$RR_LIB_DIR" 2>/dev/null || true
            rr_recovery_fail_with_health_frozen "$tx" \
                "could not restore the previous runtime; recovery evidence was retained"
            return 1
        }
    elif [ -f "$RR_BACKUP/runtime_did_not_exist" ]; then
        if ! rm -rf -- "$RR_LIB_DIR"; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "could not remove the failed first-install runtime; recovery evidence was retained"
            return 1
        fi
    fi

    local failed="$subscription_stop_failed"
    rr_restore_file rr_launcher "$RR_LAUNCHER" || failed=true
    rr_restore_file argo_vmess.conf /etc/argo_vmess.conf || failed=true
    rr_restore_file singbox_config.json /etc/sing-box/config.json || failed=true
    rr_restore_file singbox_cert.pem /etc/sing-box/cert.pem || failed=true
    rr_restore_file singbox_private.key /etc/sing-box/private.key || failed=true
    rr_restore_file singbox_binary /usr/local/bin/sing-box || failed=true
    rr_restore_file singbox.service /etc/systemd/system/sing-box.service || failed=true
    rr_restore_file health.service /etc/systemd/system/argo-rr-health.service || failed=true
    rr_restore_file health.timer /etc/systemd/system/argo-rr-health.timer || failed=true
    rr_restore_file auto_update_sub.py /usr/local/bin/auto_update_sub.py || failed=true
    rr_restore_file nexus.json /etc/rr-nexus/nexus.json || failed=true
    rr_restore_file nexus.service /etc/systemd/system/rr-nexus.service || failed=true
    rr_restore_file update_channel /etc/rr-update/channel || failed=true
    rr_restore_file remote.key /var/lib/rr-nexus/remote.key || failed=true
    rr_restore_dir rr-naive /etc/rr-naive || failed=true
    rr_restore_dir sub_server /tmp/sub_server || failed=true
    rr_restore_database || failed=true

    rr_restore_external_state_if_required "$tx" "$RR_BACKUP" || failed=true
    rr_verify_restored_state || failed=true
    systemctl daemon-reload >/dev/null 2>&1 || failed=true
    if [ "$failed" = true ]; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "internal or external rollback failed; writers remain frozen and evidence is retained at $tx"
        return 1
    fi

    if ! rr_apply_rollback_subscription_policy "$tx"; then
        failed=true
    fi
    subscription_policy=$(head -n 1 "$tx/rollback-subscription-status" 2>/dev/null || printf degraded)
    case "$subscription_policy" in normal|quarantined|degraded) ;; *) subscription_policy=degraded; failed=true ;; esac
    if [ "$failed" = true ]; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "rollback subscription policy failed; writers remain frozen and evidence is retained at $tx"
        return 1
    fi
    rr_restore_recorded_writer_state "$RR_BACKUP" "$subscription_policy" || failed=true

    if [ "$failed" = true ]; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "recovery was incomplete; writers remain frozen and evidence is retained at $tx"
        return 1
    fi
    if [ "$subscription_policy" != normal ]; then
        if ! rr_prepare_terminal_transaction_cleanup "$tx" rolled_back_degraded \
                "global rollback durability barrier failed; degraded evidence and maintenance were retained"; then
            return 1
        fi
        if ! rr_clear_update_maintenance_marker "$tx"; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "maintenance marker cleanup failed; writers remain frozen and evidence is retained at $tx"
            return 1
        fi
        if ! rr_clear_active_transaction_pointer "$tx"; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "active transaction cleanup was not durable; terminal evidence was retained at $tx"
            return 1
        fi
        rr_recover_log "rollback completed in DEGRADED mode: legacy public subscription is quarantined; upgrade to ${RR_SUBSCRIPTION_SAFE_VERSION}+ before re-enabling it"
        return 3
    fi
    if ! rr_prepare_terminal_transaction_cleanup "$tx" rolled_back \
            "global rollback durability barrier failed; transaction evidence and maintenance were retained"; then
        return 1
    fi
    if ! rr_clear_update_maintenance_marker "$tx"; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "maintenance marker cleanup failed; writers remain frozen and evidence is retained at $tx"
        return 1
    fi
    if ! rr_clear_active_transaction_pointer "$tx"; then
        rr_recovery_fail_with_health_frozen "$tx" \
            "active transaction cleanup was not durable; terminal evidence was retained at $tx"
        return 1
    fi
    rr_recover_log "rollback completed"
    if [ -f "$RR_BACKUP/runtime_did_not_exist" ]; then
        systemctl disable rr-update-recovery.service >/dev/null 2>&1 || true
        rm -f -- /etc/systemd/system/rr-update-recovery.service \
            /usr/local/sbin/rr-update-recover "$RR_UPDATE_EXTERNAL_HELPER"
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$RR_TX_ROOT"
    fi
}

main() {
    local mode="${1:-recover}" argument="${2:-}" tx="" phase="" format_state=0
    local settled_state=0 maintenance_state=0 publish_state=0 quarantine_json='{"active":false}'
    case "$mode" in
        recover|rollback|status|snapshot-metadata|apply-rollback-policy|suspend-quarantine|clear-quarantine|quarantine-guard) ;;
        *) echo "usage: rr-update-recover [recover|rollback|status|snapshot-metadata TX|apply-rollback-policy TX|suspend-quarantine|clear-quarantine|quarantine-guard]" >&2; return 2 ;;
    esac
    case "$mode" in
        recover|rollback|snapshot-metadata|apply-rollback-policy|suspend-quarantine|clear-quarantine)
            rr_acquire_update_lock || return 1
            ;;
    esac
    case "$mode" in
        snapshot-metadata) [ -n "$argument" ] || return 2; rr_snapshot_rollback_metadata "$argument"; return ;;
        apply-rollback-policy) [ -n "$argument" ] || return 2; rr_apply_rollback_subscription_policy "$argument"; return ;;
        suspend-quarantine) rr_suspend_subscription_quarantine; return ;;
        clear-quarantine) rr_clear_subscription_quarantine; return ;;
        quarantine-guard) rr_quarantine_guard; return ;;
    esac
    if [ "$mode" = status ]; then
        if [ -e "$RR_QUARANTINE_FILE" ] || [ -L "$RR_QUARANTINE_FILE" ] ||
           [ -e "$RR_QUARANTINE_GUARD_STATE" ] || [ -L "$RR_QUARANTINE_GUARD_STATE" ]; then
            if rr_quarantine_read_active_state; then
                quarantine_json=$(printf '{"active":true,"state":"%s","target_version":"%s","port":%s,"resume_subscription":%s}' \
                    "$RR_QUARANTINE_STATE" "$RR_QUARANTINE_VERSION" "$RR_QUARANTINE_PORT" "$RR_QUARANTINE_RESUME")
            else
                quarantine_json='{"active":true,"state":"invalid","target_version":"unknown","port":0,"resume_subscription":0}'
            fi
        elif rr_quarantine_artifact_evidence_present; then
            quarantine_json='{"active":true,"state":"invalid","target_version":"unknown","port":0,"resume_subscription":0}'
        fi
    fi
    tx=$(rr_transaction_path) || {
        if rr_active_transaction_evidence_present; then
            [ "$mode" = status ] && {
                printf '{"active":true,"transaction":"invalid","phase":"invalid","subscription_quarantine":%s}\n' \
                    "$quarantine_json"
                return 0
            }
            if ! rr_freeze_health_writers_strict; then
                rr_recover_log "invalid active transaction evidence found and health writers could not be verified inactive and disabled"
            fi
            rr_recover_log "active transaction pointer is unsafe or its target is missing; writers remain frozen and evidence was retained"
            return 1
        fi
        [ "$mode" = status ] && printf '{"active":false,"subscription_quarantine":%s}\n' "$quarantine_json"
        return 0
    }
    if ! phase=$(rr_read_trusted_phase "$tx"); then
        if [ "$mode" = status ]; then
            printf '{"active":true,"transaction":"%s","phase":"invalid","subscription_quarantine":%s}\n' \
                "$tx" "$quarantine_json"
            return 0
        fi
        if ! rr_freeze_health_writers_strict; then
            rr_recover_log "unsafe transaction phase found and health writers could not be verified inactive and disabled"
        fi
        rr_recover_log "transaction phase is missing, unsafe, multiline, or invalid; evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = status ]; then
        printf '{"active":true,"transaction":"%s","phase":"%s","subscription_quarantine":%s}\n' \
            "$tx" "$phase" "$quarantine_json"
        return 0
    fi
    if rr_transaction_format_state "$tx"; then
        format_state=0
    else
        format_state=$?
    fi
    if [ "$format_state" -eq 2 ]; then
        case "$phase" in
            committed|rolled_back|rolled_back_degraded|aborted) ;;
            *)
                if ! rr_freeze_health_writers_strict; then
                    rr_recover_log "unsafe transaction format found and health writers could not be verified inactive and disabled"
                fi
                rr_recovery_write_phase "$tx" recovery_failed || true
                ;;
        esac
        rr_recover_log "transaction format marker is unsafe; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$format_state" -eq 0 ] && ! rr_transaction_v2_control_metadata_is_safe "$tx"; then
        if ! rr_freeze_health_writers_strict; then
            rr_recover_log "format-2 transaction control metadata is unsafe and health writers could not be verified inactive and disabled"
        fi
        rr_recover_log "format-2 active/phase metadata is incomplete or unsafe; transaction retained at $tx"
        return 1
    fi
    # A pre-7.1.1 committed transaction predates format 2, the
    # committed-settled marker, and the --post-update-finalize launcher entry
    # point.  Under that contract, committed was already terminal and recover
    # intentionally left the rollback window untouched for the next installer
    # to retire.  The missing format marker alone is not enough to identify
    # that contract because early 7.1.1 transactions also used format 1; bind
    # the exception to the trusted live runtime version.  Do not invoke a
    # legacy launcher with a command it cannot understand, and do not replay
    # its writer snapshot over host state that may have legitimately changed
    # after the old installation completed.
    if [ "$mode" = recover ] && [ "$phase" = committed ] && \
       [ "$format_state" -eq 1 ]; then
        local legacy_runtime_version=""
        legacy_runtime_version=$(rr_trusted_runtime_version "$RR_LIB_DIR" 2>/dev/null) || {
            rr_recover_log "format-1 committed runtime version is unsafe; rollback evidence was retained"
            return 1
        }
        if ! rr_version_ge "$legacy_runtime_version" "$RR_POST_UPDATE_FINALIZE_VERSION"; then
            if ! rr_clear_update_maintenance_marker "$tx"; then
                rr_recover_log "legacy committed maintenance evidence is unsafe; rollback evidence was retained"
                return 1
            fi
            rr_recover_log "legacy committed transaction is already terminal; rollback evidence was retained"
            return 0
        fi
    fi
    # A valid settled marker retires automatic writer-state replay.  Recovery
    # still validates the live control metadata, but rollback-only backup
    # damage must not freeze a successfully committed installation.  Manual
    # rollback deliberately falls through to the complete backup validation.
    if [ "$mode" = recover ] && [ "$phase" = committed ]; then
        if rr_committed_settled_state "$tx"; then
            settled_state=0
        else
            settled_state=$?
        fi
        if [ "$settled_state" -eq 2 ]; then
            rr_recover_log "committed settled evidence is unsafe; no host state was changed and evidence was retained at $tx"
            return 1
        fi
        if [ "$settled_state" -eq 0 ]; then
            if rr_update_maintenance_marker_state "$tx"; then
                maintenance_state=0
            else
                maintenance_state=$?
            fi
            if [ "$maintenance_state" -eq 2 ]; then
                rr_recover_log "committed maintenance evidence is unsafe; no host state was changed and evidence was retained at $tx"
                return 1
            fi
            # A settled committed transaction is a dormant manual-rollback
            # window.  Never inspect or replay its old writer snapshot.
            [ "$maintenance_state" -eq 0 ] || return 0
            if ! sync; then
                rr_recover_log "settled committed cleanup could not flush host state; maintenance and rollback evidence were retained at $tx"
                return 1
            fi
            if ! rr_clear_update_maintenance_marker "$tx"; then
                rr_recover_log "settled committed cleanup could not clear maintenance; live writers were not frozen and evidence was retained at $tx"
                return 1
            fi
            return 0
        fi
    fi
    if [ "$format_state" -eq 0 ] && ! rr_transaction_v2_backup_metadata_is_safe "$tx"; then
        if ! rr_freeze_health_writers_strict; then
            rr_recover_log "format-2 transaction backup metadata is unsafe and health writers could not be verified inactive and disabled"
        fi
        rr_recover_log "format-2 backup/writer-state metadata is incomplete or unsafe; transaction retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && [ "$phase" = state_recorded ]; then
        if rr_prepare_terminal_transaction_cleanup "$tx" aborted \
                "global abort durability barrier failed; transaction evidence and maintenance were retained" && \
           rr_clear_update_maintenance_marker "$tx" && \
           rr_clear_active_transaction_pointer "$tx"; then
            rr_recover_log "stale state-record transaction discarded; no service had been stopped"
            return 0
        fi
        rr_recovery_fail_with_health_frozen "$tx" \
            "state-record recovery cleanup failed; terminal evidence was retained at $tx" || true
        rr_recover_log "state-record recovery failed; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && \
       { [ "$phase" = freezing ] || [ "$phase" = snapshotting ] || [ "$phase" = prepared ]; }; then
        RR_BACKUP="$tx/backup"
        if rr_ensure_update_maintenance_marker "$tx" && \
           rr_restore_recorded_writer_state "$RR_BACKUP" normal && \
           rr_prepare_terminal_transaction_cleanup "$tx" aborted \
               "global pre-mutation abort durability barrier failed; transaction evidence and maintenance were retained" && \
           rr_clear_update_maintenance_marker "$tx" && \
           rr_clear_active_transaction_pointer "$tx"; then
            rr_recover_log "stale pre-mutation transaction discarded; original service state restored"
            return 0
        fi
        rr_recovery_fail_with_health_frozen "$tx" \
            "pre-mutation service recovery cleanup failed; terminal evidence was retained at $tx" || true
        rr_recover_log "pre-mutation service recovery failed; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && [ "$phase" = committed ]; then
        if rr_update_maintenance_marker_state "$tx"; then
            maintenance_state=0
        else
            maintenance_state=$?
        fi
        if [ "$maintenance_state" -eq 2 ]; then
            rr_recover_log "committed maintenance evidence is unsafe; no host state was changed and evidence was retained at $tx"
            return 1
        fi
        RR_BACKUP="$tx/backup"
        if ! rr_ensure_update_maintenance_marker "$tx"; then
            rr_recover_log "committed maintenance gate could not be created or verified; no committed recovery mutation was attempted"
            return 1
        fi
        if ! rr_finalize_committed_candidate; then
            rr_freeze_health_writers_strict ||
                rr_recover_log "committed finalization failed and health writers could not be verified inactive and disabled"
            rr_recover_log "committed update finalization failed; active transaction and maintenance evidence retained at $tx"
            return 1
        fi
        if rr_quarantine_artifact_evidence_present &&
           ! rr_clear_subscription_quarantine; then
            rr_freeze_health_writers_strict ||
                rr_recover_log "committed quarantine cleanup failed and health writers could not be verified inactive and disabled"
            rr_recover_log "committed update is safe, but quarantine cleanup still requires retry; evidence retained at $tx"
            return 1
        fi
        if [ ! -d "$RR_BACKUP" ] || [ -L "$RR_BACKUP" ] ||
           ! rr_restore_recorded_writer_state "$RR_BACKUP" normal; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "committed cleanup could not restore the recorded writer state; evidence was retained at $tx"
            return 1
        fi
        if ! rr_prepare_terminal_transaction_cleanup "$tx" committed \
                "global committed durability barrier failed after writer restoration; active transaction and maintenance evidence were retained"; then
            return 1
        fi
        if rr_publish_committed_settled "$tx"; then
            publish_state=0
        else
            publish_state=$?
        fi
        case "$publish_state" in
            0) ;;
            2)
                rr_recover_log "committed settled evidence became visible but durability/readback was uncertain; live writers were not frozen and maintenance evidence was retained"
                return 1
                ;;
            *)
                rr_recovery_fail_with_health_frozen "$tx" \
                    "committed settled evidence could not be published; active transaction and maintenance evidence were retained"
                return 1
                ;;
        esac
        # Once settled is durable, retries deliberately do not replay the old
        # writer state.  A volatile marker cleanup failure therefore retains
        # evidence without freezing otherwise healthy live services.
        if ! rr_clear_update_maintenance_marker "$tx"; then
            rr_recover_log "committed update settled, but maintenance cleanup failed; evidence was retained at $tx"
            return 1
        fi
        return 0
    fi
    if [ "$mode" = recover ] && \
       { [ "$phase" = rolled_back ] || [ "$phase" = rolled_back_degraded ] || \
         [ "$phase" = aborted ]; }; then
        RR_BACKUP="$tx/backup"
        if ! rr_ensure_update_maintenance_marker "$tx"; then
            rr_recover_log "terminal maintenance gate could not be created or verified; no terminal writer restoration was attempted"
            return 1
        elif [ "$phase" = rolled_back_degraded ]; then
            rr_freeze_health_writers_strict || {
                rr_recover_log "degraded terminal recovery could not verify health writers inactive and disabled"
                return 1
            }
        elif [ ! -d "$RR_BACKUP" ] || [ -L "$RR_BACKUP" ] ||
             ! rr_restore_recorded_writer_state "$RR_BACKUP" normal; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "terminal cleanup could not restore the recorded writer state; evidence was retained at $tx"
            return 1
        fi
        if ! rr_prepare_terminal_transaction_cleanup "$tx" "$phase" \
                "global terminal durability barrier failed after terminal writer restoration; active transaction and maintenance evidence were retained"; then
            return 1
        fi
        if ! rr_clear_update_maintenance_marker "$tx"; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "terminal transaction marker cleanup failed; terminal phase and evidence retained at $tx"
            return 1
        fi
        if ! rr_clear_active_transaction_pointer "$tx"; then
            rr_recovery_fail_with_health_frozen "$tx" \
                "terminal active pointer cleanup was not durable; terminal phase and evidence retained at $tx"
            return 1
        fi
        return 0
    fi
    if ! rr_prepare_legacy_lock_for_rollback "$tx"; then
        if ! rr_freeze_health_writers_strict; then
            rr_recover_log "rollback metadata is untrusted and health writers could not be verified inactive and disabled"
        fi
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "rollback target version or legacy-lock evidence is unsafe; old runtime remains hidden and transaction evidence was retained at $tx"
        return 1
    fi
    if ! rr_ensure_update_maintenance_marker "$tx"; then
        rr_recover_log "rollback maintenance gate could not be created or verified; no rollback phase or runtime state was changed"
        return 1
    fi
    if [ "$mode" = rollback ] && [ "$phase" = committed ]; then
        if ! rr_recovery_write_phase "$tx" rolling_back; then
            rr_recover_log "manual rollback could not durably publish its in-progress phase; no runtime state was changed"
            return 1
        fi
        phase=rolling_back
    fi
    rr_restore_transaction "$tx" "$([ "$mode" = rollback ] && printf 'manual rollback requested' || printf 'interrupted update detected')"
}

if [ "${RR_UPDATE_RECOVER_SOURCE_ONLY:-0}" != 1 ]; then
    main "$@"
fi
