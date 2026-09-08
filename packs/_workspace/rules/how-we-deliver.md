---
paths: ["**"]
---

# Getting a change into main

Five gates, then a pull request. `deck gate run --task <branch>` is the whole
local ladder; [[verifying]] says what each one builds. This rule is about the
part after they are green.

## Prove the check fails first

A check added with a fix has to be shown failing without it. Otherwise you have
a check that passes, which is not the same thing as a check that would have
caught the defect — that mistake has been made in this repository more than once,
and both times the check looked fine.

Two failure modes worth naming, because both produce a passing check that
defends nothing:

- **A check that greps for the new wording** passes on the old code for want of
  a match. Assert on the behaviour — the line's severity, the value returned —
  not on the sentence that reports it.
- **A check borrowing a fixture from the group above it** measures whatever the
  previous check left behind. One in `smoke.sh` passed because the workspace had
  already been torn down. Build your own fixture unless sharing one is the point.

## How to run the suite against HEAD

**Never `git stash`.** `refs/stash` is per repository, not per worktree, so an
agent in a sibling worktree pops yours. Copy the file aside and put HEAD's
version in place:

```bash
cp plugins/deck/deck/thing.py /tmp/thing.keep
git show HEAD:plugins/deck/deck/thing.py > plugins/deck/deck/thing.py
./ci/smoke.sh 2>&1 | grep "<your check>"      # expect FAIL
cp /tmp/thing.keep plugins/deck/deck/thing.py
```

For the same reason, never `git checkout -- .` in a tree that might hold work
somebody else has not committed. There is no undo, and it has destroyed an
agent's uncommitted change here.

## Read the exit status, not the pipe's

```bash
./ci/smoke.sh | tail -3 ; echo $?      # tail's status. Always 0.
./ci/smoke.sh > /tmp/out; echo $?      # the suite's status.
```

Every false "it exits 0" claim in this repository's history came from the first
line. Redirect, then read.

## The pull request

After `0.1.0` nothing reaches `main` any other way. The description carries what
a reviewer cannot get from the diff:

- what was wrong, in the terms someone hitting it would use
- the checks added, and the statement that they fail without the change
- which gates ran and what they said — measured, quoted, not summarised
- what you got wrong on the way, if it would mislead the next reader to omit it

A pull request that says every gate is green when one was skipped is worse than
one that says which was skipped and why. Say what did not happen; [[prose]]
makes that a rule for everything deck prints, and a review is no exception.
