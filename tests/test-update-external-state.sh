#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$REPO_ROOT/scripts/update-external-state.py"
TEST_ROOT=$(mktemp -d /tmp/rr-update-external.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOTFS="$TEST_ROOT/rootfs"
TX_ROOT="$TEST_ROOT/update"
BACKUP="$TX_ROOT/transactions/tx-1/backup"
MOCK_BIN="$TEST_ROOT/bin"
FW_ROOT="$TEST_ROOT/firewall"
SERVICE_ROOT="$TEST_ROOT/services"
mkdir -p "$BACKUP" "$MOCK_BIN" "$FW_ROOT" "$SERVICE_ROOT"
chmod 700 "$TX_ROOT" "$TX_ROOT/transactions" "$TX_ROOT/transactions/tx-1" "$BACKUP"

pass_count=0
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$1"
}
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected=$2 actual=$1)"
}

for path in \
    etc/nginx/sites-available etc/nginx/sites-enabled \
    etc/letsencrypt/renewal-hooks/deploy etc/rr-cloudflared \
    etc/systemd/system; do
    mkdir -p "$ROOTFS/$path"
done
printf 'site-original\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
printf 'port-original\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf.port"
printf 'ip-original\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus-ip.conf"
ln -s ../sites-available/rr-nexus.conf "$ROOTFS/etc/nginx/sites-enabled/rr-nexus.conf"
ln -s ../sites-available/rr-nexus.conf.port "$ROOTFS/etc/nginx/sites-enabled/rr-nexus-port.conf"
printf 'legacy-hook\n' > "$ROOTFS/etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh"
printf 'current-hook\n' > "$ROOTFS/etc/letsencrypt/renewal-hooks/deploy/rr-certificates.sh"
printf 'secret-token\n' > "$ROOTFS/etc/rr-cloudflared/token"
printf 'cloud-unit\n' > "$ROOTFS/etc/systemd/system/cloudflared.service"
chmod 600 "$ROOTFS/etc/rr-cloudflared/token"
printf 'user-site-must-survive\n' > "$ROOTFS/etc/nginx/sites-available/user-site.conf"

printf 'enabled\nactive\n' > "$SERVICE_ROOT/nginx"
printf 'disabled\ninactive\n' > "$SERVICE_ROOT/cloudflared"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
root=${MOCK_SERVICE_ROOT:?}
action=${1:?}
shift
case "$action" in
    daemon-reload) exit 0 ;;
    is-enabled|is-active)
        [ "${1:-}" = --quiet ] && shift
        service=${1:?}
        if [ "$action" = is-enabled ] && grep -qx enabled "$root/$service" 2>/dev/null; then exit 0; fi
        if [ "$action" = is-active ] && grep -qx active "$root/$service" 2>/dev/null; then exit 0; fi
        exit 3
        ;;
    enable|disable|start|stop|reload)
        service=${1:?}
        touch "$root/$service"
        case "$action" in
            enable) sed -i '/^disabled$/d' "$root/$service"; grep -qx enabled "$root/$service" || printf 'enabled\n' >> "$root/$service" ;;
            disable) sed -i '/^enabled$/d' "$root/$service"; grep -qx disabled "$root/$service" || printf 'disabled\n' >> "$root/$service" ;;
            start) sed -i '/^inactive$/d' "$root/$service"; grep -qx active "$root/$service" || printf 'active\n' >> "$root/$service" ;;
            stop) sed -i '/^active$/d' "$root/$service"; grep -qx inactive "$root/$service" || printf 'inactive\n' >> "$root/$service" ;;
            reload) grep -qx active "$root/$service" ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$MOCK_BIN/netfilter" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import shlex
import sys

backend = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if args[:2] == ["-w", "5"]:
    args = args[2:]
if args[:1] != ["-t"] or len(args) < 4:
    raise SystemExit(2)
