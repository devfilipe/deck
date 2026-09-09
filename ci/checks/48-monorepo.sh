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
#
# The descriptor is in the collection, not in the project: `setup` writes
# `_workspaces/<name>/<scope>/workspace.yaml`, and the monorepo gains no
# `.deck/` at all. This block used to edit `$MR/.deck/workspace.yaml`, which
# stopped existing when the machine and the team were split — the heredoc
# raised FileNotFoundError into an otherwise green run, the edge was never
# added, and the checks below went on passing for a weaker reason than the
# one they name.
MRD="$MR/ai-packs/_workspaces/mono/default/workspace.yaml"
if [ -f "$MRD" ]; then ok "the descriptor lands in the collection, not in the product repository"; else bad "the descriptor lands in the collection, not in the product repository" "$MRD is missing"; fi
python3 - "$MRD" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["repos"]["schema"]["impacts"] = ["api"]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check "and the edge it carries is the one deck reads back" "2. api" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" impact schema
# A pack scaffolds with `rules/` empty, because mount walks it and a sample rule
# would be placed in every workspace. One real rule per package is what makes
# this a mount — and the exclude block is per package, so each has to receive
# something of its own. A workspace layer would land once, at the root, and
# prove nothing about the packages.
for pkg in schema api cli; do
  printf -- '---\npaths: ["**/*"]\n---\n\nA convention for '"$pkg"'.\n' \
    > "$MR/ai-packs/_repos/$pkg/rules/house.md"
done
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MR" "$DECK" mount --task mono --repos schema api cli >/dev/null 2>&1
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
if python3 "$REPO/ci/docs-cover.py" >/dev/null 2>&1; then
  ok "every command deck exposes is named in the documents"
else bad "every command deck exposes is named in the documents" "$(python3 "$REPO/ci/docs-cover.py" 2>&1 | head -3)"; fi
# A document naming a deleted file is the same failure as one naming a renamed
# command, and it went uncaught: the README offered a recording that had been
# removed for carrying a machine's session name through into its output.
if python3 - "$REPO" <<'PY'
import sys, pathlib, importlib.util
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dc", root / "ci/docs-cover.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
gone = m.dangling_paths("see `asciinema play docs/tour.cast` for the recording")
here = m.dangling_paths("run `./ci/smoke.sh` and read `docs/tour.sh`")
sys.exit(0 if gone == ["docs/tour.cast"] and here == [] else 1)
PY
then ok "a document pointing at a file that is gone is reported"
else bad "a document pointing at a file that is gone is reported"; fi

# The tracker filter field — `query:` and `include:` for github, `query:` for
# gerrit, `state:`/`labels:` for gitlab, `jql:` for jira — used to live in no
# document at all (#18). The synthetic prose below names whatever the table
# holds: it stands for "a document that names every field", so a field added to
# the table and not to it would prove nothing.
# `deck --help` cannot enumerate it the way it enumerates a subcommand, so it
# gets its own hand-kept check rather than being folded into the command one.
# What proves it is a count, not a sentence: every (provider, field) pair
# missing from prose that names none of them, none missing from prose that
# names every field each provider reads.
if python3 - "$REPO" <<'PY'
import sys, pathlib, importlib.util
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("dc", root / "ci/docs-cover.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
total = sum(len(v) for v in m.TRACKER_FIELDS.values())
silent = m.missing_tracker_fields("no tracker field named anywhere in here")
named = m.missing_tracker_fields("`query:` `include:` `state:` `labels:` `jql:`")
sys.exit(0 if len(silent) == total and len(named) == 0 else 1)
PY
then ok "a tracker filter field named nowhere is reported, and one named everywhere is not"
else bad "a tracker filter field named nowhere is reported, and one named everywhere is not"
fi
# Against the documents themselves, not a synthetic string: PACKS.md carries
# all four fields now, so none is missing from the real prose the gate reads.
real_fields="$(cd "$REPO" && python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('dc', 'ci/docs-cover.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
prose = '\n'.join((m.ROOT / d).read_text(encoding='utf-8') for d in m.DOCS if (m.ROOT / d).is_file())
print(len(m.missing_tracker_fields(prose)))
")"
if [ "$real_fields" = "0" ]; then
  ok "every tracker filter field is named in the documents"
else
  bad "every tracker filter field is named in the documents" "missing=$real_fields"
fi

# The count gate is what catches a stale total, and it had two holes: it read
# five documents while six state the number, and its pattern took exactly three
# digits, so it would have gone quiet the day the suite passed 999 and reported
# success over whatever the documents last said.
dc="$(cd "$REPO" && python3 -c "
import importlib.util, re
spec = importlib.util.spec_from_file_location('dc', 'ci/docs-cover.py')
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

note "a closure with nothing behind it but the ladder"
# `board done` refuses while a declared acceptance criterion is unaccepted, and
# it is exactly as strict as its source allows. No tracker has a field for
# them, and deck does not read them out of an issue body — so a board moved
# onto one arrives with none, the guard has nothing to fire on, and the task
# closed on the ladder alone without a word. The closure is still allowed; the
# silence is what is fixed.
AW="$(mktemp -d)"; mkdir -p "$AW/.deck/gates" "$AW/a"
git -C "$AW/a" init -q
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$AW/.deck/toggles.yaml"
cat > "$AW/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  a: { path: a, role: schema }
targets: []
backlog:
  - { type: tasks, file: board.yaml }
YAML
cat > "$AW/board.yaml" <<'YAML'
version: 1
tasks:
  - { id: AW-1, title: nothing here says what it was for, repos: [a], status: open }
  - { id: AW-2, title: this one says, repos: [a], status: open, acceptance: [the thing works] }
YAML
# The evidence `done` looks for before it considers anything else, written
# rather than produced: what is under test is the criteria guard, not the
# ladder that has to run before it is reached.
printf '{"gates": []}\n' > "$AW/.deck/gates/AW-2.json"
aw() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$AW" "$DECK" "$@"; }

check_fail "a file board still refuses to close while a criterion is unaccepted" aw board done AW-2 --yes

# One command, run twice, differing only in whether the task declared any
# criteria — so what is being read is the difference the declaration makes and
# not a sentence either run happens to print.
none="$(aw board done AW-1 --force --yes 2>&1 || true)"
some="$(aw board done AW-2 --force --yes --accept "the thing works" 2>&1 || true)"
if printf '%s' "$none" | grep -qF "closed AW-1" && printf '%s' "$none" | grep -qF "acceptance criteria"; then
  ok "a task whose source carries no criteria still closes, and the closure says so"
else
  bad "a task whose source carries no criteria still closes, and the closure says so" "$none"
fi
if printf '%s' "$some" | grep -qF "closed AW-2" && ! printf '%s' "$some" | grep -qF "acceptance criteria"; then
  ok "and a closure that had them says nothing, so the words mean something when they appear"
else
  bad "and a closure that had them says nothing, so the words mean something when they appear" "$some"
fi

# The bundle is the other place a reviewer meets the same task, and it has to
# agree: a delivery with nothing stating what it was for is qualified there too.
bundled() { printf '%s' "$1" | python3 -c "
import json, sys
verdict = json.load(sys.stdin)['verdict']
said = verdict['qualifiers'] + [b['why'] for b in verdict['blockers']]
print(sum(1 for t in said if 'acceptance criteria' in t))" 2>&1 || true; }
b1="$(aw bundle --task AW-1 --json 2>&1 || true)"
b2="$(aw bundle --task AW-2 --json 2>&1 || true)"
if [ "$(bundled "$b1")" = 1 ] && [ "$(bundled "$b2")" = 0 ]; then
  ok "and the bundle qualifies the one with nothing behind it, and only that one"
else
  bad "and the bundle qualifies the one with nothing behind it, and only that one" \
    "no criteria=$(bundled "$b1") criteria accepted=$(bundled "$b2")"
fi
rm -rf "$AW"

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
CU="$(mktemp -d)/ws"; mkdir -p "$CU"/{keep-a,keep-b,noise-c} "$CU/pk/_workspaces/all/default/config" "$CU/pk/_workspaces/all/default/templates/workspace"
for r in keep-a keep-b noise-c; do git -C "$CU/$r" init -q; echo x > "$CU/$r/README.md"; done
printf 'version: 1\ntoggles:\n' > "$CU/pk/_workspaces/all/default/config/toggles.yaml"
printf '# from the pack, not the generic template\nversion: 1\nrepos: {}\ntargets: []\nhouse_style: yes\n' \
  > "$CU/pk/_workspaces/all/default/templates/workspace/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CU" "$DECK" setup --workspace curated --packs-root "$CU/pk" --repos keep-a,keep-b 2>&1 || true)"
if printf '%s' "$out" | grep -q "left out 1"; then ok "setup keeps only the repositories named"; else bad "setup keeps only the repositories named" "$out"; fi
if printf '%s' "$out" | grep -q "shape from the .*pack"; then ok "and takes the descriptor shape from the pack"; else bad "and takes the descriptor shape from the pack" "$out"; fi
CU_DESC="$CU/pk/_workspaces/curated/default/workspace.yaml"
if grep -q "house_style" "$CU_DESC" 2>/dev/null; then ok "so what the pack declared survives into the descriptor"; else bad "so what the pack declared survives into the descriptor" "$CU_DESC"; fi
if grep -q "noise-c" "$CU_DESC" 2>/dev/null; then bad "a repository left out stays out"; else ok "a repository left out stays out"; fi
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
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DV" "$DECK" setup --workspace devtool-ws --dry-run --packs-root "$DV/pk" 2>&1 || true)"
if printf '%s' "$out" | grep -q "the manifest does not mention"; then
  ok "a checkout the manifest never names is kept, not dropped"
else bad "a checkout the manifest never names is kept, not dropped" "$out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DV" "$DECK" setup --workspace devtool-ws --packs-root "$DV/pk" --repos edited 2>&1 || true)"
if grep -q "build/workspace/sources/edited" "$DV/pk/_workspaces/devtool-ws/default/workspace.yaml" 2>/dev/null; then
  ok "a repository four levels down is found"
