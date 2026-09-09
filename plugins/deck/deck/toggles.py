"""The toggle catalog: composition, resolution, and pending questions.

A toggle is a recurring decision declared once instead of renegotiated per task.
It has three states: a fixed value, a value overridden at some layer, and `ask`
— which is not a value but an instruction to ask the operator at the declared
stage, using the question written in the catalog.

The layers, strongest first: the task, the environment, the repository, the
scope, the workspace, the active profile, the catalog default.

The core ships the universal toggles. Everything domain-specific arrives from
extension packs as data, never as code.
"""

from __future__ import annotations

import fnmatch
import os
from pathlib import Path

from .config import ENV_PREFIX, STATE_DIR, core_root, die, load_yaml, norm, pack_dirs, session_id, state_root, task_file
from .workspace import Workspace, current_repo, find_root, pack_name

ASK = "ask"
RISK_ORDER = {"high": 0, "medium": 1, "low": 2}

# Origins deck writes to a file, and which can therefore carry the reason a
# value was chosen. The rest cannot: an environment variable belongs to one
# command, and a profile or a catalog default was not chosen here at all.
CHOSEN_AT = ("task", "workspace", "scope ", "repo ")


def record_hint(tid: str, value: str, origin: str) -> str:
    """How to write down the reason for the layer a value actually came from.

    Lives here rather than beside `toggle explain`, which is where it started:
    the bundle says the same thing to the same person about the same missing
    sentence, and two copies of one instruction drift the first time the flag
    is renamed. Callers guard with `CHOSEN_AT` — there is no way to record a
    reason for an environment variable, and inviting someone to try is worse
    than saying nothing.
    """
    if origin.startswith("repo "):
        # `--at` takes task, workspace and scopes; a repository block is hand-written.
        return f"a `reasons:` entry beside it under `repos: {origin.split(' ', 1)[1]}:` in {STATE_DIR}/toggles.yaml"
    at = origin.split(" ", 1)[1] if origin.startswith("scope ") else origin
    return f'deck toggle set {tid} {value} --at {at} --why "…"'


def recorded_reasons(block: dict | None) -> dict:
    """The `reasons:` map beside a block's values, keyed by toggle id.

    A sibling map rather than a richer value: `values:` stays the two-column
    list a person can hand-edit, an older file with no `reasons:` reads as
    having none instead of half-having them, and no reader that only wants the
    value has to learn a second shape.
    """
    return {str(k): str(v) for k, v in ((block or {}).get("reasons") or {}).items()}


def repo_values(block: dict | None) -> dict:
    """A repository block's values, in either shape it may be written in.

    Repositories have always listed their toggles flat, unlike every other
    block, and files written that way have to keep working. A block that has a
    `values:` key is read the nested way; otherwise `reasons:` is the only key
    in it that is not a toggle id.
    """
    block = block or {}
    if "values" in block:
        return block.get("values") or {}
    return {k: v for k, v in block.items() if k != "reasons"}


def _merge_catalog(base: dict, extra: dict, origin: str) -> dict:
    """Merge one pack's catalog fragment into the accumulated catalog."""
    base.setdefault("groups", {}).update(extra.get("groups") or {})
    for stage in extra.get("stages") or []:
        if stage not in base.setdefault("stages", []):
            base["stages"].append(stage)

    by_id = {t["id"]: t for t in base.setdefault("toggles", [])}
    for spec in extra.get("toggles") or []:
        tid = spec.get("id")
        if not tid:
            die(f"{origin}: toggle without an `id`")
        spec = {**spec, "_origin": origin}
        if tid not in by_id:
            base["toggles"].append(spec)
            by_id[tid] = spec
            continue
        if not spec.get("overrides"):
            die(
                f"{origin}: toggle `{tid}` already exists "
                f"(from {by_id[tid].get('_origin', 'core')}). "
                "Set `overrides: true` to extend it deliberately."
            )
        target = by_id[tid]
        for key, value in spec.items():
            if key in ("id", "overrides"):
                continue
            if key == "question" and isinstance(value, dict):
                target.setdefault("question", {}).update(value)
            else:
                target[key] = value
    return base


