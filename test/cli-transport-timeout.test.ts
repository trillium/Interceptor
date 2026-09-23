import { describe, expect, test } from "bun:test"
import { timeoutMessage } from "../cli/transport"
import { resolveEffectiveTabId } from "../cli/commands/tabs"

// robots-m0ay: a registered-but-silent browser context must fail with the
// context named and the real missing piece identified — never the generic
// "is Chrome open" hint when the browser is in fact open.
describe("cli transport timeoutMessage", () => {
  test("names the context when one was scoped", () => {
    const msg = timeoutMessage("tab_create", 15000, "stable")
    expect(msg).toContain("tab_create")
    expect(msg).toContain("stable")
    expect(msg).toContain("interceptor diagnose --context stable")
    expect(msg).toContain("interceptor contexts")
  })

  test("keeps the generic browser hint without a context", () => {
    const msg = timeoutMessage("tab_create", 15000)
    expect(msg).toContain("tab_create")
    expect(msg).toContain("Ensure Chrome/Brave is open")
    expect(msg).not.toContain("context")
  })

  test("macos/ios branches never get the browser hint", () => {
    expect(timeoutMessage("macos_screenshot", 15000, "stable")).toContain("macOS bridge")
    expect(timeoutMessage("ios_tree", 60000, "stable")).toContain("InterceptorRunner")
  })
})

describe("resolveEffectiveTabId", () => {
  test("explicit in-action target wins over the designated fallback", () => {
    expect(resolveEffectiveTabId({ type: "tab_close", tabId: 111 }, 222)).toBe(111)
    expect(resolveEffectiveTabId({ type: "tab_switch", tabId: 111 }, 222)).toBe(111)
  })

  test("falls back to designated when the action carries no target", () => {
    expect(resolveEffectiveTabId({ type: "tab_close" }, 222)).toBe(222)
    expect(resolveEffectiveTabId({ type: "tab_list" }, undefined)).toBeUndefined()
  })
})
