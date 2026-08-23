import CoreML
import Foundation

/// Turning a recording into a voice, on this machine.
///
/// Until now cloning happened in Python: `export_voices.py` on the Mac, because
/// a voice is five tensors and producing them needs three networks neither app
/// carried — a speech tokenizer, an LSTM speaker encoder and an x-vector net —
/// plus four different mel front-ends. The cloner package is all of that in one
/// Core ML graph, so either app can do it itself.
///
/// ```
/// ten seconds at 24 kHz (fifteen for Nano)
///   ├─ speaker_emb   (256)       who is speaking             → T3
///   ├─ cond_prompt   (150 / 375) the T3's window, as tokens   → T3
///   ├─ prompt_token  (250)       the first ten, as tokens     → S3Gen
///   ├─ prompt_feat   (500, 80)   the same ten as mel          → S3Gen
///   └─ embedding     (192)       an x-vector                  → S3Gen
/// ```
///
/// Two numbers differ between the checkpoints and both are read from the
/// package rather than written down here: how long a clip it wants, and whether
/// its pipeline normalises the clip's loudness first. Nano's wants fifteen
/// seconds — its T3 asks for a 375-token conditioning prompt — and normalises
/// to −27 LUFS.
///
/// The recording never leaves the device, and none of those five tensors can be
/// turned back into it.
public actor VoiceCloner {
    /// The two packages, in the order they are looked for. `VoiceCloner` is
    /// Nano's and `MTLVoiceCloner` the multilingual one; an install has one or
    /// the other, matching the engine beside it.
    public static let modelNames = ["VoiceCloner.mlmodelc", "MTLVoiceCloner.mlmodelc"]

    public enum CloneError: Error, LocalizedError {
        case unavailable
        case silent
        case tooShort(Double)
        case badOutput(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                """
                These models cannot clone a voice. Export the cloner beside \
                them — run bun run ios:clone (or mac:clone) and install again.
                """
            case .silent:
                "That recording is silent. Check the input device and try again."
            case .tooShort(let seconds):
                """
                That is \(String(format: "%.1f", seconds)) seconds of speech, \
                which is not enough to build a voice from. Read a few more \
                sentences.
                """
            case .badOutput(let what):
                "The cloning model produced no \(what)."
            }
        }
    }

    /// The cloner installed beside these models, if either is.
    public static func installed(in models: URL) -> URL? {
        modelNames
            .map(models.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether these installed models can clone at all. An export from before
    /// the cloner existed has neither package.
    public static func isAvailable(in models: URL) -> Bool { installed(in: models) != nil }

    /// How long a clip the installed cloner wants, without loading it.
    ///
    /// A screen has to say "read for about fifteen seconds" before anyone has
    /// pressed anything, and loading 262 MB to find out the number is fifteen
    /// is not a reasonable way to find out. The compiled model's own
    /// `metadata.json` has it, the same file `ComputeUnits` reads its ladder
    /// from.
    public static func clipSeconds(in models: URL) -> Int? {
        guard let url = installed(in: models),
              let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = entries.first?["userDefinedMetadata"] as? [String: String],
              let samples = metadata["clipSamples"].flatMap(Int.init)
        else { return nil }
        return samples / ReferenceClip.sampleRate
    }

    private let model: MLModel
    /// Where the model ran, for the same reason the engine reports it.
    public nonisolated let placement: String
    /// How much audio this package was traced for, in samples at 24 kHz. Read
    /// out of the package rather than assumed: the multilingual cloner wants
    /// ten seconds and Nano's wants fifteen, and handing either the wrong
    /// number of samples is a shape error deep inside Core ML.
    public nonisolated let clipSamples: Int
    /// The loudness the clip must be at before the model sees it, when the
    /// checkpoint's own pipeline normalises. Nano's does, to −27 LUFS; the
    /// multilingual one does not, and this is nil.
    public nonisolated let targetLufs: Double?

    public nonisolated var clipSeconds: Int { clipSamples / ReferenceClip.sampleRate }

    public init(models: URL) async throws {
        guard let url = Self.installed(in: models) else { throw CloneError.unavailable }
        let name = url.deletingPathExtension().lastPathComponent
        (model, placement) = try await ComputeUnits.load(name, url)

        // The package describes itself; nothing here hardcodes a checkpoint.
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        clipSamples = metadata?["clipSamples"].flatMap(Int.init) ?? ReferenceClip.samples
        // Written as an empty string by the export when it does not apply:
        // Core ML metadata values are strings, and there is no null.
        targetLufs = metadata?["targetLufs"].flatMap(Double.init)
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
        let choice = ReferenceClip.prepare(recording, seconds: clipSeconds)
        guard choice.peak > 0.005 else { throw CloneError.silent }
        guard choice.availableSeconds >= Self.minimumSeconds else {
            throw CloneError.tooShort(choice.availableSeconds)
        }

        // Nano's pipeline normalises the clip's loudness first, and the mel the
        // decoder conditions on is a log magnitude — so skipping this does not
        // fail, it quietly makes a worse clone. See `Loudness`.
        let clip = targetLufs.map {
            Loudness.normalised(choice.samples, to: $0, sampleRate: ReferenceClip.sampleRate)
        } ?? choice.samples

        let input = try MLMultiArray(
            shape: [1, NSNumber(value: clipSamples)], dataType: .float32
        )
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: clip)
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
