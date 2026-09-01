#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/rr-nexus-gate-rollback.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

RR_LIB_DIR="$TEST_ROOT/lib"
RR_REPOSITORY=test/repository
# shellcheck source=../modules/55-resilience.sh
source "$REPO_ROOT/modules/55-resilience.sh"
# shellcheck source=../modules/85-nexus.sh
source "$REPO_ROOT/modules/85-nexus.sh"

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$1"
}
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

write_gate_pair() {
    local script="$1" dropin="$2"
    install -d -m 755 "$(dirname -- "$script")" "$(dirname -- "$dropin")"
    nexus_emit_ip_certificate_gate_script > "$script"
    nexus_emit_ip_certificate_gate_dropin \
        "$RR_RESTORE_NEXUS_GATE_EXEC_PATH" \
        /etc/rr-nexus/certs/ip.crt /etc/rr-nexus/certs/ip.key \
        /etc/rr-nexus/certs/.ip-cert-pending > "$dropin"
    chmod 755 "$script"
    chmod 644 "$dropin"
}

SOURCE_SCRIPT="$TEST_ROOT/source/usr/local/lib/rr-vps/nexus-ip-cert-gate"
SOURCE_DROPIN="$TEST_ROOT/source/etc/systemd/system/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
DESTINATION="$TEST_ROOT/destination"
DEST_SCRIPT="$DESTINATION$RR_RESTORE_NEXUS_GATE_EXEC_PATH"
DEST_DROPIN="$DESTINATION/etc/systemd/system/nginx.service.d/$RR_RESTORE_NEXUS_GATE_DROPIN_NAME"
install -d -m 755 "$TEST_ROOT/source" "$DESTINATION"

# A 7.1 target has neither fixed artifact.  The candidate may create both, but
# rollback must restore absence in dependency-safe order (drop-in, then script).
ROLLBACK_ABSENT="$TEST_ROOT/rollback-absent"
install -d -m 700 "$ROLLBACK_ABSENT/rootfs"
rr_restore_capture_nexus_gate_artifacts \
    "$ROLLBACK_ABSENT" "$SOURCE_SCRIPT" "$SOURCE_DROPIN" || \
    fail 'legacy-absent gate state was not captured'
[ "$(rr_restore_nexus_gate_snapshot_state "$ROLLBACK_ABSENT")" = absent ] || \
    fail 'legacy-absent marker did not record absence'
write_gate_pair "$DEST_SCRIPT" "$DEST_DROPIN"
rr_restore_replay_nexus_gate_artifacts "$ROLLBACK_ABSENT" "$DESTINATION" || \
    fail 'legacy-absent gate state was not replayed'
[ ! -e "$DEST_SCRIPT" ] && [ ! -L "$DEST_SCRIPT" ] && \
    [ ! -e "$DEST_DROPIN" ] && [ ! -L "$DEST_DROPIN" ] || \
    fail 'candidate gate artifacts survived legacy rollback'
pass 'portable rollback restores a legacy target with no IP certificate gate'

# A current target snapshots both exact artifacts and can recreate them after
# candidate cleanup.  Snapshot files live only in the trusted rollback tree.
ROLLBACK_PRESENT="$TEST_ROOT/rollback-present"
install -d -m 700 "$ROLLBACK_PRESENT/rootfs"
write_gate_pair "$SOURCE_SCRIPT" "$SOURCE_DROPIN"
rr_restore_capture_nexus_gate_artifacts \
    "$ROLLBACK_PRESENT" "$SOURCE_SCRIPT" "$SOURCE_DROPIN" || \
    fail 'present gate state was not captured'
[ "$(rr_restore_nexus_gate_snapshot_state "$ROLLBACK_PRESENT")" = present ] || \
    fail 'present marker did not record presence'
rr_restore_replay_nexus_gate_artifacts "$ROLLBACK_PRESENT" "$DESTINATION" || \
    fail 'present gate state was not replayed'
cmp -s "$SOURCE_SCRIPT" "$DEST_SCRIPT" && \
    cmp -s "$SOURCE_DROPIN" "$DEST_DROPIN" || \
    fail 'present gate bytes were not restored exactly'
[ "$(stat -c %a "$DEST_SCRIPT")" = 755 ] && \
    [ "$(stat -c %a "$DEST_DROPIN")" = 644 ] || \
    fail 'present gate modes were not restored exactly'
pass 'portable rollback recreates an existing exact IP certificate gate'

# An unsafe live collision is rejected before either fixed path changes.
printf 'foreign\n' > "$DEST_SCRIPT"
chmod 755 "$DEST_SCRIPT"
before_dropin=$(sha256sum "$DEST_DROPIN" | awk '{print $1}')
if rr_restore_replay_nexus_gate_artifacts \
     "$ROLLBACK_ABSENT" "$DESTINATION" >/dev/null 2>&1; then
    fail 'rollback accepted a foreign fixed gate collision'
fi
grep -qx foreign "$DEST_SCRIPT" || fail 'failed preflight changed foreign script'
[ "$(sha256sum "$DEST_DROPIN" | awk '{print $1}')" = "$before_dropin" ] || \
    fail 'failed preflight changed the paired drop-in'
pass 'foreign fixed-path collisions fail closed before mutation'

# Half-installed source evidence is not a valid rollback snapshot.
rm -f "$SOURCE_DROPIN"
ROLLBACK_HALF="$TEST_ROOT/rollback-half"
install -d -m 700 "$ROLLBACK_HALF/rootfs"
if rr_restore_capture_nexus_gate_artifacts \
     "$ROLLBACK_HALF" "$SOURCE_SCRIPT" "$SOURCE_DROPIN" >/dev/null 2>&1; then
    fail 'half-installed source gate was accepted as a rollback snapshot'
fi
[ ! -e "$ROLLBACK_HALF/$RR_RESTORE_NEXUS_GATE_SNAPSHOT_NAME" ] || \
    fail 'failed half-state capture published a complete marker'
pass 'half-installed source gate evidence is rejected'

# Keep the production orchestration boundaries tied to the durable marker.
restore_body=$(declare -f rr_restore_backup_locked)
rollback_body=$(declare -f rr_restore_rollback_stage)
apply_body=$(declare -f rr_restore_apply_tree)
[[ "$restore_body" == *'rr_restore_capture_nexus_gate_artifacts "$rollback"'*'sync || result=1'* ]] || \
    fail 'gate capture no longer precedes durable rollback completion'
[[ "$apply_body" == *'rr_restore_replay_nexus_gate_artifacts "$root"'* ]] || \
    fail 'full rollback tree replay no longer restores the fixed gate state'
[[ "$rollback_body" == *'rr_restore_migrate_with_original_state "$rollback"'*'rr_restore_replay_nexus_gate_artifacts "$rollback" /'* ]] || \
    fail 'post-migration compensation no longer restores the original gate state'
pass 'capture, replay and post-migration compensation remain transaction-bound'

printf 'All %d Nexus gate rollback tests passed.\n' "$pass_count"
