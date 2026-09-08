---
paths: ["**"]
---

# Writing an issue against deck

An issue is read by someone deciding whether to spend an afternoon on it. It has
to survive being read cold, months later, by a person who was not in the
conversation that produced it.

## Name the defect, not the feeling

The title is a claim that can be true or false. `toggle: a recorded choice can
be written but never withdrawn` is checkable; `toggle UX is confusing` is not,
and nobody can tell when it is fixed.

## Show the thing happening

Paste the command and its real output, not a description of it:

```
$ deck toggle unset gate_level --at some-scope
deck toggle: error: argument toggle_cmd: invalid choice: 'unset'
```

Never a transcript retyped from memory, and never one edited to look tidier than
it was. If the output is long, cut it and say you cut it.

## Argue the asymmetry, not the missing verb

The weakest issue asks for a feature. The strongest one shows that the current
behaviour contradicts something deck already claims about itself. "There is no
`unset`" is a wish; "`set` requires `--why` because recording a choice is a
deliberate act, and withdrawing one is equally deliberate but leaves no trace at
all" is an argument, and it survives the reader disagreeing about the verb.

Say where the shape is genuinely undecided rather than hiding it. An issue that
names its own open question gets answered; one that pretends to be finished gets
implemented wrong.

## Nothing from a workspace that is not yours to publish

deck is developed against real workspaces belonging to employers and clients.
None of that belongs in a public issue: no organisation or product names, no
internal hostnames, project keys, ticket ids or usernames, no file or symbol
names from private code, and no error text still carrying any of those. Locale
counts — an error message in the wrong language identifies an instance as surely
as a hostname does.

Reproduce the defect against a synthetic workspace and paste *that*. It is
usually a better report anyway: a reader can run it.

## One issue, one defect

Two problems in one issue means one of them gets fixed and the issue stays open,
or both get fixed in a change nobody can review. Split them and link.
