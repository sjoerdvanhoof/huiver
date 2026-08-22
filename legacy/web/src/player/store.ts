import { useSyncExternalStore } from "react";
import type { BookDetailDTO, SettingsDTO } from "@huiver/shared";
import { coverArtworkDataUrl } from "../lib/cover-artwork";

export type PlayerSource =
  | { kind: "track"; url: string; trackId: string; duration: number | null }
  | { kind: "live"; url: string; estimatedDuration: number; startPosition?: number };

export type QueueItem = {
  bookId: string;
  bookTitle: string;
  author: string | null;
  coverUrl: string | null;
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
  /** Real duration once metadata is known; the estimate for live streams. */
  duration: number | null;
  rate: number;
  expanded: boolean;
  sleep: SleepTimer;
  /** Whether the current item's audio source is loaded into the element. */
  loaded: boolean;
};

const RATES = [0.75, 1, 1.25, 1.5, 1.75, 2];
const RATE_KEY = "huiver:rate";
export const STREAM_ADVANCE_KEY = "huiver:stream-advance";

const SAVE_INTERVAL_MS = 5000;
/** Positions in the first seconds aren't worth remembering. */
const MIN_SAVE_SECONDS = 3;

type Store = {
  state: PlayerState;
  snapshot: PlayerState;
  listeners: Set<() => void>;
  audio: HTMLAudioElement | null;
  loadedKey: string | null;
  pendingSeek: number | null;
  lastSaveAt: number;
  sleepTimeout: ReturnType<typeof setTimeout> | null;
  fadeInterval: ReturnType<typeof setInterval> | null;
  globalsInstalled: boolean;
};

function readStoredRate(): number {
  try {
    const value = Number(localStorage.getItem(RATE_KEY));
    return RATES.includes(value) ? value : 1;
  } catch {
    return 1;
  }
}

const initialState = (): PlayerState => ({
  queue: [],
  index: -1,
  status: "idle",
  position: 0,
  duration: null,
  rate: typeof localStorage === "undefined" ? 1 : readStoredRate(),
  expanded: false,
  sleep: null,
  loaded: false,
});

// One store per page, surviving dev hot reloads (the audio keeps playing).
const store: Store = ((globalThis as Record<string, unknown>).__huiverPlayerStore ??= {
  state: initialState(),
  snapshot: initialState(),
  listeners: new Set(),
  audio: null,
  loadedKey: null,
  pendingSeek: null,
  lastSaveAt: 0,
  sleepTimeout: null,
  fadeInterval: null,
  globalsInstalled: false,
} satisfies Store) as Store;

function emit(): void {
  store.snapshot = { ...store.state };
  store.listeners.forEach(listener => listener());
}

const subscribe = (listener: () => void) => {
  store.listeners.add(listener);
  return () => store.listeners.delete(listener);
};

export function usePlayer<T>(selector: (state: PlayerState) => T): T {
  return useSyncExternalStore(subscribe, () => selector(store.snapshot));
}

export const getPlayerState = (): PlayerState => store.snapshot;

export const currentItem = (state: PlayerState): QueueItem | null => state.queue[state.index] ?? null;

/* ------------------------------------------------------------------ */
/* Audio element                                                       */
/* ------------------------------------------------------------------ */

