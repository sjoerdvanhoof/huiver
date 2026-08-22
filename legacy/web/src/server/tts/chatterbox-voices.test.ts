import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { buildWav } = await import("@huiver/shared");
const {
  BUILTIN_VOICES,
  MODEL_VOICE_ID,
  builtinPath,
  deleteRecordedVoice,
  isValidVoiceId,
  listVoiceProfiles,
  listVoices,
  newRecordedId,
  referencePath,
  saveRecordedVoice,
  usesModelVoice,
} = await import("./chatterbox-voices");

const SAMPLE_RATE = 24000;

/** A silent but structurally real WAV, long enough to read a duration off. */
const wavOf = (seconds: number) =>
  buildWav([new Uint8Array(Math.round(seconds * SAMPLE_RATE) * 2)], SAMPLE_RATE);

describe("chatterbox voice ids", () => {
  test("accepts the ids we generate and rejects path traversal", () => {
    expect(isValidVoiceId("lv_klett")).toBe(true);
    expect(isValidVoiceId(newRecordedId("My Voice"))).toBe(true);

    expect(isValidVoiceId("../../etc/passwd")).toBe(false);
    expect(isValidVoiceId("a/b")).toBe(false);
    expect(isValidVoiceId("")).toBe(false);
    // The preview route's own alphabet allows dots; filenames here must not.
    expect(isValidVoiceId("a.wav")).toBe(false);
  });

  test("a repeated name does not collide with the recording already saved", () => {
    expect(newRecordedId("My voice")).not.toBe(newRecordedId("My voice"));
  });

  test("a name of pure punctuation still yields a usable id", () => {
    expect(isValidVoiceId(newRecordedId("!!!"))).toBe(true);
  });
});

describe("chatterbox voices", () => {
  test("the model's own voice is always offered, and needs no clip", async () => {
    const voices = await listVoices();
    expect(voices.at(-1)?.id).toBe(MODEL_VOICE_ID);
    expect(usesModelVoice(MODEL_VOICE_ID)).toBe(true);
    // Null path plus the builtin flag is what tells the worker to use its own
    // conditionals; a null path on its own is an error.
    expect(referencePath(MODEL_VOICE_ID)).toBeNull();
  });

  test("a catalogue entry that was never downloaded is not offered", async () => {
    const profiles = await listVoiceProfiles();
    expect(profiles.some(profile => profile.id === BUILTIN_VOICES[0]!.id)).toBe(false);
    expect(referencePath(BUILTIN_VOICES[0]!.id)).toBeNull();
  });

  test("a downloaded clip becomes a voice", async () => {
    const voice = BUILTIN_VOICES[1]!;
    await mkdir(path.dirname(builtinPath(voice.id)), { recursive: true });
    await Bun.write(builtinPath(voice.id), wavOf(15));

    const profiles = await listVoiceProfiles();
    const found = profiles.find(profile => profile.id === voice.id);
    expect(found?.kind).toBe("builtin");
    expect(found?.seconds).toBeCloseTo(15, 1);
    expect(referencePath(voice.id)).toBe(builtinPath(voice.id));
  });

  test("recording, listing and deleting a voice", async () => {
    const id = newRecordedId("Sjoerd");
    const saved = await saveRecordedVoice(id, "Sjoerd", wavOf(12));

    expect(saved).toMatchObject({ id, label: "Sjoerd", kind: "recorded" });
    expect(saved.seconds).toBeCloseTo(12, 1);
    expect(referencePath(id)).toContain(`${id}.wav`);

    // Recorded voices sort ahead of the pack, so yours is the first one offered.
    const listed = await listVoices();
    expect(listed[0]?.id).toBe(id);
    expect(listed[0]?.label).toBe("Sjoerd (yours)");

    expect(await deleteRecordedVoice(id)).toBe(true);
    expect(referencePath(id)).toBeNull();
    expect((await listVoiceProfiles()).some(profile => profile.id === id)).toBe(false);
  });

  test("the downloaded pack cannot be deleted through the recorded-voice route", async () => {
    const voice = BUILTIN_VOICES[1]!;
    expect(await deleteRecordedVoice(voice.id)).toBe(false);
    expect(referencePath(voice.id)).not.toBeNull();

    // Nor can a crafted id reach outside the voices directory.
    expect(await deleteRecordedVoice("../../../etc/passwd")).toBe(false);
  });

  test("deleting a voice that was never recorded is not an error", async () => {
    expect(await deleteRecordedVoice("my_nothing_abc123")).toBe(false);
  });
});
