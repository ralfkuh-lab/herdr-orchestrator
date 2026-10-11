#!/usr/bin/env bash
# tests/lib.sh -- Shared test helpers, fixtures, runner and final summary
# for the test suite of scripts/herd.sh.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERD="$ROOT/scripts/herd.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Scaled test minute for wait/watch (HERD_EVENTS_MINUTE_SEC). On Windows
# (git-bash) every process start costs ~50-80 ms instead of ~5 ms; classify-pane
# needs ~0.7 s there and blows the 1 s minute together with the debounce (T135a,
# T141a, T159g, T161a; 2026-09-10). On msys therefore 3 s, otherwise 1 s; still
# overridable via the environment.
case "${OSTYPE:-}" in msys*|cygwin*) EV_MINUTE_DEFAULT=3 ;; *) EV_MINUTE_DEFAULT=1 ;; esac

# Platform-neutral start path: auto chose pane run on Windows instead of agent
# start, but the fakes expect agent start. Also applies to tests that call herd.sh
# directly instead of via run_herd; T172b sets run explicitly.
export HERD_START_VIA="${HERD_START_VIA:-agent}"
# Tests do not clean up the real log directories under herd-<uid>; prune_logdirs
# itself is checked by T172c against a test directory.
export HERD_LOG_KEEP_DAYS=0
# Likewise the project .herd/ (start runs in tests partly with cwd inside the
# repo); prune_herd_workdirs is checked by T172d.
export HERD_WORKDIR_KEEP_DAYS=0

pass=0; fail=0; skip=0
FAILED=()

parse_args() {
  PHASE="all"
  SELECT=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) PHASE="$2"; shift 2 ;;
      -*)      echo "unknown option: $1" >&2; exit 2 ;;
      *)       SELECT+=("$1"); shift ;;
    esac
  done

  echo "herd.sh tests — phase: $PHASE"
  echo
}

# fixture_dir <case> [further directories…] — case directory under WORK.
# Existing files are kept, as with the previous mkdir -p per case.
fixture_dir() {
  FAKE_HERDR_DIR="$WORK/$1"
  shift
  mkdir -p "$FAKE_HERDR_DIR" "$@"
}

# pane_after_files <name> <first read> <files…> — successive reads.
# Copy byte-exact; do not reset existing read counters.
pane_after_files() {
  local name="$1" read_num="$2" file
  shift 2
  for file in "$@"; do
    cp "$file" "$FAKE_HERDR_DIR/pane-after-${read_num}.$name" || return
    read_num=$((read_num + 1))
  done
}

# fixture <name> <status lines…>  — create a status sequence for an agent
fixture() {
  local name="$1"; shift
  printf '%s\n' "$@" > "$FAKE_HERDR_DIR/status.$name"
  rm -f "$FAKE_HERDR_DIR/.count.$name"
}

pane_text() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/pane.$1"; rm -f "$FAKE_HERDR_DIR/.rcount.$1"; }
pane_after() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/pane-after.$1"; rm -f "$FAKE_HERDR_DIR/.rcount.$1"; }
pane_ansi() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/pane-ansi.$1"; rm -f "$FAKE_HERDR_DIR/.rcount-ansi.$1"; }
pane_ansi_after() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/pane-ansi-after-$3.$1"; }
fixture_kind() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/kind.$1"; }
fixture_session() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/session.$1"; }

# workspace_id for a fixture agent (space isolation).
fixture_ws() { printf '%s\n' "$2" > "$FAKE_HERDR_DIR/ws.$1"; }

# Extra agent only in `agent list` (name collision: get returns status.*,
# list additionally contains this match in another space).
extra_agent() {
  printf '{"name":"%s","agent_status":"%s","pane_id":"%s","workspace_id":"%s"}\n' \
    "$1" "$2" "$3" "$4" >> "$FAKE_HERDR_DIR/extra.jsonl"
}

extra_pane() {
  printf '{"label":"%s","pane_id":"%s","workspace_id":"%s"}\n' \
    "$1" "$2" "$3" >> "$FAKE_HERDR_DIR/extra-panes.jsonl"
}

