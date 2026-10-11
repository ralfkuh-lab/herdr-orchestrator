# Orchestration policy

Your personal workflow policy for the `herdr-orchestrator` skill. Copy this
file to `~/.config/herdr-orchestrator/policy.md` and adapt it.

- The orchestrator reads it **before the first delegation** of a session. Where
  it differs from the skill's defaults, this file wins.
- It is prose for a model, not a schema. Write rules the way you would brief a
  colleague: short, concrete, with the reason where it is not obvious.
- Keep it short. It is read in every orchestrating session, so every line costs
  context. No history, no changelog, no dated anecdotes; git keeps those.
- One rule, one place. If a rule applies to every CLI, write it once here
  instead of duplicating it per model.

## Roles and rankings

Rankings are ordered lists: take the first available candidate that is not the
orchestrator itself. Deviate only when the user says so.

| Role | Ranking | Rule |
| --- | --- | --- |
| Orchestrator | Chosen by the user, otherwise `<your default orchestrator>` | Never when started explicitly as a delegated agent |
| Advisor (ideas, new features, architecture) | `<strongest reasoner>` → `<second>` → … | Second opinion before large design decisions |
| First reviewer (standard review after implementation) | `<strong, affordable reviewer>` → `<second>` → … | Effort set explicitly |
| Plan review for large or complicated features | `<strongest reviewer>`, high effort | Otherwise the first reviewer at high effort |
| Cross review | Next candidate of the same ranking | For critical spots, add the candidate after that |
| Implementer | `<cheap, reliable implementer>` → `<fallback>` → … | Hard tasks (core logic, concurrency, stubborn debugging): `<strong implementer>` |

### Example setup

One way to fill the placeholders. Each role maps to a concrete
`herd.sh start` call, so the orchestrator never has to guess model or effort:

```sh
# Advisor and plan review: strongest model, high effort
herd.sh start codex   --name advisor  --model <frontier-model>  --effort high
# First reviewer: strong but cheaper model, medium effort
herd.sh start claude  --name review   --model <reviewer-model>  --effort medium
# Implementer: fast, inexpensive model; several instances allowed
herd.sh start pi      --name impl-a   --model <provider>/<coding-model> --effort high
# Routine and mechanical refactorings
herd.sh start agy     --name impl-b   --model <fast-model>
```

Model slugs are local preferences, not a benchmark ranking. Check the slug and
the effort values a backend supports before the run; never carry flags over
from one backend to another and never invent effort levels.

### Ground rules

- Keep reviewers free of implementation work, so they stay independent.
- Whoever implemented a change does not deliver an independent review of it —
  the orchestrator included.
- Self-checks do not replace a review. If no reviewer is available, report the
  review as pending and continue with independent work.
- A repeated review by the same reviewer does not replace a cross review.
- On a limit or outage, take the next candidate of the same ranking and hand
  over the current state. Switch models within a ranking without asking, but
  say why; no silent substitutions.
- Failed twice at the same spot: consult the advisor or take it over yourself.
  Do not rotate blindly through models.
- Delegated agents work only on their brief; no orchestration of their own.

### Orchestrator duties

- Planning, specification, architecture, coordination, consolidating reviews,
  final acceptance, communication with the user.
- Choose models by difficulty, risk of error, fit, availability and quota.
  Quality comes before using up free quota.
- Check diffs, key claims and relevant tests yourself. An agent reporting
  success is not proof of acceptance.

## Review depth by risk

| Risk | Examples | Review |
| --- | --- | --- |
| Low | Docs, wording, mechanical changes, small UI tweaks | Orchestrator only |
| Normal | Ordinary features without security or data impact | One review; cross review only if findings look suspicious |
| Critical | Shell and process spawning, network and address filters, prompt injection, migrations, concurrency, data loss | Review plus independent cross review |

### Review economy

Reviews are input-heavy: every tool step resends the whole context, and fresh
sessions explore the repo again. Lower effort barely helps. So:

