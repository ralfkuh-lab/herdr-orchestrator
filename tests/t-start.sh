# ---------------------------------------------------- start / build_cli -------
# build_cli checks backends only via `command -v` → stubs suffice. HERD_PRINT_CLI=1
# makes `start` print the built start command (one argument per line) and end
# before pane creation — no daemon, no real backend needed.


if should_run T33 target; then
  fixture_dir "t33"
  # Precedence for --role impl: default acceptEdits < config < explicit option.
  run_start -- claude --name t
  has_args "--permission-mode acceptEdits" && r1=default || r1="default-wrong($OUT)"
  run_start HERD_IMPL_PERMISSION_MODE=auto -- claude --name t
  has_args "--permission-mode auto" && r2=config || r2=config-wrong
  run_start HERD_IMPL_PERMISSION_MODE=auto -- claude --name t --permission-mode bypassPermissions
  has_args "--permission-mode bypassPermissions" && r3=option || r3=option-wrong
  check T33 target "start claude impl: permission mode default < config < option" \
        "default|config|option" "$r1|$r2|$r3"
fi

if should_run T34 target; then
  fixture_dir "t34"
  # The config variable is named IMPL and must not touch research (read-only!);
  # only the EXPLICIT option may override research too.
  run_start HERD_IMPL_PERMISSION_MODE=auto -- claude --name t --role research
  has_args "--permission-mode plan" && r1=plan || r1="plan-wrong($OUT)"
  run_start -- claude --name t --role research --permission-mode acceptEdits
  has_args "--permission-mode acceptEdits" && r2=option || r2=option-wrong
  check T34 target "start claude research: config has no effect, explicit option does" \
        "plan|option" "$r1|$r2"
fi

if should_run T183 target; then
  fixture_dir "t183"
  # --role orchestrator: claude without the sub-agent lock (successor
  # orchestrator), permission mode like impl; other backends reject the role.
  run_start -- claude --name t
  has_args "--append-system-prompt" && r1=impl-lock || r1="impl-lock-missing($OUT)"
  run_start -- claude --name t --role orchestrator --permission-mode auto
  if ! has_args "--append-system-prompt" && has_args "--permission-mode auto"; then r2=orch-without-lock; else r2="orch-wrong($OUT)"; fi
  run_start -- codex --name t --role orchestrator --cwd "$WORK"
  [ "$RC" = 2 ] && r3=codex-rejected || r3="codex-rc$RC"
  check T183 target "start --role orchestrator: claude without lock, other backends exit 2" \
        "impl-lock|orch-without-lock|codex-rejected" "$r1|$r2|$r3"
fi

if should_run T35 target; then
  fixture_dir "t35"
  # grok shares the claude logic (perm_mode_for) — cross-check once.
  run_start HERD_IMPL_PERMISSION_MODE=auto -- grok --name t --cwd "$WORK"
  has_args "--permission-mode auto" && r1=config || r1="config-wrong($OUT)"
  check T35 target "start grok impl: config permission mode applies to grok too" \
        "config" "$r1"
fi

if should_run T36 target; then
  fixture_dir "t36"
  # copilot has two independent axes: --mode (work mode, fed from --role or
  # --permission-mode) and --yolo (auto-approval). Together they replace the
  # former catch-all variable HERD_IMPL_COPILOT_FLAGS.
  run_start -- copilot --name t
  if ! has_args "--mode" && has_args "-n t"; then r1=impl-default; else r1="impl-wrong($OUT)"; fi
  run_start -- copilot --name t --role research
  has_args "--mode plan" && r2=research-plan || r2="research-wrong($OUT)"
  run_start -- copilot --name t --permission-mode autopilot
  has_args "--mode autopilot" && r3=pmode-impl || r3="pmode-impl-wrong($OUT)"
  # explicit option overrides BOTH roles (as with agy/muse)
  run_start -- copilot --name t --role research --permission-mode autopilot
  if has_args "--mode autopilot" && ! has_args "--mode plan"; then r4=pmode-research; else r4="pmode-research-wrong($OUT)"; fi
  run_start -- copilot --name t --yolo --permission-mode autopilot
  if has_args "--yolo" && has_args "--mode autopilot"; then r5=yolo-plus-mode; else r5="yolo-wrong($OUT)"; fi
  check T36 target "start copilot: --mode from role/--permission-mode, --yolo as its own axis" \
        "impl-default|research-plan|pmode-impl|pmode-research|yolo-plus-mode" "$r1|$r2|$r3|$r4|$r5"
fi

if should_run T36b target; then
  fixture_dir "t36b"
  # --effort previously ended up NOWHERE for copilot (silently swallowed) —
  # that is the core of this test: cross-reviews should run at 'medium'.
  run_start -- copilot --name t --model gpt-6-astra --effort medium
  has_args "--reasoning-effort medium" && r1=effort || r1="effort-wrong($OUT)"
  # Context tier ALWAYS explicit; otherwise copilot persists the setting and
  # an old long_context would silently keep working (double rate from 272k input).
  run_start -- copilot --name t
  has_args "--context default" && r2=ctx-default || r2="ctx-default-wrong($OUT)"
  run_start -- copilot --name t --context long_context
  if has_args "--context long_context" && ! has_args "--context default"; then r3=ctx-long; else r3="ctx-long-wrong($OUT)"; fi
  run_start -- copilot --name t --model auto --auto-tier intelligence --max-ai-credits 500
  if has_args "--auto-tier intelligence" && has_args "--max-ai-credits 500"; then r4=tier-credits; else r4="tier-credits-wrong($OUT)"; fi
  # Resume: session name only for NEW sessions, otherwise it collides with -r/--continue.
  run_start -- copilot --name t --resume ses_9
  if has_args "-r ses_9" && ! has_args "-n t"; then r5=resume; else r5="resume-wrong($OUT)"; fi
  run_start -- copilot --name t --resume
  if has_args "--continue" && ! has_args "-n t"; then r6=continue; else r6="continue-wrong($OUT)"; fi
  check T36b target "start copilot: --reasoning-effort, --context, --auto-tier, --max-ai-credits, resume" \
        "effort|ctx-default|ctx-long|tier-credits|resume|continue" "$r1|$r2|$r3|$r4|$r5|$r6"
fi

