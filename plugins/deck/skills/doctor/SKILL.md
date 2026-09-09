---
name: doctor
description: >
  Diagnose the workspace: resolved root, descriptor, extension packs, tool
  prerequisites, repositories and their remotes, impact graph, backlog sources,
  deployment targets and the toggle catalog. Use when someone has just installed
  deck, when a command failed over a path or a host, or when the operator asks
  whether everything is configured.
argument-hint: "[--net] [--init]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/deck *)
---

# Doctor

The first command for someone arriving, and the first command when something
fails for environmental reasons. It fixes nothing on its own: it diagnoses and
says exactly what to do.

```bash
deck doctor          # fast, touches no network
deck doctor --net    # also tests target reachability over SSH
deck init            # creates .deck/{workspace.yaml,toggles.yaml}
```

`init` copies the templates the core and the packs provide and **does not
overwrite** what already exists (only with `--force`). After creating, say that
the descriptor needs human review in three places: repository paths, the
`impacts` edges, and above all the `targets` list, which is the allowlist the
guard enforces.

## How to report

Repeat the command's own sections. For each problem, give the concrete fix, not
the symptom:

| Symptom | What to say |
|---|---|
| root not resolved | the four sources, in order, with the `export` ready to paste |
| descriptor missing | `deck init`, and that it needs review afterwards |
| repository path missing | the tree is laid out differently — adjust `path` |
| origin does not match `remote_id` | it may be a different clone; confirm before touching it |
| `impacts` pointing outside | the name is wrong, or a repository is undeclared |
| cycle in the graph | name the repositories involved; ordering stays partial until fixed |
| target unreachable | ssh config, VPN, or the machine is off — do not try another host |
| no extension pack | the core alone knows no build, deploy or lint command |

## Rules

1. **Never invent a fix that involves credentials.** If SSH fails, the answer is
   the operator's `~/.ssh/config`. You write no key and no password anywhere.
2. **Do not edit the descriptor during a diagnosis.** Propose the exact change
   and let the operator apply it, or ask for explicit permission.
3. **A warning is not a problem.** A missing downstream repository or an offline
   target do not stop work up to the build gate — say what is still possible
   instead of only listing what is missing.
4. **Targets are only probed with `--net`.** Do not run the reachability test
   unless asked or unless the problem is clearly a network one.
