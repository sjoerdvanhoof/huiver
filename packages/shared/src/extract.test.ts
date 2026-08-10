import { expect, test } from "bun:test";
import { strToU8, unzipSync, zipSync } from "fflate";
import { extractBookFromBytes, htmlToText } from "./extract";

const body = (text: string) => new Array(20).fill(text).join(" ");

function buildEpub(): Uint8Array {
  const chapter = (title: string, text: string) =>
    `<?xml version="1.0" encoding="utf-8"?>
     <html xmlns="http://www.w3.org/1999/xhtml"><head><title>${title}</title></head>
     <body><h1>${title}</h1><p>${text}</p></body></html>`;

  return zipSync({
    "mimetype": strToU8("application/epub+zip"),
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles></container>`,
    ),
    "OEBPS/content.opf": strToU8(
      `<?xml version="1.0"?>
       <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title>The Test Book</dc:title>
           <dc:creator>Ada Lovelace</dc:creator>
         </metadata>
         <manifest>
           <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
           <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
           <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
           <item id="tiny" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
           <item id="css" href="style.css" media-type="text/css"/>
         </manifest>
         <spine>
           <itemref idref="nav"/>
           <itemref idref="tiny"/>
           <itemref idref="c1"/>
           <itemref idref="c2"/>
         </spine>
       </package>`,
    ),
    "OEBPS/nav.xhtml": strToU8(chapter("Contents", body("table of contents link"))),
    "OEBPS/text/cover.xhtml": strToU8("<html><body><p>Cover</p></body></html>"),
    "OEBPS/text/ch1.xhtml": strToU8(chapter("Chapter One", body("It was a bright cold day."))),
    "OEBPS/text/ch2.xhtml": strToU8(chapter("Chapter Two", body("The clocks were striking thirteen."))),
    "OEBPS/style.css": strToU8("body { margin: 0 }"),
  });
}

/** The extractor takes bytes, so uploads are simulated without touching disk. */
const asBytes = (data: Uint8Array | string) => (typeof data === "string" ? strToU8(data) : data);

test("htmlToText strips markup, scripts and entities", () => {
  const html = `<html><head><style>p{color:red}</style></head>
    <body><script>alert(1)</script><h1>Title</h1><p>Caf&eacute; &amp; cr&#232;me.</p><p>Next&hellip;</p></body></html>`;
  const text = htmlToText(html);

  expect(text).toContain("Café & crème.");
  expect(text).toContain("Next…");
  expect(text).not.toContain("alert");
  expect(text).not.toContain("color:red");
  expect(text).not.toContain("<");
});

test("extractBook reads EPUB metadata and spine order", () => {
  const result = extractBookFromBytes(asBytes(buildEpub()), "book.epub");

  expect(result.title).toBe("The Test Book");
  expect(result.author).toBe("Ada Lovelace");
  expect(result.format).toBe("epub");

  // The nav document and the too-short cover page are both dropped.
  expect(result.chapters.map(c => c.title)).toEqual(["Chapter One", "Chapter Two"]);
  expect(result.chapters[0]!.text).toContain("bright cold day");
});

test("extractBook splits plain text on headings", async () => {
  const text = [
    "# Prologue",
    body("Once upon a time."),
    "",
    "Chapter 1",
    body("The story begins."),
  ].join("\n");

  const result = extractBookFromBytes(asBytes(text), "my-story.txt");

  expect(result.title).toBe("my story");
  expect(result.format).toBe("txt");
  expect(result.chapters.map(c => c.title)).toEqual(["Prologue", "Chapter 1"]);
});

test("extractBook falls back to a single part when there are no headings", () => {
  const result = extractBookFromBytes(asBytes(body("No headings here at all.")), "flat.txt");

  expect(result.chapters).toHaveLength(1);
  expect(result.chapters[0]!.title).toBe("Full text");
});

test("a dragged EPUB folder (arrives as .zip) is still recognised", async () => {
  // Browsers hand over a zip named .zip when you drop a directory; the bytes
  // are what matter, not the extension.
  const result = extractBookFromBytes(asBytes(buildEpub()), "book.epub.zip");

  expect(result.format).toBe("epub");
  expect(result.title).toBe("The Test Book");
  expect(result.chapters).toHaveLength(2);
});

test("EPUB nested one level deep inside the zip is found", async () => {
  // ditto/Finder-style archives put everything under the folder name, and add __MACOSX junk.
  const inner = buildEpub();
  const entries: Record<string, Uint8Array> = { "__MACOSX/._junk": strToU8("junk") };
  for (const [name, data] of Object.entries(unzipSync(inner))) {
    entries[`My Book.epub/${name}`] = data;
  }

  const result = extractBookFromBytes(asBytes(zipSync(entries)), "nested.zip");
  expect(result.title).toBe("The Test Book");
  expect(result.chapters.map(c => c.title)).toEqual(["Chapter One", "Chapter Two"]);
});

test("NCX chapter titles win over a repeated <title>", async () => {
  // Mirrors real-world EPUBs where every document is titled after the book.
  const doc = (text: string) =>
    `<html><head><title>The Whole Book</title></head><body><p>${body(text)}</p></body></html>`;

  const epub = zipSync({
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container><rootfiles>
         <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
       </rootfiles></container>`,
    ),
    "content.opf": strToU8(
      `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Whole Book</dc:title></metadata>
         <manifest>
           <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
           <item id="c1" href="a.html" media-type="application/xhtml+xml"/>
           <item id="c2" href="b.html" media-type="application/xhtml+xml"/>
         </manifest>
         <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
       </package>`,
    ),
    "toc.ncx": strToU8(
      `<?xml version="1.0"?><ncx><navMap>
         <navPoint><navLabel><text>Prologue: February 24</text></navLabel><content src="a.html"/></navPoint>
         <navPoint><navLabel><text>Fourth Quarter</text></navLabel><content src="b.html#top"/></navPoint>
       </navMap></ncx>`,
    ),
    "a.html": strToU8(doc("It began on a Tuesday.")),
    "b.html": strToU8(doc("It ended on a Friday.")),
  });

  const result = extractBookFromBytes(asBytes(epub), "ncx.epub");
  expect(result.chapters.map(c => c.title)).toEqual(["Prologue: February 24", "Fourth Quarter"]);
});

test("several chapters inside one spine file are split at their NCX anchors", async () => {
  // The Project Gutenberg shape: one big file, chapter starts marked by anchors.
  // Bodies must clear MIN_FRAGMENT_CHARS (500), below which a slice is treated
  // as a caption/section anchor and folded into the chapter before it.
  const para = (t: string) => `<p>${new Array(40).fill(t).join(" ")}</p>`;
  const page =
    `<html><head><title>The Whole Book</title></head><body>` +
    `${para("Tail end of the previous chapter.")}` +
    `<h2 id="c2">CHAPTER II.</h2>${para("Second chapter body.")}` +
    `<h2 id="c3">CHAPTER III.</h2>${para("Third chapter body.")}` +
    `<h2 id="c4">CHAPTER IV.</h2>${para("Fourth chapter body.")}` +
    `</body></html>`;

  const epub = zipSync({
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container><rootfiles>
         <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
       </rootfiles></container>`,
    ),
    "content.opf": strToU8(
      `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Whole Book</dc:title></metadata>
         <manifest>
           <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
           <item id="p0" href="p0.html" media-type="application/xhtml+xml"/>
           <item id="p1" href="p1.html" media-type="application/xhtml+xml"/>
         </manifest>
         <spine toc="ncx"><itemref idref="p0"/><itemref idref="p1"/></spine>
       </package>`,
    ),
    "toc.ncx": strToU8(
      `<?xml version="1.0"?><ncx><navMap>
         <navPoint><navLabel><text>CHAPTER I.</text></navLabel><content src="p0.html#c1"/></navPoint>
         <navPoint><navLabel><text>An illustration caption. CHAPTER II.</text></navLabel><content src="p1.html#c2"/></navPoint>
         <navPoint><navLabel><text>CHAPTER III.</text></navLabel><content src="p1.html#c3"/></navPoint>
         <navPoint><navLabel><text>CHAPTER IV.</text></navLabel><content src="p1.html#c4"/></navPoint>
       </navMap></ncx>`,
    ),
    "p0.html": strToU8(
      `<html><head><title>The Whole Book</title></head><body>` +
        `<h2 id="c1">CHAPTER I.</h2>${para("First chapter body.")}</body></html>`,
    ),
    "p1.html": strToU8(page),
  });

  const result = extractBookFromBytes(asBytes(epub), "anchors.epub");

  // One track per chapter, not one per file.
  expect(result.chapters.map(c => c.title)).toEqual([
    "CHAPTER I.",
    "CHAPTER II.",
    "CHAPTER III.",
    "CHAPTER IV.",
  ]);

  // Text above the first anchor continues the previous chapter — it must not be
  // dropped, nor mislabelled with the name of the chapter that follows it.
  expect(result.chapters[0]!.text).toContain("Tail end of the previous chapter");
  expect(result.chapters[1]!.text).not.toContain("Tail end of the previous chapter");
  expect(result.chapters[1]!.text).toContain("Second chapter body");
});

