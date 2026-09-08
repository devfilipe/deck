# #11 — scope_leaks reads impacts and not couples, so scopes and impact disagree

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** someone working inside a scope
**so that** every surface answers the same question the same way.

Repository: `deck`

`scope_leaks()` walks `impacts:` only. A scope that owns one half of a coupled pair and not the other does not report the other half as reached, so `deck impact` names the coupling and `deck scopes` does not.

Both are consistent applications of the boundary chosen in the change that added `couples:` — `mount` expands over couplings, `board.closure()` does not — but the inconsistency between two surfaces a person reads side by side is real, and one of them is wrong.

### Acceptance
- [ ] a scope that reaches half a coupled pair reports the other half, or states why it does not
- [ ] `deck impact` and `deck scopes` agree about what a coupling reaches
- [ ] the rule, whichever it is, is written where someone deciding a scope boundary reads it

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#11.json. The commit naming this issue is attributed to it by `deck bundle`, which reports READY.
