#!/usr/bin/env python3
# Regression for the MAJOR finding of the Step-D E2E (docs/step-d-e2e.md,
# scenarios b/c): the watcher did not exit on a SILENT stream.
#
# The cause was the transport, not the logic: `close()` of a Python io object
# takes its internal lock — and a running, blocking `read()` holds that lock.
# On a Windows named pipe the read only returns once data arrives. Closing from
# the main thread while the reader thread is listening therefore waits for the
# next event line. Observed: exit code and output were already fixed, yet the
# process lived on for three more minutes — until a deliberately triggered pane
# event released it.
#
# Why the TCP test suite (T40-T93) could NOT catch this: `socket.close()` takes
# no io lock. This test therefore reproduces the trap with a FAKE transport whose
# `close()` blocks while a read is outstanding — platform-neutral and without a
# real daemon. The real pipe proof remains manual (orchestrator, see
# docs/step-d-e2e.md).
#
#   bash tests/run.sh T94          # as part of the full run
#   python3 -m unittest discover -s tests -p 'test_stream_close.py' -v

import io
import json
import os
import sys
import threading
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "scripts"))

import herd_events  # noqa: E402

# Budget for "the run came back". Generous, because the test machine may be
# slow — the difference this test measures is "fractions of a second" against
# "never", not 0.1 s against 0.3 s.
RETURN_BUDGET_SEC = 10.0
# How long the fake close() blocks at most. Clearly ABOVE the return budget
# (otherwise the test would be blind), but finite: a regression should produce a
# clean FAIL and not a hanging test process.
BLOCK_MAX_SEC = 30.0


class BlockingConnection(herd_events._Conn):
    """Fake transport with the Windows pipe property: `close()` only returns
    once the running read is back.

    - `write_line` answers the events.subscribe with the matching id (the
      watcher assigns it, it is not known in advance).
    - the first read delivers that answer, every further one BLOCKS — that is
      the silent stream.
    - `close()` waits for the running read to finish (the io lock).
    """

    blocking_close = True

    def __init__(self):
        herd_events._Conn.__init__(self)
        self._pending = []
        self.reading = threading.Event()    # reader now hangs in the read
        self.release = threading.Event()    # test lets the read return
        self._read_done = threading.Event()
        self._read_done.set()
        self.close_calls = 0
        self.closed = threading.Event()

    def _recv(self, timeout):
        if self._pending:
            return self._pending.pop(0)
        self._read_done.clear()
        self.reading.set()
        try:
            self.release.wait()
            return b""
        finally:
            self._read_done.set()

    def write_line(self, text):
        req = json.loads(text)
        self._pending.append(json.dumps(
            {"id": req["id"],
             "result": {"type": "subscription_started"}}).encode("utf-8") + b"\n")

    def close(self):
        self.close_calls += 1
        # EXACTLY the trap: as long as a read is outstanding, close() does not
        # get through.
        self._read_done.wait(BLOCK_MAX_SEC)
        self.closed.set()


