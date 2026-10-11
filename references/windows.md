# Windows notes (herdr beta + herd.sh)

> **Experimental.** herdr's Windows support is in beta; the notes below reflect the last verified state.

This file is **not** part of SKILL.md and is only read when needed — namely
when herd.sh causes problems on Windows.

herdr on Windows is officially supported (GA, as of 0.8.2; ConPTY instead of a
Unix PTY). Installation:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
```

There are stable and preview update channels (`herdr channel set
stable|preview`); fresh installs land on stable.

## The old bash.exe problem is history

Until herdr 0.7.4, `herdr agent start` spawned the pane process directly via
`CreateProcessW` — herd.sh had to determine and cache the absolute Windows path
to `bash.exe` for that (`HERD_BASH` in the config; Git for Windows deliberately
does not put `bash.exe` on the global PATH).

Since herdr 0.7.5, herd.sh creates panes via `pane split`/`tab create` (herdr
starts its **default shell** from `config.toml` in them) and types commands or
the agent start into that shell. A `HERD_BASH` entry in the config is therefore
ineffective and can be deleted.

## Requirement: a POSIX shell as the herdr default shell

herd.sh types into the pane shell:

- `start`: on Windows `bash '<logdir>/cmd.sh'` via `pane run`; the file
  contains the backend command (reason: see "Long inputs are slow" below). The
  backend (`codex`, `grok`, …) must be on the PATH of **this shell**.
- `exec`/`run`: `bash '<wrapper script>'` — needs a POSIX shell in the pane.
- `term --shell CMD`: the given command literally.

Recommendation on Windows therefore: configure **Git Bash as the herdr default
shell**, and specifically the real bash instead of the launcher (reason: see
"Session persistence" below). In the herdr `config.toml`:

```toml
[terminal]
default_shell = "C:\\Program Files\\Git\\usr\\bin\\bash.exe"
shell_mode = "login"
```

In addition, set the Windows user variable `MSYSTEM=MINGW64`
(`[Environment]::SetEnvironmentVariable('MSYSTEM','MINGW64','User')`) and
restart herdr afterwards so the server inherits it. Without the variable, the
shell runs in MSYS mode: `/mingw64/bin` is missing from the PATH, `git` comes
from `/cmd/git`. herdr has no config option for pane environment variables.

With that, all herd.sh verbs behave as on Linux; the run directories under
`$TMPDIR/herd-<uid>/` (MSYS: usually `/tmp/herd-<uid>/`) resolve identically in
the MSYS world.

With PowerShell/cmd as the default shell, `term`/`type`/`read`/`key` work.
`start` then needs `HERD_START_VIA=agent` (herdr types the start itself,
provided the backends are on the PATH), `exec`/`run` fail while typing the
bash wrapper. The setsid fallback of `exec`/`run` is not reliable under MSYS
either.

## Long inputs are slow: `start` types only a short call

Measured on 2026-10-02 (herdr 0.9.2-preview 8e78f929, the same with
`usr\bin\bash.exe` and with the Git Bash launcher): input into a pane bash
arrives immediately up to about 150 characters, longer input only at around
23 characters per second. 400 characters take 17 s. Until the line is
complete, the pane displays none of it, and subsequent input queues up behind
it. The pane therefore looks hung, but is not. Whether the cause lies with
herdr or with MSYS/ConPTY is open. Prompts to a running TUI (`send`) are not
affected, measured with 600 characters to claude.

Consequence for `herdr agent start`: for non-PowerShell shells, herdr on
Windows types a Base64-encoded PowerShell command (`powershell.exe …
-EncodedCommand …`, `src/platform/windows.rs`). For claude with a role lock
that is 3,800 characters, i.e. around 165 s, and the start runs into the
timeout. With the Git Bash launcher as the shell, this did not show: herdr
rejected the pane as `not an available shell` (the launcher has the real bash
as a child process), and herd.sh fell back to `pane run` with the ~700
character command and needed ~50 s. With `usr\bin\bash.exe`, herdr accepts the
pane, and every start failed after 2 × 180 s.

herd.sh therefore writes the command to `<logdir>/cmd.sh` and types only
`bash '<logdir>/cmd.sh'` via `pane run`. On Windows it skips `agent start`
entirely (`HERD_START_VIA=auto` chooses `run` there). A claude start then takes
~4 s. With `HERD_START_VIA=agent|run` the path can be forced.

## Live CWD & branch display: OSC 7 shell integration required

The branch/directory display in the spaces sidebar is computed live by herdr
from the **CWD of the root pane in the first tab** of a workspace
(`resolved_identity_cwd_from` in `src/workspace.rs`, verified on v0.8.2). On
Windows, herdr does **not** track `cd` changes in running shells via the
process — without shell integration, the CWD inherited at pane start sticks.
Symptom: a space created via "New" permanently shows the branch of the space
you were on when creating it.

Fix: the shell reports its CWD on every prompt via **OSC 7**
(`\e]7;file:///D:/path\e\\`, percent-encoded). For Git Bash in `~/.bashrc`
(installed on this machine on 2026-08-31):

```bash
__herdr_report_cwd() {
  local LC_ALL=C p="$PWD" enc="" c i
  case "$p" in                              # /d/foo → D:/foo
    /[a-zA-Z])   p="${p:1:1}:/" ;;
    /[a-zA-Z]/*) p="${p:1:1}:${p:2}" ;;
  esac
  for ((i = 0; i < ${#p}; i++)); do         # URL encoding, byte by byte
    c="${p:i:1}"
    case "$c" in
      [a-zA-Z0-9/:._~-]) enc+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; enc+="$c" ;;
    esac
  done
  printf '\033]7;file:///%s\033\\' "$enc"
}
case "$PROMPT_COMMAND" in
  *__herdr_report_cwd*) ;;
  *) PROMPT_COMMAND="__herdr_report_cwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac
```