else bad "a repository four levels down is found" "$out"; fi
if grep -q "vendored" "$DV/pk/_workspaces/devtool-ws/default/workspace.yaml" 2>/dev/null; then
  bad "and --repos still leaves the rest out"
else ok "and --repos still leaves the rest out"; fi

# State lives under ~/.deck/workspaces/<name>/, so the name is the key. A second
# workspace claiming a name already taken by a different directory would write
# over the first one's evidence and mounts with neither of them being wrong
# about anything, and nothing would say so. Two fixtures here were both called
# `ws` and found it; two checkouts called `build` would find it in earnest.
# A --dry-run is a promise about where the run will write. setup computed the
# machine file's path twice — once to report, once to write — and the report
# named `<project>/.deck/machine.yaml`, which setup has not written since
# machine state moved to the home directory. The plan has to name the path the
# run uses, and this compares the two literally.
PR="$(mktemp -d)/ws"; mkdir -p "$PR/pk/_workspace/config" "$PR/one" "$PR/.repo/manifests"
cat > "$PR/.repo/manifests/default.xml" <<'XML'
<manifest><project name="one" path="one"/></manifest>
XML
planned="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PR" "$DECK" setup --dry-run --workspace planned-ws --packs-root "$PR/pk" --repos one 2>&1 | tr -d '\r' | grep -o '[^ ]*machine\.yaml' | head -1)"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PR" "$DECK" setup --workspace planned-ws --packs-root "$PR/pk" --repos one >/dev/null 2>&1 || true
if [ -n "$planned" ] && [ -f "$planned" ]; then
  ok "the machine file a --dry-run names is the one the run writes"
else bad "the machine file a --dry-run names is the one the run writes" "planned=$planned"; fi
if [ -e "$PR/.deck/machine.yaml" ]; then
  bad "and the run leaves no machine file inside the project" "$(ls -a "$PR/.deck")"
else ok "and the run leaves no machine file inside the project"; fi
rm -rf "$PR"

# `--create-packs` announces a shared pack and has to produce one. Writing the
# descriptor into `_workspaces/<name>/default` makes that directory a
# discovered layer, and the scaffold skipped itself on the strength of that —
# leaving a "shared (every repository)" pack that was one YAML file with no
# `config/`, so a workspace-wide gate had nowhere to be declared.
# Two things a scope must not do quietly. `deck scope new <name> <repo> <repo>`
# collected the repositories and dropped them, creating an empty scope and then
# telling you to add the ones you had just typed. And `deck scope select none`
# cleared the workspace along with the scope, which strands a workspace whose
# descriptor lives in a collection: no `.deck/` in its tree, no markers, so
# nothing resolves the root and every later command fails from inside it.
# `propose apply` and `deck import` both built the descriptor's path from the
# root instead of using the resolved one. In a workspace whose descriptor lives
# in a collection that path holds nothing: `load_yaml` answers `{}` for a file
# that is not there, so apply found no repositories, matched no edge, and said
# "nothing to add" over a proposal it had understood — a silent no-op that
# reads as success. `import` had the mirror of it, writing a second descriptor
# into the project.
# `mount.yaml` carries `plugin` and `marketplace` and nothing else: `rules/`,
# `skills/` and `agents/` are walked. A `rules:` entry left over from when it
# was a list places nothing and used to say nothing, so a rule a config file
# appeared to declare was the one nobody would notice missing. `machine.yaml`
# already reports a key nothing reads; this is the same rule for the other file
# a person edits by hand.
# A gate id is workspace-wide, and the drafter could not see which were taken.
# Two Python repositories both proposed `ruff-check` — each right on its own,
# and together a workspace where `deck gate list` refuses to load anything
# until somebody renames one. `--show-prompt` costs nothing and calls nothing,
# so the list is asserted where it is built.
# Gates are appended as text so a person's comments survive, and the key has to
# be one a list item can attach to. A pack carrying `gates: []` took the append
# and stopped parsing — and the failure surfaced later, at `deck gate list`,
# about a file a different command had written.
# A toggle draft is refused on purpose — a person decides which pack asks the
# question, and whether the wording survives being read cold. The refusal used
# to stop at "cannot be applied", which reads as a defect rather than a
# boundary and sends nobody anywhere.
# `group` and `stage` are closed vocabularies that `deck toggle validate
# --strict` checks. The draft was never told them, invented `release` and
# `review`, and the entry failed validation in a different command after
# somebody had already placed it.
# The ordinary case, and the one `setup` used to refuse whole: a workspace that
# already works gains a repository, and that repository needs a pack. The dry
# run planned exactly that and the real run declined to do any of it. The
# refusal protects the descriptor, which is the destructive half; it never had
# a reason to protect the packs.
# `--only` is what you reach for after fixing one gate, to avoid re-running a
# long suite. It used to write the whole evidence file from the one gate it
# ran, so the long suite's result was the price — and `deck bundle`, which
# reads this file, then told a reviewer the ladder had completed no rung.
# One layering, two answers: `deck packs` called a duplicate id an overlay and
# `deck gate run` refused to run at all. `packs` is the surface whose whole job
# is "what does this add up to", so a reader who checks it first has to get the
# answer the run will give.
# Everybody builds, and one repository builds differently. A pack named after a
# repository already scopes a gate it INTRODUCES to that repository; overriding
# a shared one widened instead, so one repository's command replaced the shared
# command for all of them, silently.
# The `repos:` layer was readable and unwritable: `layers()` resolved it and no
# command produced it, so a per-repository choice and its reason had to be
# hand-edited into the choices file.
# `propose pack` drafts skills and agents, and `apply` writes them where Claude
# Code loads them from: `skills/<name>/SKILL.md` and `agents/<name>.md`. Held to
# a higher bar than a rule, because a rule that is wrong gets argued with and a
# procedure that is wrong gets executed — every step carries the file it was
# read from, and the file says it has not been followed yet.
# Proposing nothing is a real answer, and a real answer is one somebody can
# read. An empty array on its own cannot be told apart from a question that was
# never asked — which is the whole complaint that put skills and agents in the
# schema. The note is printed, and written into the pack so the next person to
# open the directory sees the question was asked.
# Somebody joining a workspace the team already set up has the collection — it
# is in git — and needs only the machine half. `setup` rewrote the descriptor
# from a fresh discovery instead: measured, a second person's first command
# turned the team's `impacts: [r2]` into `impacts: []`, in a versioned file,
# with nothing said.
# A mounted pack is a copy, and what a task taught that lives only in the copy —
# or only in the conversation — goes when the copy does. `unmount` is the last
# moment anybody is looking, and it used to say nothing about that.
# The other `propose` commands read a repository, which sits still. This one
# reads a session — the only place a wrong assumption and the three attempts it
# cost are written down. It writes nothing: a lesson nobody agreed with is one
# more thing every agent reads forever.
# "It only removes what it placed" has to include the folders it placed them
# in. A skill is `skills/<name>/SKILL.md` — a directory deck creates — while a
# rule is a flat file, so removing the file left the folder behind: measured, an
# unmount reported 28 artifacts taken back and left two empty directories it had
# made.
# Transcripts are scoped to the workspace so deck stops GUESSING which session
# is a task's — it used to return whatever had most recently written anywhere.
# Naming an id is not guessing, and a session that works a workspace from
# OUTSIDE it writes under its own directory: invisible to the scope, and
# exactly the session somebody means. Worse, a named id that was not in scope
# fell through and handed back the newest transcript in scope instead — a wrong
# answer wearing a right one.
TR="$(mktemp -d)"; export CLAUDE_PROJECTS_HOME="$TR"
SS="$(mktemp -d)/ws"; mkdir -p "$SS/.deck" "$SS/r1"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\n' > "$SS/.deck/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SS" "$DECK" propose lessons --session no-such-session-id 2>&1 || true)"
if printf '%s' "$out" | grep -q "no transcript anywhere is named no-such-session-id"; then
  ok "a named session that exists nowhere is refused, not substituted"
