# #62 — propose pack reads one repository while the workspace knows the graph, so it asks what the neighbour answers

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`deck propose pack <repo>` drafts a pack by reading one repository. Its prompt opens with "You are drafting a deck pack for one repository, by reading it" and carries exactly one `Path:`. The drafting agent runs with `cwd` set to that repository and no other directory allowed, so a read outside it is refused — one draft recorded it plainly:

> my Glob calls outside the repo root were denied, so I could not verify any backend semantics I reasoned about

The descriptor, meanwhile, holds the whole registry and the edges between them. `impacts:` and `couples:` say exactly which other repositories a change here reaches. That information sits one line from the prompt and is not used.

## What it costs

Run over a workspace of eight repositories, the drafts filed 27 questions. Roughly a third of them name an artifact as absent that is present in a sibling repository the graph already points at:

| what a draft said it could not find | where it was |
|---|---|
| the build recipe deciding which files are compiled in | the metadata layer repository |
| the module that rewrites the auth configuration | the application repository |
| the method whose merge semantics a claim depended on | the same application repository |
| the image recipe setting an account's initial credential | the metadata layer repository |

Three of those were answered by hand in minutes, by opening the sibling. One of them turned a question into a **confirmed defect** — the method replaces where the caller assumed it merged.

## Why this is worse than a missing feature

Every one of those questions is a **paid call producing a question a cheaper call could have answered**. The draft costs real money, and the question it files then costs a person's attention, and the answer was three directories away the whole time.

It also misreports what it does not know. A draft says "I could not verify X because it lives in another repository" — true of that repository, false of the workspace, and a reader who trusts the sentence stops looking.

The asymmetry is the point: deck's whole claim is that it supplies what an agent runtime cannot know — *your* workspace, and how a change propagates through it. Here deck holds exactly that and hands the agent a single directory.

## Shape

Two halves, and both are small:

- **Name the neighbours in the prompt.** For the repository under study, the ones it `impacts:`, the ones that impact it, and the ones it `couples:` with — each with its path and why it is a neighbour. Not the whole registry: the graph is what makes this cheap, and a drafter told about eight unrelated repositories will read eight.
- **Let it read them.** The agent runs `cwd`-restricted; the neighbour paths have to be added to what it may open.

One boundary has to be explicit in the prompt, or this changes what the command is: **the pack is still for one repository.** A neighbour is context for answering a question about this repository, never a subject to draft gates or rules for. Without that sentence the drafter starts proposing a rule for the neighbour, and the proposal lands in the wrong pack.

Worth deciding at the same time whether reading neighbours should be opt-out. It costs more tokens per run, and a workspace where the graph is dense would read a lot.

## Acceptance
- [ ] a draft for a repository is told which repositories the graph connects it to, and where they are
- [ ] it can read them, and a question it files says so when it did
- [ ] the pack it drafts is still for one repository — no gate, rule or toggle proposed for a neighbour
- [ ] a repository with no edges drafts exactly as it does now
