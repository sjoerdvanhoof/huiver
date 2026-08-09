import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import path from "node:path";

/** Overridable so tests can run against a throwaway directory. */
export const DATA_DIR = process.env.HUIVER_DATA_DIR ?? path.join(process.cwd(), "data");
export const UPLOAD_DIR = path.join(DATA_DIR, "uploads");
export const AUDIO_DIR = path.join(DATA_DIR, "audio");

mkdirSync(UPLOAD_DIR, { recursive: true });
mkdirSync(AUDIO_DIR, { recursive: true });

export const db = new Database(path.join(DATA_DIR, "huiver.db"), { create: true });
db.exec("PRAGMA journal_mode = WAL;");
db.exec("PRAGMA foreign_keys = ON;");

db.exec(`
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
`);

export type BookRow = {
  id: string;
  title: string;
  author: string | null;
  format: string;
  source_path: string;
  created_at: number;
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

export type TrackStatus = "pending" | "running" | "done" | "error";

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
};

export const newId = (prefix: string) => `${prefix}_${crypto.randomUUID().slice(0, 12)}`;
