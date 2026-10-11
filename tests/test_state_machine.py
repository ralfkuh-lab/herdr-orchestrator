#!/usr/bin/env python3
# Unit tests of the PURE report rules (scripts/herd_state.py, step B of the
# rework in docs/plan-watch-events.md). WITHOUT IO: pure event/tick sequences
# against expected reports, commands and abort decisions — no daemon, no socket,
# no real clock, no waiting.
#
# The test names carry the T number of the case from tests/run.sh whose SEMANTICS
# they transfer into the event world. The poll contract itself (T1-T37) remains
# the business of tests/run.sh; here stands its equivalent for the event path.
#
# CommandProtocolTest is deliberately ADVERSARIAL: the adapter boundary is
# asynchronous in step C, so answers arrive late, swapped, invalid, not at all or
# across a reconnect. Exactly there the correlation (request_id + state
# generation) decides whether an answer still counts.
#
#   bash tests/run.sh T60          # as part of the full run
#   python3 -m unittest discover -s tests -p 'test_state_machine.py' -v

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "scripts"))

from herd_state import (  # noqa: E402
    CMD_AGENT_GET, CMD_CLASSIFY, CMD_FINGERPRINT, PURPOSE_DEBOUNCE,
    PURPOSE_GONE, PURPOSE_VERIFY, StateMachine, normalize_status)

# An interval that NEVER falls due in tests. This keeps the cases that do not
# examine the rest poll or the command deadline free of their effect.
NEVER = 10 ** 6


def _rid(cmd):
    """Tests may pass a Command OR directly a request_id."""
    return cmd if isinstance(cmd, int) else cmd.request_id


class Harness(object):
    """Driver for the state machine: virtual clock, collected report lines,
    notes and open commands. Deliberately thin — the tests should show the input
    sequence, not a framework.

    Commands are NOT resolved automatically: each test decides itself whether,
    when and with which result it answers."""

    def __init__(self, names, debounce_sec=4.0, verify_interval_sec=NEVER,
                 stall_timeout_sec=0.0, max_events=0, timeout_sec=0.0,
                 cmd_timeout_sec=NEVER, cmd_retry_sec=1.0, start=1000.0,
                 busy_max_sec=None, raw_target=None, kinds=None,
                 bg_max_sec=None):
        self.now = start
        self.start = start
        self.debounce_sec = debounce_sec
        self.agent_kinds = dict(kinds or {})
        self.sm = StateMachine(names, now=start, debounce_sec=debounce_sec,
                               verify_interval_sec=verify_interval_sec,
                               stall_timeout_sec=stall_timeout_sec,
                               max_events=max_events, timeout_sec=timeout_sec,
                               cmd_timeout_sec=cmd_timeout_sec,
                               cmd_retry_sec=cmd_retry_sec,
                               busy_max_sec=busy_max_sec,
                               raw_target=raw_target, bg_max_sec=bg_max_sec)
        self.lines = []
        self.notes = []
        self.commands = []
        self.exit = None

    def _take(self, outcome):
        self.lines.extend(outcome.lines())
        self.notes.extend(outcome.notes)
        self.commands.extend(outcome.commands)
        if outcome.exit is not None and self.exit is None:
            self.exit = outcome.exit
        return outcome

    # -- inputs: events --
    def resync(self, snapshots, gaps=(), first=False):
        return self._take(self.sm.on_resync(self.now, snapshots, gaps, first,
                                            self.agent_kinds))

    def status(self, name, raw):
        return self._take(self.sm.on_status(self.now, name, raw,
                                            self.agent_kinds.get(name, "")))

    def gone(self, name):
        return self._take(self.sm.on_pane_gone(self.now, name))

    def monitor_down(self):
        return self._take(self.sm.on_monitor_unavailable(self.now))

    def monitor_up(self):
        return self._take(self.sm.on_monitor_restored(self.now))

    # -- inputs: command results (always with the request_id) --
    def classify(self, cmd, verdict="clean"):
        return self._take(self.sm.on_classify(self.now, _rid(cmd), verdict))

    def fingerprint(self, cmd, fp=None, limited=False, failed=False):
        return self._take(self.sm.on_fingerprint(
            self.now, _rid(cmd), fp, limited, failed))

    def agent_get(self, cmd, present, raw=None):
        return self._take(self.sm.on_agent_get(self.now, _rid(cmd), present, raw))

    def fail(self, cmd, reason="pane not readable"):
        return self._take(self.sm.on_command_failed(self.now, _rid(cmd), reason))

    def tick(self):
        return self._take(self.sm.tick(self.now))

    def advance(self, dt):
        """Jump time and give ONE tick. One jump is enough: the machine compares
        absolute deadlines, it does not count ticks."""
        self.now += dt
        return self.tick()

    # -- helpers --
    def pop(self, kind, name):
        """Fetch a command from the list of not yet answered ones."""
        for i, cmd in enumerate(self.commands):
            if cmd.kind == kind and cmd.name == name:
                return self.commands.pop(i)
        raise AssertionError("command %s/%s missing; open: %r"
                             % (kind, name, self.kinds()))

    def kinds(self):
        return [(c.kind, c.name) for c in self.commands]

    def settle(self, name, verdict="clean"):
        """Let the quiet window expire and answer the dialog cross-check — the
        standard sequence after an idle/done event."""
        self.advance(self.debounce_sec + 0.1)
        return self.classify(self.pop(CMD_CLASSIFY, name), verdict)

    def reason(self):
        return None if self.exit is None else self.exit.reason

    def noted(self, needle):
        return any(needle in n for n in self.notes)


class NormalizeTest(unittest.TestCase):
    """normalize_status is the counterpart to the bash function of the same
    name: ONLY working (→ limited/failed) and idle/done (→ blocked/limited/auth/
    failed) are corrected (T15a-T15c prove the bash side)."""

    def test_idle_is_replaced_by_verdict(self):
        self.assertEqual(normalize_status("idle", "blocked"), "blocked")
        self.assertEqual(normalize_status("done", "auth"), "auth")
        self.assertEqual(normalize_status("idle", "failed"), "failed")
        self.assertEqual(normalize_status("done", "failed"), "failed")
        self.assertEqual(normalize_status("idle", "clean"), "idle")
        self.assertEqual(normalize_status("idle", "busy"), "working")
        self.assertEqual(normalize_status("done", "busy"), "working")

    def test_working_only_limited(self):
        self.assertEqual(normalize_status("working", "limited"), "limited")
        self.assertEqual(normalize_status("working", "failed"), "failed")
        # A dialog pattern while the backend is running is NOT blocked — exactly
        # the restriction that the working branch of normalize_status in herd.sh
        # makes (there only looks_limited/looks_failed are checked).
        self.assertEqual(normalize_status("working", "blocked"), "working")
        self.assertEqual(normalize_status("working", "busy"), "working")

    def test_others_stay(self):
        self.assertEqual(normalize_status("unknown", "blocked"), "unknown")
        self.assertEqual(normalize_status("blocked", "clean"), "blocked")


