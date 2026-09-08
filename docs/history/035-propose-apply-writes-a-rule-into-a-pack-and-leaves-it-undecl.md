# #35 — propose apply writes a rule into a pack and leaves it undeclared

**closed** · bug · opened 2026-09-06 · closed 2026-09-07

---

**As** somebody who has just paid for a pack draft
**so that** what was written is what an agent gets, without a second step nobody mentions.

Repository: `deck`

`deck propose apply … --into <pack>` writes each drafted rule as a file under the pack's `rules/` and stops there. It does not add the entry to that pack's `config/mount.yaml`, and `mount` places only what `mount.yaml` declares. So the rules exist, the command reports writing them, and nothing mounts.

Measured twice on a real workspace, a day apart: five rules from a **$1.42** draft landed as files, `deck mount --dry-run` placed none of them, and the gap was found by looking rather than by being told. The scaffolded `mount.yaml` ships `rules:` with the key present and every example commented out, so the file looks tended rather than empty.

The command's own closing advice — *"Read what landed. A draft is a starting point, and a gate you have not run is a gate you do not have"* — is right about gates and silent about this. A rule nobody declared is a rule nobody has, and it is worse than an unrun gate: an unrun gate is at least visible in `deck gate list`.

Note that this is not the same as the `toggles` behaviour, which is deliberate and says so: *"Toggles were NOT written: a catalog entry needs wording a person will answer."* That refusal is announced and reasoned. This one is neither.

Three ways it could go, and the third is the floor:

- **Declare them.** `apply` appends the entries it just wrote. The pack is data a person reviews, and appending a line per file it also wrote is not deck forming an opinion.
- **Refuse to write an undeclared rule**, the way it refuses a toggle, and say what the operator must add. Consistent with the toggle case, and it makes the person do work a command could do.
- **Say so.** Whatever else, the closing advice must name the step. Today the only way to find out is to run `mount --dry-run` and count.

### Acceptance
- [ ] a rule `apply` wrote is mounted by the next `deck mount`, or the command says plainly what is still needed
- [ ] a pack whose `mount.yaml` a person has hand-edited is not rewritten around them
- [ ] a check covers the round trip: draft, apply, mount, and the rule reaches the repository

---

**Comment** · 2026-09-07

Fixed by #54, which landed as a duplicate of this: I filed the same defect as #53 without checking the open list first, and #53 is what the pull request closed.

The fix is what this issue asked for — `apply` writes the `mount.yaml` entry, unscoped, and `deck doctor` reports a rule a pack holds that `mount.yaml` does not name, whoever put it there. Eight checks, six of which fail without it.

This issue said it better than mine did in one respect: it measured the cost. Five rules from a $1.42 draft landed as files and `mount --dry-run` placed none of them.
