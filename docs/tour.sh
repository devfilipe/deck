#!/usr/bin/env bash
# A guided tour of deck, from nothing to a verified delivery.
#
# It builds its own workspace and its own pack in a temporary directory, so it
# runs anywhere, needs no configuration, and touches nothing you own.
#
#   ./docs/tour.sh            run it
#   ./docs/tour.sh --fast     no typing delays (used in CI)
#   ./docs/tour.sh --keep     leave the workspace on disk afterwards
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECK="${DECK_BIN:-$ROOT/plugins/deck/bin/deck}"
FAST=""; KEEP=""
for arg in "$@"; do
  [ "$arg" = "--fast" ] && FAST=1
  [ "$arg" = "--keep" ] && KEEP=1
done

B=$'\033[1m'; D=$'\033[2m'; C=$'\033[36m'; R=$'\033[0m'

pause() { [ -n "$FAST" ] || sleep "${1:-1.4}"; }
say()   { printf '\n%s%s%s\n' "$B" "$1" "$R"; pause 0.8; }
note()  { printf '%s%s%s\n' "$D" "$1" "$R"; pause 0.6; }
run()   { printf '\n%s$ deck %s%s\n' "$C" "$*" "$R"; pause 0.5; "$DECK" "$@"; pause; }

WS="$(mktemp -d)"; PACK="$WS/pack"
[ -n "$KEEP" ] || trap 'rm -rf "$WS"' EXIT
export DECK_ROOT="$WS"
cd "$WS"

clear 2>/dev/null || true
cat <<BANNER
${B}deck${R} — the operating layer between a team and its coding agents

  An agent can write the code. What it cannot know is how your team ships it.
  This tour builds a small workspace and teaches deck about it, one piece at a
  time. Nothing outside ${WS} is touched.

BANNER
pause 2

# ---------------------------------------------------------------- a workspace
say "1 · A workspace, the way most of them look"
mkdir -p "$WS"/{services/api-schema,services/api-server,clients/web,tests/e2e}
for r in services/api-schema services/api-server clients/web tests/e2e; do
  git -C "$WS/$r" init -q
  printf '{ "name": "%s", "scripts": { "lint": "echo lint ok" } }\n' "$(basename "$r")" > "$WS/$r/package.json"
done
printf 'openapi: 3.1.0\n' > "$WS/services/api-schema/openapi.yaml"
# commit the fixtures, so a clean `git status` later means something
for r in services/api-schema services/api-server clients/web tests/e2e; do
  git -C "$WS/$r" add -A
  git -C "$WS/$r" -c user.email=tour@example -c user.name=tour commit -qm "initial" 2>/dev/null
done
mkdir -p "$WS/.repo/manifests"
cat > "$WS/.repo/manifests/default.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="acme" fetch="ssh://git@git.example/"/>
  <default remote="acme" revision="main"/>
  <project name="api-schema.git" path="services/api-schema"/>
  <project name="api-server.git" path="services/api-server"/>
  <project name="web.git"        path="clients/web"/>
  <project name="e2e.git"        path="tests/e2e"/>
</manifest>
XML
ln -s manifests/default.xml "$WS/.repo/manifest.xml"
printf '  four repositories, assembled by a repo manifest\n'
find "$WS" -maxdepth 2 -mindepth 2 -type d -not -path '*/.repo*' -not -name '.git' | sed "s|$WS|  .|"
pause 2

# --------------------------------------------------------------------- a pack
say "2 · A pack is where the team's knowledge goes"
note "  It is also a Claude Code plugin: same directory, two readers."
run pack new acme --dir "$PACK" --description "Tour pack"

cat > "$PACK/config/detect.yaml" <<'YAML'
markers: [.repo/manifest.xml]
prerequisites: [git, { name: node, required: false }]
YAML
cat > "$PACK/config/toggles.yaml" <<'YAML'
version: 1
toggles:
  - id: api_compat
    group: quality
    title: API compatibility
    summary: How far this change may alter the published contract.
    type: enum
    values: [strict, breaking]
    default: ask
    stage: [plan]
    applies_to: ["**/openapi.yaml"]
    risk: high
    rationale: >
      The schema is a contract with every client already deployed. Declaring the
      intent up front is cheaper than discovering it in staging.
    impact:
      strict: Additive only. Nothing removed, renamed or narrowed.
      breaking: Requires a migration note and a version bump.
    question:
      header: API compat
      text: May this change alter the published API contract?
      options:
        - { value: strict,   label: Additive only, description: "Clients in the field keep working." }
        - { value: breaking, label: May break,     description: "Needs a migration note and a version bump." }
YAML
cat > "$PACK/config/gates.yaml" <<'YAML'
version: 1
gates:
  - { id: lint,     title: Lint,     from_level: static, per_repo: "npm run --silent lint" }
  - { id: contract, title: Contract, from_level: build,  only_repos: [api-schema], per_repo: "test -f openapi.yaml && echo contract present" }
