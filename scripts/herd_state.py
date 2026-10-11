#!/usr/bin/env python3
# herd_state.py — REPORT RULES of event observation as a PURE state machine.
# Step B from docs/plan-watch-events.md. NO IO: no socket, no thread, no
# clock — time ALWAYS arrives as the `now` parameter (monotone seconds) from outside.
#
#   INPUTS   abstract events (on_*) and time ticks (tick)
#   OUTPUTS  Outcome(reports, commands, notes, exit)
#              reports  report lines "<name> <status>" (stdout contract of watch)
#              commands orders to the ADAPTER (Step C, see COMMAND PROTOCOL)
#              notes    diagnostic lines for stderr (error paths of the commands)
#              exit     abort decision: 0 = all done or --max-events,
#                       124 = time limit of the OBSERVATION (invariant 6)
#
# WHY A SEPARATE MODULE (and no class in herd_events.py): the report rules have
# ZERO coupling to transport/RPC/stream — this module imports nothing from
# herd_events.py. As a leaf module the state machine can be imported without
# daemon, socket and reader thread and is therefore testable as a pure
# event/tick sequence (tests/test_state_machine.py). The direction is
# deliberately one-sided: Step C attaches it to the monitor hooks
# handle_event/handle_tick/handle_resync, not the other way round.
#
# CONTRACT ORIGIN: scripts/herd.sh (`watch`/`wait`) and tests/run.sh. The
# T numbers in the comments name the test case that proves the respective rule;
# the equivalents are in tests/test_state_machine.py.
#
# STATES (reports): idle · done · blocked · limited · auth · failed ·
#   question · background · stalled · unknown · working (only as all-clear) ·
#   lost, plus the
#   GLOBAL reports "* monitor-unavailable" / "* monitor-restored". `not_found` BEFORE
#   the start is NOT a report but exit 1 of the caller (invariant 5) —
#   only agents that have been seen at least once arrive here.
#
# `question`: the agent has written a question file (marker
# `QUESTION: <absolute path>` in the pane, file exists). Action state like
# blocked — NOT terminal: observation continues, a later
# `working` is the all-clear after the answer, a new question reports again.
# The verdict comes from classify_text (busy takes precedence: a working agent
# never asks).
#
# `background`: claude has ended the turn, but background shells/monitors
# are still running (classify-pane verdict `background`). Treated like busy
# until bg_max_sec (claude wakes up by itself after a monitor hit), then
# reported ONCE — action state, not terminal: the orchestrator checks
# the pane (completion marker? leftover shell?). Without this report
# watch stayed silent for a forgotten shell until the busy cap (2026-10-08).
# When the background tasks end, idle follows.
#
# RAW MODE (`raw_target=...`): ONLY for `wait --status X`. Deliberately
# heuristic-free — no quiet window, no classify-pane for idle/done, no
# normalization (no blocked/limited/auth/failed/question/busy from the pane). The
# raw status is reported as soon as it == raw_target (immediately), plus unchanged the
# always-hits stalled / lost / unknown / "* monitor-unavailable". A raw
# `blocked` that is not the target stays silent (T5). Without raw_target the
# behavior is identical to the previous watch path.
#
# RAW `blocked` + KIND `muse` (muse 1.3.0): Muse checks shell commands with
# a built-in reviewer and then shows "Reviewing approval request" without a
# dialog — herdr reports raw `blocked` for it. Such events are NOT reported
# immediately but trigger a classify-pane cross-check: busy ->
# synthetic working (with the same busy_max_sec cap rule as idle/done),
# blocked/clean -> blocked, limited/auth/failed -> that state, error/deadline
# -> blocked (fail-safe). All other kinds report blocked unchanged immediately.
# The kind comes from the resync snapshot (field "agent" from agent.get); without
# a known kind, blocked stays unchanged.
#
# ---------------------------------------------------------------------------
# COMMAND PROTOCOL — binding for the adapter in Step C
# ---------------------------------------------------------------------------
# Every command is a Command(kind, name, request_id, generation, purpose):
#
#   kind        classify-pane | stall-fingerprint | agent.get
#   name        agent name. The ADAPTER resolves the pane_id (it knows it from
#               the resync snapshot); the pattern lists remain single source in
#               herd.sh (plan, design decision 2 and 3).
#   request_id  unique per machine, monotonically increasing.
#   generation  state generation of the agent at the time of the request.
#   purpose     debounce | verify | gone — diagnosis/logging; the adapter
#               must not decide anything based on it.
#
# The adapter executes the command and returns EXACTLY ONE answer, always with
# the `request_id`:
#
#   classify-pane      -> on_classify(now, request_id, verdict)
#                         verdict MUST be blocked|limited|auth|failed|busy|
#                         background|question|clean
#   stall-fingerprint  -> on_fingerprint(now, request_id, fingerprint,
#                                         limited, failed)
#                         fingerprint MUST be a non-empty string,
#                         limited and failed MUST be bool
#   agent.get          -> on_agent_get(now, request_id, present, raw_status)
#                         present MUST be bool; raw_status only when present
#   any failure        -> on_command_failed(now, request_id, reason)
#                         (pane not readable, verb exit code != 0, RPC error,
#                         timeout in the adapter, unexpected output …)
#
# ERRORS ARE NOT `clean`: an unreadable pane must never pass as a clean
# completion and make the agent terminal. `clean` is
# exclusively a SUCCESSFUL result; missing or wrongly typed
# values are treated like on_command_failed (and diagnosed).
#
# CORRELATION: an answer is ONLY processed if its request_id is still open
# AND the generation of the agent has not changed since the request.
# The generation rises on every change of the RAW status, on a resync gap
# (seq jump or pane_id change), on `lost` and on monitor-unavailable.
# Late answers fizzle out (counter `stale_results`). Without this
# correlation a classify from a DISCARDED quiet window could report a
# later idle prematurely as blocked, and an old fingerprint could
# falsify the stall clock of a NEW working cycle (working -> idle ->
# working looks "matching" again for an old result).
#
# DEADLINE AND RETRY: every open command has a deadline
# (cmd_timeout_sec). If it expires or the adapter reports an error:
#   debounce  up to CMD_MAX_TRIES attempts at interval cmd_retry_sec. Then
#             `unknown` is reported — NOT the unconfirmed idle/done — and
#             the verification rest poll keeps classifying. The agent thus
#             does NOT become terminal: "we do not know" is an
#             action event, not a completion.
#   verify    no retry of its own; the rest-poll clock IS the retry.
#   gone      up to CMD_MAX_TRIES attempts. Then NO lost (invariant 4:
#             not knowing is not disappearing) and the slot is freed so that
#             another pane.closed triggers the cross-check again.
# On monitor-unavailable ALL open commands are invalidated (the same
# daemon will not answer them anymore) and the clocks stand still; after
# monitor-restored and the following resync the machine requests
# anew as needed. The resync is also the cross-check for pane.closed events
# that could not be checked during the outage.
#
# Environment (defaults; the caller may override them via the constructor):
#   HERD_EVENTS_DEBOUNCE_SEC     quiet window for idle/done (default 4, measured
#                                on the real idle race after send — measurement run
#                                2026-07-24)
#   HERD_EVENTS_VERIFY_SEC       verification rest poll per agent (default 30)
#   HERD_EVENTS_CMD_TIMEOUT_SEC  deadline of a command answer (default 30)
#   HERD_EVENTS_CMD_RETRY_SEC    interval of the retries (default 2)
#   HERD_EVENTS_BUSY_MAX_SEC     cap for agy-busy repetition of the
#                                quiet window (default 900)
#   HERD_EVENTS_BG_MAX_SEC       waiting time until the report `background`
#                                (default 180)

