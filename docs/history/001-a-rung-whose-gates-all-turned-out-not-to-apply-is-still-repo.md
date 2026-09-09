# #1 — A rung whose gates all turned out not to apply is still reported as reached

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** a reviewer reading how far a delivery was verified
**so that** a rung where nothing ran reads as unverified, whatever the reason nothing ran.

Repository: `deck`

the change that stopped an empty rung counting as reached stopped an empty rung counting as reached. This is the same defect one layer in: a rung that *has* gates, all of which turned out not to apply — `only_repos` excluded every repository in play, or a `when` toggle did not match — still counts, because the change that stopped the bundle claiming a rung the ladder failed at ruled that a gate which does not apply owes nothing. Nothing was verified there either.

~~Reproduced: with the smoke fixture's build gate declared `only_repos: [b]`, `deck gate run --repos a --level build` reports the ladder as having reached `build` while no build command ever ran.~~

**Correction — that recipe does not reproduce.** `--repos a` expands along the impact chain, so a gate declared `only_repos: [b]` still applies and still runs. What does reproduce: a gate whose `only_repos` names a repository that is `downstream: true`, with the gate not setting `include_downstream` — every repository is then filtered out, the gate is weighed and applies to nothing, and the rung still reports as reached.

The tension is the whole task: an inapplicable gate must not **block** the ladder, and must not **count** as verification either. Today one rule serves both and gets the second wrong.

### Acceptance
- [ ] a rung whose every gate was waved through is not reported as reached
- [ ] the bundle says why nothing ran there, so it reads as coverage and not as failure
- [ ] a rung with at least one gate that actually passed is still reported as reached
- [ ] the the change that stopped the bundle claiming a rung the ladder failed at rule that an inapplicable gate does not hold the ladder back is preserved, or its check is changed deliberately and the change is argued

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#1.json, and `deck bundle --task #1` reports READY. The commit naming this issue is attributed to it by the bundle.
