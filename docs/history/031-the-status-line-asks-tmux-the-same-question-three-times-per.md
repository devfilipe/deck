# #31 — The status line asks tmux the same question three times per prompt

**open** · bug · opened 2026-09-06

---

**As** anyone whose prompt redraws all day
**so that** the bar costs what it needs to and not three times that.

Repository: `deck`

`deck statusline` runs four child processes every time it draws, and three of them are the identical call:

```
tmux display-message
git -C
tmux display-message
tmux display-message
```

That is `session_id()` in `config.py`, asked once per caller that needs it — the toggle layer, the workspace, the task file — with nothing between them remembering the answer. The answer cannot change during one render: it is the tmux window this process is in.

Found while replacing the wall-clock check that was supposed to catch exactly this and never could. On any developer laptop four processes fit inside 250 ms, so the old assertion passed while the bar did three times the work it needed; on a loaded machine it failed while the bar was doing nothing wrong. It was measuring Python start-up, which is around 600 ms here against roughly 40 ms of actual work.

The obvious fix is to remember the answer for the life of the process. Worth checking whether it is only `session_id()` — `Toggles()` and `Workspace()` are each constructed by more than one caller in a render, and a second construction is cheap only if nothing in it shells out.

There is now a check pinning the number, so the next thing added per prompt has to move that line and say why.

### Acceptance
- [ ] one render asks the terminal what session it is in at most once
- [ ] the answer is not cached beyond the process, since the next prompt may be in a different window
- [ ] the pinned number in the suite comes down with it
