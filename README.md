# deck

[![ci](https://github.com/devfilipe/deck/actions/workflows/ci.yml/badge.svg)](https://github.com/devfilipe/deck/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**The operating layer between a team and its coding agents.**

A coding agent can write the code. What it cannot know is how *your team* ships
it: which repositories a change actually reaches, how far this particular
delivery has to be verified before anyone calls it done, which machines it may
touch, what the team decided months ago and what still has to be asked. That
knowledge lives in people's heads, in habits, and in a wiki page nobody opens —
which is exactly why agent output is uneven, and why reviewing it is tiring.

deck is where a team writes that down: once, in version control, in a form an
agent can execute against and a reviewer can check afterwards.

```
$ deck impact api-schema
a change in api-schema reaches 3 repositories

execution order:
  1. api-schema     build api-schema
  2. api-server     build api-server
  3. web-client     build web-client
  4. e2e-suite      (downstream — keep up, does not build)
```

*(from a four-repository example workspace, built by the tour below)*

## See it work

```bash
./docs/tour.sh                    # a 50-second guided tour, in a temp directory
```

The tour builds a four-repository workspace and a pack from scratch, then walks
from `deck pack new` to a verified delivery with its evidence on disk. It needs
no configuration and touches nothing you own.

## What comes from you

deck ships an engine and no domain knowledge at all. Three things are yours, and
none of them is a gap in the tool:

- **The edges** — which repositories a change forces you to touch. A manifest
  declares a checkout, never a propagation, so no importer can derive them.
- **The commands** — how your project builds, deploys and tests. deck runs the
  strings your pack declares; it has never heard of `bitbake` or `helm`.
- **The decisions** — the calls your team keeps re-making, written once.

They live in a pack, versioned and reviewed like any other code.

## What a team writes down

| | The question it answers | What deck does with it |
|---|---|---|
| **Map** | Where is everything, and what does a change here reach? | Resolves the workspace, imports the registry from how your tree is already assembled, and turns `impacts` edges into execution order and build targets. Two repositories that drive each other get a `couples` edge instead: mutual, and carrying no order, so the order goes on existing |
| **Decisions** | How far do we verify? How do we deploy? May this break a published contract? | Recurring calls declared once with their reasoning — or marked `ask`, so the agent puts *the team's own question* to a human at the moment it matters |
| **Context** | What should an agent know while working here? | Mounts the right packs into the right directories for a piece of work, and takes them back afterwards |
| **Proof** | How far did this actually get verified? | A ladder of gates that records evidence, and never reports as passed something it did not run |
| **Trend** | Is the number behind a passing gate getting better or worse? | A gate can measure as well as judge; the series is kept per run, so decay inside a threshold is visible before it crosses it |
| **Coordination** | What can run at the same time without colliding? | Groups tasks by what they would edit, respecting exclusive resources like a hardware bench |
| **The board** | Where is the work, and who has it? | Reads Jira, GitLab, GitHub, Gerrit or a file, and writes back the two things coordination needs: the claim and the state |
| **Accounting** | What did this cost? | Tokens in and out per model, exact from the session transcript, with a dollar estimate |
| **Boundaries** | What is the agent allowed to touch? | Host allowlists enforced before a command is built, and nothing left behind in a product repository |

## Why this matters to a team

**Consistency stops depending on who ran the agent.** The same task, asked by a
senior and by someone in their first week, produces the same chain of work, the
same verification, and the same questions — phrased the same way.

**Review gets cheaper.** A delivery arrives with evidence: which rung of the
ladder it reached, which gates did not run and why, which decisions were taken
and by whom. A reviewer reads facts instead of re-deriving them.

**Knowledge accumulates instead of evaporating.** The thing you explained twice
this month becomes a toggle with a rationale, or a rule scoped to the files it
applies to. Next time, nobody explains it.

**Nobody keeps a second copy of the backlog.** deck reads the tracker the team
already uses — Jira, GitLab, GitHub, Gerrit — and that is also its whole answer
to working together: the tracker is the shared state. It is already audited,
already has permissions, and already outlives a laptop. A task someone else has
claimed is refused, because two agents on one task produce a merge nobody can
review.

**Autonomy becomes adjustable.** A profile moves the whole posture in one phrase
— ask more and verify to the end for someone new, take the short path for a
hotfix — instead of arguing about it per task.

**A large product can be worked in pieces.** A *scope* names a subset of the
registry — "this initiative is these six of forty" — and carries the board those
repositories work from and the posture that applies while working on them.
`deck --scope <name>` narrows what a command acts on. It never narrows the
graph: `deck impact` still reports the whole chain and marks what falls outside,
because a subset that hides an edge is worse than no subset at all. The scope
report says the same thing from the other end — what the initiative reaches and
does not hold, by the ordered chain and by any `couples` pair it owns one side
of.

## It complements Claude Code; it replaces nothing

deck spawns no agents, creates no worktrees, and renders no UI of its own.
Claude Code already does all three, and better. deck supplies what an agent
runtime cannot know — *your* workspace — and hands it over through the
mechanisms Claude Code already has: skills, `paths:`-scoped rules, plugins at
local scope, the question box, the status line, and the workflow runtime.

The full list of what is deliberately **not** built, and the reasoning behind
each boundary, is in **[DESIGN.md](DESIGN.md)**.

## Install

```bash
git clone https://github.com/devfilipe/deck.git ~/tools/deck
ln -s ~/tools/deck/plugins/deck/bin/deck ~/.local/bin/deck
```

Python 3.10+ and PyYAML. No build step: the entry point runs the package from
the clone. Everything works in a terminal, a script, or CI, with no agent
present.

To let Claude Code use it without being told how, install it as a plugin too —
eleven skills and a cleanup hook. `claude plugin details deck` prints what that
costs in every session:

```bash
claude plugin marketplace add ~/tools/deck      # or the GitHub URL
claude plugin install deck@deck
```

### What deck asks a model, and what it does not

deck calls Claude in exactly one place, for two things a parser cannot derive:
the `impacts` edges, and the wording of a decision. Both are **off by default**,
**read-only** (the runtime is given Read, Grep and Glob and nothing else),
**capped** by `--max-budget-usd`, and land as a **proposal** for a person to
read — never as an edit.

deck never asks a model to write your code, run your build, or edit your
descriptor. The agent in your session writes the code; deck answers before and
records after. [DESIGN.md](DESIGN.md#7-where-the-model-is-and-where-it-is-not)
draws the line in full.

**[FOUNDATIONS.md](FOUNDATIONS.md)** opens with a glossary — deck's own terms,
and every acronym this documentation borrows, expanded. It then answers the
question a team asks before
adopting anything: architecture, style, patterns, security, quality, tests,
build, release — which of those enter deck, through which mechanism, and who
writes the content. Including what deck will never own, and what it does not
cover yet.

**[WALKTHROUGH.md](WALKTHROUGH.md)** starts from nothing: what deck is, what
comes from you, where files go, and both ways teams arrive.

## Start

```bash
cd ~/work/projs
deck setup --packs-root ../ai-packs --create-packs
```

One command from an unprepared workspace to a working one: it reads how your
tree is assembled, writes the descriptor, scaffolds a pack per project, links
them, and ends with the two or three things only a person can decide.

**One convention does the linking.** A pack directory named after a repository
*is* that repository's pack — no mapping table, because a mapping table is a
file nobody keeps current.

```
   projs/                          ai-packs/
   ├── group1/                     ├── _workspace/      ← applies to every repo
   │   ├── proj1/   ────────────►  ├── proj1/
   │   └── proj2/   ────────────►  ├── group1/proj2/    ← groups may be mirrored
   └── group2/proj3/────────────►  └── group2/proj3/
```

Joining a team that already has a pack collection is the same command without
`--create-packs`. Both journeys, step by step:
**[WALKTHROUGH.md](WALKTHROUGH.md)**.

What deck will not invent is `impacts`: a manifest declares a checkout, never a
propagation. Write those edges once, or ask for a draft with `deck propose
impacts`.

## Commands

```bash
deck setup                         # from an unprepared workspace to a working one
deck impact <repo>                 # what a change reaches, in execution order
deck scopes                        # the named subsets of the registry
deck --scope payments board plan   # work inside one: its repositories, board, posture
deck toggle list                   # what is decided, and where each value came from
deck toggle set gate_level build --at workspace --why "the reason, recorded with it"
deck toggle explain gate_level     # why the toggle exists, and why this value was chosen
deck toggle ask-plan --stage plan  # what still has to be asked, as ready questions
deck mount --task PAY-482          # place the packs for a piece of work
deck gate run --task PAY-482       # climb the verification ladder, record evidence
deck bundle --task PAY-482 --write # merge-readiness: what a reviewer reads instead of the diff
deck metrics list                  # what the gates measured, and which way it is going
deck board list | show | new       # the kanban, wherever the team keeps it
deck board claim PAY-482           # take it, under the name the repository publishes as
deck board plan                    # which tasks can run at the same time
deck cost --task PAY-482           # tokens in/out and an estimated cost
deck pack add owner/repo --skills x  # vendor a skill, with its provenance
deck pack update                    # re-check what you vendored against its source
deck propose impacts               # ask Claude to draft the edges, read-only
deck ui --popup                    # the control plane beside a running agent
deck doctor                        # what is missing, and the command that fixes it
```

Domain knowledge — build commands, deployment steps, the decisions particular to
your product — arrives from **extension packs** as declarative data. The engine
knows the shape of a ladder, not what `bitbake` or `helm` are.

```bash
deck pack new my-pack --from-workspace   # the whole skeleton, comments intact
```

A pack is also a Claude Code plugin: the same directory carries `skills/`,
`agents/` and `hooks/` that Claude Code loads directly, plus a `config/` only
deck reads. **[PACKS.md](PACKS.md)** documents the structure field by field, and
`deck pack new` scaffolds one with every comment intact.

## Where deck asks Claude for help

Three of deck's inputs are judgement about a codebase rather than facts a parser
can extract: the propagation edges, the wording of a decision, and the gates and
rules a repository deserves. deck can ask Claude for a draft of any of them —
under four standing constraints.

```bash
deck propose impacts --show-prompt   # see exactly what would be asked. Free.
deck propose impacts --yes           # read-only, capped, writes a proposal
deck propose apply <file> --yes      # after you have read it
```

*Off by default* (`ai_assist`). *Read-only* — the run is given Read, Grep and
Glob and nothing else, enforced by the runtime rather than requested in the
prompt. *Capped* with `--max-budget-usd`. And it produces a **proposal**, never
an edit: a tool that quietly rewrites the file describing how your system
propagates change is a tool nobody should install.

The impacts draft has both kinds of edge to write in. A coupling costs it one
citation per direction — a file for `a` breaking `b`, and a different one for
`b` breaking `a` — because a coupling claims no order, which would otherwise
make it the comfortable answer for every pair a drafter cannot decide. Evidence
one way and a hunch the other is an edge, and the hunch goes back to you.

Every run reports what it cost.

```
schema -> server   [high]
  server/src/orders.ts imports { Order } from "../../schema/generated",
  generated from schema/openapi.yaml; package.json depends on @acme/schema.

unsure: no codegen config exists in either repo, so the regeneration
  mechanism is unverified — the import itself is concrete.

cost: $0.1172 · 6 in / 1200 out · 19.9s
```

## Status

Early, and specific about it.

| Built and tested | Written, not yet proven | Designed, not built |
|---|---|---|
| Workspace resolution · registry importers · impact graph · scopes · toggles and profiles · pack scaffolding, composition and vendoring · mounting · gate ladder · measurements over time · board planning · the merge-readiness bundle · cost reporting · console, status line, tmux surfaces | The `/deck:board` workflow against a workspace anyone depends on — it has run end to end twice, on a sandbox board | Dynamic packs: task-scoped artifacts an agent writes and a human promotes |

```bash
./ci/smoke.sh    # 747 checks against a synthetic workspace; touches nothing of yours
```

## License

MIT © Filipe Denaur de Moraes

## Contributing

**[CONTRIBUTING.md](CONTRIBUTING.md)** — how the project is built, what a good
change looks like, and the three traps in the suite that have each cost time
here. Read [FOUNDATIONS.md](FOUNDATIONS.md) first: it says which concerns enter
deck at all, and the answer is a pack more often than it looks.

Report a defect or a gap through the [issue templates](../../issues/new/choose).
A security issue goes through [SECURITY.md](SECURITY.md), never a public issue.

Everyone taking part is expected to read the
[code of conduct](CODE_OF_CONDUCT.md).
