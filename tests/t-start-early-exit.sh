if should_run T156 target; then
  # T156a-n: start aborts IMMEDIATELY if the backend dies before herdr has
  # recognized it (real 2026-09-08: wrong flag -> help + exit within 1 s, herd.sh
  # still ran twice into the 3-min timeout). Real `start` path (no
  # HERD_PRINT_CLI): startsleep delays `agent start`, pane/pane-after deliver the
  # raw pane text (pane ID from split.pane, form p:<id>).
  # Round 5: one baseline read per attempt BEFORE agent start (2nd read) — only
  # the monitor (from the 3rd read) may see a NEW echo; fixtures with pane-after-N
  # are numbered accordingly (baseline = 2, monitor from 3).
  # T156a: early detection — backend help + prompt return in the pane.
  # Round 2: between echo and final prompt lie 50+ help lines (proves why
  # recent-unwrapped 400 instead of visible 40) plus a 200-character long line
  # (proves the 160-character truncation of the diagnosis).
  fixture_dir "t156a"
  printf '%s\n' 'p:t156a' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156a"
  printf '%s\n' '20' > "$FAKE_HERDR_DIR/startsleep.t156a"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156a"
  long156a="LANGZEILE-$(head -c 200 /dev/zero | tr '\0' 'z')"
  # Round 5 (G): 159 ASCII + "ö" (160 characters, 161 bytes) — a byte-wise cut
  # split the ö, character-wise truncation keeps it.
  utf_line156a="$(head -c 159 /dev/zero | tr '\0' 'y')ö"
  {
    printf '%s\n' 'user@host:~/x$ muse --workspace /tmp/x --approval-mode never'
    printf '%s\n' "error: unexpected argument '--workspace' found"
    i=1
    while [ "$i" -le 50 ]; do
      if [ "$i" -eq 49 ]; then
        printf '%s\n' "note: unexpected argument '--workspace' is not supported in muse 1.0.3"
      elif [ "$i" -eq 5 ]; then
        printf '%s\n' "$utf_line156a"
      else
        printf '%s\n' "usage detail line $i: --model <MODEL> --effort <low|high|max> --cwd <DIR>"
      fi
      i=$((i + 1))
    done
    printf '%s\n' "$long156a"
    printf '%s\n' 'user@host:~/x$'
  } > "$FAKE_HERDR_DIR/pane-after-3.t156a"
  t0="$(date +%s)"
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156a 2>"$WORK/err")"
  RC=$?
  t1="$(date +%s)"
  ERR="$(cat "$WORK/err")"
  dt=$((t1 - t0))
  has_early=no; case "$ERR" in *"ended before herdr recognized it"*) has_early=yes ;; esac
  has_help=no; case "$ERR" in *"unexpected argument"*) has_help=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156a" ] && was_killed=yes || was_killed=no
  sc156a="$(cat "$FAKE_HERDR_DIR/.startcount.t156a" 2>/dev/null || echo 0)"
  [ "$dt" -le 5 ] && fast=yes || fast="no(${dt}s)"
  # Round 2: all reads with the new source recent-unwrapped 400; long line in
  # the diagnosis truncated to 160 characters (prefix there, full line not).
  src156a="$(sort -u "$FAKE_HERDR_DIR/.reads.t156a" 2>/dev/null || true)"
  [ "$src156a" = "recent-unwrapped 400" ] && src=yes || src="no($src156a)"
  cut156a=no
  case "$ERR" in *"${long156a:0:160}"*)
    case "$ERR" in *"$long156a"*) cut156a="no-full" ;; *) cut156a=yes ;; esac
    ;;
  esac
  # Round 4: diagnosis from the echo line (echo + first help line in stderr),
  # omission at 54 lines from the echo (54-17=37), pane released via close.
  echo156a=no; case "$ERR" in *"muse --workspace /tmp/x --approval-mode never"*) echo156a=yes ;; esac
  omit156a=no; case "$ERR" in *"…"*"(37 lines omitted)"*) omit156a=yes ;; esac
  close156a=no; case "$(side_log)" in *"close p:t156a"*) close156a=yes ;; esac
  # Round 5 (D): compare the complete diagnosis as a whole — proves position
  # (error line DIRECTLY after the echo), first 12 + omission + last 5.
  want156a="$({
    printf '%s\n' 'user@host:~/x$ muse --workspace /tmp/x --approval-mode never'
    printf '%s\n' "error: unexpected argument '--workspace' found"
    i=1
    while [ "$i" -le 10 ]; do
      if [ "$i" -eq 5 ]; then
        printf '%s\n' "$utf_line156a"
      else
        printf '%s\n' "usage detail line $i: --model <MODEL> --effort <low|high|max> --cwd <DIR>"
      fi
      i=$((i + 1))
    done
    printf '%s\n' "… (37 lines omitted)"
    printf '%s\n' "usage detail line 48: --model <MODEL> --effort <low|high|max> --cwd <DIR>"
    printf '%s\n' "note: unexpected argument '--workspace' is not supported in muse 1.0.3"
    printf '%s\n' "usage detail line 50: --model <MODEL> --effort <low|high|max> --cwd <DIR>"
    printf '%s\n' "${long156a:0:160}"
    printf '%s\n' 'user@host:~/x$'
  })"
  got156a="$(printf '%s\n' "$ERR" | awk '/ended before herdr recognized it/{flag=1;next} flag' | sed -e 's/^  //')"
  [ "$got156a" = "$want156a" ] && diag156a=yes || diag156a=no
  # Round 5 (G): ö preserved AND stderr as a whole valid UTF-8 (a byte-wise
  # cut would leave half an ö = invalid sequence).
  umlaut156a=no; case "$ERR" in *"ö"*) umlaut156a=yes ;; esac
  if printf '%s' "$ERR" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null; then
    utf_valid156a=yes
  else
    utf_valid156a=no
  fi
  check T156a target "start: backend dead immediately -> exit 1 within seconds, full diagnosis comparison, exactly 1 attempt" \
        "1|yes|yes|yes|1|yes|yes|yes|yes|yes|yes|yes|yes|yes" "$RC|$has_early|$has_help|$was_killed|$sc156a|$fast|$src|$cut156a|$echo156a|$omit156a|$close156a|$diag156a|$umlaut156a|$utf_valid156a"

  # T156b: no false alarm with a running TUI — last line not equal to the prompt.
  fixture_dir "t156b"
  printf '%s\n' 'p:t156b' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156b"
  printf '%s\n' '3' > "$FAKE_HERDR_DIR/startsleep.t156b"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156b"
  # Round 5: baseline read (2nd read) still sees the pure prompt, only the
  # monitor (from the 3rd read) the TUI — as in production (typing happens after
  # the baseline).
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-3.t156b"
user@host:~/x$ claude --model opus
╭─────────────────────────────────────╮
│  Muse — interactive session  │
╰─────────────────────────────────────╯
⟩
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156b 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156b=no; case "$OUT" in *"started"*) started156b=yes ;; esac
  early156b=no; case "$ERR" in *"ended before herdr recognized it"*) early156b=yes ;; esac
  check T156b target "start: running TUI (last line not equal to prompt) -> no abort, exit 0" \
        "0|yes|no" "$RC|$started156b|$early156b"

  # T156c: fail-open without a prompt line — pane empty over ALL reads, therefore
  # after the 5 s prompt wait (round 3) fail-open, no early detection (~7 s runtime).
  fixture_dir "t156c"
  printf '%s\n' 'p:t156c' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156c"
  printf '%s\n' '2' > "$FAKE_HERDR_DIR/startsleep.t156c"
  : > "$FAKE_HERDR_DIR/pane.t156c"
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156c 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156c=no; case "$OUT" in *"started"*) started156c=yes ;; esac
  early156c=no; case "$ERR" in *"ended before herdr recognized it"*) early156c=yes ;; esac
  check T156c target "start: empty pane -> fail-open, exit 0 without early detection" \
        "0|yes|no" "$RC|$started156c|$early156c"

  # T156d: prompt BEFORE typing (only the prompt line, no echo) is NO abort.
  fixture_dir "t156d"
  printf '%s\n' 'p:t156d' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156d"
  printf '%s\n' '2' > "$FAKE_HERDR_DIR/startsleep.t156d"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156d"
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156d 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156d=no; case "$OUT" in *"started"*) started156d=yes ;; esac
  early156d=no; case "$ERR" in *"ended before herdr recognized it"*) early156d=yes ;; esac
  check T156d target "start: only prompt line without echo (not yet typed) -> no abort, exit 0" \
        "0|yes|no" "$RC|$started156d|$early156d"

  # T156e (round 3): prompt appears delayed — pane empty at first, prompt line
  # from the 2nd read, prompt + echo + help + prompt from the 4th read
  # (round 5: the 3rd read is the baseline read, still without a new echo).
  # Expected like a): exit 1 within seconds, prompt remembered from the 2nd read.
  fixture_dir "t156e"
  printf '%s\n' 'p:t156e' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156e"
  printf '%s\n' '20' > "$FAKE_HERDR_DIR/startsleep.t156e"
  : > "$FAKE_HERDR_DIR/pane.t156e"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane-after.t156e"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-4.t156e"
