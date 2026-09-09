#!/usr/bin/env python3
"""Every command the CLI exposes is named somewhere a reader will find it.

The prose rule says a user-visible change updates the documents in the same
commit. That is a rule because most of it is judgement — whether the paragraph
is any good, whether the example is the right one. But half of it is not
judgement at all: a command that exists and is written down nowhere is a fact,
and deck's own rule is that a fact a machine can check is a gate.

It checks names, not quality. A command mentioned once in a table passes here
and may still be undocumented in every sense that matters; that half stays with
the reviewer. What this stops is the silent half — a command shipped, renamed or
removed while the documents go on describing the previous version.

Both directions are checked, because a rename breaks the documents twice: the
new name is written down nowhere, and the old name is still offered as if it
worked. Only the first of those was caught until a document went on offering a
command for a week after it was gone.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# ci/ is one level below the repository root. This script used to live in
# packs/_workspace/bin/, three levels down; the constant has to track wherever
# the file actually is, and nothing else in the file would notice if it did not.
ROOT = Path(__file__).resolve().parents[1]
DOCS = ["README.md", "WALKTHROUGH.md", "DESIGN.md", "FOUNDATIONS.md", "PACKS.md", "CONTRIBUTING.md"]
# Commands that exist for a person at a terminal and are documented by being
# used, not by being listed. They are still real commands, so a document naming
# one is not naming something that does not exist.
EXEMPT = {"root", "info", "get", "path"}
# Not `\\d{3}`: that would stop matching the day the suite passed 999, and a
# gate that matches nothing reports success over whatever the documents last
# said. Named so a check can exercise the pattern itself.
COUNT = r"\b(\d{2,}) checks\b"

# The filter field each tracker provider reads from its own source — the one
# that turns a team's whole board into the slice a workspace acts on. Nothing
# in the CLI's own `--help` lists these the way it lists subcommands: they are
# read with `source.get(...)` inside trackers.py, not declared anywhere central.
# So unlike `subcommands()`, this is a hand-kept table rather than an
# introspected one — #18 was a field with no home in any document, and the
# fix decided that a short table checked by hand is worth it here even though
# a full schema walk is not.
TRACKER_FIELDS = {
    "github": ["query", "include"],
    "gitlab": ["state", "labels"],
    "jira": ["jql"],
    "gerrit": ["query"],
}

# Every field above names part of what a board source *is*, so every one of them
# has to survive `pack new --from-workspace`. `in_progress:` is here too: it is
# how a board writes down that somebody is on a task, which is the team's answer
# and not one machine's. `api:` is the one that proved this needs checking — it
# was absent from BOARD_IDENTITY, and a team on a self-hosted host seeded a
# template that quietly pointed at the public service.
MUST_SURVIVE_SEEDING = sorted({f for fields in TRACKER_FIELDS.values() for f in fields} | {"api", "in_progress"})


def subcommands() -> list[str]:
    out = subprocess.run(
        [str(ROOT / "plugins" / "deck" / "bin" / "deck"), "--help"],
        capture_output=True,
        text=True,
    ).stdout
    match = re.search(r"\{([a-z,-]+)\}", out)
    if not match:
        print("could not read the subcommand list from `deck --help`", file=sys.stderr)
        raise SystemExit(2)
    return match.group(1).split(",")


# Paths that are real parts of this repository. `packs/proj1` and the like are
# illustrations in a diagram and are meant not to exist.
REAL_DIRS = ("docs/", "ci/", "seed/", ".github/")

FENCE = re.compile(r"```[a-z]*\n(.*?)```", re.S)
# The two spellings these documents actually use for a command someone would
# type: `deck impact` inline, and a `deck impact` line inside a fenced block,
# with or without a `$ ` prompt in front of it.
INLINE_CALL = re.compile(r"`deck ([a-z][a-z0-9-]*)")
FENCED_CALL = re.compile(r"^(?:\$ )?deck ([a-z][a-z0-9-]*)", re.M)


def offered_commands(prose: str) -> set[str]:
    """Commands the documents put in front of a reader as something to run.

    Deliberately narrower than "the word appears near `deck`". A fenced block
    holds transcripts, trees and two-column diagrams, and those contain lines
    like `deck computes these.` and `── deck places these ──`; matching those
    would make the check report a rename every time someone wrote a sentence.
    Inside a fence only a line that *starts* a command counts; outside one,
    only an inline code span does.
    """
    offered = set()
    for block in FENCE.findall(prose):
        offered.update(FENCED_CALL.findall(block))
    offered.update(INLINE_CALL.findall(FENCE.sub("", prose)))
    return offered


def dangling_paths(prose: str) -> list[str]:
    """Files the documents point at that are not there.

    A document naming a file that was deleted is the same failure as one naming
    a command that was renamed, and it had gone uncaught: the README went on
    offering `asciinema play docs/tour.cast` for a recording that had been
    removed for carrying a machine's session name.
    """
    found = set(re.findall(r"(?:\./)?((?:docs|ci|seed|\.github)/[A-Za-z0-9_./-]+)", prose))
    return sorted(p for p in found if p.startswith(REAL_DIRS) and not (ROOT / p).exists())


def missing_tracker_fields(prose: str) -> list[str]:
    """Tracker filter fields named nowhere in the documents.

    Checks presence, not placement: a field written as `` `query:` `` anywhere
    in these documents passes, on the same theory the command check uses — a
    field mentioned once may still be explained badly, and that half stays with
    the reviewer. What this stops is the field appearing in no document at all,
    the way `query:` did until PACKS.md named it.
    """
    return sorted(
        f"{provider}.{field}"
        for provider, fields in TRACKER_FIELDS.items()
        for field in fields
        if f"`{field}:`" not in prose
    )


def suite_total(log: Path | None) -> tuple[int | None, str]:
    """The suite's own check total, and where it came from.

    With a log, from a run that already happened; without one, by running the
    suite here. CI has already run it by the time the documents are checked, so
    it passes the log and the suite runs once per push rather than twice. The
    log is never optional once it is asked for: a missing or unreadable one is
    an error, because falling back to "no number, nothing to compare" would
    turn a broken workflow into a silent pass — which is the failure this whole
    file exists to stop.
    """
    if log is None:
        out = subprocess.run([str(ROOT / "ci" / "smoke.sh")], capture_output=True, text=True).stdout
        source = "the suite, run here"
    elif not log.is_file():
        return None, f"no suite log at {log} — the step that runs the suite has to write one"
    else:
        out = log.read_text(encoding="utf-8", errors="replace")
        source = str(log)
    match = re.search(r"(\d+) checks", out)
    if not match:
        return None, f"could not read the suite's own total from {source}"
    return int(match.group(1)), source


COUNT_HOME = "CONTRIBUTING.md"


def stated_counts(prose: str, log: Path | None) -> list[str]:
    """The check total the documents state, against what the suite actually has.

    This project has published a wrong one four times in a single working day.
    It is a number, it is checkable, and by its own rule that makes it a gate
    rather than a habit.

    It also lives in exactly ONE document, and that half is enforced here too.
    It used to be in four. Every change that added a check edited four
    documents that had nothing to do with it, and two branches that both added
    one conflicted on four lines whose resolution was neither side's number but
    the sum — which happened between two unrelated fixes in one day.

    `CONTRIBUTING.md` holds it because that is where somebody who is about to
    run the suite reads. The others say what is covered, which is the part a
    reader can actually use: a total grows when a check is split and says
    nothing about what it covers.
    """
    problems = []
    home_path = ROOT / COUNT_HOME
    # Only where there is a home to compare against. A tree with no
    # CONTRIBUTING.md has not chosen a place for the number, and a gate that
    # invents the requirement would fail every small documentation set that
    # states a total once, correctly, in its only file.
    elsewhere = (
        sorted(
            d
            for d in DOCS
            if d != COUNT_HOME and (ROOT / d).is_file() and re.search(COUNT, (ROOT / d).read_text(encoding="utf-8"))
        )
        if home_path.is_file()
        else []
    )
    if elsewhere:
        problems.append(
            f"the check total is stated in {', '.join(elsewhere)} as well as {COUNT_HOME}; "
            f"it belongs in {COUNT_HOME} alone, and the others say what is covered instead"
        )
    # Without a home, the total is read wherever it is stated — which is what
    # this did before the number was given one place to live.
    home = home_path.read_text(encoding="utf-8") if home_path.is_file() else prose
    stated = {int(m) for m in re.findall(COUNT, home)}
    if not stated:
        return problems
    actual, source = suite_total(log)
    if actual is None:
        return problems + [source]
    return problems + [
        f"the documents say {s} checks; the suite has {actual} ({source})" for s in sorted(stated) if s != actual
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--counts", action="store_true", help="also check the check totals the documents state")
    parser.add_argument(
        "--suite-log",
        metavar="PATH",
        type=Path,
        help="read the suite's total from this log instead of running the suite again",
    )
    args = parser.parse_args()
    if args.suite_log and not args.counts:
        parser.error("--suite-log only means anything with --counts")

    prose = "\n".join((ROOT / d).read_text(encoding="utf-8") for d in DOCS if (ROOT / d).is_file())
    known = subcommands()
    # Two spellings count, because both are how these documents actually name a
    # command: `deck impact` in a line someone would type, and a bare `impact`
    # in the table that lists the surface. A bare word anywhere in prose does
    # not — it has to be code-formatted, or the check passes on coincidence.
    missing = [
        c
        for c in known
        if c not in EXEMPT and not re.search(rf"deck {re.escape(c)}[ `\n]", prose) and f"`{c}`" not in prose
    ]
    gone = sorted(offered_commands(prose) - set(known))
    dangling = dangling_paths(prose)
    # TRACKER_FIELDS names deck's own tracker providers, so it means nothing
    # against a tree that is not deck — the synthetic sandbox this script's own
    # test builds, to prove the *general* mechanics work, is exactly that kind
    # of tree. Guarded the way the rest of this file stays generic: on whether
    # the code these fields describe is actually there to drift from.
    fields = missing_tracker_fields(prose) if (ROOT / "plugins/deck/deck/trackers.py").is_file() else []
    counts = stated_counts(prose, args.suite_log) if args.counts else []

    if missing:
        print(f"{len(missing)} command(s) the documents never name:")
        for name in missing:
            print(f"  deck {name}")
        print("\nA command nobody wrote down is a command nobody finds. Name it in")
        print(f"one of: {', '.join(DOCS)}")
    if gone:
        print(f"\n{len(gone)} command(s) the documents offer that `deck --help` does not have:")
        for name in gone:
            print(f"  deck {name}")
        print("\nEither the command was renamed or removed and the documents still")
        print("offer it, or it is a typo. Fix the document, not this check.")
    if dangling:
        print(f"\n{len(dangling)} file(s) the documents point at and are not there:")
        for path in dangling:
            print(f"  {path}")
    if fields:
        print(f"\n{len(fields)} tracker field(s) the documents never name:")
        for name in fields:
            print(f"  {name}")
        print("\nA field nobody wrote down is a field nobody finds. Name it in PACKS.md,")
        print("beside the tracker source it belongs to.")
    for problem in counts:
        print(f"\n{problem}")

    if missing or gone or dangling or fields or counts:
        return 1
    print(f"every command is named and every path exists ({len(known)} commands checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
