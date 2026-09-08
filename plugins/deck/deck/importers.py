"""Registry importers: derive the repository list from how the tree is assembled.

Writing out twenty repositories by hand is the tedious half of a descriptor, and
the half a tool can do. These importers read the file that already declares the
layout — a repo manifest, `.gitmodules`, a workspaces field — and produce the
`repos:` block.

What they deliberately do NOT produce is `impacts`. Nothing in a manifest says
that changing the schema forces the client to be rebuilt; that is knowledge
about the system, and it has to be written down by someone who has it. The
importer leaves the edges empty and says so.

Layout is core. A build system is not: bitbake targets, chart names and test
suites arrive from an extension pack.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from .config import run

SOURCES = ("repo", "submodules", "npm")


def detect(root: Path) -> list[str]:
    """Which importers could work on this tree."""
    found = []
    if (root / ".repo").is_dir():
        found.append("repo")
    if (root / ".gitmodules").is_file():
        found.append("submodules")
    package = root / "package.json"
    if package.is_file() and '"workspaces"' in package.read_text(encoding="utf-8", errors="ignore"):
        found.append("npm")
    return found


# --------------------------------------------------------------------- repo
def _manifest_files(root: Path) -> list[Path]:
    """The manifest, plus whatever it includes.

    `.repo/manifest.xml` is a symlink into `.repo/manifests/`; older checkouts
    keep the file directly. Both shapes resolve here.
    """
    base = root / ".repo"
    candidates = [base / "manifest.xml", base / "manifests" / "default.xml"]
    primary = next((c for c in candidates if c.is_file()), None)
    if not primary:
        return []

    files = [primary]
    seen = {primary.resolve()}
    queue = [primary]
    while queue:
        current = queue.pop()
        try:
            tree = ET.parse(current)
        except ET.ParseError:
            continue
        for include in tree.getroot().findall("include"):
            name = include.get("name")
            if not name:
                continue
            target = (base / "manifests" / name).resolve()
            if target.is_file() and target not in seen:
                seen.add(target)
                files.append(target)
                queue.append(target)
    return files


def from_repo(root: Path) -> dict:
    """Read a Google `repo` manifest into a repository registry."""
    repos: dict[str, dict] = {}
    for manifest in _manifest_files(root):
        try:
            tree = ET.parse(manifest)
        except ET.ParseError:
            continue
        node = tree.getroot()

        remotes = {r.get("name"): r.get("fetch", "") for r in node.findall("remote")}
        default = node.find("default")
        default_remote = default.get("remote") if default is not None else None
        default_revision = default.get("revision") if default is not None else None

        for project in node.findall("project"):
            name = project.get("name")
            if not name:
                continue
            path = project.get("path") or name
            key = Path(path).name
            remote = project.get("remote") or default_remote
            entry = {
                "path": path,
                "remote_id": name.removesuffix(".git"),
                "impacts": [],
            }
            revision = project.get("revision") or default_revision
            if revision:
                entry["revision"] = revision
            if remote and remote in remotes:
                entry["remote"] = remote
            repos[key] = entry
    return repos


# -------------------------------------------------------------- submodules
def from_submodules(root: Path) -> dict:
    """Read `.gitmodules` through git itself, so the parsing matches git's."""
    code, out = run(["git", "-C", str(root), "config", "-f", ".gitmodules", "--list"])
    if code != 0:
        return {}
    modules: dict[str, dict] = {}
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        parts = key.split(".")
        if len(parts) < 3 or parts[0] != "submodule":
            continue
        name, field = ".".join(parts[1:-1]), parts[-1]
        modules.setdefault(name, {})[field] = value

    repos = {}
    for name, fields in modules.items():
        path = fields.get("path", name)
        entry = {"path": path, "impacts": []}
        url = fields.get("url")
        if url:
            entry["remote_id"] = url.rstrip("/").removesuffix(".git").split("/")[-1]
        repos[Path(path).name] = entry
    return repos


# --------------------------------------------------------------------- npm
def from_npm(root: Path) -> dict:
    """Read the `workspaces` globs of a package.json."""
    import json

    try:
        package = json.loads((root / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    globs = package.get("workspaces")
    if isinstance(globs, dict):
        globs = globs.get("packages") or []
    repos = {}
    for pattern in globs or []:
        for path in sorted(root.glob(pattern)):
            if not (path / "package.json").is_file():
                continue
            rel = path.relative_to(root)
            repos[path.name] = {"path": str(rel), "impacts": []}
    return repos


IMPORTERS = {"repo": from_repo, "submodules": from_submodules, "npm": from_npm}


def load(source: str, root: Path) -> dict:
    if source not in IMPORTERS:
        raise KeyError(source)
    return IMPORTERS[source](root)


def merge(existing: dict, imported: dict) -> tuple[dict, list[str], list[str]]:
    """Fold an import into an existing registry without losing authored work.

    Imported fields describe layout and may be refreshed freely. Everything a
    person wrote — `impacts` above all, but also build targets, services and
    roles — survives untouched. Returns (registry, added, dropped).
    """
    layout_fields = ("path", "remote_id", "remote", "revision")
    registry = dict(existing)

    # Match on `path` before name. A descriptor may well call `clients/web`
    # something more descriptive than its directory; re-importing must update
    # that entry, not add a second one beside it.
    by_path = {entry.get("path"): name for name, entry in existing.items() if entry.get("path")}

    added, matched = [], set()
    for name, entry in imported.items():
        target = name if name in registry else by_path.get(entry.get("path"))
        if target is None:
            registry[name] = entry
            added.append(name)
            matched.add(name)
            continue
        matched.add(target)
        for field in layout_fields:
            if field in entry:
                registry[target][field] = entry[field]
        registry[target].setdefault("impacts", [])

    dropped = [name for name in existing if name not in matched]
    return registry, added, dropped
