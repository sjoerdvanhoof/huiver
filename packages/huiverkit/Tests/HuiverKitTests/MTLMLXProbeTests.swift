#if canImport(MLX)
import CoreML
import Foundation
import Testing

@testable import HuiverKit

/// Where the MLX step's time actually goes. Not a pass/fail test of anything
/// but existence — it prints per-step latency at two cache depths and again
/// after a seed, which separates "the matmuls are the cost" from "per-op
/// overhead is the cost" from "the seeded cache defeats buffer donation and
/// every step pays a full cache copy".
struct MTLMLXProbeTests {
    @Test("times the raw MLX step", .timeLimit(.minutes(10)))
    func probe() async throws {
        let backbone = MultilingualEngineTests.root
            .appendingPathComponent("Models/MTLT3Backbone.safetensors")
        try #require(FileManager.default.fileExists(atPath: backbone.path))
        let mlx = try MTLDecodeMLX(weights: backbone)

        func time(_ position: Int, steps: Int) -> Double {
            // Warm up: first calls pay kernel JIT compilation.
            for step in 0..<10 {
                _ = mlx.step(token: 100, position: position + step, speechPosition: step + 1, cfgWeight: 0.5)
            }
            let clock = ContinuousClock.now
            for step in 0..<steps {
                _ = mlx.step(
                    token: Int32(100 + step), position: position + 10 + step,
                    speechPosition: 10 + step + 1, cfgWeight: 0.5
                )
            }
            let elapsed = clock.duration(to: .now)
            return (Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18) / Double(steps)
        }

        let shallow = time(180, steps: 100)
        let deep = time(1_100, steps: 100)

        // Again after a seed, which is how the engine actually reaches the
        // loop.
        let length = 180
        let cache = try MLMultiArray(
            shape: [30, 2, 16, length, 64].map { NSNumber(value: $0) }, dataType: .float32
        )
        try mlx.seed(keys: cache, values: cache, length: length)
        let seeded = time(180, steps: 100)

        print(String(
            format: "PROBE: %.1f ms/step at live~200, %.1f at live~1150, %.1f after seed",
            shallow * 1000, deep * 1000, seeded * 1000
        ))

        // The prefill, repeated and at a neighbouring length — if the repeat
        // is fast but the new length is slow again, the cost is per-shape
        // kernel JIT rather than the arithmetic.
        let cond = try MLMultiArray(
            shape: [1, 34, 1024].map { NSNumber(value: $0) }, dataType: .float32
        )
        func timePrefill(_ count: Int) throws -> Double {
            let clock = ContinuousClock.now
            _ = try mlx.prefill(cond: cond, textTokens: Array(repeating: 42, count: count))
            let elapsed = clock.duration(to: .now)
            return Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }
        let firstLong = try timePrefill(265)
        let repeatLong = try timePrefill(265)
        let neighbour = try timePrefill(266)
        print(String(
            format: "PREFILL PROBE: 265 first %.2fs, repeat %.2fs, 266 %.2fs",
            firstLong, repeatLong, neighbour
        ))
    }
}
#endif
