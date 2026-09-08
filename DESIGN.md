# deck — architecture

deck is a control plane for coding agents working across repositories. It holds
the state an agent needs before it can safely change more than one repository,
and it hands that state to Claude Code rather than replacing any part of it.

This document explains what deck is made of, what it deliberately does not
build, and why the boundary sits where it does.

---

## 1. The premise

Ask an agent for a feature in a multi-repository system and three failure modes
show up, none of which is a model problem:

| Failure | What it looks like | What is actually missing |
|---|---|---|
| **It forgets the chain** | The schema changes, the client does not. The build passes and the behaviour does not exist. | A declared graph of what a change propagates to |
| **It decides silently** | It picks the fast deployment path, or skips the regression suite, and nothing in the output says so. | Recurring decisions declared once, with an explicit "ask me" state |
| **It cannot prove anything** | "Done" is a claim. Nobody can check which rung of verification was reached. | Gates that record evidence, and never round *not run* up to *passed* |

None of that is knowledge a model can derive from the code. It is knowledge
about *your* system, and it has to be written down somewhere.

---

## 2. Where deck sits

```
        ┌──────────────────────────────────────────────────────┐
        │                     Claude Code                      │
        │                                                      │
        │   agents · subagents · worktrees · workflows         │
        │   permissions · hooks · plugins · skills             │
        │   plan mode · question boxes · status line           │
        └───────────────┬──────────────────────┬───────────────┘
                        │ reads                │ runs
                        ▼                      ▼
        ┌──────────────────────────┐   ┌──────────────────────┐
        │   mounted artifacts      │   │   the deck CLI       │
        │   rules · skills · CLAUDE│   │                      │
        │   .local.md · settings   │   │  workspace · impact  │
        └──────────────┬───────────┘   │  toggles · mount     │
                       │ placed by     │  gates · metrics     │
                       └───────────────┤  board · cost        │
                                       └──────────┬───────────┘
                                                  │ reads
                                                  ▼
                                  ┌───────────────────────────────┐
                                  │  .deck/  (per machine)        │
                                  │   workspace.yaml  the graph   │
                                  │   toggles.yaml    the choices │
                                  │   gates/          evidence    │
                                  │   metrics/        the series  │
                                  │   mounts/         what is out │
                                  └───────────────┬───────────────┘
                                                  │ extended by
                                                  ▼
                                  ┌───────────────────────────────┐
                                  │  packs  (versioned, shared)   │
                                  │   toggles · gates · rules     │
                                  │   detect · templates          │
                                  └───────────────────────────────┘
```

deck is a plain CLI. Claude Code calls it through skills; a person calls it in a
terminal; a script calls it in CI. Nothing about it requires an agent to be
present.

---

## 3. What deck does not build

This is the important half of the design. Claude Code already ships a great deal
of what a "multi-agent delivery system" would otherwise reinvent.

| Capability | Claude Code already has | deck's position |
|---|---|---|
| Spawning and coordinating agents | Subagents; the Workflow runtime with `agent()`, `parallel()`, `pipeline()`, resume, a progress view, and caps | **Never reimplemented.** deck emits a plan; a workflow executes it |
| Isolating parallel work | `--worktree`, `EnterWorktree`, `isolation: worktree` on a subagent, automatic cleanup sweep, `.worktreeinclude` | **Never reimplemented, and deliberately not used by the board workflow.** A worktree is made of one repository; a deck workspace is usually several and its root is often not a checkout at all. What keeps concurrent tasks apart here is the grouping, which is the guarantee deck actually offers |
| Loading instructions per directory | `CLAUDE.md` up the tree and lazily in subdirectories, `.claude/rules/` with `paths:`, skills by description | **Used as the mechanism.** Mounting places artifacts into these surfaces rather than inventing a loader |
| Enabling extensions per directory | Plugins at user / project / **local** scope; project-scope plugins inherit into worktrees | **Used as the mechanism.** A mount is mostly three lines in `settings.local.json` |
| Asking the operator a question | `AskUserQuestion` — headers, options, descriptions | **Used as the mechanism.** deck supplies the wording; Claude Code renders it |
| Pausing for approval | Plan mode, `ExitPlanMode` | deck's `plan_approval` toggle is the *policy*; plan mode is the *mechanism* |
| Reviewing code and security | `/code-review`, `/security-review` | **Not rebuilt, and not invoked from inside a run** — a workflow agent has no way to run a slash command. The board's last phase reviews *the delivery*, not the code: what changed, which rung was reached, what went unverified. It ends by telling the human to run the real reviewer |
| Remembering across sessions | Auto memory, per repository | Overlaps with dynamic packs. Auto memory keeps what an agent learned locally; a pack keeps what the *team* agreed, under review |
| Reporting session cost | `cost.total_cost_usd` in the status-line payload | **Treated as authoritative.** deck reports tokens from the transcript and shows Claude Code's dollar figure beside its own estimate |

