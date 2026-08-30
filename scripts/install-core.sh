#!/bin/bash

# shellcheck disable=SC2034 # Contract marker consumed by repository validation.
RR_BOOTSTRAP_VERSION="1"
RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_RELEASE_TAG="v7.1.1"
RR_BRANCH="main"
[ -r /etc/rr-update/channel ] && [ "$(tr -d '[:space:]' < /etc/rr-update/channel)" = beta ] && RR_BRANCH="beta"
RR_SOURCE_REF="$RR_RELEASE_TAG"
[ "$RR_BRANCH" = beta ] && RR_SOURCE_REF=beta
RR_REF_KIND=tags
[ "$RR_BRANCH" = beta ] && RR_REF_KIND=heads
RR_RAW_BASE="https://raw.githubusercontent.com/${RR_REPOSITORY}/refs/${RR_REF_KIND}/${RR_SOURCE_REF}"
RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"
RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@${RR_SOURCE_REF}"
RR_MANIFEST_URL="${RR_RAW_BASE}/manifest.sha256"
RR_LIB_DIR="/usr/local/lib/rr"
RR_LAUNCHER="/usr/local/bin/rr"
RR_MODE="${1:-install}"

RR_GITHUB_MIRROR="${RR_GITHUB_MIRROR:-}"

STAGE_ROOT=""
PAYLOAD_DIR=""
BACKUP_DIR=""
NEW_RUNTIME=""
OLD_RUNTIME=""
NEW_LAUNCHER=""
RUNTIME_REPLACED=false
TRANSACTION_ACTIVE=false
ROLLBACK_FAILED=false
RR_TX_ROOT="/var/lib/rr-update"
RR_ACTIVE_TX="${RR_TX_ROOT}/active"
RR_SUBSCRIPTION_SAFE_VERSION="7.1.1"
RR_RECOVERY_HELPER="${RR_RECOVERY_HELPER:-/usr/local/sbin/rr-update-recover}"
RR_UPDATE_EXTERNAL_HELPER="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
TX_DIR=""
KEEP_TRANSACTION=false
UPDATE_LOCK_FD=""
LEGACY_UPDATE_LOCK_FD=""
RR_HEALTH_MONITOR_FROZEN=false
RR_HEALTH_TIMER_WAS_ENABLED=false
RR_HEALTH_TIMER_WAS_ACTIVE=false
RR_HEALTH_SERVICE_WAS_ACTIVE=false
RR_HEALTH_STATE_CAPTURED=false
RR_UPDATE_WRITERS_FROZEN=false
RR_UPDATE_MAINTENANCE_ACTIVE=false
RR_SINGBOX_WAS_ACTIVE=false
RR_SINGBOX_WAS_ENABLED=false
RR_NEXUS_WAS_ACTIVE=false
RR_NEXUS_WAS_ENABLED=false
RR_SUBSCRIPTION_WAS_ACTIVE=false
RR_HEALTH_TIMER_FILE="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"
RR_LEGACY_UPDATE_LOCK_FILE="${RR_LEGACY_UPDATE_LOCK_FILE:-/run/lock/rr-update.lock}"
RR_LEGACY_UPDATE_BRIDGE_FILE="${RR_LEGACY_UPDATE_BRIDGE_FILE:-/run/rr-vps/legacy-update-bridge}"
RR_UPDATE_MAINTENANCE_FILE="${RR_UPDATE_MAINTENANCE_FILE:-/run/rr-vps/update-maintenance}"
RR_COMMITTED_SETTLED_NAME="committed-settled"
RR_COMMITTED_SETTLED_VALUE="rr-update-committed-settled-v1"

rr_error() {
    echo "[RR-vps] $*" >&2
}

rr_prepare_update_lock_file() {
    local lock_file="${1:-$RR_UPDATE_LOCK_FILE}"
    local lock_dir="" canonical=""
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

rr_update_lock_fd_is_safe() {
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
    # 7.1.0 normally left this file as 0644.  Preserve that inode exactly,
    # but reject special bits, execute bits, and group/other write access.
    (( (mode_value & 07133) == 0 ))
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
    # /run/lock may be 1777.  A world-writable compatibility directory is
    # acceptable only when the sticky bit prevents unprivileged replacement.
    (( (mode_value & 06000) == 0 )) || return 1
    if (( (mode_value & 0002) != 0 && (mode_value & 01000) == 0 )); then
        return 1
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
    [ "$path_identity" = "$fd_identity" ] && \
        [ "$path_identity_after" = "$fd_identity" ] || return 1
    IFS=: read -r _ _ owner_uid owner_gid mode links <<<"$fd_identity"
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] && [ "$links" = 1 ] || return 1
    rr_legacy_update_lock_mode_is_safe "$mode"
}

rr_trusted_installed_runtime_version() {
  (
    local runtime_file="$RR_LIB_DIR/modules/00-runtime.sh"
    local directory="" canonical="" owner="" group="" mode="" mode_value=0
    local runtime_fd="" shell_pid="${BASHPID:-$$}" fd_path=""
    local path_identity="" fd_identity="" line="" count=0 version=""
    local -a runtime_lines=()
    for directory in "$RR_LIB_DIR" "$RR_LIB_DIR/modules"; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
        [ "$canonical" = "$directory" ] || return 1
        IFS=: read -r owner group mode < <(
            stat -c '%u:%g:%a' -- "$directory" 2>/dev/null
        ) || return 1
        [ "$owner" = 0 ] && [ "$group" = 0 ] || return 1
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
    IFS=: read -r _ _ owner group mode _ <<<"$fd_identity"
    [ "$owner" = 0 ] && [ "$group" = 0 ] || return 1
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
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
    printf '%s\n' "$version"
  )
}

