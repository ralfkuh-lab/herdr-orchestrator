# ---------------------------------------------- Event path (herd_events.py) ---
# T40+: the event watcher scripts/herd_events.py against the fake event server
# tests/bin/fake_events_server.py — over TCP (HERD_EVENTS_ENDPOINT), because
# Windows named pipes cannot be faked server-side without pywin32. The real
# pipe/AF_UNIX resolution remains a manual test (step D of the rebuild plan).
#
# Step A still has NO reporting rules: checked are the transport, the four-stage
# start sequence (discovery snapshot -> subscribe -> control snapshot), reconnect
# and the stream error rules. The `stream` subcommand prints delivered events as
# raw lines — a diagnostic verb, NOT the watch contract.


if should_run T40 target; then
  ev_start "$WORK/t40" <<'EOF'
reply ping {"type":"pong","version":"fake","protocol":17}
EOF
  run_events ping
  ev_stop
  check T40 target "herd_events ping: reachability via HERD_EVENTS_ENDPOINT" \
        "ok|0" "$OUT|$RC"
fi

if should_run T41 target; then
  ev_start "$WORK/t41" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_events stream a --max-lines 2 --timeout 10
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  # Additionally proves the four-stage start sequence in its ORDER
  # (discovery snapshot, subscribe, control snapshot), every request on its OWN
  # connection (on Windows a second write after a read fails) and the COMPLETE
  # subscription list: status events per observed pane plus the global
  # pane.closed/exited as the source for 'lost'.
  order="$(awk '$2 != "close" && $2 != "drop" {printf "%s,", $2}' "$EV_LOG")"
  conns="$(awk '{print $1}' "$EV_LOG" | sort -u | wc -l | tr -d ' ')"
  subs="$(awk '$2 == "events.subscribe" {print $3}' "$EV_LOG")"
  ev_stop
  check T41 target "herd_events stream: raw lines, start sequence in order, complete subscription" \
        "$EV_A_WORKING;$EV_A_IDLE|0|agent.get,events.subscribe,agent.get,|3|$EV_SUBS_A" \
        "$got|$RC|$order|$conns|$subs"
fi

if should_run T42 target; then
  ev_start "$WORK/t42" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
sleep 0.1
drop
stream
emit $EV_A_IDLE
hold
EOF
  # A torn stream is a GLOBAL event ("*"), not an agent state — and after the
  # rebuild the same resync sequence runs again, after which the events keep
  # flowing.
  run_events stream a --max-lines 4 --timeout 10
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  ev_stop
  check T42 target "herd_events: tear-down -> '* monitor-unavailable', reconnect -> '* monitor-restored'" \
        "$EV_A_WORKING;* monitor-unavailable;* monitor-restored;$EV_A_IDLE|0" "$got|$RC"
fi

if should_run T42b target; then
  ev_start "$WORK/t42b" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
raw {"id":"sub","error":{"code":"events_lost","message":"resubscribe and resync"}}
hold
stream
emit $EV_A_IDLE
hold
EOF
  # herdr >= 0.9.2: if a subscriber falls behind the event history, an error
  # line arrives instead of an event. It is a tear-down with resync, not
  # garbage — even if the server were to leave the connection (here: hold) open.
  run_events stream a --max-lines 4 --timeout 10
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  reason=no; case "$ERR" in *"herdr reports events_lost"*) reason=yes ;; esac
  garbage="$(printf '%s\n' "$ERR" | grep -c 'unreadable line' | tr -d ' ')"
  ev_stop
  check T42b target "herd_events: events_lost -> tear-down with resync, no garbage diagnosis" \
        "$EV_A_WORKING;* monitor-unavailable;* monitor-restored;$EV_A_IDLE|0|yes|0" \
        "$got|$RC|$reason|$garbage"
fi

if should_run T43 target; then
  ev_start "$WORK/t43" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
raw {broken
raw still broken
emit {"event":["no","string"],"data":{}}
emit {"event":"pane.agent_status_changed","data":"not an object"}
emit {"event":"pane_closed","data":{"pane":"not an object"}}
emit {"event":"pane_closed","data":{"pane_id":42}}
emit $EV_A_IDLE
hold
EOF
  # Unreadable lines must not abort the stream — but also must not produce one
  # diagnosis per line: ONE per error class and connection.
  # That includes FORMALLY valid JSON with wrong types (event as a list, data as
  # a string, pane as a string, pane_id as a number): it may be ignored, but must
  # not terminate the watcher with AttributeError/TypeError.
  run_events stream a --max-lines 1 --timeout 10
  n="$(printf '%s\n' "$ERR" | grep -c 'unreadable line' | tr -d ' ')"
  ev_stop
  check T43 target "herd_events: unreadable/wrongly typed stream line ignored, ONE diagnosis" \
        "$EV_A_IDLE|0|1" "$OUT|$RC|$n"
fi

if should_run T44 target; then
  ev_start "$WORK/t44" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit {"event":"unknown.event","data":{}}
emit {"event":"unknown.event","data":{}}
emit $EV_FOREIGN
emit $EV_FOREIGN
emit {"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"p:new"}}}
emit $EV_A_IDLE
hold
EOF
  # Unknown type and foreign pane: ONE diagnosis each. pane_created belongs to
  # the replay burst after subscription_started and is KNOWN-irrelevant — it must
  # produce no diagnosis at all, otherwise stderr drowns with the real daemon.
  run_events stream a --max-lines 1 --timeout 10
  n1="$(printf '%s\n' "$ERR" | grep -c 'unknown event type' | tr -d ' ')"
  n2="$(printf '%s\n' "$ERR" | grep -c 'foreign pane' | tr -d ' ')"
  n3="$(printf '%s\n' "$ERR" | grep -c '^\[herd\]' | tr -d ' ')"
  ev_stop
  check T44 target "herd_events: unknown type/foreign pane ignored (1 diagnosis each), pane_created silent" \
        "$EV_A_IDLE|0|1|1|2" "$OUT|$RC|$n1|$n2|$n3"
fi

if should_run T45 target; then
  ev_start "$WORK/t45" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
reply ping {"type":"pong","version":"fake","protocol":17}
stream
hold
EOF
  # A silent stream is no proof of a healthy stream: after LIVENESS_SEC a ping
  # RPC fetches the sign of life. It must NOT trigger a false alarm (stdout stays
  # empty), and the time limit ends with 124.
  HERD_EVENTS_LIVENESS_SEC=0.2 run_events stream a --timeout 1
  pings="$(awk '$2 == "ping"' "$EV_LOG" | wc -l | tr -d ' ')"
  ev_stop
  ok=no; [ "${pings:-0}" -ge 2 ] && ok=yes
  check T45 target "herd_events: silent stream -> liveness ping without false alarm; time limit -> exit 124" \
        "|124|yes" "$OUT|$RC|$ok"
fi

if should_run T46 target; then
  ev_start "$WORK/t46" <<'EOF'
error agent.get agent_not_found no such agent
EOF
  # not_found BEFORE the start is a usage error (exit 1), not an event —
  # disappearing AFTER the start later becomes 'lost' (step B).
  run_events stream missing --timeout 5
  ev_stop
  check T46 target "herd_events: never-seen agent -> exit 1 (no event)" \
        "|1" "$OUT|$RC"
fi

# --- Resync edge cases (review step A: BLOCKER 1/2, MAJOR 1/4/5) -------------

if should_run T47 target; then
  ev_start "$WORK/t47" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_GET_A_SEQ9
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  # Discovery and control snapshot differ in the generation: a complete cycle
  # lay in the window between snapshot and subscribe. That MUST be noticed
  # (T29 equivalent) — the pane_id is stable, so it stays at ONE subscribe, no
  # rebuild.
  run_events stream a --max-lines 1 --timeout 10
  gap=no
  case "$ERR" in *"subscribe window (seq 3 -> 9)"*) gap=yes ;; esac
  subs="$(awk '$2 == "events.subscribe"' "$EV_LOG" | wc -l | tr -d ' ')"
  ev_stop
  check T47 target "herd_events: seq jump between discovery and control snapshot is reported" \
        "$EV_A_IDLE|0|yes|1" "$OUT|$RC|$gap|$subs"
fi

if should_run T48 target; then
  ev_start "$WORK/t48" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_GET_A_NEW_PANE
reply events.subscribe {"type":"subscription_started"}
stream
hold
stream
emit $EV_A2_IDLE
hold
EOF
  # The pane_id changes between discovery and control (pane newly created):
  # the fresh subscription already points at a dead pane. It MUST be discarded
  # and rebuilt completely with the new pane_id — otherwise the new pane stays
  # unobserved forever.
  run_events stream a --max-lines 1 --timeout 10
  n="$(awk '$2 == "events.subscribe"' "$EV_LOG" | wc -l | tr -d ' ')"
  sub2="$(awk '$2 == "events.subscribe" {print $3}' "$EV_LOG" | sed -n 2p)"
  ev_stop
  check T48 target "herd_events: pane_id change in the subscribe window -> complete re-subscribe" \
        "$EV_A2_IDLE|0|2|$EV_SUBS_A2" "$OUT|$RC|$n|$sub2"
fi

if should_run T49 target; then
  ev_start "$WORK/t49" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_A_GET
reply agent.get $EV_A_GET
error agent.get internal_error broken
reply events.subscribe {"type":"subscription_started"}
stream
drop
stream
hold
EOF
  # The first stream tears off; on reconnect discovery and subscribe succeed,
  # but the CONTROL snapshot fails. Then the resync counts as failed — and the
  # candidate stream must not keep running, otherwise a connection delivers
  # events into an observation that considers itself failed.
  #
  # Checked while the watcher is still RUNNING: at process end the operating
  # system closes every connection, a leak would be invisible afterwards.
  # (The test run with a deliberately omitted close() showed exactly that.)
  ( env PYTHONUTF8=1 HERD_EVENTS_ENDPOINT="tcp:127.0.0.1:$EV_PORT" \
      HERD_EVENTS_TICK_SEC=0.05 HERD_EVENTS_BACKOFF_SEC=0.05 \
      HERD_EVENTS_BACKOFF_MAX_SEC=0.2 HERD_EVENTS_RPC_TIMEOUT_SEC=5 \
      python3 "$EVENTS_PY" stream a --timeout 30 >"$WORK/t49out" 2>/dev/null ) &
  cl=$!
  i=0
  while [ "$(awk '$2 == "events.subscribe"' "$EV_LOG" | wc -l | tr -d ' ')" -lt 2 ] \
        && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  sub2="$(awk '$2 == "events.subscribe" {print $1}' "$EV_LOG" | sed -n 2p)"
  ev_wait_log "^${sub2:-none} close\$"
  closed=no
  grep -q "^${sub2:-none} close\$" "$EV_LOG" && closed=yes
  kill "$cl" 2>/dev/null || true; wait "$cl" 2>/dev/null || true
  got="$(cat "$WORK/t49out")"
  ev_stop
  check T49 target "herd_events: failed control snapshot closes the candidate stream" \
        "* monitor-unavailable|yes" "$got|$closed"
fi

if should_run T50 target; then
  ev_start "$WORK/t50" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_GET_A_NEW_PANE
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
drop
stream
emit $EV_A2_IDLE
hold
EOF
  # The discarded candidate still delivers one line AND then tears off. Both
  # carry its stream generation and must fizzle out: without this isolation a
  # delayed EOF reports the successor that was just built as failed (then the
  # first line would be '* monitor-unavailable') or an event of the dead pane
  # would be printed (then it would be the p:a event).
  run_events stream a --max-lines 1 --timeout 10
  ev_stop
  check T50 target "herd_events: line and EOF of a discarded stream generation fizzle out" \
        "$EV_A2_IDLE|0" "$OUT|$RC"
fi

if should_run T51 target; then
  ev_start "$WORK/t51a" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"pong"}