user@host:~/x$ muse --effort bogus
error: unexpected argument '--effort' found
Usage: muse [OPTIONS] --model <MODEL>
user@host:~/x$
EOF
  t0="$(date +%s)"
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156e 2>"$WORK/err")"
  RC=$?
  t1="$(date +%s)"
  ERR="$(cat "$WORK/err")"
  dt=$((t1 - t0))
  has_early=no; case "$ERR" in *"ended before herdr recognized it"*) has_early=yes ;; esac
  has_help=no; case "$ERR" in *"unexpected argument"*) has_help=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156e" ] && was_killed=yes || was_killed=no
  sc156e="$(cat "$FAKE_HERDR_DIR/.startcount.t156e" 2>/dev/null || echo 0)"
  [ "$dt" -le 5 ] && fast=yes || fast="no(${dt}s)"
  # Round 4: only 4 lines from the echo -> diagnosis complete, NO omission line;
  # echo + help in stderr, pane released via close.
  echo156e=no; case "$ERR" in *"muse --effort bogus"*) echo156e=yes ;; esac
  noomit156e=yes; case "$ERR" in *"lines omitted"*) noomit156e=no ;; esac
  close156e=no; case "$(side_log)" in *"close p:t156e"*) close156e=yes ;; esac
  check T156e target "start: delayed prompt -> exit 1 within seconds with early detection" \
        "1|yes|yes|yes|1|yes|yes|yes|yes" "$RC|$has_early|$has_help|$was_killed|$sc156e|$fast|$echo156e|$noomit156e|$close156e"

  # T156f (round 5, A spec-literal): client ends with ok synchronously to the
  # second read (startsleep small, pane from read 2 with signature) -> NO abort,
  # exit 0, no close, no .startkilled. Read 2 is the baseline read
  # (echo already there -> baseline 1), the monitor afterwards sees no NEW echo.
  # Without a baseline (round 4) read 2 as the first monitor read would abort.
  fixture_dir "t156f"
  printf '%s\n' 'p:t156f' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156f"
  printf '%s\n' '1' > "$FAKE_HERDR_DIR/startsleep.t156f"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156f"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after.t156f"
