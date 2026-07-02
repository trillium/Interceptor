/**
 * cli/transport.ts — sendCommand (Unix socket / TCP) and sendCommandWs (WebSocket)
 */

import { IPC_PORT, IS_WIN, SOCKET_PATH, WS_PORT } from "../shared/platform"

export const INTERCEPTOR_TIMEOUT_MS = parseInt(process.env.INTERCEPTOR_TIMEOUT || "15000")

// Speech permission prompts are async and user-bounded; 15s is too short
// for first-time `listen start` / `vad start`. 60s covers the documented
// user-prompt UX while preserving the normal timeout for other verbs.
//
// Render/vision capture (screenshot, canvas read/ocr/diff, capture frame) can
// exceed 15s on a heavy chart/image page or when the browser is under load —
// which previously made an agent give up on reading a number trapped in a
// chart and fall back to a weaker secondary source. 45s lets the vision rung
// of the deep-research escalation chain actually complete.
const ACTION_TIMEOUT_OVERRIDES_MS: Record<string, number> = {
  macos_listen: 60_000,
  macos_vad: 60_000,
  // monitor start/stop can do non-trivial setup/teardown (AX
  // attach across many apps under --all-apps, frame/video/speech engines,
  // source snapshot). Even though the bridge now acks early, give the
  // RPC an elevated deadline as a safety margin so a momentarily busy main
  // run loop never trips the old 15s timeout that left a split-brain envelope.
  macos_monitor: 60_000,
  // iOS XCUITest AX ops (element-tree snapshot, app activate/launch, typing) are
  // slow — the first snapshot initializes the on-device accessibility bridge and
  // waits for app quiescence. Give them an elevated deadline.
  ios_tree: 60_000,
  ios_find: 60_000,
  ios_app: 60_000,
  ios_type: 60_000,
  ios_screenshot: 60_000,
  ios_setup: 600_000,
  ios_refresh: 600_000,
  ios_enable: 120_000,
  ios_install: 240_000,
  screenshot: 45_000,
  binary_sink_save: 600_000,
  screenshot_background: 45_000,
  canvas_read: 45_000,
  canvas_ocr: 60_000,
  canvas_diff: 45_000,
  capture_frame: 45_000,
  // OCR: native capture + Tesseract. First call also lazy-loads the WASM core +
  // language data, so allow generous headroom.
  ocr: 60_000,
}

function pickTimeoutForAction(actionType: string): number {
  return ACTION_TIMEOUT_OVERRIDES_MS[actionType] ?? INTERCEPTOR_TIMEOUT_MS
}

// Branch the timeout hint on `macos_*` so bridge commands don't get a
// Chrome/Brave-extension troubleshooting hint.
function timeoutMessage(actionType: string, ms: number): string {
  const seconds = Math.round(ms / 1000)
  if (actionType.startsWith("macos_")) {
    return `timeout: no response for '${actionType}' after ${seconds}s. The macOS bridge may be waiting on a TCC permission prompt (Microphone / Speech Recognition for listen/vad, Screen Recording for screenshot/capture/vision). Check System Settings → Privacy & Security.`
  }
  if (actionType.startsWith("ios_")) {
    return `timeout: no response for '${actionType}' after ${seconds}s. The InterceptorRunner may be busy with a slow XCUITest snapshot or a non-quiescing app; confirm the device is unlocked and 'interceptor ios status' shows it connected.`
  }
  return `timeout: no response for '${actionType}' after ${seconds}s. Ensure Chrome/Brave is open with the Interceptor extension loaded.`
}

export type Action = { type: string; [key: string]: unknown }
export type DaemonResult = { success: boolean; error?: string; data?: unknown; tabId?: number }
export type DaemonResponse = {
  id: string
  result: DaemonResult
}

// the per-invocation group scope (--group / $INTERCEPTOR_GROUP), set once
// by cli/index.ts and injected into every outgoing action here — the single choke
// point every command path (simple, compound, override, tail loops) funnels
// through. The group rides INSIDE the action payload because the daemon relays
// `{id, action, tabId}` verbatim to the extension.
let globalGroup: string | undefined
let globalGroupColor: string | undefined

export function setGlobalGroup(group?: string, groupColor?: string): void {
  globalGroup = group
  globalGroupColor = groupColor
}

