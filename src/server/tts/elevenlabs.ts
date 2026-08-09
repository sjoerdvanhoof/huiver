import { silencePcm16, writeWavFromPcm16 } from "../wav";
import type { ProviderInfo, StreamRequest, TTSProvider, TTSSession, TrackRequest, Voice } from "./types";

const SAMPLE_RATE = 24000;
const MODEL = process.env.ELEVENLABS_MODEL ?? "eleven_multilingual_v2";

/**
 * Untested — no API key was available while building. Kept minimal and behind
 * an env-var gate so the provider registry has a real third implementation.
 */
export const elevenlabsProvider: TTSProvider = {
  async info(): Promise<ProviderInfo> {
    const key = process.env.ELEVENLABS_API_KEY;
    let voices: Voice[] = [];

    if (key) {
      try {
        const response = await fetch("https://api.elevenlabs.io/v1/voices", {
          headers: { "xi-api-key": key },
        });
        if (response.ok) {
          const body = (await response.json()) as { voices?: { voice_id: string; name: string }[] };
          voices = (body.voices ?? []).map(v => ({ id: v.voice_id, label: v.name }));
        }
      } catch {
        // Fall through to "available but no voices listed".
      }
    }

    return {
      id: "elevenlabs",
      label: "ElevenLabs",
      local: false,
      available: Boolean(key),
      reason: key ? undefined : "Set ELEVENLABS_API_KEY in .env to enable",
      voices,
      defaultVoice: voices[0]?.id ?? "",
      supportsSpeed: false,
    };
  },

  async open(): Promise<TTSSession> {
    const key = process.env.ELEVENLABS_API_KEY;
    if (!key) throw new Error("ELEVENLABS_API_KEY is not set");

    const speak = async (text: string, voice: string, signal?: AbortSignal) => {
      const url = `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voice)}?output_format=pcm_${SAMPLE_RATE}`;
      const response = await fetch(url, {
        method: "POST",
        headers: { "xi-api-key": key, "Content-Type": "application/json" },
        body: JSON.stringify({ text, model_id: MODEL }),
        signal,
      });
      if (!response.ok) {
        throw new Error(`ElevenLabs ${response.status}: ${(await response.text()).slice(0, 300)}`);
      }
      return new Uint8Array(await response.arrayBuffer());
    };

    return {
      sampleRate: SAMPLE_RATE,

      async synthesize(req: TrackRequest) {
        const parts: Uint8Array<ArrayBuffer>[] = [];
        const gap = silencePcm16(0.25, SAMPLE_RATE);

        for (const [index, text] of req.chunks.entries()) {
          parts.push(await speak(text, req.voice), gap);
          req.onChunk?.(index + 1, req.chunks.length);
        }
        return writeWavFromPcm16(req.outWav, parts, SAMPLE_RATE);
      },

      async stream(req: StreamRequest) {
        const gap = silencePcm16(0.25, SAMPLE_RATE);
        for (const text of req.chunks) {
          if (req.signal?.aborted) return;
          await req.onAudio(await speak(text, req.voice, req.signal));
          await req.onAudio(gap);
        }
      },

      async close() {},
    };
  },
};
