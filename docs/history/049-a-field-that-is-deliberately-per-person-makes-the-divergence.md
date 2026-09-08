# #49 — A field that is deliberately per-person makes the divergence report cry wolf forever

**closed** · bug · opened 2026-09-07 · closed 2026-09-07

---

**As** a team sharing an initiative whose board each member authenticates to separately
**so that** a warning that can never be cleared does not teach everybody to ignore the report it lives in.

Repository: `deck`

A scope can carry its own `backlog:`, and it travels into the pack template, which is what makes an initiative shareable. But a tracker source holds two kinds of field:

- **the initiative's**, and the same for everybody — `type`, `url`, `project`, `jql`
- **the person's** — `user`, the account the credentials belong to

The second must not travel: each member authenticates as themselves, and a shared file naming one of them is both wrong and a small disclosure. So the sensible thing is to keep `user:` out of the pack and set it locally.

Doing exactly that makes `doctor` report a divergence that is true and useless:

```
!! scope `payments` reads a different board from the one the `<pack>` pack ships —
   same repositories, different tasks; deck is using this workspace's `backlog:`.
```

Nothing is wrong. The comparison is byte-for-byte over the whole source, so one field that is *supposed* to differ makes the scope look divergent for ever. Measured on a real workspace within minutes of the field being removed from the template for exactly the right reason.

A warning nobody can clear is a warning nobody reads, and this repository has argued that before — a wall-clock check that failed on a loaded machine was replaced rather than tolerated, on the grounds that a check which cannot go green trains people to skip the output.

Note the wording is also wrong in a way that matters: *"different tasks"* is a claim about what the two sources return, and deck did not fetch either to find out. It compared configuration and described results.

Three ways, and the first two are not exclusive:

- **Compare only the fields that identify the board.** `type`, `url`, `project`/`repo`, `jql` say which board; `user` and any future credential-shaped key say who is asking. deck already knows this distinction — `resolve_token` exists precisely because credentials are resolved at call time and never read from the descriptor.
- **Keep `user` out of a scope's `backlog:` altogether**, and let it come from `$DECK_USER_<KIND>` or `whoami`-style resolution only. Cleaner, and it removes the chance of somebody committing their own address into a shared file.
- **Say what actually differs.** Whatever is compared, naming the field beats naming a consequence deck did not measure.

### Acceptance
- [ ] a scope whose board differs only by who is asking is not reported as divergent
- [ ] a scope genuinely pointing at a different board still is
- [ ] the message names the field that differs, and does not describe results deck never fetched
