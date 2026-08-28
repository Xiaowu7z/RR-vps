#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source modules/55-resilience.sh

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

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

stage="$RR_BACKUP_WORK_DIR/restore.good"
other_stage="$RR_BACKUP_WORK_DIR/restore.other"
install -d -m 700 "$stage" "$other_stage"

printf '%s\n' '[1/6] service gate validates exact durable markers'
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

printf '%s\n' '[2/6] live owner gate closes as soon as its lock is released'
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

printf '%s\n' '[3/6] watcher exits cleanly when no transaction is active'
rr_restore_watch_active
armed_stage="$RR_BACKUP_WORK_DIR/restore.armed"
install -d -m 700 "$armed_stage"
rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$armed_stage"
rr_restore_watch_active
[ ! -e "$armed_stage" ] || { echo 'Pre-active decrypted stage was left behind.' >&2; exit 1; }

printf '%s\n' '[4/6] watcher blocks on the update lock before recovery'
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

printf '%s\n' '[5/6] recovery and watchdog units install bounded gates'
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/systemd"
    systemctl() { return 0; }
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
        dropin="$RR_RESTORE_SYSTEMD_DIR/${unit}.d/40-rr-restore-gate.conf"
        [ -f "$dropin" ] && [ ! -L "$dropin" ]
        grep -Fq 'if [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]' "$dropin"
        grep -Fq 'exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' "$dropin"
    done
)
grep -Fq -- '--watch-restore)' rr
grep -Fq -- '--restore-service-gate)' rr
grep -Fq 'rr-restore-watchdog.service' modules/95-install.sh
grep -Fq '40-rr-restore-gate.conf' modules/95-install.sh

printf '%s\n' '[6/6] SIGKILL releases the lock and dispatches phase rollback'
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
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
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