What is left is the part no agent runtime can know: **this workspace**. That is
deck's entire surface area.

---

## 4. The engine and the packs

> Which engineering concerns enter deck, through which mechanism, and who owns
> the content, is set out in **[FOUNDATIONS.md](FOUNDATIONS.md)** — including the
> rule that decides where a thing goes, and the list of what is not covered.


The engine knows the *shape* of things. Every specific — a build command, a
deployment step, a domain decision, a detection marker — arrives from an
extension pack as declarative data.

```
   deck (engine, MIT)                pack (yours, private or shared)
   ─────────────────────             ──────────────────────────────
   how a ladder works        ←───    which rungs, and their commands
   how toggles resolve       ←───    which decisions exist in this domain
   how a workspace is found  ←───    which files identify one
   how a registry is built   ←───    (importers are core: layout is generic)
   how artifacts are placed  ←───    which artifacts, and where they apply
```

The rule that keeps this honest: **if serving an organization requires editing
the engine, the feature is in the wrong layer.** `deck-acme` exists to prove it
— an example pack for a fictional SaaS, kept working unedited on every change.

### Composition

A pack merges its catalog into the core's. Extending an entry the core defines
requires repeating the `id` with `overrides: true`; a collision without that
flag is refused, so nobody shadows a core decision by accident.

```yaml
- id: deploy_mode        # core concept: how far the artifact travels
  overrides: true        # this domain's actual rungs
  values: [none, fast, packaged]
  question:
    options:
      - { value: fast, label: Sync into the pod, description: "Seconds; diverges from the image." }
```

---

## 5. The pieces

| Module | Answers | Notes |
|---|---|---|
| `workspace` | Where is the root? Which repositories? What does a change reach? | Root resolution has four sources and never guesses. The impact graph gives transitive reach, topological order, and build targets, over two kinds of edge: `impacts:` is directional and ordered, `couples:` is mutual and carries no order. A **scope** names a subset of the registry and narrows what a command acts on — never what the graph knows. A pack may belong to one, through `scope:` in its own `config/detect.yaml`: it loads while that initiative is active and nowhere else, and the scopes every pack ships are merged while the registry is taken from one template — a second opinion about the graph is a contradiction, a second initiative is not |
| `importers` | Can the registry be derived? | Reads a Google `repo` manifest with includes, `.gitmodules` via git itself, or npm workspace globs. Never derives `impacts` — a manifest declares a checkout, not a propagation |
| `toggles` | What is decided, and what must be asked? | Seven precedence layers, a three-state model, and a question written in the catalog rather than improvised |
| `mount` | How does a pack get into a working directory, and back out? | Plugin entry → symlinked rule → copied file, in that order of preference |
| `gates` | How far was this verified, and can it be checked? | Ladder declared by packs; evidence recorded pass or fail |
| `metrics` | Which way is the number behind a passing gate going? | A gate may declare `measures:`; the engine reads the number out of the output that gate already produced and appends it to a series. It fails nothing — a trend that blocked a merge would be a threshold again, and one nobody chose |
| `board` | What can run at the same time? | Conflict is about what would be *edited*, not what is reached |
| `bundle` | Is this ready to merge, and what would a reviewer have to take on trust? | Assembles the gate record, the impact chain, the toggle layers with the reason recorded beside each, the consultations and git into one page. Derives everything and asserts nothing: each claim names the file it came from |
| `trackers` | Where is the work, and who holds it? | Jira, GitLab, GitHub, Gerrit or a file. Tokens are resolved at call time — environment, netrc, or a command the descriptor names — and never read from a descriptor |
| `cost` | What did it cost, in tokens and dollars? | Tokens exact from the transcript; dollars an estimate, labelled as one |
| `assist` | What can a parser not derive? | Headless Claude, read-only and capped, producing a proposal that a person applies — never an edit |
| `console` · `ui` · `statusline` | How does a person watch and steer it? | A REPL, a tmux split or popup, and rows inside the agent's own window |

