# ------------------------------------------------------ a ladder with no rungs
# ------------------------------------ the machine's three fields, and no more
# A descriptor versioned in a collection gives deck the workspace's identity —
# the layer it sits in IS the statement of which workspace and which phase. What
# it cannot carry is `packs_root`, `paths` and `targets`: a packs checkout, a
# tools directory and a lab host are one person's answers, and a versioned
# allowlist hands everybody else your machines. Before the overlay, choosing the
# versioned route meant losing all three, and `deck doctor` reported `no target
# declared` exactly as it would for a workspace that deploys nowhere.
# ------------------------------------- a selection, and the scope it carries
# `--scope` on every command is a flag somebody forgets. A selection is where
# you ARE, kept in ~/.deck so a project a team shares carries nobody's answer to
# "which initiative am I in". DECK_HOME_STATE moves it, which is the only reason
# this section can run without touching the person running it.
# ------------------------------------ setup writes the team's half where a team can read it
note "a document does not name a descriptor key the engine never reads"
# FOUNDATIONS.md's table said `container` in the descriptor, used by gate
# commands ... yes ... works. There is no `container` anywhere in
# plugins/deck/deck/ — no reader, no writer, never was. It read as a shipped
# feature because the row was written the way the rows around it were, and
# nothing ever compared the claim against the engine.
#
# The phrase is the trigger, not a list of keys: "`x` in the descriptor" is a
# claim that deck reads `x`, and the only way to keep it true is for someone
# adding the key to the document to also add the reader. A mechanism that is
# not a key — a gate command, a toggle — says so and is not asked about here.
_docclaims="$(python3 - "$REPO" <<'PYCLAIM'
import re, sys, pathlib
repo = pathlib.Path(sys.argv[1])
doc = (repo / "FOUNDATIONS.md").read_text()
engine = "\n".join(f.read_text() for f in sorted((repo / "plugins/deck/deck").glob("*.py")))
unread = [
    key
    for key in sorted(set(re.findall(r"`([a-z_]+)` in the descriptor", doc)))
    if f'"{key}"' not in engine and f"'{key}'" not in engine
]
print(" ".join(unread))
PYCLAIM
)"
if [ -z "$_docclaims" ]; then
  ok "every descriptor key a document claims has a reader in the engine"
else
  bad "every descriptor key a document claims has a reader in the engine" "unread: $_docclaims"
fi

# The descriptor is the registry, the edges and the carve-up — one answer for
# everybody, so it belongs in the collection rather than under somebody's root.
# What cannot go with it is the three fields `pack new --from-workspace` already
# drops: a packs checkout, a tools directory and a lab host are one person's.
# --------------------------------- a selection is about ONE workspace, not all
# State is keyed by the selected workspace's name, and a command pointed
# somewhere else by DECK_ROOT is not in that workspace. Without the test, every
# synthetic workspace here read the state of whatever the person running the
# suite had selected: 359 checks failed on a machine with a selection and none
# on a clean one, which is the worst shape a failure can take.
note "a selection does not follow you"

LK="$(mktemp -d)"; LKH="$LK/home"
mkdir -p "$LK/mine/.deck" "$LK/mine/r" "$LK/other/.deck" "$LK/other/r" "$LKH/workspaces/mine"
for d in mine other; do git -C "$LK/$d/r" init -q 2>/dev/null; done
printf 'root: %s\npacks_root: []\n' "$LK/mine" > "$LKH/workspaces/mine/machine.yaml"
printf 'mine/default\n' > "$LKH/selected"
printf 'version: 1\nrepos:\n  r: { path: r }\n' > "$LK/other/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$LK/other/.deck/toggles.yaml"
lk_out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_DESCRIPTOR \
  DECK_ROOT="$LK/other" DECK_HOME_STATE="$LKH" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$lk_out" | grep -q "$LK/other"; then
  ok "a workspace named by DECK_ROOT keeps its own state, whatever is selected"
else bad "a workspace named by DECK_ROOT keeps its own state" "$lk_out"; fi
if printf '%s' "$lk_out" | grep -q "workspaces/mine"; then
  bad "and never reads the selected one's" "it read $LKH/workspaces/mine"
else ok "and never reads the selected one's"; fi
rm -rf "$LK"

note "setup, into the collection"

SU="$(mktemp -d)"; SUH="$SU/home"
mkdir -p "$SU/ws"/{one,two} "$SUH"
for d in one two; do git -C "$SU/ws/$d" init -q 2>/dev/null; echo x > "$SU/ws/$d/R"; done
su_out="$(cd "$SU/ws" && env -u DECK_ROOT -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_DESCRIPTOR \
  DECK_HOME_STATE="$SUH" "$DECK" setup --packs-root "$SU/coll" --workspace proj --create-packs 2>&1 || true)"
