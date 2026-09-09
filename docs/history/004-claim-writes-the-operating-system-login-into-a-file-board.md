# #4 — claim writes the operating-system login into a file board

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** someone whose work login is not the name they publish under
**so that** taking a task does not put a corporate username into a public repository.

Repository: `deck`

`cmd_board.py` resolves the claimant as `--who`, then `$DECK_USER`, then `$USER`. For a tracker that is nearly right — the account acting is the account that authenticates. For a file board it is wrong: the file is committed and published, and `$USER` is whatever the machine calls you.

Found on this repository, which had seven `assignee:` lines carrying a shell login headed for a public push under a different identity; they were corrected by hand. `consult.py` records `asked_by` and `answered_by` the same way and has the same exposure.

Likely answer is the repository's own git identity, which is already the name every commit carries, with `$DECK_USER` kept as the override — but the tracker case must not regress.

### Acceptance
- [ ] a claim on a file board records the identity the repository is published under, not the shell login
- [ ] where that identity comes from is stated, and a way to override it exists
- [ ] a tracker source keeps using the account that authenticates to it, which is a different question

---

**Comment** · 2026-09-06

Verified under the deck ladder: 5 gates passed, evidence in .deck/gates/#4.json, and `deck bundle --task #4` reports READY.
