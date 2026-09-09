# #25 — The suite cannot run twice on one machine: the tracker stub binds a fixed port

**closed** · bug · opened 2026-09-06 · closed 2026-09-06

---

**As** anyone running the suite while it is already running — in another worktree, in a second terminal, or in two CI jobs on one runner
**so that** a red result means a change broke something.

Repository: `deck`

The tracker stand-in binds a fixed port:

```python
s = HTTPServer(("127.0.0.1", 8731), H)
```

launched as `python3 "$WS/fake.py" &` so the `OSError` goes to a background process nobody reads, followed by `sleep 1`. With the port already held, the bind raises `[Errno 98] Address already in use`, the launch looks fine, and every tracker check then runs against a dead port.

Measured with four copies of the suite running at once on one machine: `show says the two were reconciled`, `the tracker supplies the live url` and both `--net` checks failed with `<urlopen error [Errno 111] Connection refused>` on some runs and passed on others — identical code, between zero and five failures across runs.

Two load-sensitive assumptions in the same twenty lines. The stub also carries `time.sleep(90)`, hard-coded to "outlive the whole section": a wall-clock guess about how long the rest of the suite takes.

An ephemeral port the stub reports back, plus a readiness poll instead of `sleep 1`, settles both — the stub can print the port it got and the suite can read it, which also removes the `sleep`.

Worth deciding in the same change whether a background process failing to start should be able to look like success anywhere in this suite. That is the general shape: the `&` is what turned a clear `OSError` into four confusing reds.

Related: #23, the other load-sensitive check. Together they are why a suite that is otherwise a claim about behaviour sometimes answers a question about the machine.

### Acceptance
- [ ] two copies of the suite on one machine both pass
- [ ] a stub that fails to start fails the suite, naming why, rather than producing connection-refused further down
- [ ] no wall-clock guess about how long another part of the suite takes

---

**Comment** · 2026-09-06

Verified under the deck ladder: 5 gates passed, evidence in .deck/gates/#25.json, and `deck bundle --task #25` reports READY.
