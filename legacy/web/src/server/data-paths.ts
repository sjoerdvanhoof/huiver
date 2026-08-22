import { existsSync } from "node:fs";
import path from "node:path";

/**
 * Keeping the library's file references pointing at the files.
 *
 * Rows record where a book, its cover and its audio live as absolute paths, and
 * an absolute path stops being true the moment the data directory moves — which
 * it does: the app moved into apps/web during the monorepo split, HUIVER_DATA_DIR
 * can point anywhere, and a repo gets cloned to a different home directory.
 *
 * Rather than migrate once for one move, every stored path is re-rooted onto the
 * current data directory whenever the file it names has gone missing. That is
 * self-healing and costs a `stat` per row on a library of tens of books.
 */

/** Every directory the app writes into, all of them directly under DATA_DIR. */
const SUBDIRECTORIES = ["uploads", "audio", "streams", "previews"];

/**
 * The same file, addressed from `dataDir`. Null when the path does not look
 * like it came from a data directory at all, or already points there.
 *
 * The *last* matching segment wins, so a data directory that happens to sit
 * under something called "audio" does not confuse the search.
 */
export function rebaseDataPath(stored: string, dataDir: string): string | null {
  let bestAt = -1;
  let bestSub = "";

  for (const sub of SUBDIRECTORIES) {
    const at = stored.lastIndexOf(`${path.sep}${sub}${path.sep}`);
    if (at > bestAt) {
      bestAt = at;
      bestSub = sub;
    }
  }

  if (bestAt < 0) return null;

  const relative = stored.slice(bestAt + 1);
  const rebased = path.join(dataDir, relative);
  return rebased === stored ? null : rebased;
}

type Target = { table: string; column: string; key: string };

const TARGETS: Target[] = [
  { table: "books", column: "source_path", key: "id" },
  { table: "books", column: "cover_path", key: "id" },
  { table: "tracks", column: "path", key: "id" },
  { table: "tracks", column: "resume_path", key: "id" },
  { table: "stream_partials", column: "path", key: "key" },
];

/** Minimal shape of the database, so this is testable without bun:sqlite. */
export type PathStore = {
  rows(table: string, column: string, key: string): { key: string; value: string }[];
  update(table: string, column: string, key: string, keyValue: string, value: string): void;
};

/**
 * Point every broken path at the file it names, if that file can be found under
 * `dataDir`. Conservative on purpose: a path whose file is present is left
 * alone, and a rewrite only happens when the rebased file actually exists, so a
 * genuinely deleted file keeps its original path and its "missing" error.
 */
export function repairDataPaths(
  store: PathStore,
  dataDir: string,
  exists: (candidate: string) => boolean = existsSync,
): number {
  let repaired = 0;

  for (const { table, column, key } of TARGETS) {
    for (const row of store.rows(table, column, key)) {
      if (exists(row.value)) continue;

      const rebased = rebaseDataPath(row.value, dataDir);
      if (!rebased || !exists(rebased)) continue;

      store.update(table, column, key, row.key, rebased);
      repaired++;
    }
  }

  return repaired;
}
