#!/usr/bin/env python3
# herd_events.py — event-based observation of herdr agents from the
# EVENT stream (backend for `herd.sh wait` and `watch`).
#
# STATUS: Step D. It contains transport, RPC, event stream, the timed
# main loop, reconnect/backoff, liveness ping, the resync sequence (Step A), the
# ADAPTER that wires all of this with the report rules from herd_state.py (Step B)
# into the watch contract, and the feature detection for the
# API availability check in herd.sh (exit 2 without API):
#
#   herd_events.py watch <name…> [--stall-timeout MIN] [--timeout MIN]
#                                [--poll SEC] [--max-events N]
#                                            # the watch contract: stdout one
#                                            # line "<name> <status>" per
#                                            # event, stderr the
#                                            # action instruction, exit 0/1/2/124
#   herd_events.py wait <name> [--timeout MIN] [--stall-timeout MIN]
#                              [--poll SEC] [--status X]
#                                            # the wait contract: stdout EXACTLY
#                                            # one line (only the state, no
#                                            # name), stderr the instruction,
#                                            # exit 0/1/2/124. Runs over
#                                            # the same session as watch
#                                            # (max_events=1, output "bare").
#   herd_events.py probe                     # is the event API USABLE?
#                                            # exit 0 = yes, 2 = no (reason on
#                                            # stderr). herd.sh wait/watch
#                                            # end hard at exit 2.
#   herd_events.py ping                      # reachability: "ok" + exit 0
#   herd_events.py stream <name…> [--max-lines N] [--timeout SEC]
#                                            # smoke: delivered events as
#                                            # RAW LINE, plus the global
#                                            # "* monitor-unavailable"/"-restored"
#
# ping and stream are diagnostic verbs and NO part of the herd.sh contract (their
# --timeout counts in SECONDS; `watch` counts in MINUTES like herd.sh).
# `probe` is the interface to the dispatcher: `herd.sh wait`/`watch` call
# it once per run (result deliberately NOT cached — the daemon can
# change between two runs) and delegate only at exit 0 via exec.
#
# WHO OWNS WHAT (the division of labor of the adapter, see WatchMonitor):
#   herd_state.StateMachine  ALL report rules and ALL clocks of the observation:
#                            report lock, quiet window, all-clear, stall latch,
#                            terminal end, --max-events, --timeout (exit 124)
#                            and the global monitor-unavailable/-restored.
#   Monitor (here)           ONLY transport and delivery: stream, reconnect,
#                            liveness, resync snapshots, filter on foreign panes.
#                            It reports NOTHING on its own — it calls hooks.
#   WatchMonitor (here)      the adapter: hooks -> StateMachine inputs,
#                            commands -> herd.sh verbs or agent.get,
#                            outcome -> stdout/stderr/exit.
# The former double ownerships are thus resolved: the monitor no longer emits the
# global reports itself (handle_stream_down/-up are hooks, the
# default applies only to the smoke verb `stream`) and holds for the
# watch path NO own deadline and no output limit.
#
# Exit codes: 0 = regular end · 1 = agent unknown (never seen) ·
#   2 = usage error OR event API not available/rejected · 124 = time limit
#   of the OBSERVATION (the agents keep running).
#
# Protocol (verified 2026-07-28 against `herdr api schema --json`, herdr
# 0.7.5-preview, protocol 17):
#   Request   {"id":"<str>","method":"…","params":{…}}
#   Answer    {"id":"<str>","result":{"type":…,…}} | {"id":…,"error":{"code","message"}}
#   Event     {"event":"<kind>","data":{…}}
#   ping → result.type "pong"; agent.get params {"target":"<name>"} →
#   result.agent with pane_id/agent_status/state_change_seq; events.subscribe
#   params {"subscriptions":[{"type":"pane.agent_status_changed","pane_id":…},
#   {"type":"pane.closed"},…]} → result.type "subscription_started".
#
# Environment:
#   HERD_EVENTS_ENDPOINT      tcp:host:port | unix:/path | pipe:\\.\pipe\…
#                             (takes precedence; tcp ONLY for tests)
#   HERDR_SOCKET_PATH         set by herdr in every pane — the source for
#                             the automatic resolution
#   HERD_EVENTS_TICK_SEC      tick of the main loop (default 0.5)
#   HERD_EVENTS_LIVENESS_SEC  silent stream → ping as a sign of life (default 60)
#   HERD_EVENTS_RPC_TIMEOUT_SEC          (default 10)
#   HERD_EVENTS_BACKOFF_SEC / _MAX_SEC   reconnect backoff (default 0.5 / 5)
#   only for `watch`/`wait`:
#   HERD_EVENTS_DEBOUNCE_SEC   quiet window for idle/done (default 4, see
#                              herd_state.py)
#   HERD_EVENTS_VERIFY_SEC     verification rest poll per agent; without a value
#                              --poll * 15 (so ~30 s at --poll 2)
#   HERD_EVENTS_CMD_TIMEOUT_SEC / _CMD_RETRY_SEC   deadline and retry interval
#                              of a command; without a value derived from the
#                              verification interval (clearly below it)
#   HERD_STALL_UNIT            seconds per --stall-timeout unit (default 60,
#                              the same test convention as in herd.sh)
#   HERD_EVENTS_MINUTE_SEC     seconds per --timeout minute (default 60; ONLY
#                              so the tests can check the time limit without real
#                              minutes, like HERD_STALL_UNIT)
#   HERD_SH / HERD_BASH        path to herd.sh or to bash (default:
#                              neighboring file / "bash") — the tests plug in
#                              a stub here to check adapter errors
#   HERD_NOTIFY                "1" = for every emitted action line
#                              additionally `herdr notification show`
#                              (fire-and-forget, see WatchMonitor._notify);
#                              any other/missing value: bit-identical as before

import itertools
import json
import os
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import namedtuple

# No __pycache__ next to the scripts: otherwise the import of herd_state would
# create a directory in EVERY working tree in which watch runs — and the repo
# has no .gitignore. The saved milliseconds are meaningless anyway against an
# observer that runs for minutes.
sys.dont_write_bytecode = True

try:
    import herd_state
except ImportError:                                       # pragma: no cover
    # When called as a script, scripts/ is in sys.path anyway; this branch
    # only applies when the module is imported from another directory.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import herd_state

EXIT_OK = 0
EXIT_NOT_FOUND = 1
EXIT_USAGE = 2          # usage error AND "event API not available"
EXIT_TIMEOUT = 124


# --- Configuration -----------------------------------------------------------

def _env_float(name, default):
    """Positive number from the environment; nonsense silently falls back to
    the default — a broken env must not prevent the observation."""
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        val = float(raw)
    except ValueError:
        return default
    return val if val > 0 else default


TICK_SEC = _env_float("HERD_EVENTS_TICK_SEC", 0.5)
LIVENESS_SEC = _env_float("HERD_EVENTS_LIVENESS_SEC", 60.0)
RPC_TIMEOUT_SEC = _env_float("HERD_EVENTS_RPC_TIMEOUT_SEC", 10.0)
BACKOFF_SEC = _env_float("HERD_EVENTS_BACKOFF_SEC", 0.5)
BACKOFF_MAX_SEC = _env_float("HERD_EVENTS_BACKOFF_MAX_SEC", 5.0)
# Verification rest poll: fingerprint every 15 ticks (at --poll 2 thus ~30 s).
# The factor depends on --poll, the quiet window deliberately does not (own size,
# plan decision 1).
VERIFY_TICKS = 15
# Seconds per --stall-timeout unit. In production 60 (the option is in minutes);
# the tests lower it (HERD_STALL_UNIT).
STALL_UNIT_SEC = _env_float("HERD_STALL_UNIT", 60.0)
# Seconds per --timeout minute. Same reasoning as above: a time-limit test
# must not take a real minute.
MINUTE_SEC = _env_float("HERD_EVENTS_MINUTE_SEC", 60.0)
# HERD_NOTIFY=1: every ACTUALLY emitted action line of watch/wait
# additionally gets a herdr notification (see WatchMonitor._notify).
# Deliberately only the exact value "1": anything else leaves the behavior
# bit-identical to without the switch.
NOTIFY_ENABLED = os.environ.get("HERD_NOTIFY") == "1"
# States that call the human to the screen — the same selection as the
# action lines of the watch table in SKILL.md §7 States and exit codes. idle/done (result), working
# (all-clear) and monitor-restored are deliberately NOT included; stalled/unknown/
# lost are, because they demand "check yourself". `monitor-unavailable`
# as the only GLOBAL state carries its own title (see _notify).
NOTIFY_STATES = frozenset(("blocked", "question", "limited", "auth", "failed",
                           "stalled", "unknown", "lost", "background"))

# The internal herd.sh verbs (classify-pane/stall-fingerprint/explain-status)
# are the SINGLE SOURCE of the pane heuristics and report texts. Always call
# via `bash <script>`: on Windows the .sh is not directly executable, and
# a second code path only for POSIX would be one more source of error.
HERD_SH = (os.environ.get("HERD_SH")
           or os.path.join(os.path.dirname(os.path.abspath(__file__)), "herd.sh"))
BASH = os.environ.get("HERD_BASH") or "bash"
# Own, SHORT deadline for explain-status: it is pure accessory output (the
# report line on stdout is the message) and runs in its own thread —
# a long deadline would only pile up the explanations.
EXPLAIN_TIMEOUT_SEC = _env_float("HERD_EVENTS_EXPLAIN_TIMEOUT_SEC", 5.0)

VerbResult = namedtuple("VerbResult", "code out err")


