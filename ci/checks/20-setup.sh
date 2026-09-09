note "setup, and packs linked by name"
SW="$WS/greenfield"; SP="$WS/aipacks"
mkdir -p "$SW"/group1/{proj1,proj2} "$SW"/group2/proj3
for d in group1/proj1 group1/proj2 group2/proj3; do git -C "$SW/$d" init -q; echo x > "$SW/$d/README.md"; done

held="$("$DECK" setup --root "$SW" 2>&1 || true)"
if printf '%s' "$held" | grep -q "Re-run with --packs-root"; then
  ok "setup stops rather than guessing where knowledge should live"
else
  bad "setup stops rather than guessing" "$held"
fi
if [ ! -e "$SW/.deck" ]; then ok "a stopped setup writes nothing"; else bad "a stopped setup writes nothing"; fi

"$DECK" setup --root "$SW" --packs-root "$SP" --create-packs >/dev/null 2>&1
# Into the collection, under the root directory's name — no --workspace given.
if [ -f "$SP/_workspaces/$(basename "$SW")/default/workspace.yaml" ]; then
  ok "setup writes the descriptor into the collection"
else bad "setup writes the descriptor into the collection" "$(find "$SP" -name workspace.yaml | tr '\n' ' ')"; fi
if [ -f "$SP/_repos/proj1/config/toggles.yaml" ]; then ok "a pack is created per repository"; else bad "a pack is created per repository"; fi

# the convention: a pack directory named after a repository is its pack, one or
# two levels deep, and a shared pack applies to all
rm -rf "$SP/_repos/proj2"; "$DECK" pack new proj2 --dir "$SP/_repos/group1/proj2" >/dev/null
"$DECK" pack new all/default --dir "$SP/_workspaces/all/default" >/dev/null
linked="$(cd "$SW" && "$DECK" setup --root "$SW" --packs-root "$SP" --force 2>&1 || true)"
if printf '%s' "$linked" | grep -q "linked   proj1"; then ok "a top-level pack is linked by name"; else bad "a top-level pack is linked by name"; fi
if printf '%s' "$linked" | grep -q "group1/proj2"; then ok "a nested pack is linked by name"; else bad "a nested pack is linked by name" "$linked"; fi
if printf '%s' "$linked" | grep -q "shared   (every repository)"; then ok "a _workspace pack applies to all"; else bad "a _workspace pack applies to all"; fi

rm -rf "$SP/_repos/proj3-dup"; "$DECK" pack new proj3 --dir "$SP/_repos/group2/proj3" >/dev/null
dup="$(cd "$SW" && "$DECK" setup --root "$SW" --packs-root "$SP" --force 2>&1 || true)"
if printf '%s' "$dup" | grep -qE "two packs claim|linked   proj3"; then
  ok "a duplicate name is resolved or reported, never guessed"
else
  bad "a duplicate name is handled"
fi
# The plan and the run have to name the same directory. They did not: step 2
# announced `_repos/<name>`, step 4 printed the flat path, and step 5 told
# somebody to create a directory the engine no longer reads. Found by a person
# following the tutorial, which is where a stale message is always found.
PW="$(mktemp -d)"; PP="$PW/pk"; mkdir -p "$PW/only"; git -C "$PW/only" init -q 2>/dev/null
printf 'version: 1\nrepos:\n  only: { path: only }\n' > /dev/null
plan="$(cd "$PW" && env -u DECK_PACKS_ROOT -u DECK_PACKS "$DECK" setup --root "$PW" --packs-root "$PP" --dry-run 2>&1 || true)"
if printf '%s' "$plan" | grep -q "_repos/only"; then
  ok "the plan names the directory the run will create"
else bad "the plan names the directory the run will create" "$(printf '%s' "$plan" | grep 'no pack')"; fi
(cd "$PW" && env -u DECK_PACKS_ROOT -u DECK_PACKS "$DECK" setup --root "$PW" --packs-root "$PP" --create-packs >/dev/null 2>&1)
if [ -d "$PP/_repos/only" ]; then
  ok "and the run creates it there"
else bad "and the run creates it there" "$(find "$PP" -maxdepth 2 -type d | tr '\n' ' ')"; fi
rm -rf "$PW"

existing="$(cd "$SW" && "$DECK" setup --root "$SW" --packs-root "$SP" 2>&1 || true)"
if printf '%s' "$existing" | grep -q "already has"; then
  ok "setup refuses to overwrite an existing workspace"
else
  bad "setup refuses to overwrite an existing workspace"
fi

# A scaffolded pack must accept the obvious next move: append your entry at the
# end of the file. `toggles: []` closed the collection, so it did not.
SC="$(mktemp -d)/scaffold"
"$DECK" pack new probe --dir "$SC" >/dev/null 2>&1
printf '  - id: mine\n    group: quality\n    title: Mine\n    summary: A test.\n    type: enum\n    values: [a, b]\n    default: a\n    stage: [plan]\n' >> "$SC/config/toggles.yaml"
if python3 -c "import yaml,sys; d=yaml.safe_load(open('$SC/config/toggles.yaml')); sys.exit(0 if len(d['toggles'])==1 else 1)" 2>/dev/null; then
  ok "an entry appended to a scaffolded catalog parses"
