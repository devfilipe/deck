"""Mount commands: place the packs for a piece of work, then take them back."""

from __future__ import annotations

import pathlib

import json
import sys
from pathlib import Path

from . import consult
from . import mount as mount_lib
from .config import session_id
from .workspace import Workspace


def _resolve_repos(ws: Workspace, args) -> list[str]:
    """Which repositories this task touches.

    Given `--repos`, the impact graph expands them: mounting the pack for the
    schema and not for the server it forces to change is how an agent ends up
    editing a repository it knows nothing about.

    Without them, the active scope's subset — which is the point of a scope,
    and is why nobody has to retype the list. Expansion still follows the graph
    out of the scope where the graph goes: a change that forces a repository
    the initiative does not own still has to be made in it, and mounting
    nothing there would leave that edit unguided.

    A coupled repository is in play too, by the same argument and no other: it
    is a repository this work may have to be edited in, and the failure mount
    expansion exists to prevent is an agent editing one of those with none of
    its rules loaded. Mount is also the one consumer of the graph that never
    asks for an order, so the single thing a coupling does not carry is the
    single thing mount does not need. Mounting more than was needed is cheap
    and reversible — `deck unmount`, or `--no-expand` to take only what was
    named — while mounting too little is discovered by reading the diff.
    """
    if args.repos:
        named = [r.strip() for r in ",".join(args.repos).split(",") if r.strip()]
    else:
        named = ws.selected_repos()

    for name in named:
        ws.repo(name)  # fails loudly on a name that is not declared

    if args.no_expand:
        return named

    expanded = list(named)
    for name in named:
        for reached in list(ws.impacted(name)) + ws.coupled(name):
            if reached not in expanded:
                expanded.append(reached)
    # `order()` is cycle-blind and coupling-blind; a coupled repository simply
    # lands wherever the impact edges put it, which is fine because nothing in a
    # mount is sequenced.
    return ws.order(expanded)


def cmd_mount(ws: Workspace, args) -> int:
    if not ws.root:
        print("deck: workspace not resolved")
        return 1
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1

    task = args.task or session_id()

    brief = None
    if args.brief == "-":
        brief = sys.stdin.read()
    elif args.brief:
        brief = args.brief if "\n" in args.brief else f"# Task {task}\n\n{args.brief}\n"

    existing = mount_lib.manifest_path(ws.root, task)
    if existing.is_file() and not args.dry_run:
        # A statement of the task usually arrives after the mount: you mount to
        # start working, and work out what the task is by working. Charging an
        # unmount for that means most tasks never get one — and the statement is
        # what an agent most needs to read beside the rules.
        if brief is not None:
            return _rebrief(ws, task, brief)
        print(f"deck: task {task} is already mounted ({existing})")
        print("  deck unmount --task " + task)
        print(f"  or add a statement to it:  deck mount --task {task} --brief -")
        return 1

    repos = _resolve_repos(ws, args)
    actions = mount_lib.plan(ws, repos, brief)

    if not actions:
        print(f"nothing to mount for {', '.join(repos)}")
        print("  No pack applies. Check `packs:` in the descriptor and each pack's config/mount.yaml.")
        return 0

    if args.dry_run:
        print(f"would mount for task {task}, across {len(repos)} repositor{'y' if len(repos) == 1 else 'ies'}\n")
        for action in actions:
            # The destination that is already occupied is the one worth seeing
            # before mounting, not after: it is the one artifact the mount will
            # not place, and --dry-run exists to answer what will happen.
            taken = "   (occupied — deck will not overwrite it)" if Path(action["path"]).exists() else ""
            print(f"  {action['kind']:<8} {action['repo']:<28} {action['path']}{taken}")
        print("\n  Nothing written.")
        return 0

    manifest = mount_lib.apply(ws, actions, task, asked=repos)
    print(f"mounted for task {task}\n")
    for entry in manifest["entries"]:
        # A rule shows the pack file it came from; its destination is predictable.
        # Anything else shows where it landed — a hash tells the reader nothing,
        # and --dry-run already prints the destination, so the two disagreed.
        detail = ", ".join(entry.get("plugins", [])) or entry.get("source", "") or entry.get("path", "")
        print(f"  {entry['kind']:<8} {entry['repo']:<28} {detail}")
    blocked = manifest.get("blocked") or []
    if blocked:
        print(f"\n  {len(blocked)} not placed — something deck did not write is already there:")
        for entry in blocked:
            print(f"  {entry['kind']:<8} {entry['repo']:<28} {entry['path']}")
        print("  Nothing was overwritten, and unmount will not remove these. The pack's")
        print("  version did not arrive: whatever is at that path is what the agent reads.")
    print(f"\n  {len(manifest['entries'])} artifact(s) · manifest at {mount_lib.manifest_path(ws.root, task)}")
    print(f"  deck unmount --task {task}")
    if brief is None:
        # The rules say how not to break things; only the statement says what
        # this task is for. Mounting without one is allowed and often right at
        # the start — it just must not pass unremarked, or it never gets added.
        print("\n  No statement — the agent will read the rules and not the task.")
        print(f"  deck mount --task {task} --brief -   adds one without unmounting")
    return 0


