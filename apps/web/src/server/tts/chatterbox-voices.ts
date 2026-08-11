import { existsSync } from "node:fs";
import { mkdir, readdir, rm } from "node:fs/promises";
import path from "node:path";
import type { VoiceProfileDTO } from "@huiver/shared";
import { DATA_DIR } from "../db";
import { readWavLayout, wavDurationSec } from "../wav";
import type { Voice } from "./types";

/**
 * Chatterbox's voices.
 *
 * There is no roster to pick from: the model clones whatever reference clip it
 * is handed, so here a "voice" *is* a ten-to-fifteen second WAV on disk. Two
 * kinds live side by side — a downloaded pack of public-domain LibriVox
 * narrators (see scripts/fetch-voices.ts) and clips you recorded yourself.
 *
 * Voices are addressed by id and resolved to a path on every use, so moving the
 * data directory needs no migration.
 */

export const VOICES_DIR = path.join(DATA_DIR, "voices");
export const BUILTIN_DIR = path.join(VOICES_DIR, "builtin");
export const RECORDED_DIR = path.join(VOICES_DIR, "recorded");

/** Reference clips are stored the way the workers want to read them. */
export const REFERENCE_SAMPLE_RATE = 24000;

/**
 * Nano ships a conds.pt — a voice already embedded in the weights — so it can
 * speak before anything has been downloaded or recorded. It is the one voice
 * that is not a file on disk, which is why it is a special case everywhere.
 */
export const MODEL_VOICE_ID = "nano_default";

const MODEL_VOICE: Voice = { id: MODEL_VOICE_ID, label: "Nano — the model's own voice" };

export const usesModelVoice = (id: string): boolean => id === MODEL_VOICE_ID;

export type BuiltinVoiceSource = {
  id: string;
  label: string;
  /** The LibriVox volunteer whose voice this is, credited in the UI. */
  reader: string;
  /** archive.org item the clip is cut from. */
  item: string;
  /**
   * Which of the item's 64 kbps MP3s, by index into their sorted names. 1 is
   * chapter two — chapter one opens with the LibriVox announcement, which is
   * the same formulaic paragraph in every recording.
   */
  fileIndex: number;
  /** Seconds in, chosen to land in the middle of ordinary narration. */
  offsetSeconds: number;
};

/**
 * The shipped pack. Every one is a solo LibriVox reading, which means a single
 * voice, a consistent room, and a public-domain recording we are free to use;
 * they were picked for range across accent, pitch and pace rather than for the
 * books they come from.
 */
