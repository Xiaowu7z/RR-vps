#!/bin/bash
# Narrow recovery adapter for 7.0.2, whose launcher has no --refresh-subscription.
# This never installs a runtime, migrates config, or discards transaction evidence.
set -eo pipefail
umask 077
[ "${EUID:-$(id -u)}" = 0 ] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
trap 'rc=$?; printf "RECOVERY_STOPPED line=%s rc=%s; transaction retained.\n" "$LINENO" "$rc"; exit "$rc"' ERR
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/f0c42343c9547ea12e16a66549d831052539c15e/scripts/update-recover.sh \
    -o "$work/recover.sh"
printf '%s  %s\n' bbf520a15a4d520d7b724e5abcc2341bd00c54f73c2cacf79c243fc3a50fb3a3 \
    "$work/recover.sh" | sha256sum -c -
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$work/recover.sh"
# Keep the normal update locks and every recovery metadata/service identity gate.
rr_acquire_update_lock
# This process now really owns both descriptors; main() must reuse that lock.
RR_UPDATE_LOCK_HELD=1
tx=$(rr_transaction_path)
[ "$(rr_read_trusted_phase "$tx")" = freezing ] || {
    echo 'STOP: transaction is no longer freezing.'; exit 1;
}
rr_transaction_v2_control_metadata_is_safe "$tx"
rr_transaction_v2_backup_metadata_is_safe "$tx"
rr_ip_acme_phase_contract_is_safe "$tx" freezing
rr_update_maintenance_marker_state "$tx"
[ ! -e "$RR_QUARANTINE_FILE" ] && [ ! -L "$RR_QUARANTINE_FILE" ]
[ "$(rr_trusted_runtime_version "$RR_LIB_DIR")" = 7.0.2 ] || {
    echo 'STOP: this adapter only supports RR-vps 7.0.2.'; exit 1;
}
rr_recorded_managed_start_identities_are_safe "$tx/backup"
# Only load root-owned installed code, as the original launcher does.
for module in 00-runtime.sh 10-system.sh 20-config.sh; do
    file="$RR_LIB_DIR/modules/$module"
    rr_quarantine_source_ancestors_are_trusted "$file"
    [ -f "$file" ] && [ ! -L "$file" ]
    IFS=: read -r owner group mode links < <(stat -c '%u:%g:%a:%h' -- "$file")
    [ "$owner:$group:$links" = 0:0:1 ]
    rr_legacy_update_lock_mode_is_safe "$mode"
    bash -n "$file"
done
if grep -Fq -- '--refresh-subscription' "$RR_LAUNCHER"; then
    echo 'STOP: launcher already has the new refresh entry; use normal recovery.'
    exit 1
fi
# Called by the normal locked recovery, only after all writer gates succeed.
# Old runtime modules only declare functions/constants; invoke the two read/start
# operations directly, with no main menu, schema migration or node generation.
rr_resume_subscription_bounded() {
    local status=0
    rr_run_delegated_without_lock_fds 30 bash -c '
        for module in 00-runtime.sh 10-system.sh 20-config.sh; do
            source "$1/modules/$module" || exit 1
        done
        select_entry_ip || exit 1
        start_subscription_server
    ' rr-v702-subscription "$RR_LIB_DIR" </dev/null >"$work/subscription.log" 2>&1 || status=$?
    printf 'LEGACY_SUBSCRIPTION_START rc=%s\n' "$status"
    if [ "$status" -ne 0 ] || ! rr_subscription_running; then
        rr_stop_subscription_servers >/dev/null 2>&1 || true
        return 1
    fi
}
echo 'Recovering existing 7.0.2 services; brief service restarts are expected.'
sha256sum -- "$RR_CONFIG_FILE" /etc/sing-box/config.json > "$work/config.sha256"
result=0
main recover || result=$?
sha256sum -c "$work/config.sha256" || {
    echo 'CONFIG_CHANGED: stop and inspect before any upgrade.'
    result=1
}
main status
"$RR_LAUNCHER" --version
systemctl show sing-box.service rr-nexus.service nginx.service argo-rr-health.timer \
    -p Id -p ActiveState -p SubState --no-pager
if [ "$result" -ne 0 ]; then
    echo 'RECOVERY_FAILED: transaction evidence retained; do not retry the upgrade.'
    exit "$result"
fi
echo 'RECOVERY_COMPLETE: 7.0.2 restored; no upgrade performed.'
