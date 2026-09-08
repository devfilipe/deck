# #34 — deck cannot see instruction files it does not manage

**open** · feature · opened 2026-09-06

---

**As** a team that decided its agent instructions live in packs
**so that** a second source of instruction is something deck reports rather than something somebody notices.

Repository: `deck`

A workspace can hold `CLAUDE.md`, `AGENTS.md`, `.cursor/rules`, `.github/copilot-instructions.md` and their neighbours, and deck knows about none of them. It mounts what packs declare and reports what it placed; anything already in the tree is invisible to it.

That is not hypothetical. On a real workspace, an agent working in a sub-project received two sources of instruction at once: a `CLAUDE.md` sitting in an ancestor directory, always loaded, and the rules deck had mounted. Nothing compared them, and nothing said the first one was there.

Three things make it worth reporting rather than shrugging at:

- **An ancestor file is always in context.** A rule scoped by `paths:` loads when the agent touches a matching file; a `CLAUDE.md` above the working directory loads at launch, every time. So the unmanaged one has the *stronger* position.
- **It can sit outside version control entirely.** The one measured here lives in a directory that is not inside any git repository — no history, no review, no owner. A team that decided instructions are reviewed like code has one that cannot be.
- **`deck setup` already walks the tree** looking for checkouts. It passes these files without a word, at the one moment somebody is deciding what this workspace contains.

This is the same shape as the scope-divergence report: two sources of truth and nothing comparing them. The answer there was to report, never to refuse — a local file may be perfectly deliberate, and deck deciding otherwise would be deck governing somebody else's repository.

What to settle:

- **Which names.** `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.cursor/rules`, `.clinerules`, `.github/copilot-instructions.md` are the obvious set, and the list will date. Reading Claude Code's own is not possible; a stated list in the descriptor with sensible defaults probably is.
- **Where it is said.** `deck setup` is the moment somebody is deciding what the workspace holds; `doctor` is where a standing condition belongs. Probably both, like scope divergence.
- **What it says.** Naming the file and whether it is versioned is most of the value — "this is loaded before anything deck mounts, and it is not in git" is the sentence that changes what somebody does.
- **What it must not do.** Not refuse, not move it, not read its contents and form an opinion. Report that it exists, and let the team decide whether it should be a pack.

### Acceptance
- [ ] an instruction file deck does not manage is reported, with its path and whether it is under version control
- [ ] a workspace with none is not accused of anything
- [ ] deck never edits, moves or grades one
- [ ] the names it looks for are stated where a team can extend them
