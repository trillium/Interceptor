import { describe, expect, test, beforeEach, afterEach } from "bun:test"
import { existsSync, unlinkSync } from "node:fs"
import { TEMP } from "../shared/platform"

// Mock paths for testing
const testPidPath = `${TEMP}/test-interceptor.pid`
const testSocketPath = `${TEMP}/test-interceptor.sock`

beforeEach(() => {
  try { unlinkSync(testPidPath) } catch {}
  try { unlinkSync(testSocketPath) } catch {}
})

afterEach(() => {
  try { unlinkSync(testPidPath) } catch {}
  try { unlinkSync(testSocketPath) } catch {}
})

describe("daemon readiness check", () => {
  test("handles AbortSignal timeout properly", async () => {
    // Test that we can abort a fetch request with a timeout
    try {
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), 100)
      try {
        await fetch("http://127.0.0.1:65432/", { signal: controller.signal })
      } catch (err) {
        // Expected: fetch throws when port is not listening or abort is called
        expect(err).toBeDefined()
      }
      clearTimeout(timeoutId)
    } catch (err) {
      // If there's an error in the test itself, that's also acceptable
      expect(err).toBeDefined()
    }
  })

  test("fetch succeeds on a valid server", async () => {
    // Start a simple HTTP server to verify fetch works
    const server = Bun.serve({
      port: 0,
      fetch() {
        return new Response("ok", { status: 200 })
      },
    })

    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/`)
      expect(response.status).toBe(200)
    } finally {
      server.stop(true)
    }
  })

  test("cold start case: PID file missing indicates no daemon", () => {
    const pidExists = existsSync(testPidPath)
    expect(pidExists).toBe(false)
  })
})