else bad "a named session that exists nowhere is refused, not substituted" "$out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SS" "$DECK" propose lessons 2>&1 || true)"
if printf '%s' "$out" | grep -q -- "--session"; then
  ok "and a workspace with no transcript in scope is told how to name one"
else bad "and a workspace with no transcript in scope is told how to name one" "$out"; fi
rm -rf "$SS" "$TR"; unset CLAUDE_PROJECTS_HOME

RD="$(mktemp -d)/ws"; mkdir -p "$RD/.deck" "$RD/r1" "$RD/pk/_repos/r1/config" "$RD/pk/_repos/r1/skills/a-procedure"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$RD/.deck/workspace.yaml"
printf 'markers: []\n' > "$RD/pk/_repos/r1/config/detect.yaml"
printf -- '---\nname: a-procedure\n---\n\nSteps.\n' > "$RD/pk/_repos/r1/skills/a-procedure/SKILL.md"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RD" "$DECK" mount --task T --repos r1 >/dev/null 2>&1 || true
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RD" "$DECK" unmount --task T >/dev/null 2>&1 || true
if [ -d "$RD/r1/.claude" ]; then
  bad "unmount takes back the directories it created, not only the files" "$(find "$RD/r1/.claude" 2>&1)"
else ok "unmount takes back the directories it created, not only the files"; fi
# And never a directory somebody else put something in.
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RD" "$DECK" mount --task T2 --repos r1 >/dev/null 2>&1 || true
# Beside the skill deck placed, because this pack carries no rule and
# `.claude/rules/` would not exist to write into.
mkdir -p "$RD/r1/.claude/skills"
printf 'mine\n' > "$RD/r1/.claude/skills/not-decks.md"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RD" "$DECK" unmount --task T2 >/dev/null 2>&1 || true
if [ -f "$RD/r1/.claude/skills/not-decks.md" ]; then
  ok "and leaves a directory somebody else put something in"
else bad "and leaves a directory somebody else put something in" "$(find "$RD/r1" 2>&1)"; fi
rm -rf "$RD"

# What makes a lesson admissible is that it names what would have caught it: a
# gate names a command, a rule names its `paths:`. One that names neither is a
# diary entry — and defaulting it to `**/*` was the worst way to take one, since
# it then loads on every file read, forever, for a lesson nobody could scope.
# The suite's check total lived in four documents. Every change that added a
# check edited four that had nothing to do with it, and two branches that both
# added one conflicted on four lines whose resolution was neither side's number
# but the sum — between two unrelated fixes, in one day. It now lives in
# CONTRIBUTING.md alone, and the `docs` gate refuses a second copy rather than
# trusting anybody to remember.
# The symmetric half of the diary rule. What makes a lesson admissible is that
# it names what would have caught it: a rule names its `paths:`, a gate names
# the command. A gate whose text is a sentence becomes a `per_repo:` that fails
# every run with a shell error, which is worse than the lesson never landing.
# `deck packs --json` crashed for ANY workspace holding a pack: an internal set
# used to tell an overlay from a collision was spread into each row, and
# `json.dumps` cannot serialise a set. Nothing exercised the JSON shape, so a
# command that worked in plain text was broken in the form a machine reads —
# found by an agent working on something else entirely.
PJ="$(mktemp -d)/ws"; mkdir -p "$PJ/.deck" "$PJ/r1" "$PJ/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$PJ/.deck/workspace.yaml"
printf 'markers: []\n' > "$PJ/pk/_repos/r1/config/detect.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PJ" "$DECK" packs --json 2>&1 || true)"
if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  ok "deck packs --json is JSON, for a workspace that holds a pack"
else bad "deck packs --json is JSON, for a workspace that holds a pack" "$out"; fi
if printf '%s' "$out" | grep -q "_overrides"; then
  bad "and carries no key meant only for the code that built it" "$out"
else ok "and carries no key meant only for the code that built it"; fi
rm -rf "$PJ"

GD="$(mktemp -d)/ws"; mkdir -p "$GD/.deck/proposals" "$GD/r1" "$GD/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$GD/.deck/workspace.yaml"
printf 'markers: []\n' > "$GD/pk/_repos/r1/config/detect.yaml"
cat > "$GD/.deck/proposals/lessons-gd.json" <<'JSON'
{
 "kind": "lessons",
 "proposal": {
  "session": "s1",
  "lessons": [
   {
    "kind": "gate",
    "name": "runnable one",
    "text": "ruff check src",
    "evidence": "the lint that would have caught it",
    "confidence": "high"
   },
   {
    "kind": "gate",
    "name": "a description",
    "text": "Someone should check the imports are tidy.",
    "evidence": "felt true",
    "confidence": "high"
   }
  ],
  "nothing_because": "",
  "unsure": []
 }
}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GD" "$DECK" propose apply "$GD/.deck/proposals/lessons-gd.json" --into "$GD/pk/_repos/r1" --confidence medium --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "a gate's text has to BE the command"; then
  ok "a gate lesson that describes a check instead of writing one is refused"
else bad "a gate lesson that describes a check instead of writing one is refused" "$out"; fi
if grep -q "ruff check src" "$GD/pk/_repos/r1/config/gates.yaml" 2>/dev/null; then
  ok "and the runnable one beside it still lands"
else bad "and the runnable one beside it still lands" "$(cat "$GD/pk/_repos/r1/config/gates.yaml" 2>&1)"; fi
if grep -q "Someone should check" "$GD/pk/_repos/r1/config/gates.yaml" 2>/dev/null; then
  bad "and no sentence reaches per_repo" "$(cat "$GD/pk/_repos/r1/config/gates.yaml" 2>&1)"
