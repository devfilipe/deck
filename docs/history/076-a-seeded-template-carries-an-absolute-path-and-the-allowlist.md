# #76 — A seeded template carries an absolute path, and the allowlist's reason for seeding path does not cover one

**open** · — · opened 2026-09-07

---

`SEEDED_REPO_FIELDS` seeds `path`, with the reason written beside it:

```python
"path",  # the layout below the root, which is the root's job to differ, not this one's
```

That holds when a repository sits below the workspace root: `build/sources/thing` is the same on everybody's machine, and only the root differs. It does not hold when the path is absolute, which the descriptor explicitly allows — "something you edit is a repository and belongs under `repos:` even when it sits outside this tree".

Seeding such a workspace writes somebody's home directory into a file a team versions:

```yaml
repos:
  some-engine:
    path: /home/<username>/workspace/clones/<account>/some-engine
    role: 'the engine'
    impacts: [some-checks]
```

## Why it matters

The field is not merely useless on the next machine — it is **wrong in a way that looks right**. A second person copying that template gets a descriptor that resolves to a path they do not have, and the failure arrives later, from a command that says a repository is not on disk rather than that the template was never portable.

And it is a small disclosure, the same class as #56: a username and a directory layout in a public or shared file, put there by a command whose whole job is stripping what is local.

## Shape

The distinction the allowlist needs is not `path` versus not-`path`, but **relative** versus **absolute**. A relative path is layout and travels; an absolute one is this machine and does not.

What to write instead is the real question, and it has more than one defensible answer:

- **Drop the field**, leaving the repository named with its role and edges and no path. Honest, and the template no longer initialises a working descriptor without an edit — which may be right, since it never could have.
- **Write a placeholder** the reader must replace, so the shape is visible and the failure is at edit time rather than at run time.
- **Write it relative to the root anyway** where that is expressible, and drop it only when the path escapes the root.

Whichever is chosen, the comment block the seeded file already carries should name `path` among the fields that did not travel, the way it names the others — a field removed in silence is one somebody puts back.

## Acceptance
- [ ] a seeded template carries no absolute path
- [ ] a repository below the root still seeds its relative path, unchanged
- [ ] the seeded file says what was dropped and why, as it already does for other fields
