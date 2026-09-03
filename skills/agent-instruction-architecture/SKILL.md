---
name: agent-instruction-architecture
description: Reference for organizing a project's own agent-facing instructions and knowledge - AGENTS.md, docs/, local skills, scripts, and evals. Use when creating a new project's AGENTS.md, when an existing AGENTS.md has grown large or accumulated workflow detail, or when auditing or restructuring how a project's agent instructions and knowledge are laid out.
user-invocable: true
---

# agent-instruction-architecture

A project accumulates agent-facing instructions the same way it accumulates code: casually at
first, then as an unmanaged pile of prose that every agent session has to read in full before doing
anything.
This skill is a small, durable framework for keeping that material organized as the project grows,
so an agent finds the right instruction at the right cost instead of loading everything up front.

## The five-part framework

Sort every piece of agent-facing material into exactly one of these.
Each has a different cost profile - `AGENTS.md` is paid by every session, everything else only by
the sessions that actually need it - and that cost profile is what should drive where a fact goes.

```text
AGENTS.md   = rules of the road - project invariants, architecture boundaries, commands,
              "never do X" rules, and pointers for discovering deeper guidance
docs/       = knowledge about the project - current architecture, product notes, ADRs,
              runbooks, decisions
skills/     = repeatable agent workflows (PR review, migrations, test-failure triage,
              releases, etc.) - loaded on demand, not automatically in context
scripts/CLI = deterministic work - if an instruction says "run these N commands, inspect
              M outputs, then compute X," that's a script, not prose
evals/      = proof the workflows still work - real tasks -> benchmark -> run candidate
              model/skill combinations -> measure quality/cost/reliability
```

Route each new piece of knowledge to one of these, never to whichever file is most convenient to
edit in the moment.

## Rules

**Keep the root `AGENTS.md` small.**
Target roughly 100-250 lines.
Treat anything past ~300-400 lines as a signal that it has accumulated workflows, reference
material, or historical narrative that belongs in `docs/` or `skills/` instead.
An unenforced guideline erodes; prefer a concrete enforced ceiling.
A project that already runs CI can add a lint check that fails the build once `AGENTS.md` (and any
nested `AGENTS.md` files) cross a line or character limit, so the ceiling holds without relying on
every future session to remember it.

**Apply the admission test before adding a line to `AGENTS.md`.**
A candidate line belongs there only if it would affect nearly every agent session in the repo.
If it only matters "when reviewing a PR" or "when touching the data layer," it belongs in a skill
or doc that's discoverable on demand, not something every session pays for whether or not it's
relevant.

**Give `AGENTS.md` a skill/doc router.**
A short table or list mapping "this kind of work -> read this doc/skill first" gives every agent a
single, cheap entry point instead of forcing a choice between loading everything up front or
missing something relevant.
This is cheap to build and high-leverage; do not treat it as a stretch goal reserved for large or
mature projects.

**Prefer pointers over copied detail.**
`AGENTS.md` and skills should point at the authoritative doc, schema, or script rather than
re-explaining it inline.
A fact stated in two places drifts the moment only one of them is updated; a fact stated once and
pointed to twice cannot.

**Reach for evals once a skill's reliability is a real question.**
Evals - real tasks, run through candidate model/skill combinations, measured for quality, cost, and
reliability - are the most valuable and least commonly adopted part of this framework.
They are not something every project needs on day one.
Add them when a skill is load-bearing enough that "does this still work" needs a real answer rather
than an impression, not as a default scaffold for every new project.

## A worked example

A validated real-world instance of this framework in active use: a pnpm monorepo's root
`AGENTS.md`, kept to roughly 120 lines, opens with a short "start here" section pointing at its
`TODO.md` and `docs/README.md`, then carries an "Authority and routing" table mapping areas of the
codebase (the data model, UI, infrastructure, secrets, production data changes, and more) to the
doc to read first and the code or config that stays authoritative over it.
That table is the skill/doc router described above.
Below the table, a short "universal safety and data rules" section holds the handful of invariants
that apply to nearly every change - never print secrets, treat named deployment stages as real and
non-interchangeable, use existing data-access seams instead of parallel ones - and nothing deeper.
Its `docs/` directory is split by kind: `architecture/` for current-state technical docs,
`decisions/` for numbered ADRs recording historical rationale, `runbooks/` for operational
procedures, `plans/` for active design work, and `product/` for product and persona notes, so a
fact lives in the directory that matches what kind of fact it is rather than in one flat pile.
A handful of local skills hold repeatable workflows (deploying a stage, diagnosing CI, authoring a
data migration) that are loaded only when that specific workflow is needed, not on every session.
Finally, its `AGENTS.md` closes with its own "maintaining these instructions" section stating the
size ceiling in characters and naming the CI check (a package script) that enforces it, plus which
kind of fact routes to which `docs/` subdirectory or to `skills/` - so the framework's own
housekeeping is itself a few pointers, not restated prose.

## Applying this to an existing project

When auditing or restructuring an existing project's instructions:

1. Read the current `AGENTS.md` (and any nested ones) in full before changing anything.
2. For each section, apply the admission test: does this affect nearly every session, or only a
   nameable situation?
   Move the latter to `docs/` (if it's knowledge) or `skills/` (if it's a workflow), leaving only a
   one-line pointer behind.
3. Check whether a skill/doc router already exists.
   If not, build one - it is usually the single highest-leverage addition to an overgrown
   `AGENTS.md`.
4. Look for prose restating something the codebase, a config file, or a script's own help text
   already shows accurately, and replace it with a pointer.
5. If the project has CI and lacks a size check, propose adding one rather than relying on manual
   discipline to hold the ceiling going forward.
6. Only after this pass, look for genuinely repeatable multi-step workflows that keep getting
   redone from scratch or reinvented slightly differently each time; those are `skills/` candidates.
   Reserve evals for a skill whose reliability has actually become a question worth measuring.
