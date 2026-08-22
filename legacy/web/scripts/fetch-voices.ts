/**
 * Build the Chatterbox voice pack.
 *
 * Chatterbox has no voices of its own — it clones whatever reference clip it is
 * given — so the "voices" in the picker are a folder of short WAVs. This fills
 * that folder from LibriVox, whose recordings are public domain and whose solo
 * readings give us one voice per clip in a consistent room.
 *
 * Nothing is bundled in the repo, and nothing large is downloaded: ffmpeg
 * range-requests its way to the offset we want and pulls out ~13 seconds,
 * leaving the rest of the chapter on archive.org. Loudness is normalised so
 * every reference sits at the same level, which is one less thing for the clone
 * to inherit.
 *
 *   bun run voices
 */
import { mkdir, rename, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  BUILTIN_DIR,
  BUILTIN_VOICES,
  REFERENCE_SAMPLE_RATE,
  builtinPath,
  type BuiltinVoiceSource,
} from "../src/server/tts/chatterbox-voices";
import { ffmpegBinary } from "../src/server/ffmpeg";
import { readWavLayout, wavDurationSec } from "../src/server/wav";

/** Exactly what Chatterbox's speech encoder reads; anything past it is dropped. */
const CLIP_SECONDS = 15;

/**
 * A clip shorter than this is a failed download, not a short reading.
 *
 * ffmpeg reading over HTTP exits 0 having written only a header when
 * archive.org cuts a range request short — which it does when asked for ten
 * files in a row — so the exit code is not enough to go on. Chatterbox would
 * accept the resulting stub and clone a voice from nothing.
 */
const MIN_USABLE_SECONDS = 10;

const ATTEMPTS = 3;
const force = process.argv.includes("--force");

/**
 * Resolve the item's audio at fetch time rather than hardcoding filenames:
 * archive.org keeps identifiers stable but the files inside them get renamed.
 */
async function resolveMp3(voice: BuiltinVoiceSource): Promise<string | null> {
  const response = await fetch(`https://archive.org/metadata/${voice.item}`, {
    headers: { "User-Agent": "huiver-voice-fetcher/0.1 (local use; public-domain audio)" },
  });
  if (!response.ok) return null;

  const body = (await response.json()) as { files?: { name?: string }[] };
  const names = (body.files ?? [])
    .map(file => file.name ?? "")
    .filter(name => name.endsWith("_64kb.mp3"))
    .sort();

  const chosen = names[voice.fileIndex] ?? names[0];
  return chosen ? `https://archive.org/download/${voice.item}/${chosen}` : null;
}

/**
 * Cut the clip to a scratch file and only move it into place once it is real
 * audio, so a half-finished download can never present itself as a voice — nor
 * replace a good clip from an earlier run.
 */
async function cutClip(url: string, voice: BuiltinVoiceSource, dest: string): Promise<string | null> {
  const scratch = path.join(tmpdir(), `huiver-voice-${voice.id}-${crypto.randomUUID().slice(0, 8)}.wav`);

  try {
    const proc = Bun.spawn(
      [
        ffmpegBinary(), "-hide_banner", "-loglevel", "error",
        // Before -i, so ffmpeg seeks with a range request instead of decoding
        // its way there from the start of the file.
        "-ss", String(voice.offsetSeconds),
        "-i", url,
        "-t", String(CLIP_SECONDS),
        "-ac", "1", "-ar", String(REFERENCE_SAMPLE_RATE),
        // LibriVox levels vary by tens of decibels between readers; even them
        // out so no voice clones from a clip that is mostly noise floor.
        "-af", "loudnorm=I=-20:TP=-2:LRA=9",
        "-c:a", "pcm_s16le", "-y", scratch,
      ],
      { stdout: "ignore", stderr: "pipe" },
    );

    const stderr = await new Response(proc.stderr).text();
    if ((await proc.exited) !== 0) return stderr.trim().split("\n").pop() || "ffmpeg failed";

    const layout = await readWavLayout(scratch);
    const seconds = layout ? wavDurationSec(layout) : 0;
    if (seconds < MIN_USABLE_SECONDS) {
      return `download was cut short — got ${seconds.toFixed(1)}s of the ${CLIP_SECONDS}s clip`;
    }

    await rename(scratch, dest);
    return null;
  } finally {
    await rm(scratch, { force: true });
  }
}

await mkdir(BUILTIN_DIR, { recursive: true });

let installed = 0;
let skipped = 0;
const failures: string[] = [];

for (const [index, voice] of BUILTIN_VOICES.entries()) {
  const dest = builtinPath(voice.id);

  if (!force && (await Bun.file(dest).exists())) {
    console.log(`· ${voice.id.padEnd(18)} already present`);
    skipped++;
    continue;
  }

  process.stdout.write(`↓ ${voice.id.padEnd(18)} ${voice.reader} … `);

  // archive.org throttles a run of range requests, and a throttled one comes
  // back as a 5XX or as a truncated read. Both are worth another go.
  let error: string | null = "not attempted";
  for (let attempt = 1; attempt <= ATTEMPTS && error; attempt++) {
    if (attempt > 1) {
      process.stdout.write("retrying … ");
      await Bun.sleep(2000 * attempt);
    }
    const url = await resolveMp3(voice);
    error = url ? await cutClip(url, voice, dest) : `archive.org item ${voice.item} has no 64 kbps MP3`;
  }

  if (error) {
    console.log("FAILED");
    failures.push(`${voice.id} — ${error}`);
    continue;
  }

  console.log(`${CLIP_SECONDS}s, ${(Bun.file(dest).size / 1024).toFixed(0)} KB`);
  installed++;

  // Be a polite guest on someone else's bandwidth, as the example fetcher is.
  if (index < BUILTIN_VOICES.length - 1) await Bun.sleep(700);
}

console.log();
for (const failure of failures) console.log(`  ! ${failure}`);

const total = installed + skipped;
console.log(
  failures.length === 0
    ? `${total} voice${total === 1 ? "" : "s"} ready in ${BUILTIN_DIR}\n` +
        "Pick Chatterbox Nano as the engine in Settings, or record your own voice there."
    : `\n${failures.length} voice(s) failed. Re-run to retry just those; --force redoes them all.`,
);

if (failures.length === 0 && installed > 0) {
  console.log("\nVoices are public-domain LibriVox recordings, read by:");
  for (const voice of BUILTIN_VOICES) console.log(`  ${voice.reader.padEnd(22)} ${voice.label}`);
}

process.exit(failures.length === 0 ? 0 : 1);
