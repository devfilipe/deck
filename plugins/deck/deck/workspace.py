"""Workspace resolution, repository registry, and the impact graph.

The engine knows nothing about what your repositories build with. It knows that
a repository has a path, an optional build target, a list of repositories it
impacts, and a list it is coupled with. Everything else is declared by a pack.

Two kinds of edge, because `impacts:` answers two questions at once — *what must
I revisit* and *in what order* — and some real relationships answer the first
and not the second. `couples:` is the second kind: symmetric, order-free, and
invisible to `order()` and `cycles()`.
"""

from __future__ import annotations

import json
import os
import urllib.parse
from pathlib import Path

from .config import (
    ENV_PREFIX,
    STATE_DIR,
    die,
    MACHINE_FILE,
    load_yaml,
    norm,
    pack_dirs,
    run,
    selected_scope,
    state_root,
)


# The key a pack uses to bind itself to an initiative, in its own
# `config/detect.yaml`.
#
# A directory convention was the other candidate — a pack under a reserved
# parent whose name matches a declared scope — and it was rejected because the
# binding would then be a property of the collection rather than of the pack.
# The same pack pointed at by `packs:` or by DECK_PACKS sits in no collection at
# all and could never be bound; vendored into another team's collection it would
# silently lose or change its binding; and nothing inside the pack would say
# what it was bound to, so `deck packs` could not report it and `deck pack
# validate` could not check it. `scope:` travels with the pack through all three
# routes a pack arrives by, and sits beside `requires:` because both answer the
# same question: when does this pack apply.
SCOPE_KEY = "scope"

# The layered collection: `_workspaces/<name>/<scope>/` and `_repos/<name>/`.
#
# This is the shape. There is no other, and `is_layered` exists to say so out
# loud: a directory pointed at by `packs_root` that holds neither is reported as
# not being a collection, rather than resolving to nothing and letting a
# workspace run with no knowledge in it and no word about why.
#
# `all` and `default` always exist and are the base. A leaf under a name other
# than `all`, or a scope other than `default`, overlays it file by file — that is
# the whole point of the axis, and it is why the same file name may appear at
# more than one level without being the collision the flat shape refuses.
#
# When the two axes disagree — `all/<scope>` and `<name>/default` both carrying
# one file — the name wins. A workspace is a place and a scope is a phase, and
# the phase is the temporary one; a rule written for this workspace should not be
# displaced by one written for every workspace merely because an initiative is
# running.
WORKSPACES_DIR = "_workspaces"
REPOS_DIR = "_repos"
ALL_NAME = "all"
DEFAULT_SCOPE = "default"


def is_layered(root: Path) -> bool:
    """Whether a collection is laid out in the `_workspaces`/`_repos` shape."""
    return (root / WORKSPACES_DIR).is_dir() or (root / REPOS_DIR).is_dir()


def pack_name(pack: Path) -> str:
    """What to call a pack in a message a person reads.

    Not `path.name`: the leaf of a workspace layer is `default` or a scope name,
    so four layers would report as `default`, `default`, `beta`, `beta` and a
    reader could not tell which one relabelled their toggle. The pair is the
    name — it is what the collection is indexed by, and what someone would have
    to type to go and edit the thing.
    """
    layer = pack_layer(pack)
    return layer[0] if layer else pack.name


def collection_home(root: Path, name: str) -> Path:
    """Where a pack called `name` belongs inside a collection.

    The name says which axis it is on, because in this shape the axis is the
    only thing a name can mean: `<workspace>/<scope>` is a workspace layer,
    anything else is a repository. That is why `deck pack new all/default` and
    `deck pack new deck` need no flag between them — a slash is not decoration
    here, it is the pair the collection is indexed by.
    """
    parts = [piece for piece in name.split("/") if piece]
    if len(parts) == 2:
        return root / WORKSPACES_DIR / parts[0] / parts[1]
    return root / REPOS_DIR / name


def pack_layer(pack: Path) -> tuple[str, str] | None:
    """(label, what it reaches) for a pack inside a layered collection.

    The leaf directory of a workspace layer is called `default` or the name of a
    scope, so `path.name` alone would print four packs called `default` and say
    nothing about which layer each one is. The label is the pair, because the
    pair is what the collection actually declared.

    None for a pack that is in no collection — one named by `packs:` or
    DECK_PACKS — where the directory name is all there is and is the answer.
    """
    parts = pack.resolve().parts
    for marker, depth in ((WORKSPACES_DIR, 2), (REPOS_DIR, 1)):
        if marker not in parts:
            continue
        at = len(parts) - 1 - parts[::-1].index(marker)
        tail = parts[at + 1 : at + 1 + depth]
        if len(tail) != depth:
            continue
        if marker == REPOS_DIR:
            return parts[-1], parts[-1]
        name, scope = tail
        reach = "every repository" if name == ALL_NAME else f"workspace {name}"
        if scope != DEFAULT_SCOPE:
            reach += f" · scope {scope}"
        return f"{name}/{scope}", reach
    return None


# The three fields that are one person's answer and can never be versioned: a
# packs checkout, a tools directory and a lab host. `pack new --from-workspace`
# already drops exactly these when it seeds a template, and this is the same
# list read from the other end.
MACHINE_FIELDS = ("packs_root", "paths", "targets")


def machine_path(root: Path | None) -> Path | None:
    """`.deck/machine.yaml` — the three fields, and where the descriptor is."""
    return (state_root(root) / MACHINE_FILE) if root else None


