#!/usr/bin/env python3
"""Local recovery regression tests; no live services or firewall are changed."""
import contextlib
import fcntl
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "la_recovery", REPO / "scripts/recover-la721-firewall-inflight.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


@unittest.skipUnless(os.geteuid() == 0, "root ownership validation needs root")
class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rr-la721-test-", dir="/root")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def file(self, name, data, mode=0o600):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        p.write_bytes(data)
        p.chmod(mode)
        return p

    def recovery(self):
        r = m.Recovery()
        r.note = lambda *args, **kwargs: None
        return r

    def test_marker_and_patch_match_official_baseline(self):
        self.assertEqual(m.sha(m.EXPECTED_MARKER), m.MARKER_SHA)
        baseline = Path(os.environ.get("RR_HEALTH_HOP_BASELINE_ROOT", REPO))
        source = (baseline / "modules/60-update.sh").read_bytes()
        self.assertEqual(m.sha(m.transform_bytes(source)), m.PATCHED_SHA256)
        with self.assertRaises(ValueError):
            m.transform_bytes(source + b"\n")

    def test_legacy_projection_preserves_every_tcp_udp_port_decision(self):
        fixture = REPO / "tests/fixtures/la721-firewall-20260913"
        def decisions(program, proto):
            # Independent evaluator for the concrete simple incident rules.
            # Walk backwards so the first matching rule wins over later rules.
            tokens = [shlex.split(line) for line in program.decode().splitlines()]
            policy = next(row[2] for row in tokens if row[:2] == ["-P", "INPUT"])
            result = [policy] * 65536
            for row in reversed(tokens):
                if row[:2] == ["-A", "INPUT"] and row[row.index("-p") + 1] == proto:
                    result[int(row[row.index("--dport") + 1])] = row[row.index("-j") + 1]
            return result
        for backend in ("iptables", "ip6tables"):
            original = (fixture / (backend + ".filter.raw")).read_bytes()
            projected = m.prove_redundant_legacy_allow(original)
            self.assertEqual(original.count(b"--dport 22049 "), 1)
            self.assertNotIn(b"--dport 22049 ", projected)
            for proto in ("tcp", "udp"):
                self.assertEqual(decisions(original, proto), decisions(projected, proto))
            self.assertEqual(decisions(projected, "tcp")[20382], "DROP")

    def test_legacy_projection_refuses_changed_policy_and_overlap(self):
        original = (REPO / "tests/fixtures/la721-firewall-20260913/iptables.filter.raw").read_bytes()
        legacy = next(line for line in original.splitlines(keepends=True) if b"--dport 22049 " in line)
        bad_programs = [
            original.replace(b"-P INPUT ACCEPT", b"-P INPUT DROP"),
            original.replace(b"-P INPUT ACCEPT", b"-P INPUT QUEUE"),
            original + legacy,
            original.replace(legacy, b""),
            original + b"-A INPUT -p tcp -m tcp --dport 22049 -j DROP\n",
            original + b"-A INPUT -p tcp -m tcp --dport 22049 -j ACCEPT\n",
            original + b"-A INPUT -j CUSTOM_CHAIN\n",
            original + b"-A INPUT -p tcp -m multiport --dports 22048:22050 -j DROP\n",
            original.replace(legacy, legacy.replace(b"-j ACCEPT", b"-j DROP")),
        ]
        for program in bad_programs:
            with self.subTest(program=program[-90:]):
                with self.assertRaises(m.Refused):
                    m.prove_redundant_legacy_allow(program)

    def test_projection_is_private_and_keeps_original_evidence(self):
        fixture = REPO / "tests/fixtures/la721-firewall-20260913"
        evidence = self.root / "evidence"
        before = {}
        for original in fixture.iterdir():
            relative = original.name if original.name == "desired.namespace" else "firewall/" + original.name
            path = self.file("evidence/" + relative, original.read_bytes())
            before[path] = path.read_bytes()
        stage = self.root / "stage"
        stage.mkdir(mode=0o700)
        r = self.recovery()
        r.stage = stage
        with patch.object(m, "EVIDENCE", evidence):
            r.prepare_policy_projection()
        self.assertTrue((stage / "policy-projection/proof.json").is_file())
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents)
        for name in m.RAW_PINS:
            original = (evidence / "firewall" / (name + ".raw")).read_bytes()
            projected = (stage / "policy-projection/firewall" / (name + ".raw")).read_bytes()
            self.assertEqual(projected, m.prove_redundant_legacy_allow(original) if name.endswith(".filter") else original)

    def test_helper_checks_private_projection_and_reports_later_failures(self):
        stage = self.root / "stage"
        (stage / "modules").mkdir(parents=True, mode=0o700)
        expected = stage / "policy-projection"
        module = """
SUB_ACCESS_MODE=local SUB_PORT=20382 SUB_ROOT=/tmp/sub_server SINGBOX_BIN=/usr/bin/true
load_config_with_defaults() { return 0; }
rr_firewall_load_inflight_marker() { return 0; }
rr_restore_verify_firewall_pre_mutation_snapshot() { return 0; }
rr_firewall_verify_desired_namespace() { [ "$1" = 'PROJECTION' ]; }
rr_firewall_quarantine_supervisor_effective() { return 1; }
rr_singbox_service_guards_are_effective() { return 0; }
rr_singbox_certificate_start_gate() { return 0; }
nexus_service_effective_identity_is_exact() { return 0; }
nexus_service_effective_guards_are_exact() { return 0; }
managed_singbox_running() { return 1; }
subscription_server_running() { return 1; }
""".replace("PROJECTION", str(expected))
        self.file("stage/modules/fixture.sh", module.encode())
        r = self.recovery()
        r.stage = stage
        events = []
        r.note = lambda event, **values: events.append((event, values))
        with self.assertRaises(m.Refused):
            r.helper("verify")
        results = {values["name"]: values["rc"] for event, values in events if event == "RECOVERY_PREDICATE"}
        self.assertEqual(results["desired_policy"], 0)
        self.assertEqual(results["supervisor"], 1)
        self.assertEqual(results["nexus_guards"], 0)
        self.assertEqual(results["subscription_idle"], 0)

    def test_read_refuses_untrusted_files_and_parents(self):
        good = self.file("good", b"original")
        self.assertEqual(m.pinned(good, m.sha(b"original")), b"original")
        with self.assertRaises(m.Refused):
            m.pinned(good, "0" * 64)
        link = self.root / "link"
        link.symlink_to(good)
        with self.assertRaises(OSError):
            m.read_regular(link)
        os.link(good, self.root / "hardlink")
        with self.assertRaises(m.Refused):
            m.read_regular(good)
        writable = self.file("writable", b"x", 0o666)
        with self.assertRaises(m.Refused):
            m.read_regular(writable)
        unsafe = self.file("unsafe/file", b"x")
        unsafe.parent.chmod(0o777)
        with self.assertRaises(m.Refused):
            m.read_regular(unsafe)
        fifo = self.root / "fifo"
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(m.Refused):
            m.read_regular(fifo)

    def test_atomic_write_keeps_private_mode(self):
        target = self.file("atomic", b"old")
        m.atomic_write(target, b"new", 0o600)
        self.assertEqual(m.read_regular(target), b"new")
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.root.glob(".rr-la721-*")), [])

    @contextlib.contextmanager
    def lock_paths(self):
        mapping = {name: self.file("locks/" + str(i), b"") for i, name in enumerate((
            "/run/rr-vps/locks/update.lock", "/run/lock/rr-update.lock",
            "/run/rr-vps/locks/firewall.lock"))}
        real_open, real_stat, real_read = os.open, os.stat, m.read_regular
        def remap(path):
            return mapping.get(str(path), path)
        with patch.object(m, "read_regular", side_effect=lambda p, *a: real_read(remap(p), *a)), \
             patch.object(m.os, "open", side_effect=lambda p, *a, **k: real_open(remap(p), *a, **k)), \
             patch.object(m.os, "stat", side_effect=lambda p, *a, **k: real_stat(remap(p), *a, **k)), \
             patch.object(m.os.path, "lexists", return_value=True):
            yield mapping

    def test_real_flocks_exclude_other_process_and_are_not_inherited(self):
        with self.lock_paths() as mapping:
            r = self.recovery()
            try:
                r.acquire_locks()
                self.assertEqual(len(r.fds), 3)
                for path in mapping.values():
                    result = subprocess.run(["python3", "-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", str(path)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                for fd, _ in r.fds:
                    self.assertFalse(os.get_inheritable(fd))
            finally:
                for fd, _ in r.fds:
                    os.close(fd)
        # The same locks become available after the parent releases them.
        for path in mapping.values():
            with path.open("r+") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_busy_real_lock_stops_before_any_recovery(self):
        with self.lock_paths() as mapping:
            lock = mapping["/run/rr-vps/locks/update.lock"].open("r+")
            self.addCleanup(lock.close)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.recovery()
            try:
                with patch.object(m.time, "monotonic", side_effect=[0, 21]):
                    with self.assertRaisesRegex(m.Refused, "writer_busy"):
                        r.acquire_locks()
            finally:
                for fd, _ in r.fds:
                    os.close(fd)

    def test_complete_live_program_change_is_rejected(self):
        evidence = self.root / "evidence"
        self.file("evidence/evidence.complete", b"firewall-evidence-v1\n")
        self.file("evidence/firewall/complete", b"firewall-snapshot-v2\n")
        cfg = self.file("config", b"test configuration")
        desired = b"protocol|closed|20382|tcp\n"
        self.file("evidence/desired.namespace", desired)
        self.file("evidence/config.sha256", (m.sha(cfg.read_bytes()) + "\n").encode())
        marker = self.file("marker", m.EXPECTED_MARKER)
        programs = {name: ("-P INPUT ACCEPT\n# fixture " + name + "\n").encode() for name in m.RAW_PINS}
        for name, data in programs.items():
            self.file("evidence/firewall/" + name + ".raw", data)
        r = self.recovery()
        r.command = lambda args, **kwargs: programs[args[0] + "." + args[4]]
        real_pinned = m.pinned
        with patch.object(m, "EVIDENCE", evidence), patch.object(m, "MARKER", marker), \
             patch.object(m, "CONFIG_PINS", {"/etc/argo_vmess.conf": m.sha(cfg.read_bytes())}), \
             patch.object(m, "PERSISTENCE_PINS", {}), patch.object(m, "DESIRED_SHA", m.sha(desired)), \
             patch.object(m, "RAW_PINS", {key: m.sha(value) for key, value in programs.items()}), \
             patch.object(m, "pinned", side_effect=lambda p, digest: real_pinned(cfg if str(p) == "/etc/argo_vmess.conf" else p, digest)):
            r.verify_files_and_firewall()
            programs["ip6tables.nat"] += b"-A PREROUTING -j DROP\n"
            with self.assertRaisesRegex(m.Refused, "live_firewall_changed:ip6tables.nat"):
                r.verify_files_and_firewall()
            self.assertEqual(marker.read_bytes(), m.EXPECTED_MARKER)

    def test_orphan_abort_is_after_proof_and_archives_exact_marker(self):
        marker = self.file("marker", m.EXPECTED_MARKER)
        stage = self.root / "stage"
        stage.mkdir(mode=0o700)
        r = self.recovery()
        r.stage = stage
        calls = []
        states = {name: {"ActiveState": "inactive", "LoadState": "loaded", "Result": "success"} for name in m.GUARD_NAMES}
        for name in ("sing-box.service", "rr-nexus.service"):
            states[name] = {"ActiveState": "inactive", "UnitFileState": "disabled"}
        def command(args, **kwargs):
            calls.append(args)
            if args[1] == "enable":
                self.assertTrue(marker.exists())
                for name in args[2:]:
                    states[name]["UnitFileState"] = "enabled"
            elif args[1] in {"reset-failed", "start"}:
                self.assertFalse(marker.exists())
                if args[1] == "start":
                    states[args[2]]["ActiveState"] = "active"
            return b""
        r.command, r.unit = command, lambda name: states[name]
        r.verify_files_and_firewall = lambda: (_ for _ in ()).throw(m.Refused("changed"))
        with patch.object(m, "MARKER", marker):
            with self.assertRaises(m.Refused):
                r.finish_orphan()
            self.assertEqual(calls, [])
            self.assertTrue(marker.exists())
            r.verify_files_and_firewall = lambda: None
            r.finish_orphan()
        self.assertFalse(marker.exists())
        archived = list(self.root.glob(".firewall-inflight-aborted-*"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_bytes(), m.EXPECTED_MARKER)
        self.assertTrue(r.marker_removed)

    def test_reset_skips_normal_timer_and_resets_only_real_failures(self):
        r = self.recovery()
        timer = "rr-firewall-quarantine-guard.timer"
        path = "rr-firewall-quarantine-guard.path"
        service = "rr-firewall-quarantine-guard.service"
        states = {
            timer: {"LoadState": "loaded", "ActiveState": "inactive", "Result": "success"},
            path: {"LoadState": "loaded", "ActiveState": "failed", "Result": "unit-start-limit-hit"},
            service: {"LoadState": "loaded", "ActiveState": "failed", "Result": "start-limit-hit"},
        }
        calls = []
        r.unit = lambda name: states[name].copy()
        def command(args, **kwargs):
            self.assertEqual(args[:2], ["systemctl", "reset-failed"])
            self.assertEqual(len(args), 3)
            calls.append(args[2])
            if args[2] == timer:
                raise m.Refused("Unit timer not loaded")
            states[args[2]] = {"LoadState": "loaded", "ActiveState": "inactive", "Result": "success"}
            return b""
        r.command = command
        for name in m.GUARD_NAMES:
            r.reset_failed_if_needed(name)
        self.assertEqual(calls, [path, service])
        self.assertEqual(states[timer]["ActiveState"], "inactive")

    def test_reset_failure_and_uncleared_start_limit_are_not_ignored(self):
        r = self.recovery()
        name = "rr-firewall-quarantine-guard.service"
        state = {"LoadState": "loaded", "ActiveState": "failed", "Result": "start-limit-hit"}
        r.unit = lambda unit: state.copy()
        r.command = lambda *args, **kwargs: (_ for _ in ()).throw(m.Refused("real reset failure"))
        with self.assertRaisesRegex(m.Refused, "real reset failure"):
            r.reset_failed_if_needed(name)
        r.command = lambda *args, **kwargs: b""
        with self.assertRaisesRegex(m.Refused, "unit_failure_not_cleared"):
            r.reset_failed_if_needed(name)
        state.update(ActiveState="inactive")
        with self.assertRaisesRegex(m.Refused, "unit_failure_not_cleared"):
            r.reset_failed_if_needed(name)
        state.update(ActiveState="active", Result="success")
        with self.assertRaisesRegex(m.Refused, "unexpected_reset_state"):
            r.reset_failed_if_needed(name)

    def test_failure_reinstates_marker_and_stops_subscription_even_when_systemctl_fails(self):
        marker = self.root / "marker"
        r = self.recovery()
        r.guard_stopped = r.marker_removed = True
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            if "disable" in args:
                raise m.Refused("simulated_stop_failure")
            return b""
        r.command = command
        r.helper = lambda operation: calls.append([operation])
        r.unit = lambda name: {"ActiveState": "inactive"}
        with patch.object(m, "MARKER", marker):
            r.protect_failure()
        self.assertEqual(marker.read_bytes(), m.EXPECTED_MARKER)
        self.assertIn(["stop_subscription"], calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
