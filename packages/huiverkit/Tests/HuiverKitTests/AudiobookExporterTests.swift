import AVFoundation
import Foundation
import Testing

@testable import HuiverKit

/// The export round trip: chunk WAVs in, a playable audiobook out, with the
/// chapter marks where the audio says they should be.
struct AudiobookExporterTests {
    /// A sine-tone WAV of the given length, standing in for a rendered chunk.
    private func chunk(seconds: Double, directory: URL, name: String) throws -> URL {
        let count = Int(seconds * Double(WavFile.sampleRate))
        let samples = (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.2 }
        let url = directory.appendingPathComponent(name)
        try WavFile.data(from: samples).write(to: url)
        return url
    }

    @Test("an exported m4b opens with the right duration and chapter names")
    func m4bRoundTrip() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let chapters = [
            AudiobookExporter.Chapter(
                title: "The First",
                chunkURLs: [
                    try chunk(seconds: 1.5, directory: directory, name: "a0.wav"),
                    try chunk(seconds: 1.0, directory: directory, name: "a1.wav"),
                ]
            ),
            AudiobookExporter.Chapter(
                title: "The Second",
                chunkURLs: [try chunk(seconds: 2.0, directory: directory, name: "b0.wav")]
            ),
        ]
        let destination = directory.appendingPathComponent("book.m4b")
        try AudiobookExporter.writeM4B(
            chapters: chapters,
            metadata: .init(title: "Round Trip", author: "A. Writer", cover: nil),
            to: destination
        )

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        // 4.5 s of audio, within AAC priming tolerance.
        #expect(abs(duration - 4.5) < 0.2)

        let groups = try await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: ["und", "en"]
        )
        #expect(groups.count == 2)
        var titles: [String] = []
        for group in groups {
            for item in group.items where item.commonKey == .commonKeyTitle {
                if let value = try await item.load(.stringValue) { titles.append(value) }
            }
        }
        #expect(titles == ["The First", "The Second"])
        // The second chapter starts where the first one's audio ends.
        #expect(abs(groups[1].timeRange.start.seconds - 2.5) < 0.1)
    }

    @Test("a chapter m4a round-trips its audio length")
    func chapterRoundTrip() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("chapter.m4a")
        try AudiobookExporter.writeChapterM4A(
            chunkURLs: [try chunk(seconds: 1.2, directory: directory, name: "c0.wav")],
            title: "Only",
            track: (1, 1),
            metadata: .init(title: "Round Trip", author: nil, cover: nil),
            to: destination
        )
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.2) < 0.2)
    }

    @Test("exporting nothing is refused, not written")
    func refusesEmpty() {
        #expect(throws: AudiobookExporter.ExportError.self) {
            try AudiobookExporter.writeM4B(
                chapters: [],
                metadata: .init(title: "Empty", author: nil, cover: nil),
                to: URL.temporaryDirectory.appendingPathComponent("empty.m4b")
            )
        }
    }
}
