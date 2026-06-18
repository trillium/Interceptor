/**
 * cli/commands/tabs.ts — tabs, tab new/close/switch, window, frames, session
 *
 * Returns null for "session" subcommands (handled locally, no daemon needed).
 */

import { unlinkSync } from "node:fs"
import { writeFileSync } from "node:fs"

type Action = { type: string; [key: string]: unknown }

export async function parseTabsCommand(filtered: string[]): Promise<Action | null> {
  const cmd = filtered[0]

  switch (cmd) {
    case "tabs":
      return { type: "tab_list" }

    case "tab":
      switch (filtered[1]) {
        case "new": {
          // Background-first by default; --activate is the opt-in.
          const action: Action = { type: "tab_create", url: filtered[2] }
          if (filtered.includes("--activate")) action.active = true
          return action
        }
        case "close":
          return filtered[2]
            ? { type: "tab_close", tabId: parseInt(filtered[2]) }
            : { type: "tab_close" }
        case "switch":
          return { type: "tab_switch", tabId: parseInt(filtered[2]) }
        default:
          console.error("error: unknown tab subcommand. Use: new, close, switch")
          process.exit(1)
      }
      break

    case "window":
      switch (filtered[1]) {
        case "new":
          return { type: "window_create", url: filtered[2], incognito: filtered.includes("--incognito") }
        case "close":
          return { type: "window_close", windowId: parseInt(filtered[2]) }
        case "focus":
          return { type: "window_focus", windowId: parseInt(filtered[2]) }
        case "resize": {
          // Back-compat: `window resize <id> <width> <height>` (positional).
          // New: --left/--top/--width/--height/--state flags (all forwarded to
          // chrome.windows.update via the extension's window_resize handler,
          // which already honors them). Enables absolute positioning + tiling.
          const flagNum = (f: string) => {
            const i = filtered.indexOf(f)
            return i >= 0 && filtered[i + 1] !== undefined ? parseInt(filtered[i + 1]) : undefined
          }
          const flagStr = (f: string) => {
            const i = filtered.indexOf(f)
            return i >= 0 ? filtered[i + 1] : undefined
          }
          const posNum = (idx: number) =>
            filtered[idx] && !filtered[idx].startsWith("--") ? parseInt(filtered[idx]) : undefined
          const action: Action = {
            type: "window_resize",
            windowId: filtered[2] ? parseInt(filtered[2]) : undefined
          }
          const width = flagNum("--width") ?? posNum(3)
          const height = flagNum("--height") ?? posNum(4)
          const left = flagNum("--left")
          const top = flagNum("--top")
          const state = flagStr("--state")
          if (width !== undefined && !Number.isNaN(width)) action.width = width
          if (height !== undefined && !Number.isNaN(height)) action.height = height
          if (left !== undefined && !Number.isNaN(left)) action.left = left
          if (top !== undefined && !Number.isNaN(top)) action.top = top
          if (state !== undefined) action.state = state
          return action
        }
        case "list":
        default:
          return { type: "window_list" }
      }

    case "frames":
      return { type: "frames_list" }

    case "session": {
      const sessionPath = "/tmp/interceptor-session.pid"
      if (filtered[1] === "start") {
        writeFileSync(sessionPath, `${process.pid}\n${Date.now()}`)
        console.log(`session started (pid: ${process.pid})`)
        console.log("session mode: batch commands recommended for best performance")
        return null
      }
      if (filtered[1] === "end") {
        try { unlinkSync(sessionPath) } catch {}
        console.log("session ended")
        return null
      }
      console.error("error: usage: interceptor session start|end")
      process.exit(1)
    }

    default:
      console.error(`error: unknown tabs command '${cmd}'`)
      process.exit(1)
  }
}
