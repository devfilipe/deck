"""The merge-readiness bundle: what a reviewer reads instead of the diff.

A reviewer looking at a multi-repository change has to answer five questions,
and a diff answers one of them. Is this the whole change, or did it stop halfway
along the impact chain? What was actually verified, and to which rung? Which
decisions were in force while it was written, and where did each come from? Is
the working tree clean, or is there still something deck placed in it? And can
every one of those claims be traced back to a file?

Each answer already exists on disk — the gate record, the mount manifest, the
toggle layers, the consultations, git itself. Nobody reads five places, so the
change gets reviewed on the diff alone and the chain is checked by whoever the
break reaches first.

Assembling that is all this module does. **It writes no conclusion of its own.**
Every line is derived from a file this module names, which is the property that
makes the bundle worth reading: a reviewer who distrusts a claim can go and see
the same file. Nothing here narrates, estimates or infers intent.

Two consequences of deck's usual line, worth stating because both were choices:

*Not called `review`.* Claude Code ships code review, and deck must not build a
second one. This bundle does not read the code and has no opinion about it — it
says what was verified, what was decided, and what was left, so a reviewer (or
that reviewer) starts from facts rather than from a diff.

*Not a rung of the ladder.* `ready()` returns an exit-code-shaped verdict, so a
pack that wants merge-readiness enforced can declare a gate that runs it. Wiring
it into every ladder is a pack's decision about its own posture, not the
engine's about everyone's.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from . import board as board_lib
from . import consult
from . import gates as gate_lib
from . import metrics as metric_lib
from .config import STATE_DIR, run
from .mount import manifest_path, span_path
from .toggles import CHOSEN_AT, Toggles, record_hint
from .workspace import Workspace

# A byte no commit subject contains, so the header of each commit is
# unambiguous even when a subject holds tabs or begins with a digit.
MARK = "\x01"
# Per repository. A bundle that quietly stops at fifty commits reports a change
# set smaller than the change, which is the one thing it must never do — so when
# the cap bites it is said, not swallowed.
COMMIT_LIMIT = 50


def bundles_dir(root: Path) -> Path:
    return root / STATE_DIR / "bundles"


# ------------------------------------------------------------------ the change
def _log(path: Path, selector: list[str]) -> list[dict]:
    """Commits and their line counts in one call, or nothing if git cannot answer.

    `--numstat` alongside a marked `--format` gives both halves at once. Two
    calls per repository — one for the subjects, one for the stat — could
    disagree with each other, and a bundle whose file count does not match its
    commit list is worse than one that says it could not tell.
    """
    code, out = run(
        [
            "git",
            "-C",
            str(path),
            "log",
            f"--format={MARK}%H%x09%h%x09%an%x09%s",
            "--numstat",
            "-n",
            str(COMMIT_LIMIT),
            *selector,
        ],
        timeout=20,
    )
    if code != 0:
        return []
    commits: list[dict] = []
    for line in out.splitlines():
        if line.startswith(MARK):
            parts = (line[1:].split("\t") + ["", "", "", ""])[:4]
            commits.append(
                {
                    "sha": parts[0],
                    "short": parts[1],
                    "author": parts[2],
                    "subject": parts[3],
                    "files": [],
                    "added": 0,
                    "removed": 0,
                }
            )
            continue
        cells = line.split("\t")
        if len(cells) == 3 and commits:
            added, removed, name = cells
            commits[-1]["files"].append(name)
            commits[-1]["added"] += int(added) if added.isdigit() else 0
            commits[-1]["removed"] += int(removed) if removed.isdigit() else 0
    return commits


def started_at(root: Path, task: str) -> str | None:
    """When the task's first mount happened, which is the only start deck records."""
    path = span_path(root, task)
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("started")
    except (OSError, ValueError, AttributeError):
        return None


