"""Measurements over time: the trend a threshold cannot show.

A gate answers one question — did it pass? — and answers it against a threshold
somebody chose. That is the right shape for a gate and the wrong shape for
decay. Coverage sliding from 86% to 81% under an 80% floor passes every run, and
the day it fails is the day the slide has already happened.

So a gate may also *measure*. A `measures:` entry names a number to read out of
the output the gate already produced, and the engine appends it to a series with
the task, the rung and the moment it was taken. Nothing here fails anything:
this module reports movement, and movement is not a verdict.

Three properties, each the reason for a decision below:

    a number is measured or it is absent — never defaulted, never zero
    a sample comes from a run that actually ran, and from its real output
    the series is append-only, because a history you can rewrite is not evidence

The engine still knows no domain. What to measure, how to find it in the output,
and which direction is good all arrive from a pack as data. `coverage`,
`warnings` and `binary size` are all the same thing from here: a regular
expression a pack wrote, applied to bytes a command printed.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

from .config import STATE_DIR, die, slug, state_root
from .toggles import Toggles
from .workspace import Workspace

ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

# A metric that has no declared direction is reported as movement and nothing
# more. Guessing that "up is good" for a number nobody labelled would put a
# judgement in the report that no one wrote.
BETTER = ("lower", "higher")


# ---------------------------------------------------------------- declaration
def declared(gate: dict) -> list[dict]:
    """The measurements one gate declares, validated.

    Validation is fatal rather than skipped, for the same reason a gate id
    collision is fatal: a measurement silently dropped means a series with a
    hole in it, and a hole in a series reads exactly like a period of stability.
    """
    out: list[dict] = []
    seen: set[str] = set()
    for spec in gate.get("measures") or []:
        mid = spec.get("id")
        if not mid or not ID.match(str(mid)):
            die(f"gate `{gate.get('id')}`: a measure needs an `id` of [a-z0-9_-] (got {mid!r})")
        if mid in seen:
            die(f"gate `{gate.get('id')}`: two measures share the id `{mid}`")
        seen.add(mid)
        pattern = spec.get("pattern")
        if not pattern:
            die(f"gate `{gate.get('id')}`, measure `{mid}`: no `pattern` to read the number with")
        try:
            compiled = re.compile(str(pattern))
        except re.error as exc:
            die(f"gate `{gate.get('id')}`, measure `{mid}`: `pattern` is not a regular expression — {exc}")
        better = spec.get("better")
        if better is not None and str(better) not in BETTER:
            die(f"gate `{gate.get('id')}`, measure `{mid}`: `better` is `lower` or `higher`, not {better!r}")
        out.append(
            {
                "gate": gate.get("id"),
                "id": str(mid),
                "key": f"{gate.get('id')}.{mid}",
                "title": spec.get("title", str(mid)),
                "pattern": str(pattern),
                "_re": compiled,
                "unit": spec.get("unit", ""),
                "better": str(better) if better else None,
                "pack": gate.get("_pack"),
            }
        )
    return out


def catalogue(gates: list[dict]) -> list[dict]:
    """Every measurement every gate declares, flattened."""
    return [m for gate in gates for m in declared(gate)]


# ----------------------------------------------------------------- extraction
def read(spec: dict, output: str) -> tuple[float | None, str]:
    """(value, reason it is missing). The last match wins.

    A command prints its progress before its summary, so a pattern that also
    matches a progress line would otherwise record a figure from the middle of
    the work. Taking the last match makes the rule one an author can rely on
    rather than one they have to discover.
    """
    matches = list(spec["_re"].finditer(output or ""))
    if not matches:
        return None, f"`{spec['pattern']}` matched nothing in what the command printed"
    match = matches[-1]
    raw = match.group(1) if match.groups() else match.group(0)
    try:
        return float(raw), ""
    except (TypeError, ValueError):
        return None, f"`{spec['pattern']}` matched {raw!r}, which is not a number"


def measure(gate: dict, repo: str | None, output: str) -> list[dict]:
    """What one run measured. Called with the same bytes the log received."""
    out = []
    for spec in declared(gate):
        value, reason = read(spec, output)
        out.append(
            {
                "gate": spec["gate"],
                "metric": spec["id"],
                "key": spec["key"],
                "title": spec["title"],
                "repo": repo,
                "value": value,
                "reason": reason,
                "unit": spec["unit"],
                "better": spec["better"],
            }
        )
    return out


def taken(results: list[dict]) -> list[dict]:
    """Every measurement across a whole gate run, in the order it was taken."""
    return [m for gate in results for run in gate.get("runs") or [] for m in run.get("measured") or []]


# ---------------------------------------------------------------------- store
def store(ws: Workspace, tg: Toggles) -> tuple[Path | None, str, str]:
    """(directory, mode, refusal). Where the series lives, from `metrics_store`.

    `shared` with nothing declared is refused rather than quietly written to
    `.deck/`: a team that asked for one history across machines and silently got
    one per machine would not find out until the histories disagreed.
    """
    mode = tg.resolve("metrics_store")[0] if "metrics_store" in tg.defs else "workspace"
    if mode == "off":
        return None, mode, ""
    if not ws.root:
        return None, mode, "workspace not resolved, so there is nowhere to keep a series"
    if mode == "shared":
        raw = (ws.data or {}).get("metrics_dir")
        if not raw:
            return (
                None,
                mode,
                "metrics_store is `shared`, and the descriptor declares no `metrics_dir:`. "
                f"Add `metrics_dir: <path>` to {STATE_DIR}/workspace.yaml, or run "
                "`deck toggle set --at workspace metrics_store workspace`.",
            )
        return ws.resolve_path(str(raw)), mode, ""
    return state_root(ws.root) / "metrics", mode, ""


def path_for(directory: Path, key: str, repo: str | None) -> Path:
    """One file per series, and a series is one metric in one repository.

    Interleaving two repositories in one file would make "first against last" a
    comparison between different things, which is worse than no trend at all.
    """
    return directory / (f"{key}@{slug(repo)}.jsonl" if repo else f"{key}.jsonl")


def append(ws: Workspace, tg: Toggles, task: str, level: str, samples: list[dict]) -> tuple[int, str]:
    """Add what this run measured to the series. (samples written, refusal).

    JSON Lines, appended, one file per metric. Appending never rewrites what is
    already there, which is the property that makes the file worth trusting: no
    run can revise the history it is about to join.
    """
    directory, mode, refusal = store(ws, tg)
    if refusal:
        return 0, refusal
    if directory is None:
        return 0, ""
    written = 0
    at = datetime.now().isoformat(timespec="seconds")
    for sample in samples:
        if sample.get("value") is None:
            continue  # not measured is not a sample; the run report says why
        row = {
            "at": at,
            "task": task,
            "level": level,
            "gate": sample["gate"],
            "metric": sample["metric"],
            "repo": sample.get("repo"),
            "value": sample["value"],
            "unit": sample.get("unit", ""),
            "better": sample.get("better"),
        }
        target = path_for(directory, sample["key"], sample.get("repo"))
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        written += 1
    return written, ""


def _rows(path: Path) -> list[dict]:
    """The samples in one file, oldest first. A malformed line is skipped, not fatal."""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue  # a truncated append; the rest of the history is still readable
        rows.append(row)
    return rows


def series(ws: Workspace, tg: Toggles, key: str, repo: str | None = None) -> list[dict]:
    """One metric's samples in one repository, oldest first."""
    directory, _, refusal = store(ws, tg)
    if directory is None or refusal:
        return []
    path = path_for(directory, key, repo)
    return _rows(path) if path.is_file() else []