function audioEl(): HTMLAudioElement {
  if (store.audio) return store.audio;
  const audio = new Audio();
  audio.preload = "metadata";
  store.audio = audio;

  audio.addEventListener("loadedmetadata", () => {
    if (store.pendingSeek !== null && Number.isFinite(audio.duration)) {
      audio.currentTime = Math.min(store.pendingSeek, Math.max(0, audio.duration - 0.5));
      store.pendingSeek = null;
    }
    const item = currentItem(store.state);
    if (item && Number.isFinite(audio.duration) && item.source.kind === "track") {
      store.state.duration = audio.duration;
      emit();
    }
  });

  audio.addEventListener("timeupdate", () => {
    const item = currentItem(store.state);
    const offset = item?.source.kind === "live" ? (item.source.startPosition ?? 0) : 0;
    store.state.position = offset + audio.currentTime;
    emit();
    updatePositionState();
    maybeAutosave();
  });

  audio.addEventListener("play", () => {
    store.state.status = "playing";
    emit();
    setMediaPlaybackState("playing");
  });

  audio.addEventListener("pause", () => {
    // 'ended' also fires pause; the ended handler decides what happens next.
    if (audio.ended) return;
    if (store.state.status === "playing" || store.state.status === "loading") {
      store.state.status = "paused";
      emit();
      setMediaPlaybackState("paused");
      void persistNow(false);
    }
  });

  audio.addEventListener("waiting", () => {
    if (store.state.status === "playing") {
      store.state.status = "loading";
      emit();
    }
  });

  audio.addEventListener("playing", () => {
    if (store.state.status !== "playing") {
      store.state.status = "playing";
      emit();
    }
  });

  audio.addEventListener("ended", () => {
    const item = currentItem(store.state);
    if (item) void persistCompleted(item);

    if (store.state.sleep?.kind === "chapter") {
      setSleep(null);
      store.state.status = "paused";
      emit();
      return;
    }
    advance();
  });

  audio.addEventListener("error", () => {
    if (!audio.src) return;
    store.state.status = "paused";
    emit();
  });

  return audio;
}

const itemKey = (item: QueueItem): string => `${item.chapterId}:${item.source.url}`;

function loadItem(item: QueueItem, startPosition: number | null): void {
  const audio = audioEl();
  if (item.source.kind === "live") {
    const url = new URL(item.source.url, location.origin);
    url.searchParams.delete("start");
    const start = Math.max(0, Math.min(startPosition ?? 0, Math.max(0, item.source.estimatedDuration - 1)));
    if (start > MIN_SAVE_SECONDS) url.searchParams.set("start", String(Math.floor(start)));
    item.source.url = `${url.pathname}${url.search}`;
    item.source.startPosition = start;
  }
  const key = itemKey(item);

  if (store.loadedKey !== key) {
    audio.src = item.source.url;
    store.loadedKey = key;
    audio.load();
  }

  store.pendingSeek = null;
  if (item.source.kind === "track" && startPosition && startPosition > 0) {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      audio.currentTime = Math.min(startPosition, audio.duration - 0.5);
    } else {
      store.pendingSeek = startPosition;
    }
  }

  audio.playbackRate = store.state.rate;
  store.state.loaded = true;
  store.state.position = startPosition ?? 0;
  store.state.duration = item.source.kind === "track" ? item.source.duration : item.source.estimatedDuration;
}

/* ------------------------------------------------------------------ */
/* Actions                                                             */
/* ------------------------------------------------------------------ */

/** Start playing `queue[index]`. Called synchronously from user gestures (iOS). */
export function playQueue(queue: QueueItem[], index: number, startPosition: number | null = null): void {
  installGlobals();
  const item = queue[index];
  if (!item) return;

  void persistNow(false); // capture the previous item's spot before switching

  store.state.queue = queue;
  store.state.index = index;
  store.state.status = "loading";
  loadItem(item, startPosition);
  emit();
  updateMediaMetadata(item);
  store.lastSaveAt = Date.now();

  void audioEl()
    .play()
    .catch(() => {
      store.state.status = "paused";
      emit();
    });
}

/** Restore a session without starting playback — one tap resumes. */
export function loadPaused(queue: QueueItem[], index: number, startPosition: number | null = null): void {
  installGlobals();
  if (store.state.status !== "idle") return; // never clobber active playback
  const item = queue[index];
  if (!item) return;

  store.state.queue = queue;
  store.state.index = index;
  store.state.status = "paused";
  loadItem(item, startPosition);
  emit();
  updateMediaMetadata(item);
}

/**
 * Swap in a richer queue (e.g. the full book once its detail loads) without
 * interrupting whatever is playing.
 */
export function replaceQueue(queue: QueueItem[]): void {
  const item = currentItem(store.state);
  if (!item) return;
  const index = queue.findIndex(q => q.chapterId === item.chapterId);
  if (index < 0) return;
  // Keep the exact item that is loaded so the key/src stay consistent.
  const next = [...queue];
  next[index] = item;
  store.state.queue = next;
  store.state.index = index;
  emit();
}

