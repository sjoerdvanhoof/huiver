import { expect, test } from "bun:test";
import { Glob } from "bun";
import path from "node:path";

/**
 * The app runs on Hermes, but these tests run on Bun — which happily provides
 * `crypto`, `Buffer` and the rest, so a missing-on-device global sails through
 * every other test and only shows up as a dialog on the phone. (It did: chapter
 * ids used `crypto.randomUUID`, and importing a book failed with "Property
 * 'crypto' doesn't exist".)
 *
 * So this reads the source rather than running it, and fails on APIs Hermes has
 * no answer for. Needing one of these is not forbidden — it means reaching for
 * the Expo module that provides it, and adding it here once it exists.
 */
const FORBIDDEN: { pattern: RegExp; what: string; instead: string }[] = [
  { pattern: /\bcrypto\s*\./, what: "Web Crypto", instead: "src/db's newId, or expo-crypto" },
  { pattern: /\bstructuredClone\s*\(/, what: "structuredClone", instead: "a hand-written clone" },
  { pattern: /\bBuffer\s*\./, what: "node's Buffer", instead: "Uint8Array" },
  { pattern: /\bfrom\s+["']node:/, what: "a node builtin", instead: "an expo-* module" },
  { pattern: /\brequire\s*\(\s*["']node:/, what: "a node builtin", instead: "an expo-* module" },
  { pattern: /\bprocess\.(env|cwd|platform)/, what: "node's process", instead: "expo-constants" },
];

const ROOT = path.join(import.meta.dir, "..");

function sources(): string[] {
  const files: string[] = [];
  for (const dir of ["src", "app"]) {
    for (const file of new Glob("**/*.{ts,tsx}").scanSync(path.join(ROOT, dir))) {
      if (file.endsWith(".test.ts") || file.endsWith(".test.tsx")) continue;
      files.push(path.join(dir, file));
    }
  }
  return files;
}

test("no app code depends on a global Hermes does not have", async () => {
  const offences: string[] = [];

  for (const file of sources()) {
    const text = await Bun.file(path.join(ROOT, file)).text();

    text.split("\n").forEach((line, index) => {
      // Comments describe these APIs on purpose — this very list, for one.
      const code = line.replace(/\/\/.*$/, "").replace(/^\s*\*.*$/, "");
      for (const rule of FORBIDDEN) {
        if (rule.pattern.test(code)) {
          offences.push(`${file}:${index + 1} uses ${rule.what} — use ${rule.instead}`);
        }
      }
    });
  }

  expect(offences).toEqual([]);
});

test("the scan actually looks at the app", () => {
  const files = sources();
  expect(files.length).toBeGreaterThan(15);
  expect(files).toContain(path.join("src", "db", "index.ts"));
});
