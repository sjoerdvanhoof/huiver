import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { appendFile, open, stat, truncate } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  appendPcm16ToWav,
  pcmFromWav,
  readWavLayout,
  truncateWavData,
  wavDurationSec,
  writeWavFromPcm16,
} from "./wav";

const SAMPLE_RATE = 24000;
const dir = mkdtempSync(path.join(tmpdir(), "huiver-wav-"));

let counter = 0;
const tempWav = () => path.join(dir, `t${counter++}.wav`);

/** 16-bit little-endian mono PCM from sample values. */
function pcm(...samples: number[]): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  samples.forEach((value, index) => view.setInt16(index * 2, value, true));
  return bytes;
}

async function samplesIn(filePath: string): Promise<number[]> {
  const { pcm: data } = pcmFromWav(new Uint8Array(await Bun.file(filePath).arrayBuffer()));
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return Array.from({ length: data.byteLength / 2 }, (_, i) => view.getInt16(i * 2, true));
}

describe("writeWavFromPcm16", () => {
  test("round-trips through pcmFromWav", async () => {
    const file = tempWav();
    const { durationSec } = await writeWavFromPcm16(file, [pcm(1, 2, 3)], SAMPLE_RATE);

    expect(durationSec).toBeCloseTo(3 / SAMPLE_RATE, 10);
    expect(await samplesIn(file)).toEqual([1, 2, 3]);

    const layout = (await readWavLayout(file))!;
    expect(layout.dataOffset).toBe(44);
    expect(layout.dataBytes).toBe(6);
    expect(layout.sampleRate).toBe(SAMPLE_RATE);
    expect(layout.fileBytes).toBe(50);
    expect(wavDurationSec(layout)).toBeCloseTo(3 / SAMPLE_RATE, 10);
  });

  test("rejects things that are not WAV files", () => {
    expect(() => pcmFromWav(new Uint8Array([1, 2, 3]))).toThrow("Not a WAV file");
    expect(() => pcmFromWav(new TextEncoder().encode("RIFF____WAVEjunk"))).toThrow("no data chunk");
  });
});

describe("readWavLayout", () => {
  test("returns null for a missing file", async () => {
    expect(await readWavLayout(path.join(dir, "nope.wav"))).toBeNull();
  });

  test("trusts the file over a header that claims audio it does not have", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2, 3, 4, 5)], SAMPLE_RATE);
    await truncate(file, 44 + 4); // lost tail: header still says 10 bytes

    const layout = (await readWavLayout(file))!;
    expect(layout.dataBytes).toBe(4);
  });
});

describe("appendPcm16ToWav", () => {
  test("creates the file when there is nothing to append to", async () => {
    const file = tempWav();
    const { durationSec } = await appendPcm16ToWav(file, [pcm(7, 8)], SAMPLE_RATE);

    expect(durationSec).toBeCloseTo(2 / SAMPLE_RATE, 10);
    expect(await samplesIn(file)).toEqual([7, 8]);
  });

  test("adds to existing audio and reports the whole file", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2)], SAMPLE_RATE);

    const { durationSec } = await appendPcm16ToWav(file, [pcm(3), pcm(4, 5)], SAMPLE_RATE);

    expect(durationSec).toBeCloseTo(5 / SAMPLE_RATE, 10);
    expect(await samplesIn(file)).toEqual([1, 2, 3, 4, 5]);
    expect((await readWavLayout(file))!.dataBytes).toBe(10);
  });

  test("overwrites bytes an interrupted append left past the audio", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2)], SAMPLE_RATE);
    // A crash mid-append: extra bytes on disk that the header knows nothing about.
    await appendFile(file, pcm(999, 999, 999));

    await appendPcm16ToWav(file, [pcm(3)], SAMPLE_RATE);

    expect(await samplesIn(file)).toEqual([1, 2, 3]);
    expect((await stat(file)).size).toBe(44 + 6);
  });
});

describe("truncateWavData", () => {
  test("cuts back to a known-good amount of audio", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2, 3, 4)], SAMPLE_RATE);

    await truncateWavData(file, 4);

    expect(await samplesIn(file)).toEqual([1, 2]);
    expect((await stat(file)).size).toBe(44 + 4);
    expect((await readWavLayout(file))!.dataBytes).toBe(4);
  });

  test("drops a torn tail even when the header already agrees", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2)], SAMPLE_RATE);
    await appendFile(file, pcm(999, 999));

    await truncateWavData(file, 4);

    expect(await samplesIn(file)).toEqual([1, 2]);
    expect((await stat(file)).size).toBe(44 + 4);
  });

  test("never grows a file, and leaves an exact one alone", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2)], SAMPLE_RATE);

    await truncateWavData(file, 999);

    expect(await samplesIn(file)).toEqual([1, 2]);
    expect((await stat(file)).size).toBe(44 + 4);
  });

  test("leaves a writer that still holds the old file writing into nothing", async () => {
    const file = tempWav();
    await writeWavFromPcm16(file, [pcm(1, 2, 3, 4)], SAMPLE_RATE);

    // Stand in for the speech worker a crashed server left behind: it has the
    // file open and is about to append another chunk.
    const stale = await open(file, "r+");
    try {
      await truncateWavData(file, 4);
      await stale.write(pcm(999, 999), 0, 4, 44 + 8);

      expect(await samplesIn(file)).toEqual([1, 2]);
      expect((await stat(file)).size).toBe(44 + 4);
    } finally {
      await stale.close();
    }
  });

  test("is a no-op on a file that is not a WAV", async () => {
    const file = path.join(dir, "notwav.bin");
    await Bun.write(file, "hello");
    await truncateWavData(file, 2);
    expect(await Bun.file(file).text()).toBe("hello");
  });
});