know_ws() { printf '%s\n' "$1" >> "$FAKE_HERDR_DIR/workspaces"; }

side_log() { [ -f "$FAKE_HERDR_DIR/.side" ] && cat "$FAKE_HERDR_DIR/.side" || true; }

# run_herd <args…> — herd.sh in the fake environment; sets OUT, ERR, RC.
# Hard upper bound with SIGKILL: a hanging watcher must not block the whole test
# run. KILL instead of TERM so that the abort code (137) is not confused with the
# regular timeout code 124 of wait/watch.
#
# wait/watch run only via the event path now (T90+/T135*/T161*).
# run_herd therefore sets NO engine default — status/list/send/start
# need no watch engine. The backend stubs from $STUB belong in PATH too
# whenever run_herd drives start/usage --probe (build_cli checks the binary
# with `command -v`; without the stubs the suite would depend on locally
# installed backend CLIs). T168-cli checks a missing CLI with its own PATH
# and does not use run_herd, so it stays effective.
run_herd() {
  if [ -n "${HERD_TEST_WS:-}" ] && [ "${HERD_TEST_UNKNOWN_WS:-}" != 1 ]; then
    printf '%s\n' "$HERD_TEST_WS" >> "$FAKE_HERDR_DIR/workspaces"
  fi
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_POLL_SEC="${HERD_POLL_SEC:-0.02}" HERD_RETRY_SEC=0.05 FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        HERD_ANSWER_VERIFY_SEC="${HERD_ANSWER_VERIFY_SEC:-}" \
        HERD_ANSWER_READ_TIMEOUT="${HERD_ANSWER_READ_TIMEOUT:-2}" \
        HERD_USAGE_WAIT_SEC="${HERD_USAGE_WAIT_SEC:-0.1}" \
        HERD_USAGE_POLL_SEC="${HERD_USAGE_POLL_SEC:-0.02}" \
        ${HERD_TEST_WS:+HERDR_WORKSPACE_ID="$HERD_TEST_WS"} \
        ${HERD_TEST_TAB:+HERDR_TAB_ID="$HERD_TEST_TAB"} \
        ${HERD_TEST_PANE:+HERDR_PANE_ID="$HERD_TEST_PANE"} \
        "$HERD" "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  [ "$RC" = 137 ] && ERR="$ERR
[TESTRUNNER] call hung and was killed hard after 20 s."
  return 0
}

# run_herd_fn <bash-code> — loads herd.sh as a FUNCTION LIBRARY in an isolated
# subshell and runs <bash-code> with the real internals. The call with --help
# makes the dispatcher only print the usage (to /dev/null), no herdr/backend
# action. Intended for cases that cannot be driven deterministically over the CLI
# path with the fake — e.g. the agent_kind_of lookup in the empty-kind branch of
# normalize_status (T178h). Exported environment variables are visible in the
# code.
#
# `$0` of the subshell is the REAL herd.sh path: only that way herd.sh derives
# its SCRIPT_DIR (herd.sh: "cd $(dirname "$0")") correctly and EVENTS_PY points
# to scripts/herd_events.py. A `bash` as $0 would make SCRIPT_DIR point to the
# working directory — parser/event-dependent functions would be broken.
# A load error is NOT swallowed silently: it is reported on stderr (the caller
# sees it), code execution continues anyway.
run_herd_fn() {
  local err rc
  err="$(mktemp "${TMPDIR:-/tmp}/herd-fn-err.XXXXXX")"
  bash -c '
    herd="$1"; code="$2"; err="$3"
    set -- --help
    source "$herd" >/dev/null 2>"$err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf "[run_herd_fn] herd.sh not loadable (rc=%s):\n" "$rc" >&2
      cat "$err" >&2
    fi
    eval "$code"
  ' "$HERD" "$HERD" "$1" "$err"
  rc=$?
  rm -f "$err"
  return $rc
}

