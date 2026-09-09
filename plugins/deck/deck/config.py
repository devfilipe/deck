"""Configuration loading, caching, and session identity.

Everything that reads a file from disk goes through here, so caching and error
reporting stay in one place.
"""

from __future__ import annotations

import re
import json
import os
import subprocess
import sys
import unicodedata
from pathlib import Path

STATE_DIR = ".deck"

# The machine's file, wherever the state for a workspace lives.
MACHINE_FILE = "machine.yaml"


def home_state() -> Path:
    """`~/.deck` — what is yours and this machine's, kept out of the project.

    A project a team shares must not carry one person's answer to "where is my
    checkout of the collection", "which machines may I reach", or "which
    initiative am I in". `${ENV}HOME_STATE` moves it, which is the only reason
    the suite can run without touching the person running it.
    """
    named = os.environ.get(f"{ENV_PREFIX}HOME_STATE")
    return Path(named).expanduser() if named else Path.home() / ".deck"


def selected_scope() -> str | None:
    """The `<name>/<scope>` pair selected for this machine, or None."""
    path = home_state() / "selected"
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip() or None


def write_selection(value: str | None) -> None:
    """Record the selection, or clear it."""
    path = home_state() / "selected"
    path.parent.mkdir(parents=True, exist_ok=True)
    if value:
        path.write_text(value + "\n", encoding="utf-8")
    elif path.is_file():
        path.unlink()


def state_root(root: Path | None) -> Path:
    """Where this workspace's machine state lives: evidence, series, mounts.

    Under `~/.deck/workspaces/<name>/` when a workspace has been named — which
    is what `deck setup` does the moment a collection is given. The project tree
    then holds nothing of deck's between a mount and its unmount, which is the
    whole point: a repository somebody else owns should not carry a directory of
    yours it has to be told to ignore.


    Keyed by the workspace's name rather than by its absolute path, so moving
    the checkout costs a line in one file instead of the evidence of every run.

    Falling back to `<root>/.deck` for a workspace with no collection and so no
    name — somebody on their first day, whose state has nowhere else to be.
    """
    chosen = selected_scope()
    if chosen:
        here = home_state() / "workspaces" / chosen.split("/")[0]
        # Only when the selection is about THIS tree. A selection is global —
        # one at a time, for the person — and a command pointed at another
        # workspace by ${ENV}ROOT is not in it. Without this test, every
        # synthetic workspace in the suite read the state of whatever the person
        # running it happened to have selected, and 359 checks failed on a
        # machine with a selection and none on a machine without one.
        machine = here / MACHINE_FILE
        if machine.is_file():
            declared = (load_yaml(machine) or {}).get("root")
            if root is None or declared is None or Path(str(declared)).resolve() == Path(root).resolve():
                return here
        elif root is None:
            # Nothing to compare against and no root to fall back to: this is
            # `find_root` asking where the machine file would be, before there
            # is a workspace at all.
            return here
    return (root or Path.cwd()) / STATE_DIR


ENV_PREFIX = "DECK_"

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "deck"


def die(message: str) -> None:
    sys.exit(f"deck: {message}")


def _yaml():
    """Imported on demand.

    The status line runs on every session event; with a warm cache it should not
    pay the ~16 ms of loading PyYAML.
    """
    try:
        import yaml
    except ImportError:  # pragma: no cover
        die("PyYAML not found. Install it with: pip install pyyaml")
    return yaml


def _cache_path(path: Path) -> Path:
    """One cache file per source file, so the cache never grows unbounded."""
    slug = "".join(c if c.isalnum() else "-" for c in str(path))[-120:]
    return CACHE_DIR / f"{slug}.json"


def load_yaml(path: Path) -> dict:
    """Read YAML through a JSON mirror keyed by mtime and size.

    Parsing a large toggle catalog costs tens of milliseconds. Re-read on every
    status line refresh, that shows. The mirror drops it to about 2 ms and
    invalidates itself when the source file changes.
    """
    if not path.is_file():
        return {}
    stat = path.stat()
    cache = _cache_path(path)
    try:
        held = json.loads(cache.read_text(encoding="utf-8"))
        if held.get("mtime") == stat.st_mtime_ns and held.get("size") == stat.st_size:
            return held["data"]
    except (OSError, ValueError, KeyError):
        pass

    yaml = _yaml()
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        die(f"{path}: invalid YAML — {exc}")

    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        cache.write_text(
            json.dumps({"mtime": stat.st_mtime_ns, "size": stat.st_size, "data": data}),
            encoding="utf-8",
        )
    except (OSError, TypeError, ValueError):
        pass  # a value JSON cannot round-trip (a date, say): carry on uncached
    return data


