# #64 — gate run --only replaces the task's evidence instead of adding to it

**open** · — · opened 2026-09-07

---

`deck gate run --task T --only <gate>` writes the evidence file for the whole task from the one gate it ran. Everything verified before it is gone from the record.

## Reproduce

A workspace with two `static` gates, both trivial:

```
$ deck gate run --task T1
  ok   one          workspace                  0.0s
  ok   two          workspace                  0.0s

  2 gate(s) passed
  evidence: /tmp/g2/.deck/gates/T1.json

$ deck gate run --task T1 --only two
  1 gate(s) passed
  evidence: /tmp/g2/.deck/gates/T1.json

$ deck gate report --task T1
task T1 · level deploy · 2026-09-07T02:46:50

  ok   two          passed
       workspace                  passed     0.0s

  1 gate(s) passed
```

`one` passed seconds earlier, against a tree nothing had touched in between, and now reads as never run.

## Why it matters more than a lost line

The evidence file is what `deck bundle` reads to tell a reviewer which rung the ladder reached. After a `--only` run it reports the ladder as having completed nothing — a bundle produced this, on a workspace where every rung had passed minutes before:

> the ladder was set to `deploy` and completed no rung; `static`, `build`, `deploy` hold no gate in the record, so they were skipped rather than verified

That sentence is deck being careful, and it is being careful about a hole deck made. The whole point of the evidence file is that a rung reached is a rung somebody can point at afterwards; a flag that silently un-reaches three of them defeats the surface it feeds.

It also punishes exactly the right instinct. `--only` is what somebody reaches for after fixing one gate, to avoid re-running a long suite — and the price is that the long suite's result is discarded, which is the opposite of what they were trying to save.

## Shape

A `--only` run is a partial run and its result is partial news: it should merge into the record, replacing the entry for the gate it ran and leaving every other entry alone.

Two things worth deciding rather than assuming:

- **How stale is too stale.** An entry from a run against a tree that has since changed is not evidence of anything. Merging without a check trades one wrong answer for another. A timestamp is already recorded; whether deck should compare it against anything, and against what, is the real question here.
- **What the report says about a mixed record.** If one entry is from 10:02 and another from 10:47, the report should say so rather than presenting them as one run.

Found by an agent updating `deck-acme`, which worked around it by ordering the demo so the last run is a full one.

## Acceptance
- [ ] a `--only` run leaves the entries for gates it did not run in the record
- [ ] `gate report` and `bundle` distinguish a record assembled from several runs from one produced by a single run
- [ ] a full run still replaces the record wholesale
