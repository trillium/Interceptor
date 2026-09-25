import { describe, expect, test } from "bun:test"
import pkg from "../package.json"
import manifest from "../extension/manifest.json"
import { VERSION } from "../cli/version"

describe("version sync", () => {
  test("source CLI version matches package.json#version", () => {
    expect(VERSION).toBe(pkg.version)
  })

  test("extension/manifest.json#version matches package.json#version", () => {
    expect(manifest.version).toBe(pkg.version)
  })
})
