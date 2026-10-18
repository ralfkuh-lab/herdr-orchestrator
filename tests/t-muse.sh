if should_run T150 target; then
  fixture_dir "t150"
  echo "codex,muse" > "$FAKE_HERDR_DIR/kinds"
  # T150a: impl default: --workspace <cwd>, --trust-workspace (opt-in HERD_AUTO_TRUST=1;
  # default without it: TSEC5), --approval-mode on-request, no --disable-write
  run_start HERD_AUTO_TRUST=1 -- muse --name t --cwd "$WORK" --role impl
  if has_args "--workspace $WORK" && has_args "--trust-workspace" && ! has_args "--no-foreign-personal-context" && has_args "--approval-mode on-request" && ! has_args "--disable-write"; then r=ok; else r="wrong($OUT)"; fi
  check T150a target "start muse impl: default flags and approval-mode on-request" \
        "ok" "$r"

  # T150b: research: --approval-mode on-request and --disable-write
  run_start -- muse --name t --role research
  if has_args "--approval-mode on-request" && has_args "--disable-write"; then r=ok; else r="wrong($OUT)"; fi
  check T150b target "start muse research: --disable-write" \
        "ok" "$r"

  # T150c: --permission-mode never with impl -> --approval-mode never
  run_start -- muse --name t --permission-mode never --role impl
  if has_args "--approval-mode never" && ! has_args "--disable-write"; then r=ok; else r="wrong($OUT)"; fi
  check T150c target "start muse impl --permission-mode never: --approval-mode never" \
        "ok" "$r"

  # T150d: --permission-mode never with research -> --approval-mode never and still --disable-write
  run_start -- muse --name t --permission-mode never --role research
  if has_args "--approval-mode never" && has_args "--disable-write"; then r=ok; else r="wrong($OUT)"; fi
  check T150d target "start muse research --permission-mode never: --approval-mode never and --disable-write" \
        "ok" "$r"

  # T150e: HERD_IMPL_PERMISSION_MODE=acceptEdits -> NOT in the command, mode stays on-request
  run_start HERD_IMPL_PERMISSION_MODE=acceptEdits -- muse --name t --role impl
  if has_args "--approval-mode on-request" && ! has_args "acceptEdits"; then r=ok; else r="wrong($OUT)"; fi
  check T150e target "start muse impl: HERD_IMPL_PERMISSION_MODE has no effect" \
        "ok" "$r"

  # T150f: --model muse-spark-1.3 --effort low -> --model muse-spark-1.3 and --reasoning-effort low
  run_start -- muse --name t --model muse-spark-1.3 --effort low --role impl
  if has_args "--model muse-spark-1.3" && has_args "--reasoning-effort low"; then r=ok; else r="wrong($OUT)"; fi
  check T150f target "start muse: --model and --effort passed through" \
        "ok" "$r"

  # T150g: --resume -> muse resume --last (with root options after it), --resume abc-123 -> muse resume abc-123
  run_start -- muse --name t --resume --role impl
  r1=wrong
  if has_args "resume --last" && has_args "--workspace"; then r1=ok; fi
  run_start -- muse --name t --resume abc-123 --role impl
  r2=wrong
  if has_args "resume abc-123" && has_args "--workspace"; then r2=ok; fi
  check T150g target "start muse --resume: resume --last / resume ID" \
        "ok|ok" "$r1|$r2"

  # T150h: MODEL_MUSE in config -> --model muse-spark-1.3 without --model CLI
  printf 'MODEL_MUSE=muse-spark-1.3\n' > "$WORK/t150h-config"
  run_start HERD_CONFIG="$WORK/t150h-config" -- muse --name t --role impl
  if has_args "--model muse-spark-1.3"; then r=ok; else r="wrong($OUT)"; fi
  check T150h target "start muse: default model from MODEL_MUSE in config" \
        "ok" "$r"

  # Recursion guard (muse >= 1.0.3): herd.sh persistently disables the
  # orchestrator skill in muse (skills disable) instead of setting a run flag.
  # T150i: skill active -> skills disable called, stderr note, start without flag
  fixture_dir "t150i"; echo "codex,muse" > "$FAKE_HERDR_DIR/kinds"
  run_start HERD_AUTO_TRUST=1 -- muse --name t --cwd "$WORK" --role impl
  calls_i="$(cat "$FAKE_HERDR_DIR/muse-skills-calls" 2>/dev/null || true)"
  note_i=no; case "$ERR" in *"disabling skill 'herdr-orchestrator'"*) note_i=yes ;; esac
  if has_args "--workspace $WORK" && has_args "--trust-workspace" && ! has_args "--no-foreign-personal-context" && has_args "--approval-mode on-request"; then r=ok; else r="wrong($OUT)"; fi
  check T150i target "start muse (skill active): skills disable + start without flag" \
        "0|ok|herdr-orchestrator --scope user|yes" "$RC|$r|$calls_i|$note_i"

  # T150j: skill already off -> no disable call, no note
  fixture_dir "t150j"; echo "codex,muse" > "$FAKE_HERDR_DIR/kinds"
  run_start FAKE_MUSE_ORCH_ACTIVATION=off -- muse --name t --cwd "$WORK" --role impl
  calls_j="$(cat "$FAKE_HERDR_DIR/muse-skills-calls" 2>/dev/null || true)"
  note_j=no; case "$ERR" in *"disabling"*) note_j=yes ;; esac
  if has_args "--workspace $WORK" && ! has_args "--no-foreign-personal-context"; then r=ok; else r="wrong($OUT)"; fi
  check T150j target "start muse (skill already off): no disable, no note" \
        "0|ok||no" "$RC|$r|$calls_j|$note_j"

  # T150k: disable has no effect -> abort exit 1 before pane creation
  fixture_dir "t150k"; echo "codex,muse" > "$FAKE_HERDR_DIR/kinds"
  run_start FAKE_MUSE_DISABLE_FAILS=1 -- muse --name t --cwd "$WORK" --role impl
  abort_k=no; case "$ERR" in *"recursion guard cannot be established"*) abort_k=yes ;; esac
  check T150k target "start muse (disable ineffective): abort exit 1" \
        "1|yes|" "$RC|$abort_k|$OUT"
