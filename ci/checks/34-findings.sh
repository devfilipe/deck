# arrives anyway, so `apply` is handed hand-written JSON — no model involved.
note "a drafted finding is a decision or a question"
check "the prompt separates a toggle from a question" "A toggle and a question are not the same finding" \
  "$DECK" propose pack a --show-prompt
check "and says a toggle owes every value a defence" "for EVERY value in \`values\`" \
  "$DECK" propose pack a --show-prompt
check "and sends what it cannot explain to a question" "put it in \`questions\`" \
  "$DECK" propose pack a --show-prompt
check "and keeps \`unsure\` for the limits of its own reading" "limits of your own reading" \
  "$DECK" propose pack a --show-prompt

DP="$WS/draftpack"
"$DECK" pack new drafted --dir "$DP" >/dev/null
mkdir -p "$WS/.deck/proposals"

# A toggle whose values are bare names: two answers, no reason for either.
cat > "$WS/.deck/proposals/pack-bare.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"drafted_lint","title":"Lint","from_level":"static","command":"ruff check .","evidence":"ci.yml","confidence":"high"}],
"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],"rationale":"r","confidence":"high"}],
"questions":[],"unsure":[]}}
JSON
bare="$("$DECK" propose apply pack-bare.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$bare" | grep -q "REFUSED"; then
  ok "a toggle that defends neither value is refused"
else
  bad "a toggle that defends neither value is refused" "$bare"
fi
if printf '%s' "$bare" | grep -q "not one of its values is defended"; then
  ok "and the refusal names what is missing"
else
  bad "and the refusal names what is missing" "$bare"
fi
if grep -q "drafted_lint" "$DP/config/gates.yaml"; then
  bad "a refused draft writes nothing at all" "the gate landed anyway"
else
  ok "a refused draft writes nothing at all"
fi

# Half-defended is still not a decision: `409` has no reason to exist.
cat > "$WS/.deck/proposals/pack-half.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],
  "defends":{"400":"the caller sent something it could have got right"},"rationale":"r","confidence":"high"}],
"questions":[],"unsure":[]}}
JSON
half="$("$DECK" propose apply pack-half.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$half" | grep -q "does not say what defends .409."; then
  ok "a toggle that defends one value of two is refused, by name"
else
  bad "a toggle that defends one value of two is refused, by name" "$half"
fi

# Both values defended, and the same finding ALSO written down as something the
# draft could not explain. That is the draft having it both ways.
cat > "$WS/.deck/proposals/pack-mixed.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[],"rules":[],
"toggles":[{"id":"refusal_status_code","title":"Refusal status code","summary":"s","values":["400","409"],
  "defends":{"400":"the caller sent something wrong","409":"the resource is in the wrong state"},
  "rationale":"r","confidence":"high"}],
"questions":[],
"unsure":["I could not tell whether the refusal status code split across the two handlers was intentional or drift."]}}
JSON
mixed="$("$DECK" propose apply pack-mixed.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$mixed" | grep -q "also filed as something the draft could not explain"; then
  ok "a finding filed as both a decision and a doubt is refused"
else
  bad "a finding filed as both a decision and a doubt is refused" "$mixed"
fi

# The shape the drafter should have produced: the choice it can defend is a
# toggle, the inconsistency it cannot is a question.
cat > "$WS/.deck/proposals/pack-sorted.json" <<'JSON'
{"kind":"pack","at":"2026-09-05T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"drafted_lint","title":"Lint","from_level":"static","command":"ruff check .","evidence":"ci.yml","confidence":"high"}],
"rules":[],
"toggles":[{"id":"schema_compat","title":"Schema compatibility","summary":"s","values":["strict","breaking"],
  "defends":{"strict":"clients already deployed keep working across a release","breaking":"the contract gets fixed instead of carried forever"},
  "rationale":"r","confidence":"high"}],
"questions":[{"question":"Do the token path and the quota path refuse with the same status on purpose?",
  "context":"auth.py answers 403 and quota.py answers 429 for the same class of refusal.",
  "evidence":"src/auth.py:88, src/quota.py:41",
  "options":["make both 403","make both 429","they are deliberately different"]}],
"unsure":["b is empty"]}}
JSON
sorted_out="$("$DECK" propose apply pack-sorted.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$sorted_out" | grep -q "consultation "; then
  ok "an inconsistency the draft cannot explain becomes a consultation"
else
  bad "an inconsistency the draft cannot explain becomes a consultation" "$sorted_out"
fi
asked="$("$DECK" ask list 2>&1 || true)"
if printf '%s' "$asked" | grep -q "same status on purpose"; then
  ok "and it is open, waiting on a person"
else
  bad "and it is open, waiting on a person" "$asked"
fi
QID="$(printf '%s' "$asked" | grep -B1 "same status on purpose" | grep -oE '[0-9]{8}-[0-9]{6}-[a-z0-9-]+' | head -1)"
shown="$("$DECK" ask show "$QID" 2>&1 || true)"
if printf '%s' "$shown" | grep -q "src/auth.py:88"; then
  ok "and carries the files that disagree, so it can be answered"
else
  bad "and carries the files that disagree, so it can be answered" "$shown"
fi
# A regression guard, and it passes without the change too: a draft that sorts
# its findings correctly must go on applying exactly as it did.
if grep -q "drafted_lint" "$DP/config/gates.yaml"; then
  ok "a draft that sorts its findings still lands its gates"
else
  bad "a draft that sorts its findings still lands its gates"
fi
# Applying the same draft into a second pack must not ask the question twice —
# a consultation nobody answers twice as fast is just noise.
"$DECK" pack new drafted2 --dir "$WS/draftpack2" >/dev/null
"$DECK" propose apply pack-sorted.json --into "$WS/draftpack2" --confidence high >/dev/null 2>&1
count="$("$DECK" ask list --all 2>&1 | grep -c "same status on purpose" || true)"
if [ "$count" = "1" ]; then
  ok "and applying the draft again does not ask it twice"
else
  bad "and applying the draft again does not ask it twice" "asked $count time(s)"
fi
# A draft written before any of this: no `questions` key, no `defends`. It has
# nothing to sort wrongly, so it applies as it always did. Regression guard.
cat > "$WS/.deck/proposals/pack-older.json" <<'JSON'
{"kind":"pack","at":"2026-01-01T00:00:00","cost":{},"prompt":"x","proposal":{"repo":"a",
"gates":[{"id":"older_types","title":"Types","from_level":"static","command":"mypy .","evidence":"tox.ini","confidence":"high"}],
"rules":[],"toggles":[],"unsure":["nothing"]}}
JSON
older="$("$DECK" propose apply pack-older.json --into "$DP" --confidence high 2>&1 || true)"
if printf '%s' "$older" | grep -q "older_types" || grep -q "older_types" "$DP/config/gates.yaml"; then
  ok "a draft predating the questions list still applies"
else
  bad "a draft predating the questions list still applies" "$older"
fi
