# Security hardening before publication (security review 2026-10-11, findings
# B1-B3, W4-W7). Reference cases and expected values come from the review and
# the brief, not from the implementation; each block names its derivation.

# ------------------------------------------ TSEC1: batch names and --hold (B1) --
# Derivation: herdr's agent name rule (a-z, then a-z0-9_-, at most 32) applies to
# every pane/run creator; --hold is a number of seconds. A name like
# '$(touch X)' or 'a"b' and a hold like '0; touch Y' must be rejected with exit 2
# BEFORE anything is written (no log root, no wrapper), and no marker file may
# appear. Values that are valid but contain shell syntax (here: the log root
# path) must land in the wrapper literally — a marker Z must not appear.
# The fake setsid runs the wrapper synchronously in $TSEC_DIR (without -il), so
# an injection would leave its marker file there; it also keeps the wrapper.
if should_run TSEC1 target; then
  d="$WORK/tsec1"; mkdir -p "$d/rt" "$WORK/tsec-bin"
  cat > "$WORK/tsec-bin/setsid" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$3" > "$TSEC_DIR/wrapper.txt"
cd "$TSEC_DIR" || exit 1
exec bash -c "$3"
STUB
  chmod +x "$WORK/tsec-bin/setsid"
  root="$d/rt/herd-$(id -u)"
  # wait_for <path> — up to ~3 s for the background wrapper.
  wait_for() { local i; for ((i=0; i<150; i++)); do [ -e "$1" ] && return 0; /bin/sleep 0.02; done; return 1; }
  tsec1_run() {
    TSEC_DIR="$d" XDG_RUNTIME_DIR="$d/rt" PATH="$WORK/tsec-bin:$PATH" HERD_CONFIG="$WORK/no-config" \
      run_herd "$@"
  }
  fixture_dir "tsec1"
  printf 'herdr: Permission denied\n' > "$FAKE_HERDR_DIR/.pane-list-error"   # -> setsid path

  tsec1_run exec codex --name '$(touch X)' --no-wait --hold 0 hello
  /bin/sleep 0.3
  r1="$RC|$([ -e "$d/X" ] && echo X || echo noX)|$([ -e "$root" ] && echo root || echo noroot)"
  tsec1_run run --name 'a"b' --no-wait --hold 0 -- true
  r2="$RC|$([ -e "$root" ] && echo root || echo noroot)"
  tsec1_run run --name tsec-hold --hold '0; touch Y' --no-wait -- true
  /bin/sleep 0.3
  r3="$RC|$([ -e "$d/Y" ] && echo Y || echo noY)|$([ -e "$root" ] && echo root || echo noroot)"
  tsec1_run exec codex --name tsec-hold --hold '0; touch Y' --no-wait hello
  r4="$RC|$([ -e "$d/Y" ] && echo Y || echo noY)"
  tsec1_run run --name tsec-to --timeout 'a[$(touch T)]' --no-wait -- true
  r5="$RC|$([ -e "$d/T" ] && echo T || echo noT)"
  check TSEC1a target 'exec/run: unsafe name, hold or timeout -> exit 2, nothing written, no marker' \
        '2|noX|noroot/2|noroot/2|noY|noroot/2|noY/2|noT' "$r1/$r2/$r3/$r4/$r5"

  # Valid name + --hold 5 works as before: wrapper runs, done marker 0, log
  # contains the command output, wrapper ends with the hold pause.
  rm -f "$d/wrapper.txt"
  tsec1_run run --name tsec-ok --hold 5 --no-wait -- printf 'ran-ok'
  rc_ok="$RC"
  done_f=""; for ((i=0; i<150; i++)); do
    done_f="$(ls -d "$root"/*-tsec-ok.*/done 2>/dev/null | head -1)"; [ -n "$done_f" ] && break; /bin/sleep 0.02
  done
  wait_for "$d/wrapper.txt" || true
  ok_ec="$(cat "$done_f" 2>/dev/null || echo missing)"
  ok_log=no; grep -q 'ran-ok' "${done_f%/done}/log.txt" 2>/dev/null && ok_log=yes
  ok_hold=no; case "$(cat "$d/wrapper.txt" 2>/dev/null)" in *'; sleep 5') ok_hold=yes ;; esac
  check TSEC1b target 'run with a valid name and --hold 5: runs as before' \
        '0|0|yes|yes' "$rc_ok|$ok_ec|$ok_log|$ok_hold"

  # Shell syntax in a VALID value (the log root path) stays literal.
  d2="$WORK/tsec1z"; mkdir -p "$d2/rt\$(touch Z)"
  TSEC_DIR="$d2" XDG_RUNTIME_DIR="$d2/rt\$(touch Z)" PATH="$WORK/tsec-bin:$PATH" HERD_CONFIG="$WORK/no-config" \
    run_herd run --name tsec-z --hold 0 --no-wait -- true
  rc_z="$RC"
  zdone=""; for ((i=0; i<150; i++)); do
    zdone="$(ls -d "$d2/rt\$(touch Z)/herd-$(id -u)"/*-tsec-z.*/done 2>/dev/null | head -1)"; [ -n "$zdone" ] && break; /bin/sleep 0.02
  done
  check TSEC1c target 'wrapper quotes the log path: no command substitution from it' \
        '0|done|noZ' "$rc_z|$([ -n "$zdone" ] && echo done || echo nodone)|$([ -e "$d2/Z" ] && echo Z || echo noZ)"

  # term creates a pane too: same name rule, exit 2 before the split.
  fixture_dir "tsec1-term"
  run_herd term --name 'a b'
  split=no; side_log | grep -q pane-split && split=yes
  check TSEC1d target 'term: invalid name -> exit 2 before the split' '2|no' "$RC|$split"
