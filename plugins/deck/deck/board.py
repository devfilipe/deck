"""Read a board of tasks and work out what can run at the same time.

This module deliberately stops short of running anything. Claude Code already
orchestrates agents — subagents, worktree isolation, and a workflow runtime with
`parallel()` and `pipeline()` — and reimplementing that would be building a
worse copy of something that ships in the box.

What Claude Code cannot know is *this* workspace: that a change to the schema
reaches the client, that two tasks touching the same chain must not run at once,
and that a hardware target is an exclusive resource. That is the deterministic
part, and it is what lives here.

The output is a plan. A workflow script executes it.
"""

from __future__ import annotations

import re
from pathlib import Path

from . import trackers
from .config import dump_yaml, load_yaml, norm, run
from .workspace import Workspace

CHECKLIST = re.compile(r"^\s*[-*]\s+\[( |x|X)\]\s+(.+?)\s*$")
TASK_ID = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")
REPO_HINT = re.compile(r"`([^`]+)`")


def _tasks_from_yaml(path: Path) -> list[dict]:
    """A plain list of tasks, the shape deck writes when nothing else exists."""
    data = load_yaml(path)
    out = []
    for item in data.get("tasks") or []:
        out.append(
            {
                "id": norm(item.get("id") or item.get("title", "?"))[:32],
                "title": norm(item.get("title", "")),
                "repos": [norm(r) for r in (item.get("repos") or [])],
                "exclusive": bool(item.get("exclusive")),
                "target": item.get("target"),
                "status": norm(item.get("status", "open")),
                # Carried through, not dropped: without `assignee` the ownership
                # check never fires and two people take the same task.
                "assignee": item.get("assignee"),
                "labels": [norm(x) for x in (item.get("labels") or [])],
                "url": item.get("url"),
                "ext_provider": norm(item.get("ext_provider", "")) or None,
                "ext_id": norm(item.get("ext_id", "")) or None,
                "decides": [norm(x) for x in (item.get("decides") or [])],
                # The briefing half. A title and a repository say what to touch;
                # they never say what it is for or how anyone would know it
                # worked. An agent given only those does the plausible thing and
                # reports that it did it.
                "as_a": item.get("as_a"),
                "so_that": item.get("so_that"),
                "acceptance": [str(a) for a in (item.get("acceptance") or [])],
                "accepted": [str(a) for a in (item.get("accepted") or [])],
                "notes": item.get("notes"),
            }
        )
    return out


def _tasks_from_checklist(path: Path, repos: list[str]) -> list[dict]:
    """Markdown checkboxes, which is what most teams' roadmaps actually are.

    Repositories are picked up from backticked names that match the registry.
    Anything the text does not name stays empty, and an empty task is reported
    rather than guessed at.
    """
    out = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for line in lines:
        match = CHECKLIST.match(line)
        if not match:
            continue
        done, title = match.group(1).lower() == "x", match.group(2)
        ident = TASK_ID.search(title)
        named = [name for name in REPO_HINT.findall(title) if name in repos]
        out.append(
            {
                "id": ident.group(1) if ident else re.sub(r"[^A-Za-z0-9]+", "-", title.lower())[:32].strip("-"),
                "title": title,
                "repos": named,
                "exclusive": False,
                "target": None,
                "status": "done" if done else "open",
                "assignee": None,
                "labels": [],
                "url": None,
            }
        )
    return out


def _tasks_from_command(command: str, cwd: Path) -> tuple[list[dict], str | None]:
    """A pack's own adapter: any command that prints a JSON list of tasks.

    The same shape as the importers. It keeps a board format the engine has
    never heard of — a tracker export, a requirements matrix — out of the engine.
    """
    import json

    # From the workspace root. `cwd` was accepted here and never passed on, so a
    # pack's adapter — declared, like every other pack path, relative to the
    # root — resolved only when the operator happened to be standing there. It
    # worked for a day and broke the moment deck was run from anywhere else.
    code, out = run(["bash", "-c", command], timeout=60, cwd=cwd)
    if code != 0:
        return [], f"exit {code}: {(out or 'no output').splitlines()[-1][:160]}"
    try:
        data = json.loads(out)
    except ValueError:
        return [], f"the adapter printed something that is not JSON: {out[:120]}"
    items = data.get("tasks") if isinstance(data, dict) else data
    return [
        {
            "id": norm(t.get("id", "?")),
            "title": norm(t.get("title", "")),
            "repos": [norm(r) for r in (t.get("repos") or [])],
            "exclusive": bool(t.get("exclusive")),
            "target": t.get("target"),
            "status": norm(t.get("status", "open")),
            "assignee": t.get("assignee"),
            "labels": [norm(x) for x in (t.get("labels") or [])],
            "url": t.get("url"),
            "ext_provider": norm(t.get("ext_provider", "")) or None,
            "ext_id": norm(t.get("ext_id", "")) or None,
        }
        for t in (items or [])
    ], None


