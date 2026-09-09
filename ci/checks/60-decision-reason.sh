# ------------------------------------------------ the reason behind a decision
# The bundle is the one surface written for somebody who was not there. It
# carried the value and the layer from the start and not the sentence explaining
# the choice, so it said a task ran at `gate_level: build` and never why anyone
# chose that — while the sentence was on disk the whole time.
note "a decision's reason, in the bundle"

"$DECK" toggle set gate_level build --at workspace \
  --why "delivery goes through a firmware update path nobody has wired to deck yet" >/dev/null
"$DECK" toggle set test_depth smoke --at workspace >/dev/null
"$DECK" toggle set api_compat breaking --at task \
  --why "the field being removed has no consumer left in the registry" >/dev/null

decided="$("$DECK" bundle --task T-1 2>&1 | sed -n '/what was decided/,/^$/p' || true)"
if printf '%s' "$decided" | grep -q "why  delivery goes through a firmware update path"; then
  ok "a decision in the bundle carries the reason its chooser recorded"
else
  bad "a decision in the bundle carries the reason its chooser recorded" "$decided"
fi
owned="$(printf '%s' "$decided" | grep -A1 "this task's to decide" || true)"
if printf '%s' "$owned" | grep -q "no consumer left in the registry"; then
  ok "and so does the decision the task existed to take"
else
  bad "and so does the decision the task existed to take" "$decided"
fi
bare="$(printf '%s' "$decided" | grep -A1 "test_depth" || true)"
if printf '%s' "$bare" | grep -q "not recorded"; then
  ok "a decision with none says so rather than looking justified"
else
  bad "a decision with none says so rather than looking justified" "$decided"
fi
if printf '%s' "$bare" | grep -q 'record it with: deck toggle set test_depth smoke --at workspace --why'; then
  ok "and names the command that would record one"
else
  bad "and names the command that would record one" "$bare"
fi

# An environment variable belongs to one command, so there is no file to record
# a reason in and no command to suggest. Saying "not recorded" here would read
# as an omission somebody could fix.
env_decided="$(DECK_UNIT_TESTS=required "$DECK" bundle --task T-1 2>&1 | sed -n '/what was decided/,/^$/p' || true)"
from_env="$(printf '%s' "$env_decided" | grep -A1 "unit_tests" || true)"
if printf '%s' "$from_env" | grep -q "is not a layer a reason can be written at"; then
  ok "a value from the environment says why no reason exists for it"
else
  bad "a value from the environment says why no reason exists for it" "$env_decided"
fi
# A guard, not a new behaviour: the old bundle printed no reason line at all, so
# this passed before the change too. It is here because the fix could only go
# wrong one way — by offering `--why` for a layer that cannot hold one.
if printf '%s' "$from_env" | grep -q "record it with"; then
  bad "a reason is never invited where none can be recorded" "$from_env"
else
  ok "a reason is never invited where none can be recorded"
fi

"$DECK" bundle --task T-1 --write >/dev/null 2>&1 || true
md_row="$(grep '^| `gate_level`' "$WS/.deck/bundles/T-1.md" || true)"
if printf '%s' "$md_row" | grep -q "firmware update path"; then
  ok "the markdown a reviewer reads carries it in a column of its own"
else
  bad "the markdown a reviewer reads carries it in a column of its own" "$md_row"
fi
# A reason is a sentence somebody typed. An unescaped pipe in it splits the row
# and shifts every column after it, so the reviewer reads a table that is wrong.
"$DECK" toggle set test_depth full --at workspace \
  --why "unit alone | nothing here runs integration" >/dev/null
"$DECK" bundle --task T-1 --write >/dev/null 2>&1 || true
md_row="$(grep '^| `test_depth`' "$WS/.deck/bundles/T-1.md" || true)"
if printf '%s' "$md_row" | grep -qF '\|'; then
  ok "a pipe inside a reason is escaped rather than splitting the row"
else
  bad "a pipe inside a reason is escaped rather than splitting the row" "$md_row"
fi

bundle_json="$("$DECK" bundle --task T-1 --json 2>&1 || true)"
if printf '%s' "$bundle_json" | python3 -c 'import json,sys
rows = {d["id"]: d for d in json.load(sys.stdin)["decisions"]["recorded"]}
sys.exit(0 if "firmware update path" in (rows["gate_level"]["reason"] or "") else 1)' 2>/dev/null; then
  ok "the JSON carries the reason, so a consumer need not re-read the toggle file"
else
  bad "the JSON carries the reason, so a consumer need not re-read the toggle file" \
    "$(printf '%s' "$bundle_json" | head -3)"
fi
"$DECK" toggle set test_depth smoke --at workspace >/dev/null
bundle_json="$("$DECK" bundle --task T-1 --json 2>&1 || true)"
if printf '%s' "$bundle_json" | python3 -c 'import json,sys
rows = {d["id"]: d for d in json.load(sys.stdin)["decisions"]["recorded"]}
row = rows["test_depth"]
sys.exit(0 if row["reason"] is None and "not recorded" in (row["why_missing"] or "") else 1)' 2>/dev/null; then
  ok "and a decision with none is null there, with a field saying which nothing it is"
else
  bad "and a decision with none is null there, with a field saying which nothing it is" \
    "$(printf '%s' "$bundle_json" | head -3)"
fi