stream
hold
EOF
  # Taking any response with 'result' as a subscription confirmation would let
  # every protocol deviation pass. Exactly result.type 'subscription_started' is
  # required — otherwise protocol error.
  run_events stream a --timeout 10
  rc1=$RC
  protocol=no
  case "$ERR" in *subscription_started*) protocol=yes ;; esac
  ev_stop
  # Second case: the server does not know the method (no reply directive) and
  # answers with an error — likewise not a viable stream.
  ev_start "$WORK/t51b" <<EOF
reply agent.get $EV_A_GET
stream
hold
EOF
  run_events stream a --timeout 10
  rc2=$RC
  ev_stop
  check T51 target "herd_events: wrong/missing subscription_started response -> exit 2" \
        "2|yes|2" "$rc1|$protocol|$rc2"
fi

if should_run T52 target; then
  ev_start "$WORK/t52" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
error ping internal_error broken
stream
hold
EOF
  # Silent stream AND failing liveness ping: this is the case that a mere
  # "no events = all good" never sees. It must be reported as a global failure
  # so that the reconnect loop takes over.
  HERD_EVENTS_LIVENESS_SEC=0.2 run_events stream a --max-lines 1 --timeout 10
  reason=no
  case "$ERR" in *"liveness ping failed"*) reason=yes ;; esac
  ev_stop
  check T52 target "herd_events: failed liveness ping -> '* monitor-unavailable'" \
        "* monitor-unavailable|0|yes" "$OUT|$RC|$reason"
fi

if should_run T53 target; then
  ev_start "$WORK/t53" <<'EOF'
mute ping 0.005 {"event":"pane_created","data":{}}
EOF
  # The daemon NEVER answers, but keeps sending irrelevant lines. A minimum
  # budget per read would thus start new reads endlessly and the RPC timeout
  # would be ineffective — the watcher would hang forever (the test runner then
  # kills it after 20 s with 137).
  HERD_EVENTS_RPC_TIMEOUT_SEC=1 run_events ping
  ev_stop
  check T53 target "herd_events: RPC timeout applies despite continuous fire of foreign lines" \
        "|2" "$OUT|$RC"
fi

if should_run T54 target; then
  # Permanent garbage on the stream, plus a failing ping. If EVERY received line
  # shifted the liveness deadline, the ping would never get its turn and the
  # failure would stay undetected (end then via time limit, exit 124).
  # The garbage must run LONGER than the observation (200 x 0.02 s = ~4 s with
  # --timeout 2), otherwise the silence after the last garbage would still
  # trigger the ping afterwards and the test would be blind.
  # Fixture first into a file, then via redirection: a PIPE to ev_start would run
  # in a subshell, and EV_PORT/EV_PID would never come back.
  { echo "reply agent.get $EV_A_GET"
    echo 'reply events.subscribe {"type":"subscription_started"}'
    echo 'error ping internal_error broken'
    echo stream
    i=0
    while [ "$i" -lt 200 ]; do echo 'raw muell'; echo 'sleep 0.02'; i=$((i + 1)); done
    echo hold
  } > "$WORK/t54.fixture"
  ev_start "$WORK/t54" < "$WORK/t54.fixture"
  HERD_EVENTS_LIVENESS_SEC=0.3 run_events stream a --max-lines 1 --timeout 2
  ev_stop
  check T54 target "herd_events: garbage lines do not shift the liveness deadline" \
        "* monitor-unavailable|0" "$OUT|$RC"
fi

# ------------------------------------- Reporting rules (herd_state.py, step B) ---
# T60 bundles the unit tests of the PURE state machine into ONE test case.
# They need neither fake herdr nor fake event server: no IO, no real clock, no
# wait time — only event/tick sequences against expected reports, commands and
# abort decisions. Which contract case (T number) is modelled where is stated in
# tests/test_state_machine.py.
if should_run T60 target; then
  # PYTHONDONTWRITEBYTECODE: importing herd_state would otherwise create
  # __pycache__ in the working tree (the repo has no .gitignore).
  out="$(cd "$ROOT" && timeout --signal=KILL 60 env PYTHONUTF8=1 \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 -m unittest discover -s tests -p 'test_state_machine.py' 2>&1)"
  rc=$?
  # Also check the count: an empty discovery likewise reports exit 0 and would be
  # a green test that tests nothing.
  ran="$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | head -1)"
  ok=no; [ "${ran:-0}" -ge 40 ] && ok=yes
  # On failures show the unittest output — otherwise only "0|yes != 1|yes" stands there.
  [ "$rc" = 0 ] && [ "$ok" = yes ] || printf '%s\n' "$out" | tail -25
  check T60 target "herd_state: reporting rules as pure event/tick sequences" \
        "0|yes" "$rc|$ok"
