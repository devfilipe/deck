"""Headless Claude, used to propose — never to apply.

deck is a deterministic tool and stays one. But three of its inputs are
genuinely hard to produce by hand, and all three are judgement about a codebase
rather than facts a parser can extract: the `impacts` edges, the wording of a
toggle that captures a decision a team keeps re-making, and the gates and rules
a repository already deserves.

A drafted finding also has to be sorted, and the hardest call is the one between
a decision and a question. A toggle is a choice whose values each defend
themselves; an inconsistency nobody has explained is not a choice at all, and
filing it as one turns "we do not know" into "we chose". So a pack draft carries
a `questions` list, and `deck propose apply` records each entry as a
consultation instead.

So deck can ask Claude, under four standing constraints:

    off by default        `ai_assist` decides; a run without permission refuses
    read-only             the call is given Read, Grep and Glob and nothing else
    capped                --max-budget-usd stops a runaway loop from opening another
                           turn; the turn already running when it trips still bills
    proposal, never edit  output lands in .deck/proposals/ for a human to read

The last one is the important one. A tool that quietly rewrites the file
describing how your system propagates change is a tool nobody should install.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

from .config import state_root

# Read-only by construction. Not a request in the prompt — a flag the runtime
# enforces, because a prompt is a suggestion and this must not be one.
READ_ONLY = ["Read", "Grep", "Glob"]
DEFAULT_BUDGET = 1.50


class AssistError(RuntimeError):
    pass


def available() -> bool:
    return shutil.which("claude") is not None


def _tool_target(name: str, tool_input: dict) -> str:
    """What a read-only tool call names, in the words a reader would use.

    Every tool call is noise; nothing is what a two-minute wait has today. A
    file path or a search pattern is the line: it says where the time — and
    the money — is going, without asking anyone to read a transcript.
    """
    if name == "Read":
        return str(tool_input.get("file_path") or tool_input.get("path") or "?")
    if name == "Grep":
        pattern = tool_input.get("pattern", "?")
        path = tool_input.get("path")
        return f'"{pattern}"' + (f" in {path}" if path else "")
    if name == "Glob":
        pattern = tool_input.get("pattern", "?")
        path = tool_input.get("path")
        return f"{pattern}" + (f" in {path}" if path else "")
    return name


def proposals_dir(root: Path) -> Path:
    return state_root(root) / "proposals"


def ask(
    prompt: str,
    schema: dict,
    cwd: Path,
    budget: float = DEFAULT_BUDGET,
    timeout: int = 600,
    also_read: list[Path] | None = None,
    on_event: Callable[[float, str, str], None] | None = None,
) -> tuple[dict, dict]:
    """Run one headless turn. Returns (parsed result, accounting).

    Structured output is requested through --json-schema rather than by asking
    for JSON in the prompt, so a malformed answer is the runtime's problem and
    not something deck has to parse defensively.

    The runtime is read line by line, through `--output-format stream-json`
    rather than the single blocking `json` reply this used to wait on — a
    proposal over a few repositories has run past three and a half minutes
    with nothing printed until it was over. The last line is still the same
    envelope `json` would have handed back whole, so nothing about how the
    reply is parsed changes; the difference is that every read and search the
    model asks for on the way there reaches `on_event` as it happens, which is
    what makes the wait watchable without deck ever reading a word of prose.
    `on_event`, not a print here: whether that is worth showing — a terminal,
    say, and not a log nobody is tailing — is the caller's call, not this
    function's.
    """
    if not available():
        raise AssistError("`claude` is not on PATH, so deck cannot ask for a proposal")

    command = [
        "claude",
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--json-schema",
        json.dumps(schema),
        "--max-budget-usd",
        str(budget),
        "--tools",
        *READ_ONLY,
        "--permission-mode",
        "dontAsk",
    ]
    # Directories beyond `cwd` the call may open. The runtime refuses a read
    # outside its working directory, and it is right to: what is added here is
    # named by the descriptor's own graph, never guessed from the filesystem.
    for extra in also_read or []:
        command += ["--add-dir", str(extra)]

    started = time.time()
    try:
        proc = subprocess.Popen(
            command, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
        )
    except OSError as exc:
        raise AssistError(str(exc)) from exc

    # A pipe fills. Reading only stdout in the loop below, while the process
    # blocks writing a stderr nobody is draining, is the classic subprocess
    # deadlock — so stderr gets its own thread from the start, independent of
    # whatever the stdout loop is doing.
    stderr_chunks: list[str] = []

    def _drain_stderr() -> None:
        if proc.stderr:
            for line in proc.stderr:
                stderr_chunks.append(line)

    stderr_thread = threading.Thread(target=_drain_stderr, daemon=True)
    stderr_thread.start()

    # A hard deadline, on its own timer rather than a check between reads: a
    # call that goes quiet mid-tool-call must still be killed at `timeout`,
    # not only one that is still emitting lines when the clock runs out.
    timed_out = {"flag": False}

    def _kill() -> None:
        timed_out["flag"] = True
        proc.kill()

    timer = threading.Timer(timeout, _kill)
    timer.start()

    envelope: dict | None = None
    tool_calls: dict[str, dict[str, int]] = {}
    try:
        if proc.stdout:
            for raw_line in proc.stdout:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    event = json.loads(raw_line)
                except ValueError:
                    continue
                kind = event.get("type")
                if kind == "assistant":
                    for block in (event.get("message") or {}).get("content") or []:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        name = block.get("name")
                        if name not in READ_ONLY:
                            continue
                        target = _tool_target(name, block.get("input") or {})
                        bucket = tool_calls.setdefault(name, {})
                        bucket[target] = bucket.get(target, 0) + 1
                        if on_event:
                            on_event(time.time() - started, name, target)
                elif kind == "result":
                    envelope = event
    finally:
        timer.cancel()
    proc.wait()
    stderr_thread.join(timeout=5)
    stderr_text = "".join(stderr_chunks)

    if timed_out["flag"]:
        # Named, because the way out is not guessable and the run already
        # cost something. Measured: the largest repository in an
        # eight-repository workspace ran 558s on one pass and over 600s on
        # another, and the fixed cap turned a paid call into nothing at all.
        # What was read before the cutoff is not nothing, even though the
        # dollar cost never arrives — it is the one thing left to narrow a
        # retry by.
        seen = sum(len(v) for v in tool_calls.values())
        did = f" {seen} read(s)/search(es) got through before the cutoff." if seen else ""
        raise AssistError(
            f"the call did not finish within {timeout}s, and nothing was written.{did}\n"
            "  Raise it with --timeout <seconds>, or narrow the read: a big repository\n"
            "  with several neighbours is the slow case, and `--no-neighbours` drops\n"
            "  the neighbours a `propose pack` reads for context."
        )

    if envelope is None:
        last = (stderr_text or "no output").strip().splitlines()
        raise AssistError((last[-1] if last else "no output")[:300])

    if envelope.get("is_error"):
        spent = envelope.get("total_cost_usd")
        cost = f" (${spent:.4f} spent)" if isinstance(spent, (int, float)) else ""
        subtype = envelope.get("subtype") or ""
        if "budget" in subtype:
            # --max-budget-usd stops the *loop* — it refuses to start another
            # turn once the running total crosses it — not the spend: the
            # turn already in flight when it trips still finishes and bills.
            # So the number here can, and usually does, read over the cap the
            # caller asked for; say whose charge that is, or the reader is
            # left thinking the cap itself failed.
            raise AssistError(
                f"the cap stopped the loop, not the spend: the call already running when "
                f"it tripped still finished and billed{cost}, so no answer came back. "
                "Raise --budget, or narrow the scope with --repos: proposing over a few "
                "repositories at a time is cheaper and easier to review than one large run."
            )
        raise AssistError(f"{envelope.get('result') or subtype or 'the call reported an error'}{cost}")

    usage = envelope.get("usage") or {}
    accounting = {
        "usd": envelope.get("total_cost_usd"),
        "seconds": round(time.time() - started, 1),
        "input": usage.get("input_tokens", 0),
        "output": usage.get("output_tokens", 0),
        "cache_read": usage.get("cache_read_input_tokens", 0),
        "session": envelope.get("session_id"),
        "denials": len(envelope.get("permission_denials") or []),
        # Where the money went, at the resolution a reader can act on: not
        # "$1.37 over six repositories", but which file was read how many
        # times and what was searched for — the difference between "run it
        # again with fewer repositories" and "run it again without that one".
        "reads": tool_calls.get("Read", {}),
        "greps": tool_calls.get("Grep", {}),
        "globs": tool_calls.get("Glob", {}),
    }

    raw = envelope.get("result")
    if isinstance(raw, dict):
        return raw, accounting
    try:
        return json.loads(raw), accounting
    except (ValueError, TypeError) as exc:
        raise AssistError(f"the reply did not match the requested shape: {str(raw)[:200]}") from exc


def save(root: Path, kind: str, payload: dict, accounting: dict, prompt: str) -> Path:
    """Write the proposal, with what it cost and what it was asked, beside it."""
    path = proposals_dir(root) / f"{kind}-{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "kind": kind,
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "cost": accounting,
                "prompt": prompt,
                "proposal": payload,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return path


IMPACTS_SCHEMA = {
    "type": "object",
    "required": ["edges"],
    "properties": {
        "edges": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["from", "to", "why", "confidence"],
                "properties": {
                    "from": {"type": "string"},
                    "to": {"type": "string"},
                    "why": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                },
            },
        },
        # A coupling is its own list, not a flag on an edge, and the two `why`
        # fields are the reason. A coupling claims no order, which makes it the
        # comfortable answer for any pair the drafter cannot decide; the one
        # thing that separates it from an edge is evidence in both directions,
        # each citable on its own. A flag can be set without producing the
        # second citation. Two required fields cannot, so the shape asks for the
        # thing the wording asks for — the same move `defends` makes for a
        # toggle in PACK_SCHEMA.
        "couplings": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["a", "b", "why_a_to_b", "why_b_to_a", "confidence"],
                "properties": {
                    "a": {"type": "string"},
                    "b": {"type": "string"},
                    "why_a_to_b": {"type": "string"},
                    "why_b_to_a": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                },
            },
        },
        "unsure": {"type": "array", "items": {"type": "string"}},
    },
}

TOGGLE_SCHEMA = {
    "type": "object",
    "required": ["id", "title", "summary", "values", "default", "rationale", "impact", "question"],
    "properties": {
        "id": {"type": "string"},
        "group": {"type": "string"},
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "values": {"type": "array", "items": {"type": "string"}},
        "default": {"type": "string"},
        "stage": {"type": "array", "items": {"type": "string"}},
        "risk": {"type": "string"},
        "rationale": {"type": "string"},
        "impact": {"type": "object", "additionalProperties": {"type": "string"}},
        "question": {
            "type": "object",
            "required": ["header", "text", "options"],
            "properties": {
                "header": {"type": "string"},
                "text": {"type": "string"},
                "options": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["value", "label", "description"],
                        "properties": {
                            "value": {"type": "string"},
                            "label": {"type": "string"},
                            "description": {"type": "string"},
                        },
                    },
                },
            },
        },
    },
}


def _declared_couples(name: str, entry: dict, repos: dict) -> list[str]:
    """The couplings this repository is in, from either side.

    `couples:` is symmetric and one side is enough, so a listing that printed
    only what an entry declares would show a drafter half of the pairs and then
    tell it not to propose what already exists. It would obey, and re-propose
    the other half.
    """
    out = [other for other in (entry.get("couples") or []) if other != name and other in repos]
    out += [
        other for other, e in repos.items() if other != name and other not in out and name in (e.get("couples") or [])
    ]
    return out


def impacts_prompt(repos: dict, root: Path) -> str:
    listing = "\n".join(
        f"  {name}: {entry.get('path', '?')}"
        + (f" — {entry['role']}" if entry.get("role") else "")
        + (f"  (already declares impacts: {', '.join(entry['impacts'])})" if entry.get("impacts") else "")
        + (
            f"  (already coupled with: {', '.join(_declared_couples(name, entry, repos))})"
            if _declared_couples(name, entry, repos)
            else ""
        )
        for name, entry in repos.items()
    )
    return f"""You are helping fill in a change-propagation graph for a multi-repository
