"""Capability-tier classifier + operator-allowlist gate.

Line-for-line port of cli/mcp/tiers.ts. Keep in lockstep with the TypeScript
tables; the conformance suite (test/mcp-conformance) exercises both.
"""

from __future__ import annotations

from typing import NamedTuple, Optional

TIER_RANK = {"read": 0, "mutate": 1, "destructive": 2, "exec": 3}

# Ordered lists (the TS Sets preserve insertion order, which fixes the READ_VERB_NAMES menu).
READ_VERB_ORDER: dict[str, list[str]] = {
    "browser": [
        "state", "tree", "diff", "find", "text", "html", "links", "images",
        "forms", "query", "exists", "count", "table", "attr", "style", "screenshot",
        "net", "network", "headers", "inspect", "tabs", "read", "status", "meta",
        "info", "page_info", "events", "modals", "panels", "sessions", "capabilities",
        "delegate", "idle", "history", "bookmarks", "downloads", "frames", "canvas",
        "ocr", "what-at", "contexts", "manifest",
    ],
    "macos": [
        "tree", "find", "inspect", "focused", "windows", "text", "menu", "apps",
        "frontmost", "screenshot", "vision", "nlp", "sensitive", "health", "files",
        "log", "sounds", "detect", "translate", "thumbnail", "read", "capture",
    ],
    "ios": [
        "tree", "find", "inspect", "screenshot", "apps", "status", "devices",
        "discover", "diag", "crash", "profiles", "springboard", "proc", "ps", "top",
        "gpu", "shot", "axtree", "screen", "backup", "logs", "notify",
    ],
}

READ_VERBS: dict[str, set[str]] = {k: set(v) for k, v in READ_VERB_ORDER.items()}
READ_VERBS["local"] = {"status", "manifest", "diagnose", "extensions", "contexts", "capabilities"}

EXEC: dict[str, str] = {
    "browser:eval": "exec", "browser:save": "exec", "browser:raw": "exec",
    "macos:script": "exec", "macos:intent": "exec", "macos:container": "exec",
    "macos:overlay:eval": "exec",
    "macos:vm:exec": "exec",
    "macos:cdp:raw": "exec",
    "ios:eval": "exec", "ios:spawn": "exec",
    "ios:web:eval": "exec", "ios:web:call": "exec",
}

DESTRUCTIVE_SUB: dict[str, str] = {
    "macos:app:quit": "destructive", "macos:app:terminate": "destructive",
    "macos:fs:write": "destructive", "macos:display:set": "destructive",
    "macos:tcc:profile": "destructive",
    "macos:vm:create": "destructive", "macos:vm:delete": "destructive",
    "macos:vm:reset": "destructive", "macos:vm:stop": "destructive",
    "macos:vm:restore": "destructive", "macos:vm:start": "destructive",
    "macos:vm:clone": "destructive", "macos:vm:adopt": "destructive",
    "macos:vm:install": "destructive", "macos:vm:pull": "destructive",
    "macos:runtime:enable": "destructive", "macos:runtime:disable": "destructive",
    "macos:update:install": "destructive",
    "ios:app:terminate": "destructive",
    "ios:fs:push": "destructive",
    "ios:web:call:--mutating": "destructive",
}

PD_WRITE_SUBS = {
    "create", "update", "delete", "move", "reset", "create-calendar",
    "delete-calendar", "album-create", "album-delete", "album-rename",
    "group-create", "group-update", "group-delete", "group-add-member",
    "group-remove-member", "import", "import-video", "import-vcard", "favorite",
    "hide", "add-to-album", "remove-from-album", "complete", "uncomplete",
}
PD_VERBS = {"calendar", "reminders", "contacts", "photos"}
SHARE_SEND = {"airdrop", "email", "message", "named", "reading-list", "desktop-picture"}
PDF_WRITE = {"annotate", "strip", "merge", "split"}