class ReportLockTest(unittest.TestCase):
    """Invariant 1 (report lock per agent, re-entry is reported) and invariant 2
    (working only as a clears-alarm)."""

    def test_t20_second_completion_is_reported(self):
        # T20 equivalent, THE core finding of the cross review: a finishes, gets
        # a new brief and finishes again. b keeps working so the observation does
        # not end early.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])
        h.status("a", "working")          # new brief: NO event
        self.assertEqual(h.lines, ["a idle"])
        h.status("a", "idle")
        h.settle("a")
        self.assertEqual(h.lines, ["a idle", "a idle"])
        self.assertIsNone(h.exit)

    def test_t20_idle_and_done_are_one_class(self):
        # A change idle->done is the same finished work and must not report twice
        # (invariant 1). DEVIATION from herd.sh: there the report lock compares
        # strings and yields a second line here — against its own comment in the
        # code. Confirmed as justified in the step-B review; details in
        # scripts/herd_state.py, _apply.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a")
        h.status("a", "done")
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])

    def test_t21_second_dialog_is_reported(self):
        # T21 equivalent: blocked -> (short, never reported idle) -> blocked. The
        # idle in the quiet window is discarded but lifts the report lock —
        # otherwise the second dialog would stay silent.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "blocked")
        h.status("a", "idle")
        h.advance(1.0)                    # still in the window
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked", "a blocked"])
        # The discarded window must not push another cross-check afterwards.
        h.advance(10.0)
        self.assertEqual(h.kinds(), [])

    def test_t21_working_after_dialog_clears_alarm(self):
        # Invariant 2: working reports ONLY after an action state.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "blocked")
        h.status("a", "working")
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked", "a working", "a blocked"])

    def test_failed_like_limited_immediate_and_reentry(self):
        # failed is an ACTION_STATE like limited: reported immediately, not
        # terminal, clears-alarm via working, re-entry reported again.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "failed")
        self.assertEqual(h.lines, ["a failed"])
        self.assertIsNone(h.exit)
        h.status("a", "working")
        self.assertEqual(h.lines, ["a failed", "a working"])
        h.status("a", "idle")
        h.settle("a", "failed")
        self.assertEqual(h.lines, ["a failed", "a working", "a failed"])
        self.assertIsNone(h.exit)

    def test_working_is_not_work_start_noise(self):
        h = Harness(["a"])
        h.resync({"a": "idle"}, first=True)
        h.status("a", "working")
        h.status("a", "working")
        self.assertEqual(h.lines, [])

    def test_t24_unknown_is_reported(self):
        # T24 equivalent: 'unknown' is a real herdr status. Without a report watch
        # would keep running forever without ever delivering an event.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "unknown")
        h.status("a", "unknown")          # report lock holds
        self.assertEqual(h.lines, ["a unknown"])
        h.status("a", "working")          # clears-alarm
        self.assertEqual(h.lines, ["a unknown", "a working"])


class QuietWindowTest(unittest.TestCase):
    """Debounce as a settle replacement (plan, design decision 1) and the
    dialog cross-check at the end of the window (design decision 2)."""

    def test_t2_single_idle_before_working_is_silent(self):
        # T2 equivalent: right after `send` herdr briefly reports idle before
        # working takes over. The working inside the window discards the report;
        # no cross-check command is created for it at all.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(1.0)
        h.status("a", "working")
        h.advance(10.0)
        self.assertEqual(h.lines, [])
        self.assertEqual(h.kinds(), [])
        self.assertIsNone(h.exit)
        # The real completion afterwards is reported.
        h.status("a", "idle")
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])

    def test_t10_quiet_window_per_agent_separate(self):
        # T10 equivalent: the windows of a and b must not mix — b discards ITS
        # report, a still reports.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.advance(1.0)
        h.status("b", "idle")
        h.advance(1.0)
        h.status("b", "working")
        h.advance(2.2)                    # window end ONLY for a
        self.assertEqual(h.kinds(), [(CMD_CLASSIFY, "a")])
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertIsNone(h.exit)

    def test_verdict_replaces_idle_report(self):
        # herdr knows no approval dialogs: idle + dialog in the pane is blocked.
        # The verdict at the end of the window replaces the report — and blocked
        # is NOT terminal, the observation keeps running.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])
        self.assertIsNone(h.exit)

    def test_snapshot_idle_passes_through_window(self):
        # For a state that already existed before the watch, NO event arrives any
        # more — the snapshot is the source (plan, design decision 4). It is
        # debounced too: watch typically starts right after `send`.
        h = Harness(["a"])
        h.resync({"a": "idle"}, first=True)
        self.assertEqual(h.lines, [])
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])
        self.assertEqual(h.reason(), "all-settled")

    def test_duplicates_do_not_extend_window(self):
        # Repeated identical events (the daemon also delivers lines twice) must
        # not push the report forever.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(2.0)
        h.status("a", "idle")
        h.advance(2.2)                    # 4.2 s after the FIRST idle
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a idle"])


class TerminalTest(unittest.TestCase):
    """Invariant 3: terminal are lost and reported idle/done — nothing else."""

    def test_t7_end_when_all_done(self):
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.status("b", "idle")
        h.advance(4.1)
        ca = h.pop(CMD_CLASSIFY, "a")
        cb = h.pop(CMD_CLASSIFY, "b")
        h.classify(ca, "clean")
        self.assertIsNone(h.exit)         # b still missing
        h.classify(cb, "clean")
        self.assertEqual(h.lines, ["a idle", "b idle"])
        self.assertEqual(h.exit.code, 0)
        self.assertEqual(h.reason(), "all-settled")

    def test_t6_action_state_does_not_end_observation(self):
        # T6 equivalent: watch does NOT end at the first event — otherwise b
        # would stay unobserved. Only --max-events ends here.
        h = Harness(["a", "b"], max_events=2)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "blocked")
        self.assertIsNone(h.exit)
        h.status("b", "idle")
        h.settle("b")
        self.assertEqual(h.lines, ["a blocked", "b idle"])
        self.assertEqual(h.reason(), "max-events")

    def test_max_events_stops_further_reports(self):
        h = Harness(["a", "b"], max_events=1)
        h.resync({"a": "working", "b": "working"}, first=True)
        out = h.sm.on_status(h.now, "a", "blocked")
        self.assertEqual(out.lines(), ["a blocked"])
        self.assertEqual(out.exit.reason, "max-events")
        # Afterwards the decision is binding: further inputs change nothing and
        # deliver the same decision.
        out2 = h.sm.on_status(h.now, "b", "blocked")
        self.assertEqual(out2.lines(), [])
        self.assertEqual(out2.exit.reason, "max-events")

    def test_timeout_is_not_a_result(self):
        # Invariant 6: exit 124, no report — the agents keep running.
        h = Harness(["a"], timeout_sec=60.0)
        h.resync({"a": "working"}, first=True)
        h.advance(59.0)
        self.assertIsNone(h.exit)
        h.advance(1.5)
        self.assertEqual(h.lines, [])
        self.assertEqual(h.exit.code, 124)
        self.assertEqual(h.reason(), "timeout")


