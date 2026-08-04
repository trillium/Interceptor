import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

// Mock the daemon command module with test-friendly dependencies
type DaemonKillDeps = {
  existsSync: (path: string) => boolean
  readFileSync: (path: string, encoding: string) => string
  unlinkSync: (path: string) => void
  kill: (pid: number, signal?: string | number) => void
  sleep: (ms: number) => Promise<void>
}

type KillResult = {
  success: boolean
  message: string
  pid?: number
  cleaned?: string[]
}

function makeMockDeps(overrides: Partial<DaemonKillDeps> = {}): DaemonKillDeps & { files: Map<string, string>; unlinked: string[]; alive: Set<number> } {
  const files = new Map<string, string>()
  const unlinked: string[] = []
  const alive = new Set<number>()

  const deps: DaemonKillDeps = {
    existsSync(path) {
      return files.has(path)
    },
    readFileSync(path) {
      const value = files.get(path)
      if (value === undefined) throw new Error(`missing ${path}`)
      return value
    },
    unlinkSync(path) {
      unlinked.push(path)
      files.delete(path)
    },
    kill(pid, signal) {
      if (!alive.has(pid)) throw new Error("ESRCH")
    },
    async sleep() {},
    ...overrides,
  }

  return Object.assign(deps, { files, unlinked, alive }) as DaemonKillDeps & { files: Map<string, string>; unlinked: string[]; alive: Set<number> }
}

async function doDaemonKill(
  deps: DaemonKillDeps & { files: Map<string, string>; unlinked: string[]; alive: Set<number> },
  pidPath: string,
  lockPath: string,
  socketPath: string,
): Promise<KillResult> {
  const cleaned: string[] = []
  let daemonPid: number | null = null

  // Try to read the PID from the lock file first (has more metadata)
  if (deps.existsSync(lockPath)) {
    try {
      const lockData = JSON.parse(deps.readFileSync(lockPath, "utf-8")) as { pid: number }
      daemonPid = lockData.pid
      // Check if process is still alive
      try {
        deps.kill(daemonPid, 0)
        // Process exists, will try to kill it
      } catch {
        // Process is dead; treat as stale
        daemonPid = null
      }
    } catch {
      daemonPid = null
    }
  }

  // Fallback: read from PID file
  if (!daemonPid && deps.existsSync(pidPath)) {
    try {
      const content = deps.readFileSync(pidPath, "utf-8").trim()
      const firstLine = content.split("\n")[0]
      const pid = parseInt(firstLine, 10)
      daemonPid = Number.isFinite(pid) && pid > 0 ? pid : null
      if (daemonPid) {
        try {
          deps.kill(daemonPid, 0)
        } catch {
          daemonPid = null
        }
      }
    } catch {
      daemonPid = null
    }
  }

  // No daemon found
  if (!daemonPid) {
    // Clean up stale artifacts anyway
    if (deps.existsSync(pidPath)) {
      try {
        deps.unlinkSync(pidPath)
        cleaned.push(pidPath)
      } catch {}
    }
    if (deps.existsSync(lockPath)) {
      try {
        deps.unlinkSync(lockPath)
        cleaned.push(lockPath)
      } catch {}
    }
    if (deps.existsSync(socketPath)) {
      try {
        deps.unlinkSync(socketPath)
        cleaned.push(socketPath)
      } catch {}
    }

    const msg = cleaned.length > 0
      ? `no daemon running, cleaned ${cleaned.length} stale artifact(s)`
      : "no daemon running"
    return { success: true, message: msg, cleaned }
  }

  // Kill the daemon
  try {
    deps.kill(daemonPid, "SIGTERM")
    await deps.sleep(500)
    // Verify it's gone via kill(pid, 0)
    try {
      deps.kill(daemonPid, 0)
      // Still alive; force kill
      deps.kill(daemonPid, "SIGKILL")
      await deps.sleep(200)
    } catch {
      // Already dead, good
    }
  } catch {
    // Failed to kill
    return {
      success: false,
      message: `failed to kill daemon (pid ${daemonPid}); stale artifacts may remain`,
      pid: daemonPid,
      cleaned,
    }
  }

  // Clean up files
  if (deps.existsSync(pidPath)) {
    try {
      deps.unlinkSync(pidPath)
      cleaned.push(pidPath)
    } catch {}
  }
  if (deps.existsSync(lockPath)) {
    try {
      deps.unlinkSync(lockPath)
      cleaned.push(lockPath)
    } catch {}
  }
  if (deps.existsSync(socketPath)) {
    try {
      deps.unlinkSync(socketPath)
      cleaned.push(socketPath)
    } catch {}
  }

  return {
    success: true,
    message: `killed daemon (pid ${daemonPid}), cleaned ${cleaned.length} artifact(s)`,
    pid: daemonPid,
    cleaned,
  }
}