import os
from collections import OrderedDict, namedtuple

EXIT_OK = 0
EXIT_TIMEOUT = 124

# Name of the global reports. watch outputs events that affect ALL agents
# under "*" — with four agents four identical lines would just be noise.
GLOBAL = "*"

CMD_CLASSIFY = "classify-pane"
CMD_FINGERPRINT = "stall-fingerprint"
CMD_AGENT_GET = "agent.get"

# Purpose of a command. It decides about retry and fallback.
PURPOSE_DEBOUNCE = "debounce"   # dialog cross-check at the end of a quiet window
PURPOSE_VERIFY = "verify"       # verification rest poll (~30 s)
PURPOSE_GONE = "gone"           # cross-check for pane.closed/pane.exited
PURPOSES = (PURPOSE_DEBOUNCE, PURPOSE_VERIFY, PURPOSE_GONE)

# Attempts per purpose before the fallback applies. Three attempts covered every
# transient read error observed in practice; after that it is a finding, not a
# loop (the same reasoning as RESYNC_MAX_ATTEMPTS in herd_events.py).
CMD_MAX_TRIES = 3

# idle and done are ONE class (invariant 1): a change between the two is the
# same completed work and must not report it twice.
DONE_CLASS = "settled"
QUIET_STATES = frozenset(("idle", "done"))
# Action states: worth reporting immediately, and only after them is a later
# `working` an all-clear (invariant 2). Like blocked, `question` is an
# action state but not a terminal condition: the agent lives on and continues
# delivering after the answer.
ACTION_STATES = frozenset(("blocked", "limited", "auth", "failed", "question",
                           "background", "stalled", "unknown"))
# Successful results of `classify-pane`. `clean` means "checked and
# inconspicuous" — a failure is NOT clean (see COMMAND PROTOCOL).
# busy is NOT a reportable state but a "not yet" for the idle class
# (agy 2026-08-31: herdr idle during generation). VALID_VERDICTS contains it,
# VERDICTS (the reportable heuristic states) does not.
VERDICT_CLEAN = "clean"
VERDICT_BUSY = "busy"
# claude: turn ended, background shells/monitors still running (see `background`
# above). Treated like busy until bg_max_sec, then reported as state `background`.
VERDICT_BACKGROUND = "background"
VERDICTS = frozenset(("blocked", "limited", "auth", "failed", "question"))
VALID_VERDICTS = VERDICTS | frozenset((VERDICT_CLEAN, VERDICT_BUSY,
                                       VERDICT_BACKGROUND))

# Internal phases of the quiet window per agent.
_PHASE_NONE = ""
_PHASE_WINDOW = "window"    # window running, report pending
_PHASE_AWAIT = "await"      # window expired, classify result outstanding

# Report texts, verbatim to herd.sh — Step C outputs them on stderr and
# adds the duration and the restart hint for the time limit (for that it needs
# the names and the minute figure, which are deliberately unknown here).
MSG_ALL_SETTLED = ("[herd] watch: all observed agents are done "
                   "(or gone).")
MSG_TIMEOUT = ("[herd] watch TIMEOUT — observation ends, the agents keep "
               "RUNNING.")


def _env_float(name, default):
    """Positive number from the environment; nonsense silently falls back to
    the default. Deliberately duplicated here and NOT imported from herd_events.py:
    this module should stay a leaf without transport dependency."""
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        val = float(raw)
    except ValueError:
        return default
    return val if val > 0 else default


DEBOUNCE_SEC = _env_float("HERD_EVENTS_DEBOUNCE_SEC", 4.0)
VERIFY_SEC = _env_float("HERD_EVENTS_VERIFY_SEC", 30.0)
CMD_TIMEOUT_SEC = _env_float("HERD_EVENTS_CMD_TIMEOUT_SEC", 30.0)
CMD_RETRY_SEC = _env_float("HERD_EVENTS_CMD_RETRY_SEC", 2.0)
BUSY_MAX_SEC = _env_float("HERD_EVENTS_BUSY_MAX_SEC", 900.0)
BG_MAX_SEC = _env_float("HERD_EVENTS_BG_MAX_SEC", 180.0)


Report = namedtuple("Report", "name status")
Command = namedtuple("Command", "kind name request_id generation purpose")
Exit = namedtuple("Exit", "code reason message")
# Open command (in flight). `generation` freezes the state for which it was
# requested — its answer is valid only for that.
_Req = namedtuple("_Req", "name kind purpose generation deadline")


class Outcome(namedtuple("Outcome", "reports commands notes exit")):
    """Result of ONE input. The order within `reports` is the
    output order on stdout."""

    __slots__ = ()

    def lines(self):
        """The stdout lines of this input — the watch contract in text form."""
        return ["%s %s" % (r.name, r.status) for r in self.reports]


class _Stop(Exception):
    """Internal: abort decision made, remaining processing is skipped.
    Mirror of emit_event in herd.sh, which exits immediately at --max-events —
    without the abort, reports AFTER the limit would be possible."""


def status_class(status):
    """Report class of a state. idle/done merge (invariant 1)."""
    return DONE_CLASS if status in QUIET_STATES else status


def normalize_status(raw, verdict):
    """Counterpart to `normalize_status` in herd.sh: there the function reads the
    visible pane and applies looks_blocked/looks_limited/looks_auth/
    looks_failed, here exactly that result arrives as `verdict` from the
    adapter (command classify-pane). The PATTERNS thus remain single source
    in herd.sh.

    Only `working` (→ limited/failed) and `idle`/`done` (→ blocked/limited/
    auth/failed/question/busy) are corrected; every other raw status stays
    untouched. busy on idle/done becomes synthetic working; on working
    busy is meaningless."""
    if raw in QUIET_STATES:
        if verdict in (VERDICT_BUSY, VERDICT_BACKGROUND):
            return "working"
        return verdict if verdict in VERDICTS else raw
    if raw == "working":
        if verdict == "limited":
            return "limited"
        if verdict == "failed":
            return "failed"
        return raw
    return raw


