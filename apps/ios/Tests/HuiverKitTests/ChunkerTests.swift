import Foundation
import Testing

@testable import HuiverKit

/// The chunker decides where a chapter pauses, so it has to agree with
/// `packages/shared/src/chunk.ts`. These cases are the same ones that file's
/// tests use, at the same limit.
struct ChunkerTests {
    @Test("keeps short text in one piece")
    func short() {
        #expect(Chunker.chunk("Hello there.", max: 420) == ["Hello there."])
    }

    @Test("collapses whitespace inside a paragraph")
    func whitespace() {
        #expect(Chunker.chunk("one\n  two\n\tthree", max: 420) == ["one two three"])
    }

    @Test("joins paragraphs up to the limit, then breaks")
    func paragraphs() {
        let a = String(repeating: "a", count: 200)
        let b = String(repeating: "b", count: 200)
        let c = String(repeating: "c", count: 200)
        let chunks = Chunker.chunk("\(a)\n\n\(b)\n\n\(c)", max: 420)
        #expect(chunks.count == 2)
        #expect(chunks[0] == "\(a) \(b)")
        #expect(chunks[1] == c)
    }

    @Test("breaks a long paragraph on sentence boundaries")
    func sentences() {
        let sentence = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces) + "."
        let chunks = Chunker.chunk("\(sentence) \(sentence) \(sentence)", max: 260)
        #expect(chunks.count >= 2)
        // Nothing overshoots, and nothing is lost.
        for chunk in chunks { #expect(chunk.count <= 260) }
        #expect(chunks.joined(separator: " ").filter { !$0.isWhitespace }.count
            == "\(sentence) \(sentence) \(sentence)".filter { !$0.isWhitespace }.count)
    }

    @Test("splits a word longer than the limit")
    func longWord() {
        let url = String(repeating: "x", count: 900)
        let chunks = Chunker.chunk(url, max: 260)
        #expect(chunks.count == 4)
        for chunk in chunks { #expect(chunk.count <= 260) }
        #expect(chunks.joined() == url)
    }

    @Test("keeps a closing quote with the sentence it ends")
    func closingQuotes() {
        // The quote goes with `"Stop!"`, not with what follows. Dialogue and
        // its attribution end up as separate pieces, which is what the web
        // chunker does too — worth pinning down, since it is the one place the
        // two could plausibly drift.
        let split = Chunker.sentences(in: "\"Stop!\" she said. Then nothing.")
        #expect(split == ["\"Stop!\"", "she said.", "Then nothing."])
    }

    @Test("leads with a single sentence for a fast first chunk")
    func sentenceLead() {
        let text = "First one. " + String(repeating: "more words here. ", count: 30)
        let chunks = Chunker.chunkWithSentenceLead(text, max: 260)
        #expect(chunks[0] == "First one.")
        #expect(chunks.count > 2)
    }

    @Test("drops empty input")
    func empty() {
        #expect(Chunker.chunk("   \n\n  ", max: 420).isEmpty)
    }
}
