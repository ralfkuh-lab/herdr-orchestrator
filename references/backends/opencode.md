# Backend: opencode

- **opencode** — `role impl` → `--agent build`, `research` → `--agent plan`.
  `--effort VARIANT` sets the model variant for a **new** run;
  requires an explicit model (or `MODEL_OPENCODE`) and checks the
  available variants via `opencode models PROVIDER --verbose` in the target cwd.
  The TUI reads its variant from `model.json`, not reliably from the
  agent configuration. A process wrapper therefore copies model choice/favorites,
  UI settings, pinned sessions and prompt history into a private
  `XDG_STATE_HOME` and sets the variant there. Original state and config files
  remain unchanged; later UI changes of this run also remain private.
  Inline configuration (`OPENCODE_CONFIG_CONTENT`) the wrapper passes unchanged
  to OpenCode. The private state remains in the system temp directory
  (`herd-opencode-state-*`) for diagnosis, similar to the run logs.
  With `--resume`, `--effort` is rejected, because the stored session variant
  may take precedence. Without `--effort` the start remains unchanged.
  Herdr starts the wrapper via `pane run` and registers the detected agent.
  Live verified with OpenCode 1.18.29: `opencode-go/deepseek-v4.1-flash` uses
  the requested `low` in TUI and request/response, while the original choice
  `high` and the configuration files remain unchanged.
  `--model` expects `provider/model`; without a slash the provider from
  the config (`OPENCODE_PROVIDER`) is optionally prepended. Resume: `-c` / `-s <id>`.
  Asks on access outside the workspace in the permission dialog via a horizontal
  option bar; `answer` detects and serves this dialog automatically.
  After `answer "Allow always"` a second confirmation dialog `Confirm`/`Cancel` follows;
  `answer` detects the changed option set as success (`[herd] answer: '<option>' selected (...) and confirmed — follow-up dialog open: Confirm | Cancel`,
  exit 0) and `watch` reports the agent as `blocked` again, so that the orchestrator serves the follow-up dialog
  with a further `answer <name> "Confirm"`.
  **NEVER send write briefs to `research`** (plan is truly read-only; the
  model sometimes attempts failing shell workarounds instead of a clean rejection) — if a result file is to be produced, start `--role impl`;
  use `research` only for chat answers that are read from the pane.
