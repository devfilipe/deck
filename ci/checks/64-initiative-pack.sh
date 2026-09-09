# ------------------------------- a pack that belongs to an initiative
note "a pack that belongs to an initiative"
# A pack reached an agent by three routes: named explicitly, shared by its
# directory name, or named after a repository. None of them says "this belongs
# to this initiative", so knowledge that only matters while one is running was
# either loaded for everybody or written nowhere. `scope:` in a pack's own
# config/detect.yaml is the fourth route, and it comes and goes with
# `deck --scope`.
SP="$(mktemp -d)"; SPP="$SP/packs"
mkdir -p "$SP/.deck" "$SP"/{api,server,ops} \
         "$SPP/_workspaces/all/default"/{config,templates/workspace} \
         "$SPP/_workspaces/all/payments"/{config,rules,templates/workspace} \
         "$SPP/_workspaces/all/ledger"/{config,templates/workspace} \
         "$SPP/_repos/server/config"
for d in api server ops; do git -C "$SP/$d" init -q 2>/dev/null; done
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$SP/.deck/toggles.yaml"
cat > "$SP/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    lint: "true", impacts: [server] }
  server: { path: server, lint: "true", impacts: [] }
  ops:    { path: ops,    lint: "true", impacts: [] }
scopes:
  payments: { title: Payments migration, repos: [api, server] }
  house:    { title: A local errand,     repos: [ops] }
targets: []
YAML
printf 'markers: []\n' > "$SPP/_workspaces/all/default/config/detect.yaml"
printf 'gates:\n  - { id: lint, title: Workspace lint, from_level: static, per_repo: "${repo.lint}" }\n' \
  > "$SPP/_workspaces/all/default/config/gates.yaml"
cat > "$SPP/_workspaces/all/default/templates/workspace/workspace.yaml" <<'YAML'
version: 1
repos:
  api:    { path: api,    impacts: [server] }
  server: { path: server, impacts: [] }
  ops:    { path: ops,    impacts: [] }
scopes: {}
YAML
printf 'markers: []\n' > "$SPP/_repos/server/config/detect.yaml"
# The initiative's own layer: bound by where it sits, which is the pair the
# collection is indexed by. Nothing inside it repeats the binding.
printf 'markers: []\n' > "$SPP/_workspaces/all/payments/config/detect.yaml"
printf 'gates:\n  - { id: audit, title: Audit trail, from_level: static, per_repo: "echo auditing ${repo.name}" }\n' \
  > "$SPP/_workspaces/all/payments/config/gates.yaml"
printf -- '---\npaths: ["**/*.py"]\n---\n\nThe vocabulary this initiative reports in.\n' \
  > "$SPP/_workspaces/all/payments/rules/regs.md"
printf 'rules:\n  - { file: rules/regs.md }\n' > "$SPP/_workspaces/all/payments/config/mount.yaml"
cat > "$SPP/_workspaces/all/payments/templates/workspace/workspace.yaml" <<'YAML'
scopes:
  payments: { title: Payments migration, repos: [api, server] }
YAML
# A second initiative, versioned in a pack of its own — which is the whole of
# the other half: neither team edits the file the other one lives in.
printf 'markers: []\n' > "$SPP/_workspaces/all/ledger/config/detect.yaml"
cat > "$SPP/_workspaces/all/ledger/templates/workspace/workspace.yaml" <<'YAML'
scopes:
  ledger: { title: Ledger rewrite, repos: [ops] }
YAML
SPENV=(env DECK_ROOT="$SP" DECK_PACKS_ROOT="$SPP")

# Not in play means not in play: a gate it declares is not on the ladder while
# nobody has asked for the initiative.
sp_idle="$("${SPENV[@]}" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$sp_idle" | grep -q "audit"; then
  bad "a scope-bound pack declares nothing while its scope is inactive" "$sp_idle"
else ok "a scope-bound pack declares nothing while its scope is inactive"; fi

# And knowledge nobody can find is worse than knowledge loaded too widely, so
# the pack is still listed — with the command that brings it in.
sp_packs="$("${SPENV[@]}" "$DECK" packs 2>&1 || true)"
if printf '%s' "$sp_packs" | grep -q '^not in play'; then
  ok "a scope-bound pack that is not in play is listed rather than hidden"
else bad "a scope-bound pack that is not in play is listed rather than hidden" "$sp_packs"; fi
if printf '%s' "$sp_packs" | grep -q 'bring it in with: deck --scope payments'; then
  ok "and the listing names the command that brings it in"
else bad "and the listing names the command that brings it in" "$sp_packs"; fi

sp_scoped="$("${SPENV[@]}" "$DECK" --scope payments gate list 2>&1 || true)"
if printf '%s' "$sp_scoped" | grep -q "audit"; then
  ok "and under its own scope it reaches the ladder"
else bad "and under its own scope it reaches the ladder" "$sp_scoped"; fi

