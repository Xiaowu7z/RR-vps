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
RR_QUARANTINE_FILE="${RR_QUARANTINE_FILE:-${RR_TX_ROOT}/subscription-quarantine}"
RR_QUARANTINE_UNIT="${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}"
RR_QUARANTINE_READY="${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}"
RR_RECOVERY_SELF="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"
RR_UPDATE_EXTERNAL_HELPER="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
RR_IPV6_STATE_FILE="${RR_IPV6_STATE_FILE:-/proc/net/if_inet6}"
RR_HEALTH_SERVICE_FILE="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
RR_UPDATE_LOCK_FILE="${RR_UPDATE_LOCK_FILE:-/run/rr-vps/locks/update.lock}"
RR_UPDATE_MAINTENANCE_FILE="${RR_UPDATE_MAINTENANCE_FILE:-/run/rr-vps/update-maintenance}"
RR_QUARANTINE_COMMENT="rr-vps unsafe rollback subscription quarantine"
RR_UPDATE_RECOVERY_LOCK_FD=""

rr_recover_log() {
    printf '[RR-vps recovery] %s\n' "$*" >&2
    logger -t rr-update-recovery "$*" 2>/dev/null || true
}

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

rr_update_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" fd_identity=""
    local shell_pid="${BASHPID:-$$}"
    local fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [[ "$fd_identity" == *:0:0:600:1 ]]
}

