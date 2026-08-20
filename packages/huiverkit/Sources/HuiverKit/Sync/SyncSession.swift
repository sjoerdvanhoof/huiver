import Foundation

/// What a session reads from and writes to.
///
/// `SyncSession` never touches `Library`, `ProgressStore` or the filesystem
/// directly. Everything it needs is behind this, which is what lets the whole
/// protocol be exercised over a pipe against an in-memory store — and what will
/// let the Mac serve books out of a different layout than the phone stores them
/// in.
public protocol SyncDataSource: Sendable {
    /// Everything this device has.
    func manifest() async -> SyncMessage.Manifest
    /// The bytes of something the other device asked for, or nil if it has gone
    /// since the manifest was built.
    func data(for item: WantItem) async throws -> Data?
    /// Take delivery. Already hash-verified by the time this is called.
    func receive(_ item: WantItem, data: Data) async throws
    /// Merge readings from the other device that are newer than ours.
    func mergeProgress(_ records: [ProgressRecord]) async
    /// Take on the other device's outstanding "please render this" asks, and
    /// say what became of each.
    func acceptConvertRequests(_ requests: [ConvertRequest]) async -> [SyncMessage.JobStatus]
    /// What the other device made of an ask this one sent.
    func receive(jobStatus: SyncMessage.JobStatus) async
}

/// Both halves of convert-offload are optional: a device that renders for
/// nobody accepts no requests, and one that asks for nothing has nowhere to put
/// a status. Defaults rather than requirements, so a data source that predates
/// offload — including the in-memory one the protocol tests run against — is
/// still a `SyncDataSource`.
public extension SyncDataSource {
    func acceptConvertRequests(_ requests: [ConvertRequest]) async -> [SyncMessage.JobStatus] {
        []
    }

    func receive(jobStatus: SyncMessage.JobStatus) async {}
}

