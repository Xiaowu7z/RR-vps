#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RECOVER="$REPO_ROOT/scripts/update-recover.sh"
TEST_ROOT=$(mktemp -d /tmp/rr-update-recover-ip-acme.XXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$1"
}
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
private_marker() {
    (umask 077; : > "$1")
    chmod 600 "$1"
}
writer_markers() {
    local backup="$1" marker=""
    for marker in ip_acme_was_present ip_acme_was_ready \
        ip_acme_timer_was_enabled ip_acme_timer_was_running; do
        private_marker "$backup/$marker"
    done
}
make_state_tree() {
    local root="$1" email="${2:-ops@example.com}"
    mkdir -p "$root"
    chmod 700 "$root"
    printf 'rr-nexus-ip-acme-v1\n' > "$root/.rr-nexus-ip-acme-owner"
    chmod 600 "$root/.rr-nexus-ip-acme-owner"
    printf '{"address":"8.8.8.8","email":"%s","version":1}\n' "$email" > "$root/config.json"
    chmod 600 "$root/config.json"
}
make_webroot_tree() {
    local root="$1"
    mkdir -p "$root/.well-known/acme-challenge"
    chmod 755 "$root" "$root/.well-known" "$root/.well-known/acme-challenge"
    printf 'rr-nexus-ip-acme-webroot-v1\n' > "$root/.rr-nexus-ip-acme-owner"
    chmod 600 "$root/.rr-nexus-ip-acme-owner"
}

bash -n "$RECOVER"
pass 'standalone recovery helper parses'

(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    tx="$TEST_ROOT/contracts/transactions/tx"
    backup="$tx/backup"
    mkdir -p "$backup"
    chmod 700 "$TEST_ROOT/contracts" "$TEST_ROOT/contracts/transactions" "$tx" "$backup"

    state=0
    rr_ip_acme_writer_contract_state "$backup" || state=$?
    [ "$state" -eq 1 ] || fail 'markerless writer contract was not legacy/no-op'
    writer_markers "$backup"
    rr_ip_acme_writer_contract_state "$backup" || fail 'complete writer quartet was rejected'
    rr_ip_acme_phase_contract_is_safe "$tx" snapshotting || \
        fail 'snapshotting incorrectly required directory snapshots'
    if rr_ip_acme_phase_contract_is_safe "$tx" prepared; then
        fail 'prepared accepted a missing directory-complete marker'
    fi

    private_marker "$backup/ip_acme_directories_complete"
    private_marker "$backup/had_nexus_ip_acme_state"
    private_marker "$backup/had_nexus_ip_acme_webroot"
    make_state_tree "$backup/nexus_ip_acme_state"
    make_webroot_tree "$backup/nexus_ip_acme_webroot"
    rr_ip_acme_external_snapshot_is_complete() { return 0; }
    rr_ip_acme_phase_contract_is_safe "$tx" prepared || \
        fail 'prepared rejected a complete IP-ACME snapshot'

    chmod 644 "$backup/ip_acme_was_ready"
    state=0
    rr_ip_acme_writer_contract_state "$backup" || state=$?
    [ "$state" -eq 2 ] || fail '0644 writer marker was accepted'
    chmod 600 "$backup/ip_acme_was_ready"
    rm -f "$backup/ip_acme_timer_was_running"
    state=0
    rr_ip_acme_writer_contract_state "$backup" || state=$?
    [ "$state" -eq 2 ] || fail 'partial writer quartet was accepted'

    legacy="$TEST_ROOT/contracts/transactions/legacy"
    mkdir -p "$legacy/backup"
    chmod 700 "$legacy" "$legacy/backup"
    rr_ip_acme_phase_contract_is_safe "$legacy" prepared || \
        fail 'old markerless transaction lost compatibility'
    private_marker "$legacy/backup/had_nexus_ip_acme_state"
    if rr_ip_acme_phase_contract_is_safe "$legacy" snapshotting; then
        fail 'orphan directory evidence without writer markers was accepted'
    fi
)
pass 'phase-aware writer and snapshot markers fail closed without breaking legacy transactions'

