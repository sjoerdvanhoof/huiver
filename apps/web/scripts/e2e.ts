/**
 * End-to-end smoke test: uploads a small EPUB, converts one chapter with the
 * configured engine, and checks that a playable audio track comes out.
 *
 * Runs against a throwaway data directory, on an ephemeral port, so it never
 * touches your real library or collides with `bun dev`.
 *
 *   bun run scripts/e2e.ts
 */
import { strToU8, zipSync } from "fflate";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const dataDir = await mkdtemp(path.join(tmpdir(), "huiver-e2e-"));
process.env.HUIVER_DATA_DIR = dataDir;

// Imported after HUIVER_DATA_DIR is set so the db module picks it up.
const { apiRoutes, IDLE_TIMEOUT_SECONDS } = await import("../src/server/routes");
const { serve } = await import("bun");

const server = serve({
  port: 0,
  routes: apiRoutes,
  idleTimeout: IDLE_TIMEOUT_SECONDS,
  error: e => new Response(e.message, { status: 500 }),
});
const base = server.url.origin;

let failures = 0;
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "✓" : "✗"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
}

function buildEpub(): Uint8Array {
  const prose =
    "The lamps were lit early that evening. A thin rain fell against the windows, " +
    "and the street outside had the hushed look of a place waiting for something to happen.";

  return zipSync({
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container version="1.0"><rootfiles>
         <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
       </rootfiles></container>`,
    ),
    "OEBPS/content.opf": strToU8(
      `<?xml version="1.0"?><package version="3.0" xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title>A Short Evening</dc:title><dc:creator>Test Author</dc:creator>
         </metadata>
         <manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
         <spine><itemref idref="c1"/></spine>
       </package>`,
    ),
    "OEBPS/ch1.xhtml": strToU8(
      `<html><head><title>The First Evening</title></head>
       <body><h1>The First Evening</h1><p>${prose}</p></body></html>`,
    ),
  });
}

try {
  const providers = (await (await fetch(`${base}/api/providers`)).json()) as {
    id: string;
    available: boolean;
    reason?: string;
    defaultVoice: string;
  }[];
  const kokoro = providers.find(p => p.id === "kokoro");
  check("GET /api/providers lists kokoro", Boolean(kokoro));
  check("kokoro is available", Boolean(kokoro?.available), kokoro?.reason ?? "");
  if (!kokoro?.available) throw new Error("Kokoro unavailable — cannot run conversion");

  const form = new FormData();
  form.append("file", new File([buildEpub() as unknown as BlobPart], "evening.epub"));
  const uploadRes = await fetch(`${base}/api/books`, { method: "POST", body: form });
  const book = (await uploadRes.json()) as { id: string; title: string; author: string; chapterCount: number };
  check("POST /api/books accepts an EPUB", uploadRes.status === 201, `status ${uploadRes.status}`);
  check("parsed title and author", book.title === "A Short Evening" && book.author === "Test Author",
    `${book.title} / ${book.author}`);

  const detail = (await (await fetch(`${base}/api/books/${book.id}`)).json()) as {
    chapters: { id: string; title: string }[];
  };
  check("chapter list is populated", detail.chapters.length === 1, `${detail.chapters.length} chapters`);
  check("chapter title from <h1>", detail.chapters[0]?.title === "The First Evening", detail.chapters[0]?.title ?? "");

  const convertRes = await fetch(`${base}/api/books/${book.id}/convert`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "kokoro", voice: kokoro.defaultVoice, speed: 1, chapterIds: [detail.chapters[0]!.id] }),
  });
  const created = (await convertRes.json()) as { id: string };
  check("POST /convert queues a job", convertRes.status === 201, `status ${convertRes.status}`);

  console.log("  …synthesizing (first run loads the model, this takes a moment)");
  let job: any;
  const deadline = Date.now() + 300_000;
  do {
    await Bun.sleep(1000);
    job = await (await fetch(`${base}/api/jobs/${created.id}`)).json();
  } while (["queued", "running"].includes(job.status) && Date.now() < deadline);

  check("job finished successfully", job.status === "done", `${job.status} ${job.error ?? ""}`);
  check("progress counters filled in", job.chunksTotal > 0 && job.chunksDone === job.chunksTotal,
    `${job.chunksDone}/${job.chunksTotal}`);

  const track = job.tracks[0];
  check("track rendered", track?.status === "done", track?.error ?? "");
  check("track has a duration", (track?.duration ?? 0) > 1, `${track?.duration?.toFixed(1)}s`);
  check("track is an mp3", String(track?.url ?? "").length > 0);

  const audioRes = await fetch(`${base}${track.url}`);
  const bytes = new Uint8Array(await audioRes.arrayBuffer());
  check("audio downloads", audioRes.ok && bytes.byteLength > 5000, `${bytes.byteLength} bytes`);
  check("served as audio/mpeg", audioRes.headers.get("content-type") === "audio/mpeg",
    audioRes.headers.get("content-type") ?? "");

  const rangeRes = await fetch(`${base}${track.url}`, { headers: { Range: "bytes=0-99" } });
  check("range requests work (seeking)", rangeRes.status === 206 &&
    rangeRes.headers.get("content-range") === `bytes 0-99/${bytes.byteLength}`,
    rangeRes.headers.get("content-range") ?? `status ${rangeRes.status}`);

  const zipRes = await fetch(`${base}/api/jobs/${created.id}/download`);
  check("zip download works", zipRes.ok && (await zipRes.arrayBuffer()).byteLength > 5000);

  // --- voice preview ---
  const previewUrl = `${base}/api/providers/kokoro/preview?voice=${kokoro.defaultVoice}`;
  const previewRes = await fetch(previewUrl);
  const previewBytes = (await previewRes.arrayBuffer()).byteLength;
  check("voice preview renders", previewRes.ok && previewBytes > 5000,
    `${previewRes.status} ${previewRes.headers.get("content-type")} ${previewBytes} bytes`);

  const cacheStart = Date.now();
  await (await fetch(previewUrl)).arrayBuffer();
  const cacheMs = Date.now() - cacheStart;
  check("repeat preview is served from cache", cacheMs < 500, `${cacheMs}ms`);

  const badVoice = await fetch(`${base}/api/providers/kokoro/preview?voice=definitely_not_a_voice`);
  check("unknown voice is rejected", badVoice.status === 404, `status ${badVoice.status}`);

  // --- live chapter streaming ---
  const streamStart = Date.now();
  const streamRes = await fetch(
    `${base}/api/chapters/${detail.chapters[0]!.id}/stream?provider=kokoro&voice=${kokoro.defaultVoice}&speed=1`,
  );
  check("stream responds as mp3", streamRes.ok && streamRes.headers.get("content-type") === "audio/mpeg",
    `${streamRes.status} ${streamRes.headers.get("content-type")}`);

  const reader = streamRes.body!.getReader();
  let streamedBytes = 0;
  let firstByteMs = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    firstByteMs ||= Date.now() - streamStart;
    streamedBytes += value.byteLength;
  }
  const totalMs = Date.now() - streamStart;
  check("stream delivers audio", streamedBytes > 10_000, `${streamedBytes} bytes`);
  check("audio starts before rendering finishes", firstByteMs < totalMs,
    `first byte ${(firstByteMs / 1000).toFixed(1)}s of ${(totalMs / 1000).toFixed(1)}s total`);

  // Abandoning streams (e.g. dragging the speed slider) must cancel the work
  // gracefully rather than killing and respawning the model worker.
  const countWorkers = () =>
    Number(Bun.spawnSync(["bash", "-c", "ps -eo command | grep -c '[k]okoro_worker.py'"]).stdout.toString().trim());

  const before = countWorkers();
  for (let i = 0; i < 4; i++) {
    const ac = new AbortController();
    const res = await fetch(
      `${base}/api/chapters/${detail.chapters[0]!.id}/stream?provider=kokoro&voice=${kokoro.defaultVoice}&speed=${1 + i * 0.05}`,
      { signal: ac.signal },
    );
    await res.body!.getReader().read();
    ac.abort();
    await Bun.sleep(150);
  }
  await Bun.sleep(1500);
  const after = countWorkers();
  check("abandoned streams don't spawn extra workers", after <= before,
    `${before} before, ${after} after 4 restarts`);

  const recovered = await fetch(
    `${base}/api/chapters/${detail.chapters[0]!.id}/stream?provider=kokoro&voice=${kokoro.defaultVoice}&speed=1`,
  );
  let recoveredBytes = 0;
  const recoveredReader = recovered.body!.getReader();
  while (true) {
    const { done, value } = await recoveredReader.read();
    if (done) break;
    recoveredBytes += value.byteLength;
  }
  check("streaming still works after cancellations", recovered.ok && recoveredBytes > 10_000,
    `${recovered.status}, ${recoveredBytes} bytes`);

  const delRes = await fetch(`${base}/api/books/${book.id}`, { method: "DELETE" });
  const afterDelete = (await (await fetch(`${base}/api/books`)).json()) as unknown[];
  check("deleting a book cleans up", delRes.ok && afterDelete.length === 0);

  const badForm = new FormData();
  badForm.append("file", new File(["not a book"], "thing.pdf"));
  const badRes = await fetch(`${base}/api/books`, { method: "POST", body: badForm });
  check("unsupported file type is rejected", badRes.status === 422, `status ${badRes.status}`);

  // A zip that isn't an EPUB should fail with a useful message, not a crash.
  const junkZip = zipSync({ "notes.txt": strToU8("just some notes") });
  const junkForm = new FormData();
  junkForm.append("file", new File([junkZip as unknown as BlobPart], "folder.zip"));
  const junkRes = await fetch(`${base}/api/books`, { method: "POST", body: junkForm });
  const junkBody = (await junkRes.json()) as { error?: string };
  check("non-EPUB zip is rejected clearly", junkRes.status === 422 && /container\.xml/.test(junkBody.error ?? ""),
    junkBody.error ?? `status ${junkRes.status}`);
} finally {
  const { closeWarmSessions } = await import("../src/server/tts/warm");
  await closeWarmSessions();
  await server.stop(true);
  await rm(dataDir, { recursive: true, force: true });
}

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
