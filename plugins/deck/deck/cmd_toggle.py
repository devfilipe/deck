"""Toggle commands: read a decision, explain it, record it, validate the catalog."""

from __future__ import annotations

import json
from pathlib import Path

from .config import STATE_DIR, dump_yaml, load_yaml, norm, task_file
from .toggles import ASK, CHOSEN_AT, Toggles, record_hint, recorded_reasons, repo_values
from .workspace import find_root


def _die(message: str) -> int:
    print(f"deck: {message}")
    return 1


def _write_target(tg: Toggles, scope: str) -> tuple[Path | None, str | None, str | None]:
    """Where a recorded value goes: (file, block within it, refusal).

    Three kinds of place on one axis — this task, this initiative, this
    workspace — so they are one option and not three commands. `block` is None
    for a file's own top-level `values:`, or the name of a scope's sub-block.
    A name that is neither `task`, `workspace`, nor a declared scope comes back
    as a refusal listing the ones that exist, rather than being created: a
    posture recorded for a scope nobody declared would apply to nothing.
    """
    if scope == "task":
        return task_file(tg.root, tg.session), None, None
    if scope == "workspace":
        return tg.root / STATE_DIR / "toggles.yaml", None, None
    declared = tg.descriptor.get("scopes") or {}
    if scope in declared:
        return tg.root / STATE_DIR / "toggles.yaml", scope, None
    known = ", ".join(["task", "workspace", *declared])
    return None, None, f"unknown scope: {scope} (accepts: {known})"


def _where(scope: str, block: str | None) -> str:
    return f"scope {block}" if block else scope


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
    target = data.setdefault("scopes", {}).setdefault(block, {}) if block else data
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
