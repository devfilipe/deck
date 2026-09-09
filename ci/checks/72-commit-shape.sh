note "the commit-shape gate"
# Its own scratch repository: the gate reads git history, and the only way to
# check what it says about a bad subject is to write one.
CSD="$(mktemp -d)"
CS="$REPO/ci/commit-shape.py"
git init -q -b main "$CSD"
cs_git() { git -C "$CSD" -c user.email=t@t -c user.name=T "$@"; }
: > "$CSD/a"; cs_git add -A; cs_git commit -q -m "chore: seed"
CSBASE="$(cs_git rev-parse HEAD)"
cs_run() { (cd "$CSD" && env -u GITHUB_HEAD_REF DECK_BRANCH="$1" python3 "$CS" 2>&1); }

cs_out="$(cs_run "" )"; cs_rc=$?
if [ "$cs_rc" = 0 ] && printf '%s' "$cs_out" | grep -q 'nothing ahead'; then
  ok "a branch with nothing ahead of main is not a failure"
else bad "a branch with nothing ahead of main is not a failure" "$cs_out"; fi

# A root commit is not a change: there is nothing it changed relative to, so
# `<type>: <what changed>` has nothing to describe. It matters because the range
# is `main..HEAD` and assumes a shared base — a history rewritten to one commit
# shares none, so everything looks like work in hand and the gate judged the
# commit that was about to BECOME main.
CSR="$(mktemp -d)"; git init -q -b main "$CSR"
csr_git() { git -C "$CSR" -c user.email=t@t -c user.name=T "$@"; }
: > "$CSR/a"; csr_git add -A; csr_git commit -q -m "the project, described rather than changed"
csr_git branch -q -f orphan HEAD
csr_out="$( (cd "$CSR" && env -u GITHUB_HEAD_REF DECK_BRANCH=orphan python3 "$CS" 2>&1) )"
if printf '%s' "$csr_out" | grep -q 'is not Conventional Commits'; then
  bad "a root commit is not judged as a change" "$csr_out"
else ok "a root commit is not judged as a change"; fi
rm -rf "$CSR"

cs_git checkout -q -b fix-49
: > "$CSD/b"; cs_git add -A; cs_git commit -q -m "arrumei o board."
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q 'is not Conventional Commits'; then
  ok "a subject that is not Conventional Commits is named"
else bad "a subject that is not Conventional Commits is named" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "and the issue the branch name carries is asked for by number"
else bad "and the issue the branch name carries is asked for by number" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q 'no commit on `fix-49` carries'; then
  ok "and the branch is what owes it, so the branch is what the message names"
else bad "and the branch is what owes it, so the branch is what the message names" "$cs_out"; fi

cs_git commit -q --amend -m "fix: name the board a scope reads"
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "a good subject alone does not satisfy a branch that names an issue"
else bad "a good subject alone does not satisfy a branch that names an issue" "$cs_out"; fi

cs_out="$(cs_run add-a-thing)"
if printf '%s' "$cs_out" | grep -q 'Closes'; then
  bad "a branch with no number in it is asked for no trailer" "$cs_out"
else ok "a branch with no number in it is asked for no trailer"; fi

cs_git commit -q --amend -m "fix: name the board a scope reads

Closes #49"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ] && printf '%s' "$cs_out" | grep -q 'the branch closes #49'; then
  ok "a Conventional subject with the trailer passes"
else bad "a Conventional subject with the trailer passes" "$cs_out"; fi

# An issue is closed once. Asking every commit for the trailer is noise the
# gate would be training people to write — and did, on the second commit of a
# two-commit branch whose first already carried it.
cs_git commit -q --allow-empty -m "docs: the note that goes with the fix"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ]; then
  ok "a second commit on the same branch does not owe the trailer again"
else bad "a second commit on the same branch does not owe the trailer again" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q '2 commit(s)'; then
  ok "and both are still judged, not skipped to reach that answer"
else bad "and both are still judged, not skipped to reach that answer" "$cs_out"; fi
# The half that stays per commit: a subject is a property of each message.
cs_git commit -q --amend --allow-empty -m "arrumei o commit"
cs_out="$(cs_run fix-49)"
if printf '%s' "$cs_out" | grep -q "subject is not Conventional Commits: 'arrumei o commit'"; then
  ok "a bad subject is still reported against the commit that has it"
else bad "a bad subject is still reported against the commit that has it" "$cs_out"; fi
if printf '%s' "$cs_out" | grep -q 'Closes #49'; then
  bad "and the branch still owes nothing, its first commit having closed it" "$cs_out"
else ok "and the branch still owes nothing, its first commit having closed it"; fi
cs_git reset -q --hard HEAD~1

# The shape that broke this gate on its own first pull request. A forge builds
# a pull request at an ephemeral merge whose subject is `Merge <sha> into <sha>`
# — not `Merge branch`, not `Merge pull request`, which is what a pattern on the
# subject was written against. Having two parents is the fact.
CSTOP="$(cs_git rev-parse HEAD)"
cs_git checkout -q --detach "$CSBASE"
cs_git merge -q --no-ff -m "Merge ${CSTOP} into ${CSBASE:0:8}" "$CSTOP"
cs_out="$(cs_run fix-49)"; cs_rc=$?
if [ "$cs_rc" = 0 ]; then
  ok "the merge a forge builds a pull request at is not judged"
else bad "the merge a forge builds a pull request at is not judged" "$cs_out"; fi

# GITHUB_HEAD_REF over a detached HEAD: without it the branch name is `HEAD`,
# the issue number is gone, and the gate asks for less on the pull request than
# it asked for locally. On a branch of its own, because the one above closes its
# issue on its first commit and a branch that owes nothing proves nothing here.
cs_git checkout -q -b owes-nothing-yet "$CSBASE"
cs_git commit -q --allow-empty -m "fix: something with no trailer anywhere"
cs_out="$( (cd "$CSD" && GITHUB_HEAD_REF=fix-49 python3 "$CS" 2>&1) )"
if printf '%s' "$cs_out" | grep -q '`Closes #49` trailer'; then
  ok "the branch name comes from the environment when git has only a detached HEAD"
else bad "the branch name comes from the environment when git has only a detached HEAD" "$cs_out"; fi
cs_out="$( (cd "$CSD" && env -u GITHUB_HEAD_REF DECK_BRANCH=owes-nothing-yet python3 "$CS" 2>&1) )"
if printf '%s' "$cs_out" | grep -q 'Closes'; then
  bad "and a branch whose name carries no number is still asked for nothing" "$cs_out"
else ok "and a branch whose name carries no number is still asked for nothing"; fi
rm -rf "$CSD"
