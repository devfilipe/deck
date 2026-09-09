# #3 — A pack seeded from a workspace loses the downstream flag

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** someone turning a working registry into a pack the team can share
**so that** what the seed carries is what the workspace knew, not a subset nobody named.

Repository: `deck`

`cmd_pack.py` filters the seeded registry through an allowlist of keys — `path`, `role`, `build_target`, `lint`, `impacts`, `couples` — and `downstream` is not in it, so every downstream repository comes out of the seed looking like a normal build node. `downstream` is graph knowledge the team owns, not a per-machine path, which is exactly the kind of thing a pack is for.

One word fixes the symptom. The task is to decide what the allowlist is **for**, since an allowlist nobody can state the rule of will lose the next field too.

Related: `--from-workspace` had no smoke coverage at all until recently.

### Acceptance
- [ ] a repository marked downstream in the workspace is still marked downstream in the seeded template
- [ ] the allowlist that decides what a seed carries is stated where someone editing it will read it
- [ ] a check covers each field the seed is meant to carry

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#3.json, and `deck bundle --task #3` reports READY. The commit naming this issue is attributed to it by the bundle.
