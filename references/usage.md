# usage: querying limits

Provider limit rules change constantly (5h windows come and go, weekly/monthly
quotas change). Only what the TUI itself shows is reliable. `usage` queries
exactly that — it sends the matching slash command (`/status` for codex,
`/usage` otherwise), waits up to 6 s for the view, parses it and closes it
again (`esc`; codex leaves its status block in the scrollback):

```bash
<herd> usage impl-a rev-codex rev-grok        # running sessions
<herd> usage --probe codex,grok,agy,claude,muse   # throwaway sessions per backend (~5–10 s per backend)
<herd> usage --raw rev-codex                  # raw pane block for diagnosis
<herd> usage --log codex                      # limits from the codex session logs (without a pane)
```

One tab-separated line per agent, percentage always as **remaining** ("left"),
even if the TUI shows "used" or "remaining"; reset times verbatim from the
pane:

```
impl-a     agy    5h=73% left   week=90% left                  reset5h=4h 1    resetweek=103h
rev-codex  codex  5h=93% left   week=84% left                  reset5h=14:11   resetweek=23:09 on 7 Sep
rev-grok   grok   5h=–          week=100% left (bar 0/30)      reset5h=–       resetweek=September 9, 22:20
impl-muse  muse   5h=100% left  week=100% left                 reset5h=at 10:23 PM  resetweek=Sep 7 at 2:00 AM
```

- agy's `/usage` view is a scroller (footer `(a–b of N lines)`, only ~5 lines
  visible in short panes): since 2026-09-09, `usage` pages through it itself
  with `down`×window width, maps the window lines to their positions and parses
  the reconstructed text — before that, panes of the 2×2 grid regularly showed
  `5h=?`. A still-open old view is closed beforehand with `esc`. herdr does not
  know `pgdown`/`end`.
- `–` = this window does not exist for the backend (grok has no 5h window, its
  bar shows consumption and is converted to the remaining value; since codex
  0.156 the 5h window is missing, `5h=–`). In `/usage`, muse shows the lines
  `Current N% used` (5h window) and `Weekly N% used` under `Subscription`; as
  with codex, the block stays in the scrollback (no `esc`).
- `?` = not parseable → exit 1 with a hint pointing to `--raw`. Two exceptions
  for resets that are not yet scheduled: for agy exactly 100 % with
  `Quota available`, for Claude `Current session` with `0% used` and no reset
  line. On a successful call the respective reset stays `?`; Claude's weekly
  values together with the reset remain mandatory. Empty reset lines and
  timeouts without new output are errors.
- With an **open dialog**, `usage` sends nothing (exit 1 with a hint) — first
  `answer`/`key`, then again. Unsupported backends (opencode, copilot, kimi,
  pi) are rejected before sending. For **copilot in batch**, there is the CLI
  route: `exec copilot …` writes the usage statistics as `usage.json` into the
  run's log directory (`--usage-output-file`).
- **`usage --log codex`** bypasses the TUI entirely: it reads the last valid
  `rate_limits` line from `${CODEX_HOME:-$HOME/.codex}/sessions/**/rollout-*.jsonl`
  (the 20 most recent files). Fast, without a pane, and works even when codex
  shows a dialog at start (e.g. a Luna switch offer at the limit). Limits: only
  as fresh as the last codex turn (the age is shown as `age=…` in the line,
  above 60 min additionally as a warning on stderr), and only the general codex
  limit — the Luna reserve does not appear there. The backend must be `codex`.
- Convention: **once a day before the first fan-out**, `usage --probe …` for
  the backends that are up today; **before long codex reviews**, `usage
  rev-codex`. If a window is below ~15 %, swap the backend for the run (fallback
  chain) instead of blowing the limit in the middle of the run.
