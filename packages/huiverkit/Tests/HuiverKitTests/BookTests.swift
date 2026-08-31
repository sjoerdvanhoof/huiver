import Foundation
import Testing

@testable import HuiverKit

struct HTMLTests {
    @Test("turns block tags into paragraph breaks")
    func paragraphs() {
        let html = "<html><body><p>One.</p><p>Two.</p></body></html>"
        #expect(HTML.text(from: html) == "One.\n\nTwo.")
    }

    @Test("drops scripts and styles rather than reading them aloud")
    func scripts() {
        let html = "<p>Keep.</p><script>var x = 1;</script><style>p{color:red}</style>"
        #expect(HTML.text(from: html) == "Keep.")
    }

    @Test("decodes entities")
    func entities() {
        #expect(HTML.entities("Tom &amp; Jerry &#8212; &hellip; &#x41;") == "Tom & Jerry — … A")
        // An ampersand that starts nothing is left alone.
        #expect(HTML.entities("fish & chips") == "fish & chips")
    }

    @Test("finds a heading for an untitled chapter")
    func heading() {
        #expect(HTML.heading(in: "<h1>The <i>Yellow</i> Wallpaper</h1><p>x</p>") == "The Yellow Wallpaper")
        #expect(HTML.heading(in: "<p>no heading</p>") == nil)
    }

    @Test("recognises a contents page by link density")
    func contents() {
        let toc = (1...20).map { "<p><a href='c\($0).xhtml'>Chapter \($0)</a></p>" }.joined()
        #expect(HTML.isContentsPage(toc))

        let chapter = "<p>" + String(repeating: "ordinary prose. ", count: 60)
            + "<a href='n1'>1</a></p>"
        #expect(!HTML.isContentsPage(chapter))
    }
}

struct ExtractTests {
    @Test("resolves hrefs against the document that contains them")
    func resolve() {
        #expect(Extract.resolve("ch1.xhtml", relativeTo: "OEBPS") == "OEBPS/ch1.xhtml")
        #expect(Extract.resolve("../images/x.png", relativeTo: "OEBPS/text") == "OEBPS/images/x.png")
        #expect(Extract.resolve("/abs.xhtml", relativeTo: "OEBPS") == "abs.xhtml")
        #expect(Extract.resolve("./a.xhtml", relativeTo: "") == "a.xhtml")
        // Percent-encoded names are common in EPUBs from Word.
        #expect(Extract.resolve("My%20Chapter.xhtml", relativeTo: "T") == "T/My Chapter.xhtml")
    }

    @Test("splits a plain-text book on chapter headings")
    func plainText() {
        let body = String(repeating: "Prose goes here. ", count: 20)
        let text = "Chapter I\n\n\(body)\n\nChapter II\n\n\(body)"
        let chapters = Extract.plainChapters(text, fallbackTitle: "Book")
        #expect(chapters.count == 2)
        #expect(chapters[0].title == "Chapter I")
        #expect(chapters[1].title == "Chapter II")
    }

    @Test("falls back to one chapter when there are no headings")
    func plainTextNoHeadings() {
        let text = String(repeating: "Just prose. ", count: 40)
        let chapters = Extract.plainChapters(text, fallbackTitle: "Book")
        #expect(chapters.count == 1)
        #expect(chapters[0].title == "Book")
    }

    /// Builds a small EPUB in memory and reads it back, so the zip reader, the
    /// OPF walk and the NCX titles are all exercised together.
    @Test("reads an EPUB end to end")
    func epub() throws {
        let body = String(repeating: "The quiet harbour town woke slowly. ", count: 12)
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            (
                "META-INF/container.xml",
                """
                <?xml version="1.0"?><container version="1.0" \
                xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
                <rootfiles><rootfile full-path="OEBPS/book.opf" \
                media-type="application/oebps-package+xml"/></rootfiles></container>
                """
            ),
            (
                "OEBPS/book.opf",
                """
                <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0">\
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
                <dc:title>A Harbour Book</dc:title><dc:creator>A Narrator</dc:creator>\
                <dc:language>en-GB</dc:language>\
                <meta name="cover" content="cov"/></metadata>\
                <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>\
                <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>\
                <item id="cov" href="images/cover.jpg" media-type="image/jpeg"/>\
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>\
                <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine></package>
                """
            ),
            (
                "OEBPS/toc.ncx",
                """
                <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>\
                <navPoint><navLabel><text>The Jetty</text></navLabel><content src="c1.xhtml"/></navPoint>\
                <navPoint><navLabel><text>The Crossing</text></navLabel><content src="c2.xhtml"/></navPoint>\
                </navMap></ncx>
                """
            ),
            ("OEBPS/images/cover.jpg", "not-really-a-jpeg"),
            ("OEBPS/c1.xhtml", "<html><body><p>\(body)</p></body></html>"),
            ("OEBPS/c2.xhtml", "<html><body><p>\(body)</p></body></html>"),
        ]