def read(ws: Workspace) -> tuple[list[dict], list[str]]:
    """Every task from every declared source. Returns (tasks, problems)."""
    tasks: list[dict] = []
    problems: list[str] = []
    repos = list(ws.repos)

    for source in ws.backlog_sources():
        kind = norm(source.get("type", ""))

        if kind in trackers.FETCH:
            try:
                found, notes = trackers.fetch(source, repos)
                tasks += [{**t, "_tracked": True} for t in found]
                # A short read is a problem, not a footnote. It reaches the same
                # `!` lines an unreachable tracker does, because the board it
                # produced is wrong in the same way: it is not the whole one.
                problems += [f"{kind}: {note}" for note in notes]
            except trackers.TrackerError as exc:
                problems.append(f"{kind}: {exc}")
            continue

        if source.get("command"):
            found, why = _tasks_from_command(source["command"], ws.root)
            if not found:
                # Say why. "produced no tasks" sent someone looking at their
                # roadmap when the adapter had exited non-zero.
                problems.append(f"{kind}: the adapter produced no tasks — {why or 'it returned an empty list'}")
            tasks += found
            continue

        path = ws.resolve_path(norm(source.get("file", "")))
        if not path.is_file():
            problems.append(f"{kind}: file not found — {source.get('file')}")
            continue

        # `type` is a label the team chose — "roadmap", "requirements" — so it
        # cannot also be what picks the parser. The extension can: a .yaml file
        # is read as tasks, anything else as a checklist. Naming the type
        # `tasks` or `board` still forces the yaml reader, for a tasks file
        # that does not end in .yaml.
        if kind in ("tasks", "board") or path.suffix.lower() in (".yaml", ".yml"):
            found = _tasks_from_yaml(path)
            shape = "a list of tasks under `tasks:`"
        else:
            found = _tasks_from_checklist(path, repos)
            shape = "checklist items written as `- [ ] ...`"
        if not found:
            # Silence here was how a declared backlog could pass `deck doctor`
            # — the file exists — and still leave `deck board list` empty with
            # nothing to explain it.
            problems.append(
                f"{kind}: no tasks in {source.get('file')} — this reader expects {shape}. "
                "Declare a `command:` for a format of your own."
            )
        tasks += found

    return _within_scope(ws, *_reconcile(tasks, problems))


def _within_scope(ws: Workspace, tasks: list[dict], problems: list[str]) -> tuple[list[dict], list[str]]:
    """Narrow a board to the active scope, or say why a task could not be placed.

    Two shapes, because a scope declares a board or it does not.

    A scope with its own board owns every task on it, and nothing is filtered —
    but a task there naming a repository the scope does not hold is reported,
    because that is either a task on the wrong board or a scope missing a
    repository, and both are worth a person's attention.

    A scope working from the shared board keeps the tasks its repositories
    cover. A task that names no repository is not kept: nothing places it in
    one scope rather than another, and silently handing it to whichever scope
    happens to be active is exactly the guess deck refuses elsewhere. It is
    named in the problems so it does not simply vanish.
    """
    if not ws.scope_name:
        return tasks, problems
    inside = set(ws.scope_repos())

    if ws.scope.get("backlog"):
        for task in tasks:
            outside = [r for r in task["repos"] if r not in inside]
            if outside:
                problems.append(
                    f"scope `{ws.scope_name}`: {task['id']} names {', '.join(outside)}, "
                    "which the scope does not hold — add them to the scope, or move the task"
                )
        return tasks, problems

    kept = [t for t in tasks if set(t["repos"]) & inside]
    unplaced = [t["id"] for t in tasks if not t["repos"]]
    if unplaced:
        one = len(unplaced) == 1
        problems.append(
            f"scope `{ws.scope_name}`: {', '.join(unplaced)} "
            f"{'names' if one else 'name'} no repository, so no scope claims "
            f"{'it' if one else 'them'} — name the repositories, or give the scope a `backlog:` of its own"
        )
    return kept, problems


