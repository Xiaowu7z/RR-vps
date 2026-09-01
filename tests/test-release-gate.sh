#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
VPS_WORKFLOW="$REPO_ROOT/.github/workflows/vps-audit.yml"
CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

CURRENT_VERSION=$(sed -n 's/^RR-vps \([0-9][0-9.]*\)$/\1/p' "$REPO_ROOT/version")
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[ "$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' \
    "$REPO_ROOT/modules/00-runtime.sh")" = "$CURRENT_VERSION" ]
grep -Fxq "RR_RELEASE_TAG=\"v${CURRENT_VERSION}\"" "$REPO_ROOT/install.sh"
grep -Fxq "RR_RELEASE_TAG=\"v${CURRENT_VERSION}\"" \
    "$REPO_ROOT/scripts/install-core.sh"
grep -Fxq 'NEXUS_CORE_TARGET_VERSION="1.14.0"' \
    "$REPO_ROOT/modules/85-nexus.sh"
grep -Fq "当前版本：**${CURRENT_VERSION}**" "$REPO_ROOT/README.md"
grep -Fq "Current version: **${CURRENT_VERSION}**" "$REPO_ROOT/README_EN.md"
grep -Fq "## ${CURRENT_VERSION} -" "$REPO_ROOT/CHANGELOG.md"
# These are security/transaction compatibility cutoffs, not display versions.
grep -Fxq 'RR_SUBSCRIPTION_SAFE_VERSION="7.1.1"' \
    "$REPO_ROOT/scripts/install-core.sh"
grep -Fxq 'RR_SUBSCRIPTION_SAFE_VERSION="7.1.1"' \
    "$REPO_ROOT/scripts/update-recover.sh"
grep -Fxq 'RR_POST_UPDATE_FINALIZE_VERSION="7.1.1"' \
    "$REPO_ROOT/scripts/update-recover.sh"
grep -Fxq 'RR_RESTORE_ACTIVE="${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}"' \
    "$REPO_ROOT/scripts/install-core.sh"

python3 - "$WORKFLOW" "$VPS_WORKFLOW" "$CI_WORKFLOW" \
    "$TEST_ROOT/assert-workflow-gate.sh" \
    "$REPO_ROOT/modules/55-resilience.sh" \
    "$REPO_ROOT/modules/10-system.sh" \
    "$REPO_ROOT/modules/20-config.sh" \
    "$REPO_ROOT/modules/30-singbox.sh" \
    "$REPO_ROOT/rr" \
    "$REPO_ROOT/scripts/install-core.sh" \
    "$REPO_ROOT/modules/85-nexus.sh" \
    "$REPO_ROOT/scripts/naive-cert-hook.sh" \
    "$REPO_ROOT/modules/70-protocols.sh" \
    "$REPO_ROOT/modules/99-menus.sh" \
    "$REPO_ROOT/modules/60-update.sh" \
    "$REPO_ROOT/modules/95-install.sh" <<'PY'
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import textwrap

release = Path(sys.argv[1]).read_text(encoding="utf-8")
vps = Path(sys.argv[2]).read_text(encoding="utf-8")
ci = Path(sys.argv[3]).read_text(encoding="utf-8")
resilience = Path(sys.argv[5]).read_text(encoding="utf-8")
system = Path(sys.argv[6]).read_text(encoding="utf-8")
config = Path(sys.argv[7]).read_text(encoding="utf-8")
singbox = Path(sys.argv[8]).read_text(encoding="utf-8")
launcher = Path(sys.argv[9]).read_text(encoding="utf-8")
installer = Path(sys.argv[10]).read_text(encoding="utf-8")
nexus = Path(sys.argv[11]).read_text(encoding="utf-8")
certificate_hook = Path(sys.argv[12]).read_text(encoding="utf-8")
protocols = Path(sys.argv[13]).read_text(encoding="utf-8")
menus = Path(sys.argv[14]).read_text(encoding="utf-8")
update = Path(sys.argv[15]).read_text(encoding="utf-8")
uninstall_module = Path(sys.argv[16]).read_text(encoding="utf-8")


def firewall_function_slice(candidate, start_token, end_token):
    start = candidate.index(start_token)
    end = candidate.index(end_token, start)
    return candidate[start:end]


def function_slice(candidate, start_token, end_token=None):
    start = candidate.index(start_token)
    end = candidate.index(end_token, start) if end_token else len(candidate)
    return start, end, candidate[start:end]


def mutate_function_slice(
        candidate, start_token, end_token, old, replacement, *, last=False):
    start, end, body = function_slice(candidate, start_token, end_token)
    position = body.rfind(old) if last else body.find(old)
    assert position >= 0
    mutated_body = body[:position] + replacement + body[position + len(old):]
    assert mutated_body != body
    return candidate[:start] + mutated_body + candidate[end:]


def firewall_mutate_function(
        candidate, start_token, end_token, old, replacement, *, last=False):
    start = candidate.index(start_token)
    end = candidate.index(end_token, start)
    body = candidate[start:end]
    position = body.rfind(old) if last else body.find(old)
    assert position >= 0
    changed = body[:position] + replacement + body[position + len(old):]
    return candidate[:start] + changed + candidate[end:]


def firewall_tokens_are_ordered(body, tokens):
    cursor = -1
    for token in tokens:
        cursor = body.find(token, cursor + 1)
        if cursor < 0:
            return False
    return True


# systemctl renders the empty default of its `(bas)` set properties as the
# literal `~`.  Every effective-identity gate must preserve that exact
# fail-closed contract instead of treating the value as an empty string.
system_marker_view = function_slice(
    system,
    "rr_firewall_effective_root_marker_view_is_safe() {",
    "\nrr_firewall_effective_marker_view_is_safe() {",
)[2]
assert '[ "$system_call_filter" = \'~\' ] || return 1' in system_marker_view

certbot_runtime = function_slice(
    config,
    "rr_certbot_renewal_runtime_is_ready() {",
    "\nrr_enable_certbot_renewal_runtime() {",
)[2]
for exact_default in (
    '[ "$restrict_address_families" = \'~\' ] || return 1',
    '[ "$restrict_network_interfaces" = \'~\' ] && \\\n',
    '[ "$restrict_filesystems" = \'~\' ] || return 1',
    '[ "$system_call_filter" = \'~\' ] || return 1',
):
    assert exact_default in certbot_runtime

singbox_current = function_slice(
    singbox,
    "rr_singbox_service_guards_are_effective() {",
    "\nrr_singbox_effective_control_hooks_are_empty() {",
)[2]
singbox_legacy = function_slice(
    singbox,
    "rr_singbox_legacy_service_is_owned() {",
    "\nrr_singbox_service_is_owned_or_absent() {",
)[2]
health_namespace = function_slice(
    singbox,
    "rr_health_effective_namespace_is_exact() {",
    "\nrr_health_effective_conditions_are_exact() {",
)[2]
for effective_gate in (singbox_current, singbox_legacy, health_namespace):
    assert '--property=SystemCallFilter --value' in effective_gate
    assert '[ "$value" = \'~\' ] || return 1' in effective_gate

restore_marker_view = function_slice(
    resilience,
    "rr_restore_effective_marker_view_is_safe() {",
    "\nrr_restore_effective_conditions_are_managed() {",
)[2]
assert '--property=SystemCallFilter --value' in restore_marker_view
assert '[ "$value" = \'~\' ] || return 1' in restore_marker_view

cloudflared_identity = function_slice(
    protocols,
    "rr_cloudflared_effective_identity_is_exact() {",
    "\nrr_cloudflared_effective_service_is_absent() {",
)[2]
assert 'rr_cloudflared_show SystemCallFilter' in cloudflared_identity
assert '[ "$value" = \'~\' ] || return 1' in cloudflared_identity

update_recovery_identity = function_slice(
    installer,
    "rr_update_recovery_effective_identity_matches() {",
    "\nrr_update_recovery_effective_identity_is_exact() {",
)[2]
assert '--property=SystemCallFilter --value' in update_recovery_identity
assert '[ "$value" = \'~\' ] || return 1' in update_recovery_identity


def firewall_lock_contract(system_candidate, resilience_candidate):
    try:
        directory_safe = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_directory_is_safe() {",
            "\nrr_firewall_lock_file_is_safe() {",
        )
        file_safe = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_file_is_safe() {",
            "\nrr_firewall_lock_prepare() {",
        )
        prepare = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_prepare() {",
            "\nrr_firewall_lock_owner_matches() {",
        )
        owner_matches = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_owner_matches() {",
            "\nrr_firewall_lock_is_held() {",
        )
        held = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_is_held() {",
            "\nrr_firewall_lock_acquire() {",
        )
        acquire = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_acquire() {",
            "\nrr_firewall_lock_release() {",
        )
        release_lock = firewall_function_slice(
            system_candidate,
            "rr_firewall_lock_release() {",
            "\nrr_firewall_persistence_backend_available() {",
        )
    except ValueError:
        return False
    fixed_lock = "/run/rr-vps/locks/firewall.lock"
    if 'RR_FIREWALL_LOCK_FILE="${RR_FIREWALL_LOCK_FILE:-' \
       f'{fixed_lock}}}"' not in system_candidate:
        return False
    if not all(token in directory_safe for token in (
        '[ -d "$directory" ] && [ ! -L "$directory" ]',
        "stat -c '%u:%g'",
        '"$directory" 2>/dev/null)" = 0:0',
        "stat -c '%a'",
        "(( (8#$mode & 8#022) == 0 ))",
    )):
        return False
    if not all(token in file_safe for token in (
        '[ -f "$lock_file" ] && [ ! -L "$lock_file" ]',
        "stat -c '%u:%g:%a:%h:%s'",
        '0:0:600:1:0',
    )):
        return False
    if prepare.count(fixed_lock) != 1 or not all(token in prepare for token in (
        '[ "${EUID:-$(id -u)}" -eq 0 ] || return 1',
        'rr_firewall_lock_directory_is_safe /run || return 1',
        '[[ "$lock_file" = /* && "$lock_file" != *[[:space:]]* ]] || return 1',
        '[ "$(basename -- "$lock_file")" = firewall.lock ] || return 1',
        'lock_directory=$(dirname -- "$lock_file") || return 1',
        'if [ "$lock_file" = /run/rr-vps/locks/firewall.lock ]; then',
        'for directory in /run/rr-vps /run/rr-vps/locks; do',
        'mkdir -m 700 -- "$directory" || return 1',
        'chown 0:0 -- "$directory" || return 1',
        'chmod 700 -- "$directory" || return 1',
        'lock_parent=$(dirname -- "$lock_directory") || return 1',
        'rr_firewall_lock_directory_is_safe "$lock_parent" || return 1',
        'rr_firewall_lock_directory_is_safe "$lock_directory" || return 1',
        '( umask 077; : > "$lock_file" ) || return 1',
        'rr_firewall_lock_file_is_safe "$lock_file"',
    )):
        return False
    if not all(token in owner_matches for token in (
        '[ "$RR_FIREWALL_LOCK_OWNER_PID" = "$BASHPID" ]',
        '[[ "${RR_FIREWALL_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ ]]',
        '[[ "${RR_FIREWALL_LOCK_FD:-}" =~ ^[0-9]+$ ]]',
        '[ -e "/dev/fd/$RR_FIREWALL_LOCK_FD" ]',
    )):
        return False
    if not firewall_tokens_are_ordered(held, (
        "rr_firewall_lock_owner_matches || return 1",
        'rr_firewall_lock_file_is_safe "$RR_FIREWALL_LOCK_FILE" || return 1',
        "path_identity=$(stat -Lc '%d:%i:%u:%g:%h'",
        '"$RR_FIREWALL_LOCK_FILE" 2>/dev/null)',
        "descriptor_identity=$(stat -Lc '%d:%i:%u:%g:%h'",
        '[ "$path_identity" = "$descriptor_identity" ]',
    )):
        return False
    if acquire.count("$RR_FIREWALL_LOCK_FILE") != 5 or not firewall_tokens_are_ordered(
        acquire,
        (
            "if rr_firewall_lock_is_held; then",
            "RR_FIREWALL_LOCK_DEPTH=$((RR_FIREWALL_LOCK_DEPTH + 1))",
            'exec {RR_FIREWALL_LOCK_FD}>&- || true',
            'RR_FIREWALL_LOCK_OWNER_PID=""',
            "rr_firewall_lock_prepare || {",
            'exec {RR_FIREWALL_LOCK_FD}<>"$RR_FIREWALL_LOCK_FILE"',
            "path_identity=$(stat -Lc '%d:%i:%u:%g:%h'",
            '"$RR_FIREWALL_LOCK_FILE" 2>/dev/null)',
            "descriptor_identity=$(stat -Lc '%d:%i:%u:%g:%h'",
            '! flock -w 60 "$RR_FIREWALL_LOCK_FD"',
            "# Recheck after the blocking wait.",
            'RR_FIREWALL_LOCK_OWNER_PID="$BASHPID"',
            "RR_FIREWALL_LOCK_DEPTH=1",
        ),
    ):
        return False
    if acquire.count("rr_firewall_lock_file_is_safe") != 2:
        return False
    if not firewall_tokens_are_ordered(
        release_lock,
        (
            "rr_firewall_lock_owner_matches || return 1",
            "rr_firewall_lock_is_held || failed=true",
            '[ "$RR_FIREWALL_LOCK_DEPTH" -gt 1 ]',
            "RR_FIREWALL_LOCK_DEPTH=$((RR_FIREWALL_LOCK_DEPTH - 1))",
            'flock -u "$RR_FIREWALL_LOCK_FD"',
            'exec {RR_FIREWALL_LOCK_FD}>&-',
            'RR_FIREWALL_LOCK_OWNER_PID=""',
            "RR_FIREWALL_LOCK_DEPTH=0",
        ),
    ):
        return False

    wrapper_specs = (
        (
            system_candidate,
            "rr_reconcile_protocol_firewall() {",
            "\nrr_reconcile_protocol_firewall_locked() {",
            'rr_reconcile_protocol_firewall_locked "$@"',
        ),
        (
            system_candidate,
            "rr_firewall_restore_hop_transaction() {",
            "\nrr_firewall_restore_hop_transaction_locked() {",
            'rr_firewall_restore_hop_transaction_locked "$@"',
        ),
        (
            system_candidate,
            "open_configured_firewall() {",
            "\nopen_configured_firewall_locked() {",
            'open_configured_firewall_locked "$@"',
        ),
        (
            system_candidate,
            "save_firewall() {",
            "\nrr_save_firewall_locked() {",
            "rr_save_firewall_locked",
        ),
        (
            resilience_candidate,
            "rr_restore_clear_managed_firewall() {",
            "\nrr_restore_clear_managed_firewall_locked() {",
            'rr_restore_clear_managed_firewall_locked "$@"',
        ),
        (
            resilience_candidate,
            "rr_restore_restore_firewall_snapshot() {",
            "\nrr_restore_restore_firewall_snapshot_locked() {",
            'rr_restore_restore_firewall_snapshot_locked "$@"',
        ),
    )
    try:
        for candidate, start, end, locked_call in wrapper_specs:
            wrapper = firewall_function_slice(candidate, start, end)
            if not firewall_tokens_are_ordered(
                wrapper,
                (
                    "rr_firewall_lock_acquire || return 1",
                    locked_call,
                    "rr_firewall_lock_release",
                ),
            ):
                return False
        save_locked = firewall_function_slice(
            system_candidate,
            "rr_save_firewall_locked() {",
            "\n# ==========================================\n# 安全 sed 替换函数",
        )
        clear_locked = firewall_function_slice(
            resilience_candidate,
            "rr_restore_clear_managed_firewall_locked() {",
            "\nrr_restore_normalize_full_firewall_program() {",
        )
    except ValueError:
        return False
    return (
        "rr_firewall_writer_gate_is_held || return 1" in save_locked
        and "rr_firewall_lock_is_held || return 1" in clear_locked
    )


def firewall_nat_first_match_contract(system_candidate):
    try:
        backend = firewall_function_slice(
            system_candidate,
            "rr_firewall_hop_backend_first_match_is_safe() {",
            "\nrr_firewall_hop_program_first_match_is_safe() {",
        )
        program = firewall_function_slice(
            system_candidate,
            "rr_firewall_hop_program_first_match_is_safe() {",
            "\nrr_firewall_capture_hop_backend_state() {",
        )
    except ValueError:
        return False
    required = (
        'case "$phase" in pre|post)',
        'if len(tokens) < 8 or tokens[0:2] != ["-A", "PREROUTING"] or "!" in tokens:',
        'gotos = values(tokens, "-g", "--goto")',
        'if (protocols != ["udp"] or dports != [wanted] or multiports',
        'if jump == "REDIRECT":',
        'elif jump == "DNAT":',
        'else:\n        return False\n    index = 2',
        'if "!" in tokens:\n        return [(1, 65535)]',
        'if protocol not in {"udp", "17", "all", "0"}:',
        'if protocol in {"tcp", "6", "icmp", "1", "icmpv6", "58", "sctp", "132"}:',
        'return []\n            return [(1, 65535)]',
        'if ports is None or len(ports) != 1:\n        return [(1, 65535)]',
        'for raw_line in open(path, encoding="utf-8"):',
        'rules.append(tokens)',
        'for tokens in rules:',
        'overlaps = any(low <= wanted_high and wanted_low <= high',
        'if exact_desired(tokens, wanted):\n            desired_seen = True\n            break',
        'shadows an existing RR rule.  Unknown jumps/user chains, ranges,',
        'raise SystemExit(1)\n    if phase == "post" and not desired_seen:',
    )
    return (
        all(token in backend for token in required)
        and backend.count('"!" in tokens') == 2
        and backend.count('rr_firewall_hop_backend_first_match_is_safe') == 1
        and program.count('rr_firewall_hop_backend_first_match_is_safe') == 1
        and "for backend in iptables ip6tables; do" in program
        and "[ \"$seen\" = true ]" in program
    )


def firewall_transaction_contract(system_candidate, resilience_candidate):
    try:
        batch_active = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_is_active() {",
            "\nrr_firewall_batch_begin() {",
        )
        batch_begin = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_begin() {",
            "\nrr_firewall_batch_record_protocol() {",
        )
        batch_cleanup = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_cleanup() {",
            "\nrr_firewall_batch_abort() {",
        )
        batch_abort = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_abort() {",
            "\nrr_firewall_batch_commit() {",
        )
        batch_commit = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_commit() {",
            "\nrr_netfilter_rr_namespace_is_empty() {",
        )
        reconcile = firewall_function_slice(
            system_candidate,
            "rr_reconcile_protocol_firewall_locked() {",
            "\nrr_validate_protocol_firewall() {",
        )
        hop = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_install_hop_rules() {",
            "\nrr_firewall_preflight_configured_hops() {",
        )
        configured = firewall_function_slice(
            system_candidate,
            "open_configured_firewall_locked() {",
            "\nrr_firewall_restore_quarantine_unit_enablement() {",
        )
        restore_clear = firewall_function_slice(
            resilience_candidate,
            "rr_restore_clear_managed_firewall() {",
            "\nrr_restore_clear_managed_firewall_locked() {",
        )
        restore_snapshot = firewall_function_slice(
            resilience_candidate,
            "rr_restore_restore_firewall_snapshot() {",
            "\nrr_restore_restore_firewall_snapshot_locked() {",
        )
        restore_snapshot_locked = firewall_function_slice(
            resilience_candidate,
            "rr_restore_restore_firewall_snapshot_locked() {",
            "\nrr_restore_snapshot_nginx() {",
        )
        snapshot_raw_probe = firewall_function_slice(
            resilience_candidate,
            "rr_restore_firewall_snapshot_has_managed_raw_rules() {",
            "\nrr_restore_live_has_managed_raw_rules() {",
        )
        live_raw_probe = firewall_function_slice(
            resilience_candidate,
            "rr_restore_live_has_managed_raw_rules() {",
            "\nrr_restore_run_netfilter_saved_rule() {",
        )
        candidate_hop_preflight = firewall_function_slice(
            resilience_candidate,
            "rr_restore_candidate_hop_persistence_is_available() {",
            "\nrr_restore_capture_firewall_snapshot() {",
        )
        portable_restore = firewall_function_slice(
            resilience_candidate,
            "rr_restore_backup_locked() {",
            "\nrr_update_preflight() {",
        )
    except ValueError:
        return False

    if not all(token in batch_active for token in (
        "rr_firewall_lock_is_held",
        '[ "${RR_FIREWALL_BATCH_OWNER_PID:-}" = "$BASHPID" ]',
        '[ "$(stat -c \'%u:%a\' "$RR_FIREWALL_BATCH_ROOT" 2>/dev/null)" = "${EUID}:700" ]',
    )):
        return False
    if not firewall_tokens_are_ordered(
        batch_begin,
        (
            'RR_FIREWALL_BATCH_ACTIVE:-0}" = 0',
            "rr_firewall_lock_acquire || return 1",
            "mktemp -d /tmp/rr-firewall-batch.XXXXXX",
            "chmod 700",
            "RR_FIREWALL_BATCH_ACTIVE=1",
            'RR_FIREWALL_BATCH_OWNER_PID="$BASHPID"',
        ),
    ):
        return False
    if not firewall_tokens_are_ordered(
        batch_cleanup,
        (
            "rr_firewall_batch_is_active || return 1",
            "rm -rf --",
            "RR_FIREWALL_BATCH_ACTIVE=0",
            'RR_FIREWALL_BATCH_OWNER_PID=""',
            "rr_firewall_lock_release || failed=true",
        ),
    ):
        return False
    if not firewall_tokens_are_ordered(
        batch_abort,
        ("rr_firewall_batch_rollback_operations", "rr_firewall_batch_cleanup"),
    ):
        return False
    if batch_commit.count("save_firewall") != 2 or not firewall_tokens_are_ordered(
        batch_commit,
        (
            "! save_firewall",
            "rr_firewall_batch_rollback_operations",
            "! save_firewall",
            "rr_firewall_batch_cleanup",
            "return 1",
        ),
    ):
        return False

    try:
        persistence = reconcile.index("rr_firewall_persistence_backend_available")
        capture = reconcile.index("rr_firewall_capture_protocol_transaction")
        first_writer = min(
            reconcile.index("rr_reconcile_ufw_protocol_rule"),
            reconcile.index("rr_reconcile_netfilter_protocol_rule"),
        )
        post_validate = reconcile.index("! rr_validate_protocol_firewall", first_writer)
        seals = reconcile.index("rr_firewall_protocol_transaction_seals_match", post_validate)
        first_save = reconcile.index("! save_firewall", seals)
        restore = reconcile.index("rr_firewall_restore_protocol_transaction", first_save)
        second_save = reconcile.index("! save_firewall", first_save + 1)
    except ValueError:
        return False
    if not persistence < capture < first_writer < post_validate < seals < first_save < restore < second_save:
        return False
    if reconcile.count("save_firewall") != 2:
        return False
    if not all(token in reconcile for token in (
        'if [ "$mode" != ufw ] && ! rr_firewall_persistence_backend_available; then',
        "rr_firewall_batch_record_protocol",
        "rr_firewall_restore_protocol_transaction",
    )):
        return False

    if not firewall_tokens_are_ordered(
        hop,
        (
            "rr_firewall_batch_is_active || return 1",
            "rr_firewall_persistence_backend_available || {",
            '"$spec_list" pre',
            "rr_firewall_capture_hop_transaction",
            'install_hop_rules "$label" "$main_port" "$spec_list"',
            'rr_validate_hop_rules "$label" "$main_port" "$spec_list"',
            '"$spec_list" post',
            "rr_firewall_hop_transaction_seals_match",
            "rr_firewall_restore_hop_transaction",
            "rr_firewall_batch_record_hop",
        ),
    ) or hop.count("rr_firewall_hop_program_first_match_is_safe") != 2:
        return False

    try:
        batch_start = configured.index("rr_firewall_batch_begin || return 1")
        authority = configured.index("rr_firewall_filter_authority_mode", batch_start)
        raw_required = configured.index("raw_persistence_required=true", authority)
        persistence = configured.index("rr_firewall_persistence_backend_available", raw_required)
        hop_preflight = configured.index("rr_firewall_preflight_configured_hops", persistence)
        writer = configured.index("\n    open_firewall || result=$?", hop_preflight)
        final_gate = configured.index('if [ "$batch_started" = false ]; then', writer)
        abort = configured.index("rr_firewall_batch_abort", final_gate)
        commit = configured.index("rr_firewall_batch_commit", abort)
    except ValueError:
        return False
    if not batch_start < authority < raw_required < persistence < hop_preflight < writer < final_gate < abort < commit:
        return False
    if "rr_firewall_batch_cleanup" in configured or "rr_firewall_lock_release" in configured:
        return False

    if not firewall_tokens_are_ordered(
        restore_clear,
        (
            "rr_firewall_lock_acquire || return 1",
            'if [ "${RR_RESTORE_FIREWALL_NEEDS_PERSIST:-false}" = true ]',
            '[ -z "$snapshot" ]; then',
            'rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"',
            'raw_backend_owned=true',
            'if [ "$raw_backend_owned" = true ]',
            "rr_firewall_persistence_backend_available",
            'rr_restore_clear_managed_firewall_locked "$@"',
            "rr_firewall_lock_release",
        ),
    ):
        return False
    if not firewall_tokens_are_ordered(
        restore_snapshot,
        (
            "rr_firewall_lock_acquire || return 1",
            'rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"',
            "rr_restore_live_has_managed_raw_rules",
            'if [ "$raw_required" = true ]',
            "rr_firewall_persistence_backend_available",
            'RR_RESTORE_FIREWALL_NEEDS_PERSIST="$raw_required"',
            'rr_restore_restore_firewall_snapshot_locked "$@"',
            "rr_firewall_lock_release",
        ),
    ):
        return False
    if not all(token in snapshot_raw_probe for token in (
        '[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 2',
        "for backend in iptables ip6tables; do",
        "for table in filter nat; do",
        '[ -f "$rules" ] && [ ! -L "$rules" ] || return 2',
        '[ ! -s "$rules" ] || return 0',
        "return 1",
    )):
        return False
    if snapshot_raw_probe.count("return 2") != 4:
        return False
    if not all(token in live_raw_probe for token in (
        "mktemp -d /tmp/rr-restore-firewall-live.XXXXXX",
        'chmod 700 "$directory"',
        'rr_netfilter_backend_state "$backend"',
        'rr_restore_capture_netfilter_rules "$backend" "$table"',
        '[ ! -s "$rules" ] || managed_seen=true',
        '[ "$readable_seen" = true ] || return 2',
        '[ "$managed_seen" = true ]',
    )):
        return False
    if live_raw_probe.count("return 2") != 5:
        return False
    if not all(token in candidate_hop_preflight for token in (
        "load_config_with_defaults || return 1",
        '[ -n "${HY2_HOP_PORTS:-}" ] || [ -n "${TU5_HOP_PORTS:-}" ]',
        "rr_firewall_persistence_backend_available || {",
    )):
        return False
    if not firewall_tokens_are_ordered(
        restore_snapshot_locked,
        (
            "rr_restore_require_firewall_snapshot_v2",
            "rr_restore_firewall_backend_states_match",
            'rr_restore_clear_managed_firewall "$snapshot"',
            "rr_restore_verify_firewall_snapshot",
            'if [ "${RR_RESTORE_FIREWALL_NEEDS_PERSIST:-false}" = true ]',
            "! save_firewall",
        ),
    ):
        return False
    return firewall_tokens_are_ordered(
        portable_restore,
        (
            'rr_restore_verify_firewall_pre_mutation_snapshot "$rollback"',
            'rr_restore_candidate_ufw_is_disjoint "$rollback"',
            'rr_restore_candidate_netfilter_is_disjoint "$rollback"',
            "rr_restore_candidate_hop_persistence_is_available",
            'rr_restore_firewall_snapshot_has_managed_raw_rules',
            'rr_restore_clear_managed_firewall "$rollback/firewall"',
            '[ "$portable_firewall_needs_persist" = true ]; then',
            "save_firewall || result=1",
            'rr_restore_firewall_backend_states_match "$rollback/firewall"',
            "open_configured_firewall || result=1",
        ),
    )


def firewall_inflight_contract(system_candidate):
    """Bind every backend writer to the durable v1 -> v2 crash boundary."""
    try:
        owned = firewall_function_slice(
            system_candidate,
            "rr_firewall_inflight_is_owned() {",
            "\nrr_firewall_writer_gate_is_held() {",
        )
        writer_gate = firewall_function_slice(
            system_candidate,
            "rr_firewall_writer_gate_is_held() {",
            "\nrr_firewall_promote_inflight_locked() {",
        )
        promote = firewall_function_slice(
            system_candidate,
            "rr_firewall_promote_inflight_locked() {",
            "\nrr_firewall_publish_fail_closed_quarantine() {",
        )
        quiesce = firewall_function_slice(
            system_candidate,
            "rr_firewall_quiesce_durable_ingress() {",
            "\n# Arm the crash boundary",
        )
        begin = firewall_function_slice(
            system_candidate,
            "rr_firewall_inflight_begin_locked() {",
            "\n# Clear a fully proved transaction",
        )
        finish = firewall_function_slice(
            system_candidate,
            "rr_firewall_inflight_finish_locked() {",
            "\nrr_firewall_stop_nodes_on_indeterminate_commit() {",
        )
        stop_nodes = firewall_function_slice(
            system_candidate,
            "rr_firewall_stop_nodes_on_indeterminate_commit() {",
            "\nrr_firewall_fail_closed_stop_nodes() {",
        )
        fail_closed = firewall_function_slice(
            system_candidate,
            "rr_firewall_fail_closed_stop_nodes() {",
            "\nrr_firewall_persistence_backend_available() {",
        )
    except ValueError:
        return False

    if not firewall_tokens_are_ordered(owned, (
        "rr_firewall_lock_is_held || return 1",
        '[ "${RR_FIREWALL_INFLIGHT_ACTIVE:-0}" = 1 ]',
        '[ "${RR_FIREWALL_INFLIGHT_OWNER_PID:-}" = "$BASHPID" ]',
        '[[ "${RR_FIREWALL_INFLIGHT_MARKER_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]',
        '[ "$(stat -c \'%u:%g:%h:%a\' -- "$marker" 2>/dev/null)" = 0:0:1:600 ]',
        'IFS= read -r hash < "$marker" || return 1',
        '[ "$hash" = firewall-inflight-v1 ] || return 1',
        'hash=$(sha256sum -- "$marker" 2>/dev/null',
        '[ "$hash" = "$RR_FIREWALL_INFLIGHT_MARKER_SHA256" ]',
    )):
        return False
    if owned.count("$BASHPID") != 1 or "$$" in owned:
        return False

    if not firewall_tokens_are_ordered(writer_gate, (
        "rr_firewall_lock_is_held || return 1",
        "rr_firewall_inflight_is_owned && return 0",
        '[ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" = 1 ]',
        '[ "${RR_FIREWALL_QUARANTINE_WRITER:-0}" = 1 ]',
        '[ "$(stat -c \'%u:%g:%h:%a\' -- "$marker" 2>/dev/null)" = 0:0:1:600 ]',
        '[ "$(head -n 1 -- "$marker" 2>/dev/null)" = firewall-quarantine-v2 ]',
    )):
        return False

    if not firewall_tokens_are_ordered(promote, (
        "rr_firewall_inflight_is_owned || return 1",
        "rr_firewall_refresh_quarantine_evidence_config_locked || return 1",
        'mapfile -t lines < "$marker" || return 1',
        '[ "${lines[0]}" = firewall-inflight-v1 ] || return 1',
        'temporary=$(mktemp "$directory/.firewall-quarantine.XXXXXX")',
        "printf '%s\\n' firewall-quarantine-v2",
        '! chown 0:0 "$temporary"',
        '! chmod 600 "$temporary"',
        '! sync -f "$temporary"',
        '! mv -f -- "$temporary" "$marker"',
        '! sync -f "$directory"',
        "RR_FIREWALL_INFLIGHT_ACTIVE=0",
        'RR_FIREWALL_INFLIGHT_OWNER_PID=""',
        'RR_FIREWALL_INFLIGHT_MARKER_SHA256=""',
        "rr_firewall_load_fail_closed_quarantine",
    )) or promote.count("firewall-quarantine-v2") != 1:
        return False

    if not firewall_tokens_are_ordered(quiesce, (
        "rr_firewall_disable_managed_unit argo-rr-health.timer || failed=true",
        "rr_firewall_disable_managed_unit argo-rr-health.service || failed=true",
        "stop_subscription_servers >/dev/null 2>&1 || failed=true",
        "subscription_server_running && failed=true",
        "rr_firewall_disable_managed_unit rr-subscription.service || failed=true",
        "stop_singbox_instances >/dev/null 2>&1 || failed=true",
        "managed_singbox_running && failed=true",
        "rr_firewall_disable_managed_unit sing-box.service || failed=true",
        "rr_firewall_disable_managed_unit rr-nexus.service || failed=true",
        '[ "$failed" = false ]',
    )) or quiesce.count("rr_firewall_disable_managed_unit") != 5:
        return False

    if not firewall_tokens_are_ordered(begin, (
        "rr_firewall_lock_is_held || return 1",
        "rr_firewall_inflight_is_owned && return 0",
        '[ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1',
        "rr_firewall_install_fail_closed_supervisor || return 1",
        "rr_firewall_install_fail_closed_dropins || return 1",
        "rr_firewall_prepare_quarantine_evidence_locked || return 1",
        "rr_firewall_write_marker_locked firewall-inflight-v1",
        'hash=$(sha256sum -- "$marker"',
        "RR_FIREWALL_INFLIGHT_ACTIVE=1",
        'RR_FIREWALL_INFLIGHT_OWNER_PID="$BASHPID"',
        'RR_FIREWALL_INFLIGHT_MARKER_SHA256="$hash"',
        "rr_firewall_load_inflight_marker",
        "rr_firewall_activate_quarantine_supervisor",
        "rr_firewall_quiesce_durable_ingress",
        "rr_firewall_promote_inflight_locked",
        "return 2",
        "rr_firewall_inflight_is_owned || return 2",
    )):
        return False
    if begin.count("rr_firewall_write_marker_locked firewall-inflight-v1") != 1 or \
       begin.count("rr_firewall_quiesce_durable_ingress") != 1 or \
       begin.count('RR_FIREWALL_INFLIGHT_OWNER_PID="$BASHPID"') != 1:
        return False

    if not firewall_tokens_are_ordered(finish, (
        "rr_firewall_inflight_is_owned || return 2",
        "rr_firewall_restore_quarantine_unit_enablement",
        "rr_firewall_deactivate_quarantine_retry || failed=true",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_activate_quarantine_supervisor",
        "rr_firewall_quiesce_durable_ingress",
        '[ -d "$evidence" ] && [ ! -L "$evidence" ]',
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_activate_quarantine_supervisor",
        "rr_firewall_quiesce_durable_ingress",
        '[ ! -e "$completed" ] && [ ! -L "$completed" ]',
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_activate_quarantine_supervisor",
        "rr_firewall_quiesce_durable_ingress",
        'mv -- "$evidence" "$completed"',
        'rm -f -- "$marker"',
        'rm -rf -- "$completed"',
        'sync -f "$directory"',
        'if [ -e "$marker" ] || [ -L "$marker" ]',
        "rr_firewall_activate_quarantine_supervisor",
        "else",
        "rr_firewall_publish_fail_closed_quarantine",
        "rr_firewall_quiesce_durable_ingress",
        "RR_FIREWALL_INFLIGHT_ACTIVE=0",
        'RR_FIREWALL_INFLIGHT_OWNER_PID=""',
        'RR_FIREWALL_INFLIGHT_MARKER_SHA256=""',
        "rr_firewall_activate_idle_quarantine_supervisor",
        "rr_firewall_publish_fail_closed_quarantine",
        "rr_firewall_quiesce_durable_ingress",
        "rr_firewall_restore_quarantine_runtime_state",
        "rr_firewall_publish_fail_closed_quarantine",
        "rr_firewall_quiesce_durable_ingress",
        "return 2",
        "return 0",
    )):
        return False
    if finish.count("rr_firewall_promote_inflight_locked") != 3 or \
       finish.count("rr_firewall_activate_quarantine_supervisor") != 4 or \
       finish.count("rr_firewall_activate_idle_quarantine_supervisor") != 1 or \
       finish.count("rr_firewall_publish_fail_closed_quarantine") != 3 or \
       finish.count("rr_firewall_quiesce_durable_ingress") != 6 or \
       finish.count("return 2") != 7:
        return False

    return (
        firewall_tokens_are_ordered(stop_nodes, (
            "rr_firewall_publish_fail_closed_quarantine || failed=true",
            "rr_firewall_quiesce_durable_ingress || failed=true",
            '[ "$failed" = false ]',
        ))
        and firewall_tokens_are_ordered(fail_closed, (
            'local context="$1"',
            "if rr_firewall_stop_nodes_on_indeterminate_commit; then",
            "return 2",
            "return 3",
        ))
    )


def firewall_writer_boundary_contract(
        system_candidate, resilience_candidate, protocols_candidate,
        uninstall_candidate):
    # The first mutating command in each primitive must be dominated by the
    # same-owner v1 gate (or the explicit v2 repair/uninstall gate).  Merely
    # mentioning the gate somewhere after a writer is deliberately rejected.
    specs = (
        (system_candidate, "rr_reconcile_ufw_protocol_rule() {",
         "\nrr_reconcile_netfilter_protocol_rule() {", "ufw delete"),
        (system_candidate, "rr_reconcile_netfilter_protocol_rule() {",
         "\nrr_firewall_capture_ufw_protocol_state() {",
         '"$backend" -w 5 -t filter'),
        (system_candidate, "rr_firewall_run_netfilter_saved_tuple() {",
         "\nrr_firewall_run_ufw_saved_tuple() {",
         '"$backend" -w 5 -t filter'),
        (system_candidate, "rr_firewall_run_ufw_saved_tuple() {",
         "\nrr_firewall_restore_netfilter_protocol_state() {", "ufw delete"),
        (system_candidate, "rr_firewall_run_netfilter_saved_hop() {",
         "\nrr_firewall_restore_hop_backend_state() {",
         '"$backend" -w 5 -t nat'),
        (system_candidate, "rr_save_firewall_locked() {", "\nsafe_sed() {",
         "netfilter-persistent save"),
        (resilience_candidate, "rr_restore_run_netfilter_saved_rule() {",
         "\nrr_restore_run_ufw_saved_rule() {",
         '"$backend" -w 5 -t "$table"'),
        (resilience_candidate, "rr_restore_run_ufw_saved_rule() {",
         "\nrr_restore_clear_ufw_rules() {", "ufw delete"),
        (protocols_candidate, "rr_remove_hop_ports_locked() {",
         "\nremove_hop_ports() {", '"$command_name" -w 5 -t nat -D'),
        (protocols_candidate, "add_hop_rule() {",
         "\nrr_install_hop_rules_locked() {",
         '"$command_name" -w 5 -t nat -A'),
        (protocols_candidate, "rr_install_hop_rules_locked() {",
         "\nrr_firewall_batch_replace_hop_rules() {", "add_hop_rule"),
        (uninstall_candidate, "rr_uninstall_run_inactive_ufw_saved_rule() {",
         "\nrr_uninstall_clear_inactive_ufw_rules() {", "ufw delete"),
    )
    gate = "rr_firewall_writer_gate_is_held || return 1"
    try:
        for candidate, start, end, first_writer in specs:
            body = firewall_function_slice(candidate, start, end)
            if body.count(gate) != 1 or body.count(first_writer) < 1:
                return False
            if not firewall_tokens_are_ordered(body, (gate, first_writer)):
                return False
        save_locked = firewall_function_slice(
            system_candidate,
            "rr_save_firewall_locked() {",
            "\nsafe_sed() {",
        )
    except ValueError:
        return False
    return firewall_tokens_are_ordered(save_locked, (
        gate,
        "netfilter-persistent save",
        "service iptables save",
    ))


def firewall_prewrite_flow_contract(
        system_candidate, resilience_candidate, protocols_candidate,
        uninstall_candidate):
    try:
        reconcile_wrapper = firewall_function_slice(
            system_candidate,
            "rr_reconcile_protocol_firewall() {",
            "\nrr_reconcile_protocol_firewall_locked() {",
        )
        reconcile = firewall_function_slice(
            system_candidate,
            "rr_reconcile_protocol_firewall_locked() {",
            "\nrr_validate_protocol_firewall() {",
        )
        batch_hop = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_install_hop_rules() {",
            "\nrr_firewall_preflight_configured_hops() {",
        )
        batch_abort = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_abort() {",
            "\nrr_firewall_batch_commit() {",
        )
        batch_commit = firewall_function_slice(
            system_candidate,
            "rr_firewall_batch_commit() {",
            "\nrr_netfilter_rr_namespace_is_empty() {",
        )
        save = firewall_function_slice(
            system_candidate,
            "save_firewall() {",
            "\nrr_save_firewall_locked() {",
        )
        restore_clear = firewall_function_slice(
            resilience_candidate,
            "rr_restore_clear_managed_firewall() {",
            "\nrr_restore_clear_managed_firewall_locked() {",
        )
        restore_snapshot = firewall_function_slice(
            resilience_candidate,
            "rr_restore_restore_firewall_snapshot() {",
            "\nrr_restore_restore_firewall_snapshot_locked() {",
        )
        remove_hop = firewall_function_slice(
            protocols_candidate,
            "remove_hop_ports() {",
            "\nadd_hop_rule() {",
        )
        replace_hop = firewall_function_slice(
            protocols_candidate,
            "rr_firewall_batch_replace_hop_rules() {",
            "\ninstall_hop_rules() {",
        )
        uninstall = firewall_function_slice(
            uninstall_candidate,
            "rr_uninstall_clear_managed_firewall_transaction() {",
            "\nrr_uninstall_fixed_cloudflared_evidence_is_trusted() {",
        )
    except ValueError:
        return False

    # Per-tuple path: snapshot -> durable marker + stop proof -> writer.  An
    # ordinary compensated failure is cleared/restored; uncertainty is
    # promoted to v2 before the common fail-closed stop path is reached.
    if not firewall_tokens_are_ordered(reconcile, (
        "rr_firewall_capture_protocol_transaction",
        "rr_firewall_inflight_begin_locked",
        "rr_reconcile_ufw_protocol_rule",
        "rr_reconcile_netfilter_protocol_rule",
        "rr_validate_protocol_firewall",
        "rr_firewall_restore_protocol_transaction",
    )) or reconcile.count("rr_firewall_inflight_begin_locked") != 1:
        return False
    if not firewall_tokens_are_ordered(reconcile_wrapper, (
        "rr_firewall_lock_acquire || return 1",
        'rr_reconcile_protocol_firewall_locked "$@"',
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_lock_release",
        "rr_firewall_fail_closed_stop_nodes",
    )):
        return False

    if not firewall_tokens_are_ordered(batch_hop, (
        'rr_firewall_hop_program_first_match_is_safe "$label" "$main_port"',
        "rr_firewall_capture_hop_transaction",
        "rr_firewall_inflight_begin_locked",
        'install_hop_rules "$label" "$main_port" "$spec_list"',
        "rr_validate_hop_rules",
        "rr_firewall_restore_hop_transaction",
        "rr_firewall_batch_record_hop",
    )):
        return False
    if not firewall_tokens_are_ordered(batch_abort, (
        "rr_firewall_batch_rollback_operations",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_batch_cleanup",
    )):
        return False
    if not all(token in batch_commit for token in (
        "rr_firewall_batch_rollback_operations",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_batch_cleanup",
    )):
        return False
    if batch_commit.index("rr_firewall_batch_rollback_operations") > \
       batch_commit.index("rr_firewall_promote_inflight_locked"):
        return False

    if not firewall_tokens_are_ordered(save, (
        "rr_firewall_lock_acquire || return 1",
        "rr_firewall_writer_gate_is_held",
        "rr_firewall_inflight_begin_locked",
        "rr_save_firewall_locked",
        "rr_restore_verify_firewall_pre_mutation_snapshot",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_lock_release",
        "rr_firewall_fail_closed_stop_nodes",
    )):
        return False

    for wrapper, locked_call in (
        (restore_clear, 'rr_restore_clear_managed_firewall_locked "$@"'),
        (restore_snapshot, 'rr_restore_restore_firewall_snapshot_locked "$@"'),
    ):
        if not firewall_tokens_are_ordered(wrapper, (
            "rr_firewall_lock_acquire || return 1",
            "rr_firewall_writer_gate_is_held",
            "rr_firewall_inflight_begin_locked",
            locked_call,
            "rr_firewall_inflight_finish_locked",
            "rr_firewall_promote_inflight_locked",
            "rr_firewall_lock_release",
            "rr_firewall_fail_closed_stop_nodes",
        )):
            return False

    if not firewall_tokens_are_ordered(remove_hop, (
        "rr_firewall_capture_hop_transaction",
        "rr_firewall_inflight_begin_locked",
        "rr_remove_hop_ports_locked",
        "rr_firewall_restore_hop_transaction",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_fail_closed_stop_nodes",
    )):
        return False
    if remove_hop.count("rr_firewall_inflight_finish_locked") != 3 or \
       remove_hop.count("rr_firewall_promote_inflight_locked") != 4:
        return False

    if not firewall_tokens_are_ordered(replace_hop, (
        "rr_firewall_capture_hop_transaction",
        "rr_firewall_inflight_begin_locked",
        "rr_remove_hop_ports_locked",
        "rr_install_hop_rules_locked",
        "rr_firewall_restore_hop_transaction",
        "rr_firewall_batch_record_hop",
    )):
        return False

    return firewall_tokens_are_ordered(uninstall, (
        "rr_firewall_lock_acquire || return 1",
        "rr_firewall_load_fail_closed_quarantine",
        "rr_firewall_writer_gate_is_held",
        "rr_firewall_inflight_begin_locked",
        'rr_uninstall_clear_managed_firewall_transaction_locked "$evidence"',
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_lock_release",
    ))


def firewall_release_contract(
        system_candidate, resilience_candidate, protocols_candidate,
        uninstall_candidate):
    return (
        firewall_lock_contract(system_candidate, resilience_candidate)
        and firewall_nat_first_match_contract(system_candidate)
        and firewall_transaction_contract(system_candidate, resilience_candidate)
        and firewall_inflight_contract(system_candidate)
        and firewall_writer_boundary_contract(
            system_candidate, resilience_candidate, protocols_candidate,
            uninstall_candidate,
        )
        and firewall_prewrite_flow_contract(
            system_candidate, resilience_candidate, protocols_candidate,
            uninstall_candidate,
        )
    )


assert firewall_lock_contract(system, resilience), "firewall lock contract"
assert firewall_nat_first_match_contract(system), "firewall NAT first-match contract"
assert firewall_transaction_contract(system, resilience), "firewall transaction contract"
assert firewall_inflight_contract(system), "firewall in-flight journal contract"
assert firewall_writer_boundary_contract(
    system, resilience, protocols, uninstall_module
), "firewall writer gate contract"
assert firewall_prewrite_flow_contract(
    system, resilience, protocols, uninstall_module
), "firewall pre-write flow contract"
assert firewall_release_contract(
    system, resilience, protocols, uninstall_module
), "firewall aggregate contract"

firewall_mutations = []
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_file_is_safe() {",
        "\nrr_firewall_lock_prepare() {",
        "0:0:600:1:0",
        "0:0:644:1:0",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_prepare() {",
        "\nrr_firewall_lock_owner_matches() {",
        'mkdir -m 700 -- "$directory" || return 1',
        'mkdir -- "$directory" || return 1',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_prepare() {",
        "\nrr_firewall_lock_is_held() {",
        "/run/rr-vps/locks/firewall.lock",
        "/tmp/firewall.lock",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_owner_matches() {",
        "\nrr_firewall_lock_is_held() {",
        '"$BASHPID"',
        '"$$"',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_acquire() {",
        "\nrr_firewall_lock_release() {",
        'exec {RR_FIREWALL_LOCK_FD}>&- || true',
        ': # inherited descriptor left open',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_lock_acquire() {",
        "\nrr_firewall_lock_release() {",
        "RR_FIREWALL_LOCK_DEPTH=$((RR_FIREWALL_LOCK_DEPTH + 1))",
        "RR_FIREWALL_LOCK_DEPTH=1",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_begin() {",
        "\nrr_firewall_batch_record_protocol() {",
        "rr_firewall_lock_acquire || return 1",
        "true",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_cleanup() {",
        "\nrr_firewall_batch_abort() {",
        "rr_firewall_lock_release || failed=true",
        "true",
    ),
    resilience,
))

configured_persist_late = firewall_mutate_function(
    system,
    "open_configured_firewall_locked() {",
    "\nrr_firewall_restore_quarantine_unit_enablement() {",
    "! rr_firewall_persistence_backend_available",
    "! true",
)
configured_persist_late = firewall_mutate_function(
    configured_persist_late,
    "open_configured_firewall_locked() {",
    "\nrr_firewall_restore_quarantine_unit_enablement() {",
    "open_firewall || result=$?",
    "open_firewall || result=$?\n    rr_firewall_persistence_backend_available || result=1",
)
firewall_mutations.append((configured_persist_late, resilience))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "open_configured_firewall_locked() {",
        "\nrr_firewall_restore_quarantine_unit_enablement() {",
        "open_firewall || result=$?",
        "rr_firewall_batch_cleanup || return 1\n    open_firewall || result=$?",
    ),
    resilience,
))

firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_reconcile_protocol_firewall_locked() {",
        "\nrr_validate_protocol_firewall() {",
        "rr_firewall_persistence_backend_available",
        "true",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_install_hop_rules() {",
        "\nrr_firewall_preflight_configured_hops() {",
        "rr_firewall_persistence_backend_available",
        "true",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_install_hop_rules() {",
        "\nrr_firewall_preflight_configured_hops() {",
        '"$spec_list" pre',
        '"$spec_list" post',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_install_hop_rules() {",
        "\nrr_firewall_preflight_configured_hops() {",
        '"$spec_list" post',
        '"$spec_list" pre',
        last=True,
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        ' or "!" in tokens:',
        ":",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        'if "!" in tokens:\n        return [(1, 65535)]',
        'if "!" in tokens:\n        return []',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        'return []\n            return [(1, 65535)]',
        'return []\n            return []',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        'else:\n        return False\n    index = 2',
        'else:\n        jump = "REDIRECT"\n    index = 2',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        'raise SystemExit(1)\n    if phase == "post" and not desired_seen:',
        'continue\n    if phase == "post" and not desired_seen:',
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_hop_backend_first_match_is_safe() {",
        "\nrr_firewall_hop_program_first_match_is_safe() {",
        'if phase == "post" and not desired_seen:',
        "if False:",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_commit() {",
        "\nrr_netfilter_rr_namespace_is_empty() {",
        "save_firewall",
        "true",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_commit() {",
        "\nrr_netfilter_rr_namespace_is_empty() {",
        "save_firewall",
        "true",
        last=True,
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_batch_commit() {",
        "\nrr_netfilter_rr_namespace_is_empty() {",
        "rr_firewall_batch_rollback_operations",
        "true",
    ),
    resilience,
))
firewall_mutations.append((
    firewall_mutate_function(
        system,
        "rr_reconcile_protocol_firewall_locked() {",
        "\nrr_validate_protocol_firewall() {",
        "save_firewall",
        "true",
        last=True,
    ),
    resilience,
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_restore_firewall_snapshot() {",
        "\nrr_restore_restore_firewall_snapshot_locked() {",
        "rr_firewall_persistence_backend_available",
        "true",
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_clear_managed_firewall() {",
        "\nrr_restore_clear_managed_firewall_locked() {",
        'rr_restore_clear_managed_firewall_locked "$@"',
        'rr_restore_clear_managed_firewall_unlocked "$@"',
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_firewall_snapshot_has_managed_raw_rules() {",
        "\nrr_restore_live_has_managed_raw_rules() {",
        "return 2",
        "return 1",
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_live_has_managed_raw_rules() {",
        "\nrr_restore_run_netfilter_saved_rule() {",
        "return 2",
        "return 1",
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_restore_firewall_snapshot() {",
        "\nrr_restore_restore_firewall_snapshot_locked() {",
        'rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"',
        "false",
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_restore_firewall_snapshot() {",
        "\nrr_restore_restore_firewall_snapshot_locked() {",
        "rr_restore_live_has_managed_raw_rules",
        "false",
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_restore_firewall_snapshot() {",
        "\nrr_restore_restore_firewall_snapshot_locked() {",
        '[ "$raw_required" = true ]',
        '[ true = true ]',
    ),
))
firewall_mutations.append((
    system,
    firewall_mutate_function(
        resilience,
        "rr_restore_restore_firewall_snapshot_locked() {",
        "\nrr_restore_snapshot_nginx() {",
        '[ "${RR_RESTORE_FIREWALL_NEEDS_PERSIST:-false}" = true ]',
        '[ true = true ]',
    ),
))

candidate_hop_too_late = firewall_mutate_function(
    resilience,
    "rr_restore_backup_locked() {",
    "\nrr_update_preflight() {",
    "rr_restore_candidate_hop_persistence_is_available",
    "true",
)
candidate_hop_too_late = firewall_mutate_function(
    candidate_hop_too_late,
    "rr_restore_backup_locked() {",
    "\nrr_update_preflight() {",
    'rr_restore_clear_managed_firewall "$rollback/firewall" || result=1',
    'rr_restore_clear_managed_firewall "$rollback/firewall" || result=1\n'
    '        [ "$result" -ne 1 ] && \\\n'
    '            rr_restore_candidate_hop_persistence_is_available || result=1',
)
firewall_mutations.append((system, candidate_hop_too_late))

candidate_save_too_early = firewall_mutate_function(
    resilience,
    "rr_restore_backup_locked() {",
    "\nrr_update_preflight() {",
    'save_firewall || result=1',
    'true || result=1',
)
candidate_save_too_early = firewall_mutate_function(
    candidate_save_too_early,
    "rr_restore_backup_locked() {",
    "\nrr_update_preflight() {",
    'rr_restore_clear_managed_firewall "$rollback/firewall" || result=1',
    'save_firewall || result=1\n'
    '            rr_restore_clear_managed_firewall "$rollback/firewall" || result=1',
)
firewall_mutations.append((system, candidate_save_too_early))
for mutated_system, mutated_resilience in firewall_mutations:
    assert (mutated_system, mutated_resilience) != (system, resilience)
    assert not firewall_release_contract(
        mutated_system, mutated_resilience, protocols, uninstall_module
    )


# Mutation negatives for the crash boundary are intentionally structural:
# deleting a gate is insufficient coverage if the same token could simply be
# moved below a writer.  Exercise both deletion and reordering across every
# source module that owns a firewall writer.
firewall_inflight_mutations = []
firewall_inflight_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_inflight_is_owned() {",
        "\nrr_firewall_writer_gate_is_held() {",
        '"$BASHPID"',
        '"$$"',
    ),
    resilience,
    protocols,
    uninstall_module,
))
firewall_inflight_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_inflight_begin_locked() {",
        "\n# Clear a fully proved transaction",
        "rr_firewall_install_fail_closed_supervisor || return 1",
        "true",
    ),
    resilience,
    protocols,
    uninstall_module,
))
firewall_inflight_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_inflight_begin_locked() {",
        "\n# Clear a fully proved transaction",
        "rr_firewall_quiesce_durable_ingress",
        "true",
    ),
    resilience,
    protocols,
    uninstall_module,
))
firewall_inflight_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_promote_inflight_locked() {",
        "\nrr_firewall_publish_fail_closed_quarantine() {",
        "firewall-quarantine-v2",
        "firewall-inflight-v1",
    ),
    resilience,
    protocols,
    uninstall_module,
))
firewall_inflight_mutations.append((
    firewall_mutate_function(
        system,
        "rr_firewall_inflight_finish_locked() {",
        "\nrr_firewall_stop_nodes_on_indeterminate_commit() {",
        'rm -f -- "$marker"',
        'true # marker left durable',
    ),
    resilience,
    protocols,
    uninstall_module,
))

stop_after_quiesce = firewall_mutate_function(
    system,
    "rr_firewall_stop_nodes_on_indeterminate_commit() {",
    "\nrr_firewall_fail_closed_stop_nodes() {",
    "rr_firewall_publish_fail_closed_quarantine || failed=true",
    "true",
)
stop_after_quiesce = firewall_mutate_function(
    stop_after_quiesce,
    "rr_firewall_stop_nodes_on_indeterminate_commit() {",
    "\nrr_firewall_fail_closed_stop_nodes() {",
    "rr_firewall_quiesce_durable_ingress || failed=true",
    "rr_firewall_quiesce_durable_ingress || failed=true\n"
    "    rr_firewall_publish_fail_closed_quarantine || failed=true",
)
firewall_inflight_mutations.append((
    stop_after_quiesce,
    resilience,
    protocols,
    uninstall_module,
))

for candidate, start, end in (
    (system, "rr_reconcile_ufw_protocol_rule() {",
     "\nrr_reconcile_netfilter_protocol_rule() {"),
    (resilience, "rr_restore_run_netfilter_saved_rule() {",
     "\nrr_restore_run_ufw_saved_rule() {"),
    (protocols, "rr_remove_hop_ports_locked() {", "\nremove_hop_ports() {"),
    (uninstall_module, "rr_uninstall_run_inactive_ufw_saved_rule() {",
     "\nrr_uninstall_clear_inactive_ufw_rules() {"),
):
    mutated = firewall_mutate_function(
        candidate,
        start,
        end,
        "rr_firewall_writer_gate_is_held || return 1",
        "true",
    )
    firewall_inflight_mutations.append((
        mutated if candidate is system else system,
        mutated if candidate is resilience else resilience,
        mutated if candidate is protocols else protocols,
        mutated if candidate is uninstall_module else uninstall_module,
    ))

reconcile_arm_after_writer = firewall_mutate_function(
    system,
    "rr_reconcile_protocol_firewall_locked() {",
    "\nrr_validate_protocol_firewall() {",
    "rr_firewall_inflight_begin_locked",
    "true",
)
reconcile_arm_after_writer = firewall_mutate_function(
    reconcile_arm_after_writer,
    "rr_reconcile_protocol_firewall_locked() {",
    "\nrr_validate_protocol_firewall() {",
    "# No durable write is attempted",
    "rr_firewall_inflight_begin_locked || return 2\n\n"
    "    # No durable write is attempted",
)
firewall_inflight_mutations.append((
    reconcile_arm_after_writer,
    resilience,
    protocols,
    uninstall_module,
))

save_arm_after_writer = firewall_mutate_function(
    system,
    "save_firewall() {",
    "\nrr_save_firewall_locked() {",
    "rr_firewall_inflight_begin_locked",
    "true",
)
save_arm_after_writer = firewall_mutate_function(
    save_arm_after_writer,
    "save_firewall() {",
    "\nrr_save_firewall_locked() {",
    "rr_save_firewall_locked || result=$?",
    "rr_save_firewall_locked || result=$?\n"
    "    rr_firewall_inflight_begin_locked || result=2",
)
firewall_inflight_mutations.append((
    save_arm_after_writer,
    resilience,
    protocols,
    uninstall_module,
))

for mutated_candidates in firewall_inflight_mutations:
    assert mutated_candidates != (system, resilience, protocols, uninstall_module)
    assert not firewall_release_contract(*mutated_candidates)


def firewall_menu_batch_contract(candidate):
    try:
        preflight = firewall_function_slice(
            candidate,
            "rr_firewall_preflight_stage_operations() {",
            "\nrr_firewall_future_config_value() {",
        )
        normalize = firewall_function_slice(
            candidate,
            "rr_firewall_normalize_stage_operations() {",
            "\nrr_firewall_apply_stage_operations() {",
        )
        apply_stage = firewall_function_slice(
            candidate,
            "rr_firewall_apply_stage_operations() {",
            "\nrr_firewall_run_menu_callback() {",
        )
        wrapper = firewall_function_slice(
            candidate,
            "apply_config_firewall_batch() {",
            "\napply_config_firewall_batch_locked() {",
        )
        locked = firewall_function_slice(
            candidate,
            "apply_config_firewall_batch_locked() {",
            "\napply_hop_main_port_configuration() {",
        )
        normalize_step = locked.index(
            'rr_firewall_normalize_stage_operations "$operations_name" '
            '"$updates_name"'
        )
        batch_begin = locked.index("rr_firewall_batch_begin || return 1", normalize_step)
        preflight_step = locked.index(
            "rr_firewall_preflight_stage_operations normalized_operations",
            batch_begin,
        )
        apply_step = locked.index(
            "rr_firewall_apply_stage_operations normalized_operations",
            preflight_step,
        )
        stage_failure_start = locked.index(
            'if [ "$stage_status" -ne 0 ]; then', apply_step
        )
        config_failure_start = locked.index(
            'if ! apply_config_transaction "$description" "${updates_ref[@]}"; then',
            stage_failure_start,
        )
        config_applied = locked.index("config_applied=true", config_failure_start)
        commit_call = locked.index(
            "if rr_firewall_batch_commit; then commit_status=0; else commit_status=$?; fi",
            config_applied,
        )
        commit_dispatch = locked.index('case "$commit_status" in', commit_call)
        success_start = locked.index("\n        0)", commit_dispatch)
        restored_start = locked.index("\n        10)", success_start)
        indeterminate_start = locked.index("\n        11|12|*)", restored_start)
        commit_dispatch_end = locked.index("\n    esac", indeterminate_start)
        stage_failure = locked[stage_failure_start:config_failure_start]
        config_failure = locked[config_failure_start:config_applied]
        committed = locked[success_start:restored_start]
        restored = locked[restored_start:indeterminate_start]
        indeterminate = locked[indeterminate_start:commit_dispatch_end]
    except ValueError:
        return False

    preflight_required = (
        'IFS=\'|\' read -r kind first second third fourth extra <<< "$record"',
        'case "$kind" in',
        "protocol)",
        "hop)",
        'case "$first" in open|closed)',
        'case "$third" in tcp|udp)',
        'case "$first" in HY2|TU5)',
        "rr_firewall_filter_authority_mode filter_mode || return 1",
        "rr_firewall_persistence_backend_available",
        'rr_firewall_hop_spec_lists_are_disjoint "$hy2_new" "$tu5_new"',
        'rr_firewall_hop_program_first_match_is_safe "$first" "$second"',
        '"$fourth" pre "$third"',
    )
    preflight_forbidden_writers = (
        "open_protocol_firewall", "close_protocol_firewall",
        "rr_firewall_batch_replace_hop_rules", "rr_firewall_batch_begin",
        "rr_firewall_batch_commit", "apply_config_transaction",
        "systemctl ", "save_firewall",
    )
    normalize_required = (
        'local -a hop_records=() tuple_order=()',
        'local -A tuple_seen=() tuple_desired=()',
        'tuple="${second}|${third}"',
        'elif [ "$first" = open ]; then',
        'output_ref+=("${hop_records[@]}")',
        'rr_firewall_protocol_tuple_needed_after_updates "$tuple_port"',
        '[ "$desired_state" = closed ] || return 1',
        'output_ref+=("protocol|${desired_state}|${tuple_port}|${tuple_type}")',
    )
    apply_required = (
        "rr_firewall_batch_is_active || return 1",
        'open_protocol_firewall "$second" "$third" ||',
        "operation_status=$?",
        'close_protocol_firewall "$second" "$third" ||',
        '[ "$operation_status" -eq 0 ] || return "$operation_status"',
        'rr_firewall_batch_replace_hop_rules "$first" "$second"',
        '"$third" "$fourth" || operation_status=$?',
    )
    locked_required = (
        "rr_firewall_lock_is_held || return 1",
        "local RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH=1",
        "if rr_firewall_fail_closed_quarantine_active; then",
        "case \"$service_policy\" in ensure-running|preserve)",
        'rr_firewall_config_values_match old_updates || rollback_failed=true',
        "rr_firewall_restore_menu_service_state",
        "rr_firewall_fail_closed_stop_nodes",
        'rr_firewall_run_menu_callback "$cleanup_callback"',
        '"$indeterminate_cleanup_callback"',
    )
    if not all(token in preflight for token in preflight_required) or \
       any(token in preflight for token in preflight_forbidden_writers) or \
       not all(token in normalize for token in normalize_required) or \
       not all(token in apply_stage for token in apply_required):
        return False
    if not firewall_tokens_are_ordered(wrapper, (
        "rr_firewall_lock_acquire || return 1",
        'apply_config_firewall_batch_locked "$@"',
        "rr_firewall_lock_release",
        "rr_firewall_fail_closed_stop_nodes",
    )):
        return False
    if not all(token in locked for token in locked_required):
        return False
    if not normalize_step < batch_begin < preflight_step < apply_step \
       < stage_failure_start < config_failure_start < config_applied \
       < commit_call < commit_dispatch < success_start < restored_start \
       < indeterminate_start < commit_dispatch_end:
        return False

    # A pre-config writer failure is either exactly compensated and the v1
    # gate cleared, or promoted to durable v2 before all public runtimes are
    # stopped.  It cannot fall through into the config commit.
    if not firewall_tokens_are_ordered(stage_failure, (
        "rr_firewall_batch_abort || abort_failed=true",
        'if [ "$stage_status" -ge 2 ] || [ "$abort_failed" = true ]; then',
        "rr_firewall_inflight_is_owned",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_fail_closed_stop_nodes",
        "return \"$stop_status\"",
        "rr_firewall_inflight_is_owned",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_fail_closed_stop_nodes",
        "return 1",
    )):
        return False

    # Config publication failure must quiesce the menu runtimes, compensate
    # firewall + config, prove both old values and old runtime state, or retain
    # a v2 gate and execute the common fail-closed stop proof.
    if not firewall_tokens_are_ordered(config_failure, (
        "rr_firewall_quiesce_menu_runtimes || quiesce_failed=true",
        "rr_firewall_batch_abort || abort_failed=true",
        "rr_firewall_config_values_match old_updates || rollback_failed=true",
        "rr_firewall_inflight_finish_locked",
        'rr_firewall_restore_menu_service_state "$service_was_running"',
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_fail_closed_stop_nodes",
        "return 1",
    )):
        return False

    # commit_status=0 has two subpaths.  Normal success clears v1, proves
    # readiness, releases batch evidence, then runs the post-commit callback.
    # Readiness failure re-arms v1 before touching config/firewall, rolls both
    # back and persists the old program, proves config + services, then clears
    # v1.  Every incomplete proof flows to durable fail-closed isolation.
    if not firewall_tokens_are_ordered(committed, (
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_fail_closed_stop_nodes",
        'if [ "$service_policy" = ensure-running ]',
        'rr_firewall_run_menu_callback "$precommit_callback"',
        'if [ "$readiness_failed" = true ]; then',
        "rr_firewall_inflight_begin_locked",
        'rr_firewall_run_menu_callback "$cleanup_callback"',
        'apply_config_transaction "回滚 ${description}"',
        "rr_firewall_batch_rollback_operations",
        "save_firewall",
        "rr_firewall_config_values_match old_updates",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_batch_cleanup",
        "rr_firewall_restore_menu_service_state",
        "rr_firewall_fail_closed_stop_nodes",
        "return 1",
        "rr_firewall_batch_cleanup",
        'rr_firewall_run_menu_callback "$success_callback"',
        '"$indeterminate_cleanup_callback"',
        "rr_firewall_fail_closed_stop_nodes",
        "return 0",
    )):
        return False
    if committed.count("rr_firewall_inflight_begin_locked") != 1 or \
       committed.count("rr_firewall_inflight_finish_locked") != 2 or \
       committed.count("rr_firewall_fail_closed_stop_nodes") != 4:
        return False

    # commit_status=10 means the firewall was already compensated.  Config,
    # callbacks and runtime state must independently return to the old values;
    # otherwise the still-owned v1 is promoted and public ingress is stopped.
    if not firewall_tokens_are_ordered(restored, (
        "rr_firewall_quiesce_menu_runtimes",
        'rr_firewall_run_menu_callback "$cleanup_callback"',
        'apply_config_transaction "回滚 ${description}"',
        "rr_firewall_config_values_match old_updates",
        "rr_firewall_inflight_finish_locked",
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_batch_cleanup",
        'rr_firewall_restore_menu_service_state "$service_was_running"',
        "rr_firewall_promote_inflight_locked",
        "rr_firewall_fail_closed_stop_nodes",
        "return 1",
    )):
        return False

    # 11/12/unknown are never downgraded.  Promote any owned v1, run only the
    # indeterminate cleanup hook, then prove the fail-closed runtime stop.
    if not firewall_tokens_are_ordered(indeterminate, (
        "rr_firewall_inflight_is_owned",
        "rr_firewall_promote_inflight_locked",
        '"$indeterminate_cleanup_callback"',
        "rr_firewall_fail_closed_stop_nodes",
        "return \"$stop_status\"",
    )):
        return False

    return (
        locked.count("rr_firewall_batch_abort") == 2
        and locked.count("rr_firewall_batch_commit") == 1
        and locked.count("rr_firewall_config_values_match old_updates") == 3
        and locked.count(
            'rr_firewall_restore_menu_service_state "$service_was_running"'
        ) == 2
    )


assert firewall_menu_batch_contract(protocols)

readiness_arm_after_config = mutate_function_slice(
    protocols,
    'if [ "$readiness_failed" = true ]; then',
    '\n            if ! rr_firewall_batch_cleanup; then',
    "if ! rr_firewall_inflight_begin_locked; then",
    "if ! true; then",
)
readiness_arm_after_config = mutate_function_slice(
    readiness_arm_after_config,
    'if [ "$readiness_failed" = true ]; then',
    '\n            if ! rr_firewall_batch_cleanup; then',
    "rr_firewall_batch_rollback_operations",
    "rr_firewall_inflight_begin_locked || rollback_failed=true\n"
    "                   ! rr_firewall_batch_rollback_operations",
)

indeterminate_promote_after_stop = mutate_function_slice(
    protocols,
    '\n        11|12|*)\n            rr_firewall_inflight_is_owned',
    '\n    esac',
    "rr_firewall_promote_inflight_locked",
    "true # delayed promotion",
)
indeterminate_promote_after_stop = mutate_function_slice(
    indeterminate_promote_after_stop,
    '\n        11|12|*)\n            rr_firewall_inflight_is_owned',
    '\n    esac',
    "rr_firewall_fail_closed_stop_nodes",
    "rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true\n"
    "            rr_firewall_fail_closed_stop_nodes",
)

firewall_menu_mutations = (
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch() {",
        "\napply_config_firewall_batch_locked() {",
        "rr_firewall_lock_acquire || return 1",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        "rr_firewall_lock_is_held || return 1",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        "rr_firewall_normalize_stage_operations",
        "removed_firewall_normalization",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        "rr_firewall_batch_begin || return 1",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        "rr_firewall_preflight_stage_operations normalized_operations",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        'apply_config_transaction "$description" "${updates_ref[@]}"',
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "apply_config_firewall_batch_locked() {",
        "\napply_hop_main_port_configuration() {",
        "rr_firewall_batch_commit",
        "removed_firewall_commit",
    ),
    firewall_mutate_function(
        protocols,
        "rr_firewall_preflight_stage_operations() {",
        "\nrr_firewall_future_config_value() {",
        "rr_firewall_persistence_backend_available",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "rr_firewall_preflight_stage_operations() {",
        "\nrr_firewall_future_config_value() {",
        '"$fourth" pre "$third"',
        '"$fourth" post "$third"',
    ),
    firewall_mutate_function(
        protocols,
        "rr_firewall_normalize_stage_operations() {",
        "\nrr_firewall_apply_stage_operations() {",
        'output_ref+=("${hop_records[@]}")',
        ": # removed NAT-first normalization",
    ),
    firewall_mutate_function(
        protocols,
        "rr_firewall_apply_stage_operations() {",
        "\nrr_firewall_run_menu_callback() {",
        "rr_firewall_batch_is_active || return 1",
        "true",
    ),
    firewall_mutate_function(
        protocols,
        "rr_firewall_apply_stage_operations() {",
        "\nrr_firewall_run_menu_callback() {",
        "rr_firewall_batch_replace_hop_rules",
        "install_hop_rules",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_inflight_begin_locked",
        "removed_readiness_inflight_begin",
    ),
    readiness_arm_after_config,
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        'apply_config_transaction "回滚 ${description}"',
        "removed_readiness_config_rollback",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_batch_rollback_operations",
        "removed_readiness_firewall_rollback",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "save_firewall",
        "removed_readiness_persistence",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_config_values_match old_updates",
        "removed_readiness_config_proof",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_inflight_finish_locked",
        "removed_readiness_inflight_finish",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_promote_inflight_locked",
        "removed_readiness_v2_promotion",
    ),
    mutate_function_slice(
        protocols,
        'if [ "$readiness_failed" = true ]; then',
        '\n            if ! rr_firewall_batch_cleanup; then',
        "rr_firewall_fail_closed_stop_nodes",
        "removed_readiness_fail_closed_stop",
    ),
    mutate_function_slice(
        protocols,
        '\n        10)\n            quiesce_failed=false',
        '\n        11|12|*)',
        'apply_config_transaction "回滚 ${description}"',
        "removed_status10_config_rollback",
    ),
    mutate_function_slice(
        protocols,
        '\n        10)\n            quiesce_failed=false',
        '\n        11|12|*)',
        "rr_firewall_inflight_finish_locked",
        "removed_status10_inflight_finish",
    ),
    mutate_function_slice(
        protocols,
        '\n        10)\n            quiesce_failed=false',
        '\n        11|12|*)',
        "rr_firewall_fail_closed_stop_nodes",
        "removed_status10_fail_closed_stop",
    ),
    mutate_function_slice(
        protocols,
        '\n        11|12|*)\n            rr_firewall_inflight_is_owned',
        '\n    esac',
        "rr_firewall_promote_inflight_locked",
        "removed_indeterminate_v2_promotion",
    ),
    mutate_function_slice(
        protocols,
        '\n        11|12|*)\n            rr_firewall_inflight_is_owned',
        '\n    esac',
        "rr_firewall_fail_closed_stop_nodes",
        "removed_indeterminate_fail_closed_stop",
    ),
    indeterminate_promote_after_stop,
)
for mutated in firewall_menu_mutations:
    assert mutated != protocols
    assert not firewall_menu_batch_contract(mutated)


menu_writer_callbacks = (
    "install_main", "change_cdn", "refresh_argo", "install_f2b",
    "toggle_auto_update", "protocol_menu", "sb_control_menu",
    "ip_stack_menu", "subscription_port_menu", "nexus_menu",
)


def menu_writer_exclusion_contract(menu_candidate, resilience_candidate):
    try:
        wrapper = firewall_function_slice(
            menu_candidate,
            "rr_menu_run_writer() {",
            "\nmain_menu() {",
        )
        main = menu_candidate[menu_candidate.index("main_menu() {"):]
        dispatch_start = main.index('        case "$menu_choice" in')
        dispatch_end = main.index("\n        esac", dispatch_start)
        dispatch = main[dispatch_start:dispatch_end]
        entrypoint = firewall_function_slice(
            resilience_candidate,
            "rr_run_mutating_entrypoint() {",
            "\nrr_ensure_resilience_dependencies() {",
        )
        health = main.index("rr_run_health_check")
        loop = main.index("while true; do", health)
    except ValueError:
        return False

    wrapped = tuple(re.findall(
        r"rr_menu_run_writer\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+\|\|\s+:",
        dispatch,
    ))
    wrapper_required = (
        'local callback="$1" result=0',
        'rr_run_mutating_entrypoint "$callback" "$@" || result=$?',
        'case "$result" in',
        "75)",
        "[忙碌]",
        "76)",
        "[安全拒绝]",
        'return "$result"',
    )
    entrypoint_required = (
        'declare -F "$callback" >/dev/null 2>&1 || return 76',
        'if [ "${RR_UPDATE_LOCK_HELD:-0}" = 1 ]; then',
        "rr_delegated_update_lock_context_is_trusted || return 76",
        '"$callback" "$@"',
        'rr_run_with_update_locks isolated 0 "$callback" "$@" || result=$?',
        'return "$result"',
    )
    return (
        all(token in wrapper for token in wrapper_required)
        and all(token in entrypoint for token in entrypoint_required)
        and wrapped == menu_writer_callbacks
        and dispatch.count("rr_menu_run_writer ") == len(menu_writer_callbacks)
        and health < loop
        and "ensure_runtime_health" not in main[:loop]
        and re.search(r"2\).*then show_info;", dispatch) is not None
        and "10) show_ports ;;" in dispatch
        and "6) uninstall_all ;;" in dispatch
        and "8) do_update ;;" in dispatch
        and not any(
            f"rr_menu_run_writer {callback}" in dispatch
            for callback in ("show_info", "show_ports", "uninstall_all", "do_update")
        )
        and "flock " not in wrapper
        and "flock " not in main
    )


assert menu_writer_exclusion_contract(menus, resilience)
menu_writer_mutations = [
    menus.replace("    rr_run_health_check ||", "    ensure_runtime_health ||", 1),
    menus.replace("then show_info;", "then rr_menu_run_writer show_info || :;", 1),
    menus.replace("10) show_ports ;;", "10) rr_menu_run_writer show_ports || : ;;", 1),
    menus.replace("6) uninstall_all ;;", "6) rr_menu_run_writer uninstall_all || : ;;", 1),
    menus.replace("8) do_update ;;", "8) rr_menu_run_writer do_update || : ;;", 1),
    menus.replace("[忙碌]", "[稍后]", 1),
    menus.replace("[安全拒绝]", "[拒绝]", 1),
]
for callback in menu_writer_callbacks:
    menu_writer_mutations.append(menus.replace(
        f"rr_menu_run_writer {callback}", callback, 1
    ))
    menu_writer_mutations.append(menus.replace(
        f"rr_menu_run_writer {callback} || :", f"rr_menu_run_writer {callback}", 1
    ))
for mutated in menu_writer_mutations:
    assert mutated != menus
    assert not menu_writer_exclusion_contract(mutated, resilience)

menu_entrypoint_mutations = (
    resilience.replace(
        'rr_run_with_update_locks isolated 0 "$callback" "$@" || result=$?',
        'rr_run_with_update_locks isolated 60 "$callback" "$@" || result=$?',
        1,
    ),
    resilience.replace(
        "rr_delegated_update_lock_context_is_trusted || return 76",
        ": # delegated ownership authentication removed",
        1,
    ),
)
for mutated in menu_entrypoint_mutations:
    assert mutated != resilience
    assert not menu_writer_exclusion_contract(menus, mutated)


def installer_restore_gate_contract(candidate):
    default_path = (
        'RR_RESTORE_ACTIVE="${RR_RESTORE_ACTIVE:-/var/lib/rr-backup/active}"'
    )
    try:
        gate_start = candidate.index("rr_install_release_after_locks() {")
        gate_end = candidate.index("\n}\n", gate_start) + len("\n}\n")
        entry_start = candidate.index('\ncase "$RR_MODE" in', gate_end)
    except ValueError:
        return False
    gate_definitions = re.findall(
        r"(?m)^\s*(?:function\s+)?rr_install_release_after_locks\s*"
        r"(?:\(\s*\))?\s*\{",
        candidate,
    )
    if (
        candidate.count(default_path) != 1
        or len(gate_definitions) != 1
        or candidate.count("rr_install_release_after_locks") != 2
    ):
        return False

    gate = candidate[gate_start:gate_end]
    lines = [
        line.strip() for line in gate.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(lines) != 8:
        return False
    if lines[0] != "rr_install_release_after_locks() {" or lines[-1] != "}":
        return False
    if lines[1] != (
        'if [ -e "$RR_RESTORE_ACTIVE" ] || '
        '[ -L "$RR_RESTORE_ACTIVE" ]; then'
    ):
        return False
    if not lines[2].startswith('rr_error "') or lines[3:7] != [
        "return 1",
        "fi",
        "rr_fetch_release || return 1",
        "rr_install_release",
    ]:
        return False

    entry = candidate[entry_start:]
    try:
        system_check = entry.index("rr_check_system || exit 1")
        prepare_lock = entry.index(
            'rr_prepare_update_lock_file "$RR_UPDATE_LOCK_FILE" || {',
            system_check,
        )
        prepare_lock_end = entry.index("\n}\n", prepare_lock) + len("\n}\n")
        open_lock = entry.index(
            'exec {UPDATE_LOCK_FD}>>"$RR_UPDATE_LOCK_FILE" || exit 1',
            prepare_lock_end,
        )
        validate_lock = entry.index(
            'rr_update_lock_fd_is_safe "$RR_UPDATE_LOCK_FILE" '
            '"$UPDATE_LOCK_FD" || {',
            open_lock,
        )
        validate_lock_end = entry.index("\n}\n", validate_lock) + len("\n}\n")
        shared_lock = entry.index('if ! flock -n "$UPDATE_LOCK_FD"; then')
        shared_lock_end = entry.index("\nfi\n", shared_lock) + len("\nfi\n")
        legacy_lock = entry.index(
            'if ! rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"; then',
            shared_lock_end,
        )
        legacy_end = entry.index("\nfi\n", legacy_lock) + len("\nfi\n")
        gate_call = entry.index(
            "rr_install_release_after_locks || exit 1", legacy_end
        )
    except ValueError:
        return False
    if not (
        system_check < prepare_lock < prepare_lock_end <= open_lock
        < validate_lock < validate_lock_end <= shared_lock < shared_lock_end
        <= legacy_lock < legacy_end <= gate_call
    ):
        return False
    fail_closed_blocks = (
        entry[prepare_lock:prepare_lock_end],
        entry[validate_lock:validate_lock_end],
        entry[shared_lock:shared_lock_end],
        entry[legacy_lock:legacy_end],
    )
    if any(block.count("\n    exit 1\n") != 1 for block in fail_closed_blocks):
        return False
    if entry.count("rr_install_release_after_locks || exit 1") != 1:
        return False
    if entry[legacy_end:gate_call].strip():
        return False
    forbidden_before_gate = (
        "rr_fetch_release",
        "rr_install_release",
        "rr_prepare_recovery_runtime",
    )
    return not any(name in entry[:gate_call] for name in forbidden_before_gate)


assert installer_restore_gate_contract(installer)


def fail_open_entry_block(candidate, start_token, end_token):
    start = candidate.index(start_token)
    end = candidate.index(end_token, start) + len(end_token)
    block = candidate[start:end]
    assert "\n    exit 1\n" in block
    return (
        candidate[:start]
        + block.replace("\n    exit 1\n", "\n    :\n", 1)
        + candidate[end:]
    )


installer_gate_mutations = (
    installer.replace(
        'if [ -e "$RR_RESTORE_ACTIVE" ] || [ -L "$RR_RESTORE_ACTIVE" ]; then',
        'if [ -e "$RR_RESTORE_ACTIVE" ]; then',
        1,
    ),
    installer.replace(
        '        return 1\n    fi\n    rr_fetch_release || return 1',
        '        return 0\n    fi\n    rr_fetch_release || return 1',
        1,
    ),
    installer.replace(
        '    if [ -e "$RR_RESTORE_ACTIVE" ] || [ -L "$RR_RESTORE_ACTIVE" ]; then',
        '    rr_fetch_release || return 1\n'
        '    if [ -e "$RR_RESTORE_ACTIVE" ] || [ -L "$RR_RESTORE_ACTIVE" ]; then',
        1,
    ),
    installer.replace(
        'if ! rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"; then',
        'if ! true; then',
        1,
    ),
    installer.replace(
        "rr_install_release_after_locks || exit 1",
        "rr_fetch_release || exit 1\nrr_install_release || exit 1",
        1,
    ),
    installer.replace(
        '\ncase "$RR_MODE" in',
        '\nrr_install_release_after_locks() {\n'
        '    rr_fetch_release || return 1\n'
        '    rr_install_release\n'
        '}\n\ncase "$RR_MODE" in',
        1,
    ),
    installer.replace(
        '\ncase "$RR_MODE" in',
        '\nfunction rr_install_release_after_locks {\n'
        '    rr_fetch_release || return 1\n'
        '    rr_install_release\n'
        '}\n\ncase "$RR_MODE" in',
        1,
    ),
    fail_open_entry_block(
        installer,
        'if ! flock -n "$UPDATE_LOCK_FD"; then',
        "\nfi\n",
    ),
    fail_open_entry_block(
        installer,
        'if ! rr_acquire_legacy_update_lock "$RR_LEGACY_UPDATE_LOCK_FILE"; then',
        "\nfi\n",
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "rr_fetch_release || exit 2\nrr_check_system || exit 1",
        1,
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "rr_install_release\nrr_check_system || exit 1",
        1,
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "rr_prepare_recovery_runtime\nrr_check_system || exit 1",
        1,
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "rr_fetch_release; rr_check_system || exit 1",
        1,
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "command rr_fetch_release\nrr_check_system || exit 1",
        1,
    ),
    installer.replace(
        "rr_check_system || exit 1",
        "RR_UNSAFE=1 rr_install_release\nrr_check_system || exit 1",
        1,
    ),
)
for mutated in installer_gate_mutations:
    assert mutated != installer
    assert not installer_restore_gate_contract(mutated)

# Portable restore owns the durable rollback snapshot and performs one narrow
# ordinary reconciliation in its orchestrator.  The system layer may consume
# RR_PORTABLE_RESTORE only together with the explicit UFW-authority bit and the
# held restore lock; no generic transaction reader may use the ambient flag as
# a writer authorization by itself.  Naive's separate exception is a read-only
# hook-integrity check after its transaction has validated and synchronized the
# certificate pair.
authority_start = system.index("rr_firewall_filter_authority_mode() {")
authority_end = system.index("\n}\n", authority_start) + len("\n}\n")
authority = system[authority_start:authority_end]
assert system.count("RR_PORTABLE_RESTORE") == 1
assert '[ "${RR_PORTABLE_RESTORE:-0}" = 1 ]' in authority
assert '[ "${RR_RESTORE_LOCK_HELD:-0}" = 1 ]' in authority
assert 'case "${RR_PORTABLE_UFW_AUTHORITY:-0}" in' in authority
assert "RR_PORTABLE_RESTORE=0 post_update_migrate" in launcher

ensure_naive_start = singbox.index("ensure_naive_certificate() {")
ensure_naive_end = singbox.index(
    "\nrr_certificate_deploy_hook_is_current() {", ensure_naive_start
)
ensure_naive = singbox[ensure_naive_start:ensure_naive_end]


def naive_portable_branch_is_read_only(candidate):
    transaction = '    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then\n'
    certificate_check = "        if ! naive_certificate_pair_valid \\\n"
    certificate_sync = (
        '        sync_naive_certificate_pair "${le_live_root}/${naive_domain}" '
        "\\\n            \"$naive_cert_dir\" \"$naive_domain\" || return 1\n"
    )
    portable = '        if [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then\n'
    ordinary = "        else\n"
    branch_end = "        fi\n        return 0\n"
    if candidate.count(transaction) != 1 or candidate.count(portable) != 1:
        return False
    if candidate.count("RR_PORTABLE_RESTORE") != 1:
        return False
    tx_at = candidate.index(transaction)
    portable_at = candidate.index(portable, tx_at)
    if candidate.find(certificate_check, tx_at, portable_at) < 0:
        return False
    if candidate.find(certificate_sync, tx_at, portable_at) < 0:
        return False
    else_at = candidate.find(ordinary, portable_at + len(portable))
    end_at = candidate.find(branch_end, else_at + len(ordinary))
    if else_at < 0 or end_at < 0:
        return False
    portable_body = candidate[portable_at + len(portable):else_at]
    portable_lines = [
        line.strip() for line in portable_body.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(portable_lines) != 4:
        return False
    if portable_lines[0] != "rr_certificate_deploy_hook_is_current || {":
        return False
    if not portable_lines[1].startswith("echo "):
        return False
    if portable_lines[2:] != ["return 1", "}"]:
        return False
    ordinary_lines = [
        line.strip() for line in candidate[
            else_at + len(ordinary):end_at
        ].splitlines() if line.strip()
    ]
    if ordinary_lines != ["deploy_naive_cert_hook || return 1"]:
        return False
    forbidden_portable_writes = (
        "certbot", "prepare_naive_acme_webroot", "open_configured_firewall",
        "save_firewall", "deploy_naive_cert_hook", "sync_naive_certificate_pair",
        "install ", "mkdir ", "rm ", "mv ", "cp ", "ln ", "chmod ",
        "chown ", "systemctl ", "apt-get ",
    )
    return not any(token in portable_body for token in forbidden_portable_writes)


assert singbox.count("RR_PORTABLE_RESTORE") == 1
assert naive_portable_branch_is_read_only(ensure_naive)
naive_mutations = (
    ensure_naive.replace(
        "            rr_certificate_deploy_hook_is_current || {",
        "            deploy_naive_cert_hook || {",
        1,
    ),
    ensure_naive.replace(
        "            rr_certificate_deploy_hook_is_current || {",
        "            certbot renew\n"
        "            rr_certificate_deploy_hook_is_current || {",
        1,
    ),
    ensure_naive.replace(
        "            rr_certificate_deploy_hook_is_current || {",
        "            prepare_naive_acme_webroot \"$naive_domain\"\n"
        "            rr_certificate_deploy_hook_is_current || {",
        1,
    ),
    ensure_naive.replace(
        "            rr_certificate_deploy_hook_is_current || {",
        "            open_configured_firewall\n"
        "            rr_certificate_deploy_hook_is_current || {",
        1,
    ),
    ensure_naive.replace(
        "            deploy_naive_cert_hook || return 1",
        "            rr_certificate_deploy_hook_is_current || return 1",
        1,
    ),
)
for mutated in naive_mutations:
    assert mutated != ensure_naive
    assert not naive_portable_branch_is_read_only(mutated)

subscription_start = config.index("start_subscription_server() {")
subscription_server = config[subscription_start:]


def subscription_portable_branch_is_read_only(candidate):
    certificate_check = (
        '            subscription_certificate_pair_valid "$cert_file" '
        '"$key_file" "$SUB_DOMAIN" || {\n'
    )
    portable = (
        '            if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] && \\\n'
        '               [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then\n'
    )
    ordinary = "            else\n"
    branch_end = "            fi\n"
    if candidate.count("RR_PORTABLE_RESTORE") != 1:
        return False
    try:
        certificate_at = candidate.index(certificate_check)
        portable_at = candidate.index(portable, certificate_at)
        else_at = candidate.index(ordinary, portable_at + len(portable))
        end_at = candidate.index(branch_end, else_at + len(ordinary))
    except ValueError:
        return False
    portable_body = candidate[portable_at + len(portable):else_at]
    ordinary_body = candidate[else_at + len(ordinary):end_at]
    portable_lines = [
        line.strip() for line in portable_body.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if portable_lines != [
        "declare -F rr_certificate_deploy_hook_is_current \\",
        ">/dev/null 2>&1 || return 1",
        "rr_certificate_deploy_hook_is_current || return 1",
    ]:
        return False
    ordinary_lines = [line.strip() for line in ordinary_body.splitlines() if line.strip()]
    if ordinary_lines != ["deploy_subscription_cert_hook || return 1"]:
        return False
    forbidden_writes = (
        "deploy_subscription_cert_hook", "certbot", "install ", "mkdir ",
        "rm ", "mv ", "cp ", "ln ", "chmod ", "chown ", "systemctl ",
        "open_configured_firewall", "save_firewall",
    )
    return not any(token in portable_body for token in forbidden_writes)


assert config.count("RR_PORTABLE_RESTORE") == 1
assert subscription_portable_branch_is_read_only(subscription_server)
subscription_mutations = (
    subscription_server.replace(
        "                rr_certificate_deploy_hook_is_current || return 1",
        "                deploy_subscription_cert_hook || return 1",
        1,
    ),
    subscription_server.replace(
        "                rr_certificate_deploy_hook_is_current || return 1",
        "                certbot renew\n"
        "                rr_certificate_deploy_hook_is_current || return 1",
        1,
    ),
    subscription_server.replace(
        "                rr_certificate_deploy_hook_is_current || return 1",
        "                install source target\n"
        "                rr_certificate_deploy_hook_is_current || return 1",
        1,
    ),
    subscription_server.replace(
        "                deploy_subscription_cert_hook || return 1",
        "                rr_certificate_deploy_hook_is_current || return 1",
        1,
    ),
)
for mutated in subscription_mutations:
    assert mutated != subscription_server
    assert not subscription_portable_branch_is_read_only(mutated)


def target_snapshot_shape_contract(candidate):
    try:
        shape_start = candidate.index(
            "rr_restore_validate_target_snapshot_shape() {"
        )
        shape_end = candidate.index(
            "\nrr_restore_validate_portable_config() {", shape_start
        )
        shape = candidate[shape_start:shape_end]
        restore_start_at = candidate.index("rr_restore_backup_locked() {")
        restore_candidate = candidate[restore_start_at:]
        ownership = restore_candidate.index(
            "rr_restore_validate_target_ownership ||"
        )
        initial_shape = restore_candidate.index(
            "rr_restore_validate_target_snapshot_shape || {", ownership
        )
        first_mutation = restore_candidate.index(
            "rr_restore_migrate_legacy_fixed_token ||", initial_shape
        )
        unit_preflight = restore_candidate.index(
            "rr_restore_reject_unrestorable_unit_states ||", initial_shape
        )
        recovery_write = restore_candidate.index(
            "rr_restore_prepare_recovery_unit ||", initial_shape
        )
        freeze = restore_candidate.index(
            "rr_restore_freeze_writers || result=1", recovery_write
        )
        frozen_shape = restore_candidate.index(
            "rr_restore_validate_target_snapshot_shape || result=1", freeze
        )
        snapshot_loop = restore_candidate.index(
            "    for target in /etc/argo_vmess.conf", frozen_shape
        )
        complete = restore_candidate.index(
            'mv -f "$snapshot_tmp" "$rollback/complete"', snapshot_loop
        )
        complete_shape = restore_candidate.index(
            "rr_restore_validate_target_snapshot_shape || result=1", complete
        )
        prepared = restore_candidate.index(
            'rr_restore_write_phase "$stage" prepared || result=1',
            complete_shape,
        )
        runtime_stop = restore_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" || result=1', prepared
        )
        target_clear = restore_candidate.index(
            "rr_restore_clear_managed_tree", runtime_stop
        )
    except ValueError:
        return False

    if not ownership < initial_shape < unit_preflight < first_mutation:
        return False
    if not (
        initial_shape < recovery_write < freeze < frozen_shape < snapshot_loop
        < complete < complete_shape < prepared < runtime_stop < target_clear
    ):
        return False
    if restore_candidate.count("rr_restore_validate_target_snapshot_shape") != 3:
        return False
    required = (
        "return os.lstat(path)",
        "entry.stat(follow_symlinks=False)",
        "(info.st_uid, info.st_gid) != (0, 0)",
        "stat.S_ISDIR(info.st_mode)",
        "stat.S_ISREG(info.st_mode)",
        "stat.S_ISLNK(info.st_mode)",
        'validate_regular(config_path)',
        '"/etc/systemd/system/sing-box.service"',
        '"/etc/systemd/system/rr-nexus.service"',
        '"/etc/systemd/system/argo-rr-health.service"',
        '"/etc/systemd/system/argo-rr-health.timer"',
        '"/etc/systemd/system/cloudflared.service"',
        '"/etc/systemd/system/rr-restore-recovery.service"',
        '"/etc/systemd/system/rr-restore-watchdog.service"',
        '"/usr/local/bin/auto_update_sub.py"',
        '"/etc/sing-box", "/etc/rr-nexus", "/etc/rr-naive"',
        '"/etc/rr-update", "/etc/rr-cloudflared", "/var/lib/rr-nexus"',
        'validate_real_directory(rooted("/tmp/sub_server"))',
        "mountinfo=/proc/self/mountinfo",
        "os.O_NOFOLLOW",
        "MAX_MOUNTINFO_BYTES",
        "MAX_MOUNTINFO_LINES",
        "MAX_MOUNTINFO_LINE",
        'b"040": b" "',
        'b"011": b"\\t"',
        'b"012": b"\\n"',
        'b"134": b"\\\\"',
        "permissions & 0o7000",
        "permissions & 0o022",
        "permissions == 0o1777",
        "validate_managed_tree(dropin_directory)",
        "dropin_units = (",
        '"argo-rr-health.timer", "rr-restore-recovery.service",',
        '"rr-restore-watchdog.service",',
        "deletion_roots = (",
        '"/tmp/sub_server",',
        "exact_writers = {",
        "at_or_below(mountpoint, root)",
        '"/etc/nginx/sites-enabled/rr-nexus.conf"',
        '"/etc/nginx/sites-enabled/rr-nexus-port.conf"',
        '"/etc/nginx/sites-enabled/rr-nexus-ip.conf"',
        "raw_target = os.readlink(link)",
        "if raw_target not in allowed_targets:",
        "validate_regular(target, required=True)",
    )
    if not all(token in shape for token in required):
        return False
    if shape.count("(info.st_uid, info.st_gid) != (0, 0)") != 2:
        return False
    if shape.count("if info.st_nlink != 1:") != 2:
        return False
    if shape.count('"/etc/systemd/system/cloudflared.service",') != 2:
        return False
    if shape.count('"/etc/systemd/system/rr-restore-watchdog.service",') != 2:
        return False
    if shape.count(
        '"/etc/rr-update", "/etc/rr-cloudflared", "/var/lib/rr-nexus",'
    ) != 2:
        return False
    if shape.count("permissions == 0o1777") != 2:
        return False
    try:
        dropin_start = shape.index("    dropin_units = (")
        dropin_end = shape.index("    )", dropin_start)
        dropins = shape[dropin_start:dropin_end]
    except ValueError:
        return False
    for unit in (
        '"argo-rr-health.timer"',
        '"rr-restore-recovery.service"',
        '"rr-restore-watchdog.service"',
    ):
        if dropins.count(unit) != 1:
            return False
    forbidden_writes = (
        "os.unlink", "os.remove", "os.rename", "os.replace", "os.chmod",
        "os.chown", "shutil.", "subprocess", "systemctl", "certbot",
        "open_configured_firewall", "rr_restore_migrate_legacy_fixed_token",
    )
    return not any(token in shape for token in forbidden_writes)


def restore_replay_contract(candidate):
    try:
        apply_start = candidate.index("rr_restore_apply_tree() {")
        clear_start = candidate.index("\nrr_restore_clear_managed_tree() {", apply_start)
        derived_start = candidate.index("\nrr_restore_clear_derived_state() {", clear_start)
        crontab_start = candidate.index("\nrr_restore_crontab() {", derived_start)
        apply_tree = candidate[apply_start:clear_start]
        clear_tree = candidate[clear_start:derived_start]
        clear_derived = candidate[derived_start:crontab_start]
        tree_gate = clear_tree.index("rr_restore_validate_target_snapshot_shape ||")
        tree_delete = clear_tree.index("rm -rf -- /etc/sing-box", tree_gate)
        derived_gate = clear_derived.index("rr_restore_validate_target_snapshot_shape ||")
        derived_ensure = clear_derived.index(
            "ensure_subscription_root || return 1", derived_gate
        )
        derived_root = clear_derived.index(
            '[ "$SUB_ROOT" = /tmp/sub_server ] || return 1', derived_ensure
        )
        derived_final_gate = clear_derived.index(
            "rr_restore_validate_target_snapshot_shape ||", derived_root
        )
        derived_delete = clear_derived.index(
            'find "$SUB_ROOT" -mindepth 1 -xdev -delete', derived_final_gate
        )
    except ValueError:
        return False
    required = (
        'destination_root="${3:-/}"',
        'find "$root/rootfs" -mindepth 1 -type d -print0',
        'chmod 700 "$target"',
        '[ "$policy" = full ] || return 0',
        'find "$root/rootfs" -mindepth 1 -depth -type d -print0',
        '(( (source_mode_decimal & 07000) == 0 ))',
        '(( (source_mode_decimal & 00022) == 0 ))',
        "printf -v safe_mode '%03o'",
        'chmod "$safe_mode" "$target"',
    )
    return (
        tree_gate < tree_delete
        and derived_gate < derived_ensure < derived_root
        < derived_final_gate < derived_delete
        and clear_derived.count(
            "rr_restore_validate_target_snapshot_shape || return 1"
        ) == 2
        and all(token in apply_tree for token in required)
    )


def complete_shape_contract(candidate):
    return target_snapshot_shape_contract(candidate) and restore_replay_contract(candidate)


assert complete_shape_contract(resilience)


def restore_gate_effective_contract(candidate):
    try:
        shape_start = candidate.index("rr_restore_validate_target_snapshot_shape() {")
        shape_end = candidate.index("\nrr_restore_validate_portable_config() {", shape_start)
        shape = candidate[shape_start:shape_end]
        directory_start = candidate.index("rr_restore_gate_dropin_directory_is_safe() {")
        file_start = candidate.index("\nrr_restore_gate_dropin_file_is_exact() {", directory_start)
        firewall_file_start = candidate.index(
            "\nrr_restore_firewall_gate_dropin_file_is_exact() {", file_start
        )
        unit_gate_start = candidate.index(
            "\nrr_restore_unit_uses_firewall_gate() {", firewall_file_start
        )
        order_start = candidate.index(
            "\nrr_restore_effective_dropin_order_is_safe() {", unit_gate_start
        )
        effective_start = candidate.index("\nrr_restore_effective_gate_is_exact() {", order_start)
        preflight_start = candidate.index("\nrr_restore_preflight_gate_dropin_order() {", effective_start)
        set_start = candidate.index("\nrr_restore_effective_gate_set_is_exact() {", preflight_start)
        required_start = candidate.index(
            "\nrr_restore_required_effective_gate_set_is_exact() {", set_start
        )
        isolate_start = candidate.index("\nrr_restore_isolate_gate_units() {", set_start)
        writer_start = candidate.index("\nrr_restore_write_gate_dropins() {", isolate_start)
        prepare_start = candidate.index("\nrr_restore_prepare_recovery_unit() {", writer_start)
        service_gate_start = candidate.index("\nrr_restore_service_gate() {", prepare_start)
        directory = candidate[directory_start:file_start]
        exact_file = candidate[file_start:firewall_file_start]
        firewall_exact_file = candidate[firewall_file_start:unit_gate_start]
        unit_gate = candidate[unit_gate_start:order_start]
        order = candidate[order_start:effective_start]
        effective = candidate[effective_start:preflight_start]
        preflight = candidate[preflight_start:set_start]
        required = candidate[required_start:isolate_start]
        isolate = candidate[isolate_start:writer_start]
        writer = candidate[writer_start:prepare_start]
        prepare = candidate[prepare_start:service_gate_start]
        restore_start = candidate.index("rr_restore_backup_locked() {")
        restore = candidate[restore_start:]
        initial_shape = restore.index("rr_restore_validate_target_snapshot_shape || {")
        order_preflight = restore.index(
            "rr_restore_preflight_gate_dropin_order || {", initial_shape
        )
        first_mutation = restore.index(
            "rr_restore_migrate_legacy_fixed_token ||", order_preflight
        )
        reload_gate = prepare.index("if ! systemctl daemon-reload")
        effective_gate = prepare.index(
            "if ! rr_restore_effective_gate_set_is_exact", reload_gate
        )
        enable_recovery = prepare.index(
            "systemctl enable rr-restore-recovery.service", effective_gate
        )
        regenerate_start = candidate.index("rr_restore_regenerate_runtime_files() {")
        regenerate_end = candidate.index("\nrr_restore_verify_manifest() {", regenerate_start)
        regenerate = candidate[regenerate_start:regenerate_end]
        regenerate_reload = regenerate.index("systemctl daemon-reload")
        regenerate_gate = regenerate.index(
            "rr_restore_require_effective_gates_or_isolate", regenerate_reload
        )
        cloud_start = candidate.index("rr_restore_apply_cloudflared_snapshot() {")
        cloud_end = candidate.index("\nrr_restore_migrate_with_original_state() {", cloud_start)
        cloud_apply = candidate[cloud_start:cloud_end]
        cloud_reload = cloud_apply.index("systemctl daemon-reload")
        cloud_gate = cloud_apply.index(
            "rr_restore_require_effective_gates_or_isolate", cloud_reload
        )
        cloud_enable = cloud_apply.index("systemctl enable cloudflared", cloud_gate)
        abort_start = candidate.index("rr_restore_abort_pre_mutation_stage() {")
        abort_end = candidate.index("\nrr_restore_rollback_stage() {", abort_start)
        abort = candidate[abort_start:abort_end]
        abort_gate = abort.index("rr_restore_require_effective_gates_or_isolate")
        abort_ready = abort.index('rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY"')
        rollback_start = abort_end + 1
        rollback_end = candidate.index("\nrr_restore_recover_active() {", rollback_start)
        rollback = candidate[rollback_start:rollback_end]
        rollback_gate = rollback.index("rr_restore_require_effective_gates_or_isolate")
        rollback_ready = rollback.index('rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY"')
        main_gate = restore.index("rr_restore_require_effective_gates_or_isolate")
        main_start = min(
            restore.index("rr_restore_migrate_with_original_state", main_gate),
            restore.index("post_update_migrate", main_gate),
        )
    except ValueError:
        return False

    shape_required = (
        'RESTORE_GATE_DROPIN = b"zzzz-rr-restore-gate.conf"',
        'FIREWALL_GATE_DROPIN = b"zzzzz-rr-firewall-quarantine.conf"',
        'and name > RESTORE_GATE_DROPIN',
        'and name != FIREWALL_GATE_DROPIN',
        '"systemd drop-in sorts after the restore gate"',
        'exact_writers.add(f"{dropin}/zzzz-rr-restore-gate.conf")',
        'exact_writers.add(f"{dropin}/zzzzz-rr-firewall-quarantine.conf")',
    )
    directory_required = (
        "os.lstat(directory)",
        "not stat.S_ISDIR(directory_info.st_mode)",
        "(directory_info.st_uid, directory_info.st_gid) != (0, 0)",
        "stat.S_IMODE(directory_info.st_mode) & 0o7022",
        "entry.stat(follow_symlinks=False)",
        "(info.st_uid, info.st_gid, info.st_nlink) != (0, 0, 1)",
        "name > gate_name_raw and name != firewall_gate_name_raw",
    )
    exact_file_required = (
        "0:0:644:1",
        "[ \"${lines[1]}\" = 'ExecCondition=' ]",
        "/var/lib/rr-backup/active",
        "/usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate",
    )
    firewall_exact_file_required = (
        "0:0:644:1",
        'ExecCondition=/usr/bin/test ! -e $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
        'ExecCondition=/usr/bin/test ! -L $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
    )
    order_required = (
        "--property=LoadState --value",
        "--property=DropInPaths --value",
        "if name > firewall_gate_raw:",
        "elif name == gate_raw:",
        'allow_firewall != "true"',
        "name != firewall_gate_raw",
        "path != firewall_expected",
        "if firewall_count > 1:",
        'require_gate == "true" and expected_count != 1',
    )
    effective_required = (
        'rr_restore_gate_dropin_file_is_exact "$dropin"',
        'rr_restore_effective_dropin_order_is_safe "$unit" true',
        'rr_restore_unit_uses_firewall_gate "$unit"',
        'rr_restore_firewall_gate_dropin_file_is_exact "$firewall_dropin"',
        "--property=ExecCondition --value",
        'expected = [("/bin/sh", expected_argv)]',
        '("/usr/bin/test", f"/usr/bin/test ! -e {firewall_marker}")',
        '("/usr/bin/test", f"/usr/bin/test ! -L {firewall_marker}")',
        "records != expected",
        'raw.count("{") != len(expected)',
        'raw.count("path=") != len(expected)',
        'raw.count("argv[]=") != len(expected)',
    )
    isolate_required = (
        'systemctl stop "$unit"',
        "--property=ActiveState --value",
        "inactive|failed",
    )
    required_gate_tokens = (
        "rr_restore_effective_gate_set_is_exact || return 1",
        "rr_restore_effective_gate_is_exact sing-box.service",
        "rr_restore_effective_gate_is_exact argo-rr-health.service",
        "rr_restore_effective_gate_is_exact rr-nexus.service",
        "rr_restore_effective_gate_is_exact nginx.service",
        "rr_restore_effective_gate_is_exact cloudflared.service",
        ')" = loaded ] || return 1',
        "rr_restore_isolate_gate_units >/dev/null 2>&1 || true",
    )
    writer_required = (
        'rr_restore_gate_dropin_directory_is_safe "$dropin_dir"',
        "ExecCondition=\nExecCondition=/bin/sh -c",
        'mv -f -- "$temporary" "$dropin_dir/$RR_RESTORE_GATE_DROPIN_NAME"',
        'rr_restore_gate_dropin_file_is_exact',
    )
    return (
        'RR_RESTORE_GATE_DROPIN_NAME="zzzz-rr-restore-gate.conf"' in candidate
        and 'RR_RESTORE_GATE_EXEC_CONDITION="/bin/sh -c ' in candidate
        and all(token in shape for token in shape_required)
        and all(token in directory for token in directory_required)
        and all(token in exact_file for token in exact_file_required)
        and all(token in firewall_exact_file for token in firewall_exact_file_required)
        and all(token in unit_gate for token in (
            "sing-box.service", "rr-nexus.service",
            "rr-subscription.service", "argo-rr-health.service",
        ))
        and all(token in order for token in order_required)
        and all(token in effective for token in effective_required)
        and 'if expect_firewall == "true":' in effective
        and 'rr_restore_effective_dropin_order_is_safe "$unit" false' in preflight
        and "rr_firewall_fail_closed_quarantine_active; then" in preflight
        and 'rr_restore_firewall_gate_dropin_file_is_exact' in preflight
        and all(token in required for token in required_gate_tokens)
        and all(token in isolate for token in isolate_required)
        and all(token in writer for token in writer_required)
        and prepare.count(
            "rr_restore_isolate_gate_units >/dev/null 2>&1 || true"
        ) == 2
        and reload_gate < effective_gate < enable_recovery
        and regenerate_reload < regenerate_gate
        and cloud_reload < cloud_gate < cloud_enable
        and abort_gate < abort_ready
        and rollback_gate < rollback_ready
        and main_gate < main_start
        and initial_shape < order_preflight < first_mutation
    )


def restore_gate_effective_contract_v2(candidate):
    try:
        _, _, shape = function_slice(
            candidate, "rr_restore_validate_target_snapshot_shape() {",
            "\nrr_restore_validate_portable_config() {",
        )
        _, _, directory = function_slice(
            candidate, "rr_restore_gate_dropin_directory_is_safe() {",
            "\nrr_restore_gate_dropin_file_is_exact() {",
        )
        _, _, restore_file = function_slice(
            candidate, "rr_restore_gate_dropin_file_is_exact() {",
            "\nrr_restore_firewall_gate_dropin_file_is_exact() {",
        )
        _, _, firewall_file = function_slice(
            candidate, "rr_restore_firewall_gate_dropin_file_is_exact() {",
            "\nrr_restore_nexus_gate_dropin_file_is_exact() {",
        )
        _, _, nexus_file = function_slice(
            candidate, "rr_restore_nexus_gate_dropin_file_is_exact() {",
            "\nrr_restore_unit_uses_firewall_gate() {",
        )
        _, _, unit_sets = function_slice(
            candidate, "rr_restore_unit_uses_firewall_gate() {",
            "\nrr_restore_effective_dropin_order_is_safe() {",
        )
        _, _, order = function_slice(
            candidate, "rr_restore_effective_dropin_order_is_safe() {",
            "\nrr_restore_effective_conditions_are_managed() {",
        )
        _, _, managed = function_slice(
            candidate, "rr_restore_effective_conditions_are_managed() {",
            "\nrr_restore_effective_gate_is_exact() {",
        )
        _, _, effective = function_slice(
            candidate, "rr_restore_effective_gate_is_exact() {",
            "\nrr_restore_preflight_gate_dropin_order() {",
        )
        _, _, preflight = function_slice(
            candidate, "rr_restore_preflight_gate_dropin_order() {",
            "\nrr_restore_effective_gate_set_is_exact() {",
        )
        _, _, writer = function_slice(
            candidate, "rr_restore_write_gate_dropins() {",
            "\nrr_restore_prepare_recovery_unit() {",
        )
        _, _, prepare = function_slice(
            candidate, "rr_restore_prepare_recovery_unit() {",
            "\nrr_restore_service_gate() {",
        )
        prepare_reload = prepare.index("systemctl daemon-reload")
        prepare_effective = prepare.index(
            "rr_restore_effective_gate_set_is_exact", prepare_reload
        )
        prepare_enable = prepare.index(
            "systemctl enable rr-restore-recovery.service", prepare_effective
        )
        restore = candidate[candidate.index("rr_restore_backup_locked() {"):]
        preflight_position = restore.index("rr_restore_preflight_gate_dropin_order || {")
        first_mutation = restore.index(
            "rr_restore_migrate_legacy_fixed_token ||", preflight_position
        )
    except ValueError:
        return False
    return (
        all(token in candidate for token in (
            'RR_RESTORE_GATE_DROPIN_NAME="zzzz-rr-restore-gate.conf"',
            'RR_RESTORE_FIREWALL_GATE_DROPIN_NAME="zzzzz-rr-firewall-quarantine.conf"',
            'RR_RESTORE_NEXUS_GATE_DROPIN_NAME="zzzzzz-rr-nexus-ip-cert-gate.conf"',
            'RR_RESTORE_NEXUS_GATE_EXEC_PATH="/usr/local/lib/rr-vps/nexus-ip-cert-gate"',
        ))
        and all(token in shape for token in (
            'NEXUS_GATE_DROPIN = b"zzzzzz-rr-nexus-ip-cert-gate.conf"',
            'and name != NEXUS_GATE_DROPIN',
            'exact_writers.add(f"{dropin}/zzzzzz-rr-nexus-ip-cert-gate.conf")',
        ))
        and all(token in directory for token in (
            'entry.stat(follow_symlinks=False)',
            'name not in {firewall_gate_name_raw, nexus_gate_name_raw}',
            'rr_restore_unit_uses_firewall_gate "$unit" || return 1',
            'rr_restore_unit_uses_nexus_gate "$unit" || return 1',
        ))
        and all(token in restore_file for token in (
            '0:0:644:1', '"${#lines[@]}" -eq 2',
            '/usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate',
        ))
        and "[ \"${lines[1]}\" = 'ExecCondition=' ]" not in restore_file
        and all(token in firewall_file for token in (
            'ExecCondition=/usr/bin/test ! -e $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
            'ExecCondition=/usr/bin/test ! -L $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
        ))
        and all(token in nexus_file for token in (
            '"${#lines[@]}" -eq 2',
            'ExecCondition=$RR_RESTORE_NEXUS_GATE_EXEC_ARGV',
        ))
        and 'rr_restore_unit_uses_nexus_gate() {' in unit_sets
        and '[ "$1" = nginx.service ]' in unit_sets
        and all(token in order for token in (
            'allow_firewall=false allow_nexus=false',
            'if name > nexus_gate_raw:',
            'allow_nexus != "true" or path != nexus_expected',
            'expected_count > 1 or firewall_count > 1 or nexus_count > 1',
        ))
        and all(token in managed for token in (
            '--property=ExecCondition --value',
            'expected = []',
            'if expect_restore == "true":',
            'if expect_firewall == "true":',
            'if expect_nexus == "true":',
            'records != expected',
            'raw.count("{") != len(expected)',
        ))
        and all(token in effective for token in (
            'rr_restore_effective_dropin_order_is_safe "$unit" true',
            'rr_restore_nexus_gate_dropin_file_is_exact "$nexus_dropin"',
            'if expect_nexus == "true":',
            'records != expected',
        ))
        and all(token in preflight for token in (
            'rr_firewall_fail_closed_quarantine_active; then',
            'rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit"',
            'rr_restore_effective_conditions_are_managed "$unit" || return 1',
        ))
        and all(token in writer for token in (
            'rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit"',
            'mv -f -- "$temporary" "$dropin_dir/$RR_RESTORE_GATE_DROPIN_NAME"',
            'sync -f "$dropin_dir"',
        ))
        and writer.count(
            'rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit"'
        ) == 2
        and "\nExecCondition=\n" not in writer
        and prepare_reload < prepare_effective < prepare_enable
        and preflight_position < first_mutation
    )


assert restore_gate_effective_contract_v2(resilience)
restore_gate_mutations_legacy = r'''
    resilience.replace(
        'RR_RESTORE_GATE_DROPIN_NAME="zzzz-rr-restore-gate.conf"',
        'RR_RESTORE_GATE_DROPIN_NAME="40-rr-restore-gate.conf"',
        1,
    ),
    resilience.replace(
        'and name != FIREWALL_GATE_DROPIN',
        'and False',
        1,
    ),
    resilience.replace(
        "if name > gate_name_raw and name != firewall_gate_name_raw:",
        "if False:",
        1,
    ),
    resilience.replace("if name > firewall_gate_raw:", "if False:", 1),
    resilience.replace("elif name == gate_raw:", "elif False:", 1),
    resilience.replace(
        "ExecCondition=\nExecCondition=/bin/sh -c",
        "ExecCondition=/bin/sh -c",
        1,
    ),
    resilience.replace(
        "--property=DropInPaths --value", "--property=Names --value", 1
    ),
    resilience.replace('raw.count("{") != len(expected)', "False", 1),
    resilience.replace('raw.count("path=") != len(expected)', "False", 1),
    resilience.replace('raw.count("argv[]=") != len(expected)', "False", 1),
    resilience.replace(
        "records != expected", "False", 1
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_firewall_gate_dropin_file_is_exact() {",
        "\nrr_restore_unit_uses_firewall_gate() {",
        'ExecCondition=/usr/bin/test ! -L $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
        'ExecCondition=/usr/bin/test ! -e $RR_RESTORE_FIREWALL_QUARANTINE_FILE',
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_unit_uses_firewall_gate() {",
        "\nrr_restore_effective_dropin_order_is_safe() {",
        'rr-subscription.service|\\\n'
        '        argo-rr-health.service',
        "argo-rr-health.service",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_effective_dropin_order_is_safe() {",
        "\nrr_restore_effective_gate_is_exact() {",
        'allow_firewall != "true"',
        "False",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_effective_dropin_order_is_safe() {",
        "\nrr_restore_effective_gate_is_exact() {",
        "path != firewall_expected",
        "False",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_effective_dropin_order_is_safe() {",
        "\nrr_restore_effective_gate_is_exact() {",
        "if firewall_count > 1:",
        "if False:",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_effective_gate_is_exact() {",
        "\nrr_restore_preflight_gate_dropin_order() {",
        'rr_restore_firewall_gate_dropin_file_is_exact "$firewall_dropin" || return 1',
        ": # removed firewall drop-in content proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_effective_gate_is_exact() {",
        "\nrr_restore_preflight_gate_dropin_order() {",
        'if expect_firewall == "true":',
        "if False:",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_preflight_gate_dropin_order() {",
        "\nrr_restore_effective_gate_set_is_exact() {",
        "rr_firewall_fail_closed_quarantine_active; then",
        "false; then",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_preflight_gate_dropin_order() {",
        "\nrr_restore_effective_gate_set_is_exact() {",
        'rr_restore_firewall_gate_dropin_file_is_exact \\\n'
        '                    "$firewall_dropin" || return 1',
        ': # removed static firewall gate proof',
    ),
    resilience.replace(
        'rr_restore_effective_gate_set_is_exact; then', "false; then", 1
    ),
    resilience.replace(
        "rr_restore_isolate_gate_units >/dev/null 2>&1 || true", ":", 1
    ),
    resilience.replace(
        "rr_restore_preflight_gate_dropin_order || {", "true || {", 1
    ),
    resilience.replace(
        "rr_restore_effective_gate_is_exact cloudflared.service || return 1",
        "true # removed late Cloudflared gate proof",
        1,
    ),
    resilience.replace(
        "    rr_restore_require_effective_gates_or_isolate\n}\n\nrr_restore_verify_manifest() {",
        "    true # removed post-regeneration gate proof\n}\n\nrr_restore_verify_manifest() {",
        1,
    ),
    resilience.replace(
        "    systemctl daemon-reload >/dev/null 2>&1 || return 1\n"
        "    rr_restore_require_effective_gates_or_isolate || return 1\n"
        "    if [ -f \"$rollback/cloudflared_was_enabled\" ]; then",
        "    systemctl daemon-reload >/dev/null 2>&1 || return 1\n"
        "    if [ -f \"$rollback/cloudflared_was_enabled\" ]; then",
        1,
    ),
    resilience.replace(
        "    rr_restore_require_effective_gates_or_isolate || return 1\n"
        "    rr_restore_publish_marker \"$RR_RESTORE_RUNTIME_READY\" \"$stage\" || return 1",
        "    rr_restore_publish_marker \"$RR_RESTORE_RUNTIME_READY\" \"$stage\" || return 1",
        1,
    ),
    resilience.replace(
        "        rr_restore_require_effective_gates_or_isolate || failed=true\n"
        "    fi\n"
        "    if [ \"$failed\" = false ]; then\n"
        "        rr_restore_publish_marker \"$RR_RESTORE_RUNTIME_READY\"",
        "    fi\n"
        "    if [ \"$failed\" = false ]; then\n"
        "        rr_restore_publish_marker \"$RR_RESTORE_RUNTIME_READY\"",
        1,
    ),
    resilience.replace(
        "            rr_restore_require_effective_gates_or_isolate || result=1\n"
        "        fi\n"
        "        if [ \"$result\" -ne 1 ]; then\n"
        "            if [ -f \"$rollback/target_rr_was_present\" ]; then",
        "            true # removed final pre-start gate proof\n"
        "        fi\n"
        "        if [ \"$result\" -ne 1 ]; then\n"
        "            if [ -f \"$rollback/target_rr_was_present\" ]; then",
        1,
    ),
)
'''
restore_gate_mutations = (
    resilience.replace(
        'RR_RESTORE_NEXUS_GATE_DROPIN_NAME="zzzzzz-rr-nexus-ip-cert-gate.conf"',
        'RR_RESTORE_NEXUS_GATE_DROPIN_NAME="removed-nexus-gate.conf"', 1,
    ),
    mutate_function_slice(
        resilience, "rr_restore_write_gate_dropins() {",
        "\nrr_restore_prepare_recovery_unit() {",
        "ExecCondition=/bin/sh -c '[ !",
        "ExecCondition=\nExecCondition=/bin/sh -c '[ !",
    ),
    mutate_function_slice(
        resilience, "rr_restore_effective_conditions_are_managed() {",
        "\nrr_restore_effective_gate_is_exact() {",
        "records != expected", "False",
    ),
    mutate_function_slice(
        resilience, "rr_restore_effective_conditions_are_managed() {",
        "\nrr_restore_effective_gate_is_exact() {",
        'if expect_nexus == "true":', "if False:",
    ),
    mutate_function_slice(
        resilience, "rr_restore_effective_dropin_order_is_safe() {",
        "\nrr_restore_effective_conditions_are_managed() {",
        "if name > nexus_gate_raw:", "if False:",
    ),
    mutate_function_slice(
        resilience, "rr_restore_effective_dropin_order_is_safe() {",
        "\nrr_restore_effective_conditions_are_managed() {",
        "expected_count > 1 or firewall_count > 1 or nexus_count > 1",
        "False",
    ),
    mutate_function_slice(
        resilience, "rr_restore_unit_uses_nexus_gate() {",
        "\nrr_restore_effective_dropin_order_is_safe() {",
        '[ "$1" = nginx.service ]', "false",
    ),
    mutate_function_slice(
        resilience, "rr_restore_nexus_gate_dropin_file_is_exact() {",
        "\nrr_restore_unit_uses_firewall_gate() {",
        'ExecCondition=$RR_RESTORE_NEXUS_GATE_EXEC_ARGV',
        'ExecCondition=/bin/true',
    ),
    mutate_function_slice(
        resilience, "rr_restore_preflight_gate_dropin_order() {",
        "\nrr_restore_effective_gate_set_is_exact() {",
        'rr_restore_effective_conditions_are_managed "$unit" || return 1',
        "true # removed unmanaged-condition rejection",
    ),
    mutate_function_slice(
        resilience, "rr_restore_preflight_gate_dropin_order() {",
        "\nrr_restore_effective_gate_set_is_exact() {",
        "rr_firewall_fail_closed_quarantine_active; then", "false; then",
    ),
    mutate_function_slice(
        resilience, "rr_restore_write_gate_dropins() {",
        "\nrr_restore_prepare_recovery_unit() {",
        'rr_restore_gate_dropin_directory_is_safe "$dropin_dir" "$unit"',
        'rr_restore_gate_dropin_directory_is_safe "$dropin_dir"',
    ),
    mutate_function_slice(
        resilience, "rr_restore_prepare_recovery_unit() {",
        "\nrr_restore_service_gate() {",
        "if ! rr_restore_effective_gate_set_is_exact; then", "if false; then",
    ),
)
for mutated in restore_gate_mutations:
    assert mutated != resilience
    assert not restore_gate_effective_contract_v2(mutated)


def replace_last(candidate, old, new):
    position = candidate.rfind(old)
    assert position >= 0
    return candidate[:position] + new + candidate[position + len(old):]


shape_mutations = (
    resilience.replace("return os.lstat(path)", "return os.stat(path)", 1),
    resilience.replace(
        "entry.stat(follow_symlinks=False)",
        "entry.stat(follow_symlinks=True)",
        1,
    ),
    resilience.replace(
        "(info.st_uid, info.st_gid) != (0, 0)",
        "False",
        1,
    ),
    resilience.replace("if info.st_nlink != 1:", "if False:", 1),
    resilience.replace(
        '"/etc/systemd/system/cloudflared.service",',
        '"/removed-cloudflared.service",',
        1,
    ),
    resilience.replace(
        '"/etc/systemd/system/rr-restore-watchdog.service",',
        '"/removed-restore-watchdog.service",',
        1,
    ),
    resilience.replace(
        '        "argo-rr-health.timer", "rr-restore-recovery.service",\n',
        '        "rr-restore-recovery.service",\n',
        1,
    ),
    resilience.replace(
        '        "argo-rr-health.timer", "rr-restore-recovery.service",\n',
        '        "argo-rr-health.timer",\n',
        1,
    ),
    resilience.replace(
        '        "rr-restore-watchdog.service",\n',
        '',
        1,
    ),
    resilience.replace(
        '"/etc/rr-update", "/etc/rr-cloudflared", "/var/lib/rr-nexus",',
        '"/etc/rr-update", "/etc/rr-cloudflared",',
        1,
    ),
    resilience.replace(
        "if raw_target not in allowed_targets:",
        "if False:",
        1,
    ),
    resilience.replace(
        "validate_managed_tree(dropin_directory)",
        "validate_real_directory(dropin_directory)",
        1,
    ),
    resilience.replace("mountinfo=/proc/self/mountinfo", "mountinfo=/tmp/mock", 1),
    resilience.replace("os.O_NOFOLLOW", "0", 1),
    resilience.replace("permissions & 0o022", "False", 1),
    resilience.replace("permissions == 0o1777", "False", 1),
    resilience.replace(
        '        "/tmp/sub_server",\n    )\n    exact_writers = {',
        '    )\n    exact_writers = {',
        1,
    ),
    resilience.replace(
        "at_or_below(mountpoint, root)",
        "False",
        1,
    ),
    resilience.replace(
        "    rr_restore_validate_target_snapshot_shape || {",
        "    removed_target_snapshot_shape_gate || {",
        1,
    ),
    resilience.replace(
        "        rr_restore_validate_target_snapshot_shape || result=1",
        "        removed_frozen_shape_gate || result=1",
        1,
    ),
    replace_last(
        resilience,
        "        rr_restore_validate_target_snapshot_shape || result=1",
        "        removed_complete_shape_gate || result=1",
    ),
    resilience.replace(
        "    rr_restore_validate_target_snapshot_shape || return 1\n"
        "    rm -rf -- /etc/sing-box",
        "    rm -rf -- /etc/sing-box",
        1,
    ),
    resilience.replace(
        "    rr_restore_validate_target_snapshot_shape || return 1\n"
        "    ensure_subscription_root || return 1",
        "    ensure_subscription_root || return 1",
        1,
    ),
    resilience.replace(
        "    ensure_subscription_root || return 1\n",
        "",
        1,
    ),
    resilience.replace(
        "    rr_restore_validate_target_snapshot_shape || return 1\n"
        '    find "$SUB_ROOT" -mindepth 1 -xdev -delete',
        '    find "$SUB_ROOT" -mindepth 1 -xdev -delete',
        1,
    ),
    resilience.replace('destination_root="${3:-/}"', 'destination_root="/"', 1),
    resilience.replace(" -depth -type d -print0", " -type d -print0", 1),
    resilience.replace(
        "(( (source_mode_decimal & 00022) == 0 ))",
        ":",
        1,
    ),
)
for mutated in shape_mutations:
    assert mutated != resilience
    assert not complete_shape_contract(mutated)

restore_start = resilience.index("rr_restore_backup_locked() {")
restore = resilience[restore_start:]


def portable_certificate_preflight_contract(candidate):
    try:
        naive_start = candidate.index("rr_restore_preflight_portable_naive_target() {")
        subscription_start = candidate.index(
            "rr_restore_preflight_portable_subscription_target() {", naive_start
        )
        stage_start = candidate.index("rr_restore_stage_is_safe() {", subscription_start)
        naive = candidate[naive_start:subscription_start]
        subscription = candidate[subscription_start:stage_start]
        restore_start_at = candidate.index("rr_restore_backup_locked() {")
        restore_candidate = candidate[restore_start_at:]

        imported_pair = naive.index('"$imported_cert_dir/fullchain.pem"')
        blank_guard = naive.index(
            '[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || {',
            imported_pair,
        )
        naive_target_pair = naive.index(
            '"$le_live_root/$naive_domain/fullchain.pem"', blank_guard
        )
        naive_lineage = naive.index(
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {',
            naive_target_pair,
        )
        naive_runtime = naive.index(
            'rr_certbot_renewal_runtime_is_ready "$naive_domain" || {',
            naive_lineage,
        )
        naive_hook = naive.index(
            "rr_certificate_deploy_hook_is_current || {", naive_runtime
        )

        target_config = subscription.index(
            '[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 0'
        )
        subscription_target_pair = subscription.index(
            "subscription_certificate_pair_valid", target_config
        )
        subscription_lineage = subscription.index(
            'rr_certbot_webroot_lineage_is_renewable "$target_domain" || {',
            subscription_target_pair,
        )
        subscription_runtime = subscription.index(
            'rr_certbot_renewal_runtime_is_ready "$target_domain" || {',
            subscription_lineage,
        )
        subscription_hook = subscription.index(
            "rr_certificate_deploy_hook_is_current || {", subscription_runtime
        )

        ownership = restore_candidate.index("rr_restore_validate_target_ownership ||")
        shape_call = restore_candidate.index(
            "rr_restore_validate_target_snapshot_shape ||", ownership
        )
        naive_call = restore_candidate.index(
            "rr_restore_preflight_portable_naive_target", shape_call
        )
        config_arg = restore_candidate.index(
            '"$stage/payload/rootfs/etc/argo_vmess.conf"', naive_call
        )
        payload_arg = restore_candidate.index('"$stage/payload" ||', config_arg)
        subscription_call = restore_candidate.index(
            "rr_restore_preflight_portable_subscription_target ||", payload_arg
        )
        first_mutation = restore_candidate.index(
            "rr_restore_migrate_legacy_fixed_token ||", subscription_call
        )
    except ValueError:
        return False

    if not (
        imported_pair < blank_guard < naive_target_pair < naive_lineage
        < naive_runtime < naive_hook
    ):
        return False
    if not (
        target_config < subscription_target_pair < subscription_lineage
        < subscription_runtime < subscription_hook
    ):
        return False
    if not ownership < shape_call < naive_call < config_arg < payload_arg < subscription_call < first_mutation:
        return False
    required_naive = (
        'print("enabled:" + values.get("NAIVE_DOMAIN", ""))',
        'print("disabled:")',
        "case \"$imported_naive\" in",
        "disabled:)",
        "enabled:*)",
        "naive_certificate_pair_valid \\",
        "declare -F rr_certbot_webroot_lineage_is_renewable",
        "declare -F rr_certbot_renewal_runtime_is_ready",
    )
    if not all(token in naive for token in required_naive):
        return False
    if naive.count(
        'rr_certbot_webroot_lineage_is_renewable "$naive_domain"'
    ) != 1:
        return False
    if naive.count(
        'rr_certbot_renewal_runtime_is_ready "$naive_domain"'
    ) != 1:
        return False
    if 'print("disabled")' in naive or "[ -f \"$CONFIG_FILE\" ] || return 0" in naive:
        return False
    required_subscription = (
        'values.get("SUB_ACCESS_MODE", "local")',
        'values.get("SUB_DOMAIN", "")',
        "local:)",
        "https:*)",
        "subscription_certificate_pair_valid \\",
        "declare -F rr_certbot_webroot_lineage_is_renewable",
        "declare -F rr_certbot_renewal_runtime_is_ready",
    )
    return (
        all(token in subscription for token in required_subscription)
        and subscription.count(
            'rr_certbot_webroot_lineage_is_renewable "$target_domain"'
        ) == 1
        and subscription.count(
            'rr_certbot_renewal_runtime_is_ready "$target_domain"'
        ) == 1
    )


assert portable_certificate_preflight_contract(resilience)
preflight_mutations = (
    resilience.replace(
        'print("enabled:" + values.get("NAIVE_DOMAIN", ""))',
        'print(values.get("NAIVE_DOMAIN", ""))',
        1,
    ),
    resilience.replace('print("disabled:")', 'print("disabled")', 1),
    resilience.replace(
        '[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || {',
        '[ -f "$CONFIG_FILE" ] || return 0\n    true || {',
        1,
    ),
    resilience.replace(
        '        "$imported_cert_dir/fullchain.pem" \\\n',
        '        "$payload_root/removed-imported-certificate" \\\n',
        1,
    ),
    resilience.replace(
        '    rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {',
        "    true || {",
        1,
    ),
    resilience.replace(
        '    rr_certbot_webroot_lineage_is_renewable "$target_domain" || {',
        "    true || {",
        1,
    ),
    resilience.replace(
        '    rr_certbot_renewal_runtime_is_ready "$naive_domain" || {',
        "    true || {",
        1,
    ),
    resilience.replace(
        '    rr_certbot_renewal_runtime_is_ready "$target_domain" || {',
        "    true || {",
        1,
    ),
    resilience.replace(
        "    rr_certificate_deploy_hook_is_current || {",
        "    true || {",
        1,
    ),
    resilience.replace(
        "    rr_restore_preflight_portable_subscription_target || {",
        "    removed_subscription_preflight || {",
        1,
    ),
    resilience.replace(
        '        "$stage/payload" || { rm -rf "$stage"; return 1; }',
        '        "/removed-payload" || { rm -rf "$stage"; return 1; }',
        1,
    ),
)
for mutated in preflight_mutations:
    assert mutated != resilience
    assert not portable_certificate_preflight_contract(mutated)


lineage_required_tokens = (
    'RR_LE_CONFIG_ROOT:-/etc/letsencrypt',
    'RR_LE_LIVE_ROOT:-${config_root}/live',
    'RR_LE_ARCHIVE_ROOT:-${config_root}/archive',
    'RR_LE_RENEWAL_ROOT:-${config_root}/renewal',
    'RR_LE_ACCOUNTS_ROOT:-${config_root}/accounts',
    'RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot',
    'PRODUCTION_SERVER = "https://acme-v02.api.letsencrypt.org/directory"',
    'PRODUCTION_HOST = "acme-v02.api.letsencrypt.org"',
    "MAX_RENEWAL_BYTES = 128 * 1024",
    "MAX_JSON_BYTES = 1024 * 1024",
    "MAX_PEM_BYTES = 4 * 1024 * 1024",
    "MAX_CERTIFICATES = 16",
    "return path.lstat()",
    "def require_secure_directory(path, *, canonical_tmp=False, secret=False):",
    'if path != pathlib.Path("/tmp") or permissions != 0o1777:',
    "elif permissions & 0o7022:",
    "def require_secure_directory_chain(path, *, secret_leaf=False):",
    "for member in (*reversed(path.parents), path):",
    'canonical_tmp=(member == pathlib.Path("/tmp"))',
    "secret=(secret_leaf and member == path)",
    'path.resolve(strict=True) != path',
    "permissions & 0o111",
    "info.st_nlink != 1 or info.st_size > maximum",
    "if nonempty and info.st_size == 0:",
    "require_secure_directory_chain(required_root)",
    "require_secure_directory_chain(live_dir)",
    "require_secure_directory_chain(archive_dir)",
    'renewal_bytes.decode("utf-8", errors="strict")',
    'webroot / ".well-known" / "acme-challenge"',
    'renewal_file = renewal_root / f"{domain}.conf"',
    'len(raw_line.encode("utf-8")) > 4096',
    'if line == "[[webroot_map]]" and section != "renewalparams":',
    'section_counts.get("renewalparams") != 1',
    'section_counts.get("webroot_map") != 1',
    "if key in bucket:",
    '"archive_dir": str(archive_dir)',
    '"cert": str(live_dir / "cert.pem")',
    '"privkey": str(live_dir / "privkey.pem")',
    '"chain": str(live_dir / "chain.pem")',
    '"fullchain": str(live_dir / "fullchain.pem")',
    'params.get("authenticator") != "webroot"',
    'params.get("server") != PRODUCTION_SERVER',
    '"autorenew" in params and params["autorenew"].strip().lower() != "true"',
    'params["config_dir"] != str(config_root)',
    'if set(renewal_info) != {"ari_retry_after"}:',
    "parsed_retry_after = datetime.datetime.fromisoformat(retry_after)",
    "parsed_retry_after.tzinfo is not None",
    'parsed_retry_after.isoformat(timespec="seconds") != retry_after',
    'mapped_domain.lower() == domain.lower()',
    'selected_webroot != str(webroot)',
    'for stem in ("cert", "privkey", "chain", "fullchain"):',
    'or (info.st_uid, info.st_gid) != (0, 0)',
    'target.parent != archive_dir',
    'elif generation != member_generation:',
    "if stat.S_ISLNK(entry_info.st_mode):",
    'stem != "privkey"',
    'reuse_match = re.fullmatch(r"privkey([1-9][0-9]*)\\.pem", material.name)',
    "int(reuse_match.group(1)) >= generation",
    "archive_raw_target != os.path.relpath(material, archive_entry.parent)",
    'require_secure_regular(material, MAX_PEM_BYTES, secret=(stem == "privkey"))',
    'result = subprocess.run(',
    '["openssl", *arguments]',
    "timeout=10",
    "pass_fds=pass_fds",
    'begin = b"-----BEGIN CERTIFICATE-----"',
    'base64.b64decode(payload, validate=True)',
    "if base64.b64encode(certificate) != payload:",
    '["x509", "-inform", "DER", "-noout"]',
    "if len(certificates) > MAX_CERTIFICATES:",
    "if len(leaf_certificates) != 1:",
    "if fullchain_bytes != cert_bytes + chain_bytes:",
    "if fullchain_certificates != leaf_certificates + chain_certificates:",
    "if len(set(fullchain_certificates)) != len(fullchain_certificates):",
    '"-partial_chain"',
    'f"/proc/self/fd/{issuer_fd}"',
    "for index in range(len(certificate_sequence) - 1):",
    "server_leaf=(index == 0)",
    '["x509", "-inform", "DER", "-checkend", "604800", "-noout"]',
    '["x509", "-inform", "DER", "-noout", "-ext", "subjectAltName"]',
    'if len(san_entries) != 1 or not san_entries[0].startswith("DNS:"):',
    "san_entries[0][4:].lower() != domain.lower()",
    "private_key_pattern.fullmatch(privkey_bytes) is None",
    '["pkey", "-check", "-noout", "-passin", "pass:"]',
    "if certificate_public_key != private_public_key:",
    'server_dir = accounts_root / PRODUCTION_HOST',
    'LEGACY_PRODUCTION_HOST = "acme-v01.api.letsencrypt.org"',
    'directory_dir = server_dir / "directory"',
    "require_secure_directory_chain(server_dir)",
    "directory_info = lstat(directory_dir)",
    "if stat.S_ISLNK(directory_info.st_mode):",
    "(directory_info.st_uid, directory_info.st_gid, directory_info.st_nlink)",
    "!= (0, 0, 1)",
    "directory_raw_target = os.readlink(directory_dir)",
    'legacy_directory = accounts_root / LEGACY_PRODUCTION_HOST / "directory"',
    "expected_relative = os.path.relpath(legacy_directory, directory_dir.parent)",
    "directory_raw_target != expected_relative",
    "lexical_link_target(directory_dir, directory_raw_target) != legacy_directory",
    "require_secure_directory_chain(legacy_directory)",
    "account_base = legacy_directory",
    "require_secure_directory_chain(directory_dir)",
    "account_dir = account_base / account",
    "require_secure_directory_chain(account_dir, secret_leaf=True)",
    "require_secure_regular(path, MAX_JSON_BYTES, secret=secret)",
    'private_key = read_json("private_key.json", secret=True)',
    'registration = read_json("regr.json")',
    'metadata = read_json("meta.json")',
    'private_key.get("kty") != "RSA"',
    'jwk_integer(name) for name in ("n", "e", "d", "p", "q", "dp", "dq", "qi")',
    "or p * q != n",
    "lcm = math.lcm(p - 1, q - 1)",
    "math.gcd(e, lcm) != 1 or (e * d) % lcm != 1",
    "dp != d % (p - 1) or dq != d % (q - 1) or (q * qi) % p != 1",
    '["pkey", "-inform", "DER", "-check", "-noout"]',
    "rsa_algorithm_identifier = bytes.fromhex",
    "subject_public_key_info = der_value(",
    "hashlib.md5(public_key_pem, usedforsecurity=False).hexdigest()",
    "if account != account_digest:",
    'registration_body = registration.get("body")',
    "if not isinstance(registration_body, dict):",
    'contacts = registration_body.get("contact", [])',
    'registration_body["termsOfServiceAgreed"] is not True',
    'parsed_uri.scheme != "https"',
    'parsed_uri.hostname != PRODUCTION_HOST',
    're.fullmatch(r"/acme/acct/[1-9][0-9]*", parsed_uri.path)',
    'creation_host = metadata.get("creation_host")',
    'creation_dt = metadata.get("creation_dt")',
    "parsed_creation_dt.tzinfo is None",
    'metadata["register_to_eff"] is not None',
)


def renewable_lineage_contract(candidate):
    try:
        _, _, lineage = function_slice(
            candidate,
            "rr_certbot_webroot_lineage_is_renewable() {",
            "\nrr_certbot_acme_effective_route_probe() (",
        )
    except ValueError:
        return False
    forbidden_writes = (
        "os.unlink(", "os.remove(", "os.rename(", "os.replace(",
        "os.chmod(", "os.chown(", ".write_text(", ".write_bytes(",
        "shutil.", "certbot certonly", "certbot renew",
        "\n    install ", "\n    mkdir ", "\n    rm ", "\n    mv ",
        "\n    cp ", "\n    ln ", "\n    chmod ", "\n    chown ",
        "\n    systemctl ",
    )
    return (
        all(token in lineage for token in lineage_required_tokens)
        and lineage.count("if secret and permissions & 0o077:") == 2
        and lineage.count("result = subprocess.run(") == 1
        and lineage.count('["openssl", *arguments]') == 1
        and "or not registration_body" not in lineage
        and candidate.count("rr_certbot_webroot_lineage_is_renewable() {") == 1
        and not any(token in lineage for token in forbidden_writes)
    )


assert renewable_lineage_contract(config)
for token_index, token in enumerate(lineage_required_tokens):
    mutated = mutate_function_slice(
        config,
        "rr_certbot_webroot_lineage_is_renewable() {",
        "\nrr_certbot_acme_effective_route_probe() (",
        token,
        f"removed_lineage_contract_{token_index}",
    )
    assert not renewable_lineage_contract(mutated)

lineage_semantic_mutations = (
    mutate_function_slice(
        config,
        "rr_certbot_webroot_lineage_is_renewable() {",
        "\nrr_certbot_acme_effective_route_probe() (",
        "if secret and permissions & 0o077:",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_webroot_lineage_is_renewable() {",
        "\nrr_certbot_acme_effective_route_probe() (",
        "if not isinstance(registration_body, dict):",
        "if not isinstance(registration_body, dict) or not registration_body:",
    ),
)
for mutated in lineage_semantic_mutations:
    assert not renewable_lineage_contract(mutated)


effective_probe_required_tokens = (
    'rr_certbot_acme_effective_route_probe() (',
    'curl_path=$(command -v curl',
    '[ -f "$curl_path" ] && [ ! -L "$curl_path" ] && [ -x "$curl_path" ]',
    'PROBE_PREFIX = "rr-route-probe-v1_"',
    'TOKEN = re.compile(r"[A-Za-z0-9_-]{32}")',
    'BODY = re.compile(rb"rr-route-probe-v1:[A-Za-z0-9_-]{43}")',
    'for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):',
    'secure_directory_chain(challenge)',
    'os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW',
    '(directory_info.st_dev, directory_info.st_ino)',
    'for stale in os.listdir(directory_fd):',
    'if TOKEN.fullmatch(suffix) is None:',
    'unlink_verified(directory_fd, stale)',
    'os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW',
    'os.fchown(descriptor, 0, 0)',
    'os.fchmod(descriptor, 0o644)',
    'os.fsync(descriptor)',
    'os.fsync(directory_fd)',
    'or info.st_nlink != 1',
    'or info.st_size != BODY_SIZE',
    'validate_probe(directory_fd, name, body, identity)',
    'for address in ("127.0.0.1", "[::1]"):',
    '"-q"',
    '"--noproxy", "*"',
    '"--path-as-is"',
    '"--connect-timeout", "2"',
    '"--max-time", "5"',
    '"--max-filesize", str(MAX_RESPONSE)',
    '"--resolve", f"{domain}:80:{address}"',
    '"--write-out", "%{http_code}"',
    'timeout=7',
    'result.stdout != body + b"200"',
    'except BaseException as error:',
    'cleanup_failure = error',
    'if failure is not None or cleanup_failure is not None:',
)


runtime_route_required_tokens = (
    'RR_NAIVE_ACME_NGINX_SITE:-/etc/nginx/sites-available/rr-naive-acme.conf',
    'RR_NAIVE_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-naive-acme.conf',
    'NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available',
    'NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled',
    'is_valid_domain "$domain" || return 1',
    'declare -F rr_validate_protocol_firewall >/dev/null 2>&1 || return 1',
    '"$naive_site" "$naive_enabled"',
    '"$nexus_site" "$nexus_enabled_dir/rr-nexus.conf"',
    '"${nexus_site}.port" "$nexus_enabled_dir/rr-nexus-port.conf"',
    'command -v curl >/dev/null 2>&1 || return 1',
    "MAX_SITE_BYTES = 128 * 1024",
    'if not path.is_absolute() or str(path) != raw or ".." in path.parts:',
    "def secure_directory_chain(path):",
    "for member in (*reversed(path.parents), path):",
    'if path == pathlib.Path("/tmp"):',
    "elif mode & 0o022:",
    "or (info.st_uid, info.st_gid) != (0, 0)",
    "path.resolve(strict=True) != path",
    "secure_directory_chain(path.parent)",
    "or (before.st_uid, before.st_gid) != (0, 0)",
    "stat.S_IMODE(before.st_mode) != 0o644",
    "before.st_nlink != 1",
    "before.st_size > MAX_SITE_BYTES",
    "os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW",
    "(opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)",
    "after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns",
    "data.decode(\"utf-8\", errors=\"strict\")",
    "not stat.S_ISLNK(link_info.st_mode)",
    "or (link_info.st_uid, link_info.st_gid) != (0, 0)",
    "or link_info.st_nlink != 1",
    "if raw_target != str(site):",
    "(link_after.st_dev, link_after.st_ino) != (link_info.st_dev, link_info.st_ino)",
    're.match(r"^\\s*include(?:\\s|;)", line)',
    "if len(challenge_mentions) != 1:",
    '"location /.well-known/acme-challenge/ {"',
    '"location ^~ /.well-known/acme-challenge/ {"',
    "def is_port_80_listener(line):",
    'return endpoint in {"80", "http"} or endpoint.endswith((":80", ":http"))',
    "port_80_listeners = [line for line in top_level if is_port_80_listener(line)]",
    "if port_80_listeners:",
    'raise InvalidRoute("RR site has an unrelated port-80 server")',
    'ipv4_listeners = top_level.count("listen 80;")',
    'ipv6_listeners = top_level.count("listen [::]:80;")',
    "ipv4_listeners != 1",
    "or ipv6_listeners != 1",
    "or len(port_80_listeners) != 2",
    "or len(names) != 1",
    "or DOMAIN.fullmatch(names[0]) is None",
    '[f"root {expected_webroot};"]',
    '[f"root {expected_webroot};", "try_files $uri =404;"]',
    "if len(routes) != 1:",
    "secure_directory_chain(required)",
    "if len(candidate_values) % 2:",
    "if pair in seen:",
    "route_domains.append(route_from_site(text, str(webroot)))",
    "if expected_domain.lower() not in route_domains:",
    "nginx -t >/dev/null 2>&1 || return 1",
    "systemctl is-active --quiet nginx >/dev/null 2>&1 || return 1",
    "ss -H -ltn 'sport = :80'",
    'grep -q LISTEN <<< "$port_80_listeners" || return 1',
    "rr_validate_protocol_firewall 80 tcp open || return 1",
    'rr_certbot_acme_effective_route_probe "$domain" "$webroot"',
)


def certificate_runtime_route_contract(candidate):
    try:
        _, _, probe = function_slice(
            candidate,
            "rr_certbot_acme_effective_route_probe() (",
            "\nrr_certbot_acme_http_route_is_ready() {",
        )
        _, _, route = function_slice(
            candidate,
            "rr_certbot_acme_http_route_is_ready() {",
            "\nrr_certbot_renewal_runtime_is_ready() {",
        )
        _, _, runtime = function_slice(
            candidate,
            "rr_certbot_renewal_runtime_is_ready() {",
            "\nrr_enable_certbot_renewal_runtime() {",
        )
        _, _, enable = function_slice(
            candidate,
            "rr_enable_certbot_renewal_runtime() {",
            "\nrr_install_certificate_deploy_hook() {",
        )

        runtime_domain = runtime.index('is_valid_domain "$domain" || return 1')
        runtime_certbot = runtime.index(
            "certbot_path=$(command -v certbot", runtime_domain
        )
        runtime_executable = runtime.index(
            '[ -f "$certbot_path" ] && [ -x "$certbot_path" ] || return 1',
            runtime_certbot,
        )
        runtime_service_load = runtime.index(
            "systemctl show certbot.service", runtime_executable
        )
        runtime_service_loaded = runtime.index(
            '[ "$service_load_state" = loaded ] || return 1',
            runtime_service_load,
        )
        runtime_exec = runtime.index(
            "systemctl show certbot.service --property=ExecStart --value",
            runtime_service_loaded,
        )
        runtime_exec_pre = runtime.index(
            "--property=ExecStartPre --value", runtime_exec
        )
        runtime_exec_condition = runtime.index(
            "--property=ExecCondition --value", runtime_exec_pre
        )
        runtime_conditions = runtime.index(
            "--property=Conditions --value", runtime_exec_condition
        )
        runtime_asserts = runtime.index(
            "--property=Asserts --value", runtime_conditions
        )
        runtime_blockers_empty = runtime.index(
            '[ -z "${unit_asserts//[[:space:]]/}" ] || return 1',
            runtime_asserts,
        )
        runtime_exec_unique = runtime.index(
            'raw.count("{") != 1', runtime_blockers_empty
        )
        runtime_exec_path = runtime.index(
            "if exec_path != certbot_path:", runtime_exec_unique
        )
        runtime_exec_renew = runtime.index(
            "if not renew_seen:", runtime_exec_path
        )
        runtime_load = runtime.index(
            "systemctl show certbot.timer --property=LoadState --value",
            runtime_exec_renew,
        )
        runtime_loaded = runtime.index(
            '[ "$timer_load_state" = loaded ] || return 1', runtime_load
        )
        runtime_triggers = runtime.index(
            "systemctl show certbot.timer --property=Triggers --value",
            runtime_loaded,
        )
        runtime_trigger_exact = runtime.index(
            '[ "${#trigger_units[@]}" -eq 1 ]', runtime_triggers
        )
        runtime_next_realtime = runtime.index(
            "--property=NextElapseUSecRealtime --value", runtime_trigger_exact
        )
        runtime_next_monotonic = runtime.index(
            "--property=NextElapseUSecMonotonic --value", runtime_next_realtime
        )
        runtime_next_scheduled = runtime.index(
            '[ "$next_scheduled" = true ] || return 1', runtime_next_monotonic
        )
        runtime_enabled = runtime.index(
            "systemctl is-enabled certbot.timer", runtime_next_scheduled
        )
        runtime_enabled_states = runtime.index(
            "enabled|enabled-runtime", runtime_enabled
        )
        runtime_active = runtime.index(
            "systemctl is-active --quiet certbot.timer", runtime_enabled_states
        )
        runtime_route = runtime.index(
            'rr_certbot_acme_http_route_is_ready "$domain"', runtime_active
        )

        enable_domain = enable.index('is_valid_domain "$domain" || return 1')
        enable_route = enable.index(
            'rr_certbot_acme_http_route_is_ready "$domain" || return 1',
            enable_domain,
        )
        enable_timer = enable.index(
            "systemctl enable --now certbot.timer", enable_route
        )
        enable_final = enable.index(
            'rr_certbot_renewal_runtime_is_ready "$domain"', enable_timer
        )
    except ValueError:
        return False

    forbidden_route_writes = (
        "certbot renew", "certbot certonly", "systemctl enable",
        "systemctl start", "systemctl restart", "systemctl reload",
        "open_protocol_firewall", "save_firewall", "os.write(",
        ".write_text(", ".write_bytes(", "shutil.", "subprocess.",
        "\n    install ", "\n    mkdir ", "\n    rm ", "\n    mv ",
        "\n    cp ", "\n    ln ", "\n    chmod ", "\n    chown ",
    )
    runtime_blocker_tokens = (
        '[ -z "${exec_start_pre//[[:space:]]/}" ] || return 1',
        '[ -z "${exec_condition//[[:space:]]/}" ] || return 1',
        '[ -z "${unit_conditions//[[:space:]]/}" ] || return 1',
        '[ -z "${unit_asserts//[[:space:]]/}" ] || return 1',
        'raw.count("{") != 1',
        'raw.count("path=") != 1',
        'raw.count("argv[]=") != 1',
        'raw.count("ignore_errors=") != 1',
        'if ignore_errors != ["no"]:',
    )
    runtime_effective_unit_tokens = (
        "        /lib/systemd/system/certbot.service|\\\n",
        "        /usr/lib/systemd/system/certbot.service) ;;",
        "        /lib/systemd/system/certbot.timer|\\\n",
        "        /usr/lib/systemd/system/certbot.timer) ;;",
        "--property=FragmentPath --value",
        '[ ! -L "$service_fragment" ] || return 1',
        '[ ! -L "$timer_fragment" ] || return 1',
        "stat -c '%u:%g:%a:%h:%F'",
        "'0:0:1:regular file'",
        '(( (8#$fragment_mode & 8#022) == 0 )) || return 1',
        "--property=DropInPaths --value",
        '[ -z "${service_dropins//[[:space:]]/}" ] || return 1',
        '[ -z "${timer_dropins//[[:space:]]/}" ] || return 1',
        '--property=User --value',
        'in ""|root)',
        '--property=DynamicUser --value',
        '[ "$dynamic_user" = no ] || return 1',
        '--property=RemainAfterExit --value',
        '[ "$remain_after_exit" = no ] || return 1',
        '--property=PrivateNetwork --value',
        '[ "$private_network" = no ] || return 1',
        '--property=RootDirectory --value',
        '[ -z "${root_directory//[[:space:]]/}" ] || return 1',
        '--property=RootImage --value',
        '--property=ProtectSystem --value',
        '[ "$protect_system" = no ] || return 1',
        '--property=ReadOnlyPaths --value',
        '--property=InaccessiblePaths --value',
        '--property=BindPaths --value',
        '--property=BindReadOnlyPaths --value',
        '--property=TemporaryFileSystem --value',
        '--property=NoExecPaths --value',
        '--property=NetworkNamespacePath --value',
        '--property=PrivateUsers --value',
        '[ "$private_users" = no ] || return 1',
        '--property=RestrictAddressFamilies --value',
        'if (( systemd_version >= 250 )); then',
        '--property=RestrictNetworkInterfaces --value',
        '--property=RestrictFileSystems --value',
        '--property=SystemCallFilter --value',
        '--property=MountImages --value',
        '--property=ExtensionImages --value',
        'if (( systemd_version >= 251 )); then',
        '--property=ExtensionDirectories --value',
        '--property=JoinsNamespaceOf --value',
        '--property=IPAddressDeny --value',
        '[ -z "${timer_conditions//[[:space:]]/}" ] || return 1',
        '[ -z "${timer_asserts//[[:space:]]/}" ] || return 1',
        '--property=TimersCalendar --value',
        '--property=RandomizedDelayUSec --value',
        '--property=AccuracyUSec --value',
        'if (( systemd_version >= 258 )); then',
        '--property=RandomizedOffsetUSec --value',
        'MAX_INTERVAL = 7 * 24 * 60 * 60',
        'MAX_DAILY_BASE_INTERVAL_US = 2 * 24 * 60 * 60 * 1_000_000',
        'def duration_us(raw):',
        'worst_delay_us = sum(',
        'if MAX_DAILY_BASE_INTERVAL_US + worst_delay_us > MAX_INTERVAL_US:',
        '"--iterations=2"',
        'r"\\*-\\*-\\* [0-9*~,/.:+-]+"',
        'now < next_epoch <= now + MAX_INTERVAL',
        '(first - now) * 1_000_000 <= MAX_DAILY_BASE_INTERVAL_US',
        '(second - first) * 1_000_000 <= MAX_DAILY_BASE_INTERVAL_US',
    )
    return (
        all(token in probe for token in effective_probe_required_tokens)
        and '"-L"' not in probe and '"--location"' not in probe
        and all(token in route for token in runtime_route_required_tokens)
        and route.count("rr_validate_protocol_firewall 80 tcp open") == 1
        and not any(token in route for token in forbidden_route_writes)
        and all(token in runtime for token in runtime_blocker_tokens)
        and all(token in runtime for token in runtime_effective_unit_tokens)
        and runtime.count("--property=FragmentPath --value") == 2
        and runtime.count('[ ! -L "$service_fragment" ] || return 1') == 1
        and runtime.count('[ ! -L "$timer_fragment" ] || return 1') == 1
        and runtime.count("stat -c '%u:%g:%a:%h:%F'") == 2
        and runtime.count("'0:0:1:regular file'") == 2
        and runtime.count('(( (8#$fragment_mode & 8#022) == 0 )) || return 1') == 2
        and runtime.count("--property=DropInPaths --value") == 2
        and runtime_domain < runtime_certbot < runtime_executable
        < runtime_service_load < runtime_service_loaded < runtime_exec
        < runtime_exec_pre < runtime_exec_condition < runtime_conditions
        < runtime_asserts < runtime_blockers_empty < runtime_exec_unique
        < runtime_exec_path < runtime_exec_renew < runtime_load
        < runtime_loaded < runtime_triggers < runtime_trigger_exact
        < runtime_next_realtime < runtime_next_monotonic
        < runtime_next_scheduled < runtime_enabled < runtime_enabled_states
        < runtime_active < runtime_route
        and runtime.count('rr_certbot_acme_http_route_is_ready "$domain"') == 1
        and "systemctl enable" not in runtime
        and enable_domain < enable_route < enable_timer < enable_final
        and enable.count('rr_certbot_acme_http_route_is_ready "$domain"') == 1
        and enable.count('rr_certbot_renewal_runtime_is_ready "$domain"') == 1
    )


assert certificate_runtime_route_contract(config)
runtime_route_mutations = (
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        "os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW",
        "os.O_WRONLY | os.O_CREAT | os.O_TRUNC",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        "or info.st_nlink != 1",
        "or False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        "unlink_verified(directory_fd, stale)",
        ": # removed SIGKILL residue convergence",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        'for address in ("127.0.0.1", "[::1]"):',
        'for address in ("127.0.0.1",):',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        '"--noproxy", "*"',
        '"--proxy", "http://127.0.0.1:9"',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        '"--path-as-is"',
        '"--location"',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        '"--max-filesize", str(MAX_RESPONSE)',
        '"--max-filesize", "0"',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        'result.stdout != body + b"200"',
        "False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_effective_route_probe() (",
        "\nrr_certbot_acme_http_route_is_ready() {",
        "cleanup_failure = error",
        "cleanup_failure = None",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW",
        "os.O_RDONLY",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "or (before.st_uid, before.st_gid) != (0, 0)",
        "or False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "stat.S_IMODE(before.st_mode) != 0o644",
        "False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "before.st_nlink != 1",
        "False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "if raw_target != str(site):",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "nginx -t >/dev/null 2>&1 || return 1",
        ": # removed Nginx configuration proof",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "if len(challenge_mentions) != 1:",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        'ipv4_listeners = top_level.count("listen 80;")',
        "False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "if port_80_listeners:",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "if expected_domain.lower() not in route_domains:",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "systemctl is-active --quiet nginx >/dev/null 2>&1 || return 1",
        ": # removed Nginx activity proof",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "ss -H -ltn 'sport = :80'",
        "printf ''",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        "rr_validate_protocol_firewall 80 tcp open",
        "true # removed effective firewall proof",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_acme_http_route_is_ready() {",
        "\nrr_certbot_renewal_runtime_is_ready() {",
        'rr_certbot_acme_effective_route_probe "$domain" "$webroot"',
        "true # removed effective Host-route proof",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$service_load_state" = loaded ] || return 1',
        "true # accepted masked Certbot service",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "if exec_path != certbot_path:",
        "true # removed trusted service ExecStart path",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "if not renew_seen:",
        "true # removed certbot renew argv proof",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        'raw.count("{") != 1',
        "False",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        'if ignore_errors != ["no"]:',
        'if False:',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=ExecStartPre --value",
        "--property=ExecStopPost --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=ExecCondition --value",
        "--property=ControlPID --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${unit_conditions//[[:space:]]/}" ] || return 1',
        "true # accepted unit Conditions",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${unit_asserts//[[:space:]]/}" ] || return 1',
        "true # accepted unit Asserts",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "/lib/systemd/system/certbot.service",
        "/etc/systemd/system/certbot.service",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ ! -L "$service_fragment" ] || return 1',
        "true # accepted a symlinked service fragment",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "'0:0:1:regular file'",
        "'0:0:1:symbolic link'",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '(( (8#$fragment_mode & 8#022) == 0 )) || return 1',
        "true # accepted writable service fragment",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${service_dropins//[[:space:]]/}" ] || return 1',
        "true # accepted unknown service drop-ins",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        'in ""|root)',
        'in ""|root|nobody)',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$dynamic_user" = no ] || return 1',
        "true # accepted a dynamic service identity",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$remain_after_exit" = no ] || return 1',
        "true # accepted a sticky oneshot service",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$private_network" = no ] || return 1',
        "true # accepted a private network namespace",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${root_directory//[[:space:]]/}" ] || return 1',
        "true # accepted a chrooted Certbot runtime",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$protect_system" = no ] || return 1',
        "true # accepted a write-blocked Certbot runtime",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=ReadOnlyPaths --value",
        "--property=ReadWritePaths --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=BindPaths --value",
        "--property=BindReadOnlyPaths --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$private_users" = no ] || return 1',
        "true # accepted a private user namespace",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=RestrictNetworkInterfaces --value",
        "--property=NetworkNamespacePath --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=RestrictFileSystems --value",
        "--property=ReadOnlyPaths --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=SystemCallFilter --value",
        "--property=SystemCallLog --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=MountImages --value",
        "--property=RootImage --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=ExtensionImages --value",
        "--property=MountImages --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=ExtensionDirectories --value",
        "--property=MountImages --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=JoinsNamespaceOf --value",
        "--property=Requires --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "/lib/systemd/system/certbot.timer",
        "/etc/systemd/system/certbot.timer",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ ! -L "$timer_fragment" ] || return 1',
        "true # accepted a symlinked timer fragment",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${timer_dropins//[[:space:]]/}" ] || return 1',
        "true # accepted unknown timer drop-ins",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${timer_conditions//[[:space:]]/}" ] || return 1',
        "true # accepted timer Conditions",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ -z "${timer_asserts//[[:space:]]/}" ] || return 1',
        "true # accepted timer Asserts",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=TimersCalendar --value",
        "--property=TimersMonotonic --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=RandomizedDelayUSec --value",
        "--property=LastTriggerUSec --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "--property=AccuracyUSec --value",
        "--property=LastTriggerUSec --value",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "if (( systemd_version >= 258 )); then",
        "if false; then",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "worst_delay_us = sum(",
        "worst_delay_us = 0 # removed timer jitter bound\n#",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '"--iterations=2"',
        '"--iterations=1"',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        'r"\\*-\\*-\\* [0-9*~,/.:+-]+"',
        'r".*"',
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "if MAX_DAILY_BASE_INTERVAL_US + worst_delay_us > MAX_INTERVAL_US:",
        "if False:",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        "MAX_INTERVAL = 7 * 24 * 60 * 60",
        "MAX_INTERVAL = 100 * 365 * 24 * 60 * 60",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "${#trigger_units[@]}" -eq 1 ]',
        "true",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        '[ "$next_scheduled" = true ] || return 1',
        "true # accepted an empty next trigger",
    ),
    mutate_function_slice(
        config,
        "rr_certbot_renewal_runtime_is_ready() {",
        "\nrr_enable_certbot_renewal_runtime() {",
        'rr_certbot_acme_http_route_is_ready "$domain"',
        "true",
    ),
    mutate_function_slice(
        config,
        "rr_enable_certbot_renewal_runtime() {",
        "\nrr_install_certificate_deploy_hook() {",
        'rr_certbot_acme_http_route_is_ready "$domain" || return 1',
        ": # removed pre-mutation route proof",
    ),
    mutate_function_slice(
        config,
        "rr_enable_certbot_renewal_runtime() {",
        "\nrr_install_certificate_deploy_hook() {",
        '    rr_certbot_acme_http_route_is_ready "$domain" || return 1\n'
        '    systemctl enable --now certbot.timer >/dev/null 2>&1 || return 1',
        '    systemctl enable --now certbot.timer >/dev/null 2>&1 || return 1\n'
        '    rr_certbot_acme_http_route_is_ready "$domain" || return 1',
    ),
)
for mutated in runtime_route_mutations:
    assert not certificate_runtime_route_contract(mutated)


def certificate_lifecycle_contract(config_candidate, singbox_candidate, nexus_candidate):
    try:
        _, _, subscription = function_slice(
            config_candidate, "start_subscription_server() {", None
        )
        _, _, naive = function_slice(
            singbox_candidate,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
        )
        _, _, nexus_issue = function_slice(
            nexus_candidate,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
        )
        _, _, nexus_reconcile = function_slice(
            nexus_candidate,
            "nexus_reconcile_public_proxy() {",
            "\nnexus_public_proxy_health_check() {",
        )

        subscription_pair = subscription.index(
            'subscription_certificate_pair_valid "$cert_file" "$key_file" "$SUB_DOMAIN"'
        )
        subscription_lineage = subscription.index(
            'rr_certbot_webroot_lineage_is_renewable "$SUB_DOMAIN" || {',
            subscription_pair,
        )
        subscription_runtime = subscription.index(
            "rr_certbot_renewal_runtime_is_ready", subscription_lineage
        )
        subscription_hook = subscription.index(
            "deploy_subscription_cert_hook || return 1",
            subscription_runtime,
        )

        update_pair = naive.index("if ! naive_certificate_pair_valid")
        update_lineage = naive.index(
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {',
            update_pair,
        )
        update_runtime = naive.index(
            'rr_certbot_renewal_runtime_is_ready "$naive_domain"',
            update_lineage,
        )
        update_sync = naive.index("sync_naive_certificate_pair", update_runtime)
        update_hook = naive.index(
            "deploy_naive_cert_hook || return 1", update_sync
        )
        reuse_pair = naive.index(
            "if naive_certificate_pair_valid", update_sync
        )
        reuse_lineage = naive.index(
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain"; then',
            reuse_pair,
        )
        reuse_runtime = naive.index(
            'rr_enable_certbot_renewal_runtime "$naive_domain"', reuse_lineage
        )
        reuse_sync = naive.index("sync_naive_certificate_pair", reuse_runtime)
        reuse_hook = naive.index(
            "deploy_naive_cert_hook || return 1", reuse_sync
        )
        certbot = naive.index("certbot certonly --webroot", reuse_sync)
        cert_name = naive.index('--cert-name "$naive_domain"', certbot)
        issued_pair = naive.index("naive_certificate_pair_valid", cert_name)
        issued_lineage = naive.index(
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain" || return 1',
            issued_pair,
        )
        issued_runtime = naive.index(
            'rr_enable_certbot_renewal_runtime "$naive_domain"', issued_lineage
        )
        issued_sync = naive.index("sync_naive_certificate_pair", issued_runtime)
        issued_hook = naive.index(
            "deploy_naive_cert_hook || return 1", issued_sync
        )

        nexus_certbot = nexus_issue.index("certbot certonly --webroot")
        nexus_cert_name = nexus_issue.index('--cert-name "$domain"', nexus_certbot)
        nexus_pair = nexus_issue.index(
            "subscription_certificate_pair_valid", nexus_cert_name
        )
        nexus_lineage = nexus_issue.index(
            'rr_certbot_webroot_lineage_is_renewable "$domain"', nexus_pair
        )
        nexus_hook = nexus_issue.index(
            "nexus_certificate_deploy_hook_is_ready", nexus_lineage
        )
        nexus_runtime = nexus_issue.index(
            'rr_enable_certbot_renewal_runtime "$domain"', nexus_hook
        )
        nexus_proxy = nexus_issue.index(
            'nexus_write_nginx_custom_port "$domain" "$port"', nexus_runtime
        )
        nexus_firewall = nexus_issue.index(
            'nexus_firewall_open_accounted "$port" tcp panel_created', nexus_proxy
        )
        nexus_reload = nexus_issue.index(
            "if ! nginx -t || ! systemctl reload nginx; then", nexus_firewall
        )
        nexus_final_runtime = nexus_issue.index(
            'rr_certbot_renewal_runtime_is_ready "$domain" || {', nexus_reload
        )
        reconcile_pair = nexus_reconcile.index(
            "subscription_certificate_pair_valid"
        )
        reconcile_lineage = nexus_reconcile.index(
            'rr_certbot_webroot_lineage_is_renewable "$domain" || return 1',
            reconcile_pair,
        )
        reconcile_hook = nexus_reconcile.index(
            "nexus_certificate_deploy_hook_is_ready", reconcile_lineage
        )
        reconcile_proxy = nexus_reconcile.index(
            'nexus_write_nginx_custom_port "$domain" "$port"',
            reconcile_hook,
        )
        reconcile_firewall_80 = nexus_reconcile.index(
            "nexus_firewall_open_accounted 80 tcp http_created", reconcile_proxy
        )
        reconcile_firewall_port = nexus_reconcile.index(
            'nexus_firewall_open_accounted "$port" tcp panel_created',
            reconcile_firewall_80,
        )
        reconcile_final_runtime = nexus_reconcile.index(
            'rr_certbot_renewal_runtime_is_ready "$domain" || {',
            reconcile_firewall_port,
        )
    except ValueError:
        return False

    return (
        subscription_pair < subscription_lineage < subscription_runtime
        < subscription_hook
        and subscription.count(
            'rr_certbot_webroot_lineage_is_renewable "$SUB_DOMAIN"'
        ) == 1
        and subscription.count(
            'rr_certbot_renewal_runtime_is_ready "$SUB_DOMAIN"'
        ) == 1
        and subscription.count("rr_certbot_renewal_runtime_is_ready") == 2
        and subscription.count("deploy_subscription_cert_hook || return 1") == 1
        and update_pair < update_lineage < update_runtime < update_sync < update_hook
        and reuse_pair < reuse_lineage < reuse_runtime < reuse_sync < reuse_hook
        and certbot < cert_name < issued_pair < issued_lineage < issued_runtime
        < issued_sync < issued_hook
        and naive.count(
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain"'
        ) == 3
        and naive.count(
            'rr_certbot_renewal_runtime_is_ready "$naive_domain"'
        ) == 1
        and naive.count(
            'rr_enable_certbot_renewal_runtime "$naive_domain"'
        ) == 2
        and naive.count("deploy_naive_cert_hook || return 1") == 3
        and nexus_certbot < nexus_cert_name < nexus_pair < nexus_lineage
        < nexus_hook < nexus_runtime < nexus_proxy < nexus_firewall
        < nexus_reload < nexus_final_runtime
        and nexus_issue.count(
            'rr_certbot_webroot_lineage_is_renewable "$domain"'
        ) == 1
        and nexus_issue.count("nexus_certificate_deploy_hook_is_ready") == 1
        and nexus_issue.count(
            'rr_enable_certbot_renewal_runtime "$domain"'
        ) == 1
        and nexus_issue.count(
            'rr_certbot_renewal_runtime_is_ready "$domain"'
        ) == 1
        and reconcile_pair < reconcile_lineage < reconcile_hook
        < reconcile_proxy < reconcile_firewall_80
        < reconcile_firewall_port < reconcile_final_runtime
        and nexus_reconcile.count(
            'rr_certbot_webroot_lineage_is_renewable "$domain"'
        ) == 1
        and nexus_reconcile.count(
            'rr_certbot_renewal_runtime_is_ready "$domain"'
        ) == 1
        and nexus_reconcile.count("nexus_certificate_deploy_hook_is_ready") == 1
    )


assert certificate_lifecycle_contract(config, singbox, nexus)
lifecycle_mutations = (
    (
        "config",
        mutate_function_slice(
            config,
            "start_subscription_server() {",
            None,
            'rr_certbot_webroot_lineage_is_renewable "$SUB_DOMAIN" || {',
            "true || {",
        ),
    ),
    (
        "config",
        mutate_function_slice(
            config,
            "start_subscription_server() {",
            None,
            "rr_certbot_renewal_runtime_is_ready",
            "removed_certbot_renewal_runtime",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {',
            "true || {",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            "rr_certbot_renewal_runtime_is_ready",
            "removed_certbot_renewal_runtime",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            'rr_certbot_renewal_runtime_is_ready "$naive_domain"',
            'rr_certbot_renewal_runtime_is_ready "wrong.example"',
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            "deploy_naive_cert_hook || return 1",
            "removed_ordinary_update_hook || return 1",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain"; then',
            "true; then",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            "rr_enable_certbot_renewal_runtime",
            "removed_reuse_runtime",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            'rr_certbot_webroot_lineage_is_renewable "$naive_domain" || return 1',
            "true || return 1",
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            "rr_enable_certbot_renewal_runtime",
            "removed_issued_runtime",
            last=True,
        ),
    ),
    (
        "singbox",
        mutate_function_slice(
            singbox,
            "ensure_naive_certificate() {",
            "\nrr_certificate_deploy_hook_is_current() {",
            '--cert-name "$naive_domain"',
            "--removed-cert-name",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            '--cert-name "$domain"',
            "--removed-cert-name",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            '! rr_certbot_webroot_lineage_is_renewable "$domain"; then',
            "! true; then",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            "nexus_certificate_deploy_hook_is_ready",
            "removed_nexus_deploy_hook",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            "rr_enable_certbot_renewal_runtime",
            "removed_nexus_runtime",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            'rr_enable_certbot_renewal_runtime "$domain"',
            "rr_enable_certbot_renewal_runtime",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
            'rr_certbot_renewal_runtime_is_ready "$domain"',
            "removed_nexus_final_runtime",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_reconcile_public_proxy() {",
            "\nnexus_public_proxy_health_check() {",
            'rr_certbot_webroot_lineage_is_renewable "$domain" || return 1',
            "true",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_reconcile_public_proxy() {",
            "\nnexus_public_proxy_health_check() {",
            "rr_certbot_renewal_runtime_is_ready",
            "removed_reconcile_runtime",
        ),
    ),
    (
        "nexus",
        mutate_function_slice(
            nexus,
            "nexus_reconcile_public_proxy() {",
            "\nnexus_public_proxy_health_check() {",
            "nexus_certificate_deploy_hook_is_ready",
            "removed_reconcile_hook",
        ),
    ),
)
for changed, candidate in lifecycle_mutations:
    assert not certificate_lifecycle_contract(
        candidate if changed == "config" else config,
        candidate if changed == "singbox" else singbox,
        candidate if changed == "nexus" else nexus,
    )


def post_update_certificate_gate_contract(candidate):
    try:
        _, _, migrate = function_slice(
            candidate,
            "post_update_migrate() {",
            "\nensure_runtime_health() {",
        )
        naive = migrate.index('if [ "${NAIVE_ENABLED:-false}" = true ]; then')
        unit = migrate.index(
            'local singbox_service_file="${RR_SINGBOX_SERVICE_FILE:-', naive
        )
        shape = migrate.index(
            '[ -f "$singbox_service_file" ] && [ ! -L "$singbox_service_file" ]',
            unit,
        )
        install_gate = migrate.index(
            "ensure_singbox_service_guards || return 1", shape
        )
        effective_gate = migrate.index(
            "rr_singbox_service_guards_are_effective || return 1", install_gate
        )
        publish_pair = migrate.index(
            'ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL" || return 1',
            effective_gate,
        )
    except ValueError:
        return False
    return naive < unit < shape < install_gate < effective_gate < publish_pair


assert post_update_certificate_gate_contract(update)
for old, replacement in (
    (
        '[ -f "$singbox_service_file" ] && [ ! -L "$singbox_service_file" ]',
        "true # removed safe existing unit requirement",
    ),
    (
        "ensure_singbox_service_guards || return 1",
        "true # removed atomic certificate start gate install",
    ),
    (
        "rr_singbox_service_guards_are_effective || return 1",
        "true # removed compiled certificate start gate proof",
    ),
):
    mutated = mutate_function_slice(
        update,
        "post_update_migrate() {",
        "\nensure_runtime_health() {",
        old,
        replacement,
    )
    assert mutated != update
    assert not post_update_certificate_gate_contract(mutated)


def nexus_firewall_lifecycle_contract(candidate):
    try:
        _, _, needed = function_slice(
            candidate,
            "nexus_firewall_tuple_needed_without_nexus() {",
            "\nnexus_firewall_open_accounted() {",
        )
        _, _, accounted = function_slice(
            candidate,
            "nexus_firewall_open_accounted() {",
            "\nnexus_firewall_reconcile_without_nexus() {",
        )
        _, _, abort_public = function_slice(
            candidate,
            "nexus_abort_public_activation() {",
            "\nnexus_enable_public_https() {",
        )
        _, _, enable_domain = function_slice(
            candidate,
            "nexus_enable_public_https() {",
            "\nnexus_remove_public_proxy() {",
        )
        _, _, enable_ip = function_slice(
            candidate,
            "nexus_enable_public_ip_https() {",
            "\nnexus_firewall_tuple_array_add() {",
        )
        _, _, pending_mark = function_slice(
            candidate,
            "nexus_ip_certificate_mark_pending() {",
            "\nnexus_ip_certificate_clear_pending() {",
        )
        _, _, install_cert_gate = function_slice(
            candidate,
            "nexus_install_ip_certificate_gate() {",
            "\nnexus_ip_certificate_gate_allows() {",
        )
        _, _, emit_cert_gate_dropin = function_slice(
            candidate,
            "nexus_emit_ip_certificate_gate_dropin() {",
            "\nnexus_ip_certificate_gate_script_is_current() {",
        )
        _, _, compiled_cert_gates = function_slice(
            candidate,
            "nexus_nginx_exec_condition_set_is_exact() {",
            "\nnexus_install_ip_certificate_gate() {",
        )
        _, _, remove_cert_gate = function_slice(
            candidate,
            "nexus_remove_ip_certificate_gate() {",
            "\nnexus_publish_ip_certificate_pair() {",
        )
        _, _, publish_cert_pair = function_slice(
            candidate,
            "nexus_publish_ip_certificate_pair() {",
            "\nnexus_enable_public_ip_https() {",
        )
        _, _, publish_config = function_slice(
            candidate,
            "nexus_publish_config_candidate() {",
            "\nnexus_write_config() {",
        )
        _, _, write_config = function_slice(
            candidate,
            "nexus_write_config() {",
            "\nnexus_sync_subscription_endpoint() {",
        )
        _, _, sync_config = function_slice(
            candidate,
            "nexus_sync_subscription_endpoint() {",
            "\nnexus_set_certificate_mode() {",
        )
        _, _, migrate_config = function_slice(
            candidate,
            "nexus_migrate_runtime_config() {",
            "\nnexus_emit_service_unit() {",
        )
        _, _, effective_guards = function_slice(
            candidate,
            "nexus_service_effective_guards_are_exact() {",
            "\nnexus_service_effective_identity_is_exact() {",
        )
        _, _, effective_identity = function_slice(
            candidate,
            "nexus_service_effective_identity_is_exact() {",
            "\nnexus_write_service() {",
        )
        _, _, write_service = function_slice(
            candidate,
            "nexus_write_service() {",
            "\n# T4：为旧版已安装的 rr-nexus 单元幂等补齐",
        )
        _, _, restore_singbox = function_slice(
            candidate,
            "nexus_restore_singbox_transaction() {",
            "\nnexus_enable_traffic_engine() {",
        )
        _, _, traffic_engine = function_slice(
            candidate,
            "nexus_enable_traffic_engine() {",
            "\nnexus_protocol_users() {",
        )
        _, _, sync_devices = function_slice(
            candidate,
            "_sync_nexus_devices_locked() {",
            "\nNEXUS_GRPCIO_MIN_VERSION=",
        )
        _, _, service_guards = function_slice(
            candidate,
            "ensure_nexus_service_guards() {",
            "\nnexus_prompt_admin() {",
        )
        _, _, deactivate = function_slice(
            candidate,
            "nexus_deactivate_public_access() {",
            "\nnexus_reconcile_public_proxy() {",
        )
        _, _, local_health = function_slice(
            candidate,
            "nexus_local_backend_health_check() {",
            "\nnexus_start_service() {",
        )
        _, _, start_service = function_slice(
            candidate,
            "nexus_start_service() {",
            "\nnexus_abort_install_transaction() {",
        )
        _, _, install = function_slice(
            candidate,
            "nexus_install() {",
            "\nnexus_reset_admin() {",
        )
        _, _, uninstall = function_slice(
            candidate,
            "nexus_uninstall() {",
            "\nnexus_menu() {",
        )

        accounted_pre = accounted.index(
            'rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" open'
        )
        accounted_writer = accounted.index(
            'open_protocol_firewall "$tuple_port" "$tuple_proto"',
            accounted_pre,
        )
        accounted_owned = accounted.index(
            'printf -v "$output_name" \'%s\' true', accounted_writer
        )
        accounted_post = accounted.index(
            'rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" open',
            accounted_writer,
        )

        abort_proxy = abort_public.index("nexus_remove_public_proxy")
        abort_firewall = abort_public.index(
            "nexus_firewall_compensate_public_opens", abort_proxy
        )
        abort_indeterminate = abort_public.index(
            '[ "$firewall_indeterminate" = true ]', abort_firewall
        )
        abort_fail_closed = abort_public.index(
            "nexus_firewall_fail_closed", abort_indeterminate
        )
        abort_determinate = abort_public.rindex("return 1")

        domain_http = enable_domain.index(
            "nexus_firewall_open_accounted 80 tcp http_created"
        )
        domain_panel = enable_domain.index(
            'nexus_firewall_open_accounted "$port" tcp panel_created',
            domain_http,
        )
        domain_final = enable_domain.index(
            'rr_certbot_renewal_runtime_is_ready "$domain"', domain_panel
        )

        ip_open = enable_ip.index(
            'nexus_firewall_open_accounted "$port" tcp panel_created'
        )
        ip_rollback = enable_ip.index(
            'if [ "$transaction_ok" != true ]; then', ip_open
        )
        ip_compensate = enable_ip.index(
            "nexus_firewall_compensate_public_opens", ip_rollback
        )
        ip_fail_closed = enable_ip.index(
            "nexus_firewall_fail_closed", ip_compensate
        )
        ip_determinate = enable_ip.index("return 1", ip_fail_closed)

        pending_file_sync = pending_mark.index('sync -f "$pending_tmp"')
        pending_publish = pending_mark.index(
            'mv -f -- "$pending_tmp" "$pending_file"', pending_file_sync
        )
        pending_dir_sync = pending_mark.index(
            'sync -f "$cert_dir"', pending_publish
        )
        cert_mark = publish_cert_pair.index(
            'nexus_ip_certificate_mark_pending "$cert_dir" "$pending_file"'
        )
        cert_key_publish = publish_cert_pair.index(
            'mv -f -- "$key_tmp" "$key_file"', cert_mark
        )
        cert_key_sync = publish_cert_pair.index(
            'sync -f "$cert_dir"', cert_key_publish
        )
        cert_leaf_publish = publish_cert_pair.index(
            'mv -f -- "$cert_tmp" "$cert_file"', cert_key_sync
        )
        cert_leaf_sync = publish_cert_pair.index(
            'sync -f "$cert_dir"', cert_leaf_publish
        )
        cert_pair_proof = publish_cert_pair.index(
            "nexus_ip_certificate_pair_is_ready", cert_leaf_sync
        )
        cert_clear = publish_cert_pair.index(
            "nexus_ip_certificate_clear_pending", cert_pair_proof
        )
        cert_gate_dropin = emit_cert_gate_dropin.index("ExecCondition=%s")
        cert_gate_script_sync = install_cert_gate.index('sync -f "$script_tmp"')
        cert_gate_dropin_sync = install_cert_gate.index(
            'sync -f "$dropin_tmp"', cert_gate_script_sync
        )
        cert_gate_script_publish = install_cert_gate.index(
            'mv -f -- "$script_tmp" "$gate_script"', cert_gate_dropin_sync
        )
        cert_gate_script_dir_sync = install_cert_gate.index(
            'sync -f "$script_dir"', cert_gate_script_publish
        )
        cert_gate_dropin_publish = install_cert_gate.index(
            'mv -f -- "$dropin_tmp" "$gate_dropin"', cert_gate_script_dir_sync
        )
        cert_gate_dropin_dir_sync = install_cert_gate.index(
            'sync -f "$dropin_dir"', cert_gate_dropin_publish
        )
        cert_gate_reload = install_cert_gate.index(
            "systemctl daemon-reload", cert_gate_dropin_dir_sync
        )
        cert_gate_effective = install_cert_gate.index(
            "nexus_nginx_exec_condition_set_is_exact",
            cert_gate_reload,
        )
        ip_gate_install = enable_ip.index("nexus_install_ip_certificate_gate")
        ip_pending_recovery = enable_ip.index(
            '[ -e "$pending_file" ] || [ -L "$pending_file" ]',
            ip_gate_install,
        )
        ip_publish = enable_ip.index(
            "nexus_publish_ip_certificate_pair", ip_pending_recovery
        )
        ip_pair_gate = enable_ip.index(
            "nexus_ip_certificate_gate_allows", ip_publish
        )
        ip_nginx_validate = enable_ip.index("nginx -t", ip_pair_gate)
        ip_reload_gate = enable_ip.index(
            "nexus_ip_certificate_gate_allows", ip_nginx_validate
        )
        ip_reload = enable_ip.index("systemctl reload nginx", ip_reload_gate)
        ip_failure = enable_ip.index(
            'if [ "$transaction_ok" != true ]; then', ip_reload
        )
        ip_rollback_mark = enable_ip.index(
            "nexus_ip_certificate_mark_pending", ip_failure
        )
        ip_rollback_remove = enable_ip.index(
            'for path in "${managed_paths[@]}"', ip_rollback_mark
        )
        ip_rollback_restore = enable_ip.index(
            'for index in "${!managed_paths[@]}"', ip_rollback_remove
        )
        ip_rollback_pair = enable_ip.index(
            "nexus_ip_certificate_restored_state_is_safe", ip_rollback_restore
        )
        ip_rollback_clear = enable_ip.index(
            "nexus_ip_certificate_clear_pending", ip_rollback_pair
        )

        config_chmod = publish_config.index('chmod 600 "$candidate"')
        config_json = publish_config.index(
            "jq -e 'type == \"object\"' \"$candidate\"", config_chmod
        )
        config_hash = publish_config.index(
            'expected_hash=$(sha256sum "$candidate"', config_json
        )
        config_file_sync = publish_config.index(
            'sync -f "$candidate"', config_hash
        )
        config_publish = publish_config.index(
            'mv -f -- "$candidate" "$target"', config_file_sync
        )
        config_dir_sync = publish_config.index(
            'sync -f "$target_dir"', config_publish
        )
        config_reread = publish_config.index(
            "jq -e 'type == \"object\"' \"$target\"", config_dir_sync
        )
        config_actual_hash = publish_config.index(
            'actual_hash=$(sha256sum "$target"', config_reread
        )
        write_config_tmp = write_config.index(
            'mktemp "$config_dir/.nexus.json.XXXXXX"'
        )
        write_config_bytes = write_config.index(
            "printf '%s\\n' \"$cfg\" > \"$tmp\"", write_config_tmp
        )
        write_config_publish = write_config.index(
            'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"',
            write_config_bytes,
        )

        unit_render = write_service.index('nexus_emit_service_unit > "$tmp"')
        unit_chmod = write_service.index('chmod 644 "$tmp"', unit_render)
        unit_hash = write_service.index(
            'expected_hash=$(sha256sum "$tmp"', unit_chmod
        )
        unit_file_sync = write_service.index('sync -f "$tmp"', unit_hash)
        unit_publish = write_service.index(
            'mv -f -- "$tmp" "$NEXUS_SERVICE_FILE"', unit_file_sync
        )
        unit_dir_sync = write_service.index(
            'sync -f "$service_dir"', unit_publish
        )
        unit_reload = write_service.index(
            "systemctl daemon-reload", unit_dir_sync
        )
        unit_guards = write_service.index(
            "ensure_nexus_service_guards", unit_reload
        )
        unit_identity = write_service.index(
            "nexus_service_effective_identity_is_exact", unit_guards
        )
        unit_effective_guards = write_service.index(
            "nexus_service_effective_guards_are_exact", unit_identity
        )

        identity_properties = (
            "--property=LoadState --value",
            "--property=FragmentPath --value",
            "--property=DropInPaths --value",
            "--property=ExecStart --value",
            "--property=ExecStartPre --value",
            "--property=ExecReload --value",
            "--property=User --value",
            "--property=Group --value",
            "--property=WorkingDirectory --value",
            "--property=DynamicUser --value",
            "--property=PrivateNetwork --value",
            "--property=RootDirectory --value",
            "--property=RootImage --value",
            "--property=Conditions --value",
            "--property=Asserts --value",
            "--property=ExecCondition --value",
        )
        identity_property_positions = tuple(
            effective_identity.index(property_name)
            for property_name in identity_properties
        )
        identity_rendered_unit = effective_identity.index(
            'cmp -s -- "$NEXUS_SERVICE_FILE" <(nexus_emit_service_unit)'
        )
        identity_guard_bytes = effective_identity.index(
            'cmp -s -- "$guard_file"', identity_rendered_unit
        )
        identity_restore_bytes = effective_identity.index(
            'cmp -s -- "$restore_dropin"', identity_guard_bytes
        )
        identity_firewall_bytes = effective_identity.index(
            'cmp -s -- "$firewall_dropin"', identity_restore_bytes
        )
        identity_dropin_count = effective_identity.index(
            '[ "${#effective_dropins[@]}" -eq "${#expected_dropins[@]}" ]',
            identity_property_positions[2],
        )
        identity_dropin_order = effective_identity.index(
            '[ "${effective_dropins[i]}" = "${expected_dropins[i]}" ]',
            identity_dropin_count,
        )
        identity_exec_start_shape = effective_identity.index(
            '(fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))',
            identity_property_positions[3],
        )
        identity_no_aux_exec = effective_identity.index(
            '[ -z "${exec_start_pre//[[:space:]]/}" ]',
            identity_property_positions[5],
        )
        identity_principal = effective_identity.index(
            '[ "$user" = root ] && [ "$working_directory" = "${RR_LIB_DIR}/nexus" ]',
            identity_property_positions[14],
        )
        identity_group = effective_identity.index(
            'case "${group//[[:space:]]/}" in ""|root)', identity_principal
        )
        identity_restore_condition_record = effective_identity.index(
            'expected.append(("/bin/sh", restore_argv, "no"))',
            identity_property_positions[15],
        )
        identity_firewall_exists_record = effective_identity.index(
            '("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no")',
            identity_restore_condition_record,
        )
        identity_firewall_link_record = effective_identity.index(
            '("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no")',
            identity_firewall_exists_record,
        )
        identity_exec_condition_records = effective_identity.index(
            "records != expected", identity_firewall_link_record
        )

        restore_binary = restore_singbox.index(
            'nexus_restore_singbox_file_state "$binary_snapshot"'
        )
        restore_config = restore_singbox.index(
            'nexus_restore_singbox_file_state "$config_snapshot"',
            restore_binary,
        )
        restore_restart = restore_singbox.index(
            "restart_singbox", restore_config
        )
        restore_runtime = restore_singbox.index(
            "nexus_singbox_runtime_matches_restored_files", restore_restart
        )
        restore_fail_closed = restore_singbox.index(
            "nexus_firewall_fail_closed", restore_runtime
        )
        traffic_binary_snapshot = traffic_engine.index(
            'nexus_capture_singbox_file_state "$SINGBOX_BIN"'
        )
        traffic_config_snapshot = traffic_engine.index(
            "nexus_capture_singbox_file_state /etc/sing-box/config.json",
            traffic_binary_snapshot,
        )
        traffic_candidate = traffic_engine.index(
            "if ! nexus_core_supports_traffic", traffic_config_snapshot
        )
        sync_snapshot = sync_devices.index(
            "nexus_capture_singbox_file_state /etc/sing-box/config.json"
        )
        sync_candidate = sync_devices.index(
            "if ! build_singbox_config", sync_snapshot
        )

        guard_write = service_guards.index('cat > "$guard_tmp"')
        guard_file_sync = service_guards.index('sync -f "$guard_tmp"', guard_write)
        guard_publish = service_guards.index(
            'mv -f -- "$guard_tmp" "$guard_file"', guard_file_sync
        )
        guard_dir_sync = service_guards.index(
            'sync -f "$guard_dir"', guard_publish
        )
        guard_reload = service_guards.index(
            "systemctl daemon-reload", guard_dir_sync
        )
        guard_proof = service_guards.index(
            "nexus_service_effective_guards_are_exact", guard_reload
        )
        guard_interval = effective_guards.index(
            "--property=StartLimitIntervalUSec --value"
        )
        guard_burst = effective_guards.index(
            "--property=StartLimitBurst --value", guard_interval
        )
        guard_restart = effective_guards.index(
            "--property=RestartPreventExitStatus --value", guard_burst
        )

        deactivate_config = deactivate.index(
            "nexus_collect_configured_public_firewall_tuples"
        )
        deactivate_site = deactivate.index(
            "nexus_collect_managed_proxy_firewall_tuples", deactivate_config
        )
        deactivate_proxy = deactivate.index(
            "nexus_remove_public_proxy", deactivate_site
        )
        deactivate_firewall = deactivate.index(
            "nexus_reconcile_firewall_tuple_list", deactivate_proxy
        )
        deactivate_fail_closed = deactivate.index(
            "nexus_firewall_fail_closed", deactivate_firewall
        )

        service_active = start_service.index(
            "systemctl is-active --quiet rr-nexus"
        )
        service_health = start_service.index(
            "nexus_local_backend_health_check", service_active
        )
        service_success = start_service.index("Nexus 已启动", service_health)

        install_deactivate = install.index("nexus_deactivate_public_access")
        install_config = install.index("nexus_write_config", install_deactivate)
        install_admin = install.index("nexus_prompt_admin", install_config)
        install_traffic = install.index("nexus_enable_traffic_engine", install_admin)
        install_subscriptions = install.index(
            "generate_nexus_device_subscriptions", install_traffic
        )
        install_service = install.index(
            'nexus_start_service "$port"', install_subscriptions
        )
        install_domain = install.index(
            'nexus_enable_public_https "${domain,,}" "$email" "$port"',
            install_service,
        )
        install_ip = install.index(
            'nexus_enable_public_ip_https "$ENTRY_IP_RAW" "$port"',
            install_domain,
        )
        install_proxy_health = install.index(
            "nexus_public_proxy_health_check", install_ip
        )
        install_public_compensation = install.index(
            "nexus_abort_public_activation", install_proxy_health
        )
        install_health_abort = install.index(
            "nexus_abort_install_transaction", install_public_compensation
        )
        install_success = install.index(
            "RR Nexus 已安装并启用", install_health_abort
        )

        uninstall_snapshot = uninstall.index(
            'config_snapshot=$(mktemp "$NEXUS_DATA_DIR/.uninstall-config.XXXXXX")'
        )
        uninstall_config = uninstall.index(
            "nexus_collect_configured_public_firewall_tuples", uninstall_snapshot
        )
        uninstall_site = uninstall.index(
            "nexus_collect_managed_proxy_firewall_tuples", uninstall_config
        )
        uninstall_stop = uninstall.index(
            "systemctl disable --now rr-nexus", uninstall_site
        )
        uninstall_inactive = uninstall.index(
            "systemctl is-active --quiet rr-nexus", uninstall_stop
        )
        uninstall_proxy = uninstall.index(
            "nexus_remove_public_proxy", uninstall_inactive
        )
        uninstall_firewall = uninstall.index(
            "nexus_reconcile_firewall_tuple_list", uninstall_proxy
        )
        uninstall_cert_gate = uninstall.index(
            "nexus_remove_ip_certificate_gate", uninstall_firewall
        )
        uninstall_service = uninstall.index(
            'rm -f "$NEXUS_SERVICE_FILE"', uninstall_cert_gate
        )
        uninstall_config_dir = uninstall.index(
            'rm -rf -- "$config_dir"', uninstall_service
        )
        uninstall_success = uninstall.index(
            "RR Nexus 已卸载", uninstall_config_dir
        )
    except ValueError:
        return False

    return (
        'local NEXUS_CONFIG_FILE=/dev/null' in needed
        and '[ "${NAIVE_ENABLED:-false}" = true ]' in needed
        and '"${NAIVE_DOMAIN:-}" =~' in needed
        and '[ "${SUB_ACCESS_MODE:-local}" = https ]' in needed
        and '"${SUB_DOMAIN:-}" =~' in needed
        and "rr_firewall_protocol_tuple_needed_after_updates" in needed
        and accounted_pre < accounted_writer < accounted_owned < accounted_post
        and 'return "$operation_status"' in accounted
        and "return 2" in accounted
        and abort_proxy < abort_firewall < abort_indeterminate
        < abort_fail_closed < abort_determinate
        and domain_http < domain_panel < domain_final
        and enable_domain.count("nexus_abort_public_activation") >= 9
        and ip_open < ip_rollback < ip_compensate < ip_fail_closed < ip_determinate
        and pending_file_sync < pending_publish < pending_dir_sync
        and cert_mark < cert_key_publish < cert_key_sync < cert_leaf_publish
        < cert_leaf_sync < cert_pair_proof < cert_clear
        and cert_gate_dropin >= 0
        and cert_gate_script_sync < cert_gate_dropin_sync
        < cert_gate_script_publish < cert_gate_script_dir_sync
        < cert_gate_dropin_publish < cert_gate_dropin_dir_sync
        < cert_gate_reload < cert_gate_effective
        and "zzzzzz-rr-nexus-ip-cert-gate.conf" in compiled_cert_gates
        and "zzzz-rr-restore-gate.conf" in compiled_cert_gates
        and "expect_restore=false" in compiled_cert_gates
        and "expect_restore=true" in compiled_cert_gates
        and 'expect_restore == "true"' in compiled_cert_gates
        and "records != expected" in compiled_cert_gates
        and 'name > nexus_name' in compiled_cert_gates
        and 'r"ExecCondition\\s*="' in compiled_cert_gates
        and "nexus_ip_certificate_gate_dropin_is_current" in remove_cert_gate
        and "nexus_nginx_exec_condition_set_is_exact" in remove_cert_gate
        and ip_gate_install < ip_pending_recovery < ip_publish < ip_pair_gate < ip_nginx_validate
        < ip_reload_gate < ip_reload < ip_failure < ip_rollback_mark
        < ip_rollback_remove < ip_rollback_restore < ip_rollback_pair
        < ip_rollback_clear
        and config_chmod < config_json < config_hash < config_file_sync
        < config_publish < config_dir_sync < config_reread < config_actual_hash
        and write_config_tmp < write_config_bytes < write_config_publish
        and '.nexus-endpoint.XXXXXX' in sync_config
        and 'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"'
        in sync_config
        and '.nexus-migrate.XXXXXX' in migrate_config
        and 'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"'
        in migrate_config
        and unit_render < unit_chmod < unit_hash < unit_file_sync < unit_publish
        < unit_dir_sync < unit_reload < unit_guards < unit_identity
        < unit_effective_guards
        and all(
            effective_identity.count(property_name) == 1
            for property_name in identity_properties
        )
        and identity_property_positions == tuple(sorted(identity_property_positions))
        and effective_identity.count("0:0:644:1") == 2
        and identity_rendered_unit < identity_guard_bytes < identity_restore_bytes
        < identity_firewall_bytes < identity_property_positions[0]
        and 'canonical=$(readlink -f -- "$NEXUS_SERVICE_FILE"' in effective_identity
        and '[ "$canonical" = "$NEXUS_SERVICE_FILE" ]' in effective_identity
        and 'for managed_file in "$guard_file" "$restore_dropin" "$firewall_dropin"; do'
        in effective_identity
        and effective_identity.count("cmp -s --") == 4
        and 'local -a expected_dropins=("$guard_file") effective_dropins=()'
        in effective_identity
        and 'expected_dropins+=("$restore_dropin")' in effective_identity
        and 'expected_dropins+=("$firewall_dropin")' in effective_identity
        and identity_property_positions[2] < identity_dropin_count
        < identity_dropin_order < identity_property_positions[3]
        and 'read -r -a effective_dropins <<< "$dropin_paths"'
        in effective_identity
        and identity_property_positions[3] < identity_exec_start_shape
        < identity_property_positions[4]
        and '!= ("/usr/bin/python3", f"/usr/bin/python3 {app}", "no")'
        in effective_identity
        and 'raw.count("path=") != 1' in effective_identity
        and 'raw.count("argv[]=") != 1' in effective_identity
        and 'raw.count("ignore_errors=") != 1' in effective_identity
        and identity_property_positions[4] < identity_property_positions[5]
        < identity_no_aux_exec < identity_property_positions[6]
        and '[ -z "${exec_reload//[[:space:]]/}" ]' in effective_identity
        and identity_property_positions[6] < identity_property_positions[7]
        < identity_property_positions[8] < identity_property_positions[9]
        < identity_property_positions[10] < identity_property_positions[11]
        < identity_property_positions[12] < identity_property_positions[13]
        < identity_property_positions[14] < identity_principal < identity_group
        < identity_property_positions[15]
        and '[ "$dynamic_user" = no ] && [ "$private_network" = no ]'
        in effective_identity
        and '[ -z "${root_directory//[[:space:]]/}" ]' in effective_identity
        and '[ -z "${root_image//[[:space:]]/}" ]' in effective_identity
        and '[ -z "${conditions//[[:space:]]/}" ]' in effective_identity
        and '[ -z "${asserts//[[:space:]]/}" ]' in effective_identity
        and identity_property_positions[15] < identity_restore_condition_record
        < identity_firewall_exists_record < identity_firewall_link_record
        < identity_exec_condition_records
        # The verifier mixes shell control flow with two embedded Python parsers.
        # Freeze its complete released implementation so dead-code wrapping,
        # observation laundering, or a swallowed final parser status cannot pass
        # merely by leaving the required tokens in place.
        and hashlib.sha256(effective_identity.encode()).hexdigest()
        == "7f5d448780f77a1d13c8b78269881dd31003436304833818206d2bb826984155"
        and 'raw.count("{") != len(expected)' in effective_identity
        and 'raw.count("}") != len(expected)' in effective_identity
        and 'raw.count("path=") != len(expected)' in effective_identity
        and 'raw.count("argv[]=") != len(expected)' in effective_identity
        and 'raw.count("ignore_errors=") != len(expected)' in effective_identity
        and restore_binary < restore_config < restore_restart < restore_runtime
        < restore_fail_closed
        and '"$context（回滚重启=${restart_status}，旧运行代无法精确证明）"'
        in restore_singbox
        and 'return $?' in restore_singbox
        and traffic_binary_snapshot < traffic_config_snapshot < traffic_candidate
        and traffic_engine.count("nexus_restore_singbox_transaction") >= 3
        and traffic_engine.count('return "$rollback_status"') >= 3
        and sync_snapshot < sync_candidate
        and sync_devices.count("nexus_restore_singbox_transaction") >= 3
        and sync_devices.count('return "$rollback_status"') >= 3
        and guard_write < guard_file_sync < guard_publish < guard_dir_sync
        < guard_reload < guard_proof
        and guard_interval < guard_burst < guard_restart
        and "RestartPreventExitStatus=" in service_guards
        and "RestartPreventExitStatus=3" in service_guards
        and "return 1" in service_guards
        and deactivate_config < deactivate_site < deactivate_proxy
        < deactivate_firewall < deactivate_fail_closed
        and "http://127.0.0.1:7900/healthz" in local_health
        and "--connect-timeout 1 --max-time 2" in local_health
        and 'while [ "$attempt" -lt 10 ]' in local_health
        and service_active < service_health < service_success
        and install_deactivate < install_config < install_admin < install_traffic
        < install_subscriptions < install_service < install_domain < install_ip
        < install_proxy_health < install_public_compensation < install_health_abort
        < install_success
        and "install_http_created install_panel_created" in install
        and '"$install_http_created" "$install_panel_created" "$port"' in install
        and install.count("nexus_abort_install_transaction") >= 9
        and uninstall_snapshot < uninstall_config < uninstall_site < uninstall_stop
        < uninstall_inactive < uninstall_proxy < uninstall_firewall
        < uninstall_cert_gate < uninstall_service < uninstall_config_dir
        < uninstall_success
        and uninstall.count("nexus_firewall_fail_closed") >= 5
    )


assert nexus_firewall_lifecycle_contract(nexus)
nexus_firewall_lifecycle_mutations = (
    mutate_function_slice(
        nexus,
        "nexus_firewall_tuple_needed_without_nexus() {",
        "\nnexus_firewall_open_accounted() {",
        '[ "${NAIVE_ENABLED:-false}" = true ]',
        "false",
    ),
    mutate_function_slice(
        nexus,
        "nexus_firewall_tuple_needed_without_nexus() {",
        "\nnexus_firewall_open_accounted() {",
        '[ "${SUB_ACCESS_MODE:-local}" = https ]',
        "false",
    ),
    mutate_function_slice(
        nexus,
        "nexus_firewall_open_accounted() {",
        "\nnexus_firewall_reconcile_without_nexus() {",
        'printf -v "$output_name" \'%s\' true',
        ": # removed per-run ownership",
    ),
    mutate_function_slice(
        nexus,
        "nexus_abort_public_activation() {",
        "\nnexus_enable_public_https() {",
        "nexus_firewall_fail_closed 'Nexus 公网入口失败且无法证明防火墙原态'",
        ": # removed durable fail-closed",
    ),
    mutate_function_slice(
        nexus,
        "nexus_enable_public_https() {",
        "\nnexus_remove_public_proxy() {",
        'nexus_firewall_open_accounted "$port" tcp panel_created',
        'open_protocol_firewall "$port" tcp',
    ),
    mutate_function_slice(
        nexus,
        "nexus_enable_public_ip_https() {",
        "\nnexus_firewall_tuple_array_add() {",
        "nexus_firewall_compensate_public_opens false \"$panel_created\"",
        "true # removed IP firewall compensation",
    ),
    mutate_function_slice(
        nexus,
        "nexus_publish_ip_certificate_pair() {",
        "\nnexus_enable_public_ip_https() {",
        'nexus_ip_certificate_mark_pending "$cert_dir" "$pending_file"',
        "true # removed durable pending marker",
    ),
    mutate_function_slice(
        nexus,
        "nexus_publish_ip_certificate_pair() {",
        "\nnexus_enable_public_ip_https() {",
        'mv -f -- "$key_tmp" "$key_file"',
        "true # removed key publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_publish_ip_certificate_pair() {",
        "\nnexus_enable_public_ip_https() {",
        'nexus_ip_certificate_clear_pending "$cert_dir" "$pending_file"',
        "true # removed post-match marker clear",
    ),
    mutate_function_slice(
        nexus,
        "nexus_emit_ip_certificate_gate_dropin() {",
        "\nnexus_ip_certificate_gate_script_is_current() {",
        "ExecCondition=%s",
        "RemovedCondition=%s",
    ),
    mutate_function_slice(
        nexus,
        "nexus_install_ip_certificate_gate() {",
        "\nnexus_ip_certificate_gate_allows() {",
        'sync -f "$dropin_dir"',
        "true # removed durable certificate gate directory sync",
    ),
    mutate_function_slice(
        nexus,
        "nexus_nginx_exec_condition_set_is_exact() {",
        "\nnexus_install_ip_certificate_gate() {",
        "records != expected",
        "False",
    ),
    mutate_function_slice(
        nexus,
        "nexus_nginx_exec_condition_set_is_exact() {",
        "\nnexus_install_ip_certificate_gate() {",
        "expect_restore=true",
        "true # removed optional restore gate accounting",
    ),
    mutate_function_slice(
        nexus,
        "nexus_uninstall() {",
        "\nnexus_menu() {",
        "nexus_remove_ip_certificate_gate",
        "true # removed exact cert gate cleanup",
    ),
    mutate_function_slice(
        nexus,
        "nexus_enable_public_ip_https() {",
        "\nnexus_firewall_tuple_array_add() {",
        "nexus_ip_certificate_restored_state_is_safe",
        "removed_restored_pair_proof",
    ),
    mutate_function_slice(
        nexus,
        "ensure_nexus_service_guards() {",
        "\nnexus_prompt_admin() {",
        'mv -f -- "$guard_tmp" "$guard_file"',
        "true # removed atomic guard publication",
    ),
    mutate_function_slice(
        nexus,
        "ensure_nexus_service_guards() {",
        "\nnexus_prompt_admin() {",
        "systemctl daemon-reload",
        "true # removed guard daemon reload",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_guards_are_exact() {",
        "\nnexus_service_effective_identity_is_exact() {",
        "--property=RestartPreventExitStatus --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "0:0:644:1",
        "0:0:600:1",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'cmp -s -- "$NEXUS_SERVICE_FILE" <(nexus_emit_service_unit)',
        "true # removed exact rendered unit proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'cmp -s -- "$guard_file"',
        "true # removed exact guard bytes proof #",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'cmp -s -- "$restore_dropin"',
        "true # removed exact restore gate bytes proof #",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'cmp -s -- "$firewall_dropin"',
        "true # removed exact firewall gate bytes proof #",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "--property=DropInPaths --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ "${#effective_dropins[@]}" -eq "${#expected_dropins[@]}" ]',
        "true # removed exact effective drop-in count",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ "${effective_dropins[i]}" = "${expected_dropins[i]}" ]',
        "true # removed exact effective drop-in order",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '!= ("/usr/bin/python3", f"/usr/bin/python3 {app}", "no")',
        '!= ("/usr/bin/python3", f"/usr/bin/python3 {app}", "yes")',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'raw.count("ignore_errors=") != 1',
        'raw.count("ignore_errors=") != 2',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "--property=ExecStartPre --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "--property=ExecReload --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "--property=User --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "--property=WorkingDirectory --value",
        "--property=Unrelated --value",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ "$dynamic_user" = no ] && [ "$private_network" = no ]',
        '[ "$dynamic_user" = yes ] && [ "$private_network" = no ]',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ -z "${root_directory//[[:space:]]/}" ]',
        "true # removed empty RootDirectory proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ -z "${conditions//[[:space:]]/}" ]',
        "true # removed empty Conditions proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'case "${group//[[:space:]]/}" in ""|root)',
        'case "${group//[[:space:]]/}" in root)',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'expected.append(("/bin/sh", restore_argv, "no"))',
        'expected.append(("/bin/sh", restore_argv, "yes"))',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '            ("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no"),\n'
        '            ("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no"),',
        '            ("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no"),\n'
        '            ("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no"),',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "records != expected",
        "False",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '    local load_state="" fragment="" exec_start="" exec_start_pre=""',
        '    return 0 # token-preserving early success bypass\n'
        '    local load_state="" fragment="" exec_start="" exec_start_pre=""',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'cmp -s -- "$NEXUS_SERVICE_FILE" <(nexus_emit_service_unit) || return 1',
        'cmp -s -- "$NEXUS_SERVICE_FILE" <(nexus_emit_service_unit) || true',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'fragment=$(systemctl show rr-nexus.service --property=FragmentPath --value \\\n'
        '        2>/dev/null) || return 1',
        'fragment=$(systemctl show rr-nexus.service --property=FragmentPath --value \\\n'
        '        2>/dev/null) || return 1\n'
        '    fragment="$NEXUS_SERVICE_FILE" # laundered observation',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        'read -r -a effective_dropins <<< "$dropin_paths"',
        'read -r -a effective_dropins <<< "$dropin_paths"\n'
        '    effective_dropins=("${expected_dropins[@]}") # laundered observation',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "if (\n    (fields.get(\"path\")",
        "if False and (\n    (fields.get(\"path\")",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ -z "${exec_start_pre//[[:space:]]/}" ] && \\\n'
        '        [ -z "${exec_reload//[[:space:]]/}" ]',
        '[ -z "${exec_start_pre//[[:space:]]/}" ] || \\\n'
        '        [ -z "${exec_reload//[[:space:]]/}" ]',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        '[ "$user" = root ] && [ "$working_directory" = "${RR_LIB_DIR}/nexus" ]',
        '[ "$user" = root ] || [ "$working_directory" = "${RR_LIB_DIR}/nexus" ]',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "records != expected",
        "False and records != expected",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "systemctl show rr-nexus.service --property=LoadState",
        "systemctl show unrelated.service --property=LoadState # rr-nexus.service",
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        ';; *) return 1 ;; esac',
        ';; *) : ;; esac',
    ),
    mutate_function_slice(
        nexus,
        "nexus_service_effective_identity_is_exact() {",
        "\nnexus_write_service() {",
        "PY\n}",
        "PY\ntrue # swallowed final ExecCondition parser status\n}",
    ),
    mutate_function_slice(
        nexus,
        "nexus_publish_config_candidate() {",
        "\nnexus_write_config() {",
        'mv -f -- "$candidate" "$target"',
        "true # removed atomic config publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_write_config() {",
        "\nnexus_sync_subscription_endpoint() {",
        'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"',
        "true # removed checked initial config publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_sync_subscription_endpoint() {",
        "\nnexus_set_certificate_mode() {",
        'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"',
        "true # removed checked endpoint publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_migrate_runtime_config() {",
        "\nnexus_emit_service_unit() {",
        'nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"',
        "true # removed checked migration publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_write_service() {",
        "\n# T4：为旧版已安装的 rr-nexus 单元幂等补齐",
        'mv -f -- "$tmp" "$NEXUS_SERVICE_FILE"',
        "true # removed atomic service publication",
    ),
    mutate_function_slice(
        nexus,
        "nexus_write_service() {",
        "\n# T4：为旧版已安装的 rr-nexus 单元幂等补齐",
        "nexus_service_effective_identity_is_exact",
        "true # removed effective service identity proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_restore_singbox_transaction() {",
        "\nnexus_enable_traffic_engine() {",
        "nexus_singbox_runtime_matches_restored_files",
        "true # removed restored runtime generation proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_restore_singbox_transaction() {",
        "\nnexus_enable_traffic_engine() {",
        "nexus_firewall_fail_closed \\\n"
        '            "$context（回滚重启=${restart_status}，旧运行代无法精确证明）"',
        "return 1 # removed durable rollback isolation",
    ),
    mutate_function_slice(
        nexus,
        "nexus_enable_traffic_engine() {",
        "\nnexus_protocol_users() {",
        "nexus_restore_singbox_transaction",
        "true # removed traffic-engine rollback proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_enable_traffic_engine() {",
        "\nnexus_protocol_users() {",
        'return "$rollback_status"',
        "return 1 # collapsed indeterminate traffic rollback status",
    ),
    mutate_function_slice(
        nexus,
        "_sync_nexus_devices_locked() {",
        "\nNEXUS_GRPCIO_MIN_VERSION=",
        "nexus_restore_singbox_transaction",
        "true # removed device-sync rollback proof",
    ),
    mutate_function_slice(
        nexus,
        "_sync_nexus_devices_locked() {",
        "\nNEXUS_GRPCIO_MIN_VERSION=",
        'return "$rollback_status"',
        "return 1 # collapsed indeterminate device-sync rollback status",
    ),
    mutate_function_slice(
        nexus,
        "nexus_deactivate_public_access() {",
        "\nnexus_reconcile_public_proxy() {",
        "nexus_reconcile_firewall_tuple_list retired_tuples",
        "true # removed retired firewall reconcile",
    ),
    mutate_function_slice(
        nexus,
        "nexus_install() {",
        "\nnexus_reset_admin() {",
        'nexus_start_service "$port"',
        "removed_backend_readiness",
    ),
    mutate_function_slice(
        nexus,
        "nexus_start_service() {",
        "\nnexus_abort_install_transaction() {",
        "nexus_local_backend_health_check",
        "true # removed application health proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_install() {",
        "\nnexus_reset_admin() {",
        "nexus_public_proxy_health_check",
        "true # removed local TLS proxy proof",
    ),
    mutate_function_slice(
        nexus,
        "nexus_uninstall() {",
        "\nnexus_menu() {",
        "nexus_reconcile_firewall_tuple_list retired_tuples",
        "true # removed uninstall firewall reconcile",
    ),
)
for mutation_index, mutated in enumerate(nexus_firewall_lifecycle_mutations):
    assert mutated != nexus
    assert not nexus_firewall_lifecycle_contract(mutated), (
        f"nexus firewall lifecycle mutation {mutation_index} survived"
    )


def singbox_effective_identity_contract(candidate):
    try:
        _, _, renderer = function_slice(
            candidate, "rr_render_singbox_systemd_unit() {",
            "\nrr_render_singbox_systemd_unit_legacy_710() {",
        )
        _, _, writer = function_slice(
            candidate, "write_singbox_systemd_unit() {",
            "\nrr_singbox_service_guards_are_effective() {",
        )
        _, _, proof = function_slice(
            candidate, "rr_singbox_service_guards_are_effective() {",
            "\nrr_singbox_effective_control_hooks_are_empty() {",
        )
        _, _, ensure = function_slice(
            candidate, "ensure_singbox_service_guards() {",
            "\nstop_singbox_instances() {",
        )
        ensure_write = ensure.index("write_singbox_systemd_unit || return 1")
        ensure_reload = ensure.index("systemctl daemon-reload", ensure_write)
        ensure_proof = ensure.index(
            "rr_singbox_service_guards_are_effective", ensure_reload
        )
    except ValueError:
        return False
    return (
        all(token in renderer for token in (
            "User=root", "WorkingDirectory=/etc/sing-box",
            "ExecStartPre=/usr/local/bin/rr --singbox-certificate-gate",
            "ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json",
            "ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json",
            "ExecReload=/bin/kill -HUP $MAINPID", "RestartPreventExitStatus=78",
        ))
        and all(token in writer for token in (
            "rr_render_singbox_systemd_unit", 'chown 0:0 "$unit_tmp"',
            'chmod 644 "$unit_tmp"',
            'sync -f "$unit_tmp"', 'sync -f "$unit_dir"',
            'cmp -s -- "$service_file" <(rr_render_singbox_systemd_unit)',
        ))
        and all(token in proof for token in (
            '--property=FragmentPath --value',
            '--property=ExecStartPre --value',
            'fields.get("ignore_errors")',
            '"/usr/local/bin/rr --singbox-certificate-gate", "no"',
            '--property=ExecStart --value', '--property=ExecReload --value',
            '"/usr/local/bin/sing-box run -c /etc/sing-box/config.json"',
            '"/bin/kill -HUP $MAINPID"',
            '--property=User --value', '--property=WorkingDirectory --value',
            '--property=DynamicUser --value', '--property=PrivateNetwork --value',
            '--property=RootDirectory --value', '--property=RootImage --value',
            '--property=Conditions --value', '--property=Asserts --value',
            '--property=DropInPaths --value', '--property=ExecCondition --value',
            'paths not in ([], [restore], [firewall], [restore, firewall])',
            'ExecCondition=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine',
            'if restore_present == "true":', 'if firewall_present == "true":',
            'records != expected', 'fields.get("ignore_errors")',
        ))
        and proof.count('fields.get("ignore_errors")') >= 3
        and proof.count("records != expected") == 2
        and all(
            proof.count(property_name) == 1
            for property_name in (
                '--property=FragmentPath --value',
                '--property=ExecStartPre --value',
                '--property=ExecStart --value',
                '--property=ExecReload --value',
                '--property=User --value',
                '--property=WorkingDirectory --value',
                '--property=DynamicUser --value',
                '--property=PrivateNetwork --value',
                '--property=RootDirectory --value',
                '--property=RootImage --value',
                '--property=Conditions --value',
                '--property=Asserts --value',
                '--property=DropInPaths --value',
                '--property=ExecCondition --value',
            )
        )
        and ensure_write < ensure_reload < ensure_proof
    )


assert singbox_effective_identity_contract(singbox)
singbox_identity_mutations = (
    singbox.replace(
        "ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json",
        "ExecStart=/bin/true", 1,
    ),
    singbox.replace("User=root", "User=nobody", 1),
    singbox.replace("WorkingDirectory=/etc/sing-box", "WorkingDirectory=/tmp", 1),
    mutate_function_slice(
        singbox, "rr_singbox_service_guards_are_effective() {",
        "\nrr_singbox_effective_control_hooks_are_empty() {",
        'fields.get("ignore_errors")', '"no"',
    ),
    mutate_function_slice(
        singbox, "rr_singbox_service_guards_are_effective() {",
        "\nrr_singbox_effective_control_hooks_are_empty() {",
        '--property=ExecStart --value',
        '--property=Description --value',
    ),
    mutate_function_slice(
        singbox, "rr_singbox_service_guards_are_effective() {",
        "\nrr_singbox_effective_control_hooks_are_empty() {",
        '--property=DropInPaths --value',
        '--property=Names --value',
    ),
    mutate_function_slice(
        singbox, "rr_singbox_service_guards_are_effective() {",
        "\nrr_singbox_effective_control_hooks_are_empty() {",
        'paths not in ([], [restore], [firewall], [restore, firewall])',
        'False',
    ),
    mutate_function_slice(
        singbox, "rr_singbox_service_guards_are_effective() {",
        "\nrr_singbox_effective_control_hooks_are_empty() {",
        'records != expected', 'False', last=True,
    ),
    mutate_function_slice(
        singbox, "ensure_singbox_service_guards() {",
        "\nstop_singbox_instances() {",
        "rr_singbox_service_guards_are_effective", "true # removed effective proof",
    ),
)
for mutation_index, mutated in enumerate(singbox_identity_mutations):
    assert mutated != singbox
    assert not singbox_effective_identity_contract(mutated), (
        f"sing-box effective identity mutation {mutation_index} survived"
    )


def certificate_hook_contract(candidate):
    try:
        _, _, nexus_reload = function_slice(
            candidate,
            "reload_nexus_certificate() {",
            "\n# One renewed lineage can serve several RR consumers.",
        )
        tail_start = candidate.index("hook_failed=0")
        tail = candidate[tail_start:]
        pair = nexus_reload.index(
            'certificate_pair_valid "$RENEWED_LINEAGE/fullchain.pem"'
        )
        nexus_domain = nexus_reload.index(
            '"$RENEWED_LINEAGE/privkey.pem" "$NEXUS_DOMAIN"', pair
        )
        nginx_check = nexus_reload.index(
            '"$NGINX_BIN" -t >/dev/null 2>&1 || return 1', nexus_domain
        )
        reload_nginx = nexus_reload.index(
            '"$SYSTEMCTL_BIN" reload nginx >/dev/null 2>&1', nginx_check
        )

        naive_if = tail.index('if lineage_matches_domain "$NAIVE_DOMAIN"; then')
        naive_call = tail.index(
            "deploy_naive_certificate || hook_failed=1", naive_if
        )
        subscription_if = tail.index(
            'if [ "$SUB_ACCESS_MODE" = https ] && '
            'lineage_matches_domain "$SUB_DOMAIN"; then',
            naive_call,
        )
        subscription_call = tail.index(
            "refresh_subscription_certificate || hook_failed=1",
            subscription_if,
        )
        nexus_if = tail.index(
            'if lineage_matches_domain "$NEXUS_DOMAIN"; then',
            subscription_call,
        )
        nexus_call = tail.index(
            "reload_nexus_certificate || hook_failed=1", nexus_if
        )
        aggregate_exit = tail.index('exit "$hook_failed"', nexus_call)
    except ValueError:
        return False
    return (
        pair < nexus_domain < nginx_check < reload_nginx
        and nexus_reload.count('"$SYSTEMCTL_BIN" reload nginx') == 1
        and "restart nginx" not in nexus_reload
        and "try-restart nginx" not in nexus_reload
        and naive_if < naive_call < subscription_if < subscription_call
        < nexus_if < nexus_call < aggregate_exit
        and tail.count("|| hook_failed=1") == 3
        and tail.count("elif ") == 0
        and tail.count("exit ") == 1
    )


def certificate_hook_lock_contract(candidate):
    try:
        locked_start = candidate.index("rr_certificate_hook_locked() {")
        locked_end = candidate.index(
            "\n}\n\nRR_CERT_HOOK_LOCK_MODULE=", locked_start
        )
        locked = candidate[locked_start:locked_end]
        wrapper = candidate[locked_end:]
        naive = locked.index('if lineage_matches_domain "$NAIVE_DOMAIN"; then')
        naive_call = locked.index("deploy_naive_certificate || hook_failed=1", naive)
        subscription = locked.index(
            'if [ "$SUB_ACCESS_MODE" = https ]', naive_call
        )
        subscription_call = locked.index(
            "refresh_subscription_certificate || hook_failed=1", subscription
        )
        nexus = locked.index(
            'if lineage_matches_domain "$NEXUS_DOMAIN"; then', subscription_call
        )
        nexus_call = locked.index(
            "reload_nexus_certificate || hook_failed=1", nexus
        )
    except ValueError:
        return False
    return (
        naive < naive_call < subscription < subscription_call < nexus < nexus_call
        and locked.count("|| hook_failed=1") == 3
        and locked.count('kill -KILL "${BASHPID:-$$}"') == 2
        and all(token in wrapper for token in (
            'RR_CERT_HOOK_LOCK_MODULE="${RR_CERT_HOOK_LOCK_MODULE:-/usr/local/lib/rr/modules/55-resilience.sh}"',
            '[ -f "$RR_CERT_HOOK_LOCK_MODULE" ] && [ ! -L "$RR_CERT_HOOK_LOCK_MODULE" ]',
            'source "$RR_CERT_HOOK_LOCK_MODULE" || exit 1',
            'declare -F rr_run_with_update_locks',
            'rr_run_with_update_locks isolated 0 rr_certificate_hook_locked',
            '75|76) exit 1 ;;',
        ))
        and "deploy_naive_certificate" not in wrapper
        and "refresh_subscription_certificate" not in wrapper
        and "reload_nexus_certificate" not in wrapper
    )


assert certificate_hook_lock_contract(certificate_hook)
certificate_hook_mutations_legacy = r'''
    mutate_function_slice(
        certificate_hook,
        "reload_nexus_certificate() {",
        "\n# One renewed lineage can serve several RR consumers.",
        '"$SYSTEMCTL_BIN" reload nginx >/dev/null 2>&1',
        ": # removed exact Nexus reload",
    ),
    certificate_hook.replace(
        'if lineage_matches_domain "$NEXUS_DOMAIN"; then',
        'elif lineage_matches_domain "$NEXUS_DOMAIN"; then',
        1,
    ),
    certificate_hook.replace(
        "deploy_naive_certificate || hook_failed=1",
        "deploy_naive_certificate || exit 1",
        1,
    ),
    certificate_hook.replace(
        "reload_nexus_certificate || hook_failed=1",
        "reload_nexus_certificate || true",
        1,
    ),
    certificate_hook.replace('exit "$hook_failed"', "exit 0", 1),
)
'''
certificate_hook_mutations = (
    certificate_hook.replace(
        "rr_run_with_update_locks isolated 0 rr_certificate_hook_locked",
        "rr_certificate_hook_locked", 1,
    ),
    certificate_hook.replace(
        '75|76) exit 1 ;;', '75|76) exit 0 ;;', 1,
    ),
    certificate_hook.replace(
        '[ -f "$RR_CERT_HOOK_LOCK_MODULE" ] && [ ! -L "$RR_CERT_HOOK_LOCK_MODULE" ]',
        '[ -e "$RR_CERT_HOOK_LOCK_MODULE" ]', 1,
    ),
    certificate_hook.replace(
        'source "$RR_CERT_HOOK_LOCK_MODULE" || exit 1', ': # removed lock helper', 1,
    ),
    certificate_hook.replace(
        "deploy_naive_certificate || hook_failed=1",
        "deploy_naive_certificate || true", 1,
    ),
    certificate_hook.replace(
        "refresh_subscription_certificate || hook_failed=1",
        "refresh_subscription_certificate || true", 1,
    ),
    certificate_hook.replace(
        "reload_nexus_certificate || hook_failed=1",
        "reload_nexus_certificate || true", 1,
    ),
    certificate_hook.replace(
        'kill -KILL "${BASHPID:-$$}"', 'kill -KILL "$$"', 1,
    ),
)
for mutated in certificate_hook_mutations:
    assert mutated != certificate_hook
    assert not certificate_hook_lock_contract(mutated)


ready_nginx_isolation_contract_legacy = r'''
def ready_nginx_isolation_contract(candidate):
    try:
        _, _, cloud_claim = function_slice(
            candidate,
            "rr_restore_rollback_claims_cloudflared() {",
            "\nrr_restore_stop_managed_runtime() {",
        )
        _, _, stop = function_slice(
            candidate,
            "rr_restore_stop_managed_runtime() {",
            "\nrr_restore_freeze_writers() {",
        )
        _, _, resume_snapshot = function_slice(
            candidate,
            "rr_restore_resume_snapshot_writers() {",
            "\nrr_restore_resume_frozen_writers() {",
        )
        _, _, resume = function_slice(
            candidate,
            "rr_restore_resume_frozen_writers() {",
            "\nrr_restore_remove_managed_fixed_tunnel() {",
        )
        _, _, abort = function_slice(
            candidate,
            "rr_restore_abort_pre_mutation_stage() {",
            "\nrr_restore_rollback_stage() {",
        )
        _, _, rollback_candidate = function_slice(
            candidate,
            "rr_restore_rollback_stage() {",
            "\nrr_restore_recover_active() {",
        )
        _, _, restore_candidate = function_slice(
            candidate,
            "rr_restore_backup_locked() {",
            None,
        )

        claim_stage = cloud_claim.index(
            'rr_restore_stage_is_safe "$stage" || return 2'
        )
        claim_rollback = cloud_claim.index(
            '[ -d "$rollback" ] && [ ! -L "$rollback" ] || return 2',
            claim_stage,
        )
        claim_canonical = cloud_claim.index(
            '[ "$canonical" = "$rollback" ] || return 2', claim_rollback
        )
        claim_owner = cloud_claim.index(
            '[ "$(stat -c \'%u:%g\' "$rollback" 2>/dev/null)" = 0:0 ] || return 2',
            claim_canonical,
        )
        claim_rollback_mode = cloud_claim.index(
            '[ $((8#$mode & 8#7022)) -eq 0 ] || return 2', claim_owner
        )
        claim_absent = cloud_claim.index(
            'if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then',
            claim_rollback_mode,
        )
        claim_absent_result = cloud_claim.index("return 1", claim_absent)
        claim_marker = cloud_claim.index(
            '[ -f "$marker" ] && [ ! -L "$marker" ] || return 2',
            claim_absent_result,
        )
        claim_marker_meta = cloud_claim.index(
            "stat -c '%u:%g:%h:%s:%a' \"$marker\"", claim_marker
        )
        claim_marker_exact = cloud_claim.index(
            "0:0:1:0:*) ;; *) return 2 ;; esac", claim_marker_meta
        )
        claim_service = cloud_claim.index(
            '[ -f "$service" ] && [ ! -L "$service" ] || return 2',
            claim_marker_exact,
        )
        claim_service_meta = cloud_claim.index(
            "stat -c '%u:%g:%h:%s:%a' \"$service\"", claim_service
        )
        claim_service_owner = cloud_claim.index(
            '[ "$owner:$group:$links" = 0:0:1 ] || return 2',
            claim_service_meta,
        )
        claim_service_size = cloud_claim.index(
            '[ "$size" -le 1048576 ] || return 2', claim_service_owner
        )
        claim_service_mode = cloud_claim.index(
            '[ $((8#$mode & 8#7022)) -eq 0 ] || return 2',
            claim_service_size,
        )
        claim_success = cloud_claim.index("return 0", claim_service_mode)

        stop_claim = stop.index(
            'if rr_restore_rollback_claims_cloudflared "$rollback"; then'
        )
        stop_claim_status = stop.index("claim_result=$?", stop_claim)
        stop_claim_case = stop.index('0) cloudflared_owned=true ;;', stop_claim_status)
        stop_malformed = stop.index('2|*) failed=true ;;', stop_claim_case)
        stop_live_claim = stop.index(
            '[ "${TUNNEL_MODE:-1}" = 2 ] && '
            '[ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]',
            stop_malformed,
        )
        stop_cloudflared = stop.index(
            "systemctl stop cloudflared >/dev/null 2>&1 || true",
            stop_live_claim,
        )
        stop_cloudflared_proof = stop.index(
            "rr_restore_unit_activity_matches cloudflared inactive || failed=true",
            stop_cloudflared,
        )

        stop_cmd = stop.index(
            "systemctl stop rr-nexus sing-box nginx >/dev/null 2>&1 || true"
        )
        stop_proof = stop.index(
            "rr_restore_unit_activity_matches nginx inactive || failed=true",
            stop_cmd,
        )

        snapshot_nexus_start = resume_snapshot.index("systemctl start rr-nexus")
        snapshot_nexus_active = resume_snapshot.index(
            "rr_restore_unit_activity_matches rr-nexus active", snapshot_nexus_start
        )
        snapshot_nexus_stop = resume_snapshot.index(
            "systemctl stop rr-nexus", snapshot_nexus_active
        )
        snapshot_nexus_inactive = resume_snapshot.index(
            "rr_restore_unit_activity_matches rr-nexus inactive", snapshot_nexus_stop
        )
        snapshot_health_stop = resume_snapshot.index(
            "systemctl stop argo-rr-health.service", snapshot_nexus_inactive
        )
        snapshot_health_inactive = resume_snapshot.index(
            "rr_restore_unit_activity_matches argo-rr-health.service inactive",
            snapshot_health_stop,
        )
        snapshot_timer_start = resume_snapshot.index(
            "systemctl start argo-rr-health.timer", snapshot_health_inactive
        )
        snapshot_timer_active = resume_snapshot.index(
            "rr_restore_unit_activity_matches argo-rr-health.timer active",
            snapshot_timer_start,
        )
        snapshot_timer_stop = resume_snapshot.index(
            "systemctl stop argo-rr-health.timer", snapshot_timer_active
        )
        snapshot_timer_inactive = resume_snapshot.index(
            "rr_restore_unit_activity_matches argo-rr-health.timer inactive",
            snapshot_timer_stop,
        )

        resume_load = resume.index(
            "load_config_with_defaults >/dev/null 2>&1 || return 1"
        )
        resume_select = resume.index(
            "select_entry_ip >/dev/null 2>&1 || return 1", resume_load
        )
        resume_claim = resume.index(
            'if rr_restore_rollback_claims_cloudflared "$rollback"; then',
            resume_select,
        )
        resume_claim_status = resume.index("claim_result=$?", resume_claim)
        resume_claim_case = resume.index(
            '0) cloudflared_owned=true ;;', resume_claim_status
        )
        resume_malformed = resume.index(
            '2|*) return 1 ;;', resume_claim_case
        )
        resume_live_config = resume.index(
            'if [ "${TUNNEL_MODE:-1}" = 2 ]', resume_malformed
        )
        resume_live_claim = resume.index(
            '[ "${TUNNEL_MODE:-1}" = 2 ] && \\\n'
            '       [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]',
            resume_live_config,
        )
        resume_argo = resume.index(
            'if [ -f "$rollback/argo_was_running" ]; then', resume_live_claim
        )
        resume_start_guard = resume.index(
            '[ "${TUNNEL_MODE:-1}" = 2 ] && \\\n'
            '           [ "$cloudflared_owned" != true ]; then',
            resume_argo,
        )
        resume_start = resume.index("start_argo_tunnel", resume_start_guard)
        resume_expected = resume.index(
            "expected_argo_tunnel_running", resume_start
        )
        resume_active_proof = resume.index(
            "rr_restore_unit_activity_matches cloudflared active || failed=true",
            resume_expected,
        )
        resume_stop_quick = resume.index(
            "stop_quick_argo_tunnel", resume_active_proof
        )
        resume_stop_guard = resume.index(
            'if [ "$cloudflared_owned" = true ]; then', resume_stop_quick
        )
        resume_cloud_stop = resume.index(
            "systemctl stop cloudflared >/dev/null 2>&1 || true",
            resume_stop_guard,
        )
        resume_inactive_proof = resume.index(
            "rr_restore_unit_activity_matches cloudflared inactive || failed=true",
            resume_cloud_stop,
        )

        abort_ready = abort.index(
            'rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage"'
        )
        abort_resume = abort.index(
            'rr_restore_resume_snapshot_writers "$rollback"', abort_ready
        )
        abort_resume_clear = abort.index(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
            abort_resume,
        )
        abort_resume_isolate = abort.index(
            'rr_restore_freeze_writers >/dev/null 2>&1 || true',
            abort_resume_clear,
        )
        abort_failed = abort.index(
            'rr_restore_write_phase "$stage" pre_recovery_failed',
            abort_resume_isolate,
        )
        abort_terminal = abort.index(
            'if ! rr_restore_publish_terminal_phase "$stage" aborted; then',
            abort_failed,
        )
        abort_terminal_clear = abort.index(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
            abort_terminal,
        )
        abort_terminal_isolate = abort.index(
            'rr_restore_freeze_writers >/dev/null 2>&1 || true',
            abort_terminal_clear,
        )

        rollback_clear = rollback_candidate.index(
            'if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then'
        )
        rollback_clear_isolate = rollback_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
            rollback_clear,
        )
        rollback_phase = rollback_candidate.index(
            'rr_restore_write_phase "$stage" rolling_back',
            rollback_clear_isolate,
        )
        rollback_phase_isolate = rollback_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
            rollback_phase,
        )
        rollback_phase_return = rollback_candidate.index(
            "return 1", rollback_phase_isolate
        )
        rollback_main_isolate = rollback_candidate.index(
            'if ! rr_restore_stop_managed_runtime "$rollback"; then',
            rollback_phase_return,
        )
        rollback_ready = rollback_candidate.index(
            'rr_restore_publish_marker "$RR_RESTORE_RUNTIME_READY" "$stage"',
            rollback_main_isolate,
        )
        rollback_nginx = rollback_candidate.index(
            'rr_restore_restore_nginx "$rollback" activate', rollback_ready
        )
        rollback_migrate = rollback_candidate.index(
            'rr_restore_migrate_with_original_state "$rollback"', rollback_nginx
        )
        rollback_firewall = rollback_candidate.index(
            'rr_restore_verify_firewall_snapshot "$rollback"', rollback_migrate
        )
        rollback_cloud_guard = rollback_candidate.index(
            'if [ "$failed" = false ] && \\\n'
            '       rr_restore_rollback_claims_cloudflared "$rollback"; then',
            rollback_firewall,
        )
        rollback_cloud_start = rollback_candidate.index(
            "systemctl start cloudflared >/dev/null 2>&1 || failed=true",
            rollback_cloud_guard,
        )
        rollback_late = rollback_candidate.index(
            'if [ "$failed" = true ]; then', rollback_cloud_start
        )
        rollback_late_clear = rollback_candidate.index(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
            rollback_late,
        )
        rollback_late_isolate = rollback_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
            rollback_late_clear,
        )
        rollback_failed = rollback_candidate.index(
            'rr_restore_write_phase "$stage" recovery_failed',
            rollback_late_isolate,
        )
        rollback_terminal = rollback_candidate.index(
            'if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then',
            rollback_failed,
        )
        rollback_terminal_clear = rollback_candidate.index(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
            rollback_terminal,
        )
        rollback_terminal_isolate = rollback_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
            rollback_terminal_clear,
        )
        main_stop = restore_candidate.index(
            'rr_restore_stop_managed_runtime "$rollback" || result=1'
        )
        main_mutating = restore_candidate.index(
            'rr_restore_write_phase "$stage" mutating', main_stop
        )
    except ValueError:
        return False

    resume_snapshot_commands = "\n".join(
        line.strip()
        for line in resume_snapshot.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )
    return (
        claim_stage < claim_rollback < claim_canonical < claim_owner
        < claim_rollback_mode < claim_absent < claim_absent_result
        < claim_marker < claim_marker_meta < claim_marker_exact
        < claim_service < claim_service_meta < claim_service_owner
        < claim_service_size < claim_service_mode < claim_success
        and cloud_claim.count("rr_restore_stage_is_safe") == 1
        and cloud_claim.count("return 1") == 1
        and cloud_claim.count("return 0") == 1
        and 'local rollback="$1"' in cloud_claim
        and stop_claim < stop_claim_status < stop_claim_case < stop_malformed
        < stop_live_claim < stop_cloudflared < stop_cloudflared_proof
        and 'local rollback="${1:-}"' in stop
        and stop.count("rr_restore_rollback_claims_cloudflared") == 1
        and stop.count('if [ "$cloudflared_owned" = true ]; then') == 2
        and stop.count("systemctl stop cloudflared") == 1
        and stop.count(
            "rr_restore_unit_activity_matches cloudflared inactive"
        ) == 1
        and stop_cmd < stop_proof
        and "command -v nginx" not in stop
        and stop.count("rr_restore_unit_activity_matches nginx inactive") == 1
        and snapshot_nexus_start < snapshot_nexus_active
        < snapshot_nexus_stop < snapshot_nexus_inactive
        < snapshot_health_stop < snapshot_health_inactive
        < snapshot_timer_start < snapshot_timer_active
        < snapshot_timer_stop < snapshot_timer_inactive
        and not any(token in resume_snapshot_commands for token in (
            "sing-box", "subscription", "nginx", "cloudflared",
            "start_argo_tunnel", "stop_quick_argo_tunnel",
            "load_config_with_defaults", "select_entry_ip",
        ))
        and resume_load < resume_select < resume_claim
        < resume_claim_status < resume_claim_case
        < resume_malformed < resume_live_config < resume_live_claim < resume_argo
        < resume_start_guard < resume_start < resume_expected
        < resume_active_proof < resume_stop_quick < resume_stop_guard
        < resume_cloud_stop < resume_inactive_proof
        and 'local rollback="$1" failed=false cloudflared_owned=false claim_result=1'
        in resume
        and "local config_loaded=false" not in resume
        and resume.count("rr_restore_rollback_claims_cloudflared") == 1
        and resume.count('if [ "$cloudflared_owned" = true ]; then') == 1
        and resume.count('[ "$cloudflared_owned" != true ]; then') == 1
        and resume.count("start_argo_tunnel") == 1
        and resume.count("systemctl stop cloudflared") == 1
        and resume.count(
            "rr_restore_unit_activity_matches cloudflared active"
        ) == 1
        and resume.count(
            "rr_restore_unit_activity_matches cloudflared inactive"
        ) == 1
        and abort_ready < abort_resume
        < abort_resume_clear < abort_resume_isolate < abort_failed
        < abort_terminal < abort_terminal_clear < abort_terminal_isolate
        and abort.count(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true'
        ) == 2
        and abort.count('rr_restore_freeze_writers >/dev/null 2>&1 || true') == 2
        and "rr_restore_resume_frozen_writers" not in abort
        and "rr_restore_activate_nginx_state" not in abort
        and "rr_restore_stop_managed_runtime" not in abort
        and rollback_clear < rollback_clear_isolate < rollback_phase
        < rollback_phase_isolate < rollback_phase_return
        < rollback_main_isolate < rollback_ready < rollback_nginx
        < rollback_migrate < rollback_firewall < rollback_cloud_guard
        < rollback_cloud_start < rollback_late
        < rollback_late_clear < rollback_late_isolate < rollback_failed
        < rollback_terminal < rollback_terminal_clear < rollback_terminal_isolate
        and rollback_candidate.count(
            'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"'
        ) == 3
        and rollback_candidate.count("rr_restore_stop_managed_runtime") == 5
        and rollback_candidate.count(
            'rr_restore_stop_managed_runtime "$rollback"'
        ) == 5
        and rollback_candidate.count("systemctl start cloudflared") == 1
        and main_stop < main_mutating
        and restore_candidate.count(
            'rr_restore_stop_managed_runtime "$rollback" || result=1'
        ) == 1
        and candidate.count('rr_restore_stop_managed_runtime "$rollback"') == 6
        and "rr_restore_stop_managed_runtime >/dev/null" not in candidate
        and "if ! rr_restore_stop_managed_runtime; then" not in candidate
    )


assert ready_nginx_isolation_contract(resilience)
isolation_mutations = (
    resilience.replace(
        "systemctl stop rr-nexus sing-box nginx >/dev/null 2>&1 || true",
        "systemctl stop rr-nexus sing-box >/dev/null 2>&1 || true",
        1,
    ),
    resilience.replace(
        "rr_restore_unit_activity_matches nginx inactive || failed=true",
        "true # removed Nginx inactive proof",
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_resume_snapshot_writers "$rollback"; then',
        '    if ! rr_restore_resume_frozen_writers "$rollback"; then',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_resume_snapshot_writers "$rollback"; then',
        '    if ! rr_restore_resume_snapshot_writers "$rollback" || \\\n'
        '       ! rr_restore_activate_nginx_state "$rollback"; then',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then\n'
        '        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
        '    if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then\n'
        '        : # removed clear-failure isolation',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_write_phase "$stage" rolling_back; then\n'
        '        # READY has already been cleared, but candidate processes may have\n'
        '        # crossed it earlier.  A failed phase rename/fsync must still isolate\n'
        '        # every managed runtime using the durable rollback ownership evidence.\n'
        '        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
        '    if ! rr_restore_write_phase "$stage" rolling_back; then\n'
        '        : # removed phase-write-failure isolation',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_stop_managed_runtime "$rollback"; then',
        '    if false; then',
        1,
    ),
    resilience.replace(
        '    if [ "$failed" = true ]; then\n'
        '        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
        '    if [ "$failed" = true ]; then\n'
        '        : # removed late READY clear',
        1,
    ),
    resilience.replace(
        '        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true\n'
        '        rr_restore_write_phase "$stage" recovery_failed',
        '        rr_restore_write_phase "$stage" recovery_failed',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then\n'
        '        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
        '    if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then\n'
        '        : # removed terminal READY clear',
        1,
    ),
    resilience.replace(
        '    if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then\n'
        '        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true\n'
        '        rr_restore_stop_managed_runtime "$rollback" >/dev/null 2>&1 || true',
        '    if ! rr_restore_publish_terminal_phase "$stage" rolled_back; then\n'
        '        rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY" || true',
        1,
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_rollback_claims_cloudflared() {",
        "\nrr_restore_stop_managed_runtime() {",
        'rr_restore_stage_is_safe "$stage" || return 2',
        "true # removed safe-stage proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_rollback_claims_cloudflared() {",
        "\nrr_restore_stop_managed_runtime() {",
        '[ -f "$marker" ] && [ ! -L "$marker" ] || return 2',
        '[ -e "$marker" ] || return 2',
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_rollback_claims_cloudflared() {",
        "\nrr_restore_stop_managed_runtime() {",
        "0:0:1:0:*) ;; *) return 2 ;; esac",
        "*) ;; esac",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_rollback_claims_cloudflared() {",
        "\nrr_restore_stop_managed_runtime() {",
        '[ "$size" -le 1048576 ] || return 2',
        ": # removed service-size bound",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_stop_managed_runtime() {",
        "\nrr_restore_freeze_writers() {",
        'if rr_restore_rollback_claims_cloudflared "$rollback"; then',
        "if false; then",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        'if rr_restore_rollback_claims_cloudflared "$rollback"; then',
        "if false; then",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        "load_config_with_defaults >/dev/null 2>&1 || return 1",
        "load_config_with_defaults >/dev/null 2>&1 || failed=true",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        "select_entry_ip >/dev/null 2>&1 || return 1",
        "select_entry_ip >/dev/null 2>&1 || failed=true",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        '[ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]',
        "false",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        '[ "$cloudflared_owned" != true ]; then',
        '[ true = false ]; then',
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        'if [ "$cloudflared_owned" = true ]; then',
        "if true; then",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        "rr_restore_unit_activity_matches cloudflared active || failed=true",
        "true # removed resumed Cloudflared active proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        "rr_restore_unit_activity_matches cloudflared inactive || failed=true",
        "true # removed stopped Cloudflared inactive proof",
    ),
    resilience.replace(
        'if [ "$failed" = false ] && \\\n'
        '       rr_restore_rollback_claims_cloudflared "$rollback"; then',
        'if rr_restore_rollback_claims_cloudflared "$rollback"; then',
        1,
    ),
    resilience.replace(
        '    rr_restore_stop_managed_runtime "$rollback" || result=1',
        '    rr_restore_stop_managed_runtime || result=1',
        1,
    ),
)
for mutated in isolation_mutations:
    assert mutated != resilience
    assert not ready_nginx_isolation_contract(mutated)
'''


def restore_cloudflared_ownership_contract(candidate):
    try:
        _, _, evidence = function_slice(
            candidate,
            "rr_restore_fixed_cloudflared_evidence_is_trusted() {",
            "\nrr_restore_fixed_cloudflared_binary_path() {",
        )
        _, _, unit = function_slice(
            candidate,
            "rr_restore_fixed_cloudflared_unit_is_owned() {",
            "\nrr_restore_write_cloudflared_claim() {",
        )
        _, _, write_claim = function_slice(
            candidate,
            "rr_restore_write_cloudflared_claim() {",
            "\nrr_restore_rollback_claims_cloudflared() {",
        )
        _, _, claim = function_slice(
            candidate,
            "rr_restore_rollback_claims_cloudflared() {",
            "\nrr_restore_stop_managed_runtime() {",
        )
        _, _, stop = function_slice(
            candidate,
            "rr_restore_stop_managed_runtime() {",
            "\nrr_restore_freeze_writers() {",
        )
        _, _, resume = function_slice(
            candidate,
            "rr_restore_resume_frozen_writers() {",
            "\nrr_restore_remove_managed_fixed_tunnel() {",
        )
        _, _, remove = function_slice(
            candidate,
            "rr_restore_remove_managed_fixed_tunnel() {",
            "\nrr_restore_apply_cloudflared_snapshot() {",
        )
        _, _, apply_snapshot = function_slice(
            candidate,
            "rr_restore_apply_cloudflared_snapshot() {",
            "\nrr_restore_migrate_with_original_state() {",
        )
        _, _, rollback = function_slice(
            candidate,
            "rr_restore_rollback_stage() {",
            "\nrr_restore_recover_active() {",
        )
        _, _, preflight = function_slice(
            candidate,
            "rr_restore_preflight_cloudflared_target() {",
            "\nrr_restore_backup_locked() {",
        )
        _, _, restore = function_slice(
            candidate,
            "rr_restore_backup_locked() {",
            None,
        )

        first_preflight = restore.index(
            'rr_restore_preflight_cloudflared_target \\\n'
            '        "$stage/payload/rootfs/etc/rr-cloudflared/token"'
        )
        gate_preflight = restore.index(
            "rr_restore_preflight_gate_dropin_order", first_preflight
        )
        token_migration = restore.index(
            "rr_restore_migrate_legacy_fixed_token", gate_preflight
        )
        second_preflight = restore.index(
            'rr_restore_preflight_cloudflared_target \\\n'
            '        "$stage/payload/rootfs/etc/rr-cloudflared/token"',
            first_preflight + 1,
        )
        capture_proof = restore.index(
            "rr_restore_fixed_cloudflared_unit_is_owned", second_preflight
        )
        capture_copy = restore.index(
            'cp -p -- "$cloudflared_service_file"', capture_proof
        )
        capture_claim = restore.index(
            'rr_restore_write_cloudflared_claim "$rollback"', capture_copy
        )

        rollback_claim = rollback.index(
            'if rr_restore_rollback_claims_cloudflared "$rollback"; then'
        )
        rollback_proof = rollback.index(
            "rr_restore_fixed_cloudflared_unit_is_owned || failed=true",
            rollback_claim,
        )
        rollback_start = rollback.index(
            "systemctl start cloudflared.service", rollback_proof
        )
        rollback_stop = rollback.index(
            "systemctl stop cloudflared.service", rollback_start
        )
    except ValueError:
        return False

    return (
        '[ "${TUNNEL_MODE:-1}" = 2 ] || return 1' in evidence
        and "[ -f \"$config\" ] && [ ! -L \"$config\" ] || return 1" in evidence
        and '[ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 1'
        in evidence
        and '[ "$lines" -eq 1 ] || return 1' in evidence
        and "rr_restore_fixed_cloudflared_evidence_is_trusted || return 1" in unit
        and 'cmp -s -- "$service_file" \\\n'
        '        <(rr_restore_render_fixed_cloudflared_service "$cloudflared_bin")'
        in unit
        and "--property=LoadState --value" in unit
        and "--property=FragmentPath --value" in unit
        and "--property=DropInPaths --value" in unit
        and '[ "$load_state" = loaded ] && [ "$fragment" = "$service_file" ]'
        in unit
        and 'case "$dropins" in' in unit
        and '"$restore_dropin")' in unit
        and "*) return 1 ;;" in unit
        and "rr_restore_fixed_cloudflared_unit_is_owned || return 1" in write_claim
        and 'service_sha=$(sha256sum -- "$service_file"' in write_claim
        and 'token_sha=$(sha256sum -- "$token_file"' in write_claim
        and "'rr-cloudflared-claim-v1'" in write_claim
        and '"service_sha256=$service_sha"' in write_claim
        and '"token_sha256=$token_sha"' in write_claim
        and 'sync -f "$temporary"' in write_claim
        and 'sync -f "$rollback"' in write_claim
        and '[ "${#claim_lines[@]}" -eq 5 ] || return 2' in claim
        and '[ "$expected_binary" = "$current_binary" ] || return 2' in claim
        and '[ "$(sha256sum -- "$service"' in claim
        and '"$service_sha" ] || return 2' in claim
        and 'rr_restore_render_fixed_cloudflared_service "$expected_binary"'
        in claim
        and '[ "$(sha256sum -- "$token_snapshot"' in claim
        and '"$token_sha" ] || return 2' in claim
        and "2|*) failed=true ;;" in stop
        and stop.count("rr_restore_fixed_cloudflared_unit_is_owned") >= 2
        and stop.count("systemctl stop cloudflared") == 1
        and '[ "$cloudflared_owned" = true ]' in stop
        and "RR_CF_TOKEN_FILE" not in stop
        and "2|*) return 1 ;;" in resume
        and resume.count("rr_restore_fixed_cloudflared_unit_is_owned") >= 3
        and resume.count("systemctl stop cloudflared") == 1
        and "RR_CF_TOKEN_FILE" not in resume
        and remove.count(
            "rr_restore_fixed_cloudflared_unit_is_owned || return 1"
        ) == 3
        and "systemctl stop cloudflared.service" in remove
        and "systemctl disable cloudflared.service" in remove
        and 'rm -f -- "$service_file" || return 1' in remove
        and "cloudflared service uninstall" not in remove
        and "2|*) return 1 ;;" in apply_snapshot
        and apply_snapshot.count(
            "rr_restore_fixed_cloudflared_unit_is_owned || return 1"
        ) == 2
        and "rr_restore_require_effective_gates_or_isolate || return 1"
        in apply_snapshot
        and '[ "$target_fixed" = true ] || [ "$token_present" = true ]'
        in preflight
        and "rr_restore_fixed_cloudflared_unit_is_owned || {" in preflight
        and '[ -s "$imported_token" ] && [ "$service_present" = true ]'
        in preflight
        and first_preflight < gate_preflight < token_migration
        < second_preflight < capture_proof < capture_copy < capture_claim
        and rollback_claim < rollback_proof < rollback_start < rollback_stop
    )


assert restore_cloudflared_ownership_contract(resilience)
cloudflared_ownership_mutations = (
    mutate_function_slice(
        resilience,
        "rr_restore_fixed_cloudflared_evidence_is_trusted() {",
        "\nrr_restore_fixed_cloudflared_binary_path() {",
        '[ "${TUNNEL_MODE:-1}" = 2 ] || return 1',
        ": # removed fixed-mode proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_fixed_cloudflared_unit_is_owned() {",
        "\nrr_restore_write_cloudflared_claim() {",
        'cmp -s -- "$service_file" \\\n'
        '        <(rr_restore_render_fixed_cloudflared_service "$cloudflared_bin") || return 1',
        ": # removed byte-exact renderer proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_fixed_cloudflared_unit_is_owned() {",
        "\nrr_restore_write_cloudflared_claim() {",
        "--property=FragmentPath --value",
        "--property=Description --value",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_write_cloudflared_claim() {",
        "\nrr_restore_rollback_claims_cloudflared() {",
        '"service_sha256=$service_sha"',
        '"service_sha256=unbound"',
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_rollback_claims_cloudflared() {",
        "\nrr_restore_stop_managed_runtime() {",
        'rr_restore_render_fixed_cloudflared_service "$expected_binary"',
        'cat "$service"',
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_stop_managed_runtime() {",
        "\nrr_restore_freeze_writers() {",
        "rr_restore_fixed_cloudflared_unit_is_owned || failed=true",
        ": # removed destructive-boundary proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        "rr_restore_fixed_cloudflared_unit_is_owned || return 1",
        ": # removed pre-action proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_remove_managed_fixed_tunnel() {",
        "\nrr_restore_apply_cloudflared_snapshot() {",
        "rr_restore_fixed_cloudflared_unit_is_owned || return 1",
        ": # removed remove-boundary proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_apply_cloudflared_snapshot() {",
        "\nrr_restore_migrate_with_original_state() {",
        "rr_restore_require_effective_gates_or_isolate || return 1",
        ": # removed post-reload gate proof",
    ),
    mutate_function_slice(
        resilience,
        "rr_restore_preflight_cloudflared_target() {",
        "\nrr_restore_backup_locked() {",
        "rr_restore_fixed_cloudflared_unit_is_owned || {",
        "true || {",
    ),
    resilience.replace(
        '        rr_restore_fixed_cloudflared_unit_is_owned || { rm -rf "$stage"; return 1; }\n'
        '        rr_restore_capture_unit_activity_state cloudflared.service',
        '        : # removed capture-boundary proof\n'
        '        rr_restore_capture_unit_activity_state cloudflared.service',
        1,
    ),
    resilience.replace(
        '        rr_restore_write_cloudflared_claim "$rollback" || { rm -rf "$stage"; return 1; }',
        '        : # removed durable ownership claim',
        1,
    ),
)
for mutated in cloudflared_ownership_mutations:
    assert mutated != resilience
    assert not restore_cloudflared_ownership_contract(mutated)


def restore_watch_fail_closed_contract(candidate):
    try:
        _, _, probe = function_slice(
            candidate, "rr_inherited_update_lock_fds_present() {",
            "\nrr_close_inherited_update_lock_fds() {",
        )
        _, _, close = function_slice(
            candidate, "rr_close_inherited_update_lock_fds() {",
            "\nrr_run_without_inherited_update_lock_fds() {",
        )
        _, _, run = function_slice(
            candidate, "rr_run_without_inherited_update_lock_fds() {",
            "\nrr_run_with_update_locks() {",
        )
        _, _, ready_gate = function_slice(
            candidate, "rr_restore_close_runtime_ready_gate() {",
            "\nrr_restore_watch_fail_closed() {",
        )
        _, _, fail_closed = function_slice(
            candidate, "rr_restore_watch_fail_closed() {",
            "\nrr_restore_watch_active_locked() {",
        )
        _, _, watch = function_slice(
            candidate, "rr_restore_watch_active_locked() {",
            "\nRR_RESTORE_UNIT_LOAD_STATE=",
        )
        _, _, resume = function_slice(
            candidate, "rr_restore_resume_frozen_writers() {",
            "\nrr_restore_remove_managed_fixed_tunnel() {",
        )
        request_clear = watch.index(
            'if ! rr_restore_clear_marker "$RR_RESTORE_WATCH_REQUEST"; then'
        )
        request_isolate = watch.index(
            'rr_restore_watch_fail_closed "$expected_stage"', request_clear
        )
        absent_active = watch.index(
            'if [ ! -e "$RR_RESTORE_ACTIVE" ] && [ ! -L "$RR_RESTORE_ACTIVE" ]; then',
            request_isolate,
        )
        absent_live_clear = watch.index(
            'if ! rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then',
            absent_active,
        )
        absent_isolate = watch.index(
            'rr_restore_watch_fail_closed "$expected_stage"', absent_live_clear
        )
        current_read = watch.index(
            'current_stage=$(rr_restore_active_stage) || {', absent_isolate
        )
        current_isolate = watch.index(
            'rr_restore_watch_fail_closed "$expected_stage"', current_read
        )
        live_clear = watch.index(
            'if ! rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then',
            current_isolate,
        )
        live_isolate = watch.index(
            'rr_restore_watch_fail_closed "$expected_stage"', live_clear
        )
        recover = watch.index("rr_restore_recover_active || result=$?", live_isolate)
        recover_failure = watch.index('if [ "$result" -ne 0 ]; then', recover)
        recover_isolate = watch.index(
            'rr_restore_watch_fail_closed "$expected_stage"', recover_failure
        )
        sub_wrapper = resume.index("rr_run_without_inherited_update_lock_fds")
        sub_start = resume.index("start_subscription_server", sub_wrapper)
        argo_wrapper = resume.index(
            "rr_run_without_inherited_update_lock_fds", sub_start
        )
        argo_start = resume.index("start_argo_tunnel", argo_wrapper)
    except ValueError:
        return False
    if not firewall_tokens_are_ordered(ready_gate, (
        'if ! rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"; then',
        "clear_result=1",
        'if sync && [ ! -e "$RR_RESTORE_RUNTIME_READY" ]',
        '[ ! -L "$RR_RESTORE_RUNTIME_READY" ]; then',
        "clear_result=0",
        'if [ "$clear_result" -eq 0 ]',
        '[ ! -e "$RR_RESTORE_RUNTIME_READY" ]',
        '[ ! -L "$RR_RESTORE_RUNTIME_READY" ]',
        "return 0",
        "declare -F rr_firewall_publish_fail_closed_quarantine",
        "declare -F rr_firewall_fail_closed_quarantine_active",
        "declare -F rr_firewall_load_fail_closed_quarantine",
        "declare -F rr_firewall_quarantine_supervisor_effective",
        "rr_firewall_publish_fail_closed_quarantine || return 1",
        "rr_firewall_fail_closed_quarantine_active || return 1",
        "rr_firewall_load_fail_closed_quarantine || return 1",
        "rr_firewall_quarantine_supervisor_effective",
    )):
        return False
    if not firewall_tokens_are_ordered(fail_closed, (
        'rr_restore_stage_is_safe "$stage" || return 1',
        "rr_restore_close_runtime_ready_gate || ready_result=$?",
        'rr_restore_stop_managed_runtime "$stage/rollback" || isolation_result=$?',
        '[ "$ready_result" -eq 0 ]',
        '[ "$isolation_result" -eq 0 ]',
    )):
        return False
    lock_required = (
        'lock_file="$RR_RESTORE_LIVE_LOCK_FILE"',
        '[ -f "$lock_file" ] && [ ! -L "$lock_file" ]',
        "stat -c '%u:%g:%a:%h'", "0:0:600:1", "stat -c '%d:%i'",
        'lock_identities+=("$lock_identity")',
    )
    return (
        all(token in probe for token in lock_required)
        and all(token in close for token in lock_required)
        and 'local shell_pid="${BASHPID:-$$}"' in probe
        and 'local shell_pid="${BASHPID:-$$}"' in close
        and 'exec {inherited_fd}>&-' in close
        and "rr_inherited_update_lock_fds_present || probe_result=$?" in run
        and "rr_close_inherited_update_lock_fds || return 1" in run
        and run.index("rr_close_inherited_update_lock_fds || return 1")
        < run.index('RR_RESTORE_LOCK_HELD=1 "$callback" "$@"')
        and ready_gate.count("rr_firewall_publish_fail_closed_quarantine") == 2
        and ready_gate.count("rr_firewall_quarantine_supervisor_effective") == 2
        and fail_closed.count("rr_restore_close_runtime_ready_gate") == 1
        and request_clear < request_isolate < absent_active
        < absent_live_clear < absent_isolate < current_read < current_isolate
        < live_clear < live_isolate < recover < recover_failure < recover_isolate
        and watch.count('rr_restore_watch_fail_closed "$expected_stage"') == 6
        and sub_wrapper < sub_start < argo_wrapper < argo_start
        and resume.count("rr_run_without_inherited_update_lock_fds") == 2
    )


assert restore_watch_fail_closed_contract(resilience)
restore_watch_mutations = (
    mutate_function_slice(
        resilience, "rr_inherited_update_lock_fds_present() {",
        "\nrr_close_inherited_update_lock_fds() {",
        'lock_file="$RR_RESTORE_LIVE_LOCK_FILE"',
        'lock_file="/run/removed-live-lock"',
    ),
    mutate_function_slice(
        resilience, "rr_close_inherited_update_lock_fds() {",
        "\nrr_run_without_inherited_update_lock_fds() {",
        'lock_file="$RR_RESTORE_LIVE_LOCK_FILE"',
        'lock_file="/run/removed-live-lock"',
    ),
    mutate_function_slice(
        resilience, "rr_close_inherited_update_lock_fds() {",
        "\nrr_run_without_inherited_update_lock_fds() {",
        'exec {inherited_fd}>&-', ': # removed inherited FD close',
    ),
    mutate_function_slice(
        resilience, "rr_run_without_inherited_update_lock_fds() {",
        "\nrr_run_with_update_locks() {",
        'rr_close_inherited_update_lock_fds || return 1',
        ': # removed inherited FD close proof',
    ),
    mutate_function_slice(
        resilience, "rr_restore_close_runtime_ready_gate() {",
        "\nrr_restore_watch_fail_closed() {",
        'rr_restore_clear_marker "$RR_RESTORE_RUNTIME_READY"',
        ': # removed READY clear',
    ),
    mutate_function_slice(
        resilience, "rr_restore_close_runtime_ready_gate() {",
        "\nrr_restore_watch_fail_closed() {",
        "rr_firewall_publish_fail_closed_quarantine || return 1",
        ": # removed durable quarantine publication",
    ),
    mutate_function_slice(
        resilience, "rr_restore_watch_fail_closed() {",
        "\nrr_restore_watch_active_locked() {",
        "rr_restore_close_runtime_ready_gate || ready_result=$?",
        ": # removed clear-or-quarantine READY gate",
    ),
    mutate_function_slice(
        resilience, "rr_restore_watch_fail_closed() {",
        "\nrr_restore_watch_active_locked() {",
        'rr_restore_stop_managed_runtime "$stage/rollback" || isolation_result=$?',
        ': # removed candidate isolation',
    ),
    mutate_function_slice(
        resilience, "rr_restore_watch_active_locked() {",
        "\nRR_RESTORE_UNIT_LOAD_STATE=",
        'rr_restore_watch_fail_closed "$expected_stage" || result=1',
        ': # removed first watcher isolation',
    ),
    mutate_function_slice(
        resilience, "rr_restore_watch_active_locked() {",
        "\nRR_RESTORE_UNIT_LOAD_STATE=",
        'if ! rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then',
        'if rr_restore_clear_marker "$RR_RESTORE_LIVE_MARKER"; then',
        last=True,
    ),
    mutate_function_slice(
        resilience, "rr_restore_watch_active_locked() {",
        "\nRR_RESTORE_UNIT_LOAD_STATE=",
        'if [ "$result" -ne 0 ]; then', 'if false; then',
    ),
    mutate_function_slice(
        resilience, "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        'rr_run_without_inherited_update_lock_fds \\\n'
        '            start_subscription_server', 'start_subscription_server',
    ),
    mutate_function_slice(
        resilience, "rr_restore_resume_frozen_writers() {",
        "\nrr_restore_remove_managed_fixed_tunnel() {",
        'rr_run_without_inherited_update_lock_fds \\\n'
        '                start_argo_tunnel', 'start_argo_tunnel',
    ),
)
for mutated in restore_watch_mutations:
    assert mutated != resilience
    assert not restore_watch_fail_closed_contract(mutated)

watchdog = restore.index("rr_restore_start_watchdog")
firewall_snapshot = restore.index(
    'rr_restore_capture_firewall_snapshot "$rollback" || result=1'
)
snapshot_complete = restore.index(
    'mv -f "$snapshot_tmp" "$rollback/complete"', firewall_snapshot
)
runtime_gate = restore.index("rr_restore_stop_managed_runtime", watchdog)
migrating = restore.index('rr_restore_write_phase "$stage" migrating', runtime_gate)
firewall_verify_before = restore.index(
    'rr_restore_verify_firewall_pre_mutation_snapshot "$rollback"', migrating
)
candidate_ufw_preflight = restore.index(
    'rr_restore_candidate_ufw_is_disjoint "$rollback"', firewall_verify_before
)
candidate_netfilter_preflight = restore.index(
    'rr_restore_candidate_netfilter_is_disjoint "$rollback"',
    candidate_ufw_preflight,
)
firewall_clear = restore.index(
    'rr_restore_clear_managed_firewall "$rollback/firewall"',
    candidate_netfilter_preflight,
)
firewall_state_after_clear = restore.index(
    'rr_restore_firewall_backend_states_match "$rollback/firewall"',
    firewall_clear,
)
firewall_reconcile = restore.index(
    'open_configured_firewall || result=1',
    firewall_state_after_clear,
)
firewall_state_after_reconcile = restore.index(
    'rr_restore_firewall_backend_states_match "$rollback/firewall"',
    firewall_reconcile,
)
target_migrate = restore.index(
    'rr_restore_migrate_with_original_state "$rollback"',
    firewall_state_after_reconcile,
)
commit = restore.index('rr_restore_commit_candidate "$stage"', target_migrate)
assert watchdog < firewall_snapshot < snapshot_complete < runtime_gate
assert runtime_gate < migrating < firewall_verify_before < candidate_ufw_preflight
assert candidate_ufw_preflight < candidate_netfilter_preflight < firewall_clear
assert firewall_clear < firewall_state_after_clear
assert firewall_state_after_clear < firewall_reconcile < firewall_state_after_reconcile
assert firewall_state_after_reconcile < target_migrate < commit


def portable_firewall_v2_contract(candidate):
    try:
        phase = candidate.index('rr_restore_write_phase "$stage" migrating')
        verify_before = candidate.index(
            'rr_restore_verify_firewall_pre_mutation_snapshot "$rollback"', phase
        )
        ufw_guard = candidate.index(
            'rr_restore_candidate_ufw_is_disjoint "$rollback"', verify_before
        )
        netfilter_guard = candidate.index(
            'rr_restore_candidate_netfilter_is_disjoint "$rollback"', ufw_guard
        )
        scoped_clear = candidate.index(
            'rr_restore_clear_managed_firewall "$rollback/firewall"',
            netfilter_guard,
        )
        state_after_clear = candidate.index(
            'rr_restore_firewall_backend_states_match "$rollback/firewall"',
            scoped_clear,
        )
        reconcile = candidate.index(
            'open_configured_firewall || result=1',
            state_after_clear,
        )
        state_after_reconcile = candidate.index(
            'rr_restore_firewall_backend_states_match "$rollback/firewall"',
            reconcile,
        )
        migrate_target = candidate.index(
            'rr_restore_migrate_with_original_state "$rollback"',
            state_after_reconcile,
        )
    except ValueError:
        return False
    reconcile_context = candidate[state_after_clear:reconcile]
    migrate_context = candidate[state_after_reconcile:migrate_target]
    return (
        'RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 \\\n'
        in reconcile_context
        and 'RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" \\\n'
        in reconcile_context
        and 'RR_PORTABLE_RESTORE=1 \\\n' in migrate_context
        and 'RR_PORTABLE_UFW_AUTHORITY="$portable_ufw_authority" \\\n'
        in migrate_context
        and 'rr_restore_restore_firewall_snapshot "$rollback"'
        not in candidate[scoped_clear:migrate_target]
    )


assert portable_firewall_v2_contract(restore)
firewall_contract_tokens = (
    'rr_restore_verify_firewall_pre_mutation_snapshot "$rollback"',
    'rr_restore_candidate_ufw_is_disjoint "$rollback"',
    'rr_restore_candidate_netfilter_is_disjoint "$rollback"',
    'rr_restore_clear_managed_firewall "$rollback/firewall"',
    'rr_restore_firewall_backend_states_match "$rollback/firewall"',
    'open_configured_firewall || result=1',
    'RR_UPDATE_TRANSACTION=0 RR_PORTABLE_RESTORE=1 \\\n',
)
for token in firewall_contract_tokens:
    mutated = restore.replace(token, "removed_firewall_contract_step", 1)
    assert mutated != restore
    assert not portable_firewall_v2_contract(mutated)
assert (
    'RR_UPDATE_TRANSACTION=1 \\\n'
    in resilience[
        resilience.index("rr_restore_migrate_with_original_state() {"):
        resilience.index("rr_restore_finalize_original_service_state() {")
    ]
)
assert "rr_restore_restore_firewall_snapshot" not in restore[
    firewall_clear:target_migrate
]
rollback_start = resilience.index("rr_restore_rollback_stage() {")
rollback_end = resilience.index("rr_restore_recover_active() {", rollback_start)
rollback = resilience[rollback_start:rollback_end]
assert (
    'RR_PORTABLE_RESTORE=0 RR_PORTABLE_UFW_AUTHORITY=0 \\\n'
    '            rr_restore_migrate_with_original_state "$rollback"'
    in rollback
)
post_migrate = rollback.index(
    'rr_restore_migrate_with_original_state "$rollback"'
)
assert rollback.index(
    'rr_restore_verify_firewall_snapshot "$rollback"', post_migrate
) > post_migrate
assert 'rr_restore_restore_firewall_snapshot "$rollback"' not in rollback[post_migrate:]
blank_target = restore.index(
    'post_update_migrate || result=1',
    target_migrate,
)
assert target_migrate < blank_target < commit

verify_start = release.index("  verify:\n")
publish_start = release.index("  publish:\n", verify_start)
verify = release[verify_start:publish_start]
publish = release[publish_start:]

assert "permissions:\n      contents: read\n      actions: read" in verify
assert "permissions:\n      contents: write\n      actions: read" in publish
assert "needs: verify" in publish
assert "head_sha=${REQUESTED_SHA}" in verify
assert "head_sha=${EXPECTED_SHA}" in publish
# Workflow gates use the exact head_sha filter. Release/tag reconciliation
# additionally requires successful paginated inventories and never maps a
# failed API read to absence.
assert release.count("--paginate --slurp") >= 4
for body, helper, sha in (
    (verify, "require_workflow_success_for_sha", "REQUESTED_SHA"),
    (publish, "assert_workflow_gate", "EXPECTED_SHA"),
):
    assert (
        f"branch=main&event=${{expected_event}}&head_sha=${{{sha}}}"
        "&per_page=100&page=${page}"
    ) in body
    for token in (
        '.total_count | type == "number"',
        '.total_count == (.total_count | floor)',
        '.total_count >= 0 and .total_count <= 10000',
        'expected_total=$(jq -r \'.total_count\'',
        '[ "$accumulated" -le "$expected_total" ]',
        '[ "$accumulated" -eq "$expected_total" ]',
        '[ "$page" -le 101 ]',
        '([$inventory[].id] | length) ==',
        '([$inventory[].id] | unique | length)',
        '$inventory | group_by([.run_number, .run_attempt])',
        'sort_by([.run_number, .run_attempt]) | last',
        '$run.status == "completed" and $run.conclusion == "success"',
    ):
        assert token in body, f"missing {helper} inventory invariant: {token}"
assert 'require_workflow_success_for_sha ci.yml push "CI push"' in verify
assert 'require_workflow_success_for_sha vps-audit.yml push "VPS audit push"' in verify
assert (
    'require_workflow_success_for_sha vps-audit.yml workflow_dispatch \\\n'
    '            "VPS audit workflow_dispatch"'
) in verify
assert 'assert_workflow_gate ci.yml push "CI push"' in publish
assert 'assert_workflow_gate vps-audit.yml push "VPS audit push"' in publish
assert (
    'assert_workflow_gate vps-audit.yml workflow_dispatch \\\n'
    '              "VPS audit workflow_dispatch"'
) in publish
assert publish.count("assert_release_gate") >= 4
assert publish.count("assert_verified_sha_gate") >= 2
assert "assert_main_tip()" in publish
assert 'git/ref/heads/main" --jq \'.object.sha\'' in publish
assert re.search(
    r"assert_release_gate\n\s+cleanup_armed=true\n\s+trap release_cleanup_on_exit EXIT\n"
    r"\s+created_ref=\$\(api --method POST",
    publish,
)
ref_create = publish.index("created_ref=$(api --method POST")
tag_wait = publish.index('wait_for_remote_tag_sha "$TAG" "$EXPECTED_SHA"', ref_create)
tag_identity = publish.index("assert_run_owned_target_tag", tag_wait)
post_tag_main = publish.index("assert_main_tip", tag_identity)
draft_create = publish.index(
    'api --method POST --input release-create-request.json', post_tag_main
)
assert ref_create < tag_wait < tag_identity < post_tag_main < draft_create
assert re.search(
    r"assert_release_gate\n\s+cleanup_armed=false\n\s+trap - EXIT\n"
    r"\s+publish_draft_and_confirm \"\$draft_id\" \"\$RUN_OWNER_MARKER\"",
    publish,
)
assert "rr-vps-release-owner:v2:" in publish
assert "rr-vps-release-owner:v1:" not in publish
assert "reconcile_owned_mutable_target()" in publish
assert "classify_target_release_state()" in publish
assert "is_owned_mutable_draft()" in publish
assert "is_canonical_owned_partial_draft()" in publish
assert "complete_owned_draft_assets()" in publish
assert "is_exact_public_release()" in publish
assert "verify_published_release()" in publish
assert '$actual.state == "starter"' in publish
assert (
    'https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/'
    '${draft_id}/assets?name=${asset}' in publish
)
assert 'gh release create "$TAG"' not in publish
assert "--clobber" not in publish
patch_call = publish.index(
    'publish_draft_and_confirm "$draft_id" "$RUN_OWNER_MARKER"'
)
verify_call = publish.index(
    'verify_published_release "$draft_id" "$RUN_OWNER_MARKER"', patch_call
)
assert patch_call < verify_call
verifier_start = publish.index("          verify_published_release() {")
assets_start = publish.index("          expected_assets=", verifier_start)
verifier = publish[verifier_start:assets_start]
exact_id = verifier.index('api "/repos/${GITHUB_REPOSITORY}/releases/${release_id}"')
download = verifier.index('/releases/assets/${asset_id}', exact_id)
final_release = verifier.index(
    'api "/repos/${GITHUB_REPOSITORY}/releases/${release_id}"',
    download,
)
final_tag_identity = verifier.index("assert_run_owned_target_tag", final_release)
latest_call = verifier.index(
    'assert_latest_product "$release_id" "$owner_marker"', final_tag_identity
)
final_attempt_gates = verifier.index("assert_verified_sha_gate", latest_call)
final_main = verifier.index("assert_main_tip", final_attempt_gates)
newer_gate = verifier.index("assert_no_newer_product_version", final_main)
assert (
    exact_id < download < final_release < final_tag_identity < latest_call
    < final_attempt_gates < final_main < newer_gate
)
assert "releases/latest/download" not in verifier
latest_start = publish.index("          assert_latest_product() {")
latest_end = verifier_start
latest = publish[latest_start:latest_end]
assert "is_exact_public_release" in latest
assert "'.immutable == true'" in latest
assert '--rawfile notes "$RELEASE_NOTES_FILE"' in publish
assert '.body == ($notes + "\\n" + $marker + "\\n")' in publish
assert 'releases=$(api --paginate --slurp' in publish
assert '") || return 1\n            jq -e' in publish
assert "remote_tags=$(git ls-remote --tags --refs origin 'refs/tags/v*') || return 1" in publish

driver = publish[assets_start:]
first_classify = driver.index("classify_target_release_state")
first_version_gate = driver.index("assert_new_monotonic_version")
tag_object_post = driver.index('tag_object=$(api --method POST')
assert first_classify < first_version_gate < tag_object_post
resume_start = driver.index("exact_public_current)")
resume_end = driver.index(
    "exact_owned_draft_current|exact_owned_partial_draft_current)", resume_start
)
resume = driver[resume_start:resume_end]
assert "assert_release_gate" in resume
assert "verify_published_release" in resume
assert "exit 0" in resume
assert not re.search(r"--method\s+(?:POST|PATCH|DELETE)", resume)
partial_end = driver.index("owned_tag_only_current)", resume_end)
partial = driver[resume_end:partial_end]
assert "is_canonical_owned_partial_draft" in partial
assert 'complete_owned_draft_assets "$draft_id" "$RUN_OWNER_MARKER"' in partial
assert "is_exact_mutable_draft" in partial
assert "publish_draft_and_confirm" in partial
owned_end = driver.index("absent)", partial_end)
owned_tag = driver[partial_end:owned_end]
assert 'reconcile_owned_mutable_target "$LOADED_TAG_OBJECT_SHA"' in owned_tag
last_creation_gate = driver.rfind("assert_release_gate", 0, tag_object_post)
assert last_creation_gate != -1 and last_creation_gate < tag_object_post
assert 'api --method DELETE "/repos/${GITHUB_REPOSITORY}/releases/' not in publish
assert 'api --method DELETE "/repos/${GITHUB_REPOSITORY}/git/refs/tags/' not in publish
assert '--force-with-lease="refs/tags/${TAG}:${expected_object_sha}"' in publish
assert "Main is allowed to" not in publish
assert publish.count("--method PATCH") == 1
assert "bash scripts/" not in publish
assert "python3 scripts/" not in publish
for asset in (
    "CHANGELOG.md", "install.sh", "manifest.sha256",
    "modules/00-runtime.sh", "rr-bundle.tar.gz",
):
    assert f"            {asset}\n" in publish

assert "StrictHostKeyChecking=accept-new" not in vps
assert vps.count("StrictHostKeyChecking=yes") == 5
assert vps.count("HostKeyAlgorithms=ssh-ed25519") == 5
assert vps.count("GlobalKnownHostsFile=/dev/null") == 5
job_ranges = {
    "A": ("  debian-full:\n", "  ubuntu-upgrade:\n"),
    "B": ("  ubuntu-upgrade:\n", "  ubuntu-transaction:\n"),
    "C": ("  ubuntu-transaction:\n", "  cross-machine-migration-scale:\n"),
}
pinned_keys = {
    "A": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmpYE2GN+xGyCxDQW1e/NrwzmApHDMz+zLigsrhXhRm",
    "B": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWJw40hog64SpnWDcp4mvlSJIZ1qspCoOhNrn0L/B5A",
    "C": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPNn4M3kE0+DoV//4xOYwweoLnTrwS+bJmmD6pK4ios3",
}
assert len(set(pinned_keys.values())) == 3
for slot, (start_marker, end_marker) in job_ranges.items():
    start = vps.index(start_marker)
    end = vps.index(end_marker, start)
    job = vps[start:end]
    assert f"RR_{slot}_HOST_KEY: {pinned_keys[slot]}" in job
    assert 'printf \'%s %s %s\\n\' "$host" "$host_key_type" "$host_key_data" > "$known_hosts"' in job
b_start, b_end = job_ranges["B"]
b_job = vps[vps.index(b_start):vps.index(b_end, vps.index(b_start))]
a_start, a_end = job_ranges["A"]
a_job = vps[vps.index(a_start):vps.index(a_end, vps.index(a_start))]
expected_waited_helper = [
    "rr_audit_waited_uninstall() {",
    "  local deadline=$((SECONDS + 180)) remaining=0 result=0",
    "  while :; do",
    "    remaining=$((deadline - SECONDS))",
    '    [ "$remaining" -ge 1 ] || return 75',
    '    if rr_run_with_update_locks direct "$remaining" \\',
    "        uninstall_all_locked; then",
    "      return 0",
    "    else",
    "      result=$?",
    "    fi",
    '    [ "$result" = 75 ] || return "$result"',
    "    sleep 1",
    "  done",
    "}",
]

def waited_helpers(job):
    lines = job.splitlines()
    helpers = []
    for start, line in enumerate(lines):
        match = re.fullmatch(r"(\s*)rr_audit_waited_uninstall\(\) \{", line)
        if not match:
            continue
        indent = match.group(1)
        for end in range(start + 1, len(lines)):
            if lines[end] == f"{indent}}}":
                helpers.append([entry[len(indent):] for entry in lines[start:end + 1]])
                break
        else:
            raise AssertionError("unterminated rr_audit_waited_uninstall helper")
    return helpers

def assert_waited_preclean_contract(job, slot):
    # Bind the entire retry helper, including ordering and control flow. This
    # rejects deleted retries, busy-spin loops and fail-open command changes.
    assert waited_helpers(job) == [expected_waited_helper, expected_waited_helper]
    assert job.count("rr_audit_waited_uninstall\n") == 2
    # The installed-runtime call must be the final successful command in the
    # feature-detected branch; the candidate call must be the final command in
    # its fail-closed bash body. A later `true` would otherwise hide failure.
    assert len(re.findall(
        r"^\s+rr_audit_waited_uninstall\n\s+else$", job, re.MULTILINE
    )) == 1
    assert len(re.findall(
        r'^\s+else\n\s+printf "%s\\n" y \| uninstall_all\n\s+fi$',
        job,
        re.MULTILINE,
    )) == 1
    assert "                rr_audit_waited_uninstall\n              '" in job
    assert len(re.findall(r"^\s+if ! bash -c '$", job, re.MULTILINE)) == 1
    assert len(re.findall(
        r'^\s+if ! CLEANUP_RUNTIME="\$cleanup_runtime" bash -c \'$',
        job,
        re.MULTILINE,
    )) == 1
    installed_failure = (
        r"^\s+' >/root/rr-audit-preclean\.log 2>&1; then\n"
        + rf"\s+echo '{slot} pre-clean failed; root-only log retained on VPS\.' >&2\n"
        + r"\s+exit 1\n\s+fi$"
    )
    candidate_log = (
        "/root/rr-audit-preclean.log" if slot in ("A", "B")
        else "/root/rr-audit-candidate-preclean.log"
    )
    candidate_redirect = ">>" if slot in ("A", "B") else ">"
    candidate_failure = (
        rf"^\s+' {candidate_redirect}{re.escape(candidate_log)} 2>&1; then\n"
        + rf"\s+echo '{slot} candidate pre-clean failed; root-only log retained on VPS\.' >&2\n"
        + r"\s+exit 1\n\s+fi$"
    )
    assert len(re.findall(installed_failure, job, re.MULTILINE)) == 1
    assert len(re.findall(candidate_failure, job, re.MULTILINE)) == 1
    assert job.count("declare -F rr_run_with_update_locks") == 1
    assert job.count("declare -F uninstall_all_locked") == 1
    assert job.count('printf "%s\\n" y | uninstall_all') == 1
    assert f"{slot} pre-clean failed; root-only log retained on VPS." in job
    assert f"{slot} candidate pre-clean failed; root-only log retained on VPS." in job

for slot, job in (("A", a_job), ("B", b_job)):
    assert_waited_preclean_contract(job, slot)
assert "openssl x509 -checkhost" not in a_job
assert "declare -F certificate_identity_matches >/dev/null" in a_job
for certificate, identity in (
    ('${panel_domain}', '$panel_domain'),
    ('${naive_domain}', '$naive_domain'),
):
    assert (
        f'"/etc/letsencrypt/live/{certificate}/fullchain.pem" "{identity}"'
        in a_job
    )
for certificate, wrong_identity in (
    ('${panel_domain}', '$naive_domain'),
    ('${naive_domain}', '$panel_domain'),
):
    assert (
        f'"/etc/letsencrypt/live/{certificate}/fullchain.pem" "{wrong_identity}"'
        in a_job
    )
for fragment in (
    "[ -e /etc/rr-nexus ]",
    "[ -e /var/lib/rr-nexus ]",
    "systemctl list-unit-files rr-nexus.service --no-legend",
    "test ! -e /etc/rr-nexus",
    "test ! -e /var/lib/rr-nexus",
    'systemctl show -p LoadState --value rr-nexus.service',
):
    assert fragment in b_job
candidate_cleanup_if = b_job.index("          if [ -e /usr/local/bin/rr ]")
candidate_cleanup_call = b_job.index(
    "                rr_audit_waited_uninstall\n              '",
    candidate_cleanup_if,
)
candidate_cleanup_stage = b_job.index("          printf 'preclean-complete", candidate_cleanup_call)
quarantine_contract_start = b_job.index("          quarantine_fully_absent() {")
quarantine_contract_end = b_job.index(
    '          test "$(id -u)" -eq 0', quarantine_contract_start
)
quarantine_contract = b_job[quarantine_contract_start:quarantine_contract_end]
for artifact in (
    "/var/lib/rr-update/subscription-quarantine",
    "/run/rr-subscription-quarantine.ready",
    "/etc/systemd/system/rr-subscription-quarantine.service",
    "/var/lib/rr-quarantine/guard-state",
    "/usr/local/libexec/rr-vps/subscription-quarantine-guard",
):
    assert artifact in quarantine_contract
assert '[ ! -e "$artifact" ] && [ ! -L "$artifact" ]' in quarantine_contract
assert "not-found:inactive:not-found || return 1" in quarantine_contract
assert '"$backend" -w 5 -t raw -S PREROUTING' in quarantine_contract
assert "rr-vps unsafe rollback subscription quarantine" in quarantine_contract
assert "assert_product_quarantine_firewall() (" in quarantine_contract
assert "assert_product_quarantine_firewall_absent() (" in quarantine_contract
assert "export RR_UPDATE_RECOVER_SOURCE_ONLY=1" in quarantine_contract
assert "source /usr/local/sbin/rr-update-recover" in quarantine_contract
assert "rr_quarantine_firewall_inventory_is_exact 18081" in quarantine_contract
assert (
    "rr_quarantine_firewall_backend_inventory_is_exact iptables 18081 0"
    in quarantine_contract
)
assert (
    "rr_quarantine_firewall_backend_inventory_is_exact ip6tables 18081 0"
    in quarantine_contract
)
for fragment in (
    "[ -e /var/lib/rr-update ]",
    "[ -L /var/lib/rr-update ]",
    "[ -e /run/rr-vps/update-maintenance ]",
    "[ -L /run/rr-vps/update-maintenance ]",
):
    position = b_job.index(fragment, candidate_cleanup_if, candidate_cleanup_call)
    assert candidate_cleanup_if < position < candidate_cleanup_call
for fragment in (
    "test ! -e /var/lib/rr-update",
    "test ! -L /var/lib/rr-update",
    "test ! -e /run/rr-vps/update-maintenance",
    "test ! -L /run/rr-vps/update-maintenance",
):
    position = b_job.index(fragment, candidate_cleanup_call, candidate_cleanup_stage)
    assert candidate_cleanup_call < position < candidate_cleanup_stage
quarantine_wait = b_job.index("          quarantine_absent=false", candidate_cleanup_call)
quarantine_probe = b_job.index(
    "            if quarantine_fully_absent; then", quarantine_wait
)
quarantine_final = b_job.index(
    '          if [ "$quarantine_absent" != true ] || ! quarantine_fully_absent; then',
    quarantine_probe,
)
assert candidate_cleanup_call < quarantine_wait < quarantine_probe
assert quarantine_probe < quarantine_final < candidate_cleanup_stage
lock_wait = b_job.index("          update_locks_released=false", quarantine_final)
lock_probe = b_job.index(
    "            rr_run_with_update_locks direct 0 true", lock_wait
)
lock_busy_retry = b_job.index("              75) sleep 1 ;;", lock_probe)
lock_timeout = b_job.index(
    '          if [ "$update_locks_released" != true ]; then', lock_busy_retry
)
assert quarantine_final < lock_wait < lock_probe < lock_busy_retry
assert lock_busy_retry < lock_timeout < candidate_cleanup_stage
assert "B pre-clean update lock probe failed safely" in b_job[lock_probe:lock_timeout]
for fragment in (
    "recovery_helper_is_known_for_reset() {",
    "recovery_unit_is_known_for_reset() {",
    "recovery_dropin_dir_is_safe_for_reset() {",
    "reset_recovery_runtime_for_v710_fixture() {",
    "assert_pure_v710_recovery_runtime() {",
    "/etc/systemd/system/rr-update-recovery.service.d",
    "/usr/local/sbin/rr-update-recover",
    "/usr/local/sbin/rr-update-external-state",
    "2243e4b3c9199a100b0725cbec5b333a1897fe9367b0c222e8536da26531b9ec",
    "dfc878951a4bb9d8b43523b767314ebc8254d4ad64b3a606b569255190916e4a",
    "95c317ad865e0ac9b77454a6948bea25783ccc19aa52a25134386ee396362412",
):
    assert fragment in b_job
recovery_reset_start = b_job.index(
    "          recovery_dropin_dir_is_safe_for_reset() {"
)
recovery_reset_end = b_job.index(
    "          assert_pure_v710_recovery_runtime() {", recovery_reset_start
)
recovery_reset_contract = b_job[recovery_reset_start:recovery_reset_end]
assert 'find "$target" -mindepth 1 -maxdepth 1 -printf x -quit' in \
    recovery_reset_contract
assert '[ -z "$entry" ]' in recovery_reset_contract
assert 'rmdir -- "$dropin_dir" || return 1' in recovery_reset_contract
assert 'rm -rf -- "$dropin_dir"' not in recovery_reset_contract
recovery_reset_call = b_job.index(
    '          reset_recovery_runtime_for_v710_fixture "$cleanup_runtime"',
    lock_timeout,
)
assert lock_timeout < recovery_reset_call < candidate_cleanup_stage
assert b_job.count("          assert_pure_v710_recovery_runtime\n") == 2
old_core_install = b_job.index(
    '            bash "$old/install-core.sh" --upgrade >/root/rr-audit-old-core.log'
)
first_pure_v710 = b_job.index(
    "          assert_pure_v710_recovery_runtime\n", old_core_install
)
first_candidate_upgrade = b_job.index(
    "          install_candidate >/root/rr-audit-upgrade.log", first_pure_v710
)
second_pure_v710 = b_job.index(
    "          assert_pure_v710_recovery_runtime\n", first_pure_v710 + 1
)
assert old_core_install < first_pure_v710 < second_pure_v710 < first_candidate_upgrade
pure_v710_start = b_job.index("          assert_pure_v710_recovery_runtime() {")
pure_v710_end = b_job.index("          quarantine_fully_absent() {", pure_v710_start)
pure_v710_contract = b_job[pure_v710_start:pure_v710_end]
for fragment in (
    "[ ! -e /usr/local/sbin/rr-update-external-state ]",
    "loaded:inactive:enabled",
    '[ "$unit_umask" = 0022 ]',
    "/var/lib/rr-update/transactions/*",
    '[ "$(cat "$active_tx/phase")" = committed ]',
):
    assert fragment in pure_v710_contract
assert b_job.count("source /usr/local/sbin/rr-update-recover") == 3
assert b_job.count("rr_quarantine_firewall_inventory_is_exact 18081") == 2
legacy_assert_start = b_job.index("          assert_legacy_quarantine() {")
legacy_assert_end = b_job.index(
    "          install_candidate >/root/rr-audit-upgrade.log", legacy_assert_start
)
legacy_assert = b_job[legacy_assert_start:legacy_assert_end]
assert legacy_assert.count("            assert_product_quarantine_firewall\n") == 1
first_rollback = b_job.index(
    "          /usr/local/sbin/rr-update-recover rollback", legacy_assert_end
)
first_legacy_assert_call = b_job.index(
    "          assert_legacy_quarantine\n", first_rollback
)
second_upgrade = b_job.index(
    "          install_candidate >>/root/rr-audit-upgrade.log", first_legacy_assert_call
)
second_upgrade_runtime = b_job.index(
    "          assert_candidate_runtime\n", second_upgrade
)
post_upgrade_firewall_absent = b_job.index(
    "          assert_product_quarantine_firewall_absent\n", second_upgrade_runtime
)
second_upgrade_stage = b_job.index(
    "          printf 'second-upgrade-complete", post_upgrade_firewall_absent
)
assert second_upgrade < second_upgrade_runtime < post_upgrade_firewall_absent
assert post_upgrade_firewall_absent < second_upgrade_stage
assert b_job.count("          assert_product_quarantine_firewall_absent\n") == 1
pre710_start = b_job.index("          # Re-enter the unsafe rollback once more")
legacy_contract_start = b_job.rfind(
    "          legacy_quarantine_fully_absent() {", 0, pre710_start
)
legacy_contract_end = b_job.index(
    '          test "$(id -u)" -eq 0', legacy_contract_start
)
legacy_contract = b_job[legacy_contract_start:legacy_contract_end]
for artifact in (
    "/var/lib/rr-update/subscription-quarantine",
    "/run/rr-subscription-quarantine.ready",
    "/etc/systemd/system/rr-subscription-quarantine.service",
    "/var/lib/rr-quarantine/guard-state",
    "/usr/local/libexec/rr-vps/subscription-quarantine-guard",
):
    assert artifact in legacy_contract
assert '[ ! -e "$artifact" ] && [ ! -L "$artifact" ]' in legacy_contract
assert "not-found:inactive:not-found || return 1" in legacy_contract
assert '"$backend" -w 5 -t raw -S PREROUTING' in legacy_contract
assert "rr-vps unsafe rollback subscription quarantine" in legacy_contract
pre710_firewall = b_job.index(
    "          assert_product_quarantine_firewall\n", pre710_start
)
legacy_uninstall = b_job.index("          printf 'y\\n' | bash -c '", pre710_firewall)
assert pre710_firewall < legacy_uninstall
assert '"$backend" -w 5 -t raw -C PREROUTING' not in b_job[
    pre710_start:legacy_uninstall
]
legacy_wait = b_job.index(
    "          legacy_quarantine_absent=false", legacy_uninstall
)
legacy_probe = b_job.index(
    "            if legacy_quarantine_fully_absent; then", legacy_wait
)
legacy_final = b_job.index(
    "          legacy_quarantine_final=false", legacy_probe
)
legacy_final_probe = b_job.index(
    "          if legacy_quarantine_fully_absent; then", legacy_final
)
legacy_final_gate = b_job.index(
    '          if [ "$legacy_quarantine_absent" != true ] ||', legacy_final_probe
)
legacy_helper_removed = b_job.index(
    "          test ! -e /usr/local/sbin/rr-update-recover", legacy_final_gate
)
assert legacy_uninstall < legacy_wait < legacy_probe < legacy_final
assert legacy_final < legacy_final_probe < legacy_final_gate < legacy_helper_removed
assert "for _ in $(seq 1 30); do" in b_job[legacy_wait:legacy_final]
assert "sleep 1" in b_job[legacy_wait:legacy_final]
assert "B legacy uninstall did not converge quarantine cleanup." in b_job[
    legacy_final_gate:legacy_helper_removed
]
assert (
    "[ -e /etc/systemd/system/rr-subscription-quarantine.service ] || break"
    not in b_job[legacy_uninstall:legacy_helper_removed]
)
for fragment in (
    "run_old_install_deps() {",
    "attempt <= 30",
    "Could not get lock|Unable to acquire.*lock|held by process|is another process using",
    "sleep 10",
    "return 75",
):
    assert fragment in b_job
assert b_job.count("run_old_install_deps") == 2
assert "SELECT COUNT(*) FROM devices;" in b_job
assert 'all(.[]; test("^dev_[a-f0-9]{12}$"))' in b_job
nexus_names = b_job.index("            nexus_traffic_user_names")
nexus_assert_start = b_job.rfind("          bash -c '\n", 0, nexus_names)
nexus_assert_end = b_job.index("\n          '\n", nexus_names)
nexus_assert = b_job[nexus_assert_start:nexus_assert_end]
assert "set -eo pipefail" in nexus_assert
assert "nexus_traffic_user_names" in nexus_assert and "| jq -e" in nexus_assert
c_start, c_end = job_ranges["C"]
c_job = vps[vps.index(c_start):vps.index(c_end, vps.index(c_start))]
assert_waited_preclean_contract(c_job, "C")
assert "printf '%s\\n' 0 '' '' '' | bash -c" in c_job
assert "committed-settled" in c_job
assert "rr-update-committed-settled-v1" in c_job
assert "if any_node_protocol_enabled; then" in c_job
assert "C no-protocol recovery fixture unexpectedly has an enabled node." in c_job
assert "for writer_marker in writer_state_complete subscription_was_running; do" in c_job
assert 'test -f "$active_tx/backup/$writer_marker"' in c_job
assert "subscription_server_running" in c_job
assert 'ufw --force allow' not in a_job
ufw_reset = a_job.index('ufw --force reset')
ufw_inactive = a_job.index("grep -qx 'Status: inactive'", ufw_reset)
ufw_marker = a_job.index('ufw_marker=/etc/ufw/applications.d/rr-audit-marker', ufw_inactive)
ufw_allow = a_job.index('ufw allow "$ssh_control_port/tcp"', ufw_marker)
ufw_saved = a_job.index('ufw show added', ufw_allow)
ufw_enable = a_job.index('ufw --force enable', ufw_saved)
ufw_active = a_job.index("grep -qx 'Status: active'", ufw_enable)
ufw_live = a_job.index('rr_ufw_rule_state "$ssh_control_port" tcp ALLOW', ufw_active)
assert ufw_reset < ufw_inactive < ufw_marker < ufw_allow < ufw_saved
assert ufw_saved < ufw_enable < ufw_active < ufw_live
assert "|| true" not in a_job[ufw_reset:ufw_live]
migration_start = vps.index("  cross-machine-migration-scale:\n")
ip_audit_start = vps.index("  public-ip-acme:\n", migration_start)
gate_start = vps.index("  vps-gate:\n", migration_start)
migration = vps[migration_start:ip_audit_start]
ip_audit = vps[ip_audit_start:gate_start]
gate = vps[gate_start:]
assert "needs: [debian-full, ubuntu-transaction]" in migration
for slot in ("A", "C"):
    for secret in ("HOST", "PASS"):
        assert f"RR_{slot}_{secret}: ${{{{ secrets.RR_{slot}_{secret} }}}}" in migration
    assert f"RR_{slot}_HOST_KEY: {pinned_keys[slot]}" in migration
for slot in ("A", "B", "C"):
    assert f"secrets.RR_{slot}_HOST_KEY" not in vps
assert "known-hosts-migration-A" in migration
assert "known-hosts-migration-C" in migration
assert 'prepare_known_hosts "$a_host" "$RR_A_HOST_KEY" "$a_known_hosts"' in migration
assert 'prepare_known_hosts "$c_host" "$RR_C_HOST_KEY" "$c_known_hosts"' in migration
assert migration.count("assert_unit_state() {") == 3
unit_state_helpers = []
helper_search = 0
while True:
    helper_start = migration.find("assert_unit_state() {", helper_search)
    if helper_start < 0:
        break
    helper_end = migration.index("\n          }\n", helper_start)
    unit_state_helpers.append(migration[helper_start:helper_end])
    helper_search = helper_end + 1
assert len(unit_state_helpers) == 3
for fragment in (
    'systemctl show -p LoadState --value "$unit"',
    'systemctl show -p ActiveState --value "$unit"',
    'systemctl show -p UnitFileState --value "$unit"',
):
    assert all(helper.count(fragment) == 1 for helper in unit_state_helpers)
assert sum(
    'test "$load_state:$active_state:$unit_file_state" = "$expected"' in helper
    for helper in unit_state_helpers
) == 2
assert sum(
    '[ "$load_state:$active_state:$unit_file_state" = "$expected" ]' in helper
    for helper in unit_state_helpers
) == 1
assert sum(
    'if [ "$load_state" = not-found ] && [ -z "$unit_file_state" ]; then'
    in helper for helper in unit_state_helpers
) == 2
assert "for scale in 1 10 100 500; do" in migration
assert "timeout --kill-after=5 150 /usr/local/bin/rr --sync-devices" in migration
assert 'timeout --kill-after=10 300 /usr/local/bin/rr backup "$backup_file"' in migration
assert 'timeout --kill-after=10 300 /usr/local/bin/rr restore "$backup_file"' in migration
assert migration.count("RR_BACKUP_PASSPHRASE=") == 2
assert "PRAGMA quick_check" in migration
assert "PRAGMA foreign_key_check" in migration
assert "stable_sha256" in migration
assert "cmp -s \"$fingerprint_file\" \"$restored_fingerprint\"" in migration
assert "127.0.0.1:7900" in migration
assert "public_listen=$(ss -H -ltn 'sport = :17900') || exit 1" in migration
for field in (
    "SUB_PORT", "SUB_ACCESS_MODE", "SUB_DOMAIN",
    "SUB_PUBLIC_PORT_IPV4", "SUB_PUBLIC_PORT_IPV6",
):
    assert field in migration
assert "rr-audit-cross-target-bind" in migration
assert "firewall_rule_count()" in migration
assert "capture_full_firewall_state()" in migration
assert "capture_rr_firewall_state()" not in migration
assert "$BASH_COMMAND" not in migration
assert "set -x" not in migration
assert "printenv" not in migration
assert not re.search(r"\b(?:cat|tee)\s+/root/rr-audit-cross-.*\.log", migration)
audit_stages = set(re.findall(r"^\s+audit_stage=([a-z0-9-]+)$", migration, re.M))
assert audit_stages == {
    "runner-preflight", "runner-passphrase", "runner-source", "runner-copy",
    "runner-target", "runner-complete", "a-preflight", "a-scale-fixture",
    "a-scale-sync", "a-health-freeze", "a-database-finalize",
    "a-fingerprint", "a-config-snapshot", "a-backup", "a-config-restore",
    "a-service-resume", "a-complete", "c-preflight", "c-fixture",
    "c-restore", "c-data-verify", "c-config-verify", "c-firewall-verify",
    "c-runtime-verify", "c-complete",
}
assert not re.search(r"audit_stage\s*=\s*[\"']?\$", migration)
assert migration.count('case "$failure_stage" in') == 3
assert migration.count("RR_AUDIT_CROSS_FAILURE side=") == 8
assert migration.count('"$failure_stage" "$body_rc" >&2') == 3
assert '"$audit_stage" "$body_rc"' not in migration
for unknown_stage in ("runner-unknown", "a-unknown", "c-unknown"):
    assert migration.count(f"*) failure_stage={unknown_stage} ;;") == 1
for fixed_cleanup_stage in (
    "runner-cleanup-local", "runner-cleanup-source", "runner-cleanup-target",
    "a-cleanup", "c-cleanup",
):
    assert f"stage={fixed_cleanup_stage} rc=1" in migration

remote_a_start = migration.index("bash -s <<'REMOTE_A'\n")
remote_a_end = migration.index("          REMOTE_A\n", remote_a_start)
remote_a = migration[remote_a_start:remote_a_end]
source_cleanup_start = remote_a.index("          finish_source_audit() {\n")
source_cleanup_end = remote_a.index(
    "          trap finish_source_audit EXIT\n", source_cleanup_start
)
source_cleanup = remote_a[source_cleanup_start:source_cleanup_end]


def source_cleanup_is_strict(candidate):
    required = (
        'local body_rc="$?" failure_stage="${audit_stage:-a-unknown}" rc=0',
        "trap - EXIT",
        'rc="$body_rc"',
        "systemctl restart rr-nexus.service >/dev/null 2>&1 || true",
        "assert_unit_state rr-nexus.service loaded:active:enabled",
        "wait_local_nexus",
        "systemctl restart argo-rr-health.timer >/dev/null 2>&1 || true",
        "assert_unit_state argo-rr-health.timer loaded:active:enabled",
        'if [ "$cleanup_failed" = true ]; then',
        '[ "$rc" -ne 0 ] || rc=1',
        'exit "$rc"',
    )
    if any(candidate.count(fragment) != 1 for fragment in required):
        return False
    positions = [candidate.index(fragment) for fragment in required]
    return positions == sorted(positions)


assert source_cleanup_is_strict(source_cleanup)
cleanup_mutations = (
    (
        "systemctl restart rr-nexus.service >/dev/null 2>&1 || true",
        "systemctl start rr-nexus.service >/dev/null 2>&1 || true",
    ),
    ("assert_unit_state rr-nexus.service loaded:active:enabled", ":"),
    ("wait_local_nexus", ":"),
    (
        "systemctl restart argo-rr-health.timer >/dev/null 2>&1 || true",
        "systemctl start argo-rr-health.timer >/dev/null 2>&1 || true",
    ),
    ("assert_unit_state argo-rr-health.timer loaded:active:enabled", ":"),
    ('local body_rc="$?"', 'local body_rc=0'),
    ('rc="$body_rc"', 'rc=0'),
)
for original, replacement in cleanup_mutations:
    mutated = source_cleanup.replace(original, replacement, 1)
    assert mutated != source_cleanup
    assert not source_cleanup_is_strict(mutated)

def cleanup_flags_are_strict(candidate):
    matches = {}
    for flag in ("nexus_stopped", "health_timer_stopped"):
        matches[flag] = list(re.finditer(
            rf"(?<![A-Za-z0-9_]){flag}=([^\s;#]+)", candidate
        ))
        if [match.group(1) for match in matches[flag]] != [
            "false", "true", "false"
        ]:
            return False
        if re.search(
            rf"(?m)^\s*unset(?:\s+--)?[^\n#]*\b{flag}\b", candidate
        ):
            return False

    readiness = candidate.index("wait_local_nexus", candidate.index(
        "systemctl start argo-rr-health.timer"
    ))
    nexus_positions = [match.start() for match in matches["nexus_stopped"]]
    health_positions = [match.start() for match in matches["health_timer_stopped"]]
    return (
        nexus_positions[0] < nexus_positions[1]
        < candidate.index("systemctl stop rr-nexus.service", nexus_positions[1])
        < readiness < nexus_positions[2]
        and health_positions[0] < health_positions[1]
        < candidate.index(
            "systemctl stop argo-rr-health.timer", health_positions[1]
        ) < readiness < health_positions[2]
    )


assert cleanup_flags_are_strict(remote_a)


def replace_last(value, old, new):
    prefix, separator, suffix = value.rpartition(old)
    assert separator
    return prefix + new + suffix


flag_mutations = (
    remote_a.replace(
        "          wait_local_nexus\n",
        "          nexus_stopped=false\n          wait_local_nexus\n",
        1,
    ),
    replace_last(remote_a, "health_timer_stopped=false", "health_timer_stopped=0"),
    remote_a.replace(
        "          wait_local_nexus\n",
        "          unset health_timer_stopped\n          wait_local_nexus\n",
        1,
    ),
)
for mutated in flag_mutations:
    assert mutated != remote_a
    assert not cleanup_flags_are_strict(mutated)

health_flag = remote_a.index("health_timer_stopped=true")
health_stop = remote_a.index("systemctl stop argo-rr-health.timer", health_flag)
health_service_stop = remote_a.index(
    "systemctl stop argo-rr-health.service >/dev/null 2>&1 || true",
    health_stop,
)
health_reset = remote_a.index(
    "systemctl reset-failed argo-rr-health.service >/dev/null 2>&1 || true",
    health_service_stop,
)
health_exact = remote_a.index(
    "assert_unit_state argo-rr-health.service loaded:inactive:static",
    health_reset,
)
nexus_flag = remote_a.index("nexus_stopped=true", health_exact)
nexus_stop = remote_a.index("systemctl stop rr-nexus.service", nexus_flag)
resume_nexus = remote_a.index("systemctl start rr-nexus.service", nexus_stop)
resume_nexus_exact = remote_a.index(
    "assert_unit_state rr-nexus.service loaded:active:enabled", resume_nexus
)
resume_timer = remote_a.index("systemctl start argo-rr-health.timer", resume_nexus_exact)
resume_timer_exact = remote_a.index(
    "assert_unit_state argo-rr-health.timer loaded:active:enabled", resume_timer
)
resume_health = remote_a.index("wait_local_nexus", resume_timer_exact)
clear_nexus_flag = remote_a.index("nexus_stopped=false", resume_health)
clear_health_flag = remote_a.index("health_timer_stopped=false", clear_nexus_flag)
assert health_flag < health_stop < health_service_stop < health_reset < health_exact
assert health_exact < nexus_flag < nexus_stop < resume_nexus < resume_nexus_exact
assert resume_nexus_exact < resume_timer < resume_timer_exact < resume_health
assert resume_health < clear_nexus_flag < clear_health_flag
remote_c_start = migration.index(
    "            \"$backup_sha\" \"$fingerprint_sha\" <<'REMOTE_C'\n"
    "          set -euo pipefail\n"
    "          umask 077\n"
)
remote_c_end = migration.index("          REMOTE_C\n", remote_c_start)
remote_c = migration[remote_c_start:remote_c_end]

source_ordinary_targets = (
    "/run/rr-audit-cross-passphrase",
    "/root/rr-audit-cross.rrbak",
    "/run/rr-audit-cross-fingerprint.json",
    "/root/rr-audit-cross-sync.log",
    "/root/rr-audit-cross-backup.log",
    "/root/rr-audit-panel-pass",
)
source_evidence_targets = (
    "/root/rr-audit-cross-source-config",
    "/root/rr-audit-cross-source-config.sha256",
    "/root/.rr-audit-cross-source-config.sha256.new",
    "/etc/.rr-audit-cross-source-config.recover",
)
target_cleanup_targets = (
    "/run/rr-audit-cross-passphrase",
    "/root/rr-audit-cross.rrbak",
    "/run/rr-audit-cross-fingerprint.json",
    "/run/rr-audit-cross-restored-fingerprint.json",
    "/run/rr-audit-cross-target-access.json",
    "/run/rr-audit-cross-target-network.txt",
    "/run/rr-audit-cross-target-channel",
    "/run/rr-audit-cross-target-bind",
    "/run/rr-audit-cross-target-firewall",
    "/run/rr-audit-cross-restored-firewall",
    "/run/rr-audit-cross-firewall-before-validate",
    "/run/rr-audit-cross-firewall-before-validate.tmp",
    "/run/rr-audit-cross-firewall-after-validate",
    "/run/rr-audit-cross-firewall-after-validate.tmp",
    "/root/rr-audit-cross-restore.log",
    "/root/rr-audit-cross-firewall-validate.log",
    "/root/rr-audit-panel-pass",
)
a_state_dir = "/var/lib/rr-audit-cross-cleanup-a"
c_state_dir = "/var/lib/rr-audit-cross-cleanup-c"


def heredoc_body(candidate, start_marker, end_marker, offset=0):
    start = candidate.index(start_marker, offset) + len(start_marker)
    end = candidate.index(end_marker, start)
    return candidate[start:end], start, end


def normalized_shell(candidate):
    normalized = re.sub(r"\\\n\s*", " ", candidate)
    return re.sub(r"[ \t]+", " ", normalized)


def fixed_path_count(candidate, path):
    return len(re.findall(
        re.escape(path) + r"(?=$|[\s;\"'\\])", candidate
    ))


def embedded_cleanup_helper(block, slot):
    marker = f"<<'RR_{slot}_CLEANUP_HELPER'\n"
    end_marker = f"          RR_{slot}_CLEANUP_HELPER\n"
    if block.count(marker) != 1 or block.count(end_marker) != 1:
        raise ValueError(f"{slot} cleanup helper heredoc is not unique")
    start = block.index(marker) + len(marker)
    end = block.index(end_marker, start)
    return textwrap.dedent(block[start:end]), start, end + len(end_marker)


def durable_helper_common_is_strict(body, slot):
    state_dir = a_state_dir if slot == "A" else c_state_dir
    service = f"rr-audit-cross-cleanup-{slot.lower()}.service"
    timer = f"rr-audit-cross-cleanup-{slot.lower()}.timer"
    required = (
        f"state_dir={state_dir}",
        'self="$state_dir/helper"',
        'self_tmp="$state_dir/.helper.new"',
        'deadline_file="$state_dir/deadline"',
        'unit_hashes="$state_dir/units.sha256"',
        f"service_unit={service}",
        f"timer_unit={timer}",
        "validate_unit_hashes() {",
        "/usr/bin/sha256sum --check --strict",
        "validate_bundle() {",
        "self_disarm() {",
        '[ "$0" = "$self" ]',
        '[ "$#" -eq 1 ]',
        'case "$cleanup_mode" in timer|exit)',
        "RR_AUDIT_HELPER_SHA:-",
        "validate_bundle",
        'deadline_epoch=$(/usr/bin/sed -n',
        '[ "$cleanup_mode" = timer ]',
        '[ "$(/usr/bin/date +%s)" -lt "$deadline_epoch" ]',
        '/usr/bin/systemctl disable --now "$timer_unit"',
        '/usr/bin/rm -f -- "$service_file" "$timer_file"',
        "/usr/bin/systemctl daemon-reload",
        '/usr/bin/rm -f -- "$unit_hashes" "$deadline_file" "$self"',
        '/usr/bin/rmdir "$state_dir"',
    )
    if any(fragment not in body for fragment in required):
        return False
    if any(fragment in body for fragment in (
        "|| true", "eval ", "bash -c", "sh -c", "RR_A_PASS", "sshpass",
        "/run/rr-audit-cross-cleanup-",
    )):
        return False
    validate = body.index("validate_bundle\n")
    deadline = body.index("deadline_epoch=", validate)
    early_gate = body.index('if [ "$cleanup_mode" = timer ]', deadline)
    functional = body.find("acquire_firewall_lock", early_gate)
    if slot == "A":
        functional = body.index('[ -f "$source_hash" ]', early_gate)
    disable = body.index('/usr/bin/systemctl disable --now "$timer_unit"')
    unit_remove = body.index(
        '/usr/bin/rm -f -- "$service_file" "$timer_file"', disable
    )
    reload_units = body.index("/usr/bin/systemctl daemon-reload", unit_remove)
    helper_remove = body.index(
        '/usr/bin/rm -f -- "$unit_hashes" "$deadline_file" "$self"',
        reload_units,
    )
    return (
        validate < deadline < early_gate < functional
        and disable < unit_remove < reload_units < helper_remove
    )


def source_helper_is_strict(body):
    if not durable_helper_common_is_strict(body, "A"):
        return False
    required = (
        "/usr/bin/systemctl restart rr-nexus.service",
        "assert_unit_state rr-nexus.service loaded:active:enabled",
        "/usr/bin/systemctl restart argo-rr-health.timer",
        "assert_unit_state argo-rr-health.timer loaded:active:enabled",
        "wait_local_nexus",
        "/usr/bin/curl -fsS --connect-timeout 1 --max-time 3",
        "/root/rr-audit-panel-pass",
        'if [ "$cleanup_mode" = timer ]; then',
        '/usr/bin/rm -f -- "$source_hash"',
        "self_disarm",
        '[ -f "$source_hash" ] && [ ! -L "$source_hash" ]',
    )
    if any(fragment not in body for fragment in required):
        return False
    if "restore_runtime" in body:
        return False
    if any(fixed_path_count(body, target) != 2
           for target in source_ordinary_targets):
        return False
    restore = body.index(
        '/usr/bin/mv -fT -- "$recover_tmp" "$live_config"'
    )
    config_proof = body.index(
        'validate_config "$live_config" "$expected_source_sha"', restore
    )
    nexus = body.index(
        "/usr/bin/systemctl restart rr-nexus.service", config_proof
    )
    nexus_proof = body.index(
        "assert_unit_state rr-nexus.service loaded:active:enabled", nexus
    )
    timer = body.index(
        "/usr/bin/systemctl restart argo-rr-health.timer", nexus_proof
    )
    timer_proof = body.index(
        "assert_unit_state argo-rr-health.timer loaded:active:enabled", timer
    )
    readiness = body.index("wait_local_nexus", timer_proof)
    artifact_remove = body.index(
        "/usr/bin/rm -f -- /run/rr-audit-cross-passphrase", readiness
    )
    timer_cleanup = body.index(
        'if [ "$cleanup_mode" = timer ]; then', artifact_remove
    )
    source_remove = body.index(
        '/usr/bin/rm -f -- "$source_hash"', timer_cleanup
    )
    disarm = body.index("self_disarm", source_remove)
    exit_retain = body.index(
        '[ -f "$source_hash" ] && [ ! -L "$source_hash" ]', disarm
    )
    return (
        restore < config_proof < nexus < nexus_proof < timer < timer_proof
        < readiness < artifact_remove < timer_cleanup < source_remove
        < disarm < exit_retain
    )


firewall_rule_fragments = (
    "filter INPUT -p tcp --dport 65431 -m comment --comment "
    "argo-rr-managed-block -j DROP",
    "nat PREROUTING -p udp --dport 65432 -m comment --comment "
    "argo-rr-audit-fixture -j REDIRECT --to-ports 65431",
    "filter INPUT -p tcp --dport 65433 -m comment --comment "
    "rr-audit-user-sentinel -j ACCEPT",
    "nat PREROUTING -p udp --dport 65434 -m comment --comment "
    "rr-audit-user-sentinel -j REDIRECT --to-ports 65433",
)


def target_helper_is_strict(body):
    if not durable_helper_common_is_strict(body, "C"):
        return False
    normalized = normalized_shell(body)
    required = (
        "firewall_lock_fd=",
        "lock_directory_is_safe() {",
        "lock_file_is_safe() {",
        "acquire_firewall_lock() {",
        "release_firewall_lock() {",
        "/run/rr-vps/locks/firewall.lock",
        "0:0:600:1:0",
        "%d:%i:%u:%g:%h",
        'flock -w 60 "$firewall_lock_fd"',
        'flock -u "$firewall_lock_fd"',
        "clean_backend() {",
        "assert_backend_clean() {",
        "persist_firewall_cleanup() {",
        "netfilter-persistent save >/dev/null 2>&1",
        "service iptables save >/dev/null 2>&1",
        "/root/rr-audit-panel-pass",
    )
    if any(fragment not in body for fragment in required):
        return False
    for rule in firewall_rule_fragments:
        if normalized.count(
            'remove_audit_rule_all "$backend" ' + rule
        ) != 1:
            return False
        if normalized.count(
            'assert_audit_rule_absent "$backend" ' + rule
        ) != 1:
            return False
    if normalized.count("for backend in iptables ip6tables; do") != 2:
        return False
    if any(fixed_path_count(body, target) != 2
           for target in target_cleanup_targets):
        return False
    acquire = body.index("\nacquire_firewall_lock\n")
    clean = body.index('clean_backend "$backend"', acquire)
    first_proof = body.index('assert_backend_clean "$backend"', clean)
    persist = body.index("persist_firewall_cleanup", first_proof)
    second_loop = body.index(
        "for backend in iptables ip6tables; do", persist
    )
    second_proof = body.index('assert_backend_clean "$backend"', second_loop)
    release = body.index("release_firewall_lock", second_proof)
    artifact_remove = body.index(
        "/usr/bin/rm -f -- /run/rr-audit-cross-passphrase", release
    )
    mode_gate = body.index(
        'if [ "$cleanup_mode" = timer ]; then', artifact_remove
    )
    disarm = body.index("self_disarm", mode_gate)
    retain = body.index("validate_bundle", disarm)
    return (
        acquire < clean < first_proof < persist < second_loop
        < second_proof < release < artifact_remove < mode_gate < disarm < retain
    )


def arm_is_durable(block, slot, helper_sha, job_timeout):
    body = embedded_cleanup_helper(block, slot)[0]
    if hashlib.sha256(body.encode()).hexdigest() != helper_sha:
        return False
    if slot == "A":
        if not source_helper_is_strict(body):
            return False
    elif not target_helper_is_strict(body):
        return False
    state_dir = a_state_dir if slot == "A" else c_state_dir
    suffix = slot.lower()
    required = (
        f"state_dir={state_dir}",
        f"expected_helper_sha={helper_sha}",
        "date -u -d '+75 minutes' +%s",
        "OnCalendar=$deadline_calendar",
        "OnActiveSec=5m",
        "OnUnitInactiveSec=5m",
        "Persistent=true",
        "AccuracySec=1s",
        "RandomizedDelaySec=0",
        "StartLimitIntervalSec=0",
        "Restart=on-failure",
        "RestartSec=30s",
        "ExecStart=$helper timer",
        'sha256sum "$service_file" "$timer_file"',
        "sha256sum --check --strict",
        'systemctl enable --now "$timer_unit"',
        'test "$(systemctl show -p UnitFileState --value "$timer_unit")" = enabled',
        'test "$(systemctl show -p Transient --value "$timer_unit")" = no',
        'test "$(systemctl show -p UnitFileState --value "$service_unit")" = static',
        'test "$(systemctl show -p Transient --value "$service_unit")" = no',
        'test "$(systemctl show -p Restart --value "$service_unit")" = on-failure',
        'test "$(systemctl show -p RestartUSec --value "$service_unit")" = 30s',
        'test "$(systemctl show -p StartLimitIntervalUSec --value "$service_unit")" = 0',
        f"timer_unit=rr-audit-cross-cleanup-{suffix}.timer",
        f"service_unit=rr-audit-cross-cleanup-{suffix}.service",
        'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit',
        'expected_exec_prefix="{ path=$helper ; argv[]=$helper timer ; "',
    )
    if any(fragment not in block for fragment in required):
        return False
    if any(fragment in block for fragment in (
        "systemd-run --quiet", "--on-active=", "StartLimitBurst",
        "StartLimitIntervalSec=10m", "Transient --value \"$timer_unit\")\" = yes",
        "/run/rr-audit-cross-cleanup-",
    )):
        return False
    if block.count('systemctl disable --now "$timer_unit"') != 2:
        return False
    if job_timeout + 10 > 75:
        return False
    helper_write = block.index(
        f"<<'RR_{slot}_CLEANUP_HELPER'"
    )
    deadline = block.index("date -u -d '+75 minutes'", helper_write)
    service_write = block.index(
        '(set -C; tee "$service_tmp"', deadline
    )
    timer_write = block.index(
        '(set -C; tee "$timer_tmp"', service_write
    )
    hashes = block.index(
        'sha256sum "$service_file" "$timer_file"', timer_write
    )
    reload_units = block.index("systemctl daemon-reload", hashes)
    enable = block.index('systemctl enable --now "$timer_unit"', reload_units)
    helper_probe = block.index(
        'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit', enable
    )
    runtime = block.index(
        'test "$(systemctl show -p LoadState --value "$timer_unit")"',
        helper_probe,
    )
    return (
        helper_write < deadline < service_write < timer_write < hashes
        < reload_units < enable < helper_probe < runtime
    )


def full_firewall_cleanup_is_ordered(block, *, product_lock=False):
    normalized = normalized_shell(block)
    try:
        if product_lock:
            acquire = block.index("\n            rr_firewall_lock_acquire\n")
            release = block.index("rr_firewall_lock_release")
            trap = block.index("trap release_fixture_lock EXIT", acquire)
            persist = block.index("persist_rr_firewall_fixture true", acquire)
            proof = block.index(
                "for backend in iptables ip6tables; do", persist
            )
            return release < acquire < trap < persist < proof
        acquire = block.index("\n                acquire_firewall_lock\n")
        first_remove = block.index(
            'remove_audit_rule_all "$backend"', acquire
        )
        first_proof = block.index('assert_backend_clean "$backend"', first_remove)
        persist = min(position for position in (
            block.find("netfilter-persistent save", first_proof),
            block.find("service iptables save", first_proof),
        ) if position >= 0)
        second_loop = block.index(
            "for backend in iptables ip6tables; do", persist
        )
        second_proof = block.index(
            'assert_backend_clean "$backend"', second_loop
        )
        release = block.index("release_firewall_lock", second_proof)
    except (ValueError, StopIteration):
        return False
    for rule in firewall_rule_fragments:
        if normalized.count(
            'remove_audit_rule_all "$backend" ' + rule
        ) < 1:
            return False
    return (
        acquire < first_remove < first_proof < persist
        < second_loop < second_proof < release
    )


def audit_sensitive_cleanup_contract(candidate):
    try:
        timeout_values = [int(value) for value in re.findall(
            r"(?m)^    timeout-minutes: ([0-9]+)$", candidate
        )]
        if timeout_values != [60]:
            return False
        job_timeout = timeout_values[0]
        source_arm, _, _ = heredoc_body(
            candidate, "<<'REMOTE_A_ARM'\n", "          REMOTE_A_ARM\n"
        )
        target_arm, _, _ = heredoc_body(
            candidate, "<<'REMOTE_C_ARM'\n", "          REMOTE_C_ARM\n"
        )
        source_finalize, _, _ = heredoc_body(
            candidate, "<<'REMOTE_A_FINALIZE'\n", "          REMOTE_A_FINALIZE\n"
        )
        source_recover, _, _ = heredoc_body(
            candidate, "<<'REMOTE_A_RECOVER'\n", "          REMOTE_A_RECOVER\n"
        )
        remote_c_candidate, _, _ = heredoc_body(
            candidate,
            "            \"$backup_sha\" \"$fingerprint_sha\" <<'REMOTE_C'\n",
            "          REMOTE_C\n",
        )
        a_helper = embedded_cleanup_helper(source_arm, "A")[0]
        c_helper = embedded_cleanup_helper(target_arm, "C")[0]
        a_sha = hashlib.sha256(a_helper.encode()).hexdigest()
        c_sha = hashlib.sha256(c_helper.encode()).hexdigest()
        if candidate.count(a_sha) != 3 or candidate.count(c_sha) != 3:
            return False
        if "PLACEHOLDER" in candidate:
            return False
        if not arm_is_durable(source_arm, "A", a_sha, job_timeout):
            return False
        if not arm_is_durable(target_arm, "C", c_sha, job_timeout):
            return False
        source_preclean_start = source_arm.index(
            "          rm -f -- /run/rr-audit-cross-passphrase",
            source_arm.index("          install -d -o root -g root -m 700 \"$state_dir\""),
        )
        source_preclean_end = source_arm.index(
            "\n\n          live_sha=", source_preclean_start
        )
        source_preclean = source_arm[source_preclean_start:source_preclean_end]
        if any(fixed_path_count(source_preclean, target) != 2
               for target in source_ordinary_targets):
            return False
        forbidden = (
            "/run/rr-audit-cross-cleanup-a",
            "/run/.rr-audit-cross-cleanup-a.new",
            "/run/rr-audit-cross-cleanup-c",
            "/run/.rr-audit-cross-cleanup-c.new",
            "systemd-run --quiet --unit=rr-audit-cross-cleanup",
            "StartLimitBurst",
            "StartLimitIntervalSec=10m",
        )
        if any(fragment in candidate for fragment in forbidden):
            return False

        if f"expected_helper_sha={a_sha}" not in source_finalize:
            return False
        finalize_required = (
            f"state_dir={a_state_dir}",
            "validate_bundle",
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit',
            "rm -f -- /root/rr-audit-cross-source-config",
            'systemctl disable --now "$timer_unit"',
            'rm -f -- "$service_file" "$timer_file"',
            "systemctl daemon-reload",
            'rm -f -- "$unit_hashes" "$deadline_file" "$helper"',
            'rmdir "$state_dir"',
            "StartLimitIntervalUSec --value",
            'argv[]=$helper timer',
        )
        if any(fragment not in source_finalize for fragment in finalize_required):
            return False
        helper_call = source_finalize.index(
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit'
        )
        evidence_remove = source_finalize.index(
            "rm -f -- /root/rr-audit-cross-source-config", helper_call
        )
        evidence_absence = source_finalize.index(
            "for evidence in /root/rr-audit-cross-source-config",
            evidence_remove,
        )
        disable = source_finalize.index(
            'systemctl disable --now "$timer_unit"', evidence_absence
        )
        unit_remove = source_finalize.index(
            'rm -f -- "$service_file" "$timer_file"', disable
        )
        reload_units = source_finalize.index(
            "systemctl daemon-reload", unit_remove
        )
        helper_remove = source_finalize.index(
            'rm -f -- "$unit_hashes" "$deadline_file" "$helper"',
            reload_units,
        )
        if not (
            helper_call < evidence_remove < evidence_absence < disable
            < unit_remove < reload_units < helper_remove
        ):
            return False

        recover_required = (
            f"state_dir={a_state_dir}",
            f"expected_helper_sha={a_sha}",
            "validate_bundle",
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit',
            'rm -f -- "$source_config" "$source_hash" "$source_hash_tmp" "$recover_tmp"',
            'systemctl disable --now "$timer_unit"',
            'rm -f -- "$service_file" "$timer_file"',
            "systemctl daemon-reload",
            'rm -f -- "$unit_hashes" "$deadline_file" "$helper"',
            "/root/rr-audit-panel-pass",
            'StartLimitIntervalUSec --value "$service_unit")" = 0',
        )
        if any(fragment not in source_recover for fragment in recover_required):
            return False
        recover_helper = source_recover.index(
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit'
        )
        recover_evidence = source_recover.index(
            'rm -f -- "$source_config" "$source_hash"', recover_helper
        )
        recover_disable = source_recover.index(
            'systemctl disable --now "$timer_unit"', recover_evidence
        )
        if not recover_helper < recover_evidence < recover_disable:
            return False

        outer_start = candidate.index(
            "          cleanup_audit_target_state() {\n"
        )
        outer_end = candidate.index(
            "\n          cleanup_cross_audit() {\n", outer_start
        )
        outer = candidate[outer_start:outer_end]
        if not full_firewall_cleanup_is_ordered(outer):
            return False
        outer_required = (
            "/root/rr-audit-panel-pass",
            f"state_dir={c_state_dir}",
            f"expected_helper_sha={c_sha}",
            "validate_unit_hashes() {",
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit',
            'systemctl disable --now "$timer_unit"',
            'rm -f -- "$service_file" "$timer_file"',
            "systemctl daemon-reload",
            'rm -f -- "$unit_hashes" "$deadline_file" "$helper"',
            "StartLimitIntervalUSec --value",
            'argv[]=$helper timer',
        )
        if any(fragment not in outer for fragment in outer_required):
            return False
        artifact_remove = outer.index(
            "                rm -f -- /run/rr-audit-cross-passphrase",
        )
        firewall_release = outer.rindex(
            "\n                release_firewall_lock\n", 0, artifact_remove
        )
        bundle_helper = outer.index(
            'RR_AUDIT_HELPER_SHA="$expected_helper_sha" "$helper" exit',
            artifact_remove,
        )
        outer_disable = outer.index(
            'systemctl disable --now "$timer_unit"', bundle_helper
        )
        if not firewall_release < artifact_remove < bundle_helper < outer_disable:
            return False
        if any(fragment in outer[firewall_release:artifact_remove] for fragment in (
            "netfilter-persistent save", "service iptables save",
        )):
            return False

        disarm_start = remote_c_candidate.index(
            "          disarm_target_cleanup_timer() {"
        )
        disarm_end = remote_c_candidate.index(
            "          finish_target_audit() {", disarm_start
        )
        disarm = remote_c_candidate[disarm_start:disarm_end]
        disarm_required = (
            "validate_cleanup_bundle",
            'UnitFileState --value "$timer_unit")" = enabled',
            'Transient --value "$timer_unit")" = no',
            'Restart --value "$service_unit")" = on-failure',
            'RestartUSec --value "$service_unit")" = 30s',
            'StartLimitIntervalUSec --value',
            '= 0',
            'argv[]=$cleanup_helper timer',
            'systemctl disable --now "$timer_unit"',
            'rm -f -- "$cleanup_service_file" "$cleanup_timer_file"',
            "systemctl daemon-reload",
            'rm -f -- "$cleanup_unit_hashes" "$cleanup_deadline" "$cleanup_helper"',
            'rmdir "$cleanup_state_dir"',
        )
        if any(fragment not in disarm for fragment in disarm_required):
            return False
        validate = disarm.index("validate_cleanup_bundle")
        disable = disarm.index('systemctl disable --now "$timer_unit"', validate)
        unit_remove = disarm.index(
            'rm -f -- "$cleanup_service_file" "$cleanup_timer_file"', disable
        )
        reload_units = disarm.index("systemctl daemon-reload", unit_remove)
        helper_remove = disarm.index(
            'rm -f -- "$cleanup_unit_hashes" "$cleanup_deadline" "$cleanup_helper"',
            reload_units,
        )
        if not validate < disable < unit_remove < reload_units < helper_remove:
            return False

        finish_start = remote_c_candidate.index(
            "          finish_target_audit() {\n"
        )
        finish_end = remote_c_candidate.index(
            "          trap finish_target_audit EXIT\n", finish_start
        )
        finish = remote_c_candidate[finish_start:finish_end]
        finish_required = (
            "helper_cleanup_ok=false firewall_cleanup_ok=false",
            "sensitive_cleanup_ok=false",
            "validate_cleanup_bundle &&",
            '"$cleanup_helper" exit',
            "helper_cleanup_ok=true",
            "firewall_cleanup_ok=true",
            "sensitive_cleanup_ok=true",
            "/root/rr-audit-panel-pass",
            '[ "$helper_cleanup_ok" = true ] &&',
            '[ "$firewall_cleanup_ok" = true ] &&',
            '[ "$sensitive_cleanup_ok" = true ]; then',
            "disarm_target_cleanup_timer",
        )
        if any(fragment not in finish for fragment in finish_required):
            return False
        if "if ! disarm_target_cleanup_timer" in finish:
            return False
        helper_call = finish.index('"$cleanup_helper" exit')
        sensitive_proof = finish.index("for sensitive_file", helper_call)
        all_flags = finish.index(
            '[ "$helper_cleanup_ok" = true ] &&', sensitive_proof
        )
        finish_disarm = finish.index(
            "disarm_target_cleanup_timer", all_flags
        )
        if not helper_call < sensitive_proof < all_flags < finish_disarm:
            return False

        install_start = remote_c_candidate.index(
            "          install_rr_firewall_fixture() ("
        )
        install_end = remote_c_candidate.index(
            "          audit_update_channel_value() {", install_start
        )
        install = remote_c_candidate[install_start:install_end]
        if not full_firewall_cleanup_is_ordered(
            install, product_lock=True
        ):
            return False
        for fragment in (
            "trap release_fixture_lock EXIT",
            "rr_firewall_lock_acquire",
            "rr_firewall_lock_release",
            "persist_rr_firewall_fixture true",
            '[ "$backend_count" -eq 2 ] || return 1',
        ):
            if fragment not in install:
                return False

        return True
    except (AssertionError, ValueError, StopIteration):
        return False


assert audit_sensitive_cleanup_contract(migration)


def panel_credential_cleanup_contract(candidate):
    if "> /root/rr-audit-panel-pass" in candidate:
        return False
    if len(re.findall(r"(?m)^\s+unset panel_pass$", candidate)) != 3:
        return False
    for match in re.finditer(r"(?m)^\s+unset panel_pass$", candidate):
        tail = candidate[match.end():match.end() + 240]
        for fragment in (
            "rm -f -- /root/rr-audit-panel-pass",
            "test ! -e /root/rr-audit-panel-pass",
            "test ! -L /root/rr-audit-panel-pass",
        ):
            if fragment not in tail:
                return False
    audit_exit_blocks = re.findall(
        r"(?ms)^\s+audit_exit\(\) \{.*?^\s+\}\n\s+trap audit_exit EXIT",
        candidate,
    )
    if len(audit_exit_blocks) != 5:
        return False
    for block in audit_exit_blocks:
        if "rm -f -- /root/rr-audit-panel-pass" not in block:
            return False
        if "[ -e /root/rr-audit-panel-pass ]" not in block:
            return False
        if "[ -L /root/rr-audit-panel-pass ]" not in block:
            return False
    return True


assert panel_credential_cleanup_contract(vps)

source_arm_block, source_arm_start, source_arm_end = heredoc_body(
    migration, "<<'REMOTE_A_ARM'\n", "          REMOTE_A_ARM\n"
)
target_arm_block, target_arm_start, target_arm_end = heredoc_body(
    migration, "<<'REMOTE_C_ARM'\n", "          REMOTE_C_ARM\n"
)
source_finalize_block, source_finalize_start, source_finalize_end = heredoc_body(
    migration, "<<'REMOTE_A_FINALIZE'\n", "          REMOTE_A_FINALIZE\n"
)
source_recover_block, source_recover_start, source_recover_end = heredoc_body(
    migration, "<<'REMOTE_A_RECOVER'\n", "          REMOTE_A_RECOVER\n"
)
remote_c_block, remote_c_block_start, remote_c_block_end = heredoc_body(
    migration,
    "            \"$backup_sha\" \"$fingerprint_sha\" <<'REMOTE_C'\n",
    "          REMOTE_C\n",
)


def replace_block(value, start, end, replacement):
    return value[:start] + replacement + value[end:]


sensitive_mutations = []


def mutate_block(block, old, new):
    changed = block.replace(old, new, 1)
    assert changed != block
    return changed


for block, start, end, old, new in (
    (
        source_arm_block, source_arm_start, source_arm_end,
        "StartLimitIntervalSec=0", "StartLimitIntervalSec=10m",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "Restart=on-failure", "Restart=no",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "Persistent=true", "Persistent=false",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "OnActiveSec=5m", "# reboot wakeup removed",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "date -u -d '+75 minutes'", "date -u -d '+60 minutes'",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "/usr/bin/systemctl restart rr-nexus.service",
        "/usr/bin/systemctl start rr-nexus.service",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "/usr/bin/systemctl restart argo-rr-health.timer",
        "/usr/bin/systemctl start argo-rr-health.timer",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "          wait_local_nexus\n", "          : # readiness removed\n",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "          /usr/bin/systemctl restart rr-nexus.service\n"
        "          assert_unit_state rr-nexus.service loaded:active:enabled\n"
        "          /usr/bin/systemctl restart argo-rr-health.timer\n"
        "          assert_unit_state argo-rr-health.timer loaded:active:enabled\n"
        "          wait_local_nexus\n",
        "          restore_runtime=false\n"
        "          if [ \"$restore_runtime\" = true ]; then\n"
        "            /usr/bin/systemctl restart rr-nexus.service\n"
        "            assert_unit_state rr-nexus.service loaded:active:enabled\n"
        "            /usr/bin/systemctl restart argo-rr-health.timer\n"
        "            assert_unit_state argo-rr-health.timer loaded:active:enabled\n"
        "            wait_local_nexus\n"
        "          fi\n",
    ),
    (
        source_arm_block, source_arm_start, source_arm_end,
        "/usr/bin/systemctl daemon-reload",
        ": # helper daemon reload removed",
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        'flock -w 60 "$firewall_lock_fd"',
        ': # global firewall flock removed',
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        "          persist_firewall_cleanup\n",
        "          persist_firewall_cleanup || true\n",
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        "Persistent=true", "Persistent=false",
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        "StartLimitIntervalSec=0", "StartLimitIntervalSec=10m",
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        "ExecStart=$helper timer", "ExecStart=$helper",
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        'remove_audit_rule_all "$backend" filter INPUT -p tcp --dport 65431',
        ': # v4/v6 TCP fixture delete removed\n            #',
    ),
    (
        target_arm_block, target_arm_start, target_arm_end,
        "/usr/bin/systemctl daemon-reload",
        ": # helper daemon reload removed",
    ),
):
    sensitive_mutations.append(replace_block(
        migration, start, end, mutate_block(block, old, new)
    ))

sensitive_mutations.append(migration.replace(
    'if [ "$helper_cleanup_ok" = true ] && \\\n'
    '               [ "$firewall_cleanup_ok" = true ] && \\\n'
    '               [ "$sensitive_cleanup_ok" = true ]; then',
    'if [ "$sensitive_cleanup_ok" = true ]; then',
    1,
))
sensitive_mutations.append(migration.replace(
    '               RR_AUDIT_HELPER_SHA="$expected_cleanup_helper_sha" \\\n'
    '                 "$cleanup_helper" exit >/dev/null 2>&1 && \\\n',
    '               : && \\\n',
    1,
))
sensitive_mutations.append(migration.replace(
    "                acquire_firewall_lock\n",
    "                : # outer global lock removed\n",
    1,
))
sensitive_mutations.append(migration.replace(
    "                release_firewall_lock\n",
    "                release_firewall_lock\n"
    "                netfilter-persistent save >/dev/null 2>&1\n",
    1,
))
sensitive_mutations.append(migration.replace(
    '          systemctl disable --now "$timer_unit"\n',
    '          : # A persistent timer disarm removed\n',
    1,
))
sensitive_mutations.append(migration.replace(
    "              disarm_target_cleanup_timer\n",
    "              if ! disarm_target_cleanup_timer; then :; fi\n",
    1,
))
for mutated in sensitive_mutations:
    assert mutated != migration
    assert not audit_sensitive_cleanup_contract(mutated)

panel_disk_mutation = vps.replace(
    "          unset panel_pass\n",
    "          (umask 077; printf '%s\\n' \"$panel_pass\" > "
    "/root/rr-audit-panel-pass)\n          unset panel_pass\n",
    1,
)
panel_exit_mutation = vps.replace(
    "            if ! rm -f -- /root/rr-audit-panel-pass; then rc=1; fi\n",
    "            : # audit EXIT credential cleanup removed\n",
    1,
)
panel_symlink_mutation = vps.replace(
    "          test ! -L /root/rr-audit-panel-pass\n",
    "          : # panel credential symlink absence proof removed\n",
    1,
)
assert panel_disk_mutation != vps
assert panel_exit_mutation != vps
assert panel_symlink_mutation != vps
assert not panel_credential_cleanup_contract(panel_disk_mutation)
assert not panel_credential_cleanup_contract(panel_exit_mutation)
assert not panel_credential_cleanup_contract(panel_symlink_mutation)


def run_flock_serialization_probe():
    with tempfile.TemporaryDirectory() as temporary:
        lock = Path(temporary) / "firewall.lock"
        log = Path(temporary) / "order.log"
        script = r'''
set -euo pipefail
(
  exec 9<>"$1"
  flock -w 2 9
  printf '%s\n' first-start >>"$2"
  sleep 0.2
  printf '%s\n' first-end >>"$2"
) &
first=$!
sleep 0.05
(
  exec 8<>"$1"
  flock -w 2 8
  printf '%s\n' second >>"$2"
) &
second=$!
wait "$first" "$second"
'''
        result = subprocess.run(
            ["bash", "-s", "--", str(lock), str(log)],
            input=script,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        records = log.read_text(encoding="utf-8").splitlines()
        return result.returncode, records


flock_rc, flock_records = run_flock_serialization_probe()
assert flock_rc == 0
assert flock_records == ["first-start", "first-end", "second"]

capture_start = remote_c.index("capture_full_firewall_state() {")
capture_end = remote_c.index(
    "persist_rr_firewall_fixture() {", capture_start
)
capture_contract = remote_c[capture_start:capture_end]
for fragment in (
    "/run/rr-audit-cross-firewall-before-validate)",
    "temporary=/run/rr-audit-cross-firewall-before-validate.tmp",
    "/run/rr-audit-cross-firewall-after-validate)",
    "temporary=/run/rr-audit-cross-firewall-after-validate.tmp",
    '(set -C; : > "$temporary")',
    '"$(stat -c \'%u:%g:%a:%h\' "$temporary")" = 0:0:600:1',
    'mv -fT -- "$temporary" "$output"',
):
    assert fragment in capture_contract
assert "mktemp" not in capture_contract
assert "/^# Generated by ip(6)?tables-save .* on .+$/d" in capture_contract
assert "/^# Completed on .+$/d" in capture_contract

persist_start = capture_end
persist_end = remote_c.index(
    "install_rr_firewall_fixture() (", persist_start
)
persist_contract = remote_c[persist_start:persist_end]


def run_persistence_failure_probe(candidate, service_backend=False):
    with tempfile.TemporaryDirectory() as temporary:
        command_name = "service" if service_backend else "netfilter-persistent"
        mock = Path(temporary) / command_name
        mock.write_text("#!/bin/sh\nexit 41\n", encoding="utf-8")
        mock.chmod(0o700)
        environment = os.environ.copy()
        environment["PATH"] = f"{temporary}:/usr/bin:/bin"
        prefix = ""
        body = candidate
        if service_backend:
            prefix = r'''
command() {
    if [ "$1" = -v ] && [ "$2" = netfilter-persistent ]; then return 1; fi
    builtin command "$@"
}
'''
            body = body.replace("[ -x /etc/init.d/iptables ]", "true", 1)
        result = subprocess.run(
            ["bash"],
            input=prefix + textwrap.dedent(body)
                + "\npersist_rr_firewall_fixture true\n",
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
        )
        return result.returncode


assert run_persistence_failure_probe(persist_contract) == 41
assert run_persistence_failure_probe(persist_contract, True) == 41
for command in (
    "netfilter-persistent save >/dev/null 2>&1",
    "service iptables save >/dev/null 2>&1",
):
    swallowed = persist_contract.replace(command, command + " || true", 1)
    assert swallowed != persist_contract
    if command.startswith("service"):
        assert run_persistence_failure_probe(swallowed, True) == 0
    else:
        assert run_persistence_failure_probe(swallowed) == 0

fixture_start = remote_c.index("install_rr_firewall_fixture() (")
fixture_end = remote_c.index(
    "audit_update_channel_value() {", fixture_start
)
fixture_contract = remote_c[fixture_start:fixture_end]
for fragment in (
    "rr_firewall_lock_acquire",
    "trap release_fixture_lock EXIT",
    "rr_firewall_lock_release",
    "persist_rr_firewall_fixture true",
    '[ "$backend_count" -eq 2 ] || return 1',
):
    assert fragment in fixture_contract
fixture_acquire = fixture_contract.index("rr_firewall_lock_acquire")
fixture_persist = fixture_contract.index(
    "persist_rr_firewall_fixture true", fixture_acquire
)
fixture_postproof = fixture_contract.index(
    "for backend in iptables ip6tables; do", fixture_persist
)
assert fixture_acquire < fixture_persist < fixture_postproof

channel_helper_text = """          audit_update_channel_value() {
            local value=stable
            if [ -e /etc/rr-update/channel ] || [ -L /etc/rr-update/channel ]; then
              [ -f /etc/rr-update/channel ] && [ ! -L /etc/rr-update/channel ] || return 1
              test "$(stat -c '%U:%G:%a:%h' /etc/rr-update/channel)" = root:root:600:1 || return 1
              value=$(tr -d '[:space:]' < /etc/rr-update/channel) || return 1
              case "$value" in stable|beta) ;; *) return 1 ;; esac
            fi
            printf '%s\\n' "$value"
          }
"""
assert migration.count(channel_helper_text) == 1
channel_helper = migration.index(channel_helper_text, remote_c_start, remote_c_end)
channel_snapshot_text = (
    "          audit_update_channel_value > /run/rr-audit-cross-target-channel\n"
)
channel_compare_text = (
    "          audit_update_channel_value \\\n"
    "            | cmp -s /run/rr-audit-cross-target-channel -\n"
)
assert migration.count(channel_snapshot_text) == 1
assert migration.count(channel_compare_text) == 1
channel_snapshot = migration.index(channel_snapshot_text)
cross_restore = migration.index(
    'timeout --kill-after=10 300 /usr/local/bin/rr restore "$backup_file"',
    channel_snapshot,
)
channel_compare = migration.index(channel_compare_text, cross_restore)
assert channel_helper < channel_snapshot < cross_restore < channel_compare < remote_c_end
assert "cp -p /etc/rr-update/channel" not in migration
assert "cmp -s /etc/rr-update/channel" not in migration
assert "NAIVE_ENABLED=false" in migration
assert "expected_private" in migration and "expected_public" in migration
for dependency in (
    "debian-full",
    "ubuntu-upgrade",
    "ubuntu-transaction",
    "cross-machine-migration-scale",
    "public-ip-acme",
):
    assert f"      - {dependency}\n" in gate
assert "M_RESULT: ${{ needs.cross-machine-migration-scale.result }}" in gate
assert "IP_RESULT: ${{ needs.public-ip-acme.result }}" in gate
push_gate = gate[gate.index("            push)"):gate.index(
    "            workflow_dispatch)"
)]
dispatch_gate = gate[gate.index("            workflow_dispatch)"):]
for result in ("A", "B", "C", "M"):
    assert f'test "${result}_RESULT" = success' in push_gate
    assert f'test "${result}_RESULT" = skipped' in dispatch_gate
assert 'test "$IP_RESULT" = skipped' in push_gate
assert 'test "$IP_RESULT" = success' in dispatch_gate
assert "github.event_name == 'workflow_dispatch'" in ip_audit
assert "pinned SSH host keys" in vps
assert "TOFU" not in vps
assert not re.search(r"\bsystemctl\s+is-(?:active|enabled)\b", vps)
for line in vps.splitlines():
    if line.lstrip().startswith("! "):
        assert "||" in line, f"bare negated assertion can pass under errexit: {line}"
assert not re.search(r"!\s+ss\b", vps)
assert not re.search(r"if\s+ss\b[^\n]*\|", vps)
assert not re.search(r"if\s+journalctl\b[^\n]*\|", vps)
assert not re.search(r'test\s+-z\s+"\$\(', vps)
assert 'rules=$("$backend" -w 5 -t raw -S PREROUTING 2>/dev/null || true)' not in vps
assert "test-uninstall-quarantine.sh|\\" in ci

lines = release.splitlines()
start = lines.index("          assert_workflow_gate() (")
end = lines.index("          assert_immutable_releases_enabled() {", start)
functions = "\n".join(line[10:] for line in lines[start:end]) + "\n"
Path(sys.argv[4]).write_text(functions, encoding="utf-8")
PY

# shellcheck source=/dev/null
source "$TEST_ROOT/assert-workflow-gate.sh"
EXPECTED_SHA=0123456789abcdef0123456789abcdef01234567
GITHUB_REPOSITORY=example/rr-vps
fixture="$TEST_ROOT/runs.json"
api_log="$TEST_ROOT/api.log"
MAIN_SHA="$EXPECTED_SHA"
api() {
    printf '%s\n' "$*" > "$api_log"
    case "$1" in
        */git/ref/heads/main) printf '%s\n' "$MAIN_SHA" ;;
        *) cat "$fixture" ;;
    esac
}

write_run() {
    local sha="$1" branch="$2" event="$3" status="$4" conclusion="$5" attempt="$6"
    jq -n --arg sha "$sha" --arg branch "$branch" --arg event "$event" \
        --arg status "$status" --arg conclusion "$conclusion" --argjson attempt "$attempt" \
        '{total_count:1,workflow_runs:[{id:4101,run_number:41,run_attempt:$attempt,head_sha:$sha,
          head_branch:$branch,event:$event,status:$status,conclusion:$conclusion}]}' > "$fixture"
}

write_release_runs() {
    jq -n --arg sha "$EXPECTED_SHA" '{total_count:2,workflow_runs:[
      {id:4101,run_number:41,run_attempt:2,head_sha:$sha,head_branch:"main",
       event:"push",status:"completed",conclusion:"success"},
      {id:4201,run_number:42,run_attempt:1,head_sha:$sha,head_branch:"main",
       event:"workflow_dispatch",status:"completed",conclusion:"success"}
    ]}' > "$fixture"
}

printf '%s\n' '[1/6] exact successful main push is accepted through a SHA-filtered query'
write_run "$EXPECTED_SHA" main push completed success 1
assert_workflow_gate ci.yml push "CI push"
[[ "$(cat "$api_log")" == *"head_sha=${EXPECTED_SHA}"* ]]

printf '%s\n' '[2/6] wrong SHA, branch, event, status, and conclusion fail closed'
for mutation in sha branch event status conclusion; do
    write_run "$EXPECTED_SHA" main push completed success 1
    case "$mutation" in
        sha) write_run 1123456789abcdef0123456789abcdef01234567 main push completed success 1 ;;
        branch) write_run "$EXPECTED_SHA" beta push completed success 1 ;;
        event) write_run "$EXPECTED_SHA" main workflow_dispatch completed success 1 ;;
        status) write_run "$EXPECTED_SHA" main push in_progress success 1 ;;
        conclusion) write_run "$EXPECTED_SHA" main push completed failure 1 ;;
    esac
    if assert_workflow_gate ci.yml push "CI push" >/dev/null 2>&1; then
        echo "Release gate accepted invalid ${mutation}." >&2
        exit 1
    fi
done

printf '%s\n' '[3/6] a newer failed rerun supersedes an older success'
jq -n --arg sha "$EXPECTED_SHA" '{total_count:2,workflow_runs:[
  {id:4101,run_number:41,run_attempt:1,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"success"},
  {id:4102,run_number:41,run_attempt:2,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"failure"}
]}' > "$fixture"
if assert_workflow_gate vps-audit.yml push 'VPS audit push' >/dev/null 2>&1; then
    echo 'Release gate accepted a SHA whose latest attempt failed.' >&2
    exit 1
fi

printf '%s\n' '[4/6] a newer successful rerun is accepted'
jq '.workflow_runs[1].conclusion = "success"' "$fixture" > "$fixture.next"
mv "$fixture.next" "$fixture"
assert_workflow_gate vps-audit.yml push 'VPS audit push'

printf '%s\n' '[5/6] empty workflow evidence is rejected'
printf '%s\n' '{"total_count":0,"workflow_runs":[]}' > "$fixture"
if assert_workflow_gate ci.yml push "CI push" >/dev/null 2>&1; then
    echo 'Release gate accepted missing CI evidence.' >&2
    exit 1
fi

printf '%s\n' '[6/6] release mutation gate rejects an advanced main tip'
write_release_runs
MAIN_SHA="$EXPECTED_SHA"
assert_release_gate
MAIN_SHA=1123456789abcdef0123456789abcdef01234567
if assert_release_gate >/dev/null 2>&1; then
    echo 'Release gate accepted an obsolete main tip.' >&2
    exit 1
fi

printf '%s\n' 'release gate regression: PASS'
