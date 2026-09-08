# #24 — A pack seed carries two descriptor keys nothing reads

**open** · bug · opened 2026-09-06

---

**As** somebody reviewing a pack a teammate seeded
**so that** every key in a file the team is asked to review is one that does something.

Repository: `deck`

`cmd_pack.py` seeds the descriptor-level part of a pack template from three keys: `sources`, `container`, `requires_files`.

- `requires_files` is real, read, and documented.
- **`container` appears exactly once in the whole repository — on the line that copies it.** No reader, no writer, and no mention in `plugins/deck/templates/workspace/workspace.yaml`, which documents every field a descriptor can carry.
- **`sources` as a *descriptor* key has no reader either.** `deck pack sources` reads `config/sources.yaml` from a pack, and `bundle.py`'s `sources` is a section of a bundle. Neither is this.

Found while giving the repository-level allowlist a stated rule — *would this value still be true on the next person's machine?* The agent that wrote that rule named this tuple and deliberately left its membership alone rather than guess, which was right.

If they are dead, a seeded template hands a team two keys nobody can explain — the same failure the repository-level allowlist had, from the other direction: that one silently dropped a field that mattered, this one silently carries fields that do not.

Answer three questions in whichever order suits: does anything read them; if not, were they ever read; and if a descriptor should have a `container:` key, that is a feature request and not this.

### Acceptance
- [ ] every key the seed carries at descriptor level has a reader, or is removed
- [ ] the tuple carries the same stated rule the repository-level one now has
- [ ] a check covers each key that stays


---

**Update, after `scopes:` fell out of the same tuple.**

`scopes:` was also missing from `SEEDED_WORKSPACE_FIELDS`, which meant the documented route to making a carve-up the team's did not carry the carve-up — and once scope-divergence reporting landed, `doctor` would call a scope "this machine's own" immediately after the command meant to publish it had run. That one is fixed.

The shape of the failure is the part worth keeping, and it sharpens what this issue is for:

> `SEEDED_REPO_FIELDS` has a comment above it, a documented rule, a table in PACKS.md, and one smoke check per field — an entire apparatus built after `couples` and `downstream` went missing from it. `SEEDED_WORKSPACE_FIELDS` sits three lines below as a bare tuple with a shared preamble and no per-field check. **The rule was there; the enforcement stopped at the tuple boundary.**

So this is not only about two keys that may be dead. It is that one of two adjacent lists is watched and the other is not, and the unwatched one has now lost a field for the same reason the watched one stopped losing them. `sources`, `container` and `requires_files` still have no check of their own.

The `seeded_has` pattern from the repository-level group, extended over the workspace-level tuple, closes it.
