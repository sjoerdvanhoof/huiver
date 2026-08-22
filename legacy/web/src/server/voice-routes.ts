import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  VOICE_PROMPT_MAX_SECONDS,
  VOICE_PROMPT_MIN_SECONDS,
  VOICE_PROMPT_TEXT,
  type VoiceProfileDTO,
} from "@huiver/shared";
import { forgetVoicePreview } from "./audio-routes";
import { ffmpegBinary } from "./ffmpeg";
import {
  REFERENCE_SAMPLE_RATE,
  deleteRecordedVoice,
  listVoiceProfiles,
  newRecordedId,
  referencePath,
  saveRecordedVoice,
} from "./tts/chatterbox-voices";
import { readWavLayout, wavDurationSec } from "./wav";

/**
 * Recording a narrator.
 *
 * The browser hands us whatever its MediaRecorder produces — WebM/Opus on
 * Chrome and Firefox, MP4/AAC on Safari — and Chatterbox wants a plain mono
 * WAV, so everything goes through ffmpeg on the way in. That also gives us one
 * place to trim, normalise and, most usefully, find out how long the recording
 * actually is: a four-second clip clones badly, and it is far kinder to refuse
 * it here than to let every chapter come out wrong.
 */

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

const json = (body: unknown, status = 200) => Response.json(body, { status });
const fail = (message: string, status = 400) => Response.json({ error: message }, { status });

/**
 * Transcode to the reference format: mono, 24 kHz, levelled, and no longer than
 * the model has any use for.
 */
async function toReferenceWav(
  input: Uint8Array,
  trim?: { start: number; end: number },
): Promise<{ wav: Uint8Array } | { error: string }> {
  const stem = path.join(tmpdir(), `huiver-voice-${crypto.randomUUID().slice(0, 8)}`);
  const source = `${stem}.src`;
  const dest = `${stem}.wav`;

  try {
    await Bun.write(source, input);

    const trimArgs = trim ? ["-ss", String(trim.start)] : [];
    const outputSeconds = trim
      ? Math.min(VOICE_PROMPT_MAX_SECONDS, trim.end - trim.start)
      : VOICE_PROMPT_MAX_SECONDS;
    const proc = Bun.spawn(
      [
        ffmpegBinary(), "-hide_banner", "-loglevel", "error",
        "-i", source,
        ...trimArgs,
        "-t", String(outputSeconds),
        "-ac", "1", "-ar", String(REFERENCE_SAMPLE_RATE),
        // Headset and laptop mics land all over the place; match the level the
        // downloaded pack is normalised to so voices behave alike.
        "-af", "loudnorm=I=-20:TP=-2:LRA=9",
        "-c:a", "pcm_s16le", "-y", dest,
      ],
      { stdout: "ignore", stderr: "pipe" },
    );

    const stderr = await new Response(proc.stderr).text();
    if ((await proc.exited) !== 0) {
      return { error: `Could not read that recording. ${stderr.trim().split("\n").pop() ?? ""}`.trim() };
    }

    const layout = await readWavLayout(dest);
    if (!layout) return { error: "Could not read that recording" };

    const seconds = wavDurationSec(layout);
    if (seconds < VOICE_PROMPT_MIN_SECONDS) {
      return {
        error: `That recording is only ${seconds.toFixed(1)}s. Read the whole passage — about ${VOICE_PROMPT_MIN_SECONDS} seconds is the minimum.`,
      };
    }

    return { wav: new Uint8Array(await Bun.file(dest).arrayBuffer()) };
  } finally {
    await rm(source, { force: true });
    await rm(dest, { force: true });
  }
}

async function createVoice(req: Request): Promise<Response> {
  const form = await req.formData().catch(() => null);
  if (!form) return fail("Expected a multipart form");

  const file = form.get("audio");
  if (!(file instanceof File)) return fail("Expected an 'audio' field");
  if (file.size === 0) return fail("That recording is empty");
  if (file.size > MAX_UPLOAD_BYTES) return fail("That recording is too large");

  const label = String(form.get("label") ?? "").trim().slice(0, 60) || "My voice";

  const trimStart = Number(form.get("trimStart"));
  const trimEnd = Number(form.get("trimEnd"));
  const hasTrim = Number.isFinite(trimStart) && Number.isFinite(trimEnd) && trimEnd > trimStart;
  if ((form.has("trimStart") || form.has("trimEnd")) && !hasTrim) {
    return fail("Those trim points are not valid");
  }

  const converted = await toReferenceWav(
    new Uint8Array(await file.arrayBuffer()),
    hasTrim ? { start: Math.max(0, trimStart), end: trimEnd } : undefined,
  );
  if ("error" in converted) return fail(converted.error, 422);

  try {
    const profile = await saveRecordedVoice(newRecordedId(label), label, converted.wav);
    return json(profile, 201);
  } catch (error) {
    return fail(error instanceof Error ? error.message : "Could not save that voice", 500);
  }
}

/** Play back the reference clip itself — the recording, not a synthesis of it. */
async function serveClip(id: string): Promise<Response> {
  const file = referencePath(id);
  if (!file) return fail("Voice not found", 404);

  const handle = Bun.file(file);
  if (!(await handle.exists())) return fail("Reference clip is missing on disk", 404);

  return new Response(handle, {
    headers: {
      "Content-Type": "audio/wav",
      "Content-Length": String(handle.size),
      // Recorded clips are replaced by a new id, never edited in place.
      "Cache-Control": "public, max-age=86400",
    },
  });
}

export const voiceRoutes = {
  "/api/voices": {
    GET: async () =>
      json({
        prompt: VOICE_PROMPT_TEXT,
        minSeconds: VOICE_PROMPT_MIN_SECONDS,
        maxSeconds: VOICE_PROMPT_MAX_SECONDS,
        voices: await listVoiceProfiles(),
      } satisfies { prompt: string; minSeconds: number; maxSeconds: number; voices: VoiceProfileDTO[] }),

    POST: (req: Request) => createVoice(req),
  },

  "/api/voices/:id/clip": (req: Bun.BunRequest<"/api/voices/:id/clip">) => serveClip(req.params.id),

  "/api/voices/:id": {
    DELETE: async (req: Bun.BunRequest<"/api/voices/:id">) => {
      const removed = await deleteRecordedVoice(req.params.id);
      if (!removed) return fail("That voice is part of the downloaded pack, or does not exist", 404);

      // The cached preview is of a voice that no longer exists, and its id could
      // in principle be handed out again.
      await forgetVoicePreview("chatterbox", req.params.id);
      return json({ ok: true });
    },
  },
} as const;
