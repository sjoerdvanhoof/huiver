import Foundation

/// Keeps the machine awake while there is synthesis to do.
///
/// A Mac left converting a book is this app's core promise, and the default
/// idle-sleep timer breaks it silently: the queue stops mid-chapter and the
/// morning finds it exactly where the display slept. Playback needs no help —
/// audible audio holds the system awake on its own — but a render pass between
/// chunks is just compute, which is exactly what idle sleep interrupts.
///
/// Refcounted, because the narrator and the converter can both be rendering.
/// On iOS this is a no-op: the phone's lifecycle is bought chunk by chunk with
/// background assertions in `Converter` instead.
@MainActor
enum PowerAssertion {
    #if os(macOS)
    private static var holders = 0
    private static var activity: NSObjectProtocol?
    #endif

    static func begin() {
        #if os(macOS)
        holders += 1
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "Synthesizing speech"
        )
        #endif
    }

    static func end() {
        #if os(macOS)
        holders = max(0, holders - 1)
        guard holders == 0, let current = activity else { return }
        ProcessInfo.processInfo.endActivity(current)
        activity = nil
        #endif
    }
}