if should_run T36c target; then
  fixture_dir "t36c"
  # Invalid values must fail BEFORE pane creation: copilot exits immediately on
  # argument errors, otherwise the pane would silently die.
  for bad in "--permission-mode acceptEdits" "--context foo" "--auto-tier foo" "--max-ai-credits 10" "--max-ai-credits abc"; do
    run_start -- copilot --name t $bad
    [ "$RC" = 2 ] || { checks36c="rc=$RC at $bad"; break; }
  done
  r1="${checks36c:-all-rejected}"
  # copilot-specific switches exist only for copilot.
  run_start -- claude --name t --yolo
  [ "$RC" = 2 ] && r2=yolo-only-copilot || r2="yolo-rc=$RC"
  run_start -- claude --name t --context default
  [ "$RC" = 2 ] && r3=context-only-copilot || r3="context-rc=$RC"
  # Missing value / flag as value: clean exit 2 instead of a $2 abort under set -u.
  run_start -- copilot --name t --context
  rc_empty=$RC
  run_start -- copilot --name t --context --resume
  [ "$rc_empty" = 2 ] && [ "$RC" = 2 ] && r4=value-required || r4="value-required($rc_empty/$RC)"
  check T36c target "start copilot: invalid values and foreign backends -> exit 2 before the pane" \
        "all-rejected|yolo-only-copilot|context-only-copilot|value-required" "$r1|$r2|$r3|$r4"
fi

if should_run T36e target; then
  fixture_dir "t36e"
  # herdr's name rule (valid_agent_name): a-z at the start, then a-z0-9_-,
  # at most 32 characters. Violations fail BEFORE the pane split — otherwise
  # an orphaned pane would stay open after invalid_agent_name.
  r1=all-rejected
  for bad in impl-A 1impl -impl "impl a" impl.x "a$(printf 'b%.0s' {1..32})"; do
    rm -f "$FAKE_HERDR_DIR/.side"
    run_start -- claude --name "$bad"
    if [ "$RC" != 2 ] || side_log | grep -q pane-split || [[ "$ERR" != *"invalid name"* ]]; then
      r1="rc=$RC at '$bad'"; break
    fi
  done
  # Boundary cases on the allowed side pass the check.
  r2=allowed
  for ok in a impl-a_2 "a$(printf 'b%.0s' {1..31})"; do
    run_start -- claude --name "$ok"
    [[ "$ERR" != *"invalid name"* ]] || { r2="rejected: '$ok'"; break; }
  done
  check T36e target "start: invalid agent name -> exit 2 before the pane split, valid ones pass" \
        "all-rejected|allowed" "$r1|$r2"
fi

if should_run T36d target; then
  fixture_dir "t36d"
  # exec (batch) shares the switches; additionally the usage statistics fall
  # as JSON next to the log — `herd.sh usage` cannot query copilot.
  run_exec copilot --cwd "$WORK" --model gpt-6-astra --effort medium "hello"
  if has_args "--reasoning-effort medium" && has_args "--context default"; then r1=exec-flags; else r1="exec-flags-wrong($OUT)"; fi
  usage36d=no; case "$OUT" in *"--usage-output-file"*"/usage.json"*) usage36d=yes ;; esac
  run_exec copilot --cwd "$WORK" --context long_context --max-ai-credits 99 "hello"
  if has_args "--context long_context" && has_args "--max-ai-credits 99"; then r2=exec-opts; else r2="exec-opts-wrong($OUT)"; fi
  run_exec copilot --cwd "$WORK" --context foo "hello"
  [ "$RC" = 2 ] && r3=exec-bad || r3="exec-bad-rc=$RC"
  run_exec codex --cwd "$WORK" --context default "hello"
  [ "$RC" = 2 ] && r4=exec-only-copilot || r4="exec-only-copilot-rc=$RC"
  check T36d target "exec copilot: --reasoning-effort/--context/--max-ai-credits, usage.json, values checked" \
        "exec-flags|yes|exec-opts|exec-bad|exec-only-copilot" "$r1|$usage36d|$r2|$r3|$r4"
fi

if should_run T36f target; then
  fixture_dir "t36f"
  # --spec frames the file neutrally: it may hold a review brief, not only an
  # implementation spec.
  printf 'brief\n' > "$WORK/brief.md"
  run_exec codex --cwd "$WORK" --spec "$WORK/brief.md" "go"
  r=wrong; case "$OUT" in *"Follow the instructions in the file $WORK/brief.md. go"*) r=ok ;; esac
  case "$OUT" in *"Implement the specification"*) r=still-implement ;; esac
  check T36f target "exec --spec: neutral prompt prefix" "0|ok" "$RC|$r"
fi

if should_run T37 target; then
  fixture_dir "t37"
  # Three usage errors, all clean exit 2: missing value (would be a $2 abort
  # under set -u), EMPTY value (would silently fall back to the default and
  # bypass the backend check) and a flag as value ("--permission-mode
  # --resume" would swallow --resume). And: the option must survive the
  # --resume path — mode AND resume flag (-c) in the command.
  run_start -- claude --name t --permission-mode
  [ "$RC" = 2 ] && r1=without-value || r1="without-value(rc=$RC)"
  run_start -- claude --name t --permission-mode ""
  [ "$RC" = 2 ] && r2=empty || r2="empty(rc=$RC)"
  run_start -- claude --name t --permission-mode --resume
  [ "$RC" = 2 ] && r3=flag-as-value || r3="flag-as-value(rc=$RC)"
  run_start -- claude --name t --permission-mode auto --resume
  if has_args "--permission-mode auto" && has_args "-c"; then r4=resume; else r4="resume-wrong($OUT)"; fi
  check T37 target "start: --permission-mode missing/empty/flag-value -> exit 2; survives --resume" \
        "without-value|empty|flag-as-value|resume" "$r1|$r2|$r3|$r4"
fi


# ------------------------------------------------ pi as the ninth backend -----
# Spec: .herd/spec-pi-cloud.md. T162a–p.

