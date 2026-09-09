# #36 — setup --dry-run plans work the real run refuses to do

**open** · bug · opened 2026-09-06

---

**As** somebody who added a repository to a workspace that already has a descriptor
**so that** the rehearsal and the run agree about what is going to happen.

Repository: `deck`

`deck setup --create-packs --repos <new-repos> --dry-run` prints a plan:

```
  no pack  <repo-a>   create <packs>/<repo-a>
  no pack  <repo-b>   create <packs>/<repo-b>
```

The same command without `--dry-run` refuses:

```
  This workspace already has …/.deck/workspace.yaml.
  `deck doctor` says what is missing; `deck setup --force` starts over.
```

So the rehearsal says it will create two packs and the run declines to do anything. A dry run whose plan the real command will not carry out is worse than no dry run: it is a claim about what is about to happen, and this project refuses claims like that everywhere else.

The refusal itself is right — `setup` writes a descriptor, and overwriting one that is in use would be the destructive thing. `--force` is right too, and is right to be scary. What is missing is the case in between, which is the ordinary one: a workspace that already works gains a repository, and that repository needs a pack.

`setup`'s own closing summary already names the way through, in the same output as the refusal:

```
  3. 2 repositories have no pack yet.
     deck pack new <name> --dir <packs>/<name>
```

That works — measured, two packs created, `doctor` reports them in merge order. So this is not a missing capability; it is `--dry-run` describing a path the command will not take when the descriptor exists.

Three ways out, and they are not equivalent:

- **`--dry-run` refuses too**, with the same message and the same pointer to `pack new`. Smallest, and it makes the rehearsal honest.
- **`--create-packs` works on an existing descriptor** and only ever adds packs, never touching the descriptor. Most useful, and it needs a clear statement that `setup` is then two things wearing one name.
- **Say it in the plan.** The dry run keeps showing what a fresh workspace would get, and labels the part that will not happen here.

### Acceptance
- [ ] `--dry-run` and the real run agree about what will happen on a workspace that already has a descriptor
- [ ] a repository added to a working workspace can be given a pack without `--force`, or the command says which one to use
- [ ] `--force` keeps meaning start over, and keeps being the only thing that overwrites a descriptor
