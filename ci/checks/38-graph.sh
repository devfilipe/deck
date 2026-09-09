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
