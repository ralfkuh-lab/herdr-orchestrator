#!/usr/bin/env bash
# herd.sh — orchestrate a herdr workspace: delegate coding agents AND
# control terminals/SSH sessions in visible panes.
#
# Core idea: the orchestrator runs sub-agents and terminals as
# INTERACTIVE live sessions in herdr panes remotely (send/wait/read/key) — full
# access including slash commands. The batch one-shot (`exec`) stays a deliberate
# fire-and-forget exception. Without herdr only `exec`/`run` work (setsid fallback).
#
# Backends: codex | agy | opencode | claude | copilot | grok | kimi | muse | pi
# Config (optional, private): ~/.config/herdr-orchestrator/config — BACKENDS=…
#   (allowlist of permitted backends), MODEL_<BACKEND>=… (default model),
#   HERD_IMPL_PERMISSION_MODE=… (claude/grok: permission mode for --role impl,
#   default acceptEdits).
#   Without the file: all installed backends, no default models.
#
# Terminal/pane control (not only agents):
#   herd.sh term   --name N [--cwd DIR] [--shell CMD] [--split down|right]
#                                            # open an empty terminal pane
#   herd.sh type   <name> <text...>          # type a command WITHOUT Enter
#                                            # (you run it / enter the sudo password)
#
# Interactive (default):
#   herd.sh start  <backend> --name N [--role impl|research] [--cwd DIR]
#                      # claude additionally: --role orchestrator (without
#                      # sub-agent lock, for a successor session)
#                      [--model M] [--effort E] [--split down|right] [--tab ID]
#                      [--max-per-tab N] [--resume [ID]] [--timeout MIN]
#                      [--permission-mode M]   # only claude|grok|agy|muse|copilot
#                      # copilot additionally: --yolo (approve everything),
#                      # --context default|long_context (default if omitted —
#                      # long context only on explicit request, it costs
#                      # double rate from 272k input), --auto-tier P
#                      # (only with --model auto), --max-ai-credits N (min. 30)
#                      # automatically opens a new tab as soon as the current
#                      # one has >= N panes (default 4, HERD_MAX_PER_TAB)
#   herd.sh send   <name> <text...>      # prompt (or /slash-command) + Enter
#   herd.sh send   <name> --file PATH    # prompt from a file (quoting-safe)
#   herd.sh status <name>                # immediate state without blocking:
#                      # working|idle|done|blocked|limited|auth|failed|question
#                      # (auth = login/OAuth screen, e.g. agy session
#                      # expired; failed = backend/model error, prompt
#                      # NOT processed → send again; question = the agent
#                      # wrote a question file, see SKILL.md
#                      # "Agent questions")
#   herd.sh wait   <name> [--status idle|blocked|done|…] [--timeout MIN]
#                      [--stall-timeout MIN]
#                      # ONE event, then end. Prints the return state:
#                      # idle|done|blocked|limited|auth|failed|question|background|
#                      # stalled|lost
#                      # (limited = usage/rate limit, prompt NOT processed
#                      # → switch backend/wait for the reset; failed = backend/
#                      # model error, prompt NOT processed → send the same
#                      # prompt again, on repetition switch backend;
#                      # stalled = status working, but no visible progress
#                      # for N min; lost = the agent was there and is
#                      # gone; background = claude ended the turn, but
#                      # background shells/monitors still run since
#                      # HERD_EVENTS_BG_MAX_SEC (180 s) → read the pane.
#                      # --stall-timeout default 15 min, 0 = off)
#                      # Exit: 0 event · 124 TIMEOUT (still running!) ·
#                      #       1 agent unknown · 2 usage error
#   herd.sh watch  <name…> [--stall-timeout MIN] [--timeout MIN] [--poll SEC]
#                      [--max-events N]
#                      # PERMANENT observation of several agents. Writes one
#                      # line "<name> <status>" per event and keeps RUNNING —
#                      # unlike wait, which ends after the first event and
#                      # leaves all other agents behind blindly. Meant as a
#                      # monitor command: every line is a notification.
#                      # Ends when all agents are done/gone.
#                      # Takes its states from the herdr EVENT STREAM
#                      # (scripts/herd_events.py). Without the event API: Exit 2
#                      # (herdr >= 0.8.2 and python3 are required).
#                      # HERD_WATCH_ENGINE=auto|events (identical, event path);
#                      # poll was removed on 2026-09-09 (stage 4) -> Exit 2.
#   herd.sh list [--all-spaces] [--sessions]  # inventory: <name> <status> <pane>
#                      # own space only; --all-spaces = all + space column
#                      # --sessions = session ID as an extra column (`-` if
#                      # none reported; with --all-spaces the last column after
#                      # the space column)
#                      # the restart source after context compaction
#   herd.sh read   <name> [--lines N] [--source visible|recent|recent-unwrapped]
#   herd.sh key    <name> <enter|esc|up|down|…>   # answer approval dialogs
#   herd.sh stop   <name>                # close pane (in-session reset: send N "/clear")
#                      # reports the backend session ID (with herdr
#                      # integration) including a copyable resume command:
#                      # start <backend> --name N --resume ID; without an ID only
#                      # the note about resume as the last session (without a kind
#                      # not even a second line); if `agent get` fails, only the
#                      # close message - `stop` never fails on that
#   herd.sh usage  <name...>             # query usage limits of all backends
#                      # (scrolls through the agy scroller with down if needed)
#                      # --probe [backends] = throwaway sessions per backend
#                      #                      (shows the raw block on a parse error)
#                      # --raw <name> = print only the raw pane block
#                      # --log codex = read limits from the codex session logs
#                      #               (without herdr/TUI, even with an open
#                      #               start dialog; as fresh as the last turn)
#
# INTERNAL (for the event watcher scripts/herd_events.py, NOT a public
# contract — output and names may change together with the watcher; deliberately
# not in the usage output so it is not read as an interface). They keep
# pattern lists and message texts in ONE place, while
# the observation runs in Python:
#   herd.sh classify-pane <pane_id> [--kind KIND]
#                      # one line: blocked|limited|auth|failed|busy|background|
#                      # question|clean (background = claude turn ended, only
#                      # background shells/monitors left; otherwise like busy)
#                      # — exactly the idle/done order from normalize_status
#                      # (looks_blocked > looks_limited > looks_auth >
#                      # looks_failed > looks_busy_kind > looks_question). --kind saves
#                      # the kind RPC when the caller already knows it. Exit 1 =
#                      # pane not readable (NOT clean!), Exit 2 = usage error.
#   herd.sh stall-fingerprint <pane_id>
#                      # three lines: "fp <hash>" (normalized fingerprint,
#                      # see stall_fingerprint), "limited yes|no" (backends
#                      # with self-retry stay working at the usage limit)
#                      # and "failed yes|no" (backend/model error with raw-
#                      # working, analogous to limited). Exit 1 = pane not readable,
#                      # Exit 2 = usage error.
#   herd.sh explain-status <name> <status>
#                      # action instruction for the state on stderr
#                      # (explain_status — verbatim with wait/watch).
#
# Batch / fire-and-forget:
#   herd.sh exec   <codex|opencode|copilot|grok|kimi|muse|pi> [--model M] [--effort E] [--agent A]
#                      [--cwd DIR] [--spec FILE] [--name N] [--timeout MIN]
#                      [--no-wait] [--hold SEC] [PROMPT...]
#                      # copilot additionally: --context, --auto-tier,
#                      # --max-ai-credits (as with start); the consumption lands
#                      # as usage.json in the log directory of the run
#   herd.sh run    [--cwd DIR] [--name N] [--timeout MIN] [--no-wait]
#                      [--hold SEC] -- CMD [ARGS...]
#
# Logs/artifacts: <XDG_RUNTIME_DIR|TMPDIR|/tmp>/herd-<uid>/<timestamp>-<name>.<random>/
#   (private, mode 0700) — start/exec/run delete
# folders older than HERD_LOG_KEEP_DAYS (default 7, 0 = never), and
# in the project .herd/ entries unchanged since HERD_WORKDIR_KEEP_DAYS
# (default 14, 0 = never; `questions/` stays).
set -eu

# Ensure a UTF-8 CType. git-bash/MSYS often starts with an empty LANG; GNU grep
# then matches multibyte bracket expressions BYTEWISE. Byte 0xE2 is the first
# byte of *all* U+2xxx characters — multibyte patterns then match wildly off.
# Discovered 2026-07-24 on Windows via the (since removed) Braille spinner
# class of the looks_busy heuristic; kept as protection for future
# multibyte patterns (and sed/grep text processing in general).
# `locale charmap` wrongly reports UTF-8 here, so it is no usable guard;
# so test functionally: if a box-drawing character (0xE2 0x94 0x80) matches the
# Braille class, the CType is broken → force C.UTF-8 (MSYS supports it).
# On Linux/macOS the probe fails (UTF-8 default) → no change.
if [ -z "${LC_ALL:-}" ] && printf '\xe2\x94\x80' | grep -qE '[⣿]' 2>/dev/null; then
  export LC_ALL=C.UTF-8
fi

# Python in UTF-8 mode. Native Windows python3 otherwise decodes stdin/stdout
# with the ANSI codepage (cp1252), ignoring POSIX LC_ALL/LANG. Multibyte
# selection markers (›/❯/▶) then fall apart on read, and the answer parser
# discards exactly the MARKED option lines → wrongly counted cursor position,
# at worst the wrong option in an approval dialog (Windows, 2026-07-24).
# PYTHONUTF8=1 forces UTF-8 for all python3 calls of the script; on Linux/macOS
# it is the default anyway (harmless).
export PYTHONUTF8=1

# Do NOT let MSYS rewrite text arguments with a leading slash (slash commands
# like /usage, /effort, terminal text like /bin/…) into Windows paths:
# git-bash converts arguments of native programs that look like POSIX paths —
# `/usage` becomes `C:/Program Files/Git/usage` in the pane (Windows,
# 2026-09-10). MSYS_NO_PATHCONV=1 only for THESE calls, not globally:
# `--cwd "$PWD"` in exec/run still needs the conversion.
# On Linux/macOS the variable has no effect.
herdr_text() { MSYS_NO_PATHCONV=1 herdr "$@"; }

# Remove old log folders from start/exec/run (2026-10-02): on Windows nobody
# empties the temp directory, the folders accumulated permanently.
# Only folders directly under $1 with the name pattern <YYYYMMDD>-<HHMMSS>-<name>
# whose name stamp is older than $2 days. 0 or invalid = off.
# Deliberately the name, not the modification time: the Windows temp cleanup
# empties old folders and sets their modification time to now in the process
# (observed 2026-10-02). Errors are ignored — cleanup must not prevent a start.
prune_logdirs() {
  local root="$1" days="${2:-7}" cutoff d base
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  days=$((10#$days))
  [ "$days" -gt 0 ] && [ -d "$root" ] || return 0
  # GNU date (Linux, MSYS), otherwise BSD date (macOS).
  cutoff="$(date -d "$days days ago" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -v-"$days"d +%Y%m%d-%H%M%S 2>/dev/null)" || return 0
  [ -n "$cutoff" ] || return 0
  for d in "$root"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    if [[ "${base:0:15}" < "$cutoff" ]]; then
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  return 0
}

# `.herd/` in the project (convention from SKILL.md §4 Writing a brief) is a
# throwaway working directory for specs, prompts, diffs and reports. Deleted are
# top-level entries that have not changed for $2 days (folders by their most
# recent file); `questions/` stays. The reason is less the space than the
# full-text search (grep), which would otherwise find old drafts.
# Affected are .herd/ in $1, in the repo root and in the main checkout (agents
# often run in a worktree, but .herd/ lives in the project). Age by
# mtime — unlike /tmp no temp cleanup touches project folders.
# Never follows symlinks (security reviews 2026-10-11): a repository can ship
# `.herd` as a symlink to anywhere — such a `.herd` is skipped with a note.
# Otherwise the work happens in a subshell that `cd -P`s into `.herd`, checks
# with `pwd -P` that it is exactly <physical project>/.herd and from then on
# works only RELATIVE to `.` — a `.herd` swapped for a symlink after the check
# cannot redirect the deletion (the open directory is used, the path is never
# resolved again). Symlink entries are removed as links. Each entry is deleted
# only after a SUCCESSFUL age check (find error, missing find, unreadable
# subdirectory → keep it). The main checkout counts only if the current
# checkout is registered in its `git worktree list` (a crafted `.git` file
# could point anywhere).
# 0 or invalid = off; errors are ignored.
prune_herd_workdirs() {
  local cwd="$1" days="${2:-14}" top common dir real seen=" "
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  days=$((10#$days))
  [ "$days" -gt 0 ] && [ -d "$cwd" ] || return 0
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$common" in */.git) common="${common%/.git}" ;; *) common="" ;; esac
  if [ -n "$common" ] && ! herd_is_worktree_of "$common" "${top:-$cwd}"; then common=""; fi
  for dir in "$cwd" "$top" "$common"; do
    [ -n "$dir" ] || continue
    if [ -L "$dir/.herd" ]; then
      echo "[herd] note: $dir/.herd is a symlink — not cleaned up" >&2
      continue
    fi
    [ -d "$dir/.herd" ] || continue
    real="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || continue
    case "$seen" in *" $real "*) continue ;; esac
    seen="$seen$real "
    ( prune_herd_dir "$real" "$days" ) || true
  done
  return 0
}

# Subshell body of prune_herd_workdirs: $1 = physical project path, $2 = days.
prune_herd_dir() {
  local real="$1" days="$2" list e young
  cd -P -- "$real/.herd" 2>/dev/null || return 0
  if [ "$(pwd -P)" != "$real/.herd" ]; then
    echo "[herd] note: $real/.herd changed during the cleanup check — not cleaned up" >&2
    return 0
  fi
  list="$HERD_TMP/herd-entries"
  find . -mindepth 1 -maxdepth 1 -print0 >"$list" 2>/dev/null || return 0
  while IFS= read -r -d '' e; do
    [ "$e" = ./questions ] && continue
    # find without -L judges a symlink by its own mtime and does not descend.
    # Exit status and result separately: any error → keep the entry.
    young="$(find "$e" -mtime -"$days" -print -quit 2>/dev/null)" || continue
    [ -z "$young" ] || continue
    if [ -L "$e" ]; then rm -f -- "$e" 2>/dev/null || true
    else rm -rf -- "$e" 2>/dev/null || true
    fi
  done <"$list"
  return 0
}

# Is the checkout $2 registered in `git worktree list` of the repository $1?
# Compared by physical path; any error → no.
herd_is_worktree_of() {
  local want line p
  want="$(cd -P -- "$2" 2>/dev/null && pwd -P)" || return 1
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    p="$(cd -P -- "${line#worktree }" 2>/dev/null && pwd -P)" || continue
    [ "$p" = "$want" ] && return 0
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  return 1
}

# Private per-user root for the run directories of start/exec/run. The earlier
# shared /tmp/herd could be pre-created by another local user, who could then
# read prompts and logs or swap command files that get executed later
# (security review 2026-10-11). The root lives in XDG_RUNTIME_DIR (else TMPDIR,
# else /tmp), carries the uid in its name, is created with mode 0700 and must
# be a real directory owned by us — otherwise abort before anything is written.
# Run directories inside come from mktemp -d. Prints the root path.
herd_log_root_path() {
  local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  printf '%s\n' "${base%/}/herd-$(id -u)"
}
herd_log_root() {
  local root
  root="$(herd_log_root_path)"
  [ -e "$root" ] || [ -L "$root" ] || mkdir -m 700 "$root" 2>/dev/null || true
  if [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ]; then
    echo "[herd] log root '$root' is a symlink or not a directory owned by you — refusing to use it. Remove it, or point XDG_RUNTIME_DIR/TMPDIR elsewhere." >&2
    return 1
  fi
  # Owned by us: tighten a root left with a wider mode (best effort; Windows
  # emulates the mode bits).
  chmod 700 "$root" 2>/dev/null || true
  printf '%s\n' "$root"
}

# Wrapper shell code of exec/run (typed into the pane as a command file, or
# passed to setsid). Every value in it is %q-quoted and the hold time is a
# validated integer — before 2026-10-11 the log path (containing the name) sat
# in a double-quoted echo and --hold went unquoted into the code.
# Args: logdir hold_sec command…  Sets log, done_marker, wrapper.
batch_wrapper() {
  local hold="$2" quoted q_log q_done
  log="$1/log.txt"; done_marker="$1/done"
  shift 2
  quoted="$(printf '%q ' "$@")"
  printf -v q_log '%q' "$log"
  printf -v q_done '%q' "$done_marker"
  wrapper="{ $quoted; } 2>&1 | tee $q_log; ec=\${PIPESTATUS[0]}; echo \$ec > $q_done; echo; echo \"[herd] exit \$ec — log: \"$q_log; sleep $hold"
}

# Directory of this script — the event watcher sits next to it. Resolved via
# `cd` so that a relative call ("bash scripts/herd.sh") and a call from another
# working directory yield the same path. The skill is symlinked as a WHOLE
# directory, so resolving with readlink would be unnecessary — both files
# always live in the same (symlinked) directory.
# readlink -f: also find the helpers when herd.sh is called via a symlink
# (e.g. ~/bin/herd.sh -> <skill>/scripts/herd.sh).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
EVENTS_PY="$SCRIPT_DIR/herd_events.py"

# Role lock for sub-agents that read global instructions themselves at start
# (claude via CLAUDE.md/skill, copilot via copilot-instructions.md; muse gets
# its recursion guard via muse_foreign_guard, see below). Without this
# hint they would behave like an orchestrator themselves based on their
# orchestrator instructions and delegate recursively.
# See SKILL.md §3 Roles and recursion guard.
SUBAGENT_LOCK="You were started as a delegated sub-agent in a herdr pane. You are NOT the orchestrator of the herdr workspace: do NOT use the herdr-orchestrator skill and do NOT open new herdr panes. You may use your own (in-process) sub-agents if your brief allows it. Do the brief you were given in the current working directory and report the result back. Architecture decisions, final acceptance and communication with the user stay with the orchestrator."

show_usage() {
  # Prints the header comment from line 2 to the line before the '# INTERNAL' block
  # (without the separating blank comment line before it). No fixed line count anymore.
  local intern_ln
  intern_ln="$(grep -n '^# INTERNAL' "$0" | head -1 | cut -d: -f1)"
  if [ -n "$intern_ln" ] && [ "$intern_ln" -gt 2 ]; then
    sed -n "2,$((intern_ln - 2))p" "$0" | sed 's/^# \{0,1\}//'
  else
    sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'
  fi
}

# --- Configuration (private, optional) --------------------------------------
# The sourceable file sets e.g. BACKENDS="codex,claude" (allowlist of permitted
# backends, comma-separated) and MODEL_<BACKEND>=… (default model per backend).
# Also: HERD_IMPL_PERMISSION_MODE (claude/grok, permission mode for
# --role impl) — details at build_cli. HERD_PI_PROVIDER (pi, NO default;
# needed if --model is not provider/id) analogous to OPENCODE_PROVIDER;
# MODEL_PI as the default model. HERD_PI_PROJECT_TRUST (pi, approve|ignore;
# default approve with HERD_AUTO_TRUST=1, otherwise ignore) pre-empts the
# project trust prompt. HERD_AUTO_TRUST (0|1, default 0) — see auto_trust_enabled.
# Without the file: all installed backends allowed, no default models.
# HERD_CONFIG overrides the path.
HERD_CONFIG="${HERD_CONFIG:-$HOME/.config/herdr-orchestrator/config}"
# shellcheck disable=SC1090
[ -f "$HERD_CONFIG" ] && . "$HERD_CONFIG"

# Backend allowed? Check the BACKENDS allowlist (empty/unset → all allowed).
# The installation check (which) happens only in build_cli/exec.
guard_backend() {
  local backend="$1" list="${BACKENDS:-}"
  [ -z "$list" ] && return 0
  case ",$list," in
    *",$backend,"*) return 0 ;;
    *)
      echo "[herd] backend '$backend' is not in the allowlist" \
           "(BACKENDS=$list; Config: $HERD_CONFIG)." >&2
      exit 3 ;;
  esac
}

# Default model from config (MODEL_<BACKEND>) if no --model was given.
default_model_for() {
  case "$1" in
    codex)    printf '%s' "${MODEL_CODEX:-}" ;;
    agy)      printf '%s' "${MODEL_AGY:-}" ;;
    opencode) printf '%s' "${MODEL_OPENCODE:-}" ;;
    claude)   printf '%s' "${MODEL_CLAUDE:-}" ;;
    copilot)  printf '%s' "${MODEL_COPILOT:-}" ;;
    grok)     printf '%s' "${MODEL_GROK:-}" ;;
    kimi)     printf '%s' "${MODEL_KIMI:-}" ;;
    muse)     printf '%s' "${MODEL_MUSE:-}" ;;
    pi)       printf '%s' "${MODEL_PI:-}" ;;
  esac
}

# Is herdr running? Check reachability of the CLI instead of the socket file:
# on Windows $HERDR_SOCKET_PATH does not exist as a file (different IPC), and
# MSYS bash does not know the Unix socket test -S anyway.
# Interactive verbs: keep the cause on stderr, stdout stays protocol.
require_herdr() {
  if [ "${HERDR_ENV:-}" != "1" ]; then
    echo "[herd] herdr environment missing: HERDR_ENV=1 expected (call from a herdr terminal)." >&2
    return 2
  fi
  if ! command -v herdr >/dev/null 2>&1; then
    echo "[herd] herdr CLI 'herdr' not found in PATH." >&2
    return 2
  fi
  if herdr pane list >/dev/null; then
    return 0
  else
    local rc=$?
    echo "[herd] herdr access failed: 'herdr pane list' (exit $rc). Check environment, connection and permissions." >&2
    return 2
  fi
}

# Batch exec/run still need the silent fallback when herdr is missing.
herdr_up() { require_herdr 2>/dev/null; }

# Does the installed herdr know the given backend kind?
# Reads `herdr agent start --help 2>&1`, collects from `possible values:` to
# the closing `]` across continuation lines and checks whether <kind> appears
# as a whole word in it. If the block is missing (older/other herdr) -> fail-open (0).
herdr_kind_known() {
  local kind="$1" help_out pv_block
  command -v herdr >/dev/null 2>&1 || return 0
  help_out="$(herdr agent start --help 2>&1 || true)"
  pv_block="$(printf '%s\n' "$help_out" | awk '
    /possible values:/ { found=1; buf="" }
    found {
      buf = buf " " $0
      if ($0 ~ /\]/) { print buf; found=0; exit }
    }
  ')"
  [ -n "$pv_block" ] || return 0
  pv_block="$(printf '%s' "$pv_block" | tr -s '[:space:]' ' ')"
  printf '%s\n' "$pv_block" | grep -qE "(^|[^a-zA-Z0-9_-])${kind}([^a-zA-Z0-9_-]|$)"
}

# Client version without the leading "herdr ", "" if unknown.
herdr_client_version() {
  herdr --version 2>/dev/null | head -1 | sed -e 's/^herdr //' || true
}

# Server version + update flags from `herdr status --json`. After an update
# without a restart, client and server run with different versions (real:
# binary 0.9.3, server 0.9.1) — diagnoses therefore name both. Sets the
# globals herdr_server_version ("" if unknown) and herdr_server_stale
# (1 if update.restart_needed or update.server_binary_stale).
# Every error (herdr missing, no JSON, fields missing, server not running)
# leads to an empty result, never to an abort. The result is cached per process
# (herdr_server_info_done) — herdr_version_label does not trigger a second
# status query. Without `timeout` the diagnosis is skipped: it must not
# block the start without a hard deadline.
herdr_server_info() {
  [ "${herdr_server_info_done:-0}" = 1 ] && return 0
  herdr_server_info_done=1
  herdr_server_version=""; herdr_server_stale=0
  command -v herdr >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  local js parsed sec="${HERD_HERDR_STATUS_TIMEOUT_SEC:-5}"
  # -k 2: a child that ignores SIGTERM is killed hard (SIGKILL) 2 s after the
  # deadline — a hanging server does not block the start.
  js="$(timeout -k 2 "$sec" herdr status --json 2>/dev/null)" || return 0
  [ -n "$js" ] || return 0
  parsed="$(printf '%s' "$js" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
srv = d.get("server") or {}
if not srv.get("running"):
    sys.exit(0)
u = d.get("update") or {}
print(srv.get("version") or "")
print(1 if (u.get("restart_needed") or u.get("server_binary_stale")) else 0)
' 2>/dev/null || true)"
  [ -n "$parsed" ] || return 0
  herdr_server_version="$(printf '%s\n' "$parsed" | sed -n 1p)"
  [ "$(printf '%s\n' "$parsed" | sed -n 2p)" = 1 ] && herdr_server_stale=1
  return 0
}

# "client <client>, server <server>" for diagnoses; if the server version is
# missing (or no server is running): "client <client>, server ?".
herdr_version_label() {
  local client="${1:-}"
  [ -n "$client" ] || client="?"
  herdr_server_info
  printf 'client %s, server %s' "$client" "${herdr_server_version:-?}"
}

# --- muse: recursion guard (SKILL.md §3 Roles and recursion guard) ----------
# muse loads the Claude skills from ~/.claude/skills as "foreign personal
# context" — among them THIS orchestrator skill. Since Muse 1.0.3 there is
# no run flag for it anymore (the former --no-foreign-personal-context is gone
# from the TUI); instead the skill is persistently disabled in muse:
# `muse skills disable herdr-orchestrator --scope user` (lands in
# ~/.config/muse/settings.json, applies to TUI and exec, undo with
# `muse skills enable …`). Muse then does not load the skill (verified
# 2026-09-08: skill list of the sub-agent session without herdr-orchestrator).
#
# muse_foreign_guard checks `muse skills list --source user --json`, disables
# the skill ONCE if needed (idempotent, note on stderr) and returns Exit 1
# if that does not take effect — the caller then aborts: a muse sub-agent with
# the orchestrator skill in context would recursively open panes.
MUSE_ORCH_SKILL_ID="herdr-orchestrator"

muse_orchestrator_skill_off() {
  # 0 = the orchestrator skill is disabled in muse (user scope) or unknown.
  local out
  command -v python3 >/dev/null 2>&1 || return 1
  out="$(muse skills list --source user --json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sk = d.get("skills", []) if isinstance(d, dict) else d
for s in sk:
    if isinstance(s, dict) and s.get("id") == sys.argv[1] and s.get("activation") != "off":
        sys.exit(1)
sys.exit(0)
' "$MUSE_ORCH_SKILL_ID"
}

