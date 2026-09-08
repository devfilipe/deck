"""`deck ask` — the escalation an agent has when the catalog has no entry."""

from __future__ import annotations

import json
from pathlib import Path

from . import consult, mount
from .config import load_yaml, norm, title_slug
from .workspace import Workspace

B, D, R = "\033[1m", "\033[2m", "\033[0m"


def cmd_ask_new(ws: Workspace, args) -> int:
    options = [o.strip() for o in (args.options or "").split(",") if o.strip()]
    entry = consult.record(ws.root, args.question, args.task, args.context, options)
    if args.json:
        print(json.dumps(entry, ensure_ascii=False, indent=2))
        return 0
    print(f"recorded {entry['id']}")
    print(f"  {entry['question']}")
    print("\n  It is written down and will outlive this session. Answer it with:")
    print(f'    deck ask resolve {entry["id"]} "<the answer>"')
    print("\n  Nothing waits on it. Say in your report what you did in the meantime,")
    print("  and what would change if the answer goes the other way.")
    return 0


def _where(entry: dict) -> str:
    """Which store a consultation came from, when it is not this machine's.

    A published question is one a colleague can answer and one they may already
    have. Printing nothing for it would leave a reader unable to tell a doubt
    the team is carrying from one only they can see.
    """
    origin = entry.get("_origin", "local")
    return "" if origin == "local" else f"  ({origin})"


def cmd_ask_list(ws: Workspace, args) -> int:
    entries = consult.load_all(ws.root, ws.all_packs())
    if args.resolved:
        entries = [e for e in entries if e["status"] == consult.RESOLVED]
    elif not args.all:
        entries = [e for e in entries if e["status"] == consult.OPEN]

    if args.json:
        print(json.dumps(entries, ensure_ascii=False, indent=2))
        return 0
    if not entries:
        print("nothing to consult on" if not args.resolved else "nothing answered yet")
        return 0

    for entry in entries:
        mark = " " if entry["status"] == consult.OPEN else "x"
        task = f"[{entry['task']}] " if entry.get("task") else ""
        print(f"  [{mark}] {entry['id']}{_where(entry)}")
        print(f"      {task}{entry['question']}")
        if entry.get("options"):
            print(f"      {D}options: {', '.join(entry['options'])}{R}")
        if entry.get("answer"):
            print(f"      {B}answer:{R} {entry['answer']}")
    if any(e["status"] == consult.OPEN for e in entries):
        print('\n  deck ask resolve <id> "<the answer>"')
    if any(e.get("_origin", "local") == "local" for e in entries):
        print("  deck ask publish <id> --into <pack>   so a colleague can answer it")
    return 0


def cmd_ask_show(ws: Workspace, args) -> int:
    entry = consult.find(ws.root, args.id, ws.all_packs())
    if entry is None:
        print(f"deck: no consultation {args.id}")
        return 1
    if args.json:
        print(json.dumps(entry, ensure_ascii=False, indent=2))
        return 0
    origin = entry.get("_origin", "local")
    seen_by = "this machine only" if origin == "local" else f"published in the `{origin}` pack"
    print(f"{entry['id']}  ({entry['status']}, {seen_by})\n")
    print(f"  {entry['question']}\n")
    if entry.get("task"):
        print(f"  task      {entry['task']}")
    print(f"  asked     {entry['asked_at']} by {entry.get('asked_by') or '?'} in {entry.get('asked_in')}")
    if entry.get("context"):
        print(f"\n  context\n    {entry['context']}")
    if entry.get("options"):
        print(f"\n  options   {', '.join(entry['options'])}")
    if entry.get("answer"):
        print(f"\n  {B}answer{R}    {entry['answer']}")
        print(f"  answered  {entry['answered_at']} by {entry.get('answered_by') or '?'}")
        where = consult.folded(entry)
        if where:
            # What it became beats a guess about what it might become. The guess
            # is for an answer nobody has written down yet; once one has, saying
            # it "probably wants to become a toggle" sends a reader to write a
            # second artifact that will disagree with the first.
            print("\n  written down as:")
            for item in where:
                print(f"    {item['kind']:<7} {item['pack']}  {item['file']}")
        else:
            print(f"\n  probably wants to become: {consult.looks_like(entry)}")
            print(f"  {D}deck ask fold {entry['id']} --as <kind> --into <pack>{R}")
    return 0


