"""Pack commands: create one, list what is in play, check that it holds together.

A pack is where a team's operating knowledge lives. It is also, deliberately, a
Claude Code plugin: the same directory carries `skills/`, `agents/`, `hooks/`
and a `.claude-plugin/plugin.json` that Claude Code loads directly, plus a
`config/` that only deck reads. One artifact, two readers, no duplication.

`deck pack new` writes the whole skeleton with its comments intact, because an
empty file teaches nobody anything and a pack nobody can read is a pack nobody
maintains.
"""

from __future__ import annotations

import fnmatch
import json
import os
import re
import textwrap
import time
from pathlib import Path

from .config import STATE_DIR, core_root, dump_yaml, load_yaml, norm, run, slug, state_root
from .gates import invokes
from .workspace import Workspace, board_identity, collection_home, person_fields

SKELETON = [
    ".claude-plugin",
    "config",
    "rules",
    "skills",
    "templates/workspace",
]

# The one file every form of `pack new` exists to write. Scaffolding a new pack
# writes the rest as well, because there is nothing there to lose; re-seeding an
# existing one writes this and nothing else.
SEEDED_FILE = "templates/workspace/workspace.yaml"


def _seeded_scopes(scopes: dict | None) -> tuple[dict, list[str]]:
    """A scope's board, with everything naming a person taken out.

    The allowlist above applies the same question per repository — would this
    value still be true on the next person's machine — and `scopes:` was copied
    whole, so a tracker `backlog:` carried the account it authenticates as into
    a file a team versions. Once, into a real template, before anyone noticed.

    Returns what was dropped as well, because the seeded file already tells a
    reader which repository fields did not travel, and a field removed in
    silence is one somebody puts back.
    """
    out: dict = {}
    dropped: list[str] = []
    for name, scope in (scopes or {}).items():
        scope = dict(scope or {})
        sources = scope.get("backlog")
        if sources:
            kept = []
            for source in sources:
                if isinstance(source, dict):
                    dropped += [f"`{f}`" for f in person_fields(source)]
                    kept.append(board_identity(source))
                else:
                    # Not a mapping, so nothing to filter and nothing to claim
                    # about it. Carried through rather than dropped: refusing to
                    # understand a source is not a reason to delete it.
                    kept.append(source)
            scope["backlog"] = kept
        out[name] = scope
    return out, list(dict.fromkeys(dropped))


def _holds(path: Path) -> str:
    """What a config file a re-seed left alone is carrying, in one phrase.

    So the report can distinguish a pack that was protected from one that was
    blank anyway. Read rather than assumed: a `gates.yaml` of comments and an
    empty list is not the same file as one holding somebody's ladder, and only
    counting tells them apart.
    """
    if path.suffix != ".yaml":
        # A rule or a skill is prose with frontmatter, and `load_yaml` dies on
        # the second `---` rather than shrugging. Nothing useful to count there
        # anyway: the file being kept is the whole statement.
        return ""
    data = load_yaml(path)
    for key, word in (("gates", "gate"), ("toggles", "toggle"), ("rules", "mounted rule"), ("markers", "marker")):
        items = data.get(key)
        if items:
            return f"{len(items)} {word}{'s' if len(items) != 1 else ''}"
    return "nothing declared"


# --------------------------------------------------------------- what a seed carries
#
# `deck pack new --from-workspace` turns one person's working registry into the
# descriptor template a team shares. These two allowlists decide what survives
# that trip, and the rule behind both is one question:
#
#     WOULD THIS VALUE STILL BE TRUE ON THE NEXT PERSON'S MACHINE?
#
# If yes it is the team's knowledge and it travels. If no it is a fact about
# this checkout, this host or this afternoon, and a template that carries it
# hands the next person something they have to notice and undo.
#
# `path` is the case the rule has to survive, because it looks like the most
# machine-specific field in the list and is not — usually. The one per-machine
# fact a descriptor holds is where the workspace root is, and a repository
# entry below the root does not hold it: `deck init` resolves the root, and
# `path:` is written relative to it. `services/api-server` is the layout
# everyone clones, so `path` travels for exactly the same reason `impacts:`
# does.
#
# A repository is allowed to sit OUTSIDE the root too — the workspace template
# says so — and there `path` is not layout, it is this checkout's home
# directory, absolute and true of nobody else's machine. `_seeded_repos` below
# drops `path` for exactly those entries and says so in the seeded file, the
# same way `_seeded_scopes` already does for a scope's `backlog`.
#
# What the rule keeps out is what a checkout happens to hold right now.
# `revision` and `remote` are written by `deck import` from whatever manifest
# this machine has, and refreshed on the next import (see `importers.merge`);
# freezing them into a template pins a team to one afternoon's manifest.
#
# An allowlist rather than a denylist, because a registry entry accepts any key
# — `${repo.<field>}` in a gate command resolves against the whole entry, so
# people and importers both add their own — and the person reading a seeded
# template did not write the registry it came from. A key nobody named does not
# travel silently into a file a team reviews.
#
# Adding a field here: ask the question above, and add a check for it to the
# "what a pack seeded from a workspace carries" group in `ci/smoke.sh`, which
# asserts one field per line of this tuple. Two fields have been lost by
# omission already — `couples`, and `downstream`, which meant every downstream
# repository came out of a seed looking like an ordinary build node.
SEEDED_REPO_FIELDS = (
    "path",  # the layout below the root, which is the root's job to differ, not this one's
    "role",  # what the repository is for
    "remote_id",  # the upstream every clone of it has
    "build_target",  # the name the pack's build command receives
    "lint",  # the command the static gate runs here
    "deploy_path",  # where a deployment lands it
    "services",  # what has to be restarted once it has
    "downstream",  # produces no artifact: changes order(), build_targets() and gate scope
    "impacts",  # directional edge, ordered and transitive
    "couples",  # symmetric edge, unordered and not transitive
)

# The same question, asked of the descriptor's own fields. `packs_root`,
# `paths` and `targets` all fail it — a packs checkout, a tools directory and a
# lab host are three different people's answers — and `targets` is emptied
# rather than dropped, so the seeded file still shows a team where the
# allowlist goes.
#
# `scopes` passes it, and was missing once: how a product is carved into
# initiatives is the team's answer, not one machine's, and the template is the
# only place it can be versioned. Left out, the one documented route to making
# a scope the team's dropped it in silence, and `deck doctor` could then report
# a scope as local to this machine straight after the command meant to publish
# it ran.
#
# `sources` and `container` sat here too, and neither has ever had a reader:
# `sources` as a workspace-level key is not the same thing `deck pack sources`
# reads (that is `config/sources.yaml` inside a pack) or the `sources` section
# of a bundle; `container` appears nowhere else in the repository at all. An
# allowlist that copies a key nobody reads hands a team two lines in a
# reviewed file that nothing can explain, which is the same failure
# SEEDED_REPO_FIELDS exists to prevent, from the other direction — so both were
# removed here rather than given a reader they never had.
#
# Adding a field here: ask the question above, and add a check for it to the
# "what a pack seeded from a workspace carries" group in `ci/smoke.sh` — one
# per field, the way SEEDED_REPO_FIELDS already is. The enforcement used to
# stop at this tuple's boundary, a bare list with no check of its own while the
# allowlist above it had one per field; that is what let `sources` and
# `container` sit here unread and let `scopes` go missing without a failing
# check to catch it.
SEEDED_WORKSPACE_FIELDS = (
    "requires_files",  # what the workspace needs to be usable — `deck doctor` reads it
    "scopes",  # how the product is carved into initiatives, the team's answer, not one machine's
    # which names carry instructions here — the team's answer too, and the only
    # place it can be reviewed like the instructions it names
    "instruction_files",
)