muse_foreign_guard() {
  muse_orchestrator_skill_off && return 0
  echo "[herd] muse: disabling skill '$MUSE_ORCH_SKILL_ID' in muse persistently (recursion guard; to undo: muse skills enable $MUSE_ORCH_SKILL_ID --scope user)" >&2
  muse skills disable "$MUSE_ORCH_SKILL_ID" --scope user >/dev/null 2>&1 || true
  muse_orchestrator_skill_off && return 0
  echo "[herd] muse: recursion guard cannot be established — skill '$MUSE_ORCH_SKILL_ID' stays active in muse (check with muse skills list --source user --json). Aborting." >&2
  return 1
}

# Is the EVENT API usable? Feature detection for wait/watch.
# Not only reachability (ping) is checked, but also whether the daemon knows
# `events.subscribe` — an older daemon may reject it. Exactly that
# is the difference between "running" and "can do events": without subscribe
# the watcher would fail only after the start, in the middle of the observation.
#
# DELIBERATELY NOT CACHED (not even across calls): the daemon may restart or be
# updated between two runs.
# Reason for failure in EVENTS_PROBE_REASON — wait/watch then end hard
# with Exit 2 (no fallback).
EVENTS_PROBE_REASON=""
events_available() {
  EVENTS_PROBE_REASON=""
  command -v python3 >/dev/null 2>&1 || {
    EVENTS_PROBE_REASON="python3 not in PATH"; return 1; }
  [ -f "$EVENTS_PY" ] || {
    EVENTS_PROBE_REASON="watcher missing: $EVENTS_PY"; return 1; }
  local out rc=0
  # Collect ONLY stderr (`2>&1 >/dev/null` in this order): stdout of the
  # probe verb is meaningless, the reason is on stderr. The
  # exit code must be captured in the `||`, otherwise `set -e` ends the script.
  out="$(python3 "$EVENTS_PY" probe 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  # Multi-line to ONE line: the message later sits in a stderr line.
  EVENTS_PROBE_REASON="$(printf '%s' "${out:-Probe scheiterte (Exit $rc)}" | tr '\n' ' ')"
  return 1
}

# Engine choice for watch AND wait. HERD_WATCH_ENGINE=auto|events (both =
# event path). poll was removed on 2026-09-09 (stage 4) and is Exit 2.
# Validation belongs to the usage errors and runs BEFORE the herdr preflight,
# so a typo ("event", "Poll") does not slip through silently.
WATCH_ENGINE=""
validate_watch_engine() {
  local verb="$1"
  WATCH_ENGINE="${HERD_WATCH_ENGINE:-auto}"
  case "$WATCH_ENGINE" in
    auto|events) ;;
    poll)
      echo "[herd] $verb: HERD_WATCH_ENGINE=poll — the poll path was removed on 2026-09-09 (stage 4); use auto|events." >&2
      exit 2 ;;
    *) echo "[herd] $verb: HERD_WATCH_ENGINE expects auto|events (got: '$WATCH_ENGINE')" >&2
       exit 2 ;;
  esac
}

choose_watch_engine() {
  local verb="$1"
  if events_available; then
    return 0
  fi
  echo "[herd] $verb: event API not available (HERD_WATCH_ENGINE=$WATCH_ENGINE)" \
       "— $EVENTS_PROBE_REASON" >&2
  echo "[herd]   Requirement: herdr >= 0.8.2 and python3." >&2
  exit 2
}

# --- Space isolation ----------------------------------------------------------
# Name-based verbs act only in the own space (docs/plan-space-isolation.md).
# Own space ID, in this order:
#   1. HERDR_WORKSPACE_ID
#   2. prefix of HERDR_TAB_ID  (w9:t1 -> w9)
#   3. prefix of HERDR_PANE_ID (w9:p1 -> w9)
# An empty or obviously invalid prefix (":t1", "oops") does NOT break the
# chain — otherwise a broken higher source would hide a valid deeper one.
# A plausibly looking ID that the daemon does not know does not filter (an empty
# inventory is more dangerous) and notes it on stderr.
# Without any source: likewise no filtering, a one-time note.
# The note lives in a file (not just a variable): pane_id_of often runs in
# $(...), a subshell would otherwise lose HERD_SPACE_NOTE=1.
plausible_space_id() {
  # ASCII alnum after the leading w. [A-Za-z0-9] in case globs is not the
  # ASCII range under de_DE.UTF-8 and does not match "w9", among others.
  case "$1" in
    w[0-9a-zA-Z]*)
      case "$1" in *[!0-9a-zA-Z]*) return 1 ;; esac
      [ "${#1}" -ge 2 ] ;;
    *) return 1 ;;
  esac
}

own_workspace_id() {
  local src pre
  if plausible_space_id "${HERDR_WORKSPACE_ID:-}"; then
    printf '%s' "$HERDR_WORKSPACE_ID"
    return 0
  fi
  src="${HERDR_TAB_ID:-}"
  if [ -n "$src" ] && [ "${src#*:}" != "$src" ]; then
    pre="${src%%:*}"
    if plausible_space_id "$pre"; then
      printf '%s' "$pre"
      return 0
    fi
  fi
  src="${HERDR_PANE_ID:-}"
  if [ -n "$src" ] && [ "${src#*:}" != "$src" ]; then
    pre="${src%%:*}"
    if plausible_space_id "$pre"; then
      printf '%s' "$pre"
      return 0
    fi
  fi
}

# Private scratch directory of THIS invocation (mktemp -d: mode 0700, random
# name) for small files: status/prompt errors, the space note flag, option
# lists. Fixed names like /tmp/herd-probe-err.$$ in the shared /tmp could be
# pre-created or symlinked by another local user. Removed by the EXIT trap below
# (and by hand before an exec, which skips the trap).
HERD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/herd.XXXXXX")" \
  || { echo "[herd] cannot create a private temporary directory under ${TMPDIR:-/tmp}" >&2; exit 1; }
HERD_SPACE_NOTE_FILE="${HERD_SPACE_NOTE_FILE:-$HERD_TMP/space-note}"
note_unscoped_space() {
  if [ ! -f "$HERD_SPACE_NOTE_FILE" ]; then
    echo "[herd] no space ID determinable (HERDR_WORKSPACE_ID/TAB_ID/PANE_ID empty) — not filtering" >&2
    : > "$HERD_SPACE_NOTE_FILE"
  fi
}

note_space_once() {
  if [ ! -f "$HERD_SPACE_NOTE_FILE" ]; then
    echo "[herd] $1" >&2
    : > "$HERD_SPACE_NOTE_FILE"
  fi
}

explain_foreign_agent() {
  echo "[herd] '$1' is in space $2, you are in $3 — foreign spaces are" >&2
  echo "       not touched." >&2
}

# workspace list: 0 = known, 1 = daemon does not know the ID, 2 = not verifiable.
workspace_exists() {
  local id="$1" raw
  raw="$(herdr workspace list 2>/dev/null)" || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  printf '%s' "$raw" | python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.loads(sys.stdin.read())["result"]["workspaces"]
except Exception:
    sys.exit(2)
if not isinstance(items, list):
    sys.exit(2)
for w in items:
    if isinstance(w, dict) and (w.get("workspace_id") or "") == want:
        sys.exit(0)
sys.exit(1)
' "$id"
}

# Candidate + daemon cross-check. Empty return value = no filtering.
# Result is cached per process (one workspace-list RPC is enough).
OWN_WS_CACHE=""; OWN_WS_CACHED=0
resolved_own_workspace() {
  if [ "$OWN_WS_CACHED" = 1 ]; then
    printf '%s' "$OWN_WS_CACHE"
    return 0
  fi
  OWN_WS_CACHED=1
  OWN_WS_CACHE=""
  local cand wr=0
  cand="$(own_workspace_id || true)"
  if [ -z "$cand" ]; then
    note_unscoped_space
    return 0
  fi
  workspace_exists "$cand" || wr=$?
  if [ "$wr" -eq 0 ]; then
    OWN_WS_CACHE="$cand"
    printf '%s' "$cand"
    return 0
  fi
  if [ "$wr" -eq 1 ]; then
    note_space_once "space '$cand' is unknown to the daemon — not filtering"
  else
    note_space_once "workspace membership not verifiable (workspace list) — not filtering"
  fi
}

# String/number field from herdr JSON (same grep style as in the rest of the script).
json_str() {
  printf '%s' "$1" | grep -o '"'"$2"'":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//'
}
json_num() {
  printf '%s' "$1" | grep -o '"'"$2"'":[0-9]*' | head -1 | sed 's/.*://'
}

# workspace_id from the agent reply, otherwise the prefix of a real pane ID (w9:p1).
# Test pane IDs of the form p:name have no space prefix — those stay empty.
workspace_of_agent_json() {
  local raw="$1" ws pane
  ws="$(json_str "$raw" workspace_id)"
  if [ -n "$ws" ]; then printf '%s' "$ws"; return 0; fi
  pane="$(json_str "$raw" pane_id)"
  case "$pane" in
    w[A-Za-z0-9]*:*) printf '%s' "${pane%%:*}" ;;
  esac
}

# Look up name+workspace in `herdr agent list`. stdout: status<TAB>pane<TAB>seq
# Exit 0 = found, 1 = checked and not present, 2 = not verifiable
# (no python3, list dead, broken JSON). 2 must NOT be treated like "not present"
# — otherwise a helper failure locks out the own agent.
agent_in_workspace() {
  local name="$1" ws="$2" raw
  raw="$(herdr agent list 2>/dev/null)" || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  printf '%s' "$raw" | python3 -c '
import json, sys
name, ws = sys.argv[1], sys.argv[2]
try:
    agents = json.loads(sys.stdin.read())["result"]["agents"]
except Exception:
    sys.exit(2)
if not isinstance(agents, list):
    sys.exit(2)
for a in agents:
    if a.get("name") == name and (a.get("workspace_id") or "") == ws:
        seq = a.get("state_change_seq")
        print("%s\t%s\t%s" % (a.get("agent_status") or "",
                              a.get("pane_id") or "",
                              "" if seq is None else seq))
        sys.exit(0)
sys.exit(1)
' "$name" "$ws"
}

# Label in pane list, preferred in the own space. stdout: pane_id.
# Exit 0 = found, 1 = none (possibly only foreign), 2 = not verifiable, 3 = only foreign
# (foreign ws on the stderr line FOREIGN\t<ws>).
pane_label_lookup() {
  local name="$1" own="$2" raw
  raw="$(herdr pane list 2>/dev/null)" || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  printf '%s' "$raw" | python3 -c '
import json, sys
name, own = sys.argv[1], sys.argv[2]
try:
    panes = json.loads(sys.stdin.read())["result"]["panes"]
except Exception:
    sys.exit(2)
if not isinstance(panes, list):
    sys.exit(2)

def ws_of(p):
    ws = p.get("workspace_id") or ""
    if ws:
        return ws
    pid = p.get("pane_id") or ""
    if pid.startswith("w") and ":" in pid:
        return pid.split(":", 1)[0]
    return ""

own_hit = None
any_hit = None
foreign = None
for p in panes:
    if not isinstance(p, dict) or (p.get("label") or "") != name:
        continue
    pid = p.get("pane_id") or ""
    if not pid:
        continue
    ws = ws_of(p)
    if own and ws == own:
        print(pid)
        sys.exit(0)
    if own and ws and ws != own:
        if foreign is None:
            foreign = ws
        continue
    if any_hit is None:
        any_hit = pid
if own:
    if foreign:
        sys.stderr.write("FOREIGN\t%s\n" % foreign)
        sys.exit(3)
    sys.exit(1)
if any_hit:
    print(any_hit)
    sys.exit(0)
sys.exit(1)
' "$name" "$own"
}

# Space boundary on a successful agent-get reply. Sets PICK_STATE
# (ok|not_found), PICK_STATUS, PICK_PANE, PICK_SEQ. Foreign-only -> not_found
# (not unavailable: monitoring is intact) plus an explanatory message.
# If membership could not be checked: fail-open (keep the get values).
# PICK_* deliberately NOT PROBE_*: pane_id_of runs as a fallback AFTER the
# probe and must not overwrite its result.
PICK_STATE=""; PICK_STATUS=""; PICK_PANE=""; PICK_SEQ=""
scope_agent_pick() {
  local name="$1" raw="$2" own got_ws hit rc
  PICK_STATUS="$(json_str "$raw" agent_status)"
  PICK_PANE="$(json_str "$raw" pane_id)"
  PICK_SEQ="$(json_num "$raw" state_change_seq)"
  PICK_STATE=ok
  own="$(resolved_own_workspace || true)"
  if [ -z "$own" ]; then
    return 0
  fi
  got_ws="$(workspace_of_agent_json "$raw")"
  if [ "$got_ws" = "$own" ]; then
    return 0
  fi
  rc=0
  hit="$(agent_in_workspace "$name" "$own")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    PICK_STATUS="${hit%%	*}"
    hit="${hit#*	}"
    PICK_PANE="${hit%%	*}"
    PICK_SEQ="${hit#*	}"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    note_space_once "workspace membership of '$name' not verifiable — not filtering"
    return 0
  fi
  if [ -n "$got_ws" ]; then
    explain_foreign_agent "$name" "$got_ws" "$own"
  fi
  PICK_STATE=not_found
  PICK_STATUS=""; PICK_PANE=""; PICK_SEQ=""
  return 0
}

# pane_id for a name: first the own space (agent list, then pane label),
# only then give up. A global agent-get hit in a foreign space must not
# abort the search for the own term label. pane list is filtered as
# JSON — $name does not go unquoted into grep as a regex.
pane_id_of() {
  local name="$1" raw own hit rc p ferr got_ws
  own="$(resolved_own_workspace || true)"

  if [ -n "$own" ]; then
    rc=0
    hit="$(agent_in_workspace "$name" "$own")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      p="${hit#*	}"; p="${p%%	*}"
      if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
    elif [ "$rc" -eq 2 ]; then
      raw="$(herdr agent get "$name" 2>/dev/null)" || raw=""
      if [ -n "$raw" ] && [ -n "$(json_str "$raw" pane_id)$(json_str "$raw" agent_status)" ]; then
        scope_agent_pick "$name" "$raw"
        if [ "$PICK_STATE" = ok ] && [ -n "$PICK_PANE" ]; then
          printf '%s' "$PICK_PANE"
          return 0
        fi
      fi
    fi
    rc=0
    ferr="$(mktemp "${TMPDIR:-/tmp}/herd-pane-label.XXXXXX")"
    p="$(pane_label_lookup "$name" "$own" 2>"$ferr")" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$p" ]; then
      rm -f "$ferr"
      printf '%s' "$p"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      note_space_once "pane label of '$name' not verifiable — not filtering"
      raw="$(herdr pane list 2>/dev/null)" || raw=""
      # last resort: the first label without a space filter would be unsafe —
      # rather empty than a foreign pane.
      rm -f "$ferr"
      return 0
    fi
    if [ "$rc" -eq 3 ]; then
      got_ws="$(awk -F'\t' '/^FOREIGN\t/{print $2; exit}' "$ferr")"
      rm -f "$ferr"
      [ -n "$got_ws" ] && explain_foreign_agent "$name" "$got_ws" "$own"
      return 0
    fi
    rm -f "$ferr"
    # No own pane. If get knows a foreign one, explain that.
    raw="$(herdr agent get "$name" 2>/dev/null)" || raw=""
    got_ws="$(workspace_of_agent_json "$raw")"
    if [ -n "$got_ws" ] && [ "$got_ws" != "$own" ]; then
      explain_foreign_agent "$name" "$got_ws" "$own"
    fi
    return 0
  fi

  # No own space ID: fail-open, the note already comes from resolved_own_workspace.
  raw="$(herdr agent get "$name" 2>/dev/null)" || raw=""
  p="$(json_str "$raw" pane_id)"
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  p="$(pane_label_lookup "$name" "" 2>/dev/null)" || p=""
  printf '%s' "$p"
}

# 2026-08-31: herdr agent start can fail although the agent is already
# registered on our freshly created pane (codex in the trust dialog:
# attempt 1 registered, reported an error; attempt 2 -> agent_name_taken
# with the own pane as candidate). Then do not retry and do not
# abort — the agent is running. Checks the registration, not the error text.
start_registered_on_pane() {
  local name="$1" pane="$2" got
  [ -n "$name" ] && [ -n "$pane" ] || return 1
  got="$(pane_id_of "$name")"
  [ "$got" = "$pane" ]
}

# Does the pane-get reply carry no label? Exit 0 only if the reply is
# structurally evaluable (result.pane is an object) AND carries no non-empty
# label. Invalid JSON, empty reply, wrong structure or wrong
# label type -> Exit 1: the caller must then NOT rename (never overwrite an
# existing label). The earlier grep extraction (json_str) saw only the
# compact form "label":"..." and took whitespace JSON for empty, for instance.
pane_label_missing() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
res = d.get("result")
if not isinstance(res, dict):
    sys.exit(1)
pane = res.get("pane")
if not isinstance(pane, dict):
    sys.exit(1)
if "label" not in pane:
    sys.exit(0)
lbl = pane.get("label")
if lbl is None:
    sys.exit(0)
if not isinstance(lbl, str):
    sys.exit(1)
sys.exit(1 if lbl else 0)
' 2>/dev/null
}

# Start early detection "backend died immediately" (real 2026-09-08: wrong
# flag -> help + exit within 1 s, herdr still ran into the 3-min
# timeout twice). Reads pane text from stdin; awk in ONE pass, prompt only by
# string comparison (special characters in the prompt then do not matter).
# Last non-empty line, right-trimmed — remember the prompt line.
start_prompt_line() {
  awk '
    /^[[:space:]]*$/ { next }
    { sub(/[[:space:]]+$/, ""); last = $0 }
    END { if (last != "") print last }
  '
}

# Signature "shell is back at the prompt": the last non-empty line is the
# remembered prompt line AND there is a NEW echo of the typed command —
# more echo lines (prompt + space + text) than $2 (baseline per attempt,
# round 5). Old echoes (attempt 1, scrollback) would otherwise fire again before
# the new command was even typed. BOTH conditions together —
# the first alone also hits the state BEFORE typing. Prompt via ENVIRON
# instead of awk -v: backslashes in the prompt would otherwise not stay literal. Exit 0/1.
start_shell_back() {
  [ -n "${1:-}" ] || return 1
  START_PROMPT_LINE="$1" START_ECHO_BASE="${2:-0}" awk '
    /^[[:space:]]*$/ { next }
    { sub(/[[:space:]]+$/, ""); n++; lines[n] = $0 }
    END {
      p = ENVIRON["START_PROMPT_LINE"]
      if (n == 0 || p == "") exit 1
      # Force a string comparison: lines[n] != p would compare numerically
      # ("01" == "1") — prompt lines are text, not numbers.
      if (("" lines[n]) != ("" p)) exit 1
      base = ENVIRON["START_ECHO_BASE"] + 0
      plen = length(p)
      echoes = 0
      for (i = 1; i <= n; i++)
        if (substr(lines[i], 1, plen + 1) == (p " ") && length(lines[i]) > plen + 1) echoes++
      # > not >=: sliding 400-line window (round 6, see start_echo_count).
      if (echoes > base) exit 0
      exit 1
    }
  '
}

# Echo baseline of an attempt: counts echo lines (prompt + space +
# text) in the pane text from stdin — read immediately BEFORE agent start, so
# only a command typed afterwards triggers the signature. Reads from stdin.
# Limit (deliberate, round 6): the 400-line window slides. If an old
# echo falls out at the top and a new one is added at the bottom, the count stays
# the same — no hit, fail-open. A >= comparison would be wrong (old false alarm).
start_echo_count() {
  [ -n "${1:-}" ] || { echo 0; return 0; }
  START_PROMPT_LINE="$1" awk '
    /^[[:space:]]*$/ { next }
    { sub(/[[:space:]]+$/, ""); n++; lines[n] = $0 }
    END {
      p = ENVIRON["START_PROMPT_LINE"]
      plen = length(p)
      c = 0
      for (i = 1; i <= n; i++)
        if (plen > 0 && substr(lines[i], 1, plen + 1) == (p " ") && length(lines[i]) > plen + 1) c++
      print c + 0
    }
  '
}

# Diagnosis from the LAST echo line (live finding round 4): the error line
# sits directly AFTER the typed command, not at the pane end — the last
# 15 lines showed only the end of a long help. Prints non-empty, right-trimmed
# lines from the echo on: all if at most 17, otherwise first 12 +
# last 5 with an omission line. Python3 does the shortening (characters, not bytes),
# sed the indentation — one task per tool. Reads from stdin.
start_diagnose() {
  [ -n "${1:-}" ] || return 1
  START_PROMPT_LINE="$1" awk '
    /^[[:space:]]*$/ { next }
    { sub(/[[:space:]]+$/, ""); n++; lines[n] = $0 }
    END {
      p = ENVIRON["START_PROMPT_LINE"]
      plen = length(p)
      start = 1
      for (i = n; i >= 1; i--)
        if (plen > 0 && substr(lines[i], 1, plen + 1) == (p " ") && length(lines[i]) > plen + 1) { start = i; break }
      m = n - start + 1
      if (m <= 17) {
        for (i = start; i <= n; i++) print lines[i]
      } else {
        for (i = start; i < start + 12; i++) print lines[i]
        printf "… (%d lines omitted)\n", m - 17
        for (i = n - 4; i <= n; i++) print lines[i]
      }
    }
  '
}

# Is background process $1 still alive? kill -0 alone is not enough: a finished
# but not yet reaped child (zombie) still reports as alive — the
# monitoring loop would hang forever. So detect the zombie (Z) via ps
# (Z = finished); if ps does not hit, kill -0 follows.
start_bg_alive() {
  [ -n "${1:-}" ] || return 1
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null || true)"
  if [ -n "$st" ]; then
    case "$st" in *Z*) return 1 ;; *) return 0 ;; esac
  fi
  kill -0 "$1" 2>/dev/null
}

# wait for the agent-start client: reap once, then idempotent.
# Exit 0 is the normal success path — also after a kill that hit an already
# finished child (round 6: snapshot alive, process ends with 0 before wait).
# Sets start_waited/start_rc; the caller initializes both per attempt.
# Return 0 exactly when the client had Exit 0.
start_reap() {
  [ -n "${1:-}" ] || return 1
  if [ "${start_waited:-0}" = 1 ]; then
    [ "${start_rc:-1}" -eq 0 ]
    return
  fi
  start_waited=1
  if wait "$1" 2>/dev/null; then
    start_rc=0
  else
    start_rc=$?
  fi
  [ "$start_rc" -eq 0 ]
}

# Pane read of the start early detection with a finite deadline (pattern
# read_visible_pane): a hanging read must block neither the prompt wait nor
# the monitoring forever. Timeout counts like a read error
# (callers handle both fail-soft). No new switch.
start_pane_read() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=KILL 3 herdr pane read "$1" --source recent-unwrapped --lines 400 --format text
  else
    herdr pane read "$1" --source recent-unwrapped --lines 400 --format text
  fi
}

# agent_status (idle|working|blocked|done|unknown) of an agent name.
# Space-limited like pane_id_of: foreign hit -> empty.
agent_status_of() {
  local raw
  raw="$(herdr agent get "$1" 2>/dev/null)" || return 0
  [ -n "$(json_str "$raw" agent_status)" ] || return 0
  scope_agent_pick "$1" "$raw"
  [ "$PICK_STATE" = ok ] && printf '%s' "$PICK_STATUS"
}

