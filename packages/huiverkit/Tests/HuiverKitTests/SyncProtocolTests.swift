import Foundation
import Testing

@testable import HuiverKit

/// The wire format, and the decision about what crosses it.
///
/// None of this needs a network. The transport is deliberately the only part of
/// sync that does, so everything worth being sure of — where frames begin, what
/// to ask for, who wins a conflict — is tested here at full speed.
struct SyncFramingTests {
    @Test("a frame survives the round trip")
    func roundTrip() throws {
        let frame = Frame(kind: .control, payload: Data("hello".utf8))
        var decoder = FrameDecoder()
        let frames = try decoder.push(Framing.encode(frame))
        #expect(frames == [frame])
        #expect(decoder.pending == 0)
    }

    /// The case the length prefix exists for: TCP hands over whatever it has,
    /// which is rarely one whole message.
    @Test("a frame split across reads is reassembled")
    func splitAcrossReads() throws {
        let frame = Frame(kind: .blob, payload: Data(repeating: 7, count: 5000))
        let bytes = Framing.encode(frame)
        var decoder = FrameDecoder()

        // Split mid-header, then mid-payload — both are real.
        #expect(try decoder.push(bytes.prefix(3)).isEmpty)
        #expect(try decoder.push(bytes.dropFirst(3).prefix(1000)).isEmpty)
        #expect(try decoder.push(bytes.dropFirst(1003)) == [frame])
    }

    @Test("several frames in one read all come out")
    func coalescedReads() throws {
        let a = Frame(kind: .control, payload: Data("one".utf8))
        let b = Frame(kind: .blob, payload: Data("two".utf8))
        let c = Frame(kind: .control, payload: Data())

        var decoder = FrameDecoder()
        var bytes = Framing.encode(a)
        bytes.append(Framing.encode(b))
        bytes.append(Framing.encode(c))
        #expect(try decoder.push(bytes) == [a, b, c])
    }

    @Test("an empty payload is a valid frame")
    func emptyPayload() throws {
        let frame = Frame(kind: .control, payload: Data())
        var decoder = FrameDecoder()
        #expect(try decoder.push(Framing.encode(frame)) == [frame])
    }

    /// A bad length must not become an allocation the size of the number that
    /// happened to be in those four bytes.
    @Test("an absurd length is refused rather than allocated")
    func refusesOversizedFrames() throws {
        var bytes = Data()
        var length = UInt32(Framing.maxPayload + 1).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(Frame.Kind.blob.rawValue)

        var decoder = FrameDecoder()
        #expect(throws: Framing.FramingError.oversizedFrame(Framing.maxPayload + 1)) {
            try decoder.push(bytes)
        }
    }

    @Test("an unknown frame kind is refused")
    func refusesUnknownKind() throws {
        var bytes = Data()
        var length = UInt32(1).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(99)
        bytes.append(0)

        var decoder = FrameDecoder()
        #expect(throws: Framing.FramingError.unknownKind(99)) { try decoder.push(bytes) }
    }
}

