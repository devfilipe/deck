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
