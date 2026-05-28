export type OutboundTransport = "relay" | "ws" | "native" | "queue"
export type ContextRoutingValidation =
  | { ok: true }
  | { ok: false; error: string }

export function isControlMessage(msg: unknown): boolean {
  const candidate = msg as { type?: unknown }
  return candidate?.type === "ping" || candidate?.type === "pong"
}

export function chooseOutboundTransport(
  msg: unknown,
  state: {
    nativeRelayAvailable: boolean
    extensionWsAvailable: boolean
    stdinAlive: boolean
    standalone: boolean
  }
): OutboundTransport {
  if (isControlMessage(msg)) {
    if (state.nativeRelayAvailable) return "relay"
    if (!state.standalone && state.stdinAlive) return "native"
    return "queue"
  }

  if (state.extensionWsAvailable) return "ws"
  if (state.nativeRelayAvailable) return "relay"
  if (!state.standalone && state.stdinAlive) return "native"
  return "queue"
}

export function validateContextRouting(input: {
  contextId?: string
  connectedContexts: string[]
  nativeRelayAvailable: boolean
}): ContextRoutingValidation {
  const { contextId, connectedContexts, nativeRelayAvailable } = input

  if (contextId) {
    if (connectedContexts.includes(contextId)) return { ok: true }
    const hint = connectedContexts.length > 0
      ? ` (connected: ${connectedContexts.join(", ")})`
      : " (no extensions connected)"
    return { ok: false, error: `context '${contextId}' not found${hint}` }
  }

  if (connectedContexts.length === 1) return { ok: true }
  if (connectedContexts.length === 0 && nativeRelayAvailable) return { ok: true }
  if (connectedContexts.length === 0) return { ok: false, error: "no extensions connected" }

  return {
    ok: false,
    error: `multiple extensions connected, use --context <id> (connected: ${connectedContexts.join(", ")})`,
  }
}
