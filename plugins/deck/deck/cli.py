"""deck — a control plane for coding agents working across repositories.

One entry point, one --help. Every subcommand answers a question an agent (or a
person) has to answer before changing code across more than one repository:

    deck doctor                  is this workspace usable, and what is missing
    deck impact <repo>           what does a change here reach, in what order
    deck scopes                  which named subsets of the registry exist
    deck toggle list             what is decided, and where each value came from
    deck toggle ask-plan         what still has to be asked, as ready questions
    deck bundle --task <id>      what a reviewer reads instead of the diff
    deck metrics list            which way the numbers behind the gates are going
    deck console | ui            the control plane beside the agent
    deck statusline              the control plane inside the agent's window

`--scope <name>` before the command narrows every one of them to one initiative:
its repositories, its board, and the posture it recorded for itself.
"""

from __future__ import annotations

import argparse
import os
import sys

from . import __version__
from pathlib import Path

from . import (
    cmd_ask,
    cmd_board,
    cmd_bundle,
    cmd_cost,
    cmd_gate,
    cmd_metrics,
    cmd_mount,
    cmd_pack,
    cmd_propose,
    cmd_setup,
    cmd_toggle,
    cmd_workspace,
)
from .config import ENV_PREFIX, STATE_DIR
from .workspace import Workspace, find_root

ENTRYPOINT = str(Path(sys.argv[0]).resolve()) if sys.argv and sys.argv[0] else "deck"


def assist_default() -> float:
    from .assist import DEFAULT_BUDGET

    return DEFAULT_BUDGET


def _workspace_parsers(sub) -> None:
    sub.add_parser("root", help="print the resolved workspace root").set_defaults(fn=cmd_workspace.cmd_root)

    p = sub.add_parser("info", help="summary of the workspace")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_info)

    p = sub.add_parser("repos", help="repositories in the descriptor")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--downstream-only", action="store_true")
    p.add_argument("--buildable-only", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_repos)

    p = sub.add_parser("path", help="absolute path of a repository")
    p.add_argument("repo")
    p.set_defaults(fn=cmd_workspace.cmd_path)

    p = sub.add_parser("get", help="a descriptor field, by dotted key")
    p.add_argument("key")
    p.set_defaults(fn=cmd_workspace.cmd_get)

    p = sub.add_parser("packs", help="which packs are in play, in merge order, and who overrides whom")
    p.add_argument("--repo", help="only the packs that apply to this repository")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_packs)

    p = sub.add_parser("paths", help="named directories the workspace uses but does not change")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_paths)

    p = sub.add_parser("targets", help="the deployment allowlist")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_targets)

    p = sub.add_parser("scopes", help="the named subsets of the registry")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_scopes)

    p = sub.add_parser("scope", help="one scope: its repositories, its board, its posture")
    p.add_argument("name")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_scope)

    p = sub.add_parser("impact", help="what a change in a repository reaches")
    p.add_argument("repo")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_workspace.cmd_impact)

    p = sub.add_parser("order", help="topological order for a set of repositories")
    p.add_argument("repos", nargs="+")
    p.set_defaults(fn=cmd_workspace.cmd_order)

    p = sub.add_parser("setup", help="from an unprepared workspace to a working one, in one command")
    p.add_argument("--root", help="the workspace root (default: detected, or here)")
    p.add_argument("--packs-root", help="where the pack collection lives, or should")
    p.add_argument("--create-packs", action="store_true", help="scaffold a pack for every repository")
    p.add_argument(
        "--repos",
        nargs="*",
        metavar="NAME",
        help="only these, comma or space separated. A checkout is not the same as your work",
    )
    p.add_argument("--force", action="store_true", help="start over on a workspace that already has one")
    p.add_argument(
        "--dry-run", action="store_true", help="discovery only: what deck sees and would do, writing nothing"
    )
    p.set_defaults(fn=cmd_setup.cmd_setup)

    p = sub.add_parser("init", help="create .deck/ from the available templates")
    p.add_argument("--force", action="store_true", help="overwrite existing files")
    p.add_argument(
        "--from",
        dest="from_source",
        nargs="?",
        const="",
        metavar="SOURCE",
        help="also import the registry (repo, submodules, npm); omit the value to auto-detect",
    )
    p.set_defaults(fn=cmd_workspace.cmd_init, from_source=None)

    p = sub.add_parser("import", help="derive the repository registry from the tree layout")
    p.add_argument("source", nargs="?", help="repo, submodules or npm (auto-detected when omitted)")
    p.add_argument("--write", action="store_true", help="fold the result into the descriptor")
    p.set_defaults(fn=cmd_workspace.cmd_import)


