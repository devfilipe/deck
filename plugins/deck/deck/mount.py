"""Place and remove agent artifacts in working directories.

Packs live outside the product repositories and have to be *inside* the
directory an agent works in to be loaded. Mounting is how they get there, and
unmounting is why anyone lets you do it.

Three strategies, in order of preference. Copying a file into somebody's product
repository is the last resort, not the first:

    plugin   enable the pack in <repo>/.claude/settings.local.json — the content
             stays in one versioned place, the repository gets three lines
    rule     copy a rule file into <repo>/.claude/rules/ — reversible, and the
             manifest records which pack each one came from
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

from .config import STATE_DIR, die, load_yaml, session_id
from .workspace import Workspace, git_toplevel

RULE_PREFIX = "deck-"
TERMINAL = "terminal"
EXCLUDE_BEGIN = "# deck: begin"
EXCLUDE_END = "# deck: end"

EXCLUDE_LINES = [
    ".claude/settings.local.json",
    f".claude/rules/{RULE_PREFIX}*.md",
    "CLAUDE.local.md",
]


def hash_file(path: Path) -> str:
    try:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()[:32]
    except OSError:
        return ""


def mounts_dir(root: Path) -> Path:
    return root / STATE_DIR / "mounts"


def manifest_path(root: Path, task: str) -> Path:
    return mounts_dir(root) / f"{task}.json"


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


# ------------------------------------------------------------------ planning
def _pack_mount_config(pack: Path) -> dict:
    return load_yaml(pack / "config" / "mount.yaml")


def mounted_rules(pack: Path) -> set[str]:
    """The rule files `mount.yaml` names, as paths relative to the pack."""
    config = _pack_mount_config(pack)
    return {str(entry.get("file")) for entry in (config.get("rules") or []) if entry.get("file")}


def unmounted_rules(pack: Path) -> list[str]:
    """Rule files in the pack that `mount.yaml` does not name.

    A rule reaches an agent only by being listed there, so one that is not is a
    file on disk and nothing else — placed, counted by whoever wrote it, and
    read by nobody. `pack new` ships exactly one on purpose, `rules/example.md`,
    which is a sample and not meant to be mounted; it is excluded rather than
    reported, so the check stays quiet on a pack nobody has filled in yet.
    """
    rules = pack / "rules"
    if not rules.is_dir():
        return []
    named = mounted_rules(pack)
    return sorted(
        f"rules/{f.name}" for f in rules.glob("*.md") if f.name != "example.md" and f"rules/{f.name}" not in named
    )


def record_rules(pack: Path, files: list[str]) -> list[str]:
    """Add rule entries to a pack's `mount.yaml`, and say which were added.

    Text, not a parse-and-dump: `mount.yaml` as `pack new` writes it is mostly
    commented instruction, and a round trip through the YAML loader would answer
    a person's file with a machine's.

    Entries are unscoped. `repos:` narrows a rule to some of the repositories a
    pack covers, and choosing that for someone would be a guess — but leaving
    the entry out is not the neutral alternative it looks like, because the rule
    then reaches nobody at all. The unscoped entry is what the pack already
    means by default, and it is visible in the file for anyone to narrow.
    """
    target = pack / "config" / "mount.yaml"
    named = mounted_rules(pack)
    fresh = [f for f in files if f not in named]
    if not fresh:
        return []
    body = target.read_text(encoding="utf-8") if target.is_file() else ""
    lines = body.rstrip("\n").split("\n") if body.strip() else []
    rows = [f"  - {{ file: {f} }}" for f in fresh]

    where = next((i for i, ln in enumerate(lines) if ln.rstrip() == "rules:"), None)
    if where is None:
        lines += ([""] if lines else []) + ["rules:"] + rows
    else:
        # After the whole `rules:` block, so the drafted entries follow the
        # commented examples rather than splitting them from their heading.
        end = where + 1
        while end < len(lines) and (
            not lines[end].strip() or lines[end].lstrip().startswith("#") or lines[end].startswith((" ", "\t"))
        ):
            end += 1
        lines[end:end] = rows
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return fresh


def plan(ws: Workspace, repos: list[str], brief: str | None = None) -> list[dict]:
    """What would be placed, without placing anything."""
    actions: list[dict] = []

    for name in repos:
        entry = ws.repo(name)
        repo_dir = ws.repo_path(name)
        if not repo_dir.is_dir():
            die(f"{name}: path does not exist — {entry.get('path')}")

        # Which packs apply to this repository: the ones it names, or every
        # pack whose own scope covers it when it names none. That scope matters
        # — a pack named after a sibling repository is not a workspace-wide
        # pack, and its rules have no business landing here.
        wanted = entry.get("packs")
        applicable = [p for p in ws.packs_for(name) if not wanted or p.name in wanted]

        for pack in applicable:
            config = _pack_mount_config(pack)
            plugin = config.get("plugin")
            if plugin:
                actions.append(
                    {
                        "kind": "plugin",
                        "repo": name,
                        "path": str(repo_dir / ".claude" / "settings.local.json"),
                        "plugins": [plugin],
                        "marketplace": config.get("marketplace"),
                        "pack": pack.name,
                    }
                )
            for rule in config.get("rules") or []:
                only = rule.get("repos")
                if only and name not in only:
                    continue
                source = (pack / rule["file"]).resolve()
                if not source.is_file():
                    die(f"{pack.name}: rule file not found — {rule['file']}")
                target = repo_dir / ".claude" / "rules" / f"{RULE_PREFIX}{source.stem}.md"
                actions.append(
                    {
                        "kind": "rule",
                        "repo": name,
                        "path": str(target),
                        "source": str(source),
                        "pack": pack.name,
                    }
                )

    # The brief is one description of one task, so it is written once, at the
    # workspace root. A root CLAUDE.local.md loads at launch and applies to
    # every repository below it; a copy per repository would say the same thing
    # four times and load four times.
    if brief:
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


def apply(ws: Workspace, actions: list[dict], task: str) -> dict:
    """Place the artifacts and write the manifest that lets us take them back."""
    entries, touched_repos = [], set()

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

        elif kind == "rule":
            if path.exists() or path.is_symlink():
                continue  # never overwrite what is already there
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
                    "kind": "rule",
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
        "entries": entries,
    }
    path = manifest_path(ws.root, task)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    note_span(ws.root, task, "started", manifest["created"])
    return manifest


def span_path(root: Path, task: str) -> Path:
    return root / STATE_DIR / "state" / "tasks" / f"{task}.json"


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

        elif kind == "rule":
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
