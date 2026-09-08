"""Board commands: read the tasks, and say what can run at the same time."""

from __future__ import annotations

import json
import os
from pathlib import Path

from .config import ENV_PREFIX, STATE_DIR, publish_identity
from . import board as board_lib
from . import trackers
from .toggles import Toggles
from .workspace import Workspace


def _limit(ws: Workspace, args) -> int:
    if args.parallelism:
        return int(args.parallelism)
    tg = Toggles(root=ws.root)
    return int(tg.resolve("board_parallelism")[0]) if "board_parallelism" in tg.defs else 2


def _scope_line(ws: Workspace) -> str:
    """One line saying which board is being read, and why it is not the whole one."""
    where = "its own board" if ws.scope.get("backlog") else "the workspace board, narrowed to its repositories"
    return f"  scope {ws.scope_name} — {where}\n"


def cmd_board_list(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tasks, problems = board_lib.read(ws)
    if args.json:
        print(json.dumps({"tasks": tasks, "problems": problems}, ensure_ascii=False, indent=2))
        return 0
    if not tasks:
        # Before the early return, not after: an empty board inside a scope is
        # the one case the scope line exists to explain, and it was the one case
        # that never saw it.
        if ws.scope_name:
            print(_scope_line(ws))
        print("no tasks found")
        print("  Sources come from `backlog:` in the descriptor. deck reads a markdown")
        print("  checklist or a tasks file; a pack can declare a command for its own format.")
        for problem in problems:
            print(f"  ! {problem}")
        return 0
    if ws.scope_name:
        print(_scope_line(ws))
    for task in tasks:
        # Three marks, not two. `~` is a task somebody holds, and it is the
        # whole reason this command is worth reading before starting: a board
        # that shows a claimed task as free sends two people at one task.
        mark = {"done": "x", "in-progress": "~"}.get(task["status"], " ")
        repos = ", ".join(task["repos"]) or "(no repository named)"
        print(f"  [{mark}] {task['id']:<24} {task['title'][:60]}")
        # The assignee was read all along and thrown away at the render. A name
        # here is the floor: whatever a source can or cannot say about state,
        # deck knows who holds the task and can print it.
        held = f"   held by {task['assignee']}" if task.get("assignee") else ""
        print(f"        {repos}{held}")
    for problem in problems:
        print(f"  ! {problem}")

    # Said once, not per task. A two-state source cannot express `in-progress`,
    # so an unmarked task there means "not closed" and not "nobody is on it" —
    # and a reader who does not know that reads the wrong thing silently.
    blind = [board_lib.norm(src.get("type", "")) for src in ws.backlog_sources() if trackers.two_state(src)]
    # `ext_provider`, not `_tracked`: the second is an internal marker that
    # reconciliation strips before the tasks are returned, so a condition on it
    # is a condition that never fires.
    if blind and any(t.get("ext_provider") for t in tasks):
        kinds = ", ".join(sorted(set(blind)))
        print(f"\n  {kinds}: two states, so `[ ]` here means not closed, not unclaimed.")
        print("  Say how this board writes it down, in the source:")
        print("    in_progress: assignee        anyone assigned is on it")
        print("    in_progress: label:wip       that label is what taken means here")
    return 0


def cmd_board_plan(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    tasks, problems = board_lib.read(ws)
    limit = _limit(ws, args)
    payload = board_lib.plan_with_decisions(ws, Toggles(root=ws.root), tasks, limit)

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if ws.scope_name:
        print(_scope_line(ws))
    print(f"{sum(len(g['tasks']) for g in payload['groups'])} open task(s) · parallelism {limit}\n")
    for bucket in payload["groups"]:
        how = "parallel" if bucket["parallel"] else "alone"
        print(f"  group {bucket['index']} ({how})")
        for task in bucket["tasks"]:
            reaches = ", ".join(task["order"]) or "(no repository named)"
            print(f"    {task['id']:<24} {task['title'][:52]}")
            print(f"      reaches: {reaches}")
            if task["target"]:
                print(f"      target:  {task['target']}")
        print()
    for caution in payload.get("cautions") or []:
        print(f"  !! {caution}")
    if payload.get("cautions"):
        print()
    if payload["skipped"]:
        print(f"  done, not planned: {', '.join(payload['skipped'])}")
    for problem in problems:
        print(f"  ! {problem}")
    print("\n  This is a plan, not a run. deck does not orchestrate agents: Claude Code")
    print("  already does that. Hand this to a workflow — /deck:board — which spawns")
    print("  one worktree-isolated agent per task and runs each group in parallel.")
    return 0


def cmd_board_why(ws: Workspace, args) -> int:
    """Explain why two tasks cannot run together."""
    tasks, _ = board_lib.read(ws)
    by_id = {t["id"]: t for t in tasks}
    for ident in (args.a, args.b):
        if ident not in by_id:
            print(f"deck: no task named {ident}")
            return 1
    reason = board_lib.conflicts(ws, by_id[args.a], by_id[args.b])
    if reason:
        print(f"{args.a} and {args.b} must not run together: {reason}")
    else:
        print(f"{args.a} and {args.b} can run at the same time")
    return 0


def _writes_allowed(ws: Workspace, what: str, args) -> bool:
    """Writing to a tracker is outward-facing, so it is a decision, not a default."""
    tg = Toggles(root=ws.root)
    setting = tg.resolve("tracker_writes")[0] if "tracker_writes" in tg.defs else "ask"
    if setting == "off":
        print(f"deck: tracker writes are off (`tracker_writes`). {what} was not sent.")
        return False
    if setting == "allow" or getattr(args, "yes", False):
        return True
    print(f"deck: {what} would be sent to the tracker.")
    print("  This changes state other people can see. Re-run with --yes, or set")
    print("  `tracker_writes: allow` if this workspace should not ask each time.")
    return False


def _board_anchor(ws: Workspace, source: dict) -> Path:
    """The directory whose git identity a write to this file source publishes under.

    The file's own directory, not the workspace root: a workspace holds several
    repositories and the board may live in any of them, so the identity that
    signs the commit is the one configured where the file is — which is also
    the only reading that stays right when two of them disagree.
    """
    declared = board_lib.norm(source.get("file", ""))
    return ws.resolve_path(declared).parent if declared else ws.root


def cmd_board_whoami(ws: Workspace, args) -> int:
    """Which account each source would act as. Tokens are never printed."""
    sources = ws.backlog_sources()
    if not sources:
        print("no backlog sources declared")
        return 0
    print(f"  {'type':<10} {'host or repo':<38} {'token':<9} {'from':<24} user")
    local = False
    for source in sources:
        kind = board_lib.norm(source.get("type", ""))
        if kind in ("tasks", "board", "roadmap", "checklist") or source.get("command"):
            local = True
            # A file source has no account, but it does have an identity, and it
            # is the one that ends up in a commit. Printing `-` here was the same
            # silence that let the login through: the column exists to say who
            # this source would act as, and for a file that is answerable.
            name, origin = publish_identity(_board_anchor(ws, source))
            print(f"  {kind:<10} {str(source.get('file', 'local')):<38} {'n/a':<9} {origin:<24} {name or '-'}")
            continue
        who = trackers.identity(source)
        print(f"  {who['type']:<10} {who['host']:<38} {who['token']:<9} {who['from']:<24} {who['user']}")
    print("\n  A token is resolved at call time: $DECK_TOKEN_<TYPE>, then the")
    print("  conventional variable, then ~/.netrc, then a `token_command` the")
    print("  descriptor names. It is never read from the descriptor itself.")
    if local:
        print("\n  A file source is committed and published, so a claim in one is recorded")
        print("  under the identity its repository publishes under — git's `user.name`,")
        print("  read where the file lives, never $USER. $DECK_USER overrides it, and")
        print("  `deck board claim <id> <name>` overrides both.")
    return 0


def cmd_board_show(ws: Workspace, args) -> int:
    tasks, problems = board_lib.read(ws)
    task = next((t for t in tasks if t["id"] == args.id), None)
    if not task:
        print(f"deck: no task named {args.id}")
        for problem in problems:
            print(f"  ! {problem}")
        return 1
    if args.json:
        print(json.dumps(task, ensure_ascii=False, indent=2))
        return 0
    print(f"{task['id']}  {task['title']}\n")
    if task.get("as_a") or task.get("so_that"):
        if task.get("as_a"):
            print(f"  as        {task['as_a']}")
        if task.get("so_that"):
            print(f"  so that   {task['so_that']}")
        print()
    print(f"  status    {task['status']}")
    print(f"  repos     {', '.join(task['repos']) or '(none named)'}")
    if task.get("assignee"):
        print(f"  claimed   {task['assignee']}")
    if task.get("labels"):
        print(f"  labels    {', '.join(task['labels'])}")
    if task.get("url"):
        print(f"  url       {task['url']}")
    if task.get("ext_provider") and task.get("ext_id"):
        linked = "   (reconciled with the local entry)" if task.get("linked") else ""
        print(f"  external  {task['ext_provider']}:{task['ext_id']}{linked}")
    criteria = task.get("acceptance") or []
    if criteria:
        met = set(task.get("accepted") or [])
        print(f"\n  acceptance   {len(met)} of {len(criteria)} accepted")
        for item in criteria:
            print(f"    [{'x' if item in met else ' '}] {item}")
    if task.get("decides"):
        print(f"\n  decides   {', '.join(task['decides'])}   (this task makes the call, in context)")
    if task.get("notes"):
        print(f"\n  notes     {task['notes']}")
    reaches = sorted(board_lib.closure(ws, task["repos"]))
    if reaches:
        print(f"\n  reaches   {', '.join(ws.order(reaches))}")
    return 0


def _claimant(kind: str, anchor: Path, args) -> tuple[str, str]:
    """The name to record a claim under, and where that name came from.

    Two questions that look like one, and answering them the same way is what
    put a shell login on this repository's own board. A tracker claim names an
    account that authenticates to that tracker, so `$USER` is nearly right
    there — the account acting is the one holding the token — and a name the
    tracker will not take is already an error, because `trackers.claim` reads
    its own write back and says which name was recorded instead.

    A file board has no such backstop. It is committed and pushed, and the only
    thing that ever reads the name is a person, later, in a public diff.
    """
    if args.who:
        return args.who, "--who"
    if kind in ("tasks", "board"):
        name, origin = publish_identity(anchor)
        return name or "", origin
    for var in (f"{ENV_PREFIX}USER", "USER"):
        if os.environ.get(var):
            return os.environ[var], f"${var}"
    return "", "not set"


def cmd_board_claim(ws: Workspace, args) -> int:
    source, task = board_lib.source_for(ws, args.id)
    if task is None:
        print(f"deck: no task named {args.id}")
        return 1
    # Before the claimant is resolved, because which source holds the task is
    # what decides where the name comes from.
    if source is None:
        print(f"deck: {args.id} is not in a source deck can write to")
        return 1

    kind = board_lib.norm(source.get("type", ""))
    local = kind in ("tasks", "board")
    anchor = _board_anchor(ws, source)
    who, origin = _claimant(kind, anchor, args)
    if not who:
        if local:
            print("deck: no name to claim as. A file board is committed, so deck records the")
            print("  identity its repository publishes under, and none is set where it lives.")
            print(f'  Set it:       git -C {anchor} config user.name "<the name you publish under>"')
            print(f"  Or name one:  deck board claim {args.id} <name>, or set $DECK_USER")
        else:
            print("deck: no name to claim as. Pass one, or set DECK_USER.")
        return 1

    if task.get("assignee") and task["assignee"] != who and not args.force:
        print(f"deck: {args.id} is already claimed by {task['assignee']}.")
        print("  Two agents on one task produce a merge nobody can review.")
        print("  Use --force only after talking to them.")
        return 1

    if not _writes_allowed(ws, f"claiming {args.id} for {who}", args):
        return 1

    if local:
        path = ws.resolve_path(board_lib.norm(source.get("file", "")))
        if board_lib.update_local(ws, path, args.id, {"assignee": who, "status": "in-progress"}):
            print(f"claimed {args.id} for {who} in {path}")
            print(f"  {who} comes from {origin} — this file is committed, so that is the")
            print("  name the claim is published under.")
            if origin != "--who":
                override = f", or set ${ENV_PREFIX}USER" if origin == "git user.name" else ""
                print(f"  Another name:  deck board claim {args.id} <name>{override}")
            return 0
        print(f"deck: could not update {args.id} in {path}")
        return 1

    try:
        print(trackers.claim(source, args.id, who))
    except trackers.TrackerError as exc:
        print(f"deck: {exc}")
        return 1
    return 0


def cmd_board_done(ws: Workspace, args) -> int:
    """Close a task — but not on the strength of someone saying it is closed.

    deck spends its whole surface refusing to let a rung the ladder did not
    reach be reported as reached. Marking a task done with no evidence that
    anything ran would undo that in one command, so the gate record is the
    precondition and `--force` is the deliberate exception.
    """
    source, task = board_lib.source_for(ws, args.id)
    if task is None:
        print(f"deck: no task named {args.id}")
        return 1
    if task.get("status") == "done":
        print(f"{args.id} is already done")
        return 0

    evidence = ws.root / STATE_DIR / "gates" / f"{args.id}.json"
    if not evidence.is_file() and not args.force:
        print(f"deck: no gate evidence for {args.id} — nothing has been verified under that name.")
        print(f"  Run it:      deck gate run --task {args.id}")
        print("  Or say so:   --force, for a task the ladder does not cover")
        return 1

    failed = []
    if evidence.is_file():
        try:
            record = json.loads(evidence.read_text(encoding="utf-8"))
            failed = [g["id"] for g in record.get("gates", []) if g.get("status") in ("failed", "blocked")]
        except (OSError, ValueError):
            pass
    if failed and not args.force:
        print(f"deck: {args.id} has gates that did not pass: {', '.join(failed)}")
        print(f"  deck gate report --task {args.id}   to see why")
        return 1

    # Acceptance criteria are the task's own definition of done, and they are
    # the half a gate cannot reach: the ladder proves the code holds together,
    # not that it does what somebody asked for. Closing without them is the
    # commonest way a green delivery still fails the person who wanted it.
    criteria = task.get("acceptance") or []
    already = set(task.get("accepted") or [])
    if criteria and not args.force:
        claimed = set(getattr(args, "accepted", None) or []) | already
        unmet = [c for c in criteria if c not in claimed]
        if unmet:
            print(f"deck: {args.id} declares {len(criteria)} acceptance criteria, {len(unmet)} not accepted:")
            for item in unmet:
                print(f"  [ ] {item}")
            print("\n  Accept what the change actually satisfies:")
            print(f'    deck board done {args.id} --accept "<the criterion, verbatim>" --yes')
            print("  Or say why the ladder is the whole story here, with --force.")
            return 1

    if source is None:
        print(f"deck: {args.id} is not in a source deck can write to")
        return 1

    kind = board_lib.norm(source.get("type", ""))
    if not _writes_allowed(ws, f"closing {args.id}", args):
        return 1

    if kind in ("tasks", "board"):
        path = ws.resolve_path(board_lib.norm(source.get("file", "")))
        changes = {"status": "done"}
        if criteria:
            changes["accepted"] = sorted(set(getattr(args, "accepted", None) or []) | already)
        if board_lib.update_local(ws, path, args.id, changes):
            print(f"closed {args.id} in {path}")
            if task.get("ext_provider") and task.get("ext_id"):
                print(f"  {task['ext_provider']}:{task['ext_id']} is not touched — close it where it lives.")
            return 0
        print(f"deck: could not update {args.id} in {path}")
        return 1

    # Closing a tracker item is a different call per provider, with a workflow
    # behind it that deck does not model — a Jira transition is not a field
    # write. Saying so beats guessing at someone's workflow.
    print(f"deck: {args.id} lives in {kind}, and deck does not close {kind} items.")
    if task.get("url"):
        print(f"  Close it there: {task['url']}")
    return 1


def cmd_board_new(ws: Workspace, args) -> int:
    # The scope's own board when there is one: a task created while working
    # inside an initiative belongs to that initiative's board, not the shared
    # one it would otherwise have to be moved off later.
    sources = ws.backlog_sources()
    target = None
    for source in sources:
        kind = board_lib.norm(source.get("type", ""))
        if args.to and kind != args.to:
            continue
        if kind in ("tasks", "board") or kind in trackers.FETCH:
            target = source
            break
    if target is None:
        print("deck: no backlog source to write to")
        print("  Declare one under `backlog:` — a tasks file, or a tracker.")
        return 1

    kind = board_lib.norm(target.get("type", ""))
    ext: dict = {}
    if getattr(args, "ext", None):
        provider, _, ident = args.ext.partition(":")
        if not provider or not ident:
            print("deck: --ext takes <provider>:<id>, for example --ext jira:PROJ-412")
            return 1
        ext = {"ext_provider": provider.strip().lower(), "ext_id": ident.strip()}
    repos = [r.strip() for r in ",".join(args.repos or []).split(",") if r.strip()]
    for name in repos:
        ws.repo(name)

    if not _writes_allowed(ws, f"creating a task in the {kind} source", args):
        return 1

    if kind in ("tasks", "board"):
        declared = board_lib.norm(target.get("file", ""))
        if not declared:
            # The old default was `.deck/board.yaml`, which is the one place a
            # shared board must not go: `.deck/` is per machine and not
            # versioned, so the task would be invisible to everyone else on the
            # team and gone with the checkout.
            print("deck: that backlog source declares no `file:`, so there is nowhere to write")
            print("  Add one, somewhere the team versions:")
            print("    backlog:")
            print("      - { type: tasks, file: docs/board.yaml }")
            print("  Or write to a tracker instead, with --to <github|gitlab|jira|gerrit>.")
            return 1
        path = ws.resolve_path(declared)
        ident = args.id or board_lib.re.sub(r"[^A-Za-z0-9]+", "-", args.title.lower())[:32].strip("-")
        board_lib.add_local(
            ws,
            path,
            {
                "id": ident,
                "title": args.title,
                "repos": repos,
                "status": "open",
                "exclusive": bool(args.exclusive),
                **ext,
            },
        )
        print(f"created {ident} in {path}")
        return 0

    try:
        print(trackers.create(target, args.title, args.body or ""))
    except trackers.TrackerError as exc:
        print(f"deck: {exc}")
        return 1
    return 0


def cmd_board_ask_plan(ws: Workspace, args) -> int:
    """Every decision the open board is waiting on, asked once.

    This is the command that makes an autonomous run possible. Inside a run an
    agent has no channel to a person, so a toggle left at `ask` is a wall rather
    than a prompt. Answer them here, in the session that has someone attached,
    and the run has nothing left to stop it.
    """
    tasks, problems = board_lib.read(ws)
    tg = Toggles(root=ws.root, session=getattr(args, "session", None))
    questions = board_lib.pending_decisions(ws, tg, tasks, args.stage)

    if args.json:
        print(
            json.dumps(
                {"stage": args.stage, "questions": questions, "problems": problems}, ensure_ascii=False, indent=2
            )
        )
        return 0

    owned = board_lib.owned_decisions(tasks)
    if owned:
        print("owned by a task, and deliberately not answered here:")
        for item in owned:
            print(f"  {item['id']:<20} {item['task']} exists to decide it — it escalates with `deck ask`")
        print()

    if not questions:
        print(f"nothing pending at stage `{args.stage}` — the board can run unattended")
        for problem in problems:
            print(f"  ! {problem}")
        return 0

    print(f"{len(questions)} decision(s) the board is waiting on\n")
    for q in questions:
        print(f"  {q['header']:<12} {q['question']}")
        print(f"  {'':<12} stage {q.get('stage', 'plan')}   risk {q['risk']}   blocks {', '.join(q['blocks'])}")
        for option in q["options"]:
            print(f"      {option['value']:<14} {option.get('label', '')} — {option.get('description', '')}")
        print(f"      deck toggle set --at workspace {q['id']} <value>\n")
    print("  Until these are answered, an agent that reaches them has nowhere to ask.")
    return 1


TEMPLATE = """  - id: ABC-1
    title: One line, in the words of whoever wants it

    # The briefing. A title says what to touch; these say what it is for, which
    # is what an agent needs in order to choose between two plausible ways of
    # doing it.
    as_a: someone who runs the board unattended
    so_that: a delivery that passes the ladder is also the thing that was asked for

    repos: [api-schema]          # what this task edits. `deck board show` adds what it reaches
    decides: [api_compat]        # optional: a toggle THIS task exists to answer

    # The definition of done, in the words of the person who will judge it. The
    # ladder proves the code holds together; these say it does what was wanted,
    # which no gate can decide. `deck board done` refuses until they are accepted.
    acceptance:
      - a client on the old schema keeps working, verified against the recorded contract
      - the new field appears in the published table
      - the ladder is green under this task's name

    notes: |
      Anything a person would say in the handover and nowhere else: what was
      tried before, which decision this reverses, who to ask.

    status: open                 # open | in-progress | done
    exclusive: false             # true = nothing else may run beside it
    ext_provider: jira           # optional: where this work lives elsewhere
    ext_id: ABC-1
"""


def cmd_board_template(ws: Workspace, args) -> int:
    """A well-formed board item, to copy.

    Printed rather than written, because where the board lives is the team's
    decision and deck has no business guessing at it.
    """
    print(TEMPLATE)
    print("Paste it under `tasks:` in the file your `backlog:` names, and edit.")
    print("Two fields earn their place more than the rest:")
    print("  acceptance  what a gate cannot decide — that this is what was asked for")
    print("  decides     a choice that IS the work, so nobody answers it in advance")
    return 0