struct SyncMessageTests {
    /// Every message shape, through JSON and back. This is the format two
    /// separately-updated apps have to agree on, so the test is exhaustive
    /// rather than representative.
    @Test("every message round-trips through JSON")
    func messagesRoundTrip() throws {
        let hello = SyncMessage.Hello(
            deviceId: "phone", deviceName: "iPhone", clock: Date(timeIntervalSince1970: 1_000_000),
            appVersion: "0.2"
        )
        let messages: [SyncMessage] = [
            .hello(hello),
            .helloAck(hello),
            .manifest(
                SyncMessage.Manifest(
                    books: [
                        BookManifest(
                            contentId: "abc", title: "A Book", author: "Writer", language: "en",
                            hasCover: true, hasEpub: false,
                            chapters: [
                                ChapterManifest(
                                    index: 0, title: "One", textHash: "hash", chunkCount: 12,
                                    chunkerVersion: 1,
                                    audio: AudioManifest(
                                        voiceId: "nano_default", renderedChunks: 12, codec: .aac
                                    )
                                )
                            ]
                        )
                    ],
                    voices: [VoiceManifest(id: "v1", name: "Ruth", hasPreview: true)],
                    progress: [
                        ProgressRecord(
                            contentId: "abc", chapterIndex: 0, position: 61.5, finished: false,
                            updatedAt: Date(timeIntervalSince1970: 2_000_000), deviceId: "phone"
                        )
                    ],
                    convertRequests: [
                        ConvertRequest(
                            contentId: "abc", chapterIndex: 3, textHash: "hash", voiceId: "v1",
                            requestedAt: Date(timeIntervalSince1970: 3_000_000)
                        )
                    ]
                )
            ),
            .want(
                SyncMessage.Want(items: [
                    .bookBundle(contentId: "abc"),
                    .epub(contentId: "abc"),
                    .audio(contentId: "abc", chapterIndex: 2, voiceId: "v1", chunks: [0, 1, 2]),
                    .voice(id: "v1"),
                    .voicePreview(id: "v1"),
                ])
            ),
            .fileHeader(
                SyncMessage.FileHeader(
                    item: .bookBundle(contentId: "abc"), size: 4096, sha256: "deadbeef"
                )
            ),
            .fileDone(SyncMessage.FileDone(item: .bookBundle(contentId: "abc"))),
            .progressSet(SyncMessage.ProgressSet(records: [])),
            .jobStatus(
                SyncMessage.JobStatus(
                    requestId: "r1", state: .rendering, renderedChunks: 4, chunkCount: 20
                )
            ),
            .bye,
        ]

        for message in messages {
            let decoded = try SyncMessage.decode(try message.frame())
            #expect(decoded == message, "\(message) did not survive the round trip")
        }
    }

    /// The discriminator is part of the contract, not an implementation
    /// detail — an older build has to be able to read it.
    @Test("the wire format is a named type field")
    func wireFormatIsExplicit() throws {
        let frame = try SyncMessage.bye.frame()
        let json = try #require(String(data: frame.payload, encoding: .utf8))
        #expect(json.contains("\"type\""))
        #expect(json.contains("\"bye\""))
    }

    @Test("versions that cannot talk are detected")
    func versionNegotiation() {
        let new = SyncMessage.Hello(
            protocolVersion: 3, minimumVersion: 3, deviceId: "a", deviceName: "A", appVersion: "1"
        )
        let old = SyncMessage.Hello(
            protocolVersion: 1, minimumVersion: 1, deviceId: "b", deviceName: "B", appVersion: "1"
        )
        #expect(!new.canTalk(to: old))
        #expect(!old.canTalk(to: new))

        let tolerant = SyncMessage.Hello(
            protocolVersion: 3, minimumVersion: 1, deviceId: "c", deviceName: "C", appVersion: "1"
        )
        #expect(tolerant.canTalk(to: old))
        #expect(old.canTalk(to: tolerant))
    }

    /// Asking for the same render twice must be asking once — the phone
    /// re-sends its pending requests in every manifest.
    @Test("a convert request is idempotent by construction")
    func requestIdIsDerived() {
        let a = ConvertRequest(contentId: "x", chapterIndex: 1, textHash: "h", voiceId: "v")
        let b = ConvertRequest(
            contentId: "x", chapterIndex: 1, textHash: "h", voiceId: "v",
            requestedAt: Date(timeIntervalSince1970: 999)
        )
        #expect(a.requestId == b.requestId, "the time it was asked is not part of the ask")

        let other = ConvertRequest(contentId: "x", chapterIndex: 1, textHash: "h", voiceId: "w")
        #expect(a.requestId != other.requestId, "a different voice is a different job")
    }
}

