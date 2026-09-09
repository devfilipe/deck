# #44 — pack new --force silently overwrites a pack's config, including gates somebody wrote

**closed** · bug · opened 2026-09-06 · closed 2026-09-07

---

**As** somebody re-seeding a pack template from a workspace that has grown
**so that** refreshing one file does not quietly discard the knowledge the pack was carrying.

Repository: `deck`

`deck pack new <name> --dir <existing pack> --from-workspace --force` rewrites the pack's whole `config/` directory. Measured: a `_workspace` pack that held a declared gate and two mounted rules came back with `gates: []` and an empty `rules:` list. The rule files and `bin/` survived; the declarations that made them do anything did not.

Nothing said so. The command's closing words were about targets being left empty on purpose, which is a deliberate and well-explained decision about one field, printed while three others were being emptied without mention.

The scaffolding itself is right — a new pack needs a `config/` — and `--force` is right to exist and right to be the thing you have to ask for. What is wrong is that `--force` is one word covering two very different acts: *overwrite the descriptor template I asked you to re-seed*, and *reset everything else in this pack to blank*.

Worth noting how it was found, because it is the shape of the damage: the pack was re-seeded to check whether a scope travels into version control. It did, the check succeeded — and the same command deleted a gate and two mount entries that had nothing to do with the template. Neither loss appeared in the output; both were noticed later, by running `deck mount --dry-run` and counting.

Three things to settle:

- **Which files `--from-workspace` actually needs to write.** It seeds `templates/workspace/workspace.yaml`. Rewriting `config/gates.yaml`, `config/mount.yaml`, `config/toggles.yaml` and `config/detect.yaml` is scaffolding a *new* pack, not seeding an existing one's template.
- **What `--force` should mean on a pack that already holds work.** Refusing unless the pack is empty, and offering a narrower flag for the template alone, is one answer. Rewriting only what was asked for is another and probably better.
- **Whether anything overwritten should be reported.** deck says what it places when mounting and what it removes when unmounting. A command that empties four declarations should be able to say it did.

### Acceptance
- [ ] re-seeding a template does not empty declarations the pack already carried
- [ ] whatever `--force` overwrites, the command names it before or after doing it
- [ ] scaffolding a genuinely new pack still works exactly as it does now