export const BUILTIN_VOICES: BuiltinVoiceSource[] = [
  {
    id: "lv_klett",
    label: "Elizabeth — US female, clear and literary",
    reader: "Elizabeth Klett",
    item: "prideandprejudice_1005_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_savage",
    label: "Karen — US female, warm and storybook",
    reader: "Karen Savage",
    item: "anne_greengables_librivox",
    fileIndex: 1,
    offsetSeconds: 240,
  },
  {
    id: "lv_shallenberg",
    label: "Kara — US female, bright and brisk",
    reader: "Kara Shallenberg",
    item: "treasureisland_ks_1510_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_golding",
    label: "Ruth — UK female, measured",
    reader: "Ruth Golding",
    item: "adventures_sherlock_holmes_rg_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_samuel",
    label: "Cori — UK female, crisp",
    reader: "Cori Samuel",
    item: "livingalone_1209_librivox",
    fileIndex: 1,
    offsetSeconds: 150,
  },
  {
    id: "lv_smith",
    label: "Mark — US male, steady and even",
    reader: "Mark F. Smith",
    item: "wind_in_the_willows_solo",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_chenevert",
    label: "Phil — US male, lively",
    reader: "Phil Chenevert",
    item: "thetimemachine_2004_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_neufeld",
    label: "Bob — US male, deep and unhurried",
    reader: "Bob Neufeld",
    item: "studyinscarlet_bn_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_clarke",
    label: "David — UK male, crisp and precise",
    reader: "David Clarke",
    item: "adventuressherlockholmes_v4_1501_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
  {
    id: "lv_praetzellis",
    label: "Adrian — UK male, characterful",
    reader: "Adrian Praetzellis",
    item: "historymrpolly_ap_librivox",
    fileIndex: 1,
    offsetSeconds: 90,
  },
];

const BUILTIN_BY_ID = new Map(BUILTIN_VOICES.map(voice => [voice.id, voice]));

/**
 * Ids end up in filenames, in preview URLs and in resume keys, so keep them to
 * the same alphabet the preview route already accepts. This is also what stops
 * a crafted id from addressing a file outside the voices directory.
 */
export const isValidVoiceId = (id: string): boolean => /^[\w-]{1,64}$/.test(id);

export const builtinPath = (id: string): string => path.join(BUILTIN_DIR, `${id}.wav`);
export const recordedPath = (id: string): string => path.join(RECORDED_DIR, `${id}.wav`);
const recordedMetaPath = (id: string): string => path.join(RECORDED_DIR, `${id}.json`);

/** Where the clip for a voice lives, whichever kind it is. Null if unknown. */
export function referencePath(id: string): string | null {
  if (!isValidVoiceId(id)) return null;
  if (BUILTIN_BY_ID.has(id)) {
    const file = builtinPath(id);
    return existsSync(file) ? file : null;
  }
  const file = recordedPath(id);
  return existsSync(file) ? file : null;
}

type RecordedMeta = { label: string; createdAt: number };

async function readRecordedMeta(id: string): Promise<RecordedMeta | null> {
  try {
    const raw = (await Bun.file(recordedMetaPath(id)).json()) as Partial<RecordedMeta>;
    if (typeof raw.label !== "string") return null;
    return { label: raw.label, createdAt: Number(raw.createdAt) || 0 };
  } catch {
    return null;
  }
}

async function clipSeconds(file: string): Promise<number> {
  const layout = await readWavLayout(file);
  return layout ? wavDurationSec(layout) : 0;
}

/**
 * Every voice that can actually be spoken right now — a catalogue entry whose
 * clip was never downloaded is not offered, since choosing it would only fail
 * at synthesis time.
 */
export async function listVoiceProfiles(): Promise<VoiceProfileDTO[]> {
  const profiles: VoiceProfileDTO[] = [];

  for (const voice of BUILTIN_VOICES) {
    const file = builtinPath(voice.id);
    if (!existsSync(file)) continue;
    profiles.push({
      id: voice.id,
      label: voice.label,
      kind: "builtin",
      seconds: await clipSeconds(file),
      createdAt: null,
    });
  }

  let names: string[] = [];
  try {
    names = await readdir(RECORDED_DIR);
  } catch {
    // Nothing recorded yet.
  }

  const recorded: VoiceProfileDTO[] = [];
  for (const name of names) {
    if (!name.endsWith(".wav")) continue;
    const id = name.slice(0, -4);
    if (!isValidVoiceId(id)) continue;
    const meta = await readRecordedMeta(id);
    recorded.push({
      id,
      label: meta?.label ?? id,
      kind: "recorded",
      seconds: await clipSeconds(recordedPath(id)),
      createdAt: meta?.createdAt ?? null,
    });
  }

  // Newest recording first, so the voice you just made is at the top.
  recorded.sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));
  return [...recorded, ...profiles];
}

/**
 * The provider's voice list, in the shape the picker consumes. The model's own
 * voice is always last: it is the fallback that makes the engine usable before
 * the pack is fetched, not the one to reach for once it is.
 */
export async function listVoices(): Promise<Voice[]> {
  const profiles = await listVoiceProfiles();
  const named = profiles.map(profile => ({
    id: profile.id,
    label: profile.kind === "recorded" ? `${profile.label} (yours)` : profile.label,
  }));
  return [...named, MODEL_VOICE];
}

/**
 * An id for a newly recorded voice: readable enough to recognise in a filename,
 * with a short suffix so recording "Me" twice does not overwrite the first one.
 */
export function newRecordedId(label: string): string {
  const slug = label
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 32);
  return `my_${slug || "voice"}_${crypto.randomUUID().slice(0, 6)}`;
}

export async function saveRecordedVoice(id: string, label: string, wav: Uint8Array): Promise<VoiceProfileDTO> {
  if (!isValidVoiceId(id)) throw new Error("Invalid voice id");
  await mkdir(RECORDED_DIR, { recursive: true });
  await Bun.write(recordedPath(id), wav);
  await Bun.write(recordedMetaPath(id), JSON.stringify({ label, createdAt: Date.now() }, null, 2));

  return {
    id,
    label,
    kind: "recorded",
    seconds: await clipSeconds(recordedPath(id)),
    createdAt: Date.now(),
  };
}

/** Built-in voices are not deletable — re-running the fetch script owns those. */
export async function deleteRecordedVoice(id: string): Promise<boolean> {
  if (!isValidVoiceId(id) || BUILTIN_BY_ID.has(id)) return false;
  if (!existsSync(recordedPath(id))) return false;
  await rm(recordedPath(id), { force: true });
  await rm(recordedMetaPath(id), { force: true });
  return true;
}
