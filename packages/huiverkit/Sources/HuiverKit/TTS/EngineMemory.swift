import Foundation
#if canImport(MLX)
import MLX
#endif

/// The MLX allocator's manners.
///
/// MLX pools every buffer it frees and, by default, lets the pool grow to the
/// machine's memory limit — a research default that reads as a multi-gigabyte
/// app in Activity Monitor. Only transients live in the pool: the weights and
/// the KV cache are active memory and never evicted, so bounding it costs an
/// occasional re-allocation during prefill and nothing in the compiled decode
/// loop, whose buffers are in use and untouchable.
///
/// Compiles to no-ops where MLX is not linked (the iOS app), so callers do
/// not need the `#if`.
public enum EngineMemory {
    /// One gigabyte: comfortably above the largest prefill's transients, far
    /// below where the default lets the pool wander.
    public static let cacheBytes = 1 << 30

    /// Bound the pool. Called once, when the MLX decode path loads.
    static func capCache() {
        #if canImport(MLX)
        Memory.cacheLimit = cacheBytes
        #endif
    }

    /// Give the pool back to the OS, for the moments nothing is synthesizing.
    /// Idle is measured against synthesis, not sound — playing already
    /// rendered audio never touches MLX.
    public static func trim() {
        #if canImport(MLX)
        Memory.clearCache()
        #endif
    }
}