export function toggle(): void {
  const item = currentItem(store.state);
  if (!item) return;
  const audio = audioEl();

  if (store.state.status === "playing" || store.state.status === "loading") {
    audio.pause();
    return;
  }

  if (!store.state.loaded || store.loadedKey !== itemKey(item)) {
    // Stopped at an unloaded chapter (e.g. auto-advance halted at an
    // unconverted one) — start it fresh.
    playQueue(store.state.queue, store.state.index, store.state.position || null);
    return;
  }

  audio.playbackRate = store.state.rate;
  void audio.play().catch(() => undefined);
}

/** Stop playback without changing what is loaded — used when a preview starts. */
export function pause(): void {
  if (store.state.status === "playing" || store.state.status === "loading") store.audio?.pause();
}

export function seekTo(seconds: number): void {
  const item = currentItem(store.state);
  if (!item) return;
  const audio = audioEl();
  if (item.source.kind === "live") {
    const wasPlaying = store.state.status === "playing" || store.state.status === "loading";
    store.loadedKey = null;
    loadItem(item, seconds);
    emit();
    if (wasPlaying) void audio.play().catch(() => undefined);
    void persistNow(false);
    return;
  }
  const max = Number.isFinite(audio.duration) ? audio.duration - 0.25 : seconds;
  audio.currentTime = Math.max(0, Math.min(seconds, max));
  store.state.position = audio.currentTime;
  emit();
  void persistNow(false);
}

export function seekBy(delta: number): void {
  const item = currentItem(store.state);
  if (!item) return;
  seekTo(store.state.position + delta);
}

export function playIndex(index: number): void {
  const item = store.state.queue[index];
  if (!item) return;
  playQueue(store.state.queue, index, null);
}

export function next(): void {
  const state = store.state;
  if (state.index < state.queue.length - 1) jumpTo(state.index + 1);
}

export function previous(): void {
  const audio = audioEl();
  // Like every audiobook player: early in a chapter go to the previous one,
  // otherwise restart the current chapter.
  if (audio.currentTime > 4 && currentItem(store.state)?.source.kind === "track") {
    seekTo(0);
    return;
  }
  if (store.state.index > 0) jumpTo(store.state.index - 1);
  else seekTo(0);
}

function streamAdvanceEnabled(): boolean {
  try {
    return localStorage.getItem(STREAM_ADVANCE_KEY) === "1";
  } catch {
    return false;
  }
}

function jumpTo(index: number): void {
  const item = store.state.queue[index];
  if (!item) return;

  const wasPlaying = store.state.status === "playing" || store.state.status === "loading";
  if (item.source.kind === "live" && !wasPlaying) {
    // Don't open a synthesis stream unless the user actually wants sound now.
    parkAt(index);
    return;
  }
  playQueue(store.state.queue, index, null);
}

/** Move the needle to a chapter but stay paused, without loading its audio. */
function parkAt(index: number): void {
  void persistNow(false);
  store.state.index = index;
  store.state.status = "paused";
  store.state.loaded = false;
  store.state.position = 0;
  const item = store.state.queue[index]!;
  store.state.duration = item.source.kind === "track" ? item.source.duration : item.source.estimatedDuration;
  audioEl().pause();
  emit();
  updateMediaMetadata(item);
}

/** Auto-advance after a chapter ends. */
function advance(): void {
  const state = store.state;
  const nextIndex = state.index + 1;
  const nextItem = state.queue[nextIndex];

  if (!nextItem) {
    state.status = "paused";
    emit();
    return;
  }

  if (nextItem.source.kind === "live" && !streamAdvanceEnabled()) {
    // Stop at the unconverted chapter; play stays one tap away.
    parkAt(nextIndex);
    return;
  }

  playQueue(state.queue, nextIndex, null);
}

export function setRate(rate: number): void {
  store.state.rate = rate;
  try {
    localStorage.setItem(RATE_KEY, String(rate));
  } catch {
    // Best effort.
  }
  if (store.audio) store.audio.playbackRate = rate;
  emit();
}

