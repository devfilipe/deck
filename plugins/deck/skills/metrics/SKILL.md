---
name: metrics
description: >
  Report which way the numbers behind a passing ladder are going. Use after a
  gate run that measured something, when asked whether quality is improving, and
  before saying a passing gate means nothing has got worse.
when_to_use: >
  "is coverage going down", "how many warnings now", "is it getting worse",
  "what changed since last time", "the gate passes but".
user-invocable: false
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Metrics

A gate answers "did it pass" against a threshold somebody chose. Coverage
sliding from 86% to 81% under an 80% floor passes every run, and the day it
fails is the day the slide has already happened. A gate that declares
`measures:` records the number as well as judging it.

```bash
deck metrics list              # every metric, declared or recorded, and its trend
deck metrics show <gate>.<id>  # the samples behind one trend, with the run each came from
deck metrics show <id> --repo b --json
```

Samples are taken by `deck gate run` from the output the gate already produced —
never by re-running anything — and appended to `.deck/metrics/` (or wherever
`metrics_store` says). The gate run prints each number against the previous one;
these commands are for the shape over many runs.

## Rules

1. **A trend is not a verdict.** Nothing here failed anything. Report movement
   and let the operator decide whether it matters; a trend that blocked a merge
   would be a threshold again, and one nobody chose.
2. **Not measured is never zero.** A pattern that matched nothing leaves no
   sample and says why. Do not fill the gap, and do not read a missing sample as
   a good one.
3. **Say how many samples the claim rests on.** "Worse across 3 runs" and
   "worse than the one previous run" are different statements. One sample is not
   a trend, and `deck metrics` says so rather than drawing a line through it.
4. **A passing ladder is not evidence that nothing decayed.** When a bundle or a
   report says the gates passed, check `deck metrics list` before adding that
   nothing got worse.
5. **Declaring a measurement belongs to a pack.** What to measure and which
   direction is good are `measures:` entries in `config/gates.yaml`, not
   anything the engine knows.