# What each side of a link is the authority on. The tracker is live: it knows
# the status, who holds it, and where it is. The local file is curated: it knows
# which repositories the work touches and whether anything may run beside it —
# things no tracker has a field for. Merging beats picking, because picking
# throws away whichever half was not chosen.
FROM_TRACKER = ("status", "assignee", "url", "title")
FROM_LOCAL = ("repos", "exclusive", "target")


def _link(task: dict) -> tuple[str, str] | None:
    provider, ident = task.get("ext_provider"), task.get("ext_id")
    return (provider, ident) if provider and ident else None


def _merge(base: dict, other: dict) -> dict:
    """Fold two records of one piece of work together, whichever arrived first."""
    tracked, local = (base, other) if base.get("_tracked") else (other, base)
    merged = {**local}
    for key in FROM_TRACKER:
        value = tracked.get(key)
        if value not in (None, "", []):
            merged[key] = value
    for key in FROM_LOCAL:
        value = local.get(key)
        if value not in (None, "", []):
            merged[key] = value
    merged["labels"] = list(dict.fromkeys((local.get("labels") or []) + (tracked.get("labels") or [])))
    merged["ext_provider"] = tracked.get("ext_provider") or local.get("ext_provider")
    merged["ext_id"] = tracked.get("ext_id") or local.get("ext_id")
    merged["linked"] = True
    return merged


def _reconcile(tasks: list[dict], problems: list[str]) -> tuple[list[dict], list[str]]:
    by_id: dict[str, int] = {}
    by_link: dict[tuple[str, str], int] = {}
    unique: list[dict] = []

    for task in tasks:
        link = _link(task)
        if link is not None and link in by_link:
            at = by_link[link]
            if unique[at].get("_tracked") == task.get("_tracked"):
                problems.append(f"two tasks claim {link[0]}:{link[1]} — {unique[at]['id']} and {task['id']}")
                continue
            unique[at] = _merge(unique[at], task)
            continue
        if task["id"] in by_id:
            continue
        by_id[task["id"]] = len(unique)
        if link is not None:
            by_link[link] = len(unique)
        unique.append(task)

    for task in unique:
        task.pop("_tracked", None)
    return unique, problems


# ------------------------------------------------------------------ grouping
def closure(ws: Workspace, repos: list[str]) -> set[str]:
    """Everything a task reaches: its repositories plus what they impact.

    `couples:` is deliberately not read here. This feeds `edit_closure()` and
    `conflicts()`, which answer one question — may these two tasks run at the
    same time — and widening it makes tasks collide that had no reason to.
    `edit_closure` below records that mistake being made once already, on
    downstream repositories; a coupling is the same shape of mistake. Coupling
    says "revisit before you ship", not "edit in this task", and a revisit that
    finds nothing changes no file and can collide with nothing.

    So the coupling lives where the person asks about a change — `deck impact`,
    and `deck mount`, which places the rules for a repository they may edit —
    and not where the planner decides what may run beside what.
    """
    out: set[str] = set()
    for name in repos:
        if name not in ws.repos:
            continue
        out.add(name)
        out.update(ws.impacted(name))
    return out


def edit_closure(ws: Workspace, task: dict) -> set[str]:
    """What a task would actually edit, which is what can collide.

    Reaching a repository is not editing it. Nearly every change reaches the
    end-to-end suite, and if that counted as a collision no two tasks would ever
    run together — the first grouping run made exactly that mistake.

    So a downstream repository, one that keeps up but produces no artifact, only
    collides when both tasks name it directly.
    """
    named = set(task.get("repos") or [])
    reached = closure(ws, list(named))
    return {r for r in reached if r in named or not ws.repos.get(r, {}).get("downstream")}


def conflicts(ws: Workspace, a: dict, b: dict) -> str | None:
    """Why two tasks may not run at the same time, or None."""
    if a.get("exclusive") or b.get("exclusive"):
        return "one of them is marked exclusive"
    shared = edit_closure(ws, a) & edit_closure(ws, b)
    if shared:
        return f"both would edit {', '.join(sorted(shared))}"
    if a.get("target") and a.get("target") == b.get("target"):
        return f"both need target {a['target']}"
    if not a["repos"] or not b["repos"]:
        return "a task with no repositories could touch anything"
    return None