rr_prepare_legacy_update_bridge_parent() {
    local marker="${1:-$RR_LEGACY_UPDATE_BRIDGE_FILE}" parent="" canonical=""
    parent=$(dirname -- "$marker") || return 1
    if [ -e "$parent" ] || [ -L "$parent" ]; then
        [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
        [ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" = 0:0 ] || return 1
    else
        (umask 077; mkdir -p -- "$parent") || return 1
    fi
    canonical=$(readlink -f -- "$parent" 2>/dev/null) || return 1
    [ "$canonical" = "$parent" ] || return 1
    [ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" = 0:0 ] || return 1
    chmod 0700 -- "$parent" || return 1
    [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ]
}

rr_legacy_update_bridge_marker_is_safe() {
    (
        local marker="${1:-$RR_LEGACY_UPDATE_BRIDGE_FILE}" marker_fd=""
        local shell_pid="${BASHPID:-$$}" fd_path="" path_identity="" fd_identity=""
        local -a marker_lines=()
        rr_prepare_legacy_update_bridge_parent "$marker" || return 1
        [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
        exec {marker_fd}<"$marker" || return 1
        fd_path="/proc/$shell_pid/fd/$marker_fd"
        [ -e "$fd_path" ] || fd_path="/dev/fd/$marker_fd"
        path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$marker" 2>/dev/null) || return 1
        fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
        [ "$path_identity" = "$fd_identity" ] && \
            [[ "$fd_identity" == *:0:0:600:1 ]] && [ ! -L "$marker" ] || return 1
        mapfile -t marker_lines <&"$marker_fd"
        [ "${#marker_lines[@]}" -eq 1 ] && \
            [ "${marker_lines[0]}" = rr-legacy-update-bridge-v1 ] || return 1
        path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$marker" 2>/dev/null) || return 1
        [ "$path_identity" = "$fd_identity" ] && [ ! -L "$marker" ]
    )
}

rr_publish_legacy_update_bridge_marker() {
    local marker="${1:-$RR_LEGACY_UPDATE_BRIDGE_FILE}" parent="" temporary=""
    rr_prepare_legacy_update_bridge_parent "$marker" || return 1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        rr_legacy_update_bridge_marker_is_safe "$marker"
        return
    fi
    parent=$(dirname -- "$marker") || return 1
    temporary=$(mktemp "$parent/.legacy-update-bridge.XXXXXX") || return 1
    if ! printf '%s\n' rr-legacy-update-bridge-v1 > "$temporary" || \
       ! chmod 0600 -- "$temporary" || \
       [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$parent"; then
        rm -f -- "$temporary"
        return 1
    fi
    rr_legacy_update_bridge_marker_is_safe "$marker"
}

rr_legacy_public_lock_is_nonroot_noise() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}" owner=""
    [ -e "$lock_file" ] || [ -L "$lock_file" ] || return 1
    # GNU stat without -L inspects the directory entry itself.  Do not open,
    # read, follow, chmod, unlink, or otherwise treat public-path noise as
    # authoritative when no private bridge marker requires compatibility.
    owner=$(stat -c '%u' -- "$lock_file" 2>/dev/null) || return 1
    [ "$owner" != 0 ]
}

rr_promote_trusted_legacy_preoccupation() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    # This path is used only after a root-owned 7.1.0 runtime has been proven.
    # Bind every check and mutation to one opened inode: path-based chown/rm/mv
    # could race a genuine legacy updater and split the flock domain.
    python3 -I -S - "$lock_file" <<'PY'
import fcntl
import os
import stat
import sys

path = sys.argv[1]
parent = os.path.dirname(path)
name = os.path.basename(path)

def fail(code=1):
    raise SystemExit(code)

def same_inode(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)

def safe_root_lock(value):
    mode = stat.S_IMODE(value.st_mode)
    return (
        stat.S_ISREG(value.st_mode)
        and value.st_uid == 0
        and value.st_gid == 0
        and value.st_nlink == 1
        and mode & 0o7133 == 0
    )

if not parent or not name or not hasattr(os, "O_PATH"):
    fail()

directory_fd = os.open(
    parent,
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
)
entry_fd = exact_fd = None
try:
    directory_state = os.fstat(directory_fd)
    directory_mode = stat.S_IMODE(directory_state.st_mode)
    if (
        not stat.S_ISDIR(directory_state.st_mode)
        or directory_state.st_uid != 0
        or directory_state.st_gid != 0
        or directory_mode & 0o6000
        or (directory_mode & 0o002 and not directory_mode & 0o1000)
    ):
        fail()

    entry_fd = os.open(
        name,
        os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    entry_state = os.fstat(entry_fd)
    path_state = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        not same_inode(entry_state, path_state)
        or not stat.S_ISREG(entry_state.st_mode)
        or entry_state.st_nlink != 1
        or entry_state.st_uid == 0
    ):
        fail()

    exact_fd = os.open(
        f"/proc/self/fd/{entry_fd}",
        os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC,
    )
    exact_state = os.fstat(exact_fd)
    if not same_inode(entry_state, exact_state):
        fail()
    try:
        fcntl.flock(exact_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail()

    current_state = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not same_inode(current_state, exact_state):
        # Even a root-safe replacement is a different flock domain.  A legacy
        # process may already have opened the original inode and acquire it as
        # soon as this helper closes exact_fd, while Bash locks the replacement.
        # Fail closed and retry the complete acquisition instead.
        fail()

    os.fchmod(exact_fd, 0o600)
    os.fchown(exact_fd, 0, 0)
    os.fsync(exact_fd)
    os.fsync(directory_fd)
    final_fd_state = os.fstat(exact_fd)
    final_path_state = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not same_inode(final_fd_state, final_path_state) or not safe_root_lock(final_fd_state):
        fail()
finally:
    if exact_fd is not None:
        os.close(exact_fd)
    if entry_fd is not None:
        os.close(entry_fd)
    os.close(directory_fd)
PY
}

rr_acquire_legacy_update_lock() {
    local lock_file="${1:-$RR_LEGACY_UPDATE_LOCK_FILE}"
    local installed_version="" bridge_required=false marker_present=false
    local trusted_legacy_runtime=false
    LEGACY_UPDATE_LOCK_FD=""
    rr_prepare_legacy_update_bridge_parent "$RR_LEGACY_UPDATE_BRIDGE_FILE" || return 1
    if [ -e "$RR_LEGACY_UPDATE_BRIDGE_FILE" ] || \
       [ -L "$RR_LEGACY_UPDATE_BRIDGE_FILE" ]; then
        rr_legacy_update_bridge_marker_is_safe "$RR_LEGACY_UPDATE_BRIDGE_FILE" || {
            rr_error "7.1.0 兼容锁私有标记不安全，已拒绝安装/更新。"
            return 1
        }
        marker_present=true
        bridge_required=true
    elif installed_version=$(rr_trusted_installed_runtime_version 2>/dev/null); then
        if ! rr_version_ge "$installed_version" "$RR_SUBSCRIPTION_SAFE_VERSION"; then
            bridge_required=true
            trusted_legacy_runtime=true
        fi
    elif [ -e "$RR_LIB_DIR" ] || [ -L "$RR_LIB_DIR" ] || \
         [ -e "$RR_LAUNCHER" ] || [ -L "$RR_LAUNCHER" ]; then
        rr_error "检测到无法可信识别版本的既有安装，拒绝推断兼容锁状态。"
        return 1
    fi
    rr_legacy_update_lock_parent_is_safe "$lock_file" || return 1
    if [ "$bridge_required" = true ] && [ "$marker_present" != true ] &&
       [ "$trusted_legacy_runtime" = true ] &&
       rr_legacy_public_lock_is_nonroot_noise "$lock_file"; then
        if ! rr_promote_trusted_legacy_preoccupation "$lock_file"; then
            rr_error "无法安全接管低权限用户预占的 7.1.0 兼容锁，已拒绝安装/更新。"
            return 1
        fi
    fi
    if [ "$bridge_required" != true ]; then
        if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
            return 0
        fi
        if rr_legacy_public_lock_is_nonroot_noise "$lock_file"; then
            return 0
        fi
        # A safe/root-owned existing inode is authoritative evidence that an
        # old updater may still participate this boot.  Acquire it and publish
        # the private marker so every later runtime path keeps bridging it.
        bridge_required=true
    elif [ "$marker_present" = true ] && \
         [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        rr_error "7.1.0 兼容锁私有标记存在，但公共锁缺失；已安全拒绝。"
        return 1
    elif [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        # Closing the absent->legacy-start race requires publishing the old
        # name only while an old/unknown installed runtime requires the bridge.
        # Noclobber never truncates a concurrent creator; strict checks below
        # decide whether the winning inode is trustworthy.
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
    fi
    rr_legacy_update_lock_path_is_safe "$lock_file" || {
        rr_error "检测到不安全的 7.1.0 兼容锁，已拒绝安装/更新。"
        return 1
    }
    # Read-only opening is deliberate: an existing compatibility inode is
    # never truncated, chmodded, chowned, replaced, or unlinked.
    exec {LEGACY_UPDATE_LOCK_FD}<"$lock_file" || {
        LEGACY_UPDATE_LOCK_FD=""
        return 1
    }
    if ! rr_legacy_update_lock_fd_is_safe "$lock_file" "$LEGACY_UPDATE_LOCK_FD"; then
        exec {LEGACY_UPDATE_LOCK_FD}>&-
        LEGACY_UPDATE_LOCK_FD=""
        rr_error "7.1.0 兼容锁在打开时发生变化，已拒绝安装/更新。"
        return 1
    fi
    if ! flock -n "$LEGACY_UPDATE_LOCK_FD"; then
        exec {LEGACY_UPDATE_LOCK_FD}>&-
        LEGACY_UPDATE_LOCK_FD=""
        rr_error "另一个 7.1.0 安装/更新任务正在运行，本次未改动系统。"
        return 1
    fi
    if [ "$bridge_required" = true ] && [ "$marker_present" != true ] && \
       ! rr_publish_legacy_update_bridge_marker "$RR_LEGACY_UPDATE_BRIDGE_FILE"; then
        exec {LEGACY_UPDATE_LOCK_FD}>&-
        LEGACY_UPDATE_LOCK_FD=""
        rr_error "无法可信发布 7.1.0 兼容锁私有标记，已安全拒绝。"
        return 1
    fi
}

rr_close_inherited_installer_lock_fds() {
    local lock_fd=""
    lock_fd="${LEGACY_UPDATE_LOCK_FD:-}"
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        exec {lock_fd}>&-
    fi
    LEGACY_UPDATE_LOCK_FD=""
    lock_fd="${UPDATE_LOCK_FD:-}"
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
        exec {lock_fd}>&-
    fi
    UPDATE_LOCK_FD=""
}

rr_run_with_delegated_update_lock() {
    (
        # The installer parent remains the sole lock owner for the whole
        # transaction.  Delegated helpers are told not to reacquire, but their
        # process tree must not inherit either flock fd: a nohup child could
        # otherwise keep the transaction locked after the installer exits.
        rr_close_inherited_installer_lock_fds
        RR_UPDATE_LOCK_HELD=1 "$@"
    )
}

rr_freeze_health_monitor() {
    local attempt=0 timer_result=0 service_result=0
    local captured_timer_enabled="${RR_HEALTH_TIMER_WAS_ENABLED:-false}"
    local captured_timer_active="${RR_HEALTH_TIMER_WAS_ACTIVE:-false}"
    local captured_service_active="${RR_HEALTH_SERVICE_WAS_ACTIVE:-false}"
    if [ "${RR_HEALTH_STATE_CAPTURED:-false}" != true ]; then
        rr_capture_unit_file_state argo-rr-health.timer \
            captured_timer_enabled || return 1
        rr_capture_unit_activity_state argo-rr-health.timer \
            captured_timer_active || return 1
        rr_capture_unit_activity_state argo-rr-health.service \
            captured_service_active || return 1
        RR_HEALTH_TIMER_WAS_ENABLED="$captured_timer_enabled"
        RR_HEALTH_TIMER_WAS_ACTIVE="$captured_timer_active"
        RR_HEALTH_SERVICE_WAS_ACTIVE="$captured_service_active"
        RR_HEALTH_STATE_CAPTURED=true
    fi
    RR_HEALTH_MONITOR_FROZEN=true

    # A legacy runtime does not know about the shared transaction lock.  Stop
    # both the scheduler and an already-running oneshot before any installer
    # recovery or snapshot work, and wait until systemd confirms both exited.
    systemctl stop argo-rr-health.timer argo-rr-health.service >/dev/null 2>&1 || true
    while [ "$attempt" -lt 30 ]; do
        rr_unit_activity_matches argo-rr-health.timer inactive
        timer_result=$?
        rr_unit_activity_matches argo-rr-health.service inactive
        service_result=$?
        if [ "$timer_result" -eq 0 ] && [ "$service_result" -eq 0 ]; then
            return 0
        fi
        # Result 2 means the query failed or returned an unknown state.  That
        # is never proof that a writer stopped, so do not retry it as though it
        # were a normal activating/deactivating transition.
        if [ "$timer_result" -eq 2 ] || [ "$service_result" -eq 2 ]; then
            break
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    rr_error "无法冻结健康检查服务，已拒绝创建并发更新快照。"
    return 1
}

rr_resume_health_monitor_after_abort() {
    [ "$RR_HEALTH_MONITOR_FROZEN" = true ] || return 0
    if [ "$RR_HEALTH_TIMER_WAS_ENABLED" = true ] && \
       [ -f "$RR_HEALTH_TIMER_FILE" ]; then
        systemctl enable --now argo-rr-health.timer >/dev/null 2>&1 || return 1
    else
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    RR_HEALTH_MONITOR_FROZEN=false
}

rr_wait_unit_state() {
    local unit="$1" wanted="$2" attempt=0 state=0
    while [ "$attempt" -lt 50 ]; do
        rr_unit_activity_matches "$unit" "$wanted" && return 0
        state=$?
        # A valid but not-yet-final state may be retried.  A systemd bus/query
        # error or an unrecognised state is not evidence of inactivity.
        [ "$state" -eq 1 ] || return 1
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

rr_unit_activity_matches() {
    local unit="$1" wanted="$2" load_state="" active_state=""
    load_state=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || return 2
    active_state=$(systemctl show --property=ActiveState --value \
        "$unit" 2>/dev/null) || return 2
    case "$load_state:$active_state" in
        loaded:active|loaded:inactive|loaded:failed|loaded:activating|loaded:deactivating|\
        loaded:reloading|masked:inactive|masked:failed|not-found:inactive) ;;
        *) return 2 ;;
    esac
    case "$wanted:$load_state:$active_state" in
        active:loaded:active|\
        inactive:loaded:inactive|inactive:loaded:failed|\
        inactive:masked:inactive|inactive:masked:failed|\
        inactive:not-found:inactive) return 0 ;;
        active:*|inactive:*) return 1 ;;
        *) return 2 ;;
    esac
}

rr_unit_file_state_matches() {
    local unit="$1" wanted="$2" load_state="" unit_file_state=""
    load_state=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || return 2
    unit_file_state=$(systemctl show --property=UnitFileState --value \
        "$unit" 2>/dev/null) || return 2
    if [ "$load_state" = not-found ] && [ -z "$unit_file_state" ]; then
        unit_file_state=not-found
    fi
    case "$wanted:$load_state:$unit_file_state" in
        enabled:loaded:enabled|enabled:loaded:enabled-runtime|\
        disabled:loaded:disabled|disabled:loaded:static|\
        disabled:masked:masked|disabled:not-found:not-found) return 0 ;;
        enabled:loaded:*|enabled:masked:*|enabled:not-found:*|\
        disabled:loaded:*|disabled:masked:*|disabled:not-found:*) return 1 ;;
        *) return 2 ;;
    esac
}

rr_capture_unit_activity_state() {
    local unit="$1" output_name="$2" state=0
    if rr_unit_activity_matches "$unit" active; then
        printf -v "$output_name" '%s' true
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    rr_unit_activity_matches "$unit" inactive || return 1
    printf -v "$output_name" '%s' false
}

rr_capture_unit_file_state() {
    local unit="$1" output_name="$2" state=0
    if rr_unit_file_state_matches "$unit" enabled; then
        printf -v "$output_name" '%s' true
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    rr_unit_file_state_matches "$unit" disabled || return 1
    printf -v "$output_name" '%s' false
}

rr_quiesce_health_monitor_for_rollback() {
    local attempt=0 timer_load="" service_load="" timer_state=""
    local service_state="" timer_enabled_state="" service_enabled_state=""
    # Candidate migration may have re-enabled the timer after the original
    # snapshot freeze.  Revoke both scheduling and an in-flight oneshot before
    # touching any old runtime file; only observed final state is authoritative.
    timer_load=$(systemctl show --property=LoadState --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    service_load=$(systemctl show --property=LoadState --value \
        argo-rr-health.service 2>/dev/null) || return 1
    case "$timer_load" in loaded|masked|not-found) ;; *) return 1 ;; esac
    case "$service_load" in loaded|masked|not-found) ;; *) return 1 ;; esac
    case "$timer_load" in
        loaded) systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || return 1 ;;
        masked) systemctl stop argo-rr-health.timer >/dev/null 2>&1 || return 1 ;;
    esac
    case "$service_load" in
        loaded|masked) systemctl stop argo-rr-health.service >/dev/null 2>&1 || return 1 ;;
    esac
    while [ "$attempt" -lt 30 ]; do
        timer_load=$(systemctl show --property=LoadState --value \
            argo-rr-health.timer 2>/dev/null) || return 1
        service_load=$(systemctl show --property=LoadState --value \
            argo-rr-health.service 2>/dev/null) || return 1
        timer_state=$(systemctl show --property=ActiveState --value \
            argo-rr-health.timer 2>/dev/null) || return 1
        service_state=$(systemctl show --property=ActiveState --value \
            argo-rr-health.service 2>/dev/null) || return 1
        timer_enabled_state=$(systemctl show --property=UnitFileState --value \
            argo-rr-health.timer 2>/dev/null) || return 1
        service_enabled_state=$(systemctl show --property=UnitFileState --value \
            argo-rr-health.service 2>/dev/null) || return 1
        if [ "$timer_load" = not-found ] && [ -z "$timer_enabled_state" ]; then
            timer_enabled_state=not-found
        fi
        if [ "$service_load" = not-found ] && [ -z "$service_enabled_state" ]; then
            service_enabled_state=not-found
        fi
        case "$timer_load:$timer_state:$timer_enabled_state" in
            loaded:inactive:disabled|loaded:inactive:static|\
            loaded:failed:disabled|loaded:failed:static|\
            masked:inactive:masked|masked:failed:masked|\
            not-found:inactive:not-found) timer_state=safe ;;
            *) timer_state=unsafe ;;
        esac
        case "$service_load:$service_state:$service_enabled_state" in
            loaded:inactive:disabled|loaded:inactive:static|\
            loaded:failed:disabled|loaded:failed:static|\
            masked:inactive:masked|masked:failed:masked|\
            not-found:inactive:not-found) service_state=safe ;;
            *) service_state=unsafe ;;
        esac
        if [ "$timer_state" = safe ] && [ "$service_state" = safe ]; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    rr_error "无法严格冻结健康检查 timer/service，拒绝切回旧运行文件。"
    return 1
}

