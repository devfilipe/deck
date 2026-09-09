note "scopes"
# A scope is a named subset of the registry with its own board and posture. The
# checks that matter are the ones about what it must NOT do: narrowing what a
# command acts on is the feature, narrowing what deck knows would be a lie.
cat > "$WS/.deck/board-side.yaml" <<'YAML'
tasks:
  - { id: S-1, title: side work,            repos: [c] }
  - { id: S-2, title: side work that leaks, repos: [c, a] }
YAML
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {
    "core": {"title": "The build chain", "repos": ["a", "b"]},
    "side": {"title": "The side project", "repos": ["c"],
             "backlog": [{"type": "tasks", "file": ".deck/board-side.yaml"}]},
}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "declared scopes are listed"     "core"    "$DECK" scopes
check "a scope names its subset"       "2 of 3"  "$DECK" scope core
check "and what it reaches outside"    "reaches" "$DECK" scope core
# Regression guard: this registry declares no `couples:`, and the coupled half
# of the boundary report has to stay silent rather than print an empty heading.
out="$("$DECK" scope core 2>&1 || true)"
if printf '%s' "$out" | grep -qi "coupled"; then
  bad "a scope in a registry with no coupling says nothing about coupling" "$out"
else ok "a scope in a registry with no coupling says nothing about coupling"; fi
if [ "$("$DECK" --scope core repos | tr '\n' ' ')" = "a b " ]; then
  ok "the registry narrows to exactly the scope"
else
  bad "the registry narrows to exactly the scope" "got: $("$DECK" --scope core repos | tr '\n' ' ')"
fi
check_fail "an undeclared scope is refused" "$DECK" --scope nope repos
out="$("$DECK" --scope nope repos 2>&1 || true)"
if printf '%s' "$out" | grep -q "core, side"; then ok "and the refusal lists the real ones"; else bad "and the refusal lists the real ones" "$out"; fi

# The graph is not narrowed. A change inside a scope still reaches what it
# reaches, and the report says which of those the scope does not hold.
check "impact still reports the whole chain" '"c"'            "$DECK" --scope core impact a --json
check "and marks what falls outside"         "outside scope"  "$DECK" --scope core impact a

# `c` is not in `core`, so T-2 is not this scope's work.
if "$DECK" --scope core board list | grep -q "T-2"; then
  bad "the shared board is narrowed to the scope"
else
  ok "the shared board is narrowed to the scope"
fi
check "and keeps the tasks it does hold"    "T-1" "$DECK" --scope core board list
# A task naming no repository cannot be placed in one scope rather than
# another, so no scope takes it — and it is named rather than dropped in
# silence, which is the difference between a filter and a disappearance.
printf '  - { id: T-6, title: names no repository }\n' >> "$WS/.deck/board.yaml"
check "a scope with its own board reads it" "S-1" "$DECK" --scope side board list
if "$DECK" --scope side board list | grep -q "T-1"; then
  bad "its own board replaces the workspace one"
else
  ok "its own board replaces the workspace one"
fi
check "a task naming a repo the scope lacks is reported" "which the scope does not hold" "$DECK" --scope side board list
check "a task naming no repository is not silently claimed" "no scope claims" "$DECK" --scope core board list

# The posture: a layer between the repository and the workspace.
"$DECK" toggle set --at core gate_level build >/dev/null
if [ "$("$DECK" --scope core toggle get gate_level)" = "build" ]; then
  ok "a value recorded for a scope applies inside it"
else
  bad "a value recorded for a scope applies inside it" "got: $("$DECK" --scope core toggle get gate_level)"
fi
if [ "$("$DECK" --scope side toggle get gate_level)" = "build" ]; then
  bad "and nowhere else" "the value leaked into another scope"
else
  ok "and nowhere else"
fi
check "the layer says where the value came from" "scope core" "$DECK" --scope core toggle explain gate_level
# `deck scope <name>` is the only view that shows a scope whole, and the posture
# is the part of it somebody argued about. It printed the values alone, so the
# argument stayed in the file — while `--json` has carried the `reasons:` block
# verbatim all along, which made the text form the odd one out.
"$DECK" toggle set --at core test_depth full \
  --why "everything downstream compiles against this schema" >/dev/null
shown="$("$DECK" scope core 2>&1 || true)"
if printf '%s' "$shown" | grep -q "why  everything downstream compiles against this schema"; then
  ok "deck scope shows the reason recorded with a posture value"
else
  bad "deck scope shows the reason recorded with a posture value" "$shown"
fi
posture="$(printf '%s' "$shown" | grep -A1 "gate_level" || true)"
if printf '%s' "$posture" | grep -q 'not recorded — deck toggle set gate_level build --at core --why'; then
  ok "and names the command for a posture value that has none"
else
  bad "and names the command for a posture value that has none" "$posture"
fi
check_fail "recording at a scope nobody declared is refused" "$DECK" toggle set --at nope gate_level build
"$DECK" toggle profile guided --at side >/dev/null
check "a profile can be recorded for a scope" "guided" "$DECK" --scope side toggle list --stage plan

# The ladder climbs the scope, not the registry.
check "gates run over the scope" "repos    a, b" "$DECK" --scope core gate list

check "doctor reports the scopes" "core" "$DECK" doctor
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"]["core"]["repos"] = ["a", "b", "ghost"]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check_fail "a scope naming an unknown repository fails the diagnosis" "$DECK" doctor
out="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "which the registry does not declare"; then
  ok "and says which name is wrong"
else
  bad "and says which name is wrong" "$out"
fi
out="$(DECK_SCOPE=nope "$DECK" doctor 2>&1 || true)"
if printf '%s' "$out" | grep -q "not a declared scope"; then
  ok "an exported scope nobody declares is reported"
else
  bad "an exported scope nobody declares is reported" "$out"
fi

# Take the scopes away and leave the posture behind: a decision recorded for
# something that no longer exists applies to nothing, which is worse than no
# decision at all.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check_fail "a posture left behind for a scope that is gone is caught" "$DECK" toggle validate
out="$("$DECK" toggle validate 2>&1 || true)"
if printf '%s' "$out" | grep -q "no such scope"; then ok "and names it"; else bad "and names it" "$out"; fi
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()) or {}
d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
rm -f "$WS/.deck/board-side.yaml"
python3 - "$WS/.deck/board.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("  - { id: T-6, title: names no repository }\n", ""))
PY