def cmd_ask_resolve(ws: Workspace, args) -> int:
    entry = consult.resolve(ws.root, args.id, args.answer, getattr(args, "who", None), ws.all_packs())
    if entry is None:
        print(f"deck: no consultation {args.id}")
        return 1
    print(f"answered {entry['id']}")
    print(f"  {entry['question']}")
    print(f"  -> {entry['answer']}")
    print(f"\n  {B}This answer is a transcript until someone writes it down.{R}")
    print(f"  It probably wants to become: {consult.looks_like(entry)}")
    print(f"\n  Fold it:   deck ask fold {entry['id']} --as <rule|toggle|gate> --into <pack>")
    print('  Or draft:  deck propose toggle "<the decision, in one line>" --yes')
    print("  Until then the next run has to ask again.")
    return 0


def _pairs(raw: list[str] | None, flag: str) -> tuple[dict, str | None]:
    """`value=text` arguments, or the first one that is not shaped like that."""
    out: dict[str, str] = {}
    for item in raw or []:
        if "=" not in item:
            return out, f"{flag} takes `<value>=<text>`, and got {item!r}"
        key, text = item.split("=", 1)
        if not key.strip() or not text.strip():
            return out, f"{flag} takes `<value>=<text>`, and got {item!r}"
        out[key.strip()] = text.strip()
    return out, None


def _refuse(lines: list[str]) -> int:
    print("deck: REFUSED")
    for line in lines:
        print(f"  {line}")
    return 1


