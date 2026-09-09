# Packs — the artifact structure

A pack is where a team's operating knowledge lives: what identifies this kind of
workspace, the decisions it keeps re-making, the ladder that verifies its work,
and the rules and skills an agent should have while working in it.

A pack is **also a Claude Code plugin**. The same directory serves both readers,
so nothing is written twice and nothing drifts apart:

```
my-pack/
├── .claude-plugin/
│   └── plugin.json          Claude Code reads this. Name, version, description.
│
├── skills/                  ── Claude Code loads these directly ──
│   └── <name>/SKILL.md         procedures, loaded on demand by description
├── agents/                     subagent definitions (optional)
├── hooks/hooks.json            event handlers (optional)
├── commands/                   flat command files (optional; prefer skills/)
│
├── config/                  ── only deck reads these ──
│   ├── detect.yaml             what identifies this workspace; tool prerequisites;
│   │                           `scope:`, if it belongs to one initiative
│   ├── toggles.yaml            the decisions this domain keeps re-making
│   ├── gates.yaml              the verification ladder and its commands
│   ├── mount.yaml              the plugin entry — everything else is a directory
│   └── profiles.yaml           named postures
│
├── rules/                   ── deck places these; Claude Code loads them ──
│   └── <name>.md               `paths:`-scoped rules, copied in on mount
│
├── templates/workspace/
│   ├── workspace.yaml          the descriptor shape THIS kind of workspace has.
│   │                           `deck setup` uses it instead of the generic one
│   └── toggles.yaml            optional: the choices file a team starts from
│
└── README.md
```

The split is worth stating plainly: **`skills/`, `agents/`, `hooks/` and
`commands/` are Claude Code's own structure, unchanged.** deck adds `config/`
and `rules/` beside them. A pack works as a plain Claude Code plugin even if
deck is never installed; deck reads the extra directories when it is.

## Create one

```bash
deck pack new my-pack                    # scaffolds the whole skeleton
deck pack new my-pack --from-workspace   # seeds markers and the descriptor template
deck pack new my-pack --scope payments   # binds it to one initiative (see below)
deck pack validate my-pack
export DECK_PACKS=$PWD/my-pack           # or list it under `packs:` in the descriptor
```

Every generated file arrives with its comments intact, because an empty file
teaches nobody anything and a pack nobody can read is a pack nobody maintains.

## The five config files

### `detect.yaml` — what this workspace *is*

```yaml
markers:                    # checked before any descriptor is read
  - manifest-sx/default.xml #   root resolution has to happen first
prerequisites:              # `deck doctor` checks these are on PATH
  - git
  - docker
  - { name: ruff, required: false }
scope: payments             # optional: the initiative this pack belongs to
```

