---
name: board
description: >
  Read the team's task board, see what may run in parallel, and take a task
  without colliding with someone else. Use when asked to pick up work, plan a
  batch, or say what is open.
when_to_use: >
  "what is open", "pick up the next task", "can these run together", "what am I
  working on", "add a task".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Board

```bash
deck board list                # every task the declared sources hold
deck board show <id>           # one task, and every repository it reaches
deck board plan                # the open ones, grouped into what may run together
deck board why <id> <id>       # why two tasks may not run together
deck board claim <id>          # take it, so nobody else picks it up
deck board done <id>           # close it, once the ladder has run for it
deck board new "title" --repos a b
```

## The grouping is the point

`plan` groups tasks by the closure of what they edit — the repositories a task
names, plus everything those reach through `impacts`. Two tasks collide when
both would edit the same repository, so a group is a set that can genuinely run
at the same time.

A task with no repository named cannot be grouped, and appears alone. That is a
gap in the board, not a property of the work: say so rather than guessing which
repositories it touches.

## One piece of work in two systems

A task may name where it lives elsewhere — `ext_provider: jira`, `ext_id:
PROJ-412`. When a tracker deck can fetch returns that same identity, the two are
reconciled into one task: state (`status`, `assignee`, `url`) comes from the
tracker, workspace knowledge (`repos`, `exclusive`, `target`) from the local
entry.

So when someone asks about PROJ-412 and about the local task, they are asking
about the same thing. `deck board show` prints the external identity and says
when it was reconciled. A provider deck cannot fetch — `linear`, `asana` — is
still recorded, and is then just a reference.

## What a well-formed item carries

```bash
deck board show <id>       # `as_a`, `so_that` and the acceptance criteria
deck board template        # the shape, to copy
```

`acceptance:` is the half the ladder cannot reach. Gates prove the code holds
together; they decide nothing about whether it is what somebody asked for. So:

- **Read the criteria before planning.** They are the definition of done, in the
  words of whoever will judge it, and they often rule out the plausible approach.
- **Accept each one by name** when the change satisfies it:
  `deck board done <id> --accept "<the criterion, verbatim>"`. `done` refuses
  while any is unaccepted, and `deck bundle` blocks on the same thing.
- **Never accept one you did not verify.** Accepting is a claim, and it is the
  claim nothing else in deck checks for you.
- A task declaring none is not thereby finished — the bundle says "nothing
  states what it was for", which is a finding.

## Rules

1. **Claim before working.** `claim` refuses a task someone else already holds.
   The board is shared state; two people on one task is the failure it prevents.
   Claim with no name unless you were given one: a file board is committed, so
   the name recorded is the identity that repository publishes under, and a
   login typed in from the shell is how the wrong person ends up in a public
   diff. `deck board whoami` says which name each source would write.
2. **The board is the source, not your memory.** Status, assignee and repositories
   come from `deck board show`, never from what was said earlier in the session.
3. **Do not invent task ids.** An id that is not in `board list` does not exist.
4. **Closing is a claim about verification.** `done` refuses a task with no gate
   record, or with a gate that failed, and names the command that fixes it.
   `--force` exists for work the ladder does not cover — use it saying why, not
   to get past a red gate.
5. **Parallel means parallel.** When `plan` puts tasks in one group, they may run
   in separate worktrees at the same time. When it does not, running them
   together corrupts one of them.
