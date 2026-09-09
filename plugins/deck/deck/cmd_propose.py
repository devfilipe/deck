"""Propose commands: ask Claude for the two inputs a parser cannot produce."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

from . import assist, consult
from . import cost as cost_lib
from .config import die, dump_yaml, load_yaml, norm, title_slug
from .toggles import Toggles
from .workspace import Workspace, pack_name

D, R = "\033[2m", "\033[0m"


def _permitted(ws: Workspace, args) -> bool:
    tg = Toggles(root=ws.root)
    setting = tg.resolve("ai_assist")[0] if "ai_assist" in tg.defs else "ask"
    if setting == "off":
        print("deck: `ai_assist` is off. deck will not call Claude.")
        return False
    if setting == "allow" or args.yes:
        return True
    print("deck: this asks Claude to read the workspace and draft a proposal.")
    print("  It runs read-only, costs money, and writes nothing but a file under")
    print("  .deck/proposals/. Re-run with --yes, or set `ai_assist: allow`.")
    return False


def _watch(elapsed: float, name: str, target: str) -> None:
    """Print one read or search as `assist.ask` makes it, live.

    Only when stdout is a terminal. Piped into a file or a log, this would be
    noise nobody is watching rather than the wait it is meant to make legible
    — and a `deck propose` captured by a script, as the suite itself does
    throughout, must stay exactly as quiet as it always was.
    """
    if not sys.stdout.isatty():
        return
    print(f"  {elapsed:>5.0f}s  {name.lower():<5} {target}")


def _report(accounting: dict, path: Path) -> None:
    usd = accounting.get("usd")
    print(f"\n  proposal: {path}")
    print(
        f"  cost: {'$%.4f' % usd if usd is not None else 'unknown'} · "
        f"{accounting['input']} in / {accounting['output']} out · {accounting['seconds']}s"
    )
    if accounting.get("denials"):
        print(f"  {accounting['denials']} tool call(s) were denied — the run is read-only by construction")
    # What the run spent is attributable to something more specific than the
    # run: which file it read how many times, what it searched for. The
    # difference between "run it again with fewer repositories" and "run it
    # again without that one".
    reads = accounting.get("reads") or {}
    if reads:
        top = sorted(reads.items(), key=lambda kv: -kv[1])[:5]
        print(f"  read: {', '.join(f'{p} x{n}' if n > 1 else p for p, n in top)}")
    searches = {**(accounting.get("greps") or {}), **(accounting.get("globs") or {})}
    if searches:
        top = sorted(searches.items(), key=lambda kv: -kv[1])[:5]
        print(f"  searched: {', '.join(f'{p} x{n}' if n > 1 else p for p, n in top)}")


def cmd_propose_impacts(ws: Workspace, args) -> int:
    if not ws.data:
        print("deck: no descriptor — run `deck init` first")
        return 1
    if not ws.repos:
        print("deck: the registry is empty. Import it first: deck import")
        return 1
    repos = ws.repos
    if args.repos:
        named = [r.strip() for r in ",".join(args.repos).split(",") if r.strip()]
        for name in named:
            ws.repo(name)
        # Everything already declared stays in the prompt as context: an edge is
        # about a pair, and hiding half the workspace invites duplicates.
        repos = {k: v for k, v in ws.repos.items() if k in named or v.get("impacts")}
        if len(repos) < 2:
            repos = {k: ws.repos[k] for k in named} | {k: v for k, v in list(ws.repos.items())[:3]}

    prompt = assist.impacts_prompt(repos, ws.root)
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    # "loop capped" and "about": the flag bounds the tool-use loop, not the
    # total charge, and the call in flight when it trips still bills — so a
    # promise of an exact ceiling here is one the cap cannot keep.
    print(f"asking Claude to read {len(repos)} repositories (read-only, loop capped at about ${args.budget})...")
    try:
        result, accounting = assist.ask(
            prompt, assist.IMPACTS_SCHEMA, ws.root, budget=args.budget, timeout=args.timeout, on_event=_watch
        )
    except assist.AssistError as exc:
        print(f"deck: {exc}")
        return 1

    edges = result.get("edges") or []
    couplings = result.get("couplings") or []
    path = assist.save(ws.root, "impacts", result, accounting, prompt)

    if not (edges or couplings):
        print("\n  Nothing proposed.")
    for edge in edges:
        print(f"\n  {edge['from']} -> {edge['to']}   [{edge['confidence']}]")
        print(f"    {edge['why']}")
    # Printed apart from the edges, and with both citations, because both
    # citations are what makes it a coupling rather than a pair the drafter
    # could not order. A reviewer reads them to decide whether it is one.
    for pair in couplings:
        print(f"\n  {pair['a']} <-> {pair['b']}   [{pair['confidence']}]   coupling: mutual, carries no order")
        print(f"    {pair['a']} -> {pair['b']}: {pair.get('why_a_to_b', '(no evidence given)')}")
        print(f"    {pair['b']} -> {pair['a']}: {pair.get('why_b_to_a', '(no evidence given)')}")
    for a, b in _mutual_pairs(edges):
        print(f"\n  {a} <-> {b}   proposed as two edges, one each way.")
        print("    Two `impacts:` edges between one pair is a cycle, so `apply` drafts this")
        print("    as a coupling instead. Read both directions above before you take it.")
    for note in result.get("unsure") or []:
        print(f"\n  unsure: {note}")
    _report(accounting, path)

    print("\n  Nothing was written to the descriptor. These are proposals, and a wrong")
    print("  edge serialises work that could have run in parallel.")
    if edges or couplings:
        print(f"  Review them, then: deck propose apply {path.name}")
    return 0


def cmd_propose_toggle(ws: Workspace, args) -> int:
    tg = Toggles(root=ws.root)
    prompt = assist.toggle_prompt(
        args.decision,
        list(tg.defs),
        list((tg.catalog.get("groups") or {}).keys()),
        [str(s) for s in (tg.catalog.get("stages") or [])],
    )
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    print(f"drafting a catalog entry (read-only, loop capped at about ${args.budget})...")
    try:
        result, accounting = assist.ask(
            prompt,
            assist.TOGGLE_SCHEMA,
            ws.root or Path.cwd(),
            budget=args.budget,
            timeout=args.timeout,
            on_event=_watch,
        )
    except assist.AssistError as exc:
        print(f"deck: {exc}")
        return 1

    import yaml as _yaml

    entry = _yaml.safe_dump([result], allow_unicode=True, sort_keys=False)
    print()
    print(entry)
    if ws.root:
        path = assist.save(ws.root, "toggle", result, accounting, prompt)
        _report(accounting, path)
    print("\n  Paste it into a pack's config/toggles.yaml, then check the wording:")
    print("    deck toggle validate --strict")
    return 0


def cmd_propose_pack(ws: Workspace, args) -> int:
    """Draft a pack for one repository, by reading it.

    The third and last thing deck asks a model for, and it is the same kind of
    thing as the other two: judgement about a codebase that a parser cannot
    produce. What commands does this project already run, what convention does
    it hold that no command checks, what choice did it make that could have gone
    the other way.

    It reads and proposes. It writes nothing into the pack — `apply` does that,
    separately, after a person has read the draft.
    """
    entry = ws.repo(args.repo)
    path = ws.repo_path(args.repo)
    if not path.is_dir():
        print(f"deck: {args.repo} is not on disk at {path}")
        return 1

    # The graph, not the registry. A drafter told about every repository in the
    # workspace reads every repository in the workspace; what makes reading a
    # sibling affordable is that `impacts:` and `couples:` already name the few
    # that could hold the answer. `--no-neighbours` is there because that cost is
    # still real on a dense graph, and because a run should be repeatable as it
    # was before this existed.
    neighbours: list[tuple[str, str, Path]] = []
    if not getattr(args, "no_neighbours", False):
        for name, why in ws.neighbours(args.repo):
            near = ws.repo_path(name)
            if near.is_dir():
                neighbours.append((name, why, near))

    # Before the permission check: showing what would be asked calls nothing and
    # costs nothing, and refusing it is how someone decides not to trust this.
    # Read straight from each pack rather than through `gate_lib.applicable`:
    # that resolver REFUSES a duplicate id, which is the very state this list
    # exists to keep the draft out of, so asking it would fail exactly when the
    # answer matters. The repository's own pack is excluded — a redraft is
    # allowed to restate its own gate.
    own = None
    for pack in ws.all_packs():
        if pack_name(pack) == args.repo:
            own = pack.resolve()
    taken = []
    for pack in ws.all_packs():
        if own is not None and pack.resolve() == own:
            continue
        for gate in (load_yaml(pack / "config" / "gates.yaml") or {}).get("gates") or []:
            gid = gate.get("id")
            if gid:
                taken.append(str(gid))
    prompt = assist.pack_prompt(args.repo, path, entry.get("role"), neighbours, sorted(set(taken)))
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    if neighbours:
        print(f"reading {args.repo}, and {len(neighbours)} repository(ies) the graph connects to it")
    try:
        proposal, accounting = assist.ask(
            prompt,
            assist.PACK_SCHEMA,
            path,
            budget=args.budget,
            timeout=args.timeout,
            also_read=[p for _, _, p in neighbours],
            on_event=_watch,
        )
    except assist.AssistError as exc:
        print(f"deck: {exc}")
        return 1

    proposal["repo"] = args.repo
    out = assist.save(ws.root, "pack", proposal, accounting, prompt)
    gates = proposal.get("gates") or []
    rules = proposal.get("rules") or []
    toggles = proposal.get("toggles") or []
    questions = proposal.get("questions") or []

    print(
        f"drafted for {args.repo}: {len(gates)} gate(s), {len(rules)} rule(s), "
        f"{len(proposal.get('skills') or [])} skill(s), {len(proposal.get('agents') or [])} agent(s), "
        f"{len(toggles)} toggle(s), {len(questions)} question(s)\n"
    )
    for gate in gates:
        print(f"  gate    {gate['id']:<16} [{gate['confidence']}] {gate['from_level']}: {gate['command']}")
        print(f"          {D}{gate['evidence']}{R}")
    for rule in rules:
        print(f"  rule    {rule['name']:<16} [{rule['confidence']}] {', '.join(rule['paths'])}")
        print(f"          {D}{rule['consequence']}{R}")
    for toggle in toggles:
        print(f"  toggle  {toggle['id']:<16} [{toggle['confidence']}] {'/'.join(toggle['values'])}")
        for value in toggle.get("values") or []:
            print(f"          {D}{value}: {(toggle.get('defends') or {}).get(value, '(not defended)')}{R}")
    for skill in proposal.get("skills") or []:
        print(f"  skill   {skill['name']:<16} [{skill['confidence']}] {len(skill['steps'])} step(s)")
        print(f"          {D}{skill['when_to_use']}{R}")
    for agent in proposal.get("agents") or []:
        print(f"  agent   {agent['name']:<16} [{agent['confidence']}] {agent['title']}")
        print(f"          {D}{agent['why']}{R}")
    for question in questions:
        print(f"  question {question['question']}")
        print(f"          {D}{question.get('context', '')}{R}")
    for item in proposal.get("unsure") or []:
        print(f"  {D}unsure  {item}{R}")
    # Printed whatever was decided, and always. An empty array beside nothing
    # cannot be told apart from a question nobody asked, and that ambiguity is
    # what put skills and agents in this schema in the first place.
    for label, note in (("skills", proposal.get("skills_note")), ("agents", proposal.get("agents_note"))):
        if note:
            print(f"  {D}no {label}: {note}{R}" if not (proposal.get(label) or []) else f"  {D}{label}: {note}{R}")
    if not (gates or rules or toggles or questions):
        print("  Nothing proposed. That is a valid answer: a repository whose conventions")
        print("  are already enforced does not need a pack to repeat them.")

    _report(accounting, out)
    if questions:
        print(f"\n  {len(questions)} question(s) the draft could not answer. Applying records each as a")
        print("  consultation, so it waits for a person instead of being filed as a decision.")
    print(f"\n  Read it, then:  deck propose apply {out.name} --into <pack dir> --confidence high")
    return 0


def cmd_propose_apply(ws: Workspace, args) -> int:
    """Fold a reviewed proposal into the descriptor or a pack."""
    path = Path(args.file)
    if not path.is_absolute():
        path = assist.proposals_dir(ws.root) / path
    if not path.is_file():
        print(f"deck: no proposal at {path}")
        return 1
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("kind") == "pack":
        return _apply_pack(ws, payload, args)
    if payload.get("kind") == "lessons":
        # Reshaped into a pack proposal and handed to the same writer. A lesson
        # about a repository IS a rule, a gate or a skill about it — the only
        # difference is where it was read from, and that belongs in the
        # evidence, not in a second code path that would drift from this one.
        lessons = payload.get("proposal", {}).get("lessons") or []
        session = payload.get("proposal", {}).get("session", "a session")
        recast: dict = {"repo": session, "gates": [], "rules": [], "toggles": [], "skills": [], "agents": []}
        diary = []
        for lesson in lessons:
            learned = f"learned in session {session}: {lesson['evidence']}"
            if lesson["kind"] == "rule":
                # A rule that cannot say which files it is about is a diary
                # entry, and defaulting it to `**/*` was the worst way to take
                # one: it loads on every file read, forever, for a lesson
                # nobody could scope. What makes a lesson admissible is that it
                # names what would have caught it — a gate names a command, a
                # rule names its `paths:`. Naming neither is not a small gap in
                # a lesson, it is the lesson not being one.
                if not lesson.get("paths"):
                    diary.append(lesson)
                    continue
                recast["rules"].append(
                    {
                        "name": lesson["name"],
                        "paths": lesson["paths"],
                        "consequence": lesson["text"],
                        "evidence": learned,
                        "confidence": lesson["confidence"],
                    }
                )
            elif lesson["kind"] == "gate":
                # For a gate, `text` is the command. A lesson that describes a
                # check instead of writing one has not named what would have
                # caught it, which is the whole test for admitting a lesson —
                # the same bar the `paths:` rule above applies to a rule. A
                # sentence written into `per_repo:` becomes a gate that fails
                # every run with a shell error, which is worse than the lesson
                # never landing.
                command = str(lesson["text"]).strip()
                if "\n" in command or command.endswith("."):
                    diary.append(lesson)
                    continue
                recast["gates"].append(
                    {
                        "id": title_slug(lesson["name"]),
                        "title": lesson["name"],
                        "from_level": "static",
                        "command": lesson["text"],
                        "evidence": learned,
                        "confidence": lesson["confidence"],
                    }
                )
            elif lesson["kind"] == "skill":
                recast["skills"].append(
                    {
                        "name": lesson["name"],
                        "title": lesson["name"],
                        "when_to_use": lesson["text"][:200],
                        "steps": [{"do": lesson["text"], "evidence": learned}],
                        "confidence": lesson["confidence"],
                    }
                )
            else:
                # A toggle is a question somebody will be asked, and which pack
                # asks it is a decision. `propose toggle` drafts one properly;
                # a lesson that is one gets named and left for that.
                print(f"  toggle `{lesson['name']}` not written — draft it with:")
                print(f'    deck propose toggle "{lesson["text"][:80]}"')
        for lesson in diary:
            if lesson["kind"] == "gate":
                print(f"  `{lesson['name']}` not written — a gate's text has to BE the command,")
                print("    a line you could paste into a shell. This one reads as a description,")
                print("    and a sentence in `per_repo:` is a gate that fails every run.")
                continue
            print(f"  `{lesson['name']}` not written — a rule with no `paths:` applies to everything,")
            print("    and a lesson that cannot name the files it is about has not said what")
            print("    would have caught it. Add `paths:` to the proposal, or let it go.")
        if not any(recast[k] for k in ("gates", "rules", "skills")):
            print("nothing to write: every lesson here is a toggle, a rule with no `paths:`,")
            print("  or below the confidence floor")
            return 0
        return _apply_pack(ws, {"proposal": recast}, args)
    if payload.get("kind") != "impacts":
        kind = payload.get("kind")
        if kind == "toggle":
            # Refused on purpose, and the reason is worth printing. A catalog
            # entry is a question somebody will be asked; which pack owns it,
            # and whether the wording survives being read cold, are decisions
            # a draft does not get to make. The message used to stop at
            # "cannot be applied", which reads as a defect rather than a
            # boundary and points nowhere.
            print("deck: a `toggle` proposal is not applied — a person places it.\n")
            print("  A toggle is a question your team will be asked, so which pack owns")
            print("  it is a decision, and so is whether the wording still makes sense")
            print("  to somebody reading it cold in six months.\n")
            print(f"  The draft is in {path}, under `proposal`.")
            print("  Paste it under `toggles:` in the pack that should ask it, then:")
            print("    deck toggle validate --strict")
            return 1
        print(f"deck: `{kind}` proposals cannot be applied")
        return 1
    return _apply_impacts(ws, payload, args)


def _mutual_pairs(edges: list[dict]) -> list[tuple[str, str]]:
    """Pairs a proposal names in both directions, each pair once, sorted.

    Written by hand, two `impacts:` edges between one pair stay a cycle: someone
    can type that, `doctor` refuses it, and `deck order` needs it refused. A
    DRAFT means something else by it. The drafter found evidence in both
    directions, had one field to put it in, and used it twice — which is exactly
    the finding `couples:` exists to record, and exactly what happened on the
    workspace that motivated the field, where one of the two directions was
    discarded to keep the graph acyclic and survived only as prose.

    So the fold happens here, on the draft, before anything is written. It never
    touches what is already in the descriptor.
    """
    seen = {(edge.get("from"), edge.get("to")) for edge in edges}
    pairs = {tuple(sorted((a, b))) for a, b in seen if a and b and a != b and (b, a) in seen}
    return sorted(pairs)  # type: ignore[arg-type]


def _fold(wanted: list[dict], couplings: list[dict]) -> tuple[list[dict], list[dict]]:
    """Move every both-ways pair out of the edges and into the couplings."""
    pairs = _mutual_pairs(wanted)
    if not pairs:
        return wanted, couplings
    why = {(e.get("from"), e.get("to")): e.get("why", "") for e in wanted}
    already = {tuple(sorted((c.get("a"), c.get("b")))) for c in couplings}
    folded = list(couplings)
    for a, b in pairs:
        if (a, b) not in already:
            folded.append(
                {
                    "a": a,
                    "b": b,
                    "why_a_to_b": why.get((a, b), ""),
                    "why_b_to_a": why.get((b, a), ""),
                    "from_edges": True,
                }
            )
    kept = [e for e in wanted if tuple(sorted((e.get("from"), e.get("to")))) not in set(pairs)]
    return kept, folded


def _session_digest(path: Path, limit: int = 120000) -> str:
    """The readable half of a transcript, oldest first, trimmed to `limit`.

    Raw JSONL would be mostly tool payloads and base64, and paying for those
    buys nothing: what a session TAUGHT is in what was said about what failed.
    So this keeps prose — the person's messages and the assistant's — and the
    first line of each tool result, which is where an error announces itself.

    Trimmed from the FRONT when it does not fit. A lesson is usually learned
    late: the third attempt is the one that worked, and the reason it worked is
    the last thing said about it.
    """
    kept: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        kind = row.get("type")
        if kind not in ("user", "assistant"):
            continue
        message = row.get("message") or {}
        content = message.get("content")
        if isinstance(content, str):
            body = content
        elif isinstance(content, list):
            parts = []
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    parts.append(str(block.get("text", "")))
                elif block.get("type") == "tool_result":
                    inner = block.get("content")
                    text = inner if isinstance(inner, str) else json.dumps(inner)[:400]
                    first = str(text).strip().splitlines()[:1]
                    if first:
                        parts.append(f"[tool result] {first[0][:300]}")
            body = "\n".join(parts)
        else:
            continue
        body = body.strip()
        if body:
            kept.append(f"{kind}: {body[:2000]}")
    digest = "\n\n".join(kept)
    return digest[-limit:] if len(digest) > limit else digest


def cmd_propose_lessons(ws: Workspace, args) -> int:
    """What this session taught, sorted into the kinds a pack holds.

    The other `propose` commands read a repository — a thing that sits still.
    This one reads a session, which is the only place a wrong assumption and
    the three attempts it cost are written down. Nothing is written to a pack:
    it produces a proposal, the way the others do, and `deck propose apply`
    puts it somewhere after a person has read it.
    """
    if not ws.root:
        return die("workspace not resolved")
    wanted = getattr(args, "session", None)
    # `anywhere=True`: a named session is a statement, and the session that
    # worked this workspace may well have run from another directory.
    paths = cost_lib.transcripts(wanted, ws.root, anywhere=True)
    if not paths:
        if wanted:
            print(f"deck: no transcript anywhere is named {wanted}")
            print("  Checked every project directory, not only this workspace's.")
        else:
            print("deck: no session of this workspace has a transcript yet")
            print("  A lesson is read out of a session; there is none to read.")
        # The way through, with the ids: a session that works this workspace
        # from OUTSIDE it — an agent running in a tools checkout, a session
        # opened in the collection — writes its transcript under its own
        # directory, and `--session` is how you say which. That is not
        # guessable, so the ids are printed rather than described.
        others = [p for p in cost_lib.transcripts(None, None) if p.stem != wanted][:5]
        if others:
            print("\n  A session that worked on this workspace from another directory is")
            print("  not in scope. Name it:")
            for path in others:
                print(f"    deck propose lessons --session {path.stem}   {D}({path.parent.name}){R}")
        return 1
    transcript = paths[0]
    digest = _session_digest(transcript)
    if not digest.strip():
        print(f"deck: {transcript.name} holds no readable exchange")
        return 1

    packs = [pack_name(p) for p in ws.all_packs()]
    prompt = assist.lessons_prompt(sorted(ws.repos), packs, digest)
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    print(f"reading {transcript.name} · {len(digest)} characters of exchange")
    try:
        proposal, accounting = assist.ask(
            prompt, assist.LESSONS_SCHEMA, ws.root, budget=args.budget, timeout=args.timeout, on_event=_watch
        )
    except assist.AssistError as exc:
        print(f"deck: {exc}")
        return 1

    proposal["session"] = transcript.stem
    out = assist.save(ws.root, "lessons", proposal, accounting, prompt)
    lessons = proposal.get("lessons") or []
    print(f"\nfrom {transcript.stem}: {len(lessons)} lesson(s)\n")
    for lesson in lessons:
        print(f"  {lesson['kind']:<7} {lesson['name']:<24} [{lesson['confidence']}]")
        print(f"          {D}{lesson['text']}{R}")
        print(f"          {D}learned: {lesson['evidence']}{R}")
    for item in proposal.get("unsure") or []:
        print(f"  {D}unsure  {item}{R}")
    note = proposal.get("nothing_because")
    if note and not lessons:
        print(f"  {D}nothing: {note}{R}")
        print("\n  That is the ordinary answer. Most sessions teach nothing general.")
    _report(accounting, out)
    if lessons:
        print("\n  Nothing was written. A lesson nobody agreed with is one more thing")
        print("  every agent reads forever, so this waits for you:")
        print(f"    deck propose apply {out.name} --into <pack dir>")
    return 0


def _apply_impacts(ws: Workspace, payload: dict, args) -> int:
    """Fold a reviewed impacts proposal into the descriptor.

    Two kinds of edge land here. `impacts:` is appended to the impacting side;
    `couples:` is written to one side only, because it is symmetric and one side
    is enough — writing both would say the same thing twice in a file a person
    has to read.
    """
    proposal = payload.get("proposal", {})
    edges = proposal.get("edges") or []
    # A proposal drafted before `couplings` existed has no such key, and applies
    # exactly as it did — except for a pair it named both ways, which used to be
    # refused as a cycle and is now the coupling it always was.
    couplings = proposal.get("couplings") or []
    rank = {"high": 3, "medium": 2, "low": 1}
    floor = rank.get(args.confidence, 2)
    wanted = [e for e in edges if rank.get(e.get("confidence"), 0) >= floor]
    wanted_couplings = [c for c in couplings if rank.get(c.get("confidence"), 0) >= floor]
    skipped = (len(edges) - len(wanted)) + (len(couplings) - len(wanted_couplings))
    # After the confidence filter, not before: the floor is the reviewer's
    # control over what the draft asserts, and a reverse edge it excludes was
    # never asserted, so there is no pair to fold.
    wanted, wanted_couplings = _fold(wanted, wanted_couplings)

    # The RESOLVED descriptor, not a path built from the root. A workspace set
    # up with a collection keeps it in `_workspaces/<name>/<scope>/`, and
    # reading `<root>/.deck/workspace.yaml` there found nothing: `load_yaml`
    # answers `{}` for a file that is not there, so every repository was
    # unknown, every edge was skipped, and apply reported "nothing to add" over
    # a proposal it had understood perfectly. A silent no-op that reads as
    # success is the worst shape this could have taken.
    descriptor = ws.descriptor
    if not descriptor or not descriptor.is_file():
        die("no descriptor resolved — nothing to apply into. See: deck doctor")
    data = load_yaml(descriptor)
    repos = data.get("repos") or {}
    added: list[str] = []
    for edge in wanted:
        entry = repos.get(edge["from"])
        if entry is None or edge["to"] not in repos:
            continue
        impacts = entry.setdefault("impacts", [])
        if edge["to"] not in impacts:
            impacts.append(edge["to"])
            added.append(f"{edge['from']} -> {edge['to']}")

    contradicted: list[tuple[str, str]] = []
    for pair in wanted_couplings:
        a, b = pair.get("a"), pair.get("b")
        if a == b or a not in repos or b not in repos:
            continue
        if b in (repos[a].get("impacts") or []) or a in (repos[b].get("impacts") or []):
            contradicted.append((a, b))
            continue
        if b in (repos[a].get("couples") or []) or a in (repos[b].get("couples") or []):
            continue
        # Registry order, so the descriptor reads back in the order it was
        # written. One side only: `coupled()` reads both directions.
        order = list(repos)
        first, second = (a, b) if order.index(a) <= order.index(b) else (b, a)
        repos[first].setdefault("couples", []).append(second)
        # A folded pair says so. The draft asked for two ordered edges and is
        # getting one unordered coupling, and a reviewer who is not told that
        # would go looking for the edges in the descriptor.
        how = " — folded from the two edges the draft named" if pair.get("from_edges") else ""
        added.append(f"{first} <-> {second}   coupling: mutual, carries no order{how}")

    if contradicted:
        # One pair, two edges disagreeing about it: `doctor` refuses that
        # descriptor, so deck must not write one. It also will not rank the two
        # — the declared edge was written by a person and the coupling by a
        # draft, and picking either is a guess about which is right.
        print("REFUSED: this proposal calls a pair a coupling that the descriptor already orders.\n")
        for a, b in contradicted:
            print(f"  {a} <-> {b} is proposed as a coupling, and `impacts:` already puts one of them first.")
        print("\n  A pair is ordered or it is not. If neither of them comes first, drop the")
        print("  `impacts:` entry between them and apply again; if one does, drop the")
        print("  coupling from the proposal. Nothing was written.")
        return 1

    if not added:
        print("nothing to add — every proposed edge and coupling is already in the descriptor")
        return 0
    n_edges = sum(1 for line in added if " -> " in line)
    counted = [f"{n} {word}" for n, word in ((n_edges, "edge(s)"), (len(added) - n_edges, "coupling(s)")) if n]
    print(f"would add {' and '.join(counted)} to {descriptor}:")
    for line in added:
        print(f"  + {line}")
    if skipped:
        print(f"  ({skipped} below `{args.confidence}` confidence left out; --confidence lowers the bar)")
    # An edge that closes a cycle makes the execution order uncomputable, and a
    # proposal is exactly where one sneaks in: two repositories that genuinely
    # depend on each other both look like real edges in isolation. A pair the
    # draft named both ways is already a coupling by here, and a coupling is
    # unreachable from `cycles()` — so what is left is a real cycle.
    probe = Workspace(ws.root)
    probe.data = data
    cycles = probe.cycles()
    if cycles:
        print(f"\n  REFUSED: this would create a cycle through {', '.join(cycles)}.")
        for a, b in probe.mutual_impacts():
            print(f"  {a} and {b} would impact each other, and one of those edges is already in the")
            print("  descriptor. If neither of them comes first that is a coupling: drop the")
            print(f"  `impacts:` entry and put `couples: [{b}]` under `{a}`.")
        print("  Execution order stops being computable, so pick the direction that")
        print("  actually forces the other and leave the reverse out — usually the")
        print("  mechanical one (an import, a package dependency) over the feature one.")
        return 1

    if not args.yes:
        print("\n  Nothing written. Re-run with --yes.")
        return 0

    dump_yaml(descriptor, data)
    print(f"\n  {descriptor} updated. Check it: deck doctor")
    return 0


_STOPWORDS = frozenset(
    "a an the and or of for to in on at is it its this that these those how what which when where why "
    "be are was were do does not no with without from by as".split()
)


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", norm(text).lower()) if len(w) > 2 and w not in _STOPWORDS}


def _echoes(toggle: dict, text: str) -> bool:
    """Is this toggle the same finding as that note?

    Word overlap, deliberately narrow: every content word of the toggle's id, or
    every content word of its title, has to be in the note. A drafter that files
    one finding twice names it the same way both times, and anything looser
    would refuse an honest draft for sharing a word like `error`.

    It can still fire on a draft that meant no harm — a note saying the drafter
    could not read the api_compat tests names the same words as the api_compat
    toggle. That refusal costs one edit and is read by a person who has the
    draft open; a question quietly filed as a decision costs the doubt itself,
    and nobody reads that at all.
    """
    haystack = _tokens(text)
    for source in (toggle.get("id") or "", toggle.get("title") or ""):
        words = _tokens(str(source))
        if len(words) >= 2 and words <= haystack:
            return True
    return False


def _pack_refusals(proposal: dict) -> list[str]:
    """Every reason this draft confuses a decision with a question.

    A toggle is a choice whose values each defend themselves; a question is an
    inconsistency nobody has explained yet. The difference is not stylistic. A
    question filed as a toggle turns "we do not know" into "we chose" and the
    doubt is gone at the moment it was worth keeping, which is what happened to
    two code paths returning different status codes for the same refusal.

    So the check is structural rather than a reading of the prose: a finding
    nobody understands cannot produce a line of defence for each value, and
    cannot honestly appear in `toggles` and in `questions`/`unsure` at once.
    Whether a defence that IS written is any good stays with the reviewer —
    deck does not grade sentences.
    """
    out: list[str] = []
    notes = [str(n) for n in (proposal.get("unsure") or [])]
    notes += [f"{q.get('question', '')} {q.get('context', '')}" for q in proposal.get("questions") or []]

    for toggle in proposal.get("toggles") or []:
        ident = toggle.get("id") or toggle.get("title") or "(unnamed)"
        values = list(dict.fromkeys(str(v) for v in (toggle.get("values") or []) if str(v).strip()))
        if len(values) < 2:
            out.append(f"toggle `{ident}` names {len(values)} value(s); a decision has at least two.")
            continue
        defends = toggle.get("defends")
        if not isinstance(defends, dict):
            out.append(f"toggle `{ident}` has no `defends` block, so not one of its values is defended.")
        else:
            bare = [v for v in values if not str(defends.get(v, "")).strip()]
            if bare:
                named = ", ".join(f"`{v}`" for v in bare)
                out.append(f"toggle `{ident}` does not say what defends {named}.")
        for note in notes:
            if _echoes(toggle, note):
                out.append(
                    f'toggle `{ident}` is also filed as something the draft could not explain: "{note.strip()[:80]}"'
                )
                break
    return out


def _refuse(refusals: list[str]) -> int:
    print("REFUSED: this draft files a question as a decision.\n")
    for line in refusals:
        print(f"  {line}")
    print("\n  A toggle is a choice where every value defends itself, one line per value")
    print("  in `defends`. A finding you cannot defend from both sides is a question:")
    print("  move it into the draft's `questions` list and `apply` records it as a")
    print('  consultation, where "we do not know" survives until someone answers it.')
    print("\n  Nothing was written. A draft made before `defends` existed carries no such")
    print("  block and will say this until each value has one, or the toggle is removed;")
    print("  its gates and rules are unaffected and land on the next run.")
    return 1


def _apply_pack(ws: Workspace, payload: dict, args) -> int:
    """Fold a reviewed pack proposal into a pack directory.

    Appending, never replacing. Whatever is already in the pack was written by a
    person and reviewed; a draft does not get to overwrite that.

    It refuses the whole draft when a toggle in it is not a decision. Toggles
    are not written into the pack here — a catalog entry needs wording a person
    will answer — so refusing looks pedantic until you notice what happens
    otherwise: the gates and the rules land, the malformed toggle is silently
    dropped, and the person who applies it files it by hand from the printed
    draft. Refusing is the only moment deck can stop that, and a draft that
    cannot tell a question from a decision is not one to trust by halves.
    """
    if not args.into:
        print("deck: a pack proposal needs --into <pack dir>")
        print("  It writes gates, rules and toggles into a pack, so it has to be told which.")
        return 1
    pack = Path(args.into).expanduser().resolve()
    if not (pack / "config").is_dir():
        print(f"deck: {pack} is not a pack (no config/ directory) — create it with `deck pack new`")
        return 1

    rank = {"high": 3, "medium": 2, "low": 1}
    floor = rank.get(args.confidence, 2)
    proposal = payload.get("proposal", {})
    refusals = _pack_refusals(proposal)
    if refusals:
        return _refuse(refusals)
    written = []

    # Questions first, and unfiltered by --confidence: a confidence floor is for
    # a finding the draft is asserting, and a question asserts nothing. The one
    # thing it must not do is arrive twice when a draft is applied into a second
    # pack, so an identical question already on file is left alone.
    asked = {norm(e.get("question", "")) for e in consult.load_all(ws.root, ws.all_packs())}
    for question in proposal.get("questions") or []:
        text = str(question.get("question") or "").strip()
        if not text or norm(text) in asked:
            continue
        context = "\n".join(
            part
            for part in (
                str(question.get("context") or "").strip(),
                f"evidence: {question['evidence']}" if question.get("evidence") else "",
                f"found by `deck propose pack {proposal.get('repo', '?')}`, which could not explain it.",
            )
            if part
        )
        entry = consult.record(ws.root, text, None, context, [str(o) for o in (question.get("options") or [])])
        asked.add(norm(text))
        written.append(f"consultation {entry['id']} — {text}")

    gates = [g for g in (proposal.get("gates") or []) if rank.get(g.get("confidence"), 0) >= floor]
    if gates:
        target = pack / "config" / "gates.yaml"
        existing = load_yaml(target)
        have = {g.get("id") for g in (existing.get("gates") or [])}
        fresh = [g for g in gates if g["id"] not in have]
        if fresh:
            lines = [f"\n# Drafted by `deck propose pack` from {payload.get('proposal', {}).get('repo', '?')}."]
            lines.append("# Read every command before trusting it.")
            for gate in fresh:
                lines.append(f"  - id: {gate['id']}")
                lines.append(f"    title: {gate['title']}")
                lines.append(f"    from_level: {gate['from_level']}")
                lines.append(f"    per_repo: {json.dumps(gate['command'])}")
                lines.append(f"    # evidence: {gate['evidence']}")
            body = target.read_text(encoding="utf-8") if target.is_file() else "gates:\n"
            # Appended as text, so the comments a person wrote survive — but the
            # key has to be one an item can attach to. A file carrying
            # `gates: []` took the append and stopped parsing, and the failure
            # surfaced later at `deck gate list`, in a different command, about
            # a file this one had written. An empty inline list means the same
            # thing as an empty block, so it is rewritten rather than refused.
            body = re.sub(r"^gates:[ \t]*\[[ \t]*\][ \t]*$", "gates:", body, count=1, flags=re.MULTILINE)
            candidate = body.rstrip() + "\n" + "\n".join(lines) + "\n"
            try:
                yaml.safe_load(candidate)
            except yaml.YAMLError as exc:
                # Refused, not written. A pack whose gates.yaml does not parse
                # takes the whole ladder down, and finding that out from an
                # unrelated command later is the worst way to learn it.
                print(f"REFUSED: appending to {target} would not parse.\n")
                print(f"  {str(exc).splitlines()[0]}")
                print("\n  Nothing was written. Check the file's `gates:` key, then apply again.")
                return 1
            target.write_text(candidate, encoding="utf-8")
            written.append(f"{len(fresh)} gate(s) -> config/gates.yaml")

    rules = [r for r in (proposal.get("rules") or []) if rank.get(r.get("confidence"), 0) >= floor]
    placed: list[str] = []
    for rule in rules:
        name = title_slug(rule["name"])
        target = pack / "rules" / f"{name}.md"
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        patterns = ", ".join(json.dumps(p) for p in rule["paths"])
        target.write_text(
            f"---\npaths: [{patterns}]\n---\n\n{rule['consequence'].strip()}\n\n"
            f"<!-- drafted by `deck propose pack`; evidence: {rule['evidence']} -->\n",
            encoding="utf-8",
        )
        placed.append(f"rules/{name}.md")

    # The answer "nothing here needs one" is written into the pack, not only
    # printed: the next person to open this directory sees that the question was
    # asked and what it was answered with, instead of an empty folder.
    for label, note in (("skills", proposal.get("skills_note")), ("agents", proposal.get("agents_note"))):
        if not note or (proposal.get(label) or []):
            continue
        target = pack / label / "NONE.md"
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        # `.md` outside `skills/<name>/SKILL.md` is not a skill to `mount`, and a
        # file at `agents/NONE.md` would be — so it says what it is on line one.
        target.write_text(
            f"# No {label[:-1]} was proposed for `{proposal.get('repo', '?')}`\n\n"
            f"{note.strip()}\n\n"
            "Drafted by `deck propose pack`. Delete this file when you write a real one.\n",
            encoding="utf-8",
        )
        placed.append(f"{label}/NONE.md")

    # A skill is a directory, because that is the shape Claude Code loads:
    # `skills/<name>/SKILL.md`. Never overwritten — a skill somebody reviewed
    # and edited is exactly what a draft must not replace.
    for skill in [s for s in (proposal.get("skills") or []) if rank.get(s.get("confidence"), 0) >= floor]:
        name = title_slug(skill["name"])
        target = pack / "skills" / name / "SKILL.md"
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        steps = "\n\n".join(
            f"{i}. {s['do'].strip()}\n\n   <!-- {s['evidence']} -->" for i, s in enumerate(skill["steps"], 1)
        )
        pitfall = (
            f"\n## What breaks when a step is skipped\n\n{skill['pitfall'].strip()}\n" if skill.get("pitfall") else ""
        )
        target.write_text(
            "---\n"
            f"name: {name}\n"
            f"description: >\n  {skill['title'].strip()}\n"
            f"when_to_use: >\n  {skill['when_to_use'].strip()}\n"
            "user-invocable: true\n"
            "---\n\n"
            f"# {skill['title'].strip()}\n\n"
            "> Drafted by `deck propose pack` and **not yet followed by anybody**. A\n"
            "> procedure that is wrong does not get argued with, it gets executed —\n"
            "> walk it once against this repository before trusting it, and delete the\n"
            "> steps that turn out to be invented. Each step carries the file it was\n"
            "> read from.\n\n"
            f"{steps}\n{pitfall}",
            encoding="utf-8",
        )
        placed.append(f"skills/{name}/SKILL.md")

    # An agent is one file, and it says the default posture is wrong here.
    for agent in [a for a in (proposal.get("agents") or []) if rank.get(a.get("confidence"), 0) >= floor]:
        name = title_slug(agent["name"])
        target = pack / "agents" / f"{name}.md"
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            "---\n"
            f"name: {name}\n"
            f"description: >\n  {agent['description'].strip()}\n"
            "---\n\n"
            f"# {agent['title'].strip()}\n\n"
            "> Drafted by `deck propose pack`. An agent is a claim that the default\n"
            "> posture is wrong for this repository — read the reason below and keep\n"
            "> it only if you agree with it.\n\n"
            f"{agent['why'].strip()}\n",
            encoding="utf-8",
        )
        placed.append(f"agents/{name}.md")

    # The file is half of a rule; `mount.yaml` naming it is the other half, and
    written += placed

    if not written:
        print(f"nothing at confidence `{args.confidence}` or above, or it is all already there")
        return 0
    print("wrote:")
    for item in written:
        print(f"  {item}")
    print("\n  Read what landed. A draft is a starting point, and a gate you have not")
    print("  run is a gate you do not have. Toggles were NOT written: a catalog entry")
    print("  needs wording a person will answer, which `deck propose toggle` drafts one")
    print("  at a time and `deck toggle validate --strict` then checks.")
    if any(item.startswith("consultation ") for item in written):
        print("\n  A consultation is open, not decided. Answer it, and it stays answered:")
        print("    deck ask list")
    return 0
