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
finish() {
  rc=$?
  trap - EXIT
  if [ "$rc" != 0 ]; then
    test ! -f /root/rr-stability-lines.log || tail -25 /root/rr-stability-lines.log >&3
    test ! -f /root/rr-stability-return.log || tail -20 /root/rr-stability-return.log >&3
    python3 - "$log" <<'PYLOG' >&3
import re, sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines()[-18:]:
    line = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line)
    if ' DIAG ' not in line:
        line = re.sub(r'[!-~]{8,}', '[redacted]', line)
    print(line[:240])
PYLOG
  fi
  printf "STABILITY role=%s phase=%s result=%s\n" "$role" "$phase" "$rc" | tee /root/rr-stability-result >&3
  exit "$rc"
}
trap finish EXIT
: >/root/rr-stability-lines.log

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

# Reuse completed dependency/firewall setup. Install only the corrected helper
# on hosts whose candidate runtime is already deployed; verify every file.
phase=runtime-install
candidate=$(mktemp -d /root/rr-stability-payload.XXXXXX)
tar -xzf "$stage/rr-bundle.tar.gz" -C "$candidate"
(cd "$candidate/rr-bundle"; sha256sum -c manifest.sha256 >/dev/null)
if [ "$role" = C ]; then
  bash "$stage/audit-upgrade-702.sh" "$candidate/rr-bundle" 3>&-
fi
if [ -f /usr/local/lib/rr/modules/09-systemd.sh ] || [ "$role" = C ]; then
  # Exercise the complete transaction, including the manifest-verified helper.
  # Copying selected modules cannot prove that a released upgrade succeeds.
  RR_BUNDLE_FILE="$stage/rr-bundle.tar.gz" RR_GUARD_FILE="$stage/update-guard.sh" \
    bash "$stage/install-core.sh" --upgrade 3>&-
else
  # A's old installer retained failed rollback evidence. Keep it as a private
  # backup before installing the candidate on this never-completed test host.
  failed_install=$(mktemp -d /root/rr-stability-incomplete.XXXXXX)
  for unit in argo-rr-health.timer rr-update-recovery.service rr-restore-recovery.service rr-firewall-quarantine-guard.path rr-firewall-quarantine-guard.timer sing-box.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  test "$(systemctl show -p ActiveState --value sing-box.service)" = inactive
  for path in /etc/argo_vmess.conf /etc/systemd/system/sing-box.service /usr/local/lib/rr /usr/local/bin/rr /var/lib/rr-update /etc/rr-update /var/lib/rr-vps /run/rr-vps; do
    if [ -e "$path" ]; then mv -- "$path" "$failed_install/$(basename "$path").$(printf %s "$path" | sha256sum | cut -c1-8)"; fi
  done
  systemctl daemon-reload
  RR_BUNDLE_FILE="$stage/rr-bundle.tar.gz" RR_GUARD_FILE="$stage/update-guard.sh" \
    bash "$stage/install-core.sh" --upgrade 3>&-
fi
rm -rf -- "$candidate"
install -m 755 "$stage/update-guard.sh" /usr/local/lib/rr/modules/61-update-guard.sh
cmp -s "$stage/update-guard.sh" /usr/local/lib/rr/modules/61-update-guard.sh
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"
if [ "$role" = C ]; then
  python3 "$stage/verify-upgrade-identities.py" /root/rr-702-identities.json
  printf 'STABILITY role=C upgrade_from=7.0.2 identities=preserved\n' >&3
fi
(cd /usr/local/lib/rr; awk '$2 != "rr"' manifest.sha256 | sha256sum -c - >/dev/null)
if ! grep -qx INSTALL_COMPLETE=true /etc/argo_vmess.conf; then
phase=finish-protocol-install
# The protocol wizard already generated all five inbounds and started Sing-box.
# Owner-authorized test-host firewall cleanup; keep SSH before removing conflicts.
for backend in iptables ip6tables; do
  if command -v "$backend" >/dev/null && "$backend" -w 5 -t filter -S >/dev/null; then
    "$backend-save" >"/root/rr-stability-before-finish-$backend.rules"
    for chain in INPUT FORWARD OUTPUT; do "$backend" -w 5 -P "$chain" ACCEPT; done
    "$backend" -w 5 -F
    "$backend" -w 5 -X
    "$backend" -w 5 -I INPUT 1 -p tcp --dport "$ssh_port" -j ACCEPT
  fi
done
netfilter-persistent save
: >/root/rr-stability-return.log
timeout 600 bash -c '
    for module in /usr/local/lib/rr/modules/*.sh; do source "$module"; done
    exec 4>/root/rr-stability-lines.log
    exec 5>/root/rr-stability-return.log
    set -T
    trace_line() {
      printf "%s:%s:%s\n" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}" >&4
      case "$BASH_COMMAND" in return\ 1|return\ 2|return\ 3) printf "RETURN %s:%s:%s\n" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}" >&5 ;; esac
    }
    trap trace_line DEBUG
    finish_protocol_install() {
      load_config_with_defaults || return 1
      build_singbox_config || return 1
      setup_systemd || return 1
      open_configured_firewall || return 1
      generate_node_and_sub || return 1
      setup_health_monitor || return 1
      rr_health_monitor_units_are_current || return 1
      safe_sed INSTALL_COMPLETE true
    }
    rr_menu_run_writer finish_protocol_install
  ' 3>&-
fi
grep -qx INSTALL_COMPLETE=true /etc/argo_vmess.conf
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
for tag in vmess-in vless-in hy2-in tuic5-in anytls-in; do
  jq -e --arg tag "$tag" 'any(.inbounds[]; .tag == $tag)' /etc/sing-box/config.json >/dev/null
done
printf 'STABILITY role=%s protocols=pass\n' "$role" >&3

if [ ! -f /etc/rr-nexus/nexus.json ]; then
phase=panel-install
panel_pass=$(openssl rand -hex 20)
printf '%s\n' auditadmin "$panel_pass" >/root/rr-stability-panel-credentials
chmod 600 /root/rr-stability-panel-credentials
printf '%s\n' 1 17900 auditadmin "$panel_pass" "$panel_pass" '' | \
  timeout 600 bash -c '
    set -o pipefail
    exec 4>/root/rr-stability-lines.log
    set -T
    trace_line() { printf "%s:%s:%s\n" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}" >&4; }
    trap trace_line DEBUG
    for module in /usr/local/lib/rr/modules/*.sh; do source "$module"; done
    rr_menu_run_writer nexus_install
  ' 3>&-
unset panel_pass
fi
test "$(jq -r '.listen' /etc/rr-nexus/nexus.json)" = 127.0.0.1
test "$(jq -r '.mode' /etc/rr-nexus/nexus.json)" = local

phase=subscription-sync
python3 - <<'PY'
import datetime, secrets, sqlite3, uuid
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
with sqlite3.connect('/var/lib/rr-nexus/nexus.db', timeout=30) as db:
    db.execute('INSERT OR IGNORE INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,used_bytes,uploaded_bytes,downloaded_bytes,traffic_updated_at,group_id,expires_at,next_reset_at,reset_anchor_day,reset_max,reset_count,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ('dev_a11ce0000001','stability-audit',str(uuid.uuid4()),secrets.token_hex(24),1,1073741824,0,0,0,now,None,'2030-12-31','2030-09-30',30,36,0,now,now))
PY
timeout 90 /usr/local/bin/rr --sync-devices 3>&-
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
