note "what a pack seeded from a workspace carries"
# `--from-workspace` turns one person's registry into the template a team
# shares, through an allowlist of per-repository fields. `downstream` was
# missing from it, so every repository that produces no artifact came out of a
# seed looking like an ordinary build node; `couples` had been missing before
# that. The rule is one question — would this value still be true on the next
# person's machine — and there is a check below per field the rule lets
# through, so the next field lost by omission is lost loudly.
SW="$(mktemp -d)"
mkdir -p "$SW/.deck" "$SW"/{svc,ops,e2e} "$SW/round2/.deck" "$SW/round2"/{svc,ops,e2e}
cat > "$SW/.deck/workspace.yaml" <<'YAML'
version: 1
requires_files: [svc/Makefile]
instruction_files: [CLAUDE.md, HOUSE.md]
sources: [some-registry]
container: acme/toolchain:latest
paths:
  tools: /home/someone-else/tools
repos:
  svc:
    path: svc
    role: request handling
    remote_id: acme/svc
    build_target: pkg-svc
    lint: make lint
    deploy_path: /opt/svc/
    services: [svcd]
    impacts: [e2e]
    couples: [ops]
    revision: refs/heads/one-afternoon
    remote: origin
  ops:
    path: ops
    role: the deployment commands the service shells out to
    impacts: []
  e2e:
    path: e2e
    role: end-to-end assertions over the running service
    downstream: true
    impacts: []
  ext:
    path: /home/someone-else/workspace/clones/acme/ext-tool
    role: a repository this workspace edits but keeps outside its own tree
    impacts: []
scopes:
  build:
    title: Everything this workspace builds
    repos: [svc, ops, e2e]
targets:
  - { host: 10.9.9.9, alias: someones-lab }
YAML
env DECK_ROOT="$SW" "$DECK" pack new "$SW/seeded" --from-workspace >/dev/null 2>&1 || true
SEEDED="$SW/seeded/templates/workspace/workspace.yaml"

# ---- re-seeding a template is not resetting a pack
# The observed loss: a `_workspace` pack was re-seeded to check that a scope
# travelled into version control. It did — and the same command came back with
# `gates: []` and an empty `rules:`, taking a declared gate and two mount
# entries that had nothing to do with the template. Nothing in the output said
# so; the closing words were about targets being left empty on purpose, printed
# while three other files were emptied without mention.
note "re-seeding a template is not resetting a pack"
RS="$SW/reseed"
env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" >/dev/null 2>&1
cat > "$RS/config/gates.yaml" <<'YAML'
gates:
  - { id: mine, title: a gate somebody wrote, from_level: static, once: "true" }
YAML
cat > "$RS/config/mount.yaml" <<'YAML'
rules:
  - { file: rules/one.md }
  - { file: rules/two.md }
  - { file: rules/three.md }
YAML
printf 'toggles:
  - { id: kept_choice, group: quality, title: t, summary: s, type: enum, values: [a, b], default: a, askable: false, impact: { a: x, b: y } }
' > "$RS/config/toggles.yaml"
reseed="$(env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" --from-workspace --force 2>&1 || true)"
if grep -q 'id: mine' "$RS/config/gates.yaml"; then
  ok "a gate the pack declared survives --force"
else bad "a gate the pack declared survives --force" "$reseed"; fi
# Uncommented entries only, and three of them. The scaffold `mount.yaml` ships
# two commented examples that also match a bare `file: rules/`, so a count of
# two passed on the broken code as well and proved nothing.
if [ "$(grep -c '^  - .*file: rules/' "$RS/config/mount.yaml")" = "3" ]; then
  ok "and the mount entries that made its rules do anything"
else bad "and the mount entries that made its rules do anything" "$(cat "$RS/config/mount.yaml")"; fi
if grep -q 'kept_choice' "$RS/config/toggles.yaml"; then
  ok "and the catalog entries somebody wrote"
else bad "and the catalog entries somebody wrote" "$(cat "$RS/config/toggles.yaml")"; fi
if grep -q 'Seeded by' "$RS/templates/workspace/workspace.yaml"; then
  ok "while the template it was asked to re-seed is rewritten"
else bad "while the template it was asked to re-seed is rewritten" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'templates/workspace/workspace.yaml   (replaced)'; then
  ok "and the one file it replaced is named as replaced"
