# ---------------------------------------------- space isolation + answer -----
# Plan: docs/plan-space-isolation.md. Tests run against the fake herdr
# (workspace_id via ws.<name>, collisions via extra.jsonl).

if should_run T95 target; then
  fixture_dir "t95"
  fixture mine working
  fixture foreign idle
  fixture_ws mine w9
  fixture_ws foreign wH
  HERD_TEST_WS=w9 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T95 target "list: only the own space" "mine working p:mine|0" "$got|$RC"
fi

if should_run T96 target; then
  fixture_dir "t96"
  fixture mine working
  fixture foreign idle
  fixture_ws mine w9
  fixture_ws foreign wH
  HERD_TEST_WS=w9 run_herd list --all-spaces
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  check T96 target "list --all-spaces: all with the space column" \
        "foreign idle p:foreign wH;mine working p:mine w9;|0" "$got|$RC"
fi

if should_run T97 target; then
  fixture_dir "t97"
  fixture mine working
  fixture foreign idle
  fixture_ws mine w9
  fixture_ws foreign wH
  # No space ID (run_herd unsets HERDR_*) → do not filter + stderr note.
  run_herd list
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  note=no
  case "$ERR" in *"not filtering"*) note=yes ;; esac
  check T97 target "list without a space ID: unfiltered + stderr note" \
        "foreign idle p:foreign;mine working p:mine;|0|yes" "$got|$RC|$note"
fi

if should_run T98 target; then
  fixture_dir "t98"
  fixture rev-codex working
  fixture_ws rev-codex wH
  pane_text rev-codex "Do you want to proceed?"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_TEST_WS=w9 run_herd status rev-codex
  s_rc=$RC
  case "$ERR" in *"is in space wH"*"you are in w9"*) s_msg=yes ;; *) s_msg="no($ERR)" ;; esac
  HERD_TEST_WS=w9 run_herd send rev-codex "hello world"
  send_rc=$RC
  case "$ERR" in *"is in space wH"*) send_msg=yes ;; *) send_msg=no ;; esac
  HERD_TEST_WS=w9 run_herd answer rev-codex "Yes"
  ans_rc=$RC
  case "$ERR" in *"is in space wH"*) ans_msg=yes ;; *) ans_msg=no ;; esac
  HERD_TEST_WS=w9 run_herd stop rev-codex
  stop_rc=$RC
  case "$ERR" in *"is in space wH"*) stop_msg=yes ;; *) stop_msg=no ;; esac
  HERD_TEST_WS=w9 run_herd wait rev-codex --timeout 1 --stall-timeout 0
  wait_rc=$RC
  HERD_TEST_WS=w9 run_herd watch rev-codex --stall-timeout 0 --max-events 1
  watch_rc=$RC
  HERD_TEST_WS=w9 run_herd read rev-codex
  read_rc=$RC
  HERD_TEST_WS=w9 run_herd key rev-codex enter
  key_rc=$RC
  HERD_TEST_WS=w9 run_herd type rev-codex "echo hi"
  type_rc=$RC
  side="$(side_log)"
  untouched=no
  case "$side" in
    *"prompt"*|*"close"*|*"pane-keys"*|*"pane-text"*|*"agent-keys"*) untouched="no($side)" ;;
    *) untouched=yes ;;
  esac
  check T98 target "foreign verbs: exit 1, no side effects (including wait/watch/read/key/type)" \
        "1|yes|1|yes|1|yes|1|yes|1|1|1|1|1|yes" \
        "$s_rc|$s_msg|$send_rc|$send_msg|$ans_rc|$ans_msg|$stop_rc|$stop_msg|$wait_rc|$watch_rc|$read_rc|$key_rc|$type_rc|$untouched"
fi

if should_run T99 target; then
  fixture_dir "t99"
  # get returns the own one (ws.w9); extra is the foreign one with a different status.
  fixture rev-codex idle
  fixture_ws rev-codex w9
  extra_agent rev-codex working wH:p5 wH
  HERD_TEST_WS=w9 run_herd status rev-codex
  check T99a target "same name in both spaces (get=own): own status" \
        "idle|0" "$OUT|$RC"
  # get returns the foreign one; extra is the own one — resolution must use list.
  fixture_dir "t99b"
  fixture rev-codex working
  fixture_ws rev-codex wH
  extra_agent rev-codex idle w9:p3 w9
  HERD_TEST_WS=w9 run_herd status rev-codex
  check T99b target "same name in both spaces (get=foreign): own status from list" \
        "idle|0" "$OUT|$RC"
fi

if should_run T100 target; then
  fixture_dir "t100"
  # Space ID from the TAB_ID prefix when HERDR_WORKSPACE_ID is missing.
  fixture mine working
  fixture foreign idle
  fixture_ws mine w9
  fixture_ws foreign wH
  HERD_TEST_TAB=w9:t1 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T100a target "space ID from the HERDR_TAB_ID prefix" "mine working p:mine|0" "$got|$RC"
  HERD_TEST_PANE=w9:p1 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T100b target "space ID from the HERDR_PANE_ID prefix" "mine working p:mine|0" "$got|$RC"
fi

if should_run T101 target; then
  fixture_dir "t101"
  fixture rev-codex working
  fixture_ws rev-codex wH
  # Name exists only in a foreign space → start must NOT block (HERD_PRINT_CLI before pane).
  HERD_TEST_WS=w9 run_start -- claude --name rev-codex
  check T101a target "start: name only in a foreign space does not block" "0" "$RC"
  # Name in the own space → blocks.
  fixture_ws rev-codex w9
  HERD_TEST_WS=w9 run_start -- claude --name rev-codex
  own_rc=$RC
  case "$ERR" in *"already running in this space"*) own_msg=yes ;; *) own_msg="no($ERR)" ;; esac
  check T101b target "start: name in the own space blocks" "1|yes" "$own_rc|$own_msg"
fi

if should_run T102 target; then
  fixture_dir "t102"
  fixture a idle
  pane_text a "plain output without options"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes"
  check T102 target "answer: unrecognized dialog format -> exit != 0" \
        "yes" "$([ "$RC" != 0 ] && echo yes || echo "no(rc=$RC)")"
fi

if should_run T103 target; then
  fixture_dir "t103"
  fixture a idle
  pane_text a "1. Yes, continue
2. No, reject"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, continue"
  hint=no
  case "$ERR" in *"digit"*) hint=yes ;; esac
  check T103 target "answer: dialog still there after selecting -> exit != 0 + workaround" \
        "yes|yes" "$([ "$RC" != 0 ] && echo yes || echo no)|$hint"
fi

if should_run T103b target; then
  # Confirmation repeats the read: long/wrapped dialogs close only a moment
  # after Enter (2026-10-09). First post-read still shows the dialog, the
  # second one is gone -> exit 0, "confirmed".
  fixture_dir "t103b"
  fixture a idle
  pane_text a "1. Yes, continue
2. No, reject"
  printf 'ok\n' > "$WORK/t103b-gone.txt"
  pane_after_files a 2 "$FAKE_HERDR_DIR/pane.a" "$WORK/t103b-gone.txt"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, continue"
  ok=no; case "$OUT" in *"confirmed"*) ok=yes ;; esac
  check T103b target "answer: dialog gone on a later verification read -> exit 0, confirmed" \
        "0|yes" "$RC|$ok"
