#!/usr/bin/env bash
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'ERROR: root required' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /root/rr-test-firewall-recovery.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077

# Real root-owned files, production marker/evidence predicates and production
# reentrant flock. Systemd, process discovery, snapshot format/live comparison
# and native firewall application are explicit fixtures: this test never calls
# host service management, iptables, or the real native recovery function.
# shellcheck source=../modules/10-system.sh
source "$repo/modules/10-system.sh"
python3 - "$repo/scripts/repair-v723-naive-first-install.sh" "$fixture" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2])
definitions = source[source.index('repair_note() {'):source.index('\n# The environment was cleared')]
for prefix in ('/etc/', '/var/lib/', '/run/rr-vps'):
    definitions = definitions.replace(prefix, str(root) + prefix)
# Preserve the actual capture implementation, but both its path probes and its
# archive root must refer exclusively to this fixture, including relative paths.
assert '"/$path"' in definitions and 'tar -C / -czf' in definitions
definitions = definitions.replace('"/$path"', '"' + str(root) + '/$path"')
definitions = definitions.replace('tar -C / -czf', 'tar -C "' + str(root) + '" -czf')
(root / 'functions.sh').write_text(definitions)
PY
# shellcheck disable=SC1091
source "$fixture/functions.sh"

# Observe the actual release API while its owner process is still alive. A
# probe after the subprocess exits alone would also pass if it leaked its FD.
eval "$(declare -f rr_firewall_lock_release | sed '1s/rr_firewall_lock_release/fixture_original_firewall_lock_release/')"
rr_firewall_lock_release() {
    fixture_original_firewall_lock_release "$@" || return $?
    printf 'lock_released depth=%s descriptor=%s\n' \
        "${RR_FIREWALL_LOCK_DEPTH:-}" "${RR_FIREWALL_LOCK_FD:-}" >>"$fixture/events"
    if [ "${RR_FIREWALL_LOCK_DEPTH:-}" = 0 ]; then
        [ -z "${RR_FIREWALL_LOCK_FD:-}" ] && flock -n "$RR_FIREWALL_LOCK_FILE" true || return 91
    fi
    return 0
}

RR_FIREWALL_LOCK_FILE="$fixture/locks/firewall.lock"
RR_FIREWALL_QUARANTINE_DIR="$fixture/var/lib/rr-vps"
RR_FIREWALL_QUARANTINE_FILE="$RR_FIREWALL_QUARANTINE_DIR/firewall-quarantine"
CONFIG_FILE="$fixture/etc/argo_vmess.conf"
NEXUS_CONFIG_FILE="$fixture/etc/rr-nexus/nexus.json"
NEXUS_DB_FILE="$fixture/var/lib/rr-nexus/nexus.db"
marker="$RR_FIREWALL_QUARANTINE_FILE"
evidence="$RR_FIREWALL_QUARANTINE_DIR/firewall-evidence"
node_config="$fixture/etc/sing-box/config.json"
gate="$fixture/etc/systemd/system/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf"
repair_recover_firewall=true
repair_check_only=false
cases=0

forbidden() { printf '%s\n' "$*" >>"$fixture/forbidden"; return 90; }
repair_verify_runtime() { [ "$1" = check ]; }
managed_singbox_running() { return 1; }
subscription_server_running() { return 1; }
quick_argo_running() { return 1; }
load_config_with_defaults() { forbidden load_config_with_defaults; }
repair_capture() { forbidden repair_capture; }
repair_add_missing_unit() { forbidden repair_add_missing_unit; }
setup_systemd() { forbidden setup_systemd; }
build_config() { forbidden build_config; }
start_singbox() { forbidden start_singbox; }
start_subscription_server() { forbidden start_subscription_server; }
start_quick_argo() { forbidden start_quick_argo; }