else ok "and no sentence reaches per_repo"; fi
rm -rf "$GD"

DI="$(mktemp -d)/ws"; mkdir -p "$DI/.deck/proposals" "$DI/r1" "$DI/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$DI/.deck/workspace.yaml"
printf 'markers: []\n' > "$DI/pk/_repos/r1/config/detect.yaml"
cat > "$DI/.deck/proposals/lessons-di.json" <<'JSON'
{
 "kind": "lessons",
 "proposal": {
  "session": "abc123",
  "lessons": [
   {
    "kind": "rule",
    "name": "scoped one",
    "text": "Rotate before restart.",
    "paths": [
     "conf/pki/**"
    ],
    "evidence": "three attempts",
    "confidence": "high"
   },
   {
    "kind": "rule",
    "name": "a diary entry",
    "text": "I should read more carefully.",
    "evidence": "felt true",
    "confidence": "high"
   }
  ],
  "nothing_because": "",
  "unsure": []
 }
}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DI" "$DECK" propose apply "$DI/.deck/proposals/lessons-di.json" --into "$DI/pk/_repos/r1" --confidence medium --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "a rule with no .paths:. applies to everything"; then
  ok "a lesson that names no paths is refused as a diary entry"
else bad "a lesson that names no paths is refused as a diary entry" "$out"; fi
if ! grep -rl '\*\*/\*' "$DI/pk/_repos/r1/rules" >/dev/null 2>&1; then
  ok "and never lands as a rule scoped to every file"
else bad "and never lands as a rule scoped to every file" "$(cat "$DI"/pk/_repos/r1/rules/*.md 2>&1)"; fi
if find "$DI/pk/_repos/r1/rules" -name '*.md' 2>/dev/null | grep -q .; then
  ok "and the scoped lesson beside it still lands"
else bad "and the scoped lesson beside it still lands" "$out"; fi
rm -rf "$DI"

LS="$(mktemp -d)/ws"; mkdir -p "$LS/.deck/proposals" "$LS/r1" "$LS/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$LS/.deck/workspace.yaml"
printf 'markers: []\n' > "$LS/pk/_repos/r1/config/detect.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LS" "$DECK" propose lessons --show-prompt 2>&1 || true)"
if printf '%s' "$out" | grep -q "no session of this workspace has a transcript"; then
  ok "propose lessons refuses when there is no session to read"
elif printf '%s' "$out" | grep -q "Packs that could hold it"; then
  ok "propose lessons names the packs a lesson could go into"
else bad "propose lessons refuses when there is no session, or names the packs" "$out"; fi
# Applying one: a lesson about a repository IS a rule about it, so it goes
# through the same writer rather than a second path that would drift.
cat > "$LS/.deck/proposals/lessons-t.json" <<'JSON'
{
 "kind": "lessons",
 "proposal": {
  "session": "abc123",
  "lessons": [
   {
    "kind": "rule",
    "name": "rotate before restart",
    "text": "The NBI certificate is rotated before the restart, not after.",
    "paths": [
     "conf/pki/**"
    ],
    "evidence": "three attempts; the restart read the old cert",
    "confidence": "high"
   },
   {
    "kind": "toggle",
    "name": "how far back",
    "text": "How far back the published history goes",
    "evidence": "asked twice in the session",
    "confidence": "medium"
   }
  ],
  "nothing_because": "",
  "unsure": []
 }
}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LS" "$DECK" propose apply "$LS/.deck/proposals/lessons-t.json" --into "$LS/pk/_repos/r1" --confidence medium --yes 2>&1 || true)"
if find "$LS/pk/_repos/r1/rules" -name '*.md' 2>/dev/null | grep -q .; then
  ok "applying a lessons proposal writes the rule into the pack"
else bad "applying a lessons proposal writes the rule into the pack" "$out"; fi
if find "$LS/pk/_repos/r1/rules" -name '*.md' -exec grep -l "learned in session abc123" {} + 2>/dev/null | grep -q .; then
  ok "and the evidence says which session taught it"
else bad "and the evidence says which session taught it" "$(cat "$LS"/pk/_repos/r1/rules/*.md 2>&1)"; fi
if printf '%s' "$out" | grep -q "deck propose toggle"; then
  ok "and a lesson that is a toggle is named, not written"
else bad "and a lesson that is a toggle is named, not written" "$out"; fi
rm -rf "$LS"

CL="$(mktemp -d)/ws"; mkdir -p "$CL/.deck" "$CL/r1" "$CL/pk/_repos/r1/config" "$CL/pk/_repos/r1/rules"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$CL/.deck/workspace.yaml"
printf 'markers: []\n' > "$CL/pk/_repos/r1/config/detect.yaml"
printf -- '---\npaths: ["**/*"]\n---\n\nA convention.\n' > "$CL/pk/_repos/r1/rules/a.md"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CL" "$DECK" mount --task T --repos r1 >/dev/null 2>&1 || true
echo "edited by hand" >> "$CL/r1/.claude/rules/deck-a.md"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CL" "$DECK" unmount --task T 2>&1 || true)"
if printf '%s' "$out" | grep -q "what did the task teach"; then
  ok "unmount asks what the task taught, at the last moment anybody is looking"
else bad "unmount asks what the task taught, at the last moment anybody is looking" "$out"; fi
if printf '%s' "$out" | grep -q "deck save "; then
  ok "and names deck save when an edit would otherwise be left behind"
else bad "and names deck save when an edit would otherwise be left behind" "$out"; fi
# Relative to the binary, which is `plugins/deck/bin/deck`. An unset variable
# aborts the block under `set -u`, and the check then reports nothing at all —
# neither pass nor fail, which is the one outcome a check must not have.
if [ -f "$(dirname "$DECK")/../skills/closing/SKILL.md" ]; then
  ok "and a closing skill exists to say what belongs where"
else bad "and a closing skill exists to say what belongs where" "$(dirname "$DECK")/../skills"; fi
rm -rf "$CL"

JN="$(mktemp -d)/ws"; mkdir -p "$JN/r1" "$JN/r2" "$JN/.repo/manifests" "$JN/coll/_workspaces/produto/default" "$JN/coll/_repos/r1/config"
cat > "$JN/.repo/manifests/default.xml" <<'XML'
<manifest><project name="r1" path="r1"/><project name="r2" path="r2"/></manifest>
XML
printf 'markers: []\n' > "$JN/coll/_repos/r1/config/detect.yaml"
printf 'version: 1\nrepos:\n  r1:\n    path: r1\n    impacts:\n    - r2\n  r2:\n    path: r2\n    impacts: []\nscopes:\n  hardening:\n    title: H\n    repos: [r1]\n' > "$JN/coll/_workspaces/produto/default/workspace.yaml"
JN_DESC="$JN/coll/_workspaces/produto/default/workspace.yaml"
before="$(cat "$JN_DESC")"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$JN" "$DECK" setup --workspace produto --packs-root "$JN/coll" 2>&1 || true)"
if [ "$before" = "$(cat "$JN_DESC")" ]; then
  ok "setup leaves a descriptor the collection already carries exactly as it is"
else bad "setup leaves a descriptor the collection already carries exactly as it is" "$(diff <(printf '%s' "$before") "$JN_DESC")"; fi
if printf '%s' "$out" | grep -q "Joining a workspace that already has a descriptor"; then
  ok "and says it is joining rather than writing"
else bad "and says it is joining rather than writing" "$out"; fi
if [ -f "$DECK_HOME_STATE/workspaces/produto/machine.yaml" ]; then
  ok "and still creates the machine half the joiner needs"
