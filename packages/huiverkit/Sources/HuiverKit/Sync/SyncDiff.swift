import Foundation

/// Given what I have and what you have, what should I ask you for?
///
/// Pure, synchronous, and the only place the "what to transfer" decision is
/// made. Everything about a sync session that is worth being sure of lives
/// here, so it is written as a function of two manifests rather than as
/// something that happens while sockets are open.
public enum SyncDiff {
    /// Audio is transcoded before it crosses the wire. Keep each request small
    /// enough that packing WAV, decoding it to floats and handing it to
    /// AVAudioFile cannot put several chapter-sized copies in memory at once.
    /// Eight normal speech chunks are only a few minutes of audio, while still
    /// amortising the fixed MPEG-4 container overhead well.
    static let audioChunksPerTransfer = 8

    /// What one side wants from the other.
    ///
    /// `audioIsWanted` is a policy knob rather than a constant because the two
    /// directions differ: the Mac renders faster than the phone ever will, so
    /// audio flows Mac → phone and the Mac does not ask for the phone's.
    public static func want(
        mine: SyncMessage.Manifest,
        theirs: SyncMessage.Manifest,
        audioIsWanted: Bool = true,
        preferRemoteAudio: Bool = false
    ) -> [WantItem] {
        var items: [WantItem] = []
        let minesByContent = Dictionary(
            mine.books.map { ($0.contentId, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for book in theirs.books {
            guard let local = minesByContent[book.contentId] else {
                // A book we have never seen. Take the text now; the EPUB is a
                // separate ask so that a device with fifty books does not stall
                // on fifty multi-megabyte files before showing any of them.
                items.append(.bookBundle(contentId: book.contentId))
                if book.hasEpub { items.append(.epub(contentId: book.contentId)) }
                if audioIsWanted {
                    items.append(contentsOf: audioWants(
                        for: book, having: nil, preferRemote: preferRemoteAudio
                    ))
                }
                continue
            }
            // Known book, but the file itself never made it across.
            if book.hasEpub, !local.hasEpub {
                items.append(.epub(contentId: book.contentId))
            }
            if audioIsWanted {
                items.append(contentsOf: audioWants(
                    for: book, having: local, preferRemote: preferRemoteAudio
                ))
            }
        }

        // TODO(narcisse): the Mac advertises its whole bundle, so the phone
        // pulls multilingual voices Nano cannot read (they never show — the
        // roster filters on engine.canRead — but they cost disk and transfer).
        // Filtering here needs an engine/format tag in the manifest first.
        let mineVoices = Set(mine.voices.map(\.id))
        for voice in theirs.voices where !mineVoices.contains(voice.id) {
            items.append(.voice(id: voice.id))
            if voice.hasPreview { items.append(.voicePreview(id: voice.id)) }
        }
        return items
    }

    /// Which chunks of which chapters are worth asking for.
    private static func audioWants(
        for remote: BookManifest, having local: BookManifest?, preferRemote: Bool
    ) -> [WantItem] {
        var items: [WantItem] = []
        let localChapters = Dictionary(
            (local?.chapters ?? []).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for chapter in remote.chapters {
            guard let audio = chapter.audio, audio.renderedChunks > 0 else { continue }
            let mine = localChapters[chapter.index]

            // Same words, or the files mean nothing here.
            if let mine {
                guard mine.textHash == chapter.textHash else { continue }
            }

            // Audio rendered in a voice we are not using is not worth the
            // bandwidth; the local render, if any, wins.
            let alreadyHave: Int
            if let existing = mine?.audio, existing.voiceId == audio.voiceId {
                // A paired phone must replace Nano even when both renderers use
                // the same voice id. Once the Mac copy has landed, `preferred`
                // prevents it being requested again on every session.
                alreadyHave = preferRemote && existing.preferred != true
                    ? 0 : existing.renderedChunks
            } else if mine?.audio != nil, !preferRemote {
                // A different voice on this side. Taking theirs would mean
                // discarding ours, which is the listener's call, not sync's.
                continue
            } else {
                alreadyHave = 0
            }

            // Agreeing on where the chunks begin only matters for *extending*
            // files already here — chunk 12 by one chunker is not chunk 12 by
            // another. Taking a chapter whole is different: the receiver
            // adopts the sender's boundaries along with the audio, so a
            // chunker that has moved on locally is no reason to refuse. It
            // used to be one, which is how a chunker bump quietly stopped
            // every already-rendered book from ever reaching the phone.
            if alreadyHave > 0, let mine {
                guard mine.chunkerVersion == chapter.chunkerVersion,
                      mine.chunkingProfile == chapter.chunkingProfile
                else { continue }
            }

            guard audio.renderedChunks > alreadyHave else { continue }
            // A WantItem is also the sender's transcoding boundary. Asking for
            // a whole chapter here made the Mac materialise the entire chapter
            // as WAV, Float and AVAudioPCMBuffer simultaneously; long chapters
            // drove the process into tens of gigabytes. Separate items remain
            // independently resumable because each one is committed before
            // the next starts.
            let missing = Array(alreadyHave..<audio.renderedChunks)
            for start in stride(from: 0, to: missing.count, by: audioChunksPerTransfer) {
                let end = min(start + audioChunksPerTransfer, missing.count)
                items.append(.audio(
                    contentId: remote.contentId,
                    chapterIndex: chapter.index,
                    voiceId: audio.voiceId,
                    chunks: Array(missing[start..<end])
                ))
            }
        }
        return items
    }

    /// Which of their progress records are newer than ours.
    ///
    /// Ties go to neither side — an equal timestamp means nothing changed, and
    /// picking a winner would make the merge depend on which device asked
    /// first. When two records genuinely collide at the same instant the device
    /// id breaks it, identically on both sides.
    public static func newerProgress(
        mine: [ProgressRecord], theirs: [ProgressRecord]
    ) -> [ProgressRecord] {
        let byKey = Dictionary(
            mine.map { ProgressKey(contentId: $0.contentId, chapterIndex: $0.chapterIndex) }
                .enumerated().map { ($0.element, mine[$0.offset]) },
            uniquingKeysWith: { first, _ in first }
        )
        return theirs.filter { incoming in
            let key = ProgressKey(
                contentId: incoming.contentId, chapterIndex: incoming.chapterIndex
            )
            guard let local = byKey[key] else { return true }
            if incoming.updatedAt > local.updatedAt { return true }
            if incoming.updatedAt < local.updatedAt { return false }
            // Same instant, different content: settle it with something both
            // devices can compute and agree on.
            return incoming != local && incoming.deviceId > local.deviceId
        }
    }

    private struct ProgressKey: Hashable {
        let contentId: String
        let chapterIndex: Int
    }
}
