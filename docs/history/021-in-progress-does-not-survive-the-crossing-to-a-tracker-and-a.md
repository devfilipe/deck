# #21 — in-progress does not survive the crossing to a tracker, and a claim leaves no trace deck can read

**open** · feature · opened 2026-09-06

---

**As** anyone reading a board that lives in a tracker
**so that** a task somebody has taken looks different from one nobody has.

Repository: `deck`

deck has three states: `open`, `in-progress`, `done`. A GitHub issue has two. `fetch_github` maps them `"done" if state == "closed" else "open"`, so `in-progress` cannot be expressed and never comes back.

The consequence is not theoretical. Four issues were claimed here, correctly, with the assignee written to GitHub and verified there:

```
$ gh issue view 5 --json assignees --jq "[.assignees[].login]"
["devfilipe"]

$ deck board list
  [ ] #5   gate record writes from_level: null for a gate declared without one
  [ ] #6   A toggle choice carries its reason, and the bundle does not show it
```

Still `[ ]`. deck reads the assignee — `_task()` carries it — and neither the list nor the state uses it. A second person running `board plan` is told all four are free.

`board claim` refuses a task someone else already holds. Against a tracker, that guard has nothing to hold on to.

Directions, none decided:

- **Derive the state from the assignee.** Assigned and open is `in-progress`. Costs nothing, needs no convention, and is wrong for a team that assigns before starting.
- **Write a label on claim**, and read it back — `in-progress`, or whatever the source names in the descriptor. Explicit and visible in the tracker's own UI, and it means deck writes a second thing on claim, which can fail separately (see #20).
- **Say the source cannot express it.** `board list` marks tasks from a two-state source so nobody reads `[ ]` as "nobody is on this". Cheapest, and stops the loss being silent.

Whatever else is chosen, the third is the floor: at minimum `board list` should show the assignee it already has, so a claimed task is not indistinguishable from a free one.

Related: #15 (a tracker carries no acceptance criteria), #4 (claim writes a shell login), #20 (claim reports an assignment that did not happen). All four are the same shape — the crossing from a file board to a tracker loses something and says nothing.

### Acceptance
- [ ] a task somebody holds is visibly different from one nobody holds, in `board list` and in `board plan`
- [ ] `board claim` refusing a task someone else holds works against a tracker, or says plainly that it cannot
- [ ] whatever a state maps to, the mapping is written where someone choosing a tracker will read it