# Merge order is the stated one: an initiative is narrower than the workspace
# and wider than one codebase, so its layer sits between the two.
sp_order="$("${SPENV[@]}" "$DECK" --scope payments packs 2>&1 || true)"
sp_names="$(printf '%s' "$sp_order" | grep -E '^  [0-9]+  ' | awk '{print $2}' | tr '\n' ' ')"
if [ "$sp_names" = "all/default all/payments server " ]; then
  ok "it merges after the workspace-wide pack and before the repository's own"
else bad "it merges after the workspace-wide pack and before the repository's own" "got: $sp_names"; fi

# A collision resolves by the rule every other layer already uses, so there is
# one mechanism to learn rather than two.
cat > "$SPP/_workspaces/all/payments/config/gates.yaml" <<'YAML'
gates:
  - { id: audit, title: Audit trail, from_level: static, per_repo: "echo auditing ${repo.name}" }
  - { id: lint,  title: Audited lint, from_level: static, per_repo: "${repo.lint}" }
YAML
check_fail "an id it reuses without \`overrides: true\` is refused" \
  "${SPENV[@]}" "$DECK" --scope payments gate list
python3 - "$SPP/_workspaces/all/payments/config/gates.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("{ id: lint,  title:", "{ id: lint, overrides: true, title:"))
PY
check "and with it the initiative's pack has the last word" "Audited lint" \
  "${SPENV[@]}" "$DECK" --scope payments gate list
sp_outside="$("${SPENV[@]}" "$DECK" gate list 2>&1 || true)"
if printf '%s' "$sp_outside" | grep -q "Workspace lint"; then
  ok "and outside the scope the same id is the workspace pack's again"
else bad "and outside the scope the same id is the workspace pack's again" "$sp_outside"; fi

sp_narrow="$("${SPENV[@]}" "$DECK" --scope payments gate list --repos ops 2>&1 || true)"
if printf '%s' "$sp_narrow" | grep -q "audit.*skipped"; then
  ok "a gate it declares does not run outside the scope, even when --repos names one"
else bad "a gate it declares does not run outside the scope, even when --repos names one" "$sp_narrow"; fi

# A gate that appears and disappears with a flag is a different proposition
# from one every session carries, so the evidence has to say which scope was
# active and which pack each gate came from — and so does the page a reviewer
# reads instead of the diff.
"${SPENV[@]}" "$DECK" --scope payments gate run --task SP-1 --level static >/dev/null 2>&1
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["scope"]=="payments" else 1)' \
     "$SP/.deck/gates/SP-1.json"; then
  ok "the evidence records the scope the ladder climbed inside"
else bad "the evidence records the scope the ladder climbed inside" "$(cat "$SP/.deck/gates/SP-1.json" | head -6)"; fi
sp_bundle="$("${SPENV[@]}" "$DECK" bundle --task SP-1 2>&1 || true)"
if printf '%s' "$sp_bundle" | grep -q '^  scope    payments'; then
  ok "and the bundle says which initiative it was, whatever the coverage"
else bad "and the bundle says which initiative it was, whatever the coverage" "$sp_bundle"; fi
sp_md="$("${SPENV[@]}" "$DECK" bundle --task SP-1 --markdown 2>&1 || true)"
if printf '%s' "$sp_md" | grep -q '| audit | passed | all/payments |'; then
  ok "and names the pack each gate came from, for a reviewer who was not there"
else bad "and names the pack each gate came from, for a reviewer who was not there" "$sp_md"; fi

# The promise to everybody not using this: with no scope declared, a pack bound
# to one is inert. Composition, ladder and catalog are compared with the pack
# present and with it taken away, and they have to be the same text.
sp_composition() {
  "${SPENV[@]}" "$DECK" gate list 2>&1
  "${SPENV[@]}" "$DECK" toggle list 2>&1
  "${SPENV[@]}" "$DECK" packs --json 2>&1 | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["packs"], indent=1))' 2>&1
}
python3 - "$SP/.deck/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text()); d.pop("scopes", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
sp_present="$(sp_composition)"
mv "$SPP/_workspaces/all/payments" "$SP/parked-payments"; mv "$SPP/_workspaces/all/ledger" "$SP/parked-ledger"
sp_absent="$(sp_composition)"
mv "$SP/parked-payments" "$SPP/_workspaces/all/payments"; mv "$SP/parked-ledger" "$SPP/_workspaces/all/ledger"
if [ "$sp_present" = "$sp_absent" ]; then
  ok "where no scope is declared, a pack bound to one changes nothing at all"
else bad "where no scope is declared, a pack bound to one changes nothing at all" "the two compositions differ"; fi
python3 - "$SP/.deck/workspace.yaml" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["scopes"] = {"payments": {"title": "Payments migration", "repos": ["api"]},
               "house": {"title": "A local errand", "repos": ["ops"]}}
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
