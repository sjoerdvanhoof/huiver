import { expect, test } from "bun:test";
import nodePath from "node:path";
import { basename, dirname, extname, join, normalize } from "./posix-path";

/**
 * This module only exists because `node:path` is missing in React Native. Its
 * whole contract is "behaves like path.posix for zip entry names", so check it
 * against the real thing on the shapes the EPUB reader actually produces.
 */
const CASES = [
  "OEBPS/text/chapter1.xhtml",
  "chapter1.xhtml",
  "OEBPS/../chapter1.xhtml",
  "OEBPS/./text/ch.xhtml",
  "a/b/c/../../d.xhtml",
  "content.opf",
  "META-INF/container.xml",
  "images/cover.jpeg",
];

test("normalize matches path.posix", () => {
  for (const input of CASES) expect(normalize(input)).toBe(nodePath.posix.normalize(input));
});

test("join matches path.posix", () => {
  const pairs: [string, string][] = [
    ["OEBPS", "text/ch1.xhtml"],
    ["OEBPS/text", "../images/cover.png"],
    ["", "content.opf"],
    ["OEBPS", "./ch.xhtml"],
  ];
  for (const [a, b] of pairs) expect(join(a, b)).toBe(nodePath.posix.join(a, b));
});

test("dirname matches path.posix", () => {
  for (const input of CASES) expect(dirname(input)).toBe(nodePath.posix.dirname(input));
});

test("extname matches path.posix", () => {
  for (const input of [...CASES, "book.epub.zip", "noext", ".hidden", "trailing."]) {
    expect(extname(input)).toBe(nodePath.posix.extname(input));
  }
});

test("basename matches path.posix, including extension stripping", () => {
  for (const input of CASES) expect(basename(input)).toBe(nodePath.posix.basename(input));
  expect(basename("my book.epub", ".epub")).toBe(nodePath.posix.basename("my book.epub", ".epub"));
  expect(basename("archive.zip", ".zip")).toBe("archive");

  // Stripping never eats the whole name, so a file called ".epub" keeps its
  // name. (node itself is inconsistent here — it returns "" for ".epub" but
  // ".epub" for "x/.epub" — and the second answer is the useful one.)
  expect(basename(".epub", ".epub")).toBe(".epub");
  expect(basename("x/.epub", ".epub")).toBe(nodePath.posix.basename("x/.epub", ".epub"));
});
