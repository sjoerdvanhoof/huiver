import { beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { appendFile, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { resumeKey } = await import("@huiver/shared");
const { db, newId } = await import("./db");
const {
  forgetStoredStream,
  lookupStoredStream,
  openStreamWriter,
  storedStreamPathsForBook,
  sweepStoredStreams,
} = await import("./stream-store");
const { pcmFromWav } = await import("@huiver/shared");

const SAMPLE_RATE = 24000;
const TOTAL = 4;

/** 40 samples of a single value, so a stored file says which chunks it holds. */
function pcmFor(value: number): Uint8Array {
  const bytes = new Uint8Array(40 * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < 40; i++) view.setInt16(i * 2, value, true);
  return bytes;
}

/** The chunk values a stored file contains, in order, one entry per run. */
async function runsIn(filePath: string): Promise<number[]> {
  const { pcm } = pcmFromWav(new Uint8Array(await Bun.file(filePath).arrayBuffer()));
  const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  const runs: number[] = [];
  for (let i = 0; i < pcm.byteLength / 2; i++) {
    const value = view.getInt16(i * 2, true);
    if (runs.at(-1) !== value) runs.push(value);
  }
  return runs;
}

function seedChapter() {
  const book = newId("bk");
  const chapter = newId("ch");
  db.transaction(() => {
    db.query(
      "INSERT INTO books (id, title, format, source_path, created_at) VALUES (?, 'Stream Book', 'epub', '/x', ?)",
    ).run(book, Date.now());
    db.query(
      "INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, 0, 'One', 'Text.', 5)",
    ).run(chapter, book);
  })();
  return { book, chapter };
}

let ids: { book: string; chapter: string };
let key: string;

beforeEach(() => {
  ids = seedChapter();
  key = resumeKey({ provider: "fake", voice: "v1", speed: 1 }, ["a", "b", "c", "d"]);
});

const open = (from = 0) =>
  openStreamWriter({ key, chapterId: ids.chapter, totalChunks: TOTAL, sampleRate: SAMPLE_RATE, from });

describe("stored streams", () => {
  test("nothing is stored until a stream writes something", async () => {
    expect(await lookupStoredStream(ids.chapter, key, TOTAL)).toBeNull();

    const writer = (await open())!;
    expect(await lookupStoredStream(ids.chapter, key, TOTAL)).toBeNull(); // an empty file is not worth resuming
    writer.release();
  });

  test("what a stream stored is what a later one can pick up", async () => {
    const writer = (await open())!;
    await writer.append(pcmFor(1), 0);
    await writer.append(pcmFor(2), 1);
    writer.release();

    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    expect(stored.chunksDone).toBe(2);
    expect(stored.dataBytes).toBe(2 * 80);
    expect(stored.sampleRate).toBe(SAMPLE_RATE);
    expect(stored.durationSec).toBeCloseTo(80 / SAMPLE_RATE, 10);
    expect(await runsIn(stored.path)).toEqual([1, 2]);
  });

  test("only one stream extends a stored file at a time", async () => {
    const first = (await open())!;
    expect(await open()).toBeNull();

    first.release();
    const second = await open(1);
    expect(second).not.toBeNull();
    second!.release();
  });

  test("starting from the top replaces whatever was there", async () => {
    const first = (await open())!;
    await first.append(pcmFor(1), 0);
    await first.append(pcmFor(2), 1);
    first.release();

    const second = (await open(0))!;
    await second.append(pcmFor(9), 0);
    second.release();

    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    expect(stored.chunksDone).toBe(1);
    expect(await runsIn(stored.path)).toEqual([9]);
  });

  test("drops audio an interrupted write left past the last chunk", async () => {
    const writer = (await open())!;
    await writer.append(pcmFor(1), 0);
    await writer.append(pcmFor(2), 1);
    writer.release();

    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    await appendFile(stored.path, pcmFor(99)); // never recorded, so unattributable

    const reread = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    expect(reread.chunksDone).toBe(2);
    expect(await runsIn(reread.path)).toEqual([1, 2]);
  });

  test("forgets a stored stream whose file has gone", async () => {
    const writer = (await open())!;
    await writer.append(pcmFor(1), 0);
    writer.release();

    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    await Bun.file(stored.path).delete();

    expect(await lookupStoredStream(ids.chapter, key, TOTAL)).toBeNull();
    expect(db.query("SELECT COUNT(*) AS n FROM stream_partials WHERE key = ?").get(key)).toEqual({ n: 0 });
  });

  test("a chapter streamed to the end reports the whole file", async () => {
    const writer = (await open())!;
    for (let i = 0; i < TOTAL; i++) await writer.append(pcmFor(i + 1), i);
    const finished = await writer.complete();
    writer.release();

    expect(finished?.durationSec).toBeCloseTo((TOTAL * 40) / SAMPLE_RATE, 10);
    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    expect(stored.chunksDone).toBe(TOTAL);
    expect(await runsIn(stored.path)).toEqual([1, 2, 3, 4]);
  });

  test("lists its files per book, so deleting one cleans them up", async () => {
    const writer = (await open())!;
    await writer.append(pcmFor(1), 0);
    writer.release();

    const stored = (await lookupStoredStream(ids.chapter, key, TOTAL))!;
    expect(storedStreamPathsForBook(ids.book)).toEqual([stored.path]);
    expect(storedStreamPathsForBook(newId("bk"))).toEqual([]);
  });

  test("sweeps audio nobody has played for a while", async () => {
    db.query("DELETE FROM stream_partials").run(); // count only what this test stores

    const writer = (await open())!;
    await writer.append(pcmFor(1), 0);
    writer.release();
    const stale = (await lookupStoredStream(ids.chapter, key, TOTAL))!;

    const otherIds = seedChapter();
    const otherKey = resumeKey({ provider: "fake", voice: "v2", speed: 1 }, ["a", "b", "c", "d"]);
    const other = (await openStreamWriter({
      key: otherKey,
      chapterId: otherIds.chapter,
      totalChunks: TOTAL,
      sampleRate: SAMPLE_RATE,
      from: 0,
    }))!;
    await other.append(pcmFor(1), 0);
    other.release();

    const longAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    await utimes(stale.path, longAgo, longAgo);

    expect(await sweepStoredStreams(Date.now() - 14 * 24 * 60 * 60 * 1000)).toBe(1);
    expect(await Bun.file(stale.path).exists()).toBe(false);
    expect(await lookupStoredStream(ids.chapter, key, TOTAL)).toBeNull();
    expect(await lookupStoredStream(otherIds.chapter, otherKey, TOTAL)).not.toBeNull();

    await forgetStoredStream(otherIds.chapter, otherKey);
  });
});
