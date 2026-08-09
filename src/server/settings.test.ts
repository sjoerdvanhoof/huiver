import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { runMigrations } = await import("./db");
const { getSettings, updateSettings, DEFAULT_SETTINGS } = await import("./settings");

function freshDb(): Database {
  const db = new Database(":memory:");
  runMigrations(db);
  return db;
}

describe("settings", () => {
  test("returns defaults on an empty table", () => {
    expect(getSettings(freshDb())).toEqual(DEFAULT_SETTINGS);
  });

  test("partial patch merges over defaults and persists", () => {
    const db = freshDb();
    const updated = updateSettings({ defaultVoice: "af_heart" }, db);
    expect(updated.defaultVoice).toBe("af_heart");
    expect(updated.defaultProvider).toBe("kokoro");

    // A second patch keeps earlier keys.
    updateSettings({ theme: "dark" }, db);
    const settings = getSettings(db);
    expect(settings.defaultVoice).toBe("af_heart");
    expect(settings.theme).toBe("dark");
  });

  test("rejects unknown keys, providers and themes", () => {
    const db = freshDb();
    expect(() => updateSettings({ nonsense: 1 }, db)).toThrow(/Unknown setting/);
    expect(() => updateSettings({ defaultProvider: "does-not-exist" }, db)).toThrow(/Unknown provider/);
    expect(() => updateSettings({ theme: "sepia" }, db)).toThrow(/Unknown theme/);
  });

  test("synthesis speed is no longer a setting", () => {
    const db = freshDb();
    expect(() => updateSettings({ defaultSpeed: 1.25 }, db)).toThrow(/Unknown setting/);
    expect(getSettings(db)).not.toHaveProperty("defaultSpeed");
  });

  test("ignores a defaultSpeed row left over from an older version", () => {
    const db = freshDb();
    db.query("INSERT INTO settings (key, value) VALUES ('defaultSpeed', '1.5')").run();
    expect(getSettings(db)).toEqual(DEFAULT_SETTINGS);
  });

  test("empty-string voice is stored as null (provider default)", () => {
    const db = freshDb();
    updateSettings({ defaultVoice: "af_heart" }, db);
    expect(updateSettings({ defaultVoice: "" }, db).defaultVoice).toBeNull();
  });
});
