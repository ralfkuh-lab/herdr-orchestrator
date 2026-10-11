# -------------------------------------------------------------- status -------
# T15: characterization of the status) branch. This normalization is merged
# with the wait logic during the rework — the outputs must stay identical.

if should_run T15a char; then
  fixture_dir "t15a"
  fixture a idle
  pane_text a "Do you want to proceed?"
  run_herd status a
  check T15a char "status: idle + dialog pane -> blocked" "blocked|0" "$OUT|$RC"
fi

if should_run T15b char; then
  fixture_dir "t15b"
  fixture a working
  pane_text a "usage limit reached"
  run_herd status a
  check T15b char "status: working + limit pane -> limited" "limited|0" "$OUT|$RC"
fi

if should_run T15c char; then
  fixture_dir "t15c"
  fixture a idle
  pane_text a "plain output"
  run_herd status a
  check T15c char "status: idle without anything unusual stays idle" "idle|0" "$OUT|$RC"
fi

if should_run T15d char; then
  fixture_dir "t15d"
  run_herd status missing
  check T15d char "status: unknown agent -> exit 1" "1" "$RC"
fi

if should_run T16 target; then
  fixture_dir "t16"
  fixture a working
  fixture b idle
  run_herd list
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"
  check T16 target "list: inventory of all agents with status" "a working p:a;b idle p:b;|0" "$got|$RC"
fi

if should_run T28 target; then
  fixture_dir "t28"
  fixture a working
  # Daemon outage during list: MUST fail loudly. An empty output with
  # exit 0 could read as "no agents" after a compaction.
  touch "$FAKE_HERDR_DIR/.down"
  run_herd list
  check T28 target "list: error -> exit != 0 (not silently empty)" "yes" \
        "$([ "$RC" != 0 ] && echo yes || echo "no(rc=$RC)")"
fi

if should_run T32 target; then
  fixture_dir "t32"
  # The agent was ALREADY working before. The send fails. An uncorrelated
  # 'working' afterwards must NOT count as success — otherwise the
  # orchestrator waits for a brief that was never accepted.
  fixture a working:5 working:5 working:5 working:5 working:5 working:5
  pane_text a "working on something else"
  printf 'connection reset by peer\n' > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "new brief"
  check T32 target "send: an already running 'working' is NOT proof of acceptance" \
        "yes" "$([ "$RC" != 0 ] && echo yes || echo "no(rc=$RC)")"
fi

# ---------------------------------------------------------------- send -------

if should_run T12 target; then
  fixture_dir "t12"
  # Prompt is not accepted: herdr reports agent_prompt_stalled, the text does
  # not appear in the pane, the status stays idle. That must NOT look like
  # success — otherwise the orchestrator waits for work that never started.
  fixture a idle idle idle idle idle idle idle idle
  pane_text a "empty composer"
  printf 'agent_prompt_stalled\n' > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  uncertain=no
  case "$ERR" in *UNCERTAIN*) uncertain=yes ;; esac
  check T12 target "send: prompt not accepted -> exit 75 (uncertain), not 0" \
        "75|yes" "$RC|$uncertain"
fi

if should_run T13 target; then
  fixture_dir "t13"
  # Hard error (no agent_prompt_stalled) -> exit 1, no silent success.
  fixture a idle idle idle idle
  pane_text a "whatever"
  printf 'connection reset by peer\n' > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  check T13 target "send: hard herdr error -> exit 1" "1" "$RC"
fi

# T163: herdr 0.9.0 error classification + enter nudge protocol.
# T163d omitted: T13 already covers the generic error (`connection reset by
# peer` → exit 1) exactly.
# Marker in the pane ("do something"): old path → exit 75 (UNCERTAIN + cross-check),
# new path → exit 1 without a recent-unwrapped read. .count.a = 2 (pane_id_of +
# pre-check); the old path calls send_accepted and lands at 3.

if should_run T163a target; then
  fixture_dir "t163a"
  fixture a idle idle idle idle
  pane_text a "do something"
  printf '%s\n' '{"error":{"code":"agent_blocked","message":"agent already blocked"},"id":"cli:agent:prompt"}' \
    > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  side="$(side_log)"
  n_prompt="$(printf '%s\n' "$side" | grep -c '^prompt a ' || true)"
  nudge=no
  case "$side" in *"agent-keys"*enter*) nudge=yes ;; esac
  has=no; case "$ERR" in *"nothing sent"*) has=yes ;; esac
  reads="$(cat "$FAKE_HERDR_DIR/.reads.a" 2>/dev/null || true)"
  count="$(cat "$FAKE_HERDR_DIR/.count.a" 2>/dev/null || true)"
  check T163a target "send: agent_blocked -> exit 1, nothing sent, no cross-check" \
        "1|yes|1|no|visible 40|2" "$RC|$has|$n_prompt|$nudge|$reads|$count"
fi

