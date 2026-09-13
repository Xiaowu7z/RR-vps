#!/usr/bin/env python3
"""PathExists/oneshot lifecycle regression, using actual RR unit renderers.

This is a deterministic systemd state model, not a real systemd-host claim.
It deliberately implements the service-exit -> path-recheck event missed by
the older systemctl fixture. Model boundaries follow official systemd source:
https://github.com/systemd/systemd/blob/v249/src/core/path.c
https://github.com/systemd/systemd/blob/v249/src/core/service.c
https://github.com/systemd/systemd/blob/v255/src/core/path.c
https://github.com/systemd/systemd/blob/v255/src/core/service.c

In v249 path notification can queue a start during transient FAILED, but
service_start returns EAGAIN in AUTO_RESTART, retaining RestartSec. In v255
the notification is deferred and observes AUTO_RESTART as ACTIVATING.
"""

import configparser
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(name):
    return subprocess.check_output(
        ["bash", "-c", 'source modules/10-system.sh; "$1"', "rr-test", name],
        cwd=ROOT, text=True,
    )


class Manager:
    """A virtual clock and queued jobs, with no host systemctl side effects."""

    def __init__(self, service, path, version=255):
        self.service = configparser.ConfigParser(interpolation=None)
        self.service.read_string(service)
        self.path = configparser.ConfigParser(interpolation=None)
        self.path.read_string(path)
        self.version = version
        self.now = 0
        self.marker = False
        self.path_enabled = True
        self.path_state = "waiting"
        self.service_state = "inactive"
        self.retry_at = None
        self.starts = []
        self.failures_left = 0
        self.ingress_running = True
        self.queued_start = False
        self.service_limit = int(self.service.get("Unit", "StartLimitIntervalSec", fallback="10"))

    def notify_path(self):
        if self.path_state == "stopped" or self.path_state.endswith("limit-hit"):
            return
        if self.service_state == "start-limit-hit":
            self.path_state = "unit-start-limit-hit"
        elif self.service_state in {"inactive", "failed"} and self.marker:
            self.queued_start = True
            self.path_state = "running"
        elif self.service_state in {"active-exited", "auto-restart", "starting"}:
            self.path_state = "running"
        else:
            self.path_state = "waiting"

    def drain_jobs(self):
        for _ in range(201):
            if not self.queued_start:
                return
            # service_start(v249) defers a path start while its backoff runs.
            if self.service_state == "auto-restart":
                return
            self.queued_start = False
            if self.service_state == "active-exited":
                return
            recent = [t for t in self.starts if self.now - t < self.service_limit]
            if self.service_limit and len(recent) >= 5:
                self.service_state = "start-limit-hit"
                self.notify_path()
                return
            self.starts.append(self.now)
            self.service_state = "starting"
            failure = self.failures_left > 0
            self.failures_left -= int(failure)
            if not failure:
                if self.marker:
                    self.ingress_running = False
                if self.service.getboolean("Service", "RemainAfterExit", fallback=False):
                    self.service_state = "active-exited"
                else:
                    self.service_state = "inactive"
            elif self.service.get("Service", "Restart", fallback="no") == "on-failure":
                self.service_state = "failed"
                if self.version == 249:
                    self.notify_path()
                self.service_state = "auto-restart"
                self.retry_at = self.now + int(self.service["Service"]["RestartSec"].removesuffix("s"))
            else:
                self.service_state = "failed"
            self.notify_path()
        raise AssertionError("unbounded path-trigger loop")

    def publish(self):
        self.marker = True
        self.notify_path()
        self.drain_jobs()

    def advance(self, seconds):
        until = self.now + seconds
        while self.retry_at is not None and self.retry_at <= until:
            self.now = self.retry_at
            self.retry_at = None
            self.service_state = "inactive"
            self.queued_start = True
            self.drain_jobs()
        self.now = until
        self.notify_path()
        self.drain_jobs()

    def clear_transaction(self):
        # Exact ordering used by rr_firewall_deactivate_quarantine_retry and
        # rr_firewall_activate_idle_quarantine_supervisor: stop watcher first.
        self.path_state = "stopped"
        self.queued_start = False
        self.retry_at = None
        self.service_state = "inactive"
        self.notify_path()
        self.marker = False
        self.path_state = "waiting"
        self.notify_path()
        self.drain_jobs()
        self.ingress_running = True


class GuardLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.current = render("rr_firewall_render_quarantine_guard_service")
        cls.legacy = render("rr_firewall_render_quarantine_guard_service_legacy")
        cls.path = render("rr_firewall_render_quarantine_guard_path")

    def test_old_template_reproduces_owner_start_limit(self):
        for version in (249, 255):
            with self.subTest(version=version):
                manager = Manager(self.legacy, self.path, version)
                manager.publish()
                self.assertEqual(manager.path_state, "unit-start-limit-hit")
                self.assertEqual(len(manager.starts), 5)

    def test_quarantine_converges_once_and_stays_idle_for_one_day(self):
        manager = Manager(self.current, self.path)
        manager.publish()
        manager.advance(86400)
        self.assertEqual(manager.service_state, "active-exited")
        self.assertEqual(manager.starts, [0])
        self.assertFalse(manager.ingress_running)
        self.assertTrue(manager.marker)
        self.assertIsNone(manager.retry_at)

    def test_repeated_failures_honor_backoff_and_eventually_converge(self):
        for version in (249, 255):
            with self.subTest(version=version):
                manager = Manager(self.current, self.path, version)
                manager.failures_left = 8
                manager.publish()
                manager.advance(39)
                self.assertEqual(manager.starts, list(range(0, 40, 5)))
                self.assertEqual(manager.service_state, "auto-restart")
                self.assertTrue(manager.marker)
                manager.advance(1)
                self.assertEqual(manager.service_state, "active-exited")
                self.assertFalse(manager.ingress_running)
                manager.advance(86400)
                self.assertEqual(len(manager.starts), 9)

    def test_completed_inflight_rearms_next_independent_transaction(self):
        manager = Manager(self.current, self.path)
        for cycle in range(3):
            manager.publish()
            self.assertEqual(len(manager.starts), cycle + 1)
            manager.clear_transaction()
            self.assertEqual(manager.path_state, "waiting")
            self.assertEqual(manager.service_state, "inactive")
            self.assertTrue(manager.ingress_running)
            manager.advance(60)
            self.assertEqual(len(manager.starts), cycle + 1)

    def test_clear_cancels_pending_failure_retry_before_restoring_ingress(self):
        manager = Manager(self.current, self.path, 249)
        manager.failures_left = 99
        manager.publish()
        manager.clear_transaction()
        manager.advance(60)
        self.assertEqual(len(manager.starts), 1)
        self.assertTrue(manager.ingress_running)
        self.assertEqual(manager.path_state, "waiting")

    def test_boot_with_orphan_marker_converges_without_live_writer(self):
        manager = Manager(self.current, self.path)
        manager.marker = True
        manager.notify_path()
        manager.drain_jobs()
        self.assertFalse(manager.ingress_running)
        self.assertEqual(manager.service_state, "active-exited")

    def test_stopping_service_before_path_would_retrigger(self):
        manager = Manager(self.current, self.path)
        manager.publish()
        manager.service_state = "inactive"
        manager.notify_path()
        manager.drain_jobs()
        self.assertEqual(len(manager.starts), 2)

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze unavailable")
    def test_current_units_compile_in_real_systemd_parser(self):
        # verify parses units without loading them into the live manager or
        # executing ExecStart. Use /bin/true only for executable existence.
        with tempfile.TemporaryDirectory(prefix="rr-guard-unit-verify-") as directory:
            unit_paths = []
            for kind in ("service", "path", "timer"):
                body = render("rr_firewall_render_quarantine_guard_" + kind)
                if kind == "service":
                    body = body.replace(
                        "ExecStart=/usr/local/sbin/rr-firewall-quarantine-guard",
                        "ExecStart=/bin/true",
                    )
                target = pathlib.Path(directory) / ("rr-firewall-quarantine-guard." + kind)
                target.write_text(body, encoding="utf-8")
                unit_paths.append(str(target))
            result = subprocess.run(
                ["systemd-analyze", "verify", *unit_paths], text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
