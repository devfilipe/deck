"""`deck ui` — put the control plane next to the agent.

    +-------------------------------+--------------------------+
    | agent                         | deck>                    |
    | (interactive session)         | toggles, impact, doctor  |
    +-------------------------------+--------------------------+

The split is tmux on purpose. A coding agent is a full-screen application and
needs a real TTY: emulating a terminal inside a pane of our own would mean
writing a terminal emulator to gain nothing.

Both panes agree on the `task` scope without exporting anything, because the
session id derives from the tmux WINDOW. That holds for an agent that was
already running before the console opened.
"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys

from .config import ENV_PREFIX, session_id
from .workspace import find_root


def _quote(parts: list[str]) -> str:
    return " ".join(shlex.quote(p) for p in parts)


def run_ui(args, entrypoint: str) -> int:
    if not 15 <= args.width <= 80:
        sys.exit("deck: --width outside the useful range (15 to 80)")

    root = find_root()
    if not root:
        sys.exit(
            "deck: workspace not resolved.\n"
            f"  export {ENV_PREFIX}ROOT=/path/to/your/workspace\n"
            "  or run from inside the tree (deck init)"
        )

    if not shutil.which("tmux"):
        sys.exit(
            "deck: tmux not found.\n"
            "  Arch: sudo pacman -S tmux    Debian/Ubuntu: sudo apt install tmux\n"
            f"  Without tmux, open the console alone in another terminal: {entrypoint} console"
        )

    # Only propagate a session the operator set deliberately; otherwise let both
    # sides derive the same value from the window.
    prefix = ""
    if os.environ.get(f"{ENV_PREFIX}SESSION"):
        prefix = f"{ENV_PREFIX}SESSION={shlex.quote(os.environ[f'{ENV_PREFIX}SESSION'])} "
    console_cmd = f"{prefix}{shlex.quote(entrypoint)} console"
    agent_cmd = f"{prefix}{args.agent_cmd}"

    commands: list[list[str]] = []
    attach_now: list[str] = []

    if args.popup:
        # A popup is not a pane: it has no window index of its own, so the
        # automatic scope derivation does not apply. Pass this window's id
        # explicitly so the console lands in the same task as the agent.
        if not os.environ.get("TMUX"):
            name = args.session or f"deck-{root.name}"
            up = subprocess.run(["tmux", "has-session", "-t", name], capture_output=True, check=False).returncode == 0
            hint = (
                f"  A session for this workspace is already up. From your terminal:\n      tmux attach -t {name}\n"
                if up
                else "  From a plain terminal, `deck ui` builds the session for you:\n"
                "      deck ui --width 40      agent left, console right\n"
            )
            sys.exit(
                "deck: --popup only works inside tmux — a popup is drawn by tmux itself.\n"
                + hint
                + "  Or run the console on its own, in a second terminal:\n"
                "      deck console"
            )
        commands.append(
            [
                "tmux",
                "display-popup",
                "-E",
                "-w",
                f"{args.width + 30}%",
                "-h",
                "60%",
                "-T",
                " deck console ",
                "-d",
                str(root),
                f"{ENV_PREFIX}SESSION={shlex.quote(session_id())} {shlex.quote(entrypoint)} console",
            ]
        )
    elif os.environ.get("TMUX"):
        # `-f` splits the WHOLE window, not just the current pane: without it,
        # opening the console from an already narrow pane yields a useless strip.
        commands.append(["tmux", "split-window", "-h", "-f", "-l", f"{args.width}%", "-c", str(root), console_cmd])
        commands.append(["tmux", "select-pane", "-L"])
    else:
        name = args.session or f"deck-{root.name}"
        # A session left over from an earlier run is the normal case, not an
        # error: the first attempt builds it, the attach then fails for want of
        # a terminal, and every attempt after that used to die on `duplicate
        # session` — the first run closing the door on all the rest.
        existing = (
            subprocess.run(
                ["tmux", "has-session", "-t", name],
                capture_output=True,
                check=False,
            ).returncode
            == 0
        )

        if existing:
            print(f"session {name} is already up — connecting to it rather than building a second one.")
        else:
            left = console_cmd if args.no_agent else agent_cmd
            commands.append(["tmux", "new-session", "-d", "-s", name, "-c", str(root), left])
            if not args.no_agent:
                # Target `<session>:` = the session's current window. Never a
                # fixed index: with `base-index 1` in the user's config, `:0`
                # does not exist.
                commands.append(
                    [
                        "tmux",
                        "split-window",
                        "-h",
                        "-t",
                        f"{name}:",
                        "-l",
                        f"{args.width}%",
                        "-c",
                        str(root),
                        console_cmd,
                    ]
                )
                commands.append(["tmux", "select-pane", "-t", f"{name}:", "-L"])

        # Attaching needs a terminal to attach TO. Run from somewhere that
        # captures output — an agent's `!`, a pipe, CI — tmux fails with `not a
        # terminal`, which names the symptom and not the fix. Build the session
        # anyway, then say how to reach it.
        detached = args.detach or not sys.stdout.isatty()
        if detached:
            attach_now.append(name)
        else:
            commands.append(["tmux", "attach-session", "-t", name])

    if args.dry_run:
        for command in commands:
            print(_quote(command))
        for name in attach_now:
            print(f"# then, from a terminal: tmux attach -t {name}")
        return 0

    for command in commands:
        if subprocess.run(command, check=False).returncode != 0:
            sys.exit(f"deck: failed — {_quote(command)}")

    for name in attach_now:
        print(f"\nsession {name} is up, with the console beside the agent.")
        print("  Nothing here can attach to it: attaching needs a terminal, and this")
        print("  is not one. From your terminal:")
        print(f"\n      tmux attach -t {name}          # from outside tmux")
        print(f"      tmux switch-client -t {name}   # from inside another session\n")
    return 0