fi

if should_run T151 target; then
  # T151a: muse fixture (100% left)
  fixture_dir "t151a"
  usage_fixture m muse "$ROOT/tests/fixtures/usage/muse-usage.txt"
  run_herd usage m
  want_151a="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "m" "muse" "5h=100% left" "week=100% left" "reset5h=at 10:23 PM" "resetweek=Sep 7 at 2:00 AM")"
  reads_m="$(cat "$FAKE_HERDR_DIR/.reads.m" 2>/dev/null || true)"
  r_want_m="$(printf 'visible 40\nrecent 200\nrecent 200')"
  check T151a target "usage muse: 5h=100% left, week=100% left, reads recent 200" \
        "$want_151a|$r_want_m" "$OUT|$RC|$reads_m"

  # T151b: synthetic fixture muse-usage-37.txt (Current 37%, Weekly 12%)
  fixture_dir "t151b"
  usage_fixture m muse "$ROOT/tests/fixtures/usage/muse-usage-37.txt"
  run_herd usage m
  want_151b="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "m" "muse" "5h=63% left" "week=88% left" "reset5h=at 9:05 PM" "resetweek=Sep 8 at 2:00 AM")"
  check T151b target "usage muse: Current 37% -> 5h=63% left, Weekly 12% -> week=88% left" \
        "$want_151b" "$OUT|$RC"

  # T151c: .side shows prompt m /usage and no esc
  fixture_dir "t151c"
  usage_fixture m muse "$ROOT/tests/fixtures/usage/muse-usage.txt"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage m
  side="$(side_log)"
  s_prompt=no; case "$side" in *"prompt m /usage"*) s_prompt=yes ;; esac
  s_esc=no; case "$side" in *"pane-keys p:m esc"*) s_esc=yes ;; esac
  check T151c target "usage muse: prompt m /usage and no esc in .side" \
        "0|yes|no" "$RC|$s_prompt|$s_esc"

  # T151d: block without subscription header -> ? fields, exit 1
  fixture_dir "t151d"
  cat << 'EOF' > "$WORK/t151d-fix.txt"
  Muse Code 1.0.2

  Session usage

    Input      0
    Cached     0
    Output     0
    Total      0

    Turns         0
    Subagents  none
