---
name: mount
description: >
  Place a pack's rules and plugins into the repositories a task touches, and
  take them back afterwards. Use when starting work in a repository and when
  finishing it.
when_to_use: >
  "start working on X", "set up the context", "clean up", "why does this repo
  have a .claude directory".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Mount

Context arrives in a repository for the duration of a task and then leaves.

```bash
deck mount --task X --repos a b --dry-run   # what would be placed, and where
deck mount --task X --repos a b
deck mounts                                 # what is currently placed
deck unmount --task X                       # take it all back
```

## What gets placed, in order of preference

1. **A plugin entry** in `.claude/settings.local.json` — content stays in one
   versioned place and is enabled, not copied.
2. **A file copied** into `.claude/rules/`, `.claude/agents/` or
   `.claude/skills/`. Copying is the mechanism, not a last resort: Claude Code
   does not follow a symlink in `.claude/rules/`, so a mount that linked would
   report success while placing something the runtime ignores.

Everything placed is recorded in a manifest with hashes, and `unmount` removes
exactly what it placed. deck never deletes a file it did not write.

## Rules

1. **Unmount when the task ends.** A `SessionEnd` hook takes back what is left,
   but relying on it means every intermediate state has stray files in it.
2. **A repository's own pack stays in that repository.** If a rule you expected
   did not arrive, it is scoped to another repo — check `deck packs --repo <name>`
   rather than copying the file in by hand.
3. **A mounted rule is a copy, and editing it is allowed.** `deck save` carries
   the edit back to the pack, where it is reviewed and versioned; `deck
   unmount` compares against the recorded hash and leaves an edited file alone
   rather than deleting it. What you must not do is leave the edit only in the
   working directory — the copy goes away, the pack is what lasts.
