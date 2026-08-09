import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// The db module opens its singleton at import time; point it at a throwaway
// directory before anything pulls it in. `??=` keeps whichever test file ran
// first authoritative, so every file shares one temp dir.
process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { runMigrations } = await import("./db");

const tableNames = (db: Database): string[] =>
  (db.query("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[]).map(r => r.name);

const columnNames = (db: Database, table: string): string[] =>
  (db.query(`PRAGMA table_info(${table})`).all() as { name: string }[]).map(r => r.name);

const userVersion = (db: Database): number =>
  (db.query("PRAGMA user_version").get() as { user_version: number }).user_version;

/** The exact schema the first release shipped, before migrations existed. */
const LEGACY_SCHEMA = `
  CREATE TABLE IF NOT EXISTS books (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    author      TEXT,
    format      TEXT NOT NULL,
    source_path TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS chapters (
    id         TEXT PRIMARY KEY,
    book_id    TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    title      TEXT NOT NULL,
    text       TEXT NOT NULL,
    char_count INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS jobs (
    id           TEXT PRIMARY KEY,
    book_id      TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL,
    voice        TEXT NOT NULL,
    speed        REAL NOT NULL,
    status       TEXT NOT NULL,
    error        TEXT,
    chunks_done  INTEGER NOT NULL DEFAULT 0,
    chunks_total INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    finished_at  INTEGER
  );
  CREATE TABLE IF NOT EXISTS tracks (
    id         TEXT PRIMARY KEY,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    chapter_id TEXT NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    title      TEXT NOT NULL,
    status     TEXT NOT NULL,
    path       TEXT,
    duration   REAL,
    error      TEXT
  );
  CREATE INDEX IF NOT EXISTS chapters_book ON chapters(book_id, idx);
  CREATE INDEX IF NOT EXISTS jobs_book ON jobs(book_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS tracks_job ON tracks(job_id, idx);
`;

describe("runMigrations", () => {
  test("fresh database gets the full schema", () => {
    const db = new Database(":memory:");
    runMigrations(db);

    const tables = tableNames(db);
    for (const table of ["books", "chapters", "jobs", "tracks", "settings", "playback_positions"]) {
      expect(tables).toContain(table);
    }
    expect(columnNames(db, "books")).toContain("cover_path");
    expect(columnNames(db, "tracks")).toContain("chunks_done");
    expect(userVersion(db)).toBe(3);
  });

  test("existing pre-migration database keeps its data", () => {
    const db = new Database(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    db.exec(LEGACY_SCHEMA); // user_version stays 0, exactly like a real old install

    db.exec(`
      INSERT INTO books (id, title, author, format, source_path, created_at)
        VALUES ('bk_1', 'Moby Dick', 'Melville', 'epub', '/x/moby.epub', 1);
      INSERT INTO chapters (id, book_id, idx, title, text, char_count)
        VALUES ('ch_1', 'bk_1', 0, 'Loomings', 'Call me Ishmael.', 16);
      INSERT INTO jobs (id, book_id, provider, voice, speed, status, created_at)
        VALUES ('job_1', 'bk_1', 'kokoro', 'af_heart', 1, 'done', 2);
      INSERT INTO tracks (id, job_id, chapter_id, idx, title, status, path, duration)
        VALUES ('tr_1', 'job_1', 'ch_1', 0, 'Loomings', 'done', '/x/a.mp3', 12.5);
    `);

    runMigrations(db);

    expect(userVersion(db)).toBe(3);
    expect(db.query("SELECT title FROM books WHERE id = 'bk_1'").get()).toEqual({ title: "Moby Dick" });
    expect(db.query("SELECT COUNT(*) AS n FROM tracks").get()).toEqual({ n: 1 });
    expect(tableNames(db)).toContain("playback_positions");
    expect(columnNames(db, "books")).toContain("cover_path");
  });

  test("upgrades a v2 database in place", () => {
    const db = new Database(":memory:");
    runMigrations(db);

    // Wind the schema back to what v2 shipped, keeping a row to check.
    db.exec(`
      INSERT INTO books (id, title, format, source_path, created_at) VALUES ('bk_1', 'Emma', 'epub', '/x', 1);
      INSERT INTO settings (key, value) VALUES ('defaultVoice', '"af_heart"');
      ALTER TABLE tracks DROP COLUMN chunks_done;
      ALTER TABLE tracks DROP COLUMN chunks_total;
      PRAGMA user_version = 2;
    `);
    expect(columnNames(db, "tracks")).not.toContain("chunks_done");

    runMigrations(db);

    expect(userVersion(db)).toBe(3);
    expect(columnNames(db, "tracks")).toContain("chunks_done");
    expect(columnNames(db, "tracks")).toContain("chunks_total");
    expect(db.query("SELECT title FROM books WHERE id = 'bk_1'").get()).toEqual({ title: "Emma" });
    expect(db.query("SELECT value FROM settings WHERE key = 'defaultVoice'").get()).toEqual({
      value: '"af_heart"',
    });
  });

  test("running migrations twice is a no-op", () => {
    const db = new Database(":memory:");
    runMigrations(db);
    expect(() => runMigrations(db)).not.toThrow();
    expect(userVersion(db)).toBe(3);
  });
});
