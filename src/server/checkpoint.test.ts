import { describe, expect, test } from "bun:test";
import { planResume, resumeKey, type CheckpointRow } from "./checkpoint";

const job = { provider: "kokoro", voice: "af_heart", speed: 1 };
const chunks = ["one", "two", "three", "four"];

describe("resumeKey", () => {
  test("is stable for the same work", () => {
    expect(resumeKey(job, chunks)).toBe(resumeKey({ ...job }, [...chunks]));
  });

  test("changes when the render would differ", () => {
    const base = resumeKey(job, chunks);
    expect(resumeKey({ ...job, voice: "bm_george" }, chunks)).not.toBe(base);
    expect(resumeKey({ ...job, speed: 1.1 }, chunks)).not.toBe(base);
    expect(resumeKey({ ...job, provider: "openai" }, chunks)).not.toBe(base);
    expect(resumeKey(job, ["one", "two", "three"])).not.toBe(base);
    expect(resumeKey(job, ["one", "two", "three", "five"])).not.toBe(base);
  });

  test("tells apart chunk lists that only differ in where they split", () => {
    expect(resumeKey(job, ["a b", "c"])).not.toBe(resumeKey(job, ["a", "b c"]));
  });
});

describe("planResume", () => {
  const key = resumeKey(job, chunks);
  const saved: CheckpointRow = { resume_chunks: 2, resume_bytes: 400, resume_key: key };
  const plan = (over: Partial<Parameters<typeof planResume>[0]> = {}) =>
    planResume({ saved, key, totalChunks: chunks.length, dataBytes: 400, ...over });

  test("continues from the checkpoint when everything lines up", () => {
    expect(plan()).toEqual({ startChunk: 2, dataBytes: 400 });
  });

  test("keeps only the checkpointed audio when the file grew past it", () => {
    // The batch that crashed had written some frames of chunk 3.
    expect(plan({ dataBytes: 512 })).toEqual({ startChunk: 2, dataBytes: 400 });
  });

  test("starts over when the checkpointed audio never reached the disk", () => {
    expect(plan({ dataBytes: 399 })).toBeNull();
  });

  test("starts over when there is no partial file", () => {
    expect(plan({ dataBytes: null })).toBeNull();
  });

  test("starts over when the work changed", () => {
    expect(plan({ key: resumeKey({ ...job, voice: "bm_george" }, chunks) })).toBeNull();
    expect(plan({ saved: { ...saved, resume_key: null } })).toBeNull();
  });

  test("starts over when there is no checkpoint yet", () => {
    expect(plan({ saved: { ...saved, resume_chunks: 0 } })).toBeNull();
    expect(plan({ saved: { ...saved, resume_bytes: 0 } })).toBeNull();
  });

  test("starts over when the checkpoint sits past the end of the chapter", () => {
    expect(plan({ totalChunks: 1 })).toBeNull();
  });

  test("accepts a checkpoint that covers the whole chapter", () => {
    expect(plan({ saved: { ...saved, resume_chunks: 4 } })).toEqual({ startChunk: 4, dataBytes: 400 });
  });
});
