note "headless proposals"
# A stand-in for `claude`, so the plumbing is covered without spending money
# or needing credentials in CI.
FAKEBIN="$WS/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *"propagation graph"*) KIND=impacts;; *"decision catalog"*) KIND=toggle;; esac; done
if [ "${KIND:-}" = "impacts" ]; then
  RESULT='{"edges":[{"from":"a","to":"c","why":"c asserts against a fixture a owns","confidence":"high"},{"from":"c","to":"a","why":"weak, and would close a cycle","confidence":"medium"}],"unsure":["b is empty"]}'
else
  RESULT='{"id":"x","title":"T","summary":"S","values":["on","off"],"default":"on","rationale":"R","impact":{"on":"o"},"question":{"header":"H","text":"Q?","options":[{"value":"on","label":"Yes","description":"d"}]}}'
fi
# Two `tool_use` events ahead of the result — a stand-in for what
# `--output-format stream-json` actually sends while the real call is still
# running, so the plumbing that reads them is covered without spending money.
# The same file twice, so the reader sees a repeat read counted rather than
# printed as two lines.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"a/model.py"}}]}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"a/model.py"}}]}}\n'
printf '{"type":"result","subtype":"success","is_error":false,"result":%s,"total_cost_usd":0.0123,"session_id":"fake","usage":{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":9},"permission_denials":[]}\n' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$RESULT")"
SH
chmod +x "$FAKEBIN/claude"

check "show-prompt costs nothing and needs no permission" "propagation graph" "$DECK" propose impacts --show-prompt
refused="$("$DECK" propose impacts 2>&1 || true)"
if printf '%s' "$refused" | grep -q "Re-run with --yes"; then
  ok "a proposal run without permission is refused"
else
  bad "a proposal run without permission is refused" "$refused"
fi
out="$(PATH="$FAKEBIN:$PATH" "$DECK" propose impacts --yes 2>&1 || true)"
if printf '%s' "$out" | grep -q "a -> c"; then ok "an edge is proposed with its evidence"; else bad "an edge is proposed" "$out"; fi
if printf '%s' "$out" | grep -q '\$0.0123'; then ok "the call reports what it cost"; else bad "the call reports what it cost"; fi
if printf '%s' "$out" | grep -q "Nothing was written to the descriptor"; then
  ok "a proposal never edits the descriptor"
else
  bad "a proposal never edits the descriptor"
fi
PROP="$(ls "$WS/.deck/proposals" | head -1)"
if [ -n "$PROP" ]; then ok "the proposal is saved for review"; else bad "the proposal is saved for review"; fi
# The drafter found `a -> c` and `c -> a`, which is what a drafter with only
# `impacts:` does when both directions have evidence. Two edges there is a
# cycle, so `apply` drafts it as the coupling it is. Without --yes, so the
# descriptor this file goes on using is untouched.
both="$("$DECK" propose apply "$PROP" 2>&1 || true)"
if printf '%s' "$both" | grep -q "a <-> c"; then
  ok "a pair the drafter found both ways is drafted as a coupling"
else
  bad "a pair the drafter found both ways is drafted as a coupling" "$both"
fi
if printf '%s' "$both" | grep -q "carries no order"; then
  ok "and the draft says the coupling carries no order"
else
  bad "and the draft says the coupling carries no order" "$both"
fi
if printf '%s' "$both" | grep -q "REFUSED"; then
  bad "and it is not refused as a cycle" "$both"
else
  ok "and it is not refused as a cycle"
fi
check "apply without --yes writes nothing" "Nothing written" "$DECK" propose apply "$PROP" --confidence high
"$DECK" propose apply "$PROP" --confidence high --yes >/dev/null 2>&1
if "$DECK" impact a --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["order"][-1]=="c" else 1)'; then
  ok "a reviewed edge reaches the graph"
else
  bad "a reviewed edge reaches the graph"
fi
# `--max-budget-usd` bounds the tool-use loop, not the total charge: the call
# already running when it trips still finishes and bills, so a reader who
# sees a spend above the number just announced should not conclude the cap
# failed. The announcement (captured in $out above) must say what the cap
# governs and hedge the number, not promise an exact ceiling it cannot keep.
# -F, and not an escaped `$`: inside double quotes bash turns `\$` into `$`,
# and a bare `$` in a basic regex is end-of-line — so the pattern anchored
# instead of matching the dollar sign it was about.
if printf '%s' "$out" | grep -qF 'loop capped at about $'; then
  ok "the announcement says what the cap governs, not just its number"
