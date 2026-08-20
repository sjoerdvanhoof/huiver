import CoreML
import Foundation

/// Which processors a compiled model may use, and in what order to try them.
///
/// Two facts make this worth a file of its own. Core ML will *not* fall back on
/// its own — a model that fails to load on the Neural Engine fails the whole
/// load rather than trying the GPU — so the ladder has to be walked by hand.
/// And two of the multilingual packages must never be offered to the Neural
/// Engine at all: the T3 prefill's flexible text dimension takes the process
/// down while the ANE compiler works on it, and the vocoder and voice cloner
/// fail the compile outright and get retried elsewhere after wasting a minute.
///
/// The export records which is which, and this reads it out of the compiled
/// model's own `metadata.json` *before* loading — because by the time there is
/// an `MLModel` to ask, the load that would have crashed has already happened.
enum ComputeUnits {
    static let ladder: [(String, MLComputeUnits)] = [
        ("Neural Engine / GPU / CPU", .all),
        ("GPU / CPU", .cpuAndGPU),
        ("CPU", .cpuOnly),
    ]

    static func ladder(for url: URL) -> [(String, MLComputeUnits)] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = entries.first?["userDefinedMetadata"] as? [String: String],
              let declared = metadata["computeUnits"]
        else { return ladder }

        return switch declared {
        case "cpu_gpu": Array(ladder.dropFirst())
        case "cpu": [ladder[2]]
        default: ladder
        }
    }

    /// Load a compiled model, taking the best processor it will load onto.
    static func load(_ name: String, _ url: URL) async throws -> (MLModel, String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChatterboxEngine.EngineError.missingModel(url)
        }
        var failure: Error?
        for (label, units) in ladder(for: url) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            do {
                return (try await MLModel.load(contentsOf: url, configuration: configuration), label)
            } catch {
                failure = error
            }
        }
        throw ChatterboxEngine.EngineError.unloadable(
            name, failure?.localizedDescription ?? "unknown"
        )
    }
}
