# ------------------------------------------------------------------ manifests
note "manifests"
if command -v claude >/dev/null; then
  check "marketplace valid" "Validation passed" claude plugin validate "$REPO" --strict
  check "plugin valid"      "Validation passed" claude plugin validate "$REPO/plugins/deck" --strict
else
  skip "marketplace valid — claude not on PATH"
  skip "plugin valid — claude not on PATH"
fi

note "core catalog"
# The core catalog, and nothing a workspace layers over it — which is what this
# group means and what it used to get for free, running before any root was
# resolved. The synthetic workspace is built before this file is sourced now,
# so the absence has to be asked for.
check "catalog is consistent" "OK —" env -u DECK_ROOT "$DECK" toggle validate --strict
