"""Gate commands: see the ladder, climb it, and read back the evidence."""

from __future__ import annotations

import json
from pathlib import Path

from . import gates as gate_lib
from . import metrics as metric_lib
from .config import session_id
from .toggles import Toggles
from .workspace import Workspace

MARK = {
    gate_lib.PASSED: "ok  ",
    gate_lib.FAILED: "FAIL",
    gate_lib.SKIPPED: "--  ",
    gate_lib.BLOCKED: "??  ",
    "would run": "->  ",
}


def _measurements(ws: Workspace, tg: Toggles, run: dict) -> list[str]:
    """What this run measured, each against the last sample already on disk.

    Read before anything is appended, so "was" means the previous run and not
    the one being reported.
    """
    out = []
    for sample in run.get("measured") or []:
        label = f"{sample['metric']:<12}"
        if sample.get("value") is None:
            out.append(f"{label} not measured: {sample.get('reason', '')}")
            continue
        unit = (" " + sample.get("unit", "")).rstrip()
        line = f"{label} {metric_lib.fmt(sample['value'])}{unit}"
        previous = metric_lib.latest(ws, tg, sample["key"], sample.get("repo"))
        if previous and isinstance(previous.get("value"), (int, float)):
            delta = sample["value"] - previous["value"]
            line += f" · was {metric_lib.fmt(previous['value'])} on {previous.get('task', '?')}"
            if delta:
                line += f" ({'+' if delta > 0 else ''}{metric_lib.fmt(delta)})"
        out.append(line)
    return out


def _context(ws: Workspace, args) -> tuple[Toggles, list[str], dict | None]:
    tg = Toggles(root=ws.root, session=getattr(args, "session_id", None))

    if args.repos:
        named = [r.strip() for r in ",".join(args.repos).split(",") if r.strip()]
        for name in named:
            ws.repo(name)
        expanded = list(named)
        for name in named:
            for reached in ws.impacted(name):
                if reached not in expanded:
                    expanded.append(reached)
        repos = ws.order(expanded)
    else:
        # The scope's repositories when one is active. A ladder that climbed the
        # whole registry while the work was one initiative would report a colour
        # that says nothing about the change that was made.
        repos = ws.order(ws.selected_repos())

    # A gate that names a host may only ever name one from the allowlist.
    target = None
    chosen = tg.resolve("target")[0] if "target" in tg.defs else None
    if chosen and chosen != "ask":
        target = ws.target(chosen)
        if target is None:
            raise SystemExit(
                f"deck: target `{chosen}` is not in the allowlist. "
                "Declare it under `targets:` in the descriptor, or pick one that is."
            )
    return tg, repos, target