fi

if should_run T99c target; then
  # Event engine: get returns the foreign one, list the own one — the own
  # pane must be subscribed, otherwise watch ends on foreign idle.
  fixture_dir "t99c"
  fixture rev-codex working
  fixture_ws rev-codex wH
  extra_agent rev-codex working w9:p3 w9
  pane_text rev-codex "nothing"
  ev_start "$WORK/t99c-ev" <<'EOF'
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get {"type":"agent_info","agent":{"name":"rev-codex","agent_status":"working","pane_id":"wH:p5","state_change_seq":1,"workspace_id":"wH"}}
reply agent.list {"agents":[{"name":"rev-codex","agent_status":"working","pane_id":"wH:p5","state_change_seq":1,"workspace_id":"wH"},{"name":"rev-codex","agent_status":"working","pane_id":"w9:p3","state_change_seq":2,"workspace_id":"w9"}]}
reply events.subscribe {"type":"subscription_started"}
stream
emit {"event":"pane.agent_status_changed","data":{"pane_id":"w9:p3","workspace_id":"w9","agent_status":"idle"}}
hold
EOF
  HERD_TEST_WS=w9 run_dispatch events "tcp:127.0.0.1:$EV_PORT" rev-codex --stall-timeout 0 --max-events 1
  ev_stop
  sub=no
  case "$(cat "$EV_LOG" 2>/dev/null)" in *"w9:p3"*) sub=yes ;; esac
  check T99c target "watch events: name collision subscribes the own pane" \
        "rev-codex idle|0|yes" "$OUT|$RC|$sub"
fi

if should_run T104 target; then
  fixture_dir "t104"
  fixture a idle
  pane_text a "1. Yes, continue
2. No, reject"
  printf '2\n' > "$FAKE_HERDR_DIR/readfail.a"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, continue"
  ok=no
  case "$ERR" in *"confirmed"*) ok="no-confirmed" ;;
    *"not readable"*|*"verification"*) ok=yes ;;
  esac
  check T104 target "answer: failed verification read -> exit != 0" \
        "yes|yes" "$([ "$RC" != 0 ] && echo yes || echo "no(rc=$RC)")|$ok"
fi

if should_run T105 target; then
  fixture_dir "t105"
  fixture mine working
  fixture foreign idle
  fixture_ws mine w9
  fixture_ws foreign wH
  # An empty TAB prefix must not break the chain.
  HERD_TEST_TAB=:t1 HERD_TEST_PANE=w9:p1 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T105a target "space ID: empty TAB prefix -> PANE fallback" \
        "mine working p:mine|0" "$got|$RC"
  # invalid form (oops) -> next source (TAB).
  HERD_TEST_WS=oops HERD_TEST_TAB=w9:t1 HERD_TEST_UNKNOWN_WS=1 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T105b target "space ID: invalid WS=oops -> TAB prefix" \
        "mine working p:mine|0" "$got|$RC"
  # plausible, but unknown to the daemon -> do not filter.
  HERD_TEST_WS=wZ HERD_TEST_UNKNOWN_WS=1 run_herd list
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  note=no
  case "$ERR" in *"not filtering"*) note=yes ;; esac
  check T105c target "space ID: unknown space -> unfiltered + note" \
        "foreign idle p:foreign;mine working p:mine;|0|yes" "$got|$RC|$note"
  # TAB without a colon, valid PANE.
  HERD_TEST_TAB=notab HERD_TEST_PANE=w9:p1 run_herd list
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T105d target "space ID: TAB without a colon -> PANE prefix" \
        "mine working p:mine|0" "$got|$RC"
fi

if should_run T106 target; then
  fixture_dir "t106"
  fixture mine idle
  fixture_ws mine w9
  nopy="$WORK/t106-nopy"; mkdir -p "$nopy"
  printf '#!/bin/sh\nexit 1\n' > "$nopy/python3"; chmod +x "$nopy/python3"
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$nopy:$ROOT/tests/bin:$PATH" HERDR_ENV=1 \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        HERDR_WORKSPACE_ID=w9 \
        "$HERD" status mine 2>"$WORK/err")"
  RC=$?
  check T106a target "without python3 the own agent stays reachable" "idle|0" "$OUT|$RC"
  touch "$FAKE_HERDR_DIR/.listfail"
  HERD_TEST_WS=w9 run_herd status mine
  check T106b target "agent list broken: own agent (get=own) stays reachable" \
        "idle|0" "$OUT|$RC"
fi

if should_run T107 target; then
  fixture_dir "t107"
  fixture ops working
  fixture_ws ops wH
  extra_pane ops wH:p2 wH
  extra_pane ops w9:p8 w9
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_TEST_WS=w9 run_herd type ops "echo hi"
  side="$(side_log)"
  hit=no
  case "$side" in *"pane-text w9:p8"*) hit=yes ;; esac
  foreign=no
  case "$side" in *"wH:p2"*) foreign=yes ;; esac
  check T107 target "pane_id_of: own label despite a foreign agent name" \
        "0|yes|no" "$RC|$hit|$foreign"
fi

if should_run T108 target; then
  fixture_dir "t108"
  fixture a idle
  pane_text a "  Allow this command?
  1 (●) Yes, and don't ask again for: cargo test
  2 (○) Yes, proceed
  3 (○) No, reject
  1/3:select │ Tab:next option │ Enter:confirm"
  pane_after a "working on cargo test"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, proceed"
  digit=no
  case "$OUT" in *"digit 2"*) digit=yes ;; esac
  side="$(side_log)"
  n2=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ 2$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  check T108 target "answer: grok format selects digit 2 without enter/down" \
        "0|yes|1|0|0" "$RC|$digit|$n2|$nenter|$ndown"
fi

if should_run T110 target; then
  fixture_dir "t110"
  fixture a idle
  pane_text a "1. Yes, and don"$'\u2019'"t ask again
2. No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, and don't ask again"
  hit=no
  case "$OUT" in *"ask again"*) hit=yes ;; esac
  digit=no
  case "$OUT" in *"digit"*) digit=yes ;; esac
  check T110 target "answer: typographic apostrophe matches ASCII" \
        "0|yes|no" "$RC|$hit|$digit"
fi

if should_run T111 target; then
  fixture_dir "t111"
  fixture a idle
  pane_text a "1. Yes
2. Yes, and don't ask again for: cargo"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes"
  exact=no
  case "$OUT" in *"answer: 'Yes' selected"*) exact=yes ;; esac
  ambig=no
  case "$ERR" in *"ambiguous"*) ambig=yes ;; esac
  check T111a target "answer: exact before prefix (Yes -> option 1, not AMBIG)" \
        "0|yes|no" "$RC|$exact|$ambig"
  pane_text a "1. Yes
2. Yes, and don't ask again for: cargo"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, and"
  pref=no
  case "$OUT" in *"don't ask again for: cargo"*) pref=yes ;; esac
  check T111b target "answer: prefix selects option 2 (Yes, and)" \
        "0|yes" "$RC|$pref"
fi

if should_run T112 target; then
  fixture_dir "t112"
  fixture a idle
  pane_text a "1. Yes, continue
2. No, reject"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No, reject"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  nkey=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ [0-9]+$' || true)
  check T112 target "answer: 1./2. format stays on the delta path (down+enter)" \
        "0|1|1|0" "$RC|$ndown|$nenter|$nkey"
