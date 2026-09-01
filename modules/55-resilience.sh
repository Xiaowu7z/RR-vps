# shellcheck shell=bash
# RR-vps 7.1 diagnostics, encrypted migration backups and update preflight.

RR_DIAGNOSTIC_DIR="/var/lib/rr/diagnostics"
RR_BACKUP_WORK_DIR="${RR_BACKUP_WORK_DIR:-/var/lib/rr-backup}"
RR_RESTORE_ACTIVE="${RR_BACKUP_WORK_DIR}/active"
RR_RESTORE_RUNTIME_READY="${RR_BACKUP_WORK_DIR}/runtime-ready"
RR_RESTORE_SYSTEMD_DIR="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}"
RR_RESTORE_LOCK_FILE="${RR_RESTORE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"
RR_LEGACY_UPDATE_LOCK_FILE="${RR_LEGACY_UPDATE_LOCK_FILE:-/run/lock/rr-update.lock}"
RR_LEGACY_UPDATE_BRIDGE_FILE="${RR_LEGACY_UPDATE_BRIDGE_FILE:-/run/rr-vps/legacy-update-bridge}"
RR_LEGACY_UPDATE_BRIDGE_VALUE="rr-legacy-update-bridge-v1"
RR_RESTORE_LIVE_LOCK_FILE="${RR_RESTORE_LIVE_LOCK_FILE:-/run/rr-vps/locks/restore-live.lock}"
RR_NEXUS_SECURITY_LOCK_FILE="${RR_NEXUS_SECURITY_LOCK_FILE:-/run/rr-vps/locks/nexus-security.lock}"
RR_RESTORE_LIVE_MARKER="${RR_RESTORE_LIVE_MARKER:-/run/rr-vps/restore-live}"
RR_RESTORE_WATCH_REQUEST="${RR_RESTORE_WATCH_REQUEST:-/run/rr-vps/restore-watch-request}"
RR_RESTORE_WATCH_TIMEOUT="${RR_RESTORE_WATCH_TIMEOUT:-3600}"
RR_RESTORE_GATE_DROPIN_NAME="zzzz-rr-restore-gate.conf"
RR_RESTORE_GATE_EXEC_CONDITION="/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate"
RR_RESTORE_FIREWALL_GATE_DROPIN_NAME="zzzzz-rr-firewall-quarantine.conf"
RR_RESTORE_FIREWALL_QUARANTINE_FILE="/var/lib/rr-vps/firewall-quarantine"
RR_RESTORE_NEXUS_GATE_DROPIN_NAME="zzzzzz-rr-nexus-ip-cert-gate.conf"
RR_RESTORE_NEXUS_GATE_EXEC_PATH="/usr/local/lib/rr-vps/nexus-ip-cert-gate"
RR_RESTORE_NEXUS_GATE_EXEC_ARGV="/usr/local/lib/rr-vps/nexus-ip-cert-gate /etc/rr-nexus/certs/ip.crt /etc/rr-nexus/certs/ip.key /etc/rr-nexus/certs/.ip-cert-pending"
RR_RESTORE_NEXUS_GATE_SNAPSHOT_NAME="nexus-ip-cert-gate.state"
RR_RESTORE_NEXUS_GATE_SNAPSHOT_FORMAT="rr-nexus-ip-cert-gate-snapshot-v1"
RR_RESTORE_IP_ACME_SNAPSHOT_NAME="nexus-ip-acme.state"
RR_RESTORE_IP_ACME_SNAPSHOT_FORMAT="rr-nexus-ip-acme-target-v1"
RR_RESTORE_IP_ACME_REMOVAL_MARKER_NAME="nexus-ip-acme.runtime-removal-authorized"
RR_RESTORE_IP_ACME_REMOVAL_MARKER_VALUE="rr-nexus-ip-acme-runtime-removal-v1"

rr_secure_lock_prepare() {
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

rr_secure_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" fd_identity=""
    local shell_pid="${BASHPID:-$$}"
    local fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [[ "$fd_identity" == *:0:0:600:1 ]]
}

rr_legacy_update_lock_mode_is_safe() {
    local mode="$1" mode_value=0
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    # 7.1.0 normally created this inode as 0644. Preserve an existing inode
    # exactly, but reject special/execute bits and group/other write access.
    (( (mode_value & 07133) == 0 ))
}

rr_legacy_update_bridge_required() {
    local marker="$RR_LEGACY_UPDATE_BRIDGE_FILE" directory="" canonical=""
    local expected_size=$(( ${#RR_LEGACY_UPDATE_BRIDGE_VALUE} + 1 ))
    local -a marker_lines=()
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 1
    fi
    directory=$(dirname -- "$marker") || return 2
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 2
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 2
    [ "$canonical" = "$directory" ] || return 2
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || return 2
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
    [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || return 2
    [ "$(stat -c %s -- "$marker" 2>/dev/null)" = "$expected_size" ] || return 2
    mapfile -t marker_lines < "$marker" || return 2
    [ "${#marker_lines[@]}" -eq 1 ] && \
        [ "${marker_lines[0]}" = "$RR_LEGACY_UPDATE_BRIDGE_VALUE" ] || return 2
}

rr_legacy_update_lock_parent_is_safe() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    local lock_dir="" canonical="" owner="" group="" mode="" mode_value=0
    lock_dir=$(dirname -- "$lock_file") || return 1
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] || return 1
    IFS=: read -r owner group mode < <(
        stat -c '%u:%g:%a' -- "$lock_dir" 2>/dev/null
    ) || return 1
    [ "$owner" = 0 ] && [ "$group" = 0 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    # /run/lock is commonly 1777. A world-writable compatibility directory is
    # acceptable only with sticky-bit replacement protection.
    if (( (mode_value & 0002) != 0 && (mode_value & 01000) == 0 )); then
        return 1
    fi
}

rr_legacy_update_lock_path_is_safe() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    local owner="" group="" mode="" links=""
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    IFS=: read -r owner group mode links < <(
        stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null
    ) || return 1
    [ "$owner" = 0 ] && [ "$group" = 0 ] && [ "$links" = 1 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_legacy_update_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" path_identity_after=""
    local fd_identity="" owner="" group="" mode="" links=""
    local shell_pid="${BASHPID:-$$}" fd_path=""
    fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    rr_legacy_update_lock_path_is_safe "$lock_file" || return 1
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ -f "$fd_path" ] || return 1
    [ ! -L "$lock_file" ] || return 1
    path_identity_after=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && \
        [ "$path_identity_after" = "$fd_identity" ] || return 1
    IFS=: read -r _ _ owner group mode links <<<"$fd_identity"
    [ "$owner" = 0 ] && [ "$group" = 0 ] && [ "$links" = 1 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_acquire_legacy_update_lock_fd() {
    local output_name="$1" lock_file="${2:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    local candidate_fd="" marker_state=0 evidence_owner="" evidence_group=""
    printf -v "$output_name" '%s' ''
    rr_legacy_update_bridge_required || marker_state=$?
    [ "$marker_state" -ne 2 ] || return 1
    if [ "$marker_state" -eq 1 ]; then
        # Without a trusted same-boot marker the shared predictable name is not
        # authoritative. Ignore any demonstrably non-root preplacement without
        # opening, following, changing or deleting it. Root-owned abnormal
        # evidence is still a host-integrity failure and remains fail-closed.
        if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
            return 0
        fi
        IFS=: read -r evidence_owner evidence_group < <(
            stat -c '%u:%g' -- "$lock_file" 2>/dev/null
        ) || return 1
        if [ "$evidence_owner" != 0 ]; then
            return 0
        fi
        [ "$evidence_group" = 0 ] || return 1
        [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
        rr_legacy_update_lock_parent_is_safe "$lock_file" || return 1
        rr_legacy_update_lock_path_is_safe "$lock_file" || return 1
        return 0
    fi
    # A trusted marker means an old process may still exist in this boot. The
    # public inode is now required: missing, unsafe, replaced or busy all fail.
    [ -e "$lock_file" ] || [ -L "$lock_file" ] || return 1
    rr_legacy_update_lock_parent_is_safe "$lock_file" || return 1
    rr_legacy_update_lock_path_is_safe "$lock_file" || return 1
    # Read-only opening deliberately leaves a trusted 7.1.0 inode's content,
    # ownership and mode untouched.
    exec {candidate_fd}<"$lock_file" || return 1
    if ! rr_legacy_update_lock_fd_is_safe "$lock_file" "$candidate_fd"; then
        exec {candidate_fd}>&-
        return 1
    fi
    if ! flock -n "$candidate_fd"; then
        exec {candidate_fd}>&-
        return 75
    fi
    printf -v "$output_name" '%s' "$candidate_fd"
}

rr_inherited_update_lock_fds_present() {
    local fd_path="" fd_number="" fd_identity="" lock_file="" lock_identity=""
    local shell_pid="${BASHPID:-$$}" fd_root=""
    local marker_state=0
    local -a lock_identities=()
    lock_file="$RR_RESTORE_LOCK_FILE"
    if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 2
        lock_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || return 2
        lock_identities+=("$lock_identity")
    fi
    rr_legacy_update_bridge_required || marker_state=$?
    [ "$marker_state" -ne 2 ] || return 2
    if [ "$marker_state" -eq 0 ]; then
        rr_legacy_update_lock_parent_is_safe "$RR_LEGACY_UPDATE_LOCK_FILE" || return 2
        rr_legacy_update_lock_path_is_safe "$RR_LEGACY_UPDATE_LOCK_FILE" || return 2
        lock_identity=$(stat -c '%d:%i' -- "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null) || return 2
        lock_identities+=("$lock_identity")
    fi
    # The restore owner deliberately keeps this separate lock for its full
    # transaction lifetime.  A quick-tunnel/subscription daemon must not
    # inherit it: after an owner SIGKILL that would make the service gate
    # mistake the child for the still-live restore process indefinitely.
    lock_file="$RR_RESTORE_LIVE_LOCK_FILE"
    if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 2
        [ "$(stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null)" = \
            0:0:600:1 ] || return 2
        lock_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || return 2
        lock_identities+=("$lock_identity")
    fi
    [ "${#lock_identities[@]}" -gt 0 ] || return 1
    fd_root="/proc/$shell_pid/fd"
    [ -d "$fd_root" ] || fd_root=/dev/fd
    [ -d "$fd_root" ] || return 2
    for fd_path in "$fd_root"/*; do
        fd_number=${fd_path##*/}
        [[ "$fd_number" =~ ^[0-9]+$ ]] && [ "$fd_number" -gt 2 ] || continue
        fd_identity=$(stat -Lc '%d:%i' -- "$fd_path" 2>/dev/null) || continue
        for lock_identity in "${lock_identities[@]}"; do
            [ "$fd_identity" != "$lock_identity" ] || return 0
        done
    done
    return 1
}

rr_close_inherited_update_lock_fds() {
    local fd_path="" fd_number="" fd_identity="" lock_file="" lock_identity=""
    local shell_pid="${BASHPID:-$$}" fd_root=""
    local marker_state=0
    local -a lock_identities=()
    lock_file="$RR_RESTORE_LOCK_FILE"
    if [ -f "$lock_file" ] && [ ! -L "$lock_file" ]; then
        lock_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || return 1
        lock_identities+=("$lock_identity")
    fi
    rr_legacy_update_bridge_required || marker_state=$?
    [ "$marker_state" -ne 2 ] || return 1
    if [ "$marker_state" -eq 0 ]; then
        rr_legacy_update_lock_parent_is_safe "$RR_LEGACY_UPDATE_LOCK_FILE" || return 1
        rr_legacy_update_lock_path_is_safe "$RR_LEGACY_UPDATE_LOCK_FILE" || return 1
        lock_identity=$(stat -c '%d:%i' -- "$RR_LEGACY_UPDATE_LOCK_FILE" 2>/dev/null) || return 1
        lock_identities+=("$lock_identity")
    fi
    lock_file="$RR_RESTORE_LIVE_LOCK_FILE"
    if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
        [ "$(stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null)" = \
            0:0:600:1 ] || return 1
        lock_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || return 1
        lock_identities+=("$lock_identity")
    fi
    fd_root="/proc/$shell_pid/fd"
    [ -d "$fd_root" ] || fd_root=/dev/fd
    [ -d "$fd_root" ] || return 1
    for fd_path in "$fd_root"/*; do
        fd_number=${fd_path##*/}
        [[ "$fd_number" =~ ^[0-9]+$ ]] && [ "$fd_number" -gt 2 ] || continue
        fd_identity=$(stat -Lc '%d:%i' -- "$fd_path" 2>/dev/null) || continue
        for lock_identity in "${lock_identities[@]}"; do
            [ "$fd_identity" = "$lock_identity" ] || continue
            # fd_number is regex-validated before brace-fd close expansion.
            local inherited_fd="$fd_number"
            exec {inherited_fd}>&-
            break
        done
    done
}

rr_run_without_inherited_update_lock_fds() {
    local callback="$1" probe_result=0
    shift
    rr_inherited_update_lock_fds_present || probe_result=$?
    case "$probe_result" in
        0)
            (
                rr_close_inherited_update_lock_fds || return 1
                RR_UPDATE_LOCK_FDS_CLOSED=1 RR_UPDATE_LOCK_HELD=1 \
                    RR_RESTORE_LOCK_HELD=1 "$callback" "$@"
            )
            ;;
        1)
            RR_UPDATE_LOCK_FDS_CLOSED=1 RR_UPDATE_LOCK_HELD=1 \
                RR_RESTORE_LOCK_HELD=1 "$callback" "$@"
            ;;
        *) return 1 ;;
    esac
}

rr_run_with_update_locks() {
    local callback_mode="$1" wait_seconds="$2" callback="$3"
    local new_lock_fd="" legacy_lock_fd="" result=0
    shift 3
    case "$callback_mode" in direct|isolated) ;; *) return 76 ;; esac
    rr_secure_lock_prepare "$RR_RESTORE_LOCK_FILE" || return 76
    exec {new_lock_fd}>>"$RR_RESTORE_LOCK_FILE" || return 76
    if ! rr_secure_lock_fd_is_safe "$RR_RESTORE_LOCK_FILE" "$new_lock_fd"; then
        exec {new_lock_fd}>&-
        return 76
    fi
    if [ "$wait_seconds" = 0 ]; then
        flock -n "$new_lock_fd" || { exec {new_lock_fd}>&-; return 75; }
    else
        [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [ "$wait_seconds" -ge 1 ] && \
            [ "$wait_seconds" -le 86400 ] || { exec {new_lock_fd}>&-; return 76; }
        flock -w "$wait_seconds" "$new_lock_fd" || { exec {new_lock_fd}>&-; return 75; }
    fi
    if rr_acquire_legacy_update_lock_fd legacy_lock_fd "$RR_LEGACY_UPDATE_LOCK_FILE"; then
        :
    else
        result=$?
        exec {new_lock_fd}>&-
        [ "$result" -ne 1 ] || result=76
        return "$result"
    fi
    if [ "$callback_mode" = isolated ]; then
        (
            [ -z "$legacy_lock_fd" ] || exec {legacy_lock_fd}>&-
            exec {new_lock_fd}>&-
            RR_UPDATE_LOCK_OWNER=0 RR_UPDATE_LOCK_FDS_CLOSED=1 \
                RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
                "$callback" "$@"
        ) || result=$?
    else
        RR_UPDATE_LOCK_OWNER=1 RR_UPDATE_LOCK_FDS_CLOSED=0 \
            RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
            "$callback" "$@" || result=$?
    fi
    [ -z "$legacy_lock_fd" ] || exec {legacy_lock_fd}>&-
    exec {new_lock_fd}>&-
    return "$result"
}

# External CLI helpers invoked from an isolated locked callback inherit only
# delegation flags, not the lock descriptors.  Authenticate that delegation
# by proving a root ancestor still owns the exact current shared-lock inode;
# ambient environment variables alone are never sufficient.
rr_delegated_update_lock_context_is_trusted() {
    local lock_file="$RR_RESTORE_LOCK_FILE" lock_identity="" pid="${PPID:-0}"
    local lock_dir="" canonical="" probe_fd=""
    local fd_path="" fd_identity="" parent="" depth=0 uid_line=""
    [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] && \
        [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ] && \
        [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ] && \
        [ "${RR_UPDATE_LOCK_OWNER:-0}" = 0 ] || return 1
    lock_dir=$(dirname -- "$lock_file") || return 1
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$lock_dir" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    lock_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || return 1
    exec {probe_fd}>>"$lock_file" || return 1
    if flock -n "$probe_fd"; then
        flock -u "$probe_fd" 2>/dev/null || true
        exec {probe_fd}>&-
        return 1
    fi
    exec {probe_fd}>&-
    while [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$depth" -lt 32 ]; do
        [ -d "/proc/$pid/fd" ] || return 1
        uid_line=$(awk '/^Uid:/ {print $2":"$3":"$4":"$5; exit}' \
            "/proc/$pid/status" 2>/dev/null) || return 1
        [ "$uid_line" = 0:0:0:0 ] || return 1
        for fd_path in "/proc/$pid/fd"/*; do
            fd_identity=$(stat -Lc '%d:%i' -- "$fd_path" 2>/dev/null) || continue
            [ "$fd_identity" != "$lock_identity" ] || return 0
        done
        parent=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" \
            2>/dev/null) || return 1
        [ "$parent" != "$pid" ] || return 1
        pid="$parent"
        depth=$((depth + 1))
    done
    return 1
}

rr_run_mutating_entrypoint() {
    local callback="$1" result=0
    shift
    [[ "$callback" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && \
        declare -F "$callback" >/dev/null 2>&1 || return 76
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ]; then
        rr_delegated_update_lock_context_is_trusted || return 76
        "$callback" "$@"
        return $?
    fi
    rr_run_with_update_locks isolated 0 "$callback" "$@" || result=$?
    return "$result"
}

rr_ensure_resilience_dependencies() {
    if python3 -c 'import cryptography' >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1; then
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 || return 1
    printf '首次使用加密迁移功能，正在补齐系统加密与 SQLite 组件…\n'
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null && \
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
            python3-cryptography sqlite3 >/dev/null
}

rr_backup_prepare_work_dir() {
    local canonical=""
    if [ -e "$RR_BACKUP_WORK_DIR" ] || [ -L "$RR_BACKUP_WORK_DIR" ]; then
        [ -d "$RR_BACKUP_WORK_DIR" ] && [ ! -L "$RR_BACKUP_WORK_DIR" ] || return 1
    else
        install -d -m 700 "$RR_BACKUP_WORK_DIR" || return 1
    fi
    canonical=$(readlink -f -- "$RR_BACKUP_WORK_DIR" 2>/dev/null) || return 1
    [ "$canonical" = "$RR_BACKUP_WORK_DIR" ] || return 1
    [ "$(stat -c '%u:%g' "$RR_BACKUP_WORK_DIR" 2>/dev/null)" = 0:0 ] || return 1
    chmod 700 "$RR_BACKUP_WORK_DIR" || return 1
    [ "$(stat -c %a "$RR_BACKUP_WORK_DIR" 2>/dev/null)" = 700 ]
}

rr_backup_stage_is_safe() {
    local stage="$1" expected_kind="${2:-}" name="" canonical=""
    [ "$(dirname -- "$stage")" = "$RR_BACKUP_WORK_DIR" ] || return 1
    name=$(basename -- "$stage") || return 1
    case "$expected_kind" in
        create) [[ "$name" =~ ^create\.[A-Za-z0-9]+$ ]] || return 1 ;;
        restore) [[ "$name" =~ ^restore\.[A-Za-z0-9]+$ ]] || return 1 ;;
        *) [[ "$name" =~ ^(create|restore)\.[A-Za-z0-9]+$ ]] || return 1 ;;
    esac
    [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
    canonical=$(readlink -f -- "$stage" 2>/dev/null) || return 1
    [ "$canonical" = "$stage" ] || return 1
    [ "$(stat -c '%u:%g:%a' "$stage" 2>/dev/null)" = 0:0:700 ]
}

rr_backup_prune_stale_stages() {
    local active="" stage=""
    if [ -e "$RR_RESTORE_ACTIVE" ] || [ -L "$RR_RESTORE_ACTIVE" ]; then
        active=$(rr_restore_active_stage) || return 1
    fi
    for stage in "$RR_BACKUP_WORK_DIR"/create.* "$RR_BACKUP_WORK_DIR"/restore.*; do
        [ -e "$stage" ] || [ -L "$stage" ] || continue
        [ "$stage" != "$active" ] || continue
        rr_backup_stage_is_safe "$stage" || return 1
        rm -rf -- "$stage" || return 1
    done
}

rr_emit_alert() {
    [ -r /var/lib/rr-nexus/nexus.db ] || return 0
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.notify_cli "$@" >/dev/null 2>&1 || true
}

rr_doctor_add() {
    local level="$1" id="$2" summary="$3" detail="${4:-}" suggestion="${5:-}"
    case "$level" in
        ok) RR_DOCTOR_OK=$((RR_DOCTOR_OK + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '✅ %s\n' "$summary" ;;
        warn) RR_DOCTOR_WARN=$((RR_DOCTOR_WARN + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '⚠️  %s\n' "$summary" ;;
        fail) RR_DOCTOR_FAIL=$((RR_DOCTOR_FAIL + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '❌ %s\n' "$summary" ;;
        *) return 1 ;;
    esac
    if [ "${RR_DOCTOR_JSON_ONLY:-false}" != true ]; then
        [ -n "$detail" ] && printf '   %s\n' "$detail"
        [ -n "$suggestion" ] && printf '   建议：%s\n' "$suggestion"
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg level "$level" --arg id "$id" --arg summary "$summary" \
            --arg detail "$detail" --arg suggestion "$suggestion" \
            '{level:$level,id:$id,summary:$summary,detail:$detail,suggestion:$suggestion}' \
            >> "$RR_DOCTOR_EVENTS"
    fi
}

rr_doctor_redact() {
    local source="$1" target="$2"
    sed -E \
        -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g' \
        -e 's#([?&](token|key|secret|password|auth)=)[^&[:space:]"}]+#\1***#Ig' \
        -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}#***-UUID-REDACTED***#g' \
        -e 's#([A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})#***-TOKEN-REDACTED***#g' \
        -e 's#(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)#\1***-IP-REDACTED***\3#g' \
        -e 's#([A-Za-z0-9-]+\.)+[A-Za-z]{2,}#***-DOMAIN-REDACTED***#g' \
        "$source" > "$target"
}

rr_doctor_firewall_state() {
    local port="$1" proto="$2" policy=""
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 1 | grep -qi active; then
        ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}[[:space:]]+ALLOW" && return 0
        return 1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$port" -m comment \
            --comment "$FIREWALL_BLOCK_COMMENT" -j DROP >/dev/null 2>&1 && return 1
        iptables -C INPUT -p "$proto" --dport "$port" -m comment \
            --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 && return 0
        policy=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P" && $2=="INPUT" {print $3; exit}')
        [ "$policy" = ACCEPT ] && return 0
        return 1
    fi
    return 2
}

rr_doctor_check_endpoint() {
    local name="$1" port="$2" proto="$3" state=0
    if ! is_valid_port "$port"; then
        rr_doctor_add fail "port_${name}" "${name} 端口配置无效" "port=${port:-empty}" "在协议菜单重新设置端口"
        return
    fi
    case "$proto" in
        tcp) ss -H -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN ;;
        udp) ss -H -lun "sport = :$port" 2>/dev/null | grep -qE 'UNCONN|ESTAB' ;;
        *) return ;;
    esac
    if [ "$?" -eq 0 ]; then
        rr_doctor_add ok "port_${name}" "${name} ${proto^^}/${port} 正在监听"
    else
        rr_doctor_add fail "port_${name}" "${name} ${proto^^}/${port} 未监听" "协议已启用但没有对应套接字" "查看 Sing-box 配置与服务日志"
    fi
    rr_doctor_firewall_state "$port" "$proto" || state=$?
    case "$state" in
        0) rr_doctor_add ok "firewall_${name}" "${name} ${proto^^}/${port} 防火墙允许" ;;
        1) rr_doctor_add fail "firewall_${name}" "${name} ${proto^^}/${port} 被防火墙阻止" "RR 放行规则不存在或存在拒绝规则" "执行 rr doctor --repair" ;;
        *) rr_doctor_add warn "firewall_${name}" "未检测到可识别的防火墙管理器" "端口监听正常，但无法确认云厂商安全组" "同时检查 VPS 控制台安全组" ;;
    esac
}

rr_singbox_service_start_preflight() {
    ensure_singbox_service_guards || return 1
    rr_singbox_service_guards_are_effective
}

rr_singbox_systemctl_start_checked() {
    rr_singbox_service_start_preflight || return 1
    systemctl start sing-box "$@"
}

rr_nexus_service_start_preflight() {
    nexus_service_start_preflight
}

rr_nexus_systemctl_start_checked() {
    rr_nexus_service_start_preflight || return 1
    systemctl start rr-nexus "$@"
}

rr_doctor_repair_locked() {
    local nodes_enabled="$1" json_only="$2"
    local repair_failed=false repair_firewall_status=0
    [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] && \
        [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ] || return 1
    [ "$json_only" = true ] || printf '\n执行安全修复…\n'
    if rr_firewall_fail_closed_quarantine_active; then
        rr_firewall_repair_fail_closed_quarantine >/dev/null 2>&1 || \
            repair_firewall_status=$?
        if [ "$repair_firewall_status" -ne 0 ]; then
            repair_failed=true
            rr_doctor_add fail repair_firewall_quarantine \
                '防火墙持久隔离未能解除' \
                "status=${repair_firewall_status}；公网运行面保持停止" \
                '人工核对 live/持久规则后再次运行 rr doctor --repair'
        fi
    fi
    if [ "$repair_failed" = false ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || repair_failed=true
        for repair_path in /etc/rr-nexus/nexus.json /var/lib/rr-nexus/nexus.db \
            /var/lib/rr-nexus/remote.key; do
            [ -e "$repair_path" ] || continue
            chmod 600 "$repair_path" 2>/dev/null || repair_failed=true
        done
        systemctl daemon-reload >/dev/null 2>&1 || repair_failed=true
        if [ "$nodes_enabled" = true ] && [ "$repair_failed" = false ]; then
            if [ ! -x "$SINGBOX_BIN" ] || \
               ! "$SINGBOX_BIN" check -c /etc/sing-box/config.json \
                    >/dev/null 2>&1 || \
               ! rr_singbox_service_start_preflight || \
               ! restart_singbox >/dev/null 2>&1 || \
               ! managed_singbox_running; then
                repair_failed=true
            fi
        fi
        if [ -r /etc/rr-nexus/nexus.json ] && \
           { ! nexus_systemctl_restart_checked >/dev/null 2>&1 || \
             ! systemctl is-active --quiet rr-nexus; }; then
            repair_failed=true
        fi
        if [ "$repair_failed" = true ]; then
            rr_doctor_add fail repair_services \
                '受管服务修复或状态复核失败' \
                'daemon-reload/restart/active proof 未全部通过' \
                '检查 systemd 状态与服务日志'
        fi
    fi
    if [ "$repair_failed" = false ]; then
        HEALTH_CHECK_DONE=false
        if ! ensure_runtime_health >/dev/null 2>&1; then
            repair_failed=true
            rr_doctor_add fail repair_runtime \
                '运行状态安全修复未完成' \
                '健康修复返回失败，未将其视为成功' \
                '检查服务日志与防火墙事务证据'
        fi
    fi
    if [ "$repair_failed" = false ] && [ "$nodes_enabled" = true ]; then
        if ! generate_node_and_sub >/dev/null 2>&1; then
            repair_failed=true
            rr_doctor_add fail repair_subscription \
                '节点与订阅修复未完成' \
                '订阅重建返回失败' \
                '检查 Sing-box 配置与订阅服务日志'
        fi
        repair_firewall_status=0
        open_configured_firewall >/dev/null 2>&1 || repair_firewall_status=$?
        if [ "$repair_firewall_status" -ne 0 ]; then
            repair_failed=true
            case "$repair_firewall_status" in
                1|10)
                    rr_doctor_add fail repair_firewall \
                        '防火墙修复失败，已证明保持原态' \
                        "status=${repair_firewall_status}" \
                        '排除 UFW/NAT 冲突或安装 netfilter 持久化后重试'
                    ;;
                2)
                    rr_doctor_add fail repair_firewall \
                        '防火墙修复状态不确定' \
                        'RR 公网运行面已停止并验证 inactive' \
                        '立即人工检查 live 与持久规则'
                    ;;
                *)
                    rr_doctor_add fail repair_firewall \
                        '防火墙修复状态不确定且无法证明停服' \
                        "status=${repair_firewall_status}" \
                        '立即隔离主机并人工检查'
                    ;;
            esac
        fi
    fi
    if [ "$repair_failed" = false ]; then
        [ "$json_only" = true ] || \
            printf '安全修复完成；请再次运行 rr doctor 验证。\n'
        return 0
    fi
    [ "$json_only" = true ] || \
        printf '安全修复未完成；已记录失败且未伪报成功。\n' >&2
    return 1
}

rr_doctor() {
    local repair=false report=false json_only=false arg=""
    for arg in "$@"; do
        case "$arg" in
            --repair) repair=true ;;
            --report) report=true ;;
            --json) json_only=true ;;
            *) printf '用法：rr doctor [--repair] [--report] [--json]\n' >&2; return 2 ;;
        esac
    done

    RR_DOCTOR_OK=0
    RR_DOCTOR_WARN=0
    RR_DOCTOR_FAIL=0
    RR_DOCTOR_JSON_ONLY="$json_only"
    RR_DOCTOR_EVENTS=$(mktemp /tmp/rr-doctor-events.XXXXXX) || return 1
    chmod 600 "$RR_DOCTOR_EVENTS"
    local started report_file="" free_kb="" cert_file="" cert_days="" db_result="" nodes_enabled=false
    local repair_lock_status=0
    started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [ "$json_only" = true ] || printf '\nRR-vps %s 一键体检\n%s\n' "$SCRIPT_VERSION" '────────────────────────────────────────'

    if check_supported_os >/dev/null 2>&1; then
        rr_doctor_add ok system "系统版本受支持" "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
    else
        rr_doctor_add fail system "系统版本不受支持" "仅支持 Debian 12 / Ubuntu 22.04 / 24.04" "迁移到受支持系统后再更新"
    fi

    if getent ahosts github.com >/dev/null 2>&1; then
        rr_doctor_add ok dns "DNS 解析正常"
    else
        rr_doctor_add fail dns "DNS 无法解析 github.com" "更新与证书申请会失败" "检查 /etc/resolv.conf 与 VPS 网络"
    fi

    if command -v timedatectl >/dev/null 2>&1 && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
        rr_doctor_add ok clock "系统时间已同步"
    else
        rr_doctor_add warn clock "无法确认系统时间同步" "时间漂移会导致 TLS、TOTP 与更新校验异常" "启用 systemd-timesyncd 或 chrony"
    fi

    if load_config_with_defaults >/dev/null 2>&1; then
        rr_doctor_add ok config "RR 配置可读取" "schema=${CONFIG_VERSION:-unknown}"
        any_node_protocol_enabled && nodes_enabled=true
    else
        rr_doctor_add fail config "RR 配置读取失败" "$CONFIG_FILE" "从备份恢复配置或重新运行安装"
    fi

    detect_public_ips
    if [ -n "$PUBLIC_IPV4" ]; then
        rr_doctor_add ok public_ipv4 "公网 IPv4 入口可用" "$IPV4_ENTRY_SOURCE"
    else
        rr_doctor_add warn public_ipv4 "未检测到公网 IPv4" "纯 IPv6 机器可忽略"
    fi
    if [ -n "$PUBLIC_IPV6" ]; then
        rr_doctor_add ok public_ipv6 "公网 IPv6 入口可用" "$IPV6_ENTRY_SOURCE"
    elif [ "${IPV6_NAT66_DETECTED:-false}" = true ]; then
        rr_doctor_add warn public_ipv6 "检测到 NAT66，缺少手动公网 IPv6" "出口地址不能直接作为容器入口" "在入口设置中填写服务商映射地址"
    else
        rr_doctor_add warn public_ipv6 "未检测到公网 IPv6" "纯 IPv4 机器可忽略"
    fi

    if [ "$nodes_enabled" = true ]; then
      if [ -x "$SINGBOX_BIN" ] && [ -s /etc/sing-box/config.json ] && \
       "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        rr_doctor_add ok singbox_config "Sing-box 配置语法正常"
    else
        rr_doctor_add fail singbox_config "Sing-box 配置校验失败" "配置不存在或核心拒绝加载" "运行 rr doctor --repair；仍失败时查看 journalctl -u sing-box"
    fi

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        rr_doctor_add ok singbox_service "Sing-box 服务运行中"
    else
        rr_doctor_add fail singbox_service "Sing-box 服务未运行" "$(systemctl is-failed sing-box 2>/dev/null || true)" "查看 journalctl -u sing-box -n 80"
    fi

    [ "${VL_ENABLED:-false}" = true ] && rr_doctor_check_endpoint vless "$VL_PORT" tcp
    [ "${HY2_ENABLED:-false}" = true ] && rr_doctor_check_endpoint hysteria2 "$HY2_PORT" udp
    [ "${TU5_ENABLED:-false}" = true ] && rr_doctor_check_endpoint tuic "$TU5_PORT" udp
    [ "${AN_ENABLED:-false}" = true ] && rr_doctor_check_endpoint anytls "$AN_PORT" tcp
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        [ "${NAIVE_MODE:-h2}" = h3 ] || rr_doctor_check_endpoint naive_h2 "$NAIVE_PORT" tcp
        [ "${NAIVE_MODE:-h2}" = h2 ] || rr_doctor_check_endpoint naive_h3 "$NAIVE_PORT" udp
    fi
    [ "${VM_ENABLED:-false}" = true ] && [ "${VM_TLS_ENABLED:-false}" = true ] && \
        rr_doctor_check_endpoint vmess_tls "$PORT" tcp
    if [ "${VM_ENABLED:-false}" = true ] && [ "${VM_TLS_ENABLED:-false}" != true ]; then
        if expected_argo_tunnel_running; then
            rr_doctor_add ok argo "Argo 隧道运行中" "$([ "${TUNNEL_MODE:-1}" = 2 ] && printf '固定隧道' || printf '快速隧道')"
        else
            rr_doctor_add fail argo "Argo 隧道未运行" "VMess-WS 源站已启用但隧道离线" "执行 rr doctor --repair"
        fi
    fi
    else
        rr_doctor_add warn singbox_service "当前没有启用节点协议" "管理框架保持待机，不要求 Sing-box 或订阅服务运行"
    fi

    if [ -r /etc/rr-nexus/nexus.json ]; then
        if [ -r /var/lib/rr-nexus/nexus.db ] && command -v sqlite3 >/dev/null 2>&1; then
            db_result=$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA quick_check;' 2>/dev/null || true)
            if [ "$db_result" = "ok" ]; then
                rr_doctor_add ok nexus_db "RR Nexus 数据库完整"
            else
                rr_doctor_add fail nexus_db "RR Nexus 数据库完整性异常" "${db_result:-无法读取}" "不要删除数据库；优先从加密备份恢复"
            fi
        else
            rr_doctor_add warn nexus_db "Nexus 尚未安装或数据库不存在"
        fi
        if systemctl is-active --quiet rr-nexus 2>/dev/null; then
            local nexus_port=""
            nexus_port=$(jq -r '.port // 7900' /etc/rr-nexus/nexus.json 2>/dev/null || printf 7900)
            if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${nexus_port}/healthz" >/dev/null 2>&1; then
                rr_doctor_add ok nexus_service "RR Nexus 服务与健康接口正常"
            else
                rr_doctor_add fail nexus_service "RR Nexus 进程存在但健康门禁失败" "http://127.0.0.1:${nexus_port}/healthz" "检查数据库与 journalctl -u rr-nexus"
            fi
        else
            rr_doctor_add fail nexus_service "RR Nexus 服务未运行" "面板 API 不可用" "查看 journalctl -u rr-nexus -n 80"
        fi
    else
        rr_doctor_add warn nexus "RR Nexus 未安装" "不影响节点协议"
    fi

    if [ "$nodes_enabled" = true ]; then
        rr_doctor_check_endpoint subscription "${SUB_PORT:-0}" tcp
        local subscription_root="${SUB_ROOT}/${UUID}" missing_subscriptions="" required_subscription=""
        for required_subscription in jhsub.txt jhsub_encoded.txt client.json; do
            [ -s "$subscription_root/$required_subscription" ] || missing_subscriptions+=" ${required_subscription}"
        done
        if [ "${CLASH_ENABLED:-false}" = true ]; then
            for required_subscription in clash_meta.yaml client-mihomo.yaml client-clash-verge.yaml client-flclash.yaml; do
                [ -s "$subscription_root/$required_subscription" ] || missing_subscriptions+=" ${required_subscription}"
            done
        fi
        if [ -z "$missing_subscriptions" ] && jq -e . "$subscription_root/client.json" >/dev/null 2>&1; then
            rr_doctor_add ok subscription_formats "订阅格式完整且 Sing-box 客户端 JSON 有效"
        else
            rr_doctor_add fail subscription_formats "订阅产物缺失或格式无效" "缺失:${missing_subscriptions:- client.json(JSON)}" "执行 rr doctor --repair"
        fi
    fi

    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        cert_file=/etc/rr-naive/fullchain.pem
        if [ -s "$cert_file" ] && command -v openssl >/dev/null 2>&1; then
            if openssl x509 -checkend $((14 * 86400)) -noout -in "$cert_file" >/dev/null 2>&1; then
                rr_doctor_add ok naive_cert "NaiveProxy 真证书有效期充足"
            elif openssl x509 -checkend 0 -noout -in "$cert_file" >/dev/null 2>&1; then
                cert_days=$(python3 - "$cert_file" <<'PY' 2>/dev/null || true
import datetime, ssl, sys
value = ssl._ssl._test_decode_cert(sys.argv[1])["notAfter"]
end = datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
print(max(0, int((end-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400)))
PY
)
                rr_doctor_add warn naive_cert "NaiveProxy 证书即将到期" "剩余约 ${cert_days:-14} 天" "检查 certbot renew 与续签钩子"
            else
                rr_doctor_add fail naive_cert "NaiveProxy 证书已过期" "$cert_file" "立即运行证书申请/续签"
            fi
        else
            rr_doctor_add fail naive_cert "NaiveProxy 已启用但证书缺失" "$cert_file" "在协议菜单重新申请 Let's Encrypt 证书"
        fi
    fi

    free_kb=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -ge 262144 ]; then
        rr_doctor_add ok disk "磁盘可用空间充足" "$((free_kb / 1024)) MiB 可用"
    else
        rr_doctor_add fail disk "磁盘空间不足" "更新至少需要 256 MiB 可用空间" "清理日志和无用安装包"
    fi

    if rr_download_file "$RR_MANIFEST_URL" "${RR_DOCTOR_EVENTS}.manifest" 5 && \
       rr_manifest_is_valid "${RR_DOCTOR_EVENTS}.manifest"; then
        rr_doctor_add ok update_source "${RR_UPDATE_CHANNEL:-stable} 更新源可用"
    else
        rr_doctor_add warn update_source "更新源暂不可用" "Raw/API/CDN 均已尝试" "检查 DNS、IPv4/IPv6 路由或稍后重试"
    fi
    rm -f "${RR_DOCTOR_EVENTS}.manifest"

    if [ "$repair" = true ]; then
        rr_run_with_update_locks isolated 0 rr_doctor_repair_locked \
            "$nodes_enabled" "$json_only" || repair_lock_status=$?
        case "$repair_lock_status" in
            0) ;;
            75)
                rr_doctor_add fail repair_busy \
                    '安全修复未执行：另一更新/备份/恢复事务正在运行' \
                    '共享事务锁 busy；零修复 mutation' \
                    '等待当前事务结束后重试 rr doctor --repair'
                ;;
            76)
                rr_doctor_add fail repair_lock \
                    '安全修复未执行：共享事务锁证据不安全' \
                    '锁路径、inode 或旧版兼容锁未通过校验；零修复 mutation' \
                    '人工检查 /run/rr-vps/locks 与旧版锁证据'
                ;;
            *) : ;;
        esac
    fi

    if [ "$report" = true ]; then
        mkdir -p "$RR_DIAGNOSTIC_DIR"
        chmod 700 "$RR_DIAGNOSTIC_DIR"
        report_file="$RR_DIAGNOSTIC_DIR/rr-doctor-$(date -u '+%Y%m%d-%H%M%S').json"
    elif [ "$json_only" = true ]; then
        report_file=$(mktemp /tmp/rr-doctor-report.XXXXXX) || { rm -f "$RR_DOCTOR_EVENTS"; return 1; }
    fi
    if [ -n "$report_file" ] && command -v jq >/dev/null 2>&1; then
        jq -s --arg version "$SCRIPT_VERSION" --arg started "$started" \
            --arg channel "${RR_UPDATE_CHANNEL:-stable}" \
            --argjson ok "$RR_DOCTOR_OK" --argjson warn "$RR_DOCTOR_WARN" --argjson fail "$RR_DOCTOR_FAIL" \
            '{product:"RR-vps",version:$version,started_at:$started,update_channel:$channel,summary:{ok:$ok,warn:$warn,fail:$fail},checks:.}' \
            "$RR_DOCTOR_EVENTS" > "${report_file}.raw"
        rr_doctor_redact "${report_file}.raw" "$report_file"
        rm -f "${report_file}.raw"
        chmod 600 "$report_file"
    fi
    [ "$json_only" = true ] && [ -s "$report_file" ] && cat "$report_file"
    if [ "$json_only" != true ]; then
        printf '%s\n体检结果：%s 正常 · %s 警告 · %s 失败\n' '────────────────────────────────────────' "$RR_DOCTOR_OK" "$RR_DOCTOR_WARN" "$RR_DOCTOR_FAIL"
        [ "$report" = true ] && printf '脱敏报告：%s\n' "$report_file"
    fi
    [ "$report" = true ] || { [ -z "$report_file" ] || rm -f "$report_file"; }
    rm -f "$RR_DOCTOR_EVENTS"
    unset RR_DOCTOR_JSON_ONLY
    [ "$RR_DOCTOR_FAIL" -eq 0 ]
}

rr_backup_copy_path() {
    local source="$1" stage="$2" destination=""
    [ -e "$source" ] || return 0
    destination="$stage/rootfs${source}"
    mkdir -p "$(dirname "$destination")" || return 1
    cp -a -- "$source" "$destination"
}

rr_backup_source_preflight() {
    local output_parent="$1"
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 - \
        "$RR_BACKUP_WORK_DIR" "$output_parent" \
        /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive \
        /etc/rr-update /etc/rr-cloudflared/token \
        /var/lib/rr-nexus/remote.key /var/lib/rr-nexus/nexus.db \
        /var/lib/rr-nexus/nexus.db-wal <<'PY'
import os
import pathlib
import shutil
import stat
import sys

from rr_nexus_lib.backup_archive import (
    FREE_SPACE_RESERVE_BYTES,
    MAX_EXPANDED_BYTES,
    MAX_MEMBERS,
    _member_file_limit,
    _path_parts,
)

work_dir = pathlib.Path(sys.argv[1])
output_parent = pathlib.Path(sys.argv[2])
roots = [pathlib.Path(value) for value in dict.fromkeys(sys.argv[3:])]
members = {
    "payload",
    "payload/rootfs",
    "payload/metadata.json",
    "payload/manifest.sha256",
    "payload/crontab.txt",
}
files = set()
total = 0
stack = list(roots)

while stack:
    path = stack.pop()
    try:
        info = path.lstat()
    except FileNotFoundError:
        continue
    archive_name = f"payload/rootfs{path.as_posix()}"
    if stat.S_ISDIR(info.st_mode):
        _path_parts(archive_name, directory=True)
        with os.scandir(path) as entries:
            stack.extend(pathlib.Path(entry.path) for entry in entries)
    elif stat.S_ISREG(info.st_mode):
        _path_parts(archive_name, directory=False)
        if info.st_size > _member_file_limit(archive_name):
            raise SystemExit("backup source member exceeds its size limit")
        if archive_name not in files:
            files.add(archive_name)
            total += info.st_size
    else:
        raise SystemExit("backup source contains a link or special file")

    parts = pathlib.PurePosixPath(archive_name).parts
    for index in range(1, len(parts) + 1):
        members.add("/".join(parts[:index]))
    if len(members) > MAX_MEMBERS:
        raise SystemExit("backup source has too many members")
    if total > MAX_EXPANDED_BYTES:
        raise SystemExit("backup source exceeds the expanded-size limit")

# During creation the work filesystem holds the copied payload and compressed
# tar simultaneously.  The destination then holds a no-larger encrypted copy.
# Add the requirements when both paths share one filesystem.
requirements = {}
work_device = work_dir.stat().st_dev
output_device = output_parent.stat().st_dev
requirements[work_device] = (
    2 * total + FREE_SPACE_RESERVE_BYTES + 32 * 1024**2
)
requirements[output_device] = requirements.get(output_device, 0) + (
    total + FREE_SPACE_RESERVE_BYTES + 16 * 1024**2
)
paths = {work_device: work_dir, output_device: output_parent}
for device, required in requirements.items():
    if shutil.disk_usage(paths[device]).free < required:
        raise SystemExit("insufficient free space to create and encrypt backup")
PY
}

rr_backup_sqlite_validate() {
    local source="$1"
    [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] || return 1
    python3 - "$source" <<'PY'
import sqlite3, sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=15)
try:
    tables = {
        row[0] for row in source.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    if not {"admins", "devices", "schema_migrations"}.issubset(tables):
        raise RuntimeError("not an RR Nexus database")
    row = source.execute("PRAGMA quick_check").fetchone()
    if not row or row[0] != "ok" or source.execute("PRAGMA foreign_key_check").fetchone():
        raise RuntimeError("database integrity check failed")
finally:
    source.close()
PY
}

rr_backup_sqlite_consistent() {
    local source="$1" target="$2"
    [ -e "$source" ] || return 1
    [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] || return 1
    mkdir -p "$(dirname "$target")" || return 1
    python3 - "$source" "$target" <<'PY'
import os, sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=15)
target = sqlite3.connect(sys.argv[2])
try:
    tables = {
        row[0] for row in source.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    if not {"admins", "devices", "schema_migrations"}.issubset(tables):
        raise RuntimeError("source is not an RR Nexus database")
    row = source.execute("PRAGMA quick_check").fetchone()
    if not row or row[0] != "ok" or source.execute("PRAGMA foreign_key_check").fetchone():
        raise RuntimeError("source database integrity check failed")
    source.backup(target)
    row = target.execute("PRAGMA quick_check").fetchone()
    if not row or row[0] != "ok" or target.execute("PRAGMA foreign_key_check").fetchone():
        raise RuntimeError("backup database integrity check failed")
finally:
    target.close(); source.close()
os.chmod(sys.argv[2], 0o600)
PY
}

rr_backup_capture_nexus_consistent() {
    local stage="$1" result=0 security_lock_fd=""
    rr_secure_lock_prepare "$RR_NEXUS_SECURITY_LOCK_FILE" || return 1
    exec {security_lock_fd}>>"$RR_NEXUS_SECURITY_LOCK_FILE" || return 1
    rr_secure_lock_fd_is_safe "$RR_NEXUS_SECURITY_LOCK_FILE" "$security_lock_fd" || return 1
    flock -w 30 "$security_lock_fd" || return 1

    # remote.key and its database/audit state form one security snapshot.
    # Stopping the API prevents a concurrent remote-key revoke from pairing an
    # old key with a newer database and resurrecting revoked credentials.
    if [ -e "$NEXUS_CONFIG_FILE" ] || [ -L "$NEXUS_CONFIG_FILE" ]; then
        [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || return 1
        [ -f "$NEXUS_DB_FILE" ] && [ ! -L "$NEXUS_DB_FILE" ] && \
            [ -s "$NEXUS_DB_FILE" ] || {
                printf 'Nexus 已配置但数据库缺失或为空，已拒绝生成会丢失用户的备份。\n' >&2
                return 1
            }
    fi
    rr_backup_copy_path /var/lib/rr-nexus/remote.key "$stage" || result=1
    if [ "$result" -eq 0 ] && \
       { [ -e "$NEXUS_CONFIG_FILE" ] || [ -e "$NEXUS_DB_FILE" ]; }; then
        rr_backup_sqlite_consistent "$NEXUS_DB_FILE" \
            "$stage/rootfs/var/lib/rr-nexus/nexus.db" || result=1
    fi

    return "$result"
}

rr_backup_fixed_argo_token() {
    local stage="$1" token="" target=""
    load_config_with_defaults >/dev/null 2>&1 || return 0
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 0
    if [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        IFS= read -r token < "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" || return 1
        if [ -n "$token" ] && [[ "$token" != *[[:space:]]* ]]; then
            rr_backup_copy_path "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" "$stage"
            return $?
        fi
        token=""
    fi
    token=$(rr_cloudflared_service_token)
    if [ -z "$token" ] || [[ "$token" == *[[:space:]]* ]]; then
        printf '无法从当前固定 Argo 服务提取 Token，已拒绝生成不完整迁移备份。\n' >&2
        return 1
    fi
    target="$stage/rootfs/etc/rr-cloudflared/token"
    install -d -m 700 "$(dirname "$target")" || return 1
    (umask 077; printf '%s\n' "$token" > "$target")
}

rr_restore_migrate_legacy_fixed_token() {
    local token="" token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" temporary=""
    [ -f "$CONFIG_FILE" ] || return 0
    load_config_with_defaults || return 1
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 0
    if [ -r "$token_file" ]; then
        IFS= read -r token < "$token_file" || return 1
        [ -n "$token" ] && [[ "$token" != *[[:space:]]* ]] || return 1
        chmod 600 "$token_file" || return 1
        return 0
    fi
    token=$(rr_cloudflared_service_token) || return 1
    [ -n "$token" ] && [[ "$token" != *[[:space:]]* ]] || {
        printf '旧版固定 Argo 服务无法证明 RR 所有权，拒绝恢复。\n' >&2
        return 1
    }
    install -d -m 700 "$(dirname "$token_file")" || return 1
    temporary=$(mktemp "$(dirname "$token_file")/.token.XXXXXX") || return 1
    printf '%s\n' "$token" > "$temporary" && chmod 600 "$temporary" && \
        mv -f "$temporary" "$token_file" || { rm -f "$temporary"; return 1; }
}

rr_auto_update_cron_line() {
    printf '%s\n' '0 * * * * PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin /usr/bin/python3 /usr/local/bin/auto_update_sub.py >> /var/log/auto_update_sub.log 2>&1'
}

rr_backup_capture_crontab() {
    local destination="$1"
    local expected=""
    local rr_lines=""
    expected=$(rr_auto_update_cron_line)
    rr_lines=$(crontab -l 2>/dev/null | grep 'auto_update_sub\.py' || true)
    if [ -n "$rr_lines" ] && [ "$rr_lines" != "$expected" ]; then
        printf '检测到非标准 RR 自动更新 cron，已拒绝把可执行命令写入备份。\n' >&2
        return 1
    fi
    if [ -n "$rr_lines" ]; then
        printf '%s\n' "$expected" > "$destination"
    else
        : > "$destination"
    fi
}

rr_backup_create() (
    local result=0
    rr_run_with_update_locks direct 0 rr_backup_create_locked "$@" || result=$?
    if [ "$result" -eq 75 ]; then
        printf '另一个更新、备份恢复或迁移事务正在运行。\n' >&2
        return 1
    fi
    [ "$result" -ne 76 ] || result=1
    return "$result"
)

rr_backup_create_locked() {
    local output="${1:-}" stage="" archive="" relative="" sha="" now="" unsupported=""
    rr_backup_create_cleanup() {
        [ -z "$stage" ] || ! rr_backup_stage_is_safe "$stage" create || rm -rf -- "$stage"
    }
    trap rr_backup_create_cleanup EXIT
    trap 'exit 143' HUP INT TERM
    rr_ensure_resilience_dependencies || { printf '无法安装加密备份所需组件。\n' >&2; return 1; }
    rr_backup_prepare_work_dir || {
        printf '备份工作目录的所有者、权限或路径不安全。\n' >&2
        return 1
    }
    RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
        rr_restore_recover_active || return 1
    rr_backup_prune_stale_stages || return 1
    load_config_with_defaults || return 1
    [ -f "$CONFIG_FILE" ] && [ "$INSTALL_COMPLETE" = true ] || {
        printf '当前没有完整的 RR-vps 安装，拒绝生成不可恢复的空备份。\n' >&2
        return 1
    }
    now=$(date -u '+%Y%m%d-%H%M%S')
    [ -n "$output" ] || output="$(pwd)/rr-backup-${now}.rrbak"
    [ -d "$output" ] && output="${output%/}/rr-backup-${now}.rrbak"
    case "$output" in /*) ;; *) output="$(pwd)/$output" ;; esac
    mkdir -p "$(dirname "$output")" || return 1
    [ ! -e "$output" ] && [ ! -L "$output" ] || {
        printf '备份目标已存在，拒绝覆盖：%s\n' "$output" >&2
        return 1
    }
    rr_backup_source_preflight "$(dirname "$output")" || return 1
    stage=$(mktemp -d "$RR_BACKUP_WORK_DIR/create.XXXXXX") || return 1
    chmod 700 "$stage" && rr_backup_stage_is_safe "$stage" create || return 1
    mkdir -p "$stage/rootfs" || { rm -rf "$stage"; return 1; }
    archive="$stage/payload.tar.gz"

    rr_backup_copy_path /etc/argo_vmess.conf "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/sing-box "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-nexus "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-naive "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-update "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_fixed_argo_token "$stage" || { rm -rf "$stage"; return 1; }
    # Executable workers and systemd units are regenerated from the installed,
    # manifest-verified runtime after restore. They are never accepted from a
    # portable backup, otherwise importing an untrusted archive is root RCE.
    # cloudflared.service may be owned by another application. RR migrates its
    # tunnel settings, but deliberately never backs up or overwrites that global unit.
    rr_backup_capture_nexus_consistent "$stage" || { rm -rf "$stage"; return 1; }

    mkdir -p "$stage/payload" || { rm -rf "$stage"; return 1; }
    mv "$stage/rootfs" "$stage/payload/rootfs" || { rm -rf "$stage"; return 1; }
    unsupported=$(find "$stage/payload/rootfs" -mindepth 1 ! -type d ! -type f -print -quit) || {
        rm -rf "$stage"
        return 1
    }
    if [ -n "$unsupported" ]; then
        printf '备份源中包含不支持的链接或特殊文件，已拒绝生成。\n' >&2
        rm -rf "$stage"
        return 1
    fi
    rr_backup_capture_crontab "$stage/payload/crontab.txt" || { rm -rf "$stage"; return 1; }
    (
        set -o pipefail
        cd "$stage/payload" || exit 1
        { find rootfs -type f -print0; printf 'crontab.txt\0'; } | \
            LC_ALL=C sort -z | xargs -0 sha256sum > manifest.sha256
    ) || { rm -rf "$stage"; return 1; }
    sha=$(sha256sum "$stage/payload/manifest.sha256" | awk '{print $1}')
    jq -n --arg product RR-vps --arg version "$SCRIPT_VERSION" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg arch "$SYS_ARCH" --arg manifest_sha256 "$sha" \
        '{format:2,product:$product,version:$version,created_at:$created,architecture:$arch,manifest_sha256:$manifest_sha256}' \
        > "$stage/payload/metadata.json" || { rm -rf "$stage"; return 1; }
    rr_restore_verify_manifest "$stage/payload" 2 || { rm -rf "$stage"; return 1; }
    rr_restore_validate_portable_config "$stage/payload/rootfs/etc/argo_vmess.conf" || { rm -rf "$stage"; return 1; }
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_archive \
        validate-payload "$stage/payload" || { rm -rf "$stage"; return 1; }
    tar --format=ustar --sort=name --mtime='UTC 1970-01-01' \
        --owner=0 --group=0 --numeric-owner --hard-dereference \
        -czf "$archive" -C "$stage" payload || { rm -rf "$stage"; return 1; }
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_archive \
        inspect "$archive" || { rm -rf "$stage"; return 1; }
    if ! PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_crypto encrypt "$archive" "$output"; then
        unset RR_BACKUP_PASSPHRASE
        rm -rf "$stage"
        return 1
    fi
    unset RR_BACKUP_PASSPHRASE
    # backup_crypto publishes the exact open inode atomically with mode 0600.
    # Never chmod the path here: an output directory writer could replace it
    # with a symlink between the Python process exit and this shell operation.
    rm -rf "$stage"
    stage=""
    printf '加密备份已生成：%s\n' "$output"
    printf '请把文件与口令分开保存；遗失口令无法恢复。\n'
}

rr_restore_apply_tree() {
    local root="$1" policy="${2:-portable}" destination_root="${3:-/}"
    local source="" relative="" target="" temporary="" mode="" source_mode=""
    local source_mode_decimal=0 safe_mode=""
    [ -d "$root/rootfs" ] || return 1
    [ "$policy" = full ] || [ "$policy" = portable ] || return 1
    case "$destination_root" in /*) ;; *) return 1 ;; esac
    [ -d "$destination_root" ] && [ ! -L "$destination_root" ] || return 1
    destination_root="${destination_root%/}"

    # Create every managed directory before installing files.  This preserves
    # empty rollback directories while keeping untrusted portable modes out of
    # the destination.  Existing host-wide parents such as /etc are never
    # chmodded by this replayer.
    while IFS= read -r -d '' source; do
        relative="${source#"$root/rootfs/"}"
        case "$relative" in
            etc/sing-box|etc/sing-box/*|etc/rr-nexus|etc/rr-nexus/*|\
            etc/rr-naive|etc/rr-naive/*|etc/rr-update|etc/rr-update/*|\
            etc/rr-cloudflared|etc/rr-cloudflared/*|\
            var/lib/rr-nexus|var/lib/rr-nexus/*|\
            var/www/rr-nexus-ip-acme|var/www/rr-nexus-ip-acme/*) ;;
            *) continue ;;
        esac
        if [ "$policy" = portable ]; then
            case "$relative" in etc/rr-nexus|etc/rr-nexus/*) continue ;; esac
        fi
        target="${destination_root}/$relative"
        mkdir -p "$target" || return 1
        chmod 700 "$target" || return 1
    done < <(find "$root/rootfs" -mindepth 1 -type d -print0 | LC_ALL=C sort -z)

    while IFS= read -r -d '' source; do
        relative="${source#"$root/rootfs/"}"
        case "$relative" in
            etc/argo_vmess.conf|etc/sing-box/*|etc/rr-nexus/*|etc/rr-naive/*|etc/rr-update/*|etc/rr-cloudflared/*|\
            var/lib/rr-nexus/*|var/www/rr-nexus-ip-acme/*) ;;
            usr/local/bin/auto_update_sub.py|etc/systemd/system/sing-box.service|\
            etc/systemd/system/rr-nexus.service|etc/systemd/system/argo-rr-health.service|\
            etc/systemd/system/argo-rr-health.timer|\
            etc/systemd/system/rr-nexus-ip-acme.service|\
            etc/systemd/system/rr-nexus-ip-acme.timer|\
            usr/local/lib/rr-vps/nexus-ip-cert-gate|usr/local/lib/rr-vps/lego|\
            usr/local/lib/rr-vps/lego.install|\
            etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf)
                [ "$policy" = full ] || {
                    printf '拒绝从便携备份恢复可执行文件或 systemd 单元：%s\n' "$relative" >&2
                    return 1
                }
                ;;
            *) printf '拒绝恢复不受支持路径：%s\n' "$relative" >&2; return 1 ;;
        esac
        # Nexus access is a property of the destination machine.  In
        # particular, never install a source machine's public mode, domain or
        # certificate files even briefly during a portable restore.  The
        # candidate config is rebuilt below from the captured target state.
        if [ "$policy" = portable ]; then
            case "$relative" in
                etc/rr-nexus/*) continue ;;
            esac
        fi
        target="${destination_root}/$relative"
        mkdir -p "$(dirname "$target")" || return 1
        temporary="$(dirname "$target")/.rr-restore.$$.tmp"
        # Never trust archived permission bits.  In particular, a crafted
        # backup must not be able to restore setuid/setgid files.
        case "$relative" in
            usr/local/bin/*.py|usr/local/lib/rr-vps/nexus-ip-cert-gate|\
            usr/local/lib/rr-vps/lego) mode=755 ;;
            etc/systemd/system/*.service|etc/systemd/system/*.timer|\
            etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf) mode=644 ;;
            *) mode=600 ;;
        esac
        install -m "$mode" "$source" "$temporary" || return 1
        mv -f "$temporary" "$target" || return 1
    done < <(find "$root/rootfs" -type f -print0 | LC_ALL=C sort -z)

    [ "$policy" = full ] || return 0
    # The rollback snapshot was taken only after its complete tree passed the
    # privileged-shape gate.  Recheck directory metadata nonetheless and
    # restore ordinary permission bits deepest-first, so parents never become
    # restrictive before their children have been materialized.  Special bits
    # and group/other-writable modes are never replayed.
    while IFS= read -r -d '' source; do
        relative="${source#"$root/rootfs/"}"
        case "$relative" in
            etc/sing-box|etc/sing-box/*|etc/rr-nexus|etc/rr-nexus/*|\
            etc/rr-naive|etc/rr-naive/*|etc/rr-update|etc/rr-update/*|\
            etc/rr-cloudflared|etc/rr-cloudflared/*|\
            var/lib/rr-nexus|var/lib/rr-nexus/*|\
            var/www/rr-nexus-ip-acme|var/www/rr-nexus-ip-acme/*) ;;
            *) continue ;;
        esac
        [ "$(stat -c '%u:%g' "$source" 2>/dev/null)" = 0:0 ] || return 1
        source_mode=$(stat -c %a "$source" 2>/dev/null) || return 1
        [[ "$source_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        source_mode_decimal=$((8#$source_mode))
        (( (source_mode_decimal & 07000) == 0 )) || return 1
        (( (source_mode_decimal & 00022) == 0 )) || return 1
        printf -v safe_mode '%03o' "$((source_mode_decimal & 0777))"
        target="${destination_root}/$relative"
        [ -d "$target" ] && [ ! -L "$target" ] || return 1
        chmod "$safe_mode" "$target" || return 1
    done < <(find "$root/rootfs" -mindepth 1 -depth -type d -print0)
    rr_restore_replay_nexus_gate_artifacts "$root" "${destination_root:-/}"
}

rr_restore_clear_managed_tree() {
    # Recheck immediately before crossing a recursive deletion boundary.  The
    # earlier transaction checks protect snapshot fidelity; this narrow check
    # also closes ordinary races before the destructive operation itself.
    rr_restore_validate_target_snapshot_shape || return 1
    rm -rf -- /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared || return 1
    rm -f -- /etc/argo_vmess.conf /var/lib/rr-nexus/remote.key \
        /var/lib/rr-nexus/nexus.db /var/lib/rr-nexus/nexus.db-wal /var/lib/rr-nexus/nexus.db-shm \
        /usr/local/bin/auto_update_sub.py /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/sing-box.service /etc/systemd/system/argo-rr-health.service \
        /etc/systemd/system/argo-rr-health.timer || return 1
}

rr_restore_clear_derived_state() {
    # Subscription files and Nexus job/log state are derived from the restored
    # config+database.  Keeping another machine's old UUID directories would
    # leave known credential URLs live after a cross-machine restore.
    # Validate before ensure_subscription_root can chmod/create anything, then
    # validate again immediately before crossing the deletion boundary.  A
    # mount appearing in either window therefore fails closed without first
    # changing its metadata.
    rr_restore_validate_target_snapshot_shape || return 1
    ensure_subscription_root || return 1
    [ "$SUB_ROOT" = /tmp/sub_server ] || return 1
    rr_restore_validate_target_snapshot_shape || return 1
    find "$SUB_ROOT" -mindepth 1 -xdev -delete || return 1
    install -d -m 700 /var/lib/rr-nexus || return 1
    local derived=""
    while IFS= read -r -d '' derived; do
        # The destination ACME account/store/journal is machine-bound security
        # state, not imported Nexus database output.  Preserve only this exact
        # owned subtree while clearing every other derived child.
        [ "$derived" = /var/lib/rr-nexus/ip-acme ] && continue
        case "$derived" in /var/lib/rr-nexus/*) ;; *) return 1 ;; esac
        rm -rf -- "$derived" || return 1
    done < <(find /var/lib/rr-nexus -mindepth 1 -maxdepth 1 -print0)
    if [ -e /var/lib/rr-nexus/ip-acme ] || [ -L /var/lib/rr-nexus/ip-acme ]; then
        declare -F nexus_ip_acme_owned_state_is_safe >/dev/null 2>&1 || return 1
        nexus_ip_acme_owned_state_is_safe || return 1
    fi
    [ "$(stat -c '%u:%g:%a' -- /var/lib/rr-nexus 2>/dev/null)" = 0:0:700 ]
}

rr_restore_crontab() {
    local rr_entries="$1" temporary="" current="" expected="" restored="" result=0 had_crontab=false
    expected=$(rr_auto_update_cron_line)
    restored=$(cat "$rr_entries" 2>/dev/null || true)
    if [ -n "$restored" ] && [ "$restored" != "$expected" ]; then
        printf '拒绝恢复非标准 RR cron 命令。\n' >&2
        return 1
    fi
    temporary=$(mktemp /tmp/rr-crontab-restore.XXXXXX) || return 1
    current=$(mktemp /tmp/rr-crontab-current.XXXXXX) || { rm -f "$temporary"; return 1; }
    if crontab -l > "$current" 2>/dev/null; then
        had_crontab=true
    fi
    grep -v 'auto_update_sub\.py' "$current" > "$temporary" || true
    [ -n "$restored" ] && printf '%s\n' "$expected" >> "$temporary"
    if [ -s "$temporary" ]; then
        crontab "$temporary" || result=$?
    elif [ "$had_crontab" = true ]; then
        crontab -r >/dev/null 2>&1 || result=$?
    fi
    rm -f "$temporary" "$current"
    return "$result"
}

rr_restore_regenerate_runtime_files() {
    local singbox_service="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local health_service="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
    local health_timer="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
    local unit_load_state=""
    # Portable backups contain data/config only. Recreate privileged units and
    # executable workers from the already verified local RR runtime. These
    # writers only materialize trusted files; enable/start decisions stay at
    # the transaction finalization boundary.
    if [ -r "$CONFIG_FILE" ]; then
        declare -F write_singbox_systemd_unit >/dev/null 2>&1 || return 1
        declare -F write_health_monitor_units >/dev/null 2>&1 || return 1
        write_singbox_systemd_unit || return 1
        write_health_monitor_units || return 1
    fi
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        nexus_write_service || return 1
    fi
    # Unit removal and recreation must become visible as one explicit manager
    # transition. Never depend on an incidental reload inside another writer.
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if [ -r "$CONFIG_FILE" ]; then
        [ -f "$singbox_service" ] && [ ! -L "$singbox_service" ] || return 1
        [ -f "$health_service" ] && [ ! -L "$health_service" ] || return 1
        [ -f "$health_timer" ] && [ ! -L "$health_timer" ] || return 1
        for unit in sing-box.service argo-rr-health.service argo-rr-health.timer; do
            rr_restore_unit_load_state_read "$unit" unit_load_state || return 1
            [ "$unit_load_state" = loaded ] || return 1
        done
    fi
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        [ -f "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] || return 1
        rr_restore_unit_load_state_read rr-nexus.service unit_load_state || return 1
        [ "$unit_load_state" = loaded ] || return 1
    else
        [ ! -e "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] || return 1
        rr_restore_unit_load_state_read rr-nexus.service unit_load_state || return 1
        [ "$unit_load_state" = not-found ] || return 1
    fi
    rr_restore_require_effective_gates_or_isolate
}

rr_restore_verify_manifest() {
    local payload="$1"
    local format="$2"
    python3 - "$payload" "$format" <<'PY'
import hashlib
import pathlib
import re
import stat
import sys

payload = pathlib.Path(sys.argv[1])
backup_format = int(sys.argv[2])
manifest_path = payload / "manifest.sha256"
rootfs = payload / "rootfs"
if backup_format not in {1, 2} or not rootfs.is_dir():
    raise SystemExit("unsupported backup format")
cron_info = (payload / "crontab.txt").lstat()
if not stat.S_ISREG(cron_info.st_mode):
    raise SystemExit("backup crontab is missing or not a regular file")

entries = {}
with manifest_path.open("r", encoding="utf-8", newline="") as manifest:
    for raw_line in manifest:
        if raw_line.endswith("\r\n") or not raw_line.endswith("\n"):
            raise SystemExit("non-canonical manifest line ending")
        line = raw_line[:-1]
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\n]+)", line)
        if not match:
            raise SystemExit("invalid manifest entry")
        expected, name = match.groups()
        relative = pathlib.PurePosixPath(name)
        if (relative.is_absolute() or ".." in relative.parts or relative.as_posix() != name
                or name in entries):
            raise SystemExit("unsafe or duplicate manifest path")
        allowed = len(relative.parts) > 1 and relative.parts[0] == "rootfs"
        if backup_format == 2 and name == "crontab.txt":
            allowed = True
        if not allowed:
            raise SystemExit("manifest path is outside the portable payload")
        candidate = payload.joinpath(*relative.parts)
        info = candidate.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit("manifest entry is not a regular file")
        digest = hashlib.sha256()
        with candidate.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise SystemExit("manifest digest mismatch")
        entries[name] = expected

actual = {
    path.relative_to(payload).as_posix()
    for path in rootfs.rglob("*")
    if path.is_file()
}
if backup_format == 2:
    actual.add("crontab.txt")
if set(entries) != actual:
    raise SystemExit("manifest does not exactly cover the portable payload")
PY
}

rr_restore_reject_portable_ip_acme_payload() {
    local payload="${1:-}" imported=""
    [ -d "$payload/rootfs" ] && [ ! -L "$payload/rootfs" ] || return 1
    # ACME account keys, stores and publication journals are machine-bound.
    # Portable archives are data migration artifacts, never a vehicle for
    # replacing the destination CA identity or its crash journal.
    for imported in \
        "$payload/rootfs/var/lib/rr-nexus/ip-acme" \
        "$payload/rootfs/var/www/rr-nexus-ip-acme" \
        "$payload/rootfs/etc/systemd/system/rr-nexus-ip-acme.service" \
        "$payload/rootfs/etc/systemd/system/rr-nexus-ip-acme.timer" \
        "$payload/rootfs/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf" \
        "$payload/rootfs/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf" \
        "$payload/rootfs/usr/local/lib/rr-vps/lego" \
        "$payload/rootfs/usr/local/lib/rr-vps/lego.install"; do
        if [ -e "$imported" ] || [ -L "$imported" ]; then
            printf '%s\n' \
                '便携备份包含来源服务器的 IP-ACME 账户或签发状态，已拒绝导入。' >&2
            return 1
        fi
    done
}

rr_restore_validate_node_config() {
    local config="$1"
    [ -r "$config" ] || return 0
    python3 - "$config" <<'PY'
import re
import shlex
import sys

allowed = {
    "PORT", "ARGO_EDGE_PORT", "SUB_PORT", "UUID", "CDN_IP", "ARGO_DOMAIN", "TUNNEL_MODE",
    "ENTRY_IP_MODE", "OUTBOUND_IP_MODE", "SUB_PUBLIC_PORT", "SUB_PUBLIC_PORT_IPV4",
    "SUB_PUBLIC_PORT_IPV6", "ENTRY_IPV4_ADDRESS", "ENTRY_IPV6_ADDRESS", "VM_TLS_ENABLED",
    "SUB_ACCESS_MODE", "SUB_DOMAIN", "SUB_TOKEN",
    "VM_PREVIOUS_PORT", "VM_ENABLED", "VL_ENABLED", "VL_PORT", "HY2_ENABLED", "HY2_PORT",
    "HY2_HOP_PORTS", "HY2_HOP_INTERVAL", "TU5_ENABLED", "TU5_PORT", "TU5_HOP_PORTS",
    "AN_ENABLED", "AN_PORT", "NAIVE_ENABLED", "NAIVE_PORT", "NAIVE_USER", "NAIVE_PASS",
    "NAIVE_DOMAIN", "NAIVE_MODE", "NAIVE_QUIC_CC", "CLASH_ENABLED", "SINGBOX_AUTO_RESTART",
    "CONFIG_VERSION", "PRIVATE_KEY", "PUBLIC_KEY", "SHORT_ID", "CERT_SHA256",
    "INSTALL_COMPLETE", "HB_ENABLED", "HB_INTERVAL", "LE_EMAIL",
}

seen = set()
with open(sys.argv[1], "r", encoding="utf-8", newline="") as source:
    for number, raw in enumerate(source, 1):
        if raw.endswith("\r\n") or (raw and not raw.endswith("\n")):
            raise SystemExit(f"non-canonical config line {number}")
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", line)
        if not match:
            raise SystemExit(f"invalid config line {number}")
        key, encoded = match.groups()
        if key not in allowed or key in seen:
            raise SystemExit(f"unknown or duplicate config key on line {number}")
        seen.add(key)
        values = shlex.split(encoded, posix=True)
        if len(values) > 1 or any(ord(char) < 32 for char in (values[0] if values else "")):
            raise SystemExit(f"invalid config value on line {number}")
PY
}

rr_restore_validate_target_ownership() {
    local collision=""
    # `-e` is false for a dangling symlink.  Treat every lstat-visible config
    # path as an occupied target so an unmanaged link can never be mistaken
    # for a blank machine and then removed by the restore transaction.
    if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
        grep -q '^CONFIG_VERSION=' "$CONFIG_FILE" 2>/dev/null || {
            printf '目标机配置没有 RR-vps 所有权标记，拒绝覆盖。\n' >&2
            return 1
        }
        rr_restore_validate_node_config "$CONFIG_FILE" || return 1
        if [ -f /etc/systemd/system/sing-box.service ] && \
           ! grep -Fxq 'ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json' \
               /etc/systemd/system/sing-box.service; then
            printf '目标机 sing-box.service 不是 RR-vps 管理，拒绝覆盖。\n' >&2
            return 1
        fi
        if [ -f /etc/systemd/system/rr-nexus.service ] && \
           ! grep -Fq 'ExecStart=/usr/bin/python3 /usr/local/lib/rr/nexus/rr_nexus.py' \
               /etc/systemd/system/rr-nexus.service; then
            printf '目标机 rr-nexus.service 所有权不明，拒绝覆盖。\n' >&2
            return 1
        fi
        return 0
    fi

    # A blank target is supported, but a machine with colliding unmanaged
    # paths is not.  Portable restore never guesses ownership of global units.
    for collision in \
        /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared \
        /etc/systemd/system/sing-box.service /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/rr-nexus-ip-acme.service \
        /etc/systemd/system/rr-nexus-ip-acme.timer \
        /usr/local/lib/rr-vps/nexus-ip-cert-gate \
        /usr/local/lib/rr-vps/lego /usr/local/lib/rr-vps/lego.install \
        /etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf \
        /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf \
        /var/lib/rr-nexus /var/www/rr-nexus-ip-acme /tmp/sub_server; do
        if [ -e "$collision" ] || [ -L "$collision" ]; then
            printf '目标机已有非 RR 所有权路径，拒绝恢复覆盖：%s\n' "$collision" >&2
            return 1
        fi
    done
}

rr_restore_validate_target_snapshot_shape() {
    # Every path below is either removed, replaced or used as rollback input by
    # portable restore.  Reject shapes that the regular-file-only rollback
    # replayer cannot reproduce exactly.  The optional root is used only by the
    # regression harness; the production orchestrator always calls this with no
    # argument and therefore validates the live filesystem.
    local validation_root="${1:-}" requested_mountinfo="${2:-}" mountinfo=""
    case "$validation_root" in
        ""|/*) ;;
        *) return 1 ;;
    esac
    [ -z "$validation_root" ] || {
        [ -d "$validation_root" ] && [ ! -L "$validation_root" ] || return 1
    }
    if [ -z "$validation_root" ]; then
        # A caller must never redirect the production topology proof to a
        # fixture.  Tests get that capability only together with an explicit
        # synthetic destination root.
        [ -z "$requested_mountinfo" ] || return 1
        mountinfo=/proc/self/mountinfo
    else
        mountinfo="${requested_mountinfo:-/proc/self/mountinfo}"
        case "$mountinfo" in /*) ;; *) return 1 ;; esac
    fi
    [ -f "$mountinfo" ] && [ ! -L "$mountinfo" ] && [ -r "$mountinfo" ] || return 1

    python3 - "$validation_root" "$CONFIG_FILE" "$mountinfo" <<'PY'
import os
import posixpath
import re
import stat
import sys

validation_root, configured_config, mountinfo_path = sys.argv[1:]
MAX_MANAGED_MEMBERS = 200_000
MAX_MOUNTINFO_BYTES = 8 * 1024 * 1024
MAX_MOUNTINFO_LINES = 65_536
MAX_MOUNTINFO_LINE = 65_536
RESTORE_GATE_DROPIN = b"zzzz-rr-restore-gate.conf"
FIREWALL_GATE_DROPIN = b"zzzzz-rr-firewall-quarantine.conf"
NEXUS_GATE_DROPIN = b"zzzzzz-rr-nexus-ip-cert-gate.conf"
managed_members = 0


class UnsafeShape(Exception):
    def __init__(self, path, reason):
        super().__init__(reason)
        self.path = path
        self.reason = reason


def rooted(path):
    if not validation_root:
        return path
    return validation_root.rstrip("/") + path


def lstat_optional(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise UnsafeShape(path, f"lstat failed: {error.errno}") from error


def require_privileged_metadata(path, info, *, canonical_tmp=False):
    if (info.st_uid, info.st_gid) != (0, 0):
        raise UnsafeShape(path, "not root-owned")
    permissions = stat.S_IMODE(info.st_mode)
    if permissions & 0o7000:
        if canonical_tmp and permissions == 0o1777:
            return
        raise UnsafeShape(path, "privileged special mode bits are set")
    if permissions & 0o022:
        if canonical_tmp and permissions == 0o1777:
            return
        raise UnsafeShape(path, "group/other writable")


def validate_real_directory(path, *, required=False, canonical_tmp=False):
    info = lstat_optional(path)
    if info is None:
        if required:
            raise UnsafeShape(path, "required directory is absent")
        return False
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise UnsafeShape(path, "directory is a link or special file")
    require_privileged_metadata(path, info, canonical_tmp=canonical_tmp)
    return True


def validate_regular(path, *, required=False):
    info = lstat_optional(path)
    if info is None:
        if required:
            raise UnsafeShape(path, "required file is absent")
        return False
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise UnsafeShape(path, "file is a link or special file")
    require_privileged_metadata(path, info)
    if info.st_nlink != 1:
        raise UnsafeShape(path, "file has multiple hard links")
    return True


def validate_managed_tree(path):
    global managed_members
    if not validate_real_directory(path):
        return
    stack = [path]
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    item = entry.path
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError as error:
                        raise UnsafeShape(item, f"lstat failed: {error.errno}") from error
                    managed_members += 1
                    if managed_members > MAX_MANAGED_MEMBERS:
                        raise UnsafeShape(path, "managed trees have too many members")
                    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                        require_privileged_metadata(item, info)
                        stack.append(item)
                    elif stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                        require_privileged_metadata(item, info)
                        if info.st_nlink != 1:
                            raise UnsafeShape(item, "file has multiple hard links")
                    else:
                        raise UnsafeShape(item, "managed tree contains a link or special file")
        except UnsafeShape:
            raise
        except OSError as error:
            raise UnsafeShape(directory, f"scan failed: {error.errno}") from error


def decode_mount_path(encoded):
    output = bytearray()
    index = 0
    escapes = {
        b"040": b" ",
        b"011": b"\t",
        b"012": b"\n",
        b"134": b"\\",
    }
    while index < len(encoded):
        byte = encoded[index]
        if byte != 0x5C:
            if byte == 0:
                raise UnsafeShape(mountinfo_path, "mountinfo contains NUL")
            output.append(byte)
            index += 1
            continue
        code = encoded[index + 1:index + 4]
        if len(code) != 3 or code not in escapes:
            raise UnsafeShape(mountinfo_path, "mountinfo has a non-kernel escape")
        output.extend(escapes[code])
        index += 4
    decoded = os.fsdecode(bytes(output))
    if not decoded.startswith("/") or len(os.fsencode(decoded)) > 4096:
        raise UnsafeShape(mountinfo_path, "mountinfo path is invalid")
    if decoded != "/" and decoded.endswith("/"):
        raise UnsafeShape(mountinfo_path, "mountinfo path is non-canonical")
    if posixpath.normpath(decoded) != decoded:
        raise UnsafeShape(mountinfo_path, "mountinfo path is non-canonical")
    return decoded


def read_mountpoints():
    try:
        descriptor = os.open(
            mountinfo_path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
    except OSError as error:
        raise UnsafeShape(
            mountinfo_path, f"mountinfo open failed: {error.errno}"
        ) from error
    points = []
    seen_ids = set()
    total = 0
    lines = 0
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise UnsafeShape(mountinfo_path, "mountinfo is not a regular file")
        require_privileged_metadata(mountinfo_path, info)
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            for raw in stream:
                lines += 1
                total += len(raw)
                if lines > MAX_MOUNTINFO_LINES or total > MAX_MOUNTINFO_BYTES:
                    raise UnsafeShape(mountinfo_path, "mountinfo exceeds bounds")
                if len(raw) > MAX_MOUNTINFO_LINE or not raw.endswith(b"\n"):
                    raise UnsafeShape(mountinfo_path, "mountinfo line is invalid")
                fields = raw[:-1].split(b" ")
                if b"" in fields:
                    raise UnsafeShape(mountinfo_path, "mountinfo spacing is invalid")
                try:
                    separator = fields.index(b"-")
                except ValueError as error:
                    raise UnsafeShape(
                        mountinfo_path, "mountinfo separator is absent"
                    ) from error
                before = fields[:separator]
                after = fields[separator + 1:]
                if len(before) < 6 or len(after) < 3:
                    raise UnsafeShape(mountinfo_path, "mountinfo fields are incomplete")
                if not before[0].isdigit() or not before[1].isdigit():
                    raise UnsafeShape(mountinfo_path, "mountinfo IDs are invalid")
                if before[0] in seen_ids:
                    raise UnsafeShape(mountinfo_path, "mountinfo ID is duplicated")
                seen_ids.add(before[0])
                if not re.fullmatch(rb"[0-9]+:[0-9]+", before[2]):
                    raise UnsafeShape(mountinfo_path, "mountinfo device is invalid")
                # Decode both path fields.  Bind mounts commonly share st_dev
                # with their source, so every mount record is retained instead
                # of deduplicating by device number.
                decode_mount_path(before[3])
                points.append(decode_mount_path(before[4]))
    except UnsafeShape:
        raise
    except OSError as error:
        raise UnsafeShape(
            mountinfo_path, f"mountinfo read failed: {error.errno}"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not points:
        raise UnsafeShape(mountinfo_path, "mountinfo is empty")
    return points


def logical_mountpoint(path):
    if not validation_root:
        return path
    root = validation_root.rstrip("/")
    if path == root:
        return "/"
    if path.startswith(root + "/"):
        return path[len(root):]
    # Explicit test fixtures may use production-form logical paths directly.
    return path


def at_or_below(path, boundary):
    return path == boundary or path.startswith(boundary + "/")


try:
    # These parents are written through later.  A symlinked parent would make a
    # seemingly narrow RR cleanup cross into another administrator-owned tree.
    for parent in (
        "/etc", "/etc/systemd", "/etc/systemd/system",
        "/usr", "/usr/local", "/usr/local/bin", "/var", "/var/lib",
    ):
        validate_real_directory(rooted(parent), required=True)
    for parent in ("/usr/local/lib", "/usr/local/lib/rr-vps", "/var/www"):
        validate_real_directory(rooted(parent))
    validate_real_directory(rooted("/tmp"), required=True, canonical_tmp=True)
    for parent in ("/etc/nginx", "/etc/nginx/sites-available", "/etc/nginx/sites-enabled"):
        validate_real_directory(rooted(parent))

    config_path = configured_config
    if validation_root and configured_config == "/etc/argo_vmess.conf":
        config_path = rooted(configured_config)
    validate_regular(config_path)

    for path in (
        "/usr/local/bin/auto_update_sub.py",
        "/etc/systemd/system/sing-box.service",
        "/etc/systemd/system/rr-nexus.service",
        "/etc/systemd/system/argo-rr-health.service",
        "/etc/systemd/system/argo-rr-health.timer",
        "/etc/systemd/system/cloudflared.service",
        "/etc/systemd/system/rr-restore-recovery.service",
        "/etc/systemd/system/rr-restore-watchdog.service",
        "/etc/systemd/system/rr-nexus-ip-acme.service",
        "/etc/systemd/system/rr-nexus-ip-acme.timer",
        "/usr/local/lib/rr-vps/nexus-ip-cert-gate",
        "/usr/local/lib/rr-vps/lego",
        "/usr/local/lib/rr-vps/lego.install",
        "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-available/rr-nexus.conf.port",
        "/etc/nginx/sites-available/rr-nexus-ip.conf",
        "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
    ):
        validate_regular(rooted(path))

    for path in (
        "/etc/sing-box", "/etc/rr-nexus", "/etc/rr-naive",
        "/etc/rr-update", "/etc/rr-cloudflared", "/var/lib/rr-nexus",
        "/var/www/rr-nexus-ip-acme",
    ):
        validate_managed_tree(rooted(path))

    # Restore gates are durable RR-owned infrastructure.  Validate the whole
    # drop-in tree: an unexamined writable, linked or special sibling can still
    # affect the service that crosses the gate.
    dropin_units = (
        "sing-box.service", "rr-nexus.service", "rr-subscription.service",
        "rr-nexus-ip-acme.service", "rr-nexus-ip-acme.timer",
        "cloudflared.service", "nginx.service", "argo-rr-health.service",
        "argo-rr-health.timer", "rr-restore-recovery.service",
        "rr-restore-watchdog.service",
    )
    for unit in dropin_units:
        dropin_directory = rooted(f"/etc/systemd/system/{unit}.d")
        validate_managed_tree(dropin_directory)
        if not os.path.isdir(dropin_directory):
            continue
        try:
            with os.scandir(dropin_directory) as entries:
                for entry in entries:
                    name = os.fsencode(entry.name)
                    if (
                        name.endswith(b".conf")
                        and name > RESTORE_GATE_DROPIN
                        and name != FIREWALL_GATE_DROPIN
                        and name != NEXUS_GATE_DROPIN
                    ):
                        raise UnsafeShape(
                            entry.path,
                            "systemd drop-in sorts after the restore gate",
                        )
        except UnsafeShape:
            raise
        except OSError as error:
            raise UnsafeShape(
                dropin_directory, f"drop-in order scan failed: {error.errno}"
            ) from error

    # /tmp/sub_server is regenerated derived state and legitimately contains
    # RR-created client-route symlinks.  Its top-level directory is still a
    # deletion boundary and must never itself be a link or non-root directory.
    validate_real_directory(rooted("/tmp/sub_server"))

    # Nexus creates these three links itself.  Snapshot/restore already uses
    # cp -a and lstat-aware presence checks, so the exact known target is the
    # one safe, intentionally supported symlink exception.
    nginx_links = {
        "/etc/nginx/sites-enabled/rr-nexus.conf":
            "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-enabled/rr-nexus-port.conf":
            "/etc/nginx/sites-available/rr-nexus.conf.port",
        "/etc/nginx/sites-enabled/rr-nexus-ip.conf":
            "/etc/nginx/sites-available/rr-nexus-ip.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf":
            "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
    }
    for link_name, target_name in nginx_links.items():
        link = rooted(link_name)
        target = rooted(target_name)
        info = lstat_optional(link)
        if info is None:
            continue
        if not stat.S_ISLNK(info.st_mode):
            raise UnsafeShape(link, "managed Nginx enablement is not a symlink")
        if (info.st_uid, info.st_gid) != (0, 0):
            raise UnsafeShape(link, "managed Nginx link is not root-owned")
        raw_target = os.readlink(link)
        allowed_targets = {
            target,
            target_name,
            os.path.relpath(target, os.path.dirname(link)),
            os.path.relpath(target_name, os.path.dirname(link_name)),
        }
        if raw_target not in allowed_targets:
            raise UnsafeShape(link, "managed Nginx symlink target is unexpected")
        validate_regular(target, required=True)

    deletion_roots = (
        "/etc/sing-box", "/etc/rr-nexus", "/etc/rr-naive",
        "/etc/rr-update", "/etc/rr-cloudflared", "/var/lib/rr-nexus",
        "/var/www/rr-nexus-ip-acme",
        "/tmp/sub_server",
    )
    exact_writers = {
        "/etc/argo_vmess.conf",
        "/usr/local/bin/auto_update_sub.py",
        "/etc/systemd/system/sing-box.service",
        "/etc/systemd/system/rr-nexus.service",
        "/etc/systemd/system/argo-rr-health.service",
        "/etc/systemd/system/argo-rr-health.timer",
        "/etc/systemd/system/cloudflared.service",
        "/etc/systemd/system/rr-restore-recovery.service",
        "/etc/systemd/system/rr-restore-watchdog.service",
        "/etc/systemd/system/rr-nexus-ip-acme.service",
        "/etc/systemd/system/rr-nexus-ip-acme.timer",
        "/usr/local/lib/rr-vps/nexus-ip-cert-gate",
        "/usr/local/lib/rr-vps/lego",
        "/usr/local/lib/rr-vps/lego.install",
        "/etc/nginx",
        "/etc/nginx/sites-available",
        "/etc/nginx/sites-enabled",
        "/etc/nginx/sites-available/rr-nexus.conf",
        "/etc/nginx/sites-available/rr-nexus.conf.port",
        "/etc/nginx/sites-available/rr-nexus-ip.conf",
        "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
        "/etc/nginx/sites-enabled/rr-nexus.conf",
        "/etc/nginx/sites-enabled/rr-nexus-port.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip.conf",
        "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf",
    }
    for unit in dropin_units:
        dropin = f"/etc/systemd/system/{unit}.d"
        exact_writers.add(dropin)
        exact_writers.add(f"{dropin}/40-rr-restore-gate.conf")
        exact_writers.add(f"{dropin}/zzzz-rr-restore-gate.conf")
        exact_writers.add(f"{dropin}/zzzzz-rr-firewall-quarantine.conf")
        exact_writers.add(f"{dropin}/zzzzzz-rr-nexus-ip-cert-gate.conf")

    config_logical = configured_config
    if validation_root and configured_config.startswith(
        validation_root.rstrip("/") + "/"
    ):
        config_logical = configured_config[len(validation_root.rstrip("/")):]
    exact_writers.add(config_logical)

    for physical_mountpoint in read_mountpoints():
        mountpoint = logical_mountpoint(physical_mountpoint)
        if any(at_or_below(mountpoint, root) for root in deletion_roots):
            raise UnsafeShape(
                physical_mountpoint,
                "mount crosses a recursive restore deletion boundary",
            )
        if mountpoint in exact_writers:
            raise UnsafeShape(
                physical_mountpoint, "mount replaces an exact restore writer target"
            )
except UnsafeShape as error:
    print(
        f"目标快照路径形状不安全，恢复尚未修改目标机：{error.path} ({error.reason})。",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

rr_restore_validate_portable_config() {
    local config="$1"
    [ -f "$config" ] && [ ! -L "$config" ] || return 1
    rr_restore_validate_node_config "$config" || return 1
    python3 - "$config" <<'PY'
import shlex
import sys
import uuid

values = {}
with open(sys.argv[1], "r", encoding="utf-8") as source:
    for raw in source:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, encoded = line.split("=", 1)
        parsed = shlex.split(encoded, posix=True)
        values[key] = parsed[0] if parsed else ""
try:
    if int(values.get("CONFIG_VERSION", "0")) < 1:
        raise ValueError
    uuid.UUID(values.get("UUID", ""))
except (ValueError, TypeError, AttributeError):
    raise SystemExit("portable config identity is invalid")
if values.get("INSTALL_COMPLETE") != "true":
    raise SystemExit("portable config is not a completed installation")
for key in ("VM_ENABLED", "VL_ENABLED", "HY2_ENABLED", "TU5_ENABLED", "AN_ENABLED", "NAIVE_ENABLED"):
    if values.get(key, "false") not in {"true", "false"}:
        raise SystemExit(f"invalid protocol state: {key}")
PY
}

rr_restore_preflight_portable_naive_target() {
    local imported_config="$1" payload_root="$2"
    local imported_naive="" naive_domain="" imported_cert_dir=""
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"

    imported_naive=$(python3 - "$imported_config" <<'PY'
import shlex
import sys

values = {}
with open(sys.argv[1], "r", encoding="utf-8") as source:
    for raw in source:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, encoded = line.split("=", 1)
        parsed = shlex.split(encoded, posix=True)
        values[key] = parsed[0] if parsed else ""
if values.get("NAIVE_ENABLED", "false") == "true":
    print("enabled:" + values.get("NAIVE_DOMAIN", ""))
else:
    print("disabled:")
PY
    ) || return 1
    case "$imported_naive" in
        disabled:)
            return 0
            ;;
        enabled:*)
            naive_domain="${imported_naive#enabled:}"
            ;;
        *)
            printf '无法解析便携备份中的 NaiveProxy 状态；恢复尚未修改目标机。\n' >&2
            return 1
            ;;
    esac
    is_valid_domain "$naive_domain" || {
        printf '便携备份启用了 NaiveProxy，但域名无效；恢复尚未修改目标机。\n' >&2
        return 1
    }

    declare -F naive_certificate_pair_valid >/dev/null 2>&1 || return 1
    imported_cert_dir="$payload_root/rootfs/etc/rr-naive"
    naive_certificate_pair_valid \
        "$imported_cert_dir/fullchain.pem" \
        "$imported_cert_dir/privkey.pem" "$naive_domain" || {
        printf '%s\n' \
            '便携备份中的 NaiveProxy 证书缺失、域名不匹配、即将过期、私钥不匹配或不受信任；恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }

    # Portable archives intentionally do not contain Certbot accounts,
    # renewal configuration or deploy hooks.  Creating them in a blank or
    # unprepared target would mutate global ACME, Nginx, package and firewall
    # state outside the restore snapshot.  Require a fully prepared target and
    # keep the transaction path read-only for all global certificate state.
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || {
        printf '%s\n' \
            '便携备份启用了 NaiveProxy，但目标机尚未预置匹配的可续签证书与部署钩子；恢复尚未修改目标机即已拒绝。请先用当前 RR-vps 在目标机建立匹配 lineage 和钩子后再恢复。' >&2
        return 1
    }
    naive_certificate_pair_valid \
        "$le_live_root/$naive_domain/fullchain.pem" \
        "$le_live_root/$naive_domain/privkey.pem" "$naive_domain" || {
        printf '%s\n' \
            '目标机缺少与导入 NaiveProxy 域名匹配且受信任的可续签证书；恢复尚未修改目标机即已拒绝。请先用当前 RR-vps 建立匹配 lineage 后再恢复。' >&2
        return 1
    }
    declare -F rr_certbot_webroot_lineage_is_renewable >/dev/null 2>&1 || return 1
    rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {
        printf '%s\n' \
            '目标机证书虽然有效，但不是结构完整的生产 Webroot lineage；恢复尚未修改目标机即已拒绝。请先用当前 RR-vps 重新建立 lineage。' >&2
        return 1
    }
    declare -F rr_certbot_renewal_runtime_is_ready >/dev/null 2>&1 || return 1
    rr_certbot_renewal_runtime_is_ready "$naive_domain" || {
        printf '%s\n' \
            '目标机 Certbot 定时器或该域名的本机 ACME HTTP 路由未就绪；恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
    declare -F rr_certificate_deploy_hook_is_current >/dev/null 2>&1 || return 1
    rr_certificate_deploy_hook_is_current || {
        printf '%s\n' \
            '目标机 NaiveProxy 证书部署钩子缺失或不是当前受信版本；恢复尚未修改目标机即已拒绝。请先用当前 RR-vps 更新钩子后再恢复。' >&2
        return 1
    }
    return 0
}

rr_restore_preflight_portable_subscription_target() {
    local target_subscription="" target_domain=""
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"

    # Portable restore deliberately preserves the destination subscription
    # access plane.  A blank target defaults to loopback-only and needs no
    # certificate state; an existing HTTPS target must already be complete so
    # candidate migration never edits global Certbot hooks outside rollback.
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 0
    target_subscription=$(python3 - "$CONFIG_FILE" <<'PY'
import shlex
import sys

values = {}
with open(sys.argv[1], "r", encoding="utf-8") as source:
    for raw in source:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, encoded = line.split("=", 1)
        parsed = shlex.split(encoded, posix=True)
        values[key] = parsed[0] if parsed else ""
print(values.get("SUB_ACCESS_MODE", "local") + ":" + values.get("SUB_DOMAIN", ""))
PY
    ) || return 1
    case "$target_subscription" in
        local:)
            return 0
            ;;
        https:*)
            target_domain="${target_subscription#https:}"
            ;;
        *)
            printf '%s\n' \
                '目标机订阅访问状态无效；便携恢复尚未修改目标机即已拒绝。' >&2
            return 1
            ;;
    esac
    is_valid_domain "$target_domain" || {
        printf '%s\n' \
            '目标机 HTTPS 订阅域名无效；便携恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
    declare -F subscription_certificate_pair_valid >/dev/null 2>&1 || return 1
    subscription_certificate_pair_valid \
        "$le_live_root/$target_domain/fullchain.pem" \
        "$le_live_root/$target_domain/privkey.pem" "$target_domain" || {
        printf '%s\n' \
            '目标机 HTTPS 订阅证书缺失、域名不匹配、即将过期、私钥不匹配或不受信任；便携恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
    declare -F rr_certbot_webroot_lineage_is_renewable >/dev/null 2>&1 || return 1
    rr_certbot_webroot_lineage_is_renewable "$target_domain" || {
        printf '%s\n' \
            '目标机 HTTPS 订阅证书虽然有效，但不是结构完整的生产 Webroot lineage；便携恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
    declare -F rr_certbot_renewal_runtime_is_ready >/dev/null 2>&1 || return 1
    rr_certbot_renewal_runtime_is_ready "$target_domain" || {
        printf '%s\n' \
            '目标机 Certbot 定时器或该域名的本机 ACME HTTP 路由未就绪；便携恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
    declare -F rr_certificate_deploy_hook_is_current >/dev/null 2>&1 || return 1
    rr_certificate_deploy_hook_is_current || {
        printf '%s\n' \
            '目标机 HTTPS 订阅证书部署钩子缺失或不是当前受信版本；便携恢复尚未修改目标机即已拒绝。' >&2
        return 1
    }
}

rr_restore_stage_is_safe() {
    rr_backup_stage_is_safe "$1" restore
}

rr_restore_read_exact_marker() {
    local marker="$1" value=""
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a' "$marker" 2>/dev/null)" = 0:0:600 ] || return 1
    [ "$(stat -c %s "$marker" 2>/dev/null || printf 0)" -le 4096 ] || return 1
    IFS= read -r value < "$marker" || return 1
    [ -n "$value" ] || return 1
    # Re-encoding the one accepted line and comparing bytes rejects extra
    # lines, missing final newlines, NUL bytes and other non-canonical forms.
    cmp -s -- "$marker" <(printf '%s\n' "$value") || return 1
    printf '%s\n' "$value"
}

rr_restore_marker_matches_stage() {
    local marker="$1" stage="$2" value=""
    rr_restore_stage_is_safe "$stage" || return 1
    value=$(rr_restore_read_exact_marker "$marker") || return 1
    [ "$value" = "$stage" ]
}

rr_restore_publish_marker() {
    local marker="$1" stage="$2" directory="" temporary=""
    rr_restore_stage_is_safe "$stage" || return 1
    directory=$(dirname -- "$marker") || return 1
    install -d -m 700 "$directory" || return 1
    temporary=$(mktemp "$directory/.rr-restore-marker.XXXXXX") || return 1
    if ! printf '%s\n' "$stage" > "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_restore_clear_marker() {
    local marker="$1" directory=""
    directory=$(dirname -- "$marker") || return 1
    rm -f -- "$marker" || return 1
    [ -d "$directory" ] || return 0
    sync -f "$directory"
}

rr_restore_active_stage() {
    local stage=""
    stage=$(rr_restore_read_exact_marker "$RR_RESTORE_ACTIVE") || return 1
    rr_restore_stage_is_safe "$stage" || return 1
    printf '%s\n' "$stage"
}

rr_restore_write_phase() {
    local stage="$1" phase="$2" temporary=""
    rr_restore_stage_is_safe "$stage" || return 1
    temporary=$(mktemp "$stage/.phase.XXXXXX") || return 1
    if ! printf '%s\n' "$phase" > "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$stage/phase" || \
       ! sync -f "$stage"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_restore_publish_terminal_phase() {
    local stage="$1" phase="$2"
    case "$phase" in committed|rolled_back|aborted) ;; *) return 1 ;; esac
    # Runtime/configuration state spans several filesystems.  A directory
    # fsync on the small phase file cannot make that host state durable.
    sync || return 1
    rr_restore_write_phase "$stage" "$phase"
}

rr_restore_finalize_terminal_stage() {
    local stage="$1" phase=""
    rr_restore_marker_matches_stage "$RR_RESTORE_ACTIVE" "$stage" || return 1
    phase=$(rr_restore_read_exact_marker "$stage/phase") || return 1
    case "$phase" in committed|rolled_back|aborted) ;; *) return 1 ;; esac
    # Re-publish the same phase so a prior rename-success/directory-fsync
    # failure cannot be followed by removal of the only recovery pointer.
    rr_restore_write_phase "$stage" "$phase" || return 1
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || return 1
    rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || return 1
    rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || return 1
    if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then
        rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || true
        return 1
    fi
    # ACTIVE is the durable rollback/recovery pointer and is always the last
    # critical marker removed.  If its directory fsync fails after unlink,
    # restore both the pointer and ready gate whenever possible.
    if ! rr_restore_clear_marker "$RR_RESTORE_ACTIVE"; then
        rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage" || true
        rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || true
        return 1
    fi
}

rr_restore_commit_candidate() {
    local stage="$1" phase=""
    # Return 1 only while rollback is still safe.  Return 2 once committed may
    # have become visible, even if its final directory fsync was interrupted.
    sync || return 1
    if rr_restore_write_phase "$stage" committed; then
        rr_restore_finalize_terminal_stage "$stage" || return 2
        return 0
    fi
    phase=$(rr_restore_read_exact_marker "$stage/phase") || return 2
    case "$phase" in
        migrating) return 1 ;;
        committed)
            rr_restore_finalize_terminal_stage "$stage" || return 2
            return 0
            ;;
        *) return 2 ;;
    esac
}

rr_restore_gate_dropin_directory_is_safe() {
    local dropin_dir="$1" unit="${2:-}"
    local firewall_dropin="$dropin_dir/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
    local nexus_dropin="$dropin_dir/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
    python3 - "$dropin_dir" "$RR_RESTORE_GATE_DROPIN_NAME" \
        "$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME" \
        "$RR_RESTORE_NEXUS_GATE_DROPIN_NAME" <<'PY'
import os
import stat
import sys

directory, gate_name, firewall_gate_name, nexus_gate_name = sys.argv[1:]
gate_name_raw = os.fsencode(gate_name)
firewall_gate_name_raw = os.fsencode(firewall_gate_name)
nexus_gate_name_raw = os.fsencode(nexus_gate_name)
try:
    directory_info = os.lstat(directory)
except OSError:
    raise SystemExit(1)
if not stat.S_ISDIR(directory_info.st_mode) or stat.S_ISLNK(directory_info.st_mode):
    raise SystemExit(1)
if (directory_info.st_uid, directory_info.st_gid) != (0, 0):
    raise SystemExit(1)
if stat.S_IMODE(directory_info.st_mode) & 0o7022:
    raise SystemExit(1)
try:
    with os.scandir(directory) as entries:
        for entry in entries:
            name = os.fsencode(entry.name)
            if not name.endswith(b".conf"):
                continue
            info = entry.stat(follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise SystemExit(1)
            if (info.st_uid, info.st_gid, info.st_nlink) != (0, 0, 1):
                raise SystemExit(1)
            if stat.S_IMODE(info.st_mode) & 0o7022:
                raise SystemExit(1)
            if (
                name > gate_name_raw
                and name not in {firewall_gate_name_raw, nexus_gate_name_raw}
            ):
                raise SystemExit(1)
except OSError:
    raise SystemExit(1)
PY
    if [ -e "$firewall_dropin" ] || [ -L "$firewall_dropin" ]; then
        rr_restore_unit_uses_firewall_gate "$unit" || return 1
        rr_restore_firewall_gate_dropin_file_is_exact "$firewall_dropin" || return 1
    fi
    if [ -e "$nexus_dropin" ] || [ -L "$nexus_dropin" ]; then
        rr_restore_unit_uses_nexus_gate "$unit" || return 1
        rr_restore_nexus_gate_dropin_file_is_exact "$nexus_dropin"
    fi
}

rr_restore_gate_dropin_file_is_exact() {
    local dropin="$1"
    local -a lines=()
    [ -f "$dropin" ] && [ ! -L "$dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$dropin" 2>/dev/null)" = 0:0:644:1 ] || return 1
    mapfile -t lines < "$dropin" || return 1
    [ "${#lines[@]}" -eq 2 ] || return 1
    [ "${lines[0]}" = '[Service]' ] || return 1
    [ "${lines[1]}" = \
      "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" ]
}

rr_restore_firewall_gate_dropin_file_is_exact() {
    local dropin="$1"
    local -a lines=()
    [ -f "$dropin" ] && [ ! -L "$dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$dropin" 2>/dev/null)" = 0:0:644:1 ] || return 1
    mapfile -t lines < "$dropin" || return 1
    [ "${#lines[@]}" -eq 3 ] || return 1
    [ "${lines[0]}" = '[Service]' ] || return 1
    [ "${lines[1]}" = \
      "ExecCondition=/usr/bin/test ! -e $RR_RESTORE_FIREWALL_QUARANTINE_FILE" ] || return 1
    [ "${lines[2]}" = \
      "ExecCondition=/usr/bin/test ! -L $RR_RESTORE_FIREWALL_QUARANTINE_FILE" ]
}

rr_restore_nexus_gate_dropin_file_is_exact() {
    local dropin="$1"
    local -a lines=()
    [ -f "$dropin" ] && [ ! -L "$dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$dropin" 2>/dev/null)" = 0:0:644:1 ] || return 1
    mapfile -t lines < "$dropin" || return 1
    [ "${#lines[@]}" -eq 2 ] || return 1
    [ "${lines[0]}" = '[Service]' ] || return 1
    [ "${lines[1]}" = \
      "ExecCondition=$RR_RESTORE_NEXUS_GATE_EXEC_ARGV" ]
}

rr_restore_unit_uses_firewall_gate() {
    case "$1" in
        sing-box.service|rr-nexus.service|rr-subscription.service|\
        argo-rr-health.service) return 0 ;;
        *) return 1 ;;
    esac
}

rr_restore_unit_uses_nexus_gate() {
    [ "$1" = nginx.service ]
}

rr_restore_effective_dropin_order_is_safe() {
    local unit="$1" require_gate="${2:-false}" effective_require=""
    local load_state="" dropin_paths="" allow_firewall=false allow_nexus=false
    local expected="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_GATE_DROPIN_NAME}"
    local firewall_expected="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_FIREWALL_GATE_DROPIN_NAME}"
    local nexus_expected="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}"
    rr_restore_unit_uses_firewall_gate "$unit" && allow_firewall=true
    rr_restore_unit_uses_nexus_gate "$unit" && allow_nexus=true
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || return 1
    dropin_paths=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || return 1
    case "$load_state" in
        loaded) effective_require="$require_gate" ;;
        not-found) effective_require=false ;;
        *) return 1 ;;
    esac
    python3 - "$dropin_paths" "$RR_RESTORE_GATE_DROPIN_NAME" \
        "$expected" "$effective_require" "$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME" \
        "$firewall_expected" "$allow_firewall" \
        "$RR_RESTORE_NEXUS_GATE_DROPIN_NAME" "$nexus_expected" \
        "$allow_nexus" <<'PY'
import os
import sys

(
    raw, gate_name, expected, require_gate, firewall_gate_name,
    firewall_expected, allow_firewall, nexus_gate_name,
    nexus_expected, allow_nexus,
) = sys.argv[1:]
gate_raw = os.fsencode(gate_name)
firewall_gate_raw = os.fsencode(firewall_gate_name)
nexus_gate_raw = os.fsencode(nexus_gate_name)
paths = raw.split()
if any("\\" in path or not path.startswith("/") for path in paths):
    raise SystemExit(1)
if len(paths) != len(set(paths)):
    raise SystemExit(1)
expected_count = 0
firewall_count = 0
nexus_count = 0
for path in paths:
    if os.path.normpath(path) != path:
        raise SystemExit(1)
    name = os.fsencode(os.path.basename(path))
    if not name.endswith(b".conf"):
        raise SystemExit(1)
    if name > nexus_gate_raw:
        raise SystemExit(1)
    if path == expected:
        expected_count += 1
    elif name == gate_raw:
        raise SystemExit(1)
    elif name == firewall_gate_raw:
        if allow_firewall != "true" or path != firewall_expected:
            raise SystemExit(1)
        firewall_count += 1
    elif name == nexus_gate_raw:
        if allow_nexus != "true" or path != nexus_expected:
            raise SystemExit(1)
        nexus_count += 1
    elif name > gate_raw:
        raise SystemExit(1)
if require_gate == "true" and expected_count != 1:
    raise SystemExit(1)
if expected_count > 1 or firewall_count > 1 or nexus_count > 1:
    raise SystemExit(1)
PY
}

rr_restore_effective_marker_view_is_safe() {
    local unit="$1" expected_environment="${2:-}"
    local user="" group="" dynamic_user="" private_users=""
    local private_mounts="" protect_system="" protect_home="" property=""
    local root_ephemeral=no version_line="" systemd_version="" value=""
    local -a empty_properties=(
        RootDirectory RootImage MountImages ExtensionImages
        ExtensionDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths
        InaccessiblePaths JoinsNamespaceOf ReadOnlyPaths ReadWritePaths
        EnvironmentFiles PassEnvironment UnsetEnvironment PAMName
        SystemCallFilter
    )
    version_line=$(systemctl --version 2>/dev/null | head -n 1) || return 1
    [[ "$version_line" =~ ^systemd[[:space:]]+([0-9]+)([[:space:]]|$) ]] || \
        return 1
    systemd_version="${BASH_REMATCH[1]}"
    user=$(systemctl show --property=User --value "$unit" 2>/dev/null) || return 1
    group=$(systemctl show --property=Group --value "$unit" 2>/dev/null) || return 1
    case "${user//[[:space:]]/}" in ""|root) ;; *) return 1 ;; esac
    case "${group//[[:space:]]/}" in ""|root) ;; *) return 1 ;; esac
    dynamic_user=$(systemctl show --property=DynamicUser --value "$unit" \
        2>/dev/null) || return 1
    private_users=$(systemctl show --property=PrivateUsers --value "$unit" \
        2>/dev/null) || return 1
    private_mounts=$(systemctl show --property=PrivateMounts --value "$unit" \
        2>/dev/null) || return 1
    [ "$dynamic_user" = no ] && [ "$private_users" = no ] && \
        [ "$private_mounts" = no ] || return 1
    for property in "${empty_properties[@]}"; do
        value=$(systemctl show --property="$property" --value "$unit" \
            2>/dev/null) || return 1
        [ -z "$value" ] || return 1
    done
    value=$(systemctl show --property=Environment --value "$unit" \
        2>/dev/null) || return 1
    [ "$value" = "$expected_environment" ] || return 1
    if [ "$systemd_version" -ge 254 ]; then
        root_ephemeral=$(systemctl show --property=RootEphemeral --value \
            "$unit" 2>/dev/null) || return 1
    fi
    [ "$root_ephemeral" = no ] || return 1
    protect_system=$(systemctl show --property=ProtectSystem --value "$unit" \
        2>/dev/null) || return 1
    case "$protect_system" in no|yes|full|strict) ;; *) return 1 ;; esac
    protect_home=$(systemctl show --property=ProtectHome --value "$unit" \
        2>/dev/null) || return 1
    case "$unit:$protect_home" in
        rr-nexus.service:yes|cloudflared.service:yes|\
        sing-box.service:no|rr-subscription.service:no|\
        argo-rr-health.service:no|nginx.service:no|\
        rr-restore-recovery.service:no|rr-restore-watchdog.service:no|\
        rr-update-recovery.service:no) ;;
        *) return 1 ;;
    esac
    # Conditions and Asserts can only prevent a start. Query them so a bus or
    # property failure remains fatal, but never treat their current result as
    # proof that the marker ExecCondition observed the host namespace.
    systemctl show --property=Conditions --value "$unit" \
        >/dev/null 2>&1 || return 1
    systemctl show --property=Asserts --value "$unit" \
        >/dev/null 2>&1 || return 1
}

rr_restore_effective_conditions_are_managed() {
    local unit="$1" load_state="" condition="" dropin_paths=""
    local expect_restore=false expect_firewall=false expect_nexus=false
    local restore_dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_GATE_DROPIN_NAME}"
    local firewall_dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_FIREWALL_GATE_DROPIN_NAME}"
    local nexus_dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}"
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || return 1
    case "$load_state" in
        not-found) return 0 ;;
        loaded) ;;
        *) return 1 ;;
    esac
    dropin_paths=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || return 1
    case " $dropin_paths " in
        *" $restore_dropin "*)
            rr_restore_gate_dropin_file_is_exact "$restore_dropin" || return 1
            expect_restore=true
            ;;
    esac
    case " $dropin_paths " in
        *" $firewall_dropin "*)
            rr_restore_unit_uses_firewall_gate "$unit" || return 1
            rr_restore_firewall_gate_dropin_file_is_exact "$firewall_dropin" || return 1
            expect_firewall=true
            ;;
    esac
    case " $dropin_paths " in
        *" $nexus_dropin "*)
            rr_restore_unit_uses_nexus_gate "$unit" || return 1
            rr_restore_nexus_gate_dropin_file_is_exact "$nexus_dropin" || return 1
            expect_nexus=true
            ;;
    esac
    condition=$(systemctl show --property=ExecCondition --value "$unit" 2>/dev/null) || return 1
    if ! python3 - "$condition" "$expect_restore" "$RR_RESTORE_GATE_EXEC_CONDITION" \
        "$expect_firewall" "$RR_RESTORE_FIREWALL_QUARANTINE_FILE" \
        "$expect_nexus" "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
        "$RR_RESTORE_NEXUS_GATE_EXEC_ARGV" <<'PY'
import re
import sys

(
    raw, expect_restore, restore_argv, expect_firewall, firewall_marker,
    expect_nexus, nexus_path, nexus_argv,
) = sys.argv[1:]
records = []
for encoded in re.findall(r"\{([^{}]*)\}", raw):
    fields = {}
    for item in encoded.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
expected = []
if expect_restore == "true":
    expected.append(("/bin/sh", restore_argv, "no"))
if expect_firewall == "true":
    expected.extend(
        [
            ("/usr/bin/test", f"/usr/bin/test ! -e {firewall_marker}", "no"),
            ("/usr/bin/test", f"/usr/bin/test ! -L {firewall_marker}", "no"),
        ]
    )
if expect_nexus == "true":
    expected.append((nexus_path, nexus_argv, "no"))
if (
    records != expected
    or raw.count("{") != len(expected)
    or raw.count("}") != len(expected)
    or raw.count("path=") != len(expected)
    or raw.count("argv[]=") != len(expected)
    or raw.count("ignore_errors=") != len(expected)
):
    raise SystemExit(1)
PY
    then
        return 1
    fi
    rr_restore_effective_marker_view_is_safe "$unit"
}

rr_restore_effective_gate_is_exact() {
    local unit="$1" load_state="" condition="" dropin_paths=""
    local expect_firewall=false expect_nexus=false
    local dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_GATE_DROPIN_NAME}"
    local firewall_dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_FIREWALL_GATE_DROPIN_NAME}"
    local nexus_dropin="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}"
    rr_restore_gate_dropin_file_is_exact "$dropin" || return 1
    rr_restore_effective_dropin_order_is_safe "$unit" true || return 1
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || return 1
    [ "$load_state" = loaded ] || [ "$load_state" = not-found ] || return 1
    if [ "$load_state" = not-found ]; then
        return 0
    fi
    dropin_paths=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || return 1
    case " $dropin_paths " in
        *" $firewall_dropin "*)
            rr_restore_unit_uses_firewall_gate "$unit" || return 1
            rr_restore_firewall_gate_dropin_file_is_exact "$firewall_dropin" || return 1
            expect_firewall=true
            ;;
    esac
    case " $dropin_paths " in
        *" $nexus_dropin "*)
            rr_restore_unit_uses_nexus_gate "$unit" || return 1
            rr_restore_nexus_gate_dropin_file_is_exact "$nexus_dropin" || return 1
            expect_nexus=true
            ;;
    esac
    condition=$(systemctl show --property=ExecCondition --value "$unit" 2>/dev/null) || return 1
    if ! python3 - "$condition" "$RR_RESTORE_GATE_EXEC_CONDITION" \
        "$expect_firewall" "$RR_RESTORE_FIREWALL_QUARANTINE_FILE" \
        "$expect_nexus" "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
        "$RR_RESTORE_NEXUS_GATE_EXEC_ARGV" <<'PY'
import re
import sys

(
    raw, expected_argv, expect_firewall, firewall_marker,
    expect_nexus, nexus_path, nexus_argv,
) = sys.argv[1:]
records = []
for encoded in re.findall(r"\{([^{}]*)\}", raw):
    fields = {}
    for item in encoded.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
expected = [("/bin/sh", expected_argv, "no")]
if expect_firewall == "true":
    expected.extend(
        [
            ("/usr/bin/test", f"/usr/bin/test ! -e {firewall_marker}", "no"),
            ("/usr/bin/test", f"/usr/bin/test ! -L {firewall_marker}", "no"),
        ]
    )
if expect_nexus == "true":
    expected.append((nexus_path, nexus_argv, "no"))
if (
    records != expected
    or raw.count("{") != len(expected)
    or raw.count("}") != len(expected)
    or raw.count("path=") != len(expected)
    or raw.count("argv[]=") != len(expected)
    or raw.count("ignore_errors=") != len(expected)
):
    raise SystemExit(1)
PY
    then
        return 1
    fi
    rr_restore_effective_marker_view_is_safe "$unit"
}

rr_restore_preflight_gate_dropin_order() {
    local unit="" dropin_dir="" restore_dropin="" firewall_dropin="" nexus_dropin=""
    if declare -F rr_firewall_fail_closed_quarantine_active >/dev/null 2>&1 && \
       rr_firewall_fail_closed_quarantine_active; then
        return 1
    fi
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        dropin_dir="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d"
        restore_dropin="$dropin_dir/$RR_RESTORE_GATE_DROPIN_NAME"
        firewall_dropin="$dropin_dir/$RR_RESTORE_FIREWALL_GATE_DROPIN_NAME"
        nexus_dropin="$dropin_dir/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
        if [ -e "$dropin_dir" ] || [ -L "$dropin_dir" ]; then
            rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit" || return 1
        fi
        if [ -e "$restore_dropin" ] || [ -L "$restore_dropin" ]; then
            rr_restore_gate_dropin_file_is_exact "$restore_dropin" || return 1
        fi
        if rr_restore_unit_uses_firewall_gate "$unit"; then
            if [ -e "$firewall_dropin" ] || [ -L "$firewall_dropin" ]; then
                rr_restore_firewall_gate_dropin_file_is_exact \
                    "$firewall_dropin" || return 1
            fi
        elif [ -e "$firewall_dropin" ] || [ -L "$firewall_dropin" ]; then
            return 1
        fi
        if rr_restore_unit_uses_nexus_gate "$unit"; then
            if [ -e "$nexus_dropin" ] || [ -L "$nexus_dropin" ]; then
                rr_restore_nexus_gate_dropin_file_is_exact \
                    "$nexus_dropin" || return 1
            fi
        elif [ -e "$nexus_dropin" ] || [ -L "$nexus_dropin" ]; then
            return 1
        fi
        rr_restore_effective_dropin_order_is_safe "$unit" false || return 1
        # Appending the RR condition is safe only when every existing
        # effective condition is one of the exact managed gates.  Refuse an
        # administrator/base condition rather than reset or silently erase it.
        rr_restore_effective_conditions_are_managed "$unit" || return 1
    done
}

rr_restore_effective_gate_set_is_exact() {
    local unit=""
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        rr_restore_effective_gate_is_exact "$unit" || return 1
    done
}

rr_restore_required_effective_gate_set_is_exact() {
    local cloudflared_service="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    rr_restore_effective_gate_set_is_exact || return 1
    if [ -r "$CONFIG_FILE" ]; then
        rr_restore_effective_gate_is_exact sing-box.service || return 1
        rr_restore_effective_gate_is_exact argo-rr-health.service || return 1
        [ "$(systemctl show --property=LoadState --value sing-box.service \
            2>/dev/null)" = loaded ] || return 1
        [ "$(systemctl show --property=LoadState --value \
            argo-rr-health.service 2>/dev/null)" = loaded ] || return 1
    fi
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        rr_restore_effective_gate_is_exact rr-nexus.service || return 1
        rr_restore_effective_gate_is_exact nginx.service || return 1
        [ "$(systemctl show --property=LoadState --value rr-nexus.service \
            2>/dev/null)" = loaded ] || return 1
        [ "$(systemctl show --property=LoadState --value nginx.service \
            2>/dev/null)" = loaded ] || return 1
    fi
    if [ -f "$cloudflared_service" ] && [ ! -L "$cloudflared_service" ]; then
        rr_restore_effective_gate_is_exact cloudflared.service || return 1
        [ "$(systemctl show --property=LoadState --value cloudflared.service \
            2>/dev/null)" = loaded ] || return 1
    fi
}

rr_restore_require_effective_gates_or_isolate() {
    rr_restore_required_effective_gate_set_is_exact && return 0
    rr_restore_isolate_gate_units >/dev/null 2>&1 || true
    return 1
}

rr_restore_isolate_gate_units() {
    local unit="" load_state="" active_state="" result=0
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || {
            result=1
            continue
        }
        case "$load_state" in
            loaded)
                systemctl stop "$unit" >/dev/null 2>&1 || result=1
                active_state=$(systemctl show --property=ActiveState --value \
                    "$unit" 2>/dev/null) || {
                    result=1
                    continue
                }
                case "$active_state" in inactive|failed) ;; *) result=1 ;; esac
                ;;
            not-found) ;;
            *) result=1 ;;
        esac
    done
    return "$result"
}

rr_restore_write_gate_dropins() {
    local unit="" dropin_dir="" temporary=""
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        dropin_dir="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d"
        install -d -m 755 "$dropin_dir" || return 1
        rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit" || return 1
        temporary=$(mktemp "$dropin_dir/.rr-restore-gate.XXXXXX") || return 1
        if ! cat > "$temporary" <<'EOF'
[Service]
ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'
EOF
        then
            rm -f -- "$temporary"
            return 1
        fi
        chown 0:0 "$temporary" && chmod 644 "$temporary" && \
            sync -f "$temporary" && \
            mv -f -- "$temporary" "$dropin_dir/$RR_RESTORE_GATE_DROPIN_NAME" && \
            sync -f "$dropin_dir" && \
            rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit" && \
            rr_restore_gate_dropin_file_is_exact \
                "$dropin_dir/$RR_RESTORE_GATE_DROPIN_NAME" || {
                rm -f -- "$temporary"
                return 1
            }
    done
}

rr_restore_render_recovery_unit() {
    cat <<'EOF'
[Unit]
Description=RR-vps interrupted portable restore recovery
Wants=network-online.target
After=local-fs.target network-online.target
ConditionPathExists=/var/lib/rr-backup/active

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rr --recover-restore
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
EOF
}

rr_restore_render_watchdog_unit() {
    cat <<'EOF'
[Unit]
Description=RR-vps live portable restore watchdog
After=local-fs.target

[Service]
Type=exec
ExecStart=/usr/local/bin/rr --watch-restore
RuntimeMaxSec=3700
TimeoutStopSec=10
EOF
}

rr_restore_render_update_recovery_unit() {
    cat <<'EOF'
[Unit]
Description=RR-vps interrupted update recovery
DefaultDependencies=no
After=local-fs.target
Before=network.target
ConditionPathExists=/var/lib/rr-update/active

[Service]
Type=oneshot
Environment=RR_UPDATE_RECOVERY_SERVICE=1
UMask=0077
ExecStart=/usr/local/sbin/rr-update-recover recover

[Install]
WantedBy=multi-user.target
EOF
}

rr_restore_effective_exec_vector_is_exact() {
    local raw="$1"
    shift
    [ $(( $# % 2 )) -eq 0 ] || return 1
    python3 - "$raw" "$@" <<'PY'
import re
import sys

raw = sys.argv[1]
spec = sys.argv[2:]
expected = [(spec[i], spec[i + 1], "no") for i in range(0, len(spec), 2)]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if residual.strip():
    raise SystemExit(1)
records = []
for match in matches:
    fields = {}
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(1)
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
if (
    records != expected
    or raw.count("{") != len(expected)
    or raw.count("}") != len(expected)
    or raw.count("path=") != len(expected)
    or raw.count("argv[]=") != len(expected)
    or raw.count("ignore_errors=") != len(expected)
):
    raise SystemExit(1)
PY
}

rr_restore_internal_unit_file_is_exact() {
    local kind="$1" target="$2" canonical="" parent="" mode=""
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    canonical=$(readlink -f -- "$target" 2>/dev/null) || return 1
    [ "$canonical" = "$target" ] || return 1
    parent=$(dirname -- "$target") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] && \
        [ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" = 0:0 ] || return 1
    canonical=$(readlink -f -- "$parent" 2>/dev/null) || return 1
    [ "$canonical" = "$parent" ] || return 1
    mode=$(stat -c %a -- "$parent" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    case "$kind" in
        restore-recovery) cmp -s -- "$target" <(rr_restore_render_recovery_unit) ;;
        restore-watchdog) cmp -s -- "$target" <(rr_restore_render_watchdog_unit) ;;
        update-recovery) cmp -s -- "$target" <(rr_restore_render_update_recovery_unit) ;;
        *) return 1 ;;
    esac
}

rr_restore_internal_unit_effective_identity_is_exact() {
    local kind="$1" unit="$2" target="$3" expected_path="$4"
    local expected_argv="$5" expected_type="$6" expected_environment="$7"
    local load_state="" fragment="" dropins="" exec_start=""
    local exec_start_pre="" exec_reload="" exec_condition=""
    local working_directory="" environment="" service_type=""
    local remain_after_exit=""
    rr_restore_internal_unit_file_is_exact "$kind" "$target" || return 1
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || \
        return 1
    fragment=$(systemctl show --property=FragmentPath --value "$unit" 2>/dev/null) || \
        return 1
    dropins=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || \
        return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$target" ] && \
        [ -z "${dropins//[[:space:]]/}" ] || return 1
    exec_start=$(systemctl show --property=ExecStart --value "$unit" 2>/dev/null) || \
        return 1
    rr_restore_effective_exec_vector_is_exact "$exec_start" \
        "$expected_path" "$expected_argv" || return 1
    exec_start_pre=$(systemctl show --property=ExecStartPre --value "$unit" \
        2>/dev/null) || return 1
    exec_reload=$(systemctl show --property=ExecReload --value "$unit" 2>/dev/null) || \
        return 1
    exec_condition=$(systemctl show --property=ExecCondition --value "$unit" \
        2>/dev/null) || return 1
    rr_restore_effective_exec_vector_is_exact "$exec_start_pre" || return 1
    rr_restore_effective_exec_vector_is_exact "$exec_reload" || return 1
    rr_restore_effective_exec_vector_is_exact "$exec_condition" || return 1
    working_directory=$(systemctl show --property=WorkingDirectory --value "$unit" \
        2>/dev/null) || return 1
    case "${working_directory//[[:space:]]/}" in ""|/) ;; *) return 1 ;; esac
    environment=$(systemctl show --property=Environment --value "$unit" \
        2>/dev/null) || return 1
    [ "$environment" = "$expected_environment" ] || return 1
    service_type=$(systemctl show --property=Type --value "$unit" 2>/dev/null) || \
        return 1
    remain_after_exit=$(systemctl show --property=RemainAfterExit --value "$unit" \
        2>/dev/null) || return 1
    [ "$service_type" = "$expected_type" ] && [ "$remain_after_exit" = no ] || \
        return 1
    rr_restore_effective_marker_view_is_safe "$unit" "$expected_environment"
}

rr_restore_recovery_unit_is_owned() {
    rr_restore_internal_unit_effective_identity_is_exact restore-recovery \
        rr-restore-recovery.service \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service" \
        /usr/local/bin/rr '/usr/local/bin/rr --recover-restore' oneshot ''
}

rr_restore_watchdog_unit_is_owned() {
    rr_restore_internal_unit_effective_identity_is_exact restore-watchdog \
        rr-restore-watchdog.service \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service" \
        /usr/local/bin/rr '/usr/local/bin/rr --watch-restore' exec ''
}

rr_update_recovery_unit_is_owned() {
    rr_restore_internal_unit_effective_identity_is_exact update-recovery \
        rr-update-recovery.service \
        "$RR_RESTORE_SYSTEMD_DIR/rr-update-recovery.service" \
        /usr/local/sbin/rr-update-recover \
        '/usr/local/sbin/rr-update-recover recover' oneshot \
        'RR_UPDATE_RECOVERY_SERVICE=1'
}

rr_restore_internal_unit_is_owned_or_absent() {
    local kind="$1" unit="$2" target="$3" dropin_dir=""
    local load_state="" fragment="" dropins=""
    dropin_dir="${target}.d"
    if [ -e "$target" ] || [ -L "$target" ]; then
        case "$kind" in
            restore-recovery) rr_restore_recovery_unit_is_owned ;;
            restore-watchdog) rr_restore_watchdog_unit_is_owned ;;
            update-recovery) rr_update_recovery_unit_is_owned ;;
            *) return 1 ;;
        esac
        return
    fi
    if [ -e "$dropin_dir" ] || [ -L "$dropin_dir" ]; then
        [ -d "$dropin_dir" ] && [ ! -L "$dropin_dir" ] || return 1
        [ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit \
            2>/dev/null)" ] || return 1
    fi
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || \
        return 1
    fragment=$(systemctl show --property=FragmentPath --value "$unit" 2>/dev/null) || \
        return 1
    dropins=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || \
        return 1
    [ "$load_state" = not-found ] && [ -z "${fragment//[[:space:]]/}" ] && \
        [ -z "${dropins//[[:space:]]/}" ]
}

rr_restore_prepare_recovery_unit() {
    local recovery_tmp="" watchdog_tmp=""
    rr_restore_internal_unit_is_owned_or_absent restore-recovery \
        rr-restore-recovery.service \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service" || return 1
    rr_restore_internal_unit_is_owned_or_absent restore-watchdog \
        rr-restore-watchdog.service \
        "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service" || return 1
    install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR" || return 1
    recovery_tmp=$(mktemp "$RR_RESTORE_SYSTEMD_DIR/.rr-restore-recovery.XXXXXX") || return 1
    watchdog_tmp=$(mktemp "$RR_RESTORE_SYSTEMD_DIR/.rr-restore-watchdog.XXXXXX") || {
        rm -f -- "$recovery_tmp"
        return 1
    }
    if ! rr_restore_render_recovery_unit > "$recovery_tmp"
    then
        rm -f -- "$recovery_tmp" "$watchdog_tmp"
        return 1
    fi
    if ! rr_restore_render_watchdog_unit > "$watchdog_tmp"
    then
        rm -f -- "$recovery_tmp" "$watchdog_tmp"
        return 1
    fi
    chown 0:0 "$recovery_tmp" "$watchdog_tmp" && \
        chmod 644 "$recovery_tmp" "$watchdog_tmp" && \
        sync -f "$recovery_tmp" && sync -f "$watchdog_tmp" && \
        mv -f -- "$recovery_tmp" "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service" && \
        mv -f -- "$watchdog_tmp" "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service" && \
        sync -f "$RR_RESTORE_SYSTEMD_DIR" || {
            rm -f -- "$recovery_tmp" "$watchdog_tmp"
            return 1
        }
    rr_restore_write_gate_dropins || return 1
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        rr_restore_isolate_gate_units >/dev/null 2>&1 || true
        return 1
    fi
    if ! rr_restore_effective_gate_set_is_exact; then
        rr_restore_isolate_gate_units >/dev/null 2>&1 || true
        return 1
    fi
    rr_restore_recovery_unit_is_owned || return 1
    rr_restore_watchdog_unit_is_owned || return 1
    systemctl enable rr-restore-recovery.service >/dev/null 2>&1 || return 1
    rr_restore_unit_file_state_matches rr-restore-recovery.service enabled || return 1
    sync
}

rr_restore_service_gate() {
    local stage="" live_lock_fd=""
    # No durable transaction means normal boot/start behavior. A dangling or
    # malformed active marker fails closed instead of being treated as absent.
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        return 0
    fi
    stage=$(rr_restore_active_stage) || return 1
    rr_restore_marker_matches_stage "$RR_RESTORE_RUNTIME_READY" "$stage" && return 0

    # During the original, still-live restore process, service starts are
    # intentional. The separate live lock is released by SIGKILL and never
    # survives reboot; an interrupted recovery therefore cannot use this path.
    if rr_restore_marker_matches_stage "$RR_RESTORE_LIVE_MARKER" "$stage"; then
        rr_secure_lock_prepare "$RR_RESTORE_LIVE_LOCK_FILE" || return 1
        exec {live_lock_fd}>>"$RR_RESTORE_LIVE_LOCK_FILE" || return 1
        rr_secure_lock_fd_is_safe "$RR_RESTORE_LIVE_LOCK_FILE" "$live_lock_fd" || return 1
        if ! flock -n "$live_lock_fd"; then
            exec {live_lock_fd}>&-
            return 0
        fi
        exec {live_lock_fd}>&-
    fi
    return 1
}

rr_restore_watch_active() {
    local result=0
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ] && \
       [ ! -e "$RR_RESTORE_WATCH_REQUEST" ] && [ ! -L "$RR_RESTORE_WATCH_REQUEST" ]; then
        return 0
    fi
    [[ "$RR_RESTORE_WATCH_TIMEOUT" =~ ^[0-9]+$ ]] && \
        [ "$RR_RESTORE_WATCH_TIMEOUT" -ge 1 ] && \
        [ "$RR_RESTORE_WATCH_TIMEOUT" -le 86400 ] || return 1
    rr_run_with_update_locks direct "$RR_RESTORE_WATCH_TIMEOUT" \
        rr_restore_watch_active_locked || result=$?
    if [ "$result" -eq 75 ] || [ "$result" -eq 76 ]; then result=1; fi
    return "$result"
}

rr_restore_close_runtime_ready_gate() {
    local clear_result=0
    if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then
        clear_result=1
        # unlink may have succeeded before the containing-directory fsync
        # failed.  A successful host sync closes that durability ambiguity.
        if sync && [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
           [ ! -L "$RR_RESTORE_RUNTIME_READY" ]; then
            clear_result=0
        fi
    fi
    if [ "$clear_result" -eq 0 ] && \
       [ ! -e "$RR_RESTORE_RUNTIME_READY" ] && \
       [ ! -L "$RR_RESTORE_RUNTIME_READY" ]; then
        return 0
    fi

    # READY may still authorize a late/manual restart.  Before stopping the
    # current processes, publish and re-prove the independent, reboot-durable
    # firewall quarantine so every managed unit remains blocked even though
    # the restore marker itself could not be removed.
    declare -F rr_firewall_publish_fail_closed_quarantine >/dev/null 2>&1 || return 1
    declare -F rr_firewall_fail_closed_quarantine_active >/dev/null 2>&1 || return 1
    declare -F rr_firewall_load_fail_closed_quarantine >/dev/null 2>&1 || return 1
    declare -F rr_firewall_quarantine_supervisor_effective >/dev/null 2>&1 || return 1
    rr_firewall_publish_fail_closed_quarantine || return 1
    rr_firewall_fail_closed_quarantine_active || return 1
    rr_firewall_load_fail_closed_quarantine || return 1
    rr_firewall_quarantine_supervisor_effective
}

rr_restore_watch_fail_closed() {
    local stage="$1" isolation_result=0 ready_result=0
    rr_restore_stage_is_safe "$stage" || return 1
    # READY is an allow-to-start marker.  Its durable removal must precede
    # every stop operation, otherwise a late/manual restart can cross the gate
    # while ACTIVE still points at the failed transaction.
    rr_restore_close_runtime_ready_gate || ready_result=$?
    # Keep ACTIVE and every rollback artifact intact.  The caller is already
    # failing; this helper exists solely to prove that no candidate runtime
    # can continue after watcher marker/recovery preconditions become
    # indeterminate.  Cloudflared is stopped only with the rollback ownership
    # proof enforced by rr_restore_stop_managed_runtime.
    rr_restore_stop_managed_runtime "$stage/rollback" || isolation_result=$?
    if [ "$isolation_result" -ne 0 ]; then
        printf '恢复看门狗无法证明候选运行时已全部隔离；ACTIVE 与回滚证据已保留：%s\n' \
            "$stage" >&2
    fi
    [ "$ready_result" -eq 0 ] && [ "$isolation_result" -eq 0 ]
}

rr_restore_watch_active_locked() {
    local expected_stage="" current_stage="" armed_from_request=false
    local active_seen=false result=0
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        # A restore arms the watcher before publishing `active`, closing the
        # otherwise unavoidable SIGKILL gap between those two operations.
        # An ordinary manual invocation has neither marker and exits at once.
        expected_stage=$(rr_restore_read_exact_marker "$RR_RESTORE_WATCH_REQUEST") || {
            if [ ! -e "$RR_RESTORE_WATCH_REQUEST" ] && [ ! -L "$RR_RESTORE_WATCH_REQUEST" ]; then
                return 0
            fi
            return 1
        }
        rr_restore_stage_is_safe "$expected_stage" || return 1
        armed_from_request=true
    else
        expected_stage=$(rr_restore_active_stage) || return 1
        active_seen=true
    fi
    if ! rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST"; then
        [ "$active_seen" = false ] || \
            rr_restore_watch_fail_closed "$expected_stage" || result=1
        return 1
    fi
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        if ! rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then
            [ "$active_seen" = false ] || \
                rr_restore_watch_fail_closed "$expected_stage" || result=1
            return 1
        fi
        # SIGKILL before `active` publication cannot require state rollback,
        # but the decrypted staging tree must not be left behind.
        [ "$armed_from_request" = false ] || rm -rf -- "$expected_stage"
        return 0
    fi
    current_stage=$(rr_restore_active_stage) || {
        rr_restore_watch_fail_closed "$expected_stage" || result=1
        return 1
    }
    if [ "$current_stage" != "$expected_stage" ]; then
        rr_restore_watch_fail_closed "$expected_stage" || result=1
        return 1
    fi
    if ! rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then
        rr_restore_watch_fail_closed "$expected_stage" || result=1
        return 1
    fi
    RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
        rr_restore_recover_active || result=$?
    if [ "$result" -ne 0 ]; then
        rr_restore_watch_fail_closed "$expected_stage" || result=1
        return 1
    fi
    return "$result"
}

RR_RESTORE_UNIT_LOAD_STATE=""
RR_RESTORE_UNIT_ACTIVE_STATE=""
RR_RESTORE_UNIT_FILE_STATE=""

rr_restore_unit_state_read() {
    local unit="$1"
    RR_RESTORE_UNIT_LOAD_STATE=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || return 2
    RR_RESTORE_UNIT_ACTIVE_STATE=$(systemctl show --property=ActiveState --value \
        "$unit" 2>/dev/null) || return 2
    RR_RESTORE_UNIT_FILE_STATE=$(systemctl show --property=UnitFileState --value \
        "$unit" 2>/dev/null) || return 2
    if [ "$RR_RESTORE_UNIT_LOAD_STATE" = not-found ] && \
       [ -z "$RR_RESTORE_UNIT_FILE_STATE" ]; then
        RR_RESTORE_UNIT_FILE_STATE=not-found
    fi
    case "$RR_RESTORE_UNIT_LOAD_STATE:$RR_RESTORE_UNIT_ACTIVE_STATE:$RR_RESTORE_UNIT_FILE_STATE" in
        loaded:active:enabled|loaded:active:enabled-runtime|loaded:active:disabled|loaded:active:static|\
        loaded:inactive:enabled|loaded:inactive:enabled-runtime|loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:enabled|loaded:failed:enabled-runtime|loaded:failed:disabled|loaded:failed:static|\
        loaded:activating:enabled|loaded:activating:enabled-runtime|loaded:activating:disabled|loaded:activating:static|\
        loaded:deactivating:enabled|loaded:deactivating:enabled-runtime|loaded:deactivating:disabled|loaded:deactivating:static|\
        loaded:reloading:enabled|loaded:reloading:enabled-runtime|loaded:reloading:disabled|loaded:reloading:static|\
        masked:inactive:masked|masked:failed:masked|not-found:inactive:not-found) return 0 ;;
        *) return 2 ;;
    esac
}

rr_restore_unit_load_state_read() {
    local unit="$1" output_name="$2" load_state=""
    load_state=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || return 1
    case "$load_state" in loaded|masked|not-found) ;; *) return 1 ;; esac
    printf -v "$output_name" '%s' "$load_state"
}

rr_restore_unit_activity_matches() {
    local unit="$1" wanted="$2"
    rr_restore_unit_state_read "$unit" || return 2
    case "$wanted:$RR_RESTORE_UNIT_LOAD_STATE:$RR_RESTORE_UNIT_ACTIVE_STATE" in
        active:loaded:active|\
        inactive:loaded:inactive|inactive:loaded:failed|\
        inactive:masked:inactive|inactive:masked:failed|\
        inactive:not-found:inactive) return 0 ;;
        active:*|inactive:*) return 1 ;;
        *) return 2 ;;
    esac
}

rr_restore_unit_file_state_matches() {
    local unit="$1" wanted="$2"
    rr_restore_unit_state_read "$unit" || return 2
    case "$wanted:$RR_RESTORE_UNIT_LOAD_STATE:$RR_RESTORE_UNIT_FILE_STATE" in
        enabled:loaded:enabled|\
        disabled:loaded:disabled|disabled:loaded:static|\
        disabled:masked:masked|disabled:not-found:not-found) return 0 ;;
        enabled:*|disabled:*) return 1 ;;
        *) return 2 ;;
    esac
}

rr_restore_capture_unit_activity_state() {
    local unit="$1" output_name="$2"
    rr_restore_unit_state_read "$unit" || return 1
    case "$RR_RESTORE_UNIT_LOAD_STATE:$RR_RESTORE_UNIT_ACTIVE_STATE" in
        loaded:active) printf -v "$output_name" '%s' true ;;
        loaded:inactive|loaded:failed|not-found:inactive)
            printf -v "$output_name" '%s' false
            ;;
        # A mask is a persistent administrator decision, not merely an
        # inactive state. Portable restore cannot silently flatten it.
        masked:*|*) return 1 ;;
    esac
}

rr_restore_capture_unit_file_state() {
    local unit="$1" output_name="$2"
    rr_restore_unit_state_read "$unit" || return 1
    case "$RR_RESTORE_UNIT_LOAD_STATE:$RR_RESTORE_UNIT_FILE_STATE" in
        loaded:enabled) printf -v "$output_name" '%s' true ;;
        loaded:disabled|loaded:static|not-found:not-found)
            printf -v "$output_name" '%s' false
            ;;
        masked:*|*) return 1 ;;
    esac
}

rr_restore_reject_unrestorable_unit_states() {
    local unit=""
    for unit in sing-box.service rr-nexus.service \
        argo-rr-health.service argo-rr-health.timer cloudflared.service \
        rr-restore-recovery.service rr-restore-watchdog.service; do
        rr_restore_unit_state_read "$unit" || return 1
        if [ "$RR_RESTORE_UNIT_LOAD_STATE" = masked ] || \
           [ "$RR_RESTORE_UNIT_FILE_STATE" = masked ]; then
            printf '目标 Unit %s 已被 masked；为避免不可逆覆盖，恢复未开始。\n' \
                "$unit" >&2
            return 1
        fi
    done
}

rr_restore_start_watchdog() {
    rr_restore_watchdog_unit_is_owned || return 1
    systemctl reset-failed rr-restore-watchdog.service >/dev/null 2>&1 || true
    rr_restore_watchdog_unit_is_owned || return 1
    systemctl restart rr-restore-watchdog.service >/dev/null 2>&1 || return 1
    rr_restore_unit_activity_matches rr-restore-watchdog.service active
}

rr_restore_filter_managed_firewall_rules() {
    local table="$1" source="$2" target="$3" mode="${4:-managed}"
    python3 - "$table" "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
        "$source" "$mode" > "$target" <<'PY'
import shlex
import sys

table, allow_comment, block_comment, source, mode = sys.argv[1:]
if mode not in {"managed", "positioned", "unmanaged"}:
    raise SystemExit("unsupported firewall snapshot mode")
if table == "filter":
    chain = "INPUT"
elif table == "nat":
    chain = "PREROUTING"
else:
    raise SystemExit("unsupported firewall table")

position = 0
for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit("invalid firewall rule syntax")
    if len(tokens) >= 3 and tokens[0] == "-P" and tokens[1] == chain:
        if mode == "unmanaged":
            print(line)
        continue
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != chain:
        continue
    position += 1
    try:
        comment = tokens[tokens.index("--comment") + 1]
    except (ValueError, IndexError):
        comment = None
    if table == "filter":
        managed = comment in {allow_comment, block_comment}
    else:
        managed = comment is not None and comment.startswith("argo-rr-")
    if managed:
        if mode == "managed":
            print(line)
        elif mode == "positioned":
            print(f"{position}\t{line}")
    elif mode == "unmanaged":
        print(line)
PY
}

rr_restore_capture_netfilter_rules() {
    local backend="$1" table="$2" target="$3" raw=""
    raw=$(mktemp "$(dirname "$target")/.${backend}-${table}.XXXXXX") || return 1
    if ! "$backend" -w 5 -t "$table" -S > "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 1
    fi
    if ! rr_restore_filter_managed_firewall_rules "$table" "$raw" "$target"; then
        rm -f "$raw" "$target"
        return 1
    fi
    rm -f "$raw"
}

rr_restore_capture_netfilter_snapshot() {
    local backend="$1" table="$2" rules_target="$3" unmanaged_target="$4"
    local raw_target="${5:-}" raw=""
    raw=$(mktemp "$(dirname "$rules_target")/.${backend}-${table}.XXXXXX") || return 1
    if ! "$backend" -w 5 -t "$table" -S > "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 1
    fi
    if ! rr_restore_filter_managed_firewall_rules "$table" "$raw" \
        "$rules_target" positioned || \
       ! rr_restore_filter_managed_firewall_rules "$table" "$raw" \
        "$unmanaged_target" unmanaged; then
        rm -f "$raw" "$rules_target" "$unmanaged_target"
        return 1
    fi
    if [ -n "$raw_target" ]; then
        cp -f -- "$raw" "$raw_target" || {
            rm -f "$raw" "$rules_target" "$unmanaged_target" "$raw_target"
            return 1
        }
    fi
    rm -f "$raw"
}

rr_restore_filter_ufw_rules() {
    local source="$1" target="$2" mode="${3:-managed}" validation="${4:-permissive}"
    python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
        "$source" "$mode" "$validation" > "$target" <<'PY'
import re
import shlex
import sys

allow_comment, block_comment = sys.argv[1:3]
managed_comments = {allow_comment, block_comment}
source, mode, validation = sys.argv[3:]
if mode not in {"managed", "unmanaged"}:
    raise SystemExit("unsupported UFW snapshot mode")
if validation not in {"permissive", "strict"}:
    raise SystemExit("unsupported UFW validation mode")

managed_keys = set()
unmanaged_keys = set()
unmanaged_seen = False
unmanaged_simple = True
managed_output = []
for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit("invalid UFW rule syntax")
    if not tokens or tokens[0] != "ufw":
        continue
    try:
        comment = tokens[tokens.index("comment") + 1]
    except (ValueError, IndexError):
        comment = None
    managed = comment in managed_comments
    if managed and validation == "strict":
        if (len(tokens) != 5 or tokens[1] not in {"allow", "deny"}
                or tokens[3] != "comment" or tokens[4] != comment
                or comment != (allow_comment if tokens[1] == "allow" else block_comment)
                or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
                or int(tokens[2].split("/", 1)[0]) > 65535):
            raise SystemExit("unsupported tagged UFW rule")
        key = tokens[2]
        if key in managed_keys:
            raise SystemExit("duplicate or conflicting tagged UFW rule")
        managed_keys.add(key)
    elif not managed and validation == "strict":
        unmanaged_seen = True
        if (len(tokens) not in {3, 5}
                or tokens[1] not in {"allow", "deny", "reject", "limit"}
                or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
                or int(tokens[2].split("/", 1)[0]) > 65535
                or (len(tokens) == 5 and tokens[3] != "comment")):
            unmanaged_simple = False
        else:
            unmanaged_keys.add(tokens[2])
    if managed:
        if mode == "managed":
            managed_output.append(line)
    elif mode == "unmanaged":
        print(line)
if mode == "managed":
    for line in sorted(managed_output):
        print(line)
if (validation == "strict" and managed_keys and unmanaged_seen
        and (not unmanaged_simple or managed_keys & unmanaged_keys)):
    raise SystemExit("UFW rules have ambiguous cross-namespace ordering")
PY
}

rr_restore_capture_ufw_rules() {
    local target="$1" mode="${2:-managed}" raw=""
    raw=$(mktemp "$(dirname "$target")/.ufw.XXXXXX") || return 1
    if ! LC_ALL=C ufw show added > "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 1
    fi
    if ! rr_restore_filter_ufw_rules "$raw" "$target" "$mode"; then
        rm -f "$raw" "$target"
        return 1
    fi
    rm -f "$raw"
}

rr_restore_capture_ufw_snapshot() {
    local rules_target="$1" unmanaged_target="$2" policy="${3:-allow-mixed}" raw=""
    local ordered_target="${4:-}" program_target="${5:-}"
    local validation=permissive
    raw=$(mktemp "$(dirname "$rules_target")/.ufw.XXXXXX") || return 1
    if ! LC_ALL=C ufw show added > "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 1
    fi
    [ "$policy" != prove-disjoint ] || validation=strict
    if ! rr_restore_filter_ufw_rules "$raw" "$rules_target" managed "$validation" || \
       ! rr_restore_filter_ufw_rules "$raw" "$unmanaged_target" unmanaged "$validation"; then
        rm -f "$raw" "$rules_target" "$unmanaged_target"
        if [ "$policy" = prove-disjoint ]; then
            printf '%s\n' \
                '活动 UFW 的用户规则与 RR 端口重叠或格式无法证明互不影响；便携恢复已在防火墙变更前拒绝。' >&2
        fi
        return 1
    fi
    if [ -n "$ordered_target" ] || [ -n "$program_target" ]; then
        [ -n "$ordered_target" ] && [ -n "$program_target" ] || {
            rm -f "$raw" "$rules_target" "$unmanaged_target" \
                "$ordered_target" "$program_target"
            return 1
        }
        cp -f -- "$raw" "$program_target" || {
            rm -f "$raw" "$rules_target" "$unmanaged_target" \
                "$ordered_target" "$program_target"
            return 1
        }
        if ! python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
            "$raw" > "$ordered_target" <<'PY'
import re
import shlex
import sys

allow_comment, block_comment, source = sys.argv[1:]
managed = {allow_comment: "allow", block_comment: "deny"}
position = 0
for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if not tokens or tokens[0] != "ufw":
        continue
    position += 1
    try:
        comment = tokens[tokens.index("comment") + 1]
    except (ValueError, IndexError):
        continue
    if comment not in managed:
        continue
    if (len(tokens) != 5 or tokens[1] != managed[comment]
            or tokens[3:] != ["comment", comment]
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535):
        raise SystemExit(1)
    print(f"{position}\t{line}")
PY
        then
            rm -f "$raw" "$rules_target" "$unmanaged_target" \
                "$ordered_target" "$program_target"
            return 1
        fi
    fi
    rm -f "$raw"
    case "$policy" in
        allow-mixed) ;;
        prove-disjoint) ;;
        *)
            rm -f "$rules_target" "$unmanaged_target"
            return 1
            ;;
    esac
}

rr_restore_firewall_ufw_state() {
    local output_name="$1" rr_state=0 resolved=""
    if ! command -v ufw >/dev/null 2>&1; then
        printf -v "$output_name" '%s' absent
        return 0
    fi
    if rr_ufw_backend_state; then
        resolved=active
    else
        rr_state=$?
        case "$rr_state" in
            1)
                command -v ufw >/dev/null 2>&1 || return 1
                resolved=inactive
                ;;
            *) return 1 ;;
        esac
    fi
    printf -v "$output_name" '%s' "$resolved"
}

rr_restore_firewall_netfilter_state() {
    local backend="$1" output_name="$2" rr_state=0 resolved=""
    if rr_netfilter_backend_state "$backend"; then
        resolved=readable
    else
        rr_state=$?
        case "$rr_state" in
            1)
                command -v "$backend" >/dev/null 2>&1 && return 1
                resolved=absent
                ;;
            *) return 1 ;;
        esac
    fi
    printf -v "$output_name" '%s' "$resolved"
}

rr_restore_firewall_backend_states_match() {
    local snapshot="$1" backend="" expected="" current="" inactive_current=""
    [ -f "$snapshot/ufw.state" ] && [ ! -L "$snapshot/ufw.state" ] || return 1
    expected=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    case "$expected" in active|inactive|absent) ;; *) return 1 ;; esac
    rr_restore_firewall_ufw_state current || return 1
    [ "$current" = "$expected" ] || return 1
    if [ "$expected" = active ]; then
        [ -f "$snapshot/ufw.status" ] && [ ! -L "$snapshot/ufw.status" ] && \
            grep -qE '^Status:[[:space:]]+active([[:space:]]|$)' \
                "$snapshot/ufw.status" || return 1
    elif [ "$expected" = inactive ]; then
        [ -f "$snapshot/ufw.inactive.rules" ] && \
            [ ! -L "$snapshot/ufw.inactive.rules" ] || return 1
        inactive_current=$(mktemp "$snapshot/.verify-ufw-inactive.XXXXXX") || return 1
        if ! LC_ALL=C ufw show added > "$inactive_current" 2>/dev/null || \
           ! cmp -s "$snapshot/ufw.inactive.rules" "$inactive_current"; then
            rm -f "$inactive_current"
            return 1
        fi
        rm -f "$inactive_current"
    fi

    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.state" ] && \
            [ ! -L "$snapshot/${backend}.state" ] || return 1
        expected=$(cat -- "$snapshot/${backend}.state" 2>/dev/null) || return 1
        case "$expected" in readable|absent) ;; *) return 1 ;; esac
        rr_restore_firewall_netfilter_state "$backend" current || return 1
        [ "$current" = "$expected" ] || return 1
    done
    if [ -f "$snapshot/ipv6.disabled" ]; then
        [ ! -L "$snapshot/ipv6.disabled" ] && rr_ipv6_stack_is_disabled || return 1
        [ "$(cat -- "$snapshot/ip6tables.state" 2>/dev/null)" = absent ] || return 1
    elif [ "$(cat -- "$snapshot/ip6tables.state" 2>/dev/null)" = absent ]; then
        return 1
    fi
}

rr_restore_candidate_firewall_keys() {
    local target="$1" panel_port="" nexus_domain="" certificate_mode=""
    load_config_with_defaults || return 1
    : > "$target" || return 1
    if [ "${VM_TLS_ENABLED:-false}" = true ]; then
        is_valid_port "${PORT:-}" || return 1
        printf '%s\n' "${PORT}/tcp open" >> "$target" || return 1
    fi
    is_valid_port "${SUB_PORT:-}" || return 1
    case "${SUB_ACCESS_MODE:-local}" in
        local) printf '%s\n' "${SUB_PORT}/tcp closed" >> "$target" || return 1 ;;
        https) printf '%s\n' "${SUB_PORT}/tcp open" >> "$target" || return 1 ;;
        *) return 1 ;;
    esac
    if [ "${VL_ENABLED:-false}" = true ]; then
        is_valid_port "${VL_PORT:-}" || return 1
        printf '%s\n' "${VL_PORT}/tcp open" >> "$target" || return 1
    fi
    if [ "${HY2_ENABLED:-false}" = true ]; then
        is_valid_port "${HY2_PORT:-}" || return 1
        printf '%s\n' "${HY2_PORT}/udp open" >> "$target" || return 1
    fi
    if [ "${TU5_ENABLED:-false}" = true ]; then
        is_valid_port "${TU5_PORT:-}" || return 1
        printf '%s\n' "${TU5_PORT}/udp open" >> "$target" || return 1
    fi
    if [ "${AN_ENABLED:-false}" = true ]; then
        is_valid_port "${AN_PORT:-}" || return 1
        printf '%s\n' "${AN_PORT}/tcp open" >> "$target" || return 1
    fi
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        is_valid_port "${NAIVE_PORT:-}" || return 1
        case "${NAIVE_MODE:-h2}" in
            h2) printf '%s\n' "${NAIVE_PORT}/tcp open" >> "$target" || return 1 ;;
            h3) printf '%s\n' "${NAIVE_PORT}/udp open" >> "$target" || return 1 ;;
            both)
                printf '%s\n' "${NAIVE_PORT}/tcp open" "${NAIVE_PORT}/udp open" \
                    >> "$target" || return 1
                ;;
            *) return 1 ;;
        esac
    fi
    if [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] && \
       [ "$(jq -r '.mode // empty' \
        "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null)" = public ]; then
        panel_port=$(jq -r '.public_port // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 1
        is_valid_port "$panel_port" || return 1
        printf '%s\n' "${panel_port}/tcp open" >> "$target" || return 1
        nexus_domain=$(jq -r '.domain // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 1
        certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 1
        case "$certificate_mode" in
            acme-ip-shortlived|pending-acme-ip)
                is_global_ip_version "$nexus_domain" 4 || \
                    is_global_ip_version "$nexus_domain" 6 || return 1
                # The destination-owned short-lived IP certificate renews by
                # HTTP-01.  Port 80 is a distinct durable consumer alongside
                # the public panel port and must survive portable migration.
                printf '%s\n' '80/tcp open' >> "$target" || return 1
                ;;
        esac
    fi
    sort -u -o "$target" "$target" || return 1
    # A malformed imported configuration must not let the last duplicate win
    # and silently collapse contradictory open/closed intent for one key.
    awk '
        previous == $1 && previous_action != $2 { exit 1 }
        { previous=$1; previous_action=$2 }
    ' "$target"
}

rr_restore_candidate_hop_keys() {
    local target="$1"
    load_config_with_defaults || return 1
    python3 - "$target" \
        "${HY2_HOP_PORTS:-}" "${HY2_PORT:-}" \
        "${TU5_HOP_PORTS:-}" "${TU5_PORT:-}" <<'PY'
import re
import sys

target, *values = sys.argv[1:]
items = set()
for label, (spec_list, main_port) in zip(("HY2", "TU5"), zip(values[::2], values[1::2])):
    if not spec_list:
        continue
    if re.fullmatch(r"[1-9][0-9]{0,4}", main_port) is None or int(main_port) > 65535:
        raise SystemExit(1)
    for spec in spec_list.split(","):
        match = re.fullmatch(r"([1-9][0-9]{0,4})(?::([1-9][0-9]{0,4}))?", spec)
        if match is None:
            raise SystemExit(1)
        low = int(match.group(1))
        high = int(match.group(2) or match.group(1))
        if high > 65535 or low > high:
            raise SystemExit(1)
        items.add((low, high, label, int(main_port)))
with open(target, "w", encoding="utf-8") as output:
    for low, high, label, main_port in sorted(items):
        print(f"{low}:{high}/udp redirect {label} {main_port}", file=output)
PY
}

rr_restore_candidate_ufw_is_disjoint() {
    local rollback="$1" snapshot="$1/firewall" keys="" rules="" state=""
    state=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    case "$state" in
        active)
            rules="$snapshot/ufw.unmanaged"
            # Any UFW rule writer flushes and rebuilds the user chains.  Recheck
            # the live program immediately before the portable clear gate so a
            # post-snapshot, live-only custom rule can never be erased.
            rr_ufw_reload_program_is_canonical || {
                printf '%s\n' \
                    '活动 UFW 含有无法从持久规则精确重建的 live 用户链；便携恢复已在首次规则写入前拒绝。' >&2
                return 1
            }
            ;;
        inactive) rules="$snapshot/ufw.inactive.rules" ;;
        absent) return 0 ;;
        *) return 1 ;;
    esac
    [ -f "$rules" ] && [ ! -L "$rules" ] || return 1
    keys=$(mktemp "$snapshot/.candidate-ufw-keys.XXXXXX") || return 1
    rr_restore_candidate_firewall_keys "$keys" || {
        rm -f "$keys"
        return 1
    }
    if ! python3 - "$keys" "$rules" <<'PY'
import re
import shlex
import sys

keys = {}
for raw_key in open(sys.argv[1], encoding="utf-8"):
    fields = raw_key.split()
    if len(fields) != 2 or fields[1] not in {"open", "closed"}:
        raise SystemExit(1)
    keys[fields[0]] = fields[1]
for raw_line in open(sys.argv[2], encoding="utf-8"):
    line = raw_line.strip()
    if not line:
        continue
    if line == "Added user rules (see 'ufw status' for running firewall):":
        continue
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if (len(tokens) not in {3, 5} or tokens[0] != "ufw"
            or tokens[1] not in {"allow", "deny", "reject", "limit"}
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535
            or (len(tokens) == 5 and tokens[3] != "comment")
            or tokens[2] in keys):
        raise SystemExit(1)
PY
    then
        rm -f "$keys"
        printf '%s\n' \
            '目标 UFW 用户规则与导入配置的 RR 端口重叠或格式无法证明互不影响；便携恢复已在防火墙变更前拒绝。' >&2
        return 1
    fi
    rm -f "$keys"
}

rr_restore_candidate_netfilter_is_disjoint() {
    local rollback="$1" snapshot="$1/firewall" keys="" hop_keys="" backend=""
    local filter_raw="" nat_raw="" ufw_user_chain="" proof_mode=netfilter
    local ufw_active=0 ufw_v6_declared=0 namespace_state=0
    if rr_netfilter_rr_namespace_is_empty; then
        namespace_state=0
    else
        namespace_state=$?
    fi
    case "$namespace_state" in
        0|1) ;;
        *)
            printf '%s\n' \
                '目标缺少可读防火墙 filter 权威后端，或 RR 原始规则命名空间无效；便携恢复已在首次规则写入前拒绝。' >&2
            return 1
            ;;
    esac
    keys=$(mktemp "$snapshot/.candidate-netfilter-keys.XXXXXX") || return 1
    hop_keys=$(mktemp "$snapshot/.candidate-netfilter-hops.XXXXXX") || {
        rm -f "$keys"
        return 1
    }
    rr_restore_candidate_firewall_keys "$keys" || {
        rm -f "$keys" "$hop_keys"
        return 1
    }
    rr_restore_candidate_hop_keys "$hop_keys" || {
        rm -f "$keys" "$hop_keys"
        return 1
    }
    if [ -f "$snapshot/ufw.enabled" ]; then
        ufw_active=1
        [ -f "$snapshot/ufw.status" ] && [ ! -L "$snapshot/ufw.status" ] && \
            grep -qE '^Status:[[:space:]]+active([[:space:]]|$)' \
                "$snapshot/ufw.status" && \
            [ -f "$snapshot/iptables.enabled" ] || {
            rm -f "$keys" "$hop_keys"
            printf '%s\n' \
                '活动 UFW 缺少 IPv4 raw filter 证明；便携恢复已在首次规则写入前拒绝。' >&2
            return 1
        }
        if grep -qE '^[^[:space:]]+[[:space:]]+\(v6\)[[:space:]]' \
            "$snapshot/ufw.status"; then
            ufw_v6_declared=1
            if [ ! -f "$snapshot/ip6tables.enabled" ]; then
                rm -f "$keys" "$hop_keys"
                printf '%s\n' \
                    '活动 UFW 声明 IPv6 规则但缺少 IPv6 raw filter 证明；便携恢复已在首次规则写入前拒绝。' >&2
                return 1
            fi
        fi
        if [ ! -f "$snapshot/ip6tables.enabled" ]; then
            [ -f "$snapshot/ipv6.disabled" ] && \
                [ ! -L "$snapshot/ipv6.disabled" ] && \
                rr_ipv6_stack_is_disabled || {
                rm -f "$keys" "$hop_keys"
                printf '%s\n' \
                    '活动 UFW 缺少 IPv6 raw filter 证明，且无法证明系统 IPv6 已禁用；便携恢复已在首次规则写入前拒绝。' >&2
                return 1
            }
        fi
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        [ -f "$snapshot/${backend}.filter.unmanaged" ] && \
            [ ! -L "$snapshot/${backend}.filter.unmanaged" ] || {
            rm -f "$keys" "$hop_keys"
            return 1
        }
        [ -f "$snapshot/${backend}.nat.unmanaged" ] && \
            [ ! -L "$snapshot/${backend}.nat.unmanaged" ] || {
            rm -f "$keys" "$hop_keys"
            return 1
        }
        filter_raw="$snapshot/${backend}.filter.raw"
        nat_raw="$snapshot/${backend}.nat.raw"
        case "$backend" in
            iptables) ufw_user_chain=ufw-user-input ;;
            ip6tables) ufw_user_chain=ufw6-user-input ;;
            *) rm -f "$keys" "$hop_keys"; return 1 ;;
        esac
        [ -f "$filter_raw" ] && [ ! -L "$filter_raw" ] && \
            [ -f "$nat_raw" ] && [ ! -L "$nat_raw" ] || {
            rm -f "$keys" "$hop_keys"
            return 1
        }
        proof_mode=netfilter
        if [ "$ufw_active" -eq 1 ]; then
            if [ "$backend" = iptables ]; then
                proof_mode=ufw
            elif grep -qE '^-N ufw6-user-input$|^-A ufw6-user-input([[:space:]]|$)' \
                "$filter_raw"; then
                proof_mode=ufw
            elif [ "$ufw_v6_declared" -eq 1 ]; then
                rm -f "$keys" "$hop_keys"
                return 1
            else
                proof_mode=raw-effective
            fi
        fi
        if ! python3 - "$keys" "$snapshot/${backend}.filter.unmanaged" \
            "$filter_raw" "$proof_mode" "$FIREWALL_COMMENT" \
            "$FIREWALL_BLOCK_COMMENT" "$snapshot/ufw.rules" "$hop_keys" \
            "$snapshot/${backend}.nat.unmanaged" "$nat_raw" \
            "$ufw_user_chain" <<'PY'
import re
import shlex
import sys

candidate = {}
for raw_key in open(sys.argv[1], encoding="utf-8"):
    fields = raw_key.split()
    if (len(fields) != 2 or fields[1] not in {"open", "closed"}
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", fields[0]) is None):
        raise SystemExit(1)
    port_text, proto = fields[0].split("/", 1)
    port = int(port_text)
    if port > 65535:
        raise SystemExit(1)
    candidate[(port, proto)] = fields[1]

unmanaged_filter, raw_filter = sys.argv[2:4]
proof_mode = sys.argv[4]
if proof_mode not in {"ufw", "netfilter", "raw-effective"}:
    raise SystemExit(1)
allow_comment, block_comment = sys.argv[5:7]
managed_comments = {allow_comment, block_comment}
managed_ufw_file, hop_file, unmanaged_nat, raw_nat = sys.argv[7:11]
ufw_user_chain = sys.argv[11]
safe_continue_targets = {"LOG", "NFLOG", "TRACE"}

managed_ufw = {}
if proof_mode == "ufw":
    for raw_rule in open(managed_ufw_file, encoding="utf-8"):
        try:
            tokens = shlex.split(raw_rule)
        except ValueError:
            raise SystemExit(1)
        if (len(tokens) != 5 or tokens[0] != "ufw"
                or tokens[1] not in {"allow", "deny"}
                or tokens[3] != "comment" or tokens[4] not in managed_comments
                or tokens[4] != (allow_comment if tokens[1] == "allow" else block_comment)
                or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None):
            raise SystemExit(1)
        port_text, proto = tokens[2].split("/", 1)
        key = (int(port_text), proto)
        target = "ACCEPT" if tokens[1] == "allow" else "DROP"
        if key in managed_ufw:
            raise SystemExit(1)
        managed_ufw[key] = target
managed_ufw_seen = set()

hop_ranges = []
for raw_key in open(hop_file, encoding="utf-8"):
    fields = raw_key.split()
    if (len(fields) != 4 or fields[1] != "redirect"
            or re.fullmatch(r"[1-9][0-9]{0,4}:[1-9][0-9]{0,4}/udp", fields[0]) is None):
        raise SystemExit(1)
    bounds, _ = fields[0].split("/", 1)
    low, high = map(int, bounds.split(":"))
    if low > high or high > 65535:
        raise SystemExit(1)
    hop_ranges.append((low, high))


def option_value(tokens, *names):
    for index, token in enumerate(tokens):
        if token not in names:
            continue
        if index + 1 >= len(tokens):
            return None, True, False
        negated = index > 0 and tokens[index - 1] == "!"
        return tokens[index + 1], False, negated
    return "", False, False


def comment_value(tokens):
    value, ambiguous, negated = option_value(tokens, "--comment")
    if ambiguous or negated:
        return None
    return value or None


def port_intervals(spec):
    intervals = []
    for part in spec.split(","):
        if re.fullmatch(r"[0-9]+", part):
            low = high = int(part)
        else:
            match = re.fullmatch(r"([0-9]+)[:-]([0-9]+)", part)
            if match is None:
                return None
            low, high = map(int, match.groups())
        if low < 1 or high > 65535 or low > high:
            return None
        intervals.append((low, high))
    return intervals


def rule_overlap(tokens, wanted, *, local_new=True):
    if "-i" in tokens:
        interface, ambiguous, negated = option_value(tokens, "-i", "--in-interface")
        if not ambiguous and not negated and interface == "lo":
            return set()
    if local_new:
        destination_type, ambiguous_type, negated_type = option_value(tokens, "--dst-type")
        if not ambiguous_type and destination_type:
            is_local = destination_type.upper() == "LOCAL"
            if (is_local and negated_type) or (not is_local and not negated_type):
                return set()
    state, ambiguous_state, negated_state = option_value(tokens, "--ctstate", "--state")
    if not ambiguous_state and not negated_state and state:
        states = {value.upper() for value in state.split(",")}
        if states and "NEW" not in states:
            return set()

    proto, ambiguous_proto, negated_proto = option_value(tokens, "-p", "--protocol")
    if ambiguous_proto or negated_proto:
        protocols = {"tcp", "udp"}
    elif not proto or proto in {"all", "0"}:
        protocols = {"tcp", "udp"}
    elif proto in {"tcp", "udp"}:
        protocols = {proto}
    else:
        return set()

    spec, ambiguous_port, negated_port = option_value(tokens, "--dport", "--dports")
    possible = {(port, item_proto) for port, item_proto in wanted
                if item_proto in protocols}
    if not possible:
        return set()
    if ambiguous_port or negated_port or not spec:
        return possible
    ranges = port_intervals(spec)
    if ranges is None:
        return possible
    return {(port, item_proto) for port, item_proto in possible
            if any(low <= port <= high for low, high in ranges)}


def rule_covers_candidate(tokens, wanted):
    if len(wanted) != 1 or "!" in tokens:
        return False
    (port, protocol), _ = next(iter(wanted.items()))
    allowed_modules = {protocol, "comment", "conntrack", "state", "addrtype", "multiport"}
    seen = set()
    index = 2
    while index < len(tokens):
        token = tokens[index]
        if token == "-m":
            if index + 1 >= len(tokens) or tokens[index + 1] not in allowed_modules:
                return False
            index += 2
            continue
        if token in {"-p", "--protocol", "--dport", "--dports",
                     "--ctstate", "--state", "--dst-type", "--comment",
                     "-j", "--jump"}:
            if index + 1 >= len(tokens) or token in seen:
                return False
            seen.add(token)
            value = tokens[index + 1]
            if token in {"-p", "--protocol"} and value not in {"all", "0", protocol}:
                return False
            if token in {"--dport", "--dports"}:
                intervals = port_intervals(value)
                if intervals is None or not any(low <= port <= high for low, high in intervals):
                    return False
            if token in {"--ctstate", "--state"} and \
                    "NEW" not in {item.upper() for item in value.split(",")}:
                return False
            if token == "--dst-type" and value.upper() != "LOCAL":
                return False
            index += 2
            continue
        return False
    return True


def parse_rules(path):
    chains = {}
    policies = {}
    for raw_line in open(path, encoding="utf-8"):
        try:
            tokens = shlex.split(raw_line)
        except ValueError:
            raise SystemExit(1)
        if len(tokens) >= 3 and tokens[0] == "-P":
            policies[tokens[1]] = tokens[2]
        elif len(tokens) == 2 and tokens[0] == "-N":
            chains.setdefault(tokens[1], [])
        elif len(tokens) >= 3 and tokens[0] == "-A":
            chains.setdefault(tokens[1], []).append(tokens)
    return chains, policies


def jump_target(tokens):
    goto, ambiguous_goto, negated_goto = option_value(tokens, "-g", "--goto")
    if ambiguous_goto or negated_goto or goto:
        raise SystemExit(1)
    target, ambiguous, negated = option_value(tokens, "-j", "--jump")
    if ambiguous or negated or not target:
        raise SystemExit(1)
    return target


def removable_compiled_ufw_rule(tokens, target):
    if tokens[1] != ufw_user_chain or "!" in tokens:
        return False
    if (sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1
            or tokens.count("-m") > 1):
        return False
    proto, bad_proto, negated_proto = option_value(tokens, "-p", "--protocol")
    port_spec, bad_port, negated_port = option_value(tokens, "--dport")
    if bad_proto or negated_proto or bad_port or negated_port:
        return False
    if proto not in {"tcp", "udp"} or re.fullmatch(r"[1-9][0-9]{0,4}", port_spec) is None:
        return False
    key = (int(port_spec), proto)
    if managed_ufw.get(key) != target:
        return False
    # A simple UFW PORT/PROTO rule compiles to only the protocol matcher, its
    # protocol module, destination port and terminal verdict.  Correlate that
    # exact shape with `ufw show added`; accepting source/interface/state or an
    # unknown extension here could hide an administrator custom rule.
    index = 2
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens) and tokens[index + 1] == proto:
            index += 2
        else:
            return False
    if key in managed_ufw_seen:
        raise SystemExit(1)
    managed_ufw_seen.add(key)
    return True


def check_direct_rule(raw_line, wanted_chain):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != wanted_chain:
        return
    overlap = rule_overlap(tokens, candidate)
    if not overlap:
        return
    target = jump_target(tokens)
    if target in safe_continue_targets:
        return
    # Any terminal verdict or user-chain transfer that can match a candidate
    # key changes effective first-match semantics and is therefore ambiguous.
    raise SystemExit(1)


def prove_ufw_candidate_reachable():
    chains, policies = parse_rules(raw_filter)
    if "INPUT" not in chains or policies.get("INPUT") not in {"ACCEPT", "DROP"}:
        raise SystemExit(1)
    for candidate_key, action in candidate.items():
        wanted = {candidate_key: action}
        def walk(chain, stack):
            if chain in stack or len(stack) > 64 or chain not in chains:
                raise SystemExit(1)
            for tokens in chains[chain]:
                if not rule_overlap(tokens, wanted):
                    continue
                target = jump_target(tokens)
                if target in safe_continue_targets:
                    continue
                if chain == "INPUT" and comment_value(tokens) in managed_comments:
                    # Only tagged INPUT rules are in the raw clear namespace.
                    # A lookalike in a custom chain is administrator policy and
                    # must remain a conflict unless correlated to UFW evidence.
                    continue
                if chain == ufw_user_chain and \
                        removable_compiled_ufw_rule(tokens, target):
                    # Portable restore clears every RR-owned UFW rule before
                    # rebuilding the imported desired set.  Prove the future
                    # tail-insert position, never the current short-circuit.
                    continue
                if not rule_covers_candidate(tokens, wanted):
                    raise SystemExit(1)
                if target == "RETURN":
                    if chain in {"INPUT", ufw_user_chain}:
                        raise SystemExit(1)
                    return "returned"
                if target == ufw_user_chain:
                    return walk(target, stack + (chain,))
                if target in chains:
                    outcome = walk(target, stack + (chain,))
                    if outcome == "reached":
                        return outcome
                    continue
                # Any verdict/extension reachable by this NEW local key before
                # the family-specific UFW user chain may shadow policy.
                raise SystemExit(1)

            if chain == ufw_user_chain:
                return "reached"
            if chain == "INPUT":
                return "missing"
            return "returned"

        if walk("INPUT", ()) != "reached":
            raise SystemExit(1)


def nat_rule_overlaps_hop(tokens):
    if not hop_ranges:
        return False
    proto, ambiguous_proto, negated_proto = option_value(tokens, "-p", "--protocol")
    if ambiguous_proto or negated_proto or not proto or proto in {"all", "0"}:
        protocol_matches = True
    elif proto == "udp":
        protocol_matches = True
    elif proto == "tcp":
        protocol_matches = False
    else:
        protocol_matches = False
    if not protocol_matches:
        return False
    spec, ambiguous, negated = option_value(tokens, "--dport", "--dports")
    if ambiguous or negated or not spec:
        return True
    rule_ranges = port_intervals(spec)
    if rule_ranges is None:
        return True
    return any(max(left, low) <= min(right, high)
               for left, right in rule_ranges for low, high in hop_ranges)


if proof_mode == "ufw":
    prove_ufw_candidate_reachable()
elif proof_mode == "netfilter":
    for raw_line in open(unmanaged_filter, encoding="utf-8"):
        check_direct_rule(raw_line, "INPUT")
else:
    chains, policies = parse_rules(raw_filter)
    if "INPUT" not in chains or policies.get("INPUT") not in {"ACCEPT", "DROP"}:
        raise SystemExit(1)
    for candidate_key, action in candidate.items():
        wanted = {candidate_key: action}
        for tokens in chains["INPUT"]:
            if not rule_overlap(tokens, wanted):
                continue
            target = jump_target(tokens)
            if target in safe_continue_targets:
                continue
            if comment_value(tokens) in managed_comments:
                continue
            raise SystemExit(1)
        wanted_policy = "ACCEPT" if action == "open" else "DROP"
        if policies["INPUT"] != wanted_policy:
            raise SystemExit(1)

for raw_line in open(unmanaged_nat, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != "PREROUTING":
        continue
    if not nat_rule_overlaps_hop(tokens):
        continue
    target = jump_target(tokens)
    if target in safe_continue_targets:
        continue
    raise SystemExit(1)
PY
        then
            rm -f "$keys" "$hop_keys"
            printf '%s\n' \
                '目标防火墙用户规则与导入配置的 filter/NAT 策略无法证明互不影响；便携恢复已在规则变更前拒绝。' >&2
            return 1
        fi
    done
    rm -f "$keys" "$hop_keys"
}

rr_restore_candidate_hop_persistence_is_available() {
    load_config_with_defaults || return 1
    if [ -n "${HY2_HOP_PORTS:-}" ] || [ -n "${TU5_HOP_PORTS:-}" ]; then
        rr_firewall_persistence_backend_available || {
            printf '%s\n' \
                '导入配置包含端口跳跃，但目标系统缺少 raw/NAT 持久化后端；尚未改写防火墙规则。' >&2
            return 1
        }
    fi
}

rr_restore_capture_firewall_snapshot() {
    local rollback="$1" snapshot="$1/firewall" backend="" table="" state=""
    local marker_tmp="" raw_target="" ufw_normalize_rules=""
    install -d -m 700 "$snapshot" || return 1

    rr_restore_firewall_ufw_state state || return 1
    printf '%s\n' "$state" > "$snapshot/ufw.state" || return 1
    case "$state" in
        active)
            LC_ALL=C ufw status > "$snapshot/ufw.status" 2>/dev/null && \
                grep -qE '^Status:[[:space:]]+active([[:space:]]|$)' \
                    "$snapshot/ufw.status" || return 1
            rr_restore_capture_ufw_snapshot "$snapshot/ufw.rules" \
                "$snapshot/ufw.unmanaged" prove-disjoint \
                "$snapshot/ufw.ordered" "$snapshot/ufw.program" || return 1
            # Capture only rollback states that a later UFW add/delete can
            # reproduce without flushing live-only administrator policy.
            rr_ufw_reload_program_is_canonical || {
                printf '%s\n' \
                    '活动 UFW 含有无法从持久规则精确重建的 live 用户链；便携恢复已在任何目标变更前拒绝。' >&2
                return 1
            }
            : > "$snapshot/ufw.enabled" || return 1
            ;;
        inactive)
            LC_ALL=C ufw show added > "$snapshot/ufw.inactive.rules" \
                2>/dev/null || return 1
            rr_restore_filter_ufw_rules "$snapshot/ufw.inactive.rules" \
                "$snapshot/ufw.inactive.managed" managed || return 1
            if [ -s "$snapshot/ufw.inactive.managed" ]; then
                if [ "${RR_UNINSTALL_CAPTURE_INACTIVE_UFW:-0}" != 1 ]; then
                    printf '%s\n' \
                        '未启用的 UFW 中仍保存 RR 规则，未来启用时可能恢复旧策略；便携恢复已在防火墙变更前拒绝。' >&2
                    return 1
                fi
            fi
            # Complete uninstall owns a narrower transaction that removes
            # only tagged RR entries from UFW's disabled saved program and can
            # restore their exact order.  Ordinary portable restore continues
            # to reject this state above.
            if [ "${RR_UNINSTALL_CAPTURE_INACTIVE_UFW:-0}" = 1 ]; then
                rr_restore_filter_ufw_rules "$snapshot/ufw.inactive.rules" \
                    "$snapshot/ufw.inactive.managed" managed strict || return 1
                rr_restore_filter_ufw_rules "$snapshot/ufw.inactive.rules" \
                    "$snapshot/ufw.inactive.unmanaged" unmanaged strict || return 1
            fi
            ;;
        absent) ;;
        *) return 1 ;;
    esac

    for backend in iptables ip6tables; do
        rr_restore_firewall_netfilter_state "$backend" state || return 1
        printf '%s\n' "$state" > "$snapshot/${backend}.state" || return 1
        case "$state" in
            readable)
                : > "$snapshot/${backend}.enabled" || return 1
                for table in filter nat; do
                    raw_target="$snapshot/${backend}.${table}.raw"
                    rr_restore_capture_netfilter_snapshot "$backend" "$table" \
                        "$snapshot/${backend}.${table}.rules" \
                        "$snapshot/${backend}.${table}.unmanaged" \
                        "$raw_target" || return 1
                    : > "$snapshot/${backend}.${table}.enabled" || return 1
                done
                ;;
            absent) ;;
            *) return 1 ;;
        esac
    done

    # A portable transaction must establish a writable/readable IPv4 filter
    # authority before it can ever clear target rules.  Active UFW additionally
    # needs an IPv6 raw view unless the kernel itself proves IPv6 disabled.
    [ -f "$snapshot/iptables.enabled" ] || return 1
    if [ ! -f "$snapshot/ip6tables.enabled" ]; then
        rr_ipv6_stack_is_disabled || return 1
        : > "$snapshot/ipv6.disabled" || return 1
    fi

    [ ! -f "$snapshot/ufw.enabled" ] || ufw_normalize_rules="$snapshot/ufw.rules"
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        for table in filter nat; do
            rr_restore_normalize_full_firewall_program "$table" "$backend" \
                "$snapshot/${backend}.${table}.raw" "$ufw_normalize_rules" \
                "$snapshot/${backend}.${table}.unmanaged.raw" || return 1
        done
    done

    marker_tmp="$snapshot/.complete.$$"
    printf '%s\n' firewall-snapshot-v2 > "$marker_tmp" && chmod 600 "$marker_tmp" && \
        sync -f "$marker_tmp" && mv -f "$marker_tmp" "$snapshot/complete" && \
        sync -f "$snapshot" || {
            rm -f "$marker_tmp"
            return 1
    }
}

rr_restore_validate_ufw_ordered_evidence() {
    local snapshot="$1"
    python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
        "$snapshot/ufw.program" "$snapshot/ufw.ordered" <<'PY'
import re
import shlex
import sys

allow_comment, block_comment, program_path, ordered_path = sys.argv[1:]
managed = {allow_comment: "allow", block_comment: "deny"}
expected = []
position = 0
for raw_line in open(program_path, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if not tokens or tokens[0] != "ufw":
        continue
    position += 1
    try:
        comment = tokens[tokens.index("comment") + 1]
    except (ValueError, IndexError):
        continue
    if comment not in managed:
        continue
    if (len(tokens) != 5 or tokens[1] != managed[comment]
            or tokens[3:] != ["comment", comment]
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535):
        raise SystemExit(1)
    expected.append(f"{position}\t{line}\n")
with open(ordered_path, encoding="utf-8") as source:
    actual = source.readlines()
if actual != expected:
    raise SystemExit(1)
PY
}

rr_restore_require_firewall_snapshot_v2() {
    local rollback="$1" snapshot="$1/firewall" marker="" evidence=""
    if [ ! -d "$snapshot" ] || [ -L "$snapshot" ] || \
       [ ! -f "$snapshot/complete" ] || [ -L "$snapshot/complete" ]; then
        printf '%s\n' \
            '防火墙回滚证据缺失或未完整提交；已保留恢复事务并拒绝改写规则。' >&2
        return 1
    fi
    marker=$(cat -- "$snapshot/complete" 2>/dev/null) || {
        printf '%s\n' \
            '防火墙回滚证据缺失或未完整提交；已保留恢复事务并拒绝改写规则。' >&2
        return 1
    }
    if [ "$marker" != firewall-snapshot-v2 ]; then
        printf '%s\n' \
            '旧版防火墙回滚快照缺少安全恢复所需的顺序或后端状态证据；已保留恢复事务，拒绝猜测性改写规则。' >&2
        return 1
    fi
    if [ -f "$snapshot/ufw.enabled" ]; then
        [ ! -L "$snapshot/ufw.enabled" ] || return 1
        for evidence in ufw.rules ufw.unmanaged ufw.ordered ufw.program \
            ufw.status ufw.state; do
            [ -f "$snapshot/$evidence" ] && [ ! -L "$snapshot/$evidence" ] || {
                printf '%s\n' \
                    '活动 UFW 的有序回滚证据缺失；已保留恢复事务并拒绝改写规则。' >&2
                return 1
            }
        done
        rr_restore_validate_ufw_ordered_evidence "$snapshot" || {
            printf '%s\n' \
                '活动 UFW 的有序回滚证据不一致；已保留恢复事务并拒绝改写规则。' >&2
            return 1
        }
    fi
}

rr_restore_firewall_snapshot_has_managed_raw_rules() {
    local snapshot="$1" backend="" table="" rules=""
    [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 2
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        [ ! -L "$snapshot/${backend}.enabled" ] || return 2
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            [ ! -L "$snapshot/${backend}.${table}.enabled" ] || return 2
            rules="$snapshot/${backend}.${table}.rules"
            [ -f "$rules" ] && [ ! -L "$rules" ] || return 2
            [ ! -s "$rules" ] || return 0
        done
    done
    return 1
}

rr_restore_live_has_managed_raw_rules() {
    local directory="" backend="" table="" rules="" state=0
    local readable_seen=false managed_seen=false
    directory=$(mktemp -d /tmp/rr-restore-firewall-live.XXXXXX) || return 2
    chmod 700 "$directory" || { rm -rf "$directory"; return 2; }
    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        case "$state" in
            0)
                readable_seen=true
                for table in filter nat; do
                    rules="$directory/${backend}.${table}.rules"
                    if ! rr_restore_capture_netfilter_rules "$backend" "$table" \
                        "$rules"; then
                        rm -rf "$directory"
                        return 2
                    fi
                    [ ! -s "$rules" ] || managed_seen=true
                done
                ;;
            1) ;;
            *) rm -rf "$directory"; return 2 ;;
        esac
    done
    rm -rf "$directory"
    [ "$readable_seen" = true ] || return 2
    [ "$managed_seen" = true ]
}

rr_restore_run_netfilter_saved_rule() {
    local backend="$1" table="$2" operation="$3" line="$4" position="${5:-}"
    local token=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    while IFS= read -r -d '' token; do
        arguments+=("$token")
    done < <(python3 - "$table" "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" "$line" <<'PY'
import shlex
import sys

table, allow_comment, block_comment, line = sys.argv[1:]
try:
    tokens = shlex.split(line)
except ValueError:
    raise SystemExit("invalid firewall rule syntax")
if len(tokens) < 3 or tokens[0] != "-A":
    raise SystemExit("invalid firewall rule")
try:
    comment = tokens[tokens.index("--comment") + 1]
except (ValueError, IndexError):
    raise SystemExit("firewall rule is not tagged")
if table == "filter":
    valid = tokens[1] == "INPUT" and comment in {allow_comment, block_comment}
elif table == "nat":
    valid = tokens[1] == "PREROUTING" and comment.startswith("argo-rr-")
else:
    valid = False
if not valid:
    raise SystemExit("firewall rule is outside the RR namespace")
for value in tokens:
    sys.stdout.buffer.write(value.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -ge 3 ] && [ "${arguments[0]}" = -A ] || return 1
    case "$operation" in
        -A|-D) arguments[0]="$operation" ;;
        -I)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            arguments=("-I" "${arguments[1]}" "$position" "${arguments[@]:2}")
            ;;
        *) return 1 ;;
    esac
    "$backend" -w 5 -t "$table" "${arguments[@]}" >/dev/null 2>&1
}

rr_restore_run_ufw_saved_rule() {
    local operation="$1" line="$2" position="${3:-}" token=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    while IFS= read -r -d '' token; do
        arguments+=("$token")
    done < <(python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" "$line" <<'PY'
import shlex
import sys

managed_comments = set(sys.argv[1:3])
try:
    tokens = shlex.split(sys.argv[3])
except ValueError:
    raise SystemExit("invalid UFW rule syntax")
if len(tokens) < 4 or tokens[0] != "ufw" or tokens[1] not in {"allow", "deny"}:
    raise SystemExit("invalid UFW rule")
try:
    comment = tokens[tokens.index("comment") + 1]
except (ValueError, IndexError):
    raise SystemExit("UFW rule is not tagged")
if comment not in managed_comments:
    raise SystemExit("UFW rule is outside the RR namespace")
for value in tokens:
    sys.stdout.buffer.write(value.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -ge 4 ] && [ "${arguments[0]}" = ufw ] || return 1
    # UFW reloads all user chains for each add/delete.  Repeat the canonical
    # rebuild proof at the actual writer boundary, including rollback writers.
    rr_ufw_reload_program_is_canonical || return 1
    case "$operation" in
        add) ufw "${arguments[@]:1}" >/dev/null 2>&1 ;;
        delete) ufw delete "${arguments[@]:1}" >/dev/null 2>&1 ;;
        insert)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            ufw insert "$position" "${arguments[@]:1}" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

rr_restore_clear_ufw_rules() {
    local directory="" rules="" unique_rules="" line="" state=0 attempts=0
    if rr_ufw_backend_state; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        1) return 0 ;;
        2) return 1 ;;
    esac

    directory=$(mktemp -d /tmp/rr-firewall-ufw.XXXXXX) || return 1
    rules="$directory/rules"
    unique_rules="$directory/unique"
    while [ "$attempts" -lt 100 ]; do
        rr_restore_capture_ufw_rules "$rules" || { rm -rf "$directory"; return 1; }
        if [ ! -s "$rules" ]; then
            rm -rf "$directory"
            return 0
        fi
        rr_ufw_reload_program_is_canonical || { rm -rf "$directory"; return 1; }
        awk '!seen[$0]++' "$rules" > "$unique_rules" || { rm -rf "$directory"; return 1; }
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            rr_restore_run_ufw_saved_rule delete "$line" || { rm -rf "$directory"; return 1; }
        done < "$unique_rules"
        attempts=$((attempts + 1))
    done
    rm -rf "$directory"
    return 1
}

rr_restore_clear_netfilter_table() {
    local backend="$1" table="$2" directory="" rules="" verify="" line=""
    directory=$(mktemp -d /tmp/rr-firewall-netfilter.XXXXXX) || return 1
    rules="$directory/rules"
    verify="$directory/verify"
    rr_restore_capture_netfilter_rules "$backend" "$table" "$rules" || {
        rm -rf "$directory"
        return 1
    }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        rr_restore_run_netfilter_saved_rule "$backend" "$table" -D "$line" || {
            rm -rf "$directory"
            return 1
        }
    done < "$rules"
    rr_restore_capture_netfilter_rules "$backend" "$table" "$verify" || {
        rm -rf "$directory"
        return 1
    }
    if [ -s "$verify" ]; then
        rm -rf "$directory"
        return 1
    fi
    rm -rf "$directory"
}

rr_restore_clear_managed_firewall() {
    local result=0 snapshot="${1:-}" raw_backend_owned=false raw_state=0
    local started_here=false arm_status=0 finish_status=0 stop_status=0
    rr_firewall_lock_acquire || return 1
    if [ "${RR_RESTORE_FIREWALL_NEEDS_PERSIST:-false}" = true ] || \
       [ -z "$snapshot" ]; then
        raw_backend_owned=true
    elif rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"; then
        raw_backend_owned=true
    else
        raw_state=$?
        if [ "$raw_state" -ne 1 ]; then
            rr_firewall_lock_release || true
            return 1
        fi
    fi
    if [ "$raw_backend_owned" = true ] && \
       ! rr_firewall_persistence_backend_available; then
        printf '%s\n' \
            '防火墙清理涉及 raw/NAT 规则但缺少持久化后端；尚未改写 live 规则。' >&2
        rr_firewall_lock_release || true
        return 1
    fi
    if ! rr_firewall_writer_gate_is_held; then
        if rr_firewall_inflight_begin_locked; then
            started_here=true
        else
            arm_status=$?
            rr_firewall_lock_release || true
            [ "$arm_status" -ge 2 ] && return 2
            return 1
        fi
    fi
    rr_restore_clear_managed_firewall_locked "$@" || result=$?
    if [ "$started_here" = true ]; then
        if [ "$result" -eq 0 ] && [ "$raw_backend_owned" = true ]; then
            save_firewall || result=2
        fi
        if [ "$result" -eq 0 ]; then
            rr_firewall_inflight_finish_locked || finish_status=$?
            [ "$finish_status" -eq 0 ] || result=2
        else
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            result=2
        fi
    fi
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '防火墙清理事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

rr_restore_clear_managed_firewall_locked() {
    local snapshot="${1:-}" backend="" table="" state=0 failed=false
    rr_firewall_lock_is_held || return 1
    if [ -z "$snapshot" ] || [ -f "$snapshot/ufw.enabled" ]; then
        rr_restore_clear_ufw_rules || failed=true
    fi
    for backend in iptables ip6tables; do
        if [ -n "$snapshot" ] && [ ! -f "$snapshot/${backend}.enabled" ]; then
            continue
        fi
        if rr_netfilter_backend_state "$backend"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                for table in filter nat; do
                    rr_restore_clear_netfilter_table "$backend" "$table" || failed=true
                done
                ;;
            1) ;;
            *) failed=true ;;
        esac
    done
    [ "$failed" = false ]
}

rr_restore_normalize_full_firewall_program() {
    local table="$1" backend="$2" source="$3" ufw_rules="$4" target="$5"
    local user_chain=ufw-user-input
    [ "$backend" != ip6tables ] || user_chain=ufw6-user-input
    python3 - "$table" "$source" "$ufw_rules" "$target" "$user_chain" \
        "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" <<'PY'
import re
import shlex
import sys

table, source, ufw_path, target_path, user_chain, allow_comment, block_comment = sys.argv[1:]
if table not in {"filter", "nat"}:
    raise SystemExit(1)
managed_targets = {allow_comment: "ACCEPT", block_comment: "DROP"}
compiled = set()

if ufw_path:
    for raw_line in open(ufw_path, encoding="utf-8"):
        try:
            tokens = shlex.split(raw_line)
        except ValueError:
            raise SystemExit(1)
        if not tokens:
            continue
        if (len(tokens) != 5 or tokens[0] != "ufw"
                or tokens[1] not in {"allow", "deny"} or tokens[3] != "comment"):
            raise SystemExit(1)
        expected_comment = allow_comment if tokens[1] == "allow" else block_comment
        if (tokens[4] != expected_comment
                or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
                or int(tokens[2].split("/", 1)[0]) > 65535):
            raise SystemExit(1)
        port, protocol = tokens[2].split("/", 1)
        verdict = "ACCEPT" if tokens[1] == "allow" else "DROP"
        item = (port, protocol, verdict)
        if item in compiled:
            raise SystemExit(1)
        compiled.add(item)


def option(tokens, *names):
    for index, token in enumerate(tokens):
        if token not in names:
            continue
        if index + 1 >= len(tokens):
            return None, True, False
        return tokens[index + 1], False, index > 0 and tokens[index - 1] == "!"
    return "", False, False


def exact_filter_owned(tokens):
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != "INPUT" or "!" in tokens:
        return False
    comment, bad_comment, negated_comment = option(tokens, "--comment")
    target, bad_target, negated_target = option(tokens, "-j", "--jump")
    protocol, bad_protocol, negated_protocol = option(tokens, "-p", "--protocol")
    port, bad_port, negated_port = option(tokens, "--dport")
    if (bad_comment or negated_comment or bad_target or negated_target
            or bad_protocol or negated_protocol or bad_port or negated_port
            or comment not in managed_targets or target != managed_targets[comment]
            or protocol not in {"tcp", "udp"}
            or re.fullmatch(r"[1-9][0-9]{0,4}", port) is None
            or int(port) > 65535 or tokens.count("--comment") != 1
            or tokens.count("--dport") != 1
            or sum(item in {"-p", "--protocol"} for item in tokens) != 1
            or sum(item in {"-j", "--jump"} for item in tokens) != 1):
        return False
    index = 2
    modules = []
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "--comment", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return False
    return (modules.count("comment") == 1
            and all(item in {"comment", protocol} for item in modules)
            and modules.count(protocol) <= 1 and len(modules) in {1, 2})


def exact_ufw_compiled(tokens):
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != user_chain or "!" in tokens:
        return False
    protocol, bad_protocol, negated_protocol = option(tokens, "-p", "--protocol")
    port, bad_port, negated_port = option(tokens, "--dport")
    verdict, bad_target, negated_target = option(tokens, "-j", "--jump")
    if (bad_protocol or negated_protocol or bad_port or negated_port
            or bad_target or negated_target or (port, protocol, verdict) not in compiled
            or sum(item in {"-p", "--protocol"} for item in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(item in {"-j", "--jump"} for item in tokens) != 1
            or tokens.count("-m") > 1):
        return False
    index = 2
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens) and tokens[index + 1] == protocol:
            index += 2
        else:
            return False
    return True


def exact_nat_owned(tokens):
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != "PREROUTING" or "!" in tokens:
        return False
    protocol, bad_protocol, negated_protocol = option(tokens, "-p", "--protocol")
    spec, bad_spec, negated_spec = option(tokens, "--dport")
    comment, bad_comment, negated_comment = option(tokens, "--comment")
    verdict, bad_target, negated_target = option(tokens, "-j", "--jump")
    to_port, bad_to, negated_to = option(tokens, "--to-ports")
    if (bad_protocol or negated_protocol or bad_spec or negated_spec
            or bad_comment or negated_comment or bad_target or negated_target
            or bad_to or negated_to or protocol != "udp" or verdict != "REDIRECT"
            or re.fullmatch(r"argo-rr-(?:HY2|TU5)", comment or "") is None
            or re.fullmatch(r"[1-9][0-9]{0,4}(?::[1-9][0-9]{0,4})?", spec or "") is None
            or re.fullmatch(r"[1-9][0-9]{0,4}", to_port or "") is None
            or tokens.count("--dport") != 1 or tokens.count("--comment") != 1
            or tokens.count("--to-ports") != 1
            or sum(item in {"-p", "--protocol"} for item in tokens) != 1
            or sum(item in {"-j", "--jump"} for item in tokens) != 1):
        return False
    index = 2
    modules = []
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "--comment",
                     "-j", "--jump", "--to-ports"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return False
    return (modules.count("comment") == 1
            and all(item in {"comment", "udp"} for item in modules)
            and modules.count("udp") <= 1 and len(modules) in {1, 2})


with open(target_path, "w", encoding="utf-8") as output:
    for raw_line in open(source, encoding="utf-8"):
        line = raw_line.rstrip("\n")
        try:
            tokens = shlex.split(line)
        except ValueError:
            raise SystemExit(1)
        if table == "filter" and (exact_filter_owned(tokens) or exact_ufw_compiled(tokens)):
            continue
        if table == "nat" and exact_nat_owned(tokens):
            continue
        print(line, file=output)
PY
}

rr_restore_verify_firewall_snapshot() {
    local rollback="$1" snapshot="$1/firewall" backend="" table=""
    local failed=false current_rules="" current_unmanaged="" current_raw=""
    local current_ufw_rules="" current_normalized=""
    rr_restore_require_firewall_snapshot_v2 "$rollback" || return 1
    rr_restore_firewall_backend_states_match "$snapshot" || return 1
    current_ufw_rules=$(mktemp "$snapshot/.verify-ufw-managed.XXXXXX") || return 1
    : > "$current_ufw_rules" || { rm -f "$current_ufw_rules"; return 1; }

    if [ -f "$snapshot/ufw.enabled" ]; then
        current_rules="$current_ufw_rules"
        current_unmanaged=$(mktemp "$snapshot/.verify-ufw-user.XXXXXX") || {
            rm -f "$current_rules"
            return 1
        }
        if ! rr_restore_capture_ufw_snapshot "$current_rules" "$current_unmanaged"; then
            failed=true
        else
            cmp -s "$snapshot/ufw.rules" "$current_rules" || failed=true
            cmp -s "$snapshot/ufw.unmanaged" "$current_unmanaged" || failed=true
        fi
        rm -f "$current_unmanaged"
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            current_rules=$(mktemp \
                "$snapshot/.verify-${backend}-${table}-rules.XXXXXX") || return 1
            current_unmanaged=$(mktemp \
                "$snapshot/.verify-${backend}-${table}-user.XXXXXX") || {
                rm -f "$current_rules"
                return 1
            }
            current_raw=$(mktemp \
                "$snapshot/.verify-${backend}-${table}-raw.XXXXXX") || {
                rm -f "$current_rules" "$current_unmanaged"
                return 1
            }
            current_normalized=$(mktemp \
                "$snapshot/.verify-${backend}-${table}-normalized.XXXXXX") || {
                rm -f "$current_rules" "$current_unmanaged" "$current_raw" \
                    "$current_ufw_rules"
                return 1
            }
            if ! rr_restore_capture_netfilter_snapshot "$backend" "$table" \
                "$current_rules" "$current_unmanaged" "$current_raw"; then
                failed=true
            else
                cmp -s "$snapshot/${backend}.${table}.rules" \
                    "$current_rules" || failed=true
                cmp -s "$snapshot/${backend}.${table}.unmanaged" \
                    "$current_unmanaged" || failed=true
                rr_restore_normalize_full_firewall_program "$table" "$backend" \
                    "$current_raw" "$current_ufw_rules" "$current_normalized" || \
                    failed=true
                cmp -s "$snapshot/${backend}.${table}.unmanaged.raw" \
                    "$current_normalized" || failed=true
            fi
            rm -f "$current_rules" "$current_unmanaged" "$current_raw" \
                "$current_normalized"
        done
    done
    rm -f "$current_ufw_rules"
    [ "$failed" = false ]
}

rr_restore_verify_ufw_program_exact() {
    local snapshot="$1" current=""
    [ -f "$snapshot/ufw.enabled" ] || return 0
    [ -f "$snapshot/ufw.program" ] && [ ! -L "$snapshot/ufw.program" ] || return 1
    current=$(mktemp "$snapshot/.verify-ufw-program.XXXXXX") || return 1
    if ! LC_ALL=C ufw show added > "$current" 2>/dev/null || \
       ! cmp -s "$snapshot/ufw.program" "$current"; then
        rm -f "$current"
        return 1
    fi
    rm -f "$current"
    rr_ufw_reload_program_is_canonical || return 1
}

rr_restore_verify_firewall_pre_mutation_snapshot() {
    local rollback="$1" snapshot="$1/firewall" backend="" table="" current=""
    rr_restore_verify_firewall_snapshot "$rollback" || return 1
    # The ordinary verifier compares RR rules and the same-chain unmanaged
    # anchors needed for rollback.  Immediately before candidate writes, also
    # require the complete live filter/NAT programs to match the durable raw
    # evidence.  This covers UFW before/user chains and custom NAT chains that
    # `show added` or an INPUT/PREROUTING-only projection cannot see.
    if [ -f "$snapshot/ufw.enabled" ]; then
        [ -f "$snapshot/ufw.status" ] && [ ! -L "$snapshot/ufw.status" ] || return 1
        current=$(mktemp "$snapshot/.prewrite-ufw-status.XXXXXX") || return 1
        if ! LC_ALL=C ufw status > "$current" 2>/dev/null || \
           ! cmp -s "$snapshot/ufw.status" "$current"; then
            rm -f "$current"
            printf '%s\n' \
                '目标 UFW 状态或启用族在快照后发生变化；便携恢复已在首次规则写入前拒绝。' >&2
            return 1
        fi
        rm -f "$current"
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            [ -f "$snapshot/${backend}.${table}.raw" ] && \
                [ ! -L "$snapshot/${backend}.${table}.raw" ] || return 1
            current=$(mktemp \
                "$snapshot/.prewrite-${backend}-${table}.XXXXXX") || return 1
            if ! "$backend" -w 5 -t "$table" -S > "$current" 2>/dev/null || \
               ! cmp -s "$snapshot/${backend}.${table}.raw" "$current"; then
                rm -f "$current"
                printf '%s\n' \
                    '目标防火墙在快照后发生变化；便携恢复已在首次规则写入前拒绝。' >&2
                return 1
            fi
            rm -f "$current"
        done
    done
}

rr_restore_restore_firewall_snapshot() {
    local result=0 raw_required=false raw_state=0 snapshot="$1/firewall"
    local started_here=false arm_status=0 finish_status=0 stop_status=0
    rr_firewall_lock_acquire || return 1
    if rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"; then
        raw_required=true
    else
        raw_state=$?
        [ "$raw_state" -eq 1 ] || {
            rr_firewall_lock_release || true
            return 1
        }
    fi
    if rr_restore_live_has_managed_raw_rules; then
        raw_required=true
    else
        raw_state=$?
    fi
    case "$raw_state" in
        0|1) ;;
        *) rr_firewall_lock_release || true; return 1 ;;
    esac
    if [ "$raw_required" = true ] && \
       ! rr_firewall_persistence_backend_available; then
        printf '%s\n' \
            '防火墙回滚需要 netfilter 持久化后端；尚未改写 live 规则。' >&2
        rr_firewall_lock_release || true
        return 1
    fi
    if ! rr_firewall_writer_gate_is_held; then
        if rr_firewall_inflight_begin_locked; then
            started_here=true
        else
            arm_status=$?
            rr_firewall_lock_release || true
            [ "$arm_status" -ge 2 ] && return 2
            return 1
        fi
    fi
    RR_RESTORE_FIREWALL_NEEDS_PERSIST="$raw_required" \
        rr_restore_restore_firewall_snapshot_locked "$@" || result=$?
    if [ "$started_here" = true ]; then
        if [ "$result" -eq 0 ]; then
            rr_firewall_inflight_finish_locked || finish_status=$?
            [ "$finish_status" -eq 0 ] || result=2
        else
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            result=2
        fi
    fi
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '防火墙快照恢复事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

rr_restore_restore_firewall_snapshot_locked() {
    local rollback="$1" snapshot="$1/firewall" backend="" table="" line=""
    local state=0 failed=false position="" rule=""
    local current_rules="" current_unmanaged="" current_ufw_rules=""
    local current_raw="" current_normalized=""
    # Every released portable-restore transaction contained firewall evidence.
    # Missing/incomplete evidence is corruption, not a legacy compatibility
    # state; fail closed before touching either the candidate or user rules.
    rr_restore_require_firewall_snapshot_v2 "$rollback" || return 1

    # A backend that appeared after the snapshot may belong to a concurrent
    # administrator action.  Require the exact active/absent state before any
    # rule mutation and clear only backends that the v2 snapshot owned.
    rr_restore_firewall_backend_states_match "$snapshot" || return 1

    # A numeric rule position is meaningful only while every non-RR rule in
    # the same evaluation chain is unchanged.  Check all such anchors before
    # deleting a candidate rule; a concurrent administrator change is kept
    # intact and leaves the recovery transaction fail-closed for inspection.
    current_ufw_rules=$(mktemp "$snapshot/.preflight-ufw-managed.XXXXXX") || return 1
    : > "$current_ufw_rules" || { rm -f "$current_ufw_rules"; return 1; }
    if [ -f "$snapshot/ufw.enabled" ]; then
        if rr_ufw_backend_state; then state=0; else state=$?; fi
        [ "$state" -eq 0 ] || { rm -f "$current_ufw_rules"; return 1; }
        current_rules="$current_ufw_rules"
        current_unmanaged=$(mktemp "$snapshot/.preflight-ufw-user.XXXXXX") || {
            rm -f "$current_ufw_rules"
            return 1
        }
        if ! rr_restore_capture_ufw_snapshot "$current_rules" "$current_unmanaged" || \
           ! cmp -s "$snapshot/ufw.unmanaged" "$current_unmanaged"; then
            rm -f "$current_ufw_rules" "$current_unmanaged"
            return 1
        fi
        rm -f "$current_unmanaged"
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        [ "$state" -eq 0 ] || { rm -f "$current_ufw_rules"; return 1; }
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            [ -f "$snapshot/${backend}.${table}.unmanaged.raw" ] && \
                [ ! -L "$snapshot/${backend}.${table}.unmanaged.raw" ] || {
                rm -f "$current_ufw_rules"
                return 1
            }
            current_rules=$(mktemp \
                "$snapshot/.preflight-${backend}-${table}-rules.XXXXXX") || {
                rm -f "$current_ufw_rules"
                return 1
            }
            current_unmanaged=$(mktemp \
                "$snapshot/.preflight-${backend}-${table}-user.XXXXXX") || {
                rm -f "$current_ufw_rules" "$current_rules"
                return 1
            }
            current_raw=$(mktemp \
                "$snapshot/.preflight-${backend}-${table}-raw.XXXXXX") || {
                rm -f "$current_ufw_rules" "$current_rules" "$current_unmanaged"
                return 1
            }
            current_normalized=$(mktemp \
                "$snapshot/.preflight-${backend}-${table}-normalized.XXXXXX") || {
                rm -f "$current_ufw_rules" "$current_rules" "$current_unmanaged" \
                    "$current_raw"
                return 1
            }
            if ! rr_restore_capture_netfilter_snapshot "$backend" "$table" \
                "$current_rules" "$current_unmanaged" "$current_raw" || \
               ! cmp -s "$snapshot/${backend}.${table}.unmanaged" \
                "$current_unmanaged" || \
               ! rr_restore_normalize_full_firewall_program "$table" "$backend" \
                "$current_raw" "$current_ufw_rules" "$current_normalized" || \
               ! cmp -s "$snapshot/${backend}.${table}.unmanaged.raw" \
                "$current_normalized"; then
                rm -f "$current_ufw_rules" "$current_rules" "$current_unmanaged" \
                    "$current_raw" "$current_normalized"
                return 1
            fi
            rm -f "$current_rules" "$current_unmanaged" "$current_raw" \
                "$current_normalized"
        done
    done
    rm -f "$current_ufw_rules"

    rr_restore_clear_managed_firewall "$snapshot" || return 1
    if [ -f "$snapshot/ufw.enabled" ]; then
        while IFS=$'\t' read -r position line; do
            [ -n "$position" ] && [ -n "$line" ] || { failed=true; continue; }
            rr_restore_run_ufw_saved_rule insert "$line" "$position" || failed=true
        done < "$snapshot/ufw.ordered"
    fi

    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        if [ "$state" -ne 0 ]; then
            failed=true
            continue
        fi
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                IFS=$'\t' read -r position rule <<< "$line"
                if [[ ! "$position" =~ ^[1-9][0-9]*$ ]] || [ -z "$rule" ]; then
                    failed=true
                    continue
                fi
                rr_restore_run_netfilter_saved_rule "$backend" "$table" \
                    -I "$rule" "$position" || failed=true
            done < "$snapshot/${backend}.${table}.rules"
        done
    done

    rr_restore_verify_firewall_snapshot "$rollback" || failed=true
    rr_restore_verify_ufw_program_exact "$snapshot" || failed=true
    if [ "${RR_RESTORE_FIREWALL_NEEDS_PERSIST:-false}" = true ] && \
       ! save_firewall; then
        failed=true
    fi
    [ "$failed" = false ]
}

rr_restore_nexus_gate_script_is_exact() {
    local script="${1:-}"
    declare -F nexus_ip_certificate_gate_script_is_current >/dev/null 2>&1 || \
        return 1
    nexus_ip_certificate_gate_script_is_current "$script"
}

rr_restore_nexus_gate_pair_state() {
    local script="${1:-$RR_RESTORE_NEXUS_GATE_EXEC_PATH}"
    local dropin="${2:-${RR_RESTORE_SYSTEMD_DIR}/nginx.service.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}}"
    local script_present=false dropin_present=false
    if [ -e "$script" ] || [ -L "$script" ]; then
        rr_restore_nexus_gate_script_is_exact "$script" || return 1
        script_present=true
    fi
    if [ -e "$dropin" ] || [ -L "$dropin" ]; then
        rr_restore_nexus_gate_dropin_file_is_exact "$dropin" || return 1
        dropin_present=true
    fi
    [ "$script_present" = "$dropin_present" ] || return 1
    [ "$script_present" = true ] && printf '%s\n' present || printf '%s\n' absent
}

rr_restore_nexus_gate_snapshot_state() {
    local rollback="${1:-}" marker="" state=""
    local -a lines=()
    marker="$rollback/$RR_RESTORE_NEXUS_GATE_SNAPSHOT_NAME"
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 2 ] || return 1
    [ "${lines[0]}" = "format=$RR_RESTORE_NEXUS_GATE_SNAPSHOT_FORMAT" ] || \
        return 1
    state="${lines[1]#state=}"
    [ "${lines[1]}" = "state=$state" ] || return 1
    case "$state" in present|absent) printf '%s\n' "$state" ;; *) return 1 ;; esac
}

rr_restore_nexus_gate_parent_is_safe() {
    local parent="${1:-}" canonical="" mode="" mode_value=0
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    canonical=$(readlink -f -- "$parent" 2>/dev/null) || return 1
    [ "$canonical" = "$parent" ] || return 1
    [ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c %a -- "$parent" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 07022) == 0 ))
}

rr_restore_capture_nexus_gate_artifacts() {
    local rollback="${1:-}"
    local script="${2:-$RR_RESTORE_NEXUS_GATE_EXEC_PATH}"
    local dropin="${3:-${RR_RESTORE_SYSTEMD_DIR}/nginx.service.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}}"
    local snapshot_script="$rollback/rootfs$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
    local snapshot_dropin="$rollback/rootfs/etc/systemd/system/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
    local marker="$rollback/$RR_RESTORE_NEXUS_GATE_SNAPSHOT_NAME"
    local temporary="" state=""
    [ -d "$rollback/rootfs" ] && [ ! -L "$rollback/rootfs" ] || return 1
    state=$(rr_restore_nexus_gate_pair_state "$script" "$dropin") || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    if [ "$state" = present ]; then
        mkdir -p "$(dirname -- "$snapshot_script")" \
            "$(dirname -- "$snapshot_dropin")" || return 1
        install -m 755 -- "$script" "$snapshot_script" || return 1
        install -m 644 -- "$dropin" "$snapshot_dropin" || return 1
        rr_restore_nexus_gate_script_is_exact "$snapshot_script" && \
            rr_restore_nexus_gate_dropin_file_is_exact "$snapshot_dropin" && \
            cmp -s -- "$script" "$snapshot_script" && \
            cmp -s -- "$dropin" "$snapshot_dropin" || return 1
    else
        [ ! -e "$snapshot_script" ] && [ ! -L "$snapshot_script" ] && \
            [ ! -e "$snapshot_dropin" ] && [ ! -L "$snapshot_dropin" ] || \
            return 1
    fi
    temporary=$(mktemp "$rollback/.nexus-ip-cert-gate-state.XXXXXX") || return 1
    if ! printf 'format=%s\nstate=%s\n' \
            "$RR_RESTORE_NEXUS_GATE_SNAPSHOT_FORMAT" "$state" > "$temporary" || \
       ! chmod 600 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$marker" || ! sync -f "$rollback"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || rm -f -- "$temporary"
        return 1
    fi
    [ "$(rr_restore_nexus_gate_snapshot_state "$rollback")" = "$state" ]
}

rr_restore_replay_nexus_gate_artifacts() {
    local rollback="${1:-}" destination_root="${2:-/}"
    local marker="$rollback/$RR_RESTORE_NEXUS_GATE_SNAPSHOT_NAME"
    local snapshot_script="$rollback/rootfs$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
    local snapshot_dropin="$rollback/rootfs/etc/systemd/system/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
    local script="" dropin="" script_dir="" dropin_dir="" state=""
    local script_tmp="" dropin_tmp=""
    # Rollback directories created before this fixed-path snapshot format did
    # not mutate these artifacts.  Preserve their previous replay contract.
    [ -e "$marker" ] || [ -L "$marker" ] || return 0
    case "$destination_root" in /*) ;; *) return 1 ;; esac
    [ -d "$destination_root" ] && [ ! -L "$destination_root" ] || return 1
    destination_root="${destination_root%/}"
    script="${destination_root}${RR_RESTORE_NEXUS_GATE_EXEC_PATH}"
    dropin="${destination_root}/etc/systemd/system/nginx.service.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}"
    script_dir=$(dirname -- "$script") || return 1
    dropin_dir=$(dirname -- "$dropin") || return 1
    state=$(rr_restore_nexus_gate_snapshot_state "$rollback") || return 1

    if [ "$state" = present ]; then
        rr_restore_nexus_gate_script_is_exact "$snapshot_script" && \
            rr_restore_nexus_gate_dropin_file_is_exact "$snapshot_dropin" || \
            return 1
    else
        [ ! -e "$snapshot_script" ] && [ ! -L "$snapshot_script" ] && \
            [ ! -e "$snapshot_dropin" ] && [ ! -L "$snapshot_dropin" ] || \
            return 1
    fi

    # Preflight every live artifact before the first unlink/replace.  A
    # candidate cannot turn rollback into an overwrite primitive for an
    # administrator-owned path.
    if [ -e "$script" ] || [ -L "$script" ]; then
        rr_restore_nexus_gate_script_is_exact "$script" || return 1
    fi
    if [ -e "$dropin" ] || [ -L "$dropin" ]; then
        rr_restore_nexus_gate_dropin_file_is_exact "$dropin" || return 1
    fi

    if [ "$state" = absent ]; then
        if [ -e "$dropin" ] || [ -L "$dropin" ]; then
            rr_restore_nexus_gate_parent_is_safe "$dropin_dir" || return 1
            unlink "$dropin" 2>/dev/null || return 1
            sync -f "$dropin_dir" || return 1
        fi
        if [ -e "$script" ] || [ -L "$script" ]; then
            rr_restore_nexus_gate_parent_is_safe "$script_dir" || return 1
            unlink "$script" 2>/dev/null || return 1
            sync -f "$script_dir" || return 1
        fi
        [ ! -e "$script" ] && [ ! -L "$script" ] && \
            [ ! -e "$dropin" ] && [ ! -L "$dropin" ]
        return $?
    fi

    install -d -m 755 "$script_dir" "$dropin_dir" || return 1
    rr_restore_nexus_gate_parent_is_safe "$script_dir" && \
        rr_restore_nexus_gate_parent_is_safe "$dropin_dir" || return 1
    script_tmp=$(mktemp "$script_dir/.rr-nexus-ip-cert-gate.XXXXXX") || return 1
    dropin_tmp=$(mktemp "$dropin_dir/.rr-nexus-ip-cert-gate.XXXXXX") || {
        rm -f -- "$script_tmp"
        return 1
    }
    if ! install -m 755 -- "$snapshot_script" "$script_tmp" || \
       ! install -m 644 -- "$snapshot_dropin" "$dropin_tmp" || \
       ! sync -f "$script_tmp" || ! sync -f "$dropin_tmp" || \
       ! mv -f -- "$script_tmp" "$script" || ! sync -f "$script_dir" || \
       ! mv -f -- "$dropin_tmp" "$dropin" || ! sync -f "$dropin_dir"; then
        [ -e "$script_tmp" ] || [ -L "$script_tmp" ] || script_tmp=""
        [ -e "$dropin_tmp" ] || [ -L "$dropin_tmp" ] || dropin_tmp=""
        [ -z "$script_tmp" ] || rm -f -- "$script_tmp"
        [ -z "$dropin_tmp" ] || rm -f -- "$dropin_tmp"
        return 1
    fi
    rr_restore_nexus_gate_script_is_exact "$script" && \
        rr_restore_nexus_gate_dropin_file_is_exact "$dropin" && \
        cmp -s -- "$snapshot_script" "$script" && \
        cmp -s -- "$snapshot_dropin" "$dropin"
}

rr_restore_nginx_snapshot_paths_are_owned() {
    local rollback="${1:-}" state=legacy address="" path=""
    local available="$rollback/nginx/sites-available"
    local enabled="$rollback/nginx/sites-enabled"
    local live_site="${NEXUS_NGINX_SITE:-/etc/nginx/sites-available/rr-nexus.conf}"
    local challenge_site="$available/rr-nexus-ip-acme-http.conf"
    local challenge_link="$enabled/rr-nexus-ip-acme-http.conf"
    local snapshot_link="" expected_target=""
    local -a entries=()
    declare -F nexus_nginx_managed_directory_is_safe >/dev/null 2>&1 && \
        declare -F nexus_nginx_domain_http_site_is_supported >/dev/null 2>&1 && \
        declare -F nexus_nginx_domain_custom_site_is_supported >/dev/null 2>&1 && \
        declare -F nexus_nginx_ip_site_is_supported >/dev/null 2>&1 && \
        declare -F nexus_nginx_enabled_link_is_exact >/dev/null 2>&1 && \
        declare -F nexus_nginx_regular_site_metadata_is_exact >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_emit_nginx_http_site >/dev/null 2>&1 || return 1
    [ -d "$rollback" ] && [ ! -L "$rollback" ] && \
        [ "$(readlink -f -- "$rollback" 2>/dev/null)" = "$rollback" ] || return 1
    NEXUS_NGINX_TRUST_ROOT="$rollback" \
        nexus_nginx_managed_directory_is_safe "$available" && \
        NEXUS_NGINX_TRUST_ROOT="$rollback" \
            nexus_nginx_managed_directory_is_safe "$enabled" || return 1

    mapfile -d '' -t entries < <(
        find "$available" "$enabled" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
    ) || return 1
    for path in "${entries[@]}"; do
        case "$path" in
            "$available/rr-nexus.conf"|"$available/rr-nexus.conf.port"|\
            "$available/rr-nexus-ip.conf"|"$challenge_site"|\
            "$enabled/rr-nexus.conf"|"$enabled/rr-nexus-port.conf"|\
            "$enabled/rr-nexus-ip.conf"|"$challenge_link") ;;
            *) return 1 ;;
        esac
    done

    path="$available/rr-nexus.conf"
    if [ -e "$path" ] || [ -L "$path" ]; then
        NEXUS_NGINX_TRUST_ROOT="$rollback" \
            nexus_nginx_domain_http_site_is_supported "$path" || return 1
    fi
    path="$available/rr-nexus.conf.port"
    if [ -e "$path" ] || [ -L "$path" ]; then
        NEXUS_NGINX_TRUST_ROOT="$rollback" \
            nexus_nginx_domain_custom_site_is_supported "$path" || return 1
    fi
    path="$available/rr-nexus-ip.conf"
    if [ -e "$path" ] || [ -L "$path" ]; then
        NEXUS_NGINX_TRUST_ROOT="$rollback" \
            nexus_nginx_ip_site_is_supported "$path" || return 1
    fi
    for path in \
        "$enabled/rr-nexus.conf:$live_site" \
        "$enabled/rr-nexus-port.conf:${live_site}.port" \
        "$enabled/rr-nexus-ip.conf:/etc/nginx/sites-available/rr-nexus-ip.conf"; do
        snapshot_link="${path%%:*}"
        expected_target="${path#*:}"
        if [ -e "$snapshot_link" ] || [ -L "$snapshot_link" ]; then
            NEXUS_NGINX_TRUST_ROOT="$rollback" \
                nexus_nginx_enabled_link_is_exact \
                    "$snapshot_link" "$expected_target" || return 1
        fi
    done

    if [ -e "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ] || \
       [ -L "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ]; then
        state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
        if [ "$state" = ready ]; then
            address=$(sed -n 's/^address=//p' \
                "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME") || return 1
            [ -f "$challenge_site" ] && [ ! -L "$challenge_site" ] && \
                [ -L "$challenge_link" ] || return 1
            NEXUS_NGINX_TRUST_ROOT="$rollback" \
                nexus_nginx_regular_site_metadata_is_exact "$challenge_site" && \
                cmp -s -- "$challenge_site" \
                    <(nexus_ip_acme_emit_nginx_http_site "$address") && \
                NEXUS_NGINX_TRUST_ROOT="$rollback" \
                    nexus_nginx_enabled_link_is_exact "$challenge_link" \
                        /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf || \
                return 1
        fi
    fi
    if [ "$state" != ready ]; then
        [ ! -e "$challenge_site" ] && [ ! -L "$challenge_site" ] && \
            [ ! -e "$challenge_link" ] && [ ! -L "$challenge_link" ] || return 1
    fi
}

rr_restore_nginx_live_paths_are_owned() {
    local state="${1:-legacy}" address="${2:-}"
    nexus_nginx_managed_paths_are_owned || return 1
    if [ "$state" = ready ]; then
        nexus_ip_acme_nginx_http_site_removal_is_safe "$address"
    else
        [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ]
    fi
}

rr_restore_prepare_nginx_snapshot_destinations() {
    local available="${1:-/etc/nginx/sites-available}"
    local enabled="${2:-/etc/nginx/sites-enabled}"
    local directory="" parent=""
    declare -F nexus_nginx_managed_directory_is_safe >/dev/null 2>&1 || return 1
    for directory in "$available" "$enabled"; do
        if [ -e "$directory" ] || [ -L "$directory" ]; then
            nexus_nginx_managed_directory_is_safe "$directory" || return 1
            continue
        fi
        parent=$(dirname -- "$directory") || return 1
        nexus_nginx_managed_directory_is_safe "$parent" || return 1
        mkdir -m 755 -- "$directory" || return 1
        sync -f "$parent" || return 1
        nexus_nginx_managed_directory_is_safe "$directory" || return 1
    done
}

rr_restore_snapshot_nginx() {
    local rollback="$1" source="" was_running=false was_enabled=false
    local ip_state=legacy ip_address=""
    declare -F nexus_nginx_managed_paths_are_owned >/dev/null 2>&1 && \
        declare -F nexus_nginx_managed_path_is_owned >/dev/null 2>&1 || return 1
    nexus_nginx_managed_paths_are_owned || return 1
    if [ -e "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ] || \
       [ -L "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ]; then
        ip_state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
        if [ "$ip_state" = ready ]; then
            ip_address=$(sed -n 's/^address=//p' \
                "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME") || return 1
            nexus_ip_acme_nginx_http_site_is_current "$ip_address" || return 1
        else
            [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
                [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
                [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
                [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] || return 1
        fi
    else
        [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] || return 1
    fi
    mkdir -p "$rollback/nginx/sites-available" "$rollback/nginx/sites-enabled" || return 1
    for source in \
        /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf \
        /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf; do
        [ -e "$source" ] || continue
        if [ "$source" = /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ]; then
            [ "$ip_state" = ready ] && \
                nexus_ip_acme_nginx_http_site_is_current "$ip_address" || return 1
        else
            nexus_nginx_managed_path_is_owned "$source" || return 1
        fi
        cp -a -- "$source" "$rollback/nginx/sites-available/" || return 1
    done
    for source in \
        /etc/nginx/sites-enabled/rr-nexus.conf \
        /etc/nginx/sites-enabled/rr-nexus-port.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf; do
        [ -e "$source" ] || [ -L "$source" ] || continue
        if [ "$source" = /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ]; then
            [ "$ip_state" = ready ] && \
                nexus_ip_acme_nginx_http_site_is_current "$ip_address" || return 1
        else
            nexus_nginx_managed_path_is_owned "$source" || return 1
        fi
        cp -a -- "$source" "$rollback/nginx/sites-enabled/" || return 1
    done
    rr_restore_nginx_snapshot_paths_are_owned "$rollback" || return 1
    rr_restore_capture_unit_activity_state nginx was_running || return 1
    rr_restore_capture_unit_file_state nginx was_enabled || return 1
    if [ "$was_running" = true ]; then
        : > "$rollback/nginx_was_running" || return 1
    fi
    if [ "$was_enabled" = true ]; then
        : > "$rollback/nginx_was_enabled" || return 1
    fi
    return 0
}

rr_restore_capture_target_network() {
    local rollback="$1"
    local target_entry_mode=auto target_outbound_mode=auto
    local target_entry_v4="" target_entry_v6="" target_sub_v4="" target_sub_v6=""
    local target_sub_port="" target_sub_access_mode=local target_sub_domain=""
    if [ -r "$CONFIG_FILE" ]; then
        : > "$rollback/target_rr_was_present" || return 1
        load_config_with_defaults || return 1
        target_entry_mode="${ENTRY_IP_MODE:-auto}"
        target_outbound_mode="${OUTBOUND_IP_MODE:-auto}"
        target_entry_v4="${ENTRY_IPV4_ADDRESS:-}"
        target_entry_v6="${ENTRY_IPV6_ADDRESS:-}"
        target_sub_port="${SUB_PORT:-}"
        target_sub_access_mode="${SUB_ACCESS_MODE:-local}"
        target_sub_domain="${SUB_DOMAIN:-}"
        target_sub_v4="${SUB_PUBLIC_PORT_IPV4:-${SUB_PORT:-}}"
        target_sub_v6="${SUB_PUBLIC_PORT_IPV6:-${SUB_PORT:-}}"
    fi
    {
        printf 'TARGET_ENTRY_IP_MODE=%q\n' "$target_entry_mode"
        printf 'TARGET_OUTBOUND_IP_MODE=%q\n' "$target_outbound_mode"
        printf 'TARGET_ENTRY_IPV4_ADDRESS=%q\n' "$target_entry_v4"
        printf 'TARGET_ENTRY_IPV6_ADDRESS=%q\n' "$target_entry_v6"
        printf 'TARGET_SUB_PORT=%q\n' "$target_sub_port"
        printf 'TARGET_SUB_ACCESS_MODE=%q\n' "$target_sub_access_mode"
        printf 'TARGET_SUB_DOMAIN=%q\n' "$target_sub_domain"
        printf 'TARGET_SUB_PUBLIC_PORT_IPV4=%q\n' "$target_sub_v4"
        printf 'TARGET_SUB_PUBLIC_PORT_IPV6=%q\n' "$target_sub_v6"
    } > "$rollback/target-network" || return 1
    chmod 600 "$rollback/target-network"
}

rr_restore_capture_target_nexus_state() {
    local rollback="$1" access_tmp="" was_enabled=false
    mkdir -p "$rollback" || return 1
    access_tmp="$rollback/.target-nexus-access.$$"
    if [ -e "$NEXUS_CONFIG_FILE" ] || [ -L "$NEXUS_CONFIG_FILE" ]; then
        [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || return 1
        jq -e '
            type == "object" and
            (.mode == "local" or .mode == "public") and
            ((.domain | type) == "string") and
            ((.public_port | type) == "number") and
            (.public_port == (.public_port | floor)) and
            (.public_port >= 1 and .public_port <= 65535) and
            ((has("acme_email") | not) or ((.acme_email | type) == "string")) and
            ((has("certificate_mode") | not) or
             ((.certificate_mode | type) == "string"))
        ' "$NEXUS_CONFIG_FILE" >/dev/null || return 1
        jq '{mode,domain,public_port} +
            (if has("acme_email") then {acme_email:.acme_email} else {} end) +
            (if has("certificate_mode") then
                {certificate_mode:.certificate_mode}
             else {} end)' \
            "$NEXUS_CONFIG_FILE" > "$access_tmp" || { rm -f "$access_tmp"; return 1; }
        : > "$rollback/target_nexus_was_present" || { rm -f "$access_tmp"; return 1; }
    else
        jq -cn '{mode:"local",domain:"",public_port:7900}' > "$access_tmp" || return 1
    fi
    chmod 600 "$access_tmp" && mv -f "$access_tmp" "$rollback/target-nexus-access.json" || {
        rm -f "$access_tmp"
        return 1
    }
    rr_restore_capture_unit_file_state rr-nexus was_enabled || return 1
    if [ "$was_enabled" = true ]; then
        : > "$rollback/nexus_was_enabled" || return 1
    fi
    return 0
}

rr_restore_apply_target_nexus_state() {
    local rollback="$1" payload="$2"
    local source_config="$payload/rootfs/etc/rr-nexus/nexus.json"
    local target_snapshot="$rollback/rootfs/etc/rr-nexus/nexus.json"
    local access="$rollback/target-nexus-access.json"
    local target_dir="" temporary="" cert_name="" cert_mode=""
    target_dir=$(dirname "$NEXUS_CONFIG_FILE") || return 1

    [ -f "$access" ] && [ ! -L "$access" ] || return 1
    if [ -f "$rollback/target_nexus_was_present" ]; then
        # If the imported machine did not have Nexus, retaining the target
        # config still preserves the destination access plane while the
        # restored database is initialized empty.
        [ -f "$source_config" ] || source_config="$target_snapshot"
    elif [ ! -e "$source_config" ] && [ ! -L "$source_config" ]; then
        return 0
    fi
    [ -f "$source_config" ] && [ ! -L "$source_config" ] || return 1

    install -d -m 700 "$target_dir" || return 1
    # IP-mode TLS material belongs to the destination access plane too.  Only
    # restore the two known local snapshot files; source certificates are
    # intentionally ignored.
    if [ -f "$rollback/target_nexus_was_present" ]; then
        for cert_name in ip.crt ip.key .ip-cert-pending; do
            [ -e "$rollback/rootfs/etc/rr-nexus/certs/$cert_name" ] || continue
            [ -f "$rollback/rootfs/etc/rr-nexus/certs/$cert_name" ] && \
                [ ! -L "$rollback/rootfs/etc/rr-nexus/certs/$cert_name" ] || return 1
            install -d -m 700 "$target_dir/certs" || return 1
            cert_mode=600
            [ "$cert_name" = ip.crt ] && cert_mode=644
            install -m "$cert_mode" "$rollback/rootfs/etc/rr-nexus/certs/$cert_name" \
                "$target_dir/certs/$cert_name" || return 1
        done
    fi

    temporary=$(mktemp "$target_dir/.nexus.json.XXXXXX") || return 1
    if ! jq --slurpfile access "$access" '
        ($access[0]) as $target |
        .mode=$target.mode |
        .domain=$target.domain |
        .public_port=$target.public_port |
        if ($target | has("acme_email")) then
            .acme_email=$target.acme_email
        else
            del(.acme_email)
        end |
        if ($target | has("certificate_mode")) then
            .certificate_mode=$target.certificate_mode
        else
            del(.certificate_mode)
        end
    ' "$source_config" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod 600 "$temporary" && mv -f "$temporary" "$NEXUS_CONFIG_FILE" || {
        rm -f "$temporary"
        return 1
    }
}

rr_restore_ip_acme_snapshot_state() {
    local rollback="${1:-}" marker="" state="" address=""
    local -a lines=()
    marker="$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME"
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 3 ] || return 1
    [ "${lines[0]}" = "format=$RR_RESTORE_IP_ACME_SNAPSHOT_FORMAT" ] || return 1
    state="${lines[1]#state=}"
    address="${lines[2]#address=}"
    [ "${lines[1]}" = "state=$state" ] && \
        [ "${lines[2]}" = "address=$address" ] || return 1
    case "$state" in
        absent) [ -z "$address" ] || return 1 ;;
        ready)
            [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] && \
                [ "${#address}" -le 64 ] || return 1
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$state"
}

rr_restore_ip_acme_runtime_readonly_is_ready() {
    local address="${1:-}"
    # Module 86's readiness contract is deliberately read-only: it proves the
    # owner trees, fingerprints, absence of recovery temporaries, exact gate,
    # effective units and quiescent/armed states without prepare/install,
    # daemon-reload, cleanup or service mutations. Keep target capture on that
    # canonical proof so renderer changes cannot split the two contracts.
    declare -F nexus_ip_acme_runtime_is_ready >/dev/null 2>&1 || return 1
    nexus_ip_acme_runtime_is_ready "$address"
}

rr_restore_legacy_ip_access_plane_is_exact() {
    local access="${1:-}" mode="" access_mode="" address=""
    local cert="${NEXUS_IP_ACME_LIVE_CERT:-/etc/rr-nexus/certs/ip.crt}"
    local key="${NEXUS_IP_ACME_LIVE_KEY:-/etc/rr-nexus/certs/ip.key}"
    local pending="${NEXUS_IP_ACME_PENDING:-/etc/rr-nexus/certs/.ip-cert-pending}"
    local script="$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
    local dropin="${RR_RESTORE_SYSTEMD_DIR}/nginx.service.d/${RR_RESTORE_NEXUS_GATE_DROPIN_NAME}"
    local cert_present=false key_present=false script_present=false
    local dropin_present=false
    [ -f "$access" ] && [ ! -L "$access" ] || return 1
    mode=$(jq -r '.certificate_mode // empty' "$access" 2>/dev/null) || return 1
    access_mode=$(jq -r '.mode // empty' "$access" 2>/dev/null) || return 1
    address=$(jq -r '.domain // empty' "$access" 2>/dev/null) || return 1
    [ ! -L "$cert" ] && [ ! -L "$key" ] || return 1
    [ -e "$cert" ] && cert_present=true
    [ -e "$key" ] && key_present=true
    [ "$cert_present" = "$key_present" ] || return 1
    [ ! -e "$script" ] && [ ! -L "$script" ] || script_present=true
    [ ! -e "$dropin" ] && [ ! -L "$dropin" ] || dropin_present=true
    [ "$script_present" = "$dropin_present" ] || return 1
    if [ "$cert_present" = false ]; then
        [ "$script_present" = false ] && [ "$mode" != legacy-self-signed ] || \
            return 1
        if [ "$access_mode" = public ]; then
            declare -F is_ip_version >/dev/null 2>&1 || return 1
            is_ip_version "$address" 4 || is_ip_version "$address" 6 || return 0
            return 1
        fi
        return 0
    fi
    [ -n "$mode" ] || mode=legacy-self-signed
    [ "$mode" = legacy-self-signed ] && [ -n "$address" ] || return 1
    declare -F nexus_ip_certificate_pair_is_ready >/dev/null 2>&1 || return 1
    nexus_ip_certificate_pair_is_ready "$cert" "$key" "$address" || return 1
    [ "$script_present" = true ] || return 0
    declare -F nexus_ip_certificate_gate_artifacts_are_current >/dev/null 2>&1 && \
        declare -F nexus_nginx_exec_condition_set_is_exact >/dev/null 2>&1 || \
        return 1
    nexus_ip_certificate_gate_artifacts_are_current "$cert" "$key" "$pending" && \
        nexus_nginx_exec_condition_set_is_exact "$cert" "$key" "$pending" true
}

rr_restore_capture_target_ip_acme_state() {
    local rollback="${1:-}" access="$rollback/target-nexus-access.json"
    local state=absent address="" mode="" temporary="" service_active=false
    local timer_active=false timer_enabled=false artifact="" any_artifact=false
    [ -f "$access" ] && [ ! -L "$access" ] || return 1
    mode=$(jq -r '.certificate_mode // "none"' "$access" 2>/dev/null) || return 1
    address=$(jq -r '.domain // empty' "$access" 2>/dev/null) || return 1
    for artifact in \
        "${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}" \
        "${NEXUS_IP_ACME_WEBROOT:-/var/www/rr-nexus-ip-acme}" \
        "${NEXUS_IP_ACME_SERVICE_FILE:-/etc/systemd/system/rr-nexus-ip-acme.service}" \
        "${NEXUS_IP_ACME_TIMER_FILE:-/etc/systemd/system/rr-nexus-ip-acme.timer}" \
        "${NEXUS_IP_ACME_NGINX_AVAILABLE:-/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf}" \
        "${NEXUS_IP_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf}" \
        "${NEXUS_IP_ACME_LEGO_BIN:-/usr/local/lib/rr-vps/lego}" \
        "${NEXUS_IP_ACME_LEGO_MARKER:-/usr/local/lib/rr-vps/lego.install}" \
        "${NEXUS_IP_ACME_PENDING:-/etc/rr-nexus/certs/.ip-cert-pending}"; do
        if [ -e "$artifact" ] || [ -L "$artifact" ]; then
            any_artifact=true
            break
        fi
    done
    case "$mode" in
        acme-ip-shortlived)
            [ "$any_artifact" = true ] || return 1
            rr_restore_ip_acme_runtime_readonly_is_ready "$address" || return 1
            rr_restore_capture_unit_activity_state rr-nexus-ip-acme.service \
                service_active || return 1
            rr_restore_capture_unit_activity_state rr-nexus-ip-acme.timer \
                timer_active || return 1
            rr_restore_capture_unit_file_state rr-nexus-ip-acme.timer \
                timer_enabled || return 1
            [ "$service_active" = false ] && [ "$timer_active" = true ] && \
                [ "$timer_enabled" = true ] || return 1
            state=ready
            ;;
        pending-acme-ip)
            printf '%s\n' \
                '目标机 IP 证书仍处于待恢复签发状态；请先完成或卸载该事务，再执行便携恢复。' >&2
            return 1
            ;;
        *)
            [ "$any_artifact" = false ] || return 1
            rr_restore_legacy_ip_access_plane_is_exact "$access" || return 1
            address=""
            ;;
    esac
    temporary=$(mktemp "$rollback/.ip-acme-state.XXXXXX") || return 1
    if ! printf 'format=%s\nstate=%s\naddress=%s\n' \
            "$RR_RESTORE_IP_ACME_SNAPSHOT_FORMAT" "$state" "$address" > "$temporary" || \
       ! chmod 600 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" || \
       ! sync -f "$rollback"; then
        rm -f -- "$temporary"
        return 1
    fi
    [ "$(rr_restore_ip_acme_snapshot_state "$rollback")" = "$state" ]
}

rr_restore_snapshot_target_ip_acme_state() {
    local rollback="${1:-}" state=""
    state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
    [ "$state" = ready ] || return 0
    declare -F nexus_ip_acme_owned_state_is_safe >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_webroot_is_safe >/dev/null 2>&1 || return 1
    nexus_ip_acme_owned_state_is_safe && nexus_ip_acme_webroot_is_safe || return 1
    install -d -m 700 "$rollback/rootfs/var/lib/rr-nexus" || return 1
    install -d -m 755 "$rollback/rootfs/var/www" || return 1
    cp -a -- /var/lib/rr-nexus/ip-acme \
        "$rollback/rootfs/var/lib/rr-nexus/ip-acme" || return 1
    cp -a -- /var/www/rr-nexus-ip-acme \
        "$rollback/rootfs/var/www/rr-nexus-ip-acme" || return 1
    nexus_ip_acme_owned_state_is_safe && nexus_ip_acme_webroot_is_safe
}

rr_restore_ip_acme_prepare_parent() {
    local target="${1:-}" parent="" mode=""
    case "$target" in
        /var/lib/rr-nexus/ip-acme) parent=/var/lib/rr-nexus; mode=700 ;;
        /var/www/rr-nexus-ip-acme) parent=/var/www; mode=755 ;;
        *) return 1 ;;
    esac
    python3 - "$target" <<'PY'
import os
import stat
import sys

target = sys.argv[1]
chains = {
    "/var/lib/rr-nexus/ip-acme": (("/", 0o755), ("/var", 0o755), ("/var/lib", 0o755), ("/var/lib/rr-nexus", 0o700)),
    "/var/www/rr-nexus-ip-acme": (("/", 0o755), ("/var", 0o755), ("/var/www", 0o755)),
}
if target not in chains:
    raise SystemExit(1)
for index, (path, expected_mode) in enumerate(chains[target]):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if index == len(chains[target]) - 1:
            continue
        raise SystemExit(1)
    except OSError:
        raise SystemExit(1)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or (info.st_uid, info.st_gid) != (0, 0)
            or stat.S_IMODE(info.st_mode) != expected_mode
            or os.path.realpath(path) != path):
        raise SystemExit(1)
if os.path.realpath(os.path.dirname(target)) != os.path.dirname(target):
    raise SystemExit(1)
PY
    if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then
        install -d -m "$mode" "$parent" || return 1
    fi
    [ -d "$parent" ] && [ ! -L "$parent" ] && \
        [ "$(readlink -f -- "$parent" 2>/dev/null)" = "$parent" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = "0:0:${mode}" ]
}

rr_restore_ip_acme_fixed_parent_is_safe() {
    local target="${1:-}"
    python3 - "$target" <<'PY'
import os
import stat
import sys

target = sys.argv[1]
parents = {
    "/etc/systemd/system/rr-nexus-ip-acme.service": "/etc/systemd/system",
    "/etc/systemd/system/rr-nexus-ip-acme.timer": "/etc/systemd/system",
    "/usr/local/lib/rr-vps/lego": "/usr/local/lib/rr-vps",
    "/usr/local/lib/rr-vps/lego.install": "/usr/local/lib/rr-vps",
}
parent = parents.get(target)
if parent is None or os.path.dirname(target) != parent:
    raise SystemExit(1)
current = "/"
components = ["", *[part for part in parent.split("/") if part]]
for component in components:
    if component:
        current = os.path.join(current, component)
    try:
        info = os.lstat(current)
    except OSError:
        raise SystemExit(1)
    mode = stat.S_IMODE(info.st_mode)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or (info.st_uid, info.st_gid) != (0, 0)
            or mode & 0o7022 or os.path.realpath(current) != current):
        raise SystemExit(1)
if os.path.realpath(parent) != parent:
    raise SystemExit(1)
PY
}

rr_restore_ip_acme_removal_marker_is_safe() {
    local rollback="${1:-}" marker=""
    marker="$rollback/$RR_RESTORE_IP_ACME_REMOVAL_MARKER_NAME"
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$marker" 2>/dev/null)" = 0:0:600:1 ] && \
        [ "$(cat -- "$marker" 2>/dev/null)" = \
          "$RR_RESTORE_IP_ACME_REMOVAL_MARKER_VALUE" ]
}

rr_restore_authorize_ip_acme_runtime_removal() {
    local rollback="${1:-}" marker="" temporary="" state="" unit="" kind=""
    marker="$rollback/$RR_RESTORE_IP_ACME_REMOVAL_MARKER_NAME"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        rr_restore_ip_acme_removal_marker_is_safe "$rollback"
        return $?
    fi
    state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
    if [ "$state" = ready ]; then
        declare -F nexus_ip_acme_unit_is_current >/dev/null 2>&1 && \
            declare -F nexus_ip_acme_effective_service_is_exact >/dev/null 2>&1 && \
            declare -F nexus_ip_acme_effective_timer_is_exact >/dev/null 2>&1 && \
            declare -F nexus_ip_acme_lego_marker_is_current >/dev/null 2>&1 || \
            return 1
        for unit in /etc/systemd/system/rr-nexus-ip-acme.service \
            /etc/systemd/system/rr-nexus-ip-acme.timer; do
            rr_restore_ip_acme_fixed_parent_is_safe "$unit" || return 1
            kind=service
            [ "$unit" = /etc/systemd/system/rr-nexus-ip-acme.timer ] && kind=timer
            nexus_ip_acme_unit_is_current "$unit" "$kind" || return 1
        done
        nexus_ip_acme_effective_service_is_exact && \
            nexus_ip_acme_effective_timer_is_exact && \
            nexus_ip_acme_lego_marker_is_current || return 1
        rr_restore_ip_acme_fixed_parent_is_safe /usr/local/lib/rr-vps/lego && \
            rr_restore_ip_acme_fixed_parent_is_safe \
                /usr/local/lib/rr-vps/lego.install || return 1
    else
        for unit in /etc/systemd/system/rr-nexus-ip-acme.service \
            /etc/systemd/system/rr-nexus-ip-acme.timer \
            /usr/local/lib/rr-vps/lego /usr/local/lib/rr-vps/lego.install; do
            [ ! -e "$unit" ] && [ ! -L "$unit" ] || return 1
        done
    fi
    temporary=$(mktemp "$rollback/.ip-acme-removal.XXXXXX") || return 1
    if ! printf '%s\n' "$RR_RESTORE_IP_ACME_REMOVAL_MARKER_VALUE" > "$temporary" || \
       ! chmod 600 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$marker" || ! sync -f "$rollback"; then
        rm -f -- "$temporary"
        return 1
    fi
    rr_restore_ip_acme_removal_marker_is_safe "$rollback"
}

rr_restore_replace_target_ip_acme_state() {
    local rollback="${1:-}" state="" source="" target="" kind="" unit=""
    local architecture="" artifact=""
    state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
    # Preflight every fixed runtime artifact before replacing the first tree.
    rr_restore_authorize_ip_acme_runtime_removal "$rollback" || return 1
    for target in /var/lib/rr-nexus/ip-acme /var/www/rr-nexus-ip-acme; do
        rr_restore_ip_acme_prepare_parent "$target" || return 1
        if [ "$target" = /var/lib/rr-nexus/ip-acme ]; then
            kind=state
            source="$rollback/rootfs/var/lib/rr-nexus/ip-acme"
            if [ -e "$target" ] || [ -L "$target" ]; then
                declare -F nexus_ip_acme_state_tree_is_owned >/dev/null 2>&1 && \
                    declare -F nexus_ip_acme_path_is_mountpoint >/dev/null 2>&1 || return 1
                nexus_ip_acme_state_tree_is_owned || return 1
                nexus_ip_acme_path_is_mountpoint "$target" && return 1
            fi
        else
            kind=webroot
            source="$rollback/rootfs/var/www/rr-nexus-ip-acme"
            if [ -e "$target" ] || [ -L "$target" ]; then
                declare -F nexus_ip_acme_webroot_is_safe >/dev/null 2>&1 && \
                    declare -F nexus_ip_acme_path_is_mountpoint >/dev/null 2>&1 || return 1
                nexus_ip_acme_webroot_is_safe || return 1
                nexus_ip_acme_path_is_mountpoint "$target" && return 1
            fi
        fi
        rr_restore_ip_acme_prepare_parent "$target" || return 1
        [ ! -e "$target" ] && [ ! -L "$target" ] || rm -rf -- "$target" || return 1
        rr_restore_ip_acme_prepare_parent "$target" || return 1
        if [ "$state" = ready ]; then
            [ -d "$source" ] && [ ! -L "$source" ] || return 1
            cp -a -- "$source" "$target" || return 1
        else
            [ ! -e "$source" ] && [ ! -L "$source" ] || return 1
        fi
    done
    # Unit and pinned-client paths are also exact rollback state.  Publish a
    # durable authorization only after proving the complete candidate pair;
    # a boot recovery can then finish an interrupted per-file removal without
    # treating its own first unlink as an unexplained half-install.
    for unit in /etc/systemd/system/rr-nexus-ip-acme.timer \
        /etc/systemd/system/rr-nexus-ip-acme.service; do
        if [ -e "$unit" ] || [ -L "$unit" ]; then
            declare -F nexus_ip_acme_unit_is_current >/dev/null 2>&1 || return 1
            kind=service
            [ "$unit" = /etc/systemd/system/rr-nexus-ip-acme.timer ] && kind=timer
            rr_restore_ip_acme_fixed_parent_is_safe "$unit" || return 1
            nexus_ip_acme_unit_is_current "$unit" "$kind" || return 1
            unlink "$unit" 2>/dev/null || return 1
            sync -f "$(dirname -- "$unit")" || return 1
        fi
    done
    if [ -e /usr/local/lib/rr-vps/lego ] || [ -L /usr/local/lib/rr-vps/lego ] || \
       [ -e /usr/local/lib/rr-vps/lego.install ] || \
       [ -L /usr/local/lib/rr-vps/lego.install ]; then
        declare -F nexus_ip_acme_lego_current_architecture >/dev/null 2>&1 && \
            declare -F nexus_ip_acme_lego_binary_is_official >/dev/null 2>&1 && \
            declare -F nexus_ip_acme_lego_marker_record_is_current \
                >/dev/null 2>&1 || return 1
        nexus_ip_acme_lego_current_architecture architecture || return 1
        for artifact in /usr/local/lib/rr-vps/lego.install \
            /usr/local/lib/rr-vps/lego; do
            [ -e "$artifact" ] || [ -L "$artifact" ] || continue
            rr_restore_ip_acme_fixed_parent_is_safe "$artifact" || return 1
            if [ "$artifact" = /usr/local/lib/rr-vps/lego ]; then
                nexus_ip_acme_lego_binary_is_official \
                    "$artifact" "$architecture" || return 1
            else
                nexus_ip_acme_lego_marker_record_is_current \
                    "$artifact" "$architecture" || return 1
            fi
            unlink "$artifact" 2>/dev/null || return 1
            sync -f /usr/local/lib/rr-vps || return 1
        done
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if [ "$state" = ready ]; then
        nexus_ip_acme_owned_state_is_safe && nexus_ip_acme_webroot_is_safe
    else
        [ ! -e /var/lib/rr-nexus/ip-acme ] && \
            [ ! -L /var/lib/rr-nexus/ip-acme ] && \
            [ ! -e /var/www/rr-nexus-ip-acme ] && \
            [ ! -L /var/www/rr-nexus-ip-acme ]
    fi
}

rr_restore_disarm_target_ip_acme() {
    local rollback="${1:-}" state=""
    state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
    [ "$state" = ready ] || return 0
    declare -F nexus_ip_acme_disarm >/dev/null 2>&1 || return 1
    nexus_ip_acme_disarm || return 1
    rr_restore_unit_activity_matches rr-nexus-ip-acme.service inactive && \
        rr_restore_unit_activity_matches rr-nexus-ip-acme.timer inactive && \
        rr_restore_unit_file_state_matches rr-nexus-ip-acme.timer disabled
}

rr_restore_rearm_target_ip_acme() {
    local rollback="${1:-}" state="" address=""
    state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
    [ "$state" = ready ] || return 0
    address=$(sed -n 's/^address=//p' \
        "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME") || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] && [ "${#address}" -le 64 ] || return 1
    declare -F nexus_ip_acme_rearm >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_runtime_is_ready >/dev/null 2>&1 || return 1
    nexus_ip_acme_rearm "$address" || return 1
    nexus_ip_acme_runtime_is_ready "$address" || return 1
    rr_restore_unit_activity_matches rr-nexus-ip-acme.service inactive && \
        rr_restore_unit_activity_matches rr-nexus-ip-acme.timer active && \
        rr_restore_unit_file_state_matches rr-nexus-ip-acme.timer enabled
}

rr_restore_set_nexus_enablement() {
    local enabled="$1"
    if [ "$enabled" = true ]; then
        [ -r "$NEXUS_CONFIG_FILE" ] && [ -f "$NEXUS_SERVICE_FILE" ] || return 1
        systemctl enable rr-nexus >/dev/null 2>&1 || return 1
        rr_restore_unit_file_state_matches rr-nexus enabled || return 1
        return 0
    fi
    [ "$enabled" = false ] || return 1
    systemctl disable rr-nexus >/dev/null 2>&1 || true
    rr_restore_unit_file_state_matches rr-nexus disabled
}

rr_restore_finalize_nexus_enablement() {
    local rollback="$1" enabled=false running=false
    if [ -r "$NEXUS_CONFIG_FILE" ] || [ -f "$NEXUS_SERVICE_FILE" ]; then
        [ -r "$NEXUS_CONFIG_FILE" ] && [ -f "$NEXUS_SERVICE_FILE" ] || return 1
        if [ -f "$rollback/target_nexus_was_present" ]; then
            [ -f "$rollback/nexus_was_enabled" ] && enabled=true
            [ -f "$rollback/nexus_was_running" ] && running=true
        else
            # A valid Nexus imported onto a machine without Nexus is a new
            # managed service. It must be live now and survive the first boot.
            enabled=true
            running=true
        fi
    fi
    if [ "$enabled" = true ] || [ "$running" = true ]; then
        rr_nexus_service_start_preflight || return 1
    fi
    rr_restore_set_nexus_enablement "$enabled" || return 1
    if [ "$running" = true ]; then
        rr_nexus_systemctl_start_checked >/dev/null 2>&1 || return 1
        rr_restore_unit_activity_matches rr-nexus active
    else
        systemctl stop rr-nexus >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches rr-nexus inactive
    fi
}

rr_restore_restore_nexus_enablement() {
    local rollback="$1" enabled=false
    [ -f "$rollback/nexus_was_enabled" ] && enabled=true
    rr_restore_set_nexus_enablement "$enabled"
}

rr_restore_apply_target_network_config() {
    local rollback="$1"
    local TARGET_ENTRY_IP_MODE=auto TARGET_OUTBOUND_IP_MODE=auto
    local TARGET_ENTRY_IPV4_ADDRESS="" TARGET_ENTRY_IPV6_ADDRESS=""
    local TARGET_SUB_PORT="" TARGET_SUB_ACCESS_MODE=local TARGET_SUB_DOMAIN=""
    local TARGET_SUB_PUBLIC_PORT_IPV4="" TARGET_SUB_PUBLIC_PORT_IPV6=""
    [ -r "$rollback/target-network" ] || return 1
    # This file was generated locally with printf %q before the mutation and
    # is never accepted from the imported archive.
    # shellcheck disable=SC1090
    source "$rollback/target-network" || return 1
    load_config_with_defaults || return 1
    case "$TARGET_ENTRY_IP_MODE" in auto|ipv4|ipv6) ;; *) return 1 ;; esac
    case "$TARGET_OUTBOUND_IP_MODE" in
        auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;;
        *) return 1 ;;
    esac
    case "$TARGET_SUB_ACCESS_MODE" in
        local) [ -z "$TARGET_SUB_DOMAIN" ] || return 1 ;;
        https) is_valid_domain "$TARGET_SUB_DOMAIN" || return 1 ;;
        *) return 1 ;;
    esac
    if [ -n "$TARGET_SUB_PORT" ]; then
        is_valid_port "$TARGET_SUB_PORT" || return 1
        safe_sed SUB_PORT "$TARGET_SUB_PORT" || return 1
    fi
    is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV4" || TARGET_SUB_PUBLIC_PORT_IPV4="$SUB_PORT"
    is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV6" || TARGET_SUB_PUBLIC_PORT_IPV6="$SUB_PORT"
    safe_sed ENTRY_IP_MODE "$TARGET_ENTRY_IP_MODE" || return 1
    safe_sed OUTBOUND_IP_MODE "$TARGET_OUTBOUND_IP_MODE" || return 1
    safe_sed ENTRY_IPV4_ADDRESS "$TARGET_ENTRY_IPV4_ADDRESS" || return 1
    safe_sed ENTRY_IPV6_ADDRESS "$TARGET_ENTRY_IPV6_ADDRESS" || return 1
    safe_sed SUB_ACCESS_MODE "$TARGET_SUB_ACCESS_MODE" || return 1
    safe_sed SUB_DOMAIN "$TARGET_SUB_DOMAIN" || return 1
    if is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV4"; then
        safe_sed SUB_PUBLIC_PORT_IPV4 "$TARGET_SUB_PUBLIC_PORT_IPV4" || return 1
    fi
    if is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV6"; then
        safe_sed SUB_PUBLIC_PORT_IPV6 "$TARGET_SUB_PUBLIC_PORT_IPV6" || return 1
    fi
}

rr_restore_apply_target_network() {
    local rollback="$1"
    rr_restore_apply_target_network_config "$rollback" || return 1
    install -d -m 700 /etc/rr-update || return 1
    if [ -s "$rollback/rootfs/etc/rr-update/channel" ]; then
        install -m 600 "$rollback/rootfs/etc/rr-update/channel" /etc/rr-update/channel || return 1
    else
        printf '%s\n' stable > /etc/rr-update/channel || return 1
        chmod 600 /etc/rr-update/channel || return 1
    fi
    rr_refresh_update_channel_constants || return 1
}

rr_restore_restore_nginx_files() {
    local rollback="$1" source="" target="" ip_state=legacy ip_address=""
    declare -F nexus_nginx_managed_paths_are_owned >/dev/null 2>&1 && \
        declare -F nexus_nginx_unlink_owned_path >/dev/null 2>&1 && \
        declare -F nexus_nginx_copy_snapshot_noreplace >/dev/null 2>&1 && \
        declare -F nexus_nginx_restore_snapshot_path >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_parent_directory_is_safe >/dev/null 2>&1 || \
        return 1
    rr_restore_nginx_snapshot_paths_are_owned "$rollback" || return 1
    nexus_nginx_managed_paths_are_owned || return 1
    if [ -e "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ] || \
       [ -L "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ]; then
        ip_state=$(rr_restore_ip_acme_snapshot_state "$rollback") || return 1
        if [ "$ip_state" = ready ]; then
            ip_address=$(sed -n 's/^address=//p' \
                "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME") || return 1
            declare -F nexus_ip_acme_nginx_http_site_removal_is_safe \
                >/dev/null 2>&1 || return 1
            nexus_ip_acme_nginx_http_site_removal_is_safe "$ip_address" || return 1
        else
            [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
                [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
                [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
                [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] || return 1
        fi
    else
        [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] || return 1
    fi
    # Every existing path was preflighted before the first unlink.  Reuse the
    # renderer-owned boundary helper for each of the six generic Nexus paths;
    # the IP-ACME pair has its own exact address-bound removal helper.
    for target in \
        /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf \
        /etc/nginx/sites-enabled/rr-nexus.conf \
        /etc/nginx/sites-enabled/rr-nexus-port.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip.conf; do
        rr_restore_nginx_live_paths_are_owned "$ip_state" "$ip_address" || \
            return 1
        nexus_nginx_unlink_owned_path "$target" || return 1
    done
    if [ "$ip_state" = ready ]; then
        declare -F nexus_ip_acme_remove_nginx_http_site >/dev/null 2>&1 || return 1
        rr_restore_nginx_live_paths_are_owned "$ip_state" "$ip_address" || \
            return 1
        nexus_ip_acme_remove_nginx_http_site "$ip_address" || return 1
    fi
    rr_restore_prepare_nginx_snapshot_destinations || return 1
    for source in \
        "$rollback/nginx/sites-available/rr-nexus.conf" \
        "$rollback/nginx/sites-available/rr-nexus.conf.port" \
        "$rollback/nginx/sites-available/rr-nexus-ip.conf" \
        "$rollback/nginx/sites-enabled/rr-nexus.conf" \
        "$rollback/nginx/sites-enabled/rr-nexus-port.conf" \
        "$rollback/nginx/sites-enabled/rr-nexus-ip.conf"; do
        [ -e "$source" ] || [ -L "$source" ] || continue
        case "$source" in
            "$rollback/nginx/sites-available/"*)
                target="/etc/nginx/sites-available/${source##*/}"
                ;;
            *) target="/etc/nginx/sites-enabled/${source##*/}" ;;
        esac
        nexus_nginx_restore_snapshot_path "$source" "$target" || return 1
    done
    if [ "$ip_state" = ready ]; then
        source="$rollback/nginx/sites-available/rr-nexus-ip-acme-http.conf"
        target=/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
        nexus_ip_acme_parent_directory_is_safe "$target" || return 1
        nexus_nginx_copy_snapshot_noreplace "$source" "$target" || return 1
        [ -f "$target" ] && [ ! -L "$target" ] && \
            cmp -s -- "$source" "$target" || return 1
        sync -f /etc/nginx/sites-available || return 1
        source="$rollback/nginx/sites-enabled/rr-nexus-ip-acme-http.conf"
        target=/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
        nexus_ip_acme_parent_directory_is_safe "$target" || return 1
        nexus_nginx_copy_snapshot_noreplace "$source" "$target" || return 1
        [ -L "$target" ] && [ "$(readlink -- "$target" 2>/dev/null)" = \
            /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] || return 1
        sync -f /etc/nginx/sites-enabled || return 1
    fi
    nexus_nginx_managed_paths_are_owned || return 1
    if [ "$ip_state" = ready ]; then
        nexus_ip_acme_nginx_http_site_is_current "$ip_address" || return 1
    else
        [ ! -e /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf ] && \
            [ ! -e /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] && \
            [ ! -L /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf ] || return 1
    fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || return 1
    fi
}

rr_restore_activate_nginx_state() {
    local rollback="$1"
    if command -v nginx >/dev/null 2>&1; then
        if [ -f "$rollback/nginx_was_enabled" ]; then
            systemctl enable nginx >/dev/null 2>&1 || return 1
            rr_restore_unit_file_state_matches nginx enabled || return 1
        else
            systemctl disable nginx >/dev/null 2>&1 || true
            rr_restore_unit_file_state_matches nginx disabled || return 1
        fi
        if [ -f "$rollback/nginx_was_running" ]; then
            systemctl restart nginx >/dev/null 2>&1 || return 1
            rr_restore_unit_activity_matches nginx active || return 1
        else
            systemctl stop nginx >/dev/null 2>&1 || true
            rr_restore_unit_activity_matches nginx inactive || return 1
        fi
    fi
}

rr_restore_restore_nginx() {
    local rollback="$1" mode="${2:-all}"
    case "$mode" in all|files|activate) ;; *) return 1 ;; esac
    if [ "$mode" != activate ]; then
        rr_restore_restore_nginx_files "$rollback" || return 1
    fi
    [ "$mode" = files ] || rr_restore_activate_nginx_state "$rollback"
}

rr_restore_fixed_cloudflared_evidence_is_trusted() {
    local config="${CONFIG_FILE:-/etc/argo_vmess.conf}"
    local token="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local token_dir="" metadata="" owner="" group="" links="" mode="" size=""
    local value="" lines=0
    load_config_with_defaults >/dev/null 2>&1 || return 1
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 1
    [ -f "$config" ] && [ ! -L "$config" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$config" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<<"$metadata"
    [ "$owner:$group:$links" = 0:0:1 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 1

    token_dir=$(dirname -- "$token") || return 1
    [ -d "$token_dir" ] && [ ! -L "$token_dir" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$token_dir" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ -f "$token" ] && [ ! -L "$token" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$token" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<<"$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1 ] && \
        [ "$size" -le 4097 ] || return 1
    lines=$(wc -l < "$token" 2>/dev/null) || return 1
    [ "$lines" -eq 1 ] || return 1
    IFS= read -r value < "$token" || return 1
    [ -n "$value" ] && [ "${#value}" -le 4096 ] && \
        [[ "$value" != *[[:space:]]* ]]
}

rr_restore_fixed_cloudflared_binary_path() {
    local cloudflared_bin="${RR_CLOUDFLARED_BIN:-}" canonical="" metadata=""
    local owner="" group="" mode="" links=""
    [ -n "$cloudflared_bin" ] || \
        cloudflared_bin=$(command -v cloudflared 2>/dev/null) || return 1
    canonical=$(readlink -f -- "$cloudflared_bin" 2>/dev/null) || return 1
    [[ "$canonical" = /* && "$canonical" != *[[:space:]]* ]] || return 1
    [ -f "$canonical" ] && [ ! -L "$canonical" ] && [ -x "$canonical" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$canonical" 2>/dev/null) || return 1
    IFS=: read -r owner group mode links <<<"$metadata"
    [ "$owner:$group" = 0:0 ] && [[ "$links" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    printf '%s\n' "$canonical"
}

rr_restore_render_fixed_cloudflared_service() {
    local cloudflared_bin="$1"
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    cat <<EOF
[Unit]
Description=RR-vps Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=${token_file}

[Service]
Type=simple
DynamicUser=no
User=root
Group=root
LoadCredential=rr-tunnel-token:${token_file}
ExecStart=${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
UMask=0077
NoNewPrivileges=yes
PrivateUsers=no
PrivateMounts=no
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
}

rr_restore_fixed_cloudflared_unit_is_owned() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin="" canonical="" fragment="" dropins="" load_state=""
    local metadata="" owner="" group="" links="" mode="" size=""
    local exec_start="" exec_start_pre="" exec_reload="" user="" dynamic_user=""
    local working_directory="" private_network="" root_directory="" root_image=""
    local restore_dropin="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}/cloudflared.service.d/${RR_RESTORE_GATE_DROPIN_NAME}"
    rr_restore_fixed_cloudflared_evidence_is_trusted || return 1
    [ -f "$service_file" ] && [ ! -L "$service_file" ] || return 1
    canonical=$(readlink -f -- "$service_file" 2>/dev/null) || return 1
    [ "$canonical" = "$service_file" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$service_file" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<<"$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:644 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 1
    cloudflared_bin=$(rr_restore_fixed_cloudflared_binary_path) || return 1
    cmp -s -- "$service_file" \
        <(rr_restore_render_fixed_cloudflared_service "$cloudflared_bin") || return 1
    load_state=$(systemctl show --property=LoadState --value \
        cloudflared.service 2>/dev/null) || return 1
    fragment=$(systemctl show --property=FragmentPath --value \
        cloudflared.service 2>/dev/null) || return 1
    dropins=$(systemctl show --property=DropInPaths --value \
        cloudflared.service 2>/dev/null) || return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$service_file" ] || return 1
    case "$dropins" in
        "") ;;
        "$restore_dropin")
            rr_restore_gate_dropin_file_is_exact "$restore_dropin" || return 1
            rr_restore_effective_dropin_order_is_safe cloudflared.service false || return 1
            ;;
        *) return 1 ;;
    esac
    # Bind ownership to the effective service identity as well as the exact
    # on-disk renderer.  Runtime-only systemd metadata varies across supported
    # releases, so parse only the security-relevant command fields.
    exec_start=$(systemctl show --property=ExecStart --value \
        cloudflared.service 2>/dev/null) || return 1
    exec_start_pre=$(systemctl show --property=ExecStartPre --value \
        cloudflared.service 2>/dev/null) || return 1
    exec_reload=$(systemctl show --property=ExecReload --value \
        cloudflared.service 2>/dev/null) || return 1
    python3 - "$exec_start" "$cloudflared_bin" <<'PY' || return 1
import re
import sys

raw, binary = sys.argv[1:]
encoded = re.findall(r"\{([^{}]*)\}", raw)
if len(encoded) != 1 or raw.count("{") != 1 or raw.count("}") != 1:
    raise SystemExit(1)
fields = {}
for item in encoded[0].split(";"):
    item = item.strip()
    if not item or "=" not in item:
        continue
    key, value = item.split("=", 1)
    key = key.strip()
    if key in fields:
        raise SystemExit(1)
    fields[key] = value.strip()
expected_argv = (
    f"{binary} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
)
if (
    (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    != (binary, expected_argv, "no")
    or raw.count("path=") != 1
    or raw.count("argv[]=") != 1
    or raw.count("ignore_errors=") != 1
):
    raise SystemExit(1)
PY
    [ -z "$exec_start_pre" ] && [ -z "$exec_reload" ] || return 1
    dynamic_user=$(systemctl show --property=DynamicUser --value \
        cloudflared.service 2>/dev/null) || return 1
    user=$(systemctl show --property=User --value \
        cloudflared.service 2>/dev/null) || return 1
    group=$(systemctl show --property=Group --value \
        cloudflared.service 2>/dev/null) || return 1
    working_directory=$(systemctl show --property=WorkingDirectory --value \
        cloudflared.service 2>/dev/null) || return 1
    private_network=$(systemctl show --property=PrivateNetwork --value \
        cloudflared.service 2>/dev/null) || return 1
    root_directory=$(systemctl show --property=RootDirectory --value \
        cloudflared.service 2>/dev/null) || return 1
    root_image=$(systemctl show --property=RootImage --value \
        cloudflared.service 2>/dev/null) || return 1
    [ "$dynamic_user" = no ] && [ "$private_network" = no ] && \
        [ -z "$root_directory" ] && [ -z "$root_image" ] || return 1
    case "$user" in ""|root) ;; *) return 1 ;; esac
    case "$group" in ""|root) ;; *) return 1 ;; esac
    case "$working_directory" in ""|/) ;; *) return 1 ;; esac
    # The exact fragment and sole allowed restore drop-in prove the sole
    # ConditionFileNotEmpty token condition.  This check additionally binds
    # all effective ExecCondition records, including ignore_errors semantics.
    rr_restore_effective_conditions_are_managed cloudflared.service
}

rr_restore_write_cloudflared_claim() {
    local rollback="$1" service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local claim="$rollback/cloudflared_service_was_present" temporary=""
    local service_sha="" token_sha="" cloudflared_bin=""
    rr_restore_fixed_cloudflared_unit_is_owned || return 1
    service_sha=$(sha256sum -- "$service_file" 2>/dev/null | awk '{print $1}') || return 1
    token_sha=$(sha256sum -- "$token_file" 2>/dev/null | awk '{print $1}') || return 1
    cloudflared_bin=$(rr_restore_fixed_cloudflared_binary_path) || return 1
    [[ "$service_sha" =~ ^[0-9a-f]{64}$ && "$token_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    temporary=$(mktemp "$rollback/.cloudflared-claim.XXXXXX") || return 1
    if ! printf '%s\n' \
        'rr-cloudflared-claim-v1' \
        "fragment=$service_file" \
        "binary=$cloudflared_bin" \
        "service_sha256=$service_sha" \
        "token_sha256=$token_sha" > "$temporary" || \
       ! chmod 600 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$claim" || ! sync -f "$rollback"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_restore_rollback_claims_cloudflared() {
    # Return 0 only for a trustworthy RR-owned Cloudflared snapshot, 1 when
    # this otherwise-safe rollback contains no such claim, and 2 when the
    # supplied evidence itself is malformed.  The stage is root-only, so a
    # validated marker remains authoritative even after the live config has
    # been cleared or a candidate replay has failed.
    local rollback="$1" stage="" canonical="" mode="" metadata=""
    local owner="" group="" links="" size="" service_sha="" token_sha=""
    local expected_binary="" current_binary="" expected_fragment=""
    local marker="$rollback/cloudflared_service_was_present"
    local service="$rollback/cloudflared.service"
    local token_snapshot="$rollback/rootfs/etc/rr-cloudflared/token"
    local -a claim_lines=()
    [ "$(basename -- "$rollback")" = rollback ] || return 2
    stage=$(dirname -- "$rollback") || return 2
    rr_restore_stage_is_safe "$stage" || return 2
    [ -d "$rollback" ] && [ ! -L "$rollback" ] || return 2
    canonical=$(readlink -f -- "$rollback" 2>/dev/null) || return 2
    [ "$canonical" = "$rollback" ] || return 2
    [ "$(stat -c '%u:%g' "$rollback" 2>/dev/null)" = 0:0 ] || return 2
    mode=$(stat -c %a "$rollback" 2>/dev/null) || return 2
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 2
    [ $((8#$mode & 8#7022)) -eq 0 ] || return 2

    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 1
    fi
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
    metadata=$(stat -c '%u:%g:%h:%s:%a' "$marker" 2>/dev/null) || return 2
    IFS=: read -r owner group links size mode <<<"$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 2
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 2048 ] || return 2
    mapfile -t claim_lines < "$marker" || return 2
    [ "${#claim_lines[@]}" -eq 5 ] || return 2
    [ "${claim_lines[0]}" = rr-cloudflared-claim-v1 ] || return 2
    expected_fragment="${claim_lines[1]#fragment=}"
    expected_binary="${claim_lines[2]#binary=}"
    service_sha="${claim_lines[3]#service_sha256=}"
    token_sha="${claim_lines[4]#token_sha256=}"
    [ "${claim_lines[1]}" = "fragment=$expected_fragment" ] && \
        [ "${claim_lines[2]}" = "binary=$expected_binary" ] && \
        [ "${claim_lines[3]}" = "service_sha256=$service_sha" ] && \
        [ "${claim_lines[4]}" = "token_sha256=$token_sha" ] || return 2
    [ "$expected_fragment" = \
        "${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}" ] || return 2
    [[ "$service_sha" =~ ^[0-9a-f]{64}$ && "$token_sha" =~ ^[0-9a-f]{64}$ ]] || return 2
    current_binary=$(rr_restore_fixed_cloudflared_binary_path) || return 2
    [ "$expected_binary" = "$current_binary" ] || return 2

    [ -f "$service" ] && [ ! -L "$service" ] || return 2
    metadata=$(stat -c '%u:%g:%h:%s:%a' "$service" 2>/dev/null) || return 2
    IFS=: read -r owner group links size mode <<<"$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:644 ] || return 2
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 2
    [ "$(sha256sum -- "$service" 2>/dev/null | awk '{print $1}')" = \
        "$service_sha" ] || return 2
    cmp -s -- "$service" \
        <(rr_restore_render_fixed_cloudflared_service "$expected_binary") || return 2
    [ -f "$token_snapshot" ] && [ ! -L "$token_snapshot" ] || return 2
    [ "$(stat -c '%u:%g:%h:%a' -- "$token_snapshot" 2>/dev/null)" = \
        0:0:1:600 ] || return 2
    [ "$(sha256sum -- "$token_snapshot" 2>/dev/null | awk '{print $1}')" = \
        "$token_sha" ] || return 2
    return 0
}

rr_restore_stop_managed_runtime() {
    local rollback="${1:-}" failed=false cloudflared_owned=false claim_result=1
    if [ -n "$rollback" ]; then
        if rr_restore_rollback_claims_cloudflared "$rollback"; then
            claim_result=0
        else
            claim_result=$?
        fi
        case "$claim_result" in
            0) cloudflared_owned=true ;;
            1) ;;
            2|*) failed=true ;;
        esac
    fi
    load_config_with_defaults >/dev/null 2>&1 || true
    if [ -n "$rollback" ] && \
       [ -e "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ]; then
        rr_restore_disarm_target_ip_acme "$rollback" || failed=true
    fi
    # Nginx can already have crossed the READY gate when a late rollback check
    # fails.  Always stop it with the managed runtime and always prove it is
    # inactive, even when no nginx executable is currently discoverable.
    systemctl stop rr-nexus sing-box nginx >/dev/null 2>&1 || true
    systemctl stop argo-rr-health.timer argo-rr-health.service >/dev/null 2>&1 || true
    stop_subscription_servers >/dev/null 2>&1 || failed=true
    stop_quick_argo_tunnel >/dev/null 2>&1 || true
    if rr_restore_fixed_cloudflared_unit_is_owned; then
        cloudflared_owned=true
    fi
    if [ "$cloudflared_owned" = true ]; then
        rr_restore_fixed_cloudflared_unit_is_owned || failed=true
        # Freezing must be reversible even if the process is killed before a
        # rollback snapshot is complete.  Stop the RR-owned fixed tunnel here;
        # uninstall it only after the durable transaction reaches `mutating`.
        if [ "$failed" = false ]; then
            systemctl stop cloudflared >/dev/null 2>&1 || failed=true
        fi
    fi
    rr_restore_unit_activity_matches rr-nexus inactive || failed=true
    rr_restore_unit_activity_matches sing-box inactive || failed=true
    rr_restore_unit_activity_matches nginx inactive || failed=true
    rr_restore_unit_activity_matches argo-rr-health.timer inactive || failed=true
    rr_restore_unit_activity_matches argo-rr-health.service inactive || failed=true
    if [ "$cloudflared_owned" = true ]; then
        rr_restore_unit_activity_matches cloudflared inactive || failed=true
    fi
    subscription_server_running && failed=true
    expected_argo_tunnel_running >/dev/null 2>&1 && failed=true
    [ "$failed" = false ]
}

rr_restore_freeze_writers() {
    local failed=false rollback="${1:-${rollback:-}}"
    # Nexus is the authoritative SQLite/key writer.  The health timer can
    # trigger a sync while the snapshot is being assembled.  Other data-plane
    # services do not write the portable state and stay online until the
    # rollback snapshot is durably committed.
    if [ -n "$rollback" ] && \
       [ -e "$rollback/$RR_RESTORE_IP_ACME_SNAPSHOT_NAME" ]; then
        rr_restore_disarm_target_ip_acme "$rollback" || failed=true
    fi
    systemctl stop rr-nexus >/dev/null 2>&1 || true
    systemctl stop argo-rr-health.timer argo-rr-health.service >/dev/null 2>&1 || true
    rr_restore_unit_activity_matches rr-nexus inactive || failed=true
    rr_restore_unit_activity_matches argo-rr-health.timer inactive || failed=true
    rr_restore_unit_activity_matches argo-rr-health.service inactive || failed=true
    [ "$failed" = false ]
}

rr_restore_resume_snapshot_writers() {
    local rollback="$1" failed=false
    # Pre-mutation freeze touches only Nexus and the health scheduler.  Restore
    # exactly that set; Sing-box, subscriptions, Nginx and both Argo modes
    # remained live and must retain their original process identity/state.
    rr_restore_rearm_target_ip_acme "$rollback" || return 1
    if [ -f "$rollback/nexus_was_running" ]; then
        rr_nexus_service_start_preflight || return 1
        rr_nexus_systemctl_start_checked >/dev/null 2>&1 || failed=true
        rr_restore_unit_activity_matches rr-nexus active || failed=true
    else
        systemctl stop rr-nexus >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches rr-nexus inactive || failed=true
    fi
    systemctl stop argo-rr-health.service >/dev/null 2>&1 || true
    rr_restore_unit_activity_matches argo-rr-health.service inactive || failed=true
    if [ -f "$rollback/health_timer_was_running" ]; then
        systemctl start argo-rr-health.timer >/dev/null 2>&1 || failed=true
        rr_restore_unit_activity_matches argo-rr-health.timer active || failed=true
    else
        systemctl stop argo-rr-health.timer >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches argo-rr-health.timer inactive || failed=true
    fi
    [ "$failed" = false ]
}

rr_restore_resume_frozen_writers() {
    local rollback="$1" failed=false cloudflared_owned=false claim_result=1
    # Full rollback resumes every data-plane component, so configuration and
    # target-address proof must succeed before the first start/stop action.
    load_config_with_defaults >/dev/null 2>&1 || return 1
    select_entry_ip >/dev/null 2>&1 || return 1
    if rr_restore_rollback_claims_cloudflared "$rollback"; then
        claim_result=0
    else
        claim_result=$?
    fi
    case "$claim_result" in
        0) cloudflared_owned=true ;;
        1) ;;
        2|*) return 1 ;;
    esac
    if [ "$cloudflared_owned" = true ]; then
        rr_restore_fixed_cloudflared_unit_is_owned || return 1
    fi
    rr_restore_rearm_target_ip_acme "$rollback" || return 1
    # Prove every RR data-plane unit that may be started before the first
    # start action.  A hostile Nexus unit must not be discovered only after a
    # valid Sing-box unit has already been revived (or vice versa).
    if [ -f "$rollback/singbox_was_running" ]; then
        rr_singbox_service_start_preflight || return 1
    fi
    if [ -f "$rollback/nexus_was_running" ]; then
        rr_nexus_service_start_preflight || return 1
    fi
    if [ -f "$rollback/singbox_was_running" ]; then
        rr_singbox_systemctl_start_checked >/dev/null 2>&1 || failed=true
        rr_restore_unit_activity_matches sing-box active || failed=true
    else
        systemctl stop sing-box >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches sing-box inactive || failed=true
    fi
    if [ -f "$rollback/subscription_was_running" ]; then
        rr_run_without_inherited_update_lock_fds \
            start_subscription_server >/dev/null 2>&1 || failed=true
        subscription_server_running || failed=true
    else
        stop_subscription_servers >/dev/null 2>&1 || true
    fi
    if [ -f "$rollback/argo_was_running" ]; then
        # A fixed tunnel may be started only when the safe rollback snapshot
        # or the still-live RR token configuration proves ownership.  Quick
        # tunnels remain independent of a third-party cloudflared.service.
        if [ "${TUNNEL_MODE:-1}" = 2 ] && \
           [ "$cloudflared_owned" != true ]; then
            failed=true
        else
            if [ "${TUNNEL_MODE:-1}" = 2 ]; then
                rr_restore_fixed_cloudflared_unit_is_owned || failed=true
            fi
            [ "$failed" = false ] || return 1
            rr_run_without_inherited_update_lock_fds \
                start_argo_tunnel >/dev/null 2>&1 || failed=true
            expected_argo_tunnel_running >/dev/null 2>&1 || failed=true
            if [ "${TUNNEL_MODE:-1}" = 2 ]; then
                rr_restore_unit_activity_matches cloudflared active || failed=true
            fi
        fi
    else
        stop_quick_argo_tunnel >/dev/null 2>&1 || true
        # Absence of the RR running marker says nothing about an unrelated
        # cloudflared service.  Preserve it unless ownership is proven.
        if [ "$cloudflared_owned" = true ]; then
            rr_restore_fixed_cloudflared_unit_is_owned || failed=true
            [ "$failed" = false ] && \
                systemctl stop cloudflared >/dev/null 2>&1 || failed=true
            rr_restore_unit_activity_matches cloudflared inactive || failed=true
        fi
    fi
    if [ -f "$rollback/nexus_was_running" ]; then
        rr_nexus_systemctl_start_checked >/dev/null 2>&1 || failed=true
        rr_restore_unit_activity_matches rr-nexus active || failed=true
    else
        systemctl stop rr-nexus >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches rr-nexus inactive || failed=true
    fi
    if [ -f "$rollback/health_timer_was_running" ]; then
        systemctl start argo-rr-health.timer >/dev/null 2>&1 || failed=true
        rr_restore_unit_activity_matches argo-rr-health.timer active || failed=true
    else
        systemctl stop argo-rr-health.timer >/dev/null 2>&1 || true
        rr_restore_unit_activity_matches argo-rr-health.timer inactive || failed=true
    fi
    rr_restore_unit_activity_matches argo-rr-health.service inactive || failed=true
    [ "$failed" = false ]
}

rr_restore_remove_managed_fixed_tunnel() {
    local cloud_load_state=""
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    load_config_with_defaults >/dev/null 2>&1 || return 1
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 0
    rr_restore_unit_load_state_read cloudflared.service cloud_load_state || return 1
    case "$cloud_load_state" in
        loaded)
            rr_restore_fixed_cloudflared_unit_is_owned || return 1
            systemctl stop cloudflared.service >/dev/null 2>&1 || return 1
            rr_restore_unit_activity_matches cloudflared.service inactive || return 1
            rr_restore_fixed_cloudflared_unit_is_owned || return 1
            systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
            rr_restore_unit_file_state_matches cloudflared.service disabled || return 1
            rr_restore_fixed_cloudflared_unit_is_owned || return 1
            rm -f -- "$service_file" || return 1
            [ ! -e "$service_file" ] && [ ! -L "$service_file" ] || return 1
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            rr_restore_unit_load_state_read cloudflared.service cloud_load_state || return 1
            [ "$cloud_load_state" = not-found ] || return 1
            rr_restore_unit_activity_matches cloudflared.service inactive || return 1
            rr_restore_unit_file_state_matches cloudflared.service disabled
            ;;
        not-found)
            [ ! -e "$service_file" ] && [ ! -L "$service_file" ]
            ;;
        masked|*) return 1 ;;
    esac
}

rr_restore_apply_cloudflared_snapshot() {
    local rollback="$1" claim_result=1 load_state="" temporary=""
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    if rr_restore_rollback_claims_cloudflared "$rollback"; then
        claim_result=0
    else
        claim_result=$?
    fi
    case "$claim_result" in
        0) ;;
        1) return 0 ;;
        2|*) return 1 ;;
    esac
    rr_restore_unit_load_state_read cloudflared.service load_state || return 1
    if [ -e "$service_file" ] || [ -L "$service_file" ] || \
       [ "$load_state" != not-found ]; then
        rr_restore_fixed_cloudflared_unit_is_owned || return 1
    fi
    install -d -m 755 "$(dirname -- "$service_file")" || return 1
    temporary=$(mktemp "$(dirname -- "$service_file")/.cloudflared.restore.XXXXXX") || return 1
    if ! install -m 644 "$rollback/cloudflared.service" "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$service_file" || \
       ! sync -f "$(dirname -- "$service_file")"; then
        rm -f -- "$temporary"
        return 1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    rr_restore_require_effective_gates_or_isolate || return 1
    rr_restore_fixed_cloudflared_unit_is_owned || return 1
    if [ -f "$rollback/cloudflared_was_enabled" ]; then
        systemctl enable cloudflared >/dev/null 2>&1 || return 1
        rr_restore_unit_file_state_matches cloudflared enabled || return 1
    else
        systemctl disable cloudflared >/dev/null 2>&1 || true
        rr_restore_unit_file_state_matches cloudflared disabled || return 1
    fi
}

rr_restore_migrate_with_original_state() {
    local rollback="$1"
    RR_UPDATE_TRANSACTION=1 \
    RR_UPDATE_SINGBOX_WAS_RUNNING="$([ -f "$rollback/singbox_was_running" ] && printf true || printf false)" \
    RR_UPDATE_NEXUS_WAS_RUNNING="$([ -f "$rollback/nexus_was_running" ] && printf true || printf false)" \
    RR_UPDATE_SUBSCRIPTION_WAS_RUNNING="$([ -f "$rollback/subscription_was_running" ] && printf true || printf false)" \
    RR_UPDATE_ARGO_WAS_RUNNING="$([ -f "$rollback/argo_was_running" ] && printf true || printf false)" \
    RR_UPDATE_HEALTH_TIMER_WAS_ENABLED="$([ -f "$rollback/health_timer_was_enabled" ] && printf true || printf false)" \
        post_update_migrate
}

rr_restore_finalize_original_service_state() {
    local rollback="$1" failed=false

    if [ -f /etc/systemd/system/sing-box.service ]; then
        rr_singbox_service_start_preflight || return 1
        if [ -f "$rollback/singbox_was_enabled" ]; then
            systemctl enable sing-box >/dev/null 2>&1 || failed=true
            rr_restore_unit_file_state_matches sing-box enabled || failed=true
        else
            systemctl disable sing-box >/dev/null 2>&1 || true
            rr_restore_unit_file_state_matches sing-box disabled || failed=true
        fi
        if [ -f "$rollback/singbox_was_running" ]; then
            rr_singbox_systemctl_start_checked >/dev/null 2>&1 || failed=true
            rr_restore_unit_activity_matches sing-box active || failed=true
        else
            systemctl stop sing-box >/dev/null 2>&1 || true
            rr_restore_unit_activity_matches sing-box inactive || failed=true
        fi
    fi

    if [ -f /etc/systemd/system/argo-rr-health.timer ]; then
        if [ -f "$rollback/health_timer_was_enabled" ]; then
            systemctl enable argo-rr-health.timer >/dev/null 2>&1 || failed=true
            rr_restore_unit_file_state_matches argo-rr-health.timer enabled || failed=true
        else
            systemctl disable argo-rr-health.timer >/dev/null 2>&1 || true
            rr_restore_unit_file_state_matches argo-rr-health.timer disabled || failed=true
        fi
        if [ -f "$rollback/health_timer_was_running" ]; then
            systemctl start argo-rr-health.timer >/dev/null 2>&1 || failed=true
            rr_restore_unit_activity_matches argo-rr-health.timer active || failed=true
        else
            systemctl stop argo-rr-health.timer >/dev/null 2>&1 || true
            rr_restore_unit_activity_matches argo-rr-health.timer inactive || failed=true
        fi
    fi

    rr_restore_finalize_nexus_enablement "$rollback" || failed=true
    [ "$failed" = false ]
}

rr_restore_abort_pre_mutation_stage() {
    local stage="$1" rollback=""
    rollback="$stage/rollback"
    # No configuration or database has been replaced yet.  Restart exactly
    # the services that were running when the transaction began.
    rr_restore_require_effective_gates_or_isolate || return 1
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || return 1
    if ! rr_restore_resume_snapshot_writers "$rollback"; then
        if ! rr_restore_close_runtime_ready_gate; then
            printf 'READY 无法清除且防火墙隔离无法证明；保留恢复证据：%s\n' \
                "$stage" >&2
        fi
        rr_restore_freeze_writers >/dev/null 2>&1 || true
        # Keep this distinct from a failed full rollback: the snapshot may be
        # incomplete in `freezing`/`frozen`, so a later recovery must never
        # clear the live tree and apply that partial snapshot.
        rr_restore_write_phase "$stage" pre_recovery_failed || true
        printf '恢复事务在写入前中断，自动恢复服务失败；证据已保留在 %s。\n' "$stage" >&2
        return 1
    fi
    if ! rr_restore_publish_terminal_phase "$stage" aborted; then
        # READY is valid only for a durably terminal transaction. Re-isolate
        # if the host-wide sync or terminal phase publication fails.
        if ! rr_restore_close_runtime_ready_gate; then
            printf 'READY 无法清除且防火墙隔离无法证明；保留恢复证据：%s\n' \
                "$stage" >&2
        fi
        rr_restore_freeze_writers >/dev/null 2>&1 || true
        return 1
    fi
    rr_restore_finalize_terminal_stage "$stage"
}

rr_restore_rollback_stage() {
    local stage="$1" rollback="" failed=false claim_result=1
    rollback="$stage/rollback"
    [ -d "$rollback/rootfs" ] && [ -f "$rollback/complete" ] && [ ! -L "$rollback/complete" ] || {
        printf '回滚快照未完整提交，拒绝清理当前运行目录：%s。\n' "$rollback" >&2
        return 1
    }
    if ! rr_restore_close_runtime_ready_gate; then
        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true
        return 1
    fi
    if ! rr_restore_write_phase "$stage" rolling_back; then
        # READY has already been cleared, but candidate processes may have
        # crossed it earlier.  A failed phase rename/fsync must still isolate
        # every managed runtime using the durable rollback ownership evidence.
        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true
        printf '无法持久化回滚阶段；候选服务已重新隔离，证据保留在 %s。\n' \
            "$stage" >&2
        return 1
    fi
    if ! rr_restore_stop_managed_runtime "$rollback"; then
        rr_restore_write_phase "$stage" recovery_failed || true
        printf '无法停止候选运行服务；已保留回滚证据：%s。\n' "$stage" >&2
        return 1
    fi
    # Remove the candidate's boot symlink while its unit file is still
    # present.  The exact original enablement is restored after regenerating
    # the original runtime below.
    rr_restore_set_nexus_enablement false || failed=true
    rr_restore_remove_managed_fixed_tunnel || failed=true
    rr_restore_clear_derived_state || failed=true
    rr_restore_replace_target_ip_acme_state "$rollback" || failed=true
    rr_restore_clear_managed_tree || failed=true
    rr_restore_apply_tree "$rollback" full || failed=true
    rr_refresh_update_channel_constants || failed=true
    rr_restore_crontab "$rollback/crontab.txt" || failed=true
    rr_restore_regenerate_runtime_files || failed=true
    rr_restore_restore_nginx "$rollback" files || failed=true
    rr_restore_apply_cloudflared_snapshot "$rollback" || failed=true
    rr_restore_restore_firewall_snapshot "$rollback" || failed=true
    rr_restore_restore_nexus_enablement "$rollback" || failed=true
    rr_restore_rearm_target_ip_acme "$rollback" || failed=true
    if [ "$failed" = false ]; then
        # All original data, configuration, units, proxy files and firewall
        # rules are durable before any service is allowed through its gate.
        rr_restore_require_effective_gates_or_isolate || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_restore_restore_nginx "$rollback" activate || failed=true
        # A same-process signal trap can enter rollback while the successful
        # portable migration call still has RR_PORTABLE_RESTORE=1 in dynamic
        # scope.  Original-target recovery must never inherit that mode.
        RR_PORTABLE_RESTORE=0 RR_PORTABLE_UFW_AUTHORITY=0 \
            rr_restore_migrate_with_original_state "$rollback" \
            >/dev/null 2>&1 || failed=true
        # Migration may repair/install the current IP-certificate gate.  The
        # rollback contract is the exact pre-restore fixed-path state, including
        # a legacy 7.1 target on which both artifacts were absent.
        rr_restore_replay_nexus_gate_artifacts "$rollback" / || failed=true
        systemctl daemon-reload >/dev/null 2>&1 || failed=true
        rr_restore_require_effective_gates_or_isolate || failed=true
        # Transaction migration is contractually read-only for firewall state.
        # Verify that contract after services have been reconstructed; never
        # perform a second destructive clear/replay after they can be running.
        rr_restore_verify_firewall_snapshot "$rollback" || failed=true
        rr_restore_verify_ufw_program_exact "$rollback/firewall" || failed=true
        rr_restore_restore_nexus_enablement "$rollback" || failed=true
    fi
    if [ "$failed" = false ]; then
        if rr_restore_rollback_claims_cloudflared "$rollback"; then
            claim_result=0
        else
            claim_result=$?
        fi
        case "$claim_result" in
            0)
                rr_restore_fixed_cloudflared_unit_is_owned || failed=true
                if [ "$failed" = false ] && \
                   [ -f "$rollback/cloudflared_was_running" ]; then
                    systemctl start cloudflared.service >/dev/null 2>&1 || failed=true
                    rr_restore_unit_activity_matches cloudflared.service active || failed=true
                elif [ "$failed" = false ]; then
                    systemctl stop cloudflared.service >/dev/null 2>&1 || failed=true
                    rr_restore_unit_activity_matches cloudflared.service inactive || failed=true
                fi
                ;;
            1) ;;
            2|*) failed=true ;;
        esac
    fi
    if [ "$failed" = true ]; then
        if ! rr_restore_close_runtime_ready_gate; then
            printf 'READY 无法清除且防火墙隔离无法证明；保留恢复证据：%s\n' \
                "$stage" >&2
        fi
        # READY gates only service start.  A service that already crossed the
        # gate must be stopped explicitly if late verification or activation
        # fails, otherwise a partial firewall recovery could remain exposed.
        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true
        rr_restore_write_phase "$stage" recovery_failed || true
        printf '恢复原机状态时发生二次故障；证据已保留在 %s。\n' "$stage" >&2
        return 1
    fi
    if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then
        if ! rr_restore_close_runtime_ready_gate; then
            printf 'READY 无法清除且防火墙隔离无法证明；保留恢复证据：%s\n' \
                "$stage" >&2
        fi
        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true
        return 1
    fi
    rr_restore_finalize_terminal_stage "$stage"
}

rr_restore_recover_active() {
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        return 0
    fi
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] || [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ]; then
        if [ "${RR_UPDATE_LOCK_OWNER:-0}" = 1 ] || \
           [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ]; then
            rr_restore_recover_active_with_firewall_lock
        else
            rr_run_without_inherited_update_lock_fds \
                rr_restore_recover_active_with_firewall_lock
        fi
        return $?
    fi
    local result=0
    rr_run_with_update_locks direct 0 \
        rr_restore_recover_active_with_firewall_lock || result=$?
    if [ "$result" -eq 75 ] || [ "$result" -eq 76 ]; then result=1; fi
    return "$result"
}

rr_restore_recover_active_with_firewall_lock() {
    local result=0
    rr_firewall_lock_acquire || return 1
    rr_restore_recover_active_locked || result=$?
    rr_firewall_lock_release || result=1
    return "$result"
}

rr_restore_recover_active_locked() {
    local stage="" phase=""
    rr_firewall_lock_is_held || return 1
    stage=$(rr_restore_active_stage) || return 1
    phase=$(rr_restore_read_exact_marker "$stage/phase") || return 1
    case "$phase" in
        freezing|frozen|prepared|pre_recovery_failed)
            rr_restore_abort_pre_mutation_stage "$stage" || return 1
            rm -rf -- "$stage"
            ;;
        committed|rolled_back|aborted)
            rr_restore_finalize_terminal_stage "$stage" || return 1
            rm -rf -- "$stage"
            ;;
        mutating|cleared|applied|migrating|rolling_back|recovery_failed)
            rr_restore_rollback_stage "$stage" || return 1
            rm -rf -- "$stage"
            ;;
        ""|*) return 1 ;;
    esac
}

rr_restore_test_phase() {
    local phase="$1"
    [ "${RR_TEST_FAULTS:-0}" = 1 ] || return 0
    if [ "${RR_TEST_FAIL_PHASE:-}" = "$phase" ]; then
        return 1
    fi
    if [ "${RR_TEST_CRASH_PHASE:-}" = "$phase" ]; then
        kill -KILL "$$"
    fi
}

rr_restore_estimate_snapshot_bytes() {
    python3 - \
        /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive \
        /etc/rr-update /etc/rr-cloudflared /var/lib/rr-nexus/remote.key \
        /var/lib/rr-nexus/nexus.db /var/lib/rr-nexus/nexus.db-wal \
        /usr/local/bin/auto_update_sub.py \
        /etc/systemd/system/sing-box.service \
        /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/argo-rr-health.service \
        /etc/systemd/system/argo-rr-health.timer \
        /etc/systemd/system/cloudflared.service \
        /etc/systemd/system/rr-nexus-ip-acme.service \
        /etc/systemd/system/rr-nexus-ip-acme.timer \
        /var/lib/rr-nexus/ip-acme /var/www/rr-nexus-ip-acme \
        /usr/local/lib/rr-vps/nexus-ip-cert-gate \
        /usr/local/lib/rr-vps/lego /usr/local/lib/rr-vps/lego.install \
        /etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf \
        /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf \
        /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf <<'PY'
import os
import stat
import sys

maximum = 2 * 1024**3
count = 0
total = 0
stack = list(dict.fromkeys(sys.argv[1:]))
seen = set()
while stack:
    path = stack.pop()
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        continue
    identity = (info.st_dev, info.st_ino)
    if identity in seen:
        continue
    seen.add(identity)
    count += 1
    if count > 10_000:
        raise SystemExit("target rollback snapshot has too many members")
    if stat.S_ISREG(info.st_mode):
        total += info.st_size
    elif stat.S_ISDIR(info.st_mode):
        with os.scandir(path) as entries:
            stack.extend(entry.path for entry in entries)
    elif stat.S_ISLNK(info.st_mode):
        total += info.st_size
    else:
        raise SystemExit("target rollback snapshot contains a special file")
    if total > maximum:
        raise SystemExit("target rollback snapshot exceeds the size limit")

# SQLite backup and filesystem metadata can temporarily exceed the exact sum.
# Reserve 25%, with a 64 MiB floor, before decrypting or stopping any writer.
print(total + max(64 * 1024**2, total // 4))
PY
}

rr_restore_backup() (
    local result=0
    # Keep one lock order everywhere: the shared update lock is outermost and
    # the firewall transaction lock is acquired by its delegated callback.
    # An updater may already own the update lock before reconciling firewall
    # state, so taking these in the reverse order could create an AB/BA wait.
    rr_run_with_update_locks direct 0 rr_restore_backup_with_firewall_lock "$@" || result=$?
    if [ "$result" -eq 75 ]; then
        printf '另一个更新、备份恢复或迁移事务正在运行。\n' >&2
        result=1
    fi
    [ "$result" -ne 76 ] || result=1
    return "$result"
)

rr_restore_backup_with_firewall_lock() {
    local result=0
    rr_firewall_lock_acquire || return 1
    rr_restore_backup_locked "$@" || result=$?
    rr_firewall_lock_release || result=1
    return "$result"
}

rr_restore_preflight_cloudflared_target() {
    local imported_token="$1" load_state="" service_file=""
    local target_fixed=false token_present=false service_present=false
    service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    load_config_with_defaults >/dev/null 2>&1 || return 1
    [ "${TUNNEL_MODE:-1}" != 2 ] || target_fixed=true
    if [ -e "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ] || \
       [ -L "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        token_present=true
    fi
    rr_restore_unit_load_state_read cloudflared.service load_state || return 1
    if [ -e "$service_file" ] || [ -L "$service_file" ] || \
       [ "$load_state" != not-found ]; then
        service_present=true
    fi
    if [ "$target_fixed" = true ] || [ "$token_present" = true ]; then
        rr_restore_fixed_cloudflared_unit_is_owned || {
            printf '%s\n' \
                '目标 Cloudflared 的配置、Token、Unit 或有效 systemd 身份不符合 RR 固定隧道形状；恢复尚未写入任何门禁或服务文件。' >&2
            return 1
        }
        return 0
    fi
    if [ -s "$imported_token" ] && [ "$service_present" = true ]; then
        printf '%s\n' \
            '目标服务器已有非 RR 管理的 cloudflared 服务；为避免覆盖其他隧道，恢复尚未写入任何门禁或服务文件。' >&2
        return 1
    fi
}

rr_restore_backup_locked() {
    local input="${1:-}" stage="" archive="" rollback="" result=1 backup_format=""
    local restore_live_fd="" snapshot_tmp="" rollback_reserve="" cloud_load_state=""
    local cloudflared_service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local commit_result=1 portable_ufw_authority=0 firewall_raw_state=0
    local portable_firewall_needs_persist=false
    local singbox_was_running=false singbox_was_enabled=false nexus_was_running=false
    local health_timer_was_enabled=false health_timer_was_running=false
    local cloudflared_was_running=false cloudflared_was_enabled=false
    [ -r "$input" ] || { printf '找不到备份文件：%s\n' "$input" >&2; return 2; }
    rr_ensure_resilience_dependencies || { printf '无法安装加密恢复所需组件。\n' >&2; return 1; }
    rr_backup_prepare_work_dir || {
        printf '备份工作目录的所有者、权限或路径不安全。\n' >&2
        return 1
    }
    RR_UPDATE_LOCK_HELD=1
    RR_RESTORE_LOCK_HELD=1
    rr_restore_recover_active || return 1
    rr_backup_prune_stale_stages || return 1
    rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || return 1
    rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || return 1
    rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || return 1
    stage=$(mktemp -d "$RR_BACKUP_WORK_DIR/restore.XXXXXX") || return 1
    chmod 700 "$stage" && rr_restore_stage_is_safe "$stage" || { rm -rf "$stage"; return 1; }
    # Before active/watchdog publication this stage contains plaintext but no
    # target mutation.  Signals may delete it directly; the later transaction
    # trap replaces this handler with durable recovery.
    trap 'rm -rf -- "$stage"; exit 143' HUP INT TERM
    archive="$stage/payload.tar.gz"
    rollback="$stage/rollback"
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_crypto decrypt "$input" "$archive"
    result=$?
    unset RR_BACKUP_PASSPHRASE
    if [ "$result" -ne 0 ]; then
        rm -rf "$stage"
        return 1
    fi
    rollback_reserve=$(rr_restore_estimate_snapshot_bytes) || {
        rm -rf "$stage"
        trap - HUP INT TERM
        return 1
    }
    if ! PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_archive \
        extract "$archive" "$stage" --extra-reserve-bytes "$rollback_reserve"; then
        rm -rf "$stage"
        trap - HUP INT TERM
        return 1
    fi
    [ -s "$stage/payload/metadata.json" ] && [ -s "$stage/payload/manifest.sha256" ] || { rm -rf "$stage"; return 1; }
    [ "$(stat -c %s "$stage/payload/manifest.sha256" 2>/dev/null || printf 0)" -le 52428800 ] || { rm -rf "$stage"; return 1; }
    jq -e '(.format == 1 or .format == 2) and .product == "RR-vps"' "$stage/payload/metadata.json" >/dev/null || { rm -rf "$stage"; return 1; }
    backup_format=$(jq -r '.format' "$stage/payload/metadata.json")
    [ "$(jq -r '.manifest_sha256 // empty' "$stage/payload/metadata.json")" = \
      "$(sha256sum "$stage/payload/manifest.sha256" | awk '{print $1}')" ] || { rm -rf "$stage"; return 1; }
    rr_restore_verify_manifest "$stage/payload" "$backup_format" || { rm -rf "$stage"; return 1; }
    rr_restore_reject_portable_ip_acme_payload "$stage/payload" || {
        rm -rf "$stage"
        return 1
    }
    rr_restore_validate_portable_config "$stage/payload/rootfs/etc/argo_vmess.conf" || { rm -rf "$stage"; return 1; }
    if [ -e "$stage/payload/rootfs/etc/rr-nexus/nexus.json" ] && \
       [ ! -s "$stage/payload/rootfs/var/lib/rr-nexus/nexus.db" ]; then
        printf '备份包含 Nexus 配置但缺少有效数据库，已拒绝恢复。\n' >&2
        rm -rf "$stage"
        return 1
    fi
    if [ -e "$stage/payload/rootfs/var/lib/rr-nexus/nexus.db" ]; then
        rr_backup_sqlite_validate \
            "$stage/payload/rootfs/var/lib/rr-nexus/nexus.db" || { rm -rf "$stage"; return 1; }
    fi
    rr_restore_validate_target_ownership || { rm -rf "$stage"; return 1; }
    rr_restore_validate_target_snapshot_shape || {
        rm -rf "$stage"
        return 1
    }
    rr_restore_preflight_cloudflared_target \
        "$stage/payload/rootfs/etc/rr-cloudflared/token" || {
        rm -rf "$stage"
        return 1
    }
    rr_restore_preflight_gate_dropin_order || {
        rm -rf "$stage"
        return 1
    }
    rr_restore_preflight_portable_naive_target \
        "$stage/payload/rootfs/etc/argo_vmess.conf" \
        "$stage/payload" || { rm -rf "$stage"; return 1; }
    rr_restore_preflight_portable_subscription_target || {
        rm -rf "$stage"
        return 1
    }
    # These fragments are deleted or replaced later in the transaction. A
    # persistent administrator mask cannot be represented by the portable
    # data archive, so reject it before any target token/config is migrated.
    rr_restore_reject_unrestorable_unit_states || { rm -rf "$stage"; return 1; }
    if [ -e "$NEXUS_CONFIG_FILE" ] || [ -L "$NEXUS_CONFIG_FILE" ]; then
        rr_backup_sqlite_validate "$NEXUS_DB_FILE" || {
            printf '目标 Nexus 数据库缺失、损坏或结构不匹配，恢复未开始。\n' >&2
            rm -rf "$stage"
            return 1
        }
    fi
    rr_restore_migrate_legacy_fixed_token || { rm -rf "$stage"; return 1; }
    mkdir -p "$rollback/rootfs" || { rm -rf "$stage"; return 1; }
    rr_restore_capture_unit_activity_state sing-box singbox_was_running || { rm -rf "$stage"; return 1; }
    rr_restore_capture_unit_file_state sing-box singbox_was_enabled || { rm -rf "$stage"; return 1; }
    rr_restore_capture_unit_activity_state rr-nexus nexus_was_running || { rm -rf "$stage"; return 1; }
    [ "$singbox_was_running" = false ] || : > "$rollback/singbox_was_running" || { rm -rf "$stage"; return 1; }
    [ "$singbox_was_enabled" = false ] || : > "$rollback/singbox_was_enabled" || { rm -rf "$stage"; return 1; }
    [ "$nexus_was_running" = false ] || : > "$rollback/nexus_was_running" || { rm -rf "$stage"; return 1; }
    if subscription_server_running; then
        : > "$rollback/subscription_was_running" || { rm -rf "$stage"; return 1; }
    fi
    load_config_with_defaults >/dev/null 2>&1 || true
    if expected_argo_tunnel_running >/dev/null 2>&1; then
        : > "$rollback/argo_was_running" || { rm -rf "$stage"; return 1; }
    fi
    rr_restore_capture_unit_file_state argo-rr-health.timer health_timer_was_enabled || { rm -rf "$stage"; return 1; }
    rr_restore_capture_unit_activity_state argo-rr-health.timer health_timer_was_running || { rm -rf "$stage"; return 1; }
    [ "$health_timer_was_enabled" = false ] || : > "$rollback/health_timer_was_enabled" || { rm -rf "$stage"; return 1; }
    [ "$health_timer_was_running" = false ] || : > "$rollback/health_timer_was_running" || { rm -rf "$stage"; return 1; }
    rr_restore_capture_target_network "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_capture_target_nexus_state "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_capture_target_ip_acme_state "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_snapshot_nginx "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_preflight_cloudflared_target \
        "$stage/payload/rootfs/etc/rr-cloudflared/token" || { rm -rf "$stage"; return 1; }
    load_config_with_defaults >/dev/null 2>&1 || { rm -rf "$stage"; return 1; }
    if [ "${TUNNEL_MODE:-1}" = 2 ]; then
        rr_restore_fixed_cloudflared_unit_is_owned || { rm -rf "$stage"; return 1; }
        rr_restore_capture_unit_activity_state cloudflared.service \
            cloudflared_was_running || { rm -rf "$stage"; return 1; }
        rr_restore_capture_unit_file_state cloudflared.service \
            cloudflared_was_enabled || { rm -rf "$stage"; return 1; }
        cp -p -- "$cloudflared_service_file" \
            "$rollback/cloudflared.service" || { rm -rf "$stage"; return 1; }
        rr_restore_write_cloudflared_claim "$rollback" || { rm -rf "$stage"; return 1; }
        [ "$cloudflared_was_running" = false ] || : > "$rollback/cloudflared_was_running" || { rm -rf "$stage"; return 1; }
        [ "$cloudflared_was_enabled" = false ] || : > "$rollback/cloudflared_was_enabled" || { rm -rf "$stage"; return 1; }
    fi

    # Install recovery and publish the active transaction before stopping a
    # single writer.  A SIGKILL in the freeze/snapshot window can then restart
    # the untouched original runtime instead of leaving every service down.
    rr_restore_prepare_recovery_unit || { rm -rf "$stage"; return 1; }
    rr_restore_write_phase "$stage" freezing || { rm -rf "$stage"; return 1; }
    rr_secure_lock_prepare "$RR_RESTORE_LIVE_LOCK_FILE" || { rm -rf "$stage"; return 1; }
    exec {restore_live_fd}>>"$RR_RESTORE_LIVE_LOCK_FILE" || { rm -rf "$stage"; return 1; }
    rr_secure_lock_fd_is_safe "$RR_RESTORE_LIVE_LOCK_FILE" "$restore_live_fd" || {
        exec {restore_live_fd}>&-
        rm -rf "$stage"
        return 1
    }
    flock -n "$restore_live_fd" || { exec {restore_live_fd}>&-; rm -rf "$stage"; return 1; }
    rr_restore_publish_marker "$RR_RESTORE_LIVE_MARKER" "$stage" || {
        exec {restore_live_fd}>&-
        rm -rf "$stage"
        return 1
    }
    rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$stage" || {
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        rm -rf -- "$stage"
        return 1
    }
    if ! rr_restore_start_watchdog; then
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        rm -rf -- "$stage"
        return 1
    fi
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$stage" || {
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        rm -rf -- "$stage"
        return 1
    }
    trap 'RR_RESTORE_LOCK_HELD=1; rr_restore_recover_active; rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true; rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true; exit 143' HUP INT TERM
    if ! rr_restore_test_phase freezing; then
        rr_restore_recover_active || true
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        return 1
    fi

    # Freeze writers before taking the rollback database snapshot.  Otherwise
    # a confirmed write between sqlite backup and service stop would vanish if
    # candidate migration later failed.
    rr_restore_freeze_writers || result=1
    if [ "$result" -eq 0 ]; then
        # A mount or permission boundary can change while the target writers
        # are being frozen.  Re-prove the exact snapshot source before cp -a.
        rr_restore_validate_target_snapshot_shape || result=1
    fi
    if [ "$result" -eq 0 ]; then
        rr_restore_write_phase "$stage" frozen || result=1
        rr_restore_test_phase frozen || result=1
    fi
    if [ "$result" -eq 0 ]; then
        rr_restore_snapshot_target_ip_acme_state "$rollback" || result=1
    fi
    for target in /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared \
        /var/lib/rr-nexus/remote.key /usr/local/bin/auto_update_sub.py \
        /etc/systemd/system/sing-box.service /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/argo-rr-health.service /etc/systemd/system/argo-rr-health.timer \
        /etc/systemd/system/rr-nexus-ip-acme.service \
        /etc/systemd/system/rr-nexus-ip-acme.timer \
        /usr/local/lib/rr-vps/lego /usr/local/lib/rr-vps/lego.install; do
        [ "$result" -eq 0 ] || break
        # Preserve dangling links in the rollback image as well.  Ownership
        # preflight rejects an unsafe CONFIG_FILE link, while other original
        # RR-managed links still need exact lstat-level rollback semantics.
        [ -e "$target" ] || [ -L "$target" ] || continue
        mkdir -p "$rollback/rootfs$(dirname "$target")" || { result=1; break; }
        cp -a -- "$target" "$rollback/rootfs$target" || { result=1; break; }
    done
    if [ "$result" -eq 0 ]; then
        rr_restore_capture_nexus_gate_artifacts "$rollback" || result=1
    fi
    if [ "$result" -eq 0 ] && \
       { [ -e "$NEXUS_CONFIG_FILE" ] || [ -e /var/lib/rr-nexus/nexus.db ]; }; then
        rr_backup_sqlite_consistent /var/lib/rr-nexus/nexus.db \
            "$rollback/rootfs/var/lib/rr-nexus/nexus.db" || result=1
    fi
    if [ "$result" -eq 0 ]; then
        rr_backup_capture_crontab "$rollback/crontab.txt" || result=1
    fi
    if [ "$result" -eq 0 ]; then
        rr_restore_capture_firewall_snapshot "$rollback" || result=1
    fi
    if [ "$result" -eq 0 ]; then
        # The rollback tree spans configuration, databases and firewall
        # evidence.  Publish `complete` only after all of it is durable.
        sync || result=1
    fi
    if [ "$result" -eq 0 ]; then
        snapshot_tmp="$rollback/.complete.$$"
        printf '%s\n' snapshot-v1 > "$snapshot_tmp" && chmod 600 "$snapshot_tmp" && \
            sync -f "$snapshot_tmp" && mv -f "$snapshot_tmp" "$rollback/complete" && \
            sync -f "$rollback" || result=1
        rm -f "$snapshot_tmp"
    fi
    if [ "$result" -eq 0 ]; then
        # The durable rollback is complete, but no target tree has been
        # cleared.  This final pre-mutation proof makes a changed mount or
        # privileged mode take the safe abort path, never recursive rollback.
        rr_restore_validate_target_snapshot_shape || result=1
    fi
    if [ "$result" -eq 0 ]; then
        rr_restore_write_phase "$stage" prepared || result=1
        rr_restore_test_phase prepared || result=1
    fi
    if [ "$result" -ne 0 ]; then
        rr_restore_recover_active || true
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        return 1
    fi

    printf '备份已完整验证。即将恢复配置、设备、额度、流量周期和密钥。\n'
    rr_restore_stop_managed_runtime "$rollback" || result=1
    if [ "$result" -ne 1 ]; then
        rr_restore_write_phase "$stage" mutating || result=1
        rr_restore_test_phase mutating || result=1
    fi
    if [ "$result" -ne 1 ]; then
        rr_restore_remove_managed_fixed_tunnel || result=1
    fi
    if [ "$result" -ne 1 ]; then
        rr_restore_clear_derived_state || result=1
    fi
    if [ "$result" -ne 1 ] && rr_restore_clear_managed_tree; then
        rr_restore_write_phase "$stage" cleared || result=1
        rr_restore_test_phase cleared || result=1
    else
        result=1
    fi
    if [ "$result" -ne 1 ] && rr_restore_apply_tree "$stage/payload" portable && \
       rr_restore_crontab "$stage/payload/crontab.txt" && \
       rr_restore_apply_target_network "$rollback" && \
       rr_restore_apply_target_nexus_state "$rollback" "$stage/payload" && \
       rr_restore_regenerate_runtime_files && \
       rr_restore_rearm_target_ip_acme "$rollback"; then
        if [ -s /var/lib/rr-nexus/nexus.db ] && \
           sqlite3 /var/lib/rr-nexus/nexus.db \
             "UPDATE server_traffic_policy SET last_interface='',last_rx_counter=NULL,last_tx_counter=NULL WHERE id=1;" \
             >/dev/null 2>&1; then
            :
        elif [ -s /var/lib/rr-nexus/nexus.db ] && \
             sqlite3 /var/lib/rr-nexus/nexus.db \
               "SELECT 1 FROM sqlite_master WHERE type='table' AND name='server_traffic_policy';" \
               2>/dev/null | grep -q '^1$'; then
            result=1
        fi
        rr_restore_write_phase "$stage" applied || result=1
        rr_restore_test_phase applied || result=1
    else
        result=1
    fi
    if [ "$result" -ne 1 ]; then
        rr_restore_write_phase "$stage" migrating || result=1
        [ ! -f "$rollback/firewall/ufw.enabled" ] || portable_ufw_authority=1
        [ "$result" -ne 1 ] && \
            rr_restore_verify_firewall_pre_mutation_snapshot "$rollback" || result=1
        [ "$result" -ne 1 ] && \
            rr_restore_candidate_ufw_is_disjoint "$rollback" || result=1
        [ "$result" -ne 1 ] && \
            rr_restore_candidate_netfilter_is_disjoint "$rollback" || result=1
        [ "$result" -ne 1 ] && \
            rr_restore_candidate_hop_persistence_is_available || result=1
        if [ "$result" -ne 1 ]; then
            if rr_restore_firewall_snapshot_has_managed_raw_rules \
                "$rollback/firewall"; then
                portable_firewall_needs_persist=true
            else
                firewall_raw_state=$?
                [ "$firewall_raw_state" -eq 1 ] || result=1
            fi
        fi
        [ "$result" -ne 1 ] && \
            rr_restore_clear_managed_firewall "$rollback/firewall" || result=1
        if [ "$result" -ne 1 ] && \
           [ "$portable_firewall_needs_persist" = true ]; then
            save_firewall || result=1
        fi
        [ "$result" -ne 1 ] && \
            rr_restore_firewall_backend_states_match "$rollback/firewall" || result=1
        if [ "$result" -ne 1 ]; then
            # The durable target snapshot and watchdog are already active, and
            # managed services remain behind the restore gate.  Reconcile the
            # imported configuration's desired RR rules before migration; the
            # transaction-mode migration below then validates them read-only.
            RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 \
                RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" \
                open_configured_firewall || result=1
            [ "$result" -ne 1 ] && \
                rr_restore_firewall_backend_states_match "$rollback/firewall" || result=1
        fi
        if [ "$result" -ne 1 ]; then
            rr_restore_require_effective_gates_or_isolate || result=1
        fi
        if [ "$result" -ne 1 ]; then
            if [ -f "$rollback/target_rr_was_present" ]; then
                RR_PORTABLE_RESTORE=1 \
                    RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" \
                    rr_restore_migrate_with_original_state "$rollback" || result=1
                [ "$result" -ne 1 ] && \
                    rr_restore_finalize_original_service_state "$rollback" || result=1
            else
                RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 \
                    RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" \
                    post_update_migrate || result=1
                [ "$result" -ne 1 ] && \
                    rr_restore_finalize_nexus_enablement "$rollback" || result=1
            fi
        fi
        rr_restore_test_phase migrated || result=1
    fi
    if [ "$result" -ne 1 ]; then
        if rr_restore_commit_candidate "$stage"; then
            commit_result=0
        else
            commit_result=$?
        fi
    fi

    if [ "$commit_result" -eq 0 ]; then
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        if ! rm -rf -- "$stage"; then
            printf '恢复已提交，但临时目录清理失败；下次备份/恢复会重试清理：%s。\n' \
                "$stage" >&2
            return 1
        fi
        printf '恢复完成：已根据目标服务器网络、端口、证书和防火墙重新生成运行配置。\n'
        return 0
    fi
    if [ "$commit_result" -eq 2 ]; then
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        printf '恢复候选可能已经提交；已禁止回滚并保留证据。请运行 rr --recover-restore：%s。\n' \
            "$stage" >&2
        return 1
    fi

    printf '恢复后健康检查失败，正在恢复本机原状态…\n' >&2
    if rr_restore_rollback_stage "$stage"; then
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        rm -rf -- "$stage"
    else
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || true
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        exec {restore_live_fd}>&-
        trap - HUP INT TERM
        printf '自动回滚未完整完成；请保留机器并运行 rr --recover-restore。\n' >&2
    fi
    return 1
}

rr_update_preflight() {
    local ok=true free_kb="" db_state="not_installed" config_state="not_installed" lock_state="available" summary=""
    check_supported_os >/dev/null 2>&1 || ok=false
    for command_name in bash awk sed grep sha256sum tar find stat python3 flock systemctl jq sqlite3; do
        command -v "$command_name" >/dev/null 2>&1 || ok=false
    done
    free_kb=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -ge 262144 ] || ok=false
    if [ -r /var/lib/rr-nexus/nexus.db ]; then
        db_state=$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA quick_check;' 2>/dev/null || echo failed)
        [ "$db_state" = ok ] || ok=false
    fi
    if [ -s /etc/sing-box/config.json ] && [ -x "$SINGBOX_BIN" ]; then
        if "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            config_state=ok
        else
            config_state=failed
            ok=false
        fi
    fi
    if ! (
        rr_secure_lock_prepare "$RR_RESTORE_LOCK_FILE" &&
        exec 9>>"$RR_RESTORE_LOCK_FILE" &&
        rr_secure_lock_fd_is_safe "$RR_RESTORE_LOCK_FILE" 9 &&
        flock -n 9
    ); then
        lock_state=busy
        ok=false
    fi
    if [ "$ok" = true ]; then
        summary="系统、磁盘、数据库、配置和更新锁均通过"
    else
        summary="预检未通过；请运行 rr doctor 查看并修复"
    fi
    jq -cn --argjson ok "$ok" --arg summary "$summary" --arg channel "${RR_UPDATE_CHANNEL:-stable}" \
        --arg disk_free_mb "$(( ${free_kb:-0} / 1024 ))" --arg database "$db_state" \
        --arg singbox_config "$config_state" --arg update_lock "$lock_state" \
        '{ok:$ok,summary:$summary,channel:$channel,disk_free_mb:($disk_free_mb|tonumber),database:$database,singbox_config:$singbox_config,update_lock:$update_lock}'
    [ "$ok" = true ]
}

rr_set_update_channel() {
    local channel="${1:-}" temporary=""
    case "$channel" in stable|beta) ;; *) printf '更新通道只能是 stable 或 beta。\n' >&2; return 2 ;; esac
    mkdir -p /etc/rr-update || return 1
    temporary=$(mktemp /etc/rr-update/.channel.XXXXXX) || return 1
    if ! printf '%s\n' "$channel" > "$temporary" || ! chmod 600 "$temporary" || \
       ! mv -f "$temporary" /etc/rr-update/channel; then
        rm -f "$temporary"
        return 1
    fi
    printf '更新通道已切换为 %s；下次检查更新时生效。\n' "$channel"
}
