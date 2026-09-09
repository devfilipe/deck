# ---------------------------------------------------- the documents gate
note "the documents gate"
# On a tree of its own, so the checks can state a wrong total and name a
# command that was never there without editing this repository's documents.
DC="$(mktemp -d)"
mkdir -p "$DC/plugins/deck/bin" "$DC/ci"
COVER="$DC/ci/docs-cover.py"
cp "$REPO/ci/docs-cover.py" "$COVER"
cat > "$DC/plugins/deck/bin/deck" <<'SH'
#!/usr/bin/env bash
printf 'usage: deck [-h] {alpha,beta} ...\n'
SH
cat > "$DC/ci/smoke.sh" <<'SH'
#!/usr/bin/env bash
# Leaves a mark, so a check can prove the count check did not run it, and
# reports a total no document here states, so a run that reached this script
# is a run that fails.
: > "$(dirname "$0")/../suite-ran"
printf '999 checks, 0 failures\n'
SH
chmod +x "$DC/plugins/deck/bin/deck" "$DC/ci/smoke.sh"
printf 'ran the suite\n\033[32m41 checks, 0 failures\033[0m\n' > "$DC/suite.log"
cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it and `deck beta` stops it. The suite has 41 checks.
MD

cover="$(python3 "$COVER" --counts --suite-log "$DC/suite.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -eq 0 ] && printf '%s' "$cover" | grep -q "every command is named"; then
  ok "documents that match the code pass"
else bad "documents that match the code pass" "exit $cover_rc: $cover"; fi

# The total used to be stated in four documents. Every change that added a
# check edited four that had nothing to do with it, and two branches that both
# added one conflicted on four lines whose resolution was neither side's number
# but the sum — between two unrelated fixes, in one day. One document holds it
# now, and the gate refuses a second copy rather than trusting anybody to
# remember. Enforced only where there IS a CONTRIBUTING.md: a tree that has not
# chosen a home has not broken a rule it never had, which is why the fixture
# above still passes without one.
cat > "$DC/CONTRIBUTING.md" <<'MD'
# Contributing

The suite has 41 checks.
MD
printf '\nAnd a second copy: the suite has 41 checks.\n' >> "$DC/README.md"
second="$(python3 "$COVER" --counts --suite-log "$DC/suite.log" 2>&1)"; second_rc=$?
if [ $second_rc -ne 0 ] && printf '%s' "$second" | grep -q "as well as CONTRIBUTING.md"; then
  ok "a check total stated in a second document is refused, naming both"
else bad "a check total stated in a second document is refused, naming both" "exit $second_rc: $second"; fi
cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it and `deck beta` stops it. The suite has 41 checks.
MD
rm -f "$DC/CONTRIBUTING.md"
# The point of --suite-log, and the acceptance criterion behind it: the total
# comes off a run that already happened, so a push runs the suite once.
if [ -f "$DC/suite-ran" ]; then
  bad "and the suite is not run a second time to learn its own total" "ci/smoke.sh was called anyway"
else ok "and the suite is not run a second time to learn its own total"; fi

printf '\n`deck gamma` retires it.\n' >> "$DC/README.md"
cover="$(python3 "$COVER" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "deck gamma"; then
  ok "a document offering a command the CLI does not have fails, and names it"
else bad "a document offering a command the CLI does not have fails, and names it" "exit $cover_rc: $cover"; fi

cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it. The suite has 41 checks.
MD
cover="$(python3 "$COVER" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "deck beta"; then
  ok "a command the documents never name still fails, and names it"
else bad "a command the documents never name still fails, and names it" "exit $cover_rc: $cover"; fi

cat > "$DC/README.md" <<'MD'
# A documented tool

`deck alpha` starts it and `deck beta` stops it. The suite has 41 checks.
MD
printf '\033[32m7 checks, 0 failures\033[0m\n' > "$DC/stale.log"
cover="$(python3 "$COVER" --counts --suite-log "$DC/stale.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "say 41 checks; the suite has 7"; then
  ok "a stated total the suite does not have fails, and names both numbers"
else bad "a stated total the suite does not have fails, and names both numbers" "exit $cover_rc: $cover"; fi

cover="$(python3 "$COVER" --counts --suite-log "$DC/absent.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "no suite log at"; then
  ok "a suite log that is not there is an error, not a total nobody checked"
else bad "a suite log that is not there is an error, not a total nobody checked" "exit $cover_rc: $cover"; fi

: > "$DC/empty.log"
cover="$(python3 "$COVER" --counts --suite-log "$DC/empty.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "could not read the suite's own total"; then
  ok "a log with no total in it is an error too"
else bad "a log with no total in it is an error too" "exit $cover_rc: $cover"; fi

# A flag the workflow mistypes has to stop the run. Ignored, it would drop the
# count check back to running the suite itself — the cost this change removes,
# reintroduced silently.
cover="$(python3 "$COVER" --counts --suite-logg "$DC/suite.log" 2>&1)"; cover_rc=$?
if [ $cover_rc -ne 0 ] && printf '%s' "$cover" | grep -q "unrecognized arguments"; then
  ok "a mistyped flag is refused rather than ignored"
else bad "a mistyped flag is refused rather than ignored" "exit $cover_rc: $cover"; fi
rm -rf "$DC"
