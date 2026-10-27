"""Skills tool wiring. Keep in lockstep with cli/mcp/skills.ts and cli/commands/skills.ts.

adopt/unadopt go through the existing gate at mutate minimum. unadopt of a
path outside the skills root is refused before the CLI is spawned.
"""

from __future__ import annotations

import os
import re
from typing import Optional

from . import tiers

SKILLS_OPS = ["list", "status", "show", "adopt", "unadopt"]
SKILLS_DESCRIPTION = (
    "List, show, and link Interceptor skill packs (list/status/show/adopt), or unadopt a link. "
    "adopt and unadopt go through the operator gate at mutate minimum. "
    "unadopt refuses any path outside the skills root and does not reach the CLI."
)
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
_GATED = {"adopt", "unadopt"}


def floor_tier(tier: str, minimum: str) -> str:
    if tiers.TIER_RANK[tier] < tiers.TIER_RANK[minimum]:
        return minimum
    return tier


def skills_sub(args: list[str]) -> str:
    for a in args:
        if not a.startswith("-"):
            return a
    return "list"


def skills_needs_gate(args: list[str]) -> bool:
    return skills_sub(args) in _GATED


def skills_cli_args(op: str, name: Optional[str], args: list[str], path: Optional[str]) -> list[str]:
    out = ["skills", op]
    if name:
        out.append(name)
    if path:
        out += ["--path", path]
    return out + list(args)


def is_safe_skill_name(name: str) -> bool:
    return bool(_NAME_RE.match(name))


def _pack_dir() -> Optional[str]:
    starts = [os.getcwd(), os.path.dirname(os.path.abspath(__file__))]
    for start in starts:
        cur = start
        for _ in range(8):
            candidate = os.path.join(cur, ".agents", "skills")
            if os.path.isdir(os.path.join(candidate, "interceptor-browser")):
                return os.path.abspath(candidate)
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    darwin = "/Library/Application Support/Interceptor/skills"
    if os.path.isdir(darwin):
        return darwin
    return None


def skills_roots() -> list[str]:
    raw = os.environ.get("INTERCEPTOR_SKILLS_ROOT")
    if raw and raw.strip():
        return [os.path.abspath(p.strip()) for p in raw.split(":") if p.strip()]
    roots: list[str] = []
    pack = _pack_dir()
    if pack:
        roots.append(pack)
    home = os.path.expanduser("~")
    codex = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    for d in (
        os.path.join(home, ".claude", "skills"),
        os.path.join(codex, "skills"),
        os.path.join(home, ".agents", "skills"),
        os.path.join(home, ".openclaw", "skills"),
        os.path.join(home, ".config", "opencode", "skills"),
    ):
        roots.append(os.path.abspath(d))
    return roots


def _lexical_inside(root: str, abs_c: str) -> bool:
    rel = os.path.relpath(abs_c, os.path.abspath(root))
    return bool(rel) and not rel.startswith("..") and not os.path.isabs(rel)


def path_inside_skills_root(candidate: str, roots: list[str]) -> bool:
    if not candidate or "\0" in candidate:
        return False
    abs_c = os.path.abspath(candidate)
    # Missing path: lexical compare only. realpath(/var) is /private/var on
    # macOS, which would reject a not-yet-created child of the root we were given.
    if not os.path.exists(abs_c):
        return any(_lexical_inside(root, abs_c) for root in roots)
    try:
        real = os.path.realpath(abs_c)
    except OSError:
        return False
    for root in roots:
        rr = os.path.abspath(root)
        try:
            if os.path.exists(rr):
                rr = os.path.realpath(rr)
        except OSError:
            continue
        rel = os.path.relpath(real, rr)
        if rel and not rel.startswith("..") and not os.path.isabs(rel):
            return True
    return False


def unadopt_candidates(name: Optional[str], path: Optional[str], args: list[str]) -> list[tuple[str, bool]]:
    out: list[tuple[str, bool]] = []
    if path:
        out.append((path, True))
    if name:
        out.append((name, False))
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--path" and i + 1 < len(args):
            out.append((args[i + 1], True))
            i += 2
            continue
        if a.startswith("--path="):
            out.append((a[len("--path="):], True))
            i += 1
            continue
        if a.startswith("-"):
            i += 1
            continue
        out.append((a, False))
        i += 1
    return out


def unadopt_refusal(candidates: list[tuple[str, bool]], roots: Optional[list[str]] = None) -> Optional[str]:
    roots = skills_roots() if roots is None else roots
    for value, is_path in candidates:
        if not is_path and is_safe_skill_name(value):
            continue
        if not path_inside_skills_root(value, roots):
            return f"unadopt refuses paths outside the skills root: {value}"
    return None


def refuse_unadopt(name: Optional[str], path: Optional[str], args: list[str]) -> Optional[str]:
    return unadopt_refusal(unadopt_candidates(name, path, args))
