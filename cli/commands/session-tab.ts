/**
 * cli/commands/session-tab.ts — the "designated" working tab.
 *
 * Agents that open a tab get back a numeric id they'd otherwise have to
 * thread through every later command by hand. `tab designate` pins one tab
 * id here; `tab self` (and `read`'s no-tab fallback) read it back.
 *
 * Mirrors the ~/.interceptor/<subsystem>/state.json convention used by the
 * iOS surface (daemon/ios/state.ts) — a single global file, not per-PID,
 * since the CLI is a fresh process per invocation with no other place to
 * remember "which tab am I working in" across commands.
 *
 * The designation is scoped by `--group` (the same named tab group used to
 * isolate concurrent agents). Each group gets an independent slot inside the
 * one state file, so two agents running under different groups never clobber
 * each other's designated tab. Invocations with no group share a single
 * default slot, preserving the original single-group behavior.
 */

import { mkdirSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

/**
 * Resolve the user's home directory.
 *
 * Bun's os.homedir() resolves from the OS user database and ignores a
 * runtime override of $HOME, unlike Node — so honor $HOME explicitly. This
 * also happens to be the right Unix convention, and it's what makes this
 * module overridable in tests without touching the real machine's state.
 */
function resolveHome(): string {
  return process.env.HOME || homedir()
}

/**
 * Map an optional `--group` label to the key used inside the state file.
 *
 * Group labels always match `[A-Za-z0-9_-]{1,32}` (see GROUP_LABEL_RE), so the
 * empty string can never be a real label — it's a safe sentinel for the
 * default (no-group) slot.
 */
function groupKey(group?: string): string {
  return group ?? ""
}

/** On-disk shape: a map from group key → designated tab id. */
type SessionTabState = { groups?: Record<string, number>; tabId?: number }

/** Return (and ensure) the `~/.interceptor` directory under `home`. */
function sessionTabDir(home: string): string {
  const dir = join(home, ".interceptor")
  try { mkdirSync(dir, { recursive: true }) } catch {}
  return dir
}

/** Path to the designated-tab state file under `home`. */
function sessionTabPath(home: string): string {
  return join(sessionTabDir(home), "session-tab.json")
}

/** Path to the mkdir-based cross-process lock guarding the state file under `home`. */
function sessionTabLockPath(home: string): string {
  return join(sessionTabDir(home), "session-tab.lock")
}

/**
 * Block the current thread for `ms` milliseconds.
 *
 * The lock below guards a synchronous read-modify-write, so waiting for it
 * to free up must itself be synchronous — Atomics.wait on a scratch buffer
 * is the standard way to get a blocking sleep without a native binding.
 */
function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

/**
 * Acquire the cross-process lock for `home`, blocking until it's free.
 *
 * `mkdirSync` on an already-existing directory is atomic and throws EEXIST,
 * which is what makes a lock directory (rather than a lock file) a safe
 * mutex across unrelated CLI processes racing on the same state file. A
 * lock that's held past `staleAfterMs` is assumed to belong to a process
 * that crashed mid-write (this CLI is a fresh process per invocation, so
 * nothing ever "comes back" to release it) and is forcibly reclaimed rather
 * than deadlocking every future `tab designate`/`tab self` in that group.
 *
 * Exported purely so tests can hold the lock directly to prove out mutual
 * exclusion deterministically, without depending on OS scheduling luck to
 * make two real writers overlap.
 */
export function acquireLock(home: string, staleAfterMs = 5000): string {
  const lockPath = sessionTabLockPath(home)
  const deadline = Date.now() + staleAfterMs
  while (true) {
    try {
      mkdirSync(lockPath)
      return lockPath
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err
      if (Date.now() >= deadline) {
        try { rmdirSync(lockPath) } catch {}
        sleepSync(10)
        continue
      }
      sleepSync(10)
    }
  }
}

/** Release a lock acquired by `acquireLock`. Safe to call even if it's already gone. */
export function releaseLock(lockPath: string): void {
  try { rmdirSync(lockPath) } catch {}
}

/**
 * Read the full group→tab map from disk, returning `{}` on any error.
 *
 * Understands the legacy flat `{ tabId }` shape written before designations
 * were group-scoped: it's read back as the default (no-group) slot so an
 * upgrade never silently loses an existing designation.
 */
function readState(home: string): Record<string, number> {
  try {
    const raw = JSON.parse(readFileSync(sessionTabPath(home), "utf-8")) as SessionTabState
    const groups: Record<string, number> = {}
    if (raw.groups && typeof raw.groups === "object") {
      for (const [key, value] of Object.entries(raw.groups)) {
        if (typeof value === "number") groups[key] = value
      }
    }
    // Legacy flat file: fold its tab into the default slot unless a group map
    // already claims it.
    if (typeof raw.tabId === "number" && groups[""] === undefined) groups[""] = raw.tabId
    return groups
  } catch {
    return {}
  }
}

/** Read the tab id designated for `group`, or `undefined` if none is set. */
export function loadDesignatedTab(group?: string, home = resolveHome()): number | undefined {
  const groups = readState(home)
  const tabId = groups[groupKey(group)]
  return typeof tabId === "number" ? tabId : undefined
}

/** Atomically replace the state file's contents with `groups` via temp-file + rename. */
function writeStateAtomic(home: string, groups: Record<string, number>): void {
  const statePath = sessionTabPath(home)
  const tempPath = join(sessionTabDir(home), `.session-tab.tmp.${process.pid}`)
  try {
    writeFileSync(tempPath, JSON.stringify({ groups }, null, 2))
    renameSync(tempPath, statePath)
  } catch (writeErr) {
    try {
      unlinkSync(tempPath)
    } catch {}
    throw writeErr
  }
}

/**
 * Persist `tabId` as the designated working tab for `group`.
 *
 * The read-modify-write against the shared group map is serialized by
 * `acquireLock`/`releaseLock` — without it, two agents designating under
 * different groups at the same moment can each read the map before the
 * other's write lands, and the second write silently drops the first
 * group's entry.
 */
export function saveDesignatedTab(tabId: number, group?: string, home = resolveHome()): void {
  let lockPath: string | undefined
  try {
    lockPath = acquireLock(home)
    const groups = readState(home)
    groups[groupKey(group)] = tabId
    writeStateAtomic(home, groups)
  } catch (err) {
    if (lockPath) releaseLock(lockPath)
    console.error(`error: failed to save designated tab: ${(err as Error).message}`)
    process.exit(1)
  }
  if (lockPath) releaseLock(lockPath)
}

/** Clear the designated tab for `group`, if one is set. Serialized the same way as `saveDesignatedTab`. */
export function clearDesignatedTab(group?: string, home = resolveHome()): void {
  let lockPath: string | undefined
  try {
    lockPath = acquireLock(home)
    const groups = readState(home)
    if (groups[groupKey(group)] === undefined) return
    delete groups[groupKey(group)]
    if (Object.keys(groups).length === 0) {
      try { unlinkSync(sessionTabPath(home)) } catch {}
    } else {
      writeStateAtomic(home, groups)
    }
  } catch {
    // best-effort: clearing a designation is not worth surfacing an error for
  } finally {
    if (lockPath) releaseLock(lockPath)
  }
}