# Status query WITH error classes. agent_status_of alone cannot tell between
# "agent does not exist" and "monitoring broken" — both return
# an empty string. With several observed agents a daemon failure would
# otherwise have been misread as "all gone".
# Sets PROBE_STATE (ok|not_found|unavailable), PROBE_STATUS, PROBE_PANE,
# PROBE_SEQ and PROBE_KIND (field "agent", e.g. agy|grok). Status, pane_id,
# sequence and kind come from the SAME reply — an additional
# pane_id_of call would be a second roundtrip per agent query.
#
# PROBE_SEQ (herdr's state_change_seq) is the GENERATION: it changes on
# every state change of the agent and stays stable otherwise. Without it, a
# brief that lies completely between two observations (idle -> working ->
# idle) would not be recognizable from the status alone — the status looks the
# same before and after.
PROBE_STATE=""; PROBE_STATUS=""; PROBE_PANE=""; PROBE_SEQ=""; PROBE_KIND=""
PROBE_ERR="$HERD_TMP/probe-err"
trap 'rm -rf "$HERD_TMP"; rm -f "$HERD_SPACE_NOTE_FILE" "${answer_opts:-}"' EXIT
agent_status_probe() {
  local name="$1" i raw rc
  PROBE_KIND=""
  # Repeat the FAILED query itself — not just the daemon check.
  # Otherwise a transient agent-get hiccup with a healthy daemon immediately
  # becomes 'lost' ("work counts as NOT done"), a costly false alarm.
  for i in 1 2 3; do
    # `raw="$(cmd)"; rc=$?` would already be fatal under `set -e` at the
    # ASSIGNMENT as soon as cmd returns nonzero — the exit code must be captured in the ||.
    rc=0
    # Capture stderr TOO: herdr reports an unknown agent there as
    # {"error":{"code":"agent_not_found",...}} — a clear signal that makes
    # a heuristic over "empty reply + exit code" unnecessary.
    raw="$(herdr agent get "$name" 2>"$PROBE_ERR")" || rc=$?
    if grep -q 'agent_not_found' "$PROBE_ERR" 2>/dev/null; then
      PROBE_STATE=not_found; PROBE_STATUS=""; PROBE_PANE=""; PROBE_SEQ=""; PROBE_KIND=""
      return 0
    fi
    PROBE_STATUS="$(printf '%s' "$raw" | grep -o '"agent_status":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    PROBE_PANE="$(printf '%s' "$raw" | grep -o '"pane_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    PROBE_SEQ="$(printf '%s' "$raw" | grep -o '"state_change_seq":[0-9]*' | head -1 | sed 's/.*://')"
    if [ -n "$PROBE_STATUS" ]; then
      # Space boundary: a hit in a foreign space is not_found, not
      # unavailable (monitoring is intact). If the same name exists in the
      # own space, scope_agent_pick takes it.
      scope_agent_pick "$name" "$raw"
      PROBE_STATE="$PICK_STATE"
      PROBE_STATUS="$PICK_STATUS"
      PROBE_PANE="$PICK_PANE"
      PROBE_SEQ="$PICK_SEQ"
      # Kind only if the get hit is the own pane (the list fallback
      # has no kind field).
      PROBE_KIND=""
      if [ "$PICK_STATE" = ok ] && [ "$PICK_PANE" = "$(json_str "$raw" pane_id)" ]; then
        PROBE_KIND="$(json_str "$raw" agent)"
      fi
      return 0
    fi
    [ "$i" -lt 3 ] && sleep "$RETRY_SEC"
  done
  # A NON-EMPTY reply without a readable status is a protocol/schema problem
  # (error envelope, changed format) — NOT proof that the agent is gone.
  # Turning that into 'lost' ("work counts as not done") would be a costly
  # false alarm based on a misreading.
  if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
    PROBE_STATE=unavailable
    return 0
  fi
  # Empty reply: tell whether the daemon is alive (then really only this agent
  # is gone) or whether the monitoring as a whole has failed.
  if herdr pane list >/dev/null 2>&1; then
    PROBE_STATE=not_found
  else
    for i in 1 2; do
      sleep "$RETRY_SEC"
      if herdr pane list >/dev/null 2>&1; then PROBE_STATE=not_found; return 0; fi
    done
    PROBE_STATE=unavailable
  fi
  return 0
}

# Correct the raw agent status using the visible pane content. herdr knows
# neither approval dialogs nor usage limits nor login screens — they all look
# like idle (or like working with self-retry). Some backends (agy, grok)
# additionally report idle/done during generation/background task
# (looks_busy_kind → working). $3 = optional kind from agent get; a known
# kind without a busy pattern saves the extra read.
# STATELESS and therefore subshell-safe: the only place of this normalization,
# used by `status`, `wait` and `watch`.
normalize_status() {
  local st="$1" pane="$2" kind="${3:-}"
  [ -n "$pane" ] || { printf '%s' "$st"; return 0; }
  case "$st" in
    working)
      # Backends with self-retry (opencode: "usage limit reached … retrying
      # in 3h") stay permanently "working" at the limit. failed analogously:
      # a model error with raw-working (rare; muse typically returns to the
      # prompt) must not pass as progress.
      if looks_limited "$pane"; then st=limited
      elif looks_failed "$pane"; then st=failed
      fi ;;
    idle|done)
      # EXACTLY ONE pane read, then classify_text. Before, up to five reads
      # (looks_blocked/limited/auth/failed/busy_kind) — a read error after the
      # first would look like "no pattern". Kind RPC only on a busy pre-hit,
      # if $kind is empty (T128/T131).
      local buf verdict kind_use="$kind"
      buf="$(pane_visible "$pane")" || { printf '%s' "$st"; return 0; }
      if [ -z "$kind_use" ] && printf '%s\n' "$buf" | text_looks_any_busy; then
        kind_use="$(agent_kind_of "$pane")"
      fi
      verdict="$(printf '%s\n' "$buf" | classify_text "$kind_use")"
      case "$verdict" in
        blocked|limited|auth|failed|question) st="$verdict" ;;
        busy|background) st=working ;;
      esac ;;
    blocked)
      # muse 1.3.0 checks shell commands before execution with a built-in
      # reviewer: the pane then shows
      # "Reviewing approval request (… · esc to interrupt)" plus
      # "shell command: …" WITHOUT a user dialog, but herdr reports raw
      # `blocked` for it (confirmed live 2026-09-16, >10 false reports in 12 min).
      # Only muse is cross-checked; for ALL other kinds herdr's
      # `blocked` stays the reliable dialog source (no extra read, exactly
      # today's behavior).
      if [ "$kind" = muse ]; then
        # EXACTLY ONE pane read, then classify_text (blocked > limited > auth >
        # failed > busy > question > clean). Dialog → blocked (unchanged),
        # busy without dialog → working, quiet pane (clean) → blocked (herdr
        # keeps authority; do not hide unknown dialog formats).
        # A read error leaves `st` at blocked (fail-safe).
        local mbuf mverdict
        mbuf="$(pane_visible "$pane")" || { printf '%s' "$st"; return 0; }
        mverdict="$(printf '%s\n' "$mbuf" | classify_text "$kind")"
        case "$mverdict" in
          limited|auth|failed|question) st="$mverdict" ;;
          busy) st=working ;;
          *) st=blocked ;;
        esac
      elif [ -z "$kind" ]; then
        # Kind unknown/empty: as in the idle/done path, look it up via
        # agent_kind_of only on a busy pre-hit (T128/T131). Without a pre-hit it
        # stays at raw blocked — no additional kind RPC. Correction happens
        # ONLY if the lookup yields muse: for every other kind
        # (agy/grok/pi have their own busy patterns) a spinner would hide an
        # unknown dialog — there herdr keeps authority.
        local ubuf uverdict ukind
        ubuf="$(pane_visible "$pane")" || { printf '%s' "$st"; return 0; }
        if printf '%s\n' "$ubuf" | text_looks_any_busy; then
          ukind="$(agent_kind_of "$pane")"
          if [ "$ukind" = muse ]; then
            uverdict="$(printf '%s\n' "$ubuf" | classify_text "$ukind")"
            case "$uverdict" in
              limited|auth|failed|question) st="$uverdict" ;;
              busy) st=working ;;
            esac
          fi
        fi
      fi ;;
  esac
  printf '%s' "$st"
}

# The three timeout notice lines of wait — ONE source (explain-status
# wait-timeout). Do not type them into herd_events.py.
explain_wait_timeout() {
  local name="$1" timeout_min="${2:-30}" st="${3:-}"
  if [ -n "$st" ]; then
    echo "[herd] wait TIMEOUT after ${timeout_min}min (status: $st) — NOT done, the agent keeps running." >&2
  else
    echo "[herd] wait TIMEOUT after ${timeout_min}min — NOT done, the agent keeps running." >&2
  fi
  echo "[herd]   Wait again:          herd.sh wait $name --timeout 5" >&2
  echo "[herd]   Observe permanently: herd.sh watch $name   (does not end on the first event)" >&2
}

# Action instruction for a return state on stderr — shared by wait
# and watch so both speak the same language.
explain_status() {
  local name="$1" st="$2"
  case "$st" in
    wait-timeout)
      explain_wait_timeout "$name" "${3:-30}" "${4:-}"
      return 0 ;;
    blocked) echo "[herd] '$name' is BLOCKED (approval/prompt) — dialog: herd.sh read $name --source visible; answer: herd.sh answer $name \"<option text>\" | key $name enter|esc" >&2 ;;
    limited) echo "[herd] '$name' has reached its usage/rate limit — prompt was NOT processed. Switch backend or wait for the reset." >&2 ;;
    failed)  echo "[herd] '$name' reports a backend/model error (e.g. muse \"model failed: model stream idle timeout\") — prompt was NOT processed. Send the same prompt again; on repetition switch backend (fallback chain)." >&2 ;;
    auth)    echo "[herd] '$name' shows a login/OAuth screen — session expired (agy: skill agy-auth). Send the prompt again afterwards." >&2 ;;
    question) echo "[herd] '$name' asked a QUESTION — only if the marker names the question path agreed in its brief: read the file (herd.sh read $name --source visible), move the file with a timestamp to <dir>/answered/, THEN answer via send $name \"<answer>\" and re-arm (see SKILL.md). Another path: ignore the marker, check the pane." >&2 ;;
    stalled) echo "[herd] '$name' has shown no visible progress for minutes (status working) — check the pane: herd.sh read $name --source visible; if needed abandon/restart the session." >&2 ;;
    busy)    echo "[herd] '$name' is still generating / has a background task — herdr reports idle/done, the pane is working. Do not treat as done." >&2 ;;
    background) echo "[herd] '$name' ended the turn, but background shells/monitors are still running — read the pane (herd.sh read $name --source visible): completion marker present and the shell just left over → have it cleaned up via send $name \"end background shells\"; if it waits for real work → keep observing, idle follows." >&2 ;;
    lost)    echo "[herd] '$name' is GONE (pane closed or backend ended) — work counts as NOT done. Check: herd.sh list" >&2 ;;
    monitor-unavailable)
             echo "[herd] MONITORING FAILED — herdr does not respond, the state of ALL agents is unknown. Check: herdr pane list" >&2 ;;
  esac
}

# --- Pane heuristics --------------------------------------------------------
# Two layers, ONE pattern list per state:
#   text_looks_*  checks TEXT on stdin (the pattern list lives here, once).
#   looks_*       reads the pane itself and sends it through the checker —
#                 unchanged interface for status/wait/answer/start.
# Why the split: `classify-pane` (internal verb for the event watcher)
# must read the pane EXACTLY ONCE and evaluate all pattern lists against the SAME
# text. With several own reads, a read error AFTER the first read would be
# indistinguishable from "no pattern found" — the result would be
# `clean`, i.e. a confirmed completion for a pane that could not be read at
# all anymore (TOCTOU, Step-C review MAJOR 1). Also, three reads could classify
# three different pane states.
# The visible read is identical for all three (40 lines), hence a helper.
pane_visible() {
  herdr pane read "$1" --source visible --lines 40 --format text 2>/dev/null
}

# Prefilter for dialog/limit/login detection:
# Filters the relevant lines for text_looks_blocked,
# text_looks_limited and text_looks_auth out of the pane text (package D, 2026-09-02).
# text_looks_failed has its OWN filter: this prefilter removes
# ◆-prefixed lines (tool echoes), but would also cut off "◆ model failed:".
# 1. Window: by default only the last 20 lines (dialogs, options,
#    footer and limit messages sit at the bottom above the composer). For login
#    screens (text_looks_auth) the whole window ($1 = all|0), since logins can
#    fill the entire pane.
# 2. Ignores lines with a line-number prefix (read/cat -n/Claude Code):
#    ^[[:space:]]*[0-9]{2,5}([[:space:]]{2,}|\t|→)
#    Single-digit numbers stay (dialog options like '1. Yes').
#    Box frames (┃/│) also stay (grok/codex dialog frames).
# 3. Ignores tool echo lines (agy/grok quote executed commands including
#    patterns, e.g. '● Bash(printf ... usage limit reached ...)' or '◆ Run ...'):
#    ^[[:space:]]*(●|◆|•)[[:space:]]
dialog_relevant_lines() {
  local n="${1:-20}"
  case "$n" in
    all|0) cat ;;
    *)     tail -n "$n" ;;
  esac | grep -vE $'^[[:space:]]*[0-9]{2,5}([[:space:]]{2,}|\t|→)|^[[:space:]]*(●|◆|•)[[:space:]]' || true
}

# Heuristic: does the visible pane content look like an approval/selection
# dialog? Needed because herdr sometimes reports the codex status as
# 'idle' with an open approval prompt. Patterns cover codex/claude/opencode/agy/kimi
# confirmations (kimi: plan dialog "Ready to build with this plan?" + options "1. Approve").
# DELIBERATELY NOT included: 'esc to cancel' — agy also shows that in the
# footer during generation (false blocked, real 2026-07-14: watcher aborted).
text_looks_blocked() {
  # incl. grok project/workspace picker ("Run Grok Build in a project directory?")
  # and grok footers (enter:select for long recents lists, [0-9]+/[0-9]+:select
  # for command approval, if the dialog head lies outside the 20-line window),
  # as well as muse questions with options (footer with "tab for an optional note")
  # and opencode permission/confirm dialog ("Permission required" or option bar with "Allow once" and "Reject"
  # or generically with "⇆ select" and "enter confirm", kind-independent, since opencode-specific enough).
  dialog_relevant_lines 20 \
    | grep -qiE 'press enter to (confirm|continue)|would you like to|do you want to proceed|do you trust|[0-9]\. yes,|[0-9]\. approve|[0-9]\. update now|ready to build with|yes, proceed|allow this|approve\?|run grok build in a project directory|[0-9]+/[0-9]+:select|enter:select|tab for an optional note|permission required|allow once.*reject|reject.*allow once|⇆.*select.*enter.*confirm'
}

looks_blocked() { pane_visible "$1" | text_looks_blocked; }

# Busy patterns per backend. herdr reports idle/done although the pane is still
# working (agy 2026-08-31: spinner / "esc to cancel" / task line;
# grok 2026-09-02: "N command(s) still running"; muse 2026-09-03:
# "esc to interrupt"; pi 2026-09-09: Braille spinner AND "Working").
# "esc to cancel" is HERE and NOT in text_looks_blocked — deliberately excluded
# there (false blocked, 2026-07-14). agy/grok/pi only in the last
# 10 lines (otherwise prose in reports hits the heuristic). 2026-09-02: grok
# showed "N command(s) still running" as the 7th line from the bottom (below it
# a blank line, composer frame 3 lines, blank line, footer) — 6 lines
# were not enough, watch kept reporting done. 10 covers grok, agy and pi;
# the false-positive risk is low (specific texts). muse: 25 lines
# — under the status line "Thinking (… · esc to interrupt)" sits the
# task list (◆ E: …, +N more, separator, prompt, footer); 2026-09-09
# the busy line lay 11+ lines above the end, watch reported idle in the middle of
# edits. claude 2026-10-04: implementers waiting for their own background
# shells/monitors sit at idle between events; evidence
# (live, Claude Code 2.1): turn end "✻ Cogitated for 3s · done 17:30 ·
# 2 monitors still running", footer "⏵⏵ auto mode on · 1 shell, 1 monitor ·
# ← for agents". If a background task keeps running after the work is done
# (dev server), the busy cap applies (HERD_EVENTS_BUSY_MAX_SEC).
kind_has_busy_patterns() {
  case "$1" in agy|grok|muse|pi|claude) return 0 ;; *) return 1 ;; esac
}

# claude: "· N shell(s)/monitor(s)" in the footer or "… still running"
# at turn end. Only with a middle dot before it or "still running" after it — a
# bare number before "shells" in reply prose is not enough.
CLAUDE_BG_RE='·[[:space:]]+[0-9]+ (shell|monitor)s?([[:space:],·]|$)|[0-9]+ (shell|monitor)s? still running'
# claude: running turn status line "· Crystallizing… (1m 16s · …)" — verb with
# ellipsis, directly followed by the parenthesis. The turn end ("✻ Cogitated for 3s
# · done 17:30") has none. Distinguishes in classify_text busy (turn running)
# from background (turn ended, only background tasks).
CLAUDE_TURN_RE='…[[:space:]]*\('


text_is_agy_survey() {
  # Only the contiguous survey block at the end of the window invalidates
  # its footer. A second footer or new output stays busy evidence.
  awk '
    /^[[:space:]]*How\047s the CLI experience so far\? Help us improve:[[:space:]]*$/ { state=1; next }
    state == 1 && /^[[:space:]]*\[1\] Good +\[2\] Fine +\[3\] Bad +\[0\] Skip[[:space:]]*$/ { state=2; blanks=0; next }
    state == 2 && /^[[:space:]]*$/ && blanks++ == 0 { next }
    state == 2 && /^[[:space:]]*esc to cancel([[:space:]]|$)/ { state=3; next }
    state == 3 && /^[[:space:]]*$/ { next }
    { state=0 }
    END { exit !(state == 3) }
  '
}

text_looks_busy_for_kind() {
  local kind="$1" buf last n
  buf="$(cat)"
  case "$kind" in
    muse) n=25 ;;
    *)    n=10 ;;
  esac
  last="$(printf '%s\n' "$buf" | tail -n "$n")"
  case "$kind" in
    agy)
      # The known survey is input-ready; its footer is no busy evidence.
      # Spinner and background tasks stay relevant next to the survey too.
      if ! printf '%s\n' "$last" | text_is_agy_survey; then
        printf '%s\n' "$last" | grep -qiE 'esc to cancel' && return 0
      fi
      printf '%s\n' "$last" | text_has_braille_spinner && return 0
      printf '%s\n' "$last" | grep -qE '^[[:space:]]*●[[:space:]]*\[[0-9]{2}:[0-9]{2}:[0-9]{2}\][[:space:]].*[[:space:]]running[[:space:]]*$'
      ;;
    grok)
      # NO Braille for grok (start logo trap 2026-07-24).
      # Marker glyph blinks (◎/◉/○, seen 2026-09-02) — therefore NOT part
      # of the pattern; the text behind it is stable.
      printf '%s\n' "$last" | grep -qE '(^|[[:space:]])[0-9]+ commands? still running'
      ;;
    muse)
      # No Braille for muse. Status line with esc to interrupt.
      # Window 25: task list under the thinking line (see above).
      printf '%s\n' "$last" | grep -qiE 'esc to interrupt'
      ;;
    claude)
      printf '%s\n' "$last" | grep -qE "$CLAUDE_BG_RE"
      ;;
    pi)
      # Working line: Braille spinner AND "Working" in the same line
      # (fixture working.txt; idle has the footer without a working line).
      printf '%s\n' "$last" | grep 'Working' | text_has_braille_spinner
      ;;
    *) return 1 ;;
  esac
}

# Union of all busy patterns (cheap pre-check). agy/grok: last 10
# lines; muse "esc to interrupt": last 25 (task list under the
# status line, otherwise the pre-hit without --kind misses the busy line).
# Braille additionally under LC_ALL=C — the same byte class as the fingerprint.
text_looks_any_busy() {
  local buf last10 last25
  buf="$(cat)"
  last10="$(printf '%s\n' "$buf" | tail -n 10)"
  last25="$(printf '%s\n' "$buf" | tail -n 25)"
  printf '%s\n' "$last25" | grep -qiE 'esc to interrupt' && return 0
  printf '%s\n' "$last10" | grep -qE "$CLAUDE_BG_RE" && return 0
  printf '%s\n' "$last10" | grep -qiE 'esc to cancel|(^|[[:space:]])[0-9]+ commands? still running|^[[:space:]]*●[[:space:]]*\[[0-9]{2}:[0-9]{2}:[0-9]{2}\][[:space:]].*[[:space:]]running[[:space:]]*$' && return 0
  printf '%s\n' "$last10" | text_has_braille_spinner
}

# Kind (backend) of a pane from `herdr agent get`. Field "agent" (e.g. "agy").
# Empty on error. Helper, no verb.
agent_kind_of() {
  local raw
  raw="$(herdr agent get "$1" 2>/dev/null)" || { printf ''; return 0; }
  json_str "$raw" agent
}

# Optional $2 = already known kind. Known kind without a busy pattern:
# no pane read. Known kind with a pattern: one read, only this pattern.
# Unknown: text first, then kind RPC.
looks_busy_kind() {
  local pane="$1" kind="${2:-}" buf
  if [ -n "$kind" ] && ! kind_has_busy_patterns "$kind"; then
    return 1
  fi
  buf="$(pane_visible "$pane")" || return 1
  if [ -n "$kind" ]; then
    printf '%s\n' "$buf" | text_looks_busy_for_kind "$kind"
    return
  fi
  printf '%s\n' "$buf" | text_looks_any_busy || return 1
  kind="$(agent_kind_of "$pane")"
  [ -n "$kind" ] || return 1
  printf '%s\n' "$buf" | text_looks_busy_for_kind "$kind"
}

# grok project picker (outside recents/non-project dir): option 1 = cwd.
# Conservative — only the unambiguous question marker, not generic "directory" prose.
looks_grok_project_picker() {
  herdr pane read "$1" --source visible --lines 40 --format text 2>/dev/null \
    | grep -qiE 'run grok build in a project directory\?'
}

# --- Selection dialog: plan + execution (shared by answer and start) ----------
# Answers SAFELY by option TEXT instead of blind down/enter (incident
# 2026-07-14: blind down+enter hit "No, reject" and aborted 22 min of grok work
# — the selection position varies!). Reads the visible pane, matches the
# option (exact, then prefix, then substring; case-insensitive, normalized)
# or __FIRST__ = index 0, computes the needed arrow keys relative to the
# current (›/❯/(●)) position. grok form "1 (●) Text" returns "key:N" instead of
# a delta — there the digit selects AND confirms (2026-08-31).
# Numbered options only as a run 1,2,3,... (min. 2, last run wins);
# isolated prose like "3 (x) tests failed" does not count. Radio-only: min. 2.
# stdout: NOOPTS | NOMATCH | AMBIG | READFAIL | "<delta>\t<chosen>" | "key:N\t<chosen>"
# stderr: OPT\t... (list of the options found)
# READFAIL = pane not readable (IPC, timeout, python). Must NEVER be treated
# like NOOPTS — otherwise a failed verification read counts as
# "dialog gone" and answer ends with Exit 0 (cross-review 2026-08-18).
read_visible_pane() {
  local pane="$1" sec="${HERD_ANSWER_READ_TIMEOUT:-5}"
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=KILL "$sec" herdr pane read "$pane" --source visible --lines 40 --format text
  else
    herdr pane read "$pane" --source visible --lines 40 --format text
  fi
}

read_visible_pane_ansi() {
  local pane="$1" sec="${HERD_ANSWER_READ_TIMEOUT:-5}"
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=KILL "$sec" herdr pane read "$pane" --source visible --lines 40 --format ansi
  else
    herdr pane read "$pane" --source visible --lines 40 --format ansi
  fi
}

# Pure ANSI evaluation in the shared parser; terminal accesses stay here.
answer_bar_marked_option() {
  local ansi="$1"
  shift
  printf '%s' "$ansi" | python3 "$SCRIPT_DIR/herd_parse.py" bar-marked -- "$@"
}

dialog_answer_plan() {
  local pane="$1" target="$2" buf rc=0
  buf="$(read_visible_pane "$pane")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo READFAIL
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { echo READFAIL; return 1; }
  printf '%s' "$buf" | python3 "$SCRIPT_DIR/herd_parse.py" dialog --target="$target"
}

# Execute the plan: delta arrow keys + Enter, or grok digit direct selection.
# stdout: chosen option text.
# Args: pane plan  (plan = "<delta>\t<chosen>" | "key:N\t<chosen>")
# 2026-08-31: grok form "1 (●) Text" returns plan "key:N\t<chosen>".
# The digit selects AND confirms with grok; Enter afterwards types into the prompt.
dialog_answer_apply() {
  local pane="$1" plan="$2"
  local delta chosen i k
  delta="${plan%%	*}"; chosen="${plan#*	}"
  case "$delta" in
    BAR*) return 1 ;;
    key:*)
      k="${delta#key:}"
      # send-keys: one argument = one key. Two digits therefore "1 0"
      # in ONE call. Whether grok supports multi-digit selection is open — the
      # verification after selecting catches the failure (2026-08-31).
      case "$k" in
        [0-9][0-9]) herdr pane send-keys "$pane" "${k:0:1}" "${k:1:1}" >/dev/null ;;
        *)          herdr pane send-keys "$pane" "$k" >/dev/null ;;
      esac
      printf '%s' "$chosen"
      return 0
      ;;
  esac
  if [ "$delta" -gt 0 ] 2>/dev/null; then
    i=0; while [ "$i" -lt "$delta" ]; do herdr pane send-keys "$pane" down >/dev/null; sleep 0.2; i=$((i+1)); done
  elif [ "$delta" -lt 0 ] 2>/dev/null; then
    i=0; while [ "$i" -gt "$delta" ]; do herdr pane send-keys "$pane" up >/dev/null; sleep 0.2; i=$((i-1)); done
  fi
  herdr pane send-keys "$pane" enter >/dev/null
  printf '%s' "$chosen"
}

# Heuristic: backend reports idle but has reached its usage/rate limit
# (codex: "You've hit your usage limit", agy: "Individual quota reached …
# Resets in …"). The prompt was then NOT processed — for the
# orchestrator a different state than "done".
text_looks_limited() {
  dialog_relevant_lines 20 \
    | grep -qiE "hit your usage limit|usage limit reached|rate limit (reached|exceeded)|out of credits|quota (exceeded|reached)|upgrade your subscription|try again at|resets in [0-9]"
}

looks_limited() { pane_visible "$1" | text_looks_limited; }

# Heuristic: login/OAuth screen instead of the work view (agy session expires
# several times a day; prompts sent then get lost). Own state
# 'auth' instead of idle/blocked so the orchestrator does re-auth + resend.
text_looks_auth() {
  dialog_relevant_lines all \
    | grep -qiE 'sign in with google|accounts\.google\.com|log ?in (required|to continue)|please (sign|log) ?in|token exchange failed|authenticate to continue'
}

looks_auth() { pane_visible "$1" | text_looks_auth; }

# Heuristic: backend/model error, prompt not processed, agent stays
# alive at the prompt. Pattern so far only evidenced for muse ("◆ model failed:
# model stream idle timeout after 180000ms"), but formulated
# kind-independent. Own filter, not dialog_relevant_lines: that removes
# lines with a ◆ prefix (tool echoes "◆ Ran command …" should drop out),
# but would also swallow the "◆ model failed:" line.
# Hit: line that starts, after the mandatory marker ◆/•/● and whitespace, with
# "model failed:", in the last 20 visible lines.
# The marker is mandatory — marker-less prose ("model failed: …" in logs/tests)
# would otherwise be a false alarm. Window 20: a successful short
# follow-up brief can still keep an old model-failed line in the window
# (the same limit as looks_limited/looks_blocked); if needed run /clear before
# the resend.
text_looks_failed() {
  tail -n 20 | grep -qiE '^[[:space:]]*(◆|•|●)[[:space:]]+model failed:'
}

looks_failed() { pane_visible "$1" | text_looks_failed; }

# Heuristic: the agent asked a question. Convention for delegated
# briefs: write the question into a file and end the turn with the line
#   QUESTION: <absolute path>
# The marker may only stand AT THE LINE START — before it only
# whitespace and TUI frame characters (│ ┃ ║ ▏ ▕ |). A `>` (Markdown quote) or
# any other text before it does NOT count: that way a quoted old
# report, a displayed brief text and a numbered/tool-echoed
# line stay silent. Path to end of line, without trailing whitespace.
# The same exclusions as text_looks_blocked/limited: only the last 20
# visible lines, without line-number prefixes and without tool echoes (●/◆/•).
# `question` ONLY if the path is absolute AND exists as a regular file that is
# not a symlink (a marker on a link to a foreign file must not make the
# orchestrator read or move it): the orchestrator moves the answered file to <dir>/answered/,
# after which the same marker is deliberately silent again; a relative path or
# the mere placeholder path from a displayed brief text does not exist.
# The priority busy > question is established by classify_text: an agent still
# working (spinner/Working/background task) never reports question.
# KNOWN LIMIT (accepted, see SKILL.md): a standalone line at the
# line start with a real, existing path from an old report is
# indistinguishable from a new question; the flow "move first, then
# answer" prevents that in practice.
text_looks_question() {
  local path
  path="$(dialog_relevant_lines 20 \
    | sed -n 's/^[[:space:]│┃║▏▕|]*QUESTION:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
    | tail -n 1)"
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ]
}

