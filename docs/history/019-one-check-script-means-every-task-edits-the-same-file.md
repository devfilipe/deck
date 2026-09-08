# #19 — One check script means every task edits the same file

**open** · feature · opened 2026-09-06

---

**As** two people fixing unrelated things at the same time
**so that** work in different parts of deck does not collide in the one file both have to touch.

Repository: `deck`

`ci/smoke.sh` is a single script — over two thousand lines and dozens of `note` groups — and the house rule is that every behaviour change adds a check to it. So every task edits it, whatever it changed, and two tasks in different modules conflict there and nowhere else.

Measured on this board: seventeen open issues touching six different source files, and `board plan` correctly puts every one of them alone. Two files cause that, and this is one. (#17 is the other: a check total restated in four documents. #18 asks whether `plan` should answer at a finer granularity, and would not help here — a finer answer would still say these tasks collide, because they do.)

The script's single-file shape earns something real and any split has to keep it: one command, `./ci/smoke.sh`, that a contributor runs with no arguments and that prints one total. Its own gate compares that total to what the documents state.

Directions, none decided:

- **Split by module** — `ci/checks/gates.sh`, `ci/checks/mount.sh`, `ci/checks/board.sh` — with `ci/smoke.sh` sourcing them and keeping the helpers, the fixture and the total. A task then edits the file for the module it changed. Most of the benefit; the fixture has to stay shared, and that is the part to get right.
- **Split by fixture instead**, if it turns out most groups share workspace setup rather than subject matter.
- **Leave it and merge by hand.** Appending near the same anchor conflicts textually but almost never semantically; a person resolves it in seconds. Honest, and it means the collision keeps showing up in every plan.

Whatever is chosen, the number the documents state must keep coming from one place — a split that produces several totals to add up would trade this problem for a worse one.

### Acceptance
- [ ] `./ci/smoke.sh` still runs everything with no arguments and prints one total
- [ ] a change confined to one module touches one check file
- [ ] the shared fixture and helpers are defined once, not copied per file
- [ ] the docs gate still compares the stated total against the real one, unchanged