user@host:~/x$ muse --model opus
error: unexpected argument '--model' found
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156f 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156f=no; case "$OUT" in *"started"*) started156f=yes ;; esac
  early156f=no; case "$ERR" in *"ended before herdr recognized it"*) early156f=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156f" ] && killed156f=yes || killed156f=no
  sc156f="$(cat "$FAKE_HERDR_DIR/.startcount.t156f" 2>/dev/null || echo 0)"
  close156f=no; case "$(side_log)" in *"close p:t156f"*) close156f=yes ;; esac
  check T156f target "start: client ok during the read -> no abort, exit 0, no close" \
        "0|yes|no|no|1|no" "$RC|$started156f|$early156f|$killed156f|$sc156f|$close156f"

  # T156g (round 6, D): echo arises only through attempt 1 (pane-after-start
  # after noreg), baseline before attempt 1 is 0. Attempt 2 sees the same text
  # (baseline 1, no new echo) -> exit 0, .startcount=2, no close.
  # A baseline taken only once before attempt 1 (0 for both) would abort
  # attempt 2 — that is the discrimination that pane-after.t156g
  # (echo already at attempt 1's baseline read) could not provide.
  fixture_dir "t156g"
  printf '%s\n' 'p:t156g' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' "noreg:error: unexpected argument '--bogus' found" > "$FAKE_HERDR_DIR/start.t156g"
  printf '%s\n' 'ok' >> "$FAKE_HERDR_DIR/start.t156g"
  printf '%s\n' '3' > "$FAKE_HERDR_DIR/startsleep.t156g"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156g"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-start.t156g"
