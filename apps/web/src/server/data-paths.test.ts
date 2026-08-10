import { describe, expect, test } from "bun:test";
import { rebaseDataPath, repairDataPaths, type PathStore } from "./data-paths";

const OLD = "/Users/someone/huiver/data";
const NEW = "/Users/someone/huiver/apps/web/data";

describe("rebaseDataPath", () => {
  test("re-roots a path from a data directory that has moved", () => {
    // The move that broke a real library: data/ went into apps/web/.
    expect(rebaseDataPath(`${OLD}/uploads/bk_1/alice.epub`, NEW)).toBe(`${NEW}/uploads/bk_1/alice.epub`);
    expect(rebaseDataPath(`${OLD}/audio/job_1/001-one.mp3`, NEW)).toBe(`${NEW}/audio/job_1/001-one.mp3`);
    expect(rebaseDataPath(`${OLD}/streams/ch_1-abc.wav`, NEW)).toBe(`${NEW}/streams/ch_1-abc.wav`);
    expect(rebaseDataPath(`${OLD}/previews/kokoro-af_heart.mp3`, NEW)).toBe(`${NEW}/previews/kokoro-af_heart.mp3`);
  });

  test("leaves a path that already points at the data directory", () => {
    expect(rebaseDataPath(`${NEW}/uploads/bk_1/alice.epub`, NEW)).toBeNull();
  });

  test("ignores a path that never came from a data directory", () => {
    expect(rebaseDataPath("/tmp/somewhere/else.epub", NEW)).toBeNull();
  });

  test("the last matching segment wins", () => {
    // A data directory that itself lives under a folder called "audio" must not
    // send the search off at the wrong segment.
    const stored = "/Users/someone/audio/huiver/data/audio/job_1/001-one.mp3";
    expect(rebaseDataPath(stored, "/elsewhere/data")).toBe("/elsewhere/data/audio/job_1/001-one.mp3");
  });

  test("keeps names containing spaces and colons intact", () => {
    const stored = `${OLD}/uploads/bk_1/Private Equity: A Memoir.epub.zip`;
    expect(rebaseDataPath(stored, NEW)).toBe(`${NEW}/uploads/bk_1/Private Equity: A Memoir.epub.zip`);
  });
});

/** An in-memory stand-in for the path columns across the schema. */
function fakeStore(rows: Record<string, { key: string; value: string }[]>) {
  const updates: { at: string; key: string; value: string }[] = [];
  const store: PathStore = {
    rows: (table, column) => rows[`${table}.${column}`] ?? [],
    update: (table, column, _key, keyValue, value) => {
      updates.push({ at: `${table}.${column}`, key: keyValue, value });
    },
  };
  return { store, updates };
}

describe("repairDataPaths", () => {
  test("re-roots broken paths and reports how many", () => {
    const { store, updates } = fakeStore({
      "books.source_path": [{ key: "bk_1", value: `${OLD}/uploads/bk_1/alice.epub` }],
      "books.cover_path": [{ key: "bk_1", value: `${OLD}/uploads/bk_1/cover.jpg` }],
      "tracks.path": [{ key: "tr_1", value: `${OLD}/audio/job_1/001-one.mp3` }],
    });

    // Only files under the new root are on disk.
    const repaired = repairDataPaths(store, NEW, candidate => candidate.startsWith(NEW));

    expect(repaired).toBe(3);
    expect(updates.map(u => u.value)).toEqual([
      `${NEW}/uploads/bk_1/alice.epub`,
      `${NEW}/uploads/bk_1/cover.jpg`,
      `${NEW}/audio/job_1/001-one.mp3`,
    ]);
  });

  test("never touches a path whose file is present", () => {
    const { store, updates } = fakeStore({
      "books.source_path": [{ key: "bk_1", value: `${OLD}/uploads/bk_1/alice.epub` }],
    });

    const repaired = repairDataPaths(store, NEW, () => true);

    expect(repaired).toBe(0);
    expect(updates).toEqual([]);
  });

  test("leaves a genuinely deleted file alone rather than inventing a path", () => {
    // Nothing exists anywhere: rewriting would only swap one dead path for
    // another and hide the real problem.
    const { store, updates } = fakeStore({
      "tracks.path": [{ key: "tr_1", value: `${OLD}/audio/job_1/gone.mp3` }],
    });

    expect(repairDataPaths(store, NEW, () => false)).toBe(0);
    expect(updates).toEqual([]);
  });

  test("is idempotent — a second pass has nothing left to do", () => {
    const stored = [{ key: "bk_1", value: `${NEW}/uploads/bk_1/alice.epub` }];
    const { store, updates } = fakeStore({ "books.source_path": stored });

    expect(repairDataPaths(store, NEW, candidate => candidate.startsWith(NEW))).toBe(0);
    expect(updates).toEqual([]);
  });
});
