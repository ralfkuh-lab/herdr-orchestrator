# herdr CLI primitives (raw socket API)

Distilled from the official herdr skill (ogulcancelik/herdr, SKILL.md) and the
CLI help, as of **0.7.5**. When in doubt, the installed binary is the
authority: `herdr <group>` without a subcommand lists the commands (NOT bare
`herdr` — that attaches the TUI).

**When to use the raw CLI instead of herd.sh:** wait for specific output
(`pane wait-output`), read arbitrary panes, manage tabs/workspaces, split panes
deliberately. **For agent delegation always use herd.sh** (dialog guard, role
flags, recursion guard, status cross-checks) — the primitives here are the
layer below.

## IDs & status

- IDs are **opaque stable handles**: workspace `w1`, tab `w1:t1`, pane
  `w1:p1`. Closed IDs are not reused. **Always parse them from the JSON
  responses**, never guess or derive them from the sidebar order.
- Own context via env: `$HERDR_WORKSPACE_ID`, `$HERDR_TAB_ID`,
  `$HERDR_PANE_ID`; for your own pane use `--current`. Without a target, herdr
  may pick the UI-focused pane — that may belong to the user!
- `agent_status`: `idle | working | blocked | done | unknown`.
  `done` = idle after background work whose tab has not been viewed yet
  (CLI reads do NOT mark it as viewed). `blocked` = detected approval/question
  dialog. `unknown` does not prove completion.

## Panes

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"   # json; focus, labels, status
herdr pane current --current                        # your own pane
herdr pane read w1:p2 --source recent-unwrapped --lines 120   # text
herdr pane read w1:p2 --source visible --format ansi          # rendered snapshot
herdr pane split --current --direction right --cwd "$PWD" --no-focus
                                                    # json → result.pane.pane_id
