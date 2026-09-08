# #5 — gate record writes from_level: null for a gate declared without one

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone reading a gate record, or a function that has to place a gate on the ladder
**so that** a gate that ran at a rung is recorded as belonging to it.

Repository: `deck`

`applicable()` reads `gate.get("from_level", "static")`. `record()` writes `g.get("from_level")`, which is `None` when the key is absent. So a gate declared without a level runs at static and comes back belonging to no rung at all, and `rung_completed()` can neither credit it nor stop on it.

The read side was normalised (`gates.rung_of()`) in the change that stopped an empty rung counting as reached and there is a check for it, because records already on disk carry the null. The write side is still wrong. No gate in this repository or in the smoke fixtures omits `from_level`, so it is latent rather than live.

### Acceptance
- [ ] a gate declared with no `from_level` is recorded at the rung it actually ran on
- [ ] a record written before this still reads correctly, since the null is already on disk
- [ ] a check covers a gate declared without the key

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#5.json. The commit naming this issue is attributed to it by `deck bundle`, which reports READY.