`scope:` is the fourth route a pack takes to an agent, beside being named, being
shared, and being named after a repository — and it is the only one that says
*when*. See [A pack that belongs to an
initiative](#a-pack-that-belongs-to-an-initiative).

### `toggles.yaml` — the decisions

Two mechanisms. A **new entry** is declared in the catalog format. **Extending**
one the core defines requires repeating the `id` with `overrides: true`; a
collision without that flag is refused, so nothing shadows a core decision by
accident.

```yaml
toggles:
  - id: api_compat
    group: quality
    title: API compatibility
    summary: How far this change may alter the published contract.
    type: enum
    values: [strict, additive, breaking]
    default: strict            # or `ask`, to put the question to a person
    stage: [plan]              # plan · implement · verify · deliver
    applies_to: ["**/openapi.yaml"]
    risk: high
    rationale: >
      Why this exists at all. A reader six months from now needs this more
      than they need a restatement of the values.
    impact:
      strict: What choosing this costs you.
      breaking: What choosing this costs you.
    question:
      header: API compat        # at most 12 characters
      text: May this change alter the published contract?
      options:
        - { value: strict,   label: Additive only, description: "The consequence, not the label again." }
        - { value: breaking, label: May break,     description: "..." }
```

| Field | Why it matters |
|---|---|
| `rationale` | The reason survives the person who wrote it |
| `impact` per value | A reader can weigh the choice without asking |
| `question` | The same decision reaches everyone worded the same way |
| `applies_to` | The question only appears when the files make it relevant |
| `depends_on` | A toggle that only matters under another one stays quiet |
| `askable: false` | Policy nobody should be asked about mid-task |

Enforced by `deck toggle validate --strict`: headers at most 12 characters, at
most four askable values, `off`/`on`/`yes`/`no` quoted (YAML turns them into
booleans), no security toggle defaulting to `ask`.

### `gates.yaml` — the ladder

```yaml
gates:
  - id: build
    title: Build
    from_level: build          # the rung it starts at; omitted, it is
                               # the first one, `static`
    per_repo: "make ${repo.build_target}"   # or `once:` for the workspace
    only_repos: [api-schema]   # optional
    include_downstream: true   # optional: also run it on repositories marked
                               # `downstream`, which every other gate skips
    when: { deploy_mode: [fast, packaged] } # optional condition
    subagent: true             # hint: large output, run it isolated
    timeout: 3600
    measures:                  # optional: numbers to keep, not just judge
      - id: warnings
        title: compiler warnings
        pattern: '(\d+) warnings'   # one capture group, or the whole match
        unit: warnings
        better: lower          # optional; without it, movement is reported
                               # and never judged
```

Rungs come from the `gate_level` toggle, so inserting one means extending that
toggle — not touching the engine.

A **measure** is read out of the output the gate already produced — never a
second command, which could disagree with the first — and appended to a series
under `metrics_store`, one file per metric per repository. Three rules an author
can rely on: the **last** match wins, because a summary comes after the progress
it summarises; a pattern that matches nothing records nothing and says so, since
a missing sample must never read as a zero; and a bad `pattern`, a duplicate
`id` or a `better` that is not `lower`/`higher` is refused when the gates load,
not skipped at run time. `deck metrics` reads the series back; nothing about it
fails a gate.

`downstream: true` on a repository means it produces no artifact, not that it is
never checked. A published table, a requirements matrix, a reference document —
each carries a real obligation to keep up, and build gates rightly skip them. A
gate that exists to verify one says `include_downstream: true`; without it,
nothing enforces the obligation at all. Variables: `${repo.<field>}`,
`${toggle.<id>}`, `${workspace.<dotted>}`, `${target.<field>}`, `${deck.root}`.
A command whose *whole* body is an undeclared variable does not apply to that
repository; a variable missing from inside a larger command blocks the gate.

### `mount.yaml` — the one thing that is not a directory

```yaml
plugin: my-pack@my-marketplace     # enabled in .claude/settings.local.json
marketplace:
  name: my-marketplace
  source: { source: url, url: "https://example.com/packs.git" }
```

Nothing about rules, skills or agents here. What a pack holds in `rules/`,
`skills/` and `agents/` is what gets placed — a directory that had to agree with
a list in this file was two statements of one fact, and the list went stale the
first time somebody added a rule and forgot the entry.

Where each lands is the pack's own axis. A `_workspaces/<name>/<scope>/` layer is
about the workspace, so it is placed once at the workspace root; a `_repos/<name>/`
pack is placed in that repository and no sibling, which is what keeps a convention
meant for one codebase from quietly becoming law across the workspace.

That Claude Code finds all of them at project level is measured, not assumed —
a skill, an agent and a `paths:`-scoped rule, each carrying a word nothing else
could supply, put to a session launched in the directory:

```
SKILL: yes          .claude/skills/<name>/SKILL.md, in the skills list
AGENT: yes          .claude/agents/<name>.md, as an Agent type
CLAUDE_MD: yes      CLAUDE.local.md at the root, in the instructions
RULE: no            .claude/rules/<name>.md — and then yes, once the session
                    read a file its `paths:` matched
```

The last line is the mechanism, not a fault: a rule loads when something it
applies to is read. It also had to be asked twice, because a single `no` reads
exactly like a rule that never arrives.

`plugin` stays declared because it is the one strategy that is not a directory:
it leaves three lines in `.claude/settings.local.json` instead of files, which is
what a pack published as a Claude Code plugin wants. A layer in a collection does
not need it.

Everything placed is recorded in a manifest and removed on unmount, deck never
deletes what it did not place, and `deck save` carries back what the agent
changed — to the file it came from, in the layer it came from.

### `profiles.yaml` — named postures

```yaml
profiles:
  release:
    title: Release candidate
    summary: The whole ladder, the full suite, the contract frozen.
    values: { gate_level: behavior, test_depth: full, doc_sync: required }
```

A profile is the base layer. Anything in `~/.deck/workspaces/<name>/toggles.yaml`, in the
environment, or on the task still wins over it.

## `templates/workspace/workspace.yaml` — the registry, and its two edges

A pack ships the descriptor shape its kind of workspace has, and `deck init`
copies it into `.deck/`. Every field is commented there, because that file is
what a person reads while writing a registry by hand. Two of them describe the
graph, and they are not interchangeable.

```yaml
repos:
  api-schema:
    path: services/api-schema
    impacts: [api-server]        # directional, ordered, transitive
  api-server:
    path: services/api-server
    couples: [ops-scripts]       # mutual, unordered, not transitive
  ops-scripts:
    path: tools/ops-scripts
```

**`impacts:` answers two questions with one edge** — what must I revisit, and
in what order. That is right for most relationships: the schema changes, the
server follows, and the order is the build chain.

Some relationships answer the first question and have no answer to the second.
`api-server` seeds a configuration `ops-scripts` reads, so a change there forces
a look at the scripts; `ops-scripts` owns the command line `api-server` calls at
runtime, so a renamed flag breaks the server. Both directions have file-and-line
evidence and neither goes first. Declaring both as `impacts:` is a cycle —
`deck doctor` refuses it, because the topological order stops existing — and
declaring one throws the other away into a comment no command can read.

**`couples:` is that relationship, recorded.**

| | `impacts:` | `couples:` |
|---|---|---|
| Direction | one way | neither |
| Declared | on the impacting side | on either side; both is accepted and means the same |
| Transitive | yes | no — it is a claim about one pair |
| `deck order`, cycle check | yes | **never**, so a coupling cannot make the graph cyclic |
| `deck impact` | the ordered chain | listed apart, marked as carrying no order |
| `deck mount` expansion | mounted | mounted — it is a repository you may have to edit |
| `deck board plan` grouping | collides | does not — a revisit that changes nothing collides with nothing |
| `deck scopes` · `deck scope` | the chain a scope reaches outside itself | listed beside it, as the other way a boundary leaks |

`deck doctor` checks that every `couples:` target exists, names each pair once
with the side that declared it, and refuses a pair written as an impact and a
coupling at the same time: two edges disagreeing about one pair is exactly the
kind of thing deck reports rather than ranks.

`deck propose impacts` can draft either kind, and `deck propose apply` writes
either kind. A coupling costs the draft a citation in each direction; a pair it
names as two opposite `impacts:` edges is applied as one coupling, since two of
those is the cycle this field exists to avoid.

### Seeding it from a working registry

```bash
deck pack new my-pack --from-workspace
```

This is how one person's registry becomes the template a team shares, and the
question it asks of every field is the same one:

> **Would this value still be true on the next person's machine?**

If it would, it is knowledge the team owns and it travels. If it would not, it
describes this checkout, this host or this afternoon, and a template carrying it
hands the next person something to notice and undo.

| Travels | Why |
|---|---|
| `path`, below the root | relative to the workspace root, and the root is the only per-machine fact a descriptor holds — no entry holds it |
| `role`, `remote_id` | what the repository is, and the upstream every clone of it has |
| `build_target`, `lint` | the names the pack's build and static gates receive |
| `deploy_path`, `services` | where it lands, and what restarts once it has |
| `downstream` | it produces no artifact — the graph reads this in `deck order`, in build targets, and in which repositories a gate runs on |
| `impacts`, `couples` | both edges, or the seeded registry's coupled pairs have quietly become uncoupled |
| `requires_files:` | what the workspace needs to be usable, and true for anyone who has it — `deck doctor` checks it |
| `instruction_files:` | which names carry instruction to an agent here — `deck setup` and `deck doctor` report the ones deck did not place, and a team that reviews its instructions has to be able to review that list too |
| `scopes:` | how the product is carved into initiatives is the team's answer, not one machine's, and the template is the only place it can be versioned |

| Stripped | Why |
|---|---|
| `revision`, `remote` | written by `deck import` from the manifest this machine has now, and rewritten on the next import |
| `path`, outside the root | a repository may sit outside the workspace tree, and there `path` is absolute — this machine's home directory, not layout the next clone shares. Everything else about the repository still seeds; only the path is dropped |
| `paths:` | a tools checkout, absolute and per person |
| `targets:` | emptied rather than dropped, so the shape is still there — an allowlist is a decision, not a copy of someone's hosts |

It is an allowlist and not a denylist because a repository entry accepts any
key: `${repo.<field>}` in a gate command resolves against the whole entry, so
people and importers both add their own. A key nobody named does not travel
silently into a file a team is asked to review. That cuts both ways: `sources`
and `container` sat in the workspace-level allowlist for a time with no reader
anywhere in the repository, and were removed rather than given one they never
had — a key nobody reads is not team knowledge either.

The list lives in `plugins/deck/deck/cmd_pack.py` as `SEEDED_REPO_FIELDS`, with
the rule written above it, and `ci/smoke.sh` asserts one check per field in it.
The descriptor's own top-level fields are beside it in `SEEDED_WORKSPACE_FIELDS`,
checked the same way. Fields have been lost by omission before — `couples`;
`downstream`, which meant every repository that produces no artifact came out
of a seed looking like an ordinary build node; and `scopes:`, which meant the
one documented route to making a carve-up the team's dropped it in silence.
`path` outside the root went the other way: seeded whole, it put a username and
a directory layout into a file a team versions.

### What a scope leaks, and why a coupling counts

A `scopes:` entry names a subset of `repos:`, and the report that matters is
what the subset does not hold. Carve the registry above into an initiative that
takes the schema and the server and leaves the scripts out:

```yaml
scopes:
  payments:
    title: Payments migration
    repos: [api-schema, api-server]
```

```bash
deck scope payments
```

Two of the lines it prints back:

```
  reaches       nothing outside itself through `impacts:`
  coupled with  ops-scripts   (outside the scope, mutual and in no order)
```

A boundary leaks two ways, and they are two lines rather than one: the first is
the ordered chain, the second carries no order, and merging them would hand the
coupling a position in a sequence it has no place in. `deck scopes` prints the
same two, and `deck impact api-server` names the same coupling — three surfaces
answering one question the same way.

The second line is what a coupling is *for* here. `couples:` says two
repositories break each other with evidence on both sides, so an initiative
holding one of them and not the other has a boundary that is wrong, or a
dependency its owners have not agreed with anyone. That is the same finding as
the first line and it is worth having before the work starts, not in the merge
— which is why a scope leaking only a coupling is not told its boundary is
closed.

It reports the couplings of the repositories the scope *holds*, not of the ones
it merely reaches, and it does not chain: a coupling is a claim about one pair.
Taking `ops-scripts` into `repos:` is what makes the line go away.

## Rules versus skills

Both are Claude Code mechanisms; the difference is when they load.

| | Loads when | Use it for |
|---|---|---|
| **Rule** (`rules/*.md` with `paths:`) | Claude reads a matching file | A constraint tied to an area of the code |
| **Skill** (`skills/<name>/SKILL.md`) | Claude judges it relevant, or you invoke it | A procedure with steps |

Write about **consequence**, not description. "Handlers validate at the edge;
nothing below re-checks shapes" earns its place. "This directory contains
handlers" does not — Claude can see that. Point at the decision rather than
restating it: `check api_compat before changing the schema` beats repeating what
each value means, because the toggle already says it and will not drift from
itself.

## Who fills each of these in

A scaffolded pack is mostly empty, and not every part of it has the same route
in. Worth knowing before you go looking for a command that does not exist:

| What | Drafted by | Applied by | Filled by hand |
|---|---|---|---|
| `config/gates.yaml` | `deck propose pack <repo>` — reads CI, Makefile, tox, package.json for commands the project **already** runs | `deck propose apply … --into <pack>` | when no such command exists yet |
| `rules/*.md` | `deck propose pack <repo>` | same, written as files with `paths:` frontmatter | always an option |
| `config/toggles.yaml` | `deck propose toggle "<the decision>"` | **nobody** — deck refuses, and says why: which pack asks the question is a decision, and so is whether the wording survives being read cold | you paste it, then `deck toggle validate --strict` |
| `config/detect.yaml` | `deck pack new` seeds the markers it can see | — | the rest |
| `config/mount.yaml` | — | — | only for `plugin:` and `marketplace:`; nothing else there is read |
| `config/profiles.yaml` | — | — | yes |
| `skills/<name>/SKILL.md` | `deck propose pack <repo>` | `deck propose apply … --into <pack>` | always an option |
| `agents/<name>.md` | `deck propose pack <repo>` | same | always an option |

**A drafted skill is held to a higher bar than a drafted rule, and the reason is
worth keeping in mind while you review one.** A gate is judged by a machine. A
rule is a claim a reader can disagree with. A skill is an instruction somebody
will follow — a procedure that is subtly wrong does not get argued with, it gets
executed. So the draft has to earn it:

- every step names the file, commit or document it was **read from**; a step
  worked out from how the code looks belongs in `questions`
- at least two steps, and an order that matters — if reordering breaks nothing,
  what was found is a rule
- the file says on its face that nobody has walked it yet

An agent is a bigger claim still: that the default posture is wrong for this
repository. Proposing none is the ordinary answer.

Neither is ever overwritten. A skill somebody reviewed and edited is exactly
what a draft must not replace, so an existing file is left alone.

`deck pack new` still creates `skills/` and `agents/` empty. They used to ship a
`README.md` example, and `mount` placed it as though it were a real skill.

## Boards — the four shapes, and where they live

A board is declared under `backlog:` in the descriptor. deck reads four
shapes and writes to two of them:

| Shape | Declared as | Read | Write |
|---|---|---|---|
| Tasks file | `{ type: tasks, file: planning/board.yaml }` | yes | yes |
| Markdown checklist | `{ type: <label>, file: ROADMAP.md }` | yes | no |
| A pack's own adapter | `{ type: <label>, command: ./bin/backlog.py … }` | yes | no |
| Tracker | `{ type: jira \| github \| gitlab \| gerrit, … }` | yes | yes |

The reader is chosen by the file extension, not by `type:` — `type` is a label
you choose, and calling your file `roadmap` should not decide how it is parsed.
Naming it `tasks` or `board` forces the tasks reader.

A `jira` source needs its `url:` and then either a `project:` or a `jql:` of its
own. Both are refused without one, offline, before anything is sent: Jira's
search endpoint answers an unbounded query with a 400, and `project = ` with
nothing after it is the query deck would otherwise have built.

```yaml
backlog:
  - { type: jira, url: https://example.atlassian.net, project: ACME }
  - { type: jira, url: https://example.atlassian.net, jql: "labels = agent-ready AND statusCategory != Done" }
```

### Narrowing what a tracker source reads

A team's tracker rarely holds only what one workspace cares about, so every
provider takes a filter — the field that turns "everything in this project" into
"the work this workspace acts on". `type`, `repo`/`project` and `url` say
*where* the tracker is; the filter below says *which* of its issues count. Each
provider takes its own, and each defaults to the widest reasonable read rather
than to nothing, so a source declared without one still reads something sane:

| Kind | Field | Default | What the default reads |
|---|---|---|---|
| `github` | `query:`, plus `include:` for which kind | `is:open`, `include: issues` | every issue not yet closed |
| `gitlab` | `state:` (plus optional `labels:`) | `state: opened`, no label filter | every open issue, of any label |
| `jira` | `jql:`, or `project:` for a plain project filter | none — refused without one | the search endpoint answers an unbounded query with 400, so pick one |
| `gerrit` | `query:` | `status:open` | every open change |

```yaml
backlog:
  - { type: github, repo: acme/api, query: "is:open label:agent-ready" }
  - { type: github, repo: acme/api, include: both, query: "is:open" }
  - { type: gitlab, project: acme/api, state: opened, labels: agent-ready }
  - { type: jira, url: https://example.atlassian.net, jql: "project = ACME AND labels = agent-ready" }
  - { type: gerrit, url: https://gerrit.example.com, query: "status:open topic:agent-ready" }
```

A github source reads `issues` unless it says otherwise; `include: pulls` reads
pull requests and `include: both` reads either. A pull request is work in
flight — the half of a board that goes missing the day changes start arriving by
review — and a task that came back as one says so, because github numbers issues
and pull requests in one sequence and `#11` on its own does not say which it is.
The kind is not a second filter: a `query:` that already names one (`is:pr`) is
the descriptor's answer and nothing is added beside it, since asking github for
both qualifiers at once matches nothing and would empty the board without
saying why.

### Saying a task is taken, on a board with two states

deck has three states and a GitHub issue has two, so `in-progress` never comes
back from one on its own. deck does not repair that by guessing: reading anyone
assigned as working on it is wrong for every team that assigns before somebody
starts, and a tool that guesses about who is on what is a tool nobody can plan
against.

So the source says how its own board writes it down:

| `in_progress:` | what it means |
|---|---|
| `assignee` | anyone assigned is on it |
| `label:wip` | that label is what taken means here |
| *(absent)* | this board cannot express it |

Absent is not a failure. `deck board list` prints the holder's name either way —
that is the floor, and it is what stops two people picking the same task — and
where the source says nothing it adds one line saying that `[ ]` here means "not
closed" rather than "nobody is on this", naming the two ways to answer. A closed
task stays closed; held and finished are different answers and nothing collapses
them.

`deck bundle` can hand a pull request the body it already writes — `--open-pr`
opens or updates the request for the branch the work is on, `--pr` reports the
state of the request a task belongs to, and neither happens without the flag or
without the permission `tracker_writes` holds every other tracker write to. A
new request merges into whatever the repository says it merges into; a source
that wants another branch names it with `base:`.
deck reviews nothing: it writes a title and a body, names the reviews that have
not happened, and performs none of them.

Whether a descriptor field gets the same machine check a command does: yes, for
this table specifically. `deck --help` cannot enumerate a tracker's fields the
way it enumerates subcommands — they are read with `source.get(...)` deep
inside `trackers.py`, not declared anywhere central — so `ci/docs-cover.py`
checks a short, hand-maintained list of `(provider, field)` pairs against this
document instead of introspecting the descriptor schema. That is deliberately
narrower than the command check: it catches this table going stale, not every
field a source could ever carry.

### What a tracker cannot carry

A tracker is a board somebody else designed, and two things deck's own board
holds have nowhere to go in it. Both are written here rather than discovered
after the move.

**State.** deck has three — `open`, `in-progress`, `done` — and every tracker
here has two. The mapping is one-way and lossy in one direction:

| Kind | reads as `done` | everything else reads as |
|---|---|---|
| `github` | `state: closed` | `open` |
| `gitlab` | `state: closed` | `open` |
| `jira` | `statusCategory` is `done` | `open` |
| `gerrit` | `MERGED` or `ABANDONED` | `open` |

So `in-progress` never comes back from a tracker. What does come back is the
assignee, and that is what `deck board list` and `deck board plan` show:

```
  [~] #7                       rate limit in `a`
        api-server
        held by ana
```

`[~]` means somebody is named on the task — because the board said
`in-progress`, or because the tracker has an assignee, which on a two-state
source is the only evidence that survives. deck does not turn an assignee into
`in-progress`: a team that assigns before anyone starts would have its whole
board read as taken. The two signals are shown, not merged, and a workflow
reading `deck board plan --json` gets `status` and `assignee` per task and
decides for itself.

`deck board claim` refuses a task another name already holds, and the refusal
works against a tracker — it reads the assignee the tracker returned, the same
one the list prints.

**Acceptance criteria.** `deck board done` refuses to close a task while a
declared criterion is unaccepted, and no tracker has a field for them. deck does
not read them out of an issue body either: parsing somebody else's prose is the
guess it refuses everywhere else. A tracker item is not closed by deck at all —
`done` names where to close it — so what this actually costs is a tasks file
entry written without `acceptance:`, which is what a board migrated onto a
tracker leaves behind. `deck board done` says so as it closes, and `deck bundle`
carries the same qualifier: the closure rests on the ladder alone, and the
ladder does not decide whether this was what somebody asked for. Criteria that
have to be enforced live in a tasks entry linked to the issue with
`ext_provider` / `ext_id`, below.

The tasks file is the shape deck itself writes:

```yaml
version: 1
tasks:
  - id: cdb-boot-reconcile
    title: Reconcile CDB config to the filesystem at boot
    repos: [api-server, api-client]
    status: open            # open · in-progress · done
    exclusive: false        # true = nothing else may run beside it
    assignee: null
    labels: [p1]
    target: bench-1         # optional, from the allowlist
    url: null
    ext_provider: jira      # where this work lives in another system
    ext_id: PROJ-412
```

Only `id` and `title` are required. `repos` is what makes grouping work: `deck
board plan` collides two tasks when the closure of what they edit overlaps, so a
task with no repositories cannot be grouped and is reported as such rather than
guessed at.

### A board per scope

A `scopes:` entry may declare a `backlog:` of its own, and then that board *is*
the scope's board — `deck --scope <name> board list` reads it and nothing else.
A scope without one works from the shared board, narrowed to the tasks its
repositories cover; a task there naming no repository belongs to no scope and is
reported rather than handed to whichever one happens to be active.

A scope's repositories, and what the boundary leaks when it is drawn in the
wrong place, are in [What a scope leaks](#what-a-scope-leaks-and-why-a-coupling-counts)
above. The carve-up lives in the layer's own descriptor, which is versioned in
the collection — so a scope is the team's by being where the team can read it,
not by having been copied into a template first.

#### Where an initiative's definition lives

In the descriptor of the layer it belongs to, and nowhere else. `scopes:` is read
from `_workspaces/<name>/<scope>/workspace.yaml`, which is versioned in the
collection with everything else that layer carries.

That is a change worth stating plainly, because deck used to work the other way.
While the descriptor was per machine and never versioned, two people could run
the same command in the same named scope over different repositories with nothing
to tell either of them — so a pack shipped a `templates/workspace/workspace.yaml`
as the team's copy, and deck compared this machine's carve-up against it and
reported the divergence.

None of that survives a versioned descriptor. The template was a stand-in for a
file that could not be versioned; the file can be versioned now, so the stand-in
has no job, and the comparison has no two sides. `deck scopes` and
`deck scope <name>` report the carve-up itself, which is the only one there is.

### The briefing — what the task is for, and how anyone would know it worked

A title and a repository say what to touch. They never say what it is for, or
what would make it right, and an agent given only those does the plausible thing
and reports that it did it.

```bash
deck board template     # a well-formed item, to copy
```

```yaml
  - id: ABC-1
    title: One line, in the words of whoever wants it
    as_a: someone who runs the board unattended
    so_that: a delivery that passes the ladder is also the thing that was asked for
    repos: [api-schema]
    acceptance:
      - a client on the old schema keeps working
      - the new field appears in the published table
```

**`acceptance:` is the half a gate cannot reach.** The ladder proves the code
holds together; it decides nothing about whether this is what somebody wanted.
So `deck board done` refuses while a criterion is unaccepted, and each one is
accepted by name:

```bash
deck board done ABC-1 --accept "a client on the old schema keeps working" --yes
```

`deck bundle` blocks on the same thing, and a task declaring none is qualified
rather than passed in silence — "nothing states what it was for" is a finding, not
an absence.

`--force` closes without them, for work the criteria genuinely do not fit. It is
a thing you say, not a thing that happens.

### `decides:` — a task that owns its own decision

Answering every pending decision before a run is what makes it autonomous. It is
also how you empty a task whose entire point is the decision — an item titled
"decide and implement X" arriving with X already chosen did the implementing and
skipped the deciding, and a reviewer caught it.

```yaml
  - id: POLY-3
    title: Decide and implement unknown-code behaviour
    repos: [hello-core, hello-cli]
    decides: [unknown_locale]      # not pre-answered; this task makes the call
```

`deck board ask-plan` leaves it alone and says why:

```
owned by a task, and deliberately not answered here:
  unknown_locale       POLY-3 exists to decide it — it escalates with `deck ask`
```

The distinction is between **policy** — how far to verify, how to deploy, stable
across the board — and **the work itself**. Policy is answered up front. A
decision that is the work stays with the work.

### `ext_provider` / `ext_id` — one piece of work, two systems

Teams rarely have one board. The work is a Jira issue, a Linear ticket or a
GitHub issue, *and* it needs things no tracker has a field for: which
repositories it touches, whether anything may run beside it, which bench it
deploys to. Rather than choosing, name the same work in both:

```yaml
  - id: rate-limit
    title: Rate limit the NBI
    repos: [api-server]        # what no tracker knows
    exclusive: true
    ext_provider: jira
    ext_id: PROJ-412
```

When a source deck can fetch returns that same identity, the two are
**reconciled into one task**, not listed twice:

| Comes from the tracker | Comes from the local entry |
|---|---|
| `status`, `assignee`, `url`, `title` | `repos`, `exclusive`, `target` |

Labels are the union of both. The rule follows from what each side actually
knows: the tracker is live and authoritative about state, the local file is
curated and authoritative about the workspace. Picking one would throw away the
half not chosen.

```
$ deck board show rate-limit
  status    open
  repos     api-server
  external  jira:PROJ-412   (reconciled with the local entry)
```

`ext_provider` is **not restricted to the four trackers deck can fetch**. Naming
`linear`, `asana` or `azure` records where the work lives and survives in the
board even though deck will never call that API. Two local tasks claiming one
external identity is reported as a mistake rather than merged.

Record it at creation with `deck board new "…" --ext jira:PROJ-412`.

### `delivery_trailer` — the same idea, one layer down

`ext_provider` names the identity a *task* has in the system it came from. Under
change-based review a **delivery** has one too, and it is not the commit hash.
A change is pushed, a reviewer asks for something, and the next round is
`git commit --amend` on the same change: new hash, same work. The stable name is
a trailer the server's `commit-msg` hook writes and nobody edits.

`deck bundle` reported hashes, so a bundle written before a round of review
named commits that no longer existed and one written after named different ones
for the same delivery. Neither was wrong about what it saw; both were wrong
about what the delivery was.

Which trailer — or whether there is one at all — is a pack's to declare, because
it is a property of the server that will land the change and the engine has
never heard of any server:

```yaml
toggles:
  - id: delivery_trailer
    group: delivery
    title: Delivery identity
    summary: The commit-message trailer this review server uses to name a delivery.
    type: enum
    values: ["off", Change-Id]
    default: Change-Id
    stage: [deliver]
    scope: [workspace]
    risk: low
    impact:
      "off": A delivery is named by the commit that carries it.
      Change-Id: A delivery is named by its trailer, which survives an amend.
```

With it declared, the bundle names each delivery by its trailer and says which
commit it is at *now*:

```
  api-server           1 change(s) · 1 commit(s) · 3 file(s) · +3 -0
       I0fc2a91b4d5e6f708192a3b4c5d6e7f809a1b2c3  CH-1: widen the schema   (now at fe24e54)
```

No pack declaring it, or a value of `off`, and nothing changes: every delivery is
named by its commit exactly as before. deck ships no such toggle in the core
catalog and assumes no trailer — a workspace on a branch-and-merge flow has no
convention to read and is not given one.

**An amend does not invalidate gate evidence, and that is deliberate.** A ladder
ran against a tree; an amend produces a different tree, and nothing notices. The
gate record says what it ran on and when, which is the claim it was ever making;
re-running the ladder after every patchset is the operator's call, not deck's.

**A board file has no default location.** deck used to fall back to
`.deck/board.yaml`, which is the one place a shared board must not go — `.deck/`
is per machine and not versioned, so the task would be invisible to the rest of
the team. Declare `file:` somewhere the team versions, or use a tracker.

### When your format is your own

Neither a checklist nor a tasks file? Declare a `command:` and let the pack read
it. The command prints `{"tasks": [...]}` and the engine stays ignorant of the
format — which is the point, because a roadmap written for people is not going
to be rewritten to suit a tool.

```yaml
backlog:
  - type: roadmap
    file: planning/roadmap.md
    command: roadmap-to-tasks roadmap planning/roadmap.md
```

A source whose file exists but yields no tasks says so, naming the file and the
shape its reader expected. Silence there is how a declared backlog passes
`deck doctor` and leaves `deck board list` empty with nothing to explain it.

## When there is no entry for it

A toggle is a decision someone foresaw. Everything a team already knows it keeps
re-deciding fits there. Nothing else does — and an agent that meets a genuinely
new trade-off has, without somewhere to put it, only two options: decide alone,
or stall. A board run stalled on exactly that, twice, before a line was edited.

```bash
deck ask new "Should regional tags like de-DE resolve to de?" \
  --task POLY-1 --options strict,aliases \
  --context "German is the first language where a regional tag is likely to be typed."

deck ask list                       # what is waiting on a person
deck ask publish <id> --into <pack> # so a colleague can answer it
deck ask resolve <id> "<answer>"    # and what it wants to become
deck ask fold <id> --as rule --into <pack> --paths "src/**"
deck ask list --resolved            # what the next run should read first
```

`publish` is how a question crosses to another person. A consultation is
written under `.deck/`, which is machine state and is never versioned, so
without it the whole loop — an agent records what it cannot decide, a person
answers, `fold` writes the answer into a pack — runs inside one checkout until
the last step.

It moves the record into a pack's `consultations/`, where it travels the way
rules do: versioned, reviewed, and read by everyone whose workspace has that
pack. A move rather than a copy, because two records of one question drift the
moment either is answered. `asked_in` is dropped — it names a session on one
machine — and `asked_by` is kept, because an answer nobody can attribute is an
answer nobody can ask about.

Deliberate rather than automatic: not every half-formed question is worth three
people's attention, and a store that fills itself is one nobody reads.

`fold` writes the answer into a pack as a rule, a toggle or a gate, carrying the
question and the answer with it so the reasoning outlives the session. deck does
not do it on its own, and will not invent the parts the consultation does not
contain: a rule is refused without `--paths`, because one without them loads on
every turn; a gate without `--command`, because a gate deck invented is worse
than none; a toggle until every value has an `--impact`, because the answer
defends only the value it chose.

**Nothing waits on a consultation.** The agent records it and keeps working,
saying what it did in the meantime and what would change if the answer goes the
other way. A run that stops for a question is a run that fails at the first one.

`resolve` says which artifact the answer looks like — a toggle if the choice had
options, a rule if it reads as a constraint, a gate if a machine could check it —
and then leaves the writing to a person. That is deliberate. Whether an answer
recurs is a judgement nobody can make from one instance, and it is the whole
difference between knowledge and a transcript.

## Taking artifacts from elsewhere

```bash
deck pack sources                              # what deck knows about
deck pack add owner/repo --skills reviewer --yes
deck pack sources --vendored                   # what you took, and from where
deck pack update                               # re-check it against the source
```

Vendoring, not installing: what you take becomes files you own, reviewed and
committed like anything else. A plugin you *install* stays under its author's
control, which is right for a marketplace and wrong for something you need to
adapt. `deck pack sources` prints the shipped registry, which is deliberately
short — it lists only sources whose existence can be checked, because a curated
list nobody verified borrows credibility it has not earned. Star counts are read
from the API at the moment you add, so they are data rather than a claim.

Two safety rules, because these files instruct an agent:

- **Hooks are not taken** unless you ask with `--with-hooks`. A hook is a shell
  command that runs on your machine.
- **Provenance is recorded** — source, ref, commit and a per-file hash land in
  `config/sources.yaml`, so what you have can be audited and updated. One record
  per artifact: taking it again replaces that record rather than adding a second
  answer to the same question.

### Re-checking what you took

A provenance record only pays for itself if something reads it back. That is
`deck pack update`: it clones each recorded source once, and answers the two
questions the record makes answerable — has the source moved since you took
this, and has anyone changed the copy here.

```bash
deck pack update                     # report; writes nothing
deck pack update skills/reviewer     # one artifact, by path or by name
deck pack update --yes               # take what moved upstream and was not edited here
deck pack update --check             # exit non-zero if anything has moved, for a gate
```

The two questions are kept apart because the answers mean different things:

| | |
|---|---|
| `current` | unchanged since you took it |
| `local` | edited here; the source has not moved |
| `upstream` | the source moved; your copy is what you took |
| `diverged` | edited here **and** the source moved |
| `withdrawn` | no longer in the source at this ref |
| `missing` | recorded, but not in the pack any more |
| `unreachable` | the source could not be read — **not** checked |

`--yes` takes the `upstream` ones and leaves the rest alone. A `diverged`
artifact is refused, not merged and not ranked: adapting what you take is the
reason to vendor at all, so overwriting a local edit is the one outcome that
loses work. `--force` takes it anyway, and the refusal says so before you reach
for it. An `unreachable` source is reported as unchecked and never as unchanged,
and it fails the command — silence about an artifact nobody could read is the
one answer that would be a lie.

`--yes` also refreshes the recorded commit for artifacts whose bytes still match
upstream, so the record says which commit the copy was last confirmed against
rather than the one it happened to be taken from.

## A collection, and how it links to your code

Most teams end up with a *collection* — one pack per project, in one repository
the team shares. The link to the workspace is a name:

```
   projs/                          ai-packs/
   ├── group1/                     ├── _workspaces/
   │   ├── proj1/                  │   └── all/default/     ← every repository, always
   │   └── proj2/                  ├── _repos/
   └── group2/                     │   ├── proj1/   ◄────────── by name
       ├── proj3/                  │   ├── group1/proj2/   ← groups may be mirrored
       └── proj4/                  │   └── group2/proj3/
                                   └──   (proj4 has no pack — deck says so
                                          rather than staying quiet)
```

Point deck at one or more collections with `packs_root:` in the descriptor or
`DECK_PACKS_ROOT`. A collection holds two directories and the names inside them
are the whole of the linking:

`_repos/<name>/` is that repository's pack, matched by the directory name or the
registry name, two levels deep so a collection can mirror your groups.

`_workspaces/<name>/<scope>/` is a layer over the workspace. `all` and `default`
always exist and are the base — every workspace, every scope. A layer under
another workspace name, or another scope, overlays that base file by file, which
is why one file name may appear at several levels without being the collision a
repository pack still is. Where the two axes disagree, the name wins: a workspace
is a place and a scope is a phase, and a rule written for this workspace should
not be displaced by one written for every workspace merely because an initiative
is running.

The descriptor lives in the layer it belongs to — `_workspaces/<name>/<scope>/workspace.yaml`
— so pointing deck at that file is what says which workspace and which scope this
is. Neither needs a key inside the file, and a descriptor moved between layers
cannot end up disagreeing with its own contents.

`packs_root` takes a list, because layering is real: a domain collection any
team could use, and an organisation's own on top of it.

A name claimed by two packs is reported by `deck packs` and `deck doctor`, and
never resolved: picking one would be a guess about your intent, and which of the
two a walk of the collection reaches first is the order the filesystem handed
back its entries. `deck setup --packs-root <path>` does the linking and prints
what matched and what did not.

## The two packs deck ships for itself

deck is its own first user, and the split is the one every project ends up
needing:

| | Directory | Who reads it | Delivered as |
|---|---|---|---|
| **Usage** | `plugins/deck/` | Claude, in any workspace that uses deck | a Claude Code plugin you install |
| **Development** | `_workspaces/all/default/` in [deck-ai-packs](https://github.com/devfilipe/deck-ai-packs) | Claude, in deck's own checkout | a pack, mounted while contributing |

The **usage pack** is what `claude plugin install deck@deck` puts in a session:
eleven skills — `workspace`, `toggles`, `gates`, `metrics`, `board`, `bundle`,
`mount`, `packs`, `asking`, `cost`, `doctor` — plus the `SessionEnd` hook that takes back
anything left mounted. It
teaches an agent to consult the control plane instead of guessing, and it is
delivered as a plugin because that is how it reaches a workspace that is not
deck's own.

The **development pack** is for contributing to deck: the design line (what deck
is not allowed to reinvent), the writing standard, how to add a command, and how
a change is verified. It also declares deck's own gate ladder, so the tool
verifies itself with the mechanism it offers everyone else:

```
$ deck gate run --task self
  ok   lint         workspace   0.0s
  ok   smoke        workspace   22.3s
```

A pack for using a tool and a pack for building it are different audiences, and
mixing them costs the first audience context it will never use.

## Layers, and what each one may reach

A collection is layered whether or not anyone calls it that. Four kinds of pack
apply to a repository, in this order — most general first, so the most specific
has the last word:

```
   named explicitly     `packs:` in the descriptor, then DECK_PACKS
          ↓             a domain or organisation layer, named after no repository
   <name>/default       every repository, by where the pack sits
          ↓
   scope: <name>        every repository the initiative holds, while it is active
          ↓
   <repo-name>          that repository, and no other
```

`deck packs` prints exactly this, for the workspace or for one repository:

```
$ deck packs
packs   3 in play, merged most general first

  1  yocto-base    workspace (named)   6 toggle(s) · 3 gate(s) · 0 rule(s)
  2  org-acme      workspace (named)   1 toggle(s) · 1 gate(s) · 2 rule(s)
     requires yocto-base
  3  proj1         proj1               0 toggle(s) · 1 gate(s) · 1 rule(s)

not in play   bound to an initiative, and loaded only while it is active
  payments-ops                 scope payments       0 toggle(s) · 1 gate(s) · 1 rule(s)
     bring it in with: deck --scope payments <command>

overlaid   a later pack takes over an entry an earlier one declared
  gate    build                    yocto-base -> org-acme
```

### A pack that belongs to an initiative

A scope is an initiative: a named subset of the registry, with a board and a
posture of its own. Some knowledge only matters while one is running — the
vocabulary a compliance programme reports in, the checks that stand in for an
auditor — and before `scope:` the only two places to put it were "loaded for
everybody" and "written nowhere".

```yaml
# packs/payments-ops/config/detect.yaml
markers: []
scope: payments        # the initiative this pack belongs to
```

**The binding is in the pack, not in the directory.** A convention — a pack
under a reserved parent named after the scope — would make the binding a
property of the collection: a pack pointed at by `packs:` sits in no collection
and could never be bound, one vendored elsewhere would silently change what it
belonged to, and nothing inside it would say what that was. `scope:` travels
with the pack through all three routes a pack arrives by, and sits beside
`requires:` because both answer the same question: when does this pack apply.

| | |
|---|---|
| In play | only under `deck --scope <name>`. With no scope active it contributes nothing — not a toggle, not a gate, not a rule |
| Merge order | after the workspace-wide packs, before any repository's own. An initiative is narrower than the workspace and wider than one codebase |
| A collision | the rule every other layer uses: reusing an `id` needs `overrides: true`, and then the scope's pack wins, because it merges later. Without the flag deck refuses and names both origins |
| Outside the scope | the same `id` is the workspace pack's again, which is why the evidence has to say which scope was active |
| Its rules and gates | reach the repositories the scope holds and no others, even when `--repos` names one outside. Same rule as a repository pack's, one layer up |
| Not in play | still listed by `deck packs`, under `not in play`, with the command that brings it in. Knowledge nobody can find is worse than knowledge loaded too widely |

**A scope-bound pack may declare gates**, and the condition is that the evidence
says so. A rule is knowledge and travels harmlessly; a gate is a claim about
what verifies a delivery, and one that appears and disappears with a flag is a
different proposition. So `deck gate run` records the active scope in
`.deck/gates/<task>.json`, `deck gate report` prints it, and `deck bundle` names
it on the line under the rung and names the pack each gate came from:

```
what was verified
  level    static   ladder static -> build -> deploy -> behavior   …
  scope    payments   the ladder climbed inside this initiative, not the whole registry
  ok   lint           passed
  ok   audit          passed
```

Several packs may be bound to one scope, exactly as several may be shared — that
layer is a list for the same reason.

### `requires:` — order you declare instead of order you inherit

A pack names the packs it builds on in its own `config/detect.yaml`, beside the
binaries it needs:

```yaml
prerequisites: [bitbake]      # must be on PATH
requires: [yocto-base]        # must be in play, and merges first
```

They merge **before** it, so anything it marks `overrides: true` wins over
theirs. That is the whole reason to declare a requirement: without it, the order
comes from where the packs happened to be found, and an organisation pack
overriding its domain pack works or not depending on how the directories sort.

A requirement that is missing, or circular, is reported by `deck packs` and
`deck doctor` — it does not abort, because refusing to run takes the diagnosis
away at the moment it is needed.

**Scope is not advisory.** A pack named after a repository describes *that*
codebase: its rules mount only there, and a gate it declares defaults to
`only_repos: [<that repo>]`. A convention meant for one repository must not
become law across the workspace because someone left a `repos:` key off a line.
Widen it deliberately with `repos:` on the rule or `only_repos:` on the gate.

**Extending across layers is explicit.** Reusing an `id` a lower layer already
defined — a toggle or a gate — requires `overrides: true` on the entry, and the
two are merged, key by key. Without the flag deck refuses and names both
origins. This is the same rule in both catalogs, so there is one mechanism to
learn:

```yaml
# ai-packs/proj2/config/gates.yaml — extending the shared build gate
gates:
  - id: build
    overrides: true
    per_repo: "make -C firmware ${repo.build_target}"
```

An override says only what it changes; everything else is inherited. It does not
inherit the scope default, because narrowing a shared gate to one repository is
a decision that should be written rather than deduced.

What deck deliberately does **not** have is a priority number that decides a
collision on your behalf. The pack namespace is your own repository names — a
few dozen, owned by people who can talk to each other — so two packs claiming
one name is a mistake to fix, not an ambiguity to rank. `deck packs` and `deck
doctor` report it, with the edit that resolves it; nothing resolves it silently.
The same rule governs a scope name two packs ship: reported, and compared
against neither.

## Where a pack lives

| Shape | When |
|---|---|
| Its own repository | It is shared across teams, or published |
| A `packs/` directory in an existing repo | It belongs to one product and one team |
| Several packs, layered | A domain pack (build system, delivery shape) with an organisation pack depending on it |

Layering is worth the trouble once a second product appears: a Yocto pack that
any BSP could use, and an organisation pack on top with its own hosts, remotes
and container image. The organisation-specific half stays private; the reusable
half does not have to.

## Keeping it honest

```bash
deck pack validate my-pack           # structure, mount references, gate shape
deck toggle validate --strict        # catalog wording, against the core
claude plugin validate my-pack       # the Claude Code half
deck pack review                     # whether it is still doing anything
```

`validate` asks whether a pack is well formed. **`review` asks whether it is
doing anything**, which is the harder question and the one that decays quietly:

```
$ deck pack review
  hello-cli    hello-cli    0 rule(s) · 0 skill(s) · 1 toggle(s) · 0 gate(s)
               !! toggle locale_aliases has a fixed default and is never asked —
                  if nobody would change it, it is a rule, not a decision

gate history, from the evidence this workspace kept
  table            ran   4  caught   0  skipped   0
```

Every signal comes from what the workspace already recorded. Nothing is a
judgement and nothing calls a model:

| Signal | Why it matters |
|---|---|
| always-on cost | a skill's description is paid in every session, used or not |
| a rule matching no file | it never loads, and nothing else would ever tell you |
| a rule naming a command a gate already runs | a machine is already deciding it, and the rule is paying context to say so again |
| a gate that ran often and never failed | either the code is perfect or the gate stopped asserting |
| a gate skipped every time | it is declared and has never run |
| a toggle with a fixed default | nobody would change it, so it is a rule wearing a decision's clothes |
| a toggle with fewer than two values | not a choice |

None of it is automatically wrong. Each is a place where a pack may have stopped
earning its context — which is the only failure mode a pack has that nobody
notices until something gets through.

A catalog people cannot read is a catalog people start ignoring. Every entry
should answer four things: what it is, why it exists, what each value costs, and
how the question should be put to a person.