if should_run T162 target; then
  fixture_dir "t162"

  # T162a: --model provider/id → no --provider, --approve upfront (opt-in trust)
  run_start HERD_AUTO_TRUST=1 -- pi --name t --model opencode-go/deepseek-v4.1-flash
  if has_args "--model opencode-go/deepseek-v4.1-flash" && has_args "--approve" && ! has_args "--provider" && [ "$(echo "$OUT" | head -1)" = pi ]; then r=ok; else r="wrong($OUT)"; fi
  check T162a target "start pi --model provider/id: --model without --provider" \
        "0|ok" "$RC|$r"

  # T162b: --model X + HERD_PI_PROVIDER=freetoken → --provider freetoken --model X
  run_start HERD_PI_PROVIDER=freetoken -- pi --name t --model X
  if has_args "--provider freetoken" && has_args "--model X"; then r=ok; else r="wrong($OUT)"; fi
  check T162b target "start pi --model X + HERD_PI_PROVIDER=freetoken: --provider freetoken --model X" \
        "0|ok" "$RC|$r"

  # T162c: without a model → exit 2, hint pi --list-models (cloud example, no llamacpp)
  run_start -- pi --name t
  has_hint=no; case "$ERR" in *"--list-models"*) has_hint=yes ;; esac
  has_cloud=no; case "$ERR" in *"opencode-go/deepseek-v4.1-flash"*) has_cloud=yes ;; esac
  has_llama=yes; case "$ERR" in *"llamacpp"*) ;; *) has_llama=no ;; esac
  check T162c target "start pi without a model: exit 2, hint pi --list-models (no llamacpp)" \
        "2|yes|yes|no" "$RC|$has_hint|$has_cloud|$has_llama"

  # T162d: research → --tools read,bash
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash --role research
  if has_args "--tools read,bash"; then r=ok; else r="wrong($OUT)"; fi
  check T162d target "start pi research: --tools read,bash" \
        "0|ok" "$RC|$r"

  # T162e: --effort high → --thinking high
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash --effort high
  if has_args "--thinking high"; then r=ok; else r="wrong($OUT)"; fi
  check T162e target "start pi --effort high: --thinking high" \
        "0|ok" "$RC|$r"

  # T162f: --resume / --resume abc → -c / --session abc
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash --resume
  r1=wrong; has_args "-c" && r1=ok
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash --resume abc
  r2=wrong; has_args "--session abc" && ! has_args "-c" && r2=ok
  check T162f target "start pi --resume: -c / --session abc" \
        "ok|ok" "$r1|$r2"

  # T162g: --permission-mode never → exit 2
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash --permission-mode never
  has_pi_perm=no; case "$ERR" in *"pi: no permission mode"*) has_pi_perm=yes ;; esac
  check T162g target "start pi --permission-mode never: exit 2, pi: no permission mode" \
        "2|yes" "$RC|$has_pi_perm"

  # T162h: exec pi → env -C <cwd> pi -p --no-session …
  run_exec pi --cwd "$WORK" --model opencode-go/deepseek-v4.1-flash "hello"
  if has_args "env -C $WORK pi -p --no-session" && has_args "--model opencode-go/deepseek-v4.1-flash" && ! has_args "--provider"; then r=ok; else r="wrong($OUT)"; fi
  check T162h target "exec pi: env -C <cwd> pi -p --no-session --model provider/id" \
        "0|ok" "$RC|$r"

  # T162i: usage with kind pi → rejection (quotas not readable)
  fixture_dir "t162i"
  fixture o idle
  fixture_kind o pi
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage o
  side="$(side_log)"
  has_unsupp_err=no
  case "$ERR" in *"pi shows no quotas"*) has_unsupp_err=yes ;; esac
  has_local=yes; case "$ERR" in *"local models"*) ;; *) has_local=no ;; esac
  check T162i target "usage pi: rejection before sending (.side empty, exit 1)" \
        "1||yes|no" "$RC|$side|$has_unsupp_err|$has_local"

  # T162j: classify-pane --kind pi: working.txt → busy, idle-after-task.txt → clean
  fixture_dir "t162j"
  fixture a idle
  pane_text a "$(cat "$ROOT/tests/fixtures/pi/working.txt")"
  run_herd classify-pane p:a --kind pi
  r_busy="$OUT|$RC"
  pane_text a "$(cat "$ROOT/tests/fixtures/pi/idle-after-task.txt")"
  run_herd classify-pane p:a --kind pi
  check T162j target "classify-pane --kind pi: working.txt busy, idle-after-task.txt clean" \
        "busy|0|clean|0" "$r_busy|$OUT|$RC"

  # T162j2: reverse busy — working.txt with a foreign kind → clean.
  # --kind agy would be busy (agy matches any Braille spinner); grok is
  # spinner-free and stays clean (agy review; muse: spinner-free kinds).
  pane_text a "$(cat "$ROOT/tests/fixtures/pi/working.txt")"
  run_herd classify-pane p:a --kind grok
  check T162j2 target "classify-pane --kind grok on pi working.txt -> clean" \
        "clean|0" "$OUT|$RC"

  # T162k: kinds file without pi → start pi exit 2 (herdr_kind_known)
  fixture_dir "t162k"
  echo "codex,claude" > "$FAKE_HERDR_DIR/kinds"
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash
  has_kind_err=no; case "$ERR" in *"does not know the backend kind 'pi'"*) has_kind_err=yes ;; esac
  check T162k target "start pi with a kinds file without pi -> exit 2 (herdr_kind_known)" \
        "2|yes" "$RC|$has_kind_err"

  # T162l: :thinking suffix + --effort → exit 2
  fixture_dir "t162l"
  run_start -- pi --name t --model opencode-go/deepseek-v4.1-flash:high --effort low
  has_suffix_err=no; case "$ERR" in *"either a suffix in the model or --effort"*) has_suffix_err=yes ;; esac
  check T162l target "start pi :thinking suffix + --effort -> exit 2" \
        "2|yes" "$RC|$has_suffix_err"

  # T162m: --model X without (empty/unset) HERD_PI_PROVIDER → exit 2, hint provider/id
  # Set HERD_PI_PROVIDER= empty; lib.sh additionally removes pi's own
  # PI_* variables from the caller environment (K2).
  fixture_dir "t162m"
  run_start HERD_PI_PROVIDER= -- pi --name t --model Qwen3.6-35B
  has_pid=no; case "$ERR" in *"provider/id"*) has_pid=yes ;; esac
  check T162m target "start pi --model X without HERD_PI_PROVIDER: exit 2, hint provider/id" \
        "2|yes" "$RC|$has_pid"

  # T162n: HERD_PI_PROJECT_TRUST default/empty → approve (with HERD_AUTO_TRUST=1;
  # the default without it is covered by TSEC5), ignore → --no-approve, invalid → exit 2
  fixture_dir "t162n"
  run_start HERD_AUTO_TRUST=1 -- pi --name t --model a/b
  r1=wrong; has_args "--approve" && r1=ok
  run_start HERD_AUTO_TRUST=1 HERD_PI_PROJECT_TRUST= -- pi --name t --model a/b
  r1b=wrong; has_args "--approve" && r1b=ok
  run_start HERD_PI_PROJECT_TRUST=ignore -- pi --name t --model a/b
  r2=wrong; if has_args "--no-approve" && ! has_args "--approve"; then r2=ok; fi
  run_start HERD_PI_PROJECT_TRUST=foo -- pi --name t --model a/b
  has_var=no; case "$ERR" in *"HERD_PI_PROJECT_TRUST"*) has_var=yes ;; esac
  has_vals=no; case "$ERR" in *"approve|ignore"*) has_vals=yes ;; esac
  check T162n target "start pi: HERD_PI_PROJECT_TRUST default/empty/ignore/invalid" \
        "ok|ok|ok|2|yes|yes" "$r1|$r1b|$r2|$RC|$has_var|$has_vals"

  # T162o: exec pi --model a/b → --approve; ignore → --no-approve; foo → exit 2
  fixture_dir "t162o"
  run_exec HERD_AUTO_TRUST=1 -- pi --cwd "$WORK" --model a/b "hello"
  r1=wrong; has_args "--approve" && r1=ok
  run_exec HERD_PI_PROJECT_TRUST=ignore -- pi --cwd "$WORK" --model a/b "hello"
  r2=wrong; if has_args "--no-approve" && ! has_args "--approve"; then r2=ok; fi
  run_exec HERD_PI_PROJECT_TRUST=foo -- pi --cwd "$WORK" --model a/b "hello"
  has_var=no; case "$ERR" in *"HERD_PI_PROJECT_TRUST"*) has_var=yes ;; esac
  check T162o target "exec pi: --approve / ignore -> --no-approve / invalid -> exit 2" \
        "ok|ok|2|yes" "$r1|$r2|$RC|$has_var"

  # T162p (regression K1): pi's own variables must not act as provider/trust
  fixture_dir "t162p"
  run_start PI_PROVIDER=opencode-go -- pi --name t --model X
  rc1=$RC
  r1=no; [ "$rc1" = 2 ] && r1=yes
  run_start HERD_AUTO_TRUST=1 PI_PROJECT_TRUST=ignore -- pi --name t --model a/b
  r2=wrong; has_args "--approve" && r2=ok
  check T162p target "start pi: old PI_PROVIDER/PI_PROJECT_TRUST are ignored" \
        "2|yes|ok" "$rc1|$r1|$r2"
