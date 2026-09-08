---
name: cost
description: >
  Report what a task cost — tokens in and out per model, and the price. Use when
  asked what something cost, before a large fan-out, and when a budget was set.
when_to_use: >
  "how much did that cost", "what are we spending", "is this worth running".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Cost

```bash
deck cost --task X          # one task's window
deck cost --since 2d        # a period
deck cost --json
```

Token counts are read from the session transcripts and are exact, deduplicated
by message id so a resumed session is not counted twice. Cache reads, cache
writes and their multipliers are counted separately, because they dominate the
bill on long sessions and hiding them makes the number meaningless.

The **dollar figure is an estimate** from a price table with a date on it. Quote
it as an estimate. If the operator needs a billing-grade number, the invoice is
the source, not this.

## Rules

1. **Never present the estimate as the invoice.** Say "estimated" once, in the
   sentence that carries the number.
2. **Report before a large fan-out, not after.** A cost someone learns about
   afterwards is a cost they did not agree to.
3. **A run that hit a budget cap is a failed run.** It produced a partial answer.
   Say that, rather than reporting what came back as if it were complete.
