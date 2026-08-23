import Foundation
import Testing

@testable import HuiverKit

/// What read-along draws: which sentence is being spoken, and when.
struct ChunkMapTests {
    func makeMap(_ durations: [Double]) -> ChunkMap {
        var start = 0.0
        var chunks: [ChunkMap.Chunk] = []
        for (index, duration) in durations.enumerated() {
            chunks.append(
                ChunkMap.Chunk(
                    index: index, text: "Chunk \(index).", start: start, duration: duration
                )
            )
            start += duration
        }
        return ChunkMap(chunks: chunks)
    }

    @Test("the chunk being spoken is the one whose span contains the position")
    func findsTheCurrentChunk() {
        let map = makeMap([10, 10, 10])
        #expect(map.index(at: 0) == 0)
        #expect(map.index(at: 9.9) == 0)
        #expect(map.index(at: 10) == 1)
        #expect(map.index(at: 25) == 2)
    }

    /// Past the end of the last chunk the highlight stays on it rather than
    /// disappearing — the chapter is finishing, not empty.
    @Test("a position past the end stays on the last chunk")
    func clampsPastTheEnd() {
        let map = makeMap([10, 10])
        #expect(map.index(at: 500) == 1)
    }

    @Test("a position before the start is the first chunk")
    func clampsBeforeTheStart() {
        #expect(makeMap([10]).index(at: -5) == 0)
    }

    @Test("an empty map has nothing to highlight")
    func emptyMap() {
        #expect(ChunkMap(chunks: []).index(at: 12) == nil)
    }

    /// The quarter-second of silence the renderer pads with belongs to the
    /// chunk before it. Moving the highlight on during the gap would have it
    /// flicker ahead at every sentence.
    @Test("the padding between chunks belongs to the chunk before it")
    func paddingBelongsToThePrecedingChunk() {
        // Two seconds of speech plus a quarter-second of padding each.
        let map = makeMap([2.25, 2.25])
        #expect(map.index(at: 2.1) == 0, "still in the first chunk's padding")
        #expect(map.index(at: 2.25) == 1)
    }

    /// When playback catches the render edge, every unrendered chunk shares
    /// that edge as its start. The highlight must stay on the last *rendered*
    /// chunk — it used to snap to the last sentence of the chapter.
    @Test("the highlight never runs ahead of the rendered edge")
    func staysAtTheRenderedEdge() {
        let map = makeMap([10, 10, 0, 0, 0])
        #expect(map.index(at: 20) == 1, "at the edge, the last rendered chunk holds")
        #expect(map.index(at: 500) == 1)
        // A chapter with nothing rendered highlights its opening sentence.
        #expect(makeMap([0, 0, 0]).index(at: 0) == 0)
    }

    // MARK: - Loading from disk

    func makeLibraryBook() async throws -> (Library, Book) {
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let text = (0..<8)
            .map { "Sentence number \($0) in a paragraph that runs on for a while." }
            .joined(separator: " ")
        let book = try await library.add(
            ExtractedBook(
                title: "A Book", author: nil, chapters: [ExtractedChapter(title: "One", text: text)]
            ),
            language: .english
        )
        return (library, book)
    }

