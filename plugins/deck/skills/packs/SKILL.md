---
name: packs
description: >
  Which knowledge applies where, in what order it merges, and whether it is
  still doing anything. Use when a rule did not arrive, when two packs disagree,
  and before adding to a pack.
when_to_use: >
  "why did that rule not load", "which pack decides this", "where do I put this
  convention", "is this pack still useful".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Packs

```bash
deck packs                  # what is in play, in merge order, and who overrides whom
deck packs --repo <name>    # only what applies to one repository
deck pack review            # what each costs, and what has stopped earning it
```

## Where a thing goes

Four homes, and the cheapest correct one wins:

| Put it in | When |
|---|---|
| **gate** | a machine can check it — format, lint, coverage, build, tests |
| **toggle** | more than one defensible answer, and the team keeps re-deciding |
| **rule** | a constraint over an area of code, with a consequence worth stating |
| **skill** | a procedure with steps, followed rather than obeyed |

**If a formatter can fix it, it is a gate — never a rule.** A rule costs context
every time a matching file is read; a gate costs nothing until it runs. This is
the commonest way a pack wastes an agent's context, and it is worth refusing.

## Scope is not advisory

A pack named after a repository applies to that repository and no other. Its
rules mount only there, and a gate it declares defaults to that repository. If a
rule you expected did not arrive, it is scoped somewhere else — check
`deck packs --repo <name>` rather than copying the file in.

Merge order is most general first, so the most specific has the last word:
explicitly named packs, then `_workspaces/all/default`, then `all/<scope>`,
then `_workspaces/<name>/default`, then `<name>/<scope>`, then the
repository's own `_repos/<name>`. A pack
declaring `requires:` merges after what it requires, which is why its overrides
win.

## Rules

1. **A mounted rule is a copy.** Edit it if that is where you noticed the
   problem, then `deck save` to carry it back to the pack — the pack is what
   is reviewed and versioned, and the copy goes away at unmount.
2. **Reusing an id needs `overrides: true`**, for a toggle or a gate. Without
   it deck refuses and names both origins.
3. **Adding to a pack is a change to shared knowledge.** It is reviewed like
   code, because that is what it is.
4. **`deck pack review` before adding.** A pack that already carries a rule
   matching no file, or a gate that never fails, does not need more — it needs
   the dead weight removed.