else bad "and still creates the machine half the joiner needs" "$out"; fi
out="$(cd "$JN" && env -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_ROOT "$DECK" impact r1 2>&1 || true)"
if printf '%s' "$out" | grep -q "reaches 1 repository"; then
  ok "so the team's graph answers on the joiner's first command"
else bad "so the team's graph answers on the joiner's first command" "$out"; fi
rm -rf "$JN"

NN="$(mktemp -d)/ws"; mkdir -p "$NN/.deck/proposals" "$NN/r1" "$NN/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$NN/.deck/workspace.yaml"
printf 'markers: []\n' > "$NN/pk/_repos/r1/config/detect.yaml"
cat > "$NN/.deck/proposals/pack-nn.json" <<'JSON'
{
 "kind": "pack",
 "proposal": {
  "repo": "r1",
  "gates": [],
  "rules": [],
  "toggles": [],
  "questions": [],
  "unsure": [],
  "skills": [],
  "agents": [],
  "skills_note": "every command here is a single make target, already a gate",
  "agents_note": "nothing about this repository needs a posture the default lacks"
 }
}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$NN" "$DECK" propose apply "$NN/.deck/proposals/pack-nn.json" --into "$NN/pk/_repos/r1" --confidence medium --yes 2>&1 || true)"
if [ -f "$NN/pk/_repos/r1/skills/NONE.md" ] && [ -f "$NN/pk/_repos/r1/agents/NONE.md" ]; then
  ok "a draft that proposes no skill and no agent records why, in the pack"
else bad "a draft that proposes no skill and no agent records why, in the pack" "$out"; fi
if grep -q "already a gate" "$NN/pk/_repos/r1/skills/NONE.md" 2>/dev/null; then
  ok "and the note is the reason, not a placeholder"
else bad "and the note is the reason, not a placeholder" "$(cat "$NN/pk/_repos/r1/skills/NONE.md" 2>&1)"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$NN" "$DECK" mount --task N --repos r1 2>&1 || true)"
if printf '%s' "$out" | grep -q "agent "; then
  bad "and mount never places that note as an artifact" "$out"
else ok "and mount never places that note as an artifact"; fi
rm -rf "$NN"

SA="$(mktemp -d)/ws"; mkdir -p "$SA/.deck/proposals" "$SA/r1" "$SA/pk/_repos/r1/config"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\npacks_root:\n- pk\n' > "$SA/.deck/workspace.yaml"
printf 'markers: []\n' > "$SA/pk/_repos/r1/config/detect.yaml"
cat > "$SA/.deck/proposals/pack-sa.json" <<'JSON'
{
 "kind": "pack",
 "proposal": {
  "repo": "r1",
  "gates": [],
  "rules": [],
  "toggles": [],
  "questions": [],
  "unsure": [],
  "skills": [
   {
    "name": "adding an action",
    "title": "Adding an action",
    "when_to_use": "add a new action",
    "confidence": "high",
    "pitfall": "Skipping step one compiles and fails on the device.",
    "steps": [
     {
      "do": "Add the annotation.",
      "evidence": "annotations.yang:41"
     },
     {
      "do": "Add it to the dispatch set.",
      "evidence": "app.py:2118"
     }
    ]
   }
  ],
  "agents": [
   {
    "name": "contract reviewer",
    "title": "Contract reviewer",
    "description": "Use when a change touches the published schema.",
    "why": "Every change here is a contract change.",
    "confidence": "medium"
   }
  ]
 }
}
JSON
# By absolute path: `proposals/` is resolved through `state_root`, which a
# selection left by another fixture can point somewhere else entirely.
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SA" "$DECK" propose apply "$SA/.deck/proposals/pack-sa.json" \
  --into "$SA/pk/_repos/r1" --confidence medium --yes >/dev/null 2>&1 || true
if [ -f "$SA/pk/_repos/r1/skills/adding-an-action/SKILL.md" ]; then
  ok "propose apply writes a skill where Claude Code loads one from"
else bad "propose apply writes a skill where Claude Code loads one from" "$(find "$SA/pk/_repos/r1" -type f 2>&1)"; fi
if [ -f "$SA/pk/_repos/r1/agents/contract-reviewer.md" ]; then
  ok "and an agent as one file"
else bad "and an agent as one file" "$(find "$SA/pk/_repos/r1" -type f 2>&1)"; fi
if grep -q "annotations.yang:41" "$SA/pk/_repos/r1/skills/adding-an-action/SKILL.md" 2>/dev/null; then
  ok "and every step carries the file it was read from"
else bad "and every step carries the file it was read from" "$(cat "$SA/pk/_repos/r1/skills/adding-an-action/SKILL.md" 2>&1)"; fi
if grep -q "not yet followed by anybody" "$SA/pk/_repos/r1/skills/adding-an-action/SKILL.md" 2>/dev/null; then
  ok "and says on its face that nobody has walked it"
else bad "and says on its face that nobody has walked it" "$(cat "$SA/pk/_repos/r1/skills/adding-an-action/SKILL.md" 2>&1)"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SA" "$DECK" mount --task T --repos r1 2>&1 || true)"
if printf '%s' "$out" | grep -q "skill " && printf '%s' "$out" | grep -q "agent "; then
  ok "and mount places both into the repository"
else bad "and mount places both into the repository" "$out"; fi
rm -rf "$SA"

RL="$(mktemp -d)/ws"; mkdir -p "$RL/.deck" "$RL/api" "$RL/web"
printf 'version: 1\nrepos:\n  api: {path: api, impacts: []}\n  web: {path: web, impacts: []}\nscopes:\n  api: {title: clash, repos: [api]}\n' > "$RL/.deck/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RL" "$DECK" toggle set gate_level build --at repo:web --why "static only here" 2>&1 || true)"
if printf '%s' "$out" | grep -q "repository web"; then
  ok "a per-repository choice can be recorded by a command"
else bad "a per-repository choice can be recorded by a command" "$out"; fi
if grep -A8 "^repos:" "$RL/.deck/toggles.yaml" 2>/dev/null | grep -q "static only here"; then
  ok "and its reason lands in the repos block beside the value"
else bad "and its reason lands in the repos block beside the value" "$(cat "$RL/.deck/toggles.yaml" 2>&1)"; fi
# `api` is both a declared scope and a repository.
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RL" "$DECK" toggle set gate_level build --at api 2>&1 || true)"
if printf '%s' "$out" | grep -q "both a declared scope and a repository"; then
  ok "and a name that is both is refused rather than guessed"
else bad "and a name that is both is refused rather than guessed" "$out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RL" "$DECK" toggle set gate_level build --at repo:api 2>&1 || true)"
if printf '%s' "$out" | grep -q "repository api"; then
  ok "and the repo: prefix says which without ambiguity"
else bad "and the repo: prefix says which without ambiguity" "$out"; fi
rm -rf "$RL"

OV="$(mktemp -d)/ws"; mkdir -p "$OV/.deck" "$OV/pk/_workspaces/all/default/config" "$OV/pk/_repos/a/config"
for r in a b c; do mkdir -p "$OV/$r"; done
printf 'version: 1\nrepos:\n  a: {path: a, impacts: []}\n  b: {path: b, impacts: []}\n  c: {path: c, impacts: []}\npacks_root:\n- pk\n' > "$OV/.deck/workspace.yaml"
printf 'markers: []\n' > "$OV/pk/_workspaces/all/default/config/detect.yaml"
printf 'markers: []\n' > "$OV/pk/_repos/a/config/detect.yaml"
printf 'version: 1\ngates:\n  - id: build\n    title: Build\n    from_level: static\n    per_repo: "echo shared-command"\n' > "$OV/pk/_workspaces/all/default/config/gates.yaml"
printf 'version: 1\ngates:\n  - id: build\n    title: Build\n    from_level: static\n    overrides: true\n    per_repo: "echo only-for-a"\n' > "$OV/pk/_repos/a/config/gates.yaml"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$OV" "$DECK" gate run --task T >/dev/null 2>&1 || true
if grep -q "only-for-a" "$OV/.deck/gates/logs/T/build-a.log" 2>/dev/null; then
  ok "a repository pack overriding a shared gate changes it for that repository"
