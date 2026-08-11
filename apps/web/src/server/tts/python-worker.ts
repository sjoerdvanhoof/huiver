import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pcmFromWav } from "@huiver/shared";
import type { StreamRequest, TTSSession, TrackRequest } from "./types";

/**
 * Talking to a Python speech worker.
 *
 * Both local engines are the same shape — a long-lived subprocess speaking
 * newline-delimited JSON over stdin/stdout, so the model is loaded once per job
 * rather than once per track — and differ only in which script is spawned and
 * what a request needs to carry. That protocol lives here; see py/*_worker.py
 * for the other end of it.
 */

export type WorkerMessage =
  | { type: "ready"; sampleRate: number; device?: string }
  | { type: "chunk"; id: string; index: number; total: number }
  | { type: "audio"; id: string; index: number; path: string }
  | { type: "track"; id: string; duration: number; path: string }
  | { type: "done"; id: string }
  | { type: "cancelled"; id: string }
  | { type: "error"; id: string | null; message: string }
  | { type: "fatal"; message: string };

export type WorkerOptions = {
  /** Short engine name, used in log lines and error messages. */
  name: string;
  python: string;
  script: string;
  cwd: string;
  /** Rate of the PCM the worker emits. Workers resample to match it. */
  sampleRate: number;
  /**
   * Fields a request needs beyond the common ones. Chatterbox uses this to turn
   * a voice id into the reference clip it clones from.
   */
  requestFields?: (voice: string) => Record<string, unknown>;
};

type Pending = {
  resolve: (value: { durationSec: number }) => void;
  reject: (error: Error) => void;
  onChunk?: (done: number, total: number) => void;
  /** Set for streaming requests; receives each rendered chunk's WAV path and index. */
  onAudioPath?: (path: string, index: number) => void;
};

export class PythonWorkerSession implements TTSSession {
  readonly sampleRate: number;
  private proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private pending = new Map<string, Pending>();
  private stderr = "";
  private nextId = 0;
  private closed = false;
  private ready: Promise<void>;
  private signalReady!: () => void;
  private failReady!: (error: Error) => void;
  private device = "cpu";

  constructor(private options: WorkerOptions) {
    this.sampleRate = options.sampleRate;
    this.ready = new Promise((resolve, reject) => {
      this.signalReady = resolve;
      this.failReady = reject;
    });

    this.proc = Bun.spawn([options.python, options.script], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      cwd: options.cwd,
    });

