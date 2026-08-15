import { chunkTextWithSentenceLead, pcmDurationSec, resumeKey, silencePcm16 } from "@huiver/shared";
import { useSyncExternalStore } from "react";
import {
  cancelTrack,
  failTrack,
  finishTrack,
  finishedTracks,
  getChapter,
  getTrack,
  interruptedTracks,
  setTrackProgress,
  upsertTrack,
} from "../db/queries";
import { chapterFile, chunkDir, chunkFile, contiguousChunkCount, deleteChunks, ensureDir } from "../files";
import { acquireSession } from "../tts";
import { readChunkPcmLength, stitchChapter, writeChunkWav } from "./wavFile";

/**
 * Rendering a chapter, chunk by chunk.
 *
 * The chunk files on disk *are* the checkpoint: each one is a finished WAV, so
 * a run interrupted anywhere — a crash, the OS suspending the app, the user
 * stopping — leaves a prefix that the next run continues from. What ties them
 * to the work is `resumeKey` (shared with the server): change the text, the
 * voice or the speed and the key changes, so a stale prefix is thrown away
 * rather than spliced onto a different render.
 *
 * The listener reads the same files while they are being written, which is how
 * "listen while converting" works — see src/player/queueFeeder.
 */

/** Spacing between chunks so sentences do not run together, as on the server. */
const GAP_SECONDS = 0.25;

/** Kokoro renders at 24 kHz; chunk files on disk are all at this rate. */
export const SAMPLE_RATE = 24000;

export type ChapterProgress = {
  chapterId: string;
  chunksDone: number;
  chunksTotal: number;
  /** Seconds of audio rendered so far, for the player's synthesis frontier. */
  renderedSeconds: number;
  status: "running" | "stopping";
};

type Run = {
  chapterId: string;
  cancel: () => void;
  finished: Promise<void>;
};

let active: Run | null = null;
let progress: ChapterProgress | null = null;
const listeners = new Set<() => void>();

const publish = (next: ChapterProgress | null) => {
  progress = next;
  listeners.forEach(listener => listener());
};

const subscribe = (onChange: () => void) => {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
};

export const getConversionProgress = (): ChapterProgress | null => progress;

/**
 * Watch conversion from outside React. The player needs this: it has to follow
 * a render it did not start itself, which is what happens when a chapter is
 * already converting and the user presses play on it.
 */
export const subscribeConversion = subscribe;

export function useConversionProgress(): ChapterProgress | null {
  return useSyncExternalStore(subscribe, getConversionProgress);
}

/** Chunks are cut the same way the server cuts them for live playback: the
 * opening sentence stands alone, so the first audio arrives in a second or two. */
export const chapterChunks = (text: string): string[] => chunkTextWithSentenceLead(text);

export type ConvertOptions = {
  chapterId: string;
  voice: string;
  /** Synthesis speed. Playback rate is the player's business, so this is 1. */
  speed?: number;
};

/**
 * Convert one chapter. Only one runs at a time: synthesis is the whole CPU and
 * most of the memory, and the UI never asks for two at once.
 */
export function convertChapter(options: ConvertOptions): Run {
  if (active && active.chapterId === options.chapterId) return active;
  const previous = active;

  let cancelled = false;
  const cancel = () => {
    cancelled = true;
  };

  // Never rejects: a failure is recorded on the track row and shown in the UI,
  // and callers (the player, the chapter list) only ever await the ending.
  const finished = (async () => {
    // Let a chapter already in flight unwind before taking the engine.
    if (previous) {
      previous.cancel();
      await previous.finished;
    }
    try {
      await runConversion(options, () => cancelled);
    } catch (error) {
      failTrack(options.chapterId, error instanceof Error ? error.message : String(error));
    }
  })();

  const run: Run = { chapterId: options.chapterId, cancel, finished };
  active = run;
  void finished.then(() => {
    if (active === run) {
      active = null;
      publish(null);
    }
  });
  return run;
}

export function stopConversion(chapterId?: string): void {
  if (!active) return;
  if (chapterId && active.chapterId !== chapterId) return;
  active.cancel();
  if (progress) publish({ ...progress, status: "stopping" });
}

export const activeChapterId = (): string | null => active?.chapterId ?? null;

