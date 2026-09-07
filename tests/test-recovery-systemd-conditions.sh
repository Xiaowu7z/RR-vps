#!/bin/bash
set -euo pipefail
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$(dirname "$0")/../scripts/update-recover.sh"
shown='[unprintable]'
condition_fixture='{"type":"a(sbbsi)","data":[]}'
bus_status=0
systemctl() { printf '%s\n' "$shown"; }
busctl() {
    [ "$bus_status" = 0 ] || return "$bus_status"
    case "$*" in
        '--system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/sing_2dbox_2eservice org.freedesktop.systemd1.Unit Conditions'|\
        '--system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/sing_2dbox_2eservice org.freedesktop.systemd1.Unit Asserts'|\
        '--system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/rr_2dnexus_2eservice org.freedesktop.systemd1.Unit Conditions'|\
        '--system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/rr_2dnexus_2eservice org.freedesktop.systemd1.Unit Asserts') ;;
        *) return 9 ;;
    esac
    printf '%s\n' "$condition_fixture"
}
for unit in sing-box.service rr-nexus.service; do
    rr_recovery_unit_conditions_are_empty "$unit"
    condition_fixture='{"type":"a(sbbsi)","data":[["ConditionPathExists",false,false,"/required",1]]}'
    if rr_recovery_unit_conditions_are_empty "$unit"; then exit 1; fi
    for condition_fixture in '{"type":"s","data":[]}' '{"type":"a(sbbsi)"}' \
                   '{"type":"a(sbbsi)","data":[null]}' 'null'; do
        if rr_recovery_unit_conditions_are_empty "$unit"; then exit 1; fi
    done
    condition_fixture='{"type":"a(sbbsi)","data":[]}'
    bus_status=1
    if rr_recovery_unit_conditions_are_empty "$unit"; then exit 1; fi
    shown=''
    rr_recovery_unit_conditions_are_empty "$unit"
    shown='{ type=AssertPathExists; parameter=/required; }'
    if rr_recovery_unit_conditions_are_empty "$unit"; then exit 1; fi
    bus_status=0
    shown='[unprintable]'
done
echo 'standalone recovery systemd compatibility: PASS'
