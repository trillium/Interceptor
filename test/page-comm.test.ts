import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { parseNetworkCommand } from "../cli/commands/network"
import { parseMonitorCommand, renderEvent } from "../cli/commands/monitor"

const root = new URL("..", import.meta.url).pathname
const injectNet = readFileSync(`${root}/extension/src/inject-net.ts`, "utf-8")
const netBuffer = readFileSync(`${root}/extension/src/content/net-buffer.ts`, "utf-8")
const monitorContent = readFileSync(`${root}/extension/src/content/monitor.ts`, "utf-8")
const passiveNet = readFileSync(`${root}/extension/src/background/capabilities/passive-net.ts`, "utf-8")
const router = readFileSync(`${root}/extension/src/background/router.ts`, "utf-8")
const manifest = JSON.parse(readFileSync(`${root}/extension/manifest.json`, "utf-8")) as {
  content_scripts: Array<{ js?: string[]; run_at?: string; world?: string }>
}
const buildBridge = readFileSync(`${root}/scripts/build-bridge.sh`, "utf-8")

describe("page communication capture source", () => {
  test("WebSocket wrapper preserves constructor shape and captures lifecycle/send/message", () => {
    expect(injectNet).toContain("Reflect.construct(OriginalWebSocket")
    expect(injectNet).toContain("InterceptorWebSocket.prototype = OriginalWebSocket.prototype")
    expect(injectNet).toContain("CONNECTING: { value: OriginalWebSocket.CONNECTING }")
    expect(injectNet).toContain("event: \"ws_opening\"")
    expect(injectNet).toContain("event: \"ws_send\"")
    expect(injectNet).toContain("event: \"ws_message\"")
    expect(injectNet).toContain("event: \"ws_error\"")
    expect(injectNet).toContain("event: \"ws_close\"")
    expect(injectNet).toContain("return originalSend(data)")
  })

  test("Beacon wrapper preserves return/throw behavior and records no response", () => {
    expect(injectNet).toContain("navigator.sendBeacon = function")
    expect(injectNet).toContain("const result = originalBeacon(url, data)")
    expect(injectNet).toContain("returnValue: result")
    expect(injectNet).toContain("throw err")
    expect(injectNet).not.toContain("event: \"beacon\",\\n          status")
  })

  test("BroadcastChannel wrapper captures channel and message events as page communication", () => {
    expect(injectNet).toContain("Reflect.construct(OriginalBroadcastChannel")
    expect(injectNet).toContain("event: \"broadcast_open\"")
    expect(injectNet).toContain("event: \"broadcast_send\"")
    expect(injectNet).toContain("event: \"broadcast_message\"")
    expect(injectNet).toContain("event: \"broadcast_error\"")
    expect(injectNet).toContain("event: \"broadcast_close\"")
    expect(injectNet).toContain("type: \"broadcast\"")
  })

  test("dynamic registration is document_start MAIN world and not persistent unless requested", () => {
    expect(passiveNet).toContain("chrome.storage.local.set")
    expect(passiveNet).toContain("chrome.storage.local.get")
    expect(passiveNet).toContain("chrome.scripting.registerContentScripts")
    expect(passiveNet).toContain("runAt: \"document_start\"")
    expect(passiveNet).toContain("world: \"MAIN\"")
    expect(passiveNet).toContain("persistAcrossSessions: config.persistAcrossSessions")
    expect(passiveNet).toContain("injectImmediately: true")
    expect(router).toContain("restorePageCommCaptureConfig()")
  })

  test("page communication buffer is installed at document_start before page scripts", () => {
    const bufferScriptIndex = manifest.content_scripts.findIndex(script => script.js?.includes("net-buffer-content.js"))
    const mainWorldIndex = manifest.content_scripts.findIndex(script => script.js?.includes("inject-net.js"))
    expect(bufferScriptIndex).toBeGreaterThanOrEqual(0)
    expect(mainWorldIndex).toBeGreaterThanOrEqual(0)
    expect(bufferScriptIndex).toBeLessThan(mainWorldIndex)
    expect(manifest.content_scripts[bufferScriptIndex]?.run_at).toBe("document_start")
    expect(manifest.content_scripts[bufferScriptIndex]?.world).toBeUndefined()
  })

  test("monitor re-arm drains early page communication entries captured before document_idle", () => {
    expect(netBuffer).toContain("__interceptorPageCommSnapshot")
    expect(monitorContent).toContain("drainBufferedPageComm(_startedAt)")
    expect(monitorContent).toContain("entry.timestamp < startedAt")
  })

  test("webRequest is not the source of WebSocket frame capture", () => {
    expect(passiveNet).not.toContain("webRequest")
    expect(injectNet).toContain("__interceptor_page_comm")
  })
})

describe("page communication CLI parsing", () => {
  test("net monitor on parses attach-now and from-start controls", () => {
    const action = parseNetworkCommand(["net", "monitor", "on", "--reload", "--filter", "https://example.com/*"]) as Record<string, unknown>
    expect(action.type).toBe("page_comm_enable")
    expect(action.reload).toBe(true)
    expect(action.patterns).toEqual(["https://example.com/*"])
    expect(action.persistAcrossSessions).toBe(false)
  })

  test("net page-comm log parses filters", () => {
    const action = parseNetworkCommand(["net", "page-comm", "log", "--type", "ws", "--filter", "/socket", "--limit", "5"]) as Record<string, unknown>
    expect(action.type).toBe("page_comm_log")
    expect(action.entryType).toBe("ws")
    expect(action.filter).toBe("/socket")
    expect(action.limit).toBe(5)
  })

  test("monitor start parses page-comm reload mode", async () => {
    const action = await parseMonitorCommand(["monitor", "start", "--capture", "page-comm", "--reload"])
    expect(action?.type).toBe("monitor_start")
    expect(action?.capture).toBe("page-comm")
    expect(action?.reload).toBe(true)
  })

  test("monitor renderer formats WebSocket, Beacon, and BroadcastChannel rows", () => {
    expect(renderEvent({ event: "ws_send", t: 1000, dir: "send", u: "wss://example.com/ws", pk: "string", bt: 5, skt: "ws-1" }, 1000)).toContain("ws_send")
    expect(renderEvent({ event: "beacon", t: 1000, u: "https://example.com/b", pk: "string", bt: 4, rv: true }, 1000)).toContain("return=true")
    expect(renderEvent({ event: "broadcast_message", t: 1000, dir: "receive", cn: "room", pk: "object", ch: "bc-1" }, 1000)).toContain("room")
  })
})

describe("JXA packaging guardrails", () => {
  test("bridge app bundle carries the Apple Events usage string", () => {
    expect(buildBridge).toContain("NSAppleEventsUsageDescription")
  })
})