### Two kinds of edge

`impacts:` answers two questions with one edge — *what must I revisit*, and *in
what order*. That is the right shape for most of a workspace, and it is what
makes `deck order`, the build chain and the cycle check possible at all.

It is the wrong shape for a relationship that answers the first question and has
no answer to the second. A schema repository seeds a configuration a scripts
repository reads, and the scripts repository owns the command line the first one
calls at runtime: each side breaks the other, with file-and-line evidence in
both, and neither goes first. There were three ways to hold that and only one of
them keeps both halves:

| | What it costs |
|---|---|
| Declare one direction, write the other as a prose rule | The constraint survives as text. No command can use it, and `deck impact` on the second repository does not mention the first at all |
| Declare both as `impacts:` | A cycle. The topological order stops existing for that pair, and every consumer of `deck order` — the gate ladder, the plan, the bundle — has to cope with a graph that no longer has one |
| **A third kind of edge** | `couples:`, symmetric and order-free |

`couples:` is read by `deck impact`, which lists it apart from the ordered
chain, and by `deck mount`, which places the packs for a repository the work may
have to be edited in. It is read by nothing that sorts: `order()` and `cycles()`
never look at it, which is precisely why a coupling can never make the graph
cyclic and why the order goes on being computable. It is symmetric — one side is
enough — and not transitive, because "forces a change in" composes and "drives
each other" does not.

`deck board plan` does not read it either. Grouping asks whether two tasks may
run at once, and that is about what would be *edited*; a coupling says "revisit
before you ship", and a revisit that changes nothing collides with nothing.

Those two answers are opposite, so no later surface is settled by pointing at
them. What settles one is what its answer is spent on. `board.closure()` decides
which tasks may not run beside each other, and there a name too many is a
collision that never existed and work serialised for nothing. `deck mount` only
places files, and a report only tells a person. So: **a surface that reports
reads `couples:`; a surface that sorts, schedules or excludes does not.**

That rule puts the coupling into the one report a scope exists to produce. A
scope leaks two ways — the chain its `impacts:` reach and the coupled pair it
holds one side of — and both belong to the person drawing the boundary. Left
out, `deck scope` printed *the boundary is closed* over a pair with
file-and-line evidence on both sides, while `deck impact` on a repository inside
that same scope named it: two surfaces read side by side, disagreeing. The two
halves are printed apart and never merged into one list, for the reason `deck
impact` keeps them apart — only one of them carries an order, and one list would
lend it to the other.

`deck propose impacts` drafts both kinds, and what separates them in the draft
is not left to taste: a coupling costs one citation per direction, in two fields
of the proposal, because it claims no order and would otherwise be the cheap
answer for every pair a model cannot decide. Evidence one way and a hunch the
other is an edge plus an `unsure` note. A draft that names one pair in both
directions is applied as the coupling it is — the same two `impacts:` edges
written by hand stay a cycle, because someone can type those and mean them.

### Toggle precedence

```
   strongest ──────────────────────────────────────────────────────────► weakest

   task file     DECK_<ID>       repos:          scopes:      values:      profile   catalog
                 in the env      block           block        block                  default
   ─────────     ──────────      ──────          ───────      ───────      ───────   ───────
   one task      one command     one repository  one          this         a         the team's
                                                 initiative   machine      posture   policy
```

Each layer is wider than the one before it: this task, this command, this
codebase, this initiative, this machine. The narrowest that has a value wins.
`deck toggle set --at <task | workspace | a scope name>` writes into one of
them, and `deck toggle explain` names the one an effective value came from.

The special value `ask` is not a value. It is an instruction to put the
catalog's own question to the operator at the declared stage.

### Why a value, not just which

