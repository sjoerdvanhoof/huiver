import type { Database } from "bun:sqlite";
import type { SettingsDTO } from "../shared";
import { db as defaultDb } from "./db";
import { PROVIDERS } from "./tts";

export type Settings = SettingsDTO;

export const DEFAULT_SETTINGS: Settings = {
  defaultProvider: "kokoro",
  defaultVoice: null,
  defaultSpeed: 1,
  theme: "system",
};

const THEMES = new Set(["system", "light", "dark"]);

export function getSettings(database: Database = defaultDb): Settings {
  const rows = database.query("SELECT key, value FROM settings").all() as { key: string; value: string }[];

  const stored: Record<string, unknown> = {};
  for (const row of rows) {
    try {
      stored[row.key] = JSON.parse(row.value);
    } catch {
      // A corrupt value falls back to the default.
    }
  }

  const settings = { ...DEFAULT_SETTINGS };
  if (typeof stored.defaultProvider === "string" && stored.defaultProvider in PROVIDERS) {
    settings.defaultProvider = stored.defaultProvider;
  }
  if (typeof stored.defaultVoice === "string" || stored.defaultVoice === null) {
    settings.defaultVoice = (stored.defaultVoice as string | null) || null;
  }
  if (typeof stored.defaultSpeed === "number" && Number.isFinite(stored.defaultSpeed)) {
    settings.defaultSpeed = clampSpeed(stored.defaultSpeed);
  }
  if (typeof stored.theme === "string" && THEMES.has(stored.theme)) {
    settings.theme = stored.theme as Settings["theme"];
  }
  return settings;
}

const clampSpeed = (speed: number) => Math.min(2, Math.max(0.5, speed));

/** Validate and persist a partial update. Throws on unknown keys or bad values. */
export function updateSettings(patch: Record<string, unknown>, database: Database = defaultDb): Settings {
  const values = new Map<string, unknown>();

  for (const [key, value] of Object.entries(patch)) {
    switch (key) {
      case "defaultProvider":
        if (typeof value !== "string" || !(value in PROVIDERS)) throw new Error(`Unknown provider: ${value}`);
        values.set(key, value);
        break;
      case "defaultVoice":
        if (value !== null && typeof value !== "string") throw new Error("defaultVoice must be a string or null");
        values.set(key, value || null);
        break;
      case "defaultSpeed": {
        const speed = Number(value);
        if (!Number.isFinite(speed)) throw new Error("defaultSpeed must be a number");
        values.set(key, clampSpeed(speed));
        break;
      }
      case "theme":
        if (typeof value !== "string" || !THEMES.has(value)) throw new Error(`Unknown theme: ${value}`);
        values.set(key, value);
        break;
      default:
        throw new Error(`Unknown setting: ${key}`);
    }
  }

  const upsert = database.query(
    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  );
  database.transaction(() => {
    for (const [key, value] of values) upsert.run(key, JSON.stringify(value));
  })();

  return getSettings(database);
}
