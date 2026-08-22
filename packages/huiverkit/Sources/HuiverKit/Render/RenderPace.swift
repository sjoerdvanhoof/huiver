import Foundation

/// How fast this device actually renders, measured rather than guessed.
///
/// Every screen that promises a conversion time used to have nothing to
/// promise it with: the engine logged a ×realtime figure per chunk and threw
/// it away. This keeps a blended factor — seconds of compute per second of
/// audio — in UserDefaults, so "convert this book" can be told in minutes
/// rather than discovered in hours.
///
/// A blend rather than the last measurement: chunk cost varies with length
/// and with what else the machine is doing, and an estimate that jumped
/// around per chunk would read as a countdown that cannot make up its mind.
public enum RenderPace {
    static let key = "renderRealtimeFactor"

    /// Seconds of compute per second of audio, or nil before the first
    /// measured render on this device.
    public static var factor: Double? {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : nil
    }

    /// Record a measured stretch of synthesis. Ignores stubs — a chunk read
    /// off disk, a cancelled pass — which would otherwise pull the blend
    /// toward zero.
    public static func record(spent: Double, audioSeconds: Double) {
        guard audioSeconds > 1, spent > 0 else { return }
        let measured = spent / audioSeconds
        let blended = factor.map { $0 * 0.7 + measured * 0.3 } ?? measured
        UserDefaults.standard.set(blended, forKey: key)
    }

    /// The compute estimate for text of this many characters, or nil before
    /// anything has been measured. Uses the same chars-per-second guess the
    /// listening estimates use, times the measured factor.
    public static func estimate(characters: Int) -> Double? {
        guard let factor else { return nil }
        return Double(characters) / Format.assumedCharactersPerSecond * factor
    }
}
