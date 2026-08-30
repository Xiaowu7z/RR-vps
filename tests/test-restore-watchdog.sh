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

printf '%s\n' '[1/8] service gate validates exact durable markers'
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

printf '%s\n' '[2/8] live owner gate closes as soon as its lock is released'
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

printf '%s\n' '[3/8] watcher exits cleanly when no transaction is active'
rr_restore_watch_active
armed_stage="$RR_BACKUP_WORK_DIR/restore.armed"
install -d -m 700 "$armed_stage"
rr_restore_publish_marker "$RR_RESTORE_WATCH_REQUEST" "$armed_stage"
rr_restore_watch_active
[ ! -e "$armed_stage" ] || { echo 'Pre-active decrypted stage was left behind.' >&2; exit 1; }

printf '%s\n' '[4/8] watcher blocks on the update lock before recovery'
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

printf '%s\n' '[5/8] recovery and watchdog units install bounded gates'
(
    RR_RESTORE_SYSTEMD_DIR="$test_root/systemd"
    systemctl() {
        case "$*" in
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
        dropin="$RR_RESTORE_SYSTEMD_DIR/${unit}.d/40-rr-restore-gate.conf"
        [ -f "$dropin" ] && [ ! -L "$dropin" ]
        grep -Fq 'if [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]' "$dropin"
        grep -Fq 'exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate' "$dropin"
    done
)
(
    regeneration_root="$test_root/regeneration"
    CONFIG_FILE="$regeneration_root/argo_vmess.conf"
    NEXUS_CONFIG_FILE="$regeneration_root/nexus.json"
    NEXUS_SERVICE_FILE="$regeneration_root/rr-nexus.service"
    RR_SINGBOX_SERVICE_FILE="$regeneration_root/sing-box.service"
    RR_HEALTH_SERVICE_FILE="$regeneration_root/argo-rr-health.service"
    RR_HEALTH_TIMER_FILE="$regeneration_root/argo-rr-health.timer"
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
    manager_reloaded=false
    systemctl() {
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
                esac
                printf 'load:%s\n' "${*: -1}" >> "$operation_log"
                ;;
            *) return 0 ;;
        esac
    }
    rr_restore_regenerate_runtime_files
    expected_regeneration=$(printf '%s\n' write-singbox write-health write-nexus reload \
        'load:sing-box.service' 'load:argo-rr-health.service' \
        'load:argo-rr-health.timer' 'load:rr-nexus.service')
    [ "$(cat "$operation_log")" = "$expected_regeneration" ] || {
        echo 'Trusted unit regeneration did not reload and prove every unit in order.' >&2
        exit 1
    }
)
grep -Fq -- '--watch-restore)' rr
grep -Fq -- '--restore-service-gate)' rr
grep -Fq 'rr-restore-watchdog.service' modules/95-install.sh
grep -Fq '40-rr-restore-gate.conf' modules/95-install.sh

printf '%s\n' '[6/8] restore systemd state is explicit and query failures fail closed'
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
    : > "$cloud_rollback/cloudflared_service_was_present"
    : > "$cloud_rollback/cloudflared_was_running"
    chmod 600 "$cloud_rollback/complete" \
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
    rr_restore_restore_nginx() { return 0; }
    rr_restore_apply_cloudflared_snapshot() { return 0; }
    rr_restore_restore_firewall_snapshot() { return 0; }
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
[ "$(grep -c 'rr_restore_unit_load_state_read cloudflared cloud_load_state' \
    modules/55-resilience.sh)" -ge 2 ]

printf '%s\n' '[7/8] terminal phases are durable and can never cross back into rollback'
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

    abort_stage="$RR_BACKUP_WORK_DIR/restore.abort"
    install -d -m 700 "$abort_stage" "$abort_stage/rollback"
    rr_restore_write_phase "$abort_stage" prepared
    rr_restore_publish_marker "$RR_RESTORE_ACTIVE" "$abort_stage"
    rr_restore_resume_frozen_writers() { return 0; }
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
)

printf '%s\n' '[8/8] SIGKILL releases the lock and dispatches phase rollback'
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