fi

# -------------------------------------------- TSEC2: .herd cleanup (B2) -------
# Derivation: cleanup may only delete inside <project>/.herd and never through
# a symlink. (a) .herd -> directory outside, old file inside -> file survives,
# note on stderr. (b) real .herd/ with an old symlink entry pointing to an old
# file outside -> the link is removed, the target survives.
if should_run TSEC2 target; then
  d="$WORK/tsec2"
  out="$(run_herd_fn '
    d="'"$d"'"
    mkdir -p "$d/p1" "$d/outside" "$d/p2/.herd" "$d/outside2"
    printf keep > "$d/outside/important.txt"; touch -d "20 days ago" "$d/outside/important.txt" "$d/outside"
    ln -s "$d/outside" "$d/p1/.herd"
    prune_herd_workdirs "$d/p1" 14 2>"$d/err1"
    echo "a: $([ -e "$d/outside/important.txt" ] && echo kept || echo deleted)"
    grep -q "symlink" "$d/err1" && echo "a-note: yes" || echo "a-note: no"
    printf keep > "$d/outside2/old.txt"; touch -d "20 days ago" "$d/outside2/old.txt"
    ln -s "$d/outside2/old.txt" "$d/p2/.herd/link"; touch -h -d "20 days ago" "$d/p2/.herd/link"
    prune_herd_workdirs "$d/p2" 14 2>/dev/null
    echo "b: link=$([ -L "$d/p2/.herd/link" ] && echo kept || echo removed) target=$([ -e "$d/outside2/old.txt" ] && echo kept || echo deleted)"
  ')"
  check TSEC2 target 'cleanup: symlinked .herd untouched with a note; symlink entry removed as a link only' \
        "a: kept
a-note: yes
b: link=removed target=kept" "$out"
fi

