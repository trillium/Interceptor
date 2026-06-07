# Interceptor Leverage — why this tool is built for depth

Interceptor's architecture turns the tactics in this skill into an advantage no
CDP-based or HTTP-only scraper has. Three structural reasons depth works better here.

## 1. Real signed-in Chrome beats headless for depth

JS-rendered, lazy-loaded, and SPA content *only exists in a real browser engine*.
Interceptor drives the user's actual signed-in Chrome / Brave — it scrolls to
trigger lazy content and reads the live DOM, no selectors. CDP-based tools miss
rendering that real Chrome catches; Interceptor's zero-CDP, signed-in session is
the right tool for sources that fight scrapers. (And many gates — paywalls,
soft logins, human-verification — are already cleared in a session the user is
signed into.)

## 2. Scrape the data source, not the website

Most JS pages are powered by JSON. Interceptor captures request **and** response
(both directions) and WebSocket / Beacon / BroadcastChannel traffic **without
CDP**, so you can read the API the page already calls instead of parsing brittle
HTML:

```bash
interceptor inspect --net-only
interceptor net log --filter <host> --format json --out <path>
interceptor net headers --filter <host>     # infer infra/processors from request hosts
```

Field-reported impact: ~5 min/page of brittle HTML parsing → ~2 sec/page of clean
JSON. This is the deepest, fastest extraction path.

## 3. The escalation chain maps directly to Interceptor verbs

```
open (load + wait + tree + text)
  → re-read (read --text-only --full / --markdown)
  → DOM/element (find / read e<ref>)
  → the API (inspect --net-only / net log)
  → JS escape hatch (eval --main)
  → VLM (screenshot --save)
```

Wire `workflows/escalate-page.md` straight to these. Nothing is silently skipped
because every rung is a real command.

## Zero CDP is a product invariant, not a limitation

Interceptor deliberately never attaches `chrome.debugger` / CDP. The passive
network surface (`net`, `inspect`, `override`, `headers`) views and modifies
requests **and** responses without a debugger banner and without the fingerprint a
CDP attach leaves. For research that means: no automation tell, the user's real
session and cookies, and pages that behave exactly as they do for a human. Never
reach for CDP as an escape hatch — `eval --main` plus the passive net surface
already covers what you need.

## Background-first

Routine research verbs (`open`, `read`, `inspect`, `net`, `tab new`, `screenshot`)
run in the background and do not steal the user's focus. You can fan out across
many tabs and profiles while the user keeps working. Only the explicit
`--activate` / `tab switch` / `window focus` verbs move focus.

## Token economy

Default to plain text output (not `--json`) for your own context — it's what the
model consumes best. Save pages to the ledger's `sources/` and re-query the
artifact with `rg` instead of re-fetching; this keeps context lean and the run
resumable.