A layer says who decided; it does not say why. `gate_level` was lowered from
`deploy` to `build` in a real workspace because delivery went through a firmware
update path nobody had wired to deck. The value was right and the sentence
explaining it lived in a chat log, so months later nothing distinguished it from
a value nobody had revisited.

```bash
deck toggle set gate_level build --at workspace \
  --why "delivery goes through a firmware update path nobody has wired to deck yet"
```

`--why` is recorded in a `reasons:` map beside the `values:` map it explains, in
the same file and on the same toggle ids — a sibling rather than a richer value,
so `values:` stays the two-column list a person can hand-edit and an older file
with no `reasons:` reads as having none rather than half-having them. Any layer
deck writes to a file can carry one: the task, a scope, the workspace, and a
`repos:` block written by hand.

`deck toggle explain` prints the two sentences apart, because they have two
authors: **why the toggle exists** is the catalog's `rationale`, reviewed by
whoever owns the domain; **why this value was chosen** is the chooser's, and
belongs to this workspace alone. A value with nothing recorded says so and names
the command that would record one, rather than standing under the catalog's
paragraph and reading as justified. A reason belongs to the value it was written
for, so setting a value without `--why` drops the previous one and says it did:
a sentence left behind would go on justifying a decision no longer in the file.

The sentence then travels to the surfaces written for somebody who was not
there. The merge-readiness bundle prints it under each decision — in the
terminal, in the markdown a pull request gets, and in `--json` as `reason`
beside the value — and where nobody recorded one it says so and names the
command that would record it, rather than printing a value alone for a reviewer
to take on trust. `deck toggle list --json` and `deck scope <name>` carry the
same sentence, so neither a consumer nor a reader of one initiative has to call
`explain` once per toggle to find out which values anyone actually decided. The
one place a reason is never invited is a layer that cannot hold one: an
environment variable belongs to a single command, and a profile or a catalog
default was not chosen here at all.

### The gate ladder

```
   gate_level:  static ──► contract ──► build ──► deploy ──► behavior
                                ▲
                                └── a pack inserted this rung by extending
                                    the gate_level toggle, not the engine

   each gate declares:  from_level · per_repo or once · only_repos · when · timeout
                        · measures  (optional: a number to read out of the output)
   each outcome is:     passed · failed · could-not-run · not-applicable
                        └─ the last two always carry the reason
```

Three properties were chosen over features:

1. A gate that did not run is never reported as passed.
2. A command with an unresolved variable does not run at all.
3. Every run leaves evidence on disk, pass or fail.

### A threshold, and a trend

A gate is a threshold, and a threshold has one blind spot: everything inside it
looks identical. Coverage sliding from 86% to 81% under an 80% floor passes on
every run, and the run that finally fails is the one after the decay finished.

```
   the gate            the series
   ─────────           ──────────────────────────────────────────────
   pass / fail   +     86.1 -> 84.0 -> 82.7 -> 81.2  across four runs
   against a           every one of them passed; that is the finding
   number someone      └─ a bundle carries it as a qualifier, never a
   chose                  blocker: a trend nobody set a limit on must
                          not become a limit nobody set
```

A gate declares `measures:` — an id, a regular expression, a unit, and
optionally which direction is better. The engine applies it to the bytes the
command already printed (never a second run, which could disagree with the
first), and appends `{at, task, level, value}` to one file per metric per
repository. A pattern that matches nothing records nothing and says so: a
missing sample is never a zero, because a zero would look like a measurement
somebody took.

Where the series lives is a decision, not a default — `metrics_store` is
`workspace`, `shared` or `off`, and `shared` without a declared directory is
refused rather than quietly written per machine.

### Mounting, and the two guarantees

```
   pack (outside the repo)                    repository (someone else's)
   ───────────────────────                    ───────────────────────────
   config/mount.yaml          ──plugin──►     .claude/settings.local.json
   rules/api-contract.md      ──symlink─►     .claude/rules/deck-api-contract.md
   (generated for this task)  ──copy────►     CLAUDE.local.md

                          manifest ──► .deck/mounts/<task>.json
                          exclusions ─► .git/info/exclude   (never .gitignore)
```

