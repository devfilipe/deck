note "cost reporting"
FAKE_HOME="$WS/fakehome"
# The transcript has to sit in the project directory Claude Code would name for
# this workspace, because `deck cost` is scoped to the workspace — reading every
# project on the machine is how a task's bill became an unrelated session's.
SLUG="$(printf '%s' "$WS" | sed 's/[^A-Za-z0-9-]/-/g')"
mkdir -p "$FAKE_HOME/.claude/projects/$SLUG"
cat > "$FAKE_HOME/.claude/projects/$SLUG/sess-1.jsonl" <<'JSONL'
{"timestamp":"2026-01-01T10:00:00.000Z","sessionId":"sess-1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":10000,"cache_creation":{"ephemeral_5m_input_tokens":4000,"ephemeral_1h_input_tokens":0}}}}
{"timestamp":"2026-01-01T10:00:01.000Z","sessionId":"sess-1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":10000}}}
{"timestamp":"2026-01-01T12:00:00.000Z","sessionId":"sess-1","message":{"id":"m2","model":"claude-haiku-4-5","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0}}}
{"timestamp":"2026-01-01T13:00:00.000Z","sessionId":"sess-1","message":{"id":"m3","model":"model-nobody-priced","usage":{"input_tokens":10,"output_tokens":10}}}
JSONL

# A workflow's agents write under <project>/<session>/subagents/..., and those
# are real tokens on a real bill. Counting only the top level made a board run
# of eleven agents invisible.
mkdir -p "$FAKE_HOME/.claude/projects/$SLUG/sess-1/subagents/workflows/wf-x"
cat > "$FAKE_HOME/.claude/projects/$SLUG/sess-1/subagents/workflows/wf-x/agent-1.jsonl" <<'JSONL'
{"timestamp":"2026-01-01T11:00:00.000Z","sessionId":"sess-1","message":{"id":"sub1","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":13,"cache_read_input_tokens":0}}}
JSONL

costjson() { HOME="$FAKE_HOME" "$DECK" cost --session sess-1 --json "$@"; }

# The scoping itself: a transcript belonging to a different project must not be
# picked up, however recent it is.
mkdir -p "$FAKE_HOME/.claude/projects/-somewhere-else"
cp "$FAKE_HOME/.claude/projects/$SLUG/sess-1.jsonl" "$FAKE_HOME/.claude/projects/-somewhere-else/sess-9.jsonl"
out="$(HOME="$FAKE_HOME" "$DECK" cost --session sess-9 2>&1 || true)"
if printf '%s' "$out" | grep -q "no transcript named sess-9 in this workspace"; then
  ok "another project's session is out of scope"
else bad "another project's session is out of scope" "$out"; fi
# It used to say "falling back to the most recent one here", and it did fall
# back — the newest transcript in scope, billed under an id that was not its
# own. It no longer falls back, so the line no longer says it does.
if printf '%s' "$out" | grep -q "falling back"; then
  bad "and does not announce a fallback it no longer makes" "$out"
else ok "and does not announce a fallback it no longer makes"; fi
if HOME="$FAKE_HOME" "$DECK" cost --session sess-9 --any-project --json >/dev/null 2>&1; then
  ok "--any-project widens it deliberately"
else bad "--any-project widens it deliberately"; fi

if HOME="$FAKE_HOME" "$DECK" cost --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["output"]>=13 else 1)'; then
  ok "a workflow agent's tokens are counted"
else bad "a workflow agent's tokens are counted"; fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["messages"]==3 else 1)'; then
  ok "a streamed message is counted once"
else
  bad "a streamed message is counted once" "$(costjson | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')"
fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["output"]==2110 else 1)'; then
  ok "output tokens add up across models"
else
  bad "output tokens add up across models"
fi
# opus-5: 1000*5 + 2000*25 + 4000*5*1.25 + 10000*5*0.1 = 85000 / 1e6 = 0.085
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if abs(d["models"]["claude-opus-5"]["usd"]-0.085)<1e-6 else 1)'; then
  ok "cache write and read are priced by their multipliers"
else
  bad "cache write and read are priced by their multipliers"
fi
if costjson | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["models"]["model-nobody-priced"]["usd"] is None and d["total"]["priced"] is False else 1)'; then
  ok "an unpriced model is reported, not guessed at"
else
  bad "an unpriced model is reported, not guessed at"
fi
if costjson --since 2026-01-01T11:00:00Z | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["total"]["messages"]==2 else 1)'; then
  ok "a window excludes what falls outside it"
else
  bad "a window excludes what falls outside it"
fi
check "dollars are labelled an estimate" "ESTIMATE" env HOME="$FAKE_HOME" "$DECK" cost --session sess-1
if costjson --since 2026-01-01T11:00:00 | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "+" in d["window"] or "-0" in d["window"] else 1)'; then
  ok "a zoneless timestamp is echoed with the zone it was read as"
else
  bad "a zoneless timestamp is echoed with the zone it was read as"
fi
check_fail "an unreadable timestamp is refused" env HOME="$FAKE_HOME" "$DECK" cost --session sess-1 --since nonsense
if HOME="$FAKE_HOME" "$DECK" cost --task NOPE >/dev/null 2>&1; then
  bad "a task with no window is refused"
else
  ok "a task with no window is refused"
fi