def recorded(ws: Workspace, tg: Toggles) -> list[dict]:
    """Every series on disk: `{key, repo, rows}`, including metrics nothing declares now.

    Identity comes from the rows rather than from the filename, so a repository
    whose name needed escaping is still reported under the name it has.
    """
    directory, _, refusal = store(ws, tg)
    if directory is None or refusal or not directory.is_dir():
        return []
    out = []
    for path in sorted(directory.glob("*.jsonl")):
        rows = _rows(path)
        if not rows:
            continue
        out.append(
            {
                "key": f"{rows[-1].get('gate')}.{rows[-1].get('metric')}",
                "repo": rows[-1].get("repo"),
                "file": str(path),
                "rows": rows,
            }
        )
    return out


def latest(ws: Workspace, tg: Toggles, key: str, repo: str | None = None) -> dict | None:
    rows = series(ws, tg, key, repo)
    return rows[-1] if rows else None


# ---------------------------------------------------------------------- trend
def fmt(value: float | None) -> str:
    """A measured number, printed as it was measured."""
    if value is None:
        return "—"
    if float(value).is_integer():
        return str(int(value))
    return f"{value:.2f}".rstrip("0").rstrip(".")


def trend(rows: list[dict]) -> dict:
    """Which way a series is going, said in the terms it was recorded in.

    First against last, and nothing cleverer. A regression line over four points
    would be a claim about a shape nobody measured, and the point of the series
    is that a reader can check every number in it.
    """
    values = [r for r in rows if isinstance(r.get("value"), (int, float)) and not isinstance(r.get("value"), bool)]
    if not values:
        return {"samples": 0, "text": "nothing recorded yet", "direction": None, "judgement": None}

    first, last = values[0], values[-1]
    better = last.get("better") or first.get("better")
    unit = (" " + last.get("unit", "")).rstrip()
    if len(values) == 1:
        return {
            "samples": 1,
            "first": first["value"],
            "last": last["value"],
            "delta": 0.0,
            "direction": None,
            "judgement": None,
            "better": better,
            "unit": last.get("unit", ""),
            "text": f"one sample, {fmt(last['value'])}{unit} on {last.get('task', '?')} — a trend needs a second",
        }

    delta = last["value"] - first["value"]
    direction = "flat" if delta == 0 else ("up" if delta > 0 else "down")
    judgement = None
    if better in BETTER and delta != 0:
        improving = (better == "lower" and delta < 0) or (better == "higher" and delta > 0)
        judgement = "better" if improving else "worse"

    span = f"{first.get('task', '?')} -> {last.get('task', '?')}"
    if delta == 0:
        text = f"{fmt(last['value'])}{unit}, unchanged across {len(values)} runs ({span})"
    else:
        text = (
            f"{fmt(first['value'])} -> {fmt(last['value'])}{unit} across {len(values)} runs "
            f"({span}), {'+' if delta > 0 else ''}{fmt(delta)}"
        )
    if judgement == "worse":
        text += f", moving the wrong way (`better: {better}`)"
    elif judgement == "better":
        text += f", moving the right way (`better: {better}`)"
    elif better not in BETTER and delta != 0:
        text += " — no `better:` is declared, so this is movement, not a verdict"

    return {
        "samples": len(values),
        "first": first["value"],
        "last": last["value"],
        "delta": delta,
        "direction": direction,
        "judgement": judgement,
        "better": better,
        "unit": last.get("unit", ""),
        "text": text,
    }


def regressions(ws: Workspace, tg: Toggles) -> list[dict]:
    """Every recorded metric whose series has moved the wrong way.

    What a threshold cannot tell you, and the only thing in this module a
    reviewer is asked to act on.
    """
    out = []
    for entry in recorded(ws, tg):
        movement = trend(entry["rows"])
        if movement.get("judgement") == "worse":
            out.append({"key": entry["key"], "repo": entry["repo"], "file": entry["file"], **movement})
    return out
