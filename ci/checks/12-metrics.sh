note "measurements over time"
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: counted
    title: Counted
    from_level: static
    per_repo: "echo 'progress: 3 warnings'; echo '${repo.name}: 7 warnings, 91.5% coverage'"
    measures:
      - { id: warnings, title: warnings,     pattern: '(\d+) warnings',       unit: warnings, better: lower }
      - { id: coverage, title: line coverage, pattern: '([0-9.]+)% coverage', unit: '%',      better: higher }
      - { id: absent,   title: never printed, pattern: 'nothing prints (\d+)' }
YAML

out="$("$DECK" gate run --task M1 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "warnings     7 warnings"; then ok "a gate measures a number out of its own output"; else bad "a gate measures a number out of its own output" "$out"; fi
# "progress: 3 warnings" is printed before the summary, so first-match would
# record the number from the middle of the work.
if printf '%s' "$out" | grep -q "warnings     7"; then ok "the last match wins, so a progress line does not become the sample"; else bad "the last match wins" "$out"; fi
if printf '%s' "$out" | grep -q "coverage     91.5 %"; then ok "a decimal is recorded as measured"; else bad "a decimal is recorded as measured" "$out"; fi
if printf '%s' "$out" | grep -q "absent       not measured"; then ok "a pattern that matched nothing is not measured, never zero"; else bad "a pattern that matched nothing is not measured" "$out"; fi
# Two repositories (a, and b through the impact edge) and two metrics that
# matched: the third matched nothing and contributes no sample at all.
if printf '%s' "$out" | grep -q "4 measurement(s) added"; then ok "only what was measured joins the series"; else bad "only what was measured joins the series" "$out"; fi

# One file per repository. Interleaving them would make "first against last" a
# comparison between two different things.
if [ -f "$WS/.deck/metrics/counted.warnings@a.jsonl" ] && [ -f "$WS/.deck/metrics/counted.warnings@b.jsonl" ]; then
  ok "the series lives under .deck/metrics, one file per repository"
else
  bad "the series lives under .deck/metrics, one file per repository"
fi
out="$("$DECK" metrics show counted.warnings --repo b 2>&1)"
if printf '%s' "$out" | grep -q "a trend needs a second"; then ok "one sample is reported as one sample, not as a trend"; else bad "one sample is reported as one sample" "$out"; fi

# The number moves. Nothing about the gate changes: it still passes.
sed -i 's/7 warnings, 91.5% coverage/9 warnings, 88.0% coverage/' "$PACK/config/gates.yaml"
out="$("$DECK" gate run --task M2 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "was 7 on M1"; then ok "a run is reported against the sample before it"; else bad "a run is reported against the sample before it" "$out"; fi
if printf '%s' "$out" | grep -q "1 gate(s) passed"; then ok "and the gate still passes, which is the point"; else bad "and the gate still passes" "$out"; fi

out="$("$DECK" metrics list 2>&1)"
if printf '%s' "$out" | grep -q "moving the wrong way"; then ok "the trend names the direction the pack declared as worse"; else bad "the trend names the direction" "$out"; fi
if printf '%s' "$out" | grep -q "no sample yet"; then ok "a metric declared and never measured says so"; else bad "a metric declared and never measured says so" "$out"; fi
out="$("$DECK" metrics show counted.coverage --repo a 2>&1)"
if printf '%s' "$out" | grep -q "M1"; then ok "every sample is shown with the run it came from"; else bad "every sample is shown with the run it came from" "$out"; fi
if printf '%s' "$out" | grep -q "91.5 -> 88"; then ok "and the series is first against last, in the unit it was measured in"; else bad "and the series is first against last" "$out"; fi
check_fail "an unknown metric is refused, with the known ones listed" "$DECK" metrics show nope.nope

# The finding a threshold cannot produce: everything passed, and it is worse.
out="$("$DECK" bundle --task M2 2>&1 || true)"
if printf '%s' "$out" | grep -q "passing and getting worse"; then ok "a bundle qualifies a passing task whose numbers slid"; else bad "a bundle qualifies a passing task whose numbers slid" "$out"; fi
if printf '%s' "$out" | grep -q "what was measured"; then ok "and carries the measurements beside the gates"; else bad "and carries the measurements beside the gates" "$out"; fi

# Where the series lives is a decision, and one of its values is `nowhere`.
"$DECK" toggle set --at workspace metrics_store off >/dev/null
out="$("$DECK" gate run --task M4 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q 'metrics_store is `off`'; then ok "metrics_store off measures and keeps nothing, and says so"; else bad "metrics_store off says so" "$out"; fi
if printf '%s' "$out" | grep -q "warnings     9"; then ok "and the run still prints the number it measured"; else bad "and the run still prints the number" "$out"; fi

"$DECK" toggle set --at workspace metrics_store shared >/dev/null
out="$("$DECK" gate run --task M5 --repos a --level static --only counted 2>&1)"
if printf '%s' "$out" | grep -q "declares no \`metrics_dir:\`"; then ok "shared with nowhere declared is refused, not written per machine"; else bad "shared with nowhere declared is refused" "$out"; fi
if printf '%s' "$out" | grep -q "Add \`metrics_dir:"; then ok "and the refusal carries the edit that resolves it"; else bad "and the refusal carries the edit" "$out"; fi

printf 'metrics_dir: %s\n' "$WS/shared-metrics" >> "$WS/.deck/workspace.yaml"
"$DECK" gate run --task M6 --repos a --level static --only counted >/dev/null 2>&1
if [ -f "$WS/shared-metrics/counted.warnings@a.jsonl" ]; then ok "with a directory declared the series goes there instead"; else bad "with a directory declared the series goes there instead"; fi
"$DECK" toggle set --at workspace metrics_store workspace >/dev/null