(
    fixture="$TEST_ROOT/early-quartet"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$fixture/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$fixture/run/update-maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    tx="$RR_TX_ROOT/transactions/tx"
    backup="$tx/backup"
    mkdir -p "$backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    chmod 700 "$RR_TX_ROOT" "$RR_TX_ROOT/transactions" "$tx" "$backup" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    printf '2\n' > "$tx/transaction-format"
    printf 'snapshotting\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    printf '%s\n' "$tx" > "$RR_UPDATE_MAINTENANCE_FILE"
    private_marker "$backup/writer_state_complete"
    writer_markers "$backup"
    chmod 600 "$tx/transaction-format" "$tx/phase" "$RR_ACTIVE_TX" \
        "$RR_UPDATE_MAINTENANCE_FILE"

    restore_attempts=0
    health_freezes=0
    ip_freezes=0
    rr_restore_recorded_writer_state() {
        restore_attempts=$((restore_attempts + 1))
        [ "$restore_attempts" -gt 1 ]
    }
    rr_freeze_health_writers_strict() { health_freezes=$((health_freezes + 1)); }
    rr_freeze_ip_acme_writer_if_recorded() {
        rr_ip_acme_writer_contract_state "$1" || return 1
        ip_freezes=$((ip_freezes + 1))
    }
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$(cat "$tx/phase")" = snapshotting ] && \
        [ -e "$RR_ACTIVE_TX" ] && [ -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'quartet recovery failure did not retain its retryable phase and gates'
    [ "$health_freezes:$ip_freezes" = 1:1 ] || \
        fail 'quartet recovery failure did not freeze both writer classes'
    main recover || fail 'quartet recovery did not succeed on the next boot'
    [ "$restore_attempts" -eq 2 ] && [ "$(cat "$tx/phase")" = aborted ] && \
        [ ! -e "$RR_ACTIVE_TX" ] && [ ! -e "$RR_UPDATE_MAINTENANCE_FILE" ] || \
        fail 'quartet recovery retry did not converge to a durable abort'
)
pass 'IP writer quartet survives an early failure and succeeds on the next boot'

(
    fixture="$TEST_ROOT/maintenance-failure"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_UPDATE_LOCK_HELD=1
    export RR_TX_ROOT="$fixture/update"
    export RR_ACTIVE_TX="$RR_TX_ROOT/active"
    export RR_UPDATE_MAINTENANCE_FILE="$fixture/run/update-maintenance"
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    tx="$RR_TX_ROOT/transactions/tx"
    mkdir -p "$tx/backup" "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    chmod 700 "$RR_TX_ROOT" "$RR_TX_ROOT/transactions" "$tx" "$tx/backup" \
        "$(dirname "$RR_UPDATE_MAINTENANCE_FILE")"
    printf 'runtime_swapped\n' > "$tx/phase"
    printf '%s\n' "$tx" > "$RR_ACTIVE_TX"
    chmod 600 "$tx/phase" "$RR_ACTIVE_TX"
    health_freezes=0
    ip_freezes=0
    restore_called=0
    rr_prepare_legacy_lock_for_rollback() { return 0; }
    rr_ensure_update_maintenance_marker() { return 1; }
    rr_freeze_health_writers_strict() { health_freezes=$((health_freezes + 1)); }
    rr_freeze_ip_acme_writer_if_recorded() { ip_freezes=$((ip_freezes + 1)); }
    rr_restore_transaction() { restore_called=$((restore_called + 1)); return 99; }
    set +e
    main recover
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ "$health_freezes:$ip_freezes:$restore_called" = 1:1:0 ] || \
        fail 'automatic rollback gate failure did not freeze both writers before returning'
    [ "$(cat "$tx/phase")" = runtime_swapped ] && [ -e "$RR_ACTIVE_TX" ] || \
        fail 'automatic rollback gate failure discarded retry evidence'
)
pass 'automatic rollback gate failure freezes health and IP writers'