def run_verb(args, timeout):
    """Execute an internal herd.sh verb and return (exit code, stdout, stderr).

    Outputs go into FILES, not pipes. Reason: if the deadline expires,
    subprocess.run must still drain the pipes after the kill — and a GRANDCHILD
    PROCESS (bash starts e.g. sleep) keeps their write ends open. The cleanup
    would then hang as long as the grandchild, and the deadline would be
    ineffective. Files do not block. Always via `bash <script>`: on Windows the .sh
    is not directly executable, and a second code path only for POSIX would be
    one more source of error."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        proc = subprocess.run([BASH, HERD_SH] + list(args), stdout=out, stderr=err,
                              timeout=timeout)
        out.seek(0)
        err.seek(0)
        return VerbResult(proc.returncode,
                          out.read().decode("utf-8", "replace"),
                          err.read().decode("utf-8", "replace"))

# How often discovery→subscribe→control snapshot is repeated with a changing
# pane_id (see Monitor._resync). Three attempts covered every pane rebuild
# observed in practice; after that it is a finding, not a loop.
RESYNC_MAX_ATTEMPTS = 3

# Subscription events carry the DOT name (SubscriptionEventKind:
# "pane.agent_status_changed"), global events the UNDERSCORE name (EventKind:
# "pane_closed") — both in the same envelope {"event":…,"data":…}. Whoever knows
# only one of the two spellings silently loses half of the stream.
STATUS_EVENTS = frozenset(("pane.agent_status_changed", "pane_agent_status_changed"))
GONE_EVENTS = frozenset(("pane.closed", "pane_closed", "pane.exited", "pane_exited"))
# Known, but (so far) without a report rule. Without this list the burst of
# pane_created right after subscription_started (observed 2026-07-28) would be
# diagnosed as "unknown event type" — noise without insight value.
QUIET_EVENTS = frozenset((
    "pane.created", "pane_created", "pane.updated", "pane_updated",
    "pane.output_changed", "pane_output_changed", "pane.focused", "pane_focused",
    "pane.scroll_changed", "pane_scroll_changed",
    "pane.agent_detected", "pane_agent_detected",
))
KNOWN_EVENTS = STATUS_EVENTS | GONE_EVENTS | QUIET_EVENTS


# --- Error classes -----------------------------------------------------------

class UsageError(Exception):
    """Usage error → exit 2."""


class TransportError(Exception):
    """IPC broken/gone. For the observation this means monitor-unavailable —
    explicitly NO statement about the state of the agents."""


class RpcTimeout(TransportError):
    pass


class RpcError(Exception):
    """The daemon ANSWERS but rejects (e.g. agent_not_found)."""

    def __init__(self, code, message):
        Exception.__init__(self, "%s: %s" % (code, message))
        self.code = code or ""
        self.message = message or ""


class CommandFailed(Exception):
    """A command of the adapter (internal herd.sh verb) did not get through:
    exit code != 0, unexpected output, verb not callable. For the
    StateMachine this is `on_command_failed` — explicitly NO result and
    certainly not `clean`."""


class AgentNotFound(Exception):
    """Names that were NEVER seen → exit 1 (input error)."""

    def __init__(self, names):
        Exception.__init__(self, ", ".join(names))
        self.names = list(names)


class _Done(Exception):
    """Internal: output limit reached (--max-lines)."""


# --- Transport ---------------------------------------------------------------

Endpoint = namedtuple("Endpoint", "kind target label")


def default_socket_path():
    """Fallback when HERDR_SOCKET_PATH is missing (i.e. outside a pane)."""
    if os.name == "nt":
        base = os.environ.get("APPDATA") or os.path.expanduser(r"~\AppData\Roaming")
        return os.path.join(base, "herdr", "herdr.sock")
    # Verified 2026-07-29 (Linux, herdr 0.7.5): the daemon listens on
    # ~/.config/herdr/herdr.sock — NOT under XDG_RUNTIME_DIR. The
    # reliable way remains HERDR_SOCKET_PATH, which herdr sets in every pane.
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "herdr", "herdr.sock")


def _parse_endpoint(spec):
    if spec.startswith("tcp:"):
        host, sep, port = spec[4:].rpartition(":")
        if not sep or not port.isdigit():
            raise UsageError("HERD_EVENTS_ENDPOINT: tcp requires host:port (%s)" % spec)
        return Endpoint("tcp", (host or "127.0.0.1", int(port)), spec)
    if spec.startswith("unix:"):
        return Endpoint("unix", spec[5:], spec)
    if spec.startswith("pipe:"):
        return Endpoint("pipe", spec[5:], spec)
    raise UsageError("HERD_EVENTS_ENDPOINT: expected tcp:… | unix:… | pipe:… (%s)" % spec)


def resolve_endpoint(env=None):
    """HERD_EVENTS_ENDPOINT takes precedence, otherwise convention from the .sock path."""
    env = os.environ if env is None else env
    spec = (env.get("HERD_EVENTS_ENDPOINT") or "").strip()
    if spec:
        return _parse_endpoint(spec)
    path = (env.get("HERDR_SOCKET_PATH") or "").strip() or default_socket_path()
    if os.name == "nt":
        # On Windows the .sock file is only a 25-byte marker file
        # "<PID>:<start timestamp>". The real IPC is a named pipe whose
        # NAME is the full .sock path (verified 2026-07-28).
        return Endpoint("pipe", r"\\.\pipe\%s" % os.path.normpath(path),
                        "pipe:" + path)
    return Endpoint("unix", path, "unix:" + path)


class _Conn:
    """NDJSON lines over a raw byte source."""

    # Does close() of this transport block while a read is pending?
    # On Windows named pipes YES (see _PipeConn) — and that was the reason why
    # the observer did not terminate with a silent stream (E2E Step D,
    # scenarios b/c). A caller of close() therefore does so via close_conn().
    blocking_close = False

    def __init__(self):
        self._buf = b""
        self._eof = False

    def read_line(self, timeout=None):
        """Next line without the line ending as str; None at EOF.
        timeout=None blocks (this is how the reader thread reads), otherwise RpcTimeout."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                return line.rstrip(b"\r").decode("utf-8", "replace")
            if self._eof:
                rest, self._buf = self._buf.strip(), b""
                if not rest:
                    return None
                return rest.rstrip(b"\r").decode("utf-8", "replace")
            budget = None
            if deadline is not None:
                budget = deadline - time.monotonic()
                if budget <= 0:
                    raise RpcTimeout("no reply within the time window")
            chunk = self._recv(budget)
            if chunk:
                self._buf += chunk
            else:
                self._eof = True

    def _recv(self, timeout):
        raise NotImplementedError

    def write_line(self, text):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


class _SocketConn(_Conn):
    """AF_UNIX (Linux/macOS) and AF_INET (tests only)."""

    def __init__(self, sock):
        _Conn.__init__(self)
        self._sock = sock

    def _recv(self, timeout):
        try:
            self._sock.settimeout(timeout)
            return self._sock.recv(65536)
        except socket.timeout:
            raise RpcTimeout("no reply within the time window")
        except OSError as exc:
            raise TransportError(str(exc))

    def write_line(self, text):
        try:
            self._sock.sendall(text.encode("utf-8") + b"\n")
        except OSError as exc:
            raise TransportError(str(exc))

    def close(self):
        # shutdown() BEFORE close(): on Linux a recv() blocked in the reader thread
        # keeps the file description open in the kernel — close()
        # alone then sends NO FIN, the server never sees the connection end
        # and the discarded stream lives on server-side (T49).
        # shutdown() wakes the blocked recv() (EOF) and sends the FIN
        # immediately. Windows TCP aborts recv() already at close(), which is why
        # this was invisible in the Windows test suite.
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


class _PipeConn(_Conn):
    """Windows named pipe. open(…, 'r+b', buffering=0) suffices — BUT: on
    the same handle a second write AFTER a read fails in the CRT with
    EINVAL. Therefore a fresh connection per RPC, and the event stream
    writes exactly once (subscribe)."""

    # SECOND Windows trap (E2E Step D, MAJOR): `close()` of a Python io object
    # takes its internal lock — and a currently running,
    # BLOCKING read() holds it. On a named pipe this read returns only
    # when data arrives. So a caller that closes from the main thread while the
    # reader thread listens waits for the next event line — on a regular
    # program end this meant: exit code and output are fixed, the process lives
    # on anyway (reproduced three times, up to three minutes). Over TCP this
    # does not exist: socket.close() takes no io lock, which is why it was
    # invisible in the entire TCP test suite.
    blocking_close = True

    def __init__(self, name):
        _Conn.__init__(self)
        try:
            self._fh = open(name, "r+b", buffering=0)
        except OSError as exc:
            raise TransportError("%s: %s" % (name, exc))

    def _read_raw(self):
        try:
            return self._fh.read(65536) or b""
        except OSError as exc:
            raise TransportError(str(exc))

    def _recv(self, timeout):
        if timeout is None:
            return self._read_raw()
        # Named pipes have no read timeout in the stdlib. The blocking
        # read therefore runs in a helper thread; if the time expires, the
        # CONNECTION counts as lost (otherwise the thread keeps hanging on the handle).
        # Harmless for RPC because there a fresh connection is made per request anyway.
        box = queue.Queue(1)

        def _pump():
            try:
                box.put(("data", self._read_raw()))
            except Exception as exc:                      # noqa: BLE001
                box.put(("err", exc))

        threading.Thread(target=_pump, daemon=True).start()
        try:
            kind, val = box.get(timeout=timeout)
        except queue.Empty:
            raise RpcTimeout("no reply within the time window (named pipe)")
        if kind == "err":
            raise val
        return val

    def write_line(self, text):
        try:
            self._fh.write(text.encode("utf-8") + b"\n")
        except OSError as exc:
            raise TransportError(str(exc))

    def close(self):
        try:
            self._fh.close()
        except OSError:
            pass


def connect(endpoint, timeout=None):
    timeout = timeout or RPC_TIMEOUT_SEC
    if endpoint.kind == "tcp":
        try:
            return _SocketConn(socket.create_connection(endpoint.target, timeout))
        except OSError as exc:
            raise TransportError("%s: %s" % (endpoint.label, exc))
    if endpoint.kind == "unix":
        if not hasattr(socket, "AF_UNIX"):
            raise TransportError("AF_UNIX not available on this platform")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            sock.connect(endpoint.target)
        except OSError as exc:
            sock.close()
            raise TransportError("%s: %s" % (endpoint.label, exc))
        return _SocketConn(sock)
    return _PipeConn(endpoint.target)


