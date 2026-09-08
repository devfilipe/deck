#!/usr/bin/env bash
# Smoke test for deck. Builds a synthetic workspace and an example pack in a
# temporary directory, so it runs anywhere and touches nothing you own.
#
#   ./ci/smoke.sh        run everything
#   ./ci/smoke.sh -v     show each command's output
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECK="$REPO/plugins/deck/bin/deck"
VERBOSE="${1:-}"

pass=0
fail=0
skipped=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
# A check that could not run here still exists. Counting it keeps the total the
# same on every machine, which is what lets the documents state one number —
# and it puts the skip in the summary rather than one yellow line in six
# hundred, where nobody was going to find it.
skip() { printf '  \033[33m..\033[0m   %s\n' "$1"; skipped=$((skipped + 1)); }
note() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <description> <expected substring> <command…>
check() {
  local desc="$1" expect="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [ -n "$VERBOSE" ] && printf '       $ %s\n%s\n' "$*" "$out"
  if [ $rc -ne 0 ]; then
    bad "$desc" "exit $rc: $(printf '%s' "$out" | tail -1)"
  elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
    bad "$desc" "expected '$expect', got: $(printf '%s' "$out" | tail -1)"
  else
    ok "$desc"
  fi
}

check_fail() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [ -n "$VERBOSE" ] && printf '       $ %s\n%s\n' "$*" "$out"
  if [ $rc -eq 0 ]; then bad "$desc" "should have failed"; else ok "$desc"; fi
}

# ------------------------------------------------------------------ manifests
note "manifests"
if command -v claude >/dev/null; then
  check "marketplace valid" "Validation passed" claude plugin validate "$REPO" --strict
  check "plugin valid"      "Validation passed" claude plugin validate "$REPO/plugins/deck" --strict
else
  skip "marketplace valid — claude not on PATH"
  skip "plugin valid — claude not on PATH"
fi

note "core catalog"
check "catalog is consistent" "OK —" "$DECK" toggle validate --strict

