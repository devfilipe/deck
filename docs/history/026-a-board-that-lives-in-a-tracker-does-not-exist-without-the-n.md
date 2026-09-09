# #26 — A board that lives in a tracker does not exist without the network

**open** · feature · opened 2026-09-06

---

**As** anyone working where the network is not guaranteed
**so that** losing DNS for a minute does not mean losing the board.

Repository: `deck`

Every `deck board` command that reads a tracker is a live request. There is no cached read. When the resolver went down on this machine — the network itself was fine, `1.1.1.1` answered — the board simply was not there:

```
$ deck board list
no tasks found
  ! github: <urlopen error [Errno -3] Temporary failure in name resolution>
```

deck reported it correctly and did not pretend the board was empty, which is the important half and already works. The other half is that a file board would have kept working, and this repository migrated away from one.

It reaches further than `board list`. `bundle` consults the board to say whether a task is on it and which repositories it names; `board plan` cannot group what it cannot read. So an outage does not only hide the list, it degrades the merge-readiness page a reviewer is meant to trust.

What makes this worth solving rather than tolerating: a tracker board is *someone else's* state, and the whole argument for pointing at one is that it already holds the shared truth. A cache has to keep that argument honest — a stale read that looks live would be worse than no read at all, which is the failure this project refuses everywhere else.

Directions, none decided:

- **Cache the last successful read, and always say how old it is.** Never silently: `board list` prints the age and the fact that it is a cache, every time. `claim` and any other write still refuse without the network, because writing against a stale board is how two people take one task.
- **Cache only for the commands that report, not the ones that decide.** `bundle` and `board show` may read a cache; `plan` and `claim` may not. That is the same reports-versus-decides line already drawn for couplings, and it may be the right one here too.
- **Nothing, and say so in the documentation.** A tracker board needs the network, and a team that works offline should keep a tasks file. Honest, and it makes the choice of source a bigger decision than it currently looks.

### Acceptance
- [ ] a read served from a cache is never mistakable for a live one
- [ ] a write against a board deck could not read is refused
- [ ] whichever way it goes, choosing a tracker source says what it costs when the network is gone
