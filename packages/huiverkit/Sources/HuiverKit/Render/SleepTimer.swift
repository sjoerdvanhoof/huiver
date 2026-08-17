import Foundation
import Observation

/// Stop reading after a while.
///
/// Kept out of `Narrator` deliberately. The narrator is a player: it knows how
/// to schedule audio and where the playhead is, and every bug in its history
/// has come from it also being asked to hold policy. This holds the policy and
/// asks the narrator for two things — fade out now, or stop when this chapter
/// ends.
@MainActor
@Observable
public final class SleepTimer {
    public enum Mode: Equatable, Sendable, Hashable {
        case minutes(Int)
        /// The natural place to stop for anyone who falls asleep mid-book, and
        /// the reason `Narrator.autoAdvance` exists to be suppressed.
        case endOfChapter

        public var label: String {
            switch self {
            case .minutes(let count): return "\(count) minutes"
            case .endOfChapter: return "End of chapter"
            }
        }
    }

    /// What the menu offers.
    public static let presets: [Mode] = [
        .minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter,
    ]

    /// How long the volume ramp takes. Long enough to be a fade rather than a
    /// cut, short enough not to lose a paragraph to it.
    public static let fadeSeconds: Double = 8

    public private(set) var mode: Mode?
    /// Seconds left, for a countdown in the menu. Nil for `.endOfChapter`,
    /// which has no clock.
    public private(set) var remaining: TimeInterval?

    public var isArmed: Bool { mode != nil }

    /// Set when the timer is armed and disarmed. The narrator is handed in
    /// rather than held, so this type stays testable without an audio engine.
    private var onFade: ((Double) -> Void)?
    private var onStopAtChapterEnd: ((Bool) -> Void)?
    private var onCancelFade: (() -> Void)?
    private var countdown: Task<Void, Never>?

    public init() {}

    /// Wire the timer to a narrator. Called once, after both exist.
    public func attach(
        fade: @escaping (Double) -> Void,
        stopAtChapterEnd: @escaping (Bool) -> Void,
        cancelFade: @escaping () -> Void = {}
    ) {
        onFade = fade
        onStopAtChapterEnd = stopAtChapterEnd
        onCancelFade = cancelFade
    }

    public func start(_ mode: Mode) {
        cancel()
        self.mode = mode

        switch mode {
        case .endOfChapter:
            remaining = nil
            onStopAtChapterEnd?(true)
        case .minutes(let minutes):
            let total = TimeInterval(minutes * 60)
            remaining = total
            countdown = Task { [weak self] in
                var left = total
                while left > 0, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    left -= 1
                    self?.remaining = max(0, left)
                    // Start the fade before the end rather than at it, so the
                    // book trails off instead of stopping mid-word.
                    if left == SleepTimer.fadeSeconds {
                        self?.onFade?(SleepTimer.fadeSeconds)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    public func cancel() {
        countdown?.cancel()
        countdown = nil
        // Cancelling in the final seconds must also abandon the volume ramp
        // already running — without this the fade completed and paused anyway,
        // right after the listener asked it not to.
        if case .minutes = mode { onCancelFade?() }
        if mode == .endOfChapter { onStopAtChapterEnd?(false) }
        mode = nil
        remaining = nil
    }

    /// The clock ran out. The fade has already happened; this is only the
    /// bookkeeping.
    private func finish() {
        countdown = nil
        mode = nil
        remaining = nil
    }
}