fi


if should_run T171 target; then
  fixture_dir "t171"
  for role in impl research; do
    run_start -- opencode --name t --model test/model --effort high --role "$role"
    agent=build; [ "$role" = research ] && agent=plan
    ok=no; if has_args "run $ROOT test/model high opencode -m test/model --agent $agent $ROOT"; then ok=yes; fi
    check "T171-$role" target 'OpenCode start with isolated variant and role' '0|yes' "$RC|$ok"
  done
  run_start OPENCODE_PROVIDER=test MODEL_OPENCODE=model -- opencode --name t --effort custom
  check T171-default target 'config model and custom variant' '0' "$RC"
  for variant in bogus disabled; do
    run_start -- opencode --name t --model test/model --effort "$variant"
    check "T171-$variant" target 'unknown/disabled variant fails before the pane' '2|' "$RC|$OUT"
  done
  for mode in fail bad nullvariant listvariants listmodel; do
    run_start FAKE_OPENCODE_CATALOG="$mode" -- opencode --name t --model test/model --effort high
    check "T171-$mode" target 'catalog error fails before the pane' '2|' "$RC|$OUT"
  done
  run_start -- opencode --name t --effort high
  check T171-model target 'variant needs an unambiguous model' '2|' "$RC|$OUT"
  run_start -- opencode --name t --model test/model --effort high --resume
  check T171-resume target 'do not silently bypass a stored variant' '2|' "$RC|$OUT"
  run_start -- opencode --name t --effort ''
  check T171-empty target 'empty effort value is an error' '2|' "$RC|$OUT"
  run_start -- opencode --name t --model test/model --resume ses_123
  want=$(printf 'opencode\n-s\nses_123\n-m\ntest/model\n--agent\nbuild\n%s' "$ROOT")
  check T171-unchanged target 'resume command unchanged without effort' "$want|0" "$OUT|$RC"

fi

if should_run T172 target; then
  fixture_dir "t172"
  fixture t idle; fixture_kind t opencode
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  HERD_CONFIG="$WORK/no-config" run_herd start opencode --name t --model test/model --effort high --timeout 1
  invoked=no; canonical=no
  # Only the call of the command file is typed; the wrapper is inside it
  # (the fake logs its content as pane-run-file).
  case "$(side_log)" in *"pane-run p:t bash /"*"/cmd.sh"*'pane-run-file python3 '*'herd_opencode.py run '*'test/model high opencode '*) invoked=yes ;; esac
  # Unique fake entry for EVERY real `agent start` call; match at the line
  # start, since a checkout path like …/repo-agent-start appears in the middle
  # of a `pane-run-file …` side-log line as well.
  side_log | grep -q '^agent-start ' && canonical=yes
  check T172 target 'real start path passes the wrapper to pane run (command file), not agent start' '0|yes|no' "$RC|$invoked|$canonical"
fi

if should_run T172b target; then
  fixture_dir "t172b"
  fixture t idle; fixture_kind t claude
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  # HERD_START_VIA=run (Windows default via auto): no agent start, pane run
  # types only the short call; the full command incl. role lock is in the
  # file, which is deleted again after a successful start.
  HERD_START_VIA=run HERD_CONFIG="$WORK/no-config" run_herd start claude --name t --timeout 1
  r1="$RC"
  # The path is %q-quoted; test paths contain nothing %q would escape.
  cmdfile="$(side_log | sed -n "s/.*pane-run p:t bash \([^ ]*\/cmd\.sh\).*/\1/p" | head -1)"
  infile=no; canonical=no; note=no; gone=no
  case "$(side_log)" in *'pane-run-file claude '*--append-system-prompt*) infile=yes ;; esac
  [ -n "$cmdfile" ] && [ ! -e "$cmdfile" ] && gone=yes
  # Unique fake entry for every real `agent start` call (see T172), at the
  # line start.
  side_log | grep -q '^agent-start ' && canonical=yes
  case "$ERR" in *'starting claude via pane run'*) note=yes ;; esac
  # Invalid value: exit 2 before the pane split.
  fixture_dir "t172b-bad"
  HERD_START_VIA=foo HERD_CONFIG="$WORK/no-config" run_herd start claude --name t --timeout 1
  split=no; side_log | grep -q pane-split && split=yes
  check T172b target 'HERD_START_VIA=run: command file instead of agent start, deleted afterwards; invalid value -> exit 2 before the split' \
        '0|yes|yes|no|yes|2|no' "$r1|$infile|$gone|$canonical|$note|$RC|$split"
