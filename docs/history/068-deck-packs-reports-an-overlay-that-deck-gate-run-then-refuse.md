# #68 — deck packs reports an overlay that deck gate run then refuses

**open** · — · opened 2026-09-07

---

Two packs declare a gate with the same id and neither says `overrides: true`. `deck packs` presents that as a merged overlay; `deck gate run` refuses to run at all.

```
$ deck packs
  overlaid   gate    build   _common -> catalog-api

$ deck gate run --task T1
deck: gate `build` already exists … Set `overrides: true`
```

One composition, two answers. A reader who checks `deck packs` before running — which is the command for exactly that question, *what does this pack layering add up to* — is told it composes, and finds out otherwise when the ladder runs.

## Which one is right

The refusal. deck's stated line is that refusing beats guessing: two packs claiming one gate id is a collision deck cannot rank, and it says so rather than picking the more specific one. `deck packs` is the surface that is wrong — it is reporting a merge that the engine will not perform.

## Shape

`deck packs` should report the collision as a collision, in the same words the run will use, so that reading it before running is worth doing. It already has the information — it found both declarations to print the overlay line.

Worth checking whether the same disagreement exists for the other things a pack contributes: toggles, rules, mount entries, scopes. `doctor` reports a scope two packs both claim; whether `packs` agrees with `doctor` and with the engine on each of those is one question asked four times, and the answer should be the same every time.

## Acceptance
- [ ] `deck packs` reports a colliding gate id as a collision, not as an overlay
- [ ] the wording matches what `gate run` says, so one does not surprise a reader of the other
- [ ] a genuine `overrides: true` overlay is still reported as an overlay
