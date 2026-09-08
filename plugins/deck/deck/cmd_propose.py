"""Propose commands: ask Claude for the two inputs a parser cannot produce."""

from __future__ import annotations

import json
import re
from pathlib import Path

from . import assist, consult, mount
from .config import dump_yaml, load_yaml, norm, title_slug
from .toggles import Toggles
from .workspace import Workspace

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


def _report(accounting: dict, path: Path) -> None:
    usd = accounting.get("usd")
    print(f"\n  proposal: {path}")
    print(
        f"  cost: {'$%.4f' % usd if usd is not None else 'unknown'} · "
        f"{accounting['input']} in / {accounting['output']} out · {accounting['seconds']}s"
    )
    if accounting.get("denials"):
        print(f"  {accounting['denials']} tool call(s) were denied — the run is read-only by construction")


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

    print(f"asking Claude to read {len(repos)} repositories (read-only, capped at ${args.budget})...")
    try:
        result, accounting = assist.ask(prompt, assist.IMPACTS_SCHEMA, ws.root, budget=args.budget)
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
    prompt = assist.toggle_prompt(args.decision, list(tg.defs))
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    print(f"drafting a catalog entry (read-only, capped at ${args.budget})...")
    try:
        result, accounting = assist.ask(prompt, assist.TOGGLE_SCHEMA, ws.root or Path.cwd(), budget=args.budget)
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
    prompt = assist.pack_prompt(args.repo, path, entry.get("role"), neighbours)
    if args.show_prompt:
        print(prompt)
        return 0
    if not _permitted(ws, args):
        return 1

    if neighbours:
        print(f"reading {args.repo}, and {len(neighbours)} repository(ies) the graph connects to it")
    try:
        proposal, accounting = assist.ask(
            prompt, assist.PACK_SCHEMA, path, budget=args.budget, also_read=[p for _, _, p in neighbours]
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
    for question in questions:
        print(f"  question {question['question']}")
        print(f"          {D}{question.get('context', '')}{R}")
    for item in proposal.get("unsure") or []:
        print(f"  {D}unsure  {item}{R}")
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
    if payload.get("kind") != "impacts":
        print(f"deck: `{payload.get('kind')}` proposals cannot be applied")
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

    descriptor = ws.root / ".deck" / "workspace.yaml"
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
            target.write_text(body.rstrip() + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
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

    # The file is half of a rule; `mount.yaml` naming it is the other half, and
    # a rule that has only the first reaches nobody. Writing the file and
    # leaving the entry to a person is the same trap this command already
    # refuses for a malformed toggle: the report reads like delivery, and the
    # step nobody sees is the one that never happens.
    recorded = set(mount.record_rules(pack, placed))
    for item in placed:
        written.append(item if item in recorded else f"{item}   (already in mount.yaml)")
    if recorded:
        written.append(f"{len(recorded)} rule(s) -> config/mount.yaml")

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
