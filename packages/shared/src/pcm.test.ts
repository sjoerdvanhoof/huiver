import { expect, test } from "bun:test";
import { floatToPcm16 } from "./pcm";

const read = (bytes: Uint8Array): number[] => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return Array.from({ length: bytes.byteLength / 2 }, (_, i) => view.getInt16(i * 2, true));
};

test("floats map onto the full int16 range", () => {
  expect(read(floatToPcm16([0, 1, -1, 0.5, -0.5]))).toEqual([0, 32767, -32768, 16384, -16384]);
});

test("samples past ±1 clip rather than wrapping around", () => {
  expect(read(floatToPcm16([2, -2, 1.0001]))).toEqual([32767, -32768, 32767]);
});

test("output is two bytes per sample", () => {
  expect(floatToPcm16(new Float32Array(100)).byteLength).toBe(200);
});
