# #39 — The suite has a variable size and the documents state a fixed number

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone reading a red CI on a change that is fine
**so that** the check total means the same thing on every machine that runs it.

Repository: `deck`

The first pull request this repository ever ran CI on failed, on this:

```
the documents say 609 checks; the suite has 607
```

Nothing was wrong with the change. Two checks are inside `if command -v claude`:

```bash
if command -v claude >/dev/null; then
  check "marketplace valid" …
  check "plugin valid"      …
else
  printf "  ..  claude not on PATH — manifest validation skipped\n"
fi
```

`claude` is on a contributor's machine and not on a GitHub runner, so the suite is 609 locally and 607 in CI. The documents can only state one number.

This has been true since those checks were written. It surfaced now because the documents gate started running in CI, which is the gate working — it caught a claim that is not true everywhere, which is exactly what it is for.

Three ways, and they are not equivalent:

- **Count what was skipped.** The total becomes `607 checks (2 skipped: claude not on PATH)`, and the documents state the unconditional number. Honest, and it makes the skip visible rather than silently absorbed — a skipped check is currently one line of yellow among six hundred.
- **Make the suite unconditional.** Anything that cannot run everywhere moves out of `smoke.sh` into a separate script CI and contributors run when they can. Cleanest, and it costs a second entry point.
- **State a range or a floor.** `at least 607` in the documents. Cheapest, and it gives up the property that made this gate worth having: an exact number that drifts is caught, a floor that drifts is not.

The second is probably right and the first is probably enough. What is certainly wrong is the current state, where a green local run and a red CI run disagree about a number both are reporting correctly.

Worth noting for whoever takes it: `docs-cover.py` learns the real total by reading the suite's own output, so whatever the suite decides to print is what the gate compares against. The fix is in what the suite says about itself, not in the gate.

### Acceptance
- [ ] a contributor with every tool installed and a CI runner without them agree about the number the documents should state
- [ ] a check that could not run is visible in the total, not only as a line in the scroll
- [ ] the gate keeps catching a stale number, which is the thing it exists for
