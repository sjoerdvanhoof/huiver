import CoreML
import Foundation

/// Chatterbox Nano, running on the phone.
///
/// Four Core ML models, in two stages. T3 is a 12-layer GPT-2 that reads the
/// text and emits speech tokens at 25 Hz, one at a time; S3Gen turns a whole
/// run of those tokens into 24 kHz audio in one shot. So the cost of a chunk is
/// dominated by the token loop, which is why that half is split into a
/// flexible-shape prefill and a fixed-shape, stateful decode step — the decode
/// model is the only one that runs hundreds of times, and fixed shapes are what
/// let it stay on the Neural Engine.
///
/// One chunk of text in, one buffer of samples out. Splitting a chapter into
/// chunks, keeping the audio and playing it belongs to the caller.
public actor ChatterboxEngine {
    public struct Models: Sendable {
        public var prefill: URL
        public var decode: URL
        public var flow: URL
        public var vocoder: URL
        public var tokenizer: URL

        /// The layout `bun run ios:models` writes.
        public init(directory: URL) {
            prefill = directory.appendingPathComponent("T3Prefill.mlmodelc")
            decode = directory.appendingPathComponent("T3Decode.mlmodelc")
            flow = directory.appendingPathComponent("S3Flow.mlmodelc")
            vocoder = directory.appendingPathComponent("S3Vocoder.mlmodelc")
            tokenizer = directory
        }
    }

    public enum EngineError: Error, LocalizedError {
        case missingModel(URL)
        case missingMetadata(String, String)
        case textTooLong(Int, Int)
        case badOutput(String)
        case unloadable(String, String)

        public var errorDescription: String? {
            switch self {
            case .missingModel(let url):
                "Model not found: \(url.lastPathComponent). Run: bun run ios:models"
            case .missingMetadata(let model, let key):
                "\(model) was exported without '\(key)'; re-export with the current scripts"
            case .textTooLong(let got, let max):
                "Chunk is \(got) tokens, over the \(max) the prefill model was exported for"
            case .badOutput(let what): "Model produced no \(what)"
            case .unloadable(let model, let why):
                "Core ML could not load \(model) on any processor: \(why)"
            }
        }
    }

    /// Fixed by the checkpoint, and needed by callers writing WAV headers, so
    /// it does not belong behind the actor.
    public nonisolated let sampleRate = 24000

    /// Replaceable, and briefly absent: see `reload`. Implicitly unwrapped because
    /// they are nil only between being freed and being loaded again, inside a
    /// single actor-isolated call, so nothing can observe them empty.
    private var prefill: MLModel!
    private var decode: MLModel!
    private var flow: MLModel!
    private var vocoder: MLModel!
    private let tokenizer: BPETokenizer
    /// Where the models came from, kept so they can be loaded again.
    private let source: Models

    // Read out of the models rather than hardcoded, so re-exporting at a
    // different size needs no change here.
    private let condPrefixLength: Int
    private let maxTextTokens: Int
    private let maxContext: Int
    private let layers: Int
    private let heads: Int
    private let headDim: Int
    private let vocabulary: Int
    private let startSpeechToken: Int32
    private let stopSpeechToken: Int32
    private let genTokens: Int
    private let promptTokenLength: Int
    private let promptFeatureLength: Int
    private let tokenMelRatio: Int
    private let silenceToken: Int32
    private let melFrames: Int
    private let hop: Int

    /// How far along `load` is.
    ///
    /// Core ML offers no progress callback — `MLModel.load` either has the
    /// compiled model cached or spends minutes building it, and says nothing
    /// either way. So progress is reported per model, weighted by how big each
    /// one is on disk, which is the best proxy available for how long it will
    /// take. Within a model the fraction eases forward on a timer, so the bar
    /// keeps moving rather than sitting still for four minutes.
    public struct LoadProgress: Sendable {
        /// The model being prepared, for the caller to show.
        public let model: String
        public let index: Int
        public let total: Int
        /// 0...1 across the whole load. Never goes backwards.
        public let fraction: Double
    }

    /// Languages the loaded models can read.
    ///
    /// Read from the export's metadata, defaulting to English. Chatterbox Nano
    /// is English-only by construction: its text vocabulary is GPT-2's English
    /// byte-pair set and `inference_turbo` takes no language argument. Reading
    /// another language with it produces English pronunciation of foreign words
    /// rather than an error, which is worse than an error, so callers are given
    /// this list to check against.
    public nonisolated let languages: [Language]

    /// Where each model ended up running, for the settings screen.
    ///
    /// Worth surfacing rather than hiding: which processor a model gets is the
    /// single biggest thing determining how fast this app is, Core ML decides it
    /// silently, and it can differ per model and per device.
    public nonisolated let placement: [String: String]

    /// Compute units to try, hardest-working first.
    ///
    /// `.all` is not always loadable. The decode model is stateful and writes
    /// into its KV cache at an index that is only known at run time, and a
    /// device whose compiler will not specialise that for the Neural Engine
    /// fails the whole load with a bare "failed to build the model execution
    /// plan" rather than falling back on its own. So the fallback is here.
    private static let ladder: [(String, MLComputeUnits)] = [
        ("Neural Engine / GPU / CPU", .all),
        ("GPU / CPU", .cpuAndGPU),
        ("CPU", .cpuOnly),
    ]


    /// Load the models, reporting progress as each one is prepared.
    ///
    /// The first run after installing is the slow one: Core ML compiles each
    /// model for this particular device, which takes minutes and cannot be done
    /// ahead of time on the Mac. Every run after that reads the cache and is
    /// quick.
    public static func load(
        models: Models,
        progress: @escaping @Sendable (LoadProgress) -> Void = { _ in }
    ) async throws -> ChatterboxEngine {
        let (loaded, placement) = try await loadModels(models, using: ladder, progress: progress)
        return try ChatterboxEngine(
            source: models,
            prefill: loaded[0],
            decode: loaded[1],
            flow: loaded[2],
            vocoder: loaded[3],
            tokenizer: try BPETokenizer(directory: models.tokenizer),
            placement: placement
        )
    }

    /// Replace the four models with freshly loaded ones.
    ///
    /// Needed because a Core ML prediction that fails does not fail only once. Once
    /// the app has been off screen and a prediction has failed there, *every* later
    /// prediction on that `MLModel` fails too — in the foreground as much as in the
    /// background, and with a different error the second time round ("neural network
    /// model … error code -1"). The instance is finished; only a new one recovers.
    ///
    /// Quick, despite appearances: the expensive part of a first run is Core ML
    /// compiling each model for the device, and that result is cached. This reads
    /// the cache. Everything derived from the models — the metadata, the tokenizer,
    /// the language list — is the same for the same files, so only the models
    /// themselves are swapped.
    /// Each model is freed before its replacement is loaded, one at a time. Loading
    /// a second set beside the first needs twice 736 MB of weights, and iOS answers
    /// that by killing the app — silently, with no crash report, which is a
    /// miserable thing to debug. Doing them in sequence keeps the high-water mark
    /// near one set instead of two.
    public func reload() async throws {
        prefill = nil
        (prefill, _) = try await Self.load("T3Prefill", source.prefill, using: Self.ladder)
        decode = nil
        (decode, _) = try await Self.load("T3Decode", source.decode, using: Self.ladder)
        flow = nil
        (flow, _) = try await Self.load("S3Flow", source.flow, using: Self.ladder)
        vocoder = nil
        (vocoder, _) = try await Self.load("S3Vocoder", source.vocoder, using: Self.ladder)
    }

    private static func loadModels(
        _ models: Models,
        using ladder: [(String, MLComputeUnits)],
        progress: @escaping @Sendable (LoadProgress) -> Void = { _ in }
    ) async throws -> ([MLModel], [String: String]) {
        let stages = [
            ("T3Prefill", models.prefill),
            ("T3Decode", models.decode),
            ("S3Flow", models.flow),
            ("S3Vocoder", models.vocoder),
        ]
        for (_, url) in stages where !FileManager.default.fileExists(atPath: url.path) {
            throw EngineError.missingModel(url)
        }

        let sizes = stages.map { Double(directorySize($0.1)) }
        let total = max(sizes.reduce(0, +), 1)

        var loaded: [MLModel] = []
        var placement: [String: String] = [:]
        var base = 0.0
        for (index, stage) in stages.enumerated() {
            let share = sizes[index] / total
            let start = base
            progress(
                LoadProgress(
                    model: stage.0, index: index + 1, total: stages.count, fraction: start
                )
            )

            // Ease across this stage while Core ML is busy. The curve
            // approaches the stage's end without reaching it, so the bar is
            // always moving and never overtakes reality.
            let ticker = Task {
                let began = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { break }
                    let seconds = Double(began.duration(to: .now).components.seconds)
                    let eased = 1 - exp(-seconds / 90)
                    progress(
                        LoadProgress(
                            model: stage.0,
                            index: index + 1,
                            total: stages.count,
                            fraction: start + share * eased
                        )
                    )
                }
            }

            let model: MLModel
            do {
                (model, placement[stage.0]) = try await load(stage.0, stage.1, using: ladder)
            } catch {
                ticker.cancel()
                throw error
            }
            ticker.cancel()
            loaded.append(model)
            base = start + share
            progress(
                LoadProgress(
                    model: stage.0, index: index + 1, total: stages.count, fraction: base
                )
            )
        }

        return (loaded, placement)
    }

    /// Load one model, taking the best processor it will load onto.
    ///
    /// The ladder is here rather than at the call site because `.all` is not always
    /// loadable and Core ML will not fall back on its own — see `ladder`.
    private static func load(
        _ name: String,
        _ url: URL,
        using ladder: [(String, MLComputeUnits)]
    ) async throws -> (MLModel, String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.missingModel(url)
        }
        var failure: Error?
        for (label, units) in ladder {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            do {
                let model = try await MLModel.load(contentsOf: url, configuration: configuration)
                return (model, label)
            } catch {
                failure = error
            }
        }
        throw EngineError.unloadable(name, failure?.localizedDescription ?? "unknown")
    }

    /// Bytes under a `.mlmodelc`, which is a directory rather than a file.
    private static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return walker.reduce(Int64(0)) { total, item in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return total }
            return total + Int64(size)
        }
    }

    private init(
        source: Models,
        prefill: MLModel,
        decode: MLModel,
        flow: MLModel,
        vocoder: MLModel,
        tokenizer: BPETokenizer,
        placement: [String: String]
    ) throws {
        self.source = source
        self.placement = placement
        let declared = (prefill.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["languages"]
        self.languages = (declared?.split(separator: ",").map {
            Language.named(String($0).trimmingCharacters(in: .whitespaces))
        }).flatMap { $0.isEmpty ? nil : $0 } ?? [.english]
        self.prefill = prefill
        self.decode = decode
        self.flow = flow
        self.vocoder = vocoder
        self.tokenizer = tokenizer

        func meta(_ model: MLModel, _ name: String, _ key: String) throws -> Int {
            let defined = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            guard let raw = defined?[key], let value = Int(raw) else {
                throw EngineError.missingMetadata(name, key)
            }
            return value
        }

        condPrefixLength = try meta(prefill, "T3Prefill", "condPrefixLen")
        maxTextTokens = try meta(prefill, "T3Prefill", "maxTextTokens")
        maxContext = try meta(decode, "T3Decode", "maxContext")
        layers = try meta(decode, "T3Decode", "nLayer")
        heads = try meta(decode, "T3Decode", "nHead")
        headDim = try meta(decode, "T3Decode", "headDim")
        vocabulary = try meta(decode, "T3Decode", "speechVocab")
        startSpeechToken = Int32(try meta(decode, "T3Decode", "startSpeechToken"))
        stopSpeechToken = Int32(try meta(decode, "T3Decode", "stopSpeechToken"))
        genTokens = try meta(flow, "S3Flow", "genTokens")
        promptTokenLength = try meta(flow, "S3Flow", "promptTokenLen")
        promptFeatureLength = try meta(flow, "S3Flow", "promptFeatLen")
        tokenMelRatio = try meta(flow, "S3Flow", "tokenMelRatio")
        silenceToken = Int32(try meta(flow, "S3Flow", "silenceToken"))
        melFrames = try meta(vocoder, "S3Vocoder", "melFrames")
        hop = try meta(vocoder, "S3Vocoder", "hop")
    }

    /// Speak one chunk of text. Returns mono 24 kHz float samples.
    ///
    /// `cancelled` is consulted between tokens. Chatterbox is autoregressive,
    /// so there is no finer granularity to stop at — the same limitation the
    /// desktop worker has.
    public func speak(
        _ text: String,
        voice: Voice,
        options: SamplingOptions = SamplingOptions(),
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> [Float] {
        let tokens = try generateSpeechTokens(
            for: text, voice: voice, options: options, cancelled: cancelled
        )
        if tokens.isEmpty { return [] }
        return try decodeToAudio(tokens: tokens, voice: voice)
    }

    // MARK: - T3, the token loop

    func generateSpeechTokens(
        for text: String,
        voice: Voice,
        options: SamplingOptions,
        cancelled: @Sendable () -> Bool
    ) throws -> [Int32] {
        let textTokens = tokenizer.encode(PuncNorm.apply(text)).map(Int32.init)
        guard !textTokens.isEmpty else { return [] }
        guard textTokens.count <= maxTextTokens else {
            throw EngineError.textTooLong(textTokens.count, maxTextTokens)
        }

        let prefixLength = condPrefixLength + textTokens.count + 1
        let budget = min(options.maxTokens, maxContext - prefixLength)

        let prefixOut = try prefill.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "speaker_emb": try array(voice.speakerEmbedding, shape: [1, voice.speakerEmbedding.count]),
            "prompt_tokens": try array(voice.condPromptTokens, shape: [1, voice.condPromptTokens.count]),
            "text_tokens": try array(textTokens, shape: [1, textTokens.count]),
            "text_positions": try array(
                (0..<textTokens.count).map { Int32(condPrefixLength + $0) },
                shape: [1, textTokens.count]
            ),
            "bos_position": try array([Int32(condPrefixLength + textTokens.count)], shape: [1, 1]),
        ]))

        guard let logits = prefixOut.featureValue(for: "logits")?.multiArrayValue,
              let keys = prefixOut.featureValue(for: "k_cache")?.multiArrayValue,
              let values = prefixOut.featureValue(for: "v_cache")?.multiArrayValue
        else { throw EngineError.badOutput("prefill output") }

        let state = decode.makeState()
        seed(state: state, keys: keys, values: values, length: prefixLength)

        var sampler = Sampler(options: options)
        var generated: [Int32] = []
        // The repetition penalty starts against the start-of-speech token, as
        // it does upstream, and switches to the real history after the first.
        var history: [Int32] = [startSpeechToken]

        let tokenInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let positionInput = try MLMultiArray(shape: [1], dataType: .int32)

        var current = sample(&sampler, logits, history: history)
        for step in 0..<budget {
            if current == stopSpeechToken || cancelled() { break }
            generated.append(current)
            history = generated

            tokenInput[0] = NSNumber(value: current)
            positionInput[0] = NSNumber(value: Int32(prefixLength + step))
            let out = try decode.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "token": tokenInput, "position": positionInput,
                ]),
                using: state
            )
            guard let next = out.featureValue(for: "logits")?.multiArrayValue else {
                throw EngineError.badOutput("decode logits")
            }
            current = sample(&sampler, next, history: history)
        }
        if current != stopSpeechToken, generated.count < budget { generated.append(current) }

        // Control tokens live at and above the start-of-speech id. The mel
        // decoder's embedding table stops below them, so one that slips through
        // is read as noise rather than rejected.
        return generated.filter { $0 < startSpeechToken }
    }

    private func sample(_ sampler: inout Sampler, _ logits: MLMultiArray, history: [Int32]) -> Int32 {
        logits.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            sampler.next(logits: buffer, history: history)
        }
    }

    /// Copy the prefill's KV cache into the decode model's state.
    ///
    /// Both are `(layers, 1, heads, position, headDim)` float16, so each
    /// (layer, head) row is contiguous in both and this is 144 memcpys rather
    /// than an element-by-element walk. Nothing past `length` is cleared: the
    /// decode model masks every slot above the position it was given, and every
    /// slot at or below it has been written by then.
    private func seed(state: MLState, keys: MLMultiArray, values: MLMultiArray, length: Int) {
        let row = length * headDim * 2  // float16
        let stride = maxContext * headDim * 2
        let rows = layers * heads

        for (name, source) in [("k_cache", keys), ("v_cache", values)] {
            // Lifted into a plain array first. Holding a pointer into one
            // MLMultiArray while writing through another trips Swift 6's
            // concurrency checking, and at ~12 MB once per chunk the copy is
            // not worth arguing with.
            let bytes: [UInt8] = source.withUnsafeBytes { Array($0) }
            state.withMultiArray(for: name) { destination in
                destination.withUnsafeMutableBytes { raw, _ in
                    guard let dst = raw.baseAddress else { return }
                    bytes.withUnsafeBytes { src in
                        guard let src = src.baseAddress else { return }
                        for index in 0..<rows {
                            dst.advanced(by: index * stride)
                                .copyMemory(from: src.advanced(by: index * row), byteCount: row)
                        }
                    }
                }
            }
        }
    }

    // MARK: - S3Gen, tokens to audio

    /// The mel decoder is exported at one fixed length, so a run of tokens is
    /// split into windows of that length and each is padded out with the
    /// model's own silence token. Text chunks are sized to fit in one window;
    /// the loop is here for the occasional chunk where the model rambles.
    func decodeToAudio(tokens: [Int32], voice: Voice) throws -> [Float] {
        var audio: [Float] = []
        for start in stride(from: 0, to: tokens.count, by: genTokens) {
            let window = Array(tokens[start..<min(start + genTokens, tokens.count)])
            audio += try decodeWindow(window, voice: voice)
        }
        fadeIn(&audio)
        return audio
    }

    private func decodeWindow(_ window: [Int32], voice: Voice) throws -> [Float] {
        var padded = window
        // Three tokens of silence before the padding, as the desktop pipeline
        // appends, so the last word is not clipped by the window edge.
        padded += [silenceToken, silenceToken, silenceToken]
        let spoken = min(padded.count, genTokens)
        padded += Array(repeating: silenceToken, count: max(0, genTokens - padded.count))
        padded = Array(padded.prefix(genTokens))

        let melDimension = voice.promptFeatures.count / promptFeatureLength
        let melLength = (promptTokenLength + genTokens) * tokenMelRatio
        let melOut = try flow.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "prompt_tokens": try array(voice.promptTokens, shape: [1, promptTokenLength]),
            "gen_tokens": try array(padded, shape: [1, genTokens]),
            "prompt_feat": try array(
                voice.promptFeatures, shape: [1, promptFeatureLength, melDimension]
            ),
            "embedding": try array(voice.xvector, shape: [1, voice.xvector.count]),
            "noise": try gaussian(shape: [1, melDimension, melLength]),
        ]))
        guard let mel = melOut.featureValue(for: "mel")?.multiArrayValue else {
            throw EngineError.badOutput("mel")
        }

        let wavOut = try vocoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["mel": mel]))
        guard let waveform = wavOut.featureValue(for: "waveform")?.multiArrayValue else {
            throw EngineError.badOutput("waveform")
        }

        let wanted = min(spoken * tokenMelRatio * hop, waveform.count)
        return waveform.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(wanted)) }
    }

    /// Chatterbox fades the first 40 ms of every render, to keep the tail of
    /// the reference clip from bleeding into the first word.
    private func fadeIn(_ audio: inout [Float]) {
        let ramp = sampleRate / 50
        guard audio.count > ramp * 2 else { return }
        for i in 0..<ramp { audio[i] = 0 }
        for i in 0..<ramp {
            let t = Float(i) / Float(ramp)
            audio[ramp + i] *= (cosf(.pi * (1 - t)) + 1) / 2
        }
    }

    // MARK: - Buffers

    private func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: values)
        }
        return out
    }

    private func array(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        out.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: values)
        }
        return out
    }

    /// The flow decoder starts from gaussian noise rather than generating it
    /// internally — Core ML has no random number generator, so the seed lives
    /// on this side of the boundary.
    private func gaussian(shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            var index = 0
            while index < buffer.count {
                // Box-Muller: two normals per pair of uniforms.
                let u1 = Float.random(in: Float.leastNormalMagnitude..<1)
                let u2 = Float.random(in: 0..<1)
                let radius = sqrtf(-2 * logf(u1))
                buffer[index] = radius * cosf(2 * .pi * u2)
                index += 1
                if index < buffer.count {
                    buffer[index] = radius * sinf(2 * .pi * u2)
                    index += 1
                }
            }
        }
        return out
    }
}
