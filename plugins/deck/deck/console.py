"""`deck console` — the control plane as a plain-text REPL.

Meant to sit beside an agent session (see `deck ui`): the agent works on one
side, you inspect and adjust the state it reads on the other.

Because the state lives in files, a change made here applies the next time the
agent consults it — without interrupting its turn.
"""

from __future__ import annotations

import os
import shlex
import time
from pathlib import Path

from .config import STATE_DIR, load_yaml, session_id, task_file
from .toggles import Toggles
from .workspace import Workspace, current_repo, find_root

BANNER_WIDE = "deck console — `help` lists the commands, `q` quits"
BANNER_NARROW = "`help` = commands · `q` = quit"

HELP = """\
state
  status | st            root, repo, profile, pending decisions
  doctor [--net]         full workspace diagnosis
  watch [seconds]        auto-refreshing header (Ctrl-C returns to the prompt)

decisions
  toggles | t [stage]    effective value of each toggle and where it came from
  explain | x <id>       what it means, current value, source, impact
  set <id> <value> [scope]    scope: task (default), workspace, or a named scope
  profile [name]         show or apply a profile
  asks [stage]           the questions the agent will ask at this stage

workspace
  repos [--verbose]      repositories in the descriptor
  scopes                 the named subsets, and which one is active
  scope <name>           one scope: repositories, board, posture
  impact <repo>          what a change reaches, in execution order
  path <repo>            absolute path
  get <key.path>         a field from the descriptor

  help                   this list
  q | exit               quit\
"""


def _width() -> int:
    try:
        return os.get_terminal_size().columns
    except OSError:
        return 80


def _rule(title: str = "") -> str:
    width = min(_width(), 100)
    if not title:
        return "-" * width
    return f"-- {title} " + "-" * max(0, width - len(title) - 4)


def _shorten(text: str, width: int) -> str:
    text = str(text).replace(str(Path.home()), "~")
    if len(text) <= width or width < 12:
        return text
    keep = (width - 1) // 2
    return f"{text[:keep]}…{text[-(width - keep - 1) :]}"


def header() -> str:
    root = find_root()
    if not root:
        return "workspace not resolved — run `doctor`"

    ws = Workspace(root)
    tg = Toggles(root=root)
    task = load_yaml(task_file(root, session_id()))
    pending = sum(len(tg.pending(stage)) for stage in ("plan", "verify", "deliver"))

    width = _width()
    field = max(10, width - 8)
    lines = [f"root     {_shorten(root, field)}"]
    counted = f"{len(ws.selected_repos())} of {len(ws.repos)}" if ws.scope_name else str(len(ws.repos))
    if width < 64:
        lines += [
            f"repo     {_shorten(current_repo() or '—', field)}",
            f"profile  {tg.profile_name}",
            f"session  {_shorten(session_id(), field)}",
        ]
        lines.append(f"state    {counted} repos · {len(ws.targets)} target(s) · {pending} pending")
    else:
        lines.append(f"repo     {current_repo() or '—'}     profile  {tg.profile_name}     session  {session_id()}")
        lines.append(f"state    {counted} repositories · {len(ws.targets)} target(s) · {pending} pending decision(s)")
    if ws.scope_name:
        lines.append(f"scope    {ws.scope_name}")
    if task.get("values"):
        pairs = ", ".join(f"{k}={v}" for k, v in task["values"].items())
        lines.append(f"task     {_shorten(pairs, field)}")
    return "\n".join(lines)


