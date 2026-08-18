import Foundation
import Testing

@testable import HuiverKit

/// The sampler decides what the voice actually says, and its filtering has to
/// agree with the logits processors chatterbox drives the model with. The order
/// matters too — temperature, top-k, top-p, then the repetition penalty, which
/// is unusual but is what `T3.inference_turbo` does.
struct SamplerTests {
    /// Which tokens survive filtering, found by sampling often enough that
    /// anything reachable turns up.
    func reachable(_ logits: [Float], _ options: SamplingOptions, draws: Int = 4000) -> Set<Int32> {
        var seen: Set<Int32> = []
        var sampler = Sampler(options: options)
        for _ in 0..<draws {
            var copy = logits
            copy.withUnsafeMutableBufferPointer { seen.insert(sampler.next(logits: $0, history: [])) }
        }
        return seen
    }

    @Test("top-p keeps the token that crosses the threshold")
    func topPBoundary() {
        // Probabilities 0.6, 0.3, 0.1. With top_p = 0.95 the nucleus is all
        // three: the prefix before the last token is 0.9, which is under the
        // threshold. Testing the inclusive sum instead would drop it.
        let logits = [0.6, 0.3, 0.1].map { Float(log($0)) }
        var options = SamplingOptions()
        options.temperature = 1
        options.topK = 0
        options.topP = 0.95
        options.repetitionPenalty = 1
        #expect(reachable(logits, options) == [0, 1, 2])
    }

    @Test("top-p cuts the tail")
    func topPCuts() {
        let logits = [0.9, 0.06, 0.04].map { Float(log($0)) }
        var options = SamplingOptions()
        options.temperature = 1
        options.topK = 0
        options.topP = 0.9
        options.repetitionPenalty = 1
        // Prefix before token 1 is 0.9, which is not under 0.9, so only the
        // first survives.
        #expect(reachable(logits, options) == [0])
    }

    @Test("top-k keeps exactly k")
    func topK() {
        let logits: [Float] = [5, 4, 3, 2, 1]
        var options = SamplingOptions()
        options.temperature = 1
        options.topK = 2
        options.topP = 1
        options.repetitionPenalty = 1
        #expect(reachable(logits, options) == [0, 1])
    }

    @Test("always returns something when only one token survives")
    func degenerate() {
        var options = SamplingOptions()
        options.topK = 1
        options.topP = 1
        options.repetitionPenalty = 1
        #expect(reachable([1, 2, 9, 3], options, draws: 20) == [2])
    }

    /// The sampler was rewritten for speed (one shared index sort and reused
    /// scratch, instead of a fresh sorted copy per stage). Everything before
    /// the random draw is deterministic, so the rewrite must reproduce the
    /// original — transcribed below — bit for bit.
    @Test("filtering matches the original implementation exactly")
    func filterMatchesReference() {
        func original(_ logits: inout [Float], _ options: SamplingOptions, _ history: Set<Int32>) {
            let count = logits.count
            if options.temperature > 0, options.temperature != 1 {
                for i in 0..<count { logits[i] /= options.temperature }
            }
            if options.topK > 0, options.topK < count {
                var values = logits
                values.sort(by: >)
                let cutoff = values[options.topK - 1]
                for i in 0..<count where logits[i] < cutoff { logits[i] = -.infinity }
            }
            if options.topP < 1 {
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
                if total > 0 {
                    var prefix: Float = 0
                    for (rank, index) in order.enumerated() {
                        if rank > 0, prefix >= options.topP { logits[index] = -.infinity }
                        prefix += probabilities[rank] / total
                    }
                }
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

        // Deterministic pseudo-random logits, so a failure reproduces.
        var seed: UInt64 = 0x5eed
        func random() -> Float {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Float(seed % 10_000) / 1_000 - 5
        }

        for temperature in [Float(0.8), 1] {
            for topK in [0, 3, 40, 10_000] {
                for topP in [Float(0.9), 0.95, 1] {
                    for penalty in [Float(1), 1.2] {
                        var options = SamplingOptions()
                        options.temperature = temperature
                        options.topK = topK
                        options.topP = topP
                        options.repetitionPenalty = penalty

                        let logits = (0..<257).map { _ in random() }
                        let history: Set<Int32> = [0, 5, 17, 200]

                        var want = logits
                        original(&want, options, history)
                        var got = logits
                        var sampler = Sampler(options: options)
                        got.withUnsafeMutableBufferPointer {
                            sampler.filter(logits: $0, history: history)
                        }
                        #expect(
                            got == want,
                            "diverged at temperature \(temperature), topK \(topK), topP \(topP), penalty \(penalty)"
                        )
                    }
                }
            }
        }
    }

    @Test("repetition penalty pushes a repeated token down")
    func repetition() {
        // Two equally likely tokens, one of them already used. The penalty
        // divides a positive score, so the used one should come up less often.
        let logits: [Float] = [2, 2]
        var options = SamplingOptions()
        options.temperature = 1
        options.topK = 0
        options.topP = 1
        options.repetitionPenalty = 1.5

        var sampler = Sampler(options: options)
        var zeros = 0
        for _ in 0..<2000 {
            var copy = logits
            copy.withUnsafeMutableBufferPointer {
                if sampler.next(logits: $0, history: [0]) == 0 { zeros += 1 }
            }
        }
        #expect(zeros < 900, "penalised token came up \(zeros)/2000 times")
    }
}