EOF
  usage_fixture m muse "$WORK/t151d-fix.txt"
  run_herd usage m
  want_151d="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "m" "muse" "5h=?" "week=?" "reset5h=?" "resetweek=?")"
  check T151d target "usage muse: without subscription header -> ? fields, exit 1" \
        "$want_151d|1" "$OUT|$RC"
fi

if should_run T152 target; then
  fixture_dir "t152"
  fixture x idle
  # T152a: answer x "Quit" -> 1 step down + enter
  pane_text x "$(cat "$ROOT/tests/fixtures/muse/dialog-trust.txt")"
  pane_after x "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "Quit"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  nkey=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ [0-9]+$' || true)
  check T152a target "answer muse trust: 'Quit' -> 1 step down + enter" \
        "0|1|1|0" "$RC|$ndown|$nenter|$nkey"

  # T152b: answer x "Trust and continue" -> 0 steps + enter
  pane_text x "$(cat "$ROOT/tests/fixtures/muse/dialog-trust.txt")"
  pane_after x "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "Trust and continue"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  nkey=$(printf '%s\n' "$side" | grep -cE 'pane-keys [^[:space:]]+ [0-9]+$' || true)
  check T152b target "answer muse trust: 'Trust and continue' -> 0 steps + enter" \
        "0|0|1|0" "$RC|$ndown|$nenter|$nkey"

  # T152c: prose "  10  files changed" alone -> NOOPTS
  pane_text x "  10  files changed"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "files changed"
  no_dialog=no
  case "$ERR" in *"no selection dialog"*) no_dialog=yes ;; esac
  keys=no
  case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T152c target "answer: isolated prose '10  files changed' -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$no_dialog|$keys"
fi

if should_run T153 target; then
  fixture_dir "t153"
  fixture a idle

  # T153a: working text with --kind muse -> busy
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/working.txt")"
  run_herd classify-pane p:a --kind muse
  check T153a target "classify-pane muse: working text with --kind muse -> busy" \
        "busy|0" "$OUT|$RC"

  # T153b: the same text with --kind codex -> clean
  run_herd classify-pane p:a --kind codex
  check T153b target "classify-pane muse: working text with --kind codex -> clean" \
        "clean|0" "$OUT|$RC"

  # T153c: approval dialog (also contains esc to interrupt) with --kind muse -> blocked
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/dialog-approval.txt")"
  run_herd classify-pane p:a --kind muse
  check T153c target "classify-pane muse: approval dialog with --kind muse -> blocked" \
        "blocked|0" "$OUT|$RC"

  # T153d: trust dialog -> blocked
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/dialog-trust.txt")"
  run_herd classify-pane p:a --kind muse
  check T153d target "classify-pane muse: trust dialog -> blocked" \
        "blocked|0" "$OUT|$RC"
fi

if should_run T154 target; then
  # T154a: start muse without kinds file -> exit 2, message contains "does not know the backend kind 'muse'" and 'Preview'
  fixture_dir "t154a"
  rm -f "$FAKE_HERDR_DIR/kinds"
  run_start -- muse --name t --role impl
  has_kind_err=no; case "$ERR" in *"does not know the backend kind 'muse'"*) has_kind_err=yes ;; esac
  has_prev_hint=no; case "$ERR" in *"preview"*) has_prev_hint=yes ;; esac
  check T154a target "start muse without kinds file -> exit 2, error message and preview hint" \
        "2|yes|yes" "$RC|$has_kind_err|$has_prev_hint"

  # T154b: start muse with kinds = codex,muse -> runs through (HERD_PRINT_CLI output starts with muse)
  fixture_dir "t154b"
  echo "codex,muse" > "$FAKE_HERDR_DIR/kinds"
  run_start -- muse --name t --role impl
  first_word="$(echo "$OUT" | head -1)"
  check T154b target "start muse with kinds=codex,muse -> runs through, output starts with muse" \
        "0|muse" "$RC|$first_word"

  # T154c: kinds = file with an empty line (do not simulate a possible-values line) -> fail-open, start claude runs through
  fixture_dir "t154c"
  printf '\n' > "$FAKE_HERDR_DIR/kinds"
  run_start -- claude --name t --role impl
  first_word="$(echo "$OUT" | head -1)"
  check T154c target "start claude with kinds=empty line -> fail-open, runs through" \
        "0|claude" "$RC|$first_word"
fi

