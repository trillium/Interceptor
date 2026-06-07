# VerifyDeploy

You are verifying that something works on a deployed page. This is the workflow for "confirm the fix landed", "reproduce the bug first", "check the deploy", and any task where the answer is "open the page and see what's actually there."

**Reproduce before fix.** If the user reported a UI bug, open the page first. Console errors and network 404s before code analysis. Never theorize from code when you can just look. This is non-negotiable.

## Command Budget

This workflow should complete in **3 commands**, max **4**:
1. `interceptor open <url>` → 1 command
2. `interceptor read --tree-only --tree-format compact` (or `--text-only` if you only need prose) → 1 command
3. (Optional) `interceptor inspect --filter <pattern>` if network behavior is in question → 1 command

If you're at command 3 and don't have the verdict, **re-read once with a narrower surface** (`read --text-only` or `text <ref>`) and commit with what's there. Do not add a 4th read.

## Steps

1. **Open the page.**
   ```bash
   interceptor open <url>
   ```
   For long verification loops (calling `open` many times in a session), pass `--reuse` to navigate the same managed tab instead of leaving dead tabs behind:
   ```bash
   interceptor open <url> --reuse
   ```

2. **Read structured state.** Default to a narrow read before screenshots — pick the surface that answers your question:
   ```bash
   interceptor read --tree-only --tree-format compact   # Actionable refs, agent-budget tree
   interceptor read --text-only                         # Just prose (cheaper than full tree)
   interceptor read                                     # Full (use only when both are needed)
   ```
   Prefer `--text-only` for fact verification; prefer `--tree-only --tree-format compact` for "find a button" tasks.
   If the page hides data behind XHRs:
   ```bash
   interceptor inspect                  # Tree + text + passive network
   interceptor inspect --filter api
   ```

3. **Check for client-side errors.**
   ```bash
   interceptor net log --filter "status>=400"  # HTTP errors
   interceptor net headers --filter api        # Header inspection
   ```

4. **Re-read after any mutation.** `act`, `click`, `type`, `keys`, and navigation can re-render. Refs from the prior read may be stale.

5. **Report the actual observed behavior.** Not what the code says should happen — what the page returned. If a value is wrong, quote it. If a request failed, give the status and URL.

## When to escalate to a screenshot

Only when pixels are the answer (visual layout, color, chart artifact). Use `workflows/screenshot-for-vlm.md` — the agent-default recipe keeps the file small and on-disk.

## Common pitfalls

- **Stale refs after navigation.** Always re-`read` after `open`, `navigate`, `back`, `forward`. The `eN` refs are bound to the previous DOM tree.
- **Reading the wrong tab.** If you've been working with multiple tabs, confirm with `interceptor tabs` or pass `--tab <id>` to scope.
- **Treating absence of error as success.** A 200 status with `<div>Internal Server Error</div>` in the body is still a failure — read the text, don't just check the network.

## Output format

Report:
- URL opened
- Observed state (one short paragraph or bullet list of key values)
- Any client-side errors (status codes, console output via `interceptor inspect`)
- Verdict: matches expected / does not match expected / inconclusive
- If verdict is "does not match" — the exact observed value vs the exact expected value