def _toggle_parsers(sub) -> None:
    parser = sub.add_parser("toggle", help="read, explain and record decisions")
    parser.add_argument("--repo", help="force the repository context")
    parser.add_argument("--session", help="task-scope session id")
    inner = parser.add_subparsers(dest="toggle_cmd", required=True)

    p = inner.add_parser("list", help="effective value of every toggle")
    p.add_argument("--stage", choices=["plan", "implement", "verify", "deliver"])
    p.add_argument("--group")
    p.add_argument("--json", action="store_true")
    p.set_defaults(tfn=cmd_toggle.cmd_list)

    p = inner.add_parser("get", help="effective value of one toggle")
    p.add_argument("id")
    p.set_defaults(tfn=cmd_toggle.cmd_get)

    p = inner.add_parser("explain", help="meaning, value, source and impact")
    p.add_argument("id")
    p.set_defaults(tfn=cmd_toggle.cmd_explain)

    # `choices` cannot be a fixed list any more: the scopes a workspace declares
    # are as valid a place to record a decision as `task` and `workspace`, and
    # they are only known once the descriptor is read. The command validates the
    # name and prints the ones this workspace has.
    p = inner.add_parser("set", help="record a value")
    p.add_argument("id")
    p.add_argument("value")
    # `--at`, not `--scope`. Two flags spelled the same on one line meaning
    # different things — which initiative, and which layer the value is written
    # to — is a trap whoever writes the second one falls into.
    p.add_argument("--at", default="task", metavar="task|workspace|<scope>", dest="write_at")
    # The value and the layer were always recorded; the sentence explaining the
    # choice lived in a chat log, and six months later nothing told a decision
    # apart from a value nobody had revisited.
    p.add_argument("--why", metavar="REASON", help="why this value, here — recorded beside it in the same file")
    p.set_defaults(tfn=cmd_toggle.cmd_set)

    p = inner.add_parser("profile", help="show or apply a profile")
    p.add_argument("name", nargs="?")
    p.add_argument("--at", default="workspace", metavar="task|workspace|<scope>", dest="write_at")
    p.set_defaults(tfn=cmd_toggle.cmd_profile)

    p = inner.add_parser("ask-plan", help="pending questions for a stage, as JSON")
    p.add_argument("--stage", required=True, choices=["plan", "implement", "verify", "deliver"])
    p.add_argument("--files", nargs="*", help="files being touched, to filter by applies_to")
    p.set_defaults(tfn=cmd_toggle.cmd_ask_plan)

    p = inner.add_parser("validate", help="check the catalog, profiles and recorded choices")
    p.add_argument("--strict", action="store_true", help="warnings fail too")
    p.set_defaults(tfn=cmd_toggle.cmd_validate)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="deck", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    # The first question about anything deck did is which deck did it. `doctor`
    # carries it too, because a diagnosis is what somebody pastes into a report.
    parser.add_argument("--version", action="version", version=f"deck {__version__}")
    # Before the command, not after: it says which piece of the workspace you
    # are in, which is context for everything that follows rather than an
    # argument to any one of them. `dest` is deliberately not `scope` — the
    # namespace argparse builds is flat, and `deck toggle set --at` means a
    # different thing on the same word.
    parser.add_argument(
        "--scope",
        dest="active_scope",
        metavar="NAME",
        help="work inside a declared scope: its repositories, its board, its posture",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    _workspace_parsers(sub)
    _toggle_parsers(sub)

    p = sub.add_parser("mount", help="place the packs for a piece of work")
    p.add_argument("--task", help="task id; defaults to the session id")
    p.add_argument("--repos", nargs="*", help="repositories in play (comma or space separated)")
    p.add_argument("--no-expand", action="store_true", help="do not follow the impact graph")
    p.add_argument("--brief", help="text for a task CLAUDE.local.md, or - to read stdin")
    p.add_argument("--dry-run", action="store_true", help="show what would be placed")
    p.set_defaults(fn=cmd_mount.cmd_mount)

    p = sub.add_parser("unmount", help="take back what was placed")
    p.add_argument("--task", help="task id; defaults to the session id")
    p.add_argument("--session", action="store_true", help="everything this session mounted")
    p.add_argument("--all", action="store_true", help="every mount in this workspace")
    p.set_defaults(fn=cmd_mount.cmd_unmount)

    p = sub.add_parser("hold", help="register this session as holding what is mounted here")
    p.set_defaults(fn=cmd_mount.cmd_hold)

    p = sub.add_parser("mounts", help="what is currently mounted")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_mount.cmd_mounts)

    pack = sub.add_parser("pack", help="create and check the packs that hold your knowledge")
    pack_sub = pack.add_subparsers(dest="pack_cmd", required=True)

    p = pack_sub.add_parser("new", help="scaffold a pack, with its comments intact")
    p.add_argument("name")
    p.add_argument("--dir", help="where to write it (default ./packs/<name>)")
    p.add_argument("--description")
    p.add_argument("--from-workspace", action="store_true", help="seed markers and the descriptor template from here")
    # `--scope`, on `pack new`, is not the global `--scope`: it says what the
    # pack being written is bound to, not which initiative this command runs in.
    p.add_argument(
        "--scope",
        dest="bind_scope",
        metavar="NAME",
        help="bind the pack to an initiative: it loads only under `deck --scope NAME`",
    )
    p.add_argument("--force", action="store_true", help="overwrite existing files")
    p.set_defaults(fn=cmd_pack.cmd_pack_new)

    p = pack_sub.add_parser("review", help="what each pack costs, and what has stopped earning it")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_pack.cmd_pack_review)

    p = pack_sub.add_parser("list", help="the packs in play, and what each contributes")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_pack.cmd_pack_list)

    p = pack_sub.add_parser("sources", help="known sources, or what a pack has vendored")
    p.add_argument("--vendored", action="store_true", help="what is already in this pack")
    p.add_argument("--into", help="the pack directory (default: here)")
    p.set_defaults(fn=cmd_pack.cmd_pack_sources)

    p = pack_sub.add_parser("add", help="vendor skills or agents from a repository into a pack")
    p.add_argument("source", help="owner/repo, a git URL, or a name from `deck pack sources`")
    p.add_argument("--into", help="the pack directory (default: here)")
    p.add_argument("--skills", nargs="*", help="which skills to take")
    p.add_argument("--agents", nargs="*", help="which agents to take")
    p.add_argument("--all", action="store_true", help="take every skill and agent")
    p.add_argument("--with-hooks", action="store_true", help="also take hooks (they run shell commands)")
    p.add_argument("--ref", help="branch or tag")
    p.add_argument("--force", action="store_true", help="replace what is already there")
    p.add_argument("--yes", action="store_true", help="write, instead of listing what would be taken")
    p.set_defaults(fn=cmd_pack.cmd_pack_add)

    p = pack_sub.add_parser("update", help="re-check what a pack vendored against its source")
    p.add_argument("artifact", nargs="?", help="one vendored path, or a glob (default: all of them)")
    p.add_argument("--into", help="the pack directory (default: here)")
    p.add_argument("--check", action="store_true", help="exit non-zero if anything has moved, for a gate")
    p.add_argument("--force", action="store_true", help="take the source copy even over local edits")
    p.add_argument("--timeout", type=int, default=120, help="seconds allowed per clone")
    p.add_argument("--json", action="store_true")
    p.add_argument("--yes", action="store_true", help="take the updates, instead of only reporting them")
    p.set_defaults(fn=cmd_pack.cmd_pack_update)

    p = pack_sub.add_parser("validate", help="check a pack holds together")
    p.add_argument("dir", nargs="?", help="the pack directory (default: here)")
    p.set_defaults(fn=cmd_pack.cmd_pack_validate)

    board = sub.add_parser("board", help="tasks, and what can run at the same time")
    board_sub = board.add_subparsers(dest="board_cmd", required=True)

    p = board_sub.add_parser("list", help="the tasks the declared sources hold")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_board.cmd_board_list)

    p = board_sub.add_parser("plan", help="group the open tasks into what may run together")
    p.add_argument("--parallelism", type=int, help="override board_parallelism")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_board.cmd_board_plan)

    p = board_sub.add_parser("show", help="one task, and what it reaches")
    p.add_argument("id")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_board.cmd_board_show)

    p = board_sub.add_parser("claim", help="take a task, so nobody else picks it up")
    p.add_argument("id")
    p.add_argument(
        "who",
        nargs="?",
        help="defaults to $DECK_USER, then git user.name for a file board and $USER for a tracker",
    )
    p.add_argument("--force", action="store_true", help="claim one someone else holds")
    p.add_argument("--yes", action="store_true", help="send the write without asking")
    p.set_defaults(fn=cmd_board.cmd_board_claim)

    p = board_sub.add_parser("ask-plan", help="every decision the open board is waiting on, asked once")
    p.add_argument("--stage", default="all", choices=["all", "plan", "implement", "verify", "deliver"])
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_board.cmd_board_ask_plan)

    p = board_sub.add_parser("template", help="a well-formed board item, to copy")
    p.set_defaults(fn=cmd_board.cmd_board_template)

    p = board_sub.add_parser("done", help="close a task, once the ladder has run and its criteria are met")
    p.add_argument("id")
    p.add_argument(
        "--accept",
        dest="accepted",
        action="append",
        metavar="CRITERION",
        help="an acceptance criterion this change satisfies, verbatim; repeatable",
    )
    p.add_argument("--force", action="store_true", help="close it with no evidence, or with a gate that failed")
    p.add_argument("--yes", action="store_true", help="send the write without asking")
    p.set_defaults(fn=cmd_board.cmd_board_done)

    p = board_sub.add_parser("new", help="add a task where the team keeps them")
    p.add_argument("title")
    p.add_argument("--repos", nargs="*")
    p.add_argument("--id")
    p.add_argument(
        "--ext",
        metavar="PROVIDER:ID",
        help="the identity this task has elsewhere, e.g. jira:PROJ-412 or linear:ENG-88",
    )
    p.add_argument("--body")
    p.add_argument("--to", help="which source type to write to")
    p.add_argument("--exclusive", action="store_true", help="must run alone")
    p.add_argument("--yes", action="store_true", help="send the write without asking")
    p.set_defaults(fn=cmd_board.cmd_board_new)

    p = board_sub.add_parser("whoami", help="which account each source would act as")
    p.set_defaults(fn=cmd_board.cmd_board_whoami)

    p = board_sub.add_parser("why", help="why two tasks may not run together")
    p.add_argument("a")
    p.add_argument("b")
    p.set_defaults(fn=cmd_board.cmd_board_why)

    gate = sub.add_parser("gate", help="the verification ladder")
    gate_sub = gate.add_subparsers(dest="gate_cmd", required=True)

    p = gate_sub.add_parser("list", help="which gates apply to this change, and why")
    p.add_argument("--repos", nargs="*")
    p.add_argument("--level", help="override gate_level for this listing")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_gate.cmd_gate_list)

    p = gate_sub.add_parser("run", help="climb the ladder and record the evidence")
    p.add_argument("--task", help="task id; defaults to the session id")
    p.add_argument("--repos", nargs="*")
    p.add_argument("--level", help="override gate_level for this run")
    p.add_argument("--only", nargs="*", help="run just these gates")
    p.add_argument("--keep-going", action="store_true", help="continue after a failure")
    p.add_argument("--dry-run", action="store_true", help="resolve the commands, run nothing")
    p.set_defaults(fn=cmd_gate.cmd_gate_run)

    p = gate_sub.add_parser("report", help="read back the evidence for a task")
    p.add_argument("--task")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_gate.cmd_gate_report)

    p = sub.add_parser("bundle", help="the merge-readiness bundle: what a reviewer reads instead of the diff")
    p.add_argument("--task", help="task id; defaults to the session id")
    p.add_argument("--since", help="attribute commits by this timestamp instead of the task's first mount")
    p.add_argument("--markdown", action="store_true", help="render for a pull request rather than a terminal")
    p.add_argument("--write", action="store_true", help="save the markdown under .deck/bundles/")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_bundle.cmd_bundle)

    metrics = sub.add_parser("metrics", help="what the gates measured, and which way it is going")
    metrics_sub = metrics.add_subparsers(dest="metrics_cmd", required=True)

    p = metrics_sub.add_parser("list", help="every metric, declared or recorded, and its trend")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_metrics.cmd_metrics_list)

    p = metrics_sub.add_parser("show", help="the samples behind one trend")
    p.add_argument("id", help="<gate>.<metric>, as `deck metrics list` prints it")
    p.add_argument("--repo", help="only the series taken in this repository")
    p.add_argument("--limit", type=int, default=20, help="how many samples to show (default 20)")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_metrics.cmd_metrics_show)

    p = sub.add_parser("cost", help="tokens and estimated dollars for a task or window")
    p.add_argument("--task", help="use the window a mount and a gate run recorded")
    p.add_argument("--since", help="ISO timestamp")
    p.add_argument("--until", help="ISO timestamp")
    p.add_argument("--session", help="a session id; defaults to this one")
    p.add_argument("--all-sessions", action="store_true", help="every transcript, not just this session")
    p.add_argument(
        "--any-project",
        action="store_true",
        help="do not scope to this workspace (reports other projects' spending too)",
    )
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_cost.cmd_cost)

    propose = sub.add_parser("propose", help="ask Claude for what a parser cannot derive")
    propose_sub = propose.add_subparsers(dest="propose_cmd", required=True)

    p = propose_sub.add_parser("impacts", help="draft the change-propagation edges")
    p.add_argument("--repos", nargs="*", help="propose for these repositories only — cheaper, and easier to review")
    p.add_argument("--budget", type=float, default=assist_default(), help="hard cost cap in USD")
    p.add_argument("--show-prompt", action="store_true", help="print what would be asked, and stop")
    p.add_argument("--yes", action="store_true", help="run without asking")
    p.set_defaults(fn=cmd_propose.cmd_propose_impacts)

    p = propose_sub.add_parser("toggle", help="draft a catalog entry for a recurring decision")
    p.add_argument("decision", help="the decision, in your own words")
    p.add_argument("--budget", type=float, default=assist_default())
    p.add_argument("--show-prompt", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(fn=cmd_propose.cmd_propose_toggle)

    p = propose_sub.add_parser("pack", help="draft a pack for one repository, by reading it")
    p.add_argument("repo")
    p.add_argument(
        "--no-neighbours",
        action="store_true",
        help="read only this repository, not the ones the graph connects to it",
    )
    p.add_argument("--budget", type=float, default=assist_default())
    p.add_argument("--yes", action="store_true", help="permit the call when ai_assist is `ask`")
    p.add_argument("--show-prompt", action="store_true", help="print what would be asked, and stop")
    p.set_defaults(fn=cmd_propose.cmd_propose_pack)

    p = propose_sub.add_parser("apply", help="fold a reviewed proposal into the descriptor or a pack")
    p.add_argument("file", help="a file under .deck/proposals/")
    p.add_argument("--into", help="the pack directory a `pack` proposal writes into")
    p.add_argument(
        "--confidence",
        choices=["high", "medium", "low"],
        default="medium",
        help="the lowest confidence to take (default: medium)",
    )
    p.add_argument("--yes", action="store_true")
    p.set_defaults(fn=cmd_propose.cmd_propose_apply)

    ask = sub.add_parser("ask", help="record a question the catalog has no entry for")
    ask_sub = ask.add_subparsers(dest="ask_cmd", required=True)

    p = ask_sub.add_parser("new", help="write down a question, and keep working")
    p.add_argument("question")
    p.add_argument("--task", help="the task that raised it")
    p.add_argument("--context", help="what a person needs to answer it")
    p.add_argument("--options", help="comma separated, if the choice is already narrow")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_ask.cmd_ask_new)

    p = ask_sub.add_parser("list", help="what is waiting on a person")
    p.add_argument("--resolved", action="store_true", help="what has been answered")
    p.add_argument("--all", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_ask.cmd_ask_list)

    p = ask_sub.add_parser("show", help="one consultation, in full")
    p.add_argument("id")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_ask.cmd_ask_show)

    p = ask_sub.add_parser("resolve", help="answer one, and be told what it wants to become")
    p.add_argument("id")
    p.add_argument("answer")
    p.add_argument("--who")
    p.set_defaults(fn=cmd_ask.cmd_ask_resolve)

    p = ask_sub.add_parser("publish", help="move one into a pack, so a colleague can answer it")
    p.add_argument("id")
    p.add_argument("--into", required=True, help="the pack directory it becomes part of")
    p.set_defaults(fn=cmd_ask.cmd_ask_publish)

    p = ask_sub.add_parser("fold", help="write an answered one into a pack, as a rule, toggle or gate")
    p.add_argument("id")
    p.add_argument("--as", dest="as_kind", required=True, choices=["rule", "toggle", "gate"])
    p.add_argument("--into", required=True, help="the pack directory it becomes part of")
    p.add_argument("--title", help="what to call it (default: the question)")
    p.add_argument("--paths", action="append", help="rule: a glob it applies to; repeatable, and required")
    p.add_argument("--text", help="rule: the wording (default: the answer, verbatim)")
    p.add_argument("--command", help="gate: what a machine runs to check it")
    p.add_argument("--from-level", dest="from_level", default="static", help="gate: the rung it starts at")
    p.add_argument("--gate-id", dest="gate_id", help="gate or toggle: the id (default: from the title)")
    p.add_argument("--values", help="toggle: comma separated (default: the consultation's options)")
    p.add_argument("--group", help="toggle: quality, build, security, delivery, docs or agent")
    p.add_argument("--impact", action="append", help="toggle: `<value>=<what taking it means>`, once per value")
    p.add_argument("--default", help="toggle: the value chosen (default: the one the answer names)")
    p.add_argument("--header", help="toggle: 12 characters or fewer, and it becomes askable")
    p.add_argument("--again", action="store_true", help="fold it a second time, into another pack")
    p.set_defaults(fn=cmd_ask.cmd_ask_fold)

    p = sub.add_parser("doctor", help="diagnose the workspace")
    p.add_argument("--net", action="store_true", help="test target reachability over SSH, and read each tracker board")
    p.set_defaults(fn=None, doctor=True)

    p = sub.add_parser("console", help="control plane REPL")
    p.add_argument("-c", "--command", help="run one command and exit")
    p.set_defaults(fn=None, console=True)

    p = sub.add_parser("ui", help="open the control plane beside the agent")
    p.add_argument("--width", type=int, default=40, help="console width, in %% (default 40)")
    p.add_argument("--popup", action="store_true", help="overlay popup, leaves the layout untouched")
    p.add_argument("--no-agent", action="store_true", help="open only the console")
    p.add_argument("--agent-cmd", default="claude", help="command for the left pane")
    p.add_argument("--session", help="tmux session name")
    p.add_argument("--detach", action="store_true", help="create the session without attaching")
    p.add_argument("--dry-run", action="store_true", help="print the tmux commands and exit")
    p.set_defaults(fn=None, ui=True)

    p = sub.add_parser("statusline", help="render the status line rows")
    p.add_argument("--settings", action="store_true", help="print the configuration snippet")
    p.add_argument("--demo", action="store_true", help="render with sample session data")
    p.add_argument("--no-color", action="store_true")
    p.set_defaults(fn=None, statusline=True)

    return parser


