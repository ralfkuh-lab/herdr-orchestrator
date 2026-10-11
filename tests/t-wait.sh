# ------------------------------------------ wait event path / one classification
# T135: wait uses the same engine switch as watch. run_dispatch_wait is the
# counterpart to run_dispatch (verb wait instead of watch). T136: one pane read
# in status, classify-pane and status speak the same classification.


if should_run T135a target; then
  fixture_dir "t135a"
  fixture a working
  pane_text a "plain output"
  ev_start "$WORK/t135a-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  expl=no; case "$ERR" in *"BLOCKED"*|*"Limit"*|*"Login"*|*"OAuth"*) expl=yes ;; esac
  check T135a target "wait events: working->idle -> stdout exactly idle, exit 0, idle without explanation" \
        "idle|0|no" "$OUT|$RC|$expl"
fi

if should_run T135a2 target; then
  # Initial state: already idle at the first resync is reported as idle after
  # the quiet window + cross-check.
  fixture_dir "t135a2"
  fixture a idle
  pane_text a "plain output"
  ev_start "$WORK/t135a2-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  check T135a2 target "wait events: resync already idle -> idle after the window" \
        "idle|0" "$OUT|$RC"
fi

if should_run T135b target; then
  fixture_dir "t135b"
  fixture a working
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t135b-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  check T135b target "wait events: idle + dialog text -> blocked" \
        "blocked|0" "$OUT|$RC"
fi

if should_run T135c target; then
  fixture_dir "t135c"
  fixture a working
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t135c-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.3
emit $EV_A_BLOCKED
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --status blocked --timeout 1 --stall-timeout 0
  ev_stop
  nread="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T135c target "wait --status blocked events: idle+dialog silent (no classify), then blocked" \
        "blocked|0|0" "$OUT|$RC|$nread"
fi

if should_run T135d target; then
  fixture_dir "t135d"
  fixture a working
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t135d-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --status idle --timeout 1 --stall-timeout 0
  ev_stop
  check T135d target "wait --status idle events: dialog text still returns raw idle" \
        "idle|0" "$OUT|$RC"
fi

if should_run T135e target; then
  fixture_dir "t135e"
  fixture a working
  pane_text a "working"
  ev_start "$WORK/t135e-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  notDone=no; case "$ERR" in *"NOT done"*) notDone=yes ;; esac
  again=no; case "$ERR" in *"Wait again"*) again=yes ;; esac
  permanent=no; case "$ERR" in *"Observe permanently"*) permanent=yes ;; esac
  check T135e target "wait events: timeout -> exit 124, all three note lines" \
        "|124|yes|yes|yes" "$OUT|$RC|$notDone|$again|$permanent"
fi

if should_run T135f target; then
  fixture_dir "t135f"
  fixture a working
  pane_text a "nothing"
  ev_start "$WORK/t135f-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
drop
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  check T135f target "wait events: stream loss -> stdout monitor-unavailable, exit 0" \
        "monitor-unavailable|0" "$OUT|$RC"
fi

if should_run T135g target; then
  fixture_dir "t135g"
  fixture a blocked
  pane_text a "plain output"
  run_dispatch_wait events "tcp:127.0.0.1:1" a --timeout 1 --stall-timeout 0
  hard="$OUT|$RC"
  reason=no; case "$ERR" in *"HERD_WATCH_ENGINE=events"*) reason=yes ;; esac
  run_dispatch_wait auto "tcp:127.0.0.1:1" a --timeout 1 --stall-timeout 0
  auto="$OUT|$RC"
  hint=no; case "$ERR" in *"event API not available"*) hint=yes ;; esac
  fallback=yes; case "$ERR" in *"poll fallback"*) fallback=no ;; esac
  check T135g target "wait dispatcher: events/auto without API -> exit 2, no fallback" \
        "|2|yes/|2|yes|yes" "$hard|$reason/$auto|$hint|$fallback"
fi

if should_run T135h target; then
  fixture_dir "t135h"
  run_dispatch_wait events "tcp:127.0.0.1:1" missing --timeout 1 --stall-timeout 0
  e1=$RC
  run_dispatch_wait auto "tcp:127.0.0.1:1" missing --timeout 1 --stall-timeout 0
  a1=$RC
  check T135h target "wait: unknown name -> exit 1 before the engine choice (auto|events)" \
        "1 == 1" "$e1 == $a1"
