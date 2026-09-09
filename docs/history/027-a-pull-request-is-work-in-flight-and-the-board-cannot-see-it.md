# #27 — A pull request is work in flight, and the board cannot see it

**open** · feature · opened 2026-09-06

---

**As** anyone reading the board once changes arrive by pull request
**so that** the half of the work that is in review is not invisible.

Repository: `deck`

`fetch_github` hard-codes `is:issue` into its query, so a pull request never reaches the board and there is no way to ask for one. Today that costs nothing — this repository has no pull requests, deliberately, because until the 0.1.0 tag the published tree is one force-pushed commit and a force push orphans what a pull request points at (see CHANGELOG.md).

From that tag onward it inverts, and immediately: history stops being rewritten, changes arrive by pull request, and a board showing only issues shows half the work.

**Four verbs hide in "support pull requests", and they do not have the same answer.** Deciding them separately is most of the work here:

- **Show.** A pull request is work in flight, and the board answers where the work is and who has it. Yes.
- **Produce.** `deck bundle` already describes itself as "what a reviewer reads instead of the diff" — what changed, which gates passed, which rung the ladder reached, which decisions were in force and where each came from, what is still unanswered. It *is* the body of a pull request, written to `.deck/bundles/` for a person to carry across by hand. Opening the request with that body is a small step from where this already stands.
- **Review.** No. deck names the reviews that have not happened and never performs one; Claude Code already ships code review. A pull-request engine that read diffs and formed opinions would be deck reimplementing the tool next to it.
- **Require.** The interesting one. `bundle` says READY from local evidence; a pull request has its own checks on the remote. Neither knows about the other, so a task can be READY here and red there. A bundle that could see the request would stop the local ladder and the remote one from disagreeing.

**The sharpest argument is about this repository itself.** Eight issues have been closed here by agents working in worktrees: one actor wrote the briefs, integrated the work, ran the ladder and pushed. The bundle said READY and its only reader was the same actor. `bundle` was built to be read by somebody else and never has been — and CI has been configured for `pull_request` since the first commit and has never run on one.

### Acceptance
- [ ] a pull request appears on the board, distinguishable from an issue
- [ ] what a source fetches is a choice in the descriptor, not a constant in the code
- [ ] `deck bundle` can open or update a pull request with itself as the body, and never does so implicitly
- [ ] a bundle can report the state of the request its task belongs to
- [ ] deck still reviews nothing
