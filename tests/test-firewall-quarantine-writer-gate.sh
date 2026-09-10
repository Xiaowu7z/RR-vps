#!/usr/bin/env bash
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'ERROR: root required' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /root/rr-test-writer-gate.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077

# Real production protocol/hop orchestration, flock ownership, writer gate,
# marker publication/parser, in-flight begin/finish, batch lifecycle and save
# wrapper. Kernel rules, persistence, snapshot contents and systemd effects
# are fixtures. This does not exercise a live firewall or a live recovery.
# shellcheck source=../modules/10-system.sh
source "$repo/modules/10-system.sh"

# Replay the precise pre-fix writer boundary, keeping the rest of each actual
# production function. These controls must fail before any backend write.
python3 - "$repo/modules/10-system.sh" "$fixture/old-functions.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = []
for name in ('rr_reconcile_protocol_firewall_locked', 'rr_firewall_batch_install_hop_rules'):
    start = source.index(name + '() {\n')
    end = source.index('\n}\n', start) + 3
    body = source[start:end]
    gate = 'if rr_firewall_writer_gate_is_held || rr_firewall_inflight_begin_locked; then'
    assert body.count(gate) == 1, name
    old.append(body.replace(name + '()', 'fixture_old_' + name + '()', 1)
               .replace(gate, 'if rr_firewall_inflight_begin_locked; then'))
Path(sys.argv[2]).write_text('\n'.join(old))
PY
# shellcheck disable=SC1091
source "$fixture/old-functions.sh"
for name in rr_firewall_inflight_begin_locked rr_firewall_inflight_finish_locked; do
    eval "$(declare -f "$name" | sed "1s/$name/fixture_original_$name/")"
done
rr_firewall_inflight_begin_locked() {
    printf 'begin\n' >>"$fixture_case/events"
    fixture_original_rr_firewall_inflight_begin_locked "$@"
}
rr_firewall_inflight_finish_locked() {
    printf 'finish\n' >>"$fixture_case/events"
    fixture_original_rr_firewall_inflight_finish_locked "$@"
}
forbidden() { printf 'FORBIDDEN %s\n' "$*" >>"$fixture_case/forbidden"; return 90; }
iptables() { forbidden iptables; }
ip6tables() { forbidden ip6tables; }
ufw() { forbidden ufw; }
netfilter-persistent() { forbidden netfilter-persistent; }
systemctl() {
    [ "$1" = show ] && [ "$3" = --value ] || { forbidden systemctl; return 90; }
    case "$2" in
        --property=LoadState) printf 'not-found\n' ;;
        --property=ActiveState) printf 'inactive\n' ;;
        --property=UnitFileState) printf '\n' ;;
        *) forbidden systemctl_property; return 90 ;;
    esac
}
managed_singbox_running() { return 1; }
subscription_server_running() { return 1; }
rr_firewall_install_fail_closed_supervisor() { :; }
rr_firewall_install_fail_closed_dropins() { :; }
rr_firewall_prepare_quarantine_evidence_locked() {
    mkdir -m 700 "$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence"
    printf 'snapshot-fixture-only\n' >"$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence/fixture"
}
rr_firewall_quarantine_evidence_is_trusted() {
    [ "$(cat "$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence/fixture")" = snapshot-fixture-only ]
}
rr_firewall_activate_quarantine_supervisor() { :; }
rr_firewall_quiesce_durable_ingress() { :; }
rr_firewall_restore_quarantine_unit_enablement() { :; }
rr_firewall_deactivate_quarantine_retry() { :; }
rr_firewall_activate_idle_quarantine_supervisor() { [ ! -e "$RR_FIREWALL_QUARANTINE_FILE" ]; }
rr_firewall_restore_quarantine_runtime_state() { :; }
rr_firewall_filter_authority_mode() { printf -v "$1" '%s' netfilter; }
rr_firewall_persistence_backend_available() { return 0; }
rr_inactive_ufw_protocol_is_disjoint() { return 0; }
rr_netfilter_backend_state() { return 0; }
rr_netfilter_protocol_is_uncontested() { return 0; }
rr_firewall_capture_protocol_transaction() {
    cp "$fixture_case/live" "$1/live"
    printf 'untouched-rules\n' >"$1/seal"
}
rr_firewall_protocol_transaction_seals_match() { cmp -s "$1/seal" "$2/seal"; }
rr_reconcile_netfilter_protocol_rule() {
    rr_firewall_writer_gate_is_held || { forbidden backend_without_gate; return 90; }
    printf 'protocol %s %s %s %s\n' "$@" >>"$fixture_case/live"
    printf 'protocol_write\n' >>"$fixture_case/events"
}
rr_validate_protocol_firewall() { return 0; }
rr_firewall_restore_protocol_transaction() { cp "$1/live" "$fixture_case/live"; }
rr_firewall_hop_program_first_match_is_safe() { return 0; }
rr_firewall_capture_hop_transaction() { rr_firewall_capture_protocol_transaction "$@"; }
rr_firewall_hop_transaction_seals_match() { cmp -s "$1/seal" "$2/seal"; }
install_hop_rules() {
    rr_firewall_writer_gate_is_held || { forbidden hop_without_gate; return 90; }
    printf 'hop %s %s %s\n' "$@" >>"$fixture_case/live"
    printf 'hop_write\n' >>"$fixture_case/events"
}
rr_validate_hop_rules() { return 0; }
rr_firewall_restore_hop_transaction() { cp "$1/live" "$fixture_case/live"; }
rr_save_firewall_locked() {
    rr_firewall_writer_gate_is_held || { forbidden save_without_gate; return 90; }
    cp "$fixture_case/live" "$fixture_case/persisted"
    printf 'save\n' >>"$fixture_case/events"
}

