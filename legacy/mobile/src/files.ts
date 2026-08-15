import { Directory, File, Paths } from "expo-file-system";

/**
 * Where the library lives on disk.
 *
 * Everything is stored relative to the document directory and resolved at call
 * time: iOS gives the app container a new UUID on every install, so an absolute
 * path saved in the database would break at the next update.
 */

const AUDIO = "audio";
const COVERS = "covers";
const CHUNKS = "chunks";

/** Audio the user would lose by deleting it, so not the cache directory. */
export const audioRoot = () => new Directory(Paths.document, AUDIO);

export const chapterDir = (chapterId: string) => new Directory(audioRoot(), chapterId);

/** Chunk WAVs, written as a chapter is synthesized. These are the checkpoint. */
export const chunkDir = (chapterId: string) => new Directory(chapterDir(chapterId), CHUNKS);

export const chunkFile = (chapterId: string, index: number) =>
  new File(chunkDir(chapterId), `${String(index).padStart(5, "0")}.wav`);

/** The stitched chapter, written once every chunk has been rendered. */
export const chapterFile = (chapterId: string) => new File(chapterDir(chapterId), "chapter.wav");

export const coverFile = (bookId: string, ext: string) =>
  new File(new Directory(Paths.document, COVERS), `${bookId}.${ext.replace(/^\./, "")}`);

export function ensureDir(dir: Directory): Directory {
  dir.create({ intermediates: true, idempotent: true });
  return dir;
}

/** How many chunk files a chapter has, counted from 0 with no gaps. */
export function contiguousChunkCount(chapterId: string): number {
  const dir = chunkDir(chapterId);
  if (!dir.exists) return 0;

  const present = new Set<string>();
  for (const entry of dir.list()) {
    if (entry instanceof File && entry.name.endsWith(".wav")) present.add(entry.name);
  }

  let count = 0;
  // A torn write leaves a gap, and audio past it cannot be attributed to a
  // chunk, so the run stops at the first missing index.
  while (present.has(`${String(count).padStart(5, "0")}.wav`)) count++;
  return count;
}

export function deleteChapterAudio(chapterId: string): void {
  const dir = chapterDir(chapterId);
  if (dir.exists) dir.delete();
}

export function deleteChunks(chapterId: string): void {
  const dir = chunkDir(chapterId);
  if (dir.exists) dir.delete();
}

/** Bytes a chapter's audio occupies, for the per-book storage readout. */
export function chapterBytes(chapterId: string): number {
  const dir = chapterDir(chapterId);
  if (!dir.exists) return 0;

  let total = 0;
  const walk = (directory: Directory) => {
    for (const entry of directory.list()) {
      if (entry instanceof File) total += entry.size ?? 0;
      else walk(entry);
    }
  };
  walk(dir);
  return total;
}