def cmd_ask_fold(ws: Workspace, args) -> int:
    """Write an answered consultation into a pack as a rule, a toggle or a gate.

    deck never does this on its own, and the reason is the whole difference
    between knowledge and a transcript: whether an answer belongs in a pack is a
    judgement about whether the question recurs, and one instance cannot tell
    you that. So this is a command a person runs, having decided.

    What it will not do is invent the parts the consultation does not contain. A
    rule needs `paths:` or it loads on every turn a repository is touched; a
    gate needs a command; a toggle needs a reason for every value, not only the
    one that was chosen. Each is refused by name rather than filled with
    something plausible — the same refusal `propose apply` already makes for a
    drafted toggle that defends one value of two.
    """
    entry = consult.find(ws.root, args.id, ws.all_packs())
    if entry is None:
        print(f"deck: no consultation {args.id}")
        return 1
    if entry["status"] != consult.RESOLVED or not entry.get("answer"):
        return _refuse(
            [
                f"consultation {entry['id']} has no answer yet.",
                "  An unanswered question folded into a pack is a question with a",
                "  false air of settlement. Answer it first:",
                f'    deck ask resolve {entry["id"]} "<the answer>"',
            ]
        )

    already = consult.folded(entry)
    if already and not args.again:
        return _refuse(
            [f"{entry['id']} was already folded into {f['pack']} as a {f['kind']} ({f['file']})." for f in already]
            + [
                "  Two artifacts written from one answer disagree the moment either is edited.",
                "  Edit the one that exists, or pass --again if this pack genuinely needs its own.",
            ]
        )

    pack = Path(args.into).expanduser().resolve()
    if not (pack / "config").is_dir():
        print(f"deck: {pack} is not a pack (no config/ directory) — create it with `deck pack new`")
        return 1

    why = consult.provenance(entry)
    if args.as_kind == "rule":
        if not args.paths:
            return _refuse(
                [
                    "a rule needs --paths.",
                    "  A rule with no `paths:` is loaded on every turn that touches the",
                    "  repository, whether or not it is relevant — which is a cost worth",
                    "  choosing rather than inheriting. Name the files it is about:",
                    f'    deck ask fold {entry["id"]} --as rule --into {args.into} --paths "src/**"',
                ]
            )
        name = title_slug(args.title or entry["question"])
        target = pack / "rules" / f"{name}.md"
        if target.exists():
            print(f"deck: {target} already exists — edit it, or pass --title to write a second")
            return 1
        target.parent.mkdir(parents=True, exist_ok=True)
        patterns = ", ".join(json.dumps(p) for p in args.paths)
        body = args.text or entry["answer"]
        target.write_text(
            f"---\npaths: [{patterns}]\n---\n\n# {args.title or entry['question']}\n\n{body.strip()}\n\n"
            + "\n".join(f"<!-- {line} -->" for line in why.split("\n"))
            + "\n",
            encoding="utf-8",
        )
        placed = mount.record_rules(pack, [f"rules/{name}.md"])
        written = [f"rules/{name}.md"] + ([f"{len(placed)} entry -> config/mount.yaml"] if placed else [])
        rel = f"rules/{name}.md"

    elif args.as_kind == "gate":
        if not args.command:
            return _refuse(
                [
                    "a gate needs --command.",
                    "  deck will not guess what checks this. A gate nobody has run is a",
                    "  gate nobody has, and one deck invented is worse than none.",
                    f'    deck ask fold {entry["id"]} --as gate --into {args.into} --command "make lint"',
                ]
            )
        gid = args.gate_id or title_slug(args.title or entry["question"])[:40]
        target = pack / "config" / "gates.yaml"
        existing = load_yaml(target)
        if any(g.get("id") == gid for g in (existing.get("gates") or [])):
            print(f"deck: gate `{gid}` is already in {target} — edit it, or pass --gate-id")
            return 1
        lines = [""] + [f"# {line}" for line in why.split("\n")]
        lines.append(f"  - id: {gid}")
        lines.append(f"    title: {args.title or entry['question']}")
        lines.append(f"    from_level: {args.from_level}")
        lines.append(f"    per_repo: {json.dumps(args.command)}")
        body = target.read_text(encoding="utf-8") if target.is_file() else "gates:\n"
        target.write_text(body.rstrip() + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
        written = [f"gate `{gid}` -> config/gates.yaml"]
        rel = f"config/gates.yaml#{gid}"

    else:  # toggle
        values = [
            v.strip() for v in (args.values.split(",") if args.values else entry.get("options") or []) if v.strip()
        ]
        if len(values) < 2:
            return _refuse(
                [
                    "a toggle needs at least two values, and this consultation names "
                    + (f"only {len(values)}." if values else "none."),
                    "  A decision with one answer is a rule. Fold it as one, or pass",
                    "  --values a,b if the choice is real and the question did not list it.",
                ]
            )
        impact, bad = _pairs(args.impact, "--impact")
        if bad:
            return _refuse([bad])
        undefended = [v for v in values if v not in impact]
        if undefended:
            return _refuse(
                [
                    "not one of its values is defended:"
                    if len(undefended) == len(values)
                    else "these values have no `impact`:"
                ]
                + [f"  {v}" for v in undefended]
                + [
                    "  The answer defends the value it chose. A catalog entry has to say",
                    "  what the others are for, or the next person reads a choice with one",
                    "  real option. `deck propose toggle` drafts those if you would rather",
                    "  not write them.",
                    "    --impact " + " --impact ".join(f'"{v}=<what taking it means>"' for v in undefended),
                ]
            )
        if not args.group:
            return _refuse(["a toggle needs --group: quality, build, security, delivery, docs or agent."])
        tid = args.gate_id or title_slug(args.title or entry["question"])[:40].replace("-", "_")
        target = pack / "config" / "toggles.yaml"
        existing = load_yaml(target)
        if any(t.get("id") == tid for t in (existing.get("toggles") or [])):
            print(f"deck: toggle `{tid}` is already in {target}")
            return 1
        default = args.default or next((v for v in values if norm(v) in norm(entry["answer"])), None)
        if default is None:
            return _refuse(
                [
                    "the answer does not name one of the values, so deck cannot tell which is the default.",
                    f"  values: {', '.join(values)}",
                    "  Pass --default <value>.",
                ]
            )
        lines = [""] + [f"# {line}" for line in why.split("\n")]
        lines.append(f"  - id: {tid}")
        lines.append(f"    group: {args.group}")
        lines.append(f"    title: {args.title or entry['question'][:60]}")
        lines.append(f"    summary: {json.dumps(entry['question'])}")
        lines.append("    type: enum")
        lines.append(f"    values: [{', '.join(values)}]")
        lines.append(f"    default: {default}")
        lines.append("    impact:")
        for value in values:
            lines.append(f"      {value}: {impact[value]}")
        if args.header:
            if len(args.header) > 12:
                return _refuse([f"--header is {len(args.header)} characters; the selector fits 12."])
            lines.append("    question:")
            lines.append(f"      header: {args.header}")
            lines.append(f"      text: {json.dumps(entry['question'])}")
            lines.append("      options:")
            for value in values:
                lines.append(f"        - {{ value: {value}, label: {json.dumps(value)} }}")
        else:
            # An answered consultation is a decision already taken once. Whether
            # an agent should be interrupted to take it again, at which stage,
            # with what twelve-character header — that is a second decision, and
            # deck has no way to make it from the question's wording. Entries
            # land unasked and settable; `--header` opts in, and `validate`
            # would have refused the entry either way.
            lines.append("    askable: false")
        body = target.read_text(encoding="utf-8") if target.is_file() else "version: 1\n\ntoggles:\n"
        target.write_text(body.rstrip() + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
        written = [f"toggle `{tid}` -> config/toggles.yaml"]
        rel = f"config/toggles.yaml#{tid}"

    consult.record_fold(ws.root, entry["id"], args.as_kind, pack.name, rel, ws.all_packs())
    print(f"folded {entry['id']} into {pack.name} as a {args.as_kind}")
    for item in written:
        print(f"  {item}")
    print("\n  It carries the question and the answer, so the reasoning survives the")
    print("  session that produced it. Read it: deck answered a person's judgement,")
    print("  it did not make one.")
    if args.as_kind == "gate":
        print("\n  Run it before trusting it:  deck gate run")
    return 0


def cmd_ask_publish(ws: Workspace, args) -> int:
    """Move a consultation into a pack, so the team can see it.

    Deliberate rather than automatic, and that is the whole design: not every
    half-formed question is worth three people's attention, and a store that
    fills itself is one nobody reads. What crosses is what somebody decided
    should cross.
    """
    pack = Path(args.into).expanduser().resolve()
    if not (pack / "config").is_dir():
        print(f"deck: {pack} is not a pack (no config/ directory) — create it with `deck pack new`")
        return 1
    entry = consult.find(ws.root, args.id, ws.all_packs())
    if entry is None:
        print(f"deck: no consultation {args.id}")
        return 1
    if entry.get("_origin", "local") != "local":
        print(f"deck: {entry['id']} is already published, in the `{entry['_origin']}` pack")
        print(f"  {entry['_path']}")
        return 1

    moved = consult.publish(ws.root, entry["id"], pack, ws.all_packs())
    if moved is None:
        print(f"deck: {args.id} could not be moved")
        return 1
    print(f"published {moved['id']} into {pack.name}")
    print(f"  {moved['_path']}")
    print("\n  Moved, not copied: two records of one question drift the moment either")
    print("  is answered. `asked_in` was dropped — it names a session on this machine.")
    print("\n  It reaches your colleagues when the pack does. Commit it.")
    return 0
