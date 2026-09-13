#!/usr/bin/env python3
"""Exercise recovery transitions with real private files and mocked kernel writes.

No production paths, systemd units, or firewall tables are accessed. Readiness
tests use real loopback sockets on ephemeral ports behind an endpoint adapter.
"""

import contextlib
import errno
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "la_loopback_recovery", REPO / "scripts/recover-la721-firewall-inflight.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
REAL_PATH = Path
REAL_CONNECT = socket.create_connection


@unittest.skipUnless(os.geteuid() == 0, "real file ownership checks require root")
class LoopbackLifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rr-la721-lifecycle-", dir="/root")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.mapping = {}
        self.events = []
        self.calls = []
        self.fail_insert_after_mutation = False
        self.fail_nexus_start = False
        self.raw = {}
        fixture = REPO / "tests/fixtures/la721-firewall-20260913"
        evidence = self.root / "evidence"
        for name in m.RAW_PINS:
            data = (fixture / (name + ".raw")).read_bytes()
            self.raw[name] = data
            self.write("evidence/firewall/" + name + ".raw", data)
        self.live = self.raw.copy()
        self.write("evidence/evidence.complete", b"firewall-evidence-v1\n")
        self.write("evidence/firewall/complete", b"firewall-snapshot-v2\n")
        self.write("evidence/desired.namespace", (fixture / "desired.namespace").read_bytes())
        configs = {
            "/etc/argo_vmess.conf": b"fixture configuration\n",
            "/etc/sing-box/config.json": b"{}\n",
            "/etc/rr-nexus/nexus.json": b'{"listen":"127.0.0.1","port":7900}\n',
        }
        for index, (name, data) in enumerate(configs.items()):
            self.mapping[name] = self.write("config/" + str(index), data)
        self.write("evidence/config.sha256", (m.sha(configs["/etc/argo_vmess.conf"]) + "\n").encode())
        self.saved_original = self.saved_table(self.raw["iptables.filter"], "filter")
        # Preserve an unrelated NAT table through all persistence transitions.
        self.saved_original += self.saved_table(self.raw["iptables.nat"], "nat")
        self.saved_path = self.write("persistence/rules.v4", self.saved_original)
        self.mapping["/etc/iptables/rules.v4"] = self.saved_path
        saved_v6 = b"# unchanged IPv6 saved fixture\n"
        self.mapping["/etc/iptables/rules.v6"] = self.write("persistence/rules.v6", saved_v6)
        self.marker = self.write("marker", m.EXPECTED_MARKER)
        self.stage = self.root / "stage"
        self.stage.mkdir(mode=0o700)

        def mapped_path(value, *args, **kwargs):
            path = REAL_PATH(value, *args, **kwargs)
            return self.mapping.get(str(path), path)

        for name, value in (
            ("Path", mapped_path), ("EVIDENCE", evidence), ("MARKER", self.marker),
            ("CONFIG_PINS", {name: m.sha(data) for name, data in configs.items()}),
            ("PERSISTENCE_PINS", {"/etc/iptables/rules.v4": m.sha(self.saved_original),
                                  "/etc/iptables/rules.v6": m.sha(saved_v6)}),
        ):
            self.stack.enter_context(patch.object(m, name, value))
        self.saved_candidate = m.loopback_persistence_candidate(
            self.saved_original, self.raw["iptables.filter"])
        self.live_candidate = m.loopback_raw_candidate(self.raw["iptables.filter"])
        self.r = m.Recovery(repair_loopback=True)
        self.r.stage = self.stage
        self.r.note = lambda event, **values: self.events.append((event, values))
        self.r.command = self.command
        self.states = {
            name: {"LoadState": "loaded", "ActiveState": "inactive", "SubState": "dead",
                   "UnitFileState": "disabled", "MainPID": "0", "Result": "success"}
            for name in (*m.GUARD_NAMES, "sing-box.service", "rr-nexus.service")
        }
        self.r.unit = lambda name: self.states[name].copy()

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        for parent in path.parents:
            if parent == self.root:
                break
            parent.chmod(0o700)
        path.write_bytes(data)
        path.chmod(0o600)
        return path

    @staticmethod
    def saved_table(raw, table):
        result = [b"# preserved save comment\n", ("*" + table + "\n").encode()]
        for line in raw.splitlines(keepends=True):
            if line.startswith(b"-P "):
                _, chain, policy = line.strip().split()
                result.append(b":" + chain + b" " + policy + b" [27:3489]\n")
            else:
                result.append(line)
        return b"".join(result) + b"COMMIT\n"

    def command(self, args, **kwargs):
        self.calls.append(tuple(args))
        if args[0] in ("iptables", "ip6tables"):
            table = args[args.index("-t") + 1]
            key = args[0] + "." + table
            if "-S" in args:
                return self.live[key]
            self.assertEqual(key, "iptables.filter")
            if "-I" in args:
                pos = args.index("-I")
                self.assertEqual(args[pos + 1:pos + 3], ["INPUT", "12"])
                self.assertEqual(args[pos + 3:], m.shlex.split(m.LOOPBACK_RULE.decode())[2:])
                self.assertEqual(self.live[key], self.raw[key])
                self.live[key] = self.live_candidate
                if self.fail_insert_after_mutation:
                    self.fail_insert_after_mutation = False
                    raise m.Refused("injected_insert_result_failure")
            elif "-D" in args:
                pos = args.index("-D")
                self.assertEqual(args[pos + 1], "INPUT")
                self.assertEqual(args[pos + 2:], m.shlex.split(m.LOOPBACK_RULE.decode())[2:])
                self.assertEqual(self.live[key], self.live_candidate)
                self.live[key] = self.raw[key]
            else:
                self.fail("unexpected firewall mutation: " + repr(args))
            return b""
        self.assertEqual(args[0], "systemctl")
        verb = args[1]
        names = [name for name in args[2:] if not name.startswith("--")]
        if verb == "start" and names == ["rr-nexus.service"] and self.fail_nexus_start:
            raise m.Refused("injected_nexus_start_failure")
        for name in names:
            if verb in ("stop", "disable"):
                self.states[name].update(ActiveState="inactive", SubState="dead", MainPID="0")
            if verb == "disable":
                self.states[name]["UnitFileState"] = "disabled"
            if verb == "enable":
                self.states[name]["UnitFileState"] = "enabled"
            if verb == "start":
                self.states[name].update(ActiveState="active", SubState="running", MainPID="1234")
        return b""

    def prepared_run(self):
        # The unrelated release/host/database checks have their own regression
        # suite; keep real firewall proof, mutation, orphan and cleanup methods.
        for name in ("verify_host", "acquire_locks", "verify_runtime", "verify_transactions",
                     "verify_stopped_units", "backup", "prepare_policy_projection", "patch_health"):
            setattr(self.r, name, lambda: None)
        self.r.helper = lambda operation: self.calls.append(("helper", operation))
        self.r.postverify = lambda: None

    def assert_original(self):
        self.assertEqual(self.live, self.raw)
        self.assertEqual(self.saved_path.read_bytes(), self.saved_original)
        self.assertEqual(self.marker.read_bytes(), m.EXPECTED_MARKER)
        for name in ("sing-box.service", "rr-nexus.service"):
            self.assertEqual(self.states[name]["ActiveState"], "inactive")

    def test_all_four_initial_live_saved_states_converge_and_repeat_without_extra_insert(self):
        for live_repaired in (False, True):
            for saved_repaired in (False, True):
                with self.subTest(live_repaired=live_repaired, saved_repaired=saved_repaired):
                    self.live["iptables.filter"] = self.live_candidate if live_repaired else self.raw["iptables.filter"]
                    self.saved_path.write_bytes(self.saved_candidate if saved_repaired else self.saved_original)
                    self.calls.clear()
                    evidence_before = {path: path.read_bytes() for path in (self.root / "evidence").rglob("*") if path.is_file()}
                    self.r.verify_files_and_firewall()
                    self.r.repair_local_subscription_route()
                    self.r.repair_local_subscription_route()
                    self.assertEqual(self.live["iptables.filter"], self.live_candidate)
                    self.assertEqual(self.saved_path.read_bytes(), self.saved_candidate)
                    inserts = [call for call in self.calls if "-I" in call]
                    self.assertEqual(len(inserts), 0 if live_repaired else 1)
                    for name in self.raw:
                        if name != "iptables.filter":
                            self.assertEqual(self.live[name], self.raw[name])
                    for path, data in evidence_before.items():
                        self.assertEqual(path.read_bytes(), data)

    def test_duplicate_or_moved_live_rule_is_rejected_before_mutation(self):
        malformed = [self.live_candidate + m.LOOPBACK_RULE,
                     self.raw["iptables.filter"] + m.LOOPBACK_RULE]
        for live in malformed:
            with self.subTest(live=live[-160:]):
                self.live["iptables.filter"] = live
                self.calls.clear()
                with self.assertRaisesRegex(m.Refused, "live_loopback_not_exact"):
                    self.r.repair_local_subscription_route()
                self.assertFalse(any("-I" in call or "-D" in call for call in self.calls))
                self.assertEqual(self.saved_path.read_bytes(), self.saved_original)

    def test_duplicate_or_moved_saved_rule_is_rejected_before_mutation(self):
        malformed = [self.saved_candidate + m.LOOPBACK_RULE,
                     self.saved_original + m.LOOPBACK_RULE]
        for saved in malformed:
            with self.subTest(saved=saved[-160:]):
                self.saved_path.write_bytes(saved)
                self.calls.clear()
                with self.assertRaises(m.Refused):
                    self.r.repair_local_subscription_route()
                self.assertEqual(self.calls, [])
                self.assertEqual(self.live, self.raw)

    def test_insert_mutates_then_reports_failure_is_rolled_back_by_run(self):
        self.prepared_run()
        self.fail_insert_after_mutation = True
        self.assertEqual(self.r.run(), 1)
        self.assert_original()
        self.assertTrue(any("-D" in call for call in self.calls))
        protection = [values for event, values in self.events if event == "RECOVERY_PROTECTION"][-1]
        self.assertFalse(protection["cleanup_uncertain"])

    def test_service_start_failure_rolls_back_both_completed_writes(self):
        self.prepared_run()
        self.fail_nexus_start = True
        self.assertEqual(self.r.run(), 1)
        self.assert_original()
        stop_index = self.calls.index(("helper", "stop_subscription"))
        delete_index = next(i for i, call in enumerate(self.calls) if "-D" in call)
        self.assertLess(stop_index, delete_index)
        self.assertTrue(any(event == "ORPHAN_ABORTED" for event, _ in self.events))
        self.assertTrue(any(event == "LOOPBACK_ROLLBACK" for event, _ in self.events))

    def test_persistence_write_failure_after_insert_still_rolls_back_live(self):
        self.prepared_run()
        real_write = m.atomic_write
        failed = False

        def atomic_write(path, data, mode):
            nonlocal failed
            if REAL_PATH(path) == self.saved_path and data == self.saved_candidate and not failed:
                failed = True
                raise OSError("injected persistence failure")
            return real_write(path, data, mode)

        with patch.object(m, "atomic_write", side_effect=atomic_write):
            self.assertEqual(self.r.run(), 1)
        self.assertTrue(failed)
        self.assert_original()

    def test_cleanup_preserves_unknown_saved_change_and_reports_uncertainty(self):
        self.r.repair_local_subscription_route()
        changed = self.saved_candidate + b"# externally changed\n"
        self.saved_path.write_bytes(changed)
        self.r.guard_stopped = True
        self.r.helper = lambda operation: self.calls.append(("helper", operation))
        self.r.protect_failure()
        self.assertEqual(self.saved_path.read_bytes(), changed)
        self.assertEqual(self.live, self.raw)
        protection = [values for event, values in self.events if event == "RECOVERY_PROTECTION"][-1]
        self.assertTrue(protection["cleanup_uncertain"])

    def listener(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        return listener

    def test_readiness_connects_both_real_sockets(self):
        sub_listener, nexus_listener = self.listener(), self.listener()
        nexus_port = nexus_listener.getsockname()[1]
        self.mapping["/etc/rr-nexus/nexus.json"].write_text(json.dumps({"listen": "127.0.0.1", "port": nexus_port}))
        attempted = []

        def connect(endpoint, timeout):
            attempted.append(endpoint)
            actual = sub_listener.getsockname() if endpoint[1] == 20382 else endpoint
            return REAL_CONNECT(actual, timeout=timeout)

        self.r.helper = lambda operation: None
        with patch.object(m.socket, "create_connection", side_effect=connect):
            self.r.start_services()
        self.assertEqual(attempted, [("127.0.0.1", 20382), ("127.0.0.1", nexus_port)])
        self.assertFalse(any(event.endswith("READINESS_FAILED") for event, _ in self.events))

    def test_subscription_timeout_still_probes_nexus_and_reports_each_endpoint(self):
        nexus_listener = self.listener()
        nexus_port = nexus_listener.getsockname()[1]
        self.mapping["/etc/rr-nexus/nexus.json"].write_text(json.dumps({"listen": "127.0.0.1", "port": nexus_port}))
        attempted = []

        def connect(endpoint, timeout):
            attempted.append(endpoint)
            if endpoint[1] == 20382:
                raise TimeoutError(errno.ETIMEDOUT, "injected loopback drop")
            return REAL_CONNECT(endpoint, timeout=timeout)

        self.r.helper = lambda operation: None
        with patch.object(m.socket, "create_connection", side_effect=connect), \
             patch.object(m.time, "monotonic", side_effect=[0, 21, 21]):
            with self.assertRaisesRegex(m.Refused, "services_not_running"):
                self.r.start_services()
        self.assertEqual(attempted, [("127.0.0.1", 20382), ("127.0.0.1", nexus_port)])
        endpoints = [values["endpoints"] for event, values in self.events if event == "ENDPOINT_READINESS_FAILED"][-1]
        self.assertEqual(endpoints[str(("127.0.0.1", nexus_port))], "connected")
        self.assertEqual(endpoints[str(("127.0.0.1", 20382))], "TimeoutError:" + str(errno.ETIMEDOUT))
        self.assertEqual(sum(event == "SERVICE_READINESS_FAILED" for event, _ in self.events), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
