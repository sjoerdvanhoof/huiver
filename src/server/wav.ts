import { mkdir, open, rename, type FileHandle } from "node:fs/promises";
import path from "node:path";

const DEFAULT_SAMPLE_RATE = 24000;

/** Plenty for a RIFF header, even with LIST/fact chunks ahead of the audio. */
const HEADER_SCAN_BYTES = 64 * 1024;

/** Build a 16-bit mono PCM WAV file from raw little-endian PCM chunks. */
export async function writeWavFromPcm16(
  outPath: string,
  pcmChunks: Uint8Array<ArrayBuffer>[],
  sampleRate: number,
): Promise<{ durationSec: number }> {
  const dataLength = pcmChunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const header = new ArrayBuffer(44);
  const view = new DataView(header);
  const ascii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
  };

  ascii(0, "RIFF");
  view.setUint32(4, 36 + dataLength, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true); // PCM chunk size
  view.setUint16(20, 1, true); // format = PCM
  view.setUint16(22, 1, true); // channels = mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  ascii(36, "data");
  view.setUint32(40, dataLength, true);

  await mkdir(path.dirname(outPath), { recursive: true });
  await Bun.write(outPath, new Blob([header, ...pcmChunks]));

  return { durationSec: dataLength / 2 / sampleRate };
}

/**
 * Where the audio lives inside a WAV, found by walking its chunk table rather
 * than assuming the canonical 44-byte header (encoders like to add LIST/fact
 * chunks).
 */
function locateData(head: Uint8Array): { dataOffset: number; dataBytes: number; sampleRate: number } | null {
  const view = new DataView(head.buffer, head.byteOffset, head.byteLength);
  const tag = (offset: number) => String.fromCharCode(...head.subarray(offset, offset + 4));

  if (head.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;

  let sampleRate = 0;
  let offset = 12;

  while (offset + 8 <= head.byteLength) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;

    if (id === "fmt " && body + 8 <= head.byteLength) sampleRate = view.getUint32(body + 4, true);
    if (id === "data") return { dataOffset: body, dataBytes: size, sampleRate };
    offset = body + size + (size % 2); // chunks are word-aligned
  }

  return null;
}

/** Pull the raw PCM out of a WAV file. */
export function pcmFromWav(bytes: Uint8Array): { pcm: Uint8Array; sampleRate: number } {
  const found = locateData(bytes);
  if (!found) {
    if (bytes.byteLength < 12) throw new Error("Not a WAV file");
    const tag = String.fromCharCode(...bytes.subarray(0, 4));
    throw new Error(tag === "RIFF" ? "WAV file has no data chunk" : "Not a WAV file");
  }

  const end = Math.min(found.dataOffset + found.dataBytes, bytes.byteLength);
  return {
    pcm: bytes.subarray(found.dataOffset, end),
    sampleRate: found.sampleRate || DEFAULT_SAMPLE_RATE,
  };
}

export type WavLayout = {
  /** Byte offset of the PCM payload. */
  dataOffset: number;
  /**
   * Bytes of PCM the file logically holds: what the header claims, clamped to
   * what is actually there. An interrupted write can leave the two disagreeing
   * in either direction, and the smaller number is the part we can trust.
   */
  dataBytes: number;
  sampleRate: number;
  /** Size on disk, which exceeds `dataOffset + dataBytes` after a torn append. */
  fileBytes: number;
};

/** Inspect a WAV on disk. Returns null when it is missing or not a WAV at all. */
export async function readWavLayout(filePath: string): Promise<WavLayout | null> {
  const handle = await open(filePath, "r").catch(() => null);
  if (!handle) return null;

  try {
    const fileBytes = (await handle.stat()).size;
    const head = new Uint8Array(Math.min(fileBytes, HEADER_SCAN_BYTES));
    if (head.byteLength > 0) await handle.read(head, 0, head.byteLength, 0);

    const found = locateData(head);
    if (!found) return null;

    return {
      dataOffset: found.dataOffset,
      dataBytes: Math.max(0, Math.min(found.dataBytes, fileBytes - found.dataOffset)),
      sampleRate: found.sampleRate || DEFAULT_SAMPLE_RATE,
      fileBytes,
    };
  } finally {
    await handle.close();
  }
}

export const wavDurationSec = (layout: WavLayout): number => layout.dataBytes / 2 / layout.sampleRate;

