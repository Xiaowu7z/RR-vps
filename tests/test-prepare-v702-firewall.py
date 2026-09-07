#!/usr/bin/env python3
"""Focused fake-backend checks; never touches the host firewall."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("prepare", Path(__file__).parents[1] / "scripts/prepare-v702-firewall.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def fixture(family):
    lines = ["-P INPUT ACCEPT", "-P FORWARD DROP", "-P OUTPUT ACCEPT", "-N custom"]
    lines += [" ".join(["-A", "INPUT"] + PREPARE.rule(*item)) for item in PREPARE.REQUIRED]
    bare = PREPARE.BARE + ((("tcp", 18035),) if family == "ip6tables" else ())
    lines += [" ".join(["-A", "INPUT"] + PREPARE.rule(*item, marked=False)) for item in bare]
    return PREPARE.render(lines + ["-A FORWARD -j custom", "-A custom -j RETURN"])


class Backend:
    def __init__(self, states, fail_at=None, fail_after=False):
        self.states, self.fail_at, self.fail_after, self.writes = dict(states), fail_at, fail_after, 0

    def __call__(self, family, args):
        if args == ["-S"]:
            return self.states[family]
        self.writes += 1
        if self.writes == self.fail_at and not self.fail_after:
            raise subprocess.CalledProcessError(1, family)
        self.states[family] = PREPARE.alter(self.states[family], args)
        if self.writes == self.fail_at:
            raise subprocess.CalledProcessError(1, family)
        return ""


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.before = {family: fixture(family) for family in PREPARE.FAMILIES}
        for family, text in self.before.items():
            (self.directory / (family + ".before")).write_text(text)

    def plan(self):
        PREPARE.execute("plan", self.directory)
        return json.loads((self.directory / "plan.json").read_text())["families"]

    def test_exact_delta_and_inverse(self):
        plan, backend = self.plan(), Backend(self.before)
        PREPARE.execute("apply", self.directory, backend)
        PREPARE.execute("verify", self.directory, backend)
        self.assertEqual(backend.writes, 10)
        for family in PREPARE.FAMILIES:
            self.assertEqual(len(plan[family]["operations"]), 5)
            unchanged = lambda text: [line for line in text.splitlines() if not line.startswith("-A INPUT ")]
            self.assertEqual(unchanged(self.before[family]), unchanged(backend.states[family]))
            old = " ".join(["-A", "INPUT"] + PREPARE.rule("tcp", 443, marked=False))
            self.assertNotIn(old, backend.states[family].splitlines())
        PREPARE.execute("rollback", self.directory, backend)
        self.assertEqual(backend.states, self.before)
        PREPARE.execute("rollback", self.directory, backend)
        self.assertEqual(backend.writes, 20)

    def test_every_partial_failure_is_reversible(self):
        self.plan()
        for fail_at in range(1, 11):
            for after in (False, True):
                with self.subTest(fail_at=fail_at, after=after):
                    (self.directory / "journal.json").unlink(missing_ok=True)
                    backend = Backend(self.before, fail_at, after)
                    with self.assertRaises(subprocess.CalledProcessError):
                        PREPARE.execute("apply", self.directory, backend)
                    backend.fail_at = None
                    PREPARE.execute("rollback", self.directory, backend)
                    self.assertEqual(backend.states, self.before)

    def test_unknown_duplicate_and_missing_required_rejected(self):
        original = self.before["iptables"]
        managed = " ".join(["-A", "INPUT"] + PREPARE.rule("tcp", 443)) + "\n"
        for text in (original + "-A INPUT -p tcp --dport 22 -j DROP\n", original + managed,
                     original.replace(managed, ""), original.replace("-P INPUT ACCEPT", "-P INPUT DROP")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                PREPARE.build_family(text, "iptables")

    def test_prepared_state_has_no_operations(self):
        for family, text in self.before.items():
            prepared = PREPARE.build_family(text, family)["after"]
            self.assertEqual(PREPARE.build_family(prepared, family)["operations"], [])

    def test_external_change_refuses_rollback(self):
        self.plan()
        backend = Backend(self.before, 3)
        with self.assertRaises(subprocess.CalledProcessError):
            PREPARE.execute("apply", self.directory, backend)
        backend.states["ip6tables"] += "-A custom -j LOG\n"
        writes = backend.writes
        with self.assertRaises(ValueError):
            PREPARE.execute("rollback", self.directory, backend)
        self.assertEqual(backend.writes, writes)

    def test_success_without_mutation_is_rejected(self):
        self.plan()
        backend = Backend(self.before)
        def no_op(family, args):
            return backend(family, args) if args == ["-S"] else ""
        with self.assertRaises(ValueError):
            PREPARE.execute("apply", self.directory, no_op)
        PREPARE.execute("rollback", self.directory, backend)
        self.assertEqual(backend.states, self.before)


if __name__ == "__main__":
    unittest.main()