function withGroup(action: Action): Action {
  if (!globalGroup || action.group !== undefined) return action
  const scoped: Action = { ...action, group: globalGroup }
  if (globalGroupColor && scoped.groupColor === undefined) scoped.groupColor = globalGroupColor
  return scoped
}

export function sendCommand(rawAction: Action, tabId?: number, contextId?: string): Promise<DaemonResponse> {
  const action = withGroup(rawAction)
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID()
    const shortId = id.slice(0, 8)
    process.stderr.write(`[${shortId}] → ${action.type}\n`)
    let buffer = Buffer.alloc(0)
    let resolved = false
    let socketRef: Bun.Socket<undefined> | null = null

    const timeoutMs = pickTimeoutForAction(action.type)
    const timer = setTimeout(() => {
      if (!resolved) {
        resolved = true
        if (socketRef) try { socketRef.end() } catch {}
        reject(new Error(timeoutMessage(action.type, timeoutMs)))
      }
    }, timeoutMs)

    const socketHandlers: Bun.SocketHandler<undefined> = {
      open(socket: Bun.Socket<undefined>) {
        socketRef = socket
        const payload = JSON.stringify({ id, action, ...(tabId !== undefined && { tabId }), ...(contextId !== undefined && { contextId }) })
        const encoded = Buffer.from(payload, "utf-8")
        const header = Buffer.alloc(4)
        header.writeUInt32LE(encoded.byteLength, 0)
        socket.write(Buffer.concat([header, encoded]))
      },
      data(socket: Bun.Socket<undefined>, raw: Buffer<ArrayBufferLike>) {
        buffer = Buffer.concat([buffer, Buffer.from(raw)])
        if (buffer.length >= 4) {
          const msgLen = buffer.readUInt32LE(0)
          if (msgLen > 0 && msgLen <= 1024 * 1024 && buffer.length >= 4 + msgLen) {
            const json = buffer.subarray(4, 4 + msgLen).toString("utf-8")
            clearTimeout(timer)
            try {
              resolved = true
              resolve(JSON.parse(json) as DaemonResponse)
            } catch {
              resolved = true
              reject(new Error("invalid response from daemon"))
            }
            socket.end()
          }
        }
      },
      close(_socket: Bun.Socket<undefined>) {
        clearTimeout(timer)
        if (!resolved) {
          reject(new Error("connection closed before response"))
        }
      },
      connectError(_socket: Bun.Socket<undefined>, _err: Error) {
        clearTimeout(timer)
        reject(new Error("daemon not running. Open Chrome with the Interceptor extension loaded."))
      },
      error(_socket: Bun.Socket<undefined>, err: Error) {
        clearTimeout(timer)
        reject(err)
      }
    }

    const connectPromise = IS_WIN
      ? Bun.connect({ hostname: "127.0.0.1", port: IPC_PORT, socket: socketHandlers })
      : Bun.connect({ unix: SOCKET_PATH, socket: socketHandlers })

    void connectPromise.catch(() => {})
  })
}

export function sendCommandWs(rawAction: Action, tabId?: number, contextId?: string): Promise<DaemonResponse> {
  const action = withGroup(rawAction)
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID()
    const shortId = id.slice(0, 8)
    process.stderr.write(`[${shortId}] →ws ${action.type}\n`)

    const timeoutMs = pickTimeoutForAction(action.type)
    const timer = setTimeout(() => {
      reject(new Error(`timeout: no response for '${action.type}' after ${timeoutMs / 1000}s via WebSocket.`))
    }, timeoutMs)

    const ws = new WebSocket(`ws://localhost:${WS_PORT}`)
    ws.onopen = () => {
      ws.send(JSON.stringify({ id, action, ...(tabId !== undefined && { tabId }), ...(contextId !== undefined && { contextId }) }))
    }
    ws.onmessage = (event) => {
      clearTimeout(timer)
      try {
        resolve(JSON.parse(typeof event.data === "string" ? event.data : "") as DaemonResponse)
      } catch {
        reject(new Error("invalid response from daemon via WebSocket"))
      }
      ws.close()
    }
    ws.onerror = () => {
      clearTimeout(timer)
      reject(new Error("WebSocket connection failed to daemon"))
    }
    ws.onclose = () => {
      clearTimeout(timer)
    }
  })
}