fi

if should_run T113 target; then
  fixture_dir "t113"
  fixture rev-codex blocked
  fixture_ws rev-codex w9
  printf '%s\n' 'p:rev-codex' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' \
    'noreg:agent_start_timeout: no status change within 60000ms' \
    'agent_name_taken; candidates: name=rev-codex pane_id=p:rev-codex status=Blocked' \
    > "$FAKE_HERDR_DIR/start.rev-codex"
  pane_text rev-codex "Do you trust the files in this folder?"
  repo="$WORK/t113-repo"
  mkdir -p "$repo"
  git init "$repo" >/dev/null 2>&1
  rm -f "$FAKE_HERDR_DIR/.side"
  printf '%s\n' "w9" >> "$FAKE_HERDR_DIR/workspaces"
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        HERDR_WORKSPACE_ID=w9 \
        "$HERD" start codex --name rev-codex --cwd "$repo" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  already=no
  case "$ERR" in *"already registered on pane"*) already=yes ;; esac
  closed=no
  case "$(side_log)" in *"close"*) closed=yes ;; esac
  dialog=no
  case "$ERR" in *"dialog"*) dialog=yes ;; esac
  sc="$(cat "$FAKE_HERDR_DIR/.startcount.rev-codex" 2>/dev/null || echo 0)"
  check T113 target "start: timeout then own registration on agent_name_taken" \
        "0|yes|no|yes|2" "$RC|$already|$closed|$dialog|$sc"
fi

if should_run T113b target; then
  fixture_dir "t113b"
  fixture rev-codex blocked
  fixture_ws rev-codex w9
  printf '%s\n' 'p:other' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' \
    'agent_name_taken; candidates: name=rev-codex pane_id=p:rev-codex status=Blocked' \
    'agent_name_taken; candidates: name=rev-codex pane_id=p:rev-codex status=Blocked' \
    > "$FAKE_HERDR_DIR/start.rev-codex"
  repo="$WORK/t113b-repo"
  mkdir -p "$repo"
  git init "$repo" >/dev/null 2>&1
  rm -f "$FAKE_HERDR_DIR/.side"
  printf '%s\n' "w9" >> "$FAKE_HERDR_DIR/workspaces"
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        HERDR_WORKSPACE_ID=w9 \
        "$HERD" start codex --name rev-codex --cwd "$repo" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  taken=no
  case "$ERR" in *"agent_name_taken"*) taken=yes ;; esac
  open=no
  case "$ERR" in *"stays open for diagnosis"*) open=yes ;; esac
  closed=no
  case "$(side_log)" in *"close"*) closed=yes ;; esac
  sc="$(cat "$FAKE_HERDR_DIR/.startcount.rev-codex" 2>/dev/null || echo 0)"
  check T113b target "start: agent_name_taken on another pane -> error, pane open" \
        "1|yes|yes|no|2" "$RC|$taken|$open|$closed|$sc"
fi

if should_run T114 target; then
  fixture_dir "t114"
  fixture a idle
  pane_text a "2 (x) failed attempt"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "failed"
  nodlg=no
  case "$ERR" in *"no selection dialog"*) nodlg=yes ;; esac
  keys=no
  case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T114 target "answer: isolated grok-like prose -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$nodlg|$keys"
fi

if should_run T115 target; then
  fixture_dir "t115"
  fixture a idle
  pane_text a "1 (a) something"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "something"
  nodlg=no
  case "$ERR" in *"no selection dialog"*) nodlg=yes ;; esac
  check T115 target "answer: 1 (a) is not a radio -> NOOPTS" \
        "yes|yes" "$([ "$RC" != 0 ] && echo yes || echo no)|$nodlg"
fi

if should_run T116 target; then
  fixture_dir "t116"
  fixture a idle
  pane_text a "3 (x) tests failed

❯ 1. Yes
2. No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  nkey=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ [0-9]+$' || true)
  check T116 target "answer: prose before dialog, last run 1,2, down+enter" \
        "0|1|1|0" "$RC|$ndown|$nenter|$nkey"
fi

if should_run T117 target; then
  fixture_dir "t117"
  fixture a idle
  pane_text a "1. Yes, and don't ask again for:
   cargo test
2. No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T117 target "answer: a wrapped option does not interrupt the 1,2 run" \
        "0|1|1" "$RC|$ndown|$nenter"
fi

if should_run T118 target; then
  fixture_dir "t118"
  fixture a idle
  buf=""
  i=1
  while [ "$i" -le 10 ]; do
    if [ "$i" = 1 ]; then r="●"; else r="○"; fi
    buf="${buf}${i} (${r}) Option ${i}
"
    i=$((i + 1))
  done
  pane_text a "$buf"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Option 10"
  digit=no
  case "$OUT" in *"digit 10"*) digit=yes ;; esac
  side="$(side_log)"
  n10=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ 1 0$' || true)
  check T118 target "answer: grok digit 10 as two keys 1 0" \
        "0|yes|1" "$RC|$digit|$n10"
fi

if should_run T119 target; then
  fixture_dir "t119"
  fixture a idle
  pane_text a "1. Yes, proceed
2. Yes, reject"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes"
  ambig=no
  case "$ERR" in *"ambiguous"*) ambig=yes ;; esac
  check T119a target "answer: two prefixes without an exact match -> AMBIG" \
        "yes|yes" "$([ "$RC" != 0 ] && echo yes || echo no)|$ambig"
  pane_text a "1. Yes
2. No"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Nope"
  nomatch=no
  case "$ERR" in *"matches no option"*) nomatch=yes ;; esac
  check T119b target "answer: Nope against Yes/No -> NOMATCH" \
        "yes|yes" "$([ "$RC" != 0 ] && echo yes || echo no)|$nomatch"
fi

if should_run T120 target; then
  fixture_dir "t120"
  fixture a idle
  pane_text a "1. Allow  "$'\u00a0'$'\u201c'"cargo test"$'\u201d'"
2. No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a 'Allow "cargo test"'
  hit=no
  case "$OUT" in *"cargo test"*) hit=yes ;; esac
  check T120 target "answer: NBSP/quotes/spaces normalized" \
        "0|yes" "$RC|$hit"
fi

if should_run T121 target; then
  fixture_dir "t121"
  fixture a idle
  pane_text a "(●) Yes
(○) No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T121a target "answer: radio-only (●)/(○) stays on the delta path" \
        "0|1|1" "$RC|$ndown|$nenter"
  pane_text a "▶ 1. Approve
  2. Reject"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Reject"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T121b target "answer: kimi ▶ 1. Approve / 2. Reject stays delta" \
        "0|1|1" "$RC|$ndown|$nenter"
  pane_text a "> Yes, I trust this folder
  No, exit"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No, exit"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T121c target "answer: agy selector-only stays on the delta path" \
        "0|1|1" "$RC|$ndown|$nenter"
fi

if should_run T122 target; then
  fixture_dir "t122"
  fixture a idle
  fixture_kind a agy
  pane_text a "I will wait for it to complete.
● [11:14:22] tests/run.sh running"
  run_herd classify-pane p:a
  check T122a target "classify-pane: agy background task running -> busy" \
        "busy|0" "$OUT|$RC"
  pane_text a "I will wait for it to complete.
