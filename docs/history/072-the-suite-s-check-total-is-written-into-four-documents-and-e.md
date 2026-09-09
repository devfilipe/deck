# #72 — The suite's check total is written into four documents, and every change edits all four

**open** · — · opened 2026-09-07

---

The number of checks in `ci/smoke.sh` appears in four places:

```
README.md:275       ./ci/smoke.sh    # 724 checks against a synthetic workspace…
WALKTHROUGH.md:449  724 checks cover this, against a synthetic workspace…
DESIGN.md:720       …the observable behaviour: 724 checks covering resolution,…
CONTRIBUTING.md:44  ~724 checks against synthetic workspaces in temporary directories…
```

The `docs` gate compares them against a real run, so they never drift — the number is always right. What it costs is paid on every change instead.

## What it costs

**Four edits per pull request.** Every change that adds a check edits four documents that have nothing to do with it, and a reviewer reads four one-line diffs that say nothing about the change.

**A guaranteed conflict between any two branches.** Two branches that both add a check both edit the same four lines, and the second one rebases through four conflicts whose resolution is neither side's number but the sum. That happened here today, between two unrelated fixes.

**It is the one number in the documents that cannot be written by hand.** Everything else in them is a claim a person makes and the gate checks; this is a count only the suite knows, copied into prose four times.

## Shape

One place holds it, and the others refer to it. Which place, and how the others refer, is the decision:

- A generated line in one document, with the other three linking to it. Cheapest, and it makes three documents slightly less self-contained.
- A small file the suite writes — `ci/checks.count` or similar — that the documents point at rather than quote. Honest about what it is, and adds a generated file to the tree.
- The documents stop stating the number and say what it is instead ("every command, against a synthetic workspace built in a temporary directory"), leaving the count to the suite's own output. The count in prose is a proxy for coverage anyway, and a reader who wants it runs the suite.

The third is worth weighing seriously. The number's value to a reader is roughly "is this well tested", which a total answers badly — it grows when a check is split and it does not say what is covered. Whereas the value to *deck* is real: the `docs` gate catches a documentation change that quietly stopped matching the suite.

Whatever is chosen, the `docs` gate's `--counts` mode has to follow, since checking four copies is its current job.

## Acceptance
- [ ] adding a check to the suite does not require editing four documents
- [ ] a reader still learns what the suite covers
- [ ] the `docs` gate still fails when a document makes a claim about the suite that the suite does not support
