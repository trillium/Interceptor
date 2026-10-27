import { describe, expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "..")

describe("MCP classification drift", () => {
  test("a CLI verb the classification does not know fails loudly", () => {
    const proc = spawnSync("python3", ["test/mcp-conformance/drift_check.py"], { cwd: ROOT, encoding: "utf-8" })
    if (proc.status !== 0) {
      throw new Error(proc.stderr || proc.stdout || "drift check failed")
    }
    expect(proc.stdout).toContain("drift check ok")
  })
})
