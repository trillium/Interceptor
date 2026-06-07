#!/usr/bin/env bun
/**
 * scripts/gen-research-playbook.ts
 *
 * Injects the canonical one-screen playbook from shared/research-playbook.ts
 * into .agents/skills/interceptor-research/SKILL.md between the
 * `<!-- playbook:begin -->` / `<!-- playbook:end -->` markers. Run after editing
 * the playbook text so the skill never drifts from `interceptor research`.
 *
 *   bun run scripts/gen-research-playbook.ts
 *
 * test/research-playbook-drift.test.ts asserts SKILL.md contains the exact
 * RESEARCH_PLAYBOOK_ONE_SCREEN string, so a forgotten run fails CI.
 */

import { readFileSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import { RESEARCH_PLAYBOOK_ONE_SCREEN } from "../shared/research-playbook"

const REPO_ROOT = resolve(import.meta.dir, "..")
const SKILL = resolve(REPO_ROOT, ".agents/skills/interceptor-research/SKILL.md")

const BEGIN = "<!-- playbook:begin -->"
const END = "<!-- playbook:end -->"

const src = readFileSync(SKILL, "utf-8")
const begin = src.indexOf(BEGIN)
const end = src.indexOf(END)
if (begin === -1 || end === -1 || end < begin) {
  console.error(`error: playbook markers not found in ${SKILL}`)
  process.exit(1)
}

const block = `${BEGIN}\n\`\`\`\n${RESEARCH_PLAYBOOK_ONE_SCREEN}\n\`\`\`\n${END}`
const next = src.slice(0, begin) + block + src.slice(end + END.length)

if (next === src) {
  console.log("research playbook already in sync.")
} else {
  writeFileSync(SKILL, next)
  console.log(`injected one-screen playbook into ${SKILL}`)
}
