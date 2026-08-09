import { mkdir, rm } from "node:fs/promises";
import path from "node:path";
import { chunkText } from "./chunk";
import { AUDIO_DIR, db } from "./db";
import type { BookRow, ChapterRow, JobRow, TrackRow } from "./db";
import { getProvider } from "./tts";

const queue: string[] = [];
let draining = false;

export function enqueueJob(jobId: string) {
  queue.push(jobId);
  void drain();
}

async function drain() {
  if (draining) return;
  draining = true;
  try {
    while (queue.length > 0) {
      const jobId = queue.shift()!;
      try {
        await runJob(jobId);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.error(`[job ${jobId}] failed:`, message);
        db.query("UPDATE jobs SET status = 'error', error = ?, finished_at = ? WHERE id = ?")
          .run(message, Date.now(), jobId);
      }
    }
  } finally {
    draining = false;
  }
}

function slugify(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")  // strip combining accents
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
  const proc = Bun.spawn(
    [
      "ffmpeg", "-y", "-loglevel", "error",
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

  const stderr = await new Response(proc.stderr).text();
  const code = await proc.exited;

  if (code !== 0) {
    console.warn(`[ffmpeg] mp3 encode failed, keeping WAV: ${stderr.trim().slice(0, 300)}`);
    return wavPath;
  }
  await rm(wavPath, { force: true });
  return mp3Path;
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
    return { track, chunks: chapter ? chunkText(chapter.text) : [] };
  });
  const chunksTotal = work.reduce((sum, item) => sum + item.chunks.length, 0);

  db.query("UPDATE jobs SET status = 'running', chunks_total = ?, chunks_done = 0, error = NULL WHERE id = ?")
    .run(chunksTotal, jobId);

  const outDir = path.join(AUDIO_DIR, jobId);
  await mkdir(outDir, { recursive: true });

  const session = await getProvider(job.provider).open();
  let chunksDone = 0;

  try {
    for (const { track, chunks } of work) {
      if (isCancelled(jobId)) return;

      // Already rendered on an earlier run (server restart) — don't redo the work.
      if (track.status === "done" && track.path && (await Bun.file(track.path).exists())) {
        chunksDone += chunks.length;
        db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(chunksDone, jobId);
        continue;
      }

      if (chunks.length === 0) {
        db.query("UPDATE tracks SET status = 'error', error = 'Chapter is empty' WHERE id = ?").run(track.id);
        continue;
      }

      db.query("UPDATE tracks SET status = 'running', error = NULL WHERE id = ?").run(track.id);

      const stem = `${String(track.idx + 1).padStart(3, "0")}-${slugify(track.title)}`;
      const wavPath = path.join(outDir, `${stem}.wav`);
      const mp3Path = path.join(outDir, `${stem}.mp3`);
      const base = chunksDone;

      try {
        const { durationSec } = await session.synthesize({
          chunks,
          voice: job.voice,
          speed: job.speed,
          outWav: wavPath,
          onChunk: done => {
            db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(base + done, jobId);
          },
        });

        const finalPath = await encodeMp3(wavPath, mp3Path, {
          title: track.title,
          album: book.title,
          artist: book.author ?? "Unknown",
          track: track.idx + 1,
        });

        db.query("UPDATE tracks SET status = 'done', path = ?, duration = ? WHERE id = ?")
          .run(finalPath, durationSec, track.id);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        db.query("UPDATE tracks SET status = 'error', error = ? WHERE id = ?").run(message, track.id);
        // A single bad chapter should not sink the whole book.
        console.error(`[job ${jobId}] track ${track.idx + 1} failed:`, message);
      }

      chunksDone = base + chunks.length;
      db.query("UPDATE jobs SET chunks_done = ? WHERE id = ?").run(chunksDone, jobId);
    }
  } finally {
    await session.close();
  }

  if (isCancelled(jobId)) return;

  const failed = db.query("SELECT COUNT(*) AS n FROM tracks WHERE job_id = ? AND status = 'error'")
    .get(jobId) as { n: number };
  const done = db.query("SELECT COUNT(*) AS n FROM tracks WHERE job_id = ? AND status = 'done'")
    .get(jobId) as { n: number };

  db.query("UPDATE jobs SET status = ?, error = ?, finished_at = ? WHERE id = ?").run(
    done.n === 0 ? "error" : "done",
    failed.n > 0 ? `${failed.n} chapter(s) failed` : null,
    Date.now(),
    jobId,
  );
}

/** Re-queue jobs that were mid-flight when the server was restarted. */
export function resumeInterruptedJobs() {
  const stale = db.query("SELECT id FROM jobs WHERE status IN ('queued','running')").all() as { id: string }[];
  for (const { id } of stale) {
    db.query("UPDATE jobs SET status = 'queued' WHERE id = ?").run(id);
    db.query("UPDATE tracks SET status = 'pending' WHERE job_id = ? AND status = 'running'").run(id);
    enqueueJob(id);
  }
  if (stale.length > 0) console.log(`Resumed ${stale.length} interrupted job(s)`);
}