def dispatch(line: str) -> bool:
    """Run one REPL line. Returns False to quit."""
    from .cli import main as cli_main  # late import: cli imports this module

    parts = shlex.split(line)
    if not parts:
        return True
    cmd, args = parts[0], parts[1:]

    if cmd in ("q", "quit", "exit"):
        return False
    if cmd in ("help", "?", "h"):
        print(HELP)
        return True
    if cmd in ("status", "st"):
        print(header())
        return True
    if cmd == "watch":
        interval = float(args[0]) if args else 2.0
        try:
            while True:
                print("\033[2J\033[H", end="")
                print(_rule(time.strftime("%H:%M:%S")))
                print(header())
                print(_rule("pending"))
                tg = Toggles(root=find_root())
                for stage in ("plan", "verify", "deliver"):
                    for question in tg.pending(stage):
                        print(f"  [{stage}] {question['id']}: {question['question']}")
                time.sleep(interval)
        except KeyboardInterrupt:
            print("\n(watch stopped)")
        return True
    if cmd == "asks":
        tg = Toggles(root=find_root())
        stage = args[0] if args else "plan"
        questions = tg.pending(stage)
        if not questions:
            print(f"nothing pending at stage {stage}")
        for question in questions:
            print(f"\n{question['id']}  [{question['risk']}]  {question['question']}")
            for option in question["options"]:
                print(f"    {option['value']:<12} {option['label']}")
                if option.get("description"):
                    print(f"                 {option['description']}")
        return True

    # everything else maps onto the real CLI, so there is one implementation
    mapping = {
        "toggles": ["toggle", "list"],
        "t": ["toggle", "list"],
        "explain": ["toggle", "explain"],
        "x": ["toggle", "explain"],
        "set": ["toggle", "set"],
        "profile": ["toggle", "profile"],
        "doctor": ["doctor"],
        "repos": ["repos"],
        "scopes": ["scopes"],
        "scope": ["scope"],
        "impact": ["impact"],
        "path": ["path"],
        "get": ["get"],
    }
    if cmd not in mapping:
        print(f"unknown command: {cmd}  (`help` lists the available ones)")
        return True

    argv = mapping[cmd] + args
    if cmd in ("toggles", "t") and args and not args[0].startswith("-"):
        argv = ["toggle", "list", "--stage", args[0]] + args[1:]
    if cmd == "set" and len(args) == 3:
        argv = ["toggle", "set", args[0], args[1], "--at", args[2]]
    cli_main(argv)
    return True


def _setup_readline() -> None:
    try:
        import atexit
        import readline
    except ImportError:
        return

    verbs = [
        "status",
        "doctor",
        "watch",
        "toggles",
        "explain",
        "set",
        "profile",
        "asks",
        "repos",
        "scopes",
        "scope",
        "impact",
        "path",
        "get",
        "help",
        "exit",
    ]
    try:
        tg = Toggles(root=find_root())
        words = verbs + list(tg.defs) + list(Workspace(tg.root).repos)
    except SystemExit:
        words = verbs

    def complete(text, state):
        matches = [w for w in words if w.startswith(text)]
        return matches[state] if state < len(matches) else None

    readline.set_completer(complete)
    readline.parse_and_bind("tab: complete")

    history = Path.home() / ".cache" / "deck" / "console.history"
    history.parent.mkdir(parents=True, exist_ok=True)
    try:
        readline.read_history_file(history)
    except (OSError, PermissionError):
        pass

    def save():
        try:
            readline.set_history_length(500)
            readline.write_history_file(history)
        except (OSError, PermissionError):
            pass

    atexit.register(save)


def run_console(args) -> int:
    if args.command:
        dispatch(args.command)
        return 0

    if not find_root():
        print("workspace not resolved.")
        print("  export DECK_ROOT=/path/to/your/workspace")
        print("  or run `deck init` from inside the tree")
        return 1

    _setup_readline()
    print(_rule("deck"))
    print(header())
    print(_rule())
    print(BANNER_WIDE if _width() >= 64 else BANNER_NARROW)

    while True:
        try:
            line = input("\ndeck> ")
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        try:
            if not dispatch(line):
                return 0
        except SystemExit:
            pass  # a command failing must not close the operator's console
        except Exception as exc:  # noqa: BLE001
            print(f"error: {exc}")


STATE_DIR = STATE_DIR  # re-exported for callers that build paths from here
