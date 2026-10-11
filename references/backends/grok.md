# Backend: grok

- **grok** — Grok Build TUI (xAI). `role impl` → `--permission-mode acceptEdits`
  (thus writes also outside the cwd without prompting — in tests even `/tmp`;
  overridable as with claude: `HERD_IMPL_PERMISSION_MODE` / `--permission-mode`),
  `research` → `--permission-mode plan` (read-only). `--model` (`grok models`:
  `grok-4.5` = default since 2026-07-13 (replaces `grok-build`),
  `grok-composer-2.5-fast`), `--effort` →
  `--reasoning-effort`. Resume: `-c` / `-r <id>`. Auth: `grok login`
  (SuperGrok subscription). Official herdr integration (agent detection built in).
  Choose the model **at start** via `--model`, not via `/model` in the session —
  the picker changes the default model persistently and wants a new session.
- **Trust dialog:** grok asks once per folder whether to trust it (y/n). The
  dialog is only in the ANSI snapshot, not in the text that `status`/`watch`
  read — a `send` into it types the prompt as keys, and an `n` quits grok.
  Default (`HERD_AUTO_TRUST=0`): `start`/`exec` warn on stderr if the cwd is not
  trusted yet; trust the folder once in grok yourself (or `answer` the dialog
  after `read --source visible`). With `HERD_AUTO_TRUST=1`, `start`/`exec`
  append the cwd to `~/.grok/trusted_folders.toml` beforehand — **permanently**
  (also for later manual grok sessions), so grok loads that folder's project
  configuration, skills and hooks from then on. The entry is written only while
  holding grok's lock file via `flock` (copy plus entry, then an atomic
  rename); without `flock` (e.g. stock macOS), when the lock is not free within
  2 s, or for paths with `"`, `\` or control characters the file stays
  untouched (note on stderr) — trust the folder in grok yourself then. The lock
  only serializes writers that use it; whether grok itself honors it was not
  verified. Headless `exec` in an untrusted folder was not
  live-tested.

## Course correction during a running turn

(Moved from SKILL.md.) Sends during a running turn land as
individual follow-up briefs in the TUI queue; exit 0 does not prove immediate
processing in the running turn. For a necessary immediate course correction,
first check the work state and queue with `read --source visible`, then send
`key NAME ctrl+c` in a targeted way and read again. Grok may then already begin
the next queued brief. Only after assessing this state
send the correction package; do not place a series of reminders in the queue.
