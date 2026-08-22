import { mkdir, rm } from "node:fs/promises";
import path from "node:path";
import { UPLOAD_DIR, db, newId, type BookRow } from "./db";
import { extractBook } from "./extract-file";

/**
 * Add a book to the library: copy the source into data/uploads, extract its
 * chapters and record everything. Shared by the upload route and the
 * examples importer so both behave identically.
 */
export async function importBook(
  source: Blob | Uint8Array | string,
  originalName: string,
): Promise<BookRow> {
  const bookId = newId("bk");
  const dir = path.join(UPLOAD_DIR, bookId);
  await mkdir(dir, { recursive: true });

  const sourcePath = path.join(dir, path.basename(originalName));
  await Bun.write(sourcePath, typeof source === "string" ? Bun.file(source) : source);

  let extracted;
  try {
    extracted = await extractBook(sourcePath, originalName);
  } catch (error) {
    await rm(dir, { recursive: true, force: true });
    throw error;
  }

  // '' means "checked, this book has no cover" — the cover route won't retry.
  let coverPath = "";
  if (extracted.cover) {
    coverPath = path.join(dir, `cover.${extracted.cover.ext}`);
    await Bun.write(coverPath, extracted.cover.bytes);
  }

  const insertBook = db.query(
    "INSERT INTO books (id, title, author, format, source_path, created_at, cover_path) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  const insertChapter = db.query(
    "INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, ?, ?, ?, ?)",
  );

  db.transaction(() => {
    insertBook.run(bookId, extracted.title, extracted.author, extracted.format, sourcePath, Date.now(), coverPath);
    extracted.chapters.forEach((chapter, idx) => {
      insertChapter.run(newId("ch"), bookId, idx, chapter.title, chapter.text, chapter.text.length);
    });
  })();

  return db.query("SELECT * FROM books WHERE id = ?").get(bookId) as BookRow;
}

/**
 * Has a file of this name already been imported? Matches on the stored source
 * filename, so the examples importer can skip work without re-parsing a book.
 */
export function findBookBySourceName(fileName: string): BookRow | null {
  return db
    .query("SELECT * FROM books WHERE source_path LIKE ? LIMIT 1")
    .get(`%/${fileName}`) as BookRow | null;
}

export function countChapters(bookId: string): number {
  return (db.query("SELECT COUNT(*) AS n FROM chapters WHERE book_id = ?").get(bookId) as { n: number }).n;
}