class _Slot(object):
    """Command slot per purpose: at most ONE open command per purpose and
    agent. `tries` counts the attempts since the last state change,
    `retry_at` carries the time of the retry."""

    __slots__ = ("request_id", "tries", "retry_at")

    def __init__(self):
        self.reset()

    def reset(self):
        self.request_id = None
        self.tries = 0
        self.retry_at = 0.0

    @property
    def busy(self):
        """Open OR waiting for retry — in both cases the purpose is still
        running and must not be started anew."""
        return self.request_id is not None or self.tries > 0


class _Agent(object):
    """State of ONE observed agent.

    The reported/last_reported separation is taken from herd.sh:
      reported       active report lock — which state currently counts as
                     reported. Cleared as soon as the agent leaves it.
      last_reported  last state ever reported, outlives the clearing.
                     Only with it can one decide whether a `working` is an
                     all-clear after blocked/stalled or mere noise.

    `gen` is the state generation: it rises on every change of the
    RAW status, on a resync gap, on lost and on monitor-unavailable and
    thus decides whether a command answer is still current.
    """

    __slots__ = ("name", "raw", "reported", "last_reported", "phase", "pending",
                 "pending_until", "settled", "lost", "verify_due", "fp",
                 "fp_since", "stalled", "gen", "slots", "busy_since",
                 "busy_capped", "kind")

    def __init__(self, name, now):
        self.name = name
        self.raw = ""              # last known RAW status ("" = never seen)
        self.reported = ""
        self.last_reported = ""
        self.phase = _PHASE_NONE
        self.pending = ""          # idle/done whose report hangs in the window
        self.pending_until = 0.0
        self.settled = False       # idle/done REPORTED → terminal (invariant 3)
        self.lost = False
        self.verify_due = 0.0
        self.fp = ""               # last stall fingerprint
        self.fp_since = now
        self.stalled = False       # stall latch (see herd.sh)
        self.gen = 0
        self.busy_since = 0.0      # first busy of this cycle (0 = none)
        self.busy_capped = False   # cap reached: unknown/background reported
        self.kind = ""             # backend kind (muse: cross-check raw blocked)
        self.slots = dict((p, _Slot()) for p in PURPOSES)

    @property
    def terminal(self):
        return self.lost or self.settled


