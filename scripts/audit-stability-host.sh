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
  printf "STABILITY role=%s phase=%s result=%s\n" "$role" "$phase" "$rc" >&3
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

# Resume the owner-authorized reset already completed on these hosts.
test -f /etc/argo_vmess.conf
test -x /usr/local/bin/sing-box
printf "STABILITY role=%s reset=reused\n" "$role" >&3

phase=retire-incomplete-install
# These disposable hosts have never completed installation. Preserve the failed
# runtime and configuration; use the normal installer from a clean RR state.
grep -qx INSTALL_COMPLETE=false /etc/argo_vmess.conf
systemctl disable --now sing-box.service
test "$(systemctl show -p ActiveState --value sing-box.service)" = inactive
failed_install=$(mktemp -d /root/rr-stability-incomplete.XXXXXX)
for path in /etc/argo_vmess.conf /etc/systemd/system/sing-box.service /usr/local/lib/rr /usr/local/bin/rr; do
  if [ -e "$path" ]; then mv -- "$path" "$failed_install/$(basename "$path").$(printf %s "$path" | sha256sum | cut -c1-8)"; fi
done
systemctl daemon-reload
phase=runtime-install
RR_BUNDLE_FILE="$stage/rr-bundle.tar.gz" RR_GUARD_FILE="$stage/update-guard.sh" \
  bash "$stage/install-core.sh" --upgrade
/usr/local/bin/rr --version | grep -F "RR-vps $expected_version"
(cd /usr/local/lib/rr; awk '$2 != "rr"' manifest.sha256 | sha256sum -c - >/dev/null)
phase=protocol-install
# Preserve the exact failed function/line without exporting credential-bearing xtrace.
for port in 24443 18081 21443 22443 7900; do test -z "$(ss -H -ltn "sport = :$port")"; done
for port in 23443 25443; do test -z "$(ss -H -lun "sport = :$port")"; done
printf '%s\n' '1,2,3,4,5' 24443 18081 21443 22443 23443 25443 n '' '' | \
  timeout 600 bash -c '
    set -o pipefail
    exec 4>/root/rr-stability-lines.log
    set -T
    trace_line() { printf "%s:%s:%s\n" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}" >&4; }
    trap trace_line DEBUG
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
    exec 4>/root/rr-stability-lines.log
    set -T
    trace_line() { printf "%s:%s:%s\n" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}" >&4; }
    trap trace_line DEBUG
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
