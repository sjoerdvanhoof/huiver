import Foundation

/// Render a chapter chunk by chunk, writing each one out as it lands.
///
/// The per-chunk files are the whole resume story. A render interrupted
/// anywhere — the app was killed, the phone got hot, you pressed stop — leaves
/// a prefix of numbered WAVs behind, and starting again picks up at the first
/// one missing. As on the desktop, a prefix is only reused when the work is
/// identical: same text, same voice, same chunking. Change the voice and the
/// audio is discarded rather than continued, because half a chapter in one
/// voice and half in another is worse than re-rendering.
public actor ChapterRenderer {
    public struct Progress: Sendable {
        public let chunkIndex: Int
        public let chunkCount: Int
        public let url: URL
        public let seconds: Double
    }

    private let engine: ChatterboxEngine
    private let library: Library

    public init(engine: ChatterboxEngine, library: Library) {
        self.engine = engine
        self.library = library
    }

    /// Chunks already on disk, in order, stopping at the first gap.
    public nonisolated func rendered(book: String, chapter: String, of count: Int) -> [URL] {
        var found: [URL] = []
        for index in 0..<count {
            let url = library.chunkURL(book: book, chapter: chapter, index: index)
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            found.append(url)
        }
        return found
    }

    /// Render everything not already there, reporting each chunk as it is
    /// written. The stream finishes when the chapter is done or `cancelled`
    /// goes true; a thrown error ends it too.
    public func render(
        book: Book,
        chapter: Chapter,
        voice: Voice,
        options: SamplingOptions = SamplingOptions(),
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let chunks = Chunker.chunksWithSentenceLead(chapter.text)
                    let directory = library.audioDirectory(book: book.id, chapter: chapter.id)

                    // Audio left over from a different chunker cannot be
                    // continued: `00007.wav` says something else under the new
                    // boundaries, so carrying on from it would repeat one
                    // stretch of the chapter and skip another. Audio in a
                    // different voice cannot be continued either — half a
                    // chapter each from two narrators is worse than
                    // re-rendering — and the check has to live here, where
                    // every render path passes: `Narrator.play` compared
                    // voices itself, but the converter queue did not.
                    if let existing = ChunkManifest.read(from: directory),
                       existing.chunkerVersion != Chunker.version || existing.voice != voice.id {
                        try await library.discardAudio(chapterId: chapter.id, bookId: book.id)
                    }

                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    // What each file says, written down beside the files. The
                    // chunker is deterministic, so this could be recomputed —
                    // but only by a build that chunks the same way, and read-
                    // along would then silently highlight the wrong sentence
                    // for every chapter rendered before a chunker change.
                    ChunkManifest(voice: voice.id, texts: chunks.map(\.text)).write(to: directory)

                    for (index, chunk) in chunks.enumerated() {
                        if cancelled() { break }
                        let url = library.chunkURL(book: book.id, chapter: chapter.id, index: index)

                        if !FileManager.default.fileExists(atPath: url.path) {
                            let samples = try await engine.speak(
                                chunk.text,
                                voice: voice,
                                options: options,
                                beginsMidSentence: chunk.beginsMidSentence,
                                endsMidSentence: chunk.endsMidSentence,
                                cancelled: cancelled
                            )
                            if cancelled() { break }
                            // A quarter-second of silence between chunks, the
                            // same gap the desktop worker inserts, so sentences
                            // do not run into each other.
                            let padded = samples + [Float](
                                repeating: 0, count: WavFile.sampleRate / 4
                            )
                            try WavFile.data(from: padded).write(to: url, options: .atomic)
                        }

                        continuation.yield(
                            Progress(
                                chunkIndex: index,
                                chunkCount: chunks.count,
                                url: url,
                                seconds: WavFile.duration(ofFileAt: url) ?? 0
                            )
                        )

                        var updated = chapter
                        updated.chunkCount = chunks.count
                        updated.renderedChunks = index + 1
                        updated.renderedVoice = voice.id
                        try? await library.update(chapter: updated, in: book.id)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