def descriptor_path(root: Path | None) -> Path | None:
    """The descriptor deck was handed, or the one this machine keeps.

    Three sources, in order, and each is a deliberate statement rather than a
    guess:

    `${ENV}DESCRIPTOR` names a file, for one command.

    `descriptor:` in `.deck/machine.yaml` names it for this checkout. That file
    is never versioned — `.deck/` never is — so it is where a machine says
    which layer of the collection it is working in without the answer having to
    travel to anybody else. It is also what makes a versioned descriptor usable
    with no environment variable at all, which was the whole friction.

    Failing both, `.deck/workspace.yaml`, exactly as before. A workspace with no
    collection has one file and needs nothing explained to it.
    """
    named = os.environ.get(f"{ENV_PREFIX}DESCRIPTOR")
    if named:
        return Path(named).expanduser().resolve()
    machine = machine_path(root)
    overlay = load_yaml(machine) if machine and machine.is_file() else {}
    pointed = overlay.get("descriptor")
    if pointed:
        path = Path(str(pointed)).expanduser()
        return path if path.is_absolute() else (root / path).resolve()

    # A selection is a pointer too, and a shorter one: `<name>/<scope>` plus a
    # collection is a path. It is preferred over naming the file because the
    # pair is what a person thinks in, and because the file moves when the
    # layer does.
    chosen = selected_scope()
    if chosen and root:
        roots = overlay.get("packs_root") or []
        roots = [roots] if isinstance(roots, str) else list(roots)
        for entry in roots:
            base = Path(str(entry)).expanduser()
            base = base if base.is_absolute() else (root / base)
            candidate = base / WORKSPACES_DIR / chosen / "workspace.yaml"
            if candidate.is_file():
                return candidate.resolve()
            # The descriptor belongs to the workspace, not to one phase of it,
            # so a selection of `<name>/<scope>` reads `<name>/default`'s
            # descriptor unless that scope keeps one of its own.
            fallback = base / WORKSPACES_DIR / chosen.split("/")[0] / DEFAULT_SCOPE / "workspace.yaml"
            if fallback.is_file():
                return fallback.resolve()
    return (state_root(root) / "workspace.yaml") if root else None


def descriptor_identity(descriptor: Path) -> tuple[str, str] | None:
    """(name, scope) for a descriptor sitting in a layered collection.

    Pointing deck at `_workspaces/foo/bar/workspace.yaml` IS saying the workspace
    is `foo` and the scope is `bar`: the path already carries both, so neither
    needs a key in the file, and a descriptor moved between layers cannot end up
    disagreeing with its own contents.

    None for a descriptor anywhere else, which is every workspace that predates
    this shape.
    """
    parts = descriptor.resolve().parts
    try:
        at = len(parts) - 1 - parts[::-1].index(WORKSPACES_DIR)
    except ValueError:
        return None
    if len(parts) < at + 4:
        return None
    return parts[at + 1], parts[at + 2]


def active_scope() -> str | None:
    """The named subset of the registry this invocation is working inside.

    It lives in the environment rather than in a file, for the same reason the
    root does: which initiative you are working on is a property of the terminal
    you are sitting in, not of the workspace everybody shares. `deck --scope
    <name>` exports it for one command, so a gate command or a board adapter —
    both of which deck runs as subprocesses — lands inside the same scope
    without anyone threading an argument through.
    """
    named = os.environ.get(f"{ENV_PREFIX}SCOPE", "").strip()
    if named:
        return named
    # The selected pair carries the scope in its second half. `--scope` on one
    # command still wins, because a selection is where you are and a flag is
    # what you are doing right now.
    chosen = selected_scope()
    if chosen and "/" in chosen:
        tail = chosen.split("/", 1)[1]
        return tail if tail != DEFAULT_SCOPE else None
    return None


def _pack_markers() -> list[str]:
    """Detection markers contributed by extension packs.

    Root resolution has to happen before the descriptor can be read, so markers
    cannot live in the descriptor. They come from the environment or from a
    pack's `config/detect.yaml`.
    """
    markers: list[str] = []
    raw = os.environ.get(f"{ENV_PREFIX}MARKERS", "")
    markers += [m for m in raw.split(":") if m.strip()]
    for pack in pack_dirs():
        detect = load_yaml(pack / "config" / "detect.yaml")
        markers += [norm(m) for m in (detect.get("markers") or [])]
    return markers


def find_root(use_selection: bool = True) -> Path | None:
    """Four sources, in order. Never guesses a path."""
    env = os.environ.get(f"{ENV_PREFIX}ROOT")
    if env:
        return Path(env).expanduser().resolve()

    # Standing inside a workspace answers first. A selection is global — one at
    # a time, for the person — and being IN a tree is the more specific
    # statement: somebody who cd's into a workspace that keeps its own
    # descriptor means that one, whatever they selected an hour ago somewhere
    # else. Asking the selection first made a `deck init` here write there.
    here = Path.cwd().resolve()
    for base in (here, *here.parents):
        if (base / STATE_DIR / "workspace.yaml").is_file() or (base / STATE_DIR / "toggles.yaml").is_file():
            return base

    # Then the selection. `~/.deck/workspaces/<name>/machine.yaml` carries
    # `root:` because a project set up with a collection carries nothing of
    # deck's — which is the point, and which means the walk above finds nothing.
    # It is also why a command works from anywhere; `deck doctor` prints the
    # root it resolved, so standing elsewhere is visible rather than surprising.
    machine = state_root(None) / MACHINE_FILE
    if use_selection and selected_scope() and machine.is_file():
        declared = load_yaml(machine).get("root")
        if declared:
            return Path(str(declared)).expanduser().resolve()

    markers = _pack_markers()
    if markers:
        for base in (here, *here.parents):
            if any((base / m).exists() for m in markers):
                return base

    opt = os.environ.get("CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT")
    return Path(opt).expanduser().resolve() if opt else None


def root_source() -> str:
    """Where the root came from, so `doctor` can explain itself."""
    if os.environ.get(f"{ENV_PREFIX}ROOT"):
        return f"${ENV_PREFIX}ROOT"
    here = Path.cwd().resolve()
    for base in (here, *here.parents):
        if (base / STATE_DIR / "workspace.yaml").is_file() or (base / STATE_DIR / "toggles.yaml").is_file():
            return f"descriptor at {base / STATE_DIR}"
    chosen = selected_scope()
    if chosen and (state_root(None) / MACHINE_FILE).is_file():
        return f"selected {chosen}"
    if _pack_markers():
        for base in (here, *here.parents):
            if any((base / m).exists() for m in _pack_markers()):
                return "auto-detected from pack markers"
    if os.environ.get("CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT"):
        return "plugin option workspace_root"
    return "unresolved"


def git_toplevel(path: Path | None = None) -> Path | None:
    code, out = run(["git", "-C", str(path or Path.cwd()), "rev-parse", "--show-toplevel"], timeout=5)
    return Path(out) if code == 0 and out else None


def current_repo() -> str | None:
    top = git_toplevel()
    return top.name if top else None


