"""What a piece of work cost: tokens in and out, and an estimate in dollars.

Two sources, and the difference between them matters.

    transcripts   Claude Code writes one JSONL per session under
                  ~/.claude/projects/<project>/. Every assistant message carries
                  a `usage` block: input, output, cache write, cache read. This
                  is exact, always present, and attributable to a time window.

    the status line   Claude Code's own `cost.total_cost_usd`, sampled by
                  `deck statusline` when it is installed. It is the authoritative
                  dollar figure because Claude Code computes it, not us.

deck reports tokens from the transcript and prices them from a table, which is
an *estimate at list price* and says so. Where a status-line sample covers the
same window, the report shows Claude Code's figure beside it. Two numbers that
disagree are worth seeing; one number that hides its provenance is not.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

from .config import STATE_DIR, load_yaml

# List prices per million tokens, cached 2026-06-24 from the Claude API
# reference. Prices change; `.deck/pricing.yaml` overrides this table, and the
# report always labels the dollar figure as an estimate.
PRICES = {
    "claude-fable-5-1": {"input": 10.0, "output": 50.0},
    "claude-fable-5": {"input": 10.0, "output": 50.0},
    "claude-opus-5": {"input": 5.0, "output": 25.0},
    "claude-opus-4-8": {"input": 5.0, "output": 25.0},
    "claude-opus-4-7": {"input": 5.0, "output": 25.0},
    "claude-opus-4-6": {"input": 5.0, "output": 25.0},
    "claude-sonnet-5": {"input": 2.0, "output": 10.0},
    "claude-sonnet-4-6": {"input": 3.0, "output": 15.0},
    "claude-haiku-4-5": {"input": 1.0, "output": 5.0},
}

# Cache is billed relative to the input rate. These multipliers are the standard
# ones; a plan or a model with its own rate overrides them in pricing.yaml.
MULTIPLIERS = {"cache_write_5m": 1.25, "cache_write_1h": 2.0, "cache_read": 0.1}


def pricing(root: Path | None) -> tuple[dict, dict, str]:
    """The price table in force, and where it came from."""
    if root:
        override = load_yaml(root / STATE_DIR / "pricing.yaml")
        if override.get("models"):
            return (
                {**PRICES, **override["models"]},
                {**MULTIPLIERS, **(override.get("multipliers") or {})},
                str(root / STATE_DIR / "pricing.yaml"),
            )
    return PRICES, MULTIPLIERS, "built-in table, list price, cached 2026-06-24"


def claude_session() -> str | None:
    """Claude Code's own session id, which names the transcript file.

    Not deck's task-scope session id: that one is derived from the tmux window
    so two panes can share a task, and it never matches a transcript name.
    Attributing cost to the wrong transcript is the kind of silent error that
    makes a billing report worse than none.
    """
    import os

    return os.environ.get("CLAUDE_SESSION_ID")


def project_slug(path: Path) -> str:
    """Claude Code's directory name for a working directory.

    It flattens the absolute path: every character that is not a letter, a
    digit or a hyphen becomes a hyphen, so /home/me/work/hello_world becomes
    -home-me-work-hello-world.
    """
    return re.sub(r"[^A-Za-z0-9-]", "-", str(path))


def transcripts(session: str | None = None, root: Path | None = None) -> list[Path]:
    """Session transcripts, newest first. One file per session.

    Scoped to the workspace when a root is given: its own project directory and
    any nested one, because a session opened inside a repository of the
    workspace gets a directory of its own.

    Scoping is not a nicety. Without it this returned every transcript on the
    machine, newest first, and the caller took the first — so a task's cost was
    whatever session had most recently written anywhere, and an unrelated
    project running in another terminal was reported as this task's bill.
    """
    base = Path.home() / ".claude" / "projects"
    if not base.is_dir():
        return []

    folders = [d for d in base.iterdir() if d.is_dir()]
    if root is not None:
        slug = project_slug(root)
        folders = [d for d in folders if d.name == slug or d.name.startswith(slug + "-")]

    # rglob, not glob. A workflow's agents write under
    # <project>/<session>/subagents/..., and those are real tokens on a real
    # bill — a board run of eleven agents was invisible here, which made the
    # report worse than absent: it answered, and the answer was wrong by the
    # whole cost of the run. Messages carry their own ids, so the usual
    # deduplication keeps a subagent from being counted twice.
    files = sorted(
        (f for d in folders for f in d.rglob("*.jsonl")),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if session:
        exact = [p for p in files if p.stem == session]
        if exact:
            return exact
    return files


def _parse_ts(value: str | None) -> datetime | None:
    """Always timezone-aware.

    Transcript timestamps carry a zone; a `--since` a person types usually does
    not. Comparing the two raises, so a naive value is read as local time — the
    zone the person typing it is in.
    """
    if not value:
        return None
    try:
        when = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return when.astimezone() if when.tzinfo is None else when


def usage_rows(paths: list[Path], since: datetime | None = None, until: datetime | None = None) -> list[dict]:
    """Every billed message in the window, deduplicated.

    A transcript records the same message more than once as it streams, so the
    rows are keyed by message id. Counting them twice would inflate every figure
    in the report.
    """
    seen: dict[str, dict] = {}
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            message = record.get("message")
            if not isinstance(message, dict):
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            when = _parse_ts(record.get("timestamp"))
            if since and (not when or when < since):
                continue
            if until and (not when or when > until):
                continue
            key = message.get("id") or record.get("uuid")
            if not key or key in seen:
                continue
            cache = usage.get("cache_creation") or {}
            seen[key] = {
                "when": record.get("timestamp"),
                "model": message.get("model") or "unknown",
                "input": usage.get("input_tokens") or 0,
                "output": usage.get("output_tokens") or 0,
                "cache_write_5m": cache.get("ephemeral_5m_input_tokens")
                or (usage.get("cache_creation_input_tokens") or 0 if not cache else 0),
                "cache_write_1h": cache.get("ephemeral_1h_input_tokens") or 0,
                "cache_read": usage.get("cache_read_input_tokens") or 0,
                "session": record.get("sessionId"),
            }
    return sorted(seen.values(), key=lambda r: r["when"] or "")


def summarise(rows: list[dict], prices: dict, multipliers: dict) -> dict:
    """Totals per model, and the estimated cost of each."""
    by_model: dict[str, dict] = {}
    for row in rows:
        bucket = by_model.setdefault(
            row["model"],
            {"messages": 0, "input": 0, "output": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0},
        )
        bucket["messages"] += 1
        for field in ("input", "output", "cache_write_5m", "cache_write_1h", "cache_read"):
            bucket[field] += row[field]

    total = {"usd": 0.0, "input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "messages": 0, "priced": True}
    for model, bucket in by_model.items():
        rate = prices.get(model)
        if not rate:
            bucket["usd"] = None
            bucket["note"] = "no price for this model"
            total["priced"] = False
        else:
            usd = (
                bucket["input"] * rate["input"]
                + bucket["output"] * rate["output"]
                + bucket["cache_write_5m"] * rate["input"] * multipliers["cache_write_5m"]
                + bucket["cache_write_1h"] * rate["input"] * multipliers["cache_write_1h"]
                + bucket["cache_read"] * rate["input"] * multipliers["cache_read"]
            ) / 1_000_000
            bucket["usd"] = round(usd, 4)
            total["usd"] += usd
        total["messages"] += bucket["messages"]
        total["input"] += bucket["input"]
        total["output"] += bucket["output"]
        total["cache_read"] += bucket["cache_read"]
        total["cache_write"] += bucket["cache_write_5m"] + bucket["cache_write_1h"]

    total["usd"] = round(total["usd"], 4)
    return {"models": by_model, "total": total}


# ------------------------------------------------------------------ windows
def window_for_task(root: Path, task: str) -> tuple[datetime | None, datetime | None, str]:
    """When a task started and finished, from what deck already records.

    A mount opens the window and a gate run closes it. Neither exists purely to
    measure cost, which is the point: the timestamps are a by-product of work
    that had to be recorded anyway.
    """
    started = finished = None
    origin = []

    # The durable record first: it outlives the mount manifest, which unmount
    # deletes by design.
    span = root / STATE_DIR / "state" / "tasks" / f"{task}.json"
    if span.is_file():
        try:
            record = json.loads(span.read_text(encoding="utf-8"))
            started = _parse_ts(record.get("started"))
            finished = _parse_ts(record.get("ended"))
            if started:
                origin.append("mount")
            if finished:
                origin.append("unmount")
        except (OSError, ValueError):
            pass

    manifest = root / STATE_DIR / "mounts" / f"{task}.json"
    if started is None and manifest.is_file():
        try:
            started = _parse_ts(json.loads(manifest.read_text(encoding="utf-8")).get("created"))
            origin.append("mount")
        except (OSError, ValueError):
            pass

    evidence = root / STATE_DIR / "gates" / f"{task}.json"
    if finished is None and evidence.is_file():
        try:
            finished = _parse_ts(json.loads(evidence.read_text(encoding="utf-8")).get("finished"))
            origin.append("gate run")
        except (OSError, ValueError):
            pass

    return started, finished, " and ".join(origin) or "nothing recorded for this task"


def samples_path(root: Path) -> Path:
    return root / STATE_DIR / "cost" / "samples.jsonl"


def journal_sample(root: Path, session: dict, session_id: str) -> None:
    """Record what the status line was told. Cheap, and the authoritative $.

    Called from the status line, which already runs on every session event, so
    this costs one appended line and no extra process.
    """
    cost = session.get("cost") or {}
    window = session.get("context_window") or {}
    if not cost and not window:
        return
    path = samples_path(root)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {
                        "at": datetime.now().astimezone().isoformat(timespec="seconds"),
                        "session": session_id,
                        "usd": cost.get("total_cost_usd"),
                        "input": window.get("total_input_tokens"),
                        "output": window.get("total_output_tokens"),
                        "lines_added": cost.get("total_lines_added"),
                        "lines_removed": cost.get("total_lines_removed"),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
    except OSError:
        pass


def sample_delta(root: Path, since: datetime | None, until: datetime | None) -> dict | None:
    """Claude Code's own cost figure across the window, when it was sampled."""
    path = samples_path(root)
    if not path.is_file():
        return None
    rows = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            when = _parse_ts(row.get("at"))
            if when is None or row.get("usd") is None:
                continue
            if since and when < since:
                continue
            if until and when > until:
                continue
            rows.append((when, row))
    except OSError:
        return None
    if len(rows) < 2:
        return None
    rows.sort(key=lambda r: r[0])
    first, last = rows[0][1], rows[-1][1]
    return {
        "usd": round((last.get("usd") or 0) - (first.get("usd") or 0), 4),
        "samples": len(rows),
        "from": rows[0][0].isoformat(timespec="seconds"),
        "to": rows[-1][0].isoformat(timespec="seconds"),
    }
