# #66 — ask fold matches the answer against a toggle's values case-sensitively, so a sentence never names one

**open** · — · opened 2026-09-07

---

`deck ask fold --as toggle` picks the toggle's default by looking for one of the values inside the answer. The comparison is case-sensitive, so an answer written as a sentence almost never matches — because the word it would match is the one a person capitalises.

`plugins/deck/deck/cmd_ask.py:270`:

```python
default = args.default or next((v for v in values if norm(v) in norm(entry["answer"])), None)
```

`config.norm` turns a value into a string and normalises booleans. It does not lowercase:

```python
def norm(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)
```

## Reproduce

A consultation with options `reject` and `accept-and-log`, answered "Reject it. A malformed frame is not a frame.":

```
$ deck ask fold <id> --as toggle --into <pack> \
    --impact "reject=…" --impact "accept-and-log=…"
deck: REFUSED
  the answer does not name one of the values, so deck cannot tell which is the default.
    values: reject, accept-and-log
    Pass --default <value>.
```

The answer names it in the first word.

## Why the refusal is right and the match is wrong

Refusing beats guessing here — deck genuinely cannot invent which value was chosen, and `--default` is the right escape hatch. The defect is that the refusal fires on an answer that *does* name a value, which trains people to pass `--default` always and makes the matching dead weight.

It is also the wrong half to be strict about. The comparison is a convenience for reading a person's sentence; a person writing prose starts with a capital, and the first word of an answer to "which of these two" is very often the value itself.

Found by an agent updating `deck-acme`, which reworded the demo's answer rather than pass `--default` — so the workaround was to write worse prose.

## Shape

Case-fold both sides for this comparison. Whether `norm` itself should lowercase is a separate and larger question — it is used for identity comparisons elsewhere, where folding case would change what counts as the same thing, so the fold belongs at this call site rather than in `norm`.

Worth deciding at the same time whether a *substring* match is right at all: `accept` would match inside `accept-and-log`, and an answer naming both values would take whichever appears first in `values:`. Refusing an ambiguous answer may be better than picking one.

## Acceptance
- [ ] an answer that names a value in any case is recognised
- [ ] `norm` is unchanged, or the change is argued separately
- [ ] an answer naming no value is still refused, and still names `--default`
