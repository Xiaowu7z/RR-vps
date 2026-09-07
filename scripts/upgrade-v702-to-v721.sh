#!/bin/bash
# Production upgrade wrapper: private backup, immutable pinned installer, identity check.
set -euo pipefail
umask 077
export SYSTEMD_PAGER=cat
[ "${EUID:-$(id -u)}" = 0 ] || { echo '请使用 root。'; exit 1; }
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.0.2'
/usr/local/sbin/rr-update-recover status | python3 -c '
import json,sys
s=json.load(sys.stdin)
assert s.get("active") is False and s.get("subscription_quarantine",{}).get("active") is False, "升级事务尚未清理"
'
for unit in sing-box.service rr-nexus.service nginx.service; do
    systemctl is-active --quiet "$unit"
done
work=$(mktemp -d)
backup=""
writers_paused=false
timer_running=false
systemctl is-active --quiet argo-rr-health.timer && timer_running=true
resume_backup_writers() {
    [ "$writers_paused" = true ] || return 0
    systemctl start rr-nexus.service || return 1
    if [ "$timer_running" = true ]; then systemctl start argo-rr-health.timer || return 1; fi
    writers_paused=false
}
finish() {
    local result=$?
    trap - EXIT
    resume_backup_writers || result=1
    rm -rf -- "$work"
    if [ "$result" -ne 0 ]; then
        printf '升级未确认完成，请保留输出。备份目录：%s\n' "${backup:-尚未创建}"
        /usr/local/sbin/rr-update-recover status || true
    fi
    exit "$result"
}
trap finish EXIT
curl -fL --retry 2 --connect-timeout 15 --max-time 180 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/install.sh -o "$work/install.sh"
printf '%s  %s\n' 171b6f1fd2df445b5837c87b6744f9d38ff7ac2a0ca82b6fe41dd6d905995bb0 \
    "$work/install.sh" | sha256sum -c -
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/v7.2.1/scripts/verify-upgrade-identities.py \
    -o "$work/verify.py"
printf '%s  %s\n' d33dca31a1cfb295491561bd8e77c106a103e8211b8cdf7e6c9f1f21e91924f3 "$work/verify.py" | sha256sum -c -
paths=()
for path in etc/argo_vmess.conf etc/sing-box etc/rr-nexus etc/nginx etc/letsencrypt \
    etc/systemd/system etc/rr-update usr/local/bin/rr usr/local/bin/sing-box \
    usr/local/bin/auto_update_sub.py usr/local/lib/rr usr/local/sbin/rr-update-recover \
    usr/local/sbin/rr-update-external-state var/lib/rr-nexus var/lib/rr-vps tmp/sub_server; do
    if [ -e "/$path" ] || [ -L "/$path" ]; then paths+=("$path"); fi
done
size_kb=$(cd /; du -skc -- "${paths[@]}" | tail -1 | awk '{print $1}')
free_kb=$(df -Pk /root | awk 'NR==2 {print $4}')
if [ "$free_kb" -lt "$((size_kb * 2 + 524288))" ]; then
    echo '备份所需空间不足，尚未暂停服务。'; exit 1
fi
backup=$(mktemp -d /root/rr-before-7.2.1.XXXXXX)
printf '备份目录：%s\n备份期间面板暂时暂停；升级时节点服务会短暂重启。\n' "$backup"
writers_paused=true
systemctl stop argo-rr-health.timer argo-rr-health.service rr-nexus.service
python3 "$work/verify.py" "$backup/identities.json" --capture
install -m 600 "$work/verify.py" "$backup/verify-identities.py"
python3 - "$backup/nexus.db" <<'PY'
import sqlite3,sys
with sqlite3.connect('file:/var/lib/rr-nexus/nexus.db?mode=ro',uri=True) as source:
    assert source.execute('PRAGMA quick_check').fetchone() == ('ok',)
    with sqlite3.connect(sys.argv[1]) as target:
        source.backup(target)
        assert target.execute('PRAGMA quick_check').fetchone() == ('ok',)
PY
tar --acls --xattrs --numeric-owner -czf "$backup/files.tar.gz.part" -C / "${paths[@]}"
gzip -t "$backup/files.tar.gz.part"
mv "$backup/files.tar.gz.part" "$backup/files.tar.gz"
(cd "$backup"; sha256sum files.tar.gz nexus.db identities.json > SHA256SUMS; sha256sum -c SHA256SUMS)
resume_backup_writers
# From here the transactional installer alone owns service rollback/quarantine.
# The EXIT trap must never override its decision by starting old services.
bash "$work/install.sh" --upgrade
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.2.1'
python3 "$work/verify.py" "$backup/identities.json"
for unit in sing-box.service rr-nexus.service nginx.service; do
    systemctl is-active --quiet "$unit"
done
/usr/local/sbin/rr-update-recover status
/usr/local/bin/rr --version
printf 'UPGRADE_COMPLETE: 用户、设备凭据、订阅令牌与节点身份核对一致。\n备份保留在：%s\n' "$backup"