# Which board a source names, and nothing about who is asking for it. A tracker
# source holds both: `type`/`url`/`project`/`repo`/`jql` say which board, and
# `user` says which account the credentials belong to. The second is per person
# by design — everybody authenticates as themselves, and a shared file naming
# one of them is both wrong and a small disclosure.
#
# Two callers, and they are the same question asked twice. Drift comparison uses
# it because comparing the whole source reports a divergence that is true,
# useless and permanent, and a warning nobody can clear is one nobody reads.
# Seeding a pack template uses it because the seed's own rule is whether a value
# would still be true on the next person's machine, and an account name is the
# clearest case of one that would not.
# What a board source is, as opposed to who is reading it. `pack new
# --from-workspace` seeds these into a template and drops everything else, so a
# key missing here is a key that does not survive to the next machine.
#
# `api:` was missing, and with it a self-hosted host: a team on GitHub
# Enterprise seeded a template that silently pointed at github.com. `include:`
# and `in_progress:` arrived later and would have gone the same way — the kind
# of item the board holds, and how that board writes down "somebody is on it",
# are the team's answer and not one machine's. A check pins this tuple against
# the fields the documents describe, so the next one cannot be forgotten either.
BOARD_IDENTITY = (
    "type",
    "url",
    "api",
    "project",
    "repo",
    "jql",
    "query",
    "include",
    "in_progress",
    "file",
    "command",
    "state",
    "labels",
)

PER_PERSON = ("user",)

# The keys a `lives_in:` entry may point with, and the whole of what makes one
# checkable offline. A `file:` deck can stat; a `url:` it can parse. An entry
# naming neither is the bag of strings this shape exists instead of: nothing
# distinguishes it from a sentence somebody typed, so nothing can be wrong with
# it and nothing can be checked about it.
PLACE_LOCATORS = ("file", "url")


def board_identity(source: dict) -> dict:
    """A tracker source with everything that names a person taken out."""
    return {k: v for k, v in source.items() if k in BOARD_IDENTITY}


def person_fields(source: dict) -> list[str]:
    """Which per-person fields this source carries, so a report can name them."""
    return [k for k in PER_PERSON if k in source]


def _board_diff(mine: list[str], theirs: list[str]) -> str:
    """Which fields differ between two sets of board identities.

    Naming the field beats naming a consequence: the old message said the two
    read "different tasks", which is a claim about what the sources return and
    deck had fetched neither to find out. It compared configuration and
    described results.
    """

    def fields(rows: list[str]) -> dict[str, set[str]]:
        out: dict[str, set[str]] = {}
        for row in rows:
            for key, value in json.loads(row).items():
                out.setdefault(key, set()).add(str(value))
        return out

    a, b = fields(mine), fields(theirs)
    named = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
    if not named:
        # Same fields, different number of sources: two entries against one.
        return f"{len(mine)} source(s) here against {len(theirs)}"
    return "they differ on " + ", ".join(f"`{k}`" for k in named)