else
  bad "the announcement says what the cap governs, not just its number" "$out"
fi

# A tripped cap is reported by the wrapped tool as an error result, not a
# nonzero exit from it — so the stand-in mimics that shape: is_error true,
# a subtype naming the budget, and a cost already past what was asked for,
# the same shape as the issue's real run ($1.5 asked, $1.6879 spent).
FAKEBIN2="$WS/bin-budget"; mkdir -p "$FAKEBIN2"
cat > "$FAKEBIN2/claude" <<'SH'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"error_max_budget","is_error":true,"total_cost_usd":1.6879,"session_id":"fake","usage":{},"permission_denials":[]}\n'
SH
chmod +x "$FAKEBIN2/claude"

check_fail "a tripped budget cap still fails the command" \
  env PATH="$FAKEBIN2:$PATH" "$DECK" propose impacts --yes --budget 1.5
capout="$(env PATH="$FAKEBIN2:$PATH" "$DECK" propose impacts --yes --budget 1.5 2>&1 || true)"
if printf '%s' "$capout" | grep -qF '$1.6879'; then
  ok "the failure still reports what was actually spent"
else
  bad "the failure still reports what was actually spent" "$capout"
fi
if printf '%s' "$capout" | grep -q "loop" && printf '%s' "$capout" | grep -q "already"; then
  ok "the failure explains the overshoot as a call already committed, not the cap failing"
else
  bad "the failure explains the overshoot as a call already committed, not the cap failing" "$capout"
fi


# #21 — a proposal runs for minutes with nothing to watch, and what it spent is
# not attributable to anything more specific than the whole run. Read line by
# line through `--output-format stream-json`, so a read or a search reaches
# `on_event` as it happens rather than after the whole reply is in.
if printf '%s' "$out" | grep -qF "read: a/model.py x2"; then
  ok "what was read is reported, and a repeat read is counted rather than printed twice"
else
  bad "what was read is reported, and a repeat read is counted rather than printed twice" "$out"
fi
# Captured by `$( … )`, exactly like every other check in this suite: stdout is
# not a terminal here, and a live progress line printed into a log nobody is
# tailing would be noise, not the legible wait #21 asked for. This is the
# behaviour that matters, not the wording — a build running in CI must stay
# exactly as quiet as it always was.
if printf '%s' "$out" | grep -qF "read  a/model.py"; then
  bad "and no per-call progress line is printed when stdout is not a terminal" "$out"
else
  ok "and no per-call progress line is printed when stdout is not a terminal"
fi

# The other half: attached to a real terminal, the wait is watchable while it
# runs, not only accounted for afterwards. `script` allocates one; where it is
# not installed the property above still held, so only this half is skipped.
# Its own proposal, in its own directory: `propose impacts` writes one every
# time it runs, and this run must not add a second file for `PROP` above to
# have picked between.
if command -v script >/dev/null 2>&1; then
  TTYWS="$(mktemp -d)"
  mkdir -p "$TTYWS/.deck"
  cp "$WS/.deck/workspace.yaml" "$TTYWS/.deck/workspace.yaml"
  TTYRUN="$TTYWS/tty-propose.sh"
  TTYLOG="$TTYWS/tty-propose.log"
  cat > "$TTYRUN" <<SH
#!/usr/bin/env bash
export DECK_ROOT="$TTYWS"
export PATH="$FAKEBIN:\$PATH"
"$DECK" propose impacts --yes
SH
  chmod +x "$TTYRUN"
  script -qec "$TTYRUN" "$TTYLOG" >/dev/null 2>&1 || true
  if grep -q "read  a/model.py" "$TTYLOG" 2>/dev/null; then
    ok "attached to a terminal, a read is printed while the call is still running"
  else
    bad "attached to a terminal, a read is printed while the call is still running" "$(cat "$TTYLOG" 2>&1)"
  fi
  rm -rf "$TTYWS"
else
  skip "attached to a terminal, a read is printed while the call is still running — script not on PATH"
fi

# A rule title is written by a model, so it arrives with whatever punctuation the
# model liked. It used to become the file name verbatim: an em-dash landed in the
# name, and a slash would have made a directory.
slug="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.config import title_slug
print(title_slug('Callbacks run on one thread - never block'))
print(title_slug('a/b: \"quoted\", and dashed'))
print(title_slug('\u2014\u2014'))
")"
if printf '%s' "$slug" | grep -q "callbacks-run-on-one-thread-never-block"; then
  ok "a rule file name is ascii, lowercase, and cut on a word"
else
  bad "a rule file name is ascii, lowercase, and cut on a word" "$slug"
