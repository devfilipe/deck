---
name: workspace
description: >
  Resolve where the repositories are, what builds each one, and who else is
  affected when one changes. Use before planning any change that could span more
  than one repository, before building, and whenever you need an absolute path
  instead of guessing one.
when_to_use: >
  "add a field to the schema", "change the auth backend", "what does this
  affect", "what do I need to build", "where is repository X".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Workspace

No hardcoded paths in a skill, a plan or a command. Every machine's tree is
different, and the descriptor is the only source.

```bash
deck root                     # resolved root, and where it came from
deck path <repo>              # absolute path of a repository
deck repos --buildable-only   # the ones that build (excludes downstream)
deck get container.compose    # any descriptor field, by dotted key
deck targets --json           # the deployment allowlist
```

## Walk the graph before planning

```bash
deck impact <repo> --json
```

Four things the plan needs come back:

- `impacted` — everything the change reaches, transitively.
- `order` — topological execution order. Working out of it produces a build that
  passes and behaviour that does not exist.
- `build_targets` — the exact targets, in order. This is what stops you from
  rebuilding everything out of caution.
- `downstream` — repositories that produce no artifact but must keep up: test
  suites, requirement matrices, reference documents. They belong in the plan as
  obligations, not as an afterthought.

For a change with several entry points, combine them:

```bash
deck order repo-a repo-b
```

## Working inside a scope

A workspace may be carved into named subsets — initiatives — each with its own
board and its own posture:

```bash
deck scopes                 # what is declared, and which one is active
deck scope <name>           # its repositories, its board, what it reaches outside
```

When one is active, `deck repos` lists that subset and the board is that
initiative's board. `deck impact` is deliberately not narrowed: it still reports
the whole chain and marks the repositories the scope does not hold. Those are
obligations, not exclusions — a change that forces a repository outside the
scope still has to be made there, and the plan says so.

## Rules

1. **The graph decides the order.** If you believe it should be different, the
   descriptor is probably stale — say so and propose the `impacts` fix rather
   than working around it.
2. **A repository outside the descriptor does not exist for the plan.** If the
   change needs one that is not there, stop and ask for it to be declared.
   Editing an unmapped tree is how traceability is lost.
3. **`downstream` never silently disappears.** An item you chose not to touch
   becomes an explicit line in the report, with the reason.
4. **Hosts come only from `targets`.** No machine appears in a command of yours
   without being on the allowlist — the guard denies it, and rightly.
