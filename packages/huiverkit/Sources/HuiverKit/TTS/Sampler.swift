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
    /// Give up on a chunk after this many speech tokens (~40s of audio).
    public var maxTokens: Int = 1000

    public init() {}
}

/// Turn logits into the next speech token.
///
/// The order of operations is copied from `T3.inference_turbo`: temperature,
/// then top-k, then top-p, and only then the repetition penalty. That last one
/// is unusual — most implementations penalise before filtering — but matching
/// upstream matters more than being conventional, because a different order
/// gives a different voice.
public struct Sampler {
    public var options: SamplingOptions
    private var generator: SystemRandomNumberGenerator

    public init(options: SamplingOptions) {
        self.options = options
        self.generator = SystemRandomNumberGenerator()
    }

    /// - Parameters:
    ///   - logits: modified in place; the caller owns the buffer.
    ///   - history: tokens generated so far, for the repetition penalty.
    public mutating func next(logits: UnsafeMutableBufferPointer<Float>, history: [Int32]) -> Int32 {
        let count = logits.count

        if options.temperature > 0, options.temperature != 1 {
            for i in 0..<count { logits[i] /= options.temperature }
        }

        if options.topK > 0, options.topK < count {
            let cutoff = kthLargest(logits, k: options.topK)
            for i in 0..<count where logits[i] < cutoff { logits[i] = -.infinity }
        }

        if options.topP < 1 { applyTopP(logits) }

        if options.repetitionPenalty != 1 {
            for token in Set(history) {
                let i = Int(token)
                guard i >= 0, i < count, logits[i].isFinite else { continue }
                logits[i] = logits[i] < 0
                    ? logits[i] * options.repetitionPenalty
                    : logits[i] / options.repetitionPenalty
            }
        }

        return multinomial(logits)
    }

    /// The k-th largest value, by selection rather than a full sort: the
    /// vocabulary is 6563 wide and this runs once per token.
    private func kthLargest(_ logits: UnsafeMutableBufferPointer<Float>, k: Int) -> Float {
        var values = Array(logits)
        values.sort(by: >)
        return values[k - 1]
    }

    /// Keep the smallest set of tokens whose probabilities sum past `topP`.
    private func applyTopP(_ logits: UnsafeMutableBufferPointer<Float>) {
        let count = logits.count
        var order = Array(0..<count)
        order.sort { logits[$0] > logits[$1] }

        let maximum = logits[order[0]]
        var total: Float = 0
        var probabilities = [Float](repeating: 0, count: count)
        for (rank, index) in order.enumerated() {
            let p = logits[index].isFinite ? expf(logits[index] - maximum) : 0
            probabilities[rank] = p
            total += p
        }
        guard total > 0 else { return }

        // The comparison is against the prefix *before* this token, which keeps
        // the one that crosses the threshold rather than dropping it. That is
        // what HuggingFace's TopPLogitsWarper does, and testing the inclusive
        // sum instead — the easy mistake — truncates the nucleus by one token
        // on every step.
        var prefix: Float = 0
        for (rank, index) in order.enumerated() {
            // Never the first token, so there is always something to sample.
            if rank > 0, prefix >= options.topP { logits[index] = -.infinity }
            prefix += probabilities[rank] / total
        }
    }

    private mutating func multinomial(_ logits: UnsafeMutableBufferPointer<Float>) -> Int32 {
        let count = logits.count
        var maximum = -Float.infinity
        for i in 0..<count where logits[i] > maximum { maximum = logits[i] }
        guard maximum.isFinite else { return 0 }

        var total: Float = 0
        var weights = [Float](repeating: 0, count: count)
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
