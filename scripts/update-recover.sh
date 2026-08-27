#!/bin/bash
# Standalone RR-vps transaction recovery.  The core installer copies this file
# outside the replaceable runtime before it starts mutating /usr/local/lib/rr.

set -u

RR_TX_ROOT="/var/lib/rr-update"
RR_ACTIVE_TX="${RR_TX_ROOT}/active"
RR_LIB_DIR="/usr/local/lib/rr"
RR_LAUNCHER="/usr/local/bin/rr"

rr_recover_log() {
    printf '[RR-vps recovery] %s\n' "$*" >&2
    logger -t rr-update-recovery "$*" 2>/dev/null || true
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
    local tx="$1" reason="${2:-automatic recovery}" failed_runtime=""
    RR_BACKUP="$tx/backup"
    [ -d "$RR_BACKUP" ] || { rr_recover_log "transaction backup is missing: $tx"; return 1; }

    rr_recover_log "$reason; restoring transaction $(basename "$tx")"
    systemctl stop sing-box rr-nexus >/dev/null 2>&1 || true
    pkill -f 'subscription_server\.py' >/dev/null 2>&1 || true

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

    local failed=false
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

    rr_verify_restored_state || failed=true
    systemctl daemon-reload >/dev/null 2>&1 || failed=true
    if [ -f "$RR_BACKUP/health_timer_was_enabled" ]; then
        systemctl enable argo-rr-health.timer >/dev/null 2>&1 || failed=true
        systemctl start --no-block argo-rr-health.timer >/dev/null 2>&1 || true
    else
        systemctl disable argo-rr-health.timer >/dev/null 2>&1 || true
        systemctl stop --no-block argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    if [ -f "$RR_BACKUP/singbox_was_running" ]; then
        systemctl restart --no-block sing-box >/dev/null 2>&1 || failed=true
    else
        systemctl stop --no-block sing-box >/dev/null 2>&1 || true
    fi
    if [ -f "$RR_BACKUP/nexus_was_running" ]; then
        systemctl restart --no-block rr-nexus >/dev/null 2>&1 || failed=true
    else
        systemctl stop --no-block rr-nexus >/dev/null 2>&1 || true
    fi
    if { [ -f "$RR_BACKUP/subscription_was_running" ] || [ -f "$RR_BACKUP/argo_was_running" ]; } && \
       [ -f /etc/systemd/system/argo-rr-health.service ]; then
        # Recovery runs before network.target. Queue the network-dependent
        # health pass instead of synchronously waiting and creating an ordering
        # cycle during boot.
        systemctl start --no-block argo-rr-health.service >/dev/null 2>&1 || true
    fi

    if [ "$failed" = true ]; then
        printf 'recovery_failed\n' > "$tx/phase"
        rr_recover_log "recovery was incomplete; evidence retained at $tx"
        return 1
    fi
    printf 'rolled_back\n' > "$tx/phase"
    rm -f -- "$RR_ACTIVE_TX"
    rr_recover_log "rollback completed"
    if [ -f "$RR_BACKUP/runtime_did_not_exist" ]; then
        systemctl disable rr-update-recovery.service >/dev/null 2>&1 || true
        rm -f -- /etc/systemd/system/rr-update-recovery.service /usr/local/sbin/rr-update-recover
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$RR_TX_ROOT"
    fi
}

main() {
    local mode="${1:-recover}" tx="" phase=""
    case "$mode" in recover|rollback|status) ;; *) echo "usage: rr-update-recover [recover|rollback|status]" >&2; return 2 ;; esac
    tx=$(rr_transaction_path) || {
        [ "$mode" = status ] && printf '{"active":false}\n'
        return 0
    }
    phase=$(head -n 1 "$tx/phase" 2>/dev/null || true)
    if [ "$mode" = status ]; then
        printf '{"active":true,"transaction":"%s","phase":"%s"}\n' "$tx" "$phase"
        return 0
    fi
    if [ "$mode" = recover ] && { [ "$phase" = snapshotting ] || [ "$phase" = prepared ]; }; then
        printf 'aborted\n' > "$tx/phase"
        rm -f -- "$RR_ACTIVE_TX"
        rr_recover_log "stale pre-mutation transaction discarded; runtime was never switched"
        return 0
    fi
    if [ "$mode" = recover ] && { [ "$phase" = committed ] || [ "$phase" = rolled_back ]; }; then
        return 0
    fi
    rr_restore_transaction "$tx" "$([ "$mode" = rollback ] && printf 'manual rollback requested' || printf 'interrupted update detected')"
}

main "$@"
