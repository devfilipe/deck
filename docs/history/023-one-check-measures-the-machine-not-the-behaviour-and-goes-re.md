# #23 — One check measures the machine, not the behaviour, and goes red under load

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone reading a red suite
**so that** a failure means something changed, not that the laptop was busy.

Repository: `deck`

`ci/smoke.sh` asserts that `deck statusline` answers in under 250 ms of wall clock. Measured on one machine while four agents were working on it: 239 ms, 255 ms, 265 ms — red in three runs out of six, on code nobody had touched.

Every other check in this suite is a claim about behaviour, and holds on any machine that can run the interpreter. This one is a claim about the machine, and it is the only check whose result depends on what else is running.

The thing it guards is real: the status line runs on every prompt, and one that takes a second is one somebody turns off. But a wall-clock threshold is a *threshold*, and this project already argues against those in `FOUNDATIONS.md` §4 under "A budget on a trend" — a number nobody chose, failing a delivery for being near a line.

Directions, none decided:

- **Measure work, not time.** Assert what the status line is allowed to do — no subprocess, no network, no walk of the registry — which is what actually makes it slow, and holds on a loaded machine.
- **Move it to the metric series.** `deck metrics` already records numbers over time and reports which way they are going. A status line drifting from 30 ms to 300 ms over a year is what anyone wants to know, and no single run can tell you.
- **Raise the number and say it is a smoke alarm.** Cheapest; keeps a threshold nobody chose, just further away.

The second is the honest one and it is what the tool is for.

### Acceptance
- [ ] the suite gives the same answer on a loaded machine as on an idle one
- [ ] whatever replaces it still notices a status line that becomes slow
- [ ] if a number survives anywhere, where it came from is written down

---

**Comment** · 2026-09-06

Better numbers, measured after four ladders had run on the same machine.

`deck statusline` against the 250 ms limit, three runs each, interleaved between the tree before a batch of four issues landed and the tree after:

| | |
|---|---|
| before | 1310, 693, 666 ms |
| after | 682, 555, 720 ms |

Indistinguishable, and **both two to three times over the limit on an idle-ish machine**. Under load during a gate run it measured 1142 ms and failed the `smoke` gate of a task that had nothing to do with it — the ladder for issue #25, whose change touches only the tracker stand-in and a trap.

So this is not a marginal check that flakes on a busy box. On this machine the command takes roughly 600 ms at rest, and the limit is 250. Earlier measurements in the 187–324 ms range came from a quieter machine, which is the point: the same code passes or fails depending on the hardware and what else is on it.

That also makes the failure actively misleading. It reddened a gate run, which reddens a ladder, which is the evidence a bundle reads — so a wall-clock assertion in the suite can make a change look unverified when nothing about it is.

---

**Comment** · 2026-09-06

Fixed. The check now counts what the status line does per prompt — child processes, sockets, and the render time measured in process where interpreter start-up is not part of it — rather than timing the whole command against a wall clock.

Replacing it immediately found the thing it was supposed to guard and could not: the bar spawns four processes per draw and three are the same `tmux display-message`. That is #31. On any fast machine four processes fit inside 250 ms, so the old assertion passed while the bar did three times the work it needed, and failed on a loaded machine while the bar was doing nothing wrong.
