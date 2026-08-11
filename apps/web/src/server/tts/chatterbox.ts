import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { listVoices, referencePath, usesModelVoice } from "./chatterbox-voices";
import { PythonWorkerSession, type WorkerOptions } from "./python-worker";
import type { ProviderInfo, TTSProvider, TTSSession } from "./types";

/**
 * Chatterbox Nano — Resemble AI's 110M-parameter zero-shot voice cloner, MIT
 * licensed and running locally, like Kokoro.
 *
 * It gets its own virtual environment rather than sharing Kokoro's. Not
 * fastidiousness: chatterbox-tts pins torch, transformers and numpy to exact
 * versions several majors below the ones Kokoro is installed against, so a
 * single venv means one of the two engines is always broken.
 */

const APP_ROOT = path.join(import.meta.dir, "..", "..", "..");
const VENV = process.env.HUIVER_CHATTERBOX_VENV ?? path.join(APP_ROOT, ".venv-chatterbox");
const PYTHON = process.env.HUIVER_CHATTERBOX_PYTHON ?? path.join(VENV, "bin", "python");
const WORKER = path.join(APP_ROOT, "py", "chatterbox_worker.py");

const SETUP_HINT = "Run: bun run setup:chatterbox";

/**
 * Is chatterbox-tts installed in that venv?
 *
 * Read off the filesystem rather than by importing it — `info()` is called on
 * every providers listing, every conversion and every preview, and importing
 * torch costs seconds.
 */
function packageInstalled(): boolean {
  const lib = path.join(VENV, "lib");
  let versions: string[];
  try {
    versions = readdirSync(lib);
  } catch {
    return false;
  }
  return versions.some(version => existsSync(path.join(lib, version, "site-packages", "chatterbox")));
}

const WORKER_OPTIONS: WorkerOptions = {
  name: "chatterbox",
  python: PYTHON,
  script: WORKER,
  cwd: APP_ROOT,
  // The worker resamples to this, so a chapter's rate never depends on which
  // build of the model happened to render it.
  sampleRate: 24000,
  // A Chatterbox voice is a reference clip, and the worker needs the path. The
  // one exception is the model's own voice, which is in the weights — flagged
  // rather than left as a null path, so a clip that has gone missing still
  // fails loudly instead of quietly narrating in the wrong voice.
  requestFields: voice =>
    usesModelVoice(voice) ? { builtin: true } : { prompt: referencePath(voice) },
};

export const chatterboxProvider: TTSProvider = {
  async info(): Promise<ProviderInfo> {
    // Never empty: Nano carries a voice of its own, so the engine is usable
    // before the pack is fetched or anything is recorded.
    const voices = await listVoices();

    const missing = !existsSync(PYTHON)
      ? `Chatterbox venv not found at ${VENV}. ${SETUP_HINT}`
      : !existsSync(WORKER)
        ? `Worker script missing at ${WORKER}`
        : !packageInstalled()
          ? `chatterbox-tts is not installed in ${VENV}. ${SETUP_HINT}`
          : undefined;

    return {
      id: "chatterbox",
      label: "Chatterbox Nano (local, cloned voices)",
      local: true,
      available: !missing,
      reason: missing,
      voices,
      defaultVoice: voices[0]?.id ?? "",
      // The model has no speed control. Listening speed is the player's job.
      supportsSpeed: false,
    };
  },

  async open(): Promise<TTSSession> {
    const { available, reason } = await chatterboxProvider.info();
    if (!available) throw new Error(reason ?? "Chatterbox is not available");
    return new PythonWorkerSession(WORKER_OPTIONS);
  },
};