YAML
cat > "$PACK/config/mount.yaml" <<'YAML'
rules:
  - { file: rules/api-contract.md, repos: [api-schema] }
YAML
rm -f "$PACK/rules/example.md"
cat > "$PACK/rules/api-contract.md" <<'MD'
---
paths: ["**/openapi.yaml"]
---

# The schema is a contract

Resolve `api_compat` before changing it. Adding an optional field needs no
ceremony; renaming or narrowing one breaks clients at run time.

A schema change is not finished in this repository — `deck impact` gives the
rest of the chain, in order.
MD
export DECK_PACKS="$PACK"
note "  Four files edited: what identifies this workspace, one decision, two"
note "  gates, and one rule that loads only when a schema file is open."
pause 1.5

# ---------------------------------------------------------------- the descriptor
say "3 · deck learns the map — most of it without being told"
run init
run import repo --write
note "  Paths and remotes came from the manifest. What no importer can produce"
note '  is impacts: a manifest declares a checkout, never a propagation.'
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
edges = {"api-schema": ["api-server", "web", "e2e"], "api-server": ["e2e"], "web": ["e2e"]}
for name, targets in edges.items():
    t = re.sub(rf"(^  {re.escape(name)}:\n(?:    .*\n)*?    impacts:) \[\]$",
               lambda m, x=targets: m.group(1) + "\n" + "\n".join(f"    - {i}" for i in x), t, flags=re.M)
t = re.sub(r"(^  e2e:\n(?:    .*\n)*?    impacts: \[\]$)", r"\1\n    downstream: true", t, flags=re.M)
t = t.replace("lint: null", "").replace("repos:", "repos:", 1)
for r in ("api-schema", "api-server", "web"):
    t = re.sub(rf"(^  {r}:\n)", rf"\1    lint: npm run --silent lint\n", t, flags=re.M)
p.write_text(t)
PY
note "  Four edges written by hand, once. That is the whole investment."
run doctor

# ------------------------------------------------------------------- the graph
say "4 · Now a question nobody has to answer from memory"
run impact api-schema
note "  The order is the chain. Editing the backend before the schema produces a"
note "  build that passes and behaviour that does not exist."

# ----------------------------------------------------------------- decisions
say "5 · Decisions the team makes once, not per task"
run toggle list --stage plan
note '  The ? is not a missing value. It is a question waiting for the right moment.'
run toggle explain api_compat

say "6 · And this is how it reaches a person"
printf '\n%s$ deck toggle ask-plan --stage plan --files services/api-schema/openapi.yaml%s\n' "$C" "$R"
"$DECK" toggle ask-plan --stage plan --files services/api-schema/openapi.yaml | python3 -c '
import json, sys
plan = json.load(sys.stdin)
for q in plan["questions"]:
    print()
    print("  " + q["question"] + "   [" + q["risk"] + " risk]")
    for o in q["options"]:
        print("    {:<18} {}".format(o["label"], o["description"]))
print()
print("  The wording comes from the pack, not from whichever agent asked.")
'
pause 2
run toggle set api_compat strict --at task

# ---------------------------------------------------------------------- mount
say "7 · The agent gets the right context, and only while it needs it"
run mount --task TOUR-1 --repos api-schema --brief "Add a rate-limit field to the response envelope."
printf '\n%s$ git -C services/api-schema status --short%s\n' "$C" "$R"
git -C "$WS/services/api-schema" status --short
note "  Nothing. Mounted artifacts are excluded locally, never through .gitignore."
pause 1.5

# ---------------------------------------------------------------------- gates
say "8 · How far it was verified, and proof of it"
run gate run --task TOUR-1 --level build
run gate report --task TOUR-1

# ----------------------------------------------------------------------- cost
say "9 · What the work cost"
note "  Tokens are read from the session transcript, exact. Dollars are an"
note "  estimate at list price, and the report says so."
printf '\n%s$ deck cost --task TOUR-1%s\n' "$C" "$R"
"$DECK" cost --task TOUR-1 2>&1 | head -10
note "  In this tour no agent ran, so the window is empty — which is the honest"
note "  answer rather than a zero. Run the same command after real work and it"
note "  reports tokens per model, exact, with the cost estimate beside them."
pause 1.5

# --------------------------------------------------------------------- unmount
say "10 · And nothing is left behind"
run unmount --task TOUR-1

cat <<CLOSING

${B}That is deck.${R}

  A map, decisions, context, proof, and an account of what it cost — written
  down once by a team, executed by an agent, checkable by a reviewer.

  It spawns no agents and creates no worktrees: Claude Code already does that,
  and better. deck supplies the part an agent runtime cannot know.

  ${D}github.com/devfilipe/deck${R}

CLOSING
[ -n "$KEEP" ] && printf '  Workspace kept at %s\n\n' "$WS"
exit 0
