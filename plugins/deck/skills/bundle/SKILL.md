---
name: bundle
description: >
  Assemble the merge-readiness bundle for a task: what changed, how far it was
  verified, what was decided, what is still uncommitted or still placed, and the
  file behind every claim. Use before reporting a task done and before handing
  work to a reviewer.
when_to_use: >
  "is this ready to merge", "write it up for the PR", "what should the reviewer
  know", "am I done", "hand this over".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# The merge-readiness bundle

A reviewer of a multi-repository change has to answer five questions, and a diff
answers one of them. This assembles the other four from what deck already
recorded.

```bash
deck bundle --task X            # read it here, before saying anything is done
deck bundle --task X --write    # markdown under .deck/bundles/, for the PR
deck bundle --task X --json     # for a workflow
```

It exits **non-zero while anything is in the way**, which is how it is worth
running at all: the exit code is the answer, not the prose.

## What it separates, and why that is the whole point

**Blockers** are things that make the change un-mergeable as it stands: no gate
record under this task, a gate that failed or could not run, a change set nobody
can attribute, uncommitted work, artifacts deck placed and never took back. Each
one comes with the command that resolves it.

**Qualifiers** are true and do not block: the rungs the ladder never attempted,
a rung it climbed to that holds no gate, a rung whose gates were all weighed
against this change and none of them applied, a repository the change reaches
that ended up with no commit, questions raised and still unanswered, commits
not pushed. A reviewer reads these; they are not failures.

Never move something from the second list to the first, or the other way, in
your own summary. The distinction is the bundle's judgement, and restating it
loosely is how "one repository in the chain has no commit" becomes "done".

## The two ways a change set is attributed

| Basis | What it means |
|---|---|
| commits whose message names the task | exact — the commit says so itself |
| commits since the task was first mounted | the **window**: everything committed there meanwhile, by anyone |

`requirement_link: required` is the decision that buys the exact basis, because
it already means "the plan and the commit message must cite the item". Under it,
a change set that could only be built from a window is a blocker. With it `off`,
the window is expected and the bundle says which basis it used — so report the
basis too, rather than the file counts alone.

Where a pack declares `delivery_trailer`, each delivery is listed by that trailer
with the commit it is at now beside it. **Quote the trailer, not the hash**: the
hash is what the work is called until the next patchset amends it, and a reviewer
reading your report after that round will not find it.

## Rules

1. **Run it before `deck board done`, not after.** `done` checks that gates
   passed; the bundle checks everything else, and it is cheaper to fix here.
2. **Do not edit a written bundle.** It is derived. Commit, then re-run it.
3. **Report what it says, not a summary of the summary.** If it says NOT READY,
   that is the headline, and the blockers are the reason — not a caveat at the
   end of a report that opens with what went well.
4. **It does not read the code.** It says what was verified and what was
   decided. Whether the code is right is still a review's job.
5. **Report a decision's reason, or report that it has none.** Each decision
   carries the sentence whoever chose the value recorded with `--why`, and says
   "not recorded" where nobody did. Do not close that gap with your own guess at
   why a value was picked: an invented reason is the one thing on this page that
   no file backs.
