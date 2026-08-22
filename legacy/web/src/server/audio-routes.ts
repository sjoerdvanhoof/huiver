import { mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { chunkTextWithSentenceLead, resumeKey } from "@huiver/shared";
import { registerRenderedChapter } from "./convert";
import { ffmpegBinary } from "./ffmpeg";
import { DATA_DIR, db, type ChapterRow } from "./db";
import {
  forgetStoredStream,
  lookupStoredStream,
  openStreamWriter,
  type StoredStream,
  type StreamWriter,
} from "./stream-store";
import { getProvider, type TTSSession } from "./tts";
import { acquireWarmSession, releaseWarmSession } from "./tts/warm";
import { charsPerSecond } from "./progress";

const PREVIEW_DIR = path.join(DATA_DIR, "previews");
const PREVIEW_TEXT =
  "This is how I sound. If you like it, I can read your whole book, one chapter at a time.";

/** Encode raw 16-bit mono PCM on stdin to an MP3 stream on stdout. */
function spawnMp3Encoder(sampleRate: number) {
  return Bun.spawn(
    [
      ffmpegBinary(), "-hide_banner", "-loglevel", "error",
      "-f", "s16le", "-ar", String(sampleRate), "-ac", "1", "-i", "pipe:0",
      "-c:a", "libmp3lame", "-b:a", "64k",
      // Without these the mp3 muxer buffers and the client hears nothing until
      // the very end, which defeats the point of streaming.
      "-flush_packets", "1", "-write_xing", "0",
      "-f", "mp3", "pipe:1",
    ],
    { stdin: "pipe", stdout: "pipe", stderr: "ignore" },
  );
}

/**
 * Streaming wants different chunking from batch conversion.
 *
 * Use the normal TTS chunker so every ordinary boundary is a paragraph or a
 * complete sentence. A sentence longer than Kokoro's safe input limit is the
 * sole exception and is split on words by chunkText.
 */
function streamChunks(text: string): string[] {
  return chunkTextWithSentenceLead(text);
}

const inFlightPreviews = new Map<string, Promise<string>>();

/**
 * Synthesis is CPU-bound and each worker holds ~1 GB, so refuse a pile-up
 * rather than thrashing. The UI only plays one chapter at a time; this is a
 * backstop against repeated requests.
 */
const MAX_CONCURRENT_STREAMS = 2;
let activeStreams = 0;

async function buildPreview(providerId: string, voice: string, outPath: string): Promise<string> {
  const session = await acquireWarmSession(providerId);
  let failed = false;
  const wavPath = path.join(tmpdir(), `huiver-preview-${crypto.randomUUID().slice(0, 8)}.wav`);

  try {
    await session.synthesize({ chunks: [PREVIEW_TEXT], voice, speed: 1, outWav: wavPath });

    await mkdir(PREVIEW_DIR, { recursive: true });
    const encode = Bun.spawn(
      [ffmpegBinary(), "-y", "-hide_banner", "-loglevel", "error", "-i", wavPath, "-c:a", "libmp3lame", "-b:a", "64k", outPath],
      { stdout: "ignore", stderr: "ignore" },
    );
    // If ffmpeg is unavailable, fall back to serving the WAV.
    if ((await encode.exited) !== 0) return wavPath;
    return outPath;
  } catch (error) {
    failed = true;
    throw error;
  } finally {
    releaseWarmSession(providerId, failed);
    if (await Bun.file(outPath).exists()) await rm(wavPath, { force: true });
  }
}

/** Drop a cached preview, for a voice that has been deleted or replaced. */
export async function forgetVoicePreview(providerId: string, voice: string): Promise<void> {
  if (!/^[\w.-]{1,64}$/.test(voice)) return;
  await rm(path.join(PREVIEW_DIR, `${providerId}-${voice}.mp3`), { force: true });
}

export async function serveVoicePreview(providerId: string, voice: string): Promise<Response> {
  if (!/^[\w.-]{1,64}$/.test(voice)) return Response.json({ error: "Invalid voice" }, { status: 400 });

  let info;
  try {
    info = await getProvider(providerId).info();
  } catch {
    return Response.json({ error: "Unknown provider" }, { status: 404 });
  }
  if (!info.available) return Response.json({ error: info.reason ?? "Engine unavailable" }, { status: 409 });
  if (info.voices.length > 0 && !info.voices.some(v => v.id === voice)) {
    return Response.json({ error: `Unknown voice '${voice}'` }, { status: 404 });
  }

  const cached = path.join(PREVIEW_DIR, `${providerId}-${voice}.mp3`);
  const key = `${providerId}:${voice}`;

  let filePath = cached;
  if (!(await Bun.file(cached).exists())) {
    let job = inFlightPreviews.get(key);
    if (!job) {
      job = buildPreview(providerId, voice, cached);
      inFlightPreviews.set(key, job);
      job.finally(() => inFlightPreviews.delete(key));
    }
    try {
      filePath = await job;
    } catch (error) {
      return Response.json(
        { error: error instanceof Error ? error.message : "Preview failed" },
        { status: 500 },
      );
    }
  }

  const file = Bun.file(filePath);
  return new Response(file, {
    headers: {
      "Content-Type": filePath.endsWith(".mp3") ? "audio/mpeg" : "audio/wav",
      "Content-Length": String(file.size),
      "Cache-Control": "public, max-age=86400",
    },
  });
}

/**
 * Which chunk roughly covers `seconds` into the chapter. Used only when playback
 * starts past the audio we have stored, where there is nothing better to go on
 * than the estimated reading rate.
 */
function estimateChunkIndex(chunks: string[], seconds: number, estimatedDuration: number, chars: number): number {
  const targetChars = estimatedDuration > 0 ? (seconds / estimatedDuration) * chars : 0;
  let consumed = 0;
  let index = 0;
  while (index + 1 < chunks.length && consumed + chunks[index]!.length <= targetChars) {
    consumed += chunks[index]!.length;
    index++;
  }
  return index;
}

/**
 * How much stored audio to hold in memory at once while replaying. A chapter
 * runs to tens of megabytes, so it is read in windows rather than whole.
 */
const REPLAY_WINDOW_BYTES = 1 << 20;

/**
 * Push already-rendered audio into the encoder as fast as the disk allows.
 *
 * Read with `arrayBuffer()` rather than `.stream()`: a file stream's chunks are
 * only valid until the next await, and handing one to the encoder's stdin —
 * which copies later — delivers nothing, so the listener gets silence.
 */
async function replayStored(
  stored: StoredStream,
  from: number,
  to: number,
  encoder: Bun.Subprocess<"pipe", "pipe", "ignore">,
  signal: AbortSignal,
): Promise<void> {
  const file = Bun.file(stored.path);

  for (let offset = from; offset < to && !signal.aborted; offset += REPLAY_WINDOW_BYTES) {
    const end = Math.min(offset + REPLAY_WINDOW_BYTES, to);
    const window = await file.slice(stored.dataOffset + offset, stored.dataOffset + end).arrayBuffer();
    encoder.stdin.write(new Uint8Array(window));
    await encoder.stdin.flush();
  }
}

/**
 * Render a chapter and stream it as MP3 while it is still being generated, so
 * playback starts after the first chunk instead of after the whole chapter.
 *
 * The audio is kept as it plays (see ./stream-store), so playing the chapter
 * again replays what was already rendered straight from disk and only
 * synthesizes the rest. A chapter that streams to the end is kept as a track.
 */
export async function streamChapter(req: Request, chapterId: string): Promise<Response> {
  const chapter = db.query("SELECT * FROM chapters WHERE id = ?").get(chapterId) as ChapterRow | null;
  if (!chapter) return Response.json({ error: "Chapter not found" }, { status: 404 });

  const url = new URL(req.url);
  const providerId = url.searchParams.get("provider") ?? "kokoro";
  const speed = Math.min(2, Math.max(0.5, Number(url.searchParams.get("speed")) || 1));

  let info;
  try {
    info = await getProvider(providerId).info();
  } catch {
    return Response.json({ error: "Unknown provider" }, { status: 404 });
  }
  if (!info.available) return Response.json({ error: info.reason ?? "Engine unavailable" }, { status: 409 });

  const voice = url.searchParams.get("voice") || info.defaultVoice;
  const allChunks = streamChunks(chapter.text);
  if (allChunks.length === 0) return Response.json({ error: "Chapter is empty" }, { status: 422 });

  const key = resumeKey({ provider: providerId, voice, speed }, allChunks);
  const stored = await lookupStoredStream(chapterId, key, allChunks.length);

  const estimatedDuration = chapter.char_count / charsPerSecond(db, chapter.book_id);
  const requestedStart = Math.min(
    Math.max(0, Number(url.searchParams.get("start")) || 0),
    Math.max(0, estimatedDuration - 1),
  );

  let replayFrom = 0;
  let replayTo = 0;
  let synthesizeFrom: number;
  let startSeconds: number;
  let mayStore: boolean;

  if (stored && requestedStart <= stored.durationSec) {
    // Stored audio is linear PCM, so the requested second is an exact offset
    // rather than the guess an unrendered chapter has to settle for.
    replayFrom = Math.min(Math.floor(requestedStart * stored.sampleRate) * 2, stored.dataBytes);
    replayTo = stored.dataBytes;
    startSeconds = replayFrom / 2 / stored.sampleRate;
    synthesizeFrom = stored.chunksDone;
    mayStore = true;
  } else if (!stored && requestedStart <= 0) {
    startSeconds = 0;
    synthesizeFrom = 0;
    mayStore = true;
  } else {
    // Playing from past what we have. Audio that starts mid-chapter cannot
    // extend the stored prefix, so this one is heard and forgotten.
    synthesizeFrom = estimateChunkIndex(allChunks, requestedStart, estimatedDuration, chapter.text.length);
    startSeconds = requestedStart;
    mayStore = false;
  }

  const chunks = allChunks.slice(synthesizeFrom);
  const needsSynthesis = chunks.length > 0;

  if (needsSynthesis && activeStreams >= MAX_CONCURRENT_STREAMS) {
    return Response.json({ error: "Too many streams at once — try again in a moment" }, { status: 429 });
  }

  let session: TTSSession | null = null;
  if (needsSynthesis) {
    activeStreams++;
    try {
      session = await acquireWarmSession(providerId);
    } catch (error) {
      activeStreams--;
      return Response.json(
        { error: error instanceof Error ? error.message : "Engine unavailable" },
        { status: 500 },
      );
    }
  }

  const sampleRate = session?.sampleRate ?? stored!.sampleRate;
  const totalChunks = allChunks.length;
  const encoder = spawnMp3Encoder(sampleRate);
  const abort = new AbortController();

  // The browser closing the connection (pause, seek, navigate) must stop synthesis.
  req.signal?.addEventListener("abort", () => abort.abort(), { once: true });

  let writer: StreamWriter | null = null;
  let claimTried = false;

  /**
   * Claim the stored stream at the last moment, when there is finally audio to
   * put in it. Pausing and immediately playing again arrives while the previous
   * request is still unwinding its synthesis, and waiting until the first chunk
   * is rendered gives it time to let go.
   */
  const claimStore = async (): Promise<StreamWriter | null> => {
    if (claimTried) return writer;
    claimTried = true;
    if (!mayStore) return null;

    // Another listener may have extended the file while we were replaying, in
    // which case our chunks no longer follow on from what it holds.
    const current = await lookupStoredStream(chapterId, key, totalChunks);
    if ((current?.chunksDone ?? 0) !== synthesizeFrom) return null;

    writer = await openStreamWriter({ key, chapterId, totalChunks, sampleRate, from: synthesizeFrom });
    return writer;
  };

  /** A chapter rendered end to end is worth keeping for good. */
  const keep = async (complete: StreamWriter): Promise<void> => {
    const finished = await complete.complete();
    if (!finished) return;

    const trackId = await registerRenderedChapter({
      chapterId,
      provider: providerId,
      voice,
      speed,
      wavPath: finished.path,
      chunksTotal: totalChunks,
    });
    // Registering moves the file into the job's folder.
    if (trackId) await forgetStoredStream(chapterId, key);
  };

  void (async () => {
    let failed = false;
    try {
      if (stored && replayTo > replayFrom) await replayStored(stored, replayFrom, replayTo, encoder, abort.signal);

      if (session) {
        await session.stream({
          chunks,
          voice,
          speed,
          signal: abort.signal,
          onAudio: async (pcm, index) => {
            encoder.stdin.write(pcm);
            await encoder.stdin.flush();

            const store = await claimStore();
            if (!store) return;
            try {
              await store.append(pcm, synthesizeFrom + index);
            } catch (error) {
              // Keeping the audio is a bonus; never let it break playback.
              console.warn(`[stream ${chapterId}] could not store audio:`, error);
              store.release();
              writer = null;
            }
          },
        });

        // Ran to the end: this is now a complete rendering of the chapter.
        if (!abort.signal.aborted && writer) await keep(writer);
      } else if (stored && stored.chunksDone >= totalChunks && !abort.signal.aborted && mayStore) {
        // Everything was already on disk, which means an earlier listen rendered
        // the whole chapter but was cut off before it could be kept properly.
        const store = await openStreamWriter({
          key,
          chapterId,
          totalChunks,
          sampleRate,
          from: stored.chunksDone,
        });
        if (store) {
          writer = store;
          await keep(store);
        }
      }
    } catch (error) {
      failed = true;
      if (!abort.signal.aborted) {
        console.error(`[stream ${chapterId}]`, error instanceof Error ? error.message : error);
      }
    } finally {
      try {
        encoder.stdin.end();
      } catch {
        // Encoder may already be gone.
      }
      writer?.release();
      if (session) {
        // An abort is now a graceful cancel, so the session stays reusable —
        // only a genuine error retires it.
        releaseWarmSession(providerId, failed);
        activeStreams--;
      }
    }
  })();

  return new Response(encoder.stdout, {
    headers: {
      "Content-Type": "audio/mpeg",
      "Cache-Control": "no-store",
      "X-Chunk-Count": String(chunks.length),
      "X-Stream-Start": String(startSeconds),
      // How much of this response comes from audio that was already rendered.
      "X-Stored-Seconds": String((replayTo - replayFrom) / 2 / sampleRate),
    },
  });
}