if should_run T155 target; then
  # T155a: '  1  first row' / '  2  second row' without marker -> NOOPTS, no keys
  fixture_dir "t155"
  fixture x idle
  pane_text x "  1  first row"$'\n'"  2  second row"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "second row"
  no_dialog=no; case "$ERR" in *"no selection dialog"*) no_dialog=yes ;; esac
  keys=no; case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T155a target "answer: '  1  first row' / '  2  second row' without marker -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$no_dialog|$keys"

  # T155b: '1  2  3' / '2  4  5' -> NOOPTS
  pane_text x "1  2  3"$'\n'"2  4  5"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "2"
  no_dialog=no; case "$ERR" in *"no selection dialog"*) no_dialog=yes ;; esac
  keys=no; case "$(side_log)" in *"pane-keys"*) keys=yes ;; esac
  check T155b target "answer: '1  2  3' / '2  4  5' without marker -> NOOPTS, no keys" \
        "yes|yes|no" "$([ "$RC" != 0 ] && echo yes || echo no)|$no_dialog|$keys"

  # T155c: muse trust fixture (with '> 1') -> still Quit = 1 step down + enter
  pane_text x "$(cat "$ROOT/tests/fixtures/muse/dialog-trust.txt")"
  pane_after x "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "Quit"
  side="$(side_log)"
  ndown=$(printf '%s\n' "$side" | grep -cE ' down$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T155c target "answer: muse trust fixture with marker -> Quit = 1 step down + enter" \
        "0|1|1" "$RC|$ndown|$nenter"

  # T155d: the same two lines as T155a, but the second with '› 2  second row' -> 1 step up + enter
  pane_text x "  1  first row"$'\n'"› 2  second row"
  pane_after x "ok"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_ANSWER_VERIFY_SEC=0 run_herd answer x "first row"
  side="$(side_log)"
  nup=$(printf '%s\n' "$side" | grep -cE ' up$' || true)
  nenter=$(printf '%s\n' "$side" | grep -cE ' enter$' || true)
  check T155d target "answer: '  1  first row' / '› 2  second row' -> 1 step up + enter" \
        "0|1|1" "$RC|$nup|$nenter"

  # T155e: kinds = 'codex, claude,\nmuse, grok' (line break before muse) -> start muse runs through
  fixture_dir "t155e"
  printf 'codex, claude,\nmuse, grok\n' > "$FAKE_HERDR_DIR/kinds"
  run_start -- muse --name t --role impl
  first_word="$(echo "$OUT" | head -1)"
  check T155e target "start muse with wrapped kinds file -> runs through" \
        "0|muse" "$RC|$first_word"

  # T155f: kinds = 'codex,musex' -> start muse exit 2 (whole word)
  fixture_dir "t155f"
  echo "codex,musex" > "$FAKE_HERDR_DIR/kinds"
  run_start -- muse --name t --role impl
  has_kind_err=no; case "$ERR" in *"does not know the backend kind 'muse'"*) has_kind_err=yes ;; esac
  check T155f target "start muse with kinds=codex,musex -> exit 2 (whole word)" \
        "2|yes" "$RC|$has_kind_err"

  # T155g: synthetic narrow fixture muse-usage-narrow.txt -> reset5h=at 10:23 PM, resetweek=Sep 7 at 2:00 AM
  fixture_dir "t155g"
  usage_fixture m muse "$ROOT/tests/fixtures/usage/muse-usage-narrow.txt"
  run_herd usage m
  want_155g="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "m" "muse" "5h=100% left" "week=100% left" "reset5h=at 10:23 PM" "resetweek=Sep 7 at 2:00 AM")"
  check T155g target "usage muse: wrapped lines in a narrow pane captured correctly" \
        "$want_155g" "$OUT|$RC"

  # T155h: start muse2 --name t -> exit 2, message contains 'unknown backend', NOT 'does not know the backend kind'
  fixture_dir "t155h"
  run_start -- muse2 --name t
  has_unk=no; case "$ERR" in *"unknown backend: muse2"*) has_unk=yes ;; esac
  has_kind_err=no; case "$ERR" in *"does not know the backend kind"*) has_kind_err=yes ;; esac
  check T155h target "start muse2: exit 2, 'unknown backend' instead of 'does not know the backend kind'" \
        "2|yes|no" "$RC|$has_unk|$has_kind_err"

  # T155i: check_dlg for muse with footer 'Tab for an optional note · Esc to interrupt' -> blocked
  fixture_dir "t155i"
  fixture a idle
  check_dlg T155i "muse question: tab for an optional note beats busy (Esc to interrupt)" "$(cat <<'EOF'