class StreamCloseTest(unittest.TestCase):

    def setUp(self):
        self.connections = []
        self._connect = herd_events.connect
        self._snapshot = herd_events.snapshot_agents
        self._liveness = herd_events.LIVENESS_SEC
        self._tick = herd_events.TICK_SEC
        herd_events.TICK_SEC = 0.05
        herd_events.connect = self._fake_connect
        herd_events.snapshot_agents = self._fake_snapshot

    def tearDown(self):
        # Release the hanging reads first, otherwise threads stay behind.
        for conn in self.connections:
            conn.release.set()
        herd_events.connect = self._connect
        herd_events.snapshot_agents = self._snapshot
        herd_events.LIVENESS_SEC = self._liveness
        herd_events.TICK_SEC = self._tick

    # -- fakes --

    def _fake_connect(self, endpoint, timeout=None):
        conn = BlockingConnection()
        self.connections.append(conn)
        return conn

    def _fake_snapshot(self, rpc, names):
        return dict((n, herd_events.AgentSnapshot(n, "p:" + n, "working", 1))
                    for n in names)

    def _monitor(self, timeout_sec):
        return herd_events.Monitor(
            ["a"], endpoint=herd_events.Endpoint("pipe", "fake", "pipe:fake"),
            timeout_sec=timeout_sec)

    def _run_monitor(self, mon):
        """Run the watcher in a thread and wait for its return. The thread is
        the measured quantity: if close() hangs, run() never comes back and
        `is_alive()` stays True.

        Deliberately a DAEMON thread: on a regression there should be a clean
        FAIL, not a hanging test process that only the runner kills. For the same
        reason the stdout redirection sits in the MAIN thread — it is also undone
        when the run hangs (sys.stdout is process-wide; the run's output ends up
        in the buffer anyway)."""
        result = {}

        def _target():
            result["rc"] = mon.run()

        thread = threading.Thread(target=_target, daemon=True)
        buf = io.StringIO()
        with redirect_stdout(buf):
            thread.start()
            thread.join(RETURN_BUDGET_SEC)
        return thread, result, buf.getvalue()

    # -- cases --

    def test_regular_end_does_not_hang_on_blocking_close(self):
        """The main case (E2E b/c): end decided, stream silent. Without the fix
        `run()` waits in finally on `close()` and thus on the next event line
        that never comes."""
        mon = self._monitor(timeout_sec=0.3)
        thread, result, _ = self._run_monitor(mon)

        self.assertFalse(thread.is_alive(),
                         "run() hangs in close() after the end decision")
        self.assertEqual(herd_events.EXIT_TIMEOUT, result.get("rc"))
        conn = self.connections[0]
        self.assertGreaterEqual(conn.close_calls, 1, "close() was never attempted")
        # THIS is what makes the test meaningful: close() is still hanging at
        # this moment — so the run did not come back because closing happened to
        # be fast, but because it no longer holds it up.
        self.assertFalse(conn.closed.is_set(),
                         "fake close() was not blocked at all — test would be blind")

    def _allow_only_first_resync(self):
        """Release snapshot_agents for exactly ONE complete resync (discovery +
        control are two calls), then let it fail. That way the case stays at the
        outage and does not blur into a chain of newly built connections."""
        counter = {"n": 0}

        def _snapshot(rpc, names):
            counter["n"] += 1
            if counter["n"] > 2:
                raise herd_events.TransportError("resync fake")
            return self._fake_snapshot(rpc, names)

        herd_events.snapshot_agents = _snapshot

    def _fail_ping(self, mon):
        def _broken():
            raise herd_events.TransportError("ping fake")

        herd_events.LIVENESS_SEC = 0.1
        mon.rpc.ping = _broken

    def test_end_after_output_limit_does_not_hang(self):
        """Second exit of the same spot: `_Done` (in the watch path the abort
        decision of the StateMachine, here the output limit of the smoke verb).
        It runs through the same finally."""
        mon = self._monitor(timeout_sec=0.0)
        mon.max_lines = 1
        # The one line comes from the outage hook, triggered IN the main loop by
        # the failing liveness ping — not a foreign thread that produces output
        # past the loop.
        self._fail_ping(mon)
        self._allow_only_first_resync()
        thread, result, out = self._run_monitor(mon)

        self.assertFalse(thread.is_alive(), "run() hangs in close() after _Done")
        self.assertEqual(herd_events.EXIT_OK, result.get("rc"))
        self.assertIn("* monitor-unavailable", out)

    def test_failed_liveness_ping_does_not_freeze_loop(self):
        """The same blockage lurks MID-run: if the liveness ping fails,
        `_stream_lost()` closes the still open connection — while the reader is
        reading. The main loop would freeze exactly when it should reconnect, and
        neither backoff nor deadline would ever get their turn."""
        mon = self._monitor(timeout_sec=1.0)
        self._fail_ping(mon)
        self._allow_only_first_resync()
        thread, result, out = self._run_monitor(mon)

        self.assertFalse(thread.is_alive(),
                         "main loop frozen in close() of the outage path")
        # The deadline must hit on time despite the outage.
        self.assertEqual(herd_events.EXIT_TIMEOUT, result.get("rc"))
        self.assertIn("* monitor-unavailable", out)
        self.assertFalse(self.connections[0].closed.is_set(),
                         "fake close() was not blocked at all — test would be blind")

    def test_close_conn_never_blocks_caller(self):
        """The unit itself — and the cross-check that the non-blocking transport
        (socket, TCP suite) still closes SYNCHRONOUSLY. Synchronous here means:
        deterministically, once close_conn has returned the connection is really
        closed (T49 builds on this)."""
        conn = BlockingConnection()
        self.connections.append(conn)
        # Let a read run so that close() WOULD block.
        threading.Thread(target=lambda: conn.read_line(None), daemon=True).start()
        self.assertTrue(conn.reading.wait(5), "fake read never entered the read")
        start = time.monotonic()
        herd_events.close_conn(conn)
        self.assertLess(time.monotonic() - start, 2.0,
                        "close_conn() blocked the caller")
        self.assertFalse(conn.closed.is_set())

        class ClosesImmediately(BlockingConnection):
            blocking_close = False

        fast = ClosesImmediately()
        herd_events.close_conn(fast)
        self.assertTrue(fast.closed.is_set(),
                        "non-blocking transport must close synchronously")

    def test_failed_subscribe_leaves_no_connection_open(self):
        """Side finding of the same spot: if `open()` failed, the connection
        stayed open — the caller only holds an object without a stream and can no
        longer close it. During reconnect backoff that would be one corpse per
        attempt."""

        class RejectingConnection(BlockingConnection):
            def write_line(self, text):
                req = json.loads(text)
                self._pending.append(json.dumps(
                    {"id": req["id"],
                     "error": {"code": "unknown_method",
                               "message": "no"}}).encode("utf-8") + b"\n")

        conn = RejectingConnection()
        self.connections.append(conn)
        herd_events.connect = lambda endpoint, timeout=None: conn
        stream = herd_events.EventStream(
            herd_events.Endpoint("pipe", "fake", "pipe:fake"),
            [{"type": "pane.closed"}], herd_events.queue.Queue())
        with self.assertRaises(herd_events.RpcError):
            stream.open()
        # Wait BOUNDED instead of asserting immediately: close_conn always
        # offloads the pipe close into a thread, even without an outstanding read
        # (see there — the transport kind decides, not the momentary state).
        # `Thread.start()` does not guarantee that close() has run before the next
        # line here; an immediate assert would depend on the scheduler.
        # No read is outstanding here, so the close goes through right away — the
        # deadline is pure scheduler tolerance, not real waiting.
        self.assertTrue(conn.closed.wait(RETURN_BUDGET_SEC),
                        "connection not closed after failed subscribe")


if __name__ == "__main__":
    unittest.main()
