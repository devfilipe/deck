# #45 — A pack can belong to a repository or to all of them, and not to an initiative

**closed** · feature · opened 2026-09-06 · closed 2026-09-07

---

**As** a team running more than one initiative over one registry
**so that** what an initiative knows arrives with it and leaves with it.

Repository: `deck`

A pack reaches an agent by one of two routes: it is named after a repository and applies to that repository, or its directory name is in `SHARED_NAMES` and it applies to every repository in the workspace. A third route exists for packs named explicitly in `packs:`, and that one applies to the whole workspace too.

There is no way to say **this pack belongs to this initiative**.

That is a gap now rather than a wish, because a scope already carries the other three things an initiative has. It names its subset of the registry, it can hold its own board, and it can hold its own posture — measured on a real workspace, two scopes side by side, one reading a hundred-odd items from one provider and the other twenty-five from another, with different `gate_level` values and each reason recorded. Knowledge is the one thing left outside.

The consequence is concrete. Work on a compliance initiative and work on ordinary product development happen over the same repositories, and what an agent should know differs: one wants the regulatory vocabulary, the checks that stand in for an auditor, the conventions a report is assembled from; the other wants none of it. Today the choice is to load it for everybody or to write it nowhere.

**Enabling is already solved and needs no new flag.** `deck --scope <name>` is how an initiative becomes active, and a scope-bound pack would come and go with it. That is the whole mechanism.

Things to settle:

- **How the binding is expressed.** A directory convention — a pack under a reserved name matching a declared scope — is consistent with how repository packs are found today, and it means no mapping table to keep current. A `packs:` key inside the scope block is the alternative and is more explicit. Note that pack discovery already walks one level of nesting, so the convention costs nothing structurally.
- **Where it sits in the merge order.** Most general first is the existing rule: named, then shared, then per-repository. An initiative is narrower than the workspace and wider than one repository, so it belongs between them — but that is an argument, not an obvious fact, and reversing it changes which rule wins a collision.
- **What happens with no scope active.** A scope-bound pack loading when nobody asked for the scope would be the opposite of the point. Not loading is probably right, and `deck packs` should be able to say it exists and is not in play, or it becomes knowledge nobody can find.
- **Whether a scope pack may declare gates.** A rule is knowledge and travels harmlessly. A gate is a claim about what verifies a delivery, and one that appears and disappears with a flag is a different proposition — worth deciding deliberately rather than falling out of the implementation.

### Acceptance
- [ ] a pack can be bound to a declared scope and reaches an agent only while that scope is active
- [ ] the merge order it takes is stated, and a collision with a workspace-wide pack resolves predictably
- [ ] a scope-bound pack that is not in play is discoverable, not invisible
- [ ] a workspace with no scopes behaves exactly as it does now