fi

if should_run T172c target; then
  # prune_logdirs: age from the name stamp, not from the modification time
  # (the Windows temp cleanup sets it to now when emptying).
  # Only folders with the log name pattern; 0/invalid = off.
  root="$WORK/t172c-logs"
  survivors="$(run_herd_fn '
    root="'"$root"'"
    # Compute the stamp once: two date calls can fall into different
    # seconds, then touch would create a second file.
    old="$(date -d "10 days ago" +%Y%m%d-%H%M%S)"
    limit="$(date -d "6 days ago" +%Y%m%d-%H%M%S)"
    new="$(date -d "1 hour ago" +%Y%m%d-%H%M%S)"
    reset() { rm -rf "$root"; mkdir -p "$root"
              mkdir "$root/$old-old"                         # old, fresh mtime
              mkdir "$root/$limit-limit"
              mkdir "$root/$new-new"; touch -d "30 days ago" "$root/$new-new"
              mkdir "$root/foreign-folder"; touch -d "30 days ago" "$root/foreign-folder"
              printf x > "$root/$old-file"; }
    list() { ls "$root" | sed "s/^[0-9]\{8\}-[0-9]\{6\}-//" | sort | paste -sd " " -; }
    reset; prune_logdirs "$root" 7; echo "7: $(list)"
    reset; prune_logdirs "$root" 0; echo "0: $(list)"
    reset; prune_logdirs "$root" abc; echo "abc: $(list)"
    prune_logdirs "$root/missing" 7; echo "missing: rc=$?"
  ')"
  want="7: file foreign-folder limit new
0: file foreign-folder limit new old
abc: file foreign-folder limit new old
missing: rc=0"
  check T172c target 'prune_logdirs: age from the name, foreign names and files stay; 0/invalid = off' \
        "$want" "$survivors"
fi

if should_run T172d target; then
  # prune_herd_workdirs: .herd/ in the main checkout is pruned even from a
  # worktree; folders count by their newest file, questions/ stays.
  repo="$WORK/t172d-repo"
  survivors="$(run_herd_fn '
    repo="'"$repo"'"; wt="$repo-wt"; h="$repo/.herd"
    reset() { rm -rf "$repo" "$wt"; mkdir -p "$repo"
              git -C "$repo" init -q
              git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
              git -C "$repo" worktree add -q "$wt" 2>/dev/null
              mkdir -p "$h/old-folder" "$h/active-folder" "$h/questions"
              printf x > "$h/old.md";  touch -d "20 days ago" "$h/old.md"
              printf x > "$h/.old-dot"; touch -d "20 days ago" "$h/.old-dot"
              printf x > "$h/new.md"
              printf x > "$h/old-folder/a"; touch -d "20 days ago" "$h/old-folder/a" "$h/old-folder"
              printf x > "$h/active-folder/a"; touch -d "20 days ago" "$h/active-folder/a"
              printf x > "$h/active-folder/b"; touch -d "20 days ago" "$h/active-folder"
              printf x > "$h/questions/q.md"; touch -d "20 days ago" "$h/questions/q.md" "$h/questions"; }
    list() { ls -A "$h" | LC_ALL=C sort | paste -sd " " -; }
    reset; prune_herd_workdirs "$wt" 14; echo "wt: $(list)"
    reset; prune_herd_workdirs "$repo" 0; echo "0: $(list)"
    reset; prune_herd_workdirs "$repo" abc; echo "abc: $(list)"
    prune_herd_workdirs "$repo/missing" 14; echo "missing: rc=$?"
    mkdir -p "$repo/../t172d-plain/.herd"; prune_herd_workdirs "$repo/../t172d-plain" 14; echo "plain: rc=$?"
  ')"
  want="wt: active-folder new.md questions
0: .old-dot active-folder new.md old-folder old.md questions
abc: .old-dot active-folder new.md old-folder old.md questions
missing: rc=0
plain: rc=0"
  check T172d target 'prune_herd_workdirs: main checkout from a worktree, folders by newest file, questions/ stays; 0/invalid = off' \
        "$want" "$survivors"
fi

if should_run T173 target; then
  fixture_dir "t173"
  printf 'p:dead\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text dead 'user@host:~/x$'
  cat > "$FAKE_HERDR_DIR/pane-after-3.dead" <<'PANE'
user@host:~/x$ python3 /repo/scripts/herd_opencode.py run /repo test/model high opencode
[herd] opencode: invalid configuration
user@host:~/x$
PANE
  t0=$(date +%s)
  HERD_CONFIG="$WORK/no-config" run_herd start opencode --name dead --model test/model --effort high --timeout 1
  dt=$(( $(date +%s) - t0 ))
  closed=no; diagnostic=no; fast=no
  case "$(side_log)" in *'close p:dead'*) closed=yes ;; esac
  case "$ERR" in *'ended before herdr recognized it'*'invalid configuration'*) diagnostic=yes ;; esac
  [ "$dt" -lt 6 ] && fast=yes
  check T173 target 'wrapper start error: fast diagnosis and pane closed' '1|yes|yes|yes' "$RC|$diagnostic|$closed|$fast"
fi