        let book = try Extract.book(from: ZipWriter.archive(files), filename: "x.epub")
        #expect(book.title == "A Harbour Book")
        // EPUB2 marks its cover with a <meta>, not a manifest property.
        #expect(book.cover?.data == Data("not-really-a-jpeg".utf8))
        #expect(book.cover?.extension == "jpg")
        #expect(book.author == "A Narrator")
        #expect(book.localeIdentifier == "en-GB")
        #expect(book.chapters.map(\.title) == ["The Jetty", "The Crossing"])
        #expect(book.chapters[0].text.hasPrefix("The quiet harbour town"))
    }
}

/// A stored-only zip writer, just for the test above. Real EPUBs are deflated,
/// which the reader handles; this only needs to produce something it can open.
enum ZipWriter {
    static func archive(_ files: [(String, String)]) -> Data {
        var payload = Data()
        var directory = Data()
        var offsets: [Int] = []

        func u16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]) }
        func u32(_ value: Int) -> Data { u16(value & 0xffff) + u16((value >> 16) & 0xffff) }

        for (name, contents) in files {
            let nameBytes = Data(name.utf8)
            let body = Data(contents.utf8)
            offsets.append(payload.count)
            payload += u32(0x0403_4b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            payload += u32(Int(crc32(body))) + u32(body.count) + u32(body.count)
            payload += u16(nameBytes.count) + u16(0) + nameBytes + body
        }

        for (index, (name, contents)) in files.enumerated() {
            let nameBytes = Data(name.utf8)
            let body = Data(contents.utf8)
            directory += u32(0x0201_4b50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            directory += u32(Int(crc32(body))) + u32(body.count) + u32(body.count)
            directory += u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0)
            directory += u32(0) + u32(offsets[index]) + nameBytes
        }

        var out = payload + directory
        out += u32(0x0605_4b50) + u16(0) + u16(0) + u16(files.count) + u16(files.count)
        out += u32(directory.count) + u32(payload.count) + u16(0)
        return out
    }

    /// The reader never checks it, but a plausible value keeps the archive
    /// openable by other tools while debugging.
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

struct WavTests {
    @Test("round-trips samples through a WAV")
    func roundTrip() {
        let samples: [Float] = (0..<2400).map { sinf(Float($0) * 0.05) * 0.5 }
        let data = WavFile.data(from: samples)
        #expect(data.count == 44 + samples.count * 2)

        let back = WavFile.samples(from: data)
        #expect(back.count == samples.count)
        for (a, b) in zip(samples, back) { #expect(abs(a - b) < 1e-4) }
    }

    @Test("clamps rather than wrapping past full scale")
    func clamps() {
        let back = WavFile.samples(from: WavFile.data(from: [2.0, -2.0]))
        #expect(back[0] > 0.99)
        #expect(back[1] < -0.99)
    }
}

struct CoverTests {
    /// The hash must agree with `coverIndex` in packages/shared/src/cover.ts, or
    /// a book would be one colour in the browser and another on the phone.
    /// Expected values were produced by running that function on these ids.
    @Test("hashes book ids the same way as the TypeScript")
    func matchesTypeScript() {
        let cases: [(String, Int)] = [
            ("", 0),
            ("a", 1),
            ("book", 1),
            ("9f8b1c2d-4e5f-6071-8293-a4b5c6d7e8f9", 5),
            ("huiver", 1),
        ]
        for (id, expected) in cases {
            #expect(Cover.index(for: id) == expected, "index for \(id.debugDescription)")
        }
    }

    @Test("every id lands on a real gradient")
    func inRange() {
        for index in 0..<500 {
            let slot = Cover.index(for: "book-\(index)")
            #expect(slot >= 0 && slot < Cover.gradients.count)
        }
    }

    @Test("drops a leading article from the initial")
    func initials() {
        #expect(Cover.initial(for: "The Yellow Wallpaper") == "Y")
        #expect(Cover.initial(for: "a tale of two cities") == "T")
        #expect(Cover.initial(for: "An Ideal Husband") == "I")
        #expect(Cover.initial(for: "Dracula") == "D")
        #expect(Cover.initial(for: "") == "?")
        // "Theatre" starts with "the" but is not an article.
        #expect(Cover.initial(for: "Theatre") == "T")
    }
}

struct FormatTests {
    @Test("clock durations match the TypeScript")
    func clock() {
        #expect(Format.duration(0) == "0:00")
        #expect(Format.duration(65) == "1:05")
        #expect(Format.duration(245) == "4:05")
        #expect(Format.duration(3845) == "1:04:05")
        #expect(Format.duration(nil) == "—")
        #expect(Format.duration(.infinity) == "—")
    }

    @Test("approximate durations match the TypeScript")
    func approximate() {
        #expect(Format.approximate(20) == "<1 min")
        #expect(Format.approximate(60 * 42) == "42 min")
        #expect(Format.approximate(3600 * 7 + 60 * 40) == "7 h 40 min")
        #expect(Format.approximate(3600 * 2) == "2 h")
        #expect(Format.estimate(60 * 42) == "~42 min")
    }
}