def attribute(ws: Workspace, repos: list[str], task: str, since: str | None) -> tuple[dict, dict]:
    """Which commits belong to this task, and on what basis — never silently.

    Two bases, and the difference matters enough to print. A commit whose
    message names the task is attributed *exactly*: it says so itself. A time
    window says only that a commit happened while the task was mounted, which
    also catches anything else committed in that repository meanwhile.

    Whether the exact basis is available is not this module's decision — the
    catalog already holds it. `requirement_link: required` means "the plan and
    the commit message must cite the item", and that is precisely what makes
    attribution exact. So the bundle reads the toggle rather than inventing a
    convention: under `required`, a change set that could only be assembled from
    a window is a broken rule; under `off`, it is the expected result and the
    bundle says so instead of implying the reviewer got the whole story.

    When neither basis produces anything the answer is `None` — not an empty
    change set. "Nobody committed anything" and "nothing tells me which commits
    were yours" look identical in a list and are opposite in a review.
    """
    # Anchored, not a substring. `-F --grep=DECK-1` also matches DECK-10 and
    # DECK-12, so a bundle for the first would claim the others' commits — and
    # attributing someone else's change to your task is worse than attributing
    # none, because it reads as evidence.
    pattern = f"(^|[^A-Za-z0-9_-]){re.escape(task)}([^A-Za-z0-9_-]|$)"
    named = {name: _log(ws.repo_path(name), ["-E", f"--grep={pattern}"]) for name in repos}
    if any(named.values()):
        return named, _basis(True, f"commits whose message names {task}", named)
    if since:
        windowed = {name: _log(ws.repo_path(name), [f"--since={since}"]) for name in repos}
        if any(windowed.values()):
            return windowed, _basis(
                False,
                f"commits made since {since}, when the task was first mounted — the window, not the task",
                windowed,
            )
    return {name: [] for name in repos}, {"exact": False, "text": None}


def _basis(exact: bool, text: str, found: dict[str, list]) -> dict:
    """How the commits were attributed, and whether the list ran into the cap.

    Shared by both branches on purpose. The first version put the truncation
    note only where the exact match is built, so a bundle falling back to the
    time window reported a change set capped at fifty with nothing saying so —
    the fix was half a fix, and the check that was supposed to guard it only
    asserted the words existed somewhere in the file.
    """
    truncated = sorted(name for name, commits in found.items() if len(commits) >= COMMIT_LIMIT)
    if truncated:
        text += f" (capped at {COMMIT_LIMIT} in {', '.join(truncated)} — there may be more)"
    return {"exact": exact, "text": text, "truncated": truncated}


def _worktree(path: Path) -> dict:
    """Branch, unpushed commits, and what is not committed at all."""
    code, branch = run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"], timeout=10)
    if code != 0:
        return {"git": False}
    code, porcelain = run(["git", "-C", str(path), "status", "--porcelain"], timeout=15)
    dirty = [line for line in porcelain.splitlines() if line.strip()] if code == 0 else []
    code, ahead = run(["git", "-C", str(path), "rev-list", "--count", "@{u}..HEAD"], timeout=10)
    return {
        "git": True,
        "branch": branch,
        "dirty": len(dirty),
        "dirty_paths": [line[3:] for line in dirty[:10]],
        "unpushed": int(ahead) if code == 0 and ahead.isdigit() else None,
    }


# ------------------------------------------------------------- what was decided
SETTLED = ("catalog default", "profile ")


def _decision(tid: str, origin: str, value: str, reason: str | None) -> dict:
    """One decision as the bundle carries it: what, to what, from where, and why.

    `reason` is the chooser's own sentence, verbatim, and is null when nobody
    wrote one — never the catalog's `rationale`, which says why the toggle
    exists at all and would make a default nobody revisited read as considered.
    `why_missing` carries the other half, because a value standing alone on the
    one page written for somebody else reads as justified, and saying which
    kind of nothing it is costs a sentence.

    Two fields rather than one: a consumer that wants only what a person wrote
    reads `reason` and gets null, without having to recognise a stand-in
    sentence as the absence of one.
    """
    return {
        "id": tid,
        "value": value,
        "source": origin,
        "reason": reason,
        "why_missing": None if reason else _why_missing(tid, value, origin),
    }


def _why_missing(tid: str, value: str, origin: str) -> str:
    """Which of the two kinds of nothing this is, and what to do about the one that has a fix.

    A layer deck writes to could have carried a reason and does not, so the
    line names the command that records one. Every other origin never could —
    an environment variable belongs to one command, a profile and a catalog
    default were not chosen here at all — and telling a reviewer to go and
    record a reason there is an instruction nobody can follow.
    """
    if origin.startswith(CHOSEN_AT):
        return (
            "not recorded — nothing here says whether it was decided or never revisited; "
            f"record it with: {record_hint(tid, value, origin)}"
        )
    return f"no reason is recorded — {origin} is not a layer a reason can be written at"