*It only removes what it placed.* Every entry carries a hash. A rule someone
edited, a settings file someone else added a plugin to, a brief that was
extended — each is reported and left alone.

*It does not dirty `git status`.* Exclusions are local. A `SessionEnd` hook
unmounts what the session placed; `deck doctor` reports a mount that outlived
its session.

One sharp edge is documented rather than hidden: a symlinked rule is writable,
and writing *through* it edits the pack's own versioned file. deck records the
source hash at mount time and reports at unmount when that happened.

### Board planning

```
   tasks ──► edit closure per task ──► conflict graph ──► ordered groups

   conflict when:  the edit closures intersect
                   both need the same target        (a bench is exclusive)
                   either is marked exclusive
                   a task names no repository       (it could touch anything)

   NOT a conflict: both merely *reach* a downstream repository
```

That last line is the whole subtlety, and it came from getting it wrong first.
The initial rule conflicted on reach, and on a five-task board it produced five
groups of one: every task reached the end-to-end suite, so every pair collided.
A downstream repository now collides only when both tasks name it directly.

The output is a plan. `/deck:board`, a workflow shipped in the plugin, executes
it: one worktree-isolated agent per task, groups in order, gates once over the
group, and a review a person signs off. The workflow pushes nothing and merges
nothing.

### Cost

```
   transcript (~/.claude/projects/<project>/<session>.jsonl)
        │  usage per message: input · output · cache write · cache read
        │  deduplicated by message id — a streamed message appears twice
        ▼
   tokens  ──── exact ────────────────────────────► reported as fact
        │
        └── × price table ── estimate at list price ──► labelled as an estimate
                                       ▲
   status line ── cost.total_cost_usd ──┘ shown beside it, and flagged
                  (Claude Code's own figure)  when the two disagree by >10%
```

A window comes from what deck already records: a mount opens it, a gate run
closes it. Neither exists to measure cost, which is why the measurement is
trustworthy — the timestamps are a by-product of work that had to be recorded
anyway.

---

A workflow's agents write their transcripts under the project directory of the
session that **launched** them, not of the workspace they worked on. Run a board
for one workspace from a terminal sitting in another, and the cost lands under
the second. deck reads paths; it cannot see intent. Drive a run from inside the
workspace it is for, or pass `--any-project` and read the window yourself.

### Working together

There is no synchronisation protocol in deck, and there should not be. A team's
work already lives in a tracker that is audited, permissioned, and outlives any
laptop — so the tracker *is* the shared state, and deck reads it.

What deck adds on top is the one thing coordination needs and a tracker does not
enforce: **a claim**. `deck board claim` assigns a task and refuses one that
someone else already holds, because two agents editing the same chain produce a
merge nobody can review. `--force` exists and says, in its help text, to talk to
the person first.

A claim is worth only as much as the tracker's own account of it. GitHub answers
`201` to an assignment for a login it is about to discard, so the status line
says the request was well-formed and only the body says nobody was assigned —
which is how `deck board claim` came to report an assignment that never
happened. The write is now read back: github, gitlab and gerrit each report the
assignee or hashtag the response says was *recorded*, a name the tracker dropped
is an error naming it, and a response that accounts for nothing is reported as
that rather than assumed to be success. Jira is the exception that shows the
shape — its assignee endpoint replaces a single value and refuses an accountId
it will not take, so a rejected name is already an error and there is nothing it
could drop quietly. `board new` follows the same rule: the url or key the
tracker gives the new task, never a stand-in word for one it did not name.

Which name a claim carries is two questions, not one, and answering them the
same way put a shell login onto this repository's own board across seven
`assignee:` lines. A tracker claim names an account that authenticates to that
tracker, so `$USER` is nearly right there: the account acting is the one holding
the token, and a name the tracker will not take is already an error, because the
write is read back. A file board has no such reader. It is committed and pushed,
and the only thing that ever sees the name is a person, later, in a public diff.

