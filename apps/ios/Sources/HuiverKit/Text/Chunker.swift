import Foundation

/// Split chapter text into pieces small enough to synthesise in one go.
///
/// A port of `packages/shared/src/chunk.ts`, and deliberately a faithful one:
/// a chapter has to break at the same places on the phone as it does on the
/// desktop, or the same book read by the two apps would pause in different
/// places.
///
/// The default is smaller here than the web app's 420 characters. Chatterbox's
/// mel decoder is exported at a fixed length, so a chunk that generates more
/// speech tokens than fit has to be decoded in two passes; 260 characters is
/// about ten seconds of speech, which leaves comfortable headroom and gets
/// audio playing sooner.
public enum Chunker {
    public static let defaultMaxChars = 260

    /// Break a paragraph after sentence-ending punctuation, keeping the
    /// punctuation and any closing quote with the sentence it belongs to.
    static func sentences(in paragraph: String) -> [String] {
        var out: [String] = []
        var current = ""
        var closing = false

        for character in paragraph {
            if closing, !#"""'”’)]"#.contains(character), !character.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
                closing = false
            }
            if ".!?…".contains(character) { closing = true }
            current.append(character)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out.isEmpty ? [paragraph] : out
    }

    /// Last resort: break on word boundaries, then mid-word if a single "word"
    /// (a URL, say) is longer than the limit on its own.
    static func splitLong(_ piece: String, max: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in piece.split(whereSeparator: \.isWhitespace) {
            if !current.isEmpty, current.count + 1 + word.count > max {
                out.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : "\(current) \(word)"
            }
        }
        if !current.isEmpty { out.append(current) }

        return out.flatMap { piece -> [String] in
            guard piece.count > max else { return [piece] }
            return stride(from: 0, to: piece.count, by: max).map { start in
                let lower = piece.index(piece.startIndex, offsetBy: start)
                let upper = piece.index(lower, offsetBy: max, limitedBy: piece.endIndex) ?? piece.endIndex
                return String(piece[lower..<upper])
            }
        }
    }

    public static func chunk(_ text: String, max: Int = defaultMaxChars) -> [String] {
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        func append(_ piece: String) {
            if !current.isEmpty, current.count + piece.count + 1 > max { flush() }
            current = current.isEmpty ? piece : "\(current) \(piece)"
        }

        for paragraph in text.splitParagraphs() {
            let clean = flatten(paragraph)
            if clean.isEmpty { continue }

            if !current.isEmpty, current.count + clean.count + 1 > max { flush() }
            if clean.count <= max {
                current = current.isEmpty ? clean : "\(current) \(clean)"
                continue
            }

            for sentence in sentences(in: clean) {
                for piece in sentence.count <= max ? [sentence] : splitLong(sentence, max: max) {
                    append(piece)
                }
            }
            flush()
        }
        flush()
        return chunks
    }

    /// Collapse a paragraph's internal line breaks and runs of spaces.
    static func flatten(_ paragraph: String) -> String {
        paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Give live playback a fast first chunk without cutting the opening
    /// sentence in half.
    public static func chunkWithSentenceLead(_ text: String, max: Int = defaultMaxChars) -> [String] {
        let chunks = chunk(text, max: max)
        guard let first = chunks.first else { return chunks }
        let lead = sentences(in: first)
        guard lead.count >= 2 else { return chunks }
        return ([lead[0], lead.dropFirst().joined(separator: " ")] + chunks.dropFirst())
            .filter { !$0.isEmpty }
    }
}

extension String {
    /// Split on runs of two or more newlines, the paragraph separator the
    /// extractor emits. Written out rather than done with a regular
    /// expression, which on a chapter-sized string is markedly slower.
    func splitParagraphs() -> [String] {
        var out: [String] = []
        var current = ""
        var newlines = 0
        for character in self {
            if character.isNewline {
                newlines += 1
                current.append(character)
            } else {
                if newlines >= 2 {
                    out.append(String(current.dropLast(newlines)))
                    current = ""
                }
                newlines = 0
                current.append(character)
            }
        }
        out.append(newlines >= 2 ? String(current.dropLast(newlines)) : current)
        return out
    }
}
