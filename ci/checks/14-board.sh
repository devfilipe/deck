note "board planning"
cat > "$WS/.deck/board.yaml" <<'YAML'
tasks:
  - { id: T-1, title: schema change,  repos: [a] }
  - { id: T-2, title: docs,           repos: [c] }
  - { id: T-3, title: server work,    repos: [b] }
  - { id: T-4, title: key rotation,   repos: [b], exclusive: true }
  - { id: T-5, title: finished,       repos: [b], status: done }
YAML
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "tasks are read"           "T-1"        "$DECK" board list
check "a done task is not planned" "T-5"      "$DECK" board plan
check "an exclusive task stands alone" "alone" "$DECK" board plan
check "conflicts are explained"  "would edit" "$DECK" board why T-1 T-3
if "$DECK" board why T-2 T-3 | grep -q "can run at the same time"; then
  ok "independent tasks are allowed together"
else
  bad "independent tasks are allowed together"
fi
if "$DECK" board plan --json | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if any(g["parallel"] for g in p["groups"]) else 1)'; then
  ok "something actually parallelises"
else
  bad "something actually parallelises"
fi
if "$DECK" board plan --parallelism 1 --json | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if not any(g["parallel"] for g in p["groups"]) else 1)'; then
  ok "parallelism 1 serialises everything"
else
  bad "parallelism 1 serialises everything"
fi
check "the plan says it is not a run" "not a run" "$DECK" board plan

# An agent inside a run has no channel to a person, so a toggle left at `ask` is
# a wall and not a prompt. The board has to say which decisions block it before
# anything is spawned.
out="$("$DECK" board ask-plan 2>&1 || true)"
if printf '%s' "$out" | grep -q "waiting on"; then ok "the board names the decisions blocking it"; else bad "the board names the decisions blocking it" "$out"; fi
if printf '%s' "$out" | grep -q "blocks "; then ok "and which tasks each one blocks"; else bad "and which tasks each one blocks" "$out"; fi
check_fail "a board with pending decisions exits non-zero" "$DECK" board ask-plan
if "$DECK" board plan --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("pending_decisions") else 1)'; then
  ok "the plan carries them, so a workflow cannot miss them"
else bad "the plan carries them, so a workflow cannot miss them"; fi
before="$("$DECK" board ask-plan --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))')"
# Answer whichever one is actually pending, rather than assuming which — and put
# it back, so this check does not decide something a later one reads.
ANSWERED="$("$DECK" board ask-plan --json | python3 -c '
import json, subprocess, sys
q = json.load(sys.stdin)["questions"][0]
subprocess.run([sys.argv[1], "toggle", "set", "--at", "workspace", q["id"], q["options"][0]["value"]],
               capture_output=True)
print(q["id"])
' "$DECK")"
after="$("$DECK" board ask-plan --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["questions"]))')"
if [ "$after" -lt "$before" ]; then ok "an answered decision leaves the list"; else bad "an answered decision leaves the list" "$before -> $after"; fi
"$DECK" toggle set --at workspace "$ANSWERED" ask >/dev/null 2>&1

# `c` is downstream in the synthetic workspace, so T-1 (repos: [a]) reaches it
# without naming it and T-2 (repos: [c]) edits it. That pair is allowed to run
# together — reaching is not editing — and is still worth one line of warning.
check "a downstream repo one task edits and another reaches is flagged" "which T-2 edits" "$DECK" board plan
if "$DECK" board plan --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("cautions") else 1)'; then
  ok "the caution is in the json a workflow consumes"
else bad "the caution is in the json a workflow consumes"; fi

# Two questions about the same answer: what the planner is allowed to establish,
# and whether a person can read the answer it gave. Its own workspace, because
# both turn on a registry that holds some of the names the board uses and not
# others — the shared one holds every name its board mentions, which is exactly
# the case that never asks either question.
PW="$(mktemp -d)"
mkdir -p "$PW/.deck" "$PW/a" "$PW/b"
cat > "$PW/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  a: { path: a }
  b: { path: b }
targets: []
backlog:
  - { type: tasks, file: .deck/board.yaml }
YAML
pw() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PW" "$DECK" "$@"; }

# `ghost` is not in the registry, so the closure drops it and the two tasks that
# both name it overlap nowhere — which read as evidence that they were disjoint.
# It is the opposite: deck cannot place the name, so nothing has been shown
# about either task, and a wrong "yes" here is two agents in one tree.
cat > "$PW/.deck/board.yaml" <<'YAML'
tasks:
  - { id: G-1, title: one, repos: [ghost] }
  - { id: G-2, title: two, repos: [ghost] }