if should_run T174 target; then
  mkdir -p "$WORK/original-state/locks"
  printf '%s' '{"variant":{"test/model":"high","other/model":"custom"},"recent":[{"modelID":"model","providerID":"test"}],"favorite":[]}' > "$WORK/original-state/model.json"
  printf 'history remains\n' > "$WORK/original-state/prompt-history.jsonl"
  printf '{"theme":"keep"}' > "$WORK/original-state/kv.json"
  before=$(cksum "$WORK/original-state/model.json")
  result=$(PATH="$ROOT/tests/bin:$PATH" FAKE_OPENCODE_STATE_DIR="$WORK/original-state" TMPDIR="$WORK" OPENCODE_CONFIG_CONTENT='{/* native JSONC */}' python3 "$ROOT/scripts/herd_opencode.py" run "$ROOT" test/model low opencode -m test/model)
  rc=$?
  verified=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["model"]["variant"]["test/model"],d["model"]["variant"]["other/model"],len(d["model"]["recent"]),d["inline"]=="{/* native JSONC */}",d["history"]=="history remains\n",d["kv"]=="{\"theme\":\"keep\"}",d["locks"],d["argv"]==["-m","test/model"])' "$result")
  check T174-state target 'low in the private copy, original high and other settings preserved' '0|low custom 1 True True True False True|same' "$rc|$verified|$([ "$before" = "$(cksum "$WORK/original-state/model.json")" ] && echo same)"
  printf '{broken' > "$WORK/original-state/model.json"
  result=$(PATH="$ROOT/tests/bin:$PATH" FAKE_OPENCODE_STATE_DIR="$WORK/original-state" TMPDIR="$WORK" python3 "$ROOT/scripts/herd_opencode.py" run "$ROOT" test/model low opencode 2>"$WORK/state-err")
  rc=$?; trace=no; case "$(cat "$WORK/state-err")" in *Traceback*) trace=yes ;; esac
  check T174-invalid target 'clearly reject a broken state, do not start a TUI' '2||no' "$rc|$result|$trace"
fi

# ------------------------------------------------- TST: herdr start diagnoses --
# Package "start": server version in diagnoses (herdr status --json) and
# codex trust override. The numbers carry the TST prefix so they do not collide
# with parallel packages.
if should_run TST1 target; then
  fixture_dir "tst1"
  repo="$WORK/tst1-repo"; git init -q "$repo"
  top="$(git -C "$repo" rev-parse --show-toplevel)"
  run_start HERD_AUTO_TRUST=1 -- codex --name t --cwd "$repo"
  r=not
  if has_args "-c" && has_args "projects={\"$top\"={trust_level=\"trusted\"}}"; then r=ok; fi
  check TST1 target "start codex new: -c override marks the git toplevel as trusted" \
        "ok" "$r"
fi

if should_run TST2 target; then
  fixture_dir "tst2"
  repo="$WORK/tst2-repo"; git init -q "$repo"
  run_start HERD_AUTO_TRUST=1 -- codex --name t --cwd "$repo" --resume
  r=ok; case "$OUT" in *"projects="*) r="wrong($OUT)" ;; esac
  check TST2 target "start codex --resume: no trust override" \
        "ok" "$r"
fi

if should_run TST3 target; then
  fixture_dir "tst3"
  repo="$WORK/tst3-repo"; git init -q "$repo"; mkdir -p "$repo/sub/dir"
  top="$(git -C "$repo" rev-parse --show-toplevel)"
  run_start HERD_AUTO_TRUST=1 -- codex --name t --cwd "$repo/sub/dir"
  r=not
  if has_args "projects={\"$top\"={trust_level=\"trusted\"}}" && ! has_args "projects={\"$repo/sub/dir\""; then r=ok; fi
  check TST3 target "start codex: trust override names the toplevel, not the subdirectory" \
        "ok" "$r"
fi

if should_run TST4 target; then
  fixture_dir "tst4"
  want="[herd] note: herdr server (0.9.1) is running an old binary (client 0.7.5 (fake)) — restart needed, update with 'herdr update --handoff'"
  # restart_needed -> exactly one note line; start continues normally.
  run_start HERD_FAKE_STATUS_JSON='{"client":{"version":"0.9.3"},"server":{"status":"running","running":true,"version":"0.9.1"},"update":{"restart_needed":true,"server_binary_stale":false}}' \
    -- claude --name t
  n1="$(printf '%s\n' "$ERR" | grep -cF "$want")"
  r1="wrong(rc=$RC,n=$n1,err=$ERR)"
  if [ "$RC" = 0 ] && [ "$n1" = 1 ] && has_args "claude"; then r1=ok; fi
  # server_binary_stale (without restart_needed) counts the same way.
  run_start HERD_FAKE_STATUS_JSON='{"server":{"running":true,"version":"0.9.1"},"update":{"restart_needed":false,"server_binary_stale":true}}' \
    -- claude --name t
  n2="$(printf '%s\n' "$ERR" | grep -cF "$want")"
  r2="wrong(n=$n2,err=$ERR)"; [ "$n2" = 1 ] && r2=ok
  check TST4 target "start note on restart_needed/server_binary_stale, exactly one line, start continues" \
        "ok|ok" "$r1|$r2"
fi

if should_run TST5 target; then
  fixture_dir "tst5"
  # Garbage JSON -> no note, no abort.
  run_start HERD_FAKE_STATUS_JSON='no json' -- claude --name t
  r1=wrong; case "$ERR" in *"note: herdr server"*) ;; *) [ "$RC" = 0 ] && r1=ok ;; esac
  # status call fails (default) -> no note, no abort.
  run_start -- claude --name t
  r2=wrong; case "$ERR" in *"note: herdr server"*) ;; *) [ "$RC" = 0 ] && r2=ok ;; esac
  # Server is not running -> no note, although restart_needed is true.
  run_start HERD_FAKE_STATUS_JSON='{"server":{"running":false},"update":{"restart_needed":true}}' -- claude --name t
  r3=wrong; case "$ERR" in *"note: herdr server"*) ;; *) [ "$RC" = 0 ] && r3=ok ;; esac
  check TST5 target "start: status error/no JSON/server off -> no note, no abort" \
        "ok|ok|ok" "$r1|$r2|$r3"
fi

if should_run TST6 target; then
  # Unknown-kind diagnosis names both versions (here with a running server) ...
  fixture_dir "tst6"
  rm -f "$FAKE_HERDR_DIR/kinds"
  run_start HERD_FAKE_STATUS_JSON='{"server":{"running":true,"version":"0.9.1"},"update":{}}' -- muse --name t
  r1=not; case "$ERR" in *"client 0.7.5 (fake), server 0.9.1"*) r1=yes ;; esac
  # Reuse: the label path does NOT query the server again.
  sc="$(cat "$FAKE_HERDR_DIR/.statuscount" 2>/dev/null || echo '?')"
  r3="wrong($sc)"; [ "$sc" = 1 ] && r3=yes
  # ... and "Server ?" when no server version can be determined.
  fixture_dir "tst6b"
  rm -f "$FAKE_HERDR_DIR/kinds"
  run_start -- muse --name t
  r2=not; case "$ERR" in *"client 0.7.5 (fake), server ?"*) r2=yes ;; esac
  check TST6 target "unknown-kind diagnosis names client and server version (or Server ?)" \
        "yes|yes|yes" "$r1|$r2|$r3"
