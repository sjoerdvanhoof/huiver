/**
 * Download a small corpus of public-domain EPUBs from Project Gutenberg into
 * examples/, then verify each one parses with huiver's own extractor.
 *
 * The files are gitignored on purpose — the repo stays lean and anyone can
 * refill the folder with `bun run examples`.
 *
 *   bun run examples
 */
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { extractBook } from "../src/server/extract-file";

type Entry = { id: number; slug: string; why: string };

// Chosen to exercise different EPUB shapes: numbered chapters, short stories,
// epistolary formats, very short texts, and one genuinely long book.
const BOOKS: Entry[] = [
  { id: 11, slug: "alice-in-wonderland", why: "short, heavy dialogue" },
  { id: 1952, slug: "the-yellow-wallpaper", why: "very short — fastest end-to-end test" },
  { id: 5200, slug: "metamorphosis", why: "3 long chapters" },
  { id: 35, slug: "the-time-machine", why: "compact, 16 chapters" },
  { id: 84, slug: "frankenstein", why: "epistolary, opens with letters" },
  { id: 1661, slug: "sherlock-holmes", why: "12 self-contained stories" },
  { id: 1342, slug: "pride-and-prejudice", why: "61 short chapters — good chapter-list test" },
  { id: 345, slug: "dracula", why: "epistolary, journal entries" },
  { id: 74, slug: "tom-sawyer", why: "dialect-heavy prose" },
  { id: 2701, slug: "moby-dick", why: "long — stress test (~130 chapters)" },
];

const OUT_DIR = path.join(process.cwd(), "examples");

// Prefer the no-images build: same text, far smaller download.
const candidateUrls = (id: number) => [
  `https://www.gutenberg.org/ebooks/${id}.epub.noimages`,
  `https://www.gutenberg.org/ebooks/${id}.epub3.images`,
  `https://www.gutenberg.org/cache/epub/${id}/pg${id}.epub`,
];

const isZip = (b: Uint8Array) => b[0] === 0x50 && b[1] === 0x4b;

async function download(entry: Entry): Promise<Uint8Array | null> {
  for (const url of candidateUrls(entry.id)) {
    try {
      const res = await fetch(url, {
        headers: { "User-Agent": "huiver-example-fetcher/0.1 (local testing; contact: repo owner)" },
      });
      if (!res.ok) continue;
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (isZip(bytes)) return bytes;
    } catch {
      // Try the next candidate URL.
    }
  }
  return null;
}

await mkdir(OUT_DIR, { recursive: true });

const rows: string[] = [];
let failures = 0;

for (const [index, entry] of BOOKS.entries()) {
  const dest = path.join(OUT_DIR, `${entry.slug}.epub`);
  const existing = Bun.file(dest);

  let bytes: Uint8Array | null = null;
  if (await existing.exists()) {
    bytes = new Uint8Array(await existing.arrayBuffer());
    console.log(`· ${entry.slug} — already present`);
  } else {
    process.stdout.write(`↓ ${entry.slug} (gutenberg #${entry.id}) … `);
    bytes = await download(entry);
    if (!bytes) {
      console.log("FAILED");
      failures++;
      continue;
    }
    await Bun.write(dest, bytes);
    console.log(`${(bytes.byteLength / 1024).toFixed(0)} KB`);
    // Be a polite guest on someone else's bandwidth.
    if (index < BOOKS.length - 1) await Bun.sleep(700);
  }

  // Parsing it here means this script doubles as a real-world extractor test.
  try {
    const book = await extractBook(dest, `${entry.slug}.epub`);
    const chars = book.chapters.reduce((sum, c) => sum + c.text.length, 0);
    const hours = (chars * 0.06) / 3600; // ~0.06s of speech per character
    rows.push(
      `${book.title.slice(0, 34).padEnd(36)}${String(book.chapters.length).padStart(5)}` +
        `${(chars / 1000).toFixed(0).padStart(8)}k${hours.toFixed(1).padStart(8)}h   ${entry.why}`,
    );
  } catch (error) {
    rows.push(`${entry.slug.padEnd(36)}  PARSE FAILED — ${error instanceof Error ? error.message : error}`);
    failures++;
  }
}

console.log(`\n${"title".padEnd(36)}${"chaps".padStart(5)}${"chars".padStart(9)}${"audio".padStart(9)}   note`);
console.log("-".repeat(110));
for (const row of rows) console.log(row);

console.log(
  failures === 0
    ? `\n${BOOKS.length} example books ready in examples/ — drop one into the app to try it.`
    : `\n${failures} book(s) failed.`,
);
process.exit(failures === 0 ? 0 : 1);
