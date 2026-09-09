note "a board that lives in a tracker, with no network"
# Every tracker read was a live request and there was no cache, so a resolver
# that went down for a minute took the board with it — `board list` empty,
# `bundle` unable to say which repositories a task names, `plan` with nothing to
# group. The cache is written only by a read that succeeded and read only by one
# that did not, and everything it serves says so.
OFF="$(mktemp -d)"; mkdir -p "$OFF/.deck" "$OFF/api"
git -C "$OFF/api" init -q 2>/dev/null
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$OFF/.deck/toggles.yaml"
# A stand-in of this block's own, on loopback, so nothing here leaves the
# machine and killing it is the outage. `total_count` is an argument because
# what a short read does is half of what is being checked.
cat > "$OFF/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOTAL = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(
            {
                "total_count": TOTAL,
                "items": [
                    {
                        "number": 41,
                        "title": "rate limit `api`",
                        "body": "",
                        "state": "open",
                        "labels": [],
                        "html_url": "http://example.invalid/41",
                        "assignee": None,
                    }
                ],
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$OFF/stub.py" 1 > "$OFF/port" 2> "$OFF/err" & OFF1=$!
OFF_PORT="$(stub_port "$OFF1" "$OFF/port")"
cat > "$OFF/.deck/workspace.yaml" <<YAML
version: 1
repos:
  api: { path: api, impacts: [] }
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$OFF_PORT" }
YAML
OFFENV=(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$OFF" DECK_TOKEN_GITHUB=smoke-token)

# The second fixture is the short read: a provider that answered for one issue
# out of nine. Its board is not the whole one, so freezing it would serve a
# partial answer for as long as the outage lasted, with nothing left to say it
# was partial.
OFS="$(mktemp -d)"; mkdir -p "$OFS/.deck" "$OFS/api"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$OFS/.deck/toggles.yaml"
cp "$OFF/stub.py" "$OFS/stub.py"
python3 "$OFS/stub.py" 9 > "$OFS/port" 2> "$OFS/err" & OFF2=$!
OFS_PORT="$(stub_port "$OFF2" "$OFS/port")"
cat > "$OFS/.deck/workspace.yaml" <<YAML
version: 1
repos:
  api: { path: api, impacts: [] }
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$OFS_PORT" }
YAML
OFSENV=(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$OFS" DECK_TOKEN_GITHUB=smoke-token)

if [ -z "$OFF_PORT" ] || [ -z "$OFS_PORT" ]; then
  bad "the offline-board stand-ins start" "$(tail -1 "$OFF/err" 2>/dev/null) $(tail -1 "$OFS/err" 2>/dev/null)"
  bad "a tracker board read once is still there when the tracker is not" "no stand-in"
  bad "and every task it serves says it came from a cache, and how old" "no stand-in"
  bad "a live read is never marked as one that came from a cache" "no stand-in"
  bad "a task only the cache holds can be read and cannot be claimed" "no stand-in"
  bad "nor closed, and --force does not buy past it" "no stand-in"
  bad "the bundle a reviewer reads says the board half came from a cache" "no stand-in"
  bad "a read that was already partial is not frozen into the cache, while a whole one is" "no stand-in"
  bad "and choosing a tracker source says what an outage costs before there is one" "no stand-in"
else
  off_cold="$("${OFSENV[@]}" "$DECK" doctor 2>&1 || true)"
  off_live="$("${OFFENV[@]}" "$DECK" board list --json 2>&1 || true)"
  ofs_live="$("${OFSENV[@]}" "$DECK" board list --json 2>&1 || true)"
  off_warm="$("${OFFENV[@]}" "$DECK" doctor 2>&1 || true)"
  kill $OFF1 $OFF2 2>/dev/null; wait $OFF1 $OFF2 2>/dev/null
  off_dark="$("${OFFENV[@]}" "$DECK" board list --json 2>&1 || true)"
  ofs_dark="$("${OFSENV[@]}" "$DECK" board list --json 2>&1 || true)"

  read_state() {   # <json> — "<n ids> <stale flags>" for whatever the board held
    python3 - <<PY 2>&1 || true
import json
d = json.loads(r'''$1''')
tasks = d.get("tasks") or []
print(len(tasks), ",".join(sorted(str(bool(t.get("stale"))) for t in tasks)) or "-",
      ",".join(sorted(str(isinstance(t.get("cached_at"), (int, float))) for t in tasks)) or "-")
PY
  }
  if [ "$(read_state "$off_dark")" = "1 True True" ]; then
    ok "a tracker board read once is still there when the tracker is not"
  else bad "a tracker board read once is still there when the tracker is not" "$(read_state "$off_dark")"; fi
  if [ "$(read_state "$off_live")" = "1 False False" ]; then
    ok "a live read is never marked as one that came from a cache"
  else bad "a live read is never marked as one that came from a cache" "$(read_state "$off_live")"; fi

  # The age is the half that keeps a cached read from passing for a live one, so
  # the text form has to carry it wherever it lists the task, not only in the
  # `!` line under it.
  off_text="$("${OFFENV[@]}" "$DECK" board show '#41' 2>&1 || true)"
  if printf '%s' "$off_text" | grep -qE "cache [0-9]+[smhd] old"; then
    ok "and every task it serves says it came from a cache, and how old"
  else bad "and every task it serves says it came from a cache, and how old" "$off_text"; fi

  # Readable and unwritable are not the same answer. A claim decided by a record
  # that may be days old prevents nothing, which is the whole of what a claim is
  # for; the read that told a person what is on the board costs nobody anything.
  "${OFFENV[@]}" "$DECK" board show '#41' >/dev/null 2>&1; off_read=$?
  "${OFFENV[@]}" "$DECK" board claim '#41' ana --yes >/dev/null 2>&1; off_claim=$?
  if [ "$off_read" = 0 ] && [ "$off_claim" != 0 ]; then
    ok "a task only the cache holds can be read and cannot be claimed"
  else bad "a task only the cache holds can be read and cannot be claimed" "show=$off_read claim=$off_claim"; fi
  "${OFFENV[@]}" "$DECK" board done '#41' --force --yes >/dev/null 2>&1; off_done=$?
  if [ "$off_read" = 0 ] && [ "$off_done" != 0 ]; then
    ok "nor closed, and --force does not buy past it"
  else bad "nor closed, and --force does not buy past it" "show=$off_read done=$off_done"; fi

  # The outage is invisible by the time a reviewer opens the page, so the page
  # has to carry it: "the board still has it as open" is a different claim when
  # the board was last seen on Tuesday.
  off_bundle="$("${OFFENV[@]}" "$DECK" bundle --task '#41' --json 2>&1 || true)"
  off_cached="$(python3 - <<PY 2>&1 || true
import json
d = json.loads(r'''$off_bundle''')
print((d.get("task") or {}).get("from_cache", "absent"))
PY
)"
  if [ "$off_cached" = "True" ]; then
    ok "the bundle a reviewer reads says the board half came from a cache"
  else bad "the bundle a reviewer reads says the board half came from a cache" "$off_cached"; fi

  # Against the whole read above, not on its own: "the board is empty when the
  # provider is gone" is also what no cache at all looks like, and the claim
  # being made is that the two reads are treated differently.
  if [ "$(read_state "$ofs_live")" = "1 False False" ] && [ "$(read_state "$ofs_dark")" = "0 - -" ] \
     && [ "$(read_state "$off_dark")" = "1 True True" ]; then
    ok "a read that was already partial is not frozen into the cache, while a whole one is"
  else
    bad "a read that was already partial is not frozen into the cache, while a whole one is" \
      "partial live=$(read_state "$ofs_live") dark=$(read_state "$ofs_dark"); whole dark=$(read_state "$off_dark")"
  fi

  # What an outage costs is answerable offline, and it is the part choosing a
  # tracker source never said. Said where the source is chosen, rather than
  # discovered the morning the resolver goes down.
  if printf '%s' "$off_cold" | grep -q "never read here" && printf '%s' "$off_warm" | grep -q "outage still shows it"; then
    ok "and choosing a tracker source says what an outage costs before there is one"
  else
    bad "and choosing a tracker source says what an outage costs before there is one" \
      "cold: $(printf '%s' "$off_cold" | grep -i github | head -1) / warm: $(printf '%s' "$off_warm" | grep -i github | head -1)"
  fi
fi
kill ${OFF1:-} ${OFF2:-} 2>/dev/null
rm -rf "$OFF" "$OFS"