struct SyncDiffTests {
    func chapter(
        _ index: Int, hash: String = "h", chunks: Int = 10, chunker: Int = 1,
        audio: AudioManifest? = nil
    ) -> ChapterManifest {
        ChapterManifest(
            index: index, title: "Chapter \(index + 1)", textHash: hash, chunkCount: chunks,
            chunkerVersion: chunker, audio: audio
        )
    }

    func book(
        _ contentId: String = "book", hasEpub: Bool = false, chapters: [ChapterManifest]
    ) -> BookManifest {
        BookManifest(
            contentId: contentId, title: "A Book", language: "en", hasEpub: hasEpub,
            chapters: chapters
        )
    }

    @Test("a book we do not have is asked for whole")
    func wantsUnknownBooks() {
        let theirs = SyncMessage.Manifest(books: [book(hasEpub: true, chapters: [chapter(0)])])
        let items = SyncDiff.want(mine: SyncMessage.Manifest(), theirs: theirs)
        #expect(items.contains(.bookBundle(contentId: "book")))
        #expect(items.contains(.epub(contentId: "book")))
    }

    @Test("a book we already have is not asked for again")
    func skipsKnownBooks() {
        let manifest = SyncMessage.Manifest(books: [book(chapters: [chapter(0)])])
        let items = SyncDiff.want(mine: manifest, theirs: manifest)
        #expect(items.isEmpty)
    }

