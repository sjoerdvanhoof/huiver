/**
 * End-to-end crash test: starts a conversion, kills the server mid-chapter,
 * starts it again and checks that the chapter carries on from its last
 * checkpoint instead of being rendered from the beginning.
 *
 * The final proof is length: the resumed audio has to come out the same
 * duration as the same chapter rendered in one go, which it only can if every
 * chunk landed exactly once.
 *
 * Runs against a throwaway data directory, on an ephemeral port, so it never
 * touches your real library or collides with `bun dev`. Needs Kokoro installed.
 *
 *   bun run scripts/e2e-resume.ts
 */
import { Database } from "bun:sqlite";
import { strToU8, zipSync } from "fflate";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const dataDir = await mkdtemp(path.join(tmpdir(), "huiver-resume-"));
const port = 3900 + Math.floor(Math.random() * 90);
const base = `http://localhost:${port}`;

let failures = 0;
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "✓" : "✗"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
}

/** Long enough to take several chunks, so there is a middle to be killed in. */
function buildEpub(): Uint8Array {
  const paragraphs = [
    "The lamps were lit early that evening, and a thin rain fell against the windows of the reading room. " +
      "Nobody spoke above a murmur, as though the weather had settled an argument that none of them wished to reopen.",
    "Later, when the clocks had been wound and the fire banked, the housekeeper carried a tray up the back stairs " +
      "and set it down outside a door that had not been opened in three days. She listened for a moment, heard nothing, and went away again.",
    "He had come to the house in September with two trunks and a letter of introduction, and by October the letter " +
      "had been mislaid and the trunks had been unpacked into rooms that were not his own. The arrangement suited everyone well enough.",
    "In the morning the rain had stopped. The garden smelled of wet stone and cut grass, and the gate at the bottom " +
      "of the lawn stood open on a road that ran, as far as anyone in the house had ever bothered to find out, all the way to the sea.",
    "There is a particular quiet that belongs to a house where something has been decided but not yet announced. " +
      "It is not the quiet of sleep, nor of absence, but of a great many people each waiting for somebody else to speak first.",
    "By the end of the week the trunks had gone again, the letter had been found behind a clock, and the road at the " +
      "bottom of the lawn had carried away the only person who could have explained any of it.",
  ];

  return zipSync({
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container version="1.0"><rootfiles>
         <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
       </rootfiles></container>`,
    ),
    "OEBPS/content.opf": strToU8(
      `<?xml version="1.0"?><package version="3.0" xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title>The Open Gate</dc:title><dc:creator>Test Author</dc:creator>
         </metadata>
         <manifest>
           <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
           <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
         </manifest>
         <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
       </package>`,
    ),
    "OEBPS/ch1.xhtml": strToU8(
      `<html><head><title>The Open Gate</title></head><body><h1>The Open Gate</h1>
       ${paragraphs.map(p => `<p>${p}</p>`).join("\n")}</body></html>`,
    ),
    // Kept short and never converted, so the streaming phase has a chapter of
    // its own to render from scratch.
    "OEBPS/ch2.xhtml": strToU8(
      `<html><head><title>The Road Down</title></head><body><h1>The Road Down</h1>
       ${paragraphs.slice(0, 3).map(p => `<p>${p}</p>`).join("\n")}</body></html>`,
    ),
  });
}

type Server = { proc: Bun.Subprocess<"ignore", "pipe", "pipe">; output: () => string };

/** Boot the real server against the throwaway library, capturing its log. */
async function startServer(): Promise<Server> {
  const proc = Bun.spawn(["bun", "src/index.ts"], {
    cwd: path.join(import.meta.dir, ".."),
    env: {
      ...process.env,
      NODE_ENV: "production",
      PORT: String(port),
      HUIVER_DATA_DIR: dataDir,
      // Checkpoint after every chunk, so a kill always lands after one.
      HUIVER_CHECKPOINT_CHUNKS: "1",
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  let log = "";
  const drain = async (stream: ReadableStream<Uint8Array>) => {
    const decoder = new TextDecoder();
    for await (const bytes of stream) log += decoder.decode(bytes, { stream: true });
  };
  void drain(proc.stdout);
  void drain(proc.stderr);

  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const up = await fetch(`${base}/api/providers`).then(r => r.ok).catch(() => false);
    if (up) return { proc, output: () => log };
    await Bun.sleep(200);
  }
  throw new Error(`server never came up on ${base}\n${log}`);
}

const api = async <T>(pathname: string, init?: RequestInit): Promise<T> =>
  (await (await fetch(`${base}${pathname}`, init)).json()) as T;

type Job = {
  id: string;
  status: string;
  error: string | null;
  chunksDone: number;
  chunksTotal: number;
  tracks: { id: string; status: string; duration: number | null; chunksDone: number; chunksTotal: number }[];
};

async function convertFirstChapter(bookId: string, chapterId: string, voice: string): Promise<Job> {
  return api<Job>(`/api/books/${bookId}/convert`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "kokoro", voice, speed: 1, chapterIds: [chapterId] }),
  });
}

async function waitForJob(jobId: string, timeoutMs = 300_000): Promise<Job> {
  const deadline = Date.now() + timeoutMs;
  let job = await api<Job>(`/api/jobs/${jobId}`);
  while (["queued", "running"].includes(job.status) && Date.now() < deadline) {
    await Bun.sleep(500);
    job = await api<Job>(`/api/jobs/${jobId}`);
  }
  return job;
}

let server: Server | null = null;

try {
  server = await startServer();

  const providers = await api<{ id: string; available: boolean; reason?: string; defaultVoice: string }[]>(
    "/api/providers",
  );
  const kokoro = providers.find(p => p.id === "kokoro");
  check("kokoro is available", Boolean(kokoro?.available), kokoro?.reason ?? "");
  if (!kokoro?.available) throw new Error("Kokoro unavailable — cannot run conversion");

  const form = new FormData();
  form.append("file", new File([buildEpub() as unknown as BlobPart], "open-gate.epub"));
  const book = (await (await fetch(`${base}/api/books`, { method: "POST", body: form })).json()) as { id: string };
  const detail = await api<{ chapters: { id: string }[] }>(`/api/books/${book.id}`);
  const chapterId = detail.chapters[0]!.id;

  const first = await convertFirstChapter(book.id, chapterId, kokoro.defaultVoice);
  check("conversion queued", Boolean(first.id), first.id);
  console.log("  …synthesizing (the first run loads the model, this takes a moment)");

  // Watch the checkpoint the server is writing, from outside the server.
  const db = new Database(path.join(dataDir, "huiver.db"));
  const checkpoint = () =>
    db.query("SELECT resume_chunks, resume_bytes, chunks_total FROM tracks WHERE job_id = ?").get(first.id) as {
      resume_chunks: number;
      resume_bytes: number;
      chunks_total: number;
    } | null;

  const killDeadline = Date.now() + 300_000;
  let mark = checkpoint();
  while ((mark?.resume_chunks ?? 0) < 2 && Date.now() < killDeadline) {
    await Bun.sleep(250);
    mark = checkpoint();
  }
  check("checkpoint written mid-chapter", (mark?.resume_chunks ?? 0) >= 2,
    `${mark?.resume_chunks ?? 0}/${mark?.chunks_total ?? 0} chunks, ${mark?.resume_bytes ?? 0} bytes`);

  const killedAt = mark!.resume_chunks;
  check("chapter is long enough to be interrupted", mark!.chunks_total > killedAt + 1,
    `${mark!.chunks_total} chunks total`);

  // Hard kill: no shutdown hook, no flush, exactly like a crash or a power cut.
  server.proc.kill(9);
  await server.proc.exited;
  console.log(`  …killed the server after ${killedAt} chunks`);

  const interrupted = db.query("SELECT status FROM jobs WHERE id = ?").get(first.id) as { status: string };
  check("job was left mid-flight", interrupted.status === "running", interrupted.status);

  server = await startServer();
  const resumed = await waitForJob(first.id);

  check("resumed job finished", resumed.status === "done", `${resumed.status} ${resumed.error ?? ""}`);
  check("picked up from the checkpoint, not the top", server.output().includes("resuming at chunk"),
    server.output().match(/resuming at chunk \d+\/\d+/)?.[0] ?? "no resume in the log");

  const resumedChunk = Number(server.output().match(/resuming at chunk (\d+)\//)?.[1] ?? 0);
  check("re-rendered no more than the interrupted chunk", resumedChunk >= killedAt,
    `resumed at ${resumedChunk}, checkpoint was ${killedAt}`);

  const resumedTrack = resumed.tracks[0]!;
  check("progress counters filled in", resumed.chunksDone === resumed.chunksTotal,
    `${resumed.chunksDone}/${resumed.chunksTotal}`);

  const leftovers = db
    .query("SELECT resume_chunks, resume_key, resume_path FROM tracks WHERE id = ?")
    .get(resumedTrack.id) as { resume_chunks: number; resume_key: string | null; resume_path: string | null };
  check("checkpoint cleared once the chapter finished",
    leftovers.resume_chunks === 0 && leftovers.resume_key === null && leftovers.resume_path === null,
    JSON.stringify(leftovers));

  // The real check: the same chapter, rendered without interruption, has to
  // come out the same length. Anything dropped or doubled shows up here.
  console.log("  …rendering the same chapter again for comparison");
  const reference = await waitForJob((await convertFirstChapter(book.id, chapterId, kokoro.defaultVoice)).id);
  check("reference conversion finished", reference.status === "done", `${reference.status} ${reference.error ?? ""}`);

  const resumedSeconds = resumedTrack.duration ?? 0;
  const referenceSeconds = reference.tracks[0]?.duration ?? 0;
  check("resumed audio is the same length as an uninterrupted render",
    referenceSeconds > 1 && Math.abs(resumedSeconds - referenceSeconds) < 0.2,
    `${resumedSeconds.toFixed(3)}s resumed vs ${referenceSeconds.toFixed(3)}s reference`);

  const audio = await fetch(`${base}/api/tracks/${resumedTrack.id}/audio`);
  const bytes = (await audio.arrayBuffer()).byteLength;
  check("resumed track downloads", audio.ok && bytes > 5000, `${bytes} bytes`);

  // --- stopping on purpose, then converting again ---
  // Same chapter, a brand new job each time, which is what the UI does.
  console.log("  …stopping a run halfway and converting again");
  const stopped = await convertFirstChapter(book.id, chapterId, kokoro.defaultVoice);
  const stoppedTrack = () =>
    db.query("SELECT id, status, resume_chunks, resume_path FROM tracks WHERE job_id = ?").get(stopped.id) as {
      id: string;
      status: string;
      resume_chunks: number;
      resume_path: string | null;
    } | null;

  const stopDeadline = Date.now() + 300_000;
  while ((stoppedTrack()?.resume_chunks ?? 0) < 2 && Date.now() < stopDeadline) await Bun.sleep(250);
  await fetch(`${base}/api/jobs/${stopped.id}/cancel`, { method: "POST" });

  while (stoppedTrack()?.status === "running" && Date.now() < stopDeadline) await Bun.sleep(250);
  const parked = stoppedTrack()!;
  check("stopped chapter was parked, not thrown away",
    parked.status === "cancelled" && parked.resume_chunks >= 2 && Boolean(parked.resume_path),
    `${parked.status} at ${parked.resume_chunks} chunks`);
  check("its audio is still on disk", Boolean(parked.resume_path) && (await Bun.file(parked.resume_path!).exists()),
    parked.resume_path ?? "no path");

  const resumesBefore = server.output().match(/resuming at chunk/g)?.length ?? 0;
  const restarted = await waitForJob((await convertFirstChapter(book.id, chapterId, kokoro.defaultVoice)).id);
  const resumesAfter = server.output().match(/resuming at chunk/g)?.length ?? 0;

  check("converting again finished", restarted.status === "done", `${restarted.status} ${restarted.error ?? ""}`);
  check("the new run continued the stopped one", resumesAfter > resumesBefore,
    server.output().match(/resuming at chunk \d+\/\d+/g)?.slice(-1)[0] ?? "started from the top");
  check("nothing was lost or doubled in the handover",
    Math.abs((restarted.tracks[0]?.duration ?? 0) - referenceSeconds) < 0.2,
    `${(restarted.tracks[0]?.duration ?? 0).toFixed(3)}s vs ${referenceSeconds.toFixed(3)}s reference`);
  check("the parked partial was handed over, not left behind",
    !(await Bun.file(parked.resume_path!).exists()), parked.resume_path ?? "");

  // --- live playback keeps what it renders ---
  console.log("  …streaming a chapter, cutting it off, then playing it again");
  const listenChapter = detail.chapters[1]!.id;
  const streamUrl = `${base}/api/chapters/${listenChapter}/stream?provider=kokoro&voice=${kokoro.defaultVoice}&speed=1`;

  const kept = () =>
    db.query("SELECT chunks_done, chunks_total, bytes, path FROM stream_partials WHERE chapter_id = ?").get(
      listenChapter,
    ) as { chunks_done: number; chunks_total: number; bytes: number; path: string } | null;

  // Listen for a moment, then walk away mid-chapter.
  const listener = new AbortController();
  const coldStart = Date.now();
  const coldPlay = await fetch(streamUrl, { signal: listener.signal });
  const firstReader = coldPlay.body!.getReader();
  await firstReader.read();
  const coldFirstByteMs = Date.now() - coldStart;

  const keepDeadline = Date.now() + 300_000;
  while ((kept()?.chunks_done ?? 0) < 1 && Date.now() < keepDeadline) await Bun.sleep(100);
  listener.abort();
  await Bun.sleep(500);

  const heard = kept();
  check("audio heard once is kept", (heard?.chunks_done ?? 0) >= 1,
    `${heard?.chunks_done ?? 0}/${heard?.chunks_total ?? 0} chunks, ${heard?.bytes ?? 0} bytes`);
  check("kept audio is on disk", Boolean(heard) && (await Bun.file(heard!.path).exists()), heard?.path ?? "");
  check("it is not playable until the chapter is complete",
    !(await api<{ chapters: { audio: unknown }[] }>(`/api/books/${book.id}`)).chapters[1]!.audio);

  // Play it again: the part already rendered comes off the disk.
  const warmStart = Date.now();
  const again = await fetch(streamUrl);
  const againReader = again.body!.getReader();
  await againReader.read();
  const warmFirstByteMs = Date.now() - warmStart;

  const storedSeconds = Number(again.headers.get("X-Stored-Seconds"));
  check("playing again replays what was stored", storedSeconds > 0, `${storedSeconds.toFixed(2)}s from disk`);
  check("and starts sooner than rendering it did",
    warmFirstByteMs < coldFirstByteMs && warmFirstByteMs < 1000,
    `${warmFirstByteMs}ms vs ${coldFirstByteMs}ms cold`);

  let listenedBytes = 0;
  while (true) {
    const { done, value } = await againReader.read();
    if (done) break;
    listenedBytes += value.byteLength;
  }
  check("the rest streams on to the end", listenedBytes > 10_000, `${listenedBytes} bytes`);

  await Bun.sleep(500);
  const listened = (await api<{ chapters: { audio: { duration: number | null } | null }[] }>(
    `/api/books/${book.id}`,
  )).chapters[1]!;
  check("a chapter listened all the way through is kept as a track",
    Boolean(listened.audio) && (listened.audio?.duration ?? 0) > 1,
    `${listened.audio?.duration?.toFixed(1) ?? "no"}s`);
  check("its kept-stream copy was handed over, not left behind", kept() === null);

  db.close();
} catch (error) {
  failures++;
  console.error("✗ crashed:", error instanceof Error ? error.message : error);
} finally {
  server?.proc.kill();
  await server?.proc.exited;
  await rm(dataDir, { recursive: true, force: true });
}

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
