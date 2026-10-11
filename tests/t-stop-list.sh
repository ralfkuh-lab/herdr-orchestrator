# ------------------------------------------------- stop/list sessions ---
# Spec .herd/spec-stop-session.md: `stop` names the session ID, `list
# --sessions` shows it. Fixture session.<name> (fake tests/bin/herdr).

if should_run T157a target; then
  fixture_dir "t157a"
  fixture sa working
  fixture_kind sa claude
  fixture_session sa sess-aaa-111
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd stop sa
  want="$(printf '[herd] pane p:sa (sa) closed.\n[herd] session ID (claude): sess-aaa-111  Resume:\n  herd.sh start claude --name sa --resume sess-aaa-111')"
  hit=no; case "$(side_log)" in *"close p:sa"*) hit=yes ;; esac
  check T157a target "stop with session: both lines, resume command with ID, pane close, exit 0" \
        "$want|0|yes" "$OUT|$RC|$hit"
fi

if should_run T157b target; then
  fixture_dir "t157b"
  fixture sb idle
  fixture_kind sb muse
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd stop sb
  want="$(printf '[herd] pane p:sb (sb) closed.\n[herd] no session ID reported (backend without herdr integration or not reported yet) — resume only as the last session:\n  herd.sh start muse --name sb --resume')"
  hit=no; case "$(side_log)" in *"close p:sb"*) hit=yes ;; esac
  check T157b target "stop without session (muse): note line with --resume without ID, exit 0" \
        "$want|0|yes" "$OUT|$RC|$hit"
fi

if should_run T157c target; then
  fixture_dir "t157c"
  fixture sc working
  fixture_kind sc claude
  fixture_ws sc w9
  fixture_session sc sess-ccc-333
  touch "$FAKE_HERDR_DIR/.getfail.sc"
  rm -f "$FAKE_HERDR_DIR/.side"
  # Own space: pane resolution runs through `agent list`, only the
  # session `agent get` before close fails (.getfail).
  HERD_TEST_WS=w9 run_herd stop sc
  hit=no; case "$(side_log)" in *"close p:sc"*) hit=yes ;; esac
  check T157c target "stop on get error: only the first line, pane closed anyway, exit 0" \
        "[herd] pane p:sc (sc) closed.|0|yes" "$OUT|$RC|$hit"
fi

if should_run T157d target; then
  fixture_dir "t157d"
  fixture la working
  fixture_kind la claude
  fixture_session la id-1
  fixture_ws la w9
  fixture lb idle
  fixture_ws lb wH
  run_herd list --sessions
  got="$(printf '%s' "$OUT" | sort | tr '\n' ';')"; rc1=$RC
  run_herd list
  plain="$(printf '%s' "$OUT" | sort | tr '\n' ';')"; rc2=$RC
  run_herd list --sessions --all-spaces
  both="$(printf '%s' "$OUT" | sort | tr '\n' ';')"; rc3=$RC
  check T157d target "list --sessions: ID or -; unchanged without the option (T16 form); with --all-spaces space, then ID" \
        "la working p:la id-1;lb idle p:lb -;|0/la working p:la;lb idle p:lb;|0/la working p:la w9 id-1;lb idle p:lb wH -;|0" \
        "$got|$rc1/$plain|$rc2/$both|$rc3"
  # Own space: only the own session is visible, also in the --sessions branch.
  HERD_TEST_WS=w9 run_herd list --sessions
  gotw9="$(printf '%s' "$OUT" | tr '\n' ';')"; rcw9=$RC
  HERD_TEST_WS=w9 run_herd list
  plainw9="$(printf '%s' "$OUT" | tr '\n' ';')"
  check T157d2 target "list (also --sessions) in the own space: only the own session" \
        "la working p:la id-1|0/la working p:la|0" "$gotw9|$rcw9/$plainw9|$RC"
  # Byte identity without the flag: unnormalized stdout via file + cmp,
  # including the trailing newline (no sort|tr).
  env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
    PATH="$ROOT/tests/bin:$PATH" HERDR_ENV=1 FAKE_HERDR_DIR="$WORK/t157d" \
    "$HERD" list >"$WORK/t157d.out" 2>/dev/null
  rcb=$?
  printf 'la working p:la\nlb idle p:lb\n' >"$WORK/t157d.want"
  cmp -s "$WORK/t157d.want" "$WORK/t157d.out" && byte=yes || byte=no
  check T157d3 target "list without the flag: stdout byte-identical (file + cmp, with newline)" \
        "0|yes" "$rcb|$byte"