Notes:

- Shells started **before** the installation must be retrofitted once with
  `source ~/.bashrc`. In panes with a running agent (claude), no OSC 7 gets
  through — the display only heals once the shell is back at the prompt and has
  been sourced once.
- Afterwards, the workspace CWD cannot be set via the API; herdr rejects
  `pane swap` across tabs (`reason: cross_tab`).
- `herdr pane send-text` occasionally swallows the first character — send a
  wake-up `enter` first.
- Diagnosis: `herdr pane get <id>` shows the tracked CWD,
  `herdr pane process-info --pane <id>` the real process CWD.
- The hook only converts drive paths (`/d/…`). For MSYS paths like `/tmp/…` it
  reports an invalid URI, and herdr ignores it.

## Session persistence: do not use the Git Bash launcher as the shell

`C:\Program Files\Git\bin\bash.exe` is only a launcher: it sets `MSYSTEM` and
PATH and starts `C:\Program Files\Git\usr\bin\bash.exe` as a child process.
herdr only knows the launcher, whose directory never changes.

When saving `session.json`, herdr first queries the directory of the shell
process (`cwd_for_persistence` in `src/pane.rs`) and uses the CWD reported via
OSC 7 only as a fallback. The logic probably arrived with #4400 (2026-09-21).
Result with the launcher as the shell: after a `cd`, the live display is
correct, but the start directory is saved. After a herdr restart, the pane
comes back in the old directory, and for root panes of tab 1 so does the space
(`identity_cwd`). Typical symptom: a newly created space that you then switched
into the project via `cd` shows the directory of the space it was created from
again after the restart.

Reproduced on 0.9.2-preview (8e78f929) on 2026-10-01. With `usr\bin\bash.exe`
as `default_shell` (see above), herdr saves the correct CWD. Also tested: a new
space takes over the OSC 7 CWD of the source pane and is then saved correctly
if you `cd` into the target directory before creating it.

## Slash commands: disable MSYS path conversion

git-bash (MSYS) converts arguments passed to native Windows programs if they
look like POSIX paths. `herdr agent prompt <pane> /usage` then arrives in the
pane as `C:/Program Files/Git/usage` — affected were `usage`, `send` with a
slash command, `start --effort` (`/effort`) and `type` with a leading `/`
(found 2026-09-10). herd.sh therefore calls these spots via `herdr_text()`,
which sets `MSYS_NO_PATHCONV=1` only for the respective call. The variable must
NOT be set globally: `exec`/`run` pass `--cwd "$PWD"` as a POSIX path and need
the conversion. So when debugging by hand, use
`MSYS_NO_PATHCONV=1 herdr agent prompt … /cmd`.

## Test suite on Windows

Process starts cost ~50–80 ms in git-bash instead of ~5 ms; `classify-pane`
needs ~0.7 s. `tests/lib.sh` therefore sets the scaled test minute
(`HERD_EVENTS_MINUTE_SEC`) to 3 s instead of 1 s on msys. Start the suite with
`LANG=C.UTF-8 LC_ALL=C.UTF-8 bash tests/run.sh` (otherwise bash does not expand
Unicode escapes in fixtures). A run takes several minutes; never start two runs
in parallel, otherwise the timing-dependent tests tip over.

Known failures on Windows (19, as of 2026-10-02):

- Harmless: T16/T96/T97/T157d/T157d3 (list output not byte-identical),
  T105c/T138c (time), T159h/T161f (exit 137, harness `timeout` against watch),
  T171-unchanged (cwd in the command as `D:/…` instead of `/d/…`).
- Open Windows bugs or tests that are not platform-neutral (as of 2026-09-18):
  T171-impl/T171-research/
  T171-default/T172/T173/T174-state (`herd_opencode.py` does not find
  `opencode`, `[WinError 2]`), T177 (`test_usage_view.py`: encoding/CRLF),
  T168-cli (a minimal PATH is not enough for MSYS), T156m (MSYS `ps` does not
  know `-o`).

After a pull, compare the list of failures at the end of `tests/run.sh` as a
whole with this list: only deviations are suspicious. When an entry is fixed,
strike it here.

## Update: no live handoff on Windows

According to the docs (windows-beta.mdx, v0.9.0), `herdr update --handoff` is
"Unix-only": an update replaces the server, running panes and agent sessions
are lost. Shut down all panes cleanly beforehand (claude sessions via `stop`
with the printed session ID, then `--resume`), then run `herdr update` without
`--handoff`; new terminals use the updated path.

## Known limitations (herdr itself, as of 0.9.0)

- `herdr --remote` **from** Windows to Linux/macOS hosts works (via Windows
  OpenSSH; key auth via `ssh-agent` recommended). Windows as a **target host**
  and live server handoff still do not work (windows-beta.mdx v0.9.0:
  "Live handoff is Unix-only").
- Directory changes after startup are not reliably reported as live CWD without
  shell integration → see the OSC 7 section above.
- Shift+Enter is passed through by the native input path through ConPTY panes —
  provided the outer terminal reports the event distinguishably (otherwise only
  Enter arrives).
- Cursor: the default is a drawn cursor (to avoid flicker); for IME use
  `host_cursor = "native"` in the herdr config.
- Custom commands run via `cmd.exe /d /c`, not `/bin/sh` (unchanged in 0.8.2;
  environment variables there in `%VAR%` syntax).

## Diagnosis

```bash
herdr status            # client/server version, socket reachable?
herdr pane list         # does JSON come back? → socket API ok
```

If `start` fails with an error about unknown flags (`--workspace`, `--split`),
a herdr < 0.7.5 is running → `herdr update`.
