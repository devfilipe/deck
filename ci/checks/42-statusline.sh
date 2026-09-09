note "status line"
if printf '{"context_window":{"used_percentage":34}}' | "$DECK" statusline --no-color | head -1 | grep -q "$(basename "$WS")"; then
  ok "renders the workspace root"
else
  bad "renders the workspace root"
fi
if printf 'not json at all' | "$DECK" statusline --no-color >/dev/null 2>&1; then
  ok "invalid stdin does not break the bar"
else
  bad "invalid stdin does not break the bar"
fi
check "prints the settings snippet" "statusLine" "$DECK" statusline --settings
# What makes a status line slow is what it DOES on every prompt, not how long a
# cold interpreter takes to start. The old check timed the whole process against
# 250 ms of wall clock, which on a loaded machine measured Python's start-up:
# the work itself is around 40 ms, and the check reddened the ladder of a task
# that had not touched it. Assert the work instead — it holds on any machine.
sl="$(cd "$REPO/plugins/deck" && DECK_ROOT="$WS" TMUX="probe-19" python3 -c "
import os, socket, subprocess, sys, time
# Forced truthy regardless of whether this suite happens to be run inside a
# real tmux: session_id()'s tmux branch, and the repeated call it used to make,
# must be exercised the same way on every machine that runs this check.
os.environ.pop('TMUX_PANE', None)
os.environ.pop('DECK_SESSION', None)
os.environ.pop('CLAUDE_SESSION_ID', None)
calls = []
socket.socket = lambda *a, **k: sys.exit('statusline opened a socket')
real = subprocess.run
subprocess.run = lambda cmd, *a, **k: (calls.append(cmd[0] if cmd else '?'), real(cmd, *a, **k))[1]
from deck.statusline import render
t = time.time(); render({}, color=False); ms = (time.time() - t) * 1000
print('subprocesses', len(calls), ','.join(sorted(set(calls))))
print('tmux_calls', calls.count('tmux'))
print('work_ms', int(ms))
" 2>&1)"
# Two today: one `tmux display-message` for the window this render is in, one
# `git -C` for the repository — see the issue this number is pinned against.
# The point of pinning it is that the next thing added per prompt has to move
# this line and say why, which a wall-clock budget on a fast laptop never made
# anyone do.
if printf '%s' "$sl" | grep -qE "^subprocesses [0-2] "; then
  ok "the status line spawns no more processes per prompt than it did"
else
  bad "the status line spawns no more processes per prompt than it did" "$sl"
fi
# The behaviour the issue is about: not what the code says, but how many times
# it actually asks. `journal_sample`, the task file, and `Toggles.__init__` each
# call `session_id()` in one render; before the fix each one asked tmux fresh,
# for an answer that cannot change during this process's life.
if [ "$(printf '%s' "$sl" | awk '/^tmux_calls/{print $2}')" -le 1 ] 2>/dev/null; then
  ok "asks tmux which window it is in at most once per render"
else
  bad "asks tmux which window it is in at most once per render" "$sl"
fi
if printf '%s' "$sl" | grep -q "opened a socket"; then
  bad "and reaches no network" "$sl"
else
  ok "and reaches no network"
fi
if [ "$(printf '%s' "$sl" | awk '/^work_ms/{print $2}')" -lt 250 ] 2>/dev/null; then
  ok "and the work it does stays well inside a prompt"
else
  bad "and the work it does stays well inside a prompt" "$sl"
fi

note "which deck did it"
# The first question about anything deck did. The number lives in the plugin
# manifest, because Claude Code reads that file without running anything, and
# Python reads it from there — two copies of one number is how they drift, and
# this repository has already lost that argument over a check total stated in
# five documents and gated in four.
check "--version answers" "deck 0." "$DECK" --version
check "and doctor carries it, since a diagnosis is what gets pasted" "OK deck" "$DECK" doctor

ver="$(cd "$REPO/plugins/deck" && python3 -c "
import json, pathlib, sys
sys.path.insert(0, '.')
import deck
manifest = json.loads(pathlib.Path('.claude-plugin/plugin.json').read_text())
print('same' if deck.__version__ == manifest['version'] else f\"drifted: {deck.__version__} != {manifest['version']}\")
")"
if [ "$ver" = "same" ]; then
  ok "the package and the manifest cannot disagree about the version"
else
  bad "the package and the manifest cannot disagree about the version" "$ver"
fi

# A clone with no manifest is broken; deck says so rather than inventing one.
noman="$(cd "$REPO/plugins/deck" && python3 -c "
import importlib, pathlib, sys, tempfile, shutil
tmp = tempfile.mkdtemp()
shutil.copytree('deck', pathlib.Path(tmp) / 'deck')
sys.path.insert(0, tmp)
for m in [k for k in sys.modules if k == 'deck' or k.startswith('deck.')]:
    del sys.modules[m]
import deck as broken
print(broken.__version__)
")"
if [ "$noman" = "unknown" ]; then
  ok "a clone that cannot read its manifest says unknown, never a plausible number"
else
  bad "a clone that cannot read its manifest says unknown, never a plausible number" "$noman"
fi