YAML
gjson="$(pw board plan --json 2>&1 || true)"
if printf '%s' "$gjson" | python3 -c 'import json,sys; sys.exit(0 if any(g["parallel"] for g in json.load(sys.stdin)["groups"]) else 1)' 2>/dev/null; then
  bad "a repository the registry does not hold is never evidence that two tasks are disjoint" "$(printf '%s' "$gjson" | head -30)"
else
  ok "a repository the registry does not hold is never evidence that two tasks are disjoint"
fi
gwhy="$(pw board why G-1 G-2 2>&1 || true)"
if printf '%s' "$gwhy" | grep -q "ghost"; then
  ok "and the refusal names the repository nobody declared"
else bad "and the refusal names the repository nobody declared" "$gwhy"; fi
gplan="$(pw board plan 2>&1 || true)"
if printf '%s' "$gplan" | grep -E "^ +reaches:" | grep -q "ghost"; then
  ok "and the plan names the repository it could not place, rather than none"
else bad "and the plan names the repository it could not place, rather than none" "$gplan"; fi

# Legibility, on the board shape the coarse answer costs the most on: every task
# in one repository, so every group holds one. The grouping is right and it is
# the reason beside it that lets somebody weigh what serial costs them.
cat > "$PW/.deck/board.yaml" <<'YAML'
tasks:
  - { id: P-1, title: one, repos: [a] }
  - { id: P-2, title: two, repos: [a] }
  - { id: P-3, title: three, repos: [b] }
YAML
sjson="$(pw board plan --json 2>&1 || true)"
if printf '%s' "$sjson" | python3 -c '
import json, sys
g = {t["id"]: t for b in json.load(sys.stdin)["groups"] for t in b["tasks"]}
held = g["P-2"]["held_from"]
sys.exit(0 if held and held[0]["against"] == "P-1" and "a" in held[0]["reason"] else 1)' 2>/dev/null; then
  ok "the plan carries which task kept another out of a group, and why"
else bad "the plan carries which task kept another out of a group, and why" "$(printf '%s' "$sjson" | head -40)"; fi
# The same reason, in the rendering a person reads. Taken out of the payload and
# looked for in the text rather than spelled out here: what is being asserted is
# that the two agree, not that either of them uses a particular sentence.
splan="$(pw board plan 2>&1 || true)"
sreason="$(printf '%s' "$sjson" | python3 -c '
import json, sys
held = {t["id"]: t for b in json.load(sys.stdin)["groups"] for t in b["tasks"]}["P-2"]["held_from"]
print(held[0]["reason"] if held else "")' 2>/dev/null || true)"
if [ -n "$sreason" ] && printf '%s' "$splan" | grep -qF -- "$sreason"; then
  ok "and the terminal plan says it too, so a group of one is not mysterious"
else bad "and the terminal plan says it too, so a group of one is not mysterious" "$splan"; fi
# The half the fix must not move: tasks in different repositories still share a
# group, and nothing was made more conservative to buy the two checks above.
if printf '%s' "$sjson" | python3 -c '
import json, sys
for b in json.load(sys.stdin)["groups"]:
    ids = sorted(t["id"] for t in b["tasks"])
    if ids == ["P-1", "P-3"]:
        sys.exit(0)
sys.exit(1)' 2>/dev/null; then
  ok "and tasks that span different repositories still run together"
else bad "and tasks that span different repositories still run together" "$(printf '%s' "$sjson" | head -40)"; fi
rm -rf "$PW"

# A declared backlog whose file exists but yields nothing used to pass doctor
# and leave `board list` empty with no explanation.
BQ="$WS/backlog-prose.md"
printf '# Roadmap\n\n## Item one\nProse, not a checklist.\n' > "$BQ"
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t + "\nbacklog:\n- type: roadmap\n  file: backlog-prose.md\n")
PY
check "a backlog that parses to nothing says so" "no tasks in backlog-prose.md" "$DECK" board list
check "and names the shape it expected" "- [ ]" "$DECK" board list
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("\nbacklog:\n- type: roadmap\n  file: backlog-prose.md\n", "\n"))
PY
rm -f "$BQ"

# A shared board must not default into .deck/, which is per machine.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text() + "\nbacklog:\n- type: tasks\n")
PY
check_fail "a tasks source with no file: refuses to be written to" "$DECK" board new "x" --yes
out="$("$DECK" board new "x" --yes 2>&1)"
if printf '%s' "$out" | grep -q "the team versions"; then ok "and says where to declare one"; else bad "and says where to declare one" "$out"; fi
# Put the real board back by rewriting the key, not by unpicking the text: the
# stub above and the genuine source share their first two lines, so a textual
# removal took both and left `file:` orphaned under `targets:`. Every board
# check after this point then ran against a descriptor with no backlog at all,
# and passed, because "no tasks" is not what any of them was asserting.
python3 - "$WS/.deck/workspace.yaml" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY
check "the board is readable again" "T-1" "$DECK" board list
