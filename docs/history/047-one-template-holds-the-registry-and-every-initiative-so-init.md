# #47 — One template holds the registry and every initiative, so initiatives cannot be versioned apart

**closed** · feature · opened 2026-09-06 · closed 2026-09-07

---

**As** two teams running two initiatives over one product
**so that** changing what one initiative contains does not go through the file the other one lives in.

Repository: `deck`

`Workspace.workspace_template()` walks the packs in play and stops at the first that ships `templates/workspace/workspace.yaml`. The most specific wins and the rest are ignored — there is no merge. So everything a team versions about its workspace is in one file: the registry, the graph, and **every** scope.

That is right for the registry. Which repositories exist and how a change propagates between them are facts about the product, and one answer serves everybody.

It is wrong for the scopes. A scope is an initiative: its subset, its board, its posture. Those belong to whoever runs that initiative, and today a second initiative appearing means editing the file the first one lives in. Two initiatives with different owners share one YAML and one review.

The shapes are different in a way worth naming. The registry is a description of a thing that exists — one product, one graph, and a second opinion about it is a contradiction. A scope is a decision about how to divide attention, and several can be true at once. Merging contradictions is wrong; merging decisions is ordinary.

Something already leans this way: a scope can carry its own `backlog:`, and it travels into the template today. So the per-initiative half of the data exists and has nowhere of its own to live.

This is #45's other half. That one asks for a pack bound to an initiative so its *knowledge* comes and goes with it; this asks that the initiative's *definition* live there too. Neither settles the other, and doing #45 first would make this one obvious — a scope-bound pack shipping the scope it is bound to is close to the whole answer.

What to settle:

- **Whether templates merge at all, or only scopes do.** Merging whole templates raises "who wins on the registry", which is a question with no good answer. Taking the registry from the most specific template and the scopes from all of them is narrower and probably right.
- **What a collision between two scope definitions means.** Two packs shipping a scope of the same name is either a mistake or a deliberate override, and deck refuses to guess elsewhere.
- **What `deck pack new --from-workspace` writes** once there is more than one destination. Today it writes everything into the one pack it was pointed at.

### Acceptance
- [ ] an initiative's definition can be versioned separately from the registry and from other initiatives
- [ ] a registry with one template and no scope packs behaves exactly as it does now
- [ ] a name claimed twice is reported, never merged silently
- [ ] `doctor`'s divergence report says which pack a scope came from
