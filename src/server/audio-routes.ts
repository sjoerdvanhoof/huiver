import { mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { chunkTextWithSentenceLead } from "./chunk";
import { DATA_DIR, db, type ChapterRow } from "./db";
import { getProvider } from "./tts";
import { acquireWarmSession, releaseWarmSession } from "./tts/warm";
import { charsPerSecond } from "./progress";

const PREVIEW_DIR = path.join(DATA_DIR, "previews");
const PREVIEW_TEXT =
  "This is how I sound. If you like it, I can read your whole book, one chapter at a time.";

/** Encode raw 16-bit mono PCM on stdin to an MP3 stream on stdout. */
function spawnMp3Encoder(sampleRate: number) {
  return Bun.spawn(
    [
      "ffmpeg", "-hide_banner", "-loglevel", "error",
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
      ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", wavPath, "-c:a", "libmp3lame", "-b:a", "64k", outPath],
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
 * Render a chapter and stream it as MP3 while it is still being generated, so
 * playback starts after the first chunk instead of after the whole chapter.
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
  const estimatedDuration = chapter.char_count / charsPerSecond(db, chapter.book_id);
  const requestedStart = Math.min(
    Math.max(0, Number(url.searchParams.get("start")) || 0),
    Math.max(0, estimatedDuration - 1),
  );
  const targetChars = estimatedDuration > 0 ? requestedStart / estimatedDuration * chapter.text.length : 0;
  let consumedChars = 0;
  let startIndex = 0;
  while (startIndex + 1 < allChunks.length && consumedChars + allChunks[startIndex]!.length <= targetChars) {
    consumedChars += allChunks[startIndex]!.length;
    startIndex++;
  }
  const chunks = allChunks.slice(startIndex);
  if (chunks.length === 0) return Response.json({ error: "Chapter is empty" }, { status: 422 });

  if (activeStreams >= MAX_CONCURRENT_STREAMS) {
    return Response.json({ error: "Too many streams at once — try again in a moment" }, { status: 429 });
  }
  activeStreams++;

  const session = await acquireWarmSession(providerId);
  const encoder = spawnMp3Encoder(session.sampleRate);
  const abort = new AbortController();

  // The browser closing the connection (pause, seek, navigate) must stop synthesis.
  req.signal?.addEventListener("abort", () => abort.abort(), { once: true });

  void (async () => {
    let failed = false;
    try {
      await session.stream({
        chunks,
        voice,
        speed,
        signal: abort.signal,
        onAudio: async pcm => {
          encoder.stdin.write(pcm);
          await encoder.stdin.flush();
        },
      });
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
      // An abort is now a graceful cancel, so the session stays reusable —
      // only a genuine error retires it.
      releaseWarmSession(providerId, failed);
      activeStreams--;
    }
  })();

  return new Response(encoder.stdout, {
    headers: {
      "Content-Type": "audio/mpeg",
      "Cache-Control": "no-store",
      "X-Chunk-Count": String(chunks.length),
      "X-Stream-Start": String(requestedStart),
    },
  });
}