fi

# ------------------------------------ Adapter + watch CLI (step C) -----------
# T70+: the wiring of event loop (step A) and reporting rules (step B) into the
# watch contract. Two levels:
#
#   T70/T71  the INTERNAL herd.sh verbs (classify-pane, stall-fingerprint) —
#            single source of the pane heuristics, against the fake herdr.
#   T72+     `herd_events.py watch` against the fake EVENT server, with the REAL
#            herd.sh for the verbs (fake herdr in PATH). This runs the complete
#            path event -> reporting rule -> command -> verb -> report.
#
# Deliberately fixture-driven instead of timing-heavy: the events come from the
# server script, the clocks (quiet window, remaining poll, stall unit, minute)
# are set to fractions of a second via env. The known Windows flakes
# T11/T22/T30 hang exactly on real wait times in the poll path.

if should_run T70 target; then
  fixture_dir "t70"
  pane_text a "Do you want to proceed?"
  pane_text b "usage limit reached"
  pane_text c "please sign in to continue"
  pane_text d "plain normal output"
  run_herd classify-pane p:a; r1="$OUT|$RC"
  run_herd classify-pane p:b; r2="$OUT|$RC"
  run_herd classify-pane p:c; r3="$OUT|$RC"
  run_herd classify-pane p:d; r4="$OUT|$RC"
  # A read error MUST be exit != 0 and must NOT pass as 'clean': otherwise an
  # unreadable pane (which may show an approval dialog) would be reported as
  # confirmed completion — and that is terminal.
  touch "$FAKE_HERDR_DIR/.down"
  run_herd classify-pane p:d; r5="$OUT|$RC"
  check T70 target "classify-pane: blocked/limited/auth/clean; read error -> exit 1 (not clean)" \
        "blocked|0/limited|0/auth|0/clean|0/|1" "$r1/$r2/$r3/$r4/$r5"
fi

if should_run T71 target; then
  fixture_dir "t71"
  # Braille spinner and elapsed timer change constantly, even if the agent
  # hangs — the fingerprint must strip them (otherwise it would NEVER find a
  # stall). Real new text, however, must come through.
  pane_text a "$(printf 'arbeit \xe2\xa0\x8b laeuft 1m 23s')"
  run_herd stall-fingerprint p:a
  fp1="$(printf '%s' "$OUT" | sed -n 1p)"; lim1="$(printf '%s' "$OUT" | sed -n 2p)"
  pane_text a "$(printf 'arbeit \xe2\xa0\x99 laeuft 2m 47s')"
  run_herd stall-fingerprint p:a; fp2="$(printf '%s' "$OUT" | sed -n 1p)"
  pane_text a "$(printf 'arbeit \xe2\xa0\x99 laeuft 2m 47s\nneuer schritt')"
  run_herd stall-fingerprint p:a; fp3="$(printf '%s' "$OUT" | sed -n 1p)"
  # limited belongs in the SAME call: backends with self-retry stay permanently
  # 'working' at the usage limit, a second roundtrip would be waste.
  pane_text a "usage limit reached, retrying in 3h"
  run_herd stall-fingerprint p:a; lim2="$(printf '%s' "$OUT" | sed -n 2p)"
  shape=no; case "$fp1" in "fp "*) shape=yes ;; esac
  same=no; [ "$fp1" = "$fp2" ] && same=yes
  differs=no; [ "$fp2" != "$fp3" ] && differs=yes
  check T71 target "stall-fingerprint: spinner/timer normalized, real progress visible, limited flag" \
        "yes|yes|yes|limited no|limited yes" "$shape|$same|$differs|$lim1|$lim2"
  # Locale robustness: under C.UTF-8 GNU sed split the range [⠀-⣿]
  # and returned a CONSTANT fingerprint at RC 0. Two texts that differ
  # only in the spinner must have the same hash.
  pane_text a "$(printf 'arbeit \xe2\xa0\x8b laeuft 1m 23s')"
  LC_ALL=C.UTF-8 run_herd stall-fingerprint p:a
  fpC1="$(printf '%s' "$OUT" | sed -n 1p)"; rcC=$RC; errC="$ERR"
  pane_text a "$(printf 'arbeit \xe2\xa0\x99 laeuft 1m 23s')"
  LC_ALL=C.UTF-8 run_herd stall-fingerprint p:a
  fpC2="$(printf '%s' "$OUT" | sed -n 1p)"
  pane_text a "$(printf 'arbeit \xe2\xa0\x99 laeuft 1m 23s\nneuer schritt')"
  LC_ALL=C.UTF-8 run_herd stall-fingerprint p:a
  fpC3="$(printf '%s' "$OUT" | sed -n 1p)"
  shapeC=no; case "$fpC1" in "fp "*) shapeC=yes ;; esac
  sameC=no; [ "$fpC1" = "$fpC2" ] && sameC=yes
  differsC=no; [ "$fpC2" != "$fpC3" ] && differsC=yes
  sed_err=no; case "$errC" in *"Invalid collation"*) sed_err=yes ;; esac
  empty=no; [ -z "$errC" ] && empty=yes
  check T71b target "stall-fingerprint under LC_ALL=C.UTF-8: spinner strip, stderr empty" \
        "0|yes|yes|yes|yes|no" "$rcC|$shapeC|$sameC|$differsC|$empty|$sed_err"
fi


# run_watch <args…> — `herd_events.py watch` against the fake event server, with
# the REAL herd.sh (HERD_SH) for classify-pane/stall-fingerprint/explain-status
# and the fake herdr in PATH. Sets OUT, ERR, RC.
# All clocks small and overridable via env: quiet window, remaining poll,
# command deadline/retry as well as the units of --stall-timeout
# (HERD_STALL_UNIT, as in herd_events.py) and --timeout (HERD_EVENTS_MINUTE_SEC).
# WATCH_KILL = hard upper bound of the call (SIGKILL, exit 137). Set small, it
# proves that the watcher keeps its own deadlines: if the main loop blocks, 137
# comes instead of the expected exit code.


if should_run T72 target; then
  fixture_dir "t72"
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t72ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  # Full cycle with DIALOG CROSS-CHECK: herdr reports only idle (it does not know
  # approval dialogs). Only classify-pane at the end of the quiet window turns
  # that into 'blocked'. Additionally checked: the action instruction on stderr
  # comes from herd.sh (explain-status), not from a copy in Python.
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  dialog=no; case "$ERR" in *"is BLOCKED"*) dialog=yes ;; esac
  check T72 target "watch: idle + dialog pane -> 'a blocked' (cross-check), explanation from herd.sh" \
        "a blocked|0|yes" "$OUT|$RC|$dialog"
fi

if should_run T73 target; then
  fixture_dir "t73"
  pane_text a "plain normal output"
  ev_start "$WORK/t73ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  # The same path with an inconspicuous pane: 'clean' -> completion is reported,
  # the agent is terminal and watch ends BY ITSELF with exit 0 —
  # without --max-events and without a time limit.
  run_watch a --stall-timeout 0
  ev_stop
  end=no; case "$ERR" in *"all observed agents are done"*) end=yes ;; esac
  check T73 target "watch: idle + clean pane -> 'a idle', then end by itself (exit 0)" \
        "a idle|0|yes" "$OUT|$RC|$end"
fi

if should_run T185 target; then
  fixture_dir "t185"
  fixture a idle
  fixture_kind a claude
  # 2026-10-08: turn finished, leftover shell. After
  # HERD_EVENTS_BG_MAX_SEC comes ONE line 'a background' (instead of silence up
  # to the busy cap), together with the action instruction from herd.sh.
  pane_text a "DONE: package implemented.
