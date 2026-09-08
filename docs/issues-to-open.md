# Issues to open

Drafted from real use, not yet filed at github.com/devfilipe/deck/issues.
Delete an entry once it is filed, and put the issue number in the commit that
fixes it.

---

## The SessionEnd hook unmounts work that other panes are still using

**Type:** bug · **Severity:** loses work · **Found:** 2026-09-05, first real
use of deck on a multi-repo product workspace.

`session_id()` derives from the tmux `session:window` deliberately, so that two
panes of one window are one task — a split screen is one piece of work. The
plugin separately registers `SessionEnd -> deck unmount --session`, so nothing
is left behind in a product repository.

Each decision is right on its own. Together they mean **any pane closing tears
down the whole task**, including for panes that are still open and working.

**Repro**

1. `deck mount --repos <repo> --task T1` in one pane.
2. Open `claude` in a second pane of the same tmux window.
3. Close the second pane.
4. The rules, the `.claude/` directory and the root `CLAUDE.local.md` are gone,
   and the first pane is still open with no warning that its context left.

**Observed**

A task mounted at 18:19:15 was fully unmounted at 18:23:37 when a second,
read-only pane was closed. The pane doing the work carried on with its rules
silently removed.

**What makes it worse**

The natural way to check that a mount worked is to open Claude in the
repository. Done from the same window, the check destroys the thing it checks.
So the failure is most likely to hit someone on their first attempt.

**Directions, none decided**

- Reference-count the mount: unmount when the *last* session holding it ends.
- Unmount only what the ending session itself mounted.
- Have `SessionEnd` warn and leave the mount, letting `doctor` report the
  orphan (it already reports a mount that outlived its session).

---

## Symlinked rules are placed, reported as mounted, and never read

**Type:** bug · **Severity:** the feature does not work · **Found:** 2026-09-05,
measured against Claude Code 2.1.261. **Fixed** in the same session — `mount`
now copies. Filing it anyway, because the failure mode is worth recording and
anyone on an older deck still has it.

Claude Code does load `.claude/rules/*.md`, including a rule scoped by `paths:`
frontmatter, which it injects when the session touches a matching file. It does
**not** follow a symlink placed there.

deck's `rule` strategy symlinked into `<repo>/.claude/rules/`. So every rule a
pack carried was placed, counted in the manifest, shown by `deck mounts`, and
never reached the agent. Nothing reported a problem: the mount succeeds, the
file is there, and `ls -l` shows a link pointing at real content.

**The measurement**

Five rules in one directory, same repository, same session:

| file | kind | `paths:` | loaded |
|---|---|---|---|
| deck-unscoped.md | copy | *(none)* | yes, at session start |
| deck-two-orders.md | copy | `["**/*.py"]` | yes, after reading a .py |
| deck-rule-one.md | copy | `["src/app.py"]` | yes, after reading it |
| deck-rule-two.md | symlink | `["src/app.py"]` | no |
| deck-rule-three.md | symlink | `["src/app.py"]` | no |
| deck-rule-four.md | symlink | `["src/app.py"]` | no |

Rows 3 and 4 carry identical frontmatter in the same directory and disagree.
The only variable left is symlink versus regular file.

**Three earlier readings of this were wrong, and all three had the same cause:**
asking a session what it had loaded without controlling when the file was
touched. A `paths:`-scoped rule loads on the turn boundary after a matching file
is read, so "read the file and answer" in one turn measures nothing.

## A mounted copy can go stale, and nothing says so

Follows from the fix above, not yet addressed. With symlinks, editing a pack's
rule changed every mount of it at once. With copies, the mounted text is frozen
at mount time: edit the pack and the repositories keep the old rule silently.
`unmount` already stores `source_hash`, so `doctor` could compare and report a
mount whose pack has moved on.
