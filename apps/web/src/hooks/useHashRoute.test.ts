import { describe, expect, test } from "bun:test";
import { href, parseHash } from "./useHashRoute";

describe("parseHash", () => {
  test("empty and root hashes land on the library", () => {
    expect(parseHash("")).toEqual({ name: "library" });
    expect(parseHash("#")).toEqual({ name: "library" });
    expect(parseHash("#/")).toEqual({ name: "library" });
  });

  test("settings is a sheet, so its old URL falls back to the library", () => {
    expect(parseHash("#/settings")).toEqual({ name: "library" });
  });

  test("book pages carry their id", () => {
    expect(parseHash("#/book/bk_abc123")).toEqual({ name: "book", id: "bk_abc123" });
  });

  test("unknown routes fall back to the library", () => {
    expect(parseHash("#/nonsense/deep/path")).toEqual({ name: "library" });
    expect(parseHash("#/book/")).toEqual({ name: "library" });
  });

  test("round-trips through href", () => {
    for (const route of [{ name: "library" } as const, { name: "book", id: "bk_1" } as const]) {
      expect(parseHash(href(route))).toEqual(route);
    }
  });
});