# ------------------------------------------ TSEC3: private log root (B3) ------
# Derivation: the run root <XDG_RUNTIME_DIR>/herd-<uid> must be a real
# directory owned by the user. (a) pre-created as a symlink -> abort with a
# message, nothing written into the link target. (b) a regular file in its
# place -> abort. (c) fresh root -> mode 0700 (umask 022 must not widen it),
# run directory 0700 as well. A root owned by ANOTHER user needs root
# privileges to set up and is not tested here (same check: test -O).
if should_run TSEC3 target; then
  d="$WORK/tsec3"; mkdir -p "$d/rt-link" "$d/rt-file" "$d/rt-fresh" "$d/target"
  ln -s "$d/target" "$d/rt-link/herd-$(id -u)"
  : > "$d/rt-file/herd-$(id -u)"
  mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
  fixture_dir "tsec3"
  fixture t idle
  printf 'p:t\n' > "$FAKE_HERDR_DIR/split.pane"
  XDG_RUNTIME_DIR="$d/rt-link" HERD_CONFIG="$WORK/no-config" run_herd run --name tsec-l --no-wait -- true
  msg=no; case "$ERR" in *"log root"*"symlink"*) msg=yes ;; esac
  ra="$RC|$msg|$(ls -A "$d/target" | wc -l | tr -d ' ')"
  XDG_RUNTIME_DIR="$d/rt-file" HERD_CONFIG="$WORK/no-config" run_herd run --name tsec-f --no-wait -- true
  rb="$RC"
  (umask 022; XDG_RUNTIME_DIR="$d/rt-fresh" HERD_CONFIG="$WORK/no-config" run_herd run --name tsec-n --no-wait -- true
   echo "$RC" > "$d/rc-fresh")
  froot="$d/rt-fresh/herd-$(id -u)"
  frun="$(ls -d "$froot"/*-tsec-n.* 2>/dev/null | head -1)"
  rc_="$(cat "$d/rc-fresh")|$(mode_of "$froot")|$(mode_of "$frun")"
  check TSEC3 target 'log root: symlink/file -> abort, nothing written; fresh root and run dir 0700' \
        '1|yes|0/1/0|700|700' "$ra/$rb/$rc_"
fi

# ------------------------------------------ TSEC4: question marker (W4) -------
# Derivation: a QUESTION marker counts only for a regular file that is not a
# symlink — a marker on a link to a foreign file must not make the orchestrator
# read or move that file. Positive control: the same marker on the real file.
if should_run TSEC4 target; then
  fixture_dir "tsec4"
  fixture a idle
  qdir="$WORK/tsec4/questions"; mkdir -p "$qdir"; : > "$qdir/real.md"
  ln -s "$qdir/real.md" "$qdir/link.md"
  pane_text a "report done"$'\n'"QUESTION: $qdir/link.md"
  run_herd classify-pane p:a; cl="$OUT|$RC"
  run_herd status a; sl="$OUT|$RC"
  pane_text a "report done"$'\n'"QUESTION: $qdir/real.md"
  run_herd classify-pane p:a; cr="$OUT|$RC"
  check TSEC4 target 'question marker on a symlink -> no question; on the real file -> question' \
        'clean|0/idle|0/question|0' "$cl/$sl/$cr"
fi

