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
from pathlib import Path

from .config import ENV_PREFIX, STATE_DIR, die, load_yaml, norm, pack_dirs, run

# Pack directory names that mean "every repository in this workspace".
# Several, because this is the one place a team's own vocabulary meets a
# directory listing, and refusing a synonym buys nothing: the name says what
# the pack is for, and a collection shared between products tends to call it
# something other than the workspace it is not specific to.
SHARED_NAMES = ("_workspace", "_all", "_shared", "_common")

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


def active_scope() -> str | None:
    """The named subset of the registry this invocation is working inside.

    It lives in the environment rather than in a file, for the same reason the
    root does: which initiative you are working on is a property of the terminal
    you are sitting in, not of the workspace everybody shares. `deck --scope
    <name>` exports it for one command, so a gate command or a board adapter —
    both of which deck runs as subprocesses — lands inside the same scope
    without anyone threading an argument through.
    """
    return os.environ.get(f"{ENV_PREFIX}SCOPE", "").strip() or None


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


def find_root() -> Path | None:
    """Four sources, in order. Never guesses a path."""
    env = os.environ.get(f"{ENV_PREFIX}ROOT")
    if env:
        return Path(env).expanduser().resolve()

    here = Path.cwd().resolve()
    for base in (here, *here.parents):
        if (base / STATE_DIR / "workspace.yaml").is_file() or (base / STATE_DIR / "toggles.yaml").is_file():
            return base

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
BOARD_IDENTITY = ("type", "url", "project", "repo", "jql", "query", "file", "command", "state", "labels")