def group(ws: Workspace, tasks: list[dict], limit: int) -> list[dict]:
    """Order the tasks into groups that may run at the same time.

    Greedy and deliberately conservative: a task joins a group only when it
    conflicts with nothing already in it. Being wrong in the other direction
    means two agents editing the same chain, and a merge nobody can review.
    """
    groups: list[dict] = []
    for task in tasks:
        placed = False
        for bucket in groups:
            if len(bucket["tasks"]) >= max(1, limit):
                continue
            reasons = [r for r in (conflicts(ws, task, other) for other in bucket["tasks"]) if r]
            if not reasons:
                bucket["tasks"].append(task)
                placed = True
                break
            bucket.setdefault("rejected", []).append({"id": task["id"], "reason": reasons[0]})
        if not placed:
            groups.append({"index": len(groups) + 1, "tasks": [task]})
    for bucket in groups:
        bucket["parallel"] = len(bucket["tasks"]) > 1
    return groups


def probe_files(ws: Workspace, repos: list[str]) -> list[str]:
    """Paths that stand in for what a task would touch, for `applies_to` matching.

    A board task names repositories, not files, and the files do not exist until
    the work happens. So the probe is what the repository actually holds today:
    its own prefix, which answers a pattern like `pkg/**`, plus one sample per
    distinct extension, which answers `*.yaml`.

    Coarse in one direction only. A task that creates the first file of a new
    kind can still meet a question the probe did not predict — under-reporting
    here, which the run then hits, rather than over-reporting, which would make
    every task look blocked.
    """
    out: list[str] = []
    for name in repos:
        entry = ws.repos.get(name) or {}
        rel = norm(entry.get("path", ""))
        if not rel:
            continue
        out.append(f"{rel}/")
        code, listing = run(["git", "-C", str(ws.repo_path(name)), "ls-files"], timeout=10)
        if code != 0:
            continue
        seen: set[str] = set()
        for line in listing.splitlines()[:5000]:
            suffix = Path(line).suffix
            if suffix and suffix not in seen:
                seen.add(suffix)
                out.append(f"{rel}/sample{suffix}")
    return out


STAGES = ("plan", "implement", "verify", "deliver")


def pending_decisions(ws: Workspace, tg, tasks: list[dict], stage: str = "plan") -> list[dict]:
    """Decisions that would stop these tasks, aggregated across the whole board.

    An agent working inside a run has no channel to a person: it can be told to
    ask and still have nowhere to ask. So a decision left at `ask` is not a
    prompt in that world, it is a wall — which is what a first autonomous run
    hit, every task blocked before a single edit.

    The answer is not to let agents decide. It is to ask once, up front, in the
    session that has a person attached, and to know which tasks each answer
    unblocks.
    """
    # A task may own a decision. `decides: [unknown_locale]` says the choice IS
    # the work, so answering it up front does not make the run autonomous — it
    # empties the task. A board run demonstrated exactly that: an item titled
    # "decide and implement unknown-code behaviour" arrived with the decision
    # already made, and the reviewer's verdict was that the decision half never
    # happened.
    owned = {norm(tid) for task in tasks if task.get("status") != "done" for tid in (task.get("decides") or [])}

    found: dict[str, dict] = {}
    for task in tasks:
        if task.get("status") == "done":
            continue
        repos = sorted(edit_closure(ws, task))
        probes = probe_files(ws, repos)
        for one in STAGES if stage == "all" else [stage]:
            for question in tg.pending(one, probes):
                if question["id"] in owned:
                    continue  # its own task decides it, in context, with `deck ask`
                entry = found.setdefault(question["id"], {**question, "stage": one, "blocks": []})
                if task["id"] not in entry["blocks"]:
                    entry["blocks"].append(task["id"])
    return sorted(found.values(), key=lambda q: (-len(q["blocks"]), q["id"]))


def plan(ws: Workspace, tasks: list[dict], limit: int) -> dict:
    """The shape a workflow script consumes through its `args`."""
    open_tasks = [t for t in tasks if t["status"] != "done"]
    groups = group(ws, open_tasks, limit)
    return {
        "workspace": str(ws.root),
        "parallelism": limit,
        "groups": [
            {
                "index": bucket["index"],
                "parallel": bucket["parallel"],
                "tasks": [
                    {
                        "id": task["id"],
                        "title": task["title"],
                        "repos": task["repos"],
                        "reaches": sorted(closure(ws, task["repos"])),
                        "order": ws.order(sorted(closure(ws, task["repos"]))),
                        "target": task.get("target"),
                        "exclusive": task.get("exclusive", False),
                    }
                    for task in bucket["tasks"]
                ],
            }
            for bucket in groups
        ],
        "skipped": [t["id"] for t in tasks if t["status"] == "done"],
        "cautions": cautions(ws, groups),
    }