export function cycleRate(): void {
  const index = RATES.indexOf(store.state.rate);
  setRate(RATES[(index + 1) % RATES.length]!);
}

export function setExpanded(expanded: boolean): void {
  store.state.expanded = expanded;
  emit();
}

/* ------------------------------------------------------------------ */
/* Sleep timer                                                         */
/* ------------------------------------------------------------------ */

const SLEEP_STEPS = [15, 30, 45, 60] as const;

export function cycleSleep(): void {
  const sleep = store.state.sleep;
  if (!sleep) return setSleep({ kind: "minutes", minutes: 15, until: Date.now() + 15 * 60_000 });
  if (sleep.kind === "chapter") return setSleep(null);
  const at = SLEEP_STEPS.indexOf(sleep.minutes as (typeof SLEEP_STEPS)[number]);
  const nextStep = SLEEP_STEPS[at + 1];
  if (nextStep) return setSleep({ kind: "minutes", minutes: nextStep, until: Date.now() + nextStep * 60_000 });
  setSleep({ kind: "chapter" });
}

export function setSleep(sleep: SleepTimer): void {
  if (store.sleepTimeout) {
    clearTimeout(store.sleepTimeout);
    store.sleepTimeout = null;
  }
  if (store.fadeInterval) {
    clearInterval(store.fadeInterval);
    store.fadeInterval = null;
    if (store.audio) store.audio.volume = 1;
  }

  store.state.sleep = sleep;
  emit();

  if (sleep?.kind === "minutes") {
    store.sleepTimeout = setTimeout(fadeOutAndPause, Math.max(0, sleep.until - Date.now()));
  }
}

function fadeOutAndPause(): void {
  const audio = store.audio;
  if (!audio || audio.paused) {
    setSleep(null);
    return;
  }
  const steps = 30; // 3 seconds
  let step = 0;
  store.fadeInterval = setInterval(() => {
    step++;
    audio.volume = Math.max(0, 1 - step / steps);
    if (step >= steps) {
      clearInterval(store.fadeInterval!);
      store.fadeInterval = null;
      audio.pause();
      audio.volume = 1;
      setSleep(null);
    }
  }, 100);
}

/* ------------------------------------------------------------------ */
/* Position persistence                                                */
/* ------------------------------------------------------------------ */

function positionPayload(item: QueueItem, position: number, completed: boolean): string {
  return JSON.stringify({
    trackId: item.source.kind === "track" ? item.source.trackId : null,
    positionSeconds: position,
    durationSeconds: store.state.duration,
    completed,
  });
}

function maybeAutosave(): void {
  if (store.state.status !== "playing") return;
  if (Date.now() - store.lastSaveAt < SAVE_INTERVAL_MS) return;
  void persistNow(false);
}

/** Write the current spot to the server for converted and live chapters. */
async function persistNow(useBeacon: boolean): Promise<void> {
  const item = currentItem(store.state);
  const audio = store.audio;
  if (!item || !audio || !store.state.loaded) return;

  const position = store.state.position;
  if (position < MIN_SAVE_SECONDS) return;

  store.lastSaveAt = Date.now();
  const url = `/api/chapters/${item.chapterId}/position`;
  const body = positionPayload(item, position, false);

  if (useBeacon && "sendBeacon" in navigator) {
    navigator.sendBeacon(url, new Blob([body], { type: "application/json" }));
    return;
  }
  await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
    keepalive: useBeacon,
  }).catch(() => undefined);
}

async function persistCompleted(item: QueueItem): Promise<void> {
  store.lastSaveAt = Date.now();
  await fetch(`/api/chapters/${item.chapterId}/position`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: positionPayload(item, store.state.duration ?? store.state.position, true),
  }).catch(() => undefined);
}

/* ------------------------------------------------------------------ */
/* Media Session + hotkeys                                             */
/* ------------------------------------------------------------------ */

function setMediaPlaybackState(state: "playing" | "paused"): void {
  if ("mediaSession" in navigator) navigator.mediaSession.playbackState = state;
}