workspace rooted at {root}.

The repositories:

{listing}

Read enough of each to answer one question per pair: **when this repository
changes, is another one forced to change with it?** Look for a real dependency —
generated code, a published schema consumed elsewhere, a shared interface, a
package another one installs, tests that assert against it.

The graph holds two kinds of edge, and they are not interchangeable:

  EDGE      `impacts:`, reported in `edges`. One direction: `from` forces `to`.
            It answers two questions with one edge — what must I revisit, and in
            what order — and everything that sorts this workspace reads it.
  COUPLING  `couples:`, reported in `couplings`. Two repositories that drive
            each other and neither of which comes first. It answers the revisit
            and says nothing about the order, and nothing that sorts reads it.

## An edge and a coupling are not the same finding

Read this twice, because a coupling claims no order and that makes it the
comfortable answer for every pair you are unsure about:

  EDGE      you can cite the thing that forces `to` to change, and you cannot
            cite one going the other way.
  COUPLING  you can cite one thing for EACH direction, separately: a file, an
            import, a generated artifact for `a` breaking `b`, and a DIFFERENT
            one for `b` breaking `a`. Two citations, not one relationship told
            twice in two word orders.

`why_a_to_b` and `why_b_to_a` are where those two citations go, and they are
what a coupling costs. If you cannot fill both in without hedging, you have not
found a coupling.