FAMILY_FLOOR: dict[str, str] = {
    "macos:vm": "destructive",
    "macos:runtime": "exec",
    "macos:cdp": "destructive",
    "macos:app": "destructive",
    "macos:share": "destructive",
    "macos:pdf": "destructive",
    "macos:tcc": "destructive",
    "macos:fs": "destructive",
    "macos:clipboard": "mutate",
    "macos:calendar": "destructive",
    "macos:reminders": "destructive",
    "macos:contacts": "destructive",
    "macos:photos": "destructive",
    "ios:app": "destructive",
    "ios:web": "mutate",
    "ios:fs": "destructive",
}

FAMILY_READ_SUBS: dict[str, set[str]] = {
    "macos:vm": {"list", "get", "inspect", "read-ax", "logs", "screenshot"},
    "macos:runtime": {
        "discover", "status", "signid", "tree", "layers", "screenshot", "ping", "ax",
        "file", "hooks", "events", "domains", "net",
    },
    "macos:cdp": {"targets", "status", "discover"},
    "macos:app": set(),
    "macos:share": {"services"},
    "macos:pdf": {"info", "text", "outline", "annotations", "forms", "images", "find", "attributes", "permissions"},
    "macos:tcc": {"status"},
    "macos:fs": {"read", "search"},
    "macos:clipboard": {"read"},
    "macos:calendar": {"status", "list", "default", "sources", "events", "event", "event-by-external", "tail"},
    "macos:reminders": {"status", "lists", "default", "all", "incomplete", "completed"},
    "macos:contacts": {"status", "containers", "default-container", "groups", "group", "list", "contact", "me", "find", "vcard", "current-token", "changes"},
    "macos:photos": {"status", "albums", "album", "assets", "asset", "thumbnail", "export", "export-video", "export-live", "current-token", "changes"},
    "ios:app": set(),
    "ios:web": {"targets", "status", "explain", "read", "text", "find", "inspect", "console", "network", "screenshot"},
    "ios:fs": {"ls"},
}
FAMILY_MUTATE_SUBS: dict[str, set[str]] = {
    "macos:app": {"activate", "launch", "focus", "hide", "unhide"},
    "macos:tcc": set(),
    "ios:app": {"launch", "activate"},
    "ios:web": {"attach", "detach", "click", "type", "keys", "scroll", "calibrate"},
    "ios:fs": {"pull"},
}


# Keep in lockstep with cli/mcp/tiers.ts EXPLICIT.
EXPLICIT = {
    "browser:back": "mutate",
    "browser:batch": "mutate",
    "browser:blur": "mutate",
    "browser:brand": "mutate",
    "browser:capture": "mutate",
    "browser:check": "mutate",
    "browser:clear": "mutate",
    "browser:clipboard": "mutate",
    "browser:dblclick": "mutate",
    "browser:focus": "mutate",
    "browser:forward": "mutate",
    "browser:group": "mutate",
    "browser:notify": "mutate",
    "browser:regions": "mutate",
    "browser:reload": "mutate",
    "browser:rightclick": "mutate",
    "browser:session": "mutate",
    "browser:sse": "mutate",
    "browser:wait_for": "mutate",
    "browser:window": "mutate",
    "ios:tunnel": "mutate",
    "local:daemon": "mutate",
    "local:help": "read",
    "local:upgrade": "mutate",
}


def classification_keys() -> list[str]:
    keys = set()
    for surface, verbs in READ_VERBS.items():
        for verb in verbs:
            keys.add(f"{surface}:{verb}")
    for table in (EXEC, DESTRUCTIVE_SUB, FAMILY_FLOOR, EXPLICIT):
        for key in table:
            surface, verb, *_ = key.split(":")
            if surface and verb:
                keys.add(f"{surface}:{verb}")
    return sorted(keys)


def sub_verb_of(args: list[str]) -> str:
    """First non-flag token after the verb (the sub-verb), else ''."""
    for a in args:
        if not a.startswith("-"):
            return a
    return ""


class Classification(NamedTuple):
    tier: str
    surface: str
    verb: str
    sub: str


