import { appendPcm16ToWav, silencePcm16, writeWavFromPcm16 } from "../wav";
import type { ProviderInfo, StreamRequest, TTSProvider, TTSSession, TrackRequest } from "./types";

const SAMPLE_RATE = 24000; // What the OpenAI speech API emits for response_format: "pcm".
const MODEL = process.env.OPENAI_TTS_MODEL ?? "gpt-4o-mini-tts";

const VOICES = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"];

/**
 * Untested — no API key was available while building. Kept minimal and behind
 * an env-var gate so the provider registry has a real second implementation.
 */
export const openaiProvider: TTSProvider = {
  async info(): Promise<ProviderInfo> {
    const key = process.env.OPENAI_API_KEY;
    return {
      id: "openai",
      label: "OpenAI TTS",
      local: false,
      available: Boolean(key),
      reason: key ? undefined : "Set OPENAI_API_KEY in .env to enable",
      voices: VOICES.map(id => ({ id, label: id[0]!.toUpperCase() + id.slice(1) })),
      defaultVoice: "alloy",
      supportsSpeed: true,
    };
  },

  async open(): Promise<TTSSession> {
    const key = process.env.OPENAI_API_KEY;
    if (!key) throw new Error("OPENAI_API_KEY is not set");

    const speak = async (text: string, voice: string, speed: number, signal?: AbortSignal) => {
      const response = await fetch("https://api.openai.com/v1/audio/speech", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model: MODEL, voice, input: text, response_format: "pcm", speed }),
        signal,
      });
      if (!response.ok) {
        throw new Error(`OpenAI TTS ${response.status}: ${(await response.text()).slice(0, 300)}`);
      }
      return new Uint8Array(await response.arrayBuffer());
    };

    return {
      sampleRate: SAMPLE_RATE,

      async synthesize(req: TrackRequest) {
        const parts: Uint8Array<ArrayBuffer>[] = [];
        const gap = silencePcm16(0.25, SAMPLE_RATE);

        for (const [index, text] of req.chunks.entries()) {
          if (req.signal?.aborted) break;
          parts.push(await speak(text, req.voice, req.speed, req.signal), gap);
          req.onChunk?.(index + 1, req.chunks.length);
        }
        return req.append
          ? appendPcm16ToWav(req.outWav, parts, SAMPLE_RATE)
          : writeWavFromPcm16(req.outWav, parts, SAMPLE_RATE);
      },

      async stream(req: StreamRequest) {
        const gap = silencePcm16(0.25, SAMPLE_RATE);
        for (const [index, text] of req.chunks.entries()) {
          if (req.signal?.aborted) return;
          const pcm = await speak(text, req.voice, req.speed, req.signal);
          const withGap = new Uint8Array(pcm.byteLength + gap.byteLength);
          withGap.set(pcm);
          withGap.set(gap, pcm.byteLength);
          // One call per chunk, gap included, so a stored stream never ends up
          // with a chunk recorded as done but its trailing pause missing.
          await req.onAudio(withGap, index);
        }
      },

      async close() {},
    };
  },
};
