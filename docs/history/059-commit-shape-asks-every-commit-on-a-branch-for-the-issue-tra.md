# #59 — commit-shape asks every commit on a branch for the issue trailer, when the branch owes it once

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`commit-shape` requires a `Closes #N` trailer on **every** commit ahead of main when the branch name carries a number. A branch with three commits therefore owes three identical trailers.

```
1 problem(s) in 2 commit(s) ahead of origin/main:

  93d0dffc has no `Closes #56` trailer — the branch name says it answers one
```

That commit was the second on a branch whose first commit already carried it.

## Why it is the wrong rule

An issue is closed once. The trailer exists so the forge can close it and so a reader of `git log` can see which work answered what — both satisfied by one commit carrying it. Repeating it on each is noise that the gate is now training people to write.

The rule as documented says the trailer is asked for "only when the branch name carries a number, because that is the case where forgetting it is an accident rather than a choice." Forgetting it on the second of two commits, when the first has it, is not an accident.

It also interacts badly with squash-merge, which is how work lands here: the merged commit's message is composed from the branch's, so a trailer anywhere in the branch reaches `main` exactly once either way.

## Shape

Check the range, not each commit: at least one commit ahead of main carries the trailer. The Conventional subject stays per commit — that one really is a property of each message.

Worth deciding at the same time what the failure should say. Naming a single commit is right for a bad subject; for a missing trailer the subject of the report is the branch, and the message should say so rather than accusing whichever commit happened to be last.

## Acceptance
- [ ] a branch whose commits collectively carry the trailer once passes
- [ ] a branch carrying it nowhere still fails, and the message names the branch rather than one commit
- [ ] a bad subject is still reported against the commit that has it
