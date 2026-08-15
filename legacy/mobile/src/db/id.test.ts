import { expect, test } from "bun:test";
import { newId } from "./id";

test("ids are unique across a burst, as a chapter insert produces", () => {
  // A book inserts every chapter inside one transaction, so these all land in
  // the same millisecond — the case a timestamp alone would not survive.
  const ids = Array.from({ length: 5000 }, () => newId("ch"));
  expect(new Set(ids).size).toBe(ids.length);
});

test("ids carry their prefix and are safe in a file path", () => {
  const id = newId("bk");
  expect(id.startsWith("bk_")).toBe(true);
  expect(id).toMatch(/^bk_[0-9a-z]+$/);
});

test("ids stay a predictable length", () => {
  for (const id of [newId("bk"), newId("ch"), newId("tr")]) expect(id.length).toBe(15);
});
