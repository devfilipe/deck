# #33 — A proposal runs for two minutes with nothing to watch

**open** · feature · opened 2026-09-06

---

**As** somebody who has just spent money on a proposal
**so that** the wait is legible and the cost is attributable to something.

Repository: `deck`

`assist.py` runs one headless turn with `--output-format json` and captures the whole reply, so nothing appears until it is over. All three commands that ask for a proposal go through it, so this is not one command's problem:

| | measured on a real product workspace |
|---|---|
| `propose impacts`, six repositories | exceeded the default cap of $1.50 before answering |
| `propose impacts`, four | $1.3685, 129s |
| `propose impacts`, three | $1.3167, 216s |
| `propose pack`, one repository | $1.14–$1.25, 158–164s |

A single line of output at the start, and everything else at the end. The longest of those is three and a half minutes.

The CLI it calls offers `--output-format stream-json`. Reading that and printing what the model is doing — which files it opened, what it searched for — would change nothing about what deck does and would stop it hiding.

The value is not only the waiting. A proposal over six repositories exceeded the default cap; over four it cost $1.37. Neither run says **where** the money went, so narrowing the scope is guesswork: a reader cannot tell whether it was one 3000-line file read three times or a walk through a directory that was not worth reading at all. That is the difference between "run it again with fewer repositories" and "run it again without that one".

Three things to settle, because a stream is easy to do badly:

- **What is worth printing.** Every tool call is noise; nothing is what we have. File reads and searches are probably the line, and the answer should be legible to somebody who is not going to read a transcript.
- **What happens to the JSON result.** The structured reply is requested through `--json-schema` precisely so a malformed answer is the runtime's problem rather than something deck parses defensively. Streaming must not put deck back in the business of parsing prose.
- **Whether it is the default or a flag.** A quiet default with `--watch` is defensible; so is the reverse. What is not defensible is deck printing a stream it does not itself understand.

Two things this is **not**, and both were asked about together:

- **Removing the cap.** `assist.py` describes itself as capped so a runaway loop cannot bill you, and the project promises exactly one place that calls a model, read-only and capped. `--budget` already lets a caller raise it deliberately for a run they know is large. See #32 for making the cap honest about what it governs.
- **An interactive session.** Conducting the model mid-proposal is the line deck does not cross — it emits a plan and never runs one, supplies a question and never draws the box. `--show-prompt` already gives anyone the exact prompt to carry into a session of their own.

### Acceptance
- [ ] a proposal shows what it is doing while it does it
- [ ] the structured result still comes from the schema, never from parsing what was printed
- [ ] what the run spent is attributable to something more specific than the run
