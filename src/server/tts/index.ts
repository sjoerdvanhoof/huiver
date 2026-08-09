import { elevenlabsProvider } from "./elevenlabs";
import { kokoroProvider } from "./kokoro";
import { openaiProvider } from "./openai";
import type { TTSProvider } from "./types";

export const PROVIDERS: Record<string, TTSProvider> = {
  kokoro: kokoroProvider,
  openai: openaiProvider,
  elevenlabs: elevenlabsProvider,
};

export function getProvider(id: string): TTSProvider {
  const provider = PROVIDERS[id];
  if (!provider) throw new Error(`Unknown TTS provider: ${id}`);
  return provider;
}

export const listProviders = () => Promise.all(Object.values(PROVIDERS).map(p => p.info()));

export type { ProviderInfo, TTSProvider, TTSSession, TrackRequest, Voice } from "./types";
