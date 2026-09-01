# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 2. 基础依赖与防火墙穿透
# ==========================================
check_supported_os() {
    if [ ! -r "$OS_RELEASE_FILE" ]; then
        echo -e "${RED}[不支持] 无法识别当前操作系统。${RESET}"
        return 1
    fi

    local os_id=""
    local os_name=""
    local os_version=""
    os_id=$(awk -F= '$1 == "ID" {gsub(/\"/, "", $2); print tolower($2); exit}' "$OS_RELEASE_FILE")
    os_name=$(awk -F= '$1 == "PRETTY_NAME" {sub(/^[^=]*=/, ""); gsub(/^\"|\"$/, ""); print; exit}' "$OS_RELEASE_FILE")
    os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/\"/, "", $2); print $2; exit}' "$OS_RELEASE_FILE")

    case "$os_id" in
        ubuntu)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "${os_version:-0}" lt "22.04"; then
                echo -e "${RED}[不支持] Ubuntu ${os_version:-未知} 版本过旧；最低支持 Ubuntu 22.04。${RESET}"
                return 1
            fi
            ;;
        debian)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "${os_version:-0}" lt "12"; then
                echo -e "${RED}[不支持] Debian ${os_version:-未知} 版本过旧；最低支持 Debian 12。${RESET}"
                return 1
            fi
            ;;
        *)
            echo -e "${RED}[不支持] 当前系统：${os_name:-未知系统}。${RESET}"
            echo -e "${YELLOW}本脚本仅支持 Ubuntu（含 24.04）和 Debian；请勿选择 Alpine。${RESET}"
            return 1
            ;;
    esac

    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}[不支持] 当前系统缺少 apt-get 或 systemd。${RESET}"
        return 1
    fi
    echo -e "${GREEN}[系统] ${os_name:-$os_id $os_version} 已通过兼容性检查。${RESET}"
}

rr_ufw_installed() {
    command -v ufw >/dev/null 2>&1 || \
        dpkg-query -W -f='${db:Status-Status}\n' ufw 2>/dev/null | grep -qx installed
}

# Every RR firewall mutation participates in one process-wide transaction
# domain.  The lock lives below a root-owned, non-writable path so the shell
# redirection used to open it cannot be redirected through an attacker-owned
# symlink.  A child shell never inherits its parent's ownership: it closes the
# inherited descriptor and must acquire a new open file description.
RR_FIREWALL_LOCK_FILE="${RR_FIREWALL_LOCK_FILE:-/run/rr-vps/locks/firewall.lock}"

