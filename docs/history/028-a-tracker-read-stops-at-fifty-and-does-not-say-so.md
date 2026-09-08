# #28 — A tracker read stops at fifty and does not say so

**open** · bug · opened 2026-09-06

---

**As** anyone whose board is larger than fifty items
**so that** a board that shows less than it holds says which.

Repository: `deck`

Every tracker fetch asks for one page and takes what comes: `per_page=50` for github and gitlab, `maxResults=50` for jira, `n=50` for gerrit. None of them pages, and none reports having stopped.

A board of fifty-one items reads as a board of fifty. `board plan` then groups the work it can see, and `bundle` says whether a task is on a board it may not have read to the end.

This repository has twenty-seven issues, so nothing here is affected. Any team board is over fifty within a quarter, and the failure is silent by construction — which is the shape deck refuses everywhere else: an unresolved variable is a hole rather than an empty string, a gate that could not run is not one that passed.

Paging is the obvious answer and it is not obviously right: a board command that fetches ten pages before printing is slow in the one place a person is waiting. The alternative is to keep the single page and be loud — say the source held more, and name the `query:` that would narrow it.

Related: #26, on what a tracker board is worth without the network. Both are about the read being less trustworthy than it looks.

### Acceptance
- [ ] a source with more items than one page either returns them all, or says how many it did not
- [ ] whichever is chosen, no board command silently acts on a partial read
- [ ] the four providers behave the same way as each other
