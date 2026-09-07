#!/bin/bash
# One-time preparation for the diagnosed DMIT layout, then the released update.
set -eo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 SYSTEMD_PAGER=cat
test "${EUID:-$(id -u)}" = 0
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.0.2'
identity_backup=/root/rr-before-7.2.1.B05HIb
printf '%s  %s\n' d33dca31a1cfb295491561bd8e77c106a103e8211b8cdf7e6c9f1f21e91924f3 \
    "$identity_backup/verify-identities.py" | sha256sum -c -
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
/usr/local/sbin/rr-update-recover status | python3 -c \
    'import json,sys; assert json.load(sys.stdin).get("active") is False'
work=$(mktemp -d)
backup=""
phase=download
fw_started=false
fw_locked=false
persist_touched=false
prep_committed=false
finish() {
    local result=$? restore_result=0
    trap - EXIT INT TERM HUP
    if [ "$fw_started" = true ] && [ "$prep_committed" != true ]; then
        python3 "$backup/prepare-firewall.py" rollback "$backup" || restore_result=1
        if [ "$persist_touched" = true ]; then
            python3 "$backup/persistence.py" restore "$backup" || restore_result=1
        fi
        printf 'FIREWALL_PREPARATION_ROLLBACK rc=%s\n' "$restore_result"
    fi
    if [ "$fw_locked" = true ]; then rr_firewall_lock_release || restore_result=1; fi
    if [ "$result" != 0 ] || [ "$restore_result" != 0 ]; then
        printf 'STOP phase=%s rc=%s backup=%s\n' "$phase" "$result" "${backup:-not-created}"
        /usr/local/bin/rr --version || true
        /usr/local/sbin/rr-update-recover status || true
    fi
    rm -rf -- "$work"
    [ "$restore_result" = 0 ] || result=1
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/rr-bundle.tar.gz -o "$work/bundle.tar.gz"
printf '%s  %s\n' f00fc713dc63e43ca60da1c5f936d17263d58776445567b0dc8f3a2af7f8f9d3 \
    "$work/bundle.tar.gz" | sha256sum -c -
tar -xzf "$work/bundle.tar.gz" -C "$work"
candidate="$work/rr-bundle"
curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/076da44df3f1ed80c09d0b87818172516f963724/scripts/prepare-v702-firewall.py -o "$work/prepare-firewall.py"
printf '%s  %s\n' a469729fb9272b8d178bb18ad7dc2c10e8b7caf89a64399ce96cc70eefaab9df "$work/prepare-firewall.py" | sha256sum -c -
if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
    https://raw.githubusercontent.com/Xiaowu7z/RR-vps/c7de4b412b2bd90d45fea733a0d62ede37918aab/install.sh -o "$work/install.sh"; then
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 90 \
        https://github.com/Xiaowu7z/RR-vps/releases/download/v7.2.1/install.sh -o "$work/install.sh"
fi
printf '%s  %s\n' 171b6f1fd2df445b5837c87b6744f9d38ff7ac2a0ca82b6fe41dd6d905995bb0 \
    "$work/install.sh" | sha256sum -c -
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$candidate/scripts/update-recover.sh"
set +u
rr_acquire_update_lock
/usr/local/sbin/rr-update-recover status | python3 -c \
    'import json,sys; assert json.load(sys.stdin).get("active") is False'
for module in 00-runtime.sh 09-systemd.sh 10-system.sh 20-config.sh 30-singbox.sh 85-nexus.sh; do
    source "$candidate/modules/$module"
done
RR_LIB_DIR="$candidate"
phase=preflight
load_config_with_defaults
test "$VL_ENABLED:$VL_PORT:$HY2_ENABLED:$HY2_PORT:$TU5_ENABLED:$TU5_PORT:$AN_ENABLED:$AN_PORT" = 'true:28759:true:15551:true:24747:true:14640'
test "$VM_ENABLED:$VM_TLS_ENABLED:$NAIVE_ENABLED:$SUB_ACCESS_MODE:$SUB_PORT" = 'true:false:false:local:20382'
if [ -n "$HY2_HOP_PORTS" ]; then
    rr_validate_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS"
    rr_firewall_hop_program_first_match_is_safe HY2 "$HY2_PORT" "$HY2_HOP_PORTS" post
fi
if [ -n "$TU5_HOP_PORTS" ]; then
    rr_validate_hop_rules TU5 "$TU5_PORT" "$TU5_HOP_PORTS"
    rr_firewall_hop_program_first_match_is_safe TU5 "$TU5_PORT" "$TU5_HOP_PORTS" post
fi
test "$(jq -r '[.mode,.domain,(.port|tostring),(.public_port|tostring)]|join(":")' "$NEXUS_CONFIG_FILE")" = 'public:rr.188199200.xyz:7900:443'
for unit in sing-box.service rr-nexus.service nginx.service; do systemctl is-active --quiet "$unit"; done
if rr_firewall_fail_closed_quarantine_active; then
    printf '存在独立防火墙隔离，停止准备。\n'
    exit 1
fi
command -v netfilter-persistent >/dev/null
for backend in iptables ip6tables; do command -v "$backend-save" >/dev/null; done
nexus_nginx_managed_paths_are_owned
rr_certbot_webroot_lineage_is_renewable rr.188199200.xyz
rr_certbot_renewal_runtime_is_ready rr.188199200.xyz
rr_firewall_lock_acquire
fw_locked=true
mode=""
rr_firewall_filter_authority_mode mode
test "$mode" = netfilter
for tuple in 443:tcp 28759:tcp 15551:udp 24747:udp 14640:tcp; do
    IFS=: read -r port proto <<< "$tuple"
    rr_inactive_ufw_protocol_is_disjoint "$port" "$proto"
done
backup=$(mktemp -d /root/rr-before-firewall.XXXXXX)
install -m 600 "$work/prepare-firewall.py" "$backup/prepare-firewall.py"
for backend in iptables ip6tables; do
    "$backend" -w 5 -t filter -S > "$backup/$backend.before"
    "$backend-save" > "$backup/$backend.before.save"
done
sha256sum /etc/argo_vmess.conf /etc/sing-box/config.json /etc/rr-nexus/nexus.json > "$backup/config.sha256"
cat > "$backup/persistence.py" <<'PY'
from pathlib import Path
import json, os, re, shutil, stat, subprocess, sys
action, raw = sys.argv[1:]
backup = Path(raw)
root = Path('/etc/iptables')
def safe(path, directory=False):
    m = path.lstat()
    assert (stat.S_ISDIR(m.st_mode) if directory else stat.S_ISREG(m.st_mode))
    assert (m.st_uid, m.st_gid) == (0, 0) and not stat.S_IMODE(m.st_mode) & 0o022
    assert path.resolve() == path
    if not directory: assert m.st_nlink == 1
def normalized(text, omit_filter=False):
    lines, table = [], ''
    for line in text.splitlines():
        if not line or line.startswith('#'): continue
        if line.startswith('*'): table = line[1:]
        if not (omit_filter and table == 'filter'):
            lines.append(re.sub(r'\[\d+:\d+\]', '[0:0]', line))
    return lines
safe(root, True)
if action == 'snapshot':
    states = {}
    for name in ('rules.v4', 'rules.v6'):
        path = root / name
        assert not (root / (name + '.rr-prepare-restore')).exists()
        assert not (root / (name + '.rr-prepare-restore')).is_symlink()
        states[name] = path.exists()
        if path.exists() or path.is_symlink():
            safe(path)
            shutil.copy2(path, backup / name)
    (backup / 'persistent-state.json').write_text(json.dumps(states))
elif action == 'restore':
    for name, existed in json.loads((backup / 'persistent-state.json').read_text()).items():
        path = root / name
        if path.exists() or path.is_symlink(): safe(path)
        if existed:
            temp = root / (name + '.rr-prepare-restore')
            shutil.copy2(backup / name, temp)
            os.replace(temp, path)
        else:
            path.unlink(missing_ok=True)
    print('PERSISTENT_FILES_RESTORED')
elif action == 'verify':
    for backend, name in (('iptables', 'rules.v4'), ('ip6tables', 'rules.v6')):
        safe(root / name)
        live = subprocess.check_output([backend + '-save'], text=True, timeout=15)
        assert normalized(live) == normalized((root / name).read_text()), 'Persistence does not match live rules'
        assert normalized(live, True) == normalized((backup / (backend + '.before.save')).read_text(), True), 'Non-filter table changed'
    print('FIREWALL_PERSISTENCE_VERIFIED')
else:
    raise SystemExit('Unknown persistence action')
PY
python3 "$backup/persistence.py" snapshot "$backup"
python3 "$backup/prepare-firewall.py" plan "$backup"
printf '备份：%s；开始修复重复 443 规则和四个节点端口。\n' "$backup"
phase=prepare-firewall
fw_started=true
python3 "$backup/prepare-firewall.py" apply "$backup"
for tuple in 80:tcp 443:tcp 28759:tcp 15551:udp 24747:udp 14640:tcp; do
    IFS=: read -r port proto <<< "$tuple"
    rr_validate_protocol_firewall "$port" "$proto" open
done
phase=persist-firewall
persist_touched=true
timeout --kill-after=5 45 netfilter-persistent save > "$backup/persistence.log" 2>&1
python3 "$backup/prepare-firewall.py" verify "$backup"
python3 "$backup/persistence.py" verify "$backup"
sha256sum -c "$backup/config.sha256" >/dev/null
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
prep_committed=true
printf 'FIREWALL_PREPARED: 目标规则与持久化核验通过，用户身份未变。\n'
rr_firewall_lock_release
fw_locked=false
rr_close_inherited_recovery_lock_fds
unset RR_UPDATE_LOCK_HELD RR_RESTORE_LOCK_HELD RR_UPDATE_LOCK_OWNER RR_UPDATE_LOCK_FDS_CLOSED
phase=upgrade
# From here the released installer owns rollback and quarantine decisions.
bash "$work/install.sh" --upgrade
phase=verify-upgrade
test "$(/usr/local/bin/rr --version)" = 'RR-vps 7.2.1'
python3 "$identity_backup/verify-identities.py" "$identity_backup/identities.json"
for unit in sing-box.service rr-nexus.service nginx.service; do systemctl is-active --quiet "$unit"; done
/usr/local/sbin/rr-update-recover status | python3 -c \
    'import json,sys; s=json.load(sys.stdin); assert s.get("active") is False and s.get("subscription_quarantine",{}).get("active") is False'
rr_health_monitor_unit_definitions_are_current
systemctl enable --now argo-rr-health.timer
rr_health_monitor_units_are_current
printf 'UPGRADE_COMPLETE: RR-vps 7.2.1；原有用户与订阅身份核对一致。\n'
