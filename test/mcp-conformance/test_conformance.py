#!/usr/bin/env python3
"""MCP conformance suite — runs the SAME cases against both implementations:

  ts : cli/mcp/server.ts           (reference, via test/mcp-conformance/ts_entry.ts, needs bun)
  py : python/interceptor_mcp      (stdlib port)

The `interceptor` CLI is replaced by test/mcp-conformance/fake_interceptor.py
(INTERCEPTOR_BIN), which logs every argv to $FAKE_LOG so tests can prove both what
reached the CLI and — for refusals — that nothing did.

Gate cases (destructive/exec, unknown sub-verb floor, allow+confirm, raw off by
default) run against both servers. The classifier itself is also compared to
cli/mcp/tiers.ts via ts_tiers.ts.

  python3 test/mcp-conformance/test_conformance.py            # both (default)
  MCP_IMPL=py python3 test/mcp-conformance/test_conformance.py  # one implementation
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from typing import Any, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FAKE = os.path.join(HERE, "fake_interceptor.py")
GROUP = "conf-group"
sys.path.insert(0, os.path.join(ROOT, "python"))
sys.path.insert(0, HERE)

import gate_cases  # noqa: E402
from interceptor_mcp import tiers  # noqa: E402
from interceptor_mcp.server import split_raw_argv  # noqa: E402

FROB_DISABLED = (
    "'macos vm frobnicate' is DESTRUCTIVE and disabled. "
    "The OPERATOR (not the model) must relaunch interceptor-mcp with "
    "INTERCEPTOR_MCP_ALLOW=destructive (or =macos:vm, or =all) to enable it."
)
FROB_NEEDS_CONFIRM = (
    "'macos vm frobnicate' is DESTRUCTIVE and operator-allowed, "
    "but requires confirm:true on this call to proceed."
)
RAW_OFF = "interceptor_raw is disabled. Operator must relaunch with INTERCEPTOR_MCP_ALLOW=raw."

IMPLS = {
    "ts": {"cmd": ["bun", os.path.join(HERE, "ts_entry.ts"), "__serve"], "env": {}},
    "py": {"cmd": [sys.executable, "-m", "interceptor_mcp", "--no-warm"],
           "env": {"PYTHONPATH": os.path.join(ROOT, "python")}},
}
ENABLED = [s for s in os.environ.get("MCP_IMPL", "ts,py").replace("both", "ts,py").split(",") if s]


class Client:
    def __init__(self, impl: str, env: Optional[dict] = None):
        self.tmp = tempfile.mkdtemp(prefix="mcp-conf-")
        self.log = os.path.join(self.tmp, "calls.log")
        self.shot = os.path.join(self.tmp, "shot.png")
        e = {**os.environ, "INTERCEPTOR_BIN": FAKE, "FAKE_LOG": self.log, "FAKE_SHOT_PATH": self.shot,
             "INTERCEPTOR_MCP_GROUP": GROUP, **IMPLS[impl]["env"], **(env or {})}
        for k in ("INTERCEPTOR_MCP_ALLOW", "INTERCEPTOR_MCP_FENCE"):
            if env is None or k not in env:
                e.pop(k, None)
        self.proc = subprocess.Popen(IMPLS[impl]["cmd"], cwd=ROOT, env=e, text=True, bufsize=1,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.q: "queue.Queue[dict]" = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self._id = 0
        r = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "conformance", "version": "1"}})
        assert "result" in r, r
        self.init = r["result"]
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _pump(self) -> None:
        for line in self.proc.stdout:
            try:
                self.q.put(json.loads(line))
            except ValueError:
                pass

    def _send(self, m: dict) -> None:
        self.proc.stdin.write(json.dumps(m) + "\n")
        self.proc.stdin.flush()

    def rpc(self, method: str, params: Optional[dict] = None, timeout: float = 20) -> dict:
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}})
        while True:
            m = self.q.get(timeout=timeout)
            if m.get("id") == self._id:
                return m

    def call(self, tool: str, **arguments: Any) -> dict:
        r = self.rpc("tools/call", {"name": tool, "arguments": arguments})
        assert "result" in r, f"tools/call must answer with a result, got {r}"
        return r["result"]

    def calls(self) -> list[list[str]]:
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(x) for x in f if x.strip()]

    def reset(self) -> None:
        if os.path.exists(self.log):
            os.remove(self.log)

    def close(self) -> None:
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        self.proc.stdout.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


def text_of(res: dict) -> str:
    return "\n".join(c["text"] for c in res["content"] if c["type"] == "text")


FENCE_OPEN = "⟦UNTRUSTED interceptor:"


class Conformance:
    impl = ""
    client: Client

    @classmethod
    def setUpClass(cls) -> None:
        cls.client = Client(cls.impl)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.client.close()

    def setUp(self) -> None:
        self.client.reset()

    def assertRefused(self, res: dict, needle: str = "") -> None:
        self.assertTrue(res.get("isError"), res)
        self.assertIn(needle, text_of(res))
        self.assertEqual(self.client.calls(), [], "a refused call must never reach the CLI")

    # ── handshake / discovery ────────────────────────────────────────────────
    def test_initialize(self):
        self.assertEqual(self.client.init["serverInfo"]["name"], "interceptor")
        self.assertIn("tools", self.client.init["capabilities"])
        self.assertIn("resources", self.client.init["capabilities"])

    def test_tools_list(self):
        tools = {t["name"]: t for t in self.client.rpc("tools/list")["result"]["tools"]}
        self.assertIn("interceptor_read", tools)
        self.assertIn("interceptor_local", tools)
        for t in ("interceptor_read", "interceptor_local"):
            self.assertTrue(tools[t]["annotations"]["readOnlyHint"])
        for name in ("interceptor_browser", "interceptor_macos", "interceptor_ios"):
            self.assertIn(name, tools)
            self.assertNotIn("annotations", tools[name], "mutate tools are not read-only")
        browser = tools["interceptor_browser"]["inputSchema"]["properties"]
        for v in ("click", "type", "keys", "scroll", "navigate", "tab", "act", "open"):
            self.assertIn(v, browser["verb"]["enum"])
        self.assertEqual(browser["confirm"]["type"], "boolean")
        macos = tools["interceptor_macos"]["inputSchema"]["properties"]
        ios = tools["interceptor_ios"]["inputSchema"]["properties"]
        for menu in (macos, ios):
            for v in ("click", "type", "keys", "scroll", "app"):
                self.assertIn(v, menu["verb"]["enum"])
        read = tools["interceptor_read"]["inputSchema"]
        self.assertEqual(read["properties"]["surface"]["enum"], ["browser", "macos", "ios"])
        verbs = read["properties"]["verb"]["enum"]
        for v in ("tree", "text", "find", "screenshot", "status", "manifest"):
            self.assertIn(v, verbs)
        for v in ("eval", "click", "type", "save", "script", "upgrade"):
            self.assertNotIn(v, verbs, "mutating/exec verbs must not be offered by the read tool")
        local = tools["interceptor_local"]["inputSchema"]["properties"]["verb"]["enum"]
        for v in ("status", "manifest", "diagnose", "extensions", "contexts", "capabilities"):
            self.assertIn(v, local)

    def test_resources(self):
        listed = self.client.rpc("resources/list")["result"]["resources"]
        self.assertIn("interceptor://manifest", [r["uri"] for r in listed])
        r = self.client.rpc("resources/read", {"uri": "interceptor://manifest"})["result"]["contents"][0]
        self.assertEqual(r["uri"], "interceptor://manifest")
        self.assertEqual(r["mimeType"], "application/json")
        self.assertEqual(json.loads(r["text"])["version"], "fake")
        self.assertEqual(self.client.calls(), [["manifest"]])

    # ── tool behaviour ───────────────────────────────────────────────────────
    def test_tree_fenced_and_group_injected(self):
        res = self.client.call("interceptor_read", surface="browser", verb="tree")
        self.assertFalse(res.get("isError"))
        t = text_of(res)
        self.assertTrue(t.startswith(FENCE_OPEN + "tree "), t)
        self.assertTrue(t.rstrip().endswith("⟦/UNTRUSTED⟧"))
        self.assertIn('[e1] button "Go"', t)
        self.assertEqual(self.client.calls(), [["tree", "--group", GROUP]])

    def test_tree_json_passthrough(self):
        res = self.client.call("interceptor_read", surface="browser", verb="tree", args=["--json"])
        self.assertEqual(self.client.calls(), [["tree", "--json", "--group", GROUP]])
        self.assertEqual(res["structuredContent"]["tree"][0]["ref"], "e1")

    def test_text_fenced(self):
        t = text_of(self.client.call("interceptor_read", surface="browser", verb="text", args=["--selector", "main"]))
        self.assertTrue(t.startswith(FENCE_OPEN + "text "))
        self.assertIn("Hello <b>world</b>", t)
        self.assertEqual(self.client.calls(), [["text", "--selector", "main", "--group", GROUP]])

    def test_find_array_becomes_items(self):
        res = self.client.call("interceptor_read", surface="browser", verb="find", args=["Go"])
        self.assertEqual([i["ref"] for i in res["structuredContent"]["items"]], ["e1", "e2"])
        self.assertTrue(text_of(res).startswith(FENCE_OPEN + "find "))

    def test_flag_injection_rules(self):
        self.client.call("interceptor_read", surface="browser", verb="tabs", context="work", tab=2.0)
        self.client.call("interceptor_read", surface="browser", verb="tabs", args=["--group", "mine"])
        self.client.call("interceptor_read", surface="macos", verb="tree", tab=9, context="x")
        self.client.call("interceptor_read", surface="ios", verb="tree", device="iphone", tab=9)
        self.assertEqual(self.client.calls(), [
            ["tabs", "--group", GROUP, "--context", "work", "--tab", "2"],
            ["tabs", "--group", "mine"],
            ["macos", "tree"],
            ["ios", "tree", "--on", "iphone"],
        ])

    def test_screenshot_data_url_is_image(self):
        res = self.client.call("interceptor_read", surface="browser", verb="screenshot")
        self.assertEqual(res["content"][0]["type"], "image")
        self.assertEqual(res["content"][0]["mimeType"], "image/png")
        self.assertTrue(res["content"][0]["data"].startswith("iVBOR"))

    def test_screenshot_saved_image_and_artifact(self):
        res = self.client.call("interceptor_read", surface="browser", verb="screenshot", args=["--save"])
        self.assertEqual([c["type"] for c in res["content"]], ["image", "text"])
        self.assertEqual(res["content"][0]["mimeType"], "image/png")
        self.assertEqual(res["content"][1]["text"], f"saved: {self.client.shot}")
        res = self.client.call("interceptor_read", surface="browser", verb="screenshot", args=["--save-bin"])
        link = res["content"][0]
        self.assertEqual(link["type"], "resource_link")
        self.assertEqual(link["uri"], f"file://{self.client.shot}.bin")

    def test_status_local_and_read(self):
        res = self.client.call("interceptor_local", verb="status")
        self.assertEqual(text_of(res), "mode: browser-only\ndaemon: up")
        self.assertNotIn("structuredContent", res)
        self.client.call("interceptor_read", surface="ios", verb="status")
        # local verbs carry no session group; surface verbs do
        self.assertEqual(self.client.calls(), [["status"], ["ios", "status"]])

    def test_manifest_and_diagnose_local(self):
        res = self.client.call("interceptor_local", verb="manifest")
        self.assertEqual(res["structuredContent"]["commands"][0]["name"], "tree")
        self.assertEqual(text_of(self.client.call("interceptor_local", verb="diagnose")), "diagnose: ok\ncontexts: 1")
        self.assertEqual(self.client.calls(), [["manifest"], ["diagnose"]])

    def test_cli_errors_surface_as_is_error(self):
        res = self.client.call("interceptor_read", surface="browser", verb="text", args=["--fake-fail"])
        self.assertTrue(res["isError"])
        self.assertIn("boom", text_of(res))
        res = self.client.call("interceptor_local", verb="status", args=["--fake-success-false"])
        self.assertTrue(res["isError"])
        self.assertIn("nope", text_of(res))

    def test_fence_can_be_disabled(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_FENCE": "off"})
        try:
            t = text_of(c.call("interceptor_read", surface="browser", verb="text"))
            self.assertEqual(t, "Hello <b>world</b>")
        finally:
            c.close()

    # ── refusal proofs ───────────────────────────────────────────────────────
    def test_refuses_unknown_verbs(self):
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="bogus"), "Input validation")
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="eval"), "Input validation")
        self.assertRefused(self.client.call("interceptor_read", surface="mars", verb="tree"), "Input validation")
        self.assertRefused(self.client.call("interceptor_local", verb="bogus"), "Input validation")
        self.assertRefused(self.client.call("interceptor_local", verb="tree; rm -rf /"), "Input validation")

    def test_refuses_wrong_surface_for_read_verb(self):
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="focused"),
                           "'focused' is not a read-only verb on browser")

    def test_refuses_malformed_input_unknown_tool_and_method(self):
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="tree", args="--json"),
                           "Input validation")
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="tree", args=[1]),
                           "Input validation")
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="tree", tab="2"),
                           "Input validation")
        self.assertRefused(self.client.call("interceptor_read", surface="browser", verb="tree", context=None),
                           "Input validation")
        self.assertRefused(self.client.call("interceptor_nope"), "not found")
        self.assertEqual(self.client.rpc("bogus/method")["error"]["code"], -32601)

    def test_gate_refuses_destructive_even_through_read_tool(self):
        # `ios profiles` is a read verb, but `profiles install` classifies DESTRUCTIVE.
        self.assertRefused(self.client.call("interceptor_read", surface="ios", verb="profiles",
                                            args=["install", "evil.mobileconfig"]), "DESTRUCTIVE and disabled")

    def test_operator_allow_alone_does_not_unlock_without_confirm(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "destructive"})
        try:
            res = c.call("interceptor_read", surface="ios", verb="profiles", args=["install", "x"])
            self.assertTrue(res["isError"])
            self.assertIn("requires confirm:true", text_of(res))
            self.assertEqual(c.calls(), [])
        finally:
            c.close()

    def _tools(self) -> dict:
        return {t["name"]: t for t in self.client.rpc("tools/list")["result"]["tools"]}

    def test_raw_off_by_default(self):
        raw = self._tools()["interceptor_raw"]
        self.assertNotIn("annotations", raw)
        self.assertEqual(raw["title"], "Interceptor — raw passthrough")
        self.assertRefused(self.client.call("interceptor_raw", args=["macos", "vm", "frobnicate"]), RAW_OFF)
        self.assertRefused(self.client.call("interceptor_raw", args=["macos", "vm", "delete"], confirm=True), RAW_OFF)
        self.assertRefused(self.client.call("interceptor_raw", args=[]), "Input validation")
        self.assertRefused(self.client.call("interceptor_raw", args=[1]), "Input validation")
        self.assertRefused(self.client.call("interceptor_raw", confirm="yes", args=["status"]), "Input validation")

    def test_all_does_not_enable_raw(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "all"})
        try:
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"], confirm=True)
            self.assertTrue(res.get("isError"), res)
            self.assertIn(RAW_OFF, text_of(res))
            self.assertEqual(c.calls(), [])
        finally:
            c.close()

    def test_unknown_subverb_defaults_high(self):
        # Named acceptance probe. Surface tool is the default path when the mutate
        # slice is present (always on the TS reference). Raw is the path both have.
        tools = self._tools()
        if "interceptor_macos" not in tools:
            self.fail(f"{self.impl} must expose interceptor_macos so the gate can refuse macos vm frobnicate")
        self.assertRefused(self.client.call("interceptor_macos", verb="vm", args=["frobnicate"]), FROB_DISABLED)
        self.assertRefused(
            self.client.call("interceptor_macos", verb="vm", args=["frobnicate"], confirm=True), FROB_DISABLED)
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw"})
        try:
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"])
            self.assertTrue(res.get("isError"), res)
            self.assertEqual(text_of(res), FROB_DISABLED)
            self.assertEqual(c.calls(), [])
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"], confirm=True)
            self.assertEqual(text_of(res), FROB_DISABLED)
            self.assertEqual(c.calls(), [])
        finally:
            c.close()

    def test_raw_refuses_leading_flag(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw"})
        try:
            for argv in (["--json", "macos", "vm", "delete"], ["--tab", "1", "eval", "x"]):
                for confirm in (None, True):
                    res = c.call("interceptor_raw", args=argv, confirm=confirm) if confirm else c.call("interceptor_raw", args=argv)
                    self.assertTrue(res.get("isError"), res)
                    self.assertIn("must start with the verb", text_of(res))
            self.assertEqual(c.calls(), [])
        finally:
            c.close()

    def test_every_high_tier_verb_refused_without_its_allow(self):
        probes = gate_cases.high_tier_probes()
        self.assertGreater(len(probes), 40)
        tools = self._tools()
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw"})
        try:
            for argv, tier in probes:
                c.reset()
                res = c.call("interceptor_raw", args=argv)
                msg = text_of(res)
                self.assertTrue(res.get("isError"), (argv, msg))
                self.assertIn(f"{tier.upper()} and disabled", msg, argv)
                flag = "arbitrary-exec" if tier == "exec" else "destructive"
                self.assertIn(f"INTERCEPTOR_MCP_ALLOW={flag}", msg, argv)
                self.assertIn("The OPERATOR (not the model)", msg, argv)
                self.assertEqual(c.calls(), [], argv)
                if "interceptor_macos" not in tools and "interceptor_browser" not in tools:
                    continue
                surface, verb, rest = split_raw_argv(argv)
                tool = {"browser": "interceptor_browser", "macos": "interceptor_macos",
                        "ios": "interceptor_ios"}.get(surface)
                spec = tools.get(tool or "")
                if not spec or verb not in spec["inputSchema"]["properties"]["verb"]["enum"]:
                    continue
                self.client.reset()
                self.assertRefused(self.client.call(tool, verb=verb, args=rest), f"{tier.upper()} and disabled")
        finally:
            c.close()

    def test_allow_and_confirm_admits_high_tier(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw,destructive"})
        try:
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"])
            self.assertEqual(text_of(res), FROB_NEEDS_CONFIRM)
            self.assertEqual(c.calls(), [])
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"], confirm=True)
            self.assertFalse(res.get("isError"), text_of(res))
            self.assertEqual(c.calls(), [["macos", "vm", "frobnicate"]])
            c.reset()
            res = c.call("interceptor_raw", args=["eval", "1"], confirm=True)
            self.assertIn("EXEC and disabled", text_of(res))
            self.assertEqual(c.calls(), [])
        finally:
            c.close()
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw,arbitrary-exec"})
        try:
            res = c.call("interceptor_raw", args=["eval", "1"])
            self.assertIn("requires confirm:true", text_of(res))
            self.assertEqual(c.calls(), [])
            res = c.call("interceptor_raw", args=["eval", "1"], confirm=True)
            self.assertFalse(res.get("isError"), text_of(res))
            self.assertEqual(c.calls(), [["eval", "1", "--group", GROUP]])
            c.reset()
            res = c.call("interceptor_raw", args=["macos", "vm", "frobnicate"], confirm=True)
            self.assertEqual(text_of(res), FROB_DISABLED)
            self.assertEqual(c.calls(), [])
        finally:
            c.close()
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw,macos:vm"})
        try:
            res = c.call("interceptor_raw", args=["macos", "vm", "delete", "box"], confirm=True)
            self.assertFalse(res.get("isError"), text_of(res))
            self.assertEqual(c.calls(), [["macos", "vm", "delete", "box"]])
            c.reset()
            res = c.call("interceptor_raw", args=["ios", "kill", "1"], confirm=True)
            self.assertIn("DESTRUCTIVE and disabled", text_of(res))
            self.assertEqual(c.calls(), [])
        finally:
            c.close()
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "ext,all"})
        try:
            res = c.call("interceptor_raw", args=["macos", "script", "beep"], confirm=True)
            self.assertFalse(res.get("isError"), text_of(res))
            self.assertEqual(c.calls(), [["macos", "script", "beep"]])
        finally:
            c.close()

    def test_ios_input_stays_mutate_and_raw_still_runs_reads(self):
        """iOS click/type/keys/scroll/drag/press stay mutate. See README."""
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "raw"})
        try:
            for argv in gate_cases.admitted_under_raw():
                surface, verb, rest = split_raw_argv(argv)
                got = tiers.classify(surface, verb, rest)
                self.assertIn(got.tier, ("read", "mutate"), argv)
                if argv[0] == "ios" and verb in ("click", "type", "keys", "scroll", "drag", "press"):
                    self.assertEqual(got.tier, "mutate", argv)
            res = c.call("interceptor_raw", args=["ios", "click", "e1"])
            self.assertFalse(res.get("isError"), text_of(res))
            self.assertEqual(c.calls(), [["ios", "click", "e1"]])
        finally:
            c.close()
        tools = self._tools()
        if "interceptor_ios" not in tools:
            self.fail(f"{self.impl} must expose interceptor_ios")
        self.client.reset()
        res = self.client.call("interceptor_ios", verb="click", args=["e1"])
        self.assertFalse(res.get("isError"), text_of(res))
        self.assertEqual(self.client.calls(), [["ios", "click", "e1"]])

    def test_refuses_path_traversal_verbs(self):
        for v in ("../../bin/sh", "..", "/etc/passwd", "tree/../eval", "tree\x00"):
            self.assertRefused(self.client.call("interceptor_read", surface="browser", verb=v), "Input validation")
            self.assertRefused(self.client.call("interceptor_local", verb=v), "Input validation")

    def test_mutate_verbs_reach_cli_with_session_flags(self):
        self.client.call("interceptor_browser", verb="click", args=["e1"])
        self.client.call("interceptor_browser", verb="type", args=["e2", "hi"])
        self.client.call("interceptor_browser", verb="keys", args=["Enter"])
        self.client.call("interceptor_browser", verb="scroll", args=["down"])
        self.client.call("interceptor_browser", verb="navigate", args=["https://example.test/p"])
        self.client.call("interceptor_browser", verb="tab", args=["new", "https://example.test/t"])
        self.client.call("interceptor_browser", verb="act", args=["e3", "typed"])
        self.client.call("interceptor_browser", verb="click", args=["e1"], context="work", tab=4)
        self.client.call("interceptor_browser", verb="click", args=["e9", "--group", "mine", "--tab", "9"])
        self.client.call("interceptor_macos", verb="click", args=["10", "20"])
        self.client.call("interceptor_macos", verb="type", args=["hello"])
        self.client.call("interceptor_macos", verb="keys", args=["cmd+c"])
        self.client.call("interceptor_macos", verb="scroll", args=["down"])
        self.client.call("interceptor_macos", verb="app", args=["activate", "Safari"])
        self.client.call("interceptor_ios", verb="click", args=["e1"], device="iphone")
        self.client.call("interceptor_ios", verb="type", args=["hi"])
        self.client.call("interceptor_ios", verb="keys", args=["Enter"])
        self.client.call("interceptor_ios", verb="scroll", args=["down"])
        self.client.call("interceptor_ios", verb="app", args=["activate", "com.example"],
                         device="phone", session="web1")
        self.assertEqual(self.client.calls(), [
            ["click", "e1", "--group", GROUP],
            ["type", "e2", "hi", "--group", GROUP],
            ["keys", "Enter", "--group", GROUP],
            ["scroll", "down", "--group", GROUP],
            ["navigate", "https://example.test/p", "--group", GROUP],
            ["tab", "new", "https://example.test/t", "--group", GROUP],
            ["act", "e3", "typed", "--group", GROUP],
            ["click", "e1", "--group", GROUP, "--context", "work", "--tab", "4"],
            ["click", "e9", "--group", "mine", "--tab", "9"],
            ["macos", "click", "10", "20"],
            ["macos", "type", "hello"],
            ["macos", "keys", "cmd+c"],
            ["macos", "scroll", "down"],
            ["macos", "app", "activate", "Safari"],
            ["ios", "click", "e1", "--on", "iphone"],
            ["ios", "type", "hi"],
            ["ios", "keys", "Enter"],
            ["ios", "scroll", "down"],
            ["ios", "app", "activate", "com.example", "--on", "phone", "--session", "web1"],
        ])

    def test_refuses_destructive_and_exec_on_default_allowlist(self):
        cases = [
            ("interceptor_browser", {"verb": "eval", "args": ["document.title"]}, "EXEC"),
            ("interceptor_browser", {"verb": "save", "args": ["--out", "/tmp/x", "blob"]}, "EXEC"),
            ("interceptor_macos", {"verb": "script", "args": ["beep"]}, "EXEC"),
            ("interceptor_macos", {"verb": "intent", "args": ["x"]}, "EXEC"),
            ("interceptor_macos", {"verb": "container", "args": ["run", "img"]}, "EXEC"),
            ("interceptor_macos", {"verb": "app", "args": ["quit", "Safari"]}, "DESTRUCTIVE"),
            ("interceptor_macos", {"verb": "app", "args": ["terminate", "Safari"]}, "DESTRUCTIVE"),
            ("interceptor_macos", {"verb": "vm", "args": ["delete", "box"]}, "DESTRUCTIVE"),
            ("interceptor_ios", {"verb": "eval", "args": ["1"]}, "EXEC"),
            ("interceptor_ios", {"verb": "spawn", "args": ["App"]}, "EXEC"),
            ("interceptor_ios", {"verb": "kill", "args": ["1"]}, "DESTRUCTIVE"),
            ("interceptor_ios", {"verb": "app", "args": ["terminate", "App"]}, "DESTRUCTIVE"),
            ("interceptor_ios", {"verb": "setup"}, "DESTRUCTIVE"),
        ]
        for tool, arguments, needle in cases:
            self.client.reset()
            res = self.client.call(tool, **arguments)
            self.assertRefused(res, needle)
        # `raw` is an exec CLI verb but not on the browser menu — schema rejection, still no CLI.
        self.client.reset()
        self.assertRefused(self.client.call("interceptor_browser", verb="raw", args=["1"]), "Input validation")
        # confirm alone cannot lift a tier the operator did not allow
        self.client.reset()
        self.assertRefused(
            self.client.call("interceptor_browser", verb="eval", args=["1"], confirm=True), "EXEC")
        self.client.reset()
        self.assertRefused(
            self.client.call("interceptor_macos", verb="app", args=["quit"], confirm=True), "DESTRUCTIVE")

    def test_allow_without_confirm_still_refuses_exec(self):
        c = Client(self.impl, {"INTERCEPTOR_MCP_ALLOW": "arbitrary-exec"})
        try:
            res = c.call("interceptor_browser", verb="eval", args=["1+1"])
            self.assertTrue(res.get("isError"), res)
            self.assertIn("requires confirm:true", text_of(res))
            self.assertEqual(c.calls(), [])
            res = c.call("interceptor_macos", verb="script", args=["beep"], confirm=True)
            self.assertFalse(res.get("isError"), res)
            self.assertEqual(c.calls(), [["macos", "script", "beep"]])
        finally:
            c.close()

    def test_refuses_bad_mutate_input(self):
        for tool in ("interceptor_browser", "interceptor_macos", "interceptor_ios"):
            self.assertRefused(self.client.call(tool, verb="../../bin/sh"), "Input validation")
            self.assertRefused(self.client.call(tool, verb="click", args="e1"), "Input validation")
            self.assertRefused(self.client.call(tool, verb="click", confirm="yes"), "Input validation")
        self.assertRefused(self.client.call("interceptor_browser", verb="click", tab="2"), "Input validation")

    def test_refuses_path_traversal_resource_uris(self):
        for uri in ("interceptor://manifest/../..", "interceptor://help/a/b", "interceptor://help/%2e%2e",
                    "interceptor://help/%2E%2E/%2e%2e", "interceptor://manifest/x", "file:///etc/passwd",
                    "interceptor://nope"):
            r = self.client.rpc("resources/read", {"uri": uri})
            self.assertIn("error", r, f"{uri} should be refused, got {r}")
            self.assertEqual(r["error"]["code"], -32602)
        self.assertEqual(self.client.calls(), [])


def _make(impl: str) -> type:
    return type(f"Conformance_{impl}", (Conformance, unittest.TestCase), {"impl": impl})


def load_tests(loader, tests, pattern):  # noqa: ARG001
    suite = unittest.TestSuite()
    for impl in ENABLED:
        if impl not in IMPLS:
            raise SystemExit(f"unknown MCP_IMPL entry {impl!r} (use ts, py)")
        if impl == "ts" and (not shutil.which("bun") or not os.path.isdir(os.path.join(ROOT, "node_modules", "@modelcontextprotocol"))):
            raise SystemExit("ts implementation needs `bun` and `bun install` (node_modules/@modelcontextprotocol). "
                             "Use MCP_IMPL=py to run only the Python port.")
        suite.addTests(loader.loadTestsFromTestCase(_make(impl)))
    if len(ENABLED) == 2:
        suite.addTest(CrossImpl("test_same_read_menu"))
        suite.addTest(CrossImpl("test_same_mutate_menus"))
        suite.addTest(CrossImpl("test_same_raw_tool"))
    if "ts" in ENABLED:
        suite.addTest(TierParity("test_python_matches_reference"))
    if "py" in ENABLED:
        suite.addTest(PythonOnly("test_local_upgrade_not_offered"))
        suite.addTest(PythonOnly("test_help_resources_not_offered"))
    return suite


def ts_tier_batch(reqs: list[dict]) -> list[dict]:
    proc = subprocess.run(
        ["bun", os.path.join(HERE, "ts_tiers.ts")],
        input=json.dumps(reqs), text=True, capture_output=True, cwd=ROOT, timeout=60,
    )
    if proc.returncode != 0:
        raise AssertionError(proc.stderr or proc.stdout)
    return json.loads(proc.stdout)


def _py_allow(env):
    a = tiers.parse_allow(env)
    return {"tiers": sorted(a.tiers), "verbs": sorted(a.verbs), "raw": a.raw, "all": a.all}


class TierParity(unittest.TestCase):
    """Python classify/gate/parseAllow must match cli/mcp/tiers.ts exactly."""

    def test_python_matches_reference(self):
        reqs = []
        expected = []
        for argv, tier in gate_cases.high_tier_probes():
            surface, verb, rest = split_raw_argv(argv)
            reqs.append({"op": "classify", "surface": surface, "verb": verb, "args": rest})
            expected.append((argv, tier))
        for argv in gate_cases.admitted_under_raw():
            surface, verb, rest = split_raw_argv(argv)
            reqs.append({"op": "classify", "surface": surface, "verb": verb, "args": rest})
            py = tiers.classify(surface, verb, rest)
            self.assertIn(py.tier, ("read", "mutate"), argv)
            expected.append((argv, py.tier))
        got = ts_tier_batch(reqs)
        self.assertEqual(len(got), len(expected))
        for (argv, tier), ts in zip(expected, got):
            surface, verb, rest = split_raw_argv(argv)
            py = tiers.classify(surface, verb, rest)
            self.assertEqual(py.tier, tier, argv)
            self.assertEqual(ts["tier"], tier, argv)
            self.assertEqual(py.sub, ts["sub"], argv)

        gate_reqs = [
            {"op": "gate", "surface": "macos", "verb": "vm", "args": ["frobnicate"], "confirm": False},
            {"op": "gate", "surface": "macos", "verb": "vm", "args": ["frobnicate"], "allow": "destructive", "confirm": False},
            {"op": "gate", "surface": "macos", "verb": "vm", "args": ["frobnicate"], "allow": "destructive", "confirm": True},
            {"op": "gate", "surface": "macos", "verb": "vm", "args": ["delete", "x"], "allow": "macos:vm", "confirm": True},
            {"op": "gate", "surface": "browser", "verb": "eval", "args": ["1"], "allow": "destructive", "confirm": True},
            {"op": "gate", "surface": "browser", "verb": "eval", "args": ["1"], "allow": "arbitrary-exec", "confirm": True},
            {"op": "gate", "surface": "browser", "verb": "eval", "args": ["1"], "allow": "exec", "confirm": True},
            {"op": "gate", "surface": "ios", "verb": "click", "args": ["e1"], "confirm": False},
            {"op": "parseAllow", "env": None},
            {"op": "parseAllow", "env": "destructive, arbitrary-exec, raw, macos:vm"},
            {"op": "parseAllow", "env": "all"},
            {"op": "parseAllow", "env": "EXT"},
            {"op": "parseAllow", "env": "  Destructive , RAW "},
        ]
        gg = ts_tier_batch(gate_reqs)
        for req, ts in zip(gate_reqs, gg):
            if req["op"] == "parseAllow":
                self.assertEqual(_py_allow(req["env"]), ts, req)
                continue
            py_c = tiers.classify(req["surface"], req["verb"], req["args"])
            py_g = tiers.gate(py_c, tiers.parse_allow(req.get("allow")), req.get("confirm") is True)
            self.assertEqual(py_g.allowed, ts["allowed"], req)
            self.assertEqual(py_g.needs_confirm, ts["needsConfirm"], req)
            self.assertEqual(py_g.reason, ts["reason"], req)
        self.assertEqual(gg[0]["reason"], FROB_DISABLED)
        self.assertEqual(gg[1]["needsConfirm"], True)
        self.assertEqual(gg[1]["reason"], FROB_NEEDS_CONFIRM)
        self.assertTrue(gg[2]["allowed"])
        self.assertEqual(gg[7]["tier"], "mutate")
        self.assertFalse(gg[10]["raw"])  # all does not enable raw
        self.assertTrue(gg[11]["raw"])


class CrossImpl(unittest.TestCase):
    def _tools(self):
        menus = {}
        for impl in ENABLED:
            c = Client(impl)
            try:
                menus[impl] = {t["name"]: t for t in c.rpc("tools/list")["result"]["tools"]}
            finally:
                c.close()
        return menus

    def test_same_read_menu(self):
        menus = self._tools()
        self.assertEqual(
            menus["ts"]["interceptor_read"]["inputSchema"]["properties"]["verb"]["enum"],
            menus["py"]["interceptor_read"]["inputSchema"]["properties"]["verb"]["enum"],
            "read verb menu must match the reference exactly")

    def test_same_mutate_menus(self):
        menus = self._tools()
        for name in ("interceptor_browser", "interceptor_macos", "interceptor_ios"):
            ts, py = menus["ts"][name], menus["py"][name]
            self.assertEqual(ts["description"], py["description"], name)
            self.assertEqual(ts["title"], py["title"], name)
            self.assertEqual(
                ts["inputSchema"]["properties"]["verb"]["enum"],
                py["inputSchema"]["properties"]["verb"]["enum"],
                name)
            self.assertEqual(
                set(ts["inputSchema"]["properties"]),
                set(py["inputSchema"]["properties"]),
                name)

    def test_same_raw_tool(self):
        tools = {}
        for impl in ENABLED:
            c = Client(impl)
            try:
                tools[impl] = {t["name"]: t for t in c.rpc("tools/list")["result"]["tools"]}["interceptor_raw"]
            finally:
                c.close()
        ts, py = tools["ts"], tools["py"]
        self.assertEqual(ts["title"], py["title"])
        self.assertEqual(ts["description"], py["description"])
        self.assertEqual(ts["inputSchema"], py["inputSchema"])
        self.assertEqual(ts.get("annotations"), py.get("annotations"))


class PythonOnly(unittest.TestCase):
    """Deliberate omissions versus the reference: local upgrade and discovery resources."""

    def test_local_upgrade_not_offered(self):
        c = Client("py")
        try:
            res = c.call("interceptor_local", verb="upgrade")
            self.assertTrue(res["isError"])
            self.assertEqual(c.calls(), [])
        finally:
            c.close()

    def test_help_resources_not_offered(self):
        c = Client("py")
        try:
            uris = {r["uri"] for r in c.rpc("resources/list")["result"]["resources"]}
            self.assertEqual(uris, {"interceptor://manifest"})
            self.assertEqual(c.calls(), [])
        finally:
            c.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
