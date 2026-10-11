"""Reference tests for `usage --log codex` (codex session rollouts).

Run: python3 -m unittest discover -s tests -p 'test_codex_log.py' -v
Pure evaluation plus the file search of run_codex_log; no Herdr, no TUI,
no network and no real codex session directory is touched.
"""
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from herd_parse import parse_codex_log, run_codex_log  # noqa: E402

UTC = timezone.utc
NOW = datetime(2026, 10, 11, 12, 30, 0, tzinfo=UTC)
R1_TSV = ('codex-log\tcodex\t5h=96% left\tweek=99% left\treset5h=14:52'
          '\tresetweek=2026-10-18 09:52\tage=30m')


def window(used, minutes, resets):
    return {"used_percent": used, "window_minutes": minutes, "resets_at": resets}


def limits(primary=None, secondary=None, reached=None):
    return {
        "limit_id": "codex", "limit_name": None,
        "primary": primary, "secondary": secondary,
        "credits": {"has_credits": False, "unlimited": False, "balance": "0"},
        "plan_type": "plus", "rate_limit_reached_type": reached,
    }


R1_LIMITS = limits(primary=window(4.0, 300, 1791730323),
                   secondary=window(1.0, 10080, 1792317123))


def line(rate_limits, timestamp="2026-10-11T12:00:00.000Z"):
    return json.dumps({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {"type": "token_count", "info": {},
                    "rate_limits": rate_limits},
    })


def token_line(timestamp="2026-10-11T12:01:00.000Z"):
    return json.dumps({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {"type": "token_count", "info": {}},
    })


def write_rollout(codex_home, rel, text, mtime):
    path = Path(codex_home) / "sessions" / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    os.utime(path, (mtime, mtime))
    return path


class CodexLogReferenceTests(unittest.TestCase):
    def test_r1_full_line(self):
        result = parse_codex_log([line(R1_LIMITS)], NOW)
        self.assertEqual(result.to_tsv(), R1_TSV)
        self.assertIsNone(result.reached)

    def test_r2_only_secondary_weekly(self):
        rl = limits(primary=None,
                    secondary=window(37.5, 10080, 1792317123))
        result = parse_codex_log([line(rl)], NOW)
        self.assertEqual(
            result.to_tsv(),
            'codex-log\tcodex\t5h=–\tweek=62% left\treset5h=–'
            '\tresetweek=2026-10-18 09:52\tage=30m')

    def test_r3_last_valid_line_wins(self):
        lines = [line(limits(primary=window(10.0, 300, 1791730323))),
                 line(limits(primary=window(20.0, 300, 1791730323))),
                 token_line()]
        result = parse_codex_log(lines, NOW)
        self.assertEqual(result.pct5, "80% left")
        self.assertEqual(result.age_min, 30)

    def test_r4_broken_json_line_is_skipped(self):
        result = parse_codex_log(['{"broken', line(R1_LIMITS)], NOW)
        self.assertEqual(result.to_tsv(), R1_TSV)

    def test_r7_reached_marker(self):
        rl = limits(primary=window(4.0, 300, 1791730323),
                    secondary=window(1.0, 10080, 1792317123),
                    reached="primary")
        result = parse_codex_log([line(rl)], NOW)
        self.assertTrue(result.to_tsv().endswith("\treached=primary"))

    def test_r8_age_61_minutes(self):
        later = datetime(2026, 10, 11, 13, 1, 0, tzinfo=UTC)
        result = parse_codex_log([line(R1_LIMITS)], later)
        self.assertEqual(result.age_min, 61)

    def test_windows_are_matched_by_minutes_not_role(self):
        # codex 0.16x puts the weekly window into primary (live read 2026-10-05).
        rl = limits(primary=window(61.0, 10080, 1791584010), secondary=None)
        result = parse_codex_log([line(rl)], NOW)
        self.assertEqual(result.pct5, "–")
        self.assertEqual(result.week, "39% left")
        self.assertIn("5h=–\tweek=39% left", result.to_tsv())

    def test_unknown_windows_are_ignored(self):
        rl = limits(primary=window(50.0, 60, 1791730323), secondary=None)
        self.assertIsNone(parse_codex_log([line(rl)], NOW))

    def test_reset_uses_now_timezone(self):
        tz = timezone(timedelta(hours=2))
        result = parse_codex_log([line(R1_LIMITS)],
                                 NOW.astimezone(tz))
        self.assertIn("reset5h=16:52", result.to_tsv())
        self.assertIn("resetweek=2026-10-18 11:52", result.to_tsv())

    def test_no_valid_line_returns_none(self):
        self.assertIsNone(parse_codex_log([token_line(), '{"broken'], NOW))

    def test_r11a_unhashable_window_minutes_is_skipped(self):
        bad = limits(primary={"used_percent": 4.0, "window_minutes": [],
                              "resets_at": 1791730323}, secondary=None)
        result = parse_codex_log([line(R1_LIMITS), line(bad)], NOW)
        self.assertEqual(result.to_tsv(), R1_TSV)

    def test_r11b_nonfinite_used_percent_is_skipped(self):
        for value in (float("inf"), float("-inf"), float("nan")):
            with self.subTest(value=value):
                bad = limits(primary={"used_percent": value,
                                      "window_minutes": 300,
                                      "resets_at": 1791730323}, secondary=None)
                result = parse_codex_log([line(R1_LIMITS), line(bad)], NOW)
                self.assertEqual(result.to_tsv(), R1_TSV)

    def test_r11d_huge_int_used_percent_is_skipped(self):
        # Review finding H1 (rest): math.isfinite(10**400) raises OverflowError.
        bad = limits(primary={"used_percent": 10 ** 400, "window_minutes": 300,
                              "resets_at": 1791730323}, secondary=None)
        result = parse_codex_log([line(R1_LIMITS), line(bad)], NOW)
        self.assertEqual(result.to_tsv(), R1_TSV)

    def test_r11c_overflow_reset_is_skipped(self):
        bad = limits(primary={"used_percent": 4.0, "window_minutes": 300,
                              "resets_at": 10 ** 30}, secondary=None)
        result = parse_codex_log([line(R1_LIMITS), line(bad)], NOW)
        self.assertEqual(result.to_tsv(), R1_TSV)


