# Contributing

deck is a control plane for coding agents working across repositories. Before
anything else, two things worth knowing about how it is built, because both will
shape whatever you send:

- **[FOUNDATIONS.md](FOUNDATIONS.md)** — which engineering concerns enter deck,
  through which mechanism, who owns the content, and what deck will never own.
  It opens with a glossary.
- **[DESIGN.md](DESIGN.md) §3** — what deck does *not* build. Claude Code already
  ships agent orchestration, worktrees, instruction loading, the question box,
  plan mode and code review. A change that reimplements any of them is refused
  however well it is written.

## Getting set up

```bash
git clone https://github.com/devfilipe/deck.git
# The pack collection this repository is verified against. A sibling, because
# that is where `seed/workspace.yaml` points `packs_root`.
git clone https://github.com/devfilipe/deck-ai-packs.git
cd deck
# deck develops itself with no collection, so its descriptor stays under the
# root. A workspace set up with `--packs-root` keeps its descriptor in the
# collection and its machine state under `~/.deck/workspaces/<name>/`.
cp seed/workspace.yaml .deck/workspace.yaml
cp seed/toggles.yaml   .deck/toggles.yaml
./plugins/deck/bin/deck doctor
```

Python 3.10+ and PyYAML. `ruff` and `pytest` to work on it; `tmux` for `deck ui`.

PyYAML stays the only requirement, and one place pays for that. Writing a YAML
file deck manages goes through `safe_dump`, which does not round-trip comments —
`ruamel.yaml` would, and is one more thing every install has to carry for a
behaviour in a handful of files. So `dump_yaml` re-attaches them by hand, keyed
on the line below each run. The limit is real and worth knowing: a comment
written on the same line as a value is not a run of its own and does not
survive, and two identical lines in one file resolve to the first.

