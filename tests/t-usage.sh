# ---------------------------------------------------------------- usage -------

if should_run T145 target; then
  # T145a: codex fixture
  fixture_dir "t145a"
  usage_fixture c codex "$ROOT/tests/fixtures/usage/codex-status-wide.txt"
  run_herd usage c
  want_c_wide="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=56% left" "week=86% left" "reset5h=21:50" "resetweek=23:09 on 7 Sep")"
  check T145a target "usage codex: 5h=56% left, week=86% left" "$want_c_wide" "$OUT|$RC"

  # T145a2: codex >= 0.153.4 shows a bar before the percentage (2026-09-06)
  fixture_dir "t145a2"
  usage_fixture c codex "$ROOT/tests/fixtures/usage/codex-status-bar.txt"
  run_herd usage c
  want_c_bar="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=100% left" "week=66% left" "reset5h=19:00" "resetweek=23:09 on 7 Sep")"
  check T145a2 target "usage codex with bar: 5h=100% left, week=66% left" "$want_c_bar" "$OUT|$RC"

  # T145a3: codex >= 0.156.0 no longer has a 5h window, but Luna Reserve instead (2026-09-23)
  fixture_dir "t145a3"
  usage_fixture c codex "$ROOT/tests/fixtures/usage/codex-status-luna-reserve.txt"
  run_herd usage c
  want_c_luna="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=–" "week=0% left" "reset5h=–" "resetweek=10:36")"
  check T145a3 target "usage codex without 5h window (Luna Reserve): 5h=–, week=0% left" "$want_c_luna" "$OUT|$RC"

  # T145b: agy fixture
  fixture_dir "t145b"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-page1.txt"
  run_herd usage a
  want_a="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=83% left" "week=95% left" "reset5h=1h 1" "resetweek=116h")"
  check T145b target "usage agy: 5h=83% left, week=95% left" "$want_a" "$OUT|$RC"

  # T145b2: agy view with the Argon section (2026-10-17): 53 lines without a scroll
  # footer, i.e. taller than pane_visible's 40 lines -> agy reads the whole screen
  fixture_dir "t145b2"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-argon.txt"
  run_herd usage a
  # (the dialog guard before sending keeps reading visible 40)
  reads_a=no; grep -qx 'visible ?' "$FAKE_HERDR_DIR/.reads.a" 2>/dev/null && reads_a=yes
  want_argon="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s|0|yes' "a" "agy" "5h=100% left" "week=100% left" "reset5h=?" "resetweek=?" "argon_5h=–" "argon_week=98% left" "argon_reset5h=–" "argon_resetweek=167h 52m" "claude_5h=100% left" "claude_week=100% left" "claude_reset5h=?" "claude_resetweek=?")"
  check T145b2 target "usage agy with Argon section: whole screen, argon_week=98% left" "$want_argon" "$OUT|$RC|$reads_a"

  # T145c: claude fixture
  fixture_dir "t145c"
  usage_fixture cl claude "$ROOT/tests/fixtures/usage/claude-usage.txt"
  run_herd usage cl
  want_cl="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "cl" "claude" "5h=48% left" "week=86% left" "reset5h=8:29pm (Europe/Berlin)" "resetweek=Sep 4, 9:59am (Europe/Berlin)")"
  check T145c target "usage claude: 5h=48% left, week=86% left" "$want_cl" "$OUT|$RC"

  # T145d: grok fixture
  fixture_dir "t145d"
  usage_fixture g grok "$ROOT/tests/fixtures/usage/grok-usage.txt"
  run_herd usage g
  want_g="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "g" "grok" "5h=–" "week=20% left (bar 24/30)" "reset5h=–" "resetweek=September 2, 22:20")"
  check T145d target "usage grok: week=20% left (bar 24/30)" "$want_g" "$OUT|$RC"
fi