**Evidence one way and a hunch the other is an edge, not a coupling.** Report
the direction you can cite as an edge, and put the hunch in `unsure`, naming
what you would have had to read to settle it — a person decides that one. The
edge you can prove is worth more than a coupling you half invented, because the
coupling drops the order the edge was carrying and every command that sorts the
workspace loses it.

Never report one pair as two edges in opposite directions. That is a cycle: the
topological order stops existing, and `deck doctor` refuses it. If both
directions are real it is one entry in `couplings`; if one is, it is one edge.

Rules:
- Only report an edge or a coupling you can point at evidence for. A guess is
  worse than a gap, because a wrong edge serialises work that could have run in
  parallel and sends an agent into a repository it has no business editing.
- Do not report an edge or a coupling that already exists in the listing above.
- `why`, `why_a_to_b` and `why_b_to_a` must each name the concrete thing: a
  file, an import, a generated artifact.
- Put anything you could not decide into `unsure`, with the reason.

You have read-only tools. Do not attempt to modify anything."""


def toggle_prompt(
    decision: str,
    existing: list[str],
    groups: list[str] | None = None,
    stages: list[str] | None = None,
) -> str:
    # `group` and `stage` are closed vocabularies, checked by
    # `deck toggle validate --strict`. A draft that invents a value looks
    # finished and fails validation later, in a different command — the same
    # shape as a gate id nobody said was taken.
    vocab = ""
    if groups:
        vocab += f"\n`group` must be exactly one of: {', '.join(sorted(groups))}."
    if stages:
        vocab += f"\n`stage` entries must come from: {', '.join(sorted(stages))}."
    if vocab:
        vocab += "\nThese are closed lists. Pick the nearest one rather than inventing a name.\n"
    return f"""Draft one entry for a decision catalog. The decision a team keeps re-making is:

  {decision}

