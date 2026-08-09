import { api } from "../lib/api";
import type { BookDTO, BookDetailDTO, SettingsDTO } from "../shared";
import {
  buildQueueFromBook,
  getPlayerState,
  liveStreamUrl,
  loadPaused,
  playQueue,
  replaceQueue,
  type QueueItem,
} from "./store";

/** A single-item queue from a book's resume point, buildable without the book detail. */
function resumeItem(book: BookDTO, settings: SettingsDTO): QueueItem | null {
  const resume = book.progress.resume;
  if (!resume) return null;
  return {
    bookId: book.id,
    bookTitle: book.title,
    author: book.author,
    coverUrl: book.coverUrl,
    chapterId: resume.chapterId,
    chapterIdx: resume.chapterIdx,
    chapterTitle: resume.chapterTitle,
    source: resume.trackId
      ? {
          kind: "track",
          url: `/api/tracks/${resume.trackId}/audio`,
          trackId: resume.trackId,
          duration: resume.durationSeconds,
        }
      : {
          kind: "live",
          url: liveStreamUrl(resume.chapterId, settings),
          estimatedDuration: resume.durationSeconds ?? 0,
        },
  };
}

/** Fill in the rest of the book around whatever is playing, without interrupting it. */
function extendWithDetail(bookId: string, settings: SettingsDTO): void {
  void api<BookDetailDTO>(`/api/books/${bookId}`)
    .then(detail => replaceQueue(buildQueueFromBook(detail, settings)))
    .catch(() => undefined);
}

/**
 * "Continue listening" tap: playback must start synchronously inside the user
 * gesture (iOS blocks play() after an await), so start with a one-item queue
 * and swap in the full book afterwards.
 */
export function playResume(book: BookDTO, settings: SettingsDTO): boolean {
  const item = resumeItem(book, settings);
  if (!item) return false;
  const position =
    item.source.kind === "track" && book.progress.resume!.positionSeconds > 0
      ? book.progress.resume!.positionSeconds
      : null;
  playQueue([item], 0, position);
  extendWithDetail(book.id, settings);
  return true;
}

/**
 * Cold-load restore: put the most recently played book into the mini-player,
 * paused at its saved spot, so one tap picks the session back up.
 */
export async function restoreLastSession(): Promise<void> {
  if (getPlayerState().index >= 0) return;
  try {
    const [books, settings] = await Promise.all([
      api<BookDTO[]>("/api/books"),
      api<SettingsDTO>("/api/settings"),
    ]);

    const latest = books
      .filter(b => b.progress.lastPlayedAt !== null && b.progress.resume)
      .sort((a, b) => (b.progress.lastPlayedAt ?? 0) - (a.progress.lastPlayedAt ?? 0))[0];
    if (!latest) return;

    const detail = await api<BookDetailDTO>(`/api/books/${latest.id}`);
    const queue = buildQueueFromBook(detail, settings);
    const resume = latest.progress.resume!;
    const index = queue.findIndex(q => q.chapterId === resume.chapterId);
    if (index < 0 || getPlayerState().index >= 0) return;

    loadPaused(queue, index, resume.positionSeconds > 0 ? resume.positionSeconds : null);
  } catch {
    // Restoring is best-effort; a fresh page is fine too.
  }
}