fi

if should_run TST7 target; then
  # Hanging server: `herdr status --json` ignores SIGTERM and sleeps for
  # 30 s. The hard deadline (`timeout -k`, shortened to 1 s here) must still
  # let the start continue within ~3 s — without a note, without an abort.
  fixture_dir "tst7"
  t0="$(date +%s)"
  run_start HERD_HERDR_STATUS_TIMEOUT_SEC=1 HERD_FAKE_STATUS_SLEEP=30 -- claude --name t
  dt=$(( $(date +%s) - t0 ))
  no_hint=ok; case "$ERR" in *"note: herdr server"*) no_hint=wrong ;; esac
  fast="ok"; [ "$dt" -lt 8 ] || fast="slow(${dt}s)"
  [ "$RC" = 0 ] || fast="rc$RC"
  check TST7 target "start: hanging status ignores SIGTERM -> hard deadline, no note, no abort" \
        "ok|ok" "$no_hint|$fast"
fi

if should_run TST8 target; then
  # Control character in the toplevel (here LF): no projects= override,
  # otherwise an invalid TOML basic string would result.
  fixture_dir "tst8"
  d="$WORK/tst8-rep"$'\n'"o"
  mkdir -p "$d"; git init -q "$d"
  run_start -- codex --name t --cwd "$d"
  r=ok; case "$OUT" in *"projects="*) r="wrong($OUT)" ;; esac
  check TST8 target "start codex: control character (LF) in the toplevel -> no trust override" \
        "ok" "$r"
fi

# ------------------------------------------------- TLB: pane labels (start) ---
# Package "pane labels": frame title '<name> · <backend>' + orchestrator label.
if should_run TLB1 target; then
  fixture_dir "tlb1"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
  n="$(side_log | grep -cxF 'pane-rename p:t impl-x · pi' || true)"
  check TLB1 target "successful start pi: exactly one pane label '<name> · <backend>'" \
        "0|1" "$RC|$n"
fi

if should_run TLB2 target; then
  fixture_dir "tlb2"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  printf 'noreg:boom\n' > "$FAKE_HERDR_DIR/start.t"
  HERD_CONFIG="$WORK/no-config" run_herd start pi --name t --model opencode-go/deepseek-v4.1-flash --timeout 1
  n="$(side_log | grep -c 'pane-rename.*·' || true)"
  check TLB2 target "failed start pi: no pane label with '·'" \
        "1|0" "$RC|$n"
fi

if should_run TLB3 target; then
  fixture_dir "tlb3"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  HERD_TEST_PANE=w9:p9 HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
  n="$(side_log | grep -cxF 'pane-rename w9:p9 Orchestrator' || true)"
  check TLB3 target "own pane without a label -> label 'Orchestrator'" \
        "0|1" "$RC|$n"
fi

if should_run TLB4 target; then
  fixture_dir "tlb4"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  printf 'My Pane\n' > "$FAKE_HERDR_DIR/label.w9:p9"
  HERD_TEST_PANE=w9:p9 HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
  n="$(side_log | grep -c 'pane-rename w9:p9' || true)"
  check TLB4 target "own pane with label 'My Pane' -> no rename" \
        "0|0" "$RC|$n"
fi

if should_run TLB5 target; then
  fixture_dir "tlb5"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  : > "$FAKE_HERDR_DIR/.renamefail.p:t"
  HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
  has_success=no; case "$OUT" in *started*) has_success=yes ;; esac
  check TLB5 target "pane rename fails -> start exit 0, success output unchanged" \
        "0|yes" "$RC|$has_success"
fi

if should_run TLB6 target; then
  # pane run (HERD_START_VIA=run): registration is confirmed via pane_id_of,
  # AFTER agent rename. The fake knows the name only after registration
  # (.register-gate) and logs the successful resolution as 'agent-resolve'.
  # The label must come AFTER this resolution.
  fixture_dir "tlb6"
  fixture t idle; fixture_kind t pi
  : > "$FAKE_HERDR_DIR/.register-gate"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  HERD_START_VIA=run HERD_CONFIG="$WORK/no-config" run_herd start pi --name t --model opencode-go/deepseek-v4.1-flash --timeout 1
  log="$(side_log)"
  ln_r="$(printf '%s\n' "$log" | grep -nxF 'agent-resolve t' | head -1 | cut -d: -f1)"
  ln_l="$(printf '%s\n' "$log" | grep -nxF 'pane-rename p:t t · pi' | head -1 | cut -d: -f1)"
  r=ok
  if [ -z "$ln_r" ] || [ -z "$ln_l" ] || [ "$ln_r" -ge "$ln_l" ]; then r="wrong(resolve=${ln_r:-?},label=${ln_l:-?})"; fi
  check TLB6 target "agent label only after the registration confirmation (pane run, pane_id_of)" \
        "0|ok" "$RC|$r"
fi

if should_run TLB7 target; then
  # agent start: the successful agent-start run confirms the registration;
  # the fake logs it as 'agent-start-ok'. The label must come after that.
  fixture_dir "tlb7"
  fixture t idle; fixture_kind t pi
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  HERD_CONFIG="$WORK/no-config" run_herd start pi --name t --model opencode-go/deepseek-v4.1-flash --timeout 1
  log="$(side_log)"
  ln_s="$(printf '%s\n' "$log" | grep -nxF 'agent-start-ok t' | head -1 | cut -d: -f1)"
  ln_l="$(printf '%s\n' "$log" | grep -nxF 'pane-rename p:t t · pi' | head -1 | cut -d: -f1)"
  r=ok
  if [ -z "$ln_s" ] || [ -z "$ln_l" ] || [ "$ln_s" -ge "$ln_l" ]; then r="wrong(start=${ln_s:-?},label=${ln_l:-?})"; fi
  check TLB7 target "agent label only after the registration confirmation (agent start)" \
        "0|ok" "$RC|$r"
fi

