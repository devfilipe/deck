# #32 — The budget cap stops the loop, not the spend, and the message reads as if it failed

**open** · docs · opened 2026-09-06

---

**As** anyone watching what a proposal costs
**so that** a cap that worked is not mistaken for a cap that did not.

Repository: `deck`

`deck propose impacts` announces `read-only, capped at $1.5` and, when the cap trips, says:

```
deck: the budget cap was reached before an answer came back ($1.6879 spent).
```

Measured on a real workspace of six repositories. A reader sees $1.69 against a stated cap of $1.5 and concludes the cap does not work.

It did work. deck passes `--max-budget-usd` to the tool it calls and relays what comes back; that cap stops the **loop** rather than the **spend**, so the request in flight when it trips is still billed. Nothing here is broken — the announcement and the failure describe the same number as though it were two different things.

Two lines to say it plainly: the announcement should say what the cap governs, and the failure should say the overshoot is the call that was already running rather than leaving the reader to work it out.

Worth deciding in the same change whether `capped at $X` should say `about $X` — a cap that can be exceeded by one request is honest only if it says so where it is claimed, which is the announcement, not the error.

Found during a first real run on a product workspace, which is also worth recording separately: six repositories at once cost more than the default cap. The advice the message already gives — narrow with `--repos` — is right, and it might be worth saying before the money is spent rather than after.

### Acceptance
- [ ] the announcement says what the cap governs, not just its number
- [ ] the failure explains the overshoot rather than reporting it bare
- [ ] neither of them claims something the cap cannot deliver
