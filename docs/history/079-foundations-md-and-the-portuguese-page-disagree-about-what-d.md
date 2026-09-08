# #79 — FOUNDATIONS.md and the Portuguese page disagree about what deck does not cover

**closed** · — · opened 2026-09-08 · closed 2026-09-08

---

`FOUNDATIONS.md` §4 lists seven gaps. `docs/pt-br.html` lists eight. They are not the same eight.

| | `FOUNDATIONS.md` | `pt-br.html` |
|---|---|---|
| A scope is per machine | yes | yes |
| The autonomous run, at stakes | yes | yes |
| **VCR, the second half** | **yes** | no |
| **Attribution without a link** | **yes** | no |
| A budget on a trend | yes | yes |
| Release and distribution | yes | yes |
| Memory across tasks | yes | yes |
| **Trackers beyond GitHub** | no | **yes** |
| **The full BriefingScript** | no | **yes** |
| **Measurement decay** | no | **yes** |

Three of those differences are each a different kind of wrong.

**`VCR, the second half` is stale.** `deck ask fold` shipped in #12: an answered consultation becomes a rule, a toggle or a gate in a named pack, carrying the question and the answer. `FOUNDATIONS.md` still says nothing folds it in. The page is right and the older document is wrong.

**`Attribution without a link` was dropped with nothing having changed.** The page simply does not carry it. Whether it belongs is a decision; vanishing is not one.

**Three gaps exist only in the page.** They are real and worth stating — the tracker one is demonstrably real, since #37 was a Jira reader calling an endpoint Atlassian had removed while the suite stayed green against a stand-in that answered it. But a gap deck admits to in one language and not the other is not admitted to.

## The one that is also misframed

Both documents present architecture as something deck does not cover. That reading is wrong in a way that costs users work: a gate command resolves `${repo.impacts}`, so a pack can compare a declared edge against real dependencies and fail when they disagree, with no engine change at all (#78). What deck does not do is *know what a dependency is* in your domain — which is the engine/pack split working, not a gap.

Framing it as a gap teaches a reader to wait for a release instead of writing eight lines of YAML.

## Shape

One list, in one place, with the other pointing at it. Where it lives is the decision: `FOUNDATIONS.md` is the older and more argued document; the page is the one a stranger reads first. Whichever holds it, the other must not restate it, because two copies of a list is exactly how this happened.

Worth doing at the same time: these are the only statements deck makes about its own future that live nowhere a person can plan against. None of the eight is an issue. `deck board` reads a tracker; the roadmap of the tool that reads it is prose in a document.

## Acceptance
- [ ] one list of what is not covered, and one only
- [ ] `VCR` is gone from it, and `Attribution without a link` is either present or deliberately removed
- [ ] architecture is described as something a pack's gate does, not as something deck lacks
- [ ] the gaps exist somewhere a person can plan against them
