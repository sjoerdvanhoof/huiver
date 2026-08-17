import Accelerate
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
        case voiceMismatch(String, Int, Int)

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
            case .voiceMismatch(let what, let got, let want):
                "Voice \(what) is \(got) values; these models want \(want). Re-run: bun run ios:voices"
            }
        }
    }

    /// Fixed by the checkpoint, and needed by callers writing WAV headers, so
    /// it does not belong behind the actor.
    public nonisolated let sampleRate = 24000

    /// Replaceable — see `reload`, which swaps each one for a freshly loaded
    /// copy. Never nil: the actor suspends inside `reload`, and a `speak`
    /// queued behind that suspension must find a working model, old or new.
    private var prefill: MLModel
    private var decode: MLModel
    private var flow: MLModel
    private var vocoder: MLModel
    /// The decode model's KV cache, kept between chunks rather than allocated
    /// per chunk (~62 MB a time). Belongs to exactly one `MLModel`, so it is
    /// dropped when `reload` replaces `decode`.
    private var decodeState: MLState?
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

    // What the models expect of a voice, read off their input shapes so a
    // stale or foreign voice file throws `voiceMismatch` instead of trapping
    // inside a buffer copy.
    private let speakerEmbeddingSize: Int
    private let xvectorSize: Int
    private let melDimension: Int

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
    /// silently, and it can differ per model and per device. Refreshed by
    /// `reload`, so it tracks the models actually in use.
    public private(set) var placement: [String: String]

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
    ///
    /// The models are replaced one at a time, each loaded into a local and only
    /// then assigned. Two things depend on that shape. Loading a whole second
    /// set beside the first needs twice 736 MB of weights, and iOS answers that
    /// by killing the app — silently, with no crash report — so the high-water
    /// mark must stay near one set plus the single model being swapped. And the
    /// actor suspends at every `await` here; it is reentrant, so a `speak`
    /// queued by the other consumer runs *during* a reload and must find every
    /// model present — old or new, never nil. (An earlier version nil-ed each
    /// field before loading its replacement, which crashed exactly there.)
    ///
    /// Narrator and Converter can both ask for a reload on the same foreground
    /// event; the second caller joins the pass already running rather than
    /// starting a second one, which would put two full sets in flight.
    public func reload() async throws {
        if reloadTask == nil {
            reloadTask = Task {
                defer { reloadTask = nil }
                try await performReload()
            }
        }
        guard let task = reloadTask else { return }
        try await task.value
    }

    /// A reload in flight, shared by every caller that arrives while it runs.
    private var reloadTask: Task<Void, Error>?

    private func performReload() async throws {
        // A throw anywhere here leaves every model loaded — some old, some
        // new, all working. The caller can simply try again.
        var label: String
        (prefill, label) = try await Self.load("T3Prefill", source.prefill, using: Self.ladder)
        placement["T3Prefill"] = label
        (decode, label) = try await Self.load("T3Decode", source.decode, using: Self.ladder)
        placement["T3Decode"] = label
        // The cached state belongs to the model instance just replaced.
        decodeState = nil
        (flow, label) = try await Self.load("S3Flow", source.flow, using: Self.ladder)
        placement["S3Flow"] = label
        (vocoder, label) = try await Self.load("S3Vocoder", source.vocoder, using: Self.ladder)
        placement["S3Vocoder"] = label
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

        func lastDimension(_ model: MLModel, _ modelName: String, _ input: String) throws -> Int {
            guard let shape = model.modelDescription.inputDescriptionsByName[input]?
                .multiArrayConstraint?.shape,
                let last = shape.last
            else { throw EngineError.missingMetadata(modelName, "\(input) shape") }
            return last.intValue
        }
        speakerEmbeddingSize = try lastDimension(prefill, "T3Prefill", "speaker_emb")
        xvectorSize = try lastDimension(flow, "S3Flow", "embedding")
        melDimension = try lastDimension(flow, "S3Flow", "prompt_feat")
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
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false,
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> [Float] {
        try validate(voice)
        var audio: [Float] = []
        let pieces = splitToFit(text)
        for (index, piece) in pieces.enumerated() {
            if cancelled() { break }
            let tokens = try generateSpeechTokens(
                for: piece,
                voice: voice,
                options: options,
                // The seams an emergency split adds are themselves mid-sentence.
                beginsMidSentence: beginsMidSentence || index > 0,
                endsMidSentence: endsMidSentence || index < pieces.count - 1,
                cancelled: cancelled
            )
            if tokens.isEmpty { continue }
            audio += try decodeToAudio(tokens: tokens, voice: voice)
        }
        return audio
    }

    /// A voice whose tensors do not match the loaded models must fail here,
    /// as an error naming the mismatch — further in it is a trap inside a
    /// buffer copy, or worse, a silently wrong shape.
    private func validate(_ voice: Voice) throws {
        let wants: [(String, Int, Int)] = [
            ("speaker embedding", voice.speakerEmbedding.count, speakerEmbeddingSize),
            ("conditioning tokens", voice.condPromptTokens.count, condPrefixLength - 1),
            ("prompt tokens", voice.promptTokens.count, promptTokenLength),
            ("prompt features", voice.promptFeatures.count, promptFeatureLength * melDimension),
            ("x-vector", voice.xvector.count, xvectorSize),
        ]
        for (what, got, want) in wants where got != want {
            throw EngineError.voiceMismatch(what, got, want)
        }
    }

    /// The chunker budgets in characters against an English ~4 chars/token;
    /// text that tokenizes worse — degenerate ASCII, non-Latin scripts — can
    /// blow the prefill ceiling anyway. Rather than failing the chunk (which
    /// used to abort the whole chapter), split it at a word boundary near the
    /// middle and speak the pieces one after another. Rare enough that the
    /// prosody reset at the join is acceptable; dropped words would not be.
    private func splitToFit(_ text: String) -> [String] {
        // Measured with `PuncNorm`'s default shape; the real call may add a
        // token or two (a trailing stop, a capitalisation), so a small margin
        // keeps a piece measured here from being refused there.
        guard tokenizer.encode(PuncNorm.apply(text)).count > maxTextTokens - 4 else { return [text] }
        let words = text.split(whereSeparator: \.isWhitespace)
        // A single unbreakable over-long word is left for `generateSpeechTokens`
        // to refuse; there is nothing sayable to salvage from it.
        guard words.count > 1 else { return [text] }
        let head = words[..<(words.count / 2)].joined(separator: " ")
        let tail = words[(words.count / 2)...].joined(separator: " ")
        return splitToFit(head) + splitToFit(tail)
    }

    // MARK: - T3, the token loop

    func generateSpeechTokens(
        for text: String,
        voice: Voice,
        options: SamplingOptions,
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false,
        cancelled: @Sendable () -> Bool
    ) throws -> [Int32] {
        let normalized = PuncNorm.apply(
            text, beginsMidSentence: beginsMidSentence, endsMidSentence: endsMidSentence
        )
        let textTokens = tokenizer.encode(normalized).map(Int32.init)
        guard !textTokens.isEmpty else { return [] }
        guard textTokens.count <= maxTextTokens else {
            throw EngineError.textTooLong(textTokens.count, maxTextTokens)
        }

        let prefixLength = condPrefixLength + textTokens.count + 1
        // What the KV cache has room for. The export sized `maxContext` as
        // prefix + maxTextTokens + 1 + a 1000-token generation budget
        // (`MAX_GEN_TOKENS` in tools/export/common.py), so for text shorter
        // than the ceiling this exceeds that budget by the unused text room.
        // Deliberate and safe: every position still fits the cache, and the
        // headroom only matters for a chunk that would otherwise be cut off.
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

        // The state is ~62 MB of KV cache, so it is made once and reused for
        // every chunk. Safe: `seed` rewrites everything up to `prefixLength`,
        // and the decode model masks every slot above the position it is
        // given, so a longer previous chunk's leftovers are never read.
        let state: MLState
        if let cached = decodeState {
            state = cached
        } else {
            state = decode.makeState()
            decodeState = state
        }
        seed(state: state, keys: keys, values: values, length: prefixLength)

        var sampler = Sampler(options: options)
        var generated: [Int32] = []
        // The repetition penalty starts against the start-of-speech token, as
        // it does upstream, and switches to the real history after the first.
        var penalized: Set<Int32> = [startSpeechToken]

        let tokenInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let positionInput = try MLMultiArray(shape: [1], dataType: .int32)
        // One feature provider and one output buffer for the whole loop — the
        // provider reads the arrays above by reference, and the backing spares
        // Core ML allocating a fresh logits array per token.
        let stepInput = try MLDictionaryFeatureProvider(dictionary: [
            "token": tokenInput, "position": positionInput,
        ])
        let stepOptions = MLPredictionOptions()
        stepOptions.outputBackings = [
            "logits": try MLMultiArray(shape: [1, NSNumber(value: vocabulary)], dataType: .float32),
        ]

        var current = sample(&sampler, logits, history: penalized)
        for step in 0..<budget {
            if current == stopSpeechToken || cancelled() { break }
            generated.append(current)
            if generated.count == 1 { penalized.remove(startSpeechToken) }
            penalized.insert(current)

            tokenInput[0] = NSNumber(value: current)
            positionInput[0] = NSNumber(value: Int32(prefixLength + step))
            let out = try decode.prediction(from: stepInput, using: state, options: stepOptions)
            guard let next = out.featureValue(for: "logits")?.multiArrayValue else {
                throw EngineError.badOutput("decode logits")
            }
            current = sample(&sampler, next, history: penalized)
        }
        if current != stopSpeechToken, generated.count < budget { generated.append(current) }
        if current != stopSpeechToken, generated.count >= budget, !cancelled() {
            // The words past the budget are dropped, and nothing downstream
            // can tell — the fade-out hides even the click. Rare by
            // construction (the chunker sizes chunks well inside the budget),
            // so when it does happen it should at least be in the log.
            PlaybackLog.note(
                "t3: hit the \(budget)-token budget mid-sentence; "
                    + "the tail of a \(textTokens.count)-text-token chunk was dropped"
            )
        }

        // Control tokens live at and above the start-of-speech id. The mel
        // decoder's embedding table stops below them, so one that slips through
        // is read as noise rather than rejected.
        return generated.filter { $0 < startSpeechToken }
    }

    private func sample(_ sampler: inout Sampler, _ logits: MLMultiArray, history: Set<Int32>) -> Int32 {
        logits.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            assert(buffer.count == vocabulary, "logits are \(buffer.count) wide, not \(vocabulary)")
            return sampler.next(logits: buffer, history: history)
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
        for (name, source) in [("k_cache", keys), ("v_cache", values)] {
            // Derived from the arrays rather than hardcoded, so an export at a
            // different precision fails loudly here instead of scrambling the
            // cache with a wrong stride.
            let element = source.dataType == .float16 ? 2 : 4
            let row = length * headDim * element
            let stride = maxContext * headDim * element
            let rows = layers * heads

            // The source pointer crosses into the destination's closure in a
            // plain box: holding it directly there trips Swift 6's
            // concurrency checking, and the box costs nothing where the old
            // workaround copied ~9 MB into an array first.
            struct Span: @unchecked Sendable {
                let base: UnsafeRawPointer
            }
            source.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                let span = Span(base: base)
                state.withMultiArray(for: name) { destination in
                    assert(
                        destination.dataType == source.dataType,
                        "prefill emits \(source.dataType), the decode cache holds \(destination.dataType)"
                    )
                    destination.withUnsafeMutableBytes { raw, _ in
                        guard let dst = raw.baseAddress else { return }
                        for index in 0..<rows {
                            dst.advanced(by: index * stride)
                                .copyMemory(from: span.base.advanced(by: index * row), byteCount: row)
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
        guard !tokens.isEmpty else { return [] }
        var audio: [Float] = []

        for step in Self.windowPlan(
            tokenCount: tokens.count, window: genTokens, runUp: Self.runUpTokens,
            tail: Self.tailTokens
        ) {
            let piece = try decodeWindow(Array(tokens[step.start..<step.end]), voice: voice)
            let from = (step.keepFrom - step.start) * tokenMelRatio * hop
            let to = min((step.keepUntil - step.start) * tokenMelRatio * hop, piece.count)
            guard from < to else { continue }

            // The seam is an equal-power crossfade, not a dip: the run-up
            // means this window also rendered the last few milliseconds the
            // previous one kept, so the two versions of that same moment are
            // blended — where ramping each side to zero left a five-
            // millisecond notch of silence at every window join.
            let overlap = min(seamRamp, from, audio.count)
            if overlap > 1 {
                for i in 0..<overlap {
                    let t = Float(i) / Float(overlap - 1)
                    audio[audio.count - overlap + i] =
                        audio[audio.count - overlap + i] * cosf(.pi / 2 * t)
                        + piece[from - overlap + i] * sinf(.pi / 2 * t)
                }
            }
            audio += piece[from..<to]
        }

        fadeIn(&audio)
        // Every chunk ends at zero, whatever happened. The renderer appends a
        // quarter-second of silence to each one, and a chunk whose last sample
        // is not near zero clicks as it meets that silence — which is also what
        // a chunk cut short by the token budget would do.
        fadeOut(&audio)
        return audio
    }

    /// Tokens of already-spoken context handed to a window that is not the
    /// first, and then thrown away. Two and a half seconds.
    ///
    /// The mel decoder is not autoregressive: it renders a window of tokens
    /// against the voice's reference clip and nothing else. A window starting
    /// cold therefore begins the way an utterance begins — pitch and pace
    /// reset to the reference baseline — which at a join in the middle of a
    /// sentence is heard as the reader stopping and starting again. Giving it
    /// the preceding tokens to run up to the join, and keeping only what comes
    /// after, means the audio we use was rendered mid-sentence.
    static let runUpTokens = 64

    /// Tokens dropped from the end of a window that is not the last.
    ///
    /// The last tokens before a window edge are rendered against silence
    /// padding rather than the speech that actually follows them, so their
    /// audio is subtly wrong even though no words are clipped (`windowPlan`
    /// reserves room for the three silence tokens). The next window re-renders
    /// this stretch with proper run-up, so it is dropped here rather than
    /// heard.
    static let tailTokens = 8

    /// One window's worth of work: which tokens to decode, and which slice of
    /// the resulting audio to keep.
    struct WindowStep: Equatable {
        let start: Int
        let end: Int
        /// First token whose audio is kept. Between `start` and this is run-up.
        let keepFrom: Int
        let keepUntil: Int
    }

    /// How to cover `tokenCount` tokens with overlapping windows.
    ///
    /// Pure arithmetic, kept apart from Core ML so the awkward part — that the
    /// kept slices tile the whole run exactly once, in order, with no gap and
    /// no repeat — can be tested without a model.
    static func windowPlan(
        tokenCount: Int, window: Int, runUp: Int, tail: Int
    ) -> [WindowStep] {
        // Three silence tokens have to fit alongside the content or the window
        // ends on a clipped word, so that is the content a window can hold —
        // not `window` itself.
        let capacity = window - 3
        guard tokenCount > capacity else {
            return [WindowStep(start: 0, end: tokenCount, keepFrom: 0, keepUntil: tokenCount)]
        }

        var steps: [WindowStep] = []
        var covered = 0
        while covered < tokenCount {
            let start = max(0, covered - runUp)
            let end = min(start + capacity, tokenCount)
            let isFinal = end == tokenCount
            // A non-final window's tail is re-rendered by its successor.
            let keepUntil = isFinal ? end : max(covered + 1, end - tail)
            steps.append(
                WindowStep(start: start, end: end, keepFrom: covered, keepUntil: keepUntil)
            )
            covered = keepUntil
        }
        return steps
    }

    /// Length of the crossfade that hides a window join: five milliseconds,
    /// long enough to remove a step, short enough that blending two slightly
    /// different renderings of the same moment cannot smear a phoneme.
    private var seamRamp: Int { sampleRate / 200 }

    /// Ramp the last few milliseconds to silence, so the file ends at zero.
    ///
    /// Scaled down rather than skipped for a very short chunk — skipping left
    /// it ending off zero, which clicks against the silence appended after it.
    private func fadeOut(_ audio: inout [Float]) {
        let ramp = min(sampleRate / 100, audio.count / 2)
        guard ramp > 1 else { return }
        for i in 0..<ramp {
            audio[audio.count - ramp + i] *= Float(ramp - 1 - i) / Float(ramp - 1)
        }
    }

    private func decodeWindow(_ window: [Int32], voice: Voice) throws -> [Float] {
        var padded = window
        // Three tokens of silence before the padding, as the desktop pipeline
        // appends, so the last word is not clipped by the window edge.
        padded += [silenceToken, silenceToken, silenceToken]
        let spoken = min(padded.count, genTokens)
        padded += Array(repeating: silenceToken, count: max(0, genTokens - padded.count))
        padded = Array(padded.prefix(genTokens))

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
    ///
    /// Scaled down rather than skipped for a very short chunk, so even a stub
    /// of audio starts and ends at zero.
    private func fadeIn(_ audio: inout [Float]) {
        let ramp = min(sampleRate / 50, audio.count / 2)
        guard ramp > 1 else { return }
        for i in 0..<ramp { audio[i] = 0 }
        for i in 0..<ramp {
            let t = Float(i) / Float(ramp)
            audio[ramp + i] *= (cosf(.pi * (1 - t)) + 1) / 2
        }
    }

    // MARK: - Buffers

    private func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        assert(values.count == out.count, "\(values.count) floats into shape \(shape)")
        out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: values)
        }
        return out
    }

    private func array(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        assert(values.count == out.count, "\(values.count) ints into shape \(shape)")
        out.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: values)
        }
        return out
    }

    /// The flow decoder starts from gaussian noise rather than generating it
    /// internally — Core ML has no random number generator, so the seed lives
    /// on this side of the boundary.
    ///
    /// Box-Muller over bulk random bits, vectorised with Accelerate: the array
    /// is ~163k floats per window, and drawing them one `Float.random` at a
    /// time was measurable against the model itself.
    private func gaussian(shape: [Int]) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        let count = out.count
        guard count > 0 else { return out }
        let pairs = (count + 1) / 2

        var bits = [UInt32](repeating: 0, count: pairs * 2)
        arc4random_buf(&bits, bits.count * MemoryLayout<UInt32>.size)

        // Radii from the first half of the bits, angles from the second. The
        // +0.5 keeps the uniform strictly inside (0, 1), so the log is finite.
        var radius = [Float](repeating: 0, count: pairs)
        var angle = [Float](repeating: 0, count: pairs)
        for i in 0..<pairs {
            radius[i] = Float((Double(bits[i]) + 0.5) * 0x1p-32)
            angle[i] = Float(Double(bits[pairs + i]) * 0x1p-32 * 2 * .pi)
        }
        var n = Int32(pairs)
        vvlogf(&radius, radius, &n)
        vDSP.multiply(-2, radius, result: &radius)
        vvsqrtf(&radius, radius, &n)
        var sines = [Float](repeating: 0, count: pairs)
        var cosines = [Float](repeating: 0, count: pairs)
        vvsincosf(&sines, &cosines, angle, &n)

        out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            // The two normals of a pair land in separate halves rather than
            // interleaved — they are independent, so placement is free.
            vDSP.multiply(radius, cosines, result: &cosines)
            cosines.withUnsafeBufferPointer { _ = buffer.update(fromContentsOf: $0[0..<min(pairs, count)]) }
            if count > pairs {
                vDSP.multiply(radius, sines, result: &sines)
                sines.withUnsafeBufferPointer {
                    _ = UnsafeMutableBufferPointer(rebasing: buffer[pairs...])
                        .update(fromContentsOf: $0[0..<(count - pairs)])
                }
            }
        }
        return out
    }
}
