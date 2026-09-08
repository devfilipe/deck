# #70 — ask fold --header says the toggle becomes askable, and it does not

**open** · — · opened 2026-09-07

---

`deck ask fold --as toggle --header <text>` documents itself as:

```
--header HEADER   toggle: 12 characters or fewer, and it becomes askable
```

It writes a `question:` block with the header, text and per-value options, and stops there. The entry is never asked.

## Measured

A toggle folded with `--header` does not appear in the plan for any stage:

```
$ deck toggle ask-plan --stage plan
(the folded toggle is absent)
```

Adding `stage: [plan]` by hand is not enough either. The entry is only asked when it has **both** a `stage:` and `default: ask` — and `fold` writes `default:` as the value the answer chose, which is the whole point of folding an answered consultation.

So the flag produces a well-formed `question:` block that nothing reads.

## Why the help text is the worse half

The behaviour is arguably fine: an answered consultation is a decision already taken, and writing it with the chosen value as the default is right. What is wrong is that `--help` promises the opposite, and a person who wanted an asked toggle gets a silent one and no signal.

This is my own text from the change that added `fold`, and it overstated what the flag does — the flag makes the entry *presentable*, with a header and labels a selector could render. It does not put it in front of anybody.

## Shape

Two defensible answers, and they lead to different commands:

1. **Reword.** `--header` makes the entry presentable — it carries the wording a selector would use if the value were ever set back to `ask`. Cheapest, and consistent with the entry being a decision already made.
2. **Emit `stage:` too**, and let `--header` mean what it said. That needs a stage to be chosen, which `fold` cannot infer from a consultation, so it would mean a second flag — and it still would not be asked while `default:` names a value rather than `ask`.

The first looks right. Folding an answer and immediately asking it again is a strange thing to want.

## Acceptance
- [ ] `--help` describes what the flag does
- [ ] whichever is chosen, a check covers whether the folded entry appears in `toggle ask-plan`
