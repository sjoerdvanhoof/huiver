import { Database } from "bun:sqlite";
import { beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { runMigrations } = await import("./db");
const { FALLBACK_CPS, charsPerSecond, computeRollups, savePosition } = await import("./progress");

let db: Database;
let counter = 0;

beforeEach(() => {
  db = new Database(":memory:");
  runMigrations(db);
  counter = 0;
});

function addBook(id: string): void {
  db.query("INSERT INTO books (id, title, format, source_path, created_at) VALUES (?, ?, 'epub', '/x', ?)").run(
    id,
    `Book ${id}`,
    ++counter,
  );
}

function addChapter(id: string, bookId: string, idx: number, charCount: number): void {
  db.query("INSERT INTO chapters (id, book_id, idx, title, text, char_count) VALUES (?, ?, ?, ?, 'x', ?)").run(
    id,
    bookId,
    idx,
    `Chapter ${idx + 1}`,
    charCount,
  );
}

function addDoneTrack(id: string, bookId: string, chapterId: string, duration: number, speed = 1): void {
  const jobId = `job_${id}`;
  db.query(
    "INSERT INTO jobs (id, book_id, provider, voice, speed, status, created_at) VALUES (?, ?, 'kokoro', 'v', ?, 'done', ?)",
  ).run(jobId, bookId, speed, ++counter);
  db.query(
    "INSERT INTO tracks (id, job_id, chapter_id, idx, title, status, path, duration) VALUES (?, ?, ?, 0, 't', 'done', '/x.mp3', ?)",
  ).run(id, jobId, chapterId, duration);
}

describe("charsPerSecond", () => {
  test("falls back to the constant with no conversions", () => {
    expect(charsPerSecond(db)).toBe(FALLBACK_CPS);
  });

  test("prefers the book's own rate, then global, then fallback", () => {
    addBook("a");
    addChapter("a1", "a", 0, 2000);
    addDoneTrack("ta1", "a", "a1", 100); // 20 cps

    addBook("b");
    addChapter("b1", "b", 0, 1000);
    addDoneTrack("tb1", "b", "b1", 100); // 10 cps

    addBook("c");
    addChapter("c1", "c", 0, 500);

    expect(charsPerSecond(db, "a")).toBe(20);
    expect(charsPerSecond(db, "b")).toBe(10);
    expect(charsPerSecond(db, "c")).toBe(15); // global: 3000 chars / 200 s
  });

  test("normalizes for synthesis speed", () => {
    addBook("a");
    addChapter("a1", "a", 0, 2000);
    // Rendered at 2×, the audio is half as long; the speed-1 rate is still 20 cps.
    addDoneTrack("ta1", "a", "a1", 50, 2);
    expect(charsPerSecond(db, "a")).toBe(20);
  });

  test("clamps degenerate rates", () => {
    addBook("a");
    addChapter("a1", "a", 0, 100000);
    addDoneTrack("ta1", "a", "a1", 10); // 10000 cps — nonsense
    expect(charsPerSecond(db, "a")).toBe(40);
  });
});

describe("savePosition", () => {
  test("inserts, updates, and keeps completed sticky", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1000);

    expect(savePosition("a1", { positionSeconds: 12 }, db)).toBe(true);
    let row = db.query("SELECT * FROM playback_positions WHERE chapter_id = 'a1'").get() as {
      position_seconds: number;
      completed: number;
    };
    expect(row.position_seconds).toBe(12);
    expect(row.completed).toBe(0);

    savePosition("a1", { positionSeconds: 99, completed: true }, db);
    savePosition("a1", { positionSeconds: 3 }, db); // re-listening from the top
    row = db.query("SELECT * FROM playback_positions WHERE chapter_id = 'a1'").get() as {
      position_seconds: number;
      completed: number;
    };
    expect(row.position_seconds).toBe(3);
    expect(row.completed).toBe(1); // sticky
  });

  test("returns false for a missing chapter", () => {
    expect(savePosition("nope", { positionSeconds: 1 }, db)).toBe(false);
  });

  test("rejects a track belonging to another chapter", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1000);
    addChapter("a2", "a", 1, 1000);
    addDoneTrack("t2", "a", "a2", 60);

    savePosition("a1", { trackId: "t2", positionSeconds: 5 }, db);
    const row = db.query("SELECT track_id FROM playback_positions WHERE chapter_id = 'a1'").get() as {
      track_id: string | null;
    };
    expect(row.track_id).toBeNull();
  });

  test("marks near-the-end positions as completed", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1000);
    addDoneTrack("t1", "a", "a1", 100);

    savePosition("a1", { trackId: "t1", positionSeconds: 95 }, db);
    const row = db.query("SELECT completed FROM playback_positions WHERE chapter_id = 'a1'").get() as {
      completed: number;
    };
    expect(row.completed).toBe(1);
  });
});