else bad "a repository pack overriding a shared gate changes it for that repository" "$(cat "$OV/.deck/gates/logs/T/build-a.log" 2>&1)"; fi
if grep -q "shared-command" "$OV/.deck/gates/logs/T/build-b.log" 2>/dev/null; then
  ok "and the shared gate still runs unchanged everywhere else"
else bad "and the shared gate still runs unchanged everywhere else" "$(cat "$OV/.deck/gates/logs/T/build-b.log" 2>&1)"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$OV" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$out" | grep -q "over b, c" && printf '%s' "$out" | grep -q "over a"; then
  ok "and gate list shows which repositories each one runs over"
else bad "and gate list shows which repositories each one runs over" "$out"; fi
# A pack that is NOT named after a repository still speaks for everybody.
mkdir -p "$OV/pk/_workspaces/all/late/config"
printf 'markers: []\n' > "$OV/pk/_workspaces/all/late/config/detect.yaml"
rm -rf "$OV"

CO="$(mktemp -d)/ws"; mkdir -p "$CO/.deck" "$CO/a" "$CO/b" "$CO/pk/_repos/a/config" "$CO/pk/_repos/b/config"
printf 'version: 1\nrepos:\n  a:\n    path: a\n    impacts: []\n  b:\n    path: b\n    impacts: []\npacks_root:\n- pk\n' > "$CO/.deck/workspace.yaml"
for r in a b; do
  printf 'markers: []\n' > "$CO/pk/_repos/$r/config/detect.yaml"
  printf 'version: 1\ngates:\n  - id: lint\n    title: Lint\n    from_level: static\n    per_repo: "true"\n' > "$CO/pk/_repos/$r/config/gates.yaml"
done
# `a` and `b` are both repository packs, so `lint` defaults to `only_repos:
# [a]` and `only_repos: [b]` respectively — disjoint, so `deck packs` must
# agree with the engine that this is not a collision (issue #8).
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CO" "$DECK" packs 2>&1 || true)"
if printf '%s' "$out" | grep -q "^collision "; then
  bad "a gate id shared by two disjointly-scoped repository packs is not a collision" "$out"
else ok "a gate id shared by two disjointly-scoped repository packs is not a collision"; fi
check "and the ladder loads both, not neither" "over a" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CO" "$DECK" gate list --repos a
check "and the second one keeps its own repository too" "over b" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CO" "$DECK" gate list --repos b
printf 'version: 1\ngates:\n  - id: lint\n    title: Lint\n    from_level: static\n    overrides: true\n    per_repo: "true"\n' > "$CO/pk/_repos/b/config/gates.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CO" "$DECK" packs 2>&1 || true)"
if printf '%s' "$out" | grep -q "^overlaid " && ! printf '%s' "$out" | grep -q "^collision "; then
  ok "and a deliberate override is still an overlay"
else bad "and a deliberate override is still an overlay" "$out"; fi
# Counted by walking, not from a `rules:` key nothing reads.
mkdir -p "$CO/pk/_repos/a/rules"
printf -- '---\npaths: ["**/*"]\n---\n\nx\n' > "$CO/pk/_repos/a/rules/one.md"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$CO" "$DECK" packs 2>&1 || true)"
if printf '%s' "$out" | grep -q "1 rule(s)"; then
  ok "and deck packs counts the rules a pack actually holds"
else bad "and deck packs counts the rules a pack actually holds" "$out"; fi
rm -rf "$CO"

# ---------------------------------------------------- disjoint gate ids (#8)
# The motivating case, from real use: an eight-repository workspace drafted
# packs for two Python repositories, and both declared a gate id `ruff-check`
# — the right name for "run ruff here" in both. `load_gates()` refused the
# whole ladder over that one shared name, though the two gates, each
# auto-scoped to its own repository by the same defaulting that already runs
# a repository pack's `build` gate only over its own repository, could never
# run over the same one. Own fixture, own temp dir, cleaned up at the end.
note "disjoint gate ids across repository packs (issue #8)"
RC="$(mktemp -d)/ws"
mkdir -p "$RC/.deck" "$RC/some-app" "$RC/some-lib" \
  "$RC/pk/_repos/some-app/config" "$RC/pk/_repos/some-lib/config"
cat > "$RC/.deck/workspace.yaml" <<EOF
version: 1
repos:
  some-app: { path: some-app, impacts: [] }
  some-lib: { path: some-lib, impacts: [] }
packs_root: [pk]
EOF
printf 'markers: []\n' > "$RC/pk/_repos/some-app/config/detect.yaml"
printf 'markers: []\n' > "$RC/pk/_repos/some-lib/config/detect.yaml"
printf 'gates:\n  - { id: ruff-check, title: Ruff, from_level: static, per_repo: "echo checking-app" }\n' \
  > "$RC/pk/_repos/some-app/config/gates.yaml"
printf 'gates:\n  - { id: ruff-check, title: Ruff, from_level: static, per_repo: "echo checking-lib" }\n' \
  > "$RC/pk/_repos/some-lib/config/gates.yaml"
