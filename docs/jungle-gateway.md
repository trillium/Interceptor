# MCPJungle gateway → Interceptor wiring (S5 posture)

Jungle fronts Interceptor on loopback only. ChatGPT connects to jungle
(through the bridge `/jungle/mcp` front door); jungle spawns the
Interceptor binary as a local stdio child. No bearer involved (stdio has
no HTTP surface); no secrets in repo or ChatGPT config.

## Server entry (jungle registry, SQLite `~/.local/share/mcpjungle/mcpjungle.db`)

- `name`: `interceptor` (no `__`, no trailing `_`)
- `transport`: `stdio` (config-file registration is required for
  stdio; CLI flags only cover streamable HTTP)
- `command`:
  `/Users/trilliumsmith/.local/share/mcpjungle/servers/interceptor/interceptor`
- `args`: `["mcp", "serve"]` — stdio, per `cli/mcp/server.ts`
  (six router tools: browser / macos / ios / read / local / raw)
- `env`: `INTERCEPTOR_MCP_ALLOW=""` — safe default, read+mutate only;
  destructive + arbitrary-exec refused until the operator opts in
- `session_mode`: default (`stateless` — fresh process per tool call;
  `INTERCEPTOR_MCP_GROUP` defaults to `mcp-<pid>`, so tab-group
  isolation is automatic per call)
- Registration config (0600): `/tmp/jungle-interceptor.json`
- Registration command: `mcpjungle register -c
  /tmp/jungle-interceptor.json --registry http://127.0.0.1:8338`

Schema source: MCPJungle `docs/guides/register-stdio-servers.mdx`
(`transport`/`command`/`args`/`session_mode`/`env`) — same shape as
the `firstmate_mcp` S5a entry.

## Binary provenance

This branch's `main` predates the MCP control plane
(`cli/mcp/*` does not exist here yet). The runnable server is built
from the v0.23.37 tree (`interceptor 0.23.37`), which carries
`cli/mcp/server.ts`, the MCP SDK in its lockfile, and the
`interceptor mcp serve` stdio entry. Build: `bun install` +
`./scripts/build.sh`; the compiled binary is installed gateway-side at
the `command` path above (outside any checkout, next to the other
jungle state — never on `PATH`, so it can't shadow the user's
`interceptor`).

Build caveat: that tree has a committed conflict marker in
`extension/src/background/transport.ts` (`<<<<<<< HEAD` /
`>>>>>>> 71d05b3`) that fails the extension bundling step. The
correct side is HEAD's one-liner
(`handleControlPlaneMessage(msg, "websocket")`) — the two lower sides
are the pre-refactor inline block the refactor replaced. Resolve (in
the build copy only) and re-run `scripts/build.sh`.

## Tool prefix

Same always-on `__` rule as the other servers: Interceptor tools
arrive as `interceptor__<name>`. Verified zero cross-server suffix
collisions with `beads-bridge__` / `firstmate_mcp__` tools.

## Counts (2026-09-17, verified over fresh Streamable HTTP sessions on `http://127.0.0.1:8338/mcp`)

- Gateway `tools/list`: **61** = **36** `beads-bridge__` + **19**
  `firstmate_mcp__` + **6** `interceptor__`, zero unprefixed
- `mcpjungle list tools --server interceptor`: **6**, all ENABLED
  (`interceptor_browser`, `interceptor_macos`, `interceptor_ios`,
  `interceptor_read`, `interceptor_local`, `interceptor_raw`)
- Live call `interceptor__interceptor_local` (`verb: status`) through
  jungle returns real server output (`mode: full`, daemon pid/socket).
- Direct stdio smoke (pre-registration): `initialize` → `interceptor
  0.23.37`, `tools/list` → **6**.

## ChatGPT refresh

Staleness lives in the client session, not the gateway (registry
changes are visible to new sessions with no gateway restart). After
this onboarding, the operator step is: disconnect/reconnect the jungle
connector in ChatGPT, then re-check `tools/list` → **61** tools
(**36** `beads-bridge__`, **19** `firstmate_mcp__`, **6**
`interceptor__`). Spot-call `interceptor__interceptor_local`
(`status`) for a live proof. The S6 front-door gate
(`…/jungle/mcp`, 401 + RFC 9728 challenge unauthenticated) is the
reachability check ahead of the connector.

## Boundaries

- Loopback only (jungle `127.0.0.1:8338`; stdio child is a local
  process, no port at all). No Tailnet/funnel.
- Direct-server fallback: run the gateway-side binary on stdio
  directly (`…/servers/interceptor/interceptor mcp serve`,
  newline-delimited JSON-RPC) — bypasses jungle entirely.
- `interceptor_raw` stays refused under the registered `ALLOW=""`
  posture even if called; enabling it is an operator relaunch
  decision, never a model one.
