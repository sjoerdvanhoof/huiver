import { expect, test } from "bun:test";
import { DEFAULT_VOICE, VOICES, findVoice, voiceSid } from "./voices";

/**
 * The speaker ids are the one thing here that cannot be checked by reading the
 * code: they index into kokoro-multi-lang-v1_0's `voices.bin`, and a wrong
 * number means the wrong person reads the book. This pins them against the
 * `speaker2id` table embedded in that model, so a careless edit fails loudly.
 */
const SPEAKER2ID: Record<string, number> = {
  af_alloy: 0, af_aoede: 1, af_bella: 2, af_heart: 3, af_jessica: 4, af_kore: 5,
  af_nicole: 6, af_nova: 7, af_river: 8, af_sarah: 9, af_sky: 10, am_adam: 11,
  am_echo: 12, am_eric: 13, am_fenrir: 14, am_liam: 15, am_michael: 16,
  am_onyx: 17, am_puck: 18, am_santa: 19, bf_alice: 20, bf_emma: 21,
  bf_isabella: 22, bf_lily: 23, bm_daniel: 24, bm_fable: 25, bm_george: 26,
  bm_lewis: 27,
};

test("every voice points at the right Kokoro speaker", () => {
  for (const voice of VOICES) {
    expect(SPEAKER2ID[voice.id]).toBeDefined();
    expect(voice.sid).toBe(SPEAKER2ID[voice.id]!);
  }
});

test("the voice list matches the desktop app's, id for id", () => {
  // Same ids in the same order as apps/web/src/server/tts/kokoro.ts, so a book
  // sounds the same whichever huiver converted it.
  expect(VOICES.map(voice => voice.id)).toEqual([
    "af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah", "af_sky",
    "am_michael", "am_fenrir", "am_puck", "am_adam", "am_echo", "am_onyx",
    "bf_emma", "bf_isabella", "bf_alice", "bf_lily",
    "bm_george", "bm_fable", "bm_daniel", "bm_lewis",
  ]);
});

test("ids are unique and the default is one of them", () => {
  expect(new Set(VOICES.map(voice => voice.id)).size).toBe(VOICES.length);
  expect(VOICES.some(voice => voice.id === DEFAULT_VOICE)).toBe(true);
});

test("an unknown voice falls back to the default rather than throwing", () => {
  expect(findVoice("nonesuch").id).toBe(DEFAULT_VOICE);
  expect(voiceSid("nonesuch")).toBe(SPEAKER2ID[DEFAULT_VOICE]!);
});