if should_run TLB8 target; then
  # L-W1: the own pane is renamed only if the pane-get response is
  # structurally readable AND carries no non-empty label. Raw responses
  # via pane-get-raw.<pane>; expectation per case: rename(1) or none(0).
  fixture_dir "tlb8"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  pane_text t 'user@host:~/x$'
  own="w9:p9"
  tlb8_case() {  # $1 = raw response (may be empty)
    rm -f "$FAKE_HERDR_DIR/.side" "$FAKE_HERDR_DIR/pane-get-raw.$own" "$FAKE_HERDR_DIR/.panegetfail.$own"
    printf '%s' "$1" > "$FAKE_HERDR_DIR/pane-get-raw.$own"
    HERD_TEST_PANE="$own" HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
    side_log | grep -c "pane-rename $own" || true
  }
  r1="$(tlb8_case '{"result": {"pane": {"label": "My Pane"}}}')"   # existing label -> no rename
  r2="$(tlb8_case 'no JSON')"                                      # invalid JSON -> no rename
  r3="$(tlb8_case '')"                                               # empty response -> no rename
  r4="$(tlb8_case '{"result":{"pane":{}}}')"                      # pane without label -> rename
  r6="$(tlb8_case '{"result":{"pane":{"label":"   "}}}')"         # whitespace only = existing label -> no rename
  # pane get fails (exit != 0) -> no rename.
  rm -f "$FAKE_HERDR_DIR/.side" "$FAKE_HERDR_DIR/pane-get-raw.$own"
  : > "$FAKE_HERDR_DIR/.panegetfail.$own"
  HERD_TEST_PANE="$own" HERD_CONFIG="$WORK/no-config" run_herd start pi --name impl-x --model opencode-go/deepseek-v4.1-flash --timeout 1
  r5="$(side_log | grep -c "pane-rename $own" || true)"
  check TLB8 target "own pane: only a structurally confirmed missing label is renamed" \
        "0|0|0|1|0|0" "$r1|$r2|$r3|$r4|$r5|$r6"
fi

if should_run TPL1 target; then
  # Two parallel placements into a tab with 3 of 4 panes: counting and
  # splitting run under the placement lock, so exactly one splits into w1:t1
  # and the other opens a new tab. Without the lock both saw pane_count 3 and
  # both split (incident 2026-10-26: six panes in one tab). Timing-based
  # regression check; TPL2 proves the lock itself.
  if ! command -v flock >/dev/null 2>&1; then
    skip_check TPL1 "flock not available, placement runs unlocked by design"
  else
    fixture_dir "tpl1" "$WORK/tpl1-run"
    printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
    printf '3\n' > "$FAKE_HERDR_DIR/tab.panes"
    printf '0.5\n' > "$FAKE_HERDR_DIR/tablistsleep"
    (
      export XDG_RUNTIME_DIR="$WORK/tpl1-run"
      ( HERD_TEST_WS=w1 HERD_TEST_TAB=w1:t1 run_herd term --name ta; echo "$RC" > "$WORK/tpl1-rc.a" ) &
      ( HERD_TEST_WS=w1 HERD_TEST_TAB=w1:t1 run_herd term --name tb; echo "$RC" > "$WORK/tpl1-rc.b" ) &
      wait
    )
    r="split=$(side_log | grep -cx 'pane-split' || true),tab=$(side_log | grep -cx 'tab-create' || true)"
    check TPL1 target "parallel placements respect --max-per-tab (lock around count + split)" \
          "split=1,tab=1|0,0" "$r|$(cat "$WORK/tpl1-rc.a" 2>/dev/null),$(cat "$WORK/tpl1-rc.b" 2>/dev/null)"
  fi
fi

if should_run TPL2 target; then
  # Deterministic lock proof: an independent `flock -n` on the lock file fails
  # while place_shell_pane runs (success and failure path) and succeeds after
  # create_shell_pane returned; the return code passes through.
  if ! command -v flock >/dev/null 2>&1; then
    skip_check TPL2 "flock not available"
  else
    mkdir -p "$WORK/tpl2-run"
    got="$(XDG_RUNTIME_DIR="$WORK/tpl2-run" run_herd_fn '
      probe() { if flock -n "$(herd_log_root)/placement.lock" true; then echo free; else echo held; fi; }
      place_shell_pane() { probe; return "$1"; }
      a=0; create_shell_pane 0 || a=$?; probe
      b=0; create_shell_pane 7 || b=$?; probe
      echo "rc=$a,$b"
    ' 2>&1 | paste -sd" ")"
    check TPL2 target "placement lock held during place_shell_pane, released afterwards, rc preserved" \
          "held free held free rc=0,7" "$got"
  fi
fi

if should_run TPL3 target; then
  # An explicit --split must not drop the chosen target tab: with --tab of
  # another tab the split targets a pane of that tab instead of --current.
  # Without any pane in that tab: exit 1, no split in the caller's tab.
  fixture_dir "tpl3"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  printf '{"pane_id":"w1:p7","tab_id":"w1:t9","workspace_id":"w1","label":"x"}\n' > "$FAKE_HERDR_DIR/extra-panes.jsonl"
  HERD_TEST_WS=w1 HERD_TEST_TAB=w1:t1 run_herd term --name tc --tab w1:t9 --split down
  a="$RC:$(head -1 "$FAKE_HERDR_DIR/.split-args" 2>/dev/null)"
  rm -f "$FAKE_HERDR_DIR/.side" "$FAKE_HERDR_DIR/.split-args"
  HERD_TEST_WS=w1 HERD_TEST_TAB=w1:t1 run_herd term --name td --tab w1:t8 --split down
  b="$RC:$(side_log | grep -c pane-split || true)"
  check TPL3 target "--tab + --split splits inside the target tab; no pane there -> exit 1 without split" \
        "0:w1:p7 --direction down --cwd $PWD --no-focus|1:0" "$a|$b"
fi

if should_run TPL4 target; then
  # --max-per-tab / HERD_MAX_PER_TAB: a non-integer is a usage error before any
  # pane split (before 2026-10-26 it silently opened a new tab on every start).
  fixture_dir "tpl4"
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  run_herd term --name te --max-per-tab foo
  a="$RC:$(side_log | grep -c pane-split || true)"
  HERD_CONFIG="$WORK/no-config" run_herd start pi --name tf --model opencode-go/deepseek-v4.1-flash --max-per-tab 4x --timeout 1
  b="$RC:$(side_log | grep -c pane-split || true)"
  check TPL4 target "invalid --max-per-tab -> exit 2 before the pane split" "2:0|2:0" "$a|$b"
fi
