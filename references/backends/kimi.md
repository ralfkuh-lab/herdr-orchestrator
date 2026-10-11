# Backend: kimi

> Not regularly tested; reflects the last verified state.

- **kimi** — Kimi Code CLI (Moonshot). `role impl` → `--auto` (auto permission:
  writes in the workspace without prompting), `research` → `--plan` (read-only;
  typically ends in a plan approval dialog "Ready to build with this
  plan?" → state `blocked`; `answer <name> "Reject"` ends read-only,
  `"Approve"` lets it implement). `--model` (default from the kimi config, e.g.
  `kimi-code/k3`; also `kimi-for-coding`, `kimi-for-coding-highspeed`);
  no effort flag. Resume: `-c` / `-S <id>`; context reset in-session via
  `/new` (not `/clear`). No cwd flag — the working directory comes from the
  pane cwd (`--cwd` at start still applies). Auth: `kimi login`
  (device code flow). Official herdr integration since 0.7.5 (kind `kimi`);
  the pane heuristics (dialog marker `▶` + "1. Approve") remain as a cross-check.
  ATTENTION: do not clear input with Ctrl+C — 2× Ctrl+C exits the kimi TUI.