fi

if should_run T157e target; then
  fixture_dir "t157e"
  fixture a idle
  run_herd list --bogus
  check T157e target "list --bogus -> exit 2 (existing behavior)" "2" "$RC"
fi

if should_run T157f target; then
  fixture_dir "t157f"
  fixture sd idle
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd stop sd
  hit=no; case "$(side_log)" in *"close p:sd"*) hit=yes ;; esac
  check T157f target "stop without kind (agent null): second line omitted entirely, exit 0" \
        "[herd] pane p:sd (sd) closed.|0|yes" "$OUT|$RC|$hit"
fi

if should_run T157g target; then
  fixture_dir "t157g"
  qname="we ird"; qid="s\"id\\l d\$e'f;g"
  fixture "$qname" working
  fixture_kind "$qname" claude
  fixture_session "$qname" "$qid"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd stop "$qname"
  qline="$(printf '  herd.sh start %q --name %q --resume %q' claude "$qname" "$qid")"
  want="$(printf '[herd] pane p:%s (%s) closed.\n[herd] session ID (claude): %s  Resume:\n%s' \
    "$qname" "$qname" "$qid" "$qline")"
  hit=no; case "$(side_log)" in *"close p:$qname"*) hit=yes ;; esac
  check T157g target "stop with special characters: resume line shell-quoted, ID complete, exit 0" \
        "$want|0|yes" "$OUT|$RC|$hit"
  # Fake roundtrip: an ID with quote/backslash comes back exactly through get AND list.
  getv="$(FAKE_HERDR_DIR="$WORK/t157g" "$ROOT/tests/bin/herdr" agent get "$qname" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_session"]["value"])')"
  [ "$getv" = "$qid" ] && getok=yes || getok=no
  run_herd list --sessions
  # grep -F: the backslash in the ID must not become a case escape.
  printf '%s\n' "$OUT" | grep -Fq "$qid" && listhit=yes || listhit=no
  check T157g2 target "fake session with quote/backslash: get and list roundtrip exact" \
        "yes|yes" "$getok|$listhit"
fi

if should_run T157h target; then
  fixture_dir "t157h"
  qname="we ird"; qid="se\$ss';x"
  fixture "$qname" working
  fixture_kind "$qname" claude
  fixture_session "$qname" "$qid"
  run_herd stop "$qname"
  # Roundtrip: run the copied line against a herd.sh stub - exactly the
  # three arguments backend/name/ID must arrive (no split, no injection).
  mkdir -p "$WORK/t157h-bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "${HERD_STUB_OUT:?}"\n' > "$WORK/t157h-bin/herd.sh"
  chmod +x "$WORK/t157h-bin/herd.sh"
  line="$(printf '%s\n' "$OUT" | sed -n '3p')"
  export HERD_STUB_OUT="$WORK/t157h-args"
  PATH="$WORK/t157h-bin:$PATH" eval "$line"
  gotargs="$(tr '\n' '|' < "$WORK/t157h-args")"
  check T157h target "resume line via eval: exactly backend/name/ID at the stub (no split/inject)" \
        "start|claude|--name|$qname|--resume|$qid|" "$gotargs"
fi