✻ Worked for 4m 12s · done 21:04
❯ 
  ⏵⏵ accept edits on · 1 shell · ← for agents"
  ev_start "$WORK/t185ev" <<EOF2
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF2
  HERD_EVENTS_BG_MAX_SEC=0.5 run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  hint=no; case "$ERR" in *"background shells/monitors are still running"*) hint=yes ;; esac
  check T185 target "watch: claude with leftover shell -> 'a background' after a short cap" \
        "a background|0|yes" "$OUT|$RC|$hint"
fi

if should_run T74 target; then
  fixture_dir "t74"
  pane_text a "arbeitet"
  ev_start "$WORK/t74ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
sleep 0.1
drop
stream
hold
EOF
  # T9/T31 equivalent: the stream tear-down is a GLOBAL event ("*"), not a state
  # statement — and BOTH reports count against --max-events. They now come from
  # the StateMachine (previously the monitor emitted them itself and thus
  # bypassed the count and the reporting lock).
  run_watch a --stall-timeout 0 --max-events 2
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  reason=no; case "$ERR" in *"MONITORING FAILED"*) reason=yes ;; esac
  check T74 target "watch: tear-down/reconnect -> '* monitor-unavailable'/'-restored', count against --max-events" \
        "* monitor-unavailable;* monitor-restored|0|yes" "$got|$RC|$reason"
fi

if should_run T75 target; then
  fixture_dir "t75"
  pane_text a "unveraenderlich"
  ev_start "$WORK/t75ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  # T11/T22 equivalent, but WITHOUT event pressure: the agent stays working, the
  # stream is silent. Only the verification remaining poll (stall-fingerprint)
  # finds the silent hang. And it must LATCH: without a latch the state falls
  # back to working between two fingerprint checks (reported as all-clear) and
  # then to stalled again — endless flapping. Therefore exactly ONE line is
  # checked over the whole runtime; the end comes via time limit (the agent keeps
  # hanging, so watch does not end by itself).
  # HERD_EVENTS_VERIFY_SEC deliberately EMPTY: that makes the derivation from
  # --poll apply (0.02 s * 15 = 0.3 s) and the test also proves that --poll in the
  # event path controls exactly this one clock (plan, design decision 3).
  HERD_STALL_UNIT=1 HERD_EVENTS_MINUTE_SEC=1 HERD_EVENTS_VERIFY_SEC= \
    run_watch a --stall-timeout 1 --timeout 4 --poll 0.02
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T75 target "watch: silent hang -> 'a stalled', latched (no flapping), time limit 124" \
        "a stalled|124" "$got|$RC"
fi

if should_run T76 target; then
  fixture_dir "t76"
  # The internal verb fails (here: not runnable at all). The adapter MUST turn
  # that into on_command_failed — exactly ONE response per command. Without this
  # response duty the quiet window would stay in _PHASE_AWAIT forever and the
  # observation would hang silently. Reported is 'unknown' (action state, NOT
  # terminal), never an unconfirmed completion.
  printf '#!/bin/sh\necho "stub: pane not readable" >&2\nexit 1\n' > "$WORK/t76stub"
  chmod +x "$WORK/t76stub"
  ev_start "$WORK/t76ev" <<EOF
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  HERD_SH="$WORK/t76stub" run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  diag=no; case "$ERR" in *"classify-pane failed"*) diag=yes ;; esac
  fallback=no; case "$ERR" in *"not classifiable"*) fallback=yes ;; esac
  check T76 target "watch: failed verb -> on_command_failed, retry, then 'unknown' (no hang)" \
        "a unknown|0|yes|yes" "$OUT|$RC|$diag|$fallback"
fi

if should_run T77 target; then
  fixture_dir "t77"
  pane_text a "plain normal output"
  ev_start "$WORK/t77ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_CLOSED
sleep 0.3
emit $EV_A_IDLE
hold
EOF
  # After events.subscribe the daemon also delivers PAST pane_closed events
  # (finding step A). A naive 'lost' would be a false alarm — and 'lost' means
  # "work counts as NOT done". Only the agent.get cross-check decides: here the
  # agent lives (third agent.get response = the repeated last one), so NO lost
  # may be reported, and the later completion arrives normally.
  run_watch a --stall-timeout 0
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T77 target "watch: replayed pane_closed -> agent.get cross-check, NO lost" \
        "a idle|0" "$got|$RC"
fi

if should_run T78 target; then
  fixture_dir "t78"
  pane_text a "arbeitet"
  ev_start "$WORK/t78ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_A_GET
error agent.get agent_not_found no such agent
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_CLOSED
hold
EOF
  # The same path, but the cross-check CONFIRMS the disappearance (third
  # agent.get response: agent_not_found). Only now 'lost' — terminal, so watch
  # ends by itself afterwards.
  run_watch a --stall-timeout 0
  ev_stop
  gone=no; case "$ERR" in *"is GONE"*) gone=yes ;; esac
  check T78 target "watch: confirmed pane_closed -> 'a lost' (terminal, exit 0)" \
        "a lost|0|yes" "$OUT|$RC|$gone"
fi

if should_run T79 target; then
  fixture_dir "t79"
  pane_text a "arbeitet"
  ev_start "$WORK/t79ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  # A time limit is NOT a result: exit 124, stdout empty, and the hint MUST name
  # duration and restart (the agents keep running). The watcher adds both — the
  # StateMachine knows neither minutes nor names.
  HERD_EVENTS_MINUTE_SEC=1 run_watch a --stall-timeout 0 --timeout 1
  ev_stop
  duration=no; case "$ERR" in *"TIMEOUT after 1min"*) duration=yes ;; esac
  resume=no; case "$ERR" in *"Resume: herd.sh watch a"*) resume=yes ;; esac
  check T79 target "watch: --timeout -> exit 124 with duration and restart hint" \
        "|124|yes|yes" "$OUT|$RC|$duration|$resume"
fi

if should_run T80 target; then
  fixture_dir "t80"
  # Usage errors end BEFORE every connection attempt with exit 2 — therefore this
  # case needs no server (port 1). The cases are the same ones the dispatcher
  # checks up front in herd.sh (T17/T26/T27): from step D on they thus cover
  # every engine, but the watcher is also directly callable.
  EV_PORT=1
  run_watch --stall-timeout 0;               rc1=$RC
  run_watch a a --stall-timeout 0;           rc2=$RC
  run_watch a --timeout 08;                  rc3=$RC
  run_watch a --poll 0;                      rc4=$RC
  run_watch a --quatsch;                     rc5=$RC
  check T80 target "watch (Python): no name / duplicate / leading zero / --poll 0 / unknown option -> exit 2" \
        "2|2|2|2|2" "$rc1|$rc2|$rc3|$rc4|$rc5"
fi

if should_run T82 target; then
  fixture_dir "t82"
  pane_text a "Do you want to proceed?"
  pane_text b "plain normal output"
  # The agent.get queue is PER METHOD: the order must match the call order
  # (discovery a, discovery b, control a, control b). Only that way does every
  # agent get ITS pane_id — a swapped pair would map both agents to the same pane.
  ev_start "$WORK/t82ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.4
emit $EV_B_IDLE
hold
EOF
  # T6/T7 equivalent: two agents, two panes. a lands in the dialog (blocked,
  # NOT terminal — watch must not end afterwards), b finishes. Both events must
  # arrive, each assigned to the RIGHT name (the pane_id -> agent mapping is done
  # by the adapter from the resync snapshot).
  # Compared sorted: which of the two command responses comes back first is
  # decided by two parallel subprocesses — not part of the contract and otherwise
  # a time race in the test (like T16).
  run_watch a b --stall-timeout 0 --max-events 2
  ev_stop
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  subs="$(awk '$2 == "events.subscribe" {print $3}' "$EV_LOG")"
  check T82 target "watch: two agents, correct pane mapping, no end at the first event" \
        "a blocked;b idle;|0|$EV_SUBS_AB" "$got|$RC|$subs"
fi

if should_run T81 target; then
  fixture_dir "t81"
  ev_start "$WORK/t81ev" <<'EOF'
