# #17 — Three documents disagreed about whether the board workflow had ever run

**open** · docs · opened 2026-09-06

---

**As** anyone deciding whether to trust what this project says about itself
**so that** a claim about maturity is true in every place it is made, or made in one place only.

Repository: `deck`

`WALKTHROUGH.md` listed the `/deck:board` workflow under **Proven end to end**, with the detail: run twice, eleven agents, four groups, every task committed and green. At the same time `README.md` said it "has not been run end to end against a real board", and `DESIGN.md` said it "has never been run end to end". All three were corrected by hand.

The documents gate catches a command nobody names, a path that does not exist, and a check total that drifted. It cannot catch this: a claim about the state of the work, stated in three places, that stopped being true in one edit and stayed wrong in the other two.

The honest structural fix is probably to state maturity **once** and have the other places point at it, rather than to gate prose. But that is a decision about how these documents are organised, not a lint rule.

### Acceptance
- [ ] the maturity of a feature is stated in one place, and the other documents refer to it rather than restating it
- [ ] or, if it stays restated, something checks the restatements agree
- [ ] the check total, the command list and the file paths keep being gated as they are now