rr_firewall_lock_directory_is_safe() {
    local directory="$1" mode=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c '%a' -- "$directory" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

rr_firewall_lock_file_is_safe() {
    local lock_file="$1"
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h:%s' -- "$lock_file" 2>/dev/null)" = 0:0:600:1:0 ]
}

rr_firewall_lock_prepare() {
    local directory="" lock_file="$RR_FIREWALL_LOCK_FILE" lock_directory=""
    local lock_parent=""
    [ "${EUID:-$(id -u)}" -eq 0 ] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    rr_firewall_lock_directory_is_safe /run || return 1
    [[ "$lock_file" = /* && "$lock_file" != *[[:space:]]* ]] || return 1
    [ "$(basename -- "$lock_file")" = firewall.lock ] || return 1
    lock_directory=$(dirname -- "$lock_file") || return 1
    if [ "$lock_file" = /run/rr-vps/locks/firewall.lock ]; then
        for directory in /run/rr-vps /run/rr-vps/locks; do
            if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
                # Set the restrictive mode in the mkdir syscall so an unusual
                # caller umask cannot leave a writable race window before chmod.
                mkdir -m 700 -- "$directory" || return 1
                chown 0:0 -- "$directory" || return 1
                chmod 700 -- "$directory" || return 1
            fi
            rr_firewall_lock_directory_is_safe "$directory" || return 1
        done
    else
        if [ ! -e "$lock_directory" ] && [ ! -L "$lock_directory" ]; then
            lock_parent=$(dirname -- "$lock_directory") || return 1
            rr_firewall_lock_directory_is_safe "$lock_parent" || return 1
            mkdir -m 700 -- "$lock_directory" || return 1
            chown 0:0 -- "$lock_directory" || return 1
        fi
        rr_firewall_lock_directory_is_safe "$lock_directory" || return 1
    fi
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        ( umask 077; : > "$lock_file" ) || return 1
    fi
    rr_firewall_lock_file_is_safe "$lock_file"
}

rr_firewall_lock_owner_matches() {
    [[ "${RR_FIREWALL_LOCK_OWNER_PID:-}" =~ ^[1-9][0-9]*$ ]] && \
        [ "$RR_FIREWALL_LOCK_OWNER_PID" = "$BASHPID" ] && \
        [[ "${RR_FIREWALL_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ ]] && \
        [[ "${RR_FIREWALL_LOCK_FD:-}" =~ ^[0-9]+$ ]] && \
        [ -e "/dev/fd/$RR_FIREWALL_LOCK_FD" ]
}

rr_firewall_lock_is_held() {
    local path_identity="" descriptor_identity=""
    rr_firewall_lock_owner_matches || return 1
    rr_firewall_lock_file_is_safe "$RR_FIREWALL_LOCK_FILE" || return 1
    path_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "$RR_FIREWALL_LOCK_FILE" 2>/dev/null) || return 1
    descriptor_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "/dev/fd/$RR_FIREWALL_LOCK_FD" 2>/dev/null) || return 1
    [ "$path_identity" = "$descriptor_identity" ]
}

rr_firewall_lock_acquire() {
    local descriptor_identity="" path_identity=""
    if rr_firewall_lock_is_held; then
        RR_FIREWALL_LOCK_DEPTH=$((RR_FIREWALL_LOCK_DEPTH + 1))
        return 0
    fi

    # A subshell inherits variables and the descriptor, but it is not the
    # transaction owner.  Drop that descriptor before opening and locking a
    # distinct file description; otherwise flock would appear reentrant.
    if [[ "${RR_FIREWALL_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
        exec {RR_FIREWALL_LOCK_FD}>&- || true
    fi
    RR_FIREWALL_LOCK_FD=""
    RR_FIREWALL_LOCK_OWNER_PID=""
    RR_FIREWALL_LOCK_DEPTH=0

    rr_firewall_lock_prepare || {
        printf '%s\n' '防火墙事务锁路径不安全或 flock 不可用；未修改规则。' >&2
        return 1
    }
    exec {RR_FIREWALL_LOCK_FD}<>"$RR_FIREWALL_LOCK_FILE" || return 1
    if ! rr_firewall_lock_file_is_safe "$RR_FIREWALL_LOCK_FILE"; then
        exec {RR_FIREWALL_LOCK_FD}>&-
        RR_FIREWALL_LOCK_FD=""
        return 1
    fi
    path_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "$RR_FIREWALL_LOCK_FILE" 2>/dev/null) || {
        exec {RR_FIREWALL_LOCK_FD}>&-
        RR_FIREWALL_LOCK_FD=""
        return 1
    }
    descriptor_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "/dev/fd/$RR_FIREWALL_LOCK_FD" 2>/dev/null) || {
        exec {RR_FIREWALL_LOCK_FD}>&-
        RR_FIREWALL_LOCK_FD=""
        return 1
    }
    if [ "$path_identity" != "$descriptor_identity" ] || \
       ! flock -w 60 "$RR_FIREWALL_LOCK_FD"; then
        exec {RR_FIREWALL_LOCK_FD}>&-
        RR_FIREWALL_LOCK_FD=""
        printf '%s\n' '无法取得全局防火墙事务锁；未修改规则。' >&2
        return 1
    fi
    # Recheck after the blocking wait.  A privileged replacement cannot make
    # the locked inode authoritative for subsequent RR writers.
    path_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "$RR_FIREWALL_LOCK_FILE" 2>/dev/null) || path_identity=""
    descriptor_identity=$(stat -Lc '%d:%i:%u:%g:%h' \
        "/dev/fd/$RR_FIREWALL_LOCK_FD" 2>/dev/null) || descriptor_identity=""
    if [ -z "$path_identity" ] || [ "$path_identity" != "$descriptor_identity" ] || \
       ! rr_firewall_lock_file_is_safe "$RR_FIREWALL_LOCK_FILE"; then
        flock -u "$RR_FIREWALL_LOCK_FD" 2>/dev/null || true
        exec {RR_FIREWALL_LOCK_FD}>&-
        RR_FIREWALL_LOCK_FD=""
        return 1
    fi
    RR_FIREWALL_LOCK_OWNER_PID="$BASHPID"
    RR_FIREWALL_LOCK_DEPTH=1
}

rr_firewall_lock_release() {
    local failed=false
    rr_firewall_lock_owner_matches || return 1
    rr_firewall_lock_is_held || failed=true
    if [ "$RR_FIREWALL_LOCK_DEPTH" -gt 1 ]; then
        RR_FIREWALL_LOCK_DEPTH=$((RR_FIREWALL_LOCK_DEPTH - 1))
        [ "$failed" = false ] && return 0
        return 1
    fi
    flock -u "$RR_FIREWALL_LOCK_FD" 2>/dev/null || failed=true
    exec {RR_FIREWALL_LOCK_FD}>&- || failed=true
    RR_FIREWALL_LOCK_FD=""
    RR_FIREWALL_LOCK_OWNER_PID=""
    RR_FIREWALL_LOCK_DEPTH=0
    [ "$failed" = false ]
}

# Background runtimes must never keep the global firewall lock's open file
# description alive after a transaction owner is SIGKILLed.  Call this only in
# the child/subshell immediately before exec; the parent retains its descriptor
# and normal reentrant ownership metadata.
rr_close_inherited_firewall_lock_fd() {
    local inherited_fd="${RR_FIREWALL_LOCK_FD:-}" path_identity=""
    local descriptor_identity="" close_fd=""
    [ -n "$inherited_fd" ] || return 0
    [[ "$inherited_fd" =~ ^[0-9]+$ ]] && [ "$inherited_fd" -gt 2 ] || return 1
    [ -e "/dev/fd/$inherited_fd" ] || return 1
    path_identity=$(stat -Lc '%d:%i' \
        "$RR_FIREWALL_LOCK_FILE" 2>/dev/null) || return 1
    descriptor_identity=$(stat -Lc '%d:%i' \
        "/dev/fd/$inherited_fd" 2>/dev/null) || return 1
    [ "$path_identity" = "$descriptor_identity" ] || return 1
    close_fd="$inherited_fd"
    exec {close_fd}>&-
}

# Every caller that observes an indeterminate firewall compensation or lock
# boundary uses the same fail-closed service proof.  Keep this primitive in
# the system module so health, install, restore, Nexus, and protocol menus do
# not depend on which higher-level module happened to be sourced first.
rr_firewall_fail_closed_quarantine_active() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    [ -e "$marker" ] || [ -L "$marker" ]
}

rr_firewall_quarantine_unit_state_is_supported() {
    case "$1:$2:$3" in
        loaded:active:enabled|loaded:active:enabled-runtime|\
        loaded:active:disabled|loaded:active:static|\
        loaded:inactive:enabled|loaded:inactive:enabled-runtime|\
        loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:enabled|loaded:failed:enabled-runtime|\
        loaded:failed:disabled|loaded:failed:static|\
        masked:inactive:masked|masked:failed:masked|\
        not-found:inactive:not-found) return 0 ;;
        *) return 1 ;;
    esac
}

rr_firewall_capture_quarantine_unit_line() {
    local unit="$1" load_state="" active_state="" file_state=""
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || \
        return 1
    active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null) || \
        return 1
    file_state=$(systemctl show --property=UnitFileState --value "$unit" 2>/dev/null) || \
        return 1
    if [ "$load_state" = not-found ] && [ -z "$file_state" ]; then
        file_state=not-found
    fi
    rr_firewall_quarantine_unit_state_is_supported \
        "$load_state" "$active_state" "$file_state" || return 1
    printf 'unit\t%s\t%s\t%s\t%s\n' \
        "$unit" "$load_state" "$active_state" "$file_state"
}

rr_firewall_render_quarantine_guard_script() {
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
    local singbox_bin="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
    local subscription_app="${RR_LIB_DIR:-/usr/local/lib/rr}/nexus/sub_server.py"
    local subscription_root="${SUB_ROOT:-/var/lib/rr/subscriptions}"
    printf '#!/bin/bash\nset -u\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf 'marker=%q\nsingbox_bin=%q\nsingbox_config=%q\n' \
        "$marker" "$singbox_bin" /etc/sing-box/config.json
    printf 'subscription_app=%q\nsubscription_root=%q\n' \
        "$subscription_app" "$subscription_root"
    cat <<'EOF'
if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    systemctl disable --now rr-firewall-quarantine-guard.timer \
        >/dev/null 2>&1 || true
    exit 0
fi
failed=false
units=(argo-rr-health.timer argo-rr-health.service rr-subscription.service \
    sing-box.service rr-nexus.service)
for unit in "${units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

rr_guard_managed_pid_kind() {
    local pid="$1" exe="" argument="" previous="" saw_run=false
    local saw_config=false saw_app=false saw_root=false
    local -a arguments=()
    [ -r "/proc/$pid/cmdline" ] || return 1
    # Keep the kernel's literal ` (deleted)` suffix.  readlink -f resolves the
    # target and fails for an unlinked executable, which would let exactly the
    # crash-recovery process we need to stop escape classification.
    exe=$(readlink -- "/proc/$pid/exe" 2>/dev/null) || return 1
    mapfile -d '' -t arguments < "/proc/$pid/cmdline" || return 1
    if [ "$exe" = "$singbox_bin" ] || [ "$exe" = "${singbox_bin} (deleted)" ]; then
        for argument in "${arguments[@]}"; do
            [ "$argument" = run ] && saw_run=true
            if [ "$previous" = -c ] || [ "$previous" = --config ]; then
                [ "$argument" = "$singbox_config" ] && saw_config=true
            fi
            previous="$argument"
        done
        [ "$saw_run" = true ] && [ "$saw_config" = true ] && return 0
    fi
    previous=""
    for argument in "${arguments[@]}"; do
        [ "$argument" = "$subscription_app" ] && saw_app=true
        if [ "$previous" = --directory ]; then
            [ "$argument" = "$subscription_root" ] && saw_root=true
        fi
        previous="$argument"
    done
    [ "$saw_app" = true ] && [ "$saw_root" = true ]
}

rr_guard_pid_starttime() {
    local pid="$1" stat_line="" remainder=""
    stat_line=$(<"/proc/$pid/stat") || return 1
    remainder=${stat_line##*) }
    set -- $remainder
    [[ "${20:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${20}"
}

rr_guard_managed_pids() {
    local proc="" pid="" starttime=""
    for proc in /proc/[1-9]*; do
        [ -d "$proc" ] || continue
        pid=${proc##*/}
        if rr_guard_managed_pid_kind "$pid"; then
            starttime=$(rr_guard_pid_starttime "$pid") || continue
            printf '%s|%s\n' "$pid" "$starttime"
        fi
    done
}

while IFS='|' read -r pid starttime; do
    [ -n "$pid" ] || continue
    # Re-authenticate both command identity and immutable process start time
    # immediately before each signal, closing the PID-reuse window.
    rr_guard_managed_pid_kind "$pid" || continue
    [ "$(rr_guard_pid_starttime "$pid" 2>/dev/null)" = "$starttime" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
done < <(rr_guard_managed_pids)
for _ in {1..20}; do
    [ -z "$(rr_guard_managed_pids)" ] && break
    sleep 0.1
done
while IFS='|' read -r pid starttime; do
    [ -n "$pid" ] || continue
    rr_guard_managed_pid_kind "$pid" || continue
    [ "$(rr_guard_pid_starttime "$pid" 2>/dev/null)" = "$starttime" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
done < <(rr_guard_managed_pids)
sleep 0.1
[ -z "$(rr_guard_managed_pids)" ] || failed=true

for unit in "${units[@]}"; do
    systemctl is-active --quiet "$unit" 2>/dev/null && failed=true
    file_state=$(systemctl show --property=UnitFileState --value \
        "$unit" 2>/dev/null) || file_state=unknown
    load_state=$(systemctl show --property=LoadState --value \
        "$unit" 2>/dev/null) || load_state=unknown
    [ "$load_state" != not-found ] || file_state=not-found
    case "$file_state" in disabled|static|masked|not-found) ;; *) failed=true ;; esac
done
if [ "$failed" = false ]; then
    # Convergence is complete.  Keep the path unit as the durable reboot/start
    # trigger, but retire the rapid retry timer so a long-lived quarantine
    # cannot generate an unbounded journal/CPU stream.
    systemctl disable --now rr-firewall-quarantine-guard.timer \
        >/dev/null 2>&1 || failed=true
fi
[ "$failed" = false ]
EOF
}

rr_firewall_render_quarantine_guard_service() {
    local guard_script="${RR_FIREWALL_GUARD_SCRIPT:-/usr/local/sbin/rr-firewall-quarantine-guard}"
    cat <<EOF
[Unit]
Description=RR firewall quarantine convergence guard
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${guard_script}
EOF
}

rr_firewall_render_quarantine_guard_path() {
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
    cat <<EOF
[Unit]
Description=Watch RR firewall quarantine marker

[Path]
PathExists=${marker}
Unit=rr-firewall-quarantine-guard.service

[Install]
WantedBy=multi-user.target
EOF
}

rr_firewall_render_quarantine_guard_timer() {
    cat <<'EOF'
[Unit]
Description=Retry RR firewall quarantine convergence

[Timer]
OnBootSec=2s
OnUnitActiveSec=2s
AccuracySec=1s
Unit=rr-firewall-quarantine-guard.service

[Install]
WantedBy=timers.target
EOF
}

rr_firewall_install_quarantine_guard_file() {
    local target="$1" renderer="$2" parent="" temporary=""
    parent=$(dirname -- "$target") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    [ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" = 0:0 ] || return 1
    temporary=$(mktemp "$parent/.rr-firewall-guard.XXXXXX") || return 1
    if ! "$renderer" > "$temporary" || ! chown 0:0 "$temporary" || \
       ! chmod 644 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$target" || ! sync -f "$parent"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_firewall_root_directory_chain_is_safe() {
    local directory="$1" canonical="" mode=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    while :; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
        mode=$(stat -c %a -- "$directory" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        [ $((8#$mode & 8#022)) -eq 0 ] || return 1
        [ "$directory" != / ] || break
        directory=$(dirname -- "$directory") || return 1
    done
}

rr_firewall_quarantine_supervisor_effective() {
    local systemd_root="${RR_FIREWALL_SYSTEMD_DIR:-/etc/systemd/system}"
    local guard_script="${RR_FIREWALL_GUARD_SCRIPT:-/usr/local/sbin/rr-firewall-quarantine-guard}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
    local unit="" fragment="" dropins="" value="" property="" target=""
    local conditions="" asserts=""
    local -A renderers=(
        [rr-firewall-quarantine-guard.service]=rr_firewall_render_quarantine_guard_service
        [rr-firewall-quarantine-guard.path]=rr_firewall_render_quarantine_guard_path
        [rr-firewall-quarantine-guard.timer]=rr_firewall_render_quarantine_guard_timer)
    rr_firewall_quarantine_guard_file_is_exact "$guard_script" \
        rr_firewall_render_quarantine_guard_script 700 || return 1
    for unit in service path timer; do
        target="$systemd_root/rr-firewall-quarantine-guard.$unit"
        rr_firewall_quarantine_guard_file_is_exact "$target" \
            "${renderers[rr-firewall-quarantine-guard.$unit]}" 644 || return 1
        value=$(systemctl show --property=LoadState --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        [ "$value" = loaded ] || return 1
        fragment=$(systemctl show --property=FragmentPath --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        [ "$fragment" = "$target" ] || return 1
        dropins=$(systemctl show --property=DropInPaths --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        [ -z "$dropins" ] || return 1
        conditions=$(systemctl show --property=Conditions --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        asserts=$(systemctl show --property=Asserts --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        [ -z "$conditions" ] && [ -z "$asserts" ] || return 1
    done
    value=$(systemctl show --property=ExecStart --value \
        rr-firewall-quarantine-guard.service 2>/dev/null) || return 1
    python3 - "$value" "$guard_script" <<'PY' || return 1
import re
import sys

raw, expected = sys.argv[1:]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if len(matches) != 1 or residual.strip():
    raise SystemExit(1)
fields = {}
for item in matches[0].group(1).split(";"):
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
if (
    (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    != (expected, expected, "no")
    or raw.count("path=") != 1
    or raw.count("argv[]=") != 1
    or raw.count("ignore_errors=") != 1
):
    raise SystemExit(1)
PY
    for property in ExecStartPre ExecStartPost ExecStop ExecStopPost \
        ExecReload ExecCondition; do
        value=$(systemctl show --property="$property" --value \
            rr-firewall-quarantine-guard.service 2>/dev/null) || return 1
        [ -z "$value" ] || return 1
    done
    rr_firewall_effective_root_marker_view_is_safe \
        rr-firewall-quarantine-guard.service no || return 1
    value=$(systemctl show --property=Paths --value \
        rr-firewall-quarantine-guard.path 2>/dev/null) || return 1
    [ "$value" = "PathExists=${marker}" ] || return 1
    value=$(systemctl show --property=Unit --value \
        rr-firewall-quarantine-guard.path 2>/dev/null) || return 1
    [ "$value" = rr-firewall-quarantine-guard.service ] || return 1
    value=$(systemctl show --property=Triggers --value \
        rr-firewall-quarantine-guard.path 2>/dev/null) || return 1
    [ "$value" = rr-firewall-quarantine-guard.service ] || return 1
    value=$(systemctl show --property=Unit --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    [ "$value" = rr-firewall-quarantine-guard.service ] || return 1
    value=$(systemctl show --property=Triggers --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    [ "$value" = rr-firewall-quarantine-guard.service ] || return 1
    value=$(systemctl show --property=TimersMonotonic --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    python3 - "$value" <<'PY' || return 1
import re
import sys

raw = sys.argv[1]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if len(matches) != 2 or residual.strip():
    raise SystemExit(1)
schedule = []
for match in matches:
    found = []
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, item_value = (part.strip() for part in item.split("=", 1))
        if key.startswith("On") and key.endswith(("Sec", "USec")):
            found.append((key, item_value))
    if len(found) != 1:
        raise SystemExit(1)
    key, item_value = found[0]
    key = {"OnBootUSec": "OnBootSec",
           "OnUnitActiveUSec": "OnUnitActiveSec"}.get(key, key)
    if item_value not in {"2s", "2000000us", "2000000"}:
        raise SystemExit(1)
    schedule.append(key)
if schedule != ["OnBootSec", "OnUnitActiveSec"]:
    raise SystemExit(1)
PY
    value=$(systemctl show --property=TimersCalendar --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    [ -z "$value" ] || return 1
    value=$(systemctl show --property=AccuracyUSec --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    case "$value" in 1s|1000000us|1000000) ;; *) return 1 ;; esac
    value=$(systemctl show --property=RandomizedDelayUSec --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    case "$value" in 0|0us) ;; *) return 1 ;; esac
}

rr_firewall_activate_quarantine_supervisor() {
    local next=""
    rr_firewall_fail_closed_quarantine_active || return 1
    rr_firewall_quarantine_supervisor_effective || return 1
    systemctl enable --now rr-firewall-quarantine-guard.path \
        >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.path || return 1
    systemctl enable --now rr-firewall-quarantine-guard.timer \
        >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.timer || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.timer || return 1
    next=$(systemctl show --property=NextElapseUSecMonotonic --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    case "$next" in ''|0|0us|'n/a') return 1 ;; esac
    systemctl start rr-firewall-quarantine-guard.service >/dev/null 2>&1
}

rr_firewall_deactivate_quarantine_retry() {
    local state="" unit=""
    # Stop the path watcher first so a queued PathExists edge cannot start the
    # guard between stopping the retry service and unlinking the marker.
    systemctl stop rr-firewall-quarantine-guard.path \
        >/dev/null 2>&1 || return 1
    systemctl disable --now rr-firewall-quarantine-guard.timer \
        >/dev/null 2>&1 || return 1
    systemctl stop rr-firewall-quarantine-guard.service >/dev/null 2>&1 || return 1
    for unit in rr-firewall-quarantine-guard.path \
        rr-firewall-quarantine-guard.timer \
        rr-firewall-quarantine-guard.service; do
        systemctl is-active --quiet "$unit" && return 1
    done
    state=$(systemctl show --property=UnitFileState --value \
        rr-firewall-quarantine-guard.path 2>/dev/null) || return 1
    [ "$state" = enabled ] || return 1
    state=$(systemctl show --property=UnitFileState --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    [ "$state" = disabled ] || return 1
}

rr_firewall_activate_idle_quarantine_supervisor() {
    local state=""
    rr_firewall_fail_closed_quarantine_active && return 1
    rr_firewall_quarantine_supervisor_effective || return 1
    systemctl start rr-firewall-quarantine-guard.path \
        >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.path || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.timer && return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.service && return 1
    state=$(systemctl show --property=UnitFileState --value \
        rr-firewall-quarantine-guard.timer 2>/dev/null) || return 1
    [ "$state" = disabled ]
}

rr_firewall_quarantine_guard_file_is_exact() {
    local target="$1" renderer="$2" expected_mode="$3" canonical=""
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    canonical=$(readlink -f -- "$target" 2>/dev/null) || return 1
    [ "$canonical" = "$target" ] || return 1
    [ "$(stat -c '%u:%g:%h:%a' -- "$target" 2>/dev/null)" = \
        "0:0:1:${expected_mode}" ] || return 1
    rr_firewall_root_directory_chain_is_safe "$(dirname -- "$target")" || \
        return 1
    cmp -s -- "$target" <("$renderer")
}

# Before replacing any supervisor byte or asking systemd to reload, accept
# only an entirely absent target set or the exact RR-owned set from an earlier
# interrupted installation.  In particular, never overwrite and then execute
# a third-party base/helper/drop-in while a quarantine marker already exists.
rr_firewall_quarantine_supervisor_preflight_is_safe() {
    local systemd_root="$1" guard_script="$2" unit="" target="" renderer=""
    local dropin_dir="" load_state="" fragment="" dropins="" loaded_count=0
    local -A renderers=(
        [rr-firewall-quarantine-guard.service]=rr_firewall_render_quarantine_guard_service
        [rr-firewall-quarantine-guard.path]=rr_firewall_render_quarantine_guard_path
        [rr-firewall-quarantine-guard.timer]=rr_firewall_render_quarantine_guard_timer)
    if [ -e "$guard_script" ] || [ -L "$guard_script" ]; then
        rr_firewall_quarantine_guard_file_is_exact "$guard_script" \
            rr_firewall_render_quarantine_guard_script 700 || return 1
    fi
    for unit in service path timer; do
        target="$systemd_root/rr-firewall-quarantine-guard.$unit"
        renderer="${renderers[rr-firewall-quarantine-guard.$unit]}"
        if [ -e "$target" ] || [ -L "$target" ]; then
            rr_firewall_quarantine_guard_file_is_exact \
                "$target" "$renderer" 644 || return 1
        fi
        dropin_dir="${target}.d"
        if [ -e "$dropin_dir" ] || [ -L "$dropin_dir" ]; then
            rr_firewall_root_directory_chain_is_safe "$dropin_dir" || return 1
            [ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit \
                2>/dev/null)" ] || return 1
        fi
    done
    for unit in service path timer; do
        target="$systemd_root/rr-firewall-quarantine-guard.$unit"
        load_state=$(systemctl show --property=LoadState --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        fragment=$(systemctl show --property=FragmentPath --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        dropins=$(systemctl show --property=DropInPaths --value \
            "rr-firewall-quarantine-guard.$unit" 2>/dev/null) || return 1
        [ -z "$dropins" ] || return 1
        case "$load_state" in
            loaded)
                [ "$fragment" = "$target" ] || return 1
                loaded_count=$((loaded_count + 1))
                ;;
            not-found)
                [ -z "$fragment" ] || return 1
                ;;
            *) return 1 ;;
        esac
    done
    case "$loaded_count" in
        0) return 0 ;;
        3) rr_firewall_quarantine_supervisor_effective ;;
        *) return 1 ;;
    esac
}

rr_firewall_install_fail_closed_supervisor() {
    local systemd_root="${RR_FIREWALL_SYSTEMD_DIR:-/etc/systemd/system}"
    local guard_script="${RR_FIREWALL_GUARD_SCRIPT:-/usr/local/sbin/rr-firewall-quarantine-guard}"
    local script_parent="" temporary="" unit="" target="" fragment=""
    local -A renderers=(
        [rr-firewall-quarantine-guard.service]=rr_firewall_render_quarantine_guard_service
        [rr-firewall-quarantine-guard.path]=rr_firewall_render_quarantine_guard_path
        [rr-firewall-quarantine-guard.timer]=rr_firewall_render_quarantine_guard_timer)
    rr_firewall_root_directory_chain_is_safe "$systemd_root" || return 1
    script_parent=$(dirname -- "$guard_script") || return 1
    rr_firewall_root_directory_chain_is_safe "$script_parent" || return 1
    rr_firewall_quarantine_supervisor_preflight_is_safe \
        "$systemd_root" "$guard_script" || return 1
    temporary=$(mktemp "$script_parent/.rr-firewall-quarantine-guard.XXXXXX") || \
        return 1
    if ! rr_firewall_render_quarantine_guard_script > "$temporary" || \
       ! bash -n "$temporary" || ! chown 0:0 "$temporary" || \
       ! chmod 700 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$guard_script" || ! sync -f "$script_parent"; then
        rm -f -- "$temporary"
        return 1
    fi
    for unit in "${!renderers[@]}"; do
        rr_firewall_install_quarantine_guard_file "$systemd_root/$unit" \
            "${renderers[$unit]}" || return 1
    done
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    # Full effective identity is proved before the first enable/start.  A
    # hostile ExecStartPre or namespace override must never get one execution
    # opportunity merely because the canonical base bytes were just restored.
    rr_firewall_quarantine_supervisor_effective || return 1
    systemctl enable --now rr-firewall-quarantine-guard.path \
        >/dev/null 2>&1 || return 1
    if ! rr_firewall_fail_closed_quarantine_active; then
        systemctl disable --now rr-firewall-quarantine-guard.timer \
            >/dev/null 2>&1 || return 1
    fi
    [ "$(stat -c '%u:%g:%h:%a' -- "$guard_script" 2>/dev/null)" = \
        0:0:1:700 ] || return 1
    cmp -s -- "$guard_script" <(rr_firewall_render_quarantine_guard_script) || \
        return 1
    for unit in "${!renderers[@]}"; do
        target="$systemd_root/$unit"
        [ "$(stat -c '%u:%g:%h:%a' -- "$target" 2>/dev/null)" = \
            0:0:1:644 ] || return 1
        cmp -s -- "$target" <("${renderers[$unit]}") || return 1
        fragment=$(systemctl show --property=FragmentPath --value \
            "$unit" 2>/dev/null) || return 1
        [ "$fragment" = "$target" ] || return 1
    done
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.path || return 1
    if rr_firewall_fail_closed_quarantine_active; then
        return 0
    fi
    ! systemctl is-active --quiet rr-firewall-quarantine-guard.timer && \
        ! systemctl is-enabled --quiet rr-firewall-quarantine-guard.timer
}

rr_firewall_systemd_dropin_metadata_is_safe() {
    local dropin="$1" parent="" canonical="" size=""
    [ -f "$dropin" ] && [ ! -L "$dropin" ] || return 1
    canonical=$(readlink -f -- "$dropin" 2>/dev/null) || return 1
    [ "$canonical" = "$dropin" ] || return 1
    [ "$(stat -c '%u:%g:%h:%a' -- "$dropin" 2>/dev/null)" = 0:0:1:644 ] || \
        return 1
    size=$(stat -c %s -- "$dropin" 2>/dev/null) || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 1
    parent=$(dirname -- "$dropin") || return 1
    rr_firewall_root_directory_chain_is_safe "$parent"
}

rr_firewall_fail_closed_dropin_is_exact() {
    local dropin="$1" marker="$2"
    rr_firewall_systemd_dropin_metadata_is_safe "$dropin" || return 1
    cmp -s -- "$dropin" <(
        printf '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
            "$marker" "$marker"
    )
}

rr_firewall_restore_dropin_is_exact() {
    local dropin="$1"
    rr_firewall_systemd_dropin_metadata_is_safe "$dropin" || return 1
    cmp -s -- "$dropin" <(
        printf '%s\n' '[Service]' \
            "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'"
    )
}

rr_firewall_dropin_has_exec_condition_directive() {
    local dropin="$1"
    python3 - "$dropin" <<'PY'
import pathlib
import re
import sys

try:
    raw = pathlib.Path(sys.argv[1]).read_bytes()
    if b"\0" in raw or len(raw) > 1024 * 1024:
        raise ValueError
    text = raw.decode("utf-8")
except (OSError, UnicodeDecodeError, ValueError):
    raise SystemExit(2)
raise SystemExit(
    0 if re.search(r"(?mi)^[ \t]*ExecCondition[ \t]*=", text) else 1
)
PY
}

rr_firewall_effective_exec_conditions_are_managed() {
    local raw="$1" expect_restore="$2" marker="$3"
    local restore_argv="/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate"
    python3 - "$raw" "$expect_restore" "$restore_argv" "$marker" <<'PY'
import re
import sys

raw, expect_restore, restore_argv, marker = sys.argv[1:]
records = []
for encoded in re.findall(r"\{([^{}]*)\}", raw):
    fields = {}
    for item in encoded.split(";"):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(1)
        key, value = item.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\[\])?", key):
            raise SystemExit(1)
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
expected = []
if expect_restore == "true":
    expected.append(("/bin/sh", restore_argv, "no"))
expected.extend(
    [
        ("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no"),
        ("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no"),
    ]
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

# ExecCondition runs in the service's effective identity and filesystem
# namespace.  Merely proving its argv is not sufficient: an unprivileged
# User= cannot traverse the root-only quarantine directory, while a private
# root/mount namespace can hide the marker and make both negative tests pass.
# Prove every property that can change that view before treating the compiled
# ExecCondition vector as a reboot/start gate.
rr_firewall_effective_root_marker_view_is_safe() {
    local unit="$1" expected_protect_home="$2"
    local user="" group="" dynamic_user="" private_users=""
    local private_mounts="" root_directory="" root_image="" mount_images=""
    local extension_images="" extension_directories="" temporary_filesystems=""
    local bind_paths="" bind_read_only_paths="" inaccessible_paths=""
    local joins_namespace_of="" protect_system="" read_only_paths=""
    local read_write_paths="" environment="" environment_files=""
    local pass_environment="" pam_name="" root_ephemeral=no
    local system_call_filter="" protect_home="" version_line=""
    local systemd_version=""
    version_line=$(systemctl --version 2>/dev/null | head -n 1) || return 1
    [[ "$version_line" =~ ^systemd[[:space:]]+([0-9]+)([[:space:]]|$) ]] || \
        return 1
    systemd_version="${BASH_REMATCH[1]}"
    user=$(systemctl show --property=User --value "$unit" 2>/dev/null) || \
        return 1
    group=$(systemctl show --property=Group --value "$unit" 2>/dev/null) || \
        return 1
    dynamic_user=$(systemctl show --property=DynamicUser --value \
        "$unit" 2>/dev/null) || return 1
    private_users=$(systemctl show --property=PrivateUsers --value \
        "$unit" 2>/dev/null) || return 1
    private_mounts=$(systemctl show --property=PrivateMounts --value \
        "$unit" 2>/dev/null) || return 1
    root_directory=$(systemctl show --property=RootDirectory --value \
        "$unit" 2>/dev/null) || return 1
    root_image=$(systemctl show --property=RootImage --value \
        "$unit" 2>/dev/null) || return 1
    mount_images=$(systemctl show --property=MountImages --value \
        "$unit" 2>/dev/null) || return 1
    extension_images=$(systemctl show --property=ExtensionImages --value \
        "$unit" 2>/dev/null) || return 1
    extension_directories=$(systemctl show --property=ExtensionDirectories \
        --value "$unit" 2>/dev/null) || return 1
    temporary_filesystems=$(systemctl show --property=TemporaryFileSystem \
        --value "$unit" 2>/dev/null) || return 1
    bind_paths=$(systemctl show --property=BindPaths --value \
        "$unit" 2>/dev/null) || return 1
    bind_read_only_paths=$(systemctl show --property=BindReadOnlyPaths \
        --value "$unit" 2>/dev/null) || return 1
    inaccessible_paths=$(systemctl show --property=InaccessiblePaths \
        --value "$unit" 2>/dev/null) || return 1
    joins_namespace_of=$(systemctl show --property=JoinsNamespaceOf \
        --value "$unit" 2>/dev/null) || return 1
    protect_system=$(systemctl show --property=ProtectSystem --value \
        "$unit" 2>/dev/null) || return 1
    read_only_paths=$(systemctl show --property=ReadOnlyPaths --value \
        "$unit" 2>/dev/null) || return 1
    read_write_paths=$(systemctl show --property=ReadWritePaths --value \
        "$unit" 2>/dev/null) || return 1
    environment=$(systemctl show --property=Environment --value \
        "$unit" 2>/dev/null) || return 1
    environment_files=$(systemctl show --property=EnvironmentFiles --value \
        "$unit" 2>/dev/null) || return 1
    pass_environment=$(systemctl show --property=PassEnvironment --value \
        "$unit" 2>/dev/null) || return 1
    pam_name=$(systemctl show --property=PAMName --value \
        "$unit" 2>/dev/null) || return 1
    system_call_filter=$(systemctl show --property=SystemCallFilter --value \
        "$unit" 2>/dev/null) || return 1
    protect_home=$(systemctl show --property=ProtectHome --value \
        "$unit" 2>/dev/null) || return 1
    # RootEphemeral= was added in systemd 254.  On older supported systemd it
    # cannot alter the service view and the effective property does not exist.
    if [ "$systemd_version" -ge 254 ]; then
        root_ephemeral=$(systemctl show --property=RootEphemeral --value \
            "$unit" 2>/dev/null) || return 1
    fi

    # Empty User=/Group= are systemd's root defaults for a system service.
    # Do not normalize whitespace: these are scalar effective properties and
    # only the two exact cross-version representations are trusted.
    case "$user" in ""|root) ;; *) return 1 ;; esac
    case "$group" in ""|root) ;; *) return 1 ;; esac
    [ "$dynamic_user" = no ] && [ "$private_users" = no ] && \
        [ "$private_mounts" = no ] || return 1
    for value in "$root_directory" "$root_image" "$mount_images" \
        "$extension_images" "$extension_directories" \
        "$temporary_filesystems" "$bind_paths" "$bind_read_only_paths" \
        "$inaccessible_paths" "$joins_namespace_of" "$read_only_paths" \
        "$read_write_paths" "$environment" "$environment_files" \
        "$pass_environment" "$pam_name"; do
        [ -z "$value" ] || return 1
    done
    [ "$system_call_filter" = '~' ] || return 1
    [ "$root_ephemeral" = no ] || return 1
    # ProtectSystem only changes write access; all supported values retain the
    # same readable path/inode view needed by `test -e/-L`.
    case "$protect_system" in no|yes|full|strict) ;; *) return 1 ;; esac
    # ProtectHome never covers /var/lib, but bind it to the exact RR renderer
    # so an unexpected service identity cannot hide behind this generic view
    # proof.  Callers supply only a fixed no/yes expectation.
    case "$expected_protect_home" in no|yes) ;; *) return 1 ;; esac
    [ "$protect_home" = "$expected_protect_home" ] || return 1

    # Unit Conditions/Asserts are conjunctive preconditions.  They can only
    # skip/fail a start before ExecCondition; they cannot make a service start
    # while bypassing it.  Query them so bus/property failures still propagate,
    # but deliberately never infer gate success from their current result.
    systemctl show --property=Conditions --value "$unit" \
        >/dev/null 2>&1 || return 1
    systemctl show --property=Asserts --value "$unit" \
        >/dev/null 2>&1 || return 1
}

rr_firewall_effective_marker_view_is_safe() {
    local unit="$1" expected_protect_home=""
    case "$unit" in
        rr-nexus.service) expected_protect_home=yes ;;
        sing-box.service|rr-subscription.service|argo-rr-health.service)
            expected_protect_home=no
            ;;
        *) return 1 ;;
    esac
    rr_firewall_effective_root_marker_view_is_safe \
        "$unit" "$expected_protect_home"
}

rr_firewall_install_fail_closed_dropins() {
    local systemd_root="${RR_FIREWALL_SYSTEMD_DIR:-/etc/systemd/system}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
    local unit="" directory="" target="" temporary="" mode="" restore_dropin=""
    local dropin="" basename="" dropin_paths="" exec_conditions="" load_state=""
    local expect_restore=false condition_status=0 firewall_count=0 restore_count=0
    local managed_name="zzzzz-rr-firewall-quarantine.conf"
    local restore_name="zzzz-rr-restore-gate.conf"
    local -a effective_dropins=()
    local -A seen_dropins=()
    # A timer itself is not an ingress runtime.  Its service is gated below,
    # while the quarantine publisher separately disables and proves both the
    # timer and service inactive.  ExecCondition is a [Service] directive and
    # therefore must not be emitted for the timer unit.
    local -a units=(sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service)
    [[ "$systemd_root" = /* && "$systemd_root" != *[[:space:]]* ]] || return 1
    [[ "$marker" = /* && "$marker" != *[[:space:]]* ]] || return 1
    [ -d "$systemd_root" ] && [ ! -L "$systemd_root" ] || return 1
    [ "$(stat -c '%u:%g' -- "$systemd_root" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c %a -- "$systemd_root" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    for unit in "${units[@]}"; do
        directory="$systemd_root/${unit}.d"
        target="$directory/$managed_name"
        if [ -e "$directory" ] || [ -L "$directory" ]; then
            [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
            [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
            mode=$(stat -c %a -- "$directory" 2>/dev/null) || return 1
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
                [ $((8#$mode & 8#022)) -eq 0 ] || return 1
        else
            install -d -o 0 -g 0 -m 755 -- "$directory" || return 1
        fi
        temporary=$(mktemp "$directory/.zzzzz-rr-firewall-quarantine.XXXXXX") || \
            return 1
        # `ConditionPathExists=!marker` is unsafe for a dangling symlink:
        # systemd treats the target as absent and permits the unit.  Two
        # independently evaluated ExecCondition entries reject both any
        # filesystem object and a dangling symlink.  Do not reset the list;
        # the earlier restore-gate ExecCondition must remain in force.
        if ! printf '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
            "$marker" "$marker" > "$temporary" || \
           ! chown 0:0 "$temporary" || ! chmod 644 "$temporary" || \
           ! sync -f "$temporary" || ! mv -f -- "$temporary" "$target" || \
           ! sync -f "$directory"; then
            rm -f -- "$temporary"
            return 1
        fi
        rr_firewall_fail_closed_dropin_is_exact "$target" "$marker" || return 1
    done
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    for unit in "${units[@]}"; do
        directory="$systemd_root/${unit}.d"
        target="$directory/$managed_name"
        restore_dropin="$directory/$restore_name"
        rr_firewall_fail_closed_dropin_is_exact "$target" "$marker" || return 1
        dropin_paths=$(systemctl show --property=DropInPaths --value \
            "$unit" 2>/dev/null) || return 1
        load_state=$(systemctl show --property=LoadState --value \
            "$unit" 2>/dev/null) || return 1
        # A later reset directive can erase every earlier condition.  Reject
        # any lexically later drop-in from all effective search paths, and for
        # loaded units prove the entire compiled ExecCondition vector.  An
        # earlier administrator drop-in may contain unrelated hardening, but
        # it may not add or reset ExecCondition; only the exact optional RR
        # restore gate and this exact firewall gate own that directive.
        if [ "$load_state" = loaded ] || [ "$load_state" = masked ]; then
            read -r -a effective_dropins <<< "$dropin_paths"
            seen_dropins=()
            expect_restore=false
            firewall_count=0
            restore_count=0
            for dropin in "${effective_dropins[@]}"; do
                [[ "$dropin" = /* && "$dropin" != *[[:space:]]* ]] || return 1
                [ -z "${seen_dropins[$dropin]+set}" ] || return 1
                seen_dropins["$dropin"]=1
                basename=$(basename -- "$dropin") || return 1
                [[ "$basename" > "$managed_name" ]] && return 1
                if [ "$dropin" = "$target" ]; then
                    [ "$basename" = "$managed_name" ] || return 1
                    rr_firewall_fail_closed_dropin_is_exact \
                        "$dropin" "$marker" || return 1
                    firewall_count=$((firewall_count + 1))
                elif [ "$dropin" = "$restore_dropin" ]; then
                    [ "$basename" = "$restore_name" ] || return 1
                    rr_firewall_restore_dropin_is_exact "$dropin" || return 1
                    restore_count=$((restore_count + 1))
                    expect_restore=true
                else
                    [ "$basename" != "$managed_name" ] && \
                        [ "$basename" != "$restore_name" ] || return 1
                    rr_firewall_systemd_dropin_metadata_is_safe "$dropin" || \
                        return 1
                    condition_status=0
                    rr_firewall_dropin_has_exec_condition_directive \
                        "$dropin" || condition_status=$?
                    [ "$condition_status" -eq 1 ] || return 1
                fi
            done
            [ "$firewall_count" -eq 1 ] && [ "$restore_count" -le 1 ] || \
                return 1
            exec_conditions=$(systemctl show --property=ExecCondition --value \
                "$unit" 2>/dev/null) || return 1
            rr_firewall_effective_exec_conditions_are_managed \
                "$exec_conditions" "$expect_restore" "$marker" || return 1
            rr_firewall_effective_marker_view_is_safe "$unit" || return 1
        elif [ "$load_state" = not-found ]; then
            # No executable unit exists to start.  Still reject a later local
            # fragment so a subsequently installed RR unit cannot bypass the
            # already-published marker before the next daemon reload.
            for dropin in "$directory"/*.conf; do
                [ -e "$dropin" ] || [ -L "$dropin" ] || continue
                basename=$(basename -- "$dropin") || return 1
                [[ "$basename" > "$managed_name" ]] && return 1
                if [ "$dropin" = "$target" ]; then
                    rr_firewall_fail_closed_dropin_is_exact \
                        "$dropin" "$marker" || return 1
                elif [ "$dropin" = "$restore_dropin" ]; then
                    rr_firewall_restore_dropin_is_exact "$dropin" || return 1
                else
                    rr_firewall_systemd_dropin_metadata_is_safe "$dropin" || \
                        return 1
                    condition_status=0
                    rr_firewall_dropin_has_exec_condition_directive \
                        "$dropin" || condition_status=$?
                    [ "$condition_status" -eq 1 ] || return 1
                fi
            done
        else
            return 1
        fi
    done
    return 0
}

declare -ga RR_FIREWALL_QUARANTINE_UNITS=()
declare -ga RR_FIREWALL_QUARANTINE_LOAD_STATES=()
declare -ga RR_FIREWALL_QUARANTINE_ACTIVE_STATES=()
declare -ga RR_FIREWALL_QUARANTINE_FILE_STATES=()
RR_FIREWALL_QUARANTINE_SINGBOX_RUNTIME=false
RR_FIREWALL_QUARANTINE_SUBSCRIPTION_RUNTIME=false
RR_FIREWALL_QUARANTINE_EVIDENCE_KIND=""
RR_FIREWALL_INFLIGHT_ACTIVE=0
RR_FIREWALL_INFLIGHT_OWNER_PID=""
RR_FIREWALL_INFLIGHT_MARKER_SHA256=""

rr_firewall_load_fail_closed_marker() {
    local expected_version="$1"
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local canonical="" metadata="" owner="" group="" links="" mode="" size=""
    local index=0 kind="" name="" load_state="" active_state="" file_state="" extra=""
    local -a lines=() expected=(sing-box.service rr-nexus.service \
        rr-subscription.service argo-rr-health.service argo-rr-health.timer)
    [ "$marker" = "$directory/firewall-quarantine" ] || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    canonical=$(readlink -f -- "$marker" 2>/dev/null) || return 1
    [ "$canonical" = "$marker" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$marker" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<< "$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 4096 ] || return 1
    mapfile -t lines < "$marker" || return 1
    case "$expected_version" in
        firewall-inflight-v1|firewall-quarantine-v2) ;;
        *) return 1 ;;
    esac
    [ "${#lines[@]}" -eq 9 ] && \
        [ "${lines[0]}" = "$expected_version" ] || return 1
    RR_FIREWALL_QUARANTINE_UNITS=()
    RR_FIREWALL_QUARANTINE_LOAD_STATES=()
    RR_FIREWALL_QUARANTINE_ACTIVE_STATES=()
    RR_FIREWALL_QUARANTINE_FILE_STATES=()
    for ((index=0; index<5; index++)); do
        IFS=$'\t' read -r kind name load_state active_state file_state extra \
            <<< "${lines[index + 1]}"
        [ "$kind" = unit ] && [ "$name" = "${expected[index]}" ] && \
            [ -z "$extra" ] || return 1
        rr_firewall_quarantine_unit_state_is_supported \
            "$load_state" "$active_state" "$file_state" || return 1
        RR_FIREWALL_QUARANTINE_UNITS+=("$name")
        RR_FIREWALL_QUARANTINE_LOAD_STATES+=("$load_state")
        RR_FIREWALL_QUARANTINE_ACTIVE_STATES+=("$active_state")
        RR_FIREWALL_QUARANTINE_FILE_STATES+=("$file_state")
    done
    IFS=$'\t' read -r kind name load_state extra <<< "${lines[6]}"
    [ "$kind:$name" = runtime:singbox ] && \
        case "$load_state" in true|false) true ;; *) false ;; esac && \
        [ -z "$extra" ] || return 1
    RR_FIREWALL_QUARANTINE_SINGBOX_RUNTIME="$load_state"
    IFS=$'\t' read -r kind name load_state extra <<< "${lines[7]}"
    [ "$kind:$name" = runtime:subscription ] && \
        case "$load_state" in true|false) true ;; *) false ;; esac && \
        [ -z "$extra" ] || return 1
    RR_FIREWALL_QUARANTINE_SUBSCRIPTION_RUNTIME="$load_state"
    IFS=$'\t' read -r kind name extra <<< "${lines[8]}"
    [ "$kind" = evidence ] && [ -z "$extra" ] || return 1
    case "$name" in
        firewall-evidence-v1)
            rr_firewall_quarantine_evidence_is_trusted || return 1
            ;;
        unavailable)
            [ ! -e "$directory/firewall-evidence" ] && \
                [ ! -L "$directory/firewall-evidence" ] || return 1
            ;;
        *) return 1 ;;
    esac
    RR_FIREWALL_QUARANTINE_EVIDENCE_KIND="$name"
}

rr_firewall_load_fail_closed_quarantine() {
    rr_firewall_load_fail_closed_marker firewall-quarantine-v2
}

rr_firewall_load_inflight_marker() {
    rr_firewall_load_fail_closed_marker firewall-inflight-v1
}

rr_firewall_write_desired_namespace() {
    local target="$1" key="" panel_mode="" panel_port="" acme_state=0
    local -a no_updates=()
    local -A desired=()
    load_config_with_defaults || return 1
    if [ "${VM_ENABLED:-false}" = true ] && \
       [ "${VM_TLS_ENABLED:-false}" = true ]; then
        is_valid_port "${PORT:-}" || return 1
        desired["${PORT}|tcp"]=open
    fi
    is_valid_port "${SUB_PORT:-}" || return 1
    case "${SUB_ACCESS_MODE:-local}" in
        https) desired["${SUB_PORT}|tcp"]=open ;;
        local) desired["${SUB_PORT}|tcp"]=closed ;;
        *) return 1 ;;
    esac
    if [ "${VL_ENABLED:-false}" = true ]; then
        is_valid_port "${VL_PORT:-}" || return 1
        desired["${VL_PORT}|tcp"]=open
    fi
    if [ "${HY2_ENABLED:-false}" = true ]; then
        is_valid_port "${HY2_PORT:-}" || return 1
        desired["${HY2_PORT}|udp"]=open
    fi
    if [ "${TU5_ENABLED:-false}" = true ]; then
        is_valid_port "${TU5_PORT:-}" || return 1
        desired["${TU5_PORT}|udp"]=open
    fi
    if [ "${AN_ENABLED:-false}" = true ]; then
        is_valid_port "${AN_PORT:-}" || return 1
        desired["${AN_PORT}|tcp"]=open
    fi
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        is_valid_port "${NAIVE_PORT:-}" || return 1
        case "${NAIVE_MODE:-h2}" in
            h2) desired["${NAIVE_PORT}|tcp"]=open ;;
            h3) desired["${NAIVE_PORT}|udp"]=open ;;
            both)
                desired["${NAIVE_PORT}|tcp"]=open
                desired["${NAIVE_PORT}|udp"]=open
                ;;
            *) return 1 ;;
        esac
    fi
    declare -F rr_firewall_acme_http_tuple_needed_after_updates \
        >/dev/null 2>&1 || return 1
    if rr_firewall_acme_http_tuple_needed_after_updates no_updates; then
        desired['80|tcp']=open
    else
        acme_state=$?
        [ "$acme_state" -eq 1 ] || return 1
    fi
    if [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ]; then
        panel_mode=$(jq -r '.mode // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 1
        case "$panel_mode" in
            local) ;;
            public)
                panel_port=$(jq -r '.public_port // empty' \
                    "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" \
                    2>/dev/null) || return 1
                is_valid_port "$panel_port" || return 1
                desired["${panel_port}|tcp"]=open
                ;;
            *) return 1 ;;
        esac
    fi
    : > "$target" || return 1
    for key in "${!desired[@]}"; do
        printf 'protocol|%s|%s|%s\n' "${desired[$key]}" \
            "${key%%|*}" "${key##*|}" >> "$target" || return 1
    done
    if [ -n "${HY2_HOP_PORTS:-}" ]; then
        is_valid_port "${HY2_PORT:-}" && \
            is_valid_hop_spec "$HY2_HOP_PORTS" || return 1
        printf 'hop|HY2|%s|%s\n' "$HY2_PORT" "$HY2_HOP_PORTS" >> "$target" || \
            return 1
    fi
    if [ -n "${TU5_HOP_PORTS:-}" ]; then
        is_valid_port "${TU5_PORT:-}" && \
            is_valid_hop_spec "$TU5_HOP_PORTS" || return 1
        printf 'hop|TU5|%s|%s\n' "$TU5_PORT" "$TU5_HOP_PORTS" >> "$target" || \
            return 1
    fi
    LC_ALL=C sort -o "$target" "$target" || return 1
    chmod 600 "$target"
}

rr_firewall_quarantine_evidence_is_trusted() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local evidence="$directory/firewall-evidence" hash="" expected=""
    local kind="" owner="" group="" links="" mode="" path="" manifest=""
    local manifest_valid=true
    [ -d "$evidence" ] && [ ! -L "$evidence" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$evidence" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    rr_restore_require_firewall_snapshot_v2 "$evidence" || return 1
    for expected in config.sha256 desired.namespace evidence.complete; do
        [ -f "$evidence/$expected" ] && [ ! -L "$evidence/$expected" ] && \
        [ "$(stat -c '%u:%g:%h:%a' -- "$evidence/$expected" \
                2>/dev/null)" = 0:0:1:600 ] || return 1
    done
    manifest=$(mktemp "$directory/.firewall-evidence-manifest.XXXXXX") || return 1
    if ! find "$evidence" -xdev -printf '%y\t%U\t%G\t%n\t%m\t%p\n' \
        > "$manifest" 2>/dev/null; then
        rm -f -- "$manifest"
        return 1
    fi
    while IFS=$'\t' read -r kind owner group links mode path; do
        if [ -z "$path" ]; then manifest_valid=false; break; fi
        case "$kind" in
            d) [ "$owner:$group:$mode" = 0:0:700 ] || manifest_valid=false ;;
            f) [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || \
                manifest_valid=false ;;
            *) manifest_valid=false ;;
        esac
        [ "$manifest_valid" = true ] || break
    done < "$manifest"
    rm -f -- "$manifest" || return 1
    [ "$manifest_valid" = true ] || return 1
    [ "$(cat -- "$evidence/evidence.complete" 2>/dev/null)" = \
        firewall-evidence-v1 ] || return 1
    hash=$(cat -- "$evidence/config.sha256" 2>/dev/null) || return 1
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
    [ "$(sha256sum -- "$CONFIG_FILE" 2>/dev/null | awk '{print $1}')" = \
        "$hash" ] || return 1
    expected=$(mktemp "$directory/.desired-verify.XXXXXX") || return 1
    if ! rr_firewall_write_desired_namespace "$expected" || \
       ! cmp -s -- "$evidence/desired.namespace" "$expected"; then
        rm -f -- "$expected"
        return 1
    fi
    rm -f -- "$expected"
}

rr_firewall_prepare_quarantine_evidence_locked() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local evidence="$directory/firewall-evidence" temporary="" hash="" stale=""
    rr_firewall_lock_is_held || return 1
    # A canonical evidence directory without its marker is an interrupted old
    # quarantine, never a reusable snapshot.  Move it out of the canonical
    # name under the global lock and capture the current live state afresh.
    if [ -e "$evidence" ] || [ -L "$evidence" ]; then
        stale="$directory/.firewall-evidence-stale.${BASHPID}"
        [ ! -e "$stale" ] && [ ! -L "$stale" ] || return 1
        mv -- "$evidence" "$stale" || return 1
        sync -f "$directory" || return 1
    fi
    temporary=$(mktemp -d "$directory/.firewall-evidence.XXXXXX") || return 1
    chmod 700 "$temporary" || { rm -rf -- "$temporary"; return 1; }
    rr_restore_capture_firewall_snapshot "$temporary" || {
        rm -rf -- "$temporary"
        return 1
    }
    hash=$(sha256sum -- "$CONFIG_FILE" 2>/dev/null | awk '{print $1}') || {
        rm -rf -- "$temporary"
        return 1
    }
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || { rm -rf -- "$temporary"; return 1; }
    if ! printf '%s\n' "$hash" > "$temporary/config.sha256" || \
       ! rr_firewall_write_desired_namespace "$temporary/desired.namespace" || \
       ! printf '%s\n' firewall-evidence-v1 > "$temporary/evidence.complete" || \
       ! find "$temporary" -xdev -type d -exec chmod 700 -- {} + || \
       ! find "$temporary" -xdev -type f -exec chmod 600 -- {} + || \
       ! chown -R 0:0 -- "$temporary" || \
       ! sync -f "$temporary/config.sha256" || \
       ! sync -f "$temporary/desired.namespace" || \
       ! sync -f "$temporary/evidence.complete" || \
       ! sync -f "$temporary" || ! mv -- "$temporary" "$evidence" || \
       ! sync -f "$directory"; then
        rm -rf -- "$temporary"
        return 1
    fi
    rr_firewall_quarantine_evidence_is_trusted || return 1
    if [ -n "$stale" ]; then
        rm -rf -- "$stale" || return 1
        sync -f "$directory" || return 1
    fi
}

rr_firewall_refresh_quarantine_evidence_config_locked() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local evidence="$directory/firewall-evidence" hash=""
    local hash_tmp="" desired_tmp=""
    rr_firewall_lock_is_held || return 1
    [ -d "$evidence" ] && [ ! -L "$evidence" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$evidence" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    rr_restore_require_firewall_snapshot_v2 "$evidence" || return 1
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
    hash=$(sha256sum -- "$CONFIG_FILE" 2>/dev/null | awk '{print $1}') || \
        return 1
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    hash_tmp=$(mktemp "$evidence/.config.sha256.XXXXXX") || return 1
    desired_tmp=$(mktemp "$evidence/.desired.namespace.XXXXXX") || {
        rm -f -- "$hash_tmp"
        return 1
    }
    if ! printf '%s\n' "$hash" > "$hash_tmp" || \
       ! rr_firewall_write_desired_namespace "$desired_tmp" || \
       ! chown 0:0 "$hash_tmp" "$desired_tmp" || \
       ! chmod 600 "$hash_tmp" "$desired_tmp" || \
       ! sync -f "$hash_tmp" || ! sync -f "$desired_tmp" || \
       ! mv -f -- "$hash_tmp" "$evidence/config.sha256" || \
       ! mv -f -- "$desired_tmp" "$evidence/desired.namespace" || \
       ! sync -f "$evidence"; then
        rm -f -- "$hash_tmp" "$desired_tmp"
        return 1
    fi
    rr_firewall_quarantine_evidence_is_trusted
}

rr_firewall_write_marker_locked() {
    local version="$1" evidence_kind="$2"
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local temporary="" singbox_runtime=false subscription_runtime=false
    rr_firewall_lock_is_held || return 1
    case "$version" in firewall-inflight-v1|firewall-quarantine-v2) ;; *) return 1 ;; esac
    case "$evidence_kind" in firewall-evidence-v1|unavailable) ;; *) return 1 ;; esac
    [ "$marker" = "$directory/firewall-quarantine" ] || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    declare -F managed_singbox_running >/dev/null 2>&1 && \
        managed_singbox_running && singbox_runtime=true
    declare -F subscription_server_running >/dev/null 2>&1 && \
        subscription_server_running && subscription_runtime=true
    temporary=$(mktemp "$directory/.firewall-marker.XXXXXX") || return 1
    if ! {
        printf '%s\n' "$version" &&
        rr_firewall_capture_quarantine_unit_line sing-box.service &&
        rr_firewall_capture_quarantine_unit_line rr-nexus.service &&
        rr_firewall_capture_quarantine_unit_line rr-subscription.service &&
        rr_firewall_capture_quarantine_unit_line argo-rr-health.service &&
        rr_firewall_capture_quarantine_unit_line argo-rr-health.timer &&
        printf 'runtime\tsingbox\t%s\n' "$singbox_runtime" &&
        printf 'runtime\tsubscription\t%s\n' "$subscription_runtime" &&
        printf 'evidence\t%s\n' "$evidence_kind"
    } > "$temporary" || \
       ! chown 0:0 "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_firewall_inflight_is_owned() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local hash=""
    rr_firewall_lock_is_held || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ "${RR_FIREWALL_INFLIGHT_ACTIVE:-0}" = 1 ] && \
        [ "${RR_FIREWALL_INFLIGHT_OWNER_PID:-}" = "$BASHPID" ] && \
        [[ "${RR_FIREWALL_INFLIGHT_MARKER_SHA256:-}" =~ ^[a-f0-9]{64}$ ]] || \
        return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%h:%a' -- "$marker" 2>/dev/null)" = 0:0:1:600 ] || \
        return 1
    IFS= read -r hash < "$marker" || return 1
    [ "$hash" = firewall-inflight-v1 ] || return 1
    hash=$(sha256sum -- "$marker" 2>/dev/null | awk '{print $1}') || return 1
    [ "$hash" = "$RR_FIREWALL_INFLIGHT_MARKER_SHA256" ]
}

rr_firewall_writer_gate_is_held() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    rr_firewall_lock_is_held || return 1
    rr_firewall_inflight_is_owned && return 0
    [ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" = 1 ] || \
        [ "${RR_FIREWALL_QUARANTINE_WRITER:-0}" = 1 ] || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        [ "$(stat -c '%u:%g:%h:%a' -- "$marker" 2>/dev/null)" = 0:0:1:600 ] && \
        [ "$(head -n 1 -- "$marker" 2>/dev/null)" = firewall-quarantine-v2 ]
}

rr_firewall_promote_inflight_locked() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local temporary="" line="" index=0
    local -a lines=()
    rr_firewall_inflight_is_owned || return 1
    rr_firewall_refresh_quarantine_evidence_config_locked || return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 9 ] && \
        [ "${lines[0]}" = firewall-inflight-v1 ] || return 1
    temporary=$(mktemp "$directory/.firewall-quarantine.XXXXXX") || return 1
    if ! {
        printf '%s\n' firewall-quarantine-v2
        for ((index=1; index<${#lines[@]}; index++)); do
            printf '%s\n' "${lines[index]}"
        done
    } > "$temporary" || ! chown 0:0 "$temporary" || \
       ! chmod 600 "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$marker" || ! sync -f "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
    RR_FIREWALL_INFLIGHT_ACTIVE=0
    RR_FIREWALL_INFLIGHT_OWNER_PID=""
    RR_FIREWALL_INFLIGHT_MARKER_SHA256=""
    rr_firewall_load_fail_closed_quarantine
}

rr_firewall_publish_fail_closed_quarantine() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local temporary="" singbox_runtime=false subscription_runtime=false
    local evidence_kind=unavailable failed=false
    [ "$marker" = "$directory/firewall-quarantine" ] || return 1
    if [ -e "$directory" ] || [ -L "$directory" ]; then
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
            return 1
    else
        install -d -o 0 -g 0 -m 700 -- "$directory" || return 1
    fi
    # Install and verify the reboot gate, but still publish the marker and stop
    # every runtime if a hostile systemd fragment prevents proving the gate.
    # In that case the caller returns the more severe unverified status 3.
    rr_firewall_install_fail_closed_supervisor || failed=true
    rr_firewall_install_fail_closed_dropins || failed=true
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        if [ -f "$marker" ] && [ ! -L "$marker" ] && \
           [ "$(head -n 1 -- "$marker" 2>/dev/null)" = firewall-inflight-v1 ]; then
            if rr_firewall_inflight_is_owned; then
                rr_firewall_promote_inflight_locked || failed=true
            else
                # An orphaned in-flight journal is deliberately not guessed
                # into a repairable v2 shape.  The shared marker path still
                # gates every start and the supervisor still converges all
                # ingress inactive; explicit recovery must inspect evidence.
                failed=true
            fi
        else
            rr_firewall_load_fail_closed_quarantine || failed=true
        fi
        rr_firewall_activate_quarantine_supervisor || failed=true
        [ "$failed" = false ]
        return
    fi
    if rr_firewall_lock_acquire; then
        if rr_firewall_prepare_quarantine_evidence_locked; then
            evidence_kind=firewall-evidence-v1
        else
            rm -rf -- "$directory/firewall-evidence" 2>/dev/null || true
            failed=true
        fi
        if ! rr_firewall_lock_release; then
            failed=true
        fi
    else
        failed=true
    fi
    declare -F managed_singbox_running >/dev/null 2>&1 && \
        managed_singbox_running && singbox_runtime=true
    declare -F subscription_server_running >/dev/null 2>&1 && \
        subscription_server_running && subscription_runtime=true
    temporary=$(mktemp "$directory/.firewall-quarantine.XXXXXX") || return 1
    if ! {
        printf '%s\n' firewall-quarantine-v2 &&
        rr_firewall_capture_quarantine_unit_line sing-box.service &&
        rr_firewall_capture_quarantine_unit_line rr-nexus.service &&
        rr_firewall_capture_quarantine_unit_line rr-subscription.service &&
        rr_firewall_capture_quarantine_unit_line argo-rr-health.service &&
        rr_firewall_capture_quarantine_unit_line argo-rr-health.timer &&
        printf 'runtime\tsingbox\t%s\n' "$singbox_runtime" &&
        printf 'runtime\tsubscription\t%s\n' "$subscription_runtime" &&
        printf 'evidence\t%s\n' "$evidence_kind"
    } > "$temporary" || \
       ! chown 0:0 "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
    rr_firewall_load_fail_closed_quarantine || failed=true
    rr_firewall_activate_quarantine_supervisor || failed=true
    [ "$failed" = false ]
}

rr_firewall_managed_unit_is_disabled_inactive() {
    local unit="$1" load_state="" active_state="" file_state=""
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || \
        return 1
    active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null) || \
        return 1
    file_state=$(systemctl show --property=UnitFileState --value "$unit" 2>/dev/null) || \
        return 1
    if [ "$load_state" = not-found ] && [ -z "$file_state" ]; then
        file_state=not-found
    fi
    case "$load_state:$active_state:$file_state" in
        loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:disabled|loaded:failed:static|\
        masked:inactive:masked|masked:failed:masked|\
        not-found:inactive:not-found) return 0 ;;
        *) return 1 ;;
    esac
}

rr_firewall_disable_managed_unit() {
    local unit="$1"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rr_firewall_managed_unit_is_disabled_inactive "$unit"
}

# Reversible quiesce used only while an otherwise exact menu rollback is in
# progress.  It deliberately does not publish quarantine evidence or change
# unit enablement.  The caller must restore and prove the captured pre-menu
# runtime state before it may downgrade the failure to an ordinary status 1.
rr_firewall_quiesce_menu_runtimes() {
    local failed=false
    if declare -F stop_subscription_servers >/dev/null 2>&1 && \
       declare -F subscription_server_running >/dev/null 2>&1; then
        stop_subscription_servers >/dev/null 2>&1 || failed=true
        subscription_server_running && failed=true
    else
        failed=true
    fi
    if declare -F stop_singbox_instances >/dev/null 2>&1 && \
       declare -F managed_singbox_running >/dev/null 2>&1; then
        stop_singbox_instances >/dev/null 2>&1 || failed=true
        managed_singbox_running && failed=true
    else
        failed=true
    fi
    [ "$failed" = false ]
}

rr_firewall_quiesce_durable_ingress() {
    local failed=false
    rr_firewall_disable_managed_unit argo-rr-health.timer || failed=true
    rr_firewall_disable_managed_unit argo-rr-health.service || failed=true

    if declare -F stop_subscription_servers >/dev/null 2>&1 && \
       declare -F subscription_server_running >/dev/null 2>&1; then
        stop_subscription_servers >/dev/null 2>&1 || failed=true
        subscription_server_running && failed=true
    else
        failed=true
    fi
    rr_firewall_disable_managed_unit rr-subscription.service || failed=true

    if declare -F stop_singbox_instances >/dev/null 2>&1 && \
       declare -F managed_singbox_running >/dev/null 2>&1; then
        stop_singbox_instances >/dev/null 2>&1 || failed=true
        managed_singbox_running && failed=true
    else
        failed=true
    fi
    rr_firewall_disable_managed_unit sing-box.service || failed=true
    rr_firewall_disable_managed_unit rr-nexus.service || failed=true
    [ "$failed" = false ]
}

# Arm the crash boundary while the global firewall lock is held.  The marker
# uses the same path as a permanent quarantine, so the already-proved systemd
# ExecConditions and path supervisor block both states.  No backend writer is
# allowed until the durable rename, supervisor activation, and synchronous
# ingress stop proof have all completed.
rr_firewall_inflight_begin_locked() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local hash=""
    rr_firewall_lock_is_held || return 1
    rr_firewall_inflight_is_owned && return 0
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    if [ -e "$directory" ] || [ -L "$directory" ]; then
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
            return 1
    else
        install -d -o 0 -g 0 -m 700 -- "$directory" || return 1
    fi
    rr_firewall_install_fail_closed_supervisor || return 1
    rr_firewall_install_fail_closed_dropins || return 1
    rr_firewall_prepare_quarantine_evidence_locked || return 1
    if ! rr_firewall_write_marker_locked firewall-inflight-v1 \
        firewall-evidence-v1; then
        return 1
    fi
    hash=$(sha256sum -- "$marker" 2>/dev/null | awk '{print $1}') || return 2
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || return 2
    RR_FIREWALL_INFLIGHT_ACTIVE=1
    RR_FIREWALL_INFLIGHT_OWNER_PID="$BASHPID"
    RR_FIREWALL_INFLIGHT_MARKER_SHA256="$hash"
    if ! rr_firewall_load_inflight_marker || \
       ! rr_firewall_activate_quarantine_supervisor || \
       ! rr_firewall_quiesce_durable_ingress; then
        rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        return 2
    fi
    rr_firewall_inflight_is_owned || return 2
}

# Clear a fully proved transaction and restore the exact pre-transaction
# service state.  Any uncertainty before marker removal is promoted in place
# to a permanent v2 quarantine.  Any later restoration failure publishes a
# fresh v2 quarantine before returning the distinct indeterminate status.
rr_firewall_inflight_finish_locked() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local evidence="$directory/firewall-evidence"
    local completed="$directory/.firewall-evidence-completed.${BASHPID}"
    local index=0 failed=false
    rr_firewall_inflight_is_owned || return 2
    for ((index=0; index<${#RR_FIREWALL_QUARANTINE_UNITS[@]}; index++)); do
        rr_firewall_restore_quarantine_unit_enablement "$index" || failed=true
    done
    rr_firewall_deactivate_quarantine_retry || failed=true
    if [ "$failed" = true ]; then
        rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    fi
    [ -d "$evidence" ] && [ ! -L "$evidence" ] || {
        rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    }
    [ ! -e "$completed" ] && [ ! -L "$completed" ] || {
        rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    }
    if ! mv -- "$evidence" "$completed" || ! rm -f -- "$marker" || \
       ! rm -rf -- "$completed" || ! sync -f "$directory"; then
        if [ -e "$marker" ] || [ -L "$marker" ]; then
            rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        else
            rr_firewall_publish_fail_closed_quarantine >/dev/null 2>&1 || true
        fi
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    fi
    RR_FIREWALL_INFLIGHT_ACTIVE=0
    RR_FIREWALL_INFLIGHT_OWNER_PID=""
    RR_FIREWALL_INFLIGHT_MARKER_SHA256=""
    if ! rr_firewall_activate_idle_quarantine_supervisor; then
        rr_firewall_publish_fail_closed_quarantine >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    fi
    if ! rr_firewall_restore_quarantine_runtime_state; then
        rr_firewall_publish_fail_closed_quarantine >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        return 2
    fi
    return 0
}

rr_firewall_stop_nodes_on_indeterminate_commit() {
    local failed=false
    # Publish durable evidence before stopping anything.  The corresponding
    # units are then disabled and proved inactive, so a reboot cannot silently
    # re-expose ingress while the marker awaits an explicit verified repair.
    rr_firewall_publish_fail_closed_quarantine || failed=true
    rr_firewall_quiesce_durable_ingress || failed=true
    [ "$failed" = false ]
}

rr_firewall_fail_closed_stop_nodes() {
    local context="$1"
    if rr_firewall_stop_nodes_on_indeterminate_commit; then
        printf '[严重] %s；RR 公网运行面已停止并验证 inactive，请立即人工检查。\n' \
            "$context" >&2
        return 2
    fi
    printf '[紧急] %s；无法验证 RR 公网运行面已停止，请立即隔离主机并人工检查。\n' \
        "$context" >&2
    return 3
}

rr_firewall_persistence_backend_available() {
    command -v netfilter-persistent >/dev/null 2>&1 || \
        { command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; }
}

install_deps() {
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '[安全拒绝] 热更新候选迁移不得运行 apt；缺少依赖时将由事务回滚。' >&2
        return 1
    fi
    echo -e "\n${YELLOW}正在更新系统源并安装必要组件 ...${RESET}"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
        ca-certificates curl wget jq python3 python3-cryptography sqlite3 openssl iproute2 qrencode dnsutils cron \
        iptables procps tar gzip coreutils util-linux || return 1

    # Debian/Ubuntu 上 iptables-persistent 可能与已有 UFW 互斥并触发 apt
    # 卸载 UFW。保留用户选择的防火墙及其既有规则；UFW 自身负责规则持久化。
    # 只有系统没有 UFW 时才安装 netfilter-persistent 后端。
    if rr_ufw_installed; then
        echo -e "${GREEN}[防火墙] 检测到 UFW，已保留现有 UFW 配置。${RESET}"
    else
        debconf-set-selections 2>/dev/null <<< \
            'iptables-persistent iptables-persistent/autosave_v4 boolean true'
        debconf-set-selections 2>/dev/null <<< \
            'iptables-persistent iptables-persistent/autosave_v6 boolean true'
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
            iptables-persistent || return 1
    fi

    if ! command -v vnstat &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y vnstat || return 1
        systemctl enable vnstat >/dev/null 2>&1
        systemctl start vnstat >/dev/null 2>&1
    fi

    echo -e "\n${YELLOW}正在优化网络，开启 BBR ...${RESET}"
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        local bbr_config_written=true
        if [ ! -f /etc/sysctl.d/99-argo-rr.conf ] || \
           ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.d/99-argo-rr.conf 2>/dev/null; then
            if ! printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' \
                > /etc/sysctl.d/99-argo-rr.conf; then
                bbr_config_written=false
            fi
        fi
        [ "$bbr_config_written" = true ] && sysctl --system >/dev/null 2>&1 || true
        if [ "$bbr_config_written" = true ] && \
           [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
            echo -e "${GREEN}[成功] BBR 网络加速已激活！${RESET}"
        else
            echo -e "${YELLOW}[提示] 内核支持 BBR，但当前容器不允许修改 sysctl，已安全跳过。${RESET}"
        fi
    else
        echo -e "${YELLOW}[提示] 当前内核/容器未提供 BBR，已跳过，不影响节点使用。${RESET}"
    fi
}

cloudflared_token_file_supported() {
    local version=""
    command -v cloudflared >/dev/null 2>&1 || return 1
    version=$(cloudflared --version 2>/dev/null | grep -Eo '[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,3}' | head -1) || return 1
    python3 - "$version" <<'PY'
import sys

parts = tuple(int(item) for item in sys.argv[1].split("."))
raise SystemExit(0 if parts >= (2025, 4, 0) else 1)
PY
}

install_cloudflared() {
    cloudflared_token_file_supported && return 0

    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '[安全拒绝] 热更新候选缺少受支持的 Cloudflared；未下载或安装软件包。' >&2
        return 1
    fi

    echo -e "${YELLOW}仅因已选择 Argo，正在下载并安装 Cloudflared ($SYS_ARCH)...${RESET}"
    local cf_tmp_dir=""
    local release_metadata=""
    local release_selection=""
    local release_tag=""
    local asset_url=""
    local expected_sha256=""
    local expected_size=""
    local asset_name="cloudflared-linux-${SYS_ARCH}.deb"
    local release_api="${RR_CLOUDFLARED_RELEASE_API:-https://api.github.com/repos/cloudflare/cloudflared/releases/latest}"
    local -a cf_release_values=()
    cf_tmp_dir=$(mktemp -d /tmp/rr-cloudflared.XXXXXX) || return 1
    release_metadata="$cf_tmp_dir/release.json"
    release_selection="$cf_tmp_dir/selection"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-all-errors \
        --connect-timeout 10 --max-time 60 --max-filesize 5242880 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --output "$release_metadata" "$release_api"; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] 无法读取 Cloudflared 官方发布元数据。${RESET}"
        return 1
    fi
    if ! python3 - "$release_metadata" "$asset_name" > "$release_selection" <<'PY'
import json
import re
import sys
import urllib.parse

metadata_path, expected_name = sys.argv[1:]
with open(metadata_path, "r", encoding="utf-8") as release_file:
    release = json.load(release_file)
tag = str(release.get("tag_name", ""))
if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest cloudflared release is not stable")
if not re.fullmatch(r"20[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,3}", tag):
    raise SystemExit("invalid cloudflared release tag")
if tuple(int(item) for item in tag.split(".")) < (2025, 4, 0):
    raise SystemExit("cloudflared release lacks token-file support")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("cloudflared release asset is missing or duplicated")
asset = assets[0]
url = str(asset.get("browser_download_url", ""))
parsed = urllib.parse.urlsplit(url)
expected_path = f"/cloudflare/cloudflared/releases/download/{tag}/{expected_name}"
if parsed.scheme != "https" or parsed.hostname != "github.com" or parsed.path != expected_path:
    raise SystemExit("cloudflared asset URL is not bound to the selected tag")
body = str(release.get("body", ""))
matches = re.findall(
    rf"(?mi)^\s*{re.escape(expected_name)}:\s*([0-9a-f]{{64}})\s*$",
    body,
)
if len(set(matches)) != 1:
    raise SystemExit("cloudflared release checksum is missing or ambiguous")
checksum = matches[0]
api_digest = str(asset.get("digest") or "")
if api_digest and api_digest != f"sha256:{checksum}":
    raise SystemExit("cloudflared API digest disagrees with release checksum")
size = asset.get("size")
if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= 128 * 1024 * 1024:
    raise SystemExit("cloudflared asset size is invalid")
print(tag)
print(url)
print(checksum)
print(size)
PY
    then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared 发布版本、资产或官方 SHA256 元数据无效。${RESET}"
        return 1
    fi
    mapfile -t cf_release_values < "$release_selection"
    if [ "${#cf_release_values[@]}" -ne 4 ]; then
        rm -rf "$cf_tmp_dir"
        return 1
    fi
    release_tag="${cf_release_values[0]}"
    asset_url="${cf_release_values[1]}"
    expected_sha256="${cf_release_values[2]}"
    expected_size="${cf_release_values[3]}"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-all-errors \
        --connect-timeout 10 --max-time 120 --max-filesize "$expected_size" \
        --output "$cf_tmp_dir/cloudflared.deb" \
        "$asset_url"; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 下载失败。${RESET}"
        return 1
    fi
    if [ "$(stat -c '%s' "$cf_tmp_dir/cloudflared.deb" 2>/dev/null || printf 0)" != "$expected_size" ] || \
       ! printf '%s  %s\n' "$expected_sha256" "$cf_tmp_dir/cloudflared.deb" | sha256sum -c - >/dev/null 2>&1 || \
       ! dpkg-deb --info "$cf_tmp_dir/cloudflared.deb" >/dev/null 2>&1; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared ${release_tag} 资产摘要或 DEB 结构校验失败。${RESET}"
        return 1
    fi
    if ! dpkg -i "$cf_tmp_dir/cloudflared.deb" >/dev/null 2>&1; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 安装失败。${RESET}"
        return 1
    fi
    if ! cloudflared --version 2>/dev/null | grep -Fq "$release_tag" || \
       ! cloudflared_token_file_supported; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared 安装后的版本与发布元数据不一致。${RESET}"
        return 1
    fi
    rm -rf "$cf_tmp_dir"
}

rr_ufw_backend_state() {
    local status=""
    command -v ufw >/dev/null 2>&1 || return 1
    if status=$(LC_ALL=C ufw status 2>/dev/null); then
        [[ "$status" =~ ^Status:[[:space:]]+active([[:space:]]|$) ]] && return 0
        [[ "$status" =~ ^Status:[[:space:]]+inactive([[:space:]]|$) ]] && return 1
        return 2
    fi
    return 2
}

rr_netfilter_backend_state() {
    local backend="$1"
    command -v "$backend" >/dev/null 2>&1 || return 1
    "$backend" -w 5 -t filter -S INPUT >/dev/null 2>&1 && return 0
    return 2
}

rr_ipv6_stack_is_disabled() {
    local proc_root="${RR_PROC_ROOT:-/proc}" conf_root="" path="" name=""
    local value="" extra=""
    local -a disable_flags=()

    conf_root="${proc_root%/}/sys/net/ipv6/conf"
    [ -d "$conf_root" ] || return 1
    disable_flags=(
        "$conf_root/all/disable_ipv6"
        "$conf_root/default/disable_ipv6"
    )
    for path in "$conf_root"/*; do
        [ -e "$path" ] || continue
        [ -d "$path" ] || continue
        name="${path##*/}"
        case "$name" in all|default) continue ;; esac
        disable_flags+=("$path/disable_ipv6")
    done

    for path in "${disable_flags[@]}"; do
        [ -r "$path" ] || return 1
        value=""
        extra=""
        {
            IFS= read -r value || return 1
            [ "$value" = 1 ] || return 1
            # sysctl evidence must be exactly one value; a second line is not
            # a trustworthy kernel-disabled proof even when its first is 1.
            if IFS= read -r extra; then
                return 1
            fi
        } < "$path"
    done
    return 0
}

rr_ufw_rule_state() {
    local proto_port="$1" proto_type="$2" action="$3" comment="$4"
    local coverage="${5:-all}" status="" ipv6_required=0 ipv6_state=0
    case "$coverage" in all|any) ;; *) return 2 ;; esac
    if ! status=$(LC_ALL=C ufw status 2>/dev/null); then
        return 2
    fi
    [[ "$status" =~ ^Status:[[:space:]]+active([[:space:]]|$) ]] || return 2
    if printf '%s\n' "$status" | grep -qE '^[^[:space:]]+[[:space:]]+\(v6\)[[:space:]]'; then
        ipv6_required=1
    elif command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -w 5 -t filter -S ufw6-user-input >/dev/null 2>&1; then
            ipv6_required=1
        else
            ipv6_state=$?
            [ "$ipv6_state" -eq 1 ] || return 2
        fi
    fi
    if printf '%s\n' "$status" | awk -v rule="${proto_port}/${proto_type}" \
        -v action="$action" -v comment="$comment" -v coverage="$coverage" \
        -v ipv6_required="$ipv6_required" '
            $1 == rule {
                family=4
                field=2
                if ($2 == "(v6)") { family=6; field=3 }
                if (toupper($field) != action) next
                marker=$0
                if (sub(/^.*#[[:space:]]*/, "", marker) && marker == comment) {
                    if (family == 4) found4=1
                    else found6=1
                }
            }
            END {
                if (coverage == "any") exit((found4 || found6) ? 0 : 1)
                exit((found4 && (!ipv6_required || found6)) ? 0 : 1)
            }
        '; then
        return 0
    fi
    return 1
}

