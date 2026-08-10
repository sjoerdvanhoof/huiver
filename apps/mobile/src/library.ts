import { useCallback, useEffect, useState } from "react";
import { listBooks, listChapters, type BookSummary, type ChapterWithTrack } from "./db/queries";
import { useConversionProgress } from "./convert/engine";
import { usePlayer } from "./player/store";

/**
 * SQLite is local and fast, so screens simply re-read it rather than keeping a
 * cache in sync. Re-reads are triggered by the two things that change the
 * library underneath a screen: a conversion making progress, and the player
 * moving to another chapter.
 */

export function useLibrary(): { books: BookSummary[]; reload: () => void } {
  const [books, setBooks] = useState<BookSummary[]>(() => listBooks());
  const progress = useConversionProgress();
  const chapterId = usePlayer(state => state.queue[state.index]?.chapterId ?? null);

  const reload = useCallback(() => setBooks(listBooks()), []);

  useEffect(reload, [reload, progress?.chunksDone, progress?.chapterId, chapterId]);

  return { books, reload };
}

export function useChapters(bookId: string): { chapters: ChapterWithTrack[]; reload: () => void } {
  const [chapters, setChapters] = useState<ChapterWithTrack[]>(() => listChapters(bookId));
  const progress = useConversionProgress();
  const position = usePlayer(state => Math.floor(state.position / 5));

  const reload = useCallback(() => setChapters(listChapters(bookId)), [bookId]);

  useEffect(reload, [reload, progress?.chunksDone, progress?.chapterId, position]);

  return { chapters, reload };
}