class Toggles:
    """Resolves a toggle to a value, and says where the value came from."""

    def __init__(self, repo: str | None = None, session: str | None = None, root: Path | None = None):
        self.core = core_root()
        self.root = root or find_root()
        self.session = session_id(session)

        # Always built, even without a root: DECK_PACKS_ROOT has to work before a
        # descriptor exists, which is exactly when `deck setup` needs it.
        ws = Workspace(self.root)
        self.descriptor = ws.data

        # A scope is a layer, not a filter: an initiative that has decided
        # something for itself has decided it for every repository it holds,
        # and for none outside.
        self.scope = ws.scope_name

        # The directory we are in may be a git repository that has nothing to do
        # with this workspace. Report it, but only let it carry per-repository
        # overrides when the descriptor actually declares it.
        self.repo_detected = repo or current_repo()
        declared = self.descriptor.get("repos") or {}
        self.repo = self.repo_detected if self.repo_detected in declared else None

        catalog = load_yaml(self.core / "config" / "toggles.core.yaml")
        catalog.setdefault("toggles", [])
        for spec in catalog["toggles"]:
            spec.setdefault("_origin", "core")

        self.profiles = (load_yaml(self.core / "config" / "profiles.core.yaml") or {}).get("profiles", {})

        for pack in ws.all_packs() if ws else pack_dirs():
            fragment = load_yaml(pack / "config" / "toggles.yaml")
            if fragment:
                catalog = _merge_catalog(catalog, fragment, pack_name(pack))
            for name, profile in ((load_yaml(pack / "config" / "profiles.yaml") or {}).get("profiles") or {}).items():
                self.profiles.setdefault(name, {}).update(profile)

        if not catalog.get("toggles"):
            die(f"empty or missing catalog at {self.core / 'config' / 'toggles.core.yaml'}")
        self.catalog = catalog
        self.defs = {t["id"]: t for t in catalog["toggles"]}

        self.choices = load_yaml(state_root(self.root) / "toggles.yaml") if self.root else {}
        self.task = load_yaml(task_file(self.root, self.session)) if self.root else {}
        self.scope_choices = ((self.choices.get("scopes") or {}).get(self.scope) or {}) if self.scope else {}
        self.profile_name = norm(
            self.task.get("profile") or self.scope_choices.get("profile") or self.choices.get("profile") or "standard"
        )

    # -- layers -------------------------------------------------------------
    def layers(self, tid: str) -> list[tuple[str, str, str | None]]:
        """(origin, value, reason) from the strongest layer to the weakest.

        `reason` is what whoever recorded the value wrote down about *this*
        choice, and is None where none was recorded — always so for the layers
        nobody chose here. It is not the catalog's `rationale`: that says why
        the toggle exists at all, which is a different sentence and a different
        author, and conflating the two is how a default nobody revisited comes
        to look like a considered decision.
        """
        out: list[tuple[str, str, str | None]] = []

        task_values = self.task.get("values") or {}
        task_reasons = recorded_reasons(self.task)
        if tid in task_values:
            out.append(("task", norm(task_values[tid]), task_reasons.get(tid)))

        env_key = f"{ENV_PREFIX}{tid.upper()}"
        if env_key in os.environ:
            out.append((f"${env_key}", norm(os.environ[env_key]), None))

        # most specific wins: the repository block beats the general one
        if self.repo:
            block = (self.choices.get("repos") or {}).get(self.repo) or {}
            values = repo_values(block)
            if tid in values:
                out.append((f"repo {self.repo}", norm(values[tid]), recorded_reasons(block).get(tid)))

        # Between the repository and the workspace: narrower than "everything we
        # do here", wider than "this one codebase".
        scope_values = self.scope_choices.get("values") or {}
        if tid in scope_values:
            out.append((f"scope {self.scope}", norm(scope_values[tid]), recorded_reasons(self.scope_choices).get(tid)))

        values = self.choices.get("values") or {}
        if tid in values:
            out.append(("workspace", norm(values[tid]), recorded_reasons(self.choices).get(tid)))

        profile = (self.profiles.get(self.profile_name) or {}).get("values") or {}
        if tid in profile:
            out.append((f"profile {self.profile_name}", norm(profile[tid]), None))

        spec = self.defs.get(tid, {})
        if "default" in spec:
            out.append((f"catalog default ({spec.get('_origin', 'core')})", norm(spec["default"]), None))

        return out

    def resolve(self, tid: str) -> tuple[str, str]:
        if tid not in self.defs:
            die(f"unknown toggle: {tid}")
        layers = self.layers(tid)
        if not layers:
            die(f"toggle has neither a value nor a default: {tid}")
        source, value, _ = layers[0]

        # An `ask` that cannot become a real question (a single target, say)
        # settles itself instead of bothering anyone.
        if value == ASK:
            auto = self.autoresolve(tid)
            if auto is not None:
                return auto, f"{source} → resolved automatically"
        return value, source

    def autoresolve(self, tid: str) -> str | None:
        if self.defs[tid].get("values_from") == "workspace.targets":
            targets = self.descriptor.get("targets") or []
            if len(targets) == 1:
                return norm(targets[0].get("host"))
        return None

    # -- options ------------------------------------------------------------
    def options(self, tid: str) -> list[dict]:
        spec = self.defs[tid]
        question = spec.get("question") or {}
        options_from = spec.get("options_from") or question.get("options_from")

        if options_from == "workspace.targets":
            template = spec.get("option_template") or question.get("option_template") or {}
            out = []
            for target in self.descriptor.get("targets") or []:
                fields = {
                    "host": target.get("host", "—"),
                    "role": target.get("role", "target"),
                    "alias": target.get("alias", "—"),
                }
                out.append(
                    {
                        "value": norm(target.get("host")),
                        "label": template.get("label", "{host}").format(**fields),
                        "description": template.get("description", "").format(**fields),
                    }
                )
            return out

        if spec.get("values_from") == "profiles":
            return [
                {
                    "value": name,
                    "label": profile.get("title", name),
                    "description": " ".join((profile.get("summary") or "").split()),
                }
                for name, profile in self.profiles.items()
            ]

        return [
            {"value": norm(o["value"]), "label": o["label"], "description": o.get("description", "")}
            for o in question.get("options", [])
        ]

    # -- filters ------------------------------------------------------------
    def applies(self, tid: str, files: list[str]) -> bool:
        patterns = self.defs[tid].get("applies_to")
        if not patterns or not files:
            return True
        return any(fnmatch.fnmatch(f, p) for f in files for p in patterns)

    def deps_ok(self, tid: str) -> bool:
        for dep, expected in (self.defs[tid].get("depends_on") or {}).items():
            if dep not in self.defs:
                return False
            current, _ = self.resolve(dep)
            wanted = [norm(e) for e in (expected if isinstance(expected, list) else [expected])]
            if current not in wanted:
                return False
        return True

    def in_stage(self, tid: str, stage: str | None) -> bool:
        return True if not stage else stage in (self.defs[tid].get("stage") or [])

    # -- questions ----------------------------------------------------------
    def pending(self, stage: str | None = None, files: list[str] | None = None) -> list[dict]:
        """Toggles that would become a question here, ranked by risk."""
        out = []
        for tid, spec in self.defs.items():
            if spec.get("askable") is False:
                continue
            value, _ = self.resolve(tid)
            if value != ASK or not self.in_stage(tid, stage) or not self.applies(tid, files or []):
                continue
            if not self.deps_ok(tid):
                continue
            options = self.options(tid)
            if len(options) < 2:
                continue  # no real choice is not a question
            question = spec.get("question") or {}
            out.append(
                {
                    "id": tid,
                    "risk": spec.get("risk", "low"),
                    "header": question.get("header", spec.get("title", tid))[:12],
                    "question": question.get("text", spec.get("title")),
                    "multiSelect": False,
                    "options": options,
                }
            )
        out.sort(key=lambda q: RISK_ORDER.get(q["risk"], 3))
        return out

    def ask_plan(self, stage: str, files: list[str] | None = None) -> dict:
        """What to ask now, what to assume, and why."""
        budget = int(self.resolve("question_budget")[0])
        questions = self.pending(stage, files)
        return {
            "stage": stage,
            "repo": self.repo,
            "scope": self.scope,
            "profile": self.profile_name,
            "budget": budget,
            "questions": questions[:budget],
            "assumed": [
                {
                    "id": q["id"],
                    "value": self.autoresolve(q["id"]) or norm(self.defs[q["id"]].get("default")),
                    "reason": "question budget exhausted",
                }
                for q in questions[budget:]
            ],
        }
