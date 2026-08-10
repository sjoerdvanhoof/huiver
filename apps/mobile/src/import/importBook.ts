import { extractBookFromBytes, SUPPORTED_EXTENSIONS } from "@huiver/shared";
import * as DocumentPicker from "expo-document-picker";
import { File } from "expo-file-system";
import { db, newId } from "../db";
import { coverFile, ensureDir } from "../files";

/**
 * Bringing a book in. The picker hands over bytes; the parsing is the very same
 * extractor the server runs (@huiver/shared), so a book imported on the phone
 * splits into exactly the chapters it would on the desktop.
 */

/** iOS reports EPUBs under a few different types depending on where they came from. */
const MIME_TYPES = ["application/epub+zip", "application/zip", "text/plain", "text/html", "text/markdown", "*/*"];

export type ImportedBook = { id: string; title: string; chapterCount: number };

export async function pickAndImportBook(): Promise<ImportedBook | null> {
  const result = await DocumentPicker.getDocumentAsync({
    type: MIME_TYPES,
    copyToCacheDirectory: true,
    multiple: false,
  });
  if (result.canceled) return null;

  const asset = result.assets[0];
  if (!asset) return null;

  const bytes = await new File(asset.uri).bytes();
  return importBytes(bytes, asset.name);
}

export function importBytes(bytes: Uint8Array, originalName: string): ImportedBook {
  const book = extractBookFromBytes(bytes, originalName);
  const bookId = newId("bk");

  let coverPath: string | null = null;
  if (book.cover) {
    const file = coverFile(bookId, book.cover.ext);
    ensureDir(file.parentDirectory);
    file.create({ overwrite: true });
    file.write(book.cover.bytes);
    coverPath = file.uri;
  }

  db.withTransactionSync(() => {
    db.runSync("INSERT INTO books (id, title, author, format, created_at, cover_path) VALUES (?, ?, ?, ?, ?, ?)", [
      bookId,
      book.title,
      book.author,
      book.format,
      Date.now(),
      coverPath,
    ]);

    book.chapters.forEach((chapter, idx) => {
      db.runSync("INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, ?, ?, ?, ?)", [
        newId("ch"),
        bookId,
        idx,
        chapter.title,
        chapter.text,
        chapter.text.length,
      ]);
    });
  });

  return { id: bookId, title: book.title, chapterCount: book.chapters.length };
}

export { SUPPORTED_EXTENSIONS };
