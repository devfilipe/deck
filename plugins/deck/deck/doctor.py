"""`deck doctor` — diagnose the workspace and say exactly what to fix.

It changes nothing. Every problem it reports comes with the command or the edit
that resolves it.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

from . import board as board_lib
from . import instructions
from . import trackers
from . import __version__
from .config import ENV_PREFIX, STATE_DIR, load_yaml, norm, run, session_id, state_root
from .mount import MOUNT_KEYS
from .toggles import Toggles
from .workspace import MACHINE_FIELDS, Workspace, find_root, git_toplevel, pack_name

OK, WARN, BAD, SKIP = "OK", "!!", "XX", ".."


def _prerequisites(ws: Workspace) -> list[tuple[str, bool]]:
    """Tools the workspace needs. Core requires git; packs add the rest."""
    tools: list[tuple[str, bool]] = [("git", True)]
    for pack in ws.all_packs():
        detect = load_yaml(pack / "config" / "detect.yaml")
        for entry in detect.get("prerequisites") or []:
            if isinstance(entry, str):
                tools.append((entry, True))
            else:
                tools.append((entry.get("name"), bool(entry.get("required", True))))
    seen, out = set(), []
    for name, required in tools:
        if name and name not in seen:
            seen.add(name)
            out.append((name, required))
    return out


def run_doctor(args) -> int:
    problems, warnings = [], []

    def line(status, label, detail=""):
        print(f"  {status} {label}{('  ' + detail) if detail else ''}")

    print("workspace")
    root = find_root()
    if not root:
        line(BAD, "root not resolved")
        print(
            f"\n1 problem:\n  {BAD} root not resolved — export {ENV_PREFIX}ROOT=... or run `deck init` inside the tree"
        )
        return 1

    ws = Workspace(root)
    line(OK, f"root {root}", f"({ws.source})")

    if not ws.data:
        line(BAD, "descriptor missing", f"{STATE_DIR}/workspace.yaml")
        problems.append("descriptor missing — run: deck init")
    else:
        line(OK, "descriptor present", f"{len(ws.repos)} repositories, {len(ws.targets)} target(s)")
    if ws.machine and ws.machine.is_file():
        overlay = load_yaml(ws.machine)
        pointed = " -> " + str(overlay["descriptor"]) if overlay.get("descriptor") else ""
        line(OK, "machine overlay", f"{ws.machine}{pointed}")
        # A key nobody reads is worse than a key nobody wrote: somebody put it
        # there meaning something by it, and silence lets them go on believing
        # it took effect. Only the three fields and the pointer are read.
        stray = [k for k in overlay if k not in (*MACHINE_FIELDS, "root", "descriptor", "version")]
        if stray:
            line(
                WARN,
                "machine overlay",
                f"{ws.machine.name} carries {', '.join(sorted(stray))} — only "
                f"{', '.join(MACHINE_FIELDS)} and `descriptor:` are read here, so "
                "that is not taking effect. Move it into the descriptor, or drop it",
            )
            warnings.append(f"{ws.machine.name}: {', '.join(sorted(stray))} is read by nothing")
    if ws.all_packs():
        names = [pack_name(p) for p in ws.all_packs()]
        line(OK, "packs", " -> ".join(names) + "   (merge order)")
        for problem in ws.pack_problems():
            # Not "pack requirement": this list carries a name two packs claim
            # as well as a requirement nobody satisfies, and labelling a
            # collision as a requirement sends the reader to the wrong file.
            line(BAD, "pack", problem)
            problems.append(problem)
        # `machine.yaml` already reports a key nothing reads, and `mount.yaml`
        # is the other file a person edits by hand. `rules:` used to live here
        # and does not: `rules/`, `skills/` and `agents/` are walked, so a list
        # was two statements of one fact. An entry left behind places nothing
        # and said nothing, and a rule that a config file appears to declare is
        # exactly the one nobody checks is missing.
        for pack in ws.all_packs():
            cfg = load_yaml(pack / "config" / "mount.yaml") or {}
            stray = [k for k in cfg if k not in MOUNT_KEYS]
            if stray:
                where = f"{pack_name(pack)}: config/mount.yaml"
                note = f"{where}: {', '.join(sorted(stray))} is read by nothing"
                line(WARN, "mount", note + "   (rules/, skills/ and agents/ are walked, not listed)")
                warnings.append(note)
    else:
        line(WARN, "packs", "none — the core alone knows no build, deploy or lint command")
        warnings.append("no extension pack configured")

    # ---- tools
    print("\ntools")
    # First, because a diagnosis is what somebody pastes into a report, and the
    # first question about anything deck did is which deck did it. `unknown` is
    # a clone whose plugin manifest is missing — a real fault, said out loud
    # rather than papered over with a plausible number.
    if __version__ == "unknown":
        line(BAD, "deck", "unknown — the plugin manifest is missing or unreadable")
        problems.append("deck cannot read its own version from the plugin manifest")
    else:
        line(OK, "deck", __version__)
    for tool, required in _prerequisites(ws):
        path = shutil.which(tool)
        if path:
            line(OK, tool, path)
        elif required:
            line(BAD, tool, "not found on PATH")
            problems.append(f"{tool} is not on PATH")
        else:
            line(WARN, tool, "not found (optional)")
            warnings.append(f"{tool} missing")
    line(OK, "python3", ".".join(str(v) for v in sys.version_info[:3]))

    # ---- files the descriptor depends on
    required_files = ws.data.get("requires_files") or []
    if required_files:
        print("\nrequired files")
        for rel in required_files:
            if (root / rel).exists():
                line(OK, rel)
            else:
                line(BAD, rel, "not found")
                problems.append(f"required file missing: {rel}")

    # ---- is this workspace the tool that is managing it?
    try:
        running = Path(sys.argv[0]).resolve()
        inside = running.is_relative_to(root.resolve())
    except (OSError, ValueError):
        inside = False
    if inside:
        line(WARN, "self-hosting", f"the deck you are running lives in this workspace ({running})")
        warnings.append(
            "this workspace contains the deck running it — an agent editing it "
            "breaks the tool mid-task, including the gates that would catch the break. "
            "Work on a copy: git clone this tree elsewhere and point DECK_ROOT at it."
        )

    # ---- `.deck/` must never be versioned; in a monorepo the root IS a repo
    top = git_toplevel(root)
    if top is not None:
        code, tracked = run(["git", "-C", str(root), "ls-files", "--error-unmatch", f"{STATE_DIR}/workspace.yaml"])
        code2, ignored = run(["git", "-C", str(root), "check-ignore", "-q", f"{STATE_DIR}/"])
        if code == 0:
            line(BAD, f"{STATE_DIR} is tracked by git", str(top))
            problems.append(f"{STATE_DIR}/ is committed to {top} — it is per machine; git rm -r --cached {STATE_DIR}")
        elif code2 != 0:
            line(WARN, f"{STATE_DIR} is visible to git", "run `deck init` to hide it")
            warnings.append(f"{STATE_DIR}/ shows in git status — deck init writes the exclude")
        else:
            line(OK, f"{STATE_DIR} hidden from git", str(top))

    # ---- instruction files nobody declared, which are loaded anyway
    # A standing condition, so it belongs here as well as in `deck setup`: the
    # file can arrive long after the workspace was set up, and an ancestor's is
    # loaded at launch, before anything a pack declares.
    print("\ninstruction files")
    unmanaged = instructions.unmanaged(ws)
    if not unmanaged:
        line(OK, "none outside the packs", f"looked for {', '.join(instructions.names(ws))}")
    for entry in unmanaged:
        line(WARN, "not managed by deck", instructions.describe(entry))
        # Named, never judged. deck does not read it, move it, or decide it
        # should have been a pack — the team decides that, and can only decide
        # it once somebody has said the file is there.
        warnings.append(
            f"{entry['path']} is a second source of instruction deck does not manage"
            + ("" if entry["repo"] else ", and nothing versions it")
        )

    # ---- directories used but not changed
    if ws.paths:
        print("\npaths")
        for name, path in ws.paths.items():
            if path.is_dir():
                line(OK, name, str(path))
            else:
                line(BAD, name, f"not a directory: {path}")
                problems.append(f"path `{name}` does not exist — {path}")

    # ---- repositories
    if ws.repos:
        print("\nrepositories")
        for name, entry in ws.repos.items():
            rel = entry.get("path")
            if not rel:
                line(BAD, name, "no `path`")
                problems.append(f"{name}: no `path` in the descriptor")
                continue
            path = ws.resolve_path(str(rel))
            if not path.is_dir():
                line(BAD, name, f"path does not exist: {rel}")
                problems.append(f"{name}: path does not exist — {rel}")
                continue
            if not git_toplevel(path):
                line(WARN, name, "not a git repository")
                warnings.append(f"{name}: not a git repository")
                continue
            code, remote = run(["git", "-C", str(path), "remote", "get-url", "origin"])
            remote_id = entry.get("remote_id")
            if code != 0:
                line(WARN, name, "no origin remote")
                warnings.append(f"{name}: no origin remote")
            elif remote_id and remote_id not in remote:
                line(WARN, name, f"origin does not match `remote_id: {remote_id}`")
                warnings.append(f"{name}: origin {remote} does not contain {remote_id}")
            else:
                _, branch = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"])
                line(OK, name, branch or "?")

        print("\nimpact graph")
        dangling = [
            f"{name} -> {target}"
            for name, entry in ws.repos.items()
            for target in entry.get("impacts") or []
            if target not in ws.repos
        ]
        # Validated exactly like `impacts`, and reported apart from it, because
        # the edit that fixes each one is in a different field.
        dangling_couples = [
            f"{name} <-> {target}"
            for name, entry in ws.repos.items()
            for target in entry.get("couples") or []
            if target not in ws.repos and target != name
        ]
        if dangling or dangling_couples:
            line(BAD, "dangling references", "; ".join(dangling + dangling_couples))
            if dangling:
                problems.append(
                    "impacts pointing outside the descriptor: "
                    + "; ".join(dangling)
                    + " — add the repository under `repos:` or drop the `impacts:` entry"
                )
            if dangling_couples:
                problems.append(
                    "couples pointing outside the descriptor: "
                    + "; ".join(dangling_couples)
                    + " — add the repository under `repos:` or drop the `couples:` entry"
                )
        else:
            line(OK, "references", "every target exists in the descriptor")
        cycles = ws.cycles()
        if cycles:
            line(BAD, "cycle", ", ".join(cycles))
            problems.append("cycle in the impact graph: " + ", ".join(cycles))
            # A two-repository cycle is usually not a modelling mistake, it is a
            # coupling written in the only field that existed. Say so here, where
            # the person is already looking, rather than leaving them to delete a
            # true edge to make the diagnosis go quiet.
            for a, b in ws.mutual_impacts():
                problems.append(
                    f"{a} and {b} impact each other — if neither of them comes first, that is a coupling, "
                    f"not two impacts: put `couples: [{b}]` under `{a}` and drop both `impacts:` entries "
                    "between them. A coupling keeps the revisit and claims no order"
                )
        else:
            line(OK, "acyclic", "topological order computable")

        # ---- coupling: the edge that carries no order
        couplings = ws.couplings()
        self_coupled = [name for name, entry in ws.repos.items() if name in (entry.get("couples") or [])]
        for name in self_coupled:
            line(BAD, "coupling", f"{name} is coupled to itself")
            problems.append(
                f"{name} declares `couples: [{name}]` — a repository cannot be coupled to itself; drop the entry"
            )
        for a, b, sides in couplings:
            both_ways = b in (ws.repos.get(a, {}).get("impacts") or []) or a in (
                ws.repos.get(b, {}).get("impacts") or []
            )
            how = "declared on both sides" if len(sides) == 2 else f"declared by {sides[0]}, which is enough"
            if both_ways:
                # Two edges saying different things about one pair. deck does not
                # rank them, the way it refuses to rank two packs claiming a name.
                line(BAD, "coupling", f"{a} <-> {b} is also an `impacts:` edge")
                problems.append(
                    f"{a} and {b} are declared both as an impact and as a coupling — `impacts:` already "
                    "carries the revisit and adds an order the coupling denies; drop whichever of the two "
                    "is not true"
                )
            else:
                line(OK, "coupling", f"{a} <-> {b}   ({how})")
        if couplings:
            line(
                OK,
                "coupling effect",
                "what it does: `deck impact`, `deck mount` and a scope's boundary report reach both sides. "
                "What it does not: no part in `deck order`, in the cycle check above, or in any "
                "build order — a coupling can never make this graph cyclic",
            )

    # ---- scopes
    scope_problems = ws.scope_problems()
    if ws.scopes or scope_problems:
        print("\nscopes")
        for name in ws.scopes:
            repos = ws.scope_repos(name)
            leaks = ws.scope_leaks(name)
            mark = "  (active)" if name == ws.scope_name else ""
            detail = f"{len(repos)} of {len(ws.repos)} repositories"
            if (ws.scopes[name] or {}).get("backlog"):
                detail += ", own board"
            if leaks:
                detail += f", reaches {', '.join(leaks)}"
            # A boundary report reads couplings, because it reports rather than
            # decides — the same rule `deck scope` follows. Kept apart from the
            # reached set: one carries an order and the other refuses to.
            coupled = ws.scope_coupled(name)
            if coupled:
                detail += f", coupled with {', '.join(coupled)}"
            line(OK, name + mark, detail)
        for problem in scope_problems:
            line(BAD, "scope", problem)
            problems.append(problem)

    # ---- backlog sources
    #
    # Three shapes, and only one of them has a file. Resolving `file:` for all
    # of them accused every working tracker source of a missing file — and
    # printed the value it never had as `None` — while `deck board list` was
    # reading the same source in the same second.
    if ws.data.get("backlog"):
        print("\nbacklog sources")
        for source in ws.data["backlog"]:
            kind = norm(source.get("type") or "") or "?"

            if kind in trackers.FETCH:
                where = norm(source.get("repo") or source.get("project") or source.get("url") or "")
                needs = trackers.missing_requirement(source) or trackers.missing_read_requirement(source)
                if needs:
                    line(WARN, kind, needs)
                    warnings.append(f"backlog {kind}: {needs}")
                elif not args.net:
                    # The keys are all that can be read off a descriptor. That
                    # the service answers is a request, so it waits for --net,
                    # the bargain the targets section below already makes.
                    #
                    # What an outage costs is answerable offline, though, and it
                    # is the part choosing a tracker source never said: a board
                    # deck has read once survives one, and a board it has not
                    # simply is not there. Said where the source is chosen,
                    # rather than discovered the morning the resolver goes down.
                    held, old_by = board_lib.source_cache(ws, source)
                    offline = (
                        f"last read {board_lib.age(old_by)} ago, so an outage still shows it"
                        if held
                        else "never read here — an outage leaves this board unreadable"
                    )
                    line(OK, kind, f"{where}  (use --net to check it answers)   {offline}")
                else:
                    try:
                        found, notes = trackers.fetch(source, list(ws.repos))
                        short = "; ".join(notes)
                        line(
                            WARN if notes else OK,
                            kind,
                            f"{where}  {len(found)} task(s)" + (f" — {short}" if short else ""),
                        )
                        if notes:
                            warnings.append(f"backlog {kind}: {short}")
                    except trackers.TrackerError as exc:
                        line(WARN, kind, f"{where}  {exc}")
                        warnings.append(f"backlog {kind}: {exc} — check the token with `deck board whoami`")
                continue

            if source.get("command"):
                # An adapter is a command line, not a path — `bash x.sh`, a
                # pipeline — so there is nothing here to stat, and running it
                # is `deck board list`'s job, not a diagnosis's.
                line(OK, kind, f"command: {source['command']}  (run `deck board list` to exercise it)")
                continue

            rel = norm(source.get("file") or "")
            if not rel:
                detail = f"no `file:` — add one, or a `command:`, or name a tracker type ({', '.join(trackers.FETCH)})"
                line(WARN, kind, detail)
                warnings.append(f"backlog {kind}: {detail}")
                continue
            # resolve_path, not root / rel, because that is what `deck board`
            # reads with: a `~/` board existed for the reader and was missing
            # for the diagnosis.
            path = ws.resolve_path(rel)
            if path.is_file():
                line(OK, kind, str(path))
            else:
                line(WARN, kind, f"missing: {rel}")
                warnings.append(f"backlog {kind}: file missing — create {path}, or correct `file:`")

    # ---- targets
    print("\ntargets (allowlist)")
    if not ws.targets:
        # An empty allowlist is only a gap if the ladder is meant to climb past
        # `build`. When gate_level says it stops there, the absence of a target
        # is the decision working, not a defect — and a warning that can never
        # go green is a warning nobody reads.
        rung, whence = "deploy", "catalog default"
        try:
            rung, whence = Toggles(root=root).resolve("gate_level")
        except (SystemExit, KeyError):
            pass
        if rung in ("static", "build"):
            line(OK, "none declared", f"not needed: gate_level = {rung} ({whence})")
        else:
            line(
                WARN, "none declared", f"gate_level = {rung} needs one — deployment and behaviour gates are unavailable"
            )
            warnings.append("no target declared")
    for target in ws.targets:
        host, alias = target.get("host"), target.get("alias")
        if not args.net:
            line(SKIP, str(host), f"alias={alias or '—'}  (use --net to test reachability)")
            continue
        code, out = run(
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=4",
                "-o",
                "StrictHostKeyChecking=accept-new",
                str(alias or host),
                "true",
            ],
            timeout=12,
        )
        if code == 0:
            line(OK, str(host), f"ssh {alias or host} answers")
        else:
            line(WARN, str(host), f"ssh {alias or host} failed: {out.splitlines()[0] if out else code}")
            warnings.append(f"target {host} unreachable")

    # ---- mounts
    from .mount import edits, list_manifests, plan, stale_sources

    manifests = list_manifests(root)
    print("\nmounted artifacts")
    if not manifests:
        # A pack's rules reach an agent only through this directory. Unmounted,
        # `deck packs` still lists the pack and `deck pack review` still counts
        # it — everything about it reports success, and nobody reads it. This
        # section used to vanish rather than say "none", so a workspace with
        # nothing mounted and one with everything mounted looked identical
        # here except that the second said so. Comparing against what the
        # packs in play declare turns "nothing" into a number worth acting on:
        # a workspace where nothing CAN be mounted is not the same finding as
        # one where eleven rules are declared and none reached the tree.
        candidates = [
            name
            for name, entry in ws.repos.items()
            if entry.get("path") and ws.resolve_path(str(entry["path"])).is_dir()
        ]
        try:
            would = [a for a in plan(ws, candidates) if a["kind"] in ("rule", "agent", "skill")]
        except SystemExit:
            would = []
        declaring = sorted({a["pack"] for a in would if a.get("pack")})
        if would:
            line(
                WARN,
                "none placed",
                f"{len(declaring)} pack(s) declare {len(would)} artifact(s) and none are mounted — deck mount",
            )
            # A warning, not a problem: reading a workspace, running a gate, or
            # answering a consultation with nothing mounted is a legitimate
            # choice. What is not legitimate is not knowing which one you are in.
            warnings.append(
                f"nothing is mounted — {len(declaring)} pack(s) declare {len(would)} artifact(s) "
                "that reach no agent unmounted — deck mount"
            )
        else:
            line(OK, "none placed", "no pack declares a rule, agent or skill for this workspace")
    else:
        for manifest in manifests:
            task, count = manifest.get("task", "?"), len(manifest.get("entries", []))
            alive = manifest.get("session") == session_id()
            if alive:
                line(OK, task, f"{count} artifact(s), this session")
            else:
                line(WARN, task, f"{count} artifact(s) from session {manifest.get('session', '?')}")
                warnings.append(f"mount {task} outlived its session — deck unmount --task {task}")
            for source, pack, repos in stale_sources(manifest):
                # "<repo> hold the old copy" collides with the `deck hold`
                # command as soon as a repository is called deck.
                where = ", ".join(repos)
                line(
                    WARN,
                    task,
                    f"stale: {pack} changed {Path(source).name} since it was placed — old copy still in {where}",
                )
                warnings.append(f"mount {task} carries a stale copy of {Path(source).name} — remount to pick up {pack}")
            # The other direction, and the one that loses work. `stale` is the
            # pack moving ahead of the copies; this is the copies moving ahead of
            # the pack — an edit the agent made that no collection holds yet, and
            # that `deck unmount` will leave behind rather than delete. Reported
            # here because a mount is where somebody looks when they wonder what
            # state they are in, and an edit nobody carried back is invisible
            # until the working directory is thrown away.
            pending = [e for e in edits(ws, manifest) if e["status"] in ("changed", "new")]
            if pending:
                changed = sum(1 for e in pending if e["status"] == "changed")
                new_files = len(pending) - changed
                parts = [f"{changed} edited"] if changed else []
                parts += [f"{new_files} written here"] if new_files else []
                line(WARN, task, f"unsaved: {', '.join(parts)} — nothing in the collection holds them yet")
                warnings.append(
                    f"mount {task} has {len(pending)} artifact(s) not carried back — deck save --task {task}"
                )

    # ---- toggles
    print("\ntoggles")
    try:
        tg = Toggles(root=root)
        line(OK, "catalog", f"{len(tg.defs)} toggles, {len(tg.profiles)} profiles")
    except SystemExit:
        line(BAD, "catalog", "invalid — run: deck toggle validate")
        problems.append("toggle catalog invalid")

    choices = state_root(root) / "toggles.yaml"
    if choices.is_file():
        line(OK, "choices", str(choices))
    else:
        line(WARN, "choices", f"missing: {choices}  (deck init)")
        warnings.append("workspace toggle file missing")

    # ---- summary
    print()
    if problems:
        print(f"{len(problems)} problem(s):")
        for problem in problems:
            print(f"  {BAD} {problem}")
    if warnings:
        print(f"{len(warnings)} warning(s):")
        for warning in warnings:
            print(f"  {WARN} {warning}")
    if not problems and not warnings:
        print(f"{OK} workspace ready")
    return 1 if problems else 0
