---
paths: ["**/*.md", "**/*.py", "**/*.yaml"]
---

# Writing, in code and in documents

Everything deck prints is read by someone deciding whether to trust it.

## Never state a number you did not measure

No "typically three repositories", no "most teams", no invented percentage. If a
figure is not counted, from the code or from a run, it does not go in. This has
gone wrong before and it is the fastest way to lose a reader.

## Comments carry the reason, not the restatement

A comment that says what the next line does is noise; the line already says it.
Write down what a reader cannot recover: why this and not the obvious
alternative, what broke when it was done the other way, which caller depends on
this exact shape. Docstrings on non-obvious functions carry the design decision.

## Messages tell the operator what to do next

Every problem `deck doctor` reports comes with the command or the edit that
resolves it. An error that names a condition without a next step is unfinished.

## Say what did not happen

A gate that never ran is reported, not omitted. A stub is labelled a stub. A
partial result is partial in the first sentence, not in a caveat at the end.

## A user-visible change updates the documents in the same commit

README, WALKTHROUGH, DESIGN, FOUNDATIONS and PACKS describe what deck does. A
command added, renamed or removed without them is a document that has started
lying, and documents drift in one direction only: they never become true again
on their own.

Half of this is now a gate. `docs` fails when a command the CLI exposes is named
in none of them — a fact a machine can check, so by this project's own rule it
is checked rather than remembered.

The other half is yours, and no gate will ever reach it:

- **A count is measured, not recalled.** Check numbers before writing them; the
  suite total and the always-on token cost have both been wrong in a document
  while every command was present.
- **A claim about what the tool does is exercised before it is written.** "It
  refuses X" and "it warns about Y" have both been written here about behaviour
  that did not exist yet.
- **A behaviour that changed is hunted in every document, not the one you are
  editing.** A renamed flag lived on in a skill and in the console for a day
  after the rename, because both were somewhere the person renaming was not
  looking.
