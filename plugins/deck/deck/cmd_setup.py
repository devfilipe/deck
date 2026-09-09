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
from . import instructions
import os

from .config import (
    ENV_PREFIX,
    STATE_DIR,
    core_root,
    dump_yaml,
    home_state,
    load_yaml,
    norm,
    selected_scope,
    state_root,
    write_selection,
)
from .workspace import DEFAULT_SCOPE, MACHINE_FILE, Workspace, collection_home, find_root

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


def _packs_only(root: Path, already: Path) -> int:
    """Scaffold a pack for every repository without one, and write nothing else.

    The reachable half of a refused `setup`. It resolves the workspace that is
    already there rather than deriving a new one, so the registry it reads is
    the reviewed one, and it says in its first line that the descriptor is not
    being touched — a command that refused a moment ago and then wrote
    something has to be explicit about what.
    """
    fresh = Workspace(root)
    if not fresh.data:
        print(f"\n  This workspace already has {already}, and deck cannot read it.")
        print("  `deck doctor` says what is missing.")
        return 1
    packs_root = fresh.packs_roots[0] if fresh.packs_roots else None
    if packs_root is None:
        print("\n  No pack collection resolved — `packs_root` names none.")
        print("  `deck doctor` says where it is looked for.")
        return 1

    # No header of its own: `cmd_setup` printed one before the guard ran, and a
    # second would read as two commands. What this line has to say is the part
    # the refusal it replaces would have implied — which file is NOT changing.
    print(f"  --create-packs only. The descriptor is left alone:\n    {fresh.descriptor}")
    print(f"  collection  {packs_root}\n")

    from .cmd_pack import cmd_pack_new

    class _Args:
        force = False
        from_workspace = False
        description = None
        quiet = True

    per_repo, _shared, _by_scope, _ = fresh.discovered_packs()
    missing = [name for name in fresh.repos if name not in per_repo]
    if not missing:
        print("  every repository already has a pack; nothing to create")
        return 0
    for name in missing:
        opts = _Args()
        opts.name, opts.dir = name, str(collection_home(packs_root, name))
        opts.description = f"Operating knowledge for {name}"
        cmd_pack_new(fresh, opts)
        print(f"   created  {name:<34} {collection_home(packs_root, name)}")
    print(f"\n  {len(missing)} pack(s) created; each one is a skeleton to fill in")
    print("  deck packs        the merge order they now sit in")
    print("  deck propose pack <name>   a draft, read from the repository itself")
    return 0