# -------------------------------------------------------- synthetic workspace
WS="$(mktemp -d)"
PACKS="$(mktemp -d)/collection"
PACK="$PACKS/_workspace"
# INT and TERM as well as EXIT: bash runs no EXIT trap for a signal it was not
# told about, and the tracker stand-in below serves until something kills it.
# A Ctrl-C already left the workspace behind; it would now leave a listening
# process behind with it.
cleanup() { kill ${FAKE:-} ${FAKE2:-} 2>/dev/null; rm -rf "$WS" "$PACKS"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
mkdir -p "$WS"/{a,b,c} "$WS/.deck" "$PACK/config" "$PACK/templates/workspace"
for d in a b c; do git -C "$WS/$d" init -q 2>/dev/null; done
: > "$WS/.example-root"

cat > "$WS/.deck/workspace.yaml" <<YAML
version: 1
requires: []
repos:
  a: { path: a, role: schema,  build_target: pkg-a, impacts: [b] }
  b: { path: b, role: server,  build_target: pkg-b, impacts: [c] }
  c: { path: c, role: e2e,     downstream: true, impacts: [] }
targets:
  - { host: 10.0.0.4, role: primary, alias: lab-1 }
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$WS/.deck/toggles.yaml"

cat > "$PACK/config/detect.yaml" <<'YAML'
markers: [".example-root"]
prerequisites: [git, {name: definitely-not-installed, required: false}]
YAML
cat > "$PACK/config/toggles.yaml" <<'YAML'
toggles:
  - id: api_compat
    group: quality
    title: API compatibility
    summary: How far this change may alter the published contract.
    type: enum
    values: [strict, breaking]
    default: strict
    stage: [plan]
    risk: high
    impact: { strict: Additive only., breaking: Needs a migration note. }
    question:
      header: API compat
      text: May this change alter the published contract?
      options:
        - { value: strict,   label: Additive only,  description: Nothing removed or renamed. }
        - { value: breaking, label: May break,      description: Needs a migration note. }
  - id: deploy_mode
    overrides: true
    values: [none, fast, packaged]
    question:
      options:
        - { value: fast,     label: Sync to the pod, description: Seconds; diverges from the image. }
        - { value: packaged, label: Install package, description: Real packaging. }
        - { value: none,     label: Do not deploy,   description: Stop at the build. }
YAML

export DECK_ROOT="$WS"

note "workspace resolution"
check "root from the environment"   "$WS"       "$DECK" root
check "descriptor is read"          "pkg-a"     "$DECK" repos --verbose
check "absolute path"               "$WS/a"     "$DECK" path a
check "dotted key lookup"           "10.0.0.4"  "$DECK" get targets.0.host
check_fail "unknown repository fails"           "$DECK" path nope

unset DECK_ROOT
export DECK_PACKS_ROOT="$PACKS"
check "auto-detection via pack marker" "$WS" env -u DECK_ROOT sh -c "cd '$WS/a' && '$DECK' root"
export DECK_ROOT="$WS"

note "impact graph"
check "transitive closure"   '"impacted"'  "$DECK" impact a --json
check "build target"         "pkg-b"       "$DECK" impact a --json
check "downstream is flagged" "downstream" "$DECK" impact a --json
if [ "$("$DECK" order c b a | tr '\n' ' ')" = "a b c " ]; then
  ok "topological order is a b c even when given c b a"
else
  bad "topological order" "got: $("$DECK" order c b a | tr '\n' ' ')"
fi

# A cycle has to be detectable, and for a long time it was not: the first
# implementation leaned on helpers that are deliberately cycle-blind.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml, copy
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
bad = copy.deepcopy(d); bad["repos"]["c"]["impacts"] = ["a"]
pathlib.Path(str(p) + ".cycle").write_text(yaml.safe_dump(bad, sort_keys=False))
PY
cp "$WS/.deck/workspace.yaml" "$WS/.deck/workspace.yaml.ok"
cp "$WS/.deck/workspace.yaml.cycle" "$WS/.deck/workspace.yaml"
cyc="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$cyc" | grep -q "cycle"; then ok "a cycle is detected"; else bad "a cycle is detected"; fi
if "$DECK" doctor >/dev/null 2>&1; then bad "a cycle fails the diagnosis"; else ok "a cycle fails the diagnosis"; fi
cp "$WS/.deck/workspace.yaml.ok" "$WS/.deck/workspace.yaml"
acy="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$acy" | grep -q "acyclic"; then ok "an acyclic graph is reported as such"; else bad "an acyclic graph is reported as such"; fi
rm -f "$WS/.deck/workspace.yaml.cycle" "$WS/.deck/workspace.yaml.ok"

# An empty target allowlist is a gap only when the ladder is meant to climb past
# `build`. doctor used to warn unconditionally, so a workspace that had decided
# to stop at build carried a warning it could never clear.
cp "$WS/.deck/workspace.yaml" "$WS/.deck/workspace.yaml.withtarget"
sed -i '/^targets:/,/alias: lab-1 }/d' "$WS/.deck/workspace.yaml"
tgt="$(DECK_GATE_LEVEL=build "$DECK" doctor 2>&1 || true)"
if printf '%s' "$tgt" | grep -q "not needed: gate_level = build"; then
  ok "no target is fine when the ladder stops at build"
else
  bad "no target is fine when the ladder stops at build" "$(printf '%s' "$tgt" | grep -A1 'targets')"
fi
tgt="$(DECK_GATE_LEVEL=deploy "$DECK" doctor 2>&1 || true)"
if printf '%s' "$tgt" | grep -q "gate_level = deploy needs one"; then
  ok "no target still warns when the ladder reaches deploy"
else
  bad "no target still warns when the ladder reaches deploy" "$(printf '%s' "$tgt" | grep -A1 'targets')"
fi
mv "$WS/.deck/workspace.yaml.withtarget" "$WS/.deck/workspace.yaml"

note "toggle precedence"
check "catalog default"        "affected" "$DECK" toggle get build_scope
check "catalog default holds"  "deploy"   "$DECK" toggle get gate_level
if [ "$(DECK_GATE_LEVEL=static "$DECK" toggle get gate_level)" = "static" ]; then
  ok "environment beats the workspace"
else
  bad "environment beats the workspace"
fi
"$DECK" toggle --session smoke set gate_level build --at task >/dev/null
if [ "$("$DECK" toggle --session smoke get gate_level)" = "build" ]; then
  ok "task beats the workspace"
else
  bad "task beats the workspace"
fi
"$DECK" toggle --session smoke profile guided --at task >/dev/null
check "profile guided requires tests" "required" "$DECK" toggle --session smoke get unit_tests

# ------------------------------------------------- the reason behind a value
# The value and the layer were always recorded; the sentence explaining the
# choice was not, so six months on a deliberate decision and a value nobody
# revisited looked identical. The catalog's own `why` is a different sentence
# by a different author, and the two are printed apart rather than merged.
note "why a value was chosen"

mkdir -p "$WS/.deck/state"
"$DECK" toggle --session why set gate_level build --at task \
  --why "delivery goes through a firmware update path nobody has wired to deck yet" >/dev/null
recorded="$(cat "$WS/.deck/state/toggles-why.yaml" 2>&1)"
if printf '%s' "$recorded" | grep -q "firmware update path"; then
  ok "the reason survives in the file, beside the value"
else
  bad "the reason survives in the file, beside the value" "$recorded"
fi

out="$("$DECK" toggle --session why explain gate_level 2>&1)"
if printf '%s' "$out" | grep -q "why the toggle exists"; then
  ok "explain still carries the catalog's own reason"
else
  bad "explain still carries the catalog's own reason" "$out"
fi
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "firmware update path"; then
  ok "and the chooser's reason under a heading of its own"
else
  bad "and the chooser's reason under a heading of its own" "$out"
fi

# The whole point of the split: a value with nothing recorded must not be able
# to borrow the catalog's paragraph and read as justified.
check "a value with no reason is still recorded" "gate_level = build" \
  "$DECK" toggle --session bare set gate_level build --at task
out="$("$DECK" toggle --session bare explain gate_level 2>&1)"
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "not recorded"; then
  ok "and says so rather than looking justified"
else
  bad "and says so rather than looking justified" "$out"
fi
if printf '%s' "$chosen" | grep -q "Not every change deserves"; then
  bad "the catalog's reason never stands in for a missing one" "$chosen"
else
  ok "the catalog's reason never stands in for a missing one"
fi
if printf '%s' "$chosen" | grep -q "deck toggle set gate_level build --at task --why"; then
  ok "and names the command that would record one"
else
  bad "and names the command that would record one" "$chosen"
fi

# A reason belongs to the value it was written for. Left behind, it would go on
# justifying a decision that is no longer the one in the file.
out="$("$DECK" toggle --session why set gate_level static --at task 2>&1)"
if printf '%s' "$out" | grep -q "dropped the reason"; then
  ok "a value set without --why drops the reason, and says so"
else
  bad "a value set without --why drops the reason, and says so" "$out"
fi
out="$("$DECK" toggle --session why explain gate_level 2>&1)"
if printf '%s' "$out" | grep -q "firmware update path"; then
  bad "the new value does not inherit the old one's reason" "$out"
else
  ok "the new value does not inherit the old one's reason"
fi
out="$("$DECK" toggle --session why set gate_level build --at task --why "   " 2>&1 || true)"
if printf '%s' "$out" | grep -q "needs a reason"; then
  ok "an empty --why is refused rather than recorded as none"
else
  bad "an empty --why is refused rather than recorded as none" "$out"
fi

# A choices file written before any of this existed keeps working, and claims
# no reason it does not have.
printf 'version: 1\nvalues:\n  gate_level: static\n' > "$WS/.deck/state/toggles-old.yaml"
check "a file written before reasons existed still resolves" "static" \
  "$DECK" toggle --session old get gate_level
out="$("$DECK" toggle --session old explain gate_level 2>&1)"
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "not recorded"; then
  ok "and reports no reason rather than inventing one"
else
  bad "and reports no reason rather than inventing one" "$out"
fi

# The layer nobody sets from the command line: a repository block is written by
# hand, in either the flat shape it has always had or the nested one.
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["repos"] = {"a": {"gate_level": "behavior",
                    "reasons": {"gate_level": "it is the published contract"}}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
out="$(sh -c "cd '$WS/a' && '$DECK' toggle explain gate_level" 2>&1)"
if printf '%s' "$out" | grep -q "why this value was chosen (repo a)"; then
  ok "a hand-written repository choice carries its reason too"
else
  bad "a hand-written repository choice carries its reason too" "$out"
fi
value="$(sh -c "cd '$WS/a' && '$DECK' toggle get gate_level" 2>&1)"
if [ "$value" = "behavior" ]; then
  ok "and the reasons map beside it is not read as a toggle"
else
  bad "and the reasons map beside it is not read as a toggle" "got: $value"
fi

# A reason with no value beside it justifies a decision this layer never makes.
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["reasons"] = {"test_depth": "explains nothing: no value here"}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
out="$("$DECK" toggle validate 2>&1)"
if printf '%s' "$out" | grep -q "it explains nothing"; then
  ok "validate reports a reason with no value beside it"
else
  bad "validate reports a reason with no value beside it" "$out"
fi
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d.pop("reasons", None); d["repos"] = {}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

# `--json` is the machine's view of the whole catalog at once. Without the
# reason in the row, a consumer that has just read fifty values has to call
# `explain` fifty times to find out which of them anyone decided.
"$DECK" toggle --session why set unit_tests required --at task \
  --why "the parser is the published contract, and nothing else checks it" >/dev/null
listed="$("$DECK" toggle --session why list --json 2>&1 || true)"
if printf '%s' "$listed" | python3 -c 'import json,sys
rows = {r["id"]: r for r in json.load(sys.stdin)["toggles"]}
sys.exit(0 if "published contract" in (rows["unit_tests"]["reason"] or "") else 1)' 2>/dev/null; then
  ok "toggle list --json carries the reason beside the value"
else
  bad "toggle list --json carries the reason beside the value" "$(printf '%s' "$listed" | head -3)"
fi
if printf '%s' "$listed" | python3 -c 'import json,sys
rows = {r["id"]: r for r in json.load(sys.stdin)["toggles"]}
sys.exit(0 if rows["question_budget"]["reason"] is None else 1)' 2>/dev/null; then
  ok "and a value nobody chose here carries null, not the catalog's rationale"
else
  bad "and a value nobody chose here carries null, not the catalog's rationale" \
    "$(printf '%s' "$listed" | head -3)"
fi

note "pack composition"
check "pack toggle is merged"   "api_compat"      "$DECK" toggle explain api_compat
check "pack origin is reported" "_workspace"    "$DECK" toggle explain api_compat
if "$DECK" toggle ask-plan --stage verify | grep -q "Sync to the pod"; then
  ok "pack relabels a core toggle"
else
  bad "pack relabels a core toggle"
fi
sed -i 's/    overrides: true//' "$PACK/config/toggles.yaml"
check_fail "collision without overrides is refused" "$DECK" toggle validate
sed -i 's/  - id: deploy_mode/  - id: deploy_mode\n    overrides: true/' "$PACK/config/toggles.yaml"

note "questions"
if [ "$("$DECK" toggle ask-plan --stage verify | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["questions"][0]["id"])')" = "deploy_mode" ]; then
  ok "deploy_mode becomes a question at verify"
else
  bad "deploy_mode becomes a question at verify"
fi
if [ "$("$DECK" toggle get target)" = "10.0.0.4" ]; then
  ok "a single target settles without asking"
else
  bad "a single target settles without asking" "got: $("$DECK" toggle get target)"
fi
if [ "$(DECK_QUESTION_BUDGET=0 "$DECK" toggle ask-plan --stage verify | python3 -c \
        'import json,sys; print(len(json.load(sys.stdin)["questions"]))')" = "0" ]; then
  ok "a zero budget asks nothing"
else
  bad "a zero budget asks nothing"
fi

note "registry importers"
mkdir -p "$WS/.repo/manifests"
cat > "$WS/.repo/manifests/default.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="origin" fetch="ssh://git@example.invalid/"/>
  <default remote="origin" revision="main"/>
  <project name="a.git" path="a"/>
  <project name="b.git" path="b"/>
  <include name="extra.xml"/>
</manifest>
XML
cat > "$WS/.repo/manifests/extra.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest><project name="c.git" path="c" revision="stable"/></manifest>
XML
ln -s manifests/default.xml "$WS/.repo/manifest.xml"

check "repo layout is detected"     "repo"        "$DECK" import
check "manifest includes are read"  "c"           "$DECK" import repo
check "dry run writes nothing"      "Nothing written" "$DECK" import repo
if "$DECK" import repo | grep -q "3 repositories"; then
  ok "three projects across manifest and include"
else
  bad "three projects across manifest and include"
fi
before="$(grep -c 'impacts' "$WS/.deck/workspace.yaml")"
"$DECK" import repo --write >/dev/null
if "$DECK" impact a --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["impacted"]==["b","c"] else 1)'; then
  ok "authored impacts survive a re-import"
else
  bad "authored impacts survive a re-import"
fi
if [ "$("$DECK" repos | wc -l)" = "3" ]; then
  ok "matching on path does not duplicate entries"
else
  bad "matching on path does not duplicate entries" "got $("$DECK" repos | tr '\n' ' ')"
fi
check_fail "unknown source is refused" "$DECK" import nosuchthing

note "mounting artifacts"
mkdir -p "$PACK/rules"
cat > "$PACK/config/mount.yaml" <<'YAML'
plugin: example-pack@example
marketplace: { name: example, source: { source: url, url: "https://example.invalid/p.git" } }
rules:
  - { file: rules/only-a.md, repos: [a] }
  - { file: rules/everywhere.md }
YAML
printf -- '---\npaths: ["**/*.py"]\n---\n\nrule for a\n' > "$PACK/rules/only-a.md"
printf -- '---\npaths: ["**/*"]\n---\n\nrule for all\n' > "$PACK/rules/everywhere.md"

check "dry run writes nothing"        "Nothing written" "$DECK" mount --task T1 --repos a --dry-run
if [ ! -e "$WS/a/.claude" ]; then ok "dry run leaves the tree untouched"; else bad "dry run leaves the tree untouched"; fi

"$DECK" mount --task T1 --repos a --brief "do the thing" >/dev/null
if [ -f "$WS/a/.claude/settings.local.json" ]; then ok "plugin enabled at local scope"; else bad "plugin enabled at local scope"; fi
# Claude Code loads `.claude/rules/*.md` but does not follow a symlink there, so
# a linked rule is placed, reported as mounted, and silently never read.
if [ -f "$WS/a/.claude/rules/deck-only-a.md" ] && [ ! -L "$WS/a/.claude/rules/deck-only-a.md" ]; then
  ok "a rule is a regular file, because a symlinked rule is never loaded"
else
  bad "a rule is a regular file, because a symlinked rule is never loaded" "$(ls -l "$WS/a/.claude/rules/" 2>&1)"
fi
if grep -q "rule for a" "$WS/a/.claude/rules/deck-only-a.md" 2>/dev/null; then
  ok "and it carries the pack's content"
else
  bad "and it carries the pack's content" "$(cat "$WS/a/.claude/rules/deck-only-a.md" 2>&1)"
fi
if [ -f "$WS/b/.claude/rules/deck-everywhere.md" ] && [ ! -e "$WS/b/.claude/rules/deck-only-a.md" ]; then
  ok "repo-scoped rule only lands where it applies"
else
  bad "repo-scoped rule only lands where it applies"
fi
if [ -f "$WS/CLAUDE.local.md" ] && [ "$(find "$WS" -name CLAUDE.local.md | wc -l)" = "1" ]; then
  ok "the brief is written once, at the root"
else
  bad "the brief is written once, at the root"
fi
if [ -z "$(git -C "$WS/a" status --short)" ]; then ok "mounting does not dirty git status"; else bad "mounting does not dirty git status" "$(git -C "$WS/a" status --short | tr '\n' ' ')"; fi
check "mounts are listed"            "T1"     "$DECK" mounts
twice="$("$DECK" mount --task T1 --repos a 2>&1 || true)"
if printf '%s' "$twice" | grep -q "already mounted"; then
  ok "mounting twice is refused"
else
  bad "mounting twice is refused" "$twice"
fi

# a third-party entry in the same settings file must survive
python3 - "$WS/b/.claude/settings.local.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["enabledPlugins"]["someone-else@x"] = True
p.write_text(json.dumps(d))
PY
rm "$WS/a/.claude/rules/deck-everywhere.md"
echo "hand edited" > "$WS/a/.claude/rules/deck-everywhere.md"
# A copy cannot be written through into the pack, which is the point: editing the
# pack after mounting leaves what was placed alone.
echo "" >> "$PACK/rules/only-a.md"
if ! tail -1 "$WS/a/.claude/rules/deck-only-a.md" | grep -q "^$"; then
  ok "editing the pack does not reach through into a mounted rule"
else
  bad "editing the pack does not reach through into a mounted rule"
fi

"$DECK" unmount --task T1 > "$WS/unmount.txt" 2>&1
if grep -q "LEFT" "$WS/unmount.txt"; then ok "an edited artifact is reported, not deleted"; else bad "an edited artifact is reported, not deleted"; fi
if [ -f "$WS/a/.claude/rules/deck-everywhere.md" ]; then ok "the edited file is still there"; else bad "the edited file is still there"; fi
if grep -q "someone-else@x" "$WS/b/.claude/settings.local.json" 2>/dev/null; then
  ok "another plugin in the same file survives"
else
  bad "another plugin in the same file survives"
fi
if [ ! -e "$WS/b/.claude/rules/deck-everywhere.md" ]; then ok "untouched artifacts are removed"; else bad "untouched artifacts are removed"; fi
if ! grep -q "deck: begin" "$WS/b/.git/info/exclude" 2>/dev/null; then ok "the exclude block is taken back"; else bad "the exclude block is taken back"; fi
if [ ! -e "$WS/a/.claude/rules/deck-only-a.md" ]; then
  ok "an untouched rule copy is taken back"
else
  bad "an untouched rule copy is taken back" "$(cat "$WS/unmount.txt")"
fi
if "$DECK" doctor 2>&1 | grep -q "T1"; then ok "doctor reports the leftover mount"; else bad "doctor reports the leftover mount"; fi
rm -rf "$WS/a/.claude" "$WS/b/.claude" "$WS/CLAUDE.local.md" "$WS/.deck/mounts"

# "nothing it places survives an unmount" has to include the directories the
# placement created — an empty .claude/rules/ left in someone else's repository
# is litter, and it is the visible kind.
"$DECK" mount --task T2 --repos a >/dev/null 2>&1
if [ -d "$WS/a/.claude/rules" ]; then ok "mount creates the rules directory"; else bad "mount creates the rules directory"; fi
"$DECK" unmount --task T2 >/dev/null 2>&1
left="$(find "$WS/a/.claude" -mindepth 1 2>/dev/null || true)"
if [ -d "$WS/a/.claude/rules" ]; then
  bad "unmount takes the directories it made" "rules/ survived"
elif [ -n "$left" ]; then
  # .claude itself may legitimately hold settings.local.json, which deck wrote
  # for the plugin strategy and removes separately. Only the empty ones go.
  ok "unmount takes the empty directories it made"
else
  ok "unmount takes the directories it made"
fi
rm -rf "$WS/a/.claude" "$WS/CLAUDE.local.md" "$WS/.deck/mounts"

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

# ----------------------------------------------------- measurements over time
# A gate answers "did it pass" against a threshold. These check the other half:
# the number behind the pass, and which way it has been going.
note "measurements over time"
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: counted
    title: Counted
    from_level: static
    per_repo: "echo 'progress: 3 warnings'; echo '${repo.name}: 7 warnings, 91.5% coverage'"
    measures:
      - { id: warnings, title: warnings,     pattern: '(\d+) warnings',       unit: warnings, better: lower }
      - { id: coverage, title: line coverage, pattern: '([0-9.]+)% coverage', unit: '%',      better: higher }
      - { id: absent,   title: never printed, pattern: 'nothing prints (\d+)' }
YAML

out="$("$DECK" gate run --task M1 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "warnings     7 warnings"; then ok "a gate measures a number out of its own output"; else bad "a gate measures a number out of its own output" "$out"; fi
# "progress: 3 warnings" is printed before the summary, so first-match would
# record the number from the middle of the work.
if printf '%s' "$out" | grep -q "warnings     7"; then ok "the last match wins, so a progress line does not become the sample"; else bad "the last match wins" "$out"; fi
if printf '%s' "$out" | grep -q "coverage     91.5 %"; then ok "a decimal is recorded as measured"; else bad "a decimal is recorded as measured" "$out"; fi
if printf '%s' "$out" | grep -q "absent       not measured"; then ok "a pattern that matched nothing is not measured, never zero"; else bad "a pattern that matched nothing is not measured" "$out"; fi
# Two repositories (a, and b through the impact edge) and two metrics that
# matched: the third matched nothing and contributes no sample at all.
if printf '%s' "$out" | grep -q "4 measurement(s) added"; then ok "only what was measured joins the series"; else bad "only what was measured joins the series" "$out"; fi

# One file per repository. Interleaving them would make "first against last" a
# comparison between two different things.
if [ -f "$WS/.deck/metrics/counted.warnings@a.jsonl" ] && [ -f "$WS/.deck/metrics/counted.warnings@b.jsonl" ]; then
  ok "the series lives under .deck/metrics, one file per repository"
else
  bad "the series lives under .deck/metrics, one file per repository"
fi
out="$("$DECK" metrics show counted.warnings --repo b 2>&1)"
if printf '%s' "$out" | grep -q "a trend needs a second"; then ok "one sample is reported as one sample, not as a trend"; else bad "one sample is reported as one sample" "$out"; fi

# The number moves. Nothing about the gate changes: it still passes.
sed -i 's/7 warnings, 91.5% coverage/9 warnings, 88.0% coverage/' "$PACK/config/gates.yaml"
out="$("$DECK" gate run --task M2 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "was 7 on M1"; then ok "a run is reported against the sample before it"; else bad "a run is reported against the sample before it" "$out"; fi
if printf '%s' "$out" | grep -q "1 gate(s) passed"; then ok "and the gate still passes, which is the point"; else bad "and the gate still passes" "$out"; fi

out="$("$DECK" metrics list 2>&1)"
if printf '%s' "$out" | grep -q "moving the wrong way"; then ok "the trend names the direction the pack declared as worse"; else bad "the trend names the direction" "$out"; fi
if printf '%s' "$out" | grep -q "no sample yet"; then ok "a metric declared and never measured says so"; else bad "a metric declared and never measured says so" "$out"; fi
out="$("$DECK" metrics show counted.coverage --repo a 2>&1)"
if printf '%s' "$out" | grep -q "M1"; then ok "every sample is shown with the run it came from"; else bad "every sample is shown with the run it came from" "$out"; fi
if printf '%s' "$out" | grep -q "91.5 -> 88"; then ok "and the series is first against last, in the unit it was measured in"; else bad "and the series is first against last" "$out"; fi
check_fail "an unknown metric is refused, with the known ones listed" "$DECK" metrics show nope.nope

# The finding a threshold cannot produce: everything passed, and it is worse.
out="$("$DECK" bundle --task M2 2>&1 || true)"
if printf '%s' "$out" | grep -q "passing and getting worse"; then ok "a bundle qualifies a passing task whose numbers slid"; else bad "a bundle qualifies a passing task whose numbers slid" "$out"; fi
if printf '%s' "$out" | grep -q "what was measured"; then ok "and carries the measurements beside the gates"; else bad "and carries the measurements beside the gates" "$out"; fi

# Where the series lives is a decision, and one of its values is `nowhere`.
"$DECK" toggle set --at workspace metrics_store off >/dev/null
out="$("$DECK" gate run --task M4 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q 'metrics_store is `off`'; then ok "metrics_store off measures and keeps nothing, and says so"; else bad "metrics_store off says so" "$out"; fi
if printf '%s' "$out" | grep -q "warnings     9"; then ok "and the run still prints the number it measured"; else bad "and the run still prints the number" "$out"; fi

"$DECK" toggle set --at workspace metrics_store shared >/dev/null
out="$("$DECK" gate run --task M5 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "declares no \`metrics_dir:\`"; then ok "shared with nowhere declared is refused, not written per machine"; else bad "shared with nowhere declared is refused" "$out"; fi
if printf '%s' "$out" | grep -q "Add \`metrics_dir:"; then ok "and the refusal carries the edit that resolves it"; else bad "and the refusal carries the edit" "$out"; fi

printf 'metrics_dir: %s\n' "$WS/shared-metrics" >> "$WS/.deck/workspace.yaml"
"$DECK" gate run --task M6 --repos a --level static --only counted >/dev/null 2>&1
if [ -f "$WS/shared-metrics/counted.warnings@a.jsonl" ]; then ok "with a directory declared the series goes there instead"; else bad "with a directory declared the series goes there instead"; fi
"$DECK" toggle set --at workspace metrics_store workspace >/dev/null

# A pack that declares a measurement badly is refused at load, not at read time:
# a sample silently dropped leaves a hole, and a hole reads like stability.
cp "$PACK/config/gates.yaml" "$WS/gates.backup"
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: mismeasured
    title: Mismeasured
    from_level: static
    per_repo: "echo 1"
    measures:
      - { id: coverage, pattern: '(' }
YAML
check_fail "a measure whose pattern is not a regular expression is refused" "$DECK" metrics list
cp "$WS/gates.backup" "$PACK/config/gates.yaml"

# `applicable()` reads a gate with no `from_level` as the first rung and runs it
# there, but `record()` filed what the gate declared, which was nothing. The gate
# came back belonging to no rung, where `rung_completed()` could neither credit
# it nor stop on it. The plan now decides the rung once and the record files that.
note "a gate declared without a rung is placed on one"
cp "$PACK/config/gates.yaml" "$WS/gates.backup"
printf '  - { id: unrung, title: Unrung, per_repo: "echo unrung ${repo.name}" }\n' >> "$PACK/config/gates.yaml"

plan="$("$DECK" gate list --repos a --json 2>&1)"
rung="$(printf '%s' "$plan" | python3 -c "
import json, sys
print(next(g.get('from_level') for g in json.load(sys.stdin)['gates'] if g['id'] == 'unrung'))
" 2>&1)"
if [ "$rung" = "static" ]; then
  ok "the plan places a gate with no from_level on the first rung"
else
  bad "the plan places a gate with no from_level on the first rung" "$rung"
fi

"$DECK" gate run --task UR1 --repos a --level static --only unrung >/dev/null 2>&1
filed="$(python3 -c "
import json
print(*[repr(g['from_level']) for g in json.load(open('$WS/.deck/gates/UR1.json'))['gates']])
" 2>&1)"
if [ "$filed" = "'static'" ]; then
  ok "and the evidence files it at the rung it ran on, not at null"
else
  bad "and the evidence files it at the rung it ran on, not at null" "$filed"
fi

# The other half of the decision, and a guard: a `from_level` written and left
# empty is a line its author did not finish. Reading it as static would place a
# gate on a rung nobody chose, which is the guess this program refuses to make.
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: halfway
    title: Halfway
    from_level:
    per_repo: "true"
YAML
half="$("$DECK" gate list --repos a 2>&1)"
if printf '%s' "$half" | grep -A1 "halfway" | grep -q "is not a rung of this ladder"; then
  ok "a from_level written and left empty is still refused, not placed for the author"
else
  bad "a from_level written and left empty is still refused, not placed for the author" "$half"
fi
cp "$WS/gates.backup" "$PACK/config/gates.yaml"

note "board planning"
cat > "$WS/.deck/board.yaml" <<'YAML'
tasks:
  - { id: T-1, title: schema change,  repos: [a] }
  - { id: T-2, title: docs,           repos: [c] }
  - { id: T-3, title: server work,    repos: [b] }
  - { id: T-4, title: key rotation,   repos: [b], exclusive: true }
  - { id: T-5, title: finished,       repos: [b], status: done }
YAML
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "tasks are read"           "T-1"        "$DECK" board list
check "a done task is not planned" "T-5"      "$DECK" board plan
check "an exclusive task stands alone" "alone" "$DECK" board plan
check "conflicts are explained"  "would edit" "$DECK" board why T-1 T-3
if "$DECK" board why T-2 T-3 | grep -q "can run at the same time"; then
  ok "independent tasks are allowed together"
else
  bad "independent tasks are allowed together"
fi
if "$DECK" board plan --json | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if any(g["parallel"] for g in p["groups"]) else 1)'; then
  ok "something actually parallelises"
else
  bad "something actually parallelises"
fi
if "$DECK" board plan --parallelism 1 --json | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if not any(g["parallel"] for g in p["groups"]) else 1)'; then
  ok "parallelism 1 serialises everything"
else
  bad "parallelism 1 serialises everything"
fi
check "the plan says it is not a run" "not a run" "$DECK" board plan

# An agent inside a run has no channel to a person, so a toggle left at `ask` is
# a wall and not a prompt. The board has to say which decisions block it before
# anything is spawned.
out="$("$DECK" board ask-plan 2>&1 || true)"
if printf '%s' "$out" | grep -q "waiting on"; then ok "the board names the decisions blocking it"; else bad "the board names the decisions blocking it" "$out"; fi
if printf '%s' "$out" | grep -q "blocks "; then ok "and which tasks each one blocks"; else bad "and which tasks each one blocks" "$out"; fi
check_fail "a board with pending decisions exits non-zero" "$DECK" board ask-plan
if "$DECK" board plan --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("pending_decisions") else 1)'; then
  ok "the plan carries them, so a workflow cannot miss them"
else bad "the plan carries them, so a workflow cannot miss them"; fi
before="$("$DECK" board ask-plan --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))')"
# Answer whichever one is actually pending, rather than assuming which — and put
# it back, so this check does not decide something a later one reads.
ANSWERED="$("$DECK" board ask-plan --json | python3 -c '
import json, subprocess, sys
q = json.load(sys.stdin)["questions"][0]
subprocess.run([sys.argv[1], "toggle", "set", "--at", "workspace", q["id"], q["options"][0]["value"]],
               capture_output=True)
print(q["id"])
' "$DECK")"
after="$("$DECK" board ask-plan --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))')"
if [ "$after" -lt "$before" ]; then ok "an answered decision leaves the list"; else bad "an answered decision leaves the list" "$before -> $after"; fi
"$DECK" toggle set --at workspace "$ANSWERED" ask >/dev/null 2>&1

# `c` is downstream in the synthetic workspace, so T-1 (repos: [a]) reaches it
# without naming it and T-2 (repos: [c]) edits it. That pair is allowed to run
# together — reaching is not editing — and is still worth one line of warning.
check "a downstream repo one task edits and another reaches is flagged" "which T-2 edits" "$DECK" board plan
if "$DECK" board plan --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("cautions") else 1)'; then
  ok "the caution is in the json a workflow consumes"
else bad "the caution is in the json a workflow consumes"; fi

# A declared backlog whose file exists but yields nothing used to pass doctor
# and leave `board list` empty with no explanation.
BQ="$WS/backlog-prose.md"
printf '# Roadmap\n\n## Item one\nProse, not a checklist.\n' > "$BQ"
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t + "\nbacklog:\n- type: roadmap\n  file: backlog-prose.md\n")
PY
check "a backlog that parses to nothing says so" "no tasks in backlog-prose.md" "$DECK" board list
check "and names the shape it expected" "- [ ]" "$DECK" board list
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("\nbacklog:\n- type: roadmap\n  file: backlog-prose.md\n", "\n"))
PY
rm -f "$BQ"

# A shared board must not default into .deck/, which is per machine.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text() + "\nbacklog:\n- type: tasks\n")
PY
check_fail "a tasks source with no file: refuses to be written to" "$DECK" board new "x" --yes
out="$("$DECK" board new "x" --yes 2>&1)"
if printf '%s' "$out" | grep -q "the team versions"; then ok "and says where to declare one"; else bad "and says where to declare one" "$out"; fi
# Put the real board back by rewriting the key, not by unpicking the text: the
# stub above and the genuine source share their first two lines, so a textual
# removal took both and left `file:` orphaned under `targets:`. Every board
# check after this point then ran against a descriptor with no backlog at all,
# and passed, because "no tasks" is not what any of them was asserting.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check "the board is readable again" "T-1" "$DECK" board list

note "scopes"
# A scope is a named subset of the registry with its own board and posture. The
# checks that matter are the ones about what it must NOT do: narrowing what a
# command acts on is the feature, narrowing what deck knows would be a lie.
cat > "$WS/.deck/board-side.yaml" <<'YAML'
tasks:
  - { id: S-1, title: side work,            repos: [c] }
  - { id: S-2, title: side work that leaks, repos: [c, a] }
YAML
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {
    "core": {"title": "The build chain", "repos": ["a", "b"]},
    "side": {"title": "The side project", "repos": ["c"],
             "backlog": [{"type": "tasks", "file": ".deck/board-side.yaml"}]},
}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "declared scopes are listed"     "core"    "$DECK" scopes
check "a scope names its subset"       "2 of 3"  "$DECK" scope core
check "and what it reaches outside"    "reaches" "$DECK" scope core
# Regression guard: this registry declares no `couples:`, and the coupled half
# of the boundary report has to stay silent rather than print an empty heading.
out="$("$DECK" scope core 2>&1 || true)"
if printf '%s' "$out" | grep -qi "coupled"; then
  bad "a scope in a registry with no coupling says nothing about coupling" "$out"
else ok "a scope in a registry with no coupling says nothing about coupling"; fi
if [ "$("$DECK" --scope core repos | tr '\n' ' ')" = "a b " ]; then
  ok "the registry narrows to exactly the scope"
else
  bad "the registry narrows to exactly the scope" "got: $("$DECK" --scope core repos | tr '\n' ' ')"
fi
check_fail "an undeclared scope is refused" "$DECK" --scope nope repos
out="$("$DECK" --scope nope repos 2>&1 || true)"
if printf '%s' "$out" | grep -q "core, side"; then ok "and the refusal lists the real ones"; else bad "and the refusal lists the real ones" "$out"; fi

# The graph is not narrowed. A change inside a scope still reaches what it
# reaches, and the report says which of those the scope does not hold.
check "impact still reports the whole chain" '"c"'            "$DECK" --scope core impact a --json
check "and marks what falls outside"         "outside scope"  "$DECK" --scope core impact a

# `c` is not in `core`, so T-2 is not this scope's work.
if "$DECK" --scope core board list | grep -q "T-2"; then
  bad "the shared board is narrowed to the scope"
else
  ok "the shared board is narrowed to the scope"
fi
check "and keeps the tasks it does hold"    "T-1" "$DECK" --scope core board list
# A task naming no repository cannot be placed in one scope rather than
# another, so no scope takes it — and it is named rather than dropped in
# silence, which is the difference between a filter and a disappearance.
printf '  - { id: T-6, title: names no repository }\n' >> "$WS/.deck/board.yaml"
check "a scope with its own board reads it" "S-1" "$DECK" --scope side board list
if "$DECK" --scope side board list | grep -q "T-1"; then
  bad "its own board replaces the workspace one"
else
  ok "its own board replaces the workspace one"
fi
check "a task naming a repo the scope lacks is reported" "which the scope does not hold" "$DECK" --scope side board list
check "a task naming no repository is not silently claimed" "no scope claims" "$DECK" --scope core board list

# The posture: a layer between the repository and the workspace.
"$DECK" toggle set --at core gate_level build >/dev/null
if [ "$("$DECK" --scope core toggle get gate_level)" = "build" ]; then
  ok "a value recorded for a scope applies inside it"
else
  bad "a value recorded for a scope applies inside it" "got: $("$DECK" --scope core toggle get gate_level)"
fi
if [ "$("$DECK" --scope side toggle get gate_level)" = "build" ]; then
  bad "and nowhere else" "the value leaked into another scope"
else
  ok "and nowhere else"
fi
check "the layer says where the value came from" "scope core" "$DECK" --scope core toggle explain gate_level
# `deck scope <name>` is the only view that shows a scope whole, and the posture
# is the part of it somebody argued about. It printed the values alone, so the
# argument stayed in the file — while `--json` has carried the `reasons:` block
# verbatim all along, which made the text form the odd one out.
"$DECK" toggle set --at core test_depth full \
  --why "everything downstream compiles against this schema" >/dev/null
shown="$("$DECK" scope core 2>&1 || true)"
if printf '%s' "$shown" | grep -q "why  everything downstream compiles against this schema"; then
  ok "deck scope shows the reason recorded with a posture value"
else
  bad "deck scope shows the reason recorded with a posture value" "$shown"
fi
posture="$(printf '%s' "$shown" | grep -A1 "gate_level" || true)"
if printf '%s' "$posture" | grep -q 'not recorded — deck toggle set gate_level build --at core --why'; then
  ok "and names the command for a posture value that has none"
else
  bad "and names the command for a posture value that has none" "$posture"
fi
check_fail "recording at a scope nobody declared is refused" "$DECK" toggle set --at nope gate_level build
"$DECK" toggle profile guided --at side >/dev/null
check "a profile can be recorded for a scope" "guided" "$DECK" --scope side toggle list --stage plan

# The ladder climbs the scope, not the registry.
check "gates run over the scope" "repos    a, b" "$DECK" --scope core gate list

check "doctor reports the scopes" "core" "$DECK" doctor
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"]["core"]["repos"] = ["a", "b", "ghost"]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check_fail "a scope naming an unknown repository fails the diagnosis" "$DECK" doctor
out="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "which the registry does not declare"; then
  ok "and says which name is wrong"
else
  bad "and says which name is wrong" "$out"
fi
out="$(DECK_SCOPE=nope "$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "not a declared scope"; then
  ok "an exported scope nobody declares is reported"
else
  bad "an exported scope nobody declares is reported" "$out"
fi

# Take the scopes away and leave the posture behind: a decision recorded for
# something that no longer exists applies to nothing, which is worse than no
# decision at all.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check_fail "a posture left behind for a scope that is gone is caught" "$DECK" toggle validate
out="$("$DECK" toggle validate 2>&1 || true)"
if printf '%s' "$out" | grep -q "no such scope"; then ok "and names it"; else bad "and names it" "$out"; fi
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()) or {}
d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
rm -f "$WS/.deck/board-side.yaml"
python3 - "$WS/.deck/board.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("  - { id: T-6, title: names no repository }\n", ""))
PY

note "trackers and the kanban"
# A local HTTP server standing in for the trackers, so the providers are
# exercised for real — request shape, auth header, and parsing — without
# touching the network.
#
# Written from what the services document, not from what deck sends, and the
# difference is the whole reason this file was wrong for months. A stand-in
# built to match the caller answers whatever the caller asks, so it agrees with
# the implementation by construction and the suite is green over a call the
# service stopped serving: that is exactly how `/rest/api/3/search` went on
# passing here while Jira Cloud answered it 410. Three rules keep it anchored
# to the API instead:
#
#   - a path the API does not document is a 404, so a reader that invents one
#     fails here rather than on someone's instance;
#   - each route wants the credentials its own service documents — Bearer for
#     GitHub, PRIVATE-TOKEN for GitLab, Basic for Jira and Gerrit — so sending
#     the wrong scheme is a 401 and not a pass;
#   - a response carries only what was asked for, the way the service says it
#     does. Jira returns issue ids and nothing else unless `fields` names more,
#     so a reader that forgets the parameter gets a board of blank titles.
#
# It also says no the way the real services say no: GitHub answers 201 to an
# assignment for a login that is not assignable on the repository and returns
# an issue that never gained it, and GitLab answers 200 to an `assignee_ids`
# naming somebody with no access to the project. A stand-in that always says
# yes cannot exercise a read-back.
cat > "$WS/fake.py" <<'PY'
import json
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CREATED = []
GITHUB_ASSIGNABLE = {'ana', 'bob'}       # github lowercases the login it records
GITLAB_USERS = {'ana': 42, 'ghost': 99}  # both accounts exist on the instance...
GITLAB_MEMBERS = {42: 'ana'}             # ...only one may be assigned on the project
JIRA_ACCOUNTS = {'acct-ana'}
GERRIT_TAGS = {'claimed-by-ana'}

# ---- jira, as /rest/api/3/search/jql documents itself ----------------------
# The body Jira Cloud answers the removed endpoint with: a 410 whose
# errorMessages names the endpoint that replaced it (CHANGE-2046).
JIRA_REMOVED = ('The requested API has been removed. Please migrate to the '
                '/rest/api/3/search/jql API. A full migration guideline is available '
                'at https://developer.atlassian.com/changelog/#CHANGE-2046')
# Every field this stand-in holds. A `fields` naming anything else is a 400 that
# names it, as Jira's is, so a reader asking for a field nobody has is caught
# here and not on someone's instance.
JIRA_ISSUES = {
    'ACME-1': {'summary': 'rate limit in `a`',
               'status': {'name': 'In Progress', 'statusCategory': {'key': 'indeterminate'}},
               'assignee': {'displayName': 'Ana'}, 'labels': ['agent-ready']},
    'ACME-2': {'summary': 'retry budget in `b`',
               'status': {'name': 'Done', 'statusCategory': {'key': 'done'}},
               'assignee': None, 'labels': []},
    'ACME-3': {'summary': 'timeout in `c`',
               'status': {'name': 'To Do', 'statusCategory': {'key': 'new'}},
               'assignee': None, 'labels': []},
}
# What each page answers, keyed by the token that asked for it. The middle page
# is empty and still hands out a token, because the endpoint documents that a
# page may carry fewer issues than were asked for — none included — while pages
# still follow it. A reader that stops on an empty page stops early, and stops
# here rather than on a board it silently reads half of.
JIRA_PAGES = {
    None:    (['ACME-1', 'ACME-2'], 'tok-2'),
    'tok-2': ([],                   'tok-3'),
    'tok-3': (['ACME-3'],           None),
}

# ---- gitlab and gerrit, in the shapes their references print ---------------
GITLAB_ISSUES = [
    # `assignee` is deprecated in favour of `assignees` and still returned, so
    # both are here: dropping the old one would be this file deciding an API
    # question on GitLab's behalf.
    {'iid': 7, 'title': 'rate limit in `a`', 'state': 'opened', 'description': '',
     'web_url': 'http://x/gl/7', 'labels': ['agent-ready'],
     'assignee': {'username': 'ana'}, 'assignees': [{'username': 'ana'}]},
    {'iid': 8, 'title': 'docs', 'state': 'closed', 'description': '',
     'web_url': 'http://x/gl/8', 'labels': [], 'assignee': None, 'assignees': []},
]
GERRIT_CHANGES = [
    {'_number': 7, 'subject': 'rate limit in `a`', 'status': 'NEW',
     'project': 'acme/api', 'hashtags': [], 'owner': {'name': 'Ana'}},
    {'_number': 8, 'subject': 'docs', 'status': 'MERGED',
     'project': 'acme/api', 'hashtags': [], 'owner': {'name': 'Ana'}},
]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _raw(self, text, code=200):
        body = text.encode()
        self.send_response(code); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def _send(self, obj, code=200):
        self._raw(json.dumps(obj), code)

    def _body(self):
        n = int(self.headers.get('Content-Length',0))
        raw = self.rfile.read(n).decode()
        return json.loads(raw or '{}')

    def _route(self):
        parts = urllib.parse.urlsplit(self.path)
        return parts.path, urllib.parse.parse_qs(parts.query)

    def _one(self, query, name, default=None):
        return (query.get(name) or [default])[0]

    def _unauth(self, scheme):
        """True, and a 401 already sent, if this request did not bring `scheme`."""
        header = 'PRIVATE-TOKEN' if scheme == 'private' else 'Authorization'
        want = {'bearer': 'Bearer ', 'basic': 'Basic ', 'private': ''}[scheme]
        got = self.headers.get(header, '')
        if got.startswith(want) and got.strip():
            return False
        self._send({'errorMessages': ['Client must be authenticated to access this resource.']}, 401)
        return True

    # ------------------------------------------------------------------ jira
    def _jira_page(self, query):
        if self._unauth('basic'):     # jira cloud takes email + api token as Basic
            return
        jql = (self._one(query, 'jql', '') or '').strip()
        if not jql:
            # An unbounded query is refused rather than answered with the site.
            self._send({'errorMessages': ["The 'jql' parameter is required and must be bounded."]}, 400)
            return
        asked = [f for f in (self._one(query, 'fields', '') or '').split(',') if f]
        unknown = [f for f in asked if f not in ('summary', 'status', 'assignee', 'labels')]
        if unknown:
            self._send({'errorMessages': [f"Field '{unknown[0]}' does not exist or "
                                          "you do not have permission to view it."]}, 400)
            return
        token = self._one(query, 'nextPageToken')

        # A board larger than any ceiling: every page hands out another token,
        # which is what a real one does until the last of them. Nothing here
        # implements JQL — only the parts of the contract that shape a request
        # and a response.
        if 'ENDLESS' in jql:
            n = int(token or 0)
            issue = {'id': str(20000 + n), 'key': f'ACME-{n + 1}',
                     'fields': {k: {'summary': f'endless {n + 1}',
                                    'status': {'statusCategory': {'key': 'new'}},
                                    'assignee': None, 'labels': []}[k] for k in asked}}
            self._send({'issues': [issue], 'nextPageToken': str(n + 1), 'isLast': False})
            return

        if token not in JIRA_PAGES:
            self._send({'errorMessages': ['The nextPageToken is invalid or has expired.']}, 400)
            return
        keys, nxt = JIRA_PAGES[token]
        # Only what `fields` asked for. Issue ids are the default and the whole
        # of it: the navigable set the old endpoint returned is gone.
        page = {'issues': [{'id': str(10000 + i), 'key': k,
                            'fields': {f: JIRA_ISSUES[k][f] for f in asked}}
                           for i, k in enumerate(keys)],
                'isLast': nxt is None}
        if nxt:
            page['nextPageToken'] = nxt      # absent on the last page, not empty
        self._send(page)

    # ---------------------------------------------------------------- routes
    def do_GET(self):
        path, query = self._route()

        if path == '/api/v4/users':
            # GitLab's user look-up answers about the instance, not the project.
            name = self._one(query, 'username', '')
            self._send([{'id': GITLAB_USERS[name], 'username': name}] if name in GITLAB_USERS else [])
            return

        if path.startswith('/api/v4/projects/') and path.endswith('/issues'):
            if self._unauth('private'):
                return
            state = self._one(query, 'state', 'all')
            self._send([i for i in GITLAB_ISSUES
                        if state == 'all' or i['state'] == state][:int(self._one(query, 'per_page', '20'))])
            return

        if path == '/rest/api/3/search':
            self._send({'errorMessages': [JIRA_REMOVED]}, 410)
            return

        if path == '/rest/api/3/search/jql':
            self._jira_page(query)
            return

        if path in ('/a/changes/', '/changes/'):
            if self._unauth('basic'):
                return
            limit = int(self._one(query, 'n', '25'))
            opts = query.get('o') or []
            out = []
            for change in GERRIT_CHANGES[:limit]:
                item = dict(change)
                if 'DETAILED_ACCOUNTS' in opts:
                    # What the option documents it adds. `name` is in the plain
                    # account reference and is there either way.
                    item['owner'] = dict(item['owner'], _account_id=1000, username='ana',
                                         email='ana@example.invalid')
                out.append(item)
            if len(GERRIT_CHANGES) > limit:
                out[-1]['_more_changes'] = True    # gerrit's own "there are more"
            self._raw(")]}'\n" + json.dumps(out))
            return

        if path == '/search/issues':
            if self._unauth('bearer'):
                return
            if not self._one(query, 'q'):
                self._send({'message': 'Validation Failed'}, 422)
                return
            self._send({'total_count': 2, 'incomplete_results': False, 'items': [
              {'number':7,'title':'rate limit in `a`','state':'open','labels':[{'name':'agent-ready'}],
               'assignee':None,'html_url':'http://x/7','body':''},
              {'number':8,'title':'docs','state':'closed','labels':[],'assignee':{'login':'ana'},
               'html_url':'http://x/8','body':''}]})
            return

        self._send({'message': f'no endpoint {path}'}, 404)

    def do_POST(self):
        body = self._body()
        if self.path.endswith('/assignees'):
            if '/mute/' in self.path:
                self._send({'number':7}, 201)   # 201, and no account of what it did
                return
            kept = [w.lower() for w in body.get('assignees',[]) if w.lower() in GITHUB_ASSIGNABLE]
            self._send({'number':7,'assignees':[{'login':w} for w in kept]}, 201)
            return
        if self.path.endswith('/hashtags'):
            kept = [t for t in body.get('add',[]) if t in GERRIT_TAGS]
            self._raw(")]}'\n" + json.dumps(kept))
            return
        if self.path.endswith('/silent/issues'):
            self._send({})           # a create that names nothing it made
            return
        if self.path.endswith('/issues'):
            CREATED.append(json.dumps(body))
            self._send({'html_url':'http://x/9','number':9})
            return
        self._send({'message': f'no endpoint {self.path}'}, 404)

    def do_PUT(self):
        body = self._body()
        if self.path.startswith('/api/v4/projects/'):
            kept = [i for i in body.get('assignee_ids',[]) if i in GITLAB_MEMBERS]
            self._send({'iid':7,'assignees':[{'id':i,'username':GITLAB_MEMBERS[i]} for i in kept]})
            return
        if self.path.endswith('/assignee'):
            # Jira validates the accountId and refuses; it never drops one quietly.
            if body.get('accountId') in JIRA_ACCOUNTS:
                self.send_response(204); self.end_headers()
            else:
                self._send({'errorMessages':[],'errors':{'accountId':'not a valid user'}}, 400)
            return
        self._send({'message': f'no endpoint {self.path}'}, 404)


# Port 0: the kernel hands out one that is free and the line below says which,
# so a second copy of this suite — another worktree, a second terminal, two jobs
# on one runner — is not a second bid for the same number. Serving in this
# thread rather than a daemon one behind a sleep: the shell kills the process
# when the section ends, which is a fact, where a duration was a guess about how
# long the rest of the suite takes.
s = HTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY

# `&` throws away the child's exit status, so a bind that raised looks exactly
# like a bind that worked and the first sign of it is a refused connection in a
# check three hundred lines below that is about trackers. Nothing here waits on
# a clock: the stand-in reports the port it got, and no port is a launch that
# failed, with the process's own stderr saying why.
stub_port() {   # <pid> <file its stdout went to> — the port it printed, or nothing
  local pid="$1" f="$2" p=""
  for _ in $(seq 1 100); do
    p="$(head -1 "$f" 2>/dev/null)"
    case "$p" in ''|*[!0-9]*) p="" ;; *) break ;; esac
    kill -0 "$pid" 2>/dev/null || break    # gone, and it will print nothing now
    sleep 0.1
  done
  printf '%s' "$p"
}

python3 "$WS/fake.py" > "$WS/fake.port" 2> "$WS/fake.err" & FAKE=$!
FAKE_PORT="$(stub_port "$FAKE" "$WS/fake.port")"
if [ -z "$FAKE_PORT" ]; then
  bad "the tracker stand-in starts" "$(tail -1 "$WS/fake.err" 2>/dev/null)"
  printf '       every tracker check below reads it; stopping here rather than\n'
  printf '       reporting a refused connection for each of them\n'
  printf '\n\033[31m%d failure(s) in %d checks — stopped at the tracker stand-in\033[0m\n' \
    "$fail" "$((pass + fail))"
  exit 1
fi

# What the fixed port cost, checked rather than remembered: a second stand-in,
# started while the first is serving, gets a port of its own and both answer.
python3 "$WS/fake.py" > "$WS/fake2.port" 2> "$WS/fake2.err" & FAKE2=$!
PORT2="$(stub_port "$FAKE2" "$WS/fake2.port")"
both="$(python3 - "$FAKE_PORT" "${PORT2:-0}" <<'PY' || true
import sys, urllib.request
codes = []
for port in sys.argv[1:]:
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/v4/users?username=ana", timeout=2) as r:
            codes.append(str(r.status))
    except Exception as exc:                 # the refused connection, named here
        codes.append(repr(exc))
print(",".join(codes))
PY
)"
kill $FAKE2 2>/dev/null || true
if [ -n "$PORT2" ] && [ "$PORT2" != "$FAKE_PORT" ] && [ "$both" = "200,200" ]; then
  ok "two stand-ins run side by side, each on a port of its own"
else
  bad "two stand-ins run side by side, each on a port of its own" \
    "first=$FAKE_PORT second=${PORT2:-none} answers=$both"
fi

# The other half of the rule, on a stub that cannot start: the launch reports
# it, and reports what the process said. Nothing downstream meets it as a
# refused connection.
printf 'raise OSError(98, "Address already in use")\n' > "$WS/fake-broken.py"
python3 "$WS/fake-broken.py" > "$WS/broken.port" 2> "$WS/broken.err" & BROKEN=$!
broke="$(stub_port "$BROKEN" "$WS/broken.port")"
if [ -z "$broke" ] && grep -q "Address already in use" "$WS/broken.err"; then
  ok "a stand-in that cannot start reports no port, and its own error says why"
else
  bad "a stand-in that cannot start reports no port, and its own error says why" \
    "port=${broke:-none} err=$(tail -1 "$WS/broken.err" 2>/dev/null)"
fi

python3 - "$WS/.deck/workspace.yaml" "$FAKE_PORT" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"},
                {"type": "github", "repo": "acme/api",
                 "api": f"http://127.0.0.1:{sys.argv[2]}"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "whoami reports a missing token"  "missing"  "$DECK" board whoami
check "whoami never prints the token"   "token"    env DECK_TOKEN_GITHUB=smoke-token "$DECK" board whoami
if env DECK_TOKEN_GITHUB=smoke-token "$DECK" board whoami | grep -q "smoke-token"; then
  bad "whoami never prints the token"
else
  ok "whoami never prints the token value"
fi
check "an unreachable tracker is reported, not fatal" "T-1" "$DECK" board list

check "a task is created locally"  "created"  "$DECK" board new "new thing" --repos a --id T-9 --yes
check "the new task is listed"     "T-9"      "$DECK" board list
check "claiming records the owner" "claimed"  "$DECK" board claim T-9 ana --yes
if "$DECK" board show T-9 | grep -q "claimed   ana"; then
  ok "show reports who holds it"
else
  bad "show reports who holds it"
fi
taken="$("$DECK" board claim T-9 bob 2>&1 || true)"
if printf '%s' "$taken" | grep -q "already claimed by ana"; then
  ok "a task held by someone else is refused"
else
  bad "a task held by someone else is refused" "$taken"
fi
guard="$("$DECK" board new "unconfirmed" --id T-10 2>&1 || true)"
if printf '%s' "$guard" | grep -q "Re-run with --yes"; then
  ok "a tracker write without --yes is refused"
else
  bad "a tracker write without --yes is refused" "$guard"
fi
check_fail "board new refuses an unknown repository" "$DECK" board new "x" --repos nope --yes

# Closing a task is a claim about verification, so it needs the record.
check_fail "closing a task with no gate record is refused" "$DECK" board done T-9 --yes
out="$("$DECK" board done T-9 --yes 2>&1)"
if printf '%s' "$out" | grep -q "deck gate run --task T-9"; then ok "and it names the command that fixes it"; else bad "and it names the command that fixes it" "$out"; fi
check "--force closes it deliberately" "closed T-9" "$DECK" board done T-9 --force --yes
check "a closed task stays closed" "already done" "$DECK" board done T-9 --yes

# ---- external identity: one piece of work, two systems.
# The stand-in serves issue #7. A local entry claiming github:#7 is the same
# work, and carries what no tracker has a field for: which repositories it
# touches.
check "a task records where it lives elsewhere" "created" \
  "$DECK" board new "rate limit" --id T-11 --repos a --ext github:#7 --yes
export DECK_TOKEN_GITHUB=smoke-token
out="$("$DECK" board list 2>&1)"
if [ "$(printf '%s' "$out" | grep -c 'rate limit')" = 1 ]; then
  ok "a linked task appears once, not twice"
else bad "a linked task appears once, not twice" "$out"; fi
shown="$("$DECK" board show T-11 2>&1)"
if printf '%s' "$shown" | grep -q "reconciled with the local entry"; then
  ok "show says the two were reconciled"
else bad "show says the two were reconciled" "$shown"; fi
if printf '%s' "$shown" | grep -q "http://x/7"; then
  ok "the tracker supplies the live url"
else bad "the tracker supplies the live url" "$shown"; fi
if printf '%s' "$shown" | grep -qE "repos +a"; then
  ok "the local entry supplies the repositories"
else bad "the local entry supplies the repositories" "$shown"; fi
check "an unfetchable provider is still recorded" "linear:ENG-88" \
  sh -c "'$DECK' board new 'design review' --id T-12 --ext linear:ENG-88 --yes >/dev/null && '$DECK' board show T-12"
check_fail "--ext without an id is refused" "$DECK" board new "x" --id T-13 --ext jira --yes
unset DECK_TOKEN_GITHUB

note "doctor and the backlog sources"
# A tracker source has no `file:` and never will. Checking every source as if it
# did accused a healthy board of a missing file and printed the value it never
# had as `None`. A workspace of its own, with `targets: []`, so `--net` below
# reaches the stand-in on loopback and nothing else.
DW="$(mktemp -d)"; mkdir -p "$DW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$DW/.deck/toggles.yaml"
printf 'tasks:\n  - { id: L-1, title: a local board }\n' > "$DW/board-here.yaml"
cat > "$DW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$FAKE_PORT" }
  - { type: github }
  - { type: tasks, file: board-here.yaml }
  - { type: tasks, file: board-gone.yaml }
YAML
# Captured, not piped: doctor exits non-zero the moment this descriptor grows a
# problem, and `set -o pipefail` would then fail the grep that read it fine.
dw="$(env DECK_ROOT="$DW" "$DECK" doctor 2>&1 || true)"

if printf '%s' "$dw" | grep -q "None"; then
  bad "doctor prints no value that was never set" "$(printf '%s' "$dw" | grep -n "None" | head -2)"
else
  ok "doctor prints no value that was never set"
fi
if printf '%s' "$dw" | grep -qF "OK github  acme/api"; then
  ok "a tracker source with the keys its kind needs is OK"
else
  bad "a tracker source with the keys its kind needs is OK" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
if printf '%s' "$dw" | grep -qF 'github source needs `repo: owner/name`'; then
  ok "a tracker source missing a key is reported, naming the key"
else
  bad "a tracker source missing a key is reported, naming the key" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
if printf '%s' "$dw" | grep -qF "(use --net to check it answers)"; then
  ok "and whether it answers is left to --net, as it is for a target"
else
  bad "and whether it answers is left to --net, as it is for a target" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
# Regression guards: a file source is checked exactly as it was before.
if printf '%s' "$dw" | grep -qE "OK tasks .*board-here\.yaml"; then
  ok "a file source that exists is still OK"
else
  bad "a file source that exists is still OK" "$(printf '%s' "$dw" | grep -i tasks | head -2)"
fi
if printf '%s' "$dw" | grep -qF "missing: board-gone.yaml"; then
  ok "a file source whose file is gone is still reported"
else
  bad "a file source whose file is gone is still reported" "$(printf '%s' "$dw" | grep -i tasks | head -2)"
fi

# --net, against the same loopback stand-in the provider checks above use.
net="$(env DECK_TOKEN_GITHUB=smoke-token DECK_ROOT="$DW" "$DECK" doctor --net 2>&1 || true)"
if printf '%s' "$net" | grep -qF "2 task(s)"; then
  ok "--net reads the tracker board and says what is on it"
else
  bad "--net reads the tracker board and says what is on it" "$(printf '%s' "$net" | grep -i github | head -2)"
fi
net0="$(env DECK_ROOT="$DW" "$DECK" doctor --net 2>&1 || true)"
if printf '%s' "$net0" | grep -q "401"; then
  ok "--net reports a tracker that refuses the credentials"
else
  bad "--net reports a tracker that refuses the credentials" "$(printf '%s' "$net0" | grep -i github | head -2)"
fi

# The requirement is stated once. Two copies of "github needs repo" drift, and
# then the diagnosis is wrong about the code sitting next to it.
drift="$(cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
src = {'type': 'github'}
want = trackers.missing_requirement(src)
try:
    trackers.fetch(src, [])          # raises before any request is built
except trackers.TrackerError as exc:
    print('same' if str(exc) == want else f'drifted: {exc!r} != {want!r}')
else:
    print('fetch accepted a github source with no repo')
" 2>&1)"
if [ "$drift" = "same" ]; then
  ok "doctor and the fetcher read one statement of what a kind requires"
else
  bad "doctor and the fetcher read one statement of what a kind requires" "$drift"
fi
# The write path used to reach `source['repo']` and raise KeyError at a user.
wrote="$(cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
try:
    trackers.claim({'type': 'github'}, '#1', 'ana')
except trackers.TrackerError as exc:
    print(exc)
" 2>&1)"
if printf '%s' "$wrote" | grep -qF 'needs `repo: owner/name`'; then
  ok "claiming on a source missing its key says which key, not KeyError"
else
  bad "claiming on a source missing its key says which key, not KeyError" "$wrote"
fi
rm -rf "$DW"

# ---- a task somebody holds does not look like one nobody holds
# deck has three states and a GitHub issue has two, so `in-progress` never came
# back and every tracked task rendered `[ ]`. The assignee was read the whole
# time — `_task` carries it — and thrown away at the render, so a board with
# four claimed issues told the next person all four were free.
#
# deck does not guess. Reading "assigned" as "in progress" is wrong for every
# team that assigns before starting, so the source says how its board writes it
# down, and a source that says nothing is a source that cannot express it.
note "a claimed task is visibly claimed"
IP="$(mktemp -d)"; mkdir -p "$IP/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$IP/.deck/toggles.yaml"
# Its own stand-in. The shared one serves two issues and a check asserts that
# count, and neither of the two is open *and* assigned — which is the one shape
# this group is about. Borrowing it would have meant testing a case the fixture
# cannot produce, which is how the first draft of these checks passed for the
# wrong reason.
python3 - "$IP/port" <<'PY' &
import http.server, json, pathlib, sys, threading
ISSUES = [
    {"number": 11, "title": "held and open", "state": "open", "labels": [{"name": "wip"}],
     "assignee": {"login": "ana"}, "html_url": "http://x/11", "body": ""},
    {"number": 12, "title": "free and open", "state": "open", "labels": [],
     "assignee": None, "html_url": "http://x/12", "body": ""},
    {"number": 13, "title": "assigned and closed", "state": "closed", "labels": [],
     "assignee": {"login": "bob"}, "html_url": "http://x/13", "body": ""},
]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if not self.path.startswith("/search/issues"):
            body = json.dumps({"message": f"no endpoint {self.path}"}).encode(); code = 404
        else:
            body = json.dumps({"total_count": len(ISSUES), "items": ISSUES}).encode(); code = 200
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
pathlib.Path(sys.argv[1]).write_text(str(srv.server_port))
srv.serve_forever()
PY
IP_PID=$!
for _ in $(seq 1 50); do [ -s "$IP/port" ] && break; sleep 0.1; done
IP_PORT="$(cat "$IP/port" 2>/dev/null)"
if [ -z "$IP_PORT" ]; then bad "the in-progress stand-in came up" "no port file"; fi
ip_source() {  # <extra keys, or empty>
  cat > "$IP/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$IP_PORT"${1:+, $1} }
YAML
}
ip() { env DECK_ROOT="$IP" DECK_TOKEN_GITHUB=smoke-token "$DECK" "$@"; }

ip_source ""
und="$(ip board list 2>&1 || true)"
if printf '%s' "$und" | grep -q 'held by ana'; then
  ok "the assignee deck already reads is printed, whatever the source can express"
else bad "the assignee deck already reads is printed, whatever the source can express" "$und"; fi
if printf '%s' "$und" | grep -q 'two states, so'; then
  ok "and a source that cannot say a task is taken says so, once"
else bad "and a source that cannot say a task is taken says so, once" "$und"; fi
if printf '%s' "$und" | grep -q 'in_progress: assignee'; then
  ok "and names how to say it, so the note is actionable"
else bad "and names how to say it, so the note is actionable" "$und"; fi
# Undeclared, an assigned task is still `[ ]`: deck will not read an assignee as
# a state the board never claimed to express.
if printf '%s' "$und" | grep -qE '^  \[~\]'; then
  bad "an undeclared source does not gain a state deck invented for it" "$und"
else ok "an undeclared source does not gain a state deck invented for it"; fi

ip_source 'in_progress: assignee'
dec="$(ip board list 2>&1 || true)"
if printf '%s' "$dec" | grep -qE '^  \[~\].*docs|^  \[~\]'; then
  ok "a source that says assigned means taken marks the task taken"
else bad "a source that says assigned means taken marks the task taken" "$dec"; fi
if printf '%s' "$dec" | grep -q 'two states, so'; then
  bad "and the note goes away, having been answered" "$dec"
else ok "and the note goes away, having been answered"; fi

# A label is the other way a board writes it down, and it is not the assignee:
# a task can be labelled without being assigned, and that is somebody's system.
ip_source 'in_progress: "label:wip"'
lab="$(ip board list 2>&1 || true)"
if printf '%s' "$lab" | grep -qE '^  \[~\]'; then
  ok "a label the source names is read as taken too"
else bad "a label the source names is read as taken too" "$lab"; fi
ip_source 'in_progress: "label:nobody-uses-this"'
nolab="$(ip board list 2>&1 || true)"
if printf '%s' "$nolab" | grep -qE '^  \[~\]'; then
  bad "and a label nothing carries marks nothing" "$nolab"
else ok "and a label nothing carries marks nothing"; fi
# Closed stays closed. A held task and a finished one are different answers.
if printf '%s' "$dec" | grep -qE '^  \[x\]'; then
  ok "a closed task is still closed, whatever the source says about taken"
else bad "a closed task is still closed, whatever the source says about taken" "$dec"; fi
# `$!`, never `%1`. A job number is the shell's, not this group's, and the
# first draft of this killed the shared stand-in every other tracker check
# depends on — twenty-five reds in groups that had nothing to do with it.
kill "$IP_PID" 2>/dev/null || true
rm -rf "$IP"

note "a tracker write reports what the tracker recorded"
# GitHub answers 201 and an issue object for an assignment it is about to
# discard, so the status line says nothing about what happened and the only
# account of it is the body. deck printed the name it had *asked* for, which is
# the one thing that is never evidence.
TW="$(mktemp -d)"; mkdir -p "$TW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$TW/.deck/toggles.yaml"
cat > "$TW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$FAKE_PORT" }
YAML
tclaim() { env DECK_ROOT="$TW" DECK_TOKEN_GITHUB=smoke-token "$DECK" board claim "$@"; }

# One provider call per process, so an import error fails its own check and not
# the group. `claim` and `create` raise, and the error is printed rather than
# re-raised so the message itself is what the check reads.
trk() { (cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
try:
    print(trackers.$1)
except trackers.TrackerError as exc:
    print(f'error: {exc}')
" 2>&1); }

check "a claim github took reports it" "assigned #7 to ana on github" tclaim "#7" ana --yes
# The sharp form of the same rule: github records the canonical login, so what
# is printed has to come back from the response and not from the request.
check "and the login github recorded, not the one that was asked for" \
  "assigned #7 to ana on github" tclaim "#7" ANA --yes

# The failure this suite exists for: 201, an empty `assignees`, nobody assigned.
dropped="$(tclaim "#7" nemo --yes 2>&1 || true)"
if printf '%s' "$dropped" | grep -qF "assigned #7 to nemo"; then
  bad "a claim github dropped is never reported as assigned" "$dropped"
else
  ok "a claim github dropped is never reported as assigned"
fi
if printf '%s' "$dropped" | grep -qF "github did not assign nemo to #7"; then
  ok "and the error names the name the tracker refused"
else
  bad "and the error names the name the tracker refused" "$dropped"
fi
if printf '%s' "$dropped" | grep -qF "it recorded nobody"; then
  ok "and says what the tracker recorded in its place"
else
  bad "and says what the tracker recorded in its place" "$dropped"
fi
check_fail "and the claim exits non-zero" tclaim "#7" nemo --yes

# A response with no assignee field at all is deck not knowing, which is a third
# answer and not a quiet success.
mute="$(trk "claim({'type':'github','repo':'acme/mute','api':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ana')")"
if printf '%s' "$mute" | grep -qF "did not say who it assigned"; then
  ok "a write whose response says nothing is reported, not assumed"
else
  bad "a write whose response says nothing is reported, not assumed" "$mute"
fi

# gitlab: the look-up-first it already had is kept — it names an unknown account
# before anything is written, which no read-back can do.
check "gitlab still refuses a name the instance does not know" "no gitlab user named nobody" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'nobody')"
check "and still reports a claim it made" "assigned #7 to ana on gitlab" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ana')"
# What the look-up cannot see: `ghost` exists on the instance and has no access
# to this project, so GitLab answers 200 and an issue that never gained them.
check "gitlab catches an account the project silently would not take" \
  "gitlab did not assign ghost to #7" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ghost')"

# gerrit answers the hashtag POST with the set the change holds afterwards.
check "gerrit reports a hashtag it recorded" "claimed by ana on gerrit" \
  trk "claim({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, '7', 'ana')"
check "and a hashtag it did not record is an error naming it" \
  "gerrit did not record \`claimed-by-ghost\`" \
  trk "claim({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, '7', 'ghost')"

# jira needs no read-back: the assignee endpoint replaces one value and refuses
# an accountId it will not take, so a rejected name is already an error. Both
# checks are guards on that staying true.
check "jira reports an assignment it accepted" "assigned PAY-1 to acct-ana on jira" \
  trk "claim({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT'}, 'PAY-1', 'acct-ana')"
check "and an accountId jira refuses is an error, not a claim" "error: 400" \
  trk "claim({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT'}, 'PAY-1', 'nemo')"

# create had the same silence in a quieter form: `payload.get(field, "created")`
# printed a word that reads like success for a response that named nothing.
check "a created issue is reported by the url the tracker gave it" "http://x/9" \
  trk "create({'type':'github','repo':'acme/api','api':'http://127.0.0.1:$FAKE_PORT'}, 'a thing')"
check "and a create that names nothing is reported, not called created" \
  "without naming the task it made" \
  trk "create({'type':'github','repo':'acme/silent','api':'http://127.0.0.1:$FAKE_PORT'}, 'a thing')"
rm -rf "$TW"

note "the jira reader, against what the API documents"
# `/rest/api/3/search` is removed, not deprecated: Jira Cloud answers it 410 and
# names `/rest/api/3/search/jql` in the body (CHANGE-2046). Every check below
# reads the stand-in, which now refuses the old path the way Cloud does — and
# that refusal is the one this file could not hold while it was written from
# what deck sends, because then it answered whatever deck asked for.
gone="$(python3 - "$FAKE_PORT" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/rest/api/3/search?jql=x", timeout=5) as r:
        print("answered", r.status)
except urllib.error.HTTPError as exc:
    print(exc.code, exc.read().decode()[:240])
except Exception as exc:
    print(repr(exc))
PY
)"
if printf '%s' "$gone" | grep -q "^410 " && printf '%s' "$gone" | grep -qF "/rest/api/3/search/jql"; then
  ok "the stand-in answers the removed search endpoint 410, naming its replacement"
else
  bad "the stand-in answers the removed search endpoint 410, naming its replacement" "$gone"
fi

# The rule that keeps the other routes honest: a path no reference documents is
# a 404. A reader that invents one fails here instead of on an instance.
nowhere="$(python3 - "$FAKE_PORT" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/rest/api/3/invented", timeout=5) as r:
        print("answered", r.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception as exc:
    print(repr(exc))
PY
)"
if [ "$nowhere" = "404" ]; then
  ok "and a path no reference documents is a 404, not whatever the caller wanted"
else
  bad "and a path no reference documents is a 404, not whatever the caller wanted" "$nowhere"
fi

# One reader per process, as above. Both return values are printed: the tasks,
# and what the read could not reach.
rdr() { (cd "$REPO/plugins/deck" && env DECK_TOKEN_JIRA=smoke-token DECK_USER_JIRA=ana \
  DECK_TOKEN_GITLAB=smoke-token DECK_TOKEN_GERRIT=smoke-token DECK_USER_GERRIT=ana python3 -c "
from deck import trackers
try:
    tasks, notes = trackers.$1
    for t in tasks:
        print('task', t['id'], t['title'], t['status'], t['assignee'], ','.join(t['labels']), sep=' | ')
    for n in notes:
        print('note', n)
except trackers.TrackerError as exc:
    print('error:', exc)
" 2>&1); }

jira="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT','project':'ACME'}, ['a','b','c'])")"
if [ "$(printf '%s\n' "$jira" | grep -c '^task ')" = 3 ]; then
  ok "the jira reader reads a board through the endpoint that replaced it"
else
  bad "the jira reader reads a board through the endpoint that replaced it" "$jira"
fi
# The middle page is empty and still carries a token. Stopping there loses
# ACME-3, and with no `total` in the response nothing else would notice.
if printf '%s' "$jira" | grep -qF "task | ACME-3"; then
  ok "and follows nextPageToken past a page that came back empty"
else
  bad "and follows nextPageToken past a page that came back empty" "$jira"
fi
# The endpoint returns issue ids and nothing else unless `fields` asks. Drop the
# parameter and this is a board of blank titles rather than an error.
if printf '%s' "$jira" | grep -qF "task | ACME-1 | rate limit in \`a\` | open | Ana | agent-ready"; then
  ok "and asks for every field it goes on to read"
else
  bad "and asks for every field it goes on to read" "$jira"
fi
if printf '%s' "$jira" | grep -qF "task | ACME-2 | retry budget in \`b\` | done"; then
  ok "and reads the status category, not the status name"
else
  bad "and reads the status category, not the status name" "$jira"
fi

# A board with more pages than the ceiling. Paging until the token runs out is
# the read deck wants — with `total` gone there is nothing else to compare a
# short board against — and the ceiling is where it stops asking, which is a
# fact the operator gets rather than a board quietly missing its tail.
endless="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT','jql':'project = ENDLESS'}, [])")"
if printf '%s' "$endless" | grep -qF "note this board is partial"; then
  ok "a read that stopped short says so, in the first words"
else
  bad "a read that stopped short says so, in the first words" "$(printf '%s' "$endless" | tail -2)"
fi
if printf '%s' "$endless" | grep -qF "Narrow it with a \`jql:\`"; then
  ok "and names what the operator does about it"
else
  bad "and names what the operator does about it" "$(printf '%s' "$endless" | tail -2)"
fi

# A source with neither `project:` nor `jql:` used to build `project =  AND ...`
# and send it. The new endpoint refuses an unbounded query with a 400, so deck
# refuses it first, offline, and says which key is missing.
JW="$(mktemp -d)"; mkdir -p "$JW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$JW/.deck/toggles.yaml"
cat > "$JW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: jira, url: "http://127.0.0.1:$FAKE_PORT", jql: "project = ENDLESS" }
  - { type: jira, url: "http://127.0.0.1:1" }
YAML
# Port 1 on loopback, not a hostname: if this guard ever stops holding, the
# request it wrongly makes is refused in a millisecond and still touches
# nothing outside this machine.
noquery="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:1'}, [])")"
if printf '%s' "$noquery" | grep -qF 'jira source needs `project: ACME` or a `jql:`'; then
  ok "a jira source with no project and no jql is refused before any request"
else
  bad "a jira source with no project and no jql is refused before any request" "$noquery"
fi
jdoc="$(env DECK_ROOT="$JW" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$jdoc" | grep -qF 'jira source needs `project: ACME` or a `jql:`'; then
  ok "and doctor reports it from the same statement, without a request either"
else
  bad "and doctor reports it from the same statement, without a request either" "$(printf '%s' "$jdoc" | grep -i jira | head -2)"
fi
jlist="$(env DECK_ROOT="$JW" DECK_TOKEN_JIRA=smoke-token DECK_USER_JIRA=ana "$DECK" board list 2>&1 || true)"
if printf '%s' "$jlist" | grep -qF "! jira: this board is partial"; then
  ok "and board list prints a partial read beside the tasks it did get"
else
  bad "and board list prints a partial read beside the tasks it did get" "$(printf '%s' "$jlist" | tail -3)"
fi
rm -rf "$JW"

# gitlab and gerrit, checked for the same drift: both endpoints are current, and
# these are the first checks that read either of them at all. Until now the
# stand-in had no route for them and only the write paths were exercised.
gl="$(rdr "fetch_gitlab({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, ['a'])")"
if printf '%s' "$gl" | grep -qF "task | #7 | rate limit in \`a\` | open | ana | agent-ready"; then
  ok "the gitlab reader reads issues from the endpoint the reference documents"
else
  bad "the gitlab reader reads issues from the endpoint the reference documents" "$gl"
fi
ge="$(rdr "fetch_gerrit({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, ['api'])")"
if printf '%s' "$ge" | grep -qF "task | 7 | rate limit in \`a\` | open | Ana"; then
  ok "the gerrit reader reads changes from the endpoint the reference documents"
else
  bad "the gerrit reader reads changes from the endpoint the reference documents" "$ge"
fi

kill $FAKE 2>/dev/null || true

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
if [ -f "$SW/.deck/workspace.yaml" ]; then ok "setup writes the descriptor"; else bad "setup writes the descriptor"; fi
if [ -f "$SP/proj1/config/toggles.yaml" ]; then ok "a pack is created per repository"; else bad "a pack is created per repository"; fi

# the convention: a pack directory named after a repository is its pack, one or
# two levels deep, and a shared pack applies to all
rm -rf "$SP/proj2"; "$DECK" pack new proj2 --dir "$SP/group1/proj2" >/dev/null
"$DECK" pack new shared --dir "$SP/_workspace" >/dev/null
linked="$(cd "$SW" && "$DECK" setup --root "$SW" --packs-root "$SP" --force 2>&1 || true)"
if printf '%s' "$linked" | grep -q "linked   proj1"; then ok "a top-level pack is linked by name"; else bad "a top-level pack is linked by name"; fi
if printf '%s' "$linked" | grep -q "group1/proj2"; then ok "a nested pack is linked by name"; else bad "a nested pack is linked by name" "$linked"; fi
if printf '%s' "$linked" | grep -q "shared   (every repository)"; then ok "a _workspace pack applies to all"; else bad "a _workspace pack applies to all"; fi

rm -rf "$SP/proj3-dup"; "$DECK" pack new proj3 --dir "$SP/group2/proj3" >/dev/null
dup="$(cd "$SW" && "$DECK" setup --root "$SW" --packs-root "$SP" --force 2>&1 || true)"
if printf '%s' "$dup" | grep -qE "two packs claim|linked   proj3"; then
  ok "a duplicate name is resolved or reported, never guessed"
else
  bad "a duplicate name is handled"
fi
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
python3 - "$PACK/config/mount.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text() + "  - { file: rules/orphan.md }\n")
PY
check "a rule that can reach no file is reported" "never loads" "$DECK" pack review
python3 - "$PACK/config/mount.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("  - { file: rules/orphan.md }\n", ""))
PY
rm -f "$PACK/rules/orphan.md"

# ---- consultations: the question the catalog has no entry for
note "consultations"
out="$("$DECK" ask new "Should regional tags resolve to the base language?" --task T-1 --options "strict,aliases" --context "First case where it matters." 2>&1)"
ID="$(printf '%s' "$out" | grep -oE '^recorded .*' | cut -d' ' -f2)"
if [ -n "$ID" ]; then ok "a question is written down"; else bad "a question is written down" "$out"; fi
check "and nothing waits on it" "Nothing waits on it" "$DECK" ask new "Another one" --task T-1
check "open ones are listed"   "regional tags"        "$DECK" ask list
check "resolving records the answer" "aliases, from the next release" "$DECK" ask resolve "$ID" "aliases, from the next release"
check "and says what it wants to become" "wants to become" "$DECK" ask resolve "$ID" "aliases, from the next release"
check "a resolved one is readable by the next run" "aliases, from the next release" "$DECK" ask list --resolved
check_fail "an unknown id is refused" "$DECK" ask resolve nope-nope "x"

# ---- a consultation that only one machine can see is one nobody can answer
# `.deck/` is machine state and is never versioned, so the loop deck built —
# an agent meets what it cannot decide, records it instead of guessing, a
# person answers, `ask fold` writes it into a pack — ran entirely inside one
# checkout until the last step. On a real workspace eight drafts filed
# twenty-seven questions and a colleague on the same initiative could not have
# seen one of them.
note "a question crosses to the people who can answer it"
CX="$(mktemp -d)"; CXP="$CX/shared"
mkdir -p "$CX/ana/.deck" "$CX/ana/app" "$CX/bob/.deck" "$CX/bob/app"
"$DECK" pack new team --dir "$CXP" >/dev/null 2>&1
for who in ana bob; do
  printf 'version: 1\nrepos: { app: { path: app } }\ntargets: []\n' > "$CX/$who/.deck/workspace.yaml"
  cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$CX/$who/.deck/toggles.yaml"
done
cx_ana() { env DECK_ROOT="$CX/ana" DECK_PACKS="$CXP" DECK_USER=ana "$DECK" "$@"; }
cx_bob() { env DECK_ROOT="$CX/bob" DECK_PACKS="$CXP" DECK_USER=bob "$DECK" "$@"; }

cx_ana ask new "Does the retry budget count per call or per request?" --options "call,request" >/dev/null 2>&1
CXID="$(cx_ana ask list 2>&1 | grep -oE '[0-9]{8}-[0-9]{6}-[a-z0-9-]+' | head -1)"
if [ -n "$CXID" ] && ! cx_bob ask list 2>&1 | grep -q "$CXID"; then
  ok "a consultation nobody published stays on the machine that raised it"
else bad "a consultation nobody published stays on the machine that raised it" "$(cx_bob ask list 2>&1)"; fi

cx_pub="$(cx_ana ask publish "$CXID" --into "$CXP" 2>&1 || true)"
if cx_bob ask list 2>&1 | grep -q "$CXID"; then
  ok "and a published one reaches a colleague reading the same pack"
else bad "and a published one reaches a colleague reading the same pack" "$cx_pub"; fi
# The directory name, which is how deck names a pack everywhere else — `deck
# doctor` prints the merge order by directory, not by what plugin.json calls it.
if cx_bob ask list 2>&1 | grep -q '(shared)'; then
  ok "which says where it came from, so a shared doubt is not read as a private one"
else bad "which says where it came from, so a shared doubt is not read as a private one" "$(cx_bob ask list 2>&1)"; fi
# A move, not a copy: two records of one question drift the moment either is
# answered, which is the failure the whole mechanism exists to prevent.
if [ "$(ls "$CX/ana/.deck/consultations"/*.json 2>/dev/null | wc -l)" = "0" ]; then
  ok "publishing moves it rather than leaving a second copy behind"
else bad "publishing moves it rather than leaving a second copy behind" "$(ls "$CX/ana/.deck/consultations")"; fi
if grep -q 'asked_in' "$CXP/consultations/$CXID.json"; then
  bad "and drops the session id, which names a machine and travels to nobody" "$(cat "$CXP/consultations/$CXID.json")"
else ok "and drops the session id, which names a machine and travels to nobody"; fi

# The half that matters most: the colleague answers, and the asker sees it.
cx_bob ask resolve "$CXID" "Per request. A retried call is one request." >/dev/null 2>&1
if cx_ana ask list --resolved 2>&1 | grep -q 'A retried call is one request'; then
  ok "an answer given on one machine is read on the other"
else bad "an answer given on one machine is read on the other" "$(cx_ana ask list --resolved 2>&1)"; fi
if cx_ana ask show "$CXID" 2>&1 | grep -q 'by bob'; then
  ok "and carries who gave it, so it can be asked about"
else bad "and carries who gave it, so it can be asked about" "$(cx_ana ask show "$CXID" 2>&1)"; fi
if grep -q 'A retried call is one request' "$CXP/consultations/$CXID.json"; then
  ok "the answer is written where the question is, not into the answerer's own store"
else bad "the answer is written where the question is, not into the answerer's own store" "$(cat "$CXP/consultations/$CXID.json")"; fi
# Publishing twice is a person's mistake, and it says so rather than moving a
# record that is no longer where it thinks it is.
again="$(cx_ana ask publish "$CXID" --into "$CXP" 2>&1 || true)"
if printf '%s' "$again" | grep -q 'already published'; then
  ok "publishing an already published one is refused, and names where it is"
else bad "publishing an already published one is refused, and names where it is" "$again"; fi
rm -rf "$CX"

# ---- an answer that stays a transcript is one the next run has to ask again
# `ask` recorded the question and the answer and named the artifact the answer
# looked like, and nothing folded it in. Twenty-seven answered consultations on
# a real workspace had an obvious home in a pack and no path to it.
FP="$WS/foldpack"
"$DECK" pack new folded --dir "$FP" >/dev/null
fold_out="$("$DECK" ask fold "$ID" --as rule --into "$FP" --paths "src/**" 2>&1 || true)"
if [ -f "$FP/rules/should-regional-tags-resolve-to-the-base.md" ]; then
  ok "an answered consultation becomes a rule in a named pack"
else bad "an answered consultation becomes a rule in a named pack" "$fold_out"; fi
if grep -q 'aliases, from the next release' "$FP/rules/should-regional-tags-resolve-to-the-base.md" 2>/dev/null; then
  ok "and the answer is what the rule says"
else bad "and the answer is what the rule says" "$(cat "$FP/rules/should-regional-tags-resolve-to-the-base.md" 2>/dev/null)"; fi
if grep -q "Folded from consultation $ID" "$FP/rules/should-regional-tags-resolve-to-the-base.md" 2>/dev/null; then
  ok "and it carries the consultation it came from, so the reasoning survives"
else bad "and it carries the consultation it came from, so the reasoning survives" "$(cat "$FP/rules/should-regional-tags-resolve-to-the-base.md" 2>/dev/null)"; fi
if grep -q 'Question: Should regional tags' "$FP/rules/should-regional-tags-resolve-to-the-base.md" 2>/dev/null; then
  ok "the question too, not only its id — a reader may not have the file"
else bad "the question too, not only its id — a reader may not have the file"; fi
# The other half of #53, reused: a rule nothing places is not delivered.
if grep -q 'file: rules/should-regional-tags-resolve-to-the-base.md' "$FP/config/mount.yaml"; then
  ok "and mount.yaml names it, so something places it"
else bad "and mount.yaml names it, so something places it" "$(grep '^  - ' "$FP/config/mount.yaml")"; fi
shown="$("$DECK" ask show "$ID" 2>&1 || true)"
if printf '%s' "$shown" | grep -q 'written down as:'; then
  ok "and the consultation says where its answer now lives"
else bad "and the consultation says where its answer now lives" "$shown"; fi
if printf '%s' "$shown" | grep -q 'probably wants to become'; then
  bad "and stops guessing what it wants to become, having become it" "$shown"
else ok "and stops guessing what it wants to become, having become it"; fi

# Folding twice writes two artifacts from one answer, which disagree the moment
# either is edited.
twice="$("$DECK" ask fold "$ID" --as rule --into "$FP" --paths "src/**" 2>&1 || true)"
if printf '%s' "$twice" | grep -q 'was already folded'; then
  ok "folding the same answer twice is refused, and says where it went"
else bad "folding the same answer twice is refused, and says where it went" "$twice"; fi

# What deck will not invent. Each is refused by name.
"$DECK" ask new "Is the retry budget per call or per request?" --options "call,request" >/dev/null 2>&1
UNANS="$("$DECK" ask list 2>&1 | grep -oE '[0-9]{8}-[0-9]{6}-is-the-retry[a-z0-9-]*' | head -1)"
noans="$("$DECK" ask fold "$UNANS" --as rule --into "$FP" --paths "src/**" 2>&1 || true)"
if printf '%s' "$noans" | grep -q 'has no answer yet'; then
  ok "an unanswered consultation is not folded — settlement it does not have"
else bad "an unanswered consultation is not folded — settlement it does not have" "$noans"; fi
"$DECK" ask resolve "$UNANS" "per call" >/dev/null 2>&1
nopaths="$("$DECK" ask fold "$UNANS" --as rule --into "$FP" 2>&1 || true)"
if printf '%s' "$nopaths" | grep -q 'a rule needs --paths'; then
  ok "a rule with no paths is refused: it would load on every turn"
else bad "a rule with no paths is refused: it would load on every turn" "$nopaths"; fi
nocmd="$("$DECK" ask fold "$UNANS" --as gate --into "$FP" 2>&1 || true)"
if printf '%s' "$nocmd" | grep -q 'a gate needs --command'; then
  ok "a gate with no command is refused: deck will not guess what checks it"
else bad "a gate with no command is refused: deck will not guess what checks it" "$nocmd"; fi
noimpact="$("$DECK" ask fold "$UNANS" --as toggle --into "$FP" --group quality 2>&1 || true)"
if printf '%s' "$noimpact" | grep -q 'not one of its values is defended'; then
  ok "a toggle defending no value is refused, the way a drafted one already is"
else bad "a toggle defending no value is refused, the way a drafted one already is" "$noimpact"; fi
if printf '%s' "$noimpact" | grep -q 'call' && printf '%s' "$noimpact" | grep -q 'request'; then
  ok "and names the values that owe a reason"
else bad "and names the values that owe a reason" "$noimpact"; fi

# The whole point of writing a toggle rather than a note: the catalog holds it.
"$DECK" ask fold "$UNANS" --as toggle --into "$FP" --group quality --gate-id retry_budget_scope \
  --impact "call=Each call gets its own budget; a retried request may take many." \
  --impact "request=One budget for the request, however many calls it makes." >/dev/null 2>&1
if env DECK_PACKS="$FP" "$DECK" toggle validate --strict >/dev/null 2>&1; then
  ok "a folded toggle is a catalog entry that validates"
else bad "a folded toggle is a catalog entry that validates" "$(env DECK_PACKS="$FP" "$DECK" toggle validate --strict 2>&1)"; fi
badhdr="$("$DECK" ask fold "$UNANS" --as toggle --into "$FP" --again --group quality --gate-id r2 --header "far too long a header" \
  --impact "call=x" --impact "request=y" 2>&1 || true)"
if printf '%s' "$badhdr" | grep -q 'the selector fits 12'; then
  ok "a header the selector cannot show is refused before it reaches the catalog"
else bad "a header the selector cannot show is refused before it reaches the catalog" "$badhdr"; fi

# A task may own a decision: answering it up front does not make the run
# autonomous, it empties the task.
python3 - "$WS/.deck/board.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["tasks"][0]["decides"] = ["api_compat"]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
"$DECK" toggle set --at workspace api_compat ask >/dev/null 2>&1
# ask-plan exits non-zero while anything else is still pending, so assert on
# what it says.
out="$("$DECK" board ask-plan 2>&1 || true)"
if printf '%s' "$out" | grep -q "exists to decide it"; then ok "a decision a task owns is not pre-answered"; else bad "a decision a task owns is not pre-answered" "$out"; fi
if printf '%s' "$out" | grep -q "api_compat.*waiting"; then bad "and it is kept out of the pending list"; else ok "and it is kept out of the pending list"; fi
if "$DECK" board plan --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("owned_decisions") else 1)'; then
  ok "and the plan says which task owns it"
else bad "and the plan says which task owns it"; fi

note "the name a claim is published under"
# A file board is committed and pushed. `$USER` is whatever the machine calls
# you, and it reached seven `assignee:` lines in this repository headed for a
# public push under a different identity — nothing between the write and the
# push ever questioned it. The name recorded in a file is now the one the
# repository publishes under: git's `user.name`, read where the file lives.
#
# Its own workspace and its own repositories, because the question this answers
# is which identity is read when two of them disagree. GIT_CONFIG_GLOBAL is
# pinned so every check reads the fixture's configuration and never the
# machine's, and `USER` is set to a name no repository here carries, so anything
# still reading the login is visible in the output instead of plausible in it.
IW="$(mktemp -d)"; mkdir -p "$IW/.deck" "$IW/pub" "$IW/other" "$IW/loose"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$IW/.deck/toggles.yaml"
for d in pub other; do git -C "$IW/$d" init -q 2>/dev/null; done
git -C "$IW/pub"   config user.name ana
git -C "$IW/other" config user.name nemo

board_at() {   # a board file at the path named, holding one open task
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'YAML'
version: 1
tasks:
  - { id: T-1, title: one thing, repos: [], status: open }
YAML
}
points_at() {  # aim the descriptor's single file source at a path
  python3 - "$IW/.deck/workspace.yaml" "$1" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1])
p.write_text(yaml.safe_dump(
    {"version": 1, "repos": {}, "targets": [], "backlog": [{"type": "tasks", "file": sys.argv[2]}]},
    sort_keys=False))
PY
}
iw()    { env -u DECK_USER DECK_ROOT="$IW" USER=shell-login \
              GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
iw_as() { local name="$1"; shift
          env DECK_USER="$name" DECK_ROOT="$IW" USER=shell-login \
              GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }

board_at "$IW/pub/board.yaml"; points_at pub/board.yaml
check "a claim on a file board records the repository's identity" "claimed T-1 for ana" \
  iw board claim T-1 --yes
check "and says where that name came from" "comes from git user.name" \
  iw board claim T-1 --yes
if grep -q "shell-login" "$IW/pub/board.yaml"; then
  bad "the shell login reaches the committed file nowhere" "$(grep -n shell-login "$IW/pub/board.yaml")"
else
  ok "the shell login reaches the committed file nowhere"
fi
check "\$DECK_USER overrides it"     "claimed T-1 for zed"     iw_as zed board claim T-1 --force --yes
check "and the override is stated"   'comes from $DECK_USER'   iw_as zed board claim T-1 --force --yes
check "a name given outright wins over both" "claimed T-1 for nemo" \
  iw_as zed board claim T-1 nemo --force --yes

# The question the fix turns on: a workspace holds several repositories and they
# may publish under different names, so the identity read is the one configured
# where the board file lives — the configuration that will sign the commit
# carrying it — and not a ranking of the registry.
board_at "$IW/other/board.yaml"; points_at other/board.yaml
check "a board in another repository records that repository's identity" "claimed T-1 for nemo" \
  iw board claim T-1 --yes

board_at "$IW/loose/board.yaml"; points_at loose/board.yaml
none="$(iw board claim T-1 --yes 2>&1 || true)"
if printf '%s' "$none" | grep -q "config user.name"; then
  ok "with no identity to read, the refusal names the command that sets one"
else
  bad "with no identity to read, the refusal names the command that sets one" "$none"
fi
check_fail "and nothing is claimed under the login instead" iw board claim T-1 --yes

points_at pub/board.yaml
check "whoami says which name a file source would write" "ana"           iw board whoami
check "and where it reads that name from"                "git user.name" iw board whoami

# `read` resolved the declared path and `source_for` did not, so a board under
# `~` was listed and closed but never claimed: the claim reported a task it had
# just printed as living in no source it could write to.
board_at "$IW/home/board.yaml"; points_at "~/board.yaml"
check "a board declared under \`~\` is claimable, not only readable" "claimed T-1 for zed" \
  env DECK_USER=zed DECK_ROOT="$IW" HOME="$IW/home" "$DECK" board claim T-1 --yes

# ---- and the other half of the question, which is not the same question.
# A tracker claim names an account that authenticates to that tracker, so the
# login stays right there. Its own stand-in on a port the kernel picks, so this
# group carries no fixture of anyone else's: it records whatever name it is
# given, and the check reads the name deck sent.
cat > "$IW/tracker.py" <<'PY'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self._send({'items': [{'number': 1, 'title': 'a thing', 'state': 'open', 'labels': [],
                               'assignee': None, 'html_url': 'http://x/1', 'body': ''}]})

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n).decode() or '{}')
        self._send({'number': 1, 'assignees': [{'login': w} for w in body.get('assignees', [])]}, 201)


s = HTTPServer(('127.0.0.1', 0), H)   # port 0: the kernel picks a free one
open(sys.argv[1], 'w').write(str(s.server_port))
threading.Thread(target=s.serve_forever, daemon=True).start()
import time; time.sleep(120)
PY
python3 "$IW/tracker.py" "$IW/port" & IFAKE=$!
# The socket is bound and listening before the port is written, so the file
# appearing is the readiness signal — no sleep long enough to be a guess.
for _ in $(seq 1 50); do [ -s "$IW/port" ] && break; sleep 0.1; done
TIW="$(mktemp -d)"; mkdir -p "$TIW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$TIW/.deck/toggles.yaml"
git -C "$TIW" init -q 2>/dev/null; git -C "$TIW" config user.name ana
cat > "$TIW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$(cat "$IW/port" 2>/dev/null)" }
YAML
check "a tracker claim still names the account that authenticates" "assigned #1 to shell-login on github" \
  env -u DECK_USER DECK_ROOT="$TIW" USER=shell-login DECK_TOKEN_GITHUB=smoke-token "$DECK" board claim "#1" --yes
kill $IFAKE 2>/dev/null || true
rm -rf "$TIW"

# A consultation outlives its session by design, is read by the next run, and is
# quoted into the bundle a reviewer reads. `asked_by` travels as far as an
# `assignee:` does, so it is resolved the same way.
CW="$(mktemp -d)"; mkdir -p "$CW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$CW/.deck/toggles.yaml"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$CW/.deck/workspace.yaml"
git -C "$CW" init -q 2>/dev/null; git -C "$CW" config user.name ana
cw() { env -u DECK_USER DECK_ROOT="$CW" USER=shell-login \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
asked="$(cw ask new "Which identity does a recorded question carry?" 2>&1)"
CID="$(printf '%s' "$asked" | grep -oE '^recorded .*' | cut -d' ' -f2)"
check "a consultation records the published identity" "by ana" cw ask show "$CID"
if grep -rq "shell-login" "$CW/.deck/consultations"; then
  bad "and never the shell login" "$(grep -rn shell-login "$CW/.deck/consultations" | head -1)"
else
  ok "and never the shell login"
fi
NW="$(mktemp -d)"; mkdir -p "$NW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$NW/.deck/toggles.yaml"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$NW/.deck/workspace.yaml"
nw() { env -u DECK_USER DECK_ROOT="$NW" USER=shell-login \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
nasked="$(nw ask new "And with no identity to read?" 2>&1)"
NID="$(printf '%s' "$nasked" | grep -oE '^recorded .*' | cut -d' ' -f2)"
check "with no identity to read, a consultation records none rather than the login" "by ?" \
  nw ask show "$NID"
rm -rf "$IW" "$CW" "$NW"

note "vendoring from a source"
UP="$WS/upstream"
mkdir -p "$UP"/{skills/reviewer,agents,hooks}
printf -- '---\ndescription: Reviews a diff\n---\n\nReview carefully.\n' > "$UP/skills/reviewer/SKILL.md"
printf -- '---\nname: tester\n---\n\nRun the suite.\n' > "$UP/agents/tester.md"
echo '{"hooks":{}}' > "$UP/hooks/hooks.json"
git -C "$UP" init -q
git -C "$UP" add -A
git -C "$UP" -c user.email=a@b -c user.name=a commit -qm init

PK="$WS/vendorpack"
"$DECK" pack new vendored --dir "$PK" >/dev/null

check "the registry lists what it knows" "claude-plugins-official" "$DECK" pack sources
check "a dry add writes nothing"    "Nothing written" "$DECK" pack add "file://$UP" --into "$PK" --all
if [ ! -e "$PK/skills/reviewer" ]; then ok "a dry add leaves the pack untouched"; else bad "a dry add leaves the pack untouched"; fi
check "hooks are called out, not taken" "not taken unless you ask" "$DECK" pack add "file://$UP" --into "$PK" --all
"$DECK" pack add "file://$UP" --into "$PK" --all --yes >/dev/null
if [ -f "$PK/skills/reviewer/SKILL.md" ] && [ -f "$PK/agents/tester.md" ]; then
  ok "skills and agents are vendored"
else
  bad "skills and agents are vendored"
fi
if [ ! -e "$PK/hooks/hooks.json" ]; then ok "hooks stay out without --with-hooks"; else bad "hooks stay out without --with-hooks"; fi
check "provenance is recorded" "$UP" "$DECK" pack sources --vendored --into "$PK"
if "$DECK" pack sources --vendored --into "$PK" | grep -q "sha256"; then
  ok "each vendored file carries a hash"
else
  bad "each vendored file carries a hash"
fi
check_fail "adding into a non-pack is refused" "$DECK" pack add "file://$UP" --into "$WS" --all --yes

# One artifact, one provenance record: a re-add must replace the answer, not
# leave two of them in the file.
"$DECK" pack add "file://$UP" --into "$PK" --all --yes --force >/dev/null
if [ "$("$DECK" pack sources --vendored --into "$PK" | grep -c "skills/reviewer")" = "1" ]; then
  ok "re-adding replaces the provenance record rather than doubling it"
else
  bad "re-adding replaces the provenance record rather than doubling it"
fi

# `add` records provenance; `update` is what reads it back. The two questions it
# has to keep apart: did the source move, and did anyone change the copy here.
note "re-checking a vendored artifact against its source"
check "a fresh vendoring matches its source" "every artifact matches" "$DECK" pack update --into "$PK"
check "and a --check run is clean" "every artifact matches" "$DECK" pack update --into "$PK" --check

printf -- '---\nname: tester\n---\n\nRun the suite. And ours.\n' > "$PK/agents/tester.md"
out="$("$DECK" pack update --into "$PK" 2>&1)"
if printf '%s' "$out" | grep -q "agents/tester.md   local"; then ok "an edit here is reported as local"; else bad "an edit here is reported as local" "$out"; fi
if printf '%s' "$out" | grep -q "skills/reviewer   current"; then ok "and its neighbour is left alone"; else bad "and its neighbour is left alone" "$out"; fi
check_fail "--check fails while anything has moved" "$DECK" pack update --into "$PK" --check
printf -- '---\nname: tester\n---\n\nRun the suite.\n' > "$PK/agents/tester.md"

printf -- '---\ndescription: Reviews a diff\n---\n\nReview carefully. Twice.\n' > "$UP/skills/reviewer/SKILL.md"
git -C "$UP" add -A
git -C "$UP" -c user.email=a@b -c user.name=a commit -qm "reviewer: twice"
out="$("$DECK" pack update --into "$PK" 2>&1)"
if printf '%s' "$out" | grep -q "skills/reviewer   upstream"; then ok "a source that moved is reported as upstream"; else bad "a source that moved is reported as upstream" "$out"; fi
if printf '%s' "$out" | grep -q "Nothing written"; then ok "and a dry re-check writes nothing"; else bad "and a dry re-check writes nothing" "$out"; fi
if grep -q "Twice" "$PK/skills/reviewer/SKILL.md"; then bad "and the pack is untouched until --yes"; else ok "and the pack is untouched until --yes"; fi
check "one artifact can be named" "1 vendored artifact" "$DECK" pack update skills/reviewer --into "$PK"
check_fail "and a name nothing was vendored under is refused" "$DECK" pack update nope --into "$PK"

"$DECK" pack update --into "$PK" --yes >/dev/null
if grep -q "Twice" "$PK/skills/reviewer/SKILL.md"; then ok "--yes takes the source copy"; else bad "--yes takes the source copy"; fi
NEW="$(git -C "$UP" rev-parse HEAD)"
if grep -q "$NEW" "$PK/config/sources.yaml"; then ok "and provenance moves to the commit it was taken from"; else bad "and provenance moves to the commit it was taken from" "$(cat "$PK/config/sources.yaml")"; fi
check "a re-check after taking it is clean" "every artifact matches" "$DECK" pack update --into "$PK" --check

# The one case where taking the update would destroy work.
printf -- '---\ndescription: Reviews a diff\n---\n\nReview carefully. Twice. Ours.\n' > "$PK/skills/reviewer/SKILL.md"
printf -- '---\ndescription: Reviews a diff\n---\n\nReview carefully. Three times.\n' > "$UP/skills/reviewer/SKILL.md"
git -C "$UP" add -A
git -C "$UP" -c user.email=a@b -c user.name=a commit -qm "reviewer: thrice"
out="$("$DECK" pack update --into "$PK" 2>&1)"
if printf '%s' "$out" | grep -q "skills/reviewer   diverged"; then ok "edited here AND moved upstream is its own state"; else bad "edited here AND moved upstream is its own state" "$out"; fi
check_fail "and --yes refuses rather than choosing a side" "$DECK" pack update --into "$PK" --yes
if grep -q "Ours" "$PK/skills/reviewer/SKILL.md"; then ok "the local edit survives the refusal"; else bad "the local edit survives the refusal"; fi
out="$("$DECK" pack update --into "$PK" --yes 2>&1)"
if printf '%s' "$out" | grep -q "loses your edits"; then ok "and the refusal says what --force would cost"; else bad "and the refusal says what --force would cost" "$out"; fi
"$DECK" pack update --into "$PK" --yes --force >/dev/null
if grep -q "Three times" "$PK/skills/reviewer/SKILL.md"; then ok "--force takes it, having said so"; else bad "--force takes it, having said so"; fi

# A source that cannot be read is reported as not checked, never as unchanged.
PK2="$WS/vendorpack-blind"
cp -r "$PK" "$PK2"
sed -i "s#file://$UP#file://$WS/no-such-source#" "$PK2/config/sources.yaml"
out="$("$DECK" pack update --into "$PK2" 2>&1)"
if printf '%s' "$out" | grep -q "were NOT checked"; then ok "an unreadable source is reported as not checked"; else bad "an unreadable source is reported as not checked" "$out"; fi
if printf '%s' "$out" | grep -q "unreachable"; then ok "and no claim is made about those artifacts"; else bad "and no claim is made about those artifacts" "$out"; fi
check_fail "an unchecked artifact fails the command" "$DECK" pack update --into "$PK2"

# Vendored, then deleted from the pack: recorded but not here.
rm -rf "$PK/agents"
out="$("$DECK" pack update --into "$PK" 2>&1)"
if printf '%s' "$out" | grep -q "agents/tester.md   missing"; then ok "a vendored path deleted from the pack is reported"; else bad "a vendored path deleted from the pack is reported" "$out"; fi

check_fail "updating a non-pack is refused" "$DECK" pack update --into "$WS"
check "a pack with nothing vendored says so" "nothing vendored" "$DECK" pack update --into "$PACK"

note "headless proposals"
# A stand-in for `claude`, so the plumbing is covered without spending money
# or needing credentials in CI.
FAKEBIN="$WS/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *"propagation graph"*) KIND=impacts;; *"decision catalog"*) KIND=toggle;; esac; done
if [ "${KIND:-}" = "impacts" ]; then
  RESULT='{"edges":[{"from":"a","to":"c","why":"c asserts against a fixture a owns","confidence":"high"},{"from":"c","to":"a","why":"weak, and would close a cycle","confidence":"medium"}],"unsure":["b is empty"]}'
else
  RESULT='{"id":"x","title":"T","summary":"S","values":["on","off"],"default":"on","rationale":"R","impact":{"on":"o"},"question":{"header":"H","text":"Q?","options":[{"value":"on","label":"Yes","description":"d"}]}}'
fi
printf '{"type":"result","subtype":"success","is_error":false,"result":%s,"total_cost_usd":0.0123,"session_id":"fake","usage":{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":9},"permission_denials":[]}\n' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$RESULT")"
SH
chmod +x "$FAKEBIN/claude"

check "show-prompt costs nothing and needs no permission" "propagation graph" "$DECK" propose impacts --show-prompt
refused="$("$DECK" propose impacts 2>&1 || true)"
if printf '%s' "$refused" | grep -q "Re-run with --yes"; then
  ok "a proposal run without permission is refused"
else
  bad "a proposal run without permission is refused" "$refused"
fi
out="$(PATH="$FAKEBIN:$PATH" "$DECK" propose impacts --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "a -> c"; then ok "an edge is proposed with its evidence"; else bad "an edge is proposed" "$out"; fi
if printf '%s' "$out" | grep -q '\$0.0123'; then ok "the call reports what it cost"; else bad "the call reports what it cost"; fi
if printf '%s' "$out" | grep -q "Nothing was written to the descriptor"; then
  ok "a proposal never edits the descriptor"
else
  bad "a proposal never edits the descriptor"
fi
PROP="$(ls "$WS/.deck/proposals" | head -1)"
if [ -n "$PROP" ]; then ok "the proposal is saved for review"; else bad "the proposal is saved for review"; fi
# The drafter found `a -> c` and `c -> a`, which is what a drafter with only
# `impacts:` does when both directions have evidence. Two edges there is a
# cycle, so `apply` drafts it as the coupling it is. Without --yes, so the
# descriptor this file goes on using is untouched.
both="$("$DECK" propose apply "$PROP" 2>&1 || true)"
if printf '%s' "$both" | grep -q "a <-> c"; then
  ok "a pair the drafter found both ways is drafted as a coupling"
else
  bad "a pair the drafter found both ways is drafted as a coupling" "$both"
fi
if printf '%s' "$both" | grep -q "carries no order"; then
  ok "and the draft says the coupling carries no order"
else
  bad "and the draft says the coupling carries no order" "$both"
fi
if printf '%s' "$both" | grep -q "REFUSED"; then
  bad "and it is not refused as a cycle" "$both"
else
  ok "and it is not refused as a cycle"
fi
check "apply without --yes writes nothing" "Nothing written" "$DECK" propose apply "$PROP" --confidence high
"$DECK" propose apply "$PROP" --confidence high --yes >/dev/null 2>&1
if "$DECK" impact a --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["order"][-1]=="c" else 1)'; then
  ok "a reviewed edge reaches the graph"
else
  bad "a reviewed edge reaches the graph"
fi

# A rule title is written by a model, so it arrives with whatever punctuation the
# model liked. It used to become the file name verbatim: an em-dash landed in the
# name, and a slash would have made a directory.
slug="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.config import title_slug
print(title_slug('Callbacks run on one thread - never block'))
print(title_slug('a/b: \"quoted\", and dashed'))
print(title_slug('\u2014\u2014'))
")"
if printf '%s' "$slug" | grep -q "callbacks-run-on-one-thread-never-block"; then
  ok "a rule file name is ascii, lowercase, and cut on a word"
else
  bad "a rule file name is ascii, lowercase, and cut on a word" "$slug"
fi
if printf '%s' "$slug" | grep -q "^a-b-quoted-and-dashed$"; then
  ok "a slash in a rule title cannot make a directory"
else
  bad "a slash in a rule title cannot make a directory" "$slug"
fi
if printf '%s' "$slug" | grep -q "^rule$"; then
  ok "a title with nothing nameable still yields a name"
else
  bad "a title with nothing nameable still yields a name" "$slug"
fi

# `skipped` means two things and the summary used to render both as "not
# applicable": a gate that does not apply here, and a gate that does apply but
# was never reached because the ladder stopped. Only the second is still owed,
# and the same line is what a reviewer reads in the bundle.
sm="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import summarise, PASSED, FAILED, SKIPPED, STOPPED_EARLY
print(summarise([{'status':PASSED,'runs':[1]},{'status':FAILED,'runs':[1]},
                 {'status':SKIPPED,'reason':STOPPED_EARLY,'runs':[]}]))
print(summarise([{'status':PASSED,'runs':[1]},
                 {'status':SKIPPED,'reason':'lint is not declared','runs':[]}]))
")"
if printf '%s' "$sm" | grep -q "1 not attempted"; then
  ok "a gate the ladder never reached is not attempted, not inapplicable"
else
  bad "a gate the ladder never reached is not attempted, not inapplicable" "$sm"
fi
if printf '%s' "$sm" | grep -q "1 not applicable"; then
  ok "a gate that does not apply is still reported as inapplicable"
else
  bad "a gate that does not apply is still reported as inapplicable" "$sm"
fi

# Every mounted line names where the artifact went, except a written file, which
# used to print its hash — so --dry-run said where the brief would land and the
# real mount did not.
"$DECK" unmount --task BRIEFED >/dev/null 2>&1
briefed="$("$DECK" mount --repos a --task BRIEFED --brief "what this task is" 2>&1 || true)"
if printf '%s' "$briefed" | grep -q "CLAUDE.local.md"; then
  ok "a written brief names the file it wrote"
else
  bad "a written brief names the file it wrote" "$briefed"
fi
"$DECK" unmount --task BRIEFED >/dev/null 2>&1

# The gate record's `level` is what the run was configured to reach. Reporting it
# as what was reached claims verification that did not happen: a failed static
# gate used to be summarised as "the ladder reached build".
rc="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
stopped = [{'from_level':'static','status':'passed'},
           {'from_level':'static','status':'failed'},
           {'from_level':'build','status':'skipped','reason':'an earlier gate failed'}]
green   = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
na      = [{'from_level':'static','status':'passed'},
           {'from_level':'build','status':'skipped','reason':'lint is not declared'}]
print('stopped', rung_completed(R,'build',stopped))
print('green', rung_completed(R,'build',green))
print('na', rung_completed(R,'build',na))
print('na_stopped', rung_completed(R,'build',na)[1])
")"
if printf '%s' "$rc" | grep -q "^stopped (None, 'static')$"; then
  ok "a failed rung is not reported as a rung the ladder reached"
else
  bad "a failed rung is not reported as a rung the ladder reached" "$rc"
fi
if printf '%s' "$rc" | grep -q "^green ('build', None)$"; then
  ok "a green run still names the level it was set to"
else
  bad "a green run still names the level it was set to" "$rc"
fi
# Deliberately narrowed, and the narrowing is the argument. This check asserted
# the whole tuple, so under one name it held two claims: that an inapplicable
# gate does not *stop* the ladder — the rule, and it stands — and that the rung
# it sits on counts as reached, which is an overclaim, because nothing was
# verified there. Asserting the second under the name of the first is how the
# defect survived two rounds of fixes in this file: a reader looking for the
# claim to challenge found a check that appeared to defend it. The rule keeps
# the name and the half of the tuple that states it, `stopped_at is None`; the
# other half moved to its own check with its own name, below.
#
# A regression guard, then: it passes before this change and after. It is here
# because the fix could only go wrong one way — by making an inapplicable gate
# owe something, which would stall a ladder that `only_repos` or a `when` toggle
# had legitimately narrowed.
if printf '%s' "$rc" | grep -q "^na_stopped None$"; then
  ok "a gate that does not apply does not hold the ladder back"
else
  bad "a gate that does not apply does not hold the ladder back" "$rc"
fi

# The same overclaim in the other direction. An empty rung was vacuously
# complete, so a workspace with `gate_level: deploy` and no deploy gate anywhere
# reported a ladder that reached `deploy` with nothing verified there.
note "a rung with no gate is a gap, not a rung the ladder reached"
# Two snippets, not one: an import that does not exist yet would fail every
# check in the block at once, and a check has to fail for its own reason.
er="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
empty = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
hole  = [{'from_level':'static','status':'passed'},{'from_level':'deploy','status':'passed'}]
print('empty', rung_completed(R,'deploy',empty))
print('hole', rung_completed(R,'deploy',hole))
")"
if printf '%s' "$er" | grep -q "^empty ('build', None)\$"; then
  ok "a rung the ladder climbed to that holds no gate is not a rung it reached"
else
  bad "a rung the ladder climbed to that holds no gate is not a rung it reached" "$er"
fi
if printf '%s' "$er" | grep -q "^hole ('static', None)\$"; then
  ok "and nothing above the hole is credited either"
else
  bad "and nothing above the hole is credited either" "$er"
fi
nr="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rungs_without_gates
R = ['static','build','deploy','behavior']
empty = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
unnamed = [{'from_level':None,'status':'passed'}]
print('without', rungs_without_gates(R,empty))
print('unnamed', rungs_without_gates(R,unnamed))
" 2>&1)"
if printf '%s' "$nr" | grep -q "^without \['deploy', 'behavior'\]\$"; then
  ok "the rungs holding no gate are named, so the gap is visible"
else
  bad "the rungs holding no gate are named, so the gap is visible" "$nr"
fi
# `applicable()` reads a missing from_level as static; `record()` files it as
# null. A gate declared without one would otherwise leave static looking empty.
if printf '%s' "$nr" | grep -q "^unnamed \['build', 'deploy', 'behavior'\]\$"; then
  ok "a gate declared with no from_level counts at the rung it ran on"
else
  bad "a gate declared with no from_level counts at the rung it ran on" "$nr"
fi

# The same overclaim one layer in. A rung that *has* gates, every one of which
# turned out not to apply — `only_repos` excluded every repository in play, a
# `when` toggle did not match — owed nothing, and owing nothing was read as
# being done. So `build` was reported reached while no build command ever ran.
note "a rung whose gates were all waved through is not a rung the ladder reached"
wv="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
waved = [{'from_level':'static','status':'passed'},
         {'from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
mixed = [{'from_level':'static','status':'passed'},
         {'from_level':'build','status':'passed'},
         {'from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
print('waved', rung_completed(R,'build',waved))
print('mixed', rung_completed(R,'build',mixed))
" 2>&1)"
if printf '%s' "$wv" | grep -q "^waved ('static', None)\$"; then
  ok "a rung whose every gate was waved through is not reported as reached"
else
  bad "a rung whose every gate was waved through is not reported as reached" "$wv"
fi
# The other half of the same rule, and it is why "not reached" is stated as
# "nothing passed here" rather than "something did not apply here". One gate
# that actually ran is verification; the inapplicable ones beside it neither add
# to it nor take it away.
if printf '%s' "$wv" | grep -q "^mixed ('build', None)\$"; then
  ok "and a rung with one gate that actually passed is still reached"
else
  bad "and a rung with one gate that actually passed is still reached" "$wv"
fi
# Its own snippet: an import that does not exist yet must not fail the checks
# above, which are about a different function.
wi="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rungs_all_inapplicable
R = ['static','build','deploy','behavior']
waved = [{'id':'lint','from_level':'static','status':'passed','reason':''},
         {'id':'build','from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
failed = [{'id':'fails','from_level':'build','status':'failed','reason':''}]
print('waved', rungs_all_inapplicable(R,waved))
print('failed', rungs_all_inapplicable(R,failed))
" 2>&1)"
if printf '%s' "$wi" | grep -q "'rung': 'build'.*'id': 'build'.*no repository in this change matches it"; then
  ok "the rung names the gates it weighed and the reason each gave"
else
  bad "the rung names the gates it weighed and the reason each gave" "$wi"
fi
# A rung the ladder failed at is not coverage. It is where the ladder stopped,
# `rung_completed()` already names it, and filing it here as well would print a
# failure under a heading that reads as "nothing to do here".
if printf '%s' "$wi" | grep -q "^failed \[\]\$"; then
  ok "and a rung the ladder failed at is not filed as coverage"
else
  bad "and a rung the ladder failed at is not filed as coverage" "$wi"
fi

# Two panes of one window are one task, and the SessionEnd hook takes mounts
# back. Together those used to mean any pane closing tore the task down under
# the pane still working in it. A mount is now held, and released one holder at
# a time.
# ---- unmount takes back everything mount wrote, not everything it recorded
# The observed failure: `unmount` reported `10 removed · 0 left alone`, exited
# 0, and left `.claude/settings.local.json` in all four repositories of a demo
# workspace. `_merge_settings` wrote `enabledPlugins` and
# `extraKnownMarketplaces` and returned only the first, so the marketplace was
# written into a product repository and recorded nowhere — and it kept `data`
# non-empty, so the branch that deletes a settings file holding nothing but
# ours was never reached.
#
# It went unseen because git's XDG default excludes file commonly carries
# `**/.claude/settings.local.json`, put there by anyone who has run Claude
# Code. `git config --get core.excludesfile` returns nothing for it and
# `GIT_CONFIG_GLOBAL=/dev/null` does not disable it, so `git status` was clean
# on the machines that could have noticed. These checks read the filesystem
# rather than git, for the same reason.
note "unmount leaves nothing deck wrote"
UN="$(mktemp -d)"
mkdir -p "$UN/.deck" "$UN/a" "$UN/pk/config" "$UN/pk/rules"
printf 'version: 1\nrepos: { a: { path: a } }\ntargets: []\n' > "$UN/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$UN/.deck/toggles.yaml"
printf 'markers: []\n' > "$UN/pk/config/detect.yaml"
cat > "$UN/pk/config/mount.yaml" <<'YAML'
plugin: example-pack@example
marketplace: { name: example, source: { source: url, url: "https://example.invalid/p.git" } }
rules:
  - { file: rules/one.md }
YAML
printf -- '---\npaths: ["**/*"]\n---\n\nsomething true\n' > "$UN/pk/rules/one.md"
un() { env DECK_ROOT="$UN" DECK_PACKS="$UN/pk" DECK_SESSION=unmounting "$DECK" "$@"; }

un mount --task U1 >/dev/null 2>&1
if [ -f "$UN/a/.claude/settings.local.json" ]; then
  ok "mounting writes the settings file the pack asks for"
else bad "mounting writes the settings file the pack asks for"; fi
if grep -q 'extraKnownMarketplaces' "$UN/a/.claude/settings.local.json" 2>/dev/null; then
  ok "and the marketplace entry inside it"
else bad "and the marketplace entry inside it" "$(cat "$UN/a/.claude/settings.local.json" 2>/dev/null)"; fi

un_out="$(un unmount --task U1 2>&1 || true)"
if [ ! -f "$UN/a/.claude/settings.local.json" ]; then
  ok "unmounting removes it, marketplace and all"
else bad "unmounting removes it, marketplace and all" "left: $(cat "$UN/a/.claude/settings.local.json")"; fi
if [ ! -d "$UN/a/.claude" ]; then
  ok "and the directory deck made for it, when nothing else is in there"
else bad "and the directory deck made for it, when nothing else is in there" "$(ls -a "$UN/a/.claude")"; fi
if printf '%s' "$un_out" | grep -q 'marketplace example'; then
  ok "and says the marketplace was one of the things it took back"
else bad "and says the marketplace was one of the things it took back" "$un_out"; fi

# What deck did not write, deck does not take away. A settings file with
# somebody else's key in it survives, and so does the directory holding it.
un mount --task U2 >/dev/null 2>&1
python3 - "$UN/a/.claude/settings.local.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["theirs"] = {"kept": True}
p.write_text(json.dumps(d, indent=2) + "\n")
PY
un unmount --task U2 >/dev/null 2>&1
if [ -f "$UN/a/.claude/settings.local.json" ] && grep -q 'theirs' "$UN/a/.claude/settings.local.json"; then
  ok "a settings file holding somebody else's key is left where it is"
else bad "a settings file holding somebody else's key is left where it is" "$(ls -a "$UN/a/.claude" 2>/dev/null)"; fi
if grep -q 'extraKnownMarketplaces' "$UN/a/.claude/settings.local.json" 2>/dev/null; then
  bad "and deck's half of it is still taken out" "$(cat "$UN/a/.claude/settings.local.json")"
else ok "and deck's half of it is still taken out"; fi
rm -rf "$UN"

note "mounts are held, not owned by whoever closes first"
export DECK_SESSION=holders
"$DECK" mount --repos a --task H1 --no-expand >/dev/null 2>&1
if python3 -c "
import json,sys
print('terminal' in json.load(open('$WS/.deck/mounts/H1.json'))['holders'] or sys.exit(1))
" >/dev/null 2>&1; then
  ok "a mount made at a terminal is held by the person who made it"
else
  bad "a mount made at a terminal is held by the person who made it"
fi
CLAUDE_SESSION_ID=agent-a "$DECK" hold >/dev/null 2>&1
CLAUDE_SESSION_ID=agent-a "$DECK" unmount --session >/dev/null 2>&1
if [ -f "$WS/.deck/mounts/H1.json" ] && [ -e "$WS/a/.claude/rules/deck-only-a.md" ]; then
  ok "an agent session ending does not take back what a person mounted"
else
  bad "an agent session ending does not take back what a person mounted"
fi
"$DECK" unmount --task H1 >/dev/null 2>&1

CLAUDE_SESSION_ID=agent-a "$DECK" mount --repos a --task H2 --no-expand >/dev/null 2>&1
CLAUDE_SESSION_ID=agent-b "$DECK" hold >/dev/null 2>&1
CLAUDE_SESSION_ID=agent-b "$DECK" unmount --session >/dev/null 2>&1
if [ -f "$WS/.deck/mounts/H2.json" ]; then
  ok "one session ending leaves a mount another session still holds"
else
  bad "one session ending leaves a mount another session still holds"
fi
CLAUDE_SESSION_ID=agent-a "$DECK" unmount --session >/dev/null 2>&1
if [ ! -f "$WS/.deck/mounts/H2.json" ] && [ ! -e "$WS/a/.claude/rules/deck-only-a.md" ]; then
  ok "the last holder leaving takes the mount back, so nothing is left behind"
else
  bad "the last holder leaving takes the mount back, so nothing is left behind"
fi
unset DECK_SESSION

# A rule is copied, so a pack that moves on afterwards leaves every mount holding
# the old text. The manifest already stored the source hash; nothing compared it.
note "a mounted copy knows when its pack has moved on"
export DECK_SESSION=stale
"$DECK" mount --repos a --task ST1 --no-expand >/dev/null 2>&1
if "$DECK" doctor 2>&1 | grep -q "stale:"; then
  bad "a fresh mount is not accused of being stale"
else
  ok "a fresh mount is not accused of being stale"
fi
echo "" >> "$PACK/rules/only-a.md"
st="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$st" | grep -q "stale: .* changed only-a.md"; then
  ok "a pack edited after mounting is reported against the mount"
else
  bad "a pack edited after mounting is reported against the mount" "$(printf '%s' "$st" | grep -A3 'mounted')"
fi
if printf '%s' "$st" | grep -q "old copy still in a"; then
  ok "and it names which repository still holds the old text"
else
  bad "and it names which repository still holds the old text"
fi
"$DECK" unmount --task ST1 >/dev/null 2>&1
unset DECK_SESSION

# A statement of the task usually arrives after the mount: you mount to start
# working and work out what the task is by working. Charging an unmount for that
# means most tasks never get one.
note "a statement can reach a mount that already exists"
export DECK_SESSION=briefing
"$DECK" mount --repos a --task BR1 --no-expand > "$WS/br.txt" 2>&1
if grep -q "No statement" "$WS/br.txt"; then
  ok "mounting with no statement says so"
else
  bad "mounting with no statement says so" "$(cat "$WS/br.txt")"
fi
add1="$("$DECK" mount --task BR1 --brief "what this task is for" 2>&1 || true)"
if printf '%s' "$add1" | grep -q "added the statement" && grep -q "what this task is for" "$WS/CLAUDE.local.md"; then
  ok "a statement is added to a live mount, without unmounting"
else
  bad "a statement is added to a live mount, without unmounting" "$add1"
fi
add2="$("$DECK" mount --task BR1 --brief "a second thought" 2>&1 || true)"
if printf '%s' "$add2" | grep -q "replaced the statement" && grep -q "a second thought" "$WS/CLAUDE.local.md"; then
  ok "and replaced, when the task turns out to be something else"
else
  bad "and replaced, when the task turns out to be something else" "$add2"
fi
echo "someone edited this" >> "$WS/CLAUDE.local.md"
add3="$("$DECK" mount --task BR1 --brief "should not win" 2>&1 || true)"
if printf '%s' "$add3" | grep -q "refusing to overwrite"; then
  ok "a statement someone edited is never overwritten"
else
  bad "a statement someone edited is never overwritten" "$add3"
fi
# `mount` exits 1 here, which is right, and pipefail would make the pipeline
# fail with it — so capture first, then look.
again="$("$DECK" mount --repos a --task BR1 --no-expand 2>&1 || true)"
if printf '%s' "$again" | grep -q "already mounted"; then
  ok "mounting again with no statement still refuses"
else
  bad "mounting again with no statement still refuses" "$again"
fi
"$DECK" unmount --task BR1 >/dev/null 2>&1
rm -f "$WS/CLAUDE.local.md"
unset DECK_SESSION

# The suite must be the same size wherever it runs, or the number the documents
# state cannot be true in both places. It was not: two checks sat inside a
# `command -v` and simply vanished on a machine without the tool, so a green
# local run and a red CI run disagreed about a number both reported correctly.
# Every `command -v` guard must have a matching `skip` for each check it hides,
# or the suite changes size between machines and the number the documents state
# cannot be true in both. It was not: two checks vanished on a runner without
# `claude`, so a green local run and a red CI run disagreed about a total both
# reported correctly.
guards="$(cd "$REPO" && python3 - <<'PYG'
import re, pathlib
src = pathlib.Path("ci/smoke.sh").read_text().split("\n")
bad = []
for i, line in enumerate(src):
    if not re.match(r"^if command -v \w+ >", line):
        continue
    hidden, skipped, j = set(), set(), i
    while j < len(src):
        t = src[j].strip()
        # One check is one line of output, so count the descriptions rather
        # than the calls: a one-line `if …; then ok "X"; else bad "X"; fi` is
        # one check written twice, and counting calls both undercounts the
        # inline form and double-counts this one.
        for m in re.finditer(r'\b(?:check|check_fail|ok|bad)\s+"([^"]+)"', src[j]):
            hidden.add(m.group(1))
        for m in re.finditer(r'\bskip\s+"([^"]+?)(?: —[^"]*)?"', src[j]):
            skipped.add(m.group(1))
        # The guard opens at column 0, so the `fi` that closes it is at column
        # 0 too. A one-line `if …; then …; fi` inside is indented and must not
        # end the scan — which it did, and the count came out wrong.
        if src[j] == "fi" and j > i:
            break
        j += 1
    missing = hidden - skipped
    if missing:
        bad.append(f"line {i+1}: no skip for {sorted(missing)}")
print("; ".join(bad) if bad else "balanced")
PYG
)"
if [ "$guards" = "balanced" ]; then
  ok "every check behind a tool guard is still counted when the tool is absent"
else
  bad "every check behind a tool guard is still counted when the tool is absent" "$guards"
fi

# Every name in SHARED_NAMES has to actually mean "every repository". They are
# synonyms so a collection shared between products can call the pack something
# other than the workspace it is deliberately not specific to — and a synonym
# nothing resolves is worse than one name, because the directory looks tended.
names="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.workspace import SHARED_NAMES
print(' '.join(SHARED_NAMES))
")"
missing=""
for n in $names; do
  SW="$(mktemp -d)"; mkdir -p "$SW/.deck" "$SW/only" "$SW/packs/$n/config"
  printf 'markers: []\n' > "$SW/packs/$n/config/detect.yaml"
  printf 'version: 1\npacks_root: packs\nrepos:\n  only: { path: only }\n' > "$SW/.deck/workspace.yaml"
  cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$SW/.deck/toggles.yaml"
  out="$(DECK_ROOT="$SW" "$DECK" packs 2>&1 || true)"
  printf '%s' "$out" | grep -q "every repository" || missing="$missing $n"
  rm -rf "$SW"
done
if [ -z "$missing" ]; then
  ok "every shared-pack name resolves to every repository"
else
  bad "every shared-pack name resolves to every repository" "not resolved:$missing"
fi
# The check above reads the list from the module, so it passes whatever the list
# says — it guards against adding a name that does not work, and proves nothing
# about which names exist. The four are named here so that dropping one is a
# failure rather than a quietly smaller list.
for want in _workspace _all _shared _common; do
  printf '%s' "$names" | grep -qw "$want" \
    && ok "\`$want\` is a name a shared pack may take" \
    || bad "\`$want\` is a name a shared pack may take" "SHARED_NAMES is: $names"
done

# `propose pack` costs money, so the check is the shape of the ask, not a call.
check "the pack prompt names the homes a finding can have" "cheapest correct home wins" "$DECK" propose pack a --show-prompt
check "and refuses to invent a command" "Do not invent a command" "$DECK" propose pack a --show-prompt
check "and demands evidence for a rule" "propose only what you can point at evidence for" "$DECK" propose pack a --show-prompt
check_fail "an unknown repository is refused" "$DECK" propose pack nope --show-prompt

# ---- a draft is told where the answer might be, when the graph knows
# The observed cost: over eight repositories, the drafts filed 27 questions and
# roughly a third named an artifact as absent that sat in a sibling the graph
# already pointed at. Each was a paid call producing a question a cheaper one
# could have answered — and the sentence "it lives in another repository" is
# true of the directory and false of the workspace.
#
# Its own fixture. The workspace above gains repositories and edges as the suite
# runs, and a check about which repositories the graph connects has to know the
# graph it is asserting on.
NG="$(mktemp -d)"
mkdir -p "$NG/.deck" "$NG"/{schema,server,e2e,side}
cat > "$NG/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  schema: { path: schema, impacts: [server] }
  server: { path: server, impacts: [e2e], couples: [side] }
  e2e:    { path: e2e,    impacts: [] }
  side:   { path: side,   impacts: [] }
targets: []
YAML
ng() { env DECK_ROOT="$NG" "$DECK" "$@"; }

np="$(ng propose pack server --show-prompt 2>&1 || true)"
if printf '%s' "$np" | grep -q 'The workspace connects this repository to others'; then
  ok "a draft is told which repositories the graph connects to this one"
else bad "a draft is told which repositories the graph connects to this one" "$(printf '%s' "$np" | head -12)"; fi
if printf '%s' "$np" | grep -q 'a change here reaches it'; then
  ok "and why each is a neighbour, which is where to look for what"
else bad "and why each is a neighbour, which is where to look for what" "$np"; fi
if printf '%s' "$np" | grep -q "$NG/e2e"; then
  ok "and where it is, so it can open it"
else bad "and where it is, so it can open it" "$np"; fi
if printf '%s' "$np" | grep -q 'The pack is still for ONE repository'; then
  ok "and that a neighbour is evidence, never a subject to draft for"
else bad "and that a neighbour is evidence, never a subject to draft for" "$np"; fi
# All three relations, and each named as itself.
if printf '%s' "$np" | grep -q 'a change there reaches this one'; then
  ok "what reaches this one is a neighbour too, not only what it reaches"
else bad "what reaches this one is a neighbour too, not only what it reaches" "$np"; fi
if printf '%s' "$np" | grep -q 'coupled: the two move together'; then
  ok "and so is what moves with it"
else bad "and so is what moves with it" "$np"; fi
if printf '%s' "$np" | grep -qE '^  server$'; then
  bad "and a repository is not its own neighbour" "$np"
else ok "and a repository is not its own neighbour"; fi
# The registry is not the graph. `schema` reaches `server` and nothing else;
# `side` and `e2e` are in the workspace and not on its edges.
ns="$(ng propose pack schema --show-prompt 2>&1 || true)"
if printf '%s' "$ns" | grep -qE '^  (side|e2e)$'; then
  bad "a repository the graph does not connect is not offered to read" "$ns"
else ok "a repository the graph does not connect is not offered to read"; fi
# A repository with no edges at all reads exactly as it did before any of this.
nn="$(ng propose pack side --show-prompt 2>&1 || true)"
if printf '%s' "$nn" | grep -q 'The workspace connects'; then
  ok "a repository whose only edge is a coupling still has that neighbour"
else bad "a repository whose only edge is a coupling still has that neighbour" "$nn"; fi
# Opting out has to leave the prompt as it was before any of this existed.
noff="$(ng propose pack server --show-prompt --no-neighbours 2>&1 || true)"
if printf '%s' "$noff" | grep -q 'The workspace connects'; then
  bad "--no-neighbours reads only this repository" "$noff"
else ok "--no-neighbours reads only this repository"; fi
if printf '%s' "$noff" | grep -q 'cheapest correct home wins'; then
  ok "and the rest of the ask is untouched by either choice"
else bad "and the rest of the ask is untouched by either choice" "$noff"; fi
rm -rf "$NG"

# --show-prompt calls nothing, so it must not need permission
if DECK_AI_ASSIST=off "$DECK" propose pack a --show-prompt >/dev/null 2>&1; then
  ok "showing the prompt needs no permission"
else bad "showing the prompt needs no permission"; fi
check_fail "a pack proposal cannot be applied without --into" "$DECK" propose apply nope.json

# ---- a drafted finding is a decision or a question, never both
# The observed failure: a drafter found two code paths returning different status
# codes for the same refusal, said in its own notes it could not tell whether
# that was intentional or drift, and filed it as a TOGGLE. That turns "we do not
# know" into "we chose" and the doubt is gone. Half of the fix is in the prompt,
# and a prompt is free to check. The other half has to hold when the draft
# arrives anyway, so `apply` is handed hand-written JSON — no model involved.
note "a drafted finding is a decision or a question"
check "the prompt separates a toggle from a question" "A toggle and a question are not the same finding" \
  "$DECK" propose pack a --show-prompt
check "and says a toggle owes every value a defence" "for EVERY value in \`values\`" \
  "$DECK" propose pack a --show-prompt
check "and sends what it cannot explain to a question" "put it in \`questions\`" \
  "$DECK" propose pack a --show-prompt
check "and keeps \`unsure\` for the limits of its own reading" "limits of your own reading" \
  "$DECK" propose pack a --show-prompt

DP="$WS/draftpack"
"$DECK" pack new drafted --dir "$DP" >/dev/null
mkdir -p "$WS/.deck/proposals"

# A toggle whose values are bare names: two answers, no reason for either.
cat > "$WS/.deck/proposals/pack-bare.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"drafted_lint","title":"Lint","from_level":"static","command":"ruff check .","evidence":"ci.yml","confidence":"high"}],
"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],"rationale":"r","confidence":"high"}],
"questions":[],"unsure":[]}}
JSON
bare="$("$DECK" propose apply pack-bare.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$bare" | grep -q "REFUSED"; then
  ok "a toggle that defends neither value is refused"
else
  bad "a toggle that defends neither value is refused" "$bare"
fi
if printf '%s' "$bare" | grep -q "not one of its values is defended"; then
  ok "and the refusal names what is missing"
else
  bad "and the refusal names what is missing" "$bare"
fi
if grep -q "drafted_lint" "$DP/config/gates.yaml"; then
  bad "a refused draft writes nothing at all" "the gate landed anyway"
else
  ok "a refused draft writes nothing at all"
fi

# Half-defended is still not a decision: `409` has no reason to exist.
cat > "$WS/.deck/proposals/pack-half.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],
  "defends":{"400":"the caller sent something it could have got right"},"rationale":"r","confidence":"high"}],
"questions":[],"unsure":[]}}
JSON
half="$("$DECK" propose apply pack-half.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$half" | grep -q "does not say what defends .409."; then
  ok "a toggle that defends one value of two is refused, by name"
else
  bad "a toggle that defends one value of two is refused, by name" "$half"
fi

# Both values defended, and the same finding ALSO written down as something the
# draft could not explain. That is the draft having it both ways.
cat > "$WS/.deck/proposals/pack-mixed.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],
  "defends":{"400":"the caller sent something wrong","409":"the resource is in the wrong state"},
  "rationale":"r","confidence":"high"}],
"questions":[],
"unsure":["I could not tell whether the refusal status code split across the two handlers was intentional or drift."]}}
JSON
mixed="$("$DECK" propose apply pack-mixed.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$mixed" | grep -q "also filed as something the draft could not explain"; then
  ok "a finding filed as both a decision and a doubt is refused"
else
  bad "a finding filed as both a decision and a doubt is refused" "$mixed"
fi

# The shape the drafter should have produced: the choice it can defend is a
# toggle, the inconsistency it cannot is a question.
cat > "$WS/.deck/proposals/pack-sorted.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"drafted_lint","title":"Lint","from_level":"static","command":"ruff check .","evidence":"ci.yml","confidence":"high"}],
"rules":[],
"toggles":[{"id":"schema_compat","title":"Schema compatibility","summary":"s","values":["strict","breaking"],
  "defends":{"strict":"clients already deployed keep working across a release","breaking":"the contract gets fixed instead of carried forever"},
  "rationale":"r","confidence":"high"}],
"questions":[{"question":"Do the token path and the quota path refuse with the same status on purpose?",
  "context":"auth.py answers 403 and quota.py answers 429 for the same class of refusal.",
  "evidence":"src/auth.py:88, src/quota.py:41",
  "options":["make both 403","make both 429","they are deliberately different"]}],
"unsure":["b is empty"]}}
JSON
sorted_out="$("$DECK" propose apply pack-sorted.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$sorted_out" | grep -q "consultation "; then
  ok "an inconsistency the draft cannot explain becomes a consultation"
else
  bad "an inconsistency the draft cannot explain becomes a consultation" "$sorted_out"
fi
asked="$("$DECK" ask list 2>&1 || true)"
if printf '%s' "$asked" | grep -q "same status on purpose"; then
  ok "and it is open, waiting on a person"
else
  bad "and it is open, waiting on a person" "$asked"
fi
QID="$(printf '%s' "$asked" | grep -B1 "same status on purpose" | grep -oE '[0-9]{8}-[0-9]{6}-[a-z0-9-]+' | head -1)"
shown="$("$DECK" ask show "$QID" 2>&1 || true)"
if printf '%s' "$shown" | grep -q "src/auth.py:88"; then
  ok "and carries the files that disagree, so it can be answered"
else
  bad "and carries the files that disagree, so it can be answered" "$shown"
fi
# A regression guard, and it passes without the change too: a draft that sorts
# its findings correctly must go on applying exactly as it did.
if grep -q "drafted_lint" "$DP/config/gates.yaml"; then
  ok "a draft that sorts its findings still lands its gates"
else
  bad "a draft that sorts its findings still lands its gates"
fi
# Applying the same draft into a second pack must not ask the question twice —
# a consultation nobody answers twice as fast is just noise.
"$DECK" pack new drafted2 --dir "$WS/draftpack2" >/dev/null
"$DECK" propose apply pack-sorted.json --into "$WS/draftpack2" --confidence high >/dev/null 2>&1
count="$("$DECK" ask list --all 2>&1 | grep -c "same status on purpose" || true)"
if [ "$count" = "1" ]; then
  ok "and applying the draft again does not ask it twice"
else
  bad "and applying the draft again does not ask it twice" "asked $count time(s)"
fi
# A draft written before any of this: no `questions` key, no `defends`. It has
# nothing to sort wrongly, so it applies as it always did. Regression guard.
cat > "$WS/.deck/proposals/pack-older.json" <<'JSON'
{"kind":"pack","at":"2026-01-01T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"older_types","title":"Types","from_level":"static","command":"mypy .","evidence":"tox.ini","confidence":"high"}],
"rules":[],"toggles":[],"unsure":["nothing"]}}
JSON
older="$("$DECK" propose apply pack-older.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$older" | grep -q "older_types" || grep -q "older_types" "$DP/config/gates.yaml"; then
  ok "a draft predating the questions list still applies"
else
  bad "a draft predating the questions list still applies" "$older"
fi

# ---- a rule the pack holds and mount.yaml never names reaches nobody
# The observed failure: `apply` wrote five rule files into a pack, listed each
# one by name, and left `config/mount.yaml` untouched. `mount.yaml` is what
# decides which rules are placed, so the report read like delivery and nothing
# was delivered. Twenty-two rules across five packs, all inert.
note "a rule is a file and an entry"
MP="$WS/mountpack"
"$DECK" pack new mounted --dir "$MP" >/dev/null
cat > "$WS/.deck/proposals/pack-rules.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"toggles":[],"questions":[],"unsure":[],
"rules":[{"name":"Handlers validate at the edge","paths":["src/handlers/**"],
  "consequence":"Nothing below the handler re-checks shapes.","evidence":"src/handlers/base.py:20","confidence":"high"},
 {"name":"Migrations are forward only","paths":["migrations/**"],
  "consequence":"A down migration is never run in production.","evidence":"migrations/README:4","confidence":"high"}]}}
JSON
ruleout="$("$DECK" propose apply pack-rules.json --into "$MP" --confidence high --yes 2>&1 || true)"
mounted="$(grep -c '^  - .*file: rules/' "$MP/config/mount.yaml" 2>/dev/null || echo 0)"
if [ "$mounted" = "2" ]; then
  ok "a rule written into a pack is named in mount.yaml, so something places it"
else
  bad "a rule written into a pack is named in mount.yaml, so something places it" "$mounted entry(ies): $ruleout"
fi
if printf '%s' "$ruleout" | grep -q 'rule(s) -> config/mount.yaml'; then
  ok "and the report says the entries were written, not only the files"
else bad "and the report says the entries were written, not only the files" "$ruleout"; fi
if grep -q '#   - { file: rules/conventions.md }' "$MP/config/mount.yaml"; then
  ok "and the commented examples the template ships survive it"
else bad "and the commented examples the template ships survive it" "$(cat "$MP/config/mount.yaml")"; fi

# Applying twice must not list a rule twice: an entry deck already wrote is one
# a person may since have narrowed with `repos:`, and a duplicate would fight it.
"$DECK" propose apply pack-rules.json --into "$MP" --confidence high --yes >/dev/null 2>&1
again="$(grep -c '^  - .*file: rules/' "$MP/config/mount.yaml" 2>/dev/null || echo 0)"
if [ "$again" = "2" ]; then
  ok "and applying it again adds no second entry for the same rule"
else bad "and applying it again adds no second entry for the same rule" "$again entry(ies)"; fi

# The other half: whatever put it there, deck can see a rule nothing places.
ORPH="$WS/orphanpack"
"$DECK" pack new orphans --dir "$ORPH" >/dev/null
printf -- '---\npaths: ["src/**"]\n---\n\nSomething true about src.\n' > "$ORPH/rules/by-hand.md"
orph="$(env DECK_ROOT="$WS" DECK_PACKS="$ORPH" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$orph" | grep -q 'config/mount.yaml does not name'; then
  ok "deck doctor reports a rule the pack holds and mount.yaml does not name"
else bad "deck doctor reports a rule the pack holds and mount.yaml does not name" "$(printf '%s' "$orph" | head -8)"; fi
if printf '%s' "$orph" | grep -q 'rules/by-hand.md'; then
  ok "and names the file, so it can be listed or deleted"
else bad "and names the file, so it can be listed or deleted" "$orph"; fi
orph_line="$(printf '%s' "$orph" | grep 'does not name' || true)"
if printf '%s' "$orph_line" | grep -q '^  !! '; then
  ok "as a warning: a rule may be sitting there on purpose, and deck cannot tell"
else bad "as a warning: a rule may be sitting there on purpose, and deck cannot tell" "$orph_line"; fi
# The sample `pack new` ships is not a rule anyone forgot: it carries
# `paths: **/*.example` and exists to be read, so a fresh pack is quiet.
"$DECK" pack new quiet --dir "$WS/quietpack" >/dev/null
fresh="$(env DECK_ROOT="$WS" DECK_PACKS="$WS/quietpack" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$fresh" | grep -q 'does not name'; then
  bad "a pack nobody has filled in yet is not reported over its own sample" "$fresh"
else ok "a pack nobody has filled in yet is not reported over its own sample"; fi

# ------------------------------ an edge and a coupling are not one finding
# `impacts:` answers two questions with one edge — what must I revisit, and in
# what order. A pair that drives both ways answers the first and has no answer
# to the second, and before `couples:` existed a drafter had to discard one of
# the two directions to keep the graph acyclic; the discarded half survived as
# prose no command can read. The prompt now offers both kinds, and `apply`
# writes both. Nothing here calls a model: the wording is checked through
# --show-prompt, and `apply` is handed hand-written JSON.
note "an edge and a coupling"

check "the impacts prompt can propose a coupling" "reported in \`couplings\`" \
  "$DECK" propose impacts --show-prompt
check "and says when a coupling is right rather than an edge" "An edge and a coupling are not the same finding" \
  "$DECK" propose impacts --show-prompt
# The one that keeps a coupling from being the cheap answer: it costs a
# citation per direction, and a flag on an edge would have cost none.
check "and a coupling costs one citation in each direction" "one thing for EACH direction" \
  "$DECK" propose impacts --show-prompt
check "and evidence one way with a hunch the other stays an edge" "a hunch the other is an edge, not a coupling" \
  "$DECK" propose impacts --show-prompt
check "and one pair is never two edges facing each other" "Never report one pair as two edges" \
  "$DECK" propose impacts --show-prompt

EW="$(mktemp -d)/ws"
mkdir -p "$EW/.deck/proposals" "$EW"/{schema,runtime,tools}
for r in schema runtime tools; do git -C "$EW/$r" init -q 2>/dev/null; done
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$EW/.deck/toggles.yaml"
cat > "$EW/.deck/workspace.yaml" <<YAML
version: 1
repos:
  schema:  { path: schema,  role: state schema, impacts: [runtime] }
  runtime: { path: runtime, role: the scripts schema shells out to, impacts: [] }
  tools:   { path: tools,   role: shared helpers, impacts: [] }
targets: []
YAML
cp "$EW/.deck/workspace.yaml" "$EW/.deck/workspace.yaml.keep"
EDECK() { env DECK_ROOT="$EW" DECK_PACKS_ROOT="$PACKS" "$DECK" "$@"; }
ERESET() { cp "$EW/.deck/workspace.yaml.keep" "$EW/.deck/workspace.yaml"; }
# Did `runtime` end up coupled to `tools`, whichever side wrote it down?
ECOUPLED() {
  python3 - "$EW/.deck/workspace.yaml" <<'PY'
import sys, yaml
repos = (yaml.safe_load(open(sys.argv[1])) or {}).get("repos") or {}
pair = "tools" in (repos.get("runtime", {}).get("couples") or []) or "runtime" in (
    repos.get("tools", {}).get("couples") or []
)
sys.exit(0 if pair else 1)
PY
}

# The listing tells the drafter what is already declared, so it does not
# re-propose it. A coupling is symmetric, so the side that declared nothing has
# to be told too — otherwise it obeys the rule and proposes the pair again.
sed 's/role: shared helpers, impacts: \[\]/role: shared helpers, impacts: [], couples: [runtime]/' \
  "$EW/.deck/workspace.yaml.keep" > "$EW/.deck/workspace.yaml"
lst="$(EDECK propose impacts --show-prompt 2>&1 || true)"
ERESET
if printf '%s' "$lst" | grep -q "runtime:.*already coupled with: tools"; then
  ok "the listing shows a coupling to the side that never declared it"
else bad "the listing shows a coupling to the side that never declared it" "$(printf '%s' "$lst" | grep -i runtime | head -2)"; fi

# -- 1. an explicit coupling is written into the descriptor
cat > "$EW/.deck/proposals/impacts-coupling.json" <<'JSON'
{"kind":"impacts","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[],
"couplings":[{"a":"runtime","b":"tools",
  "why_a_to_b":"runtime/run.sh sources tools/lib.sh and calls fmt_row",
  "why_b_to_a":"tools/lib.sh parses runtime's --format flag, renamed twice already",
  "confidence":"high"}],
"unsure":[]}}
JSON
cpl="$(EDECK propose apply impacts-coupling.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$cpl" | grep -q "runtime <-> tools"; then
  ok "propose apply writes a coupling as well as an edge"
else bad "propose apply writes a coupling as well as an edge" "$cpl"; fi
if printf '%s' "$cpl" | grep -q "carries no order"; then
  ok "and says the thing it wrote claims no order"
else bad "and says the thing it wrote claims no order" "$cpl"; fi
if ECOUPLED; then
  ok "and the descriptor now holds \`couples:\`"
else bad "and the descriptor now holds \`couples:\`" "$(grep -A3 runtime "$EW/.deck/workspace.yaml")"; fi
acy="$(EDECK doctor 2>&1 || true)"
if printf '%s' "$acy" | grep -q "OK acyclic"; then
  ok "and the descriptor it produced is one doctor accepts"
else bad "and the descriptor it produced is one doctor accepts" "$(printf '%s' "$acy" | grep -i 'cycle\|coupling')"; fi
ERESET

# -- 2. a draft that names both directions is a coupling, not a refusal
# What a drafter with only `impacts:` produces when both directions have
# evidence. It used to be refused as a cycle, and the direction it could prove
# went in the bin with the one it could not.
cat > "$EW/.deck/proposals/impacts-bothways.json" <<'JSON'
{"kind":"impacts","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[{"from":"runtime","to":"tools","why":"runtime/run.sh sources tools/lib.sh","confidence":"high"},
         {"from":"tools","to":"runtime","why":"tools/lib.sh parses runtime's --format flag","confidence":"high"}],
"unsure":[]}}
JSON
bw="$(EDECK propose apply impacts-bothways.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$bw" | grep -q "REFUSED"; then
  bad "a draft naming both directions is not refused as a cycle" "$bw"
else ok "a draft naming both directions is not refused as a cycle"; fi
if ECOUPLED; then
  ok "and the pair lands as a coupling"
else bad "and the pair lands as a coupling" "$bw"; fi
if EDECK impact runtime --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "tools" not in d["impacted"] and d["coupled"]==["tools"] else 1)'; then
  ok "and neither \`impacts:\` half is written beside it"
else bad "and neither \`impacts:\` half is written beside it" "$(EDECK impact runtime --json | head -3)"; fi
ERESET

# -- 3. the confidence floor still decides what the draft asserts
# The fold runs after the filter, not before: a reverse edge the floor excluded
# was never asserted, so there is no pair to fold and the one direction that
# survived stays an ordered edge.
cat > "$EW/.deck/proposals/impacts-lopsided.json" <<'JSON'
{"kind":"impacts","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[{"from":"runtime","to":"tools","why":"runtime/run.sh sources tools/lib.sh","confidence":"high"},
         {"from":"tools","to":"runtime","why":"a hunch about the --format flag","confidence":"low"}],
"unsure":[]}}
JSON
lop="$(EDECK propose apply impacts-lopsided.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$lop" | grep -q "runtime -> tools"; then
  ok "a reverse edge below the floor leaves an ordered edge, not a coupling"
else bad "a reverse edge below the floor leaves an ordered edge, not a coupling" "$lop"; fi
if ECOUPLED; then
  bad "and no coupling is invented from the half that was left out" "$lop"
else ok "and no coupling is invented from the half that was left out"; fi
ERESET
low="$(EDECK propose apply impacts-lopsided.json --confidence low 2>&1 || true)"
if printf '%s' "$low" | grep -q "runtime <-> tools"; then
  ok "and lowering the floor to take both makes it the coupling instead"
else bad "and lowering the floor to take both makes it the coupling instead" "$low"; fi
ERESET

# -- 4. what a coupling may not do to a pair a person already ordered
# The fold is a thing a DRAFT does to its own two edges. An `impacts:` entry in
# the descriptor was written by a person, and deck does not overrule it from a
# proposal — nor write the pair both ways, which is a descriptor doctor refuses.
cat > "$EW/.deck/proposals/impacts-contra.json" <<'JSON'
{"kind":"impacts","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[],
"couplings":[{"a":"schema","b":"runtime",
  "why_a_to_b":"schema/state.yaml seeds the config runtime reads",
  "why_b_to_a":"runtime owns the command line schema shells out to",
  "confidence":"high"}],
"unsure":[]}}
JSON
contra="$(EDECK propose apply impacts-contra.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$contra" | grep -q "REFUSED"; then
  ok "a coupling over a pair the descriptor already orders is refused"
else bad "a coupling over a pair the descriptor already orders is refused" "$contra"; fi
if printf '%s' "$contra" | grep -q "drop the"; then
  ok "and the refusal carries the edit that resolves it"
else bad "and the refusal carries the edit that resolves it" "$contra"; fi
if grep -q couples "$EW/.deck/workspace.yaml"; then
  bad "and a refused proposal writes nothing" "$(grep -n couples "$EW/.deck/workspace.yaml")"
else ok "and a refused proposal writes nothing"; fi
ERESET

# -- 5. a cycle is still a cycle when only the draft's half is new
# Regression guard, and the point of the whole issue: two `impacts:` edges
# between one pair stay refused. Only a DRAFT that owns both of them is folded.
cat > "$EW/.deck/proposals/impacts-cycle.json" <<'JSON'
{"kind":"impacts","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[{"from":"runtime","to":"schema","why":"runtime regenerates schema/state.yaml","confidence":"high"}],
"unsure":[]}}
JSON
cyc="$(EDECK propose apply impacts-cycle.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$cyc" | grep -q "REFUSED"; then
  ok "an edge closing a cycle with a declared edge is still refused"
else bad "an edge closing a cycle with a declared edge is still refused" "$cyc"; fi
if printf '%s' "$cyc" | grep -q "put \`couples:"; then
  ok "and the refusal names the field that records it without an order"
else bad "and the refusal names the field that records it without an order" "$cyc"; fi
ERESET

# -- 6. a proposal written before any of this still applies. Regression guard.
cat > "$EW/.deck/proposals/impacts-older.json" <<'JSON'
{"kind":"impacts","at":"2026-01-01T00:00:00","cost":{},"prompt":"x","proposal":{
"edges":[{"from":"tools","to":"schema","why":"schema/gen.py imports tools.fmt","confidence":"high"}],
"unsure":["nothing"]}}
JSON
old="$(EDECK propose apply impacts-older.json --confidence high --yes 2>&1 || true)"
if printf '%s' "$old" | grep -q "tools -> schema"; then
  ok "a proposal with no couplings list applies exactly as it did"
else bad "a proposal with no couplings list applies exactly as it did" "$old"; fi
ERESET
rm -rf "$(dirname "$EW")"

note "cost reporting"
FAKE_HOME="$WS/fakehome"
# The transcript has to sit in the project directory Claude Code would name for
# this workspace, because `deck cost` is scoped to the workspace — reading every
# project on the machine is how a task's bill became an unrelated session's.
SLUG="$(printf '%s' "$WS" | sed 's/[^A-Za-z0-9-]/-/g')"
mkdir -p "$FAKE_HOME/.claude/projects/$SLUG"
cat > "$FAKE_HOME/.claude/projects/$SLUG/sess-1.jsonl" <<'JSONL'
{"timestamp":"2026-01-01T10:00:00.000Z","sessionId":"sess-1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":10000,"cache_creation":{"ephemeral_5m_input_tokens":4000,"ephemeral_1h_input_tokens":0}}}}
{"timestamp":"2026-01-01T10:00:01.000Z","sessionId":"sess-1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":10000}}}
{"timestamp":"2026-01-01T12:00:00.000Z","sessionId":"sess-1","message":{"id":"m2","model":"claude-haiku-4-5","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0}}}
{"timestamp":"2026-01-01T13:00:00.000Z","sessionId":"sess-1","message":{"id":"m3","model":"model-nobody-priced","usage":{"input_tokens":10,"output_tokens":10}}}
JSONL

# A workflow's agents write under <project>/<session>/subagents/..., and those
# are real tokens on a real bill. Counting only the top level made a board run
# of eleven agents invisible.
mkdir -p "$FAKE_HOME/.claude/projects/$SLUG/sess-1/subagents/workflows/wf-x"
cat > "$FAKE_HOME/.claude/projects/$SLUG/sess-1/subagents/workflows/wf-x/agent-1.jsonl" <<'JSONL'
{"timestamp":"2026-01-01T11:00:00.000Z","sessionId":"sess-1","message":{"id":"sub1","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":13,"cache_read_input_tokens":0}}}
JSONL

costjson() { HOME="$FAKE_HOME" "$DECK" cost --session sess-1 --json "$@"; }

# The scoping itself: a transcript belonging to a different project must not be
# picked up, however recent it is.
mkdir -p "$FAKE_HOME/.claude/projects/-somewhere-else"
cp "$FAKE_HOME/.claude/projects/$SLUG/sess-1.jsonl" "$FAKE_HOME/.claude/projects/-somewhere-else/sess-9.jsonl"
out="$(HOME="$FAKE_HOME" "$DECK" cost --session sess-9 2>&1 || true)"
if printf '%s' "$out" | grep -q "no transcript named sess-9"; then
  ok "another project's session is out of scope"
else bad "another project's session is out of scope" "$out"; fi
if HOME="$FAKE_HOME" "$DECK" cost --session sess-9 --any-project --json >/dev/null 2>&1; then
  ok "--any-project widens it deliberately"
else bad "--any-project widens it deliberately"; fi

if HOME="$FAKE_HOME" "$DECK" cost --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["output"]>=13 else 1)'; then
  ok "a workflow agent's tokens are counted"
else bad "a workflow agent's tokens are counted"; fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["messages"]==3 else 1)'; then
  ok "a streamed message is counted once"
else
  bad "a streamed message is counted once" "$(costjson | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["output"]==2110 else 1)'; then
  ok "output tokens add up across models"
else
  bad "output tokens add up across models"
fi
# opus-5: 1000*5 + 2000*25 + 4000*5*1.25 + 10000*5*0.1 = 85000 / 1e6 = 0.085
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if abs(d["models"]["claude-opus-5"]["usd"]-0.085)<1e-6 else 1)'; then
  ok "cache write and read are priced by their multipliers"
else
  bad "cache write and read are priced by their multipliers"
fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["models"]["model-nobody-priced"]["usd"] is None and d["total"]["priced"] is False else 1)'; then
  ok "an unpriced model is reported, not guessed at"
else
  bad "an unpriced model is reported, not guessed at"
fi
if costjson --since 2026-01-01T11:00:00Z | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["messages"]==2 else 1)'; then
  ok "a window excludes what falls outside it"
else
  bad "a window excludes what falls outside it"
fi
check "dollars are labelled an estimate" "ESTIMATE" env HOME="$FAKE_HOME" "$DECK" cost --session sess-1
if costjson --since 2026-01-01T11:00:00 | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "+" in d["window"] or "-0" in d["window"] else 1)'; then
  ok "a zoneless timestamp is echoed with the zone it was read as"
else
  bad "a zoneless timestamp is echoed with the zone it was read as"
fi
check_fail "an unreadable timestamp is refused" env HOME="$FAKE_HOME" "$DECK" cost --session sess-1 --since nonsense
if HOME="$FAKE_HOME" "$DECK" cost --task NOPE >/dev/null 2>&1; then
  bad "a task with no window is refused"
else
  ok "a task with no window is refused"
fi

note "status line"
if printf '{"context_window":{"used_percentage":34}}' | "$DECK" statusline --no-color | head -1 | grep -q "$(basename "$WS")"; then
  ok "renders the workspace root"
else
  bad "renders the workspace root"
fi
if printf 'not json at all' | "$DECK" statusline --no-color >/dev/null 2>&1; then
  ok "invalid stdin does not break the bar"
else
  bad "invalid stdin does not break the bar"
fi
check "prints the settings snippet" "statusLine" "$DECK" statusline --settings
# What makes a status line slow is what it DOES on every prompt, not how long a
# cold interpreter takes to start. The old check timed the whole process against
# 250 ms of wall clock, which on a loaded machine measured Python's start-up:
# the work itself is around 40 ms, and the check reddened the ladder of a task
# that had not touched it. Assert the work instead — it holds on any machine.
sl="$(cd "$REPO/plugins/deck" && DECK_ROOT="$WS" python3 -c "
import socket, subprocess, sys, time
calls = []
socket.socket = lambda *a, **k: sys.exit('statusline opened a socket')
real = subprocess.run
subprocess.run = lambda cmd, *a, **k: (calls.append(cmd[0] if cmd else '?'), real(cmd, *a, **k))[1]
from deck.statusline import render
t = time.time(); render({}, color=False); ms = (time.time() - t) * 1000
print('subprocesses', len(calls), ','.join(sorted(set(calls))))
print('work_ms', int(ms))
" 2>&1)"
# Four today, and three of them are the same `tmux display-message` asking the
# same question — see the issue this number is pinned against. The point of
# pinning it is that the next thing added per prompt has to move this line and
# say why, which a wall-clock budget on a fast laptop never made anyone do.
if printf '%s' "$sl" | grep -qE "^subprocesses [0-4] "; then
  ok "the status line spawns no more processes per prompt than it did"
else
  bad "the status line spawns no more processes per prompt than it did" "$sl"
fi
if printf '%s' "$sl" | grep -q "opened a socket"; then
  bad "and reaches no network" "$sl"
else
  ok "and reaches no network"
fi
if [ "$(printf '%s' "$sl" | awk '/^work_ms/{print $2}')" -lt 250 ] 2>/dev/null; then
  ok "and the work it does stays well inside a prompt"
else
  bad "and the work it does stays well inside a prompt" "$sl"
fi

note "which deck did it"
# The first question about anything deck did. The number lives in the plugin
# manifest, because Claude Code reads that file without running anything, and
# Python reads it from there — two copies of one number is how they drift, and
# this repository has already lost that argument over a check total stated in
# five documents and gated in four.
check "--version answers" "deck 0." "$DECK" --version
check "and doctor carries it, since a diagnosis is what gets pasted" "OK deck" "$DECK" doctor

ver="$(cd "$REPO/plugins/deck" && python3 -c "
import json, pathlib, sys
sys.path.insert(0, '.')
import deck
manifest = json.loads(pathlib.Path('.claude-plugin/plugin.json').read_text())
print('same' if deck.__version__ == manifest['version'] else f\"drifted: {deck.__version__} != {manifest['version']}\")
")"
if [ "$ver" = "same" ]; then
  ok "the package and the manifest cannot disagree about the version"
else
  bad "the package and the manifest cannot disagree about the version" "$ver"
fi

# A clone with no manifest is broken; deck says so rather than inventing one.
noman="$(cd "$REPO/plugins/deck" && python3 -c "
import importlib, pathlib, sys, tempfile, shutil
tmp = tempfile.mkdtemp()
shutil.copytree('deck', pathlib.Path(tmp) / 'deck')
sys.path.insert(0, tmp)
for m in [k for k in sys.modules if k == 'deck' or k.startswith('deck.')]:
    del sys.modules[m]
import deck as broken
print(broken.__version__)
")"
if [ "$noman" = "unknown" ]; then
  ok "a clone that cannot read its manifest says unknown, never a plausible number"
else
  bad "a clone that cannot read its manifest says unknown, never a plausible number" "$noman"
fi

note "console"
check "one-shot status"       "root"       "$DECK" console -c status
check "asks lists the options" "deploy_mode" "$DECK" console -c "asks verify"
check "unknown command warns" "unknown"    "$DECK" console -c "nosuchthing"

note "split screen"
if command -v tmux >/dev/null; then
  check "plan outside tmux"  "new-session"  env -u TMUX "$DECK" ui --dry-run
  check_fail "width outside the range is refused" "$DECK" ui --dry-run --width 5

  # An existing session is the normal case, not an error: the first run builds
  # it, the attach fails for want of a terminal, and every run after that used
  # to die on `duplicate session`.
  RS="deck-reuse-$$"
  tmux kill-session -t "$RS" 2>/dev/null
  # `--agent-cmd`: the left pane runs `claude` by default, which does not exist
  # on a CI runner, so the session died before the split and took three checks
  # with it. What is under test is deck's session handling.
  env -u TMUX "$DECK" ui --session "$RS" --agent-cmd "sleep 60" >/dev/null 2>&1
  if tmux has-session -t "$RS" 2>/dev/null; then ok "a detached run builds the session"; else bad "a detached run builds the session"; fi
  out="$(env -u TMUX "$DECK" ui --session "$RS" --agent-cmd "sleep 60" 2>&1)"
  if printf '%s' "$out" | grep -q "already up"; then ok "a second run reuses it instead of failing"; else bad "a second run reuses it instead of failing" "$out"; fi
  if printf '%s' "$out" | grep -q "tmux attach -t $RS"; then ok "and says how to reach it"; else bad "and says how to reach it" "$out"; fi
  pop="$(env -u TMUX "$DECK" ui --popup --session "$RS" --agent-cmd "sleep 60" 2>&1 || true)"
  if printf '%s' "$pop" | grep -q "already up"; then ok "popup outside tmux points at the live session"; else bad "popup outside tmux points at the live session" "$pop"; fi
  tmux kill-session -t "$RS" 2>/dev/null
  S="deck-smoke-$$"
  tmux kill-session -t "$S" 2>/dev/null
  tmux new-session -d -s "$S" -x 160 -y 24 -c "$WS" bash
  sleep 1
  tmux split-window -h -f -t "$S": -c "$WS" \
    "bash -c 'DECK_ROOT=$WS $DECK toggle --session pair set deploy_mode packaged >/dev/null; sleep 30'"
  sleep 2
  OUT="$WS/shared.txt"
  tmux send-keys -t "$(tmux list-panes -t "$S": -F '#{pane_id}' | head -1)" \
    "DECK_ROOT=$WS $DECK toggle --session pair get deploy_mode > $OUT" Enter
  sleep 3
  if [ "$(cat "$OUT" 2>/dev/null)" = "packaged" ]; then
    ok "panes of one window share the task scope"
  else
    bad "panes of one window share the task scope" "got: $(cat "$OUT" 2>/dev/null)"
  fi
  tmux kill-session -t "$S" 2>/dev/null
else
  # Eight checks live above. Named one by one rather than as a count, so the
  # summary says what could not run here instead of only how many.
  skip "plan outside tmux — tmux not on PATH"
  skip "width outside the range is refused — tmux not on PATH"
  skip "a detached run builds the session — tmux not on PATH"
  skip "a second run reuses it instead of failing — tmux not on PATH"
  skip "popup outside tmux points at the live session — tmux not on PATH"
  skip "the console writes through to the toggle — tmux not on PATH"
  skip "panes of one window share the task scope — tmux not on PATH"
  skip "and says how to reach it — tmux not on PATH"
fi

# `setup --dry-run` is the discovery pass: it must run on a workspace that
# already has a descriptor, and it must write nothing.
before="$(cat "$WS/.deck/workspace.yaml")"
check "discovery runs on a configured workspace" "Nothing written" "$DECK" setup --dry-run --root "$WS"
check "and reports what it found" "What is in this workspace" "$DECK" setup --dry-run --root "$WS"
if [ "$before" = "$(cat "$WS/.deck/workspace.yaml")" ]; then ok "discovery changed nothing"; else bad "discovery changed nothing"; fi

# ------------------------------------------------------ pack scope, layering
# A collection is layered whether or not anyone calls it that: a shared pack
# under every repository, and one pack per repository on top. These check that
# the layers keep to their own scope and that a collision is refused rather
# than resolved by luck.
note "pack scope and layering"
LW="$(mktemp -d)/ws"; LP="$(mktemp -d)/packs"
mkdir -p "$LW"/{one,two} "$LW/.deck" "$LP"/one/config "$LP"/two/{config,rules} "$LP"/_workspace/config
cat > "$LW/.deck/workspace.yaml" <<EOF
packs_root: [$LP]
repos:
  one: { path: one, impacts: [] }
  two: { path: two, impacts: [] }
targets: []
EOF
printf 'gates:\n  - { id: build, title: One, from_level: build, per_repo: "true" }\n' > "$LP/one/config/gates.yaml"
printf 'gates:\n  - { id: build, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/two/config/gates.yaml"
echo "a convention that belongs to two" > "$LP/two/rules/local.md"
printf 'rules:\n  - { file: rules/local.md }\n' > "$LP/two/config/mount.yaml"

SAVED_ROOT="${DECK_ROOT:-}"; SAVED_PACKS_ROOT="${DECK_PACKS_ROOT:-}"
export DECK_ROOT="$LW"; unset DECK_PACKS_ROOT DECK_PACKS
{
  check_fail "a reused gate id is refused, not run twice" "$DECK" gate list

  printf 'gates:\n  - { id: build, overrides: true, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/two/config/gates.yaml"
  check "overrides: true merges the two" "Two" "$DECK" gate list
  out="$("$DECK" gate list 2>&1)"
  if [ "$(printf '%s' "$out" | grep -cE '^ +(->|--) +build ')" = 1 ]; then ok "the merged gate appears once"; else bad "the merged gate appears once"; fi

  printf 'gates:\n  - { id: buildtwo, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/two/config/gates.yaml"
  out="$("$DECK" gate list --repos one 2>&1)"
  if printf '%s' "$out" | grep -q "buildtwo.*skipped"; then ok "a repo pack's gate stays in its own repo"; else bad "a repo pack's gate stays in its own repo" "$out"; fi
  check "and runs for the repository that owns it" "over two" "$DECK" gate list --repos two

  out="$("$DECK" mount --task scope --repos one --dry-run 2>&1)"
  if printf '%s' "$out" | grep -q "local.md"; then bad "a repo pack's rule stays in its own repo" "$out"; else ok "a repo pack's rule stays in its own repo"; fi
  check "and mounts into the repository that owns it" "local.md" "$DECK" mount --task scope --repos two --dry-run

  # ---- named layers, declared order, and directories outside the tree.
  # A domain pack is named after no repository, so it can only arrive through
  # `packs:` in the descriptor. It is deliberately listed AFTER the pack that
  # requires it, so the order below can only come from `requires:`.
  mkdir -p "$LP"/yocto-base/config "$LP"/org-acme/config "$LW/../outside/scripts" "$LW/../outside/tools"
  git -C "$LW/../outside/tools" init -q
  printf 'echo built\n' > "$LW/../outside/scripts/build.sh"; chmod +x "$LW/../outside/scripts/build.sh"
  printf 'gates:\n  - { id: bake, title: Domain, from_level: build, per_repo: "bitbake ${repo.build_target}" }\n' > "$LP/yocto-base/config/gates.yaml"
  printf 'requires:\n  - yocto-base\n' > "$LP/org-acme/config/detect.yaml"
  printf 'gates:\n  - { id: bake, overrides: true, title: Org, per_repo: "${path.scripts}/build.sh ${repo.build_target}" }\n' > "$LP/org-acme/config/gates.yaml"
  cat > "$LW/.deck/workspace.yaml" <<EOF
packs_root: [$LP]
packs: [$LP/org-acme, $LP/yocto-base]
paths:
  scripts: ../outside/scripts
repos:
  one:   { path: one, build_target: img1, impacts: [] }
  two:   { path: two, build_target: img2, impacts: [] }
  tools: { path: ../outside/tools, impacts: [] }
targets: []
EOF
  check "a pack named in the descriptor is loaded" "yocto-base" "$DECK" packs
  out="$("$DECK" packs 2>&1)"
  if [ "$(printf '%s' "$out" | grep -nE '^  [0-9]+  (yocto-base|org-acme)' | head -1 | grep -c yocto-base)" = 1 ]; then
    ok "requires puts a domain pack ahead of what requires it"
  else bad "requires puts a domain pack ahead of what requires it" "$out"; fi
  check "the overlay is reported" "yocto-base -> org-acme" "$DECK" packs
  check "the later layer wins the gate" "Org" "$DECK" gate list --repos one
  check "a path outside the tree resolves in a command" "outside/scripts/build.sh img1" "$DECK" gate run --repos one --dry-run
  check "a repository outside the root resolves" "outside/tools" "$DECK" path tools
  check "declared paths are listed" "scripts" "$DECK" paths

  printf 'requires:\n  - nowhere\n' > "$LP/org-acme/config/detect.yaml"
  check_fail "an unmet pack requirement is a problem" "$DECK" packs
  # doctor exits non-zero here for unrelated reasons — this workspace has no
  # toggle file — so assert on what it says rather than on its status.
  out="$("$DECK" doctor 2>&1)"
  if printf '%s' "$out" | grep -q "not in play"; then ok "and doctor names it"; else bad "and doctor names it" "$out"; fi

  # A name two packs both claim was reported by `deck setup` and by nothing
  # else, while one of the two won on the order `iterdir()` handed the
  # directories back. Both documents say deck reports it and resolves nothing.
  mkdir -p "$LP/group/one/config"
  printf 'markers: []\n' > "$LP/group/one/config/detect.yaml"
  dup_packs="$("$DECK" packs 2>&1 || true)"
  if printf '%s' "$dup_packs" | grep -q 'two packs claim `one`'; then
    ok "two packs claiming one repository is reported by deck packs"
  else bad "two packs claiming one repository is reported by deck packs" "$dup_packs"; fi
  dup_doctor="$("$DECK" doctor 2>&1 || true)"
  if printf '%s' "$dup_doctor" | grep -q 'Rename one, or drop it from the collection'; then
    ok "and by the diagnosis, with the edit that resolves it"
  else bad "and by the diagnosis, with the edit that resolves it" "$dup_doctor"; fi
  rm -rf "$LP/group"
}
export DECK_ROOT="$SAVED_ROOT" DECK_PACKS_ROOT="$SAVED_PACKS_ROOT"
rm -rf "$LW" "$LP"

# ------------------------------------------------------------------ monorepo
# One repository whose real units of change are its packages. The engine does
# not care whether a unit is a checkout or a directory — but git hygiene does,
# because every package shares one .git.
note "monorepo"
MR="$(mktemp -d)/mono"
mkdir -p "$MR"/packages/{schema,api} "$MR/apps/cli"
git -C "$(dirname "$MR")" init -q 2>/dev/null || true
git init -q "$MR"
for d in packages/schema packages/api apps/cli; do
  printf '[project]\nname = "x"\n' > "$MR/$d/pyproject.toml"
  echo "# x" > "$MR/$d/README.md"
done
git -C "$MR" add -A
git -C "$MR" -c user.email=a@b -c user.name=a commit -qm init

# setup --dry-run stops at step 2 without a packs root, so it exits non-zero by
# design; assert on what it says.
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" setup --dry-run 2>&1 || true)"
if printf '%s' "$out" | grep -q "3 packages"; then ok "packages are found, not one repository"; else bad "packages are found, not one repository" "$out"; fi
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" setup --packs-root "$MR/ai-packs" --create-packs >/dev/null 2>&1
check "each package becomes a unit" "packages/schema" env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" repos --verbose
if git -C "$MR" check-ignore -q .deck/; then ok ".deck is hidden from the product repository"; else bad ".deck is hidden from the product repository"; fi

# An edge, so a mount reaches more than one package and the exclude file has to
# carry a block for each.
python3 - "$MR/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["repos"]["schema"]["impacts"] = ["api"]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
printf 'rules:\n  - { file: rules/example.md }\n' > "$MR/ai-packs/_workspace/config/mount.yaml"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" mount --task mono --repos schema >/dev/null 2>&1
dirty="$(git -C "$MR" status --short | grep -c '\.claude' || true)"
if [ "$dirty" = "0" ]; then ok "mounted artifacts never reach git status"; else bad "mounted artifacts never reach git status" "$dirty path(s) visible"; fi
blocks="$(grep -c 'deck: begin' "$MR/.git/info/exclude" || true)"
if [ "$blocks" -ge 3 ]; then ok "every package gets its own exclude block"; else bad "every package gets its own exclude block" "$blocks block(s)"; fi
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" unmount --task mono >/dev/null 2>&1
left="$(grep -c 'deck: begin mono' "$MR/.git/info/exclude" || true)"
if [ "$left" = "0" ]; then ok "unmount takes every block with it"; else bad "unmount takes every block with it" "$left left"; fi
rm -rf "$MR"

# A ladder that climbed inside a subset reports the same green as one that
# covered the registry. Which it was has to be in the evidence, not inferred.
mkdir -p "$WS/.deck"
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {"half": {"title": "Half", "repos": ["a"]}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
"$DECK" --scope half gate run --task SC1 --level static >/dev/null 2>&1 || true
if [ -f "$WS/.deck/gates/SC1.json" ]; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("scope")=="half" and d.get("registry_repos") else 1)' "$WS/.deck/gates/SC1.json"; then
    ok "the evidence records the scope it ran inside"
  else bad "the evidence records the scope it ran inside"; fi
  check "and the report says how much it covered" "of 3 repositories" "$DECK" gate report --task SC1
  check "and names what it did not cover" "still have to keep up" "$DECK" gate report --task SC1
else
  bad "the evidence records the scope it ran inside" "no evidence written"
fi
out="$("$DECK" gate run --task SC2 --level static >/dev/null 2>&1; python3 -c 'import json;print(json.load(open("'"$WS"'/.deck/gates/SC2.json")).get("scope"))')"
if [ "$out" = "None" ]; then ok "a run outside any scope records none"; else bad "a run outside any scope records none" "$out"; fi

# Regressions from a code review of the scopes work. Each was a claim the tool
# made that was not true.
# `c` is a leaf: --repos expands through the graph, so a repository with edges
# would legitimately cover more than it names.
"$DECK" gate run --task RC1 --repos c --level static >/dev/null 2>&1 || true
"$DECK" gate run --task RC2 --level static >/dev/null 2>&1 || true
if python3 - "$WS/.deck/gates/RC1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("covered_repos") == ["c"] and len(d.get("registry_repos") or []) > 1 else 1)
PY
then ok "evidence records what --repos actually gated"; else bad "evidence records what --repos actually gated"; fi
check "a partial run says how much it covered" "of 3 repositories" "$DECK" gate report --task RC1
out="$("$DECK" gate report --task RC2 2>&1 | head -2 | tail -1)"
if printf '%s' "$out" | grep -q "repositories"; then
  bad "a full run does not announce a coverage it did not narrow" "$out"
else ok "a full run does not announce a coverage it did not narrow"; fi
if python3 - <<'PY'
import re, sys
p = "(^|[^A-Za-z0-9_-])" + re.escape("T-1") + "([^A-Za-z0-9_-]|$)"
sys.exit(0 if re.search(p, "fix: T-1 thing") and not re.search(p, "fix: T-10 other") else 1)
PY
then ok "a task id does not match a longer one that starts with it"; else bad "a task id does not match a longer one that starts with it"; fi
if python3 -c 'r=[1,2,3]; import sys; sys.exit(0 if (r[-0:] if 0 else [])==[] else 1)'; then
  ok "a limit of zero shows nothing, not everything"
else bad "a limit of zero shows nothing, not everything"; fi
if grep -q -- "--at workspace" "$REPO/plugins/deck/skills/toggles/SKILL.md" &&
   ! grep -q -- "--scope workspace" "$REPO/plugins/deck/skills/toggles/SKILL.md"; then
  ok "the toggles skill teaches a flag that exists"
else bad "the toggles skill teaches a flag that exists"; fi
if python3 - "$REPO/plugins/deck/workflows/board.js" <<'PY'
import sys, pathlib
t = pathlib.Path(sys.argv[1]).read_text()
sys.exit(0 if t.index("deck bundle --task") < t.index("deck board done") else 1)
PY
then ok "the workflow bundles before it closes, as the skill says"; else bad "the workflow bundles before it closes, as the skill says"; fi

# Second review pass. Each was a claim the tool made that was not true.
# Exercised, not grepped: the console builds an argv and hands it to the CLI, so
# only running it proves the flag it builds is one the CLI accepts.
"$DECK" console -c "set gate_level deploy workspace" >/dev/null 2>&1 || true
check "the console writes through to the toggle" "workspace" "$DECK" toggle explain gate_level
"$DECK" gate run --task RB1 --repos c --level static >/dev/null 2>&1 || true
# bundle exits non-zero for unrelated reasons here (a tracker source declared
# earlier is unreachable), so assert on what it says.
out="$("$DECK" bundle --task RB1 2>&1 || true)"
if printf '%s' "$out" | grep -q "were not covered"; then
  ok "a bundle says a run covered less than the registry"
else bad "a bundle says a run covered less than the registry" "$out"; fi
out="$("$DECK" bundle --task RB1 2>&1 || true)"
if printf '%s' "$out" | grep -q "still has RB1 as .unknown"; then
  bad "a task no board holds is not also reported as a board state" "$out"
else ok "a task no board holds is not also reported as a board state"; fi
# Not `grep "capped at"`: that passes on a half-fix, and did. Both branches that
# build a basis have to carry the note, so exercise the function itself.
if python3 - "$REPO" <<'PY'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "plugins" / "deck"))
from deck import bundle as b
over = {"r": list(range(b.COMMIT_LIMIT))}
under = {"r": [1]}
ok = (
    "capped at" in b._basis(True, "named", over)["text"]
    and "capped at" in b._basis(False, "windowed", over)["text"]
    and "capped at" not in b._basis(False, "windowed", under)["text"]
)
sys.exit(0 if ok else 1)
PY
then ok "the commit cap is said on every basis, not just the exact one"
else bad "the commit cap is said on every basis, not just the exact one"; fi
if grep -q "except subprocess.TimeoutExpired" "$REPO/plugins/deck/deck/cmd_pack.py"; then
  ok "a clone that times out is reported, not fatal"
else bad "a clone that times out is reported, not fatal"; fi
if grep -q "scopes:. here" "$REPO/plugins/deck/templates/workspace/toggles.yaml"; then
  ok "the template documents the scope layer it inserts"
else bad "the template documents the scope layer it inserts"; fi
# A workspace that contains the deck running it: an agent editing it breaks the
# tool mid-task, including the gates that would have caught the break. The real
# case is this repository, so use it rather than faking one — a copied entry
# point does not import its own package and would test nothing.
out="$(DECK_ROOT="$REPO" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "self-hosting"; then ok "a workspace holding its own deck is reported"; else bad "a workspace holding its own deck is reported" "$out"; fi
if printf '%s' "$out" | grep -q "Work on a copy"; then ok "and it names what to do instead"; else bad "and it names what to do instead" "$out"; fi
out="$(DECK_ROOT="$WS" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "self-hosting"; then bad "an ordinary workspace is not accused"; else ok "an ordinary workspace is not accused"; fi

# The prose rule says a user-visible change updates the documents. Half of that
# is judgement; the other half is a fact a machine can check, so it is checked.
if python3 "$REPO/packs/_workspace/bin/docs-cover.py" >/dev/null 2>&1; then
  ok "every command deck exposes is named in the documents"
else bad "every command deck exposes is named in the documents" "$(python3 "$REPO/packs/_workspace/bin/docs-cover.py" 2>&1 | head -3)"; fi
# A document naming a deleted file is the same failure as one naming a renamed
# command, and it went uncaught: the README offered a recording that had been
# removed for carrying a machine's session name through into its output.
if python3 - "$REPO" <<'PY'
import sys, pathlib, importlib.util
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dc", root / "packs/_workspace/bin/docs-cover.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
gone = m.dangling_paths("see `asciinema play docs/tour.cast` for the recording")
here = m.dangling_paths("run `./ci/smoke.sh` and read `docs/tour.sh`")
sys.exit(0 if gone == ["docs/tour.cast"] and here == [] else 1)
PY
then ok "a document pointing at a file that is gone is reported"
else bad "a document pointing at a file that is gone is reported"; fi

# The count gate is what catches a stale total, and it had two holes: it read
# five documents while six state the number, and its pattern took exactly three
# digits, so it would have gone quiet the day the suite passed 999 and reported
# success over whatever the documents last said.
dc="$(cd "$REPO" && python3 -c "
import importlib.util, re
spec = importlib.util.spec_from_file_location('dc', 'packs/_workspace/bin/docs-cover.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('contributing', 'CONTRIBUTING.md' in m.DOCS)
print('wide', re.findall(m.COUNT, 'the suite has 1431 checks'))
")"
if printf '%s' "$dc" | grep -q "^contributing True$"; then
  ok "every document that states the check total is read"
else
  bad "every document that states the check total is read" "$dc"
fi
if printf '%s' "$dc" | grep -q "^wide \['1431'\]$"; then
  ok "a total past 999 is still read, not silently ignored"
else
  bad "a total past 999 is still read, not silently ignored" "$dc"
fi

# The briefing half of a board item: what it is for, and how anyone would know
# it worked. The ladder proves the code holds together and decides nothing about
# whether it is the thing that was asked for.
python3 - "$WS/.deck/board.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["tasks"].append({"id": "AC-9", "title": "with criteria", "repos": ["a"], "status": "open",
                   "as_a": "someone judging a delivery", "so_that": "green means what was asked for",
                   "acceptance": ["the first thing", "the second thing"]})
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check "a board item carries what it is for" "so that" "$DECK" board show AC-9
check "and its definition of done" "0 of 2 accepted" "$DECK" board show AC-9
"$DECK" gate run --task AC-9 --level static --only lint >/dev/null 2>&1 || true
check_fail "closing refuses while a criterion is unaccepted" "$DECK" board done AC-9 --yes
out="$("$DECK" board done AC-9 --accept "the first thing" --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "1 not accepted"; then ok "accepting one leaves the other"; else bad "accepting one leaves the other" "$out"; fi
out="$("$DECK" bundle --task AC-9 2>&1 || true)"
if printf '%s' "$out" | grep -q "acceptance criteria are not accepted"; then
  ok "a bundle blocks on criteria the ladder cannot decide"
else bad "a bundle blocks on criteria the ladder cannot decide" "$out"; fi
check "closing takes both" "closed AC-9" "$DECK" board done AC-9 --accept "the first thing" --accept "the second thing" --yes
check "the template names what earns its place" "acceptance" "$DECK" board template

# A pack declares its adapter relative to the workspace root, like every other
# pack path. Running it from wherever the process happens to sit made it work
# only when the operator was already standing in the right directory.
mkdir -p "$WS/tools"
cat > "$WS/tools/adapter.sh" <<'SH'
#!/usr/bin/env bash
# Proves the cwd: a relative path only resolves from the root.
test -f .deck/workspace.yaml || { echo "not at the root" >&2; exit 3; }
echo '{"tasks":[{"id":"REL-1","title":"found from the root","repos":["a"]}]}'
SH
chmod +x "$WS/tools/adapter.sh"
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "adapted", "command": "tools/adapter.sh"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
( cd / && check "an adapter runs from the workspace root, not the caller's" "REL-1" "$DECK" board list )
cat > "$WS/tools/adapter.sh" <<'SH'
#!/usr/bin/env bash
echo "the roadmap file moved" >&2
exit 4
SH
chmod +x "$WS/tools/adapter.sh"
out="$("$DECK" board list 2>&1 || true)"
if printf '%s' "$out" | grep -q "exit 4"; then ok "an adapter that fails says why, not just that it found nothing"; else bad "an adapter that fails says why, not just that it found nothing" "$out"; fi
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
rm -f "$WS/tools/adapter.sh"

# Curation at setup, and the descriptor shape a pack already carries.
CU="$(mktemp -d)/ws"; mkdir -p "$CU"/{keep-a,keep-b,noise-c} "$CU/pk/_workspace/config" "$CU/pk/_workspace/templates/workspace"
for r in keep-a keep-b noise-c; do git -C "$CU/$r" init -q; echo x > "$CU/$r/README.md"; done
printf 'version: 1\ntoggles:\n' > "$CU/pk/_workspace/config/toggles.yaml"
printf '# from the pack, not the generic template\nversion: 1\nrepos: {}\ntargets: []\nhouse_style: yes\n' \
  > "$CU/pk/_workspace/templates/workspace/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CU" "$DECK" setup --packs-root "$CU/pk" --repos keep-a,keep-b 2>&1 || true)"
if printf '%s' "$out" | grep -q "left out 1"; then ok "setup keeps only the repositories named"; else bad "setup keeps only the repositories named" "$out"; fi
if printf '%s' "$out" | grep -q "shape from the .*pack"; then ok "and takes the descriptor shape from the pack"; else bad "and takes the descriptor shape from the pack" "$out"; fi
if grep -q "house_style" "$CU/.deck/workspace.yaml" 2>/dev/null; then ok "so what the pack declared survives into the descriptor"; else bad "so what the pack declared survives into the descriptor"; fi
if grep -q "noise-c" "$CU/.deck/workspace.yaml" 2>/dev/null; then bad "a repository left out stays out"; else ok "a repository left out stays out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CU" "$DECK" setup --force --packs-root "$CU/pk" --repos nope 2>&1 || true)"
if printf '%s' "$out" | grep -q "not found here: nope"; then ok "a name that is not there is refused, with the list"; else bad "a name that is not there is refused, with the list" "$out"; fi
rm -rf "$CU"

# A manifest and a working tree answer different questions, and a devtool-style
# workspace keeps what is being edited four levels down.
DV="$(mktemp -d)/ws"; mkdir -p "$DV"/{.repo/manifests,build/workspace/sources/edited,vendored} "$DV/pk/_workspace/config"
git -C "$DV/vendored" init -q; echo x > "$DV/vendored/README.md"
git -C "$DV/build/workspace/sources/edited" init -q; echo x > "$DV/build/workspace/sources/edited/README.md"
cat > "$DV/.repo/manifests/default.xml" <<'XML'
<manifest><project name="vendored" path="vendored"/></manifest>
XML
printf 'version: 1\ntoggles:\n' > "$DV/pk/_workspace/config/toggles.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DV" "$DECK" setup --dry-run --packs-root "$DV/pk" 2>&1 || true)"
if printf '%s' "$out" | grep -q "the manifest does not mention"; then
  ok "a checkout the manifest never names is kept, not dropped"
else bad "a checkout the manifest never names is kept, not dropped" "$out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DV" "$DECK" setup --packs-root "$DV/pk" --repos edited 2>&1 || true)"
if grep -q "build/workspace/sources/edited" "$DV/.deck/workspace.yaml" 2>/dev/null; then
  ok "a repository four levels down is found"
else bad "a repository four levels down is found" "$out"; fi
if grep -q "vendored" "$DV/.deck/workspace.yaml" 2>/dev/null; then
  bad "and --repos still leaves the rest out"
else ok "and --repos still leaves the rest out"; fi
rm -rf "$DV"

# ------------------------------------------ coupling: the edge with no order
# Two repositories that drive each other cannot be written as two `impacts:`
# edges — that is a cycle, and the topological order stops existing. `couples:`
# records the same relationship and takes no part in any order, so `doctor`
# still computes one.
note "coupling that carries no order"

CW="$(mktemp -d)/ws"
mkdir -p "$CW/.deck" "$CW"/{schema,gen,runtime,tools}
for r in schema gen runtime tools; do git -C "$CW/$r" init -q 2>/dev/null; done
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$CW/.deck/toggles.yaml"

# schema seeds a configuration runtime reads; runtime ships the command line
# schema calls. Declared on one side only, to prove one side is enough. The
# tools <-> runtime pair is declared on both, to prove that is the same thing.
cat > "$CW/.deck/workspace.yaml" <<YAML
version: 1
repos:
  schema:  { path: schema,  role: state schema, build_target: schema, impacts: [gen], couples: [runtime] }
  gen:     { path: gen,     role: generated code, build_target: gen, impacts: [] }
  runtime: { path: runtime, role: the scripts schema shells out to, build_target: runtime, impacts: [], couples: [tools] }
  tools:   { path: tools,   role: shared helpers, impacts: [], couples: [runtime] }
targets: []
YAML
# The same registry with every `couples:` entry removed. `deck order` must not
# be able to tell the two apart.
sed '/couples/s/, couples: \[[a-z]*\]//' "$CW/.deck/workspace.yaml" > "$CW/.deck/workspace.yaml.nocouples"

CDECK() { env DECK_ROOT="$CW" DECK_PACKS_ROOT="$PACKS" "$DECK" "$@"; }

# -- 1. a coupling that runs both ways can be recorded, and is not a cycle
doc="$(CDECK doctor 2>&1 || true)"
if printf '%s' "$doc" | grep -q "OK acyclic"; then
  ok "a coupled pair is not a cycle"
else bad "a coupled pair is not a cycle" "$(printf '%s' "$doc" | grep -i 'cycle\|acyclic')"; fi
if printf '%s' "$doc" | grep -q "topological order computable"; then
  ok "and the order is still computable"
else bad "and the order is still computable" "$(printf '%s' "$doc" | grep -i 'acyclic\|cycle')"; fi

# The half that used to have to be dropped: runtime declares nothing about
# schema, and `deck impact runtime` still names it.
imp="$(CDECK impact runtime 2>&1 || true)"
if printf '%s' "$imp" | grep -q "schema"; then
  ok "the side that declared nothing still sees the coupling"
else bad "the side that declared nothing still sees the coupling" "$imp"; fi
if printf '%s' "$imp" | grep -q "declared by schema"; then
  ok "and is told which side declared it"
else bad "and is told which side declared it" "$imp"; fi

both="$(CDECK impact tools 2>&1 || true)"
if printf '%s' "$both" | grep -q "declared on both sides"; then
  ok "declaring it on both sides is one coupling, not two"
else bad "declaring it on both sides is one coupling, not two" "$both"; fi

# -- 2. the order stays computable and stays meaningful
imp="$(CDECK impact schema 2>&1 || true)"
if printf '%s' "$imp" | grep -q "carries no order"; then
  ok "impact says the coupling carries no order"
else bad "impact says the coupling carries no order" "$imp"; fi
# The coupled repository must not be smuggled into the numbered chain, where a
# reader would take its position for a build position.
chain="$(printf '%s' "$imp" | sed -n '/execution order:/,/^$/p')"
if printf '%s' "$chain" | grep -q "runtime"; then
  bad "a coupled repository is not in the execution order" "$chain"
else ok "a coupled repository is not in the execution order"; fi

json="$(CDECK impact schema --json 2>&1 || true)"
if printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["coupled"]==["runtime"] else 1)' 2>/dev/null; then
  ok "the JSON carries the coupling apart from the chain"
else bad "the JSON carries the coupling apart from the chain" "$(printf '%s' "$json" | head -5)"; fi
if printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "runtime" not in d["order"] and "runtime" not in d["impacted"] else 1)' 2>/dev/null; then
  ok "and never inside impacted or order"
else bad "and never inside impacted or order" "$(printf '%s' "$json" | head -5)"; fi

# Regression guard: `order()` must be unable to see `couples:` at all. Removing
# every coupling from the registry may not change one line of its output.
with="$(CDECK order tools runtime gen schema | tr '\n' ' ')"
cp "$CW/.deck/workspace.yaml" "$CW/.deck/workspace.yaml.keep"
cp "$CW/.deck/workspace.yaml.nocouples" "$CW/.deck/workspace.yaml"
without="$(CDECK order tools runtime gen schema | tr '\n' ' ')"
cp "$CW/.deck/workspace.yaml.keep" "$CW/.deck/workspace.yaml"
if [ "$with" = "$without" ] && [ -n "$with" ]; then
  ok "order is identical with the couplings and without them"
else bad "order is identical with the couplings and without them" "with: $with / without: $without"; fi
if printf '%s' "$with" | grep -q "schema gen"; then
  ok "and still puts what impacts before what it impacts"
else bad "and still puts what impacts before what it impacts" "$with"; fi

# -- 3. doctor explains what a bidirectional declaration does and does not do
if printf '%s' "$doc" | grep -q "schema <-> runtime"; then
  ok "doctor names each coupled pair once"
else bad "doctor names each coupled pair once" "$(printf '%s' "$doc" | grep -i coupling)"; fi
if printf '%s' "$doc" | grep -q "reach both sides"; then
  ok "doctor says what a coupling does"
else bad "doctor says what a coupling does" "$(printf '%s' "$doc" | grep -i coupling)"; fi
if printf '%s' "$doc" | grep -q "no part in \`deck order\`"; then
  ok "and what it does not affect"
else bad "and what it does not affect" "$(printf '%s' "$doc" | grep -i coupling)"; fi
if printf '%s' "$doc" | grep -q "can never make this graph cyclic"; then
  ok "and that it can never make the graph cyclic"
else bad "and that it can never make the graph cyclic" "$(printf '%s' "$doc" | grep -i coupling)"; fi

# -- doctor validates couples targets the way it validates impacts targets
sed 's/couples: \[tools\]/couples: [nowhere]/' "$CW/.deck/workspace.yaml" > "$CW/.deck/workspace.yaml.dangling"
cp "$CW/.deck/workspace.yaml.dangling" "$CW/.deck/workspace.yaml"
dang="$(CDECK doctor 2>&1 || true)"
cp "$CW/.deck/workspace.yaml.keep" "$CW/.deck/workspace.yaml"
if printf '%s' "$dang" | grep -q "couples pointing outside the descriptor"; then
  ok "a couples target that does not exist is a problem"
else bad "a couples target that does not exist is a problem" "$(printf '%s' "$dang" | grep -i 'dangling\|couples')"; fi
if printf '%s' "$dang" | grep -q "drop the \`couples:\` entry"; then
  ok "and the report carries the edit that fixes it"
else bad "and the report carries the edit that fixes it" "$(printf '%s' "$dang" | grep -i couples)"; fi

# One pair, two edges disagreeing about it. deck reports rather than ranks.
sed 's/impacts: \[gen\], couples: \[runtime\]/impacts: [gen, runtime], couples: [runtime]/' \
  "$CW/.deck/workspace.yaml.keep" > "$CW/.deck/workspace.yaml"
contra="$(CDECK doctor 2>&1 || true)"
cp "$CW/.deck/workspace.yaml.keep" "$CW/.deck/workspace.yaml"
if printf '%s' "$contra" | grep -q "both as an impact and as a coupling"; then
  ok "a pair declared as an impact and a coupling is refused"
else bad "a pair declared as an impact and a coupling is refused" "$(printf '%s' "$contra" | grep -i coupling)"; fi

sed 's/couples: \[tools\]/couples: [runtime]/' "$CW/.deck/workspace.yaml.keep" > "$CW/.deck/workspace.yaml"
selfc="$(CDECK doctor 2>&1 || true)"
cp "$CW/.deck/workspace.yaml.keep" "$CW/.deck/workspace.yaml"
if printf '%s' "$selfc" | grep -q "coupled to itself"; then
  ok "a repository coupled to itself is refused"
else bad "a repository coupled to itself is refused" "$(printf '%s' "$selfc" | grep -i coupling)"; fi

# The registry as it had to be written before `couples:` existed: the two
# directions as two `impacts:` edges, which is a cycle. Still a cycle, and now
# the report names the field that records it without one.
cat > "$CW/.deck/workspace.yaml" <<YAML
version: 1
repos:
  schema:  { path: schema,  impacts: [gen, runtime] }
  gen:     { path: gen,     impacts: [] }
  runtime: { path: runtime, impacts: [schema] }
  tools:   { path: tools,   impacts: [] }
targets: []
YAML
cyc2="$(CDECK doctor 2>&1 || true)"
cp "$CW/.deck/workspace.yaml.keep" "$CW/.deck/workspace.yaml"
if printf '%s' "$cyc2" | grep -q "XX cycle"; then
  ok "two impacts edges between one pair are still a cycle"
else bad "two impacts edges between one pair are still a cycle" "$(printf '%s' "$cyc2" | grep -i 'cycle\|acyclic')"; fi
if printf '%s' "$cyc2" | grep -q "if neither of them comes first, that is a coupling"; then
  ok "a two-repository cycle is told about couples"
else bad "a two-repository cycle is told about couples" "$(printf '%s' "$cyc2" | grep -i 'cycle\|impact each other')"; fi

# -- mount places the packs for a coupled repository
mnt="$(CDECK mount --task CPL --repos schema --dry-run 2>&1 || true)"
if printf '%s' "$mnt" | grep -q "runtime"; then
  ok "mount expansion reaches the coupled repository"
else bad "mount expansion reaches the coupled repository" "$mnt"; fi
if printf '%s' "$mnt" | grep -q "gen"; then
  ok "and still reaches what the change impacts"
else bad "and still reaches what the change impacts" "$mnt"; fi
mnt="$(CDECK mount --task CPL --repos schema --no-expand --dry-run 2>&1 || true)"
if printf '%s' "$mnt" | grep -q "runtime"; then
  bad "--no-expand still takes only what was named" "$mnt"
else ok "--no-expand still takes only what was named"; fi

# -- a descriptor with no `couples:` reads exactly as it did before
plain="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$plain" | grep -q "coupling"; then
  bad "a registry with no coupling says nothing about coupling" "$(printf '%s' "$plain" | grep -i coupling)"
else ok "a registry with no coupling says nothing about coupling"; fi
plain="$("$DECK" impact a 2>&1 || true)"
if printf '%s' "$plain" | grep -q "coupled with"; then
  bad "and neither does its impact report" "$plain"
else ok "and neither does its impact report"; fi

# -- a pack seeded from this workspace carries the couplings out with it
env DECK_ROOT="$CW" "$DECK" pack new "$CW/seeded" --from-workspace >/dev/null 2>&1 || true
if grep -q "couples" "$CW/seeded/templates/workspace/workspace.yaml" 2>/dev/null; then
  ok "a pack seeded from the workspace keeps the couplings"
else
  bad "a pack seeded from the workspace keeps the couplings" \
      "$(sed -n '1,20p' "$CW/seeded/templates/workspace/workspace.yaml" 2>&1)"
fi

note "a scope that holds one half of a coupled pair"
# `deck impact` named a coupling and `deck scopes` did not, so two surfaces a
# person reads side by side disagreed about the same boundary. A scope leaks two
# ways — the ordered chain and the coupling — and both are reported, apart: the
# coupled half never joins the ordered one, because it carries no order.
python3 - "$CW/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {
    "front": {"title": "The schema side",           "repos": ["schema", "gen"]},
    "back":  {"title": "The runtime side",          "repos": ["runtime"]},
    "chain": {"title": "One repository only",       "repos": ["schema"]},
    "whole": {"title": "Both sides of every pair",  "repos": ["schema", "gen", "runtime", "tools"]},
}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

sc="$(CDECK scope front 2>&1 || true)"
if printf '%s' "$sc" | grep -q "coupled with  runtime"; then
  ok "a scope holding one side of a coupling reports the other"
else bad "a scope holding one side of a coupling reports the other" "$sc"; fi
if printf '%s' "$sc" | grep -q "the boundary is closed"; then
  bad "and stops calling that boundary closed" "$sc"
else ok "and stops calling that boundary closed"; fi
# Not transitive here either: schema couples runtime and runtime couples tools,
# and the scope holds neither runtime nor the pair that would assert tools.
if printf '%s' "$sc" | grep -q "tools"; then
  bad "a coupling is not chained through a repository the scope lacks" "$sc"
else ok "a coupling is not chained through a repository the scope lacks"; fi

# doctor was the last surface answering a boundary from `impacts:` alone, while
# `deck scope` and `deck impact` both named the coupling.
docs2="$(CDECK doctor 2>&1 || true)"
if printf '%s' "$docs2" | grep -q "coupled with runtime"; then
  ok "doctor's scope line names a coupling that leaves the scope"
else
  bad "doctor's scope line names a coupling that leaves the scope" "$(printf '%s' "$docs2" | grep -A6 '^scopes')"
fi

scl="$(CDECK scopes 2>&1 || true)"
if printf '%s' "$scl" | grep -q "coupled outside: runtime"; then
  ok "the scope listing agrees with \`deck impact\` about what the coupling reaches"
else bad "the scope listing agrees with \`deck impact\` about what the coupling reaches" "$scl"; fi

# runtime declares nothing about schema; the coupling is read from both sides.
back="$(CDECK scope back 2>&1 || true)"
if printf '%s' "$back" | grep -q "coupled with  schema, tools"; then
  ok "the scope on the side that declared nothing sees the coupling too"
else bad "the scope on the side that declared nothing sees the coupling too" "$back"; fi

# The two halves in the JSON, under two keys. A scope that leaks both ways is
# the case where merging them would have hidden which name carried an order.
ch="$(CDECK scope chain --json 2>&1 || true)"
if printf '%s' "$ch" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["reaches_outside"]==["gen"] else 1)' 2>/dev/null; then
  ok "the ordered half of a leak keeps its own key"
else bad "the ordered half of a leak keeps its own key" "$(printf '%s' "$ch" | head -20)"; fi
if printf '%s' "$ch" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["coupled_outside"]==["runtime"] else 1)' 2>/dev/null; then
  ok "and the coupled half is beside it, never folded in"
else bad "and the coupled half is beside it, never folded in" "$(printf '%s' "$ch" | head -20)"; fi

wh="$(CDECK scope whole 2>&1 || true)"
if printf '%s' "$wh" | grep -q "the boundary is closed"; then
  ok "a scope holding both sides of every pair leaks nothing"
else bad "a scope holding both sides of every pair leaks nothing" "$wh"; fi

inf="$(CDECK --scope front info 2>&1 || true)"
if printf '%s' "$inf" | grep -q "coupled outside the scope: runtime"; then
  ok "and \`deck info\` inside the scope says the same as the scope report"
else bad "and \`deck info\` inside the scope says the same as the scope report" "$inf"; fi

rm -rf "$(dirname "$CW")"

note "diagnosis"
check "doctor runs on the synthetic workspace" "workspace" "$DECK" doctor
check "doctor reports the pack" "_workspace" "$DECK" doctor

# ------------------------------------------------ the merge-readiness bundle
# Last, deliberately: the bundle reads what every earlier section produced — a
# gate record, a consultation, a decision a task owns — and it commits into the
# synthetic repositories, which nothing after it should have to work around.
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

# ---- the first command anyone runs can be the first command anyone runs
# `init` went through the shared root resolution, whose second option is
# "create .deck/workspace.yaml at the root (deck init)" — so somebody trying
# deck for the first time, in a directory with no `.deck/`, was answered by the
# command they had just run. The only option that worked was the one they were
# least likely to pick.
note "deck init in a directory that is not a workspace yet"
IB="$(mktemp -d)"
ib_out="$( (cd "$IB" && env -u DECK_ROOT "$DECK" init 2>&1) )"; ib_rc=$?
if [ "$ib_rc" = 0 ]; then
  ok "deck init with no root resolved does not fail"
else bad "deck init with no root resolved does not fail" "$ib_out"; fi
if [ -f "$IB/.deck/workspace.yaml" ]; then
  ok "and creates the workspace where it was run"
else bad "and creates the workspace where it was run" "$ib_out"; fi
if printf '%s' "$ib_out" | grep -q "initialising $IB"; then
  ok "and says which directory it chose, rather than choosing in silence"
else bad "and says which directory it chose, rather than choosing in silence" "$ib_out"; fi
if printf '%s' "$ib_out" | grep -q 'deck init)'; then
  bad "and does not answer with the command that was just run" "$ib_out"
else ok "and does not answer with the command that was just run"; fi
# From below an existing workspace it must still target the root, not make a
# second one: a workspace nested inside a workspace is its own hazard.
mkdir -p "$IB/inner"
ib_in="$( (cd "$IB/inner" && env -u DECK_ROOT "$DECK" init 2>&1) )"
if [ -d "$IB/inner/.deck" ]; then
  bad "running it below an existing root does not nest a second workspace" "$ib_in"
else ok "running it below an existing root does not nest a second workspace"; fi
if printf '%s' "$ib_in" | grep -q "kept    $IB/.deck/workspace.yaml"; then
  ok "and names the root it resolved to, by absolute path"
else bad "and names the root it resolved to, by absolute path" "$ib_in"; fi
# Every other command still owes the resolution list: it is right for them.
ib_other="$( (cd "$(mktemp -d)" && env -u DECK_ROOT "$DECK" root 2>&1) )" || true
if printf '%s' "$ib_other" | grep -q 'workspace root not resolved'; then
  ok "a command that cannot create a root still explains how one is found"
else bad "a command that cannot create a root still explains how one is found" "$ib_other"; fi
rm -rf "$IB"

# ---- writing a choice does not delete what explains the file
# `dump_yaml` went through `safe_dump`, which rewrites the whole file. The first
# `toggle set` in a fresh workspace therefore deleted the header `deck init` had
# just shipped — the block on layer precedence, on `ask`, on what `reasons:` is
# for. It was the file's own documentation, and it survived until the first
# value was recorded in it.
note "a choice written does not delete what explains the file"
CM="$(mktemp -d)"
mkdir -p "$CM/app"
env DECK_ROOT="$CM" "$DECK" init >/dev/null 2>&1
cp "$CM/.deck/toggles.yaml" "$CM/shipped.yaml"
cm_comments() { grep -c '^[[:space:]]*#' "$1" 2>/dev/null || echo 0; }
before="$(cm_comments "$CM/shipped.yaml")"
env DECK_ROOT="$CM" "$DECK" toggle set gate_level build --at workspace --why "a reason" >/dev/null 2>&1
after="$(cm_comments "$CM/.deck/toggles.yaml")"
if [ "$before" -gt 20 ] && [ "$after" = "$before" ]; then
  ok "the header a fresh workspace ships survives the first choice written into it"
else bad "the header a fresh workspace ships survives the first choice written into it" "$before before, $after after"; fi
if diff -q <(grep '^[[:space:]]*#' "$CM/shipped.yaml") <(grep '^[[:space:]]*#' "$CM/.deck/toggles.yaml") >/dev/null; then
  ok "and not one comment line is reworded, reordered or dropped"
else bad "and not one comment line is reworded, reordered or dropped" "$(diff <(grep '^[[:space:]]*#' "$CM/shipped.yaml") <(grep '^[[:space:]]*#' "$CM/.deck/toggles.yaml") | head -6)"; fi
# The template's last ten lines are a commented `repos:` example with no data
# line under them. The first draft of this dropped every trailing run.
if grep -q 'both shapes are read' "$CM/.deck/toggles.yaml"; then
  ok "including the run at the end of the file, which has no line below it"
else bad "including the run at the end of the file, which has no line below it" "$(tail -4 "$CM/.deck/toggles.yaml")"; fi
# `values: {}` becomes `values:` the moment the block gains its first entry —
# the commonest thing that happens to this file. Anchoring on the line's text
# rather than its key orphaned the paragraph explaining the block exactly then.
# Immediately above, not merely somewhere in the file: the run has to still be
# attached to the block it explains, which is the whole point of re-attaching.
cm_above="$(grep -B1 '^values:' "$CM/.deck/toggles.yaml" | head -1)"
if printf '%s' "$cm_above" | grep -q '^#'; then
  ok "a paragraph above an empty block stays above it once the block fills"
else bad "a paragraph above an empty block stays above it once the block fills" "line before values: was ${cm_above:-<nothing>}"; fi
if grep -B12 '^values:' "$CM/.deck/toggles.yaml" | grep -q 'Pin here only what'; then
  ok "and it is the paragraph that was written there, whole"
else bad "and it is the paragraph that was written there, whole" "$(grep -B12 '^values:' "$CM/.deck/toggles.yaml")"; fi
# Repeated writes must not accumulate: re-attaching is not appending.
for _ in 1 2 3; do env DECK_ROOT="$CM" "$DECK" toggle set gate_level static --at workspace --why "again" >/dev/null 2>&1; done
if [ "$(cm_comments "$CM/.deck/toggles.yaml")" = "$before" ]; then
  ok "and four writes leave the same comments as one, not four copies"
else bad "and four writes leave the same comments as one, not four copies" "$(cm_comments "$CM/.deck/toggles.yaml") lines"; fi
# A comment somebody wrote themselves, against a value that then changes.
python3 - "$CM/.deck/toggles.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("values:\n  gate_level: static", "values:\n  # agreed on Wednesday\n  gate_level: static", 1))
PY
env DECK_ROOT="$CM" "$DECK" toggle set gate_level behavior --at workspace --why "moved on" >/dev/null 2>&1
if grep -A1 'agreed on Wednesday' "$CM/.deck/toggles.yaml" | grep -q 'gate_level: behavior'; then
  ok "a comment a person wrote stays on the value it was written about"
else bad "a comment a person wrote stays on the value it was written about" "$(grep -B2 -A2 'gate_level' "$CM/.deck/toggles.yaml" | head -8)"; fi
# The file still has to be a file deck can read back.
cm_val="$(env DECK_ROOT="$CM" "$DECK" toggle get gate_level 2>&1 || true)"
if printf '%s' "$cm_val" | grep -q '^behavior'; then
  ok "and the file is still valid YAML deck reads the value back out of"
else bad "and the file is still valid YAML deck reads the value back out of" "$cm_val"; fi
rm -rf "$CM"

# ------------------------------------------------ the reason behind a decision
# The bundle is the one surface written for somebody who was not there. It
# carried the value and the layer from the start and not the sentence explaining
# the choice, so it said a task ran at `gate_level: build` and never why anyone
# chose that — while the sentence was on disk the whole time.
note "a decision's reason, in the bundle"

"$DECK" toggle set gate_level build --at workspace \
  --why "delivery goes through a firmware update path nobody has wired to deck yet" >/dev/null
"$DECK" toggle set test_depth smoke --at workspace >/dev/null
"$DECK" toggle set api_compat breaking --at task \
  --why "the field being removed has no consumer left in the registry" >/dev/null

decided="$("$DECK" bundle --task T-1 2>&1 | sed -n '/what was decided/,/^$/p' || true)"
if printf '%s' "$decided" | grep -q "why  delivery goes through a firmware update path"; then
  ok "a decision in the bundle carries the reason its chooser recorded"
else
  bad "a decision in the bundle carries the reason its chooser recorded" "$decided"
fi
owned="$(printf '%s' "$decided" | grep -A1 "this task's to decide" || true)"
if printf '%s' "$owned" | grep -q "no consumer left in the registry"; then
  ok "and so does the decision the task existed to take"
else
  bad "and so does the decision the task existed to take" "$decided"
fi
bare="$(printf '%s' "$decided" | grep -A1 "test_depth" || true)"
if printf '%s' "$bare" | grep -q "not recorded"; then
  ok "a decision with none says so rather than looking justified"
else
  bad "a decision with none says so rather than looking justified" "$decided"
fi
if printf '%s' "$bare" | grep -q 'record it with: deck toggle set test_depth smoke --at workspace --why'; then
  ok "and names the command that would record one"
else
  bad "and names the command that would record one" "$bare"
fi

# An environment variable belongs to one command, so there is no file to record
# a reason in and no command to suggest. Saying "not recorded" here would read
# as an omission somebody could fix.
env_decided="$(DECK_UNIT_TESTS=required "$DECK" bundle --task T-1 2>&1 | sed -n '/what was decided/,/^$/p' || true)"
from_env="$(printf '%s' "$env_decided" | grep -A1 "unit_tests" || true)"
if printf '%s' "$from_env" | grep -q "is not a layer a reason can be written at"; then
  ok "a value from the environment says why no reason exists for it"
else
  bad "a value from the environment says why no reason exists for it" "$env_decided"
fi
# A guard, not a new behaviour: the old bundle printed no reason line at all, so
# this passed before the change too. It is here because the fix could only go
# wrong one way — by offering `--why` for a layer that cannot hold one.
if printf '%s' "$from_env" | grep -q "record it with"; then
  bad "a reason is never invited where none can be recorded" "$from_env"
else
  ok "a reason is never invited where none can be recorded"
fi

"$DECK" bundle --task T-1 --write >/dev/null 2>&1 || true
md_row="$(grep '^| `gate_level`' "$WS/.deck/bundles/T-1.md" || true)"
if printf '%s' "$md_row" | grep -q "firmware update path"; then
  ok "the markdown a reviewer reads carries it in a column of its own"
else
  bad "the markdown a reviewer reads carries it in a column of its own" "$md_row"
fi
# A reason is a sentence somebody typed. An unescaped pipe in it splits the row
# and shifts every column after it, so the reviewer reads a table that is wrong.
"$DECK" toggle set test_depth full --at workspace \
  --why "unit alone | nothing here runs integration" >/dev/null
"$DECK" bundle --task T-1 --write >/dev/null 2>&1 || true
md_row="$(grep '^| `test_depth`' "$WS/.deck/bundles/T-1.md" || true)"
if printf '%s' "$md_row" | grep -qF '\|'; then
  ok "a pipe inside a reason is escaped rather than splitting the row"
else
  bad "a pipe inside a reason is escaped rather than splitting the row" "$md_row"
fi

bundle_json="$("$DECK" bundle --task T-1 --json 2>&1 || true)"
if printf '%s' "$bundle_json" | python3 -c 'import json,sys
rows = {d["id"]: d for d in json.load(sys.stdin)["decisions"]["recorded"]}
sys.exit(0 if "firmware update path" in (rows["gate_level"]["reason"] or "") else 1)' 2>/dev/null; then
  ok "the JSON carries the reason, so a consumer need not re-read the toggle file"
else
  bad "the JSON carries the reason, so a consumer need not re-read the toggle file" \
    "$(printf '%s' "$bundle_json" | head -3)"
fi
"$DECK" toggle set test_depth smoke --at workspace >/dev/null
bundle_json="$("$DECK" bundle --task T-1 --json 2>&1 || true)"
if printf '%s' "$bundle_json" | python3 -c 'import json,sys
rows = {d["id"]: d for d in json.load(sys.stdin)["decisions"]["recorded"]}
row = rows["test_depth"]
sys.exit(0 if row["reason"] is None and "not recorded" in (row["why_missing"] or "") else 1)' 2>/dev/null; then
  ok "and a decision with none is null there, with a field saying which nothing it is"
else
  bad "and a decision with none is null there, with a field saying which nothing it is" \
    "$(printf '%s' "$bundle_json" | head -3)"
fi


note "what a pack seeded from a workspace carries"
# `--from-workspace` turns one person's registry into the template a team
# shares, through an allowlist of per-repository fields. `downstream` was
# missing from it, so every repository that produces no artifact came out of a
# seed looking like an ordinary build node; `couples` had been missing before
# that. The rule is one question — would this value still be true on the next
# person's machine — and there is a check below per field the rule lets
# through, so the next field lost by omission is lost loudly.
SW="$(mktemp -d)"
mkdir -p "$SW/.deck" "$SW"/{svc,ops,e2e} "$SW/round2/.deck" "$SW/round2"/{svc,ops,e2e}
cat > "$SW/.deck/workspace.yaml" <<'YAML'
version: 1
requires_files: [svc/Makefile]
paths:
  tools: /home/someone-else/tools
repos:
  svc:
    path: svc
    role: request handling
    remote_id: acme/svc
    build_target: pkg-svc
    lint: make lint
    deploy_path: /opt/svc/
    services: [svcd]
    impacts: [e2e]
    couples: [ops]
    revision: refs/heads/one-afternoon
    remote: origin
  ops:
    path: ops
    role: the deployment commands the service shells out to
    impacts: []
  e2e:
    path: e2e
    role: end-to-end assertions over the running service
    downstream: true
    impacts: []
targets:
  - { host: 10.9.9.9, alias: someones-lab }
YAML
env DECK_ROOT="$SW" "$DECK" pack new "$SW/seeded" --from-workspace >/dev/null 2>&1 || true
SEEDED="$SW/seeded/templates/workspace/workspace.yaml"

# ---- re-seeding a template is not resetting a pack
# The observed loss: a `_workspace` pack was re-seeded to check that a scope
# travelled into version control. It did — and the same command came back with
# `gates: []` and an empty `rules:`, taking a declared gate and two mount
# entries that had nothing to do with the template. Nothing in the output said
# so; the closing words were about targets being left empty on purpose, printed
# while three other files were emptied without mention.
note "re-seeding a template is not resetting a pack"
RS="$SW/reseed"
env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" >/dev/null 2>&1
cat > "$RS/config/gates.yaml" <<'YAML'
gates:
  - { id: mine, title: a gate somebody wrote, from_level: static, once: "true" }
YAML
cat > "$RS/config/mount.yaml" <<'YAML'
rules:
  - { file: rules/one.md }
  - { file: rules/two.md }
  - { file: rules/three.md }
YAML
printf 'toggles:
  - { id: kept_choice, group: quality, title: t, summary: s, type: enum, values: [a, b], default: a, askable: false, impact: { a: x, b: y } }
' > "$RS/config/toggles.yaml"
reseed="$(env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" --from-workspace --force 2>&1 || true)"
if grep -q 'id: mine' "$RS/config/gates.yaml"; then
  ok "a gate the pack declared survives --force"
else bad "a gate the pack declared survives --force" "$reseed"; fi
# Uncommented entries only, and three of them. The scaffold `mount.yaml` ships
# two commented examples that also match a bare `file: rules/`, so a count of
# two passed on the broken code as well and proved nothing.
if [ "$(grep -c '^  - .*file: rules/' "$RS/config/mount.yaml")" = "3" ]; then
  ok "and the mount entries that made its rules do anything"
else bad "and the mount entries that made its rules do anything" "$(cat "$RS/config/mount.yaml")"; fi
if grep -q 'kept_choice' "$RS/config/toggles.yaml"; then
  ok "and the catalog entries somebody wrote"
else bad "and the catalog entries somebody wrote" "$(cat "$RS/config/toggles.yaml")"; fi
if grep -q 'Seeded by' "$RS/templates/workspace/workspace.yaml"; then
  ok "while the template it was asked to re-seed is rewritten"
else bad "while the template it was asked to re-seed is rewritten" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'templates/workspace/workspace.yaml   (replaced)'; then
  ok "and the one file it replaced is named as replaced"
else bad "and the one file it replaced is named as replaced" "$reseed"; fi
# Spared is not enough: a reader has to be able to tell a pack that was
# protected from one that was blank anyway.
if printf '%s' "$reseed" | grep -q 'config/gates.yaml.*1 gate'; then
  ok "what it kept is named, and what that file holds"
else bad "what it kept is named, and what that file holds" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'scaffold file(s) with nothing declared'; then
  ok "and the untouched scaffold is counted, not listed line by line"
else bad "and the untouched scaffold is counted, not listed line by line" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'updated at'; then
  ok "a pack that already existed is not announced as created"
else bad "a pack that already existed is not announced as created" "$reseed"; fi

# A gap in the scaffold is still filled: writing a file that is not there takes
# nothing away, which is the whole difference from replacing one. `--force` is
# what gets a second run this far at all — the guard at the top of `pack new`
# refuses a non-empty directory without it, and that is unchanged.
rm -f "$RS/config/profiles.yaml"
nogap="$(env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" 2>&1 || true)"
if printf '%s' "$nogap" | grep -q 'already exists and is not empty'; then
  ok "a second run on a non-empty pack still needs --force to do anything"
else bad "a second run on a non-empty pack still needs --force to do anything" "$nogap"; fi
env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" --force >/dev/null 2>&1
if [ -f "$RS/config/profiles.yaml" ]; then
  ok "and then a missing scaffold file is written back"
else bad "and then a missing scaffold file is written back"; fi
if grep -q 'id: mine' "$RS/config/gates.yaml"; then
  ok "and filling that gap still leaves the declarations alone"
else bad "and filling that gap still leaves the declarations alone"; fi

# Scaffolding a genuinely new pack is untouched.
fresh_out="$(env DECK_ROOT="$SW" "$DECK" pack new brandnew --dir "$SW/brandnew" 2>&1 || true)"
if printf '%s' "$fresh_out" | grep -q 'created at'; then
  ok "a new pack is still announced as created"
else bad "a new pack is still announced as created" "$fresh_out"; fi
fresh_count="$(printf '%s' "$fresh_out" | grep -cE '^  (config|rules|skills|agents|templates|README|\.claude)')"
if [ "$fresh_count" -ge 10 ]; then
  ok "and still gets the whole scaffold, every file of it"
else bad "and still gets the whole scaffold, every file of it" "$fresh_count file(s): $fresh_out"; fi
if printf '%s' "$fresh_out" | grep -q 'kept —'; then
  bad "and has nothing to report as kept, having held nothing" "$fresh_out"
else ok "and has nothing to report as kept, having held nothing"; fi

# Flattened once, asserted one field per check: a single python block holding
# every assertion would report one failure for ten different reasons.
seed_fields="$(python3 - "$SEEDED" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for name, entry in (d.get("repos") or {}).items():
    for k, v in entry.items():
        print(f"{name}.{k}={v}")
print(f"top={','.join(sorted(d))}")
print(f"targets={d.get('targets')!r}")
PY
)"
if printf '%s' "$seed_fields" | grep -q "^svc\.path="; then
  ok "the seeded template parses and holds the registry"
else bad "the seeded template parses and holds the registry" "$seed_fields"; fi

seeded_has() {
  if printf '%s' "$seed_fields" | grep -qxF "$2"; then ok "$1"
  else bad "$1" "$(printf '%s' "$seed_fields" | grep "^${2%%=*}=" || printf 'no %s line' "${2%%=*}")"; fi
}
seeded_lacks() {
  if printf '%s' "$seed_fields" | grep -q "^$2="; then
    bad "$1" "$(printf '%s' "$seed_fields" | grep "^$2=")"
  else ok "$1"; fi
}

# One per field in SEEDED_REPO_FIELDS, in that order.
seeded_has "the seed carries path — the layout below the root, not the root"  "svc.path=svc"
seeded_has "the seed carries role"                                           "svc.role=request handling"
seeded_has "the seed carries remote_id"                                      "svc.remote_id=acme/svc"
seeded_has "the seed carries build_target"                                   "svc.build_target=pkg-svc"
seeded_has "the seed carries lint"                                           "svc.lint=make lint"
seeded_has "the seed carries deploy_path"                                    "svc.deploy_path=/opt/svc/"
seeded_has "the seed carries services"                                       "svc.services=['svcd']"
seeded_has "the seed carries downstream"                                     "e2e.downstream=True"
seeded_has "the seed carries impacts"                                        "svc.impacts=['e2e']"
seeded_has "the seed carries couples"                                        "svc.couples=['ops']"

# The other half of the rule: a field that describes one checkout, and one
# machine's directories and hosts, do not travel.
seeded_lacks "a revision the next import rewrites does not travel"  "svc.revision"
seeded_lacks "and neither does the remote it was read through"      "svc.remote"
top_keys="$(printf '%s' "$seed_fields" | grep '^top=' || true)"
if printf '%s' "$top_keys" | grep -q "paths"; then
  bad "one machine's tools directory does not travel either" "$top_keys"
else ok "one machine's tools directory does not travel either"; fi
if printf '%s' "$seed_fields" | grep -qxF "targets=[]"; then
  ok "targets are emptied, not copied — an allowlist is a decision"
else bad "targets are emptied, not copied — an allowlist is a decision" "$(printf '%s' "$seed_fields" | grep '^targets=')"; fi

# ---- a scope's board says which board, never who is asking for it
# The seed's rule is one question — would this value still be true on the next
# person's machine — and `scopes:` was copied whole, so a tracker `backlog:`
# carried the account it authenticates as into a file a team versions. It
# reached a real template before anyone noticed.
note "a seeded board names the board, not the person"
PS="$(mktemp -d)"
mkdir -p "$PS/.deck" "$PS/app"
cat > "$PS/.deck/workspace.yaml" <<'YAML'
version: 1
repos: { app: { path: app } }
scopes:
  billing:
    title: Billing
    repos: [app]
    backlog:
      - { type: jira, url: https://example.atlassian.net, project: ABC123, user: someone@example.com }
  reporting:
    title: Reporting
    repos: [app]
YAML
env DECK_ROOT="$PS" "$DECK" pack new seeded --dir "$PS/pk" --from-workspace >/dev/null 2>&1 || true
PSEED="$PS/pk/templates/workspace/workspace.yaml"
ps_scope="$(python3 - "$PSEED" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
scopes = d.get("scopes") or {}
for source in (scopes.get("billing") or {}).get("backlog") or []:
    for k, v in sorted(source.items()):
        print(f"billing.{k}={v}")
print(f"reporting_keys={','.join(sorted(scopes.get('reporting') or {}))}")
PY
)"
if printf '%s' "$ps_scope" | grep -q 'billing.project=ABC123'; then
  ok "a seeded scope keeps the board it names"
else bad "a seeded scope keeps the board it names" "$ps_scope"; fi
if printf '%s' "$ps_scope" | grep -q 'billing.url=https://example.atlassian.net'; then
  ok "and the host it is read from"
else bad "and the host it is read from" "$ps_scope"; fi
if printf '%s' "$ps_scope" | grep -q 'billing.user='; then
  bad "and drops the account it authenticates as — that is per person" "$ps_scope"
else ok "and drops the account it authenticates as — that is per person"; fi
if grep -q 'who is asking for it: `user`' "$PSEED"; then
  ok "and the file says which field did not travel, as it does for repositories"
else bad "and the file says which field did not travel, as it does for repositories" "$(head -12 "$PSEED")"; fi
# A field removed in silence is one somebody puts back; a field named is one
# they fill in on their own machine. The rest of the scope is untouched.
if printf '%s' "$ps_scope" | grep -q 'reporting_keys=repos,title'; then
  ok "a scope with no board seeds exactly as it did"
else bad "a scope with no board seeds exactly as it did" "$ps_scope"; fi
# The trip has to work in both directions: what is seeded still resolves.
cp "$PSEED" "$PS/.deck/workspace.yaml"
ps_back="$(env DECK_ROOT="$PS" "$DECK" scopes 2>&1 || true)"
if printf '%s' "$ps_back" | grep -q 'billing'; then
  ok "and a workspace initialised from it still declares the scope"
else bad "and a workspace initialised from it still declares the scope" "$ps_back"; fi
rm -rf "$PS"

# The end of the trip the seed exists for: the template becomes somebody's
# registry, and the repository that produces no artifact is still saying so.
cp "$SEEDED" "$SW/round2/.deck/workspace.yaml"
r2="$(env DECK_ROOT="$SW/round2" "$DECK" repos --downstream-only 2>&1 || true)"
if printf '%s' "$r2" | grep -q "e2e"; then
  ok "a workspace initialised from the seeded template still knows e2e is downstream"
else bad "a workspace initialised from the seeded template still knows e2e is downstream" "$r2"; fi
r2b="$(env DECK_ROOT="$SW/round2" "$DECK" repos --buildable-only 2>&1 || true)"
if printf '%s' "$r2b" | grep -q "e2e"; then
  bad "and does not offer it as something to build" "$r2b"
else ok "and does not offer it as something to build"; fi
rm -rf "$SW"

# ------------------------------------- a carve-up two people do not share
note "a carve-up two people do not share"
# `scopes:` lives in `.deck/workspace.yaml`, which is per machine and never
# versioned; a pack's `templates/workspace/workspace.yaml` is where the carve-up
# becomes the team's. Nothing compared the two, so two people could run the same
# command in the same named scope over different repositories and neither be
# told. Four facts here, and they are deliberately not one severity: a subset
# that disagrees is a warning, a scope only this machine has is not a fault.
KV="$(mktemp -d)"
KVP="$KV/packs/_workspace"
mkdir -p "$KV/.deck" "$KV"/{api,server,ops,bench} "$KVP/config" "$KVP/templates/workspace"
for d in api server ops bench; do git -C "$KV/$d" init -q 2>/dev/null; done
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$KV/.deck/toggles.yaml"
printf 'markers: []\n' > "$KVP/config/detect.yaml"
cat > "$KV/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    impacts: [server] }
  server: { path: server, impacts: [] }
  ops:    { path: ops,    impacts: [] }
  bench:  { path: bench,  impacts: [] }
scopes:
  payments:
    title: Payments migration
    repos: [api, server]
  ledger:
    title: Ledger
    repos: [bench]
    backlog: [{ type: tasks, file: board-here.yaml }]
  billing:
    title: Billing, as this machine has it
    repos: [ops]
  house:
    title: A local errand
    repos: [ops]
YAML
: > "$KV/board-here.yaml"
: > "$KV/board-ledger.yaml"
cat > "$KVP/templates/workspace/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    impacts: [server] }
  server: { path: server, impacts: [] }
  ops:    { path: ops,    impacts: [] }
  bench:  { path: bench,  impacts: [] }
scopes:
  payments:
    title: Payments migration
    repos: [api, server, ops]
  ledger:
    title: Ledger
    repos: [bench]
    backlog: [{ type: tasks, file: board-ledger.yaml }]
  billing:
    title: Billing
    repos: [ops]
  reporting:
    title: Reporting
    repos: [bench]
YAML
KVENV=(env DECK_ROOT="$KV" DECK_PACKS_ROOT="$KV/packs")

# One capture per surface, then one grep per fact: a single block asserting all
# four states would report one failure whichever of them broke.
kv_doctor="$("${KVENV[@]}" "$DECK" doctor 2>&1 || true)"
kv_scopes="$("${KVENV[@]}" "$DECK" scopes 2>&1 || true)"

# 1. The dangerous one: the same name on both sides, different repositories.
if printf '%s' "$kv_doctor" | grep -q 'scope `payments` holds different repositories here and in the `_workspace` pack'; then
  ok "a scope holding different repositories from the pack's is reported"
else bad "a scope holding different repositories from the pack's is reported" "$kv_doctor"; fi
if printf '%s' "$kv_doctor" | grep -q 'here api, server, shipped api, server, ops'; then
  ok "and both subsets are named, this machine's and the pack's"
else bad "and both subsets are named, this machine's and the pack's" "$kv_doctor"; fi
if printf '%s' "$kv_doctor" | grep -q "deck is using this workspace's, so a command run in \`payments\`"; then
  ok "and the report says which of the two deck is using"
else bad "and the report says which of the two deck is using" "$kv_doctor"; fi

# 2. A scope the pack ships that this machine has never declared.
if printf '%s' "$kv_doctor" | grep -q 'ships scope `reporting` (bench) and this workspace does not declare it'; then
  ok "a scope the pack ships and this machine lacks is reported"
else bad "a scope the pack ships and this machine lacks is reported" "$kv_doctor"; fi

# 3. A scope only this machine has is legitimate, and gets the quiet voice.
if printf '%s' "$kv_doctor" | grep -q "scope \`house\` is this machine's own"; then
  ok "a scope only this machine has is named as its own, not as a fault"
else bad "a scope only this machine has is named as its own, not as a fault" "$kv_doctor"; fi
kv_house="$(printf '%s' "$kv_doctor" | grep "scope \`house\`" || true)"
if printf '%s' "$kv_house" | grep -q '^  OK '; then
  ok "and it is not raised as a warning"
else bad "and it is not raised as a warning" "$kv_house"; fi

# 4. Same name, same repositories, different wording — and a different board,
# which is the same failure as (1) in another field.
kv_billing="$(printf '%s' "$kv_doctor" | grep "scope \`billing\` is titled" || true)"
if printf '%s' "$kv_billing" | grep -q '^  OK '; then
  ok "a title that differs over the same subset is a note, not a warning"
else bad "a title that differs over the same subset is a note, not a warning" "$kv_billing"; fi
kv_ledger="$(printf '%s' "$kv_doctor" | grep "scope \`ledger\` names a different board" || true)"
if printf '%s' "$kv_ledger" | grep -q '^  !! '; then
  ok "a board that differs over the same subset is a warning — same tasks is the point"
else bad "a board that differs over the same subset is a warning — same tasks is the point" "$kv_ledger"; fi

# The divergence is reported, never refused: deck keeps working on both sides.
if [ "$("${KVENV[@]}" "$DECK" --scope payments repos | tr '\n' ' ')" = "api server " ]; then
  ok "a diverging scope still narrows the registry, to this machine's subset"
else
  bad "a diverging scope still narrows the registry, to this machine's subset" \
      "got: $("${KVENV[@]}" "$DECK" --scope payments repos | tr '\n' ' ')"
fi
check "and the diagnosis does not fail over it" "workspace" "${KVENV[@]}" "$DECK" doctor

# The same report where a scope is chosen, not only where a workspace is
# diagnosed: `deck scopes` is the last view before the work starts.
if printf '%s' "$kv_scopes" | grep -q 'scope `payments` holds different repositories'; then
  ok "deck scopes reports the divergence beside the subset it contradicts"
else bad "deck scopes reports the divergence beside the subset it contradicts" "$kv_scopes"; fi
if printf '%s' "$kv_scopes" | grep -q 'ships scope `reporting`'; then
  ok "and names the pack-shipped scope that has no row of its own here"
else bad "and names the pack-shipped scope that has no row of its own here" "$kv_scopes"; fi
check "deck scope <name> carries it too" "holds different repositories" "${KVENV[@]}" "$DECK" scope payments
kv_json="$("${KVENV[@]}" "$DECK" scopes --json 2>&1 || true)"
if printf '%s' "$kv_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if [e for e in d["drift"] if e["scope"]=="payments" and e["severity"]=="warn"] else 1)'; then
  ok "--json carries the drift with its severity"
else bad "--json carries the drift with its severity" "$kv_json"; fi

# The other issue's promise to everyone not using it: a registry with one
# template and no pack bound to a scope is read exactly as it always was. Every
# scope here comes from that one file, so every line of the report names that
# one pack — and nothing in the collection is waiting on a scope, because
# nothing in it is bound to one.
kv_packs="$("${KVENV[@]}" "$DECK" packs --json 2>&1 || true)"
if printf '%s' "$kv_packs" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["dormant"]==[] and all(r["bound_to"] is None for r in d["packs"]) else 1)'; then
  ok "a collection with no scope-bound pack has none waiting and none bound"
else bad "a collection with no scope-bound pack has none waiting and none bound" "$kv_packs"; fi
kv_elsewhere="$(printf '%s' "$kv_doctor" | grep -E '^  (!!|OK) pack ' | grep -v '`_workspace` pack' || true)"
if [ -z "$kv_elsewhere" ]; then
  ok "and every scope in the divergence report still comes from that one pack"
else bad "and every scope in the divergence report still comes from that one pack" "$kv_elsewhere"; fi

# A name that is real but not on this machine is not "unknown".
kv_refused="$("${KVENV[@]}" "$DECK" --scope reporting repos 2>&1 || true)"
if printf '%s' "$kv_refused" | grep -q 'not declared on this machine, but the `_workspace` pack ships it'; then
  ok "asking for a pack-shipped scope this machine lacks says so, not 'unknown scope'"
else bad "asking for a pack-shipped scope this machine lacks says so, not 'unknown scope'" "$kv_refused"; fi

# Nothing to disagree with is not a disagreement.
python3 - "$KVP/templates/workspace/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()); d["scopes"] = {}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
kv_quiet="$("${KVENV[@]}" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$kv_quiet" | grep -q "_workspace\` pack"; then
  bad "a workspace whose pack ships no scopes is accused of nothing" "$kv_quiet"
else ok "a workspace whose pack ships no scopes is accused of nothing"; fi
if printf '%s' "$kv_quiet" | grep -q "OK payments"; then
  ok "and its own scopes are still listed"
else bad "and its own scopes are still listed" "$kv_quiet"; fi

# The one documented route to making a scope the team's has to carry it. It did
# not: `--from-workspace` seeded the registry and dropped `scopes:`, so a team
# that followed the instructions still shipped no carve-up.
"${KVENV[@]}" "$DECK" pack new "$KV/seeded" --from-workspace >/dev/null 2>&1 || true
kv_seed="$(python3 - "$KV/seeded/templates/workspace/workspace.yaml" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(",".join(sorted((d.get("scopes") or {}))))
PY
)"
if [ "$kv_seed" = "billing,house,ledger,payments" ]; then
  ok "a pack seeded from a workspace carries the carve-up, not only the registry"
else bad "a pack seeded from a workspace carries the carve-up, not only the registry" "scopes seeded: $kv_seed"; fi
rm -rf "$KV"

# ------------------------------- a pack that belongs to an initiative
note "who is asking is not which board"
# A tracker source holds two kinds of field: which board it is, and who is asking
# for it. The second is per person by design — everybody authenticates as
# themselves, and a shared file naming one of them is both wrong and a small
# disclosure. Comparing the whole source made removing it for that reason report
# a divergence that was true, useless and permanent, and a warning nobody can
# clear is one nobody reads. Its own fixture: the carve-up group above mutates
# its workspace as it goes, and a check that borrows it measures whatever the
# previous check left behind.
WB="$(mktemp -d)"; WBP="$WB/packs/_workspace"
mkdir -p "$WB/.deck" "$WB/bench" "$WBP/config" "$WBP/templates/workspace"
printf 'markers: []\n' > "$WBP/config/detect.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$WB/.deck/toggles.yaml"
: > "$WB/theirs.yaml"
cat > "$WBP/templates/workspace/workspace.yaml" <<'YAML'
version: 1
repos: { bench: { path: bench } }
scopes:
  ledger:
    title: Ledger
    repos: [bench]
    backlog: [{ type: tasks, file: theirs.yaml }]
YAML
wb_desc() {   # <file> [extra key: value]
  cat > "$WB/.deck/workspace.yaml" <<YAML
version: 1
packs_root: packs
repos: { bench: { path: bench } }
scopes:
  ledger:
    title: Ledger
    repos: [bench]
    backlog: [{ type: tasks, file: $1${2:+, $2} }]
YAML
}
WBENV=(env -u DECK_PACKS DECK_ROOT="$WB" DECK_PACKS_ROOT="$WB/packs")

wb_desc theirs.yaml "user: ana"
who="$("${WBENV[@]}" "$DECK" doctor 2>&1 || true)"
# The line, not its wording: a check that greps for the new sentence passes on
# the old code for want of a match, and defends nothing.
if printf '%s' "$who" | grep '^  !! ' | grep -q 'ledger'; then
  bad "a board that differs only by who is asking is not a divergence" "$(printf '%s' "$who" | grep -i ledger | head -2)"
else
  ok "a board that differs only by who is asking is not a divergence"
fi

wb_desc mine.yaml "user: ana"
real="$("${WBENV[@]}" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$real" | grep -q 'they differ on `file`'; then
  ok "a board that is genuinely a different one still is, and the field is named"
else
  bad "a board that is genuinely a different one still is, and the field is named" "$(printf '%s' "$real" | grep -i ledger | head -2)"
fi
if printf '%s' "$real" | grep -q "different tasks"; then
  bad "and it does not describe results deck never fetched"
else
  ok "and it does not describe results deck never fetched"
fi
rm -rf "$WB"

note "a pack that belongs to an initiative"
# A pack reached an agent by three routes: named explicitly, shared by its
# directory name, or named after a repository. None of them says "this belongs
# to this initiative", so knowledge that only matters while one is running was
# either loaded for everybody or written nowhere. `scope:` in a pack's own
# config/detect.yaml is the fourth route, and it comes and goes with
# `deck --scope`.
SP="$(mktemp -d)"; SPP="$SP/packs"
mkdir -p "$SP/.deck" "$SP"/{api,server,ops} \
         "$SPP/_workspace"/{config,templates/workspace} \
         "$SPP/payments-ops"/{config,rules,templates/workspace} \
         "$SPP/ledger-pack"/{config,templates/workspace} \
         "$SPP/server/config"
for d in api server ops; do git -C "$SP/$d" init -q 2>/dev/null; done
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$SP/.deck/toggles.yaml"
cat > "$SP/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    lint: "true", impacts: [server] }
  server: { path: server, lint: "true", impacts: [] }
  ops:    { path: ops,    lint: "true", impacts: [] }
scopes:
  payments: { title: Payments migration, repos: [api, server] }
  house:    { title: A local errand,     repos: [ops] }
targets: []
YAML
printf 'markers: []\n' > "$SPP/_workspace/config/detect.yaml"
printf 'gates:\n  - { id: lint, title: Workspace lint, from_level: static, per_repo: "${repo.lint}" }\n' \
  > "$SPP/_workspace/config/gates.yaml"
cat > "$SPP/_workspace/templates/workspace/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    impacts: [server] }
  server: { path: server, impacts: [] }
  ops:    { path: ops,    impacts: [] }
scopes: {}
YAML
printf 'markers: []\n' > "$SPP/server/config/detect.yaml"
# The initiative's own pack: bound by its own file, not by where it sits.
printf 'markers: []\nscope: payments\n' > "$SPP/payments-ops/config/detect.yaml"
printf 'gates:\n  - { id: audit, title: Audit trail, from_level: static, per_repo: "echo auditing ${repo.name}" }\n' \
  > "$SPP/payments-ops/config/gates.yaml"
printf -- '---\npaths: ["**/*.py"]\n---\n\nThe vocabulary this initiative reports in.\n' \
  > "$SPP/payments-ops/rules/regs.md"
printf 'rules:\n  - { file: rules/regs.md }\n' > "$SPP/payments-ops/config/mount.yaml"
cat > "$SPP/payments-ops/templates/workspace/workspace.yaml" <<'YAML'
scopes:
  payments: { title: Payments migration, repos: [api, server] }
YAML
# A second initiative, versioned in a pack of its own — which is the whole of
# the other half: neither team edits the file the other one lives in.
printf 'markers: []\nscope: ledger\n' > "$SPP/ledger-pack/config/detect.yaml"
cat > "$SPP/ledger-pack/templates/workspace/workspace.yaml" <<'YAML'
scopes:
  ledger: { title: Ledger rewrite, repos: [ops] }
YAML
SPENV=(env DECK_ROOT="$SP" DECK_PACKS_ROOT="$SPP")

# Not in play means not in play: a gate it declares is not on the ladder while
# nobody has asked for the initiative.
sp_idle="$("${SPENV[@]}" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$sp_idle" | grep -q "audit"; then
  bad "a scope-bound pack declares nothing while its scope is inactive" "$sp_idle"
else ok "a scope-bound pack declares nothing while its scope is inactive"; fi

# And knowledge nobody can find is worse than knowledge loaded too widely, so
# the pack is still listed — with the command that brings it in.
sp_packs="$("${SPENV[@]}" "$DECK" packs 2>&1 || true)"
if printf '%s' "$sp_packs" | grep -q '^not in play'; then
  ok "a scope-bound pack that is not in play is listed rather than hidden"
else bad "a scope-bound pack that is not in play is listed rather than hidden" "$sp_packs"; fi
if printf '%s' "$sp_packs" | grep -q 'bring it in with: deck --scope payments'; then
  ok "and the listing names the command that brings it in"
else bad "and the listing names the command that brings it in" "$sp_packs"; fi

sp_scoped="$("${SPENV[@]}" "$DECK" --scope payments gate list 2>&1 || true)"
if printf '%s' "$sp_scoped" | grep -q "audit"; then
  ok "and under its own scope it reaches the ladder"
else bad "and under its own scope it reaches the ladder" "$sp_scoped"; fi

# Merge order is the stated one: an initiative is narrower than the workspace
# and wider than one codebase, so its layer sits between the two.
sp_order="$("${SPENV[@]}" "$DECK" --scope payments packs 2>&1 || true)"
sp_names="$(printf '%s' "$sp_order" | grep -E '^  [0-9]+  ' | awk '{print $2}' | tr '\n' ' ')"
if [ "$sp_names" = "_workspace payments-ops server " ]; then
  ok "it merges after the workspace-wide pack and before the repository's own"
else bad "it merges after the workspace-wide pack and before the repository's own" "got: $sp_names"; fi

# A collision resolves by the rule every other layer already uses, so there is
# one mechanism to learn rather than two.
cat > "$SPP/payments-ops/config/gates.yaml" <<'YAML'
gates:
  - { id: audit, title: Audit trail, from_level: static, per_repo: "echo auditing ${repo.name}" }
  - { id: lint,  title: Audited lint, from_level: static, per_repo: "${repo.lint}" }
YAML
check_fail "an id it reuses without \`overrides: true\` is refused" \
  "${SPENV[@]}" "$DECK" --scope payments gate list
python3 - "$SPP/payments-ops/config/gates.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("{ id: lint,  title:", "{ id: lint, overrides: true, title:"))
PY
check "and with it the initiative's pack has the last word" "Audited lint" \
  "${SPENV[@]}" "$DECK" --scope payments gate list
sp_outside="$("${SPENV[@]}" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$sp_outside" | grep -q "Workspace lint"; then
  ok "and outside the scope the same id is the workspace pack's again"
else bad "and outside the scope the same id is the workspace pack's again" "$sp_outside"; fi

# Its rules follow the same boundary its gates do. A mount walks the impact
# graph outside the subset, and an initiative has no claim on a repository it
# merely reaches.
check "its rule mounts into a repository the scope holds" "regs.md" \
  "${SPENV[@]}" "$DECK" --scope payments mount --task SP-1 --repos api --no-expand --dry-run
sp_mount="$("${SPENV[@]}" "$DECK" --scope payments mount --task SP-1 --repos ops --no-expand --dry-run 2>&1 || true)"
if printf '%s' "$sp_mount" | grep -q "regs.md"; then
  bad "and not into one outside it" "$sp_mount"
else ok "and not into one outside it"; fi
sp_narrow="$("${SPENV[@]}" "$DECK" --scope payments gate list --repos ops 2>&1 || true)"
if printf '%s' "$sp_narrow" | grep -q "audit.*skipped"; then
  ok "a gate it declares does not run outside the scope, even when --repos names one"
else bad "a gate it declares does not run outside the scope, even when --repos names one" "$sp_narrow"; fi

# A gate that appears and disappears with a flag is a different proposition
# from one every session carries, so the evidence has to say which scope was
# active and which pack each gate came from — and so does the page a reviewer
# reads instead of the diff.
"${SPENV[@]}" "$DECK" --scope payments gate run --task SP-1 --level static >/dev/null 2>&1
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["scope"]=="payments" else 1)' \
     "$SP/.deck/gates/SP-1.json"; then
  ok "the evidence records the scope the ladder climbed inside"
else bad "the evidence records the scope the ladder climbed inside" "$(cat "$SP/.deck/gates/SP-1.json" | head -6)"; fi
sp_bundle="$("${SPENV[@]}" "$DECK" bundle --task SP-1 2>&1 || true)"
if printf '%s' "$sp_bundle" | grep -q '^  scope    payments'; then
  ok "and the bundle says which initiative it was, whatever the coverage"
else bad "and the bundle says which initiative it was, whatever the coverage" "$sp_bundle"; fi
sp_md="$("${SPENV[@]}" "$DECK" bundle --task SP-1 --markdown 2>&1 || true)"
if printf '%s' "$sp_md" | grep -q '| audit | passed | payments-ops |'; then
  ok "and names the pack each gate came from, for a reviewer who was not there"
else bad "and names the pack each gate came from, for a reviewer who was not there" "$sp_md"; fi

# The promise to everybody not using this: with no scope declared, a pack bound
# to one is inert. Composition, ladder and catalog are compared with the pack
# present and with it taken away, and they have to be the same text.
sp_composition() {
  "${SPENV[@]}" "$DECK" gate list 2>&1
  "${SPENV[@]}" "$DECK" toggle list 2>&1
  "${SPENV[@]}" "$DECK" packs --json 2>&1 | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["packs"], indent=1))' 2>&1
}
python3 - "$SP/.deck/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()); d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
sp_present="$(sp_composition)"
mv "$SPP/payments-ops" "$SP/parked-payments"; mv "$SPP/ledger-pack" "$SP/parked-ledger"
sp_absent="$(sp_composition)"
mv "$SP/parked-payments" "$SPP/payments-ops"; mv "$SP/parked-ledger" "$SPP/ledger-pack"
if [ "$sp_present" = "$sp_absent" ]; then
  ok "where no scope is declared, a pack bound to one changes nothing at all"
