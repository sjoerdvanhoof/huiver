import Foundation
import Testing

@testable import HuiverKit

/// The renderer's small pure rules, and the library's import guard — the
/// pieces added by the top-notch pass that have no model or file dependency.
struct RendererRulesTests {
    @Test("a chunk that ends mid-sentence gets a breath, not a paragraph pause")
    func pauseRespectsMidSentence() {
        let sentence = ChapterRenderer.pauseSamples(endsMidSentence: false)
        let midSentence = ChapterRenderer.pauseSamples(endsMidSentence: true)
        #expect(sentence == WavFile.sampleRate / 4)
        #expect(midSentence < sentence)
        // Still a real pause, not an abrupt join.
        #expect(midSentence > 0)
    }

    @Test("the emergency split prefers a sentence boundary near the middle")
    func splitPrefersSentences() throws {
        let text = "The first sentence is here. The second one follows it. "
            + "The third closes the set."
        let (head, tail) = try #require(ChatterboxEngine.splitNearMiddle(text))
        // Both halves are whole sentences — no half words, no dangling clause.
        #expect(head.hasSuffix("."))
        #expect(tail.hasSuffix("."))
        #expect(head.contains("first"))
        #expect(tail.contains("closes"))
    }

    @Test("a single sentence splits at its clause punctuation")
    func splitFallsBackToClauses() throws {
        let text = "One long sweep of prose, with a comma in the middle, and no full stop until the very end."
        let (head, tail) = try #require(ChatterboxEngine.splitNearMiddle(text))
        #expect(head.hasSuffix(","))
        #expect(!tail.isEmpty)
    }

    @Test("punctuationless text still splits, at whitespace")
    func splitFallsBackToWords() throws {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let (head, tail) = try #require(ChatterboxEngine.splitNearMiddle(text))
        #expect(!head.isEmpty)
        #expect(!tail.isEmpty)
        #expect(head.split(separator: " ").allSatisfy { $0 == "word" })
        #expect(tail.split(separator: " ").allSatisfy { $0 == "word" })
    }

    @Test("one unbreakable word is left for the engine to refuse")
    func splitGivesUpOnOneWord() {
        #expect(ChatterboxEngine.splitNearMiddle("supercalifragilistic") == nil)
    }

    @Test("importing the same book twice is refused by content identity")
    func duplicateImportRefused() async throws {
        let extracted = ExtractedBook(
            title: "Twice",
            author: "A. Writer",
            chapters: [ExtractedChapter(title: "One", text: "The town woke slowly.")]
        )
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        _ = try await library.add(extracted, language: .english)
        await #expect(throws: Library.AlreadyImported.self) {
            _ = try await library.add(extracted, language: .english)
        }
        #expect(await library.all().count == 1)
    }

    @Test("a different book is still welcome after a refusal")
    func differentBookStillImports() async throws {
        let first = ExtractedBook(
            title: "First", author: nil,
            chapters: [ExtractedChapter(title: "One", text: "Rain fell.")]
        )
        let second = ExtractedBook(
            title: "Second", author: nil,
            chapters: [ExtractedChapter(title: "One", text: "Snow fell.")]
        )
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        _ = try await library.add(first, language: .english)
        _ = try await library.add(second, language: .english)
        #expect(await library.all().count == 2)
    }
}
