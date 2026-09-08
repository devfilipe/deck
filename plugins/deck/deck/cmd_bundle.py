"""`deck bundle` — assemble the merge-readiness bundle, and render it.

Two renderings of one payload. The terminal one is for the person who just
finished the work and wants to know whether it is done. The markdown one is for
the pull request, where the reviewer is somebody who was not there.

Neither adds anything the payload does not hold. When they diverge, the JSON is
the artifact: `--json` is what a workflow reads.
"""

from __future__ import annotations

import json

from . import bundle as bundle_lib
from . import consult
from . import metrics as metric_lib
from .config import session_id
from .workspace import Workspace

MARK = {"passed": "ok  ", "failed": "FAIL", "skipped": "--  ", "blocked": "??  "}


def _why(item: dict) -> str:
    """The sentence under a decision: the chooser's own, or why there is not one.

    One function for both renderings and for neither to decide. The reason a
    reviewer needs and the admission that nobody wrote one occupy the same
    place on the page, because a decision that quietly has no line there is
    exactly the one that reads as justified.
    """
    return item.get("reason") or item.get("why_missing") or ""


def _cell(text: str) -> str:
    """Text that has to survive a markdown table cell.

    A reason is a sentence somebody typed after `--why`, or hand-wrote into the
    choices file. An unescaped pipe in it silently splits the row and shifts
    every column after it, so the reviewer reads a table that is wrong rather
    than one that is ugly.
    """
    return " ".join(str(text).split()).replace("|", "\\|")


def _headline(payload: dict) -> str:
    verdict = payload["verdict"]
    if verdict["ready"]:
        return "READY — everything this bundle checks is in place"
    one = len(verdict["blockers"]) == 1
    return f"NOT READY — {len(verdict['blockers'])} thing{'' if one else 's'} in the way"