fi

if should_run T136 target; then
  fixture_dir "t136"
  fixture a idle
  pane_text a "plain output"
  run_herd status a
  n1="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T136a target "status: idle + unremarkable text -> one pane read" \
        "idle|0|1" "$OUT|$RC|$n1"
  pane_text a "Do you want to proceed?"
  run_herd status a
  n2="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T136b target "status: idle + dialog text -> blocked, one pane read" \
        "blocked|0|1" "$OUT|$RC|$n2"
  # Table: classify-pane and status for the same texts. status maps
  # busy->working and clean->raw status (idle).
  row() {
    local text="$1" kind="${2:-}"
    pane_text a "$text"
    [ -n "$kind" ] && fixture_kind a "$kind" || rm -f "$FAKE_HERDR_DIR/kind.a"
    run_herd classify-pane p:a; c="$OUT"
    run_herd status a; s="$OUT"
    printf '%s/%s' "$c" "$s"
  }
  r1="$(row "Do you want to proceed?")"
  r2="$(row "usage limit reached")"
  r3="$(row "please sign in")"
  r4="$(row "$(printf 'streaming\n\xe2\xa2\xb9 Compilation succeeded\nesc to cancel')" agy)"
  r5="$(row "plain output")"
  check T136c target "classify-pane/status consistent (dialog/limit/login/agy-busy/clean)" \
        "blocked/blocked|limited/limited|auth/auth|busy/working|clean/idle" \
        "$r1|$r2|$r3|$r4|$r5"
fi


# ------------------------------------------ fix round stage 3 (timeout 0, worker, parity)

if should_run T137a target; then
  fixture_dir "t137a"
  fixture a blocked
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t137a-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_GET_A_BLOCKED
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 0 --stall-timeout 0
  ev_stop
  check T137a target "wait events --timeout 0: initial state blocked -> blocked exit 0" \
        "blocked|0" "$OUT|$RC"
fi

if should_run T137b target; then
  fixture_dir "t137b"
  fixture a idle
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t137b-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_GET_A_IDLE
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --status idle --timeout 0 --stall-timeout 0
  ev_stop
  check T137b target "wait events --status idle --timeout 0: start idle (raw) -> idle exit 0" \
        "idle|0" "$OUT|$RC"
fi

if should_run T137c target; then
  fixture_dir "t137c"
  fixture a working
  pane_text a "working"
  ev_start "$WORK/t137c-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 0 --stall-timeout 0
  ev_stop
  notDone=no; case "$ERR" in *"NOT done"*) notDone=yes ;; esac
  again=no; case "$ERR" in *"Wait again"*) again=yes ;; esac
  permanent=no; case "$ERR" in *"Observe permanently"*) permanent=yes ;; esac
  check T137c target "wait events --timeout 0: start working -> 124, three note lines" \
        "|124|yes|yes|yes" "$OUT|$RC|$notDone|$again|$permanent"
fi

if should_run T138a target; then
  # TERM-resistant child (ignores SIGTERM). wait must return exit 0
  # AND kill the child via SIGKILL on the process group.
  fixture_dir "t138"
  fixture a working
  pane_text a "plain output"
  printf '60\n' > "$FAKE_HERDR_DIR/readsleep.a"
  ev_start "$WORK/t138-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.5
emit $EV_A_BLOCKED
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  pid="$(tr -d ' \n' < "$FAKE_HERDR_DIR/.readpid.a" 2>/dev/null || true)"
  started=no; [ -n "$pid" ] && started=yes
  alive=yes
  if [ -z "$pid" ]; then
    alive=no-pid
  elif ! kill -0 "$pid" 2>/dev/null; then
    alive=no
  fi
  check T138a target "wait events: TERM-resistant child dead after the hit" \
        "blocked|0|yes|no" "$OUT|$RC|$started|$alive"
fi

if should_run T138b target; then
  fixture_dir "t138b"
  fixture a working
  pane_text a "plain output"
  printf '60\n' > "$FAKE_HERDR_DIR/readsleep.a"
  ev_start "$WORK/t138b-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.5
