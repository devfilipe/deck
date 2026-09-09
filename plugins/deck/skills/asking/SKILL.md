---
name: asking
description: >
  Where a question goes when the decision catalog has no entry for it. Use when
  you meet a trade-off nobody wrote down, when a task exists to decide something,
  and before deciding anything on the operator's behalf.
when_to_use: >
  "should this fail or fall back", "nobody said what to do here", "I need a
  decision", "is this my call".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Asking

Three kinds of question, and only one of them is yours to answer.

## 1. The catalog foresaw it — ask it, do not answer it

```bash
deck toggle ask-plan --stage plan --files <files you will touch>
```

Returns the question already worded, with options and the consequence of each.
Put it to the operator **verbatim**. Do not reword it and do not pick for them.

If it comes back empty, it was answered before you started. That is the normal
case in an unattended run.

## 2. The task owns it — decide it, and say why

A board item may carry `decides: [<toggle id>]`. That says the choice **is** the
work: it was deliberately left open so it would be made here, with the context
the task gives you.

```bash
deck board show <id>              # `decides` is listed if it has one
deck toggle set --at workspace <id> <value>
```

Record it, then say in your report what you chose and what you weighed.

## 3. Nobody foresaw it — write it down and keep working

```bash
deck ask new "<the question>" --task <id> \
  --context "<what a person needs in order to answer it>" \
  --options "<a,b>"          # only if the choice is already narrow
```

**Nothing waits on it.** Say in your report what you did in the meantime and
what would change if the answer goes the other way.

Before raising one, check it has not already been answered:

```bash
deck ask list --resolved
```

## Rules

1. **Never stall on a question.** A run that stops at the first one is not a
   run. Record it and carry on with the part that does not depend on it.
2. **Never answer one that is not yours.** A catalog question belongs to the
   operator. Deciding it quietly is how a preference becomes a policy nobody
   agreed to.
3. **An answer is a transcript until someone writes it down.** `deck ask
   resolve` says which artifact it looks like; a person still has to put it in
   the pack, or the next run asks again.
