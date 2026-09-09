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
echo "" >> "$PACKS/_repos/a/rules/only-a.md"
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

# `doctor`'s `mounted artifacts` section used to vanish entirely when nothing
# was mounted, so a workspace with rules mounted and one with none looked
# identical except that the first said so. A fresh, isolated fixture: the
# shared $WS/$PACKS above have accumulated rules from every section before
# this one, and asserting an exact declared count against a fixture nobody
# else writes to is the only way this stays true regardless of what runs
# before it.
note "doctor names what would be mounted when nothing is"
MD="$(mktemp -d)"
mkdir -p "$MD/.deck" "$MD/a" "$MD/pk/config" "$MD/pk/rules"
printf 'version: 1\nrepos: { a: { path: a } }\ntargets: []\n' > "$MD/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$MD/.deck/toggles.yaml"
printf 'markers: []\n' > "$MD/pk/config/detect.yaml"
printf -- '---\npaths: ["**/*"]\n---\n\none\n' > "$MD/pk/rules/one.md"
printf -- '---\npaths: ["**/*"]\n---\n\ntwo\n' > "$MD/pk/rules/two.md"

check "doctor says nothing is mounted, and what would be if it were" \
  "!! none placed  1 pack(s) declare 2 artifact(s) and none are mounted — deck mount" \
  env -u DECK_PACKS_ROOT DECK_ROOT="$MD" DECK_PACKS="$MD/pk" DECK_SESSION=mount-doctor "$DECK" doctor

env -u DECK_PACKS_ROOT DECK_ROOT="$MD" DECK_PACKS="$MD/pk" DECK_SESSION=mount-doctor \
  "$DECK" mount --task MD1 --repos a >/dev/null 2>&1

check "and stops warning once something actually is mounted" \
  "OK MD1  2 artifact(s), this session" \
  env -u DECK_PACKS_ROOT DECK_ROOT="$MD" DECK_PACKS="$MD/pk" DECK_SESSION=mount-doctor "$DECK" doctor

env -u DECK_PACKS_ROOT DECK_ROOT="$MD" DECK_PACKS="$MD/pk" DECK_SESSION=mount-doctor \
  "$DECK" unmount --task MD1 >/dev/null 2>&1
rm -rf "$MD"

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


def scan(path, src, bad):
    for i, line in enumerate(src):
        if not re.match(r"^if command -v \w+ >", line):
            continue
        hidden, skipped, j = set(), set(), i
        while j < len(src):
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
            bad.append(f"{path}:{i + 1}: no skip for {sorted(missing)}")


# Every file the runner sources, not the runner alone: the guards moved into
# ci/checks/ when the suite stopped being one script, and a scan that went on
# reading one file would have found no guard at all and called it balanced.
bad = []
for path in [pathlib.Path("ci/smoke.sh"), *sorted(pathlib.Path("ci/checks").glob("*.sh"))]:
    scan(path, path.read_text().split("\n"), bad)
print("; ".join(bad) if bad else "balanced")
PYG
)"
if [ "$guards" = "balanced" ]; then
  ok "every check behind a tool guard is still counted when the tool is absent"
else
  bad "every check behind a tool guard is still counted when the tool is absent" "$guards"
fi

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
# `-u DECK_PACKS_ROOT -u DECK_PACKS`, the way every other fixture does it.
# Without them this block inherits whatever collection an earlier section
# exported, and `propose pack` reads every resolved pack to list the gate ids
# already taken — so the prompt this check greps depended on a section running
# before it. Observed once as a failure that did not reproduce on the next run,
# which is the worst shape a check has: it lies sometimes.
ng() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$NG" "$DECK" "$@"; }

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

# ---- apply's --yes is asymmetric on purpose, and that has to be findable (#9)
# `_apply_impacts` refuses to write without `--yes`; `_apply_pack` always wrote,
# `--yes` or not, and nothing said the two disagreed on purpose. An `impacts`
# draft edits the descriptor every other command reads — cycles, execution
# order — so it stays behind a preview and `--yes`. A `pack` (or `lessons`)
# draft only appends into the one directory `--into` names, inert until `mount`
# and `gate run` next touch it; reading the draft before pointing `--into` at a
# real pack is the confirmation, so it always writes. Documented rather than
# equalised: `deck propose apply`'s own help is where someone runs into this,
# one flag meaning two different things depending on what it is applying.
# argparse wraps this onto several lines, so the shared `check` (a single-line
# grep) cannot read it — collapsed to one line first, the way a person reads it.
apply_help="$(printf '%s' "$("$DECK" propose apply --help 2>&1 || true)" | tr '\n' ' ' | tr -s ' ')"
if printf '%s' "$apply_help" | grep -qF -- "a \`pack\` or \`lessons\` proposal writes into the one pack directory"; then
  ok "apply's own help names the asymmetry, where someone meets it"
else
  bad "apply's own help names the asymmetry, where someone meets it" "$apply_help"
fi
if printf '%s' "$apply_help" | grep -qF -- "required before an \`impacts\` proposal writes the shared descriptor"; then
  ok "and says which write the flag actually gates"
else
  bad "and says which write the flag actually gates" "$apply_help"
fi
check "README explains it too, not only --help" "does not ask the same way for every kind of proposal" cat "$REPO/README.md"

# ---- a drafted finding is a decision or a question, never both
# The observed failure: a drafter found two code paths returning different status
# codes for the same refusal, said in its own notes it could not tell whether
# that was intentional or drift, and filed it as a TOGGLE. That turns "we do not
# know" into "we chose" and the doubt is gone. Half of the fix is in the prompt,
# and a prompt is free to check. The other half has to hold when the draft
