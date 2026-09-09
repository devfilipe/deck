note "console"
check "one-shot status"       "root"       "$DECK" console -c status
check "asks lists the options" "deploy_mode" "$DECK" console -c "asks verify"
check "unknown command warns" "unknown"    "$DECK" console -c "nosuchthing"

note "split screen"
if command -v tmux >/dev/null; then
  check "plan outside tmux"  "new-session"  env -u TMUX "$DECK" ui --dry-run
  check_fail "width outside the range is refused" "$DECK" ui --dry-run --width 5

  # An existing session is the normal case, not an error: the first run builds
  # it, the attach fails for want of a terminal, and every run after that used
  # to die on `duplicate session`.
  RS="deck-reuse-$$"
  tmux kill-session -t "$RS" 2>/dev/null
  # `--agent-cmd`: the left pane runs `claude` by default, which does not exist
  # on a CI runner, so the session died before the split and took three checks
  # with it. What is under test is deck's session handling.
  env -u TMUX "$DECK" ui --session "$RS" --agent-cmd "sleep 60" >/dev/null 2>&1
  if tmux has-session -t "$RS" 2>/dev/null; then ok "a detached run builds the session"; else bad "a detached run builds the session"; fi
  out="$(env -u TMUX "$DECK" ui --session "$RS" --agent-cmd "sleep 60" 2>&1)"
  if printf '%s' "$out" | grep -q "already up"; then ok "a second run reuses it instead of failing"; else bad "a second run reuses it instead of failing" "$out"; fi
  if printf '%s' "$out" | grep -q "tmux attach -t $RS"; then ok "and says how to reach it"; else bad "and says how to reach it" "$out"; fi
  pop="$(env -u TMUX "$DECK" ui --popup --session "$RS" --agent-cmd "sleep 60" 2>&1 || true)"
  if printf '%s' "$pop" | grep -q "already up"; then ok "popup outside tmux points at the live session"; else bad "popup outside tmux points at the live session" "$pop"; fi
  tmux kill-session -t "$RS" 2>/dev/null
  S="deck-smoke-$$"
  tmux kill-session -t "$S" 2>/dev/null
  tmux new-session -d -s "$S" -x 160 -y 24 -c "$WS" bash
  sleep 1
  tmux split-window -h -f -t "$S": -c "$WS" \
    "bash -c 'DECK_ROOT=$WS $DECK toggle --session pair set deploy_mode packaged >/dev/null; sleep 30'"
  sleep 2
  OUT="$WS/shared.txt"
  tmux send-keys -t "$(tmux list-panes -t "$S": -F '#{pane_id}' | head -1)" \
    "DECK_ROOT=$WS $DECK toggle --session pair get deploy_mode > $OUT" Enter
  sleep 3
  if [ "$(cat "$OUT" 2>/dev/null)" = "packaged" ]; then
    ok "panes of one window share the task scope"
  else
    bad "panes of one window share the task scope" "got: $(cat "$OUT" 2>/dev/null)"
  fi
  tmux kill-session -t "$S" 2>/dev/null
else
  # Eight checks live above. Named one by one rather than as a count, so the
  # summary says what could not run here instead of only how many.
  skip "plan outside tmux — tmux not on PATH"
  skip "width outside the range is refused — tmux not on PATH"
  skip "a detached run builds the session — tmux not on PATH"
  skip "a second run reuses it instead of failing — tmux not on PATH"
  skip "popup outside tmux points at the live session — tmux not on PATH"
  skip "the console writes through to the toggle — tmux not on PATH"
  skip "panes of one window share the task scope — tmux not on PATH"
  skip "and says how to reach it — tmux not on PATH"
fi

# `setup --dry-run` is the discovery pass: it must run on a workspace that
# already has a descriptor, and it must write nothing.
before="$(cat "$WS/.deck/workspace.yaml")"
check "discovery runs on a configured workspace" "Nothing written" "$DECK" setup --dry-run --root "$WS"
check "and reports what it found" "What is in this workspace" "$DECK" setup --dry-run --root "$WS"
if [ "$before" = "$(cat "$WS/.deck/workspace.yaml")" ]; then ok "discovery changed nothing"; else bad "discovery changed nothing"; fi
