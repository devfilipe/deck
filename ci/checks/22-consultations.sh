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

# ---- the default a folded toggle picks has to survive ordinary prose
# A person answering "which of these two" starts a sentence with a capital,
# and the word that names the value is usually the first one — which is
# exactly the word a person capitalises. Own fixture: a fold this early in the
# suite would collide with ids ($UNANS, retry_budget_scope) the block above
# already wrote into $FP.
FIX28="$(mktemp -d)"
mkdir -p "$FIX28/.deck"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$FIX28/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$FIX28/.deck/toggles.yaml"
FP28="$(mktemp -d)/foldpack28"
d28() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$FIX28" "$DECK" "$@"; }
d28 pack new foldpack28 --dir "$FP28" >/dev/null 2>&1

out28="$(d28 ask new "Should a malformed frame be rejected, or accepted and logged?" --options "reject,accept-and-log" 2>&1 || true)"
CID28="$(printf '%s' "$out28" | grep -oE '^recorded .*' | cut -d' ' -f2)"
d28 ask resolve "$CID28" "Reject it. A malformed frame is not a frame." >/dev/null 2>&1
fold28_out="$(d28 ask fold "$CID28" --as toggle --into "$FP28" --group quality --gate-id malformed_frame_handling \
  --impact "reject=Malformed frames never reach a handler." \
  --impact "accept-and-log=Malformed frames still reach a handler, logged." 2>&1 || true)"
resolved28="$(env -u DECK_PACKS_ROOT DECK_ROOT="$FIX28" DECK_PACKS="$FP28" "$DECK" toggle get malformed_frame_handling 2>&1 || true)"
if [ "$resolved28" = "reject" ]; then
  ok "a sentence that names a value in a different case still resolves to it"
else bad "a sentence that names a value in a different case still resolves to it" "resolved to '$resolved28' ($fold28_out)"; fi

# The refusal is still right when the answer names neither value — folding is
# not allowed to start guessing just because it stopped requiring exact case.
out28b="$(d28 ask new "Should a malformed header be rejected, or accepted and logged?" --options "reject,accept-and-log" 2>&1 || true)"
CID28B="$(printf '%s' "$out28b" | grep -oE '^recorded .*' | cut -d' ' -f2)"
d28 ask resolve "$CID28B" "We will decide this once the API stabilises." >/dev/null 2>&1
noneref28="$(d28 ask fold "$CID28B" --as toggle --into "$FP28" --group quality --gate-id malformed_header_handling \
  --impact "reject=x" --impact "accept-and-log=y" 2>&1 || true)"
if printf '%s' "$noneref28" | grep -qF 'does not name one of the values' && printf '%s' "$noneref28" | grep -qF -- '--default'; then
  ok "an answer naming no value is still refused, and still names --default"
else bad "an answer naming no value is still refused, and still names --default" "$noneref28"; fi
rm -rf "$FIX28" "$(dirname "$FP28")"

# ---- --header makes a folded toggle presentable, and says so — it does not
# make the entry asked again, which the flag's own help used to promise.
# Own fixture: DECK_ROOT and a pack neither $WS nor $FP above have touched.
FIX31="$(mktemp -d)"
mkdir -p "$FIX31/.deck"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$FIX31/.deck/workspace.yaml"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$FIX31/.deck/toggles.yaml"
FP31="$(mktemp -d)/foldpack31"
d31() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$FIX31" "$DECK" "$@"; }
d31 pack new foldpack31 --dir "$FP31" >/dev/null 2>&1

helpout31="$(d31 ask fold --help 2>&1 || true)"
if printf '%s' "$helpout31" | grep -qF 'becomes askable'; then
  bad "--header's help describes what the flag does, not what it used to promise" "$helpout31"
elif printf '%s' "$helpout31" | grep -qF 'wording a selector'; then
  ok "--header's help describes what the flag does, not what it used to promise"
else bad "--header's help describes what the flag does, not what it used to promise" "$helpout31"; fi

out31="$(d31 ask new "Should retries within a batch share one budget or count separately?" --options "shared,separate" 2>&1 || true)"
CID31="$(printf '%s' "$out31" | grep -oE '^recorded .*' | cut -d' ' -f2)"
d31 ask resolve "$CID31" "Shared. One budget for the whole batch." >/dev/null 2>&1
d31 ask fold "$CID31" --as toggle --into "$FP31" --group quality --gate-id batch_retry_budget --header "Retry budg" \
  --impact "shared=One budget for the whole batch; a bad item can starve the rest." \
  --impact "separate=Each item gets its own budget; a bad item costs only itself." >/dev/null 2>&1
# Read it back through deck, the way the issue's own reproduction did — not by
# grepping config/toggles.yaml, which only proves the writer wrote what it
# wrote.
plan31="$(env -u DECK_PACKS_ROOT DECK_ROOT="$FIX31" DECK_PACKS="$FP31" "$DECK" toggle ask-plan --stage plan 2>&1 || true)"
if printf '%s' "$plan31" | grep -qF 'batch_retry_budget'; then
  bad "a toggle folded with --header still does not appear in the plan for any stage" "$plan31"
else ok "a toggle folded with --header still does not appear in the plan for any stage"; fi
rm -rf "$FIX31" "$(dirname "$FP31")"

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
