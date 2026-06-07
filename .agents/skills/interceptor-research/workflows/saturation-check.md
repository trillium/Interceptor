# SaturationCheck

"Am I done?" — answered against the rubric, not a feeling. Agents stop early
because nothing tells them when they're finished. This turns "done" into a
measurable state.

## Run the readout

```bash
interceptor research status <slug>
```

Example output:

```
research: ai-deep-research  (effort: standard)
  sources collected : 12 / 20 floor   (8 to go)
  leads tracked     : 14   (12 saved to sources/)
  domains           : 9 distinct
  needs corroboration: 3 claims tagged [UNVERIFIED]/[LOW]/[CONFLICT]
  saturation        : NOT saturated (last round of 5: 4 new domains)
  triangulation     : every load-bearing claim should be corroborated >=3x
  verdict           : KEEP DIGGING — breadth floor not met (8 more to reach 20)
```

The verdict is **advisory** — Interceptor never blocks a command or forces a
retry. It tells you which rubric condition is still open.

## How to read it

| Verdict | What it means | Do this |
|---|---|---|
| KEEP DIGGING — breadth floor not met | Fewer sources than the floor | Open more primary sources for the thin sub-questions |
| KEEP DIGGING — branch not saturated | The last round still surfaced new domains | Run one more fresh-angle round (see below) |
| VERIFY — N claims need corroboration | `[UNVERIFIED]/[LOW]/[CONFLICT]` tags remain | Triangulate those claims, then re-tag |
| READY | Floor met, saturated, claims attributed | Write the report (`workflows/verify-and-attribute.md` first) |

## Saturation rule

A branch is saturated when **two consecutive rounds from fresh angles / new
domains surface nothing new.** `status` approximates this deterministically: the
floor is met *and* the most recent round of leads introduced no new domain.

## Expanding a branch — be SPECIFIC

Vague "go deeper" measurably fails. Expand with a concrete instruction:

- "Find 10 additional sources from domains **not yet in the ledger**."
- "Cross-check figure X across sources A, B, and C."
- "Find the primary/official version of the three aggregator claims."
- "Seek one source that **disconfirms** the central thesis."

When such an expansion returns only duplicates / no new domains for two rounds,
the branch is saturated — move to the next sub-question or, if all are saturated,
proceed to VERIFY and WRITE.

## Coverage critic (the last gate before writing)

Before synthesis, ask once: *what's missing — a source TYPE not consulted (primary
doc? practitioner? academic? code?), a claim unverified, a counter-view not sought,
a search angle not tried?* What it finds becomes the next collection round.
