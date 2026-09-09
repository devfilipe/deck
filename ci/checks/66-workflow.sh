# ------------------------------------------- the workflow against the pack
note "the workflow and the pack declare one ladder"
# `.github/workflows/ci.yml` keeps its own list of commands rather than calling
# `deck gate run`; the reasons are in that file's header. The price of a second
# list is that it can drift from the first, and it already had — `docs` was
# declared in the pack and run nowhere in CI, so the gate for the failure this
# repository kept having never ran on a push. These checks are what pays for
# the duplication.
#
# They read both files as data — a gate's `id`, a step's `# gate:` marker, a
# step's parsed `run` and `shell` — because there is no behaviour to exercise
# here: GitHub Actions is not runnable from this suite, and a check that
# pretended otherwise would be worse than one that says what it is.
# The pack is not in this repository, and this suite cannot ask the ambient
# DECK_PACKS_ROOT where it is: the suite sets that itself, to the synthetic
# collection every other check runs against. So the path comes from the one
# versioned statement of where deck's own collection lives — `packs_root` in
# `seed/workspace.yaml` — with DECK_SELF_PACKS overriding it where the sibling
# layout is not reproducible, which is what CI does.
#
# It fails loudly when nothing resolves. A comparison with one side missing is
# the check that passes for want of a file, and it would defend nothing.
GATES_YAML="${DECK_SELF_PACKS:-$(python3 - "$REPO" <<'SEED'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
declared = yaml.safe_load((root / "seed/workspace.yaml").read_text()).get("packs_root")
first = declared[0] if isinstance(declared, list) else declared
print((root / str(first)).resolve() if first else "")
SEED
)}"
GATES_YAML="$GATES_YAML/_workspaces/all/default"
if [ ! -f "$GATES_YAML/config/gates.yaml" ]; then
  bad "the workflow and the pack declare one ladder" "no gates.yaml under $GATES_YAML"
fi
ladder_report="$(python3 - "$REPO" "$GATES_YAML" <<'PY'
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
pack = Path(sys.argv[2])
declared = {g["id"] for g in yaml.safe_load((pack / "config/gates.yaml").read_text())["gates"]}
text = (root / ".github/workflows/ci.yml").read_text()
marked = set(re.findall(r"^\s*#\s*gate:\s*([a-z][a-z0-9-]*)\s*$", text, re.M))
steps = yaml.safe_load(text)["jobs"]["check"]["steps"]

# Each way the workflow could make the whole suite run: calling it, or calling
# the documents gate with no log for it to read.
runs_suite = [
    s
    for s in steps
    if "ci/smoke.sh" in s.get("run", "") or ("--counts" in s.get("run", "") and "--suite-log" not in s.get("run", ""))
]
writes_log = [s for s in steps if "ci/smoke.sh" in s.get("run", "") and "|" in s.get("run", "")]

print("unrun=" + ",".join(sorted(declared - marked)))
print("undeclared=" + ",".join(sorted(marked - declared)))
print("counts_checked=" + str(any("--counts" in s.get("run", "") for s in steps)))
print("suite_runs=" + str(len(runs_suite)))
if not writes_log:
    log_step = "none"
elif all(s.get("shell") == "bash" for s in writes_log):
    log_step = "bash"
else:
    log_step = "unsafe"
print("log_step=" + log_step)
PY
)"
ladder_says() {
  if printf '%s\n' "$ladder_report" | grep -qxF "$2"; then ok "$1"
  else bad "$1" "$(printf '%s\n' "$ladder_report" | grep "^${2%%=*}=" || printf 'no %s line' "${2%%=*}")"; fi
}
ladder_says "every gate the pack declares has a step in the workflow"          "unrun="
ladder_says "and no step claims a gate the pack does not declare"              "undeclared="
ladder_says "the workflow checks the check total the documents state"          "counts_checked=True"
ladder_says "and learns the real total without running the suite twice"        "suite_runs=1"
ladder_says "the step that pipes the suite into a log sets pipefail"           "log_step=bash"
