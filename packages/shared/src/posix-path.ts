/**
 * The handful of posix path operations the EPUB reader needs, without
 * `node:path`.
 *
 * Zip entry names are posix paths by specification, so there is no platform
 * behaviour to reproduce here — which is what lets the same extractor run on a
 * Bun server and inside React Native, where `node:path` is not available.
 */

/** Collapse `.` and `..` segments. Leading `..` are kept, as posix does. */
export function normalize(input: string): string {
  const absolute = input.startsWith("/");
  const out: string[] = [];

  for (const segment of input.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      const last = out[out.length - 1];
      if (out.length > 0 && last !== "..") out.pop();
      else if (!absolute) out.push("..");
      continue;
    }
    out.push(segment);
  }

  const joined = out.join("/");
  if (absolute) return `/${joined}`;
  // Preserve posix's trailing-slash-implies-directory shape only where it
  // survives normalization; an empty result means "here".
  return joined || ".";
}

export function join(...parts: string[]): string {
  const joined = parts.filter(part => part.length > 0).join("/");
  return joined === "" ? "." : normalize(joined);
}

export function dirname(input: string): string {
  const trimmed = input.endsWith("/") ? input.slice(0, -1) : input;
  const cut = trimmed.lastIndexOf("/");
  if (cut < 0) return ".";
  if (cut === 0) return "/";
  return trimmed.slice(0, cut);
}

export function basename(input: string, stripExt?: string): string {
  const trimmed = input.endsWith("/") ? input.slice(0, -1) : input;
  const name = trimmed.slice(trimmed.lastIndexOf("/") + 1);
  if (stripExt && stripExt.length < name.length && name.endsWith(stripExt)) {
    return name.slice(0, -stripExt.length);
  }
  return name;
}

/** The final `.ext` of the basename, or "" when there is none. */
export function extname(input: string): string {
  const name = basename(input);
  const dot = name.lastIndexOf(".");
  // A leading dot is a hidden file, not an extension.
  if (dot <= 0) return "";
  return name.slice(dot);
}
