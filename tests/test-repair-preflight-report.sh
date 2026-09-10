#!/usr/bin/env bash
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'ERROR: root required' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /root/rr-test-preflight.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
# Real filesystem and production metadata predicates; systemd and the already
# pinned runtime check are fixtures. No actual service calls are permitted.
# shellcheck source=../modules/10-system.sh
source "$repo/modules/10-system.sh"
python3 - "$repo/scripts/repair-v723-naive-first-install.sh" "$fixture" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2])
definitions = source[source.index('repair_note() {'):source.index('\n# The environment was cleared')]
for prefix in ('/etc/', '/var/lib/', '/run/rr-vps'):
    definitions = definitions.replace(prefix, str(root) + prefix)
(root / 'functions.sh').write_text(definitions)
PY
# shellcheck disable=SC1091
source "$fixture/functions.sh"
for path in etc/systemd/system/sing-box.service.d var/lib/rr-vps \
    etc/sing-box etc/rr-naive etc/letsencrypt run/rr-vps; do
    install -d -m 755 -- "$fixture/$path"
done
NEXUS_CONFIG_FILE="$fixture/etc/rr-nexus/nexus.json"
NEXUS_DB_FILE="$fixture/var/lib/rr-nexus/nexus.db"
printf '%s\n' 'SENSITIVE_CONFIG_SENTINEL' >"$fixture/etc/argo_vmess.conf"
printf '%s\n' 'SENSITIVE_NODE_SENTINEL' >"$fixture/etc/sing-box/config.json"
chmod 600 "$fixture/etc/argo_vmess.conf" "$fixture/etc/sing-box/config.json"
marker="$fixture/var/lib/rr-vps/firewall-quarantine"
gate="$fixture/etc/systemd/system/sing-box.service.d/zzzzz-rr-firewall-quarantine.conf"
printf '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
    "$marker" "$marker" >"$gate"
chmod 644 "$gate"
sha256sum "$fixture/etc/argo_vmess.conf" "$fixture/etc/sing-box/config.json" "$gate" >"$fixture/before.sha256"
repair_verify_runtime() { [ "$1" = check ]; }
health_state=inactive
systemctl() {
    [ "$#" -eq 5 ] && [ "$1" = show ] && [ "$3" = -p ] && [ "$5" = --value ] || {
        printf 'UNEXPECTED_SYSTEMCTL\n' >>"$fixture/forbidden"
        return 90
    }
    case "$4" in
        LoadState) printf 'not-found\n' ;;
        FragmentPath|DropInPaths) printf '\n' ;;
        ActiveState)
            if [ "$2" = argo-rr-health.timer ]; then printf '%s\n' "$health_state";
            else printf 'inactive\n'; fi ;;
        *) printf 'UNEXPECTED_PROPERTY\n' >>"$fixture/forbidden"; return 90 ;;
    esac
}
# Check-only mode must never cross into configuration parsing or mutation.
load_config_with_defaults() { : >"$fixture/forbidden"; return 91; }
repair_capture() { : >"$fixture/forbidden"; return 91; }
repair_add_missing_unit() { : >"$fixture/forbidden"; return 91; }
setup_systemd() { : >"$fixture/forbidden"; return 91; }
repair_check_only=true
repair_stage="$fixture/success"
install -d -m 700 "$repair_stage"
(exec 3>"$fixture/success.out"; repair_locked)
grep -Fq 'REPAIR_PREFLIGHT total=31 failed=0 recovery_performed=false' "$fixture/success.out"
grep -Fq 'PREFLIGHT_ONLY_OK recovery_performed=false' "$fixture/success.out"
[ ! -e "$fixture/forbidden" ]

# Three independent mismatches must all appear, including the final service
# query; first-failure exit would hide the later causes.
chmod 644 "$fixture/etc/argo_vmess.conf"
printf '%s\n' 'SENSITIVE_UNKNOWN_DROPIN' >"${gate%/*}/unknown.conf"
health_state=active
repair_stage="$fixture/failure"
install -d -m 700 "$repair_stage"
result=0
(exec 3>"$fixture/failure.out"; repair_locked) || result=$?
[ "$result" = 1 ]
grep -Eq 'name=metadata_.*_etc_argo_vmess.conf result=FAIL' "$fixture/failure.out"
grep -Fq 'name=singbox_dropin_members result=FAIL' "$fixture/failure.out"
grep -Fq 'name=inactive_argo-rr-health.timer result=FAIL' "$fixture/failure.out"
grep -Fq 'REPAIR_PREFLIGHT total=31 failed=3 recovery_performed=false' "$fixture/failure.out"
grep -Fq 'name=inactive_argo-rr-health.service result=PASS' "$fixture/failure.out"
! grep -q 'PREFLIGHT_ONLY_OK' "$fixture/failure.out"
[ ! -e "$fixture/forbidden" ]
[ ! -e "$fixture/etc/systemd/system/sing-box.service" ]
! grep -q 'SENSITIVE_' "$fixture/success.out" "$fixture/failure.out"
sha256sum -c "$fixture/before.sha256" >/dev/null
printf '%s\n' 'REPAIR_PREFLIGHT_REPORT_PASS checks=31 simultaneous_failures=3 systemd=fixture credentials_printed=false recovery_performed=false'
