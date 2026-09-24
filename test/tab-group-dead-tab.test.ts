import { describe, expect, test, beforeEach } from "bun:test"
import {
  groupTitleFor,
  isTabInAnyManagedGroup,
  isTabInNamedGroup,
} from "../extension/src/background/tab-group"

// robots-m0ay: a designated/stored tab that has since been closed makes
// chrome.tabs.get reject. Membership checks must report "not a member"
// (so the caller fails fast with a named error) — never throw, which used
// to escape handleDaemonMessage's try/catch and leave the CLI hanging with
// no reply until its 15s timeout.

function stubChrome(tabsGet: (id: number) => Promise<unknown>) {
  ;(globalThis as Record<string, unknown>).chrome = {
    tabGroups: { query: async () => [] },
    tabs: { get: tabsGet },
    storage: { session: { get: async () => ({}), set: async () => {}, remove: async () => {} } },
  }
}

beforeEach(() => {
  stubChrome(async () => {
    throw new Error("No tab with id: 999")
  })
})

describe("tab-group dead-tab membership", () => {
  test("isTabInAnyManagedGroup returns false (not throws) for a gone tab", async () => {
    await expect(isTabInAnyManagedGroup(999)).resolves.toBe(false)
  })

  test("isTabInNamedGroup returns false (not throws) for a gone tab", async () => {
    const chrome = (globalThis as Record<string, any>).chrome
    chrome.tabGroups.query = async () => [{ title: groupTitleFor("dead-tab-probe"), id: 42 }]
    await expect(isTabInNamedGroup(999, "dead-tab-probe")).resolves.toBe(false)
  })

  test("a live tab in no group is still simply not a member", async () => {
    stubChrome(async (id: number) => ({ id, groupId: -1 }))
    await expect(isTabInAnyManagedGroup(1001)).resolves.toBe(false)
  })
})
