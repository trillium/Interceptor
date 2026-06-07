# The Deep-Research Operating Loop

Reference for the method behind `workflows/deep-research-sweep.md`. Run it as a
loop, not a line — re-enter PLAN whenever a pivot opens a new branch.

```
PLAN → COLLECT → FILTER → ESCALATE → PIVOT → DEPTH-CHECK → VERIFY → WRITE
  ^_________________________ (pivot opens a new branch) ________________|
```

## Why the planner/executor/publisher split matters

Separate the roles even when one agent plays all three:

- **Planner** generates the specific research questions that collectively form an
  objective view of the task.
- **Executor** gathers evidence per question (open, escalate, save).
- **Publisher** aggregates — and only the publisher writes prose.

Keeping planning and execution disentangled gives cleaner coverage and stops the
model from answering from memory after two pages.

## The cardinal rule: separate collection from synthesis

> Collect everything to disk **first**, attribute every claim to a stored artifact
> **second**, and write the report **last**.

This is the highest-leverage change found across both the academic literature and
working practitioners. Mixing collection and synthesis produces *grounded-sounding
hallucination* — confident prose ungrounded in what was actually found. The ledger
(`workflows/build-source-ledger.md`) is how you enforce it.

## The anatomy of a deep-research trajectory

```
search → tool use → evidence inspection → answer synthesis
```

The whole game is maximizing real exploration while killing **harmful spans**
(unsupported or conflicting claims) before they reach the report. The three
documented failure modes this loop fixes:

1. **Silent skipping** — "get the page content" fails on half the web (JS, lazy
   load, SPA shells). Fixed by ESCALATE (`workflows/escalate-page.md`).
2. **Fixed-workflow shallowness** — canned pipelines stumble on unfamiliar tasks.
   Fixed by adaptive PLAN + PIVOT.
3. **Plausible hallucination** — narrative woven without grounding. Fixed by
   collect-first + VERIFY (`workflows/verify-and-attribute.md`).

## Decompose before you search

- Write 5–10 sub-questions; each earns ≥1 source.
- Pre-commit the source *type* per question: primary doc? practitioner thread?
  paper? repo? public record? This is what produces breadth — the habit that most
  separates a thorough researcher from a shallow one.

## One-line definition of "investigated"

≥ floor sources, every key claim triangulated ≥3×, every promising lead pivoted
2–3 hops, every page escalated rather than skipped, and the branch run to
saturation (2 dry rounds) — with a coverage critic confirming no obvious gap.