def _rebrief(ws: Workspace, task: str, brief: str) -> int:
    """Write the task's statement onto a mount that already exists."""
    manifest = json.loads(mount_lib.manifest_path(ws.root, task).read_text(encoding="utf-8"))
    entries = manifest.get("entries", [])
    entry = next((e for e in entries if e.get("kind") == "file" and e["path"].endswith("CLAUDE.local.md")), None)
    path = Path(entry["path"]) if entry else ws.root / "CLAUDE.local.md"

    if entry and path.is_file() and mount_lib.hash_file(path) != entry.get("hash"):
        print(f"deck: {path} was edited since it was placed — refusing to overwrite it")
        print("  read it, then remove it by hand if the new statement should win")
        return 1
    if not entry and path.exists():
        print(f"deck: {path} already exists and deck did not place it — refusing to overwrite it")
        return 1

    path.write_text(brief, encoding="utf-8")
    if entry:
        entry["hash"] = mount_lib.hash_file(path)
        what = "replaced"
    else:
        entries.append({"kind": "file", "repo": "<workspace>", "path": str(path), "hash": mount_lib.hash_file(path)})
        manifest["repos"] = sorted(set(manifest.get("repos", [])) | {"<workspace>"})
        what = "added"
    mount_lib.manifest_path(ws.root, task).write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"{what} the statement for {task}\n  {path}")
    return 0


def cmd_save(ws: Workspace, args) -> int:
    """Carry what the agent changed back into the collection, where it can be committed.

    Deliberate, and never part of unmount. The `SessionEnd` hook unmounts, and a
    hook that also wrote into a versioned collection would put edits nobody
    reviewed into somebody's git status every time a pane closed. Taking work
    back is a thing you ask for.
    """
    if not ws.root:
        print("deck: workspace not resolved")
        return 1
    task = args.task or session_id()
    manifest = mount_lib.read_manifest(ws.root, task)
    if not manifest:
        print(f"deck: nothing mounted for task {task}")
        return 1

    written, refused = mount_lib.save(ws, manifest, dry=args.dry_run)
    if written and not args.dry_run:
        # The manifest now records what was carried back, so `deck unmount` can
        # take those files with the rest. Written here rather than in `save`,
        # which stays a function that can be asked what it would do.
        mount_lib.manifest_path(ws.root, task).write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    for line in written:
        print(f"  {'would save' if args.dry_run else 'saved'}   {line}")
    for line in refused:
        print(f"  left     {line}")
    if not written and not refused:
        print("  nothing changed since it was placed")
        return 0
    if written:
        where = {str(pathlib.Path(line.split()[-1]).parent) for line in written}
        print(f"\n  {len(written)} file(s) -> {len(where)} pack directory(ies). Review and commit them there.")
    return 0


