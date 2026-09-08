# Security

## Reporting

Do not open a public issue for a security defect. Use GitHub's
[private vulnerability reporting](../../security/advisories/new), or email the
maintainer at the address on the commits.

You should get an acknowledgement within a few days. deck is maintained by one
person; there is no team on call, and saying so is fairer than implying one.

## What deck's surface actually is

deck runs commands your packs declare and places files into repositories you
declare. Its risk is not cryptographic — it is that it acts on a machine with a
developer's permissions, sometimes at an agent's request. The parts that matter:

| Surface | What holds it |
|---|---|
| **Gate commands** | strings from your packs, run in your shell. deck supplies no command of its own |
| **Hosts** | `targets:` is an allowlist. ssh, scp and http to a host not on it are refused before the command is built |
| **Mounting** | recorded in a manifest with hashes; `unmount` removes exactly what it placed and never what it did not |
| **Vendored artifacts** | `deck pack add` never takes `hooks/` unless asked with `--with-hooks`, because a hook is a shell command that runs on your machine |
| **Headless model calls** | off by default, read-only enforced by the runtime, capped by `--max-budget-usd`, and they write a proposal rather than an edit |
| **Tokens** | resolved from a command, the environment or `~/.netrc`, in that order. `deck board whoami` reports which account would act, and never prints the token |

## What deck does not protect you from

- **An agent with shell access.** deck is not a sandbox. What an agent may run is
  Claude Code's permission surface, not deck's.
- **A pack you did not read.** A pack is code that instructs an agent. Vendoring
  one is taking on its content; review it as you would a dependency.
- **A gate command you did not read.** deck runs what your pack declares, exactly.