rr_managed_subscription_pids() {
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local subscription_root="${RR_SUB_ROOT:-/tmp/sub_server}"
    local expected_cwd=""
    local process_dir=""
    local pid=""
    local cmdline=""
    local process_cwd=""
    expected_cwd=$(readlink -f "$subscription_root" 2>/dev/null) || return 0
    for process_dir in "$proc_root"/[0-9]*; do
        [ -r "$process_dir/cmdline" ] || continue
        pid="${process_dir##*/}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        cmdline=$(tr '\0' ' ' < "$process_dir/cmdline" 2>/dev/null) || continue
        [[ "$cmdline" == *"python3 -m http.server"* || "$cmdline" == *"nexus/sub_server.py"* ]] || continue
        process_cwd=$(readlink -f "$process_dir/cwd" 2>/dev/null) || continue
        [ "$process_cwd" = "$expected_cwd" ] || continue
        printf '%s\n' "$pid"
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
    local unit="$1" wanted="$2" attempt=0
    while [ "$attempt" -lt 50 ]; do
        if [ "$wanted" = active ]; then
            systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        else
            systemctl is-active --quiet "$unit" 2>/dev/null || return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

rr_clear_update_maintenance_marker() {
    local tx="$1" owner="" parent=""
    [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || return 0
    [ -f "$RR_UPDATE_MAINTENANCE_FILE" ] && [ ! -L "$RR_UPDATE_MAINTENANCE_FILE" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' "$RR_UPDATE_MAINTENANCE_FILE" 2>/dev/null)" = 0:0:600:1 ] || return 1
    owner=$(head -n 1 "$RR_UPDATE_MAINTENANCE_FILE" 2>/dev/null) || return 1
    [ "$owner" = "$tx" ] || return 1
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
    "$RR_UPDATE_EXTERNAL_HELPER" restore "$backup" --tx-root "$RR_TX_ROOT" || return 1
    "$RR_UPDATE_EXTERNAL_HELPER" verify "$backup" --tx-root "$RR_TX_ROOT"
}

rr_restore_unit_state() {
    local unit="$1" active_marker="$2" enabled_marker="$3"
    if [ -f "$enabled_marker" ]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
        systemctl is-enabled --quiet "$unit" 2>/dev/null || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl is-enabled --quiet "$unit" 2>/dev/null && return 1
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
    systemctl start argo-rr-health.service >/dev/null 2>&1 &
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

rr_restore_recorded_writer_state() {
    local backup="$1" subscription_policy="${2:-normal}" failed=false
    if [ ! -f "$backup/writer_state_complete" ]; then
        if [ -f "$backup/health_timer_was_enabled" ]; then
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
        [ -x "$RR_LAUNCHER" ] && timeout 30 env RR_UPDATE_LOCK_HELD=1 \
            "$RR_LAUNCHER" --health-check >/dev/null 2>&1 || failed=true
        rr_subscription_running || failed=true
    else
        rr_stop_subscription_servers || failed=true
        rr_subscription_running && failed=true
    fi
    rr_restore_unit_state sing-box "$backup/singbox_was_running" \
        "$backup/singbox_was_enabled" || failed=true
    rr_restore_unit_state rr-nexus "$backup/nexus_was_running" \
        "$backup/nexus_was_enabled" || failed=true
    rr_restore_unit_state argo-rr-health.timer "$backup/health_timer_was_running" \
        "$backup/health_timer_was_enabled" || failed=true
    if [ -f "$backup/health_service_was_running" ]; then
        rr_restart_health_service_bounded || failed=true
    fi
    [ "$failed" = false ]
}

rr_acquire_update_lock() {
    [ "${RR_UPDATE_LOCK_HELD:-0}" != 1 ] || return 0
    rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE" || {
        rr_recover_log "unsafe shared update lock file"
        return 1
    }
    exec {RR_UPDATE_RECOVERY_LOCK_FD}>>"$RR_UPDATE_LOCK_FILE" || return 1
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
    local tx="${1:-}" canonical=""
    [ -n "$tx" ] && [ -d "$tx" ] && [ ! -L "$tx" ] || return 1
    [ "$(dirname "$tx")" = "$RR_TX_ROOT/transactions" ] || return 1
    canonical=$(readlink -f "$tx" 2>/dev/null) || return 1
    [ "$canonical" = "$tx" ]
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
    if [ -e "$RR_QUARANTINE_FILE" ]; then
        rr_quarantine_marker_read || return 1
        if [ "$RR_QUARANTINE_RESUME" = 1 ]; then
            : > "$backup/subscription_was_running" || return 1
        else
            rm -f -- "$backup/subscription_was_running" || return 1
        fi
    fi
    rr_write_private_value "$backup/rollback-metadata-complete" 1
}

rr_quarantine_marker_read() {
    local line="" key="" value="" seen_format=0 seen_state=0 seen_version=0 seen_port=0 seen_resume=0
    RR_QUARANTINE_STATE=""
    RR_QUARANTINE_VERSION=""
    RR_QUARANTINE_PORT=""
    RR_QUARANTINE_RESUME=""
    [ -f "$RR_QUARANTINE_FILE" ] && [ ! -L "$RR_QUARANTINE_FILE" ] || return 1
    [ "$(stat -c '%u' "$RR_QUARANTINE_FILE" 2>/dev/null)" = 0 ] || return 1
    [ "$(stat -c '%a' "$RR_QUARANTINE_FILE" 2>/dev/null)" = 600 ] || return 1
    [ "$(stat -c '%s' "$RR_QUARANTINE_FILE" 2>/dev/null)" -le 512 ] || return 1
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
    done < "$RR_QUARANTINE_FILE"
    [ "$seen_format" -eq 1 ] && [ "$seen_state" -eq 1 ] &&
        [ "$seen_version" -eq 1 ] && [ "$seen_port" -eq 1 ] && [ "$seen_resume" -eq 1 ]
}

rr_quarantine_write_marker() {
    local state="$1" version="$2" port="$3" resume="${4:-0}" temporary=""
    case "$state" in quarantined|degraded) ;; *) return 1 ;; esac
    if [ "$version" != unknown ]; then rr_semver_is_valid "$version" || return 1; fi
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" = 0 ] || { [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ]; } || return 1
    case "$resume" in 0|1) ;; *) return 1 ;; esac
    mkdir -p "$RR_TX_ROOT" || return 1
    chmod 700 "$RR_TX_ROOT" || return 1
    temporary="${RR_QUARANTINE_FILE}.tmp.$$"
    (umask 077; {
        printf 'format=1\n'
        printf 'state=%s\n' "$state"
        printf 'target_version=%s\n' "$version"
        printf 'port=%s\n' "$((10#$port))"
        printf 'resume_subscription=%s\n' "$resume"
    } > "$temporary") && chmod 600 "$temporary" && mv -f "$temporary" "$RR_QUARANTINE_FILE"
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

