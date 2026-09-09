# Getting started

## 0 · What deck is, and what it is not

deck is a **command-line tool that holds what your team knows about its own
workspace**, so an agent can act on it and a reviewer can check what happened.
It answers seven questions that no coding agent can work out on its own:

| | Question | Command |
|---|---|---|
| Map | Where is everything, and what does a change here reach? | `deck impact` |
| Decisions | What is already decided, and what must be asked? | `deck toggle` |
| Context | What should an agent know while working here? | `deck mount` |
| Proof | How far did this actually get verified? | `deck gate` |
| Handover | Is this ready to merge, and what must a reviewer take on trust? | `deck bundle` |
| Trend | Which way are the numbers behind the gates going? | `deck metrics` |
| Accounting | What did it cost? | `deck cost` |

**deck does not write code, spawn agents, create worktrees, or render a UI of
its own.** Claude Code already does all of that, and better. deck supplies the
part Claude Code cannot know — *your* workspace — and hands it over through
mechanisms Claude Code already has.

It is a plain CLI first. Everything works in a terminal, in a script, or in CI,
with no agent present.

### What comes from you

deck ships an engine and no domain knowledge at all. Three things are yours to
provide, and none of them is a gap in the tool:

- **The edges.** Which repositories a change forces you to touch. A manifest
  declares a checkout, never a propagation, so no importer can derive them.
- **The commands.** How your project builds, deploys, and tests. deck runs the
  strings your pack declares; it has never heard of `bitbake` or `helm`.
- **The decisions.** The calls your team keeps re-making, written down once.

They live in a **pack**, which is versioned and reviewed like any other code.

---

## 1 · Install

### The tool

```bash
git clone https://github.com/devfilipe/deck.git ~/tools/deck
ln -s ~/tools/deck/plugins/deck/bin/deck ~/.local/bin/deck
deck --help
```

Requirements: Python 3.10+ and PyYAML. `git` for most things; `tmux` only for
`deck ui`. No install step, no virtualenv — the entry point runs the package
from the clone.

### The Claude Code side

Installing deck as a plugin is what lets an agent use it without being told how:

```bash
claude plugin marketplace add ~/tools/deck    # a local directory works
claude plugin install deck@deck
```

That adds eleven skills — `workspace`, `toggles`, `gates`, `metrics`, `board`,
`bundle`, `mount`, `packs`, `asking`, `cost`, `doctor` — which teach Claude to
consult the control plane instead of guessing, and a `SessionEnd` hook that takes
back anything left mounted. It is paid in every session: `claude plugin details
deck` prints the figure for what you have installed, which is the only one worth
quoting.

#### Turning it on where it belongs, and off where it does not

Installing enables it at **user** scope: every project, whether or not it uses
deck — that cost paid in repositories with no `.deck/` at all. Most
teams want the opposite — off by default, on in the workspaces that use it:

```bash
claude plugin disable deck@deck --scope user     # not everywhere
cd ~/work/projs
claude plugin enable deck@deck --scope project   # here, and for the team
```

Those two commands write to two different files:

```
~/.claude/settings.json          {"deck@deck": false}    yours, every project
~/work/projs/.claude/settings.json {"deck@deck": true}   the project's, committed
```

The project file is the one your team commits, so a colleague who clones the
workspace gets deck switched on without doing anything. Scope precedence is
managed → local → project → user, so a project saying `true` beats a user
saying `false`. `claude plugin list` reports the answer for the directory you
run it in.

Three scopes, three intents:

| `--scope` | Writes to | Use it for |
|---|---|---|
| `user` | `~/.claude/settings.json` | your machine, every project |
| `project` | `.claude/settings.json` | the team, committed with the repo |
| `local` | `.claude/settings.local.json` | you, in this project only, gitignored |

To turn it off for a while, `claude plugin disable deck@deck` — or `/plugin`
inside a session, which lists what is installed and toggles it without leaving
Claude. Uninstalling is `claude plugin uninstall deck@deck`; the CLI keeps
working either way, since the plugin only adds the skills and the cleanup hook.

