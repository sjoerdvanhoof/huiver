import Accelerate
import Foundation

/// How adventurous the model is allowed to be.
///
/// The defaults are chatterbox's own. `exaggeration` and `cfgWeight`, the two
/// knobs the base Chatterbox model is known for, are absent on purpose: the
/// Nano and Turbo generators accept them and then explicitly ignore them, so
/// offering them here would be a lie.
public struct SamplingOptions: Sendable, Equatable {
    public var temperature: Float = 0.8
    public var topP: Float = 0.95
    public var topK: Int = 1000
    public var repetitionPenalty: Float = 1.2
    /// Give up on a chunk after this many speech tokens (~48s of audio at
    /// 25 Hz).
    ///
    /// The engine takes `min` of this and what the KV cache can actually hold,
    /// so asking for more than the model allows costs nothing — it is a
    /// backstop against a chunk that never emits its stop token, not a budget
    /// to ration. Keeping it low was silently truncating long sentences.
    public var maxTokens: Int = 1200

    public init() {}
}

/// Turn logits into the next speech token.
///
/// The order of operations is copied from `T3.inference_turbo`: temperature,
/// then top-k, then top-p, and only then the repetition penalty. That last one
/// is unusual — most implementations penalise before filtering — but matching
/// upstream matters more than being conventional, because a different order
/// gives a different voice.
///
/// This runs ~1200 times per chunk over a 6563-wide vocabulary, so it keeps
/// its scratch buffers between calls and sorts once: a single descending index
/// sort serves both top-k (the k-th value is at rank k−1) and top-p (the
/// nucleus walk), where an earlier version sorted a fresh copy for each.
public struct Sampler {
    public var options: SamplingOptions
    private var generator: SystemRandomNumberGenerator
    /// Token indices, descending by logit. Reused between calls.
    private var order: [vDSP_Length] = []
    /// Probabilities by rank (for top-p), then by token (for the draw).
    private var weights: [Float] = []

    public init(options: SamplingOptions) {
        self.options = options
        self.generator = SystemRandomNumberGenerator()
    }

    /// - Parameters:
    ///   - logits: modified in place; the caller owns the buffer.
    ///   - history: tokens generated so far, for the repetition penalty.
    public mutating func next(
        logits: UnsafeMutableBufferPointer<Float>, history: Set<Int32>
    ) -> Int32 {
        filter(logits: logits, history: history)
        return multinomial(logits)
    }

    /// The deterministic half: everything before the draw. Split out so the
    /// tests can compare it against a reference implementation exactly.
    mutating func filter(logits: UnsafeMutableBufferPointer<Float>, history: Set<Int32>) {
        let count = logits.count

        if options.temperature > 0, options.temperature != 1 {
            for i in 0..<count { logits[i] /= options.temperature }
        }

        let wantsTopK = options.topK > 0 && options.topK < count
        let wantsTopP = options.topP < 1
        if wantsTopK || wantsTopP {
            if order.count != count {
                order = Array(0..<vDSP_Length(count))
            } else {
                for i in 0..<count { order[i] = vDSP_Length(i) }
            }
            vDSP_vsorti(logits.baseAddress!, &order, nil, vDSP_Length(count), -1)

            if wantsTopK {
                // Everything *below* the k-th value goes; ties with it stay,
                // which is what HuggingFace's TopKLogitsWarper keeps too.
                let cutoff = logits[Int(order[options.topK - 1])]
                for i in 0..<count where logits[i] < cutoff { logits[i] = -.infinity }
            }

            if wantsTopP { applyTopP(logits) }
        }

        if options.repetitionPenalty != 1 {
            for token in history {
                let i = Int(token)
                guard i >= 0, i < count, logits[i].isFinite else { continue }
                logits[i] = logits[i] < 0
                    ? logits[i] * options.repetitionPenalty
                    : logits[i] / options.repetitionPenalty
            }
        }
    }

    /// Keep the smallest set of tokens whose probabilities sum past `topP`.
    /// `order` is already sorted descending when this runs.
    private mutating func applyTopP(_ logits: UnsafeMutableBufferPointer<Float>) {
        let count = logits.count
        let maximum = logits[Int(order[0])]
        guard maximum.isFinite else { return }

        if weights.count != count { weights = [Float](repeating: 0, count: count) }
        var total: Float = 0
        for rank in 0..<count {
            let value = logits[Int(order[rank])]
            let p = value.isFinite ? expf(value - maximum) : 0
            weights[rank] = p
            total += p
        }
        guard total > 0 else { return }

        // The comparison is against the prefix *before* this token, which keeps
        // the one that crosses the threshold rather than dropping it. That is
        // what HuggingFace's TopPLogitsWarper does, and testing the inclusive
        // sum instead — the easy mistake — truncates the nucleus by one token
        // on every step.
        var prefix: Float = 0
        for rank in 0..<count {
            // Never the first token, so there is always something to sample.
            if rank > 0, prefix >= options.topP { logits[Int(order[rank])] = -.infinity }
            prefix += weights[rank] / total
        }
    }

    private mutating func multinomial(_ logits: UnsafeMutableBufferPointer<Float>) -> Int32 {
        let count = logits.count
        var maximum = -Float.infinity
        for i in 0..<count where logits[i] > maximum { maximum = logits[i] }
        guard maximum.isFinite else { return 0 }

        if weights.count != count { weights = [Float](repeating: 0, count: count) }
        var total: Float = 0
        for i in 0..<count {
            let p = logits[i].isFinite ? expf(logits[i] - maximum) : 0
            weights[i] = p
            total += p
        }
        guard total > 0 else { return 0 }

        let target = Float.random(in: 0..<total, using: &generator)
        var running: Float = 0
        for i in 0..<count {
            running += weights[i]
            if running > target { return Int32(i) }
        }
        return Int32(count - 1)
    }
}
