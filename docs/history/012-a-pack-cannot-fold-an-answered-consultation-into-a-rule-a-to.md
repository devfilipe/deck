# #12 — A pack cannot fold an answered consultation into a rule, a toggle or a gate

**closed** · feature · opened 2026-09-06 · closed 2026-09-07

---

**As** a team that answered a hard question once
**so that** the answer becomes knowledge the next task inherits, instead of a transcript.

Repository: `deck`

Named in FOUNDATIONS.md §4 as a gap: `deck ask` records the question and the answer and names the artifact the answer looks like, and nothing folds it in. Turning one answer into a toggle, a rule or a gate is a judgement about whether it recurs — which is exactly why deck does not do it automatically, and also why there is no command to do it deliberately.

Four consultations on a real workspace were answered by work and resolved by hand today. Each one had an obvious home in a pack and no path to it.

### Acceptance
- [ ] an answered consultation can be turned into a rule, a toggle or a gate in a named pack, by a command
- [ ] the resulting artifact carries the consultation it came from, so the reasoning survives
- [ ] deck never folds one in on its own — the judgement stays with a person, and the command says so
