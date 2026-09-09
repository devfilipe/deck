note "toggle precedence"
check "catalog default"        "affected" "$DECK" toggle get build_scope
check "catalog default holds"  "deploy"   "$DECK" toggle get gate_level
if [ "$(DECK_GATE_LEVEL=static "$DECK" toggle get gate_level)" = "static" ]; then
  ok "environment beats the workspace"
else
  bad "environment beats the workspace"
fi
"$DECK" toggle --session smoke set gate_level build --at task >/dev/null
if [ "$("$DECK" toggle --session smoke get gate_level)" = "build" ]; then
  ok "task beats the workspace"
else
  bad "task beats the workspace"
fi
"$DECK" toggle --session smoke profile guided --at task >/dev/null
check "profile guided requires tests" "required" "$DECK" toggle --session smoke get unit_tests

# ------------------------------------------------- the reason behind a value
# The value and the layer were always recorded; the sentence explaining the
# choice was not, so six months on a deliberate decision and a value nobody
# revisited looked identical. The catalog's own `why` is a different sentence
# by a different author, and the two are printed apart rather than merged.
note "why a value was chosen"

mkdir -p "$WS/.deck/state"
"$DECK" toggle --session why set gate_level build --at task \
  --why "delivery goes through a firmware update path nobody has wired to deck yet" >/dev/null
recorded="$(cat "$WS/.deck/state/toggles-why.yaml" 2>&1)"
if printf '%s' "$recorded" | grep -q "firmware update path"; then
  ok "the reason survives in the file, beside the value"
else
  bad "the reason survives in the file, beside the value" "$recorded"
fi

out="$("$DECK" toggle --session why explain gate_level 2>&1)"
if printf '%s' "$out" | grep -q "why the toggle exists"; then
  ok "explain still carries the catalog's own reason"
else
  bad "explain still carries the catalog's own reason" "$out"
fi
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "firmware update path"; then
  ok "and the chooser's reason under a heading of its own"
else
  bad "and the chooser's reason under a heading of its own" "$out"
fi

# The whole point of the split: a value with nothing recorded must not be able
# to borrow the catalog's paragraph and read as justified.
check "a value with no reason is still recorded" "gate_level = build" \
  "$DECK" toggle --session bare set gate_level build --at task
out="$("$DECK" toggle --session bare explain gate_level 2>&1)"
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "not recorded"; then
  ok "and says so rather than looking justified"
else
  bad "and says so rather than looking justified" "$out"
fi
if printf '%s' "$chosen" | grep -q "Not every change deserves"; then
  bad "the catalog's reason never stands in for a missing one" "$chosen"
else
  ok "the catalog's reason never stands in for a missing one"
fi
if printf '%s' "$chosen" | grep -q "deck toggle set gate_level build --at task --why"; then
  ok "and names the command that would record one"
else
  bad "and names the command that would record one" "$chosen"
fi

# A reason belongs to the value it was written for. Left behind, it would go on
# justifying a decision that is no longer the one in the file.
out="$("$DECK" toggle --session why set gate_level static --at task 2>&1)"
if printf '%s' "$out" | grep -q "dropped the reason"; then
  ok "a value set without --why drops the reason, and says so"
else
  bad "a value set without --why drops the reason, and says so" "$out"
fi
out="$("$DECK" toggle --session why explain gate_level 2>&1)"
if printf '%s' "$out" | grep -q "firmware update path"; then
  bad "the new value does not inherit the old one's reason" "$out"
else
  ok "the new value does not inherit the old one's reason"
fi
out="$("$DECK" toggle --session why set gate_level build --at task --why "   " 2>&1 || true)"
if printf '%s' "$out" | grep -q "needs a reason"; then
  ok "an empty --why is refused rather than recorded as none"
else
  bad "an empty --why is refused rather than recorded as none" "$out"
fi

# A choices file written before any of this existed keeps working, and claims
# no reason it does not have.
printf 'version: 1\nvalues:\n  gate_level: static\n' > "$WS/.deck/state/toggles-old.yaml"
check "a file written before reasons existed still resolves" "static" \
  "$DECK" toggle --session old get gate_level
