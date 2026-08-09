import type { Database } from "bun:sqlite";
import type { BookProgressDTO, ResumePointDTO } from "../shared";
import { db as defaultDb, type PlaybackPositionRow } from "./db";

/**
 * Kokoro at speed 1.0 reads roughly 16 characters per second (~150 wpm).
 * Used until real conversions teach us the actual rate.
 */
export const FALLBACK_CPS = 16;
const MIN_CPS = 5;
const MAX_CPS = 40;

/** A chapter finished within this many seconds of the end counts as completed. */
const COMPLETION_SLACK_SECONDS = 10;

type ChapterLite = { id: string; book_id: string; idx: number; title: string; char_count: number };

type BestTrack = { track_id: string; duration: number | null; speed: number };

export type ChapterAugment = {
  estimatedDurationSeconds: number;
  audio: { trackId: string; url: string; duration: number | null } | null;
  position: { positionSeconds: number; completed: boolean; updatedAt: number } | null;
};

export type BookRollup = {
  chapterCount: number;
  charCount: number;
  progress: BookProgressDTO;
  chapters: Map<string, ChapterAugment>;
};

/** Newest finished track per chapter, plus rate inputs, in one query. */
function loadDoneTracks(database: Database, bookId?: string) {
  const sql = `
    SELECT t.chapter_id AS chapter_id, c.book_id AS book_id, t.id AS track_id,
           t.duration AS duration, j.speed AS speed, c.char_count AS char_count
    FROM tracks t
    JOIN chapters c ON c.id = t.chapter_id
    JOIN jobs j ON j.id = t.job_id
    WHERE t.status = 'done' AND t.path IS NOT NULL ${bookId ? "AND c.book_id = ?" : ""}
    ORDER BY j.created_at ASC, t.id ASC
  `;
  return (bookId ? database.query(sql).all(bookId) : database.query(sql).all()) as Array<
    BestTrack & { chapter_id: string; book_id: string; char_count: number }
  >;
}

const clampCps = (cps: number) => Math.min(MAX_CPS, Math.max(MIN_CPS, cps));

/**
 * Observed reading rate, normalized to synthesis speed 1.0: a track rendered
 * at speed s covers chars in duration seconds, so the speed-1 rate is
 * chars / (duration * s).
 */
function rateFrom(rows: Array<{ duration: number | null; speed: number; char_count: number }>): number | null {
  let chars = 0;
  let seconds = 0;
  for (const row of rows) {
    if (!row.duration || row.duration <= 0) continue;
    chars += row.char_count;
    seconds += row.duration * (row.speed || 1);
  }
  if (seconds <= 0 || chars <= 0) return null;
  return clampCps(chars / seconds);
}

/** Chars-per-second at speed 1.0 for estimating unconverted chapters. */
export function charsPerSecond(database: Database = defaultDb, bookId?: string): number {
  if (bookId) {
    const own = rateFrom(loadDoneTracks(database, bookId));
    if (own !== null) return own;
  }
  return rateFrom(loadDoneTracks(database)) ?? FALLBACK_CPS;
}

/**
 * Everything the book views need — conversion status, listening progress,
 * per-chapter durations and positions — computed in a handful of batched
 * queries instead of one round-trip per book.
 */
export function computeRollups(database: Database = defaultDb, bookId?: string): Map<string, BookRollup> {
  const chapterSql =
    "SELECT id, book_id, idx, title, char_count FROM chapters" + (bookId ? " WHERE book_id = ?" : "") + " ORDER BY book_id, idx";
  const chapters = (bookId
    ? database.query(chapterSql).all(bookId)
    : database.query(chapterSql).all()) as ChapterLite[];

  const doneTracks = loadDoneTracks(database, bookId);
  const globalRateRows = bookId ? loadDoneTracks(database) : doneTracks;
  const globalRate = rateFrom(globalRateRows) ?? FALLBACK_CPS;

  // Newest wins: rows arrive oldest-first, later set() calls overwrite.
  const bestByChapter = new Map<string, BestTrack>();
  const rateRowsByBook = new Map<string, typeof doneTracks>();
  for (const row of doneTracks) {
    bestByChapter.set(row.chapter_id, row);
    const list = rateRowsByBook.get(row.book_id);
    if (list) list.push(row);
    else rateRowsByBook.set(row.book_id, [row]);
  }

  const positionSql =
    "SELECT * FROM playback_positions" + (bookId ? " WHERE book_id = ?" : "");
  const positions = (bookId
    ? database.query(positionSql).all(bookId)
    : database.query(positionSql).all()) as PlaybackPositionRow[];
  const positionByChapter = new Map(positions.map(p => [p.chapter_id, p]));

  const chaptersByBook = new Map<string, ChapterLite[]>();
  for (const chapter of chapters) {
    const list = chaptersByBook.get(chapter.book_id);
    if (list) list.push(chapter);
    else chaptersByBook.set(chapter.book_id, [chapter]);
  }

  const rollups = new Map<string, BookRollup>();

  for (const [id, bookChapters] of chaptersByBook) {
    const rate = rateFrom(rateRowsByBook.get(id) ?? []) ?? globalRate;

    let totalSeconds = 0;
    let convertedSeconds = 0;
    let listenedSeconds = 0;
    let converted = 0;
    let completed = 0;
    let charCount = 0;
    const augments = new Map<string, ChapterAugment>();

    // The freshest position row decides where "continue listening" points.
    let latest: { chapter: ChapterLite; position: PlaybackPositionRow } | null = null;

    for (const chapter of bookChapters) {
      charCount += chapter.char_count;
      const best = bestByChapter.get(chapter.id);
      const duration = best?.duration && best.duration > 0 ? best.duration : chapter.char_count / rate;
      totalSeconds += duration;
      if (best) {
        converted++;
        convertedSeconds += duration;
      }

      const position = positionByChapter.get(chapter.id);
      if (position) {
        if (position.completed) completed++;
        listenedSeconds += position.completed ? duration : Math.min(position.position_seconds, duration);
        if (!latest || position.updated_at > latest.position.updated_at) latest = { chapter, position };
      }

      augments.set(chapter.id, {
        estimatedDurationSeconds: duration,
        audio: best
          ? { trackId: best.track_id, url: `/api/tracks/${best.track_id}/audio`, duration: best.duration }
          : null,
        position: position
          ? {
              positionSeconds: position.position_seconds,
              completed: position.completed === 1,
              updatedAt: position.updated_at,
            }
          : null,
      });
    }

    rollups.set(id, {
      chapterCount: bookChapters.length,
      charCount,
      chapters: augments,
      progress: {
        conversionStatus: converted === 0 ? "none" : converted === bookChapters.length ? "full" : "partial",
        convertedChapters: converted,
        completedChapters: completed,
        percentListened: totalSeconds > 0 ? Math.min(1, listenedSeconds / totalSeconds) : 0,
        estimatedTotalSeconds: totalSeconds,
        convertedSeconds,
        lastPlayedAt: latest?.position.updated_at ?? null,
        resume: latest ? resumePoint(bookChapters, bestByChapter, latest.chapter, latest.position) : null,
      },
    });
  }

  // Books with zero chapters still deserve a rollup (shouldn't happen, but cheap).
  return rollups;
}

