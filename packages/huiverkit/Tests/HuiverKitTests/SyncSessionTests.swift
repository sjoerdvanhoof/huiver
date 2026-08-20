import Foundation
import Testing

@testable import HuiverKit

/// A whole sync, both halves, in one process.
///
/// This is what the `SyncTransport` seam is for: the client and the server run
/// as they really do, against real manifests and real diffs, over a pipe
/// instead of a socket. No Bonjour, no permissions, no second device, and a
/// full session takes microseconds.
private actor Pipe {
    private var buffer: [Frame] = []
    private var waiting: [CheckedContinuation<Frame?, Never>] = []
    private var closed = false

    func put(_ frame: Frame) {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume(returning: frame)
        } else {
            buffer.append(frame)
        }
    }

    func take() async -> Frame? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func close() {
        closed = true
        for continuation in waiting { continuation.resume(returning: nil) }
        waiting.removeAll()
    }
}

/// Two ends of one connection.
private struct MemoryTransport: SyncTransport {
    let outbound: Pipe
    let inbound: Pipe
    /// Damage the bytes of files in flight — after the sender hashed them,
    /// which is the only way to test that the hash check does anything.
    let damagesBlobs: Bool

    func send(_ frame: Frame) async throws {
        // Through the real byte codec rather than passing the struct across:
        // framing bugs should be able to fail these tests too.
        var decoder = FrameDecoder()
        for decoded in try decoder.push(Framing.encode(frame)) {
            var frame = decoded
            if damagesBlobs, frame.kind == .blob, !frame.payload.isEmpty {
                var payload = frame.payload
                payload[payload.startIndex] = payload[payload.startIndex] &+ 1
                frame = Frame(kind: .blob, payload: payload)
            }
            await outbound.put(frame)
        }
    }

    func receive() async throws -> Frame? { await inbound.take() }
    func close() async { await outbound.close() }

    static func pair(
        damagingServerBlobs: Bool = false
    ) -> (client: MemoryTransport, server: MemoryTransport) {
        let a = Pipe()
        let b = Pipe()
        return (
            MemoryTransport(outbound: a, inbound: b, damagesBlobs: false),
            MemoryTransport(outbound: b, inbound: a, damagesBlobs: damagingServerBlobs)
        )
    }
}

/// A device's worth of data, in memory.
private actor FakeSource: SyncDataSource {
    /// How many bytes a rendered chunk stands in for here.
    static let bytesPerChunk = 1000

    var stored: SyncMessage.Manifest
    var files: [String: Data]
    /// Whether this device can produce audio for any range it is asked for,
    /// the way a real one reads chunk files off disk.
    var servesAudio: Bool
    /// Whether this device renders for the other one, the way the Mac does.
    var rendersForOthers: Bool
    private(set) var delivered: [String: Data] = [:]
    private(set) var mergedProgress: [ProgressRecord] = []
    private(set) var accepted: [ConvertRequest] = []
    private(set) var heardAbout: [SyncMessage.JobStatus] = []

    init(
        manifest: SyncMessage.Manifest = .init(),
        files: [String: Data] = [:],
        servesAudio: Bool = false,
        rendersForOthers: Bool = false
    ) {
        self.stored = manifest
        self.files = files
        self.servesAudio = servesAudio
        self.rendersForOthers = rendersForOthers
    }

    func manifest() async -> SyncMessage.Manifest { stored }

    func data(for item: WantItem) async throws -> Data? {
        // Audio is asked for by range, and the range depends on what the other
        // device already has — so it is generated to fit rather than looked up.
        if case .audio(_, _, _, let chunks) = item, servesAudio {
            return Data(repeating: 42, count: chunks.count * Self.bytesPerChunk)
        }
        return files[item.key]
    }

    func receive(_ item: WantItem, data: Data) async throws {
        delivered[item.key] = data
    }

    func mergeProgress(_ records: [ProgressRecord]) async {
        mergedProgress.append(contentsOf: records)
    }

    func acceptConvertRequests(_ requests: [ConvertRequest]) async -> [SyncMessage.JobStatus] {
        guard rendersForOthers else { return [] }
        accepted.append(contentsOf: requests)
        return requests.map {
            SyncMessage.JobStatus(
                requestId: $0.requestId, state: .queued, renderedChunks: 0, chunkCount: 10
            )
        }
    }

    func receive(jobStatus: SyncMessage.JobStatus) async {
        heardAbout.append(jobStatus)
    }
}

