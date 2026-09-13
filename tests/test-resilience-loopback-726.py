#!/usr/bin/env python3
"""Isolated snapshot/replay checks for the 7.2.6 local subscription exception.

All netfilter writers are a temporary-file model.  No host firewall, services,
or production paths are changed by this suite.
"""

import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = """
set -euo pipefail
source modules/55-resilience.sh
FIREWALL_COMMENT=argo-rr-managed
FIREWALL_BLOCK_COMMENT=argo-rr-managed-block
rr_firewall_writer_gate_is_held() { return 0; }
iptables() { python3 "$MODEL" iptables "$@"; }
ip6tables() { python3 "$MODEL" ip6tables "$@"; }
"""

MODEL = r'''
import os, pathlib, shlex, sys
backend, *args = sys.argv[1:]
assert args[:2] == ["-w", "5"]
assert args[2:4] == ["-t", "filter"]
operation, *values = args[4:]
path = pathlib.Path(os.environ["CASE_ROOT"]) / (backend + ".live")
lines = path.read_text().splitlines()
if operation == "-S":
    print("\n".join(lines))
    raise SystemExit(0)
with open(os.environ["WRITE_LOG"], "a") as output:
    print(shlex.join([backend, *args]), file=output)
if operation == "-D":
    tokens = ["-A", *values]
    index = next(i for i, line in enumerate(lines) if shlex.split(line) == tokens)
    lines.pop(index)
elif operation == "-I":
    chain, index, *values = values
    rule = shlex.join(["-A", chain, *values])
    indices = [i for i, line in enumerate(lines) if shlex.split(line)[:2] == ["-A", chain]]
    ordinal = int(index) - 1
    insertion = indices[ordinal] if ordinal < len(indices) else len(lines)
    lines.insert(insertion, rule)
elif operation == "-A":
    lines.append(shlex.join(["-A", *values]))
else:
    raise AssertionError(operation)
path.write_text("\n".join(lines) + "\n")
'''


def local_rule(backend="iptables", port=20382, tag="rr-local-subscription"):
    address = "127.0.0.1/32" if backend == "iptables" else "::1/128"
    return (f"-A INPUT -i lo -s {address} -d {address} -p tcp "
            f"--dport {port} -m comment --comment {tag} -j ACCEPT")


