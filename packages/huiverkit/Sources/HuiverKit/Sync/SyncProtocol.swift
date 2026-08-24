import Foundation

/// What the two devices say to each other.
///
/// The shape of a session is deliberately dull: say hello, both describe what
/// you have, both ask for what you lack, send it, say goodbye. There are no
/// version vectors and no operation log. One person owns both devices and
/// cannot listen on two at once, so the interesting distributed-systems
/// problems do not arise; inventing machinery for them would be inventing bugs.
///
/// Everything is recomputed from scratch each session. That is what makes an
/// interrupted transfer resumable without any resume logic: the manifests are
/// exchanged again, the diff comes out smaller, and whatever is still missing
/// is asked for again.
public enum SyncProtocol {
    /// Bumped when a change would confuse an older peer. `minimumVersion` is
    /// how far back this build can still talk.
    public static let version = 1
    public static let minimumVersion = 1

    /// The Bonjour service both apps advertise and look for.
    public static let serviceType = "_huiver._tcp"
}

// MARK: - Messages

public enum SyncMessage: Sendable, Equatable {
    case hello(Hello)
    case helloAck(Hello)
    case manifest(Manifest)
    case want(Want)
    case fileHeader(FileHeader)
    case fileDone(FileDone)
    case progressSet(ProgressSet)
    case jobStatus(JobStatus)
    case bye

    public struct Hello: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var minimumVersion: Int
        public var deviceId: String
        public var deviceName: String
        /// Each side's wall clock, compared once at the handshake. Progress is
        /// merged newest-wins, so two devices that disagree about the time
        /// resolve conflicts wrongly — worth warning about, not worth refusing
        /// to sync over.
        public var clock: Date
        public var appVersion: String
        /// How this device is willing to be sent audio.
        ///
        /// Optional, and absent means WAV only: a peer built before AAC
        /// existed says nothing here, and must not be sent something it cannot
        /// decode. This is what lets the codec change without a protocol
        /// version bump — the sender asks rather than assumes.
        public var audioCodecs: [AudioManifest.Codec]?

        public init(
            protocolVersion: Int = SyncProtocol.version,
            minimumVersion: Int = SyncProtocol.minimumVersion,
            deviceId: String,
            deviceName: String,
            clock: Date = Date(),
            appVersion: String,
            audioCodecs: [AudioManifest.Codec]? = [.wav, .aac]
        ) {
            self.protocolVersion = protocolVersion
            self.minimumVersion = minimumVersion
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.clock = clock
            self.appVersion = appVersion
            self.audioCodecs = audioCodecs
        }

        /// Whether this device would understand a file sent in this codec.
        public func accepts(_ codec: AudioManifest.Codec) -> Bool {
            guard let audioCodecs else { return codec == .wav }
            return audioCodecs.contains(codec)
        }

        /// Can these two talk at all?
        public func canTalk(to other: Hello) -> Bool {
            protocolVersion >= other.minimumVersion && other.protocolVersion >= minimumVersion
        }
    }

    /// Everything one device has, in a few tens of kilobytes of hashes.
    public struct Manifest: Codable, Sendable, Equatable {
        public var books: [BookManifest]
        public var voices: [VoiceManifest]
        public var progress: [ProgressRecord]
        public var convertRequests: [ConvertRequest]

        public init(
            books: [BookManifest] = [],
            voices: [VoiceManifest] = [],
            progress: [ProgressRecord] = [],
            convertRequests: [ConvertRequest] = []
        ) {
            self.books = books
            self.voices = voices
            self.progress = progress
            self.convertRequests = convertRequests
        }
    }

    public struct Want: Codable, Sendable, Equatable {
        public var items: [WantItem]
        public init(items: [WantItem]) { self.items = items }
    }

    /// A file is coming. The hash is checked on arrival before anything is
    /// moved into place, so a truncated or garbled transfer is discarded rather
    /// than stored as a chapter that plays static.
    public struct FileHeader: Codable, Sendable, Equatable {
        public var item: WantItem
        public var size: Int64
        public var sha256: String
        /// How the audio in this transfer is encoded, when it is audio and not
        /// WAV. The hash and the size are of what is on the wire, so it is
        /// checked before it is decoded.
        public var codec: AudioManifest.Codec?

        public init(
            item: WantItem, size: Int64, sha256: String, codec: AudioManifest.Codec? = nil
        ) {
            self.item = item
            self.size = size
            self.sha256 = sha256
            self.codec = codec
        }
    }

    public struct FileDone: Codable, Sendable, Equatable {
        public var item: WantItem
        public init(item: WantItem) { self.item = item }
    }

    public struct ProgressSet: Codable, Sendable, Equatable {
        public var records: [ProgressRecord]
        public init(records: [ProgressRecord]) { self.records = records }
    }

    public struct JobStatus: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case queued, rendering, done, failed
        }
        public var requestId: String
        public var state: State
        public var renderedChunks: Int
        public var chunkCount: Int

        public init(requestId: String, state: State, renderedChunks: Int, chunkCount: Int) {
            self.requestId = requestId
            self.state = state
            self.renderedChunks = renderedChunks
            self.chunkCount = chunkCount
        }
    }
}

// MARK: - Manifest contents

