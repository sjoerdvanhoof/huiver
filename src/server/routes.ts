import { zipSync } from "fflate";
import { rm } from "node:fs/promises";
import path from "node:path";
import { serveVoicePreview, streamChapter } from "./audio-routes";
import { enqueueJob } from "./convert";
import {
  AUDIO_DIR,
  UPLOAD_DIR,
  db,
  newId,
  type BookRow,
  type ChapterRow,
  type JobRow,
  type TrackRow,
} from "./db";
import { importBook } from "./library";
import { getProvider, listProviders } from "./tts";
import type { BookDTO, BookDetailDTO, JobDTO, TrackDTO } from "../shared";

export const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

/**
 * Bun defaults to a 10s idle timeout, which kills a cold voice preview (loading
 * Kokoro takes ~10s) and can cut off a slow first streaming chunk. 255s is the
 * maximum Bun accepts.
 */
export const IDLE_TIMEOUT_SECONDS = 255;

const json = (body: unknown, status = 200) => Response.json(body, { status });
const fail = (message: string, status = 400) => Response.json({ error: message }, { status });

function toBookDTO(row: BookRow): BookDTO {
  const stats = db
    .query("SELECT COUNT(*) AS chapters, COALESCE(SUM(char_count), 0) AS chars FROM chapters WHERE book_id = ?")
    .get(row.id) as { chapters: number; chars: number };

  return {
    id: row.id,
    title: row.title,
    author: row.author,
    format: row.format,
    createdAt: row.created_at,
    chapterCount: stats.chapters,
    charCount: stats.chars,
  };
}

function toJobDTO(job: JobRow): JobDTO {
  const tracks = db.query("SELECT * FROM tracks WHERE job_id = ? ORDER BY idx").all(job.id) as TrackRow[];
  const book = db.query("SELECT title FROM books WHERE id = ?").get(job.book_id) as { title: string } | null;

  return {
    id: job.id,
    bookId: job.book_id,
    bookTitle: book?.title ?? "(deleted)",
    provider: job.provider,
    voice: job.voice,
    speed: job.speed,
    status: job.status,
    error: job.error,
    chunksDone: job.chunks_done,
    chunksTotal: job.chunks_total,
    createdAt: job.created_at,
    finishedAt: job.finished_at,
    tracks: tracks.map<TrackDTO>(t => ({
      id: t.id,
      idx: t.idx,
      title: t.title,
      status: t.status,
      duration: t.duration,
      error: t.error,
      url: t.status === "done" ? `/api/tracks/${t.id}/audio` : null,
    })),
  };
}

/** Serve an audio file with Range support so the browser player can seek. */
async function serveTrackAudio(req: Request, trackId: string): Promise<Response> {
  const track = db.query("SELECT * FROM tracks WHERE id = ?").get(trackId) as TrackRow | null;
  if (!track?.path) return fail("Track not found", 404);

  const file = Bun.file(track.path);
  if (!(await file.exists())) return fail("Audio file is missing on disk", 404);

  const type = track.path.endsWith(".mp3") ? "audio/mpeg" : "audio/wav";
  const size = file.size;
  const range = req.headers.get("range");
  const match = range?.match(/bytes=(\d*)-(\d*)/);

  if (match) {
    const start = match[1] ? Number(match[1]) : 0;
    const end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
    if (!Number.isFinite(start) || start >= size || start > end) {
      return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
    }
    return new Response(file.slice(start, end + 1), {
      status: 206,
      headers: {
        "Content-Type": type,
        "Content-Length": String(end - start + 1),
        "Content-Range": `bytes ${start}-${end}/${size}`,
        "Accept-Ranges": "bytes",
      },
    });
  }

  return new Response(file, {
    headers: { "Content-Type": type, "Content-Length": String(size), "Accept-Ranges": "bytes" },
  });
}