else bad "and the one file it replaced is named as replaced" "$reseed"; fi
# Spared is not enough: a reader has to be able to tell a pack that was
# protected from one that was blank anyway.
if printf '%s' "$reseed" | grep -q 'config/gates.yaml.*1 gate'; then
  ok "what it kept is named, and what that file holds"
else bad "what it kept is named, and what that file holds" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'scaffold file(s) with nothing declared'; then
  ok "and the untouched scaffold is counted, not listed line by line"
else bad "and the untouched scaffold is counted, not listed line by line" "$reseed"; fi
if printf '%s' "$reseed" | grep -q 'updated at'; then
  ok "a pack that already existed is not announced as created"
else bad "a pack that already existed is not announced as created" "$reseed"; fi

# A gap in the scaffold is still filled: writing a file that is not there takes
# nothing away, which is the whole difference from replacing one. `--force` is
# what gets a second run this far at all — the guard at the top of `pack new`
# refuses a non-empty directory without it, and that is unchanged.
rm -f "$RS/config/profiles.yaml"
nogap="$(env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" 2>&1 || true)"
if printf '%s' "$nogap" | grep -q 'already exists and is not empty'; then
  ok "a second run on a non-empty pack still needs --force to do anything"
else bad "a second run on a non-empty pack still needs --force to do anything" "$nogap"; fi
env DECK_ROOT="$SW" "$DECK" pack new held --dir "$RS" --force >/dev/null 2>&1
if [ -f "$RS/config/profiles.yaml" ]; then
  ok "and then a missing scaffold file is written back"
else bad "and then a missing scaffold file is written back"; fi
if grep -q 'id: mine' "$RS/config/gates.yaml"; then
  ok "and filling that gap still leaves the declarations alone"
else bad "and filling that gap still leaves the declarations alone"; fi

# Scaffolding a genuinely new pack is untouched.
fresh_out="$(env DECK_ROOT="$SW" "$DECK" pack new brandnew --dir "$SW/brandnew" 2>&1 || true)"
if printf '%s' "$fresh_out" | grep -q 'created at'; then
  ok "a new pack is still announced as created"
else bad "a new pack is still announced as created" "$fresh_out"; fi
fresh_count="$(printf '%s' "$fresh_out" | grep -cE '^  (config|rules|skills|agents|templates|README|\.claude)')"
if [ "$fresh_count" -ge 7 ]; then
  ok "and still gets the whole scaffold, every file of it"
else bad "and still gets the whole scaffold, every file of it" "$fresh_count file(s): $fresh_out"; fi
if printf '%s' "$fresh_out" | grep -q 'kept —'; then
  bad "and has nothing to report as kept, having held nothing" "$fresh_out"
else ok "and has nothing to report as kept, having held nothing"; fi

# Flattened once, asserted one field per check: a single python block holding
# every assertion would report one failure for ten different reasons.
seed_fields="$(python3 - "$SEEDED" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for name, entry in (d.get("repos") or {}).items():
    for k, v in entry.items():
        print(f"{name}.{k}={v}")
print(f"top={','.join(sorted(d))}")
print(f"targets={d.get('targets')!r}")
PY
)"
if printf '%s' "$seed_fields" | grep -q "^svc\.path="; then
  ok "the seeded template parses and holds the registry"
else bad "the seeded template parses and holds the registry" "$seed_fields"; fi

seeded_has() {
  if printf '%s' "$seed_fields" | grep -qxF "$2"; then ok "$1"
  else bad "$1" "$(printf '%s' "$seed_fields" | grep "^${2%%=*}=" || printf 'no %s line' "${2%%=*}")"; fi
}
seeded_lacks() {
  if printf '%s' "$seed_fields" | grep -q "^$2="; then
    bad "$1" "$(printf '%s' "$seed_fields" | grep "^$2=")"
  else ok "$1"; fi
}