if should_run T163b target; then
  fixture_dir "t163b"
  fixture a idle idle idle idle
  pane_text a "do something"
  printf '%s\n' '{"error":{"code":"pane_exited","message":"pane exited during prompt"},"id":"cli:agent:prompt"}' \
    > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  side="$(side_log)"
  n_prompt="$(printf '%s\n' "$side" | grep -c '^prompt a ' || true)"
  nudge=no
  case "$side" in *"agent-keys"*enter*) nudge=yes ;; esac
  has=no; case "$ERR" in *"closed during the handover"*) has=yes ;; esac
  reads="$(cat "$FAKE_HERDR_DIR/.reads.a" 2>/dev/null || true)"
  count="$(cat "$FAKE_HERDR_DIR/.count.a" 2>/dev/null || true)"
  check T163b target "send: pane_exited -> exit 1, handover ended, no cross-check" \
        "1|yes|1|no|visible 40|2" "$RC|$has|$n_prompt|$nudge|$reads|$count"
fi

if should_run T163c target; then
  fixture_dir "t163c"
  fixture a idle idle idle idle
  pane_text a "do something"
  printf '%s\n' '{"error":{"code":"agent_not_found","message":"agent target a not found"},"id":"cli:agent:prompt"}' \
    > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  side="$(side_log)"
  n_prompt="$(printf '%s\n' "$side" | grep -c '^prompt a ' || true)"
  has=no; case "$ERR" in *"is gone per herdr (agent_not_found)"*) has=yes ;; esac
  reads="$(cat "$FAKE_HERDR_DIR/.reads.a" 2>/dev/null || true)"
  count="$(cat "$FAKE_HERDR_DIR/.count.a" 2>/dev/null || true)"
  check T163c target "send: agent_not_found -> exit 1, gone, no cross-check" \
        "1|yes|1|visible 40|2" "$RC|$has|$n_prompt|$reads|$count"
fi

if should_run T163e target; then
  fixture_dir "t163e"
  # stalled + marker in the pane + status stays idle → enter nudge path.
  fixture a idle idle idle idle idle idle idle idle idle idle idle idle idle idle idle idle idle idle
  fixture_kind a claude
  pane_text a "do something in the composer"
  printf 'agent_prompt_stalled\n' > "$FAKE_HERDR_DIR/prompt-fail.a"
  run_herd send a "do something"
  side="$(side_log)"
  nudge_key=no
  case "$side" in *"agent-keys"*enter*) nudge_key=yes ;; esac
  has_nudge=no; case "$ERR" in *"enter nudge"*) has_nudge=yes ;; esac
  has_kind=no; case "$ERR" in *kind=claude*) has_kind=yes ;; esac
  check T163e target "send: enter nudge logs kind=claude, exit 75" \
        "yes|yes|yes|75" "$has_nudge|$has_kind|$nudge_key|$RC"
fi

if should_run T163f target; then
  fixture_dir "t163f"
  fixture a idle idle idle idle idle idle idle idle
  pane_text a "whatever"
  printf '%s\n' 'agent_prompt_stalled' \
    '{"error":{"code":"pane_exited","message":"pane exited during prompt"},"id":"cli:agent:prompt"}' \
    > "$FAKE_HERDR_DIR/prompt-seq.a"
  run_herd send a "do something"
  side="$(side_log)"
  n_prompt="$(printf '%s\n' "$side" | grep -c '^prompt a ' || true)"
  has=no; case "$ERR" in *"closed during the handover"*) has=yes ;; esac
  check T163f target "send: resend pane_exited -> exit 1, two prompts" \
        "1|yes|2" "$RC|$has|$n_prompt"
fi

if should_run T163g target; then
  fixture_dir "t163g"
  fixture a idle idle idle idle idle idle idle idle
  pane_text a "whatever"
  printf '%s\n' 'agent_prompt_stalled' \
    '{"error":{"code":"agent_blocked","message":"agent already blocked"},"id":"cli:agent:prompt"}' \
    > "$FAKE_HERDR_DIR/prompt-seq.a"
  run_herd send a "do something"
  side="$(side_log)"
  n_prompt="$(printf '%s\n' "$side" | grep -c '^prompt a ' || true)"
  has=no; case "$ERR" in *UNCERTAIN*) has=yes ;; esac
  check T163g target "send: resend agent_blocked -> exit 75 UNCERTAIN, two prompts" \
        "75|yes|2" "$RC|$has|$n_prompt"
fi


