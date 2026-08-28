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
        [ "$json_only" = true ] || printf '\n执行安全修复…\n'
        chmod 600 "$CONFIG_FILE" /etc/rr-nexus/nexus.json /var/lib/rr-nexus/nexus.db \
            /var/lib/rr-nexus/remote.key 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
        if [ -r /etc/rr-nexus/nexus.json ]; then
            systemctl restart rr-nexus >/dev/null 2>&1 || true
        fi
        ensure_runtime_health >/dev/null 2>&1 || true
        if [ "$nodes_enabled" = true ]; then
        generate_node_and_sub >/dev/null 2>&1 || true
        open_firewall >/dev/null 2>&1 || true
        [ "${VL_ENABLED:-false}" = true ] && open_protocol_firewall "$VL_PORT" tcp
        [ "${HY2_ENABLED:-false}" = true ] && open_protocol_firewall "$HY2_PORT" udp
        [ "${TU5_ENABLED:-false}" = true ] && open_protocol_firewall "$TU5_PORT" udp
        [ "${AN_ENABLED:-false}" = true ] && open_protocol_firewall "$AN_PORT" tcp
        if [ "${NAIVE_ENABLED:-false}" = true ]; then
            [ "${NAIVE_MODE:-h2}" = h3 ] || open_protocol_firewall "$NAIVE_PORT" tcp
            [ "${NAIVE_MODE:-h2}" = h2 ] || open_protocol_firewall "$NAIVE_PORT" udp
        fi
        fi
        [ "$json_only" = true ] || printf '安全修复完成；请再次运行 rr doctor 验证。\n'
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
    local root="$1" policy="${2:-portable}" source="" relative="" target="" temporary="" mode=""
    [ -d "$root/rootfs" ] || return 1
    [ "$policy" = full ] || [ "$policy" = portable ] || return 1
    while IFS= read -r -d '' source; do
        relative="${source#"$root/rootfs/"}"
        case "$relative" in
            etc/argo_vmess.conf|etc/sing-box/*|etc/rr-nexus/*|etc/rr-naive/*|etc/rr-update/*|etc/rr-cloudflared/*|\
            var/lib/rr-nexus/*) ;;
            usr/local/bin/auto_update_sub.py|etc/systemd/system/sing-box.service|\
            etc/systemd/system/rr-nexus.service|etc/systemd/system/argo-rr-health.service|\
            etc/systemd/system/argo-rr-health.timer)
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
        target="/$relative"
        mkdir -p "$(dirname "$target")" || return 1
        temporary="$(dirname "$target")/.rr-restore.$$.tmp"
        # Never trust archived permission bits.  In particular, a crafted
        # backup must not be able to restore setuid/setgid files.
        case "$relative" in
            usr/local/bin/*.py) mode=755 ;;
            etc/systemd/system/*.service|etc/systemd/system/*.timer) mode=644 ;;
            *) mode=600 ;;
        esac
        install -m "$mode" "$source" "$temporary" || return 1
        mv -f "$temporary" "$target" || return 1
    done < <(find "$root/rootfs" -type f -print0 | LC_ALL=C sort -z)
}

rr_restore_clear_managed_tree() {
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
    ensure_subscription_root || return 1
    [ "$SUB_ROOT" = /tmp/sub_server ] || return 1
    find "$SUB_ROOT" -mindepth 1 -xdev -delete || return 1
    rm -rf -- /var/lib/rr-nexus || return 1
    install -d -m 700 /var/lib/rr-nexus || return 1
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
    # Portable backups contain data/config only. Recreate privileged units and
    # executable workers from the already verified local RR runtime.
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        nexus_write_service || return 1
    fi
    return 0
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
    if [ -e "$CONFIG_FILE" ]; then
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
        /var/lib/rr-nexus /tmp/sub_server; do
        if [ -e "$collision" ] || [ -L "$collision" ]; then
            printf '目标机已有非 RR 所有权路径，拒绝恢复覆盖：%s\n' "$collision" >&2
            return 1
        fi
    done
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
       ! mv -f -- "$temporary" "$marker" || ! sync -f "$directory"; then
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
       ! mv -f -- "$temporary" "$stage/phase" || ! sync -f "$stage"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_restore_write_gate_dropins() {
    local unit="" dropin_dir="" temporary=""
    for unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        dropin_dir="${RR_RESTORE_SYSTEMD_DIR}/${unit}.d"
        install -d -m 755 "$dropin_dir" || return 1
        temporary=$(mktemp "$dropin_dir/.40-rr-restore-gate.XXXXXX") || return 1
        if ! cat > "$temporary" <<'EOF'
[Service]
ExecCondition=/bin/sh -c 'if [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]; then exit 0; fi; exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'
EOF
        then
            rm -f -- "$temporary"
            return 1
        fi
        chmod 644 "$temporary" && \
            mv -f -- "$temporary" "$dropin_dir/40-rr-restore-gate.conf" && \
            sync -f "$dropin_dir" || {
                rm -f -- "$temporary"
                return 1
            }
    done
}

rr_restore_prepare_recovery_unit() {
    local recovery_tmp="" watchdog_tmp=""
    install -d -m 755 "$RR_RESTORE_SYSTEMD_DIR" || return 1
    recovery_tmp=$(mktemp "$RR_RESTORE_SYSTEMD_DIR/.rr-restore-recovery.XXXXXX") || return 1
    watchdog_tmp=$(mktemp "$RR_RESTORE_SYSTEMD_DIR/.rr-restore-watchdog.XXXXXX") || {
        rm -f -- "$recovery_tmp"
        return 1
    }
    if ! cat > "$recovery_tmp" <<'EOF'
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
    then
        rm -f -- "$recovery_tmp" "$watchdog_tmp"
        return 1
    fi
    if ! cat > "$watchdog_tmp" <<'EOF'
[Unit]
Description=RR-vps live portable restore watchdog
After=local-fs.target

[Service]
Type=exec
ExecStart=/usr/local/bin/rr --watch-restore
RuntimeMaxSec=3700
TimeoutStopSec=10
EOF
    then
        rm -f -- "$recovery_tmp" "$watchdog_tmp"
        return 1
    fi
    chmod 644 "$recovery_tmp" "$watchdog_tmp" && \
        mv -f -- "$recovery_tmp" "$RR_RESTORE_SYSTEMD_DIR/rr-restore-recovery.service" && \
        mv -f -- "$watchdog_tmp" "$RR_RESTORE_SYSTEMD_DIR/rr-restore-watchdog.service" && \
        sync -f "$RR_RESTORE_SYSTEMD_DIR" || {
            rm -f -- "$recovery_tmp" "$watchdog_tmp"
            return 1
        }
    rr_restore_write_gate_dropins || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable rr-restore-recovery.service >/dev/null 2>&1 || return 1
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

rr_restore_watch_active_locked() {
    local expected_stage="" current_stage="" armed_from_request=false result=0
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
    fi
    rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || return 1
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || true
        # SIGKILL before `active` publication cannot require state rollback,
        # but the decrypted staging tree must not be left behind.
        [ "$armed_from_request" = false ] || rm -rf -- "$expected_stage"
        return 0
    fi
    current_stage=$(rr_restore_active_stage) || return 1
    [ "$current_stage" = "$expected_stage" ] || return 1
    rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || return 1
    RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
        rr_restore_recover_active || result=$?
    return "$result"
}

rr_restore_start_watchdog() {
    systemctl reset-failed rr-restore-watchdog.service >/dev/null 2>&1 || true
    systemctl restart rr-restore-watchdog.service >/dev/null 2>&1 || return 1
    systemctl is-active --quiet rr-restore-watchdog.service >/dev/null 2>&1
}

rr_restore_filter_managed_firewall_rules() {
    local table="$1" source="$2" target="$3"
    python3 - "$table" "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
        "$source" > "$target" <<'PY'
import shlex
import sys

table, allow_comment, block_comment, source = sys.argv[1:]
for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit("invalid firewall rule syntax")
    if len(tokens) < 3 or tokens[0] != "-A":
        continue
    try:
        comment = tokens[tokens.index("--comment") + 1]
    except (ValueError, IndexError):
        continue
    if table == "filter":
        managed = tokens[1] == "INPUT" and comment in {allow_comment, block_comment}
    elif table == "nat":
        managed = tokens[1] == "PREROUTING" and comment.startswith("argo-rr-")
    else:
        raise SystemExit("unsupported firewall table")
    if managed:
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

rr_restore_capture_ufw_rules() {
    local target="$1" raw=""
    raw=$(mktemp "$(dirname "$target")/.ufw.XXXXXX") || return 1
    if ! LC_ALL=C ufw show added > "$raw" 2>/dev/null; then
        rm -f "$raw"
        return 1
    fi
    if ! python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
        "$raw" > "$target" <<'PY'
import shlex
import sys

managed_comments = set(sys.argv[1:3])
for raw_line in open(sys.argv[3], encoding="utf-8"):
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
        continue
    if comment in managed_comments:
        print(line)
PY
    then
        rm -f "$raw" "$target"
        return 1
    fi
    rm -f "$raw"
}

rr_restore_capture_firewall_snapshot() {
    local rollback="$1" snapshot="$1/firewall" backend="" table="" state=0 marker_tmp=""
    install -d -m 700 "$snapshot" || return 1

    if rr_ufw_backend_state; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0)
            rr_restore_capture_ufw_rules "$snapshot/ufw.rules" || return 1
            : > "$snapshot/ufw.enabled" || return 1
            ;;
        1) ;;
        *) return 1 ;;
    esac

    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                : > "$snapshot/${backend}.enabled" || return 1
                for table in filter nat; do
                    rr_restore_capture_netfilter_rules "$backend" "$table" \
                        "$snapshot/${backend}.${table}.rules" || return 1
                    : > "$snapshot/${backend}.${table}.enabled" || return 1
                done
                ;;
            1) ;;
            *) return 1 ;;
        esac
    done

    marker_tmp="$snapshot/.complete.$$"
    printf '%s\n' firewall-snapshot-v1 > "$marker_tmp" && chmod 600 "$marker_tmp" && \
        mv -f "$marker_tmp" "$snapshot/complete" && sync -f "$snapshot" || {
            rm -f "$marker_tmp"
            return 1
        }
}

rr_restore_run_netfilter_saved_rule() {
    local backend="$1" table="$2" operation="$3" line="$4"
    local token=""
    local -a arguments=()
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
    case "$operation" in -A|-D) arguments[0]="$operation" ;; *) return 1 ;; esac
    "$backend" -w 5 -t "$table" "${arguments[@]}" >/dev/null 2>&1
}

rr_restore_run_ufw_saved_rule() {
    local operation="$1" line="$2" token=""
    local -a arguments=()
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
    case "$operation" in
        add) ufw --force "${arguments[@]:1}" >/dev/null 2>&1 ;;
        delete) ufw --force delete "${arguments[@]:1}" >/dev/null 2>&1 ;;
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
    local backend="" table="" state=0 failed=false
    rr_restore_clear_ufw_rules || failed=true
    for backend in iptables ip6tables; do
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

rr_restore_restore_firewall_snapshot() {
    local rollback="$1" snapshot="$1/firewall" backend="" table="" line=""
    local state=0 failed=false netfilter_seen=false current=""
    # Transactions created before firewall snapshots were introduced remain
    # recoverable. New transactions always carry the durable complete marker.
    [ -d "$snapshot" ] || return 0
    [ -f "$snapshot/complete" ] && [ ! -L "$snapshot/complete" ] || return 1

    rr_restore_clear_managed_firewall || return 1
    if [ -f "$snapshot/ufw.enabled" ]; then
        if rr_ufw_backend_state; then state=0; else state=$?; fi
        [ "$state" -eq 0 ] || return 1
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            rr_restore_run_ufw_saved_rule add "$line" || failed=true
        done < "$snapshot/ufw.rules"
    fi

    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        netfilter_seen=true
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        if [ "$state" -ne 0 ]; then
            failed=true
            continue
        fi
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                rr_restore_run_netfilter_saved_rule "$backend" "$table" -A "$line" || failed=true
            done < "$snapshot/${backend}.${table}.rules"
        done
    done

    if [ -f "$snapshot/ufw.enabled" ]; then
        current=$(mktemp "$snapshot/.verify-ufw.XXXXXX") || return 1
        rr_restore_capture_ufw_rules "$current" || failed=true
        cmp -s "$snapshot/ufw.rules" "$current" || failed=true
        rm -f "$current"
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        for table in filter nat; do
            [ -f "$snapshot/${backend}.${table}.enabled" ] || continue
            current=$(mktemp "$snapshot/.verify-${backend}-${table}.XXXXXX") || return 1
            rr_restore_capture_netfilter_rules "$backend" "$table" "$current" || failed=true
            cmp -s "$snapshot/${backend}.${table}.rules" "$current" || failed=true
            rm -f "$current"
        done
    done
    if [ "$netfilter_seen" = true ] && ! save_firewall; then
        failed=true
    fi
    [ "$failed" = false ]
}

rr_restore_snapshot_nginx() {
    local rollback="$1" source=""
    mkdir -p "$rollback/nginx/sites-available" "$rollback/nginx/sites-enabled" || return 1
    for source in \
        /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf; do
        [ -e "$source" ] || continue
        cp -a -- "$source" "$rollback/nginx/sites-available/" || return 1
    done
    for source in \
        /etc/nginx/sites-enabled/rr-nexus.conf \
        /etc/nginx/sites-enabled/rr-nexus-port.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip.conf; do
        [ -e "$source" ] || [ -L "$source" ] || continue
        cp -a -- "$source" "$rollback/nginx/sites-enabled/" || return 1
    done
    systemctl is-active --quiet nginx 2>/dev/null && : > "$rollback/nginx_was_running"
    systemctl is-enabled --quiet nginx 2>/dev/null && : > "$rollback/nginx_was_enabled"
    return 0
}

rr_restore_capture_target_network() {
    local rollback="$1"
    local target_entry_mode=auto target_outbound_mode=auto
    local target_entry_v4="" target_entry_v6="" target_sub_v4="" target_sub_v6=""
    if [ -r "$CONFIG_FILE" ]; then
        : > "$rollback/target_rr_was_present" || return 1
        load_config_with_defaults || return 1
        target_entry_mode="${ENTRY_IP_MODE:-auto}"
        target_outbound_mode="${OUTBOUND_IP_MODE:-auto}"
        target_entry_v4="${ENTRY_IPV4_ADDRESS:-}"
        target_entry_v6="${ENTRY_IPV6_ADDRESS:-}"
        target_sub_v4="${SUB_PUBLIC_PORT_IPV4:-${SUB_PORT:-}}"
        target_sub_v6="${SUB_PUBLIC_PORT_IPV6:-${SUB_PORT:-}}"
    fi
    {
        printf 'TARGET_ENTRY_IP_MODE=%q\n' "$target_entry_mode"
        printf 'TARGET_OUTBOUND_IP_MODE=%q\n' "$target_outbound_mode"
        printf 'TARGET_ENTRY_IPV4_ADDRESS=%q\n' "$target_entry_v4"
        printf 'TARGET_ENTRY_IPV6_ADDRESS=%q\n' "$target_entry_v6"
        printf 'TARGET_SUB_PUBLIC_PORT_IPV4=%q\n' "$target_sub_v4"
        printf 'TARGET_SUB_PUBLIC_PORT_IPV6=%q\n' "$target_sub_v6"
    } > "$rollback/target-network" || return 1
    chmod 600 "$rollback/target-network"
}

rr_restore_capture_target_nexus_state() {
    local rollback="$1" access_tmp=""
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
            ((has("acme_email") | not) or ((.acme_email | type) == "string"))
        ' "$NEXUS_CONFIG_FILE" >/dev/null || return 1
        jq '{mode,domain,public_port} +
            (if has("acme_email") then {acme_email:.acme_email} else {} end)' \
            "$NEXUS_CONFIG_FILE" > "$access_tmp" || { rm -f "$access_tmp"; return 1; }
        : > "$rollback/target_nexus_was_present" || { rm -f "$access_tmp"; return 1; }
    else
        jq -cn '{mode:"local",domain:"",public_port:7900}' > "$access_tmp" || return 1
    fi
    chmod 600 "$access_tmp" && mv -f "$access_tmp" "$rollback/target-nexus-access.json" || {
        rm -f "$access_tmp"
        return 1
    }
    if systemctl is-enabled --quiet rr-nexus 2>/dev/null; then
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
        for cert_name in ip.crt ip.key; do
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

rr_restore_set_nexus_enablement() {
    local enabled="$1"
    if [ "$enabled" = true ]; then
        [ -r "$NEXUS_CONFIG_FILE" ] && [ -f "$NEXUS_SERVICE_FILE" ] || return 1
        systemctl enable rr-nexus >/dev/null 2>&1 || return 1
        systemctl is-enabled --quiet rr-nexus 2>/dev/null || return 1
        return 0
    fi
    [ "$enabled" = false ] || return 1
    systemctl disable rr-nexus >/dev/null 2>&1 || true
    ! systemctl is-enabled --quiet rr-nexus 2>/dev/null
}

rr_restore_finalize_nexus_enablement() {
    local rollback="$1" enabled=false
    if [ -r "$NEXUS_CONFIG_FILE" ] || [ -f "$NEXUS_SERVICE_FILE" ]; then
        [ -r "$NEXUS_CONFIG_FILE" ] && [ -f "$NEXUS_SERVICE_FILE" ] || return 1
        if [ -f "$rollback/target_nexus_was_present" ]; then
            [ -f "$rollback/nexus_was_enabled" ] && enabled=true
        else
            # A valid Nexus imported onto a machine without Nexus is a new
            # managed service.  It must survive the first reboot.
            enabled=true
        fi
    fi
    rr_restore_set_nexus_enablement "$enabled"
}

rr_restore_restore_nexus_enablement() {
    local rollback="$1" enabled=false
    [ -f "$rollback/nexus_was_enabled" ] && enabled=true
    rr_restore_set_nexus_enablement "$enabled"
}

rr_restore_apply_target_network() {
    local rollback="$1"
    [ -r "$rollback/target-network" ] || return 1
    # This file was generated locally with printf %q before the mutation and
    # is never accepted from the imported archive.
    # shellcheck disable=SC1090
    source "$rollback/target-network" || return 1
    load_config_with_defaults || return 1
    is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV4" || TARGET_SUB_PUBLIC_PORT_IPV4="$SUB_PORT"
    is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV6" || TARGET_SUB_PUBLIC_PORT_IPV6="$SUB_PORT"
    safe_sed ENTRY_IP_MODE "$TARGET_ENTRY_IP_MODE" || return 1
    safe_sed OUTBOUND_IP_MODE "$TARGET_OUTBOUND_IP_MODE" || return 1
    safe_sed ENTRY_IPV4_ADDRESS "$TARGET_ENTRY_IPV4_ADDRESS" || return 1
    safe_sed ENTRY_IPV6_ADDRESS "$TARGET_ENTRY_IPV6_ADDRESS" || return 1
    if is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV4"; then
        safe_sed SUB_PUBLIC_PORT_IPV4 "$TARGET_SUB_PUBLIC_PORT_IPV4" || return 1
    fi
    if is_valid_port "$TARGET_SUB_PUBLIC_PORT_IPV6"; then
        safe_sed SUB_PUBLIC_PORT_IPV6 "$TARGET_SUB_PUBLIC_PORT_IPV6" || return 1
    fi
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
    local rollback="$1" source=""
    rm -f -- /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf \
        /etc/nginx/sites-enabled/rr-nexus.conf \
        /etc/nginx/sites-enabled/rr-nexus-port.conf \
        /etc/nginx/sites-enabled/rr-nexus-ip.conf || return 1
    install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled || return 1
    for source in "$rollback"/nginx/sites-available/*; do
        [ -e "$source" ] || continue
        cp -a -- "$source" /etc/nginx/sites-available/ || return 1
    done
    for source in "$rollback"/nginx/sites-enabled/*; do
        [ -e "$source" ] || [ -L "$source" ] || continue
        cp -a -- "$source" /etc/nginx/sites-enabled/ || return 1
    done
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || return 1
    fi
}

rr_restore_activate_nginx_state() {
    local rollback="$1"
    if command -v nginx >/dev/null 2>&1; then
        if [ -f "$rollback/nginx_was_enabled" ]; then
            systemctl enable nginx >/dev/null 2>&1 || return 1
        else
            systemctl disable nginx >/dev/null 2>&1 || true
        fi
        if [ -f "$rollback/nginx_was_running" ]; then
            systemctl restart nginx >/dev/null 2>&1 || return 1
        else
            systemctl stop nginx >/dev/null 2>&1 || true
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

rr_restore_stop_managed_runtime() {
    local failed=false
    load_config_with_defaults >/dev/null 2>&1 || true
    systemctl stop rr-nexus sing-box >/dev/null 2>&1 || true
    systemctl stop argo-rr-health.timer argo-rr-health.service >/dev/null 2>&1 || true
    stop_subscription_servers >/dev/null 2>&1 || failed=true
    stop_quick_argo_tunnel >/dev/null 2>&1 || true
    if [ "${TUNNEL_MODE:-1}" = 2 ] && [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        # Freezing must be reversible even if the process is killed before a
        # rollback snapshot is complete.  Stop the RR-owned fixed tunnel here;
        # uninstall it only after the durable transaction reaches `mutating`.
        systemctl stop cloudflared >/dev/null 2>&1 || true
    fi
    systemctl is-active --quiet rr-nexus 2>/dev/null && failed=true
    systemctl is-active --quiet sing-box 2>/dev/null && failed=true
    systemctl is-active --quiet argo-rr-health.timer 2>/dev/null && failed=true
    systemctl is-active --quiet argo-rr-health.service 2>/dev/null && failed=true
    subscription_server_running && failed=true
    expected_argo_tunnel_running >/dev/null 2>&1 && failed=true
    [ "$failed" = false ]
}

rr_restore_freeze_writers() {
    # Nexus is the authoritative SQLite/key writer.  The health timer can
    # trigger a sync while the snapshot is being assembled.  Other data-plane
    # services do not write the portable state and stay online until the
    # rollback snapshot is durably committed.
    systemctl stop rr-nexus >/dev/null 2>&1 || true
    systemctl stop argo-rr-health.timer argo-rr-health.service >/dev/null 2>&1 || true
    ! systemctl is-active --quiet rr-nexus 2>/dev/null && \
        ! systemctl is-active --quiet argo-rr-health.timer 2>/dev/null && \
        ! systemctl is-active --quiet argo-rr-health.service 2>/dev/null
}

rr_restore_resume_frozen_writers() {
    local rollback="$1" failed=false
    load_config_with_defaults >/dev/null 2>&1 || failed=true
    select_entry_ip >/dev/null 2>&1 || failed=true
    if [ -f "$rollback/singbox_was_running" ]; then
        systemctl start sing-box >/dev/null 2>&1 || failed=true
        systemctl is-active --quiet sing-box 2>/dev/null || failed=true
    else
        systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    if [ -f "$rollback/subscription_was_running" ]; then
        rr_run_without_inherited_update_lock_fds \
            start_subscription_server >/dev/null 2>&1 || failed=true
        subscription_server_running || failed=true
    else
        stop_subscription_servers >/dev/null 2>&1 || true
    fi
    if [ -f "$rollback/argo_was_running" ]; then
        rr_run_without_inherited_update_lock_fds \
            start_argo_tunnel >/dev/null 2>&1 || failed=true
        expected_argo_tunnel_running >/dev/null 2>&1 || failed=true
    else
        stop_quick_argo_tunnel >/dev/null 2>&1 || true
        systemctl stop cloudflared >/dev/null 2>&1 || true
    fi
    if [ -f "$rollback/nexus_was_running" ]; then
        systemctl start rr-nexus >/dev/null 2>&1 || failed=true
        systemctl is-active --quiet rr-nexus 2>/dev/null || failed=true
    else
        systemctl stop rr-nexus >/dev/null 2>&1 || true
    fi
    if [ -f "$rollback/health_timer_was_running" ]; then
        systemctl start argo-rr-health.timer >/dev/null 2>&1 || failed=true
        systemctl is-active --quiet argo-rr-health.timer 2>/dev/null || failed=true
    else
        systemctl stop argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    [ "$failed" = false ]
}

rr_restore_remove_managed_fixed_tunnel() {
    load_config_with_defaults >/dev/null 2>&1 || true
    if [ "${TUNNEL_MODE:-1}" = 2 ] && [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        systemctl disable --now cloudflared >/dev/null 2>&1 || true
        if systemctl cat cloudflared >/dev/null 2>&1; then
            cloudflared service uninstall >/dev/null 2>&1 || return 1
        fi
    fi
}

rr_restore_apply_cloudflared_snapshot() {
    local rollback="$1"
    [ -f "$rollback/cloudflared_service_was_present" ] || return 0
    install -m 644 "$rollback/cloudflared.service" /etc/systemd/system/cloudflared.service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if [ -f "$rollback/cloudflared_was_enabled" ]; then
        systemctl enable cloudflared >/dev/null 2>&1 || return 1
    else
        systemctl disable cloudflared >/dev/null 2>&1 || true
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
        if [ -f "$rollback/singbox_was_enabled" ]; then
            systemctl enable sing-box >/dev/null 2>&1 || failed=true
            systemctl is-enabled --quiet sing-box 2>/dev/null || failed=true
        else
            systemctl disable sing-box >/dev/null 2>&1 || true
            systemctl is-enabled --quiet sing-box 2>/dev/null && failed=true
        fi
        if [ -f "$rollback/singbox_was_running" ]; then
            systemctl start sing-box >/dev/null 2>&1 || failed=true
            systemctl is-active --quiet sing-box 2>/dev/null || failed=true
        else
            systemctl stop sing-box >/dev/null 2>&1 || true
            systemctl is-active --quiet sing-box 2>/dev/null && failed=true
        fi
    fi

    if [ -f /etc/systemd/system/argo-rr-health.timer ]; then
        if [ -f "$rollback/health_timer_was_enabled" ]; then
            systemctl enable argo-rr-health.timer >/dev/null 2>&1 || failed=true
            systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null || failed=true
        else
            systemctl disable argo-rr-health.timer >/dev/null 2>&1 || true
            systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && failed=true
        fi
        if [ -f "$rollback/health_timer_was_running" ]; then
            systemctl start argo-rr-health.timer >/dev/null 2>&1 || failed=true
            systemctl is-active --quiet argo-rr-health.timer 2>/dev/null || failed=true
        else
            systemctl stop argo-rr-health.timer >/dev/null 2>&1 || true
            systemctl is-active --quiet argo-rr-health.timer 2>/dev/null && failed=true
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
    rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || return 1
    if ! rr_restore_resume_frozen_writers "$rollback"; then
        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true
        # Keep this distinct from a failed full rollback: the snapshot may be
        # incomplete in `freezing`/`frozen`, so a later recovery must never
        # clear the live tree and apply that partial snapshot.
        rr_restore_write_phase "$stage" pre_recovery_failed || true
        printf '恢复事务在写入前中断，自动恢复服务失败；证据已保留在 %s。\n' "$stage" >&2
        return 1
    fi
    rr_restore_write_phase "$stage" aborted || return 1
    rr_restore_clear_marker "$RR_RESTORE_ACTIVE" || return 1
    rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || return 1
}

rr_restore_rollback_stage() {
    local stage="$1" rollback="" failed=false
    rollback="$stage/rollback"
    [ -d "$rollback/rootfs" ] && [ -f "$rollback/complete" ] && [ ! -L "$rollback/complete" ] || {
        printf '回滚快照未完整提交，拒绝清理当前运行目录：%s。\n' "$rollback" >&2
        return 1
    }
    rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || return 1
    rr_restore_write_phase "$stage" rolling_back || return 1
    if ! rr_restore_stop_managed_runtime; then
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
    rr_restore_clear_managed_tree || failed=true
    rr_restore_apply_tree "$rollback" full || failed=true
    rr_refresh_update_channel_constants || failed=true
    rr_restore_crontab "$rollback/crontab.txt" || failed=true
    rr_restore_regenerate_runtime_files || failed=true
    rr_restore_restore_nginx "$rollback" files || failed=true
    rr_restore_apply_cloudflared_snapshot "$rollback" || failed=true
    rr_restore_restore_firewall_snapshot "$rollback" || failed=true
    rr_restore_restore_nexus_enablement "$rollback" || failed=true
    if [ "$failed" = false ]; then
        # All original data, configuration, units, proxy files and firewall
        # rules are durable before any service is allowed through its gate.
        rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_restore_restore_nginx "$rollback" activate || failed=true
        rr_restore_migrate_with_original_state "$rollback" >/dev/null 2>&1 || failed=true
        # Migration is allowed to reconcile derived rules; restore the exact
        # pre-transaction RR set once more before declaring rollback complete.
        rr_restore_restore_firewall_snapshot "$rollback" || failed=true
        rr_restore_restore_nexus_enablement "$rollback" || failed=true
    fi
    if [ -f "$rollback/cloudflared_service_was_present" ]; then
        if [ -f "$rollback/cloudflared_was_running" ]; then
            systemctl start cloudflared >/dev/null 2>&1 || failed=true
        else
            systemctl stop cloudflared >/dev/null 2>&1 || true
        fi
    fi
    if [ "$failed" = true ]; then
        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true
        rr_restore_write_phase "$stage" recovery_failed || true
        printf '恢复原机状态时发生二次故障；证据已保留在 %s。\n' "$stage" >&2
        return 1
    fi
    rr_restore_write_phase "$stage" rolled_back || return 1
    rr_restore_clear_marker "$RR_RESTORE_ACTIVE" || return 1
    rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || return 1
}

rr_restore_recover_active() {
    if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then
        return 0
    fi
    if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ] || [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ]; then
        if [ "${RR_UPDATE_LOCK_OWNER:-0}" = 1 ] || \
           [ "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" = 1 ]; then
            rr_restore_recover_active_locked
        else
            rr_run_without_inherited_update_lock_fds rr_restore_recover_active_locked
        fi
        return $?
    fi
    local result=0
    rr_run_with_update_locks direct 0 rr_restore_recover_active_locked || result=$?
    if [ "$result" -eq 75 ] || [ "$result" -eq 76 ]; then result=1; fi
    return "$result"
}

rr_restore_recover_active_locked() {
    local stage="" phase=""
    stage=$(rr_restore_active_stage) || return 1
    phase=$(rr_restore_read_exact_marker "$stage/phase") || return 1
    case "$phase" in
        freezing|frozen|prepared|pre_recovery_failed)
            rr_restore_abort_pre_mutation_stage "$stage" || return 1
            rm -rf -- "$stage"
            ;;
        committed|rolled_back|aborted)
            rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || return 1
            rr_restore_clear_marker "$RR_RESTORE_ACTIVE" || return 1
            rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || return 1
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
        /etc/nginx/sites-available/rr-nexus.conf \
        /etc/nginx/sites-available/rr-nexus.conf.port \
        /etc/nginx/sites-available/rr-nexus-ip.conf <<'PY'
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
    rr_run_with_update_locks direct 0 rr_restore_backup_locked "$@" || result=$?
    if [ "$result" -eq 75 ]; then
        printf '另一个更新、备份恢复或迁移事务正在运行。\n' >&2
        return 1
    fi
    [ "$result" -ne 76 ] || result=1
    return "$result"
)

rr_restore_backup_locked() {
    local input="${1:-}" stage="" archive="" rollback="" result=1 backup_format="" restore_live_fd="" snapshot_tmp="" rollback_reserve=""
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
    if [ -e "$NEXUS_CONFIG_FILE" ] || [ -L "$NEXUS_CONFIG_FILE" ]; then
        rr_backup_sqlite_validate "$NEXUS_DB_FILE" || {
            printf '目标 Nexus 数据库缺失、损坏或结构不匹配，恢复未开始。\n' >&2
            rm -rf "$stage"
            return 1
        }
    fi
    rr_restore_migrate_legacy_fixed_token || { rm -rf "$stage"; return 1; }
    if [ -s "$stage/payload/rootfs/etc/rr-cloudflared/token" ] && \
       systemctl cat cloudflared >/dev/null 2>&1 && \
       [ ! -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        printf '目标服务器已有非 RR 管理的 cloudflared 服务；为避免覆盖其他隧道，恢复已停止。\n' >&2
        rm -rf "$stage"
        return 1
    fi

    mkdir -p "$rollback/rootfs" || { rm -rf "$stage"; return 1; }
    systemctl is-active --quiet sing-box 2>/dev/null && : > "$rollback/singbox_was_running"
    systemctl is-enabled --quiet sing-box 2>/dev/null && : > "$rollback/singbox_was_enabled"
    systemctl is-active --quiet rr-nexus 2>/dev/null && : > "$rollback/nexus_was_running"
    subscription_server_running && : > "$rollback/subscription_was_running"
    load_config_with_defaults >/dev/null 2>&1 || true
    expected_argo_tunnel_running >/dev/null 2>&1 && : > "$rollback/argo_was_running"
    systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && : > "$rollback/health_timer_was_enabled"
    systemctl is-active --quiet argo-rr-health.timer 2>/dev/null && : > "$rollback/health_timer_was_running"
    rr_restore_capture_target_network "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_capture_target_nexus_state "$rollback" || { rm -rf "$stage"; return 1; }
    rr_restore_snapshot_nginx "$rollback" || { rm -rf "$stage"; return 1; }
    if [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ] && \
       [ -f /etc/systemd/system/cloudflared.service ]; then
        cp -p /etc/systemd/system/cloudflared.service "$rollback/cloudflared.service" || { rm -rf "$stage"; return 1; }
        : > "$rollback/cloudflared_service_was_present"
        systemctl is-active --quiet cloudflared 2>/dev/null && : > "$rollback/cloudflared_was_running"
        systemctl is-enabled --quiet cloudflared 2>/dev/null && : > "$rollback/cloudflared_was_enabled"
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
        rr_restore_write_phase "$stage" frozen || result=1
        rr_restore_test_phase frozen || result=1
    fi
    for target in /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared \
        /var/lib/rr-nexus/remote.key /usr/local/bin/auto_update_sub.py \
        /etc/systemd/system/sing-box.service /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/argo-rr-health.service /etc/systemd/system/argo-rr-health.timer; do
        [ "$result" -eq 0 ] || break
        [ -e "$target" ] || continue
        mkdir -p "$rollback/rootfs$(dirname "$target")" || { result=1; break; }
        cp -a -- "$target" "$rollback/rootfs$target" || { result=1; break; }
    done
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
        snapshot_tmp="$rollback/.complete.$$"
        printf '%s\n' snapshot-v1 > "$snapshot_tmp" && chmod 600 "$snapshot_tmp" && \
            mv -f "$snapshot_tmp" "$rollback/complete" && sync -f "$rollback" || result=1
        rm -f "$snapshot_tmp"
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
    rr_restore_stop_managed_runtime || result=1
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
       rr_restore_regenerate_runtime_files; then
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
        [ "$result" -ne 1 ] && rr_restore_clear_managed_firewall || result=1
        if [ "$result" -ne 1 ]; then
            if [ -f "$rollback/target_rr_was_present" ]; then
                RR_PORTABLE_RESTORE=1 rr_restore_migrate_with_original_state "$rollback" || result=1
                [ "$result" -ne 1 ] && \
                    rr_restore_finalize_original_service_state "$rollback" || result=1
            else
                RR_PORTABLE_RESTORE=1 post_update_migrate || result=1
                [ "$result" -ne 1 ] && \
                    rr_restore_finalize_nexus_enablement "$rollback" || result=1
            fi
        fi
        rr_restore_test_phase migrated || result=1
    fi
    if [ "$result" -ne 1 ]; then
        rr_restore_write_phase "$stage" committed || result=1
        [ "$result" -ne 1 ] && \
            rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage" || result=1
    fi

    if [ "$result" -ne 1 ]; then
        rr_restore_clear_marker "$RR_RESTORE_ACTIVE" || result=1
        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || result=1
    fi
    if [ "$result" -ne 1 ]; then
        rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST" || result=1
        rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER" || result=1
        exec {restore_live_fd}>&-
    fi
    if [ "$result" -ne 1 ]; then
        trap - HUP INT TERM
        rm -rf -- "$stage"
        printf '恢复完成：已根据目标服务器网络、端口、证书和防火墙重新生成运行配置。\n'
        return 0
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