(
    fixture="$TEST_ROOT/directories"
    mkdir -p "$fixture/live" "$fixture/backup"
    chmod 700 "$fixture" "$fixture/live" "$fixture/backup"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_IP_ACME_STATE_ROOT="$fixture/live/state"
    export RR_IP_ACME_WEBROOT="$fixture/live/webroot"
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    rr_ip_acme_external_snapshot_is_complete() { return 0; }

    writer_markers "$fixture/backup"
    private_marker "$fixture/backup/ip_acme_directories_complete"
    private_marker "$fixture/backup/had_nexus_ip_acme_state"
    private_marker "$fixture/backup/had_nexus_ip_acme_webroot"
    make_state_tree "$fixture/backup/nexus_ip_acme_state" restored@example.com
    make_webroot_tree "$fixture/backup/nexus_ip_acme_webroot"
    make_state_tree "$RR_IP_ACME_STATE_ROOT" candidate@example.com
    make_webroot_tree "$RR_IP_ACME_WEBROOT"
    rr_restore_ip_acme_directories_if_recorded "$fixture/backup" || \
        fail 'owned same-host directory replay failed'
    grep -Fq restored@example.com "$RR_IP_ACME_STATE_ROOT/config.json" || \
        fail 'state snapshot was not restored'

    # Simulate SIGKILL after target->retired and prove the next boot converges.
    mv -T "$RR_IP_ACME_STATE_ROOT" "${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-old"
    rr_restore_ip_acme_directories_if_recorded "$fixture/backup" || \
        fail 'directory replay did not converge after an interrupted rename'
    [ ! -e "${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-old" ] || \
        fail 'retired state survived the idempotent retry'

    # Simulate power loss after stage->target, while the old target and both
    # durable sidecars still remain.  This is the second rename window.
    second_stage="${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-new"
    second_stage_owner="${second_stage}.owner"
    second_retired="${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-old"
    second_retired_owner="${second_retired}.owner"
    rr_ip_acme_publish_recovery_owner_marker "$second_stage_owner" stage state \
        "$RR_IP_ACME_STATE_ROOT" "$fixture/backup/nexus_ip_acme_state" || \
        fail 'could not publish second-window stage ownership'
    cp -a "$fixture/backup/nexus_ip_acme_state" "$second_stage"
    rr_ip_acme_publish_recovery_owner_marker "$second_retired_owner" retired state \
        "$RR_IP_ACME_STATE_ROOT" "$RR_IP_ACME_STATE_ROOT" || \
        fail 'could not publish second-window retired ownership'
    mv -T "$RR_IP_ACME_STATE_ROOT" "$second_retired"
    mv -T "$second_stage" "$RR_IP_ACME_STATE_ROOT"
    rr_restore_ip_acme_directories_if_recorded "$fixture/backup" || \
        fail 'directory replay did not converge after the second rename window'
    [ ! -e "$second_stage_owner" ] && [ ! -e "$second_retired" ] && \
        [ ! -e "$second_retired_owner" ] || \
        fail 'second rename-window evidence survived the converged retry'

    # A sidecar published before cp authorizes cleanup even when power loss
    # leaves too little of the staged tree to satisfy the final schema.
    partial_stage="${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-new"
    partial_stage_owner="${partial_stage}.owner"
    rr_ip_acme_publish_recovery_owner_marker "$partial_stage_owner" stage state \
        "$RR_IP_ACME_STATE_ROOT" "$fixture/backup/nexus_ip_acme_state" || \
        fail 'could not publish the copy-stage recovery owner'
    mkdir -m 700 "$partial_stage"
    install -m 600 "$fixture/backup/nexus_ip_acme_state/.rr-nexus-ip-acme-owner" \
        "$partial_stage/.rr-nexus-ip-acme-owner"
    rr_restore_ip_acme_directories_if_recorded "$fixture/backup" || \
        fail 'directory replay did not recover an interrupted partial copy'
    [ ! -e "$partial_stage" ] && [ ! -e "$partial_stage_owner" ] || \
        fail 'partial copy evidence survived a converged retry'

    # The sidecar also survives a recursive-delete interruption after the new
    # target is live, so a partial retired tombstone remains safely removable.
    partial_retired="${RR_IP_ACME_STATE_ROOT}.rr-update-recovery-old"
    partial_retired_owner="${partial_retired}.owner"
    rr_ip_acme_publish_recovery_owner_marker "$partial_retired_owner" retired state \
        "$RR_IP_ACME_STATE_ROOT" "$RR_IP_ACME_STATE_ROOT" || \
        fail 'could not publish the retired-tree recovery owner'
    mkdir -m 700 "$partial_retired"
    install -m 600 "$fixture/backup/nexus_ip_acme_state/.rr-nexus-ip-acme-owner" \
        "$partial_retired/.rr-nexus-ip-acme-owner"
    rr_restore_ip_acme_directories_if_recorded "$fixture/backup" || \
        fail 'directory replay did not recover an interrupted retired-tree delete'
    [ ! -e "$partial_retired" ] && [ ! -e "$partial_retired_owner" ] || \
        fail 'partial retired-tree evidence survived a converged retry'

    victim="$fixture/victim"
    mkdir -p "$victim"
    printf 'survive\n' > "$victim/sentinel"
    attack_parent="$fixture/attack-parent"
    ln -s "$victim" "$attack_parent"
    RR_IP_ACME_STATE_ROOT="$attack_parent/state"
    RR_IP_ACME_WEBROOT="$attack_parent/webroot"
    if rr_restore_ip_acme_directories_if_recorded "$fixture/backup"; then
        fail 'symlinked live parent was accepted'
    fi
    [ "$(cat "$victim/sentinel")" = survive ] || fail 'symlink victim was modified'
)
pass 'owned directory replay is canonical, non-following, and SIGKILL-idempotent'