describe("computeRollups", () => {
  test("mixes real and estimated durations into one progress picture", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);
    addChapter("a2", "a", 1, 3200);
    addChapter("a3", "a", 2, 1600);
    addChapter("a4", "a", 3, 1600);
    addDoneTrack("t1", "a", "a1", 100); // book rate: 4800 chars / 300 s = 16 cps
    addDoneTrack("t2", "a", "a2", 200);

    savePosition("a1", { trackId: "t1", positionSeconds: 100, completed: true }, db);
    savePosition("a2", { trackId: "t2", positionSeconds: 50 }, db);
    // Both saves can land in the same millisecond; make a2 unambiguously newest.
    db.query("UPDATE playback_positions SET updated_at = updated_at + 10 WHERE chapter_id = 'a2'").run();

    const rollup = computeRollups(db, "a").get("a")!;
    const p = rollup.progress;

    expect(p.conversionStatus).toBe("partial");
    expect(p.convertedChapters).toBe(2);
    expect(p.completedChapters).toBe(1);
    expect(p.estimatedTotalSeconds).toBe(500); // 100 + 200 + 2 × (1600/16)
    expect(p.convertedSeconds).toBe(300);
    expect(p.percentListened).toBeCloseTo(150 / 500);
    expect(p.resume?.chapterId).toBe("a2"); // most recent, unfinished
    expect(p.resume?.positionSeconds).toBe(50);

    const a3 = rollup.chapters.get("a3")!;
    expect(a3.estimatedDurationSeconds).toBe(100);
    expect(a3.audio).toBeNull();

    const a1 = rollup.chapters.get("a1")!;
    expect(a1.audio?.trackId).toBe("t1");
    expect(a1.position?.completed).toBe(true);
  });

  test("a completed latest chapter resumes at the start of the next one", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);
    addChapter("a2", "a", 1, 1600);
    addDoneTrack("t1", "a", "a1", 100);
    addDoneTrack("t2", "a", "a2", 100);

    savePosition("a1", { trackId: "t1", positionSeconds: 100, completed: true }, db);

    const resume = computeRollups(db, "a").get("a")!.progress.resume;
    expect(resume?.chapterId).toBe("a2");
    expect(resume?.positionSeconds).toBe(0);
    expect(resume?.trackId).toBe("t2");
  });

  test("finishing the last chapter yields no resume point", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);
    addDoneTrack("t1", "a", "a1", 100);
    savePosition("a1", { trackId: "t1", positionSeconds: 100, completed: true }, db);

    const p = computeRollups(db, "a").get("a")!.progress;
    expect(p.resume).toBeNull();
    expect(p.lastPlayedAt).not.toBeNull();
    expect(p.percentListened).toBe(1);
  });

  test("remaps a position onto a newer conversion by ratio", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);
    addDoneTrack("old", "a", "a1", 100);
    savePosition("a1", { trackId: "old", positionSeconds: 50 }, db);

    addDoneTrack("new", "a", "a1", 200); // re-converted (e.g. slower voice)

    const resume = computeRollups(db, "a").get("a")!.progress.resume;
    expect(resume?.trackId).toBe("new");
    expect(resume?.positionSeconds).toBeCloseTo(100); // 50/100 × 200
  });

  test("newest done track wins per chapter", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);
    addDoneTrack("old", "a", "a1", 100);
    addDoneTrack("new", "a", "a1", 120);

    const rollup = computeRollups(db, "a").get("a")!;
    expect(rollup.chapters.get("a1")!.audio?.trackId).toBe("new");
    expect(rollup.progress.conversionStatus).toBe("full");
  });

  test("books without conversions or listening report cleanly", () => {
    addBook("a");
    addChapter("a1", "a", 0, 1600);

    const p = computeRollups(db, "a").get("a")!.progress;
    expect(p.conversionStatus).toBe("none");
    expect(p.percentListened).toBe(0);
    expect(p.lastPlayedAt).toBeNull();
    expect(p.resume).toBeNull();
    expect(p.estimatedTotalSeconds).toBe(100); // fallback 16 cps
  });
});