# A pack that declares a measurement badly is refused at load, not at read time:
# a sample silently dropped leaves a hole, and a hole reads like stability.
cp "$PACK/config/gates.yaml" "$WS/gates.backup"
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: mismeasured
    title: Mismeasured
    from_level: static
    per_repo: "echo 1"
    measures:
      - { id: coverage, pattern: '(' }
YAML
check_fail "a measure whose pattern is not a regular expression is refused" "$DECK" metrics list
cp "$WS/gates.backup" "$PACK/config/gates.yaml"

# `applicable()` reads a gate with no `from_level` as the first rung and runs it
# there, but `record()` filed what the gate declared, which was nothing. The gate
# came back belonging to no rung, where `rung_completed()` could neither credit
# it nor stop on it. The plan now decides the rung once and the record files that.
note "a gate declared without a rung is placed on one"
cp "$PACK/config/gates.yaml" "$WS/gates.backup"
printf '  - { id: unrung, title: Unrung, per_repo: "echo unrung ${repo.name}" }\n' >> "$PACK/config/gates.yaml"

plan="$("$DECK" gate list --repos a --json 2>&1)"
rung="$(printf '%s' "$plan" | python3 -c "
import json, sys
print(next(g.get('from_level') for g in json.load(sys.stdin)['gates'] if g['id'] == 'unrung'))
" 2>&1)"
if [ "$rung" = "static" ]; then
  ok "the plan places a gate with no from_level on the first rung"
else
  bad "the plan places a gate with no from_level on the first rung" "$rung"
fi

"$DECK" gate run --task UR1 --repos a --level static --only unrung >/dev/null 2>&1
filed="$(python3 -c "
import json
print(*[repr(g['from_level']) for g in json.load(open('$WS/.deck/gates/UR1.json'))['gates']])
" 2>&1)"
if [ "$filed" = "'static'" ]; then
  ok "and the evidence files it at the rung it ran on, not at null"
else
  bad "and the evidence files it at the rung it ran on, not at null" "$filed"
fi

# The other half of the decision, and a guard: a `from_level` written and left
# empty is a line its author did not finish. Reading it as static would place a
# gate on a rung nobody chose, which is the guess this program refuses to make.
cat >> "$PACK/config/gates.yaml" <<'YAML'
  - id: halfway
    title: Halfway
    from_level:
    per_repo: "true"
YAML
half="$("$DECK" gate list --repos a 2>&1)"
if printf '%s' "$half" | grep -A1 "halfway" | grep -q "is not a rung of this ladder"; then
  ok "a from_level written and left empty is still refused, not placed for the author"
else
  bad "a from_level written and left empty is still refused, not placed for the author" "$half"
fi
cp "$WS/gates.backup" "$PACK/config/gates.yaml"

# #35 — a gate can read the declared impact graph (`${repo.impacts}`), and
# nothing anywhere showed it. Its own temp dir, its own workspace: a producer
# repository declares `impacts: [consumer]`, and a gate compares that against
# something this made-up domain can observe — whether the consumer's source
# actually imports the producer — the way a real pack would with
# `import-linter`, `go list`, `madge` or a grep over includes.
note "the declared graph, checked against something observed"
GC="$(mktemp -d)/ws"
mkdir -p "$GC/.deck" "$GC/producer" "$GC/consumer/src" "$GC/pk/_repos/producer/config"
git -C "$GC/producer" init -q 2>/dev/null
git -C "$GC/consumer" init -q 2>/dev/null
cat > "$GC/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  producer: { path: producer, impacts: [consumer] }
  consumer: { path: consumer, impacts: [] }
packs_root:
  - pk
YAML
printf 'markers: []\n' > "$GC/pk/_repos/producer/config/detect.yaml"
cat > "$GC/pk/_repos/producer/config/gates.yaml" <<'YAML'
gates:
  - id: graph-check
    title: declared impact confirmed by an observed import
    from_level: static
    per_repo: |
      echo "impacts=${repo.impacts}"
      if grep -rq "import producer" "${deck.root}/${workspace.repos.consumer.path}"; then
        echo "confirmed by a real import"
      else
        echo "declared impacts=${repo.impacts}, but consumer does not import producer -- the graph is stale" >&2
        exit 1
      fi
YAML

# The rendered form matters on its own. `impacts:` is a list, and a gate
# command that has to fight through a Python `repr` — quotes and all — before
# it can grep for the name is a mechanism nobody reaches for. This is what the
# issue's own measured probe showed: `impacts=[some-consumer]`, no per-item
# quotes, plain enough for a shell.
check "the declared edge substitutes as plain text a shell can grep for" \
  "impacts=[consumer]" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GC" "$DECK" gate run --repos producer --level static --only graph-check --dry-run

echo "import producer" > "$GC/consumer/src/app.py"
check "a declared edge still backed by a real import passes" "1 gate(s) passed" \
  env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GC" "$DECK" gate run --task GX1 --repos producer --level static

# `impacts:` was right when somebody wrote it, and nothing had ever noticed it
# stop being true. Break the one thing the edge was standing on and rerun.
rm -f "$GC/consumer/src/app.py"
stale="$(env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$GC" "$DECK" gate run --task GX2 --repos producer --level static 2>&1 || true)"
if printf '%s' "$stale" | grep -qF "the graph is stale"; then
  ok "and a declared edge nothing confirms any more fails the gate, instead of ageing silently"
else
  bad "and a declared edge nothing confirms any more fails the gate, instead of ageing silently" "$stale"
fi
rm -rf "$GC"
