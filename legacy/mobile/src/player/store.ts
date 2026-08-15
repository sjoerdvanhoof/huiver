import { createAudioPlayer, setAudioModeAsync, type AudioPlayer, type AudioStatus } from "expo-audio";
import { useSyncExternalStore } from "react";
import { pcmDurationSec } from "@huiver/shared";
import { AppState } from "react-native";
import {
  getBook,
  getChapter,
  getPosition,
  lastPosition,
  listChapters,
  savePosition,
  type ChapterWithTrack,
} from "../db/queries";
import { chunkFile, contiguousChunkCount } from "../files";
import { getSettings, updateSettings } from "../settings";
import { readChunkPcmLength } from "../convert/wavFile";
import {
  SAMPLE_RATE,
  activeChapterId,
  chapterChunks,
  convertChapter,
  getConversionProgress,
  stopConversion,
  subscribeConversion,
} from "../convert/engine";

/**
 * The player, ported from apps/web/src/player/store.ts.
 *
 * Same shape and the same rules — one module-level store published through
 * `useSyncExternalStore`, a queue of chapters, converted ones seekable and
 * unconverted ones played as they are synthesized. What changes is the bottom
 * layer: an `AudioPlayer` instead of an `<audio>` element, chunk files instead
 * of a chunked HTTP response, and SQLite instead of the positions API.
 */

export type PlayerSource =
  | { kind: "track"; uri: string; duration: number | null }
  /** Not yet converted: played from the chunk files as synthesis writes them. */
  | { kind: "live"; estimatedDuration: number };

export type QueueItem = {
  bookId: string;
  bookTitle: string;
  author: string | null;
  coverUri: string | null;
  chapterId: string;
  chapterIdx: number;
  chapterTitle: string;
  source: PlayerSource;
};

export type PlayerStatus = "idle" | "loading" | "playing" | "paused";

export type SleepTimer = { kind: "minutes"; until: number; minutes: number } | { kind: "chapter" } | null;

export type PlayerState = {
  queue: QueueItem[];
  index: number;
  status: PlayerStatus;
  position: number;
  /** Real duration once known; the estimate while a chapter is still rendering. */
  duration: number | null;
  rate: number;
  sleep: SleepTimer;
  /** Whether the current item's audio is actually loaded into the player. */
  loaded: boolean;
  /** Seconds of a live chapter that exist so far — the synthesis frontier. */
  renderedSeconds: number;
  /** True while playback is stalled waiting for the next chunk to render. */
  waitingForAudio: boolean;
};

export const RATES = [0.75, 1, 1.25, 1.5, 1.75, 2];
const SLEEP_STEPS = [15, 30, 45, 60] as const;

const SAVE_INTERVAL_MS = 5000;
/** Positions in the first seconds aren't worth remembering. */
const MIN_SAVE_SECONDS = 3;

type LiveTimeline = {
  chapterId: string;
  /** Start second of each rendered chunk, cumulative. */
  starts: number[];
  /** Index of the chunk currently loaded into the player. */
  playing: number;
};

const state: PlayerState = {
  queue: [],
  index: -1,
  status: "idle",
  position: 0,
  duration: null,
  rate: 1,
  sleep: null,
  loaded: false,
  renderedSeconds: 0,
  waitingForAudio: false,
};

let snapshot: PlayerState = { ...state };
const listeners = new Set<() => void>();

let player: AudioPlayer | null = null;
let live: LiveTimeline | null = null;
let lastSaveAt = 0;
let sleepTimeout: ReturnType<typeof setTimeout> | null = null;
let fadeInterval: ReturnType<typeof setInterval> | null = null;
let installed = false;