● [11:14:22] tests/run.sh finished"
  run_herd classify-pane p:a
  check T122b target "classify-pane: same line without running -> clean" \
        "clean|0" "$OUT|$RC"
fi

if should_run T123 target; then
  fixture_dir "t123"
  fixture a idle
  fixture_kind a agy
  pane_text a "$(printf 'output above\n\xe2\xa2\xb9 Compilation succeeded, indicating basic syntax cor\xe2\x80\xa6\nesc to cancel')"
  run_herd classify-pane p:a
  check T123 target "classify-pane: agy spinner + esc to cancel -> busy" \
        "busy|0" "$OUT|$RC"
fi

if should_run T124 target; then
  fixture_dir "t124"
  fixture a idle
  fixture_kind a grok
  pane_text a "$(printf 'output above\n\xe2\xa2\xb9 Compilation succeeded, indicating basic syntax cor\xe2\x80\xa6\nesc to cancel')"
  run_herd classify-pane p:a
  check T124 target "classify-pane: same busy text, kind grok -> clean" \
        "clean|0" "$OUT|$RC"
fi

if should_run T125 target; then
  fixture_dir "t125"
  fixture a idle
  pane_text a "$(printf 'output above\n\xe2\xa2\xb9 Compilation succeeded, indicating basic syntax cor\xe2\x80\xa6\nesc to cancel')"
  run_herd classify-pane p:a
  check T125 target "classify-pane: busy text without a kind -> clean" \
        "clean|0" "$OUT|$RC"
fi

if should_run T126 target; then
  fixture_dir "t126"
  fixture a idle
  fixture_kind a agy
  pane_text a "$(printf 'Do you want to proceed?\n\xe2\xa2\xb9 generating\nesc to cancel')"
  run_herd classify-pane p:a
  check T126 target "classify-pane: dialog beats agy-busy (blocked)" \
        "blocked|0" "$OUT|$RC"
fi

if should_run T127 target; then
  fixture_dir "t127"
  fixture a idle
  fixture_kind a agy
  pane_text a "$(printf 'streaming\n\xe2\xa2\xb9 Compilation succeeded\nesc to cancel')"
  run_herd status a
  check T127 target "status: idle + agy-busy -> working" \
        "working|0" "$OUT|$RC"
fi

if should_run T128 target; then
  fixture_dir "t128"
  fixture a idle
  fixture_kind a agy
  pane_text a "plain output without spinner"
  rm -f "$FAKE_HERDR_DIR/.count.a"
  run_herd classify-pane p:a
  moved=no
  [ -f "$FAKE_HERDR_DIR/.count.a" ] && moved=yes
  check T128 target "classify-pane: without a text hit no kind RPC" \
        "clean|0|no" "$OUT|$RC|$moved"
fi

if should_run T129 target; then
  fixture_dir "t129"
  fixture a idle
  fixture_kind a grok
  pane_text a "ready.
◎ 1 command still running · send a message to interrupt"
  run_herd classify-pane p:a
  check T129a target "classify-pane: grok background task -> busy" \
        "busy|0" "$OUT|$RC"
  fixture_kind a agy
  run_herd classify-pane p:a
  check T129b target "classify-pane: grok line with kind agy -> clean" \
        "clean|0" "$OUT|$RC"
  # The marker blinks (◎/◉/○); the pattern must not depend on the glyph.
  fixture_kind a grok
  pane_text a "ready.
○ 2 commands still running · send a message to interrupt"
  run_herd classify-pane p:a
  check T129c target "classify-pane: grok marker ○ (blinking) -> busy" \
        "busy|0" "$OUT|$RC"
fi

if should_run T130 target; then
  fixture_dir "t130"
  fixture a idle
  fixture_kind a agy
  # Busy window of 10 lines: first line = 10th or 11th from the bottom.
  spin="$(printf '\xe2\xa2\xb9')"
  pane_text a "${spin} spinning
L2
L3
L4
L5
L6
L7
L8
L9
L10"
  run_herd classify-pane p:a
  check T130a target "classify-pane: spinner alone as the 10th line from the bottom -> busy" \
        "busy|0" "$OUT|$RC"
  pane_text a "${spin} spinning
L2
L3
L4
L5
L6
L7
L8
L9
L10
L11"
  run_herd classify-pane p:a
  check T130b target "classify-pane: spinner alone as the 11th line from the bottom -> clean" \
        "clean|0" "$OUT|$RC"
  pane_text a "$(printf 'above\n\xe2\xa0\x80')"
  run_herd classify-pane p:a
  check T130c target "classify-pane: only U+2800 in the last line -> clean" \
        "clean|0" "$OUT|$RC"
  pane_text a "$(printf 'above\n\xe2\xa0\x81')"
  run_herd classify-pane p:a
  check T130d target "classify-pane: U+2801 in the last line -> busy" \
        "busy|0" "$OUT|$RC"
  pane_text a "$(printf 'above\n\xe2\xa3\xbf')"
  run_herd classify-pane p:a
  check T130e target "classify-pane: U+28FF in the last line -> busy" \
        "busy|0" "$OUT|$RC"
  # grok 2026-09-02: marker as the 7th line from the bottom, below it a blank
  # line, composer frame (3 lines), blank line, footer.
  fixture_kind a grok
  pane_text a "output above
◎ 1 command still running · send a message to interrupt

╭──────────────────────────────────────╮
│                                      │
╰──────────────────────────────────────╯

Shift+Tab:mode │ Ctrl+.:shortcuts"
  run_herd classify-pane p:a
  check T130f target "classify-pane: grok still-running as the 7th line from the bottom -> busy" \
        "busy|0" "$OUT|$RC"
fi

if should_run T184 target; then
  fixture_dir "t184"
  fixture a idle
  fixture_kind a claude
  # Live captures 2026-10-04 (Claude Code 2.1, herdr 0.9.3): turn end with
  # running monitors or footer with background shells.
  pane_text a "✻ Cogitated for 3s · done 17:30 · 2 monitors still running