# check <id> <kind char|target> <description> <expected> <actual>
check() {
  local id="$1" kind="$2" desc="$3" want="$4" got="$5"
  if [ "$want" = "$got" ]; then
    printf '  \033[32mPASS\033[0m %-5s %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %-5s %s\n' "$id" "$desc"
    printf '        expected: %s\n        got: %s\n' "$want" "$got"
    fail=$((fail + 1)); FAILED+=("$id")
  fi
}

should_run() {
  local id="$1" kind="$2"
  if [ ${#SELECT[@]} -gt 0 ]; then
    local s found=0
    for s in "${SELECT[@]}"; do [ "$s" = "$id" ] && found=1; done
    [ "$found" = 1 ] || return 1
  fi
  if [ "$PHASE" = before ] && [ "$kind" = target ]; then
    printf '  \033[33mSKIP\033[0m %-5s (target behavior, only after the rebuild)\n' "$id"
    skip=$((skip + 1)); return 1
  fi
  return 0
}

# ---------------------------------------------------- start / build_cli stubs --
STUB="$WORK/stubbin"; mkdir -p "$STUB" "$WORK/home"
for b in claude grok copilot codex agy pi; do   # muse: own fake in tests/bin/muse
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$b"; chmod +x "$STUB/$b"
done

# run_start [VAR=VALUE…] -- <backend> <start options…> — sets OUT, ERR, RC.
# HOME points to a throwaway directory (grok_trust_cwd writes to ~/.grok);
# HERD_CONFIG to a nonexistent file so that the developer machine's private
# config does not falsify the expectations.
run_start() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  if [ -n "${HERD_TEST_WS:-}" ] && [ "${HERD_TEST_UNKNOWN_WS:-}" != 1 ]; then
    printf '%s\n' "$HERD_TEST_WS" >> "$FAKE_HERDR_DIR/workspaces"
  fi
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL \
        -u HERD_PI_PROVIDER -u HERD_PI_PROJECT_TRUST -u MODEL_PI -u HERD_AUTO_TRUST \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HERD_PRINT_CLI=1 HOME="$WORK/home" \
        FAKE_HERDR_DIR="$FAKE_HERDR_DIR" \
        ${HERD_TEST_WS:+HERDR_WORKSPACE_ID="$HERD_TEST_WS"} \
        ${envs[@]+"${envs[@]}"} \
        "$HERD" start "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  return 0
}

# run_exec [VAR=VALUE…] -- <backend> <exec options…> — sets OUT, ERR, RC.
# Prefix mode only if the first argument contains an '=' (otherwise
# 'run_exec pi --cwd …' would no longer be callable).
run_exec() {
  local envs=()
  case "${1:-}" in
    *=*)
      while [ "$1" != "--" ]; do envs+=("$1"); shift; done
      shift ;;
  esac
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL \
        -u HERD_PI_PROVIDER -u HERD_PI_PROJECT_TRUST -u MODEL_PI -u HERD_AUTO_TRUST \
        PATH="$ROOT/tests/bin:$STUB:$PATH" HERDR_ENV=1 \
        HERD_CONFIG="$WORK/no-config" HERD_PRINT_CLI=1 HOME="$WORK/home" \
        FAKE_HERDR_DIR="${FAKE_HERDR_DIR:-$WORK}" \
        ${envs[@]+"${envs[@]}"} \
        "$HERD" exec "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  return 0
}

