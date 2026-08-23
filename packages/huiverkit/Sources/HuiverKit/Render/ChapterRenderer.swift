import Foundation

/// Render a chapter chunk by chunk, writing each one out as it lands.
///
/// The per-chunk files are the whole resume story. A render interrupted
/// anywhere — the app was killed, the phone got hot, you pressed stop — leaves
/// a prefix of numbered WAVs behind, and starting again picks up at the first
/// one missing. A prefix is reused whenever the boundaries still hold: same
/// text, same chunking. A different *voice* continues rather than discards —
/// the listener keeps what they have already heard and the new narrator takes
/// over at the first missing chunk, with `ChunkManifest.chunkVoices` recording
/// who read what. Trimming back to the listening position, when a voice change
/// should take over mid-chapter, is the caller's move (`Narrator.play`).
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

    /// Silence appended after a chunk: a quarter-second between sentences, the
    /// same gap the desktop worker inserted, so they do not run into each
    /// other. A chunk that ends mid-sentence — one long enough that the
    /// chunker had to break inside it — gets a breath instead: a
    /// quarter-second hole in the middle of a sentence is exactly the artifact
    /// the chunker exists to avoid.
    static func pauseSamples(endsMidSentence: Bool) -> Int {
        endsMidSentence ? WavFile.sampleRate * 6 / 100 : WavFile.sampleRate / 4
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
                    // stretch of the chapter and skip another. The check has
                    // to live here, where every render path passes. Audio in
                    // a different voice, though, *is* continued: a listener
                    // who changes narrator mid-chapter keeps what they have
                    // already heard, and the new voice takes over at the next
                    // missing chunk — who read what is written down below.
                    var existing = ChunkManifest.read(from: directory)
                    if let stored = existing, stored.chunkerVersion != Chunker.version {
                        try await library.discardAudio(chapterId: chapter.id, bookId: book.id)
                        existing = nil
                    }

                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    // What each file says, written down beside the files. The
                    // chunker is deterministic, so this could be recomputed —
                    // but only by a build that chunks the same way, and read-
                    // along would then silently highlight the wrong sentence
                    // for every chapter rendered before a chunker change.
                    //
                    // Also *who* says it: chunks already on disk keep whoever
                    // read them, everything still to render is this voice.
                    let onDisk = rendered(book: book.id, chapter: chapter.id, of: chunks.count).count
                    var chunkVoices = (0..<min(onDisk, chunks.count)).map {
                        existing?.voice(forChunk: $0) ?? voice.id
                    }
                    chunkVoices += Array(
                        repeating: voice.id, count: max(0, chunks.count - chunkVoices.count)
                    )
                    ChunkManifest(
                        voice: voice.id, texts: chunks.map(\.text), chunkVoices: chunkVoices
                    ).write(to: directory)

                    // The mel decode runs off the engine actor, so chunk N's
                    // audio is decoded *while* chunk N+1's token loop holds
                    // the actor — the two halves of a chunk's cost used to run
                    // in series, and this is what stops that. One decode in
                    // flight at a time; its tokens are always complete, so
                    // whatever it produces is a whole chunk worth keeping.
                    let stack = await engine.s3Stack()
                    var inFlight: (
                        index: Int, url: URL, endsMidSentence: Bool,
                        decode: Task<[Float], Error>
                    )?
                    // What synthesis actually costs on this device, measured
                    // chunk over chunk and blended into `RenderPace` — the
                    // number every "how long will this take" answer rests on.
                    var lastFinish = ContinuousClock.now

                    // Write the decoded chunk, report it, and note the
                    // progress on the chapter — everything the serial loop did
                    // after `speak` returned.
                    func finish(
                        _ work: (
                            index: Int, url: URL, endsMidSentence: Bool,
                            decode: Task<[Float], Error>
                        )
                    ) async throws {
                        let samples = try await work.decode.value
                        let pause = Self.pauseSamples(endsMidSentence: work.endsMidSentence)
                        let padded = samples + [Float](repeating: 0, count: pause)
                        try WavFile.data(from: padded).write(to: work.url, options: .atomic)
                        let now = ContinuousClock.now
                        let spent = lastFinish.duration(to: now)
                        lastFinish = now
                        RenderPace.record(
                            spent: Double(spent.components.seconds)
                                + Double(spent.components.attoseconds) / 1e18,
                            audioSeconds: Double(samples.count) / Double(WavFile.sampleRate)
                        )
                        continuation.yield(
                            Progress(
                                chunkIndex: work.index,
                                chunkCount: chunks.count,
                                url: work.url,
                                seconds: WavFile.duration(ofFileAt: work.url) ?? 0
                            )
                        )
                        var updated = chapter
                        updated.chunkCount = chunks.count
                        updated.renderedChunks = work.index + 1
                        updated.renderedVoice = voice.id
                        try? await library.update(chapter: updated, in: book.id)
                    }

                    do {
                        for (index, chunk) in chunks.enumerated() {
                            if cancelled() { break }
                            let url = library.chunkURL(
                                book: book.id, chapter: chapter.id, index: index
                            )

                            if FileManager.default.fileExists(atPath: url.path) {
                                // Already on disk. The decode in flight is the
                                // chunk before this one, so it reports first.
                                if let work = inFlight {
                                    inFlight = nil
                                    try await finish(work)
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
                                continue
                            }

                            let tokens = try await engine.speakTokens(
                                chunk.text,
                                voice: voice,
                                options: options,
                                // The book's own language, which is what the
                                // multilingual model needs and Nano ignores.
                                // Stored per book rather than as a setting, so
                                // a Dutch novel among twenty English ones needs
                                // nothing changed before and after.
                                language: .named(book.languageCode),
                                beginsMidSentence: chunk.beginsMidSentence,
                                endsMidSentence: chunk.endsMidSentence,
                                cancelled: cancelled
                            )
                            if cancelled() { break }
                            // Not handed `cancelled`: the tokens are complete,
                            // so letting the decode finish yields a whole
                            // chunk on disk — a truncated one would be frozen
                            // forever by the resume check above.
                            let decode = Task.detached {
                                try stack.render(tokens, voice: voice)
                            }
                            if let work = inFlight {
                                inFlight = nil
                                try await finish(work)
                            }
                            inFlight = (index, url, chunk.endsMidSentence, decode)
                        }
                        if let work = inFlight {
                            inFlight = nil
                            try await finish(work)
                        }
                        continuation.finish()
                    } catch {
                        // The chunk already decoded is progress worth keeping
                        // even when the one after it failed.
                        if let work = inFlight { try? await finish(work) }
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