/** Patch the two length fields that describe how much audio a WAV holds. */
async function writeSizes(handle: FileHandle, dataOffset: number, dataBytes: number): Promise<void> {
  const field = new Uint8Array(4);
  const view = new DataView(field.buffer);

  view.setUint32(0, dataOffset + dataBytes - 8, true); // RIFF chunk size
  await handle.write(field, 0, 4, 4);
  view.setUint32(0, dataBytes, true); // data chunk size
  await handle.write(field, 0, 4, dataOffset - 4);
}

/**
 * Append PCM to an existing WAV, or create it when there is none. Writing
 * starts at the *logical* end of the audio, so bytes left behind by an
 * interrupted append are overwritten rather than adopted.
 */
export async function appendPcm16ToWav(
  outPath: string,
  pcmChunks: Uint8Array<ArrayBuffer>[],
  sampleRate: number,
): Promise<{ durationSec: number }> {
  const layout = await readWavLayout(outPath);
  if (!layout) return writeWavFromPcm16(outPath, pcmChunks, sampleRate);

  const handle = await open(outPath, "r+");
  try {
    let position = layout.dataOffset + layout.dataBytes;
    for (const chunk of pcmChunks) {
      if (chunk.byteLength === 0) continue;
      await handle.write(chunk, 0, chunk.byteLength, position);
      position += chunk.byteLength;
    }

    await handle.truncate(position);
    await writeSizes(handle, layout.dataOffset, position - layout.dataOffset);
    return { durationSec: (position - layout.dataOffset) / 2 / layout.sampleRate };
  } finally {
    await handle.close();
  }
}

/**
 * Rewrite a WAV so it holds exactly `dataBytes` of audio, as a brand new file
 * put in place of the old one.
 *
 * Replacing rather than truncating matters when picking up after a crash: a
 * writer that has not yet noticed the crash — an orphaned speech worker whose
 * parent is gone — may still hold the old file open, and anything it writes
 * from here must land in the file we abandoned rather than the audio we are
 * about to continue.
 *
 * Never grows the audio. Returns the bytes it kept.
 */
export async function rewriteWavPrefix(filePath: string, dataBytes: number): Promise<number> {
  const layout = await readWavLayout(filePath);
  if (!layout) return 0;

  const keep = Math.max(0, Math.min(dataBytes, layout.dataBytes));
  const wanted = layout.dataOffset + keep;
  const replacement = `${filePath}.cut`;

  const source = await open(filePath, "r");
  const target = await open(replacement, "w");
  try {
    // Copied in blocks rather than read whole: a chapter's audio runs to tens of
    // megabytes, and none of it needs to be in memory at once.
    const buffer = new Uint8Array(1 << 20);
    for (let offset = 0; offset < wanted; ) {
      const { bytesRead } = await source.read(buffer, 0, Math.min(buffer.byteLength, wanted - offset), offset);
      if (bytesRead === 0) break;
      await target.write(buffer, 0, bytesRead, offset);
      offset += bytesRead;
    }
    await writeSizes(target, layout.dataOffset, keep);
    await target.sync();
  } finally {
    await source.close();
    await target.close();
  }

  await rename(replacement, filePath);
  return keep;
}

/**
 * Cut a WAV back to a known-good amount of audio, dropping anything a crash
 * left past it. A no-op on a file that already ends exactly there.
 */
export async function truncateWavData(filePath: string, dataBytes: number): Promise<void> {
  const layout = await readWavLayout(filePath);
  if (!layout) return;

  const keep = Math.max(0, Math.min(dataBytes, layout.dataBytes));
  if (keep === layout.dataBytes && layout.fileBytes === layout.dataOffset + keep) return;

  await rewriteWavPrefix(filePath, keep);
}

/**
 * Force a partly-rendered WAV out of the OS cache. Checkpoints are only worth
 * recording once the audio they point at has actually reached the disk.
 */
export async function syncWav(filePath: string): Promise<void> {
  const handle = await open(filePath, "r+").catch(() => null);
  if (!handle) return;
  try {
    await handle.sync();
  } catch {
    // Best effort: a filesystem that refuses fsync still leaves a usable file.
  } finally {
    await handle.close();
  }
}

/** Silence, used to space out chunks so sentences do not run together. */
export function silencePcm16(seconds: number, sampleRate: number): Uint8Array<ArrayBuffer> {
  return new Uint8Array(Math.round(seconds * sampleRate) * 2);
}
