import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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
    public static let currentVersion = 2

    public var version: Int
    /// The voice of the most recent render pass — the one reading anything
    /// that still has to be rendered. Chunks already on disk may have been
    /// read by someone else; see `chunkVoices`.
    public var voice: String
    /// Which `Chunker` decided these boundaries. Absent in manifests written
    /// before the chunker was versioned, which by definition means v1.
    public var chunker: Int?
    public var texts: [String]
    /// The model-facing text actually used for each rendered chunk. Nil entries
    /// are unrendered and will use the processor active when they are made.
    public var spokenTexts: [String?]?
    public var processorFingerprints: [String?]?
    public var chunkingProfile: String?
    public var beginsMidSentence: [Bool]?
    public var endsMidSentence: [Bool]?
    /// Who reads each chunk, one entry per chunk. A chapter used to have one
    /// narrator by construction — changing voice discarded the audio — but a
    /// voice change mid-listen now keeps what was already heard, so a chapter
    /// can be read by more than one voice and this is the record of who says
    /// what. Absent in older manifests, where `voice` covers every chunk.
    public var chunkVoices: [String]?

    /// The chunker that produced this, treating a manifest too old to say as
    /// the only version that existed when it was written.
    public var chunkerVersion: Int { chunker ?? 1 }

    /// Which voice reads this chunk.
    public func voice(forChunk index: Int) -> String {
        guard let chunkVoices, chunkVoices.indices.contains(index) else { return voice }
        return chunkVoices[index]
    }

    public init(
        version: Int = ChunkManifest.currentVersion,
        voice: String,
        chunker: Int? = Chunker.version,
        texts: [String],
        chunkVoices: [String]? = nil,
        spokenTexts: [String?]? = nil,
        processorFingerprints: [String?]? = nil,
        chunkingProfile: String? = nil,
        beginsMidSentence: [Bool]? = nil,
        endsMidSentence: [Bool]? = nil
    ) {
        self.version = version
        self.voice = voice
        self.chunker = chunker
        self.texts = texts
        self.chunkVoices = chunkVoices
        self.spokenTexts = spokenTexts
        self.processorFingerprints = processorFingerprints
        self.chunkingProfile = chunkingProfile
        self.beginsMidSentence = beginsMidSentence
        self.endsMidSentence = endsMidSentence
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
              (1...currentVersion).contains(manifest.version)
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
            // Only rendered chunks can be *at* a position. The unrendered tail
            // all shares the rendered edge as its start, and letting it win
            // snapped the highlight to the last sentence of the chapter every
            // time playback caught up with synthesis.
            guard chunk.isRendered else { break }
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

    /// One narrator's continuous stretch of a chapter, for the rows that say
    /// who reads what and where each voice drops in.
    public struct VoiceSpan: Sendable, Equatable, Identifiable {
        public let voiceId: String
        /// Where this narrator starts, in chapter seconds.
        public let start: Double
        /// How much they read, in rendered seconds.
        public var duration: Double

        public var id: Double { start }
    }

    /// Who reads this chapter, in order, from the audio actually on disk.
    ///
    /// Walks the rendered prefix — the same contiguous-files rule everything
    /// else follows — and folds consecutive chunks by the same voice into one
    /// span. A chapter rendered before per-chunk voices were written down
    /// reports a single span in the manifest's voice.
    public static func voiceSpans(
        book: Book, chapter: Chapter, library: Library
    ) -> [VoiceSpan] {
        let directory = library.audioDirectory(book: book.id, chapter: chapter.id)
        let manifest = ChunkManifest.read(from: directory)

        var spans: [VoiceSpan] = []
        var elapsed = 0.0
        var index = 0
        while true {
            let url = library.chunkURL(book: book.id, chapter: chapter.id, index: index)
            guard let duration = WavFile.duration(ofFileAt: url) else { break }
            let voice = manifest?.voice(forChunk: index) ?? chapter.renderedVoice ?? ""
            if !spans.isEmpty, spans[spans.count - 1].voiceId == voice {
                spans[spans.count - 1].duration += duration
            } else {
                spans.append(VoiceSpan(voiceId: voice, start: elapsed, duration: duration))
            }
            elapsed += duration
            index += 1
        }
        return spans
    }
}
