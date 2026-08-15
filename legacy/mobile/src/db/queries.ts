import { db, newId, type BookRow, type ChapterRow, type PlaybackPositionRow, type TrackRow } from ".";
import { deleteChapterAudio } from "../files";

/** Reads and writes over the library. Everything the screens need, in one place. */

export type BookSummary = BookRow & {
  chapterCount: number;
  convertedCount: number;
  charCount: number;
  /** Seconds of audio already rendered. */
  durationSeconds: number;
};

export function listBooks(): BookSummary[] {
  return db.getAllSync<BookSummary>(`
    SELECT b.*,
           COUNT(c.id)                                          AS chapterCount,
           COALESCE(SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END), 0) AS convertedCount,
           COALESCE(SUM(c.char_count), 0)                       AS charCount,
           COALESCE(SUM(CASE WHEN t.status = 'done' THEN t.duration ELSE 0 END), 0) AS durationSeconds
    FROM books b
    LEFT JOIN chapters c ON c.book_id = b.id
    LEFT JOIN tracks t   ON t.chapter_id = c.id
    GROUP BY b.id
    ORDER BY b.created_at DESC
  `);
}

export const getBook = (bookId: string): BookRow | null =>
  db.getFirstSync<BookRow>("SELECT * FROM books WHERE id = ?", [bookId]);

export type ChapterWithTrack = ChapterRow & {
  track: TrackRow | null;
  position: PlaybackPositionRow | null;
};

export function listChapters(bookId: string): ChapterWithTrack[] {
  const chapters = db.getAllSync<ChapterRow>("SELECT * FROM chapters WHERE book_id = ? ORDER BY idx", [bookId]);
  const tracks = new Map(
    db
      .getAllSync<TrackRow>(
        "SELECT t.* FROM tracks t JOIN chapters c ON c.id = t.chapter_id WHERE c.book_id = ?",
        [bookId],
      )
      .map(row => [row.chapter_id, row]),
  );
  const positions = new Map(
    db
      .getAllSync<PlaybackPositionRow>("SELECT * FROM playback_positions WHERE book_id = ?", [bookId])
      .map(row => [row.chapter_id, row]),
  );

  return chapters.map(chapter => ({
    ...chapter,
    track: tracks.get(chapter.id) ?? null,
    position: positions.get(chapter.id) ?? null,
  }));
}

export const getChapter = (chapterId: string): ChapterRow | null =>
  db.getFirstSync<ChapterRow>("SELECT * FROM chapters WHERE id = ?", [chapterId]);

export const getTrack = (chapterId: string): TrackRow | null =>
  db.getFirstSync<TrackRow>("SELECT * FROM tracks WHERE chapter_id = ?", [chapterId]);

/**
 * Create or reset a chapter's track. A chapter has at most one, so re-queueing
 * it at another voice replaces the old verdict rather than stacking up rows.
 */
export function upsertTrack(args: {
  chapterId: string;
  voice: string;
  speed: number;
  chunksTotal: number;
  resumeKey: string;
  chunksDone: number;
}): TrackRow {
  const existing = getTrack(args.chapterId);
  const id = existing?.id ?? newId("tr");

  db.runSync(
    `INSERT INTO tracks (id, chapter_id, voice, speed, status, path, duration, error,
                         chunks_done, chunks_total, resume_key, updated_at)
     VALUES (?, ?, ?, ?, 'running', NULL, NULL, NULL, ?, ?, ?, ?)
     ON CONFLICT(chapter_id) DO UPDATE SET
       voice = excluded.voice, speed = excluded.speed, status = 'running',
       path = NULL, duration = NULL, error = NULL,
       chunks_done = excluded.chunks_done, chunks_total = excluded.chunks_total,
       resume_key = excluded.resume_key, updated_at = excluded.updated_at`,
    [id, args.chapterId, args.voice, args.speed, args.chunksDone, args.chunksTotal, args.resumeKey, Date.now()],
  );

  return getTrack(args.chapterId)!;
}

export function setTrackProgress(chapterId: string, chunksDone: number): void {
  db.runSync("UPDATE tracks SET chunks_done = ?, updated_at = ? WHERE chapter_id = ?", [
    chunksDone,
    Date.now(),
    chapterId,
  ]);
}

export function finishTrack(chapterId: string, path: string, durationSeconds: number): void {
  db.runSync(
    "UPDATE tracks SET status = 'done', path = ?, duration = ?, error = NULL, updated_at = ? WHERE chapter_id = ?",
    [path, durationSeconds, Date.now(), chapterId],
  );
}

export function failTrack(chapterId: string, message: string): void {
  db.runSync("UPDATE tracks SET status = 'error', error = ?, updated_at = ? WHERE chapter_id = ?", [
    message,
    Date.now(),
    chapterId,
  ]);
}

export function cancelTrack(chapterId: string): void {
  // Stopping is a pause, not a discard: the chunk files stay on disk so the
  // next run picks up where this one left off.
  db.runSync("UPDATE tracks SET status = 'cancelled', updated_at = ? WHERE chapter_id = ?", [Date.now(), chapterId]);
}

/** Tracks left mid-render by a crash or a background kill. */
export const interruptedTracks = (): TrackRow[] =>
  db.getAllSync<TrackRow>("SELECT * FROM tracks WHERE status = 'running'");

/** Tracks whose audio is complete, so their chunk files can go. */
export const finishedTracks = (): TrackRow[] =>
  db.getAllSync<TrackRow>("SELECT * FROM tracks WHERE status = 'done'");

export function savePosition(args: {
  chapterId: string;
  bookId: string;
  positionSeconds: number;
  durationSeconds: number | null;
  completed: boolean;
}): void {
  db.runSync(
    `INSERT INTO playback_positions (chapter_id, book_id, position_seconds, duration_seconds, completed, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(chapter_id) DO UPDATE SET
       position_seconds = excluded.position_seconds,
       duration_seconds = COALESCE(excluded.duration_seconds, playback_positions.duration_seconds),
       completed = excluded.completed,
       updated_at = excluded.updated_at`,
    [
      args.chapterId,
      args.bookId,
      args.positionSeconds,
      args.durationSeconds,
      args.completed ? 1 : 0,
      Date.now(),
    ],
  );
}

export const getPosition = (chapterId: string): PlaybackPositionRow | null =>
  db.getFirstSync<PlaybackPositionRow>("SELECT * FROM playback_positions WHERE chapter_id = ?", [chapterId]);

/** The spot to offer as "continue listening": most recent, not finished. */
export function lastPosition(bookId?: string): PlaybackPositionRow | null {
  return bookId
    ? db.getFirstSync<PlaybackPositionRow>(
        "SELECT * FROM playback_positions WHERE book_id = ? AND completed = 0 ORDER BY updated_at DESC LIMIT 1",
        [bookId],
      )
    : db.getFirstSync<PlaybackPositionRow>(
        "SELECT * FROM playback_positions WHERE completed = 0 ORDER BY updated_at DESC LIMIT 1",
      );
}

export function deleteBook(bookId: string): void {
  // Audio first: once the rows are gone there is no way to find the files.
  for (const chapter of db.getAllSync<{ id: string }>("SELECT id FROM chapters WHERE book_id = ?", [bookId])) {
    deleteChapterAudio(chapter.id);
  }
  db.runSync("DELETE FROM books WHERE id = ?", [bookId]);
}
