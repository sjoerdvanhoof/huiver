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

export type ChapterDTO = {
  id: string;
  idx: number;
  title: string;
  charCount: number;
  preview: string;
};

export type BookDTO = {
  id: string;
  title: string;
  author: string | null;
  format: string;
  createdAt: number;
  chapterCount: number;
  charCount: number;
};

export type BookDetailDTO = BookDTO & { chapters: ChapterDTO[] };

export type TrackDTO = {
  id: string;
  idx: number;
  title: string;
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