else bad "where no scope is declared, a pack bound to one changes nothing at all" "the two compositions differ"; fi
python3 - "$SP/.deck/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {"payments": {"title": "Payments migration", "repos": ["api"]},
               "house": {"title": "A local errand", "repos": ["ops"]}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

# --------------------- an initiative versioned apart from the registry
note "an initiative versioned apart from the registry"
# `workspace_template()` stopped at the first pack shipping a template, so the
# registry and every scope lived in one versioned file and a second initiative
# meant editing the first one's. The registry still comes from one file — one
# product, one graph, and a second opinion about it is a contradiction. The
# scopes are merged, because several initiatives can be true at once.
sp_doctor="$("${SPENV[@]}" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$sp_doctor" | grep -q 'ships scope `ledger` (ops)'; then
  ok "a scope shipped by a pack of its own is compared, not overlooked"
else bad "a scope shipped by a pack of its own is compared, not overlooked" "$sp_doctor"; fi
if printf '%s' "$sp_doctor" | grep -q 'the `ledger-pack` pack ships scope `ledger`'; then
  ok "and the report names the pack that scope came from"
else bad "and the report names the pack that scope came from" "$sp_doctor"; fi
if printf '%s' "$sp_doctor" | grep -q 'scope `payments` holds different repositories here and in the `payments-ops` pack'; then
  ok "and a second initiative's divergence names its own pack, not the first's"
