"""Metric commands: what is measured, and which way it has been going.

`deck gate run` answers "did it pass". These two answer the question a passing
ladder cannot: is the number behind the pass getting better or worse.
"""

from __future__ import annotations

import json

from . import gates as gate_lib
from . import metrics as metric_lib
from .toggles import Toggles
from .workspace import Workspace


def _public(spec: dict) -> dict:
    """A declaration without its compiled pattern, which JSON cannot carry."""
    return {k: v for k, v in spec.items() if not k.startswith("_")}


def _setup(ws: Workspace) -> tuple[Toggles, list[dict], list[dict]]:
    tg = Toggles(root=ws.root)
    catalogue = metric_lib.catalogue(gate_lib.load_gates(ws))
    return tg, catalogue, metric_lib.recorded(ws, tg)


def _where(ws: Workspace, tg: Toggles) -> tuple[str, str]:
    """(one line about the store, refusal). Printed before anything it affects."""
    directory, mode, refusal = metric_lib.store(ws, tg)
    if refusal:
        return f"{mode} · unusable", refusal
    if directory is None:
        return f"{mode} · nothing is kept", ""
    return f"{mode} · {directory}", ""


def cmd_metrics_list(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tg, catalogue, recorded = _setup(ws)
    where, refusal = _where(ws, tg)

    by_key = {spec["key"]: spec for spec in catalogue}
    rows = []
    for entry in recorded:
        movement = metric_lib.trend(entry["rows"])
        spec = by_key.get(entry["key"])
        rows.append(
            {
                "key": entry["key"],
                "repo": entry["repo"],
                "title": spec["title"] if spec else "",
                "declared": spec is not None,
                "file": entry["file"],
                "trend": movement,
            }
        )
    seen = {(r["key"], r["repo"]) for r in rows}
    unmeasured = [spec for spec in catalogue if not any(key == spec["key"] for key, _ in seen)]

    if args.json:
        print(
            json.dumps(
                {
                    "store": where,
                    "refusal": refusal,
                    "declared": [_public(spec) for spec in catalogue],
                    "series": rows,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"store    {where}")
    if refusal:
        print(f"\n  {refusal}")
        return 1
    print(f"declared {len(catalogue)} measurement(s), by {len({s['gate'] for s in catalogue})} gate(s)\n")

    if not catalogue and not rows:
        print("  Nothing declares a measurement. A gate takes one by adding `measures:`")
        print("  to its entry in a pack's config/gates.yaml — see PACKS.md.")
        return 0

    for row in rows:
        name = row["key"] + (f"  ({row['repo']})" if row["repo"] else "")
        print(f"  {name:<34} {row['title']}")
        print(f"       {row['trend']['text']}")
        if not row["declared"]:
            print("       recorded, but no gate declares it now — the series stops here")
    for spec in unmeasured:
        print(f"  {spec['key']:<34} {spec['title']}")
        print(f"       no sample yet — measured the next time `{spec['gate']}` runs")
    print("\n  deck metrics show <id>   the samples behind a trend")
    return 0


def cmd_metrics_show(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tg, catalogue, recorded = _setup(ws)
    where, refusal = _where(ws, tg)
    if refusal:
        print(f"store    {where}\n\n  {refusal}")
        return 1

    matches = [e for e in recorded if e["key"] == args.id and (args.repo is None or e["repo"] == args.repo)]
    if not matches:
        # Declared but never measured is a different answer from "no such
        # metric", and the difference is what the reader has to do next.
        spec = next((s for s in catalogue if s["key"] == args.id), None)
        if spec:
            print(f"{args.id} is declared by gate `{spec['gate']}` and has no sample yet")
            print(f"  It is measured the next time that gate runs: deck gate run --only {spec['gate']}")
            return 1
        print(f"deck: nothing recorded or declared under `{args.id}`")
        known = sorted({e["key"] for e in recorded} | {s["key"] for s in catalogue})
        if known:
            print(f"  known: {', '.join(known)}")
        return 1

    if args.json:
        print(
            json.dumps(
                [
                    {
                        "key": e["key"],
                        "repo": e["repo"],
                        "file": e["file"],
                        "samples": e["rows"][-args.limit :] if args.limit else [],
                        "trend": metric_lib.trend(e["rows"]),
                    }
                    for e in matches
                ],
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    for entry in matches:
        spec = next((s for s in catalogue if s["key"] == entry["key"]), None)
        print(f"{entry['key']}" + (f"  ({entry['repo']})" if entry["repo"] else ""))
        if spec:
            print(f"  gate     {spec['gate']}  (pack {spec['pack'] or 'core'})")
            print(f"  pattern  {spec['pattern']}")
            direction = spec["better"] or "not declared — movement is reported, never judged"
            print(f"  better   {direction}" + (f" · unit {spec['unit']}" if spec["unit"] else ""))
        else:
            print("  gate     no gate declares this metric now")
        print(f"  file     {entry['file']}\n")

        rows = entry["rows"][-args.limit :] if args.limit else []
        print(f"  {'when':<21} {'task':<16} {'rung':<10} {'value':>10}")
        for row in rows:
            print(
                f"  {row.get('at', '?'):<21} {str(row.get('task', '?')):<16} "
                f"{str(row.get('level', '?')):<10} {metric_lib.fmt(row.get('value')):>10}"
            )
        if len(entry["rows"]) > len(rows):
            print(f"  … {len(entry['rows']) - len(rows)} earlier sample(s) not shown (--limit)")
        print(f"\n  {metric_lib.trend(entry['rows'])['text']}")
        print("  Nothing here failed anything. A gate reports a threshold; this reports a direction.")
    return 0
