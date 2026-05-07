#!/usr/bin/env bun
/**
 * Refresh Apple Developer docs from JSON to Markdown.
 *
 * Walks an existing on-disk doc tree, derives the public JSON URL for each
 * directory, fetches the JSON from developer.apple.com, and rewrites the
 * directory's README.md as proper Markdown.
 *
 * Resumable: skips files that look already-rendered (no literal `\n` markers
 * in the first 400 bytes).
 *
 * Usage:
 *   bun scripts/refresh-apple-docs.ts --root <path> [--limit N]
 *                                     [--concurrency N] [--dry-run]
 *                                     [--only <substr>] [--force] [--verbose]
 *
 *   Or set INTERCEPTOR_APPLE_DOCS_ROOT in the environment.
 */

import { readdir, readFile, writeFile, stat, mkdir, appendFile } from "node:fs/promises";
import { join, relative, dirname } from "node:path";

// ---------- args ----------
type Args = {
  root: string;
  concurrency: number;
  limit: number;
  dryRun: boolean;
  only: string | null;
  force: boolean;
  verbose: boolean;
};

function parseArgs(argv: string[]): Args {
  const a: Args = {
    root: process.env.INTERCEPTOR_APPLE_DOCS_ROOT ?? "",
    concurrency: 24,
    limit: 0,
    dryRun: false,
    only: null,
    force: false,
    verbose: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === "--root") { a.root = v; i++; }
    else if (k === "--concurrency") { a.concurrency = Number(v); i++; }
    else if (k === "--limit") { a.limit = Number(v); i++; }
    else if (k === "--only") { a.only = v; i++; }
    else if (k === "--dry-run") a.dryRun = true;
    else if (k === "--force") a.force = true;
    else if (k === "--verbose") a.verbose = true;
  }
  return a;
}

// ---------- markdown renderer ----------
type Refs = Record<string, any>;

function refUrl(r: any): string {
  if (!r) return "";
  if (typeof r.url === "string") return r.url;
  return "";
}

function renderInline(items: any[] | undefined, refs: Refs): string {
  if (!items) return "";
  let out = "";
  for (const it of items) {
    if (!it || typeof it !== "object") continue;
    switch (it.type) {
      case "text":
        out += it.text ?? "";
        break;
      case "emphasis":
        out += `*${renderInline(it.inlineContent, refs)}*`;
        break;
      case "strong":
        out += `**${renderInline(it.inlineContent, refs)}**`;
        break;
      case "codeVoice":
        out += `\`${it.code ?? ""}\``;
        break;
      case "newTerm":
        out += `**${renderInline(it.inlineContent, refs)}**`;
        break;
      case "reference": {
        const r = refs[it.identifier];
        if (!r) {
          // Unresolved — fall back to the title slug from the identifier
          const slug = String(it.identifier ?? "").split("/").pop() ?? "";
          out += slug ? `\`${slug}\`` : "";
          break;
        }
        const title = r.title ?? "";
        const url = refUrl(r);
        out += url ? `[${title}](${url})` : title;
        break;
      }
      case "link":
        out += `[${it.title ?? it.destination ?? ""}](${it.destination ?? ""})`;
        break;
      case "image": {
        const r = refs[it.identifier];
        const v = r?.variants?.[0];
        const alt = r?.alt ?? "";
        if (v?.url) out += `![${alt}](${v.url})`;
        break;
      }
      case "inlineHead":
        out += `**${renderInline(it.inlineContent, refs)}**`;
        break;
      default:
        if (Array.isArray(it.inlineContent)) {
          out += renderInline(it.inlineContent, refs);
        }
    }
  }
  return out;
}