if should_run T146 target; then
  # T146a: codex gets /status, the others /usage; grok/agy/claude then get esc (.side)
  fixture_dir "t146a"
  usage_fixture codex codex "$ROOT/tests/fixtures/usage/codex-status.txt"
  usage_fixture grok grok "$ROOT/tests/fixtures/usage/grok-usage.txt"
  usage_fixture agy agy "$ROOT/tests/fixtures/usage/agy-usage-page1.txt"
  usage_fixture claude claude "$ROOT/tests/fixtures/usage/claude-usage.txt"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage codex grok agy claude
  side="$(side_log)"
  s_codex=no; case "$side" in *"prompt codex /status"*) s_codex=yes ;; esac
  s_grok=no; case "$side" in *"prompt grok /usage"*) s_grok=yes ;; esac
  s_agy=no; case "$side" in *"prompt agy /usage"*) s_agy=yes ;; esac
  s_claude=no; case "$side" in *"prompt claude /usage"*) s_claude=yes ;; esac
  esc_codex=no; case "$side" in *"pane-keys p:codex esc"*) esc_codex=yes ;; esac
  esc_grok=no; case "$side" in *"pane-keys p:grok esc"*) esc_grok=yes ;; esac
  esc_agy=no; case "$side" in *"pane-keys p:agy esc"*) esc_agy=yes ;; esac
  esc_claude=no; case "$side" in *"pane-keys p:claude esc"*) esc_claude=yes ;; esac

  # Check the order: prompt before esc for grok, agy, claude
  idx_p_grok="$(grep -n "prompt grok /usage" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  idx_k_grok="$(grep -n "pane-keys p:grok esc" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  ord_grok=no; [ -n "$idx_p_grok" ] && [ -n "$idx_k_grok" ] && [ "$idx_p_grok" -lt "$idx_k_grok" ] && ord_grok=yes

  idx_p_agy="$(grep -n "prompt agy /usage" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  idx_k_agy="$(grep -n "pane-keys p:agy esc" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  ord_agy=no; [ -n "$idx_p_agy" ] && [ -n "$idx_k_agy" ] && [ "$idx_p_agy" -lt "$idx_k_agy" ] && ord_agy=yes

  idx_p_claude="$(grep -n "prompt claude /usage" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  idx_k_claude="$(grep -n "pane-keys p:claude esc" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  ord_claude=no; [ -n "$idx_p_claude" ] && [ -n "$idx_k_claude" ] && [ "$idx_p_claude" -lt "$idx_k_claude" ] && ord_claude=yes

  check T146a target "slash commands (/status vs /usage) and esc for grok/agy/claude" \
        "0|yes|yes|yes|yes|no|yes|yes|yes|yes|yes|yes" \
        "$RC|$s_codex|$s_grok|$s_agy|$s_claude|$esc_codex|$esc_grok|$esc_agy|$esc_claude|$ord_grok|$ord_agy|$ord_claude"

  # T146b: unknown format -> ? fields, exit 1, --raw hint
  fixture_dir "t146b"
  usage_fixture a codex "$ROOT/tests/fixtures/usage/codex-usage-heatmap.txt"
  run_herd usage a
  want_b="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "a" "codex" "5h=?" "week=?" "reset5h=?" "resetweek=?")"
  has_raw_hint=no
  case "$ERR" in *"--raw"*) has_raw_hint=yes ;; esac
  check T146b target "unknown format -> ? fields, exit 1, --raw hint" \
        "$want_b|1|yes" "$OUT|$RC|$has_raw_hint"

  # T146c: open dialog -> exit 1, NO slash command sent
  fixture_dir "t146c"
  fixture a idle; fixture_kind a codex
  pane_text a "Do you want to proceed?"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  side="$(side_log)"
  has_dlg_err=no
  case "$ERR" in *"open selection/approval dialog"*) has_dlg_err=yes ;; esac
  check T146c target "open dialog -> exit 1, no slash command sent" \
        "1||yes" "$RC|$side|$has_dlg_err"

  # T146d: --raw prints the block unchanged
  fixture_dir "t146d"
  usage_fixture a codex "$ROOT/tests/fixtures/usage/codex-status.txt"
  fix_content="$(cat "$ROOT/tests/fixtures/usage/codex-status.txt")"
  run_herd usage --raw a
  check T146d target "--raw prints the block unchanged" \
        "$fix_content|0" "$OUT|$RC"

  # T146e: wrapped codex lines are parsed correctly
  fixture_dir "t146e"
  usage_fixture c codex "$ROOT/tests/fixtures/usage/codex-status.txt"
  run_herd usage c
  want_c_narrow="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=56% left" "week=86% left" "reset5h=21:50" "resetweek=23:09 on 7 Sep")"
  check T146e target "wrapped codex lines (narrow pane fixture) parsed correctly" \
        "$want_c_narrow" "$OUT|$RC"

  # T146f: unknown agent -> exit 1
  fixture_dir "t146f"
  run_herd usage not_there
  check T146f target "unknown agent -> exit 1" \
        "1" "$RC"

  # T146g: usage without arguments -> exit 2
  fixture_dir "t146g"
  run_herd usage
  check T146g target "usage without arguments -> exit 2" \
        "2" "$RC"

  # T146h: usage --raw without a name -> exit 2
  fixture_dir "t146h"
  run_herd usage --raw
  check T146h target "usage --raw without a name -> exit 2" \
        "2" "$RC"

  # T146i: usage unknown option -> exit 2
  fixture_dir "t146i"
  run_herd usage --foobar
  check T146i target "usage unknown option -> exit 2" \
        "2" "$RC"
