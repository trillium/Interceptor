import { describe, expect, test } from "bun:test"
import {
  daemonBinaryCandidates,
  findDaemonBinary,
  formatMissingDaemonBinaryError,
  MACOS_PKG_DAEMON_PATH,
} from "../cli/daemon-spawn"

describe("daemon spawn binary resolution", () => {
  test("finds the pkg-installed daemon for installed macOS CLI cold-starts", () => {
    const found = findDaemonBinary({
      platform: "darwin",
      execPath: "/usr/local/bin/interceptor",
      cwd: "/tmp/interceptor-user-home",
      exists: (path) => path === MACOS_PKG_DAEMON_PATH,
    })

    expect(found).toBe(MACOS_PKG_DAEMON_PATH)
  })

  test("prefers repository daemon before macOS package fallback", () => {
    const repoRoot = "/workspace/interceptor"
    const repoDaemon = `${repoRoot}/daemon/interceptor-daemon`
    const found = findDaemonBinary({
      platform: "darwin",
      execPath: `${repoRoot}/dist/interceptor`,
      cwd: repoRoot,
      exists: (path) => path === repoDaemon || path === MACOS_PKG_DAEMON_PATH,
    })

    expect(found).toBe(repoDaemon)
  })

  test("keeps Windows candidates on exe daemon names without macOS fallback", () => {
    const candidates = daemonBinaryCandidates({
      platform: "win32",
      execPath: "/Program Files/Interceptor/interceptor.exe",
      cwd: "/work/interceptor",
    })

    expect(candidates.some((path) => path.endsWith("interceptor-daemon.exe"))).toBe(true)
    expect(candidates).not.toContain(MACOS_PKG_DAEMON_PATH)
  })

  test("missing-daemon message names package path without launchctl remediation", () => {
    const message = formatMissingDaemonBinaryError([
      "/usr/local/bin/interceptor-daemon",
      MACOS_PKG_DAEMON_PATH,
    ], "darwin")

    expect(message).toContain(MACOS_PKG_DAEMON_PATH)
    expect(message).toContain("browser daemon binary")
    expect(message).not.toContain("launchctl")
    expect(message).not.toContain("LaunchAgent")
  })

  test("missing-daemon message keeps macOS package guidance out of Windows output", () => {
    const message = formatMissingDaemonBinaryError([
      "C:\\Program Files\\Interceptor\\interceptor-daemon.exe",
    ], "win32")

    expect(message).not.toContain(MACOS_PKG_DAEMON_PATH)
    expect(message).not.toContain("browser daemon binary")
  })
})
