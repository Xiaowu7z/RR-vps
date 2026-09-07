#!/bin/bash
# Owner-authorized destructive reset, ONLY for the three disposable audit hosts.
set -euo pipefail
umask 077
role="$1"; expected_os="$2"; expected_os_version="$3"; expected_version="$4"
stage=/root/rr-stability-candidate
log=/root/rr-stability.log
phase=preflight
exec 3>&1
exec >>"$log" 2>&1
chmod 600 "$log"
trap 'rc=$?; trap - EXIT; printf "STABILITY role=%s phase=%s result=%s\n" "$role" "$phase" "$rc" >&3; exit "$rc"' EXIT
export LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=dumb
test "$(id -u)" = 0
. /etc/os-release
test "$ID:$VERSION_ID" = "$expected_os:$expected_os_version"
test "$(uname -m)" = x86_64
test "$(ps -p 1 -o comm= | tr -d '[:space:]')" = systemd
case "$role" in A|B|C) ;; *) exit 2 ;; esac
cd "$stage"
sha256sum -c transfer.sha256
read -r _ _ _ ssh_port <<<"${SSH_CONNECTION:?}"
[[ "$ssh_port" =~ ^[0-9]+$ ]]

phase=backup
backup=$(mktemp -d /root/rr-stability-backup.XXXXXX)
chmod 700 "$backup"
paths=(etc/argo_vmess.conf etc/sing-box etc/rr-nexus etc/rr-naive
  etc/rr-update etc/rr-cloudflared var/lib/rr-update var/lib/rr-vps
  var/lib/rr-nexus var/lib/rr-backup etc/ufw etc/iptables)
existing=()
for path in "${paths[@]}"; do
  if [ -e "/$path" ] || [ -L "/$path" ]; then existing+=("$path"); fi
done
if [ "${#existing[@]}" -gt 0 ]; then tar -C / -czf "$backup/state.tar.gz" -- "${existing[@]}"; fi
for backend in iptables ip6tables; do
  if command -v "${backend}-save" >/dev/null; then "${backend}-save" >"$backup/$backend.rules"; fi
done

phase=reset
# Stop all old RR restart/recovery paths before deleting their disposable state.
units=(argo-rr-health.timer argo-rr-health.service rr-firewall-quarantine-guard.path
  rr-firewall-quarantine-guard.timer rr-firewall-quarantine-guard.service
  rr-update-recovery.service rr-restore-recovery.service rr-restore-watchdog.service
  rr-subscription-quarantine.service rr-nexus-ip-acme.timer rr-nexus-ip-acme.service
  rr-nexus.service rr-subscription.service sing-box.service)
for unit in "${units[@]}"; do
  if [ "$(systemctl show -p LoadState --value "$unit")" != not-found ]; then
    systemctl disable --now "$unit"
    test "$(systemctl show -p ActiveState --value "$unit")" = inactive
  fi
done
# Refuse to erase a running unmanaged proxy instance.
if pgrep -x sing-box || pgrep -x cloudflared; then exit 3; fi
for unit in "${units[@]}"; do
  rm -f -- "/etc/systemd/system/$unit"
  rm -rf -- "/etc/systemd/system/$unit.d"
done
for unit in nginx.service cloudflared.service; do
  rm -f -- "/etc/systemd/system/$unit.d/40-rr-restore-gate.conf" \
    "/etc/systemd/system/$unit.d/zzzz-rr-restore-gate.conf" \
    "/etc/systemd/system/$unit.d/zzzzz-rr-firewall-quarantine.conf"
done
rm -f -- /etc/nginx/sites-enabled/rr-nexus.conf /etc/nginx/sites-available/rr-nexus.conf \
  /etc/nginx/sites-enabled/rr-naive-acme.conf /etc/nginx/sites-available/rr-naive-acme.conf \
  /etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf /etc/nginx/sites-available/rr-nexus-ip-acme-http.conf \
  /etc/letsencrypt/renewal-hooks/deploy/rr-certificates.sh /etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh
rm -rf -- /usr/local/lib/rr /usr/local/bin/rr /usr/local/bin/sing-box \
  /usr/local/bin/auto_update_sub.py /usr/local/sbin/rr-update-recover \
  /usr/local/sbin/rr-update-external-state /usr/local/sbin/rr-firewall-quarantine-guard \
  /usr/local/libexec/rr-vps/subscription-quarantine-guard \
  /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared \
  /var/lib/rr-update /var/lib/rr-vps /var/lib/rr-nexus /var/lib/rr-backup /var/lib/rr-uninstall \
  /var/lib/rr-quarantine /run/rr-vps /run/rr-subscription-quarantine.ready \
  /tmp/sub_server /tmp/sub_server.pid /tmp/sub_server.bind /var/www/rr-nexus-certbot /var/www/rr-nexus-ip-acme
systemctl daemon-reload
systemctl reset-failed
if systemctl is-active --quiet nginx; then nginx -t; systemctl reload nginx; fi

phase=firewall
# The owner explicitly authorized discarding test-host firewall configuration.
# ACCEPT policies first keep SSH reachable throughout UFW removal and flushing.
for backend in iptables ip6tables; do
  if command -v "$backend" >/dev/null && "$backend" -w 5 -t filter -S >/dev/null; then
    for chain in INPUT FORWARD OUTPUT; do "$backend" -w 5 -P "$chain" ACCEPT; done
    "$backend" -w 5 -I INPUT 1 -p tcp --dport "$ssh_port" -j ACCEPT
  fi