# has_args "<flag> <value>" — exact argument sequence in the built command? OUT has
# one argument per line; every space in the pattern stands for an argument
# boundary. Matches only whole arguments ("auto" does not hit "auto-evil") and
# not across accidentally adjacent substrings.
has_args() {
  local nl=$'\n'
  case "$nl$OUT$nl" in
    *"$nl${1// /$nl}$nl"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------- Event path (herd_events.py) ---
EVENTS_PY="$ROOT/scripts/herd_events.py"
FAKE_EVENTS="$ROOT/tests/bin/fake_events_server.py"

# Reusable fixture building blocks (name long JSON lines once).
# EV_GET_* = agent.get responses (snapshots), EV_* = event lines,
# EV_SUBS_* = the subscribe parameters logged by the server.
EV_A_GET='{"type":"agent_info","agent":{"name":"a","agent_status":"working","pane_id":"p:a","state_change_seq":3}}'
EV_GET_A_SEQ9='{"type":"agent_info","agent":{"name":"a","agent_status":"idle","pane_id":"p:a","state_change_seq":9}}'
EV_GET_A_NEW_PANE='{"type":"agent_info","agent":{"name":"a","agent_status":"working","pane_id":"p:a2","state_change_seq":4}}'
EV_A_WORKING='{"event":"pane.agent_status_changed","data":{"pane_id":"p:a","workspace_id":"w","agent_status":"working"}}'
EV_A_IDLE='{"event":"pane.agent_status_changed","data":{"pane_id":"p:a","workspace_id":"w","agent_status":"idle"}}'
EV_A_BLOCKED='{"event":"pane.agent_status_changed","data":{"pane_id":"p:a","workspace_id":"w","agent_status":"blocked"}}'
EV_A_UNKNOWN='{"event":"pane.agent_status_changed","data":{"pane_id":"p:a","workspace_id":"w","agent_status":"unknown"}}'
EV_A2_IDLE='{"event":"pane.agent_status_changed","data":{"pane_id":"p:a2","workspace_id":"w","agent_status":"idle"}}'
EV_FOREIGN='{"event":"pane.agent_status_changed","data":{"pane_id":"p:foreign","workspace_id":"w","agent_status":"idle"}}'
EV_SUBS_A='{"subscriptions":[{"pane_id":"p:a","type":"pane.agent_status_changed"},{"type":"pane.closed"},{"type":"pane.exited"}]}'
EV_SUBS_A2='{"subscriptions":[{"pane_id":"p:a2","type":"pane.agent_status_changed"},{"type":"pane.closed"},{"type":"pane.exited"}]}'

# Additional fixture building blocks for the watch path (also used by t-wait.sh).
EV_GET_A_IDLE='{"type":"agent_info","agent":{"name":"a","agent_status":"idle","pane_id":"p:a","state_change_seq":5}}'
EV_B_GET='{"type":"agent_info","agent":{"name":"b","agent_status":"working","pane_id":"p:b","state_change_seq":2}}'
EV_B_IDLE='{"event":"pane.agent_status_changed","data":{"pane_id":"p:b","workspace_id":"w","agent_status":"idle"}}'
EV_GET_A_BLOCKED='{"type":"agent_info","agent":{"name":"a","agent_status":"blocked","pane_id":"p:a","state_change_seq":7}}'
EV_A_CLOSED='{"event":"pane_closed","data":{"pane_id":"p:a"}}'
EV_SUBS_AB='{"subscriptions":[{"pane_id":"p:a","type":"pane.agent_status_changed"},{"pane_id":"p:b","type":"pane.agent_status_changed"},{"type":"pane.closed"},{"type":"pane.exited"}]}'

# ev_start <directory> — read the fixture from stdin, start the server on a FREE
# port (port 0 avoids collisions in the test run) and set EV_PORT/EV_LOG/EV_PID.
# The port comes from a file because it is only fixed at runtime.
ev_start() {
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/fixture"
  EV_LOG="$dir/log"; : > "$EV_LOG"
  rm -f "$dir/port"
  python3 "$FAKE_EVENTS" "$dir/fixture" --port-file "$dir/port" --log "$EV_LOG" \
      --exit-after 30 >/dev/null 2>&1 &
  EV_PID=$!
  local i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  EV_PORT="$(cat "$dir/port" 2>/dev/null || true)"
}

ev_stop() { kill "$EV_PID" 2>/dev/null || true; wait "$EV_PID" 2>/dev/null || true; }

# ev_wait_log <grep pattern> — wait for a log entry (max. ~2 s). The server
# logs the closing of a connection only when its read poll notices the departure;
# without this wait the check would be a race.
ev_wait_log() {
  local i=0
  while ! grep -q "$1" "$EV_LOG" 2>/dev/null && [ "$i" -lt 40 ]; do
    sleep 0.05; i=$((i + 1))
  done
}

# run_events <args…> — herd_events.py against the fake server; sets OUT, ERR, RC.
# The timing values stay small: these tests should hang on FIXTURES, not on
# clocks (the known Windows flakes T11/T22 are exactly this trap).
run_events() {
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        -u HERD_OWN_WORKSPACE \
        PYTHONUTF8=1 \
        HERD_EVENTS_ENDPOINT="tcp:127.0.0.1:$EV_PORT" \
        HERD_EVENTS_TICK_SEC=0.05 HERD_EVENTS_BACKOFF_SEC=0.05 \
        HERD_EVENTS_BACKOFF_MAX_SEC=0.2 HERD_EVENTS_RPC_TIMEOUT_SEC=5 \
        HERD_EVENTS_LIVENESS_SEC="${HERD_EVENTS_LIVENESS_SEC:-60}" \
        python3 "$EVENTS_PY" "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  [ "$RC" = 137 ] && ERR="$ERR
[TESTRUNNER] call hung and was killed hard after 20 s."
  return 0
}

# run_watch <args…> — herd_events.py watch with all test timeouts, fake server
# and the fake herdr in PATH. Sets OUT, ERR, RC.
# All clocks small and overridable via env: quiet window, remaining poll,
# command deadline/retry as well as the units of --stall-timeout
# (HERD_STALL_UNIT, as in herd_events.py) and --timeout (HERD_EVENTS_MINUTE_SEC).
# WATCH_KILL = hard upper bound of the call (SIGKILL, exit 137). Set small, it
# proves that the watcher keeps its own deadlines: if the main loop blocks, 137
# comes instead of the expected exit code.
run_watch() {
  OUT="$(timeout --signal=KILL "${WATCH_KILL:-20}" env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        -u HERD_OWN_WORKSPACE \
        PATH="$ROOT/tests/bin:$PATH" HERDR_ENV=1 \
        PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 \
        FAKE_HERDR_DIR="$FAKE_HERDR_DIR" HERD_CONFIG="$WORK/no-config" \
        HERD_SH="${HERD_SH:-$HERD}" \
        HERD_EVENTS_ENDPOINT="tcp:127.0.0.1:$EV_PORT" \
        HERD_EVENTS_TICK_SEC=0.05 HERD_EVENTS_BACKOFF_SEC=0.05 \
        HERD_EVENTS_BACKOFF_MAX_SEC=0.2 HERD_EVENTS_RPC_TIMEOUT_SEC=5 \
        HERD_EVENTS_LIVENESS_SEC="${HERD_EVENTS_LIVENESS_SEC:-60}" \
        HERD_EVENTS_DEBOUNCE_SEC="${HERD_EVENTS_DEBOUNCE_SEC:-0.2}" \
        HERD_EVENTS_VERIFY_SEC="${HERD_EVENTS_VERIFY_SEC-5}" \
        HERD_EVENTS_CMD_TIMEOUT_SEC="${HERD_EVENTS_CMD_TIMEOUT_SEC:-5}" \
        HERD_EVENTS_CMD_RETRY_SEC="${HERD_EVENTS_CMD_RETRY_SEC:-0.05}" \
        HERD_EVENTS_EXPLAIN_TIMEOUT_SEC="${HERD_EVENTS_EXPLAIN_TIMEOUT_SEC:-5}" \
        HERD_STALL_UNIT="${HERD_STALL_UNIT:-60}" \
        HERD_EVENTS_MINUTE_SEC="${HERD_EVENTS_MINUTE_SEC:-60}" \
        python3 "$EVENTS_PY" watch "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  [ "$RC" = 137 ] && ERR="$ERR
[TESTRUNNER] call hung and was killed hard after ${WATCH_KILL:-20} s."
  return 0
}

# watch_stub <file> <classify verdict> <explain shell code> — substitute herd.sh
# for the adapter tests (injected via HERD_SH). Only the three internal verbs; the
# real verbs are covered by T70/T71/T84.
# NOTE on wait times in the stub: tests/bin/sleep is a shim that shortens EVERY
# sleep to 0.02 s (so poll loops do not run in real time). Anyone needing real
# blocking here must call /bin/sleep directly.
watch_stub() {
  local file="$1" verdict="$2" explain="$3"
  cat > "$file" <<EOF
#!/bin/sh
case "\$1" in
  classify-pane)     echo $verdict ;;
  stall-fingerprint) echo "fp 1 1"; echo "limited no"; echo "failed no" ;;
  explain-status)    $explain ;;