systemctl() {
    [ "${1:-}" = show ] || { forbidden systemctl_mutation; return 90; }
    if [ "$#" -eq 5 ] && [ "$3" = -p ] && [ "$5" = --value ]; then
        case "$4" in
            LoadState)
                if [ "$scenario" = recorded_load_mismatch ] && [ "$2" = argo-rr-health.service ]; then
                    printf 'loaded\n'
                else printf 'not-found\n'; fi ;;
            FragmentPath|DropInPaths) printf '\n' ;;
            UnitFileState)
                if [ "$2" = rr-firewall-quarantine-guard.path ]; then
                    if [ "$scenario" = guard_disabled ]; then printf 'disabled\n';
                    else printf 'enabled\n'; fi
                else printf '\n'; fi ;;
            ActiveState) printf 'inactive\n' ;;
            *) forbidden systemctl_property; return 90 ;;
        esac
    elif [ "${*: -1}" = --no-pager ]; then
        printf 'Id=fixture-only\nLoadState=not-found\nActiveState=inactive\n'
    else forbidden systemctl_arguments; return 90; fi
}
journalctl() { printf 'FIXTURE_JOURNAL_ONLY\n'; }
function iptables-save() {
    [ "$scenario" != backup_iptables_failure ] || return 71
    printf '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n'
}
function ip6tables-save() { printf '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n'; }
tar() {
    if [ "${1:-}" = -C ]; then
        [ "${2:-}" = "$fixture" ] || { forbidden tar_nonfixture_root; return 90; }
        [ "$scenario" != backup_tar_failure ] || return 72
    fi
    command tar "$@"
}
# The on-disk firewall snapshot layout and live kernel policy are deliberately
# represented by separate sentinels; the production evidence function still
# checks the real root metadata, complete marker, config SHA256 and namespace.
rr_restore_require_firewall_snapshot_v2() {
    [ "$1" = "$evidence" ] && [ "$scenario" != snapshot_format_failure ] &&
        [ "$(cat "$1/snapshot.fixture")" = fixture-snapshot-v2 ]
}
rr_firewall_write_desired_namespace() {
    printf 'protocol|open|443|tcp\n' >"$1" && chmod 600 "$1"
}
rr_restore_verify_firewall_pre_mutation_snapshot() {
    rr_firewall_lock_is_held || { forbidden live_check_without_lock; return 90; }
    printf 'live_check\n' >>"$fixture/events"
    [ "$1" = "$evidence" ] && [ "$scenario" != live_mismatch ]
}
rr_firewall_quarantine_supervisor_effective() { [ "$scenario" != guard_mismatch ]; }
rr_firewall_repair_fail_closed_quarantine() {
    printf 'native_apply\n' >>"$fixture/events"
    rr_firewall_lock_is_held && [ "$RR_FIREWALL_LOCK_DEPTH" -eq 1 ] || return 91
    rr_firewall_lock_acquire && [ "$RR_FIREWALL_LOCK_DEPTH" -eq 2 ] || return 91
    # A distinct open file description must be excluded by the real outer lock.
    if flock -n "$RR_FIREWALL_LOCK_FILE" true; then forbidden lock_not_exclusive; return 91; fi
    [ -f "$repair_stage/firewall-backup.sha256" ] || return 92
    sha256sum -c "$repair_stage/firewall-backup.sha256" >/dev/null || return 92
    command tar -tzf "$repair_stage/firewall-before.tar.gz" >"$fixture/archive-members"
    grep -Fxq var/lib/rr-vps/firewall-quarantine "$fixture/archive-members" || return 92
    grep -Fxq var/lib/rr-vps/firewall-evidence/config.sha256 "$fixture/archive-members" || return 92
    command tar -xOzf "$repair_stage/firewall-before.tar.gz" etc/argo_vmess.conf |
        cmp -s "$CONFIG_FILE" - || return 92
    command tar -xOzf "$repair_stage/firewall-before.tar.gz" etc/sing-box/config.json |
        cmp -s "$node_config" - || return 92
    command tar -xOzf "$repair_stage/firewall-before.tar.gz" var/lib/rr-vps/firewall-quarantine |
        cmp -s "$marker" - || return 92
    printf 'backup_verified_before_simulated_mutation\n' >>"$fixture/events"
    if [ "$scenario" = native_failure ]; then
        rr_firewall_lock_release || return 91
        return 37
    fi
    # Simulate a native function that fails before releasing its nested depth;
    # the wrapper's EXIT cleanup must release only the same BASHPID's real lock.
    [ "$scenario" != native_failure_nested_lock ] || return 38
    [ "$scenario" = success ] || { forbidden unexpected_native_apply; return 90; }
    rm -- "$marker" && rm -r -- "$evidence" || return 93
    rr_firewall_lock_release
}

