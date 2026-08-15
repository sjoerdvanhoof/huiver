import Foundation

/// Given what I have and what you have, what should I ask you for?
///
/// Pure, synchronous, and the only place the "what to transfer" decision is
/// made. Everything about a sync session that is worth being sure of lives
/// here, so it is written as a function of two manifests rather than as
/// something that happens while sockets are open.
public enum SyncDiff {
    /// What one side wants from the other.
    ///
    /// `audioIsWanted` is a policy knob rather than a constant because the two
    /// directions differ: the Mac renders faster than the phone ever will, so
    /// audio flows Mac → phone and the Mac does not ask for the phone's.
    public static func want(
        mine: SyncMessage.Manifest,
        theirs: SyncMessage.Manifest,
        audioIsWanted: Bool = true
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
                if audioIsWanted { items.append(contentsOf: audioWants(for: book, having: nil)) }
                continue
            }
            // Known book, but the file itself never made it across.
            if book.hasEpub, !local.hasEpub {
                items.append(.epub(contentId: book.contentId))
            }
            if audioIsWanted {
                items.append(contentsOf: audioWants(for: book, having: local))
            }
        }

        let mineVoices = Set(mine.voices.map(\.id))
        for voice in theirs.voices where !mineVoices.contains(voice.id) {
            items.append(.voice(id: voice.id))
            if voice.hasPreview { items.append(.voicePreview(id: voice.id)) }
        }
        return items
    }

    /// Which chunks of which chapters are worth asking for.
    private static func audioWants(
        for remote: BookManifest, having local: BookManifest?
    ) -> [WantItem] {
        var items: [WantItem] = []
        let localChapters = Dictionary(
            (local?.chapters ?? []).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for chapter in remote.chapters {
            guard let audio = chapter.audio, audio.renderedChunks > 0 else { continue }
            let mine = localChapters[chapter.index]

            // Two devices can only trade audio if they agree on where the
            // chunks begin. Different text, or a different chunker, means the
            // files are not interchangeable however similar the chapter looks.
            if let mine {
                guard mine.textHash == chapter.textHash,
                      mine.chunkerVersion == chapter.chunkerVersion
                else { continue }
            }

            // Audio rendered in a voice we are not using is not worth the
            // bandwidth; the local render, if any, wins.
            let alreadyHave: Int
            if let existing = mine?.audio, existing.voiceId == audio.voiceId {
                alreadyHave = existing.renderedChunks
            } else if mine?.audio != nil {
                // A different voice on this side. Taking theirs would mean
                // discarding ours, which is the listener's call, not sync's.
                continue
            } else {
                alreadyHave = 0
            }

            guard audio.renderedChunks > alreadyHave else { continue }
            items.append(
                .audio(
                    contentId: remote.contentId,
                    chapterIndex: chapter.index,
                    voiceId: audio.voiceId,
                    chunks: Array(alreadyHave..<audio.renderedChunks)
                )
            )
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
