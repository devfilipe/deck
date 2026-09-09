# #20 — claim reports an assignment GitHub silently discarded

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** someone relying on a claim to stop two people picking up one task
**so that** the one guarantee the board makes is not reported as kept when it was not.

Repository: `deck`

`trackers.claim()` for github POSTs to `/issues/{n}/assignees` and returns `f"assigned {task_id} to {who} on github"` without reading the response. GitHub answers 201 and an issue object whose `assignees` shows what it actually did — and it silently drops a name that is not a valid assignee on that repository.

Measured here, against the live service:

```
$ deck board claim "#5" --yes
assigned #5 to nemo on github

$ gh issue view 5 --json assignees
{"assignees":[]}
```

Nothing was assigned. deck said it was.

This is the failure deck refuses everywhere else: a gate that did not pass is never reported as passed, an unresolved variable is a hole rather than an empty string, a mount reports what it placed. The tracker write is the one place that takes an API's word for it without looking.

The `gitlab` branch in the same function does not have this problem — it looks the user up first and raises `no gitlab user named X`. So the asymmetry is already visible in the file; github, jira and gerrit should be held to what gitlab already does.

Two failures compound here and they are separate issues: #4 is why the name was wrong (`$USER`, a shell login, not a GitHub account). This one is why nobody found out.

### Acceptance
- [ ] a claim reports what the tracker actually recorded, not what was requested
- [ ] a name the tracker will not accept is an error naming the name, before or after the write
- [ ] gitlab keeps behaving as it does today
- [ ] jira and gerrit are checked for the same shape of silence, and either fixed or stated to be safe

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#20.json, and `deck bundle --task #20` reports READY. The commit naming this issue is attributed to it by the bundle.
