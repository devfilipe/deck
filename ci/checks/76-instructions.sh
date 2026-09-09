# ------------------- a second source of instruction, which deck did not write
# Two halves of one blindness (#22). A file the packs never declared is loaded
# anyway — an ancestor's at launch, every launch — and a destination already
# occupied is one the pack's own artifact never reaches. Neither was reported.
note "instruction files deck does not manage"
IF="$(mktemp -d)"
mkdir -p "$IF/above/ws/r" "$IF/above/ws/.deck" "$IF/clean/ws/r" "$IF/clean/ws/.deck"
for w in above clean; do
  cat > "$IF/$w/ws/.deck/workspace.yaml" <<YAML
version: 1
repos:
  r: { path: r, role: one, impacts: [] }
targets: []
YAML
  git -C "$IF/$w/ws/r" init -q 2>/dev/null
done
printf 'always loaded\n' > "$IF/above/CLAUDE.md"
printf 'in the checkout\n' > "$IF/above/ws/r/AGENTS.md"
git -C "$IF/above/ws/r" add AGENTS.md >/dev/null 2>&1
git -C "$IF/above/ws/r" -c user.email=s@x -c user.name=s commit -qm add >/dev/null 2>&1

IFDOC="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$IF/above/ws" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$IFDOC" | grep -qF "$IF/above/CLAUDE.md"; then
  ok "an instruction file above the workspace is reported"
else bad "an instruction file above the workspace is reported" "$IFDOC"; fi
if printf '%s' "$IFDOC" | grep -qF "$IF/above/CLAUDE.md" && printf '%s' "$IFDOC" | grep -q "not versioned"; then
  ok "and is reported as something no repository versions"
else bad "and is reported as something no repository versions" "$IFDOC"; fi
if printf '%s' "$IFDOC" | grep -F "$IF/above/ws/r/AGENTS.md" | grep -q "versioned"; then
  ok "one inside a checkout that tracks it is reported as versioned"
else bad "one inside a checkout that tracks it is reported as versioned" "$IFDOC"; fi
# Reported, never governed: the file is still there and still says what it said.
if [ "$(cat "$IF/above/CLAUDE.md")" = "always loaded" ] && [ -f "$IF/above/ws/r/AGENTS.md" ]; then
  ok "and deck neither moved nor rewrote either of them"
else bad "and deck neither moved nor rewrote either of them" "$(ls -l "$IF/above")"; fi

# The pair, in one check: the tree that holds one is told, the tree that holds
# none is accused of nothing. A path, never a bare name — the diagnosis lists
# the names it looked for, and matching those would report every workspace.
IFCLEAN="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$IF/clean/ws" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$IFDOC" | grep -qF "$IF/above/CLAUDE.md" && ! printf '%s' "$IFCLEAN" | grep -qE "/(CLAUDE|AGENTS)\.md"; then
  ok "only the workspace that holds one is told it holds one"
else bad "only the workspace that holds one is told it holds one" "$IFCLEAN"; fi

# The names are the team's to state, not deck's to know for ever.
printf 'house style\n' > "$IF/above/ws/r/HOUSE.md"
cat >> "$IF/above/ws/.deck/workspace.yaml" <<'YAML'
instruction_files: [HOUSE.md]
YAML
IFNAMED="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$IF/above/ws" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$IFNAMED" | grep -qF "$IF/above/ws/r/HOUSE.md"; then
  ok "a name the descriptor states is looked for"
else bad "a name the descriptor states is looked for" "$IFNAMED"; fi
if ! printf '%s' "$IFNAMED" | grep -qF "$IF/above/CLAUDE.md"; then
  ok "and the descriptor's list is the list, not an addition to a built-in one"
else bad "and the descriptor's list is the list, not an addition to a built-in one" "$IFNAMED"; fi

# `deck setup` is the moment somebody is deciding what this workspace holds.
IFSET="$(env -u DECK_PACKS_ROOT -u DECK_PACKS "$DECK" setup --root "$IF/above/ws" --dry-run 2>&1 || true)"
if printf '%s' "$IFSET" | grep -qF "$IF/above/ws/r/HOUSE.md"; then
  ok "setup names them while somebody is deciding what the workspace contains"
else bad "setup names them while somebody is deciding what the workspace contains" "$IFSET"; fi

# ---- the other half: a destination deck did not write, and did not report
note "a destination deck did not write is neither overwritten nor adopted"
IFP="$IF/packs/_workspaces/all/default"
mkdir -p "$IFP/rules" "$IFP/config" "$IF/above/ws/.claude/rules"
printf 'the pack version\n' > "$IFP/rules/house.md"
printf 'hand written, not decks\n' > "$IF/above/ws/.claude/rules/deck-house.md"
IFENV="env -u DECK_PACKS DECK_PACKS_ROOT=$IF/packs DECK_ROOT=$IF/above/ws"
IFDRY="$($IFENV "$DECK" mount --task blocked --repos r --dry-run 2>&1 || true)"
if printf '%s' "$IFDRY" | grep -qi "occupied"; then
  ok "a dry run says the destination is already taken, before anything is written"
else bad "a dry run says the destination is already taken, before anything is written" "$IFDRY"; fi
IFMNT="$($IFENV "$DECK" mount --task blocked --repos r 2>&1 || true)"
if [ "$(cat "$IF/above/ws/.claude/rules/deck-house.md")" = "hand written, not decks" ]; then
  ok "mounting does not overwrite it"
else bad "mounting does not overwrite it" "$(cat "$IF/above/ws/.claude/rules/deck-house.md")"; fi
if printf '%s' "$IFMNT" | grep -qF ".claude/rules/deck-house.md" && printf '%s' "$IFMNT" | grep -q "not placed"; then
  ok "and mount says the pack's artifact did not arrive, instead of passing over it"
else bad "and mount says the pack's artifact did not arrive, instead of passing over it" "$IFMNT"; fi
# Apart from `entries`, because `entries` is the list unmount deletes from.
IFMAN="$(python3 - "$IF/above/ws/.deck/mounts/blocked.json" <<'PY' 2>&1 || true
import json, sys
m = json.load(open(sys.argv[1]))
blocked = [e["path"] for e in m.get("blocked", [])]
placed = [e["path"] for e in m.get("entries", [])]
print("blocked:" + ",".join(blocked))
print("placed:" + ",".join(placed))
PY
)"
if printf '%s' "$IFMAN" | grep -q "^blocked:.*deck-house.md" && ! printf '%s' "$IFMAN" | grep -q "^placed:.*deck-house.md"; then
  ok "the manifest records it apart from what unmount will take back"
else bad "the manifest records it apart from what unmount will take back" "$IFMAN"; fi
$IFENV "$DECK" unmount --task blocked >/dev/null 2>&1
if [ -f "$IF/above/ws/.claude/rules/deck-house.md" ] &&
   [ "$(cat "$IF/above/ws/.claude/rules/deck-house.md")" = "hand written, not decks" ]; then
  ok "and unmount takes back only what it placed, leaving that file untouched"
else bad "and unmount takes back only what it placed, leaving that file untouched" "$(ls -l "$IF/above/ws/.claude/rules" 2>&1)"; fi
rm -rf "$IF"