if should_run T158 target; then
  # T158a: usage a (kind agy), reads return pages 1 to 6 -> 5h=89% left, week=85% left, exact key sequence
  fixture_dir "t158a"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 3
  pane_after_files a 4 "$ROOT/tests/fixtures/usage/agy-usage-paged-"{2..6}.txt
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158a="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  want_side="$(printf 'prompt a /usage\npane-keys p:a down down down down down\npane-keys p:a down down down down down\npane-keys p:a down down down down down\npane-keys p:a down down down down down\npane-keys p:a down down down down down\npane-keys p:a esc')"
  side="$(cat "$FAKE_HERDR_DIR/.side" 2>/dev/null)"
  side_ok=no; [ "$side" = "$want_side" ] && side_ok=yes
  check T158a target "usage agy paged: 5h=89% left, week=85% left, exact key sequence (prompt, 5x down*5, esc)" \
        "$want_158a|yes" "$OUT|$RC|$side_ok"

  # T158b: tall (usage-agy-tall-live-53rows.txt) -> no down, correct values
  fixture_dir "t158b"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-tall.txt"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158b="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=76% left" "week=83% left" "reset5h=3h 33m" "resetweek=42h 44m")"
  side="$(side_log)"
  has_down=no; case "$side" in *"down"*) has_down=yes ;; esac
  has_esc=no; case "$side" in *"pane-keys p:a esc"*) has_esc=yes ;; esac
  check T158b target "usage agy tall: no down, correct values, esc sent" \
        "$want_158b|no|yes" "$OUT|$RC|$has_down|$has_esc"

  # T158c: repeated page (reads return page 1 twice, then 2..6) -> idempotent, exactly 1 extra read, no error
  fixture_dir "t158c"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 3
  pane_after_files a 4 "$ROOT/tests/fixtures/usage/agy-usage-paged-"{1..6}.txt
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158c="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  rcount="$(cat "$FAKE_HERDR_DIR/.rcount.a" 2>/dev/null || echo 0)"
  check T158c target "usage agy repeated page: idempotent, exactly one extra read (9), no error" \
        "$want_158c|9" "$OUT|$RC|$rcount"

  # T158d: read error in the middle of paging (readfail-once) -> step repeated, result correct
  fixture_dir "t158d"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 3
  echo 4 > "$FAKE_HERDR_DIR/readfail-once.a"
  pane_after_files a 5 "$ROOT/tests/fixtures/usage/agy-usage-paged-"{2..6}.txt
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158d="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  check T158d target "usage agy read error while paging: transient error repeated, result correct" \
        "$want_158d" "$OUT|$RC"

  # T158e: abort when the view does not move -> exactly one paging step + esc, exit 1
  fixture_dir "t158e"
  usage_fixture a agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 3
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  has_5h_q=no; case "$OUT" in *"5h=?"*) has_5h_q=yes ;; esac
  side_158e=""
  [ -f "$FAKE_HERDR_DIR/.side" ] && side_158e="$(cat "$FAKE_HERDR_DIR/.side")"
  want_side_158e="$(printf 'prompt a /usage\npane-keys p:a down down down down down\npane-keys p:a esc')"
  check T158e target "usage agy abort when the view does not move: exactly one paging step + esc, exit 1" \
        "$want_side_158e|1|yes" "$side_158e|$RC|$has_5h_q"

  # T158f: baseline open (3 variants: normal, esc fails, view does not close)
  # f1: normal flow with an open baseline
  fixture_dir "t158f1"
  fixture a idle; fixture_kind a agy
  cp "$ROOT/tests/fixtures/usage/agy-usage-tall.txt" "$FAKE_HERDR_DIR/pane.a"
  printf '%s\n' "Gemini CLI ready." ">" > "$FAKE_HERDR_DIR/pane-after-3.a"
  pane_after_files a 4 "$ROOT/tests/fixtures/usage/agy-usage-paged-"{1..6}.txt
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158f1="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  idx_pre_esc="$(grep -n "pane-keys p:a esc" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  idx_prompt="$(grep -n "prompt a /usage" "$FAKE_HERDR_DIR/.side" | head -1 | cut -d: -f1)"
  pre_esc_ok=no; [ -n "$idx_pre_esc" ] && [ -n "$idx_prompt" ] && [ "$idx_pre_esc" -lt "$idx_prompt" ] && pre_esc_ok=yes
  check T158f1 target "usage agy baseline open: esc before /usage, then paged -> exit 0" \
        "$want_158f1|yes" "$OUT|$RC|$pre_esc_ok"

  # f2: esc fails (.keysfail)
  fixture_dir "t158f2"
  fixture a idle; fixture_kind a agy
  cp "$ROOT/tests/fixtures/usage/agy-usage-tall.txt" "$FAKE_HERDR_DIR/pane.a"
  echo "simulated esc error" > "$FAKE_HERDR_DIR/.keysfail.a"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  has_esc_err=no
  case "$ERR" in *"[herd] usage: esc failed:"*) has_esc_err=yes ;; esac
  check T158f2 target "usage agy baseline open: esc fails -> exit 1 with error message" \
        "1|yes" "$RC|$has_esc_err"

  # f3: view stays open (marker in all reads)
  fixture_dir "t158f3"
  fixture a idle; fixture_kind a agy
  cp "$ROOT/tests/fixtures/usage/agy-usage-tall.txt" "$FAKE_HERDR_DIR/pane.a"
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_USAGE_WAIT_SEC=0.6 HERD_USAGE_POLL_SEC=0.2 run_herd usage a
  has_close_err=no
  case "$ERR" in *"[herd] usage: old /usage view cannot be closed"*) has_close_err=yes ;; esac
  check T158f3 target "usage agy baseline open: does not close -> exit 1 with error message" \
        "1|yes" "$RC|$has_close_err"

  # T158g: GEMINI MODELS without a key line in the read -> not fresh, timeout behavior as before
  fixture_dir "t158g"
  cat << 'EOF' > "$WORK/t158g-fix.txt"