def decisions(tg: Toggles, task: dict) -> tuple[list[dict], list[dict]]:
    """(recorded, owned) — decisions someone took, and the ones this task existed to take.

    "Recorded" means the winning layer is not the catalog default and not a
    profile: somebody chose it for this workspace, this scope, this repository
    or this task. A list of every toggle would be the catalog again, and the
    catalog is not what a reviewer is missing.
    """
    recorded = []
    for tid in sorted(tg.defs):
        layers = tg.layers(tid)
        if not layers:
            continue
        origin, value, reason = layers[0]
        if any(origin.startswith(prefix) for prefix in SETTLED):
            continue
        recorded.append(_decision(tid, origin, value, reason))

    owned = []
    for tid in task.get("decides") or []:
        layers = tg.layers(tid)
        if not layers:
            # No value and no default: the source line is the whole story, and a
            # second line about a missing reason would report the smaller half
            # of it as if it were a separate problem.
            owned.append(
                {
                    "id": tid,
                    "value": "",
                    "source": "nothing — it has no value and no default",
                    "reason": None,
                    "why_missing": None,
                }
            )
            continue
        owned.append(_decision(tid, *layers[0]))
    return recorded, owned


# ------------------------------------------------------------- what was measured
def measured(ws: Workspace, tg: Toggles, record: dict | None) -> dict:
    """The numbers this run took, each against the series it joined.

    The one thing here a threshold cannot report: a metric inside its limit on
    every run and worse on every run. `deck gate run` prints the sample; only
    the series says which way it has been going, so the bundle carries both.
    """
    directory, mode, refusal = metric_lib.store(ws, tg)
    out = {
        "store": mode,
        "where": str(directory) if directory else None,
        "refusal": refusal,
        "taken": [],
        "worse": [],
    }
    for gate in (record or {}).get("gates", []):
        for sample in gate.get("measured") or []:
            movement = metric_lib.trend(metric_lib.series(ws, tg, sample["key"], sample.get("repo")))
            entry = {
                "key": sample["key"],
                "repo": sample.get("repo"),
                "title": sample.get("title", sample["key"]),
                "value": sample.get("value"),
                "unit": sample.get("unit", ""),
                "reason": sample.get("reason", ""),
                "gate_status": gate.get("status"),
                "trend": movement,
            }
            out["taken"].append(entry)
            if movement.get("judgement") == "worse":
                out["worse"].append(entry)
    return out