done
if command -v ufw >/dev/null; then ufw --force disable; fi
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=60 update -qq
if dpkg-query -W -f='${db:Status-Status}' ufw 2>/dev/null | grep -qx installed; then
  apt-get -o DPkg::Lock::Timeout=60 purge -y ufw
fi
for backend in iptables ip6tables; do
  if command -v "$backend" >/dev/null && "$backend" -w 5 -t filter -S >/dev/null; then
    for chain in INPUT FORWARD OUTPUT; do "$backend" -w 5 -P "$chain" ACCEPT; done
    "$backend" -w 5 -t filter -F
    "$backend" -w 5 -t filter -X
    "$backend" -w 5 -t nat -F
    "$backend" -w 5 -t nat -X
    "$backend" -w 5 -I INPUT 1 -p tcp --dport "$ssh_port" -j ACCEPT
  fi
done
if command -v netfilter-persistent >/dev/null; then netfilter-persistent save; fi
printf 'STABILITY role=%s reset=pass\n' "$role" >&3

phase=runtime-install
RR_BUNDLE_FILE="$stage/rr-bundle.tar.gz" RR_GUARD_FILE="$stage/update-guard.sh" \
  bash "$stage/install-core.sh" --upgrade
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"
(cd /usr/local/lib/rr; awk '$2 != "rr"' manifest.sha256 | sha256sum -c - >/dev/null)
phase=protocol-install
for port in 24443 18081 21443 22443 7900; do test -z "$(ss -H -ltn "sport = :$port")"; done
for port in 23443 25443; do test -z "$(ss -H -lun "sport = :$port")"; done
printf '%s\n' '1,2,3,4,5' 24443 18081 21443 22443 23443 25443 n '' '' | \
  timeout 600 bash -c '
    set -o pipefail
    for module in /usr/local/lib/rr/modules/*.sh; do source "$module"; done
    install_main
  '
grep -qx INSTALL_COMPLETE=true /etc/argo_vmess.conf
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
for tag in vmess-in vless-in hy2-in tuic5-in anytls-in; do
  jq -e --arg tag "$tag" 'any(.inbounds[]; .tag == $tag)' /etc/sing-box/config.json >/dev/null
done
printf 'STABILITY role=%s protocols=pass\n' "$role" >&3

phase=panel-install
panel_pass=$(openssl rand -hex 20)
printf '%s\n' auditadmin "$panel_pass" >/root/rr-stability-panel-credentials
chmod 600 /root/rr-stability-panel-credentials
printf '%s\n' 1 17900 auditadmin "$panel_pass" "$panel_pass" '' | \
  timeout 600 bash -c '
    set -o pipefail
    for module in /usr/local/lib/rr/modules/*.sh; do source "$module"; done
    nexus_install
  '
unset panel_pass
test "$(jq -r '.listen' /etc/rr-nexus/nexus.json)" = 127.0.0.1
test "$(jq -r '.mode' /etc/rr-nexus/nexus.json)" = local

phase=subscription-sync
python3 - <<'PY'
import datetime, secrets, sqlite3, uuid
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
with sqlite3.connect('/var/lib/rr-nexus/nexus.db', timeout=30) as db:
    db.execute('INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,used_bytes,uploaded_bytes,downloaded_bytes,traffic_updated_at,group_id,expires_at,next_reset_at,reset_anchor_day,reset_max,reset_count,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ('dev_a11ce0000001','stability-audit',str(uuid.uuid4()),secrets.token_hex(24),1,1073741824,0,0,0,now,None,'2030-12-31','2030-09-30',30,36,0,now,now))
PY
timeout 90 /usr/local/bin/rr --sync-devices
test -s /var/lib/rr-nexus/subscriptions/dev_a11ce0000001.txt
grep -q '^vless://' /var/lib/rr-nexus/subscriptions/dev_a11ce0000001.txt
test "$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA quick_check;')" = ok
test -z "$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA foreign_key_check;')"
printf 'STABILITY role=%s subscriptions=pass\n' "$role" >&3

phase=restart
health() {
  systemctl is-active --quiet sing-box.service
  systemctl is-active --quiet rr-nexus.service
  curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:7900/healthz >/dev/null
}
for round in 1 2; do
  systemctl restart sing-box.service rr-nexus.service
  ready=false
  for attempt in {1..20}; do if health; then ready=true; break; fi; sleep 1; done
  test "$ready" = true
done
systemctl is-enabled --quiet sing-box.service rr-nexus.service
before_sing=$(systemctl show -p NRestarts --value sing-box.service)
before_nexus=$(systemctl show -p NRestarts --value rr-nexus.service)
pid_sing=$(systemctl show -p MainPID --value sing-box.service)
pid_nexus=$(systemctl show -p MainPID --value rr-nexus.service)
printf 'STABILITY role=%s restart=pass\n' "$role" >&3
phase=observe-180s
for sample in {1..12}; do
  sleep 15
  health
  test "$(systemctl show -p NRestarts --value sing-box.service)" = "$before_sing"
  test "$(systemctl show -p NRestarts --value rr-nexus.service)" = "$before_nexus"
  test "$(systemctl show -p MainPID --value sing-box.service)" = "$pid_sing"
  test "$(systemctl show -p MainPID --value rr-nexus.service)" = "$pid_nexus"
done
for port in 24443 21443 22443; do test -n "$(ss -H -ltn "sport = :$port")"; done
for port in 23443 25443; do test -n "$(ss -H -lun "sport = :$port")"; done
test -z "$(ss -H -ltn 'sport = :17900')"
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
phase=complete
printf 'STABILITY role=%s stable_seconds=180 unexpected_restarts=0\n' "$role" >&3
