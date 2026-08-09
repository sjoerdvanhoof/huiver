import { strFromU8, unzipSync } from "fflate";
import path from "node:path";

export type ExtractedChapter = { title: string; text: string };

export type ExtractedBook = {
  title: string;
  author: string | null;
  format: string;
  chapters: ExtractedChapter[];
};

/** Chapters shorter than this are almost always covers, nav docs or copyright pages. */
const MIN_CHAPTER_CHARS = 120;

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  ensp: " ",
  emsp: " ",
  thinsp: " ",
  shy: "",
  mdash: "—",
  ndash: "–",
  hellip: "…",
  lsquo: "‘",
  rsquo: "’",
  ldquo: "“",
  rdquo: "”",
  laquo: "«",
  raquo: "»",
  bull: "•",
  middot: "·",
  deg: "°",
  copy: "©",
  reg: "®",
  trade: "™",
  eacute: "é",
  egrave: "è",
  agrave: "à",
  ccedil: "ç",
  uuml: "ü",
  ouml: "ö",
  auml: "ä",
  szlig: "ß",
  ntilde: "ñ",
};

function decodeEntities(input: string): string {
  return input.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, entity: string) => {
    if (entity.startsWith("#")) {
      const code = entity[1] === "x" || entity[1] === "X"
        ? Number.parseInt(entity.slice(2), 16)
        : Number.parseInt(entity.slice(1), 10);
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : match;
    }
    const named = NAMED_ENTITIES[entity.toLowerCase()];
    return named === undefined ? match : named;
  });
}

/** Crude but dependency-free HTML → readable text. Good enough for EPUB XHTML. */
export function htmlToText(html: string): string {
  let out = html
    .replace(/<\?[\s\S]*?\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(script|style|head)\b[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|section|article|li|tr|h[1-6]|blockquote)\s*>/gi, "\n\n")
    .replace(/<(hr)\s*\/?>/gi, "\n\n")
    .replace(/<[^>]+>/g, "");

  out = decodeEntities(out);

  return out
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function titleFromHtml(html: string): string | null {
  const heading = html.match(/<h[1-6]\b[^>]*>([\s\S]*?)<\/h[1-6]>/i);
  if (heading) {
    const text = htmlToText(heading[1]!).replace(/\s+/g, " ").trim();
    if (text) return text.slice(0, 120);
  }
  const docTitle = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  if (docTitle) {
    const text = decodeEntities(docTitle[1]!).replace(/\s+/g, " ").trim();
    if (text) return text.slice(0, 120);
  }
  return null;
}

function attr(tag: string, name: string): string | null {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)')`, "i"));
  return match ? decodeEntities(match[2] ?? match[3] ?? "") : null;
}