emit $EV_A_BLOCKED
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  pid="$(tr -d ' \n' < "$FAKE_HERDR_DIR/.readpid.a" 2>/dev/null || true)"
  started=no; [ -n "$pid" ] && started=yes
  alive=yes
  if [ -z "$pid" ]; then
    alive=no-pid
  elif ! kill -0 "$pid" 2>/dev/null; then
    alive=no
  fi
  check T138b target "watch --max-events 1: TERM-resistant child dead after the hit" \
        "a blocked|0|yes|no" "$OUT|$RC|$started|$alive"
fi

if should_run T138c target; then
  # agent.get after pane.closed hangs (HOLD); blocked in parallel as the hit.
  # wait must finish before the RPC timeout (the socket is closed).
  fixture_dir "t138c"
  fixture a working
  pane_text a "nothing"
  ev_start "$WORK/t138c-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply agent.get $EV_A_GET
reply agent.get HOLD
reply events.subscribe {"type":"subscription_started"}
stream
sleep 0.2
emit $EV_A_CLOSED
sleep 0.3
emit $EV_A_BLOCKED
hold
EOF
  t0="$(python3 -c 'import time; print("%.3f" % time.monotonic())')"
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  t1="$(python3 -c 'import time; print("%.3f" % time.monotonic())')"
  ev_stop
  # The join budget in _cancel_workers is 1 s. A live worker would use that
  # up fully; with the socket close the runtime must stay below it.
  fast=no
  python3 -c "import sys; sys.exit(0 if float('$t1')-float('$t0') < 1.0 else 1)" && fast=yes
  # HOLD connection: last agent.get in the fake log; close = client EOF
  # (hold() returns on recv==b'', then handle logs 'N close').
  hold_line="$(grep ' agent.get ' "$EV_LOG" 2>/dev/null | tail -1)"
  hold_cid="${hold_line%% *}"
  nget="$(grep -c ' agent.get ' "$EV_LOG" 2>/dev/null || true)"
  eof=no
  # hold() polls recv every 0.2 s — the close in the log comes shortly after the EOF.
  if [ "${nget:-0}" -ge 3 ] && [ -n "$hold_cid" ]; then
    ev_wait_log "^${hold_cid} close$"
    grep -qE "^${hold_cid} close$" "$EV_LOG" && eof=yes
  fi
  check T138c target "wait events: blocked agent.get — EOF at the server, runtime below the join budget" \
        "blocked|0|yes|yes" "$OUT|$RC|$fast|$eof"
fi

if should_run T139 target; then
  fixture_dir "t139"
  fixture a working
  pane_text a "nothing"
  run_dispatch_wait events "tcp:127.0.0.1:1" a --status --blocked --timeout 1 --stall-timeout 0
  e_rc=$RC
  case "$ERR" in *"expects a status"*) e_msg=yes ;; *) e_msg="no($ERR)" ;; esac
  run_dispatch_wait auto "tcp:127.0.0.1:1" a --status --blocked --timeout 1 --stall-timeout 0
  a_rc=$RC
  case "$ERR" in *"expects a status"*) a_msg=yes ;; *) a_msg="no($ERR)" ;; esac
  check T139 target "wait --status with a leading '-' -> exit 2 in auto|events, same message" \
        "2|yes == 2|yes" "$e_rc|$e_msg == $a_rc|$a_msg"
fi

if should_run T140 target; then
  fixture_dir "t140"
  fixture a blocked
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t140-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_GET_A_BLOCKED
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  check T140 target "wait events: resync already blocked -> blocked (without timeout 0)" \
        "blocked|0" "$OUT|$RC"
fi

if should_run T141a target; then
  fixture_dir "t141a"
  fixture a working
  pane_text a "plain output"
  ev_start "$WORK/t141a-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  n="$(printf '%s' "$OUT" | awk 'NF' | wc -l | tr -d ' ')"
  check T141a target "wait events: working then idle -> stdout exactly one line idle" \
        "idle|0|1" "$OUT|$RC|$n"
fi

if should_run T141b target; then
  fixture_dir "t141b"
  fixture a working
  pane_text a "plain output"
  ev_start "$WORK/t141b-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_BLOCKED
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  n="$(printf '%s' "$OUT" | awk 'NF' | wc -l | tr -d ' ')"
  check T141b target "wait events: blocked then working/idle -> stdout exactly blocked" \
        "blocked|0|1" "$OUT|$RC|$n"
fi