(
    fixture="$TEST_ROOT/absent"
    mkdir -p "$fixture/live" "$fixture/new-backup" "$fixture/legacy-backup"
    chmod 700 "$fixture" "$fixture/live" "$fixture/new-backup" "$fixture/legacy-backup"
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    export RR_IP_ACME_STATE_ROOT="$fixture/live/state"
    export RR_IP_ACME_WEBROOT="$fixture/live/webroot"
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    rr_ip_acme_external_contract_state() {
        [ "$1" = "$fixture/new-backup" ] && return 0
        return 1
    }
    rr_ip_acme_external_absent_snapshot_is_complete() { return 0; }
    private_marker "$fixture/new-backup/ip_acme_directories_complete"
    make_state_tree "$RR_IP_ACME_STATE_ROOT" candidate@example.com
    make_webroot_tree "$RR_IP_ACME_WEBROOT"
    rr_restore_ip_acme_directories_if_recorded "$fixture/new-backup" || \
        fail 'authoritative absent snapshot could not remove owned candidate trees'
    [ ! -e "$RR_IP_ACME_STATE_ROOT" ] && [ ! -e "$RR_IP_ACME_WEBROOT" ] || \
        fail 'candidate-created trees survived an absent rollback snapshot'

    make_state_tree "$RR_IP_ACME_STATE_ROOT" legacy@example.com
    make_webroot_tree "$RR_IP_ACME_WEBROOT"
    rr_restore_ip_acme_directories_if_recorded "$fixture/legacy-backup" || \
        fail 'legacy markerless directory restore returned failure'
    [ -d "$RR_IP_ACME_STATE_ROOT" ] && [ -d "$RR_IP_ACME_WEBROOT" ] || \
        fail 'legacy markerless transaction mutated IP-ACME paths'
)
pass 'new absent snapshots remove only owned candidate trees while legacy snapshots remain no-op'

