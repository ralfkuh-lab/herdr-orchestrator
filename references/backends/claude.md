# Backend: claude

- **claude** — `role impl` → `--permission-mode acceptEdits` (overridable:
  config `HERD_IMPL_PERMISSION_MODE` or `start … --permission-mode M` —
  acceptEdits only approves file edits, under Windows/PowerShell almost every
  shell command otherwise asks), `research` →
  `--permission-mode plan` (read-only, cannot write any file — fetch the analysis
  result via `read` from the pane). `--model`/`--effort`. Resume:
  `-c` / `-r <id>`.
