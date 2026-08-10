/**
 * Put every book in examples/ onto the library shelf.
 *
 * Downloading a file does not add it to the library — the library lives in
 * SQLite. This walks examples/ and imports anything not already there, using
 * exactly the same code path as a drag-and-drop upload.
 *
 *   bun run examples:import
 *
 * Safe to run while `bun dev` is up (SQLite is in WAL mode); reload the page
 * afterwards to see the new books.
 */
import path from "node:path";
import { countChapters, findBookBySourceName, importBook } from "../src/server/library";

const PATTERNS = ["examples/*.epub", "examples/*.txt", "examples/*.md", "examples/*.html"];

/** This folder documents itself; those files are not books. */
const NOT_BOOKS = new Set(["readme.md", "readme.txt", "notes.md"]);

const files: string[] = [];
for (const pattern of PATTERNS) {
  for await (const file of new Bun.Glob(pattern).scan()) {
    if (!NOT_BOOKS.has(path.basename(file).toLowerCase())) files.push(file);
  }
}
files.sort();

if (files.length === 0) {
  console.log("Nothing in examples/ yet — run `bun run examples` first.");
  process.exit(0);
}

let added = 0;
let skipped = 0;
let failed = 0;

for (const file of files) {
  const name = path.basename(file);

  const existing = findBookBySourceName(name);
  if (existing) {
    console.log(`· ${existing.title} — already in library`);
    skipped++;
    continue;
  }

  try {
    const book = await importBook(file, name);
    console.log(`+ ${book.title} — ${countChapters(book.id)} chapters`);
    added++;
  } catch (error) {
    console.log(`✗ ${name} — ${error instanceof Error ? error.message : error}`);
    failed++;
  }
}

console.log(
  `\n${added} added, ${skipped} already present${failed ? `, ${failed} failed` : ""}.` +
    (added > 0 ? " Reload http://localhost:3000 to see them." : ""),
);
process.exit(failed > 0 ? 1 : 0);