So a claim written to a file is recorded under the identity that repository
publishes under — git's `user.name`, read from the directory the board file
lives in, which is the configuration that will sign the commit carrying it. When
a workspace holds repositories whose identities disagree, deck does not rank
them and does not pick the likely one; it asks git where the file is. `$DECK_USER`
overrides that, for the person whose git identity is not the name they take work
under, and `deck board claim <id> <name>` overrides both. With nothing to read
the claim is refused rather than filled in from the login, and `deck board
whoami` prints, for every source, the name it would write and where that name
came from. Consultations record `asked_by` and `answered_by` the same way: one
outlives its session by design, is read by the next run, and is quoted into the
bundle a reviewer reads, so the name in it travels as far as an `assignee:` does.

Writing to a tracker is outward-facing — it appears under someone's name and
other people see it — so it is governed by `tracker_writes`, which defaults to
asking. A machine meant only to read sets it to `off` and cannot write at all.

```
   read                                     write
   ────                                     ─────
   jira · gitlab · github · gerrit · file   claim  (assignee, or a hashtag)
        │                                   create (an issue, or a line in a file)
        ▼                                        │
   one task shape ──► impact closure ──► groups  │ gated by `tracker_writes`
                                                 ▼
                                            refused unless --yes
```

A tracker read follows the service's pages rather than taking the first one. It
has a ceiling, because a query nobody meant should not hold the CLI open for
hundreds of requests, and a read that reached the ceiling is reported as partial
beside the tasks it did get — Jira removed `total` from its search response, so
nothing downstream could work out for itself that a board came back short.

---

## 6. Data on disk

| Path | Belongs to | Versioned? |
|---|---|---|
| `.deck/workspace.yaml` | the machine | No — paths and targets differ per person |
| `.deck/toggles.yaml` | the machine | No — a template is versioned in the pack |
| `.deck/state/toggles-<session>.yaml` | one task | No |
| `.deck/mounts/<task>.json` | one task | No |
| `.deck/gates/<task>.json` + `logs/` | one task | No — evidence, kept until cleaned |
| `.deck/bundles/<task>.md` | one task | No — derived from the rest; re-run rather than edited |
| `.deck/metrics/<gate>.<metric>[@repo].jsonl` | the workspace | No by default — `metrics_store: shared` moves it somewhere a team shares. Append-only: a history that can be rewritten is not evidence |
| `.deck/pricing.yaml` | the machine | Optional override of the price table |
| pack `config/*.yaml` | the team | **Yes** — this is the shared knowledge |

Nothing deck writes belongs in a product repository, and nothing it places there
survives an unmount.

---

## 7. Monorepo

deck talks about "repositories", and in a monorepo that word is wrong in a way
worth being precise about.

**The engine does not care whether a unit of change is a checkout or a
directory.** `repos:` is a registry of units; `path:` is where each one lives.
Nothing in the impact graph, the gate ladder, the pack scoping or the board
depends on a unit having a `.git` of its own.

```yaml
# One repository, four units. Everything else behaves identically.
repos:
  schema: { path: packages/schema, impacts: [api, web] }
  api:    { path: packages/api,    impacts: [cli] }
  web:    { path: packages/web,    impacts: [] }
  cli:    { path: apps/cli,        impacts: [] }
```

`deck setup` finds them: a directory holding a package manifest —
`pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `pom.xml` and the rest
— declares itself a unit. That is evidence, not a guess, which is the standard
the rest of deck is held to. A repository with no such directories is a single
unit, and that is fine too.

```
$ deck setup --dry-run
1  What is in this workspace?
   one repository, holding 4 packages — those are the units of change:
     apps/cli
     packages/api
     packages/schema
     packages/web
