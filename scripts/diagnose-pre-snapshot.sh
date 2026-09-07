#!/bin/bash
# Read-only inspection of a retained pre-snapshot transaction. No recovery call.
set -euo pipefail
umask 077
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/f0c42343c9547ea12e16a66549d831052539c15e/scripts/update-recover.sh \
    -o "$work/recover.sh"
printf '%s  %s\n' bbf520a15a4d520d7b724e5abcc2341bd00c54f73c2cacf79c243fc3a50fb3a3 \
    "$work/recover.sh" | sha256sum -c -
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$work/recover.sh"
exec 3>&1
probe() {
    local name="$1" rc=0
    shift
    if (
        set -T
        trap 'probe_status=$?; if [ "$probe_status" -ne 0 ]; then printf "RETURN function=%s line=%s rc=%s\n" "${FUNCNAME[0]:-main}" "${BASH_LINENO[0]:-0}" "$probe_status" >&3; fi' RETURN
        "$@" >/dev/null 2>&1
    ); then rc=0; else rc=$?; fi
    printf 'CHECK %s rc=%s\n' "$name" "$rc"
}
main status
tx=$(rr_transaction_path)
phase=$(rr_read_trusted_phase "$tx")
case "$phase" in freezing|snapshotting|prepared) ;; *) echo 'Unexpected phase; read-only inspection stopped.'; exit 1 ;; esac
probe control_metadata rr_transaction_v2_control_metadata_is_safe "$tx"
probe backup_metadata rr_transaction_v2_backup_metadata_is_safe "$tx"
probe certificate_phase rr_ip_acme_phase_contract_is_safe "$tx" "$phase"
probe maintenance_marker rr_update_maintenance_marker_state "$tx"
probe singbox_identity rr_managed_service_start_is_safe sing-box.service
probe nexus_identity rr_managed_service_start_is_safe rr-nexus.service
probe certificate_readiness rr_ip_acme_runtime_readonly_is_ready "$tx/backup"
probe all_writer_identities rr_recorded_managed_start_identities_are_safe "$tx/backup"
probe subscription_process rr_subscription_running
printf '\nRECORDED_MARKERS\n'
for marker in writer_state_complete singbox_was_running singbox_was_enabled \
    nexus_was_running nexus_was_enabled subscription_was_running \
    health_timer_was_running health_timer_was_enabled health_service_was_running \
    ip_acme_was_present external_state_required ip_acme_directories_complete; do
    if [ -f "$tx/backup/$marker" ]; then printf '%s=present\n' "$marker"; else printf '%s=absent\n' "$marker"; fi
done
printf '\nLIVE_SERVICES\n'
systemctl show sing-box.service rr-nexus.service nginx.service argo-rr-health.timer \
    argo-rr-health.service -p Id -p LoadState -p ActiveState -p SubState -p UnitFileState -p Result --no-pager
printf '\nCONTROL_FILE_METADATA\n'
stat -c '%a %u:%g %h %F %n' /run/rr-vps /run/rr-vps/update-maintenance \
    /var/lib/rr-update /var/lib/rr-update/active "$tx" "$tx/phase" 2>/dev/null || true
printf '\nREAD_ONLY_DIAGNOSTIC_COMPLETE\n'
