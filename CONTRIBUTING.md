# Contributing

## Principles

- English everywhere: code, comments, messages, docs.
- Minimal changes: reuse what exists (codebase, standard library, herdr itself)
  before adding code; no new dependencies for what a few lines can do; no
  speculative abstractions.
- Python stays compatible with **3.8** (no `X | None`, no `match`); bash >= 4.
- Every behavior change comes with a test in `tests/`; fix bugs at the root
  cause, for all callers.

## Working on a symlinked installation

If your checkout is also your installed skill (`~/.claude/skills/herdr-orchestrator`
or `~/.codex/skills/herdr-orchestrator` is a symlink to it), running sessions use
`SKILL.md` and `scripts/herd.sh` live. Make changes in a separate git worktree
(`git worktree add -b <branch> ../herdr-orchestrator-<topic> main`), test there,
and merge into `main` only when done.

## Continuous integration

`.github/workflows/tests.yml` runs the shell suite and the Python unit tests on
Python 3.8 and 3.12 for every push and pull request.

## Tests

`tests/run.sh` runs the state logic against two fakes in `tests/bin/` — a fake
`herdr` (CLI, for `status`/`list`/`send`/`start`/…) and a fake event server
(TCP, for `wait`/`watch`) — without a running daemon, without real panes,
without backend quota, in seconds. The test blocks are split by topic into
`tests/t-*.sh` (`tests/lib.sh` bundles common helpers and the runner; new tests
go to the end of the matching `t-*.sh`).

```bash
tests/run.sh                # everything
tests/run.sh --phase before # characterization only (existing behavior)
tests/run.sh T6 T8          # individual cases
python3 -m unittest discover -s tests -p 'test_usage_parser.py' -v # usage parser only
```

`scripts/herd_parse.py` contains the pure usage and dialog parsers with
structured return values (`parse_usage`, `parse_dialog`) as well as the
evaluation of horizontal option bars. CLI adapters keep the previous protocols.
The direct tests compare outputs and exit codes with reference cases recorded
before the extraction, and for dialogs also the stderr diagnoses.
`scripts/herd_usage_view.py` reconstructs agy pages from their positions; 25
reference runs also cover read steps and key sequences.
`tests/run.sh T175 T176 T177` includes the three test modules in the overall
suite. Freshness checks, terminal access, key input and cleanup stay in
`herd.sh`.

Common test setups live in `tests/lib.sh`: `fixture_dir` selects the case
directory, `pane_after_files` lays down a sequence of byte-exact pane snapshots,
and `check_python_tests` checks test execution and the minimum number of tests
found. Read counters and case-specific expectations stay under the test case's
control.

Characterization tests (`char`) pin down **existing** behavior and must be
green before *and* after a refactoring; if one turns red, the refactoring
changed the behavior. If you work on `wait`/`watch`/`status`/`send`, run them
first.
