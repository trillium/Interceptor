"""Reference gate probes, transcribed from cli/mcp/tiers.ts.

Do not import the Python tier tables to build this list. A missing or drifted
port must fail against these cases, not against a copy of itself.
"""

from __future__ import annotations

# Exact keys from cli/mcp/tiers.ts EXEC / DESTRUCTIVE_SUB / family rules.
EXEC_KEYS = [
    "browser:eval", "browser:save", "browser:raw",
    "macos:script", "macos:intent", "macos:container",
    "macos:overlay:eval",
    "macos:vm:exec",
    "macos:cdp:raw",
    "ios:eval", "ios:spawn",
    "ios:web:eval", "ios:web:call",
]
DESTRUCTIVE_KEYS = [
    "macos:app:quit", "macos:app:terminate",
    "macos:fs:write", "macos:display:set",
    "macos:tcc:profile",
    "macos:vm:create", "macos:vm:delete",
    "macos:vm:reset", "macos:vm:stop",
    "macos:vm:restore", "macos:vm:start",
    "macos:vm:clone", "macos:vm:adopt",
    "macos:vm:install", "macos:vm:pull",
    "macos:runtime:enable", "macos:runtime:disable",
    "macos:update:install",
    "ios:app:terminate",
    "ios:fs:push",
]
SHARE_SEND = ["airdrop", "email", "message", "named", "reading-list", "desktop-picture"]
PDF_WRITE = ["annotate", "strip", "merge", "split"]
PD_VERBS = ["calendar", "reminders", "contacts", "photos"]
PD_WRITE_SUBS = [
    "create", "update", "delete", "move", "reset", "create-calendar",
    "delete-calendar", "album-create", "album-delete", "album-rename",
    "group-create", "group-update", "group-delete", "group-add-member",
    "group-remove-member", "import", "import-video", "import-vcard", "favorite",
    "hide", "add-to-album", "remove-from-album", "complete", "uncomplete",
]
IOS_DESTRUCTIVE_VERBS = ["setup", "refresh", "install", "login", "logout", "kill"]
# Unknown sub-verb → family floor. clipboard/ios:web floors are mutate, not high.
HIGH_FLOORS = {
    "macos:vm": "destructive",
    "macos:runtime": "exec",
    "macos:cdp": "destructive",
    "macos:app": "destructive",
    "macos:share": "destructive",
    "macos:pdf": "destructive",
    "macos:tcc": "destructive",
    "macos:fs": "destructive",
    "macos:calendar": "destructive",
    "macos:reminders": "destructive",
    "macos:contacts": "destructive",
    "macos:photos": "destructive",
    "ios:app": "destructive",
    "ios:fs": "destructive",
}

FROBNICATE = ["macos", "vm", "frobnicate"]


def _add(out: list, seen: set, argv: list[str], tier: str) -> None:
    key = tuple(argv)
    if key in seen:
        return
    seen.add(key)
    out.append((list(argv), tier))


def _from_key(key: str, extra: str = "") -> list[str]:
    surface, verb, *sub = key.split(":")
    tail = list(sub)
    if extra:
        tail.append(extra)
    if surface == "browser":
        return [verb, *tail] if tail else [verb]
    return [surface, verb, *tail]


def high_tier_probes() -> list[tuple[list[str], str]]:
    """Every destructive/exec argv the reference tables name, plus unknown-sub floors."""
    out: list[tuple[list[str], str]] = []
    seen: set[tuple[str, ...]] = set()
    _add(out, seen, FROBNICATE, "destructive")
    _add(out, seen, ["macos", "vm", "--json", "frobnicate"], "destructive")
    _add(out, seen, ["macos", "runtime", "novelverb"], "exec")
    _add(out, seen, ["macos", "app", "banish"], "destructive")
    for key in EXEC_KEYS:
        # Bare verbs (browser:eval) get a payload token. key2 still matches EXEC, so
        # that token becoming `sub` does not drop the tier. Keys that already name the
        # sub (macos:vm:exec) must not grow an extra token or the sub changes.
        _add(out, seen, _from_key(key, "" if key.count(":") >= 2 else "x"), "exec")
    for key in DESTRUCTIVE_KEYS:
        _add(out, seen, _from_key(key), "destructive")
    for sub in SHARE_SEND:
        _add(out, seen, ["macos", "share", sub], "destructive")
    for sub in PDF_WRITE:
        _add(out, seen, ["macos", "pdf", sub], "destructive")
    for verb in PD_VERBS:
        for sub in PD_WRITE_SUBS:
            _add(out, seen, ["macos", verb, sub], "destructive")
    for verb in IOS_DESTRUCTIVE_VERBS:
        _add(out, seen, ["ios", verb], "destructive")
        _add(out, seen, ["ios", verb, "1"], "destructive")
    _add(out, seen, ["ios", "location", "set"], "destructive")
    _add(out, seen, ["ios", "profiles", "install"], "destructive")
    _add(out, seen, ["ios", "profiles", "remove"], "destructive")
    # Dead key in the reference: exec matches ios:web:call before this can be destructive.
    _add(out, seen, ["ios", "web", "call", "--mutating"], "exec")
    for fam, tier in HIGH_FLOORS.items():
        surface, verb = fam.split(":")
        _add(out, seen, [surface, verb, "frobnicate"], tier)
    if FROBNICATE not in [list(a) for a, _ in out]:
        raise RuntimeError("acceptance probe macos vm frobnicate missing from high-tier list")
    return out


def admitted_under_raw() -> list[list[str]]:
    """Read/mutate calls that must still reach the CLI once raw (only) is allowed.

    Includes iOS input, which stays mutate — see README "iOS input stays mutate".
    """
    return [
        ["ios", "click", "e1"],
        ["ios", "type", "hi"],
        ["ios", "keys", "Enter"],
        ["ios", "scroll", "down"],
        ["ios", "drag", "e1", "e2"],
        ["ios", "press", "home"],
        ["ios", "app", "launch", "com.example"],
        ["ios", "app", "activate", "com.example"],
        ["macos", "app", "activate", "Safari"],
        ["macos", "vm", "list"],
        ["macos", "vm"],
        ["macos", "vm", "--json"],
        ["macos", "clipboard", "frobnicate"],
        ["ios", "web", "frobnicate"],
        ["tree"],
    ]