#### The status line

Optional, and worth it once you are using deck daily:

```bash
deck statusline --settings     # prints the snippet for .claude/settings.json
```

Two or three rows inside Claude's own window: which workspace, which profile,
how far this delivery verifies, and what is still waiting to be asked.

### Where things go

```
~/tools/deck            the tool. One clone, updated with `git pull`.
~/work/projs/           your workspace — the code you actually change.
   .deck/               deck's state here. Per machine, not versioned.
~/work/ai-packs/        the packs. Its own repository, shared by the team.
```

The only rule that matters: **the packs are versioned and reviewed; `.deck/` is
not.** `.deck/` holds paths, hosts and tokens, which differ per person.

---

## 2 · The one convention

**A pack directory named after a repository is that repository's pack.** No
mapping table, because a mapping table is a file nobody keeps current.

```
   projs/                          ai-packs/
   ├── group1/                     ├── _workspaces/
   │   ├── proj1/                  │   └── all/default/     ← every repository
   │   └── proj2/                  ├── _repos/
   └── group2/                     │   ├── proj1/   ◄────────── by name
       ├── proj3/                  │   ├── group1/proj2/   ← groups mirrored
       └── proj4/                  │   └── group2/proj3/
                                   └──   (proj4 has no pack — deck says so)
```

Under `_repos/` deck looks two levels deep and matches on the directory name or
the registry name; a name claimed by two packs there is reported rather than
resolved, because picking one would be a guess about your intent.

Under `_workspaces/` the pair `<name>/<scope>` is the index. `all` and `default`
always exist and are the base — every workspace, every scope — and a layer under
another name or another scope overlays it, file by file. That is the one place a
repeated file name is not a collision but the point.

`packs_root` takes a list, so a domain collection any team could use and your
organisation's own can sit side by side. A pack named after no repository at all
— a domain layer, a build system — goes under `packs:` in the descriptor instead,
and declares what it builds on with `requires:`. `deck packs` shows the resulting
merge order and who overrides whom.

### What lives outside the workspace

Real trees are not tidy. A shared tools checkout, a scripts directory, a vendor
drop — used while developing here, living somewhere else. deck asks one question
about each: **do you change it, or only use it?**

```yaml
# the descriptor: _workspaces/<name>/<scope>/workspace.yaml in the collection,
# or .deck/workspace.yaml in a workspace that has no collection yet
repos:
  tools: { path: ../shared-tools }   # you edit it → a repository, wherever it lives
paths:
  scripts: ~/work/scripts            # you only invoke it → a named directory
```

Something you edit is a repository even when it sits outside the root: it earns
impact edges, a pack of its own, and a place in the gate ladder. `path:` accepts
`../`, an absolute path, and `~`.

Something you only invoke is a **path**. It carries no edges, declares no gates,
and is never mounted into. A gate or a rule refers to it as `${path.scripts}`,
which is what keeps the pack portable — the pack names `scripts`, and
`machine.yaml`, which is yours and not versioned, says where yours is.
`deck paths` lists them; `deck doctor` checks they exist.

### Two repositories that drive each other

`impacts:` is directional, and it answers two questions at once: what must I
revisit, and in what order. Sometimes only the first has an answer. A schema
repository seeds a configuration a scripts repository reads, and the scripts
repository owns the command line the schema's own tooling calls: each side
breaks the other, and neither comes first.

Writing that as two `impacts:` edges is a cycle, which `deck doctor` refuses
because the topological order stops existing. Write it as a coupling instead:

```yaml
repos:
  schema:  { path: schema,  impacts: [gen], couples: [runtime] }
  runtime: { path: runtime, impacts: [] }
```

One side is enough — deck reads it as mutual either way, and declaring it on
both is accepted and means the same. `deck impact runtime` now names `schema`
even though `runtime` declares nothing, listed apart from the ordered chain:

```
coupled with, in no order:
  - schema  state schema   (declared by schema)

  A coupling is mutual and carries no order: revisit these, do not sequence them.
```

`deck order` and the cycle check never read `couples:`, so a coupling can never
make the graph cyclic. `deck mount` does read it — a coupled repository is one
you may have to edit, and mounting it unguided is the failure mount expansion
exists to prevent. So does `deck scope`, which reports a coupling the scope owns
one side of beside the chain it reaches: a boundary drawn across a coupled pair
is a boundary worth knowing about before the work starts. `deck board plan` does
not: a revisit that changes nothing collides with nothing.

---

Two ways teams arrive from here.

| | You have | Go to |
|---|---|---|
| **A** | Code, and nothing prepared for agents | [From nothing](#a--from-nothing) |
| **B** | A pack collection someone already built | [Joining a team](#b--joining-a-team) |

---

## A · From nothing

### 1. Look before deciding

```bash
cd ~/work/projs
deck setup
```

It stops on purpose. It has found your repositories, and the next thing it needs
is a decision only you can make — **where the knowledge will live**.

### 2. Decide, and let it build the shape

```bash
deck setup --packs-root ~/work/ai-packs --create-packs
```

Two flags worth knowing before the first run, because both save an edit
afterwards:

```bash
deck setup --packs-root ~/work/ai-packs --repos api-schema,api-server,web-client
```

**`--repos` curates at the moment it is cheapest.** A `repo` or submodule
checkout brings everything: twenty repositories where six are the work. Writing
all twenty and pruning afterwards means editing a file deck just generated, and
nobody prunes a list they did not choose to make.

**The descriptor shape can come from the pack.** If a pack carries
`templates/workspace/workspace.yaml` — which `deck pack new --from-workspace`
writes — setup uses it instead of the generic template, and says so. That is how
a second person setting up the same kind of workspace gets the same shape without
being told what it is. It is also the one copy of `scopes:` a team shares, so
`deck doctor` reports every way this machine's carve-up has since drifted from
it, and says which of the two it is using.

```
1  What is in this workspace?     4 git repositories found
2  Where will the knowledge live? Creating a pack collection at ~/work/ai-packs
3  Writing the descriptor          _workspaces/<name>/default/workspace.yaml
                                   ~/.deck/workspaces/<name>/machine.yaml · toggles.yaml
4  Linking packs, by name          linked proj1 · proj2 · proj3 · proj4
5  What only you can fill in       the edges · the allowlist
```

One skeleton pack per project, every generated file with its comments intact —
they explain what goes in it and why.

### 3. Write the edges

Which repositories a change forces you to touch. By hand in the descriptor, or
ask for a draft:

```bash
deck propose impacts --repos proj1 proj2 --yes
```

Read-only, capped, and it writes a proposal rather than editing anything. It
cites files and lines and says what it could not verify. It can draft either
kind of edge: an `impacts:` edge where one direction forces the other, and a
`couples:` pair where it can cite both directions separately. A pair it names
both ways is applied as the coupling it is, rather than refused as the cycle two
`impacts:` edges would be. Then:

```bash
deck propose apply impacts-20260904-165321.json --confidence high --yes
```

Two or three repositories at a time. A run over a dozen is expensive and harder
to review — and reviewing it is the point.

### 4. Write the commands

Open `~/work/ai-packs/_workspaces/all/default/config/gates.yaml`. This is where your build,
your deployment and your tests go. deck runs these strings; it supplies the
ladder, the ordering, the evidence and the honesty about what did not run.

```yaml
gates:
  - { id: lint,  from_level: static, per_repo: "${repo.lint}" }
  - { id: build, from_level: build,  per_repo: "make ${repo.build_target}", subagent: true }
```

Start with `static` and `build`. Add `deploy` and `behavior` when you have a
machine to deploy to and a suite to run — until then, `gate_level` simply stops
lower and the report says so.

### 5. Write one decision

In `config/toggles.yaml`, the call your team keeps re-making. Or draft it:

```bash
deck propose toggle "whether a schema change may break clients already deployed" --yes
deck toggle validate --strict
```

### 6. Declare the machines, if any

`targets:` in the descriptor is the set of hosts deck lets anything reach. An
empty list means no deployment and no behaviour gate, which is a fine place to
start.

### 7. Use it

```bash
deck doctor                 # what is missing, and the command that fixes it
deck impact proj1           # what a change reaches, in order
deck toggle list            # what is decided, and what will be asked
deck mount --task X --repos proj1     # give an agent the right context
deck gate run --task X                # verify, and record the evidence
deck save --task X                    # carry what the agent changed back to the pack
deck unmount --task X                 # leave nothing behind
deck bundle --task X --write          # hand a reviewer one page instead of the diff
```

The statement of a task can arrive after the mount, because that is usually
when you know it: `deck mount --task X --brief -` on a task already mounted
writes or replaces its `CLAUDE.local.md` and touches nothing else. A statement
somebody edited by hand is never overwritten, and mounting with no statement at
all says so — it is allowed, and often right at the start, but it must not pass
unremarked or it never gets added.

An agent that works inside a mounted rule will sometimes change it — a
convention it found to be wrong, a procedure it had to correct to get the work
done. That edit is in a working directory nobody versions, so `deck save`
carries it back to the file it came from, in the layer it came from: the
manifest already records which, so there is nothing to guess. A file the agent
wrote that deck never placed goes to the pack that owns where it sits, under its
own name — the `deck-` prefix is a placement mark, not part of the pack.

It is a command you type, and deliberately not part of `deck unmount`. The
`SessionEnd` hook unmounts; a hook that also wrote into a versioned collection
would put unreviewed edits in somebody's `git status` every time a pane closed.
A deleted artifact is reported and never propagated — removing a rule from a
pack is an edit to the pack, not something to infer from a missing working copy.

A mount is *held*, not owned. Whoever mounts takes the first hold, and every
agent session that starts under the same task takes one too — `deck hold` does
that, from the plugin's SessionStart hook, and you never type it. When a session
ends it releases its own hold, and the mount is taken back only once no holder
is left. So closing one pane cannot strip the rules from the pane still working
in the task, and a mount you made yourself at a terminal is released only by
`deck unmount`.

`deck bundle` is the last step because it reads the others. It says which
repositories the change reached and which of them ended up with no commit; which
rung the ladder got to, which rungs it never attempted, and which hold no gate
at all — a rung the ladder climbed to and found empty is a gap in coverage, not
a rung that was reached, and so is one whose gates were every one of them
weighed against this change and found not to apply. The bundle names those two
apart, because nobody declared a gate at the first and somebody did at the
second, and it prints the reason each of those gates gave; which decisions were
in force, where each value came
from and why whoever chose it chose it — or that nobody wrote a reason down;
what is still uncommitted or still placed in a working directory; and, for
every one of those, the file the claim came from. It exits non-zero while
anything is in the way, so a pack that wants merge readiness enforced can
declare a gate that runs it.

---

## B · Joining a team

### 1. Get both

```bash
git clone <your workspace>                    # or `repo sync`
git clone <the ai-packs repository> ~/work/ai-packs
```

### 2. Point deck at them

```bash
cd ~/work/projs
deck setup --packs-root ~/work/ai-packs
```

```
4  Linking packs to repositories, by name
   linked   proj1     ~/work/ai-packs/_repos/proj1
   linked   proj2     ~/work/ai-packs/_repos/group1/proj2
   no pack  proj4     create ~/work/ai-packs/_repos/proj4
   shared   (every repository)   ~/work/ai-packs/_workspaces/all/default
```

Everything the collection covers is linked; anything it does not is named, so a
gap is visible rather than silent.

### Working inside one initiative

A *scope* is a named subset of the registry, and three commands make one without
a text editor:

```bash
deck scope new payments                  # `_workspaces/all/payments/` — any workspace
deck scope new acme/payments             # `_workspaces/acme/payments/` — one of them
deck scope add-repos acme/payments api-schema api-server --title "Payments migration"
deck scope select acme/payments          # until you select another
```

`new` creates the layer's directories in the collection. `add-repos` writes the
block into the versioned descriptor, where it is the team's rather than one
machine's — so review that diff before committing it. A repository the registry
does not declare is refused: a scope narrows what is there, it never adds.

`select` is where the pair lives for this machine, in `~/.deck`, and every
command respects it with no flag on the line:

```bash
deck repos                # the subset
deck packs                # `<name>/default` and `<name>/<scope>` in play
deck scope payments       # what it holds, and what it reaches outside itself
deck scope select none    # back to acting on the whole registry
```

One selection at a time, and `--scope` on a single command still wins over it: a
selection is where you are, a flag is what you are doing right now. Selecting
while a task is mounted is refused rather than silently taking the rules away
from work in progress — unmount first, or pass `--force`.

### 3. Set what is yours alone

```bash
$EDITOR ~/.deck/workspaces/<name>/machine.yaml   # `targets:` — the machines you may reach
deck scopes                      # the initiatives this workspace is carved into
export DECK_TOKEN_JIRA=...       # or ~/.netrc, or a `token_command` in the descriptor
deck board whoami                # which account each source would act as
deck doctor
```

`whoami` answers for a file board too, and there the answer is not an account.
A board file is committed, so a claim in one is recorded under the identity that
repository publishes under — git's `user.name`, read where the file lives, never
`$USER`. Set `DECK_USER` if the name you take work under is not the one your git
configuration carries; `deck board claim <id> <name>` overrides both, and a
board with no identity to read refuses the claim rather than guessing at one.

If doctor passes, you have the same edges, the same decisions and the same
ladder as everyone else. That is the point: the same task asked by two people
produces the same chain of work and the same questions.

---

## What is ready

| Ready and tested | What it does |
|---|---|
| `setup` · `doctor` · `init` · `import` | Getting a workspace usable, and saying what is missing |
| `impact` · `order` · `repos` · `path` · `paths` · `get` | The map, and what a change reaches |
| `scopes` · `scope` · `--scope` | Named subsets of the registry, each with its own board and posture |
| `packs` | The layers in play, their merge order, and every overlaid entry |
| `toggle` (list, explain, set, profile, ask-plan, validate) | Decisions, and turning pending ones into questions |
| `pack` (new, list, validate, review, sources, add, update) | Creating packs, vendoring with provenance, re-checking what was vendored against its source, and saying what has stopped earning its context |
| `mount` · `unmount` · `mounts` | Placing context and taking it back, leaving nothing behind |
| `gate` (list, run, report) | The ladder, and evidence that survives the session |
| `board` (list, show, plan, why, claim, done, new, template, ask-plan, whoami) | The kanban, from a file or from Jira, GitLab, GitHub, Gerrit — and every decision it is waiting on |
| `bundle` | Merge readiness in one page: the change set and where the chain stopped, the rungs reached and the ones that were not, the decisions in force with where each came from and the reason its chooser recorded, what is still uncommitted or still placed, and the file behind every claim |
| `metrics` (list, show) | The number behind a passing gate, and which way it has moved across runs |
| `cost` | Tokens per model, exact, with an estimate in dollars |
| `propose` (impacts, toggle, pack, apply) | Headless Claude, read-only and capped, proposing never applying — and a pack draft that cannot explain a finding raises a consultation rather than filing it as a decision |
| `ask` (new, list, show, resolve) | The question the catalog has no entry for, recorded and outliving the session |
| `console` · `ui` · `statusline` | Watching and steering from beside or inside a session |

All of this is covered against a synthetic workspace built in a temp directory:
`./ci/smoke.sh`, which prints its own total.

| Written, not yet proven | |
|---|---|
| Trackers other than GitHub | GitHub is exercised against the real service. Jira, GitLab and Gerrit are exercised only against the local stand-in — which is now written from what those APIs document rather than from what deck sends, so it refuses a path they do not serve, but no request in this suite has ever left the machine |
| GitLab, specifically | Every request shape deck sends now runs against the stand-in: `board list` through `GET /projects/:id/issues`, `claim` through `PUT /projects/:id/issues/:iid`, `create` through `POST /projects/:id/issues`. The last of those had never run against anything — the stand-in answered that route with GitHub's body, so the `web_url` deck reads was never there — and any path under `/api/v4/projects/` used to answer an issue update 200. Both are fixed and both are checked. Two API questions are settled in the reader: it reads `assignees` and falls back to the deprecated `assignee`, and a read cut short by `X-Next-Page` is reported as partial rather than followed, as for GitHub and Gerrit. What no local run can settle, and what has therefore not been settled: whether the token scopes deck asks for are the ones an instance requires; whether an unauthenticated write is refused (the stand-in checks a token on the read route and on neither write route); whether a self-hosted instance behind a path prefix resolves; and whether the error bodies deck surfaces are legible when an instance refuses something |
| `propose pack` at scale | Run against one real repository, once. The drafts were good and the cost was $1.14 |

| Proven end to end | |
|---|---|
| `/deck:board` workflow | Run twice on a five-task board: eleven agents, four groups, every task committed and green. Not run against a workspace anyone depends on |
| GitHub as the board | deck's own board is GitHub Issues, read through `type: github` with the token resolved by `token_command`. `list`, `plan`, `show`, `claim` and `done` all run against the live service. The crossing cost four findings, and they are one shape — it loses something and says nothing: `doctor` reported a healthy tracker as a missing file; `claim` reported an assignment GitHub had silently discarded, because the write path was the one place that took a 2xx for an answer without reading the body; a task read from a tracker carries no acceptance criteria, so `board done` skips a guard a file board makes it honour; and `in-progress` has nowhere to go in a two-state tracker, so a task somebody holds still listed as free. All four are fixed, the last two at the floor the findings named: `list` and `plan` show the assignee the tracker does return, `done` says when it closes a task whose source carries no criteria, and what a tracker cannot carry is written down in `PACKS.md`. Deriving `in-progress` from an assignee, and reading criteria out of an issue body, are still open |

| Designed, not built | |
|---|---|
| **Release and distribution** | Versioning and packaging are barely modelled |
| **Memory across tasks** | Everything is task-scoped. Only the metric series crosses tasks, and it holds numbers, not lessons |
| Dynamic packs | Task-scoped artifacts an agent writes and a human promotes |
| RAG / CAG | Declaring which knowledge source applies to which repository |

---

## When something is unclear

```bash
deck doctor                  # first thing to reach for
deck toggle explain <id>     # what a decision means, where its value came from,
                             #   and why whoever chose it chose it — `--why` on
                             #   `deck toggle set` is what puts that sentence there
deck toggle unset <id> --at <layer>   # take a recorded value back; the wider
                             #   layer `explain` would have named takes over
./docs/tour.sh               # fifty seconds, end to end, in a temp directory
```

`deck doctor` never fixes anything on its own, and every problem it reports comes
with the command or the edit that resolves it.

---

## Where things live

| Path | Belongs to | Versioned |
|---|---|---|
| `ai-packs/<repo>/` | the team | **yes** — the knowledge |
| `~/.deck/workspaces/<name>/machine.yaml` | this machine | no — paths, hosts, tokens |
| `~/.deck/workspaces/<name>/toggles.yaml` | this machine | no — your own posture |
| `.deck/gates/` · `mounts/` · `proposals/` · `bundles/` | one task | no — evidence and state |

Nothing deck writes belongs in a product repository, and nothing it places there
survives an unmount.