    @Test("only the chunks we are missing are asked for")
    func wantsOnlyTheTail() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "v", renderedChunks: 10, codec: .wav))
            ])
        ])
        let mine = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "v", renderedChunks: 4, codec: .wav))
            ])
        ])
        let items = SyncDiff.want(mine: mine, theirs: theirs)
        #expect(
            items == [.audio(contentId: "book", chapterIndex: 0, voiceId: "v", chunks: [4, 5, 6, 7, 8, 9])]
        )
    }

    @Test("a paired phone replaces Nano audio with the Mac render")
    func macAudioReplacesNano() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(
                    voiceId: "v", renderedChunks: 10, codec: .wav, preferred: true
                ))
            ])
        ])
        let mine = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(
                    voiceId: "v", renderedChunks: 3, codec: .wav, preferred: false
                ))
            ])
        ])
        let items = SyncDiff.want(
            mine: mine, theirs: theirs, preferRemoteAudio: true
        )
        #expect(items == [
            .audio(
                contentId: "book", chapterIndex: 0, voiceId: "v",
                chunks: Array(0..<10)
            )
        ])
    }

    @Test("Mac audio already received by the phone resumes from its tail")
    func preferredAudioDoesNotRepeat() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(
                    voiceId: "v", renderedChunks: 10, codec: .wav, preferred: true
                ))
            ])
        ])
        let mine = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(
                    voiceId: "v", renderedChunks: 4, codec: .wav, preferred: true
                ))
            ])
        ])
        let items = SyncDiff.want(
            mine: mine, theirs: theirs, preferRemoteAudio: true
        )
        #expect(items == [
            .audio(
                contentId: "book", chapterIndex: 0, voiceId: "v",
                chunks: Array(4..<10)
            )
        ])
    }

    /// This is the resume mechanism. There is no separate resume path: an
    /// interrupted transfer simply produces a smaller diff next time.
    @Test("a re-run after a partial transfer asks for less")
    func diffIsTheResume() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "v", renderedChunks: 100, codec: .wav))
            ])
        ])
        var received = 0
        for _ in 0..<3 {
            let mine = SyncMessage.Manifest(books: [
                book(chapters: [
                    chapter(
                        0,
                        audio: received > 0
                            ? AudioManifest(voiceId: "v", renderedChunks: received, codec: .wav)
                            : nil
                    )
                ])
            ])
            guard case .audio(_, _, _, let chunks)? = SyncDiff.want(mine: mine, theirs: theirs).first
            else {
                Issue.record("expected more audio to be wanted")
                return
            }
            #expect(chunks.first == received)
            received += 30
        }
    }

    /// Chunk boundaries are file boundaries. Audio from a device that chunks
    /// differently would play the wrong words at the wrong offsets.
    @Test("audio is refused when the chunking does not match")
    func refusesMismatchedChunking() {
        let audio = AudioManifest(voiceId: "v", renderedChunks: 10, codec: .wav)
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [chapter(0, hash: "h", chunker: 2, audio: audio)])
        ])
        let mine = SyncMessage.Manifest(books: [book(chapters: [chapter(0, hash: "h", chunker: 1)])])
        #expect(SyncDiff.want(mine: mine, theirs: theirs).isEmpty)
    }

    @Test("audio is refused when the chapter text does not match")
    func refusesMismatchedText() {
        let audio = AudioManifest(voiceId: "v", renderedChunks: 10, codec: .wav)
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [chapter(0, hash: "theirs", audio: audio)])
        ])
        let mine = SyncMessage.Manifest(books: [book(chapters: [chapter(0, hash: "mine")])])
        #expect(SyncDiff.want(mine: mine, theirs: theirs).isEmpty)
    }

    /// Replacing a chapter someone rendered in the voice they chose is not
    /// sync's decision to make.
    @Test("audio in a different voice is left alone")
    func leavesOtherVoicesAlone() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "ruth", renderedChunks: 10, codec: .wav))
            ])
        ])
        let mine = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "mark", renderedChunks: 3, codec: .wav))
            ])
        ])
        #expect(SyncDiff.want(mine: mine, theirs: theirs).isEmpty)
    }

    @Test("the Mac does not ask the phone for audio")
    func audioIsOneDirectional() {
        let theirs = SyncMessage.Manifest(books: [
            book(chapters: [
                chapter(0, audio: AudioManifest(voiceId: "v", renderedChunks: 10, codec: .wav))
            ])
        ])
        let items = SyncDiff.want(
            mine: SyncMessage.Manifest(), theirs: theirs, audioIsWanted: false
        )
        #expect(items == [.bookBundle(contentId: "book")], "the book, but not its audio")
    }

    @Test("a voice we do not have is asked for, with its preview")
    func wantsNewVoices() {
        let theirs = SyncMessage.Manifest(voices: [
            VoiceManifest(id: "new", name: "New", hasPreview: true),
            VoiceManifest(id: "known", name: "Known", hasPreview: false),
        ])
        let mine = SyncMessage.Manifest(voices: [
            VoiceManifest(id: "known", name: "Known", hasPreview: false)
        ])
        let items = SyncDiff.want(mine: mine, theirs: theirs)
        #expect(items == [.voice(id: "new"), .voicePreview(id: "new")])
    }

    // MARK: - Progress

    func record(
        _ index: Int, position: Double, at seconds: TimeInterval, device: String = "phone",
        finished: Bool = false
    ) -> ProgressRecord {
        ProgressRecord(
            contentId: "book", chapterIndex: index, position: position, finished: finished,
            updatedAt: Date(timeIntervalSinceReferenceDate: seconds), deviceId: device
        )
    }

    @Test("a newer reading from the other device is taken")
    func takesNewerProgress() {
        let mine = [record(0, position: 10, at: 100)]
        let theirs = [record(0, position: 500, at: 200)]
        #expect(SyncDiff.newerProgress(mine: mine, theirs: theirs) == theirs)
    }

    @Test("an older reading is ignored")
    func ignoresOlderProgress() {
        let mine = [record(0, position: 500, at: 200)]
        let theirs = [record(0, position: 10, at: 100)]
        #expect(SyncDiff.newerProgress(mine: mine, theirs: theirs).isEmpty)
    }

    @Test("a chapter the other device has never opened is taken")
    func takesUnknownProgress() {
        let theirs = [record(3, position: 44, at: 100)]
        #expect(SyncDiff.newerProgress(mine: [], theirs: theirs) == theirs)
    }

    /// Identical records are not "newer" — otherwise every session would report
    /// every position as a change forever.
    @Test("an identical reading is not a change")
    func identicalIsNotNewer() {
        let same = [record(0, position: 10, at: 100)]
        #expect(SyncDiff.newerProgress(mine: same, theirs: same).isEmpty)
    }

    /// Two genuinely simultaneous readings have to be settled the same way on
    /// both devices, or they will swap answers every time they meet.
    @Test("a tie is broken identically on both sides")
    func tieBreakIsSymmetric() {
        let phone = record(0, position: 10, at: 100, device: "phone")
        let mac = record(0, position: 20, at: 100, device: "mac")

        // "phone" > "mac" as strings, so the phone's record wins on both sides.
        #expect(SyncDiff.newerProgress(mine: [mac], theirs: [phone]) == [phone])
        #expect(SyncDiff.newerProgress(mine: [phone], theirs: [mac]).isEmpty)
    }
}