/** Resolve an OPF-relative href into a zip entry path. */
function resolveHref(baseDir: string, href: string): string {
  const clean = decodeURIComponent(href.split("#")[0]!);
  const joined = baseDir ? path.posix.join(baseDir, clean) : clean;
  return path.posix.normalize(joined).replace(/^\.\//, "");
}

const CONTAINER_PATH = "META-INF/container.xml";

/** Zip local-file-header magic: "PK\x03\x04". */
export function looksLikeZip(bytes: Uint8Array): boolean {
  return bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04;
}

const isJunk = (entry: string) => entry.startsWith("__MACOSX/") || entry.includes("/__MACOSX/");

/**
 * Locate the EPUB root inside a zip. Normally that is the archive root, but a
 * zip made by compressing an unpacked .epub *folder* (which is what browsers
 * hand over when you drag a directory onto a file input) nests everything one
 * level deeper.
 */
function findEpubRoot(files: Record<string, Uint8Array>): string {
  const candidates = Object.keys(files)
    .filter(entry => !isJunk(entry))
    .filter(entry => entry === CONTAINER_PATH || entry.endsWith(`/${CONTAINER_PATH}`))
    .sort((a, b) => a.length - b.length);

  const found = candidates[0];
  if (!found) {
    throw new Error(
      "This zip does not look like an EPUB — no META-INF/container.xml inside. " +
        "If you exported a folder, zip the EPUB's contents rather than the folder itself.",
    );
  }
  return found.slice(0, found.length - CONTAINER_PATH.length);
}

/** One table-of-contents entry, keeping the `#fragment` so we can split inside a file. */
type TocEntry = { doc: string; fragment: string | null; label: string };

/**
 * Gutenberg-style EPUBs prefix a chapter label with the caption of the
 * illustration that happens to sit above it. Trim back to the heading.
 */
function cleanTocLabel(label: string): string {
  const match = label.match(/\b(chapter|part|book|canto|section|letter)\b\s+[ivxlcdm\d]/i);
  const trimmed = match?.index ? label.slice(match.index) : label;
  return trimmed.replace(/\s+/g, " ").trim().slice(0, 120);
}

function splitHref(baseDir: string, href: string): { doc: string; fragment: string | null } {
  const [rawPath, fragment] = href.split("#");
  return { doc: resolveHref(baseDir, rawPath ?? ""), fragment: fragment || null };
}

/** EPUB3 nav document: `<nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter One</a>`. */
function parseNavXhtml(html: string, baseDir: string): TocEntry[] {
  const scope =
    html.match(/<nav\b[^>]*epub:type\s*=\s*["'][^"']*\btoc\b[^"']*["'][^>]*>([\s\S]*?)<\/nav>/i)?.[1] ?? html;
  const entries: TocEntry[] = [];

  for (const anchor of scope.match(/<a\b[^>]*>[\s\S]*?<\/a>/gi) ?? []) {
    const href = attr(anchor, "href");
    if (!href) continue;
    const label = cleanTocLabel(htmlToText(anchor));
    if (label) entries.push({ ...splitHref(baseDir, href), label });
  }
  return entries;
}

/** EPUB2 NCX: `<navPoint><navLabel><text>Chapter One</text></navLabel><content src="ch1.html"/>`. */
function parseNcx(xml: string, baseDir: string): TocEntry[] {
  const entries: TocEntry[] = [];

  // Non-greedy to the first </navPoint> still yields the outer point's own
  // <text>/<content>, which is what we want for nested tables of contents.
  for (const point of xml.match(/<navPoint\b[\s\S]*?<\/navPoint>/gi) ?? []) {
    const label = point.match(/<text\b[^>]*>([\s\S]*?)<\/text>/i)?.[1];
    const contentTag = point.match(/<content\b[^>]*>/i)?.[0];
    const src = contentTag ? attr(contentTag, "src") : null;
    if (!label || !src) continue;

    const clean = cleanTocLabel(decodeEntities(label));
    if (clean) entries.push({ ...splitHref(baseDir, src), label: clean });
  }
  return entries;
}

/** Byte offset of the element carrying `id="frag"` (or the legacy `name="frag"`). */
function anchorOffset(html: string, fragment: string): number {
  const escaped = fragment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`<[^>]*\\b(?:id|name)\\s*=\\s*["']${escaped}["']`, "i").exec(html);
  return match ? match.index : -1;
}

/**
 * Slices below this are almost never real chapters — they're illustration
 * captions or section anchors — so they get folded into the preceding chapter.
 */
const MIN_FRAGMENT_CHARS = 500;

/**
 * Project Gutenberg (and many other producers) pack a whole book into a handful
 * of XHTML files and mark chapter starts with `#fragment` anchors. Splitting on
 * spine documents alone would give a few enormous tracks, so cut the document
 * at the anchor positions its own table of contents points to.
 */
function splitAtAnchors(
  html: string,
  entries: TocEntry[],
  fallbackTitle: string,
): { preamble: string; chapters: ExtractedChapter[] } {
  const marks = entries
    .filter(entry => entry.fragment)
    .map(entry => ({ offset: anchorOffset(html, entry.fragment!), label: entry.label }))
    .filter(mark => mark.offset >= 0)
    .sort((a, b) => a.offset - b.offset)
    // Gutenberg anchors the illustration above a chapter separately from the
    // chapter itself, and both clean up to the same label. Two consecutive
    // marks naming the same chapter are one chapter.
    .filter((mark, index, all) => index === 0 || mark.label !== all[index - 1]!.label);

  if (marks.length < 2) return { preamble: "", chapters: [] };

  const chapters: ExtractedChapter[] = [];

  marks.forEach((mark, index) => {
    const end = marks[index + 1]?.offset ?? html.length;
    const text = htmlToText(html.slice(mark.offset, end));
    if (!text.trim()) return;

    const previous = chapters[chapters.length - 1];
    if (previous && text.length < MIN_FRAGMENT_CHARS) {
      previous.text += `\n\n${text}`;
      return;
    }
    chapters.push({ title: mark.label || `${fallbackTitle} ${chapters.length + 1}`, text });
  });

  // Text above the first anchor belongs to whatever came before it — never to
  // the chapter the first anchor names. The caller decides where to put it.
  return { preamble: htmlToText(html.slice(0, marks[0]!.offset)), chapters };
}

/**
 * A contents page that isn't flagged as one: most of its text sits inside
 * links. Real prose almost never does.
 */
function isNavigationPage(html: string): boolean {
  const anchors = html.match(/<a\b[^>]*>[\s\S]*?<\/a>/gi) ?? [];
  if (anchors.length < 5) return false;

  const total = htmlToText(html).replace(/\s/g, "").length;
  if (total === 0) return false;
  const linked = anchors.reduce((sum, a) => sum + htmlToText(a).replace(/\s/g, "").length, 0);

  return linked / total > 0.6;
}

function extractEpub(bytes: Uint8Array): ExtractedBook {
  const files = unzipSync(bytes);
  const root = findEpubRoot(files);
  const read = (entry: string): string | null => {
    const data = files[root + entry];
    return data ? strFromU8(data) : null;
  };

  const container = read(CONTAINER_PATH);
  if (!container) throw new Error("Not a valid EPUB: META-INF/container.xml missing");

  const rootfile = container.match(/<rootfile\b[^>]*>/i);
  const opfPath = rootfile && attr(rootfile[0], "full-path");
  if (!opfPath) throw new Error("Not a valid EPUB: no rootfile in container.xml");

  const opf = read(opfPath);
  if (!opf) throw new Error(`Not a valid EPUB: ${opfPath} missing`);
  const opfDir = path.posix.dirname(opfPath) === "." ? "" : path.posix.dirname(opfPath);

  const title = opf.match(/<dc:title\b[^>]*>([\s\S]*?)<\/dc:title>/i)
    ?? opf.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  const creator = opf.match(/<dc:creator\b[^>]*>([\s\S]*?)<\/dc:creator>/i);

  // manifest id -> { href, type, properties }
  const manifest = new Map<string, { href: string; type: string; properties: string }>();
  for (const tag of opf.match(/<item\b[^>]*>/gi) ?? []) {
    const id = attr(tag, "id");
    const href = attr(tag, "href");
    if (!id || !href) continue;
    manifest.set(id, {
      href,
      type: attr(tag, "media-type") ?? "",
      properties: attr(tag, "properties") ?? "",
    });
  }

  const bookTitle = title ? decodeEntities(title[1]!).replace(/\s+/g, " ").trim() : "Untitled";

  // The table of contents is the only reliable source of chapter names: many
  // EPUBs have no <h1> and give every document the same <title> (the book's).
  const navItem = [...manifest.values()].find(item => item.properties.split(/\s+/).includes("nav"));
  const ncxId = attr(opf.match(/<spine\b[^>]*>/i)?.[0] ?? "", "toc");
  const ncxItem = ncxId ? manifest.get(ncxId) : undefined;

  const navPaths = new Set<string>();
  let tocEntries: TocEntry[] = [];

  if (navItem) {
    const navPath = resolveHref(opfDir, navItem.href);
    navPaths.add(navPath);
    const html = read(navPath);
    if (html) tocEntries = parseNavXhtml(html, path.posix.dirname(navPath));
  }
  if (tocEntries.length === 0 && ncxItem) {
    const ncxPath = resolveHref(opfDir, ncxItem.href);
    navPaths.add(ncxPath);
    const xml = read(ncxPath);
    if (xml) tocEntries = parseNcx(xml, path.posix.dirname(ncxPath));
  }

  // Entries grouped per spine document, in table-of-contents order.
  const tocByDoc = new Map<string, TocEntry[]>();
  for (const entry of tocEntries) {
    const list = tocByDoc.get(entry.doc);
    if (list) list.push(entry);
    else tocByDoc.set(entry.doc, [entry]);
  }

  const spineBlock = opf.match(/<spine\b[^>]*>([\s\S]*?)<\/spine>/i)?.[1] ?? "";
  const chapters: ExtractedChapter[] = [];

  for (const tag of spineBlock.match(/<itemref\b[^>]*>/gi) ?? []) {
    const idref = attr(tag, "idref");
    if (!idref) continue;
    const item = manifest.get(idref);
    if (!item) continue;
    if (item.type && !/xhtml|html/i.test(item.type)) continue;

    const docPath = resolveHref(opfDir, item.href);
    if (navPaths.has(docPath)) continue; // the nav document itself

    const html = read(docPath);
    if (!html) continue;
    if (isNavigationPage(html)) continue; // an unmarked contents page

    const entries = tocByDoc.get(docPath) ?? [];
    const fromHtml = titleFromHtml(html);
    const docTitle =
      entries[0]?.label
      ?? (fromHtml && fromHtml !== bookTitle ? fromHtml : null)
      ?? `Chapter ${chapters.length + 1}`;

    // Several chapters inside one file? Cut it at their anchors.
    const split = splitAtAnchors(html, entries, docTitle);
    if (split.chapters.length > 0) {
      const previous = chapters[chapters.length - 1];
      if (split.preamble.trim()) {
        // Continuation of the previous chapter, or front matter if there is none.
        if (previous) previous.text += `\n\n${split.preamble}`;
        else if (split.preamble.length >= MIN_CHAPTER_CHARS) {
          chapters.push({ title: fromHtml ?? bookTitle, text: split.preamble });
        }
      }
      chapters.push(...split.chapters.filter(chapter => chapter.text.length >= MIN_CHAPTER_CHARS));
      continue;
    }

    const text = htmlToText(html);
    if (text.length < MIN_CHAPTER_CHARS) continue;
    chapters.push({ title: docTitle, text });
  }

  if (chapters.length === 0) throw new Error("No readable text found in this EPUB");

  return {
    title: bookTitle,
    author: creator ? decodeEntities(creator[1]!).replace(/\s+/g, " ").trim() || null : null,
    format: "epub",
    chapters,
  };
}

/** Split plain text on markdown headings or "Chapter N" lines; otherwise keep as one part. */
function splitPlainText(text: string): ExtractedChapter[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const headingAt = (line: string): string | null => {
    const md = line.match(/^#{1,3}\s+(.{1,120})$/);
    if (md) return md[1]!.trim();
    const numbered = line.match(/^\s*(chapter|part|book)\s+([0-9]+|[ivxlcdm]+)\b\.?\s*(.{0,80})$/i);
    if (numbered) return line.trim();
    return null;
  };

  const chapters: ExtractedChapter[] = [];
  let title: string | null = null;
  let sawHeading = false;
  let buffer: string[] = [];

  const flush = () => {
    const body = buffer.join("\n").trim();
    buffer = [];
    if (body.length < MIN_CHAPTER_CHARS && chapters.length > 0) {
      // Too small to stand alone — fold it back into the previous chapter.
      if (body) chapters[chapters.length - 1]!.text += `\n\n${body}`;
      return;
    }
    if (!body) return;
    chapters.push({ title: title ?? `Part ${chapters.length + 1}`, text: body });
  };

  for (const line of lines) {
    const heading = headingAt(line);
    if (heading) {
      flush();
      sawHeading = true;
      title = heading;
      continue;
    }
    buffer.push(line);
  }
  flush();

  if (!sawHeading || chapters.length === 0) {
    const body = text.trim();
    if (!body) throw new Error("File is empty");
    return [{ title: "Full text", text: body }];
  }
  return chapters;
}

/**
 * Dispatch on file *content*, not on the extension — browsers rename files on
 * the way in (a dragged folder arrives as `.zip`), so the name is only a hint.
 */
export async function extractBook(filePath: string, originalName: string): Promise<ExtractedBook> {
  const ext = path.extname(originalName).toLowerCase();
  // ".epub" is also stripped from names like "book.epub.zip".
  const baseName = path.basename(originalName, ext).replace(/\.epub$/i, "").replace(/[_-]+/g, " ").trim();
  const bytes = new Uint8Array(await Bun.file(filePath).arrayBuffer());

  if (bytes.byteLength === 0) throw new Error("That file is empty");

  if (looksLikeZip(bytes)) {
    const book = extractEpub(bytes);
    return { ...book, title: book.title === "Untitled" ? baseName || "Untitled" : book.title };
  }

  if (!TEXT_EXTENSIONS.includes(ext)) {
    throw new Error(
      `Unsupported file '${originalName}'. Expected an EPUB, or a text file (${TEXT_EXTENSIONS.join(", ")}).`,
    );
  }

  const raw = new TextDecoder().decode(bytes);
  const text = ext === ".html" || ext === ".htm" || ext === ".xhtml" ? htmlToText(raw) : raw;

  return {
    title: baseName || "Untitled",
    author: null,
    format: ext.replace(".", "") || "txt",
    chapters: splitPlainText(text),
  };
}

const TEXT_EXTENSIONS = [".txt", ".md", ".markdown", ".html", ".htm", ".xhtml"];

/** Extensions offered in the file picker. Actual validation is content-based. */
export const SUPPORTED_EXTENSIONS = [".epub", ".zip", ...TEXT_EXTENSIONS];
