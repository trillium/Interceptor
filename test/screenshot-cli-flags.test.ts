import { describe, expect, test } from "bun:test"
import { parseScreenshotCommand } from "../cli/commands/screenshot"

describe("screenshot CLI flag parsing", () => {
  test("--target-max-long-edge sets target_max_long_edge as integer", () => {
    const action = parseScreenshotCommand(["screenshot", "--target-max-long-edge", "1568"])
    expect(action).toMatchObject({
      type: "screenshot",
      target_max_long_edge: 1568,
    })
  })

  test("--target-max-long-edge with non-numeric value is ignored (defensive)", () => {
    const action = parseScreenshotCommand(["screenshot", "--target-max-long-edge", "abc"])
    expect(action.target_max_long_edge).toBeUndefined()
  })

  test("--target-max-long-edge with zero is ignored", () => {
    const action = parseScreenshotCommand(["screenshot", "--target-max-long-edge", "0"])
    expect(action.target_max_long_edge).toBeUndefined()
  })

  test("--format webp passes through as a string", () => {
    const action = parseScreenshotCommand(["screenshot", "--format", "webp"])
    expect(action.format).toBe("webp")
  })

  test("--save --format webp combination round-trips both flags", () => {
    const action = parseScreenshotCommand([
      "screenshot",
      "--save",
      "--format",
      "webp",
      "--quality",
      "85",
      "--target-max-long-edge",
      "1568",
    ])
    expect(action).toMatchObject({
      type: "screenshot",
      save: true,
      format: "webp",
      quality: 85,
      target_max_long_edge: 1568,
    })
  })

  test("backwards-compat: existing flag sets parse identically", () => {
    const action = parseScreenshotCommand([
      "screenshot",
      "--full",
      "--format",
      "png",
      "--quality",
      "92",
    ])
    expect(action).toMatchObject({
      type: "screenshot",
      full: true,
      format: "png",
      quality: 92,
    })
    expect(action.target_max_long_edge).toBeUndefined()
  })
})
