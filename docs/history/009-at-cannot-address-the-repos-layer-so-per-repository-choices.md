# #9 — --at cannot address the repos layer, so per-repository choices are hand-edited only

**open** · feature · opened 2026-09-06

---

**As** someone recording a decision that belongs to one repository
**so that** the layer deck reads is a layer deck can also write.

Repository: `deck`

`deck toggle set --at` takes `task`, `workspace` or a declared scope. The `repos:` layer is read by `layers()` and resolved correctly, and there is no command that writes it — so a per-repository choice, and now its `--why`, must be hand-edited into `.deck/toggles.yaml`.

The obstacle is real and worth stating in whatever is decided: a repository name could collide with a scope name, so `--at <name>` alone is ambiguous.

### Acceptance
- [ ] a per-repository choice can be recorded by a command, with its reason
- [ ] a name that is both a repository and a scope is refused or disambiguated, never guessed
- [ ] reading a hand-written `repos:` block keeps working exactly as it does now