else bad "an entry appended to a scaffolded catalog parses"; fi
printf '  - { id: g, title: G, from_level: static, per_repo: "true" }\n' >> "$SC/config/gates.yaml"
if python3 -c "import yaml,sys; d=yaml.safe_load(open('$SC/config/gates.yaml')); sys.exit(0 if len(d['gates'])==1 else 1)" 2>/dev/null; then
  ok "and one appended to a scaffolded ladder"
else bad "and one appended to a scaffolded ladder"; fi
rm -rf "$SC"

# `validate` asks whether a pack is well formed. `review` asks whether it is
# doing anything, which is the question that decays quietly.
mkdir -p "$PACK/skills/a-procedure"
printf -- '---\nname: a-procedure\ndescription: >\n  When to reach for this, in the words someone would use asking for it.\n---\n\n# A procedure\n' > "$PACK/skills/a-procedure/SKILL.md"
check "review reports what each pack contributes" "rule(s)" "$DECK" pack review
check "and what the always-on surface costs" "in every session" "$DECK" pack review
check "skills are counted" "1 skill(s)" "$DECK" pack review
out="$("$DECK" pack review --json 2>&1)"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("gate_history") else 1)'; then
  ok "gate history comes from the evidence already kept"
else bad "gate history comes from the evidence already kept"; fi
# A rule scoped to a path nothing matches never loads, and nothing else says so.
mkdir -p "$PACK/rules"
printf -- '---\npaths: ["**/*.nosuchextension"]\n---\nA rule that can never load.\n' > "$PACK/rules/orphan.md"
check "a rule that can reach no file is reported" "never loads" "$DECK" pack review
rm -f "$PACK/rules/orphan.md"

# ---- the rule that is a gate in prose
# `review` priced every rule and audited every gate, and never asked deck's own
# first question of a rule: whether a machine is already deciding it. A rule
# saying to run something is paid for on every matching file read and enforced
# by nobody. The engine cannot know what `sortitall` is, and does not need to —
# a pack declared a gate that runs it, as data, and that declaration is the
# whole signal. Judgement is left alone because judgement names directories and
# modules, and nothing in the ladder runs those. Both halves are asserted here
# together: a signal that only fires is worth nothing without the one it skips.
note "a rule the ladder already decides"
R34="$(mktemp -d)"
mkdir -p "$R34/.deck" "$R34/app"
git -C "$R34/app" init -q 2>/dev/null
printf 'x = 1\n' > "$R34/app/main.py"
git -C "$R34/app" add -A >/dev/null 2>&1
git -C "$R34/app" -c user.email=t@example -c user.name=t commit -qm init >/dev/null 2>&1
printf 'version: 1\nrepos: { app: { path: app } }\ntargets: []\n' > "$R34/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$R34/.deck/toggles.yaml"
P34="$R34/ladder"; Q34="$R34/team"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$R34" "$DECK" pack new ladder --dir "$P34" >/dev/null 2>&1
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$R34" "$DECK" pack new team --dir "$Q34" >/dev/null 2>&1
printf 'gates:\n  - { id: tidy34, title: Tidy, from_level: static, per_repo: "sortitall --fix ." }\n' > "$P34/config/gates.yaml"
printf 'gates: []\n' > "$Q34/config/gates.yaml"
mkdir -p "$P34/rules" "$Q34/rules"
printf -- '---\npaths: ["**/*.py"]\n---\n\nAlways run `sortitall` before you commit.\n' > "$P34/rules/typed.md"
printf -- '---\npaths: ["**/*.py"]\n---\n\n`app/` knows no transport, and `main.py` is where that shows.\nWidening it is a judgement call — ask before you do.\n' > "$P34/rules/judged.md"
# The whole command, trailing `.` argument and all: the rule lives in one pack
# and the gate that answers for it in another, which is how a shared ladder and
# a team pack are normally split.
printf -- '---\npaths: ["**/*.py"]\n---\n\nBefore a release, run `sortitall --fix .` over the tree.\n' > "$Q34/rules/borrowed.md"
r34="$(env -u DECK_PACKS_ROOT DECK_ROOT="$R34" DECK_PACKS="$P34:$Q34" "$DECK" pack review --json 2>&1 || true)"
f34() {
  printf '%s' "$r34" | python3 -c '
import json, sys
want, gate = sys.argv[1], sys.argv[2]
found = [f for p in json.load(sys.stdin)["packs"] for f in p["findings"] if want in f and gate in f]
sys.exit(0 if found else 1)' "$1" "$2"
}
if f34 "rules/typed.md" "tidy34" && ! f34 "rules/judged.md" "tidy34"; then
  ok "the rule a gate could decide is named with the gate, and the judgement beside it is not"
else bad "the rule a gate could decide is named with the gate, and the judgement beside it is not" "$r34"; fi
if f34 "rules/borrowed.md" "tidy34"; then
  ok "a gate in one pack answers for a rule in another — gate ids are workspace-wide"
else bad "a gate in one pack answers for a rule in another — gate ids are workspace-wide" "$r34"; fi
rm -rf "$R34"

# ---- consultations: the question the catalog has no entry for
