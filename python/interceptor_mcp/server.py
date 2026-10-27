"""Interceptor MCP server (Python stdlib port).

Mirrors cli/mcp/server.ts: a thin subprocess wrapper around the `interceptor` CLI
(see adapter.py), gated by the operator allowlist INTERCEPTOR_MCP_ALLOW (tiers.py),
with content-bearing output fenced (output.py). Speaks newline-delimited JSON-RPC
(MCP stdio transport).

interceptor_browser, interceptor_macos, and interceptor_ios use the reference verb
enums and the tier gate. interceptor_raw is registered and off unless the operator
allowlist includes `raw` (or `ext`). `all` does not enable it. When raw is on, the
argv must start with the verb (a leading flag is refused), and it is classified and gated — confirm is the second key, never a substitute
for the allowlist.

Still absent: `local upgrade`, and the help/extensions resources.
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
import threading
from typing import Any, Callable, Optional
from urllib.parse import urlsplit

from . import adapter, output, tiers
from .menus import BROWSER_VERBS, IOS_VERBS, MACOS_VERBS

CALL_TIMEOUT_MS = 660_000
RESOURCE_TIMEOUT_MS = 30_000
SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]


def _version() -> str:
    try:
        path = os.path.join(os.path.dirname(__file__), "..", "..", "cli", "version.ts")
        m = re.search(r'VERSION\s*=\s*"([^"]+)"', open(path, encoding="utf-8").read())
        if m:
            return m.group(1)
    except OSError:
        pass
    return "0.0.0"


# (verb, summary) — same order/text as LOCAL_VERBS in the TS server, minus `upgrade`.
LOCAL_VERBS = [
    ("status", "daemon/bridge/extension health"),
    ("manifest", "machine-readable capability manifest"),
    ("diagnose", "post-failure snapshot"),
    ("init", "bootstrap the daemon"),
    ("skills", "list/link skill packs"),
    ("research", "deep-research playbook + ledger"),
    ("extensions", "list installed extensions"),
    ("contexts", "list connected browser contexts"),
    ("capabilities", "available domains + verbs"),
]


def _fold(items: list[tuple[str, str]]) -> str:
    return "; ".join(f"{v} — {s}" for v, s in items)


READ_VERB_NAMES: list[str] = list(dict.fromkeys(
    v for s in ("browser", "macos", "ios") for v in tiers.READ_VERB_ORDER[s]))
LOCAL_VERB_NAMES = [v for v, _ in LOCAL_VERBS]
BROWSER_VERB_NAMES = [v for v, _ in BROWSER_VERBS]
MACOS_VERB_NAMES = [v for v, _ in MACOS_VERBS]
IOS_VERB_NAMES = [v for v, _ in IOS_VERBS]


def _schema(props: dict, required: list[str], *, forbid_extra: bool = True) -> dict:
    schema = {"$schema": "http://json-schema.org/draft-07/schema#", "type": "object",
              "properties": props, "required": required}
    if forbid_extra:
        schema["additionalProperties"] = False
    return schema


def split_raw_argv(args: list[str]) -> tuple[str, str, list[str]]:
    """Surface/verb split for interceptor_raw. Matches cli/mcp/server.ts."""
    if args and args[0] == "macos":
        return "macos", args[1] if len(args) > 1 else "", args[2:]
    if args and args[0] == "ios":
        return "ios", args[1] if len(args) > 1 else "", args[2:]
    return "browser", args[0] if args else "", args[1:]


def _str(desc: Optional[str] = None, enum: Optional[list[str]] = None) -> dict:
    d: dict = {"type": "string"}
    if enum:
        d["enum"] = enum
    if desc:
        d["description"] = desc
    return d


def _bool(desc: Optional[str] = None) -> dict:
    d: dict = {"type": "boolean"}
    if desc:
        d["description"] = desc
    return d


def _args(desc: str) -> dict:
    return {"type": "array", "items": {"type": "string"}, "description": desc}


TOOLS: list[dict] = [
    {
        "name": "interceptor_browser",
        "title": "Interceptor — browser",
        "description": (
            "Drive the user's real signed-in Chrome/Brave/Safari via Interceptor (DOM, network, tabs, editors, screenshots). "
            "verb menu: " + _fold(BROWSER_VERBS) +
            ". Put sub-args/flags in `args` (see the interceptor://manifest resource for exact flags/returns). "
            "eval/save run page code and require operator opt-in + confirm."
        ),
        "inputSchema": _schema({
            "verb": _str("browser verb", BROWSER_VERB_NAMES),
            "args": _args("verb arguments + flags, verbatim"),
            "context": _str("route to a specific browser context/profile"),
            "tab": {"type": "number", "description": "target a specific tab id"},
            "confirm": _bool("required for exec-tier verbs (eval/save) when operator-allowed"),
        }, ["verb"]),
    },
    {
        "name": "interceptor_macos",
        "title": "Interceptor — macOS",
        "description": (
            "Drive native macOS apps + OS via Interceptor (AX, background input, windows, capture, Apple Events, VM, runtime, personal data). "
            "verb menu: " + _fold(MACOS_VERBS) +
            ". Put the sub-verb + flags in `args` (see interceptor://help/macos). "
            "Destructive/exec verbs (app quit, vm delete, script, runtime, container, share) require operator opt-in + confirm."
        ),
        "inputSchema": _schema({
            "verb": _str("macOS top-level verb", MACOS_VERB_NAMES),
            "args": _args("sub-verb + arguments + flags, verbatim"),
            "confirm": _bool("required for destructive/exec verbs when operator-allowed"),
        }, ["verb"]),
    },
    {
        "name": "interceptor_ios",
        "title": "Interceptor — iOS",
        "description": (
            "Drive an owned, unlocked, Developer-Mode iPhone via Interceptor (UI automation, Instruments telemetry, device services, WebKit). "
            "verb menu: " + _fold(IOS_VERBS) +
            ". Put the sub-verb + flags in `args` (see interceptor://help/ios). "
            "setup/refresh/install/kill/eval/spawn require operator opt-in + confirm."
        ),
        "inputSchema": _schema({
            "verb": _str("iOS verb", IOS_VERB_NAMES),
            "args": _args("sub-verb + arguments + flags, verbatim"),
            "device": _str("target device alias or udid (--on)"),
            "session": _str("web session id (--session) for web verbs"),
            "confirm": _bool("required for destructive/exec verbs when operator-allowed"),
        }, ["verb"]),
    },
    {
        "name": "interceptor_read",
        "title": "Interceptor — read (observational)",
        "description": ("Read-only observation across surfaces (no state change): trees, text, network, "
                        "screenshots, listings. Safe to auto-approve. verbs: " + ", ".join(READ_VERB_NAMES) + "."),
        "inputSchema": _schema({
            "surface": _str("which surface to read", ["browser", "macos", "ios"]),
            "verb": _str("read-only verb", READ_VERB_NAMES),
            "args": {"type": "array", "items": {"type": "string"}, "description": "arguments + flags, verbatim"},
            "context": {"type": "string"},
            "tab": {"type": "number"},
            "device": {"type": "string"},
        }, ["surface", "verb"]),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "interceptor_local",
        "title": "Interceptor — local/meta",
        "description": "Local, daemon-free meta commands: " + _fold(LOCAL_VERBS) + ".",
        "inputSchema": _schema({
            "verb": _str("local verb", LOCAL_VERB_NAMES),
            "args": {"type": "array", "items": {"type": "string"}},
        }, ["verb"]),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "interceptor_raw",
        "title": "Interceptor — raw passthrough",
        "description": (
            "Run `interceptor` with verbatim args (extension verbs, exotic flag combos). DISABLED unless the operator set "
            "INTERCEPTOR_MCP_ALLOW to include `raw`. The underlying verb is still tier-classified and gated."
        ),
        "inputSchema": _schema({
            "args": {
                "minItems": 1,
                "type": "array",
                "items": {"type": "string"},
                "description": "full interceptor argv, verbatim",
            },
            "confirm": {"type": "boolean"},
        }, ["args"], forbid_extra=False),
    },
]
_TOOL_BY_NAME = {t["name"]: t for t in TOOLS}

MANIFEST_RESOURCE = {
    "uri": "interceptor://manifest", "name": "manifest", "mimeType": "application/json",
    "description": "Machine-readable capability manifest (browser+local fully; macos/ios stubs)",
}


def _validate(tool: dict, args: Any) -> Optional[str]:
    """Return an error detail, or None. Mirrors zod object semantics: unknown keys are ignored,
    optional fields reject null."""
    if not isinstance(args, dict):
        return "Invalid input: expected object"
    schema = tool["inputSchema"]
    for name, spec in schema["properties"].items():
        if name not in args:
            if name in schema["required"]:
                return f"Invalid input: expected {spec['type']}, received undefined at {name}"
            continue
        v = args[name]
        t = spec["type"]
        if t == "string":
            if not isinstance(v, str):
                return f"Invalid input: expected string at {name}"
            if "enum" in spec and v not in spec["enum"]:
                return f"Invalid option: expected one of {'|'.join(spec['enum'])} at {name}"
        elif t == "number":
            if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
                return f"Invalid input: expected number at {name}"
        elif t == "boolean":
            if not isinstance(v, bool):
                return f"Invalid input: expected boolean at {name}"
        elif t == "array":
            if not isinstance(v, list):
                return f"Invalid input: expected array at {name}"
            if spec.get("minItems") and len(v) < spec["minItems"]:
                return f"Invalid input: expected at least {spec['minItems']} item(s) at {name}"
            if not all(isinstance(x, str) for x in v):
                return f"Invalid input: expected string at {name}[]"
    return None


class Session:
    def __init__(self) -> None:
        self.group = os.environ.get("INTERCEPTOR_MCP_GROUP") or f"mcp-{os.getpid()}"
        self.allow_env = os.environ.get("INTERCEPTOR_MCP_ALLOW")
        self.fence = (os.environ.get("INTERCEPTOR_MCP_FENCE") or "on").lower() != "off"


def _text_error(text: str) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": True}


def _run_verb(session: Session, surface: str, verb: str, args: list[str], flags: dict, cli_args: list[str]) -> dict:
    c = tiers.classify(surface, verb, args)
    g = tiers.gate(c, tiers.parse_allow(session.allow_env), flags.get("confirm") is True)
    if not g.allowed:
        return _text_error(g.reason or "refused")
    browser, ios = surface == "browser", surface == "ios"
    injected = adapter.with_global_flags(
        cli_args,
        group=flags.get("group") if browser else None,
        context=flags.get("context") if browser else None,
        tab=flags.get("tab") if browser else None,
        device=flags.get("device") if ios else None,
        session=flags.get("session") if ios else None,
    )
    run = adapter.run_interceptor(injected, CALL_TIMEOUT_MS)
    return output.to_result(surface, verb, run.stdout, run.stderr, run.code, session.fence)


def _tool_browser(session: Session, a: dict) -> dict:
    args = a.get("args") or []
    return _run_verb(
        session, "browser", a["verb"], args,
        {"group": session.group, "context": a.get("context"), "tab": a.get("tab"), "confirm": a.get("confirm")},
        [a["verb"], *args],
    )


def _tool_macos(session: Session, a: dict) -> dict:
    args = a.get("args") or []
    return _run_verb(
        session, "macos", a["verb"], args,
        {"confirm": a.get("confirm")},
        ["macos", a["verb"], *args],
    )


def _tool_ios(session: Session, a: dict) -> dict:
    args = a.get("args") or []
    return _run_verb(
        session, "ios", a["verb"], args,
        {"device": a.get("device"), "session": a.get("session"), "confirm": a.get("confirm")},
        ["ios", a["verb"], *args],
    )


def _tool_read(session: Session, a: dict) -> dict:
    surface, verb, args = a["surface"], a["verb"], a.get("args") or []
    if verb not in tiers.READ_VERBS.get(surface, ()):
        return _text_error(f"'{verb}' is not a read-only verb on {surface}. Use interceptor_{surface}.")
    cli_args = [verb, *args] if surface == "browser" else [surface, verb, *args]
    return _run_verb(session, surface, verb, args, session_flags(session, a), cli_args)


def session_flags(session: Session, a: dict) -> dict:
    return {"group": session.group, "context": a.get("context"), "tab": a.get("tab"), "device": a.get("device")}


def _tool_local(session: Session, a: dict) -> dict:
    verb, args = a["verb"], a.get("args") or []
    run = adapter.run_interceptor([verb, *args], CALL_TIMEOUT_MS)
    return output.to_result("local", verb, run.stdout, run.stderr, run.code, session.fence)


_RAW_OFF = "interceptor_raw is disabled. Operator must relaunch with INTERCEPTOR_MCP_ALLOW=raw."
_RAW_LEADING_FLAG = "interceptor_raw argv must start with the verb (or macos/ios), not a flag. Put the verb first and flags after it."


def _tool_raw(session: Session, a: dict) -> dict:
    if not tiers.parse_allow(session.allow_env).raw:
        return _text_error(_RAW_OFF)
    args = a["args"]
    if args[0].startswith("-"):
        return _text_error(_RAW_LEADING_FLAG)
    surface, verb, rest = split_raw_argv(args)
    return _run_verb(
        session, surface, verb, rest,
        {"group": session.group, "confirm": a.get("confirm")},
        args,
    )


_HANDLERS: dict[str, Callable[[Session, dict], dict]] = {
    "interceptor_browser": _tool_browser,
    "interceptor_macos": _tool_macos,
    "interceptor_ios": _tool_ios,
    "interceptor_read": _tool_read,
    "interceptor_local": _tool_local,
    "interceptor_raw": _tool_raw,
}


# ── resources ────────────────────────────────────────────────────────────────

def _dot_kind(seg: str) -> int:
    s = seg.lower()
    if s in (".", "%2e"):
        return 1
    if s in ("..", ".%2e", "%2e.", "%2e%2e"):
        return 2
    return 0


def normalize_uri(uri: str) -> str:
    """Approximate WHATWG URL serialization for this scheme: collapse dot segments
    (including %2e forms) so `interceptor://help/../x` is judged as `interceptor://help/x`,
    exactly as the TS server's `new URL()` does. Encoded slashes are left alone."""
    parts = urlsplit(uri)
    if parts.scheme != "interceptor" or parts.query or parts.fragment or "?" in uri or "#" in uri:
        return uri
    if not parts.path:
        return f"interceptor://{parts.netloc}"
    out: list[str] = []
    segs = parts.path.split("/")[1:]
    for i, seg in enumerate(segs):
        k = _dot_kind(seg)
        last = i == len(segs) - 1
        if k == 2:
            if out:
                out.pop()
            if last:
                out.append("")
        elif k == 1:
            if last:
                out.append("")
        else:
            out.append(seg)
    return f"interceptor://{parts.netloc}/" + "/".join(out)


