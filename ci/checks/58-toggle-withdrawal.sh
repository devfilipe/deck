# -------------------------------------- a recorded choice can be withdrawn (#25)
# `set` had no opposite: the only way to remove a recorded value was to hand-edit
# the choices file, deleting the entry from `values:` AND its matching key from
# `reasons:`, and getting an emptied block back to nothing rather than a stray
# `{}` — three edits, and a mismatch reads as valid to `validate` and wrong to a
# person. It also made the layering hard to explore: trying a narrow value and
# then taking it back to see a wider layer resurface was a one-way door.
note "a recorded toggle can be withdrawn"
UN="$(mktemp -d)"
mkdir -p "$UN/app" "$UN/.deck"
cat > "$UN/.deck/workspace.yaml" <<YAML
version: 1
repos:
  app: { path: app }
scopes:
  sec:
    title: Security
    repos: [app]
targets: []
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$UN/.deck/toggles.yaml"

check "unset is offered beside set, not invented as a separate command" "unset" env DECK_ROOT="$UN" "$DECK" toggle --help

out="$(env DECK_ROOT="$UN" "$DECK" toggle unset test_depth --at workspace 2>&1 || true)"
if printf '%s' "$out" | grep -q "nothing to withdraw"; then
  ok "unset refuses when nothing is recorded at that layer, rather than silently succeeding"
else
  bad "unset refuses when nothing is recorded at that layer, rather than silently succeeding" "$out"
fi

env DECK_ROOT="$UN" "$DECK" toggle set gate_level build --at workspace --why "trying the mechanism" >/dev/null
out="$(env DECK_ROOT="$UN" "$DECK" toggle unset gate_level --at workspace 2>&1 || true)"
if printf '%s' "$out" | grep -q "gate_level unset"; then
  ok "unset withdraws a value that set recorded"
else
  bad "unset withdraws a value that set recorded" "$out"
fi
if printf '%s' "$out" | grep -q 'withdrew the recorded reason: "trying the mechanism"'; then
  ok "and reports the reason it withdrew along with it"
else
  bad "and reports the reason it withdrew along with it" "$out"
fi
if printf '%s' "$out" | grep -q "now: deploy"; then
  ok "and says which value becomes effective afterward — the sentence \`explain\` already knows"
else
  bad "and says which value becomes effective afterward" "$out"
fi
after_get="$(env DECK_ROOT="$UN" "$DECK" toggle get gate_level 2>&1 || true)"
if [ "$after_get" = "deploy" ]; then
  ok "and the wider layer is what deck now reads back"
else
  bad "and the wider layer is what deck now reads back" "got: $after_get"
fi
# The template ships gate_level in its own commented walkthrough, so grepping
# the whole file would pass on the comment and miss a real leftover key; read
# it back as YAML instead, the way deck itself would.
if python3 -c "
import yaml
data = yaml.safe_load(open('$UN/.deck/toggles.yaml')) or {}
raise SystemExit(1 if ('gate_level' in (data.get('values') or {}) or 'gate_level' in (data.get('reasons') or {})) else 0)
"; then
  ok "the file carries no trace of the withdrawn value or its reason"
else
  bad "the file carries no trace of the withdrawn value or its reason" "$(grep -A3 '^values:\|^reasons:' "$UN/.deck/toggles.yaml")"
fi

# The layering itself: a value at the narrow scope shadows the wider one, and
# withdrawing it lets the wider one resurface — the whole reason `--at` has
# layers at all.
env DECK_ROOT="$UN" "$DECK" toggle set --at workspace test_depth full --why "workspace default while this ships" >/dev/null
env DECK_ROOT="$UN" "$DECK" toggle set --at sec test_depth smoke --why "seeing --at sec actually shadow it" >/dev/null
narrow="$(env DECK_ROOT="$UN" "$DECK" --scope sec toggle get test_depth 2>&1 || true)"
if [ "$narrow" = "smoke" ]; then
  ok "a value at a narrow scope shadows the wider one"
else
  bad "a value at a narrow scope shadows the wider one" "got: $narrow"
fi
env DECK_ROOT="$UN" "$DECK" toggle unset test_depth --at sec >/dev/null 2>&1
resurfaced="$(env DECK_ROOT="$UN" "$DECK" --scope sec toggle get test_depth 2>&1 || true)"
if [ "$resurfaced" = "full" ]; then
  ok "withdrawing it lets the wider (workspace) layer resurface"
else
  bad "withdrawing it lets the wider (workspace) layer resurface" "got: $resurfaced"
fi

check_fail "unset at an undeclared scope is refused, not created" env DECK_ROOT="$UN" "$DECK" toggle unset test_depth --at nope

# The design question the issue itself raised: `set` requires `--why` because
# recording a choice is deliberate; withdrawing one is equally deliberate, but a
# reason for an absence has nowhere to live in `reasons:` — that map is keyed to
# `values:` and paired 1:1 with it (`validate` already refuses a reason with no
# value beside it). Adding one would mean inventing a new file shape, which is a
# bigger decision than this issue asked for. So `unset` does not take `--why`:
# the reason it is withdrawing is printed at the moment of the act instead, from
# whatever was recorded, which is the trace this had none of before.
check_fail "unset does not take --why — there is nowhere in the file for a reason to withdraw something" \
  env DECK_ROOT="$UN" "$DECK" toggle unset gate_level --at workspace --why "not supported"

rm -rf "$UN"
