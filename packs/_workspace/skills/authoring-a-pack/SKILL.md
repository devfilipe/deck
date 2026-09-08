---
name: authoring-a-pack
description: >
  How to write or extend a pack: which of the four homes a thing belongs in,
  what earns its context, and how to check the pack is still doing something.
  Use when contributing knowledge rather than code.
when_to_use: >
  "add a rule", "write a gate for this", "should this be a toggle", "our
  convention should be enforced", "review our pack".
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Authoring a pack

## Sort before writing

Most existing material is three things at once: a formatter config nobody
extracted, a handful of real invariants, and decisions never written down as
such. Sorting them is most of the work.

| Home | When | Costs |
|---|---|---|
| **gate** | a machine can check it | nothing until it runs |
| **toggle** | more than one defensible answer, re-decided often | one question, once |
| **rule** | a constraint over an area, with a consequence | context on **every** matching file read |
| **skill** | a procedure with steps | its description, in **every** session |

The rule that settles most cases: **if a machine can check it, it is a gate.**
Never spend an agent's context on what `ruff format` fixes in milliseconds.

The second: **if there is one right answer, it is not a toggle.** A decision
nobody would ever change is a rule wearing a decision's clothes, and
`deck pack review` will say so.

## What earns its place in a rule

Write the **consequence**, not the description.

- Earns it: "hello-cli is installed separately and does not negotiate versions;
  a removed field breaks every deployed client silently."
- Does not: "this directory contains the CLI." The agent can see that.

Scope it with `paths:` so it loads when it matters and not otherwise.

## What earns its place in a toggle

Four things, and `deck toggle validate --strict` enforces the wording:

- `rationale` — why the decision exists, and what goes wrong when made badly.
  It is the part that survives the person who wrote it.
- `impact` per value — what choosing it **costs**, not the value's name again.
- `question` — how it should be put to a person, in at most 12 header
  characters and at most four options.
- `applies_to` — so it is only asked when the change makes it relevant.

## Drafting from a repository

```bash
deck propose pack <repo> --yes        # read-only, capped, writes a proposal
deck propose pack <repo> --no-neighbours --yes   # this repository alone
deck propose apply <file> --into <pack dir> --confidence high
```

It reads the repository and proposes gates it found evidence for, rules whose
violation no gate would catch, and toggles the code shows were genuinely chosen.
It proposes nothing when there is nothing — which is a valid answer.

A draft is a starting point. A gate you have not run is a gate you do not have.

## Then check it is still doing something

```bash
deck pack validate <pack>     # is it well formed
deck toggle validate --strict # is the wording answerable
deck pack review              # is it still doing anything
```

`review` is the one that matters over a year: a gate that ran twenty times and
never failed, a rule matching no file, a toggle nobody was ever asked. None is
automatically wrong; each is a place a pack stopped earning its context.

## Look at what exists before writing your own

`deck pack sources` lists sources whose existence was checked. Two worth reading
for shape: `anthropics/skills`, and `obra/superpowers` — whose `writing-skills`
skill is about exactly this. Install a methodology rather than vendoring it; one
you have copied is one that stops receiving its author's corrections.

What you do vendor, re-check: `deck pack update` reads the provenance record
back and says whether the source moved, whether the copy here was edited, or
both. It refuses the both case rather than picking a side.
