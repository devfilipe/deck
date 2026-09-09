#!/usr/bin/env bash
# Smoke test for deck. Builds a synthetic workspace and an example pack in a
# temporary directory, so it runs anywhere and touches nothing you own.
#
#   ./ci/smoke.sh        run everything
#   ./ci/smoke.sh -v     show each command's output
#
# What it asserts is in ci/checks/, one file per subject. This file holds what
# they all share: the counters, the helpers, the workspace and the total.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECK="$REPO/plugins/deck/bin/deck"
VERBOSE="${1:-}"

pass=0
fail=0
skipped=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
# A check that could not run here still exists. Counting it keeps the total the
# same on every machine, which is what lets the documents state one number —
# and it puts the skip in the summary rather than one yellow line in six
# hundred, where nobody was going to find it.
skip() { printf '  \033[33m..\033[0m   %s\n' "$1"; skipped=$((skipped + 1)); }
note() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <description> <expected substring> <command…>
check() {
  local desc="$1" expect="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [ -n "$VERBOSE" ] && printf '       $ %s\n%s\n' "$*" "$out"
  if [ $rc -ne 0 ]; then
    bad "$desc" "exit $rc: $(printf '%s' "$out" | tail -1)"
  elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
    bad "$desc" "expected '$expect', got: $(printf '%s' "$out" | tail -1)"
  else
    ok "$desc"
  fi
}

check_fail() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [ -n "$VERBOSE" ] && printf '       $ %s\n%s\n' "$*" "$out"
  if [ $rc -eq 0 ]; then bad "$desc" "should have failed"; else ok "$desc"; fi
}

# -------------------------------------------------------- synthetic workspace
# Isolated, always. Without it this suite reads the state of whoever runs it —
# a selection they made in their own workspace pointed every synthetic one at
# it, and 359 checks failed on their machine and none on a clean one.
export DECK_HOME_STATE="$(mktemp -d)/home"
WS="$(mktemp -d)"
PACKS="$(mktemp -d)/collection"
# The base layer of a collection: every workspace, every scope. Most of the
# suite wants exactly that, so most of the suite needs no other pack.
PACK="$PACKS/_workspaces/all/default"
# INT and TERM as well as EXIT: bash runs no EXIT trap for a signal it was not
# told about, and the tracker stand-in below serves until something kills it.
# A Ctrl-C already left the workspace behind; it would now leave a listening
# process behind with it.
cleanup() { kill ${FAKE:-} ${FAKE2:-} 2>/dev/null; rm -rf "$WS" "$PACKS"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
mkdir -p "$WS"/{a,b,c} "$WS/.deck" "$PACK/config" "$PACK/templates/workspace"
for d in a b c; do git -C "$WS/$d" init -q 2>/dev/null; done
: > "$WS/.example-root"

cat > "$WS/.deck/workspace.yaml" <<YAML
version: 1
requires: []
repos:
  a: { path: a, role: schema,  build_target: pkg-a, impacts: [b] }
  b: { path: b, role: server,  build_target: pkg-b, impacts: [c] }
  c: { path: c, role: e2e,     downstream: true, impacts: [] }
targets:
  - { host: 10.0.0.4, role: primary, alias: lab-1 }
YAML
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$WS/.deck/toggles.yaml"

cat > "$PACK/config/detect.yaml" <<'YAML'
markers: [".example-root"]
prerequisites: [git, {name: definitely-not-installed, required: false}]
YAML
cat > "$PACK/config/toggles.yaml" <<'YAML'
toggles:
  - id: api_compat
    group: quality
    title: API compatibility
    summary: How far this change may alter the published contract.
    type: enum
    values: [strict, breaking]
    default: strict
    stage: [plan]
    risk: high
    impact: { strict: Additive only., breaking: Needs a migration note. }
    question:
      header: API compat
      text: May this change alter the published contract?
      options:
        - { value: strict,   label: Additive only,  description: Nothing removed or renamed. }
        - { value: breaking, label: May break,      description: Needs a migration note. }
  - id: deploy_mode
    overrides: true
    values: [none, fast, packaged]
    question:
      options:
        - { value: fast,     label: Sync to the pod, description: Seconds; diverges from the image. }
        - { value: packaged, label: Install package, description: Real packaging. }
        - { value: none,     label: Do not deploy,   description: Stop at the build. }
YAML

export DECK_ROOT="$WS"

# ------------------------------------------------------------------ the checks
# One command to run, one file per subject to edit. Everything above is shared —
# the counters, `check`, the synthetic workspace — and everything that asserts
# anything is in `ci/checks/`, sourced into THIS shell so each group still sees
# the fixture and whatever the group before it left behind.
#
# It was one script, and the house rule is that every behaviour change adds a
# check to it. So every task edited it, whatever the task had changed, and two
# tasks in different modules collided there and nowhere else (#13).
#
# Sourced in filename order, and the numeric prefix is what states that order:
# the fixture above is built once and then added to as the suite runs, so a
# group that moved would read a workspace in a state nobody wrote it against.
# Two digits, stepping by two, so a new subject can be put between two existing
# ones without renaming either.
for part in "$REPO"/ci/checks/*.sh; do
  # A directory with nothing in it would otherwise source the literal pattern,
  # and the suite would die on a syntax error rather than report zero checks.
  [ -f "$part" ] || continue
  . "$part"
done

# --------------------------------------------------------------------- summary
printf '\n%s\n' "-----------------------------------------------"
total=$((pass + fail + skipped))
# The skipped ones are in the total on purpose: the suite is the same size
# wherever it runs, so a machine missing a tool reports the same number as one
# that has everything, and says what it could not run.
[ $skipped -gt 0 ] && note_skipped=" ($skipped skipped)" || note_skipped=""
if [ $fail -eq 0 ]; then
  printf '\033[32m%d checks, 0 failures%s\033[0m\n' "$total" "$note_skipped"
  exit 0
fi
printf '\033[31m%d failure(s) in %d checks%s\033[0m\n' "$fail" "$total" "$note_skipped"
exit 1