def _anchor(line: str) -> str:
    """What a comment is anchored to: the key it sits above, at its indent.

    Not the whole line. `values: {}` becomes `values:` the moment the block gains
    its first entry, and that transition is the commonest thing that happens to
    this file — anchoring on the text would orphan the paragraph explaining the
    block exactly when somebody first uses it. A line that is not `key: value`
    (a list item, say) anchors on itself, having no key to hold on to.
    """
    head, sep, _ = line.partition(":")
    return f"{head}:" if sep else line


def _comment_runs(text: str) -> tuple[list[str], list[tuple[str | None, list[str]]]]:
    """A file's comments, each tied to the line it sits above.

    Returns the leading block — everything before the first line of data — and
    then one entry per later run. A run at the end of the file has no line below
    it and is returned with `None`, which is not the same as having no run: the
    first draft of this dropped those, and the toggle template ends with a ten
    line example of a `repos:` block that went with them.
    """
    header: list[str] = []
    runs: list[tuple[str | None, list[str]]] = []
    pending: list[str] = []
    seen_data = False
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#") or (not stripped and not seen_data):
            pending.append(line)
            continue
        if not stripped:
            if pending:
                pending.append(line)
            continue
        if not seen_data:
            seen_data = True
            header, pending = pending, []
        if pending:
            runs.append((_anchor(line), pending))
            pending = []
    if pending:
        runs.append((None, pending))
    return header, runs


def _reattach(body: str, header: list[str], runs: list[tuple[str | None, list[str]]]) -> str:
    """Put the comments back, above the lines they were written above.

    Anchored on a key rather than a position, since the dump reorders nothing
    but may add or drop entries around it. A run whose anchor no longer exists
    is kept at the end under a note: `.deck/` is machine state and is not
    versioned, so a comment deck drops is gone for good, and moving somebody's
    sentence is recoverable where deleting it is not.
    """
    out = list(header) + body.rstrip("\n").split("\n")
    tail: list[str] = []
    orphans: list[str] = []
    for anchor, comment in runs:
        if anchor is None:
            tail += comment
            continue
        at = next((i for i in range(len(header), len(out)) if _anchor(out[i]) == anchor), None)
        if at is None:
            orphans += comment
            continue
        out[at:at] = comment
    if orphans:
        out += [
            "",
            "# Written above lines that are no longer in this file, and kept here rather",
            "# than dropped: this file is not versioned, so what deck deletes is gone.",
            *orphans,
        ]
    out += tail
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"


def dump_yaml(path: Path, data: dict) -> None:
    """Write a mapping, keeping the comments the file already had.

    `safe_dump` rewrites the whole file, so every `deck toggle set` used to
    delete the header explaining the file it was writing to — the block on layer
    precedence, on `ask`, on what `reasons:` is for. That header is shipped by
    `deck init` and is most of what makes the file readable by a person, and it
    survived exactly until the first value was recorded.

    Comments are re-attached by hand rather than round-tripped, which is a
    deliberate refusal of a dependency: `ruamel.yaml` would do this properly and
    is one more thing every install has to carry, for one behaviour in a handful
    of files. pyyaml stays the only requirement.

    The limit, stated because it is real: a comment is anchored on the text of
    the line below it. Two identical lines in one file resolve to the first, and
    a comment written on the same line as a value is not a run of its own and
    does not survive.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    body = _yaml().safe_dump(data, allow_unicode=True, sort_keys=False)
    if path.is_file():
        header, runs = _comment_runs(path.read_text(encoding="utf-8"))
        if header or runs:
            body = _reattach(body, header, runs)
    path.write_text(body, encoding="utf-8")


def norm(value) -> str:
    """Everything becomes a string; booleans become 'true'/'false'.

    YAML turns unquoted `off`, `on`, `yes` and `no` into booleans, which is a
    sharp edge in a file full of enum values. Normalising once removes it.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def slug(value: str) -> str:
    """Make a string safe to use as a filename."""
    return "".join(c if c.isalnum() or c in "-_" else "-" for c in value)[:64]


def run(cmd: list[str], timeout: int = 10, cwd: str | Path | None = None) -> tuple[int, str]:
    """Run a command, never raise. Returns (exit code, combined output).

    `cwd` matters more than it looks: a pack declares its adapter and its gate
    commands as paths relative to the workspace root, and running them from
    wherever the process happens to sit makes them work only when someone is
    already standing in the right directory.
    """
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False, cwd=str(cwd) if cwd else None
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except FileNotFoundError:
        return 127, "command not found"
    except subprocess.SubprocessError as exc:
        return 1, str(exc)


_session_cache: str | None = None