describe("daemon teardown", () => {
  let pidPath: string
  let lockPath: string
  let socketPath: string

  beforeEach(() => {
    pidPath = "/tmp/test.pid"
    lockPath = "/tmp/test.lock"
    socketPath = "/tmp/test.sock"
  })

  test("kills a running daemon and cleans up files", async () => {
    const deps = makeMockDeps()
    deps.alive.add(5555)
    deps.files.set(pidPath, "5555")
    deps.files.set(lockPath, JSON.stringify({ pid: 5555 }))
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.pid).toBe(5555)
    expect(result.cleaned).toEqual([pidPath, lockPath, socketPath])
    expect(deps.unlinked).toEqual([pidPath, lockPath, socketPath])
  })

  test("handles stale pid file (process dead)", async () => {
    const deps = makeMockDeps()
    // Process 5555 is not alive
    deps.files.set(pidPath, "5555")
    deps.files.set(lockPath, JSON.stringify({ pid: 5555 }))
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.message).toContain("no daemon running")
    expect(result.message).toContain("cleaned")
    expect(result.cleaned).toEqual([pidPath, lockPath, socketPath])
  })

  test("is idempotent when no daemon is running", async () => {
    const deps = makeMockDeps()
    // No files exist, no daemon running

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.message).toBe("no daemon running")
    expect(result.cleaned).toEqual([])
    expect(deps.unlinked).toEqual([])
  })

  test("cleans up stale files when daemon is gone", async () => {
    const deps = makeMockDeps()
    // Files exist but daemon (pid 5555) is not alive
    deps.files.set(pidPath, "5555")
    deps.files.set(lockPath, JSON.stringify({ pid: 5555 }))
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.cleaned?.length).toBe(3)
    expect(deps.unlinked).toContain(pidPath)
    expect(deps.unlinked).toContain(lockPath)
    expect(deps.unlinked).toContain(socketPath)
  })

  test("reads pid from lock file first, falls back to pid file", async () => {
    const deps = makeMockDeps()
    deps.alive.add(6666)
    // Lock file has correct PID
    deps.files.set(lockPath, JSON.stringify({ pid: 6666 }))
    // PID file would have different PID (shouldn't be used)
    deps.files.set(pidPath, "9999")
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    // Should have used 6666 from lock file
    expect(result.success).toBe(true)
    expect(result.pid).toBe(6666)
  })

  test("handles invalid pid file gracefully", async () => {
    const deps = makeMockDeps()
    deps.files.set(pidPath, "not-a-number")
    deps.files.set(lockPath, "invalid-json")
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.message).toContain("no daemon running")
    expect(result.cleaned).toEqual([pidPath, lockPath, socketPath])
  })

  test("reports when kill fails", async () => {
    const deps = makeMockDeps({
      kill(pid: number, signal?: string | number) {
        if (signal === 0) {
          // Process alive check — signal 0 succeeds
          if (!deps.alive.has(pid)) throw new Error("ESRCH")
        } else {
          // Actual kill attempt fails
          throw new Error("permission denied")
        }
      },
    })
    deps.alive.add(5555)
    deps.files.set(pidPath, "5555")
    deps.files.set(lockPath, JSON.stringify({ pid: 5555 }))

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(false)
    expect(result.message).toContain("failed to kill daemon")
    expect(result.pid).toBe(5555)
  })

  test("parses multiline pid file correctly", async () => {
    const deps = makeMockDeps()
    deps.alive.add(7777)
    // Multiline PID file (first line is PID)
    deps.files.set(pidPath, "7777\nunix:/tmp/interceptor.sock\n")
    deps.files.set(socketPath, "")

    const result = await doDaemonKill(deps, pidPath, lockPath, socketPath)

    expect(result.success).toBe(true)
    expect(result.pid).toBe(7777)
  })
})
