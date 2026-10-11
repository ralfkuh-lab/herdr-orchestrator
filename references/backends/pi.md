# Backend: pi

- **pi** — terminal harness for cloud providers (`opencode-go`,
  `openrouter`, `openai-codex` via subscription OAuth among others) **and** local models
  (pi 1.1.0; herdr kind `pi`). Since pi 1.0 the TUI runs in
  fullscreen by default (`tuiMode`); busy detection, `question`, `/new`, `--resume` and
  `exec` live-verified 2026-10-10 with pi 1.1.0 and herdr 0.9.3.
  Start: `--provider` + `--model`; `--model` in the form `provider/id` without
  `--provider`. Provider from config `HERD_PI_PROVIDER` (no default), model
  from `--model` or `MODEL_PI`. `--model id` without `/` requires a set
  `HERD_PI_PROVIDER`, otherwise exit 2 with a hint to `provider/id`; entirely without a
  model, start aborts with a hint to `pi --list-models` (herd.sh always sets
  provider/model explicitly, the default in pi's own
  `~/.pi/agent/settings.json` plays no role). `--effort` → `--thinking`
  (values directly: `off|minimal|low|medium|high|xhigh|max`). `role impl` →
  default tools; `research` → `--tools read,bash` (bash remains able to write,
  pi has no sandbox mode). The project trust question is always answered by a
  flag, so that the one-time dialog "Trust project folder?" does not stop a
  delegated run: `HERD_PI_PROJECT_TRUST=approve` → `--approve` (loads the
  project's `.pi/` settings, extensions, skills, prompts and `.agents/skills`
  for this run), `ignore` → `--no-approve` (leaves them out). Without an
  explicit value the default follows `HERD_AUTO_TRUST`: `approve` at `1`,
  otherwise `ignore`. Without a trust flag pi shows this dialog in projects
  with `.pi/` or `.agents/skills`; herd.sh does not detect it
  (state `idle`) — therefore `start` always sets the flag (live observed
  2026-09-15). `HERD_PI_PROVIDER`/`HERD_PI_PROJECT_TRUST` instead of `PI_*`:
  pi exports `PI_PROVIDER`/`PI_MODEL`/`PI_REASONING_LEVEL` into every
  bash call — with the old names herd.sh would inherit the provider of the
  calling pi session.
  Resume: `-c` / `--session <id>`.
  `--permission-mode` does not exist (exit 2). No approval dialog for
  file writes/bash. Busy pattern: line with Braille spinner and "Working"
  in the last 10 visible lines. `usage` rejects pi (pi shows no
  quotas — check limits with the respective provider). `exec`:
  `pi -p --no-session` plus trust flag (`--approve`/`--no-approve`). Skills
  from `~/.agents/skills` (not `~/.claude/skills`) — but this skill can be
  installed there too, and pi has no run flag to hide it: prefix the first
  brief with the role line (SKILL.md §3). Caution only with local servers with a small context (e.g. 16k on
  a local model server): the skill preamble from `~/.agents/skills` costs ~14k
  tokens, almost nothing remains for the prompt. Choose a model/server with a larger
  context or reduce skills for pi (to be checked).
  `:<thinking>` suffix in the model and `--effort` are mutually exclusive (exit 2).
