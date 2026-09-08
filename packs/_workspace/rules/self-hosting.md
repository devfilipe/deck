---
paths: ["plugins/deck/**", ".deck/**", "docs/board.yaml"]
---

# This workspace is the tool that manages it

`~/.local/bin/deck` is a symlink into this checkout. An agent editing
`plugins/deck/deck/` therefore changes the binary it is running — including the
one that will run the gates meant to catch the break. A half-applied edit does
not fail loudly; it disables the thing that would have said so.

**When agents will edit this tree, work on a copy:**

```bash
git clone . ~/sandbox/deck-self/deck
git clone ../deck-acme ~/sandbox/deck-self/deck-acme
deck board plan   # with DECK_ROOT pointing at the copy
```

Then read the diffs and take what survives review. `deck doctor` reports the
self-hosting case as a warning so nobody has to remember this unprompted.

`.deck/` is not versioned here either, for the same reason it is not versioned
anywhere: it is machine state. The knowledge in it — the roles, the edges, the
pack root — lives in `seed/`, which a contributor copies once. A tool that
exempts itself from its own rule is a tool nobody should believe.
