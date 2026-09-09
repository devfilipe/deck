# ------------------------------- where an initiative lives, beyond its board
note "where an initiative lives, beyond its board"
# A scope carried its repositories, its posture and its board, and a board is
# one of several places a formal initiative lives. The documentation space, the
# view the team reads every morning, the register somebody updates had nowhere
# to be written, so they stayed in one person's head and were re-asked every
# time somebody joined. `lives_in:` is that place. deck follows none of them —
# what it does is resolve the entry, so what is stored is never free text
# nobody ever looked at.
LI="$(mktemp -d)"; mkdir -p "$LI/.deck" "$LI"/{api,srv} "$LI/docs"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$LI/.deck/toggles.yaml"
printf 'the payments handbook\n' > "$LI/docs/payments.md"
cat > "$LI/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  api: { path: api, impacts: [] }
  srv: { path: srv, impacts: [] }
targets: []
scopes:
  pay:
    title: Payments migration
    repos: [api, srv]
    lives_in:
      - { type: view, url: "https://tracker.example.invalid/acme/api/-/boards/42" }
      - { type: handbook, file: docs/payments.md }
  bare:
    title: Records none
    repos: [api]
YAML
LIENV=(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LI")

li_one="$("${LIENV[@]}" "$DECK" scope pay --json 2>&1 || true)"
li_places="$(python3 - <<PY 2>&1 || true
import json
row = json.loads(r'''$li_one''')
places = row.get("lives_in", "absent")
print("absent" if places == "absent" else " ".join(sorted(p.get("url") or p.get("file") for p in places)))
PY
)"
if [ "$li_places" = "docs/payments.md https://tracker.example.invalid/acme/api/-/boards/42" ]; then
  ok "a scope records where its initiative lives, and the report carries every place"
else bad "a scope records where its initiative lives, and the report carries every place" "$li_places"; fi

# The board stays the board. A place deck only records must not arrive in the
# field a command reads tasks from, or the next outage is a board it tried to
# fetch from a wiki.
li_board="$("${LIENV[@]}" "$DECK" board list 2>&1 || true)"
if printf '%s' "$li_board" | grep -q "tracker.example.invalid"; then
  bad "and a place deck only records is not read as a board source" "$li_board"
else ok "and a place deck only records is not read as a board source"; fi

# Nothing is said about a scope that records none. A tool that accuses a team of
# not filling in an optional field is one they learn to stop reading.
li_all="$("${LIENV[@]}" "$DECK" scopes --json 2>&1 || true)"
li_quiet="$(python3 - <<PY 2>&1 || true
import json
d = json.loads(r'''$li_all''')
print(f"problems={len(d.get('problems') or [])} bare={[p for p in (d.get('problems') or []) if 'bare' in p]}")
PY
)"
if [ "$li_quiet" = "problems=0 bare=[]" ]; then
  ok "and a scope that records none is accused of nothing"
else bad "and a scope that records none is accused of nothing" "$li_quiet"; fi

# The other half of "typed entries rather than a bag of strings": four shapes
# deck cannot resolve, each named, and none of them printed as if it were a
# place somebody could follow.
LIB="$(mktemp -d)"; mkdir -p "$LIB/.deck" "$LIB/api"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$LIB/.deck/toggles.yaml"
cat > "$LIB/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  api: { path: api, impacts: [] }
targets: []
scopes:
  vague:
    title: Points nowhere
    repos: [api]
    lives_in:
      - { type: docs, url: "the wiki" }
      - { type: notes, file: docs/never-written.md }
      - { url: "https://example.invalid/x" }
      - ask Dana
YAML
LIBENV=(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LIB")
check_fail "a place deck cannot resolve is refused rather than stored" \
  "${LIBENV[@]}" "$DECK" scopes
lib_json="$("${LIBENV[@]}" "$DECK" scopes --json 2>&1 || true)"
lib_shape="$(python3 - <<PY 2>&1 || true
import json
d = json.loads(r'''$lib_json''')
row = (d.get("scopes") or [{}])[0]
print(f"problems={len(d.get('problems') or [])} printed={row.get('lives_in', 'absent')}")
PY
)"
if [ "$lib_shape" = "problems=4 printed=[]" ]; then
  ok "each unresolvable entry is named, and none of them is printed as a place"
else bad "each unresolvable entry is named, and none of them is printed as a place" "$lib_shape"; fi

# It travels the way the board already does: a team shares the carve-up AND
# where the initiative lives by cloning the pack, not by asking whoever set it
# up first.
env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LI" "$DECK" pack new lived --dir "$LI/pk" --from-workspace >/dev/null 2>&1 || true
li_seeded="$(python3 - "$LI/pk/templates/workspace/workspace.yaml" <<'PY' 2>&1 || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
places = ((d.get("scopes") or {}).get("pay") or {}).get("lives_in") or []
print(" ".join(sorted(p.get("url") or p.get("file") for p in places if isinstance(p, dict))))
PY
)"
# The round trip, not the file: a template that carries a key nothing reads at
# the other end has shared nothing. So the seeded descriptor becomes somebody
# else's workspace and is asked the question the first one answered.
LIR="$(mktemp -d)"; mkdir -p "$LIR/.deck" "$LIR"/{api,srv} "$LIR/docs"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$LIR/.deck/toggles.yaml"
printf 'the payments handbook\n' > "$LIR/docs/payments.md"
cp "$LI/pk/templates/workspace/workspace.yaml" "$LIR/.deck/workspace.yaml" 2>/dev/null || true
lir_json="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$LIR" "$DECK" scope pay --json 2>&1 || true)"
lir_places="$(python3 - <<PLACES 2>&1 || true
import json
try:
    row = json.loads(r'''$lir_json''')
except ValueError:
    print("not a scope"); raise SystemExit
places = row.get("lives_in", "absent")
print("absent" if places == "absent" else " ".join(sorted(p.get("url") or p.get("file") for p in places)))
PLACES
)"
if [ "$li_seeded" = "docs/payments.md https://tracker.example.invalid/acme/api/-/boards/42" ] \
   && [ "$lir_places" = "$li_seeded" ]; then
  ok "and it travels into a pack with the scope, and reads back on the next machine"
else
  bad "and it travels into a pack with the scope, and reads back on the next machine" \
    "seeded=$li_seeded read back=$lir_places"
fi
rm -rf "$LI" "$LIB" "$LIR"

# ------------------------------- a board that lives in a tracker, with no network
