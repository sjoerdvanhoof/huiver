import { floatToPcm16 } from "@huiver/shared";
import { createTTS, type TtsEngine } from "react-native-sherpa-onnx/tts";
import { ensureModelPath } from "./model";
import { voiceSid } from "./voices";

/**
 * On-device speech, in the shape the server's TTS provider has
 * (apps/web/src/server/tts/types.ts): open a session, synthesize chunks, close.
 *
 * The engine holds several hundred megabytes of weights while it is open, so
 * there is one session at a time and it retires itself when nothing has used it
 * for a while — the same bargain the server's warm-session pool strikes.
 */

export type TtsSession = {
  readonly sampleRate: number;
  /** One chunk of text to 16-bit mono PCM. */
  synthesize(text: string, voice: string, speed: number): Promise<Uint8Array>;
};

const IDLE_RETIRE_MS = 2 * 60 * 1000;

let engine: TtsEngine | null = null;
let opening: Promise<TtsEngine> | null = null;
let sampleRate = 24000;
let leases = 0;
let retireTimer: ReturnType<typeof setTimeout> | null = null;

async function open(): Promise<TtsEngine> {
  if (engine) return engine;
  if (opening) return opening;

  opening = (async () => {
    const modelPath = await ensureModelPath();
    const created = await createTTS({
      modelPath: { type: "file", path: modelPath },
      modelType: "kokoro",
      // One sentence per native callback keeps peak memory down; our own
      // chunker has already cut the text to a size Kokoro handles well.
      maxNumSentences: 1,
    });

    sampleRate = await created.getSampleRate().catch(() => 24000);
    engine = created;
    return created;
  })();

  try {
    return await opening;
  } finally {
    opening = null;
  }
}

function scheduleRetire(): void {
  if (retireTimer) clearTimeout(retireTimer);
  retireTimer = setTimeout(() => {
    if (leases > 0) return;
    const retiring = engine;
    engine = null;
    void retiring?.destroy().catch(() => undefined);
  }, IDLE_RETIRE_MS);
}

/**
 * Borrow the speech engine. Release it when the chapter is done; the engine
 * stays warm for a couple of minutes in case the next chapter follows.
 */
export async function acquireSession(): Promise<{ session: TtsSession; release: () => void }> {
  if (retireTimer) clearTimeout(retireTimer);
  leases++;

  let active: TtsEngine;
  try {
    active = await open();
  } catch (error) {
    leases--;
    scheduleRetire();
    throw error;
  }

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    leases = Math.max(0, leases - 1);
    if (leases === 0) scheduleRetire();
  };

  const session: TtsSession = {
    get sampleRate() {
      return sampleRate;
    },
    async synthesize(text, voice, speed) {
      const audio = await active.generateSpeech(text, { sid: voiceSid(voice), speed });
      return floatToPcm16(audio.samples);
    },
  };

  return { session, release };
}

/** Drop the engine now, whatever the idle timer thinks. */
export async function closeSession(): Promise<void> {
  if (retireTimer) clearTimeout(retireTimer);
  const retiring = engine;
  engine = null;
  leases = 0;
  await retiring?.destroy().catch(() => undefined);
}

export { VOICES, DEFAULT_VOICE, findVoice, voiceSid, type Voice } from "./voices";
export {
  MODEL_ID,
  APPROX_DOWNLOAD_BYTES,
  deleteModel,
  downloadModel,
  ensureModelPath,
  getModelState,
  isModelReady,
  refreshModelState,
  useModelState,
  type ModelState,
} from "./model";
