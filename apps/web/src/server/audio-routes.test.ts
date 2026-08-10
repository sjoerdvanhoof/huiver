import { beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { streamChapter } = await import("./audio-routes");
const { chunkTextWithSentenceLead, resumeKey } = await import("@huiver/shared");
const { db, newId } = await import("./db");
const { lookupStoredStream, openStreamWriter } = await import("./stream-store");
const { PROVIDERS } = await import("./tts");
const { readWavLayout } = await import("./wav");

type TrackRow = import("./db").TrackRow;

const SAMPLE_RATE = 24000;
/** Half a second of audio per chunk, so byte offsets and durations are real. */
const SAMPLES_PER_CHUNK = SAMPLE_RATE / 2;

/**
 * Streaming needs a real ffmpeg to encode the MP3 the browser plays. Without one
 * there is nothing to assert, so these skip rather than fail.
 */
const hasFfmpeg = Boolean(Bun.which("ffmpeg"));

const CHAPTER_TEXT = Array.from(
  { length: 6 },
  (_, i) => `Part ${i}. ${"the quick brown fox jumps over the lazy dog. ".repeat(6)}`,
).join("\n\n");

const CHUNKS = chunkTextWithSentenceLead(CHAPTER_TEXT);

/** Each chunk renders as a block of one repeated sample: its own number. */
function pcmFor(text: string): Uint8Array {
  const part = text.match(/^Part (\d+)\./);
  const value = part ? Number(part[1]) + 1 : 99;
  const bytes = new Uint8Array(SAMPLES_PER_CHUNK * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < SAMPLES_PER_CHUNK; i++) view.setInt16(i * 2, value, true);
  return bytes;
}

const fake = {
  streamed: [] as string[][],
  opens: 0,
  /** Runs after each chunk is handed over, so a test can cut the stream off. */
  afterChunk: null as ((index: number) => void) | null,
};

PROVIDERS.fakestream = {
  async info() {
    return {
      id: "fakestream",
      label: "Fake stream",
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

      async synthesize() {
        throw new Error("the fake stream provider only streams");
      },

      async stream(req) {
        fake.streamed.push(req.chunks);
        for (const [index, text] of req.chunks.entries()) {
          if (req.signal?.aborted) return;
          await req.onAudio(pcmFor(text), index);
          fake.afterChunk?.(index);
        }
      },

      async close() {},
    };
  },
};

function seedChapter() {
  const book = newId("bk");
  const chapter = newId("ch");
  db.transaction(() => {
    db.query(
      "INSERT INTO books (id, title, author, format, source_path, created_at) VALUES (?, 'Stream Book', 'Nobody', 'epub', '/x', ?)",
    ).run(book, Date.now());
    db.query(
      "INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, 0, 'Chapter One', ?, ?)",
    ).run(chapter, book, CHAPTER_TEXT, CHAPTER_TEXT.length);
  })();
  return { book, chapter };
}

const streamUrl = (chapterId: string, params: Record<string, string> = {}) =>
  `http://localhost/api/chapters/${chapterId}/stream?${new URLSearchParams({
    provider: "fakestream",
    voice: "v1",
    speed: "1",
    ...params,
  })}`;

/** Play a chapter to the end and return the response plus the bytes it produced. */
async function play(chapterId: string, params: Record<string, string> = {}) {
  const response = await streamChapter(new Request(streamUrl(chapterId, params)), chapterId);
  const bytes = response.body ? (await new Response(response.body).arrayBuffer()).byteLength : 0;
  return { response, bytes };
}

/** Play, then cut the connection right after `stopAfter` chunks have arrived. */
async function playAndInterrupt(chapterId: string, stopAfter: number) {
  const controller = new AbortController();
  fake.afterChunk = index => {
    if (index === stopAfter - 1) controller.abort();
  };

  const request = new Request(streamUrl(chapterId), { signal: controller.signal });
  const response = await streamChapter(request, chapterId);
  await new Response(response.body!).arrayBuffer().catch(() => undefined);
  fake.afterChunk = null;
  // The store is written after the encoder, so let the last write land.
  await Bun.sleep(50);
  return response;
}

const chapterTrack = (chapterId: string) =>
  db.query("SELECT * FROM tracks WHERE chapter_id = ? AND status = 'done'").get(chapterId) as TrackRow | null;

const storedFor = (chapterId: string) =>
  lookupStoredStream(chapterId, resumeKey({ provider: "fakestream", voice: "v1", speed: 1 }, CHUNKS), CHUNKS.length);

const parts = (calls: string[][]) =>
  calls.map(chunks => chunks.map(text => Number(text.match(/^Part (\d+)\./)?.[1] ?? -1)));

beforeEach(() => {
  fake.streamed = [];
  fake.opens = 0;
  fake.afterChunk = null;
});

test("the fixture splits the opening sentence off for a fast first chunk", () => {
  expect(CHUNKS.length).toBe(7);
});

describe.skipIf(!hasFfmpeg)("streaming keeps what it renders", () => {
  test("a chapter played to the end is kept as a finished track", async () => {
    const ids = seedChapter();

    const { response, bytes } = await play(ids.chapter);

    expect(response.headers.get("Content-Type")).toBe("audio/mpeg");
    expect(response.headers.get("X-Stored-Seconds")).toBe("0"); // nothing to replay yet
    expect(bytes).toBeGreaterThan(1000);
    expect(fake.streamed).toHaveLength(1);
    expect(fake.streamed[0]).toHaveLength(CHUNKS.length);

    const track = chapterTrack(ids.chapter)!;
    expect(track.status).toBe("done");
    expect(track.duration).toBeCloseTo(CHUNKS.length / 2, 3);
    expect(await Bun.file(track.path!).exists()).toBe(true);

    // The audio moved into the track, so there is nothing left to replay.
    expect(await storedFor(ids.chapter)).toBeNull();
  });

  test("an interrupted chapter keeps the audio it got through", async () => {
    const ids = seedChapter();

    await playAndInterrupt(ids.chapter, 3);

    const stored = (await storedFor(ids.chapter))!;
    expect(stored.chunksDone).toBe(3);
    expect(stored.durationSec).toBeCloseTo(1.5, 3);
    expect((await readWavLayout(stored.path))!.dataBytes).toBe(3 * SAMPLES_PER_CHUNK * 2);
    // Nothing is registered as playable until the whole chapter is there.
    expect(chapterTrack(ids.chapter)).toBeNull();
  });

  test("playing again replays the stored audio and renders only the rest", async () => {
    const ids = seedChapter();
    await playAndInterrupt(ids.chapter, 3);
    fake.streamed = [];

    const { response } = await play(ids.chapter);

    expect(Number(response.headers.get("X-Stored-Seconds"))).toBeCloseTo(1.5, 3);
    expect(response.headers.get("X-Stream-Start")).toBe("0");
    // Chunks 0-2 came off the disk; only the tail was synthesized.
    expect(parts(fake.streamed)).toEqual([[2, 3, 4, 5]]);

    const track = chapterTrack(ids.chapter)!;
    expect(track.duration).toBeCloseTo(CHUNKS.length / 2, 3);
  });

  test("resuming mid-chapter starts at the exact second asked for", async () => {
    const ids = seedChapter();
    await playAndInterrupt(ids.chapter, 4); // 2.0s stored
    fake.streamed = [];

    const { response } = await play(ids.chapter, { start: "1" });

    expect(response.headers.get("X-Stream-Start")).toBe("1");
    expect(Number(response.headers.get("X-Stored-Seconds"))).toBeCloseTo(1, 3);
    expect(parts(fake.streamed)).toEqual([[3, 4, 5]]);
  });

  test("a fully stored chapter plays back without starting the engine", async () => {
    const ids = seedChapter();
    // Give the chapter audio first, so the finished stream stays a stored stream
    // instead of being handed over as a track.
    db.query(
      "INSERT INTO jobs (id, book_id, provider, voice, speed, status, created_at) VALUES (?, ?, 'fakestream', 'v1', 1, 'done', ?)",
    ).run("job_pre", ids.book, Date.now());
    db.query(
      "INSERT INTO tracks (id, job_id, chapter_id, idx, title, status, path, duration) VALUES (?, 'job_pre', ?, 0, 'Chapter One', 'done', '/x/pre.mp3', 3.5)",
    ).run(newId("tr"), ids.chapter);

    await play(ids.chapter);
    expect((await storedFor(ids.chapter))!.chunksDone).toBe(CHUNKS.length);

    fake.streamed = [];
    fake.opens = 0;
    const { response, bytes } = await play(ids.chapter);

    expect(fake.streamed).toEqual([]); // no synthesis at all
    expect(fake.opens).toBe(0); // and no model loaded
    expect(Number(response.headers.get("X-Stored-Seconds"))).toBeCloseTo(CHUNKS.length / 2, 3);
    expect(bytes).toBeGreaterThan(1000);
  });

  test("audio cut off at the very end is kept the next time it plays", async () => {
    const ids = seedChapter();
    // Every chunk rendered, but the listen ended before it could be handed over.
    const writer = (await openStreamWriter({
      key: resumeKey({ provider: "fakestream", voice: "v1", speed: 1 }, CHUNKS),
      chapterId: ids.chapter,
      totalChunks: CHUNKS.length,
      sampleRate: SAMPLE_RATE,
      from: 0,
    }))!;
    for (const [index, text] of CHUNKS.entries()) await writer.append(pcmFor(text), index);
    writer.release();
    expect(chapterTrack(ids.chapter)).toBeNull();

    const { response } = await play(ids.chapter);

    expect(fake.streamed).toEqual([]); // nothing left to render
    expect(Number(response.headers.get("X-Stored-Seconds"))).toBeCloseTo(CHUNKS.length / 2, 3);

    const track = chapterTrack(ids.chapter)!;
    expect(track.duration).toBeCloseTo(CHUNKS.length / 2, 3);
    expect(await storedFor(ids.chapter)).toBeNull();
  });

  test("seeking past the stored audio is played but not kept", async () => {
    const ids = seedChapter();
    await playAndInterrupt(ids.chapter, 2);
    const before = (await storedFor(ids.chapter))!;
    fake.streamed = [];

    // Far beyond the 1s that is stored, so there is nothing to continue from.
    await play(ids.chapter, { start: "60" });

    const after = (await storedFor(ids.chapter))!;
    expect(after.chunksDone).toBe(before.chunksDone);
    expect(after.dataBytes).toBe(before.dataBytes);
    expect(fake.streamed).toHaveLength(1);
    expect(fake.streamed[0]!.length).toBeLessThan(CHUNKS.length);
  });
});
