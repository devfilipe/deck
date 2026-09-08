# #14 — Nothing checks that two people carve a product into the same scopes

**closed** · not-covered · opened 2026-09-06 · closed 2026-09-06

---

**As** a team using scopes to divide a product into initiatives
**so that** two people do not silently disagree about what an initiative contains.

Repository: `deck`

Named in FOUNDATIONS.md §4. `scopes:` lives in `.deck/workspace.yaml`, which is per machine and not versioned, so how a product is carved up is not shared by the descriptor. A pack's `templates/workspace/workspace.yaml` can ship the carve-up, which makes it the team's — and nothing checks that what is on this machine matches it.

The failure is quiet by construction: two people run the same command in the same named scope and act on different sets of repositories.

### Acceptance
- [ ] a scope that differs from the one its pack ships is reported, naming both
- [ ] a workspace with no pack-shipped scopes is not accused of anything
- [ ] the report says which one deck is using, since it must keep working either way

---

**Comment** · 2026-09-06

Verified under the deck ladder: 5 gates passed, evidence in .deck/gates/#14.json, and `deck bundle --task #14` reports READY.
