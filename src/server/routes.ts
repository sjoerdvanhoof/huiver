import { zipSync } from "fflate";
import { rm } from "node:fs/promises";
import path from "node:path";
import { serveVoicePreview, streamChapter } from "./audio-routes";
import { cancelJobTracks, cancelTrack, enqueueJob } from "./convert";
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
import { extractEpubCover, looksLikeZip } from "./extract";
import { importBook } from "./library";
import { EMPTY_PROGRESS, computeRollups, savePosition, type BookRollup } from "./progress";
import { getSettings, updateSettings } from "./settings";
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

function coverUrlFor(row: BookRow): string | null {
  if (row.cover_path) return `/api/books/${row.id}/cover`;
  // NULL = never checked (pre-cover import); worth one lazy attempt for EPUBs.
  if (row.cover_path === null && row.format === "epub") return `/api/books/${row.id}/cover`;
  return null;
}

function toBookDTO(row: BookRow, rollup: BookRollup | undefined): BookDTO {
  return {
    id: row.id,
    title: row.title,
    author: row.author,
    format: row.format,
    createdAt: row.created_at,
    chapterCount: rollup?.chapterCount ?? 0,
    charCount: rollup?.charCount ?? 0,
    coverUrl: coverUrlFor(row),
    progress: rollup?.progress ?? EMPTY_PROGRESS,
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
      chapterId: t.chapter_id,
      status: t.status,
      duration: t.duration,
      error: t.error,
      url: t.status === "done" ? `/api/tracks/${t.id}/audio` : null,
      chunksDone: t.chunks_done,
      chunksTotal: t.chunks_total,
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

const COVER_TYPES: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
};

/**
 * Serve a book's cover. Books imported before covers existed have
 * cover_path NULL — try to pull one out of the stored EPUB once, then record
 * the outcome ('' = checked, none) so the attempt never repeats.
 */
async function serveCover(bookId: string): Promise<Response> {
  const row = db.query("SELECT * FROM books WHERE id = ?").get(bookId) as BookRow | null;
  if (!row) return fail("Book not found", 404);

  let coverPath = row.cover_path;
  if (coverPath === null) {
    coverPath = "";
    try {
      const bytes = new Uint8Array(await Bun.file(row.source_path).arrayBuffer());
      const cover = looksLikeZip(bytes) ? extractEpubCover(bytes) : null;
      if (cover) {
        coverPath = path.join(UPLOAD_DIR, row.id, `cover.${cover.ext}`);
        await Bun.write(coverPath, cover.bytes);
      }
    } catch {
      // Source file gone or unreadable — record "no cover" below.
    }
    db.query("UPDATE books SET cover_path = ? WHERE id = ?").run(coverPath, row.id);
  }

  if (!coverPath) return fail("No cover", 404);
  const file = Bun.file(coverPath);
  if (!(await file.exists())) return fail("Cover file is missing on disk", 404);

  return new Response(file, {
    headers: {
      "Content-Type": COVER_TYPES[path.extname(coverPath).toLowerCase()] ?? "application/octet-stream",
      "Content-Length": String(file.size),
      "Cache-Control": "public, max-age=86400",
    },
  });
}

export const apiRoutes = {
  "/api/providers": async () => json(await listProviders()),

  "/api/providers/:id/preview": (req: Bun.BunRequest<"/api/providers/:id/preview">) =>
    serveVoicePreview(req.params.id, new URL(req.url).searchParams.get("voice") ?? ""),

  "/api/chapters/:id/stream": (req: Bun.BunRequest<"/api/chapters/:id/stream">) =>
    streamChapter(req, req.params.id),

  "/api/settings": {
    GET: () => json(getSettings()),

    PUT: async (req: Request) => {
      const patch = (await req.json().catch(() => null)) as Record<string, unknown> | null;
      if (!patch || typeof patch !== "object") return fail("Expected a JSON object");
      try {
        return json(updateSettings(patch));
      } catch (error) {
        return fail(error instanceof Error ? error.message : "Invalid settings");
      }
    },
  },

  "/api/chapters/:id/position": {
    // POST (not PUT) so navigator.sendBeacon can deliver the final position on pagehide.
    POST: async (req: Bun.BunRequest<"/api/chapters/:id/position">) => {
      const body = (await req.json().catch(() => null)) as {
        trackId?: string | null;
        positionSeconds?: number;
        durationSeconds?: number | null;
        completed?: boolean;
      } | null;
      if (!body || typeof body.positionSeconds !== "number") return fail("Expected { positionSeconds }");

      try {
        const saved = savePosition(req.params.id, {
          trackId: body.trackId ?? null,
          positionSeconds: body.positionSeconds,
          durationSeconds: body.durationSeconds ?? null,
          completed: body.completed === true,
        });
        return saved ? json({ ok: true }) : fail("Chapter not found", 404);
      } catch (error) {
        return fail(error instanceof Error ? error.message : "Could not save position");
      }
    },
  },

  "/api/books": {
    GET: () => {
      const rows = db.query("SELECT * FROM books ORDER BY created_at DESC").all() as BookRow[];
      const rollups = computeRollups(db);
      return json(rows.map(row => toBookDTO(row, rollups.get(row.id))));
    },

    POST: async (req: Request) => {
      const form = await req.formData();
      const file = form.get("file");
      if (!(file instanceof File)) return fail("Expected a 'file' field");
      // No extension gate here: extractBook sniffs the actual bytes, because
      // browsers rename things on the way in (a dragged folder arrives as .zip).

      try {
        const row = await importBook(file, file.name);
        const rollups = computeRollups(db, row.id);
        return json(toBookDTO(row, rollups.get(row.id)), 201);
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
      const rollup = computeRollups(db, row.id).get(row.id);

      const detail: BookDetailDTO = {
        ...toBookDTO(row, rollup),
        chapters: chapters.map(c => {
          const augment = rollup?.chapters.get(c.id);
          return {
            id: c.id,
            idx: c.idx,
            title: c.title,
            charCount: c.char_count,
            preview: c.text.slice(0, 240).replace(/\s+/g, " ").trim(),
            estimatedDurationSeconds: augment?.estimatedDurationSeconds ?? 0,
            audio: augment?.audio ?? null,
            position: augment?.position ?? null,
          };
        }),
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

  "/api/books/:id/cover": (req: Bun.BunRequest<"/api/books/:id/cover">) => serveCover(req.params.id),

  /** Every converted chapter of a book as one zip, numbered in reading order. */
  "/api/books/:id/download": async (req: Bun.BunRequest<"/api/books/:id/download">) => {
    const book = db.query("SELECT * FROM books WHERE id = ?").get(req.params.id) as BookRow | null;
    if (!book) return fail("Book not found", 404);

    // Oldest job first, so the newest conversion of a chapter overwrites it.
    const rows = db
      .query(
        `SELECT c.idx AS idx, c.title AS title, t.path AS path
         FROM tracks t
         JOIN chapters c ON c.id = t.chapter_id
         JOIN jobs j ON j.id = t.job_id
         WHERE c.book_id = ? AND t.status = 'done' AND t.path IS NOT NULL
         ORDER BY j.created_at ASC, t.id ASC`,
      )
      .all(book.id) as { idx: number; title: string; path: string }[];

    const byChapter = new Map<number, { title: string; path: string }>();
    for (const row of rows) byChapter.set(row.idx, { title: row.title, path: row.path });
    if (byChapter.size === 0) return fail("Nothing converted yet", 409);

    const slug = (value: string) => value.replace(/[^\w.-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 60);
    const entries: Record<string, Uint8Array> = {};
    for (const [idx, track] of [...byChapter].sort((a, b) => a[0] - b[0])) {
      const file = Bun.file(track.path);
      if (!(await file.exists())) continue;
      const name = `${String(idx + 1).padStart(3, "0")}-${slug(track.title) || "chapter"}${path.extname(track.path)}`;
      entries[name] = new Uint8Array(await file.arrayBuffer());
    }

    const zip = zipSync(entries, { level: 0 }); // audio is already compressed
    return new Response(zip, {
      headers: {
        "Content-Type": "application/zip",
        "Content-Disposition": `attachment; filename="${slug(book.title) || "audiobook"}.zip"`,
      },
    });
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

      const settings = getSettings();
      const providerId = body.provider ?? settings.defaultProvider;
      let info;
      try {
        info = await getProvider(providerId).info();
      } catch (error) {
        return fail(error instanceof Error ? error.message : "Unknown provider");
      }
      if (!info.available) return fail(info.reason ?? `${info.label} is not available`, 409);

      const voice = body.voice || settings.defaultVoice || info.defaultVoice;
      if (!voice) return fail("No voice selected");
      // Always render at 1.0 unless a caller explicitly asks otherwise: the
      // player changes playback speed without re-synthesizing anything.
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
      cancelJobTracks(job.id); // stop the render and clear the rest of the queue
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

  /** Remove one chapter from the conversion queue. */
  "/api/tracks/:id/cancel": {
    POST: (req: Bun.BunRequest<"/api/tracks/:id/cancel">) => {
      const track = db.query("SELECT id FROM tracks WHERE id = ?").get(req.params.id) as { id: string } | null;
      if (!track) return fail("Track not found", 404);
      return cancelTrack(track.id) ? json({ ok: true }) : fail("That chapter is already finished", 409);
    },
  },

} as const;
