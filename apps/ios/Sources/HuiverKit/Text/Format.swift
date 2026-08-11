import Foundation

/// Durations, spelled the way the other two apps spell them.
///
/// A port of `packages/shared/src/format.ts`. Worth keeping identical: the same
/// chapter should not read "42 min" in one app and "0:42:14" in another.
public enum Format {
    /// Clock-style: `4:05`, or `1:04:05` once there is an hour to show.
    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let total = Int(max(0, seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Human-scale, for totals and estimates: `42 min`, `7 h 40 min`.
    public static func approximate(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest > 0 ? "\(hours) h \(rest) min" : "\(hours) h"
    }

    /// The same, marked as an expectation rather than a measurement.
    public static func estimate(_ seconds: Double) -> String { "~\(approximate(seconds))" }

    /// How long a chapter will take to read, before any of it has been rendered.
    ///
    /// Chatterbox speaks at roughly fifteen characters a second. Once part of a
    /// chapter exists the measured rate is better, which is what
    /// `charactersPerSecond` is for.
    public static let assumedCharactersPerSecond: Double = 15

    /// Characters per second measured from whatever has actually been rendered,
    /// falling back to the assumption when nothing has.
    public static func charactersPerSecond(_ chapters: [Chapter], seconds: [String: Double]) -> Double {
        var characters = 0.0
        var total = 0.0
        for chapter in chapters where chapter.isComplete {
            guard let measured = seconds[chapter.id], measured > 0 else { continue }
            characters += Double(chapter.characters)
            total += measured
        }
        guard total > 0, characters > 0 else { return assumedCharactersPerSecond }
        return characters / total
    }
}