    @Test("a manifest round-trips")
    func manifestRoundTrip() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = ChunkManifest(voice: "ruth", texts: ["One.", "Two."])
        manifest.write(to: directory)
        #expect(ChunkManifest.read(from: directory) == manifest)
    }

    @Test("a missing manifest reads as nothing rather than throwing")
    func missingManifest() {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ChunkManifest.read(from: directory) == nil)
    }

    /// The pin. Chunking is deterministic today — the library and the renderer
    /// call the same function — and this is what will fail if that stops being
    /// true, rather than read-along silently highlighting the wrong sentence.
    @Test("a stored manifest matches what re-chunking would produce")
    func storedManifestMatchesTheChunker() async throws {
        let (library, book) = try await makeLibraryBook()
        let chapter = book.chapters[0]
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let texts = Chunker.chunkWithSentenceLead(chapter.text)
        ChunkManifest(voice: "ruth", texts: texts).write(to: directory)

        let map = ChunkMap.load(book: book, chapter: chapter, library: library)
        #expect(map.chunks.map(\.text) == texts)
        #expect(map.chunks.count == chapter.chunkCount, "and matches the count the library stored")
    }

    /// A chapter rendered before manifests existed still has to work.
    @Test("a chapter with no manifest falls back to re-chunking")
    func fallsBackToRechunking() async throws {
        let (library, book) = try await makeLibraryBook()
        let chapter = book.chapters[0]

        let map = ChunkMap.load(book: book, chapter: chapter, library: library)
        #expect(map.chunks.map(\.text) == Chunker.chunkWithSentenceLead(chapter.text))
    }

    /// Nothing rendered yet: every chunk is there to read, none is seekable,
    /// and they do not claim times they do not have.
    @Test("unrendered chunks have no duration")
    func unrenderedChunksHaveNoTime() async throws {
        let (library, book) = try await makeLibraryBook()
        let map = ChunkMap.load(book: book, chapter: book.chapters[0], library: library)

        #expect(!map.isEmpty)
        #expect(map.chunks.allSatisfy { !$0.isRendered })
        #expect(map.chunks.allSatisfy { $0.start == 0 })
    }

    /// Times come from the WAV headers, so the highlight cannot drift over a
    /// long chapter the way an estimate would.
    @Test("start times are measured from the rendered files")
    func startsComeFromTheFiles() async throws {
        let (library, book) = try await makeLibraryBook()
        let chapter = book.chapters[0]
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Two chunks of exactly one and two seconds.
        for (index, seconds) in [1.0, 2.0].enumerated() {
            let samples = [Float](repeating: 0, count: Int(Double(WavFile.sampleRate) * seconds))
            try WavFile.data(from: samples).write(
                to: library.chunkURL(book: book.id, chapter: chapter.id, index: index)
            )
        }

        let map = ChunkMap.load(book: book, chapter: chapter, library: library)
        #expect(abs(map.chunks[0].duration - 1.0) < 0.01)
        #expect(abs(map.chunks[1].start - 1.0) < 0.01)
        #expect(abs(map.chunks[2].start - 3.0) < 0.01, "the third begins after the first two")
    }

    // MARK: - Who reads what

    /// A manifest written before per-chunk voices existed answers with its one
    /// voice for every chunk; a newer one answers per chunk, and past the end
    /// of its record falls back to the latest pass's voice.
    @Test("the per-chunk voice falls back to the manifest voice")
    func perChunkVoiceFallback() {
        let legacy = ChunkManifest(voice: "ruth", texts: ["One.", "Two."])
        #expect(legacy.voice(forChunk: 0) == "ruth")
        #expect(legacy.voice(forChunk: 1) == "ruth")

        let mixed = ChunkManifest(
            voice: "peter", texts: ["One.", "Two.", "Three."], chunkVoices: ["ruth", "peter"]
        )
        #expect(mixed.voice(forChunk: 0) == "ruth")
        #expect(mixed.voice(forChunk: 1) == "peter")
        #expect(mixed.voice(forChunk: 2) == "peter", "past the record is the latest voice")
    }

    /// Write two chunks by one voice and one by another, and the spans say who
    /// reads what, where, and for how long.
    @Test("voice spans fold consecutive chunks by the same reader")
    func voiceSpansFromDisk() async throws {
        let (library, book) = try await makeLibraryBook()
        let chapter = book.chapters[0]
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, seconds) in [1.0, 2.0, 1.0].enumerated() {
            let samples = [Float](repeating: 0, count: Int(Double(WavFile.sampleRate) * seconds))
            try WavFile.data(from: samples).write(
                to: library.chunkURL(book: book.id, chapter: chapter.id, index: index)
            )
        }
        ChunkManifest(
            voice: "peter",
            texts: ["One.", "Two.", "Three.", "Four."],
            chunkVoices: ["ruth", "ruth", "peter", "peter"]
        ).write(to: directory)

        let spans = ChunkMap.voiceSpans(book: book, chapter: chapter, library: library)
        #expect(spans.map(\.voiceId) == ["ruth", "peter"])
        #expect(abs(spans[0].start) < 0.01)
        #expect(abs(spans[0].duration - 3.0) < 0.01)
        #expect(abs(spans[1].start - 3.0) < 0.01, "the second voice drops in after the first")
        #expect(abs(spans[1].duration - 1.0) < 0.01, "and only the rendered chunk counts")
    }

    /// A chapter rendered before per-chunk voices is one span, in the voice
    /// the chapter says read it.
    @Test("a legacy chapter reports a single span")
    func legacySingleSpan() async throws {
        let (library, book) = try await makeLibraryBook()
        var chapter = book.chapters[0]
        chapter.renderedVoice = "ruth"
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let samples = [Float](repeating: 0, count: WavFile.sampleRate)
        try WavFile.data(from: samples).write(
            to: library.chunkURL(book: book.id, chapter: chapter.id, index: 0)
        )

        let spans = ChunkMap.voiceSpans(book: book, chapter: chapter, library: library)
        #expect(spans.map(\.voiceId) == ["ruth"])
    }
}
