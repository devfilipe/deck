# #81 — Two repository packs cannot use the same gate id, though their gates never meet

**open** · — · opened 2026-09-08

---

A pack named after a repository gets its gates auto-scoped to that repository — `gates.py::_merge` sets `only_repos: [<repo>]` for a new gate id. Two such packs therefore declare gates that can never run over the same repository.

deck refuses them anyway:

```
$ deck gate list
deck: some-lib: gate `ruff-check` already exists (from some-app).
      Set `overrides: true` to extend it deliberately.
```

The command dies. Not a warning on one gate — `deck gate list`, `gate run` and everything downstream stop.

## Why the refusal is wrong here

The id check runs before scoping is considered, so it cannot see that the two gates are disjoint. `some-app`'s `ruff-check` runs over `some-app`; `some-lib`'s runs over `some-lib`. There is no repository where the two disagree, no ambiguity to resolve, and nothing for a person to decide.

`overrides: true` is not the fix either, and would be actively wrong: an override says "extend the gate that exists", and these two packs are not talking about the same gate. Taking it would also drag in #69 — an override gets no scope default, so `some-lib` overriding `some-app`'s gate would widen it across the workspace.

## Why it bites in practice

`deck propose pack` drafts natural names. Run over eight repositories it produced `ruff-check` twice and `ruff-format` twice, from two pairs of repositories that both happen to use ruff — which is the normal case, not a coincidence. The workspace's ladder stopped listing until the ids were hand-renamed to `ruff-check-lib` and `ruff-format-lib`.

The effect is that **every repository pack must invent a globally unique name for a locally obvious thing**. `ruff-check` is the right name for "run ruff here" in every repository that runs ruff, and only one of them may have it.

It also punishes the pack layering deck recommends. The more a workspace splits knowledge into per-repository packs — which is the documented shape — the more likely two of them name the same ordinary check.

## Shape

The collision check should ask whether the two gates can ever apply to the same repository, and refuse only then. Two gates scoped to disjoint repository sets are two gates, not a collision.

Two things to settle rather than assume:

- **What the report shows.** Two gates with one id are still confusing to read even when they are legal — `deck gate list` should probably qualify each with the repository it runs over, and `gate run` evidence has to keep them apart.
- **Whether an unscoped gate still collides with a scoped one.** A `_common` gate named `ruff-check` and a repository pack's `ruff-check` do overlap, and that one is a real collision — the current refusal is right for it.

## Acceptance
- [ ] two repository packs may each declare a gate with the same id, scoped to their own repository
- [ ] a genuine overlap is still refused, with the same message
- [ ] a run reports which repository each same-named gate covered, and the evidence keeps them apart
