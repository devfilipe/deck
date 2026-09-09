# ------------------------------------------ one suite, one file per subject
# The shape the suite has to keep (#13): one command with no arguments, one
# total — and no single file that every task has to edit whatever it changed.
note "the suite is one command over many files"

SL="$(mktemp -d)"
sl_runner="$REPO/ci/smoke.sh"
sl_files="$(find "$REPO/ci/checks" -maxdepth 1 -name '*.sh' | sort)"
sl_count="$(printf '%s\n' "$sl_files" | grep -c . || true)"

# The file a contributor runs is the file nobody has to edit to add a check.
sl_groups_in_runner="$(grep -c '^note "' "$sl_runner" || true)"
sl_checks_in_runner="$(grep -cE '^\s*(check|check_fail)\s' "$sl_runner" || true)"
if [ "$sl_groups_in_runner" -eq 0 ] && [ "$sl_checks_in_runner" -eq 0 ]; then
  ok "a behaviour change never edits the one file everybody runs"
else
  bad "a behaviour change never edits the one file everybody runs" \
    "ci/smoke.sh holds $sl_groups_in_runner group(s) and $sl_checks_in_runner check call(s)"
fi

# More than one, and none of them dead: a file the runner sources that asserts
# nothing is a subject somebody emptied and nobody removed.
sl_empty=""
for sl_f in $sl_files; do
  [ "$(grep -c '^note "' "$sl_f" || true)" -gt 0 ] || sl_empty="$sl_empty $(basename "$sl_f")"
done
if [ "$sl_count" -gt 1 ] && [ -z "$sl_empty" ]; then
  ok "the groups are spread over files of their own, each of them carrying some"
else
  bad "the groups are spread over files of their own, each of them carrying some" \
    "$sl_count file(s); holding no group:${sl_empty:- none}"
fi

# Defined once. Copying `check` per file is how two of them start disagreeing
# about what a check is, and the total stops meaning one thing.
sl_redefined=""
for sl_f in $sl_files; do
  if grep -qE '^(ok|bad|skip|note|check|check_fail)\(\)' "$sl_f" || grep -qE '^(WS|PACKS|PACK|pass|fail|skipped)=' "$sl_f"; then
    sl_redefined="$sl_redefined $(basename "$sl_f")"
  fi
done
if [ -z "$sl_redefined" ]; then
  ok "and the helpers and the synthetic workspace are stated once, by the runner"
else
  bad "and the helpers and the synthetic workspace are stated once, by the runner" \
    "restated in:$sl_redefined"
fi

# ---- the runner, exercised: a tree holding two subjects and nothing else.
# A real run, because the claim is about what happens when someone adds a file,
# not about what the runner's source says it will do.
mkdir -p "$SL/ci/checks"
cp "$sl_runner" "$SL/ci/smoke.sh"
ln -s "$REPO/plugins" "$SL/plugins"
printf 'note "alpha"\nok "alpha ran"\n'         > "$SL/ci/checks/10-alpha.sh"
printf 'note "beta"\nok "beta ran"\n'           > "$SL/ci/checks/20-beta.sh"
# Only when the runner is a runner. A script still holding the groups holds
# this one too, so running the copy would run this check inside itself, and
# each copy would make another — bounded by nothing. Say what is wrong instead.
if [ "$sl_groups_in_runner" -eq 0 ]; then
  sl_out="$(timeout 60 bash "$SL/ci/smoke.sh" 2>&1 || true)"
else
  sl_out="ci/smoke.sh still holds $sl_groups_in_runner group(s) of its own; not run"
fi
sl_clean="$(printf '%s' "$sl_out" | sed 's/\x1b\[[0-9;]*m//g')"
if printf '%s' "$sl_clean" | grep -q "alpha ran" && printf '%s' "$sl_clean" | grep -q "beta ran"; then
  ok "a subject dropped into the directory runs, with no list anywhere to add it to"
else
  bad "a subject dropped into the directory runs, with no list anywhere to add it to" "$sl_clean"
fi
sl_totals="$(printf '%s\n' "$sl_clean" | grep -cE '[0-9]+ checks' || true)"
sl_total="$(printf '%s\n' "$sl_clean" | grep -oE '[0-9]+ checks' | head -1)"
if [ "$sl_totals" -eq 1 ] && [ "$sl_total" = "2 checks" ]; then
  ok "and one command with no arguments still answers with one total over all of them"
else
  bad "and one command with no arguments still answers with one total over all of them" \
    "$sl_totals total line(s), first: ${sl_total:-none}"
fi
rm -rf "$SL"

# ------------------------------- the suite does not read the machine it runs on
# Isolation has to come before the first check, not after it. It used to sit
# below, under the synthetic workspace it was written for, which left
# `catalog is consistent` above the guard reading the real ~/.deck — and it
# failed only on a machine carrying a stale selection, most sharply when several
# checkouts ran the suite at once and one deleted the temporary root another's
# selection still named. Three consecutive runs of the same tree failed three
# different checks. A result that depends on who is running it, and on what else
# is running, is the worst shape a failure can take.
#
# The split makes the order structural rather than careful, and this is what
# pins it there: the runner sets it, and it sets it before it sources anything.
_iso=$(grep -n '^export DECK_HOME_STATE=' "$REPO/ci/smoke.sh" | head -1 | cut -d: -f1)
_src=$(grep -n 'ci/checks/\*\.sh' "$REPO/ci/smoke.sh" | head -1 | cut -d: -f1)
if [ -n "$_iso" ] && [ -n "$_src" ] && [ "$_iso" -lt "$_src" ]; then
  ok "machine state is isolated by the runner, before it sources a single check"
else
  bad "machine state is isolated by the runner, before it sources a single check" \
    "export at line ${_iso:-none}, checks sourced at line ${_src:-none}"
fi
case "${DECK_HOME_STATE:-}" in
  "" | "$HOME"/*)
    bad "and what it points at is nobody's real home" "DECK_HOME_STATE=${DECK_HOME_STATE:-<unset>}" ;;
  *) ok "and what it points at is nobody's real home" ;;
esac
