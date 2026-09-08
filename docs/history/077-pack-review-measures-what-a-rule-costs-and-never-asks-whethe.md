# #77 — pack review measures what a rule costs and never asks whether a machine could decide it

**open** · — · opened 2026-09-08

---

`deck pack review` reports what a pack holds and what its gates have done:

```
anytest-framework   10 rule(s) · 4 skill(s) · 0 toggle(s) · 5 gate(s)
                    ~157 tokens paid in every session, used or not
                    !! gate import-sanity ran 5x and never failed — check it still asserts

gate history
  ruff             ran 4  caught 0  skipped 0
  fast-tests       ran 4  caught 0  skipped 1
```

That is a real audit of a pack against what the workspace recorded, and it already catches a gate that may have stopped asserting. What it never asks is the question deck's own line makes the most important one:

> **If a machine can check it, it is a gate — never a rule.**

A rule costs context every time a matching file is read. A gate costs nothing until it runs. Sorting a finding into the wrong one is, in deck's own words, most of the cost — and `pack review` counts the rules, prices them, and says nothing about whether any of them belongs somewhere else.

## Why it matters more than a nicety

The sorting does not happen once. A rule is written when nobody has the tool yet, the tool arrives a year later, and nothing revisits the rule. deck's own pack carries the proof that this is real: four toggles that were rules wearing a decision's clothes were found by running `pack review` on deck itself — but that check exists for *toggles*, and the rule-to-gate direction has none.

It is also the shape of the architecture gap. An architectural constraint splits in two: "`core/` knows no channel" is judgement and is rightly a rule; "no module under `core/` imports from `access/`" is a command. The second one stays a rule when nobody prompts the question, and then people say deck cannot enforce architecture — when what happened is that the gate was never written.

## Shape

A heuristic, reported as a heuristic. `pack review` has the rule text; a rule that names a file pattern, an import, a directory, a command, or a forbidden string is a candidate. False positives are fine here and cheap — the output already says "None is automatically wrong; each is a place where a pack may have stopped earning its context", which is exactly the right register.

Worth deciding: whether the same pass should look for the reverse — a gate whose command asserts nothing (`true`, `exit 0`, a grep that cannot fail). `pack review` already flags a gate that never caught anything, which is the observable half of that.

## Acceptance
- [ ] `pack review` names rules a machine might decide, as candidates rather than faults
- [ ] the reasoning is stated once, where the reader is, not only in the design documents
- [ ] a rule that is genuinely judgement is not flagged merely for naming a path
