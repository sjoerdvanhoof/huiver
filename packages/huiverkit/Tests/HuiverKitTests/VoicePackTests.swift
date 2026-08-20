import Foundation
import Testing

@testable import HuiverKit

/// Reading and writing voice packs.
///
/// The format is shared with `export_voices.py`, so what a round trip here
/// really checks is that the app can read what the tooling writes and the
/// tooling could read what the app writes.
struct VoicePackTests {
    func voice(id: String, name: String = "Test", language: String? = "nl") -> Voice {
        Voice(
            id: id,
            name: name,
            detail: "a test voice",
            persona: "someone",
            language: language,
            speakerEmbedding: (0..<256).map { Float($0) / 256 },
            condPromptTokens: (0..<150).map { Int32($0 * 3) },
            promptTokens: (0..<250).map { Int32($0 * 7 % 6561) },
            promptFeatures: (0..<(500 * 80)).map { Float($0 % 97) / 97 - 0.5 },
            xvector: (0..<192).map { Float($0) / 192 - 0.5 }
        )
    }

    func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-pack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a voice survives being written and read")
    func roundTrip() throws {
        let place = directory()
        defer { try? FileManager.default.removeItem(at: place) }
        let original = voice(id: "rec_me")
        try VoicePack.write(original, to: place)

        let read = try #require(try VoicePack.load(from: place).first)
        #expect(read.id == original.id)
        #expect(read.name == original.name)
        #expect(read.language == "nl")
        #expect(read.persona == original.persona)
        #expect(read.speakerEmbedding == original.speakerEmbedding)
        #expect(read.condPromptTokens == original.condPromptTokens)
        #expect(read.promptTokens == original.promptTokens)
        #expect(read.promptFeatures == original.promptFeatures)
        #expect(read.xvector == original.xvector)
    }

    @Test("two voices share a manifest rather than replacing each other")
    func manifestGrows() throws {
        let place = directory()
        defer { try? FileManager.default.removeItem(at: place) }
        try VoicePack.write(voice(id: "rec_one", name: "One"), to: place)
        try VoicePack.write(voice(id: "rec_two", name: "Two"), to: place)
        #expect(try VoicePack.load(from: place).count == 2)
    }

    @Test("re-recording a voice replaces it")
    func writeIsIdempotent() throws {
        let place = directory()
        defer { try? FileManager.default.removeItem(at: place) }
        try VoicePack.write(voice(id: "rec_me", name: "First"), to: place)
        try VoicePack.write(voice(id: "rec_me", name: "Second"), to: place)
        let loaded = try VoicePack.load(from: place)
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Second")
    }

    @Test("a deleted voice leaves neither a file nor an entry")
    func remove() throws {
        let place = directory()
        defer { try? FileManager.default.removeItem(at: place) }
        try VoicePack.write(voice(id: "rec_me"), to: place)
        try VoicePack.remove(id: "rec_me", from: place)
        #expect(try VoicePack.load(from: place).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: place.appendingPathComponent("rec_me.voice").path
            )
        )
    }

    /// The two-directory rule: the bundle ships a pack, the listener records
    /// into a writable one, and a recorded voice with a shipped id wins —
    /// because that is what re-recording a voice is supposed to mean.
    @Test("recorded voices are added to the shipped ones, and can shadow them")
    func mergesTwoDirectories() throws {
        let shipped = directory()
        let recorded = directory()
        defer {
            try? FileManager.default.removeItem(at: shipped)
            try? FileManager.default.removeItem(at: recorded)
        }
        try VoicePack.write(voice(id: "lang_nl", name: "Shipped Dutch"), to: shipped)
        try VoicePack.write(voice(id: "lv_klett", name: "Elizabeth"), to: shipped)
        try VoicePack.write(voice(id: "rec_me", name: "Me"), to: recorded)
        try VoicePack.write(voice(id: "lang_nl", name: "My Dutch"), to: recorded)

        let loaded = try VoicePack.load(from: shipped, plus: recorded)
        #expect(loaded.count == 3, "two shipped plus one recorded, with one shadowed")
        #expect(loaded.first { $0.id == "lang_nl" }?.name == "My Dutch")
        #expect(loaded.contains { $0.id == "lv_klett" })
        #expect(loaded.contains { $0.id == "rec_me" })
    }

    @Test("no recorded directory is not an error")
    func noRecordedDirectory() throws {
        let shipped = directory()
        defer { try? FileManager.default.removeItem(at: shipped) }
        try VoicePack.write(voice(id: "lang_nl"), to: shipped)
        #expect(try VoicePack.load(from: shipped, plus: nil).count == 1)
        #expect(
            try VoicePack.load(
                from: shipped, plus: shipped.appendingPathComponent("nowhere")
            ).count == 1
        )
    }
}