if should_run T168 target; then
  for variant in permission refused silent; do
    fixture_dir "t168-$variant"
    message=''
    case "$variant" in
      permission) message='herdr: Permission denied opening socket' ;;
      refused) message='herdr: connection refused' ;;
    esac
    printf '%s' "$message" > "$FAKE_HERDR_DIR/.pane-list-error"
    run_herd list
    diagnosis=0; original=0; obsolete=0
    case "$ERR" in *"pane list"*"13"*) diagnosis=1 ;; esac
    case "$ERR" in *"$message"*) original=1 ;; esac
    case "$ERR" in *"requires a running"*) obsolete=1 ;; esac
    check "T168-$variant" target "preflight: $variant, stderr preserved, stdout empty, no action" \
      '2||1|1|0|' "$RC|$OUT|$diagnosis|$original|$obsolete|$(side_log)"
  done
  # Every interactive call site must use the same diagnosis.
  for verb in start send status answer wait watch list read key stop term type usage; do
    fixture_dir "t168-$verb"
    printf 'herdr: Permission denied\n' > "$FAKE_HERDR_DIR/.pane-list-error"
    args=("$verb" a)
    case "$verb" in
      start) args=(start claude --name a) ;;
      send|answer|type) args=("$verb" a text) ;;
      key) args=(key a enter) ;;
      list) args=(list) ;;
      term) args=(term --name a) ;;
    esac
    run_herd "${args[@]}"
    diagnosis=0; case "$ERR" in *"Permission denied"*"pane list"*) diagnosis=1 ;; esac
    check "T168-$verb" target "$verb: shared preflight stops before actions" '2||1|' "$RC|$OUT|$diagnosis|$(side_log)"
  done
  # Full CLI calls without the Herdr environment or without the Herdr binary.
  env -u HERDR_ENV HERD_CONFIG="$WORK/no-config" "$HERD" list > "$WORK/env-out" 2> "$WORK/env-err"
  rc_env=$?; msg=0; case "$(cat "$WORK/env-err")" in *"HERDR_ENV"*) msg=1 ;; esac
  check T168-env target 'name the missing Herdr environment' '2||1' "$rc_env|$(cat "$WORK/env-out")|$msg"
  mkdir -p "$WORK/no-herdr-bin"
  # mktemp: herd.sh creates its private scratch directory at start-up.
  for tool in bash grep dirname rm mktemp; do ln -s "$(command -v "$tool")" "$WORK/no-herdr-bin/$tool"; done
  env HERDR_ENV=1 HERD_CONFIG="$WORK/no-config" PATH="$WORK/no-herdr-bin" "$HERD" list > "$WORK/env-out" 2> "$WORK/env-err"
  rc_cli=$?; msg=0; case "$(cat "$WORK/env-err")" in *"herdr"*"PATH"*) msg=1 ;; esac
  check T168-cli target 'name the missing Herdr CLI' '2||1' "$rc_cli|$(cat "$WORK/env-out")|$msg"
fi

if should_run T169 target; then
  mkdir -p "$WORK/fallback-bin"
  cat > "$WORK/fallback-bin/setsid" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_HERDR_DIR/.setsid"
STUB
  chmod +x "$WORK/fallback-bin/setsid"
  for verb in run exec; do
    fixture_dir "t169-$verb"
    printf 'herdr: Permission denied\n' > "$FAKE_HERDR_DIR/.pane-list-error"
    args=(run --name "test-fallback-$$-$verb" --no-wait -- printf ok)
    if [ "$verb" = exec ]; then args=(exec codex --name "test-fallback-$$-$verb" --no-wait ok); fi
    PATH="$WORK/fallback-bin:$STUB:$PATH" HERD_CONFIG="$WORK/no-config" run_herd "${args[@]}"
    # The fake only replaces the process starter; no real backend is started.
    for ((i=0; i<50; i++)); do
      [ -s "$FAKE_HERDR_DIR/.setsid" ] && break
      sleep 0.01
    done
    launched=0; [ -s "$FAKE_HERDR_DIR/.setsid" ] && launched=1
    reported=0; case "$OUT" in *"via setsid"*) reported=1 ;; esac
    check "T169-$verb" target "$verb: silent setsid fallback despite CLI error" '0||1|1|' "$RC|$ERR|$launched|$reported|$(side_log)"
  done
fi

if should_run T170 target; then
  for variant in survey spinner task approval partial old nearby twofooters foreign; do
    fixture_dir "t170-$variant"
    fixture a idle; fixture_kind a agy
    text="$(cat "$ROOT/tests/fixtures/agy/survey.txt")"
    expected=clean
    case "$variant" in
      spinner) text+=$'\n⠋ Thinking'; expected=busy ;;
      task) text+=$'\n● [12:34:56] command running'; expected=busy ;;
      approval) text+=$'\nDo you want to proceed?'; expected=blocked ;;
      partial) text="${text/\[0\] Skip/}"; expected=busy ;;
      old) for i in {1..12}; do text+=$'\noutput'; done; text+=$'\nesc to cancel'; expected=busy ;;
      nearby) text+=$'\nNew task started\nesc to cancel'; expected=busy ;;
      twofooters) text+=$'\n\nesc to cancel'; expected=busy ;;
      foreign) fixture_kind a grok; text+=$'\n1 command still running'; expected=busy ;;
    esac
    pane_text a "$text"
    run_herd classify-pane p:a
    check "T170-$variant" target "agy survey: $variant" "$expected|0" "$OUT|$RC"
    if [ "$variant" = survey ]; then
      run_herd status a
      check T170-status target 'survey is ready for input' 'idle|0' "$OUT|$RC"
      # Transport test, no simulation of the agy key handler.
      for prompt in 'Please answer briefly' '1. Please answer briefly'; do
        run_herd send a "$prompt"
        sent=0; case "$(side_log)" in *"$prompt"*) sent=1 ;; esac
        check "T170-send-${prompt:0:1}" target 'prompt transported unchanged despite survey' '0|1' "$RC|$sent"
      done
    fi
  done
fi
