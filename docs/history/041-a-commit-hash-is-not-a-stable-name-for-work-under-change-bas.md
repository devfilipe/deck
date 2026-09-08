# #41 — A commit hash is not a stable name for work under change-based review

**open** · feature · opened 2026-09-06

---

**As** a team whose review is a change that takes patchsets
**so that** amending a commit does not move the ground under the evidence deck recorded.

Repository: `deck`

`bundle` attributes work to a task by grepping commit messages for the task id, and reports the commits it found by hash. That works on a branch-and-merge flow, where a commit is written once.

Under change-based review it is written many times. A change is pushed for review, a reviewer asks for something, and the second round is `git commit --amend` on the same change — new hash, same work. The stable name for the work is a `Change-Id:` trailer that the server's `commit-msg` hook writes and nobody edits; the hash is not stable and was never meant to be.

So a bundle written before a round of review names commits that no longer exist, and a bundle written after names different ones for the same delivery. Neither is wrong about what it saw. Both are wrong about what the delivery *is*.

deck already has the shape for this. `ext_provider`/`ext_id` exist precisely so a task can carry the identity it has in the system it came from, and the board reconciles the two rather than showing one piece of work twice. A change identity is the same idea one layer down: the identity a *delivery* has in the system that will land it.

Worth noting what is **not** broken, since I first assumed it was: the local commit exists throughout. It is made normally and then pushed to a review ref, so `bundle` finds it and attribution works today. The gap is narrower and more specific — the name it reports is one that changes.

What to settle:

- **Whether deck reads a trailer at all.** `Change-Id` is one convention of one family of servers; `requirement_link` is already the toggle that says a delivery must cite something. A pack declaring *which trailer names the delivery* keeps the engine free of any one server, and is probably the same mechanism #40 needs.
- **What the bundle says when it finds one.** "Three commits" and "one change, three patchsets" describe the same work to different readers, and the second is what a reviewer on such a server is looking at.
- **Whether an amended commit invalidates gate evidence.** A ladder ran against a tree; an amend produces a different tree. Today nothing notices. That may be right — the evidence records what it ran on — but it is not stated anywhere.

### Acceptance
- [ ] a delivery identified by a trailer is reported by that identity, not only by hashes that change
- [ ] which trailer, if any, is a pack's to declare, not the engine's to assume
- [ ] a workspace with no such convention behaves exactly as it does now
