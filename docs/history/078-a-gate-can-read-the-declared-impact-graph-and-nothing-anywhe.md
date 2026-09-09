# #78 — A gate can read the declared impact graph, and nothing anywhere shows it

**open** · — · opened 2026-09-08

---

A gate command resolves `${repo.impacts}`, `${repo.couples}` and `${repo.role}`. Measured:

```yaml
  - id: graph-probe
    per_repo: "echo 'impacts=${repo.impacts} role=${repo.role}'"
```
```
impacts=[some-consumer] role=the framework: drivers, access layer, runner, report
```

That is the whole mechanism needed to close what `FOUNDATIONS.md` describes as a gap — the declared graph is an assertion nothing confronts with reality. A pack can take `${repo.impacts}`, run whatever computes real dependencies in its domain (`import-linter`, `go list`, `madge`, `bitbake -g`, a grep over includes), and fail when the two disagree.

The engine supplies the *where* — which repositories, which rung, which files. The pack supplies the *how*, which is domain knowledge the engine must not have. It is the engine/pack contract working exactly as designed.

**Nothing demonstrates it.** Not `deck-acme`, not the exercises, not the documents, not a scaffolded pack. `resolve()` documents the substitution; no example connects it to the graph.

## Why an undemonstrated capability is a missing one

The reasonable reading of "deck records architecture and does not enforce it" is that enforcement would need engine work. It would not. A person who believes it does waits for a release instead of writing eight lines of YAML — and the belief is reinforced by every document that lists architecture under what deck does not cover.

This is also the difference between a control plane and a notebook. A declared edge that nothing checks decays the way any undefended claim decays: `impacts:` was right when somebody wrote it, and there is no run that would notice when it stopped being.

## Shape

An example gate, somewhere a reader will meet it. `deck-acme` is the natural home — it exists to show what deck does through a fictional workspace with a real graph — and one exercise should build one, since the exercises are where a reader does it rather than reads it.

Worth deciding whether the scaffolded `gates.yaml` should carry a commented example. It is the file somebody opens when writing their first gate, and a commented shape there is read by everyone who ever writes one.

## Acceptance
- [ ] an example compares a declared edge against something observed, and fails when they disagree
- [ ] a reader meets it without having to look for it
- [ ] the documents stop implying that enforcing architecture needs engine work
