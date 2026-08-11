import Foundation

/// A chapter, before any audio exists for it.
public struct ExtractedChapter: Sendable, Hashable {
    public let title: String
    public let text: String
    public var characters: Int { text.count }
}

public struct ExtractedBook: Sendable, Hashable {
    public let title: String
    public let author: String?
    public let chapters: [ExtractedChapter]
}

/// Turn a file into chapters.
///
/// A port of `packages/shared/src/extract.ts`, and it makes the same two
/// judgement calls that file explains. Chapter names come from the book's own
/// table of contents rather than from headings, because plenty of EPUBs have no
/// `<h1>` and title every document after the book itself; and a document that
/// is mostly links is a contents page, and is dropped.
///
/// Files are identified by their contents, not their name, so a `book.epub.zip`
/// works as well as a `book.epub`.
public enum Extract {
    public enum ExtractError: Error, LocalizedError {
        case unreadable
        case noChapters

        public var errorDescription: String? {
            switch self {
            case .unreadable: "Could not read this file as an ebook"
            case .noChapters: "No readable text in this file"
            }
        }
    }

    public static func book(from data: Data, filename: String) throws -> ExtractedBook {
        let fallbackTitle = (filename as NSString).deletingPathExtension

        if let zip = try? Zip(data: data) {
            // A zipped EPUB, or a folder the browser compressed on the way in.
            if let epub = try? epub(in: zip, fallbackTitle: fallbackTitle) { return epub }
            // A .epub inside a .zip.
            for entry in zip.entries where entry.name.lowercased().hasSuffix(".epub") {
                if let inner = try? zip.read(entry),
                   let book = try? book(from: inner, filename: entry.name) {
                    return book
                }
            }
        }

        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractError.unreadable
        }
        let looksLikeMarkup = text.range(of: "<(html|body|p|div|h1)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        let plain = looksLikeMarkup ? HTML.text(from: text) : text
        let chapters = plainChapters(plain, fallbackTitle: fallbackTitle)
        guard !chapters.isEmpty else { throw ExtractError.noChapters }
        return ExtractedBook(title: fallbackTitle, author: nil, chapters: chapters)
    }

    // MARK: - EPUB

    static func epub(in zip: Zip, fallbackTitle: String) throws -> ExtractedBook {
        guard let containerData = try zip.read("META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let opfPath = container.all("rootfile").compactMap({ $0["full-path"] }).first,
              let opfData = try zip.read(opfPath),
              let opf = XMLTree.parse(opfData)
        else { throw ExtractError.unreadable }

        let base = (opfPath as NSString).deletingLastPathComponent

        var manifest: [String: (href: String, properties: String)] = [:]
        for item in opf.all("item") {
            guard let id = item["id"], let href = item["href"] else { continue }
            manifest[id] = (href, item["properties"] ?? "")
        }

        let spine = opf.first("spine")
        let order = (spine?.all("itemref") ?? []).compactMap { $0["idref"] }

        let titles = tableOfContents(zip: zip, opf: opf, manifest: manifest, spine: spine, base: base)

        var chapters: [ExtractedChapter] = []
        for id in order {
            guard let item = manifest[id] else { continue }
            let path = resolve(item.href, relativeTo: base)
            guard let data = try? zip.read(path) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            if HTML.isContentsPage(html) { continue }

            let text = HTML.text(from: html)
            guard text.count >= 200 else { continue }
            let title = titles[path]
                ?? HTML.heading(in: html)
                ?? "Chapter \(chapters.count + 1)"
            chapters.append(ExtractedChapter(title: title, text: text))
        }

        guard !chapters.isEmpty else { throw ExtractError.noChapters }
        let title = opf.first("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = opf.first("creator")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractedBook(
            title: title?.isEmpty == false ? title! : fallbackTitle,
            author: author?.isEmpty == false ? author : nil,
            chapters: chapters
        )
    }

    /// Chapter titles, keyed by the document they point at.
    ///
    /// EPUB3 puts them in a nav document and EPUB2 in an NCX; both are read,
    /// because plenty of files in the wild ship one and declare the other.
    static func tableOfContents(
        zip: Zip,
        opf: XMLTree,
        manifest: [String: (href: String, properties: String)],
        spine: XMLTree?,
        base: String
    ) -> [String: String] {
        var titles: [String: String] = [:]

        func record(href: String?, title: String, relativeTo directory: String) {
            guard let href, !title.isEmpty else { return }
            let path = resolve(String(href.split(separator: "#")[0]), relativeTo: directory)
            if titles[path] == nil { titles[path] = title }
        }

        if let navId = manifest.first(where: { $0.value.properties.contains("nav") })?.key,
           let href = manifest[navId]?.href,
           let data = try? zip.read(resolve(href, relativeTo: base)),
           let nav = XMLTree.parse(data) {
            let directory = (resolve(href, relativeTo: base) as NSString).deletingLastPathComponent
            let toc = nav.all("nav").first { ($0["type"] ?? "").contains("toc") } ?? nav
            for anchor in toc.all("a") {
                record(
                    href: anchor["href"],
                    title: anchor.allText.trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTo: directory
                )
            }
        }

        if let ncxId = spine?["toc"] ?? manifest.first(where: { $0.value.href.hasSuffix(".ncx") })?.key,
           let href = manifest[ncxId]?.href,
           let data = try? zip.read(resolve(href, relativeTo: base)),
           let ncx = XMLTree.parse(data) {
            let directory = (resolve(href, relativeTo: base) as NSString).deletingLastPathComponent
            for point in ncx.all("navPoint") {
                record(
                    href: point.first("content")?["src"],
                    title: (point.first("navLabel")?.first("text")?.allText ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTo: directory
                )
            }
        }

        return titles
    }

    /// Join a relative href to the directory holding the document it came from,
    /// resolving `..` the way a reader would.
    static func resolve(_ href: String, relativeTo directory: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for piece in decoded.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }

    // MARK: - Plain text

    /// Split a plain-text book on chapter headings, and fall back to one long
    /// chapter when there are none to find.
    static func plainChapters(_ text: String, fallbackTitle: String) -> [ExtractedChapter] {
        let pattern = "(?m)^\\s*(chapter\\s+[\\dIVXLC]+.*|[IVXLC]+\\.?\\s*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [ExtractedChapter(title: fallbackTitle, text: text)]
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard matches.count >= 2 else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [ExtractedChapter(title: fallbackTitle, text: trimmed)]
        }

        var chapters: [ExtractedChapter] = []
        for (index, match) in matches.enumerated() {
            guard let titleRange = Range(match.range, in: text) else { continue }
            let start = titleRange.upperBound
            let end = index + 1 < matches.count
                ? Range(matches[index + 1].range, in: text)!.lowerBound
                : text.endIndex
            let body = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 200 else { continue }
            chapters.append(
                ExtractedChapter(
                    title: text[titleRange].trimmingCharacters(in: .whitespacesAndNewlines),
                    text: body
                )
            )
        }
        return chapters
    }
}
