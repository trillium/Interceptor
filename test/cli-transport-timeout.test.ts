import { describe, expect, test } from "bun:test"
import { timeoutMessage, pickTimeoutForAction, INTERCEPTOR_TIMEOUT_MS } from "../cli/transport"
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

  test("macos_update outwaits the bounded 10s Sparkle conclusion window", () => {
    // UpdateDomain.beginCheck waits up to 10s for the delegate conclusion
    // before returning a truthful `checking` result; the CLI must not time
    // out first and misreport a slow feed as a transport failure.
    expect(pickTimeoutForAction("macos_update")).toBe(20_000)
  })

  test("unlisted actions fall back to the default timeout", () => {
    expect(pickTimeoutForAction("tab_list")).toBe(INTERCEPTOR_TIMEOUT_MS)
  })
  test("cdp/app contexts name the endpoint, not the browser extension", () => {
    for (const ctx of ["cdp:Slack", "app:Slack"]) {
      const msg = timeoutMessage("read", 15000, ctx)
      expect(msg).toContain(ctx)
      expect(msg).toContain("endpoint")
      expect(msg).not.toContain("browser extension")
    }
  })

  test("ios contexts name the runner, not the browser extension", () => {
    const msg = timeoutMessage("read", 15000, "ios:00008110-0000000000000000")
    expect(msg).toContain("InterceptorRunner")
    expect(msg).not.toContain("browser extension")
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

  test("non-integer targets fall back to designated", () => {
    expect(resolveEffectiveTabId({ type: "tab_switch", tabId: NaN }, 222)).toBe(222)
    expect(resolveEffectiveTabId({ type: "tab_close", tabId: parseInt("abc") }, 222)).toBe(222)
    expect(resolveEffectiveTabId({ type: "tab_switch", tabId: NaN }, undefined)).toBeUndefined()
  })
})
