#!/usr/bin/env python3
"""Production shell parsers/writers against isolated kernel transcripts.

Rule I/O is emulated; readiness tests use actual ephemeral localhost sockets.
No host firewall, systemd unit, or production file is read or written.
"""

import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PORT = 20382
BLOCK = "argo-rr-managed-block"
ALLOW = "argo-rr-managed"

MOCK = r'''import json, os, shlex, sys
from pathlib import Path
root = Path(os.environ["CASE_ROOT"])
backend, *args = sys.argv[1:]
if args[:1] == ["-w"]: args = args[2:]
table = "filter"
if args[:1] == ["-t"]: table, args = args[1], args[2:]
path = root / (backend + "." + table)
if (root / (backend + ".unreadable")).exists(): raise SystemExit(3)
lines = path.read_text().splitlines()
op, *args = args
if op == "-S":
    for line in lines:
        if not args or shlex.split(line)[1] == args[0]: print(line)
    raise SystemExit(0)
if op not in {"-I", "-A", "-D", "-C"}: raise SystemExit(2)
chain, *args = args
position = 1
if op == "-I" and args and args[0].isdigit(): position, args = int(args[0]), args[1:]
tokens = ["-A", chain] + args
matches = [i for i, line in enumerate(lines) if shlex.split(line) == tokens]
if op == "-C": raise SystemExit(0 if matches else 1)
with (root / "writes").open("a") as out: out.write(json.dumps([backend, op, tokens]) + "\n")
if (root / (backend + ".fail-write")).exists(): raise SystemExit(42)
if op == "-D":
    if not matches: raise SystemExit(1)
    del lines[matches[0]]
elif op == "-A": lines.append(shlex.join(tokens))
else:
    indexes = [i for i, line in enumerate(lines) if shlex.split(line)[:2] == ["-A", chain]]
    if position > len(indexes) + 1: raise SystemExit(2)
    index = indexes[position - 1] if position <= len(indexes) else len(lines)
    lines.insert(index, shlex.join(tokens))
path.write_text("\n".join(lines) + "\n")
'''


def drop(port=PORT):
    return f"-A INPUT -p tcp --dport {port} -m comment --comment {BLOCK} -j DROP"


def scoped(backend, port=PORT, comment="rr-local-subscription"):
    address = "127.0.0.1/32" if backend == "iptables" else "::1/128"
    return (f"-A INPUT -i lo -s {address} -d {address} -p tcp --dport {port} "
            f"-m comment --comment {comment} -j ACCEPT")


