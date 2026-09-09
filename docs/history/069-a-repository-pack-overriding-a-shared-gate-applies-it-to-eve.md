# #69 — A repository pack overriding a shared gate applies it to every repository

**open** · — · opened 2026-09-07

---

`gates.py::_merge` gives a **new** gate id declared by a repository-named pack a default `only_repos: [<that repo>]`. An entry carrying `overrides: true` gets no such default, so overriding a shared gate replaces it for the whole workspace.

Measured on four repositories, where a pack named after one of them overrode `_common`'s `build`:

```
$ deck gate list
  ->  build   ...   runs
      over catalog-api, catalog-schema, catalog-web, catalog-docs
```

All four now run the command that one repository declared for itself.

Adding `only_repos:` to the override does not fix it — it narrows the gate for everyone, so the other three lose `build` entirely. **There is no way for a repository pack to specialise a shared gate for itself.**

## Why the asymmetry is the defect

The default on a new gate is right, and the reasoning behind it is sound: a pack named after a repository is speaking for that repository, so what it introduces applies there. An override is the same pack speaking about the same repository — it is the *scope* that should stay, and only the command that changes.

As it stands the two paths through one function disagree about who a repository pack speaks for, and the disagreement is silent. `deck gate list` prints the widened gate with the overriding pack's command and no indication that a repository-scoped pack just changed the ladder for repositories it has nothing to do with.

Specialising a shared gate per repository is not an exotic want. It is the ordinary case: everybody builds, and one repository builds differently.

## Shape

Default an override's `only_repos` to the declaring pack's repository, the way a new gate's already is — then a repository pack can specialise, and the shared gate survives for everybody else.

That leaves a question worth answering deliberately rather than by omission: **how does a shared pack legitimately change a gate for the whole workspace?** Today that is what an override does, and this change would remove it. Either `_common` (a pack not named after a repository) keeps the current behaviour, which is consistent — it speaks for everybody, so its override applies to everybody — or an explicit `only_repos: []` means all, and silence means the pack's own.

Until it is settled, a warning when an override widens a gate beyond the pack that declares it is strictly better than the current silence.

## Acceptance
- [ ] a repository pack overriding a shared gate changes it for that repository only
- [ ] the shared gate still runs, unchanged, everywhere else
- [ ] a pack that is not named after a repository can still change a gate workspace-wide, and how is stated
- [ ] `deck gate list` shows which repositories an overridden gate actually runs over