error agent.get agent_not_found no such agent
EOF
  # Invariant 5, in the watch verb: a name that NEVER existed is a usage error
  # (exit 1) and NOT an event — if an agent disappears later, that is 'lost'
  # (T78). Without this separation watch would keep running forever on a typo
  # without ever reporting anything.
  run_watch missing --stall-timeout 0
  ev_stop
  never=no; case "$ERR" in *"unknown agents: missing"*) never=yes ;; esac
  check T81 target "watch: never-seen agent -> exit 1, no event" \
        "|1|yes" "$OUT|$RC|$never"
fi

# --- Step C review: TOCTOU, explanation thread, adapter races -----------------

if should_run T83 target; then
  fixture_dir "t83"
  pane_text a "Do you want to proceed?"
  # The pane disappears AFTER the first read. Anyone checking the three pattern
  # lists with a separate read each gets an error from the second read on, reads
  # "no pattern" from it and prints `clean` — a confirmed completion for a pane
  # that is no longer readable (step C review MAJOR 1). Exactly ONE read per call
  # makes that impossible; the read counter proves it.
  printf '2\n' > "$FAKE_HERDR_DIR/readfail.a"
  run_herd classify-pane p:a
  v1="$OUT|$RC"; n1="$(cat "$FAKE_HERDR_DIR/.rcount.a")"
  fixture_dir "t83b"
  pane_text a "usage limit reached"
  printf '2\n' > "$FAKE_HERDR_DIR/readfail.a"
  # stall-fingerprint has the same pattern: a second read for the
  # limited check could fail and return "limited no" — that is "no limit"
  # instead of "not read".
  run_herd stall-fingerprint p:a
  v2="$(printf '%s' "$OUT" | sed -n 2p)|$RC"; n2="$(cat "$FAKE_HERDR_DIR/.rcount.a")"
  check T83 target "classify-pane/stall-fingerprint: ONE read per call (later read error cannot become 'clean'/'no')" \
        "blocked|0|1|limited yes|0|1" "$v1|$n1|$v2|$n2"
fi

if should_run T84 target; then
  fixture_dir "t84"
  # Error contract of the third internal verb: missing arguments are a usage
  # error; a state WITH an action instruction writes it to stderr and leaves
  # stdout empty (stdout is the report stream!); a state without an instruction
  # is not an error.
  run_herd explain-status;           rc1=$RC
  run_herd explain-status a;         rc2=$RC
  run_herd explain-status a blocked
  b="$OUT|$RC"; hint=no; case "$ERR" in *"is BLOCKED"*) hint=yes ;; esac
  run_herd explain-status a idle
  i="$OUT|$RC|$ERR"
  check T84 target "explain-status: missing arguments -> exit 2; instruction only on stderr, stdout empty" \
        "2|2||0|yes||0|" "$rc1|$rc2|$b|$hint|$i"
fi

if should_run T85 target; then
  fixture_dir "t85"
  # explain-status HANGS. It must not stop the timed main loop
  # (step C review MAJOR 2): the report line appears immediately, the explanation
  # runs in its own thread with a SHORT deadline, and --timeout must fire on time.
  # Proof via WATCH_KILL: if the loop blocks in the bash start, the call ends with
  # 137 instead of 124.
  watch_stub "$WORK/t85stub" blocked "/bin/sleep 10"
  ev_start "$WORK/t85ev" <<EOF
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  WATCH_KILL=5 HERD_SH="$WORK/t85stub" HERD_EVENTS_MINUTE_SEC=1 \
    HERD_EVENTS_EXPLAIN_TIMEOUT_SEC=0.3 run_watch a --stall-timeout 0 --timeout 2
  ev_stop
  diag=no; case "$ERR" in *"explain-status hangs"*) diag=yes ;; esac
  check T85 target "watch: hanging explain-status does not block the loop (time limit on time, diagnosis)" \
        "a blocked|124|yes" "$OUT|$RC|$diag"
fi

if should_run T86 target; then
  fixture_dir "t86"
  # explain-status fails with exit code != 0. That MUST become visible (otherwise
  # every report lacks its action instruction without anyone noticing) —
  # and the report line itself stays unaffected.
  watch_stub "$WORK/t86stub" blocked 'echo "stub broken" >&2; exit 3'
  ev_start "$WORK/t86ev" <<EOF
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  HERD_SH="$WORK/t86stub" run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  diag=no; case "$ERR" in *"explain-status 'a blocked': exit 3"*) diag=yes ;; esac
  check T86 target "watch: explain-status with exit != 0 is diagnosed, report line stays" \
        "a blocked|0|yes" "$OUT|$RC|$diag"
fi

if should_run T87 target; then
  fixture_dir "t87"
  # STRAGGLER response of a worker (step C review MAJOR 3a): the first
  # classify-pane needs 1.5 s and answers 'blocked'. While it runs, the raw
  # status changes to working — the quiet window is thereby discarded and the
  # generation switched. The old response MUST fizzle out: otherwise the watcher
  # reports a dialog that never existed (step B correlation, here at the REAL
  # asynchronous adapter boundary). Afterwards the cycle runs through normally.
  # The second call answers 'clean' immediately — switching via the marker.
  cat > "$WORK/t87stub" <<EOF
#!/bin/sh
case "\$1" in
  classify-pane)
    if [ ! -f "$WORK/t87.mark" ]; then : > "$WORK/t87.mark"; /bin/sleep 1.5; echo blocked
    else echo clean; fi ;;
  stall-fingerprint) echo "fp 1 1"; echo "limited no"; echo "failed no" ;;
  explain-status)    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$WORK/t87stub"
  ev_start "$WORK/t87ev" <<EOF
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
sleep 0.5
emit $EV_A_WORKING
sleep 1.5
emit $EV_A_IDLE
hold
EOF
  # The command deadline (5 s) does NOT expire — that is intentional: the
  # adapter's subprocess budget lies constructively below the StateMachine's
  # deadline, so a delayed SUCCESS response can only arise from a state change.
  # Exactly that is checked here.
  HERD_SH="$WORK/t87stub" run_watch a --stall-timeout 0
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  stale=no; case "$ERR" in *discarded*) stale=yes ;; esac
  check T87 target "watch: straggler response after status change fizzles out (no phantom 'blocked')" \
        "a idle|0|yes" "$got|$RC|$stale"
fi

if should_run T88 target; then
  fixture_dir "t88"
  pane_text a "arbeitet"
  ev_start "$WORK/t88ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_A_GET
reply agent.get $EV_GET_A_BLOCKED
reply agent.get $EV_GET_A_BLOCKED
reply events.subscribe {"type":"subscription_started"}
stream
sleep 0.1
drop
stream
hold
EOF
  # ORDER after a tear-down (step C review MAJOR 3b): the control snapshot this
  # time delivers a REPORTABLE state (raw 'blocked' — an action state that is
  # reported immediately without a quiet window). The stdout sequence must be
  # exact: first the failure, then the restoration, THEN the state. If
  # 'monitor-restored' were reported only after the resync, the agent report
  # would stand before it — a monitor consumer would see a state from a time it
  # still considers failed.
  run_watch a --stall-timeout 0 --max-events 3
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T88 target "watch: order after tear-down — unavailable, restored, THEN agent report" \
        "* monitor-unavailable;* monitor-restored;a blocked|0" "$got|$RC"
fi

if should_run T89 target; then
  fixture_dir "t89"
  # DEFENSIVE stdout diagnosis of the adapter (open MINOR from
  # docs/review-step-c-verify.md). T84 proves that the REAL explain-status keeps
  # the contract; here a stub deliberately BREAKS it and writes to stdout. The
  # Python adapter must discard this output — stdout is the report stream, a
  # foreign line there would become a notification without an event at the
  # monitor consumer — and diagnose the breach visibly (discarding silently would
  # mean permanently covering up a contract violation).
  watch_stub "$WORK/t89stub" blocked 'echo "I do not belong in the report stream"'
  ev_start "$WORK/t89ev" <<EOF
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  HERD_SH="$WORK/t89stub" run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  diag=no; case "$ERR" in *"writes to stdout"*) diag=yes ;; esac
  # OUT is compared EXACTLY: if the stub line had slipped through, it would
  # stand here as the second line.
  check T89 target "watch: explain-status on stdout is discarded and diagnosed" \
        "a blocked|0|yes" "$OUT|$RC|$diag"
