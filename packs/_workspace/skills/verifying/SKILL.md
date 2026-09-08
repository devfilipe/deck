---
name: verifying
description: >
  How a change to deck is proven before it is claimed to work: the smoke suite,
  what it builds, and how to check behaviour against a real workspace without
  touching one. Use before reporting any deck change as done.
when_to_use: >
  "is this working", "run the tests", "before I commit", "did that break anything".
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Verifying a change to deck

```bash
./ci/smoke.sh        # everything
./ci/smoke.sh -v     # with each command's output
```

The suite builds a synthetic workspace and a pack in temporary directories, so
it runs anywhere and touches nothing anyone owns. Sections mirror the surface:
manifests, catalog, workspace resolution, impact graph, toggles, packs, mounting,
gates, measurements over time, board, trackers, setup, vendoring, proposals,
cost, console, diagnosis, merge-readiness bundle, the seeded pack.

The bundle section is the last one to use the shared synthetic workspace, on
purpose: it commits into those repositories, and a check added after it that
expected a clean tree would have to work around that. The sections after it —
the seeded pack, the workflow against the pack, the documents gate, a ladder
with no rungs — each build their own directory and clean it up.

Three of those read this repository rather than a synthetic one, because what
they check is this repository: that `.github/workflows/ci.yml` runs every gate
`packs/_workspace/config/gates.yaml` declares, and that the documents gate
behaves. The workflow itself cannot be run from here — GitHub Actions is not
available to the suite — so those checks read the workflow as parsed data and
say so, rather than pretending to have executed it.

## Writing a check

```bash
check      "<description>" "<expected substring>" "$DECK" <args…>   # must exit 0
check_fail "<description>"                        "$DECK" <args…>   # must exit non-zero
```

Three traps, all of which have cost time here:

- **Do not put a deck command in a pipeline.** `set -o pipefail` carries deck's
  non-zero exit even when the grep matched. Capture the output first, then test.
- **Do not wrap checks in a subshell.** `pass`/`fail` increment in it and are
  lost, so the section reports results and changes the totals by none.
- **Assert on the row, not the word.** `grep -c 'build '` also matches the ladder
  line `static -> build -> deploy`. Anchor the pattern.

When a command legitimately exits non-zero for an unrelated reason — `doctor` on
an incomplete workspace — assert on what it says, not on its status.

## Against a real workspace

Read-only commands are safe to run anywhere: `deck packs`, `deck doctor`,
`deck board list`, `deck gate list`, `deck setup --dry-run`. Use them to check a
change behaves on real data. Anything that writes gets a temporary directory.

## The standard

A defect found by hand becomes a check in the same commit. Otherwise the next
person rediscovers it, and the suite's passing means less each time.