───────────────────────────────────────────────────────────
❯ 
───────────────────────────────────────────────────────────
  Opus 5.5 5.5  1M  [####----] 72% used / 28% left  /home/x
  ⏵⏵ auto mode on · 2 monitors · ← for agents"
  run_herd classify-pane p:a
  check T184a target "classify-pane: claude, turn ended, running monitors -> background" \
        "background|0" "$OUT|$RC"
  pane_text a "· Crystallizing… (1m 16s · still thinking with high effort)

───────────────────────────────────────────────────────────
❯ 
───────────────────────────────────────────────────────────
  Opus 5.5 5.5  1M  [####----] 55% used / 45% left  /home/x
  ⏵⏵ auto mode on · 1 shell, 1 monitor · ← for agents"
  run_herd classify-pane p:a
  check T184b target "classify-pane: claude, turn running, footer '1 shell, 1 monitor' -> busy" \
        "busy|0" "$OUT|$RC"
  pane_text a "✻ Cogitated for 3s · done 17:30

The suite starts 3 shells in parallel.
───────────────────────────────────────────────────────────
❯ 
───────────────────────────────────────────────────────────
  Opus 5.5 5.5  1M  [####----] 55% used / 45% left  /home/x
  ⏵⏵ auto mode on · ← for agents"
  run_herd classify-pane p:a
  check T184c target "classify-pane: claude without background tasks, prose '3 shells' -> clean" \
        "clean|0" "$OUT|$RC"
  pane_text a "✻ Cogitated for 3s · done 17:30 · 3 shells, 1 monitor still running"
  run_herd classify-pane p:a --kind claude
  check T184d target "classify-pane --kind claude: '3 shells, 1 monitor still running' -> background" \
        "background|0" "$OUT|$RC"
  # Live capture 2026-10-08: completion marker written, turn ended, leftover
  # shell in the footer.
  pane_text a "DONE: package 3 implemented, dotnet test green.
✻ Worked for 4m 12s · done 21:04

───────────────────────────────────────────────────────────
❯ 
───────────────────────────────────────────────────────────
  Opus 5.5 5.5  1M  [######--] 61% used / 39% left  /home/x
  ⏵⏵ accept edits on · 1 shell · ← for agents"
  run_herd classify-pane p:a --kind claude
  check T184e target "classify-pane --kind claude: marker + leftover shell -> background" \
        "background|0" "$OUT|$RC"
  run_herd status a
  check T184f target "status: claude background -> working (pane not done from herdr's point of view)" \
        "working|0" "$OUT|$RC"
fi

if should_run T131 target; then
  fixture_dir "t131"
  fixture a idle
  fixture_kind a agy
  pane_text a "$(printf 'output\n\xe2\xa2\xb9 Compilation succeeded\nesc to cancel')"
  rm -f "$FAKE_HERDR_DIR/.count.a"
  run_herd classify-pane p:a --kind grok
  moved=no
  [ -f "$FAKE_HERDR_DIR/.count.a" ] && moved=yes
  check T131a target "classify-pane --kind grok on agy text: clean, no RPC" \
        "clean|0|no" "$OUT|$RC|$moved"
  rm -f "$FAKE_HERDR_DIR/.count.a"
  run_herd classify-pane p:a --kind agy
  moved=no
  [ -f "$FAKE_HERDR_DIR/.count.a" ] && moved=yes
  check T131b target "classify-pane --kind agy on agy text: busy, no RPC" \
        "busy|0|no" "$OUT|$RC|$moved"
fi

if should_run T132 target; then
  fixture_dir "t132"
  fixture a idle
  fixture_kind a codex
  pane_text a "plain output"
  run_herd status a
  n1="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T132 target "status: kind codex without an extra busy read (blocked/limited/auth)" \
        "idle|0|1" "$OUT|$RC|$n1"
fi

if should_run T133 target; then
  fixture_dir "t133"
  run_start -- agy --name t --role impl
  if has_args "--mode accept-edits" && ! has_args "--effort"; then r=ok; else r="wrong($OUT)"; fi
  check T133a target "start agy impl: --mode accept-edits, no --effort" \
        "ok" "$r"
  run_start -- agy --name t --role research
  has_args "--mode plan" && r=ok || r="wrong($OUT)"
  check T133b target "start agy research: --mode plan" \
        "ok" "$r"
  run_start -- agy --name t --effort high --role impl
  if has_args "--effort high" && has_args "--mode accept-edits"; then r=ok; else r="wrong($OUT)"; fi
  check T133c target "start agy impl --effort high: effort and accept-edits" \
        "ok" "$r"
  run_start -- agy --name t --permission-mode plan --role impl
  if has_args "--mode plan" && ! has_args "--mode accept-edits"; then r=ok; else r="wrong($OUT)"; fi
  check T133d target "start agy impl --permission-mode plan: explicit, no accept-edits" \
        "ok" "$r"
  run_start HERD_IMPL_PERMISSION_MODE=acceptEdits -- agy --name t --role impl
  if has_args "--mode accept-edits" && ! has_args "acceptEdits"; then r=ok; else r="wrong($OUT)"; fi
  check T133e target "start agy impl: HERD_IMPL_PERMISSION_MODE has no effect" \
        "ok" "$r"
  run_start -- agy --name t --resume --role impl
  if has_args "-c" && has_args "--mode accept-edits"; then r=ok; else r="wrong($OUT)"; fi
  check T133f target "start agy impl --resume: -c and --mode accept-edits" \
        "ok" "$r"
  run_start -- codex --name t --permission-mode plan
  case "$ERR" in
    *'claude|grok|agy|muse'*) msg=ok ;;
    *) msg="msg-wrong($ERR)" ;;
  esac
  [ "$RC" != 0 ] && rc=ok || rc="rc=$RC"
  check T133g target "start codex --permission-mode: exit != 0, message claude|grok|agy|muse" \
        "ok|ok" "$rc|$msg"
fi

if should_run T134 target; then
  fixture_dir "t134"
  fixture a idle
  grok_cmd_dlg="$(cat <<'EOF'
     ❯ # Package C: wire up agy in `start` correctly (`--mode`,       1:25 PM
       `--effort`, `--permission-mode`)
  …
  ┃  Run full test suite for baseline
  ┃  tests/run.sh
  ┃  e edit pattern
  ┃
  ┃  1 (●) Yes, and don't ask again for anything (always-approve mode)
  ┃  2 (○) Always allow: tests/run.sh
  ┃  3 (○) Yes, proceed
  ┃  4 (○) No, reject (type to add feedback)
  ┃  5 (○) Never allow: tests/run.sh
  ┃
  1/5:select  │  Tab:next option  │  e:edit pattern  │  Ctrl+o:
EOF
)"
  pane_text a "$grok_cmd_dlg"
  pane_after a "working on tests/run.sh"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, proceed"
  digit=no
  case "$OUT" in *"digit 3"*) digit=yes ;; esac
  side="$(side_log)"
  n3=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ 3$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  check T134a target "answer: grok command approval with box prefix selects digit 3" \
        "0|yes|1|1|0|0" "$RC|$digit|$n3|$nkeys|$nenter|$ndown"
  pane_text a "$grok_cmd_dlg"
  pane_after a "working on tests/run.sh"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No, reject"
  digit=no
  case "$OUT" in *"digit 4"*) digit=yes ;; esac
  side="$(side_log)"
  n4=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ 4$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  check T134b target "answer: grok command approval No, reject -> digit 4" \
        "0|yes|1|0|0" "$RC|$digit|$n4|$nenter|$ndown"
  pane_text a "$(cat <<'EOF'
     ❯ # Package C: wire up agy in `start` correctly (`--mode`,       1:25 PM
       `--effort`, `--permission-mode`)
EOF
)"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Yes, proceed"
  nodlg=no
  case "$ERR" in *"no selection dialog"*) nodlg=yes ;; esac
  keys=no
  case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T134c target "answer: grok prompt echo alone -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$nodlg|$keys"
  pane_text a "│ 1. Yes, continue
│ 2. No"
  pane_after a "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "No"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  nkey=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ [0-9]+$' || true)
  check T134d target "answer: codex trust with box prefix stays on the delta path" \
        "0|1|1|0" "$RC|$ndown|$nenter|$nkey"
fi

