#if canImport(MLX)
import CoreML
import Foundation
import MLX
import MLXFast

/// The multilingual T3 — prefill and decode loop — on MLX instead of Core ML.
///
/// Core ML runs these thirty layers correctly but slowly, in two distinct
/// ways. The decode step is one `prediction()` per speech token, ~56 ms on an
/// M4 — three quarters of a chapter's wall clock. And the prefill's flexible
/// text dimension makes Core ML re-specialize the graph for every text length
/// it has not seen, which is *seconds* per chunk on top, because every chunk's
/// length is novel. MLX has neither problem: the same layers with a
/// preallocated KV cache step several times faster, and a flexible prefill
/// costs nothing extra.
///
/// What stays in Core ML is everything this is bad at or that has fixed
/// shapes anyway: the conditioning encoder (`MTLCond`, the perceiver — run
/// once per chunk), the mel decoder and the vocoder. The sampler still runs
/// in Swift on the guided logits this returns.
///
/// The forward pass mirrors `MTLT3Decode` in tools/export/mtl_t3_export.py
/// line for line — batch of two always (guidance is not optional in this
/// model), rotary tables baked at export rather than derived, the learned
/// speech position counted from the BOS while the cache position is absolute,
/// the unattended tail masked with the same -1e4 the exports use, and the two
/// rows folded as `cond + w · (cond − uncond)` before anything crosses back to
/// the sampler. When the two implementations disagree, that file and
/// mtl_reference.py are the ground truth.
///
/// Everything in the step has a fixed shape — the cache write lands at a
/// *runtime* position via `putAlong`, and attention always covers the whole
/// cache behind an additive mask, exactly the trade the Core ML export makes
/// for the Neural Engine. That is what lets the whole step be `compile`d once
/// and dispatched as one unit instead of ~700 individual kernels per token.
final class MTLDecodeMLX {
    struct Config: Decodable {
        let cfgRows: Int
        let nLayer: Int
        let nHead: Int
        let headDim: Int
        let hidden: Int
        let speechVocab: Int
        let startSpeechToken: Int
        let stopSpeechToken: Int
        let maxContext: Int
        let eps: Float
        let scaling: Float
        let quantization: String
        let quantGroupSize: Int?
        let quantBits: Int?
        // What the engine used to read off the Core ML prefill, which is not
        // loaded at all when the backbone is installed.
        let condPrefixLen: Int
        let condPromptLen: Int
        let maxTextTokens: Int
        let startTextToken: Int
        let stopTextToken: Int
        let speakerEmbeddingSize: Int
        let languages: String
    }

    enum LoadError: Error, LocalizedError {
        case missingTensor(String)
        case missingConfig(URL)
        case badDataType(String, String)

        var errorDescription: String? {
            switch self {
            case .missingTensor(let name):
                "MTLT3Backbone.safetensors has no '\(name)'; re-run: bun run mac:backbone"
            case .missingConfig(let url):
                "Missing \(url.lastPathComponent) beside the backbone weights"
            case .badDataType(let what, let type):
                "\(what) is \(type), not a float type — re-export the models"
            }
        }
    }

