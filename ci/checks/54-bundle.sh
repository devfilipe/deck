note "merge-readiness bundle"

out="$("$DECK" bundle --task T-1 2>&1 || true)"
if printf '%s' "$out" | grep -q "NOT READY"; then ok "an unverified task is not merge-ready"; else bad "an unverified task is not merge-ready" "$out"; fi
if printf '%s' "$out" | grep -q "nothing has been verified under this name"; then ok "and the missing evidence is named, with the command"; else bad "and the missing evidence is named" "$out"; fi
if printf '%s' "$out" | grep -q "unknown — not empty"; then ok "an unattributable change set is unknown, never empty"; else bad "an unattributable change set is unknown, never empty" "$out"; fi
check_fail "a bundle that is not ready exits non-zero" "$DECK" bundle --task T-1

"$DECK" gate run --task T-1 --repos a --level static --only lint >/dev/null 2>&1
out="$("$DECK" bundle --task T-1 2>&1 || true)"
if printf '%s' "$out" | grep -q "1 gate(s) passed"; then ok "the gate record is read back into the bundle"; else bad "the gate record is read back into the bundle" "$out"; fi
if printf '%s' "$out" | grep -q "did not run"; then ok "and the rungs the ladder never reached are stated"; else bad "and the rungs the ladder never reached are stated" "$out"; fi
# Every rung this run climbed to had a gate and passed it, so the level it was
# set to is the level it reached. The three checks below hold both halves at
# once: this one, and the empty rung that must not read the same way.
if printf '%s' "$out" | grep -q 'the ladder reached `static`'; then ok "a rung with gates that all passed is still reported as reached"; else bad "a rung with gates that all passed is still reported as reached" "$out"; fi

# A ladder set to `build` with nothing declared at build: the run climbed there
# and verified nothing, which used to read as "the ladder reached build".
"$DECK" gate run --task T-EMPTY --repos a --level build --only lint >/dev/null 2>&1
empty="$("$DECK" bundle --task T-EMPTY 2>&1 || true)"
if printf '%s' "$empty" | grep -q 'skipped rather than verified'; then
  ok "a rung climbed to with no gate is named as skipped, not reached"
else bad "a rung climbed to with no gate is named as skipped, not reached" "$empty"; fi
if printf '%s' "$empty" | grep -q '^  no gate  build, deploy, behavior'; then
  ok "and the bundle says which rungs hold no gate at all"
else bad "and the bundle says which rungs hold no gate at all" "$empty"; fi
empty_json="$("$DECK" bundle --task T-EMPTY --json 2>&1 || true)"
if printf '%s' "$empty_json" | python3 -c 'import json,sys; v=json.load(sys.stdin)["verification"]; sys.exit(0 if v["level"]=="static" and v["skipped_rungs"]==["build"] and v["no_gates"]==["build","deploy","behavior"] else 1)' 2>/dev/null; then
  ok "and the JSON says the same as the text"
else bad "and the JSON says the same as the text" "$(printf '%s' "$empty_json" | head -3)"; fi

# A ladder set to `build` where build *has* a gate and ran none of it. `onlydown`
# is declared for `c` alone, and `c` is downstream, so every repository this run
# carries is filtered out: deck weighed the gate against this change and waved it
# through. That used to read as "the ladder reached build" with no build command
# run — the same overclaim as the empty rung above, one layer in.
note "a rung climbed to whose gates all turned out not to apply"
cp "$PACK/config/gates.yaml" "$WS/gates.waved-backup"
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - { id: onlydown, title: Only downstream, from_level: build, only_repos: [c], per_repo: "echo building ${repo.name}" }
  - { id: climbed,  title: Climbed,         from_level: deploy, once: "echo climbed past a rung nothing applied at" }
YAML
"$DECK" gate run --task T-WAVED --repos a --level build --only lint gated onlydown >/dev/null 2>&1
waved="$("$DECK" bundle --task T-WAVED 2>&1 || true)"
if printf '%s' "$waved" | grep -q '^  level    static '; then
  ok "a rung whose every gate was waved through is not reported as reached"
