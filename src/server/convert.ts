import { mkdir, rename, rm, stat } from "node:fs/promises";
import path from "node:path";
import { planResume, resumeKey, type CheckpointRow } from "./checkpoint";
import { chunkText } from "./chunk";
import { AUDIO_DIR, db, newId } from "./db";
import type { BookRow, ChapterRow, JobRow, TrackRow } from "./db";
import { ffmpegBinary } from "./ffmpeg";
import { sweepStoredStreams } from "./stream-store";
import { getProvider } from "./tts";
import type { TTSSession } from "./tts";
import { readWavLayout, rewriteWavPrefix, syncWav, truncateWavData, wavDurationSec } from "./wav";

/**
 * `bun --hot` re-evaluates this module on every save without restarting the
 * process. Plain module-level state would give each reload its own queue and
 * drain loop, so saves during a conversion stack up parallel loops — each with
 * its own Python worker, all rendering the same book. Keeping the state on
 * globalThis means a reload picks up exactly where the last one left off.
 */
type ConvertState = {
  queue: string[];
  draining: boolean;
  /** Renders in flight, so a chapter can be pulled out of the queue mid-synthesis. */
  rendering: Map<string, AbortController>;
  /** Sessions owned by running jobs, so a reload can reap their workers. */
  sessions: Set<TTSSession>;
  resumed: boolean;
  /** The job the drain loop is on, so a reload can hand it back to the queue. */
  current: string | null;
  /**
   * Bumped when a reload supersedes the running loop. A stranded loop from an
   * earlier module instance checks this before writing anything, so it can
   * never fight the new one over the same track.
   */
  generation: number;
};

const state: ConvertState = ((globalThis as Record<string, unknown>).__huiverConvert ??= {
  queue: [],
  draining: false,
  rendering: new Map(),
  sessions: new Set(),
  resumed: false,
  current: null,
  generation: 0,
} satisfies ConvertState) as ConvertState;

const { queue, rendering } = state;

/**
 * Chunks rendered between checkpoints. Small enough that a crash costs seconds
 * of re-rendering, large enough that the flush and the row update disappear
 * next to the synthesis itself. Read per call so tests can dial it down.
 */
const checkpointChunks = () => Math.max(1, Number(process.env.HUIVER_CHECKPOINT_CHUNKS) || 8);

/** Tries per chapter. A retry resumes from the last checkpoint, so it is cheap. */
const trackAttempts = () => Math.max(1, Number(process.env.HUIVER_TRACK_ATTEMPTS) || 3);

/** How long a stopped chapter's audio waits to be resumed. 0 keeps it forever. */
const partialTtlDays = () => Math.max(0, Number(process.env.HUIVER_PARTIAL_TTL_DAYS ?? 14) || 0);

export function enqueueJob(jobId: string) {
  queue.push(jobId);
  void drain();
}

// A reload strands the worker a running job spawned (its stdin stays open, so
// it never sees EOF). Reap them and hand the job back to the queue; the new
// module instance resumes it from its last checkpoint.
if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    state.generation++;
    for (const session of state.sessions) void session.close().catch(() => {});
    state.sessions.clear();
    for (const abort of rendering.values()) abort.abort();
    rendering.clear();
    if (state.current) queue.unshift(state.current);
    state.current = null;
    state.draining = false;
  });
}

const checkpointRow = (trackId: string): CheckpointRow =>
  (db
    .query("SELECT resume_chunks, resume_bytes, resume_key FROM tracks WHERE id = ?")
    .get(trackId) as CheckpointRow | null) ?? { resume_chunks: 0, resume_bytes: 0, resume_key: null };

const clearCheckpoint = (trackId: string): void => {
  db.query(
    "UPDATE tracks SET resume_chunks = 0, resume_bytes = 0, resume_key = NULL, resume_path = NULL WHERE id = ?",
  ).run(trackId);
};

async function discardPartial(trackId: string, partPath: string): Promise<void> {
  await rm(partPath, { force: true });
  clearCheckpoint(trackId);
}

/**
 * Leave a stopped chapter's audio where it is, with the row reporting exactly
 * what the checkpoint covers — the render runs ahead of the last mark, and the
 * chunks past it are gone.
 */
function parkPartial(trackId: string): void {
  db.query("UPDATE tracks SET status = 'cancelled', chunks_done = resume_chunks WHERE id = ?").run(trackId);
}