if should_run T134e target; then
  fixture_dir "t134e"
  fixture a idle
  # A prompt echo in 24h format (locale-dependent) must not be a dialog either.
  pane_text a "     ❯ # Package C: wire up agy in \`start\` correctly (\`--mode\`,       13:25
       \`--effort\`, \`--permission-mode\`)"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer a "Package C"
  nodlg=no
  case "$ERR" in *"no selection dialog"*) nodlg=yes ;; esac
  keys=no
  case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T134e target "answer: prompt echo with 24h time -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$nodlg|$keys"
fi


# ------------------------------------------------------------- dialog prefilter
# T142: characterization of known dialogs with a realistic footer (blocked)
# T143: negative cases — tool output with line numbers and old prose (clean)
# T144: fix round — tool echo exclusion and a long recents list with enter:select



grok_footer="
╭──╮
│ ❯ │
╰── Grok 4.6 (high) ─╯

Shift+Tab:mode │ Ctrl+.:shortcuts"

if should_run T142 target; then
  fixture_dir "t142"
  fixture a idle

  # T142a: codex trust dialog
  check_dlg T142a "codex trust dialog: Do you trust + options + footer" "$(cat <<'EOF'
Do you trust the files in this folder?
1. Yes, continue
2. No, exit
Press enter to confirm or esc to cancel
EOF
)" blocked blocked

  # T142b: codex command approval with a LONG command
  cmd_body=""
  for i in $(seq 1 25); do
    cmd_body="${cmd_body}  long command parameter line $i
"
  done
  check_dlg T142b "codex command approval: long command, options/footer in the window" "$(cat <<EOF
Would you like to run the following command?
${cmd_body}› 1. Yes, proceed (y)
2. Yes, and don't ask again for this session
3. No, and tell Codex what to do differently (esc)
Press enter to confirm or esc to cancel
EOF
)" blocked blocked

  # T142c: grok command approval with ┃ box prefix (verbatim T134a text) + grok's 6-line footer
  grok_cmd_dlg="$(cat <<'EOF'
     ❯ # Package C: wire up agy in `start` correctly (`--mode`,       1:25 PM
       `--effort`, `--permission-mode`)
  …
  ┃  Run full test suite for baseline
  ┃  tests/run.sh
  ┃  e edit pattern
  ┃
  ┃  1 (●) Yes, and don't ask again for anything (always-approve mode)
  ┃  2 (○) Always allow: tests/run.sh
  ┃  3 (○) Yes, proceed
  ┃  4 (○) No, reject (type to add feedback)
  ┃  5 (○) Never allow: tests/run.sh
  ┃
  1/5:select  │  Tab:next option  │  e:edit pattern  │  Ctrl+o:
EOF
)"
  check_dlg T142c "grok command approval with ┃ box prefix and 6-line footer" "${grok_cmd_dlg}${grok_footer}" blocked blocked

  # T142d: grok project picker (realistic with hint and grok footer)
  check_dlg T142d "grok project picker: Run Grok Build in a project directory?" "$(cat <<EOF
Run Grok Build in a project directory?
1 (●) current directory (current)
2 (○) Open recent project
enter:select  │  ↑↓:navigate
${grok_footer}
EOF
)" blocked blocked

  # T142e: kimi plan approval
  check_dlg T142e "kimi plan approval: Ready to build with this plan?" "$(cat <<'EOF'
Ready to build with this plan?
▶ 1. Approve
2. Reject
EOF
)" blocked blocked

  # T142f: claude
  check_dlg T142f "claude: Do you want to proceed? + ❯ 1. Yes / 2. No" "$(cat <<'EOF'
Do you want to proceed?
❯ 1. Yes
2. No
Enter to confirm · Esc to cancel
EOF
)" blocked blocked

  # T142g: agy selector-only (never detected by text_looks_blocked -> clean/idle)
  check_dlg T142g "agy selector-only: unchanged clean, detection only via answer" "$(cat <<'EOF'
> Yes, I trust this folder
  No, exit
EOF
)" clean idle

  # T142h: real limit (codex + agy)
  pane_text a "You've hit your usage limit. Try again at 3:00 PM."
  run_herd classify-pane p:a; c1="$OUT|$RC"
  run_herd status a; s1="$OUT|$RC"
  pane_text a "Individual quota reached … Resets in 2h"
  run_herd classify-pane p:a; c2="$OUT|$RC"
  run_herd status a; s2="$OUT|$RC"
  check T142h target "real limit: codex Try again / agy Resets in -> limited" \
        "limited|0/limited|0/limited|0/limited|0" "$c1/$s1/$c2/$s2"

  # T142i: login in the middle of the pane (outside the last 20 lines)
  login_pane=""
  for i in $(seq 1 10); do login_pane="${login_pane}line $i
"; done
  login_pane="${login_pane}Sign in with Google
"
  for i in $(seq 11 35); do login_pane="${login_pane}line $i
"; done
  check_dlg T142i "login: Sign in with Google in the middle of the pane -> auth" "$login_pane" auth auth
fi

if should_run T143 target; then
  fixture_dir "t143"
  fixture a idle

  # T143a: tool output with line numbers
  check_dlg T143a "tool output with line numbers and fixture patterns -> clean" "$(cat <<EOF
       2925  fi
       2926  Do you want to proceed?
       2927  # usage limit reached resets in 3
       2928  # --------------------------------------------------------------- Conclusion
${grok_footer}
EOF
)" clean idle

  # T143b: prose report (exactly 30 lines: 2 header + 22 unremarkable + 6 footer)
  prose_head="Final report: Yes, proceed completed successfully.
Would you like to review the generated code?"
  prose_body=""
  for i in $(seq 1 22); do
    prose_body="${prose_body}This is unremarkable report prose line $i
"
  done
  t143b_txt="${prose_head}
${prose_body}${grok_footer}"
  nlines="$(printf '%s\n' "$t143b_txt" | wc -l | tr -d ' ')"
  pane_text a "$t143b_txt"
  rm -f "$FAKE_HERDR_DIR/kind.a"
  run_herd classify-pane p:a; c="$OUT|$RC"
  run_herd status a; s="$OUT|$RC"
  check T143b target "prose report: 30 lines, dialog patterns far up (>20 lines from the bottom) -> clean" \
        "30/clean|0/idle|0" "$nlines/$c/$s"

  # T143c: the same sentences in the last 5 lines (real dialog proximity) -> blocked
  near_head=""
  for i in $(seq 1 20); do
    near_head="${near_head}Report line $i
"
  done
  check_dlg T143c "prose with dialog patterns in the last 5 lines -> blocked" "$(cat <<EOF
${near_head}Yes, proceed
Would you like to continue?
Final line
EOF
)" blocked blocked

  # T143d: Claude Code read format
  pane_text a "   12→usage limit reached"
  run_herd classify-pane p:a; c1="$OUT|$RC"
  run_herd status a; s1="$OUT|$RC"
  pane_text a "usage limit reached"
  run_herd classify-pane p:a; c2="$OUT|$RC"
  run_herd status a; s2="$OUT|$RC"
  check T143d target "Claude Code read: clean with prefix, limited without prefix" \
        "clean|0/idle|0/limited|0/limited|0" "$c1/$s1/$c2/$s2"
fi

if should_run T144 target; then
  fixture_dir "t144"
  fixture a idle

  # T144a: tool echo with "usage limit reached" in the last 5 lines + agy footer -> clean
  check_dlg T144a "agy tool echo with 'usage limit reached' in last 5 lines -> clean" "$(cat <<'EOF'
● Bash(printf '   12\tusage limit reached\n' | grep -E …)
  output line 1
  output line 2
? for shortcuts
EOF
)" clean idle

  # T144b: agy tool echo ● Bash(grep 'Do you want to proceed?' …) -> clean
  check_dlg T144b "agy tool echo with 'Do you want to proceed?' -> clean" "$(cat <<'EOF'
● Bash(grep 'Do you want to proceed?' tests/run.sh)
  output line 1
  output line 2
? for shortcuts
EOF
)" clean idle

  # T144c: the same question WITHOUT a marker as a real dialog line -> blocked
  check_dlg T144c "dialog line without marker: Do you want to proceed? -> blocked" "$(cat <<'EOF'
Do you want to proceed?
❯ 1. Yes
  2. No
Enter to confirm · Esc to cancel
EOF
)" blocked blocked

  # T144d: 15 recents lines + enter:select + grok footer, title outside 20 lines -> blocked
  recents=""
  for i in $(seq 1 15); do
    recents="${recents} ${i} (○) /home/user/dev/project${i}
"
  done
  check_dlg T144d "grok recents picker: 15 entries, title outside the window -> blocked" "$(cat <<EOF
Run Grok Build in a project directory?
${recents}enter:select  │  ↑↓:navigate${grok_footer}
EOF
)" blocked blocked
fi


if should_run T160 target; then
  # Preparation: ANSI fixtures with different highlighting
  # Fixture dialog-permission.ansi marks "Reject".
  PYTHONUTF8=1 python3 -c '
def make_ansi(selected=None):
    with open("tests/fixtures/opencode/dialog-permission.ansi", "r", errors="replace") as f:
        ansi = f.read()
    ansi = ansi.replace(
        "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mReject\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m",
        "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mReject\x1b[0m"
    )
    if selected == "Allow once":
        ansi = ansi.replace(
            "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mAllow once\x1b[0m",
            "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mAllow once\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m"
        )
    elif selected == "Allow always":
        ansi = ansi.replace(
            "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mAllow always\x1b[0m",
            "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mAllow always\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m"
        )
    elif selected == "Reject":
        ansi = ansi.replace(
            "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mReject\x1b[0m",
            "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mReject\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m"
        )
    return ansi

import sys
open(sys.argv[1] + "/oc-ansi-once.txt", "w").write(make_ansi("Allow once"))
open(sys.argv[1] + "/oc-ansi-always.txt", "w").write(make_ansi("Allow always"))
open(sys.argv[1] + "/oc-ansi-reject.txt", "w").write(make_ansi("Reject"))
open(sys.argv[1] + "/oc-ansi-nomark.txt", "w").write(make_ansi(None))

with open("tests/fixtures/opencode/dialog-confirm.ansi", "r", errors="replace") as f:
    conf_ansi = f.read()
conf_cancel = conf_ansi.replace(
    "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mConfirm\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m",
    "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mConfirm\x1b[0m"
).replace(
    "\x1b[38;2;180;180;180m\x1b[48;2;25;25;25mCancel\x1b[0m",
    "\x1b[48;2;206;203;0m \x1b[0m\x1b[38;2;0;0;0m\x1b[48;2;206;203;0mCancel\x1b[0m\x1b[38;2;255;255;255m\x1b[48;2;206;203;0m \x1b[0m"
)
open(sys.argv[1] + "/oc-conf-cancel.txt", "w").write(conf_cancel)
' "$WORK"

  # T160a: classify-pane/status with the text fixture -> blocked
  fixture_dir "t160a"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  run_herd status oc
  st_160a="$OUT|$RC"
  run_herd classify-pane oc
  cl_160a="$OUT|$RC"
  check T160a target "classify-pane/status opencode text fixture -> blocked" \
        "blocked|0|blocked|0" "$st_160a|$cl_160a"

  # T160b: answer oc "Allow always" with the ANSI fixture (marker on Allow once):
  # .side = right, then enter; the second ANSI read shows the marker on Allow always
  # (fixture pane-ansi-after-2), text read afterwards without a dialog -> exit 0, message 1 step(s) right
  fixture_dir "t160b"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_msg=no; case "$OUT" in *"1 step(s) right"*"confirmed"*) has_msg=yes ;; esac
  side="$(side_log)"
  nright=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ right$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  order=no; case "$side" in *"right"*"enter"*) order=yes ;; esac
  check T160b target "answer opencode: Allow always from Allow once -> 1 step right + enter" \
        "0|yes|1|1|2|yes" "$RC|$has_msg|$nright|$nenter|$nkeys|$order"

  # T160c: answer oc "Reject" from Allow once:
  # shortest path = left (wrap-around), verified, then enter
  fixture_dir "t160c"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-reject.txt")" 2
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Reject"
  has_msg=no; case "$OUT" in *"1 step(s) left"*"confirmed"*) has_msg=yes ;; esac
  side="$(side_log)"
  nleft=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ left$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  order=no; case "$side" in *"left"*"enter"*) order=yes ;; esac
  check T160c target "answer opencode: Reject from Allow once -> 1 step left (wrap-around) + enter" \
        "0|yes|1|1|2|yes" "$RC|$has_msg|$nleft|$nenter|$nkeys|$order"

  # T160d: answer oc "Allow" -> ambiguous, exit 1, option list in the message, no keys
  fixture_dir "t160d"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow"
  ambig=no; case "$ERR" in *"is ambiguous"*) ambig=yes ;; esac
  has_opts=no; case "$ERR" in *"*"*"Allow once"*"Allow always"*"Reject"*) has_opts=yes ;; esac
  keys=no; case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T160d target "answer opencode: 'Allow' ambiguous -> exit 1, option list, no keys" \
        "1|yes|yes|no" "$RC|$ambig|$has_opts|$keys"

  # T160d2: answer oc "Nonexistent" -> no option matches, exit 1, option list in the message, no keys
  fixture_dir "t160d2"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Nonexistent"
  nomatch=no; case "$ERR" in *"matches no option"*) nomatch=yes ;; esac
  has_opts=no; case "$ERR" in *"*"*"Allow once"*"Allow always"*"Reject"*) has_opts=yes ;; esac
  keys=no; case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T160d2 target "answer opencode: 'Nonexistent' unknown -> exit 1, option list, no keys" \
        "1|yes|yes|no" "$RC|$nomatch|$has_opts|$keys"

  # T160e: ANSI without a marker -> exit 1 with a note, no keys
  fixture_dir "t160e"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-nomark.txt")"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow once"
  has_hint=no; case "$ERR" in *"selection not recognizable — key oc enter selects the default"*) has_hint=yes ;; esac
  keys=no; case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T160e target "answer opencode: ANSI without a marker -> exit 1 with a note, no keys" \
        "1|yes|no" "$RC|$has_hint|$keys"

  # T160e2: ANSI with two yellow islands -> only the real marker (black on yellow) counts
  fixture_dir "t160e2"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  yellow_noise="$(printf '\x1b[38;2;255;255;255m\x1b[48;2;206;203;0mFake Island\x1b[0m\n')"
  pane_ansi oc "${yellow_noise}$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_msg=no; case "$OUT" in *"1 step(s) right"*"confirmed"*) has_msg=yes ;; esac
  check T160e2 target "answer opencode: two yellow islands -> only the real marker counts" \
        "0|yes" "$RC|$has_msg"

  # T160f: verification fails (second ANSI read still shows Allow once) -> no enter, exit 1
  fixture_dir "t160f"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-once.txt")" 2
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  side="$(side_log)"
  nright=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ right$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T160f target "answer opencode: verification failed -> no enter, exit 1" \
        "1|1|0" "$RC|$nright|$nenter"

  # T160h: answer oc "Confirm" with the new fixtures (marker on Confirm, 0 steps, enter, dialog gone afterwards) -> exit 0
  fixture_dir "t160h"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.txt")"
  pane_ansi oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.ansi")"
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Confirm"
  has_msg=no; case "$OUT" in *"0 step(s) right"*"confirmed"*) has_msg=yes ;; esac
  side="$(side_log)"
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  check T160h target "answer opencode: Confirm from Confirm -> 0 steps + enter" \
        "0|yes|1|1" "$RC|$has_msg|$nenter|$nkeys"

  # T160i: answer oc "Cancel" -> 1 step right
  fixture_dir "t160i"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.txt")"
  pane_ansi oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.ansi")"
  pane_ansi_after oc "$(cat "$WORK/oc-conf-cancel.txt")" 2
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Cancel"
  has_msg=no; case "$OUT" in *"1 step(s) right"*"confirmed"*) has_msg=yes ;; esac
  side="$(side_log)"
  nright=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ right$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  check T160i target "answer opencode: Cancel from Confirm -> 1 step right + enter" \
        "0|yes|1|1|2" "$RC|$has_msg|$nright|$nenter|$nkeys"

  # T160j: text fixture dialog-confirm.txt -> blocked
  fixture_dir "t160j"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.txt")"
  run_herd status oc
  st_160j="$OUT|$RC"
  run_herd classify-pane oc
  cl_160j="$OUT|$RC"
  check T160j target "classify-pane/status opencode Confirm text fixture -> blocked" \
        "blocked|0|blocked|0" "$st_160j|$cl_160j"

  # T160k: text fixture after enter = Confirm/Cancel bar -> exit 0 with "follow-up dialog open: Confirm | Cancel"
  fixture_dir "t160k"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  pane_after oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-confirm.txt")"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_msg=no; case "$OUT" in *"1 step(s) right"*"confirmed — follow-up dialog open: Confirm | Cancel"*) has_msg=yes ;; esac
  side="$(side_log)"
  nright=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ right$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  nkeys=$(printf '%s\n' "$side" | grep -cE 'pane-keys ' || true)
  order=no; case "$side" in *"right"*"enter"*) order=yes ;; esac
  check T160k target "answer opencode: follow-up dialog Confirm/Cancel after enter -> exit 0" \
        "0|yes|1|1|2|yes" "$RC|$has_msg|$nright|$nenter|$nkeys|$order"

  # T160l: after enter the same Allow bar -> exit 1 "still there" (existing behavior)
  fixture_dir "t160l"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  pane_after oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_err=no; case "$ERR" in *"dialog is still there after selecting — not confirmed."*) has_err=yes ;; esac
  side="$(side_log)"
  nright=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ right$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
  check T160l target "answer opencode: same bar after enter -> exit 1 still there" \
        "1|yes|1|1" "$RC|$has_err|$nright|$nenter"

  # T160n: keyword fallback without the ⇆ glyph in the line (e.g. truncated help text)
  fixture_dir "t160n"
  fixture oc idle
  pane_text oc "$(printf '┃  Allow once   Allow always   Reject\n')"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  pane_after oc "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_msg=no; case "$OUT" in *"1 step(s) right"*"confirmed"*) has_msg=yes ;; esac
  check T160n target "answer opencode: keyword fallback without ⇆ -> BAR detected and operated" \
        "0|yes" "$RC|$has_msg"

  # T160m: the bar dialog is still there on the first post-read and gone on a
  # later one (long/wrapped dialog, 2026-10-09) -> exit 0, "confirmed".
  fixture_dir "t160m"
  fixture oc idle
  pane_text oc "$(cat "$ROOT/tests/fixtures/opencode/dialog-permission.txt")"
  pane_ansi oc "$(cat "$WORK/oc-ansi-once.txt")"
  pane_ansi_after oc "$(cat "$WORK/oc-ansi-always.txt")" 2
  printf 'ok\n' > "$WORK/t160m-gone.txt"
  pane_after_files oc 2 "$ROOT/tests/fixtures/opencode/dialog-permission.txt" "$WORK/t160m-gone.txt"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer oc "Allow always"
  has_msg=no; case "$OUT" in *"confirmed"*) has_msg=yes ;; esac
  check T160m target "answer opencode: bar dialog gone on a later verification read -> exit 0" \
        "0|yes" "$RC|$has_msg"
fi


# Claude: identical options do not mean the same tool request.
if should_run T164 target; then
  for variant in search fetch same marker history missing oldmissing backend readfail; do
    fixture_dir "t164-$variant"
    fixture a idle
    fixture_kind a claude
    before=$'Web Search\n  Query: Three.js documentation\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No'
    after="$before"
    expected=1
    case "$variant" in
      search) after="${before/Three.js documentation/Linux WebKitGTK}"; expected=0 ;;
      fetch) after=$'Fetch\n  https://example.com/install\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No'; expected=0 ;;
      marker) after="${before/❯ 1. Yes/  1. Yes}"; after="${after/  2. No/❯ 2. No}" ;;
      history) after=$'Completed another task\n'"$before" ;;
      missing) after=$'Do you want to proceed?\n❯ 1. Yes\n  2. No' ;;
      oldmissing) before=$'Edit file\n  src/main.rs\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No' ;;
      backend) fixture_kind a codex; after="${before/Three.js documentation/Linux WebKitGTK}" ;;
      readfail) printf '2\n' > "$FAKE_HERDR_DIR/readfail.a"; after="${before/Three.js documentation/Linux WebKitGTK}" ;;
    esac
    pane_text a "$before"
    pane_after a "$after"
    HERD_ANSWER_VERIFY_SEC=0 run_herd answer a Yes
    follow=0; case "$OUT" in *"follow-up dialog open"*) follow=1 ;; esac
    want_follow=0; [ "$expected" = 0 ] && want_follow=1
    nenter=$(printf '%s\n' "$(side_log)" | grep -cE 'pane-keys [^[:space:]]+ enter$' || true)
    check "T164-$variant" target "answer Claude: $variant, exactly one confirmation" \
      "$expected|$want_follow|1" "$RC|$follow|$nenter"
  done
fi

if should_run T166 target; then
  for variant in success same; do
    fixture_dir "t166-$variant" "$WORK/answer-tmp"
    fixture a idle
    pane_text a $'❯ 1. Yes\n  2. No'
    expected=1
    if [ "$variant" = success ]; then pane_after a 'Working'; expected=0; fi
    # An already created global note must be removed along with the new option data.
    : > "$WORK/space-note"
    TMPDIR="$WORK/answer-tmp" HERD_SPACE_NOTE_FILE="$WORK/space-note" HERD_ANSWER_VERIFY_SEC=0 run_herd answer a Yes
    leftover=0
    if [ -e "$WORK/space-note" ] || compgen -G "$WORK/answer-tmp/*" >/dev/null; then leftover=1; fi
    check "T166-$variant" target "answer: global and local temp files removed after $variant" "$expected|0" "$RC|$leftover"
  done
fi

# Direct pure-parser checks and frozen shell protocol (stdout, stderr, status).
if should_run T176 target; then
  check_python_tests T176 test_dialog_parser.py 7 \
    'direct dialog parser reference tests and CLI contract'
fi
