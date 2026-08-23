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

    /// A package that says nothing takes the full ladder, Neural Engine first.
    /// No nano package wants that; see `everyInstalledModelDeclaresItsUnits`.
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

    /// Against the models actually installed, because this is a property of the
    /// export and the export is where it gets dropped.
    ///
    /// All four, including the decode step. That one loads on the Neural Engine
    /// and then fails every prediction with `ANEProgramProcessRequestDirect()
    /// Failed ... Program Inference error`, which reaches the app as Core ML's
    /// generic "invalid input data or broken/unsupported model" — and which the
    /// Mac never sees, because macOS answers an `.all` load with the GPU. An
    /// export that forgets the label leaves the phone unable to synthesise a
    /// single chunk, and nothing else in this suite would notice.
    @Test func everyInstalledModelDeclaresItsUnits() throws {
        try #require(EngineTests.installed, "Models/ not installed; run bun run ios:install")
        let models = EngineTests.root.appendingPathComponent("Models")
        for name in ["T3Prefill", "T3Decode", "S3Flow", "S3Vocoder"] {
            let url = models.appendingPathComponent("\(name).mlmodelc")
            let rungs = ComputeUnits.ladder(for: url).map(\.1)
            #expect(!rungs.contains(.all), "\(name) is still offered to the Neural Engine")
        }
    }
}
