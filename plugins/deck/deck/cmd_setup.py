"""`deck setup` — from an unprepared workspace to a working one, in one command.

There are two ways a team arrives here, and they need different things.

    Nothing yet          No packs, no descriptor, nothing prepared. What is
                         missing is not configuration, it is the decision about
                         where knowledge will live. setup makes that decision
                         visible, creates the shape, and stops before guessing.

    Packs already exist   Someone has a pack collection. What is missing is the
                         link between it and this checkout — and that link is a
                         name, not a mapping table.

Both end at the same place: a descriptor, a doctor that passes, and a list of
the two or three things only a person can fill in.
"""

from __future__ import annotations

from pathlib import Path

from . import importers
import os

from .config import ENV_PREFIX, STATE_DIR, core_root, dump_yaml, load_yaml, norm
from .workspace import Workspace, find_root

B, D, R = "\033[1m", "\033[2m", "\033[0m"


def _say(step: str, text: str) -> None:
    print(f"\n{B}{step}{R}  {text}")


def _note(text: str) -> None:
    print(f"{D}   {text}{R}")


# Never a checkout, and the ones that make a build tree expensive to walk.
# `build` itself is not here on purpose: a devtool workspace keeps the sources
# being worked on under it, which is exactly what this has to find.
NOT_A_CHECKOUT = ("node_modules", "sstate-cache", "downloads", "tmp", "dist", "__pycache__")


def _guess_projects(root: Path, depth: int = 4) -> list[Path]:
    """Directories that look like projects: a git repository, or grouping above one.

    Four levels, not three. A `devtool modify` workspace puts the repositories
    someone is actually editing at `build/workspace/sources/<repo>` — depth four
    — so a three-level walk found the whole BSP and missed every source being
    worked on. Descent stops at a repository, so this never walks inside one.
    """
    found: list[Path] = []

    def walk(base: Path, level: int) -> None:
        if level > depth:
            return
        for child in sorted(base.iterdir()):
            if not child.is_dir() or child.name.startswith(".") or child.name in NOT_A_CHECKOUT:
                continue
            if (child / ".git").exists():
                found.append(child)
                continue
            if level < depth:
                walk(child, level + 1)

    try:
        if (root / ".git").exists():
            # One repository. Either a single product, or a monorepo whose real
            # units of change are its packages.
            return _monorepo_units(root) or [root]
        walk(root, 1)
    except OSError:
        pass
    return found


# A directory holding one of these declares itself a package. That is evidence,
# not a guess — which is the standard everything else in deck is held to.
PACKAGE_MARKERS = (
    "package.json",
    "pyproject.toml",
    "setup.py",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "CMakeLists.txt",
    "composer.json",
)


def _monorepo_units(root: Path, depth: int = 2) -> list[Path]:
    """Packages inside one repository, which are its real units of change.

    A monorepo answers "which repositories are there?" with "one", and that
    answer is useless: nothing propagates to itself. What propagates is package
    to package, so those are what the descriptor should hold.

    Only directories that declare themselves a package count, and only below the
    root — a manifest at the root is the repository itself, not a unit within it.
    """
    found: list[Path] = []

    def walk(base: Path, level: int) -> None:
        if level > depth:
            return
        for child in sorted(base.iterdir()):
            if not child.is_dir() or child.name.startswith((".", "_")):
                continue
            if child.name in ("node_modules", "vendor", "build", "dist", "target", "ai-packs"):
                continue
            if any((child / marker).is_file() for marker in PACKAGE_MARKERS):
                found.append(child)
                continue
            walk(child, level + 1)

    try:
        walk(root, 1)
    except OSError:
        return []
    return found if len(found) > 1 else []


