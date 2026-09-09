note "pack composition"
check "pack toggle is merged"   "api_compat"      "$DECK" toggle explain api_compat
check "pack origin is reported" "all/default"    "$DECK" toggle explain api_compat
if "$DECK" toggle ask-plan --stage verify | grep -q "Sync to the pod"; then
  ok "pack relabels a core toggle"
else
  bad "pack relabels a core toggle"
fi
sed -i 's/    overrides: true//' "$PACK/config/toggles.yaml"
check_fail "collision without overrides is refused" "$DECK" toggle validate
sed -i 's/  - id: deploy_mode/  - id: deploy_mode\n    overrides: true/' "$PACK/config/toggles.yaml"

note "questions"
if [ "$("$DECK" toggle ask-plan --stage verify | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["questions"][0]["id"])')" = "deploy_mode" ]; then
  ok "deploy_mode becomes a question at verify"
else
  bad "deploy_mode becomes a question at verify"
fi
if [ "$("$DECK" toggle get target)" = "10.0.0.4" ]; then
  ok "a single target settles without asking"
else
  bad "a single target settles without asking" "got: $("$DECK" toggle get target)"
fi
if [ "$(DECK_QUESTION_BUDGET=0 "$DECK" toggle ask-plan --stage verify | python3 -c \
        'import json,sys; print(len(json.load(sys.stdin)["questions"]))')" = "0" ]; then
  ok "a zero budget asks nothing"
else
  bad "a zero budget asks nothing"
fi

note "registry importers"
mkdir -p "$WS/.repo/manifests"
cat > "$WS/.repo/manifests/default.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="origin" fetch="ssh://git@example.invalid/"/>
  <default remote="origin" revision="main"/>
  <project name="a.git" path="a"/>
  <project name="b.git" path="b"/>
  <include name="extra.xml"/>
</manifest>
XML
cat > "$WS/.repo/manifests/extra.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest><project name="c.git" path="c" revision="stable"/></manifest>
XML
ln -s manifests/default.xml "$WS/.repo/manifest.xml"

check "repo layout is detected"     "repo"        "$DECK" import
check "manifest includes are read"  "c"           "$DECK" import repo
check "dry run writes nothing"      "Nothing written" "$DECK" import repo
if "$DECK" import repo | grep -q "3 repositories"; then
  ok "three projects across manifest and include"
else
  bad "three projects across manifest and include"
fi
before="$(grep -c 'impacts' "$WS/.deck/workspace.yaml")"
"$DECK" import repo --write >/dev/null
if "$DECK" impact a --json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["impacted"]==["b","c"] else 1)'; then
  ok "authored impacts survive a re-import"
else
  bad "authored impacts survive a re-import"
fi
if [ "$("$DECK" repos | wc -l)" = "3" ]; then
  ok "matching on path does not duplicate entries"
else
  bad "matching on path does not duplicate entries" "got $("$DECK" repos | tr '\n' ' ')"
fi
check_fail "unknown source is refused" "$DECK" import nosuchthing
