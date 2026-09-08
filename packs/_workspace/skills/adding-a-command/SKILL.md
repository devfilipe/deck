---
name: adding-a-command
description: >
  Add or change a deck subcommand: where the parser, the implementation and the
  checks go, and what a command owes its caller. Use when contributing to deck
  itself.
when_to_use: >
  "add a deck command", "deck should also be able to", "change what deck prints".
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Adding a command

## Where things go

| | |
|---|---|
| `plugins/deck/deck/cli.py` | the parser: one `add_parser`, arguments, `set_defaults(fn=…)` |
| `plugins/deck/deck/cmd_<area>.py` | the implementation, taking `(ws, args)` |
| `plugins/deck/deck/<area>.py` | the logic, if it is worth testing apart from printing |
| `ci/smoke.sh` | at least one check, in the section that matches |

Read a neighbouring command before writing a new one. `cmd_workspace.cmd_packs`
is a reasonable model: resolve, compute, honour `--json`, print, return non-zero
when it found a problem.

## What a command owes its caller

1. **`--json` when the output is structured.** An agent should not parse a table.
2. **A non-zero exit when it reports a problem**, so a script can act on it.
3. **No writes without saying so.** A command that changes files says which, and
   offers `--dry-run` when the change is more than trivial.
4. **A message that names the fix.** `deck: X is missing` is half a message;
   `deck: X is missing — run Y` is the whole one.

## Before claiming it works

```bash
ruff check . && ruff format --check .
./ci/smoke.sh
```

Add the check in the same commit as the behaviour. A commit that says a defect is
fixed and does not add the check that would have caught it is not finished.