# ------------------------------------------ TSEC5: HERD_AUTO_TRUST (W5) -------
# Derivation: trusting a project folder loads its configuration, skills and
# hooks — opt-in. Default (unset/0): codex without the projects= override, the
# grok trust file unchanged, muse without --trust-workspace, pi --no-approve
# (an explicit HERD_PI_PROJECT_TRUST wins). HERD_AUTO_TRUST=1: previous
# behavior. Any other value: exit 2.
if should_run TSEC5 target; then
  fixture_dir "tsec5"
  echo "codex,grok,muse,pi" > "$FAKE_HERDR_DIR/kinds"
  d="$WORK/tsec5"; repo="$d/repo"; mkdir -p "$d/home"; git init -q "$repo"
  tf="$d/home/.grok/trusted_folders.toml"
  sum() { cksum "$tf" 2>/dev/null || echo missing; }
  # Default
  run_start -- codex --name t --cwd "$repo"
  c0=no; [ "$RC" = 0 ] && c0=yes; case "$OUT" in *"projects="*) c0=no ;; esac
  before="$(sum)"
  run_start HOME="$d/home" -- grok --name t --cwd "$repo"
  g0=no; [ "$(sum)" = "$before" ] && g0=yes
  gnote=no; case "$ERR" in *"HERD_AUTO_TRUST"*) gnote=yes ;; esac
  run_exec HOME="$d/home" -- grok --cwd "$repo" "hello"
  ge0=no; [ "$(sum)" = "$before" ] && ! has_args "--trust-workspace" && ge0=yes
  run_start -- muse --name t --cwd "$repo"
  m0=no; [ "$RC" = 0 ] && m0=yes; has_args "--trust-workspace" && m0=no
  run_exec muse --cwd "$repo" "hello"
  me0=no; [ "$RC" = 0 ] && me0=yes; has_args "--trust-workspace" && me0=no
  run_start -- pi --name t --model a/b
  p0=no; if has_args "--no-approve" && ! has_args "--approve"; then p0=yes; fi
  run_exec pi --cwd "$repo" --model a/b "hello"
  pe0=no; if has_args "--no-approve" && ! has_args "--approve"; then pe0=yes; fi
  run_start HERD_PI_PROJECT_TRUST=approve -- pi --name t --model a/b
  px=no; has_args "--approve" && px=yes
  check TSEC5a target 'HERD_AUTO_TRUST default: no codex/grok/muse trust, pi --no-approve, explicit pi value wins' \
        'yes|yes|yes|yes|yes|yes|yes|yes|yes' "$c0|$g0|$gnote|$ge0|$m0|$me0|$p0|$pe0|$px"
  # Opt-in
  top="$(git -C "$repo" rev-parse --show-toplevel)"
  run_start HERD_AUTO_TRUST=1 -- codex --name t --cwd "$repo"
  c1=no; has_args "projects={\"$top\"={trust_level=\"trusted\"}}" && c1=yes
  run_start HERD_AUTO_TRUST=1 HOME="$d/home" -- grok --name t --cwd "$repo"
  g1=no; grep -qF "[folders.\"$top\"]" "$tf" 2>/dev/null && g1=yes
  run_start HERD_AUTO_TRUST=1 -- muse --name t --cwd "$repo"
  m1=no; has_args "--trust-workspace" && m1=yes
  run_start HERD_AUTO_TRUST=1 -- pi --name t --model a/b
  p1=no; has_args "--approve" && p1=yes
  run_start HERD_AUTO_TRUST=yes -- codex --name t --cwd "$repo"
  bad="$RC"; badmsg=no; case "$ERR" in *"HERD_AUTO_TRUST must be 0 or 1"*) badmsg=yes ;; esac
  check TSEC5b target 'HERD_AUTO_TRUST=1: previous trust behavior; invalid value -> exit 2' \
        'yes|yes|yes|yes|2|yes' "$c1|$g1|$m1|$p1|$bad|$badmsg"
fi

# -------------------------------------- TSEC6: codex --resume keeps the role (W6) --
# Derivation: `codex resume --help` (codex-cli 0.161.0) accepts -C, -s, -m and
# -c, so a resumed session gets the role's sandbox and the requested
# cwd/model/effort instead of silently keeping the old ones; the session id
# (or --last) stays the positional argument at the end.
if should_run TSEC6 target; then
  fixture_dir "tsec6"
  repo="$WORK/tsec6-repo"; git init -q "$repo"
  run_start -- codex --name t --cwd "$repo" --role research --resume abc-123
  want="$(printf 'codex\nresume\n-C\n%s\n-s\nread-only\nabc-123' "$repo")"
  r1=no; [ "$RC|$OUT" = "0|$want" ] && r1=yes
  run_start -- codex --name t --cwd "$repo" --role impl --model m1 --effort high --resume
  want="$(printf 'codex\nresume\n-C\n%s\n-s\nworkspace-write\n-m\nm1\n-c\nmodel_reasoning_effort="high"\n--last' "$repo")"
  r2=no; [ "$RC|$OUT" = "0|$want" ] && r2=yes
  check TSEC6 target 'start codex --resume: role sandbox, cwd, model and effort passed on' \
        'yes|yes' "$r1|$r2"
fi