Which option do you prefer?

› 1. Option A
  2. Option B

Enter to select · ↑/↓ to move · Tab for an optional note · Esc to interrupt
EOF
)" blocked blocked muse

  # T155j: usage --probe codex,muse on a fake without muse -> codex queried, exit 0, stderr contains uebersprungen, no start usage-muse
  fixture_dir "t155j"
  rm -f "$FAKE_HERDR_DIR/kinds"
  # start_read 6 (round 5: prompt read + baseline read), see T147.
  usage_fixture usage-codex codex "$ROOT/tests/fixtures/usage/codex-status-wide.txt" 6
  echo -n "p:usage-codex" > "$FAKE_HERDR_DIR/split.pane"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe codex,muse
  side="$(side_log)"
  has_codex_out=no; case "$OUT" in *"usage-codex"*"codex"*"5h=56% left"*) has_codex_out=yes ;; esac
  has_skip_err=no; case "$ERR" in *"skipped"*) has_skip_err=yes ;; esac
  s_start_muse=no; case "$side" in *"start usage-muse"*|*"usage-muse"*) s_start_muse=yes ;; esac
  check T155j target "usage --probe: fake without muse in kinds -> codex queried, muse skipped, exit 0" \
        "0|yes|yes|no" "$RC|$has_codex_out|$has_skip_err|$s_start_muse"

  # T155k: exec muse --cwd $WORK --model muse-spark-1.3 --effort low 'hallo welt' with HERD_PRINT_CLI
  fixture_dir "t155k"
  run_exec HERD_AUTO_TRUST=1 -- muse --cwd "$WORK" --model muse-spark-1.3 --effort low "hallo welt"
  want_155k="$(printf 'muse\nexec\n--workspace\n%s\n--trust-workspace\n--approval-mode\nnever\n--user-input-auto-resolve\n--model\nmuse-spark-1.3\n--reasoning-effort\nlow\nhallo welt' "$WORK")"
  if has_args "muse exec --workspace $WORK --trust-workspace --approval-mode never --user-input-auto-resolve --model muse-spark-1.3 --reasoning-effort low" && [ "$OUT" = "$want_155k" ]; then r_155k=ok; else r_155k="wrong($OUT)"; fi
  check T155k target "exec muse: argument sequence with HERD_PRINT_CLI" \
        "0|ok" "$RC|$r_155k"

  # T155k2: exec muse with active skill -> skills disable called (guard also applies to exec)
  calls_k2="$(cat "$FAKE_HERDR_DIR/muse-skills-calls" 2>/dev/null || true)"
  check T155k2 target "exec muse: recursion guard via skills disable" \
        "herdr-orchestrator --scope user" "$calls_k2"

  # T155l: exec codex --cwd $WORK 'x' starts with codex exec -s workspace-write -C $WORK
  run_exec codex --cwd "$WORK" "x"
  if has_args "codex exec -s workspace-write -C $WORK"; then r_155l=ok; else r_155l="wrong($OUT)"; fi
  check T155l target "exec codex: starts with codex exec -s workspace-write -C \$WORK" \
        "0|ok" "$RC|$r_155l"

  # T155m/n (codex re-review 2026-09-03): an empty reset value must NOT swallow the
  # next field -> ? field and exit 1 instead of "reset5h=Weekly 12% used ...".
  fixture_dir "t155m"
  cat << 'EOF' > "$WORK/t155m-fix.txt"
  Subscription · Muse Code Everyday Usage
    Current       37% used · Resets
    Weekly        12% used · Resets Sep 8 at 2:00 AM
    as of 5:28 PM
EOF
  usage_fixture m muse "$WORK/t155m-fix.txt"
  run_herd usage m
  r5="$(printf '%s' "$OUT" | cut -f5)"
  check T155m target "usage muse: empty Current reset -> reset5h=?, exit 1" \
        "reset5h=?|1" "$r5|$RC"

  fixture_dir "t155n"
  cat << 'EOF' > "$WORK/t155n-fix.txt"
  Subscription · Muse Code Everyday Usage
    Current       37% used · Resets at 9:05 PM
    Weekly        12% used · Resets
    as of 5:28 PM
