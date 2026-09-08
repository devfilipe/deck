"""Cost commands: what a task, a session, or a window actually spent."""

from __future__ import annotations

import json
from . import cost as cost_lib
from .workspace import Workspace


def _fmt(n: int) -> str:
    return f"{n:,}".replace(",", " ")


def cmd_cost(ws: Workspace, args) -> int:
    since = until = None
    origin = "the whole transcript"

    if args.task:
        if not ws.root:
            print("deck: workspace not resolved, so a task window cannot be found")
            return 1
        since, until, origin = cost_lib.window_for_task(ws.root, args.task)
        if since is None and until is None:
            print(f"deck: no window recorded for task {args.task}")
            print("  A window comes from a mount and a gate run. Neither exists for this task.")
            return 1
        origin = f"task {args.task} ({origin})"
    else:
        # A timestamp typed without a zone is read as local time, which is what
        # the person typing it meant. Echo the resolved value so that reading is
        # visible rather than a surprise in the numbers.
        if args.since:
            since = cost_lib._parse_ts(args.since)
            if since is None:
                print(f"deck: could not read --since {args.since!r} as a timestamp")
                return 1
            origin = f"since {since.isoformat(timespec='seconds')}"
        if args.until:
            until = cost_lib._parse_ts(args.until)
            if until is None:
                print(f"deck: could not read --until {args.until!r} as a timestamp")
                return 1
            origin = f"{origin} until {until.isoformat(timespec='seconds')}"

    wanted = None if args.all_sessions else (args.session or cost_lib.claude_session())
    # Scoped to this workspace. Falling back to every project on the machine is
    # how a hello-world task came back billed for an unrelated session.
    scope = None if args.any_project else ws.root
    paths = cost_lib.transcripts(wanted, scope)
    if wanted and not any(p.stem == wanted for p in paths):
        print(f"deck: no transcript named {wanted}; falling back to the most recent one here")
    if not paths:
        where = "~/.claude/projects"
        if scope is not None:
            where = f"{where}/{cost_lib.project_slug(scope)}*"
            print(f"deck: no session of this workspace has a transcript yet ({where})")
            print("  Sessions opened elsewhere are not counted. Use --any-project to widen,")
            print("  which reports what other projects spent and is almost never what you want.")
        else:
            print(f"deck: no transcripts found under {where}")
        return 1

    rows = cost_lib.usage_rows(paths[: 1 if not args.all_sessions else 50], since, until)
    prices, multipliers, source = cost_lib.pricing(ws.root)
    report = cost_lib.summarise(rows, prices, multipliers)
    live = cost_lib.sample_delta(ws.root, since, until) if ws.root else None

    if args.json:
        print(
            json.dumps(
                {"window": origin, "price_source": source, "claude_code": live, **report},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    total = report["total"]
    if not rows:
        print(f"no billed messages in {origin}")
        return 0

    print(f"window   {origin}")
    print(f"messages {total['messages']}\n")
    print(f"  {'model':<22} {'in':>10} {'out':>10} {'cache rd':>12} {'cache wr':>10} {'est. USD':>10}")
    for model, bucket in sorted(report["models"].items()):
        usd = f"{bucket['usd']:.4f}" if bucket.get("usd") is not None else "  (no price)"
        print(
            f"  {model:<22} {_fmt(bucket['input']):>10} {_fmt(bucket['output']):>10} "
            f"{_fmt(bucket['cache_read']):>12} {_fmt(bucket['cache_write_5m'] + bucket['cache_write_1h']):>10} {usd:>10}"
        )
    print(
        f"  {'total':<22} {_fmt(total['input']):>10} {_fmt(total['output']):>10} "
        f"{_fmt(total['cache_read']):>12} {_fmt(total['cache_write']):>10} {total['usd']:>10.4f}"
    )

    print("\n  tokens are exact, read from the session transcript")
    print(f"  dollars are an ESTIMATE at list price — {source}")
    if not total["priced"]:
        print("  one or more models have no price in the table; their cost is missing from the total")
    if live:
        print(
            f"\n  Claude Code's own figure for this window: ${live['usd']:.4f} ({live['samples']} status-line samples)"
        )
        if abs(live["usd"] - total["usd"]) > max(0.05, 0.1 * max(live["usd"], 0.01)):
            print("  The two disagree by more than 10%. Claude Code's figure is the one to trust;")
            print("  the estimate here may be using stale prices or the wrong cache multipliers.")
    else:
        print("\n  No status-line samples cover this window, so there is nothing to check the")
        print("  estimate against. Install the status line to get Claude Code's own figure:")
        print("    deck statusline --settings")
    return 0
