note "mounting artifacts"
# Where a rule lands is where it sits, not what a list says about it. A rule
# for one repository goes in that repository's pack; one for the workspace goes
# in the workspace layer, and lands once, at the root.
mkdir -p "$PACK/rules" "$PACKS/_repos/a"/{config,rules}
printf 'markers: []\n' > "$PACKS/_repos/a/config/detect.yaml"
cat > "$PACK/config/mount.yaml" <<'YAML'
plugin: example-pack@example
marketplace: { name: example, source: { source: url, url: "https://example.invalid/p.git" } }
YAML
printf -- '---\npaths: ["**/*.py"]\n---\n\nrule for a\n' > "$PACKS/_repos/a/rules/only-a.md"
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
if [ -f "$WS/.claude/rules/deck-everywhere.md" ] && [ ! -e "$WS/b/.claude/rules/deck-only-a.md" ]; then
  ok "a repository's rule lands there, and the workspace's lands once at the root"
else
  bad "a repository's rule lands there, and the workspace's lands once at the root" \
    "$(find "$WS" -name 'deck-*.md' | sed "s|$WS||" | tr '\n' ' ')"
fi
if [ -f "$WS/CLAUDE.local.md" ] && [ "$(find "$WS" -name CLAUDE.local.md | wc -l)" = "1" ]; then
  ok "the brief is written once, at the root"
else
  bad "the brief is written once, at the root"
fi
if [ -z "$(git -C "$WS/a" status --short)" ]; then ok "mounting does not dirty git status"; else bad "mounting does not dirty git status" "$(git -C "$WS/a" status --short | tr '\n' ' ')"; fi
# A `.gitkeep` holds an empty directory in a versioned collection, and a pack
# with nothing in it yet is exactly the pack that has one. Placed, it would
# arrive as `.claude/rules/deck-.gitkeep`.
touch "$PACKS/_repos/a/rules/.gitkeep"
keep="$("$DECK" mount --task KEEP --repos a --dry-run 2>&1 || true)"
if printf '%s' "$keep" | grep -q "gitkeep"; then
  bad "a dotfile in a pack is not an artifact" "$keep"
else ok "a dotfile in a pack is not an artifact"; fi
rm -f "$PACKS/_repos/a/rules/.gitkeep"

check "mounts are listed"            "T1"     "$DECK" mounts

# ---- what the agent changed, carried back to where it can be committed.
# The manifest records the file each artifact came from, so a write-back is a
# lookup, not a guess. A file nobody placed takes its home from the pack that
# owns where it sits, and its own name: the `deck-` prefix is a placement mark,
# and carrying it back would place `deck-deck-<name>` on the next mount — which
# is what this did before the prefix was stripped, measured, not supposed.
echo "changed by the agent" >> "$WS/.claude/rules/deck-everywhere.md"
printf -- '---\npaths: ["**/*"]\n---\n\ninvented here\n' > "$WS/a/.claude/rules/deck-invented.md"
check "a dry run says what it would carry back" "would save" "$DECK" save --task T1 --dry-run
if grep -q "changed by the agent" "$PACK/rules/everywhere.md"; then
  bad "and writes nothing" "the source already changed"
else ok "and writes nothing"; fi
saved="$("$DECK" save --task T1 2>&1 || true)"
if grep -q "changed by the agent" "$PACK/rules/everywhere.md"; then
  ok "an edited artifact is carried back to the layer it came from"
else bad "an edited artifact is carried back to the layer it came from" "$saved"; fi
if [ -f "$PACKS/_repos/a/rules/invented.md" ] && [ ! -e "$PACKS/_repos/a/rules/deck-invented.md" ]; then
  ok "a new file lands in the pack under its own name, without the placement prefix"
else
  bad "a new file lands in the pack under its own name, without the placement prefix" \
    "$(ls "$PACKS/_repos/a/rules/" | tr '\n' ' ')"
fi
rm -f "$WS/a/.claude/rules/deck-invented.md" "$PACKS/_repos/a/rules/invented.md"
rm "$WS/.claude/rules/deck-everywhere.md"
gone="$("$DECK" save --task T1 2>&1 || true)"
if printf '%s' "$gone" | grep -q "deleted in the working tree"; then
  ok "a deleted artifact is reported, never propagated into the pack"
else bad "a deleted artifact is reported, never propagated into the pack" "$gone"; fi
if [ -f "$PACK/rules/everywhere.md" ]; then ok "and the pack still has the file"; else bad "and the pack still has the file"; fi