fi

# ------------------------------------------ Dispatcher / engine choice (step D) --
# T90+: `herd.sh watch` is a DISPATCHER. Checked is the switch itself —
# not the reporting rules again (T72+). auto and events are identical
# (event path); poll -> exit 2 (stage 4). Without event API: hard exit 2.

# run_dispatch <engine> <endpoint> <watch arguments…> — `herd.sh watch` with a
# fixed engine and event endpoint; sets OUT, ERR, RC. Both fakes are reachable at
# the same time (CLI in PATH, event server via HERD_EVENTS_ENDPOINT).


if should_run T90 target; then
  #   poll          -> exit 2 (path removed, stage 4)
  #   events + API  -> event path
  #   auto + API    -> event path (identical to events)
  #   auto without API -> hard exit 2, no fallback
  fixture_dir "t90a"
  fixture a blocked
  pane_text a "plain normal output"
  run_dispatch poll "tcp:127.0.0.1:1" a --stall-timeout 0 --max-events 1
  r1="$OUT|$RC"
  poll_gone=no; case "$ERR" in *"poll path was removed on 2026-09-09"*) poll_gone=yes ;; esac
  dispatch_fixtures "$WORK/t90b"
  run_dispatch events "tcp:127.0.0.1:$EV_PORT" a --stall-timeout 0 --max-events 1
  r2="$OUT|$RC"
  ev_stop
  dispatch_fixtures "$WORK/t90c"
  run_dispatch auto "tcp:127.0.0.1:$EV_PORT" a --stall-timeout 0 --max-events 1
  r3="$OUT|$RC"
  ev_stop
  fixture_dir "t90d"
  fixture a blocked
  pane_text a "plain normal output"
  run_dispatch auto "tcp:127.0.0.1:1" a --stall-timeout 0 --max-events 1
  r4="$OUT|$RC"
  hard=no; case "$ERR" in *"event API not available"*) hard=yes ;; esac
  fallback=yes; case "$ERR" in *"Poll-Fallback"*) fallback=no ;; esac
  preflight=no; case "$ERR" in *"herdr >= 0.8.2"*|*"python3"*) preflight=yes ;; esac
  check T90 target "watch dispatcher: poll exit 2; events/auto with API equal; auto without API hard exit 2" \
        "|2|yes/a idle|0/a idle|0/|2|yes|yes|yes" "$r1|$poll_gone/$r2/$r3/$r4|$hard|$fallback|$preflight"
fi

if should_run T90s target; then
  # herd.sh called via a symlink (e.g. ~/bin/herd.sh -> <skill>/scripts/herd.sh)
  # must still find its helpers next to the real file; before the fix watch
  # ended with "watcher missing: <symlink dir>/herd_events.py".
  mkdir -p "$WORK/t90s-bin"
  ln -sf "$ROOT/scripts/herd.sh" "$WORK/t90s-bin/herd.sh"
  dispatch_fixtures "$WORK/t90s"
  HERD_REAL="$HERD"; HERD="$WORK/t90s-bin/herd.sh"
  run_dispatch events "tcp:127.0.0.1:$EV_PORT" a --stall-timeout 0 --max-events 1
  HERD="$HERD_REAL"
  ev_stop
  missing=no; case "$ERR" in *"watcher missing"*) missing=yes ;; esac
  check T90s target "watch via a symlinked herd.sh finds herd_events.py" \
        "a idle|0|no" "$OUT|$RC|$missing"
fi

if should_run T91 target; then
  fixture_dir "t91"
  fixture a blocked
  pane_text a "plain normal output"
  # HERD_WATCH_ENGINE=events is a FORCE (plan review MAJOR 3): if the
  # event API is missing, watch MUST end with exit 2. A silent poll fallback would
  # be the error here — precisely in the mode pinned down for diagnosis it would
  # swallow the finding. stdout stays empty: the report stream must not contain a
  # line from the old path.
  run_dispatch events "tcp:127.0.0.1:1" a --stall-timeout 0 --max-events 1
  hard="$OUT|$RC"
  reason=no; case "$ERR" in *"HERD_WATCH_ENGINE=events"*) reason=yes ;; esac
  fallback=yes; case "$ERR" in *"Poll-Fallback"*) fallback=no ;; esac
  # A typo in the engine is a usage error, not a reason to silently choose
  # one of the two engines.
  run_dispatch Poll "tcp:127.0.0.1:1" a --stall-timeout 0
  typo="$OUT|$RC"
  check T91 target "watch dispatcher: HERD_WATCH_ENGINE=events fails hard (no silent fallback); nonsense -> exit 2" \
        "|2|yes|yes/|2" "$hard|$reason|$fallback/$typo"
fi

if should_run T92 target; then
  # T17/T26/T27 in auto|events. The validation (name/timeout/duplicate) lies
  # before the switch; --poll 0 is rejected by Python. The same exit codes in both.
  # The `events` mode runs against a REACHABLE fake server: only that way is it
  # proven that bash aborts instead of delegating. The fake would return the
  # response for 'a' to `agent.get missing` (queue per method) — the watcher alone
  # would therefore NOT find the typo.
  dispatch_fixtures "$WORK/t92"
  ep="tcp:127.0.0.1:$EV_PORT"
  run_dispatch events "$ep" a missing --stall-timeout 0; e1=$RC   # T17
  run_dispatch events "$ep" a --timeout 08;              e2=$RC   # T26
  run_dispatch events "$ep" a a --stall-timeout 0;       e3=$RC   # T27
  run_dispatch events "$ep" a --poll 0 --stall-timeout 0; e4=$RC  # T27
  run_dispatch auto "$ep" a missing --stall-timeout 0;   a1=$RC
  run_dispatch auto "$ep" a --timeout 08;                a2=$RC
  run_dispatch auto "$ep" a a --stall-timeout 0;         a3=$RC
  run_dispatch auto "$ep" a --poll 0 --stall-timeout 0;  a4=$RC
  ev_stop
  check T92 target "watch dispatcher: validation (unknown name / timeout / duplicate / --poll 0) before the switch — equal in auto|events" \
        "1|2|2|2 == 1|2|2|2" "$e1|$e2|$e3|$e4 == $a1|$a2|$a3|$a4"
fi

if should_run T93 target; then
  # THE actual preview case: the daemon LIVES and answers ping, but does not know
  # `events.subscribe` (older or future version). A mere reachability check would
  # be green here and the watcher would fail only AFTER the exec — in the middle
  # of an observation that the caller considers running. That is why the feature
  # detection checks both.
  fixture_dir "t93"
  fixture a blocked
  pane_text a "plain normal output"
  ev_start "$WORK/t93ev" <<'EOF'
reply ping {"type":"pong","version":"fake","protocol":17}
error events.subscribe unknown_method no such method
EOF
  ep="tcp:127.0.0.1:$EV_PORT"
  run_dispatch auto "$ep" a --stall-timeout 0 --max-events 1
  r1="$OUT|$RC"
  reason1=no; case "$ERR" in *unknown_method*) reason1=yes ;; esac
  run_dispatch events "$ep" a --stall-timeout 0 --max-events 1
  r2="$OUT|$RC"
  reason2=no; case "$ERR" in *unknown_method*) reason2=yes ;; esac
  ev_stop
  check T93 target "watch dispatcher: ping ok, but events.subscribe rejected -> auto and events fail hard" \
        "|2|yes/|2|yes" "$r1|$reason1/$r2|$reason2"
fi

# --------------------------------------- Shutdown path of the transport ------
# T94 bundles tests/test_stream_close.py: the regression to the MAJOR finding of
# the step D E2E (watcher does not terminate on a silent stream — `close()` of a
# Windows pipe waits for the io lock of the running read). The case needs a
# transport whose close() BLOCKS; over TCP that does not exist, so a fake conn
# stands there instead of the fake server. The real pipe proof remains manual
# (docs/step-d-e2e.md).
if should_run T94 target; then
  out="$(cd "$ROOT" && timeout --signal=KILL 120 env PYTHONUTF8=1 \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 -m unittest discover -s tests -p 'test_stream_close.py' 2>&1)"
  rc=$?
  ran="$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | head -1)"
  ok=no; [ "${ran:-0}" -ge 5 ] && ok=yes
  [ "$rc" = 0 ] && [ "$ok" = yes ] || printf '%s\n' "$out" | tail -25
  check T94 target "transport: blocking close() stops neither process end nor main loop" \
        "0|yes" "$rc|$ok"