def _text(payload: dict) -> list[str]:
    task, change, ver = payload["task"], payload["change"], payload["verification"]
    out = [f"{task['id']}  {task['title']}", "", f"  {_headline(payload)}", ""]

    for item in payload["verdict"]["blockers"]:
        out += [f"  !! {item['why']}", f"       {item['fix']}"]
    if payload["verdict"]["blockers"]:
        out.append("")
    for line in payload["verdict"]["qualifiers"]:
        out.append(f"  .. {line}")
    if payload["verdict"]["qualifiers"]:
        out.append("")

    out.append("what changed")
    out.append(f"  basis    {change['basis'] or 'NONE — nothing attributes a commit to this task'}")
    if not change["reached"]:
        out.append(
            "  (no board holds this task, so nothing names its repositories)"
            if not task["on_board"]
            else "  (the task names no repository, so there is no chain to follow)"
        )
    for name in change["reached"]:
        entry = change["repos"][name]
        if not entry["commits"]:
            out.append(f"  {name:<20} reached, no commit under this task")
            continue
        out.append(
            f"  {name:<20} {len(entry['commits'])} commit(s) · {len(entry['files'])} file(s) "
            f"· +{entry['added']} -{entry['removed']}"
        )
        for commit in entry["commits"]:
            out.append(f"       {commit['short']}  {commit['subject'][:64]}")
    out.append("")

    out.append("what was verified")
    if not ver["evidence"]:
        out.append("  nothing — no gate record exists under this name")
    else:
        # `level` is the rung completed, which is None when the ladder stopped on
        # the first one. Printing None reads like a missing value rather than a
        # result, so say what happened.
        rung = ver["level"] or (f"none, stopped at {ver['stopped_at']}" if ver.get("stopped_at") else "none")
        out.append(f"  level    {rung}   ladder {' -> '.join(ver['ladder'])}   {ver['finished']}")
        # Unconditional, whenever the record names one. It used to appear only
        # inside the coverage qualifier, which is written only when a repository
        # was left out — so a scope holding the whole registry, or a run whose
        # `--repos` happened to cover it, produced a bundle that said nothing
        # about the initiative it climbed inside. A pack bound to a scope
        # declares gates that come and go with `--scope`, and a ladder whose
        # rungs depend on a flag is not readable without the flag beside it.
        if ver.get("scope"):
            out.append(f"  scope    {ver['scope']}   the ladder climbed inside this initiative, not the whole registry")
        # The inventory first, then what it cost this run. A rung nothing is
        # declared at is a gap in the ladder whether or not this run aimed at
        # it; a rung the run climbed to and found empty is a claim it must not
        # make, and that one is named in the reviewer's word: skipped.
        if ver.get("no_gates"):
            out.append(f"  no gate  {', '.join(ver['no_gates'])}   the record holds none at these rungs")
        if ver.get("skipped_rungs"):
            out.append(
                f"  skipped  {', '.join(ver['skipped_rungs'])}   climbed to under "
                f"gate_level `{ver['configured_level']}`, and nothing was verified there"
            )
        # A third line, not a third name for the second. `skipped` is a rung
        # nobody declared a gate at; `weighed` is a rung somebody did, where
        # every one of them was measured against this change and none applied.
        # Nothing ran at either, and only one of them is anybody's to fix.
        for entry in ver.get("inapplicable_rungs") or []:
            why = "; ".join(f"{g['id']}: {g['reason']}" for g in entry["gates"])
            count = len(entry["gates"])
            out.append(
                f"  weighed  {entry['rung']}   {count} gate(s) declared here, none applied to this change — {why}"
            )
        for gate in ver["gates"]:
            mark = MARK.get(gate["status"], "?   ")
            out.append(f"  {mark} {gate['id']:<14} {gate['status']:<9} {gate['reason']}")
        out.append(f"  {ver['summary']}")
    out.append("")

    metrics = payload.get("measurements") or {}
    if metrics.get("taken"):
        out.append("what was measured")
        if metrics.get("refusal"):
            out.append(f"  !! {metrics['refusal']}")
        for entry in metrics["taken"]:
            where = f" ({entry['repo']})" if entry["repo"] else ""
            if entry["value"] is None:
                out.append(f"  {entry['key'] + where:<26} not measured: {entry['reason']}")
                continue
            unit = (" " + entry["unit"]).rstrip()
            out.append(f"  {entry['key'] + where:<26} {metric_lib.fmt(entry['value'])}{unit}")
            out.append(f"       {entry['trend']['text']}")
        out.append("")

    decisions = payload["decisions"]
    out.append("what was decided")
    if decisions["owned"]:
        for item in decisions["owned"]:
            out.append(f"  * {item['id']:<22} {item['value']:<14} (this task's to decide) from {item['source']}")
            why = _why(item)
            if why:
                out.append(f"       why  {why}")
    if not decisions["recorded"]:
        out.append("  nothing recorded — every toggle in force is a catalog default or a profile value")
    for item in decisions["recorded"]:
        out.append(f"    {item['id']:<22} {item['value']:<14} from {item['source']}")
        why = _why(item)
        if why:
            out.append(f"       why  {why}")
    out.append("")

    if payload["questions"]:
        out.append("what was asked")
        for q in payload["questions"]:
            state = "open" if q["status"] == consult.OPEN else "answered"
            out.append(f"  [{state}] {q['question']}")
            if q.get("answer"):
                out.append(f"           -> {q['answer']}")
        out.append("")

    out.append("where each claim comes from")
    for item in payload["sources"]:
        out.append(f"  {item['what']:<24} {item['where']}")
    for problem in payload["problems"]:
        out.append(f"  ! {problem}")
    return out