/**
 * Drop one chapter from the queue. A chapter that is still waiting is simply
 * skipped when the job reaches it; one that is already rendering is aborted at
 * the next chunk boundary. Either way its checkpoint is left alone: stopping is
 * a pause, and converting the chapter again carries on from where it stopped.
 */
export function cancelTrack(trackId: string): boolean {
  const row = db.query("SELECT status FROM tracks WHERE id = ?").get(trackId) as { status: string } | null;
  if (!row || row.status === "done" || row.status === "cancelled") return false;

  db.query("UPDATE tracks SET status = 'cancelled', error = NULL WHERE id = ?").run(trackId);
  rendering.get(trackId)?.abort();
  return true;
}

/**
 * Stop a whole run: abort whatever is rendering and drop everything still
 * queued. Stopping is a choice, not a failure, so nothing is marked as an error.
 */
export function cancelJobTracks(jobId: string): void {
  const tracks = db
    .query("SELECT id FROM tracks WHERE job_id = ? AND status IN ('pending', 'running')")
    .all(jobId) as { id: string }[];

  for (const { id } of tracks) {
    db.query("UPDATE tracks SET status = 'cancelled', error = NULL WHERE id = ?").run(id);
    rendering.get(id)?.abort();
  }
}

const trackStatus = (trackId: string): string | null =>
  (db.query("SELECT status FROM tracks WHERE id = ?").get(trackId) as { status: string } | null)?.status ?? null;

async function drain() {
  if (state.draining) return;
  state.draining = true;
  try {
    while (queue.length > 0) {
      const jobId = queue.shift()!;
      state.current = jobId;
      try {
        await runJob(jobId);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.error(`[job ${jobId}] failed:`, message);
        db.query("UPDATE jobs SET status = 'error', error = ?, finished_at = ? WHERE id = ?")
          .run(message, Date.now(), jobId);
      } finally {
        state.current = null;
      }
    }
  } finally {
    state.draining = false;
  }
}

