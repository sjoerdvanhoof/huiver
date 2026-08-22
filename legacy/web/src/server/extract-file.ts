import { extractBookFromBytes, type ExtractedBook } from "@huiver/shared";

/**
 * Read an uploaded file off disk and hand it to the shared extractor. The
 * parsing itself is platform-neutral (the mobile app runs the same code on
 * bytes from a document picker); only this read is Bun's.
 */
export async function extractBook(filePath: string, originalName: string): Promise<ExtractedBook> {
  const bytes = new Uint8Array(await Bun.file(filePath).arrayBuffer());
  return extractBookFromBytes(bytes, originalName);
}