# One per field in SEEDED_REPO_FIELDS, in that order.
seeded_has "the seed carries path — the layout below the root, not the root"  "svc.path=svc"
seeded_has "the seed carries role"                                           "svc.role=request handling"
seeded_has "the seed carries remote_id"                                      "svc.remote_id=acme/svc"
seeded_has "the seed carries build_target"                                   "svc.build_target=pkg-svc"
seeded_has "the seed carries lint"                                           "svc.lint=make lint"
seeded_has "the seed carries deploy_path"                                    "svc.deploy_path=/opt/svc/"
seeded_has "the seed carries services"                                       "svc.services=['svcd']"
seeded_has "the seed carries downstream"                                     "e2e.downstream=True"
seeded_has "the seed carries impacts"                                        "svc.impacts=['e2e']"
seeded_has "the seed carries couples"                                        "svc.couples=['ops']"

# The other half of the rule: a field that describes one checkout, and one
# machine's directories and hosts, do not travel.
seeded_lacks "a revision the next import rewrites does not travel"  "svc.revision"
seeded_lacks "and neither does the remote it was read through"      "svc.remote"
top_keys="$(printf '%s' "$seed_fields" | grep '^top=' || true)"
if printf '%s' "$top_keys" | grep -q "paths"; then
  bad "one machine's tools directory does not travel either" "$top_keys"
else ok "one machine's tools directory does not travel either"; fi
if printf '%s' "$seed_fields" | grep -qxF "targets=[]"; then
  ok "targets are emptied, not copied — an allowlist is a decision"
else bad "targets are emptied, not copied — an allowlist is a decision" "$(printf '%s' "$seed_fields" | grep '^targets=')"; fi

# One per field in SEEDED_WORKSPACE_FIELDS. `sources` and `container` sat in
# that tuple with no reader anywhere in the repository — a seeded template
# handed a team two keys nobody could explain. `requires_files` and `scopes`
# are the ones that stayed, each with a reader, and each checked here so the
# next field lost by omission (as `scopes` once was) fails loudly instead.
if printf '%s' "$top_keys" | grep -q "requires_files"; then
  ok "the seed carries requires_files — deck doctor reads it"
else bad "the seed carries requires_files — deck doctor reads it" "$top_keys"; fi
if printf '%s' "$top_keys" | grep -q "scopes"; then
  ok "the seed carries scopes — the team's carve-up, not one machine's"
else bad "the seed carries scopes — the team's carve-up, not one machine's" "$top_keys"; fi
if printf '%s' "$top_keys" | grep -q "instruction_files"; then
  ok "the seed carries instruction_files — which names carry instruction here"
else bad "the seed carries instruction_files — which names carry instruction here" "$top_keys"; fi
if printf '%s' "$top_keys" | grep -q "sources"; then
  bad "the seed does not carry sources — nothing in the repository reads it" "$top_keys"
else ok "the seed does not carry sources — nothing in the repository reads it"; fi
if printf '%s' "$top_keys" | grep -q "container"; then
  bad "and does not carry container — no reader, no writer, either" "$top_keys"
else ok "and does not carry container — no reader, no writer, either"; fi

# ---- an absolute path is this machine's, not the layout everyone clones
# A repository is allowed to sit outside the workspace root, and there `path`
# is a home directory, true of nobody's checkout but this one. Seeding it
# verbatim hands the next person a descriptor that resolves to a path they do
# not have; the fix is to drop it the same way a scope's `user` is dropped,
# and say so, while everything else about the repository still travels.
seeded_lacks "an absolute path does not travel"                  "ext.path"
seeded_has   "and the repository it named keeps its role anyway" "ext.role=a repository this workspace edits but keeps outside its own tree"
if grep -q 'ext' "$SEEDED" && grep -qi 'absolute' "$SEEDED"; then
  ok "and the seeded file says the path was dropped, and why"
else bad "and the seeded file says the path was dropped, and why" "$(head -20 "$SEEDED")"; fi

