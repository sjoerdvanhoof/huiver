import Foundation

/// The text each rendered chunk says, stored beside the audio.
///
/// Written once when a render starts. Chunking is deterministic today — the
/// library and the renderer call the same function on the same text — so this
/// is recoverable without it. But "today" is the operative word: the moment the
/// chunker changes, every chapter rendered before it would highlight the wrong
/// sentence, and nothing would say so. Pinning the texts at render time makes
/// that impossible rather than unlikely.
public struct ChunkManifest: Codable, Sendable, Equatable {
    public static let filename = "chunks.json"
    public static let currentVersion = 1

    public var version: Int
    /// The voice these chunks were rendered in. A manifest whose voice does not
    /// match the audio's belongs to a previous render.
    public var voice: String
    public var texts: [String]

    public init(version: Int = ChunkManifest.currentVersion, voice: String, texts: [String]) {
        self.version = version
        self.voice = voice
        self.texts = texts
    }

    public func write(to directory: URL) {
        // Losing this costs a highlight, not a chapter, so a failed write is
        // not worth failing the render over.
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    public static func read(from directory: URL) -> ChunkManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let manifest = try? JSONDecoder().decode(ChunkManifest.self, from: data),
              manifest.version == currentVersion
        else { return nil }
        return manifest
    }
}

/// Chunk texts joined to the times they are spoken at.
///
/// This is what read-along draws: a list of sentences, each with a start time,
/// so the one being spoken can be highlighted and any of them can be tapped to
/// seek there. Durations come from the WAV headers rather than being estimated,
/// so the highlight does not drift over a long chapter.
public struct ChunkMap: Sendable, Equatable {
    public struct Chunk: Sendable, Equatable, Identifiable {
        public let index: Int
        public let text: String
        /// Where this chunk starts, in chapter seconds.
        public let start: Double
        /// Its length, including the quarter-second of silence the renderer
        /// pads with. Zero for a chunk that has not been rendered yet.
        public let duration: Double

        public var id: Int { index }
        public var isRendered: Bool { duration > 0 }
    }

    public var chunks: [Chunk]

    public init(chunks: [Chunk]) {
        self.chunks = chunks
    }

    public var isEmpty: Bool { chunks.isEmpty }

    /// Which chunk is being spoken at this moment in the chapter.
    ///
    /// The padding between chunks belongs to the chunk before it: during that
    /// quarter-second nothing is being said, and moving the highlight on early
    /// would make it flicker ahead at every sentence.
    public func index(at position: Double) -> Int? {
        guard !chunks.isEmpty else { return nil }
        guard position >= 0 else { return chunks.first?.index }

        var best: Int?
        // Linear rather than binary: a chapter is a couple of hundred chunks
        // and this runs four times a second. Binary search here would be
        // cleverness with nothing to buy.
        for chunk in chunks where chunk.start <= position {
            best = chunk.index
        }
        return best ?? chunks.first?.index
    }

    /// Build the map for a chapter from what is on disk.
    ///
    /// Falls back to re-chunking for a chapter rendered before manifests were
    /// written, which is the only case where the texts have to be trusted to
    /// still match.
    public static func load(book: Book, chapter: Chapter, library: Library) -> ChunkMap {
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        let stored = ChunkManifest.read(from: directory)

        let texts: [String]
        if let stored, stored.voice == (chapter.renderedVoice ?? stored.voice) {
            texts = stored.texts
        } else {
            texts = Chunker.chunkWithSentenceLead(chapter.text)
        }

        var chunks: [Chunk] = []
        var elapsed = 0.0
        for (index, text) in texts.enumerated() {
            let url = library.chunkURL(book: book.id, chapter: chapter.id, index: index)
            let duration = WavFile.duration(ofFileAt: url) ?? 0
            chunks.append(Chunk(index: index, text: text, start: elapsed, duration: duration))
            // An unrendered chunk contributes nothing, so everything after it
            // piles up at the rendered edge — which is exactly where the player
            // would refuse to seek anyway.
            elapsed += duration
        }
        return ChunkMap(chunks: chunks)
    }
}
