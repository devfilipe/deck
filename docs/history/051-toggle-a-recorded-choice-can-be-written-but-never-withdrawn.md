# #51 — toggle: a recorded choice can be written but never withdrawn

**open** · — · opened 2026-09-07

---

`deck toggle` has `list`, `get`, `explain`, `set`, `profile`, `ask-plan`, `validate`. There is no way to remove a choice once recorded.

## How it comes up

Setting a toggle at a scope to see the mechanism work, then wanting the workspace default back:

```
$ deck toggle set gate_level build --at some-scope --why "..."
gate_level = build  (scope some-scope → .deck/toggles.yaml)

$ deck toggle unset gate_level --at some-scope
deck toggle: error: argument toggle_cmd: invalid choice: 'unset'
```

The only way out is hand-editing `.deck/toggles.yaml` and deleting the entry — which also means deleting the matching key under `reasons:`, and getting the mapping back to `{}` rather than leaving an empty block. A user who edits one and forgets the other leaves the file in a shape `validate` accepts and a reader misreads.

## Why it matters beyond tidiness

The asymmetry is the problem, not the missing verb. A recorded choice is meant to be a deliberate act with a reason attached, and `set` enforces that with `--why`. Withdrawing one is equally deliberate — a scope stops needing its own posture, a repository's exception is folded into the default — and right now that act leaves no trace at all, because the only way to perform it is outside the tool. The `reasons:` map records why every value is there and nothing records why one stopped being there.

It also makes the layering hard to explore. The whole point of `--at repo | scope | workspace | task` is that a value at one layer shadows another; trying a value at a narrow layer and then removing it to see the wider one resurface is the obvious way to learn what the layering does, and it is a one-way door.

## Shape

`deck toggle unset <toggle> [--at <layer>]`, refusing when nothing is recorded at that layer rather than silently succeeding, and saying which value becomes effective afterwards and where it comes from — the same sentence `explain` already knows how to produce. Whether withdrawal should also take a `--why` is worth deciding rather than assuming: `set` requires one, and the argument for symmetry is strong, but a reason for an absence has nowhere to live in the current file format.

Found while renaming a scope: the rename itself was two YAML keys, and proving the new name worked as a selector meant writing a toggle at it that then could not be taken back.
