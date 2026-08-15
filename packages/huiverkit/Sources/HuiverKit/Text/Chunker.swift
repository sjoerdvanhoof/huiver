import Foundation

/// Split chapter text into pieces small enough to synthesise in one go.
///
/// Began as a port of `packages/shared/src/chunk.ts` and has since diverged
/// from it, deliberately. That one breaks any sentence over its limit at a word
/// boundary; this one does not break sentences at all short of the point where
/// the model could not say them anyway. Since every chunk is followed by a
/// quarter-second of silence, the old behaviour put an audible pause into the
/// middle of every long sentence.
///
/// The two apps therefore no longer pause in the same places. That was worth
/// keeping while both read the same books off the same machine; it stopped
/// being worth an audible defect. `version` is what makes the difference
/// legible to anything that cares — chunk boundaries are file boundaries, so
/// audio and chunking travel together or not at all.
public enum Chunker {
    /// How much text to pack into one chunk.
    ///
    /// Every chunk ends with a quarter-second of silence, so a chunk boundary
    /// is an audible pause. That makes the size a prosody decision as much as a
    /// technical one: chunks are filled up to here with *whole* paragraphs and
    /// whole sentences, and the pause lands where a reader would pause anyway.
    ///
    /// The ceiling above it is not a prosody decision at all — see `ceiling`.
    public static let defaultMaxChars = 300

    /// How far a single sentence may overshoot the target rather than be cut.
    ///
    /// A sentence between the target and this is spoken in one piece: one long
    /// sentence read straight through is right, and the same sentence with a
    /// gap dropped into the middle of it is not.
    ///
    /// Past it, a sentence has to break — and that ceiling belongs to the mel
    /// decoder, which is exported at **one fixed window of 768 speech tokens**.
    /// A chunk that generates more than that is decoded in two passes, each
    /// with its own noise, and the two waveforms are joined at an arbitrary
    /// phase: an audible click in the middle of a word. `ChatterboxEngine`
    /// fades that seam now, but the fade is damage control — the fix is for
    /// chunks to fit in one window in the first place.
    ///
    /// Working backwards: 768 tokens less the three the decoder pads with is
    /// 765, at 25 Hz that is 30.6 seconds, and an unhurried narrator reads
    /// about 12 characters a second. Hence roughly 360, and a 300-character
    /// target to fill up to. (A chunk this size also stays well inside
    /// `SamplingOptions.maxTokens`, so it cannot be silently truncated either.)
    static func ceiling(for max: Int) -> Int { (max * 6) / 5 }

    /// The ceiling at the default size: 360 characters, which fits the mel
    /// decoder's single window even when read slowly.
    public static var hardMaxChars: Int { ceiling(for: defaultMaxChars) }

    /// Bumped whenever a change here would move chunk boundaries.
    ///
    /// Chunk boundaries are file boundaries: `audio/<book>/<chapter>/00007.wav`
    /// only means anything next to the chunking that produced it. Two devices
    /// can hand each other rendered audio exactly as long as they agree on
    /// where the chunks start, so the number that says whether they agree
    /// travels with the chapter.
    ///
    /// v2: chunks never end in the middle of a sentence. v1 broke any sentence
    /// over 260 characters at a word boundary, which put a quarter-second of
    /// silence into the middle of it.
    ///
    /// v3: sized to the mel decoder's single 768-token window. v2 allowed 480
    /// characters, which for a slow voice needs two windows, and the join
    /// between two independently decoded windows clicks.
    public static let version = 3

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

    /// Break a sentence at its internal punctuation, keeping the mark with the
    /// clause it closes.
    ///
    /// Only reached for a sentence too long to say in one breath. A semicolon
    /// or a comma is somewhere the reader was going to pause anyway, so a chunk
    /// boundary there is nearly inaudible — where the same boundary two words
    /// later is the thing that sounds broken.
    static func clauses(in sentence: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in sentence {
            current.append(character)
            if ";:,—–".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out.isEmpty ? [sentence] : out
    }

    /// Split a sentence that is too long to be spoken in one go.
    ///
    /// Clause boundaries first, word boundaries only for a clause that has no
    /// punctuation to break on at all.
    static func splitSentence(_ sentence: String, max: Int) -> [String] {
        var out: [String] = []
        var current = ""

        for clause in clauses(in: sentence) {
            if clause.count > max {
                if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                out.append(contentsOf: splitLong(clause, max: max))
                continue
            }
            if !current.isEmpty, current.count + clause.count + 1 > max {
                out.append(current)
                current = clause
            } else {
                current = current.isEmpty ? clause : "\(current) \(clause)"
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
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

    /// Break chapter text into speakable pieces.
    ///
    /// The rule this is built around: **a chunk never ends in the middle of a
    /// sentence.** Boundaries land at paragraph ends where a paragraph fits,
    /// and at sentence ends otherwise. Only a sentence longer than
    /// `hardMaxChars` — which the model could not say in one go regardless — is
    /// broken, and then at its own punctuation.
    ///
    /// Whole paragraphs are packed together up to `max` rather than each
    /// becoming its own chunk. That is a deliberate cost: a chunk is padded to
    /// the mel decoder's fixed 768-token window whatever its length, so a
    /// one-line paragraph costs the same to synthesise as a full one, and a
    /// dialogue-heavy chapter split per paragraph would take several times
    /// longer to render for no audible gain.
    public static func chunk(_ text: String, max: Int = defaultMaxChars) -> [String] {
        var chunks: [String] = []
        var current = ""
        // Derived from `max` rather than a constant, so a caller that asks for
        // small chunks gets small chunks.
        let ceiling = ceiling(for: max)

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        /// Add something that must not be broken, starting a new chunk when it
        /// will not fit in the one being filled.
        func append(_ piece: String) {
            if !current.isEmpty, current.count + piece.count + 1 > max { flush() }
            current = current.isEmpty ? piece : "\(current) \(piece)"
        }

        for paragraph in text.splitParagraphs() {
            let clean = flatten(paragraph)
            if clean.isEmpty { continue }

            // The whole paragraph in one piece, which is the good case.
            if clean.count <= max {
                append(clean)
                continue
            }

            for sentence in sentences(in: clean) {
                if sentence.count <= ceiling {
                    // Overshoots `max` when the sentence is between the target
                    // and the ceiling, and that is the point: one long sentence
                    // read straight through beats the same sentence with a
                    // quarter-second of silence dropped into it.
                    append(sentence)
                } else {
                    flush()
                    for piece in splitSentence(sentence, max: ceiling) { append(piece) }
                    flush()
                }
            }
            // A paragraph that had to be split ends its chunk, so the next
            // paragraph starts cleanly rather than trailing off the last
            // sentence of this one.
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
