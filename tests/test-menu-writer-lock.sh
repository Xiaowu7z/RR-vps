#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-menu-writer-lock.XXXXXX)
LOCK_HOLDER_PID=""

cleanup() {
    if [ -n "$LOCK_HOLDER_PID" ]; then
        : > "$TEST_ROOT/release-holder"
        kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
        wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'menu writer lock regression: FAIL: %s\n' "$*" >&2
    exit 1
}

[ "${EUID:-$(id -u)}" -eq 0 ] || fail 'test must run as root'

# Load the production lock, health and menu implementations.  The individual
# menu callbacks are replaced below with observable stubs; dispatch and lock
# ownership remain production code.
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/55-resilience.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/60-update.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/99-menus.sh"

RR_RESTORE_LOCK_FILE="$TEST_ROOT/locks/update.lock"
RR_LEGACY_UPDATE_LOCK_FILE="$TEST_ROOT/legacy/rr-update.lock"
RR_LEGACY_UPDATE_BRIDGE_FILE="$TEST_ROOT/bridge/legacy-update-bridge"
RR_RESTORE_LIVE_LOCK_FILE="$TEST_ROOT/locks/restore-live.lock"
mkdir -p "$(dirname "$RR_LEGACY_UPDATE_LOCK_FILE")"
: > "$RR_LEGACY_UPDATE_LOCK_FILE"
chmod 0644 "$RR_LEGACY_UPDATE_LOCK_FILE"
install -d -m 700 "$(dirname "$RR_LEGACY_UPDATE_BRIDGE_FILE")"
printf '%s\n' "$RR_LEGACY_UPDATE_BRIDGE_VALUE" > \
    "$RR_LEGACY_UPDATE_BRIDGE_FILE"
chmod 0600 "$RR_LEGACY_UPDATE_BRIDGE_FILE"
rr_secure_lock_prepare "$RR_RESTORE_LOCK_FILE" || \
    fail 'could not prepare the production shared lock fixture'

CONFIG_FILE="$TEST_ROOT/argo_vmess.conf"
: > "$CONFIG_FILE"
SCRIPT_VERSION=7.2.0
UPDATE_AVAILABLE=false
UPDATE_CHECK_STATE=latest
SB_STATUS=stub
CF_STATUS=stub
AUTO_STATUS=stub
SCRIPT_VER_STATUS=stub
IP_ENTRY_STATUS=stub
IP_OUTBOUND_STATUS=stub
RED="" GREEN="" YELLOW="" CYAN="" PURPLE="" WHITE="" RESET=""

CALLBACK_LOG="$TEST_ROOT/callbacks.log"
HEALTH_LOG="$TEST_ROOT/health.log"
: > "$CALLBACK_LOG"
: > "$HEALTH_LOG"

check_update() { UPDATE_AVAILABLE=false; }
check_status() { :; }
clear() { :; }
ensure_runtime_health() {
    printf 'health:%s\n' "${RR_UPDATE_LOCK_HELD:-0}" >> "$HEALTH_LOG"
}
record_callback() { printf '%s\n' "$1" >> "$CALLBACK_LOG"; }
install_main() { record_callback install_main; }
change_cdn() { record_callback change_cdn; }
refresh_argo() { record_callback refresh_argo; }
install_f2b() { record_callback install_f2b; }
toggle_auto_update() { record_callback toggle_auto_update; }
protocol_menu() { record_callback protocol_menu; }
sb_control_menu() { record_callback sb_control_menu; }
ip_stack_menu() { record_callback ip_stack_menu; }
subscription_port_menu() { record_callback subscription_port_menu; }
nexus_menu() { record_callback nexus_menu; }
show_info() { record_callback show_info; }
show_ports() { record_callback show_ports; }
uninstall_all() { record_callback uninstall_all; }
do_update() { record_callback do_update; }

run_main_choice() {
    local choice="$1" output="$2" process="" attempt=0
    (
        main_menu <<EOF
$choice
0
EOF
    ) > "$output" 2>&1 &
    process=$!
    while kill -0 "$process" 2>/dev/null && [ "$attempt" -lt 100 ]; do
        sleep 0.02
        attempt=$((attempt + 1))
    done
    if kill -0 "$process" 2>/dev/null; then
        kill "$process" >/dev/null 2>&1 || true
        wait "$process" 2>/dev/null || true
        fail "menu choice $choice waited instead of failing fast"
    fi
    if ! wait "$process"; then
        sed -n '1,160p' "$output" >&2 || true
        fail "menu choice $choice exited unsuccessfully"
    fi
}

printf '%s\n' '[1/6] a competing shared lock skips health and rejects every writer'
(
    exec 8>> "$RR_RESTORE_LOCK_FILE"
    flock 8
    : > "$TEST_ROOT/holder-ready"
    while [ ! -e "$TEST_ROOT/release-holder" ]; do
        sleep 0.05
    done
) &
LOCK_HOLDER_PID=$!
for _ in $(seq 1 100); do
    [ -e "$TEST_ROOT/holder-ready" ] && break
    sleep 0.02
done
[ -e "$TEST_ROOT/holder-ready" ] || fail 'competing lock holder did not start'