else bad "a rung whose every gate was waved through is not reported as reached" "$waved"; fi
# Coverage, not failure: the rung is named with the sentence each gate gave for
# not applying. The rung alone reads as something that went wrong.
if printf '%s' "$waved" | grep -q '^  weighed  build .*none applied to this change .*no repository in this change matches it'; then
  ok "and the bundle says why nothing ran there"
else bad "and the bundle says why nothing ran there" "$waved"; fi
waved_json="$("$DECK" bundle --task T-WAVED --json 2>&1 || true)"
# Coverage and not failure is a claim about where the sentence lands. Nothing at
# that rung went wrong — that is the whole finding — so it is a qualifier a
# reviewer reads before merging, and never a blocker holding the merge.
if printf '%s' "$waved_json" | python3 -c 'import json,sys
d = json.load(sys.stdin)["verdict"]
sys.exit(0 if any("considered and not verified" in q for q in d["qualifiers"])
         and not any("build" in b["why"] for b in d["blockers"]) else 1)' 2>/dev/null; then
  ok "and it lands as a qualifier a reviewer reads, never as a blocker"
else bad "and it lands as a qualifier a reviewer reads, never as a blocker" "$(printf '%s' "$waved_json" | head -3)"; fi
# The two facts stay apart. `build` holds a gate, so it is in neither `no_gates`
# nor `skipped_rungs`: a rung nobody declared anything at was never considered,
# and this one was.
if printf '%s' "$waved_json" | python3 -c 'import json,sys
v = json.load(sys.stdin)["verification"]
sys.exit(0 if [e["rung"] for e in v["inapplicable_rungs"]] == ["build"]
         and "build" not in v["no_gates"] and "build" not in v["skipped_rungs"] else 1)' 2>/dev/null; then
  ok "a rung that was weighed is never reported as a rung nothing was declared at"
else bad "a rung that was weighed is never reported as a rung nothing was declared at" "$(printf '%s' "$waved_json" | head -3)"; fi
# The other half, and a regression guard: it passes before this change and
# after. `static` holds `lint`, which ran and passed, and `gated`, which its
# `when` toggle waved through. One gate that actually ran is verification, and
# the inapplicable one beside it neither adds to that nor takes it away — a fix
# that asked every gate on a rung to pass would break exactly here.
"$DECK" gate run --task T-MIXED --repos a --level static --only lint gated >/dev/null 2>&1
mixed_json="$("$DECK" bundle --task T-MIXED --json 2>&1 || true)"
if printf '%s' "$mixed_json" | python3 -c 'import json,sys
v = json.load(sys.stdin)["verification"]
by = {g["id"]: g["status"] for g in v["gates"]}
sys.exit(0 if v["level"] == "static" and by["lint"] == "passed" and by["gated"] == "skipped" else 1)' 2>/dev/null; then
  ok "a rung with one gate that actually passed is still reached, beside a gate that did not apply"
else bad "a rung with one gate that actually passed is still reached, beside a gate that did not apply" "$(printf '%s' "$mixed_json" | head -3)"; fi

# A regression guard, and the rule this change had to leave standing: an
# inapplicable gate must not hold the ladder back. It passed before this change
# and passes after. The run climbs past the waved rung to `deploy` and the gate
# there runs, and the run exits 0 — a fix that made an inapplicable gate owe
# something would stall both.
climb="$("$DECK" gate run --task T-CLIMB --repos a --level deploy --only lint onlydown climbed 2>&1)"
climb_rc=$?
if [ $climb_rc -eq 0 ] && printf '%s' "$climb" | grep -q 'ok   climbed'; then
  ok "a gate that does not apply does not stop the gates above it from running"
else bad "a gate that does not apply does not stop the gates above it from running" "exit $climb_rc: $climb"; fi
cp "$WS/gates.waved-backup" "$PACK/config/gates.yaml"

if printf '%s' "$out" | grep -q "this task's to decide"; then ok "a decision the task owns carries its value and source"; else bad "a decision the task owns carries its value and source" "$out"; fi
if printf '%s' "$out" | grep -q "regional tags"; then ok "the questions the task raised travel with it"; else bad "the questions the task raised travel with it" "$out"; fi

