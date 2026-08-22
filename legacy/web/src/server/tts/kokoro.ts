import { existsSync } from "node:fs";
import path from "node:path";
import { PythonWorkerSession, RecyclingWorkerSession, type WorkerOptions } from "./python-worker";
import type { ProviderInfo, TTSProvider, TTSSession, Voice } from "./types";

// Anchored to this file rather than the cwd: the venv and the worker script
// belong to this app, not to whatever directory the process happens to start in
// (the repo root, a test runner, an editor task).
const APP_ROOT = path.join(import.meta.dir, "..", "..", "..");
const PYTHON = process.env.HUIVER_PYTHON ?? path.join(APP_ROOT, ".venv", "bin", "python");
const WORKER = path.join(APP_ROOT, "py", "kokoro_worker.py");
const RECYCLE_CHUNKS = Math.max(1, Number(process.env.HUIVER_MPS_RECYCLE_CHUNKS) || 6);

// Kokoro ships a fixed voice set; the prefix encodes accent + gender
// (a = American, b = British; f = female, m = male).
const VOICES: Voice[] = [
  { id: "af_heart", label: "Heart — US female" },
  { id: "af_bella", label: "Bella — US female" },
  { id: "af_nicole", label: "Nicole — US female (soft)" },
  { id: "af_aoede", label: "Aoede — US female" },
  { id: "af_kore", label: "Kore — US female" },
  { id: "af_sarah", label: "Sarah — US female" },
  { id: "af_sky", label: "Sky — US female" },
  { id: "am_michael", label: "Michael — US male" },
  { id: "am_fenrir", label: "Fenrir — US male" },
  { id: "am_puck", label: "Puck — US male" },
  { id: "am_adam", label: "Adam — US male" },
  { id: "am_echo", label: "Echo — US male" },
  { id: "am_onyx", label: "Onyx — US male" },
  { id: "bf_emma", label: "Emma — UK female" },
  { id: "bf_isabella", label: "Isabella — UK female" },
  { id: "bf_alice", label: "Alice — UK female" },
  { id: "bf_lily", label: "Lily — UK female" },
  { id: "bm_george", label: "George — UK male" },
  { id: "bm_fable", label: "Fable — UK male" },
  { id: "bm_daniel", label: "Daniel — UK male" },
  { id: "bm_lewis", label: "Lewis — UK male" },
];

const WORKER_OPTIONS: WorkerOptions = {
  name: "kokoro",
  python: PYTHON,
  script: WORKER,
  cwd: APP_ROOT,
  sampleRate: 24000,
};

export const kokoroProvider: TTSProvider = {
  async info(): Promise<ProviderInfo> {
    const missing = !existsSync(PYTHON)
      ? `Python venv not found at ${PYTHON}. Run: bun run setup:python`
      : !existsSync(WORKER)
        ? `Worker script missing at ${WORKER}`
        : undefined;

    return {
      id: "kokoro",
      label: "Kokoro 82M (local)",
      local: true,
      available: !missing,
      reason: missing,
      voices: VOICES,
      defaultVoice: "af_heart",
      supportsSpeed: true,
    };
  },

  async open(): Promise<TTSSession> {
    const { available, reason } = await kokoroProvider.info();
    if (!available) throw new Error(reason ?? "Kokoro is not available");
    const device = (process.env.HUIVER_DEVICE ?? "auto").toLowerCase();
    return device === "cpu" || device === "cuda"
      ? new PythonWorkerSession(WORKER_OPTIONS)
      : new RecyclingWorkerSession(WORKER_OPTIONS, RECYCLE_CHUNKS);
  },
};