function updateMediaMetadata(item: QueueItem): void {
  if (!("mediaSession" in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: item.chapterTitle,
    artist: item.author ?? "huiver",
    album: item.bookTitle,
    artwork: [
      {
        src: item.coverUrl ? new URL(item.coverUrl, location.origin).href : coverArtworkDataUrl(item.bookId, item.bookTitle),
        sizes: "512x512",
        type: item.coverUrl ? "" : "image/png",
      },
    ],
  });
}

function updatePositionState(): void {
  if (!("mediaSession" in navigator) || !navigator.mediaSession.setPositionState) return;
  const audio = store.audio;
  if (!audio || !Number.isFinite(audio.duration) || audio.duration <= 0) return;
  try {
    navigator.mediaSession.setPositionState({
      duration: audio.duration,
      playbackRate: audio.playbackRate,
      position: Math.min(audio.currentTime, audio.duration),
    });
  } catch {
    // Some browsers are picky about transient values.
  }
}

/** Anything that handles keys itself — inputs, buttons, Radix widgets. */
const isTypingTarget = (target: EventTarget | null): boolean => {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  if (["INPUT", "TEXTAREA", "SELECT", "BUTTON", "A"].includes(target.tagName)) return true;
  const role = target.getAttribute("role");
  return (
    role !== null
    && ["slider", "combobox", "listbox", "option", "menuitem", "switch", "button", "dialog"].includes(role)
  );
};

function installGlobals(): void {
  if (store.globalsInstalled || typeof window === "undefined") return;
  store.globalsInstalled = true;

  window.addEventListener("pagehide", () => void persistNow(true));

  document.addEventListener("keydown", event => {
    if (store.state.index < 0 || isTypingTarget(event.target)) return;
    if (event.key === " ") {
      event.preventDefault();
      toggle();
    } else if (event.key === "ArrowLeft") {
      seekBy(-15);
    } else if (event.key === "ArrowRight") {
      seekBy(30);
    }
  });

  if ("mediaSession" in navigator) {
    const session = navigator.mediaSession;
    session.setActionHandler("play", () => toggle());
    session.setActionHandler("pause", () => toggle());
    session.setActionHandler("seekbackward", details => seekBy(-(details.seekOffset ?? 15)));
    session.setActionHandler("seekforward", details => seekBy(details.seekOffset ?? 30));
    session.setActionHandler("previoustrack", () => previous());
    session.setActionHandler("nexttrack", () => next());
    try {
      session.setActionHandler("seekto", details => {
        if (typeof details.seekTime === "number") seekTo(details.seekTime);
      });
    } catch {
      // Older browsers don't support seekto.
    }
  }
}

/* ------------------------------------------------------------------ */
/* Queue building + session restore                                    */
/* ------------------------------------------------------------------ */

export function liveStreamUrl(
  chapterId: string,
  settings: Pick<SettingsDTO, "defaultProvider" | "defaultVoice">,
  startPosition = 0,
): string {
  // Rendered at 1.0; the audio element's playbackRate handles the rest.
  const params = new URLSearchParams({ provider: settings.defaultProvider });
  if (settings.defaultVoice) params.set("voice", settings.defaultVoice);
  if (startPosition > MIN_SAVE_SECONDS) params.set("start", String(Math.floor(startPosition)));
  return `/api/chapters/${chapterId}/stream?${params}`;
}

/** The whole book as a play queue: converted chapters seekable, the rest live. */
export function buildQueueFromBook(book: BookDetailDTO, settings: SettingsDTO): QueueItem[] {
  return book.chapters.map(chapter => ({
    bookId: book.id,
    bookTitle: book.title,
    author: book.author,
    coverUrl: book.coverUrl,
    chapterId: chapter.id,
    chapterIdx: chapter.idx,
    chapterTitle: chapter.title,
    source: chapter.audio
      ? { kind: "track", url: chapter.audio.url, trackId: chapter.audio.trackId, duration: chapter.audio.duration }
      : {
          kind: "live",
          url: liveStreamUrl(chapter.id, settings, chapter.position?.positionSeconds ?? 0),
          estimatedDuration: chapter.estimatedDurationSeconds,
          startPosition: chapter.position?.positionSeconds ?? 0,
        },
  }));
}
