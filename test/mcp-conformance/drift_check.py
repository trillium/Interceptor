"""Drift check: a CLI verb the MCP classification does not know fails loudly.

Known = classification tables (READ / EXEC / DESTRUCTIVE / FAMILY_FLOOR / EXPLICIT)
plus the MCP verb menus. A new `case` or command-set entry that is in neither
is unclassified and would default to mutate.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "python"))

from interceptor_mcp.menus import BROWSER_VERBS, IOS_VERBS, MACOS_VERBS  # noqa: E402
from interceptor_mcp.server import LOCAL_VERBS  # noqa: E402
from interceptor_mcp.tiers import classification_keys  # noqa: E402

LOUD = (
    "DRIFT: the CLI gained verb(s) the MCP classification does not know: {verbs}\n"
    "Add an explicit tier in cli/mcp/tiers.ts EXPLICIT and python/interceptor_mcp/tiers.py EXPLICIT "
    "(and the verb menu, if the tool should offer it) before shipping.\n"
    "Refusing to pass: an unclassified verb would default to mutate and run."
)

_LOCAL_SETS = {
    "UPGRADE_CMDS", "INIT_CMDS", "RESEARCH_CMDS", "EXTENSIONS_CMDS",
    "SKILLS_CMDS", "MANIFEST_CMDS", "DIAGNOSE_CMDS", "DAEMON_CMDS",
}
_SURFACE_SETS = {"MACOS_CMDS", "IOS_CMDS"}


def py_known_keys() -> set[str]:
    keys = set(classification_keys())
    menus = {
        "browser": [v for v, _ in BROWSER_VERBS],
        "macos": [v for v, _ in MACOS_VERBS],
        "ios": [v for v, _ in IOS_VERBS],
        "local": [v for v, _ in LOCAL_VERBS],
    }
    for surface, verbs in menus.items():
        for verb in verbs:
            keys.add(f"{surface}:{verb}")
    return keys


def ts_known_keys() -> set[str]:
    proc = subprocess.run(
        ["bun", os.path.join(HERE, "ts_drift.ts")],
        text=True, capture_output=True, cwd=ROOT, timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout or "ts_drift failed")
    return set(json.loads(proc.stdout))


def cli_required_keys() -> set[str]:
    index = open(os.path.join(ROOT, "cli", "index.ts"), encoding="utf-8").read()
    keys: set[str] = set()
    for name, body in re.findall(r"const (\w+_CMDS) = new Set\(\[(.*?)\]\)", index, re.S):
        verbs = re.findall(r'"([^"]+)"', body)
        if name in _SURFACE_SETS:
            continue
        surface = "local" if name in _LOCAL_SETS else "browser"
        for verb in verbs:
            keys.add(f"{surface}:{verb}")
    known = re.search(r"const ALL_KNOWN_CMDS = new Set<string>\(\[(.*?)\]\)", index, re.S)
    if not known:
        raise RuntimeError("ALL_KNOWN_CMDS not found — drift check cannot see CLI verbs")
    extras = re.findall(r'"([^"]+)"', known.group(1))
    for verb in extras:
        if verb in ("macos", "ios"):
            continue
        keys.add(f"local:{verb}")
    for surface, path in (("macos", "cli/commands/macos.ts"), ("ios", "cli/commands/ios.ts")):
        text = open(os.path.join(ROOT, path), encoding="utf-8").read()
        for verb in re.findall(r'\n    case "([^"]+)":', text):
            keys.add(f"{surface}:{verb}")
    return keys


def unknown_verbs(required: set[str] | None = None, known: set[str] | None = None) -> list[str]:
    required = cli_required_keys() if required is None else required
    known = py_known_keys() if known is None else known
    return sorted(required - known)


def explain(missing: list[str]) -> str:
    return LOUD.format(verbs=", ".join(missing) if missing else "(none)")


def assert_no_drift(required: set[str] | None = None, known: set[str] | None = None) -> None:
    missing = unknown_verbs(required, known)
    if missing:
        raise SystemExit(explain(missing))


if __name__ == "__main__":
    assert_no_drift()
    print(f"drift check ok ({len(cli_required_keys())} CLI verbs classified)")