if should_run T141c target; then
  fixture_dir "t141c"
  fixture a working
  pane_text a "nothing"
  ev_start "$WORK/t141c-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
stream
drop
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  n="$(printf '%s' "$OUT" | awk 'NF' | wc -l | tr -d ' ')"
  check T141c target "wait events: loss/reconnect -> exactly monitor-unavailable (no restored)" \
        "monitor-unavailable|0|1" "$OUT|$RC|$n"
fi


# -------------------------- stage 4 phase A: event counterparts of the nine gaps
# Spec: .herd/spec-stufe4-etappe-a.md. One gap per test, in the order of the
# research. `tests/run.sh T161` runs the whole block. Production code stays
# untouched: if a case turns red against today's event path, it is marked
# SKIP-capable and reported in the result.

if should_run T161 target; then

  # T161a: event counterpart to T2 — a short idle blip (send race) must not end
  # wait; only the second, stable idle counts.
  fixture_dir "t161a"
  fixture a working
  pane_text a "plain output"
  ev_start "$WORK/t161a-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.05
emit $EV_A_WORKING
sleep 0.25
emit $EV_A_IDLE
hold
EOF
  t0=$(date +%s%N)
  HERD_EVENTS_DEBOUNCE_SEC=0.2 run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" \
    a --timeout 1 --stall-timeout 0
  t1=$(date +%s%N)
  ev_stop
  elapsed_ms=$(( (t1 - t0) / 1000000 ))
  # The first idle would pass after a 0.2s debounce; the second only arrives at
  # 0.30s stream + 0.2s window. A threshold of 400ms (incl. handshake) separates
  # the paths — no sleep race, just proof that the first idle was discarded.
  late=no; [ "$elapsed_ms" -ge 400 ] && late=yes
  check T161a target "wait events: a single idle before working does not settle (counterpart T2)" \
        "idle|0|yes" "$OUT|$RC|$late"

  # T161b: event counterpart to T7 — watch a b ends by itself as soon as ALL
  # agents are idle (T73 checks only 1 agent; T82 forces --max-events).
  fixture_dir "t161b"
  pane_text a "plain output"
  pane_text b "plain output"
  ev_start "$WORK/t161b-ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.25
emit $EV_B_IDLE
hold
EOF
  run_watch a b --stall-timeout 0
  ev_stop
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  finished=no; case "$ERR" in *"all observed agents are done"*) finished=yes ;; esac
  check T161b target "watch events: ends when all agents are done (counterpart T7, >=2)" \
        "a idle;b idle;|0|yes" "$got|$RC|$finished"

  # T161c: event counterpart to T8 — a lost (pane_closed confirmed), b keeps
  # running until idle. T78 checks lost for only 1 agent.
  fixture_dir "t161c"
  pane_text a "working"
  pane_text b "plain output"
  ev_start "$WORK/t161c-ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
error agent.get agent_not_found no such agent
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_CLOSED
sleep 0.25
emit $EV_B_IDLE
hold
EOF
  run_watch a b --stall-timeout 0
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T161c target "watch events: a lost, b keeps running until idle (counterpart T8, multi)" \
        "a lost;b idle|0" "$got|$RC"

  # T161d: event counterpart to T11 — stall clock isolated per agent: a hangs
  # (stalled), b finishes (idle). T75 checks stalled for only 1 agent.
  fixture_dir "t161d"
  pane_text a "unchanged"
  pane_text b "plain output"
  ev_start "$WORK/t161d-ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply events.subscribe {"type":"subscription_started"}