The catalog already contains: {", ".join(existing) or "(nothing)"} — do not duplicate one.
{vocab}
An entry is read by a person months from now and, when its value is `ask`, is put
to a human mid-task by an agent. So:

- `rationale` explains why the decision exists at all, and what goes wrong when it
  is made badly. It is the part that survives the person who wrote it.
- `impact` has one line per value saying what choosing it costs you — not a
  restatement of the value's name.
- `question.header` is at most 12 characters.
- `question.text` reads as a question a colleague would actually ask.
- Each option's `description` states the consequence, not the label again.
- At most four options.
- `default` is the safe answer, not the convenient one.

Write it for this workspace specifically, not in general terms."""


# A skill and an agent are read as instructions to follow, not as claims to
# argue with: a rule that is wrong gets disputed, a procedure that is wrong gets
# executed. So both ask for more than the other kinds — every step carries its
# own `evidence`, and a step nobody can point at is a step that was invented.
SKILL_SCHEMA = {
    "type": "object",
    "required": ["name", "title", "when_to_use", "steps", "confidence"],
    "properties": {
        "name": {"type": "string", "description": "kebab-case, becomes skills/<name>/SKILL.md"},
        "title": {"type": "string"},
        "when_to_use": {
            "type": "string",
            "description": "the words somebody would actually say when they need it, not a category",
        },
        "steps": {
            "type": "array",
            "minItems": 2,
            "items": {
                "type": "object",
                "required": ["do", "evidence"],
                "properties": {
                    "do": {"type": "string", "description": "one step, in the imperative"},
                    "evidence": {
                        "type": "string",
                        "description": "the file, commit or document this step is read FROM — never inferred",
                    },
                },
            },
        },
        "pitfall": {
            "type": "string",
            "description": "what goes wrong when a step is skipped or done out of order, if you can point at it",
        },
        "confidence": {"enum": ["high", "medium", "low"]},
    },
}

AGENT_SCHEMA = {
    "type": "object",
    "required": ["name", "title", "description", "why", "confidence"],
    "properties": {
        "name": {"type": "string", "description": "kebab-case, becomes agents/<name>.md"},
        "title": {"type": "string"},
        "description": {
            "type": "string",
            "description": "when Claude should hand work to it, in the terms a person would use",
        },
        "why": {
            "type": "string",
            "description": "what about THIS repository makes a separate agent worth having, with evidence",
        },
        "confidence": {"enum": ["high", "medium", "low"]},
    },
}

LESSONS_SCHEMA = {
    "type": "object",
    "required": ["lessons", "nothing_because", "unsure"],
    "properties": {
        "lessons": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["kind", "name", "text", "evidence", "confidence"],
                "properties": {
                    "kind": {"enum": ["rule", "toggle", "gate", "skill"]},
                    "name": {"type": "string"},
                    "text": {"type": "string", "description": "the lesson, written for somebody who was not there"},
                    "paths": {"type": "array", "items": {"type": "string"}},
                    "evidence": {
                        "type": "string",
                        "description": "where in the session this was learned — what was tried, what failed",
                    },
                    "confidence": {"enum": ["high", "medium", "low"]},
                },
            },
        },
        # The empty answer, made readable. A session where nothing was learned
        # is the ordinary session, and it must not look like a session nobody
        # read.
        "nothing_because": {
            "type": "string",
            "description": "one line. If you propose nothing, why: what the session did, and why none of it generalises.",
        },
        "unsure": {"type": "array", "items": {"type": "string"}},
    },
}


def lessons_prompt(repos: list[str], packs: list[str], transcript: str) -> str:
    return f"""You are reading one working session and deciding what, if anything, it taught