rr_quarantine_write_unit() {
    local temporary=""
    [[ "$RR_RECOVERY_SELF" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    mkdir -p "$(dirname "$RR_QUARANTINE_UNIT")" || return 1
    temporary="${RR_QUARANTINE_UNIT}.tmp.$$"
    cat > "$temporary" <<EOF
[Unit]
Description=RR-vps unsafe rollback subscription quarantine
After=local-fs.target
Before=argo-rr-health.service
ConditionPathExists=${RR_QUARANTINE_FILE}

[Service]
Type=notify
NotifyAccess=main
ExecStart=${RR_RECOVERY_SELF} quarantine-guard
Restart=always
RestartSec=1
TimeoutStartSec=15
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$temporary" && mv -f "$temporary" "$RR_QUARANTINE_UNIT"
}

rr_quarantine_guard() {
    local port=0 marker="$RR_QUARANTINE_FILE" ready="$RR_QUARANTINE_READY"
    rr_quarantine_marker_read || { rr_recover_log "subscription quarantine marker is invalid"; return 1; }
    port="$RR_QUARANTINE_PORT"
    rr_stop_subscription_servers || { rr_recover_log "could not stop the legacy subscription process"; return 1; }
    if [ "$port" != 0 ]; then
        rr_quarantine_add_firewall_rules "$port" ||
            rr_recover_log "raw firewall quarantine unavailable; the port reservation remains active"
    fi
    mkdir -p "$(dirname "$ready")" || return 1
    exec python3 - "$port" "$ready" "$marker" "${RR_PROC_ROOT:-/proc}" "${RR_SUB_ROOT:-/tmp/sub_server}" <<'PY'
import errno
import os
import signal
import socket
import sys
import time

port = int(sys.argv[1])
ready, marker, proc_root, subscription_root = sys.argv[2:]
sockets = []

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
            with open(os.path.join(process, "cmdline"), "rb") as handle:
                command = handle.read(8192).replace(b"\0", b" ")
            if b"python3 -m http.server" not in command and b"nexus/sub_server.py" not in command:
                continue
            if os.path.realpath(os.path.join(process, "cwd")) != expected:
                continue
            os.kill(int(entry), signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
            continue

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

while os.path.isfile(marker):
    stop_managed_servers()
    time.sleep(0.05)
PY
}

rr_suspend_subscription_quarantine() {
    [ -e "$RR_QUARANTINE_FILE" ] || return 0
    rr_quarantine_marker_read || return 1
    systemctl stop rr-subscription-quarantine.service >/dev/null 2>&1 || true
    rm -f -- "$RR_QUARANTINE_READY"
    return 0
}

rr_clear_subscription_quarantine() {
    local port=0 marker_present=false failed=false
    if [ -e "$RR_QUARANTINE_FILE" ]; then
        marker_present=true
        rr_quarantine_marker_read || return 1
        port="$RR_QUARANTINE_PORT"
    fi
    systemctl disable --now rr-subscription-quarantine.service >/dev/null 2>&1 || true
    rm -f -- "$RR_QUARANTINE_READY"
    if [ "$marker_present" = true ]; then
        rr_quarantine_remove_firewall_rules "$port" || failed=true
    fi
    rm -f -- "$RR_QUARANTINE_UNIT" || failed=true
    [ "$failed" = false ] || return 1
    rm -f -- "$RR_QUARANTINE_FILE" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
}

rr_activate_subscription_quarantine() {
    local version="$1" port="$2" resume="${3:-0}" state=quarantined attempt=0
    rr_stop_subscription_servers || state=degraded
    if [ -e "$RR_QUARANTINE_FILE" ]; then
        rr_quarantine_marker_read || return 1
        systemctl stop rr-subscription-quarantine.service >/dev/null 2>&1 || true
        rr_quarantine_remove_firewall_rules "$RR_QUARANTINE_PORT" || state=degraded
    fi
    [ "$port" != 0 ] || state=degraded
    rr_quarantine_write_marker "$state" "$version" "$port" "$resume" || return 1
    rr_quarantine_write_unit || return 1
    rm -f -- "$RR_QUARANTINE_READY"
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable --now rr-subscription-quarantine.service >/dev/null 2>&1 || state=degraded
    while [ "$attempt" -lt 50 ] && [ ! -f "$RR_QUARANTINE_READY" ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    [ -f "$RR_QUARANTINE_READY" ] || state=degraded
    if [ "$port" != 0 ]; then
        rr_quarantine_add_firewall_rules "$port" || state=degraded
    fi
    rr_quarantine_write_marker "$state" "$version" "$port" "$resume" || return 1
    [ "$state" = quarantined ] || rr_recover_log "legacy subscription quarantine is DEGRADED; keep this host out of production"
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
    local tx=""
    [ -r "$RR_ACTIVE_TX" ] || return 1
    tx=$(head -n 1 "$RR_ACTIVE_TX" 2>/dev/null)
    case "$tx" in
        "$RR_TX_ROOT"/transactions/*) [ -d "$tx" ] || return 1 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$tx"
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
    [ -d "$RR_BACKUP" ] || { rr_recover_log "transaction backup is missing: $tx"; return 1; }

    rr_recover_log "$reason; restoring transaction $(basename "$tx")"
    systemctl stop sing-box rr-nexus >/dev/null 2>&1 || true
    rr_stop_subscription_servers || subscription_stop_failed=true

    if [ -d "$tx/old-runtime" ]; then
        if [ -e "$RR_LIB_DIR" ]; then
            failed_runtime="$tx/failed-runtime-$(date +%s)"
            mv "$RR_LIB_DIR" "$failed_runtime" || return 1
        fi
        mv "$tx/old-runtime" "$RR_LIB_DIR" || {
            [ -n "$failed_runtime" ] && [ -e "$failed_runtime" ] && mv "$failed_runtime" "$RR_LIB_DIR" 2>/dev/null || true
            return 1
        }
    elif [ -f "$RR_BACKUP/runtime_did_not_exist" ]; then
        rm -rf -- "$RR_LIB_DIR" || return 1
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
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "internal or external rollback failed; writers remain frozen and evidence is retained at $tx"
        return 1
    fi

    if ! rr_apply_rollback_subscription_policy "$tx"; then
        failed=true
    fi
    subscription_policy=$(head -n 1 "$tx/rollback-subscription-status" 2>/dev/null || printf degraded)
    case "$subscription_policy" in normal|quarantined|degraded) ;; *) subscription_policy=degraded; failed=true ;; esac
    if [ "$failed" = true ]; then
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "rollback subscription policy failed; writers remain frozen and evidence is retained at $tx"
        return 1
    fi
    rr_restore_recorded_writer_state "$RR_BACKUP" "$subscription_policy" || failed=true

    if [ "$failed" = true ]; then
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "recovery was incomplete; evidence retained at $tx"
        return 1
    fi
    if [ "$subscription_policy" != normal ]; then
        rr_recovery_write_phase "$tx" rolled_back_degraded || return 1
        if ! rr_clear_update_maintenance_marker "$tx"; then
            rr_recovery_write_phase "$tx" recovery_failed || true
            rr_recover_log "maintenance marker cleanup failed; evidence retained at $tx"
            return 1
        fi
        rm -f -- "$RR_ACTIVE_TX"
        sync -f "$RR_TX_ROOT" >/dev/null 2>&1 || true
        rr_recover_log "rollback completed in DEGRADED mode: legacy public subscription is quarantined; upgrade to ${RR_SUBSCRIPTION_SAFE_VERSION}+ before re-enabling it"
        return 3
    fi
    rr_recovery_write_phase "$tx" rolled_back || return 1
    if ! rr_clear_update_maintenance_marker "$tx"; then
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "maintenance marker cleanup failed; evidence retained at $tx"
        return 1
    fi
    rm -f -- "$RR_ACTIVE_TX"
    sync -f "$RR_TX_ROOT" >/dev/null 2>&1 || true
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
    local mode="${1:-recover}" argument="${2:-}" tx="" phase="" format_state=0 quarantine_json='{"active":false}'
    case "$mode" in
        recover|rollback|status|snapshot-metadata|apply-rollback-policy|suspend-quarantine|clear-quarantine|quarantine-guard) ;;
        *) echo "usage: rr-update-recover [recover|rollback|status|snapshot-metadata TX|apply-rollback-policy TX|suspend-quarantine|clear-quarantine|quarantine-guard]" >&2; return 2 ;;
    esac
    case "$mode" in
        snapshot-metadata) [ -n "$argument" ] || return 2; rr_snapshot_rollback_metadata "$argument"; return ;;
        apply-rollback-policy) [ -n "$argument" ] || return 2; rr_apply_rollback_subscription_policy "$argument"; return ;;
        suspend-quarantine) rr_suspend_subscription_quarantine; return ;;
        clear-quarantine) rr_clear_subscription_quarantine; return ;;
        quarantine-guard) rr_quarantine_guard; return ;;
    esac
    if [ "$mode" = recover ] || [ "$mode" = rollback ]; then
        rr_acquire_update_lock || return 1
    fi
    if [ -e "$RR_QUARANTINE_FILE" ]; then
        if rr_quarantine_marker_read; then
            quarantine_json=$(printf '{"active":true,"state":"%s","target_version":"%s","port":%s,"resume_subscription":%s}' \
                "$RR_QUARANTINE_STATE" "$RR_QUARANTINE_VERSION" "$RR_QUARANTINE_PORT" "$RR_QUARANTINE_RESUME")
        else
            quarantine_json='{"active":true,"state":"invalid","target_version":"unknown","port":0,"resume_subscription":0}'
        fi
    fi
    tx=$(rr_transaction_path) || {
        [ "$mode" = status ] && printf '{"active":false,"subscription_quarantine":%s}\n' "$quarantine_json"
        return 0
    }
    phase=$(head -n 1 "$tx/phase" 2>/dev/null || true)
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
        case "$phase" in committed|rolled_back|rolled_back_degraded) ;; *) rr_recovery_write_phase "$tx" recovery_failed || true ;; esac
        rr_recover_log "transaction format marker is unsafe; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && [ "$phase" = state_recorded ]; then
        if rr_recovery_write_phase "$tx" aborted && \
           rr_clear_update_maintenance_marker "$tx"; then
            rm -f -- "$RR_ACTIVE_TX"
            sync -f "$RR_TX_ROOT" >/dev/null 2>&1 || true
            rr_recover_log "stale state-record transaction discarded; no service had been stopped"
            return 0
        fi
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "state-record recovery failed; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && \
       { [ "$phase" = freezing ] || [ "$phase" = snapshotting ] || [ "$phase" = prepared ]; }; then
        RR_BACKUP="$tx/backup"
        if rr_restore_recorded_writer_state "$RR_BACKUP" normal && \
           rr_recovery_write_phase "$tx" aborted && \
           rr_clear_update_maintenance_marker "$tx"; then
            rm -f -- "$RR_ACTIVE_TX"
            sync -f "$RR_TX_ROOT" >/dev/null 2>&1 || true
            rr_recover_log "stale pre-mutation transaction discarded; original service state restored"
            return 0
        fi
        rr_recovery_write_phase "$tx" recovery_failed || true
        rr_recover_log "pre-mutation service recovery failed; active transaction and evidence retained at $tx"
        return 1
    fi
    if [ "$mode" = recover ] && \
       { [ "$phase" = committed ] || [ "$phase" = rolled_back ] || [ "$phase" = rolled_back_degraded ]; }; then
        if rr_clear_update_maintenance_marker "$tx"; then
            return 0
        fi
        rr_recover_log "terminal transaction marker cleanup failed; terminal phase and evidence retained at $tx"
        return 1
    fi
    rr_restore_transaction "$tx" "$([ "$mode" = rollback ] && printf 'manual rollback requested' || printf 'interrupted update detected')"
}

if [ "${RR_UPDATE_RECOVER_SOURCE_ONLY:-0}" != 1 ]; then
    main "$@"
fi