writer_specs=(
    '1:install_main'
    '3:change_cdn'
    '4:refresh_argo'
    '5:install_f2b'
    '7:toggle_auto_update'
    '9:protocol_menu'
    '11:sb_control_menu'
    '12:ip_stack_menu'
    '13:subscription_port_menu'
    '14:nexus_menu'
)
for specification in "${writer_specs[@]}"; do
    choice=${specification%%:*}
    callback=${specification#*:}
    : > "$CALLBACK_LOG"
    : > "$HEALTH_LOG"
    output="$TEST_ROOT/busy-${choice}.log"
    run_main_choice "$choice" "$output"
    [ ! -s "$HEALTH_LOG" ] || \
        fail "initial health body ran under contention for choice $choice"
    [ ! -s "$CALLBACK_LOG" ] || \
        fail "$callback ran while another transaction owned the lock"
    grep -Fq '[忙碌]' "$output" || \
        fail "$callback contention did not produce the interactive busy message"
done

printf '%s\n' '[2/6] read-only main-menu callbacks remain available while busy'
for specification in '2:show_info' '10:show_ports'; do
    choice=${specification%%:*}
    callback=${specification#*:}
    : > "$CALLBACK_LOG"
    : > "$HEALTH_LOG"
    output="$TEST_ROOT/readonly-${choice}.log"
    run_main_choice "$choice" "$output"
    [ ! -s "$HEALTH_LOG" ] || \
        fail "initial health body ran under contention for read-only choice $choice"
    [ "$(cat "$CALLBACK_LOG")" = "$callback" ] || \
        fail "$callback was incorrectly blocked by the writer lock"
    if grep -Fq '[忙碌]' "$output"; then
        fail "$callback incorrectly emitted a writer-busy message"
    fi
done

: > "$TEST_ROOT/release-holder"
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""

printf '%s\n' '[3/6] normal main-menu and interactive stdin callbacks succeed'
: > "$CALLBACK_LOG"
: > "$HEALTH_LOG"
run_main_choice 1 "$TEST_ROOT/normal-main.log"
[ "$(cat "$CALLBACK_LOG")" = install_main ] || \
    fail 'normal main-menu writer callback did not run'
[ "$(cat "$HEALTH_LOG")" = health:1 ] || \
    fail 'normal initial health did not run in isolated lock ownership'
interactive_writer() {
    local answer=""
    read -r answer
    printf 'interactive:%s\n' "$answer" >> "$CALLBACK_LOG"
}
printf '%s\n' accepted | rr_menu_run_writer interactive_writer || \
    fail 'interactive stdin was not preserved through the isolated callback'
grep -Fxq interactive:accepted "$CALLBACK_LOG" || \
    fail 'interactive callback did not receive its input'

printf '%s\n' '[4/6] a trusted delegated lock context can invoke the menu wrapper'
: > "$CALLBACK_LOG"
DELEGATION_LOG="$TEST_ROOT/delegation.log"
: > "$DELEGATION_LOG"
# The ancestry/inode authenticator has its own security regression coverage.
# Here an observable successful authenticator isolates the menu wrapper's
# delegated branch from container-specific /proc PID namespace translation.
rr_delegated_update_lock_context_is_trusted() {
    printf '%s\n' authenticated >> "$DELEGATION_LOG"
    return 0
}
delegated_writer() {
    printf 'delegated:%s:%s:%s:%s\n' \
        "${RR_UPDATE_LOCK_HELD:-0}" "${RR_RESTORE_LOCK_HELD:-0}" \
        "${RR_UPDATE_LOCK_FDS_CLOSED:-0}" "${RR_UPDATE_LOCK_OWNER:-unset}" \
        >> "$CALLBACK_LOG"
}
RR_UPDATE_LOCK_HELD=1 RR_RESTORE_LOCK_HELD=1 \
    RR_UPDATE_LOCK_FDS_CLOSED=1 RR_UPDATE_LOCK_OWNER=0 \
    rr_menu_run_writer delegated_writer || \
    fail 'trusted delegated menu callback was rejected'
grep -Fxq authenticated "$DELEGATION_LOG" || \
    fail 'menu wrapper bypassed delegated-context authentication'
grep -Fxq delegated:1:1:1:0 "$CALLBACK_LOG" || \
    fail 'delegated callback did not retain authenticated lock context'

printf '%s\n' '[5/6] an unsafe shared-lock path fails closed with a clear message'
safe_lock_file="$RR_RESTORE_LOCK_FILE"
mkdir -p "$TEST_ROOT/unsafe"
ln -s "$TEST_ROOT/attacker-target" "$TEST_ROOT/unsafe/update.lock"
RR_RESTORE_LOCK_FILE="$TEST_ROOT/unsafe/update.lock"
: > "$CALLBACK_LOG"
unsafe_result=0
rr_menu_run_writer install_main > "$TEST_ROOT/unsafe.log" 2>&1 || \
    unsafe_result=$?
[ "$unsafe_result" -eq 76 ] || \
    fail "unsafe lock returned $unsafe_result instead of 76"
[ ! -s "$CALLBACK_LOG" ] || fail 'writer ran through an unsafe lock path'
grep -Fq '[安全拒绝]' "$TEST_ROOT/unsafe.log" || \
    fail 'unsafe lock rejection did not produce the interactive safety message'
RR_RESTORE_LOCK_FILE="$safe_lock_file"

printf '%s\n' '[6/6] dispatch keeps self-locking and read-only callbacks unwrapped'
main_body=$(sed -n '/^main_menu() {/,/^}/p' "$REPO_ROOT/modules/99-menus.sh")
grep -Fq '6) uninstall_all ;;' <<< "$main_body" || \
    fail 'uninstall gained a nested outer writer lock'
grep -Fq '8) do_update ;;' <<< "$main_body" || \
    fail 'update gained a nested outer writer lock'
grep -Fq 'then show_info;' <<< "$main_body" || \
    fail 'show_info is no longer a direct read-only callback'
grep -Fq '10) show_ports ;;' <<< "$main_body" || \
    fail 'show_ports is no longer a direct read-only callback'

printf '%s\n' 'menu writer lock regression: PASS'
