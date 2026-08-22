import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

process.env.HUIVER_DATA_DIR ??= mkdtempSync(path.join(tmpdir(), "huiver-test-"));

const { VOICE_PROMPT_MIN_SECONDS } = await import("@huiver/shared");
const { voiceRoutes } = await import("./voice-routes");
const { referencePath } = await import("./tts/chatterbox-voices");
const { ffmpegBinary } = await import("./ffmpeg");

/**
 * Everything here goes through ffmpeg, so without one there is nothing worth
 * asserting. Decided once, by asking ffmpeg what it can do — not by attempting
 * a real encode, which under load can fail for reasons that have nothing to do
 * with availability and would silently shrink the suite instead of failing it.
 */
async function ffmpegWithOpus(): Promise<boolean> {
  try {
    const proc = Bun.spawn([ffmpegBinary(), "-hide_banner", "-encoders"], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const listed = await new Response(proc.stdout).text();
    return (await proc.exited) === 0 && listed.includes("libopus");
  } catch {
    return false;
  }
}

/**
 * The browser hands us a compressed container, never a WAV, so the fixtures are
 * WebM/Opus — the same thing Chrome's MediaRecorder produces.
 */
async function webmOfSeconds(seconds: number): Promise<Uint8Array> {
  const file = path.join(tmpdir(), `huiver-fixture-${crypto.randomUUID().slice(0, 8)}.webm`);
  try {
    const proc = Bun.spawn(
      [
        ffmpegBinary(), "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", `sine=frequency=200:duration=${seconds}:sample_rate=48000`,
        "-c:a", "libopus", "-b:a", "32k", "-y", file,
      ],
      { stdout: "ignore", stderr: "pipe" },
    );
    const stderr = await new Response(proc.stderr).text();
    if ((await proc.exited) !== 0) throw new Error(`could not build fixture: ${stderr.trim()}`);
    return new Uint8Array(await Bun.file(file).arrayBuffer());
  } finally {
    await rm(file, { force: true });
  }
}

const post = (bytes: Uint8Array, label: string, trim?: { start: number; end: number }) => {
  const form = new FormData();
  form.append("audio", new File([bytes as BlobPart], "voice.webm", { type: "audio/webm" }), "voice.webm");
  form.append("label", label);
  if (trim) {
    form.append("trimStart", String(trim.start));
    form.append("trimEnd", String(trim.end));
  }
  return voiceRoutes["/api/voices"].POST(new Request("http://localhost/api/voices", { method: "POST", body: form }));
};

const usable = await ffmpegWithOpus();

describe.if(usable)("recording a voice", () => {
  test("a full read is transcoded to a mono reference clip", async () => {
    const response = await post(await webmOfSeconds(12), "Test voice");
    expect(response.status).toBe(201);

    const profile = (await response.json()) as { id: string; label: string; kind: string; seconds: number };
    expect(profile).toMatchObject({ label: "Test voice", kind: "recorded" });
    expect(profile.seconds).toBeCloseTo(12, 0);

    // Whatever container came in, what lands on disk is a WAV the worker reads.
    const stored = referencePath(profile.id);
    expect(stored).toEndWith(".wav");
    const header = new Uint8Array(await Bun.file(stored!).slice(0, 12).arrayBuffer());
    expect(new TextDecoder().decode(header.slice(0, 4))).toBe("RIFF");
    expect(new TextDecoder().decode(header.slice(8, 12))).toBe("WAVE");
  });

  test("a clip too short to clone from is refused, not stored", async () => {
    const response = await post(await webmOfSeconds(2), "Too short");
    expect(response.status).toBe(422);

    const body = (await response.json()) as { error: string };
    // Chatterbox asserts on a short reference, so this has to be caught here.
    expect(body.error).toContain(String(VOICE_PROMPT_MIN_SECONDS));
  });

  test("an uploaded sample is trimmed before it is stored", async () => {
    const response = await post(await webmOfSeconds(18), "Trimmed voice", { start: 3, end: 13 });
    expect(response.status).toBe(201);
    const profile = (await response.json()) as { seconds: number };
    expect(profile.seconds).toBeCloseTo(10, 0);
  });

  test("invalid trim points are refused", async () => {
    const response = await post(await webmOfSeconds(12), "Bad trim", { start: 8, end: 3 });
    expect(response.status).toBe(400);
  });

  test("something that is not audio at all is refused", async () => {
    const response = await post(new TextEncoder().encode("this is not audio"), "Nonsense");
    expect(response.status).toBe(422);
  });

  test("an empty upload is refused before ffmpeg is involved", async () => {
    const response = await post(new Uint8Array(), "Empty");
    expect(response.status).toBe(400);
  });

  test("the passage to read is served alongside the voices", async () => {
    const body = (await (await voiceRoutes["/api/voices"].GET()).json()) as {
      prompt: string;
      minSeconds: number;
      voices: unknown[];
    };
    expect(body.prompt.length).toBeGreaterThan(80);
    expect(body.minSeconds).toBe(VOICE_PROMPT_MIN_SECONDS);
    expect(Array.isArray(body.voices)).toBe(true);
  });
});
