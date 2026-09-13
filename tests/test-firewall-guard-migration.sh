#!/bin/bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# Reuse only the private /run fixture and declarations, not its test cases.
# Its trap also proves that no production guard/lock path was touched.
fixture=$(awk '/^printf .*global firewall lock safety/ { exit } { print }' \
    tests/test-firewall-transaction.sh)
eval "$fixture"

reset_firewall_quarantine_mock
rr_firewall_install_fail_closed_supervisor
: > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
idle_files_before=$(stat -c '%n:%d:%i:%s:%Y:%Z' "$RR_FIREWALL_GUARD_SCRIPT" \
    "$RR_FIREWALL_SYSTEMD_DIR"/rr-firewall-quarantine-guard.{service,path,timer})
rr_firewall_install_fail_closed_supervisor || fail 'current idle guard did not stay armed'
if grep -Eq '^(daemon-reload|enable|disable|start|restart|stop|reset-failed)( |$)' \
        "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"; then
    fail 'current idle guard unnecessarily mutated systemd state'
fi
[ "$idle_files_before" = "$(stat -c '%n:%d:%i:%s:%Y:%Z' \
    "$RR_FIREWALL_GUARD_SCRIPT" \
    "$RR_FIREWALL_SYSTEMD_DIR"/rr-firewall-quarantine-guard.{service,path,timer})" ] || \
    fail 'current idle guard unnecessarily replaced an artifact'
original_systemctl=$(declare -f systemctl)
eval "${original_systemctl/systemctl ()/guard_original_systemctl ()}"
compiled_legacy="$RR_FIREWALL_TEST_ROOT/compiled-legacy"
failed_path="$RR_FIREWALL_TEST_ROOT/failed-path"
failed_service="$RR_FIREWALL_TEST_ROOT/failed-service"
systemctl() {
    if [ -e "$failed_service" ]; then
        if [ "${1:-}" = reset-failed ] && \
           [ "${2:-}" = rr-firewall-quarantine-guard.service ]; then
            printf '%s\n' "$*" >> "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
            rm -f "$failed_service"
            return
        elif [ "${1:-}" = show ] && \
             [ "${4:-}" = rr-firewall-quarantine-guard.service ]; then
            case "${2:-}" in
                --property=ActiveState) printf 'failed\n'; return ;;
                --property=Result) printf 'exit-code\n'; return ;;
            esac
        fi
    fi
    if [ -e "$failed_path" ]; then
        if [ "${1:-}" = reset-failed ] && \
           [ "${2:-}" = rr-firewall-quarantine-guard.path ]; then
            printf '%s\n' "$*" >> "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
            rm -f "$failed_path"
            return
        elif [ "${1:-}" = show ] && \
             [ "${4:-}" = rr-firewall-quarantine-guard.path ]; then
            case "${2:-}" in
                --property=ActiveState) printf 'failed\n'; return ;;
                --property=Result) printf 'unit-start-limit-hit\n'; return ;;
            esac
        fi
    fi
    if [ "${1:-}" = daemon-reload ]; then
        rm -f "$compiled_legacy"
    elif [ -e "$compiled_legacy" ] && [ "${1:-}" = show ] && \
         [ "${4:-}" = rr-firewall-quarantine-guard.service ]; then
        case "${2:-}" in
            --property=RemainAfterExit|--property=Restart)
                printf 'no\n'
                return ;;
        esac
    fi
    guard_original_systemctl "$@"
}

# SIGKILL after atomic publication but before daemon-reload leaves current
# disk bytes and legacy compiled state.  Resume must complete the reload.
: > "$compiled_legacy"
rr_firewall_install_fail_closed_supervisor || \
    fail 'pre-reload interrupted migration rejected'
[ ! -e "$compiled_legacy" ] || fail 'interrupted migration did not reload'
rr_firewall_quarantine_supervisor_effective || \
    fail 'interrupted migration did not establish current effective identity'
systemctl is-active --quiet rr-firewall-quarantine-guard.service && \
    fail 'clear migration latched a service without a marker'

# A failed current watcher does not qualify for the idle shortcut.  Its
# actual failed state must be reset and its durable watcher rearmed.
: > "$failed_path"
rm -f "$RR_FIREWALL_TEST_ROOT/systemctl-state/active/rr-firewall-quarantine-guard.path"
: > "$RR_FIREWALL_TEST_SYSTEMCTL_LOG"
rr_firewall_install_fail_closed_supervisor || fail 'failed current watcher did not recover'
[ ! -e "$failed_path" ] || fail 'failed current watcher was skipped'
grep -qx 'reset-failed rr-firewall-quarantine-guard.path' \
    "$RR_FIREWALL_TEST_SYSTEMCTL_LOG" || fail 'real path failure was not reset'
systemctl is-active --quiet rr-firewall-quarantine-guard.path || \
    fail 'recovered current path watcher did not reactivate'

# `! is-active` also matches failed, so idle qualification must inspect the
# service's positive inactive state before skipping failure recovery.
: > "$failed_service"
rr_firewall_install_fail_closed_supervisor || fail 'failed service was skipped as idle'
[ ! -e "$failed_service" ] || fail 'failed service was not reset'

# A marker must never be cleared, reinterpreted, or lose its ingress gate
# merely because its canonical supervisor is being upgraded.
printf '%s\n' firewall-inflight-v1 > "$RR_FIREWALL_QUARANTINE_FILE"
chmod 600 "$RR_FIREWALL_QUARANTINE_FILE"
before=$(sha256sum "$RR_FIREWALL_QUARANTINE_FILE")
rr_firewall_render_quarantine_guard_service_legacy > \
    "$RR_FIREWALL_SYSTEMD_DIR/rr-firewall-quarantine-guard.service"
: > "$compiled_legacy"
rr_firewall_install_fail_closed_supervisor || fail 'marked legacy migration rejected'
[ "$before" = "$(sha256sum "$RR_FIREWALL_QUARANTINE_FILE")" ] || \
    fail 'guard migration changed the transaction marker'
rr_firewall_activate_quarantine_supervisor || fail 'marked migration did not activate'
rr_firewall_deactivate_quarantine_retry || fail 'marked migration did not quiesce'
rm -f "$RR_FIREWALL_QUARANTINE_FILE"
rr_firewall_activate_idle_quarantine_supervisor || fail 'idle watcher did not rearm'
printf '%s\n' 'guard migration, interrupted reload, and marker preservation passed'