```

### What genuinely differs

Only one thing, and it is about git rather than about deck:

| | Multi-repo | Monorepo |
|---|---|---|
| `.git` per unit | yes | **no — one for all of them** |
| `.git/info/exclude` | one file per unit | **one file, shared** |
| the workspace root | not a checkout | **the product's own repository** |

Both consequences are load-bearing. Exclusion patterns must be anchored to the
working-tree root (`/packages/schema/.claude/…`), or a unit hides another unit's
artifacts and not its own; and each block must be marked by task *and* path, or
every unit's write replaces the last and only the final one stays hidden.

`.deck/` matters for the same reason. In a multi-repository workspace the root
is not a checkout, so nothing sees it. In a monorepo it sits inside the product's
repository, holding paths, evidence and choices that must never be versioned —
so `deck setup` excludes it, and `deck doctor` reports it as a problem if it was
ever committed.

Get those wrong and an agent running `git add -A` commits deck's own artifacts
into the product. For an autonomous or semi-autonomous workflow that is not a
cosmetic failure.

### What is still worse in a monorepo

`deck board plan` groups by what tasks would edit. Two tasks in different
packages of one repository genuinely do not collide — but if a team's workflow
serialises on the repository (one branch, one CI pipeline), the plan is more
optimistic than the process allows. deck models the code, not your branching
policy.

And the vocabulary stays "repository" throughout the CLI. It reads oddly against
a package, and renaming it would break every descriptor in existence for a
cosmetic gain.

---

## 8. Where the model is, and where it is not

The commonest question about deck is whether it drives an agent. It does not,
and the line is worth drawing precisely, because "an AI tool" is exactly the
description that makes people unsure what they have installed.

### Two kinds of work, and only one of them is a model's

```
    what a parser can derive                what only judgement produces
    ────────────────────────                ────────────────────────────
    which repositories exist                which repositories a change
    what a manifest checks out                forces you to touch
    what a gate command is                  how to word a decision so a
    which pack claims a name                  colleague can answer it
    what a session cost                     what the code should be

    deck computes these.                    A person decides these,
    Deterministic, auditable,               or — for the first two only —
    the same answer twice.                  asks a model for a DRAFT.
                                            The third is never deck's.
```

deck calls a model in exactly one place in the source, `assist.py`, reached by
exactly three commands:

| Command | Drafts | Why a parser cannot |
|---|---|---|
| `deck propose impacts` | the `impacts` edges and the `couples:` pairs | A manifest declares a *checkout*, never a *propagation*. The dependency is in imports, generated code and published schemas. |
| `deck propose toggle` | a catalog entry | Wording a decision so someone can answer it in ten seconds is writing, not parsing. |
| `deck propose pack` | a pack's gates, rules and toggles for one repository — read with the repositories the graph connects to it, so a question is not filed about an answer three directories away — plus the questions it could not answer | Which commands a project already runs is findable; which of its conventions no command checks, and what breaks when one is crossed, is judgement about a codebase. |

**There is no fourth.** deck never asks a model to write your code, run your
build, edit your descriptor, or decide anything.

### The four constraints on that one call

```
   deck propose impacts --repos a b
              │
              ▼
   ┌──────────────────────────────────────────────────┐
   │ 1. ai_assist  off → refuse                       │  a toggle, not a flag:
   │               ask → refuse unless --yes          │  policy, recorded, and
   │               allow → go                         │  never asked mid-task
   ├──────────────────────────────────────────────────┤
   │ 2. --tools Read Grep Glob                        │  the RUNTIME enforces
   │    no Write, no Edit, no Bash                    │  it. A prompt is a
   │                                                  │  suggestion; this is not
   ├──────────────────────────────────────────────────┤
   │ 3. --max-budget-usd 1.50                         │  a runaway loop cannot
   │                                                  │  bill you
   ├──────────────────────────────────────────────────┤
   │ 4. writes .deck/proposals/impacts-<stamp>.json   │  never the descriptor
   └──────────────────────────────────────────────────┘
              │
              ▼
        a human reads it
              │
              ▼
   deck propose apply <file> --confidence high