def close_conn(conn):
    """Close a connection WITHOUT blocking the caller.

    The ONLY way to get rid of a connection — calling `conn.close()` directly
    is a trap on Windows pipes (see _PipeConn.blocking_close): the
    caller hangs there until the next arriving line. Affected were
    ALL four closing sites, not only the program end:
      1. Monitor.run() finally      — the observed hang (E2E b/c),
      2. Monitor._stream_lost()     — liveness ping failed, but the connection
                                      still open: the main loop would freeze
                                      EXACTLY when it should reconnect,
      3. Monitor._publish_stream()/_resync() — discarded candidate,
      4. RpcClient.call() finally   — after an RPC timeout the
                                      _pump helper thread is still in the read.
    The decision is made solely on `blocking_close`, i.e. on the TRANSPORT KIND
    — not on whether a read is currently running: a socket always closes
    synchronously and thus deterministically (T49 builds on that), a pipe ALWAYS in the
    throwaway thread, even when no read is pending. Intent: "is a
    read pending right now?" cannot be reliably determined from outside (the reader thread
    can enter the read between check and close()), and a condition
    that is only mostly true would be the worst kind of arrangement
    in the shutdown path. The price is one thread per pipe close — negligible
    against an observer that runs for minutes.

    Price of this way: with a blocked close, the handle and reader thread stay
    around until the daemon eventually sends a line or the process ends.
    This is deliberately chosen: all threads are daemon threads, the
    process end waits for none of them, and the affected cases
    (reconnect, candidate change) are rare. The alternative — aborting the running
    read via Windows API (CancelIoEx/CancelSynchronousIo through
    ctypes) — would be more precise, but its behavior for SYNCHRONOUS reads is not
    verified; an unverified API trick in the shutdown path is the
    worse trade."""
    if conn is None:
        return
    if not conn.blocking_close:
        conn.close()
        return
    threading.Thread(target=conn.close, daemon=True).start()


# --- RPC ---------------------------------------------------------------------

_ID_SEQ = itertools.count(1)
# Generation counter of the event streams (see EventStream).
_STREAM_SEQ = itertools.count(1)


def _try_json(line):
    try:
        msg = json.loads(line)
    except (ValueError, TypeError):
        return None
    return msg if isinstance(msg, dict) else None


def event_pane(data):
    """pane_id of an event. Some event types carry it directly, others in the
    nested `pane` object. A function so that delivery (monitor) and
    evaluation (adapter) use the same place."""
    pane = data.get("pane_id")
    if pane is None:
        nested = data.get("pane")
        pane = nested.get("pane_id") if isinstance(nested, dict) else None
    return pane