class CodexLogCliTests(unittest.TestCase):
    def run_log(self, codex_home, now=NOW):
        out, err = StringIO(), StringIO()
        rc = run_codex_log(codex_home=codex_home, now=now, out=out, err=err)
        return rc, out.getvalue(), err.getvalue()

    def test_r5_younger_file_without_limits_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = NOW.timestamp()
            write_rollout(tmp, "2026/10/11/rollout-young.jsonl",
                          token_line() + "\n", base)
            write_rollout(tmp, "2026/10/11/rollout-old.jsonl",
                          line(R1_LIMITS) + "\n", base - 3600)
            rc, out, err = self.run_log(tmp)
            # Reset times depend on the system zone; what counts here is the
            # file selection. Exact checks with TZ=UTC are in bash tests TCL1/TCL2.
            self.assertEqual((rc, err), (0, ""))
            self.assertTrue(out.startswith(
                "codex-log\tcodex\t5h=96% left\tweek=99% left\t"))
            self.assertIn("\tage=30m", out)

    def test_r6_no_valid_line_exit_1_names_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_rollout(tmp, "2026/10/11/rollout-empty.jsonl",
                          token_line() + '\n{"broken\n', NOW.timestamp())
            rc, out, err = self.run_log(tmp)
            self.assertEqual(rc, 1)
            self.assertEqual(out, "")
            self.assertIn(os.path.join(tmp, "sessions"), err)

    def test_r8_stale_value_warns_on_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_rollout(tmp, "2026/10/11/rollout-r1.jsonl",
                          line(R1_LIMITS) + "\n", NOW.timestamp())
            later = datetime(2026, 10, 11, 13, 1, 0, tzinfo=UTC)
            rc, out, err = self.run_log(tmp, now=later)
            self.assertEqual(rc, 0)
            self.assertTrue(out.startswith(
                "codex-log\tcodex\t5h=96% left\tweek=99% left\t"))
            self.assertIn("\tage=61m", out)
            self.assertIn("snapshot is 61 min old", err)

    def test_only_the_twenty_youngest_files_are_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = NOW.timestamp()
            for i in range(20):
                write_rollout(tmp, f"2026/10/11/rollout-new-{i:02d}.jsonl",
                              token_line() + "\n", base - i)
            write_rollout(tmp, "2026/10/11/rollout-oldest.jsonl",
                          line(R1_LIMITS) + "\n", base - 100)
            rc, out, err = self.run_log(tmp)
            self.assertEqual(rc, 1)
            self.assertIn(os.path.join(tmp, "sessions"), err)

    @unittest.skipUnless(hasattr(time, "tzset"), "tzset requires POSIX")
    def test_r10_reset_uses_timezone_of_reset_day(self):
        # now carries the summer offset (+02:00), the reset lies after the
        # DST change (2026-10-31, CET +01:00) -> resetweek must be 13:00.
        reset = int(datetime(2026, 10, 31, 12, 0, tzinfo=UTC).timestamp())
        rl = limits(secondary=window(1.0, 10080, reset))
        now = datetime(2026, 10, 24, 14, 0, tzinfo=timezone(timedelta(hours=2)))
        with tempfile.TemporaryDirectory() as tmp:
            write_rollout(tmp, "2026/10/24/rollout-r10.jsonl",
                          line(rl, timestamp="2026-10-24T11:30:00.000Z") + "\n",
                          now.timestamp())
            old_tz = os.environ.get("TZ")
            os.environ["TZ"] = "Europe/Berlin"
            time.tzset()
            try:
                rc, out, err = self.run_log(tmp, now=now)
            finally:
                if old_tz is None:
                    os.environ.pop("TZ", None)
                else:
                    os.environ["TZ"] = old_tz
                time.tzset()
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("5h=–", out)
        self.assertIn("resetweek=2026-10-31 13:00", out)


if __name__ == '__main__':
    unittest.main()