GEMINI MODELS
  Weekly Limit Remaining
    95% remaining · Refreshes in 116h
  Five Hour Limit Remaining
    83% remaining · Refreshes in 1h 1
CLAUDE AND GPT MODELS
EOF
  usage_fixture a agy "$WORK/t158g-fix.txt" 3
  rm -f "$FAKE_HERDR_DIR/.side"
  HERD_USAGE_WAIT_SEC=0.6 HERD_USAGE_POLL_SEC=0.2 run_herd usage a
  want_158g="$(printf '%s\t%s\t5h=?\tweek=?\treset5h=?\tresetweek=?' "a" "agy")"
  has_stale=no
  case "$ERR" in *"no new output"*) has_stale=yes ;; esac
  check T158g target "usage agy: GEMINI MODELS without a key line -> not fresh, timeout as before" \
        "$want_158g|1|yes" "$OUT|$RC|$has_stale"

  # T158h: B1 wrap (bar before the footer, remaining on the next page) -> 5h=89% left, reset5h=4h 22m
  fixture_dir "t158h"
  cat << 'EOF' > "$WORK/t158h-p1.txt"
  Account: test@example.com

GEMINI MODELS
  Weekly Limit Remaining
    85% remaining · Refreshes in 43h 33m
  Five Hour Limit Remaining
    [████████████████████████████████████████████░░░░░░] 88.67%
  (1–5 of 10 lines)

  ↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close
                                                            plan · Gemini 3.8 Flash · high
EOF
  cat << 'EOF' > "$WORK/t158h-p2.txt"
  Account: test@example.com

    89% remaining · Refreshes in 4h 22m

CLAUDE AND GPT MODELS
  Weekly Limit Remaining
    Quota available
  (6–10 of 10 lines)

  ↑/↓ Scroll · pgup/pgdown Page · ctrl+end Bottom · ctrl+home Top · esc Close
                                                            plan · Gemini 3.8 Flash · high
EOF
  usage_fixture a agy "$WORK/t158h-p1.txt" 3
  pane_after_files a 4 "$WORK/t158h-p2.txt"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158h="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  check T158h target "usage agy B1: bar before the footer, remaining/reset on the next page" \
        "$want_158h" "$OUT|$RC"

  # T158i: usage --probe agy with incomplete collection -> raw block with position numbers
  fixture_dir "t158i"
  # start_read 6 instead of 4: since early detection (T156) `start` reads twice
  # upfront (prompt line + echo baseline), see T147/T155j.
  usage_fixture usage-agy agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 6
  echo -n "p:usage-agy" > "$FAKE_HERDR_DIR/split.pane"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe agy
  has_hdr=no; case "$ERR" in *"[herd] usage --probe agy: raw block (parse error):"*) has_hdr=yes ;; esac
  has_pos1=no; case "$ERR" in *"1: GEMINI MODELS"*) has_pos1=yes ;; esac
  has_pos5=no; case "$ERR" in *"5:"*"85.48%"*) has_pos5=yes ;; esac
  check T158i target "usage --probe agy incomplete: raw block with position numbers on stderr, exit 1" \
        "1|yes|yes|yes" "$RC|$has_hdr|$has_pos1|$has_pos5"

  # T158j: budget path: a grows by 1 per read (N=30, w=5) -> exactly ceil(30/5)+2 = 8 down steps, exit 1
  fixture_dir "t158j"
  dash="$(printf '\xe2\x80\x93')"
  for step in $(seq 0 8); do
    a_val=$((1 + step))
    b_val=$((5 + step))
    read_num=$((3 + step))
    cat <<EOF > "$FAKE_HERDR_DIR/pane-after-${read_num}.a"
