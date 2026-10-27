/**
 * Conformance probe of the reference classifier (cli/mcp/tiers.ts).
 * Reads a JSON array of ops from stdin and writes a JSON array of results.
 * No logic of its own — the suite compares this to the Python port.
 */
import { classify, gate, parseAllow, type Surface } from "../../cli/mcp/tiers"

type Req = {
  op: "classify" | "gate" | "parseAllow"
  surface?: string
  verb?: string
  args?: string[]
  allow?: string | null
  confirm?: boolean
  env?: string | null
}

const reqs = JSON.parse(await new Response(Bun.stdin).text()) as Req[]
const out = reqs.map(req => {
  if (req.op === "parseAllow") {
    const a = parseAllow(req.env == null ? undefined : req.env)
    return {
      tiers: [...a.tiers].sort(),
      verbs: [...a.verbs].sort(),
      raw: a.raw,
      all: a.all,
    }
  }
  const c = classify(req.surface as Surface, req.verb || "", req.args || [])
  if (req.op === "classify") return { tier: c.tier, sub: c.sub, surface: c.surface, verb: c.verb }
  const g = gate(c, parseAllow(req.allow == null ? undefined : req.allow), req.confirm === true)
  return { tier: c.tier, sub: c.sub, allowed: g.allowed, needsConfirm: g.needsConfirm, reason: g.reason ?? null }
})
console.log(JSON.stringify(out))