def _read_resource(session: Session, uri: str) -> Optional[dict]:
    if normalize_uri(uri) != MANIFEST_RESOURCE["uri"]:
        return None
    run = adapter.run_interceptor(["manifest"], RESOURCE_TIMEOUT_MS)
    return {"contents": [{"uri": MANIFEST_RESOURCE["uri"], "mimeType": "application/json",
                          "text": run.stdout or run.stderr}]}


# ── JSON-RPC dispatch ────────────────────────────────────────────────────────

class RpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def handle(session: Session, method: str, params: Any) -> Any:
    params = params if isinstance(params, dict) else {}
    if method == "initialize":
        want = params.get("protocolVersion")
        return {
            "protocolVersion": want if want in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}},
            "serverInfo": {"name": "interceptor", "version": _version()},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name")
        tool = _TOOL_BY_NAME.get(name) if isinstance(name, str) else None
        if tool is None:
            return _text_error(f"MCP error -32602: Tool {name} not found")
        args = params.get("arguments", {})
        err = _validate(tool, args)
        if err:
            return _text_error(f"MCP error -32602: Input validation error: Invalid arguments for tool {name}: {err}")
        return _HANDLERS[name](session, args)
    if method == "resources/list":
        return {"resources": [MANIFEST_RESOURCE]}
    if method == "resources/templates/list":
        return {"resourceTemplates": []}
    if method == "resources/read":
        uri = params.get("uri")
        res = _read_resource(session, uri) if isinstance(uri, str) else None
        if res is None:
            raise RpcError(-32602, f"MCP error -32602: Resource {uri if isinstance(uri, str) else ''} not found")
        return res
    raise RpcError(-32601, "Method not found")


def serve(stdin=None, stdout=None) -> None:
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    session = Session()
    lock = threading.Lock()

    def send(msg: dict) -> None:
        with lock:
            stdout.write(json.dumps(msg, ensure_ascii=False, separators=(",", ":")) + "\n")
            stdout.flush()

    def process(msg: Any) -> None:
        if not isinstance(msg, dict) or not isinstance(msg.get("method"), str):
            return  # responses / junk from the client are ignored
        mid, is_request = msg.get("id"), "id" in msg
        try:
            result = handle(session, msg["method"], msg.get("params"))
            if is_request:
                send({"jsonrpc": "2.0", "id": mid, "result": result})
        except RpcError as e:
            if is_request:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": e.code, "message": e.message}})
        except Exception as e:  # never kill the server on a handler bug
            if is_request:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": f"Internal error: {e}"}})

    threads: list[threading.Thread] = []
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        t = threading.Thread(target=process, args=(msg,), daemon=True)
        t.start()
        threads.append(t)
        threads = [x for x in threads if x.is_alive()]
    for t in threads:  # stdin closed: let in-flight calls finish
        t.join()