(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    backup="$TEST_ROOT/rearm/backup"
    mkdir -p "$backup"
    chmod 700 "$TEST_ROOT/rearm" "$backup"
    writer_markers "$backup"
    log="$TEST_ROOT/rearm.log"
    : > "$log"
    timer_enabled=disabled
    timer_active=inactive
    timer_sub=dead
    service_active=inactive
    service_sub=dead
    service_pid=0
    start_fails=false
    active_race=false
    freeze_count=0

    rr_ip_acme_rearm_guard_is_active() { printf 'guard\n' >> "$log"; }
    rr_ip_acme_runtime_readonly_is_ready() { printf 'readonly\n' >> "$log"; }
    rr_freeze_ip_acme_writer_if_recorded() {
        freeze_count=$((freeze_count + 1))
        printf 'freeze\n' >> "$log"
        timer_enabled=disabled
        timer_active=inactive
        timer_sub=dead
        service_active=inactive
        service_sub=dead
        service_pid=0
    }
    systemctl() {
        local action="${1:-}" unit="" property="" arg=""
        shift || true
        printf 'systemctl %s %s\n' "$action" "$*" >> "$log"
        case "$action" in
            enable) timer_enabled=enabled; return 0 ;;
            start)
                [ "$start_fails" = false ] || return 1
                timer_active=active
                timer_sub=waiting
                if [ "$active_race" = true ]; then
                    service_active=active
                    service_sub=running
                    service_pid=42
                fi
                return 0
                ;;
            show)
                for arg in "$@"; do
                    case "$arg" in
                        rr-nexus-ip-acme.timer|rr-nexus-ip-acme.service) unit="$arg" ;;
                        LoadState|ActiveState|SubState|MainPID|UnitFileState) property="$arg" ;;
                    esac
                done
                case "$unit:$property" in
                    rr-nexus-ip-acme.timer:LoadState|rr-nexus-ip-acme.service:LoadState) printf 'loaded\n' ;;
                    rr-nexus-ip-acme.timer:ActiveState) printf '%s\n' "$timer_active" ;;
                    rr-nexus-ip-acme.timer:SubState) printf '%s\n' "$timer_sub" ;;
                    rr-nexus-ip-acme.timer:UnitFileState) printf '%s\n' "$timer_enabled" ;;
                    rr-nexus-ip-acme.service:ActiveState) printf '%s\n' "$service_active" ;;
                    rr-nexus-ip-acme.service:SubState) printf '%s\n' "$service_sub" ;;
                    rr-nexus-ip-acme.service:MainPID) printf '%s\n' "$service_pid" ;;
                    rr-nexus-ip-acme.service:UnitFileState) printf 'static\n' ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    rr_restore_ip_acme_writer_state "$backup" || fail 'exact timer rearm failed'
    [ "$timer_enabled:$timer_active:$timer_sub:$service_active:$service_sub:$service_pid" = \
      enabled:active:waiting:inactive:dead:0 ] || fail 'timer/service final state was not exact'
    [ "$freeze_count" -eq 1 ] || fail 'success path did not perform one clean disarm before rearm'
    grep -Eq '^freeze$' "$log" || fail 'rearm did not freeze first'
    if grep -Eq 'renew|lego|acme-install' "$log"; then
        fail 'recovery invoked signing/CA code'
    fi

    : > "$log"
    start_fails=true
    freeze_count=0
    if rr_restore_ip_acme_writer_state "$backup"; then
        fail 'timer start failure was accepted'
    fi
    [ "$freeze_count" -eq 2 ] || fail 'timer start failure did not re-isolate the writer'

    : > "$log"
    start_fails=false
    active_race=true
    freeze_count=0
    if rr_restore_ip_acme_writer_state "$backup"; then
        fail 'active service race was accepted'
    fi
    [ "$freeze_count" -eq 2 ] || fail 'active service race did not re-isolate the writer'
)
pass 'timer rearm is exact, CA-free, and isolates every start/service race failure'

