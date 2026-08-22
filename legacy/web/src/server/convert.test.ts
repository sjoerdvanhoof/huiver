import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

// The db module opens its singleton at import time; point it at a throwaway
// directory before anything pulls it in. `??=` keeps whichever test file ran
// first authoritative, so every file shares one temp dir.
process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));
// Small batches so a 12-chunk chapter checkpoints four times.
process.env.HUIVER_CHECKPOINT_CHUNKS = "3";

const { chunkText, resumeKey } = await import("@huiver/shared");
const { cancelJobTracks, enqueueJob, sweepStalePartials } = await import("./convert");
const { AUDIO_DIR, db, newId } = await import("./db");
type TrackRow = import("./db").TrackRow;
const { PROVIDERS } = await import("./tts");
const { pcmFromWav } = await import("@huiver/shared");
const { appendPcm16ToWav, writeWavFromPcm16 } = await import("./wav");

const SAMPLE_RATE = 24000;
const PARTS = 12;

/**
 * One paragraph per chunk, each announcing its own number, so the finished
 * audio spells out exactly which chunks went into it and in what order.
 */
const CHAPTER_TEXT = Array.from(
  { length: PARTS },
  (_, i) => `Part ${i}. ${"the quick brown fox jumps over the lazy dog. ".repeat(6)}`,
).join("\n\n");

const CHUNKS = chunkText(CHAPTER_TEXT);

/** Each chunk renders to a single sample carrying its number. */
function sampleFor(text: string): Uint8Array<ArrayBuffer> {
  const part = text.match(/^Part (\d+)\./);
  if (!part) throw new Error(`unexpected chunk: ${text.slice(0, 40)}`);
  const bytes = new Uint8Array(2);
  new DataView(bytes.buffer).setInt16(0, Number(part[1]) + 1, true);
  return bytes;
}

const fake = {
  calls: [] as { chunks: string[]; append: boolean }[],
  /** Chunk text that makes the provider blow up, once. */
  failAt: null as string | null,
  /** Runs as each batch starts, so a test can interfere mid-chapter. */
  beforeBatch: null as ((chunks: string[]) => void) | null,
  opens: 0,
};

PROVIDERS.fake = {
  async info() {
    return {
      id: "fake",
      label: "Fake",
      local: true,
      available: true,
      voices: [{ id: "v1", label: "One" }],
      defaultVoice: "v1",
      supportsSpeed: true,
    };
  },

  async open() {
    fake.opens++;
    return {
      sampleRate: SAMPLE_RATE,

      async synthesize(req) {
        fake.calls.push({ chunks: req.chunks, append: Boolean(req.append) });
        fake.beforeBatch?.(req.chunks);
        const parts: Uint8Array<ArrayBuffer>[] = [];

        for (const [index, text] of req.chunks.entries()) {
          if (text === fake.failAt) {
            fake.failAt = null; // the next attempt gets through
            // Like a provider that dies partway: what it already rendered is
            // on disk, past the last checkpoint.
            if (parts.length > 0) await appendPcm16ToWav(req.outWav, parts, SAMPLE_RATE);
            throw new Error("fake provider blew up");
          }
          parts.push(sampleFor(text));
          req.onChunk?.(index + 1, req.chunks.length);
        }

        return req.append
          ? appendPcm16ToWav(req.outWav, parts, SAMPLE_RATE)
          : writeWavFromPcm16(req.outWav, parts, SAMPLE_RATE);
      },

      async stream() {
        throw new Error("the fake provider does not stream");
      },

      async close() {},
    };
  },
};