fi

if should_run T147 target; then
  # T147: --probe starts a throwaway session per backend, queries it and stops it
  fixture_dir "t147"
  # start_read 6 instead of 5: since round 5 `start` reads the pane TWICE upfront
  # (remember the prompt line + echo baseline) — the new block must come one read
  # later, otherwise the usage baseline already sees the new content.
  usage_fixture usage-codex codex "$ROOT/tests/fixtures/usage/codex-status.txt" 6
  echo -n "p:usage-codex" > "$FAKE_HERDR_DIR/split.pane"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe codex
  side="$(side_log)"
  s_prompt=no; case "$side" in *"prompt usage-codex /status"*) s_prompt=yes ;; esac
  s_close=no; case "$side" in *"close p:usage-codex"*) s_close=yes ;; esac
  check T147 target "--probe starts, queries and stops a throwaway session" \
        "0|yes|yes" "$RC|$s_prompt|$s_close"
fi

if should_run T148 target; then
  # T148a: prompt echo with "Weekly limit:" before send, new block only from read 3
  fixture_dir "t148a"
  fixture c idle
  fixture_kind c codex
  echo "Please check Weekly limit:" > "$FAKE_HERDR_DIR/pane.c"
  cat << 'EOF' > "$FAKE_HERDR_DIR/pane-after-3.c"
Please check Weekly limit:
╭─────────────────────────────────────────────────────────────╮
│  5h limit:             56% left (resets 21:50)              │
│  Weekly limit:         86% left (resets 23:09 on 7 Sep)     │
╰─────────────────────────────────────────────────────────────╯
EOF
  run_herd usage c
  want_148a="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=56% left" "week=86% left" "reset5h=21:50" "resetweek=23:09 on 7 Sep")"
  check T148a target "F1: prompt echo with 'Weekly limit:' before send, block only from read 3" \
        "$want_148a" "$OUT|$RC"

  # T148b: two codex blocks in the pane -> the last/lower one wins
  fixture_dir "t148b"
  fixture c idle
  fixture_kind c codex
  cat << 'EOF' > "$FAKE_HERDR_DIR/pane.c"
╭─────────────────────────────────────────────────────────────╮
│  5h limit:             70% left (resets 18:00)              │
│  Weekly limit:         90% left (resets 20:00 on 5 Sep)     │
╰─────────────────────────────────────────────────────────────╯
EOF
  cat << 'EOF' > "$FAKE_HERDR_DIR/pane-after-3.c"
╭─────────────────────────────────────────────────────────────╮
│  5h limit:             70% left (resets 18:00)              │
│  Weekly limit:         90% left (resets 20:00 on 5 Sep)     │
╰─────────────────────────────────────────────────────────────╯

