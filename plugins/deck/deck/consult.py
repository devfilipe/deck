"""Consultations — the question nobody declared in advance.

A toggle is a decision someone foresaw: written down, worded once, asked at the
right moment. That covers the decisions a team already knows it keeps making.

It does not cover the other kind. An agent in the middle of a task meets
something genuinely new — a trade-off the catalog has no entry for — and today
it has exactly two options, both bad: decide alone, or stall. A run of the board
workflow demonstrated the second, twice, before a line was edited.

So there is a third place to put it. A consultation is recorded, survives the
session that raised it, is answered by a person, and is then readable by the
next run — which is what stops the same question being asked forever.

The answer is deliberately NOT folded into the catalog automatically. Turning
one answer into a toggle, a rule or a gate is judgement about whether it will
recur, and that is the whole difference between knowledge and a transcript.
`deck ask resolve` says which artifact it looks like and leaves the writing to a
person, or to `deck propose toggle`.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from .config import STATE_DIR, norm, publish_identity, session_id

OPEN, RESOLVED = "open", "resolved"


def store(root: Path) -> Path:
    """Where a consultation is written when nobody has said to share it."""
    return root / STATE_DIR / "consultations"


def shared_stores(packs: list[Path] | None) -> list[Path]:
    """`consultations/` in every pack in play, in merge order.

    A consultation is pack content, the way a rule is. That is not a new place
    to put things — it is the one deck already has for knowledge a team shares,
    versioned and reviewed, and it means a published question travels by the
    mechanism everything else travels by.

    The question and the answer are workspace knowledge; the session id it was
    raised in and the machine it was raised on are not, which is why publishing
    is a move rather than a mirror of the whole record.
    """
    return [pack / "consultations" for pack in (packs or []) if (pack / "consultations").is_dir()]


def _read(path: Path, origin: str) -> dict | None:
    try:
        entry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    entry["_origin"] = origin
    entry["_path"] = str(path)
    return entry


def _slug(text: str) -> str:
    keep = [c.lower() if c.isalnum() else "-" for c in text[:40]]
    return "".join(keep).strip("-").replace("--", "-") or "question"


def record(root: Path, question: str, task: str | None, context: str | None, options: list[str]) -> dict:
    """Write a consultation down. Returns it, with the id a person will answer.

    `asked_by` is the workspace's published identity, not `$USER`, for the same
    reason a claim is: a consultation outlives its session by design, is read by
    the next run, and is quoted into the bundle a reviewer reads. A name that
    travels that far is a published name. It is left empty when there is none to
    read — `deck ask show` prints that as `?`, which is true, where a shell
    login would have been plausible and wrong.
    """
    ident = f"{time.strftime('%Y%m%d-%H%M%S')}-{_slug(question)}"[:64]
    entry = {
        "id": ident,
        "status": OPEN,
        "question": question.strip(),
        "task": task,
        "context": (context or "").strip() or None,
        "options": [o for o in options if o],
        "asked_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "asked_in": session_id(),
        "asked_by": publish_identity(root)[0],
        "answer": None,
        "answered_at": None,
        "answered_by": None,
    }
    path = store(root) / f"{ident}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return entry


def load_all(root: Path, packs: list[Path] | None = None) -> list[dict]:
    """Every consultation this workspace can see, local ones first.

    An id published into a pack and still present locally is one record, not
    two: the local copy wins, because it is the one an unfinished publish left
    behind and the one a person is looking at.
    """
    out: list[dict] = []
    seen: set[str] = set()
    for directory, origin in [(store(root), "local")] + [(d, d.parent.name) for d in shared_stores(packs)]:
        for path in sorted(directory.glob("*.json")):
            entry = _read(path, origin)
            if entry is None or entry.get("id") in seen:
                continue
            seen.add(entry["id"])
            out.append(entry)
    return out


def find(root: Path, ident: str, packs: list[Path] | None = None) -> dict | None:
    for entry in load_all(root, packs):
        if entry["id"] == ident or entry["id"].endswith(ident):
            return entry
    return None


def publish(root: Path, ident: str, pack: Path, packs: list[Path] | None = None) -> dict | None:
    """Move a consultation into a pack, where a colleague can read it.

    A move, not a copy. Two records of one question drift the moment either is
    answered, and the whole reason a consultation exists is that the doubt
    survives in one place until somebody settles it.

    `asked_in` goes: it names a session on one machine and means nothing to
    anybody else. `asked_by` stays — it is the published identity, and an
    answer nobody can attribute is an answer nobody can ask about.
    """
    entry = find(root, ident, packs)
    if entry is None or entry.get("_origin") != "local":
        return None
    entry = {k: v for k, v in entry.items() if not k.startswith("_")}
    entry.pop("asked_in", None)
    target = pack / "consultations"
    target.mkdir(parents=True, exist_ok=True)
    (target / f"{entry['id']}.json").write_text(
        json.dumps(entry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (store(root) / f"{entry['id']}.json").unlink(missing_ok=True)
    entry["_origin"] = pack.name
    entry["_path"] = str(target / f"{entry['id']}.json")
    return entry


def _save(entry: dict) -> dict:
    """Write a record back where it was read from, local or in a pack.

    Not `store(root)`. Answering a consultation a colleague published used to
    write the answer into the local store and leave the published question
    open, so the team saw a question nobody had answered and the answerer saw
    one nobody else could read.
    """
    path = Path(entry["_path"])
    body = {k: v for k, v in entry.items() if not k.startswith("_")}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return entry


def resolve(root: Path, ident: str, answer: str, who: str | None, packs: list[Path] | None = None) -> dict | None:
    entry = find(root, ident, packs)
    if entry is None:
        return None
    entry["status"] = RESOLVED
    entry["answer"] = answer.strip()
    entry["answered_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    entry["answered_by"] = who or publish_identity(root)[0]
    return _save(entry)


def looks_like(entry: dict) -> str:
    """Which artifact an answer probably wants to become, as a suggestion only.

    A guess, and said as one. What decides it is whether the question recurs,
    and nobody knows that from one instance — which is exactly why this does not
    write anything.
    """
    text = f"{entry.get('question', '')} {entry.get('answer', '')}".lower()
    if entry.get("options") and len(entry["options"]) > 1:
        return "toggle — it had named options, so it may be a decision that recurs"
    if any(word in text for word in ("never", "always", "must not", "must ", "sempre", "nunca")):
        return "rule — it reads as a constraint rather than a choice"
    if any(word in text for word in ("check", "verify", "assert", "fail", "test", "gate")):
        return "gate — if a machine can check it, it belongs in the ladder"
    return "unclear — write it down where it will be read, or leave it here"


def answered_summary(root: Path, limit: int = 20) -> list[dict]:
    """Resolved consultations, newest first — what a later run should read first."""
    done = [e for e in load_all(root) if e["status"] == RESOLVED]
    return sorted(done, key=lambda e: norm(e.get("answered_at", "")), reverse=True)[:limit]


def folded(entry: dict) -> list[dict]:
    """Where this answer has already been written down, if anywhere."""
    return list(entry.get("folded") or [])


def record_fold(
    root: Path, ident: str, kind: str, pack: str, target: str, packs: list[Path] | None = None
) -> dict | None:
    """Note that the answer now lives somewhere, and where.

    Without this the same answer gets folded twice — into two packs, or into a
    rule and then a toggle — and the second one is written by somebody who could
    not see the first. It also gives `ask show` something truer to print than
    a guess about what the answer wants to become: it already became it.
    """
    entry = find(root, ident, packs)
    if entry is None:
        return None
    entry.setdefault("folded", []).append(
        {"kind": kind, "pack": pack, "file": target, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    )
    return _save(entry)


def provenance(entry: dict) -> str:
    """The consultation, in the words a reader of the artifact will need.

    An artifact folded from a consultation carries the question and the answer,
    not a bare id: somebody reading the rule two years from now needs the
    reasoning, and an id sends them looking for a file that may be on a machine
    they do not have. The id goes in too, for whoever does have it.
    """
    lines = [f"Folded from consultation {entry['id']}."]
    lines.append(f"Question: {entry['question']}")
    if entry.get("answer"):
        lines.append(
            f"Answered {entry.get('answered_at', '?')} by {entry.get('answered_by') or '?'}: {entry['answer']}"
        )
    return "\n".join(lines)