EOF
  usage_fixture m muse "$WORK/t155n-fix.txt"
  run_herd usage m
  rw="$(printf '%s' "$OUT" | cut -f6)"
  check T155n target "usage muse: empty Weekly reset -> resetweek=?, exit 1" \
        "resetweek=?|1" "$rw|$RC"
fi


# ------------------------------------------ muse states: busy 25, failed --
# Spec: busy window muse 25 lines (task list under Thinking); new event `failed`
# analogous to `limited` (cross-check after idle, report immediately, not
# terminal for watch, wait hits, re-entry again).

if should_run T159 target; then
  fixture_dir "t159"
  fixture a idle

  # T159a: real thinking+task list with --kind muse -> busy (before: clean)
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/busy-thinking-tasklist.txt")"
  run_herd classify-pane p:a --kind muse
  check T159a target "classify-pane: muse thinking+task list --kind muse -> busy" \
        "busy|0" "$OUT|$RC"

  # T159b: the same fixture with --kind agy -> clean (window only for muse)
  run_herd classify-pane p:a --kind agy
  check T159b target "classify-pane: muse thinking+task list --kind agy -> clean" \
        "clean|0" "$OUT|$RC"

  # T159a2: production path without --kind (pre-match 25 lines + kind RPC)
  fixture_kind a muse
  rm -f "$FAKE_HERDR_DIR/.count.a"
  run_herd classify-pane p:a
  moved=no
  [ -f "$FAKE_HERDR_DIR/.count.a" ] && moved=yes
  check T159a2 target "classify-pane: muse thinking fixture without --kind -> busy (pre-match+RPC)" \
        "busy|0|yes" "$OUT|$RC|$moved"

  # T159c: model-failed.txt -> failed (kind-independent)
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  run_herd classify-pane p:a
  check T159c target "classify-pane: model-failed.txt -> failed" \
        "failed|0" "$OUT|$RC"

  # T159d: tool echo "◆ Ran command · model failed test" is NOT failed
  pane_text a "$(printf '%s\n' '◆ Ran command · model failed test' '⟩ prompt')"
  run_herd classify-pane p:a
  check T159d target "classify-pane: tool echo 'Ran command · model failed test' -> clean" \
        "clean|0" "$OUT|$RC"

  # T159d2: a marker-less line "model failed:" is NOT failed (marker required)
  pane_text a "$(printf '%s\n' 'model failed: model stream idle timeout after 180000ms' '⟩ prompt')"
  run_herd classify-pane p:a
  check T159d2 target "classify-pane: marker-less 'model failed:' -> clean" \
        "clean|0" "$OUT|$RC"

  # T159d3: codex "Selected model is at capacity" with the ■ marker -> failed
  # (2026-10-12: watch reported idle although the prompt was not processed).
  pane_text a "$(printf '%s\n' '■ Selected model is at capacity. Please try a different model.' '› implement the fix')"
  run_herd classify-pane p:a --kind codex
  check T159d3 target "classify-pane: codex 'Selected model is at capacity' -> failed" \
        "failed|0" "$OUT|$RC"

  # T159d4: the same line without the ■ marker is NOT failed (marker required)
  pane_text a "$(printf '%s\n' 'Selected model is at capacity. Please try a different model.' '› implement the fix')"
  run_herd classify-pane p:a --kind codex
  check T159d4 target "classify-pane: marker-less 'Selected model is at capacity' -> clean" \
        "clean|0" "$OUT|$RC"

  # T159d5: the ■ line inside an open ```-code block (with following text) is
  # tool/code output, not a backend error -> clean
  pane_text a "$(printf '%s\n' '```' 'Output:' '■ Selected model is at capacity. Please try a different model.' '```' '› implement the fix')"
  run_herd classify-pane p:a --kind codex
  check T159d5 target "classify-pane: ■ capacity line inside a code block -> clean" \
        "clean|0" "$OUT|$RC"

  # T159d6: an indented ■ line is tool output, not the codex error line
  # (codex writes it in column 0) -> clean
  pane_text a "$(printf '%s\n' '  ■ Selected model is at capacity. Please try a different model.' '› implement the fix')"
  run_herd classify-pane p:a --kind codex
  check T159d6 target "classify-pane: indented ■ capacity line -> clean" \
        "clean|0" "$OUT|$RC"

  # T159e: send guard: model failed is no dialog — send may send
  fixture a idle
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  run_herd send a "/clear"
  blocked=no; case "$ERR" in *"open selection"*|*"approval dialog"*) blocked=yes ;; esac
  check T159e target "send: model-failed is no dialog, send sends (no guard)" \
        "0|no" "$RC|$blocked"