function renderContent(blocks: any[] | undefined, refs: Refs, listDepth = 0): string {
  if (!blocks) return "";
  let out = "";
  for (const b of blocks) {
    if (!b || typeof b !== "object") continue;
    switch (b.type) {
      case "heading": {
        const lvl = Math.min(Math.max(b.level ?? 2, 2), 6);
        out += `${"#".repeat(lvl)} ${b.text ?? ""}\n\n`;
        break;
      }
      case "paragraph":
        out += renderInline(b.inlineContent, refs).trim() + "\n\n";
        break;
      case "codeListing": {
        const code = Array.isArray(b.code) ? b.code.join("\n") : String(b.code ?? "");
        out += "```" + (b.syntax ?? "") + "\n" + code + "\n```\n\n";
        break;
      }
      case "unorderedList": {
        const indent = "  ".repeat(listDepth);
        for (const item of b.items ?? []) {
          const inner = renderContent(item.content, refs, listDepth + 1).trim();
          // Indent continuation lines
          const lines = inner.split("\n");
          out += `${indent}- ${lines[0] ?? ""}\n`;
          for (let i = 1; i < lines.length; i++) {
            if (lines[i].length) out += `${indent}  ${lines[i]}\n`;
            else out += "\n";
          }
        }
        out += "\n";
        break;
      }
      case "orderedList": {
        const indent = "  ".repeat(listDepth);
        let n = 1;
        for (const item of b.items ?? []) {
          const inner = renderContent(item.content, refs, listDepth + 1).trim();
          const lines = inner.split("\n");
          out += `${indent}${n}. ${lines[0] ?? ""}\n`;
          for (let i = 1; i < lines.length; i++) {
            if (lines[i].length) out += `${indent}   ${lines[i]}\n`;
            else out += "\n";
          }
          n++;
        }
        out += "\n";
        break;
      }
      case "termList": {
        for (const item of b.items ?? []) {
          const term = renderInline(item.term?.inlineContent, refs).trim();
          const def = renderContent(item.definition?.content, refs).trim();
          out += `- **${term}**: ${def}\n`;
        }
        out += "\n";
        break;
      }
      case "aside": {
        const label = (b.style ?? b.name ?? "Note") as string;
        const inner = renderContent(b.content, refs).trim();
        const quoted = inner.split("\n").map((l) => (l.length ? `> ${l}` : ">")).join("\n");
        out += `> **${label}**\n>\n${quoted}\n\n`;
        break;
      }
      case "table": {
        const rows: any[][] = b.rows ?? [];
        if (!rows.length) break;
        const renderCell = (cell: any[]) =>
          renderContent(cell, refs).replace(/\n+/g, " ").trim();
        const head = rows[0].map(renderCell);
        const rest = rows.slice(1).map((r) => r.map(renderCell));
        out += `| ${head.join(" | ")} |\n`;
        out += `| ${head.map(() => "---").join(" | ")} |\n`;
        for (const r of rest) out += `| ${r.join(" | ")} |\n`;
        out += "\n";
        break;
      }
      case "small":
        out += renderInline(b.inlineContent, refs).trim() + "\n\n";
        break;
      default:
        // Recurse if it has content/inlineContent we recognize
        if (Array.isArray(b.content)) out += renderContent(b.content, refs, listDepth);
        else if (Array.isArray(b.inlineContent))
          out += renderInline(b.inlineContent, refs) + "\n\n";
    }
  }
  return out;
}

function renderTopicLink(id: string, refs: Refs): string | null {
  const r = refs[id];
  if (!r) return null;
  const title = r.title ?? id.split("/").pop() ?? id;
  const url = refUrl(r);
  const abstract = renderInline(r.abstract, refs).trim();
  if (url) {
    return abstract
      ? `- [${title}](${url}): ${abstract}`
      : `- [${title}](${url})`;
  }
  return abstract ? `- ${title}: ${abstract}` : `- ${title}`;
}

