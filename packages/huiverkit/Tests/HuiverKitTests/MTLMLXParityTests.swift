#if canImport(MLX)
import CoreML
import Foundation
import Testing

@testable import HuiverKit

/// The MLX decode loop against the Core ML decode model, head to head.
///
/// Both are seeded from the *same* Core ML prefill output and stepped with the
/// *same* greedy token sequence, so every difference in the logits is decode
/// implementation difference and nothing else — no tokenizer, no sampler, no
/// prefill noise in the comparison. This is exactly the swap the engine makes
/// when `MTLT3Backbone.safetensors` is installed, tested at the seam where it
/// happens.
///
/// Both run in float16, each with its own rounding, so the logits are compared
/// with a tolerance and the *choice* — the greedy argmax — is what must agree.
struct MTLMLXParityTests {
    @Test("MLX decode matches Core ML decode", .timeLimit(.minutes(10)))
    func parity() async throws {
        try #require(MultilingualEngineTests.installed, "multilingual models not installed")
        let root = MultilingualEngineTests.root
        let models = root.appendingPathComponent("Models")
        let backbone = models.appendingPathComponent("MTLT3Backbone.safetensors")
        try #require(
            FileManager.default.fileExists(atPath: backbone.path),
            "MLX backbone not installed — run: bun run mac:backbone && bun run mac:install"
        )

        let voices = try VoicePack.load(from: root.appendingPathComponent("Voices"))
        let voice = try #require(voices.first { $0.id == "mtl_default" } ?? voices.first)

        // GPU/CPU for both Core ML models: the point is numerical parity, and
        // the prefill must never meet the ANE compiler anyway.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let prefill = try await MLModel.load(
            contentsOf: models.appendingPathComponent("MTLT3Prefill.mlmodelc"),
            configuration: configuration
        )
        let decode = try await MLModel.load(
            contentsOf: models.appendingPathComponent("MTLT3Decode.mlmodelc"),
            configuration: configuration
        )
        let mlx = try MTLDecodeMLX(weights: backbone)

        // A short Dutch sentence, tokenized the way the engine does it:
        // language-tagged graphemes bracketed by SOT/EOT.
        let tokenizer = try MTLTokenizer(directory: models)
        var textTokens = tokenizer.encode("De schrijver liep langzaam door de oude stad.", language: "nl")
        textTokens = [255] + textTokens + [0]

        func multiArray(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
            return array
        }
        func multiArray(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
            for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
            return array
        }

        let prefixOut = try await prefill.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: [
                "speaker_emb": try multiArray(
                    voice.speakerEmbedding, shape: [1, voice.speakerEmbedding.count]
                ),
                "prompt_tokens": try multiArray(
                    voice.condPromptTokens, shape: [1, voice.condPromptTokens.count]
                ),
                "text_tokens": try multiArray(textTokens, shape: [1, textTokens.count]),
                "emotion": try multiArray([0.5], shape: [1, 1]),
            ])
        )
        let prefixLogits = try #require(prefixOut.featureValue(for: "logits")?.multiArrayValue)
        let keys = try #require(prefixOut.featureValue(for: "k_cache")?.multiArrayValue)
        let values = try #require(prefixOut.featureValue(for: "v_cache")?.multiArrayValue)

        // Both start-of-speech tokens are in the prefill's output, so the
        // prefix is conditioning + text + 2.
        let prefixLength = 34 + textTokens.count + 2
        let cfgWeight: Float = 0.5

        // Seed both caches from the same prefill tensors.
        mlx.seed(keys: keys, values: values, length: prefixLength)
        let state = decode.makeState()
        seed(state: state, keys: keys, values: values, length: prefixLength, context: mlx.config.maxContext)

        // First token: guide the prefill's two rows by hand, take the argmax.
        var current = argmax(guide(prefixLogits, weight: cfgWeight))

        // Step both decoders with the same tokens, greedily from Core ML's
        // choice, and compare every step's guided logits.
        let steps = 48
        var agreements = 0
        var worst: Float = 0
        let tokenInput = try multiArray([Int32(0)], shape: [1, 1])
        let positionInput = try multiArray([Int32(0)], shape: [1])
        let speechPositionInput = try multiArray([Int32(0)], shape: [1])
        let guidanceInput = try multiArray([cfgWeight], shape: [1])
        let stepInput = try MLDictionaryFeatureProvider(dictionary: [
            "token": tokenInput,
            "position": positionInput,
            "speech_position": speechPositionInput,
            "cfg_weight": guidanceInput,
        ])

        for step in 0..<steps {
            tokenInput[0] = NSNumber(value: current)
            positionInput[0] = NSNumber(value: Int32(prefixLength + step))
            speechPositionInput[0] = NSNumber(value: Int32(step + 1))

            let coreOut = try await decode.prediction(from: stepInput, using: state)
            let coreLogits = try #require(coreOut.featureValue(for: "logits")?.multiArrayValue)
            var core = [Float](repeating: 0, count: coreLogits.count)
            coreLogits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                core = Array(buffer)
            }

            let ours = mlx.step(
                token: current, position: prefixLength + step,
                speechPosition: step + 1, cfgWeight: cfgWeight
            )

            #expect(ours.count == core.count)
            let coreChoice = argmax(core)
            let ourChoice = argmax(ours)
            if coreChoice == ourChoice { agreements += 1 }

            // Compare where it matters: near the top of the distribution.
            // Both graphs run float16, so the far tail (logits around -20)
            // wobbles by more than the tolerance and none of it is ever
            // sampled — min-p prunes everything below 5% of the peak.
            let peak = core.max() ?? 0
            for index in 0..<core.count where core[index] > peak - 5 {
                worst = max(worst, abs(core[index] - ours[index]))
            }

            current = coreChoice
            if current == Int32(mlx.config.stopSpeechToken) { break }
        }

        print("PARITY: \(agreements)/\(steps) greedy choices agree, worst top-band diff \(worst)")
        #expect(agreements >= steps - 2, "greedy paths diverged more than fp16 noise explains")
        #expect(worst < 0.75, "top-band logit drift beyond fp16 rounding")
    }

    private func guide(_ logits: MLMultiArray, weight: Float) -> [Float] {
        let vocabulary = logits.count / 2
        var out = [Float](repeating: 0, count: vocabulary)
        logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            for index in 0..<vocabulary {
                let cond = buffer[index]
                let uncond = buffer[vocabulary + index]
                out[index] = cond + weight * (cond - uncond)
            }
        }
        return out
    }

    private func argmax(_ values: [Float]) -> Int32 {
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return Int32(best)
    }

    /// The engine's `seed`, reproduced: copy the prefill's cache into the
    /// Core ML decode state, one contiguous (layer, row, head) run at a time.
    private func seed(
        state: MLState, keys: MLMultiArray, values: MLMultiArray, length: Int, context: Int
    ) {
        for (name, source) in [("k_cache", keys), ("v_cache", values)] {
            let element = source.dataType == .float16 ? 2 : 4
            let row = length * 64 * element
            let stride = context * 64 * element
            let rows = 30 * 2 * 16
            struct Span: @unchecked Sendable { let base: UnsafeRawPointer }
            source.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                let span = Span(base: base)
                state.withMultiArray(for: name) { destination in
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
}
#endif