(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    condition_script="[ ! -e /run/rr-vps/update-maintenance ] && [ ! -L /run/rr-vps/update-maintenance ] && [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ]"
    effective_condition="{ path=/bin/sh ; argv[]=/bin/sh -c $condition_script ; ignore_errors=no ; }"
    effective_start="{ path=$RR_IP_ACME_RR_BIN ; argv[]=$RR_IP_ACME_RR_BIN --nexus-ip-acme-renew ; ignore_errors=no ; }"
    systemctl() {
        local unit="${2:-}" property="${4:-}"
        [ "${1:-}" = show ] && [ "${3:-}" = -p ] && [ "${5:-}" = --value ] || \
            return 1
        case "$unit:$property" in
            rr-nexus-ip-acme.service:LoadState|rr-nexus-ip-acme.timer:LoadState) printf 'loaded\n' ;;
            rr-nexus-ip-acme.service:FragmentPath) printf '%s\n' "$RR_IP_ACME_SERVICE_FILE" ;;
            rr-nexus-ip-acme.timer:FragmentPath) printf '%s\n' "$RR_IP_ACME_TIMER_FILE" ;;
            rr-nexus-ip-acme.service:DropInPaths|rr-nexus-ip-acme.timer:DropInPaths) : ;;
            rr-nexus-ip-acme.service:UnitFileState) printf 'static\n' ;;
            rr-nexus-ip-acme.timer:UnitFileState) printf 'disabled\n' ;;
            rr-nexus-ip-acme.service:Type) printf 'oneshot\n' ;;
            rr-nexus-ip-acme.service:User|rr-nexus-ip-acme.service:Group) printf 'root\n' ;;
            rr-nexus-ip-acme.service:UMask) printf '0077\n' ;;
            rr-nexus-ip-acme.service:SuccessExitStatus) printf '75\n' ;;
            rr-nexus-ip-acme.service:ExecStart) printf '%s\n' "$effective_start" ;;
            rr-nexus-ip-acme.service:ExecCondition) printf '%s\n' "$effective_condition" ;;
            rr-nexus-ip-acme.service:ExecStartPre|rr-nexus-ip-acme.service:ExecStartPost|\
            rr-nexus-ip-acme.service:ExecReload|rr-nexus-ip-acme.service:ExecStop|\
            rr-nexus-ip-acme.service:ExecStopPost) : ;;
            *) return 1 ;;
        esac
    }
    grep -Fq "ExecCondition=/bin/sh -c '$condition_script'" \
        <(rr_render_ip_acme_service_unit) || fail 'recovery renderer omitted the exact maintenance gate'
    rr_ip_acme_effective_units_are_exact || \
        fail 'the exact effective maintenance ExecCondition was rejected'
    effective_condition='{ path=/bin/sh ; argv[]=/bin/sh -c true ; ignore_errors=no ; }'
    if rr_ip_acme_effective_units_are_exact; then
        fail 'a substituted effective maintenance ExecCondition was accepted'
    fi
)
pass 'service rearm requires the exact systemd maintenance ExecCondition'