# ------------------------------------------ TSEC7: grok trust file TOML (W7) --
# Derivation: grok's trust file must stay valid TOML. A path with a quote would
# need escaping in the table key — such a path is skipped without touching the
# file (as codex does); a normal path is appended, the file stays parseable and
# no temp file is left over (atomic temp + mv). The TOML parse needs Python
# >= 3.11 (tomllib); with an older python3 that part is skipped.
if should_run TSEC7 target; then
  fixture_dir "tsec7"
  d="$WORK/tsec7"; mkdir -p "$d/home/.grok" "$d/repo\"quote" "$d/plain"
  tf="$d/home/.grok/trusted_folders.toml"
  printf '[folders."/already/there"]\ntrusted = true\ndecided_at = 1\n' > "$tf"
  before="$(cksum "$tf")"
  run_start HERD_AUTO_TRUST=1 HOME="$d/home" -- grok --name t --cwd "$d/repo\"quote"
  q_same=no; [ "$(cksum "$tf")" = "$before" ] && q_same=yes
  q_note=no; case "$ERR" in *"trust entry skipped"*) q_note=yes ;; esac
  run_start HERD_AUTO_TRUST=1 HOME="$d/home" -- grok --name t --cwd "$d/plain"
  p_added=no; grep -qF "[folders.\"$d/plain\"]" "$tf" && grep -qF '[folders."/already/there"]' "$tf" && p_added=yes
  leftover="$(ls -A "$d/home/.grok" | grep -cv '^trusted_folders\.toml\(\.lock\)\{0,1\}$')"
  toml=skip
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    toml="$(python3 -c 'import sys, tomllib
try:
    tomllib.load(open(sys.argv[1], "rb")); print("valid")
except Exception as e:
    print("invalid: %s" % e)' "$tf")"
  else
    printf '  \033[33mSKIP\033[0m TSEC7 TOML parse (python3 < 3.11, no tomllib)\n'
    toml=valid
  fi
  check TSEC7 target 'grok trust: quote path skipped unchanged; normal path appended atomically; valid TOML' \
        'yes|yes|yes|0|valid' "$q_same|$q_note|$p_added|$leftover|$toml"
fi

# ------------------------------- TSEC8: .herd swapped during the cleanup (B2) --
# Derivation: the cleanup must stay bound to the checked directory. A parallel
# process that replaces <project>/.herd by a symlink to an outside directory
# must not get anything outside deleted. The swap is injected by a test-only
# hook (function shadowing find resp. cd in the run_herd_fn subshell), the
# production code is unchanged. (a) swap right after the check, at the first
# find: outside file kept; the original (moved) .herd is still cleaned.
# (b) swap right before `cd -P` into .herd: outside kept, note on stderr.
if should_run TSEC8 target; then
  d="$WORK/tsec8"
  out="$(run_herd_fn '
    d="'"$d"'"
    setup() { rm -rf "$d"; mkdir -p "$d/project/.herd" "$d/outside"
              printf keep > "$d/project/.herd/important.txt"; printf valuable > "$d/outside/important.txt"
              touch -d "20 days ago" "$d/project/.herd/important.txt" "$d/outside/important.txt"; }
    swap() { mv "$d/project/.herd" "$d/project/.herd.saved"; ln -s "$d/outside" "$d/project/.herd"; }
    setup; swapped=0
    find() { if [ "$swapped" = 0 ]; then swapped=1; swap; fi; command find "$@"; }
    prune_herd_workdirs "$d/project" 14 2>/dev/null
    unset -f find
    echo "a: outside=$([ -e "$d/outside/important.txt" ] && echo kept || echo DELETED) saved=$([ -e "$d/project/.herd.saved/important.txt" ] && echo kept || echo cleaned)"
    setup; swapped=0
    cd() { case "${!#}" in */.herd) if [ "$swapped" = 0 ]; then swapped=1; swap; fi ;; esac; builtin cd "$@"; }
    prune_herd_workdirs "$d/project" 14 2>"$d/err"
    unset -f cd
    echo "b: outside=$([ -e "$d/outside/important.txt" ] && echo kept || echo DELETED) note=$(grep -q "changed during" "$d/err" && echo yes || echo no)"
  ')"
  check TSEC8 target 'cleanup bound to the checked .herd: a swap to a symlink deletes nothing outside' \
        "a: outside=kept saved=cleaned
b: outside=kept note=yes" "$out"
fi

