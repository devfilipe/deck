"""Workspace commands: where things are, and what a change reaches."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from . import importers
from .config import ENV_PREFIX, STATE_DIR, core_root, die, dump_yaml, load_yaml, norm
from .workspace import SHARED_NAMES, Workspace, find_root


def require_root() -> Path:
    root = find_root()
    if not root:
        die(
            "workspace root not resolved. Use one of these, in order:\n"
            f"  1. export {ENV_PREFIX}ROOT=/path/to/your/workspace\n"
            f"  2. create {STATE_DIR}/workspace.yaml at the root (deck init)\n"
            "  3. run from inside the tree, with a pack that declares detection markers\n"
            "  4. answer `workspace_root` when installing the plugin"
        )
    return root


def cmd_root(ws: Workspace, args) -> int:
    print(require_root())
    return 0


def cmd_info(ws: Workspace, args) -> int:
    root = require_root()
    if args.json:
        print(
            json.dumps(
                {
                    "root": str(root),
                    "source": ws.source,
                    "descriptor": bool(ws.data),
                    "repos": list(ws.repos),
                    "scope": ws.scope_name,
                    "scopes": list(ws.scopes),
                    "targets": ws.targets,
                    "packs_roots": [str(p) for p in ws.packs_roots],
                    "packs": [str(p) for p in ws.all_packs()],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"root       : {root}")
    print(f"source     : {ws.source}")
    print(f"descriptor : {'present' if ws.data else 'MISSING — run: deck init'}")
    if not ws.data:
        return 0
    packs = ws.all_packs()
    if packs:
        print(f"packs      : {', '.join(p.name for p in packs)}")
    if ws.scopes:
        print(f"scopes     : {', '.join(ws.scopes)}")
    if ws.scope_name:
        print(f"scope      : {ws.scope_name}   (from --scope or ${ENV_PREFIX}SCOPE)")

    shown = ws.selected_repos()
    heading = f"repositories in scope {ws.scope_name}" if ws.scope_name else "repositories"
    count = f"{len(shown)} of {len(ws.repos)}" if ws.scope_name else str(len(shown))
    print(f"\n{heading} ({count}):")
    for name in shown:
        entry = ws.repos.get(name) or {}
        tag = "  [downstream]" if entry.get("downstream") else ""
        print(f"  {name}{tag}")
        if entry.get("role"):
            print(f"      {entry['role']}")
    if ws.scope_name:
        # The two leaks a scope has, printed apart. Merging them would give the
        # coupled half an order it does not have; leaving the second one out is
        # what made this report disagree with `deck impact`.
        leaks = ws.scope_leaks()
        coupled = ws.scope_coupled()
        if leaks or coupled:
            print()
        if leaks:
            print(f"  reaches outside the scope: {', '.join(leaks)}")
        if coupled:
            print(f"  coupled outside the scope: {', '.join(coupled)}   (mutual, in no order)")
    print(f"\ntargets ({len(ws.targets)}):")
    for t in ws.targets:
        print(f"  {t.get('host')}  {t.get('role', '')}  alias={t.get('alias', '—')}")
    return 0


def cmd_repos(ws: Workspace, args) -> int:
    require_root()
    for name in ws.selected_repos():
        entry = ws.repos.get(name) or {}
        if args.downstream_only and not entry.get("downstream"):
            continue
        if args.buildable_only and entry.get("downstream"):
            continue
        if args.verbose:
            print(f"{name}\t{entry.get('path', '')}\t{entry.get('build_target', '')}")
        else:
            print(name)
    return 0


def cmd_path(ws: Workspace, args) -> int:
    require_root()
    print(ws.repo_path(args.repo))
    return 0


def cmd_get(ws: Workspace, args) -> int:
    require_root()
    node = ws.data
    for part in args.key.split("."):
        if isinstance(node, list):
            try:
                node = node[int(part)]
                continue
            except (ValueError, IndexError):
                die(f"invalid index in `{args.key}`: {part}")
        if not isinstance(node, dict) or part not in node:
            die(f"no such key in the descriptor: {args.key}")
        node = node[part]
    print(json.dumps(node, ensure_ascii=False) if isinstance(node, (dict, list)) else norm(node))
    return 0


def cmd_targets(ws: Workspace, args) -> int:
    require_root()
    if args.json:
        print(json.dumps(ws.targets, ensure_ascii=False, indent=2))
        return 0
    if not ws.targets:
        print("no targets declared — the allowlist guard denies every host")
        return 0
    for t in ws.targets:
        print(f"{t.get('host')}\t{t.get('role', '')}\t{t.get('alias', '')}")
    return 0


def cmd_impact(ws: Workspace, args) -> int:
    require_root()
    affected = ws.impacted(args.repo)
    chain = ws.order([args.repo] + affected)
    # Reported apart from `chain`, never merged into it. Both halves answer
    # "what must I revisit"; only the chain also answers "in what order", and
    # printing them as one list would attach an order to the half that has none.
    coupled = ws.coupled(args.repo)
    if args.json:
        print(
            json.dumps(
                {
                    "repo": args.repo,
                    "impacted": affected,
                    "order": chain,
                    "coupled": coupled,
                    "scope": ws.scope_name,
                    "outside_scope": [n for n in chain if not ws.in_scope(n)] if ws.scope_name else [],
                    "build_targets": ws.build_targets(chain),
                    "downstream": [n for n in affected if ws.repos.get(n, {}).get("downstream")],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"a change in {args.repo} reaches {len(affected)} repositor{'y' if len(affected) == 1 else 'ies'}\n")
    print("execution order:")
    outside = []
    for i, name in enumerate(chain, 1):
        entry = ws.repos.get(name, {})
        tag = "  (downstream — keep up, does not build)" if entry.get("downstream") else ""
        target = f"  build {entry['build_target']}" if entry.get("build_target") and not entry.get("downstream") else ""
        # A scope narrows what a command acts on; it never narrows the graph.
        # Hiding a repository a change actually reaches would turn the one
        # answer deck exists to give into a comfortable lie.
        mark = ""
        if ws.scope_name and not ws.in_scope(name):
            mark = "  [outside scope]"
            outside.append(name)
        print(f"  {i}. {name}{tag}{target}{mark}")
    if outside:
        one = len(outside) == 1
        print(
            f"\n  {len(outside)} of these {'is' if one else 'are'} outside scope {ws.scope_name}, "
            f"and still {'has' if one else 'have'} to be kept up."
        )

    if coupled:
        print("\ncoupled with, in no order:")
        for name in coupled:
            sides = ws.coupling_sides(args.repo, name)
            how = "declared on both sides" if len(sides) == 2 else f"declared by {sides[0]}"
            entry = ws.repos.get(name, {})
            role = f"  {entry['role']}" if entry.get("role") else ""
            mark = "  [outside scope]" if ws.scope_name and not ws.in_scope(name) else ""
            print(f"  - {name}{role}{mark}   ({how})")
        print("\n  A coupling is mutual and carries no order: revisit these, do not sequence them.")
        print("  They take no part in the execution order above, and never in a build order.")
    return 0


def cmd_order(ws: Workspace, args) -> int:
    require_root()
    for name in ws.order(args.repos):
        print(name)
    return 0


def cmd_init(ws: Workspace, args) -> int:
    """Create `.deck/` from the templates the core and the packs provide.

    The one command for which `require_root()` is a circle. Resolution's second
    option is "create .deck/workspace.yaml at the root (deck init)", which is
    what somebody just ran — so the first command anyone tries answered them
    with itself, and the only option that worked was the one they were least
    likely to pick. `deck setup` never had this problem.

    With nothing resolved, `init` initialises where it was run. That is what
    running it there asked for, and it is the only interpretation available: the
    other three sources are a variable nobody set, a pack nobody has, and a
    plugin nobody installed. The directory is printed, because choosing one in
    silence is how a `.deck/` ends up three levels above where it was meant.
    """
    root = find_root()
    if root is None:
        root = Path.cwd().resolve()
        print(f"no workspace root resolved; initialising {root}")
    elif root != Path.cwd().resolve() and not (root / STATE_DIR).is_dir():
        # Resolved by a marker or by the environment, not by an existing
        # `.deck/`. Saying which directory is about to gain one is cheap.
        print(f"initialising {root}")
    dest = root / STATE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "state").mkdir(exist_ok=True)

    # A pack's template wins over the core's: it knows the shape of this
    # workspace, while the core only knows the format.
    # A scope-bound pack is skipped: its template holds one initiative's
    # definition, and seeding a workspace's registry out of whichever initiative
    # happened to be active would be a descriptor nobody meant to write.
    sources = [core_root() / "templates" / "workspace"]
    for pack in ws.all_packs():
        candidate = pack / "templates" / "workspace"
        if candidate.is_dir() and not ws.pack_scope(pack):
            sources.append(candidate)

    created, kept = [], []
    for name in ("workspace.yaml", "toggles.yaml"):
        origin = None
        for src in sources:
            if (src / name).is_file():
                origin = src / name
        if not origin:
            continue
        target = dest / name
        if target.exists() and not args.force:
            kept.append(name)
            continue
        shutil.copyfile(origin, target)
        created.append((name, origin))

    for name, origin in created:
        print(f"created {dest / name}   (from {origin.parent.parent.parent.name})")
    for name in kept:
        print(f"kept    {dest / name}   (use --force to overwrite)")
    if created:
        print("\nReview the descriptor before relying on it: paths, `impacts`, and `targets`.")
        print(f"  {dest / 'workspace.yaml'}")

    if args.from_source is not None:
        print()
        args.source, args.write = args.from_source or None, True
        return cmd_import(ws, args)
    elif importers.detect(root):
        found = ", ".join(importers.detect(root))
        print(f"\nThis tree looks like it is assembled with: {found}")
        print(f"  deck import {found.split(',')[0]}          # see what it would add")
        print(f"  deck import {found.split(',')[0]} --write  # fold it into the descriptor")
    return 0


def cmd_import(ws: Workspace, args) -> int:
    """Derive the repository registry from how the tree is assembled."""
    root = require_root()

    available = importers.detect(root)
    source = args.source
    if not source:
        if not available:
            die(
                "nothing to import from. deck reads a Google `repo` manifest "
                "(.repo/), git submodules (.gitmodules) or npm workspaces."
            )
        if len(available) > 1:
            die(f"several layouts found ({', '.join(available)}). Pick one: deck import {available[0]}")
        source = available[0]

    try:
        imported = importers.load(source, root)
    except KeyError:
        die(f"unknown source: {source} (known: {', '.join(importers.SOURCES)})")
    if not imported:
        die(f"`{source}` found no repositories under {root}")

    descriptor_path = root / STATE_DIR / "workspace.yaml"
    descriptor = load_yaml(descriptor_path)
    registry, added, dropped = importers.merge(descriptor.get("repos") or {}, imported)

    if not args.write:
        print(f"{source}: {len(imported)} repositor{'y' if len(imported) == 1 else 'ies'} under {root}\n")
        for name, entry in imported.items():
            print(f"  {name:<34} {entry.get('path', '')}")
        print(f"\n  {len(added)} new, {len(dropped)} in the descriptor but not in the layout")
        print("  Nothing written. Re-run with --write to fold this into the descriptor.")
        print("\n  `impacts` is left empty on purpose: a manifest says how the tree is")
        print("  assembled, never what a change propagates to. That part is yours.")
        return 0

    if not descriptor:
        die(f"no descriptor at {descriptor_path} — run `deck init` first")

    descriptor["repos"] = registry
    dump_yaml(descriptor_path, descriptor)
    print(f"{descriptor_path}: {len(added)} added, {len(registry)} total")
    for name in added:
        print(f"  + {name}")
    if dropped:
        print(f"\n  kept but not in the layout ({len(dropped)}): {', '.join(dropped)}")
    missing = [n for n, e in registry.items() if not e.get("impacts")]
    if missing:
        print(f"\n  {len(missing)} repositor{'y has' if len(missing) == 1 else 'ies have'} no `impacts` yet.")
        print("  Until those edges are written, a plan cannot know what a change reaches.")
    return 0


def _pack_contribution(pack: Path) -> dict:
    """What one pack puts into the merge."""
    mount = load_yaml(pack / "config" / "mount.yaml")
    return {
        "toggles": [str(t.get("id")) for t in (load_yaml(pack / "config" / "toggles.yaml").get("toggles") or [])],
        "gates": [str(g.get("id")) for g in (load_yaml(pack / "config" / "gates.yaml").get("gates") or [])],
        "rules": len(mount.get("rules") or []),
        "plugin": mount.get("plugin"),
        "markers": [str(m) for m in (load_yaml(pack / "config" / "detect.yaml").get("markers") or [])],
    }


def cmd_packs(ws: Workspace, args) -> int:
    """The composition: which packs are in play, in what order, and who overrides whom.

    Layering that nobody can see is layering nobody can debug. This is the view
    that answers, in one screen, the three questions a collection raises once it
    has more than one layer: what is loaded, in which order it merges, and which
    entries a later pack took over from an earlier one.
    """
    require_root()
    packs = ws.all_packs() if ws.root else []
    owner = ws.pack_owner()
    problems = ws.pack_problems()

    if args.repo:
        if args.repo not in ws.repos:
            die(f"unknown repository in descriptor: {args.repo}")
        packs = ws.packs_for(args.repo)

    rows = []
    declared: dict[str, list[str]] = {}
    for pack in packs:
        contribution = _pack_contribution(pack)
        scope = owner.get(pack.resolve())
        bound = ws.pack_scope(pack)
        if bound:
            where = f"scope {bound}"
        elif scope:
            where = scope
        else:
            where = "every repository" if pack.name in SHARED_NAMES else "workspace (named)"
        rows.append(
            {
                "name": pack.name,
                "path": str(pack),
                "scope": where,
                "bound_to": bound,
                "requires": ws.pack_requires(pack),
                **contribution,
            }
        )
        for kind, ids in (("toggle", contribution["toggles"]), ("gate", contribution["gates"])):
            for entry_id in ids:
                declared.setdefault(f"{kind}\t{entry_id}", []).append(pack.name)

    overlaid = [
        {"kind": key.split("\t")[0], "id": key.split("\t")[1], "packs": names}
        for key, names in declared.items()
        if len(names) > 1
    ]
    # A pack bound to an initiative nobody is working in loads for no one, and
    # a pack that loads for no one and appears in no listing is knowledge nobody
    # can find. Listed apart from the rows above, because these contribute
    # nothing to this session and folding them in would misreport the merge.
    dormant = [
        {"name": pack.name, "path": str(pack), "scope": name, **_pack_contribution(pack)}
        for pack, name in ws.dormant_packs()
    ]

    if args.json:
        print(
            json.dumps(
                {"packs": rows, "overlaid": overlaid, "dormant": dormant, "problems": problems},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    if not rows and not dormant:
        print("no packs in play")
        print("  Point at one with DECK_PACKS_ROOT=/path/to/collection, or list it under")
        print("  `packs:` in the descriptor. Create one with `deck pack new <name>`.")
        return 0
    if rows:
        scope_note = f" for {args.repo}" if args.repo else ""
        print(f"packs   {len(rows)} in play{scope_note}, merged most general first\n")
        for i, row in enumerate(rows, 1):
            gives = f"{len(row['toggles'])} toggle(s) · {len(row['gates'])} gate(s) · {row['rules']} rule(s)"
            print(f"  {i}  {row['name']:<28} {row['scope']:<20} {gives}")
            print(f"     {row['path']}")
            if row["requires"]:
                print(f"     requires {', '.join(row['requires'])}")
            if row["markers"]:
                print(f"     markers  {', '.join(row['markers'])}")
    else:
        print("no pack is in play here")

    if dormant:
        print("\nnot in play   bound to an initiative, and loaded only while it is active")
        for row in dormant:
            gives = f"{len(row['toggles'])} toggle(s) · {len(row['gates'])} gate(s) · {row['rules']} rule(s)"
            print(f"  {row['name']:<28} scope {row['scope']:<14} {gives}")
            print(f"     {row['path']}")
            print(f"     bring it in with: deck --scope {row['scope']} <command>")

    if overlaid:
        print("\noverlaid   a later pack takes over an entry an earlier one declared")
        for item in overlaid:
            print(f"  {item['kind']:<7} {item['id']:<24} {' -> '.join(item['packs'])}")

    if ws.packs_roots:
        print("\nroots")
        for root in ws.packs_roots:
            mark = "" if root.is_dir() else "   (does not exist)"
            print(f"  {root}{mark}")

    if problems:
        print(f"\n{len(problems)} problem(s)")
        for problem in problems:
            print(f"  !! {problem}")
        return 1
    return 0


def _scope_row(ws: Workspace, name: str) -> dict:
    scope = ws.scopes.get(name) or {}
    sources = scope.get("backlog") or []
    return {
        "name": name,
        "title": scope.get("title", ""),
        "repos": ws.scope_repos(name),
        "declared": [norm(r) for r in (scope.get("repos") or [])],
        "board": [norm(src.get("file", "")) or norm(src.get("type", "")) for src in sources],
        "own_board": bool(sources),
        "reaches_outside": ws.scope_leaks(name),
        "coupled_outside": ws.scope_coupled(name),
        "active": name == ws.scope_name,
    }


def cmd_scopes(ws: Workspace, args) -> int:
    """The declared scopes: what each holds, where its board is, what it leaks."""
    require_root()
    rows = [_scope_row(ws, name) for name in ws.scopes]
    problems = ws.scope_problems()
    # Reported here as well as in `deck doctor`, and the argument is who is
    # reading. `doctor` is opened when something is already wrong; this is the
    # view opened while CHOOSING which initiative to work in, which is the last
    # moment before the divergence turns into work done over the wrong set. A
    # finding only `doctor` carries is a finding you have to already suspect.
    drift = [{"scope": name, "severity": sev, "note": text} for sev, name, text in ws.scope_drift_notes()]

    if args.json:
        print(
            json.dumps(
                {"active": ws.scope_name, "scopes": rows, "problems": problems, "drift": drift},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    if not rows and not drift:
        print("no scopes declared — every command runs over the whole registry")
        print("  A scope names a subset of `repos:` and gives it a board and a posture of")
        print("  its own. Declare one under `scopes:` in the descriptor:")
        print("\n    scopes:")
        print("      payments:")
        print("        title: Payments migration")
        print("        repos: [api-schema, api-server]")
        print("        backlog: [{ type: tasks, file: docs/board-payments.yaml }]")
        return 0

    print(f"scopes   {len(rows)} declared\n")
    for row in rows:
        mark = "*" if row["active"] else " "
        board = "own board" if row["own_board"] else "workspace board, narrowed"
        print(
            f" {mark} {row['name']:<20} {len(row['repos'])} repositor{'y' if len(row['repos']) == 1 else 'ies'}"
            f" · {board}"
        )
        if row["title"]:
            print(f"     {row['title']}")
        print(f"     {', '.join(row['repos']) or '(none that the registry declares)'}")
        if row["reaches_outside"]:
            print(f"     reaches outside: {', '.join(row['reaches_outside'])}")
        if row["coupled_outside"]:
            print(f"     coupled outside: {', '.join(row['coupled_outside'])}   (mutual, in no order)")
        # Under the scope it is about, not in a block at the end: the reader is
        # looking at this scope's repository list, and "the pack ships another
        # one" belongs beside the list it contradicts.
        for entry in drift:
            if entry["scope"] == row["name"]:
                print(f"     {'!!' if entry['severity'] == 'warn' else '..'} {entry['note']}")
    print("\n  * = active in this session   ·   deck --scope <name> <command>")
    # What is left is what has no row: a scope the pack ships and this machine
    # has never declared. It has no repository list here to sit under.
    for entry in drift:
        if entry["scope"] not in ws.scopes:
            print(f"  {'!!' if entry['severity'] == 'warn' else '..'} {entry['note']}")
    for problem in problems:
        print(f"  !! {problem}")
    # A divergence changes no exit code. deck works on both sides of one, and a
    # non-zero here would fail every team with an initiative of its own.
    return 1 if problems else 0


def cmd_scope(ws: Workspace, args) -> int:
    """One scope in full: its subset, its board, its posture, and what it leaks."""
    require_root()
    if args.name not in ws.scopes:
        shipped, origins = ws.pack_scopes()
        if args.name in shipped:
            pack = (origins.get(args.name) or {}).get("pack")
            die(
                f"scope {args.name} is not declared on this machine, but the `{pack}` pack ships it "
                f"({', '.join(str(r) for r in (shipped[args.name] or {}).get('repos') or []) or 'no repository'}) — "
                f"add it under `scopes:` in {STATE_DIR}/workspace.yaml"
            )
        die(f"unknown scope: {args.name} (declared: {', '.join(ws.scopes) or 'none'})")
    row = _scope_row(ws, args.name)
    drift = [(sev, text) for sev, name, text in ws.scope_drift_notes() if name == args.name]
    recorded = (load_yaml(ws.root / STATE_DIR / "toggles.yaml").get("scopes") or {}).get(args.name) or {}
    if args.json:
        print(
            json.dumps(
                {**row, "posture": recorded, "drift": [{"severity": s, "note": n} for s, n in drift]},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"{args.name}  {row['title']}\n")
    print(f"  repositories  {len(row['repos'])} of {len(ws.repos)}")
    for name in ws.order(row["repos"]):
        entry = ws.repos.get(name) or {}
        tag = "  (downstream)" if entry.get("downstream") else ""
        print(f"      {name + tag:<28} {entry.get('role', '')}".rstrip())
    missing = [r for r in row["declared"] if r not in row["repos"]]
    if missing:
        print(f"      !! not in the registry: {', '.join(missing)}")
    # Directly under the list it is a claim about. This is the view that shows a
    # scope whole, and "the team ships this scope holding something else" is not
    # a smaller fact about it than which repositories are in it.
    for severity, sentence in drift:
        print(f"      {'!!' if severity == 'warn' else '..'} {sentence}")

    if row["reaches_outside"]:
        print(f"\n  reaches       {', '.join(row['reaches_outside'])}   (outside the scope, still has to keep up)")
    elif row["coupled_outside"]:
        print("\n  reaches       nothing outside itself through `impacts:`")
    else:
        print("\n  reaches       nothing outside itself — the boundary is closed")
    # A coupling is the other way a boundary leaks, and the claim above is only
    # about `impacts:`. Printed as its own line because it carries no order,
    # and never folded into `reaches` for the same reason `deck impact` keeps
    # the two lists apart.
    if row["coupled_outside"]:
        print(f"  coupled with  {', '.join(row['coupled_outside'])}   (outside the scope, mutual and in no order)")
        print("                revisit them before shipping, do not sequence them — or")
        print(f"                take them into the scope, under `repos:` beside the {len(row['repos'])} above")

    print("\n  board         " + (", ".join(row["board"]) if row["own_board"] else "the workspace board, narrowed"))
    if recorded.get("profile"):
        print(f"  profile       {recorded['profile']}")
    if recorded.get("values"):
        from .toggles import record_hint, recorded_reasons  # late: the cheap views build no catalog

        print("  posture")
        # A posture is the part of a scope somebody argued about. Printing the
        # values alone left the argument in the file and out of the only view
        # that shows the scope whole — and `--json` has carried the `reasons:`
        # block verbatim all along, so the text form was the odd one out.
        reasons = recorded_reasons(recorded)
        origin = f"scope {args.name}"
        for tid, value in recorded["values"].items():
            print(f"      {tid:<22} {value}")
            reason = reasons.get(tid)
            print(
                f"        why  {reason}" if reason else f"        why  not recorded — {record_hint(tid, value, origin)}"
            )
    if not recorded:
        print("  posture       none recorded — it inherits the workspace's")
        print(f"                deck toggle set --at {args.name} <id> <value>")

    from .toggles import Toggles  # late: the cheap views should not build a catalog

    tg = Toggles(root=ws.root)
    unknown = [tid for tid in (recorded.get("values") or {}) if tid not in tg.defs]
    if unknown:
        print(f"\n  !! recorded for toggles the catalog does not declare: {', '.join(unknown)}")
    print(f"\n  work in it:   deck --scope {args.name} board plan")
    return 0


def cmd_paths(ws: Workspace, args) -> int:
    """Named directories the workspace uses but does not change."""
    require_root()
    paths = ws.paths
    if args.json:
        print(json.dumps({k: str(v) for k, v in paths.items()}, ensure_ascii=False, indent=2))
        return 0
    if not paths:
        print("no paths declared")
        print("  A gate that needs a directory outside this workspace — a tools checkout, a")
        print("  scripts directory — should name it under `paths:` in the descriptor and use")
        print("  ${path.<name>}, so the pack stays portable and the location stays yours.")
        return 0
    for name, path in paths.items():
        mark = "" if path.is_dir() else "   (does not exist)"
        print(f"{name}\t{path}{mark}")
    return 0
