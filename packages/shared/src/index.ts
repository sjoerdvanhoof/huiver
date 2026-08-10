/**
 * Everything both huiver clients agree on: the API/data shapes, the EPUB
 * reader, text chunking, WAV byte layout, and the small formatting helpers.
 *
 * Strictly platform-neutral — no Bun, no node builtins, no DOM. The tsconfig
 * here has neither DOM lib nor ambient types, so a stray platform API fails to
 * compile instead of failing on a phone.
 */
export * from "./chapter-state";
export * from "./checkpoint";
export * from "./chunk";
export * from "./cover";
export * from "./dto";
export * from "./extract";
export * from "./format";
export * from "./pcm";
export * from "./wav";
export * as posixPath from "./posix-path";
