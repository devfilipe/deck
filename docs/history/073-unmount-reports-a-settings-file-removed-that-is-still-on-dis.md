# #73 — unmount reports a settings file removed that is still on disk, because mount records only half of what it wrote

**closed** · — · opened 2026-09-07 · closed 2026-09-07

---

`deck mount` writes two things into a repository's `.claude/settings.local.json` and records one. `deck unmount` then takes back what was recorded, reports `10 removed · 0 left alone`, exits 0, and leaves the file behind.

## The path

`plugins/deck/deck/mount.py`:

- `_merge_settings()` writes `enabledPlugins` **and** `extraKnownMarketplaces`, and returns only the plugins it added.
- `apply()` records that as `"plugins": added`. The marketplace entry is written into a product repository and recorded nowhere.
- `remove()` pops `enabledPlugins`, then reaches `if not data: path.unlink()` — the branch commented *"A settings file that holds nothing but what we added goes away"*. `data` is not empty: it still holds the marketplace deck itself wrote. The file survives.
- `_update_exclude(..., add=False)` runs in the same call and drops `.claude/settings.local.json` from `.git/info/exclude`, so the leftover becomes visible to `git status` at the moment deck stops hiding it.

A second variant on the same lines is worse. When `added` is empty — the plugin was already enabled by somebody else — `apply()` does `continue` and records **no entry at all**, but `_merge_settings` has already written the marketplace. That one is never taken back under any circumstances.

## Observed

```
$ deck unmount --task ACME-11
  10 removed · 0 left alone

$ git -C services/api-schema -c core.excludesFile=/dev/null status --porcelain
?? .claude/
$ cat services/api-schema/.claude/settings.local.json
{ "extraKnownMarketplaces": { "acme": { "source": { "source": "url",
  "url": "https://example.com/some-pack.git" } } } }
```

Four repositories, four leftovers, and the mount reported success.

## Why it went unseen

Git's XDG default excludes file — `~/.config/git/ignore` — commonly carries `**/.claude/settings.local.json`, put there by anyone who has run Claude Code. It is the built-in default path, so `git config --get core.excludesfile` returns nothing and `GIT_CONFIG_GLOBAL=/dev/null` does not disable it. On such a machine `git status` is clean and deck's report looks true.

It surfaced on a CI runner with no such file, as a bundle refusing to be READY over uncommitted changes in every repository — deck correctly catching deck. Reproducible anywhere with `XDG_CONFIG_HOME=/nonexistent`.

## Why this one matters beyond the file

deck's promise about mounting is specific and load-bearing: *everything placed is recorded in a manifest and removed on unmount; deck never deletes what it did not place.* The second half is honoured carefully. The first is not: what is not recorded cannot be removed, and reporting it as removed is worse than leaving it, because the operator has been told the repository is clean.

It is the fourth instance of one pattern in this codebase — deck writing something that nothing else knows about. A rule written into a pack that `mount.yaml` never named (#53). Declarations emptied by `--force` without mention (#44). Comments destroyed by a rewrite (#7). Each time the report said the work was done.

## Shape

Record the marketplace alongside the plugins, and pop it on unmount — then the existing `if not data` branch does what its comment says. The `continue` when `added` is empty has to record an entry too when a marketplace was written, or stop writing one.

Worth deciding at the same time whether `remove()` should verify rather than trust: it reports `removed` from the manifest, not from the filesystem. A count that says what is actually gone would have caught this the first time it happened.

## Acceptance
- [ ] after `unmount`, no file deck wrote is left in a repository
- [ ] `unmount` counts what it removed, not what it intended to remove
- [ ] a plugin already enabled by somebody else is still not taken away, and a marketplace deck added alongside it still is
- [ ] a check covers it with the user's excludes file out of the way