table = args[1]
operation = args[2]
chain = args[3]
state = pathlib.Path(os.environ["MOCK_FW_ROOT"]) / f"{backend}.{table}.{chain}"
state.touch(exist_ok=True)
lines = state.read_text().splitlines()
if operation == "-S":
    print("\n".join(lines))
    raise SystemExit(0)
if operation not in {"-D", "-I"}:
    raise SystemExit(2)
mutation_log = os.environ.get("MOCK_FW_MUTATION_LOG")
if mutation_log:
    with open(mutation_log, "a", encoding="utf-8") as stream:
        stream.write(f"{backend} {operation}\n")
if operation == "-I":
    position = int(args[4])
    rest = args[5:]
    line = shlex.join(["-A", chain, *rest])
    if position < 1 or position > len(lines) + 1:
        raise SystemExit(1)
    lines.insert(position - 1, line)
else:
    rest = args[4:]
    line = shlex.join(["-A", chain, *rest])
    try:
        lines.remove(line)
    except ValueError:
        raise SystemExit(1)
state.write_text("".join(value + "\n" for value in lines))
PY
cp "$MOCK_BIN/netfilter" "$MOCK_BIN/iptables"
cp "$MOCK_BIN/netfilter" "$MOCK_BIN/ip6tables"

cat > "$MOCK_BIN/ufw" <<'EOF'
#!/bin/bash
printf 'Status: %s\n' "${MOCK_UFW_STATE:-inactive}"
EOF
cat > "$MOCK_BIN/nginx" <<'EOF'
#!/bin/bash
[ "${1:-}" = -t ]
EOF
cat > "$MOCK_BIN/netfilter-persistent" <<'EOF'
#!/bin/bash
[ "${1:-}" = save ]
[ -z "${MOCK_FW_MUTATION_LOG:-}" ] || printf 'netfilter-persistent save\n' >> "$MOCK_FW_MUTATION_LOG"
EOF
chmod 755 "$MOCK_BIN"/* "$HELPER"

cat > "$FW_ROOT/iptables.filter.INPUT" <<'EOF'
-A INPUT -s 10.0.0.1 -j ACCEPT
-A INPUT -p tcp --dport 443 -m comment --comment argo-rr-managed -j ACCEPT
-A INPUT -s 10.0.0.2 -j DROP
-A INPUT -p tcp --dport 444 -m comment --comment user-rule -j ACCEPT
-A INPUT -p tcp --dport 445 -m comment --comment argo-rr-managed-block -j DROP
EOF
cat > "$FW_ROOT/iptables.nat.PREROUTING" <<'EOF'
-A PREROUTING -s 192.0.2.1 -j ACCEPT
-A PREROUTING -p udp --dport 19999 -m comment --comment argo-rr-custom -j REDIRECT --to-ports 442
-A PREROUTING -p udp --dport 20000 -m comment --comment argo-rr-HY2 -j REDIRECT --to-ports 443
-A PREROUTING -s 192.0.2.2 -j ACCEPT
EOF
cat > "$FW_ROOT/ip6tables.filter.INPUT" <<'EOF'
-A INPUT -s 2001:db8::1 -j ACCEPT
-A INPUT -p udp --dport 8443 -m comment --comment argo-rr-managed -j ACCEPT
EOF
: > "$FW_ROOT/ip6tables.nat.PREROUTING"

export PATH="$MOCK_BIN:/usr/bin:/bin"
export RR_EXTERNAL_ROOT="$ROOTFS"
export RR_EXTERNAL_SYSTEMCTL="$MOCK_BIN/systemctl"
export RR_EXTERNAL_NGINX="$MOCK_BIN/nginx"
export RR_EXTERNAL_UFW="$MOCK_BIN/ufw"
export RR_EXTERNAL_IPTABLES="$MOCK_BIN/iptables"
export RR_EXTERNAL_IP6TABLES="$MOCK_BIN/ip6tables"
export RR_EXTERNAL_NETFILTER_PERSISTENT="$MOCK_BIN/netfilter-persistent"
export MOCK_FW_ROOT="$FW_ROOT"
export MOCK_SERVICE_ROOT="$SERVICE_ROOT"
export MOCK_UFW_STATE=inactive
export MOCK_FW_MUTATION_LOG="$TEST_ROOT/firewall-mutations.log"

python3 "$HELPER" snapshot "$BACKUP" --tx-root "$TX_ROOT"
[ -f "$BACKUP/external-state/complete" ] || fail 'snapshot did not publish complete marker'
python3 "$HELPER" verify "$BACKUP" --tx-root "$TX_ROOT"
pass 'snapshot is complete and immediately verifiable'

cp "$FW_ROOT/iptables.filter.INPUT" "$TEST_ROOT/original-filter"
cp "$FW_ROOT/iptables.nat.PREROUTING" "$TEST_ROOT/original-nat"
cp "$FW_ROOT/ip6tables.filter.INPUT" "$TEST_ROOT/original-v6-filter"

# Candidate update changes only RR state and the six fixed RR Nginx paths.
sed -i '/argo-rr-/d' "$FW_ROOT/iptables.filter.INPUT"
sed -i '2i-A INPUT -p tcp --dport 9999 -m comment --comment argo-rr-managed -j ACCEPT' "$FW_ROOT/iptables.filter.INPUT"
sed -i '/--comment argo-rr-HY2 /d; /--comment argo-rr-TU5 /d' "$FW_ROOT/iptables.nat.PREROUTING"
printf '%s\n' '-A PREROUTING -p udp --dport 30000 -m comment --comment argo-rr-TU5 -j REDIRECT --to-ports 8443' >> "$FW_ROOT/iptables.nat.PREROUTING"
sed -i '/argo-rr-/d' "$FW_ROOT/ip6tables.filter.INPUT"
printf 'site-candidate\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
rm -f "$ROOTFS/etc/nginx/sites-enabled/rr-nexus.conf"
ln -s /candidate "$ROOTFS/etc/nginx/sites-enabled/rr-nexus.conf"
printf 'candidate-enabled-file\n' > "$ROOTFS/etc/nginx/sites-enabled/rr-nexus-ip.conf"
rm -f "$ROOTFS/etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh"
printf 'candidate-hook\n' > "$ROOTFS/etc/letsencrypt/renewal-hooks/deploy/rr-certificates.sh"
printf 'candidate-token\n' > "$ROOTFS/etc/rr-cloudflared/token"
printf 'candidate-unit\n' > "$ROOTFS/etc/systemd/system/cloudflared.service"
printf 'disabled\ninactive\n' > "$SERVICE_ROOT/nginx"
printf 'enabled\nactive\n' > "$SERVICE_ROOT/cloudflared"

python3 "$HELPER" restore "$BACKUP" --tx-root "$TX_ROOT"
cmp -s "$FW_ROOT/iptables.filter.INPUT" "$TEST_ROOT/original-filter" || fail 'IPv4 filter order was not exactly restored'
cmp -s "$FW_ROOT/iptables.nat.PREROUTING" "$TEST_ROOT/original-nat" || fail 'IPv4 nat order was not exactly restored'
grep -Fxq -- '-A PREROUTING -p udp --dport 19999 -m comment --comment argo-rr-custom -j REDIRECT --to-ports 442' \
    "$FW_ROOT/iptables.nat.PREROUTING" || fail 'adjacent user argo-rr-custom rule was touched'
cmp -s "$FW_ROOT/ip6tables.filter.INPUT" "$TEST_ROOT/original-v6-filter" || fail 'IPv6 filter order was not exactly restored'
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf")" site-original 'Nginx file was not restored'
assert_eq "$(readlink "$ROOTFS/etc/nginx/sites-enabled/rr-nexus.conf")" ../sites-available/rr-nexus.conf 'Nginx symlink was not restored'
[ ! -e "$ROOTFS/etc/nginx/sites-enabled/rr-nexus-ip.conf" ] || fail 'snapshot-missing managed path was not removed'
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/user-site.conf")" user-site-must-survive 'user Nginx site was touched'
grep -qx enabled "$SERVICE_ROOT/nginx" && grep -qx active "$SERVICE_ROOT/nginx" || fail 'Nginx service state was not restored'
grep -qx disabled "$SERVICE_ROOT/cloudflared" && grep -qx inactive "$SERVICE_ROOT/cloudflared" || fail 'cloudflared service state was not restored'
python3 "$HELPER" verify "$BACKUP" --tx-root "$TX_ROOT"
pass 'restore is exact and leaves unrelated Nginx/firewall state unchanged'

# A concurrent change to a non-RR rule must reject the restore before touching files.
printf 'candidate-again\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
sed -i '1s/10\.0\.0\.1/10.0.0.99/' "$FW_ROOT/iptables.filter.INPUT"
if python3 "$HELPER" restore "$BACKUP" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'restore accepted changed non-RR firewall rules'
fi
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf")" candidate-again 'failed firewall preflight changed filesystem state'
sed -i '1s/10\.0\.0\.99/10.0.0.1/' "$FW_ROOT/iptables.filter.INPUT"
pass 'concurrent non-RR firewall changes fail closed before mutation'

# Active UFW is protected by a read-only invariant: unchanged rules can be
# verified/restored without handing raw netfilter ownership to the updater.
python3 "$HELPER" restore "$BACKUP" --tx-root "$TX_ROOT"
BACKUP_UFW="$TX_ROOT/transactions/tx-ufw/backup"
mkdir -p "$BACKUP_UFW"
chmod 700 "$TX_ROOT/transactions/tx-ufw" "$BACKUP_UFW"
export MOCK_UFW_STATE=active
python3 "$HELPER" snapshot "$BACKUP_UFW" --tx-root "$TX_ROOT"
python3 "$HELPER" verify "$BACKUP_UFW" --tx-root "$TX_ROOT"
printf 'active-ufw-candidate\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
: > "$MOCK_FW_MUTATION_LOG"
python3 "$HELPER" restore "$BACKUP_UFW" --tx-root "$TX_ROOT"
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf")" site-original 'active-UFW restore did not restore Nginx state'
[ ! -s "$MOCK_FW_MUTATION_LOG" ] || fail 'active-UFW restore mutated netfilter state'
python3 "$HELPER" verify "$BACKUP_UFW" --tx-root "$TX_ROOT"
pass 'active UFW snapshot and unchanged read-only restore succeed without firewall mutation'

# Any live rule drift rejects rollback before the first managed file changes.
printf 'active-ufw-candidate-again\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
sed -i '1s/10\.0\.0\.1/10.0.0.77/' "$FW_ROOT/iptables.filter.INPUT"
: > "$MOCK_FW_MUTATION_LOG"
if python3 "$HELPER" restore "$BACKUP_UFW" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'active-UFW restore accepted changed firewall rules'
fi
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf")" active-ufw-candidate-again 'active-UFW firewall failure changed Nginx state'
[ ! -s "$MOCK_FW_MUTATION_LOG" ] || fail 'failed active-UFW restore mutated netfilter state'
sed -i '1s/10\.0\.0\.77/10.0.0.1/' "$FW_ROOT/iptables.filter.INPUT"
export MOCK_UFW_STATE=inactive
pass 'active UFW rule drift fails closed before filesystem or firewall mutation'

# A firewall backend that did not exist in the snapshot cannot be made absent
# again by the helper.  Reject that mismatch before restoring the first file,
# even when the newly appeared backend contains no rules.
BACKUP_APPEARED="$TX_ROOT/transactions/tx-backend-appeared/backup"
mkdir -p "$BACKUP_APPEARED"
chmod 700 "$TX_ROOT/transactions/tx-backend-appeared" "$BACKUP_APPEARED"
cp "$FW_ROOT/ip6tables.filter.INPUT" "$TEST_ROOT/ip6-filter-before-appeared"
: > "$FW_ROOT/ip6tables.filter.INPUT"
: > "$FW_ROOT/ip6tables.nat.PREROUTING"
mv "$MOCK_BIN/ip6tables" "$MOCK_BIN/ip6tables.hidden"
unset RR_EXTERNAL_IP6TABLES
python3 "$HELPER" snapshot "$BACKUP_APPEARED" --tx-root "$TX_ROOT"
mv "$MOCK_BIN/ip6tables.hidden" "$MOCK_BIN/ip6tables"
export RR_EXTERNAL_IP6TABLES="$MOCK_BIN/ip6tables"
printf 'backend-appeared-candidate\n' > "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf"
if python3 "$HELPER" restore "$BACKUP_APPEARED" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'restore accepted a firewall backend that appeared during the transaction'
fi
assert_eq "$(cat "$ROOTFS/etc/nginx/sites-available/rr-nexus.conf")" \
    backend-appeared-candidate 'appeared-backend preflight changed filesystem state'
cp "$TEST_ROOT/ip6-filter-before-appeared" "$FW_ROOT/ip6tables.filter.INPUT"
pass 'a newly appeared firewall backend fails before filesystem mutation'

# A fresh machine may not have Nginx, Certbot or RR cloudflared directories yet.
FRESH_ROOT="$TEST_ROOT/fresh-root"
BACKUP_FRESH="$TX_ROOT/transactions/tx-fresh/backup"
mkdir -p "$FRESH_ROOT" "$BACKUP_FRESH"
chmod 700 "$FRESH_ROOT" "$TX_ROOT/transactions/tx-fresh" "$BACKUP_FRESH"
export RR_EXTERNAL_ROOT="$FRESH_ROOT"
python3 "$HELPER" snapshot "$BACKUP_FRESH" --tx-root "$TX_ROOT"
python3 "$HELPER" verify "$BACKUP_FRESH" --tx-root "$TX_ROOT"

# Even a snapshot-missing path must not be removed through a candidate-created
# symlinked parent during rollback.
VICTIM_ROOT="$TEST_ROOT/victim-root"
mkdir -p "$VICTIM_ROOT/etc/nginx/sites-available"
printf 'victim-must-survive\n' > "$VICTIM_ROOT/etc/nginx/sites-available/rr-nexus.conf"
ln -s "$VICTIM_ROOT/etc" "$FRESH_ROOT/etc"
if python3 "$HELPER" restore "$BACKUP_FRESH" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'restore followed a candidate-created parent symlink'
fi
grep -qx victim-must-survive \
    "$VICTIM_ROOT/etc/nginx/sites-available/rr-nexus.conf" || \
    fail 'rollback modified a victim through a parent symlink'
rm -f "$FRESH_ROOT/etc"
export RR_EXTERNAL_ROOT="$ROOTFS"
pass 'fresh hosts without optional managed directories can be snapshotted'

# Backup path validation rejects both an outside directory and a symlinked backup.
OUTSIDE="$TEST_ROOT/outside"
mkdir -p "$OUTSIDE"
if python3 "$HELPER" snapshot "$OUTSIDE" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'outside backup directory was accepted'
fi
mkdir -p "$TX_ROOT/transactions/tx-link"
ln -s "$OUTSIDE" "$TX_ROOT/transactions/tx-link/backup"
if python3 "$HELPER" snapshot "$TX_ROOT/transactions/tx-link/backup" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'symlinked backup directory was accepted'
fi
pass 'backup directory confinement and no-symlink checks hold'

# The complete marker binds state.json; tampering is rejected.
printf ' ' >> "$BACKUP/external-state/state.json"
if python3 "$HELPER" verify "$BACKUP" --tx-root "$TX_ROOT" >/dev/null 2>&1; then
    fail 'tampered snapshot was accepted'
fi
pass 'complete marker detects snapshot state tampering'

printf 'All %d update external-state tests passed.\n' "$pass_count"