/// One book as the other device needs to understand it: what it is, and what
/// audio exists for it.
public struct BookManifest: Codable, Sendable, Equatable {
    public var contentId: String
    public var title: String
    public var author: String?
    public var language: String
    public var hasCover: Bool
    public var hasEpub: Bool
    public var chapters: [ChapterManifest]

    public init(
        contentId: String,
        title: String,
        author: String? = nil,
        language: String,
        hasCover: Bool = false,
        hasEpub: Bool = false,
        chapters: [ChapterManifest]
    ) {
        self.contentId = contentId
        self.title = title
        self.author = author
        self.language = language
        self.hasCover = hasCover
        self.hasEpub = hasEpub
        self.chapters = chapters
    }
}

public struct ChapterManifest: Codable, Sendable, Equatable {
    public var index: Int
    public var title: String
    public var textHash: String
    public var chunkCount: Int
    public var chunkerVersion: Int
    /// The audio that exists for this chapter, if any.
    public var audio: AudioManifest?

    public init(
        index: Int,
        title: String,
        textHash: String,
        chunkCount: Int,
        chunkerVersion: Int,
        audio: AudioManifest? = nil
    ) {
        self.index = index
        self.title = title
        self.textHash = textHash
        self.chunkCount = chunkCount
        self.chunkerVersion = chunkerVersion
        self.audio = audio
    }
}

public struct AudioManifest: Codable, Sendable, Equatable {
    public enum Codec: String, Codable, Sendable {
        /// What the phone renders: 24 kHz 16-bit mono, ~173 MB an hour.
        case wav
        /// What crosses the wire: 64 kbps mono AAC, about a sixth of that.
        case aac

        public var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .aac: return "m4a"
            }
        }
    }

    public var voiceId: String
    public var renderedChunks: Int
    public var codec: Codec
    /// The preferred renderer produced this audio. Optional for compatibility
    /// with builds from before Mac-authoritative syncing.
    public var preferred: Bool?

    public init(
        voiceId: String, renderedChunks: Int, codec: Codec, preferred: Bool? = nil
    ) {
        self.voiceId = voiceId
        self.renderedChunks = renderedChunks
        self.codec = codec
        self.preferred = preferred
    }
}

public struct VoiceManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var hasPreview: Bool

    public init(id: String, name: String, hasPreview: Bool) {
        self.id = id
        self.name = name
        self.hasPreview = hasPreview
    }
}

/// A listening position, addressed the way the other device can understand it:
/// by content id and chapter number rather than by a local uuid.
public struct ProgressRecord: Codable, Sendable, Equatable {
    public var contentId: String
    public var chapterIndex: Int
    public var position: Double
    public var finished: Bool
    public var updatedAt: Date
    /// Which device this reading came from. Only used to break a tie between
    /// two records with the same timestamp, so that both sides break it the
    /// same way and stop disagreeing.
    public var deviceId: String

    public init(
        contentId: String,
        chapterIndex: Int,
        position: Double,
        finished: Bool,
        updatedAt: Date,
        deviceId: String
    ) {
        self.contentId = contentId
        self.chapterIndex = chapterIndex
        self.position = position
        self.finished = finished
        self.updatedAt = updatedAt
        self.deviceId = deviceId
    }

    public var chapterProgress: ChapterProgress {
        ChapterProgress(position: position, finished: finished, updatedAt: updatedAt)
    }
}

/// "Please render this on the Mac." Idempotent by construction: the id is
/// derived from what is being asked for, so the same request sent in five
/// consecutive sessions is one job, not five.
public struct ConvertRequest: Codable, Sendable, Equatable, Identifiable {
    public var requestId: String
    public var contentId: String
    public var chapterIndex: Int
    public var voiceId: String
    public var requestedAt: Date

    public var id: String { requestId }

    public init(
        contentId: String,
        chapterIndex: Int,
        textHash: String,
        voiceId: String,
        requestedAt: Date = Date()
    ) {
        self.requestId = ContentIdentity.requestId(textHash: textHash, voiceId: voiceId)
        self.contentId = contentId
        self.chapterIndex = chapterIndex
        self.voiceId = voiceId
        self.requestedAt = requestedAt
    }
}

/// What one side is missing and would like sent.
public enum WantItem: Codable, Sendable, Equatable, Hashable {
    /// The book itself: metadata, chapter texts, cover.
    case bookBundle(contentId: String)
    /// The original EPUB, when the other side kept it.
    case epub(contentId: String)
    /// A run of rendered chunks for one chapter in one voice.
    case audio(contentId: String, chapterIndex: Int, voiceId: String, chunks: [Int])
    case voice(id: String)
    case voicePreview(id: String)

    /// A stable string for this item, used to name partial files on disk and to
    /// match a `FileDone` to the header that opened it.
    public var key: String {
        switch self {
        case .bookBundle(let contentId): return "book/\(contentId)"
        case .epub(let contentId): return "epub/\(contentId)"
        case .audio(let contentId, let index, let voiceId, let chunks):
            let range = chunks.isEmpty ? "none" : "\(chunks[0])-\(chunks[chunks.count - 1])"
            return "audio/\(contentId)/\(index)/\(voiceId)/\(range)"
        case .voice(let id): return "voice/\(id)"
        case .voicePreview(let id): return "preview/\(id)"
        }
    }
}
