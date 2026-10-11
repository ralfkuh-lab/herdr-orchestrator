#!/usr/bin/env python3
# fake_events_server.py — fake of the herdr event socket for the tests, over TCP.
#
# Why TCP: Windows named pipes cannot be faked cleanly on the server side
# without pywin32. scripts/herd_events.py therefore accepts tcp:host:port, but
# ONLY if HERD_EVENTS_ENDPOINT explicitly demands it — automatic resolution is
# always pipe (Windows) or AF_UNIX (Linux/macOS).
#
#   fake_events_server.py <fixture> [--port-file F] [--log F] [--exit-after SEC]
#
# The server handles ARBITRARILY MANY successive connections: the watcher
# reconnects per RPC (CRT trap) and keeps the event stream separate. --port-file
# carries the assigned port (binding to port 0 avoids collisions in the test run),
# --log one line "<conn-no> <method>" per request (proves in the tests that each
# RPC uses its own connection). --exit-after is the emergency brake against
# zombie servers when a test aborts.
#
# The log carries "<conn-no> <method> <params-json>" per request (params with
# sorted keys, so tests can compare the complete subscription list and the order
# of requests exactly) and "<conn-no> close" or "<conn-no> drop" per finished
# connection.
#
# FIXTURE LANGUAGE (one directive per line, # = comment):
#
#   reply <method> <result-json>      Answer to a request. Several lines for the
#                                     same method act as a QUEUE (the last one
#                                     repeats) — so discovery and control
#                                     snapshot get different answers. WITHOUT an
#                                     entry the server answers with the error
#                                     'fixture_missing': a silent {} would mask
#                                     a misspelled or entirely missing protocol
#                                     call. Payload HOLD (without JSON): keep the
#                                     connection open, no answer — for
#                                     cancellable agent.get workers.
#   error <method> <code> <text…>     Error answer, otherwise like reply.
#   mute <method> <interval> <text>   This method is NEVER answered; instead
#                                     <text> runs over the line every <interval>
#                                     seconds. This makes it provable that an
#                                     overall timeout also hits when irrelevant
#                                     lines keep arriving (each line could
#                                     otherwise start a new read).
#   stream                            Start of a stream script. The N-th
#                                     events.subscribe plays block N (the last
#                                     one repeats) — so block 2 is the course
#                                     AFTER the first reconnect.
#     emit <json>                     Send line verbatim (event).
#     raw  <text>                     Send line verbatim (also garbage — for
#                                     the stream error rules).
#     sleep <sec>                     Delay in the script.
#     drop                            Close the connection hard (drop).
#     hold                            Keep it open, send nothing more.
#   Without a final drop/hold it is held implicitly: a close would be a DROP and
#   thus an event the fixture did not order.

import json
import os
import socket
import sys
import threading
import time

STOP = threading.Event()