rr_set_private_marker() {
    local target="$1" parent=""
    parent=$(dirname -- "$target") || return 1
    (umask 077; : > "$target") && chmod 600 "$target" && \
        sync -f "$target" && sync -f "$parent"
}

rr_read_trusted_private_value() {
    local value_file="$1" value_fd="" shell_pid="${BASHPID:-$$}"
    local fd_path="" path_identity="" fd_identity="" value=""
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
    local transaction="$1" marker="" value=""
    marker="$transaction/$RR_COMMITTED_SETTLED_NAME"
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 1
    fi
    value=$(rr_read_trusted_private_value "$marker") || return 2
    [ "$value" = "$RR_COMMITTED_SETTLED_VALUE" ] || return 2
    return 0
}

rr_publish_committed_settled() {
    local transaction="$1" marker="" temporary="" state=0
    rr_transaction_dir_is_strict "$transaction" || return 1
    marker="$transaction/$RR_COMMITTED_SETTLED_NAME"
    if rr_committed_settled_state "$transaction"; then
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    temporary=$(umask 077; mktemp "$transaction/.${RR_COMMITTED_SETTLED_NAME}.XXXXXX") || return 1
    if ! printf '%s\n' "$RR_COMMITTED_SETTLED_VALUE" > "$temporary" ||
       ! chmod 0600 "$temporary" ||
       [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] ||
       ! sync -f "$temporary"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! mv -f -- "$temporary" "$marker"; then
        rm -f -- "$temporary" >/dev/null 2>&1 || true
        rr_committed_settled_state "$transaction" && return 2
        return 1
    fi
    # A post-rename failure is ambiguous: the marker is already visible even
    # when the directory entry has not yet been reported durable.  Preserve it
    # for recovery and distinguish this state from a definite pre-publication
    # failure so callers never assume the marker is absent.
    if ! sync -f "$transaction"; then
        rr_committed_settled_state "$transaction" && return 2
        return 1
    fi
    rr_committed_settled_state "$transaction" || return 1
    return 0
}

rr_write_transaction_format() {
    local target="$TX_DIR/transaction-format" temporary=""
    temporary="$TX_DIR/.transaction-format.$$"
    (umask 077; printf '2\n' > "$temporary") && chmod 600 "$temporary" && \
        sync -f "$temporary" && mv -f "$temporary" "$target" && \
        sync -f "$TX_DIR" && \
        [ "$(stat -c '%u:%g:%a:%h' "$target" 2>/dev/null)" = 0:0:600:1 ] && \
        [ "$(cat "$target" 2>/dev/null)" = 2 ]
}

rr_transaction_format_state() {
    local tx="" marker=""
    tx="${1:-$TX_DIR}"
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
    local backup="" marker=""
    backup="${1:-$BACKUP_DIR}"
    marker="$backup/external_state_required"
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$marker" 2>/dev/null)" = 0:0:600:1 ]
}

rr_snapshot_external_state() {
    [ -x "$RR_UPDATE_EXTERNAL_HELPER" ] && [ -f "$RR_UPDATE_EXTERNAL_HELPER" ] && \
        [ ! -L "$RR_UPDATE_EXTERNAL_HELPER" ] || return 1
    "$RR_UPDATE_EXTERNAL_HELPER" snapshot "$BACKUP_DIR" --tx-root "$RR_TX_ROOT" || return 1
    "$RR_UPDATE_EXTERNAL_HELPER" verify "$BACKUP_DIR" --tx-root "$RR_TX_ROOT" || return 1
    rr_set_private_marker "$BACKUP_DIR/external_state_required" || return 1
    rr_external_state_marker_is_safe "$BACKUP_DIR"
}

rr_install_restore_external_state_if_required() {
    local state=0
    if rr_transaction_format_state "$TX_DIR"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            rr_error "兼容恢复旧事务：该事务没有外部状态快照。"
            return 0
            ;;
        *)
            rr_error "事务格式标记损坏，拒绝跳过外部状态恢复。"
            return 1
            ;;
    esac
    rr_external_state_marker_is_safe "$BACKUP_DIR" || {
        rr_error "外部状态快照必需标记缺失或不安全。"
        return 1
    }
    [ -x "$RR_UPDATE_EXTERNAL_HELPER" ] && [ -f "$RR_UPDATE_EXTERNAL_HELPER" ] && \
        [ ! -L "$RR_UPDATE_EXTERNAL_HELPER" ] || return 1
    "$RR_UPDATE_EXTERNAL_HELPER" restore "$BACKUP_DIR" --tx-root "$RR_TX_ROOT" || return 1
    "$RR_UPDATE_EXTERNAL_HELPER" verify "$BACKUP_DIR" --tx-root "$RR_TX_ROOT"
}

rr_capture_update_writer_state() {
    local health_timer_enabled="${RR_HEALTH_TIMER_WAS_ENABLED:-false}"
    local health_timer_active="${RR_HEALTH_TIMER_WAS_ACTIVE:-false}"
    local health_service_active="${RR_HEALTH_SERVICE_WAS_ACTIVE:-false}"
    local singbox_active=false singbox_enabled=false
    local nexus_active=false nexus_enabled=false subscription_active=false

    if [ "${RR_HEALTH_STATE_CAPTURED:-false}" != true ]; then
        rr_capture_unit_file_state argo-rr-health.timer \
            health_timer_enabled || return 1
        rr_capture_unit_activity_state argo-rr-health.timer \
            health_timer_active || return 1
        rr_capture_unit_activity_state argo-rr-health.service \
            health_service_active || return 1
    fi

    rr_capture_unit_activity_state sing-box singbox_active || return 1
    rr_capture_unit_file_state sing-box singbox_enabled || return 1
    rr_capture_unit_activity_state rr-nexus nexus_active || return 1
    rr_capture_unit_file_state rr-nexus nexus_enabled || return 1
    rr_subscription_running && subscription_active=true

    # Publish the snapshot only after every systemd query was proved valid.
    # A late D-Bus failure must not leave a partially captured false state that
    # a retry could persist as authoritative recovery evidence.
    RR_HEALTH_TIMER_WAS_ENABLED="$health_timer_enabled"
    RR_HEALTH_TIMER_WAS_ACTIVE="$health_timer_active"
    RR_HEALTH_SERVICE_WAS_ACTIVE="$health_service_active"
    RR_HEALTH_STATE_CAPTURED=true
    RR_SINGBOX_WAS_ACTIVE="$singbox_active"
    RR_SINGBOX_WAS_ENABLED="$singbox_enabled"
    RR_NEXUS_WAS_ACTIVE="$nexus_active"
    RR_NEXUS_WAS_ENABLED="$nexus_enabled"
    RR_SUBSCRIPTION_WAS_ACTIVE="$subscription_active"
    return 0
}

rr_persist_update_writer_state() {
    local marker=""
    for marker in \
        "singbox_was_running:$RR_SINGBOX_WAS_ACTIVE" \
        "singbox_was_enabled:$RR_SINGBOX_WAS_ENABLED" \
        "nexus_was_running:$RR_NEXUS_WAS_ACTIVE" \
        "nexus_was_enabled:$RR_NEXUS_WAS_ENABLED" \
        "subscription_was_running:$RR_SUBSCRIPTION_WAS_ACTIVE" \
        "health_timer_was_enabled:$RR_HEALTH_TIMER_WAS_ENABLED" \
        "health_timer_was_running:$RR_HEALTH_TIMER_WAS_ACTIVE" \
        "health_service_was_running:$RR_HEALTH_SERVICE_WAS_ACTIVE"; do
        [ "${marker#*:}" = true ] || continue
        rr_set_private_marker "$BACKUP_DIR/${marker%%:*}" || return 1
    done
    rr_set_private_marker "$BACKUP_DIR/writer_state_complete"
}

rr_create_update_maintenance_marker() {
    local marker_tx="${1:-$TX_DIR}" marker_dir="" canonical="" temporary="" owner=""
    local owner_uid="" owner_gid="" mode="" mode_value=0
    [ -n "$marker_tx" ] || return 1
    marker_dir=$(dirname -- "$RR_UPDATE_MAINTENANCE_FILE") || return 1
    [ -d "$marker_dir" ] && [ ! -L "$marker_dir" ] || return 1
    canonical=$(readlink -f -- "$marker_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$marker_dir" ] || return 1
    IFS=: read -r owner_uid owner_gid mode < <(
        stat -c '%u:%g:%a' -- "$marker_dir" 2>/dev/null
    ) || return 1
    [ "$owner_uid" = 0 ] && [ "$owner_gid" = 0 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 07022) == 0 )) || return 1
    chmod 0700 -- "$marker_dir" || return 1
    [ "$(stat -c '%u:%g:%a' -- "$marker_dir" 2>/dev/null)" = 0:0:700 ] || return 1
    if [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || [ -L "$RR_UPDATE_MAINTENANCE_FILE" ]; then
        owner=$(rr_read_trusted_private_value "$RR_UPDATE_MAINTENANCE_FILE") || return 1
        [ "$owner" = "$marker_tx" ] || return 1
        sync -f "$RR_UPDATE_MAINTENANCE_FILE" || return 1
        sync -f "$marker_dir" || return 1
        owner=$(rr_read_trusted_private_value "$RR_UPDATE_MAINTENANCE_FILE") || return 1
        [ "$owner" = "$marker_tx" ] || return 1
        RR_UPDATE_MAINTENANCE_ACTIVE=true
        return 0
    fi
    temporary=$(mktemp "$marker_dir/.update-maintenance.XXXXXX") || return 1
    if ! chmod 600 "$temporary" || ! printf '%s\n' "$marker_tx" > "$temporary" || \
       ! sync -f "$temporary" || \
       ! mv -f "$temporary" "$RR_UPDATE_MAINTENANCE_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
    [ -f "$RR_UPDATE_MAINTENANCE_FILE" ] && [ ! -L "$RR_UPDATE_MAINTENANCE_FILE" ] && \
        [ "$(stat -c '%u:%g:%a:%h' "$RR_UPDATE_MAINTENANCE_FILE" 2>/dev/null)" = 0:0:600:1 ] && \
        sync -f "$RR_UPDATE_MAINTENANCE_FILE" && sync -f "$marker_dir" && \
        RR_UPDATE_MAINTENANCE_ACTIVE=true
}

rr_clear_update_maintenance_marker() {
    local marker_tx="${1:-$TX_DIR}" owner="" parent=""
    if [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] && [ ! -L "$RR_UPDATE_MAINTENANCE_FILE" ]; then
        return 0
    fi
    owner=$(rr_read_trusted_private_value "$RR_UPDATE_MAINTENANCE_FILE") || return 1
    [ "$owner" = "$marker_tx" ] || return 1
    parent=$(dirname -- "$RR_UPDATE_MAINTENANCE_FILE") || return 1
    rm -f -- "$RR_UPDATE_MAINTENANCE_FILE" && sync -f "$parent" && \
        RR_UPDATE_MAINTENANCE_ACTIVE=false
}

rr_freeze_update_writers() {
    RR_UPDATE_WRITERS_FROZEN=true
    systemctl stop rr-nexus sing-box >/dev/null 2>&1 || true
    rr_wait_unit_state rr-nexus inactive || return 1
    rr_wait_unit_state sing-box inactive || return 1
    rr_stop_subscription_servers || return 1
    rr_freeze_health_monitor || return 1
}

rr_restore_unit_state() {
    local unit="$1" active_marker="$2" enabled_marker="$3" load_state=""
    load_state=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || return 1
    case "$load_state" in loaded|masked|not-found) ;; *) return 1 ;; esac
    if [ -f "$enabled_marker" ]; then
        [ "$load_state" = loaded ] || return 1
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
        rr_unit_file_state_matches "$unit" enabled || return 1
    else
        if [ "$load_state" = loaded ]; then
            systemctl disable "$unit" >/dev/null 2>&1 || return 1
        fi
        rr_unit_file_state_matches "$unit" disabled || return 1
    fi
    if [ -f "$active_marker" ]; then
        [ "$load_state" = loaded ] || return 1
        systemctl restart "$unit" >/dev/null 2>&1 || return 1
        rr_wait_unit_state "$unit" active
    else
        case "$load_state" in
            loaded|masked) systemctl stop "$unit" >/dev/null 2>&1 || return 1 ;;
        esac
        rr_wait_unit_state "$unit" inactive
    fi
}