su() { env -u DECK_ROOT -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_DESCRIPTOR \
       DECK_ROOT="$SU/ws" DECK_HOME_STATE="$SUH" "$DECK" "$@"; }

if [ -f "$SU/coll/_workspaces/proj/default/workspace.yaml" ]; then
  ok "the descriptor is written into the collection, under the workspace's name"
else bad "the descriptor is written into the collection" "$(find "$SU/coll" -name workspace.yaml | tr '\n' ' ')"; fi
if [ ! -f "$SU/ws/.deck/workspace.yaml" ]; then
  ok "and not under the root, where nobody could review it"
else bad "and not under the root" "$SU/ws/.deck/workspace.yaml exists"; fi

# The three, and only the three.
SU_MACHINE="$SUH/workspaces/proj/machine.yaml"
if grep -q "packs_root" "$SU_MACHINE" && grep -q "targets" "$SU_MACHINE"; then
  ok "the machine keeps packs_root, paths and targets"
else bad "the machine keeps packs_root, paths and targets" "$(cat "$SU_MACHINE" 2>&1)"; fi
if grep -q "repos:" "$SU_MACHINE"; then
  bad "and nothing else — a registry there would be one person's" "$(cat "$SU_MACHINE")"
else ok "and nothing else — a registry there would be one person's"; fi
if grep -q "packs_root" "$SU/coll/_workspaces/proj/default/workspace.yaml"; then
  bad "the versioned half carries no packs_root" "it does"
else ok "the versioned half carries no packs_root"; fi

# A workspace nobody is in acts on nothing, so setup leaves one selected.
if [ "$(cat "$SUH/selected" 2>/dev/null)" = "proj/default" ]; then
  ok "and the pair is selected, so the next command needs no flag"
else bad "and the pair is selected" "$(cat "$SUH/selected" 2>/dev/null)"; fi

# The project keeps nothing of deck's. `state_root` answers where state ALREADY
# is and will not name a home directory holding no machine file — so the FIRST
# write has to name the place rather than ask where it is. It did not, and the
# file landed back in the project: the one place this exists to empty.
if [ -f "$SUH/workspaces/proj/machine.yaml" ] && [ -f "$SUH/workspaces/proj/toggles.yaml" ]; then
  ok "the machine's state is written under ~/.deck, keyed by the workspace"
else bad "the machine's state is written under ~/.deck" "$(find "$SUH" -type f | tr '\n' ' ')"; fi
if [ ! -e "$SU/ws/.deck" ]; then
  ok "and the project tree carries nothing of deck's at all"
else bad "and the project tree carries nothing of deck's" "$(ls -a "$SU/ws/.deck" | tr '\n' ' ')"; fi
check "the workspace's identity comes from the layer it was written to" "workspace proj" su packs
check "and doctor resolves the whole of it" "machine overlay" su doctor
rm -rf "$SU"

note "selecting a scope"

SEL="$(mktemp -d)"; SELC="$SEL/coll"; SELH="$SEL/home"
mkdir -p "$SEL/ws/.deck" "$SEL/ws"/{r1,r2} "$SELC/_workspaces/proj/default/config"
for d in r1 r2; do git -C "$SEL/ws/$d" init -q 2>/dev/null; done
printf 'markers: []\n' > "$SELC/_workspaces/proj/default/config/detect.yaml"
cat > "$SELC/_workspaces/proj/default/workspace.yaml" <<'YAML'
version: 1
repos:
  r1: { path: r1, impacts: [r2] }
  r2: { path: r2, impacts: [] }
YAML
printf 'packs_root: [%s]\n' "$SELC" > "$SEL/ws/.deck/machine.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$SEL/ws/.deck/toggles.yaml"
sel() { env -u DECK_SCOPE -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_DESCRIPTOR \
        DECK_ROOT="$SEL/ws" DECK_HOME_STATE="$SELH" "$DECK" "$@"; }

check "a selection is recorded" "selected proj/default" sel scope select proj/default
check "and it finds the descriptor on its own" "proj/default/workspace.yaml" sel scope select proj/default

check "a scope's layer is created by command, not by hand" "created for \`proj\`" \
  sel scope new proj/PHASE-1
if [ -d "$SELC/_workspaces/proj/PHASE-1/rules" ] && [ -f "$SELC/_workspaces/proj/PHASE-1/config/detect.yaml" ]; then
  ok "with the three directories empty and a detect.yaml that claims no marker"
else bad "with the three directories empty and a detect.yaml that claims no marker"; fi
# A marker in a scope layer would take part in resolving the workspace ROOT,
# which is not what a phase of the work is for.
if grep -q "markers: \[\]" "$SELC/_workspaces/proj/PHASE-1/config/detect.yaml"; then
  ok "a scope layer claims no marker, so it cannot decide where the root is"
