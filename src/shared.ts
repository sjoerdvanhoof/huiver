/** Response shapes shared between the Bun server and the React frontend. */

export type ProviderDTO = {
  id: string;
  label: string;
  local: boolean;
  available: boolean;
  reason?: string;
  voices: { id: string; label: string }[];
  defaultVoice: string;
  supportsSpeed: boolean;
};

export type SettingsDTO = {
  defaultProvider: string;
  /** null = use the provider's own default voice. */
  defaultVoice: string | null;
  defaultSpeed: number;
  theme: "system" | "light" | "dark";
};

/** Where to pick a book back up: the most recently played, not-yet-finished spot. */
export type ResumePointDTO = {
  chapterId: string;
  chapterIdx: number;
  chapterTitle: string;
  /** Converted audio for that chapter, when it exists. */
  trackId: string | null;
  positionSeconds: number;
  /** Duration of the resumable track, when known. */
  durationSeconds: number | null;
};

export type BookProgressDTO = {
  conversionStatus: "none" | "partial" | "full";
  convertedChapters: number;
  /** Chapters listened to the end. */
  completedChapters: number;
  /** 0..1 across the whole book, estimated durations filling in for unconverted chapters. */
  percentListened: number;
  /** Whole-book listening time: real track durations where converted, estimates elsewhere. */
  estimatedTotalSeconds: number;
  /** Portion of estimatedTotalSeconds that is already converted audio. */
  convertedSeconds: number;
  lastPlayedAt: number | null;
  resume: ResumePointDTO | null;
};

export type ChapterDTO = {
  id: string;
  idx: number;
  title: string;
  charCount: number;
  preview: string;
  /**
   * Expected listening time at synthesis speed 1.0 — the real track duration
   * once converted, otherwise char_count over an observed chars-per-second rate.
   */
  estimatedDurationSeconds: number;
  /** Best (newest finished) converted audio for this chapter. */
  audio: { trackId: string; url: string; duration: number | null } | null;
  position: { positionSeconds: number; completed: boolean; updatedAt: number } | null;
};

export type BookDTO = {
  id: string;
  title: string;
  author: string | null;
  format: string;
  createdAt: number;
  chapterCount: number;
  charCount: number;
  coverUrl: string | null;
  progress: BookProgressDTO;
};

export type BookDetailDTO = BookDTO & { chapters: ChapterDTO[] };

export type TrackDTO = {
  id: string;
  idx: number;
  title: string;
  chapterId: string;
  status: "pending" | "running" | "done" | "error";
  duration: number | null;
  error: string | null;
  url: string | null;
};

export type JobDTO = {
  id: string;
  bookId: string;
  bookTitle: string;
  provider: string;
  voice: string;
  speed: number;
  status: "queued" | "running" | "done" | "error" | "cancelled";
  error: string | null;
  chunksDone: number;
  chunksTotal: number;
  createdAt: number;
  finishedAt: number | null;
  tracks: TrackDTO[];
};