fi
if printf '%s' "$slug" | grep -q "^a-b-quoted-and-dashed$"; then
  ok "a slash in a rule title cannot make a directory"
else
  bad "a slash in a rule title cannot make a directory" "$slug"
fi
if printf '%s' "$slug" | grep -q "^rule$"; then
  ok "a title with nothing nameable still yields a name"
else
  bad "a title with nothing nameable still yields a name" "$slug"
fi

# `skipped` means two things and the summary used to render both as "not
# applicable": a gate that does not apply here, and a gate that does apply but
# was never reached because the ladder stopped. Only the second is still owed,
# and the same line is what a reviewer reads in the bundle.
sm="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import summarise, PASSED, FAILED, SKIPPED, STOPPED_EARLY
print(summarise([{'status':PASSED,'runs':[1]},{'status':FAILED,'runs':[1]},
                 {'status':SKIPPED,'reason':STOPPED_EARLY,'runs':[]}]))
print(summarise([{'status':PASSED,'runs':[1]},
                 {'status':SKIPPED,'reason':'lint is not declared','runs':[]}]))
")"
if printf '%s' "$sm" | grep -q "1 not attempted"; then
  ok "a gate the ladder never reached is not attempted, not inapplicable"
else
  bad "a gate the ladder never reached is not attempted, not inapplicable" "$sm"
fi
if printf '%s' "$sm" | grep -q "1 not applicable"; then
  ok "a gate that does not apply is still reported as inapplicable"
else
  bad "a gate that does not apply is still reported as inapplicable" "$sm"
fi

# Every mounted line names where the artifact went, except a written file, which
# used to print its hash — so --dry-run said where the brief would land and the
# real mount did not.
"$DECK" unmount --task BRIEFED >/dev/null 2>&1
briefed="$("$DECK" mount --repos a --task BRIEFED --brief "what this task is" 2>&1 || true)"
if printf '%s' "$briefed" | grep -q "CLAUDE.local.md"; then
  ok "a written brief names the file it wrote"
else
  bad "a written brief names the file it wrote" "$briefed"
fi
"$DECK" unmount --task BRIEFED >/dev/null 2>&1

# The gate record's `level` is what the run was configured to reach. Reporting it
# as what was reached claims verification that did not happen: a failed static
# gate used to be summarised as "the ladder reached build".
rc="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
stopped = [{'from_level':'static','status':'passed'},
           {'from_level':'static','status':'failed'},
           {'from_level':'build','status':'skipped','reason':'an earlier gate failed'}]
green   = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
na      = [{'from_level':'static','status':'passed'},
           {'from_level':'build','status':'skipped','reason':'lint is not declared'}]
print('stopped', rung_completed(R,'build',stopped))
print('green', rung_completed(R,'build',green))
print('na', rung_completed(R,'build',na))
print('na_stopped', rung_completed(R,'build',na)[1])
")"
if printf '%s' "$rc" | grep -q "^stopped (None, 'static')$"; then
  ok "a failed rung is not reported as a rung the ladder reached"
else
  bad "a failed rung is not reported as a rung the ladder reached" "$rc"
fi
if printf '%s' "$rc" | grep -q "^green ('build', None)$"; then
  ok "a green run still names the level it was set to"
else
  bad "a green run still names the level it was set to" "$rc"
fi
# Deliberately narrowed, and the narrowing is the argument. This check asserted
# the whole tuple, so under one name it held two claims: that an inapplicable
# gate does not *stop* the ladder — the rule, and it stands — and that the rung
# it sits on counts as reached, which is an overclaim, because nothing was
# verified there. Asserting the second under the name of the first is how the
# defect survived two rounds of fixes in this file: a reader looking for the
# claim to challenge found a check that appeared to defend it. The rule keeps
# the name and the half of the tuple that states it, `stopped_at is None`; the
# other half moved to its own check with its own name, below.
#
# A regression guard, then: it passes before this change and after. It is here
# because the fix could only go wrong one way — by making an inapplicable gate
# owe something, which would stall a ladder that `only_repos` or a `when` toggle
# had legitimately narrowed.
if printf '%s' "$rc" | grep -q "^na_stopped None$"; then
  ok "a gate that does not apply does not hold the ladder back"
else
  bad "a gate that does not apply does not hold the ladder back" "$rc"
fi

# The same overclaim in the other direction. An empty rung was vacuously
# complete, so a workspace with `gate_level: deploy` and no deploy gate anywhere
# reported a ladder that reached `deploy` with nothing verified there.
