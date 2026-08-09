export type Voice = { id: string; label: string };

export type ProviderInfo = {
  id: string;
  label: string;
  local: boolean;
  available: boolean;
  /** Why the provider cannot be used, when `available` is false. */
  reason?: string;
  voices: Voice[];
  defaultVoice: string;
  supportsSpeed: boolean;
};

export type TrackRequest = {
  /** Ordered text chunks that make up one output track. */
  chunks: string[];
  voice: string;
  speed: number;
  /** Absolute path of the WAV file to write. */
  outWav: string;
  onChunk?: (done: number, total: number) => void;
};

export type StreamRequest = {
  chunks: string[];
  voice: string;
  speed: number;
  /** Called with 16-bit mono PCM as soon as each chunk is rendered. */
  onAudio: (pcm: Uint8Array) => Promise<void> | void;
  signal?: AbortSignal;
};

/**
 * A provider session. Local providers keep a warm model between tracks, remote
 * ones just hold config — either way the caller must `close()` when done.
 */
export type TTSSession = {
  /** Sample rate of the PCM handed to `stream`'s `onAudio`. */
  sampleRate: number;
  synthesize: (req: TrackRequest) => Promise<{ durationSec: number }>;
  /** Render progressively for live playback, instead of writing a whole file. */
  stream: (req: StreamRequest) => Promise<void>;
  close: () => Promise<void>;
};

export type TTSProvider = {
  info: () => Promise<ProviderInfo>;
  open: () => Promise<TTSSession>;
};
