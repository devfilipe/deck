---
name: gates
description: >
  Run the verification ladder and report how far the change actually got. Use
  before saying anything is done, before delivering, and whenever asked whether
  something was tested.
when_to_use: >
  "is it working", "can we deliver", "did the tests run", "build it", "verify".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Gates

The rung a delivery reaches is a fact, not an impression. It comes from here.

```bash
deck gate list --repos a b     # which gates apply, and why the others do not
deck gate run --task X         # run them, in ladder order, recording evidence
deck gate run --task X --dry-run   # the resolved commands, executed none
deck gate report --task X      # what ran, what passed, what never ran
```

A gate may also **measure**: a `measures:` entry reads a number out of the
output the command already produced, and the run prints it against the last one.
`deck metrics` is where the shape over many runs lives.

## The three states, and why the third exists

| | Meaning |
|---|---|
| **passed / failed** | The command ran. The result is real. |
| **SKIPPED** | It does not apply here — the level stops lower, a condition excludes it, no repository matches. |
| **BLOCKED** | It should have run and could not: a variable in the command did not resolve. |

BLOCKED is never a pass. A command with a hole in it either fails confusingly
or, worse, succeeds while doing something other than what was meant. Report it
as unverified and say which variable was missing.

## Rules

1. **Never claim a rung the ladder did not reach.** `gate_level` decides how far
   verification goes; if it stops at `build`, then behaviour is untested and the
   report says so. Raising it is the operator's call, not yours. A rung is
   reached when something ran and passed there — a rung whose gates all turned
   out not to apply, because `only_repos` excluded every repository in play or a
   `when` toggle did not match, verified nothing and is not one the ladder
   reached, however green the run looked.
2. **A gate marked `subagent: true` runs in a subagent.** Its output is large and
   belongs out of the main context. Bring back the verdict, not the log.
3. **The evidence outlives the session.** `.deck/gates/` holds what ran and what
   it produced. When someone asks later, read it instead of re-running.
4. **A gate that fails stops the delivery.** Do not work around it, do not
   narrow its scope to make it pass, and do not report the failure as a caveat
   at the end of a success.
5. **A pass is not "nothing got worse".** A threshold says the number is inside
   its limit, never which way it has been moving. When a gate measured
   something, read `deck metrics list` before adding that nothing decayed.
6. **The ladder is not the whole handover.** "Did it pass" is this command;
   "is it ready to merge" is `deck bundle --task X`, which reads this evidence
   alongside the change set, the decisions and the working tree.