function emit(): void {
  snapshot = { ...state };
  listeners.forEach(listener => listener());
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export function usePlayer<T>(selector: (state: PlayerState) => T): T {
  return useSyncExternalStore(subscribe, () => selector(snapshot));
}

export const getPlayerState = (): PlayerState => snapshot;

export const currentItem = (from: PlayerState = snapshot): QueueItem | null => from.queue[from.index] ?? null;

/* ------------------------------------------------------------------ */
/* Audio player                                                        */
/* ------------------------------------------------------------------ */

function audio(): AudioPlayer {
  if (player) return player;

  const created = createAudioPlayer(null, { updateInterval: 500 });
  created.addListener("playbackStatusUpdate", onStatus);
  player = created;
  return created;
}

function onStatus(status: AudioStatus): void {
  const item = currentItem(state);
  if (!item) return;

  const offset = live && item.source.kind === "live" ? (live.starts[live.playing] ?? 0) : 0;
  state.position = offset + status.currentTime;

  if (item.source.kind === "track" && status.isLoaded && status.duration > 0) {
    state.duration = status.duration;
  }

  if (status.playing) state.status = "playing";
  else if (state.status === "playing" && !status.didJustFinish && !status.isBuffering) state.status = "paused";

  emit();
  maybeAutosave();

  if (status.didJustFinish) void onFinished();
}

async function onFinished(): Promise<void> {
  const item = currentItem(state);
  if (!item) return;

  // A live chapter finishes one chunk at a time; only the last one ends it.
  if (item.source.kind === "live" && live) {
    const next = live.playing + 1;
    const total = chapterChunks(getChapter(item.chapterId)?.text ?? "").length;
    if (next < total) {
      await playLiveChunk(next, true);
      return;
    }
  }

  persistCompleted(item);

  if (state.sleep?.kind === "chapter") {
    setSleep(null);
    state.status = "paused";
    emit();
    return;
  }
  advance();
}

/* ------------------------------------------------------------------ */
/* Loading                                                             */
/* ------------------------------------------------------------------ */

/** Cumulative start seconds of every chunk rendered for a chapter so far. */
function liveStarts(chapterId: string): number[] {
  const count = contiguousChunkCount(chapterId);
  const starts: number[] = [];
  let seconds = 0;
  for (let index = 0; index < count; index++) {
    starts.push(seconds);
    seconds += pcmDurationSec(readChunkPcmLength(chunkFile(chapterId, index)), SAMPLE_RATE);
  }
  // One past the end, so `starts[i+1]` is always the frontier.
  starts.push(seconds);
  return starts;
}

async function playLiveChunk(index: number, autoplay: boolean): Promise<void> {
  const item = currentItem(state);
  if (!item || item.source.kind !== "live") return;

  const starts = liveStarts(item.chapterId);
  const available = Math.max(0, starts.length - 1);

  if (index >= available) {
    // Ahead of synthesis: hold here and let the conversion listener resume us.
    state.waitingForAudio = true;
    state.status = autoplay ? "loading" : "paused";
    state.renderedSeconds = starts[available] ?? 0;
    emit();
    return;
  }

  live = { chapterId: item.chapterId, starts, playing: index };
  state.waitingForAudio = false;
  state.renderedSeconds = starts[available] ?? 0;
  state.loaded = true;

  const active = audio();
  active.replace({ uri: chunkFile(item.chapterId, index).uri });
  active.setPlaybackRate(state.rate, "medium");
  if (autoplay) active.play();
  emit();
}

async function loadItem(item: QueueItem, startPosition: number | null, autoplay: boolean): Promise<void> {
  const active = audio();
  state.position = startPosition ?? 0;

  if (item.source.kind === "track") {
    live = null;
    state.duration = item.source.duration;
    state.renderedSeconds = item.source.duration ?? 0;
    state.waitingForAudio = false;
    state.loaded = true;

    active.replace({ uri: item.source.uri });
    active.setPlaybackRate(state.rate, "medium");
    if (startPosition && startPosition > 0) await active.seekTo(startPosition).catch(() => undefined);
    if (autoplay) active.play();
    emit();
    return;
  }

  state.duration = item.source.estimatedDuration;
  // Playing an unconverted chapter is what starts rendering it.
  ensureConverting(item.chapterId);

  const starts = liveStarts(item.chapterId);
  const target = startPosition ?? 0;
  let index = 0;
  while (index + 1 < starts.length - 1 && (starts[index + 1] ?? 0) <= target) index++;

  await playLiveChunk(index, autoplay);
  if (target > (starts[index] ?? 0)) {
    await audio()
      .seekTo(target - (starts[index] ?? 0))
      .catch(() => undefined);
  }
}

function ensureConverting(chapterId: string): void {
  // Already rendering — possibly started from the book screen rather than here,
  // which is exactly why progress is followed through the store below.
  if (activeChapterId() === chapterId) return;
  convertChapter({ chapterId, voice: getSettings().voice });
}

/** Stop a render this player started, once nobody is listening to it. */
function stopLiveSynthesis(): void {
  const item = currentItem(state);
  if (item?.source.kind === "live") stopConversion(item.chapterId);
}

/** A chunk landed on disk: extend the timeline, and un-stall if we were waiting. */
function onChunkRendered(chapterId: string): void {
  const item = currentItem(state);
  if (!item || item.chapterId !== chapterId || item.source.kind !== "live") return;

  const starts = liveStarts(chapterId);
  state.renderedSeconds = starts[starts.length - 1] ?? 0;
  if (live) live.starts = starts;

  if (state.waitingForAudio) {
    const next = live ? live.playing + 1 : 0;
    void playLiveChunk(next, state.status !== "paused");
    return;
  }
  emit();
}

/* ------------------------------------------------------------------ */
/* Actions                                                             */
/* ------------------------------------------------------------------ */

export function playQueue(queue: QueueItem[], index: number, startPosition: number | null = null): void {
  install();
  const item = queue[index];
  if (!item) return;

  persistNow(); // capture the previous item's spot before switching

  state.queue = queue;
  state.index = index;
  state.status = "loading";
  emit();

  updateLockScreen(item);
  lastSaveAt = Date.now();
  void loadItem(item, startPosition, true);
}

/** Restore a session without starting playback — one tap resumes. */
export function loadPaused(queue: QueueItem[], index: number, startPosition: number | null = null): void {
  install();
  if (state.status !== "idle") return; // never clobber active playback
  const item = queue[index];
  if (!item) return;

  state.queue = queue;
  state.index = index;
  state.status = "paused";
  state.position = startPosition ?? 0;
  state.duration = item.source.kind === "track" ? item.source.duration : item.source.estimatedDuration;
  state.loaded = false;
  emit();
  updateLockScreen(item);
}

/** Swap in a richer queue without interrupting whatever is playing. */
export function replaceQueue(queue: QueueItem[]): void {
  const item = currentItem(state);
  if (!item) return;
  const index = queue.findIndex(entry => entry.chapterId === item.chapterId);
  if (index < 0) return;

  const next = [...queue];
  next[index] = item; // keep the exact item that is loaded
  state.queue = next;
  state.index = index;
  emit();
}

export function toggle(): void {
  const item = currentItem(state);
  if (!item) return;

  if (state.status === "playing" || state.status === "loading") {
    audio().pause();
    state.status = "paused";
    // Nothing is listening now, and iOS will suspend us shortly anyway. The
    // chunks already on disk mean resuming costs nothing.
    stopLiveSynthesis();
    emit();
    persistNow();
    return;
  }

  if (!state.loaded) {
    // Parked at an unloaded chapter (auto-advance stops at unconverted ones).
    playQueue(state.queue, state.index, state.position || null);
    return;
  }

  audio().setPlaybackRate(state.rate, "medium");
  audio().play();
}

/** Stop playback without changing what is loaded — used when a preview starts. */
export function pause(): void {
  if (state.status === "playing" || state.status === "loading") {
    audio().pause();
    state.status = "paused";
    stopLiveSynthesis();
    emit();
  }
}

export function seekTo(seconds: number): void {
  const item = currentItem(state);
  if (!item) return;

  if (item.source.kind === "live") {
    const starts = live?.starts ?? liveStarts(item.chapterId);
    const frontier = starts[starts.length - 1] ?? 0;
    // Nothing past the frontier exists yet, so a seek there clamps to it.
    const target = Math.max(0, Math.min(seconds, Math.max(0, frontier - 0.5)));

    let index = 0;
    while (index + 1 < starts.length - 1 && (starts[index + 1] ?? 0) <= target) index++;

    const wasPlaying = state.status === "playing" || state.status === "loading";
    const offset = target - (starts[index] ?? 0);

    if (live && live.playing === index) {
      void audio().seekTo(offset).catch(() => undefined);
    } else {
      void playLiveChunk(index, wasPlaying).then(() => audio().seekTo(offset).catch(() => undefined));
    }
    state.position = target;
    emit();
    persistNow();
    return;
  }

  const max = state.duration ? state.duration - 0.25 : seconds;
  const target = Math.max(0, Math.min(seconds, max));
  void audio().seekTo(target).catch(() => undefined);
  state.position = target;
  emit();
  persistNow();
}

export const seekBy = (delta: number): void => seekTo(state.position + delta);

export function playIndex(index: number): void {
  if (!state.queue[index]) return;
  playQueue(state.queue, index, null);
}

export function next(): void {
  if (state.index < state.queue.length - 1) jumpTo(state.index + 1);
}

export function previous(): void {
  // Like every audiobook player: early in a chapter go back one, otherwise
  // restart the current chapter.
  if (state.position > 4) {
    seekTo(0);
    return;
  }
  if (state.index > 0) jumpTo(state.index - 1);
  else seekTo(0);
}

function jumpTo(index: number): void {
  const item = state.queue[index];
  if (!item) return;

  const wasPlaying = state.status === "playing" || state.status === "loading";
  if (item.source.kind === "live" && !wasPlaying) {
    // Don't start synthesizing unless the user actually wants sound now.
    parkAt(index);
    return;
  }
  playQueue(state.queue, index, null);
}

/** Move to a chapter but stay paused, without loading or rendering anything. */
function parkAt(index: number): void {
  persistNow();
  const item = state.queue[index];
  if (!item) return;

  state.index = index;
  state.status = "paused";
  state.loaded = false;
  state.position = 0;
  state.waitingForAudio = false;
  state.duration = item.source.kind === "track" ? item.source.duration : item.source.estimatedDuration;
  audio().pause();
  emit();
  updateLockScreen(item);
}

/** Auto-advance after a chapter ends. */
function advance(): void {
  const nextIndex = state.index + 1;
  const nextItem = state.queue[nextIndex];

  if (!nextItem) {
    state.status = "paused";
    emit();
    return;
  }

  if (nextItem.source.kind === "live" && !getSettings().autoAdvanceIntoUnconverted) {
    parkAt(nextIndex);
    return;
  }
  playQueue(state.queue, nextIndex, null);
}

export function setRate(rate: number): void {
  state.rate = rate;
  updateSettings({ rate });
  player?.setPlaybackRate(rate, "medium");
  emit();
}

export function cycleRate(): void {
  const index = RATES.indexOf(state.rate);
  setRate(RATES[(index + 1) % RATES.length]!);
}

/* ------------------------------------------------------------------ */
/* Sleep timer                                                         */
/* ------------------------------------------------------------------ */

export function cycleSleep(): void {
  const sleep = state.sleep;
  if (!sleep) return setSleep({ kind: "minutes", minutes: 15, until: Date.now() + 15 * 60_000 });
  if (sleep.kind === "chapter") return setSleep(null);

  const at = SLEEP_STEPS.indexOf(sleep.minutes as (typeof SLEEP_STEPS)[number]);
  const step = SLEEP_STEPS[at + 1];
  if (step) return setSleep({ kind: "minutes", minutes: step, until: Date.now() + step * 60_000 });
  setSleep({ kind: "chapter" });
}

export function setSleep(sleep: SleepTimer): void {
  if (sleepTimeout) {
    clearTimeout(sleepTimeout);
    sleepTimeout = null;
  }
  if (fadeInterval) {
    clearInterval(fadeInterval);
    fadeInterval = null;
    if (player) player.volume = 1;
  }

  state.sleep = sleep;
  emit();

  if (sleep?.kind === "minutes") {
    sleepTimeout = setTimeout(fadeOutAndPause, Math.max(0, sleep.until - Date.now()));
  }
}

function fadeOutAndPause(): void {
  const active = player;
  if (!active || !active.playing) {
    setSleep(null);
    return;
  }

  const steps = 30; // three seconds
  let step = 0;
  fadeInterval = setInterval(() => {
    step++;
    active.volume = Math.max(0, 1 - step / steps);
    if (step >= steps) {
      clearInterval(fadeInterval!);
      fadeInterval = null;
      active.pause();
      active.volume = 1;
      state.status = "paused";
      setSleep(null);
    }
  }, 100);
}

/* ------------------------------------------------------------------ */
/* Position persistence                                                */
/* ------------------------------------------------------------------ */

function maybeAutosave(): void {
  if (state.status !== "playing") return;
  if (Date.now() - lastSaveAt < SAVE_INTERVAL_MS) return;
  persistNow();
}

function persistNow(): void {
  const item = currentItem(state);
  if (!item || !state.loaded) return;
  if (state.position < MIN_SAVE_SECONDS) return;

  lastSaveAt = Date.now();
  savePosition({
    chapterId: item.chapterId,
    bookId: item.bookId,
    positionSeconds: state.position,
    durationSeconds: state.duration,
    completed: false,
  });
}

function persistCompleted(item: QueueItem): void {
  lastSaveAt = Date.now();
  savePosition({
    chapterId: item.chapterId,
    bookId: item.bookId,
    positionSeconds: state.duration ?? state.position,
    durationSeconds: state.duration,
    completed: true,
  });
}

/* ------------------------------------------------------------------ */
/* Lock screen + app lifecycle                                         */
/* ------------------------------------------------------------------ */

function updateLockScreen(item: QueueItem): void {
  const metadata = {
    title: item.chapterTitle,
    artist: item.author ?? "huiver",
    albumTitle: item.bookTitle,
    ...(item.coverUri ? { artworkUrl: item.coverUri } : {}),
  };

  try {
    audio().setActiveForLockScreen(true, metadata, {
      showSeekForward: true,
      showSeekBackward: true,
    });
  } catch {
    // Lock-screen controls are a nicety; never let them stop playback.
  }
}

function install(): void {
  if (installed) return;
  installed = true;

  state.rate = getSettings().rate;

  void setAudioModeAsync({
    playsInSilentMode: true,
    shouldPlayInBackground: true,
    // Anything but exclusive playback and iOS may not hand us the lock screen.
    interruptionMode: "doNotMix",
    allowsRecording: false,
  }).catch(() => undefined);

  // The web app flushes on `pagehide`; backgrounding is the phone's equivalent.
  AppState.addEventListener("change", next => {
    if (next !== "active") persistNow();
  });

  // Follow whichever chapter is rendering, even one this player did not start.
  subscribeConversion(() => {
    const rendering = getConversionProgress();
    if (rendering) onChunkRendered(rendering.chapterId);
  });
}

/* ------------------------------------------------------------------ */
/* Queue building + session restore                                    */
/* ------------------------------------------------------------------ */

/**
 * Estimated seconds for an unconverted chapter, from whatever this book has
 * already rendered — the same trick the server's `charsPerSecond` plays.
 */
export function charsPerSecond(chapters: ChapterWithTrack[]): number {
  let chars = 0;
  let seconds = 0;
  for (const chapter of chapters) {
    if (chapter.track?.status === "done" && chapter.track.duration) {
      chars += chapter.char_count;
      seconds += chapter.track.duration;
    }
  }
  // ~16 characters a second is Kokoro at speed 1, and a fine cold start.
  return seconds > 0 ? chars / seconds : 16;
}

/** The whole book as a play queue: converted chapters seekable, the rest live. */
export function buildQueue(bookId: string): QueueItem[] {
  const book = getBook(bookId);
  if (!book) return [];

  const chapters = listChapters(bookId);
  const rate = charsPerSecond(chapters);

  return chapters.map(chapter => ({
    bookId: book.id,
    bookTitle: book.title,
    author: book.author,
    coverUri: book.cover_path,
    chapterId: chapter.id,
    chapterIdx: chapter.idx,
    chapterTitle: chapter.title,
    source:
      chapter.track?.status === "done" && chapter.track.path
        ? { kind: "track", uri: chapter.track.path, duration: chapter.track.duration }
        : { kind: "live", estimatedDuration: chapter.char_count / rate },
  }));
}

/**
 * Start a chapter. Called straight from the tap, because iOS refuses to start
 * audio from a callback that has already awaited something.
 */
export function playChapter(bookId: string, chapterId: string): void {
  const queue = buildQueue(bookId);
  const index = queue.findIndex(item => item.chapterId === chapterId);
  if (index < 0) return;

  const saved = getPosition(chapterId);
  playQueue(queue, index, saved && !saved.completed ? saved.position_seconds : null);
}

/** Cold start: put the last thing the user was listening to back on the bar. */
export function restoreLastSession(bookId?: string): void {
  const saved = bookId ? lastPosition(bookId) : lastPosition();
  if (!saved) return;

  const queue = buildQueue(saved.book_id);
  const index = queue.findIndex(item => item.chapterId === saved.chapter_id);
  if (index < 0) return;

  loadPaused(queue, index, saved.position_seconds);
}