# A commit whose message cites the task attributes itself. Anything else is a
# window, and the two are never printed as the same thing.
echo widened > "$WS/a/schema.txt"
git -C "$WS/a" add -A
git -C "$WS/a" -c user.email=a@b -c user.name=a commit -qm "T-1: widen the schema"
out="$("$DECK" bundle --task T-1 2>&1 || true)"
if printf '%s' "$out" | grep -q "message names T-1"; then ok "a commit citing the task is attributed exactly"; else bad "a commit citing the task is attributed exactly" "$out"; fi
if printf '%s' "$out" | grep -q "reached by this change and have no commit"; then ok "and the chain that was not followed is named"; else bad "and the chain that was not followed is named" "$out"; fi

git -C "$WS/b" -c user.email=a@b -c user.name=a commit -q --allow-empty -m "unrelated work"
out="$("$DECK" bundle --task T-3 --since 2000-01-01 2>&1 || true)"
if printf '%s' "$out" | grep -q "the window, not the task"; then ok "a window is never presented as the task"; else bad "a window is never presented as the task" "$out"; fi

# The catalog already held this decision: `requirement_link: required` means the
# commit message must cite the item, which is exactly what makes attribution
# exact. The bundle reads the toggle rather than inventing a convention.
"$DECK" toggle set --at workspace requirement_link required >/dev/null
out="$("$DECK" bundle --task T-3 --since 2000-01-01 2>&1 || true)"
if printf '%s' "$out" | grep -q 'requirement_link is `required`'; then ok "under requirement_link a window is a blocker, not a note"; else bad "under requirement_link a window is a blocker, not a note" "$out"; fi
"$DECK" toggle set --at workspace requirement_link off >/dev/null

"$DECK" bundle --task T-1 --write >/dev/null 2>&1 || true
if [ -f "$WS/.deck/bundles/T-1.md" ]; then ok "the bundle can be written for a pull request"; else bad "the bundle can be written for a pull request"; fi
if grep -q "^## Where each claim comes from" "$WS/.deck/bundles/T-1.md"; then ok "and every section names where it came from"; else bad "and every section names where it came from"; fi
# Capture it: `2>/dev/null` into a pipe hid the reason, and a check that fails
# without saying why costs more than the defect it found.
bundle_json="$("$DECK" bundle --task T-1 --json 2>&1 || true)"
if printf '%s' "$bundle_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if set(d) >= {"change","verification","decisions","questions","hygiene","sources","verdict"} else 1)' 2>/dev/null; then
  ok "the JSON carries every half a reviewer needs"
else
  bad "the JSON carries every half a reviewer needs" "$(printf '%s' "$bundle_json" | head -3)"
fi

# ---- a delivery under change-based review keeps its name across a patchset
# Its own workspace and its own collection: the point of the section is what a
# bundle says with a trailer convention declared and without one, and the suite's
# shared pack has neither to lend.
note "a delivery's name, when a patchset moves the commit"
CD="$(mktemp -d)"; CDP="$CD/collection/_workspaces/all/default"
mkdir -p "$CD/r" "$CD/.deck" "$CDP/config"
git -C "$CD/r" init -q
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$CD/.deck/toggles.yaml"
cat > "$CD/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  r: { path: r }
targets: []
backlog:
  - { type: tasks, file: .deck/board.yaml }
YAML
cat > "$CD/.deck/board.yaml" <<'YAML'
tasks:
  - { id: CH-1, title: a delivery that will take a second patchset, repos: [r] }
YAML
# The trailer lives in a pack, never in the engine: `Change-Id` is one
# convention of one family of review servers, and a workspace whose packs say
# nothing must go on reporting hashes.
cat > "$CDP/config/toggles.yaml" <<'YAML'
toggles:
  - id: delivery_trailer
    group: delivery
    title: Delivery identity
    summary: The commit-message trailer this review server uses to name a delivery.
    type: enum
    values: ["off", Change-Id]
    default: Change-Id
    stage: [deliver]
    scope: [workspace]
    risk: low
    impact:
      "off": A delivery is named by the commit that carries it.
      Change-Id: A delivery is named by its Change-Id trailer, which survives an amend.
