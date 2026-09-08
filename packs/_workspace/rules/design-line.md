---
paths: ["plugins/deck/**", "packs/**", "*.md"]
---

# What deck is allowed to be

deck supplies what an agent runtime cannot know — *your* workspace — and hands
it over through mechanisms Claude Code already has. Everything else is out of
scope, and the list is not a matter of taste:

| Already Claude Code's | deck must not build |
|---|---|
| Agent orchestration, subagents | its own scheduler |
| Worktrees, isolation | its own checkout manager |
| Instruction loading (CLAUDE.md, rules, skills) | its own context injector |
| Per-directory plugin scope | its own enable/disable layer |
| The question box, plan mode | its own prompt UI |
| Code and security review | its own reviewer |
| Session cost | a second accounting system |

Before adding a capability, find out whether Claude Code ships it. If it does,
the feature is a way to *reach* it, not a reimplementation of it. A pull request
that duplicates the runtime is refused however well it is written.

## The two halves

**Engine** — `plugins/deck/deck/`. Knows about workspaces, graphs, toggles,
gates, packs. Knows nothing about any domain: not `bitbake`, not `helm`, not
NETCONF. A domain word appearing in engine code is a bug.

**Pack** — data. Commands, edges, decisions, rules. Reviewed and versioned by
the team that owns the domain.

When something has to be added, ask which half it belongs to first. The answer
is the pack more often than it feels.

## Refusing beats guessing

Two packs claim one name; two gates share an id; a variable does not resolve;
a repository is not in the descriptor. In every case deck reports and stops. It
does not rank, default, or pick the likely one. A tool that guesses about a
multi-repository change is a tool nobody can audit afterwards.
