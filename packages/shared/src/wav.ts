/**
 * WAV byte math, with no filesystem in sight.
 *
 * Every audio path in the project — the server appending chunks to a partial on
 * disk, the phone stitching synthesized chunks into a chapter — works on the
 * same 16-bit mono PCM layout. Only the I/O differs, so only the I/O lives with
 * its platform.
 */

export const DEFAULT_SAMPLE_RATE = 24000;

/** Plenty for a RIFF header, even with LIST/fact chunks ahead of the audio. */
export const HEADER_SCAN_BYTES = 64 * 1024;

/** Bytes per sample of 16-bit mono PCM. */
const BYTES_PER_SAMPLE = 2;

/** The canonical 44-byte header for `dataLength` bytes of 16-bit mono PCM. */
export function wavHeader(dataLength: number, sampleRate: number): Uint8Array<ArrayBuffer> {
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
  view.setUint32(28, sampleRate * BYTES_PER_SAMPLE, true); // byte rate
  view.setUint16(32, BYTES_PER_SAMPLE, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  ascii(36, "data");
  view.setUint32(40, dataLength, true);

  return new Uint8Array(header);
}

/** A whole WAV file, built in memory from PCM pieces. */
export function buildWav(pcmChunks: Uint8Array[], sampleRate: number): Uint8Array<ArrayBuffer> {
  const dataLength = pcmChunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(44 + dataLength);
  out.set(wavHeader(dataLength, sampleRate), 0);

  let offset = 44;
  for (const chunk of pcmChunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/**
 * Where the audio lives inside a WAV, found by walking its chunk table rather
 * than assuming the canonical 44-byte header (encoders like to add LIST/fact
 * chunks).
 */
export function locateWavData(
  head: Uint8Array,
): { dataOffset: number; dataBytes: number; sampleRate: number } | null {
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
  const found = locateWavData(bytes);
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

/**
 * The two length fields that describe how much audio a WAV holds, as
 * `{ position, bytes }` patches an I/O layer can apply wherever the file lives.
 */
export function wavSizePatches(
  dataOffset: number,
  dataBytes: number,
): { position: number; bytes: Uint8Array<ArrayBuffer> }[] {
  const u32 = (value: number) => {
    const field = new Uint8Array(4);
    new DataView(field.buffer).setUint32(0, value, true);
    return field;
  };

  return [
    { position: 4, bytes: u32(dataOffset + dataBytes - 8) }, // RIFF chunk size
    { position: dataOffset - 4, bytes: u32(dataBytes) }, // data chunk size
  ];
}

export const pcmDurationSec = (dataBytes: number, sampleRate: number): number =>
  dataBytes / BYTES_PER_SAMPLE / sampleRate;

/** Silence, used to space out chunks so sentences do not run together. */
export function silencePcm16(seconds: number, sampleRate: number): Uint8Array<ArrayBuffer> {
  return new Uint8Array(Math.round(seconds * sampleRate) * BYTES_PER_SAMPLE);
}
