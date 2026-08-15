/**
 * Kokoro's voices, with the speaker ids sherpa-onnx selects them by.
 *
 * The ids and labels are the web app's exactly (apps/web/src/server/tts/kokoro.ts),
 * so a book converted on the desktop and one converted on the phone are read by
 * the same voice. The numbers come from the `speaker2id` metadata embedded in
 * kokoro-multi-lang-v1_0's model.onnx — Kokoro ships 53 speakers and these are
 * the English ones.
 */
export type Voice = { id: string; label: string; sid: number };

export const VOICES: Voice[] = [
  { id: "af_heart", label: "Heart — US female", sid: 3 },
  { id: "af_bella", label: "Bella — US female", sid: 2 },
  { id: "af_nicole", label: "Nicole — US female (soft)", sid: 6 },
  { id: "af_aoede", label: "Aoede — US female", sid: 1 },
  { id: "af_kore", label: "Kore — US female", sid: 5 },
  { id: "af_sarah", label: "Sarah — US female", sid: 9 },
  { id: "af_sky", label: "Sky — US female", sid: 10 },
  { id: "am_michael", label: "Michael — US male", sid: 16 },
  { id: "am_fenrir", label: "Fenrir — US male", sid: 14 },
  { id: "am_puck", label: "Puck — US male", sid: 18 },
  { id: "am_adam", label: "Adam — US male", sid: 11 },
  { id: "am_echo", label: "Echo — US male", sid: 12 },
  { id: "am_onyx", label: "Onyx — US male", sid: 17 },
  { id: "bf_emma", label: "Emma — UK female", sid: 21 },
  { id: "bf_isabella", label: "Isabella — UK female", sid: 22 },
  { id: "bf_alice", label: "Alice — UK female", sid: 20 },
  { id: "bf_lily", label: "Lily — UK female", sid: 23 },
  { id: "bm_george", label: "George — UK male", sid: 26 },
  { id: "bm_fable", label: "Fable — UK male", sid: 25 },
  { id: "bm_daniel", label: "Daniel — UK male", sid: 24 },
  { id: "bm_lewis", label: "Lewis — UK male", sid: 27 },
];

export const DEFAULT_VOICE = "af_heart";

const BY_ID = new Map(VOICES.map(voice => [voice.id, voice]));

export const findVoice = (id: string): Voice => BY_ID.get(id) ?? BY_ID.get(DEFAULT_VOICE)!;

/** The speaker id sherpa expects for a voice. Unknown ids fall back to Heart. */
export const voiceSid = (id: string): number => findVoice(id).sid;