/// One sync, start to finish.
///
/// Deliberately turn-based: the client speaks, the server answers, and only one
/// of them is sending at a time. A full-duplex version would shave time off a
/// large first sync, at the cost of a state machine where transfers, progress
/// updates and job statuses interleave — and this runs between two devices
/// belonging to one person who is usually watching it happen. Predictable beats
/// fast here, and an interrupted session costs nothing: the next one diffs the
/// manifests again and asks for whatever did not make it.
///
/// ```
/// client                          server
///   ── hello ─────────────────────▶
///   ◀───────────────── helloAck ──
///   ── manifest ──────────────────▶
///   ◀───────────────── manifest ──
///   ── want ──────────────────────▶
///   ◀──── headers, blobs, dones ──
///   ◀───────────────────── want ──
///   ── headers, blobs, dones ─────▶
///   ── bye ───────────────────────▶
/// ```
public actor SyncSession {
    public enum Role: Sendable {
        case client
        case server
    }

    /// What happened, for the UI and the log.
    public struct Summary: Sendable, Equatable {
        public var peerName: String = ""
        public var peerDeviceId: String = ""
        public var sent: Int = 0
        public var received: Int = 0
        public var bytesSent: Int64 = 0
        public var bytesReceived: Int64 = 0
        public var progressMerged: Int = 0
        /// Asks from the other device that this one took on.
        public var convertRequestsAccepted: Int = 0
        /// News about asks this device made, however it arrived.
        public var jobUpdates: Int = 0
        /// Set when the two devices' clocks disagree enough to make
        /// newest-wins the wrong answer.
        public var clockSkew: TimeInterval?
    }

    public enum SyncError: Error, LocalizedError, Equatable {
        case handshakeFailed(String)
        case incompatibleVersion(theirs: Int, mine: Int)
        case unexpectedMessage(String)
        case corruptTransfer(String)
        case closed

        public var errorDescription: String? {
            switch self {
            case .handshakeFailed(let why):
                return "Could not agree with the other device: \(why)"
            case .incompatibleVersion(let theirs, let mine):
                return """
                    The other device speaks version \(theirs) of the sync protocol and this one \
                    speaks \(mine). Update whichever is older.
                    """
            case .unexpectedMessage(let what):
                return "The other device said \(what) when it should not have."
            case .corruptTransfer(let key):
                return "\(key) arrived damaged and was discarded."
            case .closed:
                return "The other device disconnected."
            }
        }
    }

    /// How much of a file goes in one frame. Small enough that a cancelled
    /// transfer stops promptly, large enough that a 30 MB chapter is not half a
    /// million frames.
    static let blobChunk = 64 * 1024

    /// Clocks further apart than this make "newest wins" meaningless.
    static let tolerableSkew: TimeInterval = 120

    private let transport: SyncTransport
    private let role: Role
    private let source: SyncDataSource
    private let identity: SyncMessage.Hello
    /// Whether this side wants the other's audio. The phone does; the Mac,
    /// which can render anything faster than the phone can, does not.
    private let wantsAudio: Bool
    /// Set at the handshake: whether the other device can decode AAC. Audio is
    /// six times smaller compressed, and the only thing stopping every session
    /// using it is a peer old enough not to understand it.
    private var peerAcceptsAAC = false

    public init(
        transport: SyncTransport,
        role: Role,
        source: SyncDataSource,
        identity: SyncMessage.Hello,
        wantsAudio: Bool = true
    ) {
        self.transport = transport
        self.role = role
        self.source = source
        self.identity = identity
        self.wantsAudio = wantsAudio
    }

    public func run() async throws -> Summary {
        var summary = Summary()
        let peer = try await handshake()
        summary.peerName = peer.deviceName
        summary.peerDeviceId = peer.deviceId

        let skew = peer.clock.timeIntervalSince(identity.clock)
        if abs(skew) > Self.tolerableSkew { summary.clockSkew = skew }

        let mine = await source.manifest()
        let theirs: SyncMessage.Manifest
        switch role {
        case .client:
            try await send(.manifest(mine))
            theirs = try await expectManifest()
        case .server:
            theirs = try await expectManifest()
            try await send(.manifest(mine))
        }

        // Positions first, and before any bytes move: they are the thing most
        // worth having if the connection drops halfway through a gigabyte of
        // audio, and they cost nothing.
        let newer = SyncDiff.newerProgress(mine: mine.progress, theirs: theirs.progress)
        if !newer.isEmpty {
            await source.mergeProgress(newer)
            summary.progressMerged = newer.count
        }

        // Their asks, before the transfers rather than after: a request is
        // cheap to accept and a session that dies halfway through a gigabyte of
        // audio should still have started the next chapter rendering. What
        // comes back is a status per ask, which the other side picks up
        // wherever it is in the conversation — see `next()`.
        let accepted = await source.acceptConvertRequests(theirs.convertRequests)
        summary.convertRequestsAccepted = accepted.count
        for status in accepted { try await send(.jobStatus(status)) }

        let want = SyncDiff.want(mine: mine, theirs: theirs, audioIsWanted: wantsAudio)
        switch role {
        case .client:
            try await send(.want(SyncMessage.Want(items: want)))
            try await receiveFiles(expecting: want, into: &summary)
            let theirWant = try await expectWant()
            try await serve(theirWant.items, into: &summary)
            try await send(.bye)
        case .server:
            let theirWant = try await expectWant()
            try await serve(theirWant.items, into: &summary)
            try await send(.want(SyncMessage.Want(items: want)))
            try await receiveFiles(expecting: want, into: &summary)
            _ = try? await next()  // their bye
        }
        summary.jobUpdates = jobUpdates
        return summary
    }

    // MARK: - Handshake

    private func handshake() async throws -> SyncMessage.Hello {
        let peer: SyncMessage.Hello
        switch role {
        case .client:
            try await send(.hello(identity))
            guard case .helloAck(let hello) = try await next() else {
                throw SyncError.handshakeFailed("expected a reply to hello")
            }
            peer = hello
        case .server:
            guard case .hello(let hello) = try await next() else {
                throw SyncError.handshakeFailed("expected hello")
            }
            peer = hello
            try await send(.helloAck(identity))
        }

        peerAcceptsAAC = peer.accepts(.aac)

        guard identity.canTalk(to: peer) else {
            throw SyncError.incompatibleVersion(
                theirs: peer.protocolVersion, mine: identity.protocolVersion
            )
        }
        return peer
    }

    // MARK: - Sending files

    private func serve(_ items: [WantItem], into summary: inout Summary) async throws {
        for item in items {
            // Something asked for and then deleted between building the
            // manifest and being asked for it. Not an error: the next session's
            // manifest will not offer it.
            guard let wav = try await source.data(for: item) else { continue }

            // Compressed for the crossing only. A failure here is not worth
            // failing the transfer over — the uncompressed bytes are right
            // there, and a chapter that arrives slowly beats one that does not
            // arrive.
            var data = wav
            var codec: AudioManifest.Codec?
            if case .audio = item, peerAcceptsAAC {
                do {
                    let compressed = try ChunkPack.aac(from: wav)
                    // The container costs about 33 kB whatever it holds, so a
                    // transfer of one short chunk is genuinely smaller
                    // uncompressed. Sending the smaller of the two is a
                    // one-line rule that needs no threshold to tune.
                    if compressed.count < wav.count {
                        data = compressed
                        codec = .aac
                    }
                } catch {
                    PlaybackLog.note("sync: \(item.key) would not encode: \(error)")
                }
            }

            try await send(
                .fileHeader(
                    SyncMessage.FileHeader(
                        item: item,
                        size: Int64(data.count),
                        sha256: ContentIdentity.hash(of: data),
                        codec: codec
                    )
                )
            )
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: Self.blobChunk, limitedBy: data.endIndex)
                    ?? data.endIndex
                try await transport.send(Frame(kind: .blob, payload: Data(data[offset..<end])))
                offset = end
            }
            try await send(.fileDone(SyncMessage.FileDone(item: item)))
            summary.sent += 1
            summary.bytesSent += Int64(data.count)
        }
    }

    // MARK: - Receiving files

    /// Take delivery of everything asked for, in whatever order it arrives.
    ///
    /// The loop ends when the other side stops sending headers, which it
    /// signals by moving on to its own `want`. Anything not delivered is simply
    /// still missing, and will be asked for again next time.
    private func receiveFiles(
        expecting want: [WantItem], into summary: inout Summary
    ) async throws {
        guard !want.isEmpty else { return }
        var outstanding = Set(want)

        while !outstanding.isEmpty {
            let message = try await next()
            switch message {
            case .fileHeader(let header):
                let data = try await receiveBlobs(for: header)
                outstanding.remove(header.item)
                // A file that arrives damaged is dropped rather than stored.
                // The manifest diff will ask for it again, and a chapter of
                // static is worse than a chapter that is not there yet.
                guard ContentIdentity.hash(of: data) == header.sha256 else {
                    PlaybackLog.note("sync: \(header.item.key) failed its hash check")
                    continue
                }
                // Back to WAV before the library sees it: what crosses is an
                // encoding, not a storage format.
                var payload = data
                if header.codec == .aac {
                    do {
                        payload = try ChunkPack.wav(fromAAC: data)
                    } catch {
                        PlaybackLog.note("sync: \(header.item.key) would not decode: \(error)")
                        continue  // still missing, so the next diff asks again
                    }
                }
                try await source.receive(header.item, data: payload)
                summary.received += 1
                summary.bytesReceived += Int64(data.count)

            case .want, .bye:
                // They have nothing more to send. Push the message back is not
                // possible, so handle it here: the caller's next step is
                // exactly this message.
                pushedBack = message
                return

            case .progressSet(let set):
                await source.mergeProgress(set.records)
                summary.progressMerged += set.records.count

            default:
                throw SyncError.unexpectedMessage("\(message)")
            }
        }
    }

    /// Blob frames up to the matching `fileDone`.
    private func receiveBlobs(for header: SyncMessage.FileHeader) async throws -> Data {
        var data = Data(capacity: Int(header.size))
        while true {
            guard let frame = try await transport.receive() else { throw SyncError.closed }
            switch frame.kind {
            case .blob:
                data.append(frame.payload)
            case .control:
                let message = try SyncMessage.decode(frame)
                guard case .fileDone(let done) = message, done.item == header.item else {
                    throw SyncError.unexpectedMessage("\(message) inside \(header.item.key)")
                }
                return data
            }
        }
    }

    // MARK: - Message plumbing

    /// A control message read while looking for something else.
    private var pushedBack: SyncMessage?

    private func send(_ message: SyncMessage) async throws {
        try await transport.send(try message.frame())
    }

    /// How many job statuses came in, wherever in the conversation they landed.
    private var jobUpdates = 0

    /// The next message that is part of the conversation.
    ///
    /// Job statuses are not: they are the other device answering something this
    /// one asked in its manifest, and they can arrive at any point between the
    /// manifests and the goodbye. Swallowing them here rather than at each call
    /// site is what lets that be true — a phone with an empty want list never
    /// enters the receive loop at all, and used to meet a status where it
    /// expected a want.
    private func next() async throws -> SyncMessage {
        while true {
            let message = try await nextMessage()
            guard case .jobStatus(let status) = message else { return message }
            await source.receive(jobStatus: status)
            jobUpdates += 1
        }
    }

    private func nextMessage() async throws -> SyncMessage {
        if let pushedBack {
            self.pushedBack = nil
            return pushedBack
        }
        guard let frame = try await transport.receive() else { throw SyncError.closed }
        guard frame.kind == .control else {
            throw SyncError.unexpectedMessage("a blob with no file open")
        }
        return try SyncMessage.decode(frame)
    }

    private func expectManifest() async throws -> SyncMessage.Manifest {
        guard case .manifest(let manifest) = try await next() else {
            throw SyncError.unexpectedMessage("something other than a manifest")
        }
        return manifest
    }

    private func expectWant() async throws -> SyncMessage.Want {
        let message = try await next()
        guard case .want(let want) = message else {
            // A peer with nothing to ask for still sends an empty want, so this
            // really is a protocol error rather than a shortcut.
            throw SyncError.unexpectedMessage("\(message) instead of a want")
        }
        return want
    }
}