struct SyncSessionTests {
    func hello(_ name: String, acceptsAAC: Bool = true) -> SyncMessage.Hello {
        SyncMessage.Hello(
            deviceId: name, deviceName: name, appVersion: "test",
            audioCodecs: acceptsAAC ? [.wav, .aac] : [.wav]
        )
    }

    func bookManifest(
        contentId: String = "book", chapters: Int = 2, audioChunks: Int? = nil
    ) -> BookManifest {
        BookManifest(
            contentId: contentId,
            title: "A Book",
            language: "en",
            chapters: (0..<chapters).map { index in
                ChapterManifest(
                    index: index, title: "Chapter \(index + 1)", textHash: "hash-\(index)",
                    chunkCount: 10, chunkerVersion: 1,
                    audio: audioChunks.map {
                        AudioManifest(voiceId: "ruth", renderedChunks: $0, codec: .wav)
                    }
                )
            }
        )
    }

    /// Run both halves concurrently, as they run for real.
    fileprivate func runSession(
        client: FakeSource, server: FakeSource, clientWantsAudio: Bool = true,
        serverWantsAudio: Bool = false, damagingServerBlobs: Bool = false,
        clientAcceptsAAC: Bool = true
    ) async throws -> (SyncSession.Summary, SyncSession.Summary) {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            damagingServerBlobs: damagingServerBlobs
        )
        let clientSession = SyncSession(
            transport: clientTransport, role: .client, source: client,
            identity: hello("phone", acceptsAAC: clientAcceptsAAC), wantsAudio: clientWantsAudio
        )
        let serverSession = SyncSession(
            transport: serverTransport, role: .server, source: server,
            identity: hello("mac"), wantsAudio: serverWantsAudio
        )
        async let clientResult = clientSession.run()
        async let serverResult = serverSession.run()
        return (try await clientResult, try await serverResult)
    }

    @Test("two devices with the same library exchange nothing")
    func noOpSync() async throws {
        let manifest = SyncMessage.Manifest(books: [bookManifest()])
        let client = FakeSource(manifest: manifest)
        let server = FakeSource(manifest: manifest)

        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        #expect(fromClient.received == 0)
        #expect(fromServer.received == 0)
        #expect(fromClient.peerName == "mac")
        #expect(fromServer.peerName == "phone")
    }

    @Test("a book on the Mac arrives on the phone")
    func transfersABook() async throws {
        let bundle = Data("the whole book, packed".utf8)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()]),
            files: [WantItem.bookBundle(contentId: "book").key: bundle]
        )
        let client = FakeSource()

        let (fromClient, _) = try await runSession(client: client, server: server)
        #expect(fromClient.received == 1)
        #expect(await client.delivered[WantItem.bookBundle(contentId: "book").key] == bundle)
    }

    /// The direction that matters: audio is rendered on the Mac and listened to
    /// on the phone, and never travels the other way.
    @Test("audio flows to the phone and not back")
    func audioIsOneWay() async throws {
        let audio = WantItem.audio(
            contentId: "book", chapterIndex: 0, voiceId: "ruth", chunks: Array(0..<4)
        )
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 4)]),
            files: [WantItem.bookBundle(contentId: "book").key: Data("book".utf8)],
            servesAudio: true
        )
        // The phone has the book already, but none of its audio.
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        )

        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        let expected = 4 * FakeSource.bytesPerChunk
        #expect(await client.delivered[audio.key]?.count == expected)
        #expect(fromClient.bytesReceived == Int64(expected))
        #expect(fromServer.received == 0, "the Mac asked the phone for nothing")
    }

    /// A file larger than one frame proves the blob loop reassembles in order.
    @Test("a large file crosses in one piece")
    func largeTransfer() async throws {
        let big = Data((0..<500_000).map { UInt8($0 % 251) })
        let item = WantItem.bookBundle(contentId: "book")
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()]),
            files: [item.key: big]
        )
        let client = FakeSource()

        _ = try await runSession(client: client, server: server)
        #expect(await client.delivered[item.key] == big, "every byte, in order")
    }

    /// The hash is the whole defence against a chapter of static.
    @Test("a damaged file is discarded rather than stored")
    func rejectsCorruptTransfers() async throws {
        let item = WantItem.bookBundle(contentId: "book")
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()]),
            files: [item.key: Data("the whole book".utf8)]
        )
        let client = FakeSource()

        let (fromClient, _) = try await runSession(
            client: client, server: server, damagingServerBlobs: true
        )
        #expect(await client.delivered[item.key] == nil, "not stored")
        #expect(fromClient.received == 0)
    }

    /// Deleted between building the manifest and being asked for it. Common
    /// enough — the cleanup sweep runs on its own schedule — and not an error.
    @Test("something that vanished mid-session is skipped")
    func toleratesMissingFiles() async throws {
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()]),
            files: [:]  // the manifest offers a book whose bytes are gone
        )
        let client = FakeSource()

        let (fromClient, _) = try await runSession(client: client, server: server)
        #expect(fromClient.received == 0)
    }

    @Test("positions are exchanged before any files move")
    func mergesProgress() async throws {
        let newer = ProgressRecord(
            contentId: "book", chapterIndex: 1, position: 942, finished: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 5000), deviceId: "mac"
        )
        let older = ProgressRecord(
            contentId: "book", chapterIndex: 1, position: 30, finished: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1000), deviceId: "phone"
        )
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()], progress: [older])
        )
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()], progress: [newer])
        )

        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        #expect(fromClient.progressMerged == 1)
        #expect(await client.mergedProgress == [newer])
        #expect(fromServer.progressMerged == 0, "the Mac's reading was already the newer one")
    }

    @Test("both devices send books the other lacks, in one session")
    func transfersBothWays() async throws {
        let onMac = WantItem.bookBundle(contentId: "mac-book")
        let onPhone = WantItem.bookBundle(contentId: "phone-book")

        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(contentId: "mac-book")]),
            files: [onMac.key: Data("from the mac".utf8)]
        )
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(contentId: "phone-book")]),
            files: [onPhone.key: Data("from the phone".utf8)]
        )

        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        #expect(fromClient.received == 1)
        #expect(fromServer.received == 1)
        #expect(await client.delivered[onMac.key] == Data("from the mac".utf8))
        #expect(await server.delivered[onPhone.key] == Data("from the phone".utf8))
    }

    @Test("a peer that speaks a different protocol version is refused")
    func refusesIncompatiblePeers() async throws {
        let (clientTransport, serverTransport) = MemoryTransport.pair()
        let fromTheFuture = SyncMessage.Hello(
            protocolVersion: 99, minimumVersion: 99, deviceId: "mac", deviceName: "mac",
            appVersion: "future"
        )
        let client = SyncSession(
            transport: clientTransport, role: .client, source: FakeSource(),
            identity: hello("phone")
        )
        let server = SyncSession(
            transport: serverTransport, role: .server, source: FakeSource(),
            identity: fromTheFuture
        )
        async let serverRun: SyncSession.Summary = server.run()

        await #expect(throws: SyncSession.SyncError.self) { try await client.run() }
        _ = try? await serverRun
    }

    /// Clocks decide who wins a conflict, so a device whose clock is wrong is
    /// worth saying so about.
    @Test("a badly skewed clock is reported")
    func reportsClockSkew() async throws {
        let (clientTransport, serverTransport) = MemoryTransport.pair()
        let skewed = SyncMessage.Hello(
            deviceId: "mac", deviceName: "mac", clock: Date().addingTimeInterval(3600),
            appVersion: "test"
        )
        let client = SyncSession(
            transport: clientTransport, role: .client, source: FakeSource(),
            identity: hello("phone")
        )
        let server = SyncSession(
            transport: serverTransport, role: .server, source: FakeSource(), identity: skewed
        )
        async let serverResult = server.run()
        let summary = try await client.run()
        _ = try await serverResult

        let skew = try #require(summary.clockSkew)
        #expect(skew > 3000)
    }

    /// The resume story, end to end: interrupt a first sync, run a second, and
    /// only what is still missing crosses.
    @Test("a second session asks only for what the first did not deliver")
    func resumesByDiffing() async throws {
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 10)]),
            files: [WantItem.bookBundle(contentId: "book").key: Data("book".utf8)],
            servesAudio: true
        )
        // The phone already got the book and the first six chunks.
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 6)])
        )

        _ = try await runSession(client: client, server: server)
        let asked = await client.delivered.keys.sorted()
        #expect(
            asked == [
                WantItem.audio(
                    contentId: "book", chapterIndex: 0, voiceId: "ruth", chunks: Array(6..<10)
                ).key
            ],
            "only the tail, and no second copy of the book"
        )
    }

    // MARK: - Convert offload

    func request(chapter: Int = 0, voice: String = "ruth") -> ConvertRequest {
        ConvertRequest(
            contentId: "book", chapterIndex: chapter, textHash: "hash-\(chapter)", voiceId: voice
        )
    }

    @Test("an ask from the phone reaches the Mac and comes back as a status")
    func convertOffload() async throws {
        let ask = request()
        let client = FakeSource(
            manifest: SyncMessage.Manifest(
                books: [bookManifest(chapters: 1)], convertRequests: [ask]
            ),
            // Something to receive as well, so the status is not the only thing
            // in flight.
            files: [:]
        )
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(contentId: "other", chapters: 1)]),
            files: [WantItem.bookBundle(contentId: "other").key: Data("book".utf8)],
            rendersForOthers: true
        )

        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        // By id rather than by value: a `Date` does not survive a JSON round
        // trip bit-for-bit, and the id is the part that has to match anyway.
        #expect(await server.accepted.map(\.requestId) == [ask.requestId], "the Mac took it on")
        #expect(await server.accepted.first?.chapterIndex == 0)
        #expect(fromServer.convertRequestsAccepted == 1)
        #expect(await client.heardAbout.map(\.requestId) == [ask.requestId])
        #expect(await client.heardAbout.first?.state == .queued)
        #expect(fromClient.jobUpdates == 1)
    }

    /// The case that made statuses a message the session swallows anywhere
    /// rather than one handled inside the receive loop: a phone with nothing to
    /// receive never enters that loop, and used to meet the status where it was
    /// expecting a want.
    @Test("a status arrives even when the phone is asking for nothing")
    func statusWithNothingToReceive() async throws {
        let ask = request()
        let manifest = SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        let client = FakeSource(
            manifest: SyncMessage.Manifest(
                books: manifest.books, convertRequests: [ask]
            )
        )
        let server = FakeSource(manifest: manifest, rendersForOthers: true)

        let (fromClient, _) = try await runSession(client: client, server: server)
        #expect(fromClient.received == 0, "the libraries already match")
        #expect(await client.heardAbout.count == 1)
        #expect(fromClient.jobUpdates == 1)
    }

    @Test("the Mac does not ask the phone to render anything")
    func offloadIsOneWay() async throws {
        let manifest = SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        let client = FakeSource(manifest: manifest, rendersForOthers: true)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(
                books: manifest.books, convertRequests: [request()]
            )
        )

        // The Mac never populates `convertRequests`, so this is the protocol
        // being symmetric rather than a direction anything uses — what matters
        // is that the phone answering does not break the session.
        let (fromClient, fromServer) = try await runSession(client: client, server: server)
        #expect(fromClient.convertRequestsAccepted == 1)
        #expect(fromServer.jobUpdates == 1)
    }

    // MARK: - Audio on the wire

    /// A chapter's worth of real audio: a few chunks of tone, packed the way
    /// the library serves them.
    func audioPack(chunks: Int, samplesEach: Int = 12000) -> Data {
        ChunkPack.pack(
            (0..<chunks).map { index in
                let samples = (0..<samplesEach).map { sample in
                    Float(sin(2 * Double.pi * 200 * Double(sample) / 24000) * 0.5)
                }
                return (index, WavFile.data(from: samples))
            }
        )
    }

    /// The saving that makes syncing a book over a cable bearable, and the
    /// thing that must survive it: the chunk boundaries.
    @Test("audio crosses compressed and arrives as the WAV it started as")
    func audioCrossesAsAAC() async throws {
        let item = WantItem.audio(
            contentId: "book", chapterIndex: 0, voiceId: "ruth", chunks: Array(0..<6)
        )
        // Half a minute: enough that the container's fixed cost is beside the
        // point, which is the size a real transfer has.
        let original = audioPack(chunks: 6, samplesEach: 5 * WavFile.sampleRate)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 6)]),
            files: [item.key: original]
        )
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        )

        let (fromClient, _) = try await runSession(client: client, server: server)
        let delivered = try #require(await client.delivered[item.key])

        // What was stored is WAV again, chunk for chunk and sample for sample.
        let before = ChunkPack.unpack(original)
        let after = ChunkPack.unpack(delivered)
        #expect(after.map(\.index) == before.map(\.index))
        #expect(
            after.map { WavFile.sampleCount(of: $0.data) }
                == before.map { WavFile.sampleCount(of: $0.data) }
        )

        // And what crossed was a fraction of it.
        #expect(fromClient.bytesReceived < Int64(original.count) / 4)
    }

    /// A phone built before AAC existed says nothing about codecs in its hello,
    /// and must get what it can read.
    @Test("a peer that cannot decode AAC is sent WAV")
    func fallsBackToWav() async throws {
        let item = WantItem.audio(
            contentId: "book", chapterIndex: 0, voiceId: "ruth", chunks: Array(0..<2)
        )
        let original = audioPack(chunks: 2, samplesEach: 5 * WavFile.sampleRate)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 2)]),
            files: [item.key: original]
        )
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        )

        let (fromClient, _) = try await runSession(
            client: client, server: server, clientAcceptsAAC: false
        )
        #expect(await client.delivered[item.key] == original, "byte for byte, uncompressed")
        #expect(fromClient.bytesReceived == Int64(original.count))
    }

    /// An old peer's hello has no codec list at all, which is not the same as
    /// an empty one.
    @Test("a hello with nothing to say about codecs means WAV")
    func silenceMeansWav() {
        var hello = hello("old")
        hello.audioCodecs = nil
        #expect(hello.accepts(.wav))
        #expect(!hello.accepts(.aac))
    }

    /// Books and covers are not audio and are not touched by any of this.
    @Test("a book bundle crosses uncompressed even when AAC is on offer")
    func onlyAudioIsCompressed() async throws {
        let bundle = Data(repeating: 7, count: 5000)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest()]),
            files: [WantItem.bookBundle(contentId: "book").key: bundle]
        )
        let client = FakeSource()
        _ = try await runSession(client: client, server: server)
        #expect(await client.delivered[WantItem.bookBundle(contentId: "book").key] == bundle)
    }

    /// A single short chunk compresses to more than it started as, because an
    /// MPEG-4 container costs about 33 kB whatever is in it. The sender sends
    /// whichever is smaller.
    @Test("a transfer too small to be worth compressing crosses as WAV")
    func tinyTransferStaysWav() async throws {
        let item = WantItem.audio(
            contentId: "book", chapterIndex: 0, voiceId: "ruth", chunks: [0]
        )
        let original = audioPack(chunks: 1, samplesEach: 2400)
        let server = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1, audioChunks: 1)]),
            files: [item.key: original]
        )
        let client = FakeSource(
            manifest: SyncMessage.Manifest(books: [bookManifest(chapters: 1)])
        )

        _ = try await runSession(client: client, server: server)
        #expect(await client.delivered[item.key] == original)
    }
}
