# Codex as orchestrator

Proven workflow with `exec_command` and `write_stdin` (Codex runs of
11–13 September 2026). These are tools of the observed environment, not a
promise that every Codex installation offers the same tools. Briefs, result
checking and backend verbs stay as in SKILL.md.

## Active monitoring

1. Always call `scripts/herd.sh` as a single command with a fully spelled-out
   absolute path. Work in your own herdr space (`list`).
2. After start and prompt handover, launch `herd.sh wait NAME --timeout 1` via
   `exec_command` with a short output wait. `--timeout 1` means one minute. If
   the tool returns a process session ID, collect the output regularly with
   `write_stdin` (e.g. every 10 seconds).
3. On exit 124 the agent work continues: start a new `wait` immediately. On
   `blocked`, read the visible dialog and assess every request individually,
   then `answer` and watch again. If `answer` reports an error, read again
   first: the previous request may have been confirmed and another dialog may
   already be open, even with the same options.
4. Treat `idle`/`done` as completion only together with a checked result. With
   several agents, watch each one, query the process sessions in turn, and
   check all states before longer steps of your own.
5. After compaction and before finishing, reconcile `list` with your own
   briefs; close finished panes that are no longer needed with `stop`.

As long as delegated work is running, the orchestrator turn stays active. A
process session ID is not a proven automatic wake-up signal after the turn
ends. Do not assume Claude-specific tools such as `Monitor(persistent: true)`
or `Bash(run_in_background)` exist in Codex.

During monitoring, perform only short, interruptible work steps. If you
implement yourself, finish longer changes before starting the review so the
reviewer's dialogs can be handled promptly.

## Access and installation

Installation for Claude Code and Codex is described in README.md and SKILL.md.
A symlink to the same repository suffices; no separate skill fork is needed.
Check existing links before creating a new one.

Interactive verbs check the herdr environment (`HERDR_ENV`), the CLI in the
`PATH`, and reachability via `herdr pane list`. Errors end with exit 2; on a
CLI error, its stderr diagnosis and original exit code are preserved in the
error message. stdout stays free for regular output. The batch verbs
`exec`/`run` still use their `setsid` fallback silently.

A connection error does not prove that the daemon is stopped. Use the concrete
diagnosis to check environment, connection and permissions; if the environment
provides for it, have the call explicitly approved. Take existing authorization
into account, do not demand a blanket sandbox shutdown.

## Not yet proven

A wake-up signal independent of the active turn and a measured maximum reaction
time to new approval dialogs are still open. Active polling worked in the
observed runs; that does not prove unattended continuation after the turn ends.
