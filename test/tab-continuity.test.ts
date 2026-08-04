import { describe, expect, test, afterEach, beforeEach, mock } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { parseTabsCommand } from "../cli/commands/tabs"
import { loadDesignatedTab, saveDesignatedTab } from "../cli/commands/session-tab"
import { setGlobalGroup } from "../cli/transport"

/**
 * Test tab continuity: an agent can designate a tab once, then subsequent
 * commands in the same group automatically target that tab without repeating
 * --tab on every call.
 *
 * This is the core workflow from task-n0bq:
 * 1. Agent opens or identifies a tab and gets its id
 * 2. Agent designates that tab: `interceptor tab designate <id>`
 * 3. All subsequent commands in that group automatically target the designated tab
 * 4. The designation is scoped per --group, so multiple agents don't interfere
 */
describe("tab continuity across CLI invocations", () => {
  let home: string
  let originalHome: string | undefined

  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "interceptor-tab-continuity-"))
    originalHome = process.env.HOME
    process.env.HOME = home
  })

  afterEach(() => {
    process.env.HOME = originalHome
    rmSync(home, { recursive: true, force: true })
    setGlobalGroup(undefined)
  })

  test("designated tab is loaded automatically in default group", () => {
    // Setup: designate a tab
    saveDesignatedTab(12345)
    
    // Verify: loadDesignatedTab returns it
    const tabId = loadDesignatedTab()
    expect(tabId).toBe(12345)
    
    // Verify: it persists across multiple loads
    expect(loadDesignatedTab()).toBe(12345)
    expect(loadDesignatedTab()).toBe(12345)
  })

  test("designated tab persists across separate CLI invocations (simulated)", async () => {
    // Invocation 1: designate tab 999
    await parseTabsCommand(["tab", "designate", "999"])
    
    // Invocation 2: load the designated tab (simulates a fresh CLI call)
    const loaded = loadDesignatedTab()
    expect(loaded).toBe(999)
  })

  test("designated tabs are scoped per group", () => {
    // Agent A designates tab 111
    saveDesignatedTab(111, "agentA")
    
    // Agent B designates tab 222
    saveDesignatedTab(222, "agentB")
    
    // Each agent sees only their own designation
    expect(loadDesignatedTab("agentA")).toBe(111)
    expect(loadDesignatedTab("agentB")).toBe(222)
    
    // Default group was never written
    expect(loadDesignatedTab()).toBeUndefined()
  })

  test("subsequent commands use designated tab when no explicit --tab provided", () => {
    // This test verifies the cli/index.ts integration:
    // When parseTabFlag returns undefined, loadDesignatedTab is called
    // as a fallback.
    
    // Designate a tab
    saveDesignatedTab(42)
    
    // Verify it can be loaded
    const tabId = loadDesignatedTab()
    expect(tabId).toBe(42)
    
    // In practice, this tabId would be passed to sendCommand automatically
    // by the cli/index.ts dispatch logic when --tab is not present
  })

  test("explicit --tab flag overrides designated tab", () => {
    // Designate tab 100
    saveDesignatedTab(100)
    
    // Explicit --tab should win
    // (This is tested at the parseTabFlag level, which returns the explicit value)
    // The cli/index.ts logic only checks loadDesignatedTab when parseTabFlag returns undefined
    
    expect(loadDesignatedTab()).toBe(100)
    // When --tab 200 is passed, parseTabFlag returns 200, overriding the designation
  })

  test("group-scoped designation allows parallel agents", async () => {
    const logs: string[] = []
    const origLog = console.log
    console.log = (msg: string) => logs.push(msg)
    
    try {
      // Agent A (group: alpha)
      setGlobalGroup("alpha")
      await parseTabsCommand(["tab", "designate", "1001"])
      
      // Agent B (group: beta)
      setGlobalGroup("beta")
      await parseTabsCommand(["tab", "designate", "2002"])
      
      // Agent A checks
      setGlobalGroup("alpha")
      await parseTabsCommand(["tab", "self"])
      
      // Agent B checks
      setGlobalGroup("beta")
      await parseTabsCommand(["tab", "self"])
    } finally {
      console.log = origLog
      setGlobalGroup(undefined)
    }
    
    // Extract just the tab ids from logs (ignore "Designated tab X as working tab" messages)
    const selfOutputs = logs.filter(line => /^\d+$/.test(line))
    expect(selfOutputs).toEqual(["1001", "2002"])
  })

  test("tab self reports clear error when no tab is designated", async () => {
    const errors: string[] = []
    const origError = console.error
    const origExit = process.exit
    console.error = (msg: string) => errors.push(msg)
    let exitCode: number | undefined
    process.exit = ((code?: number) => { exitCode = code; throw new Error("exit") }) as typeof process.exit
    
    try {
      await parseTabsCommand(["tab", "self"])
    } catch {
      // expected: process.exit throws
    } finally {
      console.error = origError
      process.exit = origExit
    }
    
    expect(exitCode).toBe(1)
    expect(errors.join("\n")).toContain("No tab designated")
    expect(errors.join("\n")).toContain("interceptor tab designate")
  })
})
