/**
 * cli/commands/daemon.ts — daemon lifecycle management
 *
 * Supports `interceptor daemon kill` — gracefully shut down the daemon,
 * clean up PID/lock/socket files, and report what was done. Idempotent:
 * running with no daemon prints "no daemon running" and exits 0.
 */

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs"
import { IS_WIN, SOCKET_PATH, PID_PATH, LOCK_PATH, WS_PORT } from "../../shared/platform"
import { readLockFile, type LockFileData } from "../../daemon/lifecycle"

type KillResult = {
  success: boolean
  message: string
  pid?: number
  cleaned?: string[]
}

async function killDaemonProcess(pid: number): Promise<boolean> {
  try {
    process.kill(pid, "SIGTERM")
    // Give it a moment to shut down gracefully
    await new Promise(r => setTimeout(r, 500))
    // Verify it's gone via kill(pid, 0)
    try {
      process.kill(pid, 0)
      // Still alive; force kill
      process.kill(pid, "SIGKILL")
      await new Promise(r => setTimeout(r, 200))
    } catch {
      // Already dead, good
    }
    return true
  } catch {
    return false
  }
}

function readPidFromFile(pidPath: string): number | null {
  try {
    const content = readFileSync(pidPath, "utf-8").trim()
    const firstLine = content.split("\n")[0]
    const pid = parseInt(firstLine, 10)
    return Number.isFinite(pid) && pid > 0 ? pid : null
  } catch {
    return null
  }
}

function findDaemonPidFromPort(): number | null {
  try {
    // Try to connect to the WS port to see if something is listening
    // If the daemon is not responding, kill(pid, 0) on the lock file pid will fail
    // and we can clean up stale artifacts.
    return null // Can't directly query port ownership from JS; rely on PID file
  } catch {
    return null
  }
}

async function doDaemonKill(): Promise<KillResult> {
  const cleaned: string[] = []
  let daemonPid: number | null = null

  // Try to read the PID from the lock file first (has more metadata)
  const lockData = readLockFile(LOCK_PATH)
  if (lockData) {
    daemonPid = lockData.pid
    // Check if process is still alive
    try {
      process.kill(daemonPid, 0)
      // Process exists, will try to kill it
    } catch {
      // Process is dead; treat as stale
      daemonPid = null
    }
  }

  // Fallback: read from PID file
  if (!daemonPid && existsSync(PID_PATH)) {
    daemonPid = readPidFromFile(PID_PATH)
    if (daemonPid) {
      try {
        process.kill(daemonPid, 0)
      } catch {
        daemonPid = null
      }
    }
  }

  // No daemon found
  if (!daemonPid) {
    // Clean up stale artifacts anyway
    if (existsSync(PID_PATH)) {
      try {
        unlinkSync(PID_PATH)
        cleaned.push(PID_PATH)
      } catch {}
    }
    if (existsSync(LOCK_PATH)) {
      try {
        unlinkSync(LOCK_PATH)
        cleaned.push(LOCK_PATH)
      } catch {}
    }
    if (!IS_WIN && existsSync(SOCKET_PATH)) {
      try {
        unlinkSync(SOCKET_PATH)
        cleaned.push(SOCKET_PATH)
      } catch {}
    }

    const msg = cleaned.length > 0
      ? `no daemon running, cleaned ${cleaned.length} stale artifact(s)`
      : "no daemon running"
    return { success: true, message: msg, cleaned }
  }

  // Kill the daemon
  const killed = await killDaemonProcess(daemonPid)

  // Clean up files
  if (existsSync(PID_PATH)) {
    try {
      unlinkSync(PID_PATH)
      cleaned.push(PID_PATH)
    } catch {}
  }
  if (existsSync(LOCK_PATH)) {
    try {
      unlinkSync(LOCK_PATH)
      cleaned.push(LOCK_PATH)
    } catch {}
  }
  if (!IS_WIN && existsSync(SOCKET_PATH)) {
    try {
      unlinkSync(SOCKET_PATH)
      cleaned.push(SOCKET_PATH)
    } catch {}
  }

  if (!killed) {
    return {
      success: false,
      message: `failed to kill daemon (pid ${daemonPid}); stale artifacts may remain`,
      pid: daemonPid,
      cleaned,
    }
  }

  return {
    success: true,
    message: `killed daemon (pid ${daemonPid}), cleaned ${cleaned.length} artifact(s)`,
    pid: daemonPid,
    cleaned,
  }
}

export async function runDaemonCommand(filtered: string[], jsonMode: boolean): Promise<null> {
  // Skip global flags when finding the subcommand
  let subcommand: string | undefined
  for (let i = 1; i < filtered.length; i++) {
    const arg = filtered[i]
    // Skip known global flags and their values
    if (arg === "--json" || arg === "--context" || arg === "--tab" || arg === "--group" || arg === "--frame" || arg === "--no-skills-hint") {
      if (arg === "--context" || arg === "--tab" || arg === "--group" || arg === "--frame") i++ // these take a value
      continue
    }
    if (arg.startsWith("--")) continue // skip unknown flags
    subcommand = arg
    break
  }

  if (!subcommand || subcommand === "kill" || subcommand === "teardown") {
    const result = await doDaemonKill()

    if (jsonMode) {
      console.log(JSON.stringify(result))
    } else {
      console.log(result.message)
    }

    if (!result.success) {
      process.exit(1)
    }
  } else if (subcommand === "--help" || subcommand === "-h") {
    console.log(
      "interceptor daemon — daemon lifecycle management\n" +
      "\n" +
      "  interceptor daemon              Gracefully shut down the daemon and clean up runtime files\n" +
      "  interceptor daemon kill         Same as above (explicit subcommand)\n" +
      "  interceptor daemon --help       Print this help\n" +
      "\n" +
      "Behavior:\n" +
      "  - Sends SIGTERM to the daemon process, waits for graceful shutdown\n" +
      "  - Falls back to SIGKILL if the daemon doesn't respond to SIGTERM\n" +
      "  - Removes PID file, lock file, and control socket\n" +
      "  - Idempotent: running with no daemon prints 'no daemon running' and exits 0\n" +
      "  - Handles stale lock files: removes orphaned artifacts if the process is dead\n" +
      "\n" +
      "Flags:\n" +
      "  --json        Output structured result as JSON\n"
    )
  } else {
    console.error(`error: unknown daemon subcommand '${subcommand}'. Run 'interceptor daemon --help' for usage.`)
    process.exit(1)
  }

  return null
}
