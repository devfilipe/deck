# #6 — A toggle choice carries its reason, and the bundle does not show it

**closed** · feature · opened 2026-09-06 · closed 2026-09-06

---

**As** a reviewer deciding whether to merge
**so that** the page written for me carries the sentence explaining a decision, not just its value.

Repository: `deck`

`deck toggle set --why` records why a value was chosen, and `toggle explain` shows it under a heading of its own. `bundle.decisions()` still returns `{id, value, source}`, so the merge-readiness page — the one surface written for somebody else to read — says a task ran with `gate_level: build` and not why anyone chose it.

`deck scope <name>` and `toggle list --json` have the same gap.

### Acceptance
- [ ] a decision in the bundle carries the chooser's reason when one was recorded
- [ ] a decision with no reason says so, rather than looking justified
- [ ] the JSON form carries it too, so a consumer is not forced to re-read the toggle file

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#6.json. The commit naming this issue is attributed to it by `deck bundle`, which reports READY.
