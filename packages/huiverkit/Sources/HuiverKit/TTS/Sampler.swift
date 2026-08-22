import Accelerate
import Foundation

/// How adventurous the model is allowed to be.
///
/// The defaults are Nano's own, and `multilingual` below is the other set: the
/// two checkpoints do not merely prefer different numbers, they filter in a
/// different order and use different filters — see `Sampler.Order`. Handing one
/// model the other's options produces a voice that is subtly not the one the
/// weights were tuned for, which is why the presets are named rather than
/// blended.
public struct SamplingOptions: Sendable, Equatable, Codable {
    public var temperature: Float = 0.8
    public var topP: Float = 0.95
    public var topK: Int = 1000
    /// Drop everything less likely than this fraction of the best token.
    /// Relative to the peak rather than absolute, so it prunes hard when the
    /// model is confident and barely at all when it is not. Nano does not use
    /// it; the multilingual model uses it instead of top-k.
    public var minP: Float = 0
    public var repetitionPenalty: Float = 1.2
    /// How far to push away from the unconditional branch. Multilingual only:
    /// Nano's generator accepts it and then ignores it, so it is left at zero
    /// there rather than pretending.
    public var cfgWeight: Float = 0.5
    /// The emotion token's value in the conditioning prefix. Multilingual only,
    /// for the same reason.
    public var exaggeration: Float = 0.5
    /// Give up on a chunk after this many speech tokens (~48s of audio at
    /// 25 Hz).
    ///
    /// The engine takes `min` of this and what the KV cache can actually hold,
    /// so asking for more than the model allows costs nothing — it is a
    /// backstop against a chunk that never emits its stop token, not a budget
    /// to ration. Keeping it low was silently truncating long sentences.
    public var maxTokens: Int = 1200

    public init() {}

    /// What the multilingual checkpoint was tuned with, from
    /// `ChatterboxMultilingualTTS.generate`: no top-k, no nucleus cut, a
    /// relative floor instead, and guidance at a half.
    public static let multilingual: SamplingOptions = {
        var options = SamplingOptions()
        options.temperature = 0.8
        options.topP = 1.0
        options.topK = 0
        options.minP = 0.05
        options.repetitionPenalty = 1.2
        options.cfgWeight = 0.5
        options.exaggeration = 0.5
        return options
    }()

    /// Nano's, which are this type's defaults — named so a caller switching
    /// between engines can be explicit in both directions.
    public static let nano = SamplingOptions()
}

/// Turn logits into the next speech token.
///
/// The order of operations is copied from upstream, and there are two upstreams:
///
/// * **Nano** (`T3.inference_turbo`): temperature, top-k, top-p, then the
///   repetition penalty. Penalising last is unusual — most implementations do it
///   first — but matching the code the weights were tuned against matters more
///   than being conventional.
/// * **Multilingual** (`ChatterboxMultilingualTTS.generate`): the penalty
///   first, then temperature, then min-p, then top-p. Guidance has already been
///   applied inside the model by the time logits arrive here.
///
/// The difference is not cosmetic: a penalty applied before the temperature
/// divides an already-penalised logit, and applied after it does not. Same
/// numbers, different voice.
///
/// This runs ~1200 times per chunk over a vocabulary of 6563 or 8194, so it
/// keeps its scratch buffers between calls and sorts once: a single descending
/// index sort serves top-k (the k-th value is at rank k−1), min-p (the peak is
/// at rank 0) and top-p (the nucleus walk).
public struct Sampler {
    /// Which upstream's order to follow.
    public enum Order: Sendable {
        case nano
        case multilingual
    }

    public var options: SamplingOptions
    public var order: Order
    private var generator: SystemRandomNumberGenerator
    /// Token indices, descending by logit. Reused between calls.
    private var ranking: [vDSP_Length] = []
    /// Probabilities by rank (for top-p), then by token (for the draw).
    private var weights: [Float] = []

    public init(options: SamplingOptions, order: Order = .nano) {
        self.options = options
        self.order = order
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
        switch order {
        case .nano:
            applyTemperature(logits)
            applyCuts(logits, topK: true, minP: false)
            applyPenalty(logits, history: history)
        case .multilingual:
            applyPenalty(logits, history: history)
            applyTemperature(logits)
            applyCuts(logits, topK: false, minP: true)
        }
    }

    private func applyTemperature(_ logits: UnsafeMutableBufferPointer<Float>) {
        guard options.temperature > 0, options.temperature != 1 else { return }
        for i in 0..<logits.count { logits[i] /= options.temperature }
    }