class LostTest(unittest.TestCase):
    """Invariant 4/5: lost only after a cross-check, not_found before the start is
    the caller's business."""

    def test_t8_lost_is_reported_other_keeps_running(self):
        # T8 equivalent: pane_closed -> agent.get cross-check -> really gone.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.gone("a")
        self.assertEqual(h.lines, [])      # NO report yet
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=False)
        self.assertEqual(h.lines, ["a lost"])
        self.assertIsNone(h.exit)          # b keeps running
        h.status("b", "idle")
        h.settle("b")
        self.assertEqual(h.lines, ["a lost", "b idle"])
        self.assertEqual(h.reason(), "all-settled")

    def test_t25_replayed_pane_closed_is_no_lost(self):
        # T25 equivalent and the finding from step A: after the subscribe the
        # daemon also delivers events of foreign/old panes. The cross-check says
        # "there" — then neither lost may be reported nor the report lock cleared
        # (invariant 4).
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.gone("a")
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=True, raw="blocked")
        self.assertEqual(h.lines, ["a blocked"])
        self.assertFalse(h.sm.state_of("a")["lost"])
        # Second replay: new cross-check, still no event.
        h.gone("a")
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=True, raw="blocked")
        self.assertEqual(h.lines, ["a blocked"])

    def test_duplicate_pane_closed_create_one_cross_check(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.gone("a")
        h.gone("a")
        h.gone("a")
        self.assertEqual(h.kinds(), [(CMD_AGENT_GET, "a")])

    def test_lost_is_reported_only_once(self):
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.gone("a")
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=False)
        # After lost the agent is fully observed: further events must not revive
        # it and report nothing more.
        h.gone("a")
        h.status("a", "working")
        h.advance(10.0)
        self.assertEqual(h.lines, ["a lost"])
        self.assertEqual(h.kinds(), [])

    def test_not_found_before_start_is_no_lost(self):
        # Invariant 5: never seen = input error (exit 1 at the caller), gone
        # AFTER the start = lost.
        h = Harness(["a"])
        h.resync({"a": None}, first=True)
        self.assertEqual(h.lines, [])
        self.assertFalse(h.sm.state_of("a")["lost"])
        h.resync({"a": "working"})
        h.resync({"a": None})
        self.assertEqual(h.lines, ["a lost"])
        self.assertEqual(h.reason(), "all-settled")


class ResyncTest(unittest.TestCase):
    """Generation jump as a gap detector (plan, architecture/BLOCKER 1)."""

    def test_t29_generation_jump_reports_again(self):
        # T29 equivalent: a complete brief lies between two snapshots — the
        # status is idle before and after, only the seq jump betrays the cycle.
        # Without this signal the second completion would stay silent.
        h = Harness(["a", "b"])
        h.resync({"a": "idle", "b": "working"}, first=True)
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])
        h.resync({"a": "idle", "b": "working"}, gaps=["a"])
        h.settle("a")
        self.assertEqual(h.lines, ["a idle", "a idle"])

    def test_resync_without_jump_does_not_report_again(self):
        # Cross-check: the same state without a generation change is NOT a new
        # event (otherwise every reconnect would invent reports).
        h = Harness(["a", "b"])
        h.resync({"a": "idle", "b": "working"}, first=True)
        h.settle("a")
        h.resync({"a": "idle", "b": "working"})
        h.settle("a")
        self.assertEqual(h.lines, ["a idle"])


