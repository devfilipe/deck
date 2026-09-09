# #42 — GitLab is read, written and never run against GitLab

**open** · written-not-proven · opened 2026-09-06

---

**As** a team about to point deck at GitLab
**so that** the provider that has never met the service is not the one they find out about in production.

Repository: `deck`

`fetch_gitlab`, `claim` and `create` all have GitLab branches, and every check that exercises them runs against the local stand-in. No request has ever reached gitlab.com or a self-hosted instance.

That was true of Jira too, and Jira turned out to be calling an endpoint the service had **removed** — the reader could not read any board at all, and the suite was green the whole time because the stand-in answered the path deck asked for. #37 fixed the endpoint and rewrote the stand-in so a path no reference documents is a 404, which is the structural half. GitLab's routes were checked against current documentation during that work and are current, so this is not the same bug.

It is the same *exposure*. Two things are known to be worth confirming against a live instance:

- **Paging.** GitLab returns `X-Next-Page` and deck ignores it, so a read stops at fifty and says nothing — #28. The Jira fix pages to the end and reports a short read; GitLab still does neither, and nobody has seen what a board over fifty actually does.
- **`assignee` versus `assignees`.** deck reads the singular, which the reference marks deprecated in favour of the plural. It is still returned today. "Still returned today" is exactly the sentence that preceded the Jira removal.

Beyond those, the things only a live run settles: whether the token scopes deck asks for are the ones an instance actually requires, whether a self-hosted instance behind a path prefix resolves, and whether the error bodies deck surfaces are legible when something is refused.

`WALKTHROUGH.md` lists this under "written, not yet proven", which is honest and is why this issue exists rather than a claim that it works.

### Acceptance
- [ ] `deck board list`, `claim` and `create` are each run against a live instance and the result recorded
- [ ] paging is settled for this provider, whichever way #28 goes
- [ ] `assignee` versus `assignees` is decided before the deprecation lands, not after
- [ ] the walkthrough row moves out of "written, not yet proven", or says exactly what is still unproven
