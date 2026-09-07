#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
eval "$(awk '/^rr_existing_https_upgrade_is_prepared\(\) \{/{p=1} p{print} p && /^}$/{exit}' "$repo/scripts/install-core.sh")"
rr_error() { printf '%s\n' "$*" >> "$work/diagnostic"; }
printf '%s\n' '{"mode":"public","domain":"panel.example.com"}' > "$work/nexus.json"
printf '%s\n' '[renewalparams]' 'authenticator = nginx' 'installer = nginx' > "$work/panel.example.com.conf"
sha256sum "$work/nexus.json" "$work/panel.example.com.conf" > "$work/before"
if rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"; then exit 1; fi
grep -q 'upgrade_preflight=legacy-domain-renewal' "$work/diagnostic"
sha256sum -c "$work/before" >/dev/null
printf '%s\n' '[renewalparams]' 'authenticator = webroot' '[[webroot_map]]' 'panel.example.com = /var/www/rr-nexus-certbot' > "$work/panel.example.com.conf"
rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"
rm "$work/panel.example.com.conf"
if rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"; then exit 1; fi
printf '%s\n' '{"mode":"local"}' > "$work/nexus.json"
rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"
printf '%s\n' '{"mode":"public","domain":"192.0.2.1"}' > "$work/nexus.json"
rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"
printf '%s\n' '{' > "$work/nexus.json"
if rr_existing_https_upgrade_is_prepared "$work/nexus.json" "$work"; then exit 1; fi
eval "$(awk '/^rr_existing_https_upgrade_is_prepared\(\) \{/{p=1} p{print} p && /^}$/{exit}' "$repo/scripts/install-core.sh" | sed '1s/rr_existing_https_upgrade_is_prepared/real_https_preflight/')"
rr_existing_https_upgrade_is_prepared() { real_https_preflight "$work/nexus.json" "$work"; }
eval "$(awk '/^rr_install_release\(\) \{/{p=1} p{print} p && /^}$/{exit}' "$repo/scripts/install-core.sh")"
RR_MODE=--upgrade
RR_LIB_DIR="$work/runtime"
PAYLOAD_DIR="$work/payload"
mkdir -p "$RR_LIB_DIR/modules" "$PAYLOAD_DIR/modules"
printf 'SCRIPT_VERSION="7.0.2"\n' > "$RR_LIB_DIR/modules/00-runtime.sh"
printf 'SCRIPT_VERSION="7.2.1"\n' > "$PAYLOAD_DIR/modules/00-runtime.sh"
rr_version_ge() { return 0; }
rr_snapshot_runtime() { touch "$work/snapshot-started"; return 1; }
printf '%s\n' '{"mode":"public","domain":"panel.example.com"}' > "$work/nexus.json"
printf '%s\n' '[renewalparams]' 'authenticator = nginx' > "$work/panel.example.com.conf"
if rr_install_release; then exit 1; fi
test ! -e "$work/snapshot-started"
printf '%s\n' '[renewalparams]' 'authenticator = webroot' > "$work/panel.example.com.conf"
if rr_install_release; then exit 1; fi
test -e "$work/snapshot-started"
python3 "$repo/tests/test-legacy-nginx-702.py"
echo 'Legacy HTTPS preflight: PASS'