user@host:~/x$ muse --bogus foo
error: unexpected argument '--bogus' found
Usage: muse [OPTIONS] --model <MODEL>
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156g 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156g=no; case "$OUT" in *"started"*) started156g=yes ;; esac
  early156g=no; case "$ERR" in *"ended before herdr recognized it"*) early156g=yes ;; esac
  sc156g="$(cat "$FAKE_HERDR_DIR/.startcount.t156g" 2>/dev/null || echo 0)"
  close156g=no; case "$(side_log)" in *"close p:t156g"*) close156g=yes ;; esac
  check T156g target "start: old echo does not abort attempt 2 -> exit 0, 2 attempts" \
        "0|yes|no|2|no" "$RC|$started156g|$early156g|$sc156g|$close156g"

  # T156h (round 5, B2): old scrollback with an echo line (init command) before
  # the first attempt -> no false alarm; only the NEW echo + prompt triggers.
  # Read 3 still shows the old text (baseline 1 = current 1, no abort),
  # read 4 the new echo (2 > 1 -> abort with NEW diagnosis).
  fixture_dir "t156h"
  printf '%s\n' 'p:t156h' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156h"
  printf '%s\n' '20' > "$FAKE_HERDR_DIR/startsleep.t156h"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane.t156h"
user@host:~/x$ echo init
init
user@host:~/x$
EOF
  # Full text (no delta): old scrollback + new echo -> 2 echoes > baseline 1.
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-4.t156h"
user@host:~/x$ echo init
init
user@host:~/x$
user@host:~/x$ muse --effort bogus
error: unexpected argument '--effort' found
Usage: muse [OPTIONS] --model <MODEL>
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156h 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  has_early=no; case "$ERR" in *"ended before herdr recognized it"*) has_early=yes ;; esac
  newecho156h=no; case "$ERR" in *"muse --effort bogus"*) newecho156h=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156h" ] && was_killed=yes || was_killed=no
  sc156h="$(cat "$FAKE_HERDR_DIR/.startcount.t156h" 2>/dev/null || echo 0)"
  rc156h="$(cat "$FAKE_HERDR_DIR/.rcount.t156h" 2>/dev/null || echo 0)"
  [ "${rc156h:-0}" -ge 4 ] && reads156h=yes || reads156h="no($rc156h)"
  close156h=no; case "$(side_log)" in *"close p:t156h"*) close156h=yes ;; esac
  check T156h target "start: scrollback echo no false alarm, new echo triggers -> exit 1" \
        "1|yes|yes|yes|1|yes|yes" "$RC|$has_early|$newecho156h|$was_killed|$sc156h|$reads156h|$close156h"

  # T156i (round 5, C): helper negative test directly — a numeric awk comparison
  # would consider "1" and prompt "01" equal (exit 0), a string comparison does not.
  eval "$(sed -n '/^start_shell_back()/,/^}/p' "$ROOT/scripts/herd.sh")"
  if printf '%s\n' '01 cmd' '1' | start_shell_back 01 0; then cneg156i=no; else cneg156i=yes; fi
  if printf '%s\n' 'prompt$ cmd' 'prompt$' | start_shell_back 'prompt$' 0; then cpos156i=yes; else cpos156i=no; fi
  check T156i target "start_shell_back: string comparison ('01' not equal '1'), hit ok" \
        "yes|yes" "$cneg156i|$cpos156i"

  # T156j (round 5, A re-check): NEW echo (baseline 0), but the client ends with
  # ok DURING the monitor read -> NO abort, exit 0, no close, no .startkilled.
  # readsleep 2 holds the monitor read (from read 3) while startsleep 1 lets the
  # client end in the middle — the signature hits the dead client
  # deterministically (without the re-check it would abort).
  fixture_dir "t156j"
  printf '%s\n' 'p:t156j' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156j"
  printf '%s\n' '1' > "$FAKE_HERDR_DIR/startsleep.t156j"
  printf '%s\n' '2' > "$FAKE_HERDR_DIR/readsleep.t156j"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156j"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-3.t156j"