RCENV=(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$RC")

check "the ladder loads with both same-named gates, not refused whole" "ladder" "${RCENV[@]}" "$DECK" gate list
out="$("${RCENV[@]}" "$DECK" gate list 2>&1)"
if [ "$(printf '%s' "$out" | grep -cE '^ +-> +ruff-check ')" = 2 ]; then
  ok "gate list shows both, one per repository, not merged into one"
else bad "gate list shows both, one per repository, not merged into one" "$out"; fi
if [ "$(printf '%s' "$out" | grep -cE '^ +over some-app$')" = 1 ] && [ "$(printf '%s' "$out" | grep -cE '^ +over some-lib$')" = 1 ]; then
  ok "and each is scoped to the repository that declared it"
else bad "and each is scoped to the repository that declared it" "$out"; fi
out="$("${RCENV[@]}" "$DECK" packs 2>&1)"
if printf '%s' "$out" | grep -q "^collision "; then
  bad "deck packs agrees this is not a collision" "$out"
else ok "deck packs agrees this is not a collision"; fi

"${RCENV[@]}" "$DECK" gate run --task RC-1 --level static >/dev/null 2>&1 || true
if grep -q "checking-app" "$RC/.deck/gates/logs/RC-1/ruff-check-some-app.log" 2>/dev/null; then
  ok "a run executes some-app's own ruff-check command"
else bad "a run executes some-app's own ruff-check command" "$(cat "$RC/.deck/gates/logs/RC-1/ruff-check-some-app.log" 2>&1)"; fi
if grep -q "checking-lib" "$RC/.deck/gates/logs/RC-1/ruff-check-some-lib.log" 2>/dev/null; then
  ok "and some-lib's own command, not the other repository's"
else bad "and some-lib's own command, not the other repository's" "$(cat "$RC/.deck/gates/logs/RC-1/ruff-check-some-lib.log" 2>&1)"; fi

# Now the genuine overlap: a workspace-wide pack, named after no repository,
# declares the same id. It speaks for every repository — `some-app` included
# — so it and `some-app`'s own `ruff-check` CAN run over the same repository:
# a real collision, and it must still be refused, in the same words.
mkdir -p "$RC/pk/_workspaces/all/default/config"
printf 'markers: []\n' > "$RC/pk/_workspaces/all/default/config/detect.yaml"
printf 'gates:\n  - { id: ruff-check, title: Workspace ruff, from_level: static, per_repo: "echo shared" }\n' \
  > "$RC/pk/_workspaces/all/default/config/gates.yaml"
check_fail "an unscoped gate reusing the id is still a genuine collision" "${RCENV[@]}" "$DECK" gate list
out="$("${RCENV[@]}" "$DECK" gate list 2>&1)"
if printf '%s' "$out" | grep -q "gate \`ruff-check\` already exists" \
  && printf '%s' "$out" | grep -q "Set \`overrides: true\` to extend it deliberately"; then
  ok "and refuses with the same words an ordinary collision gets"
else bad "and refuses with the same words an ordinary collision gets" "$out"; fi
out="$("${RCENV[@]}" "$DECK" packs 2>&1)"
if printf '%s' "$out" | grep -q "^collision "; then
  ok "and deck packs calls this one a collision"
else bad "and deck packs calls this one a collision" "$out"; fi
rm -rf "$RC"

ON="$(mktemp -d)/ws"; mkdir -p "$ON/pk/_workspaces/all/default/config" "$ON/r1" "$ON/.deck"
printf 'version: 1\nrepos:\n  r1:\n    path: r1\n    impacts: []\npacks_root:\n- pk\n' > "$ON/.deck/workspace.yaml"
printf 'markers: []\n' > "$ON/pk/_workspaces/all/default/config/detect.yaml"
printf 'version: 1\ngates:\n  - id: one\n    title: One\n    from_level: static\n    once: "true"\n  - id: two\n    title: Two\n    from_level: static\n    once: "true"\n' > "$ON/pk/_workspaces/all/default/config/gates.yaml"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$ON" "$DECK" gate run --task T1 >/dev/null 2>&1 || true
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$ON" "$DECK" gate run --task T1 --only two >/dev/null 2>&1 || true
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$ON" "$DECK" gate report --task T1 2>&1 || true)"
if printf '%s' "$out" | grep -q "^  ok   one "; then
  ok "a --only run leaves the gates it did not run in the record"
else bad "a --only run leaves the gates it did not run in the record" "$out"; fi
if printf '%s' "$out" | grep -q "assembled from more than one run"; then
  ok "and the report says the record was assembled from several runs"
else bad "and the report says the record was assembled from several runs" "$out"; fi
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$ON" "$DECK" gate run --task T1 >/dev/null 2>&1 || true
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$ON" "$DECK" gate report --task T1 2>&1 || true)"
if printf '%s' "$out" | grep -q "assembled from more than one run"; then
  bad "and a full run makes the record one run again" "$out"
else ok "and a full run makes the record one run again"; fi
rm -rf "$ON"

AD="$(mktemp -d)/ws"; mkdir -p "$AD/a" "$AD/b" "$AD/.repo/manifests"
cat > "$AD/.repo/manifests/default.xml" <<'XML'
<manifest><project name="a" path="a"/><project name="b" path="b"/></manifest>
XML
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$AD" "$DECK" setup --workspace add-ws \
  --packs-root "$AD/pk" --create-packs --repos a >/dev/null 2>&1 || true
AD_DESC="$AD/pk/_workspaces/add-ws/default/workspace.yaml"
printf '  b:\n    path: b\n    impacts: []\n' > "$AD/tail.txt"
python3 - "$AD_DESC" <<'PY'
import sys, yaml, pathlib
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()) or {}
d.setdefault("repos", {})["b"] = {"path": "b", "impacts": []}
p.write_text(yaml.safe_dump(d, sort_keys=False, allow_unicode=True))
PY
before="$(cat "$AD_DESC")"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$AD" "$DECK" setup --create-packs 2>&1 || true)"
if [ -d "$AD/pk/_repos/b" ]; then
  ok "--create-packs gives a new repository a pack on a workspace that already has one"
else bad "--create-packs gives a new repository a pack on a workspace that already has one" "$out"; fi
if [ "$before" = "$(cat "$AD_DESC")" ]; then
  ok "and leaves the descriptor byte-for-byte alone"
else bad "and leaves the descriptor byte-for-byte alone" "$(diff <(printf '%s' "$before") "$AD_DESC")"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$AD" "$DECK" setup 2>&1 || true)"
if printf '%s' "$out" | grep -q "deck setup --create-packs"; then
  ok "and the plain refusal names the command that does the safe half"
else bad "and the plain refusal names the command that does the safe half" "$out"; fi
rm -rf "$AD"

TV="$(mktemp -d)/ws"; mkdir -p "$TV/one" "$TV/.deck"
printf 'version: 1\nrepos:\n  one:\n    path: one\n    impacts: []\n' > "$TV/.deck/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$TV" "$DECK" propose toggle "how we tag" --show-prompt 2>&1 || true)"
if printf '%s' "$out" | grep -q '`group` must be exactly one of'; then
  ok "the toggle draft is told which groups exist"
else bad "the toggle draft is told which groups exist" "$out"; fi
if printf '%s' "$out" | grep -q '`stage` entries must come from'; then
  ok "and which stages exist"
else bad "and which stages exist" "$out"; fi
rm -rf "$TV"

TP="$(mktemp -d)/ws"; mkdir -p "$TP/one" "$TP/.deck/proposals"
printf 'version: 1\nrepos:\n  one:\n    path: one\n    impacts: []\n' > "$TP/.deck/workspace.yaml"
cat > "$TP/.deck/proposals/toggle-t.json" <<'JSON'
{"kind": "toggle", "proposal": {"id": "x", "title": "X"}}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$TP" "$DECK" propose apply toggle-t.json --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "a person places it"; then
  ok "a toggle draft is refused with the reason it is refused"
else bad "a toggle draft is refused with the reason it is refused" "$out"; fi
if printf '%s' "$out" | grep -q "deck toggle validate --strict"; then
  ok "and names what to do with the draft instead"
else bad "and names what to do with the draft instead" "$out"; fi
rm -rf "$TP"

YM="$(mktemp -d)/ws"; mkdir -p "$YM/one" "$YM/pk/_repos/one/config"
printf 'markers: []\n' > "$YM/pk/_repos/one/config/detect.yaml"
printf 'version: 1\ngates: []\n' > "$YM/pk/_repos/one/config/gates.yaml"
printf 'version: 1\nrepos:\n  one:\n    path: one\n    impacts: []\npacks_root: [pk]\n' > "$YM/desc.yaml"
mkdir -p "$YM/.deck" "$DECK_HOME_STATE/proposals"; cp "$YM/desc.yaml" "$YM/.deck/workspace.yaml"
mkdir -p "$YM/.deck/proposals"
cat > "$YM/.deck/proposals/pack-ym.json" <<'JSON'
{"kind": "pack", "proposal": {"repo": "one", "gates": [{"id": "lint-one", "title": "Lint", "from_level": "static", "command": "true", "confidence": "high", "evidence": "Makefile"}], "rules": [], "toggles": [], "questions": [], "unsure": []}}
JSON
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$YM" "$DECK" propose apply pack-ym.json \
  --into "$YM/pk/_repos/one" --confidence high --yes >/dev/null 2>&1 || true
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$YM" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$out" | grep -q "invalid YAML"; then
  bad "appending a gate to an empty inline list still parses" "$out"
else ok "appending a gate to an empty inline list still parses"; fi
# Both, because the failing output quotes the offending line and so contains
# the id on its own — a check for the id alone passed over a broken file.
if printf '%s' "$out" | grep -q "^ladder " && printf '%s' "$out" | grep -q "lint-one"; then
  ok "and the gate it appended is the one that loads"
else bad "and the gate it appended is the one that loads" "$out"; fi
rm -rf "$YM"

GT="$(mktemp -d)/ws"; mkdir -p "$GT/one" "$GT/two" "$GT/pk/_repos/two/config"
printf 'markers: []\n' > "$GT/pk/_repos/two/config/detect.yaml"
printf 'version: 1\ngates:\n  - id: ruff-check\n    title: Lint\n    from_level: static\n    per_repo: "ruff check"\n' > "$GT/pk/_repos/two/config/gates.yaml"
printf 'version: 1\nrepos:\n  one:\n    path: one\n    impacts: []\n  two:\n    path: two\n    impacts: []\npacks_root: [pk]\n' > "$GT/desc.yaml"
mkdir -p "$GT/.deck"; cp "$GT/desc.yaml" "$GT/.deck/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GT" "$DECK" propose pack one --show-prompt 2>&1 || true)"
if printf '%s' "$out" | grep -q "Gate ids already declared"; then
  ok "the pack draft is told which gate ids are taken"
