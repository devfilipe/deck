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
# With no selection: a selected pair answers from anywhere, deliberately, so
# the case this asserts is the one where nothing has been selected at all.
ib_other="$( (cd "$(mktemp -d)" && env -u DECK_ROOT DECK_HOME_STATE="$(mktemp -d)" "$DECK" root 2>&1) )" || true
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
