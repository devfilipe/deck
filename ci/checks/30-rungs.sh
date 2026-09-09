note "a rung with no gate is a gap, not a rung the ladder reached"
# Two snippets, not one: an import that does not exist yet would fail every
# check in the block at once, and a check has to fail for its own reason.
er="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
empty = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
hole  = [{'from_level':'static','status':'passed'},{'from_level':'deploy','status':'passed'}]
print('empty', rung_completed(R,'deploy',empty))
print('hole', rung_completed(R,'deploy',hole))
")"
if printf '%s' "$er" | grep -q "^empty ('build', None)\$"; then
  ok "a rung the ladder climbed to that holds no gate is not a rung it reached"
else
  bad "a rung the ladder climbed to that holds no gate is not a rung it reached" "$er"
fi
if printf '%s' "$er" | grep -q "^hole ('static', None)\$"; then
  ok "and nothing above the hole is credited either"
else
  bad "and nothing above the hole is credited either" "$er"
fi
nr="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rungs_without_gates
R = ['static','build','deploy','behavior']
empty = [{'from_level':'static','status':'passed'},{'from_level':'build','status':'passed'}]
unnamed = [{'from_level':None,'status':'passed'}]
print('without', rungs_without_gates(R,empty))
print('unnamed', rungs_without_gates(R,unnamed))
" 2>&1)"
if printf '%s' "$nr" | grep -q "^without \['deploy', 'behavior'\]\$"; then
  ok "the rungs holding no gate are named, so the gap is visible"
else
  bad "the rungs holding no gate are named, so the gap is visible" "$nr"
fi
# `applicable()` reads a missing from_level as static; `record()` files it as
# null. A gate declared without one would otherwise leave static looking empty.
if printf '%s' "$nr" | grep -q "^unnamed \['build', 'deploy', 'behavior'\]\$"; then
  ok "a gate declared with no from_level counts at the rung it ran on"
else
  bad "a gate declared with no from_level counts at the rung it ran on" "$nr"
fi

# The same overclaim one layer in. A rung that *has* gates, every one of which
# turned out not to apply — `only_repos` excluded every repository in play, a
# `when` toggle did not match — owed nothing, and owing nothing was read as
# being done. So `build` was reported reached while no build command ever ran.
note "a rung whose gates were all waved through is not a rung the ladder reached"
wv="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rung_completed
R = ['static','build','deploy','behavior']
waved = [{'from_level':'static','status':'passed'},
         {'from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
mixed = [{'from_level':'static','status':'passed'},
         {'from_level':'build','status':'passed'},
         {'from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
print('waved', rung_completed(R,'build',waved))
print('mixed', rung_completed(R,'build',mixed))
" 2>&1)"
if printf '%s' "$wv" | grep -q "^waved ('static', None)\$"; then
  ok "a rung whose every gate was waved through is not reported as reached"
else
  bad "a rung whose every gate was waved through is not reported as reached" "$wv"
fi
# The other half of the same rule, and it is why "not reached" is stated as
# "nothing passed here" rather than "something did not apply here". One gate
# that actually ran is verification; the inapplicable ones beside it neither add
# to it nor take it away.
if printf '%s' "$wv" | grep -q "^mixed ('build', None)\$"; then
  ok "and a rung with one gate that actually passed is still reached"
else
  bad "and a rung with one gate that actually passed is still reached" "$wv"
fi
# Its own snippet: an import that does not exist yet must not fail the checks
# above, which are about a different function.
wi="$(cd "$REPO/plugins/deck" && python3 -c "
from deck.gates import rungs_all_inapplicable
R = ['static','build','deploy','behavior']
waved = [{'id':'lint','from_level':'static','status':'passed','reason':''},
         {'id':'build','from_level':'build','status':'skipped','reason':'no repository in this change matches it'}]
failed = [{'id':'fails','from_level':'build','status':'failed','reason':''}]
print('waved', rungs_all_inapplicable(R,waved))
print('failed', rungs_all_inapplicable(R,failed))
" 2>&1)"
if printf '%s' "$wi" | grep -q "'rung': 'build'.*'id': 'build'.*no repository in this change matches it"; then
  ok "the rung names the gates it weighed and the reason each gave"
else
  bad "the rung names the gates it weighed and the reason each gave" "$wi"
fi
# A rung the ladder failed at is not coverage. It is where the ladder stopped,
# `rung_completed()` already names it, and filing it here as well would print a
# failure under a heading that reads as "nothing to do here".
if printf '%s' "$wi" | grep -q "^failed \[\]\$"; then
  ok "and a rung the ladder failed at is not filed as coverage"
else
  bad "and a rung the ladder failed at is not filed as coverage" "$wi"
fi

# Two panes of one window are one task, and the SessionEnd hook takes mounts
# back. Together those used to mean any pane closing tore the task down under
# the pane still working in it. A mount is now held, and released one holder at
# a time.
