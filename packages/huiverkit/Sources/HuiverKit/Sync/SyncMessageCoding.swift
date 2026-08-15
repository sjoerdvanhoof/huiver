import Foundation

/// How a `SyncMessage` becomes JSON and back.
///
/// Written out by hand rather than left to Swift's synthesised enum encoding.
/// That spelling — `{"hello":{"_0":{…}}}` — is a compiler implementation
/// detail, and this is a wire format two independently-updated apps have to
/// agree on for as long as both exist. A named `type` field is worth the
/// boilerplate.
extension SyncMessage: Codable {
    private enum Key: String, CodingKey {
        case type, body
    }

    private enum Kind: String, Codable {
        case hello, helloAck, manifest, want, fileHeader, fileDone
        case progressSet, jobStatus, bye
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .hello: self = .hello(try container.decode(Hello.self, forKey: .body))
        case .helloAck: self = .helloAck(try container.decode(Hello.self, forKey: .body))
        case .manifest: self = .manifest(try container.decode(Manifest.self, forKey: .body))
        case .want: self = .want(try container.decode(Want.self, forKey: .body))
        case .fileHeader: self = .fileHeader(try container.decode(FileHeader.self, forKey: .body))
        case .fileDone: self = .fileDone(try container.decode(FileDone.self, forKey: .body))
        case .progressSet: self = .progressSet(try container.decode(ProgressSet.self, forKey: .body))
        case .jobStatus: self = .jobStatus(try container.decode(JobStatus.self, forKey: .body))
        case .bye: self = .bye
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let body):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(body, forKey: .body)
        case .helloAck(let body):
            try container.encode(Kind.helloAck, forKey: .type)
            try container.encode(body, forKey: .body)
        case .manifest(let body):
            try container.encode(Kind.manifest, forKey: .type)
            try container.encode(body, forKey: .body)
        case .want(let body):
            try container.encode(Kind.want, forKey: .type)
            try container.encode(body, forKey: .body)
        case .fileHeader(let body):
            try container.encode(Kind.fileHeader, forKey: .type)
            try container.encode(body, forKey: .body)
        case .fileDone(let body):
            try container.encode(Kind.fileDone, forKey: .type)
            try container.encode(body, forKey: .body)
        case .progressSet(let body):
            try container.encode(Kind.progressSet, forKey: .type)
            try container.encode(body, forKey: .body)
        case .jobStatus(let body):
            try container.encode(Kind.jobStatus, forKey: .type)
            try container.encode(body, forKey: .body)
        case .bye:
            try container.encode(Kind.bye, forKey: .type)
        }
    }

    /// The JSON both sides use. ISO-8601 dates rather than Apple's default
    /// reference-date doubles, so the format stays legible in a log and does
    /// not quietly depend on a Foundation constant.
    static var coder: (encoder: JSONEncoder, decoder: JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    public func frame() throws -> Frame {
        Frame(kind: .control, payload: try Self.coder.encoder.encode(self))
    }

    public static func decode(_ frame: Frame) throws -> SyncMessage {
        try coder.decoder.decode(SyncMessage.self, from: frame.payload)
    }
}

/// `WantItem` gets the same treatment, for the same reason: it names files on
/// disk and appears inside two other messages.
extension WantItem {
    private enum Key: String, CodingKey {
        case kind, contentId, chapterIndex, voiceId, chunks, id
    }

    private enum Kind: String, Codable {
        case bookBundle, epub, audio, voice, voicePreview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .bookBundle:
            self = .bookBundle(contentId: try container.decode(String.self, forKey: .contentId))
        case .epub:
            self = .epub(contentId: try container.decode(String.self, forKey: .contentId))
        case .audio:
            self = .audio(
                contentId: try container.decode(String.self, forKey: .contentId),
                chapterIndex: try container.decode(Int.self, forKey: .chapterIndex),
                voiceId: try container.decode(String.self, forKey: .voiceId),
                chunks: try container.decode([Int].self, forKey: .chunks)
            )
        case .voice:
            self = .voice(id: try container.decode(String.self, forKey: .id))
        case .voicePreview:
            self = .voicePreview(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .bookBundle(let contentId):
            try container.encode(Kind.bookBundle, forKey: .kind)
            try container.encode(contentId, forKey: .contentId)
        case .epub(let contentId):
            try container.encode(Kind.epub, forKey: .kind)
            try container.encode(contentId, forKey: .contentId)
        case .audio(let contentId, let chapterIndex, let voiceId, let chunks):
            try container.encode(Kind.audio, forKey: .kind)
            try container.encode(contentId, forKey: .contentId)
            try container.encode(chapterIndex, forKey: .chapterIndex)
            try container.encode(voiceId, forKey: .voiceId)
            try container.encode(chunks, forKey: .chunks)
        case .voice(let id):
            try container.encode(Kind.voice, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .voicePreview(let id):
            try container.encode(Kind.voicePreview, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}
