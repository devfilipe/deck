---
paths: ["**"]
---

# The shape of a commit here

A subject line in Conventional Commits, and a trailer naming the issue when one
exists. Both are checked by the `commit-shape` gate, so neither is a matter of
remembering.

```
fix: compare which board a scope names, not who is asking for it

<body: what was wrong, and why this is the fix>

Closes #49
```

**Subject.** `<type>[(scope)][!]: <what changed>` — one of `feat`, `fix`,
`refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`. Present tense, no
trailing full stop, and it says what the change *does* rather than what area it
touched: `fix: the Jira reader calls the endpoint that exists` beats
`fix: trackers`. The `!` marks a break in something someone else depends on.

**The issue goes in a trailer, not the subject.** History here has it both ways —
`fix: #39 — the suite is the same size on every machine` puts it in the subject,
`Closes #49` puts it in a trailer — and one of them has to win. The trailer wins:
GitHub closes the issue from it, the subject stays readable in `git log --oneline`,
and a commit answering no issue then looks no different from one that does.
Use `Closes #N` when the commit ends the issue, `Refs #N` when it only touches it.

**A commit with no issue is fine.** Most are. The gate asks for a trailer only
when the branch name carries a number (`fix-49`), because that is the case where
forgetting it is an accident rather than a choice.

**And it asks the branch, not each commit.** An issue is closed once. One
`Closes #N` anywhere in the branch satisfies it — the forge composes the
squashed message from all of them, so it reaches `main` exactly once either
way. A subject, by contrast, is a property of each message and is checked as
one.

## The body carries the reason

The subject says what changed; the body says what was wrong. A body that
paraphrases the diff is worse than no body — the diff is right there. What the
diff cannot show is the failure that motivated it, the thing that was tried
first, or the reason an obvious simpler fix does not work.

State what was measured, never what was assumed. `648 checks` because the suite
printed it; not "all tests pass" because it seemed likely. This is the same
standard [[prose]] sets for everything else deck prints.

## One change, one commit — and no force push

After `0.1.0`, work reaches `main` through a pull request. No force push to
`main`, no direct commit to it — the branch protection is the mechanism, and
this is the reason: a tag people can build against stops being one the moment
its history moves under them.

Inside a branch, amending and rebasing are yours to do freely until the pull
request has a review on it. After that, add commits rather than rewriting: a
reviewer who comes back to a rewritten branch cannot tell what changed since
they left.