fi

if should_run T159f target; then
  # Event watch: agent reports idle, pane shows model-failed -> a failed, exit 0
  fixture_dir "t159f"
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  ev_start "$WORK/t159f-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
hold
EOF
  run_watch a --stall-timeout 0 --max-events 1
  ev_stop
  expl=no; case "$ERR" in *"backend/model error"*) expl=yes ;; esac
  check T159f target "watch events: idle + model-failed -> 'a failed', explanation from herd.sh" \
        "a failed|0|yes" "$OUT|$RC|$expl"
fi

if should_run T159g target; then
  # wait (settled): idle + model-failed -> stdout failed, Exit 0, explain
  fixture_dir "t159g"
  fixture a working
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  ev_start "$WORK/t159g-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --timeout 1 --stall-timeout 0
  ev_stop
  expl=no; case "$ERR" in *"backend/model error"*) expl=yes ;; esac
  check T159g target "wait events: idle + model-failed -> failed, explanation" \
        "failed|0|yes" "$OUT|$RC|$expl"
fi

if should_run T159h target; then
  # Re-entry: failed -> working (all-clear) -> failed again
  fixture_dir "t159h"
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  ev_start "$WORK/t159h-ev" <<EOF
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_WORKING
emit $EV_A_IDLE
sleep 0.5
emit $EV_A_WORKING
sleep 0.2
emit $EV_A_IDLE
hold
EOF
  run_watch a --stall-timeout 0 --max-events 3
  ev_stop
  got="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T159h target "watch events: second failed after working is reported again" \
        "a failed;a working;a failed|0" "$got|$RC"
fi

if should_run T159k target; then
  # Raw mode analogous to T135c: --status failed waits for the raw herdr status
  # "failed" (which does not exist). idle + model-failed stays silent —
  # heuristic bypassed, no classify. Settled wait hits (T159g).
  fixture_dir "t159k"
  fixture a working
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  ev_start "$WORK/t159k-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
  run_dispatch_wait events "tcp:127.0.0.1:$EV_PORT" a --status failed --timeout 1 --stall-timeout 0
  ev_stop
  nread="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T159k target "wait --status failed events: idle+model-failed silent (no classify), timeout 124" \
        "|124|0" "$OUT|$RC|$nread"
fi

if should_run T159l target; then
  fixture_dir "t159l"
  pane_text a "$(cat "$ROOT/tests/fixtures/muse/model-failed.txt")"
  run_herd stall-fingerprint p:a
  lim="$(printf '%s' "$OUT" | sed -n 2p)"
  failflag="$(printf '%s' "$OUT" | sed -n 3p)"
  n="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T159l target "stall-fingerprint: model-failed -> failed yes, limited no, one read" \
        "limited no|failed yes|1|0" "$lim|$failflag|$n|$RC"
fi


# ---------------------- muse 1.3.0: wrong `blocked` (Reviewing approval) -----
# Spec .herd/spec-muse13-blocked.md, stage 1. muse checks shell commands before
# execution with a built-in reviewer: the pane shows
# "Reviewing approval request (… · esc to interrupt)" WITHOUT a dialog, but herdr
# reports raw `blocked`. Only for kind muse is this corrected via pane cross-check
# (classify_text); other kinds stay unchanged (S6).

