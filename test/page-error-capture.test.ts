/// <reference lib="dom" />

import { describe, expect, test } from "bun:test"
import { GlobalRegistrator } from "@happy-dom/global-registrator"

try { GlobalRegistrator.register() } catch { /* already registered by an earlier test file */ }

;(globalThis as any).chrome = {
  runtime: {
    onMessage: {
      addListener() {}
    }
  }
}

type PageErrorEntry = {
  type: string
  event: string
  level?: string
  message?: string
  source?: string
  line?: number
  column?: number
  stack?: string
}

describe("page error capture", () => {
  test("console.error/warn and window error/unhandledrejection surface as page_error entries and call through to the originals; console.log/info stay untouched", async () => {
    // Spies must be installed before inject-net.ts is imported — it captures
    // console.error/console.warn at import time and must call through to
    // whatever was installed then.
    const nativeErrorCalls: unknown[][] = []
    const nativeWarnCalls: unknown[][] = []
    const nativeLog = console.log
    console.error = ((...args: unknown[]) => { nativeErrorCalls.push(args) }) as any
    console.warn = ((...args: unknown[]) => { nativeWarnCalls.push(args) }) as any

    // net-buffer.ts and inject-net.ts are plain injected scripts with no
    // exports (not ES modules), imported here for their side effects only.
    // @ts-expect-error TS2306: no exports to type — side-effect import only
    await import("../extension/src/content/net-buffer")
    // @ts-expect-error TS2306: no exports to type — side-effect import only
    await import("../extension/src/inject-net")

    console.error("boom", { code: 1 })
    console.warn("careful now")
    console.log("this should never be captured")

    window.dispatchEvent(new ErrorEvent("error", {
      message: "Uncaught TypeError: x is not a function",
      filename: "https://example.com/app.js",
      lineno: 42,
      colno: 7,
      error: new Error("x is not a function")
    }))

    const rejectionEvent = new Event("unhandledrejection", { cancelable: true }) as Event & { reason?: unknown }
    rejectionEvent.reason = new Error("promise blew up")
    window.dispatchEvent(rejectionEvent)

    // call-through: the native (spied) functions actually ran
    expect(nativeErrorCalls).toEqual([["boom", { code: 1 }]])
    expect(nativeWarnCalls).toEqual([["careful now"]])
    expect(console.log).toBe(nativeLog)

    const snapshot = (globalThis as any).__interceptorPageCommSnapshot() as PageErrorEntry[]
    const pageErrors = snapshot.filter((e) => e.type === "page_error")

    expect(pageErrors.some((e) => e.event === "console_error" && e.message?.includes("boom"))).toBe(true)
    expect(pageErrors.some((e) => e.event === "console_warn" && e.message?.includes("careful now"))).toBe(true)
    expect(pageErrors.some((e) => e.event === "window_error" && e.message?.includes("not a function"))).toBe(true)
    expect(pageErrors.some((e) => e.event === "unhandled_rejection" && e.message?.includes("promise blew up"))).toBe(true)
    expect(pageErrors.every((e) => e.event !== "console_log" && e.event !== "console_info")).toBe(true)
  })
})
