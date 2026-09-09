# ---- a rule the pack holds and mount.yaml never names reaches nobody
# The observed failure: `apply` wrote five rule files into a pack, listed each
# one by name, and left `config/mount.yaml` untouched. `mount.yaml` is what
# decides which rules are placed, so the report read like delivery and nothing
# was delivered. Twenty-two rules across five packs, all inert.
note "a rule is a file and an entry"
MP="$WS/mountpack"
"$DECK" pack new mounted --dir "$MP" >/dev/null
cat > "$WS/.deck/proposals/pack-rules.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"toggles":[],"questions":[],"unsure":[],
"rules":[{"name":"Handlers validate at the edge","paths":["src/handlers/**"],
  "consequence":"Nothing below the handler re-checks shapes.","evidence":"src/handlers/base.py:20","confidence":"high"},
 {"name":"Migrations are forward only","paths":["migrations/**"],
  "consequence":"A down migration is never run in production.","evidence":"migrations/README:4","confidence":"high"}]}}
JSON
ruleout="$("$DECK" propose apply pack-rules.json --into "$MP" --confidence high --yes 2>&1 || true)"
# ------------------------------ an edge and a coupling are not one finding
# `impacts:` answers two questions with one edge — what must I revisit, and in
# what order. A pair that drives both ways answers the first and has no answer
# to the second, and before `couples:` existed a drafter had to discard one of
# the two directions to keep the graph acyclic; the discarded half survived as
# prose no command can read. The prompt now offers both kinds, and `apply`
# writes both. Nothing here calls a model: the wording is checked through
# --show-prompt, and `apply` is handed hand-written JSON.
