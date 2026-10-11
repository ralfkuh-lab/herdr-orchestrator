# Backend: codex

- **codex** — `role impl` → `-s workspace-write`, `research` → `-s read-only`.
  `--model`/`--effort` (→ `model_reasoning_effort`). Resume: `codex resume`
  with the same `-C <cwd>`, `-s <role sandbox>`, `-m`/`-c` options as a new run
  (`codex resume --help` accepts them), so `--role research --resume` really
  continues read-only.
  Asks on writes outside the workspace (→ approval handling); for
  unattended writing `send <name> "/permissions full"`.
  **cwd MUST be a Git repo** (otherwise codex exits immediately and the
  registration disappears — `start` therefore aborts early).
  **Trust dialog:** by default "Trust this folder?" appears for an untrusted
  repository → read it and `answer <name> "Yes, continue"` only for a
  repository you meant to work in (codex stores that decision). Only with
  `HERD_AUTO_TRUST=1` does a **new run** preempt it with
  `-c 'projects={"<git-toplevel>"={trust_level="trusted"}}'` — for this
  session only (nothing is stored), but codex then treats the repository as
  trusted and loads what it reserves for trusted folders (project-level
  configuration such as `.codex/config.toml`, and depending on the codex
  version project skills and hooks). Paths with `"`, `\` or control
  characters are never pre-trusted; with `--resume` the dialog is still
  possible. Every `-c` makes codex 0.157+ start in
  embedded mode ("Running without the shared background server
  …", observed 2026-09-27) — functionally without consequences.
  Tests with local sockets (our
  `tests/run.sh`, fake event server) fail in the codex sandbox with
  `Operation not permitted`; codex then asks whether it may run the suite
  outside the sandbox → `answer <name> "Yes, proceed"` (once per
  review run, observed 2026-09-09). With "Approaching rate limits
  … switch to gpt-5.6-luna?" → `answer <name> "Keep current model"`.