that belongs in a versioned pack — where the next person will read it without
having been here.

Repositories in this workspace: {", ".join(repos) or "(none)"}
Packs that could hold it: {", ".join(packs) or "(none)"}

## What counts

A lesson is something that cost somebody time and will cost the next person the
same time. Three attempts before something worked. A wrong assumption the code
did not contradict. An order that turned out to matter.

**What does NOT count, and this is most of a session:**

- the task itself. What was built is in the commit.
- anything the code already says, or a gate already checks.
- a one-off. If it will not happen again, it was a commit message.
- something already in a pack. Look at the pack list above first.

## Where each kind goes, and the test for it

  rule    something that must stay true. A reader can disagree with it.
          Needs `paths:` — the files it is about.
  toggle  a decision with more than one defensible answer, made more than once.
  gate    something a command can check. If a machine can settle it, it is a
          gate and never a rule — a rule costs context on every matching file
          read, forever, and the check was free.
          For a gate, `text` IS THE COMMAND, and nothing else: a line that
          could be pasted into a shell. Not a description of a command, not a
          sentence about what should be checked. If you cannot write the
          command, you have not found a gate — put it in `unsure`.
  skill   several steps in an order where reordering breaks something.

`evidence` is where in the session it was learned: what was tried, what failed,
what the error said. A lesson you cannot point at is a lesson you inferred, and
that goes in `unsure`.

