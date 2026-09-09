note "workspace resolution"
check "root from the environment"   "$WS"       "$DECK" root
check "descriptor is read"          "pkg-a"     "$DECK" repos --verbose
check "absolute path"               "$WS/a"     "$DECK" path a
check "dotted key lookup"           "10.0.0.4"  "$DECK" get targets.0.host
check_fail "unknown repository fails"           "$DECK" path nope

unset DECK_ROOT
export DECK_PACKS_ROOT="$PACKS"
check "auto-detection via pack marker" "$WS" env -u DECK_ROOT sh -c "cd '$WS/a' && '$DECK' root"
export DECK_ROOT="$WS"

note "impact graph"
check "transitive closure"   '"impacted"'  "$DECK" impact a --json
check "build target"         "pkg-b"       "$DECK" impact a --json
check "downstream is flagged" "downstream" "$DECK" impact a --json
if [ "$("$DECK" order c b a | tr '\n' ' ')" = "a b c " ]; then
  ok "topological order is a b c even when given c b a"
else
  bad "topological order" "got: $("$DECK" order c b a | tr '\n' ' ')"
fi

# A cycle has to be detectable, and for a long time it was not: the first
# implementation leaned on helpers that are deliberately cycle-blind.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml, copy
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
bad = copy.deepcopy(d); bad["repos"]["c"]["impacts"] = ["a"]
pathlib.Path(str(p) + ".cycle").write_text(yaml.safe_dump(bad, sort_keys=False))
PY
cp "$WS/.deck/workspace.yaml" "$WS/.deck/workspace.yaml.ok"
cp "$WS/.deck/workspace.yaml.cycle" "$WS/.deck/workspace.yaml"
cyc="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$cyc" | grep -q "cycle"; then ok "a cycle is detected"; else bad "a cycle is detected"; fi
if "$DECK" doctor >/dev/null 2>&1; then bad "a cycle fails the diagnosis"; else ok "a cycle fails the diagnosis"; fi
cp "$WS/.deck/workspace.yaml.ok" "$WS/.deck/workspace.yaml"
acy="$("$DECK" doctor 2>&1 || true)"
if printf '%s' "$acy" | grep -q "acyclic"; then ok "an acyclic graph is reported as such"; else bad "an acyclic graph is reported as such"; fi
rm -f "$WS/.deck/workspace.yaml.cycle" "$WS/.deck/workspace.yaml.ok"

# An empty target allowlist is a gap only when the ladder is meant to climb past
# `build`. doctor used to warn unconditionally, so a workspace that had decided
# to stop at build carried a warning it could never clear.
cp "$WS/.deck/workspace.yaml" "$WS/.deck/workspace.yaml.withtarget"
sed -i '/^targets:/,/alias: lab-1 }/d' "$WS/.deck/workspace.yaml"
tgt="$(DECK_GATE_LEVEL=build "$DECK" doctor 2>&1 || true)"
if printf '%s' "$tgt" | grep -q "not needed: gate_level = build"; then
  ok "no target is fine when the ladder stops at build"
else
  bad "no target is fine when the ladder stops at build" "$(printf '%s' "$tgt" | grep -A1 'targets')"
fi
tgt="$(DECK_GATE_LEVEL=deploy "$DECK" doctor 2>&1 || true)"
if printf '%s' "$tgt" | grep -q "gate_level = deploy needs one"; then
  ok "no target still warns when the ladder reaches deploy"
else
  bad "no target still warns when the ladder reaches deploy" "$(printf '%s' "$tgt" | grep -A1 'targets')"
fi
mv "$WS/.deck/workspace.yaml.withtarget" "$WS/.deck/workspace.yaml"