class Loopback726Tests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rr-loopback-726-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "mock.py").write_text(MOCK)
        (self.root / "writes").touch()
        for backend in ("iptables", "ip6tables"):
            self.rules(backend, ["-P INPUT ACCEPT", drop()])
            (self.root / (backend + ".nat")).write_text("-P PREROUTING ACCEPT\n")

    def rules(self, backend, lines):
        (self.root / (backend + ".filter")).write_text("\n".join(lines) + "\n")

    def run_shell(self, body, expected=0):
        prelude = f'''
set -euo pipefail
source {shlex.quote(str(REPO / "modules/10-system.sh"))}
FIREWALL_COMMENT={ALLOW}
FIREWALL_BLOCK_COMMENT={BLOCK}
SUB_ACCESS_MODE=local
SUB_PORT={PORT}
is_valid_port() {{ [[ "$1" =~ ^[1-9][0-9]{{0,4}}$ ]] && [ "$1" -le 65535 ]; }}
iptables() {{ python3 "$CASE_ROOT/mock.py" iptables "$@"; }}
ip6tables() {{ python3 "$CASE_ROOT/mock.py" ip6tables "$@"; }}
rr_firewall_writer_gate_is_held() {{ return 0; }}
'''
        result = subprocess.run(["bash", "-c", prelude + body], text=True,
                                capture_output=True, timeout=20,
                                env={**os.environ, "CASE_ROOT": str(self.root)})
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def writes(self):
        return [json.loads(line) for line in (self.root / "writes").read_text().splitlines()]

    def test_exact_drop_requires_scoped_insert_both_families(self):
        out = self.run_shell('for backend in iptables ip6tables; do rr_local_subscription_loopback_plan "$backend" "$SUB_PORT"; done')
        self.assertEqual(out.stdout.splitlines(), ["insert:1", "insert:1"])
        self.assertEqual(self.writes(), [])

    def test_writer_adds_only_exact_rule_before_drop_and_is_idempotent(self):
        self.run_shell('''
for backend in iptables ip6tables; do
  rr_reconcile_netfilter_subscription_loopback "$backend" "$SUB_PORT"
  rr_reconcile_netfilter_subscription_loopback "$backend" "$SUB_PORT"
done
rr_local_subscription_firewall_ready
''')
        self.assertEqual(len(self.writes()), 2)
        for backend in ("iptables", "ip6tables"):
            self.assertEqual((self.root / (backend + ".filter")).read_text().splitlines(),
                             ["-P INPUT ACCEPT", scoped(backend), drop()])

    def test_existing_la_repair_is_preserved_without_duplicate_ipv4(self):
        la = scoped("iptables", comment="rr-la721-loopback")
        self.rules("iptables", ["-P INPUT ACCEPT", la, drop()])
        self.run_shell('for backend in iptables ip6tables; do rr_reconcile_netfilter_subscription_loopback "$backend" "$SUB_PORT"; done')
        self.assertEqual([write[0] for write in self.writes()], ["ip6tables"])
        self.assertIn(la, (self.root / "iptables.filter").read_text())

    def test_administrator_loopback_deny_is_never_bypassed(self):
        self.rules("iptables", ["-P INPUT ACCEPT", "-A INPUT -i lo -j DROP", drop()])
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"', expected=1)
        self.assertEqual(self.writes(), [])

    def test_unknown_matching_extension_is_refused(self):
        self.rules("iptables", ["-P INPUT ACCEPT", "-A INPUT -m owner --uid-owner 123 -j DROP", drop()])
        self.run_shell('rr_local_subscription_loopback_plan iptables "$SUB_PORT"', expected=1)

    def test_disjoint_user_rules_remain_unchanged(self):
        original = ["-P INPUT DROP", "-A INPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT",
                    "-A INPUT -p udp --dport 20382 -j DROP",
                    "-A INPUT -i eth0 -j DROP", "-A INPUT -p tcp --dport 22 -j ACCEPT", drop()]
        self.rules("iptables", original)
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"')
        self.assertEqual((self.root / "iptables.filter").read_text().splitlines(),
                         original[:-1] + [scoped("iptables"), original[-1]])

    def test_default_drop_without_return_path_refuses_before_write(self):
        self.rules("iptables", ["-P INPUT DROP", drop()])
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"', expected=1)
        self.assertEqual(self.writes(), [])

    def test_established_rule_for_only_subscription_destination_is_insufficient(self):
        self.rules("iptables", ["-P INPUT DROP",
            f"-A INPUT -p tcp --dport {PORT} -m conntrack --ctstate ESTABLISHED -j ACCEPT", drop()])
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"', expected=1)
        self.assertEqual(self.writes(), [])

    def test_matching_reply_drop_is_refused_even_with_accept_default(self):
        self.rules("iptables", ["-P INPUT ACCEPT",
            "-A INPUT -i lo -p tcp --dport 45000 -j DROP", drop()])
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"', expected=1)
        self.assertEqual(self.writes(), [])

    def test_ufw_loopback_before_input_is_read_only(self):
        for backend, prefix in (("iptables", "ufw"), ("ip6tables", "ufw6")):
            self.rules(backend, ["-P INPUT DROP", f"-N {prefix}-before-input",
                                f"-A INPUT -j {prefix}-before-input", drop(),
                                f"-A {prefix}-before-input -i lo -j ACCEPT"])
        self.run_shell('rr_reconcile_local_subscription_loopback; rr_local_subscription_firewall_ready')
        self.assertEqual(self.writes(), [])

    def test_user_chain_matching_drop_is_refused(self):
        self.rules("iptables", ["-P INPUT ACCEPT", "-N custom", "-A INPUT -j custom",
                                drop(), "-A custom -i lo -j DROP"])
        self.run_shell('rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"', expected=1)
        self.assertEqual(self.writes(), [])

    def test_candidate_preflights_both_families_before_first_write(self):
        (self.root / "ip6tables.unreadable").touch()
        self.run_shell('''
RR_UPDATE_TRANSACTION=1
rr_firewall_writer_gate_is_held() { return 1; }
rr_update_loopback_migration_is_protected() { return 0; }
rr_reconcile_local_subscription_loopback
''', expected=1)
        self.assertEqual(self.writes(), [])

    def test_candidate_requires_protected_update_and_requests_finalization(self):
        self.run_shell('''
RR_UPDATE_TRANSACTION=1
RR_FIREWALL_FINALIZE_REQUIRED=false
rr_firewall_writer_gate_is_held() { return 1; }
rr_update_loopback_migration_is_protected() { return 1; }
if rr_reconcile_local_subscription_loopback; then exit 9; fi
rr_update_loopback_migration_is_protected() { return 0; }
rr_reconcile_local_subscription_loopback
[ "$RR_FIREWALL_FINALIZE_REQUIRED" = true ]
''')
        self.assertEqual(len(self.writes()), 2)

    def test_tuple_snapshot_compensates_both_families_after_partial_failure(self):
        for name in ("snapshot", "after"):
            (self.root / name).mkdir()
        self.run_shell('''
rr_firewall_capture_protocol_transaction "$CASE_ROOT/snapshot" "$SUB_PORT" tcp netfilter
rr_reconcile_netfilter_subscription_loopback iptables "$SUB_PORT"
touch "$CASE_ROOT/ip6tables.fail-write"
if rr_reconcile_netfilter_subscription_loopback ip6tables "$SUB_PORT"; then exit 9; fi
rm "$CASE_ROOT/ip6tables.fail-write"
rr_firewall_restore_protocol_transaction "$CASE_ROOT/snapshot" "$SUB_PORT" tcp netfilter
rr_firewall_capture_protocol_transaction "$CASE_ROOT/after" "$SUB_PORT" tcp netfilter
rr_firewall_protocol_transaction_exact_match "$CASE_ROOT/snapshot" "$CASE_ROOT/after"
''')
        for backend in ("iptables", "ip6tables"):
            self.assertEqual((self.root / (backend + ".filter")).read_text().splitlines(),
                             ["-P INPUT ACCEPT", drop()])

    def test_namespace_rejects_widened_local_comment(self):
        self.rules("iptables", ["-P INPUT ACCEPT", scoped("iptables").replace("-s 127.0.0.1/32", "-s 127.0.0.0/8"), drop()])
        self.run_shell('rr_netfilter_rr_namespace_is_empty', expected=2)

    def test_tcp_readiness_cannot_be_faked_by_process_arguments(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        proc = self.root / "proc/4242"
        proc.mkdir(parents=True)
        (proc / "cmdline").write_bytes(b"\0".join(value.encode() for value in
            ("python3", "/usr/local/lib/rr/nexus/sub_server.py", str(port), "--bind", "127.0.0.1")) + b"\0")
        (self.root / "sub.pid").write_text("4242\n")
        (self.root / "sub.bind").write_text(f"{port}|127.0.0.1|local||signature|local-http\n")
        command = f'''
SUB_PORT={port}
SUB_PID_FILE="$CASE_ROOT/sub.pid"
SUB_BIND_STATE_FILE="$CASE_ROOT/sub.bind"
RR_PROC_ROOT="$CASE_ROOT/proc"
is_subscription_pid() {{ [ "$1" = 4242 ]; }}
rr_local_subscription_loopback_ready
'''
        self.run_shell(command, expected=1)
        listener.listen(5)
        self.run_shell(command)
        connection, _ = listener.accept()
        connection.close()

    def test_https_transition_removes_only_new_owned_scoped_rule(self):
        original = ["-P INPUT ACCEPT", scoped("iptables", comment="rr-la721-loopback"),
                    scoped("iptables"), drop()]
        self.rules("iptables", original)
        self.run_shell('rr_remove_netfilter_subscription_loopback iptables "$SUB_PORT"')
        self.assertEqual((self.root / "iptables.filter").read_text().splitlines(),
                         [original[0], original[1], original[3]])

    def test_existing_subscription_start_requires_real_tcp_readiness(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        app = self.root / "lib/nexus/sub_server.py"
        app.parent.mkdir(parents=True)
        app.write_text("# isolated installed subscription app fixture\n")
        signature = hashlib.sha256(app.read_bytes()).hexdigest()
        proc = self.root / "proc/4242"
        proc.mkdir(parents=True)
        (proc / "cmdline").write_bytes(b"\0".join(value.encode() for value in
            ("python3", str(app), str(port), "--bind", "127.0.0.1")) + b"\0")
        (self.root / "sub.pid").write_text("4242\n")
        (self.root / "sub.bind").write_text(f"{port}|127.0.0.1|local||{signature}|local-http\n")
        command = f'''
source {shlex.quote(str(REPO / "modules/20-config.sh"))}
SUB_PORT={port}
RR_LIB_DIR="$CASE_ROOT/lib"
SUB_PID_FILE="$CASE_ROOT/sub.pid"
SUB_BIND_STATE_FILE="$CASE_ROOT/sub.bind"
RR_PROC_ROOT="$CASE_ROOT/proc"
rr_firewall_fail_closed_quarantine_active() {{ return 1; }}
ensure_subscription_root() {{ return 0; }}
is_subscription_pid() {{ [ "$1" = 4242 ]; }}
start_subscription_server
'''
        self.run_shell(command, expected=1)
        listener.listen(5)
        self.run_shell(command)
        connection, _ = listener.accept()
        connection.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
