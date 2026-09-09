# #8 — A hand-written scope block in the flat shape is silently ignored

**open** · bug · opened 2026-09-06

---

**As** someone writing a scope into the toggle file by hand
**so that** a block deck cannot read is refused rather than skipped without a word.

Repository: `deck`

The shipped template described `scopes: {name: {toggle: value}}` — flat. `layers()` reads only `scopes.<name>.values`, so a scope block written the way the template described resolves to nothing and no message says so. The template comment was corrected in the change that gave a toggle choice a recorded reason; the reader was not.

Decide which: accept the flat shape as a convenience, or refuse it loudly. Ignoring it is the one option that is certainly wrong — this project's rule is that it never guesses and never passes silently over what it cannot read.

### Acceptance
- [ ] a scope block deck cannot read is reported, naming the file and the shape expected
- [ ] `deck toggle validate --strict` catches it
- [ ] whichever shape is chosen, the template and the reader agree