class MonitorTest(unittest.TestCase):
    """Global reports and the reconnect gap."""

    def test_t31_global_reports_count_against_max_events(self):
        h = Harness(["a"], max_events=2)
        h.resync({"a": "working"}, first=True)
        h.monitor_down()
        self.assertIsNone(h.exit)
        h.monitor_up()
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored"])
        self.assertEqual(h.reason(), "max-events")

    def test_outage_is_reported_only_once(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.monitor_down()
        h.monitor_down()
        h.monitor_up()
        h.monitor_up()
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored"])

    def test_reconnect_gap_full_cycle_during_drop(self):
        # The case the event path loses in principle without a resync: a is
        # reported done, gets a new brief during the connection drop and finishes
        # again. There is NO event for it — only the seq jump in the resync after
        # the rebuild.
        h = Harness(["a", "b"], verify_interval_sec=30.0)
        h.resync({"a": "idle", "b": "working"}, first=True)
        h.settle("a")
        h.monitor_down()
        # During the outage commands are pointless (same daemon) — the clocks
        # stand still so the rebuild does not trigger a flood.
        h.advance(120.0)
        self.assertEqual(h.kinds(), [])
        h.monitor_up()
        h.resync({"a": "idle", "b": "working"}, gaps=["a"])
        h.settle("a")
        self.assertEqual(h.lines, ["a idle", "* monitor-unavailable",
                                   "* monitor-restored", "a idle"])

    def test_clocks_reset_after_rebuild(self):
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        h.monitor_down()
        h.advance(120.0)
        h.monitor_up()
        h.advance(10.0)
        self.assertEqual(h.kinds(), [])    # the 30 s only run from restored on
        h.advance(21.0)
        self.assertEqual(h.kinds(), [(CMD_FINGERPRINT, "a")])


class VerificationPollTest(unittest.TestCase):
    """Verification rest poll: ONE clock for stalled and classification, oriented
    at the RAW status (plan, design decision 2/3)."""

    def test_command_choice_depends_on_raw_status(self):
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        self.assertEqual(h.kinds(), [(CMD_FINGERPRINT, "a")])
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp1")
        h.status("a", "blocked")
        h.advance(30.1)
        self.assertEqual(h.kinds(), [(CMD_CLASSIFY, "a")])

    def test_rest_poll_continues_after_synthetic_report(self):
        # Recovery: the dialog was answered outside, the raw status is still
        # idle — only the next classification ('clean') can detect the end of the
        # action state at all.
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "idle"}, first=True)
        h.settle("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])
        h.advance(30.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a blocked", "a idle"])
        self.assertEqual(h.reason(), "all-settled")

    def test_limited_at_raw_status_working(self):
        # Backends with self-retry stay working permanently at the usage limit
        # (T15b proves the bash side). The rest poll is the only chance to see
        # this — there is no status event for it.
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp1", limited=True)
        self.assertEqual(h.lines, ["a limited"])
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp2", limited=False)
        self.assertEqual(h.lines, ["a limited", "a working"])   # clears-alarm

    def test_failed_at_raw_status_working(self):
        # Analogous to limited: raw-working + model failed only reaches the event
        # path via the fingerprint rest poll (no status event).
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp1", failed=True)
        self.assertEqual(h.lines, ["a failed"])
        self.assertIsNone(h.exit)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp2", failed=False)
        self.assertEqual(h.lines, ["a failed", "a working"])
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp3",
                      limited=True, failed=True)
        self.assertEqual(h.lines[-1], "a limited")   # limited before failed

    def test_no_second_command_while_window_classifies(self):
        # If the classification of the quiet window is still pending, the rest
        # poll does not push a second identical command — the clock still runs.
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        h.advance(20.0)
        h.status("a", "idle")
        h.advance(10.2)                    # window end AND rest poll due
        self.assertEqual(h.kinds(), [(CMD_CLASSIFY, "a")])


class StallTest(unittest.TestCase):
    """stalled stays fingerprint with a latch (plan, design decision 3)."""

    def _stalled_harness(self):
        h = Harness(["a"], verify_interval_sec=30.0, stall_timeout_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")     # clock starts
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")     # >10 s unchanged
        return h

    def test_t11_silent_hang_is_reported(self):
        h = self._stalled_harness()
        self.assertEqual(h.lines, ["a stalled"])
        # stalled is NOT terminal: the agent can recover.
        self.assertIsNone(h.exit)

    def test_t22_stalled_latches(self):
        # T22 equivalent: without the latch the state falls back to working
        # between two fingerprint checks (clears-alarm!) and then to stalled
        # again — endless flapping.
        h = self._stalled_harness()
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        h.status("a", "working")            # herdr repeats the status
        self.assertEqual(h.lines, ["a stalled"])

    def test_new_fingerprint_clears_latch(self):
        h = self._stalled_harness()
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "different")   # real progress
        self.assertEqual(h.lines, ["a stalled", "a working"])

    def test_leaving_working_clears_latch(self):
        h = self._stalled_harness()
        h.status("a", "idle")
        h.settle("a")
        self.assertEqual(h.lines, ["a stalled", "a idle"])
        self.assertEqual(h.reason(), "all-settled")

    def test_without_stall_timeout_no_stall_report(self):
        # --stall-timeout 0 = off. The limited check at the working pane remains.
        h = Harness(["a"], verify_interval_sec=30.0, stall_timeout_sec=0.0)
        h.resync({"a": "working"}, first=True)
        for _ in range(4):
            h.advance(30.1)
            h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        self.assertEqual(h.lines, [])


class CommandProtocolTest(unittest.TestCase):
    """ADVERSARIAL adapter boundary: answers arrive late, invalid, not at all or
    across a reconnect. Only the correlation of request_id AND state generation
    decides whether an answer still counts."""

    def test_commands_carry_id_generation_and_reason(self):
        h = Harness(["a"], verify_interval_sec=30.0)
        h.resync({"a": "working"}, first=True)
        self.assertEqual(h.sm.state_of("a")["gen"], 1)   # first observation
        h.status("a", "idle")
        self.assertEqual(h.sm.state_of("a")["gen"], 2)   # status change
        h.advance(4.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.generation, 2)
        self.assertEqual(cmd.purpose, PURPOSE_DEBOUNCE)
        self.assertEqual(h.sm.inflight()[cmd.request_id],
                         ("a", CMD_CLASSIFY, PURPOSE_DEBOUNCE, 2))
        h.classify(cmd, "clean")
        self.assertEqual(h.sm.inflight(), {})            # slot free again
        self.assertIsNone(h.sm.state_of("a")["open"][PURPOSE_DEBOUNCE])

    def test_late_classify_from_discarded_window(self):
        # THE dangerous case from the step-B review: the answer to the FIRST
        # quiet window arrives after a second one is running. Without correlation
        # it would report the new idle as blocked prematurely.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        old = h.pop(CMD_CLASSIFY, "a")
        h.status("a", "working")            # window discarded
        h.status("a", "idle")               # second window
        h.classify(old, "blocked")          # late answer
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 1)
        self.assertTrue(h.noted("discarded"))
        h.settle("a")                       # the new window reports correctly
        self.assertEqual(h.lines, ["a idle"])

    def test_late_fingerprint_across_working_idle_working(self):
        # Here too the old result looks "fitting" again (the raw status is
        # working once more) — but it describes a different work cycle and must
        # influence neither the stall clock nor the limit status.
        h = Harness(["a"], verify_interval_sec=30.0, stall_timeout_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        old = h.pop(CMD_FINGERPRINT, "a")
        h.status("a", "idle")
        h.status("a", "working")
        h.advance(30.0)
        new = h.pop(CMD_FINGERPRINT, "a")
        h.fingerprint(old, "same", limited=True)
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 1)
        self.assertFalse(h.sm.state_of("a")["stalled"])
        # The new cycle has its own command with a higher generation.
        self.assertNotEqual(new.request_id, old.request_id)
        self.assertGreater(new.generation, old.generation)

    def test_answer_after_resync_gap_vanishes(self):
        # Resync gap = seq jump OR pane_id change: an open answer afterwards
        # describes a dead pane or an overtaken cycle.
        h = Harness(["a", "b"])
        h.resync({"a": "idle", "b": "working"}, first=True)
        h.advance(4.1)
        old = h.pop(CMD_CLASSIFY, "a")
        h.resync({"a": "idle", "b": "working"}, gaps=["a"])
        h.classify(old, "blocked")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 1)
        # The window is classified anew (new request_id).
        h.advance(0.1)
        new = h.pop(CMD_CLASSIFY, "a")
        self.assertNotEqual(new.request_id, old.request_id)
        h.classify(new, "clean")
        self.assertEqual(h.lines, ["a idle"])

    def test_deadline_creates_second_attempt_old_answer_vanishes(self):
        # Two identical commands "in flight": the first is invalid after the
        # deadline expires, the second counts.
        h = Harness(["a"], cmd_timeout_sec=5.0, cmd_retry_sec=1.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        first = h.pop(CMD_CLASSIFY, "a")
        h.advance(5.1)                      # deadline expired
        self.assertEqual(h.sm.inflight(), {})
        h.advance(1.1)                      # retry due
        second = h.pop(CMD_CLASSIFY, "a")
        self.assertNotEqual(first.request_id, second.request_id)
        h.classify(first, "blocked")        # late first answer
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 1)
        h.classify(second, "clean")
        self.assertEqual(h.lines, ["a idle"])

    def test_classify_repeated_failure_reports_unknown_and_stays_open(self):
        # BLOCKER 2: without a way out the agent would stay in the waiting phase
        # forever and its completion silent. `unknown` is reported — NOT the
        # unconfirmed idle that would make the agent terminal.
        h = Harness(["a"], verify_interval_sec=30.0, cmd_retry_sec=1.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        h.fail(h.pop(CMD_CLASSIFY, "a"))
        h.advance(1.1)
        h.fail(h.pop(CMD_CLASSIFY, "a"))
        h.advance(1.1)
        h.fail(h.pop(CMD_CLASSIFY, "a"))
        self.assertEqual(h.lines, ["a unknown"])
        self.assertTrue(h.noted("not classifiable"))
        self.assertIsNone(h.exit)                         # NOT terminal
        self.assertFalse(h.sm.state_of("a")["settled"])
        # The rest poll keeps classifying — as soon as the pane is readable, the
        # real report arrives.
        h.advance(30.0)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a unknown", "a idle"])
        self.assertEqual(h.reason(), "all-settled")

    def test_agent_get_repeated_failure_reports_no_lost_and_does_not_block(self):
        # BLOCKER 2, second half: a failed cross-check must not occupy the slot
        # permanently (otherwise ALL further pane_closed are ignored) — and not
        # knowing is not disappearing (invariant 4).
        h = Harness(["a", "b"], cmd_retry_sec=1.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.gone("a")
        h.fail(h.pop(CMD_AGENT_GET, "a"), "rpc broken")
        h.advance(1.1)
        h.fail(h.pop(CMD_AGENT_GET, "a"), "rpc broken")
        h.advance(1.1)
        h.fail(h.pop(CMD_AGENT_GET, "a"), "rpc broken")
        self.assertEqual(h.lines, [])
        self.assertTrue(h.noted("NO 'lost'"))
        self.assertEqual(h.sm.state_of("a")["tries"][PURPOSE_GONE], 0)
        # Another pane.closed triggers the check again.
        h.gone("a")
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=False)
        self.assertEqual(h.lines, ["a lost"])

    def test_outage_invalidates_open_commands(self):
        # Open commands go to the same daemon: they are never answered. After the
        # rebuild the machine requests anew as needed.
        h = Harness(["a", "b"], verify_interval_sec=30.0)
        h.resync({"a": "idle", "b": "working"}, first=True)
        h.advance(4.1)
        old = h.pop(CMD_CLASSIFY, "a")
        h.monitor_down()
        self.assertEqual(h.sm.inflight(), {})
        h.classify(old, "blocked")            # straggler
        self.assertEqual(h.sm.stale_results, 1)
        h.monitor_up()
        h.resync({"a": "idle", "b": "working"})
        h.settle("a")
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored",
                                   "a idle"])

    def test_outage_with_open_cross_check_is_resolved_by_resync(self):
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.gone("a")
        old = h.pop(CMD_AGENT_GET, "a")
        h.monitor_down()
        h.fail(old, "daemon gone")            # answer after the invalidation
        self.assertEqual(h.sm.stale_results, 1)
        self.assertEqual(h.sm.state_of("a")["tries"][PURPOSE_GONE], 0)
        h.monitor_up()
        # The resync is the cross-check for everything that could not be checked
        # during the outage.
        h.resync({"a": None, "b": "working"})
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored",
                                   "a lost"])

    def test_answer_after_deadline_does_not_fix_exit_0(self):
        # MAJOR 1: the deadline applies to EVERY time-carrying input, not only in
        # the tick. Otherwise a command answer after expiry could still fix
        # all-settled/max-events and break invariant 6.
        h = Harness(["a"], timeout_sec=60.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        h.now = h.start + 61.0                # NO tick in between
        out = h.sm.on_classify(h.now, cmd.request_id, "clean")
        self.assertEqual(out.lines(), [])
        self.assertEqual(out.exit.code, 124)
        self.assertEqual(out.exit.reason, "timeout")

    def test_status_after_deadline_no_longer_reports(self):
        h = Harness(["a"], timeout_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.now = h.start + 11.0
        out = h.sm.on_status(h.now, "a", "blocked")
        self.assertEqual(out.lines(), [])
        self.assertEqual(out.exit.reason, "timeout")

    def test_invalid_verdict_is_error_not_clean(self):
        # MINOR: `clean` is exclusively a SUCCESSFUL result. An unreadable pane
        # must not become terminal as a clean completion.
        h = Harness(["a"], verify_interval_sec=30.0, cmd_retry_sec=1.0)
        h.resync({"a": "idle"}, first=True)
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), None)
        self.assertEqual(h.lines, [])
        self.assertIsNone(h.exit)
        self.assertFalse(h.sm.state_of("a")["settled"])
        h.advance(1.1)                        # retry
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a idle"])

    def test_missing_fingerprint_is_error_not_no_stall(self):
        # A read error must not silently switch off stall detection: it is an
        # error, gets diagnosed, and the rest-poll clock repeats.
        h = Harness(["a"], verify_interval_sec=30.0, stall_timeout_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), None)
        self.assertEqual(h.lines, [])
        self.assertTrue(h.noted("pane not readable"))
        self.assertEqual(h.sm.state_of("a")["tries"][PURPOSE_VERIFY], 0)
        # The rest poll returns — the stall clock starts with the first readable
        # fingerprint.
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        self.assertEqual(h.lines, ["a stalled"])

    def test_wrongly_typed_results_are_errors(self):
        h = Harness(["a", "b"], verify_interval_sec=30.0, cmd_retry_sec=1.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "fp1", limited="yes")
        self.assertTrue(h.noted("limited is not a boolean"))
        h.fingerprint(h.pop(CMD_FINGERPRINT, "b"), "fp1", failed="yes")
        self.assertTrue(h.noted("failed is not a boolean"))
        h.gone("b")
        h.agent_get(h.pop(CMD_AGENT_GET, "b"), present=None)
        self.assertTrue(h.noted("present is not a boolean"))
        self.assertEqual(h.lines, [])

    def test_unknown_request_id_vanishes(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.sm.on_classify(h.now, 4711, "blocked")
        h.sm.on_fingerprint(h.now, 4712, "fp", False)
        h.sm.on_agent_get(h.now, 4713, False)
        h.sm.on_command_failed(h.now, 4714, "whatever")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 4)
        self.assertFalse(h.sm.state_of("a")["lost"])

    def test_answer_with_wrong_kind_vanishes(self):
        # The adapter must not report a classify result as a fingerprint.
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        h.fingerprint(cmd, "fp1")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.stale_results, 1)
        h.classify(cmd, "clean")              # still valid as classify
        self.assertEqual(h.lines, ["a idle"])


