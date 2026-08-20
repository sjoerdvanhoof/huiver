import CoreML
import Foundation

/// Turning a recording into a voice, on this machine.
///
/// Until now cloning happened in Python: `export_voices.py` on the Mac, because
/// a voice is five tensors and producing them needs three networks neither app
/// carried — a speech tokenizer, an LSTM speaker encoder and an x-vector net —
/// plus four different mel front-ends. `MTLVoiceCloner` is all of that in one
/// Core ML package, so the app can do it itself.
///
/// ```
/// ten seconds at 24 kHz
///   ├─ speaker_emb   (256)       who is speaking            → T3
///   ├─ cond_prompt   (150)       six seconds, as tokens      → T3
///   ├─ prompt_token  (250)       ten seconds, as tokens      → S3Gen
///   ├─ prompt_feat   (500, 80)   the same ten as mel         → S3Gen
///   └─ embedding     (192)       an x-vector                 → S3Gen
/// ```
///
/// The recording never leaves the Mac, and none of those five can be turned
/// back into it.
public actor VoiceCloner {
    public static let modelName = "MTLVoiceCloner.mlmodelc"

    public enum CloneError: Error, LocalizedError {
        case unavailable
        case silent
        case tooShort(Double)
        case badOutput(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                """
                These models cannot clone a voice. Cloning needs the \
                multilingual export — run bun run mac:models && bun run mac:install.
                """
            case .silent:
                "That recording is silent. Check the input device and try again."
            case .tooShort(let seconds):
                """
                That is \(String(format: "%.1f", seconds)) seconds of speech; a \
                voice needs about ten. Read a couple more sentences.
                """
            case .badOutput(let what):
                "The cloning model produced no \(what)."
            }
        }
    }

    /// Whether these installed models can clone at all. Nano's export has no
    /// cloner, and neither did the multilingual one before this existed.
    public static func isAvailable(in models: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: models.appendingPathComponent(modelName).path
        )
    }

    private let model: MLModel
    /// Where the model ran, for the same reason the engine reports it.
    public let placement: String

    public init(models: URL) async throws {
        let url = models.appendingPathComponent(Self.modelName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CloneError.unavailable
        }
        (model, placement) = try await ComputeUnits.load("MTLVoiceCloner", url)
    }

    /// An `MLMultiArray`'s logical contents, in order.
    ///
    /// Not `Array(buffer)`, which is the obvious thing and is wrong: Core ML
    /// pads the backing storage for alignment, so a 250-token output arrives in
    /// a 256-long buffer and reading it whole appends six tokens of whatever
    /// was in memory. Silently, and only for some shapes — the mel came back
    /// exactly 500×80 while both token arrays were padded — which is the kind
    /// of bug that ships. The strides say where the real elements are.
    static func flatten<T: MLShapedArrayScalar>(_ array: MLMultiArray, as type: T.Type) -> [T] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let total = shape.reduce(1, *)
        var out = [T]()
        out.reserveCapacity(total)
        array.withUnsafeBufferPointer(ofType: T.self) { buffer in
            var index = [Int](repeating: 0, count: shape.count)
            for _ in 0..<total {
                let offset = zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 }
                out.append(buffer[offset])
                // Odometer over the logical indices, last axis fastest.
                var axis = shape.count - 1
                while axis >= 0 {
                    index[axis] += 1
                    if index[axis] < shape[axis] { break }
                    index[axis] = 0
                    axis -= 1
                }
            }
        }
        return out
    }

    /// How little speech is not worth cloning from.
    ///
    /// Four seconds is already thin — the reference is what the model has to
    /// infer a whole voice from — but refusing at ten would refuse most
    /// recordings for being a second short, and a short clip is padded rather
    /// than broken.
    public static let minimumSeconds = 4.0

    /// Clone a recording. `recording` is mono 24 kHz, any length.
    public func clone(
        _ recording: [Float],
        id: String,
        name: String,
        detail: String,
        persona: String? = nil,
        language: String? = nil
    ) throws -> Voice {
        let choice = ReferenceClip.prepare(recording)
        guard choice.peak > 0.005 else { throw CloneError.silent }
        guard choice.availableSeconds >= Self.minimumSeconds else {
            throw CloneError.tooShort(choice.availableSeconds)
        }

        let input = try MLMultiArray(
            shape: [1, NSNumber(value: ReferenceClip.samples)], dataType: .float32
        )
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: choice.samples)
        }
        let out = try model.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: ["wav24": input])
        )

        func floats(_ feature: String) throws -> [Float] {
            guard let array = out.featureValue(for: feature)?.multiArrayValue else {
                throw CloneError.badOutput(feature)
            }
            return Self.flatten(array, as: Float.self)
        }
        func tokens(_ feature: String) throws -> [Int32] {
            guard let array = out.featureValue(for: feature)?.multiArrayValue else {
                throw CloneError.badOutput(feature)
            }
            return Self.flatten(array, as: Int32.self)
        }

        return Voice(
            id: id,
            name: name,
            detail: detail,
            persona: persona,
            language: language,
            speakerEmbedding: try floats("speaker_emb"),
            condPromptTokens: try tokens("cond_prompt_tokens"),
            promptTokens: try tokens("prompt_token"),
            promptFeatures: try floats("prompt_feat"),
            xvector: try floats("embedding")
        )
    }
}