└ Models & Quota
Line $a_val
Line $((a_val + 1))
Line $((a_val + 2))
Line $((a_val + 3))
Line $b_val
(${a_val}${dash}${b_val} of 30 lines)  esc Close
EOF
  done
  fixture a idle; fixture_kind a agy
  pane_text a "Gemini CLI ready."$'\n'">"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  has_5h_q=no; case "$OUT" in *"5h=?"*) has_5h_q=yes ;; esac
  down_count=0
  [ -f "$FAKE_HERDR_DIR/.side" ] && down_count="$(grep -c 'pane-keys p:a down down down down down' "$FAKE_HERDR_DIR/.side" || echo 0)"
  last_key=""
  [ -f "$FAKE_HERDR_DIR/.side" ] && last_key="$(tail -n 1 "$FAKE_HERDR_DIR/.side")"
  check T158j target "usage agy budget path: exactly 8 down steps at a+=1, then esc, exit 1" \
        "8|pane-keys p:a esc|1|yes" "$down_count|$last_key|$RC|$has_5h_q"

  # T158k: down fails in the middle of paging -> exit 1 with error message, --probe shows the raw block
  fixture_dir "t158k"
  # start_read 6 instead of 4 (prompt line + echo baseline from start, T156).
  usage_fixture usage-agy agy "$ROOT/tests/fixtures/usage/agy-usage-paged-1.txt" 6
  echo -n "p:usage-agy" > "$FAKE_HERDR_DIR/split.pane"
  echo "down error injected" > "$FAKE_HERDR_DIR/.keysfail.usage-agy"
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage --probe agy
  has_sk_err=no; case "$ERR" in *"[herd] usage: send-keys down failed: down error injected"*) has_sk_err=yes ;; esac
  has_hdr=no; case "$ERR" in *"[herd] usage --probe agy: raw block (parse error):"*) has_hdr=yes ;; esac
  has_pos1=no; case "$ERR" in *"1: GEMINI MODELS"*) has_pos1=yes ;; esac
  check T158k target "usage agy: down fails, exit 1 with error message and --probe raw block" \
        "1|yes|yes|yes" "$RC|$has_sk_err|$has_hdr|$has_pos1"

  # T158l: account line between 'Refreshes in' and the value -> account dropped, reset5h found, exit 0
  fixture_dir "t158l"
  cat <<'EOF' > "$WORK/t158l-fix.txt"
      ▄▀▀▄        Antigravity CLI 1.1.27
     ▀▀▀▀▀▀       user@example.com (Google AI Pro)
    ▀▀▀▀▀▀▀▀      Gemini 3.8 Flash (High)
   ▄▀▀    ▀▀▄     ~/dev/herdr-orchestrator-wt-usage
  ▄▀▀      ▀▀▄
───────────────────────────────────────────────────────────────────────────────────────────
>
───────────────────────────────────────────────────────────────────────────────────────────
└ Models & Quota
  Account: user@example.com
GEMINI MODELS
  Models within this group: Gemini Flash, Gemini Pro
  Weekly Limit Remaining
    [██████████████████████████████████████████░░░░░░░░] 85.00%
    85% remaining · Refreshes in 43h 33m
  Five Hour Limit Remaining
    [██████████████████████████████████████░░░░░░░░░░░░] 89.00%
    89% remaining · Refreshes in
    Account: test
    4h 22m
CLAUDE AND GPT MODELS
  esc Close
EOF
  usage_fixture a agy "$WORK/t158l-fix.txt" 3
  rm -f "$FAKE_HERDR_DIR/.side"
  run_herd usage a
  want_158l="$(printf '%s\t%s\t%s\t%s\t%s\t%s|0' "a" "agy" "5h=89% left" "week=85% left" "reset5h=4h 22m" "resetweek=43h 33m")"
  check T158l target "usage agy: account line after Refreshes in dropped, reset5h correct, exit 0" \
        "$want_158l" "$OUT|$RC"
fi