else bad "and a second initiative's divergence names its own pack, not the first's" "$sp_doctor"; fi
sp_refused="$("${SPENV[@]}" "$DECK" --scope ledger repos 2>&1 || true)"
if printf '%s' "$sp_refused" | grep -q 'but the `ledger-pack` pack ships it'; then
  ok "asking for it says which pack to copy the block from"
else bad "asking for it says which pack to copy the block from" "$sp_refused"; fi

# Two packs claiming one scope name is either a mistake or a deliberate
# override, and deck refuses to guess. It reports both, compares against
# neither, and does not then accuse this machine of having invented the name.
python3 - "$SPP/_workspace/templates/workspace/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {"payments": {"title": "Payments, the other opinion", "repos": ["api", "ops"]}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
sp_clash="$("${SPENV[@]}" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$sp_clash" | grep -q 'scope `payments` is shipped by more than one pack (_workspace, payments-ops)'; then
  ok "a scope name two packs ship is reported, never merged"
else bad "a scope name two packs ship is reported, never merged" "$sp_clash"; fi
if printf '%s' "$sp_clash" | grep -q 'compared against neither'; then
  ok "and this machine's carve-up is compared against neither of them"
else bad "and this machine's carve-up is compared against neither of them" "$sp_clash"; fi
if printf '%s' "$sp_clash" | grep -q "scope \`payments\` is this machine's own"; then
  bad "and it is not also called this machine's own, which would be false" "$sp_clash"