async function runConversion(options: ConvertOptions, isCancelled: () => boolean): Promise<void> {
  const { chapterId, voice, speed = 1 } = options;
  const chapter = getChapter(chapterId);
  if (!chapter) return;

  const chunks = chapterChunks(chapter.text);
  if (chunks.length === 0) {
    failTrack(chapterId, "This chapter has no readable text.");
    return;
  }

  const key = resumeKey({ provider: "kokoro", voice, speed }, chunks);
  const startChunk = planStart(chapterId, key, chunks.length);

  upsertTrack({ chapterId, voice, speed, chunksTotal: chunks.length, resumeKey: key, chunksDone: startChunk });
  ensureDir(chunkDir(chapterId));

  let renderedSeconds = renderedSecondsUpTo(chapterId, startChunk);
  publish({ chapterId, chunksDone: startChunk, chunksTotal: chunks.length, renderedSeconds, status: "running" });

  const opened = await acquireSession().catch(error => {
    // Most often: the voice model has not been downloaded yet.
    failTrack(chapterId, error instanceof Error ? error.message : String(error));
    publish(null);
    return null;
  });
  if (!opened) return;
  const { session, release } = opened;

  try {
    for (let index = startChunk; index < chunks.length; index++) {
      if (isCancelled()) {
        cancelTrack(chapterId);
        return;
      }

      const pcm = await session.synthesize(chunks[index]!, voice, speed);
      const gap = silencePcm16(GAP_SECONDS, session.sampleRate);

      const file = chunkFile(chapterId, index);
      writeChunkWav(file, concat(pcm, gap), session.sampleRate);

      renderedSeconds += (pcm.byteLength + gap.byteLength) / 2 / session.sampleRate;
      setTrackProgress(chapterId, index + 1);
      publish({
        chapterId,
        chunksDone: index + 1,
        chunksTotal: chunks.length,
        renderedSeconds,
        status: "running",
      });
    }

    const destination = chapterFile(chapterId);
    const files = chunks.map((_, index) => chunkFile(chapterId, index));
    const { durationSec } = stitchChapter(files, destination, session.sampleRate);

    finishTrack(chapterId, destination.uri, durationSec);
    // The chunks are deliberately left behind: a listener may still be walking
    // them, and pulling a file out from under the player mid-chapter would end
    // playback. They are swept at the next launch instead — see sweepChunks.
  } catch (error) {
    if (isCancelled()) cancelTrack(chapterId);
    else failTrack(chapterId, error instanceof Error ? error.message : String(error));
  } finally {
    release();
    publish(null);
  }
}

/**
 * Where to pick up. A checkpoint only counts when it describes this exact work
 * and the chunk files actually back it — the same two conditions the server's
 * `planResume` insists on.
 */
function planStart(chapterId: string, key: string, totalChunks: number): number {
  const track = getTrack(chapterId);
  const onDisk = contiguousChunkCount(chapterId);

  if (!track || track.resume_key !== key) {
    if (onDisk > 0) deleteChunks(chapterId);
    return 0;
  }
  // A checkpoint past the end can only mean the chunking changed under us.
  if (onDisk > totalChunks) {
    deleteChunks(chapterId);
    return 0;
  }
  return Math.min(onDisk, totalChunks);
}

function renderedSecondsUpTo(chapterId: string, chunks: number): number {
  let bytes = 0;
  for (let index = 0; index < chunks; index++) bytes += readChunkPcmLength(chunkFile(chapterId, index));
  return pcmDurationSec(bytes, SAMPLE_RATE);
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.byteLength + b.byteLength);
  out.set(a, 0);
  out.set(b, a.byteLength);
  return out;
}

/**
 * A track still marked "running" at launch belonged to a run the OS cut short.
 * Nothing is resumed automatically — that would start synthesis the user did
 * not ask for — it just stops claiming to be in progress. The chunk files stay,
 * so pressing convert again continues from the checkpoint.
 */
export function reconcileInterruptedTracks(): void {
  for (const track of interruptedTracks()) cancelTrack(track.chapter_id);
}

/**
 * Drop the per-chunk files of chapters that finished rendering. They are kept
 * while the app runs, in case a listener is still walking them, so launch —
 * when nothing can be playing yet — is the moment to reclaim the space.
 */
export function sweepChunks(): void {
  for (const track of finishedTracks()) deleteChunks(track.chapter_id);
}