export const EMPTY_PROGRESS: BookProgressDTO = {
  conversionStatus: "none",
  convertedChapters: 0,
  completedChapters: 0,
  percentListened: 0,
  estimatedTotalSeconds: 0,
  convertedSeconds: 0,
  lastPlayedAt: null,
  resume: null,
};

/**
 * A completed chapter resumes at the start of the next one; an unfinished
 * chapter resumes in place, remapping the position if the audio has since
 * been re-converted to a different track.
 */
function resumePoint(
  bookChapters: ChapterLite[],
  bestByChapter: Map<string, BestTrack>,
  chapter: ChapterLite,
  position: PlaybackPositionRow,
): ResumePointDTO | null {
  if (position.completed) {
    const next = bookChapters.find(c => c.idx === chapter.idx + 1);
    if (!next) return null; // Finished the book.
    const best = bestByChapter.get(next.id);
    return {
      chapterId: next.id,
      chapterIdx: next.idx,
      chapterTitle: next.title,
      trackId: best?.track_id ?? null,
      positionSeconds: 0,
      durationSeconds: best?.duration ?? null,
    };
  }

  const best = bestByChapter.get(chapter.id);
  let seconds = position.position_seconds;
  if (best && position.track_id && position.track_id !== best.track_id) {
    // Re-converted since: keep the relative spot.
    if (position.duration_seconds && position.duration_seconds > 0 && best.duration) {
      seconds = (position.position_seconds / position.duration_seconds) * best.duration;
    }
  }
  if (best?.duration) seconds = Math.min(seconds, Math.max(0, best.duration - 1));

  return {
    chapterId: chapter.id,
    chapterIdx: chapter.idx,
    chapterTitle: chapter.title,
    trackId: best?.track_id ?? null,
    positionSeconds: seconds,
    durationSeconds: best?.duration ?? null,
  };
}

export type SavePositionInput = {
  trackId?: string | null;
  positionSeconds: number;
  durationSeconds?: number | null;
  completed?: boolean;
};

// Strictly increasing timestamps: two saves in the same millisecond (pause
// followed by an immediate track change) must still order correctly, because
// "most recent position" decides where Continue Listening points.
let lastSaveTimestamp = 0;
function nextTimestamp(): number {
  lastSaveTimestamp = Math.max(Date.now(), lastSaveTimestamp + 1);
  return lastSaveTimestamp;
}

/** Upsert a playback position. Returns false when the chapter doesn't exist. */
export function savePosition(
  chapterId: string,
  input: SavePositionInput,
  database: Database = defaultDb,
): boolean {
  const chapter = database
    .query("SELECT id, book_id FROM chapters WHERE id = ?")
    .get(chapterId) as { id: string; book_id: string } | null;
  if (!chapter) return false;

  const positionSeconds = Number(input.positionSeconds);
  if (!Number.isFinite(positionSeconds) || positionSeconds < 0) throw new Error("positionSeconds must be >= 0");

  // Only accept a track that actually belongs to this chapter.
  let trackId: string | null = null;
  let trackDuration: number | null = null;
  if (input.trackId) {
    const track = database
      .query("SELECT id, duration FROM tracks WHERE id = ? AND chapter_id = ?")
      .get(input.trackId, chapterId) as { id: string; duration: number | null } | null;
    if (track) {
      trackId = track.id;
      trackDuration = track.duration;
    }
  }

  const duration =
    typeof input.durationSeconds === "number" && Number.isFinite(input.durationSeconds) && input.durationSeconds > 0
      ? input.durationSeconds
      : trackDuration;

  const nearEnd = duration ? positionSeconds >= duration - COMPLETION_SLACK_SECONDS : false;
  const completed = input.completed === true || nearEnd ? 1 : 0;

  database
    .query(
      `INSERT INTO playback_positions (chapter_id, book_id, track_id, position_seconds, duration_seconds, completed, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(chapter_id) DO UPDATE SET
         track_id = excluded.track_id,
         position_seconds = excluded.position_seconds,
         duration_seconds = excluded.duration_seconds,
         completed = MAX(playback_positions.completed, excluded.completed),
         updated_at = excluded.updated_at`,
    )
    .run(chapterId, chapter.book_id, trackId, positionSeconds, duration, completed, nextTimestamp());

  return true;
}