def cmd_setup(ws: Workspace, args) -> int:
    # Without the selection, and for the same reason `deck init` is: setup makes
    # a workspace out of the tree you are standing in, and a pair selected
    # elsewhere answering for it would set up the wrong one in silence.
    root = Path(args.root).resolve() if args.root else (find_root(use_selection=False) or Path.cwd())

    dry = getattr(args, "dry_run", False)
    print(f"{B}deck setup{R}{'  (discovery — nothing will be written)' if dry else ''}  ·  {root}")

    # A dry run is a discovery pass, and discovery is exactly what you want on a
    # workspace that already has a descriptor: what does deck see here now, and
    # what would it link today. So this guard does not apply to it.
    # Where the descriptor ends up depends on whether a collection is named, and
    # that is not known yet. What IS known is whether this machine has been set
    # up before, and `.deck/` is the answer either way: it holds the machine file
    # in one shape and the descriptor itself in the other.
    # Both places. A workspace set up with a collection keeps its machine file
    # under `~/.deck` and its project tree carries nothing — and that is
    # exactly the workspace a second `setup` must still refuse to overwrite.
    # Resolved once, up here: step 2 names the layer it is about to create and
    # step 3 writes the descriptor into it, and the two have to agree.
    workspace_name = getattr(args, "workspace", None)
    if not workspace_name:
        # The selection, when it names THIS root. Falling straight to the
        # directory name meant a second `setup` in a configured workspace did
        # not recognise it: `tmd400g-sx-yocto` on disk, `tmd400g-sx` as the
        # name, so the guard found nothing and the run would have written a
        # parallel workspace beside the real one. Checked against the root, so
        # a selection made in another tree still answers for that tree.
        chosen = selected_scope()
        if chosen:
            here = chosen.split("/")[0]
            declared = (load_yaml(home_state() / "workspaces" / here / MACHINE_FILE) or {}).get("root")
            if declared and Path(str(declared)).resolve() == root.resolve():
                workspace_name = here
    workspace_name = workspace_name or root.name
    named = home_state() / "workspaces" / workspace_name / MACHINE_FILE
    found = next(
        ((root / STATE_DIR / f) for f in ("machine.yaml", "workspace.yaml") if (root / STATE_DIR / f).is_file()), None
    )
    # State is keyed by the workspace's NAME, so a second workspace whose
    # directory happens to be called the same thing would write over the first
    # one's evidence and mounts without either of them being wrong about
    # anything. Refused, with the name to change — two fixtures called `ws`
    # found this, and two checkouts called `build` would find it in earnest.
    if named.is_file() and not dry:
        other = (load_yaml(named) or {}).get("root")
        if other and Path(str(other)).resolve() != root.resolve():
            print(f"\n  The workspace name `{named.parent.name}` is taken, by {other}.")
            print("  State is keyed by the name, so two of them would share evidence and mounts.")
            print("  Pass --workspace <another name>.")
            return 1
    already = found or (named if named.is_file() else None)
    if already and not args.force and not dry:
        # The refusal protects the DESCRIPTOR, which is the destructive half:
        # overwriting a registry, edges and scopes that a team reviewed. It
        # never had a reason to protect the packs, and refusing both made
        # `--create-packs` unreachable on the ordinary case — a workspace that
        # already works gains a repository, and that repository needs a pack.
        # The dry run planned that work and the real run declined to do any of
        # it, which is the mismatch this branch exists to end.
        if args.create_packs:
            return _packs_only(root, already)
        print(f"\n  This workspace already has {already}.")
        print("  `deck doctor` says what is missing; `deck setup --force` starts over.")
        print("  To give a repository that has no pack one, without touching the")
        print("  descriptor:  deck setup --create-packs")
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
    # The one moment somebody is deciding what this workspace contains — so the
    # instruction files nobody declared are named here, not left for whoever
    # eventually notices an agent obeying something no pack says.
    loose = instructions.unmanaged(Workspace(root), extra=projects)
    if loose:
        _note("")
        _note(f"{len(loose)} instruction file(s) deck does not manage, loaded anyway:")
        for entry in loose:
            _note(f"  {instructions.describe(entry)}")
        _note("deck places nothing over these and never reads them. Decide whether")
        _note("each one belongs in a pack.")

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
    elif packs_root is None and already:
        # A --force re-run over a workspace that already chose. The environment
        # is deliberately NOT consulted here: on a first run this question has
        # to be answered on purpose, and an inherited DECK_PACKS_ROOT would
        # answer it by accident. `machine.yaml` carries the answer in the shape
        # this writes now, `workspace.yaml` in the shape it used to.
        declared = (load_yaml(state_root(root) / already) or {}).get("packs_root")
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
        _note("`_repos/<name>` per project, named after it, plus")
        _note(f"`_workspaces/{workspace_name}/default` for what applies to every repository.")
        _note("Where a pack sits is the whole linking mechanism.")
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
    # The descriptor is the team's: the registry, the edges, the carve-up. It
    # belongs in the collection, versioned and reviewed, in the layer that names
    # the workspace — pointing deck at `_workspaces/<name>/default/workspace.yaml`
    # IS saying which workspace this is, so the identity needs no key of its own.
    #
    # Three fields cannot go with it, and `pack new --from-workspace` already
    # names them: `packs_root`, `paths` and `targets` are one person's answers.
    # They go to `.deck/machine.yaml`, which is never versioned.
    #
    # Without a collection there is nowhere for the first half to live, so the
    # descriptor stays under the root exactly as it always did. That is somebody
    # on their first day, and nothing about it needs explaining to them.
    if packs_root:
        descriptor = packs_root / "_workspaces" / workspace_name / "default" / "workspace.yaml"
    else:
        descriptor = state_root(root) / "workspace.yaml"
    # Somebody joining a workspace the team already set up has the collection —
    # it is in git — and needs only the machine half. `setup` did not look, so
    # it rewrote the descriptor from a fresh discovery: measured, a second
    # person's first command turned the team's `impacts: [r2]` into
    # `impacts: []`. It is versioned, so `git diff` would show it, but nothing
    # said anything and nobody diffs a file they were told was being created.
    joining = bool(packs_root) and descriptor.is_file() and not args.force
    _say(
        "3",
        "Would write the descriptor"
        if dry and not joining
        else "Joining a workspace that already has a descriptor"
        if joining
        else "Writing the descriptor",
    )
    if joining:
        _note(f"the descriptor is already in the collection — left exactly as it is:\n   {descriptor}")
        _note("`deck setup --force` would replace it with a fresh discovery, and that")
        _note("is what it sounds like: the registry, the edges and the scopes, gone.")
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

    if seeded_by:
        _note(f"descriptor shape from the `{seeded_by}` pack, not the generic template")
    data = load_yaml(template) or {}
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

    # Decided HERE, once, so the plan a --dry-run prints is the path the run
    # writes. It was computed twice — `state_root(root)` for the report and the
    # real destination inside `if not dry:` — and on a dry run the report named
    # `<project>/.deck/machine.yaml`, a file setup has not written since machine
    # state moved to the home directory. A plan that does not match the run is
    # the one kind of output that is worse than no output.
    #
    # Computed, not resolved. `state_root` answers where state ALREADY is, and
    # it will not name a home directory holding no machine file — so on a first
    # setup it falls back to the project. Naming the place by the workspace's
    # name is the same answer without the first-write hole.
    machine = (
        home_state() / "workspaces" / workspace_name / MACHINE_FILE if packs_root else state_root(root) / MACHINE_FILE
    )
    if packs_root:
        # The three fields leave the descriptor, so it can be versioned at all.
        # `targets` is emptied rather than dropped, in both files: the descriptor
        # is not the place for an allowlist, and the machine file has to show a
        # newcomer where theirs goes.
        machine_data = {
            # Where the project is, because nothing in the project says so any
            # more. Keyed by the workspace's name in `~/.deck`, so moving the
            # checkout costs this line and nothing else.
            "root": str(root),
            "packs_root": str(packs_root),
            "paths": data.pop("paths", None) or {},
            "targets": [],
        }
        data.pop("packs_root", None)
        data.pop("targets", None)
        _note(f"workspace `{workspace_name}` — the layer the descriptor names, and its identity")
    if not dry:
        descriptor.parent.mkdir(parents=True, exist_ok=True)
        if not joining:
            dump_yaml(descriptor, data)
        if packs_root:
            # The selection comes FIRST, and the order is not cosmetic: every
            # state path is keyed by the selected workspace, so writing the
            # machine file before selecting put it in the project — the one
            # place this change exists to empty. Measured, not guessed.
            #
            # Selected at all because a workspace nobody is in acts on nothing.
            write_selection(f"{workspace_name}/default")
            machine.parent.mkdir(parents=True, exist_ok=True)
            (machine.parent / "state").mkdir(exist_ok=True)
            dump_yaml(machine, machine_data)
        else:
            # No collection, so no name to key state by: it stays under the root
            # with the descriptor, which is where somebody on their first day
            # would look for it.
            state_root(root).mkdir(parents=True, exist_ok=True)
            (state_root(root) / "state").mkdir(exist_ok=True)

    # Beside the machine file, for the same reason and by the same path.
    choices = machine.parent / "toggles.yaml" if packs_root else state_root(root) / "toggles.yaml"
    if not dry and not choices.is_file():
        choices.write_text(
            (core_root() / "templates" / "workspace" / "toggles.yaml").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    print(f"   {descriptor}")
    if packs_root:
        print(f"   {machine}   {D}(yours: packs_root, paths, targets){R}")
        print(f"   {D}selected {workspace_name}/default{R}")
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

        # The workspace's own layer first, and not only because step 2 promises
        # it. It is where the gate ladder goes — how this workspace builds and
        # lints is one answer, not one per repository — so a setup that
        # scaffolds four per-repo packs and no shared one leaves the newcomer
        # with nowhere obvious to write the first command they need.
        #
        # `<name>/default`, not `all/default`: it is the directory the
        # descriptor was just written into and the one the `shared (every
        # repository)` line below points at. `all/default` is the layer for
        # knowledge that outlives this workspace, and a first setup has none.
        base = f"{workspace_name}/{DEFAULT_SCOPE}"
        for name in [base, *registry]:
            if name in per_repo:
                continue
            target = collection_home(packs_root, name)
            # Asked of THIS layer, not of whether any shared layer was found.
            # Writing the descriptor into `_workspaces/<name>/default` makes
            # that directory a discovered layer, so a `shared` that is merely
            # non-empty suppressed the scaffold that was supposed to fill it —
            # setup announced a shared pack and created a directory holding one
            # file, with no `config/` to declare a workspace-wide gate in.
            if name == base and (target / "config").is_dir():
                continue
            opts = _Args()
            opts.name, opts.dir = name, str(target)
            # The descriptor already sits in this directory, and `pack new`
            # refuses a non-empty one. It writes a fixed set of files and never
            # `workspace.yaml`, so forcing here adds the skeleton beside the
            # descriptor rather than over it.
            opts.force = name == base
            opts.from_workspace = name == base
            opts.description = (
                "Knowledge that applies to every repository here" if name == base else f"Operating knowledge for {name}"
            )
            cmd_pack_new(fresh, opts)
            created.append(name)
        per_repo, shared, _by_scope, complaints = Workspace(root).discovered_packs()

    matched = sorted(per_repo)
    unmatched = [name for name in registry if name not in per_repo]
    for name in matched:
        print(f"   linked   {name:<34} {per_repo[name]}")
    for name in unmatched[:8]:
        # `collection_home`, not `packs_root / name`. Step 2 announces
        # `_repos/<name>` and the real run writes it; a plan that printed the
        # flat path contradicted the announcement six lines above it, and sent
        # somebody to create a directory the engine no longer reads.
        print(f"   {D}no pack {name:<34} create {collection_home(packs_root, name)}{R}")
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
            "The `targets` allowlist. A gate may only name a target declared here,\n"
            "     so an empty list means no deployment and no behaviour gate."
        )
    if unmatched:
        todo.append(
            f"{len(unmatched)} repositor{'y has' if len(unmatched) == 1 else 'ies have'} no pack yet.\n"
            f"     deck pack new <name> --dir {packs_root}/_repos/<name>"
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