user@host:~/x$ muse --model opus
error: unexpected argument '--model' found
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156j 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156j=no; case "$OUT" in *"started"*) started156j=yes ;; esac
  early156j=no; case "$ERR" in *"ended before herdr recognized it"*) early156j=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156j" ] && killed156j=yes || killed156j=no
  sc156j="$(cat "$FAKE_HERDR_DIR/.startcount.t156j" 2>/dev/null || echo 0)"
  close156j=no; case "$(side_log)" in *"close p:t156j"*) close156j=yes ;; esac
  check T156j target "start: new echo, client ok during reads -> re-check, no abort" \
        "0|yes|no|no|1|no" "$RC|$started156j|$early156j|$killed156j|$sc156j|$close156j"

  # T156k (round 6, A1): baseline read fails once (readfail-once=2).
  # Pane from read 3 has echo+prompt — with baseline 0 that would be an abort.
  # Invalid baseline -> monitor off, exit 0, no close, no .startkilled.
  fixture_dir "t156k"
  printf '%s\n' 'p:t156k' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156k"
  printf '%s\n' '2' > "$FAKE_HERDR_DIR/startsleep.t156k"
  printf '%s\n' '2' > "$FAKE_HERDR_DIR/readfail-once.t156k"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156k"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-3.t156k"
user@host:~/x$ muse --model opus
error: unexpected argument '--model' found
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156k 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156k=no; case "$OUT" in *"started"*) started156k=yes ;; esac
  early156k=no; case "$ERR" in *"ended before herdr recognized it"*) early156k=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156k" ] && killed156k=yes || killed156k=no
  sc156k="$(cat "$FAKE_HERDR_DIR/.startcount.t156k" 2>/dev/null || echo 0)"
  close156k=no; case "$(side_log)" in *"close p:t156k"*) close156k=yes ;; esac
  check T156k target "start: baseline read fails once -> no abort, exit 0" \
        "0|yes|no|no|1|no" "$RC|$started156k|$early156k|$killed156k|$sc156k|$close156k"

  # T156l (round 6, A2): baseline read hangs (readsleep-2 > 3 s timeout) ->
  # baseline invalid, monitor off. pane-after-3 would be an abort with baseline 0.
  # After the timeout exit 0, no close.
  fixture_dir "t156l"
  printf '%s\n' 'p:t156l' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156l"
  printf '%s\n' '1' > "$FAKE_HERDR_DIR/startsleep.t156l"
  printf '%s\n' '4' > "$FAKE_HERDR_DIR/readsleep-2.t156l"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156l"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-3.t156l"
user@host:~/x$ muse --model opus
error: unexpected argument '--model' found
user@host:~/x$
EOF
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156l 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156l=no; case "$OUT" in *"started"*) started156l=yes ;; esac
  early156l=no; case "$ERR" in *"ended before herdr recognized it"*) early156l=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156l" ] && killed156l=yes || killed156l=no
  sc156l="$(cat "$FAKE_HERDR_DIR/.startcount.t156l" 2>/dev/null || echo 0)"
  close156l=no; case "$(side_log)" in *"close p:t156l"*) close156l=yes ;; esac
  check T156l target "start: baseline read timeout -> no abort, exit 0" \
        "0|yes|no|no|1|no" "$RC|$started156l|$early156l|$killed156l|$sc156l|$close156l"

  # T156m (round 6, B): client ends with ok after the re-check snapshot
  # (ps wrapper holds the 3rd liveness status until .started exists) -> wait 0
  # after the kill, success path, no close, no .startkilled.
  fixture_dir "t156m" "$WORK/t156m-bin"
  printf '%s\n' 'p:t156m' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156m"
  printf '%s\n' '1' > "$FAKE_HERDR_DIR/startsleep.t156m"
  printf '%s\n' '3' > "$FAKE_HERDR_DIR/.ps-stall-alive"
  printf '%s\n' 't156m' > "$FAKE_HERDR_DIR/.ps-stall-name"
  printf '%s\n' 'user@host:~/x$' > "$FAKE_HERDR_DIR/pane.t156m"
  cat <<'EOF' > "$FAKE_HERDR_DIR/pane-after-3.t156m"
user@host:~/x$ muse --model opus
error: unexpected argument '--model' found
user@host:~/x$
EOF
  realps="$(command -v ps)"
  cat > "$WORK/t156m-bin/ps" << EOF