def _seeded_repos(repos: dict) -> tuple[dict, list[str]]:
    """The registry's repositories, filtered to `SEEDED_REPO_FIELDS`, with an
    out-of-tree `path` held out.

    `path` normally travels because it is layout below the workspace root —
    the same on anyone's checkout. A repository is also allowed to sit outside
    the root, and there `path` is absolute: this machine's home directory, not
    a fact the next person's clone shares. That one is dropped rather than
    copied; a path below the root is untouched.

    Returns the repositories that lost their path, because the seeded file
    already tells a reader which fields did not travel, and a field removed in
    silence is one somebody puts back.
    """
    out: dict = {}
    absolute: list[str] = []
    for name, entry in (repos or {}).items():
        filtered = {k: v for k, v in entry.items() if k in SEEDED_REPO_FIELDS}
        path = filtered.get("path")
        if path and Path(str(path)).is_absolute():
            del filtered["path"]
            absolute.append(name)
        out[name] = filtered
    return out, absolute


SKILL_EXAMPLE = """---
name: example-procedure
description: >
  One or two sentences saying WHEN this applies, in the words someone would use
  asking for it. This text is loaded in every session, so it is the only part
  that costs context whether or not the skill is ever used — make it earn that.
when_to_use: >
  "add a new backend", "how do we wire a subscriber", "the usual way to do X".
---

# Example procedure — delete this file once you have your own

A skill is a PROCEDURE: steps someone follows, loaded when Claude judges it
relevant or when you invoke it. A rule is a CONSTRAINT: loaded whenever a
matching file is read.

Choosing between the four homes, in order of what costs least:

| Put it in | When |
|---|---|
| a **gate** | a machine can check it. Formatting, lint, coverage, build, tests |
| a **toggle** | there is more than one defensible answer and the team keeps re-deciding |
| a **rule** | it constrains an area of the code and has a consequence worth stating |
| a **skill** | it is a sequence of steps, and only pays for itself when followed |

If a formatter can fix it, it is never a rule and never a skill. That is the
commonest way a pack wastes an agent's context.

## Steps

1. What to read first, and why that one.
2. The change itself.
3. What proves it worked — name the gate, do not describe the check.

## What this costs

Every skill's `description` is loaded in every session. `claude plugin details
<pack>` prints the total. A pack whose always-on surface grows without its
delivered value growing is a pack getting worse.
"""


AGENTS_NOTE = """# agents/ — subagent definitions

Empty on purpose. Add one only when a task genuinely needs a *different* set of
tools or a narrower brief than the main session — a heavy build whose output
should stay out of the main context, a reviewer that must not have write access.

An agent is the most expensive artifact in a pack: it costs a whole context of
its own every time it fires. A skill that the main session follows is cheaper
and is usually enough.

Claude Code already spawns, isolates and parallelises agents. A pack supplies
the brief; it never supplies an orchestrator.
"""