    /// One projection, dense or pre-quantized at export. The quantized form
    /// is MLX's grouped affine scheme, applied only to the big per-layer
    /// matrices — they are all of the per-token memory traffic, which is what
    /// the decode loop is bound by.
    private enum Projection {
        case dense(MLXArray)
        case quantized(MLXArray, MLXArray, MLXArray, groupSize: Int, bits: Int)

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            switch self {
            case .dense(let weight):
                return matmul(x, weight.T)
            case .quantized(let weight, let scales, let biases, let group, let bits):
                return quantizedMatmul(
                    x, weight, scales: scales, biases: biases,
                    transpose: true, groupSize: group, bits: bits
                )
            }
        }
    }

    private struct Layer {
        let q: Projection
        let k: Projection
        let v: Projection
        let o: Projection
        let gate: Projection
        let up: Projection
        let down: Projection
        let normIn: MLXArray
        let normPost: MLXArray
    }

    let config: Config

    /// The KV cache, preallocated once — (rows, heads, context, headDim) per
    /// layer, 333 MB the pair at full context. Reused across chunks the same
    /// way the Core ML state is: `prefill` (or `seed`) rewrites everything up
    /// to the prefix, and everything past the live position is masked rather
    /// than trusted, so a longer previous chunk's leftovers are never attended
    /// to.
    private let kCache: [MLXArray]
    private let vCache: [MLXArray]

    // The backbone, kept for the prefill pass; the step loop reaches them
    // through `compiledStep`, which captured them at init.
    private let layers: [Layer]
    private let norm: MLXArray
    private let head: MLXArray
    private let speechEmb: MLXArray
    private let speechPos: MLXArray
    private let textEmb: MLXArray
    private let textPos: MLXArray
    private let ropeCos: MLXArray
    private let ropeSin: MLXArray

    /// One token in, one guided distribution out, as a single compiled unit.
    /// Arguments: token (1,) i32, cache position (1,) i32, learned speech
    /// position (1,) i32, guidance weight (1,) f32. Returns [(vocab,) f32].
    private let compiledStep: @Sendable ([MLXArray]) -> [MLXArray]

    init(weights url: URL) throws {
        // Before the first allocation: everything below goes through the pool
        // this bounds.
        EngineMemory.capCache()

        let configURL = url.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: configURL) else {
            throw LoadError.missingConfig(configURL)
        }
        // Locals throughout, so the compiled closure below captures values
        // rather than `self` before every member is initialized.
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        config = cfg

        let arrays = try MLX.loadArrays(url: url)
        func tensor(_ name: String) throws -> MLXArray {
            guard let found = arrays[name] else { throw LoadError.missingTensor(name) }
            return found
        }
        func projection(_ name: String) throws -> Projection {
            if let dense = arrays[name] { return .dense(dense) }
            guard let group = cfg.quantGroupSize, let bits = cfg.quantBits else {
                throw LoadError.missingTensor(name)
            }
            // Stored bitcast as int32 — safetensors has no uint32.
            return .quantized(
                try tensor("\(name).weight").view(dtype: .uint32),
                try tensor("\(name).scales"),
                try tensor("\(name).biases"),
                groupSize: group, bits: bits
            )
        }

        let layers = try (0..<cfg.nLayer).map { index in
            Layer(
                q: try projection("layers.\(index).q"),
                k: try projection("layers.\(index).k"),
                v: try projection("layers.\(index).v"),
                o: try projection("layers.\(index).o"),
                gate: try projection("layers.\(index).gate"),
                up: try projection("layers.\(index).up"),
                down: try projection("layers.\(index).down"),
                normIn: try tensor("layers.\(index).norm_in"),
                normPost: try tensor("layers.\(index).norm_post")
            )
        }
        let norm = try tensor("norm")
        let head = try tensor("head")
        let speechEmb = try tensor("speech_emb")
        let speechPos = try tensor("speech_pos")
        let ropeCos = try tensor("rope_cos")
        let ropeSin = try tensor("rope_sin")
        self.layers = layers
        self.norm = norm
        self.head = head
        self.speechEmb = speechEmb
        self.speechPos = speechPos
        self.textEmb = try tensor("text_emb")
        self.textPos = try tensor("text_pos")
        self.ropeCos = ropeCos
        self.ropeSin = ropeSin

        let shape = [cfg.cfgRows, cfg.nHead, cfg.maxContext, cfg.headDim]
        let kCache = (0..<cfg.nLayer).map { _ in MLX.zeros(shape, type: Float16.self) }
        let vCache = (0..<cfg.nLayer).map { _ in MLX.zeros(shape, type: Float16.self) }
        self.kCache = kCache
        self.vCache = vCache

        // Cache slots at or before the live position are real; the rest is
        // whatever the last chunk left there. Same mask value as the exports:
        // not -inf, because an fp16 graph turns an all-masked row into NaN.
        let slots = MLXArray(0..<Int32(cfg.maxContext)).reshaped([1, 1, 1, cfg.maxContext])
        let masked = MLXArray(Float16(-1e4))
        let unmasked = MLXArray(Float16(0))

        func rotateHalf(_ x: MLXArray) -> MLXArray {
            let half = cfg.headDim / 2
            return concatenated(
                [-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1
            )
        }

        compiledStep = compile(inputs: kCache + vCache, outputs: kCache + vCache) { args in
            let token = args[0]
            let position = args[1]
            let speechPosition = args[2]
            let cfgWeight = args[3]

            // Token and learned-position embeddings, the same row for both
            // rows of the batch.
            var x = (speechEmb[token] + speechPos[speechPosition])
                .reshaped([1, 1, cfg.hidden])
            x = broadcast(x, to: [cfg.cfgRows, 1, cfg.hidden])

            let cos = ropeCos[position].reshaped([1, 1, 1, cfg.headDim])
            let sin = ropeSin[position].reshaped([1, 1, 1, cfg.headDim])
            let bias = which(slots .<= position, unmasked, masked)

            // Where in the cache this step's K and V land: `putAlong` takes
            // the slot index per written element, which is how the write stays
            // one fixed-shape op with a runtime position.
            let writeShape = [cfg.cfgRows, cfg.nHead, 1, cfg.headDim]
            let slot = broadcast(position.reshaped([1, 1, 1, 1]), to: writeShape)

            for (index, layer) in layers.enumerated() {
                let h = MLXFast.rmsNorm(x, weight: layer.normIn, eps: cfg.eps)

                func heads(_ projected: MLXArray) -> MLXArray {
                    projected.reshaped([cfg.cfgRows, 1, cfg.nHead, cfg.headDim])
                        .transposed(0, 2, 1, 3)
                }
                var q = heads(layer.q(h))
                var k = heads(layer.k(h))
                let v = heads(layer.v(h))
                q = q * cos + rotateHalf(q) * sin
                k = k * cos + rotateHalf(k) * sin

                kCache[index]._updateInternal(putAlong(kCache[index], slot, values: k, axis: 2))
                vCache[index]._updateInternal(putAlong(vCache[index], slot, values: v, axis: 2))

                let attended = MLXFast.scaledDotProductAttention(
                    queries: q,
                    keys: kCache[index],
                    values: vCache[index],
                    scale: cfg.scaling,
                    mask: bias
                )
                .transposed(0, 2, 1, 3)
                .reshaped([cfg.cfgRows, 1, cfg.nHead * cfg.headDim])

                x = x + layer.o(attended)
                let post = MLXFast.rmsNorm(x, weight: layer.normPost, eps: cfg.eps)
                let gate = layer.gate(post)
                x = x + layer.down(gate * sigmoid(gate) * layer.up(post))
            }

            var logits = matmul(MLXFast.rmsNorm(x, weight: norm, eps: cfg.eps), head.T)
                .reshaped([cfg.cfgRows, cfg.speechVocab])
                .asType(.float32)
            // Guidance folded here, as the Core ML decode model folds it: it
            // is arithmetic over both rows, not a sampling decision.
            let cond = logits[0..<1]
            let uncond = logits[1..<2]
            logits = cond + cfgWeight * (cond - uncond)
            return [logits]
        }

        // Materialise everything now: the weights load lazily, and the first
        // decode step of the first chunk is a bad place to fault in a
        // gigabyte.
        MLX.eval(kCache + vCache + [norm, head, speechEmb, speechPos, ropeCos, ropeSin])
    }

    /// The whole prompt in one pass: conditioning, text, and the two
    /// start-of-speech tokens, exactly as `MTLT3Prefill` assembles them (see
    /// mtl_t3_export.py). Fills the KV cache and returns both rows' logits at
    /// the last position, unguided — the engine folds them, as it does for the
    /// Core ML prefill's output.
    ///
    /// The two easy-to-get-wrong pieces, pinned down by mtl_reference.py: the
    /// prompt ends with *two* BOS tokens, both at learned position 0, and the
    /// unconditional row zeroes the text's token embeddings but keeps its
    /// position embeddings — position without content.
    ///
    /// `cond` is the `MTLCond` model's output, (1, condPrefixLen, hidden).
    func prefill(cond: MLMultiArray, textTokens: [Int32]) throws -> [Float] {
        // A bad export is an error to report, not a reason to take the
        // process down.
        guard cond.dataType == .float16 || cond.dataType == .float32 else {
            throw LoadError.badDataType("the conditioning output", "\(cond.dataType)")
        }
        let condRow: MLXArray = cond.withUnsafeBytes { bytes in
            switch cond.dataType {
            case .float16:
                return MLXArray(
                    bytes.bindMemory(to: Float16.self),
                    [1, config.condPrefixLen, config.hidden]
                )
            default:
                return MLXArray(
                    bytes.bindMemory(to: Float.self),
                    [1, config.condPrefixLen, config.hidden]
                ).asType(.float16)
            }
        }

        let count = textTokens.count
        let tokens = MLXArray(textTokens)
        let positions = textPos[0..<count]
        // The unconditional row loses the words and keeps the positions, in
        // that order — zeroing after the addition is a different model.
        let text = stacked([textEmb[tokens] + positions, positions], axis: 0)

        let bos = (speechEmb[config.startSpeechToken] + speechPos[0])
            .reshaped([1, 1, config.hidden])
        let both = broadcast(bos, to: [config.cfgRows, 1, config.hidden])

        var x = concatenated(
            [broadcast(condRow, to: [config.cfgRows, config.condPrefixLen, config.hidden]),
             text, both, both],
            axis: 1
        ).asType(.float16)

        let length = x.dim(1)
        let cos = ropeCos[0..<length].reshaped([1, 1, length, config.headDim])
        let sin = ropeSin[0..<length].reshaped([1, 1, length, config.headDim])
        // Causal, additive, and -1e4 rather than -inf for the same fp16
        // reason as everywhere else in this port.
        let slots = MLXArray(0..<Int32(length))
        let bias = which(
            slots.reshaped([1, 1, length, 1]) .>= slots.reshaped([1, 1, 1, length]),
            MLXArray(Float16(0)), MLXArray(Float16(-1e4))
        )

        for (index, layer) in layers.enumerated() {
            let h = MLXFast.rmsNorm(x, weight: layer.normIn, eps: config.eps)
            func heads(_ projected: MLXArray) -> MLXArray {
                projected.reshaped([config.cfgRows, length, config.nHead, config.headDim])
                    .transposed(0, 2, 1, 3)
            }
            var q = heads(layer.q(h))
            var k = heads(layer.k(h))
            let v = heads(layer.v(h))
            q = q * cos + rotateHalf(q) * sin
            k = k * cos + rotateHalf(k) * sin

            kCache[index][0..., 0..., 0..<length, 0...] = k
            vCache[index][0..., 0..., 0..<length, 0...] = v

            let attended = MLXFast.scaledDotProductAttention(
                queries: q, keys: k, values: v, scale: config.scaling, mask: bias
            )
            .transposed(0, 2, 1, 3)
            .reshaped([config.cfgRows, length, config.nHead * config.headDim])

            x = x + layer.o(attended)
            let post = MLXFast.rmsNorm(x, weight: layer.normPost, eps: config.eps)
            let gate = layer.gate(post)
            x = x + layer.down(gate * sigmoid(gate) * layer.up(post))
        }

        let last = MLXFast.rmsNorm(
            x[0..., (length - 1)..<length, 0...], weight: norm, eps: config.eps
        )
        let logits = matmul(last, head.T)
            .reshaped([config.cfgRows * config.speechVocab])
            .asType(.float32)
        return logits.asArray(Float.self)
    }

    private func rotateHalf(_ x: MLXArray) -> MLXArray {
        let half = config.headDim / 2
        return concatenated(
            [-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1
        )
    }

    /// Copy the Core ML prefill's cache in, replacing the first `length`
    /// positions. The source is `(layers, rows, heads, length, headDim)`,
    /// float16 or float32 depending on how the prefill was exported.
    func seed(keys: MLMultiArray, values: MLMultiArray, length: Int) throws {
        let shape = [config.nLayer, config.cfgRows, config.nHead, length, config.headDim]
        for (source, caches) in [(keys, kCache), (values, vCache)] {
            guard source.dataType == .float16 || source.dataType == .float32 else {
                throw LoadError.badDataType("the prefill cache", "\(source.dataType)")
            }
            let whole: MLXArray = source.withUnsafeBytes { bytes in
                switch source.dataType {
                case .float16:
                    return MLXArray(bytes.bindMemory(to: Float16.self), shape)
                default:
                    return MLXArray(bytes.bindMemory(to: Float.self), shape).asType(.float16)
                }
            }
            for index in 0..<config.nLayer {
                caches[index][0..., 0..., 0..<length, 0...] = whole[index]
            }
        }
        MLX.eval(kCache + vCache)
    }

    /// One token in, one guided distribution out.
    ///
    /// `position` is the absolute cache slot; `speechPosition` is the learned
    /// position, counted from the BOS (the token generated at step 0 sits at
    /// learned position 1). Exactly the Core ML decode model's inputs, and the
    /// output matches its single fused row.
    func step(token: Int32, position: Int, speechPosition: Int, cfgWeight: Float) -> [Float] {
        let out = compiledStep([
            MLXArray([token]),
            MLXArray([Int32(position)]),
            MLXArray([Int32(speechPosition)]),
            MLXArray([cfgWeight]),
        ])
        return out[0].asArray(Float.self)
    }
}
#endif
