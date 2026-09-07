#!/bin/bash
# ONLY invoked on disposable audit host C by vps-stability.yml.
set -euo pipefail
umask 077
candidate="$1"
stage=/root/rr-stability-candidate
test -f "$stage/legacy-702.tar.gz"
test -f /root/rr-stability-panel-credentials
. /etc/os-release
test "$ID:$VERSION_ID" = ubuntu:24.04
saved=$(mktemp -d /root/rr-702-test-before.XXXXXX)
systemctl stop argo-rr-health.timer argo-rr-health.service rr-nexus.service sing-box.service
RR_UPDATE_RECOVER_SOURCE_ONLY=1 source "$candidate/scripts/update-recover.sh"
rr_stop_subscription_servers
for path in /usr/local/lib/rr /usr/local/bin/rr /var/lib/rr-nexus; do
    name=$(printf '%s' "$path" | tr / _)
    mv "$path" "$saved/$name"
done
install -d -m 755 /usr/local/lib/rr
tar -xzf "$stage/legacy-702.tar.gz" -C /usr/local/lib/rr
install -m 755 /usr/local/lib/rr/rr /usr/local/bin/rr
# Restore the exact old service templates, keeping test-host network settings.
rr_render_safe_singbox_unit_legacy_710 > /etc/systemd/system/sing-box.service
rr_render_safe_nexus_unit > /etc/systemd/system/rr-nexus.service
for path in /etc/systemd/system/sing-box.service.d /etc/systemd/system/rr-nexus.service.d; do
    if [ -d "$path" ]; then mv "$path" "$saved/$(basename "$path")"; fi
done
systemctl daemon-reload
# Reproduce the published 7.2.0 helpers retained by the user's aborted upgrade,
# rather than retaining an arbitrary older helper from previous audit runs.
printf '%s  %s\n' e2e0b855c8bcd295daf2741c2e58cbf011263aabdedb535066df5ff14ac7b893 \
    "$stage/v720-update-recover.sh" | sha256sum -c -
install -m 755 "$stage/v720-update-recover.sh" /usr/local/sbin/rr-update-recover
install -m 755 "$stage/v720-update-external-state.py" /usr/local/sbin/rr-update-external-state
eval "$(awk '/^rr_render_update_recovery_unit\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$stage/install-core.sh")"
rr_render_update_recovery_unit > /etc/systemd/system/rr-update-recovery.service
chmod 644 /etc/systemd/system/rr-update-recovery.service
systemctl daemon-reload
python3 - <<'PY'
import datetime, importlib.util, secrets, sqlite3, sys, uuid
from pathlib import Path
spec = importlib.util.spec_from_file_location('rr_nexus_702', '/usr/local/lib/rr/nexus/rr_nexus.py')
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
store = module.Store(Path('/var/lib/rr-nexus/nexus.db'))
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
with store.connect() as db:
    db.execute('INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,used_bytes,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)',
        ('dev_a11ce0000002','legacy-upgrade',str(uuid.uuid4()),secrets.token_hex(24),1,1073741824,1024,now,now))
PY
mapfile -t fixture_admin < /root/rr-stability-panel-credentials
printf '%s\n' "${fixture_admin[1]}" | python3 /usr/local/lib/rr/nexus/rr_nexus.py \
    --init-admin "${fixture_admin[0]}" >/dev/null
unset fixture_admin
/usr/local/bin/rr --version | grep -Fx 'RR-vps 7.0.2'
/usr/local/bin/rr --sync-devices
# This is exactly the old noninteractive read/start path used in production.
bash -c 'for m in /usr/local/lib/rr/modules/*.sh; do source "$m"; done; select_entry_ip && start_subscription_server'
systemctl start sing-box.service rr-nexus.service
bash -c 'for m in /usr/local/lib/rr/modules/*.sh; do source "$m"; done; setup_health_monitor'
python3 "$stage/verify-upgrade-identities.py" /root/rr-702-identities.json --capture
printf 'LEGACY_FIXTURE version=7.0.2 database=7.0.2 subscription=running\n'
