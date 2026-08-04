import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { writeFileSync, unlinkSync, existsSync } from "node:fs"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"

describe("daemon command integration", () => {
  let tmpDir: string
  let pidPath: string
  let lockPath: string
  let socketPath: string

  beforeEach(() => {
    tmpDir = mkdtempSync("interceptor-test-")
    pidPath = `${tmpDir}/interceptor.pid`
    lockPath = `${tmpDir}/interceptor.lock`
    socketPath = `${tmpDir}/interceptor.sock`
  })

  afterEach(() => {
    try { rmSync(tmpDir, { recursive: true }) } catch {}
  })

  test("daemon command exits successfully with no daemon running", async () => {
    const env = { ...process.env, INTERCEPTOR_PID_PATH: pidPath, INTERCEPTOR_LOCK_PATH: lockPath, INTERCEPTOR_SOCKET_PATH: socketPath }
    const proc = Bun.spawn(["bun", "cli", "daemon", "--no-skills-hint"], { env, cwd: process.cwd(), stdout: "pipe", stderr: "pipe" })
    const exitCode = await proc.exited

    expect(exitCode).toBe(0)
  })

  test("daemon command cleans up stale lock file", async () => {
    writeFileSync(pidPath, "99999\n")
    writeFileSync(lockPath, JSON.stringify({ pid: 99999 }))
    writeFileSync(socketPath, "")

    const env = { ...process.env, INTERCEPTOR_PID_PATH: pidPath, INTERCEPTOR_LOCK_PATH: lockPath, INTERCEPTOR_SOCKET_PATH: socketPath }
    const proc = Bun.spawn(["bun", "cli", "daemon", "--no-skills-hint"], { env, cwd: process.cwd(), stdout: "pipe", stderr: "pipe" })
    const exitCode = await proc.exited

    expect(exitCode).toBe(0)
    expect(existsSync(pidPath)).toBe(false)
    expect(existsSync(lockPath)).toBe(false)
    expect(existsSync(socketPath)).toBe(false)
  })

  test("daemon command outputs JSON when requested", async () => {
    const env = { ...process.env, INTERCEPTOR_PID_PATH: pidPath, INTERCEPTOR_LOCK_PATH: lockPath, INTERCEPTOR_SOCKET_PATH: socketPath }
    const proc = Bun.spawn(["bun", "cli", "daemon", "--json", "--no-skills-hint"], { env, cwd: process.cwd(), stdout: "pipe", stderr: "pipe" })
    const exitCode = await proc.exited
    const output = await new Response(proc.stdout).text()

    expect(exitCode).toBe(0)
    const result = JSON.parse(output)
    expect(result.success).toBe(true)
    expect(result.message).toContain("no daemon running")
  })

  test("daemon command --help works", async () => {
    const env = { ...process.env, INTERCEPTOR_PID_PATH: pidPath, INTERCEPTOR_LOCK_PATH: lockPath, INTERCEPTOR_SOCKET_PATH: socketPath }
    const proc = Bun.spawn(["bun", "cli", "daemon", "--help", "--no-skills-hint"], { env, cwd: process.cwd(), stdout: "pipe", stderr: "pipe" })
    const exitCode = await proc.exited
    const output = await new Response(proc.stdout).text()

    expect(exitCode).toBe(0)
    expect(output).toContain("daemon")
  })
})