# ---- a scope's board says which board, never who is asking for it
# The seed's rule is one question — would this value still be true on the next
# person's machine — and `scopes:` was copied whole, so a tracker `backlog:`
# carried the account it authenticates as into a file a team versions. It
# reached a real template before anyone noticed.
note "a seeded board names the board, not the person"
PS="$(mktemp -d)"
mkdir -p "$PS/.deck" "$PS/app"
cat > "$PS/.deck/workspace.yaml" <<'YAML'
version: 1
repos: { app: { path: app } }
scopes:
  billing:
    title: Billing
    repos: [app]
    backlog:
      - { type: jira, url: https://example.atlassian.net, project: ABC123, user: someone@example.com }
  reporting:
    title: Reporting
    repos: [app]
YAML
env DECK_ROOT="$PS" "$DECK" pack new seeded --dir "$PS/pk" --from-workspace >/dev/null 2>&1 || true
PSEED="$PS/pk/templates/workspace/workspace.yaml"
ps_scope="$(python3 - "$PSEED" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
scopes = d.get("scopes") or {}
for source in (scopes.get("billing") or {}).get("backlog") or []:
    for k, v in sorted(source.items()):
        print(f"billing.{k}={v}")
print(f"reporting_keys={','.join(sorted(scopes.get('reporting') or {}))}")
PY
)"
if printf '%s' "$ps_scope" | grep -q 'billing.project=ABC123'; then
  ok "a seeded scope keeps the board it names"
else bad "a seeded scope keeps the board it names" "$ps_scope"; fi
if printf '%s' "$ps_scope" | grep -q 'billing.url=https://example.atlassian.net'; then
  ok "and the host it is read from"
else bad "and the host it is read from" "$ps_scope"; fi
if printf '%s' "$ps_scope" | grep -q 'billing.user='; then
  bad "and drops the account it authenticates as — that is per person" "$ps_scope"
else ok "and drops the account it authenticates as — that is per person"; fi
if grep -q 'who is asking for it: `user`' "$PSEED"; then
  ok "and the file says which field did not travel, as it does for repositories"
else bad "and the file says which field did not travel, as it does for repositories" "$(head -12 "$PSEED")"; fi
# A field removed in silence is one somebody puts back; a field named is one
# they fill in on their own machine. The rest of the scope is untouched.
if printf '%s' "$ps_scope" | grep -q 'reporting_keys=repos,title'; then
  ok "a scope with no board seeds exactly as it did"
else bad "a scope with no board seeds exactly as it did" "$ps_scope"; fi
# The trip has to work in both directions: what is seeded still resolves.
cp "$PSEED" "$PS/.deck/workspace.yaml"
ps_back="$(env DECK_ROOT="$PS" "$DECK" scopes 2>&1 || true)"
if printf '%s' "$ps_back" | grep -q 'billing'; then
  ok "and a workspace initialised from it still declares the scope"
else bad "and a workspace initialised from it still declares the scope" "$ps_back"; fi
rm -rf "$PS"

# The end of the trip the seed exists for: the template becomes somebody's
# registry, and the repository that produces no artifact is still saying so.
cp "$SEEDED" "$SW/round2/.deck/workspace.yaml"
r2="$(env DECK_ROOT="$SW/round2" "$DECK" repos --downstream-only 2>&1 || true)"
if printf '%s' "$r2" | grep -q "e2e"; then
  ok "a workspace initialised from the seeded template still knows e2e is downstream"
else bad "a workspace initialised from the seeded template still knows e2e is downstream" "$r2"; fi
r2b="$(env DECK_ROOT="$SW/round2" "$DECK" repos --buildable-only 2>&1 || true)"
if printf '%s' "$r2b" | grep -q "e2e"; then
  bad "and does not offer it as something to build" "$r2b"
else ok "and does not offer it as something to build"; fi
rm -rf "$SW"

note "what a board source is, survives being seeded"
# `pack new --from-workspace` keeps BOARD_IDENTITY and drops the rest, so a key
# missing from that tuple is a key that does not reach the next machine. `api:`
# was missing: a team on a self-hosted host seeded a template that quietly
# pointed at the public service, and nothing said so. This asks the question
# generically — every field the documents describe for a tracker, plus the two
# that say which host and how "taken" is written down — so the next field added
# cannot be forgotten the same way.
_seedkeys="$(python3 - "$REPO" <<'PYSEED'
import sys, pathlib, importlib.util
repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / "plugins/deck"))
from deck.workspace import BOARD_IDENTITY

spec = importlib.util.spec_from_file_location("_dc", repo / "ci" / "docs-cover.py")
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)
print(" ".join(f for f in dc.MUST_SURVIVE_SEEDING if f not in BOARD_IDENTITY))
PYSEED
)"
if [ -z "$_seedkeys" ]; then
  ok "every field that says what a board source is reaches the seeded template"
else
  bad "every field that says what a board source is reaches the seeded template" "dropped: $_seedkeys"
fi
