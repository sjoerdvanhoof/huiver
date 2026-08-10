/**
 * Chunk-level checkpoints for conversion.
 *
 * A chapter is rendered in batches of chunks that are appended to one partial
 * WAV. After each batch the file is flushed and the track row records how many
 * chunks it holds and how many bytes of audio that came to. If the process dies
 * mid-chapter, that pair is enough to pick the render back up where it stopped
 * instead of starting the chapter over.
 *
 * Two things must line up for a partial to be reusable: the work must be
 * identical (same chunks, same voice, same speed) and the audio on disk must
 * still match what the checkpoint claims.
 */

/**
 * cyrb53, a 53-bit string hash. Not `Bun.hash`: the same key has to be
 * computable on the phone, where there is no Bun, and a partial rendered by one
 * runtime should stay resumable by the other.
 */
function hashString(input: string): string {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;

  for (let i = 0; i < input.length; i++) {
    const ch = input.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }

  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);

  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
}

export type CheckpointRow = {
  resume_chunks: number;
  resume_bytes: number;
  resume_key: string | null;
};

/**
 * Identifies the exact work a partial file represents. A chapter re-extracted
 * with different text, or re-queued at another voice or speed, produces a
 * different key and the partial is thrown away rather than continued.
 */
export function resumeKey(
  job: { provider: string; voice: string; speed: number },
  chunks: string[],
): string {
  // Length-prefixed so no separator can be ambiguous: ["a b", "c"] and
  // ["a", "b c"] are different renders and must hash differently.
  const digest = hashString(chunks.map(chunk => `${chunk.length}:${chunk}`).join("|"));
  return `${job.provider}|${job.voice}|${job.speed}|${chunks.length}|${digest}`;
}

export type ResumePlan = {
  /** Index of the first chunk that still has to be rendered. */
  startChunk: number;
  /** Bytes of audio to keep; anything past this is unattributable and dropped. */
  dataBytes: number;
};

/**
 * Decide whether a partial file can be continued, given the checkpoint on the
 * track row and what is actually on disk. Returns null when the render has to
 * start from the beginning.
 */
export function planResume(args: {
  saved: CheckpointRow;
  /** Key of the work about to be rendered. */
  key: string;
  totalChunks: number;
  /** Audio the partial file holds, or null when there is no usable file. */
  dataBytes: number | null;
}): ResumePlan | null {
  const { saved, key, totalChunks, dataBytes } = args;

  if (saved.resume_chunks <= 0 || saved.resume_bytes <= 0) return null;
  if (saved.resume_key !== key) return null;
  // A checkpoint past the end can only mean the chunking changed under us.
  if (saved.resume_chunks > totalChunks) return null;
  if (dataBytes === null) return null;
  // Less audio than the checkpoint promised: its tail never reached the disk,
  // and there is no way to tell which chunk the survivors belong to.
  if (dataBytes < saved.resume_bytes) return null;

  return { startChunk: saved.resume_chunks, dataBytes: saved.resume_bytes };
}
