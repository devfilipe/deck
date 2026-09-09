"""The gate ladder: declared by packs, executed and recorded by the engine.

A gate is a rung of verification. The engine knows the shape of a ladder — which
rungs apply, in what order, over which repositories, and what counts as evidence
— and nothing about what the commands do. `npm run lint`, `bitbake`, `helm
upgrade` and `pytest` are all the same thing from here: a string a pack wrote.

The ladder's rungs are the values of the `gate_level` toggle, so a pack that
inserts a rung does it by extending that toggle rather than by touching this
file.

Three properties matter more than features:

    a gate that did not run is never reported as passed
    a command with an unresolved variable does not run at all
    every run leaves evidence on disk, whether it passed or failed
"""

from __future__ import annotations

import json
import re
import shlex
import subprocess
import time
from pathlib import Path

from . import metrics as metric_lib
from .config import die, load_yaml, norm, state_root
from .toggles import Toggles
from .workspace import Workspace, pack_name

VAR = re.compile(r"\$\{([a-z_]+)\.([a-zA-Z0-9_.]+)\}")

PASSED, FAILED, SKIPPED, BLOCKED = "passed", "failed", "skipped", "blocked"

# `skipped` covers two different facts and a reader must not confuse them: a gate
# that does not apply here (its command resolves to nothing for this repository)
# and a gate that does apply but the ladder stopped before reaching it. Only the
# second one is still owed.
STOPPED_EARLY = "an earlier gate failed"
DEFAULT_TIMEOUT = 1800


def gates_dir(root: Path) -> Path:
    return state_root(root) / "gates"


def gate_scope(gate: dict, pack: Path, ws: Workspace, owner: dict[Path, str]) -> list[str] | None:
    """The repositories a gate declared by this pack would reach, before any
    override changes it. `None` means unbounded — every repository in the
    registry — which is the ordinary case for a pack that speaks for nobody in
    particular.

    This is the same defaulting `load_gates()` applies the first time it sees
    an id — a pack named after a repository speaks for that repository, and a
    pack bound to an initiative speaks for its scope — pulled out so a second
    reader (`deck packs`, deciding whether two packs declaring the same id can
    coexist) asks the engine's own question instead of a cheaper one that could
    answer differently.
    """
    if gate.get("only_repos"):
        return list(gate["only_repos"])
    scope = owner.get(pack.resolve())
    if scope:
        return [scope]
    if ws.pack_scope(pack):
        return list(ws.scope_repos())
    return None


def gates_disjoint(a: list[str] | None, b: list[str] | None) -> bool:
    """Whether two gate scopes can never reach the same repository.

    `None` is unbounded — every repository in the registry — and unbounded is
    never disjoint from anything, including another `None`: there is always at
    least the repositories both would reach. Two concrete lists are disjoint
    only when they share no repository.
    """
    if a is None or b is None:
        return False
    return not (set(a) & set(b))