else ok "and it is not also called this machine's own, which would be false"; fi
python3 - "$SPP/_workspace/templates/workspace/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()); d["scopes"] = {}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

# The command that makes an initiative the team's, and the shape it writes.
"${SPENV[@]}" "$DECK" pack new pay-knowledge --dir "$SP/seeded" --scope payments --from-workspace >/dev/null 2>&1
if grep -q '^scope: payments' "$SP/seeded/config/detect.yaml"; then
  ok "deck pack new --scope writes the binding into the pack itself"
else bad "deck pack new --scope writes the binding into the pack itself" "$(cat "$SP/seeded/config/detect.yaml" 2>&1 | tail -3)"; fi
sp_seed="$(python3 - "$SP/seeded/templates/workspace/workspace.yaml" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(",".join(sorted(d.get("scopes") or {})), "|", ",".join(sorted(d.get("repos") or {})))
PY
)"
if [ "$sp_seed" = "payments | " ]; then
  ok "and a template holding that initiative and none of the registry"
else bad "and a template holding that initiative and none of the registry" "seeded: $sp_seed"; fi
check_fail "and refuses a scope this workspace does not declare" \
  "${SPENV[@]}" "$DECK" pack new ghost-pack --dir "$SP/ghost" --scope nowhere

# The registry is never taken from a scope pack, whatever is active: `deck init`
# has to seed the repositories, not one initiative's block.
"${SPENV[@]}" "$DECK" --scope payments init --force >/dev/null 2>&1
sp_seeded="$(python3 - "$SP/.deck/workspace.yaml" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(",".join(sorted(d.get("repos") or {})))
PY
)"
if [ "$sp_seeded" = "api,ops,server" ]; then
  ok "the registry is seeded from the workspace pack, never from a scope's"
