import { describe, expect, test, afterEach } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { loadDesignatedTab, saveDesignatedTab, clearDesignatedTab } from "../cli/commands/session-tab"

describe("session-tab — designated working tab state", () => {
  let home: string

  function freshHome(): string {
    home = mkdtempSync(join(tmpdir(), "interceptor-session-tab-"))
    return home
  }

  afterEach(() => {
    if (home) rmSync(home, { recursive: true, force: true })
  })

  test("returns undefined when nothing has been designated", () => {
    expect(loadDesignatedTab(undefined, freshHome())).toBeUndefined()
  })

  test("round-trips a designated tab id", () => {
    const h = freshHome()
    saveDesignatedTab(592791482, undefined, h)
    expect(loadDesignatedTab(undefined, h)).toBe(592791482)
  })

  test("re-designating overwrites the previous tab id", () => {
    const h = freshHome()
    saveDesignatedTab(111, undefined, h)
    saveDesignatedTab(222, undefined, h)
    expect(loadDesignatedTab(undefined, h)).toBe(222)
  })

  test("clearDesignatedTab removes the designation", () => {
    const h = freshHome()
    saveDesignatedTab(333, undefined, h)
    clearDesignatedTab(undefined, h)
    expect(loadDesignatedTab(undefined, h)).toBeUndefined()
  })

  test("survives a corrupt state file by returning undefined", async () => {
    const h = freshHome()
    saveDesignatedTab(444, undefined, h)
    await Bun.write(join(h, ".interceptor", "session-tab.json"), "not json")
    expect(loadDesignatedTab(undefined, h)).toBeUndefined()
  })

  test("reads a legacy flat { tabId } file as the default-group designation", async () => {
    const h = freshHome()
    mkdirSync(join(h, ".interceptor"), { recursive: true })
    await Bun.write(join(h, ".interceptor", "session-tab.json"), JSON.stringify({ tabId: 4242 }))
    expect(loadDesignatedTab(undefined, h)).toBe(4242)
  })

  test("a write failure prints a clean error and exits 1 instead of throwing", async () => {
    const h = freshHome()
    // Put a plain file where ~/.interceptor should be a directory, so the
    // write into it fails with ENOTDIR.
    await Bun.write(join(h, ".interceptor"), "not a directory")

    const errors: string[] = []
    const origError = console.error
    const origExit = process.exit
    console.error = (msg: string) => errors.push(msg)
    let exitCode: number | undefined
    process.exit = ((code?: number) => { exitCode = code; throw new Error("exit") }) as typeof process.exit
    try {
      expect(() => saveDesignatedTab(555, undefined, h)).toThrow("exit")
    } finally {
      console.error = origError
      process.exit = origExit
    }
    expect(exitCode).toBe(1)
    expect(errors.join("\n")).toContain("error: failed to save designated tab")
  })
})

describe("session-tab — per-group designation scoping", () => {
  let home: string

  function freshHome(): string {
    home = mkdtempSync(join(tmpdir(), "interceptor-session-tab-group-"))
    return home
  }

  afterEach(() => {
    if (home) rmSync(home, { recursive: true, force: true })
  })

  test("two groups each hold their own designated tab without clobber", () => {
    const h = freshHome()
    // Two concurrent agents designate under different groups.
    saveDesignatedTab(111, "agentA", h)
    saveDesignatedTab(222, "agentB", h)
    // Each recalls its own tab; neither overwrote the other.
    expect(loadDesignatedTab("agentA", h)).toBe(111)
    expect(loadDesignatedTab("agentB", h)).toBe(222)
  })

  test("re-designating within one group leaves the other group untouched", () => {
    const h = freshHome()
    saveDesignatedTab(111, "agentA", h)
    saveDesignatedTab(222, "agentB", h)
    saveDesignatedTab(333, "agentA", h)
    expect(loadDesignatedTab("agentA", h)).toBe(333)
    expect(loadDesignatedTab("agentB", h)).toBe(222)
  })

  test("the default (no-group) slot is independent of named groups", () => {
    const h = freshHome()
    saveDesignatedTab(999, undefined, h)
    saveDesignatedTab(111, "agentA", h)
    expect(loadDesignatedTab(undefined, h)).toBe(999)
    expect(loadDesignatedTab("agentA", h)).toBe(111)
  })

  test("a group with no designation reads undefined even when another group is set", () => {
    const h = freshHome()
    saveDesignatedTab(111, "agentA", h)
    expect(loadDesignatedTab("agentB", h)).toBeUndefined()
  })

  test("clearing one group leaves the others intact", () => {
    const h = freshHome()
    saveDesignatedTab(111, "agentA", h)
    saveDesignatedTab(222, "agentB", h)
    clearDesignatedTab("agentA", h)
    expect(loadDesignatedTab("agentA", h)).toBeUndefined()
    expect(loadDesignatedTab("agentB", h)).toBe(222)
  })

  // The mkdir-based lock in saveDesignatedTab is a cross-process mutex.
  // Racing two real writer processes and hoping they happen to overlap is a
  // false-positive risk: on a fast filesystem each read-modify-write can
  // complete in well under a millisecond, so two independently-scheduled
  // processes routinely finish without ever actually colliding — a test
  // built that way can pass even with the lock ripped out. Instead, force a
  // deterministic overlap: a real second process holds the lock for a fixed
  // window (via the exported acquireLock/releaseLock — the same primitives
  // saveDesignatedTab uses), and we assert that a concurrent saveDesignatedTab
  // call in this process both blocks for that window and loses no data.
  test("a concurrent designate under a different group blocks for the lock and neither write is lost", async () => {
    const h = freshHome()
    saveDesignatedTab(999, "agentA", h)

    const fixture = join(import.meta.dir, "fixtures", "session-tab-lock-holder.ts")
    const readyPath = join(h, "holder-ready")
    const holdMs = 300
    const holder = Bun.spawn(["bun", "run", fixture, h, String(holdMs), readyPath])

    // Wait for the holder to actually have the lock (not a fixed guess at
    // its startup time) before racing a writer against it.
    while (!existsSync(readyPath)) {
      await new Promise((resolve) => setTimeout(resolve, 5))
    }

    const before = Date.now()
    saveDesignatedTab(222, "agentB", h)
    const elapsed = Date.now() - before

    await holder.exited

    // Proves saveDesignatedTab actually waited on the lock rather than
    // racing past it — a broken/no-op lock would return almost instantly.
    expect(elapsed).toBeGreaterThanOrEqual(holdMs - 50)
    // Neither the pre-existing designation nor the new one was lost across
    // the contention.
    expect(loadDesignatedTab("agentA", h)).toBe(999)
    expect(loadDesignatedTab("agentB", h)).toBe(222)
  })
})
