# #18 — board plan conflicts by repository, so many tasks in one repository never parallelise

**open** · feature · opened 2026-09-06

---

**As** someone with a queue of small tasks in a single repository
**so that** work that genuinely does not overlap is not serialised for want of a finer question.

Repository: `deck`

`board plan` decides what may run together from `board.closure()`, which is a set of repositories. Every task in this repository declares `repos: [deck]`, so every pair overlaps and the plan is seventeen groups of one.

That is correct at the granularity deck has. It is also the whole cost: measured on this board, seventeen tasks in series against four at a time is roughly four-to-seven hours against one-and-a-half-to-two.

Six of the current issues touch six different files — `gates.py`, `bundle.py`, `toggles.py`, `cli.py`, `workspace.py`, `doctor.py`. Nothing about them collides except two files that **every** task touches: `ci/smoke.sh`, where each adds checks, and the stated check total in four documents. Those are real conflicts and mechanical ones.

**The asymmetry any change has to keep.** Saying "these cannot run together" when they could costs time. Saying "these can" when they cannot corrupts somebody's work. deck currently errs the safe way, and that is worth more than the parallelism — a finer answer must be *derived*, never guessed.

Directions, none decided:

- **A task declares the paths it expects to touch**, and closure intersects those before falling back to repositories. Honest, and it asks an author to predict — a prediction that is wrong in the dangerous direction is exactly the failure above.
- **Derive it from what the task already names.** A tracker issue has no field for it; a tasks file could carry `paths:`. Same prediction problem, better placed.
- **Keep the coarse answer and say what it cost.** `plan` reports that these tasks share only a repository and no evidence of a real overlap, so a person can decide to run them together with eyes open. Cheapest, changes no guarantee, and moves the judgement to where the knowledge is.
- **Leave it.** Serial is safe, and a queue of seventeen tasks in one repository may be the unusual case rather than the one to design for.

Note that the two files that actually collide are conventions of this repository, not of deck: a shared check script and a number restated in four documents. Issue #17 is about the second of those, and fixing it removes half of this collision.

### Acceptance
- [ ] whatever is decided, a plan never says two tasks may run together unless something establishes it — never a default, never a guess
- [ ] a person can see why two tasks were put in separate groups, so a coarse answer is legible rather than mysterious
- [ ] the existing behaviour on a board whose tasks span repositories is unchanged
