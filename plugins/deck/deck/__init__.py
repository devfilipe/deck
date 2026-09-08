"""deck — a control plane for coding agents working across repositories."""

import json
from pathlib import Path


def _version() -> str:
    """The version, read from the plugin manifest.

    One number, one home. The manifest has to carry it as a JSON literal because
    Claude Code reads that file without running anything, so the manifest is the
    home and Python reads from it. Two copies of one number is how they drift,
    and this project has already lost that argument once over a check total
    stated in five documents and gated in four.
    """
    manifest = Path(__file__).resolve().parent.parent / ".claude-plugin" / "plugin.json"
    try:
        return json.loads(manifest.read_text(encoding="utf-8"))["version"]
    except (OSError, ValueError, KeyError):
        # A clone missing its manifest is broken in a way `deck doctor` should
        # say out loud, not something to paper over with a plausible number.
        return "unknown"


__version__ = _version()
