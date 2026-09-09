"""Instruction files in the tree that deck did not place.

deck mounts what packs declare and reports what it placed. Anything already in
the working tree it neither wrote nor knows about — and one of those files
carries more weight than anything deck mounts: a `CLAUDE.md` above the working
directory is loaded at launch, every launch, while a `paths:`-scoped rule is
loaded only when something it matches is read.

So this is a second source of instruction, and until it is named, nothing
compares the two. It is reported, never acted on: a file in somebody's tree may
be perfectly deliberate, and deck deciding otherwise would be deck governing a
repository it does not own. Nothing here edits, moves, or reads the contents.

Whether it is versioned is half the value. The one that prompted this sits in a
directory that is inside no git repository at all — no history, no review, no
owner — in a workspace whose team had decided instructions are reviewed like
code.
"""

from __future__ import annotations

from pathlib import Path

from .config import run
from .mount import list_manifests
from .workspace import Workspace, git_toplevel

# The names other agent tools load without being asked. Each one is a documented
# location, not a guess.
#
# It is a default rather than the answer because the list dates the moment a
# tool ships a new one: a descriptor's `instruction_files:` replaces it, which
# is how a team adds the file its own tooling reads and drops one it has decided
# it does not want named again.
DEFAULT_NAMES = (
    "CLAUDE.md",
    "CLAUDE.local.md",
    "AGENTS.md",
    ".cursor/rules",
    ".clinerules",
    ".github/copilot-instructions.md",
)

DESCRIPTOR_KEY = "instruction_files"

# Where it sits relative to the workspace, which is what decides how much it
# weighs. An ancestor's file is loaded before deck has said anything at all.
ABOVE, HERE, INSIDE = "above the workspace", "the workspace root", "in a repository"


def names(ws: Workspace) -> list[str]:
    """The names to look for: the descriptor's list, or the default one."""
    declared = (ws.data or {}).get(DESCRIPTOR_KEY)
    if declared is None:
        return list(DEFAULT_NAMES)
    return [str(n) for n in declared]


def versioned(path: Path) -> str | None:
    """The repository tracking `path`, or None when nothing is.

    Two ways to be unreviewable, and they read differently to whoever has to act
    on it: a file inside no checkout, and a file inside one that never added it.
    """
    top = git_toplevel(path.parent)
    if top is None:
        return None
    code, _ = run(["git", "-C", str(path.parent), "ls-files", "--error-unmatch", path.name])
    return str(top) if code == 0 else None


def _placed(root: Path) -> set[str]:
    """Every path deck currently holds a mount for.

    Without this, the file deck itself writes at the workspace root —
    `CLAUDE.local.md` — is reported as somebody else's the moment a task is
    mounted, and the report accuses deck of the thing it exists to find.
    """
    out: set[str] = set()
    for manifest in list_manifests(root):
        for entry in manifest.get("entries", []):
            if entry.get("path"):
                out.add(str(Path(entry["path"]).resolve()))
    return out


def _look(base: Path, where: str, wanted: list[str], placed: set[str]) -> list[dict]:
    found = []
    for name in wanted:
        path = base / name
        # `.cursor/rules` is a directory and the rest are files; both exist or
        # do not, and neither is opened.
        if not path.exists():
            continue
        if str(path.resolve()) in placed:
            continue
        found.append({"path": path, "where": where, "repo": versioned(path)})
    return found


def unmanaged(ws: Workspace, extra: list[Path] | None = None) -> list[dict]:
    """Instruction files in and above this workspace that no mount placed.

    Ancestors are walked to the filesystem root on purpose. The measured case
    was a file two levels above the workspace, outside every checkout, and a
    search that stopped at the workspace root would have missed exactly the one
    with the strongest position.

    `extra` is for `deck setup`, which is asking this question before there is a
    descriptor to read: it has just walked the tree and knows the checkouts the
    registry does not hold yet.
    """
    if not ws.root:
        return []
    wanted = names(ws)
    if not wanted:
        return []
    root = ws.root.resolve()
    placed = _placed(ws.root)

    found: list[dict] = []
    seen: set[Path] = set()
    for parent in reversed(root.parents):
        found += _look(parent, ABOVE, wanted, placed)
    found += _look(root, HERE, wanted, placed)
    seen.add(root)
    for path in [ws.repo_path(name) for name in ws.repos] + list(extra or []):
        path = path.resolve()
        # A monorepo's registry points at the root, and the root is covered
        # above; `extra` may repeat what the registry already holds.
        if path in seen or not path.is_dir():
            continue
        seen.add(path)
        found += _look(path, INSIDE, wanted, placed)
    return found


def describe(entry: dict) -> str:
    """One line: the path, where it sits, and whether anyone could review it."""
    state = "versioned" if entry["repo"] else "not versioned"
    return f"{entry['path']}  ({entry['where']}, {state})"