    void this.readStdout();
    void this.readStderr();
    void this.proc.exited.then(code => {
      if (this.closed) {
        this.signalReady();
        return;
      }
      this.failAll(
        new Error(`${this.options.name} worker exited (code ${code}). ${this.stderr.trim().slice(-500)}`),
      );
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
        this.device = message.device ?? "cpu";
        console.log(`[${this.options.name}] worker ready on ${message.device ?? "cpu"}`);
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
        this.pending.get(message.id)?.onAudioPath?.(message.path, message.index);
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

  /** Ask the worker to stop a request without tearing the worker itself down. */
  private cancel(id: string) {
    if (this.closed) return;
    try {
      this.proc.stdin.write(`${JSON.stringify({ cmd: "cancel", id })}\n`);
      this.proc.stdin.flush();
    } catch {
      // Worker already gone; the pending promise settles via failAll.
    }
  }

  private send(command: Record<string, unknown>) {
    this.proc.stdin.write(`${JSON.stringify(command)}\n`);
    this.proc.stdin.flush();
  }

  /** Resolves once the model is loaded, so callers can read `device`. */
  async whenReady() {
    await this.ready;
  }

  async usesMps() {
    await this.ready;
    return this.device === "mps";
  }

  async synthesize(req: TrackRequest): Promise<{ durationSec: number }> {
    await this.ready;
    if (this.closed) throw new Error(`${this.options.name} session is closed`);

    const id = `t${this.nextId++}`;
    const promise = new Promise<{ durationSec: number }>((resolve, reject) => {
      this.pending.set(id, { resolve, reject, onChunk: req.onChunk });
    });

    // Removing a chapter from the queue must stop the CPU work without tearing
    // down the worker — the same `cancel` the streaming path uses.
    const onAbort = () => this.cancel(id);
    req.signal?.addEventListener("abort", onAbort, { once: true });

    this.send({
      cmd: "track",
      id,
      chunks: req.chunks,
      voice: req.voice,
      speed: req.speed,
      out: req.outWav,
      append: req.append,
      ...this.options.requestFields?.(req.voice),
    });

    try {
      return await promise;
    } finally {
      req.signal?.removeEventListener("abort", onAbort);
    }
  }

  async stream(req: StreamRequest): Promise<void> {
    await this.ready;
    if (this.closed) throw new Error(`${this.options.name} session is closed`);

    const id = `s${this.nextId++}`;
    const dir = await mkdtemp(path.join(tmpdir(), "huiver-stream-"));

    // Chunks arrive in order; chain them so onAudio never runs concurrently.
    let queue = Promise.resolve();
    let failure: Error | null = null;

    const forward = (wavPath: string, index: number) => {
      queue = queue.then(async () => {
        if (failure || req.signal?.aborted) return;
        try {
          const bytes = new Uint8Array(await Bun.file(wavPath).arrayBuffer());
          await req.onAudio(pcmFromWav(bytes).pcm, index);
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
    // reloading the model costs seconds and ~1 GB, and a user dragging the speed
    // slider aborts many streams in a row.
    const onAbort = () => this.cancel(id);
    req.signal?.addEventListener("abort", onAbort, { once: true });

    try {
      this.send({
        cmd: "stream",
        id,
        chunks: req.chunks,
        voice: req.voice,
        speed: req.speed,
        dir,
        ...this.options.requestFields?.(req.voice),
      });
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
      this.send({ cmd: "quit" });
      this.proc.stdin.end();
    } catch {
      // Worker may already be gone.
    }
    const timeout = setTimeout(() => this.proc.kill(), 5000);
    await this.proc.exited;
    clearTimeout(timeout);
  }
}

/**
 * Metal currently leaks native objects during repeated LSTM inference, outside
 * the memory managed by torch.mps.empty_cache(). Give each MPS process a small
 * chunk budget, then replace it. Conversion appends each batch to the same WAV;
 * live playback already has the earlier batches buffered.
 *
 * Only worth wrapping an engine that actually leaks — on CPU and CUDA every
 * method here falls straight through to a single long-lived session.
 */
export class RecyclingWorkerSession implements TTSSession {
  readonly sampleRate: number;
  private session: PythonWorkerSession | null;
  private usedChunks = 0;
  private closed = false;
  private tail: Promise<void> = Promise.resolve();

  constructor(
    private options: WorkerOptions,
    /** Chunks one process may render before it is replaced. */
    private budget: number,
  ) {
    this.sampleRate = options.sampleRate;
    this.session = new PythonWorkerSession(options);
  }

  private exclusive<T>(work: () => Promise<T>): Promise<T> {
    const result = this.tail.then(work, work);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }

  private async rotate() {
    const session = this.session;
    this.session = null;
    await session?.close();
    this.usedChunks = 0;
  }

  private currentSession() {
    if (this.closed) throw new Error(`${this.options.name} session is closed`);
    return (this.session ??= new PythonWorkerSession(this.options));
  }

  private capacity() {
    return Math.max(1, this.budget - this.usedChunks);
  }

  async synthesize(req: TrackRequest): Promise<{ durationSec: number }> {
    return this.exclusive(() => this.synthesizeBatched(req));
  }

  private async synthesizeBatched(req: TrackRequest): Promise<{ durationSec: number }> {
    let session = this.currentSession();
    if (!(await session.usesMps())) return session.synthesize(req);
    let offset = 0;
    let durationSec = 0;

    while (offset < req.chunks.length) {
      if (req.signal?.aborted) break;
      const batch = req.chunks.slice(offset, offset + this.capacity());
      const base = offset;
      session = this.currentSession();
      const result = await session.synthesize({
        ...req,
        chunks: batch,
        // The caller may itself be appending to a partial file from an earlier
        // checkpoint, in which case every batch adds to it.
        append: req.append || offset > 0,
        onChunk: req.onChunk ? done => req.onChunk!(base + done, req.chunks.length) : undefined,
      });
      durationSec += result.durationSec;
      offset += batch.length;
      this.usedChunks += batch.length;

      if (this.usedChunks >= this.budget || req.signal?.aborted) await this.rotate();
    }

    return { durationSec };
  }

  async stream(req: StreamRequest): Promise<void> {
    return this.exclusive(() => this.streamBatched(req));
  }

  private async streamBatched(req: StreamRequest): Promise<void> {
    let session = this.currentSession();
    if (!(await session.usesMps())) return session.stream(req);
    let offset = 0;
    while (offset < req.chunks.length) {
      if (req.signal?.aborted) break;
      const batch = req.chunks.slice(offset, offset + this.capacity());
      const base = offset;
      session = this.currentSession();
      // Each batch indexes from zero; the caller wants the chapter's own numbering.
      await session.stream({ ...req, chunks: batch, onAudio: (pcm, index) => req.onAudio(pcm, base + index) });
      offset += batch.length;
      this.usedChunks += batch.length;

      if (this.usedChunks >= this.budget || req.signal?.aborted) await this.rotate();
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    await this.tail;
    await this.session?.close();
    this.session = null;
  }
}