def cmd_gate_list(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tg, repos, _ = _context(ws, args)
    level = args.level or tg.resolve("gate_level")[0]
    plan = gate_lib.applicable(ws, tg, repos, level)

    if args.json:
        print(json.dumps({"level": level, "repos": repos, "gates": plan}, ensure_ascii=False, indent=2, default=str))
        return 0

    rungs = gate_lib.ladder(tg)
    print(f"ladder   {' -> '.join(rungs)}")
    print(f"level    {level}")
    print(f"repos    {', '.join(repos) or '(none)'}\n")
    if not plan:
        print("  No gate is declared. Gates come from a pack's config/gates.yaml.")
        return 0
    for gate in plan:
        state = "runs" if gate["status"] is None else gate["status"]
        mark = MARK.get(gate["status"], "->  ")
        print(f"  {mark} {gate['id']:<12} {gate.get('title', ''):<26} {state}")
        if gate.get("reason"):
            print(f"       {gate['reason']}")
        elif gate.get("per_repo") and gate.get("repos"):
            print(f"       over {', '.join(gate['repos'])}")
        if gate.get("subagent"):
            print("       heavy: run it in a subagent so its output stays out of the main context")
    return 0


def cmd_gate_run(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tg, repos, target = _context(ws, args)
    task = args.task or session_id()
    level = args.level or tg.resolve("gate_level")[0]
    plan = gate_lib.applicable(ws, tg, repos, level)

    if not plan:
        # "0 gate(s) passed" and exit 0 is a green run that verified nothing,
        # and it is exactly what a mis-resolved pack root produces. A ladder
        # with no rungs is a configuration fault, not a clean bill of health —
        # the same fact `gate list` already prints, given the exit status it
        # always needed.
        print("deck: no gate is declared, so nothing was verified.")
        print("Gates come from a pack's config/gates.yaml — check `deck packs`")
        print("resolves the pack you expect.")
        return 1

    if args.only:
        wanted = set(args.only)
        plan = [g for g in plan if g["id"] in wanted]
        if not plan:
            print(f"deck: no gate named {', '.join(sorted(wanted))}")
            return 1

    print(f"task {task} · level {level} · {len(repos)} repositor{'y' if len(repos) == 1 else 'ies'}")
    if target:
        print(f"target {target.get('host')} ({target.get('role', '')})")
    print()

    results, failed = [], False
    for gate in plan:
        if gate["status"] in (gate_lib.SKIPPED, gate_lib.BLOCKED):
            print(f"  {MARK[gate['status']]} {gate['id']:<12} {gate.get('reason', '')}")
            results.append(gate)
            continue
        if failed and not args.keep_going:
            results.append({**gate, "status": gate_lib.SKIPPED, "reason": gate_lib.STOPPED_EARLY, "runs": []})
            print(f"  {MARK[gate_lib.SKIPPED]} {gate['id']:<12} not attempted: {gate_lib.STOPPED_EARLY}")
            continue

        outcome = gate_lib.run_gate(gate, ws, tg, task, target, dry_run=args.dry_run)
        results.append(outcome)

        for run in outcome.get("runs", []):
            where = run.get("repo") or "workspace"
            if args.dry_run and run["status"] != gate_lib.BLOCKED:
                print(f"  ->   {gate['id']:<12} {where:<26} {run['command']}")
            elif run["status"] in (gate_lib.BLOCKED, gate_lib.SKIPPED):
                mark = MARK[run["status"]]
                print(f"  {mark} {gate['id']:<12} {where:<26} {run.get('reason', '')}")
            else:
                mark = MARK[run["status"]]
                print(f"  {mark} {gate['id']:<12} {where:<26} {run['seconds']}s")
                for line in _measurements(ws, tg, run):
                    print(f"       {line}")
                if run["status"] == gate_lib.FAILED:
                    print(f"       exit {run['exit']} · {run['log']}")
                    for line in run.get("tail", "").splitlines()[-6:]:
                        print(f"       | {line}")
        if outcome["status"] in (gate_lib.FAILED, gate_lib.BLOCKED):
            failed = True

    if args.dry_run:
        print("\n  Nothing executed.")
        # A preview exists to be trusted before the real run. One that found a
        # command pointing at a script that is not there is not a clean bill of
        # health, and saying so only in the text above it would let a caller
        # that checks the exit status alone miss it the same way `deck doctor`
        # did.
        return 1 if failed else 0

    # `--only` is a partial run: it merges into the record rather than
    # replacing it. A full run still writes the file wholesale.
    path = gate_lib.record(ws, task, results, level, covered=repos, partial=bool(args.only))
    print(f"\n  {gate_lib.summarise(results)}")
    print(f"  evidence: {path}")

    samples = metric_lib.taken(results)
    if samples:
        written, refusal = metric_lib.append(ws, tg, task, level, samples)
        if refusal:
            print(f"\n  {len(samples)} measurement(s) taken, none kept: {refusal}")
        elif written:
            print(f"  {written} measurement(s) added to the series · deck metrics list")
        elif all(s.get("value") is None for s in samples):
            print("  nothing was measured this run — the reasons are above")
        else:
            mode = metric_lib.store(ws, tg)[1]
            print(f"  metrics_store is `{mode}`, so the numbers above were not kept")
    if failed:
        print("\n  A gate that did not pass is never reported as passed. Fix it, or lower")
        print("  `gate_level` deliberately — the report will say which rung was reached.")
    return 1 if failed else 0


def cmd_gate_report(ws: Workspace, args) -> int:
    if not ws.root:
        print("deck: workspace not resolved")
        return 1
    task = args.task or session_id()
    path = gate_lib.gates_dir(ws.root) / f"{task}.json"
    if not path.is_file():
        print(f"no evidence for task {task}")
        available = sorted(p.stem for p in gate_lib.gates_dir(ws.root).glob("*.json"))
        if available:
            print(f"  recorded: {', '.join(available)}")
        return 1

    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0

    print(f"task {data['task']} · level {data['level']} · {data['finished']}")
    # A record assembled from several runs must not read as one. `--only`
    # merges rather than replacing, which is what makes a partial run useful,
    # and the cost is that two entries can be minutes or days apart — an entry
    # from a run against a tree that has since changed is not evidence of
    # anything. deck does not judge how stale is too stale; it says when the
    # entries disagree about their own time, and names the oldest.
    if data.get("partial_runs"):
        # The flag records the fact; the stamps are the detail. Keyed on the
        # flag rather than on the stamps differing, because two runs a second
        # apart share a timestamp and the record would then claim to be one
        # run — true of the clock, false of the thing it is evidence for.
        stamps = sorted({g.get("finished") for g in data.get("gates", []) if g.get("finished")})
        print("  assembled from more than one run — `--only` merged into this record")
        if len(stamps) > 1:
            print(f"  oldest entry {stamps[0]} · newest {stamps[-1]}")
        print("  Re-run in full to make it one run.")
    # A ladder that climbed inside a subset reports the same green as one that
    # covered the registry. Which it was belongs in the first three lines, not
    # inferred from which repositories happen to appear under each gate.
    whole = data.get("registry_repos")
    covered = data.get("covered_repos") or data.get("scope_repos")
    scope = data.get("scope")
    if covered is not None and whole is not None and len(covered) < len(whole):
        outside = [r for r in whole if r not in covered]
        where = f"scope {scope} · " if scope else ""
        print(f"{where}{len(covered)} of {len(whole)} repositories")
        if outside:
            tail = "outside the scope, still have to keep up" if scope else "not covered by this run"
            print(f"  not covered here: {', '.join(outside)} — {tail}")
    print()
    for gate in data["gates"]:
        print(f"  {MARK.get(gate['status'], '?')} {gate['id']:<12} {gate['status']:<10} {gate.get('reason', '')}")
        for run in gate.get("runs", []):
            where = run.get("repo") or "workspace"
            detail = f"{run.get('seconds', '?')}s" if run.get("status") == gate_lib.PASSED else run.get("reason", "")
            print(f"       {where:<26} {run.get('status', '?'):<10} {detail}")
        # Read back from the record rather than re-measured: the log is what the
        # command printed then, and the number has to be the one that was filed.
        for sample in gate.get("measured") or []:
            where = f" ({sample['repo']})" if sample.get("repo") else ""
            if sample.get("value") is None:
                print(f"       {sample['metric'] + where:<26} not measured: {sample.get('reason', '')}")
            else:
                unit = (" " + sample.get("unit", "")).rstrip()
                print(f"       {sample['metric'] + where:<26} {metric_lib.fmt(sample['value'])}{unit}")
    print(f"\n  {gate_lib.summarise(data['gates'])}")
    if any(g.get("measured") for g in data["gates"]):
        print("  the trend behind these numbers: deck metrics list")
    return 0