PER_PERSON = ("user",)


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
        self.data = load_yaml(self.root / STATE_DIR / "workspace.yaml") if self.root else {}

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
        value = load_yaml(pack / "config" / "detect.yaml").get(SCOPE_KEY)
        return norm(value).strip() or None if value is not None else None

    def discovered_packs(self) -> tuple[dict[str, Path], list[Path], dict[str, list[Path]], list[str]]:
        """Walk the pack root. Returns (per repository, shared, per scope, complaints).

        Two levels deep, so a pack collection can mirror a workspace laid out in
        groups — `packs/group1/proj1` matches `proj1` wherever it sits. A name
        that appears twice is reported rather than resolved: guessing which of
        two packs a repository meant is worse than saying they collide.

        A pack declaring `scope:` goes in the third bucket and in no other, and
        that is checked before the directory name is looked at: an explicit
        declaration outranks a convention, so a pack sitting under a repository's
        name and saying it belongs to an initiative belongs to the initiative.
        Several packs may be bound to one scope, exactly as several may be
        shared — that layer is a list for the same reason the shared one is.
        """
        roots = list(self.packs_roots)
        missing = [str(r) for r in roots if not r.is_dir()]
        roots = [r for r in roots if r.is_dir()]
        if not roots:
            return {}, [], {}, [f"packs_root does not exist: {m}" for m in missing]

        names = {name: name for name in self.repos}
        for name, entry in self.repos.items():
            if entry.get("path"):
                names.setdefault(Path(entry["path"]).name, name)

        found: dict[str, Path] = {}
        shared: list[Path] = []
        by_scope: dict[str, list[Path]] = {}
        complaints: list[str] = []

        candidates: list[Path] = []
        for root in roots:
            top = [p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")]
            candidates += top
            candidates += [
                child
                for p in top
                for child in p.iterdir()
                if child.is_dir() and not child.name.startswith(".") and (child / "config").is_dir()
            ]
        complaints += [f"packs_root does not exist: {m}" for m in missing]

        for path in candidates:
            if not (path / "config").is_dir():
                continue
            bound = self.pack_scope(path)
            if bound:
                by_scope.setdefault(bound, []).append(path)
                continue
            if path.name in SHARED_NAMES:
                shared.append(path)
                continue
            repo = names.get(path.name)
            if repo is None:
                continue
            if repo in found and found[repo] != path:
                complaints.append(
                    f"two packs claim `{repo}`: {found[repo]} and {path} — deck does not rank two "
                    "packs claiming one repository, and which of them wins here is the order the "
                    "directories happened to be read in. Rename one, or drop it from the collection"
                )
                continue
            found[repo] = path
        return found, shared, by_scope, complaints

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
        """
        per_repo, shared, by_scope, _ = self.discovered_packs()
        out = self.unbound_named_packs() + list(shared)
        if self.in_scope(repo):
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
        known = {p.name for p in packs}
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
        known = {p.name for p in packs}
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

    def scope_publishers(self) -> list[Path]:
        """Every pack whose template may ship the definition of a scope.

        The packs in play, plus the scope-bound ones that are not. A pack
        publishes the initiative it is bound to whether or not that initiative
        is running right now — otherwise the definition would only be visible
        from inside the scope it defines, and `deck --scope <name>` on a machine
        that has not declared the scope yet could never say where to copy the
        block from.
        """
        out = list(self.all_packs())
        seen = {pack.resolve() for pack in out}
        for pack, _name in self.dormant_packs():
            if pack.resolve() not in seen:
                seen.add(pack.resolve())
                out.append(pack)
        return out

    def _shipped_scopes(self) -> tuple[dict, dict[str, dict], list[str]]:
        """(the scopes the packs ship, where each came from, names claimed twice).

        Merged across every pack rather than taken from one template, because an
        initiative belongs to whoever runs it and a second initiative appearing
        must not mean editing the file the first one lives in.

        A name two packs both ship is neither merged nor ranked. deck cannot
        know which of two answers to one question the team meant, and picking
        the later one would make the winner depend on the order the directories
        sorted in — so the name is left out of the comparison entirely and
        reported instead, with both packs named.
        """
        scopes: dict = {}
        origins: dict[str, dict] = {}
        clashes: dict[str, list[str]] = {}
        for pack in self.scope_publishers():
            path = pack / "templates" / "workspace" / "workspace.yaml"
            if not path.is_file():
                continue
            for name, scope in (load_yaml(path).get("scopes") or {}).items():
                if name in origins:
                    clashes.setdefault(name, [origins[name]["pack"]]).append(pack.name)
                    continue
                scopes[name] = scope
                origins[name] = {"pack": pack.name, "template": str(path)}
        collisions = []
        for name, packs in clashes.items():
            scopes.pop(name, None)
            origins.pop(name, None)
            collisions.append(
                f"scope `{name}` is shipped by more than one pack ({', '.join(packs)}) — "
                "deck does not rank two answers to one question, so this machine's carve-up is "
                f"compared against neither. Keep `{name}` in one of them and drop it from the rest"
            )
        return scopes, origins, collisions

    def pack_scopes(self) -> tuple[dict, dict[str, dict]]:
        """The carve-up the packs ship, and where each scope came from.

        `origins[name]` is `{"pack": ..., "template": ...}`, per scope rather
        than per workspace: with the definitions merged across packs, "which
        pack shipped this" no longer has one answer for the whole file, and a
        divergence report that could not say which pack to go and edit would be
        a report nobody can act on.

        Empty when no pack ships a template, and equally empty when the ones
        that do declare no `scopes:` — the generic template ships `scopes: {}`,
        and a team that never filled it in has not disagreed with anything.
        """
        scopes, origins, _ = self._shipped_scopes()
        return scopes, origins

    def pack_scope_collisions(self) -> list[str]:
        """Scope names claimed by two packs, each with the fix in the sentence."""
        return self._shipped_scopes()[2]

    def scope_drift(self) -> list[dict]:
        """How this machine's carve-up differs from the one its pack ships.

        `scopes:` lives in `.deck/workspace.yaml`, which is per machine and
        never versioned, so two people can run the same command in the same
        named scope and act on different sets of repositories with nothing to
        tell either of them. A pack's `templates/workspace/workspace.yaml` is
        where the carve-up stops being one person's and becomes the team's, and
        this is the comparison against it.

        Four facts, and they do not deserve one severity, so this reports the
        state and leaves the voice to whoever prints it:

        - `missing` — the pack ships a scope this workspace does not declare.
          Work the team shares that this machine cannot enter: `deck --scope
          <name>` is refused here.
        - `local` — this workspace declares one the pack does not ship. An
          initiative of somebody's own, which is a legitimate thing to have and
          is reported as a fact, never as a fault.
        - `differs` on `repos` or `backlog` — the same name on both sides
          holding a different subset, or reading a different board. This is the
          quiet failure the check exists for.
        - `differs` on `title` alone — the same subset under another wording,
          which changes nothing any command does.

        Repositories are compared as a set. Declaration order is how a person
        wrote the list, not what a command acts on, and two people who wrote the
        same six names in a different order are working on the same initiative.
        Declared names, not `scope_repos()`: filtering each side to what its own
        registry holds would make `[a, b, ghost]` and `[a, b]` compare equal and
        hide the mistake `scope_problems` is separately reporting.

        Empty when the pack ships no scopes at all, which is the ordinary case
        and not a finding. A check that accuses a workspace of drifting from
        nothing is a check people learn to scroll past.
        """
        theirs, origins, collisions = self._shipped_scopes()
        if not theirs and not collisions:
            return []
        # A name two packs both claim is left out of the comparison altogether,
        # on both sides. It is not a scope this machine has invented: the packs
        # ship it, deck refuses to read which one, and `scope_problems()` says
        # so. Letting it fall through here reported it as local to this machine
        # — a sentence that is false, beside one that is true.
        contested = {
            name for name in self.scopes if name not in theirs and any(f"scope `{name}` is" in c for c in collisions)
        }

        def board(source: dict) -> str:
            return json.dumps(board_identity(source), sort_keys=True, default=str)

        def shape(scope: dict | None) -> dict:
            scope = scope or {}
            return {
                "title": norm(scope.get("title", "")),
                "repos": [norm(r) for r in (scope.get("repos") or [])],
                "backlog": [board(s) for s in (scope.get("backlog") or [])],
            }

        out: list[dict] = []
        for name in list(theirs) + [n for n in self.scopes if n not in theirs and n not in contested]:
            mine = shape(self.scopes.get(name)) if name in self.scopes else None
            pack_side = shape(theirs.get(name)) if name in theirs else None
            if pack_side is None:
                state, fields = "local", []
            elif mine is None:
                state, fields = "missing", []
            else:
                # Repositories and board first, title last: the order the caller
                # reads to decide how loud to be, most material difference first.
                fields = [f for f in ("repos", "backlog") if set(mine[f]) != set(pack_side[f])]
                if mine["title"] != pack_side["title"]:
                    fields.append("title")
                if not fields:
                    continue
                state = "differs"
            # Per scope, not per workspace: the definitions are merged across
            # packs now, so "go and edit the pack" has to name the one that
            # actually holds this scope. A scope only this machine has belongs
            # to no pack, and the note about it points at wherever the registry
            # template lives, which is where a local initiative would go to
            # become the team's.
            origin = origins.get(name) or {}
            found = self.workspace_template()
            out.append(
                {
                    "name": name,
                    "pack": origin.get("pack") or (found[1] if found else None),
                    "template": origin.get("template") or (str(found[0]) if found else ""),
                    "state": state,
                    "fields": fields,
                    "here": mine,
                    "shipped": pack_side,
                }
            )
        return out

    def scope_drift_notes(self) -> list[tuple[str, str, str]]:
        """`scope_drift` as sentences, each with its severity and its fix.

        Returns `(severity, scope name, sentence)`, severity being `warn` or
        `note`. Three surfaces print this — `deck doctor`, `deck scopes` and
        `deck scope <name>` — and a divergence worded three ways is a
        divergence a team argues about instead of resolving, so the wording is
        written once here, beside `scope_problems`, which is a list of
        sentences with the fix in them for the same reason.

        One sentence per differing field rather than one per scope: a scope can
        hold a different subset AND carry a different title, and those are not
        the same finding at the same volume.

        `note`, not `warn`, is the whole point of the split. A scope only this
        machine has is a legitimate thing to have; a title worded differently
        changes nothing any command does. Reporting either at the volume of
        "you and your colleague are editing different repositories" is how a
        report stops being read.

        Nothing here is a problem. deck keeps working on both sides of every
        divergence, and which side it is using is in the sentence, because an
        operator who cannot tell which list is in force has been told something
        worse than nothing.
        """
        here = f"{STATE_DIR}/workspace.yaml"
        out: list[tuple[str, str, str]] = []
        for entry in self.scope_drift():
            name, pack = entry["name"], entry["pack"]
            template = entry["template"]
            mine, shipped = entry["here"], entry["shipped"]
            if entry["state"] == "missing":
                out.append(
                    (
                        "warn",
                        name,
                        f"the `{pack}` pack ships scope `{name}` ({', '.join(shipped['repos']) or 'no repository'}) "
                        f"and this workspace does not declare it — `deck --scope {name}` is refused here until it "
                        f"is; copy the block from {template} into `scopes:` in {here}",
                    )
                )
                continue
            if entry["state"] == "local":
                out.append(
                    (
                        "note",
                        name,
                        f"scope `{name}` is this machine's own — the `{pack}` pack does not ship it. Nothing is "
                        f"wrong with that; to make it the team's, add it to `scopes:` in {template}",
                    )
                )
                continue
            for field in entry["fields"]:
                if field == "repos":
                    out.append(
                        (
                            "warn",
                            name,
                            f"scope `{name}` holds different repositories here and in the `{pack}` pack: "
                            f"here {', '.join(mine['repos']) or 'none'}, shipped "
                            f"{', '.join(shipped['repos']) or 'none'} — deck is using this workspace's, so a "
                            f"command run in `{name}` on this machine acts on "
                            f"{', '.join(mine['repos']) or 'nothing'} and on somebody else's it does not. "
                            f"Settle it in `scopes:` in {here} or in {template}",
                        )
                    )
                elif field == "backlog":
                    out.append(
                        (
                            "warn",
                            name,
                            f"scope `{name}` names a different board from the one the `{pack}` pack ships — "
                            f"{_board_diff(mine['backlog'], shipped['backlog'])}; deck is using this "
                            f"workspace's `backlog:`. Settle it in `scopes:` in {here} or in {template}",
                        )
                    )
                else:
                    out.append(
                        (
                            "note",
                            name,
                            f'scope `{name}` is titled "{mine["title"]}" here and "{shipped["title"]}" in the '
                            f"`{pack}` pack — the same repositories either way; deck is using this workspace's",
                        )
                    )
        return out

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

    def scope_problems(self) -> list[str]:
        """Everything wrong with the declared scopes, with the fix in the text.

        A name two packs both ship is here rather than in `scope_drift_notes()`,
        because a divergence is a fact about two carve-ups deck can read and this
        is a carve-up deck refuses to read at all. It is reported at the volume
        the design line gives every collision: two packs claiming one name is a
        mistake to fix, never an ambiguity to rank.
        """
        out: list[str] = list(self.pack_scope_collisions())
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