# UFW rewrites its user chains from the persistent `show added` program for
# every rule add/delete.  A live-only rule injected directly into one of those
# chains would therefore be silently erased by an otherwise unrelated RR
# change.  Before each UFW writer, prove that every live rule in the chains
# UFW reloads is the exact simple projection of the current persistent rules.
# Deliberately accept only the PORT/PROTO allow/deny grammar RR can attribute;
# route/direction/range/limit/custom programs remain untouched and fail closed.
rr_ufw_reload_program_is_canonical() {
    local directory="" added="" backend="" raw="" prefix="" state=0 proof_state=0
    directory=$(mktemp -d /tmp/rr-ufw-reload-proof.XXXXXX) || return 1
    added="$directory/added"
    if ! rr_ufw_backend_state || \
       ! LC_ALL=C ufw show added > "$added" 2>/dev/null; then
        rm -rf "$directory"
        return 1
    fi
    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        case "$state" in
            0) ;;
            1)
                if [ "$backend" = iptables ] || ! rr_ipv6_stack_is_disabled; then
                    rm -rf "$directory"
                    return 1
                fi
                continue
                ;;
            *) rm -rf "$directory"; return 1 ;;
        esac
        prefix=ufw
        [ "$backend" != ip6tables ] || prefix=ufw6
        raw="$directory/${backend}.filter"
        "$backend" -w 5 -t filter -S > "$raw" 2>/dev/null || {
            rm -rf "$directory"
            return 1
        }
        if python3 - "$added" "$raw" "$prefix" <<'PY'
import re
import shlex
import sys

added_path, raw_path, prefix = sys.argv[1:]
wanted_chains = {
    f"{prefix}-user-input",
    f"{prefix}-user-output",
    f"{prefix}-user-forward",
}
header = "Added user rules (see 'ufw status' for running firewall):"
expected = []
for raw_line in open(added_path, encoding="utf-8"):
    line = raw_line.strip()
    if not line or line == header:
        continue
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if (len(tokens) not in {3, 5} or tokens[0] != "ufw"
            or tokens[1] not in {"allow", "deny"}
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535
            or (len(tokens) == 5 and tokens[3] != "comment")):
        raise SystemExit(1)
    port, protocol = tokens[2].split("/", 1)
    target = "ACCEPT" if tokens[1] == "allow" else "DROP"
    expected.append((int(port), protocol, target))


def option(tokens, *names):
    matches = [index for index, token in enumerate(tokens) if token in names]
    if len(matches) != 1 or matches[0] + 1 >= len(tokens):
        return None
    return tokens[matches[0] + 1]


