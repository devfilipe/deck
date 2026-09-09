# #22 — CI does not run the documents gate, so a stale document passes green

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone reading a green tick on `main`
**so that** the check that catches a document saying something untrue is one CI actually ran.

Repository: `deck`

`.github/workflows/ci.yml` runs the lint, `toggle validate --strict`, the smoke suite, and the tour. It does not run `packs/_workspace/bin/docs-cover.py --counts` — the gate that checks every command is named in the documents, that every path they point at exists, and that the check total they state is the one the suite has.

That gate is declared in the development pack and runs only when someone runs the ladder locally. So the repository has a gate for exactly the failure it keeps having, and its CI does not run it.

Measured over one working day: the stated total drifted three times (433 → 436 → 447 → 471 as work landed), and each time the local ladder caught it. A push in between would have been green.

Worth deciding in the same change: whether CI should run `deck gate run` rather than a list of commands that duplicates what the pack already declares. The pack is the statement of what verifies this repository; `ci.yml` is a second copy of most of it, and the two have already diverged by one gate.

Note the cost, since it is the argument against: `docs-cover.py --counts` runs the suite to learn the real number, so a naive addition makes CI run the suite twice. The number is on stdout of the run CI already does.

### Acceptance
- [ ] a document stating a wrong check total fails CI
- [ ] a document naming a command that does not exist fails CI
- [ ] CI does not run the suite twice to find out
- [ ] whether `ci.yml` keeps its own list or defers to the pack is decided and written down

---

**Comment** · 2026-09-06

Verified under the deck ladder: 5 gates passed, evidence in .deck/gates/#22.json, and `deck bundle --task #22` reports READY.