class RobustnessTest(unittest.TestCase):
    def test_unknown_names_and_empty_status_are_no_ops(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("foreign", "idle")
        h.status("a", "")
        h.status("a", None)
        h.gone("foreign")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.kinds(), [])

    def test_monitor_unavailable_as_agent_status_is_no_statement(self):
        # "we do not know right now" must not clear the report lock — otherwise
        # the old state is reported twice after a single hiccup (invariant 4).
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.status("a", "monitor-unavailable")
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])

    def test_duplicate_names_are_rejected(self):
        # In herd.sh a usage error (exit 2, T27); here a programming error.
        self.assertRaises(ValueError, StateMachine, ["a", "a"])
        self.assertRaises(ValueError, StateMachine, [])


class ClaudeBackgroundTest(unittest.TestCase):
    """background: claude has ended the turn, only background shells/monitors are
    running (2026-10-08). Up to bg_max_sec like busy, then ONE report
    `background`; when the tasks end, idle follows."""

    def _up_to_cap(self, h):
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        for _ in range(3):
            h.advance(4.1)
            h.classify(h.pop(CMD_CLASSIFY, "a"), "background")
        return h

    def test_reports_background_after_short_cap(self):
        h = self._up_to_cap(Harness(["a"], bg_max_sec=8.0,
                                    verify_interval_sec=30.0))
        self.assertEqual(h.lines, ["a background"])
        self.assertFalse(h.sm.state_of("a")["settled"])
        self.assertIsNone(h.exit)

    def test_silent_before_cap(self):
        h = Harness(["a"], bg_max_sec=60.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "background")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")

    def test_verify_holds_background_without_flapping_then_idle(self):
        h = self._up_to_cap(Harness(["a"], bg_max_sec=8.0,
                                    verify_interval_sec=30.0))
        h.advance(30.0)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "background")
        self.assertEqual(h.lines, ["a background"])
        h.advance(30.0)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a background", "a idle"])
        self.assertTrue(h.sm.state_of("a")["settled"])

    def test_working_again_clears_alarm_and_new_cycle(self):
        h = self._up_to_cap(Harness(["a"], bg_max_sec=8.0))
        h.status("a", "working")
        self.assertEqual(h.lines, ["a background", "a working"])
        self.assertFalse(h.sm.state_of("a")["busy_capped"])
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a background", "a working", "a idle"])

    def test_busy_still_uses_long_cap(self):
        h = Harness(["a"], bg_max_sec=8.0, busy_max_sec=100.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        for _ in range(3):
            h.advance(4.1)
            h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, [])