else bad "the registry is seeded from the workspace pack, never from a scope's" "seeded repos: $sp_seeded"; fi
rm -rf "$SP"

# ------------------------------------------- the workflow against the pack
note "the workflow and the pack declare one ladder"
# `.github/workflows/ci.yml` keeps its own list of commands rather than calling
# `deck gate run`; the reasons are in that file's header. The price of a second
# list is that it can drift from the first, and it already had — `docs` was
# declared in the pack and run nowhere in CI, so the gate for the failure this
# repository kept having never ran on a push. These checks are what pays for
# the duplication.
#
# They read both files as data — a gate's `id`, a step's `# gate:` marker, a
# step's parsed `run` and `shell` — because there is no behaviour to exercise
# here: GitHub Actions is not runnable from this suite, and a check that
# pretended otherwise would be worse than one that says what it is.
ladder_report="$(python3 - "$REPO" <<'PY'
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
declared = {g["id"] for g in yaml.safe_load((root / "packs/_workspace/config/gates.yaml").read_text())["gates"]}
text = (root / ".github/workflows/ci.yml").read_text()
marked = set(re.findall(r"^\s*#\s*gate:\s*([a-z][a-z0-9-]*)\s*$", text, re.M))
steps = yaml.safe_load(text)["jobs"]["check"]["steps"]