esac
exit 0
EOF
  chmod +x "$file"
}

# run_dispatch <engine> <endpoint> <watch arguments…> — `herd.sh watch` with a
# fixed engine and event endpoint; sets OUT, ERR, RC. Both fakes are reachable at
# the same time (CLI in PATH, event server via HERD_EVENTS_ENDPOINT).
run_dispatch() {
  local engine="$1" endpoint="$2"; shift 2
  if [ -n "${HERD_TEST_WS:-}" ] && [ "${HERD_TEST_UNKNOWN_WS:-}" != 1 ]; then
    printf '%s\n' "$HERD_TEST_WS" >> "$FAKE_HERDR_DIR/workspaces"
  fi
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$PATH" HERDR_ENV=1 \
        PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 \
        FAKE_HERDR_DIR="$FAKE_HERDR_DIR" HERD_CONFIG="$WORK/no-config" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 \
        ${HERD_TEST_WS:+HERDR_WORKSPACE_ID="$HERD_TEST_WS"} \
        HERD_WATCH_ENGINE="$engine" HERD_EVENTS_ENDPOINT="$endpoint" \
        HERD_EVENTS_TICK_SEC=0.05 HERD_EVENTS_BACKOFF_SEC=0.05 \
        HERD_EVENTS_BACKOFF_MAX_SEC=0.2 HERD_EVENTS_RPC_TIMEOUT_SEC=5 \
        HERD_EVENTS_DEBOUNCE_SEC=0.2 HERD_EVENTS_VERIFY_SEC=5 \
        HERD_EVENTS_CMD_TIMEOUT_SEC=5 HERD_EVENTS_CMD_RETRY_SEC=0.05 \
        HERD_EVENTS_EXPLAIN_TIMEOUT_SEC=5 HERD_EVENTS_MINUTE_SEC="${HERD_EVENTS_MINUTE_SEC:-$EV_MINUTE_DEFAULT}" \
        "$HERD" watch "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  [ "$RC" = 137 ] && ERR="$ERR
[TESTRUNNER] call hung and was killed hard after 20 s."
  return 0
}

