# #82 — A consultation is raised, answered and folded on one machine, and the team never sees it

**closed** · — · opened 2026-09-08 · closed 2026-09-08

---

**As** two or three people working one initiative
**so that** a question one person's agent could not answer reaches the person who can answer it.

Repository: `deck`

A consultation lives in `.deck/consultations/`, and `.deck/` is machine state that is never versioned. So the loop deck built — an agent meets something it cannot decide, records it instead of guessing, a person answers, `deck ask fold` writes the answer into a pack — runs entirely inside one person's checkout until the last step.

The last step is the only one that crosses: a folded rule lands in a pack, and packs are versioned. Everything before it is private.

## What that costs a team

**The question does not reach whoever can answer it.** The agent that raised it stopped guessing, which is the whole point, and then filed the doubt somewhere only its author will look. On a real workspace here, eight drafts filed twenty-seven questions; a colleague on the same initiative could not have seen one of them.

**Two people answer the same question differently and neither knows.** `deck ask` deduplicates by question text within one store. Across stores there is no dedup, because there is no across.

**A question nobody folds is asked again, per person, forever.** `propose pack` re-files what its predecessor could not explain. Two people running it on the same repository each pay for the same question, and the second one's copy is not marked as already open.

**And it is the one place deck's own reasoning does not reach.** The design line is that a consultation "survives the session that raised it, and is then readable by the next run — which is what stops the same question being asked forever." It survives the session. It does not survive the machine.

## Why the answer is not simply "version them"

`.deck/` is machine state for good reasons: it holds paths true on one checkout, gate evidence from one run, a mount manifest for one session. Versioning it wholesale would put all of that into review.

A consultation is different in kind from the rest of `.deck/`, and that is what makes it worth solving rather than accepting. Its question and answer are workspace knowledge — the same knowledge a rule is, before it is a rule. Its `asked_in` session id and `asked_by` identity are not.

## Shape

Several defensible answers, and the choice is the work:

- **A shared store beside the pack collection.** The packs are already versioned and already reviewed; a `consultations/` directory there would travel the way rules do, and `deck ask fold` would move a file rather than write one.
- **The tracker.** A workspace with a board already has a place where a question waits for a person, and #21 is already about deck writing state back to one. A consultation is a task of a particular shape.
- **Keep them local and make the crossing explicit** — a command that publishes one deliberately, since not every half-formed question is worth the team's attention.

Worth settling at the same time: whether an answer carries who gave it across the boundary. `answered_by` uses the published identity for exactly this reason, and it is the field that makes an answer citable rather than anonymous.

## Acceptance
- [ ] a question one person's agent raises can reach a colleague on the same initiative
- [ ] an answer given once is not asked again on another machine
- [ ] whatever crosses does not drag session ids, gate evidence or mount manifests with it
- [ ] a person can still record a question that stays local
