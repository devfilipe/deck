note "gate ladder"
cat > "$PACK/config/gates.yaml" <<'YAML'
gates:
  - { id: lint,   title: Lint,   from_level: static, per_repo: "echo linting ${repo.name}" }
  - { id: build,  title: Build,  from_level: build,  per_repo: "echo building ${repo.build_target}" }
  - { id: broken, title: Broken, from_level: static, per_repo: "echo ${repo.nonexistent_field}" }
  - { id: absent, title: Absent, from_level: static, per_repo: "${repo.lint}" }
  - { id: fails,  title: Fails,  from_level: build,  per_repo: "exit 3" }
  - { id: gated,  title: Gated,  from_level: static, when: { deploy_mode: [full] }, once: "echo never" }
  - { id: shipit, title: Ship,   from_level: deploy, once: "echo deploying to ${target.host}" }
  - { id: keepup, title: Keep up, from_level: static, per_repo: "echo checking ${repo.name}", include_downstream: true }
YAML

check "the ladder is listed"        "static"    "$DECK" gate list --repos a

# `downstream` means "produces no artifact", not "is never checked": a repo that
# has to keep up carries an obligation, and nothing was enforcing it.
out="$("$DECK" gate list --repos a c 2>&1)"
if printf '%s' "$out" | grep -A1 "keepup" | grep -q "c"; then ok "a gate may opt into a downstream repository"; else bad "a gate may opt into a downstream repository" "$out"; fi
if printf '%s' "$out" | grep -A1 "^  ->   lint" | grep -qv " c"; then ok "and one that does not still skips it"; else bad "and one that does not still skips it" "$out"; fi
check "a higher rung is skipped"    "starts at" "$DECK" gate list --repos a --level static
check "an unmet condition is explained" "gate needs" "$DECK" gate list --repos a
check "dry run resolves commands"   "echo linting a" "$DECK" gate run --repos a --level static --only lint --dry-run
if [ ! -d "$WS/.deck/gates" ]; then ok "dry run records nothing"; else bad "dry run records nothing"; fi

check "a gate passes"                "1 gate(s) passed"  "$DECK" gate run --task G1 --repos a --level static --only lint
check "evidence is written"         "G1"        "$DECK" gate report --task G1
if [ -f "$WS/.deck/gates/logs/G1/lint-a.log" ]; then ok "output is kept on disk"; else bad "output is kept on disk"; fi

blocked="$("$DECK" gate run --task G2 --repos a --level static --only broken 2>&1 || true)"
if printf '%s' "$blocked" | grep -q "unresolved"; then
  ok "an unresolved variable blocks the command"
else
  bad "an unresolved variable blocks the command" "$blocked"
fi
if printf '%s' "$blocked" | grep -q "could not run"; then
  ok "blocked is not reported as passed"
else
  bad "blocked is not reported as passed"
fi

absent="$("$DECK" gate run --task G7 --repos a --level static --only absent 2>&1 || true)"
if printf '%s' "$absent" | grep -q "not declared for this repository"; then
  ok "a gate whose whole command is missing does not apply, rather than blocking"
else
  bad "a gate whose whole command is missing does not apply" "$absent"
fi

failing="$("$DECK" gate run --task G3 --repos a --level build 2>&1 || true)"
if printf '%s' "$failing" | grep -q "an earlier gate failed"; then
  ok "a failure stops the ladder"
else
  bad "a failure stops the ladder"
fi
if "$DECK" gate run --task G4 --repos a --level build >/dev/null 2>&1; then
  bad "a failing run exits non-zero"
else
  ok "a failing run exits non-zero"
fi
keep="$("$DECK" gate run --task G5 --repos a --level build --keep-going 2>&1 || true)"
if [ "$(printf '%s' "$keep" | grep -c 'ok  ')" -ge 2 ]; then
  ok "--keep-going carries on past a failure"
else
  bad "--keep-going carries on past a failure"
fi

# a gate naming a host may only ever name one from the allowlist
"$DECK" toggle set target 10.0.0.99 --at task >/dev/null 2>&1 || true
denied="$("$DECK" gate run --task G6 --repos a --level deploy 2>&1 || true)"
if printf '%s' "$denied" | grep -q "not in the allowlist"; then
  ok "a target outside the allowlist is refused"
else
  bad "a target outside the allowlist is refused" "$denied"
fi
"$DECK" toggle set target 10.0.0.4 --at task >/dev/null