def load_gates(ws: Workspace) -> list[dict]:
    """Every gate every pack declares, merged.

    Two rules, both taken from how the toggle catalog already merges, so that a
    reader does not have to learn the mechanism twice.

    A gate declared by a pack named after a repository defaults to that
    repository. The pack says how *that* codebase is built, and its `build`
    gate silently running against a sibling is an efficient way to fail a
    delivery for a reason nobody can locate.

    A second pack reusing an `id` has to say `overrides: true` — UNLESS the two
    gates are provably scoped to disjoint repositories, in which case they are
    two gates that happen to share a name, not one name two packs are fighting
    over. This is what lets `deck propose pack` draft `ruff-check` in every
    Python repository's own pack without a person renaming one by hand: two
    repository packs each default their gate to their own repository, so there
    is no repository where the two would disagree and nothing to decide.

    A collision that is NOT provably disjoint — an unscoped gate and a scoped
    one, or two scopes that overlap — still has to say `overrides: true`. Two
    gates answering to one name over the same repository is not something
    anyone meant, and quietly running both — which is what this did before —
    costs the time of the slower one and reports under a name that no longer
    identifies which ran.
    """
    gates: list[dict] = []
    by_id: dict[str, dict] = {}
    # Every gate registered under an id so far, disjoint-coexisting ones
    # included, so a THIRD pack reusing the id is checked against all of them
    # and not only the first. `by_id` keeps pointing at the first one, which is
    # still what an `overrides:` targets — unaffected by how many gates now
    # answer to the plain id.
    variants: dict[str, list[dict]] = {}
    owner = ws.pack_owner()

    for pack in ws.all_packs():
        fragment = load_yaml(pack / "config" / "gates.yaml")
        for gate in fragment.get("gates") or []:
            gid = gate.get("id")
            if not gid:
                die(f"{pack_name(pack)}: a gate has no `id`")
            gate = {**gate, "_pack": pack_name(pack)}

            if gid not in by_id:
                gate["only_repos"] = gate_scope(gate, pack, ws, owner)
                gates.append(gate)
                by_id[gid] = gate
                variants[gid] = [gate]
                continue

            if not gate.get("overrides"):
                gate["only_repos"] = gate_scope(gate, pack, ws, owner)
                if all(gates_disjoint(gate["only_repos"], other.get("only_repos")) for other in variants[gid]):
                    # Provably disjoint: this pack's gate and every other gate
                    # already answering to this id can never run over the same
                    # repository. Coexist rather than refuse — the id is still
                    # shared, `deck gate list` and evidence keep them apart by
                    # the repository each one covers.
                    gates.append(gate)
                    variants[gid].append(gate)
                    continue
                die(
                    f"{pack_name(pack)}: gate `{gid}` already exists "
                    f"(from {by_id[gid].get('_pack', 'core')}). "
                    "Set `overrides: true` to extend it deliberately."
                )
            target = by_id[gid]
            origin = target.get("_pack")
            scope = owner.get(pack.resolve())
            if scope and not gate.get("only_repos"):
                # A pack named after a repository speaks FOR that repository,
                # and it says so twice: once when it introduces a gate — which
                # already defaults to `only_repos: [<that repo>]` — and once
                # when it overrides one. The two paths disagreed, and only the
                # override path widened: one repository's `build` replaced the
                # shared `build` for all four, silently.
                #
                # Specialised rather than replaced. The overriding pack gets a
                # copy of the shared gate with its own changes, narrowed to its
                # repository; the shared gate keeps running everywhere else,
                # which is the ordinary case this made impossible — everybody
                # builds, and one repository builds differently.
                #
                # A pack NOT named after a repository still changes the gate
                # workspace-wide, unchanged: it speaks for everybody, so its
                # override applies to everybody. Writing `only_repos:` on the
                # override is how a repository pack says something wider on
                # purpose.
                special = {**target}
                for key, value in gate.items():
                    if key in ("id", "overrides", "_pack"):
                        continue
                    special[key] = value
                special["only_repos"] = [scope]
                special["_pack"] = f"{origin} + {pack_name(pack)}"
                # The shared gate keeps its own reach minus this repository.
                # `only_repos` cannot say "all except one" — absent means all —
                # so the exclusion is its own field.
                target["_excluded"] = sorted(set(target.get("_excluded") or []) | {scope})
                gates.append(special)
                by_id[f"{gid}\t{scope}"] = special
                variants[gid].append(special)
                continue
            for key, value in gate.items():
                if key in ("id", "overrides", "_pack"):
                    continue
                target[key] = value
            target["_pack"] = f"{origin} + {pack_name(pack)}"
    return gates


def ladder(tg: Toggles) -> list[str]:
    """The rungs, weakest first, from the gate_level toggle's own values."""
    spec = tg.defs.get("gate_level") or {}
    return [norm(v) for v in (spec.get("values") or [])]