def canonical_input_projection(tokens):
    if len(tokens) < 8 or tokens[0] != "-A" or tokens[1] != f"{prefix}-user-input":
        return None
    if "!" in tokens:
        return None
    protocol = option(tokens, "-p", "--protocol")
    port = option(tokens, "--dport")
    target = option(tokens, "-j", "--jump")
    if (protocol not in {"tcp", "udp"}
            or port is None or re.fullmatch(r"[1-9][0-9]{0,4}", port) is None
            or int(port) > 65535 or target not in {"ACCEPT", "DROP"}
            or sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1):
        return None
    index = 2
    modules = []
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return None
    if tuple(modules) not in {(), (protocol,)}:
        return None
    return int(port), protocol, target


declared = set()
actual = []
for raw_line in open(raw_path, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) == 2 and tokens[0] == "-N" and tokens[1] in wanted_chains:
        declared.add(tokens[1])
        continue
    if len(tokens) >= 3 and tokens[0] == "-A" and tokens[1] in wanted_chains:
        if tokens[1] != f"{prefix}-user-input":
            raise SystemExit(1)
        projection = canonical_input_projection(tokens)
        if projection is None:
            raise SystemExit(1)
        actual.append(projection)

# IPV6=no legitimately leaves no ufw6 user program even while ip6tables is
# readable.  A partial program is never a valid reload boundary.
if not declared:
    raise SystemExit(3)
if declared != wanted_chains or actual != expected:
    raise SystemExit(1)
PY
        then
            proof_state=0
        else
            proof_state=$?
        fi
        case "$proof_state" in
            0) ;;
            3)
                [ "$backend" = ip6tables ] || {
                    rm -rf "$directory"
                    return 1
                }
                ;;
            *) rm -rf "$directory"; return 1 ;;
        esac
    done
    rm -rf "$directory"
}

rr_netfilter_rule_state() {
    local backend="$1" proto_port="$2" proto_type="$3" comment="$4" target="$5" result=0
    if "$backend" -w 5 -t filter -C INPUT -p "$proto_type" --dport "$proto_port" \
        -m comment --comment "$comment" -j "$target" >/dev/null 2>&1; then
        return 0
    else
        result=$?
    fi
    [ "$result" -eq 1 ] && return 1
    return 2
}

rr_reconcile_ufw_protocol_rule() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local desired_action="" desired_status="" desired_comment=""
    local opposite_action="" opposite_status="" opposite_comment="" state=0 attempts=0
    rr_firewall_writer_gate_is_held || return 1
    case "$desired" in
        open)
            desired_action=allow
            desired_status=ALLOW
            desired_comment="$FIREWALL_COMMENT"
            opposite_action=deny
            opposite_status=DENY
            opposite_comment="$FIREWALL_BLOCK_COMMENT"
            ;;
        closed)
            desired_action=deny
            desired_status=DENY
            desired_comment="$FIREWALL_BLOCK_COMMENT"
            opposite_action=allow
            opposite_status=ALLOW
            opposite_comment="$FIREWALL_COMMENT"
            ;;
        *) return 1 ;;
    esac

    while [ "$attempts" -lt 100 ]; do
        if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" \
            "$opposite_comment" any; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                # UFW only accepts --force for commands that can prompt, such
                # as enable/reset.  Rule add/delete syntax rejects it on the
                # Debian 12 and Ubuntu 22.04/24.04 versions we support.
                rr_ufw_reload_program_is_canonical || return 1
                rr_ufw_backend_state || return 1
                ufw delete "$opposite_action" "$proto_port/$proto_type" \
                    comment "$opposite_comment" >/dev/null 2>&1 || return 1
                attempts=$((attempts + 1))
                ;;
            1) break ;;
            *) return 1 ;;
        esac
    done
    [ "$attempts" -lt 100 ] || return 1

    if rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" "$desired_comment"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            # A one-family remnant is not a complete desired rule. Remove the
            # exact RR-owned tuple before recreating it for every enabled UFW
            # family; never let an add report success while IPv6 stays stale.
            if rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" \
                "$desired_comment" any; then
                rr_ufw_reload_program_is_canonical || return 1
                rr_ufw_backend_state || return 1
                ufw delete "$desired_action" "$proto_port/$proto_type" \
                    comment "$desired_comment" >/dev/null 2>&1 || return 1
            else
                state=$?
                [ "$state" -eq 1 ] || return 1
            fi
            rr_ufw_reload_program_is_canonical || return 1
            rr_ufw_backend_state || return 1
            ufw "$desired_action" "$proto_port/$proto_type" \
                comment "$desired_comment" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac

    rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" "$desired_comment" || return 1
    if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" \
        "$opposite_comment" any; then
        return 1
    else
        state=$?
    fi
    [ "$state" -eq 1 ]
}

rr_reconcile_netfilter_protocol_rule() {
    local backend="$1" proto_port="$2" proto_type="$3" desired="$4"
    local desired_comment="" desired_target="" desired_action=""
    local opposite_comment="" opposite_target="" state=0 attempts=0
    rr_firewall_writer_gate_is_held || return 1
    case "$desired" in
        open)
            desired_comment="$FIREWALL_COMMENT"
            desired_target=ACCEPT
            desired_action=-I
            opposite_comment="$FIREWALL_BLOCK_COMMENT"
            opposite_target=DROP
            ;;
        closed)
            desired_comment="$FIREWALL_BLOCK_COMMENT"
            desired_target=DROP
            desired_action=-A
            opposite_comment="$FIREWALL_COMMENT"
            opposite_target=ACCEPT
            ;;
        *) return 1 ;;
    esac

    while [ "$attempts" -lt 100 ]; do
        if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
            "$opposite_comment" "$opposite_target"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                "$backend" -w 5 -t filter -D INPUT -p "$proto_type" --dport "$proto_port" \
                    -m comment --comment "$opposite_comment" -j "$opposite_target" \
                    >/dev/null 2>&1 || return 1
                attempts=$((attempts + 1))
                ;;
            1) break ;;
            *) return 1 ;;
        esac
    done
    [ "$attempts" -lt 100 ] || return 1

    if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$desired_comment" "$desired_target"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            "$backend" -w 5 -t filter "$desired_action" INPUT -p "$proto_type" \
                --dport "$proto_port" -m comment --comment "$desired_comment" \
                -j "$desired_target" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac

    rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$desired_comment" "$desired_target" || return 1
    if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$opposite_comment" "$opposite_target"; then
        return 1
    else
        state=$?
    fi
    [ "$state" -eq 1 ]
}

# Ordinary firewall changes are a single-key transaction.  The snapshot keeps
# the exact RR tuple (including its chain position) separate from an immutable
# projection of every non-target rule.  Compensation therefore needs only
# targeted -D/-I operations; it never restores an entire user firewall table.
rr_firewall_capture_ufw_protocol_state() {
    local directory="$1" proto_port="$2" proto_type="$3" raw=""
    raw="$directory/ufw.raw"
    rr_ufw_backend_state || return 1
    LC_ALL=C ufw show added > "$raw" 2>/dev/null || return 1
    python3 - "$raw" "$directory/ufw.program" "$directory/ufw.tuple" \
        "$directory/ufw.seal" "$proto_port" "$proto_type" \
        "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" <<'PY'
import re
import shlex
import sys

source, program_path, tuple_path, seal_path, port_text, protocol, allow_comment, block_comment = sys.argv[1:]
if re.fullmatch(r"[1-9][0-9]{0,4}", port_text) is None or int(port_text) > 65535:
    raise SystemExit(1)
if protocol not in {"tcp", "udp"}:
    raise SystemExit(1)
header = "Added user rules (see 'ufw status' for running firewall):"
managed = {allow_comment: "allow", block_comment: "deny"}
program = []
target = []
seal = []
position = 0
for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    if not line or line == header:
        continue
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if (len(tokens) not in {3, 5} or tokens[0] != "ufw"
            or tokens[1] not in {"allow", "deny"}
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535
            or (len(tokens) == 5 and tokens[3] != "comment")):
        raise SystemExit(1)
    position += 1
    program.append(line)
    comment = tokens[4] if len(tokens) == 5 else None
    if tokens[2] == f"{port_text}/{protocol}" and comment in managed:
        if tokens[1] != managed[comment]:
            raise SystemExit(1)
        target.append(f"{position}\t{line}")
    else:
        seal.append(line)
if len(target) > 1:
    raise SystemExit(1)
for path, lines in (
        (program_path, program), (tuple_path, target), (seal_path, seal)):
    with open(path, "w", encoding="utf-8") as output:
        for line in lines:
            output.write(line + "\n")
PY
}

rr_firewall_capture_netfilter_protocol_state() {
    local directory="$1" backend="$2" proto_port="$3" proto_type="$4"
    local mode="$5" raw="$directory/${backend}.raw"
    "$backend" -w 5 -t filter -S > "$raw" 2>/dev/null || return 1
    python3 - "$raw" "$directory/${backend}.tuple" \
        "$directory/${backend}.seal" "$backend" "$proto_port" \
        "$proto_type" "$mode" "$FIREWALL_COMMENT" \
        "$FIREWALL_BLOCK_COMMENT" <<'PY'
import re
import shlex
import sys

source, tuple_path, seal_path, backend, port_text, protocol, mode, allow_comment, block_comment = sys.argv[1:]
if backend not in {"iptables", "ip6tables"} or mode not in {"ufw", "dual", "netfilter"}:
    raise SystemExit(1)
if re.fullmatch(r"[1-9][0-9]{0,4}", port_text) is None or int(port_text) > 65535:
    raise SystemExit(1)
if protocol not in {"tcp", "udp"}:
    raise SystemExit(1)
managed = {allow_comment: "ACCEPT", block_comment: "DROP"}
user_chain = "ufw-user-input" if backend == "iptables" else "ufw6-user-input"
target = []
seal_records = []
input_position = 0


def option(tokens, *names):
    indexes = [index for index, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None
    return tokens[indexes[0] + 1]


def direct_managed_tuple(tokens):
    if len(tokens) < 10 or tokens[0] != "-A" or tokens[1] != "INPUT" or "!" in tokens:
        return False
    comment = option(tokens, "--comment")
    target_name = option(tokens, "-j", "--jump")
    rule_protocol = option(tokens, "-p", "--protocol")
    rule_port = option(tokens, "--dport")
    if (comment not in managed or target_name != managed[comment]
            or rule_protocol not in {"tcp", "udp"}
            or rule_port is None
            or re.fullmatch(r"[1-9][0-9]{0,4}", rule_port) is None
            or int(rule_port) > 65535
            or sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1 or tokens.count("--comment") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1):
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
    if (modules.count("comment") != 1
            or any(item not in {"comment", rule_protocol} for item in modules)
            or modules.count(rule_protocol) > 1 or len(modules) not in {1, 2}):
        return False
    return rule_protocol == protocol and rule_port == port_text


def compiled_ufw_tuple(tokens):
    if mode not in {"ufw", "dual"} or len(tokens) < 8 or "!" in tokens:
        return False
    if tokens[0] != "-A" or tokens[1] != user_chain:
        return False
    rule_protocol = option(tokens, "-p", "--protocol")
    rule_port = option(tokens, "--dport")
    target_name = option(tokens, "-j", "--jump")
    if (rule_protocol != protocol or rule_port != port_text
            or target_name not in {"ACCEPT", "DROP"}
            or sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1):
        return False
    index = 2
    modules = []
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return False
    return tuple(modules) in {(), (protocol,)}


for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) >= 3 and tokens[0] == "-A" and tokens[1] == "INPUT":
        input_position += 1
    if direct_managed_tuple(tokens):
        target.append(f"{input_position}\t{line}")
    elif compiled_ufw_tuple(tokens):
        continue
    else:
        if len(tokens) == 3 and tokens[0] == "-P":
            kind, chain = 0, tokens[1]
        elif len(tokens) == 2 and tokens[0] == "-N":
            kind, chain = 1, tokens[1]
        elif len(tokens) >= 3 and tokens[0] == "-A":
            kind, chain = 2, tokens[1]
        else:
            raise SystemExit(1)
        # iptables -S may move whole chain blocks relative to one another after
        # a UFW reload.  Cross-chain display order has no packet semantics;
        # preserve and seal the exact order inside each chain instead.
        seal_records.append((kind, chain, line))
if len(target) >= 100:
    raise SystemExit(1)
seal = [record[2] for record in sorted(seal_records, key=lambda item: item[:2])]
for path, lines in ((tuple_path, target), (seal_path, seal)):
    with open(path, "w", encoding="utf-8") as output:
        for line in lines:
            output.write(line + "\n")
PY
}

