# Backend: copilot

- **copilot** — two **independent** axes, hence two switches:
  **work mode** `--permission-mode interactive|plan|autopilot` → `--mode M`
  (applies to BOTH roles; without a value: `research` → `--mode plan` (read-only),
  `impl` → copilot default, asks before writes) and **auto-approval**
  `--yolo` (= `--allow-all-tools --allow-all-paths --allow-all-urls`).
  Combinable: `start copilot … --permission-mode autopilot --yolo`.
  In the running session still via `/yolo`.
  `--model` (among others OpenAI models; available IDs via `/model` in the TUI),
  `--effort` → `--reasoning-effort` (`none|minimal|low|medium|high|xhigh|max`).
  `--context default|long_context`: is **always set explicitly**, `default`
  without a value. Reason: copilot **persists** the context tier across sessions
  ("overrides persisted setting"), an earlier `long_context` would otherwise
  silently continue to apply — and from 272k input tokens the doubled long-context
  rate applies to the **entire** request. So long context only on explicit request.
  `--auto-tier efficiency|balance|intelligence` (only with `--model auto`),
  `--max-ai-credits N` (upper limit per session, min. 30).
  Invalid values fail with exit 2 **before** pane creation — copilot
  exits immediately on argument errors, the pane would otherwise die silently.
  Resume: `--continue` / `-r <id>`; for new sessions copilot gets the
  agent name as session name (`-n`), so that `-r <name>` works without an ID.
  Auth: `copilot login` or `COPILOT_GITHUB_TOKEN`.
