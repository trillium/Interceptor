# MultiPageCompare

You are extracting facts from N pages and answering a comparative question — "who designed Python vs JavaScript", "what year did each of these papers publish", "compare pricing across these three product pages". The answer lives in plain prose on each page; the structure (refs, tree) does not matter. You need fast, sequential fact extraction with minimal context bloat.

## Command Budget

This workflow should complete in **2 + 1 per page**: 3 commands for two pages, 4 commands for three pages, 5 for four. The pattern:

1. `interceptor open <url-1> --text-only` → 1 command (open + read prose in one shot)
2. `interceptor open <url-2> --text-only` → 1 command
3. (... 1 more per page ...)
4. Answer with the facts extracted from each page's text.

If a page returns the wrong section (table-of-contents instead of the article body), spend 1 extra command on a scoped `interceptor read e<ref> --text-only` — once, not twice. Then commit to the answer with what you have.

## Why this exists

**Without explicit guidance the agent thrashes on multi-page comparisons** — it opens page A, opens page B, then re-opens page A trying to "go back," sometimes mixing `tab new` and `navigate` calls. Tab-state confusion. This workflow prevents that.

## Procedure

1. **One `open --text-only` per page.** The `--text-only` flag returns prose without the actionable-element tree, which is the only thing you need for fact extraction. Skipping the tree cuts ~70% of the per-page token cost.

   ```bash
   interceptor open "https://en.wikipedia.org/wiki/Python_(programming_language)" --text-only
   interceptor open "https://en.wikipedia.org/wiki/JavaScript" --text-only
   ```

2. **Read each result in your context.** The text is already there from the `open` call — you do not need a follow-up `read`. Each `open` is open + wait + read in one round-trip.

3. **Answer from the texts.** Quote the exact fact from each page, naming the page it came from. If a page's text didn't contain the fact, say so for that page and answer only for the pages where you found it. Do not re-open.

## Anti-patterns

- **DO NOT use `tab new`** — `interceptor open` already creates a tab. Calling `tab new` then `navigate` to do what `open` does in one shot is the most common over-spend on this task type.
- **DO NOT use `navigate` after `open`** — `open` already navigates. `navigate` is for changing pages *within an already-managed tab*, not for opening a fresh page.
- **DO NOT re-open the same page** — your context still has its text from the first call. The second call is identical bytes and wastes a command. If you think the first read missed something, scope down (`read e<ref> --text-only`) or accept what's there and commit.
- **DO NOT use full `interceptor read`** — the tree is irrelevant when you're extracting prose facts. `--text-only` is the right surface.
- **DO NOT chain `open` calls before reading any results** — read each one before opening the next, so you can decide whether you have enough. Sometimes page 1's text answers the whole question.

## When NOT to use this workflow

- **Single-page tasks** — use `read-and-extract.md`. This workflow is for ≥ 2 pages.
- **Tasks where the answer requires clicking something on each page** — use `read-and-extract.md` or `verify-deploy.md` with `--tree-only --tree-format compact` instead. Multi-page-compare assumes the prose contains the answer.
- **Pages behind auth or with heavy JS rendering** — `--text-only` may miss content loaded after first paint. Fall back to full `read` for those specific pages, but stay sequential (one page at a time).

## Output format

Report each page's fact, then the comparative answer:

```
Page 1 (Python wiki): Guido van Rossum, released 1991.
Page 2 (JavaScript wiki): Brendan Eich, released 1995.

Answer: Python was designed by Guido van Rossum (1991); JavaScript was designed by Brendan Eich (1995). Python predates JavaScript by 4 years.
```

If you couldn't extract a fact from a page, name the page and what you tried:

```
Page 1: extracted (Guido van Rossum, 1991).
Page 2: page text did not include the creator's name; the byline was rendered post-load.
```

Do not invent the missing fact. Do not retry indefinitely — name the gap and move on.
