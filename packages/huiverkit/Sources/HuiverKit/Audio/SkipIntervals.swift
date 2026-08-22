import Foundation

/// The transport's two skip sizes, in one place.
///
/// They were hardcoded at four sites — both players, the mini players and the
/// lock screen — which is exactly how a settings change misses one. Stored in
/// UserDefaults so a listener who thinks in 10-second nudges is not stuck
/// with 15.
public enum SkipIntervals {
    public static let backwardChoices: [Double] = [5, 10, 15, 30]
    public static let forwardChoices: [Double] = [15, 30, 45, 60]

    public static var backward: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "skipBackward")
            return stored > 0 ? stored : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: "skipBackward") }
    }

    public static var forward: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "skipForward")
            return stored > 0 ? stored : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "skipForward") }
    }

    /// The SF Symbol for a skip button at this size, so every player draws
    /// the same glyph for the same jump.
    public static func symbol(back seconds: Double) -> String { "gobackward.\(Int(seconds))" }
    public static func symbol(forward seconds: Double) -> String { "goforward.\(Int(seconds))" }
}