fixture_setup() {
    fixture_case="$fixture/$1"
    mkdir -m 700 "$fixture_case"
    : >"$fixture_case/events"
    : >"$fixture_case/live"
    CONFIG_FILE="$fixture_case/config"
    printf 'PORT=30677\n' >"$CONFIG_FILE"
    cp "$CONFIG_FILE" "$fixture_case/config.before"
    RR_FIREWALL_LOCK_FILE="$fixture_case/locks/firewall.lock"
    RR_FIREWALL_QUARANTINE_DIR="$fixture_case/quarantine"
    RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
    mkdir -m 700 "$RR_FIREWALL_QUARANTINE_DIR"
    ENTRY_IP_MODE=ipv4
    RR_FIREWALL_QUARANTINE_REPAIR=0
    RR_FIREWALL_QUARANTINE_WRITER=0
    RR_FIREWALL_LOCK_FD="" RR_FIREWALL_LOCK_OWNER_PID="" RR_FIREWALL_LOCK_DEPTH=0
    RR_FIREWALL_BATCH_ACTIVE=0 RR_FIREWALL_BATCH_ROOT=""
    RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH=0
    trap '[ -z "${RR_FIREWALL_BATCH_ROOT:-}" ] || rm -rf -- "$RR_FIREWALL_BATCH_ROOT"' EXIT
}
count() { awk -v expected="$1" '$0 == expected {n++} END {print n+0}' "$fixture_case/events"; }
expect_count() { [ "$(count "$1")" -eq "$2" ]; }
expect_rc() {
    local actual=0 expected="$1"
    shift
    "$@" || actual=$?
    [ "$actual" -eq "$expected" ] || {
        printf 'Expected rc=%s actual=%s function=%s\n' "$expected" "$actual" "$1" >&2
        return 1
    }
}
make_v2() {
    rr_firewall_prepare_quarantine_evidence_locked
    rr_firewall_write_marker_locked firewall-quarantine-v2 firewall-evidence-v1
    rr_firewall_load_fail_closed_quarantine
    cp "$RR_FIREWALL_QUARANTINE_FILE" "$fixture_case/marker.before"
    RR_FIREWALL_QUARANTINE_REPAIR=1
}
unchanged() {
    cmp -s "$CONFIG_FILE" "$fixture_case/config.before"
    cmp -s "$RR_FIREWALL_QUARANTINE_FILE" "$fixture_case/marker.before"
}
case_old_protocol() {
    rr_firewall_lock_acquire; make_v2
    expect_rc 1 fixture_old_rr_reconcile_protocol_firewall_locked 30677 tcp open
    expect_count begin 1; expect_count protocol_write 0; unchanged
    rr_firewall_lock_release
}
case_old_hop() {
    rr_firewall_lock_acquire; make_v2; rr_firewall_batch_begin
    expect_rc 1 fixture_old_rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    expect_count begin 1; expect_count hop_write 0; unchanged
    rr_firewall_batch_abort; rr_firewall_lock_release
}
case_recovery_protocol() {
    rr_firewall_lock_acquire; make_v2
    rr_reconcile_protocol_firewall 30677 tcp open
    expect_count begin 0; expect_count finish 0; expect_count protocol_write 2
    expect_count save 1; unchanged
    [ "$RR_FIREWALL_LOCK_DEPTH" -eq 1 ]; rr_firewall_lock_release
}
case_recovery_batch() {
    rr_firewall_lock_acquire; make_v2; rr_firewall_batch_begin
    rr_reconcile_protocol_firewall 30677 tcp open
    rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    rr_firewall_batch_commit
    expect_count begin 0; expect_count finish 0; expect_count protocol_write 2
    expect_count hop_write 1; expect_count save 1; unchanged
    [ "$RR_FIREWALL_LOCK_DEPTH" -eq 1 ]; rr_firewall_lock_release
}
case_ordinary_protocol() {
    rr_reconcile_protocol_firewall 30677 tcp open
    expect_count begin 1; expect_count finish 1; expect_count protocol_write 2
    expect_count save 1
    [ ! -e "$RR_FIREWALL_QUARANTINE_FILE" ]; [ "$RR_FIREWALL_LOCK_DEPTH" -eq 0 ]
    cmp -s "$CONFIG_FILE" "$fixture_case/config.before"
}
case_ordinary_batch() {
    rr_firewall_batch_begin
    rr_reconcile_protocol_firewall 30677 tcp open
    rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    expect_count begin 1; rr_firewall_inflight_is_owned
    rr_firewall_batch_commit
    expect_count begin 1; expect_count finish 1; expect_count save 1
    [ ! -e "$RR_FIREWALL_QUARANTINE_FILE" ]; [ "$RR_FIREWALL_LOCK_DEPTH" -eq 0 ]
}
case_owned_inflight() {
    rr_firewall_batch_begin; rr_firewall_inflight_begin_locked
    rr_reconcile_protocol_firewall 30677 tcp open
    rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    expect_count begin 1; rr_firewall_batch_commit
    expect_count finish 1
}
case_deferred_finish() {
    rr_firewall_lock_acquire; rr_firewall_batch_begin
    RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH=1
    rr_reconcile_protocol_firewall 30677 tcp open
    rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    # The caller's configuration commit is a fixture. The real deferred batch
    # must retain its marker, owner, evidence and lock through this boundary.
    printf 'PORT=30678\n' >"$CONFIG_FILE"
    rr_firewall_batch_commit
    rr_firewall_batch_is_active; rr_firewall_inflight_is_owned
    expect_count begin 1; expect_count finish 0; expect_count save 1
    [ "$RR_FIREWALL_LOCK_DEPTH" -eq 2 ]
    rr_firewall_inflight_finish_locked; rr_firewall_batch_cleanup
    [ "$(cat "$CONFIG_FILE")" = PORT=30678 ]
    expect_count finish 1; [ "$RR_FIREWALL_LOCK_DEPTH" -eq 1 ]
    rr_firewall_lock_release
}
case_reject() {
    local variant="$1" saved_owner=""
    rr_firewall_lock_acquire; make_v2
    case "$variant" in
        no_lock) rr_firewall_lock_release ;;
        wrong_owner) saved_owner="$RR_FIREWALL_LOCK_OWNER_PID"; RR_FIREWALL_LOCK_OWNER_PID=1 ;;
        v1) sed -i '1s/.*/firewall-inflight-v1/' "$RR_FIREWALL_QUARANTINE_FILE" ;;
        other) sed -i '1s/.*/unrecognized-marker/' "$RR_FIREWALL_QUARANTINE_FILE" ;;
        writable) chmod 666 "$RR_FIREWALL_QUARANTINE_FILE" ;;
        no_repair) RR_FIREWALL_QUARANTINE_REPAIR=0 ;;
    esac
    expect_rc 1 rr_firewall_writer_gate_is_held
    expect_rc 1 rr_reconcile_protocol_firewall_locked 30677 tcp open
    expect_count protocol_write 0; expect_count save 0
    [ -z "$saved_owner" ] || RR_FIREWALL_LOCK_OWNER_PID="$saved_owner"
    [ "$variant" = no_lock ] || rr_firewall_lock_release
}
case_hop_reject_marker() {
    rr_firewall_lock_acquire; make_v2; rr_firewall_batch_begin
    sed -i '1s/.*/firewall-inflight-v1/' "$RR_FIREWALL_QUARANTINE_FILE"
    expect_rc 1 rr_firewall_batch_install_hop_rules HY2 14014 20000:20010
    expect_count hop_write 0; expect_count save 0
    rr_firewall_batch_cleanup; rr_firewall_lock_release
}

cases=0
run_case() {
    local label="$1" status=0
    shift
    set +e
    ( set -e; fixture_setup "$label"; "$@"; [ ! -e "$fixture_case/forbidden" ] ) >"$fixture/$label.log" 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        printf 'FAIL %s rc=%s\n' "$label" "$status" >&2
        cat "$fixture/$label.log" >&2
        exit 1
    fi
    cases=$((cases + 1))
    printf 'PASS %s\n' "$label"
}
run_case old_protocol_reproduces_refusal case_old_protocol
run_case old_hop_reproduces_refusal case_old_hop
run_case valid_recovery_protocol case_recovery_protocol
run_case valid_recovery_batch case_recovery_batch
run_case ordinary_protocol_publishes_marker case_ordinary_protocol
run_case ordinary_batch_publishes_once case_ordinary_batch
run_case owned_inflight_is_reused case_owned_inflight
run_case config_commit_deferred_finish case_deferred_finish
for variant in no_lock wrong_owner v1 other writable no_repair; do
    run_case "reject_$variant" case_reject "$variant"
done
run_case hop_rejects_orphan_marker case_hop_reject_marker
printf 'PASS firewall quarantine writer gate: %s cases; fixture firewall/systemd, real locks and lifecycle\n' "$cases"