export const apiRoutes = {
  "/api/providers": async () => json(await listProviders()),

  "/api/providers/:id/preview": (req: Bun.BunRequest<"/api/providers/:id/preview">) =>
    serveVoicePreview(req.params.id, new URL(req.url).searchParams.get("voice") ?? ""),

  "/api/chapters/:id/stream": (req: Bun.BunRequest<"/api/chapters/:id/stream">) =>
    streamChapter(req, req.params.id),

  "/api/books": {
    GET: () => {
      const rows = db.query("SELECT * FROM books ORDER BY created_at DESC").all() as BookRow[];
      return json(rows.map(toBookDTO));
    },

    POST: async (req: Request) => {
      const form = await req.formData();
      const file = form.get("file");
      if (!(file instanceof File)) return fail("Expected a 'file' field");
      // No extension gate here: extractBook sniffs the actual bytes, because
      // browsers rename things on the way in (a dragged folder arrives as .zip).

      try {
        return json(toBookDTO(await importBook(file, file.name)), 201);
      } catch (error) {
        return fail(error instanceof Error ? error.message : "Could not read that file", 422);
      }
    },
  },

  "/api/books/:id": {
    GET: (req: Bun.BunRequest<"/api/books/:id">) => {
      const row = db.query("SELECT * FROM books WHERE id = ?").get(req.params.id) as BookRow | null;
      if (!row) return fail("Book not found", 404);

      const chapters = db
        .query("SELECT * FROM chapters WHERE book_id = ? ORDER BY idx")
        .all(row.id) as ChapterRow[];

      const detail: BookDetailDTO = {
        ...toBookDTO(row),
        chapters: chapters.map(c => ({
          id: c.id,
          idx: c.idx,
          title: c.title,
          charCount: c.char_count,
          preview: c.text.slice(0, 240).replace(/\s+/g, " ").trim(),
        })),
      };
      return json(detail);
    },

    DELETE: async (req: Bun.BunRequest<"/api/books/:id">) => {
      const row = db.query("SELECT * FROM books WHERE id = ?").get(req.params.id) as BookRow | null;
      if (!row) return fail("Book not found", 404);

      const jobs = db.query("SELECT id FROM jobs WHERE book_id = ?").all(row.id) as { id: string }[];
      db.query("DELETE FROM books WHERE id = ?").run(row.id); // cascades to chapters/jobs/tracks

      await rm(path.join(UPLOAD_DIR, row.id), { recursive: true, force: true });
      for (const job of jobs) await rm(path.join(AUDIO_DIR, job.id), { recursive: true, force: true });

      return json({ ok: true });
    },
  },

  "/api/books/:id/convert": {
    POST: async (req: Bun.BunRequest<"/api/books/:id/convert">) => {
      const book = db.query("SELECT * FROM books WHERE id = ?").get(req.params.id) as BookRow | null;
      if (!book) return fail("Book not found", 404);

      const body = (await req.json().catch(() => ({}))) as {
        provider?: string;
        voice?: string;
        speed?: number;
        chapterIds?: string[];
      };

      const providerId = body.provider ?? "kokoro";
      let info;
      try {
        info = await getProvider(providerId).info();
      } catch (error) {
        return fail(error instanceof Error ? error.message : "Unknown provider");
      }
      if (!info.available) return fail(info.reason ?? `${info.label} is not available`, 409);

      const voice = body.voice || info.defaultVoice;
      if (!voice) return fail("No voice selected");
      const speed = Math.min(2, Math.max(0.5, Number(body.speed) || 1));

      const all = db.query("SELECT * FROM chapters WHERE book_id = ? ORDER BY idx").all(book.id) as ChapterRow[];
      const wanted = body.chapterIds?.length ? new Set(body.chapterIds) : null;
      const chapters = wanted ? all.filter(c => wanted.has(c.id)) : all;
      if (chapters.length === 0) return fail("No chapters selected");

      const jobId = newId("job");
      const insertTrack = db.query(
        "INSERT INTO tracks (id, job_id, chapter_id, idx, title, status) VALUES (?, ?, ?, ?, ?, 'pending')",
      );

      db.transaction(() => {
        db.query(
          "INSERT INTO jobs (id, book_id, provider, voice, speed, status, created_at) VALUES (?, ?, ?, ?, ?, 'queued', ?)",
        ).run(jobId, book.id, providerId, voice, speed, Date.now());
        chapters.forEach((chapter, idx) => {
          insertTrack.run(newId("tr"), jobId, chapter.id, idx, chapter.title);
        });
      })();

      enqueueJob(jobId);

      const job = db.query("SELECT * FROM jobs WHERE id = ?").get(jobId) as JobRow;
      return json(toJobDTO(job), 201);
    },
  },

  "/api/jobs": () => {
    const rows = db.query("SELECT * FROM jobs ORDER BY created_at DESC LIMIT 50").all() as JobRow[];
    return json(rows.map(toJobDTO));
  },

  "/api/jobs/:id": (req: Bun.BunRequest<"/api/jobs/:id">) => {
    const job = db.query("SELECT * FROM jobs WHERE id = ?").get(req.params.id) as JobRow | null;
    return job ? json(toJobDTO(job)) : fail("Job not found", 404);
  },

  "/api/jobs/:id/cancel": {
    POST: (req: Bun.BunRequest<"/api/jobs/:id/cancel">) => {
      const job = db.query("SELECT * FROM jobs WHERE id = ?").get(req.params.id) as JobRow | null;
      if (!job) return fail("Job not found", 404);
      if (job.status === "done" || job.status === "error") return fail("Job already finished", 409);

      db.query("UPDATE jobs SET status = 'cancelled', finished_at = ? WHERE id = ?").run(Date.now(), job.id);
      return json({ ok: true });
    },
  },

  "/api/jobs/:id/download": async (req: Bun.BunRequest<"/api/jobs/:id/download">) => {
    const job = db.query("SELECT * FROM jobs WHERE id = ?").get(req.params.id) as JobRow | null;
    if (!job) return fail("Job not found", 404);

    const tracks = db
      .query("SELECT * FROM tracks WHERE job_id = ? AND status = 'done' ORDER BY idx")
      .all(job.id) as TrackRow[];
    if (tracks.length === 0) return fail("Nothing to download yet", 409);

    const book = db.query("SELECT title FROM books WHERE id = ?").get(job.book_id) as { title: string } | null;
    const entries: Record<string, Uint8Array> = {};
    for (const track of tracks) {
      if (!track.path) continue;
      entries[path.basename(track.path)] = new Uint8Array(await Bun.file(track.path).arrayBuffer());
    }

    const zip = zipSync(entries, { level: 0 }); // audio is already compressed
    const name = (book?.title ?? "audiobook").replace(/[^\w.-]+/g, "_");
    return new Response(zip, {
      headers: {
        "Content-Type": "application/zip",
        "Content-Disposition": `attachment; filename="${name}.zip"`,
      },
    });
  },

  "/api/tracks/:id/audio": (req: Bun.BunRequest<"/api/tracks/:id/audio">) => serveTrackAudio(req, req.params.id),

} as const;