# --------------------------------- TSEC9: unregistered git common dir (B2) ----
# Derivation: a crafted `.git` file (gitdir: <foreign repo>/.git) makes git
# report the foreign repository as common dir, although the project is not in
# its `git worktree list`. The foreign .herd is no cleanup target; a real
# worktree stays one (T172d).
if should_run TSEC9 target; then
  d="$WORK/tsec9"
  out="$(run_herd_fn '
    d="'"$d"'"
    mkdir -p "$d/project" "$d/foreign/.herd"
    git init -q "$d/foreign"
    printf "gitdir: %s/foreign/.git\n" "$d" > "$d/project/.git"
    printf valuable > "$d/foreign/.herd/important.txt"; touch -d "20 days ago" "$d/foreign/.herd/important.txt"
    prune_herd_workdirs "$d/project" 14 2>/dev/null
    echo "foreign=$([ -e "$d/foreign/.herd/important.txt" ] && echo kept || echo DELETED)"
  ')"
  check TSEC9 target 'cleanup: foreign common dir from a crafted .git file is skipped' "foreign=kept" "$out"
fi

# --------------------------------------- TSEC10: failed age check (B2) --------
# Derivation: an entry may only be deleted after a SUCCESSFUL age check.
# (a) no find in PATH -> fresh and old entries stay. (b) traversal error: an old
# folder whose old subfolder is unreadable (it holds a fresh file) -> find fails
# -> the folder stays complete (its old file too). (b) is skipped as root
# (permissions do not apply).
if should_run TSEC10 target; then
  d="$WORK/tsec10"
  out="$(run_herd_fn '
    d="'"$d"'"
    mkdir -p "$d/a/.herd" "$d/bin"
    printf x > "$d/a/.herd/fresh.txt"; printf x > "$d/a/.herd/old.txt"; touch -d "20 days ago" "$d/a/.herd/old.txt"
    for t in git rm head; do ln -s "$(command -v "$t")" "$d/bin/$t"; done
    PATH="$d/bin" prune_herd_workdirs "$d/a" 14 2>/dev/null
    echo "a: fresh=$([ -e "$d/a/.herd/fresh.txt" ] && echo kept || echo DELETED) old=$([ -e "$d/a/.herd/old.txt" ] && echo kept || echo DELETED)"
    if [ "$(id -u)" = 0 ]; then echo "b: skipped"; exit 0; fi
    o="$d/b/.herd/olddir"; mkdir -p "$o/locked"
    printf x > "$o/locked/fresh.txt"; printf x > "$o/old.txt"
    touch -d "20 days ago" "$o/old.txt" "$o/locked" "$o"
    chmod 000 "$o/locked"
    prune_herd_workdirs "$d/b" 14 2>/dev/null
    chmod 700 "$o/locked" 2>/dev/null
    echo "b: old=$([ -e "$o/old.txt" ] && echo kept || echo DELETED) fresh=$([ -e "$o/locked/fresh.txt" ] && echo kept || echo DELETED)"
  ')"
  case "$out" in *"b: skipped"*) printf '  \033[33mSKIP\033[0m TSEC10 (b) traversal error (running as root)\n'; out="${out%%b: skipped*}b: old=kept fresh=kept" ;; esac
  check TSEC10 target 'cleanup: missing find or traversal error -> nothing deleted' \
        "a: fresh=kept old=kept
b: old=kept fresh=kept" "$out"
fi

# ------------------------------------------ TSEC11: grok without flock (W7) ---
# Derivation: copy + mv without a lock can lose a parallel update of grok's
# user-wide trust file; without flock the file must stay byte-identical, with
# a note on stderr. PATH holds every tool the write path needs, except flock.
if should_run TSEC11 target; then
  d="$WORK/tsec11"
  out="$(run_herd_fn '
    d="'"$d"'"
    mkdir -p "$d/home/.grok" "$d/bin" "$d/plain"
    printf "[folders.\"/x\"]\ntrusted = true\n" > "$d/home/.grok/trusted_folders.toml"
    before="$(cksum < "$d/home/.grok/trusted_folders.toml")"
    for t in grep mkdir mktemp cat date mv rm; do ln -s "$(command -v "$t")" "$d/bin/$t"; done
    HOME="$d/home" HERD_AUTO_TRUST=1 PATH="$d/bin" grok_trust_cwd "$d/plain" 2>"$d/err"
    echo "same=$([ "$(cksum < "$d/home/.grok/trusted_folders.toml")" = "$before" ] && echo yes || echo no) note=$(grep -q "flock not available" "$d/err" && echo yes || echo no)"
  ')"
  check TSEC11 target 'grok trust without flock: file byte-identical, note' "same=yes note=yes" "$out"
fi
