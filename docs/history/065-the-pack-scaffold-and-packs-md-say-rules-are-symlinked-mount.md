# #65 — The pack scaffold and PACKS.md say rules are symlinked; mount copies them, deliberately

**open** · — · opened 2026-09-07

---

Three places tell a pack author that `deck mount` symlinks a rule into a repository. `mount.py` does not, and the comment there explains at length why it must not.

The claim:

- `plugins/deck/deck/cmd_pack.py:365` — "a rule is symlinked, so `ls -l` shows where it came from"
- `PACKS.md:30` — "`paths:`-scoped rules, symlinked in on mount"
- `PACKS.md:182` — "a rule is symlinked so its origin is visible"

The code, `plugins/deck/deck/mount.py:355`:

> Copy, never symlink. Claude Code loads `.claude/rules/*.md`, but it does not follow a symlink there: measured with two rules carrying identical `paths:` frontmatter … A symlink fails silently — the mount reports success and the rule reaches nobody.

## Why this one is worth fixing rather than tidying

That comment is the record of a defect that took a controlled experiment to find, because every observable signal said the mount had worked: the file was placed, the manifest counted it, `deck mounts` listed it, and nothing read it. The documentation still describes the broken design as the intended one — so a pack author reading `PACKS.md` today learns the wrong mental model, and the next person to look at `mount.py` finds the code contradicting the manual and has to work out which one is stale.

`cmd_pack.py:365` is worse than the other two: it is a comment written **into every pack** `deck pack new` scaffolds. Every new pack ships with the wrong claim in its `mount.yaml`. The agent updating `deck-acme` found that repository's `mount.yaml` carrying it, inherited from the scaffold, and corrected it there — the source is still emitting it.

## Shape

Say what the code does and why, in each of the three places, briefly. The reason is short and is the whole point: a copy is what the runtime reads, and a symlink is what looks right in `ls -l` and reaches nobody. `mount.py` already has the long version.

Worth checking at the same time whether anything else in the documentation describes mount as reversible-by-link — `unmount` reads a manifest, and the manifest is what makes it reversible, not the link.

## Acceptance
- [ ] no document or scaffold comment says a mounted rule is a symlink
- [ ] the scaffolded `mount.yaml` a new pack ships says what actually happens
- [ ] the reason is stated where it is claimed, not only in `mount.py`
