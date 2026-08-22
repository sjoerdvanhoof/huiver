import { Database } from "bun:sqlite";
import { repairDataPaths, type PathStore } from "./data-paths";
import { mkdirSync } from "node:fs";
import path from "node:path";

/** Overridable so tests can run against a throwaway directory. */
export const DATA_DIR = process.env.HUIVER_DATA_DIR ?? path.join(process.cwd(), "data");
export const UPLOAD_DIR = path.join(DATA_DIR, "uploads");
export const AUDIO_DIR = path.join(DATA_DIR, "audio");

mkdirSync(UPLOAD_DIR, { recursive: true });
mkdirSync(AUDIO_DIR, { recursive: true });

/**
 * Baseline schema. Kept `IF NOT EXISTS` so databases created before the
 * migration counter existed (they sit at user_version 0 but already have
 * these tables) replay it as a no-op.
 */
const BASELINE = `
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

/** v2: persisted settings, playback positions, cover art. */
const V2 = `
  CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS playback_positions (
    chapter_id       TEXT PRIMARY KEY REFERENCES chapters(id) ON DELETE CASCADE,
    book_id          TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    track_id         TEXT REFERENCES tracks(id) ON DELETE SET NULL,
    position_seconds REAL NOT NULL DEFAULT 0,
    duration_seconds REAL,
    completed        INTEGER NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS positions_book ON playback_positions(book_id, updated_at DESC);

  ALTER TABLE books ADD COLUMN cover_path TEXT;

  CREATE INDEX IF NOT EXISTS tracks_chapter ON tracks(chapter_id);
`;

/** v3: per-track progress, so a single chapter can show its own percentage. */
const V3 = `
  ALTER TABLE tracks ADD COLUMN chunks_done INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE tracks ADD COLUMN chunks_total INTEGER NOT NULL DEFAULT 0;
`;

/**
 * v4: mid-chapter conversion checkpoints. `resume_chunks` chunks of this
 * track are already in the partial WAV at `resume_path`, which holds
 * `resume_bytes` of audio; `resume_key` pins the work they represent so a
 * partial is never continued with different text, voice or speed.
 */
const V4 = `
  ALTER TABLE tracks ADD COLUMN resume_chunks INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE tracks ADD COLUMN resume_bytes INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE tracks ADD COLUMN resume_key TEXT;
  ALTER TABLE tracks ADD COLUMN resume_path TEXT;
`;

/**
 * v5: audio kept from live playback. A chapter the user streams is written to
 * disk as it plays, so playing it again starts from what is already rendered
 * instead of synthesizing it a second time. Keyed by the work it represents,
 * exactly like a conversion checkpoint.
 */
const V5 = `
  CREATE TABLE IF NOT EXISTS stream_partials (
    key          TEXT PRIMARY KEY,
    chapter_id   TEXT NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
    path         TEXT NOT NULL,
    chunks_done  INTEGER NOT NULL DEFAULT 0,
    chunks_total INTEGER NOT NULL,
    bytes        INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS stream_partials_chapter ON stream_partials(chapter_id);
`;

/** Index = the user_version the database is migrated *from*. */
const MIGRATIONS = [BASELINE, V2, V3, V4, V5];

export function runMigrations(database: Database): void {
  const { user_version } = database.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= MIGRATIONS.length) return;

  database.transaction(() => {
    for (let v = user_version; v < MIGRATIONS.length; v++) database.exec(MIGRATIONS[v]!);
    database.exec(`PRAGMA user_version = ${MIGRATIONS.length}`);
  })();
}

/**
 * A view of the path columns for ./data-paths, which re-roots them when the
 * data directory has moved out from under the library.
 */
const pathStore = (database: Database): PathStore => ({
  rows: (table, column, key) =>
    database
      .query(`SELECT ${key} AS key, ${column} AS value FROM ${table} WHERE ${column} IS NOT NULL`)
      .all() as { key: string; value: string }[],
  update: (table, column, key, keyValue, value) => {
    database.query(`UPDATE ${table} SET ${column} = ? WHERE ${key} = ?`).run(value, keyValue);
  },
});

/** Open (or create) a huiver database and bring its schema up to date. */
export function openDatabase(dbPath: string, dataDir = DATA_DIR): Database {
  const database = new Database(dbPath, { create: true });
  database.exec("PRAGMA journal_mode = WAL;");
  database.exec("PRAGMA foreign_keys = ON;");
  runMigrations(database);

  const repaired = repairDataPaths(pathStore(database), dataDir);
  if (repaired > 0) console.log(`Re-rooted ${repaired} file path(s) onto ${dataDir}`);

  return database;
}

export const db = openDatabase(path.join(DATA_DIR, "huiver.db"));

export type BookRow = {
  id: string;
  title: string;
  author: string | null;
  format: string;
  source_path: string;
  created_at: number;
  cover_path: string | null;
};

export type ChapterRow = {
  id: string;
  book_id: string;
  idx: number;
  title: string;
  text: string;
  char_count: number;
};

export type JobStatus = "queued" | "running" | "done" | "error" | "cancelled";

export type JobRow = {
  id: string;
  book_id: string;
  provider: string;
  voice: string;
  speed: number;
  status: JobStatus;
  error: string | null;
  chunks_done: number;
  chunks_total: number;
  created_at: number;
  finished_at: number | null;
};

export type TrackStatus = "pending" | "running" | "done" | "error" | "cancelled";

export type TrackRow = {
  id: string;
  job_id: string;
  chapter_id: string;
  idx: number;
  title: string;
  status: TrackStatus;
  path: string | null;
  duration: number | null;
  error: string | null;
  chunks_done: number;
  chunks_total: number;
  /** Chunks already rendered into the partial WAV — see ./checkpoint. */
  resume_chunks: number;
  resume_bytes: number;
  resume_key: string | null;
  resume_path: string | null;
};

/** Audio kept from live playback — see ./stream-store. */
export type StreamPartialRow = {
  key: string;
  chapter_id: string;
  path: string;
  chunks_done: number;
  chunks_total: number;
  bytes: number;
  updated_at: number;
};

export type PlaybackPositionRow = {
  chapter_id: string;
  book_id: string;
  track_id: string | null;
  position_seconds: number;
  duration_seconds: number | null;
  completed: number;
  updated_at: number;
};

export const newId = (prefix: string) => `${prefix}_${crypto.randomUUID().slice(0, 12)}`;