def cmd_setup(ws: Workspace, args) -> int:
    root = Path(args.root).resolve() if args.root else (find_root() or Path.cwd())
    descriptor = root / STATE_DIR / "workspace.yaml"

    dry = getattr(args, "dry_run", False)
    print(f"{B}deck setup{R}{'  (discovery — nothing will be written)' if dry else ''}  ·  {root}")

    # A dry run is a discovery pass, and discovery is exactly what you want on a
    # workspace that already has a descriptor: what does deck see here now, and
    # what would it link today. So this guard does not apply to it.
    if descriptor.is_file() and not args.force and not dry:
        print(f"\n  This workspace already has {descriptor}.")
        print("  `deck doctor` says what is missing; `deck setup --force` starts over.")
        return 1

    # ---------------------------------------------------------------- step 1
    _say("1", "What is in this workspace?")
    layouts = importers.detect(root)
    projects = _guess_projects(root)

    if layouts:
        _note(f"assembled with: {', '.join(layouts)} — the registry can be imported")
    monorepo = (root / ".git").exists() and projects != [root]
    if projects:
        if monorepo:
            _note(f"one repository, holding {len(projects)} packages — those are the units of change:")
        else:
            _note(f"{len(projects)} git repositor{'y' if len(projects) == 1 else 'ies'} found:")
        for path in projects[:12]:
            _note(f"  {path.relative_to(root)}")
        if len(projects) > 12:
            _note(f"  … and {len(projects) - 12} more")
    if monorepo:
        _note("")
        _note("A monorepo answers `which repositories are there` with `one`, and that")
        _note("answer is useless — nothing propagates to itself. What propagates is")
        _note("package to package, so the descriptor will hold the packages.")
    if not layouts and not projects:
        print("\n  deck found neither a manifest nor any git repository here.")
        print("  Point it somewhere else with `deck setup --root <path>`, or run it")
        print("  from inside the tree you work in.")
        return 1

    # ---------------------------------------------------------------- step 2
    _say("2", "Where will the knowledge live?")
    packs_root = Path(args.packs_root).expanduser() if args.packs_root else None
    if packs_root is None and dry:
        # Reporting, so any already-given answer will do: the descriptor, or
        # DECK_PACKS_ROOT. Asking again would make the one command that reports
        # on an existing workspace refuse to run on one.
        existing = Workspace(root).packs_roots
        if existing:
            packs_root = existing[0]
            _note(f"already answered: {packs_root}")
    elif packs_root is None and descriptor.is_file():
        # A --force re-run over a workspace that already chose. The environment
        # is deliberately NOT consulted here: on a first run this question has
        # to be answered on purpose, and an inherited DECK_PACKS_ROOT would
        # answer it by accident.
        declared = (load_yaml(descriptor) or {}).get("packs_root")
        first = declared[0] if isinstance(declared, list) and declared else declared
        if first:
            packs_root = Workspace(root).resolve_path(str(first))
            _note(f"already answered, in the descriptor: {first}")

    if packs_root and packs_root.is_dir():
        print(f"   Using the pack collection at {packs_root}.")
        _note("A pack directory named after a repository is that repository's pack.")
        _note("Nothing else has to be declared — the link is the name.")
    elif packs_root:
        print(f"   Creating a pack collection at {packs_root}.")
        _note("One pack per project, named after it, plus `_workspace` for what")
        _note("applies to everything. That naming is the whole linking mechanism.")
    else:
        print("   No pack collection named.")
        _note("Knowledge has to live somewhere a team can review and version, and")
        _note("that is a decision worth making deliberately rather than by default.")
        _note("Re-run with --packs-root <path> — a directory in this workspace, or a")
        _note("separate repository your team shares:")
        _note("")
        _note("   deck setup --packs-root ./ai-packs          # beside the code")
        _note("   deck setup --packs-root ~/work/ai-packs     # a shared repository")
        return 1

    # From here on the packs have to be visible: the template comes from one, and
    # step 4 links them. DECK_PACKS_ROOT outranks the descriptor everywhere else,
    # which is right for an override and is what this command has just been told.
    os.environ[f"{ENV_PREFIX}PACKS_ROOT"] = str(packs_root)

    # ---------------------------------------------------------------- step 3
    _say("3", "Would write the descriptor" if dry else "Writing the descriptor")
    # A pack may carry the shape of descriptor its workspaces have — that is
    # what `deck pack new --from-workspace` writes and what PACKS.md documents
    # it as. setup never read it, so a collection that already knew the answer
    # was ignored and every team retyped it. The most specific pack wins, as
    # everywhere else.
    template = core_root() / "templates" / "workspace" / "workspace.yaml"
    seeded_by = None
    # One lookup, shared with the scopes divergence report: whichever template
    # this resolves to is the one a team's carve-up is measured against, so a
    # second walk here would be a second answer waiting to disagree.
    shipped = Workspace(root).workspace_template()
    if shipped:
        template, seeded_by = shipped
    if not dry:
        (root / STATE_DIR).mkdir(parents=True, exist_ok=True)
        (root / STATE_DIR / "state").mkdir(exist_ok=True)

    if seeded_by:
        _note(f"descriptor shape from the `{seeded_by}` pack, not the generic template")
    data = load_yaml(template) or {}
    data["packs_root"] = str(packs_root if packs_root.is_absolute() else packs_root)
    data.setdefault("packs", [])
    data.setdefault("targets", [])

    registry: dict = {}
    if layouts:
        try:
            registry = importers.load(layouts[0], root)
            _note(f"registry imported from {layouts[0]}: {len(registry)} repositories")
        except KeyError:
            registry = {}
    # A manifest and a working tree answer different questions. The manifest says
    # what the tooling checks out; a `devtool modify` workspace, a submodule
    # someone added by hand, a clone dropped in beside the rest — those are
    # repositories the manifest never mentions and are often exactly the ones
    # being worked on. Taking the manifest and discarding the rest lost five
    # source repositories on the first real setup, and `--repos` then refused
    # names the operator could see on disk.
    known = {norm(entry.get("path", "")) for entry in registry.values()}
    extra = {
        path.name: {"path": str(path.relative_to(root)) or ".", "impacts": []}
        for path in projects
        if norm(str(path.relative_to(root))) not in known and path.name not in registry
    }
    if registry and extra:
        _note(f"{len(extra)} checkout(s) the manifest does not mention, found on disk and kept")
    registry.update(extra)
    if not registry:
        registry = {path.name: {"path": str(path.relative_to(root)) or ".", "impacts": []} for path in projects}
        _note(f"registry built from the git repositories found: {len(registry)}")

    # Curation, at the moment it is cheapest. A `repo` checkout brings the whole
    # BSP: twenty repositories where six are the work. Writing all twenty and
    # pruning afterwards means editing a file deck just generated, and nobody
    # prunes a list they did not choose to make.
    if args.repos:
        wanted = [r.strip() for r in ",".join(args.repos).split(",") if r.strip()]
        unknown = [r for r in wanted if r not in registry]
        if unknown:
            print(f"\n  not found here: {', '.join(unknown)}")
            print(f"  known: {', '.join(sorted(registry))}")
            return 1
        dropped = len(registry) - len(wanted)
        registry = {name: registry[name] for name in wanted}
        _note(f"kept {len(wanted)}, left out {dropped} — the rest are checkouts, not your work")
    data["repos"] = registry
    if not dry:
        dump_yaml(descriptor, data)

    choices = root / STATE_DIR / "toggles.yaml"
    if not dry and not choices.is_file():
        choices.write_text(
            (core_root() / "templates" / "workspace" / "toggles.yaml").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    print(f"   {descriptor}")
    print(f"   {choices}")
    if not dry:
        from .mount import exclude_state

        if exclude_state(root):
            _note(f"{STATE_DIR}/ hidden from this repository's git status (.git/info/exclude)")

    # ---------------------------------------------------------------- step 4
    _say("4", "Linking packs to repositories, by name")
    fresh = Workspace(root)
    per_repo, shared, _by_scope, complaints = fresh.discovered_packs()

    created = []
    if args.create_packs and dry:
        _note("--create-packs would scaffold a pack for every repository without one")
    elif args.create_packs:
        from .cmd_pack import cmd_pack_new

        class _Args:
            force = False
            from_workspace = False
            description = None
            quiet = True

        # `_workspace` first, and not only because step 2 promises it. It is
        # where the gate ladder goes — how this workspace builds and lints is
        # one answer, not one per repository — so a setup that scaffolds four
        # per-repo packs and no shared one leaves the newcomer with nowhere
        # obvious to write the first command they need.
        for name in ["_workspace", *registry]:
            if name in per_repo or (name == "_workspace" and shared):
                continue
            target = packs_root / name
            opts = _Args()
            opts.name, opts.dir = name, str(target)
            opts.from_workspace = name == "_workspace"
            opts.description = (
                "Knowledge that applies to every repository here"
                if name == "_workspace"
                else f"Operating knowledge for {name}"
            )
            cmd_pack_new(fresh, opts)
            created.append(name)
        per_repo, shared, _by_scope, complaints = Workspace(root).discovered_packs()

    matched = sorted(per_repo)
    unmatched = [name for name in registry if name not in per_repo]
    for name in matched:
        print(f"   linked   {name:<34} {per_repo[name]}")
    for name in unmatched[:8]:
        print(f"   {D}no pack {name:<34} create {packs_root / name}{R}")
    if len(unmatched) > 8:
        print(f"   {D}… and {len(unmatched) - 8} more without a pack{R}")
    for shared_pack in shared:
        print(f"   shared   {'(every repository)':<34} {shared_pack}")
    for complaint in complaints:
        print(f"   ! {complaint}")
    if created:
        _note(f"created {len(created)} pack(s); each one is a skeleton to fill in")

    # ---------------------------------------------------------------- step 5
    _say("5", "What only you can fill in")
    todo = []
    if all(not entry.get("impacts") for entry in registry.values()):
        todo.append(
            "The `impacts` edges. A manifest declares a checkout, never a propagation.\n"
            "     Write them, or ask for a draft:  deck propose impacts --repos a b --yes"
        )
    if not data.get("targets"):
        todo.append(
            "The `targets` allowlist. deck denies ssh, scp and http to any host that\n"
            "     is not in it, so an empty list means no deployment and no behaviour gate."
        )
    if unmatched:
        todo.append(
            f"{len(unmatched)} repositor{'y has' if len(unmatched) == 1 else 'ies have'} no pack yet.\n"
            f"     deck pack new <name> --dir {packs_root}/<name>"
        )
    for i, item in enumerate(todo, 1):
        print(f"   {i}. {item}")
    if not todo:
        print("   Nothing. Run `deck doctor`.")

    if dry:
        print(f"\n{B}Nothing written.{R}  Run it again without --dry-run to apply.")
        return 0

    print(f"\n{B}Then{R}")
    print(f"   cd {root} && deck doctor")
    print("   deck impact <repo>          what a change reaches")
    print("   deck toggle list            what is decided, and what will be asked")
    return 0
