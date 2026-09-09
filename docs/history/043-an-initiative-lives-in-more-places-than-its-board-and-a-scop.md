# #43 — An initiative lives in more places than its board, and a scope can only name the board

**open** · feature · opened 2026-09-06

---

**As** somebody joining a team on an initiative already under way
**so that** where that initiative lives is something deck can tell you rather than something you ask around for.

Repository: `deck`

A scope is deck's name for an initiative: a named subset of the registry, with its own posture and its own board. Two of those three travel — a pack's workspace template carries `scopes:`, including a scope's own `backlog:`, so a team shares the carve-up and the board by cloning the pack.

That much works, and it works well. Measured on a real workspace: two scopes side by side, one reading a hundred-odd items from one provider and the other twenty-five from another, each with its own `gate_level`. Nothing in the engine needed changing.

**But a board is one of several places an initiative lives**, and it is the only one with a home. A formal initiative typically also has a documentation space, a specific board view rather than the whole project, sometimes a channel, a risk register, a compliance matrix. deck has nowhere to say *"this initiative also lives here"*, so that knowledge stays in somebody's head and is re-asked every time a person joins.

A small concrete instance of the same gap: a board URL usually names both a project and a *board within it*. `backlog:` keeps the project and drops the board, so the thing the team actually looks at every morning is the part deck did not record.

**What this is not.** Documentation and knowledge retrieval — reading those spaces, indexing them, answering from them — is a different feature with different machinery, and not what this asks for. This is only the registry: a place to write down where an initiative lives, so a command can print it and a person can follow it. Anything that goes and *reads* those places is a separate decision, and probably a separate provider mechanism.

Three things to settle:

- **Shape.** `backlog:` is a typed list of sources and it earned that shape by being consumed. A generic `links:` risks becoming a bag of strings nobody validates — which this project would normally refuse. Typed entries deck can at least check the keys of are probably the line, even when nothing reads them yet.
- **Whether an unread entry is worth having.** A link deck never follows is documentation, and this project has said before that a rule nobody can act on belongs in prose. The counter-argument is that a person follows it, and a person is a legitimate consumer.
- **What surfaces it.** `deck scope <name>` already prints repositories, board and posture; it is the obvious place, and `deck setup` is where somebody meets a workspace for the first time.

### Acceptance
- [ ] a scope can record where its initiative lives, beyond the board it reads
- [ ] whatever the shape, deck checks what it can and refuses what it cannot read, rather than storing free text it never looks at
- [ ] it travels with the scope into a pack, the way the board already does
- [ ] a scope that records none is not accused of anything