› Ask Codex to do anything

╭─────────────────────────────────────────────────────────────╮
│  5h limit:             56% left (resets 21:50)              │
│  Weekly limit:         86% left (resets 23:09 on 7 Sep)     │
╰─────────────────────────────────────────────────────────────╯
EOF
  run_herd usage c
  want_148b="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=56% left" "week=86% left" "reset5h=21:50" "resetweek=23:09 on 7 Sep")"
  check T148b target "F1: two codex blocks in the pane -> the last/lower one wins" \
        "$want_148b" "$OUT|$RC"

  # T148c: unsupported backend aborts immediately (.side empty, exit 1)
  fixture_dir "t148c"
  fixture o idle
  fixture_kind o opencode
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage o
  side="$(side_log)"
  has_unsupp_err=no
  case "$ERR" in *"backend 'opencode' not supported"*) has_unsupp_err=yes ;; esac
  check T148c target "F3: unsupported backend aborts immediately (.side empty, exit 1)" \
        "1||yes" "$RC|$side|$has_unsupp_err"

  # T148d: --probe with a partial failure -> codex queried, foo failed, cleanup in .side
  fixture_dir "t148d"
  # start_read 6 (round 5: prompt read + baseline read), see T147.
  usage_fixture usage-codex codex "$ROOT/tests/fixtures/usage/codex-status-wide.txt" 6
  echo -n "p:usage-codex" > "$FAKE_HERDR_DIR/split.pane"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe codex,foo
  side="$(side_log)"
  has_codex_out=no
  case "$OUT" in *"usage-codex"*"codex"*"5h=56% left"*) has_codex_out=yes ;; esac
  s_close_codex=no
  case "$side" in *"close p:usage-codex"*) s_close_codex=yes ;; esac
  has_foo_err=no
  case "$ERR" in *"unknown backend: foo"*|*"start for backend 'foo' failed"*) has_foo_err=yes ;; esac
  check T148d target "F5: --probe with partial failure -> codex queried, foo failed, cleanup in .side" \
        "1|yes|yes|yes" "$RC|$has_codex_out|$s_close_codex|$has_foo_err"

  # T148e: start error with registration -> no prompt, but stop/close in .side
  fixture_dir "t148e"
  fixture usage-codex idle
  fixture_kind usage-codex codex
  echo "boom" > "$FAKE_HERDR_DIR/start.usage-codex"
  echo -n "p:other" > "$FAKE_HERDR_DIR/split.pane"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe codex
  side="$(side_log)"
  s_prompt=no; case "$side" in *"prompt"*) s_prompt=yes ;; esac
  s_close=no; case "$side" in *"close p:usage-codex"*) s_close=yes ;; esac
  check T148e target "F5: start error with registration -> no prompt, but stop/close in .side" \
        "1|no|yes" "$RC|$s_prompt|$s_close"

  # T148f: codex without the resets parenthesized part -> reset5h=?, resetweek=?, exit 1
  fixture_dir "t148f"
  cat << 'EOF' > "$WORK/t148f-fix.txt"
╭─────────────────────────────────────────────────────────────╮
│  5h limit:             56% left                             │
│  Weekly limit:         86% left                             │
╰─────────────────────────────────────────────────────────────╯
EOF
  usage_fixture c codex "$WORK/t148f-fix.txt"
  run_herd usage c
  want_148f="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "c" "codex" "5h=56% left" "week=86% left" "reset5h=?" "resetweek=?")"
  check T148f target "F2: codex without the resets parenthesized part -> reset5h=?, resetweek=?, exit 1" \
        "$want_148f|1" "$OUT|$RC"

  # T148g: prompt-fail for grok -> esc called in .side
  fixture_dir "t148g"
  usage_fixture grok grok "$ROOT/tests/fixtures/usage/grok-usage.txt"
  echo "simulated prompt failure" > "$FAKE_HERDR_DIR/prompt-fail.grok"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage grok
  side="$(side_log)"
  has_esc=no; case "$side" in *"pane-keys p:grok esc"*) has_esc=yes ;; esac
  check T148g target "F4: prompt-fail for grok -> esc called in .side" \
        "1|yes" "$RC|$has_esc"

  # T148h: agy with gemini-3.8-flash in the 5h section -> reset fields unaffected
  fixture_dir "t148h"
  cat << 'EOF' > "$WORK/t148h-fix.txt"