def _plugin_json(name: str, description: str) -> str:
    return (
        json.dumps(
            {
                "name": name,
                "description": description,
                "version": "0.1.0",
                "keywords": ["deck", "pack"],
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )


def _detect(name: str, markers: list[str], tools: list[str], scope: str | None = None) -> str:
    marker_lines = "\n".join(f"  - {m}" for m in markers) or "  # - .my-workspace-marker"
    tool_lines = "\n".join(f"  - {t}" for t in tools) or "  - git"
    binding = (
        f"""
# The initiative this pack belongs to. It reaches an agent only under
# `deck --scope {scope}`, and merges after the workspace-wide packs and before
# any repository's own: an initiative is narrower than the workspace and wider
# than one codebase. Outside that scope nothing here is loaded — `deck packs`
# still lists the pack, so the knowledge stays findable rather than invisible.
scope: {scope}
"""
        if scope
        else ""
    )
    return f"""# How deck recognises a {name} workspace, and what it needs installed.
#
# Markers are checked before any descriptor is read — root resolution has to
# happen first — so they cannot live in the descriptor. Name one or two files
# that only this kind of workspace has.
markers:
{marker_lines}

# `deck doctor` checks these are on PATH. Mark the optional ones so a missing
# one is a warning rather than a problem.
prerequisites:
{tool_lines}

# Packs this one builds on, by name. They merge BEFORE it, so anything this
# pack marks `overrides: true` wins over theirs — which is the whole reason to
# declare a requirement rather than trust the order to come out right.
# `deck packs` shows the resulting order; `deck doctor` reports one that is
# missing or circular.
requires: []
# requires:
#   - yocto-base
{binding}"""


TOGGLES = """# Decisions this domain keeps re-making.
#
# The deck core ships the universal ones — how far to verify, how to deploy,
# where the commit stops. This file adds the decisions that only make sense
# here, and relabels core ones in this domain's vocabulary.
#
# Two mechanisms:
#   NEW ENTRY   declared in the catalog format, like any core toggle.
#   OVERRIDE    repeat a core `id` with `overrides: true`. Without that flag the
#               merge is refused, so nothing shadows a core decision by accident.
#
# Authoring rules, enforced by `deck toggle validate --strict`:
#   - `question.header` at most 12 characters
#   - at most 4 askable values (use `askable_values` to choose which)
#   - quote `off`, `on`, `yes`, `no` — YAML turns them into booleans
#   - a toggle in the `security` group may not default to `ask`
#
# A good entry answers four things: what it is, why it exists, what each value
# costs you, and how the question should be put to a person.

version: 1

# Entries go under the key below, indented as the example is. Uncomment it and
# edit, or delete it and write your own.
toggles:

# Example — delete once you have your own:
#
#   - id: api_compat
#     group: quality
#     title: API compatibility
#     summary: How far this change may alter the published contract.
#     type: enum
#     values: [strict, additive, breaking]
#     default: strict
#     stage: [plan]
#     applies_to: ["**/openapi.yaml"]
#     risk: high
#     rationale: >
#       The schema is a contract with every client already deployed. Declaring
#       the intent up front is cheaper than discovering it in staging.
#     impact:
#       strict: Additive only. Nothing removed, renamed or narrowed.
#       additive: New fields land; old ones are marked obsolete but stay.
#       breaking: Requires a migration note and a version bump.
#     question:
#       header: API compat
#       text: May this change alter the published contract?
#       options:
#         - { value: strict,   label: Additive only, description: "Clients in the field keep working." }
#         - { value: breaking, label: May break,     description: "Needs a migration note." }
"""

GATES = """# The verification ladder for this domain.
#
# The engine knows the shape — which rungs apply, over which repositories, in
# what order, and what counts as evidence. It knows nothing about your build
# system. Every command below is a string this pack wrote.
#
# Rungs come from the `gate_level` toggle. To insert one, extend that toggle in
# toggles.yaml with `overrides: true` rather than touching the engine.
#
# Per gate:
#   from_level   the rung at which it starts running (omitted: static)
#   per_repo     a command run in each repository in the change
#   once         a command run once, at the workspace root
#   only_repos   restrict it to named repositories
#   when         a condition over other toggles
#   subagent     a hint that the output is large and belongs in a subagent
#
# Variables: ${repo.<field>} ${toggle.<id>} ${workspace.<dotted>} ${target.<field>}
# An unresolved variable blocks the gate rather than running a broken command.

version: 1

# Entries go under the key below, indented as the example is. Uncomment it and
# edit, or delete it and write your own.
gates:

# Example — delete once you have your own:
#
#   - id: static
#     title: Lint
#     from_level: static
#     per_repo: "${repo.lint}"
#     timeout: 300
#
#   - id: build
#     title: Build
#     from_level: build
#     per_repo: "make ${repo.build_target}"
#     subagent: true
#
# `${repo.impacts}` and `${repo.couples}` are the declared graph, not only a
# build variable — a gate can compare that declaration against something this
# domain can observe, and fail when they disagree. The engine does not know
# what a dependency is here; your tool does (`import-linter`, `go list`,
# `madge`, `bitbake -g`, or a grep over includes). Example:
#
#   - id: graph-check
#     title: declared impact confirmed by an observed dependency
#     from_level: static
#     per_repo: >
#       for dep in your-real-dependency-tool --for "${repo.name}"; do
#         case "${repo.impacts}" in *"$dep"*) ;; *)
#           echo "observed dependency on $dep, but nothing declares impacts: [$dep]" >&2; exit 1 ;;
#         esac
#       done
"""

MOUNT = """# The one thing this pack places that is not a directory.
#
# `rules/`, `skills/` and `agents/` are walked and copied as they are; a
# `_workspaces/<name>/<scope>/` layer lands once at the workspace root, and a
# `_repos/<name>/` pack lands in that repository and no sibling. Copying is the
# mechanism, not a last resort: the collection is versioned somewhere else, so a
# working directory carries a copy and `deck save` carries the edits back.
#
# Everything placed is recorded in a manifest and removed on unmount. deck never
# deletes what it did not place, and never deletes what somebody edited.

# The plugin id Claude Code should enable in a working directory.
# plugin: PACK_NAME@MARKETPLACE

# Where that plugin comes from, if it is not already known on the machine.
# marketplace:
#   name: MARKETPLACE
#   source: { source: url, url: "https://example.com/packs.git" }

# Nothing about rules here. Whatever sits in this pack's `rules/`, `skills/` and
# `agents/` is placed, and a directory that had to agree with a list in this file
# was two statements of one fact — with one of them going stale the first time
# somebody added a rule and forgot the entry.
"""

PROFILES = """# Named postures. A profile is the base layer; anything set in
# .deck/toggles.yaml, in the environment, or on the task still wins over it.
#
# Switching profile is how a team changes stance in one phrase — "today is a
# hotfix day" — without editing twenty lines of configuration.

version: 1

# Entries go under the key below, indented as the example is. Uncomment it and
# edit, or delete it and write your own.
profiles:

# Example — delete once you have your own:
#
#   release:
#     title: Release candidate
#     summary: >
#       What runs before cutting a release: the whole ladder, the full suite,
#       and the contract treated as frozen.
#     values:
#       gate_level: behavior
#       test_depth: full
#       doc_sync: required
"""

RULE_EXAMPLE = """---
paths:
  - "**/*.example"
---

# A rule, and what makes one worth writing

A rule loads only when Claude reads a file matching `paths:`, so it costs
nothing the rest of the time. That is what makes it the right home for
knowledge that applies to one area of the code.

Write about **consequence**, not description. "Handlers validate at the edge;
nothing below re-checks shapes" earns its place. "This directory contains
handlers" does not — Claude can see that.

Point at the decision rather than restating it: "check `api_compat` before
changing the schema" is better than repeating what each value means, because
the toggle already says that and will not drift from itself.
"""


def _readme(name: str) -> str:
    return f"""# {name}

A [deck](https://github.com/devfilipe/deck) pack: the operating knowledge for
this workspace, in a form an agent can execute against and a reviewer can check.

It is also a Claude Code plugin. The same directory carries `skills/`, and can
carry `agents/` and `hooks/`, which Claude Code loads directly.

```
config/detect.yaml     how deck recognises this workspace, and what it needs
config/toggles.yaml    the decisions this domain keeps re-making
config/gates.yaml      the verification ladder, and the commands behind it
config/mount.yaml      what gets placed in a repository, and how
config/profiles.yaml   named postures
rules/                 `paths:`-scoped rules, copied in on mount
skills/                procedures, loaded on demand by description
templates/workspace/   a filled-in descriptor for this shape of workspace
```

## Use it

```bash
export DECK_PACKS=$PWD          # or list it under `packs:` in the descriptor
deck doctor
deck toggle list
```

## Keep it honest

```bash
deck pack validate .            # structure, catalog, and the plugin manifest
```

Every entry should say why it exists and what each value costs. A catalog people
cannot read is a catalog people start ignoring.
"""


def cmd_pack_new(ws: Workspace, args) -> int:
    name = args.name
    target = Path(args.dir) if args.dir else collection_home(Path.cwd(), name)
    if target.exists() and any(target.iterdir()) and not args.force:
        print(f"deck: {target} already exists and is not empty (use --force)")
        return 1

    bind = norm(getattr(args, "bind_scope", None) or "").strip() or None
    # Refused rather than written, and refused before anything is created: a
    # pack bound to a name this workspace does not declare loads for nobody, and
    # a misspelling would produce exactly that with nothing to notice.
    if bind and ws.data and bind not in ws.scopes:
        print(f"deck: `{bind}` is not a declared scope (declared: {', '.join(ws.scopes) or 'none'})")
        print(f"  Declare it under `scopes:` in {STATE_DIR}/workspace.yaml first. See: deck scopes")
        return 1

    markers, tools = [], ["git"]
    if args.from_workspace:
        if not ws.data:
            print("deck: --from-workspace needs a descriptor; run `deck init` first")
            return 1
        markers = [str(f) for f in (ws.data.get("requires_files") or [])][:2]
        for pack in ws.all_packs():
            detect = load_yaml(pack / "config" / "detect.yaml")
            markers += [str(m) for m in (detect.get("markers") or [])]
        markers = list(dict.fromkeys(markers))

    # Read before the scaffold is created, or `config/` always exists by the
    # time it is asked about and every pack looks like one that was already here.
    existing_pack = (target / "config").is_dir()

    for folder in SKELETON:
        (target / folder).mkdir(parents=True, exist_ok=True)

    description = args.description or f"deck pack for {name}"
    files = {
        ".claude-plugin/plugin.json": _plugin_json(name, description),
        "config/detect.yaml": _detect(name, markers, tools, bind),
        "config/toggles.yaml": TOGGLES,
        "config/gates.yaml": GATES,
        "config/mount.yaml": MOUNT.replace("PACK_NAME", name),
        "config/profiles.yaml": PROFILES,
        "README.md": _readme(name),
    }

    if bind:
        # A scope pack's template carries ONE initiative and never the registry.
        # The registry is a description of a thing that exists — one answer
        # serves everybody, and `workspace_template()` skips this file for that
        # reason. What lives here is a decision about how to divide attention,
        # and several of those can be true at once, which is why deck merges
        # them across packs instead of letting the most specific one win.
        block = {bind: (ws.scopes.get(bind) or {})} if (args.from_workspace and ws.data) else {}
        import yaml as _yaml

        files["templates/workspace/workspace.yaml"] = (
            f"# The initiative `{bind}`, versioned where its owners can review it.\n"
            "#\n"
            "# No `repos:` block, deliberately. The registry — which repositories exist\n"
            "# and how a change propagates between them — is one answer for everybody and\n"
            "# belongs in the workspace pack's template. This file holds one initiative's\n"
            "# subset, its board and its title; deck merges the scopes every pack ships,\n"
            "# and refuses a name two packs both claim rather than ranking them.\n"
            "#\n"
            "# Copy the block into `scopes:` in .deck/workspace.yaml to work in it:\n"
            "#   deck --scope "
            + bind
            + " board plan\n\n"
            + _yaml.safe_dump(
                {"scopes": block or {bind: {"title": bind, "repos": []}}}, allow_unicode=True, sort_keys=False
            )
        )
    elif args.from_workspace and ws.data:
        # Seed the descriptor template from what this machine already has, with
        # the machine-specific parts stripped: a template is a shape, not a copy
        # of somebody's paths and hosts. Both allowlists, and the one rule that
        # decides what is in them, are at the top of this file.
        seed = {k: v for k, v in ws.data.items() if k in SEEDED_WORKSPACE_FIELDS}
        seed["repos"], absolute_paths = _seeded_repos(ws.repos)
        seed["targets"] = []
        seed["scopes"], dropped = _seeded_scopes(seed.get("scopes"))
        import yaml as _yaml

        notes = []
        if absolute_paths:
            notes.append(
                textwrap.fill(
                    "A repository outside the workspace root had an absolute `path` — this "
                    "machine's home directory, not layout the next clone shares — dropped for: "
                    f"{', '.join(absolute_paths)}. Give it a path of your own.",
                    width=76,
                    initial_indent="# ",
                    subsequent_indent="# ",
                )
            )
        if dropped:
            notes.append(
                textwrap.fill(
                    "A scope's board kept what says which board it is, and dropped what says "
                    f"who is asking for it: {', '.join(dropped)}. Everybody authenticates as "
                    "themselves, so that is filled in per machine and never shared.",
                    width=76,
                    initial_indent="# ",
                    subsequent_indent="# ",
                )
            )

        files["templates/workspace/workspace.yaml"] = (
            "# Seeded by `deck pack new --from-workspace`.\n"
            "# Targets were left empty on purpose: an allowlist is a decision, not a copy.\n"
            "# Each repository kept the fields that stay true on anyone's machine, and\n"
            "# nothing that described only this checkout:\n"
            + textwrap.fill(", ".join(SEEDED_REPO_FIELDS), width=76, initial_indent="#   ", subsequent_indent="#   ")
            + "".join("\n" + note for note in notes)
            + "\n\n"
            + _yaml.safe_dump(seed, allow_unicode=True, sort_keys=False)
        )
    else:
        template = core_root() / "templates" / "workspace" / "workspace.yaml"
        files["templates/workspace/workspace.yaml"] = template.read_text(encoding="utf-8")

    # `--force` used to mean "rewrite the whole scaffold", which is two acts
    # wearing one word: re-seed the template I asked for, and reset everything
    # else in this pack to blank. Re-seeding a `_workspace` pack to check that a
    # scope travelled into version control took a declared gate and two mount
    # entries with it, and said nothing — the closing words were about targets
    # being left empty on purpose, printed while three other files were emptied
    # without mention.
    #
    # So `--force` now overwrites only what the invocation is actually seeding.
    # It still fills a gap: a scaffold file that is not there is written, because
    # creating one takes nothing away, and that is the whole difference from
    # replacing one. (`--force` is needed to get this far at all on a pack that
    # already exists — the guard at the top of this function refuses a non-empty
    # directory without it, and that is unchanged.)
    created, replaced, kept = [], [], []
    # The three mountable directories are created empty, and that is not
    # tidiness. Mount walks them: a sample rule, a placeholder skill and a README
    # explaining the agents directory would all be placed, and the README would
    # arrive as `.claude/agents/deck-README.md` for Claude Code to load as an
    # agent. What the three are for is in this pack's own README, which mount
    # does not walk.
    for folder in ("rules", "skills", "agents"):
        (target / folder).mkdir(parents=True, exist_ok=True)

    for rel, content in files.items():
        path = target / rel
        if path.exists():
            if not args.force:
                continue
            if existing_pack and rel != SEEDED_FILE:
                kept.append(rel)
                continue
            replaced.append(rel)
        else:
            created.append(rel)
        # Parents per file, not a fixed list: the scaffold gained a nested
        # skills/<name>/SKILL.md and every deeper path added later would fail
        # the same way, at write time, halfway through.
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    if getattr(args, "quiet", False):
        return 0

    print(f"pack `{name}` {'updated' if existing_pack else 'created'} at {target}\n")
    for rel in created:
        print(f"  {rel}")
    for rel in replaced:
        print(f"  {rel}   (replaced)")
    if kept:
        # Named, not merely spared. deck says what it places when mounting and
        # what it removes when unmounting; a command that used to empty four
        # declarations owes the same account of what it left alone, or the
        # person cannot tell a pack that was protected from one that was blank.
        #
        # Only the files carrying something are named. A README and an empty
        # `profiles.yaml` were never at risk, and ten lines of them bury the one
        # line that answers the question a reader actually has — did my gate
        # survive?
        holding = [(rel, _holds(target / rel)) for rel in kept]
        carrying = [(rel, what) for rel, what in holding if what and what != "nothing declared"]
        print("\n  kept — this command seeds a template, and these are not it:")
        for rel, what in carrying:
            print(f"    {rel:<28} {what}")
        rest = len(kept) - len(carrying)
        if rest:
            print(f"    and {rest} scaffold file(s) with nothing declared in them")
    print("\nNext:")
    print(f"  $EDITOR {target}/config/toggles.yaml   # the decisions your team keeps re-making")
    print(f"  $EDITOR {target}/config/gates.yaml     # the ladder, and the commands behind it")
    print(f"  deck pack validate {target}")
    print(f"  export DECK_PACKS={target}")
    if bind:
        print(f"\n  Bound to the `{bind}` scope: it loads under `deck --scope {bind}` and")
        print("  nowhere else, and its template ships that initiative rather than the")
        print("  registry. `deck packs` lists it either way, in play or waiting.")
    elif args.from_workspace:
        print("\n  The descriptor template was seeded from this workspace, with targets")
        print("  left empty: an allowlist is a decision, not a copy of someone's hosts.")
    return 0


def cmd_pack_list(ws: Workspace, args) -> int:
    packs = ws.all_packs() if ws.root else []
    if args.json:
        print(json.dumps([str(p) for p in packs], ensure_ascii=False, indent=2))
        return 0
    if not packs:
        print("no packs in play")
        print("  Point at one with DECK_PACKS=/path/to/pack, or list it under `packs:`")
        print("  in the descriptor. Create one with `deck pack new <name>`.")
        return 0
    for pack in packs:
        detect = load_yaml(pack / "config" / "detect.yaml")
        toggles = load_yaml(pack / "config" / "toggles.yaml").get("toggles") or []
        gates = load_yaml(pack / "config" / "gates.yaml").get("gates") or []
        print(f"  {pack.name:<28} {len(toggles)} toggle(s) · {len(gates)} gate(s)")
        print(f"    {pack}")
        if detect.get("markers"):
            print(f"    markers: {', '.join(str(m) for m in detect['markers'])}")
    return 0


def cmd_pack_validate(ws: Workspace, args) -> int:
    target = Path(args.dir or ".").resolve()
    problems, warnings = [], []

    if not (target / "config").is_dir():
        problems.append("no config/ directory — is this a pack?")

    manifest = target / ".claude-plugin" / "plugin.json"
    if manifest.is_file():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            if not data.get("name"):
                problems.append(".claude-plugin/plugin.json has no `name`")
        except ValueError as exc:
            problems.append(f".claude-plugin/plugin.json is not valid JSON: {exc}")
    else:
        warnings.append("no .claude-plugin/plugin.json — Claude Code will not load this as a plugin")

    for rel in ("config/detect.yaml", "config/toggles.yaml", "config/gates.yaml"):
        if not (target / rel).is_file():
            warnings.append(f"{rel} is missing")

    # Nothing checks that a list and a directory agree, because there is no
    # list: `rules/` is what gets placed, and a file in it cannot be missing.

    gates = load_yaml(target / "config" / "gates.yaml").get("gates") or []
    for gate in gates:
        if not gate.get("id"):
            problems.append("a gate has no `id`")
        if not gate.get("per_repo") and not gate.get("once"):
            problems.append(f"gate `{gate.get('id', '?')}` declares neither `per_repo` nor `once`")

    for warning in warnings:
        print(f"warning: {warning}")
    for problem in problems:
        print(f"ERROR  : {problem}")

    if problems:
        print(f"\n{len(problems)} problem(s), {len(warnings)} warning(s)")
        return 1

    toggles = load_yaml(target / "config" / "toggles.yaml").get("toggles") or []
    print(f"OK — {len(toggles)} toggle(s), {len(gates)} gate(s), {len(warnings)} warning(s)")
    print("  Catalog wording is checked against the core with: deck toggle validate --strict")
    return 0


# ------------------------------------------------------------------ sources
def _registry() -> list[dict]:
    return load_yaml(core_root() / "config" / "sources.yaml").get("sources") or []


def _stars(repo: str) -> str:
    """Star count, read from the API when it answers. Data, not a claim."""
    import json as _json
    import urllib.error
    import urllib.request

    try:
        request = urllib.request.Request(f"https://api.github.com/repos/{repo}")
        request.add_header("Accept", "application/vnd.github+json")
        token = os.environ.get("DECK_TOKEN_GITHUB") or os.environ.get("GITHUB_TOKEN")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(request, timeout=10) as response:
            return str(_json.loads(response.read().decode()).get("stargazers_count", "?"))
    except (urllib.error.URLError, OSError, ValueError):
        return "?"


def cmd_pack_sources(ws: Workspace, args) -> int:
    if args.vendored:
        target = Path(args.into or ".").resolve()
        record = load_yaml(target / "config" / "sources.yaml")
        vendored = record.get("vendored") or []
        if not vendored:
            print(f"nothing vendored into {target}")
            return 0
        for item in vendored:
            print(f"  {item['path']}")
            print(f"    from {item['source']} @ {item.get('ref', '?')} ({item.get('commit', '?')[:12]})")
            print(f"    added {item.get('at', '?')} · sha256 {item.get('hash', '?')[:16]}")
        return 0

    for entry in _registry():
        print(f"  {entry['name']:<28} {entry.get('repo', entry.get('url', ''))}")
        print(f"    {entry.get('what', '')}")
        if entry.get("note"):
            print(f"    {' '.join(entry['note'].split())}")
    print("\n  `deck pack add <owner/repo|url|name>` vendors skills or agents from any of")
    print("  these, or from any git repository, recording where each file came from.")
    return 0


def _clone_url(source: str) -> str:
    if "://" in source or source.startswith("git@"):
        return source
    return f"https://github.com/{source}.git"


def cmd_pack_add(ws: Workspace, args) -> int:
    """Vendor skills or agents from a git repository into a pack.

    Vendoring, not installing: these become files you own, reviewed and
    committed like any other. A plugin you install stays under its author's
    control, which is right for a marketplace and wrong for something you need
    to adapt.
    """
    import shutil as _shutil
    import subprocess
    import tempfile

    target = Path(args.into or ".").resolve()
    if not (target / "config").is_dir():
        print(f"deck: {target} does not look like a pack (no config/). Use --into, or `deck pack new`.")
        return 1

    source = args.source
    known = {e["name"]: e for e in _registry()}
    if source in known:
        source = known[source].get("repo") or known[source].get("url")
    url = _clone_url(source)
    repo_slug = source if "/" in source and "://" not in source else ""

    with tempfile.TemporaryDirectory() as tmp:
        clone = Path(tmp) / "src"
        proc = subprocess.run(
            ["git", "clone", "--depth", "1", *(["--branch", args.ref] if args.ref else []), url, str(clone)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            print(f"deck: could not clone {url}\n  {proc.stderr.strip().splitlines()[-1][:200]}")
            return 1
        code, commit = run(["git", "-C", str(clone), "rev-parse", "HEAD"])
        commit = commit if code == 0 else "?"

        wanted: list[tuple[str, Path]] = []
        for kind, names in (("skills", args.skills), ("agents", args.agents)):
            base = clone / kind
            if not base.is_dir():
                continue
            for item in sorted(base.iterdir()):
                if names and item.name not in names and item.stem not in names:
                    continue
                if not names and not args.all:
                    continue
                wanted.append((kind, item))

        hooks = clone / "hooks"
        if hooks.is_dir():
            if args.with_hooks:
                wanted.append(("hooks", hooks))
            else:
                print(f"  note: {source} ships hooks/. Hooks are shell commands that run on")
                print("        your machine, so they are not taken unless you ask with --with-hooks.")

        if not wanted:
            print("nothing selected.")
            print("  Name what to take: --skills a,b  --agents c   (or --all)")
            available = {
                k: [p.name for p in (clone / k).iterdir()] for k in ("skills", "agents") if (clone / k).is_dir()
            }
            for kind, names in available.items():
                print(f"  {kind}: {', '.join(names) or '(none)'}")
            return 1

        print(f"from {source} @ {args.ref or 'default branch'} ({commit[:12]})")
        if repo_slug:
            print(f"  {_stars(repo_slug)} stars on GitHub at the time of adding")
        for kind, item in wanted:
            print(f"  + {kind}/{item.name}")
        if not args.yes:
            print("\n  Nothing written. These become files you own and review — re-run with --yes.")
            return 0

        record = load_yaml(target / "config" / "sources.yaml")
        record.setdefault("version", 1)
        vendored = record.setdefault("vendored", [])
        for kind, item in wanted:
            dest = target / (kind if item.name == kind else f"{kind}/{item.name}")
            if dest.exists() and not args.force:
                print(f"  kept {kind}/{item.name} (already here; --force replaces it)")
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            if item.is_dir():
                _shutil.rmtree(dest, ignore_errors=True)
                _shutil.copytree(item, dest)
                digest = _tree_hash(dest)
            else:
                _shutil.copyfile(item, dest)
                digest = _file_hash(dest)
            entry = {
                # A directory taken whole lands at `hooks/`, not `hooks/hooks`.
                # Recording the doubled name meant `pack update` looked for a
                # source path that never existed and reported the entry as
                # withdrawn on every run.
                "path": kind if item.name == kind else f"{kind}/{item.name}",
                "source": source,
                "ref": args.ref or "default",
                "commit": commit,
                "hash": digest,
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }
            # Replace rather than append: `--force` over something already
            # vendored is one artifact with a new provenance, and two records
            # for one path is two answers to the question the file exists to
            # answer.
            previous = next((i for i, v in enumerate(vendored) if norm(v.get("path")) == entry["path"]), None)
            if previous is None:
                vendored.append(entry)
            else:
                entry["at"] = vendored[previous].get("at", entry["at"])
                entry["replaced"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                vendored[previous] = entry
        dump_yaml(target / "config" / "sources.yaml", record)

    print(f"\n  vendored into {target}")
    print(f"  provenance recorded in {target / 'config' / 'sources.yaml'}")
    print("  Review what you took before committing it: these files instruct an agent.")
    return 0


def _file_hash(path: Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree_hash(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(item.read_bytes())
    return digest.hexdigest()


# ------------------------------------------------------------------ update
def _digest(path: Path) -> str | None:
    """Content hash of a vendored artifact, whether it is a file or a directory."""
    if path.is_dir():
        return _tree_hash(path)
    if path.is_file():
        return _file_hash(path)
    return None


# What can be true of a vendored artifact, and what each answer means to the
# person reading the report. `diverged` is the only one where taking the update
# would destroy work, which is why it is refused by default; `unreachable` is
# the only one that is not an answer at all, which is why it never counts as
# unchanged.
_STATES = {
    "current": "unchanged since you took it",
    "local": "edited here — upstream has not moved",
    "upstream": "the source moved; your copy is what you took",
    "diverged": "edited here AND the source moved",
    "withdrawn": "no longer in the source at this ref",
    "missing": "recorded, but not in the pack any more",
    "unreachable": "the source could not be read — not checked",
}


def cmd_pack_update(ws: Workspace, args) -> int:
    """Re-check what a pack vendored against the source it came from.

    `deck pack add` records the source, the ref, the commit and a hash. That
    record is what makes vendoring auditable rather than a copy nobody can trace
    — but a record only pays for itself if something reads it back. This reads
    it back, and answers the two questions the record makes answerable: has the
    source moved since you took this, and has anyone changed the copy here.

    Those two are reported separately on purpose. A file edited locally is the
    normal case — adapting what you take is the reason to vendor at all — and
    overwriting it is the one outcome that loses work. So an artifact that moved
    upstream *and* was changed here is refused, and says so, rather than being
    ranked or merged.
    """
    import shutil as _shutil
    import subprocess
    import tempfile

    target = Path(args.into or ".").resolve()
    if not (target / "config").is_dir():
        print(f"deck: {target} does not look like a pack (no config/). Use --into, or `deck pack new`.")
        return 1

    record = load_yaml(target / "config" / "sources.yaml")
    vendored = record.get("vendored") or []
    if not vendored:
        print(f"nothing vendored into {target}")
        print("  `deck pack add <owner/repo|url|name>` takes skills or agents from a source.")
        return 0

    wanted = vendored
    if args.artifact:
        wanted = [
            item
            for item in vendored
            if item.get("path") == args.artifact
            or Path(item.get("path", "")).name == args.artifact
            or fnmatch.fnmatch(item.get("path", ""), args.artifact)
        ]
        if not wanted:
            print(f"deck: {args.artifact} is not vendored into {target}")
            print(f"  What is: {', '.join(i.get('path', '?') for i in vendored)}")
            return 1

    # One clone per (source, ref): several artifacts usually come from the same
    # repository, and cloning it once per artifact would be the slow way to get
    # the same answer.
    groups: dict[tuple[str, str], list[dict]] = {}
    for item in wanted:
        groups.setdefault((item.get("source", ""), norm(item.get("ref", "default"))), []).append(item)

    rows: list[dict] = []
    with tempfile.TemporaryDirectory() as tmp:
        for (source, ref), items in groups.items():
            clone = Path(tmp) / slug(f"{source}-{ref}")
            branch = [] if ref in ("", "default", "?") else ["--branch", ref]
            try:
                proc = subprocess.run(
                    ["git", "clone", "--depth", "1", *branch, _clone_url(source), str(clone)],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=args.timeout,
                )
            except subprocess.TimeoutExpired:
                # Without this the timeout propagates and the whole command
                # dies, skipping the branch below whose entire job is to report
                # a source deck could not reach.
                for item in items:
                    rows.append(
                        {
                            **item,
                            "state": "unreachable",
                            "why": f"clone did not finish within {args.timeout}s",
                            "head": None,
                            "upstream_hash": None,
                        }
                    )
                continue
            if proc.returncode != 0:
                why = (proc.stderr.strip().splitlines() or ["clone failed"])[-1][:160]
                for item in items:
                    rows.append({**item, "state": "unreachable", "why": why, "head": None, "upstream_hash": None})
                continue
            code, head = run(["git", "-C", str(clone), "rev-parse", "HEAD"])
            head = head if code == 0 else "?"

            fresh = []
            for item in items:
                rel = norm(item.get("path", ""))
                taken = norm(item.get("hash", ""))
                here = _digest(target / rel)
                there = _digest(clone / rel)
                if here is None:
                    state = "missing"
                elif there is None:
                    state = "withdrawn"
                else:
                    moved = there != taken
                    edited = here != taken
                    state = ("diverged" if edited else "upstream") if moved else ("local" if edited else "current")
                fresh.append(
                    {
                        **item,
                        "state": state,
                        "why": "",
                        "head": head,
                        "upstream_hash": there,
                        "local_hash": here,
                        "source_path": str(clone / rel),
                    }
                )
            rows.extend(fresh)

            # Applying happens inside the `with`, while the clone still exists.
            if args.yes:
                for row in fresh:
                    if row["state"] not in ("upstream", "diverged"):
                        continue
                    if row["state"] == "diverged" and not args.force:
                        continue
                    dest = target / norm(row["path"])
                    src = Path(row["source_path"])
                    if src.is_dir():
                        _shutil.rmtree(dest, ignore_errors=True)
                        _shutil.copytree(src, dest)
                    else:
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        _shutil.copyfile(src, dest)
                    row["applied"] = True

    stale = [r for r in rows if r["state"] != "current"]
    refused = [r for r in rows if r["state"] == "diverged" and not r.get("applied")]
    blind = [r for r in rows if r["state"] == "unreachable"]

    if args.yes:
        now = time.strftime("%Y-%m-%dT%H:%M:%S")
        by_path = {norm(r["path"]): r for r in rows}
        for item in vendored:
            row = by_path.get(norm(item.get("path", "")))
            if row is None or row["state"] == "unreachable":
                continue
            item["checked"] = now
            if row.get("applied"):
                item["commit"] = row["head"]
                item["hash"] = row["upstream_hash"]
                item["updated"] = now
            elif row["state"] == "current":
                # Same bytes at a newer commit: the record should say which
                # commit the copy was last confirmed against, not the one it
                # happened to be taken from.
                item["commit"] = row["head"]
        record["vendored"] = vendored
        dump_yaml(target / "config" / "sources.yaml", record)

    if args.json:
        print(
            json.dumps(
                {
                    "pack": str(target),
                    "applied": bool(args.yes),
                    "artifacts": [
                        {
                            "path": r.get("path"),
                            "source": r.get("source"),
                            "ref": r.get("ref"),
                            "state": r["state"],
                            "meaning": _STATES[r["state"]],
                            "taken_commit": r.get("commit"),
                            "source_commit": r.get("head"),
                            "applied": bool(r.get("applied")),
                            "why": r.get("why", ""),
                        }
                        for r in rows
                    ],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print(f"re-checking {len(rows)} vendored artifact(s) in {target}\n")
        for row in rows:
            if row.get("applied"):
                mark, label = "->", f"taken — replaced with the source copy at {norm(row.get('head', '?'))[:12]}"
            else:
                mark, label = ("==" if row["state"] == "current" else "!!"), f"{row['state']} — {_STATES[row['state']]}"
            print(f"  {mark} {row.get('path', '?')}   {label}")
            print(f"       from {row.get('source', '?')} @ {row.get('ref', '?')}")
            if row["state"] == "unreachable":
                print(f"       {row['why']}")
            else:
                taken, head = norm(row.get("commit", "?"))[:12], norm(row.get("head", "?"))[:12]
                print(f"       taken at {taken} · source now at {head}")
            if row.get("applied"):
                print("       provenance updated; review it before you commit it")
            elif row["state"] == "diverged":
                print("       not replaced. Read both sides before deciding:")
                print(f"         git clone --depth 1 {_clone_url(norm(row.get('source', '')))} /tmp/src")
                print(f"         diff -ru {target / norm(row.get('path', ''))} /tmp/src/{norm(row.get('path', ''))}")
                print("       Then keep yours, port the change by hand, or take theirs with --force.")

        if blind:
            print(f"\n{len(blind)} artifact(s) were NOT checked — their source could not be read.")
            print("  Nothing is claimed about those; re-run when the source is reachable.")
        if not stale:
            print("\nevery artifact matches the source it came from.")
        elif not args.yes:
            takeable = [r for r in stale if r["state"] == "upstream"]
            if takeable:
                print(f"\nNothing written. `--yes` takes the {len(takeable)} marked `upstream`.")
            else:
                print("\nNothing written, and nothing here is `--yes` would take on its own.")
            if refused:
                print(f"  {len(refused)} artifact(s) diverged — those are left alone even with --yes.")
        elif refused:
            print(f"\n{len(refused)} artifact(s) left alone: edited here and moved upstream.")
            print("  Read the diff and decide. `--force` takes the source copy and loses your edits.")

    if blind:
        return 1
    if args.check and stale:
        return 1
    if args.yes and refused:
        return 1
    return 0


# ---------------------------------------------------------------- reviewing
# `validate` asks whether a pack is well formed. This asks whether it is doing
# anything — a different and harder question, and the one that decays quietly.
# Every signal here is computed from what the workspace already records; none of
# it is a judgement, and none of it needs a model.


def _front_matter(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    try:
        import yaml as _yaml

        return _yaml.safe_load(text[3:end]) or {}
    except Exception:
        return {}


_CODE_SPAN = re.compile(r"`+([^`\n]+)`+")


def _literals(path: Path) -> list[str]:
    """Every fragment a rule marks as text to type rather than to read.

    Backticks and fences are the only place a rule says "this is literal", so
    only those are read. The prose around them is judgement and is left alone:
    a rule whose sentence happens to contain a word that is also a program name
    is not naming a command, and treating it as one would make the finding
    below wrong often enough that a reader would stop believing any of it.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    if text.startswith("---"):
        # Front matter is the rule's scope, not its text. `paths:` names
        # directories for a living, and reading them here would flag every
        # scoped rule in the pack.
        close = text.find("\n---", 3)
        end = text.find("\n", close + 1) if close != -1 else -1
        text = text[end + 1 :] if end != -1 else ""
    out, fenced = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            out.append(line.strip())
        else:
            out.extend(m.group(1).strip() for m in _CODE_SPAN.finditer(line))
    return [frag for frag in out if frag]


def _ladder_programs(packs: list[Path]) -> dict[str, str]:
    """Program name -> the gate that already runs it, across the workspace.

    Gate ids are workspace-wide, so a rule in one pack can be repeating a gate
    declared in another; scoping this to the rule's own pack would miss the
    commonest case, where the shared pack owns the ladder.

    This is also the whole reason the finding below needs no tooling knowledge.
    The engine cannot know that `ruff` is a linter. It does not have to: a pack
    declared a gate that runs `ruff`, as data, and that declaration is what
    makes the name mean "something the ladder already decides".
    """
    programs: dict[str, str] = {}
    for pack in sorted(packs):
        for gate in load_yaml(pack / "config" / "gates.yaml").get("gates") or []:
            gid = norm(gate.get("id", ""))
            if not gid:
                continue
            for command in (gate.get("per_repo"), gate.get("once")):
                for name in invokes(str(command or "")):
                    programs.setdefault(name, gid)
    return programs


def _gate_history(root: Path) -> dict[str, dict]:
    """Per gate: how often it ran, and how often it caught something."""
    stats: dict[str, dict] = {}
    for record in sorted((state_root(root) / "gates").glob("*.json")):
        try:
            data = json.loads(record.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for gate in data.get("gates") or []:
            entry = stats.setdefault(gate.get("id", "?"), {"runs": 0, "caught": 0, "skipped": 0})
            status = gate.get("status")
            if status in ("passed", "failed", "blocked"):
                entry["runs"] += 1
            if status in ("failed", "blocked"):
                entry["caught"] += 1
            if status == "skipped":
                entry["skipped"] += 1
    return stats


def cmd_pack_review(ws: Workspace, args) -> int:
    """What each pack contributes, what it costs, and what is not earning its place.

    A pack is not judged by whether it parses. It is judged by whether its gates
    ever catch anything, whether its rules can reach a file, and whether its
    decisions were ever genuinely open. All three decay silently: a gate that
    stopped asserting, a rule scoped to a path that was renamed, a toggle whose
    answer has been the same for a year. None of that shows up anywhere until
    something gets through.
    """
    packs = ws.all_packs() if ws.root else []
    if not packs:
        print("no packs in play")
        return 0

    history = _gate_history(ws.root) if ws.root else {}
    ladder = _ladder_programs(packs)
    per_repo, _, _, _ = ws.discovered_packs()
    owner = {path.resolve(): repo for repo, path in per_repo.items()}
    report = []

    for pack in packs:
        mount = load_yaml(pack / "config" / "mount.yaml")
        toggles = load_yaml(pack / "config" / "toggles.yaml").get("toggles") or []
        gates = load_yaml(pack / "config" / "gates.yaml").get("gates") or []
        skills = sorted(pack.glob("skills/*/SKILL.md"))

        # Always-on cost: what every session pays whether or not the pack is used.
        always_on = 0
        for skill in skills:
            meta = _front_matter(skill)
            always_on += len(str(meta.get("description", ""))) + len(str(meta.get("when_to_use", "")))

        findings = []

        # Rules that cannot reach a file.
        scope = owner.get(pack.resolve())
        repos = [scope] if scope else list(ws.repos)
        rule_dir = pack / "rules"
        for path in sorted(rule_dir.glob("*.md")) if rule_dir.is_dir() else []:
            rel = f"rules/{path.name}"

            # Rules that are restating the ladder. This is the one direction
            # `review` never asked in: it priced every rule and never wondered
            # whether a machine was already deciding one. The sorting is not a
            # one-off — a rule gets written while nobody has the tool, the tool
            # arrives as a gate a year later, and nothing goes back to the rule.
            # A gate arriving is exactly what makes this detectable, so it is
            # the arrival that is looked for, not the wording of the rule.
            named = set()
            for fragment in _literals(path):
                for name in invokes(fragment):
                    gid = ladder.get(name)
                    if gid and name not in named:
                        named.add(name)
                        findings.append(
                            f"rule {rel} names `{name}`, which gate {gid} already runs — "
                            "a gate costs nothing until it fires; this is paid for on "
                            "every matching file read"
                        )

            patterns = _front_matter(path).get("paths") or []
            if not patterns:
                continue
            targets = [r for r in repos if r in ws.repos]
            reached = False
            for name in targets:
                code, listing = run(["git", "-C", str(ws.repo_path(name)), "ls-files"], timeout=10)
                if code != 0:
                    reached = True  # cannot tell; do not accuse
                    break
                for line in listing.splitlines():
                    if any(fnmatch.fnmatch(line, p) or fnmatch.fnmatch(f"{name}/{line}", p) for p in patterns):
                        reached = True
                        break
                if reached:
                    break
            if not reached and targets:
                findings.append(f"rule {rel} matches no file in {', '.join(targets)} — it never loads")

        # Gates that have never caught anything.
        for gate in gates:
            stat = history.get(gate.get("id", ""), {})
            if stat.get("runs", 0) >= 5 and stat.get("caught", 0) == 0:
                findings.append(f"gate {gate.get('id')} ran {stat['runs']}x and never failed — check it still asserts")
            if stat.get("runs", 0) == 0 and stat.get("skipped", 0) >= 3:
                findings.append(f"gate {gate.get('id')} was skipped {stat['skipped']}x and has never run")

        # Decisions that are not decisions.
        for spec in toggles:
            if spec.get("askable") is False:
                continue
            # An `overrides: true` entry adds impact text or wording to a
            # toggle defined elsewhere; it carries no values of its own and is
            # not a candidate for either complaint below.
            if spec.get("overrides"):
                continue
            values = spec.get("values") or []
            if len(values) < 2:
                findings.append(f"toggle {spec.get('id')} offers no real choice")
            if norm(spec.get("default", "")) not in ("ask", "") and not spec.get("overrides"):
                findings.append(
                    f"toggle {spec.get('id')} has a fixed default and is never asked — "
                    "if nobody would change it, it is a rule, not a decision"
                )

        report.append(
            {
                "pack": pack.name,
                "path": str(pack),
                "scope": scope or "workspace",
                "rules": len(mount.get("rules") or []),
                "skills": len(skills),
                "toggles": len(toggles),
                "gates": len(gates),
                "always_on_chars": always_on,
                "findings": findings,
            }
        )

    if args.json:
        print(json.dumps({"packs": report, "gate_history": history}, ensure_ascii=False, indent=2))
        return 0

    print(f"reviewing {len(report)} pack(s) against what this workspace has recorded\n")
    for row in report:
        print(
            f"  {row['pack']:<22} {row['scope']:<18} "
            f"{row['rules']} rule(s) · {row['skills']} skill(s) · {row['toggles']} toggle(s) · {row['gates']} gate(s)"
        )
        if row["always_on_chars"]:
            print(f"  {'':<22} ~{row['always_on_chars'] // 4} tokens paid in every session, used or not")
        for finding in row["findings"]:
            print(f"  {'':<22} !! {finding}")
    total = sum(len(r["findings"]) for r in report)

    if history:
        print("\ngate history, from the evidence this workspace kept")
        for gid, stat in sorted(history.items(), key=lambda kv: -kv[1]["caught"]):
            print(f"  {gid:<16} ran {stat['runs']:>3}  caught {stat['caught']:>3}  skipped {stat['skipped']:>3}")
    else:
        print("\nno gate evidence yet — run the ladder a few times and ask again.")
        print("  A gate's worth is how often it catches something, and that takes history.")

    if total:
        print(f"\n{total} thing(s) worth looking at. None is automatically wrong;")
        print("each is a place where a pack may have stopped earning its context.")
    return 0
