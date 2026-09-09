# Changelog

Notable changes, newest first. deck follows no release cadence yet; entries are
grouped by what they changed rather than by date.

Until the 0.1.0 tag, the published tree is a single commit, rewritten by force
push as work lands. That is deliberate and it is temporary: it keeps the first
release readable as one statement of what deck is, rather than a transcript of
it being built. It also means no pull request can be relied on to survive, which
is why there are none.

0.1.0 is a photograph, not a promise. It is cut when what the documents claim is
true and the ladder is green — not when the work is finished, which is a bar no
version ever clears.

From that tag, changes arrive by pull request and history stops being rewritten.
The two cannot overlap — a force push orphans the commits a pull request points
at — so the switch is a single moment, not a gradual one. Tags survive it: each
one stays reachable as a complete tree however often `main` was rewritten before
it.

The format is deliberately plain: what changed, and why it mattered. A line that
cannot say why is usually not worth an entry.

## 0.1.0

The first release. What is written here is what deck is on the day it was
tagged, rather than a history of how it got there — the development happened
before this tree existed, and republishing it would have been a transcript
rather than a statement.

Cut against the standard this project holds everything else to: what the
documents claim is true, the ladder is green, and the ledger of what has *not*
been proven is accurate. Two entries stand in `WALKTHROUGH.md` under "written,
not yet proven" — GitLab, Jira and Gerrit are exercised only against a local
stand-in, and `propose pack` has been run against one real repository once —
and one in `FOUNDATIONS.md` §4: the board workflow has never been pointed at a
workspace anyone depends on. Those are the shape of a 0.1.0 rather than an
oversight in it.

596 checks, five gates, and a board that is this repository's own issue tracker.

## Unreleased

The first public tree. Everything below is what deck is on the day it was
published, rather than a history of how it got there — the development happened
in private and squashing it loses nothing a reader wants.

See [README.md](README.md) for what deck is, and
[FOUNDATIONS.md](FOUNDATIONS.md) §4 for what it does not cover yet.
