# Foundations — what enters deck, and who owns it

Software engineering has a long list of things a team wants held: architecture,
paradigms, patterns, style, formatting, guidelines, security, quality, metrics,
tests, build, deploy, release. A tool that claims to guarantee all of it either
owns your whole stack or is lying.

deck does neither. This document says exactly which mechanism carries each of
those, who supplies the content, and what is honestly not covered yet.

---

## 0. Words this document uses

Two vocabularies meet here, and neither is universal. deck's own terms come
first, because they mean something specific and are used everywhere else in the
documentation:

| Term | What it means in deck |
|---|---|
| **workspace** | the tree deck manages, holding one or more repositories. Named by its descriptor — `_workspaces/<name>/<scope>/workspace.yaml` in a collection, or `.deck/workspace.yaml` when there is none |
| **descriptor** | that file: the registry of repositories, the edges between them, the targets, the boards |
| **registry** | the `repos:` block — every unit of change deck knows about |
| **unit of change** | a repository, or a package inside a monorepo. deck does not care which |
| **scope** | a named subset of the registry: one initiative, with its own board and posture |
| **pack** | a directory of team knowledge — decisions, commands, rules, skills. Also a Claude Code plugin |
| **toggle** | a decision with more than one defensible answer, written down once with its reasoning |
| **gate** | a command that passes or fails, at a rung of the ladder |
| **ladder** | the rungs verification climbs: `static → build → deploy → behavior` |
| **rung** | one level of that ladder |
| **mount** | placing a pack's rules into the repositories a task touches, for the duration of that task |
| **posture** | the set of toggle values in force — for a workspace, a scope, a repository or a task |
| **impact / reach** | which repositories a change forces you to revisit. Not which ones you will edit |
| **bundle** | the merge-readiness page: what changed, what was verified, what was not |
| **consultation** | a question the decision catalog has no entry for, recorded by `deck ask` |

Terms from the wider field, expanded where this documentation uses them:

| Short | In full, and why it appears here |
|---|---|
| **SASE** | Structured Agentic Software Engineering — the framework in Hassan et al., *Agentic Software Engineering: Foundational Pillars and a Research Roadmap* ([arXiv:2509.06216](https://arxiv.org/abs/2509.06216)). Its vocabulary is used because it names these artifacts precisely and deck did not invent better words |
| **BriefingScript** | SASE's term for a structured work order — scope, context, advice — replacing a vague ticket. In deck this is a board item's `as_a`, `so_that` and `acceptance` |
| **LoopScript** | SASE's term for a declarative orchestration playbook: decomposition, parallelism, review checkpoints. In deck, `deck board plan` and the `/deck:board` workflow |
| **MentorScript** | SASE's term for versioned team norms guiding agent behaviour. In deck, a pack's `rules/` and `skills/` |
| **CRP** | Consultation Request Pack — SASE's term for an agent escalating a question it cannot answer. In deck, `deck ask` |
| **MRP** | Merge-Readiness Pack — SASE's term for an evidence bundle a reviewer reads instead of the diff. In deck, `deck bundle` |
| **VCR** | Version-Controlled Resolution — SASE's term for a human answer recorded so it outlives the conversation. In deck, `deck ask resolve` records it and `deck ask fold` writes it into a pack |
| **ATLE** | AI Teammate Lifecycle Engineering — SASE's term for memory that survives across tasks and projects. Not implemented (§4) |
| **ADR** | Architecture Decision Record — a short document recording one architectural decision and its reasoning. A deck rule may point at one; deck does not manage them |
| **SAST** | Static Application Security Testing — analysing source for security defects without running it. A gate, in deck's terms |
| **SCA** | Software Composition Analysis — checking declared dependencies against known vulnerabilities. Also a gate |
| **CVE** | Common Vulnerabilities and Exposures — the public identifier scheme for a known vulnerability |
| **RAG / CAG** | Retrieval- and Cache-Augmented Generation — supplying an agent with retrieved or pre-loaded knowledge. deck's position is to declare which source applies where and delegate retrieval (§4) |
| **MCP** | Model Context Protocol — the standard by which a tool exposes data to an agent. Where deck recommends integrating rather than building |
| **CI** | continuous integration — whatever runs your gates without a person present |
| **CLI** | command-line interface. deck is one before it is anything else |

---

## 1. Four kinds of thing, and the rule for sorting them

Everything on that list is one of four kinds. Getting the kind right is most of
the work, because each kind has a different cost and a different failure mode.

| Kind | What it is | Where it lives | How it acts |
|---|---|---|---|
| **Fact** | something true about this workspace | the descriptor | answers a question |
| **Invariant** | a constraint that is always on | `rules/`, `skills/` in a pack | reaches the agent as context |
| **Decision** | a call with more than one defensible answer | `toggles/` in a pack | is asked, once, and recorded |
| **Proof** | a command that passes or fails | `gates/` in a pack | produces evidence |

### The rule: the cheapest correct home wins

An invariant costs context **every time** the agent reads a matching file. A
gate costs nothing until it runs, and then it either passes or names the file
and line. So:

> **If a machine can check it, it is a gate — never a rule.**

Telling an agent about indentation, import order or trailing commas is paying
tokens forever for something `ruff format` settles in 40 milliseconds. Style
guides belong in the formatter's config and the formatter belongs in the ladder.

Rules are for what no command can decide: which direction a dependency may
point, why this boundary exists, what breaks if you cross it.

The same rule sorts decisions: if there is one right answer, it is not a
decision — write it as a rule or enforce it as a gate. A toggle whose value
nobody would ever change is a question you will make people answer forever.

### When none of the four fits, it is a question

A decision has more than one answer and you can say what defends each of them.
When you cannot — two code paths disagree and nobody knows whether that was
decided or whether it drifted — none of the four kinds fits, and forcing it into
one destroys the only thing worth keeping. Filed as a toggle it reads as "we
chose". Filed as a rule it reads as "we require". Both are lies about a thing
nobody has explained.

That is what a **consultation** is for: `deck ask` records it, a person answers
it, and the answer outlives the session that raised it. `deck propose pack`
emits one for every finding its draft cannot account for, and `deck propose
apply` refuses a drafted toggle that does not say what defends each of its
values — because that sentence is exactly what a question cannot produce.

---

## 2. The full map

Every item, where it goes, who writes it, and what it is today.

### Architecture and design

| | Mechanism | Content owner | Enforceable? | Today |
|---|---|---|---|---|
| Module boundaries, dependency direction | `impacts` + a `rule` + an import-linter **gate** | org / project pack | **yes**, largely | mechanism ready |
| Layering (what may import what) | `rule` scoped by `paths:` | org pack | partly | mechanism ready |
| Paradigms (event-driven, immutability) | `rule` | org pack | rarely | mechanism ready |
| Design patterns as used *here* | `skill` — a procedure with steps | org pack | no | mechanism ready |
| Architecture decisions already taken | `rule` + an ADR the rule points at | org | no | mechanism ready |

An architecture rule earns its place by naming the **consequence**: "handlers
validate at the edge; nothing below re-checks shapes" is worth context.
"This directory contains handlers" is not — the agent can see that.

### Style, formatting, conventions

| | Mechanism | Content owner | Enforceable? | Today |
|---|---|---|---|---|
| Formatting | **gate** at `static` (`ruff format --check`, `prettier`, `clang-format`) | org pack | **yes, fully** | works |
| Lint / static analysis | **gate** at `static` | org pack | **yes** | works |
| Naming conventions | linter where possible, else `rule` | org pack | partly | mechanism ready |
| Commit message shape | `commit_granularity`, `changelog` toggles + a gate | core + org | yes | toggles exist |

**None of this belongs in a rule if a formatter can do it.** This is the single
most common way a team wastes an agent's context.

### Security

| | Mechanism | Content owner | Enforceable? | Today |
|---|---|---|---|---|
| Secret scanning | **gate**, `secret_scan` toggle | core + org command | **yes** | toggle in core |
| Dependency CVEs / SCA | **gate** at `static` or `build` | org pack | **yes** | mechanism ready |
| SAST / hardening checks | **gate** | org pack | **yes** | mechanism ready |
| "Never log a credential" | `rule` | org pack | partly | mechanism ready |
| Exposure decisions | `toggle`, `security_review` | core + org | n/a | in core |
| Which hosts may be reached | `targets` allowlist — **refused, not advised** | project | **yes, by refusal** | works |

A `security` group toggle may not default to `ask`: policy is decided in
advance, not negotiated mid-task by an agent in a hurry. `deck toggle validate
--strict` refuses a catalog that tries.

### Quality, metrics, tests

| | Mechanism | Content owner | Enforceable? | Today |
|---|---|---|---|---|
| Unit tests | **gate** at `build`; `unit_tests`, `test_depth`, `test_scaffold` | core + org command | **yes** | works |
| Integration / system tests | **gate** at `behavior`, needs a `target` | org pack | **yes** | works |
| Coverage floor | **gate**; `coverage_min` toggle | core + org command | **yes** | toggle in core |
| Complexity, duplication, dead code | **gate** at `static` | org pack | **yes** | mechanism ready |
| Metrics over time, trends | **gate** with `measures:`; `metrics_store` toggle | org pack writes the pattern | reported, never enforced | works |
| Budgets on a metric | — | — | — | **not covered** (§4) |

### Build, deploy, release

| | Mechanism | Content owner | Enforceable? | Today |
|---|---|---|---|---|
| Build | **gate** at `build`; `build_target` per repo; `build_scope` toggle | org pack | **yes** | works |
| Container / toolchain | the gate command itself — a pack writes `docker run … make` where it would have written `make` | project | yes | works, with no key of its own |
| Deploy | **gate** at `deploy`; `deploy_mode` toggle; `targets` allowlist | org pack | **yes** | works |
| Update / restart posture | `restart_policy` toggle | core | n/a | in core |
| Push / branch policy | `push_policy` toggle | core | partly | in core |
| Versioning, packaging, distribution | — | — | — | **thin** (§4) |

### Engineering *with* agents

This is the half that has no settled vocabulary yet. The terms below are from
Hassan et al., *Agentic Software Engineering: Foundational Pillars and a
Research Roadmap* (arXiv:2509.06216), which names the artifacts precisely.

| SASE artifact | What it is | deck today |
|---|---|---|
| **MentorScript** | team norms and quality principles, versioned, guiding agent behaviour | `rules/` + `skills/` in a pack — **works** |
| **LoopScript** | declarative orchestration: decomposition, parallelisation, review checkpoints | `deck board plan` + the `/deck:board` workflow — **written, never run end to end** |
| **BriefingScript** | a structured work order: scope, context, strategic advice | **missing** — a task is a title and a repo list |
| **CRP** (Consultation Request Pack) | the agent escalates a question it cannot answer | `deck ask new` — recorded, outlives the session, and nothing waits on it |
| **MRP** (Merge-Readiness Pack) | evidence bundle: completeness, verification, hygiene, rationale, auditability | `deck bundle` — **works.** All five, each derived from a file it names, with a verdict that separates what blocks a merge from what a reviewer should merely read first. It does not read the code: what the change *is* stays the diff's job |
| **VCR** (Version-Controlled Resolution) | the human answer goes back into the knowledge base, versioned | **yes.** `deck ask resolve` records the answer and says which artifact it looks like; `deck ask fold` writes it into a pack as a rule, toggle or gate, carrying the question and the answer. Which of the three, and whether it recurs at all, stays a person's judgement — deck never folds one in on its own |
| **ATLE** | memory that survives across tasks and projects | **missing** |

On **loops versus graphs**: deck is already a graph. `impacts` is declared
ownership and dependency, and `couples` is the mutual relationship that has no
direction to declare; `board plan` is explicit orchestration; a toggle set to
`ask` and `plan_approval` are what Bosio calls the ground wire — a human with
preserved judgement and a designed place in the structure. What deck does not
yet address is *measurement decay*: a long autonomous run can pass every gate
that exists and still drift, because no loop watches the watcher. Gates prove
what they assert and nothing more, which is a property, not a bug — but it means
the ladder has to be extended as the work teaches you what it missed.

---

## 2b. deck does not write code, and does not duplicate the CLI

Two questions worth answering flatly, because both are easy to assume wrong.

### deck writes no product code

There is exactly one place in the source that calls a model, and it is
read-only. Three commands reach it — `deck propose impacts`, `deck propose
toggle` and `deck propose pack` — and all three draft something for a person to
review: an edge list, a catalog entry, or a pack's gates and rules. Everything else deck writes is
deterministic and is never your code:

| deck writes | what it is |
|---|---|
| the descriptor, and `~/.deck/workspaces/<name>/toggles.yaml` | configuration you then edit |
| a pack skeleton | static template files, copied |
| a mounted rule | a copy of the pack's file, recorded with its hash |
| `.claude/settings.local.json` | three lines enabling a plugin |
| `.deck/gates/`, `.deck/metrics/`, `.deck/proposals/` | evidence, the series it accumulated, and drafts |

The agent in your session writes the code. deck answers before and records
after.

### What Claude Code's own commands already do

| Claude Code | deck | Overlap |
|---|---|---|
| `/code-review`, `/security-review` | — | **None.** deck does not review code. A workflow agent cannot invoke a slash command, so the board's last phase reviews the *delivery* and ends by naming the reviews a human still has to run |
| `/todos` | `deck board` | **None.** `/todos` is one session's checklist. A board is the team's, persistent, with repositories, conflicts and evidence |
| `/cost`, `/usage` | `deck cost` | **Partial, deliberately.** `/cost` is this session — use it for that. `deck cost --task X` is one task's window, which may span sessions, per model, scoped to this workspace. Where Claude Code's own figure is available deck treats it as authoritative and shows its estimate beside it |
| `/agents`, `/workflows`, `/tasks` | — | **None.** deck spawns nothing and orchestrates nothing |
| `/memory`, `/memories` | packs | Adjacent. Memory keeps what an agent learned, locally. A pack keeps what the team agreed, under review |
| `/init` | `deck init` | Name only. `/init` writes a `CLAUDE.md`; `deck init` writes the workspace descriptor |
| `/loop` | — | **None** |

The rule behind the table: **if Claude Code ships it, deck's job is to reach it,
not to rebuild it.** Where deck has something with a similar name, it is because
the scope genuinely differs — a task rather than a session, a team rather than a
person — and the overlap is stated rather than hidden.

---

## 3. Who owns what

Four layers, each merging into the next through `requires:`. Order is merge
order, so the more specific has the last word.

```
   deck                    the engine, and a universal catalog of decisions
     │                     ships with the tool · has no domain knowledge
     ▼
   foundations pack        DRY, SRP, cohesion, fail-fast, testability, POLA…
     │                     published, language-agnostic · opt-in
     ▼
   organisation pack       your architecture, build system, security posture,
     │                     commands, hosts, conventions
     ▼
   project / repo pack     what this product or this repository adds
```

| Layer | Supplies | Never supplies |
|---|---|---|
| **deck** | the four mechanisms; the ladder; the graph; the universal catalog (`gate_level`, `deploy_mode`, `test_depth`, `ai_assist`…) | any command, any edge, any domain rule |
| **foundations** | principles that hold in every language | how to check them |
| **organisation** | the commands, the edges, the domain decisions, the rules with consequences | anything one product owns alone |
| **project** | its repositories, its board, its posture | anything the org already decided |

### What deck will never own

- **A command.** deck runs the strings your pack declares. It has never heard of
  `bitbake`, `npm` or `helm`, and adding them would make it wrong for everyone
  else.
- **An edge.** A manifest declares a checkout, never a propagation. Only your
  team knows what a change forces.
- **A domain rule.** The moment deck ships an opinion about your architecture it
  becomes a framework, and frameworks are abandoned when the opinion stops
  fitting.
- **Your product's runtime configuration.** A toggle records a decision; it is
  not read by your application at run time. If it were, your product would need
  a control plane to start.

The engine/pack line is not stylistic. A domain word appearing in engine code is
a bug, and the development pack says so.

---

## 4. Honestly not covered

Named so nobody discovers them the hard way.

**This is the list.** `docs/pt-br.html` carries a translation of it and nothing
else does — the two disagreed for a day, over `VCR` (shipped as `deck ask fold`
and still named here as missing), over `Attribution without a link` (dropped
from one and not the other), and over three gaps only the translation had.
Anything added below has to reach the translation with it, and nothing else may
restate it: two copies of a list is how that happened.

| Gap | What it means in practice |
|---|---|
| **The autonomous run, at stakes** | `/deck:board` has been run end to end, twice, on a five-task sandbox board — eleven agents, everything committed and green. It has never been pointed at a workspace anyone depends on. |
| **Attribution without a link** | `deck bundle` attributes a commit to a task exactly when the message cites it — which is what `requirement_link: required` already asks for. With that toggle `off`, the change set is the mount window instead: every commit made in a reached repository while the task was mounted, whoever made it. The bundle says which basis it used, so the reviewer is never misled, but the exact one has to be bought with a commit-message convention. |
| **A budget on a trend** | A gate that measures records the series and reports which way it is going; a bundle carries a slide as a qualifier. Nothing lets a team say "no more than 2% in a quarter" and have it enforced, and nothing spots a step change that stays inside its limits. Deliberate so far: a trend that fails a delivery is a threshold again, and one nobody chose. |
| **Release and distribution** | Versioning, packaging and artifact publication are barely modelled — `push_policy` and `changelog` are the whole of it. |
| **Memory across tasks** | Everything is task-scoped by design. The one thing that now crosses tasks is the metric series, and it is deliberately only numbers — no lesson, no context, nothing an agent could mistake for advice. The same lesson is still learned again. |
| **Trackers beyond GitHub** | GitHub is exercised against the real service. Jira, GitLab and Gerrit are exercised only against the local stand-in — written from what those APIs document rather than from what deck sends — and no request from this suite has ever left the machine. The gap is not theoretical: the Jira reader called an endpoint Atlassian had removed while the suite stayed green, because the stand-in answered it *because deck asked for it*. GitLab has since had every request shape deck sends run against the stand-in — the create had never run against anything at all — and `WALKTHROUGH.md` names the four things about it that only a live instance can answer. |
| **The full BriefingScript** | A task is a title and a list of repositories. `as_a` and `so_that` exist in the board template, but the structured work order is not settled. |
| **Measurement decay** | A long autonomous run can pass every gate that exists and still drift, because no loop watches the watcher. Gates prove what they assert and nothing more — a property rather than a bug, but it means the ladder has to be extended as the work teaches what it let through. `deck pack review` reports a gate that has run and never caught anything, which is the observable half. |
| **Architecture, and who enforces it** | deck records how a change propagates — `impacts:`, `couples:`, `role`, `downstream` — and does not compute it. It cannot: the engine has never heard of an import, a Bazel target or a recipe, and giving it one would be the domain knowledge the engine/pack split exists to keep out. What is *not* missing is enforcement, and this used to read as a gap only because nothing showed it: a gate command resolves `${repo.impacts}` and `${repo.couples}`, so a pack can run whatever computes real dependencies in its domain (`import-linter`, `go list`, `madge`, `bitbake -g`, a grep over includes) and fail when the declared edge and the observed one disagree — no engine change at all. The scaffolded `config/gates.yaml` (`deck pack new`) carries a commented example of exactly this, and `ci/smoke.sh` runs one end to end: it passes while a declared edge is still backed by something real, and fails the moment that stops being true. |

---

## 4b. Where a decision made in a session goes

A worked example, because it is the failure this whole taxonomy exists to
prevent.

Agents were about to edit deck's own source. The tool they would break is the
tool that runs the gates that would have caught the break, so the call was: work
on a copy. That call was made in a session, acted on, and written down nowhere —
which means the next person makes it again, or does not, and finds out the hard
way.

Sorting it by kind gives it two homes, not one:

| Kind | Where it went |
|---|---|
| **proof** — a machine can detect it | `deck doctor` warns when the running `deck` resolves inside the workspace it is managing |
| **invariant** — the consequence is worth stating | `rules/self-hosting.md` in the development pack: why, and the clone commands |

Neither replaces the other. The check fires without anyone remembering; the rule
explains what the check is talking about and what to do.

The same sorting applies to anything decided mid-task. If a machine can check
it, it is a gate or a `doctor` line. If it constrains an area of the code, it is
a rule. If it has more than one defensible answer, it is a toggle. If it is none
of those and might recur, `deck ask resolve` will say which it looks like and
`deck ask fold` will write it into a pack. Which kind it becomes stays a
person's call: whether an answer recurs is not knowable from one instance, and
that judgement is the difference between knowledge and a transcript.

---

## 5. Putting it to work

For a team adopting deck, the order that wastes the least effort:

1. **Sort your existing material by kind.** Most style guides are three
   documents in one: a formatter config that nobody extracted, a handful of real
   invariants, and a list of decisions that were never written down as such.
2. **Move everything mechanical into gates first.** It is the cheapest win and
   it stops you paying context for it.
3. **Write the edges.** Without them the graph answers nothing, and the graph is
   what an agent cannot work out alone.
4. **Write invariants as rules, with their consequence.** Scope them with
   `paths:` so they load when they matter.
5. **Write decisions as toggles, with `rationale` and `impact` per value.** The
   reason has to survive the person who wrote it.
6. **Extend the ladder every time something gets through it.** A defect a gate
   did not catch is a gate you do not have yet.

Step 6 is the one that matters over a year. A ladder that never grows is a
ladder that measures less each month.