# dispatch_fixtures <directory> — set up both fakes for the engine tests:
# CLI fake says 'blocked', event server says 'idle' on a clean pane.
# The event server also needs a ping response: the feature detection
# (herd_events.py probe) checks reachability AND events.subscribe.
dispatch_fixtures() {
  FAKE_HERDR_DIR="$1"; mkdir -p "$FAKE_HERDR_DIR"
  fixture a blocked
  pane_text a "plain normal output"
  ev_start "$1-ev" <<EOF
reply ping {"type":"pong","version":"fake","protocol":17}
reply agent.get $EV_A_GET
reply events.subscribe {"type":"subscription_started"}
stream
emit $EV_A_IDLE
hold
EOF
}

run_dispatch_wait() {
  local engine="$1" endpoint="$2"; shift 2
  if [ -n "${HERD_TEST_WS:-}" ] && [ "${HERD_TEST_UNKNOWN_WS:-}" != 1 ]; then
    printf '%s\n' "$HERD_TEST_WS" >> "$FAKE_HERDR_DIR/workspaces"
  fi
  OUT="$(timeout --signal=KILL 20 env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
        PATH="$ROOT/tests/bin:$PATH" HERDR_ENV=1 \
        PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 \
        FAKE_HERDR_DIR="$FAKE_HERDR_DIR" HERD_CONFIG="$WORK/no-config" \
        HERD_POLL_SEC=0.02 HERD_RETRY_SEC=0.05 \
        ${HERD_TEST_WS:+HERDR_WORKSPACE_ID="$HERD_TEST_WS"} \
        HERD_WATCH_ENGINE="$engine" HERD_EVENTS_ENDPOINT="$endpoint" \
        HERD_EVENTS_TICK_SEC=0.05 HERD_EVENTS_BACKOFF_SEC=0.05 \
        HERD_EVENTS_BACKOFF_MAX_SEC=0.2 HERD_EVENTS_RPC_TIMEOUT_SEC=5 \
        HERD_EVENTS_DEBOUNCE_SEC="${HERD_EVENTS_DEBOUNCE_SEC:-0.2}" \
        HERD_EVENTS_VERIFY_SEC="${HERD_EVENTS_VERIFY_SEC:-5}" \
        HERD_EVENTS_CMD_TIMEOUT_SEC=5 HERD_EVENTS_CMD_RETRY_SEC=0.05 \
        HERD_EVENTS_EXPLAIN_TIMEOUT_SEC=5 \
        HERD_STALL_UNIT="${HERD_STALL_UNIT:-60}" \
        HERD_EVENTS_MINUTE_SEC="${HERD_EVENTS_MINUTE_SEC:-$EV_MINUTE_DEFAULT}" \
        "$HERD" wait "$@" 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  [ "$RC" = 137 ] && ERR="$ERR
[TESTRUNNER] call hung and was killed hard after 20 s."
  return 0
}

