note "a ladder with no rungs"
# `deck gate run` used to print "0 gate(s) passed" and exit 0 when no pack
# resolved, which is a green run that verified nothing — and the reason CI
# cannot be a single call to it. A configuration fault is now reported as one.
EL="$(mktemp -d)"; ELP="$(mktemp -d)"
mkdir -p "$EL/.deck"
cat > "$EL/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  one: { path: ., role: engine }
targets: []
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$EL/.deck/toggles.yaml"
empty="$(env DECK_ROOT="$EL" DECK_PACKS_ROOT="$ELP" "$DECK" gate run --task EL1 2>&1 || true)"
if printf '%s' "$empty" | grep -q "no gate is declared"; then
  ok "a run that found no gate says so"
else bad "a run that found no gate says so" "$empty"; fi
if printf '%s' "$empty" | grep -q "deck packs"; then
  ok "and names the command that shows why"
else bad "and names the command that shows why" "$empty"; fi
check_fail "and does not report it as a pass" env DECK_ROOT="$EL" DECK_PACKS_ROOT="$ELP" "$DECK" gate run --task EL2
rm -rf "$EL" "$ELP"

note "secret scanning is a gate, not a hook"
# `secret_scan`'s `impact` used to read "A pre-tool hook refuses to write
# private keys, credentials or certificate material." No hook does that:
# hooks.json — the manifest Claude Code actually loads — wires only
# SessionStart and SessionEnd, and nothing in the plugin inspects a write
# before it happens. What is real is a gate command an org pack can declare,
# reading `${toggle.secret_scan}`, the same way any other gate reads a toggle.
SS="$(mktemp -d)"
mkdir -p "$SS/.deck"
cat > "$SS/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  one: { path: ., role: engine }
targets: []
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$SS/.deck/toggles.yaml"
ssdeck() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SS" "$DECK" "$@"; }
ss_out="$(ssdeck toggle explain secret_scan 2>&1 || true)"
# The PROMISE, not the phrase. The rationale that denies the hook has to name
# it to deny it — "There is no pre-tool hook and nothing inspects a write as it
# happens" — so a check that greps for the words fails on the very sentence
# that fixes the defect. What must not be there is the claim that something
# refuses a write.
if printf '%s' "$ss_out" | grep -qi "refuses to write\|refused before the command is built"; then
  bad "secret_scan: the catalog no longer claims an enforcement deck does not have" "$ss_out"
else
  ok "secret_scan: the catalog no longer claims an enforcement deck does not have"
fi
check "and hooks.json wires no PreToolUse to back the old claim" \
  "['SessionEnd', 'SessionStart']" \
  python3 -c "import json; print(sorted(json.load(open('$REPO/plugins/deck/hooks/hooks.json'))['hooks'].keys()))"
rm -rf "$SS"

note "push_policy records a destination; it does not push"
# The catalog `impact` used to read "Pushed as a draft or work in progress" and
# "Pushed and ready for review", as if deck did it. There is no `deck deliver`
# and no `deck push`, and nothing in `deck bundle` shells out to git push.
# Prove both halves: the wording, and a real run — recording the value, then
# asking for the merge-readiness bundle — through a stand-in git that logs
# every call it sees before running the real one, against a repo one commit
# ahead of its remote so a push, if one happened, would have something to do.
PW="$(mktemp -d)"; PWBIN="$(mktemp -d)"; PWBARE="$(mktemp -d)/bare.git"
mkdir -p "$PW/.deck" "$PW/one"
git init -q --bare "$PWBARE"
git -C "$PW/one" init -q -b main
git -C "$PW/one" config user.email smoke@example.com
git -C "$PW/one" config user.name smoke
git -C "$PW/one" commit -q --allow-empty -m "chore: seed"
git -C "$PW/one" remote add origin "$PWBARE"
git -C "$PW/one" push -q -u origin main
git -C "$PW/one" commit -q --allow-empty -m "feat: PP1 not pushed by deck"
cat > "$PW/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  one: { path: one, role: engine }
targets: []
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$PW/.deck/toggles.yaml"
REALGIT="$(command -v git)"
cat > "$PWBIN/git" <<GITSH
#!/usr/bin/env bash
echo "\$*" >> "$PW/git-calls.log"
exec "$REALGIT" "\$@"
GITSH
chmod +x "$PWBIN/git"
pwdeck() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PW" "$DECK" "$@"; }
pp_out="$(pwdeck toggle explain push_policy 2>&1 || true)"
if printf '%s' "$pp_out" | grep -q "Pushed"; then
  bad "push_policy: the catalog no longer claims deck pushes the commit" "$pp_out"
else
  ok "push_policy: the catalog no longer claims deck pushes the commit"
fi
pwdeck toggle set push_policy review --at workspace --why "smoke fixture" >/dev/null 2>&1 || true
ahead_before="$(git -C "$PW/one" rev-list --count origin/main..HEAD)"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PW" PATH="$PWBIN:$PATH" "$DECK" bundle --task PP1 >/dev/null 2>&1 || true
ahead_after="$(git -C "$PW/one" rev-list --count origin/main..HEAD)"
pushed_calls="$(grep -c "push" "$PW/git-calls.log" 2>/dev/null || true)"
if [ "${pushed_calls:-0}" = "0" ] && [ "$ahead_before" = "$ahead_after" ]; then
  ok "and a real run recording push_policy=review never calls git push"
else
  bad "and a real run recording push_policy=review never calls git push" \
    "push invocations: ${pushed_calls:-0}; commits ahead of origin/main: $ahead_before before, $ahead_after after"
fi
rm -rf "$PW" "$PWBIN" "$(dirname "$PWBARE")"
