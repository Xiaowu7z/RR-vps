#!/bin/bash
# Execute the unchanged production 7.2.1 preflight with both actual module
# identities. The old guard's full release proof is covered separately by
# test-upgrade-721-release.sh; this checks the local hotfix cannot self-lock it.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/rr-721-hotfix-preflight.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077
python3 "$repo/tests/la721_baseline.py" "$fixture/old"
python3 "$repo/scripts/patch-health-hop-observation.py" \
    < "$fixture/old/modules/60-update.sh" > "$fixture/patched-60.sh"
source "$fixture/old/modules/55-resilience.sh"
RR_RESTORE_LOCK_FILE="$fixture/locks/update.lock"
SINGBOX_BIN="$fixture/absent-core"
check_supported_os() { return 0; }
# These host facilities are independent of the old runtime's module hash.
# Keep the real root-only lock implementation and JSON preflight unchanged.
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1000000 100000 900000 10%% /usr/local\n'; }
sqlite3() { printf 'ok\n'; }
for profile in original hotfix; do
    if [ "$profile" = original ]; then source "$fixture/old/modules/60-update.sh"
    else source "$fixture/patched-60.sh"; fi
    rr_update_preflight > "$fixture/$profile.json"
    jq -e '.ok == true and .update_lock == "available"' "$fixture/$profile.json" >/dev/null
    printf 'PRODUCTION_721_PREFLIGHT_OK %s\n' "$profile"
done
echo '7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d  '"$fixture/old/modules/60-update.sh" | sha256sum -c - >/dev/null
echo 'ecc1eeaf5e7ae73e2e337d94b2abcd4acf59b4bcca9eb70b1edeef92cd6e30c7  '"$fixture/patched-60.sh" | sha256sum -c - >/dev/null
printf 'OFFICIAL_AND_LA_HOTFIX_PREFLIGHT_IDENTITIES_PRESERVED_OK\n'
