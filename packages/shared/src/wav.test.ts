import { expect, test } from "bun:test";
import { buildWav, locateWavData, pcmDurationSec, pcmFromWav, silencePcm16, wavHeader, wavSizePatches } from "./wav";

const SAMPLE_RATE = 24000;

/** 16-bit little-endian mono PCM from sample values. */
function pcm(...samples: number[]): Uint8Array {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  samples.forEach((value, index) => view.setInt16(index * 2, value, true));
  return bytes;
}

test("wavHeader describes the audio that follows it", () => {
  const header = wavHeader(1000, SAMPLE_RATE);
  const view = new DataView(header.buffer);

  expect(header.byteLength).toBe(44);
  expect(String.fromCharCode(...header.subarray(0, 4))).toBe("RIFF");
  expect(String.fromCharCode(...header.subarray(8, 12))).toBe("WAVE");
  expect(view.getUint32(4, true)).toBe(36 + 1000); // RIFF size
  expect(view.getUint32(24, true)).toBe(SAMPLE_RATE);
  expect(view.getUint16(22, true)).toBe(1); // mono
  expect(view.getUint16(34, true)).toBe(16); // bits per sample
  expect(view.getUint32(40, true)).toBe(1000); // data size
});

test("buildWav round-trips through pcmFromWav", () => {
  const data = pcm(0, 1000, -1000, 32767, -32768);
  const wav = buildWav([data], SAMPLE_RATE);

  const read = pcmFromWav(wav);
  expect(read.sampleRate).toBe(SAMPLE_RATE);
  expect([...read.pcm]).toEqual([...data]);
});

test("buildWav concatenates pieces in order", () => {
  const wav = buildWav([pcm(1, 2), pcm(3), pcm(4, 5)], SAMPLE_RATE);
  const view = new DataView(wav.buffer, 44);
  expect([0, 1, 2, 3, 4].map(i => view.getInt16(i * 2, true))).toEqual([1, 2, 3, 4, 5]);
});

test("locateWavData walks past extra chunks before the audio", () => {
  // A LIST chunk between fmt and data, as some encoders emit.
  const list = new Uint8Array(12);
  list.set([..."LIST"].map(c => c.charCodeAt(0)), 0);
  new DataView(list.buffer).setUint32(4, 4, true);

  const canonical = buildWav([pcm(7, 8)], SAMPLE_RATE);
  const spliced = new Uint8Array(canonical.byteLength + list.byteLength);
  spliced.set(canonical.subarray(0, 36), 0);
  spliced.set(list, 36);
  spliced.set(canonical.subarray(36), 36 + list.byteLength);
  // The RIFF size field is now wrong, which locateWavData does not care about.

  const found = locateWavData(spliced);
  expect(found?.dataOffset).toBe(44 + list.byteLength);
  expect(found?.sampleRate).toBe(SAMPLE_RATE);
});

test("pcmFromWav rejects anything that is not a WAV", () => {
  expect(() => pcmFromWav(new Uint8Array([1, 2, 3]))).toThrow("Not a WAV file");
  expect(() => pcmFromWav(new TextEncoder().encode("RIFF____WAVEjunk"))).toThrow("no data chunk");
});

test("wavSizePatches patches the two length fields in place", () => {
  const wav = buildWav([pcm(1, 2, 3)], SAMPLE_RATE);
  // Pretend the file grew: patch it to claim twice the audio.
  for (const patch of wavSizePatches(44, 12)) wav.set(patch.bytes, patch.position);

  const view = new DataView(wav.buffer);
  expect(view.getUint32(4, true)).toBe(44 + 12 - 8);
  expect(view.getUint32(40, true)).toBe(12);
});

test("durations follow from byte counts", () => {
  expect(pcmDurationSec(SAMPLE_RATE * 2, SAMPLE_RATE)).toBe(1);
  expect(silencePcm16(0.25, SAMPLE_RATE).byteLength).toBe(0.25 * SAMPLE_RATE * 2);
  expect(silencePcm16(0.25, SAMPLE_RATE).every(byte => byte === 0)).toBe(true);
});
