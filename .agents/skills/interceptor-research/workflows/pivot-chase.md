# PivotChase

The move that separates investigation from browsing. **Every fact you collect is
a potential new search seed.** A simple query leads to a forgotten PDF, which
exposes an author name, which connects to a username reused elsewhere. Follow each
promising thread 2–3 hops before declaring it dry. A finding you didn't pivot on
is a finding you didn't investigate.

## What to pivot on (extract from every artifact)

| Seed | Next search |
|---|---|
| A **name** (author, founder, maintainer) | their other work, talks, profiles, filings |
| A **filename / title** | who else cites it; the doc it came from |
| A **date** | what else happened in that window (`tbm=nws` + date range) |
| A **handle / username / email** | the same handle on other platforms (the reuse pivot) |
| A **citation / reference** | the cited work forward + backward (citation graph) |
| A **domain / org** | their repos, job posts, pricing, changelog, advisories |
| **Metadata** (PDF author field, WHOIS, DNS, EXIF) | the identity/infra behind the artifact |

## The loop

1. Read a source; extract every identifying detail (the table above).
2. Turn the most promising 1–2 into the next query. Be specific — exact-match
   `"quotes"`, `OR` for name variants, `site:` to pin a domain.
3. Open the result; if it's a real lead, add it to the ledger and pivot again
   (up to 2–3 hops from the original).
4. If a branch looks dead, ask the missing-persons question before stopping:
   *"what resource have I not tried, and what detail have I not extracted?"*
   A dead end is a signal to **change record system**, not to quit.

## Worked example (academic)

```bash
interceptor open "https://arxiv.org/abs/<id>" --text-only          # 1. read abstract
# pivot on the citation graph linked from the abstract page:
interceptor open "https://www.connectedpapers.com/search?q=<title>" --text-only
# pivot on the author:
interceptor open "https://www.google.com/search?q=\"<author>\" <topic>" --text-only
```

## Worked example (OSINT / people)

```bash
interceptor open "https://www.google.com/search?q=\"<full name>\" <org> interview" --text-only
# drill the event page to the actual recording / primary artifact, then:
interceptor open "https://www.google.com/search?q=\"<handle>\" site:github.com OR site:reddit.com" --text-only
```

## Discipline

- **Know when to stop.** Pivot until a branch goes dry (no new domains for two
  rounds — `workflows/saturation-check.md`), then move to the next sub-question.
- **Guard confirmation bias.** Don't only chase threads that confirm your thesis;
  pivot toward the disconfirming hit too (`references/verification.md`, ACH).
- **Ethics.** OSINT relentlessness is a method bounded by consent and law. Stay
  on public sources; do not pursue private individuals without legitimate cause.