    private func applyPenalty(
        _ logits: UnsafeMutableBufferPointer<Float>, history: Set<Int32>
    ) {
        guard options.repetitionPenalty != 1 else { return }
        let count = logits.count
        for token in history {
            let i = Int(token)
            guard i >= 0, i < count, logits[i].isFinite else { continue }
            // Divided when positive, multiplied when negative. The sign test is
            // not a detail: a flat divide would *raise* the probability of every
            // token whose logit is negative, which is most of the vocabulary.
            logits[i] = logits[i] < 0
                ? logits[i] * options.repetitionPenalty
                : logits[i] / options.repetitionPenalty
        }
    }

    /// The three cuts that need the logits sorted, done in one pass.
    private mutating func applyCuts(
        _ logits: UnsafeMutableBufferPointer<Float>, topK: Bool, minP: Bool
    ) {
        let count = logits.count
        let wantsTopK = topK && options.topK > 0 && options.topK < count
        let wantsMinP = minP && options.minP > 0
        let wantsTopP = options.topP < 1
        guard wantsTopK || wantsMinP || wantsTopP else { return }

        // Only the relative floor is wanted — which is the multilingual
        // preset, so this is the hot path — and it needs the peak alone, not
        // an order. The sort below is O(n log n) over the whole vocabulary and
        // runs ~1200 times per chunk; a max scan is all the floor requires.
        if wantsMinP, !wantsTopK, !wantsTopP {
            var peak: Float = 0
            var peakIndex: vDSP_Length = 0
            vDSP_maxvi(logits.baseAddress!, 1, &peak, &peakIndex, vDSP_Length(count))
            applyMinP(logits, peak: peak)
            return
        }

        if ranking.count != count {
            ranking = Array(0..<vDSP_Length(count))
        } else {
            for i in 0..<count { ranking[i] = vDSP_Length(i) }
        }
        vDSP_vsorti(logits.baseAddress!, &ranking, nil, vDSP_Length(count), -1)

        if wantsTopK {
            // Everything *below* the k-th value goes; ties with it stay,
            // which is what HuggingFace's TopKLogitsWarper keeps too.
            let cutoff = logits[Int(ranking[options.topK - 1])]
            for i in 0..<count where logits[i] < cutoff { logits[i] = -.infinity }
        }

        if wantsMinP { applyMinP(logits, peak: logits[Int(ranking[0])]) }
        if wantsTopP { applyTopP(logits) }
    }

    /// Keep everything within `minP` of the best token's probability.
    ///
    /// A ratio of probabilities is a difference of logits, so this needs no
    /// softmax: `p_i / p_max >= minP` is `logit_i >= logit_max + log(minP)`.
    /// The peak comes in from whichever caller already has it — the sorted
    /// path's rank zero, or the fast path's max scan.
    private func applyMinP(_ logits: UnsafeMutableBufferPointer<Float>, peak: Float) {
        guard peak.isFinite else { return }
        let floor = peak + logf(options.minP)
        for i in 0..<logits.count where logits[i] < floor { logits[i] = -.infinity }
    }

    /// Keep the smallest set of tokens whose probabilities sum past `topP`.
    /// `ranking` is already sorted descending when this runs.
    private mutating func applyTopP(_ logits: UnsafeMutableBufferPointer<Float>) {
        let count = logits.count
        let maximum = logits[Int(ranking[0])]
        guard maximum.isFinite else { return }

        if weights.count != count { weights = [Float](repeating: 0, count: count) }
        var total: Float = 0
        for rank in 0..<count {
            let value = logits[Int(ranking[rank])]
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
            if rank > 0, prefix >= options.topP { logits[Int(ranking[rank])] = -.infinity }
            prefix += weights[rank] / total
        }
    }

    private mutating func multinomial(_ logits: UnsafeMutableBufferPointer<Float>) -> Int32 {
        let count = logits.count
        var maximum = -Float.infinity
        for i in 0..<count where logits[i] > maximum { maximum = logits[i] }
        guard maximum.isFinite else {
            // Every token filtered out, or NaN logits: the model has gone
            // somewhere it cannot come back from. Token 0 keeps the loop
            // alive, but silently emitting it hid the fault — say so.
            PlaybackLog.note("sampler: degenerate distribution, no finite logit")
            return 0
        }

        if weights.count != count { weights = [Float](repeating: 0, count: count) }
        var total: Float = 0
        for i in 0..<count {
            let p = logits[i].isFinite ? expf(logits[i] - maximum) : 0
            weights[i] = p
            total += p
        }
        guard total > 0 else {
            PlaybackLog.note("sampler: degenerate distribution, probabilities sum to zero")
            return 0
        }

        let target = Float.random(in: 0..<total, using: &generator)
        var running: Float = 0
        for i in 0..<count {
            running += weights[i]
            if running > target { return Int32(i) }
        }
        return Int32(count - 1)
    }
}