# One classification for status (normalize_status) and classify-pane.
# stdin = visible pane text, stdout = EXACTLY ONE word:
#   blocked | limited | auth | failed | busy | background | question | clean
# in this order (blocked > limited > auth > failed > busy(kind) >
# question > clean).
# $1 = backend kind; empty = no busy (the caller looks the kind up only
# if text_looks_any_busy hit before — T128/T131).
classify_text() {
  local kind="${1:-}" buf
  buf="$(cat)"
  if   printf '%s\n' "$buf" | text_looks_blocked; then echo blocked
  elif printf '%s\n' "$buf" | text_looks_limited; then echo limited
  elif printf '%s\n' "$buf" | text_looks_auth;    then echo auth
  elif printf '%s\n' "$buf" | text_looks_failed;  then echo failed
  elif [ -n "$kind" ] && printf '%s\n' "$buf" | text_looks_busy_for_kind "$kind"; then
    # claude has only one busy pattern (background tasks, CLAUDE_BG_RE). Without
    # a running turn line the agent no longer waits by itself — own verdict,
    # so that watch reports `background` after a short deadline instead of staying silent.
    if [ "$kind" = claude ] && ! printf '%s\n' "$buf" | tail -n 25 | grep -qE "$CLAUDE_TURN_RE"; then
      echo background
    else
      echo busy
    fi
  elif printf '%s\n' "$buf" | text_looks_question; then echo question
  else echo clean
  fi
}

# Stall fingerprint for wait: visible pane content, normalized + hashed.
# WHY it is normalized: TUIs paint spinners (Braille frames U+2800-U+28FF)
# and elapsed timers ("1m 23s", "12:34", "2h 5m") that change constantly,
# even when the agent hangs — a raw hash would therefore NEVER detect a stall.
# Conservatively stripped: ONLY Braille spinners and duration values.
# ASCII spinners [|/-\] stay in (too aggressive as single-character tokens,
# hits real text; Braille is enough in practice). DELIBERATELY NOT stripped:
# token/context counters ("57.9k"), percentages, task lists — exactly that
# is the real progress signal (incident 2026-07-22: kimi-K3 hung >60 min
# with a frozen context counter, status stayed working). Hash via cksum
# (POSIX, also runs under Windows Git Bash).
# Read error → RC 1 (caller skips the comparison, no abort).
# Two layers like the looks_* heuristics (see there): text_stall_fingerprint
# normalizes TEXT on stdin, stall_fingerprint reads the pane for it. The internal
# verb `stall-fingerprint` needs the split because it must answer fingerprint,
# limited check AND failed check from ONE read.
#
# Braille NOT as a multibyte range [⠀-⣿] in sed: under LC_ALL=C.UTF-8
# (herd.sh forces that on a broken CType; sandboxes often set it) GNU sed
# aborts with "Invalid collation character" — the pipeline would then be empty
# and cksum a CONSTANT fingerprint (every long run -> stalled).
# Bytewise under LC_ALL=C: U+2800-U+28FF is UTF-8 E2 A0 80 .. E2 A3 BF.
strip_braille_bytes() {
  LC_ALL=C sed -E 's/\xe2[\xa0-\xa3][\x80-\xbf]//g'
}

# Braille spinner U+2801-U+28FF (the empty U+2800 is a spacer, not a spinner).
# The same byte class as strip_braille_bytes, without U+2800 (E2 A0 80).
text_has_braille_spinner() {
  LC_ALL=C grep -qE $'\xe2(\xa0[\x81-\xbf]|[\xa1-\xa3][\x80-\xbf])'
}

text_stall_fingerprint() {
  strip_braille_bytes | sed -E \
    -e 's/[0-9]+h[[:space:]]+[0-9]+m//g' \
    -e 's/[0-9]+m[[:space:]]+[0-9]+s//g' \
    -e 's/[0-9]+:[0-9]{2}(:[0-9]{2})?//g' \
    -e 's/[0-9]+s([^A-Za-z]|$)/\1/g' \
    | cksum
}

stall_fingerprint() {
  local buf
  buf="$(pane_recent60 "$1")" || return 1
  printf '%s' "$buf" | text_stall_fingerprint
}

# The read of stall detection: 60 lines (more than the 40 of the dialog heuristic —
# the fingerprint should also see progress further up in the pane).
pane_recent60() {
  herdr pane read "$1" --source visible --lines 60 --format text 2>/dev/null
}

# Content acceptance verification for send: is the prompt text (fixed
# marker, first ~40 characters) OR a paste placeholder visible in the pane?
# Distinguishes "text lost" (→ send text again; grok directly after start)
# from "text there, Enter fizzled" (→ Enter retry; codex buffers long prompts
# as "[Pasted Content …]" — the marker is then invisible, but the text is there).
# recent-unwrapped so soft wraps do not tear the marker apart.
prompt_arrived() {
  local buf
  buf="$(herdr pane read "$1" --source recent-unwrapped --lines 80 --format text 2>/dev/null)" || return 1
  printf '%s' "$buf" | grep -qF -- "$2" && return 0
  printf '%s' "$buf" | grep -qiE '\[?pasted (content|text)'
}

# NOTE: The former global looks_busy heuristic (pane scrape for spinner/
# generation markers as a safeguard against false herdr idle) was REMOVED after the
# measurement run 2026-07-24: with herdr 0.7.5 (official integrations/
# kind manifests for all our backends) the raw agent_status was correct in all
# transitions, while looks_busy only produced false positives
# (grok's Braille-art start logo matched the spinner class — that is why grok
# has NO Braille pattern in the busy table). The idle-before-working race right
# after send is instead cushioned by `agent prompt --wait` (in send) and the
# debounce window in the event path (in wait). False idle is handled ONLY per backend
# in text_looks_busy_for_kind, not globally.
# 2026-08-31/2026-09-02: agy (spinner, "esc to cancel", task line) and grok
# ("N command(s) still running") report idle/done during generation /
# background task — see text_looks_busy_for_kind.

# prompt_arrived with backoff: under load TUIs (especially agy) render the
# injected text into the composer only with a delay — a single scan
# then yields a false negative and the following text resend creates
# DOUBLE prompts (really observed 2026-07-13/14). Therefore up to 3 scans
# 1.5 s apart before "text lost" applies.
prompt_arrived_retry() {
  local i
  for i in 1 2 3; do
    prompt_arrived "$1" "$2" && return 0
    [ "$i" -lt 3 ] && sleep 1.5
  done
  return 1
}

# Error code from `agent prompt` stderr. Classifies the stderr of the respective
# last call. First the JSON field "code", otherwise substring match on the
# known codes (plain-text fixtures). Empty if none of the codes occurs.
prompt_err_code() {
  local f="$1" code
  [ -f "$f" ] || { printf ''; return 0; }
  code="$(grep -o '"code":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/"code":"//;s/"$//')"
  case "$code" in
    agent_blocked|pane_exited|agent_not_found|agent_prompt_stalled)
      printf '%s\n' "$code"; return 0 ;;
    ?*)
      # Code field present but unknown (e.g. timeout): trust the field,
      # do NOT scan the message for known codes → generic path.
      printf ''; return 0 ;;
  esac
  for code in agent_blocked pane_exited agent_not_found agent_prompt_stalled; do
    grep -q "$code" "$f" 2>/dev/null && { printf '%s\n' "$code"; return 0; }
  done
  printf ''
}

# Immediate abort if herdr proves that NOTHING arrived in the pane.
prompt_reject_unsent() {
  local name="$1" code="$2" perr="${3:-}"
  case "$code" in
    agent_blocked)
      echo "[herd] '$name' shows an open dialog per herdr (agent_blocked) — nothing sent." >&2
      echo "[herd]   view:     herd.sh read $name --source visible" >&2
      echo "[herd]   answer:   herd.sh answer $name \"<option text>\"  |  herd.sh key $name enter|esc" >&2
      ;;
    pane_exited)
      echo "[herd] pane of '$name' was closed during the handover (pane_exited) — prompt NOT accepted. Inventory: herd.sh list" >&2
      ;;
    agent_not_found)
      echo "[herd] agent '$name' is gone per herdr (agent_not_found) — prompt NOT accepted. Inventory: herd.sh list" >&2
      ;;
    *) return 1 ;;
  esac
  [ -n "$perr" ] && rm -f "$perr"
  exit 1
}

need_name() {
  [ -n "$1" ] || { echo "[herd] --name (or <name>) required" >&2; exit 2; }
}

# herdr's agent name rule (valid_agent_name), applied to EVERY pane/run creator
# (start, term, exec, run). Besides herdr's own check this keeps names safe
# for log paths and the batch wrapper scripts (no quotes, '$', '/', spaces).
validate_name() {
  local verb="$1" name="$2"
  if ! [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    echo "[herd] $verb: invalid name '$name' — herdr allows only a-z, 0-9, '-' and '_', starting with a-z, at most 32 characters" >&2
    exit 2
  fi
}

# HERD_AUTO_TRUST=0|1 (default 0): may herd.sh pre-trust the cwd for backends
# whose trust dialog would stop a delegated run (codex -c projects=…, grok
# ~/.grok/trusted_folders.toml, muse --trust-workspace, pi --approve)? Trusting
# loads the project's own configuration, skills and hooks — a security
# decision, hence opt-in. Exit 2 on any other value.
auto_trust_enabled() {
  case "${HERD_AUTO_TRUST:-0}" in
    0) return 1 ;;
    1) return 0 ;;
    *) echo "[herd] HERD_AUTO_TRUST must be 0 or 1 (is '${HERD_AUTO_TRUST}')" >&2; exit 2 ;;
  esac
}

# Default --poll for wait/watch (passed through to herd_events.py). Overridable
# via the env — the tests use that to run without real-time waits.
POLL_SEC="${HERD_POLL_SEC:-2}"

# Wait time between the repetitions of a failed status query.
# Real 1 s; the tests lower it so error paths do not have to run in real time.
RETRY_SEC="${HERD_RETRY_SEC:-1}"

# Validate the minutes argument: missing value, non-numeric or negative are
# usage errors and must fail loudly instead of running into an endless loop or
# an immediate timeout.
# Also used for every other integer option that reaches shell arithmetic or a
# generated script ($4 = unit for the message): bash evaluates a variable inside
# $(( )) as an expression, so 'a[$(cmd)]' would run cmd.
validate_minutes() {
  local verb="$1" opt="$2" val="${3:-}" unit="${4:-minutes}"
  case "$val" in
    ''|*[!0-9]*)
      echo "[herd] $verb: $opt requires a non-negative integer ($unit), got: '${val}'" >&2
      exit 2 ;;
    0|[1-9]*) ;;
    *)
      # Leading zero: bash computes "$((08 * 60))" octal and aborts under
      # set -e with a misleading Exit 1.
      echo "[herd] $verb: $opt must be given without a leading zero (got: '${val}')" >&2
      exit 2 ;;
  esac
}

# 2x2 grid instead of narrow strips: panes need HEIGHT, otherwise you see
# only the agent's status line. Rule: the largest pane of the target tab is
# split, direction along its longer edge — yields
# 1. agent to the right of the main window, 2. below one, 3. below the
# other column. Sets SPLIT_DIR (right|down) and SPLIT_TARGET (target pane,
# focused before the start; empty = leave the herdr default).
choose_split_placement() {
  local tab="$1"
  SPLIT_DIR="down"; SPLIT_TARGET=""
  [ -n "$tab" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local anchor placement
  anchor="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = [p for p in json.load(sys.stdin)["result"]["panes"] if p["tab_id"] == tab]
except Exception:
    sys.exit()
print(panes[0]["pane_id"] if panes else "")
' "$tab" 2>/dev/null)"
  [ -n "$anchor" ] || return 0
  placement="$(herdr pane layout --pane "$anchor" 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)["result"]["layout"]["panes"]
except Exception:
    sys.exit()
# Split the largest pane, direction along the longer edge (terminal
# cells are ~1:2, hence width vs. 2*height). Yields the 2x2 grid from every
# state: 1 pane -> to the right of it, 2 columns -> split the larger
# downward, 3 panes -> split the unsplit column downward.
best = max(panes, key=lambda p: p["rect"]["width"] * p["rect"]["height"])
r = best["rect"]
print("right" if r["width"] > 2 * r["height"] else "down", best["pane_id"])
' 2>/dev/null)"
  [ -n "$placement" ] || return 0
  SPLIT_DIR="${placement%% *}"
  SPLIT_TARGET="${placement#* }"
  return 0
}

# Create a shell pane for a new agent/terminal (herdr >= 0.7.5:
# `agent start` no longer splits itself, it needs an EXISTING pane
# at the interactive shell prompt). Chooses target tab (choose_target_tab) and
# placement (choose_split_placement) and splits specifically by pane ID —
# the focus stays untouched (the earlier necessary focus/restore dance including
# keyboard-stealing risk is gone; incident 2026-07-15 can no longer occur).
# A freshly created tab already brings an empty shell root pane —
# that is used directly instead of splitting. Sets NEW_PANE; return 1 on
# failure (message on stderr).
create_shell_pane() {
  local cwd="$1" split="$2" tab_opt="$3" max="$4" sj
  NEW_PANE=""
  # Not only HERDR_WORKSPACE_ID: the variable is missing in some panes, TAB_ID
  # and PANE_ID then carry the space prefix. Without any source ws stays empty
  # and choose_target_tab returns (as before) the herdr default.
  choose_target_tab "$max" "$(own_workspace_id || true)" "${HERDR_TAB_ID:-}" "$cwd" "$tab_opt"
  if [ -n "$TARGET_TAB_ROOT" ]; then
    NEW_PANE="$TARGET_TAB_ROOT"
    return 0
  fi
  SPLIT_DIR="down"; SPLIT_TARGET=""
  if [ -z "$split" ]; then
    choose_split_placement "${TARGET_TAB:-${HERDR_TAB_ID:-}}"
    split="$SPLIT_DIR"
  fi
  if [ -n "$SPLIT_TARGET" ]; then
    sj="$(herdr pane split "$SPLIT_TARGET" --direction "$split" --cwd "$cwd" --no-focus 2>&1)"
  else
    sj="$(herdr pane split --current --direction "$split" --cwd "$cwd" --no-focus 2>&1)"
  fi || { echo "[herd] pane split failed: $sj" >&2; return 1; }
  NEW_PANE="$(printf '%s' "$sj" | grep -o '"pane_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  [ -n "$NEW_PANE" ] || { echo "[herd] pane split: no pane_id in the reply: $sj" >&2; return 1; }
  return 0
}

# Choose the target tab for a new agent so that never more than MAX panes land
# in one tab (every agent should have enough room). Fills the current
# tab up to MAX, then existing "herd" tabs with room, otherwise a new tab.
# Sets the globals TARGET_TAB (possibly empty → herdr uses the current tab) and
# TARGET_TAB_ROOT (empty initial pane of a freshly created tab, to be closed).
choose_target_tab() {
  local max="$1" ws="$2" cur="$3" cwd="$4" explicit="$5"
  TARGET_TAB=""; TARGET_TAB_ROOT=""
  [ -n "$explicit" ] && { TARGET_TAB="$explicit"; return 0; }
  [ -n "$ws" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0   # without python3: herdr default
  local picked
  picked="$(herdr tab list --workspace "$ws" 2>/dev/null | python3 -c '
import json, sys
max_n, ws, cur = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    tabs = [t for t in json.load(sys.stdin)["result"]["tabs"] if t["workspace_id"] == ws]
except Exception:
    print("NEW"); sys.exit()
for t in tabs:                                   # current tab, if room
    if t["tab_id"] == cur and t["pane_count"] < max_n:
        print(t["tab_id"]); sys.exit()
for t in sorted((x for x in tabs                 # existing herd tab with room
                 if str(x.get("label", "")).startswith("herd") and x["pane_count"] < max_n),
                key=lambda x: x["number"]):
    print(t["tab_id"]); sys.exit()
print("NEW")
' "$max" "$ws" "$cur" 2>/dev/null)"
  if [ "$picked" = NEW ] || [ -z "$picked" ]; then
    local cj
    cj="$(herdr tab create --workspace "$ws" --cwd "$cwd" --label herd --no-focus 2>/dev/null)"
    TARGET_TAB="$(printf '%s' "$cj" | grep -o '"tab_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    TARGET_TAB_ROOT="$(printf '%s' "$cj" | grep -o '"pane_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
  else
    TARGET_TAB="$picked"
  fi
  return 0
}

# --- grok: trust cwd in advance ------------------------------------------------
# grok (from 0.2.103) shows a y/n trust dialog on the first start in an untrusted
# directory, which is invisible in the pane-read TEXT scrape (only in the
# ANSI snapshot) — a send into the dialog types the prompt as individual keys
# and sooner or later hits an 'n' ("No, quit"): the TUI exits,
# herdr deregisters the agent (incident 2026-07-18, repeated immediate
# pane deaths). Therefore the cwd is entered idempotently into
# ~/.grok/trusted_folders.toml BEFORE the start — the dialog then does not
# appear at all. Deliberate trade-off: bypasses a security gate (PERSISTENTLY,
# the entry stays in grok's file), hence only with HERD_AUTO_TRUST=1 and only
# for directories that the orchestrator explicitly passes as --cwd. Without
# it, a note on stderr if the folder is not trusted yet.
grok_trust_cwd() {
  local dir="$1" f="$HOME/.grok/trusted_folders.toml" lock="$HOME/.grok/trusted_folders.toml.lock"
  [ -n "$dir" ] || return 0
  # Canonicalize like grok (absolute path without a trailing slash).
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 0
  if ! auto_trust_enabled; then
    grep -qF "[folders.\"$dir\"]" "$f" 2>/dev/null \
      || echo "[herd] note: grok does not trust '$dir' yet and HERD_AUTO_TRUST=0 — grok shows a trust dialog that status/watch do not see; trust the folder once in grok yourself, or set HERD_AUTO_TRUST=1" >&2
    return 0
  fi
  # Quotes, backslashes and control characters would need TOML escaping in the
  # table key; skip such paths without touching the file (as codex does).
  case "$dir" in
    *'"'*|*'\'*|*[[:cntrl:]]*|*$'\177'*)
      echo "[herd] note: grok trust entry skipped for '$dir' (quote, backslash or control character in the path)" >&2
      return 0 ;;
  esac
  mkdir -p "$HOME/.grok"
  grep -qF "[folders.\"$dir\"]" "$f" 2>/dev/null && return 0
  # grok uses a .lock file; we flock on it so that a grok process or a second
  # herd.sh writing in parallel does not collide (copy + mv would otherwise lose
  # the other update). Without flock, or no lock within 2 s → leave the file alone.
  if ! command -v flock >/dev/null 2>&1; then
    echo "[herd] note: flock not available — grok trust entry for '$dir' not written; trust the folder in grok yourself" >&2
    return 0
  fi
  {
    if flock -w 2 9; then
      grok_trust_write "$dir" "$f"
    else
      echo "[herd] note: grok trust file is locked — entry for '$dir' not written" >&2
    fi
  } 9>>"$lock"
  return 0
}

# Append the trust table for $1 to $2 atomically: copy plus entry into a temp
# file next to it, then mv — a crash never leaves a half-written file. Only
# called while holding grok's lock (lost updates otherwise).
grok_trust_write() {
  local dir="$1" f="$2" tmp
  grep -qF "[folders.\"$dir\"]" "$f" 2>/dev/null && return 0
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  if { if [ -e "$f" ]; then cat "$f"; fi \
       && printf '\n[folders."%s"]\ntrusted = true\ndecided_at = %s\n' "$dir" "$(date +%s)"; } >"$tmp" \
     && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp"
  return 0
}

# Permission mode for claude/grok. Order: explicit --permission-mode option
# (start verb; as a deliberate user decision overrides BOTH roles, including
# research) > config HERD_IMPL_PERMISSION_MODE (affects ONLY --role impl —
# research stays at plan/read-only here) > role default. Background:
# hard-wired acceptEdits accepts only file edits, under
# Windows/PowerShell practically every shell command then asks for approval
# (finding 2026-07-27); shift+tab as a remote toggle does not work
# over ConPTY — the mode MUST therefore be settable at start.
perm_mode_for() {
  local role="$1" pmode="$2"
  if [ -n "$pmode" ]; then printf '%s' "$pmode"
  elif [ "$role" = research ]; then printf 'plan'
  else printf '%s' "${HERD_IMPL_PERMISSION_MODE:-acceptEdits}"
  fi
}

# pi: --model in the form provider/id -> no --provider; otherwise provider from
# HERD_PI_PROVIDER (config, NO default — otherwise Exit 2). Without model: Exit 2
# with a hint. Sets pi_provider (empty for provider/id) and pi_model.
# :thinking suffix and --effort exclude each other (pi: CLI thinking
# silently overrides the suffix — better to fail early).
#
# HERD_ prefix instead of PI_: pi exports into EVERY bash tool call the
# variables PI_PROVIDER/PI_MODEL/PI_REASONING_LEVEL (currently selected model,
# pi docs docs/environment-variables.md). Without the prefix herd.sh would
# inherit the provider of the calling pi session and --model id without '/' would
# silently run with a foreign provider instead of Exit 2.
pi_resolve() {
  local model="$1" effort="${2:-}"
  pi_provider=""
  pi_model="$model"
  case "$model" in
    */*) ;;
    "")
      echo "[herd] pi: --model or MODEL_PI required (e.g. opencode-go/deepseek-v4.1-flash; pi --list-models)" >&2
      exit 2
      ;;
    *)
      if [ -z "${HERD_PI_PROVIDER:-}" ]; then
        echo "[herd] pi: --model without a provider — specify 'provider/id' or set HERD_PI_PROVIDER (pi --list-models)" >&2
        exit 2
      fi
      pi_provider="$HERD_PI_PROVIDER"
      ;;
  esac
  case "$model" in
    *:*)
      if [ -n "$effort" ]; then
        echo "[herd] pi: either a suffix in the model or --effort" >&2
        exit 2
      fi
      ;;
  esac
}

# pi asks once for the project trust if .pi/settings.json, .pi/extensions|skills|prompts|themes,
# .pi/SYSTEM.md or .agents/skills exists in the cwd (or a parent directory) —
# the dialog would stop a delegated run. HERD_PI_PROJECT_TRUST=approve -> --approve
# (loads the project's skills/extensions/settings), ignore -> --no-approve (no
# dialog either, project resources stay unloaded). Without an explicit value the
# default follows HERD_AUTO_TRUST: approve at 1, otherwise ignore. Sets pi_trust.
pi_trust_flag() {
  local pi_default=ignore
  auto_trust_enabled && pi_default=approve
  case "${HERD_PI_PROJECT_TRUST:-$pi_default}" in
    approve) pi_trust="--approve" ;;
    ignore)  pi_trust="--no-approve" ;;
    *)
      echo "[herd] pi: HERD_PI_PROJECT_TRUST must be approve|ignore (is '${HERD_PI_PROJECT_TRUST:-}')" >&2
      exit 2 ;;
  esac
}

# --- Backend → interactive TUI start command (sets global array `cli`) -----
# Args: backend role cwd model effort resume resume_id [permission_mode] [name]
build_cli() {
  local backend="$1" role="$2" cwd="$3" model="$4" effort="$5" resume="$6" rid="$7" pmode="${8:-}" aname="${9:-}"
  cli=()
  [ -z "$model" ] && model="$(default_model_for "$backend")"   # Config default
  case "$backend" in
    codex)
      command -v codex >/dev/null || { echo "codex not in PATH" >&2; exit 127; }
      # `codex resume` accepts the same -C/-s/-m/-p/-c options (codex 0.161
      # resume --help). Pass them on resume too: otherwise --role research
      # would continue a session with its old (possibly writable) sandbox and
      # cwd/model/effort would be dropped silently (security review 2026-10-11).
      if [ "$resume" = 1 ]; then cli=(codex resume -C "$cwd"); else cli=(codex -C "$cwd"); fi
      if [ "$role" = research ]; then cli+=(-s read-only); else cli+=(-s workspace-write); fi
      [ -n "$model" ] && cli+=(-m "$model")
      # Per-model config layer (e.g. a larger context window for one model)
      [ -n "$model" ] && [ -f "${CODEX_HOME:-$HOME/.codex}/$model.config.toml" ] && cli+=(-p "$model")
      # Preempt the Codex trust dialog ("Trust this folder?") on a NEW run
      # with HERD_AUTO_TRUST=1: mark the Git toplevel of cwd as trusted for
      # this session only (-c overrides nothing persistently). Stable order:
      # after -s/-m/-p, before the effort override (tests check the built
      # command). Paths with " \ or control characters (U+0000-U+001F,
      # U+007F) are skipped — TOML escaping is not replicated here; the
      # Git repo check in `start` aborts earlier anyway if rev-parse
      # fails.
      local toplevel=""
      if [ "$resume" != 1 ] && auto_trust_enabled &&
         toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$toplevel" ]; then
        case "$toplevel" in
          *'"'*|*'\'*|*[[:cntrl:]]*|*$'\177'*) ;;
          *) cli+=(-c "projects={\"$toplevel\"={trust_level=\"trusted\"}}") ;;
        esac
      fi
      [ -n "$effort" ] && cli+=(-c "model_reasoning_effort=\"$effort\"")
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=("$rid") || cli+=(--last)
      fi
      ;;
    opencode)
      command -v opencode >/dev/null || { echo "opencode not in PATH" >&2; exit 127; }
      case "$model" in "" | */*) ;; *) [ -n "${OPENCODE_PROVIDER:-}" ] && model="${OPENCODE_PROVIDER}/$model" ;; esac
      cli=(opencode)
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(-s "$rid") || cli+=(-c)
      fi
      [ -n "$model" ] && cli+=(-m "$model")
      if [ "$role" = research ]; then cli+=(--agent plan); else cli+=(--agent build); fi
      cli+=("$cwd")
      if [ -n "$effort" ]; then
        [ "$resume" != 1 ] || { echo "[herd] opencode: --effort with --resume not supported (stored session variant takes precedence)" >&2; exit 2; }
        local oc_helper
        oc_helper="$SCRIPT_DIR/herd_opencode.py"
        command -v python3 >/dev/null || { echo "[herd] opencode --effort requires python3" >&2; exit 2; }
        python3 "$oc_helper" check "$cwd" "$model" "$effort" || exit 2
        cli=(python3 "$oc_helper" run "$cwd" "$model" "$effort" "${cli[@]}")
      fi
      ;;
    claude)
      command -v claude >/dev/null || { echo "claude not in PATH" >&2; exit 127; }
      cli=(claude --model "${model:-opus}")
      cli+=(--permission-mode "$(perm_mode_for "$role" "$pmode")")
      [ -n "$effort" ] && cli+=(--effort "$effort")
      # Recursion guard: do not orchestrate itself. --role orchestrator
      # (follow-up session that takes over the orchestration) leaves it out.
      [ "$role" = orchestrator ] || cli+=(--append-system-prompt "$SUBAGENT_LOCK")
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(-r "$rid") || cli+=(-c)
      fi
      cli+=(--add-dir "$cwd")
      ;;
    agy)
      command -v agy >/dev/null || { echo "agy not in PATH" >&2; exit 127; }
      cli=(agy --add-dir "$cwd")
      [ -n "$model" ] && cli+=(--model "$model")
      # Pass --effort through explicitly (like claude/grok). The model slug
      # (gemini-3.8-flash-high) also carries the effort; --effort is
      # the explicit variant, both may occur together.
      [ -n "$effort" ] && cli+=(--effort "$effort")
      # Mode per role: impl -> --mode accept-edits, research -> --mode plan.
      # Plan mode is read-only (replaces the earlier note that research
      # ran on prompt discipline alone). Whether plan mode ends in a plan
      # approval dialog as with kimi has not been observed yet.
      # HERD_IMPL_PERMISSION_MODE does NOT apply to agy: it carries
      # claude/grok vocabulary (acceptEdits), which agy does not know — hence
      # no perm_mode_for. An explicit --permission-mode M sets --mode M
      # for BOTH roles (same semantics as claude/grok).
      if [ -n "$pmode" ]; then
        cli+=(--mode "$pmode")
      elif [ "$role" = research ]; then
        cli+=(--mode plan)
      else
        cli+=(--mode accept-edits)
      fi
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(--conversation "$rid") || cli+=(-c)
      fi
      ;;
    copilot)
      command -v copilot >/dev/null || { echo "copilot not in PATH" >&2; exit 127; }
      cli=(copilot -C "$cwd")
      # copilot has TWO independent axes (copilot --help), hence two
      # switches instead of the earlier combined variable HERD_IMPL_COPILOT_FLAGS:
      #   work mode      --mode interactive|plan|autopilot
      #   auto approval  --yolo (= --allow-all-tools --allow-all-paths --allow-all-urls)
      # An explicit --permission-mode M sets --mode M for BOTH roles (same
      # semantics as claude/grok/agy/muse), otherwise research -> plan and impl
      # -> copilot default (asks before writes). Both combinable:
      # start ... --permission-mode autopilot --yolo.
      if [ -n "$pmode" ]; then
        cli+=(--mode "$pmode")
      elif [ "$role" = research ]; then
        cli+=(--mode plan)
      fi
      [ "${cp_yolo:-0}" = 1 ] && cli+=(--yolo)
      [ -n "$model" ]  && cli+=(--model "$model")
      [ -n "$effort" ] && cli+=(--reasoning-effort "$effort")
      # Context tier ALWAYS explicit: copilot PERSISTS the setting
      # ("overrides persisted setting" per --help). A previously set
      # long_context would otherwise silently continue to apply — and from 272k input tokens
      # the doubled long-context rate applies to the WHOLE request. Without --context
      # therefore 'default'; long context only on explicit request.
      cli+=(--context "${cp_context:-default}")
      [ -n "${cp_tier:-}" ]    && cli+=(--auto-tier "$cp_tier")
      [ -n "${cp_credits:-}" ] && cli+=(--max-ai-credits "$cp_credits")
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(-r "$rid") || cli+=(--continue)
      else
        # Session name = agent name: makes `copilot -r <name>` possible
        # without a session ID (name match exact, case-insensitive).
        cli+=(-n "$aname")
      fi
      ;;
    grok)
      command -v grok >/dev/null || { echo "grok not in PATH" >&2; exit 127; }
      grok_trust_cwd "$cwd"   # Preempt the trust dialog (text scrape does not see it)
      cli=(grok --cwd "$cwd")
      cli+=(--permission-mode "$(perm_mode_for "$role" "$pmode")")
      [ -n "$model" ] && cli+=(-m "$model")
      [ -n "$effort" ] && cli+=(--reasoning-effort "$effort")
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(-r "$rid") || cli+=(-c)
      fi
      ;;
    kimi)
      command -v kimi >/dev/null || { echo "kimi not in PATH" >&2; exit 127; }
      # kimi has no cwd flag — the working directory comes from the pane cwd
      # (pane split --cwd). --auto = auto permission mode (counterpart to
      # acceptEdits), --plan = read-only. No CLI effort flag: --effort is
      # supplied after ready via the slash command /effort low|high|max (see
      # the start branch); default otherwise from ~/.kimi-code/config.toml.
      cli=(kimi)
      if [ "$role" = research ]; then cli+=(--plan); else cli+=(--auto); fi
      [ -n "$model" ] && cli+=(-m "$model")
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(-S "$rid") || cli+=(-c)
      fi
      ;;
    muse)
      command -v muse >/dev/null || { echo "muse not in PATH" >&2; exit 127; }
      if [ "$resume" = 1 ]; then
        cli=(muse resume); [ -n "$rid" ] && cli+=("$rid") || cli+=(--last)
      else
        cli=(muse)
      fi
      # --workspace = explicit workspace root (counterpart to codex -C);
      # --trust-workspace (only with HERD_AUTO_TRUST=1) preempts the trust
      # dialog for this session without persisting anything;
      # recursion guard (do not load Claude skills incl. herdr-orchestrator):
      # persistent skill deactivation in muse — see muse_foreign_guard.
      muse_foreign_guard || exit 1
      cli+=(--workspace "$cwd")
      auto_trust_enabled && cli+=(--trust-workspace)
      [ -n "$model" ]  && cli+=(--model "$model")
      [ -n "$effort" ] && cli+=(--reasoning-effort "$effort")
      # Approval mode: explicit --permission-mode M -> --approval-mode M (muse vocabulary
      # untrusted|on-request|never; applies to BOTH roles), otherwise on-request.
      # HERD_IMPL_PERMISSION_MODE does NOT apply (claude/grok vocabulary) — as with agy.
      cli+=(--approval-mode "${pmode:-on-request}")
      # research = read-only: file tool does not write (shell remains for exploration;
      # it is sandboxed to the workspace).
      if [ "$role" = research ]; then
        cli+=(--disable-write)
      fi
      ;;
    pi)
      command -v pi >/dev/null || { echo "pi not in PATH" >&2; exit 127; }
      # pi has no cwd flag — the working directory comes from the pane cwd
      # (create_shell_pane / pane split --cwd).
      pi_resolve "$model" "$effort"
      pi_trust_flag
      cli=(pi "$pi_trust")
      [ -n "$pi_provider" ] && cli+=(--provider "$pi_provider")
      cli+=(--model "$pi_model")
      [ -n "$effort" ] && cli+=(--thinking "$effort")
      # research: --tools read,bash (bash remains writable, pi knows
      # no sandbox mode). impl: default tools, set nothing.
      if [ "$role" = research ]; then
        cli+=(--tools read,bash)
      fi
      if [ "$resume" = 1 ]; then
        [ -n "$rid" ] && cli+=(--session "$rid") || cli+=(-c)
      fi
      ;;
    *)
      echo "[herd] unknown backend: $backend (codex|agy|opencode|claude|copilot|grok|kimi|muse|pi)" >&2
      exit 2
      ;;
  esac
  return 0   # otherwise a trailing `[ -n "$x" ] && …` (false) can abort under set -e
}