build_external_snapshot() {
    local backup="$1" lego_size="$2" omit_path="${3:-}" contract="${4:-ready}"
    rm -rf -- "$backup/external-state"
    mkdir -p "$backup/external-state/items"
    chmod 700 "$backup/external-state" "$backup/external-state/items"
    python3 - "$backup/external-state" "$lego_size" "$omit_path" "$contract" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
lego_size = int(sys.argv[2])
omit = sys.argv[3]
contract = sys.argv[4]
spec = [
    ("/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf", "file", 0o644),
    ("/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf", "symlink", None),
    ("/usr/local/lib/rr-vps/nexus-ip-cert-gate", "file", 0o755),
    ("/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf", "file", 0o644),
    ("/etc/systemd/system/rr-nexus-ip-acme.service", "file", 0o644),
    ("/etc/systemd/system/rr-nexus-ip-acme.timer", "file", 0o644),
    ("/etc/rr-nexus/certs/ip.crt", "file", 0o644),
    ("/etc/rr-nexus/certs/ip.key", "file", 0o600),
    ("/etc/rr-nexus/certs/.ip-cert-pending", "missing", None),
    ("/usr/local/lib/rr-vps/lego", "file", 0o755),
    ("/usr/local/lib/rr-vps/lego.install", "file", 0o600),
]
if contract in {"legacy-namespace", "malformed-paths"}:
    spec = []
elif contract == "absent":
    spec = [(name, "missing", None) for name, _, _ in spec]
elif contract in {"legacy-pair", "legacy-gate", "legacy-half-gate"}:
    optional = {
        "/etc/rr-nexus/certs/ip.crt": ("file", 0o644),
        "/etc/rr-nexus/certs/ip.key": ("file", 0o600),
    }
    if contract in {"legacy-gate", "legacy-half-gate"}:
        optional["/usr/local/lib/rr-vps/nexus-ip-cert-gate"] = ("file", 0o755)
    if contract == "legacy-gate":
        optional["/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf"] = ("file", 0o644)
    spec = [(name, *optional.get(name, ("missing", None))) for name, _, _ in spec]
entries = []
for index, (name, kind, mode) in enumerate(spec):
    if name == omit:
        continue
    if kind == "missing":
        entries.append({"path": name, "kind": kind})
        continue
    if kind == "symlink":
        entries.append({
            "path": name,
            "kind": kind,
            "uid": 0,
            "gid": 0,
            "mode": 0o777,
            "target": "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
        })
        continue
    item = root / "items" / str(index)
    with item.open("wb") as stream:
        if name == "/usr/local/lib/rr-vps/lego":
            stream.truncate(lego_size)
        elif name == "/usr/local/lib/rr-vps/nexus-ip-cert-gate":
            stream.write(b'''#!/bin/sh
set -eu
[ "$#" -eq 3 ] || exit 1
cert_file=$1
key_file=$2
pending_file=$3
if [ -e "$pending_file" ] || [ -L "$pending_file" ]; then
    exit 1
fi
if [ ! -e "$cert_file" ] && [ ! -L "$cert_file" ] && \\
   [ ! -e "$key_file" ] && [ ! -L "$key_file" ]; then
    exit 0
fi
[ -f "$cert_file" ] && [ ! -L "$cert_file" ] && \\
    [ -f "$key_file" ] && [ ! -L "$key_file" ] || exit 1
openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || exit 1
openssl pkey -in "$key_file" -check -noout -passin pass: >/dev/null 2>&1 || exit 1
cert_public=$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | \\
    sha256sum | awk '{print $1}') || exit 1
key_public=$(openssl pkey -in "$key_file" -pubout 2>/dev/null | \\
    sha256sum | awk '{print $1}') || exit 1
[ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ]
''')
        elif name == "/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf":
            stream.write(
                b"[Service]\nExecCondition=/usr/local/lib/rr-vps/nexus-ip-cert-gate "
                b"/etc/rr-nexus/certs/ip.crt /etc/rr-nexus/certs/ip.key "
                b"/etc/rr-nexus/certs/.ip-cert-pending\n"
            )
        else:
            stream.write((name + "\n").encode())
    os.chmod(item, 0o600)
    digest = hashlib.sha256()
    with item.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    entries.append({
        "path": name,
        "kind": kind,
        "uid": 0,
        "gid": 0,
        "mode": mode,
        "item": str(index),
        "size": item.stat().st_size,
        "sha256": digest.hexdigest(),
    })
value = {
    "version": "rr-update-external-state-v2",
    "paths": "not-a-list" if contract == "malformed-paths" else entries,
}
raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
(root / "state.json").write_bytes(raw)
os.chmod(root / "state.json", 0o600)
(root / "complete").write_text(
    "rr-update-external-state-v2 " + hashlib.sha256(raw).hexdigest() + "\n",
    encoding="ascii",
)
os.chmod(root / "complete", 0o600)
PY
}

