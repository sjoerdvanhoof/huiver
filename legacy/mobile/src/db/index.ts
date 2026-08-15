import * as SQLite from "expo-sqlite";

/**
 * The phone's library. Mirrors the server's schema (apps/web/src/server/db.ts)
 * minus the parts that only make sense there: there is no multi-book job queue
 * on a phone, so a chapter's conversion state lives on its one track row, and
 * live playback stores its chunks as files rather than one growing partial.
 */

const BASELINE = `
  CREATE TABLE IF NOT EXISTS books (
    id         TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    author     TEXT,
    format     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    cover_path TEXT
  );

  CREATE TABLE IF NOT EXISTS chapters (
    id         TEXT PRIMARY KEY,
    book_id    TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    title      TEXT NOT NULL,
    text       TEXT NOT NULL,
    char_count INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS tracks (
    id           TEXT PRIMARY KEY,
    chapter_id   TEXT NOT NULL UNIQUE REFERENCES chapters(id) ON DELETE CASCADE,
    voice        TEXT NOT NULL,
    speed        REAL NOT NULL,
    status       TEXT NOT NULL,
    path         TEXT,
    duration     REAL,
    error        TEXT,
    chunks_done  INTEGER NOT NULL DEFAULT 0,
    chunks_total INTEGER NOT NULL DEFAULT 0,
    -- Pins the exact work the chunk files on disk represent, so a partial is
    -- never continued with different text or a different voice.
    resume_key   TEXT,
    updated_at   INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS playback_positions (
    chapter_id       TEXT PRIMARY KEY REFERENCES chapters(id) ON DELETE CASCADE,
    book_id          TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    position_seconds REAL NOT NULL DEFAULT 0,
    duration_seconds REAL,
    completed        INTEGER NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS chapters_book ON chapters(book_id, idx);
  CREATE INDEX IF NOT EXISTS positions_book ON playback_positions(book_id, updated_at DESC);
`;

/** Index = the user_version the database is migrated *from*. */
const MIGRATIONS = [BASELINE];

export function runMigrations(database: SQLite.SQLiteDatabase): void {
  const row = database.getFirstSync<{ user_version: number }>("PRAGMA user_version");
  const version = row?.user_version ?? 0;
  if (version >= MIGRATIONS.length) return;

  database.withTransactionSync(() => {
    for (let v = version; v < MIGRATIONS.length; v++) database.execSync(MIGRATIONS[v]!);
    database.execSync(`PRAGMA user_version = ${MIGRATIONS.length}`);
  });
}

function open(): SQLite.SQLiteDatabase {
  const database = SQLite.openDatabaseSync("huiver.db");
  database.execSync("PRAGMA journal_mode = WAL;");
  database.execSync("PRAGMA foreign_keys = ON;");
  runMigrations(database);
  return database;
}

export const db = open();

export type BookRow = {
  id: string;
  title: string;
  author: string | null;
  format: string;
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

export type TrackStatus = "pending" | "running" | "done" | "error" | "cancelled";

export type TrackRow = {
  id: string;
  chapter_id: string;
  voice: string;
  speed: number;
  status: TrackStatus;
  path: string | null;
  duration: number | null;
  error: string | null;
  chunks_done: number;
  chunks_total: number;
  resume_key: string | null;
  updated_at: number;
};

export type PlaybackPositionRow = {
  chapter_id: string;
  book_id: string;
  position_seconds: number;
  duration_seconds: number | null;
  completed: number;
  updated_at: number;
};

export { newId } from "./id";
