import Foundation
import Testing

@testable import HuiverKit

/// One sync between two libraries over real sockets.
///
/// `SyncSessionTests` runs the protocol over an in-memory pipe, which is what
/// makes it fast and hermetic — and what leaves a whole layer untested: Bonjour
/// discovery, the TLS-PSK handshake, `NWSyncTransport`'s framing, and every
/// assumption about who may send what while a socket is open. This runs the
/// same session for real, with both ends in one process, because the
/// alternative is finding out on a phone.
///
/// It needs the local network, and on a Mac that has never been asked it may
/// prompt. It is a few seconds rather than milliseconds, which is why it is
/// here rather than folded into the pipe tests.
struct NetworkSyncTests {
    /// A library seeded as JSON, which is all `Library` needs: it stamps the
    /// content identity on load exactly as it does for a real one.
    func seed(
        _ root: URL, id: String, title: String, text: String, chunkCount: Int
    ) throws {
        let json = """
        [{"id":"\(id)","title":"\(title)","author":"Test","added":776000000,\
        "language":"en","chapters":[{"id":"\(id)-chapter-0","title":"Chapter One",\
        "text":"\(text)","chunkCount":\(chunkCount),"renderedChunks":0}]}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
    }

    func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-net-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A chunk's worth of tone, so what arrives can be compared with what left.
    func wav(seconds: Double, hz: Double) -> Data {
        let count = Int(Double(WavFile.sampleRate) * seconds)
        return WavFile.data(from: (0..<count).map { index in
            Float(sin(2 * .pi * hz * Double(index) / 24000) * 0.5)
        })
    }

    func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, energyA = 0.0, energyB = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            energyA += Double(x) * Double(x)
            energyB += Double(y) * Double(y)
        }
        return dot / max(1e-9, (energyA.squareRoot() * energyB.squareRoot()))
    }

    /// Somewhere for the server callback to record what it was asked, from
    /// whichever thread Network hands it to us on.
    final class Asks: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConvertRequest] = []
        func add(_ new: [ConvertRequest]) { lock.withLock { items.append(contentsOf: new) } }
        var count: Int { lock.withLock { items.count } }
    }

    @Test("a whole session over Bonjour and TLS: books, compressed audio, an ask")
    func realSession() async throws {
        let macRoot = try temporaryRoot()
        let phoneRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: macRoot)
            try? FileManager.default.removeItem(at: phoneRoot)
        }

        // The Mac has a book with audio; the phone has a different one without.
        let chunks = 6
        try seed(
            macRoot, id: "mac-book", title: "A Networked Book",
            text: String(repeating: "The quiet harbour town woke slowly. ", count: 20),
            chunkCount: chunks
        )
        try seed(
            phoneRoot, id: "phone-book", title: "A Book The Phone Has",
            text: String(repeating: "Gulls turned above the jetty. ", count: 20),
            chunkCount: 12
        )

        let macLibrary = try Library(root: macRoot)
        let phoneLibrary = try Library(root: phoneRoot)
        let macProgress = ProgressStore(root: macRoot)
        let phoneProgress = ProgressStore(root: phoneRoot)

        let book = try #require(await macLibrary.book("mac-book"))
        let chapter = try #require(book.chapters.first)
        try await macLibrary.storeChunks(
            (0..<chunks).map { ($0, wav(seconds: 2, hz: 180 + Double($0) * 20)) },
            bookId: book.id, chapterId: chapter.id, voiceId: "lv_klett"
        )

        let phoneBook = try #require(await phoneLibrary.book("phone-book"))
        let phoneChapter = try #require(phoneBook.chapters.first)
        let phoneContentId = try #require(phoneBook.contentId)

        // The Mac's side, listening.
        let asks = Asks()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let serviceName = "huiver-test-\(UUID().uuidString.prefix(8))"
        let server = SyncServer()
        let finished = AsyncStream<Void>.makeStream()

        try server.start(serviceName: serviceName, psk: key, pskIdentity: "phone-id") {
            transport in
            let source = LibrarySyncDataSource(
                library: macLibrary, progress: macProgress, deviceId: "mac-id",
                acceptRequests: { requests in
                    asks.add(requests)
                    return requests.map {
                        SyncMessage.JobStatus(
                            requestId: $0.requestId, state: .queued,
                            renderedChunks: 0, chunkCount: 12
                        )
                    }
                }
            )
            let session = SyncSession(
                transport: transport, role: .server, source: source,
                identity: SyncMessage.Hello(
                    deviceId: "mac-id", deviceName: "Mac", appVersion: "test"
                ),
                wantsAudio: false
            )
            _ = try? await session.run()
            await transport.close()
            finished.continuation.yield()
            finished.continuation.finish()
        }
        defer { server.stop() }

        // The phone's side: an ask for a chapter it has and the Mac does not,
        // which is the case convert-offload exists for.
        let requests = ConvertRequestStore(root: phoneRoot)
        let ask = await requests.add(
            contentId: phoneContentId, chapterIndex: 0,
            textHash: phoneChapter.textHash ?? "", voiceId: "lv_klett"
        )

        let endpoint = try await SyncClient.find(serviceName: serviceName, timeout: .seconds(20))
        let transport = try await SyncClient.connect(
            to: endpoint, psk: key, pskIdentity: "phone-id"
        )
        let session = SyncSession(
            transport: transport, role: .client,
            source: LibrarySyncDataSource(
                library: phoneLibrary, progress: phoneProgress,
                deviceId: "phone-id", requests: requests
            ),
            identity: SyncMessage.Hello(
                deviceId: "phone-id", deviceName: "Phone", appVersion: "test"
            ),
            wantsAudio: true
        )
        let summary = try await session.run()
        await transport.close()
        for await _ in finished.stream {}

        // The book and its audio arrived.
        let arrived = try #require(
            await phoneLibrary.all().first { $0.contentId == book.contentId }
        )
        let arrivedChapter = try #require(arrived.chapters.first)
        #expect(arrivedChapter.renderedChunks == chunks)
        #expect(arrivedChapter.renderedVoice == "lv_klett")
        #expect(await macLibrary.all().count == 2, "the phone's book went the other way")

        // Compressed on the wire, WAV on both disks, sample for sample.
        let sent = WavFile.samples(
            from: try Data(
                contentsOf: macLibrary.chunkURL(book: book.id, chapter: chapter.id, index: 2)
            )
        )
        let landed = WavFile.samples(
            from: try Data(
                contentsOf: phoneLibrary.chunkURL(
                    book: arrived.id, chapter: arrivedChapter.id, index: 2
                )
            )
        )
        #expect(landed.count == sent.count, "the chunk kept its length across AAC")
        #expect(correlation(sent, landed) > 0.99)

        let onDisk = (0..<chunks).reduce(Int64(0)) { total, index in
            let url = macLibrary.chunkURL(book: book.id, chapter: chapter.id, index: index)
            return total + Int64((try? Data(contentsOf: url))?.count ?? 0)
        }
        #expect(
            summary.bytesReceived < onDisk / 3,
            "\(summary.bytesReceived) bytes on the wire for \(onDisk) of WAV"
        )

        // And the ask made it, with an answer.
        #expect(asks.count == 1)
        #expect(summary.jobUpdates == 1)
        #expect(await requests.status(requestId: ask.requestId)?.state == .queued)
    }
}
