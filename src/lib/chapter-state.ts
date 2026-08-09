import type { ChapterActionState } from "@/components/ChapterAction";
import type { BookDetailDTO, JobDTO } from "../shared";

export type ChapterUiState = {
  state: ChapterActionState;
  detail?: string | null;
  /** 0–1 while converting; null when this chapter's share of a run is unknown. */
  progress?: number | null;
  /** The queued/rendering track, so it can be dropped on its own. */
  cancelTrackId?: string;
};

const ACTIVE = new Set(["queued", "running"]);

/**
 * Fold a chapter's tracks and any active jobs into one displayable state.
 * Only the most recent attempt at a chapter counts, so stopping a conversion —
 * or retrying after a failure — clears the older verdict instead of leaving a
 * stale error badge behind. A cancelled track is the user's decision, not a
 * failure, so it reads as simply "not converted".
 */
export function deriveChapterStates(
  book: Pick<BookDetailDTO, "chapters"> | null,
  jobs: JobDTO[],
): Map<string, ChapterUiState> {
  const map = new Map<string, ChapterUiState>();
  if (!book) return map;

  for (const chapter of book.chapters) {
    map.set(chapter.id, { state: chapter.audio ? "done" : "none" });
  }

  const decided = new Set<string>();

  for (const job of [...jobs].sort((a, b) => b.createdAt - a.createdAt)) {
    const active = ACTIVE.has(job.status);

    for (const track of job.tracks) {
      const base = map.get(track.chapterId);
      if (!base || decided.has(track.chapterId)) continue;
      decided.add(track.chapterId);

      if (active && track.status === "running") {
        map.set(track.chapterId, {
          state: "converting",
          progress: track.chunksTotal > 0 ? Math.min(1, track.chunksDone / track.chunksTotal) : null,
          cancelTrackId: track.id,
        });
      } else if (active && track.status === "pending") {
        map.set(track.chapterId, { state: "queued", cancelTrackId: track.id });
      } else if (track.status === "error" && base.state !== "done") {
        map.set(track.chapterId, { state: "error", detail: track.error });
      }
      // 'cancelled', and leftovers from a stopped run, keep the plain state.
    }
  }
  return map;
}