rr_firewall_capture_protocol_transaction() {
    local directory="$1" proto_port="$2" proto_type="$3" mode="$4"
    local backend="" state=0
    case "$mode" in ufw|dual|netfilter) ;; *) return 1 ;; esac
    printf '%s\n' "$mode" > "$directory/mode" || return 1
    if [ "$mode" = ufw ] || [ "$mode" = dual ]; then
        rr_firewall_capture_ufw_protocol_state "$directory" "$proto_port" \
            "$proto_type" || return 1
        : > "$directory/ufw.enabled" || return 1
    fi
    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
        case "$state" in
            0)
                rr_firewall_capture_netfilter_protocol_state "$directory" \
                    "$backend" "$proto_port" "$proto_type" "$mode" || return 1
                : > "$directory/${backend}.enabled" || return 1
                ;;
            1)
                [ "$backend" = ip6tables ] && rr_ipv6_stack_is_disabled || return 1
                ;;
            *) return 1 ;;
        esac
    done
    chmod 600 "$directory"/* 2>/dev/null || return 1
}

rr_firewall_protocol_transaction_seals_match() {
    local snapshot="$1" current="$2" backend=""
    cmp -s "$snapshot/mode" "$current/mode" || return 1
    if [ -f "$snapshot/ufw.enabled" ] || [ -f "$current/ufw.enabled" ]; then
        [ -f "$snapshot/ufw.enabled" ] && [ -f "$current/ufw.enabled" ] || return 1
        cmp -s "$snapshot/ufw.seal" "$current/ufw.seal" || return 1
    fi
    for backend in iptables ip6tables; do
        if [ -f "$snapshot/${backend}.enabled" ] || \
           [ -f "$current/${backend}.enabled" ]; then
            [ -f "$snapshot/${backend}.enabled" ] && \
                [ -f "$current/${backend}.enabled" ] || return 1
            cmp -s "$snapshot/${backend}.seal" \
                "$current/${backend}.seal" || return 1
        fi
    done
}

rr_firewall_protocol_transaction_exact_match() {
    local snapshot="$1" current="$2" backend=""
    rr_firewall_protocol_transaction_seals_match "$snapshot" "$current" || return 1
    if [ -f "$snapshot/ufw.enabled" ]; then
        cmp -s "$snapshot/ufw.program" "$current/ufw.program" || return 1
        cmp -s "$snapshot/ufw.tuple" "$current/ufw.tuple" || return 1
    fi
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.enabled" ] || continue
        cmp -s "$snapshot/${backend}.tuple" \
            "$current/${backend}.tuple" || return 1
    done
}

rr_firewall_run_netfilter_saved_tuple() {
    local backend="$1" operation="$2" line="$3" position="${4:-}"
    local proto_port="$5" proto_type="$6" token=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    while IFS= read -r -d '' token; do
        arguments+=("$token")
    done < <(python3 - "$line" "$proto_port" "$proto_type" \
        "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" <<'PY'
import re
import shlex
import sys

line, port_text, protocol, allow_comment, block_comment = sys.argv[1:]
managed = {allow_comment: "ACCEPT", block_comment: "DROP"}
try:
    tokens = shlex.split(line)
except ValueError:
    raise SystemExit(1)
if (len(tokens) < 10 or tokens[0:2] != ["-A", "INPUT"] or "!" in tokens
        or tokens.count("--dport") != 1 or tokens.count("--comment") != 1
        or sum(token in {"-p", "--protocol"} for token in tokens) != 1
        or sum(token in {"-j", "--jump"} for token in tokens) != 1):
    raise SystemExit(1)
def value(*names):
    indexes = [index for index, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        raise SystemExit(1)
    return tokens[indexes[0] + 1]
rule_protocol = value("-p", "--protocol")
rule_port = value("--dport")
comment = value("--comment")
target = value("-j", "--jump")
if (rule_protocol != protocol or rule_port != port_text
        or target != managed.get(comment)
        or re.fullmatch(r"[1-9][0-9]{0,4}", rule_port) is None
        or int(rule_port) > 65535):
    raise SystemExit(1)
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
        raise SystemExit(1)
if (modules.count("comment") != 1
        or any(item not in {"comment", protocol} for item in modules)
        or modules.count(protocol) > 1 or len(modules) not in {1, 2}):
    raise SystemExit(1)
for token in tokens:
    sys.stdout.buffer.write(token.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -ge 10 ] || return 1
    case "$backend" in iptables|ip6tables) ;; *) return 1 ;; esac
    case "$operation" in
        -D) arguments[0]=-D ;;
        -I)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            arguments=(-I INPUT "$position" "${arguments[@]:2}")
            ;;
        *) return 1 ;;
    esac
    "$backend" -w 5 -t filter "${arguments[@]}" >/dev/null 2>&1
}

rr_firewall_run_ufw_saved_tuple() {
    local operation="$1" line="$2" position="${3:-}" proto_port="$4"
    local proto_type="$5" token=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    while IFS= read -r -d '' token; do
        arguments+=("$token")
    done < <(python3 - "$line" "$proto_port" "$proto_type" \
        "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" <<'PY'
import shlex
import sys

line, port_text, protocol, allow_comment, block_comment = sys.argv[1:]
managed = {allow_comment: "allow", block_comment: "deny"}
try:
    tokens = shlex.split(line)
except ValueError:
    raise SystemExit(1)
if (len(tokens) != 5 or tokens[0] != "ufw" or tokens[1] not in {"allow", "deny"}
        or tokens[2] != f"{port_text}/{protocol}" or tokens[3] != "comment"
        or tokens[1] != managed.get(tokens[4])):
    raise SystemExit(1)
for token in tokens:
    sys.stdout.buffer.write(token.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -eq 5 ] && [ "${arguments[0]}" = ufw ] || return 1
    rr_ufw_reload_program_is_canonical || return 1
    rr_ufw_backend_state || return 1
    case "$operation" in
        delete) ufw delete "${arguments[@]:1}" >/dev/null 2>&1 ;;
        insert)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            ufw insert "$position" "${arguments[@]:1}" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

rr_firewall_restore_netfilter_protocol_state() {
    local snapshot="$1" backend="$2" proto_port="$3" proto_type="$4"
    local mode="$5" current="" position="" line=""
    [ -f "$snapshot/${backend}.enabled" ] || return 0
    current=$(mktemp -d /tmp/rr-firewall-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_netfilter_protocol_state "$current" "$backend" \
        "$proto_port" "$proto_type" "$mode" || \
       ! cmp -s "$snapshot/${backend}.seal" "$current/${backend}.seal"; then
        rm -rf "$current"
        return 1
    fi
    if cmp -s "$snapshot/${backend}.tuple" "$current/${backend}.tuple"; then
        rm -rf "$current"
        return 0
    fi
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_netfilter_saved_tuple "$backend" -D "$line" "" \
            "$proto_port" "$proto_type" || { rm -rf "$current"; return 1; }
    done < "$current/${backend}.tuple"
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_netfilter_saved_tuple "$backend" -I "$line" "$position" \
            "$proto_port" "$proto_type" || { rm -rf "$current"; return 1; }
    done < "$snapshot/${backend}.tuple"
    rm -rf "$current"
    current=$(mktemp -d /tmp/rr-firewall-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_netfilter_protocol_state "$current" "$backend" \
        "$proto_port" "$proto_type" "$mode" || \
       ! cmp -s "$snapshot/${backend}.seal" "$current/${backend}.seal" || \
       ! cmp -s "$snapshot/${backend}.tuple" "$current/${backend}.tuple"; then
        rm -rf "$current"
        return 1
    fi
    rm -rf "$current"
}

rr_firewall_restore_ufw_protocol_state() {
    local snapshot="$1" proto_port="$2" proto_type="$3"
    local current="" position="" line=""
    [ -f "$snapshot/ufw.enabled" ] || return 0
    current=$(mktemp -d /tmp/rr-firewall-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_ufw_protocol_state "$current" "$proto_port" \
        "$proto_type" || ! cmp -s "$snapshot/ufw.seal" "$current/ufw.seal"; then
        rm -rf "$current"
        return 1
    fi
    if cmp -s "$snapshot/ufw.program" "$current/ufw.program"; then
        rm -rf "$current"
        return 0
    fi
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_ufw_saved_tuple delete "$line" "" "$proto_port" \
            "$proto_type" || { rm -rf "$current"; return 1; }
    done < "$current/ufw.tuple"
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_ufw_saved_tuple insert "$line" "$position" \
            "$proto_port" "$proto_type" || { rm -rf "$current"; return 1; }
    done < "$snapshot/ufw.tuple"
    rm -rf "$current"
}

rr_firewall_restore_protocol_transaction() {
    local snapshot="$1" proto_port="$2" proto_type="$3" mode="$4"
    local current="" failed=false
    # Writers ran UFW -> IPv4 -> IPv6, so compensation is deliberately the
    # inverse sequence.  Continue across families to make a best-effort return
    # to the captured live state even if one family itself becomes unwritable.
    rr_firewall_restore_netfilter_protocol_state "$snapshot" ip6tables \
        "$proto_port" "$proto_type" "$mode" || failed=true
    rr_firewall_restore_netfilter_protocol_state "$snapshot" iptables \
        "$proto_port" "$proto_type" "$mode" || failed=true
    rr_firewall_restore_ufw_protocol_state "$snapshot" "$proto_port" \
        "$proto_type" || failed=true
    [ "$failed" = false ] || return 1
    current=$(mktemp -d /tmp/rr-firewall-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_protocol_transaction "$current" "$proto_port" \
        "$proto_type" "$mode" || \
       ! rr_firewall_protocol_transaction_exact_match "$snapshot" "$current"; then
        rm -rf "$current"
        return 1
    fi
    rm -rf "$current"
}

# Port-hop rules live in the nat table, but they participate in the same
# configured-firewall commit as the INPUT tuples above.  Keep only the exact
# RR hop projection and its PREROUTING positions in the mutable part of the
# snapshot; every other nat rule is an immutable seal.
rr_firewall_hop_backend_first_match_is_safe() {
    local backend="$1" label="$2" main_port="$3" spec_list="$4"
    local phase="${5:-pre}" ignored_spec_list="${6:-}" raw=""
    case "$backend" in iptables|ip6tables) ;; *) return 1 ;; esac
    case "$label" in HY2|TU5) ;; *) return 1 ;; esac
    is_valid_port "$main_port" && is_valid_hop_spec "$spec_list" && \
        [ -n "$spec_list" ] || return 1
    case "$phase" in pre|post) ;; *) return 1 ;; esac
    raw=$(mktemp /tmp/rr-firewall-hop-first-match.XXXXXX) || return 1
    if ! "$backend" -w 5 -t nat -S > "$raw" 2>/dev/null || \
       ! python3 - "$raw" "$label" "$main_port" "$spec_list" "$phase" \
            "$ignored_spec_list" <<'PY'
import re
import shlex
import sys

path, label, main_port_text, spec_list, phase, ignored_spec_list = sys.argv[1:]
if label not in {"HY2", "TU5"} or phase not in {"pre", "post"}:
    raise SystemExit(1)
if re.fullmatch(r"[1-9][0-9]{0,4}", main_port_text) is None:
    raise SystemExit(1)
main_port = int(main_port_text)
if main_port > 65535:
    raise SystemExit(1)


def parse_interval(text):
    match = re.fullmatch(r"([0-9]+)(?::([0-9]+))?", text)
    if match is None:
        raise ValueError
    low = int(match.group(1))
    high = int(match.group(2) or match.group(1))
    if low < 1000 or high > 65535 or low > high:
        raise ValueError
    return low, high


specs = spec_list.split(",")
if not specs or any(not item for item in specs):
    raise SystemExit(1)
try:
    intervals = {item: parse_interval(item) for item in specs}
except ValueError:
    raise SystemExit(1)
if len(intervals) != len(specs):
    raise SystemExit(1)
ordered = sorted((low, high, item) for item, (low, high) in intervals.items())
for previous, current in zip(ordered, ordered[1:]):
    if current[0] <= previous[1]:
        raise SystemExit(1)
ignored_specs = set(filter(None, ignored_spec_list.split(",")))
try:
    for item in ignored_specs:
        parse_interval(item)
except ValueError:
    raise SystemExit(1)


def values(tokens, *names):
    result = []
    for index, token in enumerate(tokens):
        if token in names:
            if index + 1 >= len(tokens):
                return None
            result.append(tokens[index + 1])
    return result


def exact_desired(tokens, wanted):
    if len(tokens) < 8 or tokens[0:2] != ["-A", "PREROUTING"] or "!" in tokens:
        return False
    protocols = values(tokens, "-p", "--protocol")
    dports = values(tokens, "--dport")
    multiports = values(tokens, "--dports")
    jumps = values(tokens, "-j", "--jump")
    gotos = values(tokens, "-g", "--goto")
    comments = values(tokens, "--comment")
    to_ports = values(tokens, "--to-ports")
    to_destinations = values(tokens, "--to-destination")
    if any(value is None for value in (
            protocols, dports, multiports, jumps, gotos, comments,
            to_ports, to_destinations)):
        return False
    if (protocols != ["udp"] or dports != [wanted] or multiports
            or len(jumps) != 1 or gotos or len(comments) > 1):
        return False
    if comments and comments[0] != f"argo-rr-{label}":
        return False
    jump = jumps[0]
    if jump == "REDIRECT":
        if to_ports != [main_port_text] or to_destinations:
            return False
    elif jump == "DNAT":
        if to_destinations != [f":{main_port_text}"] or to_ports:
            return False
    else:
        return False
    index = 2
    modules = []
    value_options = {
        "-p", "--protocol", "--dport", "--comment", "-j", "--jump",
        "--to-ports", "--to-destination",
    }
    while index < len(tokens):
        token = tokens[index]
        if token in value_options:
            if index + 1 >= len(tokens):
                return False
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return False
    return (all(module in {"udp", "comment"} for module in modules)
            and modules.count("udp") <= 1
            and modules.count("comment") <= 1
            and (bool(comments) == (modules.count("comment") == 1)))


def rule_intervals(tokens):
    # Negation and malformed/duplicate selectors are deliberately treated as
    # matching the entire candidate class.  RR may only bypass a rule after a
    # positive, mechanically proven disjointness result.
    if "!" in tokens:
        return [(1, 65535)]
    protocols = values(tokens, "-p", "--protocol")
    if protocols is None or len(protocols) > 1:
        return [(1, 65535)]
    if protocols:
        protocol = protocols[0].lower()
        if protocol not in {"udp", "17", "all", "0"}:
            if protocol in {"tcp", "6", "icmp", "1", "icmpv6", "58", "sctp", "132"}:
                return []
            return [(1, 65535)]
    ports = values(tokens, "--dport", "--dports")
    if ports is None or len(ports) != 1:
        return [(1, 65535)]
    result = []
    for item in ports[0].split(","):
        match = re.fullmatch(r"([0-9]+)(?:(?::|-)([0-9]+))?", item)
        if match is None:
            return [(1, 65535)]
        low = int(match.group(1))
        high = int(match.group(2) or match.group(1))
        if low < 0 or high > 65535 or low > high:
            return [(1, 65535)]
        result.append((low, high))
    return result


rules = []
for raw_line in open(path, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) >= 3 and tokens[0:2] == ["-A", "PREROUTING"]:
        rules.append(tokens)

for wanted, (wanted_low, wanted_high) in intervals.items():
    desired_seen = False
    for tokens in rules:
        overlaps = any(low <= wanted_high and wanted_low <= high
                       for low, high in rule_intervals(tokens))
        if not overlaps:
            continue
        # A replacement transaction may remove an exact RR/legacy tuple
        # before appending the new desired tuple.  Ignore only those fully
        # recognized old tuples; every user/unknown overlap still rejects
        # before the first write.
        if phase == "pre" and any(exact_desired(tokens, old)
                                  for old in ignored_specs):
            continue
        if exact_desired(tokens, wanted):
            desired_seen = True
            break
        # This rule would be evaluated before an appended RR rule, or already
        # shadows an existing RR rule.  Unknown jumps/user chains, ranges,
        # multiport selectors and negation therefore all fail closed.
        raise SystemExit(1)
    if phase == "post" and not desired_seen:
        raise SystemExit(1)
PY
    then
        rm -f "$raw"
        return 1
    fi
    rm -f "$raw"
}

rr_firewall_hop_program_first_match_is_safe() {
    local label="$1" main_port="$2" spec_list="$3" phase="${4:-pre}"
    local ignored_spec_list="${5:-}" backend="" seen=false
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        seen=true
        rr_firewall_hop_backend_first_match_is_safe "$backend" "$label" \
            "$main_port" "$spec_list" "$phase" "$ignored_spec_list" || return 1
    done
    [ "$seen" = true ]
}

rr_firewall_hop_spec_lists_are_disjoint() {
    local first="$1" second="$2"
    is_valid_hop_spec "$first" && is_valid_hop_spec "$second" && \
        [ -n "$first" ] && [ -n "$second" ] || return 1
    python3 - "$first" "$second" <<'PY'
import re
import sys


def intervals(text):
    result = []
    for item in text.split(","):
        match = re.fullmatch(r"([0-9]+)(?::([0-9]+))?", item)
        if match is None:
            raise SystemExit(1)
        low = int(match.group(1))
        high = int(match.group(2) or match.group(1))
        if low < 1000 or high > 65535 or low > high:
            raise SystemExit(1)
        result.append((low, high))
    return result


first, second = map(intervals, sys.argv[1:])
if any(a <= d and c <= b for a, b in first for c, d in second):
    raise SystemExit(1)
PY
}

rr_firewall_capture_hop_backend_state() {
    local directory="$1" backend="$2" label="$3" main_port="$4"
    local spec_list="$5" raw="$directory/${backend}.nat.raw"
    "$backend" -w 5 -t nat -S > "$raw" 2>/dev/null || return 1
    python3 - "$raw" "$directory/${backend}.nat.tuple" \
        "$directory/${backend}.nat.seal" "$backend" "$label" \
        "$main_port" "$spec_list" <<'PY'
import re
import shlex
import sys

source, tuple_path, seal_path, backend, label, main_port, spec_list = sys.argv[1:]
if backend not in {"iptables", "ip6tables"}:
    raise SystemExit(1)
if re.fullmatch(r"[A-Z0-9_-]{1,32}", label) is None:
    raise SystemExit(1)
if re.fullmatch(r"[1-9][0-9]{0,4}", main_port) is None or int(main_port) > 65535:
    raise SystemExit(1)
specs = spec_list.split(",")
if not specs or any(re.fullmatch(r"[1-9][0-9]{0,4}(?::[1-9][0-9]{0,4})?", item) is None
                    for item in specs):
    raise SystemExit(1)
for item in specs:
    values = [int(value) for value in item.split(":")]
    if any(value < 1000 or value > 65535 for value in values):
        raise SystemExit(1)
    if len(values) == 2 and values[0] >= values[1]:
        raise SystemExit(1)
specs = set(specs)
target = []
seal_records = []
prerouting_position = 0


def option(tokens, *names):
    indexes = [index for index, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None
    return tokens[indexes[0] + 1]


def exact_hop_tuple(tokens):
    if len(tokens) < 10 or tokens[0:2] != ["-A", "PREROUTING"] or "!" in tokens:
        return False
    protocol = option(tokens, "-p", "--protocol")
    dport = option(tokens, "--dport")
    jump = option(tokens, "-j", "--jump")
    comment_indexes = [index for index, token in enumerate(tokens)
                       if token == "--comment"]
    if (protocol != "udp" or dport not in specs or jump not in {"REDIRECT", "DNAT"}
            or sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1
            or len(comment_indexes) > 1):
        return False
    if comment_indexes:
        index = comment_indexes[0]
        if index + 1 >= len(tokens) or tokens[index + 1] != f"argo-rr-{label}":
            return False
    to_ports = option(tokens, "--to-ports")
    to_destination = option(tokens, "--to-destination")
    if jump == "REDIRECT":
        if to_ports != main_port or to_destination is not None:
            return False
    elif to_destination != f":{main_port}" or to_ports is not None:
        return False
    index = 2
    modules = []
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "--comment",
                     "-j", "--jump", "--to-ports", "--to-destination"}:
            if index + 1 >= len(tokens):
                return False
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return False
    if (any(module not in {"udp", "comment"} for module in modules)
            or modules.count("udp") > 1 or modules.count("comment") > 1
            or (bool(comment_indexes) != (modules.count("comment") == 1))):
        return False
    return True


for raw_line in open(source, encoding="utf-8"):
    line = raw_line.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) >= 3 and tokens[0:2] == ["-A", "PREROUTING"]:
        prerouting_position += 1
    if exact_hop_tuple(tokens):
        target.append(f"{prerouting_position}\t{line}")
    else:
        if len(tokens) == 3 and tokens[0] == "-P":
            kind, chain = 0, tokens[1]
        elif len(tokens) == 2 and tokens[0] == "-N":
            kind, chain = 1, tokens[1]
        elif len(tokens) >= 3 and tokens[0] == "-A":
            kind, chain = 2, tokens[1]
        else:
            raise SystemExit(1)
        seal_records.append((kind, chain, line))
if len(target) >= 100:
    raise SystemExit(1)
seal = [record[2] for record in sorted(seal_records, key=lambda item: item[:2])]
for path, lines in ((tuple_path, target), (seal_path, seal)):
    with open(path, "w", encoding="utf-8") as output:
        for line in lines:
            output.write(line + "\n")
PY
}

rr_firewall_capture_hop_transaction() {
    local directory="$1" label="$2" main_port="$3" spec_list="$4"
    local backend="" seen=false
    case "$label" in HY2|TU5) ;; *) return 1 ;; esac
    is_valid_port "$main_port" && is_valid_hop_spec "$spec_list" && \
        [ -n "$spec_list" ] || return 1
    printf '%s\n' "$label" > "$directory/hop.label" || return 1
    printf '%s\n' "$main_port" > "$directory/hop.main-port" || return 1
    printf '%s\n' "$spec_list" > "$directory/hop.spec-list" || return 1
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        rr_firewall_capture_hop_backend_state "$directory" "$backend" \
            "$label" "$main_port" "$spec_list" || return 1
        : > "$directory/${backend}.nat.enabled" || return 1
        seen=true
    done
    [ "$seen" = true ] || return 1
    chmod 600 "$directory"/* 2>/dev/null || return 1
}

rr_firewall_hop_transaction_seals_match() {
    local snapshot="$1" current="$2" backend=""
    cmp -s "$snapshot/hop.label" "$current/hop.label" || return 1
    cmp -s "$snapshot/hop.main-port" "$current/hop.main-port" || return 1
    cmp -s "$snapshot/hop.spec-list" "$current/hop.spec-list" || return 1
    for backend in iptables ip6tables; do
        if [ -f "$snapshot/${backend}.nat.enabled" ] || \
           [ -f "$current/${backend}.nat.enabled" ]; then
            [ -f "$snapshot/${backend}.nat.enabled" ] && \
                [ -f "$current/${backend}.nat.enabled" ] || return 1
            cmp -s "$snapshot/${backend}.nat.seal" \
                "$current/${backend}.nat.seal" || return 1
        fi
    done
}

rr_firewall_hop_transaction_exact_match() {
    local snapshot="$1" current="$2" backend=""
    rr_firewall_hop_transaction_seals_match "$snapshot" "$current" || return 1
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.nat.enabled" ] || continue
        cmp -s "$snapshot/${backend}.nat.tuple" \
            "$current/${backend}.nat.tuple" || return 1
    done
}

rr_firewall_hop_transaction_matches_specs() {
    local snapshot="$1" desired_spec_list="$2" backend=""
    local tuple_file=""
    for backend in iptables ip6tables; do
        [ -f "$snapshot/${backend}.nat.enabled" ] || continue
        tuple_file="$snapshot/${backend}.nat.tuple"
        [ -f "$tuple_file" ] && [ ! -L "$tuple_file" ] || return 1
        python3 - "$tuple_file" "$desired_spec_list" <<'PY' || return 1
import shlex
import sys

path, desired_text = sys.argv[1:]
desired = set(filter(None, desired_text.split(",")))
seen = set()
with open(path, encoding="utf-8") as source:
    for raw_line in source:
        try:
            _position, line = raw_line.rstrip("\n").split("\t", 1)
            tokens = shlex.split(line)
            index = tokens.index("--dport")
            spec = tokens[index + 1]
        except (ValueError, IndexError):
            raise SystemExit(1)
        if spec not in desired:
            raise SystemExit(1)
        seen.add(spec)
if seen != desired:
    raise SystemExit(1)
PY
    done
}

rr_firewall_run_netfilter_saved_hop() {
    local backend="$1" operation="$2" line="$3" position="${4:-}"
    local label="$5" main_port="$6" spec_list="$7" token=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    while IFS= read -r -d '' token; do
        arguments+=("$token")
    done < <(python3 - "$line" "$label" "$main_port" "$spec_list" <<'PY'
import re
import shlex
import sys

line, label, main_port, spec_list = sys.argv[1:]
if (re.fullmatch(r"[A-Z0-9_-]{1,32}", label) is None
        or re.fullmatch(r"[1-9][0-9]{0,4}", main_port) is None
        or int(main_port) > 65535):
    raise SystemExit(1)
specs = set(spec_list.split(","))
if (not specs or any(re.fullmatch(r"[1-9][0-9]{0,4}(?::[1-9][0-9]{0,4})?", item) is None
                     for item in specs)):
    raise SystemExit(1)
for item in specs:
    values = [int(value) for value in item.split(":")]
    if (any(value < 1000 or value > 65535 for value in values)
            or (len(values) == 2 and values[0] >= values[1])):
        raise SystemExit(1)
try:
    tokens = shlex.split(line)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 10 or tokens[0:2] != ["-A", "PREROUTING"] or "!" in tokens:
    raise SystemExit(1)


def option(*names):
    indexes = [index for index, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None
    return tokens[indexes[0] + 1]


protocol = option("-p", "--protocol")
dport = option("--dport")
jump = option("-j", "--jump")
comment_indexes = [index for index, token in enumerate(tokens) if token == "--comment"]
if (protocol != "udp" or dport not in specs or jump not in {"REDIRECT", "DNAT"}
        or sum(token in {"-p", "--protocol"} for token in tokens) != 1
        or tokens.count("--dport") != 1
        or sum(token in {"-j", "--jump"} for token in tokens) != 1
        or len(comment_indexes) > 1):
    raise SystemExit(1)
if comment_indexes:
    index = comment_indexes[0]
    if index + 1 >= len(tokens) or tokens[index + 1] != f"argo-rr-{label}":
        raise SystemExit(1)
to_ports = option("--to-ports")
to_destination = option("--to-destination")
if ((jump == "REDIRECT" and (to_ports != main_port or to_destination is not None))
        or (jump == "DNAT" and (to_destination != f":{main_port}" or to_ports is not None))):
    raise SystemExit(1)
index = 2
modules = []
while index < len(tokens):
    token = tokens[index]
    if token in {"-p", "--protocol", "--dport", "--comment", "-j", "--jump",
                 "--to-ports", "--to-destination"}:
        if index + 1 >= len(tokens):
            raise SystemExit(1)
        index += 2
    elif token == "-m" and index + 1 < len(tokens):
        modules.append(tokens[index + 1])
        index += 2
    else:
        raise SystemExit(1)
if (any(module not in {"udp", "comment"} for module in modules)
        or modules.count("udp") > 1 or modules.count("comment") > 1
        or (bool(comment_indexes) != (modules.count("comment") == 1))):
    raise SystemExit(1)
for token in tokens:
    sys.stdout.buffer.write(token.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -ge 10 ] || return 1
    case "$backend" in iptables|ip6tables) ;; *) return 1 ;; esac
    case "$operation" in
        -D) arguments[0]=-D ;;
        -I)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            arguments=(-I PREROUTING "$position" "${arguments[@]:2}")
            ;;
        *) return 1 ;;
    esac
    "$backend" -w 5 -t nat "${arguments[@]}" >/dev/null 2>&1
}

rr_firewall_restore_hop_backend_state() {
    local snapshot="$1" backend="$2" label="$3" main_port="$4"
    local spec_list="$5" current="" position="" line=""
    [ -f "$snapshot/${backend}.nat.enabled" ] || return 0
    current=$(mktemp -d /tmp/rr-firewall-hop-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_hop_backend_state "$current" "$backend" "$label" \
        "$main_port" "$spec_list" || \
       ! cmp -s "$snapshot/${backend}.nat.seal" \
            "$current/${backend}.nat.seal"; then
        rm -rf "$current"
        return 1
    fi
    if cmp -s "$snapshot/${backend}.nat.tuple" \
        "$current/${backend}.nat.tuple"; then
        rm -rf "$current"
        return 0
    fi
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_netfilter_saved_hop "$backend" -D "$line" "" \
            "$label" "$main_port" "$spec_list" || \
            { rm -rf "$current"; return 1; }
    done < "$current/${backend}.nat.tuple"
    while IFS=$'\t' read -r position line; do
        [ -n "$line" ] || continue
        rr_firewall_run_netfilter_saved_hop "$backend" -I "$line" "$position" \
            "$label" "$main_port" "$spec_list" || \
            { rm -rf "$current"; return 1; }
    done < "$snapshot/${backend}.nat.tuple"
    rm -rf "$current"
    current=$(mktemp -d /tmp/rr-firewall-hop-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_hop_backend_state "$current" "$backend" "$label" \
        "$main_port" "$spec_list" || \
       ! cmp -s "$snapshot/${backend}.nat.seal" \
            "$current/${backend}.nat.seal" || \
       ! cmp -s "$snapshot/${backend}.nat.tuple" \
            "$current/${backend}.nat.tuple"; then
        rm -rf "$current"
        return 1
    fi
    rm -rf "$current"
}

rr_firewall_restore_hop_transaction() {
    local result=0
    rr_firewall_lock_acquire || return 1
    rr_firewall_restore_hop_transaction_locked "$@" || result=$?
    rr_firewall_lock_release || return 1
    return "$result"
}

rr_firewall_restore_hop_transaction_locked() {
    local snapshot="$1" label="$2" main_port="$3" spec_list="$4"
    local current="" failed=false
    rr_firewall_restore_hop_backend_state "$snapshot" ip6tables "$label" \
        "$main_port" "$spec_list" || failed=true
    rr_firewall_restore_hop_backend_state "$snapshot" iptables "$label" \
        "$main_port" "$spec_list" || failed=true
    [ "$failed" = false ] || return 1
    current=$(mktemp -d /tmp/rr-firewall-hop-compensate.XXXXXX) || return 1
    if ! rr_firewall_capture_hop_transaction "$current" "$label" "$main_port" \
        "$spec_list" || \
       ! rr_firewall_hop_transaction_exact_match "$snapshot" "$current"; then
        rm -rf "$current"
        return 1
    fi
    rm -rf "$current"
}

rr_firewall_batch_is_active() {
    rr_firewall_lock_is_held && \
        [ "${RR_FIREWALL_BATCH_ACTIVE:-0}" = 1 ] && \
        [ "${RR_FIREWALL_BATCH_OWNER_PID:-}" = "$BASHPID" ] && \
        [ -n "${RR_FIREWALL_BATCH_ROOT:-}" ] && \
        [ -d "$RR_FIREWALL_BATCH_ROOT" ] && [ ! -L "$RR_FIREWALL_BATCH_ROOT" ] && \
        [ "$(stat -c '%u:%a' "$RR_FIREWALL_BATCH_ROOT" 2>/dev/null)" = "${EUID}:700" ]
}

rr_firewall_batch_begin() {
    [ "${RR_FIREWALL_BATCH_ACTIVE:-0}" = 0 ] || return 1
    rr_firewall_lock_acquire || return 1
    RR_FIREWALL_BATCH_ROOT=$(mktemp -d /tmp/rr-firewall-batch.XXXXXX) || {
        rr_firewall_lock_release || true
        return 1
    }
    chmod 700 "$RR_FIREWALL_BATCH_ROOT" || {
        rm -rf "$RR_FIREWALL_BATCH_ROOT"
        RR_FIREWALL_BATCH_ROOT=""
        rr_firewall_lock_release || true
        return 1
    }
    RR_FIREWALL_BATCH_ACTIVE=1
    RR_FIREWALL_BATCH_OWNER_PID="$BASHPID"
    RR_FIREWALL_BATCH_NEEDS_PERSIST=false
    declare -ga RR_FIREWALL_BATCH_SNAPSHOTS=()
    declare -ga RR_FIREWALL_BATCH_KINDS=()
    declare -ga RR_FIREWALL_BATCH_ARG1=()
    declare -ga RR_FIREWALL_BATCH_ARG2=()
    declare -ga RR_FIREWALL_BATCH_ARG3=()
}

rr_firewall_batch_record_protocol() {
    local snapshot="$1" proto_port="$2" proto_type="$3" mode="$4"
    rr_firewall_batch_is_active || return 1
    [ "$(dirname -- "$snapshot")" = "$RR_FIREWALL_BATCH_ROOT" ] && \
        [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    RR_FIREWALL_BATCH_SNAPSHOTS+=("$snapshot")
    RR_FIREWALL_BATCH_KINDS+=(protocol)
    RR_FIREWALL_BATCH_ARG1+=("$proto_port")
    RR_FIREWALL_BATCH_ARG2+=("$proto_type")
    RR_FIREWALL_BATCH_ARG3+=("$mode")
    if [ "$mode" = dual ] || [ "$mode" = netfilter ]; then
        RR_FIREWALL_BATCH_NEEDS_PERSIST=true
    fi
}

rr_firewall_batch_record_hop() {
    local snapshot="$1" label="$2" main_port="$3" spec_list="$4"
    rr_firewall_batch_is_active || return 1
    [ "$(dirname -- "$snapshot")" = "$RR_FIREWALL_BATCH_ROOT" ] && \
        [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    RR_FIREWALL_BATCH_SNAPSHOTS+=("$snapshot")
    RR_FIREWALL_BATCH_KINDS+=(hop)
    RR_FIREWALL_BATCH_ARG1+=("$label")
    RR_FIREWALL_BATCH_ARG2+=("$main_port")
    RR_FIREWALL_BATCH_ARG3+=("$spec_list")
    RR_FIREWALL_BATCH_NEEDS_PERSIST=true
}

rr_firewall_batch_rollback_operations() {
    local index=0 failed=false
    rr_firewall_batch_is_active || return 1
    for ((index=${#RR_FIREWALL_BATCH_SNAPSHOTS[@]} - 1; index >= 0; index--)); do
        case "${RR_FIREWALL_BATCH_KINDS[index]}" in
            protocol)
                rr_firewall_restore_protocol_transaction \
                    "${RR_FIREWALL_BATCH_SNAPSHOTS[index]}" \
                    "${RR_FIREWALL_BATCH_ARG1[index]}" \
                    "${RR_FIREWALL_BATCH_ARG2[index]}" \
                    "${RR_FIREWALL_BATCH_ARG3[index]}" || failed=true
                ;;
            hop)
                rr_firewall_restore_hop_transaction \
                    "${RR_FIREWALL_BATCH_SNAPSHOTS[index]}" \
                    "${RR_FIREWALL_BATCH_ARG1[index]}" \
                    "${RR_FIREWALL_BATCH_ARG2[index]}" \
                    "${RR_FIREWALL_BATCH_ARG3[index]}" || failed=true
                ;;
            *) failed=true ;;
        esac
    done
    [ "$failed" = false ]
}

rr_firewall_batch_cleanup() {
    local root="${RR_FIREWALL_BATCH_ROOT:-}" failed=false
    rr_firewall_batch_is_active || return 1
    if [ -n "$root" ] && [[ "$root" = /tmp/rr-firewall-batch.* ]] && \
       [ -d "$root" ] && [ ! -L "$root" ]; then
        rm -rf -- "$root" || failed=true
    else
        failed=true
    fi
    RR_FIREWALL_BATCH_ACTIVE=0
    RR_FIREWALL_BATCH_OWNER_PID=""
    RR_FIREWALL_BATCH_ROOT=""
    RR_FIREWALL_BATCH_NEEDS_PERSIST=false
    RR_FIREWALL_BATCH_SNAPSHOTS=()
    RR_FIREWALL_BATCH_KINDS=()
    RR_FIREWALL_BATCH_ARG1=()
    RR_FIREWALL_BATCH_ARG2=()
    RR_FIREWALL_BATCH_ARG3=()
    rr_firewall_lock_release || failed=true
    [ "$failed" = false ]
}

rr_firewall_batch_abort() {
    local failed=false finish_status=0
    if ! rr_firewall_batch_rollback_operations; then
        failed=true
        printf '防火墙批事务补偿失败；请立即人工核对 IPv4、IPv6、UFW 的 live 与持久规则。\n' >&2
    fi
    if rr_firewall_inflight_is_owned; then
        if [ "$failed" = false ] && \
           [ "${RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH:-0}" != 1 ]; then
            rr_firewall_inflight_finish_locked || finish_status=$?
            [ "$finish_status" -eq 0 ] || failed=true
        elif [ "$failed" = true ]; then
            rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        fi
    fi
    rr_firewall_batch_cleanup || failed=true
    [ "$failed" = false ]
}

rr_firewall_batch_commit() {
    local needs_persist="${RR_FIREWALL_BATCH_NEEDS_PERSIST:-false}"
    local cleanup_status=0 finish_status=0
    rr_firewall_batch_is_active || return 1
    if [ "$needs_persist" = true ] && ! save_firewall; then
        if ! rr_firewall_batch_rollback_operations; then
            printf '防火墙批事务首次持久化失败，且 live 原态恢复失败；请立即人工检查。\n' >&2
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_batch_cleanup || cleanup_status=$?
            [ "$cleanup_status" -eq 0 ] || printf '%s\n' \
                '防火墙批事务补偿失败后，证据清理或锁释放也失败。' >&2
            return 11
        fi
        if ! save_firewall; then
            printf '防火墙批事务原态二次持久化失败；live 已恢复，但请立即人工检查持久规则。\n' >&2
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            cleanup_status=0
            rr_firewall_batch_cleanup || cleanup_status=$?
            [ "$cleanup_status" -eq 0 ] || printf '%s\n' \
                '防火墙原态持久化失败后，证据清理或锁释放也失败。' >&2
            return 12
        fi
        printf '防火墙批事务持久化失败；live 与持久规则已补偿回原态。\n' >&2
        if [ "${RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH:-0}" = 1 ]; then
            return 10
        fi
        if [ "${RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH:-0}" != 1 ] && \
           rr_firewall_inflight_is_owned; then
            rr_firewall_inflight_finish_locked || finish_status=$?
        fi
        cleanup_status=0
        rr_firewall_batch_cleanup || cleanup_status=$?
        if [ "$finish_status" -ne 0 ] || [ "$cleanup_status" -ne 0 ]; then
            printf '%s\n' \
                '防火墙已恢复并持久化原态，但 in-flight 证据、服务状态或锁完整性失败。' >&2
            return 13
        fi
        return 10
    fi
    if [ "${RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH:-0}" = 1 ]; then
        return 0
    fi
    if [ "${RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH:-0}" != 1 ] && \
       rr_firewall_inflight_is_owned; then
        rr_firewall_inflight_finish_locked || finish_status=$?
    fi
    if [ "$finish_status" -ne 0 ]; then
        rr_firewall_inflight_is_owned && \
            rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
        rr_firewall_batch_cleanup >/dev/null 2>&1 || true
        printf '%s\n' \
            '防火墙已验证并持久化，但 in-flight 隔离证据无法安全清除或服务原态无法恢复。' >&2
        return 13
    fi
    if ! rr_firewall_batch_cleanup; then
        # Persistence already succeeded.  At this point compensation would
        # create a split-brain with callers that have committed matching
        # configuration, so keep the committed side authoritative.  A failed
        # evidence cleanup or lock release is nevertheless an indeterminate
        # process-wide safety boundary: never report it as an ordinary
        # successful commit to a caller that may leave active nodes running.
        printf '%s\n' \
            '防火墙已持久化提交，但临时证据清理或锁完整性检查失败；新规则保持生效，请人工检查 /tmp/rr-firewall-batch.*。' >&2
        return 13
    fi
    return 0
}

rr_netfilter_rr_namespace_is_empty() {
    local backend="" state=0 rules="" parse_state=0 readable_seen=false
    local supported_seen=false
    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                readable_seen=true
                rules=$("$backend" -w 5 -t filter -S 2>/dev/null) || return 2
                if printf '%s\n' "$rules" | \
                    python3 -c '
import re
import shlex
import sys

managed = {
    sys.argv[1]: "ACCEPT",
    sys.argv[2]: "DROP",
}
supported_seen = False
for raw in sys.stdin:
    try:
        tokens = shlex.split(raw)
    except ValueError:
        raise SystemExit(2)
    indexes = [index for index, token in enumerate(tokens)
               if token == "--comment"]
    comments = []
    for index in indexes:
        if index + 1 >= len(tokens):
            continue
        comments.append(tokens[index + 1])
    owned = [comment for comment in comments if comment in managed]
    if not owned:
        continue
    if (len(owned) != 1 or len(indexes) != 1 or len(tokens) < 3
            or tokens[0] != "-A" or tokens[1] != "INPUT" or "!" in tokens
            or any(item in tokens for item in ("-g", "--goto"))):
        raise SystemExit(2)

    values = {}
    modules = []
    index = 2
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "--comment", "-j", "--jump"}:
            if index + 1 >= len(tokens) or token in values:
                raise SystemExit(2)
            values[token] = tokens[index + 1]
            index += 2
            continue
        if token == "-m":
            if index + 1 >= len(tokens):
                raise SystemExit(2)
            modules.append(tokens[index + 1])
            index += 2
            continue
        raise SystemExit(2)

    protocol_names = [name for name in ("-p", "--protocol") if name in values]
    jump_names = [name for name in ("-j", "--jump") if name in values]
    if len(protocol_names) != 1 or len(jump_names) != 1:
        raise SystemExit(2)
    protocol = values[protocol_names[0]]
    comment = values.get("--comment")
    port_text = values.get("--dport", "")
    target = values[jump_names[0]]
    if (protocol not in {"tcp", "udp"}
            or re.fullmatch(r"[1-9][0-9]{0,4}", port_text) is None
            or int(port_text) > 65535 or comment not in managed
            or target != managed[comment]
            or modules.count("comment") != 1
            or any(module not in {"comment", protocol} for module in modules)
            or modules.count(protocol) > 1
            or len(modules) not in {1, 2}):
        raise SystemExit(2)
    supported_seen = True
raise SystemExit(1 if supported_seen else 0)
' "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT"; then
                    parse_state=0
                else
                    parse_state=$?
                fi
                case "$parse_state" in
                    0) ;;
                    1) supported_seen=true ;;
                    *) return 2 ;;
                esac
                ;;
            1) ;;
            *) return 2 ;;
        esac
    done
    [ "$readable_seen" = true ] || return 2
    [ "$supported_seen" = false ] || return 1
    return 0
}

rr_filter_family_backends_are_complete() {
    local state=0
    if rr_netfilter_backend_state iptables; then state=0; else state=$?; fi
    [ "$state" -eq 0 ] || return 1
    if rr_netfilter_backend_state ip6tables; then state=0; else state=$?; fi
    case "$state" in
        0) return 0 ;;
        1) rr_ipv6_stack_is_disabled ;;
        *) return 1 ;;
    esac
}

rr_firewall_filter_authority_mode() {
    local output_name="$1" ufw_state=0 namespace_state=0 resolved=""
    case "${RR_PORTABLE_UFW_AUTHORITY:-0}" in
        0) ;;
        1)
            [ "${RR_PORTABLE_RESTORE:-0}" = 1 ] && \
                [ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ] || return 1
            ;;
        *) return 1 ;;
    esac
    rr_filter_family_backends_are_complete || return 1
    if rr_ufw_backend_state; then
        ufw_state=0
    else
        ufw_state=$?
    fi
    case "$ufw_state" in
        0) ;;
        1)
            [ "${RR_PORTABLE_UFW_AUTHORITY:-0}" != 1 ] || return 1
            # Reporting firewall success with no writable/readable backend is
            # a fail-open. The namespace probe also rejects installed but
            # unreadable backends and an entirely absent raw firewall plane.
            rr_netfilter_rr_namespace_is_empty || {
                [ "$?" -eq 1 ] || return 1
            }
            resolved=netfilter
            printf -v "$output_name" '%s' "$resolved"
            return 0
            ;;
        *) return 1 ;;
    esac
    if rr_netfilter_rr_namespace_is_empty; then
        namespace_state=0
    else
        namespace_state=$?
    fi
    case "$namespace_state" in
        0) resolved=ufw ;;
        1)
            [ "${RR_PORTABLE_UFW_AUTHORITY:-0}" != 1 ] || return 1
            resolved=dual
            ;;
        *) return 1 ;;
    esac
    printf -v "$output_name" '%s' "$resolved"
}

rr_ufw_protocol_policy_is_reachable() {
    local proto_port="$1" proto_type="$2" desired="$3" filter_mode="${4:-ufw}"
    local proof_phase="${5:-current}"
    local directory="" added="" status_file="" raw="" backend="" user_chain="" state=0
    local chain_state=0 family_required=false family_mode=ufw ipv6_required=false
    local v4_proved=false v6_proved=false failed=false
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    case "$desired" in open|closed) ;; *) return 1 ;; esac
    case "$filter_mode" in ufw|dual) ;; *) return 1 ;; esac
    case "$proof_phase" in current|future) ;; *) return 1 ;; esac
    directory=$(mktemp -d /tmp/rr-ufw-proof.XXXXXX) || return 1
    added="$directory/added"
    status_file="$directory/status"
    if ! LC_ALL=C ufw status > "$status_file" 2>/dev/null || \
       ! grep -qE '^Status:[[:space:]]+active([[:space:]]|$)' "$status_file" || \
       ! LC_ALL=C ufw show added > "$added" 2>/dev/null; then
        rm -rf "$directory"
        return 1
    fi
    if grep -qE '^[^[:space:]]+[[:space:]]+\(v6\)[[:space:]]' "$status_file"; then
        ipv6_required=true
    fi
    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                raw="$directory/${backend}.filter"
                "$backend" -w 5 -t filter -S > "$raw" 2>/dev/null || {
                    failed=true
                    continue
                }
                case "$backend" in
                    iptables)
                        user_chain=ufw-user-input
                        family_required=true
                        family_mode=ufw
                        ;;
                    ip6tables)
                        user_chain=ufw6-user-input
                        family_required=true
                        family_mode=ufw
                        if python3 - "$raw" "$user_chain" <<'PY'
import shlex
import sys

path, wanted = sys.argv[1:]
for raw_line in open(path, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(2)
    if ((len(tokens) == 2 and tokens[0] == "-N" and tokens[1] == wanted)
            or (len(tokens) >= 3 and tokens[0] == "-A" and tokens[1] == wanted)):
        raise SystemExit(0)
raise SystemExit(1)
PY
                        then
                            family_required=true
                            ipv6_required=true
                        else
                            chain_state=$?
                            if [ "$chain_state" -ne 1 ]; then
                                failed=true
                                continue
                            fi
                            if [ "$ipv6_required" = false ]; then
                                if [ "$filter_mode" = dual ]; then
                                    family_mode=dual-raw
                                else
                                    family_mode=raw-effective
                                fi
                            fi
                        fi
                        ;;
                    *) failed=true; continue ;;
                esac
                [ "$family_required" = true ] || continue
                if python3 - "$raw" "$added" "$proto_port" "$proto_type" \
                    "$desired" "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" \
                    "$user_chain" "$family_mode" "$proof_phase" <<'PY'
import re
import shlex
import sys

raw_path, added_path, port_text, protocol, desired, allow_comment, block_comment, user_chain, family_mode, proof_phase = sys.argv[1:]
if family_mode not in {"ufw", "dual-raw", "raw-effective"}:
    raise SystemExit(1)
if proof_phase not in {"current", "future"}:
    raise SystemExit(1)
port = int(port_text)
desired_target = "ACCEPT" if desired == "open" else "DROP"
managed_comments = {allow_comment, block_comment}
managed_ufw = {}

for raw_line in open(added_path, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if not tokens or tokens[0] != "ufw":
        continue
    try:
        comment = tokens[tokens.index("comment") + 1]
    except (ValueError, IndexError):
        comment = None
    simple = (
        len(tokens) == 5
        and tokens[1] in {"allow", "deny"}
        and tokens[3] == "comment"
        and re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is not None
        and int(tokens[2].split("/", 1)[0]) <= 65535
    )
    if not simple:
        # A route/range/catch-all high-level rule may shadow this key and is
        # not safely attributable from the compact status output.
        raise SystemExit(1)
    item_port, item_proto = tokens[2].split("/", 1)
    key = (int(item_port), item_proto)
    if key != (port, protocol):
        continue
    expected_comment = allow_comment if tokens[1] == "allow" else block_comment
    if comment != expected_comment:
        raise SystemExit(1)
    target = "ACCEPT" if tokens[1] == "allow" else "DROP"
    if key in managed_ufw:
        raise SystemExit(1)
    managed_ufw[key] = target


def option(tokens, *names):
    for index, token in enumerate(tokens):
        if token not in names:
            continue
        if index + 1 >= len(tokens):
            return None, True, False
        return tokens[index + 1], False, index > 0 and tokens[index - 1] == "!"
    return "", False, False


def matches(tokens):
    interface, bad, negated = option(tokens, "-i", "--in-interface")
    if not bad and not negated and interface == "lo":
        return False
    destination_type, bad, negated = option(tokens, "--dst-type")
    if not bad and destination_type:
        local = destination_type.upper() == "LOCAL"
        if (local and negated) or (not local and not negated):
            return False
    state, bad, negated = option(tokens, "--ctstate", "--state")
    if not bad and not negated and state:
        if "NEW" not in {item.upper() for item in state.split(",")}:
            return False
    rule_proto, bad, negated = option(tokens, "-p", "--protocol")
    if not bad and not negated and rule_proto and rule_proto not in {"all", "0", protocol}:
        return False
    spec, bad, negated = option(tokens, "--dport", "--dports")
    if bad or negated or not spec:
        return True
    for part in spec.split(","):
        if re.fullmatch(r"[0-9]+", part):
            low = high = int(part)
        else:
            match = re.fullmatch(r"([0-9]+)[:-]([0-9]+)", part)
            if match is None:
                return True
            low, high = map(int, match.groups())
        if low <= port <= high:
            return True
    return False


def covers_candidate(tokens):
    # The proof is over every NEW, locally-destined packet for one fixed
    # protocol/port key.  A source, non-loopback interface, destination,
    # negation, unknown extension or other conditional matcher covers only a
    # subset of that class.  Treating such a branch as universal would let the
    # remaining packets bypass the UFW user chain.
    if "!" in tokens:
        return False
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
                covered = False
                for part in value.split(","):
                    if re.fullmatch(r"[0-9]+", part):
                        low = high = int(part)
                    else:
                        match = re.fullmatch(r"([0-9]+)[:-]([0-9]+)", part)
                        if match is None:
                            return False
                        low, high = map(int, match.groups())
                    if low <= port <= high:
                        covered = True
                if not covered:
                    return False
            if token in {"--ctstate", "--state"} and \
                    "NEW" not in {item.upper() for item in value.split(",")}:
                return False
            if token == "--dst-type" and value.upper() != "LOCAL":
                return False
            index += 2
            continue
        # In particular, -s/-d/-i(non-lo)/-o and every unmodelled matcher are
        # subset conditions, not evidence that all candidate packets follow
        # this control-flow edge.
        return False
    return True


def target_of(tokens):
    goto, bad_goto, negated_goto = option(tokens, "-g", "--goto")
    if bad_goto or negated_goto or goto:
        raise SystemExit(1)
    target, bad, negated = option(tokens, "-j", "--jump")
    if bad or negated or not target:
        raise SystemExit(1)
    return target


def comment_of(tokens):
    comment, bad, negated = option(tokens, "--comment")
    return None if bad or negated else (comment or None)


def compiled_managed_target(tokens, target):
    if tokens[1] != user_chain or "!" in tokens:
        return None
    if (sum(token in {"-p", "--protocol"} for token in tokens) != 1
            or tokens.count("--dport") != 1
            or sum(token in {"-j", "--jump"} for token in tokens) != 1
            or tokens.count("-m") > 1):
        return None
    rule_proto, bad_proto, negated_proto = option(tokens, "-p", "--protocol")
    spec, bad_port, negated_port = option(tokens, "--dport")
    if (bad_proto or negated_proto or bad_port or negated_port
            or rule_proto != protocol or spec != port_text):
        return None
    index = 2
    while index < len(tokens):
        token = tokens[index]
        if token in {"-p", "--protocol", "--dport", "-j", "--jump"}:
            index += 2
        elif token == "-m" and index + 1 < len(tokens) and tokens[index + 1] == protocol:
            index += 2
        else:
            return None
    return target if managed_ufw.get((port, protocol)) == target else None


chains = {}
policies = {}
for raw_line in open(raw_path, encoding="utf-8"):
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
if "INPUT" not in chains or policies.get("INPUT") not in {"ACCEPT", "DROP"}:
    raise SystemExit(1)


def walk(chain, stack):
    if chain in stack or len(stack) > 64 or chain not in chains:
        raise SystemExit(1)
    for tokens in chains[chain]:
        if not matches(tokens):
            continue
        target = target_of(tokens)
        if target in {"LOG", "NFLOG", "TRACE"}:
            continue
        if chain == "INPUT" and comment_of(tokens) in managed_comments:
            # Legacy dual-written RR INPUT rules are ignored only while proving
            # the underlying UFW path; unmanaged first-match rules are not.
            continue
        compiled = compiled_managed_target(tokens, target)
        if compiled is not None:
            if proof_phase == "current" and compiled == desired_target:
                return "reached"
            # The reconciler removes an exact opposite RR-owned UFW tuple
            # before appending the desired tuple, so continue the proof as if
            # that removable rule were absent.
            continue
        if not covers_candidate(tokens):
            raise SystemExit(1)
        if target == "RETURN":
            if chain in {"INPUT", user_chain}:
                raise SystemExit(1)
            return "returned"
        if target == user_chain:
            return walk(target, stack + (chain,))
        if target in chains:
            outcome = walk(target, stack + (chain,))
            if outcome == "reached":
                return outcome
            continue
        raise SystemExit(1)
    if chain == user_chain:
        # Falling through the existing user chain means the candidate UFW rule
        # can be appended in a future-state proof.  A current-state validator
        # must observe the exact compiled desired terminal rule instead.
        return "reached" if proof_phase == "future" else "missing"
    if chain == "INPUT":
        return "missing"
    return "returned"


if family_mode == "ufw":
    raise SystemExit(0 if walk("INPUT", ()) == "reached" else 1)

# UFW with IPv6 disabled can leave a readable IPv6 filter plane without the
# ufw6 user chain.  Never pretend that the IPv4 proof covers it: either legacy
# dual mode will reconcile an exact raw RR rule, or the existing raw policy
# must already implement the requested action for the whole candidate class.
for tokens in chains["INPUT"]:
    if not matches(tokens):
        continue
    target = target_of(tokens)
    if target in {"LOG", "NFLOG", "TRACE"}:
        continue
    if comment_of(tokens) in managed_comments and family_mode == "dual-raw":
        continue
    raise SystemExit(1)
if family_mode == "raw-effective" and policies["INPUT"] != desired_target:
    raise SystemExit(1)
raise SystemExit(0)
PY
                then
                    case "$backend" in
                        iptables) v4_proved=true ;;
                        ip6tables) v6_proved=true ;;
                    esac
                else
                    failed=true
                fi
                ;;
            1)
                if [ "$backend" = iptables ] || \
                   { [ "$backend" = ip6tables ] && \
                     { [ "$ipv6_required" = true ] || ! rr_ipv6_stack_is_disabled; }; }; then
                    failed=true
                fi
                ;;
            *) failed=true ;;
        esac
    done
    [ "$v4_proved" = true ] || failed=true
    [ "$ipv6_required" = false ] || [ "$v6_proved" = true ] || failed=true
    rm -rf "$directory"
    [ "$failed" = false ]
}

rr_inactive_ufw_protocol_is_disjoint() {
    local proto_port="$1" proto_type="$2" state=0 evidence=""
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    command -v ufw >/dev/null 2>&1 || return 0
    if rr_ufw_backend_state; then
        return 0
    else
        state=$?
    fi
    [ "$state" -eq 1 ] || return 1
    evidence=$(mktemp /tmp/rr-ufw-inactive.XXXXXX) || return 1
    if ! LC_ALL=C ufw show added > "$evidence" 2>/dev/null || \
       ! python3 - "$evidence" "${proto_port}/${proto_type}" <<'PY'
import re
import shlex
import sys

path, wanted = sys.argv[1:]
header = "Added user rules (see 'ufw status' for running firewall):"
for raw_line in open(path, encoding="utf-8"):
    line = raw_line.strip()
    if not line or line == header:
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
            or tokens[2] == wanted):
        raise SystemExit(1)
PY
    then
        rm -f "$evidence"
        return 1
    fi
    rm -f "$evidence"
}

rr_netfilter_protocol_is_uncontested() {
    local backend="$1" proto_port="$2" proto_type="$3" raw=""
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    raw=$(mktemp /tmp/rr-netfilter-proof.XXXXXX) || return 1
    if ! "$backend" -w 5 -t filter -S > "$raw" 2>/dev/null || \
       ! python3 - "$raw" "$proto_port" "$proto_type" \
            "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" <<'PY'
import re
import shlex
import sys

path, port_text, protocol, allow_comment, block_comment = sys.argv[1:]
port = int(port_text)
managed = {allow_comment: "ACCEPT", block_comment: "DROP"}
safe_targets = {"LOG", "NFLOG", "TRACE"}


def option(tokens, *names):
    for index, token in enumerate(tokens):
        if token not in names:
            continue
        if index + 1 >= len(tokens):
            return None, True, False
        return tokens[index + 1], False, index > 0 and tokens[index - 1] == "!"
    return "", False, False


def overlaps(tokens):
    interface, bad, negated = option(tokens, "-i", "--in-interface")
    if not bad and not negated and interface == "lo":
        return False
    destination_type, bad, negated = option(tokens, "--dst-type")
    if not bad and destination_type:
        local = destination_type.upper() == "LOCAL"
        if (local and negated) or (not local and not negated):
            return False
    state, bad, negated = option(tokens, "--ctstate", "--state")
    if not bad and not negated and state and \
            "NEW" not in {item.upper() for item in state.split(",")}:
        return False
    rule_proto, bad, negated = option(tokens, "-p", "--protocol")
    if not bad and not negated and rule_proto and \
            rule_proto not in {"all", "0", protocol}:
        return False
    spec, bad, negated = option(tokens, "--dport", "--dports")
    if bad or negated or not spec:
        return True
    for part in spec.split(","):
        if re.fullmatch(r"[0-9]+", part):
            low = high = int(part)
        else:
            match = re.fullmatch(r"([0-9]+)[:-]([0-9]+)", part)
            if match is None:
                return True
            low, high = map(int, match.groups())
        if low <= port <= high:
            return True
    return False


def target_of(tokens):
    goto, bad, negated = option(tokens, "-g", "--goto")
    if bad or negated or goto:
        raise SystemExit(1)
    target, bad, negated = option(tokens, "-j", "--jump")
    if bad or negated or not target:
        raise SystemExit(1)
    return target


def supported_managed(tokens, comment, target):
    if (tokens[1] != "INPUT" or "!" in tokens
            or target != managed.get(comment)
            or sum(item in {"-p", "--protocol"} for item in tokens) != 1
            or tokens.count("--dport") != 1
            or tokens.count("--comment") != 1
            or sum(item in {"-j", "--jump"} for item in tokens) != 1):
        return False
    rule_proto, bad_proto, negated_proto = option(tokens, "-p", "--protocol")
    rule_port, bad_port, negated_port = option(tokens, "--dport")
    if (bad_proto or negated_proto or bad_port or negated_port
            or rule_proto not in {"tcp", "udp"}
            or re.fullmatch(r"[1-9][0-9]{0,4}", rule_port) is None
            or int(rule_port) > 65535):
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
            and all(item in {"comment", rule_proto} for item in modules)
            and modules.count(rule_proto) <= 1 and len(modules) in {1, 2})


policy = None
input_rules = []
for raw_line in open(path, encoding="utf-8"):
    try:
        tokens = shlex.split(raw_line)
    except ValueError:
        raise SystemExit(1)
    if len(tokens) >= 3 and tokens[0] == "-P" and tokens[1] == "INPUT":
        policy = tokens[2]
    elif len(tokens) >= 3 and tokens[0] == "-A" and tokens[1] == "INPUT":
        input_rules.append(tokens)
if policy not in {"ACCEPT", "DROP"}:
    raise SystemExit(1)

for tokens in input_rules:
    if not overlaps(tokens):
        continue
    target = target_of(tokens)
    if target in safe_targets:
        continue
    comment, bad, negated = option(tokens, "--comment")
    if not bad and not negated and comment in managed:
        if supported_managed(tokens, comment, target):
            continue
    # No unmanaged rule that can match this key may be silently bypassed by
    # an RR head insert or shadow an RR tail DROP.
    raise SystemExit(1)
PY
    then
        rm -f "$raw"
        return 1
    fi
    rm -f "$raw"
}

rr_reconcile_protocol_firewall() {
    local result=0 stop_status=0 batch_active=false finish_status=0
    # A configured/menu batch may already have published its v1 crash journal
    # for an earlier tuple.  Permit only that same-owner, lock-held batch to
    # reach the locked reconciler; every actual writer still requires the
    # owned v1 gate.  An unrelated or orphan marker remains a hard refusal.
    rr_firewall_batch_is_active && batch_active=true
    if rr_firewall_fail_closed_quarantine_active && \
       [ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" != 1 ] && \
       [ "$batch_active" = false ]; then
        printf '%s\n' \
            '防火墙持久隔离尚未修复；拒绝单端口规则改写。' >&2
        return 1
    fi
    rr_firewall_lock_acquire || return 1
    rr_firewall_batch_is_active && batch_active=true
    rr_reconcile_protocol_firewall_locked "$@" || result=$?
    if [ "$batch_active" = false ] && rr_firewall_inflight_is_owned; then
        case "$result" in
            0|1)
                rr_firewall_inflight_finish_locked || finish_status=$?
                [ "$finish_status" -eq 0 ] || result=2
                ;;
            *)
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
                ;;
        esac
    fi
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '单端口防火墙事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    case "$result" in
        0|1) ;;
        *)
            rr_firewall_fail_closed_stop_nodes \
                '单端口防火墙事务无法证明完整原态' || stop_status=$?
            return "$stop_status"
            ;;
    esac
    return "$result"
}

rr_reconcile_protocol_firewall_locked() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local backend="" state=0 failed=false persist_netfilter=false mode=""
    local raw_preflight_seen=false snapshot="" current="" arm_status=0

    # A release candidate must not insert/reorder INPUT rules or persist a
    # changed ruleset before it commits.  Transaction mode is a strict
    # read-only gate; fresh installs and interactive changes still reconcile.
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        rr_validate_protocol_firewall "$proto_port" "$proto_type" "$desired"
        return $?
    fi

    # Resolve the three-state backend model before the first UFW/netfilter
    # writer.  Active UFW with an empty RR raw namespace is authoritative and
    # stays so across later menus/updates.  Existing dual-written hosts retain
    # their legacy mode until a separately rollback-safe migration is designed.
    rr_firewall_filter_authority_mode mode || {
        printf '无法证明活动防火墙后端及 RR 规则命名空间安全；未修改规则。\n' >&2
        return 1
    }
    if [ "$mode" != ufw ] && ! rr_firewall_persistence_backend_available; then
        printf '%s\n' '系统缺少受支持的 netfilter 持久化后端；未修改 RR 防火墙规则。' >&2
        return 1
    fi

    if [ "$mode" = netfilter ]; then
        rr_inactive_ufw_protocol_is_disjoint "$proto_port" "$proto_type" || {
            printf '未启用 UFW 的持久规则与 RR %s/%s 策略冲突；未修改规则。\n' \
                "$proto_type" "$proto_port" >&2
            return 1
        }
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
            case "$state" in
                0)
                    raw_preflight_seen=true
                    rr_netfilter_protocol_is_uncontested "$backend" "$proto_port" \
                        "$proto_type" || {
                        printf '%s 的用户 INPUT 策略与 RR %s/%s 冲突；未修改规则。\n' \
                            "$backend" "$proto_type" "$proto_port" >&2
                        return 1
                    }
                    ;;
                1) ;;
                *) return 1 ;;
            esac
        done
        [ "$raw_preflight_seen" = true ] || return 1
    fi

    if [ "$mode" = ufw ] || [ "$mode" = dual ]; then
        rr_ufw_protocol_policy_is_reachable "$proto_port" "$proto_type" \
            "$desired" "$mode" future || {
            printf 'UFW 的有效首匹配路径与 RR %s/%s 策略冲突；未修改规则。\n' \
                "$proto_type" "$proto_port" >&2
            return 1
        }
        rr_ufw_reload_program_is_canonical || {
            printf 'UFW 的持久规则与 live 用户链不一致；未修改规则。\n' >&2
            return 1
        }
    fi

    # This is the final read-only boundary.  It records the target tuple and
    # its positions plus a byte-exact seal of every non-target rule before the
    # first UFW/netfilter writer is allowed to run.
    if rr_firewall_batch_is_active; then
        snapshot=$(mktemp -d "$RR_FIREWALL_BATCH_ROOT/tuple.XXXXXX") || return 1
    else
        snapshot=$(mktemp -d /tmp/rr-firewall-transaction.XXXXXX) || return 1
    fi
    chmod 700 "$snapshot" || { rm -rf "$snapshot"; return 1; }
    if ! rr_firewall_capture_protocol_transaction "$snapshot" "$proto_port" \
        "$proto_type" "$mode"; then
        rm -rf "$snapshot"
        printf '无法建立 RR %s/%s 防火墙事务快照；未修改规则。\n' \
            "$proto_type" "$proto_port" >&2
        return 1
    fi

    if rr_firewall_inflight_begin_locked; then
        arm_status=0
    else
        arm_status=$?
        rm -rf "$snapshot"
        [ "$arm_status" -ge 2 ] && return 2
        return 1
    fi

    if [ "$mode" = ufw ] || [ "$mode" = dual ]; then
        if ! rr_reconcile_ufw_protocol_rule "$proto_port" "$proto_type" "$desired"; then
            printf 'UFW 未能写入或验证 RR %s/%s 规则。\n' "$proto_type" "$proto_port" >&2
            failed=true
        fi
        if [ "$failed" = false ] && \
           ! rr_ufw_protocol_policy_is_reachable "$proto_port" "$proto_type" \
                "$desired" "$mode" current; then
            printf 'UFW 写入后的有效首匹配策略校验失败。\n' >&2
            failed=true
        fi
    fi

    if [ "$failed" = false ] && \
       { [ "$mode" = dual ] || [ "$mode" = netfilter ]; }; then
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then
                state=0
            else
                state=$?
            fi
            case "$state" in
                0)
                    persist_netfilter=true
                    if ! rr_reconcile_netfilter_protocol_rule "$backend" "$proto_port" \
                        "$proto_type" "$desired"; then
                        printf '%s 未能写入或验证 RR %s/%s 规则。\n' \
                            "$backend" "$proto_type" "$proto_port" >&2
                        failed=true
                    fi
                    ;;
                1) ;;
                *)
                    printf '%s 已安装但无法读取活动 filter 后端。\n' "$backend" >&2
                    failed=true
                    ;;
            esac
            [ "$failed" = false ] || break
        done
    elif [ "$failed" = false ] && ! rr_netfilter_rr_namespace_is_empty; then
        # Recheck after the UFW writer: authority is valid only while no raw RR
        # filter rule can precede and bypass UFW policy.
        failed=true
    fi

    # No durable write is attempted until every participating backend, the
    # effective policy, and the non-target projections have all passed their
    # post-write verification.
    if [ "$failed" = false ] && \
       ! rr_validate_protocol_firewall "$proto_port" "$proto_type" "$desired"; then
        printf 'RR %s/%s 写入后的完整策略校验失败。\n' \
            "$proto_type" "$proto_port" >&2
        failed=true
    fi
    if [ "$failed" = false ]; then
        current=$(mktemp -d /tmp/rr-firewall-transaction.XXXXXX) || failed=true
        if [ "$failed" = false ] && \
           { ! rr_firewall_capture_protocol_transaction "$current" "$proto_port" \
                "$proto_type" "$mode" || \
             ! rr_firewall_protocol_transaction_seals_match "$snapshot" "$current"; }; then
            printf '防火墙变更触及了非目标规则；正在补偿。\n' >&2
            failed=true
        fi
        [ -z "$current" ] || rm -rf "$current"
        current=""
    fi

    if [ "$failed" = true ]; then
        if rr_firewall_restore_protocol_transaction "$snapshot" "$proto_port" \
            "$proto_type" "$mode"; then
            printf 'RR %s/%s 防火墙变更失败，live 与 UFW 持久规则已恢复原态。\n' \
                "$proto_type" "$proto_port" >&2
        else
            printf '防火墙事务补偿失败；请立即人工核对 IPv4、IPv6、UFW 的 live 与持久规则。\n' >&2
            rm -rf "$snapshot"
            return 2
        fi
        rm -rf "$snapshot"
        return 1
    fi

    if rr_firewall_batch_is_active; then
        if ! rr_firewall_batch_record_protocol "$snapshot" "$proto_port" \
            "$proto_type" "$mode"; then
            if ! rr_firewall_restore_protocol_transaction "$snapshot" "$proto_port" \
                "$proto_type" "$mode"; then
                printf '防火墙批事务登记失败且当前 tuple 补偿失败；请立即人工检查。\n' >&2
                rm -rf "$snapshot"
                return 2
            fi
            rm -rf "$snapshot"
            return 1
        fi
        return 0
    fi

    if [ "$persist_netfilter" = true ] && ! save_firewall; then
        # A save helper may write one family before failing on another.  First
        # restore the exact live snapshot, then save that original state once.
        if ! rr_firewall_restore_protocol_transaction "$snapshot" "$proto_port" \
            "$proto_type" "$mode"; then
            printf '首次防火墙持久化失败，且 live 原态恢复失败；请立即人工检查 IPv4/IPv6 持久规则。\n' >&2
            rm -rf "$snapshot"
            return 2
        fi
        if ! save_firewall; then
            printf '防火墙原态二次持久化失败；live 已恢复，但请立即人工检查 IPv4/IPv6 持久规则。\n' >&2
            rm -rf "$snapshot"
            return 2
        fi
        printf '防火墙持久化失败；live 与持久规则已补偿回原态。\n' >&2
        rm -rf "$snapshot"
        return 1
    fi
    rm -rf "$snapshot"
    return 0
}

rr_validate_protocol_firewall() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local backend="" state=0 failed=false
    local desired_comment="" desired_target="" desired_status=""
    local opposite_comment="" opposite_target="" opposite_status="" mode=""
    local raw_preflight_seen=false
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    case "$desired" in
        open)
            desired_comment="$FIREWALL_COMMENT"; desired_target=ACCEPT; desired_status=ALLOW
            opposite_comment="$FIREWALL_BLOCK_COMMENT"; opposite_target=DROP; opposite_status=DENY
            ;;
        closed)
            desired_comment="$FIREWALL_BLOCK_COMMENT"; desired_target=DROP; desired_status=DENY
            opposite_comment="$FIREWALL_COMMENT"; opposite_target=ACCEPT; opposite_status=ALLOW
            ;;
        *) return 1 ;;
    esac

    rr_firewall_filter_authority_mode mode || return 1

    if [ "$mode" = netfilter ]; then
        rr_inactive_ufw_protocol_is_disjoint "$proto_port" "$proto_type" || failed=true
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
            case "$state" in
                0)
                    raw_preflight_seen=true
                    rr_netfilter_protocol_is_uncontested "$backend" "$proto_port" \
                        "$proto_type" || failed=true
                    ;;
                1) ;;
                *) failed=true ;;
            esac
        done
        [ "$raw_preflight_seen" = true ] || failed=true
    fi

    if [ "$mode" = ufw ] || [ "$mode" = dual ]; then
        rr_ufw_protocol_policy_is_reachable "$proto_port" "$proto_type" \
            "$desired" "$mode" || failed=true
        rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" \
            "$desired_comment" || failed=true
        if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" \
            "$opposite_comment" any; then
            failed=true
        else
            state=$?
            [ "$state" -eq 1 ] || failed=true
        fi
    fi

    if [ "$mode" = dual ] || [ "$mode" = netfilter ]; then
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then
                rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                    "$desired_comment" "$desired_target" || failed=true
                if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                    "$opposite_comment" "$opposite_target"; then
                    failed=true
                else
                    state=$?
                    [ "$state" -eq 1 ] || failed=true
                fi
            else
                state=$?
                [ "$state" -eq 1 ] || failed=true
            fi
        done
    elif ! rr_netfilter_rr_namespace_is_empty; then
        failed=true
    fi

    if [ "$failed" = true ]; then
        printf '热更新只读检查发现 RR 防火墙 %s/%s 规则缺失、冲突或不可读；未修改规则。\n' \
            "$proto_type" "$proto_port" >&2
        return 1
    fi
    return 0
}

rr_local_subscription_loopback_ready() {
    local pid="" state="" argument="" expect_bind=false
    local app_seen=false port_seen=false bind_seen=false
    local proc_root="${RR_PROC_ROOT:-/proc}" cmdline_file=""

    [ "${SUB_ACCESS_MODE:-local}" = local ] || return 1
    is_valid_port "${SUB_PORT:-}" || return 1
    [ -f "${SUB_BIND_STATE_FILE:-}" ] && [ ! -L "${SUB_BIND_STATE_FILE:-}" ] || return 1
    state=$(cat -- "$SUB_BIND_STATE_FILE" 2>/dev/null) || return 1
    case "$state" in
        "${SUB_PORT}|127.0.0.1|local|"*) ;;
        *) return 1 ;;
    esac

    [ -f "${SUB_PID_FILE:-}" ] && [ ! -L "${SUB_PID_FILE:-}" ] || return 1
    pid=$(cat -- "$SUB_PID_FILE" 2>/dev/null) || return 1
    is_subscription_pid "$pid" || return 1
    cmdline_file="${proc_root}/${pid}/cmdline"
    [ -r "$cmdline_file" ] || return 1
    while IFS= read -r -d '' argument; do
        if [ "$expect_bind" = true ]; then
            [ "$argument" = 127.0.0.1 ] && bind_seen=true
            expect_bind=false
            continue
        fi
        case "$argument" in
            */nexus/sub_server.py) app_seen=true ;;
            --bind) expect_bind=true ;;
        esac
        [ "$argument" = "$SUB_PORT" ] && port_seen=true
    done < "$cmdline_file"
    [ "$expect_bind" = false ] && [ "$app_seen" = true ] && \
        [ "$port_seen" = true ] && [ "$bind_seen" = true ]
}

