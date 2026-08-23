import CoreML
import Foundation
import Testing

@testable import HuiverKit

/// The one thing standing between a launch and a quarter of an hour of the ANE
/// compiler is a string in a compiled model's `metadata.json`, read before the
/// load. It is worth a test that does not need a model to run: a mel decoder
/// whose `computeUnits` is dropped in an export goes straight back to grinding,
/// and the only symptom is a slow launch.
struct ComputeUnitsTests {
    /// A stand-in `.mlmodelc`: the ladder reads the metadata file and nothing
    /// else, so the directory needs no weights to answer.
    private func modelDirectory(metadata: [String: String]?) throws -> URL {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("compute-units-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let metadata {
            let entry: [[String: Any]] = [["userDefinedMetadata": metadata]]
            try JSONSerialization.data(withJSONObject: entry).write(
                to: directory.appendingPathComponent("metadata.json")
            )
        }
        return directory
    }

    @Test func declaringCPUAndGPUNeverOffersTheNeuralEngine() throws {
        let url = try modelDirectory(metadata: ["computeUnits": "cpu_gpu"])
        defer { try? FileManager.default.removeItem(at: url) }

        let rungs = ComputeUnits.ladder(for: url)
        #expect(rungs.map(\.1) == [.cpuAndGPU, .cpuOnly])
    }

    @Test func declaringCPUPinsTheModelToIt() throws {
        let url = try modelDirectory(metadata: ["computeUnits": "cpu"])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ComputeUnits.ladder(for: url).map(\.1) == [.cpuOnly])
    }

    /// A package that says nothing takes the full ladder — which is right for
    /// the decode step and wrong for everything else, so the export says.
    @Test func sayingNothingTakesTheWholeLadder() throws {
        let silent = try modelDirectory(metadata: ["genTokens": "768"])
        let bare = try modelDirectory(metadata: nil)
        defer {
            try? FileManager.default.removeItem(at: silent)
            try? FileManager.default.removeItem(at: bare)
        }

        for url in [silent, bare] {
            #expect(ComputeUnits.ladder(for: url).map(\.1) == [.all, .cpuAndGPU, .cpuOnly])
        }
    }
}
