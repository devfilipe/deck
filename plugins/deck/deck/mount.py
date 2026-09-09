"""Place and remove agent artifacts in working directories.

Packs live outside the product repositories and have to be *inside* the
directory an agent works in to be loaded. Mounting is how they get there, and
unmounting is why anyone lets you do it.

What a pack offers is what it holds. `rules/`, `skills/` and `agents/` are
copied as they are, and nothing enumerates them a second time: a directory that
has to agree with a list in a config file is two statements of one fact, and one
of them goes stale. The directory is the statement.

Where each lands is the pack's own axis, not a setting:

    _workspaces/<name>/<scope>/   the workspace root — the layer is about the
                                  workspace, so it is placed once, not per
                                  repository
    _repos/<name>/                that repository, and no sibling: a convention
                                  meant for one codebase quietly becoming law
                                  across the workspace is what this prevents

    plugin   still declared, because it is not a directory: enabling a pack in
             <repo>/.claude/settings.local.json leaves three lines instead of
             files
    file     copy — only for something generated for this task

Two guarantees make this safe to run in a repository you do not own:

    it only removes what it placed  — every entry records a hash; a file someone
                                      edited is reported, never deleted
    it does not dirty `git status`  — exclusions go to .git/info/exclude, which
                                      is local, never .gitignore, which is the
                                      team's
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path

from .config import STATE_DIR, die, load_yaml, session_id, state_root
from .workspace import Workspace, git_toplevel, pack_name

RULE_PREFIX = "deck-"
TERMINAL = "terminal"
EXCLUDE_BEGIN = "# deck: begin"
EXCLUDE_END = "# deck: end"

# What a pack can offer, and the directory each kind lands in. The prefix is on
# every one of them for the same reason it was on rules: the exclude below has
# to name deck's files without claiming a directory the repository also uses.
#
# That Claude Code finds all three at project level is measured, not assumed. A
# directory carrying a skill, an agent and a `paths:`-scoped rule, each with a
# word nothing else in the session could supply, put to a session launched there:
#
#     SKILL: yes          .claude/skills/<name>/SKILL.md, in the skills list
#     AGENT: yes          .claude/agents/<name>.md, as an Agent type
#     CLAUDE_MD: yes      CLAUDE.local.md at the root, in the instructions
#     RULE: no            .claude/rules/<name>.md — and then yes, after the
#                         session read a file its `paths:` matched
#
# The last line is the mechanism, not a fault: a rule is loaded when something
# it applies to is read. It is also why the check had to be run twice — a single
# "no" here reads exactly like a rule that never arrives, which is the failure
# the symlink note below is a scar from.
ARTIFACTS = (
    ("rules", "rules", "rule"),
    ("agents", "agents", "agent"),
    ("skills", "skills", "skill"),
)

EXCLUDE_LINES = [
    ".claude/settings.local.json",
    f".claude/rules/{RULE_PREFIX}*.md",
    f".claude/agents/{RULE_PREFIX}*.md",
    f".claude/skills/{RULE_PREFIX}*/",
    "CLAUDE.local.md",
]

# Every kind that is a file on disk with a hash behind it. `plugin` is not one —
# it is a merge into somebody else's JSON — and the difference is why unmount
# can delete these and has to reason about that one.
FILE_KINDS = {"rule", "agent", "skill", "file"}


def hash_file(path: Path) -> str:
    try:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()[:32]
    except OSError:
        return ""


def mounts_dir(root: Path) -> Path:
    return state_root(root) / "mounts"


def manifest_path(root: Path, task: str) -> Path:
    return mounts_dir(root) / f"{task}.json"


def read_manifest(root: Path, task: str) -> dict:
    """One task's manifest, or an empty dict when nothing is mounted for it."""
    path = manifest_path(root, task)
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def list_manifests(root: Path) -> list[dict]:
    out = []
    for path in sorted(mounts_dir(root).glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            data["_path"] = str(path)
            out.append(data)
        except (OSError, ValueError):
            continue
    return out


# What `mount.yaml` still carries. Everything else in a pack is a directory that
# gets walked, so a key outside this pair is read by nothing — `deck doctor`
# says so rather than letting it look like a declaration that works.
MOUNT_KEYS = ("plugin", "marketplace")


# ------------------------------------------------------------------ planning
def _pack_mount_config(pack: Path) -> dict:
    return load_yaml(pack / "config" / "mount.yaml")


def _artifacts(pack: Path, dest: Path, repo: str, layer: int = 0) -> list[dict]:
    """Everything `pack` holds, as actions placing it under `dest`.

    Walked, not listed. A pack that grows a rule and forgets to name it in a
    config file used to place nothing and say nothing — `deck doctor` grew a
    check for exactly that, and the check exists because the list existed.
    """
    out: list[dict] = []
    for folder, into, kind in ARTIFACTS:
        base = pack / folder
        if not base.is_dir():
            continue
        for source in sorted(base.rglob("*")):
            if not source.is_file():
                continue
            rel = source.relative_to(base)
            # Nothing whose name starts with a dot, at any depth. A `.gitkeep`
            # holding an empty directory in the collection would otherwise be
            # placed as `.claude/rules/deck-.gitkeep`, and the directory it was
            # keeping is exactly the one a pack with nothing in it yet has.
            if any(part.startswith(".") for part in rel.parts):
                continue
            # A pack may record that it deliberately has no skill and no agent —
            # "nothing here needs one" is an answer worth keeping, and an empty
            # directory does not carry it. It is a note to a person reading the
            # pack. Placing it would install a file saying "no agent was
            # proposed" AS an agent, which is the mistake the scaffold's
            # `README.md` example made before those directories shipped empty.
            if rel.name == "NONE.md":
                continue
            # The prefix goes on the first segment, so a skill keeps its own
            # directory shape underneath and the exclude still matches at the
            # top: `.claude/skills/deck-verifying/references/x.md`.
            head = f"{RULE_PREFIX}{rel.parts[0]}"
            target = dest / ".claude" / into / Path(head, *rel.parts[1:])
            out.append(
                {
                    "kind": kind,
                    "repo": repo,
                    "path": str(target),
                    "source": str(source.resolve()),
                    "pack": pack_name(pack),
                    "layer": layer,
                }
            )

    claude = pack / "CLAUDE.md"
    if claude.is_file():
        # Placed as CLAUDE.local.md, never CLAUDE.md. The source is versioned in
        # the collection; a CLAUDE.md in the working tree would be the same text
        # versioned twice, in two repositories, drifting from the moment either
        # is edited.
        out.append(
            {
                "kind": "rule",
                "repo": repo,
                "path": str(dest / "CLAUDE.local.md"),
                "source": str(claude.resolve()),
                "pack": pack_name(pack),
                "layer": layer,
            }
        )
    return out


def plan(ws: Workspace, repos: list[str], brief: str | None = None) -> list[dict]:
    """What would be placed, without placing anything."""
    actions: list[dict] = []
    per_repo, shared, by_scope, _ = ws.discovered_packs()

    # The workspace layers land once, at the root. They are about the workspace,
    # and a copy per repository would say the same thing four times and load
    # four times.
    seen: set[Path] = set()
    # Numbered in the order they are walked, which is merge order: most general
    # first. The number is what ranks an overlay — `<name>/<scope>` naming a file
    # `all/default` also names wins, and two artifacts at the same number are the
    # tie `resolve_overlay` refuses.
    for layer, pack in enumerate(ws.unbound_named_packs() + list(shared) + ws.scope_layer(by_scope), start=1):
        if pack.resolve() in seen:
            continue
        seen.add(pack.resolve())
        actions += _artifacts(pack, ws.root, "<workspace>", layer=layer)

    for name in repos:
        entry = ws.repo(name)
        repo_dir = ws.repo_path(name)
        if not repo_dir.is_dir():
            die(f"{name}: path does not exist — {entry.get('path')}")

        pack = per_repo.get(name)
        if pack is not None:
            # Above every workspace layer: a repository's own pack is the most
            # specific thing there is about that repository.
            actions += _artifacts(pack, repo_dir, name, layer=1000)

        # `plugin` is not a directory, so it stays declared. It is also the one
        # strategy that leaves lines rather than files, which is why it is worth
        # keeping the config entry for.
        for source in ([pack] if pack is not None else []) + list(shared):
            config = _pack_mount_config(source)
            plugin = config.get("plugin")
            if plugin:
                actions.append(
                    {
                        "kind": "plugin",
                        "repo": name,
                        "path": str(repo_dir / ".claude" / "settings.local.json"),
                        "plugins": [plugin],
                        "marketplace": config.get("marketplace"),
                        "pack": pack_name(source),
                    }
                )

    if brief:
        # A layer's CLAUDE.md and the task's brief both want the root
        # CLAUDE.local.md, because both are read at launch and that is the file
        # read at launch. They shared a destination and the second one refused —
        # after the first had already been written, leaving a mount with
        # artifacts on disk and no manifest to take them back.
        #
        # One file, two parts: what is always true here, then what this task is.
        standing = next(
            (a for a in actions if a["kind"] == "rule" and a["path"] == str(ws.root / "CLAUDE.local.md")),
            None,
        )
        if standing is not None:
            actions.remove(standing)
            head = Path(standing["source"]).read_text(encoding="utf-8").rstrip()
            brief = f"{head}\n\n---\n\n{brief}"
        actions.append(
            {
                "kind": "file",
                "repo": "<workspace>",
                "path": str(ws.root / "CLAUDE.local.md"),
                "content": brief,
            }
        )

    return actions


# ------------------------------------------------------------------ applying
def _merge_settings(path: Path, plugins: list[str], marketplace: dict | None) -> tuple[list[str], str | None]:
    """Add plugin entries to a local settings file without disturbing the rest.

    Returns both halves of what it wrote: the plugins it enabled, and the name
    of the marketplace it added, if it added one. It used to return the first
    only. What is not returned is not recorded, what is not recorded cannot be
    removed, and `unmount` then reported a file gone that was still on disk —
    the marketplace entry kept `data` non-empty, so the branch that deletes a
    settings file holding nothing but ours was never reached.
    """
    data = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            die(f"{path}: not valid JSON — refusing to touch it")

    added = []
    enabled = data.setdefault("enabledPlugins", {})
    for plugin in plugins:
        if plugin not in enabled:
            enabled[plugin] = True
            added.append(plugin)

    named = None
    if marketplace and marketplace.get("name"):
        known = data.setdefault("extraKnownMarketplaces", {})
        if marketplace["name"] not in known:
            known[marketplace["name"]] = {"source": marketplace.get("source")}
            named = marketplace["name"]

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return added, named


def _git_dir_for(path: Path) -> tuple[Path, Path] | None:
    """(.git directory, working-tree root) that governs `path`, or None.

    Not `path/.git`. In a monorepo the unit of change is a package, and a
    package directory has no `.git` of its own — so looking only there found
    nothing, wrote nothing, and left every mounted artifact sitting in the
    product's `git status`. An agent running `git add -A` would then commit
    deck's own files into the repository deck promises never to touch.
    """
    top = git_toplevel(path)
    if top is None:
        return None
    git_dir = top / ".git"
    if git_dir.is_file():  # worktree: .git is a file pointing at the real dir
        try:
            pointer = git_dir.read_text(encoding="utf-8").strip()
            if pointer.startswith("gitdir:"):
                git_dir = Path(pointer.split(":", 1)[1].strip())
        except OSError:
            return None
    return (git_dir, top) if git_dir.is_dir() else None


def _write_exclude_block(git_dir: Path, marker: str, patterns: list[str]) -> None:
    """Replace one marked block in .git/info/exclude. Empty patterns removes it.

    Never .gitignore: that file is versioned and belongs to the team.
    """
    exclude = git_dir / "info" / "exclude"
    begin, end = f"{EXCLUDE_BEGIN} {marker}", f"{EXCLUDE_END} {marker}"
    lines = exclude.read_text(encoding="utf-8").splitlines() if exclude.is_file() else []

    kept, inside = [], False
    for line in lines:
        if line.strip() == begin:
            inside = True
            continue
        if line.strip() == end:
            inside = False
            continue
        if not inside:
            kept.append(line)

    if patterns:
        kept += [begin, *patterns, end]

    exclude.parent.mkdir(parents=True, exist_ok=True)
    exclude.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")


def exclude_state(root: Path) -> bool:
    """Keep `.deck/` out of `git status` when the workspace root is itself a repo.

    In a multi-repository workspace the root is not a checkout and nobody sees
    `.deck/`. In a monorepo it is the product's own repository, and `.deck/`
    holds paths, evidence and choices that must never be versioned.
    """
    found = _git_dir_for(root)
    if found is None:
        return False
    git_dir, top = found
    try:
        rel = root.resolve().relative_to(top.resolve())
    except ValueError:
        return False
    prefix = f"/{rel.as_posix()}" if rel.as_posix() != "." else ""
    _write_exclude_block(git_dir, "state", [f"{prefix}/{STATE_DIR}/"])
    return True


def _update_exclude(repo_dir: Path, task: str, add: bool) -> None:
    """Keep a task's artifacts out of `git status`, wherever the checkout is."""
    found = _git_dir_for(repo_dir)
    if found is None:
        return
    git_dir, top = found
    try:
        rel = repo_dir.resolve().relative_to(top.resolve())
    except ValueError:
        return
    # Anchored to the working-tree root, so a package inside a monorepo excludes
    # its own artifacts and not every package's.
    prefix = "" if rel.as_posix() == "." else f"/{rel.as_posix()}"
    patterns = [f"{prefix}/{line}" if prefix else line for line in EXCLUDE_LINES]
    # The marker names the task AND the directory. In a multi-repository
    # workspace each checkout has its own exclude file, so the task alone was
    # unique; in a monorepo every package shares one, and each write replaced
    # the last — leaving only the final package excluded and the rest visible.
    marker = task if not prefix else f"{task}{prefix}"
    _write_exclude_block(git_dir, marker, patterns if add else [])
    return


def resolve_overlay(actions: list[dict]) -> tuple[list[dict], list[str]]:
    """One artifact per destination: the last layer to name it wins.

    `plan` walks the layers most general first, so `<name>/<scope>` naming the
    same file as `all/default` is the overlay the whole design turns on — the
    more specific layer has the last word, exactly as it does for a toggle or a
    gate. Refusing that pair would make a legitimate override impossible.

    What is refused is a genuine tie: two artifacts for one path with no
    precedence between them. `apply` writes as it walks, so a plan that collided
    used to write everything up to the collision and then die — artifacts on
    disk, no manifest, and nothing for `deck unmount` to take back. Refusing the
    plan beats undoing half of it.
    """
    by_path: dict[str, dict] = {}
    order: list[str] = []
    overlaid: list[str] = []
    for action in actions:
        if action["kind"] == "plugin":
            order.append(f"\0{len(order)}")
            by_path[order[-1]] = action
            continue
        path = action["path"]
        previous = by_path.get(path)
        if previous is None:
            order.append(path)
        elif previous.get("layer", 0) == action.get("layer", 0):
            die(
                f"two artifacts would be placed at {path}: "
                f"{previous['kind']} from {previous.get('pack') or previous['repo']} and "
                f"{action['kind']} from {action.get('pack') or action['repo']}, and "
                "nothing ranks them. Rename one. Nothing was written."
            )
        else:
            overlaid.append(f"{Path(path).name}: {action.get('pack')} over {previous.get('pack')}")
        by_path[path] = action
    return [by_path[k] for k in order], overlaid


def apply(ws: Workspace, actions: list[dict], task: str, asked: list[str] | None = None) -> dict:
    actions, _overlaid = resolve_overlay(actions)
    """Place the artifacts and write the manifest that lets us take them back."""
    entries, touched_repos = [], set()
    # Destinations already occupied by something deck did not put there. Kept
    # apart from `entries` on purpose: `entries` is what unmount takes back, and
    # a file deck never wrote must not end up in the list of files deck removes.
    blocked: list[dict] = []

    for action in actions:
        path = Path(action["path"])
        kind = action["kind"]
        touched_repos.add(action["repo"])

        if kind == "plugin":
            added, market = _merge_settings(path, action["plugins"], action.get("marketplace"))
            if not added and not market:
                continue  # already there before us; not ours to remove
            entries.append(
                {
                    "kind": "plugin",
                    "repo": action["repo"],
                    "path": str(path),
                    "plugins": added,
                    "marketplace": market,
                    "pack": action.get("pack"),
                }
            )

        elif kind in ("rule", "agent", "skill"):
            if path.exists() or path.is_symlink():
                # Never overwrite what is already there — and never pass over it
                # in silence either. Skipping quietly is how a hand-written file
                # gets adopted as if a pack had placed it: the agent reads it,
                # the pack's own artifact never arrives, and the mount reports
                # success either way.
                blocked.append(
                    {
                        "kind": kind,
                        "repo": action["repo"],
                        "path": str(path),
                        "source": action["source"],
                        "pack": action.get("pack"),
                    }
                )
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            # Copy, never symlink. Claude Code loads `.claude/rules/*.md`, but it
            # does not follow a symlink there: measured with two rules carrying
            # identical `paths:` frontmatter in one directory, where the regular
            # file was injected on touching the matching source and the link was
            # not. A symlink fails silently — the mount reports success and
            # `ls -l` looks right — so the rules simply never reach the agent.
            # Provenance lives in the manifest's `source`, which is where unmount
            # reads it anyway; and a copy cannot be written through into the
            # pack's own file, which was a hazard the link carried.
            path.write_text(Path(action["source"]).read_text(encoding="utf-8"), encoding="utf-8")
            mode = "copy"
            entries.append(
                {
                    "kind": kind,
                    "repo": action["repo"],
                    "path": str(path),
                    "source": action["source"],
                    "mode": mode,
                    "hash": hash_file(path) if mode == "copy" else "",
                    # Remember what the source looked like, so unmount can say
                    # whether the pack's own file moved on underneath the copy.
                    "source_hash": hash_file(Path(action["source"])),
                    "pack": action.get("pack"),
                }
            )

        elif kind == "file":
            if path.exists():
                die(f"{path} already exists — refusing to overwrite it")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(action["content"], encoding="utf-8")
            entries.append(
                {
                    "kind": "file",
                    "repo": action["repo"],
                    "path": str(path),
                    "hash": hash_file(path),
                }
            )

    for name in touched_repos:
        if name == "<workspace>":
            _update_exclude(ws.root, task, add=True)
        else:
            _update_exclude(ws.repo_path(name), task, add=True)

    manifest = {
        "task": task,
        "session": session_id(),
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "pid": os.getpid(),
        # Whoever mounted holds it first. An agent session that ends releases its
        # own hold; a mount made by a person at a terminal is that person's, and
        # only `deck unmount --task` takes it back.
        "holders": [holder()],
        "repos": sorted(touched_repos),
        # What was asked for, which is not what was written: a repository whose
        # pack is still empty gets nothing placed and would vanish from the
        # record. `deck save` needs it, because the commonest new file is the
        # first artifact a repository ever gets — and a search of what was
        # written would never look in the directory the agent just wrote to.
        "mounted": sorted(asked or touched_repos),
        "entries": entries,
        # Recorded so the condition outlives the one line `deck mount` printed:
        # whoever reads the manifest afterwards can see which of the pack's
        # artifacts are not actually on disk.
        "blocked": blocked,
    }
    path = manifest_path(ws.root, task)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    note_span(ws.root, task, "started", manifest["created"])
    return manifest


def span_path(root: Path, task: str) -> Path:
    return state_root(root) / "state" / "tasks" / f"{task}.json"


def holder() -> str:
    """Who is holding a mount right now.

    An agent session identifies itself; anything else is a person at a terminal.
    The distinction is the whole point: a session's hold is released when that
    session ends, and a person's is not.
    """
    return os.environ.get("CLAUDE_SESSION_ID") or TERMINAL


def holders_of(manifest: dict) -> list[str]:
    """A manifest written before holders existed is treated as a person's.

    Guessing the other way would make an old mount vanish the first time any
    session ends, which is the failure this field exists to stop.
    """
    return manifest.get("holders") or [TERMINAL]


def hold(root: Path, who: str, session: str) -> list[str]:
    """Register `who` against every mount `session` can see. Returns their tasks."""
    held = []
    for manifest in list_manifests(root):
        if manifest.get("session") != session:
            continue
        holders = holders_of(manifest)
        if who not in holders:
            manifest["holders"] = holders + [who]
            manifest_path(root, manifest["task"]).write_text(
                json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
        held.append(manifest["task"])
    return held


def release(root: Path, who: str, manifest: dict) -> list[str]:
    """Drop `who` from a manifest's holders. Returns who is left."""
    left = [h for h in holders_of(manifest) if h != who]
    manifest["holders"] = left
    manifest_path(root, manifest["task"]).write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return left


def stale_sources(manifest: dict) -> list[tuple[str, str, list[str]]]:
    """Rules whose pack file has moved on since the copy was placed.

    A rule is copied, not linked, because a linked rule is never loaded. The
    cost of that is a copy frozen at mount time: edit the pack and every
    repository already carrying the rule keeps the old text, silently. The
    manifest already knows what the source looked like, so the comparison is
    free — what was missing was anybody making it.

    Returns (source path, pack, repositories still holding the old copy).
    """
    by_source: dict[tuple[str, str], list[str]] = {}
    for entry in manifest.get("entries", []):
        if entry.get("kind") != "rule" or not entry.get("source_hash"):
            continue
        source = Path(entry["source"])
        if not source.is_file() or hash_file(source) == entry["source_hash"]:
            continue
        key = (entry["source"], entry.get("pack") or "?")
        by_source.setdefault(key, [])
        if entry.get("repo") not in by_source[key]:
            by_source[key].append(entry.get("repo", "?"))
    return [(src, pack, repos) for (src, pack), repos in by_source.items()]


def edits(ws: Workspace, manifest: dict) -> list[dict]:
    """What changed in the working tree since it was placed, and where it came from.

    Two kinds, and the difference is the whole of the design:

    - **changed** — a placed artifact whose copy no longer hashes to what was
      written. The manifest already records the file it came from, so where the
      edit belongs is not a guess: it goes back to that file, in that layer. An
      edit that should instead become an overlay in a narrower layer is a
      promotion, which is a deliberate act and not this one.
    - **new** — a file that appeared in a directory deck manages and that no
      entry claims. It has no source, so its home comes from where it sits: the
      pack that owns that destination. When nothing in the manifest owns the
      place, deck reports the file and writes nothing, because the alternative
      is inventing a layer on somebody's behalf.

    A placed artifact that was deleted is reported and never propagated: removing
    a rule from a pack is an edit to the pack, and deleting somebody's file
    because a working copy went missing is not a thing to do by inference.
    """
    out: list[dict] = []

    # Claimed by ANY mount in this workspace, not only by this one. Two tasks
    # can be mounted at once over the same tree, and a file the other one placed
    # is not a file nobody placed — reporting it here would tell each task the
    # other's artifacts were unsaved work of its own.
    claimed: set[Path] = {
        Path(e["path"]).resolve()
        for other in list_manifests(ws.root)
        for e in other.get("entries", [])
        if e.get("path")
    }

    for entry in manifest.get("entries", []):
        if entry.get("kind") not in ("rule", "agent", "skill"):
            continue
        path, source = Path(entry["path"]), Path(entry.get("source", ""))
        claimed.add(path.resolve())
        if not path.is_file():
            out.append({"status": "gone", "path": str(path), "source": str(source), "pack": entry.get("pack")})
        elif source.is_file() and hash_file(path) != hash_file(source):
            # Against the SOURCE, not against the hash this mount recorded. The
            # two answer different questions: unmount asks "did somebody change
            # what I put here", and the recorded hash is the only thing that can
            # answer it; save asks "is there anything to carry back", and the
            # pack file is. They come apart the moment two tasks are mounted over
            # one tree — carrying an edit back through one of them left the other
            # reporting the same file as unsaved forever.
            out.append({"status": "changed", "path": str(path), "source": str(source), "pack": entry.get("pack")})

    # Where a repository's own artifacts would go, whether or not any were
    # placed. Derived from the mount rather than from what it wrote, because the
    # commonest new file is the FIRST rule a repository gets — and a pack with
    # nothing in it yet placed nothing, so a search of what was placed would
    # never look in the one directory the agent just wrote to.
    per_repo, _shared, _by_scope, _ = ws.discovered_packs()
    places: list[tuple[Path, str, str]] = []
    for name in manifest.get("mounted") or manifest.get("repos", []):
        pack = per_repo.get(name)
        if pack is None:
            continue
        for folder, into, _kind in ARTIFACTS:
            places.append((ws.repo_path(name) / ".claude" / into, str(pack / folder), name))

    # Files nobody placed, in the directories deck manages. Only those: a
    # repository's own `.claude/` is not deck's to read.
    seen: set[Path] = set()
    for base, home, owner in places + [
        (Path(e["path"]).parent, str(Path(e.get("source", "")).parent), e.get("repo", "<workspace>"))
        for e in manifest.get("entries", [])
        if e.get("kind") in ("rule", "agent", "skill")
    ]:
        if base in seen or not base.is_dir():
            continue
        seen.add(base)
        for found in sorted(base.rglob("*")):
            if not found.is_file() or found.resolve() in claimed:
                continue
            if not found.name.startswith(RULE_PREFIX) and not found.parent.name.startswith(RULE_PREFIX):
                continue
            out.append(
                {
                    "status": "new",
                    "path": str(found),
                    # The prefix comes off. It is a placement mark — it exists so
                    # the exclude block can name deck's files without claiming a
                    # directory the repository also uses — and carrying it back
                    # into the pack would make the next mount place
                    # `deck-deck-<name>`, once per round trip.
                    "source": str(Path(home, found.name.removeprefix(RULE_PREFIX))) if home else "",
                    "repo": owner,
                    "pack": None,
                }
            )
    return out


def save(ws: Workspace, manifest: dict, dry: bool = False) -> tuple[list[str], list[str]]:
    """Carry the working tree's edits back into the collection. (written, refused)

    The manifest is updated with what this now knows, and that is not
    bookkeeping. `deck never deletes what it did not place` is implemented by
    comparing a placed file against the hash recorded for it — so a file that
    was edited stays behind on unmount, correctly, because the edit is somebody's
    unsaved work. Once the edit has been carried back it is not unsaved any more,
    and leaving the record stale meant `save` then `unmount` cleaned nothing at
    all: `0 removed · 1 left alone`, with the new file not even seen. Measured
    before this did it.

    A file edited AFTER the save is protected exactly as before, because the hash
    written here is the one the copy had when it was carried back.
    """
    written, refused = [], []
    entries = manifest.setdefault("entries", [])
    by_path = {e["path"]: e for e in entries}

    for edit in edits(ws, manifest):
        if edit["status"] == "gone":
            refused.append(f"{edit['path']} (deleted in the working tree — remove it from the pack yourself)")
            continue
        if not edit["source"]:
            refused.append(f"{edit['path']} (new, and nothing in this mount owns where it sits)")
            continue
        target = Path(edit["source"])
        if not dry:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(Path(edit["path"]).read_text(encoding="utf-8"), encoding="utf-8")
            entry = by_path.get(edit["path"])
            if entry is None:
                # A file deck did not place becomes one it did, because it now
                # exists in the pack it was carried into. Without this, unmount
                # has no entry for it and leaves it in a repository deck promised
                # to hand back clean.
                entry = {
                    "kind": "rule",
                    "repo": edit.get("repo") or "<workspace>",
                    "path": edit["path"],
                    "source": str(target),
                    "mode": "copy",
                    "pack": edit.get("pack"),
                }
                entries.append(entry)
                by_path[edit["path"]] = entry
            entry["hash"] = hash_file(Path(edit["path"]))
            entry["source_hash"] = hash_file(target)
        written.append(f"{edit['status']:<8} {target}")
    return written, refused


def note_span(root: Path, task: str, field: str, when: str) -> None:
    """Record when a task began and ended, outside the mount manifest.

    The manifest is deliberately transient — it is the list of what is placed
    right now, and unmount deletes it. That made it the wrong place to keep the
    only record of when the task started: after a normal cycle the span was
    gone, and `deck cost --task` lost its lower bound and silently reported an
    open-ended window.
    """
    path = span_path(root, task)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        record = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    except (OSError, ValueError):
        record = {}
    # First mount wins the start; the last unmount wins the end.
    if field == "started" and record.get("started"):
        return
    record[field] = when
    try:
        path.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except OSError:
        pass


# ------------------------------------------------------------------ removing
# Directories deck creates on the way to placing something. Removing a rule and
# leaving `.claude/rules/` behind is litter in someone else's repository, and it
# makes "nothing it places survives an unmount" untrue in the visible way.
OURS = ("rules", ".claude")


def _prune_dirs(removed: list[str]) -> None:
    """Remove the directories the placement created, if they are now empty.

    Only ever upward from a file deck itself removed, only directories it would
    have created, and only while they are empty — a directory holding anything
    else was not deck's to begin with.
    """
    seen: set[Path] = set()
    for entry in removed:
        candidate = Path(entry).parent
        for _ in range(len(OURS)):
            if candidate.name not in OURS or candidate in seen:
                break
            seen.add(candidate)
            try:
                next(candidate.iterdir())
                break  # not empty, so not ours to remove
            except StopIteration:
                candidate.rmdir()
            except OSError:
                break
            candidate = candidate.parent


def remove(ws: Workspace, manifest: dict) -> tuple[list[str], list[str]]:
    """Take back exactly what was placed. Returns (removed, left alone)."""
    removed, kept = [], []

    for entry in manifest.get("entries", []):
        path = Path(entry["path"])
        kind = entry["kind"]

        if kind == "plugin":
            if not path.is_file():
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                kept.append(f"{path} (no longer valid JSON)")
                continue
            enabled = data.get("enabledPlugins") or {}
            for plugin in entry.get("plugins", []):
                if enabled.get(plugin) is True:
                    enabled.pop(plugin)
                    removed.append(f"{path.name}: {plugin}")
                elif plugin in enabled:
                    kept.append(f"{path.name}: {plugin} (changed by someone else)")
            if not enabled:
                data.pop("enabledPlugins", None)
            market = entry.get("marketplace")
            if market:
                known = data.get("extraKnownMarketplaces") or {}
                if market in known:
                    known.pop(market)
                    removed.append(f"{path.name}: marketplace {market}")
                if not known:
                    data.pop("extraKnownMarketplaces", None)
            # A settings file that holds nothing but what we added goes away;
            # one with anything else in it stays.
            if not data:
                path.unlink()
                # The directory too, when it is empty and deck made it. An empty
                # `.claude/` is not a file anybody wrote, but it is `?? .claude/`
                # in `git status`, which is the same surprise in a repository
                # deck promised not to touch.
                parent = path.parent
                if parent.name == ".claude" and not any(parent.iterdir()):
                    parent.rmdir()
            else:
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

        elif kind in ("rule", "agent", "skill"):
            if path.is_symlink():
                source = Path(entry.get("source", ""))
                if entry.get("source_hash") and hash_file(source) != entry["source_hash"]:
                    # The link was written through: the pack file itself changed.
                    # Removing the link is still right; the edit is not ours to
                    # revert, and someone should know it happened.
                    kept.append(f"{source} (the pack file was edited through the mounted link)")
                if str(Path(os.readlink(path))) == entry.get("source"):
                    path.unlink()
                    removed.append(str(path))
                else:
                    kept.append(f"{path} (points somewhere else now)")
            elif path.is_file():
                if entry.get("hash") and hash_file(path) == entry["hash"]:
                    path.unlink()
                    removed.append(str(path))
                else:
                    kept.append(f"{path} (edited since it was placed)")

        elif kind == "file":
            if not path.is_file():
                continue
            if hash_file(path) == entry.get("hash"):
                path.unlink()
                removed.append(str(path))
            else:
                kept.append(f"{path} (edited since it was placed)")

    for name in manifest.get("repos", []):
        try:
            _update_exclude(ws.root if name == "<workspace>" else ws.repo_path(name), manifest["task"], add=False)
        except SystemExit:
            continue

    _prune_dirs(removed)
    note_span(ws.root, manifest["task"], "ended", time.strftime("%Y-%m-%dT%H:%M:%S"))

    path = manifest_path(ws.root, manifest["task"])
    if not kept:
        path.unlink(missing_ok=True)
    else:
        # Something was left behind: keep the manifest so a later unmount, or a
        # person, can finish the job knowingly.
        pending = [e for e in manifest["entries"] if any(str(e["path"]) in k for k in kept)]
        manifest["entries"] = pending
        if not pending:
            path.unlink(missing_ok=True)
            return removed, kept
        path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    return removed, kept
