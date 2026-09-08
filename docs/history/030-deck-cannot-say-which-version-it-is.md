# #30 — deck cannot say which version it is

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone reporting something deck did
**so that** the first question — which version — has an answer that is not "read the source".

Repository: `deck`

`plugins/deck/deck/__init__.py` carries `__version__ = "0.1.0"` and nothing exposes it. There is no `deck --version`, the parser has no such flag, and no other command prints it. The repository has no tags either, so a clone cannot be placed by `git describe`.

That is tolerable while the only user is the author and the only tree is one force-pushed commit. It stops being tolerable at the moment of the 0.1.0 tag, which is when somebody else can have a copy that is not the newest one, and when a bug report has to say which copy.

Three surfaces plausibly want it and they are not the same want: `--version` for a person at a terminal, the version in `deck doctor`'s header for a diagnosis someone pastes into an issue, and the version in `deck bundle` for a merge-readiness page that outlives the tree it was written from. Decide which of the three earn it.

Worth settling in the same change: where the number lives. It is in `__init__.py` today and also has to be in the plugin manifest for Claude Code; two places holding one number is how they drift, and this project has already lost that argument once over a check total stated in five documents and gated in four.

### Acceptance
- [ ] `deck --version` answers, and the answer is the version the package carries
- [ ] the number has one home, and anything else that needs it reads from there
- [ ] a check covers it, so the release after this one cannot ship saying the wrong number

---

**Comment** · 2026-09-06

Fixed. `deck --version` answers, and `deck doctor` carries it in its `tools` block, because a diagnosis is what somebody pastes into a report.

The number has one home: the plugin manifest, which Claude Code reads without running anything, so the package reads it from there. A check compares the two so they cannot drift, and a clone whose manifest is missing reports `unknown` and fails the diagnosis rather than inventing a plausible number.

Verified under the ladder: 5 gates passed, bundle READY.