GEMINI MODELS
  Weekly Limit Remaining
    95% remaining · Refreshes in 116h
  Five Hour Limit Remaining
    Models: gemini-3.8-flash
    83% remaining · Refreshes in 1h 1
CLAUDE AND GPT MODELS
  esc Close
EOF
  usage_fixture a agy "$WORK/t148h-fix.txt"
  run_herd usage a
  want_148h="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=83% left" "week=95% left" "reset5h=1h 1" "resetweek=116h")"
  check T148h target "F10: agy with gemini-3.8-flash in the group -> reset fields unaffected" \
        "$want_148h" "$OUT|$RC"

  # T148i: agy without the GEMINI MODELS header -> all fields ?, exit 1
  fixture_dir "t148i"
  cat << 'EOF' > "$WORK/t148i-fix.txt"
CLAUDE AND GPT MODELS
  Weekly Limit Remaining
    50% remaining · Refreshes in 40h
  Five Hour Limit Remaining
    60% remaining · Refreshes in 2h
  esc Close
EOF
  usage_fixture a agy "$WORK/t148i-fix.txt"
  run_herd usage a
  want_148i="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "a" "agy" "5h=?" "week=?" "reset5h=?" "resetweek=?")"
  check T148i target "F11: agy without the GEMINI MODELS header -> all fields ?, exit 1" \
        "$want_148i|1" "$OUT|$RC"

  # T148j: grok with Weekly limit (SuperGrok Heavy) -> same values
  fixture_dir "t148j"
  cat << 'EOF' > "$WORK/t148j-fix.txt"
Weekly limit (SuperGrok Heavy)
████████████████████████░░░░░░
Resets: September 2, 22:20
└─────────────────────────────┘
EOF
  usage_fixture g grok "$WORK/t148j-fix.txt"
  run_herd usage g
  want_148j="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "g" "grok" "5h=–" "week=20% left (bar 24/30)" "reset5h=–" "resetweek=September 2, 22:20")"
  check T148j target "F12: grok with Weekly limit (SuperGrok Heavy) -> same values" \
        "$want_148j" "$OUT|$RC"
fi