else bad "a scope layer claims no marker" "$(cat "$SELC/_workspaces/proj/PHASE-1/config/detect.yaml")"; fi

check_fail "a scope cannot hold a repository the registry does not declare" \
  sel scope add-repos proj/PHASE-1 ghost
ghost_out="$(sel scope add-repos proj/PHASE-1 ghost 2>&1 || true)"
if printf '%s' "$ghost_out" | grep -q "narrows what is there"; then
  ok "and says so in the words of what a scope is for"
else bad "and says so in the words of what a scope is for" "$ghost_out"; fi
check "repositories are folded in by command" "now holds 1 repository" \
  sel scope add-repos proj/PHASE-1 r1 --title "One phase"
if grep -q "PHASE-1" "$SELC/_workspaces/proj/default/workspace.yaml"; then
  ok "written into the versioned descriptor, where it is the team's"
else bad "written into the versioned descriptor" "$(cat "$SELC/_workspaces/proj/default/workspace.yaml")"; fi

sel scope select proj/PHASE-1 >/dev/null 2>&1
sel_repos="$(sel repos 2>&1 | tr '\n' ' ')"
if [ "$sel_repos" = "r1 " ]; then
  ok "the selection narrows every command, with no flag on the line"
else bad "the selection narrows every command, with no flag on the line" "got: $sel_repos"; fi
check "and the scope's own layer is in play" "proj/PHASE-1" sel packs
check "the boundary is still reported, never hidden" "reaches" sel scope PHASE-1

# A selection is where you are. Taking it away while a task is mounted would
# strip the rules from work in progress — the failure holds exist to prevent.
# One real artifact, because a mount that places nothing writes no manifest and
# there would be nothing held to refuse over.
mkdir -p "$SELC/_repos/r1/rules" "$SELC/_repos/r1/config"
printf 'markers: []\n' > "$SELC/_repos/r1/config/detect.yaml"
printf -- '---\npaths: ["**/*"]\n---\n\nA convention.\n' > "$SELC/_repos/r1/rules/house.md"
sel mount --task T --repos r1 >/dev/null 2>&1
check_fail "a selection is refused while a task is mounted" sel scope select proj/default
held_out="$(sel scope select none 2>&1 || true)"
if printf '%s' "$held_out" | grep -q "still mounted"; then
  ok "and it names the task rather than the file"
else bad "and it names the task rather than the file" "$held_out"; fi
sel unmount --task T >/dev/null 2>&1
check "cleared once nothing is held" "back to proj/default" sel scope select none
rm -rf "$SEL"

note "the machine overlay"

MO="$(mktemp -d)"; MOC="$MO/coll"
mkdir -p "$MO/ws/.deck" "$MO/ws/r1"
git -C "$MO/ws/r1" init -q 2>/dev/null
for leaf in all/default proj/default proj/PHASE-1; do
  mkdir -p "$MOC/_workspaces/$leaf/config"
  printf 'markers: []\n' > "$MOC/_workspaces/$leaf/config/detect.yaml"
done
cat > "$MOC/_workspaces/proj/PHASE-1/workspace.yaml" <<YAML
version: 1
scopes:
  PHASE-1: { title: One phase, repos: [r1] }
repos:
  r1: { path: r1, impacts: [] }
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$MO/ws/.deck/toggles.yaml"
cat > "$MO/ws/.deck/machine.yaml" <<YAML
descriptor: $MOC/_workspaces/proj/PHASE-1/workspace.yaml
packs_root: [$MOC]
targets:
  - { host: 10.0.0.9, role: bench }
YAML
mo() { env -u DECK_PACKS_ROOT -u DECK_PACKS -u DECK_DESCRIPTOR DECK_ROOT="$MO/ws" "$DECK" "$@"; }

check "the overlay names where the descriptor is" "machine overlay" mo doctor
check "and the workspace takes its identity from that path" "workspace proj" mo --scope PHASE-1 packs
check "the machine keeps its allowlist" "10.0.0.9" mo targets
mo_names="$(mo --scope PHASE-1 packs 2>&1 | grep -E '^  [0-9]+  ' | awk '{print $2}' | tr '\n' ' ')"
if [ "$mo_names" = "all/default proj/default proj/PHASE-1 " ]; then
  ok "and every layer of the pair resolves, most general first"
else bad "and every layer of the pair resolves, most general first" "got: $mo_names"; fi

# Only three fields, and that is what makes it an overlay rather than a merge.
printf 'repos:\n  ghost: { path: nowhere }\n' >> "$MO/ws/.deck/machine.yaml"
check "a key nothing reads is named, not ignored" "is not taking effect" mo doctor
if mo repos 2>&1 | grep -q ghost; then
  bad "and never applied" "the overlay's repos: reached the registry"
else ok "and never applied"; fi
rm -rf "$MO"