rr_validate_local_subscription_firewall_transition() {
    local proto_port="$1" proto_type="tcp" backend="" state=0
    local closed_state=0 legacy_state=0 closed_any=0 legacy_any=0
    local failed=false legacy_seen=false mode=""
    local raw_seen=false raw_closed_all=true raw_legacy_all=true
    local raw_closed_any=false raw_legacy_any=false

    is_valid_port "$proto_port" || return 1
    rr_firewall_filter_authority_mode mode || return 1
    if [ "$mode" = netfilter ]; then
        rr_inactive_ufw_protocol_is_disjoint "$proto_port" "$proto_type" || return 1
        raw_seen=false
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then state=0; else state=$?; fi
            case "$state" in
                0)
                    raw_seen=true
                    rr_netfilter_protocol_is_uncontested "$backend" "$proto_port" \
                        "$proto_type" || return 1
                    ;;
                1) ;;
                *) return 1 ;;
            esac
        done
        [ "$raw_seen" = true ] || return 1
        raw_seen=false
    fi
    # The compatibility exception is deliberately narrower than the generic
    # firewall validator.  Every backend used by the resolved authority mode
    # must contain either the new exact RR DROP or the exact v7.1.0 ACCEPT --
    # never both.  UFW-authoritative hosts instead require the entire readable
    # raw RR namespace to remain empty.
    if [ "$mode" = ufw ] || [ "$mode" = dual ]; then
        if rr_ufw_rule_state "$proto_port" "$proto_type" DENY \
            "$FIREWALL_BLOCK_COMMENT"; then closed_state=0; else closed_state=$?; fi
        if rr_ufw_rule_state "$proto_port" "$proto_type" ALLOW \
            "$FIREWALL_COMMENT"; then legacy_state=0; else legacy_state=$?; fi
        if rr_ufw_rule_state "$proto_port" "$proto_type" DENY \
            "$FIREWALL_BLOCK_COMMENT" any; then closed_any=0; else closed_any=$?; fi
        if rr_ufw_rule_state "$proto_port" "$proto_type" ALLOW \
            "$FIREWALL_COMMENT" any; then legacy_any=0; else legacy_any=$?; fi
        case "${closed_state}:${legacy_state}:${closed_any}:${legacy_any}" in
            0:1:0:1)
                rr_ufw_protocol_policy_is_reachable "$proto_port" "$proto_type" \
                    closed "$mode" current || failed=true
                ;;
            1:0:1:0)
                rr_ufw_protocol_policy_is_reachable "$proto_port" "$proto_type" \
                    open "$mode" current || failed=true
                legacy_seen=true
                ;;
            *) failed=true ;;
        esac
    fi

    if [ "$mode" = dual ] || [ "$mode" = netfilter ]; then
        for backend in iptables ip6tables; do
            if rr_netfilter_backend_state "$backend"; then
                raw_seen=true
                if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                    "$FIREWALL_BLOCK_COMMENT" DROP; then closed_state=0; else closed_state=$?; fi
                if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                    "$FIREWALL_COMMENT" ACCEPT; then legacy_state=0; else legacy_state=$?; fi
                [ "$closed_state" -ne 0 ] || raw_closed_any=true
                [ "$legacy_state" -ne 0 ] || raw_legacy_any=true
                [ "$closed_state" -eq 0 ] || raw_closed_all=false
                [ "$legacy_state" -eq 0 ] || raw_legacy_all=false
                [ "$closed_state" -le 1 ] && [ "$legacy_state" -le 1 ] || failed=true
            else
                state=$?
                [ "$state" -eq 1 ] || failed=true
            fi
        done
        if [ "$raw_seen" = false ]; then
            failed=true
        elif [ "$raw_closed_all" = true ] && [ "$raw_legacy_any" = false ]; then
            :
        elif [ "$raw_legacy_all" = true ] && [ "$raw_closed_any" = false ]; then
            legacy_seen=true
        else
            failed=true
        fi
    elif ! rr_netfilter_rr_namespace_is_empty; then
        failed=true
    fi

    if [ "$failed" = true ]; then
        printf '热更新只读检查拒绝无法精确归属的订阅防火墙规则（tcp/%s）；未修改规则。\n' \
            "$proto_port" >&2
        return 1
    fi
    if [ "$legacy_seen" = true ]; then
        if ! rr_local_subscription_loopback_ready; then
            printf '热更新发现旧版订阅放行规则，但无法证明新订阅服务仅监听 127.0.0.1；拒绝继续。\n' >&2
            return 1
        fi
        RR_FIREWALL_FINALIZE_REQUIRED=true
    fi
    return 0
}