def classify(surface: str, verb: str, args: list[str]) -> Classification:
    sub = sub_verb_of(args)
    key3 = f"{surface}:{verb}:{sub}"
    key2 = f"{surface}:{verb}"

    def mk(tier: str) -> Classification:
        return Classification(tier, surface, verb, sub)

    # 1. exec (highest)
    if key3 in EXEC or key2 in EXEC:
        return mk("exec")
    # 2. destructive
    if key3 in DESTRUCTIVE_SUB:
        return mk("destructive")
    if surface == "macos" and verb == "share" and sub in SHARE_SEND:
        return mk("destructive")
    if surface == "macos" and verb == "pdf" and sub in PDF_WRITE:
        return mk("destructive")
    if surface == "macos" and verb in PD_VERBS and sub in PD_WRITE_SUBS:
        return mk("destructive")
    if surface == "ios" and verb in ("setup", "refresh", "install", "login", "logout", "kill"):
        return mk("destructive")
    if surface == "ios" and verb == "location" and sub == "set":
        return mk("destructive")
    if surface == "ios" and verb == "profiles" and sub in ("install", "remove"):
        return mk("destructive")
    # 3. read
    if verb in READ_VERBS.get(surface, ()):
        if key2 not in FAMILY_FLOOR:
            return mk("read")
    if key2 in FAMILY_FLOOR and sub in FAMILY_READ_SUBS.get(key2, ()):
        return mk("read")
    if key2 in FAMILY_FLOOR and sub in FAMILY_MUTATE_SUBS.get(key2, ()):
        return mk("mutate")
    # 4. mixed-family floor
    if key2 in FAMILY_FLOOR and sub:
        return mk(FAMILY_FLOOR[key2])
    if key2 in FAMILY_FLOOR and not sub:
        return mk("read")
    # 5. explicitly classified verbs (drift check fails if a new CLI verb is missing).
    if key2 in EXPLICIT:
        return mk(EXPLICIT[key2])
    # 6. default
    return mk("mutate")


class AllowSet(NamedTuple):
    tiers: frozenset
    verbs: frozenset
    raw: bool
    all: bool


def parse_allow(env: Optional[str]) -> AllowSet:
    tiers: set[str] = set()
    verbs: set[str] = set()
    raw = False
    all_ = False
    for tok_raw in (env or "").split(","):
        tok = tok_raw.strip().lower()
        if not tok:
            continue
        if tok == "all":
            all_ = True
        elif tok in ("raw", "ext"):
            raw = True
        elif tok == "destructive":
            tiers.add("destructive")
        elif tok in ("exec", "arbitrary-exec"):
            tiers.add("exec")
        elif tok == "read":
            tiers.add("read")
        elif tok == "mutate":
            tiers.add("mutate")
        elif ":" in tok:
            verbs.add(tok)
    return AllowSet(frozenset(tiers), frozenset(verbs), raw, all_)


class GateResult(NamedTuple):
    allowed: bool
    needs_confirm: bool
    reason: Optional[str] = None


def gate(c: Classification, allow: AllowSet, confirm: bool) -> GateResult:
    if c.tier in ("read", "mutate"):
        return GateResult(True, False)
    verb_key = f"{c.surface}:{c.verb}"
    operator_allowed = allow.all or c.tier in allow.tiers or verb_key in allow.verbs
    label = f"'{c.surface} {c.verb}{' ' + c.sub if c.sub else ''}'"
    if not operator_allowed:
        flag = "arbitrary-exec" if c.tier == "exec" else "destructive"
        return GateResult(
            False, False,
            f"{label} is {c.tier.upper()} and disabled. "
            f"The OPERATOR (not the model) must relaunch interceptor-mcp with "
            f"INTERCEPTOR_MCP_ALLOW={flag} (or ={verb_key}, or =all) to enable it.",
        )
    if not confirm:
        return GateResult(
            False, True,
            f"{label} is {c.tier.upper()} and operator-allowed, "
            f"but requires confirm:true on this call to proceed.",
        )
    return GateResult(True, False)