# Each way the workflow could make the whole suite run: calling it, or calling
# the documents gate with no log for it to read.
runs_suite = [
    s
    for s in steps
    if "ci/smoke.sh" in s.get("run", "") or ("--counts" in s.get("run", "") and "--suite-log" not in s.get("run", ""))
]
writes_log = [s for s in steps if "ci/smoke.sh" in s.get("run", "") and "|" in s.get("run", "")]

print("unrun=" + ",".join(sorted(declared - marked)))
print("undeclared=" + ",".join(sorted(marked - declared)))
print("counts_checked=" + str(any("--counts" in s.get("run", "") for s in steps)))
print("suite_runs=" + str(len(runs_suite)))
if not writes_log:
    log_step = "none"
elif all(s.get("shell") == "bash" for s in writes_log):
    log_step = "bash"
else:
    log_step = "unsafe"
print("log_step=" + log_step)
PY
)"
ladder_says() {
  if printf '%s\n' "$ladder_report" | grep -qxF "$2"; then ok "$1"
  else bad "$1" "$(printf '%s\n' "$ladder_report" | grep "^${2%%=*}=" || printf 'no %s line' "${2%%=*}")"; fi
}
ladder_says "every gate the pack declares has a step in the workflow"          "unrun="
ladder_says "and no step claims a gate the pack does not declare"              "undeclared="
ladder_says "the workflow checks the check total the documents state"          "counts_checked=True"
ladder_says "and learns the real total without running the suite twice"        "suite_runs=1"
ladder_says "the step that pipes the suite into a log sets pipefail"           "log_step=bash"

