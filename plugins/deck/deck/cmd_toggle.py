"""Toggle commands: read a decision, explain it, record it, validate the catalog."""

from __future__ import annotations

import json
from pathlib import Path

from .config import STATE_DIR, dump_yaml, load_yaml, norm, state_root, task_file
from .toggles import ASK, CHOSEN_AT, Toggles, record_hint, recorded_reasons, repo_values
from .workspace import find_root


def _die(message: str) -> int:
    print(f"deck: {message}")
    return 1


def _write_target(tg: Toggles, scope: str) -> tuple[Path | None, str | None, str | None]:
    """Where a recorded value goes: (file, block within it, refusal).

    Four kinds of place on one axis — this task, this initiative, this
    repository, this workspace — so they are one option and not four commands.
    `block` is None for a file's own top-level `values:`, `scopes/<name>` for an
    initiative, or `repos/<name>` for one repository. A name that names none of
    them comes back as a refusal listing the ones that exist, rather than being
    created: a posture recorded for a scope nobody declared applies to nothing.

    `repos:` was readable and unwritable — `layers()` resolved it and no command
    produced it, so a per-repository choice, and its reason, had to be
    hand-edited. A repository and a scope can share a name, so a bare `--at
    <name>` that fits both is refused rather than ranked; `repo:<name>` and
    `scope:<name>` say which, and always work.
    """
    if scope == "task":
        return task_file(tg.root, tg.session), None, None
    if scope == "workspace":
        return state_root(tg.root) / "toggles.yaml", None, None

    declared = tg.descriptor.get("scopes") or {}
    repos = tg.descriptor.get("repos") or {}
    choices = state_root(tg.root) / "toggles.yaml"

    if scope.startswith("repo:"):
        name = scope[len("repo:") :]
        if name not in repos:
            known = ", ".join(repos) or "none"
            return None, None, f"the registry declares no repository `{name}` (declares: {known})"
        return choices, f"repos/{name}", None
    if scope.startswith("scope:"):
        name = scope[len("scope:") :]
        if name not in declared:
            known = ", ".join(declared) or "none"
            return None, None, f"unknown scope: {name} (declared: {known})"
        return choices, f"scopes/{name}", None

    if scope in declared and scope in repos:
        return (
            None,
            None,
            f"`{scope}` is both a declared scope and a repository — say which: "
            f"`--at scope:{scope}` or `--at repo:{scope}`",
        )
    if scope in declared:
        return choices, f"scopes/{scope}", None
    if scope in repos:
        return choices, f"repos/{scope}", None
    known = ", ".join(["task", "workspace", *declared, *(f"repo:{r}" for r in repos)])
    return None, None, f"unknown scope: {scope} (accepts: {known})"


def _where(scope: str, block: str | None) -> str:
    if not block:
        return scope
    kind, _, name = block.partition("/")
    return f"repository {name}" if kind == "repos" else f"scope {name}"


def _record(path: Path, block: str | None, changes: dict, reason: str = "") -> str | None:
    """Merge values (and a profile) into one block of a choices file.

    Returns the reason this write replaced, if there was one. `reason` belongs
    to the value being written, so writing a value without one clears it: a
    sentence left behind by an earlier value would go on justifying a decision
    that is no longer in the file, which is worse than nothing there. The
    caller says so out loud rather than letting it happen quietly.
    """
    data = load_yaml(path)
    data.setdefault("version", 1)
    if block:
        section, _, name = block.partition("/")
        target = data.setdefault(section, {}).setdefault(name, {})
    else:
        target = data
    replaced = None
    for key, value in changes.items():
        if key == "profile":
            target["profile"] = value
            continue
        target.setdefault("values", {})[key] = value
        reasons = target.setdefault("reasons", {})
        replaced = reasons.pop(key, None)
        if reason:
            reasons[key] = reason
    if not target.get("reasons"):
        target.pop("reasons", None)  # an empty map in the file reads as a shape, not as nothing
    _beside_values(target)
    dump_yaml(path, data)
    return replaced


