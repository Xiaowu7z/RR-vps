#!/bin/bash
set -euo pipefail
python3 - "$(dirname "$0")/../modules/20-config.sh" <<'PY'
"""Exercise the production timer proof against actual systemd output formats."""
import datetime
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

source = Path(sys.argv[1]).read_text()
runtime = source.split("rr_certbot_renewal_runtime_is_ready() {", 1)[1]
runtime = runtime.split("\nrr_enable_certbot_renewal_runtime() {", 1)[0]
marker = "from decimal import Decimal, InvalidOperation, ROUND_CEILING\n"
proof = compile(marker + runtime.split(marker, 1)[1].split("\nPY\n", 1)[0],
                "certbot-calendar-production-proof", "exec")
DATE = shutil.which("date")
CALENDAR = shutil.which("systemd-analyze")
if DATE is None:
    raise SystemExit("GNU date is required for calendar timestamp tests")
NOW = int(datetime.datetime(2026, 9, 7, 16, tzinfo=datetime.timezone.utc).timestamp())
REAL_RUN = subprocess.run
CALENDAR_SPEC = "{ OnCalendar=*-*-* 00,12:00:00 ; next_elapse=Mon 2026-09-07 12:00:00 PDT }"
NEXT = "Mon 2026-09-07 18:53:45 PDT"
# Copied from the Debian 12 / systemd 252 host that failed the readiness gate.
DEBIAN_252 = """Normalized form: *-*-* 00,12:00:00
    Next elapse: Tue 2026-09-08 00:00:00 UTC
       From now: 8h left
       Iter. #2: Tue 2026-09-08 12:00:00 UTC
       From now: 20h left
"""


class CalendarProofTests(unittest.TestCase):
    def proof_status(self, output=DEBIAN_252, raw_next=NEXT,
                     raw_calendar=CALENDAR_SPEC, delay="12h", accuracy="1min",
                     offset="0", calendar_status=0, real_calendar=False):
        tool = CALENDAR if real_calendar else "/fixture/systemd-analyze"

        def run(argv, **kwargs):
            if argv[0] == "/fixture/systemd-analyze":
                self.assertEqual(argv[1:4], ["calendar", f"--base-time=@{NOW}", "--iterations=2"])
                self.assertEqual(kwargs["env"]["LC_ALL"], "C")
                self.assertEqual(kwargs["env"]["TZ"], "UTC")
                return subprocess.CompletedProcess(argv, calendar_status, output)
            return REAL_RUN(argv, **kwargs)

        argv = ["timer-proof", raw_calendar, raw_next, tool, DATE, delay, accuracy, offset]
        with patch.object(sys, "argv", argv), patch("time.time", return_value=NOW), \
                patch("subprocess.run", side_effect=run):
            try:
                exec(proof, {"__name__": "__main__"})
            except SystemExit as error:
                return error.code
            except ValueError:
                return 1  # The shell gate rejects a parser exception, too.
        self.fail("production proof did not return an exit status")

    def test_debian_252_abbreviated_iteration_and_pdt_timestamp(self):
        self.assertEqual(self.proof_status(), 0)
        # Explicit manager timezone must survive the parser's UTC subprocess env.
        expected = int(datetime.datetime(2026, 9, 8, 1, 53, 45,
                                         tzinfo=datetime.timezone.utc).timestamp())
        parsed = REAL_RUN([DATE, "-u", "--date", NEXT, "+%s"],
                          text=True, capture_output=True, check=True)
        self.assertEqual(int(parsed.stdout), expected)

    def test_existing_full_iteration_label_remains_supported(self):
        self.assertEqual(self.proof_status(DEBIAN_252.replace("Iter. #2:", "Iteration #2:")), 0)

    def test_missing_or_wrong_iteration_is_rejected(self):
        for label in ("Iter #2:", "Iter. #3:", "Iteration #20:", "Other #2:"):
            with self.subTest(label=label):
                self.assertEqual(self.proof_status(DEBIAN_252.replace("Iter. #2:", label)), 1)

    def test_stale_or_distant_manager_timestamp_is_rejected(self):
        for raw_next in ("Mon 2026-09-07 15:59:59 UTC", "Tue 2026-09-15 00:00:00 UTC", "n/a"):
            with self.subTest(raw_next=raw_next):
                self.assertEqual(self.proof_status(raw_next=raw_next), 1)

    def test_iteration_must_be_future_ordered_and_bounded(self):
        replacements = (
            ("Tue 2026-09-08 00:00:00 UTC", "Mon 2026-09-07 12:00:00 UTC"),
            ("Tue 2026-09-08 12:00:00 UTC", "Mon 2026-09-07 12:00:00 UTC"),
            ("Tue 2026-09-08 12:00:00 UTC", "Fri 2026-09-11 12:00:00 UTC"),
        )
        for before, after in replacements:
            with self.subTest(after=after):
                self.assertEqual(self.proof_status(DEBIAN_252.replace(before, after)), 1)

    def test_non_daily_calendar_or_missing_proof_is_rejected(self):
        for output in (DEBIAN_252.replace("*-*-* 00,12:00:00", "Mon *-*-* 00:00:00"), ""):
            with self.subTest(output=output):
                self.assertEqual(self.proof_status(output), 1)
        self.assertEqual(self.proof_status(calendar_status=1), 1)
        self.assertEqual(self.proof_status(raw_calendar=""), 1)

    def test_delay_and_accuracy_bounds_remain_enforced(self):
        for kwargs in ({"delay": "8d"}, {"delay": "5d", "accuracy": "1min"},
                       {"offset": "6d"}, {"accuracy": "invalid"}):
            with self.subTest(**kwargs):
                self.assertEqual(self.proof_status(**kwargs), 1)

    @unittest.skipUnless(CALENDAR, "systemd-analyze is not installed")
    def test_installed_systemd_analyze_output(self):
        self.assertEqual(self.proof_status(real_calendar=True), 0)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