# ---------------------------------------------------- the documents gate
note "the documents gate"
# On a tree of its own, so the checks can state a wrong total and name a
# command that was never there without editing this repository's documents.
DC="$(mktemp -d)"
mkdir -p "$DC/packs/_workspace/bin" "$DC/plugins/deck/bin" "$DC/ci"
COVER="$DC/packs/_workspace/bin/docs-cover.py"
cp "$REPO/packs/_workspace/bin/docs-cover.py" "$COVER"
cat > "$DC/plugins/deck/bin/deck" <<'SH'
#!/usr/bin/env bash
printf 'usage: deck [-h] {alpha,beta} ...\n'
SH
cat > "$DC/ci/smoke.sh" <<'SH'
#!/usr/bin/env bash
# Leaves a mark, so a check can prove the count check did not run it, and
# reports a total no document here states, so a run that reached this script
# is a run that fails.
: > "$(dirname "$0")/../suite-ran"
printf '999 checks, 0 failures\n'
SH
chmod +x "$DC/plugins/deck/bin/deck" "$DC/ci/smoke.sh"
printf 'ran the suite\n\033[32m41 checks, 0 failures\033[0m\n' > "$DC/suite.log"
cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it and `deck beta` stops it. The suite has 41 checks.
MD

cover="$(python3 "$COVER" --counts --suite-log "$DC/suite.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -eq 0 ] && printf '%s' "$cover" | grep -q "every command is named"; then
  ok "documents that match the code pass"
else bad "documents that match the code pass" "exit $cover_rc: $cover"; fi
# The point of --suite-log, and the acceptance criterion behind it: the total
# comes off a run that already happened, so a push runs the suite once.
if [ -f "$DC/suite-ran" ]; then
  bad "and the suite is not run a second time to learn its own total" "ci/smoke.sh was called anyway"
else ok "and the suite is not run a second time to learn its own total"; fi

printf '\n`deck gamma` retires it.\n' >> "$DC/README.md"
cover="$(python3 "$COVER" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "deck gamma"; then
  ok "a document offering a command the CLI does not have fails, and names it"
else bad "a document offering a command the CLI does not have fails, and names it" "exit $cover_rc: $cover"; fi

cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it. The suite has 41 checks.
MD
cover="$(python3 "$COVER" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "deck beta"; then
  ok "a command the documents never name still fails, and names it"
else bad "a command the documents never name still fails, and names it" "exit $cover_rc: $cover"; fi

cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it and `deck beta` stops it. The suite has 41 checks.
MD
printf '\033[32m7 checks, 0 failures\033[0m\n' > "$DC/stale.log"
cover="$(python3 "$COVER" --counts --suite-log "$DC/stale.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "say 41 checks; the suite has 7"; then
  ok "a stated total the suite does not have fails, and names both numbers"
else bad "a stated total the suite does not have fails, and names both numbers" "exit $cover_rc: $cover"; fi

cover="$(python3 "$COVER" --counts --suite-log "$DC/absent.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "no suite log at"; then
  ok "a suite log that is not there is an error, not a total nobody checked"
else bad "a suite log that is not there is an error, not a total nobody checked" "exit $cover_rc: $cover"; fi

: > "$DC/empty.log"
cover="$(python3 "$COVER" --counts --suite-log "$DC/empty.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "could not read the suite's own total"; then
  ok "a log with no total in it is an error too"
else bad "a log with no total in it is an error too" "exit $cover_rc: $cover"; fi

# A flag the workflow mistypes has to stop the run. Ignored, it would drop the
# count check back to running the suite itself — the cost this change removes,
# reintroduced silently.
cover="$(python3 "$COVER" --counts --suite-logg "$DC/suite.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "unrecognized arguments"; then
  ok "a mistyped flag is refused rather than ignored"
else bad "a mistyped flag is refused rather than ignored" "exit $cover_rc: $cover"; fi
rm -rf "$DC"

# ------------------------------------------------------ a ladder with no rungs
note "the commit-shape gate"
# Its own scratch repository: the gate reads git history, and the only way to
# check what it says about a bad subject is to write one.
CSD="$(mktemp -d)"
CS="$REPO/packs/_workspace/bin/commit-shape.py"
git init -q -b main "$CSD"
cs_git() { git -C "$CSD" -c user.email=t@t -c user.name=T "$@"; }
: > "$CSD/a"; cs_git add -A; cs_git commit -q -m "chore: seed"
CSBASE="$(cs_git rev-parse HEAD)"
cs_run() { (cd "$CSD" && env -u GITHUB_HEAD_REF DECK_BRANCH="$1" python3 "$CS" 2>&1); }

cs_out="$(cs_run "" )"; cs_rc=$?
if [ "$cs_rc" = 0 ] && printf '%s' "$cs_out" | grep -q 'nothing ahead'; then
  ok "a branch with nothing ahead of main is not a failure"
else bad "a branch with nothing ahead of main is not a failure" "$cs_out"; fi

cs_git checkout -q -b fix-49
: > "$CSD/b"; cs_git add -A; cs_git commit -q -m "arrumei o board."
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q 'is not Conventional Commits'; then
  ok "a subject that is not Conventional Commits is named"
else bad "a subject that is not Conventional Commits is named" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "and the issue the branch name carries is asked for by number"
else bad "and the issue the branch name carries is asked for by number" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q 'no commit on `fix-49` carries'; then
  ok "and the branch is what owes it, so the branch is what the message names"
else bad "and the branch is what owes it, so the branch is what the message names" "$cs_out"; fi

cs_git commit -q --amend -m "fix: name the board a scope reads"
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "a good subject alone does not satisfy a branch that names an issue"
else bad "a good subject alone does not satisfy a branch that names an issue" "$cs_out"; fi

cs_out="$(cs_run add-a-thing)"
if printf '%s' "$cs_out" | grep -q 'Closes'; then
  bad "a branch with no number in it is asked for no trailer" "$cs_out"
else ok "a branch with no number in it is asked for no trailer"; fi

cs_git commit -q --amend -m "fix: name the board a scope reads

Closes #49"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ] && printf '%s' "$cs_out" | grep -q 'the branch closes #49'; then
  ok "a Conventional subject with the trailer passes"
else bad "a Conventional subject with the trailer passes" "$cs_out"; fi

# An issue is closed once. Asking every commit for the trailer is noise the
# gate would be training people to write — and did, on the second commit of a
# two-commit branch whose first already carried it.
cs_git commit -q --allow-empty -m "docs: the note that goes with the fix"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ]; then
  ok "a second commit on the same branch does not owe the trailer again"
else bad "a second commit on the same branch does not owe the trailer again" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q '2 commit(s)'; then
  ok "and both are still judged, not skipped to reach that answer"
else bad "and both are still judged, not skipped to reach that answer" "$cs_out"; fi
# The half that stays per commit: a subject is a property of each message.
cs_git commit -q --amend --allow-empty -m "arrumei o commit"
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q "subject is not Conventional Commits: 'arrumei o commit'"; then
  ok "a bad subject is still reported against the commit that has it"
else bad "a bad subject is still reported against the commit that has it" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q 'Closes #49'; then
  bad "and the branch still owes nothing, its first commit having closed it" "$cs_out"
else ok "and the branch still owes nothing, its first commit having closed it"; fi
cs_git reset -q --hard HEAD~1

# The shape that broke this gate on its own first pull request. A forge builds
# a pull request at an ephemeral merge whose subject is `Merge <sha> into <sha>`
# — not `Merge branch`, not `Merge pull request`, which is what a pattern on the
# subject was written against. Having two parents is the fact.
CSTOP="$(cs_git rev-parse HEAD)"
cs_git checkout -q --detach "$CSBASE"
cs_git merge -q --no-ff -m "Merge ${CSTOP} into ${CSBASE:0:8}" "$CSTOP"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ]; then
  ok "the merge a forge builds a pull request at is not judged"
else bad "the merge a forge builds a pull request at is not judged" "$cs_out"; fi

# GITHUB_HEAD_REF over a detached HEAD: without it the branch name is `HEAD`,
# the issue number is gone, and the gate asks for less on the pull request than
# it asked for locally. On a branch of its own, because the one above closes its
# issue on its first commit and a branch that owes nothing proves nothing here.
cs_git checkout -q -b owes-nothing-yet "$CSBASE"
cs_git commit -q --allow-empty -m "fix: something with no trailer anywhere"
cs_out="$( (cd "$CSD" && GITHUB_HEAD_REF=fix-49 python3 "$CS" 2>&1) )"
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "the branch name comes from the environment when git has only a detached HEAD"
else bad "the branch name comes from the environment when git has only a detached HEAD" "$cs_out"; fi
cs_out="$( (cd "$CSD" && env -u GITHUB_HEAD_REF DECK_BRANCH=owes-nothing-yet python3 "$CS" 2>&1) )"
if printf '%s' "$cs_out" | grep -q 'Closes'; then
  bad "and a branch whose name carries no number is still asked for nothing" "$cs_out"
else ok "and a branch whose name carries no number is still asked for nothing"; fi
rm -rf "$CSD"

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

# --------------------------------------------------------------------- summary
printf '\n%s\n' "-----------------------------------------------"
total=$((pass + fail + skipped))
# The skipped ones are in the total on purpose: the suite is the same size
# wherever it runs, so a machine missing a tool reports the same number as one
# that has everything, and says what it could not run.
[ $skipped -gt 0 ] && note_skipped=" ($skipped skipped)" || note_skipped=""
if [ $fail -eq 0 ]; then
  printf '\033[32m%d checks, 0 failures%s\033[0m\n' "$total" "$note_skipped"
  exit 0
fi
printf '\033[31m%d failure(s) in %d checks%s\033[0m\n' "$fail" "$total" "$note_skipped"
exit 1