class Fixture:
    def __init__(self, path):
        self.replies = {}          # method -> [("result", text) | ("error", code, text)]
        self.muted = {}            # method -> (interval, text)
        self.streams = []          # [[(op, arg), …], …]
        self._used = {}
        self._stream_idx = 0
        self._lock = threading.Lock()
        self._parse(path)

    def _parse(self, path):
        block = None
        with open(path, encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                op, _, rest = line.partition(" ")
                rest = rest.strip()
                if op == "reply":
                    method, _, payload = rest.partition(" ")
                    self.replies.setdefault(method, []).append(("result", payload.strip()))
                elif op == "error":
                    method, _, tail = rest.partition(" ")
                    code, _, text = tail.partition(" ")
                    self.replies.setdefault(method, []).append(("error", code, text.strip()))
                elif op == "mute":
                    method, _, tail = rest.partition(" ")
                    interval, _, text = tail.partition(" ")
                    self.muted[method] = (float(interval), text.strip())
                elif op == "stream":
                    block = []
                    self.streams.append(block)
                elif op in ("emit", "raw", "sleep", "drop", "hold"):
                    if block is None:
                        raise SystemExit("Fixture line %d: '%s' without a preceding "
                                         "'stream'-Block" % (lineno, op))
                    block.append((op, rest))
                else:
                    raise SystemExit("Fixture line %d: unknown directive '%s'"
                                     % (lineno, op))

    def response(self, method, rid):
        with self._lock:
            specs = self.replies.get(method)
            if not specs:
                # No silent {}: a successful answer may only come from an
                # explicit reply directive, otherwise tests turn green that do
                # not even make the protocol call correctly.
                return json.dumps({"id": rid, "error": {
                    "code": "fixture_missing",
                    "message": "no reply directive for '%s'" % method}})
            used = self._used.get(method, 0)
            self._used[method] = used + 1
            spec = specs[min(used, len(specs) - 1)]
        if spec[0] == "result":
            payload = spec[1] or "{}"
            if payload.strip() == "HOLD":
                return None
            # The result JSON is inserted VERBATIM (not reserialized), so a
            # fixture can also deliberately send messy JSON.
            return '{"id": %s, "result": %s}' % (json.dumps(rid), payload)
        return json.dumps({"id": rid,
                           "error": {"code": spec[1], "message": spec[2]}})

    def next_stream(self):
        with self._lock:
            if not self.streams:
                return [("hold", "")]
            idx = min(self._stream_idx, len(self.streams) - 1)
            self._stream_idx += 1
            return self.streams[idx]


class Logger:
    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()

    def __call__(self, text):
        if not self.path:
            return
        with self._lock:
            with open(self.path, "a", encoding="utf-8", newline="\n") as fh:
                fh.write(text + "\n")


def send_line(conn, text):
    conn.sendall(text.encode("utf-8") + b"\n")


def hold(conn):
    """Keep open until the client leaves or the server ends."""
    conn.settimeout(0.2)
    while not STOP.is_set():
        try:
            if not conn.recv(4096):
                return
        except socket.timeout:
            continue
        except OSError:
            return


def noise(conn, interval, text):
    """Refuse the answer and keep sending lines instead."""
    while not STOP.is_set():
        try:
            send_line(conn, text)
        except OSError:
            return
        time.sleep(interval)


def play(conn, ops, cid, log):
    for op, arg in ops:
        if op in ("emit", "raw"):
            send_line(conn, arg)
        elif op == "sleep":
            time.sleep(float(arg))
        elif op == "drop":
            log("%d drop" % cid)
            conn.close()
            return
        elif op == "hold":
            break
    hold(conn)


def handle(conn, cid, fix, log):
    try:
        reader = conn.makefile("rb")
        for raw in reader:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except ValueError:
                log("%d unlesbar" % cid)
                continue
            method = req.get("method", "")
            rid = str(req.get("id", ""))
            log("%d %s %s" % (cid, method,
                              json.dumps(req.get("params"), sort_keys=True,
                                         separators=(",", ":"))))
            if method in fix.muted:
                noise(conn, *fix.muted[method])
                return
            resp = fix.response(method, rid)
            if resp is None:
                hold(conn)
                return
            send_line(conn, resp)
            if method == "events.subscribe":
                play(conn, fix.next_stream(), cid, log)
                return
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
        log("%d close" % cid)


def main(argv):
    fixture_path = None
    port_file = log_path = None
    exit_after = 0.0
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--port-file":
            port_file = argv[i + 1]; i += 2
        elif arg == "--log":
            log_path = argv[i + 1]; i += 2
        elif arg == "--exit-after":
            exit_after = float(argv[i + 1]); i += 2
        elif arg.startswith("-"):
            raise SystemExit("unknown option: %s" % arg)
        else:
            fixture_path = arg; i += 1
    if not fixture_path:
        raise SystemExit("usage: fake_events_server.py <fixture> "
                         "[--port-file F] [--log F] [--exit-after SEC]")

    fix = Fixture(fixture_path)
    log = Logger(log_path)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    port = srv.getsockname()[1]
    if port_file:
        # Write completely first, then rename: the test runner polls on the file
        # and must not read a half port.
        tmp = port_file + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("%d\n" % port)
        os.replace(tmp, port_file)
    print(port, flush=True)

    if exit_after > 0:
        def _watchdog():
            time.sleep(exit_after)
            STOP.set()
            os._exit(0)
        threading.Thread(target=_watchdog, daemon=True).start()

    cid = 0
    srv.settimeout(0.5)
    while not STOP.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        cid += 1
        threading.Thread(target=handle, args=(conn, cid, fix, log),
                         daemon=True).start()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
