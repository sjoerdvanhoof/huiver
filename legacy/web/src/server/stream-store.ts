/**
 * Audio kept from live playback.
 *
 * Streaming a chapter renders it chunk by chunk and throws the audio away as
 * soon as it has been played. Here it is written to a WAV as it goes, with the
 * same guarantees a conversion checkpoint gets (see ./checkpoint): the row says
 * how many chunks the file holds and how many bytes of audio that is, so an
 * interrupted stream can be picked up from what is already on disk.
 *
 * Playing a chapter again therefore replays the stored audio straight from the
 * file — no model load, no synthesis — and only renders what is missing. A
 * chapter streamed all the way to the end becomes a normal finished track.
 */
import { mkdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { planResume } from "@huiver/shared";
import { DATA_DIR, db, type StreamPartialRow } from "./db";
import { appendPcm16ToWav, readWavLayout, syncWav, truncateWavData, wavDurationSec } from "./wav";

export const STREAM_DIR = path.join(DATA_DIR, "streams");

/**
 * One writer per stored stream. A second listener on the same chapter replays
 * what is stored and then renders its own tail, rather than two of them
 * appending to one file.
 */
const claimed = new Set<string>();

/**
 * Rows are keyed by chapter as well as by work: two chapters with identical text
 * — the same book imported twice, say — describe the same render but must not
 * share one file, or deleting either book would take the other's audio.
 */
const storageKey = (chapterId: string, key: string): string => `${chapterId}|${key}`;

const fileFor = (chapterId: string, key: string): string =>
  path.join(STREAM_DIR, `${chapterId}-${Bun.hash(key).toString(36)}.wav`);

const rowFor = (stored: string): StreamPartialRow | null =>
  db.query("SELECT * FROM stream_partials WHERE key = ?").get(stored) as StreamPartialRow | null;

async function forget(stored: string): Promise<void> {
  const row = rowFor(stored);
  db.query("DELETE FROM stream_partials WHERE key = ?").run(stored);
  if (row) await rm(row.path, { force: true }).catch(() => {});
}

/** Forget stored audio, row and file both. */
export const forgetStoredStream = (chapterId: string, key: string): Promise<void> =>
  forget(storageKey(chapterId, key));

export type StoredStream = {
  path: string;
  /** Byte offset of the PCM inside the file. */
  dataOffset: number;
  /** Bytes of PCM that are known-good. */
  dataBytes: number;
  sampleRate: number;
  /** Chunks the file holds, so synthesis knows where to carry on. */
  chunksDone: number;
  durationSec: number;
};

/**
 * What is on disk for this exact work, verified against the file. Audio past the
 * last recorded chunk is cut off, since there is no telling which chunk an
 * interrupted write got to.
 */
export async function lookupStoredStream(
  chapterId: string,
  key: string,
  totalChunks: number,
): Promise<StoredStream | null> {
  const stored = storageKey(chapterId, key);
  const row = rowFor(stored);
  if (!row) return null;

  const layout = await readWavLayout(row.path);
  const plan = planResume({
    saved: { resume_chunks: row.chunks_done, resume_bytes: row.bytes, resume_key: key },
    key,
    totalChunks,
    dataBytes: layout?.dataBytes ?? null,
  });

  if (!plan || !layout) {
    await forget(stored);
    return null;
  }

  await truncateWavData(row.path, plan.dataBytes);
  return {
    path: row.path,
    dataOffset: layout.dataOffset,
    dataBytes: plan.dataBytes,
    sampleRate: layout.sampleRate,
    chunksDone: plan.startChunk,
    durationSec: plan.dataBytes / 2 / layout.sampleRate,
  };
}

export type StreamWriter = {
  /** Store one rendered chunk. `chunkIndex` is its place in the whole chapter. */
  append: (pcm: Uint8Array, chunkIndex: number) => Promise<void>;
  /**
   * The chapter rendered all the way through. Returns the finished audio, or
   * null if there is nothing usable on disk.
   */
  complete: () => Promise<{ path: string; durationSec: number } | null>;
  /** Hand the stored stream back, so another listener can extend it. */
  release: () => void;
};

/**
 * Start storing a stream. Returns null when another request is already writing
 * this one — that listener still gets audio, it just doesn't get to keep it.
 *
 * `from` is the chunk synthesis will start at: 0 means the file is being built
 * from scratch and anything already there is replaced.
 */
export async function openStreamWriter(args: {
  key: string;
  chapterId: string;
  totalChunks: number;
  sampleRate: number;
  from: number;
}): Promise<StreamWriter | null> {
  const { key, chapterId, totalChunks, sampleRate, from } = args;
  const stored = storageKey(chapterId, key);
  if (claimed.has(stored)) return null;
  claimed.add(stored);

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    claimed.delete(stored);
  };

  try {
    const filePath = fileFor(chapterId, key);
    await mkdir(STREAM_DIR, { recursive: true });
    if (from === 0) await rm(filePath, { force: true });

    db.query(
      `INSERT INTO stream_partials (key, chapter_id, path, chunks_done, chunks_total, bytes, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET
         path = excluded.path,
         chunks_total = excluded.chunks_total,
         updated_at = excluded.updated_at`,
    ).run(stored, chapterId, filePath, from, totalChunks, 0, Date.now());

    // Starting over: the row's old progress describes a file that is now gone.
    if (from === 0) {
      db.query("UPDATE stream_partials SET chunks_done = 0, bytes = 0 WHERE key = ?").run(stored);
    }

    const record = (chunksDone: number, bytes: number) =>
      db
        .query("UPDATE stream_partials SET chunks_done = ?, bytes = ?, updated_at = ? WHERE key = ?")
        .run(chunksDone, bytes, Date.now(), stored);

    return {
      async append(pcm, chunkIndex) {
        await appendPcm16ToWav(filePath, [pcm as Uint8Array<ArrayBuffer>], sampleRate);
        await syncWav(filePath);
        const layout = await readWavLayout(filePath);
        record(chunkIndex + 1, layout?.dataBytes ?? 0);
      },

      async complete() {
        const layout = await readWavLayout(filePath);
        if (!layout || layout.dataBytes === 0) return null;
        // A chunk can render silence and never call append, so trust the fact
        // that synthesis ran to the end over the count of stored chunks.
        record(totalChunks, layout.dataBytes);
        return { path: filePath, durationSec: wavDurationSec(layout) };
      },

      release,
    };
  } catch (error) {
    release();
    throw error;
  }
}

/** Stored streams for a book, so deleting it takes the audio with it. */
export function storedStreamPathsForBook(bookId: string): string[] {
  return (
    db
      .query(
        `SELECT s.path AS path FROM stream_partials s
         JOIN chapters c ON c.id = s.chapter_id
         WHERE c.book_id = ?`,
      )
      .all(bookId) as { path: string }[]
  ).map(row => row.path);
}

/** Drop stored streams nobody has played for a while. */
export async function sweepStoredStreams(cutoffMs: number): Promise<number> {
  const rows = db.query("SELECT key, path FROM stream_partials").all() as { key: string; path: string }[];
  let swept = 0;

  for (const row of rows) {
    if (claimed.has(row.key)) continue;
    const info = await stat(row.path).catch(() => null);
    if (info && info.mtimeMs > cutoffMs) continue;
    await forget(row.key);
    swept++;
  }

  return swept;
}