function renderDoc(j: any): string {
  const refs: Refs = j.references ?? {};
  const meta = j.metadata ?? {};
  const title = meta.title ?? j.identifier?.url?.split("/").pop() ?? "(untitled)";
  const role = meta.roleHeading ?? meta.symbolKind ?? meta.role ?? "";
  const platforms = (meta.platforms ?? [])
    .map((p: any) => {
      const intro = p.introducedAt ? `${p.introducedAt}+` : "";
      const dep = p.deprecatedAt ? ` (deprecated ${p.deprecatedAt})` : "";
      return `${p.name}${intro ? ` ${intro}` : ""}${dep}`;
    })
    .join(" | ");
  const abstract = renderInline(j.abstract, refs).trim();

  let md = `# ${title}\n\n`;
  if (role) md += `*${role}*\n\n`;
  if (platforms) md += `**Availability:** ${platforms}\n\n`;
  if (abstract) md += `> ${abstract}\n\n`;

  for (const s of j.primaryContentSections ?? []) {
    if (s.kind === "declarations") {
      for (const d of s.declarations ?? []) {
        const code = (d.tokens ?? []).map((t: any) => t.text ?? "").join("");
        const lang = d.languages?.[0] ?? "swift";
        md += `## Declaration\n\n\`\`\`${lang}\n${code}\n\`\`\`\n\n`;
      }
    } else if (s.kind === "parameters") {
      md += `## Parameters\n\n`;
      for (const p of s.parameters ?? []) {
        const desc = renderContent(p.content, refs).trim();
        md += `- **${p.name}**: ${desc}\n`;
      }
      md += "\n";
    } else if (s.kind === "content") {
      md += renderContent(s.content, refs);
    } else if (s.kind === "properties" || s.kind === "attributes") {
      md += `## Properties\n\n`;
      for (const p of s.items ?? []) {
        const name = p.name ?? "";
        const desc = renderContent(p.content, refs).trim();
        md += `- **${name}**${desc ? `: ${desc}` : ""}\n`;
      }
      md += "\n";
    } else if (s.kind === "restEndpoint" && s.tokens) {
      const code = s.tokens.map((t: any) => t.text ?? "").join("");
      md += `## Endpoint\n\n\`\`\`http\n${code}\n\`\`\`\n\n`;
    }
  }

  for (const t of j.topicSections ?? []) {
    md += `## ${t.title ?? "Topics"}\n\n`;
    for (const id of t.identifiers ?? []) {
      const line = renderTopicLink(id, refs);
      if (line) md += `${line}\n`;
    }
    md += "\n";
  }

  for (const sa of j.seeAlsoSections ?? []) {
    md += `## See Also\n\n`;
    if (sa.title) md += `### ${sa.title}\n\n`;
    for (const id of sa.identifiers ?? []) {
      const line = renderTopicLink(id, refs);
      if (line) md += `${line}\n`;
    }
    md += "\n";
  }

  return md.replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

// ---------- IO ----------
async function* walkDirs(root: string): AsyncGenerator<string> {
  const stack: string[] = [root];
  while (stack.length) {
    const dir = stack.pop()!;
    let ents;
    try {
      ents = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    yield dir;
    for (const e of ents) {
      if (e.isDirectory()) stack.push(join(dir, e.name));
    }
  }
}

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

async function fetchJson(url: string, attempt = 0): Promise<any | null> {
  try {
    const r = await fetch(url, {
      headers: { "User-Agent": UA, Accept: "application/json" },
      signal: AbortSignal.timeout(30_000),
    });
    if (r.status === 404) return null;
    if (r.status === 429 || r.status >= 500) {
      if (attempt >= 4) return null;
      const wait = 500 * 2 ** attempt + Math.random() * 250;
      await new Promise((res) => setTimeout(res, wait));
      return fetchJson(url, attempt + 1);
    }
    if (!r.ok) return null;
    const text = await r.text();
    try {
      return JSON.parse(text);
    } catch {
      return null;
    }
  } catch {
    if (attempt >= 3) return null;
    const wait = 500 * 2 ** attempt + Math.random() * 250;
    await new Promise((res) => setTimeout(res, wait));
    return fetchJson(url, attempt + 1);
  }
}

// Disk-safe Swift signatures encode `:` as `_`. Decode each paren group:
// scan label-then-colon-marker pairs. A label is either a single `_`
// (unlabeled arg) or a run of [A-Za-z0-9]; the next `_` is the colon.
function decodeSignatureGroup(inner: string): string {
  if (!inner) return "";
  let out = "";
  let i = 0;
  while (i < inner.length) {
    const c = inner[i];
    if (c === "_") {
      // Unlabeled arg: emit `_`, then the next `_` (if any) is the colon
      out += "_";
      i++;
      if (i < inner.length && inner[i] === "_") {
        out += ":";
        i++;
      }
    } else if (/[A-Za-z0-9]/.test(c)) {
      // Read identifier
      let j = i;
      while (j < inner.length && /[A-Za-z0-9]/.test(inner[j])) j++;
      out += inner.substring(i, j);
      i = j;
      if (i < inner.length && inner[i] === "_") {
        out += ":";
        i++;
      }
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

function diskSegmentToUrlSegment(segment: string): string {
  return segment.replace(/\(([^)]*)\)/g, (_, inner) => `(${decodeSignatureGroup(inner)})`);
}

function dirToUrl(root: string, dir: string): string {
  const rel = relative(root, dir);
  if (!rel) return ""; // root itself
  const parts = rel.split("/").map(diskSegmentToUrlSegment);
  return `https://developer.apple.com/tutorials/data/documentation/${parts.join("/")}.json`;
}

async function isAlreadyRendered(readme: string): Promise<boolean> {
  try {
    const buf = await readFile(readme);
    const head = buf.subarray(0, 400).toString("utf8");
    // The broken format has literal `\n` (backslash-n) characters
    return !head.includes("\\n");
  } catch {
    return false;
  }
}

// ---------- main ----------
async function main() {
  const args = parseArgs(Bun.argv.slice(2));
  if (!args.root) {
    console.error("error: refresh-apple-docs requires --root <path> or INTERCEPTOR_APPLE_DOCS_ROOT env var");
    process.exit(1);
  }
  console.log(`refresh-apple-docs starting | root=${args.root} concurrency=${args.concurrency} dryRun=${args.dryRun}`);

  const failureLog = join(args.root, "..", ".refresh-apple-docs.failures.log");
  const progressLog = join(args.root, "..", ".refresh-apple-docs.progress.log");
  await appendFile(progressLog, `\n=== run started ${new Date().toISOString()} ===\n`).catch(() => {});

  // 1) Collect dirs
  const dirs: string[] = [];
  console.log("scanning directories...");
  for await (const d of walkDirs(args.root)) {
    if (d === args.root) continue;
    if (args.only && !d.includes(args.only)) continue;
    dirs.push(d);
    if (args.limit && dirs.length >= args.limit) break;
  }
  console.log(`found ${dirs.length} candidate directories`);

  // 2) Worker pool
  let i = 0;
  let done = 0;
  let skipped = 0;
  let written = 0;
  let failed = 0;
  let missing = 0;
  const total = dirs.length;
  const startedAt = Date.now();

  let lastReport = Date.now();
  const report = (force = false) => {
    const now = Date.now();
    if (!force && now - lastReport < 5000) return;
    lastReport = now;
    const elapsed = (now - startedAt) / 1000;
    const rate = done / Math.max(elapsed, 0.001);
    const eta = rate > 0 ? Math.round((total - done) / rate) : 0;
    const line = `[${new Date().toISOString()}] ${done}/${total} (${(done/total*100).toFixed(1)}%) | written=${written} skipped=${skipped} 404=${missing} failed=${failed} | ${rate.toFixed(1)}/s | eta ${Math.floor(eta/60)}m${eta%60}s`;
    console.log(line);
    appendFile(progressLog, line + "\n").catch(() => {});
  };

  async function worker() {
    while (true) {
      const idx = i++;
      if (idx >= dirs.length) return;
      const dir = dirs[idx];
      const readme = join(dir, "README.md");
      try {
        if (!args.force && (await isAlreadyRendered(readme))) {
          skipped++;
          done++;
          report();
          continue;
        }
        const url = dirToUrl(args.root, dir);
        if (!url) { done++; continue; }
        const j = await fetchJson(url);
        if (j === null) {
          missing++;
          await appendFile(failureLog, `MISSING ${url}\n`).catch(() => {});
        } else {
          const md = renderDoc(j);
          if (args.dryRun) {
            if (args.verbose) console.log(`[DRY] would write ${readme} (${md.length} bytes)`);
          } else {
            await mkdir(dirname(readme), { recursive: true });
            await writeFile(readme, md);
            written++;
            if (args.verbose) console.log(`wrote ${readme}`);
          }
        }
      } catch (e: any) {
        failed++;
        await appendFile(failureLog, `ERROR ${dir} ${e?.message ?? e}\n`).catch(() => {});
      }
      done++;
      report();
    }
  }

  const workers = Array.from({ length: args.concurrency }, () => worker());
  await Promise.all(workers);
  report(true);

  console.log(`\nDONE. written=${written} skipped=${skipped} 404=${missing} failed=${failed} | failures: ${failureLog}`);
}

main().catch((e) => {
  console.error("fatal:", e);
  process.exit(1);
});
