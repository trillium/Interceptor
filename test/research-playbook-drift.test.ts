/**
 * test/research-playbook-drift.test.ts
 *
 * DR-15: the CLI playbook (shared/research-playbook.ts) and the skill checklist
 * (.agents/skills/interceptor-research/SKILL.md) derive from a single source.
 * Asserts the skill embeds the exact ONE_SCREEN string. If someone edits the
 * playbook and forgets `bun run scripts/gen-research-playbook.ts`, this fails.
 *
 * Also unit-tests the Layer C discovery-hint predicate (DR-18/19/20).
 */

import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { RESEARCH_PLAYBOOK_ONE_SCREEN } from "../shared/research-playbook"
import { isSearchUrl, shouldEmitResearchHint } from "../cli/commands/research"

const REPO_ROOT = resolve(import.meta.dir, "..")
const SKILL = resolve(REPO_ROOT, ".agents/skills/interceptor-research/SKILL.md")

describe("research playbook drift guard", () => {
  test("SKILL.md embeds the exact one-screen playbook", () => {
    const skill = readFileSync(SKILL, "utf-8")
    expect(skill).toContain(RESEARCH_PLAYBOOK_ONE_SCREEN)
  })

  test("the one-screen playbook still names the rubric floors", () => {
    expect(RESEARCH_PLAYBOOK_ONE_SCREEN).toContain("quick 8 / standard 20 / exhaustive 40")
    expect(RESEARCH_PLAYBOOK_ONE_SCREEN).toContain("saturation")
  })
})

describe("isSearchUrl", () => {
  test("recognizes search/discovery surfaces", () => {
    expect(isSearchUrl("https://www.google.com/search?q=deep+research")).toBe(true)
    expect(isSearchUrl("https://www.google.co.uk/search?q=x")).toBe(true)
    expect(isSearchUrl("https://github.com/search?q=agent&type=repositories")).toBe(true)
    expect(isSearchUrl("https://arxiv.org/search/advanced?terms-0-term=x")).toBe(true)
    expect(isSearchUrl("https://old.reddit.com/r/OSINT/search?q=x")).toBe(true)
    expect(isSearchUrl("https://duckduckgo.com/html/?q=x")).toBe(true)
    expect(isSearchUrl("https://bing.com/search?q=x")).toBe(true)
  })

  test("ignores non-search pages", () => {
    expect(isSearchUrl("https://example.com")).toBe(false)
    expect(isSearchUrl("https://www.google.com/maps")).toBe(false)
    expect(isSearchUrl("https://github.com/assafelovic/gpt-researcher")).toBe(false)
    expect(isSearchUrl("not a url")).toBe(false)
  })
})

describe("shouldEmitResearchHint", () => {
  const url = "https://www.google.com/search?q=x"

  test("emits on a search URL when nothing suppresses it", () => {
    expect(shouldEmitResearchHint(url, { noFlag: false, envSet: false, ledgerActive: false })).toBe(true)
  })

  test("suppressed by --no-research-hint", () => {
    expect(shouldEmitResearchHint(url, { noFlag: true, envSet: false, ledgerActive: false })).toBe(false)
  })

  test("suppressed by env var", () => {
    expect(shouldEmitResearchHint(url, { noFlag: false, envSet: true, ledgerActive: false })).toBe(false)
  })

  test("suppressed when a ledger is already active", () => {
    expect(shouldEmitResearchHint(url, { noFlag: false, envSet: false, ledgerActive: true })).toBe(false)
  })

  test("never emits for a non-search URL", () => {
    expect(shouldEmitResearchHint("https://example.com", { noFlag: false, envSet: false, ledgerActive: false })).toBe(false)
  })
})