fi


# ------------------------- muse 1.3.0: raw blocked + pane cross-check -------
# Spec .herd/spec-muse13-blocked.md, stage 2 (end to end over the real event
# path). herdr reports raw `blocked` during muse's built-in command check
# ("Reviewing approval request", not a dialog); watch must not report that
# immediately. A real dialog stays blocked.

if should_run T179 target; then
  # T179a: muse + reviewing-approval -> no `a blocked`; the later
  # completion (calm pane) is reported.
  fixture_dir "t179a"
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/reviewing-approval.txt")"
  pane_after a "⟩ What should I do?"$'\n'"  muse-spark-1.3  ·  /t/c/scratchpad"
  ev_start "$WORK/t179a-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get {"type":"agent_info","agent":{"name":"a","agent_status":"blocked","pane_id":"p:a","state_change_seq":3,"agent":"muse"}}
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_BLOCKED
sleep 0.5
emit $EV_A_WORKING
sleep 0.1
emit $EV_A_IDLE
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  saw_blocked=no; case "$OUT" in *"a blocked"*) saw_blocked=yes ;; esac
  check T179a target "watch events: muse + reviewing-approval -> no blocked, then a idle" \
        "a idle|0|no" "$OUT|$RC|$saw_blocked"

  # T179b: muse + real dialog -> `a blocked` reported immediately.
  fixture_dir "t179b"
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/dialog-approval.txt")"
  ev_start "$WORK/t179b-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get {"type":"agent_info","agent":{"name":"a","agent_status":"blocked","pane_id":"p:a","state_change_seq":3,"agent":"muse"}}
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_BLOCKED
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  check T179b target "watch events: muse + dialog-approval -> a blocked" \
        "a blocked|0" "$OUT|$RC"
fi

# ------------------------------------- Question marker `question` (T180+) --
# A delegated agent asks a question by writing the question into a file and
# ending the turn with the line `QUESTION: <absolute path>`. classify_text turns
# that into `question` if the path is absolute AND the file exists as a regular
# file; busy and an open dialog take precedence.
# Reference cases (a)-(f) and error paths are listed individually below; the
# expectations follow the contract (SKILL.md, §9 Agent questions).

if should_run T180 target; then
  fixture_dir "t180"
  fixture a idle
  qdir="$WORK/t180/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  # (a) Marker at the end, file exists -> question (classify-pane AND status).
  pane_text a "report done"$'\n'"QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; ca="$OUT|$RC"
  run_herd status a; sa="$OUT|$RC"
  # (b) the same marker, file missing -> clean.
  pane_text a "report done"$'\n'"QUESTION: $qdir/missing.md"
  run_herd classify-pane p:a; cb="$OUT|$RC"
  # (c) marker 25 lines above the end -> outside the 20-line window.
  { printf 'Bericht\nQUESTION: %s/impl.md\n' "$qdir"; i=0; while [ "$i" -lt 25 ]; do printf 'fueller %s\n' "$i"; i=$((i + 1)); done; } > "$FAKE_HERDR_DIR/pane.a"
  run_herd classify-pane p:a; cc="$OUT|$RC"
  # (d) placeholder path from a displayed brief text -> file missing.
  pane_text a "Brief: write the report to ..."$'\n'"QUESTION: $qdir/<name>.md"
  run_herd classify-pane p:a; cplaceholder="$OUT|$RC"
  # Error paths individually: relative path, path is a directory, marker in
  # a numbered code line, marker in a tool echo.
  pane_text a "QUESTION: questions/impl.md"
  run_herd classify-pane p:a; crel="$OUT|$RC"
  pane_text a "QUESTION: $qdir"
  run_herd classify-pane p:a; cdir="$OUT|$RC"
  pane_text a "    12  print(\"QUESTION: $qdir/impl.md\")"
  run_herd classify-pane p:a; ccode="$OUT|$RC"
  pane_text a "$(printf '\xe2\x97\x8f Bash(echo QUESTION: %s/impl.md)' "$qdir")"
  run_herd classify-pane p:a; cecho="$OUT|$RC"
  check T180 target "question fixtures (a)-(d) and error paths: file missing/relative/directory/code/tool echo -> clean" \
        "question|0/question|0/clean|0/clean|0/clean|0/clean|0/clean|0/clean|0/clean|0" \
        "$ca/$sa/$cb/$cc/$cplaceholder/$crel/$cdir/$ccode/$cecho"
fi

if should_run T180b target; then
  # (e) marker plus pi busy -> busy (classify-pane), status normalized to working.
  fixture_dir "t180b"
  fixture a idle
  qdir="$WORK/t180b/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  fixture_kind a pi
  pane_text a "$(printf '\xe2\xa0\x8b Working')"$'\n'"QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; ce="$OUT|$RC"
  run_herd status a; se="$OUT|$RC"
  # (f) marker plus open selection dialog -> blocked (dialog takes precedence).
  rm -f "$FAKE_HERDR_DIR/kind.a"
  pane_text a "Do you want to proceed?"$'\n'"QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; cf="$OUT|$RC"
  run_herd status a; sf="$OUT|$RC"
  check T180b target "question fixtures (e)/(f): busy before question, dialog before question" \
        "busy|0/working|0/blocked|0/blocked|0" "$ce/$se/$cf/$sf"
fi

if should_run T180c target; then
  # Criterion 4: after moving the file (the orchestrator answers and cleans up)
  # the same marker is silent; a NEW question with a new file reports question
  # again.
  fixture_dir "t180c"
  fixture a idle
  qdir="$WORK/t180c/questions"; mkdir -p "$qdir/answered"; : > "$qdir/impl.md"
  pane_text a "Bericht"$'\n'"QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; c1="$OUT|$RC"
  mv "$qdir/impl.md" "$qdir/answered/impl.md"
  run_herd classify-pane p:a; c2="$OUT|$RC"
  : > "$qdir/review.md"
  pane_text a "Bericht"$'\n'"QUESTION: $qdir/review.md"
  run_herd classify-pane p:a; c3="$OUT|$RC"
  check T180c target "moved file -> clean, new file -> question again" \
        "question|0/clean|0/question|0" "$c1/$c2/$c3"
fi

if should_run T180d target; then
  # `list` shows question for idle/done panes (herdr does not know the state);
  # after moving, the raw herdr status remains.
  fixture_dir "t180d"
  fixture a idle
  qdir="$WORK/t180d/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "Bericht"$'\n'"QUESTION: $qdir/impl.md"
  run_herd list; l1="$OUT|$RC"
  mv "$qdir/impl.md" "$qdir/impl.bak"
  run_herd list; l2="$OUT|$RC"
  check T180d target "list: marker + file -> 'a question', after moving raw status idle" \
        "a question p:a|0/a idle p:a|0" "$l1/$l2"
fi

if should_run T180e target; then
  # Marker only at the START OF THE LINE. Expectation directly from the
  # correction contract: before it only whitespace and TUI frame (│ ┃ ║ ▏ ▕ |);
  # a `>` (Markdown quote) or running text before it is NOT a question, but
  # frame/whitespace is.
  fixture_dir "t180e"
  fixture a idle
  qdir="$WORK/t180e/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "> QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; e1="$OUT|$RC"
  pane_text a "note from old report: QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; e2="$OUT|$RC"
  pane_text a "$(printf '\xe2\x94\x82 QUESTION: %s/impl.md' "$qdir")"
  run_herd classify-pane p:a; e3="$OUT|$RC"
  pane_text a "  QUESTION: $qdir/impl.md"
  run_herd classify-pane p:a; e4="$OUT|$RC"
  check T180e target "marker only at line start: quote/text before clean, frame/whitespace question" \
        "clean|0/clean|0/question|0/question|0" "$e1/$e2/$e3/$e4"
fi