**Proposing nothing is the ordinary answer**, and `nothing_because` is where you
give it. A session that fixed one bug in one file taught nothing general, and
saying so is worth more than inventing a rule to fill the array.

## The session

{transcript}
"""


PACK_SCHEMA = {
    "type": "object",
    "required": [
        "gates",
        "rules",
        "toggles",
        "skills",
        "agents",
        "skills_note",
        "agents_note",
        "questions",
        "unsure",
    ],
    "properties": {
        "skills": {"type": "array", "items": SKILL_SCHEMA},
        "agents": {"type": "array", "items": AGENT_SCHEMA},
        # Proposing nothing is a real answer, and a real answer is one you can
        # read. An empty array on its own is indistinguishable from a question
        # that was never asked — which is the whole complaint that put skills
        # and agents in this schema. These two make the empty case say so.
        "skills_note": {
            "type": "string",
            "description": (
                "one line. If you proposed no skill, why: what you looked at and what made it "
                "not a procedure. If you proposed some, what you left out and why."
            ),
        },
        "agents_note": {
            "type": "string",
            "description": (
                "one line. If you proposed no agent, why: proposing none is the ordinary answer, "
                "so say what would have had to be different."
            ),
        },
        "gates": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["id", "title", "from_level", "command", "evidence", "confidence"],
                "properties": {
                    "id": {"type": "string"},
                    "title": {"type": "string"},
                    "from_level": {"type": "string", "enum": ["static", "build", "deploy", "behavior"]},
                    "command": {"type": "string"},
                    "evidence": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                },
            },
        },
        "rules": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["name", "paths", "consequence", "evidence", "confidence"],
                "properties": {
                    "name": {"type": "string"},
                    "paths": {"type": "array", "items": {"type": "string"}},
                    "consequence": {"type": "string"},
                    "evidence": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                },
            },
        },
        "toggles": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["id", "title", "summary", "values", "defends", "rationale", "confidence"],
                "properties": {
                    "id": {"type": "string"},
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "values": {"type": "array", "items": {"type": "string"}},
                    # One line per value, keyed by the value. This is the field
                    # that separates a decision from a question: a finding
                    # nobody understands cannot produce a defence for both
                    # sides, so asking for one here is what stops "we do not
                    # know" being filed as "we chose".
                    "defends": {"type": "object", "additionalProperties": {"type": "string"}},
                    "rationale": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                },
            },
        },
        # A finding in the code the drafter could not explain. It is not a
        # toggle and it is not a note about the drafting: it is a question for a
        # person, and `propose apply` records it as a consultation.
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["question", "context", "evidence"],
                "properties": {
                    "question": {"type": "string"},
                    "context": {"type": "string"},
                    "evidence": {"type": "string"},
                    "options": {"type": "array", "items": {"type": "string"}},
                },
            },
        },
        "unsure": {"type": "array", "items": {"type": "string"}},
    },
}


def _neighbour_block(neighbours: list[tuple[str, str, Path]]) -> str:
    """What the graph says about this repository's surroundings, if anything.

    Empty when the repository has no edges, so a workspace of one reads exactly
    as it did — and so does a drafter, which is the point: nothing is said about
    neighbours that do not exist.
    """
    if not neighbours:
        return ""
    rows = "\n".join(f"  {name}\n    {path}\n    {why}" for name, why, path in neighbours)
    return f"""
