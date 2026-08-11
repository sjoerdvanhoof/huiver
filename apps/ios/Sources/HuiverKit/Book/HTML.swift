import Foundation

/// Turning a chapter's XHTML into the text a narrator would read.
enum HTML {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let dropped = regex("<(script|style|head)\\b[^>]*>.*?</\\1>")
    private static let breaks = regex("</?(p|div|br|li|tr|h[1-6]|blockquote|section)\\b[^>]*>")
    private static let tags = regex("<[^>]+>")
    private static let anchors = regex("<a\\b[^>]*>(.*?)</a>")
    private static let headings = regex("<h[1-3]\\b[^>]*>(.*?)</h[1-3]>")

    /// Block-level tags become paragraph breaks so the chunker has something to
    /// split on; everything else is discarded.
    static func text(from html: String) -> String {
        var out = replace(dropped, in: html, with: " ")
        out = replace(breaks, in: out, with: "\n\n")
        out = replace(tags, in: out, with: "")
        out = entities(out)

        // Collapse runs of blank lines, and trailing spaces on each line, so a
        // paragraph break is exactly two newlines.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first heading, used to name a chapter the table of contents missed.
    static func heading(in html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = headings.firstMatch(in: html, range: range),
              let group = Range(match.range(at: 1), in: html)
        else { return nil }
        let title = entities(replace(tags, in: String(html[group]), with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Is this a table of contents rather than a chapter?
    ///
    /// Decided by link density, as the desktop extractor does: a contents page
    /// is mostly anchors, and naming it "Chapter 1" and reading a list of
    /// chapter titles aloud is a bad first impression of the app.
    static func isContentsPage(_ html: String) -> Bool {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let linked = anchors.matches(in: html, range: range).reduce(0) { total, match in
            guard let group = Range(match.range(at: 1), in: html) else { return total }
            return total + entities(replace(tags, in: String(html[group]), with: "")).count
        }
        let body = text(from: html).count
        guard body > 0 else { return true }
        return Double(linked) / Double(body) > 0.4
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "'", "rsquo": "'",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "eacute": "é", "egrave": "è",
    ]

    static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<start]
            let after = rest.index(after: start)
            guard let end = rest[after...].firstIndex(of: ";"),
                  rest.distance(from: after, to: end) <= 8
            else {
                out.append("&")
                rest = rest[after...]
                continue
            }
            let name = String(rest[after..<end])
            if let mapped = named[name] {
                out += mapped
            } else if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits)
                if let value, let scalar = UnicodeScalar(value) {
                    out.append(Character(scalar))
                }
            } else {
                out += "&\(name);"
            }
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }
}