def _beside_values(target: dict) -> None:
    """Keep `reasons:` next to the values it explains rather than at the end.

    This file is read and edited by hand. A reason several blocks away from its
    value is one nobody updates when the value changes.
    """
    if "reasons" not in target or "values" not in target:
        return
    reasons = target.pop("reasons")
    items = list(target.items())
    target.clear()
    for key, value in items:
        target[key] = value
        if key == "values":
            target["reasons"] = reasons


def cmd_list(tg: Toggles, args) -> int:
    rows = []
    for tid, spec in tg.defs.items():
        if not tg.in_stage(tid, args.stage):
            continue
        if args.group and spec.get("group") != args.group:
            continue
        value, source = tg.resolve(tid)
        layers = tg.layers(tid)
        rows.append(
            {
                "id": tid,
                "group": spec.get("group"),
                "title": spec.get("title"),
                "value": value,
                "source": source,
                # Null where nobody wrote one, which is most of them: only the
                # layers deck writes to a file can carry a reason at all. It is
                # in the JSON and not in the table below because a consumer
                # otherwise has to call `explain` once per toggle to find out
                # whether the values it just read were decided or inherited —
                # while the table is a two-column list of what is in force, and
                # a sentence per row would stop it being readable.
                "reason": layers[0][2] if layers else None,
                "risk": spec.get("risk", "low"),
                "origin": spec.get("_origin", "core"),
            }
        )

    if args.json:
        print(
            json.dumps(
                {
                    "workspace": str(tg.root) if tg.root else None,
                    "repo": tg.repo,
                    "scope": tg.scope,
                    "profile": tg.profile_name,
                    "toggles": rows,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"workspace : {tg.root or '(unresolved)'}")
    if tg.repo:
        print(f"repo      : {tg.repo}")
    elif tg.repo_detected:
        print(f"repo      : {tg.repo_detected}  (not in this workspace — no repo overrides apply)")
    else:
        print("repo      : (outside a repository)")
    if tg.scope:
        print(f"scope     : {tg.scope}")
    print(f"profile   : {tg.profile_name}\n")

    groups = tg.catalog.get("groups", {})
    order = sorted({r["group"] for r in rows}, key=lambda g: groups.get(g, {}).get("order", 99))
    for group in order:
        print(f"-- {groups.get(group, {}).get('title', group)}")
        for row in [r for r in rows if r["group"] == group]:
            mark = "?" if row["value"] == ASK else " "
            print(f"  {mark} {row['id']:<22} {row['value']:<14} {row['source']}")
        print()
    print("  ? = will be asked when it matters")
    return 0


def cmd_get(tg: Toggles, args) -> int:
    print(tg.resolve(args.id)[0])
    return 0


def cmd_explain(tg: Toggles, args) -> int:
    tid = args.id
    if tid not in tg.defs:
        return _die(f"unknown toggle: {tid}")
    spec = tg.defs[tid]
    value, source = tg.resolve(tid)

    print(f"{tid} — {spec.get('title')}")
    print(f"  {' '.join((spec.get('summary') or '').split())}\n")
    print(f"  effective  : {value}")
    print(f"  source     : {source}")
    print(f"  defined in : {spec.get('_origin', 'core')}")
    print(f"  risk       : {spec.get('risk', 'low')}")
    print(f"  stages     : {', '.join(spec.get('stage') or [])}")
    if spec.get("depends_on"):
        state = "satisfied" if tg.deps_ok(tid) else "not satisfied"
        print(f"  depends on : {spec['depends_on']} → {state}")
    if spec.get("rationale"):
        print(f"\n  why the toggle exists ({spec.get('_origin', 'core')}):")
        print(f"    {' '.join(spec['rationale'].split())}")

    # Two different sentences by two different authors. The catalog says why
    # anyone has to decide this; only the choices file says why this workspace
    # decided it that way, and a value with nothing here is reported as having
    # nothing rather than borrowing the catalog's paragraph.
    layers = tg.layers(tid)
    if layers and layers[0][0].startswith(CHOSEN_AT):
        origin, chosen, reason = layers[0]
        print(f"\n  why this value was chosen ({origin}):")
        if reason:
            print(f"    {reason}")
        else:
            print("    not recorded — nothing here says whether it was decided or never revisited")
            print(f"    record it with: {record_hint(tid, chosen, origin)}")

    if spec.get("impact"):
        print("\n  impact per value:")
        for key, text in spec["impact"].items():
            print(f"    {key:<14} {' '.join(str(text).split())}")
    print("\n  layers (strongest first):")
    for src, val, reason in layers:
        print(f"    {val:<14} {src}{'   (why recorded)' if reason else ''}")
    return 0


def cmd_set(tg: Toggles, args) -> int:
    if not tg.root:
        return _die("workspace not resolved")
    if args.id not in tg.defs:
        return _die(f"unknown toggle: {args.id}")

    spec = tg.defs[args.id]
    value = norm(args.value)
    allowed = [norm(v) for v in (spec.get("values") or [])]
    if allowed and value != ASK and value not in allowed and not spec.get("values_from"):
        return _die(f"invalid value for {args.id}: {value} (accepts: {', '.join(allowed + [ASK])})")

    # A blank `--why` is a flag someone meant to fill in. Recording it as no
    # reason at all would answer the question the flag exists to ask.
    reason = " ".join((args.why or "").split())
    if args.why is not None and not reason:
        return _die("--why needs a reason: what makes this value right here")

    path, block, refusal = _write_target(tg, args.write_at)
    if refusal:
        return _die(refusal)
    replaced = _record(path, block, {args.id: value}, reason)
    print(f"{args.id} = {value}  ({_where(args.write_at, block)} → {path})")
    if reason:
        print(f"  why: {reason}")
    elif replaced:
        print(f'  dropped the reason recorded here before: "{replaced}"')
        print("  it explained an earlier value — pass --why to record one for this one")
    else:
        print('  no reason recorded — add one with: --why "why this value, here"')
    return 0


def _unset(path: Path, block: str | None, tid: str) -> tuple[bool, str | None]:
    """Remove one toggle's value, and the reason recorded beside it, from one block.

    Reads the file rather than `setdefault`-ing into it: a layer nobody has
    written to must be refused, not created just long enough to discover it was
    empty. Returns (found, reason) — `found` is False when this exact layer
    (not one it inherits from) has nothing recorded for `tid`.

    Mirrors `_record`'s own rule that an empty map reads as a shape, not as
    nothing: `values:` and `reasons:` are dropped once empty rather than left as
    `{}`, and a block left with neither of those and no `profile` is dropped
    from its section in turn — the file ends up exactly as it would have if the
    withdrawn value had never been set, which is what makes hand-editing this
    error-prone in the first place: two maps to keep in step, by hand.
    """
    data = load_yaml(path)
    if block:
        section, _, name = block.partition("/")
        target = (data.get(section) or {}).get(name)
    else:
        target = data
    if not target or tid not in (target.get("values") or {}):
        return False, None

    reasons = target.get("reasons") or {}
    removed_reason = reasons.pop(tid, None)
    target["values"].pop(tid, None)
    if not target["values"]:
        target.pop("values", None)
    if reasons:
        target["reasons"] = reasons
    else:
        target.pop("reasons", None)
    _beside_values(target)

    if block and not target:
        section, _, name = block.partition("/")
        data.get(section, {}).pop(name, None)
        if not data.get(section):
            data.pop(section, None)

    dump_yaml(path, data)
    return True, removed_reason


def cmd_unset(tg: Toggles, args) -> int:
    if not tg.root:
        return _die("workspace not resolved")
    if args.id not in tg.defs:
        return _die(f"unknown toggle: {args.id}")

    path, block, refusal = _write_target(tg, args.write_at)
    if refusal:
        return _die(refusal)
    found, reason = _unset(path, block, args.id)
    if not found:
        return _die(f"nothing recorded for {args.id} at {_where(args.write_at, block)} — nothing to withdraw")

    print(f"{args.id} unset  ({_where(args.write_at, block)} → {path})")
    if reason:
        print(f'  withdrew the recorded reason: "{reason}"')

    # Re-read rather than reuse `tg`: the file `_unset` just wrote is the one
    # this same command is about to report on, and `tg` was built before it
    # changed.
    fresh = Toggles(repo=args.repo, session=args.session, root=tg.root)
    value, source = fresh.resolve(args.id)
    print(f"  now: {value}  ({source})")
    return 0


def cmd_profile(tg: Toggles, args) -> int:
    if not tg.root:
        return _die("workspace not resolved")
    if not args.name:
        for name, profile in tg.profiles.items():
            mark = "*" if name == tg.profile_name else " "
            print(f" {mark} {name:<14} {' '.join((profile.get('summary') or '').split())[:90]}")
        return 0
    if args.name not in tg.profiles:
        return _die(f"unknown profile: {args.name} (available: {', '.join(tg.profiles)})")

    path, block, refusal = _write_target(tg, args.write_at)
    if refusal:
        return _die(refusal)
    _record(path, block, {"profile": args.name})
    profile = tg.profiles[args.name]
    print(f"profile {args.name} ({profile.get('title')}) applied at {_where(args.write_at, block)}")
    print(f"  {' '.join((profile.get('summary') or '').split())}")
    return 0


def cmd_ask_plan(tg: Toggles, args) -> int:
    print(json.dumps(tg.ask_plan(args.stage, args.files or []), ensure_ascii=False, indent=2))
    return 0


def cmd_validate(tg: Toggles, args) -> int:
    errors, warnings = [], []
    seen: set[str] = set()

    for spec in tg.catalog.get("toggles", []):
        tid = spec.get("id", "<no id>")
        origin = spec.get("_origin", "core")
        where = f"{tid} [{origin}]"
        if tid in seen:
            errors.append(f"{where}: duplicate id")
        seen.add(tid)

        if spec.get("group") not in tg.catalog.get("groups", {}):
            errors.append(f"{where}: unknown group {spec.get('group')!r}")
        for stage in spec.get("stage") or []:
            if stage not in tg.catalog.get("stages", []):
                errors.append(f"{where}: unknown stage {stage!r}")

        question = spec.get("question") or {}
        askable = spec.get("askable") is not False
        if askable and not question and not spec.get("options_from") and not spec.get("values_from"):
            errors.append(f"{where}: askable but has no `question` block")
        if question.get("header") and len(question["header"]) > 12:
            errors.append(f"{where}: header is {len(question['header'])} characters (max 12)")
        for option in question.get("options", []):
            if len(str(option.get("label", "")).split()) > 5:
                warnings.append(f"{where}: long label — {option.get('label')!r}")

        values = [norm(v) for v in (spec.get("values") or [])]
        askable_values = [norm(v) for v in (spec.get("askable_values") or values)]
        if len(askable_values) > 4:
            errors.append(f"{where}: {len(askable_values)} askable values (selector fits 4) — use `askable_values`")
        if values and askable and not spec.get("values_from"):
            covered = {norm(o["value"]) for o in question.get("options", [])}
            missing = [v for v in askable_values if v not in covered]
            if missing:
                warnings.append(f"{where}: values with no option: {', '.join(missing)}")

        default = norm(spec.get("default", ""))
        if spec.get("group") == "security" and default == ASK:
            errors.append(f"{where}: a security toggle may not default to `ask`")
        if values and default and default != ASK and default not in values and not spec.get("values_from"):
            errors.append(f"{where}: default {default!r} is not in `values`")

        for dep in spec.get("depends_on") or {}:
            if dep not in tg.defs:
                errors.append(f"{where}: depends_on points at unknown toggle {dep!r}")

    for name, profile in tg.profiles.items():
        for tid, value in (profile.get("values") or {}).items():
            if tid not in tg.defs:
                errors.append(f"profile {name}: unknown toggle {tid!r}")
                continue
            values = [norm(v) for v in (tg.defs[tid].get("values") or [])]
            if values and norm(value) != ASK and norm(value) not in values and not tg.defs[tid].get("values_from"):
                errors.append(f"profile {name}: invalid value for {tid}: {norm(value)!r}")

    if tg.choices:
        blocks = [("values", tg.choices.get("values") or {}, recorded_reasons(tg.choices))]
        blocks += [
            (f"repos.{k}", repo_values(v), recorded_reasons(v)) for k, v in (tg.choices.get("repos") or {}).items()
        ]
        declared_scopes = tg.descriptor.get("scopes") or {}
        for name, recorded in (tg.choices.get("scopes") or {}).items():
            # A posture recorded for a scope nobody declares is a decision that
            # will never apply to anything, which is worse than no decision:
            # someone answered a question and the answer went nowhere.
            if name not in declared_scopes:
                errors.append(
                    f"choices scopes.{name}: no such scope in the descriptor "
                    f"(declared: {', '.join(declared_scopes) or 'none'})"
                )
            profile = (recorded or {}).get("profile")
            if profile and norm(profile) not in tg.profiles:
                errors.append(f"choices scopes.{name}: unknown profile {norm(profile)!r}")
            # Unlike `repos:`, a scope block has never had a flat shape to stay
            # compatible with — the template has always shown `values:` nested
            # beside `reasons:`. A block written flat (`gate_level: build`
            # beside `scopes.<name>:`, the shape the template used to show)
            # would resolve to nothing in `layers()` and say nothing about it;
            # refusing here means the file and the reader can never disagree
            # silently.
            unexpected = sorted(k for k in (recorded or {}) if k not in ("values", "reasons", "profile"))
            if unexpected:
                errors.append(
                    f"choices scopes.{name}: {', '.join(unexpected)} not under `values:` — "
                    f"a scope block nests its toggles as `scopes.{name}.values.<id>` in "
                    f"{STATE_DIR}/toggles.yaml, not flat beside `scopes.{name}:`"
                )
            blocks.append((f"scopes.{name}", (recorded or {}).get("values") or {}, recorded_reasons(recorded)))
        for where, block, reasons in blocks:
            for tid, value in block.items():
                if tid not in tg.defs:
                    errors.append(f"choices {where}: unknown toggle {tid!r}")
                    continue
                values = [norm(v) for v in (tg.defs[tid].get("values") or [])]
                if values and norm(value) != ASK and norm(value) not in values and not tg.defs[tid].get("values_from"):
                    errors.append(f"choices {where}: invalid value for {tid}: {norm(value)!r}")
            # A reason with no value beside it explains a decision this layer
            # does not make. It reads as justification and justifies nothing.
            for tid in reasons:
                if tid not in tg.defs:
                    errors.append(f"choices {where}: reason recorded for unknown toggle {tid!r}")
                elif tid not in block:
                    warnings.append(f"choices {where}: reason for {tid} with no value here — it explains nothing")

    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"ERROR  : {error}")
    if errors:
        print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
        return 1

    packs = sorted({t.get("_origin", "core") for t in tg.catalog["toggles"]} - {"core"})
    extra = f", packs: {', '.join(packs)}" if packs else ""
    print(f"OK — {len(seen)} toggles, {len(tg.profiles)} profiles{extra}, {len(warnings)} warning(s)")
    return 1 if (warnings and args.strict) else 0


def build(repo=None, session=None) -> Toggles:
    return Toggles(repo=repo, session=session, root=find_root())