The workspace connects this repository to others, and you may read them:

{rows}

Read one only to answer a question about the repository above — what a symbol
it calls actually does, whether a file it names exists, which side of a
contradiction is current. That is the whole reason they are here: a draft that
files "I could not verify this, it lives in another repository" has said
something true of the directory and false of the workspace, and sent the reader
who trusts it away from an answer that was three directories off.

## Skills and agents are held to a higher bar than the rest, and here is why

A gate is judged by a machine. A rule is a claim a reader can disagree with. A
**skill is an instruction somebody will follow**, and a procedure that is subtly
wrong does not get argued with — it gets executed, in the wrong order, on a real
repository. So:

- **Every step names the file, commit or document it was read FROM.** A step you
  worked out from how the code looks is not a step you observed. If the sequence
  only exists in your head, it belongs in `questions`, not in `steps`.
- **A skill has at least two steps and an order that matters.** One action is
  not a procedure. If nothing breaks when the steps are reordered, what you
  found is a rule.
- **Do not write a skill for something the tooling already does.** "Run the
  build" is a gate. A skill earns its place when a person has to hold several
  things in the right order and the tooling will not tell them they got it
  wrong.
- **`pitfall` is what makes it worth reading.** What actually broke, the last
  time somebody skipped a step. Leave it out rather than inventing one.

An **agent** is a bigger claim still: it says the default posture is wrong for
this repository. Propose one only when you can point at what is different — a
codebase where every change is a contract change, a repository where reading the
device state matters more than reading the code. "This repository is complex" is
not a reason. **Proposing no agent is the ordinary answer**, and proposing none
costs nothing.

**Proposing none is an answer, and `skills_note` and `agents_note` are where you
give it.** Both are required whatever you decide. An empty array with nothing
beside it cannot be told apart from a question nobody asked, and somebody
reading the pack a month from now has to be able to tell "there is no procedure
here worth writing down" from "the draft never looked".

Both are drafts a person reviews before anybody follows them, and both are
written into the pack, which is versioned. Say `low` when you mean low.

The pack is still for ONE repository. Nothing you find in a neighbour becomes a
gate, a rule or a toggle here — those belong to that repository's own pack, and
proposing them here puts them where nobody looking for them will read them. A
neighbour is evidence, and evidence is what `evidence` and `questions` are for.
"""


def _taken_gates_block(taken: list[str]) -> str:
    """Gate ids already declared, and why the draft may not reuse one.

    A gate id is workspace-wide, not per pack: deck refuses a second pack
    declaring one another pack already has, and says so at `deck gate list`
    rather than picking a winner. The drafter could not see that, so two
    Python repositories both proposed `ruff-check` — each correct on its own,
    and together a workspace whose ladder would not load.
    """
    if not taken:
        return ""
    return (
        "\nGate ids already declared in this workspace, by other packs:\n"
        + "\n".join(f"  {g}" for g in taken)
        + "\n\nA gate id is workspace-wide. Do NOT reuse one of those: deck refuses a\n"
        "second pack that declares an id another pack already has, and the whole\n"
        "ladder stops loading until somebody renames one. If this repository runs\n"
        "the same tool, give the gate an id that says whose it is\n"
        "(`ruff-check-<repository>`), or leave it out and say in `unsure` that the\n"
        "existing gate looks like it should cover this repository too.\n"
    )


def pack_prompt(
    repo: str,
    path: Path,
    role: str | None,
    neighbours: list[tuple[str, str, Path]] | None = None,
    taken_gates: list[str] | None = None,
) -> str:
    return f"""You are drafting a deck pack for one repository, by reading it.