stream
sleep 0.2
emit $EV_B_IDLE
hold
EOF
  HERD_STALL_UNIT=1 HERD_EVENTS_MINUTE_SEC=1 HERD_EVENTS_VERIFY_SEC=0.2 \
    run_watch a b --stall-timeout 1 --max-events 2
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T161d target "watch events: a stalled, b idle, stall clock isolated (counterpart T11, multi)" \
        "b idle;a stalled|0" "$got|$RC"

  # T161e: event counterpart to T14 — --timeout invalid/missing -> exit 2.
  # validate_minutes runs before the engine switch; no fake server needed.
  fixture_dir "t161e"
  fixture a working
  run_dispatch_wait events "" a --timeout abc
  rc1=$RC
  run_dispatch_wait events "" a --timeout
  rc2=$RC
  check T161e target "wait events: non-numeric/missing --timeout -> exit 2 (counterpart T14)" \
        "2|2" "$rc1|$rc2"

  # T161f: event counterpart to T20 — second completion of the same agent
  # after a new brief (session reuse). The report lock must fall on
  # re-activation. b stays working: otherwise watch ends after the first idle
  # (T73) before the second cycle becomes visible — as in poll T20.
  fixture_dir "t161f"
  pane_text a "plain output"
  pane_text b "working"
  ev_start "$WORK/t161f-ev" <<EOF
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply agent.get $EV_A_GET
reply agent.get $EV_B_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
sleep 0.4
emit $EV_A_WORKING
sleep 0.2
emit $EV_A_IDLE
hold
EOF
  run_watch a b --stall-timeout 0 --max-events 2
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T161f target "watch events: second completion of the same agent (counterpart T20)" \
        "a idle;a idle|0" "$got|$RC"

  # T161g: event counterpart to T21 — second blocked dialog after a short,
  # unconfirmed idle. T159h tests re-entry only for failed.
  fixture_dir "t161g"
  pane_text a "Do you want to proceed?"
  ev_start "$WORK/t161g-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_BLOCKED
sleep 0.05
emit $EV_A_IDLE
sleep 0.05
emit $EV_A_BLOCKED
hold
EOF
  run_watch a --stall-timeout 0 --max-events 2
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T161g target "watch events: second blocked dialog after an intermediate state (counterpart T21)" \
        "a blocked;a blocked|0" "$got|$RC"

  # T161h: event counterpart to T24 — raw status unknown in the event stream is
  # an immediate action event. T76 tests unknown only after a connection error.
  fixture_dir "t161h"
  pane_text a "nothing"
  ev_start "$WORK/t161h-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_UNKNOWN
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  check T161h target "watch events: raw status unknown is reported (counterpart T24)" \
        "a unknown|0" "$OUT|$RC"

  # T161i: event counterpart to T30 — wait --status blocked still returns on
  # stalled (always-hit, exit 0). T135* does not have this stall case.
  fixture_dir "t161i"
  fixture a working
  pane_text a "unchanged"
  ev_start "$WORK/t161i-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
hold
EOF
  HERD_STALL_UNIT=1 HERD_EVENTS_MINUTE_SEC=1 HERD_EVENTS_VERIFY_SEC=0.2 \
    run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --status blocked \
    --stall-timeout 1 --timeout 3
  ev_stop
  check T161i target "wait --status events: stalled is still a hit (counterpart T30)" \
        "stalled|0" "$OUT|$RC"

fi


if should_run T182 target; then
  # End to end: the question marker + an existing file ends `wait` like an
  # event (exit 0, output question) — question is NOT terminal for watch, but
  # a regular event for the one-shot wait.
  fixture_dir "t182"
  fixture a working
  qdir="$WORK/t182/questions"; mkdir -p "$qdir"; : > "$qdir/impl.md"
  pane_text a "report done"$'\n'"QUESTION: $qdir/impl.md"
  ev_start "$WORK/t182-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  check T182 target "wait events: marker + file -> stdout question, exit 0" \
        "question|0" "$OUT|$RC"
fi

if should_run TNO6 target; then
  # N6: HERD_NOTIFY=1 on the one-shot `wait --status blocked` -> exactly one call.
  # The blocked status arrives as a raw event; `--status blocked` is the wait
  # contract that allows it as a hit at all. The fake logs fire-and-forget,
  # so the test waits for the file.
  fixture_dir "tno6"
  fixture a working
  pane_text a "working"
  ev_start "$WORK/tno6-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_BLOCKED
hold
EOF
  HERD_NOTIFY=1 run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a \
    --status blocked --timeout 1 --stall-timeout 0
  ev_stop
  i=0
  while [ ! -s "$FAKE_HERDR_DIR/.notify" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  calls="$(wc -l < "$FAKE_HERDR_DIR/.notify" 2>/dev/null | tr -d ' ')"
  line="$(cat "$FAKE_HERDR_DIR/.notify" 2>/dev/null)"
  check TNO6 target "wait: HERD_NOTIFY=1, blocked -> exactly ONE call" \
        "blocked|0|1|herd: a blocked --sound request" "$OUT|$RC|$calls|$line"
fi
