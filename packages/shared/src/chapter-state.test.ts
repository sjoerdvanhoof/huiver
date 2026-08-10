import { describe, expect, test } from "bun:test";
import { deriveChapterStates } from "./chapter-state";
import type { BookDetailDTO, JobDTO, TrackDTO } from "./dto";

const chapter = (id: string, idx: number, converted = false): BookDetailDTO["chapters"][number] => ({
  id,
  idx,
  title: `Chapter ${idx + 1}`,
  charCount: 1000,
  preview: "…",
  estimatedDurationSeconds: 60,
  audio: converted ? { trackId: `tr_done_${id}`, url: `/api/tracks/tr_done_${id}/audio`, duration: 60 } : null,
  position: null,
});

const track = (over: Partial<TrackDTO> & { chapterId: string }): TrackDTO => ({
  id: `tr_${over.chapterId}`,
  idx: 0,
  title: "t",
  status: "pending",
  duration: null,
  error: null,
  url: null,
  chunksDone: 0,
  chunksTotal: 10,
  ...over,
});

const job = (over: Partial<JobDTO> & { tracks: TrackDTO[] }): JobDTO => ({
  id: "job_1",
  bookId: "bk_1",
  bookTitle: "Book",
  provider: "kokoro",
  voice: "af_heart",
  speed: 1,
  status: "running",
  error: null,
  chunksDone: 0,
  chunksTotal: 10,
  createdAt: 1,
  finishedAt: null,
  ...over,
});

const book = { chapters: [chapter("c1", 0), chapter("c2", 1)] };

describe("deriveChapterStates", () => {
  test("reports queued and converting chapters with progress", () => {
    const states = deriveChapterStates(book, [
      job({
        tracks: [
          track({ chapterId: "c1", id: "tr_a", status: "running", chunksDone: 3, chunksTotal: 12 }),
          track({ chapterId: "c2", id: "tr_b", status: "pending" }),
        ],
      }),
    ]);

    expect(states.get("c1")).toEqual({ state: "converting", progress: 0.25, cancelTrackId: "tr_a" });
    expect(states.get("c2")).toEqual({ state: "queued", cancelTrackId: "tr_b" });
  });

  test("a cancelled chapter reads as not converted, never as an error", () => {
    const states = deriveChapterStates(book, [
      job({ status: "cancelled", tracks: [track({ chapterId: "c1", status: "cancelled" })] }),
    ]);
    expect(states.get("c1")!.state).toBe("none");
  });

  test("stopping after a previous failure clears the error badge", () => {
    const states = deriveChapterStates(book, [
      job({ id: "job_old", createdAt: 1, status: "error", tracks: [track({ chapterId: "c1", status: "error", error: "boom" })] }),
      job({ id: "job_new", createdAt: 2, status: "cancelled", tracks: [track({ chapterId: "c1", status: "cancelled" })] }),
    ]);
    expect(states.get("c1")!.state).toBe("none");
  });

  test("a leftover pending track from a stopped run is not shown as queued", () => {
    const states = deriveChapterStates(book, [
      job({ status: "cancelled", tracks: [track({ chapterId: "c1", status: "pending" })] }),
    ]);
    expect(states.get("c1")!.state).toBe("none");
  });

  test("a genuine failure still surfaces, with its message", () => {
    const states = deriveChapterStates(book, [
      job({ status: "error", tracks: [track({ chapterId: "c1", status: "error", error: "worker died" })] }),
    ]);
    expect(states.get("c1")).toEqual({ state: "error", detail: "worker died" });
  });

  test("re-queuing a failed chapter overrides the old error", () => {
    const states = deriveChapterStates(book, [
      job({ id: "job_old", createdAt: 1, status: "error", tracks: [track({ chapterId: "c1", status: "error", error: "boom" })] }),
      job({ id: "job_new", createdAt: 2, status: "queued", tracks: [track({ chapterId: "c1", id: "tr_new", status: "pending" })] }),
    ]);
    expect(states.get("c1")).toEqual({ state: "queued", cancelTrackId: "tr_new" });
  });

  test("existing audio wins over a later failed attempt", () => {
    const converted = { chapters: [chapter("c1", 0, true)] };
    const states = deriveChapterStates(converted, [
      job({ status: "error", tracks: [track({ chapterId: "c1", status: "error", error: "boom" })] }),
    ]);
    expect(states.get("c1")!.state).toBe("done");
  });
});