(
    export RR_UPDATE_RECOVER_SOURCE_ONLY=1
    # shellcheck source=../scripts/update-recover.sh
    source "$RECOVER"
    backup="$TEST_ROOT/external/backup"
    mkdir -p "$backup"
    chmod 700 "$TEST_ROOT/external" "$backup"
    private_marker "$backup/external_state_required"
    build_external_snapshot "$backup" $((17 * 1024 * 1024))
    rr_ip_acme_external_snapshot_is_complete "$backup" || \
        fail 'a valid >16 MiB lego snapshot was rejected'
    if rr_ip_acme_external_absent_snapshot_is_complete "$backup"; then
        fail 'an absent snapshot accepted restored ACME-exclusive artifacts'
    fi

    build_external_snapshot "$backup" 0 '' absent
    state=0
    rr_ip_acme_external_contract_state "$backup" || state=$?
    [ "$state" -eq 0 ] || fail 'the authenticated current IP namespace was not recognized'
    if rr_ip_acme_snapshot_contract_is_safe "$backup"; then
        fail 'current absent snapshot without directory-complete was downgraded to legacy'
    fi
    private_marker "$backup/ip_acme_directories_complete"
    rr_ip_acme_snapshot_contract_is_safe "$backup" || \
        fail 'current absent snapshot with its complete marker was rejected'
    rm -f "$backup/ip_acme_directories_complete"
    rr_ip_acme_external_absent_snapshot_is_complete "$backup" || \
        fail 'an exact all-missing absent snapshot was rejected'

    build_external_snapshot "$backup" 0 '' legacy-namespace
    state=0
    rr_ip_acme_external_contract_state "$backup" || state=$?
    [ "$state" -eq 1 ] || fail 'a genuinely old authenticated namespace lost compatibility'
    rr_ip_acme_snapshot_contract_is_safe "$backup" || \
        fail 'a genuinely old markerless transaction was rejected'

    build_external_snapshot "$backup" 0 '' malformed-paths
    state=0
    rr_ip_acme_external_contract_state "$backup" || state=$?
    [ "$state" -eq 2 ] || fail 'malformed authenticated paths were misclassified as legacy'

    build_external_snapshot "$backup" 0 '' legacy-pair
    rr_ip_acme_external_absent_snapshot_is_complete "$backup" || \
        fail 'a legacy pair with both gate files absent was rejected'
    build_external_snapshot "$backup" 0 '' legacy-gate
    rr_ip_acme_external_absent_snapshot_is_complete "$backup" || \
        fail 'a legacy pair with both exact gate files was rejected'
    build_external_snapshot "$backup" 0 '' legacy-half-gate
    if rr_ip_acme_external_absent_snapshot_is_complete "$backup"; then
        fail 'a legacy pair with a partial gate set was accepted'
    fi

    build_external_snapshot "$backup" $((73 * 1024 * 1024))
    if rr_ip_acme_external_snapshot_is_complete "$backup"; then
        fail 'an oversized >72 MiB lego snapshot was accepted'
    fi

    build_external_snapshot "$backup" $((17 * 1024 * 1024)) \
        /etc/systemd/system/rr-nexus-ip-acme.timer
    state=0
    rr_ip_acme_external_contract_state "$backup" || state=$?
    [ "$state" -eq 2 ] || fail 'a partial IP namespace was misclassified as legacy'
    if rr_ip_acme_external_snapshot_is_complete "$backup"; then
        fail 'a hash-consistent snapshot missing a fixed timer path was accepted'
    fi
)
pass 'external snapshot preflight authenticates fixed paths and the 72 MiB lego-only limit'

printf 'All %d update-recover IP-ACME tests passed.\n' "$pass_count"
