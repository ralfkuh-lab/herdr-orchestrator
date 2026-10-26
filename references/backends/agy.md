# Backend: agy

- **agy** — `role impl` → `--mode accept-edits` (writes without prompting),
  `research` → `--mode plan` (read-only; whether the plan mode ends in an
  approval dialog as with kimi has not been observed yet — check on the first
  run with `read`). `--effort low|medium|high` is passed through, but the
  model slug (`gemini-3.8-flash-high`, `gemini-4-argon-medium`) usually carries
  the effort: agy then reports that the flag is not supported for that model
  and ignores it (observed 2026-09-15) — choose the effort via the slug.
  `--permission-mode accept-edits|plan` overrides both roles; the config
  `HERD_IMPL_PERMISSION_MODE` does NOT apply here (claude/grok vocabulary).
  `--model` (see `agy models`). Resume: `-c` / `--conversation`. Official
  herdr integration since 0.7.5 (kind `agy`); the pane heuristics remain as a
  cross-check — necessary because herdr reports `idle`/`done` for agy during
  generation (see [watch-internals.md](../watch-internals.md)). For pure batch runs, `run` with a wrapper command is suitable.
  The known satisfaction survey (`How's the CLI experience …` plus
  `[1] Good [2] Fine [3] Bad [0] Skip`) does not count as running work;
  spinners, background tasks and real dialogs are still detected.
  `send` also transmits digit prompts unchanged. **Limit:** The evaluation of
  such prompts by agy with an open survey is not proven live; before a
  digit prompt, close the visible survey with `key NAME 0` and read it back.
