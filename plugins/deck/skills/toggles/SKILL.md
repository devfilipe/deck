---
name: toggles
description: >
  Resolve the recurring decisions (how far to verify, how to deploy, to which
  target, what the change may break) and turn the pending ones into questions
  for the operator at the right moment. Use at the start of a task, before
  verifying, and before delivering.
when_to_use: >
  Before planning a change, before building or deploying, before committing, or
  when the operator asks "what are the options", "what is configured", "why did
  you choose that".
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *) AskUserQuestion
---

# Toggles

Toggles are the decisions this workspace makes over and over, declared once
instead of renegotiated per task. You guess none of them: ask the resolver, and
whatever comes back as `ask`, **ask the operator**.

## The contract

```bash
deck toggle list --stage <stage>       # what holds, and where it came from
deck toggle get <id>                   # one value, for scripting
deck toggle explain <id>               # what it means and why it is what it is
deck toggle ask-plan --stage <stage> --files <files…>    # questions, as JSON
deck toggle set <id> <value> --at task --why "<reason>"  # record the answer
```

The four stages, and when to consult each:

| Stage | When | Decides |
|---|---|---|
| `plan` | before writing any code | contract compatibility, approval, requirement link |
| `implement` | while editing | formatting, guardrails |
| `verify` | before building or deploying | how far to verify, build scope, deploy mode, target |
| `deliver` | before committing | push destination, documentation, changelog |

## How to ask

At the start of each stage, run `ask-plan` with the files the task touches —
the catalog's `applies_to` uses them so you do not ask about the API schema in a
change that only touches configuration.

The output is already shaped like a selector: `header`, `question`, `options`
with `label` and `description`. Pass those to **AskUserQuestion without
rewriting them**: the wording was reviewed and keeps the decision consistent
across sessions and across people. At most four questions per call.

After each answer, record it — with the operator's own reason when they gave
one:

```bash
deck toggle set deploy_mode packaged --at task --why "the lab pod is rebuilt nightly"
```

`--why` holds why *this* value was right here. It is not the catalog's
`rationale`, which says why the toggle exists at all; `deck toggle explain`
prints the two apart. Quote the operator rather than paraphrasing, and pass no
`--why` at all when they gave no reason: a value with none is recorded as having
none, and inventing one is worse than the gap. Note that setting a value without
`--why` clears whatever reason was recorded there before.

The sentence is not filed away: it is what `deck bundle` prints under that
decision on the page a reviewer reads, and what `deck toggle list --json` and
`deck scope <name>` carry beside the value. A decision recorded without one
appears there as "not recorded", which is the honest reading and the reason to
ask for the operator's sentence while they are still in the room.

`task` scope covers this task only. If the operator says "always do this", use
`--at workspace`. If they say "always, for this initiative", `--at <name>`
takes any scope the workspace declares (`deck scopes`), and the value applies to
every repository that scope holds and to none outside it.

## Rules

1. **Never ask what `ask-plan` did not return.** A toggle with a value has been
   decided; one marked `askable: false` is not the operator's business.
2. **Respect the budget.** `ask-plan` already truncates at `question_budget`,
   highest risk first. What was cut comes back under `assumed` — say in the
   report what was assumed without asking, and with which value.
3. **Never invent a value.** If a relevant toggle has no viable option (an
   unreachable target, say), stop and say so rather than falling back silently.
4. **A settled `ask` is not a question.** With one declared target, `target`
   resolves itself and the source field records that.
5. **`explain` before disagreeing.** If a value looks wrong for the task, run
   `deck toggle explain <id>`, show the layer it comes from, and propose the
   change — do not apply it on your own.
6. **Never write a reason the operator did not give.** `--why` is theirs. If
   `explain` shows a value with no reason recorded, say that it has none rather
   than reading the catalog's `rationale` as though it justified the choice.

## In the delivery report

Every delivery ends by listing the toggles that shaped it, with each source.
That is what lets a reviewer understand why this change stopped at the build
while the previous one went all the way to the target.