def _dotted(data: dict, path: str):
    node = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _render(value) -> str:
    """A substituted value, as a gate command should see it.

    `${repo.impacts}` and `${repo.couples}` are lists, and `str(list)` renders
    one the way Python reads it back — `['some-consumer']`, quotes and all.
    That is fine for a REPL and wrong for a shell string: the quotes are not
    the pack's to escape, and a command built to grep for the name has to know
    to strip them first. A gate exists to compare this declared edge against
    something observed (#35), and a pack should be able to do that with the
    tools its domain already has — `grep`, a shell `case`, a split on `, ` —
    not with a Python literal reader it did not ask for.
    """
    if isinstance(value, list):
        return "[" + ", ".join(str(v) for v in value) + "]"
    return str(value)


def resolve(command: str, ws: Workspace, tg: Toggles, repo: str | None, target: dict | None) -> tuple[str, list[str]]:
    """Substitute ${scope.name}. Returns (command, names that did not resolve).

    An unresolved variable is not filled with an empty string. A command with a
    hole in it either fails confusingly or, worse, succeeds while doing
    something other than what was meant.
    """
    missing: list[str] = []

    def replace(match: re.Match) -> str:
        scope, name = match.group(1), match.group(2)
        value = None
        if scope == "repo" and repo:
            entry = {**ws.repos.get(repo, {}), "name": repo, "abspath": str(ws.repo_path(repo))}
            value = _dotted(entry, name)
        elif scope == "toggle":
            value = tg.resolve(name)[0] if name in tg.defs else None
        elif scope == "workspace":
            value = _dotted(ws.data, name)
        elif scope == "target" and target:
            value = target.get(name)
        elif scope == "path":
            found = ws.paths.get(name)
            value = str(found) if found else None
        elif scope == "deck" and name == "root":
            value = str(ws.root)
        if value is None or value == "":
            missing.append(match.group(0))
            return match.group(0)
        return _render(value)

    return VAR.sub(replace, command), missing


# Interpreters a gate command commonly names its script through. Only the file
# named right after one of these, or a bare program invoked by its own path, is
# checked for existence below — an argument like a build directory or a lint
# target is not, because plenty of those are legitimately absent (a `mkdir`
# target, a report a gate is about to write) and flagging them would refuse
# gates that have always worked.
_INTERPRETERS = {"python", "python3", "python2", "bash", "sh", "zsh", "node", "ruby", "perl", "pwsh"}
_SHELL_OPERATORS = re.compile(r"&&|\|\||;|\|")


# An interpreter's flags, split by whether what follows them can be a path at
# all. `-c` and `-m` are followed by code and by a module name; every other
# option is the interpreter's own and the script is further along.
_CODE_FLAGS = {"-c", "-m"}


def _script_after(tokens: list[str]) -> str | None:
    """The script an interpreter is being handed, or None when it is not one.

    Reading `tokens[1]` blindly is wrong the moment anyone writes the most
    ordinary Python invocation there is: `python3 -m pytest` named `-m` as its
    script, and every gate written that way was reported as resolving to a
    file that does not exist — a gate blocked for a path it never had.
    """
    for token in tokens[1:]:
        if token in _CODE_FLAGS:
            return None  # code or a module follows, never a path on disk
        if token.startswith("-"):
            continue  # an option of the interpreter, not the script
        return token
    return None


