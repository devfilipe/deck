---
name: closing
description: >
  Give back to the pack what this task taught, before the working copy goes
  away. Use when finishing a task, before `deck unmount`, and whenever a
  session is about to end with work in it.
when_to_use: >
  "I'm done", "finish up", "wrap this up", "unmount", "close the task", "that
  took three tries to work out".
user-invocable: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Closing a task

A mounted pack is a **copy**. When the task ends the copy goes away, and
anything learned that lives only in the copy — or only in this conversation —
goes with it. The next person re-learns it.

Two of those losses have a command. The third does not, and is the one worth
your attention.

## 1. What you edited

```bash
deck save --dry-run       # what changed against the pack it came from
deck save
```

`save` compares each placed file against its **source**. `unmount` asks a
different question — against the hash recorded at mount time — which is why an
edited file is left alone rather than deleted. Running `unmount` without `save`
does not destroy the edit, but it does leave it in a working directory nobody
will read again.

## 2. What you asked

```bash
deck ask list                                  # what is open
deck ask fold <id> --as rule   --into <pack> --paths "src/**"
deck ask fold <id> --as toggle --into <pack>
deck ask fold <id> --as gate   --into <pack> --command "..."
```

A consultation that was answered during the work is a decision the team now
holds. Folded into a pack it is versioned and reviewed; left in `ask` it is a
note on one machine.

## 3. What you learned, that is in no file

This is the part no command can find for you, and the reason this skill exists.
Ask it plainly, and answer it honestly — often the answer is *nothing*, and
saying so is fine.

> **Did anything take more than one attempt for a reason the next person will
> hit too?**

If yes, it has a home, and picking the right one is most of the work:

| What it is | Where it goes | The test |
|---|---|---|
| something that must stay true | a rule in the pack's `rules/`, scoped by `paths:` | a reader can disagree with it |
| a decision with more than one defensible answer | a toggle | you would ask a colleague, not look it up |
| several steps in an order that matters | a skill | reordering them breaks something |
| something a command can check | a **gate** — never a rule | a machine settles it in milliseconds |

**If a machine can check it, it is a gate.** Telling an agent about formatting
is paying tokens forever for what a formatter settles instantly.

**Write it where it applies, not where you are.** A convention true of one
repository goes in `_repos/<that repository>`. One true of the workspace goes in
`_workspaces/<name>/default`. One true only while this initiative runs goes in
`_workspaces/<name>/<scope>`. Where the pack sits *is* the declaration.

## What not to write down

- **What the code already says.** "This directory holds handlers" is visible.
- **What a gate already enforces.** A rule restating a check costs context on
  every matching file read, forever, and the gate was free.
- **A procedure you did not follow.** A rule that is wrong gets argued with; a
  procedure that is wrong gets executed.
- **A one-off.** If it will not happen again, it is a commit message.

## Then

```bash
deck unmount --task <id>
```

And the pack is a repository: `git diff` in the collection is the review, and
what you added is now the team's, not yours.
