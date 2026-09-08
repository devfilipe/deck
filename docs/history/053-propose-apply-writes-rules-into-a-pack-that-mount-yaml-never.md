# #53 — propose apply writes rules into a pack that mount.yaml never names, so nothing delivers them

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`deck propose apply <file> --into <pack>` writes the drafted rule files into `<pack>/rules/` and reports each one by name. It does not add them to `<pack>/config/mount.yaml`.

`mount.yaml` is what decides which rules `deck mount` places. A rule that is not listed there is a file on disk and nothing else.

## Reproduce

```
$ deck propose apply pack-20260101-120000.json --into packs/some-repo --yes
  rules/checks-are-black-box-never-run-commands-on-the.md
  rules/verdict-selection-distinguishes-not-applicable.md
  ...

  Read what landed. A draft is a starting point, and a gate you have not
  run is a gate you do not have.

$ grep -c 'file: rules/' packs/some-repo/config/mount.yaml
0

$ deck mount --repo some-repo --dry-run
would mount for task …, across 1 repository
  (none of the five)
```

Confirmed by copying a pack, emptying its `rules/`, applying, and comparing the md5 of `config/mount.yaml` before and after: unchanged.

## Why this is worse than a missing step

The report reads like delivery. It lists each rule by path, then closes with advice about reading what landed and about gates you have not run — the whole shape of the message says the pack now carries these. Five packs here received twenty-two rules across one session and delivered none of them; the first pack in the set looked correct only because its `mount.yaml` had been edited by hand earlier, which is what made the difference visible at all.

It is the same failure as a rule that is placed but never loaded: placed, counted, reported, and read by nobody. The tool's own line — *a gate you have not run is a gate you do not have* — applies exactly here, and the surface it applies to is the one printing it.

## Shape

Two defensible answers, and the choice is worth making explicitly rather than by default:

1. **`apply` writes the mount entries too.** It already knows the file names it wrote and the pack directory. The argument against is that `mount.yaml` is hand-curated — entries carry `repos:` scoping — and appending an unscoped entry is a guess about intent.
2. **`apply` refuses to claim delivery it did not arrange**, and says plainly that the rules are on disk and not yet mounted, naming the file to edit. Cheaper and no guessing, but it leaves a step a person forgets.

There is a third thing worth having either way: `deck doctor` can see a `rules/*.md` in a pack that no `mount.yaml` names, and that is a fact it can report without deciding which of the two answers is right.

## Related

The `example.md` scaffolding that `pack new` writes is also not in `mount.yaml`, correctly — it carries `paths: "**/*.example"` and is meant as a sample. That is the precedent for a rule file legitimately going unmounted, and it is why an unmounted rule cannot simply be treated as an error.