#!/usr/bin/env bash
real="${realps}"
if [ "\${1-}" = "-o" ] && [ "\${2-}" = "stat=" ] && [ "\${3-}" = "-p" ]; then
  pid="\${4-}"
  stat="\$("\$real" -o stat= -p "\$pid" 2>/dev/null || true)"
  if [ -n "\${FAKE_HERDR_DIR:-}" ] && [ -f "\$FAKE_HERDR_DIR/.ps-stall-alive" ]; then
    want="\$(tr -d ' \\n\\r' < "\$FAKE_HERDR_DIR/.ps-stall-alive")"
    case "\$stat" in
      *Z*|'') ;;
      *)
        n=0
        [ -f "\$FAKE_HERDR_DIR/.ps-alive-n" ] && n="\$(cat "\$FAKE_HERDR_DIR/.ps-alive-n")"
        n=\$((n + 1))
        echo "\$n" > "\$FAKE_HERDR_DIR/.ps-alive-n"
        if [ "\$n" = "\$want" ]; then
          nm="\$(cat "\$FAKE_HERDR_DIR/.ps-stall-name" 2>/dev/null || true)"
          dl=\$(( \$(date +%s) + 5 ))
          while [ -n "\$nm" ] && [ ! -f "\$FAKE_HERDR_DIR/.started.\$nm" ] && [ "\$(date +%s)" -lt "\$dl" ]; do
            /bin/sleep 0.02
          done
        fi
        ;;
    esac
  fi
  printf '%s\\n' "\$stat"
  exit 0
fi
exec "\$real" "\$@"
EOF
  chmod +x "$WORK/t156m-bin/ps"
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$WORK/t156m-bin:$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156m 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156m=no; case "$OUT" in *"started"*) started156m=yes ;; esac
  early156m=no; case "$ERR" in *"ended before herdr recognized it"*) early156m=yes ;; esac
  [ -f "$FAKE_HERDR_DIR/.startkilled.t156m" ] && killed156m=yes || killed156m=no
  sc156m="$(cat "$FAKE_HERDR_DIR/.startcount.t156m" 2>/dev/null || echo 0)"
  close156m=no; case "$(side_log)" in *"close p:t156m"*) close156m=yes ;; esac
  check T156m target "start: wait 0 after re-check kill -> success, no close" \
        "0|yes|no|no|1|no" "$RC|$started156m|$early156m|$killed156m|$sc156m|$close156m"

  # T156n (round 6, E): sliding 400-line window — old echo drops out,
  # new one is added, the count stays 1. No hit, fail-open, exit 0.
  fixture_dir "t156n"
  printf '%s\n' 'p:t156n' > "$FAKE_HERDR_DIR/split.pane"
  printf '%s\n' 'ok' > "$FAKE_HERDR_DIR/start.t156n"
  printf '%s\n' '1' > "$FAKE_HERDR_DIR/startsleep.t156n"
  {
    printf '%s\n' 'user@host:~/x$ echo init'
    i=2
    while [ "$i" -le 399 ]; do
      printf '%s\n' "oldfill $i"
      i=$((i + 1))
    done
    printf '%s\n' 'user@host:~/x$'
  } > "$FAKE_HERDR_DIR/pane.t156n"
  {
    i=1
    while [ "$i" -le 300 ]; do
      printf '%s\n' "newfill $i"
      i=$((i + 1))
    done
    printf '%s\n' 'user@host:~/x$ muse --effort bogus'
    i=302
    while [ "$i" -le 399 ]; do
      printf '%s\n' "newfill $i"
      i=$((i + 1))
    done
    printf '%s\n' 'user@host:~/x$'
  } > "$FAKE_HERDR_DIR/pane-after-3.t156n"
  eval "$(sed -n '/^start_echo_count()/,/^}/p' "$ROOT/scripts/herd.sh")"
  eval "$(sed -n '/^start_shell_back()/,/^}/p' "$ROOT/scripts/herd.sh")"
  cbase156n="$(start_echo_count 'user@host:~/x$' < "$FAKE_HERDR_DIR/pane.t156n")"
  cnew156n="$(start_echo_count 'user@host:~/x$' < "$FAKE_HERDR_DIR/pane-after-3.t156n")"
  if start_shell_back 'user@host:~/x$' "$cbase156n" < "$FAKE_HERDR_DIR/pane-after-3.t156n"; then
    hit156n=yes
  else
    hit156n=no
  fi
  OUT="$(timeout --signal=KILL 15 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HOME="$WORK/home" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        "$HERD" start claude --name t156n 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  started156n=no; case "$OUT" in *"started"*) started156n=yes ;; esac
  early156n=no; case "$ERR" in *"ended before herdr recognized it"*) early156n=yes ;; esac
  close156n=no; case "$(side_log)" in *"close p:t156n"*) close156n=yes ;; esac
  check T156n target "start: 400-line window count equal -> fail-open, exit 0" \
        "1|1|no|0|yes|no|no" "$cbase156n|$cnew156n|$hit156n|$RC|$started156n|$early156n|$close156n"
fi