- **One review per feature or package**, not per stage or correction round.
  The orchestrator checks intermediate states itself (diff, gates).
- **Re-check after corrections** only by the first reviewer, limited to the
  findings and their diff. A new full review only if the fix changes the design.
- **Prepare the review package:** diff as a file, list of relevant files, the
  spec section, and the gates you already ran with their summary lines. The
  reviewer runs targeted tests with trimmed output instead of the whole suite.
- Reviewers get the brief and all acceptance criteria; focus points extend the
  scope, they do not narrow it. Reviewers also check for minimalism: anything
  rebuilt that already exists in the codebase, the standard library or the
  platform is a finding, as are new dependencies and unrequested abstractions.
- A cross review checks its own reference cases before comparing findings.
  Adopting someone else's findings is not independence.
- **Keep the startup context small:** files every agent reads at start
  (`AGENTS.md`, `TODO.md`) stay short; logs and history live elsewhere.
- Start reviews in a fresh or cleared session; keep it open only for questions
  about that review. Pass earlier context again via `send --file`.

### Convergence brake

Before a third correction round on the same package, check whether findings get
fewer and smaller. If not (fixes create new findings, the solution oscillates
between two variants): re-examine spec and root cause, consult the advisor or
take the spot over yourself instead of running more rounds.

## Brief quality and evidence

- Split large work into stages with clear acceptance criteria and a stop point.
- Fix reference cases, fixtures and expected values **before** delegating and
  include them in the brief. The implementer does not invent its own test
  oracle; tests are not adjusted to fit the implementation.
- For core logic, require a **mutation proof**: the test fails without the fix
  and passes with it, both runs quoted verbatim, the mutation done in a copy
  outside the repo. Rerun it yourself. A test that is green without the fix
  proves nothing.
- Name error paths one by one (read error, timeout, command failure, limits,
  special states). A blanket "fail-safe" is not enough.
- The report separates claim from evidence: command plus verbatim summary line.
- Run the first end-to-end flow early in the target environment.
- **Put everything binding into the brief.** Delegated agents do not reliably
  read global instruction files; some only read `AGENTS.md`/`CLAUDE.md` from
  their working directory.
- Every implementation brief includes your minimalism rule verbatim, e.g.:
  understand the problem first; reuse what exists (codebase, standard library,
  platform, installed dependencies) before writing new code; no unrequested
  abstractions; fix bugs at the root cause; never cut input validation, error
  handling against data loss, security or accessibility.

## Quotas

- Before the first fan-out of a session, check limits:
  `herd.sh usage --probe <backends you plan to use>`. Re-check before long
  follow-up runs and on limit messages; no continuous polling.
- A limit that cannot be read is **unknown** — neither free nor exhausted.
  Take percentages only together with their window and meaning.
- Check availability separately from quota. A working CLI does not prove an
  active paid plan.
- Keep work and private accounts strictly apart. In a work setup, allow only
  approved backends via the `BACKENDS` allowlist in
  `~/.config/herdr-orchestrator/config`. Installed CLIs do not define what may
  be used.
- If you suspect high consumption, measure (`usage` before and after the run)
  instead of guessing.

## Worktrees and gates

- **One git worktree per writing agent**, even when it runs alone:
  `git worktree add -b <branch> ../<repo>-<package>` from the accepted commit.
  The orchestrator merges the branches and removes the worktrees afterwards.
- Separate file sets where possible and agree on interfaces up front.
- Run **all gates after every merge** on the combined state. Git does not
  report semantic conflicts (both branches green, the combination breaks).
- Reviewers get a fixed state and experiment in their own copy or worktree.

## Experience log (optional)

Keep a short log per model after each accepted package: task, correction
rounds, missed defects, time to acceptance. Consult it before a non-obvious
model choice. It turns ranking changes into decisions backed by evidence rather
than impressions. The log supplies evidence; only you change the rankings.
