/**
 * test/fixtures/session-tab-lock-holder.ts
 *
 * Fixture invoked by test/session-tab.test.ts as a real child process (via
 * Bun.spawn), not imported in-process — the lock guarding session-tab.json is
 * a cross-process mkdir lock, so proving it actually excludes a concurrent
 * writer requires a genuinely separate OS process holding it.
 *
 * Acquires the lock, holds it for `holdMs`, then releases. The test uses this
 * to deterministically force a real saveDesignatedTab call in the parent
 * process to block until the holder releases, instead of hoping two writers
 * happen to race within the same instant.
 *
 * Writes `readyPath` immediately after acquiring the lock, so the parent
 * test can wait for the lock to actually be held (rather than guessing a
 * fixed startup delay) before racing a writer against it.
 *
 * Usage: bun run session-tab-lock-holder.ts <home> <holdMs> <readyPath>
 */

import { writeFileSync } from "node:fs"
import { acquireLock, releaseLock } from "../../cli/commands/session-tab"

const [, , home, holdMsArg, readyPath] = process.argv
const holdMs = parseInt(holdMsArg, 10)

const lockPath = acquireLock(home)
writeFileSync(readyPath, "ready")
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, holdMs)
releaseLock(lockPath)
