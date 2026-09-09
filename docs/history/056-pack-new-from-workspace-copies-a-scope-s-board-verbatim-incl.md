# #56 — pack new --from-workspace copies a scope's board verbatim, including who is asking for it

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`--from-workspace` seeds a pack's descriptor template from the machine's own registry, through an allowlist. The rule behind that allowlist is written into the file, in capitals:

> WOULD THIS VALUE STILL BE TRUE ON THE NEXT PERSON'S MACHINE?

`SEEDED_REPO_FIELDS` applies it per repository. `scopes:` gets no filter at all — it is copied whole, and a scope's `backlog:` carries a tracker source:

```yaml
scopes:
  some-initiative:
    backlog:
    - type: jira
      url: https://example.atlassian.net
      project: ABC123
      user: someone@example.com     # <- travels into the shared template
```

`user:` is the account the credentials belong to. It is per person by design — everybody authenticates as themselves — and #49 established that a shared file naming one of them is both wrong and a small disclosure, which is why comparing it stopped counting as drift. The seed puts it straight back.

## Reproduce

Seed a pack from a workspace whose scope has a tracker `backlog:` with a `user:`, then read `templates/workspace/workspace.yaml`. The field is there.

Found by re-seeding a real pack while verifying #44, and the leak went into a versioned template before it was noticed.

## Shape

`workspace.BOARD_IDENTITY` already names the fields that say *which board* rather than *who is asking* — it was added for #49 and is exactly the filter this needs. A seeded scope's backlog should keep those and drop the rest, the way a seeded repository keeps `SEEDED_REPO_FIELDS`.

Worth deciding at the same time whether anything else in a scope is machine-local. `title` and `repos` are not. A scope naming a repository the template does not carry would be, but the registry and the scopes are seeded together, so that case does not arise from this command.

## Acceptance
- [ ] a seeded scope's board keeps what identifies the board and drops what identifies the person
- [ ] the comment in the seeded file says which fields were dropped, as it already does for repositories
- [ ] a scope with no `backlog:` seeds exactly as it does now