class Workspace:
    """The `.deck/workspace.yaml` descriptor and the graph it declares."""

    def __init__(self, root: Path | None = None):
        self.root = root or find_root()
        self.source = root_source()
        self.descriptor = descriptor_path(self.root)
        self.data = load_yaml(self.descriptor) if self.descriptor else {}
        self.identity = descriptor_identity(self.descriptor) if self.descriptor else None

        # The machine's three fields, laid over whatever the descriptor said.
        # Only three, and that is what makes this an overlay rather than a merge:
        # there is no question about which key wins, because no other key is
        # read. A fourth one in the file is reported by `deck doctor` and never
        # applied — a key silently ignored and a key silently applied are both
        # worse than a line naming it.
        self.machine = machine_path(self.root)
        if self.machine and self.machine.is_file():
            overlay = load_yaml(self.machine)
            for field in MACHINE_FIELDS:
                if field in overlay:
                    self.data = {**self.data, field: overlay[field]}

    # -- access -------------------------------------------------------------
    @property
    def repos(self) -> dict:
        return self.data.get("repos") or {}

    @property
    def targets(self) -> list:
        """Machines the agent is allowed to touch. An allowlist, not a hint."""
        return self.data.get("targets") or []

    @property
    def packs_roots(self) -> list[Path]:
        """Collections of packs, each matched to repositories by name.

        The convention exists because the alternative is a mapping table nobody
        keeps current: a pack directory named after a repository *is* that
        repository's pack, and there is nothing else to declare.

        A list, because layering is real — a domain collection any team could
        use, and an organisation's own on top of it.
        """
        raw = os.environ.get(f"{ENV_PREFIX}PACKS_ROOT") or (self.data.get("packs_root") if self.data else None)
        if not raw:
            return []
        entries = raw.split(":") if isinstance(raw, str) else list(raw)
        out = []
        for entry in entries:
            if not str(entry).strip():
                continue
            path = Path(str(entry)).expanduser()
            out.append(path if path.is_absolute() else (self.root / path if self.root else path))
        return out

    def pack_scope(self, pack: Path) -> str | None:
        """The initiative this pack belongs to, or None for one that belongs to none.

        Declared by the pack itself, in `config/detect.yaml`. A pack that
        declares nothing is what every pack was before scopes existed, which is
        what keeps a workspace with no scope packs exactly as it was.
        """
        layer = pack_layer(pack)
        if layer:
            # In a collection the path is the binding, and it outranks the file
            # for the same reason the file outranks a guess: it is the more
            # deliberate statement. `default` is not an initiative — it is the
            # absence of one — so it binds nothing.
            scope = layer[0].split("/")[-1] if "/" in layer[0] else None
            return scope if scope and scope != DEFAULT_SCOPE else None
        value = load_yaml(pack / "config" / "detect.yaml").get(SCOPE_KEY)
        return norm(value).strip() or None if value is not None else None

    def _repo_packs(self, base: Path, names: dict[str, str]) -> list[tuple[str, Path]]:
        """`_repos/<name>` entries that match a repository in the registry.

        Two levels deep, so a collection can mirror a workspace laid out in
        groups — `_repos/group1/proj1` matches `proj1` wherever it sits.
        """
        if not base.is_dir():
            return []
        out = []
        for path in sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")):
            if path.name in names:
                out.append((names[path.name], path))
                continue
            out += [
                (names[child.name], child)
                for child in sorted(c for c in path.iterdir() if c.is_dir() and not c.name.startswith("."))
                if child.name in names
            ]
        return out

    def discovered_packs(self) -> tuple[dict[str, Path], list[Path], dict[str, list[Path]], list[str]]:
        """Walk the pack roots. Returns (per repository, shared, per scope, complaints).

        A collection is `_workspaces/<name>/<scope>/` and `_repos/<name>/`. `all`
        and `default` always exist and are the base; a leaf under another name or
        another scope overlays them, which is why one file name may appear at
        several levels without being the collision a repository pack still is.

        The shared list comes back already ordered, most general first:

            _workspaces/all/default
            _workspaces/all/<active scope>
            _workspaces/<name>/default
            _workspaces/<name>/<active scope>

        so nothing downstream has to hold a second opinion about which layer
        outranks which. A scope directory contributes only while that scope is
        active: a layer arriving when nobody asked for the initiative would be
        the opposite of binding it.

        `by_scope` carries every scope layer the collection holds, the active one
        included — it is already placed in the list above, and `all_packs` keeps
        the first sighting of a path, so the repetition cannot reorder anything.
        It is also where packs arriving through `packs:` or DECK_PACKS end up:
        those sit in no collection and can only declare `scope:` for themselves.
        """
        roots = list(self.packs_roots)
        missing = [str(r) for r in roots if not r.is_dir()]
        roots = [r for r in roots if r.is_dir()]
        complaints = [f"packs_root does not exist: {m}" for m in missing]
        if not roots:
            return {}, [], {}, complaints

        names = {name: name for name in self.repos}
        for name, entry in self.repos.items():
            if entry.get("path"):
                names.setdefault(Path(entry["path"]).name, name)

        found: dict[str, Path] = {}
        layers: list[list[Path]] = [[], [], [], []]
        by_scope: dict[str, list[Path]] = {}
        scope = self.scope_name
        here = self.identity[0] if self.identity else None

        # The four layers, most general first, and each named only once: a
        # workspace called `all` or a scope called `default` must not make the
        # base arrive twice and merge over itself.
        wanted = [(ALL_NAME, DEFAULT_SCOPE)]
        if scope and scope != DEFAULT_SCOPE:
            wanted.append((ALL_NAME, scope))
        if here and here != ALL_NAME:
            wanted.append((here, DEFAULT_SCOPE))
            if scope and scope != DEFAULT_SCOPE:
                wanted.append((here, scope))

        for root in roots:
            if not is_layered(root):
                complaints.append(
                    f"{root} is not a pack collection: one holds `{WORKSPACES_DIR}/` or "
                    f"`{REPOS_DIR}/` at its top, and this holds neither"
                )
                continue

            for owner, path in self._repo_packs(root / REPOS_DIR, names):
                if owner in found and found[owner] != path:
                    complaints.append(
                        f"two packs claim `{owner}`: {found[owner]} and {path} — deck does not "
                        "rank two packs claiming one repository, and which of them wins here is "
                        "the order the directories happened to be read in. Rename one, or drop it from the collection"
                    )
                    continue
                found[owner] = path

            for index, (who, which) in enumerate(wanted):
                leaf = root / WORKSPACES_DIR / who / which
                if leaf.is_dir():
                    layers[index].append(leaf)

            # Every scope layer the collection holds, active or not. The active
            # ones are already in `layers` at the position their axis earned, and
            # `all_packs` keeps the first sighting of a path, so listing them
            # again here cannot move them. What it buys is the other half: a
            # layer waiting on an initiative nobody asked for is knowledge that
            # loads for nobody, and `deck packs` can only offer it if something
            # enumerated it.
            for holder in sorted((root / WORKSPACES_DIR).glob("*/*")):
                if not holder.is_dir() or holder.name == DEFAULT_SCOPE:
                    continue
                if holder.parent.name not in (ALL_NAME, here or ALL_NAME):
                    continue
                by_scope.setdefault(holder.name, []).append(holder)

        return found, [path for layer in layers for path in layer], by_scope, complaints

    def unbound_named_packs(self) -> list[Path]:
        """Named packs that belong to no initiative — the general layer, unchanged."""
        return [pack for pack in self.named_packs() if not self.pack_scope(pack)]

    def scope_layer(self, by_scope: dict[str, list[Path]] | None = None) -> list[Path]:
        """The packs bound to the active scope, in merge order.

        Empty when no scope is active, which is the whole of the answer to "what
        happens with no scope". A pack whose knowledge only matters while an
        initiative is running must not arrive when nobody asked for it — that
        would be the opposite of binding it.

        A scope-bound pack merges in this layer however it was found. Arriving
        through `packs:` makes a pack general, and being bound to an initiative
        makes it specific; the binding is the deliberate statement, so it decides
        the layer and the route it came by does not.
        """
        active = self.scope_name
        if not active:
            return []
        if by_scope is None:
            by_scope = self.discovered_packs()[2]
        named = [pack for pack in self.named_packs() if self.pack_scope(pack) == active]
        return named + list(by_scope.get(active) or [])

    def dormant_packs(self) -> list[tuple[Path, str]]:
        """Scope-bound packs that are not in play, with the scope each waits on.

        Knowledge that loads for nobody and appears in no listing is knowledge
        nobody can find, which is a worse failure than knowledge loaded too
        widely: the second is visible. `deck packs` prints these under their own
        heading with the command that brings each one in.
        """
        active = self.scope_name
        by_scope = self.discovered_packs()[2]
        out: list[tuple[Path, str]] = []
        seen: set[Path] = set()
        for pack in self.named_packs():
            bound = self.pack_scope(pack)
            if bound and bound != active and pack.resolve() not in seen:
                seen.add(pack.resolve())
                out.append((pack, bound))
        for name in sorted(by_scope):
            if name == active:
                continue
            for pack in by_scope[name]:
                if pack.resolve() not in seen:
                    seen.add(pack.resolve())
                    out.append((pack, name))
        return out

    def packs_for(self, repo: str) -> list[Path]:
        """Every pack that applies to one repository, most general first.

        Four kinds of pack, and their scope is not the same. A pack named
        explicitly — through DECK_PACKS or `packs:` in the descriptor — was
        chosen for the whole workspace. A shared pack says so in its name. A
        pack bound to an initiative applies to the repositories that initiative
        holds, while it is running. A pack named after a repository belongs to
        that repository and to no other: it describes *that* codebase, and
        letting it reach a sibling is how a convention meant for one repository
        quietly becomes law across the workspace.

        Order is merge order, so the most specific pack has the last word. An
        initiative is narrower than the workspace and wider than one repository,
        so its layer sits between them: it takes over from a workspace-wide pack
        and a repository's own pack takes over from it.

        The scope layer is skipped for a repository the scope does not hold. A
        mount follows the impact graph outside the boundary, and an initiative's
        conventions have no claim on a repository it merely reaches — the same
        rule that keeps a repository pack out of its siblings.

        The boundary is applied to the shared list too, and has to be. A scope
        layer comes back inside that list, at the position its axis earned, so
        filtering only what `scope_layer` adds would let `_workspaces/*/<scope>`
        reach every repository — which is how this stopped holding once already,
        and the check that caught it is `and not into one outside it`.
        """
        per_repo, shared, by_scope, _ = self.discovered_packs()
        inside = self.in_scope(repo)
        out = self.unbound_named_packs() + [p for p in shared if inside or not self.pack_scope(p)]
        if inside:
            out += self.scope_layer(by_scope)
        if repo in per_repo:
            out.append(per_repo[repo])
        seen, unique = set(), []
        for path in out:
            key = path.resolve()
            if key not in seen:
                seen.add(key)
                unique.append(path)
        return unique

    def pack_owner(self) -> dict[Path, str]:
        """Resolved pack path -> the repository whose name claims it.

        A pack missing from this map applies workspace-wide, because it was
        named explicitly, because it is `_workspace`, or because it is bound to
        an initiative rather than to a codebase.
        """
        per_repo, _, _, _ = self.discovered_packs()
        return {path.resolve(): repo for repo, path in per_repo.items()}

    def all_packs(self) -> list[Path]:
        """Every extension pack, once.

        A pack can arrive twice — named by DECK_PACKS and again by the
        descriptor — and loading it twice makes its own toggles collide with
        themselves. Deduplicate by resolved path, keeping first-seen order.
        """
        # Not gated on a descriptor: DECK_PACKS_ROOT has to work before one
        # exists, or `deck setup` cannot see the collection it is linking to.
        per_repo, shared, by_scope, _ = self.discovered_packs()
        # Most general first: named, shared, the active initiative's, then one
        # repository's. A pack bound to a scope nobody asked for is in none of
        # these — `dormant_packs()` is where it is still findable.
        extra = shared + self.scope_layer(by_scope) + sorted(per_repo.values())
        out, seen = [], set()
        for pack in self.unbound_named_packs() + extra:
            key = pack.resolve()
            if key not in seen:
                seen.add(key)
                out.append(pack)
        return self.ordered_packs(out)

    def named_packs(self) -> list[Path]:
        """Packs chosen by name rather than found by convention.

        Two sources, general first: `packs:` in the descriptor, then DECK_PACKS
        from the environment, which wins among them the way an environment
        variable wins everywhere else in deck.

        This is the layer a collection cannot express by naming, because a
        domain pack — a build system, a delivery shape — is named after no
        repository in particular. It is also how a pack outside every
        `packs_root` gets loaded at all.
        """
        declared = [self.resolve_path(str(entry)) for entry in ((self.data or {}).get("packs") or [])]
        return declared + pack_dirs()

    def pack_requires(self, pack: Path) -> list[str]:
        """Pack names this one declares it needs, from its `config/detect.yaml`."""
        detect = load_yaml(pack / "config" / "detect.yaml")
        return [str(n) for n in (detect.get("requires") or [])]

    def ordered_packs(self, packs: list[Path]) -> list[Path]:
        """Merge order: a pack comes after everything it requires.

        This is what makes layering declared rather than alphabetical. Order is
        merge order, so a pack that requires another is merged later and its
        overrides win — which is the only reason to declare the dependency at
        all. An organisation pack that requires a domain pack gets the last
        word over it, in every catalog, without anyone having to name the
        collection so the sort happens to come out right.

        An unsatisfiable or circular requirement does not abort. Whatever
        cannot be placed goes to the end in its original order, and `deck
        packs` and `deck doctor` report it — refusing to run would take the
        diagnosis away exactly when it is needed.
        """
        known = {pack_name(p) for p in packs}
        placed: list[Path] = []
        done: set[str] = set()
        pending = list(packs)
        while pending:
            # One at a time, rescanning from the front. Placing every ready
            # pack in a single sweep would be faster and would also shuffle the
            # layers: a per-repository pack with no requirements would overtake
            # an organisation pack that was merely waiting for its domain pack,
            # and land ahead of it in the merge. Input order already encodes the
            # layering, so `requires` should disturb it as little as it can.
            for pack in pending:
                if all(n in done for n in self.pack_requires(pack) if n in known):
                    placed.append(pack)
                    done.add(pack.name)
                    pending.remove(pack)
                    break
            else:
                break
        return placed + pending

    def pack_problems(self) -> list[str]:
        """What is wrong with the collection: its collisions, then its requirements.

        The collisions come first because they are the older and quieter fault.
        `discovered_packs()` has always reported a name two packs claim, and
        nothing but `deck setup` ever printed it — so the two commands documented
        as reporting it, `deck packs` and `deck doctor`, said nothing while one of
        the two packs won on `iterdir()` order. A collection resolved by the
        order a filesystem hands back its entries is exactly what the design line
        refuses.
        """
        out: list[str] = list(self.discovered_packs()[3])
        packs = self.all_packs()
        known = {pack_name(p) for p in packs}
        merged: set[str] = set()
        for pack in packs:
            missing = [n for n in self.pack_requires(pack) if n not in known]
            if missing:
                out.append(f"{pack.name} requires `{'`, `'.join(missing)}` — not in play")
            late = [n for n in self.pack_requires(pack) if n in known and n not in merged]
            if late:
                out.append(f"{pack.name} merges before `{'`, `'.join(late)}`, which it requires — check for a cycle")
            merged.add(pack.name)
        return out

    def repo(self, name: str) -> dict:
        entry = self.repos.get(name)
        if entry is None:
            die(f"unknown repository in descriptor: {name}")
        return entry

    def resolve_path(self, raw: str) -> Path:
        """A path out of the descriptor, resolved.

        Relative paths are relative to the workspace root, which is what a
        descriptor is for. But `~` expands and an absolute path is taken as
        given, because "everything lives under one root" is an assumption the
        real world breaks constantly — a shared tools checkout beside the
        workspace rather than inside it is an ordinary layout, and refusing it
        only pushes people into symlinks deck would then have to reason about.
        """
        path = Path(raw).expanduser()
        return path.resolve() if path.is_absolute() else (self.root / path).resolve()

    def repo_path(self, name: str) -> Path:
        rel = self.repo(name).get("path")
        if not rel:
            die(f"repository {name} has no `path` in the descriptor")
        return self.resolve_path(str(rel))

    @property
    def paths(self) -> dict[str, Path]:
        """Named directories this workspace uses but does not change.

        A tools checkout, a scripts directory, a vendor drop: things a gate or
        a rule has to point at, which are not repositories of this workspace.
        They carry no impact edges, declare no gates of their own, and nothing
        is ever mounted into them.

        The split that matters is **what you change** versus **what you use**.
        Something you edit is a repository, and belongs in `repos:` even when
        it lives outside the root. Something you only invoke belongs here.

        Declaring it keeps the pack portable: the pack says `${path.tools}`
        while the location stays in `.deck/`, which is per machine and not
        versioned.
        """
        raw = (self.data or {}).get("paths") or {}
        return {str(k): self.resolve_path(str(v)) for k, v in raw.items()}

    def target(self, name: str) -> dict | None:
        for t in self.targets:
            if norm(t.get("host")) == norm(name) or norm(t.get("alias")) == norm(name):
                return t
        return None

    # -- scopes -------------------------------------------------------------
    @property
    def scopes(self) -> dict:
        """Named subsets of the registry, each with its own board and posture.

        A workspace of forty repositories is rarely one piece of work. A scope
        says "this initiative is these six of them", and carries the two things
        that follow from saying so: the board those six work from, and the
        posture that applies while working on them.

        What a scope is NOT is a second registry. The graph stays whole — a
        change inside a scope still reaches whatever it reaches, and `deck
        impact` still says so. A scope narrows what a command *acts on*, never
        what deck *knows*, because a subset that hides an edge is worse than no
        subset at all.
        """
        return self.data.get("scopes") or {}

    @property
    def scope_name(self) -> str | None:
        """The active scope, if the descriptor declares it.

        An undeclared name is ignored here rather than fatal, because this is
        read by the status line and by `deck doctor` — the two surfaces that
        have to keep working when the environment is wrong. The entry point
        refuses an undeclared `--scope` before any command runs, and
        `scope_problems` reports an exported one, so the mistake is never
        silent; it is only non-fatal in the places whose job is to tell you.
        """
        name = active_scope()
        return name if name and name in self.scopes else None

    @property
    def scope(self) -> dict:
        """The active scope's declaration, or an empty mapping."""
        return self.scopes.get(self.scope_name) or {} if self.scope_name else {}

    def scope_repos(self, name: str | None = None) -> list[str]:
        """The repositories a scope names, in declaration order.

        Declaration order, not topological: a scope is written by a person and
        reads back the way they wrote it. Callers that need build order pass
        this through `order()`.
        """
        scope = self.scopes.get(name) if name else self.scope
        return [norm(r) for r in ((scope or {}).get("repos") or []) if norm(r) in self.repos]

    def selected_repos(self) -> list[str]:
        """The repositories a command should act on by default.

        Inside a scope this is the subset — which is what makes `deck repos`,
        `deck mount` and `deck gate run` mean "this initiative" without anyone
        retyping the list. Outside one it is the whole registry, unchanged.
        """
        return self.scope_repos() if self.scope_name else list(self.repos)

    def in_scope(self, repo: str) -> bool:
        """Whether a repository is inside the active scope. True when none is."""
        return True if not self.scope_name else repo in self.scope_repos()

    def scope_leaks(self, name: str | None = None) -> list[str]:
        """Repositories a scope's own changes reach but the scope does not hold.

        The diagnostic a scope exists to produce: an initiative that names six
        repositories and forces a seventh is an initiative whose boundary is
        wrong, or whose owners have a dependency they have not agreed with
        anyone. Either way it is worth knowing before the work starts, not in
        the merge.

        This walks `impacts:` and returns the ordered chain. The other half of
        the boundary is `scope_coupled()`, and the two are reported beside each
        other and never merged: both answer "what does this initiative reach",
        only this one also answers "in what order", and a single list would
        hand that order to the half that has none. `deck impact` keeps the same
        two halves apart on the same grounds.
        """
        inside = self.scope_repos(name)
        reached: list[str] = []
        for repo in inside:
            for other in self.impacted(repo):
                if other not in inside and other not in reached:
                    reached.append(other)
        return self.order(reached)

    def scope_coupled(self, name: str | None = None) -> list[str]:
        """The other half of a coupled pair, where the scope holds one side only.

        The second thing a scope leaks, and it leaks for the same reason as the
        first: work on the schema forces a look at the scripts it shells out
        to, and an initiative that does not hold the scripts has a boundary
        that is wrong or a dependency nobody agreed to. Left out, `deck scope`
        printed "the boundary is closed" over a pair with file-and-line
        evidence on both sides while `deck impact` on a repository inside that
        same scope named it — two surfaces read side by side, disagreeing.

        Reading the coupling here does not follow from `deck mount` reading it,
        and is not refused by `board.closure()` refusing to: those two are
        opposite answers, so the precedent settles nothing. What separates them
        is what the answer is used for. `closure()` decides which tasks may not
        run beside each other, where one name too many is a collision that did
        not happen and work serialised for nothing. `mount` only places files,
        and this only tells a person. Nothing here sorts, schedules or
        excludes: a name too many costs a sentence to read, a name too few
        costs a boundary that reads as closed when it is not.

        Couplings of the repositories the scope holds, not of the ones it
        merely reaches. A coupling is a claim about one pair, evidenced in
        those two repositories, and a scope owns that evidence only where it
        owns the repository — which is the same set `deck impact <repo>` lists
        for each repository inside, so the two surfaces answer alike.

        Registry order, not `order()`: the pair carries no order, and the
        topological sort could only invent one.
        """
        inside = self.scope_repos(name)
        out: list[str] = []
        for repo in inside:
            for other in self.coupled(repo):
                if other not in inside and other not in out:
                    out.append(other)
        rank = {repo: i for i, repo in enumerate(self.repos)}
        return sorted(out, key=lambda repo: rank.get(repo, len(rank)))

    def workspace_template(self) -> tuple[Path, str] | None:
        """The pack-shipped descriptor template, and the name of the pack shipping it.

        `deck setup` seeds `.deck/workspace.yaml` from this file, so it is the
        one place a team's registry shape is versioned. The most specific pack
        wins, as everywhere else that packs layer: merge order puts it last, so
        the walk is backwards and stops at the first hit.

        **The registry is not merged, and the scopes are.** Which repositories
        exist and how a change propagates between them is a description of a
        thing that exists: one answer serves everybody and a second opinion is a
        contradiction. A scope is a decision about how to divide attention, and
        several can be true at once. Merging contradictions is wrong; merging
        decisions is ordinary — so this stays "most specific wins" and
        `pack_scopes()` merges.

        A scope-bound pack is skipped here whatever it ships. Its template
        carries an initiative's definition, never the registry, and letting one
        win this walk would mean `deck setup` seeded a workspace's repositories
        out of whichever initiative happened to be active.

        None rather than the core's generic template, because the two are not
        interchangeable for every caller. Seeding falls back to the generic
        shape; comparing this machine against "what the team ships" has nothing
        to compare against when no pack ships one, and must say so rather than
        measure a workspace against deck's own example file.
        """
        for pack in reversed(self.all_packs()):
            if self.pack_scope(pack):
                continue
            candidate = pack / "templates" / "workspace" / "workspace.yaml"
            if candidate.is_file():
                return candidate, pack.name
        return None

    def backlog_sources(self) -> list[dict]:
        """The board sources to read: the active scope's own, or the workspace's.

        A scope that declares `backlog:` has a board of its own and that board
        replaces the workspace's — the tasks on it are the scope's tasks, and
        filtering them again by repository would only hide a mistake worth
        reporting. A scope that declares none works from the shared board,
        narrowed to the tasks its repositories cover.
        """
        if self.scope.get("backlog"):
            return list(self.scope["backlog"])
        return list((self.data or {}).get("backlog") or [])

    def scope_places(self, name: str | None = None) -> list[dict]:
        """Where this initiative lives, beyond the board deck reads.

        A board is one of several places a formal initiative lives, and it was
        the only one with a home: the documentation space, the view the team
        actually looks at, the channel, the register somebody has to update
        stayed in one person's head and were re-asked every time somebody
        joined.

        Nothing here follows a link. That is the point and the limit — reading
        those places is a different feature with different machinery, and a
        person following a URL is a legitimate consumer of a record deck only
        keeps. What deck does do is check the entry: `scope_problems` names one
        that points nowhere, so what is stored is never free text nobody looked
        at.

        Declaration order, and only the entries that resolve: a malformed one is
        reported rather than printed as if it were a place.
        """
        scope = self.scopes.get(name) if name else self.scope
        declared = (scope or {}).get("lives_in") or []
        return [place for place in declared if isinstance(place, dict) and not self._place_problem("", place)]

    def _place_problem(self, name: str, place: object) -> str | None:
        """Why deck cannot resolve this `lives_in:` entry, or None.

        Offline by construction. Whether the far end answers is a request, and
        this is the same bargain `missing_requirement` makes for a board source:
        the descriptor is checked here, the network only under `--net`.
        """
        where = f"scope `{name}`: `lives_in:`" if name else "`lives_in:`"
        if not isinstance(place, dict):
            return f"{where} holds `{place}`, which is not an entry — write `- {{ type: docs, url: https://… }}`"
        kind = norm(place.get("type", ""))
        if not kind:
            return f"{where} has an entry with no `type:` — say what the place is, in whatever word the team uses"
        named = [key for key in PLACE_LOCATORS if place.get(key)]
        if not named:
            return (
                f"{where} entry `{kind}` names neither `url:` nor `file:` — "
                "a place deck cannot resolve is a note, and a note belongs in prose"
            )
        if len(named) > 1:
            return f"{where} entry `{kind}` names both `url:` and `file:` — one place per entry"
        if named[0] == "file":
            rel = norm(place.get("file", ""))
            if not self.resolve_path(rel).exists():
                return f"{where} entry `{kind}` points at `{rel}`, which does not exist under this workspace"
            return None
        parsed = urllib.parse.urlsplit(str(place.get("url", "")))
        if not parsed.scheme or not parsed.netloc:
            return (
                f"{where} entry `{kind}` points at `{place.get('url')}`, which deck cannot follow — "
                "write the address in full, with its scheme"
            )
        return None

    def scope_problems(self) -> list[str]:
        """Everything wrong with the declared scopes, with the fix in the text.

        One kind of problem used to live here and no longer can: a scope name
        two packs both shipped. A scope is a directory now, so `all/beta` and
        `proj/beta` are two layers of one initiative — which is the overlay, not
        a collision — and there is no second answer to rank.
        """
        out: list[str] = []
        for name, scope in self.scopes.items():
            declared = [norm(r) for r in ((scope or {}).get("repos") or [])]
            unknown = [r for r in declared if r not in self.repos]
            if unknown:
                out.append(
                    f"scope `{name}` names {', '.join(unknown)}, which the registry does not declare — "
                    "add them under `repos:` or drop them from the scope"
                )
            if not declared:
                out.append(f"scope `{name}` names no repository — a scope with no subset narrows nothing")
            for source in (scope or {}).get("backlog") or []:
                rel = norm(source.get("file", ""))
                if rel and not self.resolve_path(rel).is_file():
                    out.append(f"scope `{name}`: board file not found — {rel}")
            for place in (scope or {}).get("lives_in") or []:
                problem = self._place_problem(name, place)
                if problem:
                    out.append(problem)
        wanted = active_scope()
        if wanted and wanted not in self.scopes:
            known = ", ".join(self.scopes) or "none declared"
            out.append(
                f"${ENV_PREFIX}SCOPE names `{wanted}`, which is not a declared scope "
                f"(known: {known}) — every command is running over the whole registry"
            )
        return out

    # -- impact graph -------------------------------------------------------
    def impacted(self, name: str) -> list[str]:
        """Transitive closure of `impacts`, without repeats or cycles."""
        seen: list[str] = []
        stack = list(self.repo(name).get("impacts") or [])
        while stack:
            nxt = stack.pop(0)
            if nxt in seen or nxt == name:
                continue
            seen.append(nxt)
            if nxt in self.repos:
                stack.extend(self.repos[nxt].get("impacts") or [])
        return seen

    # -- coupling -----------------------------------------------------------
    # `couples:` exists because `impacts:` answers two questions with one edge —
    # what must I revisit, and in what order — and a genuinely mutual
    # relationship answers the first and has no answer to the second. Writing it
    # as two `impacts:` edges makes the second answer a lie and destroys the
    # topological order for everyone else; writing only one half throws away a
    # constraint that has file-and-line evidence behind it.
    #
    # So coupling is a third kind of edge, and the three methods below are the
    # whole of it. Nothing here is reachable from `order()` or `cycles()`, and
    # that is the point: a coupling can never make the graph cyclic.

    def coupled(self, name: str) -> list[str]:
        """Repositories mutually coupled with this one. Symmetric, not transitive.

        Declaring it on either side is enough — this reads both directions, so
        `couples: [b]` under `a` and `couples: [a]` under `b` mean exactly the
        same thing and declaring both is not a duplicate.

        Not transitive, and deliberately so. `impacts:` composes because "forces
        a change in" composes; "drives each other" does not. A coupling is a
        claim about one pair, backed by evidence in those two repositories, and
        chaining two of them would assert a third pair nobody wrote down.

        Undeclared targets are dropped rather than returned. `impacted()` passes
        them through, but a coupling target feeds `deck mount`, which would then
        be asked to place packs in a repository that does not exist; `doctor`
        reports the dangling entry instead.
        """
        out: list[str] = []
        for other in self.repos.get(name, {}).get("couples") or []:
            if other != name and other in self.repos and other not in out:
                out.append(other)
        for other, entry in self.repos.items():
            if other == name or other in out:
                continue
            if name in (entry.get("couples") or []):
                out.append(other)
        return out

    def neighbours(self, name: str) -> list[tuple[str, str]]:
        """Which repositories the graph connects to this one, and how.

        Three relations, each a different reason to open a sibling: what this
        one reaches when it changes, what reaches it, and what moves with it.
        Named rather than merged into one list because the reason is what tells
        a reader — or a drafting agent — where to look for an answer.

        The graph, not the registry. A drafter told about every repository in the
        workspace reads every repository in the workspace; the whole reason this
        is affordable is that `impacts:` and `couples:` already say which few
        could possibly hold the answer.
        """
        out: list[tuple[str, str]] = []
        seen = {name}

        def add(other: str, why: str) -> None:
            if other in seen or other not in self.repos:
                return
            seen.add(other)
            out.append((other, why))

        for other in self.repos.get(name, {}).get("impacts") or []:
            add(other, "a change here reaches it")
        for other, entry in self.repos.items():
            if name in (entry.get("impacts") or []):
                add(other, "a change there reaches this one")
        for other in self.coupled(name):
            add(other, "coupled: the two move together")
        return out

    def coupling_sides(self, a: str, b: str) -> list[str]:
        """Which of the two repositories declared the coupling, in registry order.

        One name means one side wrote it; two means both did. `doctor` and `deck
        impact` print this so a reader is never left wondering whether the entry
        they cannot find in this file is missing or merely on the other side.
        """
        return [name for name, other in ((a, b), (b, a)) if other in (self.repos.get(name, {}).get("couples") or [])]

    def couplings(self) -> list[tuple[str, str, list[str]]]:
        """Every coupled pair once, as (a, b, who declared it), sorted.

        Once, not twice: the pair is the fact, and printing `a <-> b` beside
        `b <-> a` would read as two couplings where there is one. Pairs naming a
        repository the registry does not declare are left out — `doctor` reports
        those as dangling rather than drawing them.

        Ordered by where the repositories sit in the registry, not
        alphabetically. The pair itself has no order, so any tie-break is
        arbitrary; making it the order of the file means the report reads back in
        the order the person wrote, and the same pair prints the same way whoever
        declared it.
        """
        rank = {name: i for i, name in enumerate(self.repos)}
        pairs: set[tuple[str, str]] = set()
        for name, entry in self.repos.items():
            for other in entry.get("couples") or []:
                if other == name or other not in self.repos:
                    continue
                pairs.add((name, other) if rank[name] < rank[other] else (other, name))
        return [(a, b, self.coupling_sides(a, b)) for a, b in sorted(pairs, key=lambda p: (rank[p[0]], rank[p[1]]))]

    def mutual_impacts(self) -> list[tuple[str, str]]:
        """Pairs that impact each other — the two-repository case of a cycle.

        Reported separately from the cycle itself because it has a fix the
        general case does not: if the two genuinely drive each other, the
        relationship was a coupling all along and `couples:` records it without
        claiming an order.
        """
        pairs: set[tuple[str, str]] = set()
        for name, entry in self.repos.items():
            for other in entry.get("impacts") or []:
                if other in self.repos and name in (self.repos[other].get("impacts") or []):
                    pairs.add((name, other) if name < other else (other, name))
        return sorted(pairs)

    def order(self, names: list[str]) -> list[str]:
        """Topological order: the impacted come after what impacts them.

        A cycle does not abort. Leftover repositories go to the end in input
        order, so the caller can still work while `doctor` reports the cycle.
        Downstream repositories sort last among equals, so a plan reads as the
        build chain followed by what merely has to keep up.

        `couples:` is not read here, and must never be. A coupling carries no
        order, so folding it in could only invent one — and the pair that is
        coupled precisely because neither side comes first would be the pair it
        invented an order for.
        """
        pending = [n for n in names if n in self.repos]
        pending += [n for n in names if n not in self.repos]
        out: list[str] = []
        guard = 0
        while pending and guard <= len(names) + 1:
            guard += 1
            progressed = False
            for n in list(pending):
                upstream = [
                    other for other in pending if other != n and n in (self.repos.get(other, {}).get("impacts") or [])
                ]
                if not upstream:
                    out.append(n)
                    pending.remove(n)
                    progressed = True
            if not progressed:
                break
        out += pending
        return [n for n in out if not self.repos.get(n, {}).get("downstream")] + [
            n for n in out if self.repos.get(n, {}).get("downstream")
        ]

    def cycles(self) -> list[str]:
        """Repositories caught in an impact cycle, if any.

        This has to walk the graph itself rather than lean on `impacted()` or
        `order()`. `impacted()` skips the starting node by design, so a node can
        never appear in its own closure; `order()` appends whatever it could not
        place rather than failing, so its length never betrays a cycle. Both
        choices are right for their own callers and wrong for this question —
        which is how an earlier version of this method managed to report every
        graph as acyclic.

        `couples:` is not walked. That is the whole reason the field exists: a
        mutual relationship recorded as a coupling cannot make this method
        report a cycle, so the topological order goes on existing.
        """
        WHITE, GREY, BLACK = 0, 1, 2
        colour = dict.fromkeys(self.repos, WHITE)
        caught: set[str] = set()

        def visit(node: str, path: list[str]) -> None:
            colour[node] = GREY
            path.append(node)
            for nxt in self.repos.get(node, {}).get("impacts") or []:
                if nxt not in colour:
                    continue  # a dangling reference; `doctor` reports those separately
                if colour[nxt] == GREY:
                    caught.update(path[path.index(nxt) :])
                elif colour[nxt] == WHITE:
                    visit(nxt, path)
            path.pop()
            colour[node] = BLACK

        for name in list(self.repos):
            if colour[name] == WHITE:
                visit(name, [])
        return sorted(caught)

    def build_targets(self, names: list[str]) -> list[str]:
        """Build targets for the given repositories, in order, skipping downstream."""
        return [
            self.repos[n]["build_target"]
            for n in names
            if n in self.repos and self.repos[n].get("build_target") and not self.repos[n].get("downstream")
        ]