test("an unmarked table-of-contents page is dropped", async () => {
  const links = new Array(12)
    .fill(0)
    .map((_, i) => `<a href="ch${i}.html">Chapter number ${i} of this rather long book</a>`)
    .join("<br/>");

  const epub = zipSync({
    "META-INF/container.xml": strToU8(
      `<?xml version="1.0"?><container><rootfiles>
         <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
       </rootfiles></container>`,
    ),
    "content.opf": strToU8(
      `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf">
         <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Linky</dc:title></metadata>
         <manifest>
           <item id="toc" href="contents.html" media-type="application/xhtml+xml"/>
           <item id="c1" href="real.html" media-type="application/xhtml+xml"/>
         </manifest>
         <spine><itemref idref="toc"/><itemref idref="c1"/></spine>
       </package>`,
    ),
    "contents.html": strToU8(`<html><body><h1>Contents</h1>${links}</body></html>`),
    "real.html": strToU8(`<html><body><h1>Chapter One</h1><p>${body("Actual prose here.")}</p></body></html>`),
  });

  const result = extractBookFromBytes(asBytes(epub), "linky.epub");
  expect(result.chapters.map(c => c.title)).toEqual(["Chapter One"]);
});

test("extractBook rejects a non-EPUB zip", () => {
  const notAnEpub = zipSync({ "hello.txt": strToU8("hi") });
  expect(() => extractBookFromBytes(asBytes(notAnEpub), "bad.epub")).toThrow(/META-INF\/container.xml/);
});