Repository: {repo}
Path: {path}
{f"Its declared role: {role}" if role else ""}
{_neighbour_block(neighbours or [])}
{_taken_gates_block(sorted(taken_gates or []))}

Every finding has one right home, and putting it there is most of the work.
The rule is that the cheapest correct home wins:

  GATE      a command that passes or fails. Formatting, lint, type check,
            tests, build, schema validation. It costs nothing until it runs.
  RULE      a constraint no command can decide, tied to an area of the code,
            worth loading whenever a matching file is read. It costs context
            EVERY time, so it has to earn that.
  TOGGLE    a decision with more than one defensible answer that this team
            keeps re-making.
  SKILL     a PROCEDURE: steps in an order, where doing them out of order or
            skipping one breaks something. A rule says what must stay true; a
            skill says what to do, and in what sequence.
  AGENT     a persona worth handing a whole class of work to, because working
            in this repository needs a posture the default does not have.
  QUESTION  something you found and cannot explain: two code paths that
            disagree, a convention held here and broken there, and you cannot
            tell whether it was decided or whether it drifted. A person
            answers it; you do not.
  neither   this repository is small, or its conventions are already enforced.
            Proposing nothing is a valid and often correct answer.

Read the repository and propose only what you can point at evidence for:

- **Gates**: find the commands this project ALREADY uses. Look in CI workflows,
  Makefile, tox.ini, package.json scripts, pyproject.toml, noxfile, Justfile,
  pre-commit config. Do not invent a command, and do not propose one whose tool
  is not already a dependency here. `evidence` names the file you read it from.
- **Rules**: a constraint whose violation would not be caught by any gate you
  proposed, and whose consequence is worth a sentence. "This directory holds
  handlers" is worthless — the agent can see that. "Handlers validate at the
  edge; nothing below re-checks shapes" earns its place. `evidence` names the
  files that show the convention holds today.
- **Toggles**: only where the code shows the choice was genuinely made, and
  could defensibly have gone the other way. If there is one right answer it is
  a rule or a gate, not a toggle.
- **Questions**: an inconsistency you cannot account for. `context` is what a
  person needs in order to answer without re-reading the repository, `evidence`
  names the files that disagree, and `options` — if you have them — are the
  answers you can already see.

## A toggle and a question are not the same finding

This is the distinction that decides where a finding goes, so read it twice:

  TOGGLE    every value defends itself. You can write one line per value saying
            why a reasonable team would pick that one. `defends` carries that
            line for EVERY value in `values`.
  QUESTION  you cannot write those lines, because you do not know why the code
            is the way it is.

Recording a question as a toggle turns "we do not know" into "we chose", and the
doubt disappears at exactly the moment it was worth keeping. That has happened
here: a drafter found two code paths returning different status codes for the
same class of refusal, said in its own notes that it could not tell whether that
was intentional or drift, and filed it as a toggle. It was a question.

So one finding goes in one list, never in two. If you cannot fill in `defends`
for every value without hedging, it is a question — put it in `questions` and
leave it out of `toggles`. `deck propose apply` refuses a draft that files the
same finding as both, and refuses a toggle whose values are not all defended.

Rules:
- Anything a formatter or linter settles is a GATE, never a rule. Telling an
  agent about indentation is paying tokens forever for something a tool fixes in
  milliseconds.
- Fewer, better entries. A pack nobody reads is a pack nobody maintains.
- `unsure` is for the limits of your own reading — a directory you could not
  open, a build system you do not know, a file too large to finish. It is not
  where a finding goes. A thing you read and cannot explain is a `questions`
  entry, because a person can answer that one and nobody can answer "I did not
  look". A gap is honest; a guess dressed as a finding is not.

You have read-only tools. Do not attempt to modify anything."""
