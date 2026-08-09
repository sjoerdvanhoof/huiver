import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pcmFromWav } from "../wav";
import type { ProviderInfo, StreamRequest, TTSProvider, TTSSession, TrackRequest, Voice } from "./types";

const PYTHON = process.env.HUIVER_PYTHON ?? path.join(process.cwd(), ".venv", "bin", "python");
const WORKER = path.join(process.cwd(), "py", "kokoro_worker.py");

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

type WorkerMessage =
  | { type: "ready"; sampleRate: number; device?: string }
  | { type: "chunk"; id: string; index: number; total: number }
  | { type: "audio"; id: string; index: number; path: string }
  | { type: "track"; id: string; duration: number; path: string }
  | { type: "done"; id: string }
  | { type: "cancelled"; id: string }
  | { type: "error"; id: string | null; message: string }
  | { type: "fatal"; message: string };

type Pending = {
  resolve: (value: { durationSec: number }) => void;
  reject: (error: Error) => void;
  onChunk?: (done: number, total: number) => void;
  /** Set for streaming requests; receives each rendered chunk's WAV path. */
  onAudioPath?: (path: string) => void;
};

class KokoroSession implements TTSSession {
  readonly sampleRate = 24000;
  private proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private pending = new Map<string, Pending>();
  private stderr = "";
  private nextId = 0;
  private closed = false;
  private ready: Promise<void>;
  private signalReady!: () => void;
  private failReady!: (error: Error) => void;

  constructor() {
    this.ready = new Promise((resolve, reject) => {
      this.signalReady = resolve;
      this.failReady = reject;
    });

    this.proc = Bun.spawn([PYTHON, WORKER], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      cwd: process.cwd(),
    });

    void this.readStdout();
    void this.readStderr();
    void this.proc.exited.then(code => {
      this.failAll(new Error(`Kokoro worker exited (code ${code}). ${this.stderr.trim().slice(-500)}`));
    });
  }

  private async readStdout() {
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const bytes of this.proc.stdout) {
      buffer += decoder.decode(bytes, { stream: true });
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) this.handle(line);
      }
    }
  }

  private async readStderr() {
    const decoder = new TextDecoder();
    for await (const bytes of this.proc.stderr) {
      this.stderr = (this.stderr + decoder.decode(bytes, { stream: true })).slice(-4000);
    }
  }

  private handle(line: string) {
    let message: WorkerMessage;
    try {
      message = JSON.parse(line);
    } catch {
      return; // Ignore anything that is not part of the protocol.
    }

    switch (message.type) {
      case "ready":
        console.log(`[kokoro] worker ready on ${message.device ?? "cpu"}`);
        this.signalReady();
        return;
      case "fatal":
        this.failReady(new Error(message.message));
        this.failAll(new Error(message.message));
        return;
      case "chunk": {
        this.pending.get(message.id)?.onChunk?.(message.index, message.total);
        return;
      }
      case "audio": {
        this.pending.get(message.id)?.onAudioPath?.(message.path);
        return;
      }
      case "done":
      case "cancelled": {
        // A cancelled stream is a normal ending, not a failure.
        const entry = this.pending.get(message.id);
        this.pending.delete(message.id);
        entry?.resolve({ durationSec: 0 });
        return;
      }
      case "track": {
        const entry = this.pending.get(message.id);
        this.pending.delete(message.id);
        entry?.resolve({ durationSec: message.duration });
        return;
      }
      case "error": {
        if (!message.id) return;
        const entry = this.pending.get(message.id);
        this.pending.delete(message.id);
        entry?.reject(new Error(message.message));
        return;
      }
    }
  }

  private failAll(error: Error) {
    this.failReady(error);
    for (const entry of this.pending.values()) entry.reject(error);
    this.pending.clear();
  }

  async synthesize(req: TrackRequest): Promise<{ durationSec: number }> {
    await this.ready;
    if (this.closed) throw new Error("Kokoro session is closed");

    const id = `t${this.nextId++}`;
    const promise = new Promise<{ durationSec: number }>((resolve, reject) => {
      this.pending.set(id, { resolve, reject, onChunk: req.onChunk });
    });

    // Removing a chapter from the queue must stop the CPU work without tearing
    // down the worker — the same `cancel` the streaming path uses.
    const onAbort = () => {
      if (this.closed) return;
      try {
        this.proc.stdin.write(`${JSON.stringify({ cmd: "cancel", id })}\n`);
        this.proc.stdin.flush();
      } catch {
        // Worker already gone; the pending promise settles via failAll.
      }
    };
    req.signal?.addEventListener("abort", onAbort, { once: true });

    this.proc.stdin.write(
      `${JSON.stringify({
        cmd: "track",
        id,
        chunks: req.chunks,
        voice: req.voice,
        speed: req.speed,
        out: req.outWav,
      })}\n`,
    );
    this.proc.stdin.flush();

    try {
      return await promise;
    } finally {
      req.signal?.removeEventListener("abort", onAbort);
    }
  }

  async stream(req: StreamRequest): Promise<void> {
    await this.ready;
    if (this.closed) throw new Error("Kokoro session is closed");

    const id = `s${this.nextId++}`;
    const dir = await mkdtemp(path.join(tmpdir(), "huiver-stream-"));

    // Chunks arrive in order; chain them so onAudio never runs concurrently.
    let queue = Promise.resolve();
    let failure: Error | null = null;

    const forward = (wavPath: string) => {
      queue = queue.then(async () => {
        if (failure || req.signal?.aborted) return;
        try {
          const bytes = new Uint8Array(await Bun.file(wavPath).arrayBuffer());
          await req.onAudio(pcmFromWav(bytes).pcm);
        } catch (error) {
          failure ??= error instanceof Error ? error : new Error(String(error));
        } finally {
          await rm(wavPath, { force: true });
        }
      });
    };

    const finished = new Promise<{ durationSec: number }>((resolve, reject) => {
      this.pending.set(id, { resolve, reject, onAudioPath: forward });
    });

    // Abandoning a stream must stop the CPU work, but NOT tear down the worker:
    // reloading the model costs ~6s and ~1 GB, and a user dragging the speed
    // slider aborts many streams in a row.
    const onAbort = () => {
      if (this.closed) return;
      try {
        this.proc.stdin.write(`${JSON.stringify({ cmd: "cancel", id })}\n`);
        this.proc.stdin.flush();
      } catch {
        // Worker already gone; the pending promise settles via failAll.
      }
    };
    req.signal?.addEventListener("abort", onAbort, { once: true });

    try {
      this.proc.stdin.write(
        `${JSON.stringify({ cmd: "stream", id, chunks: req.chunks, voice: req.voice, speed: req.speed, dir })}\n`,
      );
      this.proc.stdin.flush();
      await finished;
      await queue;
      if (failure) throw failure;
    } finally {
      req.signal?.removeEventListener("abort", onAbort);
      await rm(dir, { recursive: true, force: true });
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.proc.stdin.write(`${JSON.stringify({ cmd: "quit" })}\n`);
      this.proc.stdin.flush();
      this.proc.stdin.end();
    } catch {
      // Worker may already be gone.
    }
    const timeout = setTimeout(() => this.proc.kill(), 5000);
    await this.proc.exited;
    clearTimeout(timeout);
  }
}

export const kokoroProvider: TTSProvider = {
  async info(): Promise<ProviderInfo> {
    const missing = !existsSync(PYTHON)
      ? `Python venv not found at ${PYTHON}. Run: python3.11 -m venv .venv && .venv/bin/pip install kokoro soundfile`
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
    return new KokoroSession();
  },
};
