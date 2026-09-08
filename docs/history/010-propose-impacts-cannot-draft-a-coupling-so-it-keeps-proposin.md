# #10 — propose impacts cannot draft a coupling, so it keeps proposing the cycle

**closed** · feature · opened 2026-09-06 · closed 2026-09-06

---

**As** someone mapping a workspace with help
**so that** the drafter has vocabulary for the relationship that fixes what it keeps proposing.

Repository: `deck`

`couples:` exists in the descriptor. `assist.impacts_prompt()` and `cmd_propose_apply` know only `impacts:`. A model asked to map a workspace will keep proposing the cyclic pair that `doctor` then refuses, with no way to say the thing that would resolve it — which is exactly what happened on the real workspace that motivated `couples:` in the first place: the drafter found both directions, had to discard one, and wrote the discarded half as prose.

### Acceptance
- [ ] the impacts prompt can propose a coupling, and says when a coupling is right rather than an edge
- [ ] `propose apply` writes `couples:` as well as `impacts:`
- [ ] a proposal that names both directions between one pair is drafted as a coupling, not refused as a cycle

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#10.json, and `deck bundle --task #10` reports READY. The commit naming this issue is attributed to it by the bundle.
