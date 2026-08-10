import {
  DEFAULT_SAMPLE_RATE,
  HEADER_SCAN_BYTES,
  locateWavData,
  pcmDurationSec,
  wavHeader,
  wavSizePatches,
} from "@huiver/shared";
import { mkdir, open, rename, type FileHandle } from "node:fs/promises";
import path from "node:path";

/**
 * The server's WAV files. All header/PCM arithmetic comes from @huiver/shared
 * (the mobile app renders the same format); what lives here is the disk work:
 * appending, truncating and fsyncing partly-rendered chapters.
 */

/** Build a 16-bit mono PCM WAV file from raw little-endian PCM chunks. */
export async function writeWavFromPcm16(
  outPath: string,
  pcmChunks: Uint8Array<ArrayBuffer>[],
  sampleRate: number,
): Promise<{ durationSec: number }> {
  const dataLength = pcmChunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);

  await mkdir(path.dirname(outPath), { recursive: true });
  await Bun.write(outPath, new Blob([wavHeader(dataLength, sampleRate), ...pcmChunks]));

  return { durationSec: pcmDurationSec(dataLength, sampleRate) };
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

    const found = locateWavData(head);
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

export const wavDurationSec = (layout: WavLayout): number => pcmDurationSec(layout.dataBytes, layout.sampleRate);

/** Patch the two length fields that describe how much audio a WAV holds. */
async function writeSizes(handle: FileHandle, dataOffset: number, dataBytes: number): Promise<void> {
  for (const patch of wavSizePatches(dataOffset, dataBytes)) {
    await handle.write(patch.bytes, 0, patch.bytes.byteLength, patch.position);
  }
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
    return { durationSec: pcmDurationSec(position - layout.dataOffset, layout.sampleRate) };
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