def _missing_script(command: str, cwd: Path) -> str | None:
    """The first script this resolved command names that is not on disk.

    `${deck.root}` and friends resolve to a real directory every time — the
    root itself always exists — so `resolve()` never sees a hole here. What can
    still be wrong is what a pack author appended to it: a manifest workspace
    puts the root one level above the repository a pack was written for, and
    `${deck.root}/packs/_workspace/bin/x.py` resolves to a path that is simply
    not there. Nothing catches that today except the subprocess deck spawns to
    run it — which fails, but only after the run started, in a message buried
    in a log file, and never on `--dry-run`, which is exactly when a broken
    path should be cheapest to see.

    A token is checked only when the command names it directly: the script an
    interpreter is handed, or the command's own first word when that word
    contains a `/`. An interpreter's options are not that script, and `-c` and
    `-m` mean there is no script at all — see `_script_after`. A raw `$VAR` or
    a glob is left alone too: those need a real shell to expand, and checking
    the literal text would be checking the wrong thing.
    """
    for segment in _SHELL_OPERATORS.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue  # unbalanced quoting: not this function's job to judge
        if not tokens:
            continue
        program = tokens[0]
        if program in _INTERPRETERS and len(tokens) > 1:
            candidate = _script_after(tokens)
            if candidate is None:
                continue
        elif "/" in program:
            candidate = program
        else:
            continue
        if "$" in candidate or "*" in candidate or "~" in candidate:
            continue  # shell expands this; the literal text is not the path
        path = Path(candidate)
        if not (path if path.is_absolute() else cwd / path).exists():
            return candidate
    return None


def invokes(command: str) -> list[str]:
    """What a command names as the thing it runs, once per shell segment.

    The same reading `_missing_script` uses one function up, and for the same
    reason: the only token a command names directly is the file after a known
    interpreter, or its own first word. Everything else is an argument, and a
    `$VAR` or a glob names nothing at all until a shell expands it.

    This says nothing about what the program does — `ruff`, `bitbake` and
    `helm` are all just strings here. It is the workspace's own gates that
    make a name mean something, which is why `pack review` can ask whether a
    rule is repeating the ladder without the engine learning any tooling.
    """
    names = []
    for segment in _SHELL_OPERATORS.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            continue  # unbalanced quoting: not this function's job to judge
        if not tokens:
            continue
        program = tokens[0]
        if program in _INTERPRETERS and len(tokens) > 1:
            # The same `-m`/`-c` reading `_missing_script` needs: without it a
            # gate written `python3 -m pytest` registers `-m` as the program
            # it runs, and the ladder index below answers for a flag.
            script = _script_after(tokens)
            if script is None:
                continue
            program = script
        if "$" in program or "*" in program or program.endswith("/"):
            continue
        name = program.rsplit("/", 1)[-1]
        if name:
            names.append(name)
    return names


def applicable(ws: Workspace, tg: Toggles, repos: list[str], level: str | None = None) -> list[dict]:
    """Which gates run for this change, and for the ones that do not, why."""
    rungs = ladder(tg)
    wanted = level or tg.resolve("gate_level")[0]
    reach = rungs.index(wanted) if wanted in rungs else len(rungs) - 1

    plan = []
    for gate in load_gates(ws):
        # The rung is decided once, here, and written back onto the entry the
        # run then carries to `record()`. A gate declared without a
        # `from_level` runs at the first rung, and filing it under the key it
        # did not declare — null — put it on no rung at all, where
        # `rung_completed()` could neither credit it nor stop on it.
        #
        # A `from_level` that is present but empty is deliberately not filled
        # in: that is a line its author started and did not finish, and it goes
        # down the blocked path below rather than onto a rung deck chose for it.
        rung = gate.get("from_level", "static")
        entry = {**gate, "from_level": rung, "status": None, "reason": ""}

        if rung not in rungs:
            entry["status"] = BLOCKED
            entry["reason"] = f"`from_level: {rung}` is not a rung of this ladder ({', '.join(rungs)})"
            plan.append(entry)
            continue

        if rungs.index(rung) > reach:
            entry["status"] = SKIPPED
            entry["reason"] = f"gate_level is `{wanted}`; this gate starts at `{rung}`"
            plan.append(entry)
            continue

        blocked = False
        for tid, expected in (gate.get("when") or {}).items():
            if tid not in tg.defs:
                entry["status"] = BLOCKED
                entry["reason"] = f"`when` names an unknown toggle: {tid}"
                blocked = True
                break
            current = tg.resolve(tid)[0]
            allowed = [norm(v) for v in (expected if isinstance(expected, list) else [expected])]
            if current not in allowed:
                entry["status"] = SKIPPED
                entry["reason"] = f"{tid} is `{current}`, gate needs {' or '.join(allowed)}"
                blocked = True
                break
        if blocked:
            plan.append(entry)
            continue

        only = gate.get("only_repos")
        # `downstream` means "produces no artifact", not "is never checked". A
        # repository that has to keep up — a published table, a requirements
        # matrix — carries a real obligation, and excluding it from every gate
        # meant that obligation had nothing enforcing it. Build gates still skip
        # it by default; a gate that exists to verify it says so.
        include_downstream = bool(gate.get("include_downstream"))
        # `_excluded` carries the repositories a repository-named pack took over
        # with an override. The shared gate still runs; it just stops running
        # where a more specific pack said something else about it.
        excluded = set(gate.get("_excluded") or [])
        entry["repos"] = [
            r
            for r in repos
            if (not only or r in only)
            and r not in excluded
            and (include_downstream or not ws.repos.get(r, {}).get("downstream"))
        ]
        if gate.get("per_repo") and not entry["repos"]:
            entry["status"] = SKIPPED
            entry["reason"] = "no repository in this change matches it"
        plan.append(entry)

    order = {rung: i for i, rung in enumerate(rungs)}
    plan.sort(key=lambda g: order.get(g["from_level"], 99))
    return plan