**Work on a copy when agents will edit this tree.** `~/.local/bin/deck` is a
symlink into your checkout, so an agent editing `plugins/deck/deck/` changes the
binary it is running — including the gates meant to catch the break.
`deck doctor` warns about this; `_workspaces/all/default/rules/self-hosting.md` in [`deck-ai-packs`](https://github.com/devfilipe/deck-ai-packs) gives
the clone commands.

## Before you open a pull request

deck verifies itself with its own mechanism:

```bash
./plugins/deck/bin/deck gate run --task <your-branch>
```

Six gates, in ladder order: `commit-shape` (a Conventional subject on every
commit ahead of main, and one `Closes #N` somewhere on the branch when the
branch name names an issue) ·
`ruff` · `catalog` (the toggle wording) · `docs`
(every command is named in the documentation, every path they point at exists,
and the check total they state is the one the suite has) · `smoke` (the suite,
~973 checks against synthetic workspaces in temporary directories) · `tour` (the
whole arc, in one workspace, in about two seconds). All six green, or say in the
pull request which did not run and why.

### Why CI runs the same commands rather than the ladder

`.github/workflows/ci.yml` lists the same five, step by step, instead of calling
`deck gate run` once. That is a second copy of what the pack already declares,
and the duplication was decided rather than inherited:

- **CI is the outside check on the engine.** `deck gate run` decides which gates
  apply, and the pull requests that most need catching are the ones changing
  that decision. With no pack resolved it used to print `0 gate(s) passed` and
  exit 0 — a green run over nothing. It now refuses, but a workflow that asks
  the engine under test whether the engine under test was verified is answering
  the wrong question however carefully it is written.
- **The ladder puts `docs` before `smoke`,** and `docs --counts` runs the suite
  to learn the real total. One `deck gate run` therefore runs the suite twice.
  CI runs it once and hands the log to the count check with `--suite-log`.
- **A job with one step reports one name.** Five steps put the failing gate in
  the GitHub UI; one step puts it in a log somebody has to open.

Two lists drift — this pair already had, with `docs` declared in the pack and
run nowhere in CI. So each workflow step that is a gate carries a `# gate: <id>`
marker, and the suite compares the markers against the ids in
`_workspaces/all/default/config/gates.yaml` in [`deck-ai-packs`](https://github.com/devfilipe/deck-ai-packs). A gate added to one and not the other
fails the suite. That check is what pays for the duplication; without it the
right answer would be the single call.

## What a good change looks like here

**Sort what you are adding by kind first.** Everything is one of four things, and
getting it wrong is most of the cost:

| Kind | Where it goes | Costs |
|---|---|---|
| fact about a workspace | the descriptor | nothing |
| invariant | a pack's `rules/` | context on every matching file read |
| decision with more than one defensible answer | a pack's `toggles/` | one question, once |
| something a machine can check | a `gate` | nothing until it runs |

**If a machine can check it, it is a gate — never a rule.** Telling an agent
about formatting is paying tokens forever for what a formatter settles in
milliseconds.

**A defect fixed comes with the check that would have caught it,** in the same
commit. A commit that says a defect is fixed and adds no check is not finished.
Several fixes in this repository's history were half-fixes precisely because the
check only asserted the words existed somewhere in the file.

**A user-visible change updates the documents in the same commit.** The `docs`
gate enforces the half that is a fact — every command is named somewhere. The
rest is yours: a count is measured rather than recalled, a claim is exercised
before it is written, and a changed behaviour is hunted in every document rather
than the one you are editing.

**Never state a number you did not measure.** No "typically three repositories",
no invented percentage. If it is not counted, from the code or from a run, it
does not go in.

**Comments carry the reason, not the restatement.** A comment saying what the
next line does is noise. Write what a reader cannot recover: why this and not the
obvious alternative, what broke when it was done the other way.

## The engine and the packs

**Engine** (`plugins/deck/deck/`) knows about workspaces, graphs, toggles, gates
and packs, and nothing about any domain. It has never heard of `bitbake`, `npm`
or `helm`. **A domain word appearing in engine code is a bug.**

**Packs** are data: commands, edges, decisions, rules. When something has to be
added, ask which half it belongs to. The answer is the pack more often than it
feels.

## Writing the suite

`ci/smoke.sh` builds synthetic workspaces in temporary directories, so it runs
anywhere and touches nothing you own. It holds what every check shares — the
counters, the helpers, the workspace, the one total — and then sources
`ci/checks/*.sh` in order, one file per subject.

**A new check goes in the file for its subject, not in `ci/smoke.sh`.** That is
the whole point of the split: two tasks in different subjects stopped editing
one file and stopped conflicting over it. A new subject is a new file, and the
two-digit prefixes step by two so one drops between two existing ones without
renaming either. Nothing lists them — the runner globs the directory, so writing
the file is the whole step.

They are sourced into the same shell, in order, which is load-bearing: the
synthetic workspace is built once and added to as the suite runs, so a file sees
whatever the files before it left behind.

```bash
check      "<description>" "<expected substring>" "$DECK" <args…>   # must exit 0
check_fail "<description>"                        "$DECK" <args…>   # must exit non-zero
```

Four traps, each of which has cost time here:

- **Never put a deck command in a pipeline.** `set -o pipefail` carries deck's
  non-zero exit even when the grep matched. Capture the output first.
- **Never wrap checks in a subshell.** `pass`/`fail` increment inside it and are
  lost, so a section reports results and changes the totals by none.
- **Assert on behaviour, not on the file.** A check that greps the source for a
  string passes on a half-fix, and has.
- **Never let a background process fail quietly.** `something &` throws the exit
  status away, so a stand-in that could not start looks exactly like one that
  did, and the first sign of it is a refused connection in a check about
  something else entirely. Have the process say it is ready — the tracker
  stand-in prints the port it was given — and fail the launch, naming what the
  process said, when it says nothing.

## Reporting things

- **A defect**: [bug report](../../issues/new?template=bug.yml). What you ran,
  what happened, what you expected. `deck doctor` output helps more than anything
  else.
- **A gap**: [feature request](../../issues/new?template=feature.yml). What you
  were trying to do, and what deck made you do instead.
- **A security issue**: [SECURITY.md](SECURITY.md) — not a public issue.

## Licence

MIT. By contributing you agree your contribution is licensed under it.
