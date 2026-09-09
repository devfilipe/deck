# #29 — A tracker source can be filtered and nothing says so

**open** · docs · opened 2026-09-06

---

**As** somebody pointing deck at a team board with a thousand items on it
**so that** narrowing it to the work that concerns this workspace does not require reading the source.

Repository: `deck`

Every tracker fetcher takes a `query:` from the descriptor — `source.get("query", "is:open")` for github, `state`/`labels` for gitlab, a whole `jql` for jira, `query` for gerrit. It is how you would filter by label, by milestone, by assignee, or to the component this workspace actually builds.

It appears in none of the documents. `PACKS.md` lists a tracker source as `{ type: jira | github | gitlab | gerrit, … }` and the ellipsis is the whole story; the descriptor template documents every other field it ships and not this one.

So the feature that makes a tracker source usable on a real board is the one nobody can find. The `docs` gate would not catch it either — it checks that every *command* is named, and this is a field.

Worth deciding alongside: whether the gate should check descriptor fields the way it checks commands. `couples:` was documented by hand recently, and nothing would have complained if it had not been.

### Acceptance
- [ ] a tracker source's filter is documented where someone writing a descriptor will meet it, with one worked example per provider
- [ ] the default, and what it means, is stated rather than implied
- [ ] whether descriptor fields are gated the way commands are is decided and written down