def cmd_unmount(ws: Workspace, args) -> int:
    if not ws.root:
        print("deck: workspace not resolved")
        return 1

    manifests = mount_lib.list_manifests(ws.root)
    still_held: list[dict] = []
    if args.all:
        selected = manifests
    elif args.session:
        # A session ending releases only its own hold. Two panes of one window
        # are one task by design, so the pane that closes first must not take
        # the mount away from the pane still working in it — and a mount a
        # person made at a terminal is never released by a session at all.
        who, selected = mount_lib.holder(), []
        for manifest in manifests:
            if manifest.get("session") != session_id():
                continue
            left = mount_lib.release(ws.root, who, manifest)
            (selected if not left else still_held).append(manifest)
        for manifest in still_held:
            others = ", ".join(mount_lib.holders_of(manifest))
            print(f"  held     {manifest['task']} — still held by {others}")
    else:
        task = args.task or session_id()
        selected = [m for m in manifests if m.get("task") == task]

    if not selected:
        if still_held:
            return 0  # already said which tasks stayed, and why
        print("nothing mounted" if not manifests else "no mount matches that selection")
        return 0

    total_removed, total_kept = [], []
    for manifest in selected:
        removed, kept = mount_lib.remove(ws, manifest)
        total_removed += removed
        total_kept += kept

    for item in total_removed:
        print(f"  removed  {item}")
    for item in total_kept:
        print(f"  LEFT     {item}")

    # A skill is `skills/<name>/SKILL.md` — a directory deck created — while a
    # rule is a flat file. Removing the file left the directory behind, so
    # `unmount` took back 28 artifacts and left two empty folders it had made.
    # "It only removes what it placed" has to include the folders it placed
    # them in. Only empty ones, and only upwards to `.claude`: a directory
    # somebody else put something in is theirs.
    for name in total_removed:
        here = Path(name).parent
        while here.name and here.is_dir():
            if any(here.iterdir()) or ".claude" not in here.parts:
                break
            parent = here.parent
            here.rmdir()
            here = parent

    print(f"\n  {len(total_removed)} removed · {len(total_kept)} left alone")
    if total_kept:
        print("  Anything left was changed after it was placed. deck does not delete")
        print("  what it no longer recognises — remove those by hand if you want them gone.")
    # The last moment anybody is looking. A mounted pack is a copy, and what a
    # task taught that lives only in the copy — or only in the conversation —
    # goes when the copy does. Two of those losses have a command; the third is
    # a question nothing can ask for you, which is why it is named here rather
    # than left to whoever remembers.
    open_asks = len(consult.load_all(ws.root, ws.all_packs()))
    print("\n  Before this is gone: what did the task teach?")
    if total_kept:
        print("    deck save                    carry your edits back to the pack")
    if open_asks:
        print(f"    deck ask list                {open_asks} consultation(s); `ask fold` puts an answer in a pack")
    print("    and what is in no file at all — a rule, a decision, a procedure — write it")
    print("    into the pack now. The next person re-learns it otherwise. See: the `closing` skill.")
    return 0


def cmd_hold(ws: Workspace, args) -> int:
    """Take a share in whatever is mounted for this session.

    Runs from the SessionStart hook. Without it a session that never mounted
    anything is invisible, and the first session to end takes the mount away
    from everyone else working in it.
    """
    if not ws.root:
        return 0  # a hook must never fail a session start
    who = mount_lib.holder()
    if who == mount_lib.TERMINAL:
        print("not an agent session — nothing to hold")
        return 0
    held = mount_lib.hold(ws.root, who, session_id())
    print(f"holding {', '.join(held)}" if held else "nothing mounted for this session")
    return 0


def cmd_mounts(ws: Workspace, args) -> int:
    if not ws.root:
        print("deck: workspace not resolved")
        return 1
    manifests = mount_lib.list_manifests(ws.root)
    if args.json:
        print(json.dumps(manifests, ensure_ascii=False, indent=2))
        return 0
    if not manifests:
        print("nothing mounted")
        return 0
    current = session_id()
    for manifest in manifests:
        mark = "*" if manifest.get("session") == current else " "
        print(
            f" {mark} {manifest['task']:<20} {len(manifest.get('entries', []))} artifact(s)"
            f"  {', '.join(manifest.get('repos', []))}"
        )
        print(f"     {manifest.get('created', '?')}  session {manifest.get('session', '?')}")
    print("\n  * = this session")
    return 0
