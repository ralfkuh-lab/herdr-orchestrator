# Backend: muse

> Not regularly tested; reflects the last verified state.

- **muse** — Muse Code CLI (Meta, model Muse Spark). Start
  with `--workspace <cwd>` (explicit workspace root, counterpart to codex `-C`),
  with `HERD_AUTO_TRUST=1` also `--trust-workspace` (trusts the workspace for
  this session — muse then loads its project configuration, skills and hooks —
  and preempts the trust dialog; stores nothing; default off: the trust dialog
  comes up as `blocked` → `answer` it), and the
  recursion guard ([below: persistent skill deactivation](#recursion-guard-in-detail)). `role impl` →
  `--approval-mode on-request`. **Observed with Muse 1.0.3 (live test 2026-09-08):**
  neither `on-request` nor `untrusted` prompted — `ls`, writes and `rm -rf`
  under `/tmp` as well as `curl` (via the sandbox proxy) ran through without a
  dialog; a write attempt into the home directory failed silently in the sandbox
  ("Read-only file system"), also without a dialog. The sandbox is thus the actual
  barrier (workspace + `/tmp` writable, rest read-only), not the
  approval dialog. The dialog `Would you like to run the following command?` with
  `› 1. Allow this stage once (y)` / `2. Abort the entire command (esc)` (→
  `answer`) comes from 1.0.2 and could no longer be triggered in 1.0.3 —
  `answer` remains tested for it only via fixture.
  `research` → additionally `--disable-write` (file tool read-only; the shell
  remains for exploration and is sandboxed to the workspace). `--permission-mode
  untrusted|on-request|never` overrides both roles (`never` = no prompts,
  sandbox stays on — NOT `--yolo`; in 1.0.3 practically without an observable
  difference to `on-request`); `HERD_IMPL_PERMISSION_MODE` does NOT apply here
  (claude/grok vocabulary). `--model` (`muse-spark-1.3`), `--effort` →
  `--reasoning-effort none|minimal|low|medium|high|xhigh|ultra` (default high).
  Resume: `muse resume --last` / `muse resume <uuid>`. Auth: `muse login`
  (Meta account, device code). TUI: prompt `⟩`, footer `model · effort · cwd`,
  during work `… · esc to interrupt` (busy pattern: last **25** visible
  lines, because muse shows the task list below the thinking line — 10 lines
  were not enough, `watch` reported `idle` in the middle of edits). `◆ model failed: …`
  (e.g. stream timeout) is `failed`: prompt lost, resend the same prompt,
  switch backend on repetition. **Muse 1.3.0 (live 2026-09-16, herdr
  0.9.0):** shell commands run through a built-in
  reviewer before execution (`◈ Reviewing approval request (… · esc to interrupt)` plus
  `shell command: …`, **without** a user dialog). herdr reports raw
  `blocked` in this phase; `herd.sh status`/`watch` correct that via a pane
  cross-check to `working` (only kind `muse`, busy line without dialog). A real
  dialog (trust or `Would you like to run the following command?`) remains
  `blocked` — but is only reported after the quiet window, i.e. up to
  `debounce_sec` (default 4 s) later. A
  write attempt into home failed in the sandbox without a user dialog; `usage`
  parses 1.3.0 (subscription block present). Slash commands
  among others `/usage`, `/effort`, `/compact`, `/fork`. **Requires herdr >= 0.9.0** (the
  muse manifest, herdrdev/herdr#2489, has been stable since 0.9.0; 0.8.2 rejects
  `agent start --kind muse` — `start` reports that in advance). Live verified in panes
  2026-09-08 with herdr 0.9.0 and Muse 1.0.3: `start`, `send`, `watch` (`done` only
  when a shell command running "Backgrounded" by muse is also finished),
  `usage`, result file in the workspace. After a turn the TUI may show a
  `Session usage` block on its own. No herdr integration (session hook) for
  muse — after a herdr restart only the shell remains of the pane, resume then via
  `start muse --resume [<uuid>]`.

## Recursion guard in detail

(Moved from SKILL.md.) muse loads the Claude Code skills from
`~/.claude/skills` as "foreign personal context" — among them this
orchestrator skill. Since Muse 1.0.3 there is no run flag for this anymore (the
earlier `--no-foreign-personal-context` is missing from the TUI). `herd.sh start`
and `exec` therefore deactivate the skill once persistently
(`muse skills disable herdr-orchestrator --scope user`, lands in
`~/.config/muse/settings.json`; undo via `muse skills enable …`) and
abort if that does not take effect (`muse_foreign_guard` in herd.sh). Verified
with Muse 1.0.3: The skill list of the sub-agent session no longer contains
`herdr-orchestrator` afterwards. Additionally prepend a role line to the first `send`.