check_dlg() {
  local id="$1" desc="$2" text="$3" want_c="${4:-blocked}" want_s="${5:-blocked}" kind="${6:-}"
  pane_text a "$text"
  [ -n "$kind" ] && fixture_kind a "$kind" || rm -f "$FAKE_HERDR_DIR/kind.a"
  run_herd classify-pane p:a; local c="$OUT|$RC"
  run_herd status a; local s="$OUT|$RC"
  check "$id" target "$desc" \
        "$want_c|0/$want_s|0" "$c/$s"
}

usage_fixture() {
  local name="$1" kind="$2" fix_file="$3" start_read="${4:-3}"
  fixture "$name" idle
  fixture_kind "$name" "$kind"
  case "$kind" in
    codex)
      pane_text "$name" "› Ask Codex to do anything"$'\n'"  gpt-5.6-sol high · ~/dev/herdr-orchestrator"
      ;;
    grok)
      pane_text "$name" "Grok CLI ready."$'\n'"Type your message or /help"
      ;;
    agy)
      pane_text "$name" "Gemini CLI ready."$'\n'">"
      ;;
    claude)
      pane_text "$name" "Claude Code"$'\n'"> Type a message..."
      ;;
    muse)
      pane_text "$name" "Muse Code 1.0.2"$'\n'"⟩"
      ;;
    *)
      pane_text "$name" "Agent ready."
      ;;
  esac
  pane_after_files "$name" "$start_read" "$fix_file"
}

# check_python_tests <id> <file pattern> <minimum> <description>
# An empty discovery does not count as a successful parser test run.
check_python_tests() {
  local id="$1" pattern="$2" minimum="$3" description="$4"
  local direct_out direct_rc direct_ran direct_found=no
  direct_out="$(cd "$ROOT" && PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 \
    timeout --signal=KILL 60 python3 -m unittest discover -s tests -p "$pattern" 2>&1)"
  direct_rc=$?
  direct_ran="$(printf '%s\n' "$direct_out" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p')"
  [ "${direct_ran:-0}" -ge "$minimum" ] && direct_found=yes
  check "$id" target "$description" '0|yes' "$direct_rc|$direct_found"
  if [ "$direct_rc" != 0 ]; then printf '%s\n' "$direct_out"; fi
}

print_summary() {
  echo
  printf 'PASS %d · FAIL %d · SKIP %d\n' "$pass" "$fail" "$skip"
  [ "$fail" -eq 0 ] || printf 'failed: %s\n' "${FAILED[*]}"
  [ "$fail" -eq 0 ]
}