# --- usage: query usage limits from TUIs --------------------------------------
# Interactively queries the current usage limits (5h and weekly windows) from the
# TUI status views of the backends (codex, grok, agy, claude, muse).
# Normalizes percentages as the remaining amount ("left").

usage_pattern_for_kind() {
  case "$1" in
    # codex >= 0.156 has no 5h window anymore -> anchor on Weekly limit:
    codex)  printf 'Weekly limit:' ;;
    grok)   printf 'Weekly limit (' ;;
    agy)    printf 'Weekly Limit Remaining' ;;
    claude) printf 'Current session' ;;
    # Rest boundary: if the string '% used · Resets' itself wraps,
    # the freshness marker does not apply (analogous to codex).
    muse)   printf '%s' '% used · Resets' ;;
    *)      printf '' ;;
  esac
}

usage_slash_for_kind() {
  case "$1" in
    codex) printf '/status' ;;
    *)     printf '/usage' ;;
  esac
}

usage_needs_esc_for_kind() {
  case "$1" in
    grok|agy|claude) return 0 ;;
    *)               return 1 ;;
  esac
}

# F4: esc cleanup on every return path
usage_close_view() {
  local pane="$1" kind="$2"
  if usage_needs_esc_for_kind "$kind"; then
    herdr pane send-keys "$pane" esc >/dev/null 2>&1 || true
  fi
}

usage_parse_pane() {
  local name="$1" kind="$2"
  python3 "$SCRIPT_DIR/herd_parse.py" usage --name="$name" --kind="$kind"
}

# H1: read pane content for usage.
# For codex and muse a /status or /usage block scrolls
# out of the visible area quickly in typical panes. Therefore read 200 lines of
# recent scrollback for codex and muse so the block is visible.
# For grok, agy and claude pane_visible suffices, since their overlays/modals are
# drawn on the visible screen.
usage_read_pane() {
  local pane="$1" kind="$2"
  case "$kind" in
    codex|muse)
      herdr pane read "$pane" --source recent --lines 200 --format text 2>/dev/null
      ;;
    agy)
      # Whole screen: without a scroll footer the quota view is not paged, and
      # since the Argon section (2026-10) it is taller than pane_visible's 40 lines.
      herdr pane read "$pane" --source visible --format text 2>/dev/null
      ;;
    *)
      pane_visible "$pane"
      ;;
  esac
}

USAGE_LAST_RAW_BUF=""
USAGE_LAST_PARSE_RC=0

USAGE_AGY_HAS_FOOTER=0

# agy: view open exactly when the key line with "esc Close" is visible in the current read.
usage_agy_view_open() {
  case "$1" in
    *"esc Close"*) return 0 ;;
    *) return 1 ;;
  esac
}

# agy: Python reconstructs pages and positions; bash drives the terminal.
# The JSON stays in memory as opaque state. Repetitions and the page
# budget computed for the first window keep their previous limits.
usage_agy_collect() {
  local pane="$1" cur_snap="$2" poll_sec="$3"
  local state="" reply a b N w budget accepted
  reply="$(printf '\n%s' "$cur_snap" | python3 "$SCRIPT_DIR/herd_parse.py" agy-collect)" || return 1
  state="${reply%%$'\n'*}"
  read -r a b N w budget USAGE_AGY_HAS_FOOTER accepted <<< "${reply#*$'\n'}"

  local scroll_steps=0 k attempt read_ok next_snap sk_out
  while [ "$USAGE_AGY_HAS_FOOTER" -eq 1 ] && [ "$b" -lt "$N" ]; do
    [ "$scroll_steps" -lt "$budget" ] || break
    local down_args=()
    for ((k=0; k<w; k++)); do down_args+=("down"); done
    if ! sk_out="$(herdr pane send-keys "$pane" "${down_args[@]}" 2>&1)"; then
      echo "[herd] usage: send-keys down failed: $sk_out" >&2
      USAGE_LAST_PARSE_RC=1
      USAGE_LAST_RAW_BUF="$(printf '%s' "$state" | python3 "$SCRIPT_DIR/herd_parse.py" agy-render --field=error && printf '.')" || return 1
      USAGE_LAST_RAW_BUF="${USAGE_LAST_RAW_BUF%.}"
      return 1
    fi
    scroll_steps=$((scroll_steps + 1))
    read_ok=0
    for ((attempt=0; attempt<4; attempt++)); do
      sleep "$poll_sec" 2>/dev/null || sleep 1
      next_snap="$(usage_read_pane "$pane" "agy")" || continue
      reply="$(printf '%s\n%s' "$state" "$next_snap" | python3 "$SCRIPT_DIR/herd_parse.py" agy-collect)" || return 1
      state="${reply%%$'\n'*}"
      read -r a b N w budget USAGE_AGY_HAS_FOOTER accepted <<< "${reply#*$'\n'}"
      if [ "$accepted" -eq 1 ]; then
        read_ok=1
        break
      fi
    done
    [ "$read_ok" -eq 1 ] || break
  done

  # Sentinel preserves trailing blank lines in bash variables too.
  buf="$(printf '%s' "$state" | python3 "$SCRIPT_DIR/herd_parse.py" agy-render --field=text && printf '.')" || return 1
  buf="${buf%.}"
  USAGE_LAST_RAW_BUF="$(printf '%s' "$state" | python3 "$SCRIPT_DIR/herd_parse.py" agy-render --field=raw && printf '.')" || return 1
  USAGE_LAST_RAW_BUF="${USAGE_LAST_RAW_BUF%.}"
  return 0
}

usage_one() {
  local name="$1" is_raw="${2:-0}"
  local pane kind pat slash_cmd buf
  USAGE_LAST_RAW_BUF=""
  USAGE_LAST_PARSE_RC=0

  pane="$(pane_id_of "$name")"
  if [ -z "$pane" ]; then
    echo "[herd] agent '$name' not found (or not in your own workspace)" >&2
    return 1
  fi

  # Dialog guard: do not type into open dialogs
  if looks_blocked "$pane"; then
    echo "[herd] '$name' shows an open selection/approval dialog — usage would type into it blindly." >&2
    echo "[herd]   view:     herd.sh read $name --source visible" >&2
    echo "[herd]   answer:   herd.sh answer $name \"<option text>\"  |  herd.sh key $name enter|esc" >&2
    return 1
  fi

  kind="$(agent_kind_of "$pane")"
  [ -n "$kind" ] || kind="$(agent_kind_of "$name")"
  kind="${kind:-unknown}"

  # F3: abort unsupported backends before sending
  case "$kind" in
    codex|grok|agy|claude|muse) ;;
    pi)
      echo "[herd] usage: backend 'pi' not supported (pi shows no quotas — check limits with the respective provider)" >&2
      return 1
      ;;
    *)
      echo "[herd] usage: backend '$kind' not supported (codex|grok|agy|claude|muse)" >&2
      return 1
      ;;
  esac

  pat="$(usage_pattern_for_kind "$kind")"
  slash_cmd="$(usage_slash_for_kind "$kind")"

  # F7: compute iterations honestly as ceil(WAIT / POLL)
  local max_wait="${HERD_USAGE_WAIT_SEC:-6}"
  local poll_sec="${HERD_USAGE_POLL_SEC:-0.5}"
  local iters
  iters="$(python3 "$SCRIPT_DIR/herd_parse.py" usage-polls --wait="$max_wait" --poll="$poll_sec" 2>/dev/null || echo 12)"

  # Baseline read before sending (G1/H1)
  local base_buf="" n0=0 base_out="" base_prc=0
  base_buf="$(usage_read_pane "$pane" "$kind")" || {
    echo "[herd] usage: pane of '$name' not readable" >&2
    return 1
  }

  # agy: baseline without an open view (R2-1). If the visible window
  # already shows an open usage view (marker: "esc Close"), we close it with esc,
  # check for errors and wait until the marker is gone.
  if [ "$kind" = "agy" ]; then
    if usage_agy_view_open "$base_buf"; then
      local esc_out
      if ! esc_out="$(herdr pane send-keys "$pane" esc 2>&1)"; then
        echo "[herd] usage: esc failed: $esc_out" >&2
        return 1
      fi
      local c=0 closed=0
      while [ "$c" -lt "$iters" ]; do
        sleep "$poll_sec" 2>/dev/null || sleep 1
        base_buf="$(usage_read_pane "$pane" "$kind")" || {
          echo "[herd] usage: pane of '$name' not readable" >&2
          return 1
        }
        if ! usage_agy_view_open "$base_buf"; then
          closed=1
          break
        fi
        c=$((c + 1))
      done
      if [ "$closed" -eq 0 ]; then
        echo "[herd] usage: old /usage view cannot be closed" >&2
        return 1
      fi
    fi
  fi

  if [ -n "$pat" ]; then
    n0="$(printf '%s\n' "$base_buf" | grep -F "$pat" 2>/dev/null | wc -l)"
  fi
  base_out="$(printf '%s\n' "$base_buf" | usage_parse_pane "$name" "$kind")" || base_prc=$?

  # Send slash command
  local prompt_rc=0
  herdr_text agent prompt "$pane" "$slash_cmd" >/dev/null 2>&1 || prompt_rc=$?

  if [ "$prompt_rc" -ne 0 ]; then
    # F4: esc cleanup on prompt error too
    usage_close_view "$pane" "$kind"
    echo "[herd] agent prompt '$slash_cmd' for '$name' failed" >&2
    return 1
  fi

  buf=""
  local i=0
  local last_out="" last_prc=1
  local fresh_ok=0
  while :; do
    local cur_read=""
    cur_read="$(usage_read_pane "$pane" "$kind")" || cur_read=""
    buf="$cur_read"

    if [ "$is_raw" -eq 1 ]; then
      if [ -n "$pat" ] && printf '%s\n' "$buf" | grep -Fq "$pat"; then
        break
      fi
      if [ "$i" -ge "$iters" ]; then
        break
      fi
      sleep "$poll_sec" 2>/dev/null || sleep 1
      i=$((i + 1))
      continue
    fi

    local hit=0
    if [ "$kind" = "agy" ]; then
      # Freshness for agy = key line with "esc Close" visible in the current read.
      if usage_agy_view_open "$cur_read"; then
        hit=1
      fi
    else
      local n=0
      if [ -n "$pat" ]; then
        n="$(printf '%s\n' "$buf" | grep -F "$pat" 2>/dev/null | wc -l)"
      fi
      if [ -n "$pat" ]; then
        if [ "$n" -gt "$n0" ] || { [ "$base_prc" -ne 0 ] && [ "$n" -gt 0 ]; }; then
          hit=1
        fi
      fi
    fi

    if [ "$kind" = "agy" ] && [ "$hit" -eq 1 ]; then
      if ! usage_agy_collect "$pane" "$cur_read" "$poll_sec"; then
        printf '%s\t%s\t5h=?\tweek=?\treset5h=?\tresetweek=?\n' "$name" "$kind"
        usage_close_view "$pane" "$kind"
        return 1
      fi
    fi

    local cur_out="" cur_prc=0
    cur_out="$(printf '%s\n' "$buf" | usage_parse_pane "$name" "$kind")" || cur_prc=$?
    last_out="$cur_out"
    last_prc="$cur_prc"
    if [ "$kind" != "agy" ]; then
      USAGE_LAST_RAW_BUF="$buf"
    fi
    USAGE_LAST_PARSE_RC="$cur_prc"

    # Freshness criterion in the poll:
    # agy: hit=1 AND parser ok.
    # Other kinds: parser ok AND ( n > n0 OR base_prc != 0 OR cur_out != base_out ) (G1/H1).
    if [ "$kind" = "agy" ]; then
      if [ "$hit" -eq 1 ]; then
        if [ "$cur_prc" -eq 0 ]; then
          fresh_ok=1
          break
        fi
        if [ "$USAGE_AGY_HAS_FOOTER" -eq 1 ]; then
          break
        fi
      fi
    else
      if [ "$cur_prc" -eq 0 ] && { [ "$n" -gt "$n0" ] || [ "$base_prc" -ne 0 ] || [ "$cur_out" != "$base_out" ]; }; then
        fresh_ok=1
        break
      fi
    fi

    if [ "$i" -ge "$iters" ]; then
      break
    fi
    sleep "$poll_sec" 2>/dev/null || sleep 1
    i=$((i + 1))
  done

  # Raw output if requested
  if [ "$is_raw" -eq 1 ]; then
    printf '%s\n' "$buf"
    usage_close_view "$pane" "$kind"
    return 0
  fi

  # G1: check freshness
  if [ "$fresh_ok" -eq 1 ]; then
    printf '%s\n' "$last_out"
    usage_close_view "$pane" "$kind"
    return 0
  fi

  # Not fresh (timeout without new output or format error)
  usage_close_view "$pane" "$kind"
  if [ "$kind" != "agy" ]; then
    USAGE_LAST_RAW_BUF="$buf"
  fi
  USAGE_LAST_PARSE_RC="$last_prc"

  if [ "$last_prc" -eq 0 ]; then
    # Was syntactically ok in the last run, but not fresh
    printf '%s\t%s\t5h=?\tweek=?\treset5h=?\tresetweek=?\n' "$name" "$kind"
    echo "[herd] usage: no new output from '$name' within ${max_wait} s (TUI not responding? Details with 'herd.sh usage --raw $name')" >&2
    return 1
  fi

  # Format not recognized
  printf '%s\n' "$last_out"
  echo "[herd] usage: format for '$name' not recognized (details with 'herd.sh usage --raw $name')" >&2
  return 1
}

# ============================================================================
cmd="${1:-}"
shift || true

