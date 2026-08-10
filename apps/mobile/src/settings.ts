import { useSyncExternalStore } from "react";
import { db } from "./db";

/**
 * Preferences, in the same `settings` key/value table the server uses.
 *
 * A module-level snapshot published through `useSyncExternalStore`, so the
 * player, the book page and the settings sheet always agree — the same shape
 * the web app uses for its player store.
 */

export type Theme = "system" | "light" | "dark";

export type Settings = {
  /** Kokoro voice id, matching the web app's ids exactly (see src/tts/voices). */
  voice: string;
  /** Playback rate, cycled from the player and remembered across launches. */
  rate: number;
  theme: Theme;
  /**
   * Whether reaching an unconverted chapter starts synthesizing it, or parks
   * there paused. Mirrors the web's `huiver:stream-advance`.
   */
  autoAdvanceIntoUnconverted: boolean;
};

export const DEFAULTS: Settings = {
  voice: "af_heart",
  rate: 1,
  theme: "system",
  autoAdvanceIntoUnconverted: false,
};

function readAll(): Settings {
  const rows = db.getAllSync<{ key: string; value: string }>("SELECT key, value FROM settings");
  const stored = new Map(rows.map(row => [row.key, row.value]));
  const raw = (key: string) => stored.get(key);

  const rate = Number(raw("rate"));
  const theme = raw("theme");

  return {
    voice: raw("voice") ?? DEFAULTS.voice,
    rate: Number.isFinite(rate) && rate > 0 ? rate : DEFAULTS.rate,
    theme: theme === "light" || theme === "dark" || theme === "system" ? theme : DEFAULTS.theme,
    autoAdvanceIntoUnconverted: raw("autoAdvanceIntoUnconverted") === "1",
  };
}

let snapshot: Settings = readAll();
const listeners = new Set<() => void>();

const serialize = (value: Settings[keyof Settings]): string =>
  typeof value === "boolean" ? (value ? "1" : "0") : String(value);

export function updateSettings(patch: Partial<Settings>): void {
  db.withTransactionSync(() => {
    for (const [key, value] of Object.entries(patch)) {
      if (value === undefined) continue;
      db.runSync("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [
        key,
        serialize(value as Settings[keyof Settings]),
      ]);
    }
  });

  snapshot = { ...snapshot, ...patch };
  listeners.forEach(listener => listener());
}

export const getSettings = (): Settings => snapshot;

const subscribe = (onChange: () => void) => {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
};

export function useSettings(): Settings {
  return useSyncExternalStore(subscribe, getSettings);
}
