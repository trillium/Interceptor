# BuildSourceLedger

You are standing up the on-disk evidence base so you collect *before* you
synthesize. This is the single change practitioners found scored highest in
head-to-head deep-research benchmarks: it forces a real evidence base and makes
the run resumable if the session dies.

## Create it

```bash
interceptor research init <slug> --effort standard
```

Scaffolds `./.interceptor-research/<slug>/`:

```
links.json     # leads: {url, domain, status, note, addedAt} + effort + floor
insights.md    # running insight log; tag claims [HIGH]/[MED]/[LOW]/[CONFLICT]
sources/       # one file per opened page: NN-<slug>.md
```

Override the location with `--dir <path>`. The default `.interceptor-research/`
is gitignored so research artifacts never pollute a repo.

## The collection loop (per source)

1. **Open and escalate** until you actually have the content:
   ```bash
   interceptor open "<url>" --text-only --full
   ```
   If thin, walk `workflows/escalate-page.md`. Never skip silently.

2. **Save the page to disk** — this is the artifact every later claim points at:
   ```bash
   interceptor read --text-only --full > .interceptor-research/<slug>/sources/01-<short>.md
   ```
   (Number files in open order so the report can cite `sources/01-…`.)

3. **Record the lead + the insight:**
   ```bash
   interceptor research add "<url>" --note "what this source establishes"
   interceptor research note "[MED] <claim> — per sources/01-<short>.md"
   ```

4. **Do NOT write the report yet.** Collection and synthesis are separate phases.
   Mixing them produces grounded-sounding hallucination.

## Why this works

- **Resumable.** If the session dies, the ledger is the recovery point — nothing
  is lost.
- **Auditable.** Every claim in the final report can name the `sources/NN-…` file
  it came from; anything that can't gets tagged `[UNVERIFIED]`.
- **Measurable.** `interceptor research status <slug>` reads the ledger and tells
  you sources-vs-floor, distinct domains, claims needing corroboration, and the
  saturation verdict — so "done" is a state, not a guess.

## Status readout

```bash
interceptor research status <slug>
```

The verdict is **advisory** — it never blocks a command. It just tells you
whether you've met the breadth floor, whether the branch is saturated, and
whether any claims still need corroboration before you write.
