/**
 * cli/mcp/drift.ts — verbs the MCP classification and menus explicitly know.
 *
 * A CLI verb that is in neither set is unclassified: classify() would default
 * it to mutate. The conformance drift check fails loudly on that gap.
 */

import { classificationKeys } from "./tiers"
import { mcpMenuVerbs } from "./server"

export function knownVerbKeys(): string[] {
  const keys = new Set(classificationKeys())
  for (const [surface, verbs] of Object.entries(mcpMenuVerbs())) {
    for (const verb of verbs) keys.add(`${surface}:${verb}`)
  }
  return [...keys].sort()
}
