# Query Craft — filter like a database, not a search box

The difference between browsing and investigating is treating the search box as a
**query language**. Paste-ready syntax by surface. Operators are necessary but not
sufficient — pair them with iterative reformulation (broad → narrow → specific).

## Google — advanced operators (the "dorking" core)

| Operator | What it does | Example |
|---|---|---|
| `site:` | Scope to a domain | `site:docs.example.com` |
| `intitle:` / `allintitle:` | Match the page title | `intitle:"annual report"` |
| `inurl:` / `allinurl:` | Match the URL path | `inurl:admin` |
| `filetype:` / `ext:` | Restrict to a file type (docs/PDFs leak) | `filetype:pdf "confidential"` |
| `intext:` / `allintext:` | Match body content | `intext:"internal use only"` |
| `before:` / `after:` | Date bounds inline | `after:2025-11-18 before:2026-06-07` |
| `"…"` | Exact phrase | `"deep research agent"` |
| `OR` / `( )` | Boolean grouping | `(login OR admin) site:example.com` |
| `-term` | Exclude | `agent -minecraft` |
| `*` | Wildcard in a phrase | `"best * for OSINT"` |

Date-window URL (more reliable than the UI):
```
https://www.google.com/search?q=YOUR+QUERY&tbs=cdr:1,cd_min:MM/DD/YYYY,cd_max:MM/DD/YYYY&num=30
# relative: &tbs=qdr:d | qdr:w | qdr:m | qdr:y      news: &tbm=nws
```

## arXiv — advanced search with date_range

```
https://arxiv.org/search/advanced?advanced=1
  &terms-0-operator=AND&terms-0-term=deep+research&terms-0-field=title
  &classification-computer_science=y&classification-include_cross_list=include
  &date-filter_by=date_range&date-from_date=2025-11-18&date-to_date=2026-06-07
  &date-date_type=submitted_date&abstracts=show&size=50&order=-announced_date_first
```
- `terms-N-field`: `title` | `abstract` | `author` | `all`. Title-scoping cuts
  noise hard. Check the **published** date, not `lastUpdatedDate`, for new work.
- Then chase the citation graph (Connected Papers, Litmaps, Semantic Scholar).

## GitHub — qualifier search (+ the recency/quality bar)

```
https://github.com/search?q=deep+research+agent+stars:>250+pushed:>2026-05-07&type=repositories&s=stars&o=desc
```
| Qualifier | Meaning |
|---|---|
| `stars:>N` / `stars:A..B` | Adoption proxy |
| `pushed:>YYYY-MM-DD` | Is it alive? |
| `created:>YYYY-MM-DD` | Repo age |
| `language:TypeScript` | Stack filter |
| `topic:llm` / `in:readme` | Topical / where the term appears |

**Verify before you trust:** the search filter is honored, but confirm exact
counts and last-commit dates via the API
(`api.github.com/repos/owner/name` → `stargazers_count`, `pushed_at`) before
recommending a repo. A tactic in a post can be useful even when the repo it links
fails the bar.

## Reddit — practitioner depth

- Use **`old.reddit.com`** for text-friendly, no-JS-wall reads.
- Time-box: `old.reddit.com/r/SUB/top/?t=year` (or `month`/`week`);
  `/search?q=…&restrict_sr=on&sort=new`.
- **Read the comments** — the highest-value correction is often a reply.
- High-yield subs: r/OSINT, r/LocalLLaMA, r/PromptEngineering, r/AI_Agents.

## Stack Overflow / Stack Exchange

- Filter by tag + score: `[web-scraping] [playwright] is:answer score:5..`, sort
  Newest.
- Plan for the `/nocaptcha` human-verification gate (a signed-in session clears it;
  challenges expire ~1–2 min).

## The caveat

Generating Boolean alone is "of little benefit." The query you end on is rarely
the query you started with — reformulate iteratively.