out="$("$DECK" toggle --session old explain gate_level 2>&1)"
chosen="$(printf '%s' "$out" | sed -n '/why this value was chosen/,/^$/p')"
if printf '%s' "$chosen" | grep -q "not recorded"; then
  ok "and reports no reason rather than inventing one"
else
  bad "and reports no reason rather than inventing one" "$out"
fi

# The layer nobody sets from the command line: a repository block is written by
# hand, in either the flat shape it has always had or the nested one.
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["repos"] = {"a": {"gate_level": "behavior",
                    "reasons": {"gate_level": "it is the published contract"}}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
out="$(sh -c "cd '$WS/a' && '$DECK' toggle explain gate_level" 2>&1)"
if printf '%s' "$out" | grep -q "why this value was chosen (repo a)"; then
  ok "a hand-written repository choice carries its reason too"
else
  bad "a hand-written repository choice carries its reason too" "$out"
fi
value="$(sh -c "cd '$WS/a' && '$DECK' toggle get gate_level" 2>&1)"
if [ "$value" = "behavior" ]; then
  ok "and the reasons map beside it is not read as a toggle"
else
  bad "and the reasons map beside it is not read as a toggle" "got: $value"
fi

# A reason with no value beside it justifies a decision this layer never makes.
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["reasons"] = {"test_depth": "explains nothing: no value here"}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
out="$("$DECK" toggle validate 2>&1)"
if printf '%s' "$out" | grep -q "it explains nothing"; then
  ok "validate reports a reason with no value beside it"
else
  bad "validate reports a reason with no value beside it" "$out"
fi
python3 - "$WS/.deck/toggles.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d.pop("reasons", None); d["repos"] = {}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

# `--json` is the machine's view of the whole catalog at once. Without the
# reason in the row, a consumer that has just read fifty values has to call
# `explain` fifty times to find out which of them anyone decided.
"$DECK" toggle --session why set unit_tests required --at task \
  --why "the parser is the published contract, and nothing else checks it" >/dev/null
listed="$("$DECK" toggle --session why list --json 2>&1 || true)"
if printf '%s' "$listed" | python3 -c 'import json,sys
rows = {r["id"]: r for r in json.load(sys.stdin)["toggles"]}
sys.exit(0 if "published contract" in (rows["unit_tests"]["reason"] or "") else 1)' 2>/dev/null; then
  ok "toggle list --json carries the reason beside the value"
else
  bad "toggle list --json carries the reason beside the value" "$(printf '%s' "$listed" | head -3)"
fi
if printf '%s' "$listed" | python3 -c 'import json,sys
rows = {r["id"]: r for r in json.load(sys.stdin)["toggles"]}
sys.exit(0 if rows["question_budget"]["reason"] is None else 1)' 2>/dev/null; then
  ok "and a value nobody chose here carries null, not the catalog's rationale"
else
  bad "and a value nobody chose here carries null, not the catalog's rationale" \
    "$(printf '%s' "$listed" | head -3)"
fi

# A scope's toggles are read from `scopes.<name>.values`; a block written flat
# — the shape an earlier version of this template showed — resolves to nothing
# there and used to say nothing about it either. `deck toggle validate` is
# what has to catch it, since a value written this way never surfaces through
# `layers()` at all: there is nothing later in the pipeline that could.
note "a hand-written scope block in the flat shape"
FL="$(mktemp -d)/ws"
mkdir -p "$FL/.deck" "$FL/r1"
printf 'version: 1\nrepos:\n  r1: {path: r1, impacts: []}\nscopes:\n  x: {title: X, repos: [r1]}\n' \
  > "$FL/.deck/workspace.yaml"
printf 'version: 1\nscopes:\n  x:\n    gate_level: build\n' > "$FL/.deck/toggles.yaml"
out="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$FL" "$DECK" toggle validate --strict 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a scope block written flat is refused, not silently resolved to nothing"
else
  bad "a scope block written flat is refused, not silently resolved to nothing" "$out"
fi
# The shape the template actually shows — nested under `values:` — still
# reads cleanly, so this is the flat shape being refused and not scopes
# themselves.
printf 'version: 1\nscopes:\n  x:\n    values:\n      gate_level: build\n' > "$FL/.deck/toggles.yaml"
check "and the nested shape the template shows still validates clean" "OK —" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$FL" "$DECK" toggle validate --strict
rm -rf "$FL"