class StateMachine(object):
    """Report rules of `watch` — pure, without IO.

    All inputs return an `Outcome`. Once an abort decision has been made,
    further inputs return the same decision and change nothing
    more (so the adapter may keep feeding without a special case).

    Times are seconds on an arbitrary monotone scale; the machine only
    compares, it does not read a clock. EVERY input carries `now`
    and thus first checks the time limit (invariant 6): a report after
    the deadline expires must not fixate an exit-0 decision anymore.
    """

    def __init__(self, names, now=0.0, debounce_sec=None, verify_interval_sec=None,
                 stall_timeout_sec=0.0, max_events=0, timeout_sec=0.0,
                 cmd_timeout_sec=None, cmd_retry_sec=None, busy_max_sec=None,
                 raw_target=None, bg_max_sec=None):
        names = list(names)
        if not names:
            raise ValueError("StateMachine requires at least one agent name")
        if len(set(names)) != len(names):
            # Duplicate names are a usage error in herd.sh (exit 2, T27) and
            # are caught BEFORE the delegation. Reject hard here anyway:
            # two entries for the same agent would be two quiet windows and
            # two report locks for one truth.
            raise ValueError("StateMachine: duplicate agent names")
        self._agents = OrderedDict((n, _Agent(n, now)) for n in names)
        self.names = names
        self.debounce_sec = DEBOUNCE_SEC if debounce_sec is None else float(debounce_sec)
        self.verify_interval_sec = (VERIFY_SEC if verify_interval_sec is None
                                    else float(verify_interval_sec))
        self.stall_timeout_sec = float(stall_timeout_sec)
        self.cmd_timeout_sec = (CMD_TIMEOUT_SEC if cmd_timeout_sec is None
                                else float(cmd_timeout_sec))
        if self.cmd_timeout_sec <= 0:
            # A deadline of 0 would declare every command expired in the next
            # tick and burn the attempt budget immediately —
            # the adapter would never get to answer.
            self.cmd_timeout_sec = CMD_TIMEOUT_SEC
        self.cmd_retry_sec = (CMD_RETRY_SEC if cmd_retry_sec is None
                              else max(0.0, float(cmd_retry_sec)))
        self.busy_max_sec = (BUSY_MAX_SEC if busy_max_sec is None
                             else float(busy_max_sec))
        self.bg_max_sec = BG_MAX_SEC if bg_max_sec is None else float(bg_max_sec)
        self.max_events = int(max_events)
        # Raw mode: ONLY wait --status. Empty/None = normal watch path.
        self.raw_target = raw_target or None
        # Default 0 = unlimited (like watch): a permanently blocked agent
        # should keep being observed, --timeout is the emergency brake.
        self.deadline = (now + timeout_sec) if timeout_sec > 0 else None
        self.events = 0
        self.stale_results = 0     # discarded, no-longer-current answers
        self.monitor_down = False
        self._inflight = {}        # request_id -> _Req
        self._next_id = 0
        self._finished = None
        self._reports = []
        self._commands = []
        self._notes = []
        self._noted = set()

    # -- Output collection ---------------------------------------------------

    def _begin(self):
        self._reports = []
        self._commands = []
        self._notes = []

    def _end(self):
        if self._finished is None and self._all_terminal():
            # Terminal = fully observed: lost or REPORTED idle/done.
            # Deliberately NOT blocked/limited/auth/failed/question/stalled — the agent
            # lives on and delivers a result later (T6).
            self._finish(EXIT_OK, "all-settled", MSG_ALL_SETTLED)
        return Outcome(tuple(self._reports), tuple(self._commands),
                       tuple(self._notes), self._finished)

    def _feed(self, now, fn):
        """ONE entrance for all inputs — and thus ONE place for the
        deadline check. It runs BEFORE processing, like `check_deadline`
        in herd.sh before every sleep/continue: if an event or a command answer
        arrives after the time limit expires, it must not become a
        report, let alone an exit 0 (invariant 6)."""
        self._begin()
        if self._finished is not None:
            return Outcome((), (), (), self._finished)
        try:
            if self.deadline is not None and now >= self.deadline:
                self._finish(EXIT_TIMEOUT, "timeout", MSG_TIMEOUT)
                raise _Stop()
            fn()
        except _Stop:
            pass
        return self._end()

    def _finish(self, code, reason, message):
        if self._finished is None:
            self._finished = Exit(code, reason, message)

    def _report(self, name, status):
        self._reports.append(Report(name, status))
        self.events += 1
        if self.max_events and self.events >= self.max_events:
            self._finish(EXIT_OK, "max-events",
                         "[herd] watch: --max-events (%d) erreicht — Beobachtung "
                         "endet, Agenten laufen ggf. weiter." % self.max_events)
            raise _Stop()

    def _note(self, msg, key=None):
        """Diagnostic line for stderr. With `key` only ONCE per key — a
        permanently unreadable pane would otherwise produce a line with every
        rest poll and cover the reports beside it."""
        if key is not None:
            if key in self._noted:
                return
            self._noted.add(key)
        self._notes.append(msg)

    def _all_terminal(self):
        return all(ag.terminal for ag in self._agents.values())

    # -- Inputs: events ------------------------------------------------------

    def on_status(self, now, name, raw_status, kind=None):
        """Raw status change of an observed agent
        (`pane.agent_status_changed`, Enum idle|working|blocked|done|unknown).

        `kind` is the backend kind (field "agent" from agent.get) if the
        adapter knows it: `None` = not passed (previous value stays),
        `""` = authoritatively no kind known (clears an earlier kind). Only
        muse needs it: herdr reports raw blocked WITHOUT a dialog during muse's
        built-in command check.

        The adapter filters events of foreign panes; unknown names are a
        no-op here."""
        return self._feed(now, lambda: self._observe(now, name, raw_status, kind))

    def on_pane_gone(self, now, name):
        """`pane.closed`/`pane.exited` for the pane of an agent.

        FIRST creates an agent.get cross-check and NOT immediately `lost`: after
        `events.subscribe` the daemon also delivers events of foreign and
        already past panes (finding from Step A). A naive `lost`
        would thus be a false alarm — and `lost` means "work counts as NOT
        finished" (invariant 4/5)."""
        return self._feed(now, lambda: self._pane_gone(now, name))

    def on_monitor_unavailable(self, now):
        """The event stream has broken off or the liveness ping failed.
        GLOBAL report, no state statement about an agent — and it
        counts against --max-events like every event (T9/T31). All open
        commands are invalidated: the same daemon will not answer them anymore."""
        return self._feed(now, lambda: self._monitor(now, False))

    def on_monitor_restored(self, now):
        """Stream rebuilt (the resync follows as its own input). The
        clocks are reset so that a long outage does not trigger a burst of
        commands."""
        return self._feed(now, lambda: self._monitor(now, True))

    def on_resync(self, now, snapshots, gaps=(), first=False, kinds=None):
        """Result of the four-stage start sequence or of a reconnect resync.

          snapshots  {name: raw status} — value None means `agent_not_found`.
          kinds      {name: backend kind} from the same snapshot (agent.get
                     field "agent"); `name in kinds` with an empty value clears a
                     previously known kind, a missing name leaves it in place.
          gaps       names with a seq jump or pane_id change between
                     discovery and control snapshot: a complete state change lay
                     in the window (T29 and the reconnect gap).
                     A gap clears the report lock AND invalidates open
                     commands — an answer that still describes the old pane or the
                     old cycle is worthless.
          first      first resync (start of the observation).

        The snapshot is the source for the state for which there will be NO event
        anymore — e.g. an agent that was already done before the `watch`.
        Therefore it runs through the same path as a status event, including the
        quiet window: `watch` is typically started right after `send`,
        and exactly there lies the idle race.

        `None` on the FIRST resync is a never-seen agent = input error
        (exit 1, invariant 5) and the caller's business; it is ignored here.
        Later, `None` is the authoritative statement "gone" → `lost`. The resync
        is thus also the cross-check for pane.closed events that could not be
        checked during an outage."""
        return self._feed(now, lambda: self._resync(now, snapshots, gaps, first,
                                                    kinds))

    # -- Inputs: command results ---------------------------------------------

    def on_classify(self, now, request_id, verdict):
        """Result of `classify-pane`: blocked|limited|auth|failed|busy|question|clean.

        busy is not reportable — a "not yet" for the idle class
        (background task / generation, herdr idle). Any other value
        (including None) is NOT clean but an adapter error and is treated like
        on_command_failed — an unreadable pane must not become terminal as a
        clean completion."""
        return self._feed(now, lambda: self._classified(now, request_id, verdict))

    def on_fingerprint(self, now, request_id, fingerprint=None, limited=False,
                       failed=False):
        """Result of `stall-fingerprint` (only for agents in RAW status
        working): normalized pane fingerprint plus limited check
        (self-retry stays permanently `working` at the usage limit) and
        failed check (model error at raw working, analogous to limited).

        A missing/empty fingerprint is a read error and thus an
        adapter error — NOT "no stall": otherwise a permanently
        unreadable pane could silently switch off stall detection."""
        return self._feed(
            now, lambda: self._fingerprinted(
                now, request_id, fingerprint, limited, failed))

    def on_agent_get(self, now, request_id, present, raw_status=None):
        """Result of the agent.get cross-check for a pane_closed/pane_exited.

        present=False is the only way to `lost`. present=True is the
        all-clear: a transient dropout or a replayed
        foreign event must neither report `lost` nor clear the report lock
        (invariant 4, T25). Exactly that happens here by itself because the same
        status has the same report class. A FAILURE of the query is no
        statement and belongs to on_command_failed."""
        return self._feed(
            now, lambda: self._agent_get(now, request_id, present, raw_status))

    def on_command_failed(self, now, request_id, reason=""):
        """The adapter could not execute the command (pane not readable,
        verb exit code != 0, RPC error, own timeout …). Leads per purpose to
        retry or the documented fallback — see COMMAND PROTOCOL."""
        return self._feed(now, lambda: self._failed(now, request_id, reason))

    def tick(self, now):
        """Timekeeper: time limit, deadlines of open commands, end of the
        quiet windows, retries, verification rest poll.

        Must be called regularly (Step A: `Monitor._budget` ensures
        that the main loop never blocks for longer than one tick). No
        deadline hangs on incoming events — a dead-silent stream
        must not stop the clocks."""
        return self._feed(now, lambda: self._tick_all(now))

    # -- Internals: command lifecycle ----------------------------------------

    def _issue(self, now, ag, kind, purpose):
        slot = ag.slots[purpose]
        self._next_id += 1
        rid = self._next_id
        slot.request_id = rid
        slot.tries += 1
        slot.retry_at = 0.0
        self._inflight[rid] = _Req(ag.name, kind, purpose, ag.gen,
                                   now + self.cmd_timeout_sec)
        self._commands.append(Command(kind, ag.name, rid, ag.gen, purpose))

    def _resolve(self, request_id, kind):
        """Assign an answer. Returns (agent, req) — or (None, None) if the
        answer is no longer current."""
        req = self._inflight.get(request_id)
        if req is None or (kind is not None and req.kind != kind):
            self._stale(request_id, "unknown or wrongly typed request_id")
            return None, None
        ag = self._agents.get(req.name)
        if ag is None or ag.lost or ag.gen != req.generation:
            # Second safeguard: on a generation change the entry is
            # normally already removed.
            self._inflight.pop(request_id, None)
            self._stale(request_id, "Generation gewechselt")
            return None, None
        return ag, req

    def _stale(self, request_id, why):
        self.stale_results += 1
        self._note("[herd] command reply #%s discarded (%s) — it describes "
                   "an outdated state." % (request_id, why), key="stale")

    def _close(self, request_id, ag, purpose):
        self._inflight.pop(request_id, None)
        ag.slots[purpose].reset()

    def _invalidate(self, ag):
        """Discard open commands (state change, outage, lost). NO retry
        follows: whatever is needed anew is re-established by the respective
        purpose itself (quiet window, rest-poll clock, next pane.closed or
        the resync)."""
        for slot in ag.slots.values():
            if slot.request_id is not None:
                self._inflight.pop(slot.request_id, None)
            slot.reset()

    def _bump(self, ag):
        """Raise the state generation and invalidate all open commands.
        From here on every older answer is outdated. The agy-busy cycle
        belongs to the raw status: new status / new generation = new clock."""
        ag.gen += 1
        ag.busy_since = 0.0
        ag.busy_capped = False
        self._invalidate(ag)

    def _failed(self, now, request_id, reason):
        ag, req = self._resolve(request_id, None)
        if ag is None:
            return
        self._command_failed(now, ag, req, request_id, reason or "Adapterfehler")

    def _command_failed(self, now, ag, req, request_id, reason):
        """Failed or expired command: retry or
        fallback, per purpose (see COMMAND PROTOCOL)."""
        self._inflight.pop(request_id, None)
        slot = ag.slots[req.purpose]
        slot.request_id = None
        if (req.kind == CMD_CLASSIFY and ag.raw == "blocked"
                and ag.kind == "muse"):
            # Fail-safe for EVERY classification command on raw blocked
            # (debounce AND verify): herdr reported blocked, the pane cross-check
            # failed (pane not readable, deadline, adapter error).
            # Better to report blocked than to hide the finding — NOT unknown,
            # because unknown would conceal a real dialog. Also applies
            # after the busy cap, when only the verify rest poll still runs.
            slot.reset()
            ag.phase = _PHASE_NONE
            ag.pending = ""
            self._note("[herd] '%s': blocked cross-check failed (%s) — "
                       "reporting 'blocked' (fail-safe)." % (ag.name, reason),
                       key=("blocked-check", ag.name))
            self._apply(now, ag, "blocked")
            return
        if req.purpose == PURPOSE_VERIFY:
            # No retry of its own: the rest-poll clock comes back in
            # verify_interval_sec anyway. The last reported state
            # stays valid — no hole arises in the observation.
            slot.reset()
            self._note("[herd] '%s': %s failed (%s) — the "
                       "verification rest-poll will try again."
                       % (ag.name, req.kind, reason), key=("verify", ag.name))
            return
        if slot.tries < CMD_MAX_TRIES:
            # Even the first failure is diagnosed — deduplicated per
            # agent and purpose. A systematic adapter error (wrong types,
            # missing verb) would otherwise be invisible until the budget is
            # exhausted.
            self._note("[herd] '%s': %s failed (%s) — attempt %d of %d."
                       % (ag.name, req.kind, reason, slot.tries, CMD_MAX_TRIES),
                       key=("retry", ag.name, req.purpose))
            slot.retry_at = now + self.cmd_retry_sec
            return
        slot.reset()
        if req.purpose == PURPOSE_DEBOUNCE:
            # Do not report unconfirmed idle/done: an unreadable pane
            # could show an approval dialog, and the report would be
            # terminal. Therefore `unknown` is reported — an action state,
            # not terminal, and the rest poll keeps classifying. (T24 has
            # the same reason: silent loss of control is the worse
            # alternative.)
            ag.phase = _PHASE_NONE
            ag.pending = ""
            self._note("[herd] '%s': pane not classifiable after %d attempts "
                       "(%s) — reporting 'unknown' instead of an unconfirmed "
                       "completion." % (ag.name, CMD_MAX_TRIES, reason))
            self._apply(now, ag, "unknown")
            return
        # PURPOSE_GONE: not knowing is not disappearing (invariant 4).
        self._note("[herd] '%s': agent.get cross-check failed after %d attempts "
                   "(%s) — NO 'lost' reported; another "
                   "pane.closed triggers the check again."
                   % (ag.name, CMD_MAX_TRIES, reason))

    # -- Internals: observation ----------------------------------------------

    def _agent(self, name):
        ag = self._agents.get(name)
        if ag is None or ag.lost:
            # After `lost` the agent is fully observed. Further events
            # (the daemon delivers pane_closed multiple times) must not
            # revive it or report anything.
            return None
        return ag

    def _observe(self, now, name, raw, kind=None):
        """Process one observation of the RAW status."""
        ag = self._agent(name)
        if ag is None:
            return
        kind_changed = False
        if kind is not None and kind != ag.kind:
            # A kind change is like a state change: open commands
            # describe the OLD kind assumption (muse exception) and must
            # be discarded (otherwise a late answer takes effect).
            ag.kind = kind
            kind_changed = True
        raw = raw.strip() if isinstance(raw, str) else ""
        if not raw:
            return
        if raw in ("monitor-unavailable", "unavailable"):
            # "we do not know right now" is NO state statement: it must
            # neither report anything nor clear the report lock, otherwise the
            # old state is reported twice after a single dropout.
            return
        if raw in ("lost", "not_found"):
            # Synthetic states normally only come via the
            # cross-check; treat them the same way defensively as raw status.
            self._gone_confirmed(now, ag)
            return
        if not ag.raw:
            # First observation: from now on the verification clock runs.
            ag.verify_due = now + self.verify_interval_sec
        prev_raw = ag.raw
        ag.raw = raw
        if raw != prev_raw or kind_changed:
            # New state OR new kind: all open commands describe
            # the old one. THAT is the correlation basis — a fingerprint from
            # an earlier working section must not influence the stall clock of a new
            # cycle (working -> idle -> working), and a
            # classify from a discarded quiet window must not report a later idle
            # prematurely as blocked.
            self._bump(ag)
        if raw != "working":
            # One of the two valid releases of the stall latch: the agent
            # has left `working` (the other is a new fingerprint).
            ag.stalled = False
            ag.fp = ""
            ag.fp_since = now
        if self.raw_target:
            # Raw mode: the status goes unfiltered to _apply. No window,
            # no classify — heuristic bypassed (T5).
            ag.phase = _PHASE_NONE
            ag.pending = ""
            self._apply(now, ag, raw)
            return
        if raw in QUIET_STATES:
            self._start_window(now, ag, raw, prev_raw)
            return
        if raw == "blocked" and ag.kind == "muse":
            # muse 1.3.0 checks shell commands with a built-in reviewer:
            # the pane shows "Reviewing approval request (… · esc to interrupt)"
            # WITHOUT a dialog, but herdr reports raw `blocked` for it. Therefore
            # do NOT report immediately but let quiet window + pane cross-check
            # (classify-pane) decide: real dialog -> blocked,
            # internal reviewer (busy) -> working. Only kind muse; every other
            # kind reports blocked unchanged immediately.
            self._start_blocked_window(now, ag, raw, prev_raw)
            return
        # Action states and working need no window: a running one
        # discards this event (plan, design decision 1 — "a working event
        # arriving during the window discards the report"; T2).
        ag.phase = _PHASE_NONE
        ag.pending = ""
        self._apply(now, ag, raw)

    def _start_window(self, now, ag, raw, prev_raw):
        """Open the quiet window for idle/done (settle replacement).

        The report lock is cleared IMMEDIATELY, not only at the end of the window:
        the event already proves that the agent has left the reported state.
        Without that, a second dialog would stay silent whose short
        idle in between was never reported (T21)."""
        self._unlock(ag, DONE_CLASS)
        if ag.pending == raw and ag.phase != _PHASE_NONE and prev_raw == raw:
            # Duplicate of the same event: do NOT extend the window,
            # otherwise a stream of repetitions delays the report endlessly.
            # A running classify stays valid (the generation is the same
            # because the raw status has not changed).
            return
        ag.phase = _PHASE_WINDOW
        ag.pending = raw
        ag.pending_until = now + self.debounce_sec

    def _start_blocked_window(self, now, ag, raw, prev_raw):
        """Quiet window for a raw `blocked` of kind muse.

        Like _start_window, but WITHOUT clearing the report lock of the idle class:
        an already reported blocked stays until a real
        raw status change — otherwise a repeated blocked event would report
        the same twice. The window arms the same PURPOSE_DEBOUNCE slot as
        idle/done; the verdict is evaluated in _blocked_classified."""
        if ag.pending == raw and ag.phase != _PHASE_NONE and prev_raw == raw:
            # Duplicate of the same event: do not extend the window.
            return
        ag.phase = _PHASE_WINDOW
        ag.pending = raw
        ag.pending_until = now + self.debounce_sec

    def _apply(self, now, ag, status, unlock=True):
        """Apply the effective state: maintain the report lock and report if needed.

        unlock=False: synthetic working from agy-busy. The raw status has
        not changed, so the idle report lock stays — otherwise
        a later clean would report a second idle without a
        new cycle having occurred."""
        if ag.stalled and status in ("working", "limited"):
            # Stall latch: without it
            # the state falls back to
            # working between two fingerprint checks — reported as all-clear — and then to
            # stalled again: endless flapping (T22).
            status = "stalled"
        if unlock:
            self._unlock(ag, status_class(status))
        if status_class(status) != DONE_CLASS:
            # The terminal property ends as soon as the agent leaves the idle/done
            # class — the next completion is a new event.
            ag.settled = False
        want = self._want(ag, status)
        # Compare against the CLASS, not against the text: idle and done are
        # ONE class (invariant 1). herd.sh compares the
        # strings at this point and therefore reports a direct idle->done change as a
        # second event — contradicting its own comment ("a
        # change between the two is the same completed work and must not
        # report it twice"). Here the documented intent applies; the
        # Step-B review explicitly confirmed the deviation. Nothing is
        # concealed by this: a truly new completion always has a
        # working or a resync gap in between that clears the lock (T20).
        if not want or status_class(want) == status_class(ag.reported):
            # After synthetic working (busy) settled is False but the lock
            # is still idle: a later clean should set settled again
            # without reporting again.
            if want in QUIET_STATES or (self.raw_target and want == self.raw_target):
                ag.settled = True
            return
        ag.reported = want
        ag.last_reported = want
        if want in QUIET_STATES or (self.raw_target and want == self.raw_target):
            # Raw mode: a target report ends wait (settled=True).
            # max_events=1 in the adapter would do the same; both together
            # are harmless.
            ag.settled = True
        self._report(ag.name, want)

    def _unlock(self, ag, klass):
        """Clear the report lock as soon as the agent has left the reported
        state — otherwise a SECOND completion stays silent (T20)."""
        if ag.reported and status_class(ag.reported) != klass:
            ag.reported = ""

    def _want(self, ag, status):
        """What is worth reporting?"""
        if self.raw_target:
            # wait --status: only the raw hit plus the always-hits.
            # working as all-clear does NOT count here (wait waits for a
            # state, not for "running again"). blocked unequal to the target
            # stays silent — heuristic bypassed (T5).
            if status in ("stalled", "lost", "unknown"):
                return status
            if status == self.raw_target:
                return status
            return ""
        if status in ACTION_STATES or status == "lost":
            return status
        if status in QUIET_STATES:
            # The quiet window has already been traversed at this point.
            return status
        if status == "working":
            # ONLY as all-clear after an action state ("dialog
            # answered, running again"). Otherwise every start of work would be a
            # notification — noise that covers the relevant events
            # (invariant 2).
            return "working" if ag.last_reported in ACTION_STATES else ""
        # A status the contract does not know is NOT reported — as in
        # herd.sh, whose case branches cover exactly the above cases. The
        # event enum (idle|working|blocked|done|unknown) does not allow this case
        # anyway.
        return ""

    # -- Internals: ticks, windows, verification, stall ----------------------

    def _tick_all(self, now):
        # 1. Deadlines of the open commands — FIRST, so that an expired
        #    order can be retried in the same tick.
        for rid in sorted(self._inflight):
            req = self._inflight.get(rid)
            if req is None or now < req.deadline:
                continue
            ag = self._agents.get(req.name)
            if ag is None or ag.lost:
                self._inflight.pop(rid, None)
                continue
            self._command_failed(now, ag, req, rid,
                                 "no answer within %gs" % self.cmd_timeout_sec)
        if self.monitor_down:
            # During an outage commands are pointless: classify-pane and
            # stall-fingerprint go through the same daemon that is currently not
            # answering. The clocks stand still and are reset at
            # monitor-restored.
            return
        for ag in self._agents.values():
            self._tick_agent(now, ag)

    def _tick_agent(self, now, ag):
        if ag.lost:
            return
        # 2. Quiet window: end of the window or due retry.
        # Raw mode: no window, no classify — the stall clock (working)
        # runs anyway, fingerprint as before.
        slot = ag.slots[PURPOSE_DEBOUNCE]
        if not self.raw_target and ag.pending and slot.request_id is None:
            due = ag.pending_until if slot.tries == 0 else slot.retry_at
            if now >= due:
                # End of the window: NOW the dialog cross-check. That is the
                # natural place for it (plan, design decision 2, trigger 1)
                # — a raw idle/done becomes blocked/limited/auth/failed only
                # through the classification, and herdr knows none of these states.
                ag.phase = _PHASE_AWAIT
                self._issue(now, ag, CMD_CLASSIFY, PURPOSE_DEBOUNCE)
        # 3. Cross-check retry after a failure.
        gone = ag.slots[PURPOSE_GONE]
        if gone.tries and gone.request_id is None and now >= gone.retry_at:
            self._issue(now, ag, CMD_AGENT_GET, PURPOSE_GONE)
        # 4. Verification rest poll: the ONE clock for stalled AND
        #    classification. It is oriented to the RAW status (not to the
        #    last reported synthetic state) and keeps running unchanged after
        #    synthetic reports — only this way is recovery
        #    recognized at all.
        if not ag.raw or now < ag.verify_due:
            return
        ag.verify_due = now + self.verify_interval_sec
        verify = ag.slots[PURPOSE_VERIFY]
        if verify.request_id is not None:
            # Still open — do not push anything after it; the deadline clears it.
            return
        if ag.raw == "working":
            # Fingerprint plus limited and failed check: backends with
            # self-retry stay permanently working at the limit; a
            # model error at raw working would stay invisible without this verify
            # order. Also in raw mode: stalled is an always-hit,
            # the stall clock must keep running.
            self._issue(now, ag, CMD_FINGERPRINT, PURPOSE_VERIFY)
        elif self.raw_target:
            return
        elif slot.request_id is None:
            # If a classification from the quiet window is already outstanding,
            # a second order would be just duplicated work — the clock keeps
            # running anyway. Also a running window (pending set, no request yet)
            # takes over the classification; verify must not
            # fire into it (busy re-arms the window without a generation change).
            if ag.pending:
                return
            self._issue(now, ag, CMD_CLASSIFY, PURPOSE_VERIFY)

    def _classified(self, now, request_id, verdict):
        ag, req = self._resolve(request_id, CMD_CLASSIFY)
        if ag is None:
            return
        if verdict not in VALID_VERDICTS:
            self._command_failed(now, ag, req, request_id,
                                 "ungueltiges Klassifizierungsergebnis %r" % (verdict,))
            return
        self._close(request_id, ag, req.purpose)
        if self.raw_target:
            # Raw mode orders no classify; a late answer must
            # not apply the heuristic retroactively.
            if req.purpose == PURPOSE_DEBOUNCE:
                ag.phase = _PHASE_NONE
                ag.pending = ""
            return
        if not ag.raw:
            if req.purpose == PURPOSE_DEBOUNCE:
                ag.phase = _PHASE_NONE
                ag.pending = ""
            return
        # Raw blocked + muse: the pane cross-check decides between a real
        # dialog (blocked) and the internal reviewer (busy -> working).
        if ag.raw == "blocked" and ag.kind == "muse":
            self._blocked_classified(now, ag, req, verdict)
            return
        # Late verify during a (re-armed) window: do not apply clean
        # as idle/done. busy stays synthetic working
        # (otherwise settled=True and "all done" despite a valid busy finding).
        # Action states take effect immediately, they are not "done".
        background = verdict == VERDICT_BACKGROUND
        if req.purpose == PURPOSE_VERIFY and ag.pending:
            if verdict in VERDICTS:
                self._apply(now, ag, normalize_status(ag.raw, verdict))
            elif verdict == VERDICT_BUSY or background:
                self._on_busy(now, ag, PURPOSE_VERIFY, background)
            return
        if (verdict == VERDICT_BUSY or background) and ag.raw in QUIET_STATES:
            self._on_busy(now, ag, req.purpose, background)
            return
        if req.purpose == PURPOSE_DEBOUNCE:
            ag.phase = _PHASE_NONE
            ag.pending = ""
        self._apply(now, ag, normalize_status(ag.raw, verdict))

    def _on_busy(self, now, ag, purpose, background=False):
        """Busy: idle/done is not finished yet. busy itself is NOT
        reported (no reportable state) but treated as synthetic working.
        Origin: agy 2026-08-31 / grok 2026-09-02, herdr idle
        during generation or background task.

        debounce: re-arm the quiet window until clean or action state;
        cap busy_max_sec from the first busy of this cycle → once unknown.
        verify: no re-arming, only _apply(working); the rest-poll clock
        repeats. The report lock of the idle class stays (no raw change).

        background (claude, only background tasks): own, shorter cap
        bg_max_sec, `background` is reported instead of unknown. After that
        the verify poll also holds `background` (no flapping via working)."""
        if background and ag.busy_capped:
            self._apply(now, ag, "background")
            return
        if purpose == PURPOSE_VERIFY:
            self._apply(now, ag, "working", unlock=False)
            return
        if ag.busy_since <= 0.0:
            ag.busy_since = now
        cap = self.bg_max_sec if background else self.busy_max_sec
        if cap > 0 and (now - ag.busy_since) >= cap:
            ag.phase = _PHASE_NONE
            ag.pending = ""
            if not ag.busy_capped:
                ag.busy_capped = True
                self._apply(now, ag, "background" if background else "unknown")
            return
        ag.phase = _PHASE_WINDOW
        ag.pending = ag.raw
        ag.pending_until = now + self.debounce_sec
        ag.slots[PURPOSE_DEBOUNCE].reset()
        self._apply(now, ag, "working", unlock=False)

    def _blocked_classified(self, now, ag, req, verdict):
        """Verdict for a raw `blocked` of kind muse (muse 1.3.0).

        Dialog (blocked) or quiet pane (clean) -> blocked: herdr keeps the
        authority, unknown dialog formats are not hidden.
        limited/auth/failed -> that state. busy -> like synthetic working
        (no report), with the same cap rule as in the idle path."""
        if req.purpose == PURPOSE_DEBOUNCE:
            ag.phase = _PHASE_NONE
            ag.pending = ""
        if verdict == VERDICT_BUSY:
            self._on_blocked_busy(now, ag)
            return
        if verdict in VERDICTS:
            self._apply(now, ag, verdict)
            return
        self._apply(now, ag, "blocked")

    def _on_blocked_busy(self, now, ag):
        """busy on raw blocked (muse reviewer): synthetic working plus
        the same cap rule as in the idle path. The quiet window is re-armed
        so that the cross-check is repeated as long as herdr reports blocked; from
        busy_max_sec, unknown is reported ONCE (no silent lingering)."""
        if ag.busy_since <= 0.0:
            ag.busy_since = now
        if self.busy_max_sec > 0 and (now - ag.busy_since) >= self.busy_max_sec:
            ag.phase = _PHASE_NONE
            ag.pending = ""
            if not ag.busy_capped:
                ag.busy_capped = True
                self._apply(now, ag, "unknown")
            return
        ag.phase = _PHASE_WINDOW
        ag.pending = ag.raw
        ag.pending_until = now + self.debounce_sec
        ag.slots[PURPOSE_DEBOUNCE].reset()
        self._apply(now, ag, "working", unlock=False)

    def _fingerprinted(self, now, request_id, fingerprint, limited, failed):
        ag, req = self._resolve(request_id, CMD_FINGERPRINT)
        if ag is None:
            return
        if not isinstance(fingerprint, str) or not fingerprint.strip():
            self._command_failed(now, ag, req, request_id,
                                 "fingerprint missing (pane not readable)")
            return
        if limited is not True and limited is not False:
            self._command_failed(now, ag, req, request_id,
                                 "limited is not a boolean (%r)" % (limited,))
            return
        if failed is not True and failed is not False:
            self._command_failed(now, ag, req, request_id,
                                 "failed is not a boolean (%r)" % (failed,))
            return
        self._close(request_id, ag, req.purpose)
        if ag.raw != "working":
            # Cannot occur after the generation check (leaving
            # working raises the generation) — checked defensively anyway,
            # because stall clock and limited/failed correction apply ONLY to working.
            return
        if self.stall_timeout_sec > 0:
            if fingerprint != ag.fp:
                # Real progress in the pane — THAT is the only valid
                # recovery besides leaving working.
                ag.fp = fingerprint
                ag.fp_since = now
                ag.stalled = False
            elif now - ag.fp_since >= self.stall_timeout_sec:
                ag.stalled = True
        # Order as in herd.sh: first normalize_status (working →
        # limited, otherwise failed), then the stall latch, which wins at the end
        # (in _apply). limited before failed as in classify_text. Raw mode:
        # no pane correction, stall latch stays.
        if self.raw_target:
            self._apply(now, ag, "working")
        elif limited:
            self._apply(now, ag, normalize_status("working", "limited"))
        elif failed:
            self._apply(now, ag, normalize_status("working", "failed"))
        else:
            self._apply(now, ag, normalize_status("working", VERDICT_CLEAN))

    def _agent_get(self, now, request_id, present, raw_status):
        ag, req = self._resolve(request_id, CMD_AGENT_GET)
        if ag is None:
            return
        if present is not True and present is not False:
            self._command_failed(now, ag, req, request_id,
                                 "present is not a boolean (%r)" % (present,))
            return
        self._close(request_id, ag, req.purpose)
        if not present:
            self._gone_confirmed(now, ag)
            return
        if raw_status:
            self._observe(now, ag.name, raw_status)

    # -- Internals: lost, global, resync -------------------------------------

    def _pane_gone(self, now, name):
        ag = self._agent(name)
        if ag is None:
            return
        if ag.slots[PURPOSE_GONE].busy:
            # Duplicates create NO second cross-check — and a pending
            # retry is not reset by them.
            return
        self._issue(now, ag, CMD_AGENT_GET, PURPOSE_GONE)

    def _gone_confirmed(self, now, ag):
        ag.lost = True
        ag.phase = _PHASE_NONE
        ag.pending = ""
        ag.stalled = False
        self._bump(ag)     # discard open commands of a lost agent
        # lost is terminal (invariant 3) — but nevertheless an EVENT and must
        # not fall silently under the table (T8). The report lock is maintained by _apply;
        # a second lost thus stays silent.
        self._apply(now, ag, "lost")

    def _monitor(self, now, restored):
        if restored:
            if not self.monitor_down:
                return
            self.monitor_down = False
            for ag in self._agents.values():
                # Reset the clocks: they stood still during the outage, and a
                # long outage must not trigger a burst of
                # orders on rebuild. The state is delivered by the resync anyway,
                # which follows immediately.
                ag.verify_due = now + self.verify_interval_sec
                if ag.pending:
                    # The quiet window starts anew; its classify was
                    # invalidated during the outage and is re-armed afterwards. Without that
                    # the agent would stay in _PHASE_AWAIT forever.
                    ag.phase = _PHASE_WINDOW
                    ag.pending_until = now + self.debounce_sec
            self._report(GLOBAL, "monitor-restored")
            return
        if self.monitor_down:
            # Only ONE report per outage — the reconnect loop keeps trying
            # with backoff.
            return
        self.monitor_down = True
        for ag in self._agents.values():
            # Open commands go to the same daemon: they will never be
            # answered. Without this invalidation a single
            # outage could permanently prevent a completion or lost report.
            self._bump(ag)
        self._report(GLOBAL, "monitor-unavailable")

    def _resync(self, now, snapshots, gaps, first, kinds=None):
        gaps = set(gaps or ())
        kinds = kinds or {}
        for name in self.names:
            ag = self._agents.get(name)
            if ag is None or ag.lost:
                continue
            if name in kinds:
                new_kind = kinds[name]
                if new_kind != ag.kind:
                    # Kind change = generation change: open commands were
                    # issued under the old kind assumption.
                    ag.kind = new_kind
                    self._bump(ag)
            if name in gaps:
                # Generation change: state_change_seq has jumped or the
                # pane_id has changed. That establishes that the agent changed
                # its state — even if it looks the same before and after
                # (complete brief in the subscribe/reconnect
                # gap). The report lock must go, otherwise this
                # completion stays silent (T29); open commands now describe
                # an outdated state or a dead pane.
                ag.reported = ""
                self._bump(ag)
            if name not in snapshots:
                continue
            raw = snapshots[name]
            if raw is None:
                if first:
                    # not_found BEFORE the start = input error, exit 1 at the caller.
                    continue
                self._gone_confirmed(now, ag)
                continue
            self._observe(now, name, raw)

    # -- Insight for tests and diagnosis -------------------------------------

    def state_of(self, name):
        """Compact view of the internal state of an agent (diagnosis and
        tests) — deliberately read-only as a dict so that nobody depends on it."""
        ag = self._agents[name]
        return {"raw": ag.raw, "reported": ag.reported,
                "last_reported": ag.last_reported, "phase": ag.phase,
                "pending": ag.pending, "settled": ag.settled, "lost": ag.lost,
                "stalled": ag.stalled, "gen": ag.gen, "kind": ag.kind,
                "busy_since": ag.busy_since, "busy_capped": ag.busy_capped,
                "open": dict((p, ag.slots[p].request_id) for p in PURPOSES),
                "tries": dict((p, ag.slots[p].tries) for p in PURPOSES)}

    def inflight(self):
        """Open commands as {request_id: (name, kind, purpose, generation)}."""
        return dict((rid, (r.name, r.kind, r.purpose, r.generation))
                    for rid, r in self._inflight.items())