if should_run T149 target; then
  # T149a: static pane with an old block -> ? fields, exit 1, stderr contains "no new output"
  fixture_dir "t149a"
  fixture c idle; fixture_kind c codex
  cp "$ROOT/tests/fixtures/usage/codex-status.txt" "$FAKE_HERDR_DIR/pane.c"
  run_herd usage c
  want_149a="$(printf '%s\t%s\t5h=?\tweek=?\treset5h=?\tresetweek=?' "c" "codex")"
  has_stale_err=no
  case "$ERR" in *"no new output"*) has_stale_err=yes ;; esac
  check T149a target "G1: static pane with an old block -> ?, exit 1, stderr no new output" \
        "$want_149a|1|yes" "$OUT|$RC|$has_stale_err"

  # T149b: --raw on a static pane stays exit 0 (raw block is printed)
  fixture_dir "t149b"
  fixture c idle; fixture_kind c codex
  fix_content="$(cat "$ROOT/tests/fixtures/usage/codex-status.txt")"
  pane_text c "$fix_content"
  run_herd usage --raw c
  check T149b target "G1/G2: --raw on a static pane stays exit 0" \
        "$fix_content|0" "$OUT|$RC"

  # T149c: baseline read fails -> exit 1, no prompt in .side, stderr not readable
  fixture_dir "t149c"
  fixture c idle; fixture_kind c codex
  echo 2 > "$FAKE_HERDR_DIR/readfail.c"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage c
  side="$(side_log)"
  s_prompt=no; case "$side" in *"prompt"*) s_prompt=yes ;; esac
  has_read_err=no
  case "$ERR" in *"not readable"*) has_read_err=yes ;; esac
  check T149c target "G1: baseline read fails -> exit 1, no prompt, stderr not readable" \
        "1|no|yes" "$RC|$s_prompt|$has_read_err"

  # T149d: footer change without a new block -> ?, exit 1, "no new output"
  fixture_dir "t149d"
  fixture c idle; fixture_kind c codex
  block="$(cat "$ROOT/tests/fixtures/usage/codex-status.txt")"
  pane_text c "$block"$'\n'"Footer A (cursor blink 1)"
  echo "$block"$'\n'"Footer B (cursor blink 2)" > "$FAKE_HERDR_DIR/pane-after-3.c"
  run_herd usage c
  want_149d="$(printf '%s\t%s\t5h=?\tweek=?\treset5h=?\tresetweek=?' "c" "codex")"
  has_stale_err_d=no
  case "$ERR" in *"no new output"*) has_stale_err_d=yes ;; esac
  check T149d target "G1: footer change without a new block -> ?, exit 1, stderr no new output" \
        "$want_149d|1|yes" "$OUT|$RC|$has_stale_err_d"

  # T149e: codex scrollback read (recent 200) detects freshness even for text-identical blocks (A -> A, A)
  fixture_dir "t149e"
  fixture c idle; fixture_kind c codex
  block_a="$(cat "$ROOT/tests/fixtures/usage/codex-status-wide.txt")"
  pane_text c "$block_a"
  cat << EOF > "$FAKE_HERDR_DIR/pane-after-3.c"
$block_a

› Ask Codex to do anything

$block_a
EOF
  run_herd usage c
  want_149e="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "c" "codex" "5h=56% left" "week=86% left" "reset5h=21:50" "resetweek=23:09 on 7 Sep")"
  reads_c="$(cat "$FAKE_HERDR_DIR/.reads.c" 2>/dev/null || true)"
  r_want_c="$(printf 'visible 40\nrecent 200\nrecent 200')"
  check T149e target "H1/H2: codex reads recent 200 (guard visible 40), A->A,A fresh" \
        "$want_149e|$r_want_c" "$OUT|$RC|$reads_c"

  # T149f: grok reads visible 40 throughout (no recent)
  fixture_dir "t149f"
  usage_fixture g grok "$ROOT/tests/fixtures/usage/grok-usage.txt"
  run_herd usage g
  reads_g="$(cat "$FAKE_HERDR_DIR/.reads.g" 2>/dev/null || true)"
  r_want_g="$(printf 'visible 40\nvisible 40\nvisible 40')"
  check T149f target "H1/H2: grok reads visible 40 throughout" \
        "0|$r_want_g" "$RC|$reads_g"
fi


if should_run T165 target; then
  for variant in full mixed mirror missing partial reversed; do
    fixture_dir "t165-$variant"
    weekly=$'    [████████] 100.00%\n    Quota available'
    five="$weekly"
    expected=0
    case "$variant" in
      mixed) five=$'    [████░░░░] 50.00%\n    Refreshes in 2h' ;;
      missing) five=$'    [████████] 100.00%'; expected=1 ;;
      partial) five=$'    [████░░░░] 50.00%\n    Quota available'; expected=1 ;;
      reversed) five=$'    [████████] 100.00%'; expected=1 ;;
      mirror) weekly=$'    [████░░░░] 50.00%\n    Refreshes in 43h 10m' ;;
    esac
    printf 'GEMINI MODELS\n  Weekly Limit Remaining\n%s\n  Five Hour Limit Remaining\n%s\nOTHER MODELS\n  Quota available\n  esc Close\n' "$weekly" "$five" > "$WORK/t165.txt"
    if [ "$variant" = reversed ]; then
      printf 'GEMINI MODELS\n  Five Hour Limit Remaining\n%s\n  Weekly Limit Remaining\n%s\n  esc Close\n' "$five" "$weekly" > "$WORK/t165.txt"
    fi
    usage_fixture a agy "$WORK/t165.txt"
    run_herd usage a
    pct=100; reset='?'
    case "$variant" in mixed) pct=50; reset=2h ;; partial) pct=50 ;; esac
    wpct=100; wreset='?'
    if [ "$variant" = mirror ]; then wpct=50; wreset='43h 10m'; fi
    want=$(printf 'a\tagy\t5h=%s%% left\tweek=%s%% left\treset5h=%s\tresetweek=%s' "$pct" "$wpct" "$reset" "$wreset")
    check "T165-$variant" target "agy Quota available: $variant" "$want|$expected" "$OUT|$RC"
  done
