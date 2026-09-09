## What changes, and why

<!-- The consequence, not the diff. What was true before and is not now. -->

## The ladder

```
deck gate run --task <this branch>
```

- [ ] `ruff` — lint and format
- [ ] `catalog` — the toggle wording, `--strict`
- [ ] `docs` — every command is named in the documentation
- [ ] `smoke` — the suite

If one did not run, say which and why. A gate that did not pass is never
reported as passed.

## The checks that come with it

<!--
A defect fixed comes with the check that would have caught it. If this is a fix
and adds no check, say why one is not possible — several fixes here were half
fixes because the check only asserted a string existed in a file.
-->

## Documents

- [ ] A user-visible change updates README / WALKTHROUGH / DESIGN / FOUNDATIONS / PACKS
- [ ] Every number stated was measured, not recalled
- [ ] The changed behaviour was hunted in every document, not only the one edited

## What this does not do

<!--
Anything you left out, could not verify, or decided against. This section being
empty is unusual and worth a second look.
-->
