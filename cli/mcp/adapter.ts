/**
 * cli/mcp/adapter.ts — the subprocess seam.
 *
 * The MCP server re-implements no verb: every tool call shells out to the same
 * `interceptor` binary the server itself runs as. That reuses arg parsing,
 * compound fan-out, group injection, daemon auto-spawn, upload chunking, and
 * result formatting (cli/index.ts) for free. Each call is its own process → its
 * own one-shot socket connection → concurrency + group isolation inherited.
 */

/**
 * How to re-invoke the CLI. When compiled (`bun build --compile`), argv[1] is
 * absent and process.execPath IS the interceptor binary → run it directly. In
 * dev (`bun run cli/index.ts mcp serve`), execPath is bun and argv[1] is the
 * script → run `bun <script> …`.
 */
function selfPrefix(): string[] {
  const argv1 = process.argv[1]
  if (argv1 && (argv1.endsWith(".ts") || argv1.endsWith(".js"))) {
    return [process.execPath, argv1]
  }
  return [process.execPath]
}

export type RunResult = { stdout: string; stderr: string; code: number }

/** Run `interceptor <args>` and capture stdout/stderr/exit code. Never throws. */
export async function runInterceptor(args: string[], opts: { timeoutMs?: number } = {}): Promise<RunResult> {
  const cmd = [...selfPrefix(), ...args]
  let proc: ReturnType<typeof Bun.spawn>
  try {
    proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe", stdin: "ignore" })
  } catch (err) {
    return { stdout: "", stderr: `failed to spawn interceptor: ${(err as Error).message}`, code: 127 }
  }

  const timeoutMs = opts.timeoutMs
  let timer: ReturnType<typeof setTimeout> | undefined
  let timedOut = false
  // Kill must not wait on the pipes. Bun's stdout read can stay open after
  // SIGKILL, which would hang the tool call past the timeout.
  const killed = new Promise<RunResult>((resolve) => {
    if (!timeoutMs || timeoutMs <= 0) return
    timer = setTimeout(() => {
      timedOut = true
      // SIGTERM, not SIGKILL: the conformance harness re-invokes through bun,
      // which must be able to forward the signal to the CLI child. A direct
      // interceptor binary dies on SIGTERM the same way.
      try { proc.kill("SIGTERM") } catch { try { proc.kill() } catch {} }
      const killedResult: RunResult = {
        stdout: "",
        stderr: `\n[interceptor-mcp] killed after ${timeoutMs}ms`,
        code: 124,
      }
      // Wait out the kill so the caller can observe the process is gone, but
      // never block on the pipes — that read is what used to hang past the timeout.
      const giveUp = setTimeout(() => resolve(killedResult), 500)
      proc.exited.then(() => { clearTimeout(giveUp); resolve(killedResult) }, () => resolve(killedResult))
    }, timeoutMs)
  })
  const finished = (async (): Promise<RunResult> => {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout as ReadableStream).text(),
      new Response(proc.stderr as ReadableStream).text(),
    ])
    const code = await proc.exited
    if (timer) clearTimeout(timer)
    if (timedOut) {
      return { stdout, stderr: stderr + `\n[interceptor-mcp] killed after ${timeoutMs}ms`, code: 124 }
    }
    return { stdout, stderr, code }
  })()
  try {
    return await Promise.race([finished, killed])
  } catch (err) {
    if (timer) clearTimeout(timer)
    return { stdout: "", stderr: `interceptor run error: ${(err as Error).message}`, code: 1 }
  }
}

/**
 * Warm the daemon at session start. `interceptor contexts` uses the Unix-socket
 * path (not in NO_DAEMON), so it triggers ensureDaemon() — guaranteeing the
 * WS-only `screenshot`/`save` verbs (which skip auto-spawn) find a live daemon.
 * Best-effort: a missing browser is fine, we only need the daemon up.
 */
export async function warmDaemon(): Promise<void> {
  try { await runInterceptor(["contexts"], { timeoutMs: 20_000 }) } catch {}
}

/** Inject session-scoped global flags the model shouldn't have to remember. */
export function withGlobalFlags(
  args: string[],
  opts: { group?: string; context?: string; tab?: number; device?: string; session?: string },
): string[] {
  const out = [...args]
  const has = (f: string) => out.includes(f)
  if (opts.group && !has("--group")) out.push("--group", opts.group)
  if (opts.context && !has("--context")) out.push("--context", opts.context)
  if (opts.tab !== undefined && !has("--tab")) out.push("--tab", String(opts.tab))
  if (opts.device && !has("--on") && !has("--context")) out.push("--on", opts.device)
  if (opts.session && !has("--session")) out.push("--session", opts.session)
  return out
}
