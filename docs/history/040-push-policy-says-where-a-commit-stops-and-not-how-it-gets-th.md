# #40 — push_policy says where a commit stops and not how it gets there

**open** · feature · opened 2026-09-06

---

**As** a team whose review server is not the one deck happens to assume
**so that** the toggle that decides where work goes can actually send it there.

Repository: `deck`

`push_policy` is a core toggle with three values — `local`, `draft`, `review` — and it models the shape well: commits stay on the machine, go up visible but not asking for a reviewer, or go up ready for one. Nothing anywhere turns a value into a command.

For a plain remote, `review` is roughly `git push`. For a change-based review server it is a different ref entirely, and `draft` is the same ref with a flag:

```
git push origin HEAD:refs/for/main        # ready for review
git push origin HEAD:refs/for/main%wip    # visible, not summoning anyone
```

Neither string exists in deck. So a workspace on such a server answers the question the toggle asks and then does the push by hand, which means the answer changes nothing — and a toggle whose value nothing acts on is worse than no toggle, because it reads as governance that is not there.

The obvious home is a pack: a domain declares the command per value the way it declares a gate's command, and the engine stays free of any one server's ref conventions. That fits the rule the whole project runs on — a domain word in engine code is a bug.

Two things to settle:

- **Whether deck pushes at all.** It currently does not, anywhere, and that is defensible: publishing is outward-facing and irreversible-ish, and `bundle` already reports what is unpushed. A pack could declare the command without deck ever running it, so `deck bundle` can say *"this task is at `review`; the command for that here is …"* and stop. That may be the right amount.
- **What `draft` means where the server has no such notion.** Refusing is better than quietly treating it as `review`.

### Acceptance
- [ ] a pack can declare what each `push_policy` value means for its server, without engine changes
- [ ] a value the local setup cannot express is refused, never silently downgraded
- [ ] whether deck runs the command or only reports it is decided and written down