```

The fourth constraint is the one that matters. A tool that quietly rewrites the
file describing how your system propagates change is a tool nobody should
install. Applying is a separate command, taking a confidence floor, run by a
person who read the proposal — including the `unsure` list, where the model
records what it could not verify.

### A draft may not turn a question into a decision

`deck propose pack` sorts what it finds into gates, rules and toggles. There is
a fourth outcome, and leaving it out cost something: a drafter found two code
paths returning different status codes for the same class of refusal, wrote in
its own notes that it could not tell whether that was intentional or drift, and
filed it as a **toggle**. A toggle is a decision between values that each defend
themselves. An inconsistency nobody has explained is a **question**. Filed as a
toggle it reads as "we chose", and the doubt is gone at the moment it was worth
keeping.

So a pack draft has a `questions` list beside `toggles`, and `deck propose
apply` records each entry as a consultation under `.deck/consultations/` — the
same place `deck ask` writes, answered the same way, surviving the same way. A
draft's toggle carries a `defends` block, one line per value saying why a team
would pick that one, and `apply` refuses the whole draft when a toggle does not
defend every value it names, or when the same finding appears both as a toggle
and as something the draft could not explain. Refusing the whole draft rather
than dropping the bad toggle is deliberate: `apply` does not write toggles into
a pack, so a silent drop would land the gates and the rules and leave the person
to file the toggle by hand from the printed draft. Refusing is the only moment
deck can stop that.

A draft made before `defends` existed still applies; only its toggles do not,
and the refusal says which value is missing its line.

### Who implements, then

```
   ┌─────────────┐   what does this reach?     ┌──────────┐
   │             │ ──────────────────────────► │          │
   │   Claude    │   what must I ask first?    │   deck   │
   │    Code     │ ──────────────────────────► │          │
   │             │   how far did this verify?  │          │
   │  (writes    │ ◄────────────────────────── │ (answers, │
   │   the code) │                             │  records) │
   └─────────────┘                             └──────────┘
         │                                           │
         │ spawns agents, worktrees,                 │ reads files,
         │ asks the question box,                    │ runs declared
         │ edits files                               │ commands
         ▼                                           ▼
    the runtime's job                          the workspace's job
```

The agent in your session writes the code. deck answers before (what this
reaches, what to decide, what context to place) and records after (what ran,
what it cost). Neither does the other's job.

The apparent exception is the `/deck:board` workflow, and it is worth being
exact: **Claude Code** opens the agents there, with its own workflow runtime,
its own worktrees, its own parallelism. deck supplies the plan — which tasks may
run at the same time — and nothing else. deck spawns no agent, anywhere.

> Status, plainly: that workflow has run end to end twice, on a five-task
> sandbox board — eleven agents, four groups, every task committed and green.
> It has never been pointed at a workspace anyone depends on, and the walkthrough
> says so under that heading rather than this one.

### Setting the policy

`ai_assist` is a toggle like any other, deliberately — a dedicated command for
it would be the special case that undermines the mechanism the other 26 rely on.

```bash
deck toggle set --at workspace ai_assist allow   # persists, every terminal
deck toggle set ai_assist off                       # this session only
deck toggle explain ai_assist                       # the value, and where it came from
```

It carries `askable: false`: it is policy, and policy is not something an agent
puts to you in the middle of a task.

---

## 9. Safety posture

An agent with shell access will reach whatever host a command names. Three rules
are enforced as code, not as instructions in a prompt:

| Rule | Enforced where |
|---|---|
| A gate may only name a host from the `targets` allowlist | Refused before a command is built |
| Nothing is deleted that deck did not place | Hash check at unmount |
| A dynamic artifact is task-scoped, never carries a security rule, and reaches a shared pack only through human review | Design constraint on dynamic packs |

Instructions shape behaviour; hooks and refusals decide it. deck puts the things
that matter in the second category.

---

## 10. Testing

`ci/smoke.sh` builds a synthetic workspace and an example pack in `mktemp -d`
and exercises the observable behaviour: 747 checks covering resolution,
importers, precedence, pack composition, vendoring and re-checking what was
vendored, the coupling edge that carries no order, scopes and what they refuse
to hide,
mounting and its refusals, the ladder and its honesty about what did not run,
measurements and the trends they accumulate into, the reason recorded beside a
chosen value and how a value without one is reported, board grouping, the
merge-readiness bundle and how it attributes a change set, cost arithmetic, the
status line, and the tmux split. It touches nothing you own and runs anywhere.

`deck-acme` is the standing agnosticism test. If a change to the engine cannot
keep it working unedited, the change is in the wrong layer.

---

## 11. Status

| Piece | State |
|---|---|
| Workspace resolution, impact graph, importers | built and tested |
| Toggles, profiles, pack composition | built and tested |
| Mounting and unmounting | built and tested |
| Gate ladder and evidence | built and tested |
| Board planning | built and tested |
| Merge-readiness bundle | built and tested |
| Measurements over time | built and tested |
| Cost reporting | built and tested |
| `/deck:board` workflow | written; not yet run end to end against a real board |
| Dynamic packs | designed, not built |