fi

# Live finding Codex 2026-09-13: unused session without a reset time.
if should_run T167 target; then
  for variant in unused used missingweek missingweekreset blankweekreset blankweekfooter blankreset explicit fractional stale; do
    fixture_dir "t167-$variant"
    text="$(cat "$ROOT/tests/fixtures/usage/claude-usage-unused.txt")"
    expected=1
    case "$variant" in
      unused) expected=0 ;;
      used) text="${text/0% used/1% used}" ;;
      missingweek) text="${text/Current week (all models)/Other models}" ;;
      missingweekreset) text="${text/   Resets Sep 18, 9:59am (Europe\/Berlin)/}" ;;
      blankweekreset) text="${text/Resets Sep 18, 9:59am (Europe\/Berlin)/Resets   }" ;;
      blankweekfooter) text="${text%%   Resets*}"$'   Resets   \n   Esc to cancel';;
      blankreset) text="${text/0% used/0% used$'\n   Resets   '}" ;;
      explicit) text="${text/0% used/0% used$'\n   Resets 8:29pm (Europe/Berlin)'}"; expected=0 ;;
      fractional) text="${text/0% used/1.0% used}" ;;
    esac
    printf '%s\n' "$text" > "$WORK/claude-unused.txt"
    usage_fixture cl claude "$WORK/claude-unused.txt"
    if [ "$variant" = stale ]; then pane_text cl "$text"; fi
    run_herd usage cl
    check "T167-$variant" target "Claude session without reset: $variant" "$expected" "$RC"
    if [ "$variant" = unused ]; then
      want=$(printf 'cl\tclaude\t5h=100%% left\tweek=88%% left\treset5h=?\tresetweek=Sep 18, 9:59am (Europe/Berlin)')
      check T167-values target "unused session: complete output, weekly reset preserved" "$want" "$OUT"
    fi
  done
fi

# Pure parser: direct import + CLI protocol, without fake herdr/terminal.
if should_run T175 target; then
  check_python_tests T175 test_usage_parser.py 43 \
    'direct usage parser reference tests and CLI contract'
fi

# Position reconstruction and the previous I/O flow against fixed references.
if should_run T177 target; then
  check_python_tests T177 test_usage_view.py 7 \
    'usage page collection: direct references and terminal flow'
fi

# ---------------- usage --log codex: limits from session logs ----------

codex_log_write_line() {
  # $1 file, $2 rate_limits JSON; timestamp = now - 30 min (age 30m).
  local ts
  ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":%s}}\n' "$ts" "$2" > "$1"
}

codex_log_run() {
  # $1 = CODEX_HOME. No HERDR_ENV, no herdr involved.
  OUT="$(TZ=UTC CODEX_HOME="$1" HERD_CONFIG="$WORK/no-config" \
        timeout --signal=KILL 20 env -u HERDR_ENV -u HERDR_WORKSPACE_ID \
        -u HERDR_TAB_ID -u HERDR_PANE_ID \
        "$HERD" usage --log codex 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  return 0
}

codex_rl_r1='{"limit_id":"codex","limit_name":null,"primary":{"used_percent":4.0,"window_minutes":300,"resets_at":1791730323},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1792317123},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}'
codex_want_r1="$(printf 'codex-log\tcodex\t5h=96%% left\tweek=99%% left\treset5h=14:52\tresetweek=2026-10-18 09:52\tage=30m')"