if should_run T180f target; then
  # list priority: for raw idle/done the full classify_text classification
  # (with kind lookup on busy like status). ONLY question is adopted;
  # busy/dialog keep the raw herdr status. The status lines prove that the
  # same situation is busy/blocked there — list must not turn that into question.
  fixture_dir "t180f"
  fixture a idle
  qdir="$WORK/t180f/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "Bericht"$'\n'"QUESTION: $qdir/impl.md"
  run_herd list; f1="$OUT|$RC"
  fixture_kind a pi
  pane_text a "$(printf '\xe2\xa0\x8b Working')"$'\n'"QUESTION: $qdir/impl.md"
  run_herd list; f2="$OUT|$RC"
  run_herd status a; f2s="$OUT|$RC"
  rm -f "$FAKE_HERDR_DIR/kind.a"
  pane_text a "Do you want to proceed?"$'\n'"QUESTION: $qdir/impl.md"
  run_herd list; f3="$OUT|$RC"
  run_herd status a; f3s="$OUT|$RC"
  check T180f target "list: only marker -> question; busy/dialog -> raw status (status busy/blocked)" \
        "a question p:a|0/a idle p:a|0/working|0/a idle p:a|0/blocked|0" \
        "$f1/$f2/$f2s/$f3/$f3s"
fi

if should_run T180g target; then
  # Empty inventory: NO stdout bytes (like baseline cb7042e), exit 0. The empty
  # here-string must not print a phantom record of three empty fields.
  # Byte comparison via file + od (like T157d3), not via the trimmed OUT.
  fixture_dir "t180g"
  env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
    PATH="$ROOT/tests/bin:$PATH" HERDR_ENV=1 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
    "$HERD" list > "$WORK/t180g.out" 2>/dev/null
  rcg=$?
  bytes="$(od -An -tx1 < "$WORK/t180g.out" | tr -d ' \n')"
  size="$(wc -c < "$WORK/t180g.out" | tr -d ' ')"
  check T180g target "list without agents: no stdout bytes, exit 0" \
        "0|0|" "$rcg|$size|$bytes"
fi

if should_run T181 target; then
  # End to end over the fake event server: idle + marker in the pane -> the
  # dialog cross-check returns question, the action instruction comes from herd.sh.
  fixture_dir "t181"
  fixture a working
  qdir="$WORK/t181/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "report done"$'\n'"QUESTION: $qdir/impl.md"
  ev_start "$WORK/t181-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  explain=no; case "$ERR" in *"QUESTION"*) explain=yes ;; esac
  check T181 target "watch events: marker + file -> 'a question' with action instruction" \
        "a question|0|yes" "$OUT|$RC|$explain"
fi

# --------------------------------- HERD_NOTIFY (TNO1+, optional switch) -----
# HERD_NOTIFY=1 additionally outputs `herdr notification show "herd: <name>
# <state>" --sound request` for every EMITTED action line (fire-and-forget). The
# fake herdr logs this in .notify; because the call does not wait for its end,
# the test must wait for the file.

# tno_wait_notify <file> — wait for the fake log (max. ~2 s).
tno_wait_notify() {
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
}

# tno_run_blocked <notify 0|1> <ev directory> — event server with the fixture
# working -> blocked and a watch run (--max-events 1). Sets TNO_OUT/TNO_RC.
tno_run_blocked() {
  local notify="$1" evdir="$2"
  ev_start "$evdir" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_BLOCKED
hold
EOF
  if [ "$notify" = 1 ]; then
    HERD_NOTIFY=1 run_watch a --stall-timeout 0 --max-events 1
  else
    run_watch a --stall-timeout 0 --max-events 1
  fi
  TNO_OUT="$OUT"; TNO_RC="$RC"
  ev_stop
}

# tno_notify_bytes — size of the fake log, 0 if no file.
tno_notify_bytes() {
  cat "$FAKE_HERDR_DIR/.notify" 2>/dev/null | wc -c | tr -d ' '
}

if should_run TNO1 target; then
  # N1: HERD_NOTIFY=1, working -> blocked -> EXACTLY one call with title and
  # sound; stdout/exit exactly as in the run WITHOUT the switch.
  fixture_dir "tno1"
  pane_text a "arbeitet"
  tno_run_blocked 0 "$WORK/tno1-ev-off"
  off="$TNO_OUT|$TNO_RC"
  tno_run_blocked 1 "$WORK/tno1-ev-on"
  on="$TNO_OUT|$TNO_RC"
  tno_wait_notify "$FAKE_HERDR_DIR/.notify"
  calls="$(wc -l < "$FAKE_HERDR_DIR/.notify" 2>/dev/null | tr -d ' ')"
  line="$(cat "$FAKE_HERDR_DIR/.notify" 2>/dev/null)"
  check TNO1 target "watch: HERD_NOTIFY=1 -> exactly ONE call, stdout as without the switch" \
        "a blocked|0|a blocked|0|1|herd: a blocked --sound request" \
        "$off|$on|$calls|$line"
fi

if should_run TNO2 target; then
  # N2: without HERD_NOTIFY the same sequence -> no call.
  fixture_dir "tno2"
  pane_text a "arbeitet"
  tno_run_blocked 0 "$WORK/tno2-ev"
  sleep 0.3
  check TNO2 target "watch: without HERD_NOTIFY no call (behavior unchanged)" \
        "a blocked|0|0" "$TNO_OUT|$TNO_RC|$(tno_notify_bytes)"
fi

if should_run TNO3 target; then
  # N3: idle is a result, not an action state -> no call.
  fixture_dir "tno3"
  pane_text a "plain normal output"
  ev_start "$WORK/tno3-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  HERD_NOTIFY=1 run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  sleep 0.3
  check TNO3 target "watch: HERD_NOTIFY=1, idle -> no call" \
        "a idle|0|0" "$OUT|$RC|$(tno_notify_bytes)"
fi

if should_run TNO4 target; then
  # N4: `notification show` fails (exit 1) -> stdout and exit code of the
  # watcher stay unchanged, no error on stderr.
  fixture_dir "tno4"
  : > "$FAKE_HERDR_DIR/.notifyfail"
  pane_text a "arbeitet"
  tno_run_blocked 0 "$WORK/tno4-ev-off"
  off="$TNO_OUT|$TNO_RC"
  tno_run_blocked 1 "$WORK/tno4-ev-on"
  check TNO4 target "watch: notification show exit 1 -> stdout/exit as without the switch" \
        "$off" "$TNO_OUT|$TNO_RC"
fi

if should_run TNO5 target; then
  # N5: question is an action state -> call with `herd: <name> question`.
  fixture_dir "tno5"
  fixture a working
  qdir="$WORK/tno5/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "report done"$'\n'"QUESTION: $qdir/impl.md"
  ev_start "$WORK/tno5-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  HERD_NOTIFY=1 run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  tno_wait_notify "$FAKE_HERDR_DIR/.notify"
  line="$(cat "$FAKE_HERDR_DIR/.notify" 2>/dev/null)"
  check TNO5 target "watch: HERD_NOTIFY=1, question -> 'herd: a question'" \
        "a question|0|herd: a question --sound request" "$OUT|$RC|$line"
fi

if should_run TNO7 target; then
  # * monitor-unavailable is the only GLOBAL state with its own title;
  # the all-clear * monitor-restored does not trigger a call.
  fixture_dir "tno7"
  pane_text a "arbeitet"
  ev_start "$WORK/tno7-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
sleep 0.1
drop
stream
hold
EOF
  HERD_NOTIFY=1 run_watch a --stall-timeout 0 --max-events 2
  ev_stop
  tno_wait_notify "$FAKE_HERDR_DIR/.notify"
  calls="$(wc -l < "$FAKE_HERDR_DIR/.notify" 2>/dev/null | tr -d ' ')"
  line="$(cat "$FAKE_HERDR_DIR/.notify" 2>/dev/null)"
  check TNO7 target "watch: monitor-unavailable -> own title, restored -> no call" \
        "* monitor-unavailable;* monitor-restored|0|1|herd: herdr does not respond --sound request" \
        "$(printf '%s' "$OUT" | tr '\n' ';')|$RC|$calls|$line"
fi
