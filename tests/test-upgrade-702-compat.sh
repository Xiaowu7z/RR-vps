#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$repo/scripts/update-recover.sh"
RR_LIB_DIR="$work/runtime"
RR_LAUNCHER="$work/rr"
RR_QUARANTINE_FILE="$work/quarantine"
RR_QUARANTINE_GUARD_STATE="$work/guard-state"
install -d -m 700 "$RR_LIB_DIR/modules"
printf '%s\n' 'SCRIPT_VERSION="7.0.2"' > "$RR_LIB_DIR/modules/00-runtime.sh"
printf '%s\n' ':' > "$RR_LIB_DIR/modules/10-system.sh"
cat > "$RR_LIB_DIR/modules/20-config.sh" <<'SH'
select_entry_ip() { return 0; }
start_subscription_server() { printf 'started\n' > "$LEGACY_START_RESULT"; }
SH
printf '#!/bin/bash\nprintf "wrong menu\\n" > "%s/menu"\n' "$work" > "$RR_LAUNCHER"
chmod 600 "$RR_LIB_DIR"/modules/*.sh
chmod 700 "$RR_LAUNCHER"
export LEGACY_START_RESULT="$work/result"
phase_fixture=freezing
metadata_fixture=0
rr_transaction_path() { printf '%s\n' "$work/transaction"; }
rr_read_trusted_phase() { printf '%s\n' "$phase_fixture"; }
rr_transaction_v2_control_metadata_is_safe() { return "$metadata_fixture"; }
rr_transaction_v2_backup_metadata_is_safe() { return 0; }
rr_update_maintenance_marker_state() { return 0; }
for phase_fixture in freezing snapshotting prepared; do
    rr_prepare_subscription_refresh_command
    rr_run_delegated_without_lock_fds 5 "${RR_SUBSCRIPTION_REFRESH_COMMAND[@]}" </dev/null
    test "$(cat "$LEGACY_START_RESULT")" = started
    test ! -e "$work/menu"
done
for phase_fixture in switching committed rolled_back aborted recovery_failed; do
    if rr_prepare_subscription_refresh_command; then exit 1; fi
done
phase_fixture=freezing
metadata_fixture=1
if rr_prepare_subscription_refresh_command; then exit 1; fi
metadata_fixture=0
for marker in "$RR_QUARANTINE_FILE" "$RR_QUARANTINE_GUARD_STATE"; do
    touch "$marker"
    if rr_prepare_subscription_refresh_command; then exit 1; fi
    rm "$marker"
done
chmod 666 "$RR_LIB_DIR/modules/20-config.sh"
if rr_prepare_subscription_refresh_command; then exit 1; fi
chmod 600 "$RR_LIB_DIR/modules/20-config.sh"
printf '%s\n' 'SCRIPT_VERSION="7.2.1"' > "$RR_LIB_DIR/modules/00-runtime.sh"
rr_prepare_subscription_refresh_command
test "${RR_SUBSCRIPTION_REFRESH_COMMAND[*]}" = "$RR_LAUNCHER --refresh-subscription"

# A legacy health writer must be stopped before the services it can revive.
eval "$(awk '/^rr_freeze_update_writers\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$repo/scripts/install-core.sh")"
health_frozen=false
rr_freeze_health_monitor() { health_frozen=true; }
rr_freeze_ip_acme_update_writer() { test "$health_frozen" = true; }
systemctl() { test "$health_frozen" = true; }
rr_wait_unit_state() { test "$health_frozen" = true; }
rr_stop_subscription_servers() { test "$health_frozen" = true; }
rr_freeze_update_writers
rr_error() { :; }
rr_freeze_health_monitor() { return 1; }
systemctl() { touch "$work/unsafe-stop"; }
if rr_freeze_update_writers; then exit 1; fi
test ! -e "$work/unsafe-stop"
for function in rr_recovery_helper_file_is_safe rr_recovery_helper_source_is_safe rr_recovery_helper_is_owned_or_absent; do
    eval "$(awk -v name="$function" '$0 == name "() {" {copy=1} copy{print} copy && /^}$/{exit}' "$repo/scripts/install-core.sh")"
done
RR_RECOVERY_HELPER="$work/recovery-helper"
printf 'published fixture\n' > "$RR_RECOVERY_HELPER"
printf 'candidate fixture\n' > "$work/candidate-helper"
chmod 755 "$RR_RECOVERY_HELPER"
rr_trusted_installed_runtime_version() { printf '7.0.2\n'; }
# Model the external checksum tool; the real file/owner/mode checks still run.
sha256sum() {
    if [ "$(cat "${@: -1}")" = 'published fixture' ]; then
        printf 'e2e0b855c8bcd295daf2741c2e58cbf011263aabdedb535066df5ff14ac7b893  %s\n' "${@: -1}"
    else command sha256sum "$@"; fi
}
rr_recovery_helper_is_owned_or_absent "$RR_RECOVERY_HELPER" "$work/candidate-helper" "$work/missing"
printf 'modified helper\n' > "$RR_RECOVERY_HELPER"
if rr_recovery_helper_is_owned_or_absent "$RR_RECOVERY_HELPER" "$work/candidate-helper" "$work/missing"; then exit 1; fi
printf 'published fixture\n' > "$RR_RECOVERY_HELPER"
chmod 777 "$RR_RECOVERY_HELPER"
if rr_recovery_helper_is_owned_or_absent "$RR_RECOVERY_HELPER" "$work/candidate-helper" "$work/missing"; then exit 1; fi
echo '7.0.2 pre-mutation subscription compatibility and freeze ordering: PASS'
