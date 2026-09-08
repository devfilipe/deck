# #37 — The Jira reader calls an endpoint Atlassian has removed

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** a team whose board is Jira Cloud
**so that** `deck board` works against the service rather than against the stand-in that was written for it.

Repository: `deck`

`fetch_jira` requests `/rest/api/3/search`. Atlassian removed it. Against a live Cloud instance:

```
410 Gone — {"errorMessages":["The requested API has been removed. Migrate to the
/rest/api/3/search/jql API. A full migration guide is available at
https://developer.atlassian.com/changelog/#CHANGE-2046"]}
```

The Jira reader cannot read any Jira Cloud board today. The credentials were fine — `/rest/api/3/myself` answered with the account — and the instance reports `"deploymentType":"Cloud"`.

This is exactly the gap `WALKTHROUGH.md` names under "written, not yet proven": GitLab, Jira and Gerrit are exercised only against a local stand-in. The stand-in answers the old path because it was written to match the code, so the suite has been green over a call the service stopped serving.

**The replacement is not a rename.** `/rest/api/3/search/jql` pages by `nextPageToken` rather than `startAt`, returns no total, and requires `fields` to be asked for rather than defaulting. The change touches how a page is fetched and how a result is read, not just the URL.

Worth settling in the same change, since both are already open:

- **#28**, a tracker read stops at fifty and does not say so. The new endpoint pages by token, so whatever is decided there has to be built here anyway.
- Whether the stand-in should be written from what the API documents rather than from what deck sends.

That last one is the general lesson: a stand-in that mirrors the implementation tests that the implementation is itself, which is a check that cannot fail. Three providers are still only exercised that way.

### Acceptance
- [ ] `deck board list` reads a live Jira Cloud board
- [ ] paging works, and a read that stopped short says so
- [ ] the stand-in is written from what the API documents, not from what deck sends
- [ ] gitlab and gerrit are checked for the same drift, and either confirmed current or filed