if should_run T178 target; then
  fixture_dir "t178"
  M="$ROOT/tests/fixtures/muse"

  # S1: muse + reviewing approval (no dialog, muse busy line) -> working
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$M/reviewing-approval.txt")"
  run_herd status a
  check T178a target "S1 muse + reviewing-approval -> working" \
        "working|0" "$OUT|$RC"

  # S2: muse + thinking after the review -> working
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$M/thinking-after-review.txt")"
  run_herd status a
  check T178b target "S2 muse + thinking-after-review -> working" \
        "working|0" "$OUT|$RC"

  # S3: muse + real approval dialog (despite busy line) -> blocked
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$M/dialog-approval.txt")"
  run_herd status a
  check T178c target "S3 muse + dialog-approval -> blocked" \
        "blocked|0" "$OUT|$RC"

  # S4: muse + trust dialog -> blocked
  fixture a blocked; fixture_kind a muse
  pane_text a "$(cat "$M/dialog-trust.txt")"
  run_herd status a
  check T178d target "S4 muse + dialog-trust -> blocked" \
        "blocked|0" "$OUT|$RC"

  # S5: muse + calm pane (no dialog, not busy) -> blocked (herdr keeps the
  # authority; do not hide unknown dialog formats)
  fixture a blocked; fixture_kind a muse
  pane_text a "⟩ What should I do?"$'\n'"  muse-spark-1.3  ·  /t/c/scratchpad"
  run_herd status a
  check T178e target "S5 muse + calm pane -> blocked" \
        "blocked|0" "$OUT|$RC"

  # S6: other kind (claude) -> blocked immediately, NO pane read
  fixture a blocked; fixture_kind a claude
  pane_text a "$(cat "$M/reviewing-approval.txt")"
  run_herd status a
  nread="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T178f target "S6 claude + reviewing-approval -> blocked without extra read" \
        "blocked|0|0" "$OUT|$RC|$nread"

  # S7: kind empty (no kind file) + reviewing-approval -> text_looks_any_busy
  # hits, agent_kind_of is looked up — but without a kind file the fake does not
  # return an "agent" field (empty kind), classify_text falls back to clean and
  # the raw status blocked remains. Exactly this behavior is pinned down here
  # (with a real kind muse it would be working, see S1).
  fixture a blocked; rm -f "$FAKE_HERDR_DIR/kind.a"
  pane_text a "$(cat "$M/reviewing-approval.txt")"
  run_herd status a
  nread="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T178g target "S7 kind empty + reviewing-approval -> blocked (1 read, fake without kind)" \
        "blocked|0|1" "$OUT|$RC|$nread"

  # K1/K4/K6: empty-kind branch in normalize_status. The status path already
  # delivers the kind with the first agent_status_probe — the branch
  # `[ -z "$kind" ]` would never be reached via the fake. Therefore DIRECTLY:
  # normalize_status without kind, agent_kind_of controlled. Important (K6): the
  # agy part uses a REAL agy busy pattern (`esc to cancel`), only the muse part
  # `esc to interrupt` — otherwise `classify_text agy` returns `clean` anyway and
  # the guard `[ "$ukind" = muse ]` would not be provable. agy -> blocked,
  # muse -> working, calm pane -> blocked, lookup only on a busy pre-match.
  # `events_py=yes` is the K7 self-test (SCRIPT_DIR/EVENTS_PY correct).
  lookup_file="$WORK/t178h-lookups"; : > "$lookup_file"
  export T178H_LOOKUP="$lookup_file"
  got="$(run_herd_fn "$(cat <<'EOS'
pane_visible() { printf '%s\n' "$PANE_TEXT"; }
agent_kind_of() { printf '%s\n' "$1" >> "$T178H_LOOKUP"; printf '%s' "$STUB_KIND"; }
printf 'events_py=%s\n' "$([ -f "$EVENTS_PY" ] && echo yes || echo no)"
PANE_TEXT="  esc to cancel"; STUB_KIND=agy
printf 'agy=%s\n' "$(normalize_status blocked p:a "")"
PANE_TEXT="  esc to interrupt"; STUB_KIND=muse
printf 'muse=%s\n' "$(normalize_status blocked p:a "")"
PANE_TEXT="⟩ quiet prompt"
printf 'calm=%s\n' "$(normalize_status blocked p:a "")"
EOS
)")"
  unset T178H_LOOKUP
  nlookups="$(grep -c . "$lookup_file" 2>/dev/null || echo 0)"
  flat="$(printf '%s' "$got" | tr '\n' '|')"
  check T178h target "K1/K4/K6 normalize_status empty-kind branch: agy->blocked, muse->working, lookup only on busy" \
        "events_py=yes|agy=blocked|muse=working|calm=blocked|2" "$flat|$nlookups"
fi