case "$cmd" in
# ---------------------------------------------------------------- start -------
start)
  backend="${1:-}"; shift || true
  [ -n "$backend" ] || { echo "[herd] start <backend> required" >&2; exit 2; }
  guard_backend "$backend"
  require_herdr || exit 2

  cwd="$(pwd)"; name=""; role="impl"; model=""; effort=""; perm_mode=""
  split=""; resume=0; rid=""; timeout_min=3; do_wait=1
  # copilot-specific switches. build_cli reads them as globals (like pi_* for pi),
  # instead of widening the signature by four more positional arguments.
  cp_context=""; cp_tier=""; cp_credits=""; cp_yolo=0
  tab_opt=""; max_per_tab="${HERD_MAX_PER_TAB:-4}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="$2"; shift 2 ;;
      --role)        role="$2"; shift 2 ;;
      --cwd)         cwd="$2"; shift 2 ;;
      --model)       model="$2"; shift 2 ;;
      --effort)
        case "${2:-}" in ''|-*) echo "[herd] --effort requires a non-empty value" >&2; exit 2 ;; esac
        effort="$2"; shift 2 ;;
      --permission-mode)
        # Three edge cases, all rejected clearly with exit 2: missing value (would
        # be an ugly $2 abort under set -u), EMPTY value (would silently fall back to
        # the default and bypass the backend check below) and a
        # following flag as value ("--permission-mode --resume" would
        # swallow --resume; no permission mode starts with "-").
        case "${2:-}" in
          ''|-*) echo "[herd] start: --permission-mode requires a non-empty value (not a '-…' flag)" >&2; exit 2 ;;
        esac
        perm_mode="$2"; shift 2 ;;
      --context)
        case "${2:-}" in ''|-*) echo "[herd] start: --context requires a non-empty value (not a '-...' flag)" >&2; exit 2 ;; esac
        cp_context="$2"; shift 2 ;;
      --auto-tier)
        case "${2:-}" in ''|-*) echo "[herd] start: --auto-tier requires a non-empty value (not a '-...' flag)" >&2; exit 2 ;; esac
        cp_tier="$2"; shift 2 ;;
      --max-ai-credits)
        case "${2:-}" in ''|-*) echo "[herd] start: --max-ai-credits requires a non-empty value (not a '-...' flag)" >&2; exit 2 ;; esac
        cp_credits="$2"; shift 2 ;;
      --yolo)        cp_yolo=1; shift ;;
      --split)       split="$2"; shift 2 ;;
      --tab)         tab_opt="$2"; shift 2 ;;
      --max-per-tab) max_per_tab="$2"; shift 2 ;;
      --timeout)     timeout_min="$2"; shift 2 ;;
      --no-wait)     do_wait=0; shift ;;
      --resume)  resume=1
                 if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then rid="$2"; shift 2; else shift; fi ;;
      *) echo "[herd] start: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
  need_name "$name"
  # Check herdr's name rule (valid_agent_name) BEFORE the pane split — otherwise
  # agent start rejects with invalid_agent_name and the pane stays orphaned.
  validate_name start "$name"
  validate_minutes start --timeout "$timeout_min"
  # Space-local name collision: the same name in your OWN space blocks
  # (herdr would reject the start). The same name only in a FOREIGN
  # space is no obstacle — two sessions may independently be called
  # `rev-codex`. Without a determinable space ID no guard (no filtering).
  start_own_ws="$(resolved_own_workspace || true)"
  if [ -n "$start_own_ws" ]; then
    start_rc=0
    start_hit="$(agent_in_workspace "$name" "$start_own_ws")" || start_rc=$?
    if [ "$start_rc" -eq 0 ]; then
      start_pane="${start_hit#*	}"; start_pane="${start_pane%%	*}"
      echo "[herd] agent '$name' is already running in this space (pane ${start_pane:-?})" >&2
      exit 1
    fi
    # rc 1 = foreign only / unknown → no obstacle. rc 2 = not checkable →
    # fail-open (do not block), a note is left.
    if [ "$start_rc" -eq 2 ]; then
      note_space_once "workspace membership of '$name' not verifiable — not filtering"
    fi
  fi
  case "$role" in
    impl|research) ;;
    orchestrator)
      # Only claude knows the role lock; for other backends the
      # role would mean nothing — reject early instead of silently starting as impl.
      [ "$backend" = claude ] || { echo "[herd] start: --role orchestrator is only available with claude." >&2; exit 2; } ;;
    *) echo "[herd] --role impl|research|orchestrator (orchestrator only claude)" >&2; exit 2 ;;
  esac
  # --permission-mode only where the backend knows it — silently ignoring it would be
  # more dangerous than failing early (the user would rely on a mode
  # that was never set).
  if [ -n "$perm_mode" ]; then
    case "$backend" in
      claude|grok|agy|muse|copilot) ;;
      *) echo "[herd] start: --permission-mode is only available with claude|grok|agy|muse|copilot (codex/opencode/kimi: mode depends on --role; pi: no permission mode)." >&2; exit 2 ;;
    esac
  fi
  # copilot-specific switches: only with copilot, and with checked values. An
  # invalid argument ends copilot immediately — the pane would already be created
  # and would die silently (the same class as the codex Git repo check below).
  if [ "$backend" != copilot ]; then
    [ -z "$cp_context" ] || { echo "[herd] start: --context is only available with copilot." >&2; exit 2; }
    [ -z "$cp_tier" ]    || { echo "[herd] start: --auto-tier is only available with copilot." >&2; exit 2; }
    [ -z "$cp_credits" ] || { echo "[herd] start: --max-ai-credits is only available with copilot." >&2; exit 2; }
    [ "$cp_yolo" = 0 ]   || { echo "[herd] start: --yolo is only available with copilot (claude/grok/agy/muse: --permission-mode; codex/opencode/kimi: mode depends on --role)." >&2; exit 2; }
  else
    case "$perm_mode" in
      ''|interactive|plan|autopilot) ;;
      *) echo "[herd] start copilot: --permission-mode interactive|plan|autopilot (got: '$perm_mode'). Auto-approval is a separate axis: --yolo." >&2; exit 2 ;;
    esac
    case "$cp_context" in
      ''|default|long_context) ;;
      *) echo "[herd] start copilot: --context default|long_context (got: '$cp_context')." >&2; exit 2 ;;
    esac
    case "$cp_tier" in
      ''|efficiency|balance|intelligence) ;;
      *) echo "[herd] start copilot: --auto-tier efficiency|balance|intelligence (got: '$cp_tier'); only effective with --model auto." >&2; exit 2 ;;
    esac
    if [ -n "$cp_credits" ]; then
      case "$cp_credits" in
        *[!0-9]*) echo "[herd] start copilot: --max-ai-credits requires an integer (got: '$cp_credits')." >&2; exit 2 ;;
      esac
      # copilot rejects smaller values ("The minimum AI credit limit is 30").
      [ "$cp_credits" -ge 30 ] || { echo "[herd] start copilot: --max-ai-credits at least 30 (got: $cp_credits)." >&2; exit 2; }
    fi
  fi
  # codex refuses workspace-write outside a Git repo and exits
  # immediately — the pane dies silently and the agent registration
  # disappears ("agent target not found", observed 2026-07-14 in a scratchpad).
  # Abort early and clearly instead of failing puzzlingly.
  if [ "$backend" = codex ] && ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[herd] start codex: '$cwd' is not a Git repo — codex exits there immediately." >&2
    echo "[herd]   Remedy: set --cwd to a Git repo (or run 'git init' there)." >&2
    exit 2
  fi

  build_cli "$backend" "$role" "$cwd" "$model" "$effort" "$resume" "$rid" "$perm_mode" "$name"

  # After a herdr update without restart the server may still run with the
  # old binary. Note BEFORE pane creation (exactly one line), afterwards
  # the start continues normally — no abort, exit code unchanged.
  herdr_server_info
  if [ "$herdr_server_stale" = 1 ]; then
    echo "[herd] note: herdr server (${herdr_server_version:-?}) is running an old binary (client $(herdr_client_version)) — restart needed, update with 'herdr update --handoff'" >&2
  fi

  # Precheck of the herdr kind: does the installed herdr know this backend?
  # herdr 0.8.2 e.g. does not know muse — agent start otherwise fails only after
  # pane creation. herdr_kind_known reads agent start --help (pure CLI parsing).
  if ! herdr_kind_known "$backend"; then
    hlabel="$(herdr_version_label "$(herdr_client_version)")"
    if [ "$backend" = muse ]; then
      echo "[herd] start: herdr does not know the backend kind '$backend' (herdr agent start --kind); $hlabel. muse needs herdr with a muse manifest: preview build as of 2026-08-31 or the next stable after 0.8.2 (herdr channel set preview && herdr update)." >&2
    else
      echo "[herd] start: herdr does not know the backend kind '$backend' (herdr agent start --kind); $hlabel." >&2
    fi
    exit 2
  fi

  # Tests only (tests/run.sh): print the built start command (one argument
  # per line) instead of starting a pane — makes build_cli testable without a daemon.
  if [ "${HERD_PRINT_CLI:-}" = 1 ]; then printf '%s\n' "${cli[@]}"; exit 0; fi

  # Start path: agent = `herdr agent start` (herdr types the command itself),
  # run = `pane run` with the command from a file. Windows always uses run
  # (2026-10-02): input into a pane bash arrives there from ~170 characters only
  # at ~23 characters/s, and agent start types a Base64 PowerShell command
  # (claude with role lock: 3800 characters, ~165 s) — timeout. With
  # usr\bin\bash.exe as the herdr shell, herdr accepts the pane; with the
  # Git Bash starter it rejects it (then pane run already applied).
  start_via="${HERD_START_VIA:-auto}"; start_via_why=""
  case "$start_via" in
    auto)
      case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) start_via=run; start_via_why=" (Windows)" ;;
        *) start_via=agent ;;
      esac ;;
    agent|run) ;;
    *) echo "[herd] start: HERD_START_VIA=auto|agent|run (got: '$start_via')" >&2; exit 2 ;;
  esac

  stamp="$(date +%Y%m%d-%H%M%S)"
  log_root="$(herd_log_root)" || exit 1
  prune_logdirs "$log_root" "${HERD_LOG_KEEP_DAYS:-7}"
  prune_herd_workdirs "$cwd" "${HERD_WORKDIR_KEEP_DAYS:-14}"
  logdir="$(mktemp -d "$log_root/$stamp-$name.XXXXXX")" || { echo "[herd] start: cannot create a run directory in $log_root" >&2; exit 1; }
  startjson="$logdir/herdr-start.json"

  # Create shell pane (target tab + 2x2 grid), then start the backend in it.
  # herdr >= 0.7.5: `agent start` types the command into the pane shell (whose
  # interactive bash loads nvm — the earlier boot PATH/node problem is gone),
  # waits ITSELF for agent detection + interactive readiness and returns
  # only then. --timeout caps this (herdr cap: 300 s).
  create_shell_pane "$cwd" "$split" "$tab_opt" "$max_per_tab" \
    || { echo "[herd] start: no pane could be created" >&2; exit 1; }
  pane="$NEW_PANE"

  start_timeout=$((timeout_min * 60000)); [ "$start_timeout" -gt 300000 ] && start_timeout=300000
  started=0
  # Remember the prompt line BEFORE the first agent start — the fresh shell is at the
  # prompt. If it returns there (prompt + echo of the typed command),
  # the backend died before herdr recognized it -> immediate exit 1
  # without retry: print diagnosis, close pane, free the name.
  # Without a determinable prompt line (empty pane, read error): fail-open,
  # everything as before.
  # recent-unwrapped 400 instead of visible 40 (live finding round 2): A long
  # prompt wraps in the visible window, and a long help scrolls the echo
  # of the command out of the visible area — unwrapped the prompt is ONE
  # line, 400 lines of scrollback still contain the echo.
  # WAIT for the prompt (live finding round 3): The freshly split shell
  # is still empty after create_shell_pane (bash loads nvm; measured 2026-09-08:
  # prompt only after ~0.5 s). Reading immediately notices nothing and falls
  # into fail-open even on a healthy start — hence read for up to 5 s in 0.3 s steps
  # until a non-empty last line is there. Only then agent start.
  # Wall-clock deadline (no counter): read errors shorten nothing.
  start_prompt=""
  start_wait_deadline=$(( $(date +%s) + 5 ))
  while [ -z "$start_prompt" ] && [ "$(date +%s)" -lt "$start_wait_deadline" ]; do
    if start_pre="$(start_pane_read "$pane" 2>/dev/null)"; then
      start_prompt="$(printf '%s\n' "$start_pre" | start_prompt_line || true)"
      if [ -n "$start_prompt" ]; then break; fi
    fi
    sleep 0.3
  done
  if [ "${cli[0]}" = "$backend" ] && [ "$start_via" = agent ]; then
    for attempt in 1 2; do
      # 2 attempts: the freshly split shell may not be at the prompt yet.
      # Echo baseline per attempt (round 5): count echo lines BEFORE agent start
      # (attempt 2 takes its own) — only a command typed AFTERWARDS
      # triggers the signature. Read error/timeout -> baseline INVALID, not
      # silently 0 (round 6): 0 meant "no echoes", an old echo in the next
      # monitor read would then be "new". Invalid: early detection for THIS
      # attempt off, regular wait.
      start_echo_base=0
      start_echo_base_ok=0
      if [ -n "$start_prompt" ]; then
        if start_base_buf="$(start_pane_read "$pane" 2>/dev/null)"; then
          start_echo_base="$(printf '%s\n' "$start_base_buf" | start_echo_count "$start_prompt" || true)"
          case "$start_echo_base" in
            ''|*[!0-9]*) start_echo_base=0; start_echo_base_ok=0 ;;
            *) start_echo_base_ok=1 ;;
          esac
        fi
      fi
      # agent start runs in the background so that a backend dying immediately
      # aborts within seconds instead of only after the detection timeout.
      herdr agent start "$name" --kind "$backend" --pane "$pane" \
        --timeout "$start_timeout" -- "${cli[@]:1}" >"$startjson" 2>&1 &
      start_pid=$!
      start_waited=0
      start_rc=1
      if [ -n "$start_prompt" ] && [ "$start_echo_base_ok" = 1 ]; then
        # While agent start runs, 1 s cadence: shell back at the prompt means
        # backend dead. Read errors are harmless — the background eventually delivers
        # its result. The prompt line applies to both attempts, the baseline
        # is fresh per attempt (see above). Without a valid baseline no monitor.
        while start_bg_alive "$start_pid"; do
          sleep 1
          start_bg_alive "$start_pid" || break
          if start_buf="$(start_pane_read "$pane" 2>/dev/null)"; then
            if printf '%s\n' "$start_buf" | start_shell_back "$start_prompt" "$start_echo_base"; then
              # Client finished successfully DURING the read? Then no abort
              # (round 5) — leave the loop, shared evaluation via
              # start_reap below.
              if start_bg_alive "$start_pid"; then
                kill "$start_pid" 2>/dev/null || true
                # wait 0 after the kill: client ended successfully itself
                # (round 6, window between ps snapshot and wait) — no
                # close, no diagnosis, shared success evaluation.
                if start_reap "$start_pid"; then
                  break
                fi
                # Diagnosis from echo (round 4), then close pane: The killed
                # agent-start client would otherwise leave the start server-side "pending"
                # (name taken, rename --clear fails with agent_launch_pending)
                # — only pane close frees the name immediately. Ignore errors.
                {
                  echo "[herd] start: $backend ended before herdr recognized it — pane $pane closed, name '$name' free again. Output from the command line:"
                  # Truncate character-wise (python3 is a project prerequisite):
                  # cut would cut bytes and split in the middle of UTF-8 characters.
                  printf '%s\n' "$start_buf" | start_diagnose "$start_prompt" | python3 -c 'import sys; sys.stdin.reconfigure(errors="replace"); [print(l[:160]) for l in sys.stdin.read().splitlines()]' | sed -e 's/^/  /'
                } >&2
                herdr pane close "$pane" >/dev/null 2>&1 || true
                exit 1
              else
                break
              fi
            fi
          fi
        done
      fi
      if start_reap "$start_pid"; then
        started=1; break
      fi
      # 2026-08-31: attempt 1 may have already registered the agent and
      # still report an error (codex in the trust dialog). A retry would then
      # yield agent_name_taken with its own pane as candidate. If $name
      # is already on exactly this pane: continue, no retry, no abort.
      # agent_name_taken with a DIFFERENT pane remains the previous error path
      # (pane stays open for diagnosis) — without parsing the error text.
      if start_registered_on_pane "$name" "$pane"; then
        echo "[herd] agent start reported an error, but '$name' is already registered on pane $pane — continuing." >&2
        started=1; break
      fi
      [ "$attempt" -lt 2 ] && sleep 1.5
    done
  fi
  # Windows/ConPTY fallback: there herdr does not recognize the (git-bash) pane shell
  # as "available shell" — `agent start --pane` therefore fails hard with
  # agent_pane_busy/"not an available shell", ALTHOUGH the shell is at the prompt
  # (verified 2026-07-24: reproducible on fresh panes, independent of
  # timing/OSC-133/backend). The agent detection manifests do apply normally,
  # however, once the backend runs. So start the backend here directly via `pane run` into the
  # already created shell, wait for detection and register the recognized
  # agent under $name — afterwards everything runs as after agent start.
  if [ "$started" != 1 ] && { [ "$start_via" = run ] || [ "${cli[0]}" != "$backend" ] || grep -qi 'not an available shell\|agent_pane_busy' "$startjson"; }; then
    # agent start enforces the canonical binary name. A process wrapper
    # (OpenCode variant) therefore needs pane run plus the same detection.
    if [ "${cli[0]}" != "$backend" ]; then
      echo "[herd] starting process wrapper via pane run" >&2
    elif [ "$start_via" = run ]; then
      echo "[herd] starting $backend via pane run$start_via_why" >&2
    else
      echo "[herd] agent start: pane not recognized as an 'available shell' (Windows/ConPTY) — fallback via 'pane run'" >&2
    fi
    # As with agent start: check new command echoes against the baseline.
    run_echo_base_ok=0
    if [ -n "$start_prompt" ] && run_base_buf="$(start_pane_read "$pane" 2>/dev/null)"; then
      run_echo_base="$(printf '%s\n' "$run_base_buf" | start_echo_count "$start_prompt")"
      case "$run_echo_base" in ''|*[!0-9]*) ;; *) run_echo_base_ok=1 ;; esac
    fi
    # Command into a file, only the short invocation is typed (as with
    # exec/run): Under Windows the full command (~700 characters with
    # role lock) would otherwise take ~30 s to arrive in the pane bash.
    printf '%q ' "${cli[@]}" >"$logdir/cmd.sh"
    printf '\n' >>"$logdir/cmd.sh"
    if herdr_text pane run "$pane" "bash $(printf '%q' "$logdir/cmd.sh")" >"$startjson" 2>&1; then
      deadline=$(( $(date +%s) + start_timeout / 1000 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if herdr agent get "$pane" 2>/dev/null | grep -q '"agent":"'"$backend"'"'; then
          herdr agent rename "$pane" "$name" >/dev/null 2>&1 || true
          [ -n "$(pane_id_of "$name")" ] && { started=1; break; }
        fi
        if [ "$run_echo_base_ok" = 1 ] && start_buf="$(start_pane_read "$pane" 2>/dev/null)" &&
            printf '%s\n' "$start_buf" | start_shell_back "$start_prompt" "$run_echo_base"; then
          {
            echo "[herd] start: $backend ended before herdr recognized it — pane $pane closed. Output from the command line:"
            printf '%s\n' "$start_buf" | start_diagnose "$start_prompt" | python3 -c 'import sys; sys.stdin.reconfigure(errors="replace"); [print(l[:160]) for l in sys.stdin.read().splitlines()]' | sed -e 's/^/  /'
          } >&2
          herdr pane close "$pane" >/dev/null 2>&1 || true
          exit 1
        fi
        sleep 1
      done
    fi
    [ "$started" = 1 ] || echo "[herd] fallback via 'pane run' failed (backend not recognized/registered)" >&2
  fi
  if [ "$started" != 1 ]; then
    echo "[herd] herdr agent start failed (pane $pane stays open for diagnosis):" >&2
    cat "$startjson" >&2
    echo "[herd] note: herd.sh requires herdr >= 0.7.5 (agent start --kind/--pane); $(herdr_version_label "$(herdr_client_version)")" >&2
    exit 1
  fi
  # Keep the command file only on failure for diagnosis.
  rm -f "$logdir/cmd.sh"
  # Repaint nudge: agy sometimes renders everything twice after the start
  # (repaint/resize artifact, 2026-07-14; workaround was a pane swap). A
  # minimal resize out and back triggers two SIGWINCH → cleaner repaint.
  # Harmless for all backends; at layout edges it may fail.
  if [ -n "${pane:-}" ]; then
    herdr pane resize --direction right --amount 0.02 --pane "$pane" >/dev/null 2>&1 || true
    sleep 0.3
    herdr pane resize --direction left --amount 0.02 --pane "$pane" >/dev/null 2>&1 || true
  fi
  # grok: auto-answer the project/workspace picker after ready.
  # WHY option 1 is safe: the picker only asks whether to work in the
  # directory requested via --cwd (label typically
  # "current directory (current)") — exactly the cwd that the orchestrator
  # already set explicitly. NEVER blindly down/enter: navigation runs
  # text-based via dialog_answer_plan/apply (shared with answer).
  # The trust dialog (y/n) is preempted separately via grok_trust_cwd().
  if [ "$backend" = grok ] && [ -n "${pane:-}" ] && looks_grok_project_picker "$pane"; then
    if command -v python3 >/dev/null 2>&1; then
      # __FIRST__ = option 1 (cwd); fallback to the label substring if the parser
      # splits the list differently.
      gp_plan="$(dialog_answer_plan "$pane" "__FIRST__" 2>"$HERD_TMP/answer-opts")" || gp_plan="NOOPTS"
      case "$gp_plan" in
        NOOPTS|NOMATCH|AMBIG|BAR|BAR$'\t'*)
          gp_plan="$(dialog_answer_plan "$pane" "current directory (current)" 2>"$HERD_TMP/answer-opts")" || gp_plan="NOOPTS"
          ;;
      esac
      case "$gp_plan" in
        NOOPTS|NOMATCH|AMBIG|BAR|BAR$'\t'*)
          # Auto-answer failed → the generic dialog warning below.
          ;;
        *)
          gp_chosen="$(dialog_answer_apply "$pane" "$gp_plan")"
          gp_delta="${gp_plan%%	*}"
          case "$gp_delta" in
            key:*) echo "[herd] grok workspace picker answered automatically: '$gp_chosen' (digit ${gp_delta#key:})" >&2 ;;
            *)     echo "[herd] grok workspace picker answered automatically: '$gp_chosen' (${gp_delta#-} step(s))" >&2 ;;
          esac
          sleep 0.4
          ;;
      esac
    fi
  fi
  # kimi: --effort has no CLI flag; after ready (and after dialog checks)
  # supply via /effort low|high|max — BEFORE the user prompt arrives.
  # Send the slash command WITHOUT --wait (no lifecycle change → otherwise
  # agent_prompt_stalled false-negative, see the send path).
  if [ "$backend" = kimi ] && [ -n "${effort:-}" ]; then
    case "$effort" in
      low|high|max)
        if [ -n "${pane:-}" ] && looks_blocked "$pane"; then
          echo "[herd] WARNING: '$name' has an open dialog — /effort $effort not set; send it later" >&2
        else
          if herdr_text agent prompt "$pane" "/effort $effort" >/dev/null 2>&1; then
            echo "[herd] kimi effort set to '$effort' (/effort $effort)" >&2
          else
            echo "[herd] WARNING: /effort $effort to '$name' failed — manually: herd.sh send $name \"/effort $effort\"" >&2
          fi
        fi
        ;;
      *)
        echo "[herd] WARNING: --effort '$effort' invalid for kimi (allowed: low|high|max) — starting without /effort" >&2
        ;;
    esac
  fi
  # Some backends show a dialog right after the start (codex: update/
  # trust prompt, grok: workspace picker if the auto-answer failed) and
  # report idle while doing so — a blind send then types into the dialog. Warn
  # loudly so the orchestrator answers first.
  if [ -n "${pane:-}" ] && looks_blocked "$pane"; then
    echo "[herd] ATTENTION: '$name' shows a dialog right after start (update/trust prompt?)." >&2
    echo "[herd]   First view/answer: herd.sh read $name --source visible; herd.sh answer $name \"<option>\"" >&2
  fi
  # Pane labels (SKILL.md §12 Backends at a glance): agent panes get a
  # readable frame title "<name> · <backend>" — NOT exactly the agent name.
  # Rationale: pane_id_of resolves names also via pane labels, and
  # start_registered_on_pane as well as the pane-run start path confirm the
  # registration via pane_id_of. A label equal to the name would
  # falsely confirm this check even before registration and after the
  # agent has ended (pane remains as a shell) keep resolving the name to the shell.
  # Names contain neither spaces nor "·" (herdr rule),
  # so the label never collides with a name. Only here, once the start
  # is finally confirmed (started=1 + all rechecks); ignore errors silently,
  # exit code unchanged.
  if [ -n "${pane:-}" ]; then
    herdr pane rename "$pane" "$name · $backend" >/dev/null 2>&1 || true
  fi
  # Own orchestrator pane: set "Orchestrator" only if it is structurally
  # determined that it carries no label yet. Never overwrite an existing label;
  # without HERDR_PANE_ID, on a pane-get error or an unparseable
  # reply do nothing (pane_label_missing).
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    if own_pane_raw="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null)" && pane_label_missing "$own_pane_raw"; then
      herdr pane rename "$HERDR_PANE_ID" "Orchestrator" >/dev/null 2>&1 || true
    fi
  fi
  echo "[herd] started — backend: $backend, role: $role"
  echo "  name:  $name"
  echo "  pane:  ${pane:-?}${TARGET_TAB:+  tab: $TARGET_TAB}"
  echo "  cmd:   ${cli[*]}"
  echo "  log:   $logdir"
  echo "[herd] Send prompt: herd.sh send $name \"<text>\""
  # if form instead of "[ … ] && echo": as the last command of the branch a
  # false test would otherwise become the script's exit code (start returned 1 for non-codex).
  if [ "$backend" = codex ] && [ "$role" = impl ]; then
    echo "[herd] Tip: 'herd.sh send $name \"/permissions full\"' lets codex write without approval prompts."
  fi
  ;;