class ResilienceLoopback(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rr-resilience-loopback-")
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name)
        (self.path / "model.py").write_text(MODEL)
        self.env = dict(os.environ, CASE_ROOT=str(self.path),
                        WRITE_LOG=str(self.path / "writes"),
                        MODEL=str(self.path / "model.py"))

    def run_shell(self, code, *args, success=True):
        result = subprocess.run(["bash", "-c", BASE + code, "rr-test", *args],
                                cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write_rules(self, *rules, name="input"):
        path = self.path / name
        path.write_text("\n".join(rules) + "\n")
        return str(path)

    def malformed_rules(self):
        original = local_rule()
        return [original.replace("-i lo", "-i eth0"),
                original.replace("-s 127.0.0.1/32", "-s 127.0.0.0/8"),
                original.replace("-d 127.0.0.1/32", "-d 0.0.0.0/0"),
                original.replace("-d 127.0.0.1/32 ", ""),
                original.replace("-p tcp", "-p udp"),
                original.replace("-j ACCEPT", "-j DROP"),
                original.replace("20382", "0"),
                original.replace("20382", "65536"),
                original.replace("20382", "020382"),
                original.replace("20382", "20382:20383"),
                original + " -m tcp -m tcp",
                original + " -i lo",
                original + " --comment rr-local-subscription",
                original.replace("--comment rr-local-subscription",
                                 "--comment argo-rr-managed --comment rr-local-subscription"),
                original + " -m conntrack --ctstate NEW",
                original.replace("-i lo", "! -i lo")]

    def test_exact_rules_are_positioned_and_hotfix_remains_foreign(self):
        for backend in ("iptables", "ip6tables"):
            with self.subTest(backend=backend):
                local = local_rule(backend)
                old_hotfix = local_rule(tag="rr-la721-loopback")
                raw = self.write_rules("-P INPUT DROP", old_hotfix, local,
                                       "-A INPUT -m comment --comment administrator -j DROP")
                self.run_shell('rr_restore_filter_managed_firewall_rules filter "$1" '
                               '"$CASE_ROOT/owned" positioned "$2"\n'
                               'rr_restore_filter_managed_firewall_rules filter "$1" '
                               '"$CASE_ROOT/foreign" unmanaged "$2"', raw, backend)
                self.assertEqual((self.path / "owned").read_text(), f"2\t{local}\n")
                foreign = (self.path / "foreign").read_text()
                self.assertIn(old_hotfix, foreign)
                self.assertIn("administrator", foreign)

    def test_kernel_pair_reordering_and_optional_tcp_module(self):
        for backend in ("iptables", "ip6tables"):
            tokens = shlex.split(local_rule(backend))
            pairs = list(zip(tokens[2::2], tokens[3::2]))
            reordered = shlex.join(tokens[:2] + [value for pair in reversed(pairs)
                                                for value in pair] + ["-m", "tcp"])
            raw = self.write_rules(reordered)
            self.run_shell('rr_restore_filter_managed_firewall_rules filter "$1" '
                           '"$CASE_ROOT/owned" managed "$2"', raw, backend)
            self.assertEqual((self.path / "owned").read_text(), reordered + "\n")
            self.write_rules("-P INPUT DROP", name=backend + ".live")
            self.run_shell('rr_restore_run_netfilter_saved_rule "$1" filter -A "$2"',
                           backend, reordered)
            self.assertEqual((self.path / (backend + ".live")).read_text(),
                             "-P INPUT DROP\n" + reordered + "\n")

    def test_reserved_lookalikes_fail_capture_and_cannot_replay(self):
        for rule in self.malformed_rules():
            with self.subTest(rule=rule):
                raw = self.write_rules(rule)
                self.run_shell('rr_restore_filter_managed_firewall_rules filter "$1" '
                               '"$CASE_ROOT/owned" managed iptables', raw, success=False)
                self.run_shell('rr_restore_run_netfilter_saved_rule iptables filter -D "$1"',
                               rule, success=False)
        self.assertFalse((self.path / "writes").exists())

    def test_family_mismatch_cannot_be_captured_or_replayed(self):
        for backend, other in (("iptables", "ip6tables"), ("ip6tables", "iptables")):
            raw = self.write_rules(local_rule(other))
            self.run_shell('rr_restore_filter_managed_firewall_rules filter "$1" '
                           '"$CASE_ROOT/owned" managed "$2"', raw, backend, success=False)
            self.run_shell('rr_restore_run_netfilter_saved_rule "$1" filter -A "$2"',
                           backend, local_rule(other), success=False)
        self.assertFalse((self.path / "writes").exists())

    def test_normalization_excludes_only_exact_owned_local_rules(self):
        old_hotfix = local_rule(tag="rr-la721-loopback")
        unknown = local_rule(tag="user-local-subscription")
        malformed = self.malformed_rules()
        for backend in ("iptables", "ip6tables"):
            raw = self.write_rules("-P INPUT DROP", local_rule(backend), old_hotfix,
                                   unknown, *malformed)
            self.run_shell('rr_restore_normalize_full_firewall_program filter "$1" '
                           '"$2" "" "$CASE_ROOT/normalized"', backend, raw)
            self.assertEqual((self.path / "normalized").read_text(),
                             "\n".join(["-P INPUT DROP", old_hotfix, unknown, *malformed]) + "\n")

    def test_hotfix_and_unknown_tag_cannot_be_replayed(self):
        for tag in ("rr-la721-loopback", "user-local-subscription"):
            self.run_shell('rr_restore_run_netfilter_saved_rule iptables filter -D "$1"',
                           local_rule(tag=tag), success=False)
        self.assertFalse((self.path / "writes").exists())

    def test_clear_and_saved_replay_keep_foreign_rules_and_exact_order(self):
        for backend in ("iptables", "ip6tables"):
            with self.subTest(backend=backend):
                original = ["-P INPUT DROP", local_rule(tag="rr-la721-loopback"),
                            local_rule(backend),
                            "-A INPUT -p tcp --dport 20382 -m comment "
                            "--comment argo-rr-managed-block -j DROP",
                            "-A INPUT -m comment --comment administrator -j DROP"]
                self.write_rules(*original, name=backend + ".live")
                self.run_shell('''
rr_restore_capture_netfilter_snapshot "$1" filter "$CASE_ROOT/owned" "$CASE_ROOT/foreign"
rr_restore_clear_netfilter_table "$1" filter
cp "$CASE_ROOT/$1.live" "$CASE_ROOT/cleared"
while IFS=$'\t' read -r position rule; do
    rr_restore_run_netfilter_saved_rule "$1" filter -I "$rule" "$position"
done < "$CASE_ROOT/owned"
''', backend)
                self.assertEqual((self.path / (backend + ".live")).read_text(),
                                 "\n".join(original) + "\n")
                cleared = (self.path / "cleared").read_text()
                self.assertIn("rr-la721-loopback", cleared)
                self.assertIn("administrator", cleared)
                self.assertNotIn("rr-local-subscription", cleared)
        log = (self.path / "writes").read_text()
        self.assertNotIn("rr-la721-loopback", log)
        self.assertNotIn("administrator", log)

    def test_doctor_repairs_local_path_before_runtime_and_stops_on_failure(self):
        doctor = '''
RR_UPDATE_LOCK_HELD=1
RR_UPDATE_LOCK_FDS_CLOSED=1
SUB_ACCESS_MODE=local
CONFIG_FILE="$CASE_ROOT/config"
SINGBOX_BIN=/bin/true
rr_firewall_fail_closed_quarantine_active() { return 1; }
chmod() { echo permissions; }
systemctl() { echo systemctl; }
rr_singbox_service_start_preflight() { return 0; }
restart_singbox() { return 0; }
managed_singbox_running() { return 0; }
nexus_systemctl_restart_checked() { return 0; }
ensure_runtime_health() { echo runtime >> "$CASE_ROOT/order"; }
generate_node_and_sub() { echo subscription >> "$CASE_ROOT/order"; }
open_configured_firewall() { return 0; }
rr_doctor_add() { echo event "$@"; }
rr_reconcile_local_subscription_loopback() {
    echo loopback >> "$CASE_ROOT/order"
    return "$DOCTOR_STATUS"
}
rr_doctor_repair_locked true true
'''
        self.env["DOCTOR_STATUS"] = "0"
        self.run_shell(doctor)
        self.assertEqual((self.path / "order").read_text().splitlines(),
                         ["loopback", "runtime", "subscription"])
        (self.path / "order").unlink()
        self.env["DOCTOR_STATUS"] = "2"
        result = self.run_shell(doctor, success=False)
        self.assertEqual((self.path / "order").read_text(), "loopback\n")
        self.assertIn("repair_subscription_loopback", result.stdout)
        self.assertNotIn("permissions", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
