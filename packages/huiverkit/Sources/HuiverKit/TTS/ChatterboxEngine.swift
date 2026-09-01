import Accelerate
import CoreML
import Foundation

/// Chatterbox, in either of the two sizes this project ships.
///
/// Two stages. T3 reads the text and emits speech tokens at 25 Hz, one at a
/// time; S3Gen turns a whole run of those tokens into 24 kHz audio in one
/// shot. So the cost of a chunk is dominated by the token loop — which is why
/// Nano splits it into a flexible-shape Core ML prefill and a fixed-shape,
/// stateful decode step (fixed shapes are what let it stay on the phone's
/// Neural Engine), and why the multilingual model runs the whole loop on MLX
/// instead (see `MTLDecodeMLX`), keeping Core ML only for the fixed-shape
/// conditioning encoder and for S3Gen. The multilingual T3 has no Core ML
/// path at all anymore.
///
/// ## Two models, one loop
///
/// **Nano** is the phone's: a 12-layer GPT-2 reading GPT-2's English byte
/// pairs, English only, one row per step.
///
/// **Multilingual** is the Mac's: 30 LLaMA layers, a grapheme vocabulary with a
/// language tag, and — the difference that shapes everything here —
/// **classifier-free guidance, which is not optional**. Every step computes two
/// rows, a conditional and an unconditional one, and the two are folded together
/// inside the exported model. That doubles the arithmetic and the KV cache (333
/// MB against Nano's 62), which is why one runs on a phone and the other does
/// not.
///
/// Everything variant-specific is either read out of the models' metadata or
/// switched on `variant` at exactly three places: the prefill inputs, the decode
/// inputs, and the order the sampler filters in. That is the whole difference in
/// code; the loop, the windowing and the seams are shared.
///
/// One chunk of text in, one buffer of samples out. Splitting a chapter into
/// chunks, keeping the audio and playing it belongs to the caller.
public actor ChatterboxEngine {
    public struct Models: Sendable {
        /// Which checkpoint these files came out of.
        public enum Variant: String, Sendable {
            case nano
            case multilingual
        }

        public var variant: Variant
        public var prefill: URL
        public var decode: URL
        public var flow: URL
        public var vocoder: URL
        public var tokenizer: URL
        /// The T3's weights for MLX, when the install put them beside the
        /// Core ML packages. Only the multilingual variant has them — see
        /// `MTLDecodeMLX` for why the Mac runs the token loop there instead
        /// of in Core ML.
        public var backbone: URL?
        /// The conditioning encoder that goes with `backbone`: the one piece
        /// of the prefill that is not backbone weights, kept in Core ML
        /// because its shapes are fixed.
        public var cond: URL
        /// Smaller mel-decoder windows installed beside `flow`/`vocoder`,
        /// smallest first — see the discovery in `init(directory:)`.
        public var s3Variants: [(flow: URL, vocoder: URL)] = []

        /// The layout `bun run ios:install` and `bun run mac:install` write.
        ///
        /// The multilingual packages are named `MTL*`, so both sets can sit in
        /// one folder — and if they are there, they are what this app runs. That
        /// is the whole switch: install the models you want and the engine
        /// follows, rather than a build flag deciding it.
        public init(directory: URL) {
            // The mel decoder is the marker for which set is installed: the
            // multilingual T3 runs on MLX and its Core ML pair is no longer
            // shipped at all, so the old MTLT3Prefill marker may not exist.
            let multilingual = directory.appendingPathComponent("MTLS3Flow.mlmodelc")
            let isMultilingual = FileManager.default.fileExists(atPath: multilingual.path)
            variant = isMultilingual ? .multilingual : .nano
            let prefix = isMultilingual ? "MTL" : ""
            prefill = directory.appendingPathComponent("\(prefix)T3Prefill.mlmodelc")
            decode = directory.appendingPathComponent("\(prefix)T3Decode.mlmodelc")
            flow = directory.appendingPathComponent("\(prefix)S3Flow.mlmodelc")
            vocoder = directory.appendingPathComponent("\(prefix)S3Vocoder.mlmodelc")
            tokenizer = directory
            backbone = isMultilingual
                ? directory.appendingPathComponent("MTLT3Backbone.safetensors") : nil
            cond = directory.appendingPathComponent("MTLCond.mlmodelc")

            // Smaller mel-decoder windows beside the canonical one, named
            // MTLS3Flow<N>.mlmodelc with a matching vocoder. Each is its own
            // traced graph — the conformer bakes its padding masks in at trace
            // time, so one flexible package cannot exist — and the engine
            // picks the smallest installed window that fits each run of
            // tokens, because a window's cost is paid in full however little
            // of it is used.
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            s3Variants = contents
                .filter { $0.pathExtension == "mlmodelc" }
                .compactMap { url -> (Int, flow: URL, vocoder: URL)? in
                    let name = url.deletingPathExtension().lastPathComponent
                    guard name.hasPrefix("\(prefix)S3Flow"),
                          let size = Int(name.dropFirst("\(prefix)S3Flow".count))
                    else { return nil }
                    let vocoder = directory.appendingPathComponent("\(prefix)S3Vocoder\(size).mlmodelc")
                    guard FileManager.default.fileExists(atPath: vocoder.path) else { return nil }
                    return (size, url, vocoder)
                }
                .sorted { $0.0 < $1.0 }
                .map { (flow: $0.flow, vocoder: $0.vocoder) }
        }

        /// Whether the token loop will run on MLX rather than Core ML: the
        /// weights and the conditioning model are installed and this build
        /// links MLX (the iOS app does not). When true, the Core ML prefill
        /// and decode models are not even loaded.
        var usesMLXDecode: Bool {
            #if canImport(MLX)
            guard variant == .multilingual, let backbone else { return false }
            return FileManager.default.fileExists(atPath: backbone.path)
                && FileManager.default.fileExists(atPath: cond.path)
            #else
            return false
            #endif
        }
    }

    /// Either tokenizer, behind one call.
    ///
    /// Not variations on a theme: one is byte-level BPE over English byte
    /// pairs with no unknown token, the other a grapheme vocabulary that
    /// decomposes accents and takes a language tag. What they share is text in,
    /// ids out.
    enum Tokenizing: Sendable {
        case nano(BPETokenizer)
        case multilingual(MTLTokenizer)

        func encode(_ text: String, language: Language) -> [Int32] {
            switch self {
            case .nano(let tokenizer): tokenizer.encode(text).map(Int32.init)
            case .multilingual(let tokenizer): tokenizer.encode(text, language: language.code)
            }
        }

        /// Whether this tokenizer would rather not try.
        ///
        /// Only the multilingual one ever refuses, and only for the five
        /// languages whose text needs a normaliser that is not ported —
        /// see `MTLTokenizer`. Nano refuses nothing: it reads Dutch with
        /// English pronunciation, which the app says out loud rather than
        /// hiding behind a disabled button.
        func refuses(_ language: Language) -> Bool {
            switch self {
            case .nano: false
            case .multilingual(let tokenizer): !tokenizer.canRead(language.code)
            }
        }
    }

    public enum EngineError: Error, LocalizedError {
        case missingModel(URL)
        case backboneRequired(String)
        case missingMetadata(String, String)
        case textTooLong(Int, Int)
        case badOutput(String)
        case unloadable(String, String)
        case voiceMismatch(String, Int, Int)
        case unsupportedLanguage(String)

        public var errorDescription: String? {
            switch self {
            case .missingModel(let url):
                "Model not found: \(url.lastPathComponent). Run: bun run ios:models"
            case .backboneRequired(let missing):
                """
                The multilingual engine runs its token loop on MLX and has no \
                Core ML fallback. Missing: \(missing). \
                Run: bun run mac:backbone && bun run mac:install
                """
            case .missingMetadata(let model, let key):
                "\(model) was exported without '\(key)'; re-export with the current scripts"
            case .textTooLong(let got, let max):
                "Chunk is \(got) tokens, over the \(max) the prefill model was exported for"
            case .badOutput(let what): "Model produced no \(what)"
            case .unloadable(let model, let why):
                "Core ML could not load \(model) on any processor: \(why)"
            case .voiceMismatch(let what, let got, let want):
                "Voice \(what) is \(got) values; these models want \(want). Re-run: bun run ios:voices"
            case .unsupportedLanguage(let name):
                """
                \(name) needs text preparation this app does not do — Chinese, \
                Japanese, Hebrew, Korean and Russian each need their own \
                normaliser before the model can read them.
                """
            }
        }
    }

    /// Fixed by the checkpoint, and needed by callers writing WAV headers, so
    /// it does not belong behind the actor.
    public nonisolated let sampleRate = 24000

    /// Replaceable — see `reload`, which swaps each one for a freshly loaded
    /// copy. Never nil: the actor suspends inside `reload`, and a `speak`
    /// queued behind that suspension must find a working model, old or new.
    /// `prefill` and `decode` are nil exactly when the token loop runs on MLX
    /// instead — see `Models.usesMLXDecode`; `cond` is non-nil exactly then.
    /// For Nano, `prefill` and `decode` are never nil.
    private var prefill: MLModel?
    private var decode: MLModel?
    private var cond: MLModel?
    private var flow: MLModel
    private var vocoder: MLModel
    /// One smaller mel-decoder window, loaded beside the canonical pair.
    private struct S3Window {
        var flow: MLModel
        var vocoder: MLModel
        let genTokens: Int
    }
    /// Aligned with `source.s3Variants`, so `performReload` can pair each
    /// loaded model back to its files. `decodeWindow` picks by `genTokens`.
    private var s3Windows: [S3Window]
    #if canImport(MLX)
    /// The multilingual T3 on MLX, several times faster per token than the
    /// Core ML pair — which is not loaded at all while this is present.
    private let mlxDecode: MTLDecodeMLX?
    #endif
    /// The decode model's KV cache, kept between chunks rather than allocated
    /// per chunk (~62 MB a time). Belongs to exactly one `MLModel`, so it is
    /// dropped when `reload` replaces `decode`.
    private var decodeState: MLState?
    /// The conditioning encoder's output for the last (voice, expression)
    /// pair. Chapter-constant inputs, so the whole book pays one prediction
    /// per voice. Keyed by tensor content, not just the voice id — deleting
    /// and re-recording a voice can reuse an id with different tensors.
    private var condCache: (key: String, cond: MLMultiArray)?

    /// The memo key for `condCache`.
    private static func condKey(voice: Voice, exaggeration: Float) -> String {
        var hasher = Hasher()
        hasher.combine(voice.id)
        for value in voice.speakerEmbedding { hasher.combine(value.bitPattern) }
        for token in voice.condPromptTokens { hasher.combine(token) }
        hasher.combine(exaggeration.bitPattern)
        return String(hasher.finalize())
    }
    private let tokenizer: Tokenizing
    /// Where the models came from, kept so they can be loaded again.
    private let source: Models

    /// Which checkpoint is loaded. Read by the apps to pick sampling defaults
    /// and to say what the engine is.
    public nonisolated let variant: Models.Variant

    // Read out of the models rather than hardcoded, so re-exporting at a
    // different size needs no change here.
    private let condPrefixLength: Int
    /// How many speech tokens of the reference clip a voice carries. Nano
    /// prefixes them whole, so it is the prefix minus the speaker token; the
    /// multilingual model resamples 150 of them into 32 perceiver latents, so
    /// the two numbers are unrelated and both come from metadata.
    private let condPromptLength: Int
    /// Rows per decode step: one, or two when guidance is mandatory.
    private let cfgRows: Int
    private let maxTextTokens: Int
    private let maxContext: Int
    private let layers: Int
    private let heads: Int
    private let headDim: Int
    private let vocabulary: Int
    private let startSpeechToken: Int32
    private let stopSpeechToken: Int32
    /// What the text has to be bracketed by, when the model requires it.
    ///
    /// The multilingual checkpoint does — `_ensure_BOT_EOT` asserts it — and
    /// without them the model still speaks, fluently and conditioned on
    /// something slightly other than the sentence, which is the hardest kind of
    /// wrong to notice: plausible audio in a faintly wrong accent. Nano needs
    /// nothing here, so this is nil there rather than a variant check.
    private let textBrackets: (start: Int32, stop: Int32)?
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

    /// Which processors to try, in order — see `ComputeUnits`, which the voice
    /// cloner reads the same way.
    private static var ladder: [(String, MLComputeUnits)] { ComputeUnits.ladder }

    private static func ladder(for url: URL) -> [(String, MLComputeUnits)] {
        ComputeUnits.ladder(for: url)
    }

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
        let mlx = models.usesMLXDecode
        // The multilingual T3 has exactly one implementation now. The Core ML
        // pair it replaced is not shipped, so a missing backbone is a broken
        // install to say out loud, not something to fall back from.
        if models.variant == .multilingual, !mlx {
            #if canImport(MLX)
            let missing = [models.backbone, models.cond]
                .compactMap { $0 }
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
                .map(\.lastPathComponent)
                .joined(separator: ", ")
            throw EngineError.backboneRequired(missing.isEmpty ? "MLX weights" : missing)
            #else
            throw EngineError.backboneRequired("an MLX build (this app was built without MLX)")
            #endif
        }
        let (loaded, placement) = try await loadModels(
            models, using: ladder, mlx: mlx, progress: progress
        )
        let tokenizer: Tokenizing = switch models.variant {
        case .nano: .nano(try BPETokenizer(directory: models.tokenizer))
        case .multilingual: .multilingual(try MTLTokenizer(directory: models.tokenizer))
        }
        func model(_ url: URL) throws -> MLModel {
            guard let found = loaded[url.deletingPathExtension().lastPathComponent] else {
                throw EngineError.missingModel(url)
            }
            return found
        }
        var variants: [(flow: MLModel, vocoder: MLModel)] = []
        for pair in models.s3Variants {
            variants.append((try model(pair.flow), try model(pair.vocoder)))
        }
        return try ChatterboxEngine(
            source: models,
            prefill: mlx ? nil : try model(models.prefill),
            decode: mlx ? nil : try model(models.decode),
            cond: mlx ? try model(models.cond) : nil,
            flow: try model(models.flow),
            vocoder: try model(models.vocoder),
            s3Variants: variants,
            tokenizer: tokenizer,
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
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
        var label: String
        let ladder = { (url: URL) in Self.ladder(for: url) }
        // The MLX loop has no equivalent of Core ML's poisoned-instance
        // failure mode, so when it is active there is no prefill or decode
        // model to swap — only the conditioning model.
        if prefill != nil {
            (prefill, label) = try await Self.load(name(source.prefill), source.prefill, using: ladder(source.prefill))
            placement[name(source.prefill)] = label
        }
        if decode != nil {
            (decode, label) = try await Self.load(name(source.decode), source.decode, using: ladder(source.decode))
            placement[name(source.decode)] = label
            // The cached state belongs to the model instance just replaced.
            decodeState = nil
        }
        if cond != nil {
            (cond, label) = try await Self.load(name(source.cond), source.cond, using: ladder(source.cond))
            placement[name(source.cond)] = label
            // The memo belongs to the instance just replaced.
            condCache = nil
        }
        (flow, label) = try await Self.load(name(source.flow), source.flow, using: ladder(source.flow))
        placement[name(source.flow)] = label
        (vocoder, label) = try await Self.load(name(source.vocoder), source.vocoder, using: ladder(source.vocoder))
        placement[name(source.vocoder)] = label
        for (index, pair) in source.s3Variants.enumerated() where index < s3Windows.count {
            (s3Windows[index].flow, label) = try await Self.load(
                name(pair.flow), pair.flow, using: ladder(pair.flow)
            )
            placement[name(pair.flow)] = label
            (s3Windows[index].vocoder, label) = try await Self.load(
                name(pair.vocoder), pair.vocoder, using: ladder(pair.vocoder)
            )
            placement[name(pair.vocoder)] = label
        }
    }

    private static func loadModels(
        _ models: Models,
        using ladder: [(String, MLComputeUnits)],
        mlx: Bool = false,
        progress: @escaping @Sendable (LoadProgress) -> Void = { _ in }
    ) async throws -> ([String: MLModel], [String: String]) {
        // The MLX path replaces the prefill and decode models outright, and
        // brings the small conditioning model instead; loading a gigabyte of
        // Core ML weights that would never predict is not a fallback, it is a
        // leak.
        let urls = (mlx ? [models.cond] : [models.prefill, models.decode])
            + [models.flow, models.vocoder]
            + models.s3Variants.flatMap { [$0.flow, $0.vocoder] }
        let stages = urls.map { ($0.deletingPathExtension().lastPathComponent, $0) }
        for (_, url) in stages where !FileManager.default.fileExists(atPath: url.path) {
            throw EngineError.missingModel(url)
        }

        let sizes = stages.map { Double(directorySize($0.1)) }
        let total = max(sizes.reduce(0, +), 1)

        var loaded: [String: MLModel] = [:]
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
                (model, placement[stage.0]) = try await load(
                    stage.0, stage.1, using: self.ladder(for: stage.1)
                )
            } catch {
                ticker.cancel()
                throw error
            }
            ticker.cancel()
            loaded[stage.0] = model
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
        prefill: MLModel?,
        decode: MLModel?,
        cond: MLModel?,
        flow: MLModel,
        vocoder: MLModel,
        s3Variants: [(flow: MLModel, vocoder: MLModel)],
        tokenizer: Tokenizing,
        placement: [String: String]
    ) throws {
        var placement = placement
        #if canImport(MLX)
        // Built here, in the initializer, so `mlxDecode` can stay `let`: the
        // actor's stored properties are only assignable before the actor is
        // fully formed.
        let mlxLocal: MTLDecodeMLX?
        if decode == nil, let backbone = source.backbone {
            mlxLocal = try MTLDecodeMLX(weights: backbone)
            placement[source.prefill.deletingPathExtension().lastPathComponent] = "MLX (GPU)"
            placement[source.decode.deletingPathExtension().lastPathComponent] = "MLX (GPU)"
        } else {
            mlxLocal = nil
        }
        mlxDecode = mlxLocal
        #endif
        self.source = source
        self.variant = source.variant
        self.placement = placement
        // What the checkpoint speaks, minus what this app cannot prepare text
        // for. The multilingual model has 23 languages and five of them need a
        // normaliser that is not ported, so offering all 23 would be offering
        // five ways to be confidently mispronounced.
        var declared = (prefill?.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["languages"]
        #if canImport(MLX)
        declared = declared ?? mlxLocal?.config.languages
        #endif
        let advertised = (declared?.split(separator: ",").map {
            Language.named(String($0).trimmingCharacters(in: .whitespaces))
        }).flatMap { $0.isEmpty ? nil : $0 } ?? [.english]
        self.languages = advertised.filter { !tokenizer.refuses($0) }
        self.prefill = prefill
        self.decode = decode
        self.cond = cond
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

        func optional(_ model: MLModel, _ key: String) -> Int? {
            let defined = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            return defined?[key].flatMap(Int.init)
        }

        let names = (
            prefill: source.prefill.deletingPathExtension().lastPathComponent,
            decode: source.decode.deletingPathExtension().lastPathComponent,
            flow: source.flow.deletingPathExtension().lastPathComponent,
            vocoder: source.vocoder.deletingPathExtension().lastPathComponent
        )

        // Each smaller window says how many tokens it holds in its own
        // metadata; the file name's number is only used to pair flow with
        // vocoder.
        s3Windows = try s3Variants.map { pair in
            S3Window(
                flow: pair.flow,
                vocoder: pair.vocoder,
                genTokens: try meta(pair.flow, "\(names.flow) variant", "genTokens")
            )
        }

        if let prefill {
            condPrefixLength = try meta(prefill, names.prefill, "condPrefixLen")
            // Nano's exports predate this key; there, the conditioning prompt
            // is everything in the prefix except the speaker token.
            condPromptLength = optional(prefill, "condPromptLen") ?? (condPrefixLength - 1)
            maxTextTokens = try meta(prefill, names.prefill, "maxTextTokens")
            if let start = optional(prefill, "startTextToken"),
               let stop = optional(prefill, "stopTextToken") {
                textBrackets = (Int32(start), Int32(stop))
            } else {
                textBrackets = nil
            }
            speakerEmbeddingSize = try Self.lastDimension(prefill, names.prefill, "speaker_emb")
        } else {
            #if canImport(MLX)
            guard let mlx = mlxLocal else { throw EngineError.missingModel(source.prefill) }
            condPrefixLength = mlx.config.condPrefixLen
            condPromptLength = mlx.config.condPromptLen
            maxTextTokens = mlx.config.maxTextTokens
            textBrackets = (
                Int32(mlx.config.startTextToken), Int32(mlx.config.stopTextToken)
            )
            speakerEmbeddingSize = mlx.config.speakerEmbeddingSize
            #else
            throw EngineError.missingModel(source.prefill)
            #endif
        }
        if let decode {
            cfgRows = optional(decode, "cfgRows") ?? 1
            maxContext = try meta(decode, names.decode, "maxContext")
            layers = try meta(decode, names.decode, "nLayer")
            heads = try meta(decode, names.decode, "nHead")
            headDim = try meta(decode, names.decode, "headDim")
            vocabulary = try meta(decode, names.decode, "speechVocab")
            startSpeechToken = Int32(try meta(decode, names.decode, "startSpeechToken"))
            stopSpeechToken = Int32(try meta(decode, names.decode, "stopSpeechToken"))
        } else {
            #if canImport(MLX)
            // No decode model at all: the loop runs on MLX, and the constants
            // that were baked into the Core ML package's metadata come out of
            // the backbone export's config instead.
            guard let mlx = mlxLocal else {
                throw EngineError.missingModel(source.decode)
            }
            cfgRows = mlx.config.cfgRows
            maxContext = mlx.config.maxContext
            layers = mlx.config.nLayer
            heads = mlx.config.nHead
            headDim = mlx.config.headDim
            vocabulary = mlx.config.speechVocab
            startSpeechToken = Int32(mlx.config.startSpeechToken)
            stopSpeechToken = Int32(mlx.config.stopSpeechToken)
            #else
            throw EngineError.missingModel(source.decode)
            #endif
        }
        genTokens = try meta(flow, names.flow, "genTokens")
        promptTokenLength = try meta(flow, names.flow, "promptTokenLen")
        promptFeatureLength = try meta(flow, names.flow, "promptFeatLen")
        tokenMelRatio = try meta(flow, names.flow, "tokenMelRatio")
        silenceToken = Int32(try meta(flow, names.flow, "silenceToken"))
        melFrames = try meta(vocoder, names.vocoder, "melFrames")
        hop = try meta(vocoder, names.vocoder, "hop")

        xvectorSize = try Self.lastDimension(flow, names.flow, "embedding")
        melDimension = try Self.lastDimension(flow, names.flow, "prompt_feat")
    }

    private static func lastDimension(
        _ model: MLModel, _ modelName: String, _ input: String
    ) throws -> Int {
        guard let shape = model.modelDescription.inputDescriptionsByName[input]?
            .multiArrayConstraint?.shape,
            let last = shape.last
        else { throw EngineError.missingMetadata(modelName, "\(input) shape") }
        return last.intValue
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
        language: Language = .english,
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false,
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> [Float] {
        let tokens = try speakTokens(
            text, voice: voice, options: options, language: language,
            beginsMidSentence: beginsMidSentence, endsMidSentence: endsMidSentence,
            cancelled: cancelled
        )
        return try s3Stack().render(tokens, voice: voice, cancelled: cancelled)
    }

    /// The token half of `speak`: everything up to and including the T3 loop,
    /// which is the part that must hold the actor. The audio half is a pure
    /// function of these tokens — `s3Stack().render` — and runs off the actor,
    /// which is what lets a caller overlap chunk N's mel decode with chunk
    /// N+1's token loop instead of paying the two in series.
    public func speakTokens(
        _ text: String,
        voice: Voice,
        options: SamplingOptions = SamplingOptions(),
        language: Language = .english,
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false,
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> SpokenTokens {
        try validate(voice)
        var runs: [[Int32]] = []
        let pieces = splitToFit(text, language: language)
        for (index, piece) in pieces.enumerated() {
            if cancelled() { break }
            let tokens = try generateSpeechTokens(
                for: piece,
                voice: voice,
                options: options,
                language: language,
                // The seams an emergency split adds are themselves mid-sentence.
                beginsMidSentence: beginsMidSentence || index > 0,
                endsMidSentence: endsMidSentence || index < pieces.count - 1,
                cancelled: cancelled
            )
            if tokens.isEmpty { continue }
            runs.append(tokens)
        }
        return SpokenTokens(runs: runs)
    }

    /// A snapshot of the mel decoder and vocoder for off-actor rendering.
    ///
    /// The models are the instances loaded now; a `reload` replaces the
    /// actor's own references, and a stack in flight simply keeps the old
    /// instances alive until it finishes — the same lifetime rule the reload
    /// already lives by.
    public func s3Stack() -> S3Stack {
        S3Stack(
            flow: flow,
            vocoder: vocoder,
            windows: s3Windows.map { ($0.flow, $0.vocoder, $0.genTokens) },
            genTokens: genTokens,
            promptTokenLength: promptTokenLength,
            promptFeatureLength: promptFeatureLength,
            melDimension: melDimension,
            tokenMelRatio: tokenMelRatio,
            hop: hop,
            silenceToken: silenceToken,
            sampleRate: sampleRate
        )
    }

    /// Whether this voice's tensors fit the loaded models. Sync can hand a
    /// Nano phone a voice cloned for the multilingual Mac; offering it as a
    /// narrator would fail on the first chunk, so the roster filters through
    /// this instead.
    public func canRead(_ voice: Voice) -> Bool {
        (try? validate(voice)) != nil
    }

    /// A voice whose tensors do not match the loaded models must fail here,
    /// as an error naming the mismatch — further in it is a trap inside a
    /// buffer copy, or worse, a silently wrong shape.
    private func validate(_ voice: Voice) throws {
        let wants: [(String, Int, Int)] = [
            ("speaker embedding", voice.speakerEmbedding.count, speakerEmbeddingSize),
            ("conditioning tokens", voice.condPromptTokens.count, condPromptLength),
            ("prompt tokens", voice.promptTokens.count, promptTokenLength),
            ("prompt features", voice.promptFeatures.count, promptFeatureLength * melDimension),
            ("x-vector", voice.xvector.count, xvectorSize),
        ]
        for (what, got, want) in wants where got != want {
            throw EngineError.voiceMismatch(what, got, want)
        }
    }

    /// The chunker budgets in characters against an English ~4 chars/token;
    /// text that tokenizes worse — the grapheme tokenizer's ~0.75 tokens per
    /// character, degenerate ASCII, non-Latin scripts — can blow the prefill
    /// ceiling anyway. Rather than failing the chunk (which used to abort the
    /// whole chapter), split it and speak the pieces one after another.
    ///
    /// The split lands at the friendliest boundary available: the sentence
    /// break nearest the middle, then a clause break, then the midpoint word.
    /// The seam resets prosody wherever it falls, and a reader pausing between
    /// sentences is unremarkable where one stopping mid-word is not. The chunk
    /// boundaries on disk are untouched — this split lives entirely inside one
    /// chunk's render, so audio stays interchangeable between devices.
    private func splitToFit(_ text: String, language: Language) -> [String] {
        // Measured with `PuncNorm`'s default shape; the real call may add a
        // token or two (a trailing stop, a capitalisation), so a small margin
        // keeps a piece measured here from being refused there.
        let brackets = textBrackets == nil ? 0 : 2
        let measured = tokenizer.encode(PuncNorm.apply(text), language: language).count + brackets
        guard measured > maxTextTokens - 4 else { return [text] }
        guard let (head, tail) = Self.splitNearMiddle(text) else { return [text] }
        return splitToFit(head, language: language) + splitToFit(tail, language: language)
    }

    /// Cut `text` in two near its middle, preferring sentence boundaries,
    /// then clause punctuation, then whitespace. Nil only for a single
    /// unbreakable over-long word, which `generateSpeechTokens` refuses —
    /// there is nothing sayable to salvage from it.
    static func splitNearMiddle(_ text: String) -> (head: String, tail: String)? {
        for pieces in [
            Chunker.sentences(in: text),
            Chunker.clauses(in: text),
            text.split(whereSeparator: \.isWhitespace).map(String.init),
        ] where pieces.count > 1 {
            // The cut point whose left half comes closest to half the text.
            let total = pieces.reduce(0) { $0 + $1.count }
            var running = 0
            var best: (index: Int, distance: Int)?
            for (index, piece) in pieces.enumerated().dropLast() {
                running += piece.count
                let distance = abs(total / 2 - running)
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
            guard let best else { continue }
            return (
                pieces[...best.index].joined(separator: " "),
                pieces[(best.index + 1)...].joined(separator: " ")
            )
        }
        return nil
    }

    // MARK: - T3, the token loop

    func generateSpeechTokens(
        for text: String,
        voice: Voice,
        options: SamplingOptions,
        language: Language = .english,
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false,
        cancelled: @Sendable () -> Bool
    ) throws -> [Int32] {
        guard !tokenizer.refuses(language) else {
            throw EngineError.unsupportedLanguage(language.name)
        }
        let normalized = PuncNorm.apply(
            text, beginsMidSentence: beginsMidSentence, endsMidSentence: endsMidSentence
        )
        var textTokens = tokenizer.encode(normalized, language: language)
        guard !textTokens.isEmpty else { return [] }
        if let textBrackets {
            textTokens = [textBrackets.start] + textTokens + [textBrackets.stop]
        }
        guard textTokens.count <= maxTextTokens else {
            throw EngineError.textTooLong(textTokens.count, maxTextTokens)
        }

        // The multilingual prompt ends with *two* start-of-speech tokens, both
        // at learned position zero. It looks like a slip upstream and it is
        // what the weights were trained against — see mtl_reference.py, where
        // the harness pins it down. Tidying it away produces a model that
        // sounds nearly right.
        let speechStartTokens = variant == .multilingual ? 2 : 1
        let prefixLength = condPrefixLength + textTokens.count + speechStartTokens
        // What the KV cache has room for. The export sized `maxContext` as
        // prefix + maxTextTokens + 1 + a 1000-token generation budget
        // (`MAX_GEN_TOKENS` in tools/export/common.py), so for text shorter
        // than the ceiling this exceeds that budget by the unused text room.
        // Deliberate and safe: every position still fits the cache, and the
        // headroom only matters for a chunk that would otherwise be cut off.
        let budget = min(options.maxTokens, maxContext - prefixLength)

        #if canImport(MLX)
        if let mlxDecode, let cond {
            // The conditioning encoder is the one Core ML prediction left on
            // this path — fixed shapes. Its inputs are chapter-constant (the
            // voice and the expression slider), so the output is memoised and
            // a whole book pays for it once per voice, not once per chunk.
            let condKey = Self.condKey(voice: voice, exaggeration: options.exaggeration)
            let conditioning: MLMultiArray
            if let cached = condCache, cached.key == condKey {
                conditioning = cached.cond
            } else {
                let condOut = try cond.prediction(
                    from: try MLDictionaryFeatureProvider(dictionary: [
                        "speaker_emb": try mlArray(
                            voice.speakerEmbedding, shape: [1, voice.speakerEmbedding.count]
                        ),
                        "prompt_tokens": try mlArray(
                            voice.condPromptTokens, shape: [1, voice.condPromptTokens.count]
                        ),
                        "emotion": try mlArray([options.exaggeration], shape: [1, 1]),
                    ])
                )
                guard let fresh = condOut.featureValue(for: "cond")?.multiArrayValue else {
                    throw EngineError.badOutput("cond")
                }
                conditioning = fresh
                condCache = (condKey, conditioning)
            }
            let prefixRows = try mlxDecode.prefill(cond: conditioning, textTokens: textTokens)
            return try generateTokensMLX(
                mlxDecode, prefixRows: prefixRows,
                prefixLength: prefixLength, budget: budget, options: options,
                textTokenCount: textTokens.count, cancelled: cancelled
            )
        }
        #endif
        guard let prefill, let decode else { throw EngineError.missingModel(source.prefill) }

        // Where the two models genuinely differ, one of three places. Nano is
        // handed its learned positions; the multilingual model computes them
        // inside the graph and takes an emotion scalar instead.
        let prefillInputs: [String: Any] = switch variant {
        case .nano:
            [
                "speaker_emb": try mlArray(
                    voice.speakerEmbedding, shape: [1, voice.speakerEmbedding.count]
                ),
                "prompt_tokens": try mlArray(
                    voice.condPromptTokens, shape: [1, voice.condPromptTokens.count]
                ),
                "text_tokens": try mlArray(textTokens, shape: [1, textTokens.count]),
                "text_positions": try mlArray(
                    (0..<textTokens.count).map { Int32(condPrefixLength + $0) },
                    shape: [1, textTokens.count]
                ),
                "bos_position": try mlArray(
                    [Int32(condPrefixLength + textTokens.count)], shape: [1, 1]
                ),
            ]
        case .multilingual:
            [
                "speaker_emb": try mlArray(
                    voice.speakerEmbedding, shape: [1, voice.speakerEmbedding.count]
                ),
                "prompt_tokens": try mlArray(
                    voice.condPromptTokens, shape: [1, voice.condPromptTokens.count]
                ),
                "text_tokens": try mlArray(textTokens, shape: [1, textTokens.count]),
                "emotion": try mlArray([options.exaggeration], shape: [1, 1]),
            ]
        }
        let prefixOut = try prefill.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: prefillInputs)
        )

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

        var sampler = Sampler(options: options, order: variant == .multilingual ? .multilingual : .nano)
        var generated: [Int32] = []
        // The repetition penalty starts against the start-of-speech token, as
        // it does upstream, and switches to the real history after the first.
        var penalized: Set<Int32> = [startSpeechToken]

        let tokenInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let positionInput = try MLMultiArray(shape: [1], dataType: .int32)
        // The multilingual decode step takes two more: the *learned* speech
        // position, which counts from the start-of-speech token rather than
        // from the start of the sequence, and the guidance weight, because the
        // two rows are combined inside the model.
        let speechPositionInput = try MLMultiArray(shape: [1], dataType: .int32)
        let guidanceInput = try MLMultiArray(shape: [1], dataType: .float32)
        guidanceInput[0] = NSNumber(value: options.cfgWeight)
        // One feature provider and one output buffer for the whole loop — the
        // provider reads the arrays above by reference, and the backing spares
        // Core ML allocating a fresh logits array per token.
        let stepInput = try MLDictionaryFeatureProvider(
            dictionary: variant == .multilingual
                ? [
                    "token": tokenInput,
                    "position": positionInput,
                    "speech_position": speechPositionInput,
                    "cfg_weight": guidanceInput,
                ]
                : ["token": tokenInput, "position": positionInput]
        )
        let stepOptions = MLPredictionOptions()
        stepOptions.outputBackings = [
            "logits": try MLMultiArray(shape: [1, NSNumber(value: vocabulary)], dataType: .float32),
        ]

        // The prefill hands back both CFG rows, unguided: guidance is folded in
        // by the *decode* model, which has not run yet when the first token is
        // chosen. So the first one is combined here, with the same arithmetic —
        // and the prefill keeps emitting both rows, which is what makes it
        // comparable against torch in verify_mtl.py.
        var first = try guide(logits, weight: options.cfgWeight)
        var current = first.withUnsafeMutableBufferPointer { buffer in
            sampler.next(logits: buffer, history: penalized)
        }
        for step in 0..<budget {
            if current == stopSpeechToken || cancelled() { break }
            generated.append(current)
            if generated.count == 1 { penalized.remove(startSpeechToken) }
            penalized.insert(current)

            tokenInput[0] = NSNumber(value: current)
            positionInput[0] = NSNumber(value: Int32(prefixLength + step))
            // Position 0 belongs to the start-of-speech token, so the token
            // generated at step 0 sits at learned position 1.
            speechPositionInput[0] = NSNumber(value: Int32(step + 1))
            // The logits buffer is reused via the output backing — safe to
            // read after the pool drains — but the provider wrapping it is a
            // fresh autoreleased object per token, some twelve hundred per
            // chunk, so drain them as they come.
            let next = try autoreleasepool { () throws -> MLMultiArray in
                let out = try decode.prediction(from: stepInput, using: state, options: stepOptions)
                guard let next = out.featureValue(for: "logits")?.multiArrayValue else {
                    throw EngineError.badOutput("decode logits")
                }
                return next
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

    #if canImport(MLX)
    /// The same loop as below, driving MLX instead of a Core ML prediction per
    /// token. Everything that decides what the audio *says* — the sampler, the
    /// penalty history, the budget bookkeeping, the control-token filter — is
    /// deliberately identical; only what computes the logits differs.
    private func generateTokensMLX(
        _ mlx: MTLDecodeMLX,
        prefixRows: [Float],
        prefixLength: Int,
        budget: Int,
        options: SamplingOptions,
        textTokenCount: Int,
        cancelled: () -> Bool
    ) throws -> [Int32] {
        var sampler = Sampler(options: options, order: .multilingual)
        var generated: [Int32] = []
        var penalized: Set<Int32> = [startSpeechToken]

        // The first token comes from the prefill's logits, which are both rows
        // unguided — same as the Core ML path.
        var first = guide(rows: prefixRows, weight: options.cfgWeight)
        var current = sample(&sampler, floats: &first, history: penalized)
        for step in 0..<budget {
            if current == stopSpeechToken || cancelled() { break }
            generated.append(current)
            if generated.count == 1 { penalized.remove(startSpeechToken) }
            penalized.insert(current)

            // Position 0 belongs to the start-of-speech token, so the token
            // generated at step 0 sits at learned position 1.
            var logits = mlx.step(
                token: current,
                position: prefixLength + step,
                speechPosition: step + 1,
                cfgWeight: options.cfgWeight
            )
            current = sample(&sampler, floats: &logits, history: penalized)
        }
        if current != stopSpeechToken, generated.count < budget { generated.append(current) }
        if current != stopSpeechToken, generated.count >= budget, !cancelled() {
            PlaybackLog.note(
                "t3: hit the \(budget)-token budget mid-sentence; "
                    + "the tail of a \(textTokenCount)-text-token chunk was dropped"
            )
        }
        return generated.filter { $0 < startSpeechToken }
    }
    #endif

    /// As below, for prefill logits already in Swift memory — the MLX path.
    private func guide(rows: [Float], weight: Float) -> [Float] {
        guard rows.count == cfgRows * vocabulary, cfgRows == 2 else {
            return rows
        }
        var out = [Float](repeating: 0, count: vocabulary)
        for index in 0..<vocabulary {
            let cond = rows[index]
            let uncond = rows[vocabulary + index]
            out[index] = cond + weight * (cond - uncond)
        }
        return out
    }

    /// One row of logits out of however many the model returned.
    ///
    /// `cond + w · (cond − uncond)` when there are two, which is what the
    /// multilingual decode model does internally; a straight copy when there is
    /// one.
    private func guide(_ logits: MLMultiArray, weight: Float) throws -> [Float] {
        guard cfgRows > 1 else {
            return logits.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        }
        guard logits.count == cfgRows * vocabulary else {
            throw EngineError.badOutput(
                "prefill logits \(logits.count) wide, not \(cfgRows) × \(vocabulary)"
            )
        }
        return logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            (0..<vocabulary).map { index in
                let conditional = buffer[index]
                let unconditional = buffer[vocabulary + index]
                return conditional + weight * (conditional - unconditional)
            }
        }
    }

    /// As below, for logits already in Swift memory — the MLX loop's shape.
    private func sample(_ sampler: inout Sampler, floats: inout [Float], history: Set<Int32>) -> Int32 {
        floats.withUnsafeMutableBufferPointer { buffer in
            assert(buffer.count == vocabulary, "logits are \(buffer.count) wide, not \(vocabulary)")
            return sampler.next(logits: buffer, history: history)
        }
    }

    private func sample(_ sampler: inout Sampler, _ logits: MLMultiArray, history: Set<Int32>) -> Int32 {
        logits.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            assert(buffer.count == vocabulary, "logits are \(buffer.count) wide, not \(vocabulary)")
            return sampler.next(logits: buffer, history: history)
        }
    }

    /// Copy the prefill's KV cache into the decode model's state.
    ///
    /// Both are `(layers, cfgRows, heads, position, headDim)` float16, so each
    /// (layer, row, head) slice is contiguous in both and this is a few hundred
    /// memcpys rather than an element-by-element walk. Nothing past `length` is cleared: the
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
            // Guidance doubles this: the cache is
            // (layers, rows, heads, context, headDim), and `rows` is 2 when
            // every step computes a conditional and an unconditional pass.
            let rows = layers * cfgRows * heads

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

    /// The audio half on the actor, for callers and tests that do not
    /// pipeline. The real work lives in `S3Stack.decode`.
    func decodeToAudio(tokens: [Int32], voice: Voice) throws -> [Float] {
        try s3Stack().decode(tokens: tokens, voice: voice)
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

}

// MARK: - The audio half, off the actor

/// One chunk's worth of speech tokens, ready for the mel decoder.
///
/// Usually one run; more when `splitToFit` had to break the text. Each run is
/// rendered separately, with its own fades, exactly as `speak` always did.
public struct SpokenTokens: Sendable {
    let runs: [[Int32]]
    public var isEmpty: Bool { runs.allSatisfy(\.isEmpty) }
}

/// The mel decoder and vocoder, snapshotted off the engine actor.
///
/// This exists for one reason: the token loop and the mel decode are the two
/// halves of a chunk's cost, and inside the actor they could only ever run in
/// series. A stack rendered off-actor lets `ChapterRenderer` decode chunk N
/// while the actor generates chunk N+1's tokens.
///
/// `@unchecked Sendable` because it holds `MLModel`s: Apple documents
/// `prediction` as thread-safe, every other stored property is immutable, and
/// the mutable Core ML state (the KV cache) belongs to the token loop, which
/// stays on the actor.
public struct S3Stack: @unchecked Sendable {
    let flow: MLModel
    let vocoder: MLModel
    let windows: [(flow: MLModel, vocoder: MLModel, genTokens: Int)]
    let genTokens: Int
    let promptTokenLength: Int
    let promptFeatureLength: Int
    let melDimension: Int
    let tokenMelRatio: Int
    let hop: Int
    let silenceToken: Int32
    let sampleRate: Int

    /// Length of the crossfade that hides a window join: five milliseconds,
    /// long enough to remove a step, short enough that blending two slightly
    /// different renderings of the same moment cannot smear a phoneme.
    private var seamRamp: Int { sampleRate / 200 }

    /// Every run of a chunk, rendered and joined.
    public func render(
        _ tokens: SpokenTokens, voice: Voice, cancelled: () -> Bool = { false }
    ) throws -> [Float] {
        var audio: [Float] = []
        for run in tokens.runs {
            if cancelled() { break }
            audio += try decode(tokens: run, voice: voice)
        }
        return audio
    }

    /// The mel decoder is exported at one fixed length, so a run of tokens is
    /// split into windows of that length and each is padded out with the
    /// model's own silence token. Text chunks are sized to fit in one window;
    /// the loop is here for the occasional chunk where the model rambles.
    func decode(tokens: [Int32], voice: Voice) throws -> [Float] {
        guard !tokens.isEmpty else { return [] }
        var audio: [Float] = []

        for step in ChatterboxEngine.windowPlan(
            tokenCount: tokens.count, window: genTokens,
            runUp: ChatterboxEngine.runUpTokens, tail: ChatterboxEngine.tailTokens
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

    private func decodeWindow(_ window: [Int32], voice: Voice) throws -> [Float] {
        // A pool per window, not per batch: everything Core ML hands back here
        // — the mel, the waveform, the feature providers — is autoreleased,
        // and this runs inside one long detached task per chunk, where the
        // thread's own pool does not drain until the chunk returns. Without
        // this, an overnight batch accumulates every window's few megabytes
        // until the process is killed.
        try autoreleasepool {
            // The smallest installed window that holds the tokens plus the three
            // silence tokens below. A window's cost is paid in full however little
            // of it is used — twenty estimator passes over every mel frame,
            // rendered silence included — so a typical 400-token chunk through a
            // fitted window is the single cheapest speedup S3 has.
            let fitted = windows
                .filter { $0.genTokens >= window.count + 3 }
                .min { $0.genTokens < $1.genTokens }
            let (flow, vocoder, capacity) = fitted.map { ($0.flow, $0.vocoder, $0.genTokens) }
                ?? (self.flow, self.vocoder, genTokens)

            var padded = window
            // Three tokens of silence before the padding, as the desktop pipeline
            // appends, so the last word is not clipped by the window edge.
            padded += [silenceToken, silenceToken, silenceToken]
            let spoken = min(padded.count, capacity)
            padded += Array(repeating: silenceToken, count: max(0, capacity - padded.count))
            padded = Array(padded.prefix(capacity))

            let melLength = (promptTokenLength + capacity) * tokenMelRatio
            let melOut = try flow.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "prompt_tokens": try mlArray(voice.promptTokens, shape: [1, promptTokenLength]),
                "gen_tokens": try mlArray(padded, shape: [1, capacity]),
                "prompt_feat": try mlArray(
                    voice.promptFeatures, shape: [1, promptFeatureLength, melDimension]
                ),
                "embedding": try mlArray(voice.xvector, shape: [1, voice.xvector.count]),
                "noise": try mlGaussian(shape: [1, melDimension, melLength]),
            ]))
            guard let mel = melOut.featureValue(for: "mel")?.multiArrayValue else {
                throw ChatterboxEngine.EngineError.badOutput("mel")
            }

            let wavOut = try vocoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["mel": mel]))
            guard let waveform = wavOut.featureValue(for: "waveform")?.multiArrayValue else {
                throw ChatterboxEngine.EngineError.badOutput("waveform")
            }

            let wanted = min(spoken * tokenMelRatio * hop, waveform.count)
            return waveform.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(wanted)) }
        }
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
}

// MARK: - Buffers

private func mlArray(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
    let out = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
    assert(values.count == out.count, "\(values.count) floats into shape \(shape)")
    out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
        _ = buffer.update(fromContentsOf: values)
    }
    return out
}

private func mlArray(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
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
private func mlGaussian(shape: [Int]) throws -> MLMultiArray {
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
