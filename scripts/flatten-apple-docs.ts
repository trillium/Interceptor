#!/usr/bin/env bun
/**
 * Flatten the apple-developer-docs tree.
 *
 * Before:
 *   Accessibility/AccessibilityNotification/README.md
 *   Accessibility/AccessibilityNotification/Announcement/README.md
 *   Accessibility/AccessibilityNotification/Announcement/init(__)-46byj/README.md
 *
 * After:
 *   Accessibility.md                                                 (framework overview)
 *   Accessibility/AccessibilityNotification.md                       (type doc)
 *   Accessibility/AccessibilityNotification/Announcement.md          (case doc)
 *   Accessibility/AccessibilityNotification/Announcement/init(__)-46byj.md
 *
 * Rule (applied recursively): if directory D contains README.md, move that
 * README.md to <parent_of_D>/<basename(D)>.md. If D has no other content,
 * remove D after the move. If D had children (subdirs), keep D as a folder
 * for the children — but D no longer holds its own README.
 *
 * Idempotent. Safe to re-run. Reports collisions and skips them.
 */

import { readdir, rename, rm, rmdir, stat, readFile, writeFile } from "node:fs/promises";
import { join, dirname, basename, relative } from "node:path";

type Args = {
  root: string;
  dryRun: boolean;
  onCollision: "skip" | "overwrite" | "rename";
  verbose: boolean;
};

function parseArgs(argv: string[]): Args {
  const a: Args = {
    // Set --root <path> or INTERCEPTOR_APPLE_DOCS_ROOT in the environment.
    root: process.env.INTERCEPTOR_APPLE_DOCS_ROOT ?? "",
    dryRun: false,
    onCollision: "overwrite",
    verbose: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === "--root") { a.root = v; i++; }
    else if (k === "--collision") { a.onCollision = v as any; i++; }
    else if (k === "--dry-run") a.dryRun = true;
    else if (k === "--verbose") a.verbose = true;
  }
  return a;
}

async function* walkReadmes(root: string): AsyncGenerator<string> {
  const stack: string[] = [root];
  while (stack.length) {
    const dir = stack.pop()!;
    let ents;
    try {
      ents = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of ents) {
      const full = join(dir, e.name);
      if (e.isDirectory()) stack.push(full);
      else if (e.isFile() && e.name === "README.md") yield full;
    }
  }
}

async function main() {
  const args = parseArgs(Bun.argv.slice(2));
  if (!args.root) {
    console.error("error: flatten-apple-docs requires --root <path> or INTERCEPTOR_APPLE_DOCS_ROOT env var");
    process.exit(1);
  }
  console.log(`flatten-apple-docs | root=${args.root} dryRun=${args.dryRun} collision=${args.onCollision}`);

  const startedAt = Date.now();

  // Pass 1: collect all README paths
  console.log("scanning...");
  const readmes: string[] = [];
  for await (const p of walkReadmes(args.root)) readmes.push(p);
  console.log(`found ${readmes.length} README.md files`);

  // Pass 2: plan + execute
  let moved = 0;
  let collisionsResolved = 0;
  let collisionsSkipped = 0;
  let identicalDeduped = 0;
  let errors = 0;

  let lastReport = Date.now();
  const report = (force = false) => {
    const now = Date.now();
    if (!force && now - lastReport < 2000) return;
    lastReport = now;
    const elapsed = (now - startedAt) / 1000;
    const done = moved + collisionsResolved + collisionsSkipped + identicalDeduped + errors;
    const rate = done / Math.max(elapsed, 0.001);
    console.log(`  ${done}/${readmes.length} | moved=${moved} collisions=${collisionsResolved}+${collisionsSkipped}skip dedup=${identicalDeduped} err=${errors} | ${rate.toFixed(0)}/s`);
  };

  // Process in chunks to avoid overwhelming the FS with parallelism;
  // pure FS rename is already fast.
  const chunkSize = 64;
  for (let i = 0; i < readmes.length; i += chunkSize) {
    const chunk = readmes.slice(i, i + chunkSize);
    await Promise.all(chunk.map(async (readme) => {
      try {
        const dir = dirname(readme);
        const parent = dirname(dir);
        const name = basename(dir);
        const target = join(parent, `${name}.md`);

        // Are there any siblings besides README.md inside dir?
        // We don't need to know to do the move — README.md just becomes <name>.md.
        // The dir itself stays if it has subdirs/other files.

        if (target === readme) {
          // shouldn't happen — but skip
          return;
        }

        let targetExists = false;
        try { await stat(target); targetExists = true; } catch {}

        if (targetExists) {
          // Compare content
          const [a, b] = await Promise.all([readFile(readme), readFile(target)]);
          if (a.equals(b)) {
            if (!args.dryRun) await rm(readme);
            identicalDeduped++;
          } else if (args.onCollision === "overwrite") {
            if (!args.dryRun) {
              await rm(target);
              await rename(readme, target);
            }
            collisionsResolved++;
            if (args.verbose) console.log(`  collision-overwrite: ${target}`);
          } else if (args.onCollision === "rename") {
            const alt = join(parent, `${name}__readme.md`);
            if (!args.dryRun) await rename(readme, alt);
            collisionsResolved++;
            if (args.verbose) console.log(`  collision-renamed: ${readme} → ${alt}`);
          } else {
            collisionsSkipped++;
            if (args.verbose) console.log(`  collision-skip: ${readme}`);
          }
        } else {
          if (!args.dryRun) await rename(readme, target);
          moved++;
        }
      } catch (e: any) {
        errors++;
        console.error(`  ERROR ${readme}: ${e?.message ?? e}`);
      }
    }));
    report();
  }
  report(true);

  // Pass 3: prune empty dirs (depth-first)
  console.log("pruning empty dirs...");
  let pruned = 0;
  async function pruneEmptyDir(dir: string): Promise<boolean> {
    let ents;
    try {
      ents = await readdir(dir, { withFileTypes: true });
    } catch {
      return false;
    }
    let allChildrenRemoved = true;
    for (const e of ents) {
      if (e.isDirectory()) {
        const childPath = join(dir, e.name);
        const removed = await pruneEmptyDir(childPath);
        if (!removed) allChildrenRemoved = false;
      } else {
        allChildrenRemoved = false;
      }
    }
    if (allChildrenRemoved && dir !== args.root) {
      if (!args.dryRun) {
        try {
          await rmdir(dir);
          pruned++;
          return true;
        } catch (e: any) {
          if (args.verbose) console.error(`  rmdir failed ${dir}: ${e?.message}`);
          return false;
        }
      } else {
        pruned++;
        return true;
      }
    }
    return false;
  }
  await pruneEmptyDir(args.root);
  console.log(`pruned ${pruned} empty dirs`);

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
  console.log(`\nDONE in ${elapsed}s`);
  console.log(`  moved=${moved}`);
  console.log(`  collisions resolved (overwrite/rename)=${collisionsResolved}`);
  console.log(`  collisions skipped=${collisionsSkipped}`);
  console.log(`  identical deduped=${identicalDeduped}`);
  console.log(`  errors=${errors}`);
  console.log(`  empty dirs pruned=${pruned}`);
}

main().catch((e) => { console.error("fatal:", e); process.exit(1); });
