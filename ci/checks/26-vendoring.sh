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