herdr pane run w1:p3 "npm run dev"                  # text + Enter, atomic
herdr pane send-text w1:p1 "hello"                  # without Enter
herdr pane send-keys w1:p1 enter                    # esc = canonical escape name
#   Several keys per call: send-keys w1:p1 down down down
#   Known (verified 2026-09-09, herdr 0.9.0): up down left right enter esc tab
#   backspace space f1 ctrl+c ctrl+u shift+tab alt+enter — NOT: pgdown/pgup/
#   page_up/pageup, end, home, ctrl+end, delete (response: invalid_key
#   "unsupported key …"). So page through scrollers like agy's /usage with N×down.
herdr pane rename w1:p3 "logs"                      # set label
herdr pane close w1:p3
```

Parse the new pane ID directly:

```bash
NEW=$(herdr pane split --current --direction right --cwd "$PWD" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```

Read sources: `visible` (current viewport), `recent` (with soft wraps),
`recent-unwrapped` (wraps joined — prefer for logs/transcripts), `detection`
(plain-text snapshot of the agent detection).
For VERY fresh panes (< ~2 s, no output yet),
`recent`/`recent-unwrapped` return empty — `visible` works immediately
(observed with herdr 0.7.5; herd.sh heuristics therefore read `visible`).

**Alternate-screen trap:** if the TUI runs on the alternate screen,
scrolled-off lines do NOT land in the scrollback — more `--lines` then brings
nothing to light. Fallback: ask the agent to write the complete answer as a
Markdown file and just name the path; read the file directly.

## Waiting for output

```bash
herdr pane wait-output w1:p3 --match "ready on port 3000" --timeout 30000
herdr pane wait-output w1:p3 --regex "server.*ready" --timeout 30000
```

- Searches the chosen snapshot immediately (default `recent`) — already
  existing output matches; after that, polling. Without `--timeout` it waits
  indefinitely; timeout → exit code 1. `--regex` is a Rust regex.
- Matches against unwrapped text (line breaks from the pane width do not break
  the match). To inspect the same transcript:
  `pane read … --source recent-unwrapped`.

## Agents

Agent commands address by **unique agent name or pane ID** (no terminal IDs, no
child labels). Names: `[a-z][a-z0-9_-]{0,31}`, unique among living agents; the
name expires when the agent ends.

```bash
herdr agent list
herdr agent get reviewer
herdr agent read reviewer --source recent-unwrapped --lines 120

# start: needs an EXISTING shell pane at the interactive prompt.
# agent start NEVER splits/creates layout itself. Native agent args after --.
herdr agent start reviewer --kind codex --pane w1:p3 --timeout 60000 -- -s read-only
#   → returns only once the agent is detected and ready for input
#   Kinds include: codex, claude, gemini, agy, opencode, copilot, grok, kimi,
#   muse (manifest on master since 2026-08-27; NOT in 0.8.2 stable,
#   only in a preview build from 2026-08-31 or the next stable after that)

# Prompt: submits text + Enter ATOMICALLY (bracketed-paste safe).
herdr agent prompt reviewer "Review the current diff." --wait --timeout 120000
#   --wait waits for the first settled state (idle|done|blocked).
#   No status change within 5 s → error agent_prompt_stalled (instead of forever).
#   --until <status> (repeatable) for specific target states.

herdr agent wait reviewer --until blocked --timeout 120000
#   without --until: settled default (idle|done|blocked)
herdr agent send-keys reviewer esc       # single keys (ctrl+c, up, down, …)
```

## Tabs & workspaces

```bash
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr tab create --workspace w1 --cwd /path --label "logs" --no-focus
   # json → result.tab, result.root_pane (fresh shell pane!)
herdr tab rename w1:t2 "logs" ; herdr tab focus w1:t2 ; herdr tab close w1:t2

herdr workspace list
herdr workspace create --cwd /path --label "api" --no-focus
   # json → result.workspace, result.tab, result.root_pane
herdr workspace focus w2 ; herdr workspace rename w1 "api" ; herdr workspace close w2
```

## Recipe: start a server and wait for readiness

```bash
NEW=$(herdr pane split --current --direction right --cwd "$PWD" --no-focus | python3 -c '…pane_id…')
herdr pane run "$NEW" "npm run dev"
herdr pane wait-output "$NEW" --match "ready" --timeout 30000
herdr pane read "$NEW" --source recent --lines 20
```

## Server restart: agent resume

Always update with `herdr update --handoff` — then the agent processes keep
running. Without handoff (or if it fails), herdr from 0.9.2 on reopens agent
panes with their session (`claude --resume <id>`, `codex resume <id>`,
`agy --conversation <id>`, `grok --resume <id>`, `pi --session …`,
`opencode --session <id>`), provided the **official integration is up to date**
(`herdr integration status`; as of 2026-10-01 all backends in use are
`current`, copilot not installed). The resume command carries no herd.sh start
flags — neither model/effort nor work/permission mode (`--mode`,
`--permission-mode`, `-s`). After a restart, check the footer and, if in doubt,
set the agent up again with `stop` + `start … --resume <id>`. Self-reporting
via `pane report-agent` from herd.sh was deliberately dropped: the source
would have to hold the pane and keep reporting states, otherwise it freezes the
status or competes with the integration. Only muse would have benefited from
it.

## Safety and coordination rules (from the official skill)

- `HERDR_ENV=1` indicates that you are running inside a herdr pane yourself —
  without it, do not issue control commands.
- `--no-focus` for background work; never rely on the focused pane of another
  client.
- Do not close workspaces/tabs/panes/sessions you did not create yourself
  (unless the user explicitly asks for it).
- NEVER `herdr server stop` from an active session; never kill the main herdr
  process. For experiments use named test sessions (`--session <name>`)
  (recipe below).
- Server errors: JSON on stderr, exit 1; CLI syntax errors: exit 2.
  list/create/split commands print JSON; `pane read` text;
  `send-text`/`send-keys`/`run` print nothing on success.
- NOTE recursion guard: these primitives belong to the **orchestrator**.
  Delegated sub-agents must not open/control panes (see SKILL.md, section on
  the recursion guard).

## Recipe: throwaway session for live tests

Based on the official herdr skill `herdr-throwaway-repro` (herdrdev/herdr,
`.agents/skills/`). For live checks that need real panes, agents or the socket
without endangering the main session (dialog formats, false status reports,
`start` behavior).

1. Create your own outer pane (`herdr pane split … --no-focus`, cwd e.g.
   `/var/tmp/herd-repro-<topic>`), note its pane ID — only this pane may be
   closed later.
2. Write a test config with `[experimental]` `allow_nested = true` into the
   test directory (never change the global config, do not remove `HERDR_ENV`)
   and check it with `HERDR_CONFIG_PATH=<path> herdr config check`.
3. In the outer pane, start the session with inherited addresses removed:
   `env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_SESSION
   -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID
   HERDR_CONFIG_PATH=<path> herdr --session repro-<topic>`. Then read the outer
   pane (e.g. `nested herdr is disabled by default`).
4. Issue **every** control command with the same `env -u …` prefix and
   `HERDR_SESSION=repro-<topic>`; check readiness with `pane list`.
   Always read IDs from the output, never construct them. `herd.sh` can also
   be run against the throwaway session this way.
5. Clean up, even after a failure: `herdr session stop repro-<topic>`, then
   `herdr session delete repro-<topic>`, check that it no longer runs, and
   close only your own outer pane. **Never** `pkill` or search for processes
   by environment variables — one wrong hit takes down the production server.