def owned_decisions(tasks: list[dict]) -> list[dict]:
    """Decisions a task exists to make, which nobody should pre-answer."""
    return [
        {"id": norm(tid), "task": task["id"]}
        for task in tasks
        if task.get("status") != "done"
        for tid in (task.get("decides") or [])
    ]


def plan_with_decisions(ws: Workspace, tg, tasks: list[dict], limit: int) -> dict:
    """The plan, plus what has to be answered before any of it can run."""
    payload = plan(ws, tasks, limit)
    # Every stage, not just `plan`. A run that clears the first rung and then
    # meets a new wall at `verify` has not been made autonomous, it has been
    # made to fail later — which is what the second run did, with `deploy_mode`
    # and `doc_sync` surfacing after the code was already written.
    payload["pending_decisions"] = pending_decisions(ws, tg, tasks, "all")
    payload["owned_decisions"] = owned_decisions(tasks)
    return payload


def cautions(ws: Workspace, groups: list[dict]) -> list[str]:
    """Pairs the grouping allows that a person should look at anyway.

    `edit_closure` lets a downstream repository pass unless both tasks name it,
    which is right — nearly every change reaches the end-to-end suite, and
    counting that as a collision would mean nothing ever runs in parallel.

    But "reaches it" and "has to edit it" are not the same thing, and only the
    team knows which one applies. When one task in a group names a downstream
    repository that another merely reaches, the grouping is defensible and the
    pair is still worth a second look — so it is said, once, rather than left
    to be discovered in a merge.
    """
    out: list[str] = []
    for bucket in groups:
        members = bucket["tasks"]
        for i, a in enumerate(members):
            for b in members[i + 1 :]:
                for first, second in ((a, b), (b, a)):
                    named = set(second.get("repos") or [])
                    overlap = sorted(
                        r
                        for r in closure(ws, list(first.get("repos") or []))
                        if r in named and ws.repos.get(r, {}).get("downstream")
                    )
                    if overlap:
                        out.append(
                            f"{first['id']} reaches {', '.join(overlap)}, which {second['id']} edits. "
                            f"If {first['id']} has to update it too, name it in its `repos`."
                        )
    return out


def source_for(ws: Workspace, task_id: str) -> tuple[dict | None, dict | None]:
    """Which declared source holds this task, and the task itself."""
    tasks, _ = read(ws)
    task = next((t for t in tasks if t["id"] == task_id), None)
    if not task:
        return None, None
    for source in ws.backlog_sources():
        kind = norm(source.get("type", ""))
        if kind in trackers.FETCH:
            try:
                # The notes are dropped here on purpose: this asks which source
                # holds one task, and a source that answered short still holds
                # the task if the task is in what it answered.
                found, _ = trackers.fetch(source, list(ws.repos))
                if any(t["id"] == task_id for t in found):
                    return source, task
            except trackers.TrackerError:
                continue
        elif kind in ("tasks", "board"):
            # resolve_path, not root / rel: `read` above resolves it, so a board
            # declared at an absolute path or under `~` was listed and closed but
            # never claimed — source_for looked for it under the root and found
            # nothing, and the claim reported a task it had just printed as
            # living in no source it could write to.
            path = ws.resolve_path(norm(source.get("file", "")))
            if any(t["id"] == task_id for t in _tasks_from_yaml(path)):
                return source, task
    return None, task


def add_local(ws: Workspace, path: Path, task: dict) -> None:
    """Append a task to a file-backed board, creating it if needed."""
    data = load_yaml(path)
    data.setdefault("version", 1)
    data.setdefault("tasks", []).append(task)
    dump_yaml(path, data)


def update_local(ws: Workspace, path: Path, task_id: str, changes: dict) -> bool:
    data = load_yaml(path)
    for item in data.get("tasks") or []:
        if norm(item.get("id")) == task_id:
            item.update(changes)
            dump_yaml(path, data)
            return True
    return False