/** A queued one-chapter job. Pass an existing book/chapter to convert it again. */
function seedJob(existing?: { book: string; chapter: string }) {
  const ids = {
    book: existing?.book ?? newId("bk"),
    chapter: existing?.chapter ?? newId("ch"),
    job: newId("job"),
    track: newId("tr"),
  };

  db.transaction(() => {
    if (!existing) {
      db.query(
        "INSERT INTO books (id, title, author, format, source_path, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      ).run(ids.book, "Test Book", "Nobody", "epub", "/x/test.epub", Date.now());
      db.query(
        "INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, 0, ?, ?, ?)",
      ).run(ids.chapter, ids.book, "Chapter One", CHAPTER_TEXT, CHAPTER_TEXT.length);
    }
    db.query(
      "INSERT INTO jobs (id, book_id, provider, voice, speed, status, created_at) VALUES (?, ?, 'fake', 'v1', 1, 'queued', ?)",
    ).run(ids.job, ids.book, Date.now());
    db.query(
      "INSERT INTO tracks (id, job_id, chapter_id, idx, title, status) VALUES (?, ?, ?, 0, 'Chapter One', 'pending')",
    ).run(ids.track, ids.job, ids.chapter);
  })();

  return { ...ids, partPath: path.join(AUDIO_DIR, ids.job, "001-chapter-one.part.wav") };
}

/** Stop a run the way the cancel route does. */
function stopJob(jobId: string) {
  db.query("UPDATE jobs SET status = 'cancelled', finished_at = ? WHERE id = ?").run(Date.now(), jobId);
  cancelJobTracks(jobId);
}

async function runToFinish(jobId: string): Promise<string> {
  enqueueJob(jobId);

  for (let tries = 0; tries < 500; tries++) {
    const row = db.query("SELECT status FROM jobs WHERE id = ?").get(jobId) as { status: string };
    if (row.status !== "queued" && row.status !== "running") return row.status;
    await Bun.sleep(10);
  }
  throw new Error("job never finished");
}

const trackRow = (id: string) => db.query("SELECT * FROM tracks WHERE id = ?").get(id) as TrackRow;

/** The chunk numbers the finished audio actually contains, in order. */
async function partsIn(filePath: string): Promise<number[]> {
  const { pcm } = pcmFromWav(new Uint8Array(await Bun.file(filePath).arrayBuffer()));
  const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  return Array.from({ length: pcm.byteLength / 2 }, (_, i) => view.getInt16(i * 2, true));
}

const batches = () => fake.calls.map(call => call.chunks.map(text => Number(text.match(/^Part (\d+)\./)![1])));

/** Write a partial file and the checkpoint that describes it, as a crash would leave them. */
async function seedCheckpoint(
  ids: { job: string; track: string; partPath: string },
  chunksDone: number,
  samples: number[] = Array.from({ length: chunksDone }, (_, i) => i + 1),
  key = resumeKey({ provider: "fake", voice: "v1", speed: 1 }, CHUNKS),
) {
  const pcm = new Uint8Array(samples.length * 2);
  const view = new DataView(pcm.buffer);
  samples.forEach((value, index) => view.setInt16(index * 2, value, true));
  await writeWavFromPcm16(ids.partPath, [pcm], SAMPLE_RATE);

  db.query(
    `UPDATE tracks SET resume_chunks = ?, resume_bytes = ?, resume_key = ?, resume_path = ?, chunks_done = ?
     WHERE id = ?`,
  ).run(chunksDone, chunksDone * 2, key, ids.partPath, chunksDone, ids.track);
}

beforeAll(() => {
  // Keep ffmpeg out of reach so tracks finish as WAV and the test can read the
  // samples back. Conversion already falls back to the WAV without an encoder.
  process.env.HUIVER_FFMPEG = path.join(tmpdir(), "huiver-no-such-ffmpeg");
});

afterAll(() => {
  delete process.env.HUIVER_FFMPEG;
  delete process.env.HUIVER_TRACK_ATTEMPTS;
});

beforeEach(() => {
  fake.calls = [];
  fake.failAt = null;
  fake.beforeBatch = null;
  fake.opens = 0;
});

test("the fixture chunks one paragraph at a time", () => {
  expect(CHUNKS).toHaveLength(PARTS);
});

describe("conversion checkpoints", () => {
  test("renders a chapter in batches and clears the checkpoint when it finishes", async () => {
    const ids = seedJob();

    expect(await runToFinish(ids.job)).toBe("done");

    expect(batches()).toEqual([[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]]);
    expect(fake.calls.map(call => call.append)).toEqual([false, true, true, true]);

    const track = trackRow(ids.track);
    expect(track.status).toBe("done");
    expect(await partsIn(track.path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    expect(track.duration).toBeCloseTo(PARTS / SAMPLE_RATE, 10);
    expect(track.chunks_done).toBe(PARTS);

    // Nothing left pointing at a partial.
    expect(track.resume_chunks).toBe(0);
    expect(track.resume_bytes).toBe(0);
    expect(track.resume_key).toBeNull();
    expect(track.resume_path).toBeNull();
    expect(await Bun.file(ids.partPath).exists()).toBe(false);

    const job = db.query("SELECT chunks_done, chunks_total FROM jobs WHERE id = ?").get(ids.job);
    expect(job).toEqual({ chunks_done: PARTS, chunks_total: PARTS });
  });

  test("retries from the last checkpoint instead of restarting the chapter", async () => {
    const ids = seedJob();
    fake.failAt = CHUNKS[7]!; // mid-batch, after chunk 6 has been written

    expect(await runToFinish(ids.job)).toBe("done");

    // The failed batch is re-rendered whole; the two before it are not.
    expect(batches()).toEqual([[0, 1, 2], [3, 4, 5], [6, 7, 8], [6, 7, 8], [9, 10, 11]]);
    expect(fake.opens).toBe(2); // a fresh session for the retry

    const track = trackRow(ids.track);
    expect(track.status).toBe("done");
    // Chunk 6's orphaned sample was dropped, not left in the middle of the audio.
    expect(await partsIn(track.path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("resumes a chapter that was interrupted mid-render", async () => {
    const ids = seedJob();
    await seedCheckpoint(ids, 6);

    expect(await runToFinish(ids.job)).toBe("done");

    expect(batches()).toEqual([[6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(ids.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("drops audio the interrupted batch left past the checkpoint", async () => {
    const ids = seedJob();
    // Six checkpointed chunks, plus two samples that belong to nothing.
    await seedCheckpoint(ids, 6, [1, 2, 3, 4, 5, 6, 999, 998]);

    expect(await runToFinish(ids.job)).toBe("done");

    expect(batches()).toEqual([[6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(ids.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("starts over when the partial was rendered for different work", async () => {
    const ids = seedJob();
    await seedCheckpoint(ids, 6, undefined, resumeKey({ provider: "fake", voice: "other", speed: 1 }, CHUNKS));

    expect(await runToFinish(ids.job)).toBe("done");

    expect(batches()).toEqual([[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(ids.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("starts over when the checkpointed audio is missing from disk", async () => {
    const ids = seedJob();
    await seedCheckpoint(ids, 6);
    await Bun.file(ids.partPath).delete();

    expect(await runToFinish(ids.job)).toBe("done");

    expect(batches()).toEqual([[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(ids.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("keeps a stopped chapter's audio and continues it in the next conversion", async () => {
    const first = seedJob();
    // Stop the run as the third batch starts: two checkpoints are on disk, and
    // the batch that is running will write audio past the second one.
    fake.beforeBatch = chunks => {
      if (chunks[0] === CHUNKS[6]) stopJob(first.job);
    };

    expect(await runToFinish(first.job)).toBe("cancelled");

    const stopped = trackRow(first.track);
    expect(stopped.status).toBe("cancelled");
    expect(stopped.resume_chunks).toBe(6);
    expect(stopped.chunks_done).toBe(6); // what is actually kept, not what was rendered
    expect(await Bun.file(first.partPath).exists()).toBe(true);

    // Convert the same chapter again: a new job, with a new track row.
    fake.calls = [];
    const second = seedJob(first);

    expect(await runToFinish(second.job)).toBe("done");

    expect(batches()).toEqual([[6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(second.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);

    // The partial moved to the new job, rather than being left behind twice.
    const donor = trackRow(first.track);
    expect(donor.resume_chunks).toBe(0);
    expect(donor.resume_path).toBeNull();
    expect(await Bun.file(first.partPath).exists()).toBe(false);
    expect(await Bun.file(second.partPath).exists()).toBe(false);
  });

  test("does not adopt a partial rendered at another voice", async () => {
    const first = seedJob();
    await seedCheckpoint(first, 6, undefined, resumeKey({ provider: "fake", voice: "other", speed: 1 }, CHUNKS));
    db.query("UPDATE tracks SET status = 'cancelled' WHERE id = ?").run(first.track);

    const second = seedJob(first);
    expect(await runToFinish(second.job)).toBe("done");

    expect(batches()).toEqual([[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]]);
    expect(await partsIn(trackRow(second.track).path!)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("clears partials of the same work once a chapter is rendered", async () => {
    const first = seedJob();
    await seedCheckpoint(first, 3);
    db.query("UPDATE tracks SET status = 'cancelled' WHERE id = ?").run(first.track);

    // A second stopped attempt got further, so that is the one worth adopting.
    const second = seedJob(first);
    await seedCheckpoint(second, 6);
    db.query("UPDATE tracks SET status = 'cancelled' WHERE id = ?").run(second.track);

    const third = seedJob(first);
    expect(await runToFinish(third.job)).toBe("done");

    expect(batches()).toEqual([[6, 7, 8], [9, 10, 11]]);
    expect(trackRow(first.track).resume_chunks).toBe(0);
    expect(await Bun.file(first.partPath).exists()).toBe(false);
    expect(await Bun.file(second.partPath).exists()).toBe(false);
  });

  test("sweeps parked partials that nobody came back for", async () => {
    const stale = seedJob();
    await seedCheckpoint(stale, 6);
    const longAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    await utimes(stale.partPath, longAgo, longAgo);

    const fresh = seedJob();
    await seedCheckpoint(fresh, 6);

    await sweepStalePartials();

    expect(await Bun.file(stale.partPath).exists()).toBe(false);
    expect(trackRow(stale.track).resume_chunks).toBe(0);
    expect(trackRow(stale.track).resume_path).toBeNull();

    expect(await Bun.file(fresh.partPath).exists()).toBe(true);
    expect(trackRow(fresh.track).resume_chunks).toBe(6);
  });

  test("gives up after the last attempt but keeps what it rendered", async () => {
    process.env.HUIVER_TRACK_ATTEMPTS = "1";
    try {
      const ids = seedJob();
      fake.failAt = CHUNKS[4]!;

      expect(await runToFinish(ids.job)).toBe("error");

      const track = trackRow(ids.track);
      expect(track.status).toBe("error");
      expect(track.error).toContain("fake provider blew up");
      // The three chunks it did get through are still there to build on.
      expect(track.resume_chunks).toBe(3);
      expect(await Bun.file(ids.partPath).exists()).toBe(true);
    } finally {
      delete process.env.HUIVER_TRACK_ATTEMPTS;
    }
  });
});