def session_id(explicit: str | None = None) -> str:
    """Identity of the `task` scope, shared by whoever is working together.

    Inside tmux this derives from the WINDOW, so an agent pane and a console
    pane reach the same value on their own, with no variable exported between
    them. Two panes of one window are one task, which is what a split screen
    means.

    Memoized in a module-level variable, not `functools.lru_cache`: the window
    cannot change during one process's life, so asking `tmux display-message`
    more than once per render was pure waste — a status line drawn once per
    prompt used to shell out for this three times over (`journal_sample`, the
    task file, and `Toggles.__init__`), each a process spawn plus tmux's own
    round trip to its server. The cache is a plain module global rather than
    `lru_cache` so it survives being called with and without an explicit value
    in the same process without either poisoning the other's slot, and so nothing
    is memoized across processes: the next prompt may be a different tmux window,
    and a decorator-level cache invites someone to hoist it somewhere that
    outlives one render.
    """
    if explicit:
        return slug(explicit)
    global _session_cache
    if _session_cache is not None:
        return _session_cache
    if os.environ.get(f"{ENV_PREFIX}SESSION"):
        _session_cache = slug(os.environ[f"{ENV_PREFIX}SESSION"])
        return _session_cache
    if os.environ.get("TMUX"):
        # -t $TMUX_PANE pins the query to THIS pane's window; without it
        # display-message answers about whichever window the client is viewing.
        target = ["-t", os.environ["TMUX_PANE"]] if os.environ.get("TMUX_PANE") else []
        code, out = run(["tmux", "display-message", *target, "-p", "#{session_name}:#{window_index}"], timeout=3)
        if code == 0 and out:
            _session_cache = slug("tmux-" + out)
            return _session_cache
    if os.environ.get("CLAUDE_SESSION_ID"):
        _session_cache = slug(os.environ["CLAUDE_SESSION_ID"])
        return _session_cache
    _session_cache = "default"
    return _session_cache


def publish_identity(anchor: Path | None = None) -> tuple[str | None, str]:
    """The name a file written at `anchor` is published under, and where it came from.

    `$USER` is whatever the machine calls you, and a board file is committed:
    this repository's own board carried a shell login on seven `assignee:` lines
    towards a public push under a different identity, and nothing between the
    write and the push ever questioned it. So a name recorded in a file is the
    name the repository already publishes under — `user.name`, the author line
    on every commit that file will ever appear in.

    Which repository, when a workspace holds several whose identities disagree,
    is not a question deck answers. It asks git from the directory the file is
    written to, so the answer is whichever configuration would sign the commit
    that carries it: that repository's own `user.name`, or the global one when
    the file sits outside any repository. Ranking the registry to pick a likely
    one would be a guess, and this is the one place where guessing publishes
    somebody else's name.

    `$DECK_USER` overrides it, for the person whose git identity is not the name
    they take work under. Returns `None` when there is nothing to record, which
    the caller reports — an empty name is a fact, not a reason to reach for the
    login again.
    """
    override = os.environ.get(f"{ENV_PREFIX}USER")
    if override:
        return override, f"${ENV_PREFIX}USER"
    code, out = run(["git", "-C", str(anchor or Path.cwd()), "config", "user.name"], timeout=5)
    name = out.splitlines()[0].strip() if code == 0 and out.strip() else ""
    return (name, "git user.name") if name else (None, "not set")


def core_root() -> Path:
    """Root of the deck plugin, holding config, schema and templates."""
    env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env and (Path(env) / "config" / "toggles.core.yaml").is_file():
        return Path(env)
    return Path(__file__).resolve().parent.parent


def pack_dirs() -> list[Path]:
    """Extension packs, in the order their configuration is merged.

    A pack is any directory holding a `config/` with catalog fragments. They are
    found through DECK_PACKS (colon separated) and through the `packs:` list in
    the workspace descriptor, which the caller passes in.
    """
    raw = os.environ.get(f"{ENV_PREFIX}PACKS", "")
    return [Path(p).expanduser() for p in raw.split(":") if p.strip()]


def task_file(root: Path, session: str) -> Path:
    """Where answers scoped to the current task live."""
    return state_root(root) / "state" / f"toggles-{session}.yaml"


def title_slug(name: str, limit: int = 48) -> str:
    """A title becomes a file name that survives a shared repository.

    Not `slug` above, which makes an arbitrary string safe to use as a filename
    and keeps its case — a session id read from a tmux window name depends on
    that, and on nothing being dropped. This one is for a sentence somebody
    wrote: it lowercases, transliterates, and cuts on a word boundary so the
    result reads.

    Two callers need it: a drafted rule from `propose apply`, and an answered
    consultation folded by `ask fold`. Both arrive as a sentence somebody or
    something wrote, and both become a file name in a shared repository.

    A draft comes from a model, so the title carries whatever punctuation it
    felt like: em-dashes, commas, quotes, and -- worse -- slashes, which would
    silently make a directory. Anything outside [a-z0-9] collapses to a single
    dash, and the cut lands on a word boundary, so the name reads as words
    instead of stopping mid-syllable.
    """
    ascii_only = unicodedata.normalize("NFKD", norm(name)).encode("ascii", "ignore").decode()
    words = re.findall(r"[a-z0-9]+", ascii_only.lower())
    out = ""
    for word in words:
        candidate = f"{out}-{word}" if out else word
        if len(candidate) > limit:
            break
        out = candidate
    return out or "rule"