else bad "the pack draft is told which gate ids are taken" "$out"; fi
if printf '%s' "$out" | grep -q "^  ruff-check$"; then
  ok "and names the one another pack holds"
else bad "and names the one another pack holds" "$out"; fi
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GT" "$DECK" propose pack two --show-prompt 2>&1 || true)"
if printf '%s' "$out" | grep -q "Gate ids already declared"; then
  bad "and a redraft may restate its own pack's gate" "$out"
else ok "and a redraft may restate its own pack's gate"; fi
rm -rf "$GT"

MK="$(mktemp -d)/ws"; mkdir -p "$MK/one" "$MK/pk/_repos/one/config" "$MK/pk/_repos/one/rules"
printf 'markers: []\n' > "$MK/pk/_repos/one/config/detect.yaml"
printf 'plugin: one@mk\nrules:\n  - { file: rules/house.md }\n' > "$MK/pk/_repos/one/config/mount.yaml"
printf 'version: 1\nrepos:\n  one:\n    path: one\n    impacts: []\npacks_root: [pk]\n' > "$MK/wsdesc.yaml"
mkdir -p "$MK/.deck"; cp "$MK/wsdesc.yaml" "$MK/.deck/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$MK" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "rules is read by nothing"; then
  ok "doctor reports a mount.yaml key that is read by nothing"
else bad "doctor reports a mount.yaml key that is read by nothing" "$out"; fi
if printf '%s' "$out" | grep -q "walked, not listed"; then
  ok "and says where those directories are declared instead"
else bad "and says where those directories are declared instead" "$out"; fi
rm -rf "$MK"

PA="$(mktemp -d)/ws"; mkdir -p "$PA/one" "$PA/two" "$PA/.repo/manifests"
cat > "$PA/.repo/manifests/default.xml" <<'XML'
<manifest><project name="one" path="one"/><project name="two" path="two"/></manifest>
XML
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PA" "$DECK" setup --workspace apply-ws   --packs-root "$PA/pk" --repos one,two >/dev/null 2>&1 || true
PA_DESC="$PA/pk/_workspaces/apply-ws/default/workspace.yaml"
mkdir -p "$DECK_HOME_STATE/workspaces/apply-ws/proposals"
cat > "$DECK_HOME_STATE/workspaces/apply-ws/proposals/impacts-test.json" <<'JSON'
{"kind": "impacts", "proposal": {"edges": [{"from": "one", "to": "two", "confidence": "high", "why": "one generates two"}], "couplings": [], "unsure": []}}
JSON
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PA" "$DECK" propose apply impacts-test.json --yes 2>&1 || true)"
if grep -A4 "^  one:" "$PA_DESC" 2>/dev/null | grep -q "^  *- two$"; then
  ok "propose apply writes into the descriptor the workspace actually uses"
else bad "propose apply writes into the descriptor the workspace actually uses" "$out"; fi
if [ -e "$PA/.deck/workspace.yaml" ]; then
  bad "and never into a second one under the project" "$(ls -a "$PA/.deck")"
else ok "and never into a second one under the project"; fi
# Asserted on what landed in the collection, not on the absence of a file: a
# check that only says the project stayed clean also passes when `import` fails
# outright, which is the shape CONTRIBUTING warns about.
rm -rf "$PA/pk" "$DECK_HOME_STATE/workspaces/import-ws"
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PA" "$DECK" setup --workspace import-ws \
  --packs-root "$PA/pk" --repos one >/dev/null 2>&1 || true
IMP_DESC="$PA/pk/_workspaces/import-ws/default/workspace.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PA" "$DECK" import repo --write 2>&1 || true)"
if grep -q "^  two:" "$IMP_DESC" 2>/dev/null; then
  ok "deck import folds into the resolved descriptor"
else bad "deck import folds into the resolved descriptor" "$out"; fi
if [ -e "$PA/.deck/workspace.yaml" ]; then
  bad "and writes no second descriptor into the project" "$(ls -a "$PA/.deck")"
else ok "and writes no second descriptor into the project"; fi
rm -rf "$PA"

SC="$(mktemp -d)/ws"; mkdir -p "$SC/alpha" "$SC/beta" "$SC/.repo/manifests"
cat > "$SC/.repo/manifests/default.xml" <<'XML'
<manifest><project name="alpha" path="alpha"/><project name="beta" path="beta"/></manifest>
XML
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SC" "$DECK" setup --workspace scope-ws   --packs-root "$SC/pk" --create-packs --repos alpha,beta >/dev/null 2>&1 || true
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SC" "$DECK" scope new scope-ws/T-1 alpha 2>&1 || true)"
if printf '%s' "$out" | grep -q "now holds 1 repositor"; then
  ok "scope new declares the repositories it was given"
else bad "scope new declares the repositories it was given" "$out"; fi

env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SC" "$DECK" scope select scope-ws/T-1 >/dev/null 2>&1 || true
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SC" "$DECK" scope select none 2>&1 || true)"
if printf '%s' "$out" | grep -q "back to scope-ws/default"; then
  ok "select none clears the scope and keeps the workspace"
else bad "select none clears the scope and keeps the workspace" "$out"; fi
# Resolved with no DECK_ROOT: the selection is the only thing that can find it.
out="$(cd "$SC" && env -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_ROOT "$DECK" repos 2>&1 || true)"
if printf '%s' "$out" | grep -q "^alpha$"; then
  ok "and the workspace is still reachable afterwards"
else bad "and the workspace is still reachable afterwards" "$out"; fi
rm -rf "$SC"

SH="$(mktemp -d)/ws"; mkdir -p "$SH/one" "$SH/.repo/manifests"
cat > "$SH/.repo/manifests/default.xml" <<'XML'
<manifest><project name="one" path="one"/></manifest>
XML
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$SH" "$DECK" setup --workspace shared-ws --packs-root "$SH/pk" --create-packs --repos one >/dev/null 2>&1 || true
if [ -d "$SH/pk/_workspaces/shared-ws/default/config" ]; then
  ok "--create-packs scaffolds the shared layer it announces"
else bad "--create-packs scaffolds the shared layer it announces" "$(ls -A "$SH/pk/_workspaces/shared-ws/default" 2>&1)"; fi
if [ -f "$SH/pk/_workspaces/shared-ws/default/workspace.yaml" ]; then
  ok "and writes the skeleton beside the descriptor, not over it"
else bad "and writes the skeleton beside the descriptor, not over it" "$(ls -A "$SH/pk/_workspaces/shared-ws/default" 2>&1)"; fi
rm -rf "$SH"

DV2="$(mktemp -d)/ws"; mkdir -p "$DV2/pk/_workspace/config" "$DV2/other"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$DV2" "$DECK" setup --workspace devtool-ws --packs-root "$DV2/pk" --repos other 2>&1 || true)"
if printf '%s' "$out" | grep -q "name .devtool-ws. is taken"; then
  ok "a workspace name already used by another directory is refused"
else bad "a workspace name already used by another directory is refused" "$out"; fi
if printf '%s' "$out" | grep -q "$DV"; then
  ok "and the refusal names the directory holding it"
else bad "and the refusal names the directory holding it" "$out"; fi
if [ -e "$DV2/.deck" ] || [ -e "$DV2/pk/_workspaces/devtool-ws" ]; then
  bad "and it wrote nothing before refusing" "$(ls -a "$DV2")"
else ok "and it wrote nothing before refusing"; fi
rm -rf "$DV2"
rm -rf "$DV"
