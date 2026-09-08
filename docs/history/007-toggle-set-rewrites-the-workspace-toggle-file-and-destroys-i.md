# #7 — toggle set rewrites the workspace toggle file and destroys its comments

**closed** · bug · opened 2026-09-06 · closed 2026-09-07

---

**As** someone who reads `.deck/toggles.yaml` to understand what is decided here
**so that** setting one value does not silently delete the header that explains the file.

Repository: `deck`

`_record` writes through `dump_yaml` → `yaml.safe_dump`, which rewrites the whole file. The first `deck toggle set --at workspace` in a fresh workspace wipes the shipped header — the block explaining layer precedence, `ask`, and now `reasons:`.

It was always true, and it matters more now that the header carries more that is worth keeping. Round-tripping comments needs `ruamel.yaml` or equivalent, so this is a dependency decision as much as a bug: `deck` currently depends on `pyyaml` alone.

### Acceptance
- [ ] a comment in the toggle file survives a `toggle set`, or the file is written in a form that never had comments to lose
- [ ] whichever is chosen, the dependency consequence is stated in the documentation
- [ ] a check covers it