struct BookBundleTests {
    func makeLibraryBook() async throws -> (Library, Book) {
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let book = try await library.add(
            ExtractedBook(
                title: "The Quiet Harbour",
                author: "A. Writer",
                chapters: [
                    ExtractedChapter(title: "One", text: "The town woke slowly."),
                    ExtractedChapter(title: "Two", text: "Then it rained."),
                ]
            ),
            language: .english
        )
        return (library, book)
    }

    @Test("a bundle round-trips into an equivalent book")
    func roundTrip() async throws {
        let (library, book) = try await makeLibraryBook()
        let bundle = BookBundle.make(from: book, coverURL: library.coverURL(book))
        let decoded = try BookBundle.decode(try bundle.encoded())
        let rebuilt = decoded.book(localId: "elsewhere", coverFile: nil)

        #expect(rebuilt.contentId == book.contentId, "the identity crosses intact")
        #expect(rebuilt.id != book.id, "the local id does not")
        #expect(rebuilt.chapters.map(\.text) == book.chapters.map(\.text))
        #expect(rebuilt.chapters.map(\.textHash) == book.chapters.map(\.textHash))
        #expect(rebuilt.chapters[0].id == "elsewhere-0", "chapter ids follow the local book")
    }

    /// A book that arrives claiming an id its own text does not produce would
    /// be invisible to the next sync: both devices would keep offering it to
    /// each other forever.
    @Test("a bundle that misdescribes itself is caught")
    func detectsInconsistency() async throws {
        let (library, book) = try await makeLibraryBook()
        var bundle = BookBundle.make(from: book, coverURL: library.coverURL(book))
        #expect(bundle.isSelfConsistent)

        bundle.contentId = "not the right hash"
        #expect(!bundle.isSelfConsistent)
    }

    @Test("text edited in flight is caught")
    func detectsTamperedText() async throws {
        let (library, book) = try await makeLibraryBook()
        var bundle = BookBundle.make(from: book, coverURL: library.coverURL(book))
        bundle.chapters[0].text = "Something else entirely."
        #expect(!bundle.isSelfConsistent, "the chapter no longer hashes to its stated hash")
    }

    @Test("a manifest reports the audio a book actually has")
    func manifestReportsAudio() async throws {
        let (library, book) = try await makeLibraryBook()
        var chapter = book.chapters[0]
        chapter.renderedChunks = 5
        chapter.renderedVoice = "ruth"
        try await library.update(chapter: chapter, in: book.id)

        let updated = try #require(await library.book(book.id))
        let manifest = BookBundle.manifest(
            for: updated, coverURL: library.coverURL(updated), epubURL: library.epubURL(updated)
        )
        #expect(manifest.chapters[0].audio?.renderedChunks == 5)
        #expect(manifest.chapters[0].audio?.voiceId == "ruth")
        #expect(manifest.chapters[1].audio == nil)
        #expect(manifest.hasEpub == false)
    }
}