open_firewall() {
    local operation_status=0
    # Argo 模式只监听 127.0.0.1，不占用公网防火墙端口；TLS 直连时才放行。
    if [ "${VM_ENABLED:-false}" = "true" ] && \
       [ "${VM_TLS_ENABLED:-false}" = "true" ]; then
        open_protocol_firewall "$PORT" "tcp" || operation_status=$?
        [ "$operation_status" -eq 0 ] || return "$operation_status"
    fi
    # Public subscription exposure is decided by its access mode.  Local/SSH
    # mode must never retain an inbound allow rule left by an older release.
    if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
        open_protocol_firewall "$SUB_PORT" "tcp" || operation_status=$?
        [ "$operation_status" -eq 0 ] || return "$operation_status"
    elif [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        # v7.1.0 always left a precisely tagged public ACCEPT for SUB_PORT.
        # The candidate cannot mutate external firewall state before commit,
        # so accept that one legacy state only while the replacement server is
        # demonstrably loopback-only.  A durable post-commit finalizer removes
        # it; every other closed-port caller remains strict.
        rr_validate_local_subscription_firewall_transition "$SUB_PORT" || \
            operation_status=$?
        [ "$operation_status" -eq 0 ] || return "$operation_status"
    else
        close_protocol_firewall "$SUB_PORT" "tcp" || operation_status=$?
        [ "$operation_status" -eq 0 ] || return "$operation_status"
    fi
}

open_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    rr_reconcile_protocol_firewall "$proto_port" "$proto_type" open
}

close_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 0
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    rr_reconcile_protocol_firewall "$proto_port" "$proto_type" closed
}

rr_firewall_batch_install_hop_rules() {
    local label="$1" main_port="$2" spec_list="$3"
    local snapshot="" current="" failed=false arm_status=0
    local ENTRY_IP_MODE="${ENTRY_IP_MODE:-auto}"
    rr_firewall_batch_is_active || return 1
    declare -F install_hop_rules >/dev/null 2>&1 && \
        declare -F rr_validate_hop_rules >/dev/null 2>&1 || return 1
    # Resolve auto only once so the writer and its post-write validator cannot
    # select different required families if interface discovery changes.
    if [ "$ENTRY_IP_MODE" = auto ]; then
        if select_entry_ip >/dev/null 2>&1 && \
           is_ip_version "${ENTRY_IP_RAW:-}" 6; then
            ENTRY_IP_MODE=ipv6
        else
            ENTRY_IP_MODE=ipv4
        fi
    fi
    case "$ENTRY_IP_MODE" in ipv4|ipv6) ;; *) return 1 ;; esac
    rr_firewall_persistence_backend_available || {
        printf '%s\n' '端口跳跃需要 netfilter 持久化后端；未修改 NAT 规则。' >&2
        return 1
    }
    if ! rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
        "$spec_list" pre; then
        printf '%s 端口跳跃被更早的重叠 NAT 规则遮蔽；未修改规则。\n' \
            "$label" >&2
        return 1
    fi
    snapshot=$(mktemp -d "$RR_FIREWALL_BATCH_ROOT/hop.XXXXXX") || return 1
    chmod 700 "$snapshot" || { rm -rf "$snapshot"; return 1; }
    if ! rr_firewall_capture_hop_transaction "$snapshot" "$label" \
        "$main_port" "$spec_list"; then
        rm -rf "$snapshot"
        printf '无法建立 %s 端口跳跃防火墙事务快照；未修改规则。\n' "$label" >&2
        return 1
    fi
    if rr_firewall_inflight_begin_locked; then
        arm_status=0
    else
        arm_status=$?
        rm -rf "$snapshot"
        [ "$arm_status" -ge 2 ] && return 2
        return 1
    fi
    if ! install_hop_rules "$label" "$main_port" "$spec_list"; then
        printf '%s 端口跳跃规则写入失败；正在补偿。\n' "$label" >&2
        failed=true
    fi
    if [ "$failed" = false ] && \
       ! rr_validate_hop_rules "$label" "$main_port" "$spec_list"; then
        printf '%s 端口跳跃规则写入后校验失败；正在补偿。\n' "$label" >&2
        failed=true
    fi
    if [ "$failed" = false ] && \
       ! rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
            "$spec_list" post; then
        printf '%s 端口跳跃写入后的 NAT 有效首匹配校验失败；正在补偿。\n' \
            "$label" >&2
        failed=true
    fi
    if [ "$failed" = false ]; then
        current=$(mktemp -d /tmp/rr-firewall-hop-transaction.XXXXXX) || failed=true
        if [ "$failed" = false ] && \
           { ! rr_firewall_capture_hop_transaction "$current" "$label" \
                "$main_port" "$spec_list" || \
             ! rr_firewall_hop_transaction_seals_match "$snapshot" "$current"; }; then
            printf '%s 端口跳跃变更触及了非目标 NAT 规则；正在补偿。\n' \
                "$label" >&2
            failed=true
        fi
        [ -z "$current" ] || rm -rf "$current"
        current=""
    fi
    if [ "$failed" = true ]; then
        if ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
            "$main_port" "$spec_list"; then
            printf '%s 端口跳跃事务补偿失败；请立即人工核对 IPv4/IPv6 NAT 规则。\n' \
                "$label" >&2
            rm -rf "$snapshot"
            return 2
        fi
        rm -rf "$snapshot"
        return 1
    fi
    if ! rr_firewall_batch_record_hop "$snapshot" "$label" "$main_port" \
        "$spec_list"; then
        if ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
            "$main_port" "$spec_list"; then
            printf '%s 端口跳跃批事务登记失败且补偿失败；请立即人工检查。\n' \
                "$label" >&2
            rm -rf "$snapshot"
            return 2
        fi
        rm -rf "$snapshot"
        return 1
    fi
}

rr_firewall_preflight_configured_hops() {
    local label="" main_port="" spec_list=""
    if [ -n "${HY2_HOP_PORTS:-}" ] && [ -n "${TU5_HOP_PORTS:-}" ] && \
       ! rr_firewall_hop_spec_lists_are_disjoint "$HY2_HOP_PORTS" \
            "$TU5_HOP_PORTS"; then
        printf '%s\n' \
            'HY2 与 TU5 的跳跃端口范围互相重叠；未修改任何防火墙规则。' >&2
        return 1
    fi
    for label in HY2 TU5; do
        case "$label" in
            HY2) main_port="${HY2_PORT:-}"; spec_list="${HY2_HOP_PORTS:-}" ;;
            TU5) main_port="${TU5_PORT:-}"; spec_list="${TU5_HOP_PORTS:-}" ;;
        esac
        [ -n "$spec_list" ] || continue
        declare -F install_hop_rules >/dev/null 2>&1 && \
            declare -F rr_validate_hop_rules >/dev/null 2>&1 || return 1
        rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
            "$spec_list" pre || {
            printf '%s 端口跳跃与现有 NAT 有效首匹配冲突；未修改任何防火墙规则。\n' \
                "$label" >&2
            return 1
        }
    done
}

open_configured_firewall() {
    local result=0 stop_status=0
    if rr_firewall_fail_closed_quarantine_active && \
       [ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" != 1 ]; then
        printf '%s\n' \
            '防火墙持久隔离尚未修复；请先运行显式安全修复。' >&2
        return 1
    fi
    rr_firewall_lock_acquire || return 1
    open_configured_firewall_locked "$@" || result=$?
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '配置化防火墙事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    case "$result" in
        0|1|10) ;;
        *)
            rr_firewall_fail_closed_stop_nodes \
                '配置化防火墙事务无法证明 live 与持久原态' || stop_status=$?
            return "$stop_status"
            ;;
    esac
    return "$result"
}

open_configured_firewall_locked() {
    local result=0 panel_port="" batch_started=false preflight_mode=""
    local raw_persistence_required=false operation_status=0 abort_status=0
    local acme_needed_status=0
    local -a configured_firewall_updates=()
    load_config_with_defaults || return 1
    if [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ]; then
        rr_firewall_batch_begin || return 1
        batch_started=true
        if ! rr_firewall_filter_authority_mode preflight_mode; then
            rr_firewall_batch_abort || abort_status=$?
            [ "$abort_status" -eq 0 ] || return 2
            return 1
        fi
        if [ "$preflight_mode" = dual ] || [ "$preflight_mode" = netfilter ] || \
           [ -n "${HY2_HOP_PORTS:-}" ] || [ -n "${TU5_HOP_PORTS:-}" ]; then
            raw_persistence_required=true
        fi
        if [ "$raw_persistence_required" = true ] && \
           ! rr_firewall_persistence_backend_available; then
            printf '%s\n' \
                '配置需要持久化 raw/NAT 规则，但系统没有受支持的后端；未修改任何防火墙规则。' >&2
            rr_firewall_batch_abort || abort_status=$?
            [ "$abort_status" -eq 0 ] || return 2
            return 1
        fi
        if ! rr_firewall_preflight_configured_hops; then
            rr_firewall_batch_abort || abort_status=$?
            [ "$abort_status" -eq 0 ] || return 2
            return 1
        fi
    fi
    open_firewall || result=$?
    if [ "$result" -eq 0 ] && [ "${VL_ENABLED:-false}" = true ]; then
        open_protocol_firewall "$VL_PORT" tcp || result=$?
    fi
    if [ "$result" -eq 0 ] && [ "${HY2_ENABLED:-false}" = true ]; then
        open_protocol_firewall "$HY2_PORT" udp || result=$?
    fi
    if [ "$result" -eq 0 ] && [ "${TU5_ENABLED:-false}" = true ]; then
        open_protocol_firewall "$TU5_PORT" udp || result=$?
    fi
    if [ "$result" -eq 0 ] && [ "${AN_ENABLED:-false}" = true ]; then
        open_protocol_firewall "$AN_PORT" tcp || result=$?
    fi
    if [ "$result" -eq 0 ] && [ "${NAIVE_ENABLED:-false}" = true ]; then
        case "${NAIVE_MODE:-h2}" in
            h2) open_protocol_firewall "$NAIVE_PORT" tcp || result=$? ;;
            h3) open_protocol_firewall "$NAIVE_PORT" udp || result=$? ;;
            both)
                open_protocol_firewall "$NAIVE_PORT" tcp || result=$?
                [ "$result" -ne 0 ] || \
                    open_protocol_firewall "$NAIVE_PORT" udp || result=$?
                ;;
            *) result=1 ;;
        esac
    fi
    if [ "$result" -eq 0 ] && \
       declare -F rr_firewall_acme_http_tuple_needed_after_updates \
            >/dev/null 2>&1; then
        if rr_firewall_acme_http_tuple_needed_after_updates \
            configured_firewall_updates; then
            open_protocol_firewall 80 tcp || result=$?
        else
            acme_needed_status=$?
            [ "$acme_needed_status" -eq 1 ] || result=1
        fi
    elif [ "$result" -eq 0 ] && \
         { [ "${NAIVE_ENABLED:-false}" = true ] || \
           [ "${SUB_ACCESS_MODE:-local}" = https ]; }; then
        result=1
    fi
    if [ "$result" -eq 0 ] && [ -n "${HY2_HOP_PORTS:-}" ]; then
        if ! declare -F install_hop_rules >/dev/null 2>&1; then
            result=1
        elif [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            declare -F rr_validate_hop_rules >/dev/null 2>&1 || result=1
            [ "$result" -ne 0 ] || \
                rr_validate_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" || result=1
            [ "$result" -ne 0 ] || \
                rr_firewall_hop_program_first_match_is_safe HY2 "$HY2_PORT" \
                    "$HY2_HOP_PORTS" post || result=1
        else
            rr_firewall_batch_install_hop_rules HY2 "$HY2_PORT" \
                "$HY2_HOP_PORTS" || result=$?
        fi
    fi
    if [ "$result" -eq 0 ] && [ -n "${TU5_HOP_PORTS:-}" ]; then
        if ! declare -F install_hop_rules >/dev/null 2>&1; then
            result=1
        elif [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            declare -F rr_validate_hop_rules >/dev/null 2>&1 || result=1
            [ "$result" -ne 0 ] || \
                rr_validate_hop_rules TU5 "$TU5_PORT" "$TU5_HOP_PORTS" || result=1
            [ "$result" -ne 0 ] || \
                rr_firewall_hop_program_first_match_is_safe TU5 "$TU5_PORT" \
                    "$TU5_HOP_PORTS" post || result=1
        else
            rr_firewall_batch_install_hop_rules TU5 "$TU5_PORT" \
                "$TU5_HOP_PORTS" || result=$?
        fi
    fi
    if [ "$result" -eq 0 ] && [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] && \
       [ "$(jq -r '.mode // empty' "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null)" = public ]; then
        panel_port=$(jq -r '.public_port // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || result=1
        [ "$result" -ne 0 ] || \
            open_protocol_firewall "$panel_port" tcp || result=$?
    fi
    if [ "$batch_started" = false ]; then
        [ "$result" -eq 0 ]
        return $?
    fi
    if [ "$result" -ne 0 ]; then
        operation_status="$result"
        rr_firewall_batch_abort || abort_status=$?
        if [ "$operation_status" -ge 2 ] || [ "$abort_status" -ne 0 ]; then
            return 2
        fi
        return "$operation_status"
    fi
    rr_firewall_batch_commit
}

rr_firewall_restore_quarantine_unit_enablement() {
    local index="$1" unit="${RR_FIREWALL_QUARANTINE_UNITS[index]}"
    local expected_load="${RR_FIREWALL_QUARANTINE_LOAD_STATES[index]}"
    local expected_file="${RR_FIREWALL_QUARANTINE_FILE_STATES[index]}"
    local current_load="" current_file=""
    current_load=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || \
        return 1
    [ "$current_load" = "$expected_load" ] || return 1
    case "$expected_file" in
        enabled) systemctl enable "$unit" >/dev/null 2>&1 || return 1 ;;
        enabled-runtime)
            systemctl enable --runtime "$unit" >/dev/null 2>&1 || return 1
            ;;
        disabled) systemctl disable "$unit" >/dev/null 2>&1 || return 1 ;;
        static|masked|not-found) ;;
        *) return 1 ;;
    esac
    current_file=$(systemctl show --property=UnitFileState --value \
        "$unit" 2>/dev/null) || return 1
    if [ "$current_load" = not-found ] && [ -z "$current_file" ]; then
        current_file=not-found
    fi
    [ "$current_file" = "$expected_file" ]
}

rr_firewall_restore_quarantine_runtime_state() {
    local index=0 unit="" wanted="" active_state="" failed=false
    for ((index=0; index<${#RR_FIREWALL_QUARANTINE_UNITS[@]}; index++)); do
        unit="${RR_FIREWALL_QUARANTINE_UNITS[index]}"
        wanted="${RR_FIREWALL_QUARANTINE_ACTIVE_STATES[index]}"
        case "$wanted" in
            active) systemctl start "$unit" >/dev/null 2>&1 || failed=true ;;
            inactive|failed) systemctl stop "$unit" >/dev/null 2>&1 || true ;;
            *) failed=true ;;
        esac
        active_state=$(systemctl show --property=ActiveState --value \
            "$unit" 2>/dev/null) || { failed=true; continue; }
        case "$wanted:$active_state" in
            active:active|inactive:inactive|inactive:failed|\
            failed:inactive|failed:failed) ;;
            *) failed=true ;;
        esac
    done
    case "$RR_FIREWALL_QUARANTINE_SINGBOX_RUNTIME" in
        true)
            ensure_node_service_running >/dev/null 2>&1 || failed=true
            managed_singbox_running || failed=true
            ;;
        false)
            stop_singbox_instances >/dev/null 2>&1 || failed=true
            managed_singbox_running && failed=true
            ;;
        *) failed=true ;;
    esac
    case "$RR_FIREWALL_QUARANTINE_SUBSCRIPTION_RUNTIME" in
        true)
            start_subscription_server >/dev/null 2>&1 || failed=true
            subscription_server_running || failed=true
            ;;
        false)
            stop_subscription_servers >/dev/null 2>&1 || failed=true
            subscription_server_running && failed=true
            ;;
        *) failed=true ;;
    esac
    [ "$failed" = false ]
}

rr_firewall_snapshot_unmanaged_matches() {
    local original_root="$1" current_root="$2"
    local original="$1/firewall" current="$2/firewall"
    local backend="" table="" state=""
    rr_restore_require_firewall_snapshot_v2 "$original_root" || return 1
    rr_restore_require_firewall_snapshot_v2 "$current_root" || return 1
    cmp -s "$original/ufw.state" "$current/ufw.state" || return 1
    state=$(cat -- "$original/ufw.state" 2>/dev/null) || return 1
    case "$state" in
        active)
            cmp -s "$original/ufw.unmanaged" "$current/ufw.unmanaged" || return 1
            ;;
        inactive)
            cmp -s "$original/ufw.inactive.rules" \
                "$current/ufw.inactive.rules" || return 1
            ;;
        absent) ;;
        *) return 1 ;;
    esac
    for backend in iptables ip6tables; do
        cmp -s "$original/${backend}.state" "$current/${backend}.state" || \
            return 1
        state=$(cat -- "$original/${backend}.state" 2>/dev/null) || return 1
        case "$state" in
            absent) continue ;;
            readable) ;;
            *) return 1 ;;
        esac
        for table in filter nat; do
            cmp -s "$original/${backend}.${table}.unmanaged" \
                "$current/${backend}.${table}.unmanaged" || return 1
            cmp -s "$original/${backend}.${table}.unmanaged.raw" \
                "$current/${backend}.${table}.unmanaged.raw" || return 1
        done
    done
}

rr_firewall_snapshots_match_after_clear() {
    local original_root="$1" current_root="$2"
    local original="$1/firewall" current="$2/firewall"
    local backend="" table="" state=""
    rr_firewall_snapshot_unmanaged_matches "$original_root" "$current_root" || \
        return 1
    state=$(cat -- "$current/ufw.state" 2>/dev/null) || return 1
    if [ "$state" = active ]; then
        [ -f "$current/ufw.rules" ] && [ ! -s "$current/ufw.rules" ] && \
            [ -f "$current/ufw.ordered" ] && \
            [ ! -s "$current/ufw.ordered" ] || return 1
    fi
    for backend in iptables ip6tables; do
        state=$(cat -- "$current/${backend}.state" 2>/dev/null) || return 1
        [ "$state" != readable ] || for table in filter nat; do
            [ -f "$current/${backend}.${table}.rules" ] && \
                [ ! -s "$current/${backend}.${table}.rules" ] || return 1
        done
    done
}

# A comment-free rule overlapping either the desired namespace or a tagged
# tuple present in the sealed quarantine snapshot cannot be attributed to RR
# or to the administrator.  Automatic recovery must keep the durable marker
# instead of guessing and potentially leaving a stale public allow/NAT rule.
rr_firewall_snapshot_has_ambiguous_legacy_rules() {
    local root="$1" desired="$2" snapshot="$1/firewall" state=0
    python3 - "$snapshot" "$desired" "$FIREWALL_COMMENT" \
        "$FIREWALL_BLOCK_COMMENT" <<'PY'
import os
import re
import shlex
import sys

snapshot, desired_path, allow_comment, block_comment = sys.argv[1:]
managed_comments = {allow_comment, block_comment}
protocol_keys = set()
hop_ranges = []


def intervals(value):
    result = []
    for item in value.split(","):
        match = re.fullmatch(r"([0-9]+)(?::([0-9]+))?", item)
        if match is None:
            raise SystemExit(1)
        low = int(match.group(1))
        high = int(match.group(2) or match.group(1))
        if low < 1 or high > 65535 or low > high:
            raise SystemExit(1)
        result.append((low, high))
    return result


def option(tokens, *names):
    indexes = [i for i, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None, True
    index = indexes[0]
    return tokens[index + 1], index > 0 and tokens[index - 1] == "!"


for raw in open(desired_path, encoding="utf-8"):
    fields = raw.rstrip("\n").split("|")
    if len(fields) == 4 and fields[0] == "protocol":
        action, port, proto = fields[1:]
        if action not in {"open", "closed"} or proto not in {"tcp", "udp"}:
            raise SystemExit(1)
        protocol_keys.add((int(port), proto))
    elif len(fields) == 4 and fields[0] == "hop":
        _label, main, specs = fields[1:]
        protocol_keys.add((int(main), "udp"))
        hop_ranges.extend(intervals(specs))
    else:
        raise SystemExit(1)

# Tagged tuples in the sealed indeterminate state include both the old and new
# sides of a failed configuration transition.  Treat their ports as candidates
# too, so an untagged legacy twin on the old port blocks automatic release.
for backend in ("iptables", "ip6tables"):
    for table in ("filter", "nat"):
        path = os.path.join(snapshot, f"{backend}.{table}.rules")
        if not os.path.exists(path):
            continue
        for raw in open(path, encoding="utf-8"):
            line = raw.rstrip("\n").split("\t", 1)[-1]
            try:
                tokens = shlex.split(line)
            except ValueError:
                raise SystemExit(1)
            port, negated = option(tokens, "--dport", "--dports")
            proto, proto_negated = option(tokens, "-p", "--protocol")
            if port and not negated:
                parsed = intervals(port.replace("-", ":"))
                if table == "filter" and proto in {"tcp", "udp"} and not proto_negated:
                    for low, high in parsed:
                        if low == high:
                            protocol_keys.add((low, proto))
                elif table == "nat":
                    hop_ranges.extend(parsed)


def overlaps_protocol(tokens):
    proto, proto_negated = option(tokens, "-p", "--protocol")
    port, port_negated = option(tokens, "--dport", "--dports")
    if proto_negated or port_negated:
        return bool(protocol_keys)
    protocols = {"tcp", "udp"} if proto in {None, "all", "0"} else {proto}
    candidates = {(p, q) for p, q in protocol_keys if q in protocols}
    if not candidates:
        return False
    if port is None:
        return True
    try:
        ranges = intervals(port.replace("-", ":"))
    except SystemExit:
        return True
    return any(q in protocols and any(low <= p <= high for low, high in ranges)
               for p, q in candidates)


def overlaps_hop(tokens):
    if not hop_ranges:
        return False
    proto, proto_negated = option(tokens, "-p", "--protocol")
    if not proto_negated and proto not in {None, "all", "0", "udp"}:
        return False
    port, port_negated = option(tokens, "--dport", "--dports")
    if port_negated or port is None:
        return True
    try:
        ranges = intervals(port.replace("-", ":"))
    except SystemExit:
        return True
    return any(max(a, c) <= min(b, d)
               for a, b in ranges for c, d in hop_ranges)


ufw_path = os.path.join(snapshot, "ufw.unmanaged")
if os.path.exists(ufw_path):
    for raw in open(ufw_path, encoding="utf-8"):
        try:
            tokens = shlex.split(raw)
        except ValueError:
            raise SystemExit(1)
        if len(tokens) >= 3 and tokens[0] == "ufw" and "/" in tokens[2]:
            port, proto = tokens[2].split("/", 1)
            if port.isdigit() and (int(port), proto) in protocol_keys and \
                    "comment" not in tokens:
                raise SystemExit(0)

for backend in ("iptables", "ip6tables"):
    for table in ("filter", "nat"):
        path = os.path.join(snapshot, f"{backend}.{table}.raw")
        if not os.path.exists(path):
            continue
        wanted_chain = "INPUT" if table == "filter" else "PREROUTING"
        for raw in open(path, encoding="utf-8"):
            try:
                tokens = shlex.split(raw)
            except ValueError:
                raise SystemExit(1)
            if len(tokens) < 3 or tokens[:2] != ["-A", wanted_chain]:
                continue
            comment, comment_negated = option(tokens, "--comment")
            if comment in managed_comments or (comment and comment.startswith("argo-rr-")):
                continue
            if comment is not None and not comment_negated:
                continue
            if (table == "filter" and overlaps_protocol(tokens)) or \
                    (table == "nat" and overlaps_hop(tokens)):
                raise SystemExit(0)
raise SystemExit(10)
PY
    state=$?
    # 10 is the only proof that no ambiguous overlap exists.  Parse/read
    # failures are treated like an ambiguous legacy rule and keep quarantine.
    [ "$state" -eq 10 ] && return 1
    return 0
}

rr_firewall_verify_desired_namespace() {
    local root="$1" desired="$2" snapshot="$1/firewall"
    local kind="" action="" first="" second="" extra=""
    # First reject malformed, duplicate, or extra tagged rules anywhere in the
    # complete raw programs.  Per-tuple validators below then prove every
    # desired rule is effective in the selected authority backend/families.
    python3 - "$snapshot" "$desired" "$FIREWALL_COMMENT" \
        "$FIREWALL_BLOCK_COMMENT" <<'PY' || return 1
import os
import re
import shlex
import sys

snapshot, desired_path, allow_comment, block_comment = sys.argv[1:]
protocols = {}
hops = {}
for raw in open(desired_path, encoding="utf-8"):
    fields = raw.rstrip("\n").split("|")
    if len(fields) == 4 and fields[0] == "protocol":
        action, port, proto = fields[1:]
        key = (port, proto)
        if action not in {"open", "closed"} or key in protocols:
            raise SystemExit(1)
        protocols[key] = action
    elif len(fields) == 4 and fields[0] == "hop":
        label, main, specs = fields[1:]
        if label not in {"HY2", "TU5"} or label in hops:
            raise SystemExit(1)
        hops[label] = (main, set(specs.split(",")))
    else:
        raise SystemExit(1)


def option(tokens, *names):
    indexes = [i for i, token in enumerate(tokens) if token in names]
    if len(indexes) != 1 or indexes[0] + 1 >= len(tokens):
        return None
    return tokens[indexes[0] + 1]


def exact_filter(tokens):
    if len(tokens) < 10 or tokens[:2] != ["-A", "INPUT"] or "!" in tokens:
        return None
    proto = option(tokens, "-p", "--protocol")
    port = option(tokens, "--dport")
    comment = option(tokens, "--comment")
    target = option(tokens, "-j", "--jump")
    if (proto not in {"tcp", "udp"} or port is None
            or re.fullmatch(r"[1-9][0-9]{0,4}", port) is None
            or comment not in {allow_comment, block_comment}
            or target != ({allow_comment: "ACCEPT", block_comment: "DROP"}[comment])):
        return None
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
            return None
    if any(module not in {proto, "comment"} for module in modules):
        return None
    action = "open" if comment == allow_comment else "closed"
    return (port, proto, action)


def exact_nat(tokens):
    if len(tokens) < 10 or tokens[:2] != ["-A", "PREROUTING"] or "!" in tokens:
        return None
    proto = option(tokens, "-p", "--protocol")
    spec = option(tokens, "--dport")
    comment = option(tokens, "--comment")
    target = option(tokens, "-j", "--jump")
    if proto != "udp" or spec is None or target not in {"REDIRECT", "DNAT"} \
            or comment is None or not comment.startswith("argo-rr-"):
        return None
    label = comment.removeprefix("argo-rr-")
    if label not in hops or spec not in hops[label][1]:
        return None
    main = hops[label][0]
    if target == "REDIRECT":
        if option(tokens, "--to-ports") != main or option(tokens, "--to-destination") is not None:
            return None
    elif option(tokens, "--to-destination") != f":{main}" or option(tokens, "--to-ports") is not None:
        return None
    index = 2
    modules = []
    valued = {"-p", "--protocol", "--dport", "--comment", "-j", "--jump",
              "--to-ports", "--to-destination"}
    while index < len(tokens):
        token = tokens[index]
        if token in valued and index + 1 < len(tokens):
            index += 2
        elif token == "-m" and index + 1 < len(tokens):
            modules.append(tokens[index + 1])
            index += 2
        else:
            return None
    if any(module not in {"udp", "comment"} for module in modules):
        return None
    return (label, spec, target)


seen = set()
for backend in ("iptables", "ip6tables"):
    for table in ("filter", "nat"):
        path = os.path.join(snapshot, f"{backend}.{table}.raw")
        if not os.path.exists(path):
            continue
        for raw in open(path, encoding="utf-8"):
            try:
                tokens = shlex.split(raw)
            except ValueError:
                raise SystemExit(1)
            raw_comments = [tokens[i + 1] for i, token in enumerate(tokens[:-1])
                            if token == "--comment"]
            managed_comments = [comment for comment in raw_comments
                                if comment in {allow_comment, block_comment}
                                or comment.startswith("argo-rr-")]
            managed = bool(managed_comments)
            if not managed:
                continue
            if len(raw_comments) != 1 or len(managed_comments) != 1:
                raise SystemExit(1)
            item = exact_filter(tokens) if table == "filter" else exact_nat(tokens)
            if item is None:
                raise SystemExit(1)
            if table == "filter":
                port, proto, action = item
                if protocols.get((port, proto)) != action:
                    raise SystemExit(1)
            key = (backend, table, item)
            if key in seen:
                raise SystemExit(1)
            seen.add(key)

ufw_path = os.path.join(snapshot, "ufw.rules")
if os.path.exists(ufw_path):
    seen_ufw = set()
    for raw in open(ufw_path, encoding="utf-8"):
        try:
            tokens = shlex.split(raw)
        except ValueError:
            raise SystemExit(1)
        if (len(tokens) != 5 or tokens[0] != "ufw"
                or tokens[1] not in {"allow", "deny"}
                or tokens[3] != "comment"
                or tokens[4] not in {allow_comment, block_comment}
                or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None):
            raise SystemExit(1)
        port, proto = tokens[2].split("/", 1)
        action = "open" if tokens[1] == "allow" else "closed"
        expected_comment = allow_comment if action == "open" else block_comment
        key = (port, proto)
        if tokens[4] != expected_comment or protocols.get(key) != action or key in seen_ufw:
            raise SystemExit(1)
        seen_ufw.add(key)
PY
    while IFS='|' read -r kind action first second extra; do
        [ -z "$extra" ] || return 1
        case "$kind" in
            protocol)
                rr_validate_protocol_firewall "$first" "$second" "$action" || \
                    return 1
                ;;
            hop)
                case "$action" in HY2|TU5) ;; *) return 1 ;; esac
                rr_validate_hop_rules "$action" "$first" "$second" || return 1
                rr_firewall_hop_program_first_match_is_safe \
                    "$action" "$first" "$second" post || return 1
                ;;
            *) return 1 ;;
        esac
    done < "$desired"
}

