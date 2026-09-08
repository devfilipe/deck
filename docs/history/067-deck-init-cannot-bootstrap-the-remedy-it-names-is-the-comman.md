# #67 — deck init cannot bootstrap: the remedy it names is the command that just failed

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`deck init` in a directory with no `.deck/` fails, and the way out it prints is itself.

```
$ mkdir /tmp/newthing && cd /tmp/newthing
$ deck init
deck: workspace root not resolved. Use one of these, in order:
  1. export DECK_ROOT=/path/to/your/workspace
  2. create .deck/workspace.yaml at the root (deck init)
  3. run from inside the tree, with a pack that declares detection markers
  4. answer `workspace_root` when installing the plugin
```

Option 2 is what was just run. Options 3 and 4 need a pack or an installed plugin. Only option 1 works:

```
$ DECK_ROOT=$PWD deck init
created /tmp/newthing/.deck/workspace.yaml   (from deck)
created /tmp/newthing/.deck/toggles.yaml   (from deck)
```

## Why this one matters more than its size

It is the **first command anyone runs**. Somebody trying deck for the first time meets an error that tells them to run the command that produced it, and the only working answer is the option they were least likely to pick. `deck setup` has no such problem — it resolves a root itself.

The message is not wrong about resolution in general; it is the standard "how deck finds a root" list, printed by a command whose entire job is to create the thing that would make resolution succeed. `init` is the one caller for which that list is a circle.

## Shape

`init` knows where it is. The obvious answer is that with no root resolved and no argument, it initialises the current directory — that is what the user asked for by running it there — and says which directory it chose, since choosing silently is how somebody ends up with a `.deck/` three levels above where they meant.

Worth deciding at the same time: whether `deck init <path>` should exist, and whether `init` inside a tree that already resolves to a root elsewhere should refuse rather than create a second one. A workspace nested inside a workspace is a real hazard and the current failure accidentally prevents it.

## Acceptance
- [ ] `deck init` in a directory with no root creates one there, and says where
- [ ] it refuses, naming the other root, when run inside a tree that already resolves to one
- [ ] the resolution list is not printed by the command that exists to make resolution succeed