def _markdown(payload: dict) -> list[str]:
    task, change, ver = payload["task"], payload["change"], payload["verification"]
    out = [f"# {task['id']} — {task['title']}".rstrip(" —"), "", f"**{_headline(payload)}**", ""]

    if payload["verdict"]["blockers"]:
        out.append("## In the way")
        out.append("")
        for item in payload["verdict"]["blockers"]:
            out.append(f"- {item['why']}  \n  `{item['fix']}`")
        out.append("")
    if payload["verdict"]["qualifiers"]:
        out.append("## Read before merging")
        out.append("")
        out += [f"- {line}" for line in payload["verdict"]["qualifiers"]]
        out.append("")

    out += ["## What changed", "", f"Attributed by: {change['basis'] or '**nothing** — the change set is unknown'}", ""]
    if change["reached"]:
        out += ["| repository | commits | files | +/- | in the chain |", "|---|---|---|---|---|"]
        for name in change["reached"]:
            entry = change["repos"][name]
            role = "named by the task" if name in change["named"] else "reached through it"
            out.append(
                f"| `{name}` | {len(entry['commits'])} | {len(entry['files'])} | "
                f"+{entry['added']} −{entry['removed']} | {role} |"
            )
        out.append("")
        for name in change["reached"]:
            for commit in change["repos"][name]["commits"]:
                out.append(f"- `{name}` {commit['short']} {commit['subject']}")
        out.append("")

    out += ["## What was verified", ""]
    if not ver["evidence"]:
        out += ["Nothing. No gate record exists under this name.", ""]
    else:
        where = f" inside scope `{ver['scope']}`" if ver.get("scope") else ""
        out += [
            f"Ladder `{' -> '.join(ver['ladder'])}`, climbed to `{ver['level'] or 'nothing'}`"
            f"{where} at {ver['finished']}.",
            "",
        ]
        if ver.get("no_gates"):
            line = f"The record holds no gate at {', '.join('`' + r + '`' for r in ver['no_gates'])}."
            if ver.get("skipped_rungs"):
                one = len(ver["skipped_rungs"]) == 1
                line += (
                    f" {', '.join('`' + r + '`' for r in ver['skipped_rungs'])} "
                    f"{'was' if one else 'were'} climbed to and skipped, not verified."
                )
            out += [line, ""]
        # Outside the `no_gates` guard on purpose: a rung whose gates were all
        # weighed and found not to apply holds gates, so it is never in that
        # list, and hanging this sentence off it would print it nowhere in the
        # one case it exists to describe.
        for entry in ver.get("inapplicable_rungs") or []:
            why = "; ".join(f"`{g['id']}` — {g['reason']}" for g in entry["gates"])
            out += [
                f"`{entry['rung']}` was climbed to, and every gate declared there was weighed against this "
                f"change and did not apply ({why}). Nothing was verified at that rung.",
                "",
            ]
        # The pack has a column of its own because a gate that arrived with an
        # initiative is a different claim from one every session carries, and
        # the reviewer of a pull request is the person who cannot tell them
        # apart without being told.
        out += [
            "| gate | status | declared by | why |",
            "|---|---|---|---|",
        ]
        for gate in ver["gates"]:
            out.append(f"| {gate['id']} | {gate['status']} | {gate.get('pack') or 'core'} | {gate['reason'] or ''} |")
        out += ["", ver["summary"], ""]

    metrics = payload.get("measurements") or {}
    if metrics.get("taken"):
        out += ["## What was measured", ""]
        if metrics.get("refusal"):
            out += [f"**{metrics['refusal']}**", ""]
        out += ["| metric | this run | the series so far |", "|---|---|---|"]
        for entry in metrics["taken"]:
            where = f" ({entry['repo']})" if entry["repo"] else ""
            value = (
                f"{metric_lib.fmt(entry['value'])} {entry['unit']}".strip()
                if entry["value"] is not None
                else "not measured"
            )
            detail = entry["trend"]["text"] if entry["value"] is not None else entry["reason"]
            out.append(f"| `{entry['key']}{where}` | {value} | {detail} |")
        out.append("")

    out += ["## What was decided", ""]
    decisions = payload["decisions"]
    if decisions["owned"]:
        out += ["| decision | value | source | why | |", "|---|---|---|---|---|"]
        for item in decisions["owned"]:
            out.append(
                f"| `{item['id']}` | {item['value']} | {item['source']} | {_cell(_why(item))} | this task's to decide |"
            )
        out.append("")
    if decisions["recorded"]:
        out += ["| toggle | value | source | why |", "|---|---|---|---|"]
        for item in decisions["recorded"]:
            out.append(f"| `{item['id']}` | {item['value']} | {item['source']} | {_cell(_why(item))} |")
    else:
        out.append("Nothing recorded — every toggle in force is a catalog default or a profile value.")
    out.append("")

    if payload["questions"]:
        out += ["## What was asked", ""]
        for q in payload["questions"]:
            state = "**open**" if q["status"] == consult.OPEN else "answered"
            out.append(f"- {state} — {q['question']}" + (f" → {q['answer']}" if q.get("answer") else ""))
        out.append("")

    out += ["## Where each claim comes from", ""]
    out += [f"- {item['what']}: `{item['where']}`" for item in payload["sources"]]
    if payload["problems"]:
        out += ["", "Reading the board reported:"] + [f"- {p}" for p in payload["problems"]]
    return out


def cmd_bundle(ws: Workspace, args) -> int:
    """Exit 0 when the bundle is ready, 1 when something is in the way.

    The exit code is the point of the command being runnable at all: a pack that
    wants merge-readiness enforced declares a gate that runs it. Reading it as a
    report and ignoring the status is equally valid — which is why nothing here
    fails loudly.
    """
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    task_id = args.task or session_id()
    payload = bundle_lib.assemble(ws, task_id, since=args.since)

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0 if payload["verdict"]["ready"] else 1

    lines = _markdown(payload) if (args.markdown or args.write) else _text(payload)
    if args.write:
        path = bundle_lib.bundles_dir(ws.root) / f"{task_id}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{_headline(payload)}")
        print(f"  written to {path}")
        print("  Paste it into the pull request, or attach it. It is derived, so re-run it")
        print("  after the next commit rather than editing it.")
    else:
        print("\n".join(lines))
    return 0 if payload["verdict"]["ready"] else 1
