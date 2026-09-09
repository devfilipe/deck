note "the name a claim is published under"
# A file board is committed and pushed. `$USER` is whatever the machine calls
# you, and it reached seven `assignee:` lines in this repository headed for a
# public push under a different identity — nothing between the write and the
# push ever questioned it. The name recorded in a file is now the one the
# repository publishes under: git's `user.name`, read where the file lives.
#
# Its own workspace and its own repositories, because the question this answers
# is which identity is read when two of them disagree. GIT_CONFIG_GLOBAL is
# pinned so every check reads the fixture's configuration and never the
# machine's, and `USER` is set to a name no repository here carries, so anything
# still reading the login is visible in the output instead of plausible in it.
IW="$(mktemp -d)"; mkdir -p "$IW/.deck" "$IW/pub" "$IW/other" "$IW/loose"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$IW/.deck/toggles.yaml"
for d in pub other; do git -C "$IW/$d" init -q 2>/dev/null; done
git -C "$IW/pub"   config user.name ana
git -C "$IW/other" config user.name nemo

board_at() {   # a board file at the path named, holding one open task
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'YAML'
version: 1
tasks:
  - { id: T-1, title: one thing, repos: [], status: open }
YAML
}
points_at() {  # aim the descriptor's single file source at a path
  python3 - "$IW/.deck/workspace.yaml" "$1" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1])
p.write_text(yaml.safe_dump(
    {"version": 1, "repos": {}, "targets": [], "backlog": [{"type": "tasks", "file": sys.argv[2]}]},
    sort_keys=False))
PY
}
iw()    { env -u DECK_USER DECK_ROOT="$IW" USER=shell-login \
              GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
iw_as() { local name="$1"; shift
          env DECK_USER="$name" DECK_ROOT="$IW" USER=shell-login \
              GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }

board_at "$IW/pub/board.yaml"; points_at pub/board.yaml
check "a claim on a file board records the repository's identity" "claimed T-1 for ana" \
  iw board claim T-1 --yes
check "and says where that name came from" "comes from git user.name" \
  iw board claim T-1 --yes
if grep -q "shell-login" "$IW/pub/board.yaml"; then
  bad "the shell login reaches the committed file nowhere" "$(grep -n shell-login "$IW/pub/board.yaml")"
else
  ok "the shell login reaches the committed file nowhere"
fi
check "\$DECK_USER overrides it"     "claimed T-1 for zed"     iw_as zed board claim T-1 --force --yes
check "and the override is stated"   'comes from $DECK_USER'   iw_as zed board claim T-1 --force --yes
check "a name given outright wins over both" "claimed T-1 for nemo" \
  iw_as zed board claim T-1 nemo --force --yes

# The question the fix turns on: a workspace holds several repositories and they
# may publish under different names, so the identity read is the one configured
# where the board file lives — the configuration that will sign the commit
# carrying it — and not a ranking of the registry.
board_at "$IW/other/board.yaml"; points_at other/board.yaml
check "a board in another repository records that repository's identity" "claimed T-1 for nemo" \
  iw board claim T-1 --yes

board_at "$IW/loose/board.yaml"; points_at loose/board.yaml
none="$(iw board claim T-1 --yes 2>&1 || true)"
if printf '%s' "$none" | grep -q "config user.name"; then
  ok "with no identity to read, the refusal names the command that sets one"
else
  bad "with no identity to read, the refusal names the command that sets one" "$none"
fi
check_fail "and nothing is claimed under the login instead" iw board claim T-1 --yes

points_at pub/board.yaml
check "whoami says which name a file source would write" "ana"           iw board whoami
check "and where it reads that name from"                "git user.name" iw board whoami

# `read` resolved the declared path and `source_for` did not, so a board under
# `~` was listed and closed but never claimed: the claim reported a task it had
# just printed as living in no source it could write to.
board_at "$IW/home/board.yaml"; points_at "~/board.yaml"
check "a board declared under \`~\` is claimable, not only readable" "claimed T-1 for zed" \
  env DECK_USER=zed DECK_ROOT="$IW" HOME="$IW/home" "$DECK" board claim T-1 --yes

# ---- and the other half of the question, which is not the same question.
# A tracker claim names an account that authenticates to that tracker, so the
# login stays right there. Its own stand-in on a port the kernel picks, so this
# group carries no fixture of anyone else's: it records whatever name it is
# given, and the check reads the name deck sent.
cat > "$IW/tracker.py" <<'PY'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self._send({'items': [{'number': 1, 'title': 'a thing', 'state': 'open', 'labels': [],
                               'assignee': None, 'html_url': 'http://x/1', 'body': ''}]})

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n).decode() or '{}')
        self._send({'number': 1, 'assignees': [{'login': w} for w in body.get('assignees', [])]}, 201)


s = HTTPServer(('127.0.0.1', 0), H)   # port 0: the kernel picks a free one
open(sys.argv[1], 'w').write(str(s.server_port))
threading.Thread(target=s.serve_forever, daemon=True).start()
import time; time.sleep(120)
PY
python3 "$IW/tracker.py" "$IW/port" & IFAKE=$!
# The socket is bound and listening before the port is written, so the file
# appearing is the readiness signal — no sleep long enough to be a guess.
for _ in $(seq 1 50); do [ -s "$IW/port" ] && break; sleep 0.1; done
TIW="$(mktemp -d)"; mkdir -p "$TIW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$TIW/.deck/toggles.yaml"
git -C "$TIW" init -q 2>/dev/null; git -C "$TIW" config user.name ana
cat > "$TIW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$(cat "$IW/port" 2>/dev/null)" }
YAML
check "a tracker claim still names the account that authenticates" "assigned #1 to shell-login on github" \
  env -u DECK_USER DECK_ROOT="$TIW" USER=shell-login DECK_TOKEN_GITHUB=smoke-token "$DECK" board claim "#1" --yes
kill $IFAKE 2>/dev/null || true
rm -rf "$TIW"

# A consultation outlives its session by design, is read by the next run, and is
# quoted into the bundle a reviewer reads. `asked_by` travels as far as an
# `assignee:` does, so it is resolved the same way.
CW="$(mktemp -d)"; mkdir -p "$CW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$CW/.deck/toggles.yaml"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$CW/.deck/workspace.yaml"
git -C "$CW" init -q 2>/dev/null; git -C "$CW" config user.name ana
cw() { env -u DECK_USER DECK_ROOT="$CW" USER=shell-login \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
asked="$(cw ask new "Which identity does a recorded question carry?" 2>&1)"
CID="$(printf '%s' "$asked" | grep -oE '^recorded .*' | cut -d' ' -f2)"
check "a consultation records the published identity" "by ana" cw ask show "$CID"
if grep -rq "shell-login" "$CW/.deck/consultations"; then
  bad "and never the shell login" "$(grep -rn shell-login "$CW/.deck/consultations" | head -1)"
else
  ok "and never the shell login"
fi
NW="$(mktemp -d)"; mkdir -p "$NW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$NW/.deck/toggles.yaml"
printf 'version: 1\nrepos: {}\ntargets: []\n' > "$NW/.deck/workspace.yaml"
nw() { env -u DECK_USER DECK_ROOT="$NW" USER=shell-login \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$DECK" "$@"; }
nasked="$(nw ask new "And with no identity to read?" 2>&1)"
NID="$(printf '%s' "$nasked" | grep -oE '^recorded .*' | cut -d' ' -f2)"
check "with no identity to read, a consultation records none rather than the login" "by ?" \
  nw ask show "$NID"
rm -rf "$IW" "$CW" "$NW"
