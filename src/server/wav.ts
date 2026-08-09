import { mkdir } from "node:fs/promises";
import path from "node:path";

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
 * Pull the raw PCM out of a WAV file by walking its chunk table, rather than
 * assuming the canonical 44-byte header (encoders like to add LIST/fact chunks).
 */
export function pcmFromWav(bytes: Uint8Array): { pcm: Uint8Array; sampleRate: number } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) => String.fromCharCode(...bytes.subarray(offset, offset + 4));

  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") {
    throw new Error("Not a WAV file");
  }

  let sampleRate = 24000;
  let offset = 12;

  while (offset + 8 <= bytes.byteLength) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;

    if (id === "fmt " && body + 8 <= bytes.byteLength) sampleRate = view.getUint32(body + 4, true);
    if (id === "data") {
      const end = Math.min(body + size, bytes.byteLength);
      return { pcm: bytes.subarray(body, end), sampleRate };
    }
    offset = body + size + (size % 2); // chunks are word-aligned
  }

  throw new Error("WAV file has no data chunk");
}

/** Silence, used to space out chunks so sentences do not run together. */
export function silencePcm16(seconds: number, sampleRate: number): Uint8Array<ArrayBuffer> {
  return new Uint8Array(Math.round(seconds * sampleRate) * 2);
}
