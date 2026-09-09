#!/usr/bin/env python3
"""Every commit not yet on main carries the shape this repository requires.

Checks the half a reviewer should not have to spend attention on: a Conventional
Commits subject, and an issue trailer when the branch name says the work answers
an issue. It says nothing about whether the message is any good — that is a
reviewer's job.

Scope is the commits ahead of main, so it never re-judges history somebody has
already accepted.
"""

from __future__ import annotations

import os
import re
import subprocess

TYPES = ("feat", "fix", "refactor", "perf", "test", "docs", "build", "ci", "chore")
SUBJECT = re.compile(rf"^({'|'.join(TYPES)})(\([a-z0-9][a-z0-9._-]*\))?!?: \S.*[^.]$")
ISSUE = re.compile(r"^(Closes|Fixes|Refs) #\d+$", re.M)


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, text=True)


def base() -> str | None:
    for ref in ("origin/main", "main", "@{upstream}"):
        if git("rev-parse", "--verify", "-q", ref).returncode == 0:
            return ref
    return None


def branch_name() -> str:
    """The branch the work is on, which in CI is not what git reports.

    A pull request is built at a detached merge commit, so `--abbrev-ref HEAD`
    answers `HEAD` and the issue number in the branch name is gone — the gate
    would then quietly check less on the pull request than it did locally, which
    is the worst place for a gate to relax. GitHub keeps the real name in
    `GITHUB_HEAD_REF`; `DECK_BRANCH` lets any other runner say so too.
    """
    for key in ("DECK_BRANCH", "GITHUB_HEAD_REF"):
        if os.environ.get(key):
            return os.environ[key]
    return git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()


def branch_issue() -> str | None:
    """The issue number the branch name carries, if it carries one.

    `fix-49` and `49-board-identity` both name issue 49. A branch with no number
    is work that answers no issue, which is most of them, and asking it for a
    trailer would train people to invent one.
    """
    name = branch_name()
    found = re.search(r"(?:^|[^0-9])(\d+)(?:[^0-9]|$)", name)
    return found.group(1) if found else None


def main() -> int:
    ref = base()
    if ref is None:
        # Nothing to compare against is not a pass and not a failure: there is
        # no range to judge, and saying so beats inventing one.
        print("no main to compare against — nothing to check")
        return 0

    # `--no-merges` rather than a pattern on the subject. A merge commit is
    # written by the forge, not by a contributor, and holds none of this shape —
    # but its subject is whatever the forge felt like: `Merge pull request #48
    # from x/y` locally and `Merge <sha> into <sha>` on the ephemeral commit a
    # pull request is built at. This gate failed on its own first pull request
    # for exactly that reason. Having more than one parent is the fact; the
    # wording of the subject is a guess about it.
    shas = [h for h in git("log", "--no-merges", "--format=%H", f"{ref}..HEAD").stdout.split() if h]

    # And no root commit, for the same kind of reason `--no-merges` is there:
    # having no parent is the fact, not a guess about the wording. A commit with
    # no parent is not a change — there is nothing it changed relative to — so
    # `<type>: <what changed>` has nothing to describe, and this repository's own
    # root commit says what the tree IS rather than what it did.
    #
    # It matters because the range is `main..HEAD`, which assumes a shared base.
    # A history rewritten to a single commit shares none, so everything looks
    # like work in hand and the gate judged the commit that was about to BECOME
    # main. Measured: it failed on exactly that, with `subject is not
    # Conventional Commits: 'deck — a control plane for coding agents...'`.
    shas = [h for h in shas if len(git("rev-list", "--parents", "-n", "1", h).stdout.split()) > 1]
    wanted = branch_issue()
    problems: list[str] = []
    judged = 0

    # A subject is a property of each message; the issue trailer is a property
    # of the branch. An issue is closed once, and a `Closes #N` on every commit
    # of a branch is noise the gate would be training people to write — it did,
    # to the author of this line, on the second commit of a two-commit branch
    # whose first already carried it. Squash-merge settles the rest: the merged
    # message is composed from the branch's, so a trailer anywhere in it reaches
    # main exactly once either way.
    closed = False
    for sha in shas:
        msg = git("log", "-1", "--format=%B", sha).stdout
        subject = msg.split("\n", 1)[0].strip()
        judged += 1
        if not SUBJECT.match(subject):
            problems.append(f"{sha[:8]} subject is not Conventional Commits: {subject[:60]!r}")
        closed = closed or bool(ISSUE.search(msg))

    owes_trailer = bool(wanted) and judged > 0 and not closed
    if owes_trailer:
        # The branch is the subject of this one, so the branch is what it names.
        # Accusing whichever commit happened to be last would send somebody to
        # amend a message that is no more at fault than any other.
        problems.append(
            f"no commit on `{branch_name()}` carries a `Closes #{wanted}` trailer — "
            f"the branch name says the work answers issue {wanted}"
        )

    if problems:
        print(f"{len(problems)} problem(s) in {judged} commit(s) ahead of {ref}:\n")
        for p in problems:
            print(f"  {p}")
        print("\n  <type>: <what changed>, no trailing stop, present tense.")
        print(f"  types: {', '.join(TYPES)}")
        if owes_trailer:
            # Only when the trailer is what is missing. Printed beside a bad
            # subject on a branch that already closes its issue, it reads as a
            # second fault and sends somebody to fix what is not broken.
            print(f"  the issue goes in a trailer, on one commit: Closes #{wanted}")
        print("\nAmend rather than adding a commit that fixes the message of another.")
        return 1

    if not judged:
        print(f"nothing ahead of {ref} to check")
        return 0
    where = f", and the branch closes #{wanted}" if wanted else ""
    print(f"{judged} commit(s) carry a Conventional subject{where}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