if should_run TCL1 target; then
  fx="$WORK/codexlog-r1"
  mkdir -p "$fx/sessions/2026/10/11"
  codex_log_write_line "$fx/sessions/2026/10/11/rollout-r1.jsonl" "$codex_rl_r1"
  touch -d '2026-10-11 12:00:05' "$fx/sessions/2026/10/11/rollout-r1.jsonl"
  codex_log_run "$fx"
  check TCL1 target "usage --log codex: R1 without herdr, exact line" \
        "$codex_want_r1|0|" "$OUT|$RC|$ERR"
fi

if should_run TCL2 target; then
  fx="$WORK/codexlog-r5"
  mkdir -p "$fx/sessions/2026/10/11"
  # Newest file without a valid rate_limits line, older one with R1.
  printf '{"timestamp":"2026-10-11T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}\n{"broken\n' \
    > "$fx/sessions/2026/10/11/rollout-young.jsonl"
  touch -d '2026-10-11 12:05:00' "$fx/sessions/2026/10/11/rollout-young.jsonl"
  codex_log_write_line "$fx/sessions/2026/10/11/rollout-old.jsonl" "$codex_rl_r1"
  touch -d '2026-10-11 11:00:00' "$fx/sessions/2026/10/11/rollout-old.jsonl"
  codex_log_run "$fx"
  check TCL2 target "usage --log codex: R5 newest file without limits is skipped" \
        "$codex_want_r1|0" "$OUT|$RC"
fi

if should_run TCL3 target; then
  fx="$WORK/codexlog-r6"
  mkdir -p "$fx/sessions/2026/10/11"
  printf '{"timestamp":"2026-10-11T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}\n{"broken\n' \
    > "$fx/sessions/2026/10/11/rollout-empty.jsonl"
  codex_log_run "$fx"
  case "$ERR" in *"$fx/sessions"*) dir_mentioned=yes ;; *) dir_mentioned=no ;; esac
  check TCL3 target "usage --log codex: R6 no valid line -> exit 1 with directory" \
        "1|yes|" "$RC|$dir_mentioned|$OUT"
fi

if should_run TCL4 target; then
  CODEX_HOME="$WORK/codexlog-nix" "$HERD" usage --log grok >/dev/null 2>"$WORK/err-grok"
  rc_grok=$?
  CODEX_HOME="$WORK/codexlog-nix" "$HERD" usage --log >/dev/null 2>"$WORK/err-none"
  rc_none=$?
  err_grok="$(cat "$WORK/err-grok")"
  err_none="$(cat "$WORK/err-none")"
  case "$err_grok|$err_none" in
    *"only codex"*"only codex"*) hint=yes ;;
    *) hint=no ;;
  esac
  check TCL4 target "usage --log: R9 missing/foreign backend -> exit 2 with hint" \
        "2|2|yes" "$rc_grok|$rc_none|$hint"
fi

# Pure evaluation and file search of the codex session logs.
if should_run TCL5 target; then
  check_python_tests TCL5 test_codex_log.py 19 \
    'codex --log: reference cases R1-R11 and CLI contract'
fi

if should_run TAGYCLAUDE target; then
  # The real three-group sample has no terminal chrome; add the view's close marker.
  fixture_dir "tagyclaude"
  cat "$ROOT/tests/fixtures/usage/agy-usage-claude-gpt.txt" > "$WORK/agy-claude.txt"
  printf '\n  esc Close\n' >> "$WORK/agy-claude.txt"
  usage_fixture a agy "$WORK/agy-claude.txt"
  run_herd usage a
  want="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s|0' \
    "a" "agy" "5h=100% left" "week=100% left" "reset5h=?" "resetweek=?" \
    "argon_5h=–" "argon_week=95% left" "argon_reset5h=–" "argon_resetweek=91h 22m" \
    "claude_5h=39% left" "claude_week=69% left" "claude_reset5h=4h 55m" "claude_resetweek=167h 55m")"
  check TAGYCLAUDE target "usage agy: Gemini, Argon and Claude/GPT quotas" "$want" "$OUT|$RC"
fi
