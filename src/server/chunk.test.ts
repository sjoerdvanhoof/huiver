import { expect, test } from "bun:test";
import { chunkText } from "./chunk";

const MAX = 420;

test("short text stays as one chunk", () => {
  expect(chunkText("Hello there. This is short.")).toEqual(["Hello there. This is short."]);
});

test("every chunk respects the size limit", () => {
  const text = new Array(60).fill("The quick brown fox jumps over the lazy dog.").join(" ");
  const chunks = chunkText(text);

  expect(chunks.length).toBeGreaterThan(1);
  for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(MAX);
});

test("no words are lost when splitting", () => {
  const text = new Array(40).fill("Alpha bravo charlie delta echo foxtrot.").join(" ");
  const rejoined = chunkText(text).join(" ").replace(/\s+/g, " ");

  expect(rejoined).toBe(text.replace(/\s+/g, " "));
});

test("a single word longer than the limit is hard-split rather than dropped", () => {
  const monster = "x".repeat(1000);
  const chunks = chunkText(monster);

  expect(chunks.join("")).toBe(monster);
  for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(MAX);
});

test("empty and whitespace-only input yields no chunks", () => {
  expect(chunkText("")).toEqual([]);
  expect(chunkText("   \n\n  \t ")).toEqual([]);
});

test("paragraphs are packed together when they fit", () => {
  expect(chunkText("First para.\n\nSecond para.")).toEqual(["First para. Second para."]);
});