YAML
cat > "$CDP/config/detect.yaml" <<'YAML'
markers: [".deck"]
YAML
echo one > "$CD/r/f.txt"
git -C "$CD/r" add -A
git -C "$CD/r" -c user.email=a@b -c user.name=a commit -qm "CH-1: widen the thing

Change-Id: I0fc2a91b4d5e6f708192a3b4c5d6e7f809a1b2c3"

# The identity and the commit carrying it, read from the payload rather than the
# rendering: these checks are about which name the bundle reports, not about how
# many spaces sit beside it. `bundle` exits non-zero whenever a task is not
# ready to merge, which this one never is, so the output is captured either way.
cd_with()  { env -u DECK_PACKS DECK_PACKS_ROOT="$CD/collection" DECK_ROOT="$CD" \
               "$DECK" bundle --task CH-1 --json 2>/dev/null || true; }
cd_plain() { env -u DECK_PACKS -u DECK_PACKS_ROOT DECK_ROOT="$CD" \
               "$DECK" bundle --task CH-1 --json 2>/dev/null || true; }
cd_field() {   # <json> <python expression over the one delivery in `r`>
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)['change']['repos']['r']['deliveries'][0]
print($2)
" 2>/dev/null || printf 'unreadable'
}

sha0="$(git -C "$CD/r" rev-parse --short HEAD)"
with_before="$(cd_with)"
plain_before="$(cd_plain)"
# The round of review the issue is about: a reviewer asked for something and the
# same change is amended. The edit is what makes the new commit a different
# object — an amend over an identical tree, message, author and second produces
# the very same hash, and the check below would then be proving nothing.
echo two >> "$CD/r/f.txt"
git -C "$CD/r" add -A
git -C "$CD/r" -c user.email=a@b -c user.name=a commit -q --amend --no-edit
sha1="$(git -C "$CD/r" rev-parse --short HEAD)"
with_after="$(cd_with)"
plain_after="$(cd_plain)"

id_before="$(cd_field "$with_before" "d['id']")"
id_after="$(cd_field "$with_after" "d['id']")"
at_before="$(cd_field "$with_before" "','.join(d['commits'])")"
at_after="$(cd_field "$with_after" "','.join(d['commits'])")"

# Against git's own answer, not against the earlier run: what makes the check
# below mean anything is that the amend really did move the commit, and only
# git can say that. The two hashes are asserted to differ for the same reason —
# a repository where the amend changed nothing would let any name look stable.
if [ "$sha0" != "$sha1" ] && [ "$at_before" = "$sha0" ] && [ "$at_after" = "$sha1" ]; then
  ok "a bundle reports the commit a delivery sits on now, and an amend moves it"
else
  bad "a bundle reports the commit a delivery sits on now, and an amend moves it" \
    "git $sha0 -> $sha1, bundle $at_before -> $at_after"
fi
# The defect: the same delivery, named twice, differently, with nothing about
# the work having changed between the two bundles.
if [ "$id_before" = "I0fc2a91b4d5e6f708192a3b4c5d6e7f809a1b2c3" ] && [ "$id_after" = "$id_before" ]; then
  ok "and it is named by the trailer its pack declares, which the amend did not move"
else
  bad "and it is named by the trailer its pack declares, which the amend did not move" \
    "$id_before -> $id_after"
fi
# The other half of the acceptance: nothing declared, nothing assumed. A
# workspace on a branch-and-merge flow is named by the commit exactly as before,
# and the payload says no convention is in force rather than showing an empty one.
plain_id_before="$(cd_field "$plain_before" "d['id']")"
plain_id_after="$(cd_field "$plain_after" "d['id']")"
plain_trailer="$(printf '%s' "$plain_before" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['change']['trailer'])" 2>/dev/null || printf unreadable)"
if [ "$plain_id_before" = "$sha0" ] && [ "$plain_id_after" = "$sha1" ] && [ "$plain_trailer" = None ]; then
  ok "a workspace whose packs declare no trailer is named by the commit, as it always was"
else
  bad "a workspace whose packs declare no trailer is named by the commit, as it always was" \
    "$plain_id_before -> $plain_id_after (trailer=$plain_trailer)"
fi
rm -rf "$CD"

