# #2 — propose apply writes a pack without --yes, and writes impacts only with it

**open** · bug · opened 2026-09-06

---

**As** someone applying a drafted pack
**so that** the same command does not write in one case and ask in the other, undocumented.

Repository: `deck`

`_apply_impacts` prints a preview and refuses to write until `--yes`. `_apply_pack` writes gates and rules immediately. Nothing documents the asymmetry, and the README's `deck propose apply <file> --yes` line implies both need it. Consultation recording was made consistent with the surrounding code rather than inventing a third behaviour, so this now covers three kinds of write.

Decide which way it goes: a pack write is bigger than an impacts write, which argues for `--yes` everywhere; or an impacts proposal edits the descriptor deck reads first, which argues the asymmetry was deliberate and only needs saying.

### Acceptance
- [ ] the kinds of proposal agree on when a write needs saying yes, or the difference is documented where someone meets it
- [ ] the README's own example of applying a proposal matches what the command does
- [ ] whatever is decided, a check covers it
