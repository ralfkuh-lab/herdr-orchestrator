# herdr-orchestrator

An agent skill for Claude Code and Codex that remote-controls the
[herdr](https://herdr.dev) terminal workspace. The orchestrating model delegates
work to other coding agents running as **interactive live sessions in visible
panes**, watches them, answers their approval dialogs and collects their results
from files and `git diff` — while you can see every pane and step in at any
time. Token efficiency comes from prompt discipline: agents write their results
to a file instead of the orchestrator pulling the TUI scrollback into its
context.

The skill has two roles, both built on herdr:

1. **Delegation** to coding agents (backends: `codex`, `agy`, `opencode`,
   `claude`, `copilot`, `grok`, `kimi`, `muse`, `pi`). The orchestrator does
   plan/spec, architecture and quality control and steers the sub-agents:
   send prompts, wait for them to settle, answer approval dialogs, read the
   result from a file or `git diff`.
2. **Terminal/pane control**: open empty terminals, type a command into them
   for you (which *you* run or confirm with your sudo password), read the
   output directly, drive SSH sessions — without clipboard ping-pong.

Compared to a non-interactive one-shot, a live session gives you visible
control, a live dialog including slash commands, and context persistence across
several stages (the sub-agent does not have to re-explore the repo every time).

## Features

- One verb interface (`scripts/herd.sh`) for nine agent backends, with role
  flags (`impl` = may write, `research` = read-only where the backend supports it — pi has no sandbox) mapped per backend.
- Prompt acceptance check on `send`: detects prompts that never arrived and
  resends once.
- Event-based watching (`watch`/`wait`) with explicit states: `idle`, `done`,
  `blocked`, `question`, `limited`, `failed`, `auth`, `stalled`, `background`,
  `unknown`, `lost`.
- Approval dialogs answered by option text (`answer`), never by blind key
  presses.
- Written agent questions (`QUESTION: <path>` marker) instead of silent stops.
- Usage limits read from the agents' TUIs (`usage`) as a preflight before
  fan-outs.
- Recursion guard so delegated agents do not start orchestrating themselves —
  a role line in every brief plus backend-specific locks; model instructions,
  not an access control (SKILL.md §3).
- Space isolation: name-based verbs only reach agents in your own herdr space.
- Batch mode (`exec`/`run`) for unattended runs, also without herdr.

## Requirements

- `herdr` **>= 0.8.2**; for the `muse` backend **>= 0.9.0**. `wait`/`watch`
  need the stable event API `events.subscribe` and exit with 2 without it;
  even older versions also lack `agent start --kind/--pane`, `agent prompt` and
  `pane wait-output` (`herdr update`).
- **Bash >= 4**.
- **Python >= 3.8** (no third-party packages). Required for `wait`/`watch`
  (event path) as well as `answer`/`list`; without python3, `wait`/`watch` exit
  with 2.
- At least one of the backends on your `PATH`.

## Installation

### a) With `npx skills`

```bash
npx skills add ralfkuh-lab/herdr-orchestrator
```

### b) From a git clone (symlinks)

```bash
git clone https://github.com/ralfkuh-lab/herdr-orchestrator.git ~/dev/herdr-orchestrator
# Create one or both links, depending on the orchestrator you use.
mkdir -p ~/.claude/skills ~/.codex/skills
ln -s ~/dev/herdr-orchestrator ~/.claude/skills/herdr-orchestrator
ln -s ~/dev/herdr-orchestrator ~/.codex/skills/herdr-orchestrator
```

With symlinks, `git pull` updates the installed skill in place.

### Permission allowlist (recommended)

If the orchestrator runs in an environment with command approvals (Claude Code
`settings.json`), allow the watching and answering verbs — otherwise **every**
approval dialog of a sub-agent ends up with you, and the orchestrator cannot
continue autonomously:

```json
{ "permissions": { "allow": [
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh answer *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh key *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh send *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh read *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh status *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh wait *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh watch *)",
  "Bash(/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh usage *)"
] } }
```

**Add these rules yourself, once — ideally BEFORE the first delegation run.**
The orchestrator cannot do it: the auto-mode classifier blocks both editing
`settings.json` and patching `scripts/herd.sh` as self-escalation (rightly so).
Without the rules, the orchestrator has to ask you to click in the pane for
**every** sub-agent dialog. Once added, the rules take effect immediately,
without restarting the session.

The rules only apply on a **literal match** — so the orchestrator always spells
out the path and uses no variables or pipes (see "The canonical loop" in
[`SKILL.md`](SKILL.md)). If `~/.claude/settings.json` is a symlink, edit the
target file.

**What these rules delegate:** with them, the orchestrating model — not you —
decides on every approval dialog of its sub-agents, including shell commands
and file access outside the working directory; the same holds for full/YOLO
modes (`/permissions full`, `--yolo`, `--always-approve`) and batch runs.
Pane content is not authenticated: a sub-agent can print text that looks like
a dialog or an instruction. The skill therefore tells the orchestrator to
`answer` only requests that fit your brief and whose concrete command it has
read, and never to treat a displayed recommendation or option as
authorization (SKILL.md §8). Grant the rules only if you accept that trade-off.

## Configuration

Both files are optional and private; they live outside the repo so that
updates never overwrite them.

```bash
mkdir -p ~/.config/herdr-orchestrator
cp examples/config.example    ~/.config/herdr-orchestrator/config
cp examples/policy.example.md ~/.config/herdr-orchestrator/policy.md
```

- **`config`** (path overridable via `HERD_CONFIG`) — mechanics, sourced as
  shell code by `herd.sh`: backend allowlist `BACKENDS`, default models
  `MODEL_<BACKEND>`, providers for opencode/pi, permission mode, tabs, cleanup,
  watching, automatic folder trust. Without the file: all installed backends,
  no default models. Every variable is explained in
  [`examples/config.example`](examples/config.example). Being shell code, the
  file runs with your rights — keep it as private as your shell profile.
- **`HERD_AUTO_TRUST=0|1`** (config or environment, **default `0`**) — whether
  `start`/`exec` pre-trust the working directory for backends with a trust
  dialog. A trusted folder makes the backend load the project's own
  configuration, skills and hooks. At `1`: codex and muse trust it for the
  session, pi for the run (`--approve`), grok **permanently** via
  `~/.grok/trusted_folders.toml`. At `0` codex, grok and muse ask, and the
  orchestrator handles the dialog like any other (grok's dialog is invisible to
  `status`; `start` warns); pi gets `--no-approve` — no dialog, project
  resources stay unloaded. Enable it only for repositories you trust.
- **`policy.md`** — prose for the orchestrating model: roles, which backend and
  model implements or reviews what, review rules. The orchestrator reads it
  before the first delegation, and it takes precedence over the skill's
  defaults. This keeps your personal routing preferences (subscriptions,
  rankings, review depth) out of the skill itself, so the skill stays generic
  and updatable. Template: [`examples/policy.example.md`](examples/policy.example.md).

## Quick start

From the orchestrating session (Claude Code or Codex inside a herdr pane).
`<herd>` stands for the absolute path to `scripts/herd.sh`, e.g.
`/home/<user>/.claude/skills/herdr-orchestrator/scripts/herd.sh`; the
orchestrator always spells it out (no variables, see the allowlist above).

```bash
<herd> start codex --name feat-x --role impl --cwd "$(pwd)"           # 1) start a session in a new pane
<herd> send feat-x "Implement … Write the report to .herd/feat-x.md."  # 2) send the brief
<herd> watch feat-x                                                    # 3) watch: one line per event
<herd> read feat-x --source visible                                    #    on "blocked": look at the dialog …
<herd> answer feat-x "Yes"                                             #    … and answer it by option text
cat .herd/feat-x.md; git diff                                          # 4) collect the result
<herd> stop feat-x                                                     #    close the pane
```

In practice you just ask your orchestrating agent to delegate a task; the skill
tells it how to run this loop.

## Verbs

```
herd.sh start <backend> --name N [--role impl|research] [--cwd DIR] …
herd.sh send  <name> <text…>        # prompt/slash command + Enter (waits for acceptance)
                                    #   exit 0 accepted · 75 UNCERTAIN · 1 error
herd.sh status <name>               # instant poll, one state, non-blocking
herd.sh wait  <name> [--timeout MIN]# ONE event, then exit → idle|done|blocked|
                                    #   limited|auth|failed|question|stalled|lost
                                    #   exit 0 event · 124 TIMEOUT (agent keeps running!)
herd.sh watch <name…> [--timeout MIN] [--max-events N]
                                    # watch several agents CONTINUOUSLY: one line
                                    #   "<name> <status>" per event, keeps
                                    #   running afterwards (monitor command)
herd.sh list                        # inventory: "<name> <status> <pane>" per agent
herd.sh read  <name> [--source visible|recent|recent-unwrapped]
herd.sh answer <name> "<option text>"        # answer a dialog by option TEXT
herd.sh key   <name> <enter|esc|up|down|…>   # send single keys
herd.sh stop  <name>                # close the pane
herd.sh usage <name…>               # usage limits from the TUIs: one tab-separated line per agent
herd.sh usage --probe [codex,grok,agy,claude,muse]  # same, with throwaway sessions per backend
herd.sh usage --raw <name>          # raw pane block only (diagnosis)
herd.sh term  --name N [--shell CMD]# open an empty terminal pane
herd.sh type  <name> <text…>        # type a command WITHOUT Enter (you run it)
herd.sh exec  <codex|opencode|copilot|grok|kimi|muse|pi> … # batch/fire-and-forget (exception)
herd.sh run   … -- CMD              # any command in a pane
```

## Documentation

- [`SKILL.md`](SKILL.md) — what the orchestrating model loads: roles, writing a
  brief, the canonical loop, wake-up duty, states and exit codes, dialogs,
  agent questions, backends at a glance, configuration, known limits, quality
  control.
- [`references/`](references/) — details loaded on demand: one backend profile
  per backend in [`references/backends/`](references/backends/),
  [`usage.md`](references/usage.md), [`dialogs.md`](references/dialogs.md),
  [`watch-internals.md`](references/watch-internals.md),
  [`herdr-cli.md`](references/herdr-cli.md),
  [`codex-orchestrator.md`](references/codex-orchestrator.md),
  [`windows.md`](references/windows.md) (experimental).
- [`examples/`](examples/) — templates for `config` and `policy.md`.
- `scripts/herd.sh` — the verb interface over the herdr socket API; logs of
  batch runs in a private per-user directory
  (`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/herd-<uid>/<run>/`, mode 0700).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) (tests, conventions).

## License

MIT — see [`LICENSE`](LICENSE).
