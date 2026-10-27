/**
 * Conformance-harness entry for the TypeScript reference server (cli/mcp/server.ts).
 *
 * The reference re-invokes itself for every tool call (cli/mcp/adapter.ts selfPrefix():
 * [execPath, argv[1]] + args). This file is that argv[1], so:
 *   - `bun ts_entry.ts __serve`  → run the real MCP server over stdio
 *   - `bun ts_entry.ts <verb>…`  → act as the "interceptor CLI" by exec'ing the
 *                                    stub named by INTERCEPTOR_BIN
 * That lets the unmodified reference run against a fake CLI.
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { buildServer } from "../../cli/mcp/server"

const args = process.argv.slice(2)
if (args[0] === "__serve") {
  await buildServer().connect(new StdioServerTransport())
} else {
  const bin = process.env.INTERCEPTOR_BIN
  if (!bin) { console.error("INTERCEPTOR_BIN not set"); process.exit(127) }
  const proc = Bun.spawn([bin, ...args], { stdout: "inherit", stderr: "inherit", stdin: "ignore" })
  process.exit(await proc.exited)
}