reset_fixture() {
    scenario="$1"
    rm -rf -- "$fixture/etc" "$fixture/var" "$fixture/run" "$fixture/stage"
    rm -f -- "$fixture/events" "$fixture/forbidden" "$fixture/archive-members"
    for path in etc/systemd/system/sing-box.service.d var/lib/rr-vps \
        etc/sing-box etc/rr-naive etc/letsencrypt run/rr-vps; do
        install -d -m 755 -- "$fixture/$path"
    done
    chmod 700 "$RR_FIREWALL_QUARANTINE_DIR"
    install -d -m 700 "$evidence" "$fixture/stage"
    repair_stage="$fixture/stage"
    printf 'SENSITIVE_CONFIG_SENTINEL\n' >"$CONFIG_FILE"
    printf 'SENSITIVE_NODE_SENTINEL\n' >"$node_config"
    printf '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
        "$marker" "$marker" >"$gate"
    chmod 600 "$CONFIG_FILE" "$node_config"
    chmod 644 "$gate"
    {
        printf 'firewall-quarantine-v2\n'
        for unit in sing-box.service rr-nexus.service rr-subscription.service \
            argo-rr-health.service argo-rr-health.timer; do
            printf 'unit\t%s\tnot-found\tinactive\tnot-found\n' "$unit"
        done
        printf 'runtime\tsingbox\tfalse\nruntime\tsubscription\tfalse\nevidence\tfirewall-evidence-v1\n'
    } >"$marker"
    sha256sum "$CONFIG_FILE" | awk '{print $1}' >"$evidence/config.sha256"
    rr_firewall_write_desired_namespace "$evidence/desired.namespace"
    printf 'firewall-evidence-v1\n' >"$evidence/evidence.complete"
    printf 'fixture-snapshot-v2\n' >"$evidence/snapshot.fixture"
    chmod 600 "$marker" "$evidence"/*
}

run_case() {
    local expected_rc="$1" expected_reason="$2" result=0
    sha256sum "$CONFIG_FILE" "$node_config" "$gate" >"$fixture/config-before.sha256"
    sha256sum "$marker" "$evidence"/* >"$fixture/evidence-before.sha256"
    (exec 3>"$fixture/$scenario.out"; repair_locked) >"$fixture/$scenario.private.log" 2>&1 || result=$?
    if [ "$result" -ne "$expected_rc" ]; then
        printf 'FAIL scenario=%s expected_rc=%s actual_rc=%s\n' "$scenario" "$expected_rc" "$result" >&2
        cat "$fixture/$scenario.out" "$fixture/$scenario.private.log" >&2
        return 1
    fi
    grep -Fq "$expected_reason" "$fixture/$scenario.out"
    [ ! -e "$fixture/forbidden" ]
    [ ! -e "$fixture/etc/systemd/system/sing-box.service" ]
    ! grep -q 'SENSITIVE_' "$fixture/$scenario.out"
    sha256sum -c "$fixture/config-before.sha256" >/dev/null
    if [ "$scenario" = success ]; then
        [ ! -e "$marker" ] && [ ! -e "$evidence" ]
    else
        sha256sum -c "$fixture/evidence-before.sha256" >/dev/null
        ! grep -q FIREWALL_RECOVERY_COMPLETE "$fixture/$scenario.out"
    fi
    if [ -e "$RR_FIREWALL_LOCK_FILE" ]; then
        flock -n "$RR_FIREWALL_LOCK_FILE" true
    fi
    if grep -Fq 'REPAIR_STEP phase=firewall_marker_under_lock' "$fixture/$scenario.out"; then
        grep -Fxq 'lock_released depth=0 descriptor=' "$fixture/events"
    fi
    case "$scenario" in
        success|native_failure|native_failure_nested_lock)
            [ "$(grep -Fc native_apply "$fixture/events")" -eq 1 ]
            grep -Fq backup_verified_before_simulated_mutation "$fixture/events"
            ;;
        *) [ ! -e "$fixture/events" ] || ! grep -q native_apply "$fixture/events" ;;
    esac
    cases=$((cases + 1))
}

reset_fixture inflight
sed -i '1s/firewall-quarantine-v2/firewall-inflight-v1/' "$marker"
run_case 1 orphan_inflight_requires_inspection

reset_fixture unavailable
sed -i 's/evidence\tfirewall-evidence-v1/evidence\tunavailable/' "$marker"
run_case 1 evidence_unavailable

reset_fixture malformed
printf 'unexpected-record\n' >>"$marker"
run_case 1 marker_line_count

reset_fixture recorded_active
sed -i 's/unit\targo-rr-health.service\tnot-found\tinactive\tnot-found/unit\targo-rr-health.service\tloaded\tactive\tenabled/' "$marker"
run_case 1 recorded_unit_would_start

reset_fixture recorded_runtime
sed -i 's/runtime\tsingbox\tfalse/runtime\tsingbox\ttrue/' "$marker"
run_case 1 recorded_runtime_would_start

reset_fixture config_mismatch
printf 'SENSITIVE_CHANGED_CONFIG\n' >>"$CONFIG_FILE"
run_case 1 configuration_changed_since_snapshot

reset_fixture namespace_mismatch
printf 'protocol|open|444|tcp\n' >"$evidence/desired.namespace"
run_case 1 desired_namespace_matches=false

reset_fixture evidence_metadata
chmod 644 "$evidence/snapshot.fixture"
run_case 1 'REPAIR_STOP phase=firewall_evidence_binding'

reset_fixture snapshot_format_failure
run_case 1 'REPAIR_STOP phase=firewall_evidence_binding'

reset_fixture recorded_load_mismatch
run_case 1 'REPAIR_STOP phase=firewall_recorded_idle_state'

reset_fixture live_mismatch
run_case 1 'REPAIR_STOP phase=firewall_live_snapshot'

reset_fixture guard_mismatch
run_case 1 'REPAIR_STOP phase=firewall_guard_effective'

reset_fixture guard_disabled
run_case 1 'REPAIR_STOP phase=firewall_guard_path_enabled'

reset_fixture backup_tar_failure
run_case 1 'REPAIR_STOP phase=firewall_preserve_evidence'

reset_fixture backup_iptables_failure
run_case 1 'REPAIR_STOP phase=firewall_preserve_evidence'

reset_fixture native_failure
run_case 37 'firewall_recovery_attempted=true'

reset_fixture native_failure_nested_lock
run_case 38 'cleanup_uncertain=false'

reset_fixture success
run_case 0 'FIREWALL_RECOVERY_COMPLETE configuration=unchanged nodes=inactive nexus=not_installed'

printf 'REPAIR_FIREWALL_RECOVERY_PASS cases=%s marker_parser=production evidence_metadata_and_config_hash=production flock=production systemd=fixture snapshot=fixture native_apply=fixture actual_firewall_changes=false\n' "$cases"