rr_resume_subscription_bounded() {
    local status=0
    if [ ! -f "$RR_LAUNCHER" ] || [ ! -x "$RR_LAUNCHER" ] || [ -L "$RR_LAUNCHER" ]; then
        rr_stop_subscription_servers >/dev/null 2>&1 || true
        rr_quiesce_health_monitor_for_rollback >/dev/null 2>&1 || true
        return 1
    fi
    (
        # Close both flock descriptors before exec so a surviving managed
        # subscription worker can never retain the install transaction locks.
        rr_close_inherited_installer_lock_fds
        timeout --kill-after=5 30 env RR_UPDATE_LOCK_HELD=1 \
            "$RR_LAUNCHER" --refresh-subscription
    ) >/dev/null 2>&1 || status=$?
    if [ "$status" -ne 0 ] || ! rr_subscription_running; then
        rr_stop_subscription_servers >/dev/null 2>&1 || true
        rr_quiesce_health_monitor_for_rollback >/dev/null 2>&1 || true
        return 1
    fi
}

rr_restore_committed_subscription_state() {
    local backup="${1:-$BACKUP_DIR}"
    if [ -f "$backup/subscription_was_running" ]; then
        rr_resume_subscription_bounded
        return $?
    fi
    rr_stop_subscription_servers || return 1
    ! rr_subscription_running
}

rr_reconcile_committed_writer_state() {
    local backup="${1:-$BACKUP_DIR}"
    rr_restore_committed_subscription_state "$backup" || return 1
    [ -f "$backup/runtime_did_not_exist" ] || \
        rr_verify_update_writer_state "$backup"
}

rr_restart_health_service_bounded() {
    local pid="" attempt=0 status=0
    (
        rr_close_inherited_installer_lock_fds
        systemctl start argo-rr-health.service
    ) >/dev/null 2>&1 &
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

rr_restore_update_writer_state() {
    local backup="${1:-$BACKUP_DIR}" subscription_policy="${2:-normal}" failed=false
    local resume_subscription=false
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
        # A degraded/quarantined rollback must never revive the legacy health
        # writer.  Reuse the fail-closed postcondition verifier after the old
        # unit files have been restored.
        rr_quiesce_health_monitor_for_rollback || failed=true
    fi
    if [ "$resume_subscription" = true ]; then
        if [ "$failed" = false ]; then
            rr_resume_subscription_bounded || failed=true
        else
            rr_stop_subscription_servers >/dev/null 2>&1 || true
        fi
    fi
    if [ "$failed" != false ]; then
        rr_stop_subscription_servers >/dev/null 2>&1 || true
        rr_quiesce_health_monitor_for_rollback >/dev/null 2>&1 || true
        return 1
    fi
    RR_UPDATE_WRITERS_FROZEN=false
    RR_HEALTH_MONITOR_FROZEN=false
}

rr_verify_update_writer_state() {
    local backup="${1:-$BACKUP_DIR}" unit="" active_marker="" enabled_marker=""
    for unit in sing-box rr-nexus argo-rr-health.timer; do
        case "$unit" in
            sing-box) active_marker=singbox_was_running; enabled_marker=singbox_was_enabled ;;
            rr-nexus) active_marker=nexus_was_running; enabled_marker=nexus_was_enabled ;;
            *) active_marker=health_timer_was_running; enabled_marker=health_timer_was_enabled ;;
        esac
        if [ -f "$backup/$active_marker" ]; then
            rr_wait_unit_state "$unit" active || return 1
        else
            rr_wait_unit_state "$unit" inactive || return 1
        fi
        if [ -f "$backup/$enabled_marker" ]; then
            rr_unit_file_state_matches "$unit" enabled || return 1
        else
            rr_unit_file_state_matches "$unit" disabled || return 1
        fi
    done
    if [ -f "$backup/subscription_was_running" ]; then
        rr_subscription_running || return 1
    else
        ! rr_subscription_running
    fi
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

rr_test_fault() {
    # CI-only fault injection.  Two explicit gates prevent an accidental user
    # environment variable from ever interrupting a real update.
    local phase="$1"
    [ "${RR_TEST_FAULTS:-0}" = 1 ] || return 0
    if [ "${RR_TEST_CRASH_PHASE:-}" = "$phase" ]; then
        kill -KILL $$
    fi
    [ "${RR_TEST_FAIL_PHASE:-}" != "$phase" ]
}

rr_download() {
    local source_url="$1"
    local target_file="$2"
    local cache_buster=""
    local relative_path=""
    local official_manifest="${3:-false}"

    cache_buster=$(date +%s)
    case "$source_url" in
        "${RR_RAW_BASE}/"*) relative_path="${source_url#"${RR_RAW_BASE}/"}" ;;
    esac

    if [ "$official_manifest" != true ] && [ -n "$RR_GITHUB_MIRROR" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
                "${RR_GITHUB_MIRROR}${source_url}" -o "$target_file" 2>/dev/null && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 --tries=2 \
                -O "$target_file" "${RR_GITHUB_MIRROR}${source_url}" 2>/dev/null && return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 \
            -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "${source_url}?t=${cache_buster}" -o "$target_file" 2>/dev/null && return 0
        if [ -n "$relative_path" ]; then
            curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
                -H "Accept: application/vnd.github.raw+json" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
                "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ -n "$relative_path" ]; then
            wget -q --timeout=15 --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" && return 0
            wget -4 -q --timeout=15 --tries=2 \
                -O "$target_file" "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        rr_error "缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
    rr_error "无法从 GitHub Raw、GitHub API 或 CDN 下载：${relative_path:-$source_url}"
    return 1
}

rr_manifest_is_valid() {
    local manifest_file="$1"
    [ -s "$manifest_file" ] || return 1
    awk '
        NF != 2 { exit 1 }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        seen[$2]++ { exit 1 }
        $2 == "rr" { launcher = 1; next }
        $2 == "scripts/naive-cert-hook.sh" { naive_hook = 1; next }
        $2 == "scripts/update-recover.sh" { recovery = 1; next }
        $2 == "scripts/update-external-state.py" { external_state = 1; next }
        $2 ~ /^modules\/[0-9][0-9A-Za-z_-]*\.sh$/ { modules++; next }
        $2 == "nexus/rr_nexus.py" { nexus_app = 1; next }
        $2 == "nexus/sub_server.py" { nexus_sub = 1; next }
        $2 ~ /^nexus\/rr_nexus_lib\/[A-Za-z0-9._-]+\.py$/ { nexus_python++; next }
        $2 ~ /^nexus\/static\/[A-Za-z0-9._-]+\.(html|css|js)$/ { nexus_assets++; next }
        { exit 1 }
        END {
            if (!launcher || !naive_hook || !recovery || !external_state || modules < 2) exit 1
            if (!nexus_app || !nexus_sub || nexus_assets < 3) exit 1
        }
    ' "$manifest_file"
}

rr_bundle_archive_is_safe() {
    local archive_file="$1"
    [ -s "$archive_file" ] || return 1
    # The runtime payload is normally below 1 MiB. Refuse unexpectedly large
    # downloads and inspect the raw tar stream before any extraction.  The
    # same validator is embedded in the installed runtime because this stable
    # bootstrap must be independently safe when upgrading an old release.
    [ "$(stat -c %s "$archive_file" 2>/dev/null || echo 0)" -le 52428800 ] || return 1
    python3 - "$archive_file" <<'PYEOF'
import gzip
import re
import sys
import tarfile

archive = sys.argv[1]
max_members = 512
max_member_size = 16 * 1024 * 1024
max_total_size = 64 * 1024 * 1024
max_padding = 1024 * 1024
allowed = re.compile(
    r"^rr-bundle/(?:manifest\.sha256|rr|"
    r"scripts/(?:naive-cert-hook|update-recover)\.sh|"
    r"scripts/update-external-state\.py|"
    r"modules/[0-9][0-9A-Za-z_-]*\.sh|"
    r"nexus/[A-Za-z0-9._-]+\.py|"
    r"nexus/rr_nexus_lib/[A-Za-z0-9._-]+\.py|"
    r"nexus/static/[A-Za-z0-9._-]+\.(?:html|css|js))$"
)


def fail(message):
    raise ValueError(message)


def octal(field, label):
    if field and field[0] & 0x80:
        fail(f"base-256 {label}")
    value = field.strip(b" \0")
    if not value:
        return 0
    if any(byte < 48 or byte > 55 for byte in value):
        fail(f"invalid {label}")
    return int(value, 8)


def text_field(field, label):
    value, separator, tail = field.partition(b"\0")
    if separator and any(tail):
        fail(f"ambiguous {label}")
    try:
        return value.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValueError(f"non-ascii {label}") from exc


names = []
declared_total = 0
with gzip.open(archive, "rb") as stream:
    zero_blocks = 0
    while True:
        header = stream.read(512)
        if len(header) != 512:
            fail("truncated tar header")
        if header == b"\0" * 512:
            zero_blocks += 1
            if zero_blocks == 2:
                break
            continue
        if zero_blocks:
            fail("data after a partial end marker")
        stored_checksum = octal(header[148:156], "checksum")
        calculated_checksum = sum(header[:148]) + (32 * 8) + sum(header[156:])
        if stored_checksum != calculated_checksum:
            fail("tar checksum mismatch")
        typeflag = header[156:157]
        if typeflag not in (b"\0", b"0"):
            fail("non-regular member or tar extension")
        name = text_field(header[:100], "name")
        prefix = text_field(header[345:500], "prefix")
        if prefix:
            name = prefix + "/" + name
        if not allowed.fullmatch(name):
            fail("member outside the release allowlist")
        if name in names:
            fail("duplicate member")
        size = octal(header[124:136], "size")
        if size > max_member_size:
            fail("member too large")
        declared_total += size
        if declared_total > max_total_size:
            fail("expanded archive too large")
        names.append(name)
        if len(names) > max_members:
            fail("too many members")
        remaining = size
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("truncated member")
            remaining -= len(chunk)
        padding = (-size) % 512
        if padding and len(stream.read(padding)) != padding:
            fail("truncated member padding")
    trailing = 0
    while True:
        chunk = stream.read(65536)
        if not chunk:
            break
        trailing += len(chunk)
        if trailing > max_padding or any(chunk):
            fail("unexpected data after tar end marker")

if len(names) < 2:
    fail("empty bundle")

actual_names = []
actual_total = 0
with tarfile.open(archive, mode="r:gz") as handle:
    for member in handle:
        if not member.isreg() or member.pax_headers:
            fail("unsafe interpreted member")
        if member.name not in names or member.name in actual_names:
            fail("interpreted member mismatch")
        if member.size < 0 or member.size > max_member_size:
            fail("interpreted member too large")
        source = handle.extractfile(member)
        if source is None:
            fail("unreadable regular member")
        read_size = 0
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            read_size += len(chunk)
            actual_total += len(chunk)
            if read_size > member.size or actual_total > max_total_size:
                fail("payload exceeds declared limits")
        if read_size != member.size:
            fail("truncated interpreted member")
        actual_names.append(member.name)
if actual_names != names:
    fail("tar parser disagreement")
PYEOF
}