rr_firewall_restore_quarantine_snapshot_locked() {
    local evidence="$1"
    rr_firewall_lock_is_held || return 1
    rr_restore_restore_firewall_snapshot "$evidence" || return 1
    rr_restore_verify_firewall_pre_mutation_snapshot "$evidence" || return 1
    rr_restore_verify_ufw_program_exact "$evidence/firewall"
}

# Explicit recovery for a durable firewall quarantine.  The marker remains in
# place while the full configured policy is reconciled, persisted, and
# verified under the global firewall lock.  Unit enablement is restored while
# its systemd conditions still block starts; only then is the marker removed
# and the byte-recorded running state resumed and proved.
rr_firewall_repair_fail_closed_quarantine() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local evidence="$directory/firewall-evidence" desired=""
    local cleared="" final="" backup="" evidence_backup=""
    local repair_status=0 release_status=0
    local index=0 stop_status=0 raw_required=false raw_state=0 failed=false
    local RR_FIREWALL_QUARANTINE_REPAIR=1
    rr_firewall_fail_closed_quarantine_active || return 0
    rr_firewall_lock_acquire || return 1
    if ! rr_firewall_load_fail_closed_quarantine || \
       [ "$RR_FIREWALL_QUARANTINE_EVIDENCE_KIND" != firewall-evidence-v1 ] || \
       ! rr_restore_verify_firewall_pre_mutation_snapshot "$evidence"; then
        rr_firewall_lock_release || true
        return 1
    fi
    desired="$evidence/desired.namespace"
    if rr_restore_firewall_snapshot_has_managed_raw_rules "$evidence/firewall"; then
        raw_required=true
    else
        raw_state=$?
        [ "$raw_state" -eq 1 ] || failed=true
    fi
    if [ "$failed" = false ] && [ "$raw_required" = true ] && \
       ! rr_firewall_persistence_backend_available; then
        failed=true
    fi
    if [ "$failed" = false ] && \
       rr_firewall_snapshot_has_ambiguous_legacy_rules "$evidence" "$desired"; then
        printf '%s\n' \
            '隔离快照含无法精确归属的无注释旧规则；保持隔离并拒绝自动修复。' >&2
        failed=true
    fi
    if [ "$failed" = false ]; then
        cleared=$(mktemp -d "$directory/.firewall-repair-clear.XXXXXX") || \
            failed=true
        [ "$failed" = true ] || chmod 700 "$cleared" || failed=true
    fi
    if [ "$failed" = false ]; then
        RR_RESTORE_FIREWALL_NEEDS_PERSIST="$raw_required" \
            rr_restore_clear_managed_firewall "$evidence/firewall" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_restore_capture_firewall_snapshot "$cleared" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_firewall_snapshots_match_after_clear "$evidence" "$cleared" || \
            failed=true
    fi
    if [ "$failed" = false ]; then
        open_configured_firewall_locked || repair_status=$?
        [ "$repair_status" -eq 0 ] || failed=true
    fi
    # If the indeterminate state contained raw rules but the desired policy is
    # now UFW-only, open_configured has no reason to save their removal.  The
    # outer recovery transaction still owns that persistence obligation.
    if [ "$failed" = false ] && [ "$raw_required" = true ]; then
        save_firewall || failed=true
    fi
    if [ "$failed" = false ]; then
        final=$(mktemp -d "$directory/.firewall-repair-final.XXXXXX") || \
            failed=true
        [ "$failed" = true ] || chmod 700 "$final" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_restore_capture_firewall_snapshot "$final" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_firewall_snapshot_unmanaged_matches "$evidence" "$final" || failed=true
        rr_firewall_verify_desired_namespace "$final" "$desired" || failed=true
    fi
    if [ "$failed" = true ]; then
        rm -rf -- "$cleared" "$final" 2>/dev/null || true
        if ! rr_firewall_restore_quarantine_snapshot_locked "$evidence"; then
            rr_firewall_fail_closed_stop_nodes \
                '防火墙隔离全命名空间修复及原态补偿均无法证明' || stop_status=$?
            rr_firewall_lock_release || stop_status=3
            return "$stop_status"
        fi
        if ! rr_firewall_lock_release; then
            rr_firewall_fail_closed_stop_nodes \
                '防火墙隔离修复已补偿但锁释放失败' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    rm -rf -- "$cleared" "$final" 2>/dev/null || release_status=1
    for ((index=0; index<${#RR_FIREWALL_QUARANTINE_UNITS[@]}; index++)); do
        rr_firewall_restore_quarantine_unit_enablement "$index" || \
            release_status=1
    done
    if [ "$release_status" -ne 0 ]; then
        rr_firewall_lock_release || true
        return 1
    fi
    # Stop path, timer, and any queued guard while the marker still gates every
    # managed ingress.  The path is rearmed only after marker removal; any
    # failure before then explicitly reactivates the quarantined supervisor.
    if ! rr_firewall_deactivate_quarantine_retry; then
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_quiesce_durable_ingress >/dev/null 2>&1 || true
        rr_firewall_lock_release || true
        return 1
    fi
    backup=$(mktemp "$directory/.firewall-quarantine-repair.XXXXXX") || {
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_lock_release || true
        return 1
    }
    evidence_backup="$directory/.firewall-evidence-repaired.${BASHPID}"
    if [ -e "$evidence_backup" ] || [ -L "$evidence_backup" ]; then
        rm -f -- "$backup"
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_lock_release || true
        return 1
    fi
    if ! cp -f -- "$marker" "$backup" || ! chown 0:0 "$backup" || \
       ! chmod 600 "$backup" || ! sync -f "$backup" || \
       ! rm -f -- "$marker" || ! mv -- "$evidence" "$evidence_backup" || \
       ! sync -f "$directory"; then
        [ -e "$marker" ] || mv -f -- "$backup" "$marker" 2>/dev/null || true
        [ -e "$evidence" ] || \
            mv -f -- "$evidence_backup" "$evidence" 2>/dev/null || true
        sync -f "$directory" 2>/dev/null || true
        rm -f -- "$backup"
        rr_firewall_activate_quarantine_supervisor >/dev/null 2>&1 || true
        rr_firewall_lock_release || true
        return 1
    fi
    if ! rr_firewall_activate_idle_quarantine_supervisor; then
        rm -rf -- "$backup" "$evidence_backup" 2>/dev/null || true
        sync -f "$directory" 2>/dev/null || true
        rr_firewall_fail_closed_stop_nodes \
            '防火墙隔离修复后无法重启空闲路径监督器' || stop_status=$?
        rr_firewall_lock_release || true
        return "$stop_status"
    fi
    if ! rr_firewall_restore_quarantine_runtime_state; then
        # The firewall is now the verified desired state, so the old evidence
        # must never be rebound to a new marker.  Re-publish from the current
        # state before returning the fail-closed status.
        rm -rf -- "$backup" "$evidence_backup" 2>/dev/null || true
        sync -f "$directory" 2>/dev/null || true
        rr_firewall_fail_closed_stop_nodes \
            '防火墙隔离修复后公网运行面无法精确恢复' || \
            stop_status=$?
        rr_firewall_lock_release || true
        return "$stop_status"
    fi
    rm -rf -- "$backup" "$evidence_backup" || release_status=1
    sync -f "$directory" || release_status=1
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '防火墙隔离修复后锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    if [ "$release_status" -ne 0 ]; then
        rr_firewall_fail_closed_stop_nodes \
            '防火墙隔离修复证据清理失败' || stop_status=$?
        return "$stop_status"
    fi
    return 0
}

save_firewall() {
    local result=0 arm_status=0 finish_status=0 stop_status=0
    local started_here=false evidence=""
    rr_firewall_lock_acquire || return 1
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
    rr_save_firewall_locked || result=$?
    if [ "$started_here" = true ]; then
        evidence="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-evidence"
        if [ "$result" -eq 0 ] && \
           ! rr_restore_verify_firewall_pre_mutation_snapshot "$evidence"; then
            result=2
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
            '防火墙持久化事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

rr_save_firewall_locked() {
    rr_firewall_writer_gate_is_held || return 1
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if ! netfilter-persistent save >/dev/null 2>&1; then
            printf 'netfilter-persistent 无法持久化 RR 防火墙规则。\n' >&2
            return 1
        fi
    elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; then
        if ! service iptables save >/dev/null 2>&1; then
            printf 'iptables 服务无法持久化 RR 防火墙规则。\n' >&2
            return 1
        fi
    else
        printf '系统没有受支持的 netfilter 持久化后端。\n' >&2
        return 1
    fi
    return 0
}

# ==========================================
# 安全 sed 替换函数
# ==========================================
safe_sed() {
    local key="$1"
    local value="$2"
    local encoded_value=""
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    printf -v encoded_value '%q' "$value"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${encoded_value}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$encoded_value" >> "$CONFIG_FILE"
    fi
}

is_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_cloudflare_tls_port() {
    case "${1:-}" in
        443|2053|2083|2087|2096|8443) return 0 ;;
        *) return 1 ;;
    esac
}

tcp_port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn 2>/dev/null | awk -v suffix=":${port}" '
        {
            endpoint=$4
            if (length(endpoint) >= length(suffix) &&
                substr(endpoint, length(endpoint) - length(suffix) + 1) == suffix) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

udp_port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lun 2>/dev/null | awk -v suffix=":${port}" '
        {
            # ss -H -lun: Local Address:Port is column 4; column 5 is peer address.
            endpoint=$4
            if (length(endpoint) >= length(suffix) &&
                substr(endpoint, length(endpoint) - length(suffix) + 1) == suffix) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

is_valid_hop_spec() {
    local spec="${1:-}"
    local item=""
    local start=""
    local end=""
    local -a hop_items=()
    [ -z "$spec" ] && return 0
    IFS=',' read -r -a hop_items <<< "$spec"
    for item in "${hop_items[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            is_valid_port "$start" && is_valid_port "$end" && \
                (( 10#$start >= 1000 && 10#$end <= 65535 && 10#$start < 10#$end )) || return 1
        elif is_valid_port "$item" && (( 10#$item >= 1000 )); then
            :
        else
            return 1
        fi
    done
}

hop_spec_contains_port() {
    local spec_list="$1"
    local port="$2"
    local item=""
    local start=""
    local end=""
    local -a hop_items=()
    is_valid_hop_spec "$spec_list" || return 1
    is_valid_port "$port" || return 1
    IFS=',' read -r -a hop_items <<< "$spec_list"
    for item in "${hop_items[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( 10#$port >= 10#$start && 10#$port <= 10#$end )); then
                return 0
            fi
        elif [ "$item" = "$port" ]; then
            return 0
        fi
    done
    return 1
}

validate_hop_spec_availability() {
    local spec_list="$1"
    local main_port="$2"
    local used_port=""
    [ -z "$spec_list" ] && return 0
    is_valid_hop_spec "$spec_list" || return 1

    if [ "${TU5_ENABLED:-false}" = "true" ] && is_valid_port "${TU5_PORT:-0}" && \
       [ "$TU5_PORT" != "$main_port" ] && hop_spec_contains_port "$spec_list" "$TU5_PORT"; then
        echo -e "${RED}[拒绝变更] 跳跃范围包含 Tuic5 正在使用的 UDP 端口 ${TU5_PORT}。${RESET}" >&2
        return 1
    fi

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r used_port; do
            is_valid_port "$used_port" || continue
            [ "$used_port" = "$main_port" ] && continue
            if hop_spec_contains_port "$spec_list" "$used_port"; then
                echo -e "${RED}[拒绝变更] 跳跃范围包含已被其他服务监听的 UDP 端口 ${used_port}。${RESET}" >&2
                return 1
            fi
        done < <(ss -H -lun 2>/dev/null | awk '{endpoint=$4; sub(/^.*:/, "", endpoint); if (endpoint ~ /^[0-9]+$/) print endpoint}' | sort -nu)
    fi
    return 0
}

is_valid_hop_interval() {
    local interval="${1:-}"
    local amount=""
    local unit=""
    [[ "$interval" =~ ^([1-9][0-9]*)(ms|s|m|h)$ ]] || return 1
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    # 避免超长数字触发 Bash 整数溢出；官方 Hysteria2 建议至少 5 秒。
    [ "${#amount}" -le 8 ] || return 1
    case "$unit" in
        ms) (( 10#$amount >= 5000 && 10#$amount <= 86400000 )) ;;
        s)  (( 10#$amount >= 5 && 10#$amount <= 86400 )) ;;
        m)  (( 10#$amount >= 1 && 10#$amount <= 1440 )) ;;
        h)  (( 10#$amount >= 1 && 10#$amount <= 24 )) ;;
        *) return 1 ;;
    esac
}

duration_to_seconds() {
    local interval="${1:-}"
    local amount=""
    local unit=""
    is_valid_hop_interval "$interval" || return 1
    [[ "$interval" =~ ^([1-9][0-9]*)(ms|s|m|h)$ ]] || return 1
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        ms) echo $(( (10#$amount + 999) / 1000 )) ;;
        s) echo $(( 10#$amount )) ;;
        m) echo $(( 10#$amount * 60 )) ;;
        h) echo $(( 10#$amount * 3600 )) ;;
    esac
}

ensure_subscription_root() {
    local root_uid=""
    # /tmp 使用 sticky bit 只能保护已经由 root 创建的目录；首次创建前仍可能被
    # 普通用户抢占为目录或符号链接。绝不跟随或接管这类对象，也不自动删除，
    # 以免把攻击者选择的目标变成 root 的递归删除对象。
    if [ -L "$SUB_ROOT" ] || { [ -e "$SUB_ROOT" ] && [ ! -d "$SUB_ROOT" ]; }; then
        echo -e "${RED}[安全拒绝] 订阅目录不是普通目录：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    if [ ! -d "$SUB_ROOT" ]; then
        mkdir -m 700 -- "$SUB_ROOT" 2>/dev/null || true
    fi
    if [ -L "$SUB_ROOT" ] || [ ! -d "$SUB_ROOT" ]; then
        echo -e "${RED}[安全拒绝] 无法安全创建订阅目录：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    root_uid=$(stat -c '%u' -- "$SUB_ROOT" 2>/dev/null) || return 1
    if [ "$root_uid" != 0 ]; then
        echo -e "${RED}[安全拒绝] 订阅目录不属于 root：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    chmod 700 -- "$SUB_ROOT" || return 1
    # chmod 后再次检查，防止检查与使用之间对象发生变化。
    [ ! -L "$SUB_ROOT" ] && [ -d "$SUB_ROOT" ] && \
        [ "$(stat -c '%u' -- "$SUB_ROOT" 2>/dev/null)" = 0 ]
}

rr_subscription_process_matches() {
    local process_dir="${1:-}"
    local expected_cwd="${2:-}"
    local expected_app="${3:-}"
    local uid_line=""
    local python_name=""
    local port=""
    local process_cwd=""
    local cwd_links=""
    local -a arguments=()

    [ -n "$process_dir" ] && [ -n "$expected_cwd" ] && [ -n "$expected_app" ] || return 1
    [ -r "$process_dir/status" ] && [ -r "$process_dir/cmdline" ] || return 1

    # RR launches this worker as root.  Requiring all four kernel UID fields
    # prevents a user-owned Python process from becoming a kill candidate even
    # if it can imitate the remaining argv/cwd evidence.
    uid_line=$(awk '$1 == "Uid:" { print $2 ":" $3 ":" $4 ":" $5; exit }' \
        "$process_dir/status" 2>/dev/null) || return 1
    [ "$uid_line" = 0:0:0:0 ] || return 1

    # Parse the NUL-delimited argv instead of substring-matching a flattened
    # command line.  The latter could accept an unrelated Python command that
    # merely carries nexus/sub_server.py as data in a later argument.
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
    # procfs appends " (deleted)" to an unlinked cwd, but those characters
    # are also legal in a real directory name.  st_nlink==0 proves that the
    # matched inode is actually unlinked and rejects that literal-name trap.
    cwd_links=$(stat -Lc '%h' -- "$process_dir/cwd" 2>/dev/null) || return 1
    [ "$cwd_links" = 0 ]
}

rr_subscription_pid_is_managed() {
    local pid="${1:-}"
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local expected_cwd=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    expected_cwd=$(readlink -f -- "$SUB_ROOT" 2>/dev/null) || return 1
    rr_subscription_process_matches "$proc_root/$pid" "$expected_cwd" \
        "$RR_LIB_DIR/nexus/sub_server.py"
}

is_subscription_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 必须核对进程身份，绝不因陈旧 PID 文件误杀其他服务。
    rr_subscription_pid_is_managed "$pid"
}

managed_subscription_pids() {
    # 状态文件可能因跨版本更新/回滚位于 /run 或旧版 /tmp，甚至已经丢失。
    # 按“受支持命令行 + RR 订阅根 cwd”双重条件扫描 /proc，避免仅凭名称
    # pkill 误伤用户进程，也确保无 PID 文件的 RR 孤儿 worker 仍可回收。
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local process_dir=""
    local pid=""
    for process_dir in "$proc_root"/[0-9]*; do
        pid="${process_dir##*/}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        rr_subscription_pid_is_managed "$pid" || continue
        printf '%s\n' "$pid" 2>/dev/null || return 0
    done
}

subscription_server_running() {
    local pid=""
    while IFS= read -r pid; do
        [ -n "$pid" ] && return 0
    done < <(managed_subscription_pids)
    return 1
}

stop_subscription_servers() {
    local pid=""
    local stopped=true
    local attempt=0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        # 扫描后立即复核完整身份，收窄退出/PID 复用窗口。
        rr_subscription_pid_is_managed "$pid" || continue
        kill "$pid" 2>/dev/null || true
    done < <(managed_subscription_pids)
    while [ "$attempt" -lt 20 ] && subscription_server_running; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    subscription_server_running && stopped=false
    rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE" \
        /run/rr-vps-subscription.pid /run/rr-vps-subscription.bind \
        /tmp/sub_server.pid /tmp/sub_server.bind
    [ "$stopped" = true ]
}

# ==========================================
# IPv4 / IPv6 模式与兼容性辅助函数


# ==========================================
# 面板防火墙辅助（rr --fw-* 子命令，端口白名单内操作）
# ==========================================
nexus_fw_known_ports() {
    # 输出白名单端口清单："port:proto:name" 每行
    load_config_with_defaults || return 1
    [ "$VL_ENABLED" = "true" ] && [ "$VL_PORT" != "0" ] && echo "${VL_PORT}:tcp:VLESS-Reality 节点"
    [ "$HY2_ENABLED" = "true" ] && [ "$HY2_PORT" != "0" ] && echo "${HY2_PORT}:udp:Hysteria2 节点"
    [ "$TU5_ENABLED" = "true" ] && [ "$TU5_PORT" != "0" ] && echo "${TU5_PORT}:udp:Tuic5 节点"
    [ "$AN_ENABLED" = "true" ] && [ "$AN_PORT" != "0" ] && echo "${AN_PORT}:tcp:AnyTLS 节点"
    # NAIVE-SUPPORT: H2/TCP 与 H3/UDP 可同端口并存。
    if [ "$NAIVE_ENABLED" = "true" ] && [ "${NAIVE_PORT:-0}" != "0" ]; then
        [ "${NAIVE_MODE:-h2}" != h3 ] && echo "${NAIVE_PORT}:tcp:NaiveProxy H2 节点"
        [ "${NAIVE_MODE:-h2}" != h2 ] && echo "${NAIVE_PORT}:udp:NaiveProxy H3 节点"
    fi
    [ "$VM_ENABLED" = "true" ] && [ "$VM_TLS_ENABLED" = "true" ] && [ "$PORT" != "0" ] && echo "${PORT}:tcp:VMess-TLS 直连节点"
    [ "${SUB_PORT:-0}" != "0" ] && echo "${SUB_PORT}:tcp:订阅服务"
    [ -n "${SSH_PORT:-22}" ] && echo "${SSH_PORT}:tcp:SSH 管理端口（保护）"
    if [ -f /etc/rr-nexus/nexus.json ]; then
        local panel_port=""
        panel_port=$(jq -r '.public_port // .port // empty' /etc/rr-nexus/nexus.json 2>/dev/null)
        [ -n "$panel_port" ] && [ "$panel_port" != "null" ] && echo "${panel_port}:tcp:RR Nexus 面板"
    fi
    return 0
}

nexus_fw_port_open() {
    # $1=port $2=proto；0=放行 1=关闭
    # 真实状态：端口实际被监听（节点协议已开启）即视为放行；
    # 防火墙 ACCEPT 规则存在也算放行（任一满足）
    case "$2" in
        tcp) ss -H -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN && return 0 ;;
        udp) ss -H -lun "sport = :$1" 2>/dev/null | grep -qE "UNCONN|ESTAB" && return 0 ;;
    esac
    iptables -C INPUT -p "$2" --dport "$1" -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1
}

nexus_fw_ports_json() {
    # 输出 JSON：白名单端口 + 状态
    local line="" port="" proto="" name="" open="0"
    local first=true
    printf '['
    while IFS=: read -r port proto name; do
        [ -n "$port" ] || continue
        nexus_fw_port_open "$port" "$proto" && open="1" || open="0"
        [ "$first" = true ] && first=false || printf ','
        printf '{"port":%s,"proto":"%s","name":"%s","open":%s}' "$port" "$proto" "$name" "$open"
    done < <(nexus_fw_known_ports)
    printf ']
'
}

nexus_fw_toggle() {
    # $1=port $2=proto；只允许白名单内端口；SSH 端口受保护不可关
    local port="$1" proto="$2" firewall_status=0
    if rr_firewall_fail_closed_quarantine_active; then
        echo '{"ok":false,"error":"firewall_quarantine_active"}'
        return 1
    fi
    is_valid_port "$port" || { echo '{"ok":false,"error":"invalid_port"}'; return 1; }
    if [ "$port" = "${SSH_PORT:-22}" ] && [ "$proto" = "tcp" ]; then
        echo '{"ok":false,"error":"ssh_port_protected"}'
        return 1
    fi
    case "$proto" in tcp|udp) ;; *) echo '{"ok":false,"error":"invalid_proto"}'; return 1; ;; esac
    local line="" p="" pr="" n=""
    local allowed=false
    while IFS=: read -r p pr n; do
        [ "$p" = "$port" ] && [ "$pr" = "$proto" ] && allowed=true
    done < <(nexus_fw_known_ports)
    [ "$allowed" = true ] || { echo '{"ok":false,"error":"not_allowed_port"}'; return 1; }
    if nexus_fw_port_open "$port" "$proto"; then
        close_protocol_firewall "$port" "$proto" || firewall_status=$?
        if [ "$firewall_status" -ne 0 ]; then
            if [ "$firewall_status" -ge 2 ]; then
                printf '{"ok":false,"error":"firewall_state_indeterminate","nodes_inactive":%s}\n' \
                    "$([ "$firewall_status" -eq 2 ] && printf true || printf false)"
            else
                echo '{"ok":false,"error":"firewall_transaction_failed"}'
            fi
            return "$firewall_status"
        fi
        echo "{\"ok\":true,\"action\":\"closed\",\"port\":$port,\"proto\":\"$proto\"}"
    else
        open_protocol_firewall "$port" "$proto" || firewall_status=$?
        if [ "$firewall_status" -ne 0 ]; then
            if [ "$firewall_status" -ge 2 ]; then
                printf '{"ok":false,"error":"firewall_state_indeterminate","nodes_inactive":%s}\n' \
                    "$([ "$firewall_status" -eq 2 ] && printf true || printf false)"
            else
                echo '{"ok":false,"error":"firewall_transaction_failed"}'
            fi
            return "$firewall_status"
        fi
        echo "{\"ok\":true,\"action\":\"opened\",\"port\":$port,\"proto\":\"$proto\"}"
    fi
    return 0
}

nexus_ver_info_json() {
    # 面板版本信息：脚本版本 + 内核版本 + 面板状态 + 出入站模式
    local sb_ver="" panel_state="未安装" panel_mode=""
    load_config_with_defaults || true
    [ -x "$SINGBOX_BIN" ] && sb_ver=$(get_singbox_version 2>/dev/null || echo "")
    if [ -f /etc/rr-nexus/nexus.json ]; then
        panel_state="已安装"
        panel_mode=$(jq -r '.mode // "unknown"' /etc/rr-nexus/nexus.json 2>/dev/null)
    fi
    printf '{"script_version":"%s","core_version":"%s","panel_state":"%s","panel_mode":"%s","entry_ip_mode":"%s","outbound_ip_mode":"%s"}' \
        "${SCRIPT_VERSION:-unknown}" "${sb_ver:-未知}" "$panel_state" "$panel_mode" \
        "${ENTRY_IP_MODE:-auto}" "${OUTBOUND_IP_MODE:-auto}"
}