# ----------------------------------------------------------------- send -------
send)
  name="${1:-}"; shift || true
  need_name "$name"
  [ $# -gt 0 ] || { echo "[herd] send <name> <text...> | --file PATH" >&2; exit 2; }
  require_herdr || exit 2
  # --file: prompt from a file — avoids shell quoting traps (backticks, $, !)
  # with long, formatted prompts.
  if [ "$1" = "--file" ]; then
    [ -n "${2:-}" ] && [ -f "$2" ] || { echo "[herd] send --file: file missing: '${2:-}'" >&2; exit 2; }
    text="$(cat "$2")"
  else
    text="$*"
  fi
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for agent '$name'" >&2; exit 1; }
  # Marker for verifying the content actually arrived: first ~40 characters of the
  # first non-empty line. Too-short markers (< 6 characters) are too fuzzy
  # (match anywhere in the pane) → verification then disabled.
  line="$(printf '%s\n' "$text" | grep -m1 -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//')" || line=""
  marker="${line:0:40}"
  [ "${#marker}" -ge 6 ] || marker=""
  # Dialog guard: with an open approval/selection dialog the prompt would type
  # into the dialog as keystrokes and blindly hit an option (incident
  # 2026-07-24: send "/status" confirmed the codex update dialog with Enter).
  # Answer first (answer/key), then send.
  if looks_blocked "$pane"; then
    echo "[herd] '$name' shows an open selection/approval dialog — send would type into it blindly." >&2
    echo "[herd]   view:     herd.sh read $name --source visible" >&2
    echo "[herd]   answer:   herd.sh answer $name \"<option text>\"  |  herd.sh key $name enter|esc" >&2
    exit 1
  fi
  # herdr >= 0.7.5: `agent prompt` submits text + Enter atomically. Since 0.9.0
  # (#3506) a sequenced PTY op with confirmed flush boundaries (Enter
  # no longer evaporates after a long paste). --wait: if the agent does not start
  # from working, herdr demands working/blocked within 5 s, otherwise
  # agent_prompt_stalled. Tracks no turns: send_accepted does NOT take a
  # continuous working as proof for this send (T32).
  # herdr proof of non-acceptance on the first call → immediate exit 1:
  # agent_blocked, pane_exited, agent_not_found; on resend
  # agent_blocked runs into the final check. Otherwise correlation, possibly 75.
  # Slash commands without --wait. On stalled first recheck the marker, only
  # on loss ONE resend; text without a turn → one Enter nudge (stderr).
  case "$text" in /*) is_slash=1 ;; *) is_slash=0 ;; esac
  if [ "$is_slash" = 1 ]; then
    # Pane ID instead of name: on a name collision across spaces, agent prompt
    # would otherwise hit the global get result, not necessarily its own.
    herdr_text agent prompt "$pane" "$text" >/dev/null \
      || { echo "[herd] agent prompt failed — check herd.sh read $name --source visible" >&2; exit 1; }
    echo "[herd] slash command sent to $name (pane $pane). If it opens a dialog/picker:"
    echo "[herd]   view: herd.sh read $name --source visible; answer: herd.sh answer $name \"<option>\" | key $name enter|esc"
    exit 0
  fi
  # Capture PRE-STATE to be able to CORRELATE acceptance later.
  # Without it a 'working' after the send proves nothing: if the agent was already
  # busy before, a completely failed send looks the same as a successful one
  # — and the orchestrator waits for a brief that was
  # never accepted.
  agent_status_probe "$name"
  pre_status="$PROBE_STATUS"; pre_seq="$PROBE_SEQ"
  pre_kind="${PROBE_KIND:-?}"

  # Does a state change prove that EXACTLY THIS send arrived?
  # Conclusive is a changed generation (state_change_seq) or a
  # change out of an idle state. A continuous working does NOT count.
  send_accepted() {
    agent_status_probe "$name"
    [ -n "$PROBE_SEQ" ] && [ -n "$pre_seq" ] && [ "$PROBE_SEQ" != "$pre_seq" ] && return 0
    case "$pre_status" in
      working|blocked) return 1 ;;   # was already active → no proof derivable
    esac
    case "$PROBE_STATUS" in
      working|blocked) return 0 ;;
    esac
    return 1
  }

  taken=0; perr="$HERD_TMP/prompt-err"
  if herdr_text agent prompt "$pane" "$text" \
       --wait --until working --until blocked --until idle --until done \
       --timeout 15000 >/dev/null 2>"$perr"; then
    taken=1
  else
    pec="$(prompt_err_code "$perr")"
    case "$pec" in
      agent_blocked|pane_exited|agent_not_found)
        prompt_reject_unsent "$name" "$pec" "$perr" ;;
      agent_prompt_stalled)
        # No observed status change. Recheck the content before a
        # resend creates DUPLICATE prompts (agy renders delayed under load).
        if [ -n "$marker" ] && prompt_arrived_retry "$pane" "$marker"; then
          # Text is in the pane, but no turn started: with claude the
          # atomic Enter from `agent prompt` evaporates after the paste (E2E 2026-07-24) —
          # the prompt hangs unsubmitted in the composer. ONE Enter nudge submits;
          # if the turn was in fact already through (echo in the transcript, composer
          # empty), the Enter is ineffective. Then briefly re-poll the status.
          echo "[herd] send: text in pane, no turn — enter nudge (kind=$pre_kind; herdr>=0.9.0 should no longer need this, please report the case as a finding)" >&2
          herdr agent send-keys "$pane" enter 2>/dev/null || true
          i=0
          while [ "$i" -lt 15 ]; do
            st="$(agent_status_of "$name")"
            case "$st" in working|blocked) taken=1; break ;; esac
            i=$((i + 1)); sleep 0.4
          done
          [ "$taken" = 1 ] || echo "[herd] enter nudge sent — no status change observed (possibly already done)" >&2
        else
          echo "[herd] prompt not accepted (agent_prompt_stalled) — send again" >&2
          if herdr_text agent prompt "$pane" "$text" --wait --timeout 15000 >/dev/null 2>"$perr"; then
            taken=1
          else
            pec="$(prompt_err_code "$perr")"
            case "$pec" in
              pane_exited|agent_not_found)
                prompt_reject_unsent "$name" "$pec" "$perr" ;;
            esac
            # agent_blocked on resend: the first prompt probably opened a
            # dialog → final check (looks_blocked = accepted).
          fi
        fi
        ;;
      *)
        # Error from `agent prompt` that reports NO acceptance problem (transport,
        # protocol, herdr's own timeout). Previously this silently ran into the
        # warning logic and ended with exit 0.
        #
        # BUT: do not blindly abort hard. The error does not prove that nothing
        # arrived — the connection may have been dropped AFTER the side effect, and
        # herdr's timeout text does not guarantee agent_prompt_stalled. Therefore first
        # the same recheck as below; only if that also finds nothing is it
        # a hard error. Otherwise we would have broken a previously working case
        # (finding from the cross-review).
        hard_err="$(cat "$perr" 2>/dev/null || true)"
        rm -f "$perr"
        if send_accepted; then
          echo "[herd] WARNING: 'agent prompt' reported an error, but the prompt demonstrably arrived:" >&2
          printf '%s\n' "$hard_err" | sed 's/^/[herd]   /' >&2
          taken=1
        else
          # NO hard exit 1: that the error occurred BEFORE the side effect is
          # not derivable from a generic transport error — the connection
          # may also have been dropped after sending. A renewed send could
          # then create a duplicate brief. So 75 (unclear) instead of 1,
          # unless the text demonstrably did not even land in the pane.
          echo "[herd] send to '$name': 'agent prompt' failed, no acceptance provable:" >&2
          printf '%s\n' "$hard_err" | sed 's/^/[herd]   /' >&2
          if [ -n "$marker" ] && ! prompt_arrived_retry "$pane" "$marker"; then
            echo "[herd]   text is not in the pane either — prompt NOT accepted." >&2
            exit 1
          fi
          echo "[herd]   state UNCLEAR — check before observing: herd.sh read $name --source visible" >&2
          exit 75
        fi
        ;;
    esac
  fi
  rm -f "$perr" 2>/dev/null || true
  # Final recheck — CORRELATED (see send_accepted): a continuous
  # working proves nothing, a changed generation does. A dialog newly opened by
  # the prompt also counts as accepted.
  if [ "$taken" = 0 ]; then
    if send_accepted; then
      taken=1
    elif [ "$pre_status" != blocked ] && looks_blocked "$pane"; then
      taken=1
    fi
  fi
  if [ "$taken" = 1 ]; then
    echo "[herd] sent to $name (pane $pane). Wait: herd.sh wait $name"
  else
    # UNCERTAIN, not "failed": an agent finishing in a flash may
    # already be idle again — a hard error would be a false positive here.
    # But exit 0 would be just as wrong: for an LLM caller a
    # stderr warning is indistinguishable from success, and a watcher armed afterwards
    # reports the OLD idle state as the result. Therefore a separate
    # code (75, EX_TEMPFAIL): "state unclear — check first, then wait."
    if [ -n "$marker" ] && prompt_arrived "$pane" "$marker"; then
      echo "[herd] UNCERTAIN: text arrived in '$name', but no processing status recognizable." >&2
      echo "[herd]           Probably already done — check: herd.sh read $name --source visible" >&2
    else
      echo "[herd] UNCERTAIN: '$name' may NOT have accepted the prompt (status: ${st:-?})." >&2
      echo "[herd]           Check: herd.sh read $name --source visible; if needed herd.sh key $name enter" >&2
    fi
    echo "[herd]           Clarify first, THEN observe — otherwise the watcher waits for work that never began." >&2
    exit 75
  fi
  ;;

# --------------------------------------------------------------- status -------
# Immediate state poll without blocking: outputs working|idle|done|blocked|
# limited|auth|failed|question (one line, exit 0; unknown agent → exit 1). For
# orchestrator loops over multiple panes — `wait --timeout 1` blocks 1 s per
# agent and its exit code is indistinguishable from errors.
status)
  name="${1:-}"; shift || true
  need_name "$name"
  require_herdr || exit 2
  # Use error classes: a daemon failure would otherwise be reported as "agent
  # not found" — misleading, since the probe distinguishes them.
  agent_status_probe "$name"
  case "$PROBE_STATE" in
    not_found)   echo "[herd] agent '$name' not found" >&2; exit 1 ;;
    unavailable) echo "[herd] herdr does not respond — state of '$name' UNKNOWN" >&2; exit 2 ;;
  esac
  st="$PROBE_STATUS"
  pane="${PROBE_PANE:-$(pane_id_of "$name")}"
  # Rechecks for states herdr does not know (dialog/limit/login/model error):
  # shared normalization with wait/watch — see normalize_status.
  st="$(normalize_status "$st" "$pane" "${PROBE_KIND:-}")"
  echo "$st"
  ;;

# --------------------------------------------------------------- answer -------
# Answers a selection dialog SAFELY by option TEXT (see
# dialog_answer_plan/apply — shared with the grok picker auto-answer in start).
answer)
  name="${1:-}"; shift || true
  need_name "$name"
  [ $# -gt 0 ] || { echo "[herd] answer <name> <option text>" >&2; exit 2; }
  target="$*"
  require_herdr || exit 2
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for agent '$name'" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "[herd] answer requires python3" >&2; exit 2; }
  # Isolated per call: parallel answers must not overwrite each other's
  # options or dialog identities.
  answer_opts="$(mktemp "${TMPDIR:-/tmp}/herd-answer-opts.XXXXXX")" || { echo "[herd] answer: temporary file cannot be created" >&2; exit 1; }
  plan="$(dialog_answer_plan "$pane" "$target" 2>"$answer_opts")" || true
  # Only the first line: scrollback on stdout must never count as a plan
  # (2026-08-17: answer printed pane text and ended with exit 0).
  plan="${plan%%$'\n'*}"
  case "$plan" in
    READFAIL)
      echo "[herd] answer: pane not readable — no silent success." >&2
      echo "[herd]   view:     herd.sh read $name --source visible" >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
    NOOPTS)
      echo "[herd] answer: no selection dialog recognizable in the pane — check read $name --source visible" >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
    NOMATCH|AMBIG)
      [ "$plan" = NOMATCH ] \
        && echo "[herd] answer: '$target' matches no option. Options found:" >&2 \
        || echo "[herd] answer: '$target' is ambiguous. Options found:" >&2
      sed 's/^OPT\t/[herd]   /' "$answer_opts" >&2
      exit 1 ;;
  esac
  if [[ "$plan" == BAR$'\t'* ]]; then
    bar_opts_str="${plan#BAR$'\t'}"
    IFS=$'\t' read -r -a opts <<< "$bar_opts_str"
    rc=0
    ansi_buf="$(read_visible_pane_ansi "$pane")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$ansi_buf" ]; then
      echo "[herd] answer: pane not readable — no silent success." >&2
      echo "[herd]   view:     herd.sh read $name --source visible" >&2
      echo "[herd]   Workaround: herd.sh key $name enter" >&2
      exit 1
    fi
    cur_opt="$(answer_bar_marked_option "$ansi_buf" "${opts[@]}")"
    if [ "$cur_opt" = "NOMARK" ] || [ -z "$cur_opt" ]; then
      echo "[herd] answer: selection not recognizable — key $name enter selects the default" >&2
      exit 1
    fi
    : > "$answer_opts"
    for opt in "${opts[@]}"; do
      if [ "$opt" = "$cur_opt" ]; then
        printf 'OPT\t*\t%s\n' "$opt" >> "$answer_opts"
      else
        printf 'OPT\t \t%s\n' "$opt" >> "$answer_opts"
      fi
    done
    match_res="$(python3 "$SCRIPT_DIR/herd_parse.py" bar-match --target="$target" -- "${opts[@]}")"
    case "$match_res" in
      NOMATCH|AMBIG)
        [ "$match_res" = NOMATCH ] \
          && echo "[herd] answer: '$target' matches no option. Options found:" >&2 \
          || echo "[herd] answer: '$target' is ambiguous. Options found:" >&2
        sed 's/^OPT\t/[herd]   /' "$answer_opts" >&2
        exit 1 ;;
    esac
    target_idx="${match_res%%$'\t'*}"
    chosen="${match_res#*$'\t'}"
    cur_idx=0
    for ((i=0; i<${#opts[@]}; i++)); do
      if [ "${opts[i]}" = "$cur_opt" ]; then
        cur_idx=$i
        break
      fi
    done
    n="${#opts[@]}"
    steps=$(( (target_idx - cur_idx) % n ))
    [ "$steps" -lt 0 ] && steps=$(( steps + n ))
    if [ $(( 2 * steps )) -gt "$n" ]; then
      direction="left"
      count=$(( n - steps ))
    else
      direction="right"
      count=$steps
    fi
    if [ "$count" -gt 0 ]; then
      keys=()
      for ((i=0; i<count; i++)); do keys+=("$direction"); done
      herdr pane send-keys "$pane" "${keys[@]}" >/dev/null
      # Briefly wait before the verification read: the TUI draws the new
      # marker only after the key press (live 2026-09-09: reading immediately
      # still saw the old selection -> "verification failed").
      sleep "${HERD_ANSWER_VERIFY_SEC:-0.4}"
      rc=0
      ansi_verify="$(read_visible_pane_ansi "$pane")" || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$ansi_verify" ]; then
        echo "[herd] answer: verification not readable — no silent success." >&2
        exit 1
      fi
      ver_opt="$(answer_bar_marked_option "$ansi_verify" "${opts[@]}")"
      if [ "$ver_opt" != "$chosen" ]; then
        echo "[herd] answer: verification failed — target '$chosen' not marked." >&2
        exit 1
      fi
    else
      # count == 0: the target option was already preselected (and was verified in the
      # first ANSI read). No navigation needed.
      :
    fi
    herdr pane send-keys "$pane" enter >/dev/null
    sleep "${HERD_ANSWER_VERIFY_SEC:-0.4}"
    rc=0
    post_buf="$(read_visible_pane "$pane")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$post_buf" ]; then
      echo "[herd] answer: verification not readable — no silent success." >&2
      exit 1
    fi
    post_check="$(printf '%s' "$post_buf" | python3 "$SCRIPT_DIR/herd_parse.py" bar-check -- "${opts[@]}")" || post_check="FAIL"

    case "$post_check" in
      SAME)
        echo "[herd] answer: dialog is still there after selecting — not confirmed." >&2
        exit 1 ;;
      FOLLOW$'\t'*)
        followup_dialog="${post_check#FOLLOW$'\t'}"
        echo "[herd] answer: '$chosen' selected ($count step(s) $direction) and confirmed — follow-up dialog open: $followup_dialog"
        exit 0 ;;
      GONE)
        echo "[herd] answer: '$chosen' selected ($count step(s) $direction) and confirmed."
        exit 0 ;;
      *)
        echo "[herd] answer: verification not readable — no silent success." >&2
        exit 1 ;;
    esac
  fi
  delta="${plan%%	*}"
  case "$plan" in
    *$'\t'*) ;;
    *)
      echo "[herd] answer: dialog format not recognized — no silent success." >&2
      echo "[herd]   view:     herd.sh read $name --source visible" >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
  esac
  case "$delta" in
    key:*)
      k="${delta#key:}"
      case "$k" in
        [0-9]|[0-9][0-9]) ;;
        *)
          echo "[herd] answer: dialog format not recognized — no silent success." >&2
          echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
          exit 1 ;;
      esac
      ;;
    ''|*[!0-9-]*|-)
      echo "[herd] answer: dialog format not recognized — no silent success." >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
  esac
  old_identity="$(sed -n 's/^IDENTITY\t//p' "$answer_opts")"
  answer_kind="$(agent_kind_of "$pane")"
  chosen="$(dialog_answer_apply "$pane" "$plan")"
  # After choosing, verify that the dialog is really gone.
  # Otherwise the caller takes exit 0 for "answered" and waits for
  # work that never begins (2026-08-17).
  sleep "${HERD_ANSWER_VERIFY_SEC:-0.4}"
  post="$(dialog_answer_plan "$pane" "$target" 2>"$answer_opts")" || true
  new_identity="$(sed -n 's/^IDENTITY\t//p' "$answer_opts")"
  post="${post%%$'\n'*}"
  if [ "$answer_kind" = claude ] && [ -n "$old_identity" ] &&
     [ -n "$new_identity" ] && [ "$old_identity" != "$new_identity" ]; then
    echo "[herd] answer: '$chosen' selected and confirmed — follow-up dialog open; check with read $name --source visible."
    exit 0
  fi
  case "$post" in
    READFAIL|"")
      echo "[herd] answer: verification not readable — no silent success." >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
    NOOPTS) ;;
    *)
      echo "[herd] answer: dialog is still there after selecting — not confirmed." >&2
      echo "[herd]   Workaround: herd.sh key $name <digit>  (e.g. key $name 2)" >&2
      exit 1 ;;
  esac
  case "$delta" in
    key:*) echo "[herd] answer: '$chosen' selected (digit ${delta#key:}) and confirmed." ;;
    *)     echo "[herd] answer: '$chosen' selected (${delta#-} step(s)) and confirmed." ;;
  esac
  ;;

# ----------------------------------------------------------------- wait -------
# Waits for an idle state of the agent and PRINTS THE STATUS. Default target
# is "settled" = idle|blocked|done|limited|auth|failed|question, because `blocked`
# (approval/slash prompt) means the agent is waiting for YOU — just as much
# a return point as idle; limited/auth/failed mean "prompt lost".
# With --status X it waits specifically for X. Exit 0 = target reached,
# exit 1 = timeout. On `blocked` a hint to read/key.
# Stall detection (--stall-timeout MIN, default 15, 0 = off): as long as the
# status is `working`, the event watcher compares the visible
# pane content as a normalized fingerprint (spinner/timer are stripped,
# see stall_fingerprint). If the fingerprint stays unchanged over the full stall time,
# the run counts as a silent hang → output `stalled`, exit 0
# (like blocked/limited/failed). Every fingerprint change OR every
# status change away from `working` resets the stall clock — long, active
# runs must not trigger. Active also for --status waits as long as the
# observed status is `working`.
wait)
  name="${1:-}"; shift || true
  need_name "$name"
  target="settled"; timeout_min=30; stall_timeout=15
  while [ $# -gt 0 ]; do
    case "$1" in
      # shift pattern: if the value is missing, `shift 2` under `set -e` would end the script
      # with exit 1 — a usage error would then look like a real error.
      # Therefore shift one at a time and let the empty value be validated.
      --status)        target="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --timeout)       timeout_min="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --stall-timeout) stall_timeout="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) echo "[herd] wait: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
  validate_minutes wait --timeout "$timeout_min"
  validate_minutes wait --stall-timeout "$stall_timeout"
  [ -n "$target" ] || { echo "[herd] wait: --status requires a value" >&2; exit 2; }
  # A status never begins with '-'. Otherwise `--status --x` would be a target.
  case "$target" in
    -*) echo "[herd] wait: --status expects a status, not an option ('$target')" >&2
        exit 2 ;;
  esac
  validate_watch_engine wait
  require_herdr || exit 2
  # Input errors early, BEFORE the engine choice: an unknown name is exit 1
  # regardless of whether the event API is currently reachable (T135h).
  agent_status_probe "$name"
  case "$PROBE_STATE" in
    not_found)   echo "[herd] agent '$name' not found" >&2; exit 1 ;;
    unavailable) echo "[herd] 'wait' requires a running herdr" >&2; exit 2 ;;
  esac
  choose_watch_engine wait
  HERD_OWN_WORKSPACE="$(resolved_own_workspace || true)"
  export HERD_OWN_WORKSPACE
  # exec skips the EXIT trap — remove the private scratch directory by hand.
  rm -rf "$HERD_TMP"
  if [ "$target" = settled ]; then
    exec python3 "$EVENTS_PY" wait "$name" \
         --timeout "$timeout_min" --stall-timeout "$stall_timeout" \
         --poll "$POLL_SEC"
  else
    exec python3 "$EVENTS_PY" wait "$name" \
         --timeout "$timeout_min" --stall-timeout "$stall_timeout" \
         --poll "$POLL_SEC" --status "$target"
  fi
  ;;

# ---------------------------------------------------------------- watch -------
# Long-lived event stream over ARBITRARILY MANY agents. Unlike `wait`
# watch does NOT end at the first event — precisely on that the orchestrator failed
# on 2026-07-26: a one-shot watcher leaves all remaining agents
# blind once it has fired, and after a timeout none at all.
#
# stdout: one line "<name> <status>" per state change — flushed line by line
# and thus directly usable as a monitor command (each line becomes
# a notification there).
# stderr: action instruction for the respective state (explain_status).
#
# Ends only when ALL observed agents are terminal (lost, or
# idle/done after the quiet window) — or after --max-events.
# blocked/limited/auth/failed/question are NOT terminal: the agent keeps working
# after the answer, and exactly this continuation is what watch should still report.
#
# Only the event path remains (scripts/herd_events.py). This verb checks the
# input completely and then execs the watcher.
# HERD_WATCH_ENGINE=auto|events (identical); poll -> exit 2 (stage 4).
# If the event API is missing, watch ends with exit 2 (herdr >= 0.8.2, python3).
watch)
  names=(); stall_timeout=15; max_events=0; timeout_min=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stall-timeout) stall_timeout="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --poll)          POLL_SEC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --max-events)    max_events="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --timeout)       timeout_min="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      -*) echo "[herd] watch: unknown option '$1'" >&2; exit 2 ;;
      *)  names+=("$1"); shift ;;
    esac
  done
  [ "${#names[@]}" -gt 0 ] || { echo "[herd] watch <name...> — at least one agent" >&2; exit 2; }
  validate_minutes watch --stall-timeout "$stall_timeout"
  validate_minutes watch --timeout "$timeout_min"
  case "$max_events" in ''|*[!0-9]*) echo "[herd] watch: --max-events requires an integer" >&2; exit 2 ;; esac
  validate_watch_engine watch
  # Duplicate names would observe the same agent twice.
  for n in "${names[@]}"; do
    dup=0
    for m in "${names[@]}"; do [ "$m" = "$n" ] && dup=$((dup + 1)); done
    [ "$dup" -le 1 ] || { echo "[herd] watch: agent '$n' given more than once" >&2; exit 2; }
  done
  require_herdr || exit 2

  # Input errors early: a name that NEVER existed is a typo and
  # not an event. (If an agent disappears later, that is 'lost'.)
  for n in "${names[@]}"; do
    agent_status_probe "$n"
    case "$PROBE_STATE" in
      not_found)   echo "[herd] agent '$n' not found" >&2; exit 1 ;;
      unavailable) echo "[herd] 'watch' requires a running herdr" >&2; exit 2 ;;
    esac
  done

  # Here the input is COMPLETELY checked: options (exit 2), duplicate
  # names, running herdr and "never seen agent" (exit 1). Only then the
  # API check — so the usage-error contracts hold regardless of whether
  # the event API is currently reachable.
  choose_watch_engine watch
  # exec, not a subprocess: ONE process for the whole observation. A
  # bash parent would have to forward signals, pass through the exit code
  # and would buffer the line-by-line message stream —
  # effort without value (plan, design decision 6).
  # The EFFECTIVE values are passed through instead of the raw argv: the
  # defaults (--stall-timeout 15, --timeout 0, --max-events 0) and the
  # env override HERD_POLL_SEC live HERE, not in Python.
  # Pass the space boundary into the event path. Otherwise snapshot_agents makes
  # a global agent.get and can subscribe to the foreign pane on a name collision
  # (cross-review 2026-08-18).
  HERD_OWN_WORKSPACE="$(resolved_own_workspace || true)"
  export HERD_OWN_WORKSPACE
  # After an exec the EXIT trap no longer cleans up (the process is
  # replaced) — so delete the private scratch directory by hand,
  # otherwise one corpse remains in the temp directory per observation run.
  rm -rf "$HERD_TMP"
  exec python3 "$EVENTS_PY" watch "${names[@]}" \
       --stall-timeout "$stall_timeout" --timeout "$timeout_min" \
       --poll "$POLL_SEC" --max-events "$max_events"
  ;;

# ------------------------------------------------------- INTERNAL VERBS -------
# For the event watcher scripts/herd_events.py only (step C from
# docs/plan-watch-events.md). The watcher runs in Python, the
# pane heuristics (looks_blocked/looks_limited/looks_auth/looks_failed, stall_fingerprint)
# and the action instructions (explain_status) stay here: a copy in
# Python would be a SECOND source of truth that diverges with every new backend dialog
# (plan, design decisions 2 and 3).
#
# These verbs are deliberately narrow and stateless: one argument in, one
# line (or two) out, exit != 0 on read error. The watcher turns this into
# `on_command_failed` and repeats or reports the finding — therefore an
# unreadable pane must NEVER pass here as inconspicuous. They touch no
# other verb branch and deliberately do not appear in usage().
classify-pane)
  pane=""; kind_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)
        kind_opt="${2:-}"; shift
        [ $# -gt 0 ] && shift ;;
      *)
        [ -z "$pane" ] && pane="$1"
        shift ;;
    esac
  done
  [ -n "$pane" ] || { echo "[herd] classify-pane <pane_id> [--kind KIND]" >&2; exit 2; }
  # EXACTLY ONE pane read, then all pattern lists against THIS text (the checkers
  # text_looks_* share their patterns with looks_*, see there). Multiple own reads
  # would be two error sources: a read error AFTER the first read would look like
  # "no pattern found" and would become `clean` — that is, a
  # confirmed completion for a pane that can no longer be read
  # (herd_state.py: "ERRORS ARE NOT clean") — and multiple reads could
  # classify different pane states. The kind query is an
  # additional RPC only after the cheap busy precheck (--kind saves it).
  # `-r` (exit != 0 only on read error) would be too weak here: the verb MUST
  # distinguish between "read and inconspicuous" and "not read".
  buf="$(herdr pane read "$pane" --source visible --lines 40 --format text 2>/dev/null)" \
    || { echo "[herd] classify-pane: pane '$pane' not readable" >&2; exit 1; }
  # Kind RPC only after a busy pre-hit, if --kind is missing (T128/T131).
  if [ -z "$kind_opt" ] && printf '%s\n' "$buf" | text_looks_any_busy; then
    kind_opt="$(agent_kind_of "$pane")"
  fi
  printf '%s\n' "$buf" | classify_text "$kind_opt"
  ;;

stall-fingerprint)
  pane="${1:-}"
  [ -n "$pane" ] || { echo "[herd] stall-fingerprint <pane_id>" >&2; exit 2; }
  # Like classify-pane: EXACTLY ONE read for ALL statements. A second read for
  # the limited/failed check could fail and return "limited no"/"failed no"
  # — that is "no limit/error" instead of "not read".
  buf="$(pane_recent60 "$pane")" \
    || { echo "[herd] stall-fingerprint: pane '$pane' not readable" >&2; exit 1; }
  fp="$(printf '%s' "$buf" | text_stall_fingerprint)"
  [ -n "$fp" ] \
    || { echo "[herd] stall-fingerprint: empty fingerprint for '$pane'" >&2; exit 1; }
  # THREE output lines, because the watcher needs everything in ONE call: the
  # fingerprint for the stall clock, the limited check (self-retry stays
  # working) and the failed check (model error with raw working, analogous).
  # The fingerprint may contain spaces (cksum returns "<hash> <bytes>") —
  # therefore it is at the LINE END and not in a field in between.
  echo "fp $fp"
  # `tail -40` narrows the 60-line buffer (effectively 20 without line numbers
  # via the prefilter in text_looks_limited; text_looks_failed
  # tails another 20 itself).
  if printf '%s\n' "$buf" | tail -40 | text_looks_limited
  then echo "limited yes"; else echo "limited no"; fi
  if printf '%s\n' "$buf" | tail -40 | text_looks_failed
  then echo "failed yes"; else echo "failed no"; fi
  ;;

explain-status)
  name="${1:-}"; st="${2:-}"
  [ -n "$name" ] && [ -n "$st" ] \
    || { echo "[herd] explain-status <name> <status>" >&2; exit 2; }
  # No herdr contact, no output on stdout: explain_status writes
  # exclusively to stderr. Thus wait/watch and the
  # event watcher speak the same language without duplicating the texts.
  # A state WITHOUT an action instruction (idle/done/working/monitor-restored) is
  # NO error: there is nothing to do there, the report line on stdout is the
  # whole message. Exit remains 0, stdout remains empty.
  # wait-timeout: the three hint lines; $3 = minutes, $4 = last status.
  explain_status "$name" "$st" "${3:-}" "${4:-}"
  ;;

# ----------------------------------------------------------------- list -------
# Inventory: which agents are running right now? After a context compaction
# the orchestrator would otherwise no longer know whom it still has to observe.
list)
  all_spaces=0; sessions=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all-spaces) all_spaces=1; shift ;;
      --sessions) sessions=1; shift ;;
      *) echo "[herd] list: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
  require_herdr || exit 2
  # Parse JSON instead of grepping: the agent objects are nested
  # (agent_session), the field order is not guaranteed, and foreign
  # sessions (including the orchestrator itself) have no "name" at all — a
  # line regex reliably returns the wrong thing here.
  # Output only NAMED agents: those are the ones started by herd.sh.
  # Additionally (unless --all-spaces): only your own space. Without a determinable
  # space ID do not filter — a falsely empty inventory is more dangerous.
  command -v python3 >/dev/null 2>&1 || {
    echo "[herd] 'list' requires python3" >&2; exit 2; }
  # Errors MUST be loud: list is the restart source after a
  # context compaction. A silent empty output with exit 0 would read as
  # "no agents running" — and the orchestrator would end a workflow
  # whose agents in truth keep running.
  raw="$(herdr agent list 2>/dev/null)" || {
    echo "[herd] 'list': herdr agent list failed — inventory UNKNOWN (not: empty)" >&2
    exit 1; }
  list_own="$(resolved_own_workspace || true)"
  # Field separator 0x1f (unit separator): agent names may contain spaces
  # (T157g), a space split would be ambiguous. The visible
  # line is reassembled by bash with spaces.
  records=$(printf '%s' "$raw" | python3 -c '
import json, sys
own_ws, all_spaces, sessions = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
raw = sys.stdin.read()
try:
    agents = json.loads(raw)["result"]["agents"]
except Exception as e:
    sys.stderr.write("[herd] '"'"'list'"'"': reply not parseable (%s) — inventory UNKNOWN, not empty\n" % e.__class__.__name__)
    sys.exit(1)
def session_id(a):
    sess = a.get("agent_session")
    if isinstance(sess, dict):
        return sess.get("value") or "-"
    return "-"
for a in agents:
    name = a.get("name")
    if not name:
        continue          # foreign sessions (including the orchestrator itself)
    ws = a.get("workspace_id") or ""
    if not all_spaces and own_ws and ws != own_ws:
        continue
    rest = []
    if all_spaces:
        rest.append(ws or "-")
    if sessions:
        rest.append(session_id(a))
    print("\x1f".join((name, a.get("agent_status", "?"),
                       a.get("pane_id", "-"), " ".join(rest))))
' "$list_own" "$all_spaces" "$sessions") || exit 1
  # herdr does not know question: for raw idle/done panes use the FULL
  # classify_text classification (incl. kind lookup on busy, as
  # `status` via normalize_status). It is adopted ONLY if it yields
  # question; blocked/busy/limited/... remain the raw herdr value, because
  # list otherwise does not normalize (accepted deviation). Without agents
  # stdout stays empty — the empty here-string would otherwise print a phantom record
  # of three empty fields.
  if [ -n "$records" ]; then
    while IFS=$'\x1f' read -r lname lstatus lpane lrest; do
      case "$lstatus" in
        idle|done)
          if [ "$(normalize_status "$lstatus" "$lpane")" = question ]; then
            lstatus=question
          fi ;;
      esac
      if [ -n "$lrest" ]; then
        printf '%s %s %s %s\n' "$lname" "$lstatus" "$lpane" "$lrest"
      else
        printf '%s %s %s\n' "$lname" "$lstatus" "$lpane"
      fi
    done <<< "$records"
  fi
  ;;

# ----------------------------------------------------------------- read -------
read)
  name="${1:-}"; shift || true
  need_name "$name"
  lines=40; source="recent-unwrapped"
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines)  lines="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      *) echo "[herd] read: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
  require_herdr || exit 2
  # pane read instead of agent read: works uniformly for agents AND
  # term panes (which since herdr 0.7.5 are no longer agents).
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for agent '$name'" >&2; exit 1; }
  herdr pane read "$pane" --source "$source" --lines "$lines" --format text
  ;;

# ------------------------------------------------------------------ key -------
# Send keys to the TUI — for approval dialogs (enter=Yes, esc=No, up/down for
# selection). Text prompts go through `send`; `key` is for pure key signals.
key)
  name="${1:-}"; shift || true
  need_name "$name"
  [ $# -gt 0 ] || { echo "[herd] key <name> <enter|esc|up|down|…>" >&2; exit 2; }
  require_herdr || exit 2
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for agent '$name'" >&2; exit 1; }
  herdr pane send-keys "$pane" "$@"
  echo "[herd] key(s) '$*' sent to $name (pane $pane)."
  ;;

# ----------------------------------------------------------------- stop -------
stop)
  name="${1:-}"; shift || true
  need_name "$name"
  require_herdr || exit 2
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for agent '$name'" >&2; exit 1; }
  # Remember the session ID BEFORE closing: with the pane herdr forgets the
  # agent. Parse JSON with python3 (like `list`), do not grep. If
  # `agent get` fails (exit != 0, no JSON), it is still closed and only the
  # first line is printed - `stop` must never fail because of it.
  sess_raw="$(herdr agent get "$pane" 2>/dev/null)" || sess_raw=""
  sess_info=""
  if [ -n "$sess_raw" ]; then
    sess_info="$(printf '%s' "$sess_raw" | python3 -c '
import json, sys
try:
    a = json.loads(sys.stdin.read())["result"]["agent"]
except Exception:
    sys.exit(1)
if not isinstance(a, dict):
    sys.exit(1)
kind = a.get("agent") or ""
sess = a.get("agent_session")
sid = ""
if isinstance(sess, dict):
    sid = sess.get("value") or ""
    if not kind:
        kind = sess.get("agent") or ""
print("%s\t%s" % (kind, sid))
' 2>/dev/null)" || sess_info=""
  fi
  herdr pane close "$pane" >/dev/null
  echo "[herd] pane $pane ($name) closed."
  if [ -n "$sess_info" ]; then
    sess_kind="${sess_info%%	*}"
    sess_id="${sess_info#*	}"
    if [ -n "$sess_kind" ] && [ -n "$sess_id" ]; then
      echo "[herd] session ID ($sess_kind): $sess_id  Resume:"
      printf '  herd.sh start %q --name %q --resume %q\n' "$sess_kind" "$name" "$sess_id"
    elif [ -n "$sess_kind" ]; then
      echo "[herd] no session ID reported (backend without herdr integration or not reported yet) — resume only as the last session:"
      printf '  herd.sh start %q --name %q --resume\n' "$sess_kind" "$name"
    fi
  fi
  ;;

# ----------------------------------------------------------------- term -------
# Open an empty terminal pane (login shell, or --shell CMD). For commands that
# YOU run (sudo password etc.) and whose output the orchestrator reads along —
# without clipboard ping-pong. Addressable by name with type/read/key/stop.
term)
  require_herdr || exit 2
  cwd="$(pwd)"; name=""; split=""; shell=""; tab_opt=""
  max_per_tab="${HERD_MAX_PER_TAB:-4}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="$2"; shift 2 ;;
      --cwd)         cwd="$2"; shift 2 ;;
      --shell)       shell="$2"; shift 2 ;;
      --split)       split="$2"; shift 2 ;;
      --tab)         tab_opt="$2"; shift 2 ;;
      --max-per-tab) max_per_tab="$2"; shift 2 ;;
      *) echo "[herd] term: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
  need_name "$name"
  validate_name term "$name"
  # herdr >= 0.7.5: terminal panes are NO longer agents. A split opens
  # the herdr default shell (interactive → nvm etc. loaded); the label makes
  # the pane addressable by name for type/read/key/stop (pane_id_of).
  create_shell_pane "$cwd" "$split" "$tab_opt" "$max_per_tab" \
    || { echo "[herd] term: no pane could be created" >&2; exit 1; }
  pane="$NEW_PANE"
  herdr pane rename "$pane" "$name" >/dev/null 2>&1 || true
  # --shell CMD: type the command into the fresh shell (pane run = text+Enter).
  # Briefly wait until the shell is at the prompt — otherwise the input evaporates.
  if [ -n "$shell" ]; then
    sleep 1
    herdr_text pane run "$pane" "$shell" \
      || echo "[herd] term: '$shell' could not be typed — check the pane manually" >&2
  fi
  echo "[herd] terminal open — name: $name  pane: ${pane:-?}${TARGET_TAB:+  tab: $TARGET_TAB}"
  echo "[herd] type the command (without Enter): herd.sh type $name \"<cmd>\"  |  read: herd.sh read $name --source visible"
  ;;

# ----------------------------------------------------------------- type -------
# Write command/text into a pane WITHOUT Enter — YOU run it (e.g.
# sudo password). For agent prompts WITH Enter: `send`.
type)
  name="${1:-}"; shift || true
  need_name "$name"
  [ $# -gt 0 ] || { echo "[herd] type <name> <text...>" >&2; exit 2; }
  require_herdr || exit 2
  pane="$(pane_id_of "$name")"
  [ -n "$pane" ] || { echo "[herd] no pane found for '$name'" >&2; exit 1; }
  herdr_text pane send-text "$pane" "$*"
  echo "[herd] written to $name (pane $pane) — WITHOUT Enter. Run it in the pane, or submit with: herd.sh key $name enter"
  ;;

# ---------------------------------------------------- exec (Batch/One-Shot) ---
exec)
  backend="${1:-}"; shift || true
  case "$backend" in
    codex|opencode|copilot|grok|kimi|muse|pi) ;;
    *) echo "[herd] exec <codex|opencode|copilot|grok|kimi|muse|pi> (batch only for these backends)" >&2; exit 2 ;;
  esac
  guard_backend "$backend"

  cwd="$(pwd)"; name=""; timeout_min=30; do_wait=1; hold_sec=8
  model=""; effort=""; spec=""; agent=""; prompt=()
  cp_context=""; cp_tier=""; cp_credits=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd)     cwd="$2"; shift 2 ;;
      --name)    name="$2"; shift 2 ;;
      --timeout) timeout_min="$2"; shift 2 ;;
      --no-wait) do_wait=0; shift ;;
      --hold)    hold_sec="$2"; shift 2 ;;
      --model)   model="$2"; shift 2 ;;
      --effort)  effort="$2"; shift 2 ;;
      --spec)    spec="$2"; shift 2 ;;
      --agent)   agent="$2"; shift 2 ;;
      --context)         cp_context="$2"; shift 2 ;;
      --auto-tier)       cp_tier="$2"; shift 2 ;;
      --max-ai-credits)  cp_credits="$2"; shift 2 ;;
      --) shift; prompt+=("$@"); break ;;
      *)  prompt+=("$1"); shift ;;
    esac
  done
  [ -n "$name" ] || name="$backend-$(date +%H%M%S)"
  validate_name exec "$name"
  validate_minutes exec --hold "$hold_sec" seconds
  validate_minutes exec --timeout "$timeout_min"

  full_prompt="${prompt[*]:-}"
  if [ -n "$spec" ]; then
    [ -f "$spec" ] || { echo "spec file missing: $spec" >&2; exit 2; }
    full_prompt="Implement the specification in the file ${spec}. ${full_prompt}"
  fi
  [ -n "$full_prompt" ] || { echo "[herd] exec: prompt or --spec required" >&2; exit 2; }
  [ -z "$model" ] && model="$(default_model_for "$backend")"   # Config default

  # copilot-specific switches as with start: valid only there, values checked.
  if [ "$backend" != copilot ]; then
    [ -z "$cp_context" ] || { echo "[herd] exec: --context is only available with copilot." >&2; exit 2; }
    [ -z "$cp_tier" ]    || { echo "[herd] exec: --auto-tier is only available with copilot." >&2; exit 2; }
    [ -z "$cp_credits" ] || { echo "[herd] exec: --max-ai-credits is only available with copilot." >&2; exit 2; }
  else
    case "$cp_context" in
      ''|default|long_context) ;;
      *) echo "[herd] exec copilot: --context default|long_context (got: '$cp_context')." >&2; exit 2 ;;
    esac
    case "$cp_tier" in
      ''|efficiency|balance|intelligence) ;;
      *) echo "[herd] exec copilot: --auto-tier efficiency|balance|intelligence (got: '$cp_tier'); only effective with --model auto." >&2; exit 2 ;;
    esac
    if [ -n "$cp_credits" ]; then
      case "$cp_credits" in
        *[!0-9]*) echo "[herd] exec copilot: --max-ai-credits requires an integer (got: '$cp_credits')." >&2; exit 2 ;;
      esac
      [ "$cp_credits" -ge 30 ] || { echo "[herd] exec copilot: --max-ai-credits at least 30 (got: $cp_credits)." >&2; exit 2; }
    fi
  fi

  # Create the run directory already HERE: copilot gets its usage statistics
  # via --usage-output-file into it, so the path must be fixed when building.
  # HERD_PRINT_CLI (tests) only shows the would-be path and writes nothing.
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ "${HERD_PRINT_CLI:-}" = 1 ]; then
    logdir="$(herd_log_root_path)/$stamp-$name.XXXXXX"
  else
    log_root="$(herd_log_root)" || exit 1
    prune_logdirs "$log_root" "${HERD_LOG_KEEP_DAYS:-7}"
    prune_herd_workdirs "$cwd" "${HERD_WORKDIR_KEEP_DAYS:-14}"
    logdir="$(mktemp -d "$log_root/$stamp-$name.XXXXXX")" || { echo "[herd] exec: cannot create a run directory in $log_root" >&2; exit 1; }
  fi

  cmd=()
  if [ "$backend" = codex ]; then
    command -v codex >/dev/null || { echo "codex not in PATH" >&2; exit 127; }
    cmd=(codex exec -s workspace-write -C "$cwd")
    [ -n "$model" ] && cmd+=(-m "$model")
    [ -n "$effort" ] && cmd+=(-c "model_reasoning_effort=\"$effort\"")
    cmd+=("$full_prompt")
  elif [ "$backend" = copilot ]; then
    command -v copilot >/dev/null || { echo "copilot not in PATH" >&2; exit 127; }
    # Batch: -p runs and exits, -s answer only, --allow-all-tools without
    # approval prompts (necessary in non-interactive mode).
    cmd=(copilot -p "$full_prompt" -s --allow-all-tools -C "$cwd")
    [ -n "$model" ]  && cmd+=(--model "$model")
    [ -n "$effort" ] && cmd+=(--reasoning-effort "$effort")
    # Context tier always explicit (persisted setting, long-context rate
    # from 272k input) — rationale see build_cli.
    cmd+=(--context "${cp_context:-default}")
    [ -n "$cp_tier" ]    && cmd+=(--auto-tier "$cp_tier")
    [ -n "$cp_credits" ] && cmd+=(--max-ai-credits "$cp_credits")
    # Consumption as JSON next to the log: `herd.sh usage` cannot query copilot
    # (no /usage screen in the TUI), in batch it goes via the CLI.
    cmd+=(--usage-output-file "$logdir/usage.json")
  elif [ "$backend" = grok ]; then
    command -v grok >/dev/null || { echo "grok not in PATH" >&2; exit 127; }
    # Headless: -p runs and exits. --always-approve needed — without a TTY
    # nobody answers approval dialogs. Preempt the trust dialog likewise.
    grok_trust_cwd "$cwd"
    cmd=(grok -p "$full_prompt" --cwd "$cwd" --always-approve)
    [ -n "$model" ] && cmd+=(-m "$model")
    [ -n "$effort" ] && cmd+=(--reasoning-effort "$effort")
  elif [ "$backend" = kimi ]; then
    command -v kimi >/dev/null || { echo "kimi not in PATH" >&2; exit 127; }
    # Headless: -p runs, approves implicitly itself and exits
    # (--yolo cannot be combined with -p: "Cannot combine --prompt with
    # --yolo", verified 2026-07-16). kimi has no cwd flag — env -C sets
    # the working directory correctly even in the setsid fallback.
    cmd=(env -C "$cwd" kimi -p "$full_prompt")
    [ -n "$model" ] && cmd+=(-m "$model")
  elif [ "$backend" = muse ]; then
    command -v muse >/dev/null || { echo "muse not in PATH" >&2; exit 127; }
    # Headless: muse exec runs and exits. Without a TTY nobody answers
    # approval dialogs; never leaves the sandbox on (unlike --yolo).
    # Recursion guard as with start: skill persistently off in muse (muse_foreign_guard).
    muse_foreign_guard || exit 1
    cmd=(muse exec --workspace "$cwd")
    auto_trust_enabled && cmd+=(--trust-workspace)
    cmd+=(--approval-mode never --user-input-auto-resolve)
    [ -n "$model" ]  && cmd+=(--model "$model")
    [ -n "$effort" ] && cmd+=(--reasoning-effort "$effort")
    cmd+=("$full_prompt")
  elif [ "$backend" = pi ]; then
    command -v pi >/dev/null || { echo "pi not in PATH" >&2; exit 127; }
    # Headless: -p runs and exits. --no-session so that no
    # session file is created under ~/.pi/agent/sessions/ for the one-shot.
    # pi has no cwd flag — env -C sets the working directory correctly even in the
    # setsid fallback (as with kimi).
    pi_resolve "$model" "$effort"
    pi_trust_flag
    cmd=(env -C "$cwd" pi -p --no-session "$pi_trust")
    [ -n "$pi_provider" ] && cmd+=(--provider "$pi_provider")
    cmd+=(--model "$pi_model")
    [ -n "$effort" ] && cmd+=(--thinking "$effort")
    cmd+=("$full_prompt")
  else
    command -v opencode >/dev/null || { echo "opencode not in PATH" >&2; exit 127; }
    case "$model" in "" | */*) ;; *) [ -n "${OPENCODE_PROVIDER:-}" ] && model="${OPENCODE_PROVIDER}/$model" ;; esac
    cmd=(opencode run --dir "$cwd")
    [ -n "$model" ] && cmd+=(-m "$model")
    [ -n "$agent" ] && cmd+=(--agent "$agent")
    cmd+=("$full_prompt")
  fi

  if [ "${HERD_PRINT_CLI:-}" = 1 ]; then printf '%s\n' "${cmd[@]}"; exit 0; fi

  batch_wrapper "$logdir" "$hold_sec" "${cmd[@]}"

  # herdr path (herdr >= 0.7.5): split a shell pane and type the wrapper as a
  # script file into the pane shell (pane run = text+Enter). The file
  # avoids quoting traps when typing; the prerequisite is a POSIX shell as the
  # herdr default shell (Windows: see references/windows.md).
  launched_via=""
  if herdr_up; then
    printf '%s\n' "$wrapper" >"$logdir/cmd.sh"
    if create_shell_pane "$cwd" "" "" "${HERD_MAX_PER_TAB:-4}" 2>/dev/null; then
      herdr pane rename "$NEW_PANE" "$name" >/dev/null 2>&1 || true
      sleep 1
      # "; exit" closes the pane shell after the wrapper (incl. hold pause) —
      # otherwise an empty shell pane would remain after every run.
      if herdr pane run "$NEW_PANE" "bash $(printf '%q' "$logdir/cmd.sh"); exit" >/dev/null 2>&1; then
        launched_via="herdr"
      fi
    fi
  fi
  if [ -z "$launched_via" ]; then
    setsid bash -ilc "$wrapper" </dev/null >/dev/null 2>&1 &
    disown
    launched_via="setsid"
  fi
  echo "[herd] exec started via $launched_via — name: $name, log: $log"
  [ "$do_wait" = 1 ] || exit 0

  deadline=$(( $(date +%s) + timeout_min * 60 ))
  until [ -f "$done_marker" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[herd] TIMEOUT after ${timeout_min}min — run may continue, log: $log" >&2
      exit 124
    fi
    sleep 10
  done
  ec="$(cat "$done_marker")"
  echo "[herd] exec done, exit $ec — last log lines:"
  tail -n 40 "$log" || true
  exit "$ec"
  ;;

# ------------------------------------------------------------------ run -------
run)
  cwd="$(pwd)"; name=""; timeout_min=30; do_wait=1; hold_sec=8; prompt=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd)     cwd="$2"; shift 2 ;;
      --name)    name="$2"; shift 2 ;;
      --timeout) timeout_min="$2"; shift 2 ;;
      --no-wait) do_wait=0; shift ;;
      --hold)    hold_sec="$2"; shift 2 ;;
      --) shift; prompt+=("$@"); break ;;
      *)  prompt+=("$1"); shift ;;
    esac
  done
  [ ${#prompt[@]} -gt 0 ] || { echo "[herd] run: command after -- required" >&2; exit 2; }
  [ -n "$name" ] || name="run-$(date +%H%M%S)"
  validate_name run "$name"
  validate_minutes run --hold "$hold_sec" seconds
  validate_minutes run --timeout "$timeout_min"

  stamp="$(date +%Y%m%d-%H%M%S)"
  log_root="$(herd_log_root)" || exit 1
  prune_logdirs "$log_root" "${HERD_LOG_KEEP_DAYS:-7}"
  prune_herd_workdirs "$cwd" "${HERD_WORKDIR_KEEP_DAYS:-14}"
  logdir="$(mktemp -d "$log_root/$stamp-$name.XXXXXX")" || { echo "[herd] run: cannot create a run directory in $log_root" >&2; exit 1; }
  batch_wrapper "$logdir" "$hold_sec" "${prompt[@]}"

  # Same herdr path as with exec: split pane, retype the wrapper script.
  launched_via=""
  if herdr_up; then
    printf '%s\n' "$wrapper" >"$logdir/cmd.sh"
    if create_shell_pane "$cwd" "" "" "${HERD_MAX_PER_TAB:-4}" 2>/dev/null; then
      herdr pane rename "$NEW_PANE" "$name" >/dev/null 2>&1 || true
      sleep 1
      # "; exit" closes the pane shell after the wrapper (incl. hold pause) —
      # otherwise an empty shell pane would remain after every run.
      if herdr pane run "$NEW_PANE" "bash $(printf '%q' "$logdir/cmd.sh"); exit" >/dev/null 2>&1; then
        launched_via="herdr"
      fi
    fi
  fi
  if [ -z "$launched_via" ]; then
    setsid bash -ilc "$wrapper" </dev/null >/dev/null 2>&1 &
    disown
    launched_via="setsid"
  fi
  echo "[herd] run started via $launched_via — name: $name, log: $log"
  [ "$do_wait" = 1 ] || exit 0

  deadline=$(( $(date +%s) + timeout_min * 60 ))
  until [ -f "$done_marker" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[herd] TIMEOUT after ${timeout_min}min — log: $log" >&2
      exit 124
    fi
    sleep 10
  done
  ec="$(cat "$done_marker")"
  echo "[herd] run done, exit $ec — last log lines:"
  tail -n 40 "$log" || true
  exit "$ec"
  ;;

# ---------------------------------------------------------------- usage -------
usage)
  # --log reads the limits from the codex session logs instead of from a TUI.
  # Needs no herdr and works even if codex shows a dialog at startup
  # (e.g. a model switch offer at the limit).
  if [ "${1:-}" = "--log" ]; then
    shift
    if [ $# -ne 1 ] || [ "${1:-}" != "codex" ]; then
      echo "[herd] usage --log: only codex (call: usage --log codex)" >&2
      exit 2
    fi
    python3 "$SCRIPT_DIR/herd_parse.py" codex-log
    exit $?
  fi

  require_herdr || exit 2
  [ $# -gt 0 ] || { echo "[herd] usage <name...> | --probe [backends] | --raw <name> | --log codex required" >&2; exit 2; }

  case "$1" in
    --raw)
      shift
      [ $# -gt 0 ] || { echo "[herd] usage --raw: name required" >&2; exit 2; }
      raw_name="$1"; shift
      [ $# -eq 0 ] || { echo "[herd] usage --raw: only one agent allowed" >&2; exit 2; }
      usage_one "$raw_name" 1
      exit $?
      ;;
    --probe|--probe=*)
      probe_backends="codex,grok,agy,claude,muse"
      case "$1" in
        --probe=*)
          probe_backends="${1#--probe=}"
          shift
          ;;
        --probe)
          shift
          if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
            probe_backends="$1"
            shift
          fi
          ;;
      esac
      [ -n "$probe_backends" ] || probe_backends="codex,grok,agy,claude,muse"

      IFS=',' read -ra probe_list <<< "$probe_backends"
      probe_failed=0
      for b in "${probe_list[@]}"; do
        b="$(printf '%s' "$b" | tr -d ' ')"
        [ -n "$b" ] || continue
        case "$b" in
          codex|agy|opencode|claude|copilot|grok|kimi|muse|pi)
            if ! herdr_kind_known "$b"; then
              echo "[herd] usage --probe: herdr does not know the backend kind '$b' — skipped" >&2
              continue
            fi
            ;;
        esac
        pname="usage-$b"
        tab_id=""
        ws="$(resolved_own_workspace || own_workspace_id || true)"
        if [ -n "$ws" ]; then
          tab_json="$(herdr tab create --workspace "$ws" --cwd "$PWD" --label "$pname" --no-focus 2>/dev/null || true)"
        else
          tab_json="$(herdr tab create --cwd "$PWD" --label "$pname" --no-focus 2>/dev/null || true)"
        fi
        tab_id="$(printf '%s' "$tab_json" | grep -o '"tab_id":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"

        start_cmd=("$0" start "$b" --name "$pname" --role research --cwd "$PWD")
        [ -n "$tab_id" ] && start_cmd+=(--tab "$tab_id")

        if ! "${start_cmd[@]}" >/dev/null 2>&1; then
          echo "[herd] usage --probe: start for backend '$b' failed" >&2
          probe_failed=1
        else
          USAGE_LAST_RAW_BUF=""
          USAGE_LAST_PARSE_RC=0
          if ! usage_one "$pname" 0; then
            probe_failed=1
            if [ "${USAGE_LAST_PARSE_RC:-0}" -ne 0 ] && [ -n "${USAGE_LAST_RAW_BUF:-}" ]; then
              echo "[herd] usage --probe $b: raw block (parse error):" >&2
              printf '%s\n' "$USAGE_LAST_RAW_BUF" | grep -v '^[[:space:]]*$' | head -n 40 | sed 's/^/  /' >&2
            fi
          fi
        fi

        # F5: always attempt stop AND tab close per backend
        "$0" stop "$pname" >/dev/null 2>&1 || true
        if [ -n "$tab_id" ]; then
          herdr tab close "$tab_id" >/dev/null 2>&1 || true
        fi
      done
      [ "$probe_failed" -eq 0 ] || exit 1
      exit 0
      ;;
    --*)
      echo "[herd] usage: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      usage_failed=0
      for u_name in "$@"; do
        if ! usage_one "$u_name" 0; then
          usage_failed=1
        fi
      done
      [ "$usage_failed" -eq 0 ] || exit 1
      exit 0
      ;;
  esac
  ;;

# ------------------------------------------------------------------------------
""|-h|--help|help)
  show_usage
  ;;
*)
  echo "[herd] unknown command: $cmd" >&2
  echo "  valid: start | send | status | wait | watch | list | read | answer | key | stop | term | type | exec | run | usage" >&2
  exit 2
  ;;
esac