# What was carried back is not somebody's unsaved work any more, and unmount has
# to be able to take it. Before `save` recorded what it wrote, this left every
# saved file behind — `0 removed · 1 left alone` — and never saw the new one at
# all, which is a repository deck promised to hand back clean and did not.
"$DECK" mount --task SV --repos a >/dev/null 2>&1
echo "carried back" >> "$WS/.claude/rules/deck-everywhere.md"
printf -- '---\npaths: ["**/*"]\n---\n\ninvented\n' > "$WS/a/.claude/rules/deck-fresh.md"
"$DECK" save --task SV >/dev/null 2>&1
sv="$("$DECK" unmount --task SV 2>&1 || true)"
if printf '%s' "$sv" | grep -q "0 left alone"; then
  ok "unmount takes back what save carried back"
else bad "unmount takes back what save carried back" "$sv"; fi
if [ ! -e "$WS/a/.claude/rules/deck-fresh.md" ]; then
  ok "including a file deck did not place, once the pack holds it"
else bad "including a file deck did not place, once the pack holds it"; fi

# deck watched one direction of drift and not the other. `stale` is the pack
# moving ahead of the copies; this is the copies moving ahead of the pack, and
# it is the one that loses work — an edit no collection holds, which unmount
# leaves behind rather than deletes, invisible until the tree is thrown away.
"$DECK" mount --task DR --repos a >/dev/null 2>&1
echo "not carried back" >> "$WS/.claude/rules/deck-everywhere.md"
dr="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$dr" | grep -q "unsaved:"; then
  ok "doctor reports an artifact edited and not carried back"
else bad "doctor reports an artifact edited and not carried back" "$(printf '%s' "$dr" | grep -A3 'mounted artifacts')"; fi
if printf '%s' "$dr" | grep -q "deck save --task DR"; then
  ok "and names the command that carries it"
else bad "and names the command that carries it" "$dr"; fi
"$DECK" save --task DR >/dev/null 2>&1
clean="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$clean" | grep -q "unsaved:"; then
  bad "and stops saying so once it has been" "$(printf '%s' "$clean" | grep 'unsaved')"
else ok "and stops saying so once it has been"; fi
"$DECK" unmount --task DR >/dev/null 2>&1

# And an edit made AFTER the save is protected exactly as before: the hash
# recorded is the one the copy had when it was carried back, not a blanket
# amnesty on the file.
"$DECK" mount --task SV2 --repos a >/dev/null 2>&1
echo "first" >> "$WS/.claude/rules/deck-everywhere.md"
"$DECK" save --task SV2 >/dev/null 2>&1
echo "second, after the save" >> "$WS/.claude/rules/deck-everywhere.md"
sv2="$("$DECK" unmount --task SV2 2>&1 || true)"
if printf '%s' "$sv2" | grep -q "edited since it was placed"; then
  ok "an edit made after the save is still left alone"
else bad "an edit made after the save is still left alone" "$sv2"; fi
if grep -q "^first$" "$PACK/rules/everywhere.md" && ! grep -q "after the save" "$PACK/rules/everywhere.md"; then
  ok "and the pack has what was carried back, and not what came later"
else bad "and the pack has what was carried back, and not what came later"; fi
rm -f "$WS/.claude/rules/deck-everywhere.md" "$PACKS/_repos/a/rules/fresh.md"
"$DECK" mount --task T1 --repos a >/dev/null 2>&1 || true
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
rm "$WS/.claude/rules/deck-everywhere.md"
echo "hand edited" > "$WS/.claude/rules/deck-everywhere.md"
# A copy cannot be written through into the pack, which is the point: editing the
# pack after mounting leaves what was placed alone.
echo "" >> "$PACKS/_repos/a/rules/only-a.md"
if ! tail -1 "$WS/a/.claude/rules/deck-only-a.md" | grep -q "^$"; then
  ok "editing the pack does not reach through into a mounted rule"
else
  bad "editing the pack does not reach through into a mounted rule"
fi

"$DECK" unmount --task T1 > "$WS/unmount.txt" 2>&1
if grep -q "LEFT" "$WS/unmount.txt"; then ok "an edited artifact is reported, not deleted"; else bad "an edited artifact is reported, not deleted"; fi
if [ -f "$WS/.claude/rules/deck-everywhere.md" ]; then ok "the edited file is still there"; else bad "the edited file is still there"; fi
if grep -q "someone-else@x" "$WS/b/.claude/settings.local.json" 2>/dev/null; then
  ok "another plugin in the same file survives"
else
  bad "another plugin in the same file survives"
fi
if [ ! -e "$WS/a/.claude/rules/deck-only-a.md" ]; then ok "untouched artifacts are removed"; else bad "untouched artifacts are removed"; fi
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
