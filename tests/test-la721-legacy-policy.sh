#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
baseline=${RR_LA721_BASELINE_ROOT:-$repo}
recorded="$repo/tests/fixtures/la721-firewall-20260913"
fixture=$(mktemp -d /tmp/rr-la721-policy.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077
fail() { printf 'LA721 legacy policy: FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$fixture/original/firewall" "$fixture/projection/firewall" "$fixture/live"
cp "$recorded"/*.raw "$fixture/original/firewall/"
cp "$recorded"/*.raw "$fixture/live/"
cp "$recorded/desired.namespace" "$fixture/desired.namespace"

python3 - "$repo" "$fixture" <<'PY'
import hashlib
import importlib.util
from pathlib import Path
import sys

repo, fixture = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('la_recovery', repo / 'scripts/recover-la721-firewall-inflight.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert hashlib.sha256((fixture / 'desired.namespace').read_bytes()).hexdigest() == module.DESIRED_SHA
for name, expected in module.RAW_PINS.items():
    data = (fixture / 'original/firewall' / (name + '.raw')).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected, name
    projected = module.prove_redundant_legacy_allow(data) if name.endswith('.filter') else data
    (fixture / 'projection/firewall' / (name + '.raw')).write_bytes(projected)
    if name.endswith('.filter'):
        removed = b'-A INPUT -p tcp -m tcp --dport 22049 -m comment --comment argo-rr-managed -j ACCEPT\n'
        assert data.count(removed) == 1
        assert projected == data.replace(removed, b'', 1)
    else:
        assert projected == data
print('RECORDED_FIREWALL_PINS_AND_MINIMAL_PROJECTION_OK')
PY

# Real production validators and Python parsers; only kernel rule reads are
# emulated. They always observe original live fixtures, including 22049.
# shellcheck disable=SC1091
source "$baseline/modules/10-system.sh"
# shellcheck disable=SC1091
source "$baseline/modules/30-singbox.sh"
FIREWALL_COMMENT=argo-rr-managed
FIREWALL_BLOCK_COMMENT=argo-rr-managed-block
ENTRY_IP_MODE=ipv4
rr_ufw_backend_state() { return 1; }
rr_inactive_ufw_protocol_is_disjoint() { return 0; }

cat > "$fixture/backend.py" <<'PY'
from pathlib import Path
import shlex
import sys

root = Path(sys.argv[1])
backend = sys.argv[2]
args = sys.argv[3:]
with (root / 'observations').open('a') as log:
    log.write(backend + ' ' + ' '.join(args) + '\n')
if args[:2] == ['-w', '5']:
    args = args[2:]
table = 'filter'
if args[:1] == ['-t'] and len(args) >= 2:
    table = args[1]
    args = args[2:]
if table not in {'filter', 'nat'} or not args:
    raise SystemExit(90)
data = (root / 'live' / (backend + '.' + table + '.raw')).read_text()
if args[0] == '-S' and len(args) in {1, 2}:
    if len(args) == 1:
        print(data, end='')
    else:
        chain = args[1]
        for line in data.splitlines():
            tokens = shlex.split(line)
            if len(tokens) >= 2 and tokens[1] == chain:
                print(line)
    raise SystemExit(0)
if args[0] == '-C':
    def normalize(tokens):
        result = []
        index = 0
        while index < len(tokens):
            if tokens[index:index + 2] in (['-m', 'tcp'], ['-m', 'udp']):
                index += 2
            else:
                result.append(tokens[index])
                index += 1
        return result
    target = normalize(['-A', *args[1:]])
    raise SystemExit(0 if any(normalize(shlex.split(line)) == target
                             for line in data.splitlines()) else 1)
with (root / 'writes').open('a') as log:
    log.write(backend + ' ' + ' '.join(args) + '\n')
raise SystemExit(90)
PY
iptables() { python3 "$fixture/backend.py" "$fixture" iptables "$@"; }
ip6tables() { python3 "$fixture/backend.py" "$fixture" ip6tables "$@"; }
save_firewall() { printf 'save\n' >> "$fixture/writes"; return 90; }
systemctl() { printf 'systemctl\n' >> "$fixture/writes"; return 90; }
: > "$fixture/observations"
: > "$fixture/writes"

sha256sum "$fixture/live"/*.raw "$fixture/original/firewall"/*.raw "$fixture/desired.namespace" > "$fixture/preserved.sha256"

if rr_firewall_verify_desired_namespace "$fixture/original" "$fixture/desired.namespace"; then
    fail 'original extra managed allow unexpectedly passed the strict namespace check'
fi
[ ! -s "$fixture/observations" ] || fail 'original rejection did not occur in the namespace stage'
printf 'ORIGINAL_DESIRED_POLICY_FAILURE_REPRODUCED\n'

rr_firewall_verify_desired_namespace "$fixture/projection" "$fixture/desired.namespace" || \
    fail 'verified projection failed against unchanged live rules'
grep -q 'iptables .* -C INPUT.*--dport 20382.*DROP' "$fixture/observations" || fail 'live subscription DROP was not checked'
grep -q 'ip6tables .* -t nat -S' "$fixture/observations" || fail 'live IPv6 first-match was not checked'
grep -q -- '--dport 22049' "$fixture/live/iptables.filter.raw" || fail 'live legacy rule was removed'
grep -q -- '--dport 22049' "$fixture/live/ip6tables.filter.raw" || fail 'live IPv6 legacy rule was removed'
grep -q -- '--dport 2000:3000 -j DNAT --to-destination :42536' "$fixture/live/ip6tables.nat.raw" || fail 'foreign IPv6 NAT changed'
[ ! -s "$fixture/writes" ] || fail 'validation attempted a write'
sha256sum -c "$fixture/preserved.sha256" >/dev/null || fail 'validation changed evidence/live/desired'
printf 'PROJECTION_WITH_UNCHANGED_LIVE_FILTER_AND_FOREIGN_NAT_OK\n'

# The scoped loopback exception must leave the production external-policy
# proof intact. Exercise the actual native parser against repaired live rules.
python3 - "$repo" "$fixture" <<'PY'
import importlib.util
from pathlib import Path
import sys
repo, fixture = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('la_recovery', repo / 'scripts/recover-la721-firewall-inflight.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = fixture / 'live/iptables.filter.raw'
path.write_bytes(module.loopback_raw_candidate(path.read_bytes()))
PY
rr_firewall_verify_desired_namespace "$fixture/projection" "$fixture/desired.namespace" || \
    fail 'exact loopback exception broke external-policy verification'
sed -i '/--comment argo-rr-managed-block -j DROP/d' "$fixture/live/iptables.filter.raw"
if rr_firewall_verify_desired_namespace "$fixture/projection" "$fixture/desired.namespace" >/dev/null 2>&1; then
    fail 'loopback exception concealed missing external subscription DROP'
fi
cp "$recorded/iptables.filter.raw" "$fixture/live/iptables.filter.raw"
printf 'SCOPED_LOOPBACK_WITH_EXTERNAL_DROP_REQUIRED_OK\n'

# The projection is not a bypass for required rules: the native live predicate
# still refuses a missing DROP even though the projected snapshot contains it.
sed -i '/--dport 20382 /d' "$fixture/live/iptables.filter.raw"
if rr_firewall_verify_desired_namespace "$fixture/projection" "$fixture/desired.namespace" >/dev/null 2>&1; then
    fail 'missing live subscription DROP was accepted'
fi
cp "$recorded/iptables.filter.raw" "$fixture/live/iptables.filter.raw"
printf 'MISSING_LIVE_DROP_STILL_REFUSED\n'

# A changed foreign NAT range overlapping HY2 must still fail first-match;
# only the two redundant filter lines are eligible for projection.
sed -i 's/--dport 2000:3000 /--dport 23635:23846 /' "$fixture/live/ip6tables.nat.raw"
if rr_firewall_verify_desired_namespace "$fixture/projection" "$fixture/desired.namespace" >/dev/null 2>&1; then
    fail 'shadowing foreign NAT rule was accepted'
fi
cp "$recorded/ip6tables.nat.raw" "$fixture/live/ip6tables.nat.raw"
printf 'OVERLAPPING_FOREIGN_NAT_STILL_REFUSED\n'

[ ! -s "$fixture/writes" ] || fail 'negative controls attempted a write'
sha256sum -c "$fixture/preserved.sha256" >/dev/null || fail 'original fixtures not restored'
printf 'LA721_LEGACY_POLICY_TESTS_OK\n'
