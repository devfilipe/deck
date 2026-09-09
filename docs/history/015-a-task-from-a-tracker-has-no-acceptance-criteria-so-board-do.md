# #15 — A task from a tracker has no acceptance criteria, so board done cannot ask for any

**open** · feature · opened 2026-09-06

---

**As** someone whose board lives in a tracker
**so that** moving the board off a file does not quietly remove the half of the definition of done that the ladder cannot decide.

Repository: `deck`

`board done` refuses to close a task while a declared acceptance criterion is unaccepted — `if criteria and not args.force`. A task read from a tracker arrives with none: `trackers._task()` carries `id, title, status, repos, url, assignee, labels`, and nothing else. So the guard is skipped entirely and the task closes on the ladder alone.

That is not an oversight in `done`; it is `done` being exactly as strict as its source allows. The source is what got poorer. A file board carries `as_a`, `so_that` and `acceptance`; a GitHub issue carries a title and a body. Measured here: fourteen issues were written with `**As**`, `**so that**` and an `### Acceptance` checklist in the body, and `deck board show` displays none of them.

The consequence is the one FOUNDATIONS.md warns about in the comment right above that guard: closing without criteria is the commonest way a green delivery still fails the person who wanted it. Anyone migrating a working file board to a tracker loses that guard and is not told.

Three directions, none obviously right:

- **Read them from the body.** A checklist in an issue is already a convention (`- [ ]`), and GitHub renders it. Cheap, and it means deck parses somebody else's prose — which this project generally refuses to do.
- **Reconcile with a local file.** The board already reconciles a tasks file with a tracker by `ext_provider`/`ext_id`; the criteria could live in the file and the state in the tracker. Honest, and it means two places again.
- **Say so and stop.** `done` on a task with no criteria states that its source carries none, so the closure rests on the ladder alone. Changes nothing mechanically, and stops the loss being silent.

The third is the floor: whatever else is decided, this must not pass without a word.

### Acceptance
- [ ] closing a task whose source carries no criteria says so, in the report and in the bundle
- [ ] a file board keeps refusing exactly as it does today
- [ ] if criteria can come from a tracker, the shape they are read from is documented where someone writing an issue will see it
