import Foundation
import os

/// One log for everything about playing a chapter.
///
/// Off-screen playback cannot be debugged by looking at it: the interesting
/// moments happen while the phone is locked, at the hands of MediaPlayer and the
/// audio engine rather than of a person.
///
/// It goes to two places. The unified log is the proper home and shows up in
/// Console.app, but `log collect` from an attached device needs root on the Mac,
/// which makes it useless for an unattended phone. So every line is also
/// appended to `Documents/playback.log`, which comes off the device with no
/// privileges at all:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer --domain-identifier online.mo4.huiver.nano \
///       --source Documents/playback.log --destination /tmp/playback.log
enum PlaybackLog {
    static let logger = Logger(subsystem: "online.mo4.huiver.nano", category: "playback")

    static func note(_ message: String) {
        logger.info("\(message, privacy: .public)")
        trail.append(message)
    }

    private static let trail = Trail()

    /// The copy on disk. Its own queue, so a log line never waits on the disk
    /// while audio is being scheduled, and never lands out of order.
    private final class Trail: @unchecked Sendable {
        private let queue = DispatchQueue(label: "online.mo4.huiver.nano.playback-log")
        private let url = URL.documentsDirectory.appendingPathComponent("playback.log")
        /// Enough to hold a long listening session, small enough to pull over
        /// USB without thinking about it. Past this the file starts again.
        private let limit = 512 * 1024

        func append(_ message: String) {
            let stamp = Date()
            queue.async { [url, limit] in
                let line = "\(stamp.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
                guard let data = line.data(using: .utf8) else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.size] as? Int } ?? 0
                if size < limit, let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    // No file yet, or it has grown past the limit: start again.
                    try? data.write(to: url)
                }
            }
        }
    }
}