# -------------------------------------------------------------------- assembly
def assemble(ws: Workspace, task_id: str, since: str | None = None) -> dict:
    """Everything the bundle asserts, with the file each claim came from."""
    tasks, problems = board_lib.read(ws)
    found = next((t for t in tasks if t["id"] == task_id), None)
    # A task id no board holds is legitimate — `deck gate run --task self` is in
    # the documents — so this is a fact about the bundle's reach, not an error.
    # What it costs is real, though: without a board entry there is nothing that
    # says which repositories the work names, so there is no chain to check the
    # change against, and saying so beats printing an empty one.
    task = found or {"id": task_id, "title": "", "repos": [], "status": "unknown"}

    named = list(task.get("repos") or [])
    reached = ws.order(sorted(board_lib.closure(ws, named))) if named else []
    window = since or started_at(ws.root, task_id)
    commits, basis = attribute(ws, reached, task_id, window)

    tg = Toggles(root=ws.root)
    link = tg.resolve("requirement_link")[0] if "requirement_link" in tg.defs else None

    touched = [name for name in reached if commits[name]]
    change = {
        "named": named,
        "reached": reached,
        "touched": touched,
        "untouched": [name for name in reached if name not in touched],
        "basis": basis["text"],
        "exact": basis["exact"],
        "requirement_link": link,
        "repos": {
            name: {
                "commits": commits[name],
                "files": sorted({f for c in commits[name] for f in c["files"]}),
                "added": sum(c["added"] for c in commits[name]),
                "removed": sum(c["removed"] for c in commits[name]),
                **_worktree(ws.repo_path(name)),
            }
            for name in reached
        },
    }

    evidence = gate_lib.gates_dir(ws.root) / f"{task_id}.json"
    record = None
    if evidence.is_file():
        try:
            record = json.loads(evidence.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            record = None

    rungs = gate_lib.ladder(tg)
    configured = (record or {}).get("level")
    reached_level, stopped_at = gate_lib.rung_completed(rungs, configured, (record or {}).get("gates", []))
    no_gates = gate_lib.rungs_without_gates(rungs, (record or {}).get("gates", [])) if record else []
    # The rungs the run set out to climb and found nothing at. Separate from
    # `no_gates`, which spans the whole ladder: a rung above the configured
    # level was never aimed at, so it is a gap in the ladder rather than a
    # claim this run made about itself.
    climbed = rungs[: rungs.index(configured) + 1] if configured in rungs else []
    skipped_rungs = [r for r in climbed if r in no_gates]
    # A rung that held gates and ran none of them. Not folded into
    # `skipped_rungs`: that list is rungs nothing was declared at, and a rung
    # here was declared, weighed against these repositories and this toggle
    # state, and found not to apply. Same outcome — nothing verified — and two
    # different facts, so the reviewer gets both rather than one standing in for
    # the other.
    inapplicable = (
        [e for e in gate_lib.rungs_all_inapplicable(rungs, record.get("gates", [])) if e["rung"] in climbed]
        if record
        else []
    )
    verification = {
        "evidence": str(evidence) if record else None,
        "level": reached_level,
        "configured_level": configured,
        "stopped_at": stopped_at,
        "no_gates": no_gates,
        "skipped_rungs": skipped_rungs,
        "inapplicable_rungs": inapplicable,
        "scope": (record or {}).get("scope"),
        "covered_repos": (record or {}).get("covered_repos"),
        "scope_repos": (record or {}).get("scope_repos"),
        "registry_repos": (record or {}).get("registry_repos"),
        "ladder": rungs,
        # What genuinely never ran. A rung the ladder stopped ON did run, and
        # failed there — listing it as "did not run" understates it twice.
        "not_reached": (
            rungs[rungs.index(stopped_at) + 1 :]
            if stopped_at in rungs
            else rungs[rungs.index(reached_level) + 1 :]
            if reached_level in rungs
            else rungs
        ),
        "finished": (record or {}).get("finished"),
        # `pack` travels with each gate because a ladder is not a fixed list any
        # more: a pack bound to an initiative declares gates that appear and
        # disappear with `--scope`, so "which gate ran" is only half an answer
        # without "and who declared it". The record has held it all along; the
        # bundle used to drop it on the floor.
        "gates": [
            {
                "id": g["id"],
                "title": g.get("title", g["id"]),
                "status": g["status"],
                "reason": g.get("reason", ""),
                "pack": g.get("pack"),
            }
            for g in (record or {}).get("gates", [])
        ],
        "summary": gate_lib.summarise((record or {}).get("gates", [])) if record else None,
        "failed": [
            g["id"] for g in (record or {}).get("gates", []) if g.get("status") in (gate_lib.FAILED, gate_lib.BLOCKED)
        ],
    }

    measurements = measured(ws, tg, record)

    recorded, owned = decisions(tg, task)
    asked = [e for e in consult.load_all(ws.root, ws.all_packs()) if e.get("task") == task_id]

    manifest = manifest_path(ws.root, task_id)
    placed = 0
    if manifest.is_file():
        try:
            placed = len(json.loads(manifest.read_text(encoding="utf-8")).get("entries", []))
        except (OSError, ValueError):
            placed = 0

    payload = {
        "task": {
            "id": task_id,
            "title": task.get("title", ""),
            "status": task.get("status", "unknown"),
            "on_board": found is not None,
            "labels": task.get("labels") or [],
            "assignee": task.get("assignee"),
            "url": task.get("url"),
            "as_a": task.get("as_a"),
            "so_that": task.get("so_that"),
            "acceptance": task.get("acceptance") or [],
            "accepted": task.get("accepted") or [],
        },
        "change": change,
        "verification": verification,
        "measurements": measurements,
        "decisions": {"recorded": recorded, "owned": owned},
        "questions": [
            {"id": e["id"], "status": e["status"], "question": e["question"], "answer": e.get("answer")} for e in asked
        ],
        "hygiene": {
            "mounted": placed,
            "manifest": str(manifest) if placed else None,
            "dirty": {n: change["repos"][n]["dirty_paths"] for n in reached if change["repos"][n].get("dirty")},
            "unpushed": {n: change["repos"][n]["unpushed"] for n in reached if change["repos"][n].get("unpushed")},
        },
        "sources": _sources(ws, task_id, evidence if record else None, manifest if placed else None, asked),
        "problems": problems,
    }
    payload["verdict"] = verdict(payload)
    return payload


def _sources(
    ws: Workspace, task_id: str, evidence: Path | None, manifest: Path | None, asked: list[dict]
) -> list[dict]:
    """Where each claim can be checked. A claim with no source is not in the bundle."""
    out = [{"what": "the change set", "where": "git log, in each repository listed above"}]
    out.append({"what": "verification", "where": str(evidence) if evidence else "nothing recorded under this task"})
    out.append({"what": "gate output", "where": str(gate_lib.gates_dir(ws.root) / "logs" / task_id)})
    out.append({"what": "decisions", "where": "deck toggle explain <id> — every layer, strongest first"})
    if asked:
        out.append({"what": "questions", "where": str(consult.store(ws.root))})
    if manifest:
        out.append({"what": "what is still placed", "where": str(manifest)})
    out.append({"what": "measurements", "where": "deck metrics show <id> — every sample, with the run it came from"})
    out.append({"what": "what it cost", "where": f"deck cost --task {task_id}"})
    return out


def verdict(payload: dict) -> dict:
    """Ready, or not, and for each `not` the command that resolves it.

    Blocking and worth-reading are kept apart deliberately. An unanswered
    consultation does not block: deck's whole position on those is that nothing
    waits on them. A rung the ladder did not reach does not block either —
    lowering `gate_level` is a decision someone is allowed to take, as long as
    the bundle says which rung was actually reached. Both are qualifiers, and a
    reviewer reads them before merging.
    """
    blockers, qualifiers = [], []
    task_id = payload["task"]["id"]
    v, c, h = payload["verification"], payload["change"], payload["hygiene"]

    if not v["evidence"]:
        blockers.append({"why": "nothing has been verified under this name", "fix": f"deck gate run --task {task_id}"})
    elif v["failed"]:
        blockers.append(
            {"why": f"gates did not pass: {', '.join(v['failed'])}", "fix": f"deck gate report --task {task_id}"}
        )
    if not c["basis"]:
        blockers.append(
            {
                "why": "no commit is attributable to this task, so the change set is unknown — not empty",
                "fix": f"commit naming {task_id} in the message, or pass --since <timestamp>",
            }
        )
    elif not c["exact"] and c["requirement_link"] == "required":
        # Not the bundle's rule. `requirement_link: required` says the commit
        # message must cite the item; a change set that could only be built from
        # a time window is that rule already broken, found here rather than by
        # whoever needs the trace later.
        blockers.append(
            {
                "why": f"requirement_link is `required`, and no commit cites {task_id} — "
                "the change set below is the mount window, not the task",
                "fix": f"amend the commit messages to cite {task_id}",
            }
        )
    if h["dirty"]:
        blockers.append(
            {
                "why": f"uncommitted changes in {', '.join(sorted(h['dirty']))}",
                "fix": "commit them, or say in the review why they are not part of this change",
            }
        )
    if h["mounted"]:
        blockers.append(
            {
                "why": f"{h['mounted']} artifact(s) deck placed are still in the working directories",
                "fix": f"deck unmount --task {task_id}",
            }
        )

    # Only when there *is* a record. With none, the blocker above already says
    # so, and a second line about which rungs were missed reads as a different
    # and smaller problem than "nothing ran".
    if not payload["task"]["on_board"]:
        qualifiers.append(
            f"no declared board holds {task_id}, so nothing says which repositories it names — "
            "the bundle covers what the ladder and git recorded, and no chain"
        )
    # The ladder proves the code holds together. Acceptance criteria are the
    # other half — that it is the thing somebody asked for — and no gate reaches
    # them. A bundle silent about them reports half a delivery as a whole one.
    criteria = (payload.get("task") or {}).get("acceptance") or []
    accepted = set((payload.get("task") or {}).get("accepted") or [])
    if criteria:
        unmet = [c for c in criteria if c not in accepted]
        if unmet:
            blockers.append(
                {
                    "why": f"{len(unmet)} of {len(criteria)} acceptance criteria are not accepted — "
                    "the ladder does not decide whether this is what was asked for",
                    "fix": f'deck board done {task_id} --accept "<the criterion, verbatim>"',
                }
            )
    elif payload.get("task", {}).get("status") != "unknown":
        qualifiers.append("the task declares no acceptance criteria, so nothing states what it was for")

    weighed = [e["rung"] for e in v.get("inapplicable_rungs") or []]
    if v["evidence"] and (v["not_reached"] or v["skipped_rungs"] or weighed):
        got = f"completed `{v['level']}`" if v["level"] else "completed no rung"
        # A rung named as skipped, or as weighed and inapplicable, is not also
        # listed as never run: it is one fact about one rung, and saying it
        # twice reads as two problems.
        never = [r for r in v["not_reached"] if r not in v["skipped_rungs"] and r not in weighed]
        if v["stopped_at"]:
            parts = [
                f"the ladder was set to `{v['configured_level']}` and {got}",
                f"it stopped at `{v['stopped_at']}`",
            ]
        elif v["skipped_rungs"] or weighed:
            parts = [f"the ladder was set to `{v['configured_level']}` and {got}"]
        else:
            # Every rung it climbed had gates and passed them. This is the one
            # case where the configured level is the level reached, and it is
            # still said in the shortest way there is.
            parts = [f"the ladder reached `{v['level']}`"]
        if v["skipped_rungs"]:
            one = len(v["skipped_rungs"]) == 1
            parts.append(
                f"{', '.join('`' + r + '`' for r in v['skipped_rungs'])} "
                f"{'holds' if one else 'hold'} no gate in the record, "
                f"so {'it was' if one else 'they were'} skipped rather than verified"
            )
        if weighed:
            one = len(weighed) == 1
            # The reason each gate gave, verbatim from the record. Naming the
            # rung alone would read as a failure; the sentence beside it is what
            # makes it coverage — an excluded repository, a toggle that did not
            # match — and it is the whole answer to "why did nothing run there".
            why = "; ".join(
                f"{e['rung']}: " + ", ".join(f"{g['id']} — {g['reason']}" for g in e["gates"])
                for e in v["inapplicable_rungs"]
            )
            parts.append(
                f"{', '.join('`' + r + '`' for r in weighed)} "
                f"{'holds gates' if one else 'hold gates'} that were all weighed and none applied "
                f"({why}), so {'it was' if one else 'they were'} considered and not verified"
            )
        if never:
            parts.append(f"{', '.join(never)} did not run")
        qualifiers.append("; ".join(parts))
    # Reaching the top rung inside a subset is not the same claim as reaching it
    # over the registry, and a merge-readiness page that does not say which is
    # the one place the difference must not be lost.
    # `covered_repos` is what the run actually gated; the scope's own list is a
    # fallback for evidence written before that field existed. Reading only the
    # scope missed the commoner case entirely — a run narrowed by `--repos`,
    # with no scope in sight, produced no caveat at all.
    covered = v.get("covered_repos") or v.get("scope_repos")
    whole = v.get("registry_repos")
    if covered is not None and whole is not None:
        outside = [r for r in whole if r not in covered]
        if outside:
            where = f"inside scope `{v['scope']}` " if v.get("scope") else ""
            qualifiers.append(
                f"the ladder ran {where}over {len(covered)} of {len(whole)} repositories; "
                f"{', '.join(outside)} were not covered"
            )
    if c["basis"] and not c["exact"] and c["requirement_link"] != "required":
        qualifiers.append(
            f"the change set is the mount window, not the task: no commit cites {task_id}, and "
            f"`requirement_link` is `{c['requirement_link'] or 'not in the catalog'}`, so nothing requires one"
        )
    if c["untouched"]:
        one = len(c["untouched"]) == 1
        qualifiers.append(
            f"{', '.join(c['untouched'])} {'is' if one else 'are'} reached by this change and "
            f"{'has' if one else 'have'} no commit under it — deliberate, or the chain stopped early"
        )
    for entry in payload.get("measurements", {}).get("worse", []):
        # A qualifier, never a blocker. Nothing here failed: that is the whole
        # finding. A trend that blocked a merge would be a threshold again, and
        # a threshold nobody chose is the worst kind.
        where = f" in {entry['repo']}" if entry["repo"] else ""
        qualifiers.append(f"{entry['key']}{where} is passing and getting worse: {entry['trend']['text']}")

    open_questions = [q for q in payload["questions"] if q["status"] == consult.OPEN]
    if open_questions:
        qualifiers.append(f"{len(open_questions)} question(s) were raised and are still unanswered")
    if payload["task"]["status"] not in ("done",):
        # `unknown` is what assemble() synthesises when no board holds the task,
        # and the qualifier above already said so. Repeating it as a board state
        # invents a board.
        if payload["task"]["status"] != "unknown":
            qualifiers.append(f"the board still has {task_id} as `{payload['task']['status']}`")
    unpushed = h["unpushed"]
    if unpushed:
        qualifiers.append(", ".join(f"{n} has {count} commit(s) not pushed" for n, count in sorted(unpushed.items())))

    return {"ready": not blockers, "blockers": blockers, "qualifiers": qualifiers}
