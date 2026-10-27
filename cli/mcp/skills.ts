/**
 * cli/mcp/skills.ts — skills tool wiring shared by the MCP server.
 *
 * adopt/unadopt go through the existing gate at mutate minimum (a read
 * classification is lifted; a higher one is kept). unadopt of a path outside
 * the skills root is refused before the CLI is spawned.
 */

import { TIER_RANK, type Tier } from "./tiers"
import { unadoptCandidates, unadoptRefusal } from "../commands/skills"

export const SKILLS_OPS = ["list", "status", "show", "adopt", "unadopt"] as const
export type SkillsOp = (typeof SKILLS_OPS)[number]

export const SKILLS_DESCRIPTION =
  "List, show, and link Interceptor skill packs (list/status/show/adopt), or unadopt a link. " +
  "adopt and unadopt go through the operator gate at mutate minimum. " +
  "unadopt refuses any path outside the skills root and does not reach the CLI."

const GATED = new Set(["adopt", "unadopt"])

export function floorTier(tier: Tier, minimum: Tier): Tier {
  return TIER_RANK[tier] < TIER_RANK[minimum] ? minimum : tier
}

export function skillsSub(args: string[]): string {
  for (const a of args) if (!a.startsWith("-")) return a
  return "list"
}

export function skillsNeedsGate(args: string[]): boolean {
  return GATED.has(skillsSub(args))
}

export function skillsCliArgs(op: string, name: string | undefined, args: string[], path: string | undefined): string[] {
  const out = ["skills", op]
  if (name) out.push(name)
  if (path) out.push("--path", path)
  return out.concat(args)
}

/** Refusal string, or null when the call may proceed to the gate. */
export function refuseUnadopt(name: string | undefined, path: string | undefined, args: string[]): string | null {
  return unadoptRefusal(unadoptCandidates(name, path, args))
}
