# ------------------------------------------------------ pack scope, layering
# A collection is layered whether or not anyone calls it that: a shared pack
# under every repository, and one pack per repository on top. These check that
# the layers keep to their own scope and that a collision is refused rather
# than resolved by luck.
note "pack scope and layering"
LW="$(mktemp -d)/ws"; LP="$(mktemp -d)/packs"
mkdir -p "$LW"/{one,two} "$LW/.deck" "$LP"/_repos/one/config "$LP"/_repos/two/{config,rules} "$LP"/_workspaces/all/default/config
cat > "$LW/.deck/workspace.yaml" <<EOF
packs_root: [$LP]
repos:
  one: { path: one, impacts: [] }
  two: { path: two, impacts: [] }
targets: []
EOF
printf 'gates:\n  - { id: build, title: One, from_level: build, per_repo: "true" }\n' > "$LP/_repos/one/config/gates.yaml"
printf 'gates:\n  - { id: build, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/_repos/two/config/gates.yaml"
echo "a convention that belongs to two" > "$LP/_repos/two/rules/local.md"
printf 'rules:\n  - { file: rules/local.md }\n' > "$LP/_repos/two/config/mount.yaml"

SAVED_ROOT="${DECK_ROOT:-}"; SAVED_PACKS_ROOT="${DECK_PACKS_ROOT:-}"
export DECK_ROOT="$LW"; unset DECK_PACKS_ROOT DECK_PACKS
{
  # Two repository packs naming the same ordinary gate id, each auto-scoped by
  # `load_gates()`'s own defaulting to the repository that owns it: there is no
  # repository where the two could ever disagree, so this is not a collision —
  # it used to be refused whole, which is issue #8, reported from a real
  # eight-repository workspace where two Python repositories both drafted
  # `ruff-check`.
  check "two repository packs sharing a gate id, scoped disjointly, load together" "ladder" "$DECK" gate list
  out="$("$DECK" gate list 2>&1)"
  if printf '%s' "$out" | grep -qE '^ +-> +build +One' && printf '%s' "$out" | grep -qE '^ +-> +build +Two'; then
    ok "each repository pack keeps its own version of the gate"
  else bad "each repository pack keeps its own version of the gate" "$out"; fi
  if [ "$(printf '%s' "$out" | grep -cE '^ +over one$')" = 1 ] && [ "$(printf '%s' "$out" | grep -cE '^ +over two$')" = 1 ]; then
    ok "and each runs over the repository that declared it"
  else bad "and each runs over the repository that declared it" "$out"; fi

  printf 'gates:\n  - { id: build, overrides: true, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/_repos/two/config/gates.yaml"
  check "and \`overrides: true\` still works when a pack asks for it explicitly" "Two" "$DECK" gate list

  printf 'gates:\n  - { id: buildtwo, title: Two, from_level: build, per_repo: "true" }\n' > "$LP/_repos/two/config/gates.yaml"
  out="$("$DECK" gate list --repos one 2>&1)"
  if printf '%s' "$out" | grep -q "buildtwo.*skipped"; then ok "a repo pack's gate stays in its own repo"; else bad "a repo pack's gate stays in its own repo" "$out"; fi
  check "and runs for the repository that owns it" "over two" "$DECK" gate list --repos two

  out="$("$DECK" mount --task scope --repos one --dry-run 2>&1)"
  if printf '%s' "$out" | grep -q "local.md"; then bad "a repo pack's rule stays in its own repo" "$out"; else ok "a repo pack's rule stays in its own repo"; fi
  check "and mounts into the repository that owns it" "local.md" "$DECK" mount --task scope --repos two --dry-run

  # ---- named layers, declared order, and directories outside the tree.
  # A domain pack is named after no repository, so it can only arrive through
  # `packs:` in the descriptor. It is deliberately listed AFTER the pack that
  # requires it, so the order below can only come from `requires:`.
  mkdir -p "$LP"/yocto-base/config "$LP"/org-acme/config "$LW/../outside/scripts" "$LW/../outside/tools"
  git -C "$LW/../outside/tools" init -q
  printf 'echo built\n' > "$LW/../outside/scripts/build.sh"; chmod +x "$LW/../outside/scripts/build.sh"
  printf 'gates:\n  - { id: bake, title: Domain, from_level: build, per_repo: "bitbake ${repo.build_target}" }\n' > "$LP/yocto-base/config/gates.yaml"
  printf 'requires:\n  - yocto-base\n' > "$LP/org-acme/config/detect.yaml"
  printf 'gates:\n  - { id: bake, overrides: true, title: Org, per_repo: "${path.scripts}/build.sh ${repo.build_target}" }\n' > "$LP/org-acme/config/gates.yaml"
  cat > "$LW/.deck/workspace.yaml" <<EOF
packs_root: [$LP]
packs: [$LP/org-acme, $LP/yocto-base]
paths:
  scripts: ../outside/scripts
repos:
  one:   { path: one, build_target: img1, impacts: [] }
  two:   { path: two, build_target: img2, impacts: [] }
  tools: { path: ../outside/tools, impacts: [] }
targets: []
EOF
  check "a pack named in the descriptor is loaded" "yocto-base" "$DECK" packs
  out="$("$DECK" packs 2>&1)"
  if [ "$(printf '%s' "$out" | grep -nE '^  [0-9]+  (yocto-base|org-acme)' | head -1 | grep -c yocto-base)" = 1 ]; then
    ok "requires puts a domain pack ahead of what requires it"
  else bad "requires puts a domain pack ahead of what requires it" "$out"; fi
  check "the overlay is reported" "yocto-base -> org-acme" "$DECK" packs
  check "the later layer wins the gate" "Org" "$DECK" gate list --repos one
  check "a path outside the tree resolves in a command" "outside/scripts/build.sh img1" "$DECK" gate run --repos one --dry-run
  check "a repository outside the root resolves" "outside/tools" "$DECK" path tools
  check "declared paths are listed" "scripts" "$DECK" paths

  printf 'requires:\n  - nowhere\n' > "$LP/org-acme/config/detect.yaml"
  check_fail "an unmet pack requirement is a problem" "$DECK" packs
  # doctor exits non-zero here for unrelated reasons — this workspace has no
  # toggle file — so assert on what it says rather than on its status.
  out="$("$DECK" doctor 2>&1)"
  if printf '%s' "$out" | grep -q "not in play"; then ok "and doctor names it"; else bad "and doctor names it" "$out"; fi

  # A name two packs both claim was reported by `deck setup` and by nothing
  # else, while one of the two won on the order `iterdir()` handed the
  # directories back. Both documents say deck reports it and resolves nothing.
  mkdir -p "$LP/_repos/group/one/config"
  printf 'markers: []\n' > "$LP/_repos/group/one/config/detect.yaml"
  dup_packs="$("$DECK" packs 2>&1 || true)"
  if printf '%s' "$dup_packs" | grep -q 'two packs claim `one`'; then
    ok "two packs claiming one repository is reported by deck packs"
  else bad "two packs claiming one repository is reported by deck packs" "$dup_packs"; fi
  dup_doctor="$("$DECK" doctor 2>&1 || true)"
  if printf '%s' "$dup_doctor" | grep -q 'Rename one, or drop it from the collection'; then
    ok "and by the diagnosis, with the edit that resolves it"
  else bad "and by the diagnosis, with the edit that resolves it" "$dup_doctor"; fi
  rm -rf "$LP/_repos/group"
}
export DECK_ROOT="$SAVED_ROOT" DECK_PACKS_ROOT="$SAVED_PACKS_ROOT"
rm -rf "$LW" "$LP"
