/**
 * Speech engines hand back float samples in −1..1; everything downstream
 * (WAV files, duration maths, the players) is 16-bit little-endian mono PCM.
 */

/** Convert float samples to little-endian 16-bit PCM bytes, clipping at ±1. */
export function floatToPcm16(samples: ArrayLike<number>): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(samples.length * 2);
  const view = new DataView(out.buffer);

  for (let i = 0; i < samples.length; i++) {
    const sample = Math.max(-1, Math.min(1, samples[i] as number));
    // Asymmetric on purpose: int16 reaches −32768 but only +32767.
    view.setInt16(i * 2, Math.round(sample < 0 ? sample * 0x8000 : sample * 0x7fff), true);
  }

  return out;
}