class AgyBusyTest(unittest.TestCase):
    """Busy: herdr-idle during generation/background task (agy 2026-08-31,
    grok 2026-09-02). busy is not a reportable state but a 'not yet' for the
    idle class."""

    def test_busy_prevents_idle_and_resets_window(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_DEBOUNCE)
        h.classify(cmd, "busy")
        self.assertEqual(h.lines, [])
        self.assertFalse(h.sm.state_of("a")["settled"])
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")
        h.advance(4.1)
        cmd2 = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd2.purpose, PURPOSE_DEBOUNCE)
        h.classify(cmd2, "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertTrue(h.sm.state_of("a")["settled"])

    def test_busy_cap_reports_unknown_once(self):
        h = Harness(["a", "b"], busy_max_sec=10.0, verify_interval_sec=30.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, ["a unknown"])
        self.assertTrue(h.sm.state_of("a")["busy_capped"])
        self.assertEqual(h.sm.state_of("a")["pending"], "")
        h.advance(4.1)
        self.assertEqual([(c.kind, c.name) for c in h.commands
                          if c.kind == CMD_CLASSIFY and c.name == "a"], [])
        h.advance(20.0)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_VERIFY)
        h.classify(cmd, "clean")
        self.assertEqual(h.lines, ["a unknown", "a idle"])
        # Same raw event + another debounce-busy: still ONE unknown line.
        h.status("a", "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, ["a unknown", "a idle"])

    def test_busy_from_verify_reports_no_second_idle(self):
        # idle already reported, later verify-busy: no reset, no new report.
        # Clear the report lock only on a real raw status change, otherwise a
        # second idle would arise after clean without a new cycle.
        h = Harness(["a", "b"], verify_interval_sec=30.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a idle"])
        h.advance(30.0)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_VERIFY)
        h.classify(cmd, "busy")
        self.assertEqual(h.lines, ["a idle"])
        self.assertEqual(h.sm.state_of("a")["pending"], "")
        self.assertFalse(h.sm.state_of("a")["settled"])
        h.advance(30.0)
        cmd2 = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd2.purpose, PURPOSE_VERIFY)
        h.classify(cmd2, "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertTrue(h.sm.state_of("a")["settled"])

    def test_verify_blocked_after_busy_is_reported(self):
        # Open verify, THEN window: blocked applies immediately, pending remains.
        h = Harness(["a", "b"], debounce_sec=4.0, verify_interval_sec=10.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        h.advance(6.0)
        vcmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(vcmd.purpose, PURPOSE_VERIFY)
        h.status("a", "idle")
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")
        h.classify(vcmd, "blocked")
        self.assertEqual(h.lines, ["a idle", "a blocked"])
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")
        self.assertFalse(h.sm.state_of("a")["settled"])

    def test_verify_does_not_fire_into_running_window(self):
        # verify_due BEFORE pending_until: without `if ag.pending` a verify
        # classify would arise here although the window is still running.
        h = Harness(["a"], debounce_sec=20.0, verify_interval_sec=5.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(5.1)
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")
        self.assertFalse(any(c.purpose == PURPOSE_VERIFY for c in h.commands))
        self.assertEqual(h.commands, [])
        h.advance(15.0)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_DEBOUNCE)

    def test_late_verify_busy_keeps_settled_false(self):
        h = Harness(["a", "b"], debounce_sec=4.0, verify_interval_sec=10.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a idle"])
        h.advance(6.0)
        vcmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(vcmd.purpose, PURPOSE_VERIFY)
        h.status("a", "idle")
        h.classify(vcmd, "busy")
        self.assertEqual(h.lines, ["a idle"])
        self.assertFalse(h.sm.state_of("a")["settled"])
        h.status("b", "idle")
        h.settle("b", "clean")
        self.assertIsNone(h.exit)
        self.assertFalse(h.sm.state_of("a")["settled"])
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertIn("a idle", h.lines)
        self.assertEqual(h.reason(), "all-settled")

    def test_late_verify_clean_during_window_is_no_idle(self):
        h = Harness(["a", "b"], debounce_sec=4.0, verify_interval_sec=10.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a idle"])
        h.advance(6.0)  # 1004.1+6 = 1010.1, verify_due=1010
        vcmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(vcmd.purpose, PURPOSE_VERIFY)
        h.status("a", "idle")  # new window, same generation
        h.advance(4.1)
        dcmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(dcmd.purpose, PURPOSE_DEBOUNCE)
        h.classify(dcmd, "busy")
        h.classify(vcmd, "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertFalse(h.sm.state_of("a")["settled"])
        self.assertEqual(h.sm.state_of("a")["pending"], "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertTrue(h.sm.state_of("a")["settled"])

    def test_busy_cycle_reset_on_raw_status_change(self):
        h = Harness(["a", "b"], busy_max_sec=10.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        first = h.sm.state_of("a")["busy_since"]
        self.assertGreater(first, 0.0)
        h.status("a", "working")
        self.assertEqual(h.sm.state_of("a")["busy_since"], 0.0)
        self.assertFalse(h.sm.state_of("a")["busy_capped"])
        h.status("a", "idle")
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        second = h.sm.state_of("a")["busy_since"]
        self.assertGreater(second, first)
        h.advance(4.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, [])


class MuseBlockedTest(unittest.TestCase):
    """muse 1.3.0: herdr reports raw `blocked` during the built-in command check
    ("Reviewing approval request", no dialog). For kind muse it is therefore not
    reported immediately but cross-checked via classify-pane (W1-W6). Other
    kinds stay unchanged (W4)."""

    def test_w1_busy_prevents_false_blocked(self):
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.advance(h.debounce_sec + 0.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_DEBOUNCE)
        h.classify(cmd, "busy")
        self.assertEqual(h.lines, [])
        # Raw working -> done: only the completion is reported.
        h.status("a", "working")
        h.status("a", "done")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a done"])

    def test_w2_blocked_verdict_reports_blocked_and_working_clears(self):
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.settle("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])
        h.status("a", "working")
        self.assertEqual(h.lines, ["a blocked", "a working"])

    def test_w3_command_error_reports_blocked(self):
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.advance(h.debounce_sec + 0.1)
        h.fail(h.pop(CMD_CLASSIFY, "a"))
        self.assertEqual(h.lines, ["a blocked"])
        self.assertTrue(h.noted("fail-safe"))

    def test_w4_other_kind_immediate_without_classify(self):
        h = Harness(["a"], kinds={"a": "claude"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])
        self.assertEqual(h.kinds(), [])

    def test_w5_busy_cap_reports_unknown_once(self):
        h = Harness(["a"], kinds={"a": "muse"}, busy_max_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        for _ in range(4):
            h.advance(h.debounce_sec + 0.1)
            h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, ["a unknown"])
        self.assertTrue(h.sm.state_of("a")["busy_capped"])
        # Further busy reports no second unknown.
        h.status("a", "blocked")
        h.advance(h.debounce_sec + 0.1)
        h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
        self.assertEqual(h.lines, ["a unknown"])

    def test_w6_limited_verdict_is_reported(self):
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.settle("a", "limited")
        self.assertEqual(h.lines, ["a limited"])

    def test_w7_clean_without_dialog_stays_blocked(self):
        # No dialog, no busy (quiet pane): herdr keeps the authority, unknown
        # dialog formats are not hidden.
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a blocked"])

    def test_k2_verify_error_after_cap_reports_blocked(self):
        # K2: after the busy cap only the verify rest poll runs. A failing OR
        # expiring verify cross-check must not swallow a real (unreadable)
        # dialog — fail-safe blocked.
        for mode in ("error", "deadline"):
            with self.subTest(mode=mode):
                h = Harness(["a"], kinds={"a": "muse"}, busy_max_sec=5.0,
                            verify_interval_sec=1.0, cmd_timeout_sec=2.0)
                h.resync({"a": "working"}, first=True)
                h.status("a", "blocked")
                for _ in range(3):
                    h.advance(h.debounce_sec + 0.1)
                    h.classify(h.pop(CMD_CLASSIFY, "a"), "busy")
                self.assertEqual(h.lines, ["a unknown"])
                h.advance(1.1)
                cmd = h.pop(CMD_CLASSIFY, "a")
                self.assertEqual(cmd.purpose, PURPOSE_VERIFY)
                if mode == "error":
                    h.fail(cmd)
                else:
                    h.advance(2.1)
                self.assertEqual(h.lines, ["a unknown", "a blocked"])

    def test_k3_empty_resync_snapshot_clears_kind(self):
        # K3.1: An authoritatively empty kind must clear an earlier stored muse
        # — otherwise the muse exception applies without proof and a real
        # blockage can stay silent.
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.settle("a", "busy")
        h.agent_kinds["a"] = ""
        h.resync({"a": "blocked"}, gaps=["a"])
        self.assertEqual(h.sm.state_of("a")["kind"], "")
        self.assertEqual(h.lines, ["a blocked"])

    def test_k3_kind_change_invalidates_open_command(self):
        # K3.2: a kind change at unchanged raw status is a generation change — a
        # late answer from the old kind assumption must no longer apply.
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.advance(h.debounce_sec + 0.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        h.agent_kinds["a"] = "claude"
        h.status("a", "blocked")
        h.agent_kinds["a"] = "muse"
        h.status("a", "blocked")
        h.classify(cmd, "limited")
        self.assertEqual(h.lines, ["a blocked"])

    def test_k8_resync_kind_change_without_gap_invalidates(self):
        # K8: the same proof for the RESYNC branch. Without a gap and at the same
        # raw status the kind changes (muse -> claude -> muse); the answer to the
        # old cross-check arriving afterwards must be discarded. Without `_bump`
        # in the resync kind branch it is accepted and falsely reports `limited`.
        h = Harness(["a"], kinds={"a": "muse"})
        h.resync({"a": "working"}, first=True)
        h.status("a", "blocked")
        h.advance(h.debounce_sec + 0.1)
        cmd = h.pop(CMD_CLASSIFY, "a")
        h.agent_kinds["a"] = "claude"
        h.resync({"a": "blocked"})
        h.agent_kinds["a"] = "muse"
        h.resync({"a": "blocked"})
        h.classify(cmd, "limited")
        self.assertEqual(h.lines, ["a blocked"])


class QuestionTest(unittest.TestCase):
    """`question`: the agent has written a question file (marker
    `QUESTION: <absolute path>` in the pane, file exists). The file condition
    and the priority busy > question are established by classify_text in herd.sh
    (bash fixtures T180); here stands the report semantics: like blocked an
    action state, but NOT terminal — watch keeps observing, `working` after the
    answer is the clears-alarm."""

    def test_question_action_state_not_terminal_and_clears(self):
        # idle -> classify question -> report, no exit; the agent answers and
        # works again: working is the clears-alarm; afterwards idle.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "question")
        self.assertEqual(h.lines, ["a question"])
        self.assertIsNone(h.exit)
        h.status("a", "working")
        self.assertEqual(h.lines, ["a question", "a working"])
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a question", "a working", "a idle"])
        self.assertIsNone(h.exit)      # b keeps working

    def test_clean_after_question_file_gone_stays_idle(self):
        # The orchestrator moves the file (or it was only a placeholder path):
        # classify_text yields clean, the idle stands.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a idle"])
        self.assertIsNone(h.exit)

    def test_second_question_is_reported_again(self):
        # The same state is not repeated, re-entry is.
        h = Harness(["a", "b"])
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "question")
        h.status("a", "working")
        h.status("a", "idle")
        h.settle("a", "question")
        self.assertEqual(h.lines, ["a question", "a working", "a question"])

    def test_question_after_reported_idle_from_rest_poll(self):
        # An agent is reported idle and writes the question AFTERWARDS: the
        # verification rest poll classifies again and reports question. settled
        # is therefore no one-way street as long as the watcher runs.
        h = Harness(["a", "b"], verify_interval_sec=30.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "idle")
        h.settle("a", "clean")
        self.assertEqual(h.lines, ["a idle"])
        h.advance(30.0)
        cmd = h.pop(CMD_CLASSIFY, "a")
        self.assertEqual(cmd.purpose, PURPOSE_VERIFY)
        h.classify(cmd, "question")
        self.assertEqual(h.lines, ["a idle", "a question"])
        self.assertFalse(h.sm.state_of("a")["settled"])
        self.assertIsNone(h.exit)


class RawTargetTest(unittest.TestCase):
    """Raw mode of wait --status: heuristic-free, only target plus always-match.

    Without raw_target the behavior of the existing classes stays unchanged (they
    instantiate Harness without the parameter)."""

    def test_target_blocked_idle_is_not_classified(self):
        h = Harness(["a"], raw_target="blocked")
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        h.advance(10.0)
        self.assertEqual(h.lines, [])
        self.assertEqual(h.kinds(), [])
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])
        self.assertTrue(h.sm.state_of("a")["settled"])
        self.assertEqual(h.reason(), "all-settled")

    def test_target_idle_immediate_without_classify(self):
        h = Harness(["a"], raw_target="idle")
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        self.assertEqual(h.lines, ["a idle"])
        self.assertEqual(h.kinds(), [])
        self.assertTrue(h.sm.state_of("a")["settled"])

    def test_raw_blocked_unlike_target_idle_stays_silent(self):
        h = Harness(["a", "b"], raw_target="idle")
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "blocked")
        self.assertEqual(h.lines, [])
        self.assertEqual(h.kinds(), [])
        h.status("a", "idle")
        self.assertEqual(h.lines, ["a idle"])

    def test_stalled_despite_target(self):
        h = Harness(["a"], raw_target="blocked",
                    verify_interval_sec=30.0, stall_timeout_sec=10.0)
        h.resync({"a": "working"}, first=True)
        h.advance(30.1)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        h.advance(30.0)
        h.fingerprint(h.pop(CMD_FINGERPRINT, "a"), "same")
        self.assertEqual(h.lines, ["a stalled"])
        self.assertEqual(h.kinds(), [])

    def test_lost_despite_target(self):
        h = Harness(["a"], raw_target="idle")
        h.resync({"a": "working"}, first=True)
        h.gone("a")
        h.agent_get(h.pop(CMD_AGENT_GET, "a"), present=False)
        self.assertEqual(h.lines, ["a lost"])
        self.assertEqual(h.reason(), "all-settled")

    def test_unknown_from_server_despite_target(self):
        h = Harness(["a", "b"], raw_target="idle")
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "unknown")
        self.assertEqual(h.lines, ["a unknown"])
        self.assertEqual(h.kinds(), [])

    def test_monitor_unavailable_despite_target(self):
        h = Harness(["a"], raw_target="blocked", max_events=1)
        h.resync({"a": "working"}, first=True)
        h.monitor_down()
        self.assertEqual(h.lines, ["* monitor-unavailable"])
        self.assertEqual(h.reason(), "max-events")

    def test_without_raw_target_unchanged_idle_needs_classify(self):
        h = Harness(["a"])
        h.resync({"a": "working"}, first=True)
        h.status("a", "idle")
        self.assertEqual(h.lines, [])
        h.advance(h.debounce_sec + 0.1)
        self.assertEqual(h.kinds(), [(CMD_CLASSIFY, "a")])
        h.classify(h.pop(CMD_CLASSIFY, "a"), "clean")
        self.assertEqual(h.lines, ["a idle"])

    def test_repeated_target_event_only_one_report(self):
        h = Harness(["a", "b"], raw_target="blocked")
        h.resync({"a": "working", "b": "working"}, first=True)
        h.status("a", "blocked")
        h.status("a", "blocked")
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])

    def test_late_fingerprint_from_old_cycle_vanishes(self):
        h = Harness(["a", "b"], raw_target="blocked",
                    verify_interval_sec=5.0, stall_timeout_sec=10.0)
        h.resync({"a": "working", "b": "working"}, first=True)
        h.advance(5.1)
        cmd = h.pop(CMD_FINGERPRINT, "a")
        h.status("a", "idle")
        self.assertEqual(h.lines, [])
        h.fingerprint(cmd, "same")
        self.assertGreater(h.sm.stale_results, 0)
        self.assertEqual(h.lines, [])
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])

    def test_resync_gap_no_false_hit_target_comes_after(self):
        h = Harness(["a", "b"], raw_target="blocked")
        h.resync({"a": "working", "b": "working"}, first=True)
        h.resync({"a": "working", "b": "working"}, gaps=["a"])
        self.assertEqual(h.lines, [])
        h.status("a", "blocked")
        self.assertEqual(h.lines, ["a blocked"])

    def test_monitor_down_restored_no_false_hit_target_comes_after(self):
        h = Harness(["a", "b"], raw_target="idle")
        h.resync({"a": "working", "b": "working"}, first=True)
        h.monitor_down()
        self.assertEqual(h.lines, ["* monitor-unavailable"])
        h.monitor_up()
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored"])
        h.resync({"a": "working", "b": "working"})
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored"])
        h.status("a", "idle")
        self.assertEqual(h.lines[-1], "a idle")
        self.assertEqual(h.lines, ["* monitor-unavailable", "* monitor-restored",
                                   "a idle"])


if __name__ == "__main__":
    unittest.main()