def _remaining(deadline):
    """Remaining time until the deadline — expired means timeout IMMEDIATELY.

    A minimum budget (earlier version: max(0.05, …)) would not be a timeout: whoever
    delivers foreign, unreadable or irrelevant lines without interruption starts
    endlessly new reads with it and the overall timeout would never take effect."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise RpcTimeout("no reply within the time window")
    return left


class RpcClient:
    """One request per connection (CRT trap, see _PipeConn).

    on_open/on_close: the adapter registers the connection so that
    `_cancel_workers` can close the socket and wake a blocked recv
    (agent.get worker)."""

    def __init__(self, endpoint, timeout=None, on_open=None, on_close=None):
        self.endpoint = endpoint
        self.timeout = timeout or RPC_TIMEOUT_SEC
        self.on_open = on_open
        self.on_close = on_close

    def call(self, method, params=None):
        conn = connect(self.endpoint, self.timeout)
        rid = str(next(_ID_SEQ))
        try:
            if self.on_open is not None:
                self.on_open(conn)
            conn.write_line(json.dumps(
                {"id": rid, "method": method, "params": params or {}}))
            deadline = time.monotonic() + self.timeout
            while True:
                line = conn.read_line(_remaining(deadline))
                if line is None:
                    raise TransportError("connection closed before the reply")
                msg = _try_json(line)
                # Skip unreadable data and events on the RPC connection:
                # the daemon may send something other than our
                # answer at any time, that is not an error.
                if msg is None or "event" in msg:
                    continue
                # Demand the EXACT id. Letting through an answer without an id would mean
                # accepting any arbitrary line as our answer — the
                # answer schema explicitly requires the id.
                if msg.get("id") != rid:
                    continue
                if "error" in msg:
                    err = msg["error"] or {}
                    raise RpcError(err.get("code"), err.get("message"))
                if "result" in msg:
                    return msg["result"] or {}
        finally:
            if self.on_close is not None:
                try:
                    self.on_close(conn)
                except Exception:                          # noqa: BLE001
                    pass
            # NOT conn.close(): after an RpcTimeout on a named pipe
            # the _pump helper thread is still in the read and close() waits for
            # its io lock — a timeout would thus become a permanent hang.
            close_conn(conn)

    def ping(self):
        return self.call("ping", {})


AgentSnapshot = namedtuple("AgentSnapshot",
                           "name pane_id status seq workspace_id kind",
                           defaults=["", ""])


def _plausible_space_id(value):
    return bool(value) and value[0] == "w" and value[1:].isalnum()


def own_workspace_id():
    """The same chain as herd.sh: HERD_OWN_WORKSPACE (from the dispatcher),
    otherwise HERDR_WORKSPACE_ID, otherwise the prefix of TAB_ID/PANE_ID.
    Empty/invalid prefixes are skipped."""
    override = (os.environ.get("HERD_OWN_WORKSPACE") or "").strip()
    if _plausible_space_id(override):
        return override
    ws = (os.environ.get("HERDR_WORKSPACE_ID") or "").strip()
    if _plausible_space_id(ws):
        return ws
    for key in ("HERDR_TAB_ID", "HERDR_PANE_ID"):
        raw = (os.environ.get(key) or "").strip()
        if ":" not in raw:
            continue
        pre = raw.split(":", 1)[0]
        if _plausible_space_id(pre):
            return pre
    return ""


def _workspace_of_agent(agent):
    ws = agent.get("workspace_id") or ""
    if ws:
        return ws
    pane = agent.get("pane_id") or ""
    if pane.startswith("w") and ":" in pane:
        pre = pane.split(":", 1)[0]
        if _plausible_space_id(pre):
            return pre
    return ""


def _snap_from_agent(name, agent):
    return AgentSnapshot(name, agent.get("pane_id") or "",
                         agent.get("agent_status") or "unknown",
                         agent.get("state_change_seq"),
                         agent.get("workspace_id") or "",
                         agent.get("agent") or "")


def _agent_in_workspace(rpc, name, ws):
    """Own hit from agent.list. False = checked and not there,
    None = not verifiable (no silent not_found)."""
    try:
        res = rpc.call("agent.list", {})
    except (RpcError, TransportError, OSError, TypeError, ValueError):
        return None
    agents = (res or {}).get("agents")
    if not isinstance(agents, list):
        return None
    for agent in agents:
        if not isinstance(agent, dict):
            continue
        if agent.get("name") == name and (agent.get("workspace_id") or "") == ws:
            return agent
    return False


def snapshot_agents(rpc, names):
    """agent.get per name, space-restricted. Value None = agent currently unknown.

    agent_not_found is a STATE STATEMENT and is returned as None.
    Every other rejection counts as a transport disturbance: we do not know
    the state then, and "not knowing" must never pass as "disappeared".

    agent.get is global. On a name collision across spaces the own
    hit must come from agent.list — otherwise watch subscribes to the foreign pane."""
    own = own_workspace_id()
    out = {}
    for name in names:
        try:
            res = rpc.call("agent.get", {"target": name})
        except RpcError as exc:
            if "not_found" in exc.code:
                out[name] = None
                continue
            raise TransportError("agent.get %s: %s" % (name, exc))
        agent = (res or {}).get("agent") or {}
        snap = _snap_from_agent(name, agent)
        if not own:
            out[name] = snap
            continue
        if _workspace_of_agent(agent) == own:
            out[name] = snap
            continue
        listed = _agent_in_workspace(rpc, name, own)
        if listed is None:
            sys.stderr.write("[herd] workspace membership of '%s' not "
                             "verifiable — not filtering\n" % name)
            out[name] = snap
            continue
        if listed is False:
            out[name] = None
            continue
        out[name] = _snap_from_agent(name, listed)
    return out


# --- Event-Stream ------------------------------------------------------------

class EventStream:
    """Own, long-lived connection with EXACTLY ONE write (events.subscribe);
    afterwards only reading. If the subscription list changes (e.g. a new
    pane_id), the stream is closed and rebuilt with the COMPLETE list
    — a second write on the same handle is not an option.

    Reading happens in a reader thread: on Windows pipes there is no
    select(), and the main loop should schedule its time itself. The thread
    is deliberately dumb — it puts raw lines into the queue; parsing and evaluation
    happen in the main loop.

    Every queue message carries the GENERATION (self.id) of the stream. Without it
    an already discarded stream could mark the just successfully built
    successor as failed: its reader may have enqueued a line or an
    EOF before close() took effect, and the main loop sees the
    entry only afterwards."""

    LINE = "line"
    EOF = "eof"
    ERROR = "error"

    def __init__(self, endpoint, subscriptions, sink, timeout=None):
        self.endpoint = endpoint
        self.subscriptions = subscriptions
        self.sink = sink
        self.timeout = timeout or RPC_TIMEOUT_SEC
        self.id = next(_STREAM_SEQ)
        self._conn = None
        self._thread = None
        self._stop = threading.Event()

    def open(self):
        self._conn = connect(self.endpoint, self.timeout)
        try:
            self._subscribe()
        except BaseException:
            # A failed subscribe used to leave the connection open —
            # the caller (_build_stream) only holds an object without a stream and
            # cannot close it anymore. In the reconnect backoff
            # that would be one corpse per attempt. Here close() is harmless:
            # the reader thread starts only AFTER the subscribe, so no
            # read is pending.
            close_conn(self._conn)
            self._conn = None
            raise
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    def _subscribe(self):
        rid = str(next(_ID_SEQ))
        self._conn.write_line(json.dumps({
            "id": rid, "method": "events.subscribe",
            "params": {"subscriptions": self.subscriptions}}))
        deadline = time.monotonic() + self.timeout
        while True:
            line = self._conn.read_line(_remaining(deadline))
            if line is None:
                raise TransportError("stream closed before the subscribe reply")
            msg = _try_json(line)
            if msg is None or "event" in msg:
                # Events can precede the confirmation. They go IMMEDIATELY
                # into the queue — stage 4 of the resync applies them; discarding
                # them would be exactly the gap the resync is meant to prevent.
                self.sink.put((self.id, self.LINE, line))
                continue
            if msg.get("id") != rid:
                continue
            if "error" in msg:
                err = msg["error"] or {}
                raise RpcError(err.get("code"), err.get("message"))
            # Check STRICTLY: taking any answer with "result" as confirmation
            # would let every protocol deviation through — including the
            # empty placeholder answer of a fake.
            result = msg.get("result")
            if not isinstance(result, dict) or result.get("type") != "subscription_started":
                raise TransportError(
                    "events.subscribe: unexpected reply (%s) — expected "
                    "result.type 'subscription_started'" % (line[:120],))
            return

    def _reader(self):
        try:
            while not self._stop.is_set():
                line = self._conn.read_line(None)
                if line is None:
                    # After close() EOF is the EXPECTED outcome and must not
                    # fake a break.
                    if not self._stop.is_set():
                        self.sink.put((self.id, self.EOF, None))
                    return
                self.sink.put((self.id, self.LINE, line))
        except Exception as exc:                          # noqa: BLE001
            if not self._stop.is_set():
                self.sink.put((self.id, self.ERROR, exc))

    def close(self):
        """Releases the caller IMMEDIATELY (see close_conn). The reader thread is
        a daemon: its `_stop` suppresses an EOF message after
        closing, and nobody waits for its end — neither here nor at
        process end."""
        self._stop.set()
        close_conn(self._conn)


# --- Main loop ---------------------------------------------------------------

ResyncResult = namedtuple("ResyncResult", "baseline control gaps missing first")

# Second kind of queue entry beside the stream lines: results of the commands
# that the adapter executes in worker threads (Step C). They deliberately run
# over the SAME queue — so an answer wakes the main loop immediately instead of
# waiting until the next tick. They carry no stream generation (field 0):
# their correlation is done by the request_id in the StateMachine.
CMD_RESULT = "cmd-result"


class Monitor:
    """Timed event loop.

    The beat comes from queue.get(timeout=TICK) and NOT from arriving
    events: debounce window, verification rest poll, liveness check and
    deadline thus hang on a clock that runs even with a dead-silent stream.

    Step B/C attach to the hooks handle_event/handle_tick/handle_resync/
    handle_stream_down/handle_stream_up/handle_command_result; outputs run
    exclusively via emit() (stdout, flushed line by line, counts against the
    output limit) and note() (stderr).

    The monitor decides NOTHING about reports: `timeout_sec` and
    `max_lines` are the limits of the smoke verb `stream`. The watch path leaves
    both at 0 and leaves deadline, output limit and the global
    reports to the StateMachine (see module head, "WHO OWNS WHAT")."""

    def __init__(self, names, endpoint=None, timeout_sec=0.0, max_lines=0):
        self.names = list(names)
        self.endpoint = endpoint or resolve_endpoint()
        self.rpc = RpcClient(self.endpoint)
        self.sink = queue.Queue()
        self.stream = None
        self.stream_id = 0            # generation of the CURRENT stream
        self.pane_ids = set()
        self.pane_names = {}          # pane_id -> Agentname
        self.snapshots = {}
        self.stream_down = False
        self.backoff = BACKOFF_SEC
        self.next_attempt = 0.0
        self.last_activity = time.monotonic()
        self.lines = 0
        self.max_lines = max_lines
        self.deadline = (time.monotonic() + timeout_sec) if timeout_sec > 0 else None
        # Exit code of a regular end (_Done). The smoke verb knows only the
        # output limit (0); the adapter writes the decision of the
        # StateMachine in here (0 = all-settled/--max-events, 124 = time limit).
        self.exit_code = EXIT_OK
        self._diagnosed = set()

    # -- Output --

    def emit(self, line):
        print(line, flush=True)
        self.lines += 1
        if self.max_lines and self.lines >= self.max_lines:
            raise _Done()

    def note(self, msg):
        print(msg, file=sys.stderr, flush=True)

    def diag(self, klass, msg):
        """ONE diagnostic line per error class and connection. A broken
        stream often delivers its error in every line — unchecked, stderr would
        be unusable, and the monitor output beside it."""
        if klass in self._diagnosed:
            return
        self._diagnosed.add(klass)
        self.note(msg)

    # -- Hooks for Step B/C --

    def handle_event(self, kind, data, raw):
        pass

    def handle_tick(self, now):
        pass

    def handle_resync(self, result):
        pass

    def handle_command_result(self, payload):
        """Result of an adapter command (Step C). The monitor itself issues
        no commands and does not know their content."""

    def handle_stream_down(self, reason):
        """The stream has failed (break, error, failed
        liveness ping). As a HOOK because the global report in the watch path
        belongs to the StateMachine: only it knows the report lock and counts events
        against --max-events (T9/T31). The default is the behavior of the
        smoke verb `stream`."""
        self.emit("* monitor-unavailable")

    def handle_stream_up(self):
        """Stream rebuilt AND resync succeeded (handle_resync already ran).
        Hook for the same reason as handle_stream_down."""
        self.emit("* monitor-restored")

    # -- Flow --

    def run(self):
        try:
            try:
                self._resync(first=True)
            except AgentNotFound as exc:
                self.note("[herd] unknown agents: %s — never seen, no event "
                          "to expect. Check: herd.sh list" % ", ".join(exc.names))
                return EXIT_NOT_FOUND
            except (TransportError, RpcError) as exc:
                # No contact at START is not yet a failed observation
                # but a missing prerequisite — herd.sh wait/watch then end
                # hard with exit 2.
                self.note("[herd] event API not available (%s): %s"
                          % (self.endpoint.label, exc))
                return EXIT_USAGE
            while True:
                now = time.monotonic()
                if self.deadline is not None and now >= self.deadline:
                    self.note("[herd] observation ended by time limit — the "
                              "agents keep RUNNING. Observe again: "
                              "herd.sh watch <name…>")
                    return EXIT_TIMEOUT
                if self.stream_down and now >= self.next_attempt:
                    self._try_reconnect()
                item = None
                try:
                    item = self.sink.get(timeout=self._budget())
                except queue.Empty:
                    pass
                if item is not None:
                    self._consume(item)
                now = time.monotonic()
                self.handle_tick(now)
                self._check_liveness(now)
        except _Done:
            # Regular end: output limit (smoke) or abort decision of the
            # StateMachine (watch). The FIRST resync can already trigger it —
            # an agent that was done before the watch is immediately terminal.
            # Therefore it is inside the try as well.
            return self.exit_code
        finally:
            self.handle_shutdown()
            if self.stream is not None:
                self.stream.close()

    def handle_shutdown(self):
        """Hook after the end: WatchMonitor terminates command workers.
        Default (smoke verb): nothing."""

    def _budget(self):
        """Waiting time until the next due time — never more than one tick so that
        handle_tick reliably gets its turn."""
        now = time.monotonic()
        budget = TICK_SEC
        for when in (self.deadline, self.next_attempt if self.stream_down else None):
            if when is not None:
                budget = min(budget, when - now)
        return max(0.01, budget)

    def _consume(self, item):
        stream_id, kind, payload = item
        if kind == CMD_RESULT:
            # Command result of the adapter: no stream generation, no
            # liveness effect (the answer came over its OWN connection or
            # a subprocess — it proves nothing about the event stream).
            self.handle_command_result(payload)
            return
        if stream_id != self.stream_id:
            # Message of a discarded generation. It must move NOTHING:
            # otherwise a late EOF of the predecessor would report the just-built
            # stream as failed.
            return
        if kind == EventStream.LINE:
            self._dispatch_line(payload)
        elif kind == EventStream.EOF:
            self._stream_lost("peer closed the connection")
        else:
            self._stream_lost(str(payload))

    def _dispatch_line(self, raw):
        """Every field is type-checked BEFORE it is used: formally valid
        JSON with wrong types (data as string, pane as list) may be diagnosed and
        ignored by the error rule — it must not end the whole observer
        with AttributeError/TypeError."""
        msg = _try_json(raw)
        if msg is None:
            self.diag("malformed", "[herd] event stream: unreadable line "
                                   "(no JSON object) — ignored")
            return
        kind = msg.get("event")
        err = msg.get("error")
        if kind is None and isinstance(err, dict):
            # Runtime error of the subscription (since herdr 0.9.2 mainly
            # events_lost: subscriber too far behind). herdr then closes
            # the stream; the gap requires resubscribe + snapshot comparison.
            self._stream_lost("herdr reports %s: %s"
                              % (err.get("code"), err.get("message")))
            return
        if not isinstance(kind, str):
            self.diag("malformed", "[herd] event stream: unreadable line "
                                   "(no event envelope) — ignored")
            return
        data = msg.get("data")
        if not isinstance(data, dict):
            self.diag("malformed", "[herd] event stream: unreadable line "
                                   "(data is not an object) — ignored")
            return
        # From here on the line is a valid event of the daemon and thus a
        # sign of life. Diagnosed garbage is NOT — otherwise a
        # corrupt stream could permanently suppress the liveness ping.
        if kind in QUIET_EVENTS:
            self.last_activity = time.monotonic()
            return
        if kind not in KNOWN_EVENTS:
            self.diag("unknown-type", "[herd] event stream: unknown "
                                      "event type '%s' — ignored" % kind)
            return
        pane = event_pane(data)
        # All event types left here carry pane_id as a
        # REQUIRED FIELD per schema. If it is missing or has the wrong type, the event
        # cannot be assigned to an agent — thus unusable, not merely unfiltered.
        if not isinstance(pane, str) or not pane:
            self.diag("malformed", "[herd] event stream: unreadable line "
                                   "(pane_id missing or not a string) — ignored")
            return
        if self.pane_ids and pane not in self.pane_ids:
            # A foreign pane is normal traffic (pane.closed/exited are subscribed
            # GLOBALLY), but no sign of life FOR US — the liveness deadline
            # keeps running, the ping costs nothing.
            self.diag("foreign-pane", "[herd] event stream: event for "
                                      "foreign pane (%s) — ignored" % pane)
            return
        self.last_activity = time.monotonic()
        self.handle_event(kind, data, raw)

    # -- Break and rebuild --

    def _stream_lost(self, reason):
        if not self.stream_down:
            self.stream_down = True
            self.backoff = BACKOFF_SEC
            self.next_attempt = time.monotonic() + self.backoff
            if self.stream is not None:
                self.stream.close()
                self.stream = None
            self.note("[herd] MONITORING FAILED — the event stream broke "
                      "(%s); the state of ALL agents is unknown until it is "
                      "rebuilt." % reason)
            self.handle_stream_down(reason)
        else:
            self.next_attempt = time.monotonic() + self.backoff

    def _try_reconnect(self):
        try:
            self._resync(first=False)
        except (TransportError, RpcError):
            self.next_attempt = time.monotonic() + self.backoff
            self.backoff = min(self.backoff * 2, BACKOFF_MAX_SEC)
            return
        self.stream_down = False
        self.backoff = BACKOFF_SEC
        self.note("[herd] monitoring available again — state re-synced.")
        self.handle_stream_up()

    # -- Subscribe → Snapshot → Resync --

    def _pane_map(self, snapshots):
        """Name → pane_id ("" = currently unknown). The comparison basis for whether
        the subscription still points to the right panes."""
        return dict((n, (snapshots.get(n).pane_id if snapshots.get(n) else ""))
                    for n in self.names)

    def _resync(self, first):
        """Four-stage (plan, BLOCKER 1) because subscribe needs the pane_id
        that only the discovery provides:

          1. Discovery snapshot (agent.get per name) → pane_id/status/seq,
          2. Subscribe with these pane_ids (+ global pane.closed/exited),
          3. Control snapshot: a seq jump versus 1 is a cycle that was
             lost in the window between 1 and 2,
          4. Apply buffered events.

        Stage 4 is done by the main loop: everything that arrives from the
        subscribe on already lies in the queue. The same sequence runs after every reconnect.

        If the pane_id changes between 1 and 3, the fresh subscription already
        points to a dead pane — then it is discarded and the build is repeated
        with the control snapshot as the new baseline until snapshot and
        subscription map the same panes. The candidate is published only AFTER
        this proof: a stream that kept running after a
        failed control snapshot would deliver events into an observation
        considered failed."""
        baseline = snapshot_agents(self.rpc, self.names)
        if first:
            missing = [n for n in self.names if baseline.get(n) is None]
            if missing:
                raise AgentNotFound(missing)
        gaps = []
        for attempt in range(RESYNC_MAX_ATTEMPTS):
            pane_ids = []
            for name in self.names:
                snap = baseline.get(name)
                if snap and snap.pane_id:
                    pane_ids.append(snap.pane_id)
            candidate = self._build_stream(pane_ids)
            try:
                control = snapshot_agents(self.rpc, self.names)
            except BaseException:
                candidate.close()
                raise
            for name in self.names:
                before, after = baseline.get(name), control.get(name)
                if before is None or after is None or name in gaps:
                    continue
                if before.seq != after.seq or before.pane_id != after.pane_id:
                    gaps.append(name)
                    self.note("[herd] '%s': state change missed in the subscribe "
                              "window (seq %s -> %s)" % (name, before.seq, after.seq))
            if self._pane_map(baseline) == self._pane_map(control):
                self._publish_stream(candidate, pane_ids)
                self.snapshots = control
                self.pane_names = dict((s.pane_id, n) for n, s in control.items()
                                       if s and s.pane_id)
                result = ResyncResult(baseline, control, gaps,
                                      [n for n in self.names if control.get(n) is None],
                                      first)
                self.handle_resync(result)
                return result
            candidate.close()
            baseline = control
        # Upper bound instead of an endless loop: whoever lands here has an agent
        # whose pane is rebuilt every second — that is a finding, not a
        # loop. Treated as a transport disturbance (reconnect with backoff).
        raise TransportError("pane mapping not stable after %d attempts"
                             % RESYNC_MAX_ATTEMPTS)

    def _build_stream(self, pane_ids):
        """Build the candidate stream — do NOT publish it yet."""
        subs = [{"type": "pane.agent_status_changed", "pane_id": pid}
                for pid in pane_ids]
        # pane.closed/exited are global (no pane_id in the subscription schema)
        # and the source for 'lost'.
        subs.append({"type": "pane.closed"})
        subs.append({"type": "pane.exited"})
        stream = EventStream(self.endpoint, subs, self.sink)
        stream.open()
        return stream

    def _publish_stream(self, stream, pane_ids):
        if self.stream is not None:
            self.stream.close()
        self.stream = stream
        self.stream_id = stream.id
        self.pane_ids = set(pane_ids)
        # Error classes apply per CONNECTION: after a rebuild the same
        # diagnosis may appear again (it then describes a new state).
        self._diagnosed = set()
        self.last_activity = time.monotonic()

    def _check_liveness(self, now):
        """A silent stream is no proof of a healthy stream."""
        if self.stream_down or now - self.last_activity < LIVENESS_SEC:
            return
        try:
            self.rpc.ping()
        except (TransportError, RpcError) as exc:
            self._stream_lost("liveness ping failed: %s" % exc)
            return
        # The ping does not replace an event — it only moves the next check.
        self.last_activity = now


class RawMonitor(Monitor):
    """Step-A smoke mode: outputs delivered events as a RAW LINE. Retained as a
    diagnostic verb (`stream`) — the report rules run in the watch path
    via WatchMonitor."""

    def handle_event(self, kind, data, raw):
        self.emit(raw)


# --- Adapter: event loop <-> report rules (the watch contract) ---------------

class WatchMonitor(Monitor):
    """Wires the timed event loop (Monitor, Step A) with the
    report rules (herd_state.StateMachine, Step B) into the watch contract.

    DIRECTION: the adapter translates in ONE direction. Monitor hooks become
    StateMachine inputs, the returning outcome becomes stdout lines,
    stderr notes, commands and possibly the abort decision. The StateMachine
    knows neither sockets nor subprocesses, the monitor knows no report rule.

    COMMANDS run in worker threads because they block: a classify-pane
    is a bash subprocess with several pane reads, an agent.get an RPC with
    its own deadline. Synchronously in the main loop they would stop exactly what the
    plan demands as a "timed event loop" — quiet window, deadline and
    delivery. The number of threads is bounded by the StateMachine: per
    agent at most one open command per purpose (debounce/verify/gone).

    ANSWER DUTY: every command produces EXACTLY ONE answer to the
    StateMachine — success, or on_command_failed. Without this guarantee a
    slot would stay occupied until its deadline and in the worst case a completion
    would stay unreported forever (Step-B review, BLOCKER 2)."""

    def __init__(self, names, stall_timeout_min=15, timeout_min=0, poll_sec=2.0,
                 max_events=0, endpoint=None, raw_target=None, bare=False):
        # Defaults verbatim to the watch verb in herd.sh: --stall-timeout 15,
        # --timeout 0 (unlimited — a permanently blocked agent should keep
        # being observed), --poll 2, --max-events 0.
        # timeout_sec/max_lines deliberately 0: deadline and output limit belong
        # to the StateMachine (otherwise there would be two clocks and two counters, and the
        # global reports would bypass --max-events).
        # bare/raw_target: wait contract. stdout only the state; working and
        # monitor-restored do not count as an event (wait waits for an
        # agent state, "restored" is none). max_events of the machine
        # stays 0 — the adapter ends after the first emitted line,
        # otherwise a filtered restored report would end the observation
        # silently.
        Monitor.__init__(self, names, endpoint=endpoint, timeout_sec=0.0, max_lines=0)
        verify = _env_float("HERD_EVENTS_VERIFY_SEC", 0.0) or poll_sec * VERIFY_TICKS
        # Command deadline CLEARLY below the verification interval: if it ran beyond
        # it, the next rest poll would meet an answer still open
        # and the observation would have a hole. The retry interval lies
        # again clearly below the deadline.
        cmd_timeout = (_env_float("HERD_EVENTS_CMD_TIMEOUT_SEC", 0.0)
                       or max(1.0, min(10.0, verify / 3.0)))
        cmd_retry = (_env_float("HERD_EVENTS_CMD_RETRY_SEC", 0.0)
                     or min(2.0, cmd_timeout / 2.0))
        self.timeout_min = timeout_min
        self.cmd_timeout_sec = cmd_timeout
        self.bare = bool(bare)
        self.raw_target = raw_target or None
        # wait --timeout 0 is an immediate timeout (T3): ONE observation (first
        # resync), exit 0 on a hit, otherwise 124. NO deadline before the resync
        # — otherwise an already blocked agent loses against 1e-9 s.
        # watch --timeout 0 stays unlimited.
        self.zero_timeout = bool(self.bare and timeout_min == 0)
        timeout_sec = 0.0 if self.zero_timeout else timeout_min * MINUTE_SEC
        self._cancel = threading.Event()
        self._child_lock = threading.Lock()
        self._child_procs = []
        self._worker_lock = threading.Lock()
        self._worker_threads = set()
        self._rpc_lock = threading.Lock()
        self._rpc_conns = set()
        self.sm = herd_state.StateMachine(
            names, now=time.monotonic(),
            verify_interval_sec=verify,
            stall_timeout_sec=stall_timeout_min * STALL_UNIT_SEC,
            max_events=max_events, timeout_sec=timeout_sec,
            cmd_timeout_sec=cmd_timeout, cmd_retry_sec=cmd_retry,
            raw_target=self.raw_target)
        # Names whose state demonstrably changed without the
        # next resync being able to see it from its own snapshots
        # (pane_id change that only an agent.get cross-check revealed).
        self._forced_gaps = set()
        self._resync_wanted = ""
        # Explanations run in ONE own thread (see _explain): serialized
        # so that they stay in report order, but outside the main loop.
        self._explain_q = queue.Queue()
        self._explain_thread = None
        self._explain_noted = set()     # used ONLY by the explanation thread
        # Running `herdr notification show` processes. Fire-and-forget: the
        # main loop reaps them in handle_tick (no zombie), never waited for.
        self._notify_procs = []

    # -- Output: outcome -> stdout/stderr/exit --

    def _skip_wait_report(self, rep):
        """wait does not count the working all-clear and monitor-restored as an
        event: restored is no agent state, working no hit
        of the wait contract (default target settled / --status X)."""
        if rep.status == "working":
            return True
        if rep.name == herd_state.GLOBAL and rep.status == "monitor-restored":
            return True
        return False

    def _notify(self, name, status):
        """Additional herdr notification for an emitted line.

        Fire-and-forget: the call must neither delay nor
        change the observation. stdout/stderr to nowhere, errors (herdr missing, exit != 0,
        exception) silent; the main loop reaps the child process in handle_tick
        so that no zombies remain. Without HERD_NOTIFY=1: no call."""
        if not NOTIFY_ENABLED:
            return
        if status == "monitor-unavailable":
            title = "herd: herdr does not respond"
        elif status in NOTIFY_STATES:
            title = "herd: %s %s" % (name, status)
        else:
            return
        try:
            proc = subprocess.Popen(
                ["herdr", "notification", "show", title, "--sound", "request"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError):
            return
        self._notify_procs.append(proc)

    def _reap_notifications(self):
        """Reap finished notification processes — poll() does not wait
        and reaps the child process as soon as it is done."""
        if self._notify_procs:
            self._notify_procs = [p for p in self._notify_procs if p.poll() is None]

    def _format_report(self, rep):
        if not self.bare:
            return "%s %s" % (rep.name, rep.status)
        # wait: EXACTLY the state. The global "* monitor-unavailable" becomes the
        # line "monitor-unavailable" (without the star) — wait knows no "*".
        return rep.status

    def _apply(self, outcome):
        """ONE place for the effect of a StateMachine input.

        Order: first the diagnoses (they are the REASON for a report —
        e.g. "pane not classifiable" before the resulting `unknown`),
        then per report the stdout line with its action instruction directly
        after it (like emit_event in herd.sh), commands last — after an
        abort decision not at all, they would be work for nobody."""
        for note in outcome.notes:
            self.note(note)
        for rep in outcome.reports:
            if self.bare and self._skip_wait_report(rep):
                continue
            self.emit(self._format_report(rep))
            # The notification hangs on the EMITTED line, not on the
            # raw event: a repetition suppressed by the StateMachine
            # (no report) triggers nothing here, a later real report
            # of the same state does.
            self._notify(rep.name, rep.status)
            self._explain(rep.name, rep.status)
            if self.bare:
                # wait: exactly one event. Not via max_events of the
                # machine, otherwise a filtered restored line ends the
                # run before an agent state arrived.
                self._finish(herd_state.Exit(EXIT_OK, "event", ""))
                return
        if outcome.exit is not None:
            self._finish(outcome.exit)
            return
        for cmd in outcome.commands:
            self._start_command(cmd)

    def _finish(self, decision):
        self.exit_code = decision.code
        # Workers FIRST: otherwise wait/watch returns with exit 0 and leaves
        # classify-pane/stall-fingerprint behind as a child process.
        self._cancel_workers()
        # First the explanations for the already emitted reports, then the
        # closing word — otherwise the reason for the end stands before the
        # action instructions to which it refers.
        self.drain_explanations()
        if decision.reason == "timeout":
            # The StateMachine knows neither the minute figure nor the names —
            # the adapter adds duration and restart hint. Timeout is
            # NO result (invariant 6). wait and watch have
            # DIFFERENT hint texts; wait gets them from herd.sh
            # (explain-status wait-timeout) so that they do not stand twice.
            if self.bare:
                self._emit_wait_timeout()
            else:
                self.note("[herd] watch TIMEOUT after %smin — observation ends, the "
                          "agents keep RUNNING." % self.timeout_min)
                self.note("[herd]   Resume: herd.sh watch %s"
                          % " ".join(self.names))
        elif decision.message and not self.bare:
            self.note(decision.message)
        raise _Done()

    def _emit_wait_timeout(self):
        """The three hint lines on wait timeout, from herd.sh (explain_wait_timeout)."""
        name = self.names[0] if self.names else ""
        raw = ""
        try:
            raw = self.sm.state_of(name).get("raw") or ""
        except (KeyError, AttributeError):
            raw = ""
        try:
            res = run_verb(
                ["explain-status", name, "wait-timeout",
                 str(self.timeout_min), raw],
                EXPLAIN_TIMEOUT_SEC)
        except (OSError, ValueError, subprocess.SubprocessError,
                subprocess.TimeoutExpired) as exc:
            self.note("[herd] wait TIMEOUT — NOT done, the agent keeps "
                      "running (%s)." % exc)
            return
        if res.err.strip():
            sys.stderr.write(res.err if res.err.endswith("\n") else res.err + "\n")
            sys.stderr.flush()

    def _explain(self, name, status):
        """Action instruction on stderr — from herd.sh (explain_status) so that
        wait and watch speak verbatim.

        NOT in the main loop: a bash start must not stop deadline, reconnect, liveness and
        queue (Step-C review MAJOR 2). The explanation therefore moves
        into ONE own thread — a single one so that the explanations
        stay in report order among each other and stand close behind their
        stdout line. Binding and immediate is only the report line itself;
        the explanation is its comment and may lag or be dropped."""
        if self._explain_thread is None:
            self._explain_thread = threading.Thread(target=self._explain_worker,
                                                    daemon=True)
            self._explain_thread.start()
        self._explain_q.put((name, status))

    def _explain_worker(self):
        while True:
            item = self._explain_q.get()
            if isinstance(item, threading.Event):
                # Drain marker: the queue is FIFO, so everything before it is done.
                item.set()
                continue
            self._explain_once(item[0], item[1])

    def _explain_once(self, name, status):
        try:
            res = run_verb(["explain-status", name, status], EXPLAIN_TIMEOUT_SEC)
        except subprocess.TimeoutExpired:
            self._explain_diag(
                "explain-timeout",
                "[herd] explain-status hangs (> %gs) — no action guidance; "
                "the report lines on stdout are unchanged."
                % EXPLAIN_TIMEOUT_SEC)
            return
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            self._explain_diag("explain-start",
                               "[herd] explain-status not callable (%s) — the "
                               "report lines on stdout are unaffected." % exc)
            return
        # The action instruction itself: write it on VERBATIM. It came via
        # a file instead of directly on our stderr (see run_verb) — for that the
        # deadline is binding, and the text stays word for word the one from herd.sh.
        if res.err.strip():
            sys.stderr.write(res.err if res.err.endswith("\n") else res.err + "\n")
            sys.stderr.flush()
        if res.code != 0:
            # Make visible instead of swallowing: a permanently failing verb
            # means that the action instruction is missing for EVERY report.
            self._explain_diag(
                "explain-rc",
                "[herd] explain-status '%s %s': exit %d — action guidance "
                "missing." % (name, status, res.code))
        if res.out.strip():
            # stdout is the REPORT STREAM (one line per event). explain-status
            # must not share it; it is caught anyway (the output
            # lands in a file), but a verb that writes there is a
            # finding.
            self._explain_diag(
                "explain-stdout",
                "[herd] explain-status writes to stdout (%r) — discarded: "
                "the report stream contains only '<name> <status>'."
                % res.out.strip()[:80])

    def _explain_diag(self, key, msg):
        """Diagnosis of the explanation thread, ONCE per key. Own
        dedup store: Monitor._diagnosed belongs to the main loop, and maintaining a set from
        two threads would be an arrangement nobody reads."""
        if key in self._explain_noted:
            return
        self._explain_noted.add(key)
        self.note(msg)

    def drain_explanations(self, budget=None):
        """Wait for the outstanding explanations before the end — bounded.

        Without that the explanation for the LAST report falls through: the
        process ends immediately after it, and the explanation thread is a
        daemon. Conversely the end must not hang on it, hence the deadline."""
        if self._explain_thread is None:
            return
        done = threading.Event()
        self._explain_q.put(done)
        done.wait(EXPLAIN_TIMEOUT_SEC + 1.0 if budget is None else budget)

    # -- Hooks: delivery -> StateMachine --

    def handle_event(self, kind, data, raw):
        """The monitor has checked envelope, type and pane_id and
        filtered foreign panes. What remains here is the assignment pane -> agent and the translation
        into the two inputs that the report rules know."""
        now = time.monotonic()
        name = self.pane_names.get(event_pane(data))
        if not name:
            # Our pane, but (not yet) a name for it: can occur briefly after a
            # pane_id change until the resync is through.
            self.diag("unmapped-pane", "[herd] event stream: event without a "
                                       "mapped agent — ignored")
            return
        if kind in GONE_EVENTS:
            # NO immediate lost: after events.subscribe the daemon also delivers
            # past and foreign pane_closed (finding Step A). The
            # StateMachine orders the agent.get cross-check for that.
            self._apply(self.sm.on_pane_gone(now, name))
            return
        status = data.get("agent_status")
        if not isinstance(status, str):
            nested = data.get("pane")
            status = nested.get("agent_status") if isinstance(nested, dict) else None
        if not isinstance(status, str) or not status.strip():
            self.diag("no-status", "[herd] event stream: status event without "
                                   "agent_status — ignored")
            return
        self._apply(self.sm.on_status(now, name, status.strip(), self._kind_of(name)))

    def _kind_of(self, name):
        """Backend kind from the last snapshot (field "agent" from agent.get).
        Only muse needs it (raw blocked = internal reviewer instead of dialog).
        None = (not yet) a snapshot — the machine keeps a previously
        stored kind; "" = snapshot without a kind (authoritatively empty)."""
        snap = self.snapshots.get(name)
        return None if snap is None else snap.kind

    def handle_resync(self, result):
        now = time.monotonic()
        if not result.first and self.sm.monitor_down:
            # The SUCCESSFUL resync is the proof that the stream carries again —
            # and the report must stand BEFORE the state reports of the snapshot,
            # otherwise a status report pushes itself between
            # unavailable and restored (T31 equivalent).
            self._apply(self.sm.on_monitor_restored(now))
        gaps = set(result.gaps) | self._forced_gaps
        self._forced_gaps = set()
        # Value None = agent_not_found. On the FIRST resync this is an
        # input error (exit 1, handled by Monitor.run via AgentNotFound),
        # afterwards the authoritative statement "gone" -> lost.
        snaps = dict((name, (snap.status if snap else None))
                     for name, snap in result.control.items())
        kinds = dict((name, (snap.kind if snap else ""))
                     for name, snap in result.control.items())
        self._apply(self.sm.on_resync(now, snaps, gaps, result.first, kinds))
        if result.first and self.zero_timeout:
            # Poll T3: after exactly one observation. A hit has already
            # ended _apply with _Done; without a hit now timeout 124.
            self._finish(herd_state.Exit(EXIT_TIMEOUT, "timeout",
                                         herd_state.MSG_TIMEOUT))

    def handle_stream_down(self, reason):
        # The global report comes from the StateMachine: only it knows the
        # report lock (one report per outage) and counts against --max-events.
        self._apply(self.sm.on_monitor_unavailable(time.monotonic()))

    def handle_stream_up(self):
        # Deliberately silent: `* monitor-restored` was already reported in
        # handle_resync (see there — the order versus the state reports).
        pass

    def handle_tick(self, now):
        self._reap_notifications()
        if self._resync_wanted and not self.stream_down:
            reason, self._resync_wanted = self._resync_wanted, ""
            try:
                self._resync(first=False)
            except (TransportError, RpcError) as exc:
                # The stream points to a dead pane and cannot be rebuilt
                # — that is a monitoring failure, not an agent state.
                self._stream_lost("%s (%s)" % (reason, exc))
        self._apply(self.sm.tick(now))

    # -- Commands: StateMachine -> herd.sh verbs / agent.get --

    def handle_shutdown(self):
        self._cancel_workers()

    def _kill_proc(self, proc):
        """Terminate the process group. PGID is the leader PID (start_new_session).

        POSIX: TERM to the group, 0.5 s grace period, group still there
        (`killpg(pgid, 0)` without error) → KILL to the group — even if the
        leader is already gone. Then reap the leader.
        Windows: no killpg / no SIGKILL → taskkill /T /F, then proc.kill().
        SIGKILL only via getattr, killpg only behind hasattr."""
        pgid = getattr(proc, "_herd_pgid", None) or proc.pid
        sigkill = getattr(signal, "SIGKILL", None)
        if hasattr(os, "killpg"):
            try:
                os.killpg(pgid, signal.SIGTERM)
            except OSError:
                try:
                    proc.terminate()
                except OSError:
                    pass
            until = time.monotonic() + 0.5
            group_alive = False
            while True:
                try:
                    os.killpg(pgid, 0)
                    group_alive = True
                except OSError:
                    group_alive = False
                    break
                if time.monotonic() >= until:
                    break
                time.sleep(0.05)
            if group_alive and sigkill is not None:
                try:
                    os.killpg(pgid, sigkill)
                except OSError:
                    pass
        else:
            try:
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=2)
            except (OSError, subprocess.SubprocessError):
                pass
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=0.3)
        except (subprocess.TimeoutExpired, OSError):
            pass

    def _cancel_workers(self):
        """Close RPC sockets, kill child processes, join worker snapshot.

        Idempotent: _finish and handle_shutdown both call it. explain-status
        does NOT run here (own thread, run_verb without registration)."""
        self._cancel.set()
        with self._rpc_lock:
            conns = list(self._rpc_conns)
        # Never conn.close() directly: on Windows pipes a blocked
        # read holds the I/O lock, and _finish would hang indefinitely.
        # close_conn: socket shutdown+close, pipe asynchronous (see there).
        for conn in conns:
            close_conn(conn)
        with self._child_lock:
            procs = list(self._child_procs)
        for proc in procs:
            self._kill_proc(proc)
        with self._worker_lock:
            threads = list(self._worker_threads)
        deadline = time.monotonic() + 1.0
        for thread in threads:
            remain = deadline - time.monotonic()
            if remain <= 0:
                break
            thread.join(remain)

    def _run_verb_killable(self, args, timeout):
        """Like run_verb, but the Popen is registered and killable as a process
        group — otherwise `herdr pane read` survives the end of wait/watch."""
        out_f = tempfile.TemporaryFile()
        err_f = tempfile.TemporaryFile()
        proc = None
        try:
            proc = subprocess.Popen(
                [BASH, HERD_SH] + list(args),
                stdout=out_f, stderr=err_f,
                start_new_session=True)
            # Leader PID == PGID; after an exit of the leader,
            # proc.pid alone would no longer hit the group.
            proc._herd_pgid = proc.pid
            with self._child_lock:
                self._child_procs.append(proc)
            deadline = time.monotonic() + timeout
            while True:
                if self._cancel.is_set():
                    self._kill_proc(proc)
                    raise CommandFailed("cancelled")
                rc = proc.poll()
                if rc is not None:
                    break
                if time.monotonic() >= deadline:
                    self._kill_proc(proc)
                    raise subprocess.TimeoutExpired(proc.args, timeout)
                time.sleep(0.05)
            out_f.seek(0)
            err_f.seek(0)
            return VerbResult(rc,
                              out_f.read().decode("utf-8", "replace"),
                              err_f.read().decode("utf-8", "replace"))
        finally:
            if proc is not None:
                with self._child_lock:
                    try:
                        self._child_procs.remove(proc)
                    except ValueError:
                        pass
            out_f.close()
            err_f.close()

    def _start_command(self, cmd):
        if self._cancel.is_set():
            return
        thread = threading.Thread(target=self._run_command, args=(cmd,),
                                  daemon=True)
        with self._worker_lock:
            self._worker_threads.add(thread)
        thread.start()

    def _run_command(self, cmd):
        """In the worker thread. Puts EXACTLY ONE result into the main loop's
        queue — also on timeout, exit code != 0 or unexpected output."""
        try:
            try:
                payload = self._execute(cmd)
            except BaseException as exc:                   # noqa: BLE001
                if self._cancel.is_set():
                    return
                payload = ("failed", cmd.request_id,
                           str(exc) or exc.__class__.__name__)
            if self._cancel.is_set():
                return
            if not payload:
                payload = ("failed", cmd.request_id, "no result")
            self.sink.put((0, CMD_RESULT, payload))
        finally:
            with self._worker_lock:
                self._worker_threads.discard(threading.current_thread())

    def _rpc_client(self):
        def _open(conn):
            # Cancel check and registration under the SAME lock: otherwise
            # cancel cleans out an empty register, the worker registers
            # afterwards and lives on. close_conn is done by RpcClient.finally.
            with self._rpc_lock:
                if self._cancel.is_set():
                    raise CommandFailed("cancelled")
                self._rpc_conns.add(conn)

        def _close(conn):
            with self._rpc_lock:
                self._rpc_conns.discard(conn)

        return RpcClient(self.endpoint, on_open=_open, on_close=_close)

    def _execute(self, cmd):
        if cmd.kind == herd_state.CMD_AGENT_GET:
            # Own connection per call (RpcClient) — the event stream never writes
            # again after the subscribe (CRT trap, see _PipeConn).
            snap = snapshot_agents(self._rpc_client(), [cmd.name]).get(cmd.name)
            if self._cancel.is_set():
                raise CommandFailed("cancelled")
            return ("agent-get", cmd.request_id, cmd.name, snap)
        pane = self._pane_of(cmd.name)
        if not pane:
            # Without a pane_id the question cannot be asked. That is an error, NOT
            # an inconspicuous pane — otherwise an agent without a known pane
            # would be silently reported as done.
            return ("failed", cmd.request_id,
                    "no pane_id known for '%s'" % cmd.name)
        if cmd.kind == herd_state.CMD_CLASSIFY:
            verdict = self._herd_sh("classify-pane", pane).strip()
            if verdict not in herd_state.VALID_VERDICTS:
                return ("failed", cmd.request_id,
                        "unexpected output from classify-pane: %r" % verdict[:80])
            return ("classify", cmd.request_id, verdict)
        out = self._herd_sh("stall-fingerprint", pane)
        fingerprint, limited, failed = "", None, None
        for line in out.splitlines():
            if line.startswith("fp "):
                fingerprint = line[3:].strip()
            elif line.startswith("limited "):
                limited = line[8:].strip() == "yes"
            elif line.startswith("failed "):
                failed = line[7:].strip() == "yes"
        if not fingerprint or limited is None or failed is None:
            return ("failed", cmd.request_id,
                    "unexpected output from stall-fingerprint: %r" % out[:80])
        return ("fingerprint", cmd.request_id, fingerprint, limited, failed)

    def _pane_of(self, name):
        """pane_id from the last resync snapshot (resolution name -> pane is
        the adapter's business, see herd_state.py). Also read from worker
        threads: a resync can replace self.snapshots in between. A then
        outdated value is harmless — the answer describes an outdated pane
        and is discarded by the generation correlation."""
        snap = self.snapshots.get(name)
        return snap.pane_id if snap else ""

    def _herd_sh(self, verb, pane):
        """Execute an internal herd.sh verb. The own deadline lies just BELOW
        cmd_timeout_sec of the StateMachine so that the error answer normally
        arrives BEFORE its deadline expires — otherwise it fizzles out as outdated and
        the slot only frees up past the deadline. Conversely, a late
        SUCCESS answer can thus only arise through a state change, not
        through the deadline itself."""
        res = self._run_verb_killable([verb, pane],
                                      max(0.5, self.cmd_timeout_sec - 0.5))
        if res.code != 0:
            raise CommandFailed("%s %s: exit %d (%s)"
                                % (verb, pane, res.code,
                                   res.err.strip()[:120] or "no message"))
        return res.out

    def handle_command_result(self, payload):
        now = time.monotonic()
        kind, rid = payload[0], payload[1]
        if kind == "classify":
            self._apply(self.sm.on_classify(now, rid, payload[2]))
        elif kind == "fingerprint":
            self._apply(self.sm.on_fingerprint(
                now, rid, payload[2], payload[3], payload[4]))
        elif kind == "agent-get":
            name, snap = payload[2], payload[3]
            if snap is not None:
                self._note_pane_change(name, snap)
            self._apply(self.sm.on_agent_get(now, rid, snap is not None,
                                             snap.status if snap else None))
        else:
            self._apply(self.sm.on_command_failed(now, rid, payload[2]))

    def _note_pane_change(self, name, snap):
        """The cross-check says "alive" — but in a DIFFERENT pane. Then the
        subscription points to a dead pane and the agent would from now on be
        unobserved (plan, risk table). The stream is therefore completely rebuilt
        in the next tick; the state change goes as a gap into the
        following resync so that the report lock drops."""
        if not snap.pane_id or snap.pane_id == self._pane_of(name):
            return
        self._forced_gaps.add(name)
        self._resync_wanted = ("re-subscribe after pane_id change of '%s' (%s -> %s)"
                               % (name, self._pane_of(name) or "?", snap.pane_id))
        self.note("[herd] '%s': pane changed (%s -> %s) — subscription is "
                  "rebuilt." % (name, self._pane_of(name) or "?", snap.pane_id))


# --- CLI ---------------------------------------------------------------------

USAGE = """herd_events.py — event watcher for herd.sh
  herd_events.py watch <name…> [--stall-timeout MIN] [--timeout MIN]
                               [--poll SEC] [--max-events N]
  herd_events.py wait <name> [--timeout MIN] [--stall-timeout MIN]
                             [--poll SEC] [--status X]
  herd_events.py probe                       # feature detection (0 = usable)
  herd_events.py ping                        # diagnostics
  herd_events.py stream <name…> [--max-lines N] [--timeout SEC]   # diagnostics"""


def _int_arg(argv, i, flag):
    if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
        raise UsageError("%s requires a value" % flag)
    raw = argv[i + 1]
    if not raw.isdigit():
        raise UsageError("%s: expected a number, got '%s'" % (flag, raw))
    return int(raw)


def _minutes_arg(argv, i, flag):
    """Minutes like validate_minutes in herd.sh — including the leading zero:
    there bash computes "08" as octal, here it would be silently interpreted
    differently. Both paths must report the same usage error (T26)."""
    val = _int_arg(argv, i, flag)
    raw = argv[i + 1]
    if len(raw) > 1 and raw[0] == "0":
        raise UsageError("%s must be given without a leading zero (got: '%s')" % (flag, raw))
    return val


def _poll_arg(argv, i, flag):
    """--poll: positive decimal number. 0, 00 and .000 are also zero and
    would be a verification rest poll without an interval."""
    if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
        raise UsageError("%s requires a value" % flag)
    raw = argv[i + 1]
    # Character by character like the case pattern in herd.sh: only digits and AT MOST
    # one period. This also rejects "nan"/"inf", which float() would accept.
    if not raw or raw == "." or raw.count(".") > 1 or raw.strip("0123456789."):
        raise UsageError("%s requires a positive number of seconds, got: '%s'"
                         % (flag, raw))
    val = float(raw)
    if val <= 0:
        raise UsageError("%s must be greater than 0 (got: '%s')" % (flag, raw))
    return val


def cmd_ping(argv):
    if argv:
        raise UsageError("ping takes no arguments")
    rpc = RpcClient(resolve_endpoint())
    try:
        res = rpc.ping()
    except (TransportError, RpcError) as exc:
        print("[herd] event API not reachable (%s): %s"
              % (rpc.endpoint.label, exc), file=sys.stderr, flush=True)
        return EXIT_USAGE
    version = res.get("version") or "?"
    print("[herd] herdr %s, protocol %s (%s)"
          % (version, res.get("protocol"), rpc.endpoint.label),
          file=sys.stderr, flush=True)
    print("ok", flush=True)
    return EXIT_OK


def cmd_probe(argv):
    """Feature detection for the dispatcher in `herd.sh wait`/`watch`.

    Exit 0 = the event API is USABLE, exit 2 = not (reason on stderr, one
    line — herd.sh appends it to its error message).

    Why not simply `ping`: reachable does not mean subscribable.
    An older daemon can reject `events.subscribe`. Without this second
    check the observer would have failed only AFTER the exec — with exit 2
    in the middle of an observation that the caller considers running.

    The probe subscribes only to the GLOBAL type pane.closed: it needs no
    pane_id (that would come only from the discovery) and is thus the smallest
    request that actually exercises the method. The connection is closed again
    immediately, the subscription dies with it."""
    if argv:
        raise UsageError("probe takes no arguments")
    rpc = RpcClient(resolve_endpoint())
    try:
        rpc.ping()
    except (TransportError, RpcError) as exc:
        print("[herd] event API not reachable (%s): %s"
              % (rpc.endpoint.label, exc), file=sys.stderr, flush=True)
        return EXIT_USAGE
    try:
        res = rpc.call("events.subscribe",
                       {"subscriptions": [{"type": "pane.closed"}]})
    except RpcError as exc:
        # EVERY rejection counts, not only 'unknown_method': a subscribe that
        # the daemon does not accept for whatever reason carries no
        # observation. The code is in the message — it is the difference
        # between "method missing" and "method there, call wrong".
        print("[herd] events.subscribe rejected (%s): %s"
              % (rpc.endpoint.label, exc), file=sys.stderr, flush=True)
        return EXIT_USAGE
    except TransportError as exc:
        print("[herd] events.subscribe not possible (%s): %s"
              % (rpc.endpoint.label, exc), file=sys.stderr, flush=True)
        return EXIT_USAGE
    # Just as strict as EventStream.open: taking any answer with 'result'
    # as confirmation would let every protocol deviation through —
    # and the dispatcher would delegate into an engine that fails right away.
    if not isinstance(res, dict) or res.get("type") != "subscription_started":
        print("[herd] events.subscribe: unexpected reply (%s) — expected "
              "result.type 'subscription_started'" % (json.dumps(res)[:120],),
              file=sys.stderr, flush=True)
        return EXIT_USAGE
    print("ok", flush=True)
    return EXIT_OK


def cmd_stream(argv):
    names, timeout_sec, max_lines = [], 0.0, 0
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--max-lines":
            max_lines = _int_arg(argv, i, arg)
            i += 2
        elif arg == "--timeout":
            timeout_sec = float(_int_arg(argv, i, arg))
            i += 2
        elif arg.startswith("-"):
            raise UsageError("unknown option: %s" % arg)
        else:
            names.append(arg)
            i += 1
    if not names:
        raise UsageError("stream requires at least one agent name")
    return RawMonitor(names, timeout_sec=timeout_sec, max_lines=max_lines).run()


def cmd_watch(argv):
    """The watch contract of herd.sh, here in the event path. Same options,
    same semantics (MINUTES!), same exit codes: 0 = events/all done/
    --max-events · 1 = agent never seen · 2 = usage error or event API not
    available · 124 = time limit of the OBSERVATION.

    Since Step D the dispatcher in herd.sh validates the options BEFORE the
    delegation (the same exit-2 cases as before, T17/T26/T27). The check
    here is complete anyway: the observer is also directly callable, and
    a silently misinterpreted value is worse than a
    usage error."""
    names = []
    stall_min, timeout_min, max_events, poll_sec = 15, 0, 0, 2.0
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--stall-timeout":
            stall_min = _minutes_arg(argv, i, arg); i += 2
        elif arg == "--timeout":
            timeout_min = _minutes_arg(argv, i, arg); i += 2
        elif arg == "--max-events":
            max_events = _int_arg(argv, i, arg); i += 2
        elif arg == "--poll":
            poll_sec = _poll_arg(argv, i, arg); i += 2
        elif arg.startswith("-"):
            raise UsageError("watch: unknown option '%s'" % arg)
        else:
            names.append(arg); i += 1
    if not names:
        raise UsageError("watch <name...> — at least one agent")
    for name in names:
        # Two entries for the same agent would be two quiet windows and two
        # report locks for ONE truth (in herd.sh exit 2, T27).
        if names.count(name) > 1:
            raise UsageError("watch: agent '%s' given more than once" % name)
    mon = WatchMonitor(names, stall_timeout_min=stall_min, timeout_min=timeout_min,
                       poll_sec=poll_sec, max_events=max_events)
    try:
        return mon.run()
    finally:
        # Also the paths that do NOT go through _finish (exit 1/2 at start,
        # Ctrl-C) must not swallow an already reported explanation.
        mon.drain_explanations()


def cmd_wait(argv):
    """The wait contract of herd.sh, here in the event path. Exactly one agent,
    output "bare" (only the state), max_events effectively 1 (the adapter counts
    emitted lines, not those of the machine — see WatchMonitor._apply).

    --status X switches on the raw mode of the state machine (heuristic-free).
    Without --status the default target settled applies: idle/done after quiet window
    + cross-check, plus blocked/limited/auth/failed/question and the always-hits.

    --timeout 0 is an immediate timeout (unlike watch, where it is unlimited):
    first resync complete, exit 0 on a hit, otherwise 124."""
    names = []
    stall_min, timeout_min, poll_sec = 15, 30, 2.0
    raw_target = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--stall-timeout":
            stall_min = _minutes_arg(argv, i, arg); i += 2
        elif arg == "--timeout":
            timeout_min = _minutes_arg(argv, i, arg); i += 2
        elif arg == "--poll":
            poll_sec = _poll_arg(argv, i, arg); i += 2
        elif arg == "--status":
            if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                raise UsageError("wait: --status requires a value")
            raw_target = argv[i + 1]
            if not raw_target:
                raise UsageError("wait: --status requires a value")
            i += 2
        elif arg.startswith("-"):
            raise UsageError("wait: unknown option '%s'" % arg)
        else:
            names.append(arg); i += 1
    if len(names) != 1:
        raise UsageError("wait <name> — exactly one agent")
    mon = WatchMonitor(names, stall_timeout_min=stall_min, timeout_min=timeout_min,
                       poll_sec=poll_sec, max_events=0, raw_target=raw_target,
                       bare=True)
    try:
        return mon.run()
    finally:
        mon.drain_explanations()


def main(argv):
    # Pin stdout/stderr to UTF-8 and \n: native Windows Python otherwise writes
    # CRLF and the ANSI codepage — both make the lines unusable for the
    # calling monitor (and the tests).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", newline="\n", errors="replace")
        except (AttributeError, ValueError):
            pass
    verb = argv[0] if argv else ""
    try:
        if verb == "watch":
            return cmd_watch(argv[1:])
        if verb == "wait":
            return cmd_wait(argv[1:])
        if verb == "ping":
            return cmd_ping(argv[1:])
        if verb == "probe":
            return cmd_probe(argv[1:])
        if verb == "stream":
            return cmd_stream(argv[1:])
        raise UsageError("unknown subcommand: %s" % (verb or "(none)"))
    except UsageError as exc:
        print("[herd] %s\n%s" % (exc, USAGE), file=sys.stderr, flush=True)
        return EXIT_USAGE
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
