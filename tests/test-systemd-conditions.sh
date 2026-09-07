#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../modules/09-systemd.sh"
shown='[unprintable]'
condition_fixture='{"type":"a(sbbsi)","data":[]}'
bus_status=0
systemctl() { printf '%s\n' "$shown"; }
busctl() {
    [ "$*" = '--system --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/sing_2dbox_2eservice org.freedesktop.systemd1.Unit Conditions' ] || return 9
    [ "$bus_status" = 0 ] || return "$bus_status"
    printf '%s\n' "$condition_fixture"
}
read_conditions() { rr_systemd_show --property=Conditions --value sing-box.service; }
for shown in "[unprintable]" "Conditions=[unprintable]"; do
  result=$(read_conditions)
  [ -z "$result" ]
done
condition_fixture='{"type":"a(sbbsi)","data":[["ConditionPathExists",false,false,"/etc/argo_vmess.conf",0]]}'
result=$(read_conditions)
[[ "$result" == *'parameter=/etc/argo_vmess.conf;'* && -n "$result" ]]
condition_fixture='{"type":"a(sbbsi)","data":[["ConditionPathExists",true,true,"/etc/argo_vmess.conf",0]]}'
[[ "$(read_conditions)" == *'trigger=yes; negate=yes;'* ]]
for condition_fixture in '{"type":"s","data":""}' '{"type":"a(sbbsi)","data":[["ConditionPathExists",0,false,"/etc/argo_vmess.conf",0]]}' '{"type":"a(sbbsi)","data":[["ConditionPathExists",false,false,"/etc/a; parameter=/etc/b",0]]}'; do
    if read_conditions >/dev/null 2>&1; then echo 'Malformed condition accepted' >&2; exit 1; fi
done
bus_status=1
if read_conditions >/dev/null 2>&1; then echo 'Bus failure accepted' >&2; exit 1; fi
shown=''
result=$(read_conditions)
[ -z "$result" ]
shown='{ parameter=/existing/text/output; }'
[ "$(read_conditions)" = "$shown" ]
echo 'systemd condition regression: pass'
