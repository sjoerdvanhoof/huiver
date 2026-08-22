import { expect, test } from "bun:test";
import path from "node:path";

/**
 * The sample corpus ships in git, but .gitignore is default-deny for ebooks so
 * nobody's personal library leaks into a public repo. That means every sample
 * needs an explicit `!apps/web/examples/<slug>.epub` line. Forgetting one fails
 * silently — the book just never gets committed — so assert the two lists agree.
 */
const appRoot = path.join(import.meta.dir, "..");
const repoRoot = path.join(appRoot, "..", "..");

async function sampleSlugs(): Promise<string[]> {
  const source = await Bun.file(path.join(appRoot, "scripts", "fetch-examples.ts")).text();
  const block = source.match(/const BOOKS:\s*Entry\[\]\s*=\s*\[([\s\S]*?)\n\];/)?.[1];
  if (!block) throw new Error("Could not find the BOOKS list in scripts/fetch-examples.ts");
  return [...block.matchAll(/slug:\s*"([^"]+)"/g)].map(m => m[1]!).sort();
}

/** The one .gitignore lives at the monorepo root and covers every workspace. */
function gitignoreText(): Promise<string> {
  return Bun.file(path.join(repoRoot, ".gitignore")).text();
}

async function allowlistedSlugs(): Promise<string[]> {
  const gitignore = await gitignoreText();
  return [...gitignore.matchAll(/^!apps\/web\/examples\/(.+)\.epub$/gm)].map(m => m[1]!).sort();
}

test("every sample book is allowlisted in .gitignore", async () => {
  expect(await allowlistedSlugs()).toEqual(await sampleSlugs());
});

test(".gitignore still blocks ebooks by default", async () => {
  const gitignore = await gitignoreText();

  // A personal book must not be committable just by dropping it in examples/.
  expect(gitignore).toMatch(/^\*\.epub$/m);
  expect(gitignore).toMatch(/^examples\/\*$/m);

  // Allowlist entries have to come after the blanket rules, or they do nothing.
  const lines = gitignore.split("\n");
  const blanket = lines.findIndex(line => line.trim() === "*.epub");
  const firstAllow = lines.findIndex(line => line.startsWith("!apps/web/examples/"));
  expect(firstAllow).toBeGreaterThan(blanket);
});
