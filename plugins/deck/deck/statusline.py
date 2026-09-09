"""`deck statusline` — the control plane inside the agent's own window.

Two or three persistent rows above the footer, redrawn on every session event:

    my-workspace · payments-api · guided · ctx 34%
    verify: deploy · deploy ? · target 10.0.0.4 · 2 to decide

Claude Code exposes no panel of its own to a plugin. The status line is the one
persistent surface it offers, and it suits the job: `.deck/` still owns the
state, this is only the reading of it.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from .config import load_yaml, session_id, task_file
from .cost import journal_sample
from .toggles import ASK, Toggles
from .workspace import Workspace

DIM, RESET, WARN, GOOD = "\033[2m", "\033[0m", "\033[33m", "\033[32m"

# Toggles worth the space: the ones that change what gets delivered.
HIGHLIGHT = ("gate_level", "deploy_mode", "target")

LABEL = {"gate_level": "verify", "deploy_mode": "deploy", "target": "target"}

SUMMARY = {
    "gate_level": {
        "static": "lint only",
        "build": "through build",
        "deploy": "through deploy",
        "behavior": "through behaviour",
    },
    "deploy_mode": {
        "none": "no deploy",
        "fast": "deploy: sync",
        "packaged": "deploy: package",
        "full": "deploy: full",
    },
}

SETTINGS_HELP = """\
Paste into .claude/settings.json in the project (shared with the team) or
~/.claude/settings.json (yours only):

{
  "statusLine": {
    "type": "command",
    "command": "%s statusline",
    "padding": 1
  }
}

No refreshInterval needed: the state only changes when something writes to
.deck/, and the bar already redraws on every session event."""

DEMO = {"model": {"display_name": "Opus 5"}, "context_window": {"used_percentage": 34}}


def _color(text: str, code: str, enabled: bool) -> str:
    return f"{code}{text}{RESET}" if enabled else text


def _width() -> int:
    try:
        return os.get_terminal_size().columns
    except OSError:
        return 80


def _shorten(text: str, width: int) -> str:
    """Elide the middle — the start and end of a path are what identify it."""
    text = str(text).replace(str(Path.home()), "~")
    if len(text) <= width or width < 12:
        return text
    keep = (width - 1) // 2
    return f"{text[:keep]}…{text[-(width - keep - 1) :]}"


def _short_repo(name: str | None) -> str:
    """Trim a shared prefix so the distinguishing part survives a narrow pane."""
    if not name:
        return ""
    parts = name.split("-")
    return "-".join(parts[-3:]) if len(parts) > 3 else name


def render(session: dict, color: bool = True) -> list[str]:
    try:
        tg = Toggles()
    except SystemExit:
        return [_color("deck: workspace unresolved — run /deck:doctor", WARN, color)]
    if not tg.root:
        return [_color("deck: workspace unresolved — run /deck:doctor", WARN, color)]

    ws = Workspace(tg.root)
    # The status line is told the session's cost on every event. Journalling it
    # here is the only place deck can see Claude Code's own figure.
    journal_sample(tg.root, session, session_id())
    sep = f"{DIM} · {RESET}" if color else " · "
    width = _width()
    field = max(10, width - 8)

    first = [_color(_shorten(tg.root.name, field), DIM, color)]
    if ws.scope_name:
        # Before the repository: which initiative you are in changes what every
        # other figure on the bar is counting.
        first.append(f"[{ws.scope_name}]")
    if tg.repo_detected:
        first.append(_short_repo(tg.repo_detected))
    first.append(_color(tg.profile_name, DIM, color))
    used = (session.get("context_window") or {}).get("used_percentage")
    if isinstance(used, (int, float)):
        first.append(_color(f"ctx {int(used)}%", DIM, color))
    lines = [sep.join(p for p in first if p)]

    second: list[str] = []
    for tid in HIGHLIGHT:
        if tid not in tg.defs:
            continue
        value, _ = tg.resolve(tid)
        if value == ASK:
            second.append(_color(f"{LABEL.get(tid, tid)} ?", WARN, color))
        elif tid == "target":
            second.append(f"target {value}")
        else:
            second.append(SUMMARY.get(tid, {}).get(value, f"{LABEL.get(tid, tid)} {value}"))

    pending = sum(len(tg.pending(stage)) for stage in ("plan", "verify", "deliver"))
    second.append(_color(f"{pending} to decide", WARN, color) if pending else _color("nothing to decide", GOOD, color))
    if not ws.data:
        second.append(_color("no descriptor", WARN, color))
    lines.append(sep.join(second))

    task = load_yaml(task_file(tg.root, session_id()))
    if task.get("values"):
        pairs = " ".join(f"{k}={v}" for k, v in list(task["values"].items())[:4])
        lines.append(_color(f"task: {_shorten(pairs, field)}", DIM, color))
    return lines


def run_statusline(args, entrypoint: str) -> int:
    if args.settings:
        print(SETTINGS_HELP % entrypoint)
        return 0

    if args.demo:
        session = DEMO
    else:
        try:
            raw = sys.stdin.read() if not sys.stdin.isatty() else ""
            session = json.loads(raw) if raw.strip() else {}
        except (ValueError, OSError):
            session = {}

    # This runs on every session change: an error here must not break or clutter
    # the interface. When in doubt, one quiet line.
    try:
        for line in render(session, color=not args.no_color):
            print(line)
    except Exception as exc:  # noqa: BLE001
        print(f"deck: {type(exc).__name__}")
    return 0
