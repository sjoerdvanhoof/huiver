import { buildWav, locateWavData, pcmDurationSec, wavHeader, wavSizePatches } from "@huiver/shared";
import { File, FileMode } from "expo-file-system";

/**
 * Writing WAVs on the phone. The byte layout comes from @huiver/shared — the
 * same code the server uses — so a chapter rendered here is byte-compatible
 * with one rendered on the desktop.
 */

/** Write one chunk's PCM as a complete little WAV. */
export function writeChunkWav(file: File, pcm: Uint8Array, sampleRate: number): void {
  file.create({ intermediates: true, overwrite: true });
  file.write(buildWav([pcm], sampleRate));
}

export const readChunkPcmLength = (file: File): number => {
  const size = file.size ?? 0;
  // Every chunk file is written by writeChunkWav, so the header is canonical.
  return Math.max(0, size - 44);
};

/**
 * Concatenate chunk WAVs into the finished chapter.
 *
 * Streamed rather than read whole: a long chapter's audio runs to hundreds of
 * megabytes, and none of it needs to be in memory at once.
 */
export function stitchChapter(
  chunks: File[],
  destination: File,
  sampleRate: number,
): { durationSec: number; bytes: number } {
  destination.create({ intermediates: true, overwrite: true });
  destination.write(wavHeader(0, sampleRate));

  const handle = destination.open(FileMode.ReadWrite);
  let dataBytes = 0;

  try {
    handle.offset = 44;
    for (const chunk of chunks) {
      if (!chunk.exists) continue;
      const bytes = chunk.open(FileMode.ReadOnly);
      try {
        const size = bytes.size ?? 0;
        const found = locateWavData(readHead(bytes, size));
        if (!found) continue;

        bytes.offset = found.dataOffset;
        const total = Math.min(found.dataBytes, size - found.dataOffset);
        for (let read = 0; read < total; ) {
          const piece = bytes.readBytes(Math.min(COPY_BYTES, total - read));
          if (piece.byteLength === 0) break;
          handle.writeBytes(piece);
          read += piece.byteLength;
          dataBytes += piece.byteLength;
        }
      } finally {
        bytes.close();
      }
    }

    // The header was written with a length of zero; patch in the real one now
    // that the audio is on disk.
    for (const patch of wavSizePatches(44, dataBytes)) {
      handle.offset = patch.position;
      handle.writeBytes(patch.bytes);
    }
  } finally {
    handle.close();
  }

  return { durationSec: pcmDurationSec(dataBytes, sampleRate), bytes: dataBytes };
}

const COPY_BYTES = 1 << 20;
const HEAD_BYTES = 4096;

function readHead(handle: ReturnType<File["open"]>, size: number): Uint8Array {
  handle.offset = 0;
  return handle.readBytes(Math.min(size, HEAD_BYTES));
}