rr_bundle_tree_is_valid() {
    local bundle_root="$1"
    local manifest_file="$bundle_root/manifest.sha256"
    local expected_count=0
    local actual_count=0
    local shell_file=""

    rr_manifest_is_valid "$manifest_file" || return 1
    if find "$bundle_root" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
        return 1
    fi
    expected_count=$(( $(awk 'END { print NR + 0 }' "$manifest_file") + 1 ))
    actual_count=$(find "$bundle_root" -type f | wc -l)
    [ "$actual_count" -eq "$expected_count" ] || return 1
    (cd "$bundle_root" && sha256sum -c manifest.sha256 >/dev/null 2>&1) || return 1
    bash -n "$bundle_root/rr" || return 1
    for shell_file in "$bundle_root"/modules/*.sh; do
        [ -f "$shell_file" ] || return 1
        bash -n "$shell_file" || return 1
    done
    bash -n "$bundle_root/scripts/naive-cert-hook.sh" || return 1
    bash -n "$bundle_root/scripts/update-recover.sh" || return 1
    python3 -m py_compile "$bundle_root/scripts/update-external-state.py" || return 1
    local python_file=""
    while IFS= read -r python_file; do
        python3 -m py_compile "$python_file" || return 1
    done < <(find "$bundle_root/nexus" -type f -name '*.py' -print | LC_ALL=C sort)
}

rr_version_ge() {
    [ "$1" = "$2" ] || \
        [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
}

rr_check_system() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        rr_error "请使用 root 用户运行安装命令。"
        return 1
    }
    [ -r /etc/os-release ] || {
        rr_error "无法识别操作系统。"
        return 1
    }

    local os_id=""
    local os_version=""
    os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release)
    os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    case "$os_id" in
        debian)
            dpkg --compare-versions "${os_version:-0}" ge "12" || {
                rr_error "Debian ${os_version:-未知} 版本过旧，最低支持 Debian 12。"
                return 1
            }
            ;;
        ubuntu)
            dpkg --compare-versions "${os_version:-0}" ge "22.04" || {
                rr_error "Ubuntu ${os_version:-未知} 版本过旧，最低支持 Ubuntu 22.04。"
                return 1
            }
            ;;
        *)
            rr_error "当前仅正式支持 Debian 12+ 与 Ubuntu 22.04+。"
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *)
            rr_error "不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac

    for required_command in bash awk sed grep wc head sha256sum install mktemp cp mv rm mkdir dirname basename systemctl python3 tar find stat cmp pgrep pkill sort tail flock; do
        command -v "$required_command" >/dev/null 2>&1 || {
            rr_error "系统缺少必要命令：${required_command}"
            return 1
        }
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        rr_error "系统缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
}

rr_backup_file() {
    local source_file="$1"
    local backup_name="$2"
    if [ -e "$source_file" ]; then
        cp -p "$source_file" "$BACKUP_DIR/$backup_name" || return 1
        : > "$BACKUP_DIR/had_${backup_name}"
    fi
}

rr_backup_dir() {
    local source_dir="$1"
    local backup_name="$2"
    local source_uid=""
    if [ -L "$source_dir" ]; then
        rr_error "拒绝备份符号链接目录：${source_dir}"
        return 1
    fi
    if [ -d "$source_dir" ]; then
        source_uid=$(stat -c '%u' -- "$source_dir" 2>/dev/null) || return 1
        if [ "$source_uid" != 0 ]; then
            rr_error "拒绝备份非 root 所有的运行目录：${source_dir}"
            return 1
        fi
        cp -a "$source_dir" "$BACKUP_DIR/$backup_name" || return 1
        : > "$BACKUP_DIR/had_${backup_name}"
    fi
}

rr_backup_sqlite() {
    local source_db="$1"
    local backup_name="$2"
    [ -e "$source_db" ] || return 0
    if ! python3 - "$source_db" "$BACKUP_DIR/$backup_name" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
target = sqlite3.connect(sys.argv[2])
try:
    source.backup(target)
finally:
    target.close()
    source.close()
PY
    then
        rm -f "$BACKUP_DIR/$backup_name"
        return 1
    fi
    : > "$BACKUP_DIR/had_${backup_name}"
}

rr_restore_file() {
    local backup_name="$1"
    local target_file="$2"
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        mkdir -p "$(dirname "$target_file")"
        # 运行中的二进制无法被原地覆盖（Text file busy）。
        # 先复制到同目录临时文件再原子替换目录项——运行进程保持旧 inode 不受影响。
        # 若仍失败（只读盘/权限等），记录警告并继续回滚其余文件，绝不中断回滚流程。
        local restore_tmp=""
        restore_tmp="$(dirname "$target_file")/.rr-restore.$$"
        if cp -p "$BACKUP_DIR/$backup_name" "$restore_tmp" 2>/dev/null && \
           mv -f "$restore_tmp" "$target_file" 2>/dev/null; then
            return 0
        fi
        rm -f "$restore_tmp"
        if cp -p "$BACKUP_DIR/$backup_name" "$target_file" 2>/dev/null; then
            return 0
        fi
        rr_error "警告：恢复 ${target_file} 失败（可能被运行中的进程占用），已跳过并继续回滚。"
        return 1
    else
        rm -f "$target_file" || return 1
    fi
    return 0
}

rr_restore_dir() {
    local backup_name="$1"
    local target_dir="$2"
    rm -rf "$target_dir" || return 1
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        if [ -L "$BACKUP_DIR/$backup_name" ] || [ ! -d "$BACKUP_DIR/$backup_name" ]; then
            rr_error "拒绝恢复不安全的目录备份：${backup_name}"
            return 1
        fi
        mkdir -p "$(dirname "$target_dir")" || return 1
        cp -a "$BACKUP_DIR/$backup_name" "$target_dir" || return 1
    fi
    return 0
}

rr_restore_sqlite() {
    local backup_name="$1"
    local target_db="$2"
    rm -f "$target_db" "${target_db}-wal" "${target_db}-shm" || return 1
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        mkdir -p "$(dirname "$target_db")" || return 1
        install -m 600 "$BACKUP_DIR/$backup_name" "$target_db" || return 1
    fi
    return 0
}

rr_write_phase() {
    local phase="$1" temporary=""
    [ -n "$TX_DIR" ] || return 1
    temporary="$TX_DIR/.phase.$$"
    (umask 077; printf '%s\n' "$phase" > "$temporary") && chmod 600 "$temporary" && \
        sync -f "$temporary" && mv -f "$temporary" "$TX_DIR/phase" && sync -f "$TX_DIR"
}

rr_sync_host_state_before_terminal() {
    if sync; then
        return 0
    fi
    # A failed global flush makes either the candidate or restored host state
    # non-durable.  Keep every recovery pointer and freeze writers instead of
    # publishing a terminal phase that boot recovery could wrongly discard.
    if declare -F rr_freeze_update_writers >/dev/null; then
        rr_freeze_update_writers >/dev/null 2>&1 || true
    fi
    TRANSACTION_ACTIVE=false
    ROLLBACK_FAILED=true
    KEEP_TRANSACTION=true
    RR_UPDATE_WRITERS_FROZEN=true
    RR_HEALTH_MONITOR_FROZEN=true
    rr_write_phase recovery_failed >/dev/null 2>&1 || true
    rr_error "主机状态无法完成全局持久化；写入器保持冻结，事务证据已保留。"
    return 1
}

rr_transaction_path_is_direct_child() {
    local transaction="$1" parent="" name="" canonical=""
    [ -n "$transaction" ] && [[ "$transaction" == /* ]] || return 1
    parent=$(dirname -- "$transaction") || return 1
    [ "$parent" = "$RR_TX_ROOT/transactions" ] || return 1
    name=$(basename -- "$transaction") || return 1
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
    canonical=$(readlink -m -- "$transaction" 2>/dev/null) || return 1
    [ "$canonical" = "$transaction" ]
}

rr_transaction_dir_is_strict() {
    local transaction="$1"
    rr_transaction_path_is_direct_child "$transaction" || return 1
    [ -d "$transaction" ] && [ ! -L "$transaction" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$transaction" 2>/dev/null)" = 0:0:700 ]
}

rr_read_trusted_phase() {
    local transaction="${1:-$TX_DIR}" phase_file="" phase="" phase_fd=""
    local shell_pid="${BASHPID:-$$}" fd_path="" path_identity="" fd_identity=""
    local -a phase_lines=()
    rr_transaction_dir_is_strict "$transaction" || return 1
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
    if [ "$path_identity" != "$fd_identity" ] || \
       [[ "$fd_identity" != *:0:0:600:1 ]] || [ -L "$phase_file" ]; then
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

rr_read_trusted_legacy_phase() {
    local transaction="$1" phase_file="" phase="" phase_fd=""
    local shell_pid="${BASHPID:-$$}" fd_path="" path_identity="" fd_identity=""
    local owner="" group="" mode="" links=""
    local -a phase_lines=()
    rr_transaction_dir_is_strict "$transaction" || return 1
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
    IFS=: read -r _ _ owner group mode links <<<"$fd_identity"
    if [ "$path_identity" != "$fd_identity" ] || [ -L "$phase_file" ] ||
       [ "$owner" != 0 ] || [ "$group" != 0 ] || [ "$links" != 1 ] ||
       ! rr_legacy_update_lock_mode_is_safe "$mode"; then
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

rr_read_previous_transaction_phase() {
    local transaction="$1" format_state=0
    if rr_transaction_format_state "$transaction"; then
        format_state=0
    else
        format_state=$?
    fi
    case "$format_state" in
        0) rr_read_trusted_phase "$transaction" ;;
        1) rr_read_trusted_legacy_phase "$transaction" ;;
        *) return 1 ;;
    esac
}

rr_read_trusted_active_transaction() {
    local active_fd="" shell_pid="${BASHPID:-$$}" fd_path=""
    local path_identity="" fd_identity="" owner="" group="" mode="" links=""
    local tx="" format_state=0
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
    IFS=: read -r _ _ owner group mode links <<<"$fd_identity"
    if [ "$path_identity" != "$fd_identity" ] || [ -L "$RR_ACTIVE_TX" ] ||
       [ "$owner" != 0 ] || [ "$group" != 0 ] || [ "$links" != 1 ] ||
       ! rr_legacy_update_lock_mode_is_safe "$mode"; then
        exec {active_fd}>&-
        return 1
    fi
    mapfile -t active_lines <&"$active_fd"
    [ "${#active_lines[@]}" -eq 1 ] || {
        exec {active_fd}>&-
        return 1
    }
    tx="${active_lines[0]}"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$RR_ACTIVE_TX" 2>/dev/null) || {
        exec {active_fd}>&-
        return 1
    }
    exec {active_fd}>&-
    [ "$path_identity" = "$fd_identity" ] && [ ! -L "$RR_ACTIVE_TX" ] || return 1
    rr_transaction_path_is_direct_child "$tx" || return 1
    if [ -e "$tx" ] || [ -L "$tx" ]; then
        rr_transaction_dir_is_strict "$tx" || return 1
        if rr_transaction_format_state "$tx"; then
            format_state=0
        else
            format_state=$?
        fi
        [ "$format_state" -ne 2 ] || return 1
        [ "$format_state" -ne 0 ] || [ "$mode" = 600 ] || return 1
    fi
    printf '%s\n' "$tx"
}

rr_republish_active_pointer_for_retry() {
    local expected="$1" parent="" temporary="" actual=""
    parent=$(dirname -- "$RR_ACTIVE_TX") || return 1
    [ "$parent" = "$RR_TX_ROOT" ] && [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ] || return 1
    rr_transaction_dir_is_strict "$expected" || return 1
    if [ -e "$RR_ACTIVE_TX" ] || [ -L "$RR_ACTIVE_TX" ]; then
        actual=$(rr_read_trusted_active_transaction) || return 1
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
        sync || true
        return 1
    fi
    actual=$(rr_read_trusted_active_transaction) || return 1
    [ "$actual" = "$expected" ]
}

rr_clear_active_transaction_pointer() {
    local expected="$1" actual="" parent=""
    parent=$(dirname -- "$RR_ACTIVE_TX") || return 1
    if [ ! -e "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ]; then
        sync -f "$parent"
        return
    fi
    actual=$(rr_read_trusted_active_transaction) || return 1
    [ "$actual" = "$expected" ] || return 1
    rm -f -- "$RR_ACTIVE_TX" || return 1
    if sync -f "$parent"; then
        return 0
    fi
    rr_republish_active_pointer_for_retry "$expected" || true
    return 1
}

rr_prepare_recovery_runtime() {
    local recovery_source="$PAYLOAD_DIR/scripts/update-recover.sh"
    local recovery_target="$RR_RECOVERY_HELPER"
    local recovery_tmp=""
    local external_source="$PAYLOAD_DIR/scripts/update-external-state.py"
    local external_tmp=""
    [ -s "$recovery_source" ] && bash -n "$recovery_source" || return 1
    [ -s "$external_source" ] && python3 -m py_compile "$external_source" || return 1
    mkdir -p /usr/local/sbin /etc/systemd/system "$RR_TX_ROOT/transactions" || return 1
    chmod 700 "$RR_TX_ROOT"
    external_tmp=$(mktemp /usr/local/sbin/.rr-update-external-state.XXXXXX) || return 1
    if ! install -m 755 "$external_source" "$external_tmp" || \
       ! sync -f "$external_tmp" || \
       ! mv -f "$external_tmp" "$RR_UPDATE_EXTERNAL_HELPER" || \
       ! sync -f /usr/local/sbin; then
        rm -f "$external_tmp"
        return 1
    fi
    recovery_tmp=$(mktemp /usr/local/sbin/.rr-update-recover.XXXXXX) || return 1
    install -m 755 "$recovery_source" "$recovery_tmp" && \
        sync -f "$recovery_tmp" && mv -f "$recovery_tmp" "$recovery_target" && \
        sync -f /usr/local/sbin || {
        rm -f "$recovery_tmp"
        return 1
    }
    cat > /etc/systemd/system/rr-update-recovery.service <<'EOF'
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
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable rr-update-recovery.service >/dev/null 2>&1 || return 1
}

rr_discard_previous_transaction() {
    local previous="" phase="" format_state=0 settled_state=0
    if [ ! -e "$RR_ACTIVE_TX" ] && [ ! -L "$RR_ACTIVE_TX" ]; then
        return 0
    fi
    previous=$(rr_read_trusted_active_transaction) || return 1
    if [ ! -d "$previous" ]; then
        rr_clear_active_transaction_pointer "$previous"
        return
    fi
    phase=$(rr_read_previous_transaction_phase "$previous") || {
        rr_error "旧事务阶段元数据不可信，已保留活动指针和全部恢复证据。"
        return 1
    }
    case "$phase" in
        committed)
            if rr_transaction_format_state "$previous"; then
                format_state=0
            else
                format_state=$?
            fi
            if [ "$format_state" -eq 2 ]; then
                rr_error "旧事务格式标记损坏，拒绝清理或覆盖回滚证据。"
                return 1
            fi
            if rr_committed_settled_state "$previous"; then
                settled_state=0
            else
                settled_state=$?
            fi
            if [ "$settled_state" -eq 2 ]; then
                rr_error "旧事务收尾证据不可信，拒绝修改防火墙或清理回滚窗口。"
                return 1
            fi
            if [ "$format_state" -eq 0 ]; then
                rr_create_update_maintenance_marker "$previous" || return 1
                rr_run_with_delegated_update_lock "$RR_LAUNCHER" \
                    --post-update-finalize --retire-rollback || return 1
            fi
            rr_run_with_delegated_update_lock \
                "$RR_RECOVERY_HELPER" recover || return 1
            RR_UPDATE_MAINTENANCE_ACTIVE=false
            rr_clear_active_transaction_pointer "$previous" || return 1
            rm -rf -- "$previous" || return 1
            ;;
        rolled_back|rolled_back_degraded)
            rr_run_with_delegated_update_lock \
                "$RR_RECOVERY_HELPER" recover || return 1
            rr_clear_active_transaction_pointer "$previous" || return 1
            rm -rf -- "$previous" || return 1
            ;;
        aborted)
            rr_clear_active_transaction_pointer "$previous" || return 1
            rm -rf -- "$previous" || return 1
            ;;
        *)
            rr_run_with_delegated_update_lock \
                "$RR_RECOVERY_HELPER" recover || return 1
            ;;
    esac
}

rr_prune_stale_transactions() {
    local transaction="" phase="" active=""
    if [ -e "$RR_ACTIVE_TX" ] || [ -L "$RR_ACTIVE_TX" ]; then
        active=$(rr_read_trusted_active_transaction) || return 1
    fi
    while IFS= read -r transaction; do
        [ "$transaction" = "$active" ] && continue
        rr_transaction_dir_is_strict "$transaction" || continue
        # A SIGKILL can leave an inactive directory between mkdir/format and
        # phase publication. Preserve any unreadable or incomplete orphan, but
        # never let it block a later transaction or classify it as terminal.
        if ! phase=$(rr_read_previous_transaction_phase "$transaction"); then
            continue
        fi
        case "$phase" in rolled_back|rolled_back_degraded|aborted) rm -rf -- "$transaction" || return 1 ;; esac
    done < <(find "$RR_TX_ROOT/transactions" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort)
}

rr_snapshot_runtime() {
    # Resolve a prior durable transaction first.  The new transaction records
    # every writer state and publishes its active pointer before stopping even
    # the health timer, so SIGKILL never leaves an untracked frozen writer.
    rr_prepare_recovery_runtime || return 1
    rr_discard_previous_transaction || return 1
    rr_prune_stale_transactions || return 1
    if declare -F rr_capture_update_writer_state >/dev/null; then
        rr_capture_update_writer_state || return 1
    fi
    TX_DIR="$RR_TX_ROOT/transactions/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    BACKUP_DIR="$TX_DIR/backup"
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$TX_DIR" "$BACKUP_DIR"
    rr_write_transaction_format || return 1

    if declare -F rr_persist_update_writer_state >/dev/null; then
        rr_persist_update_writer_state || return 1
        rr_write_phase state_recorded || return 1
    else
        rr_write_phase snapshotting || return 1
    fi
    (umask 077; printf '%s\n' "$TX_DIR" > "${RR_ACTIVE_TX}.tmp.$$") || return 1
    chmod 600 "${RR_ACTIVE_TX}.tmp.$$" || return 1
    sync -f "${RR_ACTIVE_TX}.tmp.$$" || return 1
    mv -f "${RR_ACTIVE_TX}.tmp.$$" "$RR_ACTIVE_TX" || return 1
    sync -f "$RR_ACTIVE_TX" && sync -f "$RR_TX_ROOT" || return 1
    if declare -F rr_persist_update_writer_state >/dev/null; then
        rr_create_update_maintenance_marker || return 1
        rr_write_phase freezing || return 1
        rr_freeze_update_writers || return 1
        rr_write_phase snapshotting || return 1
    else
        rr_freeze_health_monitor || return 1
    fi

    # Snapshot fixed RR-owned Nginx, Cloudflared and firewall state only after
    # every writer is frozen and before the candidate can mutate anything.
    # The format/required markers distinguish this transaction from a legacy
    # 7.1.0 transaction whose recovery helper knew nothing about external state.
    rr_snapshot_external_state || return 1

    rr_backup_file "$RR_LAUNCHER" rr_launcher || return 1
    rr_backup_file /etc/argo_vmess.conf argo_vmess.conf || return 1
    rr_backup_file /etc/sing-box/config.json singbox_config.json || return 1
    rr_backup_file /etc/sing-box/cert.pem singbox_cert.pem || return 1
    rr_backup_file /etc/sing-box/private.key singbox_private.key || return 1
    rr_backup_file /usr/local/bin/sing-box singbox_binary || return 1
    rr_backup_file /etc/systemd/system/sing-box.service singbox.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.service health.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.timer health.timer || return 1
    rr_backup_file /usr/local/bin/auto_update_sub.py auto_update_sub.py || return 1
    rr_backup_file /etc/rr-nexus/nexus.json nexus.json || return 1
    rr_backup_file /etc/systemd/system/rr-nexus.service nexus.service || return 1
    rr_backup_file /etc/rr-update/channel update_channel || return 1
    rr_backup_file /var/lib/rr-nexus/remote.key remote.key || return 1
    rr_backup_dir /etc/rr-naive rr-naive || return 1
    rr_backup_sqlite /var/lib/rr-nexus/nexus.db nexus.db || return 1
    rr_backup_dir /tmp/sub_server sub_server || return 1

    pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1 && : > "$BACKUP_DIR/argo_was_running"
    if [ "${RR_HEALTH_TIMER_WAS_ENABLED:-false}" = true ] && \
       [ ! -f "$BACKUP_DIR/health_timer_was_enabled" ]; then
        : > "$BACKUP_DIR/health_timer_was_enabled"
    fi

    # Service state probes are optional metadata. A fresh server has none of
    # these units yet, so their non-zero status must not turn a valid empty
    # snapshot into a failed update backup.
    [ -e "$RR_LIB_DIR" ] || : > "$BACKUP_DIR/runtime_did_not_exist"
    rr_write_phase prepared
}

rr_rollback() {
    [ "$TRANSACTION_ACTIVE" = true ] || return 0
    local rollback_phase=""
    if ! rollback_phase=$(rr_read_trusted_phase "$TX_DIR"); then
        TRANSACTION_ACTIVE=false
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_error "事务阶段记录不可信，拒绝自动回滚并保留现场。"
        return 1
    fi
    if [ "$rollback_phase" = committed ]; then
        TRANSACTION_ACTIVE=false
        KEEP_TRANSACTION=true
        rr_error "安全版本已提交；保留事务证据并等待收尾重试，绝不自动回滚。"
        return 0
    fi
    case "$rollback_phase" in
        state_recorded|freezing|snapshotting|prepared|switching|runtime_swapped|migrating) ;;
        *)
            TRANSACTION_ACTIVE=false
            ROLLBACK_FAILED=true
            KEEP_TRANSACTION=true
            rr_error "事务已处于终态，拒绝再次自动回滚并保留现场。"
            return 1
            ;;
    esac
    if ! rr_quiesce_health_monitor_for_rollback; then
        TRANSACTION_ACTIVE=false
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_write_phase recovery_failed >/dev/null 2>&1 || true
        return 1
    fi
    TRANSACTION_ACTIVE=false
    local rollback_failed=false
    local subscription_policy="normal"
    rr_error "新版本校验失败，正在恢复升级前状态……"

    systemctl stop sing-box rr-nexus >/dev/null 2>&1 || true
    rr_stop_subscription_servers || rollback_failed=true

    # OLD_RUNTIME becomes authoritative as soon as the live directory is moved.
    # A catchable failure can occur before RUNTIME_REPLACED flips to true (for
    # example a failed candidate move), so keying restoration only on that flag
    # would discard the sole old runtime during cleanup.
    if [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ]; then
        if { [ ! -e "$RR_LIB_DIR" ] || rm -rf "$RR_LIB_DIR"; } && \
           mv "$OLD_RUNTIME" "$RR_LIB_DIR"; then
            OLD_RUNTIME=""
        else
            rollback_failed=true
        fi
    elif [ "$RUNTIME_REPLACED" = true ]; then
        rm -rf "$RR_LIB_DIR" || rollback_failed=true
    fi
    RUNTIME_REPLACED=false

    rr_restore_file rr_launcher "$RR_LAUNCHER" || rollback_failed=true
    rr_restore_file argo_vmess.conf /etc/argo_vmess.conf || rollback_failed=true
    rr_restore_file singbox_config.json /etc/sing-box/config.json || rollback_failed=true
    rr_restore_file singbox_cert.pem /etc/sing-box/cert.pem || rollback_failed=true
    rr_restore_file singbox_private.key /etc/sing-box/private.key || rollback_failed=true
    rr_restore_file singbox_binary /usr/local/bin/sing-box || rollback_failed=true
    rr_restore_file singbox.service /etc/systemd/system/sing-box.service || rollback_failed=true
    rr_restore_file health.service /etc/systemd/system/argo-rr-health.service || rollback_failed=true
    rr_restore_file health.timer /etc/systemd/system/argo-rr-health.timer || rollback_failed=true
    rr_restore_file auto_update_sub.py /usr/local/bin/auto_update_sub.py || rollback_failed=true
    rr_restore_file nexus.json /etc/rr-nexus/nexus.json || rollback_failed=true
    rr_restore_file nexus.service /etc/systemd/system/rr-nexus.service || rollback_failed=true
    rr_restore_file update_channel /etc/rr-update/channel || rollback_failed=true
    rr_restore_file remote.key /var/lib/rr-nexus/remote.key || rollback_failed=true
    rr_restore_dir rr-naive /etc/rr-naive || rollback_failed=true
    rr_restore_sqlite nexus.db /var/lib/rr-nexus/nexus.db || rollback_failed=true
    rr_restore_dir sub_server /tmp/sub_server || rollback_failed=true

    rr_install_restore_external_state_if_required || rollback_failed=true
    systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=true
    if [ "$rollback_failed" = true ]; then
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_write_phase recovery_failed >/dev/null 2>&1 || true
        rr_error "严重：内部或外部状态未能完整恢复；所有写入服务保持冻结，事务证据已保留。"
        return 1
    fi

    # A pre-7.1.1 runtime can recreate the former cleartext public subscription
    # from its health timer (or when the user runs the old rr manually).  The
    # candidate recovery helper lives outside the replaceable runtime and owns
    # the quarantine.  Non-canonical TX_DIR values only occur in isolated unit
    # scaffolding; every real installer transaction is below transactions/.
    case "$TX_DIR" in
        "$RR_TX_ROOT"/transactions/*)
            if [ -x "$RR_RECOVERY_HELPER" ] &&
               rr_run_with_delegated_update_lock "$RR_RECOVERY_HELPER" \
                   apply-rollback-policy "$TX_DIR"; then
                subscription_policy=$(head -n 1 "$TX_DIR/rollback-subscription-status" 2>/dev/null || printf degraded)
            else
                subscription_policy=degraded
                rollback_failed=true
            fi
            ;;
    esac
    case "$subscription_policy" in normal|quarantined|degraded) ;; *) subscription_policy=degraded; rollback_failed=true ;; esac
    if [ "$rollback_failed" = true ]; then
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_write_phase recovery_failed >/dev/null 2>&1 || true
        rr_error "严重：旧版订阅隔离策略未能完成；写入服务保持冻结，事务证据已保留。"
        return 1
    fi
    if declare -F rr_restore_update_writer_state >/dev/null; then
        rr_restore_update_writer_state "$BACKUP_DIR" "$subscription_policy" || rollback_failed=true
    else
        if [ -f "$BACKUP_DIR/health_timer_was_enabled" ]; then
            systemctl enable --now argo-rr-health.timer >/dev/null 2>&1 || true
        else
            systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
        fi
        if [ -f "$BACKUP_DIR/singbox_was_running" ]; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        else
            systemctl stop sing-box >/dev/null 2>&1 || true
        fi
        if [ -f "$BACKUP_DIR/nexus_was_running" ]; then
            systemctl restart rr-nexus >/dev/null 2>&1 || true
        else
            systemctl stop rr-nexus >/dev/null 2>&1 || true
        fi
        if [ "$subscription_policy" = normal ] && \
           [ -f "$BACKUP_DIR/subscription_was_running" ]; then
            rr_resume_subscription_bounded || rollback_failed=true
        fi
    fi
    if [ "$rollback_failed" = true ]; then
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_write_phase recovery_failed >/dev/null 2>&1 || true
        rr_error "严重：回滚未完整完成；现场备份将保留在 ${BACKUP_DIR}，请勿删除。"
        [ -n "$OLD_RUNTIME" ] && rr_error "旧运行目录仍保留在 ${OLD_RUNTIME}。"
        return 1
    fi
    rr_sync_host_state_before_terminal || return 1
    if [ "$subscription_policy" = normal ]; then
        rr_write_phase rolled_back || {
            ROLLBACK_FAILED=true
            return 1
        }
    else
        rr_write_phase rolled_back_degraded || {
            ROLLBACK_FAILED=true
            return 1
        }
        KEEP_TRANSACTION=true
    fi
    if declare -F rr_clear_update_maintenance_marker >/dev/null && \
       ! rr_clear_update_maintenance_marker "$TX_DIR"; then
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_error "严重：维护状态标记未能安全清理；事务证据已保留。"
        return 1
    fi
    if ! rr_clear_active_transaction_pointer "$TX_DIR"; then
        ROLLBACK_FAILED=true
        KEEP_TRANSACTION=true
        rr_error "严重：活动事务指针未能持久清理；终态与事务证据已保留。"
        return 1
    fi
    if [ -f "$BACKUP_DIR/runtime_did_not_exist" ]; then
        systemctl disable rr-update-recovery.service >/dev/null 2>&1 || true
        rm -f -- /etc/systemd/system/rr-update-recovery.service \
            "$RR_RECOVERY_HELPER" "$RR_UPDATE_EXTERNAL_HELPER"
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$RR_TX_ROOT"
    fi
    if [ "$subscription_policy" = normal ]; then
        rr_error "回滚完成：原 rr、配置、内核、Nexus 数据库和订阅已恢复。"
    else
        rr_error "回滚完成（DEGRADED）：原数据和运行文件已恢复，但旧版公网订阅已安全隔离。"
        rr_error "请升级到 ${RR_SUBSCRIPTION_SAFE_VERSION} 或更高版本；诊断：/usr/local/sbin/rr-update-recover status"
    fi
    return 0
}

rr_cleanup() {
    local result="${1:-0}" cleanup_phase=""
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_ACTIVE" = true ]; then
        if cleanup_phase=$(rr_read_trusted_phase "$TX_DIR"); then
            if [ "$cleanup_phase" = committed ]; then
                TRANSACTION_ACTIVE=false
                KEEP_TRANSACTION=true
            else
                rr_rollback || result=1
            fi
        else
            TRANSACTION_ACTIVE=false
            ROLLBACK_FAILED=true
            KEEP_TRANSACTION=true
            rr_error "事务阶段记录不可信，清理器拒绝自动回滚并保留现场。"
            result=1
        fi
    fi
    if [ -n "$TX_DIR" ]; then
        cleanup_phase=$(rr_read_trusted_phase "$TX_DIR" 2>/dev/null || printf invalid)
    fi
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_ACTIVE" != true ] && \
       [ "$RR_UPDATE_WRITERS_FROZEN" = true ] && \
       [[ "$cleanup_phase" =~ ^(freezing|snapshotting|prepared)$ ]]; then
        if rr_restore_update_writer_state "$BACKUP_DIR" normal && \
           rr_sync_host_state_before_terminal && \
           rr_write_phase aborted && \
           rr_clear_update_maintenance_marker "$TX_DIR" && \
           rr_clear_active_transaction_pointer "$TX_DIR"; then
            :
        else
            cleanup_phase=$(rr_read_trusted_phase "$TX_DIR" 2>/dev/null || printf invalid)
            [ "$cleanup_phase" = aborted ] || \
                rr_write_phase recovery_failed >/dev/null 2>&1 || true
            ROLLBACK_FAILED=true
            KEEP_TRANSACTION=true
            result=1
        fi
    fi
    if [ -n "$TX_DIR" ]; then
        cleanup_phase=$(rr_read_trusted_phase "$TX_DIR" 2>/dev/null || printf invalid)
    fi
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_ACTIVE" != true ] && \
       [ "$RR_UPDATE_WRITERS_FROZEN" != true ] && \
       [ "$RR_UPDATE_MAINTENANCE_ACTIVE" = true ] && \
       [ "$ROLLBACK_FAILED" != true ] && [ "$cleanup_phase" = state_recorded ]; then
        if rr_sync_host_state_before_terminal && \
           rr_write_phase aborted && rr_clear_update_maintenance_marker "$TX_DIR" && \
           rr_clear_active_transaction_pointer "$TX_DIR"; then
            :
        else
            cleanup_phase=$(rr_read_trusted_phase "$TX_DIR" 2>/dev/null || printf invalid)
            [ "$cleanup_phase" = aborted ] || \
                rr_write_phase recovery_failed >/dev/null 2>&1 || true
            ROLLBACK_FAILED=true
            KEEP_TRANSACTION=true
            result=1
        fi
    fi
    [ -n "$STAGE_ROOT" ] && rm -rf "$STAGE_ROOT"
    [ -n "$NEW_RUNTIME" ] && [ -e "$NEW_RUNTIME" ] && rm -rf "$NEW_RUNTIME"
    [ -n "$NEW_LAUNCHER" ] && [ -e "$NEW_LAUNCHER" ] && rm -f "$NEW_LAUNCHER"
    if [ "$ROLLBACK_FAILED" != true ] && [ "$KEEP_TRANSACTION" != true ]; then
        if [ -n "$TX_DIR" ] && ! rr_clear_active_transaction_pointer "$TX_DIR"; then
            ROLLBACK_FAILED=true
            KEEP_TRANSACTION=true
            result=1
        else
            [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ] && rm -rf "$OLD_RUNTIME"
            [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
            [ -n "$TX_DIR" ] && [ -d "$TX_DIR" ] && rm -rf "$TX_DIR"
        fi
    fi
    if [ "$RR_UPDATE_WRITERS_FROZEN" != true ] && \
       [ "$RR_HEALTH_MONITOR_FROZEN" = true ] && \
       ! rr_resume_health_monitor_after_abort; then
        rr_error "健康检查定时器未能恢复；请执行 systemctl status argo-rr-health.timer。"
        result=1
    fi
    return "$result"
}

rr_fetch_release() {
    STAGE_ROOT=$(mktemp -d /tmp/rr-release.XXXXXX) || return 1
    PAYLOAD_DIR="$STAGE_ROOT/payload"
    mkdir -p "$PAYLOAD_DIR/modules"

    echo "[RR-vps] 正在下载发布清单……"
    local actual=""
    local bundle_ready=false
    if [ -n "${RR_BUNDLE_FILE:-}" ] && [ -r "$RR_BUNDLE_FILE" ]; then
        cp -p -- "$RR_BUNDLE_FILE" "$STAGE_ROOT/rr-bundle.tar.gz" 2>/dev/null && \
            bundle_ready=true
    elif rr_download "${RR_RAW_BASE}/rr-bundle.tar.gz" \
        "$STAGE_ROOT/rr-bundle.tar.gz" 2>/dev/null; then
        bundle_ready=true
    fi
    if [ "$bundle_ready" = true ]; then
        actual=$(sha256sum "$STAGE_ROOT/rr-bundle.tar.gz" | awk '{print $1}')
        if [ "$actual" = "d332fa747db7f0ec6339c0e820d6c2230884cb3b2c7d8d637fa723ebcd07fa12" ] && \
           rr_bundle_archive_is_safe "$STAGE_ROOT/rr-bundle.tar.gz" && \
           tar --no-same-owner --no-same-permissions -xzf \
               "$STAGE_ROOT/rr-bundle.tar.gz" -C "$PAYLOAD_DIR" \
               --strip-components=1 2>/dev/null && \
           rr_bundle_tree_is_valid "$PAYLOAD_DIR"; then
            cp "$PAYLOAD_DIR/manifest.sha256" "$STAGE_ROOT/manifest.sha256" || return 1
            echo "[RR-vps] ✓ 高速模式加载完成（外层与内部 SHA256 均已校验）"
            return 0
        fi
    fi

    echo "[RR-vps] ⚡ 高速模式未命中，切换逐文件下载……"
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR/modules"
    # manifest 是逐文件下载的信任锚；镜像只能搬运随后按官方哈希校验的文件，
    # 不能提供或替换这份锚点。
    rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" true || return 1
    rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" || {
        rr_error "远程发布清单格式无效。"
        return 1
    }

    local expected_hash=""
    local relative_path=""
    while read -r expected_hash relative_path; do
        mkdir -p "$PAYLOAD_DIR/$(dirname "$relative_path")"
        rr_download "${RR_RAW_BASE}/${relative_path}" "$PAYLOAD_DIR/$relative_path" || {
            rr_error "下载失败：${relative_path}"
            return 1
        }
    done < "$STAGE_ROOT/manifest.sha256"

    if ! (cd "$PAYLOAD_DIR" && sha256sum -c "$STAGE_ROOT/manifest.sha256" >/dev/null); then
        # CDN 边缘可能缓存旧版本文件：等待 10s 后强制刷新重试一次
        echo "[RR-vps] ⚠ 校验未通过（可能命中 CDN 旧缓存），10 秒后重试……"
        sleep 10
        rm -rf "$PAYLOAD_DIR"
        mkdir -p "$PAYLOAD_DIR"
        rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" true || return 1
        rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" || { rr_error "远程发布清单格式无效。"; return 1; }
        while read -r _ relative_path; do
            mkdir -p "$PAYLOAD_DIR/$(dirname "$relative_path")"
            rr_download "${RR_RAW_BASE}/${relative_path}" "$PAYLOAD_DIR/$relative_path" || {
                rr_error "重试下载失败：${relative_path}"
                return 1
            }
        done < "$STAGE_ROOT/manifest.sha256"
        if ! (cd "$PAYLOAD_DIR" && sha256sum -c "$STAGE_ROOT/manifest.sha256" >/dev/null); then
            rr_error "文件 SHA256 校验失败，拒绝安装。"
            return 1
        fi
    fi
    bash -n "$PAYLOAD_DIR/rr" || return 1
    bash -n "$PAYLOAD_DIR/scripts/naive-cert-hook.sh" || return 1
    bash -n "$PAYLOAD_DIR/scripts/update-recover.sh" || return 1
    python3 -m py_compile "$PAYLOAD_DIR/scripts/update-external-state.py" || return 1
    local shell_file=""
    for shell_file in "$PAYLOAD_DIR"/modules/*.sh; do
        bash -n "$shell_file" || return 1
    done
    if [ -f "$PAYLOAD_DIR/nexus/rr_nexus.py" ]; then
        local python_file=""
        while IFS= read -r python_file; do
            python3 -m py_compile "$python_file" || return 1
        done < <(find "$PAYLOAD_DIR/nexus" -type f -name '*.py' -print | LC_ALL=C sort)
        [ -s "$PAYLOAD_DIR/nexus/static/index.html" ] && \
        [ -s "$PAYLOAD_DIR/nexus/static/app.css" ] && \
        [ -s "$PAYLOAD_DIR/nexus/static/app.js" ] || return 1
    fi
    if ! RR_VALIDATE_MODULE_DIR="$PAYLOAD_DIR/modules" bash -c '
        for module_file in "$RR_VALIDATE_MODULE_DIR"/*.sh; do source "$module_file" || exit 1; done
        declare -F main_menu >/dev/null &&
        declare -F install_main >/dev/null &&
        declare -F do_update >/dev/null &&
        declare -F generate_node_and_sub >/dev/null
    '; then
        rr_error "模块组合加载测试失败。"
        return 1
    fi
}

rr_install_release() {
    local release_version=""
    local installed_version=""
    release_version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"/\1/p' \
        "$PAYLOAD_DIR/modules/00-runtime.sh" | head -n 1)
    [[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        rr_error "发布包版本号无效，拒绝安装。"
        return 1
    }
    if [ "$RR_MODE" = "--upgrade" ] && \
       [ -r "$RR_LIB_DIR/modules/00-runtime.sh" ]; then
        installed_version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"/\1/p' \
            "$RR_LIB_DIR/modules/00-runtime.sh" | head -n 1)
        if [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
           ! rr_version_ge "$release_version" "$installed_version"; then
            rr_error "已阻止降级：发布包 ${release_version} 低于已安装版本 ${installed_version}。"
            return 1
        fi
    fi

    rr_snapshot_runtime || {
        rr_error "无法完整备份当前安装，已取消更新。"
        return 1
    }
    rr_run_with_delegated_update_lock \
        "$RR_RECOVERY_HELPER" snapshot-metadata "$TX_DIR" || {
        rr_error "无法可信记录回滚目标版本与订阅端口，已在切换运行文件前取消更新。"
        return 1
    }

    NEW_RUNTIME=$(mktemp -d /usr/local/lib/.rr-install.XXXXXX) || return 1
    install -d -m 755 "$NEW_RUNTIME/modules"
    install -m 644 "$STAGE_ROOT/manifest.sha256" "$NEW_RUNTIME/manifest.sha256"
    local module_file=""
    for module_file in "$PAYLOAD_DIR"/modules/*.sh; do
        install -m 644 "$module_file" "$NEW_RUNTIME/modules/$(basename "$module_file")" || return 1
    done
    if [ -n "${RR_GUARD_FILE:-}" ]; then
        [ -s "$RR_GUARD_FILE" ] && bash -n "$RR_GUARD_FILE" && \
            grep -q '^RR_UPDATE_GUARD_VERSION=' "$RR_GUARD_FILE" && \
            grep -q '^do_update() {' "$RR_GUARD_FILE" || return 1
        install -m 644 "$RR_GUARD_FILE" "$NEW_RUNTIME/modules/61-update-guard.sh" || return 1
    fi
    install -d -m 755 "$NEW_RUNTIME/scripts"
    install -m 755 "$PAYLOAD_DIR/scripts/naive-cert-hook.sh" \
        "$NEW_RUNTIME/scripts/naive-cert-hook.sh" || return 1
    install -m 755 "$PAYLOAD_DIR/scripts/update-recover.sh" \
        "$NEW_RUNTIME/scripts/update-recover.sh" || return 1
    install -m 755 "$PAYLOAD_DIR/scripts/update-external-state.py" \
        "$NEW_RUNTIME/scripts/update-external-state.py" || return 1
    if [ -f "$PAYLOAD_DIR/nexus/rr_nexus.py" ]; then
        # Nexus 后端与前端均以已校验的 manifest 为唯一来源。允许安全地
        # 拆分 Python/JS/CSS 模块，不再需要同步维护安装器文件白名单。
        local relative_path=""
        while read -r _ relative_path; do
            case "$relative_path" in
                nexus/rr_nexus.py|nexus/sub_server.py|nexus/rr_nexus_lib/*.py)
                    [ -f "$PAYLOAD_DIR/$relative_path" ] || return 1
                    install -d -m 755 "$NEW_RUNTIME/$(dirname "$relative_path")" || return 1
                    install -m 755 "$PAYLOAD_DIR/$relative_path" \
                        "$NEW_RUNTIME/$relative_path" || return 1
                    ;;
                nexus/static/*.html|nexus/static/*.css|nexus/static/*.js)
                    [ -f "$PAYLOAD_DIR/$relative_path" ] || return 1
                    install -d -m 755 "$NEW_RUNTIME/$(dirname "$relative_path")" || return 1
                    install -m 644 "$PAYLOAD_DIR/$relative_path" \
                        "$NEW_RUNTIME/$relative_path" || return 1
                    ;;
            esac
        done < "$STAGE_ROOT/manifest.sha256"
    fi
    NEW_LAUNCHER=$(mktemp /usr/local/bin/.rr.new.XXXXXX) || return 1
    install -m 755 "$PAYLOAD_DIR/rr" "$NEW_LAUNCHER" || return 1

    TRANSACTION_ACTIVE=true
    rr_write_phase switching || return 1
    if [ -e "$RR_LIB_DIR" ]; then
        OLD_RUNTIME="$TX_DIR/old-runtime"
        if ! mv "$RR_LIB_DIR" "$OLD_RUNTIME"; then
            TRANSACTION_ACTIVE=false
            return 1
        fi
        rr_test_fault old_runtime_moved || return 1
    fi
    RUNTIME_REPLACED=true
    mv "$NEW_RUNTIME" "$RR_LIB_DIR" || return 1
    NEW_RUNTIME=""
    rr_write_phase runtime_swapped || return 1
    rr_test_fault runtime_swapped || return 1
    mv "$NEW_LAUNCHER" "$RR_LAUNCHER" || return 1
    NEW_LAUNCHER=""

    # A host previously rolled back to an unsafe runtime may already have the
    # independent quarantine reserving SUB_PORT.  Suspend only its process;
    # keep the marker/firewall until the safe candidate has fully migrated so
    # a crash still causes boot recovery to re-apply the quarantine.
    if rr_version_ge "$release_version" "$RR_SUBSCRIPTION_SAFE_VERSION"; then
        rr_run_with_delegated_update_lock \
            "$RR_RECOVERY_HELPER" suspend-quarantine || return 1
    fi

    rr_write_phase migrating || return 1
    if ! RR_UPDATE_TRANSACTION=1 \
        RR_UPDATE_SINGBOX_WAS_RUNNING="$([ -f "$BACKUP_DIR/singbox_was_running" ] && printf true || printf false)" \
        RR_UPDATE_NEXUS_WAS_RUNNING="$([ -f "$BACKUP_DIR/nexus_was_running" ] && printf true || printf false)" \
        RR_UPDATE_SUBSCRIPTION_WAS_RUNNING="$([ -f "$BACKUP_DIR/subscription_was_running" ] && printf true || printf false)" \
        RR_UPDATE_ARGO_WAS_RUNNING="$([ -f "$BACKUP_DIR/argo_was_running" ] && printf true || printf false)" \
        RR_UPDATE_HEALTH_TIMER_WAS_ENABLED="$([ -f "$BACKUP_DIR/health_timer_was_enabled" ] && printf true || printf false)" \
        rr_run_with_delegated_update_lock "$RR_LAUNCHER" --post-update; then
        rr_rollback
        return 1
    fi
    if [ ! -f "$BACKUP_DIR/runtime_did_not_exist" ] && \
       ! rr_verify_update_writer_state "$BACKUP_DIR"; then
        rr_error "候选版本未恢复升级前的服务启用/运行状态，正在回滚。"
        rr_rollback
        return 1
    fi
    rr_test_fault migrated || return 1

    # Once migration and writer-state verification have succeeded, make the
    # safe candidate durable before attempting quarantine retirement. A later
    # cleanup failure must retain the candidate/evidence, never resurrect the
    # vulnerable runtime that the barrier was protecting.
    rr_sync_host_state_before_terminal || return 1
    if ! rr_write_phase committed; then
        rr_rollback
        return 1
    fi
    TRANSACTION_ACTIVE=false
    RR_HEALTH_MONITOR_FROZEN=false
    RR_UPDATE_WRITERS_FROZEN=false
    KEEP_TRANSACTION=true
    if rr_version_ge "$release_version" "$RR_SUBSCRIPTION_SAFE_VERSION" &&
       ! rr_run_with_delegated_update_lock \
           "$RR_RECOVERY_HELPER" clear-quarantine; then
        rr_error "安全版本已提交，但旧版订阅隔离尚未完整清理；事务与维护标记已保留，绝不回滚到旧版。"
        return 1
    fi
    if ! rr_run_with_delegated_update_lock \
        "$RR_LAUNCHER" --post-update-finalize; then
        rr_error "版本已提交，但订阅防火墙收尾失败；事务与维护标记已保留，绝不回滚已提交版本。"
        return 1
    fi
    # clear-quarantine deliberately stops every managed subscription worker.
    # Restore only that affected writer here: the remaining unit state already
    # passed the migration gate, and restarting healthy Nexus/Sing-box units
    # would create a needless post-commit readiness race.
    if ! rr_reconcile_committed_writer_state "$BACKUP_DIR"; then
        rr_error "版本已提交，但升级前的订阅状态无法恢复或最终服务状态校验失败；事务与维护标记已保留，等待安全恢复。"
        return 1
    fi
    if ! sync; then
        rr_error "版本已提交，但收尾状态无法持久化；事务与维护标记已保留，等待安全恢复。"
        return 1
    fi
    if ! rr_publish_committed_settled "$TX_DIR"; then
        rr_error "版本已提交，但无法持久发布收尾证据；事务与维护标记已保留，等待安全恢复。"
        return 1
    fi
    rr_clear_update_maintenance_marker "$TX_DIR" || return 1
    return 0
}

case "$RR_MODE" in
    install|--upgrade) ;;
    *)
        rr_error "未知参数：${RR_MODE}"
        exit 2
        ;;
esac

trap 'rr_cleanup "$?"' EXIT
trap 'exit 130' INT TERM HUP

rr_check_system || exit 1
rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE" || {
    rr_error "共享更新锁文件不安全，已拒绝安装/更新。"
    exit 1
}
exec {UPDATE_LOCK_FD}>>"$RR_UPDATE_LOCK_FILE" || exit 1
rr_update_lock_fd_is_safe "$RR_UPDATE_LOCK_FILE" "$UPDATE_LOCK_FD" || {
    exec {UPDATE_LOCK_FD}>&-
    rr_error "共享更新锁文件在打开时发生变化，已拒绝安装/更新。"
    exit 1
}
if ! flock -n "$UPDATE_LOCK_FD"; then
    rr_error "另一个安装/更新任务正在运行，本次未改动系统。"
    exit 1
fi
if ! rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"; then
    exec {UPDATE_LOCK_FD}>&-
    UPDATE_LOCK_FD=""
    exit 1
fi
rr_fetch_release || exit 1
rr_install_release || exit 1

if [ "$RR_MODE" = "--upgrade" ]; then
    # --post-update 已完成迁移与服务恢复；这里不得再用 || true 掩盖失败，
    # 也不得把用户原本停用的服务无条件拉起。
    echo "[RR-vps] 模块化热更新完成。"
    exit 0
fi
echo "[RR-vps] 安装/迁移完成，原有节点配置（如有）已保留。"
rr_cleanup 0
trap - EXIT
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    # The management shell must not inherit the transaction lock forever.
    # Release in reverse acquisition order, only after cleanup and immediately
    # before exec.
    if [ -n "$LEGACY_UPDATE_LOCK_FD" ]; then
        exec {LEGACY_UPDATE_LOCK_FD}>&-
        LEGACY_UPDATE_LOCK_FD=""
    fi
    exec {UPDATE_LOCK_FD}>&-
    UPDATE_LOCK_FD=""
    exec "$RR_LAUNCHER" </dev/tty >/dev/tty
fi
echo "请输入 rr 打开管理面板。"