# `${deck.root}` always resolves — the workspace root always exists — so a
# `once:` command built from it plus a path a pack author appended (a script
# under the pack's own directory) can still name a file that is not there. That
# is exactly the manifest layout: the root is the parent of several
# repositories, one of them named after the tool, and the pack's own script
# lives one level below where `${deck.root}` points. Nothing used to say so
# before the subprocess itself failed — not `--dry-run`, which showed the same
# command either way.
note "a gate command that resolves to a script that is not there"
GR="$(mktemp -d)/ws"
mkdir -p "$GR/deck/pk/_workspaces/all/default/config" "$GR/deck/pk/_workspaces/all/default/bin" "$GR/.deck"
cat > "$GR/deck/pk/_workspaces/all/default/config/gates.yaml" <<'YAML'
gates:
  - id: commit-shape
    title: Commit shape
    from_level: static
    once: "python3 ${deck.root}/pk/_workspaces/all/default/bin/commit-shape.py"
YAML
echo "print('ran')" > "$GR/deck/pk/_workspaces/all/default/bin/commit-shape.py"
printf 'version: 1\npacks_root:\n  - deck/pk\nrepos:\n  deck:\n    path: deck\n    impacts: []\n' \
  > "$GR/.deck/workspace.yaml"
printf 'version: 1\n' > "$GR/.deck/toggles.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GR" "$DECK" gate run --task manifest --dry-run 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a manifest layout where the root is not the pack's own repository is caught, not shown as clean"
else
  bad "a manifest layout where the root is not the pack's own repository is caught, not shown as clean" "$out"
fi

# The same pack, the same template, with the root actually at the repository
# the script lives under — the layout the ladder was written for. Nothing
# about the check above should refuse this one; if it did, the check would be
# defending nothing.
rm -rf "$GR"
GR2="$(mktemp -d)/ws"
mkdir -p "$GR2/pk/_workspaces/all/default/config" "$GR2/pk/_workspaces/all/default/bin" "$GR2/.deck"
cat > "$GR2/pk/_workspaces/all/default/config/gates.yaml" <<'YAML'
gates:
  - id: commit-shape
    title: Commit shape
    from_level: static
    once: "python3 ${deck.root}/pk/_workspaces/all/default/bin/commit-shape.py"
YAML
echo "print('ran')" > "$GR2/pk/_workspaces/all/default/bin/commit-shape.py"
printf 'version: 1\npacks_root:\n  - pk\nrepos:\n  self:\n    path: .\n    impacts: []\n' \
  > "$GR2/.deck/workspace.yaml"
printf 'version: 1\n' > "$GR2/.deck/toggles.yaml"
check "and the layout the ladder was written for is untouched" "commit-shape.py" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GR2" "$DECK" gate run --task manifest --dry-run
rm -rf "$GR2"

# The check above reads the token after the interpreter as the script. That is
# wrong for the most ordinary Python invocation there is, and the exercises
# found it: `python3 -m pytest` named `-m` as its script, so every gate written
# that way was reported as `resolved to a script that does not exist: -m` and
# blocked before it ran. A gate refused for a path it never had is worse than
# the hole the check was closing.
GR3="$(mktemp -d)/ws"
mkdir -p "$GR3/pk/_workspaces/all/default/config" "$GR3/.deck"
cat > "$GR3/pk/_workspaces/all/default/config/gates.yaml" <<'YAML'
gates:
  - id: by-module
    title: a module, not a file
    from_level: static
    once: "python3 -m this"
  - id: by-code
    title: code on the command line
    from_level: static
    once: "python3 -c 'print(1)'"
  - id: by-option-then-script
    title: an option of the interpreter, then the script
    from_level: static
    once: "python3 -u ${deck.root}/pk/run.py"
YAML
echo "print('ran')" > "$GR3/pk/run.py"
printf 'version: 1\npacks_root:\n  - pk\nrepos:\n  self:\n    path: .\n    impacts: []\n' \
  > "$GR3/.deck/workspace.yaml"
printf 'version: 1\n' > "$GR3/.deck/toggles.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GR3" "$DECK" gate run --task flags --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "an interpreter's own flags are not read as the script it was handed"
else
  bad "an interpreter's own flags are not read as the script it was handed" "$out"
fi
if printf '%s' "$out" | grep -qF "does not exist: -"; then
  bad "and no gate is blocked for a path it never named" "$out"
else
  ok "and no gate is blocked for a path it never named"
fi
# The hole stays closed: an option in front of it does not excuse a script that
# is genuinely absent.
rm -f "$GR3/pk/run.py"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GR3" "$DECK" gate run --task flags2 --dry-run 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "and a real script missing behind an option is still caught"
else
  bad "and a real script missing behind an option is still caught" "$out"
fi
rm -rf "$GR3"

# ----------------------------------------------------- measurements over time
# A gate answers "did it pass" against a threshold. These check the other half:
# the number behind the pass, and which way it has been going.