def apply_scope(name: str) -> None:
    """Put the chosen scope in the environment, refusing one nobody declared.

    Exported rather than passed, so that everything deck starts as a subprocess
    — a gate command, a board adapter, a `deck` invoked from a workflow — runs
    inside the same scope as the command that started it. Checked here, once,
    because a misspelled scope that silently widened to the whole registry is
    the one failure mode a subset must not have.
    """
    ws = Workspace(find_root())
    if name not in ws.scopes:
        known = ", ".join(ws.scopes) or "none declared"
        # The name may be perfectly real and simply not on this machine: the
        # descriptor holding `scopes:` is per machine, the pack's template is
        # the team's copy. "Unknown scope" over an initiative a colleague is
        # working in is the wrong sentence, and the fix is one paste away.
        shipped, origins = ws.pack_scopes()
        if name in shipped:
            origin = origins.get(name) or {}
            sys.exit(
                f"deck: scope `{name}` is not declared on this machine, but the `{origin.get('pack')}` pack "
                f"ships it (declared here: {known}). Copy its block from "
                f"{origin.get('template') or 'the pack'} into `scopes:` in {STATE_DIR}/workspace.yaml. "
                "See: deck scopes"
            )
        sys.exit(f"deck: unknown scope `{name}` (declared: {known}). See: deck scopes")
    os.environ[f"{ENV_PREFIX}SCOPE"] = name


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv if argv is not None else sys.argv[1:])

    if getattr(args, "active_scope", None):
        apply_scope(args.active_scope)

    if getattr(args, "doctor", False):
        from .doctor import run_doctor

        return run_doctor(args)
    if getattr(args, "console", False):
        from .console import run_console

        return run_console(args)
    if getattr(args, "ui", False):
        from .ui import run_ui

        return run_ui(args, ENTRYPOINT)
    if getattr(args, "statusline", False):
        from .statusline import run_statusline

        return run_statusline(args, ENTRYPOINT)

    if args.command == "toggle":
        return args.tfn(cmd_toggle.build(repo=args.repo, session=args.session), args)

    return args.fn(Workspace(find_root()), args)