# ---------------------------------------------------------------- execution
def _run(command: str, cwd: Path, timeout: int) -> tuple[int, str, float]:
    started = time.time()
    try:
        proc = subprocess.run(
            ["bash", "-c", command], cwd=str(cwd), capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode, (proc.stdout + proc.stderr), time.time() - started
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s", time.time() - started
    except OSError as exc:
        return 127, str(exc), time.time() - started


def run_gate(
    gate: dict,
    ws: Workspace,
    tg: Toggles,
    task: str,
    target: dict | None,
    dry_run: bool = False,
) -> dict:
    """Run one gate over its repositories, or once, and record what happened."""
    timeout = int(gate.get("timeout", DEFAULT_TIMEOUT))
    runs: list[dict] = []

    if gate.get("per_repo"):
        work = [(repo, gate["per_repo"], ws.repo_path(repo)) for repo in gate.get("repos", [])]
    elif gate.get("once"):
        work = [(None, gate["once"], ws.root)]
    else:
        return {**gate, "status": BLOCKED, "reason": "declares neither `per_repo` nor `once`", "runs": []}

    log_dir = gates_dir(ws.root) / "logs" / task
    for repo, template, cwd in work:
        command, missing = resolve(template, ws, tg, repo, target)
        if missing:
            # A command that is *entirely* an unresolved variable means the gate
            # does not apply here — a repository with no lint command declared
            # has nothing to lint. A variable missing from inside a larger
            # command is a hole, and a command with a hole either fails
            # confusingly or succeeds doing something else.
            whole = command.strip() in {m.strip() for m in missing}
            runs.append(
                {
                    "repo": repo,
                    "command": command,
                    "status": SKIPPED if whole else BLOCKED,
                    "reason": (
                        f"{missing[0]} is not declared for this repository"
                        if whole
                        else f"unresolved: {', '.join(sorted(set(missing)))}"
                    ),
                }
            )
            continue

        missing_script = _missing_script(command, cwd)
        if missing_script:
            # Every variable resolved, and the command still names a file that
            # is not there — the shape of a pack written for one workspace
            # layout run against another, `${deck.root}` chief among them.
            # Checked here, ahead of `dry_run`, so the preview that exists to
            # catch exactly this shows it instead of a command that looks fine
            # and is not; checked ahead of actually running it so the report is
            # this sentence, not a subprocess's stderr three fields down.
            runs.append(
                {
                    "repo": repo,
                    "command": command,
                    "status": BLOCKED,
                    "reason": f"resolved to a script that does not exist: {missing_script}",
                }
            )
            continue
        if dry_run:
            runs.append({"repo": repo, "command": command, "cwd": str(cwd), "status": "would run"})
            continue

        code, output, elapsed = _run(command, cwd, timeout)
        log_dir.mkdir(parents=True, exist_ok=True)
        log = log_dir / f"{gate['id']}{'-' + repo if repo else ''}.log"
        log.write_text(output, encoding="utf-8")
        runs.append(
            {
                "repo": repo,
                "command": command,
                "status": PASSED if code == 0 else FAILED,
                "exit": code,
                "seconds": round(elapsed, 1),
                "log": str(log),
                "tail": "\n".join(output.splitlines()[-12:]),
                # Measured here, from the bytes the log just received, rather
                # than by re-reading the file or re-running anything: a sample
                # that cannot be traced to a run that happened is not evidence.
                "measured": metric_lib.measure(gate, repo, output),
            }
        )

    if dry_run:
        # A dry run that resolved to a missing script would not have run
        # either — saying "would run" over that is the same silent optimism
        # this whole check exists to remove.
        status = BLOCKED if any(r["status"] == BLOCKED for r in runs) else "would run"
    elif runs and all(r["status"] == SKIPPED for r in runs):
        status = SKIPPED
    elif any(r["status"] == BLOCKED for r in runs):
        status = BLOCKED
    elif any(r["status"] == FAILED for r in runs):
        status = FAILED
    elif runs:
        status = PASSED
    else:
        status = SKIPPED
    return {**gate, "status": status, "runs": runs}


def record(
    ws: Workspace,
    task: str,
    results: list[dict],
    level: str,
    covered: list[str] | None = None,
    partial: bool = False,
) -> Path:
    """Evidence on disk. A report nobody can reconstruct is not evidence."""
    path = gates_dir(ws.root) / f"{task}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    # The scope belongs in the evidence, not only in the terminal that ran it.
    # A ladder that climbed inside a subset reports the same green as one that
    # covered the registry, and a reader cannot tell "the scope narrowed this to
    # one repository" from "the others had no applicable gate". Silent partial
    # verification is the failure this whole file exists to prevent, so the file
    # says which repositories were in play and why.
    scope = ws.scope_name
    # What the run actually covered, not what the scope happens to hold. With
    # `--repos` the two differ, and taking the scope's list would have produced
    # evidence claiming less coverage than the run gave — the same silent
    # mismatch this field was added to close, pointing the other way.
    payload = {
        "task": task,
        "level": level,
        "scope": scope,
        "covered_repos": sorted(covered) if covered is not None else None,
        "scope_repos": sorted(ws.scope_repos(scope)) if scope else None,
        "registry_repos": sorted(ws.repos),
        "finished": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "gates": [
            {
                "id": g["id"],
                "title": g.get("title", g["id"]),
                # The rung the plan placed it on, which for a gate declared
                # without one is the rung it actually ran at rather than null.
                # A gate blocked for naming a rung this ladder has not got
                # keeps what it declared: it ran nowhere.
                "from_level": g.get("from_level"),
                "status": g["status"],
                "reason": g.get("reason", ""),
                "pack": g.get("_pack"),
                "runs": g.get("runs", []),
                "measured": [m for r in g.get("runs", []) for m in r.get("measured") or []],
            }
            for g in results
        ],
    }
    # A partial run is partial news. `--only` used to write the whole file from
    # the one gate it ran, so everything verified minutes earlier read as never
    # run — and `deck bundle`, which reads this file, then told a reviewer the
    # ladder had completed no rung. It punished the right instinct: `--only` is
    # what you reach for after fixing one gate to avoid re-running a long
    # suite, and the price was the long suite's result.
    #
    # Merged by id, keeping each entry's own `finished`, so a record assembled
    # from several runs can say so instead of presenting itself as one. How
    # stale is too stale is NOT decided here: an entry from a run against a
    # tree that has since changed is not evidence of anything, and comparing
    # timestamps against something is a judgement deck does not have the facts
    # to make. What it can do is stop hiding the spread.
    if partial and path.is_file():
        try:
            previous = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            previous = None
        if previous:
            now = payload["finished"]
            for entry in payload["gates"]:
                entry["finished"] = now
            # Keyed on id AND pack, not id alone: two disjoint-coexisting
            # gates can share an id, and keying on id alone would have a
            # partial re-run of ONE of them drop the other's own entry from
            # `kept` — evidence for a gate that did not re-run, discarded
            # because something with the same name did.
            fresh_keys = {(g["id"], g.get("pack")) for g in payload["gates"]}
            kept = [g for g in (previous.get("gates") or []) if (g.get("id"), g.get("pack")) not in fresh_keys]
            for entry in kept:
                entry.setdefault("finished", previous.get("finished"))
            payload["gates"] = kept + payload["gates"]
            payload["gates"].sort(key=lambda g: str(g.get("id")))
            payload["partial_runs"] = True
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


def rung_of(gate: dict) -> str:
    """The rung a recorded gate belongs to.

    `applicable()` now stamps the rung it decided onto every gate it plans, so
    a record written today names one. Records written before it do not: a gate
    declared without a `from_level` was filed as null, and those files are still
    read. Reading the null the way applicable() reads a missing key keeps a rung
    that did run from looking empty.
    """
    return gate.get("from_level") or "static"


def rungs_without_gates(rungs: list[str], gates: list[dict]) -> list[str]:
    """The rungs this record holds no gate for, in ladder order.

    Read from the evidence, not from the packs as they stand today, because
    every other line of the bundle describes the run that produced the record —
    a gate declared since would otherwise cover a rung retrospectively.

    `applicable()` files every declared gate, including the ones above the level
    it was told to climb, so a rung absent here is one nothing was declared for;
    under `gate run --only` it is one the operator left out. Both say the same
    thing to a reader, which is why one list carries both: this run verified
    nothing at that rung.

    A rung whose gates all turned out not to apply is *not* here. It has gates,
    deck weighed them against these repositories and this toggle state, and
    `rungs_all_inapplicable()` carries it instead — a different fact, and a
    reviewer who cannot tell the two apart cannot tell "nobody covers this rung"
    from "somebody covers it and it did not apply to this change".
    """
    return [r for r in rungs if not any(rung_of(g) == r for g in gates)]


def _owes(gate: dict) -> bool:
    """Whether this gate still owes the ladder an answer.

    Failing and not being able to run both owe one; so does a gate the ladder
    stopped short of, which is what `STOPPED_EARLY` marks. A gate that does not
    apply here owes nothing, and that is deliberate: it is what lets
    `only_repos` and a `when` toggle narrow a ladder without stalling it.
    """
    return gate["status"] in (FAILED, BLOCKED) or (gate["status"] == SKIPPED and gate.get("reason") == STOPPED_EARLY)


def _verified(gate: dict) -> bool:
    """Whether this gate is evidence that something was actually checked.

    Owing nothing and having verified something are not the same, and one
    predicate used to serve both. A rung whose every gate was waved through —
    `only_repos` excluded every repository in play, or a `when` toggle did not
    match — owed nothing, so it counted as reached while no command ran on it.
    Only a gate that ran and passed is verification.
    """
    return gate["status"] == PASSED


def rungs_all_inapplicable(rungs: list[str], gates: list[dict]) -> list[dict]:
    """The rungs that held gates, weighed every one, and ran none — with why.

    `[{"rung": str, "gates": [{"id": str, "reason": str}]}]`, in ladder order.
    The reasons travel with the rung because the whole point of the entry is
    that a reviewer can see *why* nothing ran there: an excluded repository and
    a toggle that did not match are coverage, not failure, and they read as
    failure when the rung is named with no sentence beside it.

    Reported apart from `rungs_without_gates()` on purpose. A rung with no gates
    was never considered by anyone; a rung here was — a pack declared gates for
    it and deck weighed them against these repositories and this toggle state.

    A rung that owes something is not here. It is where the ladder stopped, and
    `rung_completed()` names it; calling it inapplicable as well would file a
    failure under coverage.
    """
    out = []
    for rung in rungs:
        at = [g for g in gates if rung_of(g) == rung]
        if not at or any(_owes(g) for g in at) or any(_verified(g) for g in at):
            continue
        out.append({"rung": rung, "gates": [{"id": g["id"], "reason": g.get("reason", "")} for g in at]})
    return out


def rung_completed(rungs: list[str], configured: str | None, gates: list[dict]) -> tuple[str | None, str | None]:
    """(the highest rung actually completed, the rung it stopped at).

    The record's `level` is what the run was configured to reach, not what it
    reached. A static gate that fails stops the ladder there, and reporting the
    configured rung would claim verification that never happened — the one thing
    every other line in this program refuses to do.

    A rung counts as completed when at least one gate passed there and none of
    them failed, could not run, or was never attempted. The rule is stated in
    terms of what ran, not of what is owed, because two different ways of having
    nothing were both once vacuously complete:

    An empty rung, which made a workspace with `gate_level: deploy` and no
    deploy gate report a ladder that reached `deploy`.

    A rung whose gates were all waved through — `only_repos` excluded every
    repository in play, or a `when` toggle did not match. It owed nothing, and
    owing nothing was read as being done, so `build` was reported reached while
    no build command ever ran.

    Both are holes, and nothing above a hole is credited either: reaching a rung
    says every rung below it was verified.

    A gate that does not apply still does not *hold the ladder back*. That rule
    is untouched and is the reason `_owes()` and `_verified()` are two
    predicates rather than one: an inapplicable gate never becomes `stopped_at`,
    the run does not fail on it, and the gates above it still run. What it no
    longer does is count as verification, which is the other half the single
    rule got wrong.

    Rungs above the configured one are not considered, because the run never
    intended to climb them.
    """
    if configured not in rungs:
        return configured, None
    done = None
    hole = False
    for rung in rungs[: rungs.index(configured) + 1]:
        at = [g for g in gates if rung_of(g) == rung]
        if any(_owes(g) for g in at):
            return done, rung
        if not any(_verified(g) for g in at):
            hole = True
        elif not hole:
            done = rung
    return done, None


def summarise(results: list[dict]) -> str:
    """One honest line. `not run` is never rounded up to `passed`."""
    counts = {PASSED: 0, FAILED: 0, SKIPPED: 0, BLOCKED: 0}
    for gate in results:
        counts[gate["status"]] = counts.get(gate["status"], 0) + 1
    runs = sum(len(gate.get("runs") or []) for gate in results)
    parts = [f"{counts[PASSED]} gate(s) passed"]
    if runs > counts[PASSED]:
        # Four rows and "2 passed" underneath reads like an arithmetic error.
        # The rows are runs, one per repository; the count is gates.
        parts[0] += f" in {runs} run(s)"
    if counts[FAILED]:
        parts.append(f"{counts[FAILED]} failed")
    if counts[BLOCKED]:
        parts.append(f"{counts[BLOCKED]} could not run")
    if counts[SKIPPED]:
        unattempted = sum(1 for gate in results if gate["status"] == SKIPPED and gate.get("reason") == STOPPED_EARLY)
        if unattempted:
            parts.append(f"{unattempted} not attempted")
        if counts[SKIPPED] - unattempted:
            parts.append(f"{counts[SKIPPED] - unattempted} not applicable")
    return " · ".join(parts)


def shell_quote(command: str) -> str:
    return shlex.quote(command)