function slugify(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/[\u0300-\u036F]/g, "")  // strip combining accents
    .replace(/[^a-zA-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase()
    .slice(0, 60) || "track";
}

function isCancelled(jobId: string): boolean {
  const row = db.query("SELECT status FROM jobs WHERE id = ?").get(jobId) as { status: string } | null;
  return !row || row.status === "cancelled";
}

/** Transcode the synthesized WAV to a tagged MP3. Falls back to the WAV if ffmpeg is unavailable. */
async function encodeMp3(
  wavPath: string,
  mp3Path: string,
  tags: { title: string; album: string; artist: string; track: number },
): Promise<string> {
  let proc: Bun.Subprocess<"ignore", "ignore", "pipe">;
  try {
    proc = Bun.spawn(
      [
        ffmpegBinary(), "-y", "-loglevel", "error",
        "-i", wavPath,
        "-c:a", "libmp3lame", "-b:a", "64k", "-ac", "1",
        "-metadata", `title=${tags.title}`,
        "-metadata", `album=${tags.album}`,
        "-metadata", `artist=${tags.artist}`,
        "-metadata", `track=${tags.track}`,
        mp3Path,
      ],
      { stdout: "ignore", stderr: "pipe" },
    );
  } catch (error) {
    // No ffmpeg on this machine at all: spawning throws rather than exiting.
    const message = error instanceof Error ? error.message : String(error);
    console.warn(`[ffmpeg] not available, keeping WAV: ${message}`);
    return wavPath;
  }

  const stderr = await new Response(proc.stderr).text();
  const code = await proc.exited;

  if (code !== 0) {
    console.warn(`[ffmpeg] mp3 encode failed, keeping WAV: ${stderr.trim().slice(0, 300)}`);
    return wavPath;
  }
  await rm(wavPath, { force: true });
  return mp3Path;
}

/** Record how much of a track is safely on disk, so a crash can resume from here. */
async function saveCheckpoint(trackId: string, chunksDone: number, partPath: string, key: string): Promise<void> {
  await syncWav(partPath); // the mark must never promise audio the disk does not have
  const layout = await readWavLayout(partPath);
  db.query(
    "UPDATE tracks SET resume_chunks = ?, resume_bytes = ?, resume_key = ?, resume_path = ? WHERE id = ?",
  ).run(chunksDone, layout?.dataBytes ?? 0, key, partPath, trackId);
}

/**
 * Position a partial file at its last checkpoint and report the chunk to carry
 * on from. Audio the interrupted batch wrote past the mark is cut off: there is
 * no record of which chunk it belongs to, so it has to be rendered again.
 */
async function rewindToCheckpoint(
  trackId: string,
  key: string,
  totalChunks: number,
  partPath: string,
): Promise<number> {
  const layout = await readWavLayout(partPath);
  const plan = planResume({
    saved: checkpointRow(trackId),
    key,
    totalChunks,
    dataBytes: layout?.dataBytes ?? null,
  });

  if (!plan) {
    await discardPartial(trackId, partPath);
    return 0;
  }

  // Always replace the file, even when it needs no cutting: the speech worker
  // the crashed run spawned can outlive it by a moment and still be writing.
  await rewriteWavPrefix(partPath, plan.dataBytes);
  return plan.startChunk;
}

/**
 * Take over the partial another job left for this chapter.
 *
 * Stopping a conversion and starting it again is a new job with new tracks, so
 * without this the audio a stopped chapter had already rendered would be
 * invisible and get rendered a second time. The key guarantees it is the same
 * work, so the partial simply moves into the new job's folder.
 */
async function adoptPartial(
  track: TrackRow,
  key: string,
  totalChunks: number,
  partPath: string,
): Promise<number> {
  const donor = db
    .query(
      `SELECT id, resume_chunks, resume_bytes, resume_key, resume_path FROM tracks
       WHERE chapter_id = ? AND id != ? AND resume_key = ? AND resume_chunks > 0 AND resume_path IS NOT NULL
       ORDER BY resume_chunks DESC LIMIT 1`,
    )
    .get(track.chapter_id, track.id, key) as (CheckpointRow & { id: string; resume_path: string }) | null;

  // Never take one out from under a render in flight.
  if (!donor || rendering.has(donor.id)) return 0;

  const layout = await readWavLayout(donor.resume_path);
  const plan = planResume({ saved: donor, key, totalChunks, dataBytes: layout?.dataBytes ?? null });
  if (!plan) {
    await discardPartial(donor.id, donor.resume_path);
    return 0;
  }

  try {
    await rename(donor.resume_path, partPath);
  } catch (error) {
    console.warn(`[track ${track.id}] could not adopt ${donor.resume_path}:`, error);
    return 0;
  }

  clearCheckpoint(donor.id);
  db.query(
    "UPDATE tracks SET resume_chunks = ?, resume_bytes = ?, resume_key = ?, resume_path = ? WHERE id = ?",
  ).run(plan.startChunk, plan.dataBytes, key, partPath, track.id);

  await truncateWavData(partPath, plan.dataBytes);
  return plan.startChunk;
}

/**
 * Where this chapter's render should begin: its own checkpoint if it has one,
 * otherwise whatever an earlier, stopped job got through.
 */
async function resumePointFor(
  track: TrackRow,
  key: string,
  totalChunks: number,
  partPath: string,
): Promise<number> {
  const own = await rewindToCheckpoint(track.id, key, totalChunks, partPath);
  return own > 0 ? own : adoptPartial(track, key, totalChunks, partPath);
}

/** Once a chapter is rendered, partials of the same work are only litter. */
async function dropRedundantPartials(track: TrackRow, key: string): Promise<void> {
  const rows = db
    .query(
      `SELECT id, resume_path FROM tracks
       WHERE chapter_id = ? AND id != ? AND resume_key = ? AND resume_path IS NOT NULL`,
    )
    .all(track.chapter_id, track.id, key) as { id: string; resume_path: string }[];

  for (const row of rows) {
    if (rendering.has(row.id)) continue;
    await discardPartial(row.id, row.resume_path);
  }
}

type RenderArgs = {
  jobId: string;
  track: TrackRow;
  voice: string;
  speed: number;
  chunks: string[];
  key: string;
  partPath: string;
  /** Chunk to start from, from an earlier run's checkpoint. */
  startChunk: number;
  signal: AbortSignal;
  session: () => TTSSession;
  /** Hand back a healthy session after a failure, for the next attempt. */
  reopen: () => Promise<TTSSession>;
  onProgress: (chunksDone: number) => void;
};

/**
 * Render one chapter from `startChunk` to the end, appending to the partial WAV
 * and checkpointing every few chunks. A failure is retried from the newest
 * checkpoint rather than from the top of the chapter.
 */
async function renderCheckpointed(args: RenderArgs): Promise<void> {
  let offset = args.startChunk;

  for (let attempt = 1; ; attempt++) {
    try {
      while (offset < args.chunks.length) {
        if (args.signal.aborted) return;

        const base = offset;
        const batch = args.chunks.slice(base, base + checkpointChunks());
        await args.session().synthesize({
          chunks: batch,
          voice: args.voice,
          speed: args.speed,
          outWav: args.partPath,
          append: base > 0,
          signal: args.signal,
          onChunk: done => args.onProgress(base + done),
        });
        if (args.signal.aborted) return;

        offset = base + batch.length;
        await saveCheckpoint(args.track.id, offset, args.partPath, args.key);
        args.onProgress(offset);
      }
      return;
    } catch (error) {
      if (args.signal.aborted || attempt >= trackAttempts()) throw error;

      const message = error instanceof Error ? error.message : String(error);
      console.warn(
        `[job ${args.jobId}] chapter ${args.track.idx + 1} attempt ${attempt} failed at chunk ${offset}: ${message}`,
      );
      // Whatever broke may have taken the provider with it — a crashed local
      // worker, a dead connection — so the next attempt gets a fresh session
      // and restarts from the last mark on disk.
      await args.reopen();
      offset = await rewindToCheckpoint(args.track.id, args.key, args.chunks.length, args.partPath);
      args.onProgress(offset);
    }
  }
}

async function runJob(jobId: string) {
  const job = db.query("SELECT * FROM jobs WHERE id = ?").get(jobId) as JobRow | null;
  if (!job || job.status === "cancelled") return;

  const book = db.query("SELECT * FROM books WHERE id = ?").get(job.book_id) as BookRow | null;
  if (!book) throw new Error("Book no longer exists");

  const tracks = db.query("SELECT * FROM tracks WHERE job_id = ? ORDER BY idx").all(jobId) as TrackRow[];
  if (tracks.length === 0) throw new Error("Job has no tracks");

  // Chunk everything up front so total progress is known before synthesis starts.
  const work = tracks.map(track => {
    const chapter = db.query("SELECT * FROM chapters WHERE id = ?").get(track.chapter_id) as ChapterRow | null;
    const chunks = chapter ? chunkText(chapter.text) : [];
    return { track, chunks, key: resumeKey(job, chunks) };
  });
  const chunksTotal = work.reduce((sum, item) => sum + item.chunks.length, 0);

  db.query("UPDATE jobs SET status = 'running', chunks_total = ?, chunks_done = 0, error = NULL WHERE id = ?")
    .run(chunksTotal, jobId);
  // Per-track totals up front so a queued chapter can show its own size.
  const setTrackTotal = db.query("UPDATE tracks SET chunks_total = ? WHERE id = ?");
  for (const { track, chunks } of work) setTrackTotal.run(chunks.length, track.id);

  const outDir = path.join(AUDIO_DIR, jobId);
  await mkdir(outDir, { recursive: true });

  const generation = state.generation;
  const superseded = () => state.generation !== generation;

  let session: TTSSession | null = null;
  const openSession = async () => {
    const opened = await getProvider(job.provider).open();
    state.sessions.add(opened);
    session = opened;
    return opened;
  };
  const closeSession = async () => {
    const current = session;
    session = null;
    if (!current) return;
    state.sessions.delete(current);
    await current.close().catch(() => {});
  };

  await openSession();
  let chunksDone = 0;

  try {
    for (const { track, chunks, key } of work) {
      // A reload took over this job; the new loop owns everything from here.
      if (superseded()) return;

      if (isCancelled(jobId)) {
        cancelJobTracks(jobId); // don't leave the rest hanging as pending
        return;
      }

      // Pulled out of the queue since the job started.
      if (trackStatus(track.id) === "cancelled") {
        chunksDone += chunks.length;
        db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(chunksDone, jobId);
        continue;
      }

      // Already rendered on an earlier run (server restart) — don't redo the work.
      if (track.status === "done" && track.path && (await Bun.file(track.path).exists())) {
        chunksDone += chunks.length;
        db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(chunksDone, jobId);
        db.query("UPDATE tracks SET chunks_done = chunks_total WHERE id = ?").run(track.id);
        continue;
      }

      if (chunks.length === 0) {
        db.query("UPDATE tracks SET status = 'error', error = 'Chapter is empty' WHERE id = ?").run(track.id);
        continue;
      }

      const stem = `${String(track.idx + 1).padStart(3, "0")}-${slugify(track.title)}`;
      // Kept apart from the finished name so a partial is never mistaken for
      // playable audio, and is obvious when poking around data/audio.
      const partPath = path.join(outDir, `${stem}.part.wav`);
      const wavPath = path.join(outDir, `${stem}.wav`);
      const mp3Path = path.join(outDir, `${stem}.mp3`);
      const base = chunksDone;

      const report = (done: number) => {
        db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(base + done, jobId);
        db.query("UPDATE tracks SET chunks_done = ? WHERE id = ?").run(done, track.id);
      };

      const abort = new AbortController();
      rendering.set(track.id, abort);

      try {
        const startChunk = await resumePointFor(track, key, chunks.length, partPath);
        if (startChunk > 0) {
          console.log(
            `[job ${jobId}] chapter ${track.idx + 1} resuming at chunk ${startChunk}/${chunks.length}`,
          );
        }

        db.query("UPDATE tracks SET status = 'running', error = NULL, chunks_done = ? WHERE id = ?")
          .run(startChunk, track.id);
        report(startChunk);

        await renderCheckpointed({
          jobId,
          track,
          voice: job.voice,
          speed: job.speed,
          chunks,
          key,
          partPath,
          startChunk,
          signal: abort.signal,
          session: () => session!,
          reopen: async () => {
            await closeSession();
            return openSession();
          },
          onProgress: report,
        });

        // Leave the partial and its checkpoint alone: the loop that superseded
        // us is the one that gets to finish this chapter.
        if (superseded()) return;

        // Removed from the queue while it rendered. The partial and its
        // checkpoint stay: converting this chapter again continues from here.
        if (abort.signal.aborted || trackStatus(track.id) === "cancelled") {
          parkPartial(track.id);
        } else {
          const layout = await readWavLayout(partPath);
          await rename(partPath, wavPath);

          const finalPath = await encodeMp3(wavPath, mp3Path, {
            title: track.title,
            album: book.title,
            artist: book.author ?? "Unknown",
            track: track.idx + 1,
          });

          db.query(
            `UPDATE tracks SET status = 'done', path = ?, duration = ?, chunks_done = chunks_total,
                    resume_chunks = 0, resume_bytes = 0, resume_key = NULL, resume_path = NULL
             WHERE id = ?`,
          ).run(finalPath, layout ? wavDurationSec(layout) : null, track.id);
          await dropRedundantPartials(track, key);
        }
      } catch (error) {
        if (superseded()) return;

        const message = error instanceof Error ? error.message : String(error);
        if (abort.signal.aborted || trackStatus(track.id) === "cancelled") {
          parkPartial(track.id);
        } else {
          // Out of attempts. The checkpoint survives, so converting the book
          // again resumes this chapter rather than re-rendering what worked.
          db.query("UPDATE tracks SET status = 'error', error = ? WHERE id = ?").run(message, track.id);
          // A single bad chapter should not sink the whole book.
          console.error(`[job ${jobId}] track ${track.idx + 1} failed:`, message);
        }
      } finally {
        // Only if we still own it: a reload clears the map when it takes over.
        if (rendering.get(track.id) === abort) rendering.delete(track.id);
      }

      chunksDone = base + chunks.length;
      db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(chunksDone, jobId);
    }
  } finally {
    await closeSession();
  }

  if (isCancelled(jobId)) {
    cancelJobTracks(jobId);
    return;
  }

  const failed = db.query("SELECT COUNT(*) AS n FROM tracks WHERE job_id = ? AND status = 'error'")
    .get(jobId) as { n: number };
  const done = db.query("SELECT COUNT(*) AS n FROM tracks WHERE job_id = ? AND status = 'done'")
    .get(jobId) as { n: number };

  // Nothing rendered because every chapter was removed from the queue is a
  // cancellation, not a failure.
  const status = done.n > 0 ? "done" : failed.n > 0 ? "error" : "cancelled";

  db.query("UPDATE jobs SET status = ?, error = ?, finished_at = ? WHERE id = ?").run(
    status,
    failed.n > 0 ? `${failed.n} chapter(s) failed` : null,
    Date.now(),
    jobId,
  );
}

/**
 * Take ownership of a chapter that was rendered outside the job queue — one the
 * user streamed all the way through — and store it as an ordinary finished
 * track, so it counts as converted and can be seeked and downloaded like any
 * other. Returns null when the chapter already has audio, leaving the caller's
 * file alone.
 */
export async function registerRenderedChapter(args: {
  chapterId: string;
  provider: string;
  voice: string;
  speed: number;
  /** WAV to take over; it is moved into the new job's folder. */
  wavPath: string;
  chunksTotal: number;
}): Promise<string | null> {
  const chapter = db.query("SELECT * FROM chapters WHERE id = ?").get(args.chapterId) as ChapterRow | null;
  if (!chapter) return null;

  const existing = db
    .query("SELECT id FROM tracks WHERE chapter_id = ? AND status = 'done' AND path IS NOT NULL LIMIT 1")
    .get(args.chapterId) as { id: string } | null;
  if (existing) return null;

  const book = db.query("SELECT * FROM books WHERE id = ?").get(chapter.book_id) as BookRow | null;
  if (!book) return null;

  const layout = await readWavLayout(args.wavPath);
  if (!layout || layout.dataBytes === 0) return null;

  const jobId = newId("job");
  const trackId = newId("tr");
  const outDir = path.join(AUDIO_DIR, jobId);
  await mkdir(outDir, { recursive: true });

  const stem = `001-${slugify(chapter.title)}`;
  const wavDest = path.join(outDir, `${stem}.wav`);
  await rename(args.wavPath, wavDest);

  const finalPath = await encodeMp3(wavDest, path.join(outDir, `${stem}.mp3`), {
    title: chapter.title,
    album: book.title,
    artist: book.author ?? "Unknown",
    track: chapter.idx + 1,
  });

  const now = Date.now();
  db.transaction(() => {
    db.query(
      `INSERT INTO jobs (id, book_id, provider, voice, speed, status, chunks_done, chunks_total, created_at, finished_at)
       VALUES (?, ?, ?, ?, ?, 'done', ?, ?, ?, ?)`,
    ).run(jobId, book.id, args.provider, args.voice, args.speed, args.chunksTotal, args.chunksTotal, now, now);
    db.query(
      `INSERT INTO tracks (id, job_id, chapter_id, idx, title, status, path, duration, chunks_done, chunks_total)
       VALUES (?, ?, ?, 0, ?, 'done', ?, ?, ?, ?)`,
    ).run(
      trackId, jobId, chapter.id, chapter.title, finalPath, wavDurationSec(layout),
      args.chunksTotal, args.chunksTotal,
    );
  })();

  console.log(`[stream ${chapter.id}] kept "${chapter.title}" as a finished track`);
  return trackId;
}

/**
 * Delete parked partials nobody came back for. A stopped chapter keeps its
 * audio so the next conversion can continue it, and this is what keeps that
 * from turning into a slow disk leak.
 */
export async function sweepStalePartials(): Promise<void> {
  const days = partialTtlDays();
  if (days === 0) return;
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;

  const parked = db
    .query("SELECT id, resume_path FROM tracks WHERE resume_path IS NOT NULL")
    .all() as { id: string; resume_path: string }[];

  let swept = 0;
  for (const row of parked) {
    if (rendering.has(row.id)) continue;
    try {
      const info = await stat(row.resume_path).catch(() => null);
      if (info && info.mtimeMs > cutoff) continue;
      await discardPartial(row.id, row.resume_path); // also covers a file that vanished
      swept++;
    } catch (error) {
      console.warn(`[track ${row.id}] could not clean up ${row.resume_path}:`, error);
    }
  }

  swept += await sweepStoredStreams(cutoff);
  if (swept > 0) console.log(`Cleaned up ${swept} stale partial render(s)`);
}

/**
 * Re-queue jobs that were mid-flight when the server was restarted. Runs once
 * per process: `bun --hot` re-evaluates the entry point on every save, and
 * resuming again there would re-enqueue jobs that are still converting.
 *
 * Chapters that were half rendered keep their checkpoint, so they carry on from
 * the last mark instead of starting over.
 */
export async function resumeInterruptedJobs(): Promise<void> {
  if (state.resumed) return;
  state.resumed = true;

  // Before anything is queued, so a sweep can never pull a partial out from
  // under a chapter that is about to resume from it.
  await sweepStalePartials().catch(error => console.warn("Partial cleanup failed:", error));

  const stale = db.query("SELECT id FROM jobs WHERE status IN ('queued','running')").all() as { id: string }[];
  for (const { id } of stale) {
    db.query("UPDATE jobs SET status = 'queued' WHERE id = ?").run(id);
    db.query("UPDATE tracks SET status = 'pending' WHERE job_id = ? AND status = 'running'").run(id);
    enqueueJob(id);
  }
  if (stale.length > 0) console.log(`Resumed ${stale.length} interrupted job(s)`);
}
