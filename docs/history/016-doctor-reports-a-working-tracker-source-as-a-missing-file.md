# #16 — doctor reports a working tracker source as a missing file

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone whose board lives in a tracker
**so that** a healthy workspace is not accused of a missing file that was never supposed to exist.

Repository: `deck`

`doctor` walks `backlog:` and does `path = root / source.get("file", "")`, then warns when that is not a file. A tracker source has no `file:` at all, so the check resolves to the workspace root, fails, and prints:

```
backlog sources
  !! github  missing: None

1 warning(s):
  !! backlog github: file missing
```

The source is fine — `deck board list` reads fourteen issues through it in the same second. Found by migrating this repository's own board from `docs/board.yaml` to GitHub Issues, which is the first time a tracker source has been pointed at a real server rather than a local stand-in.

Two things are wrong at once: a working source is reported as broken, and the word `None` reaches a user, which means nothing to anybody.

What a tracker source can be checked for is a different question and worth answering in the same change: that it has the keys its kind needs (`repo:` for github, `url:` for jira), and — only under `--net`, like the target check — that it answers.

### Acceptance
- [ ] a tracker source with the keys its kind needs is reported OK, with no warning
- [ ] a tracker source missing a required key is reported, naming the key
- [ ] a file source keeps being checked exactly as it is today
- [ ] no message ever prints `None` for a value that was never set

---

**Comment** · 2026-09-06

Verified under the deck ladder: 4 gates passed, evidence in .deck/gates/#16.json. The commit naming this issue is attributed to it by `deck bundle`, which reports READY.
