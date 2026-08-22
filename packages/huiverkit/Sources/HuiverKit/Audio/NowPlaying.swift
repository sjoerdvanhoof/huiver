import Foundation
import MediaPlayer

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The lock screen, Control Centre, CarPlay and headphone buttons.
///
/// Playing audio in the background is not enough to get controls off screen. iOS
/// only draws them for an app that does both halves of the deal: publishes
/// metadata to `MPNowPlayingInfoCenter`, and accepts commands through
/// `MPRemoteCommandCenter`. Miss either and the lock screen shows nothing while
/// the book keeps reading itself.
///
/// This is a plain sink. The narrator pushes a `Snapshot` whenever anything the
/// lock screen shows has changed, and commands come back as closures rather than
/// as a reference to the narrator, so ownership runs one way only.
@MainActor
final class NowPlaying {
    /// What the lock screen is allowed to ask for.
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        /// Seconds, signed — the ±15/30 buttons.
        var skip: (Double) -> Void
        /// An absolute position in the chapter, from dragging the lock screen bar.
        var seek: (Double) -> Void
        var changeChapter: (Int) -> Void
        var setRate: (Float) -> Void
    }

    /// Everything shown off screen, as of now.
    ///
    /// `Equatable` so that repeated pushes of an unchanged state cost nothing:
    /// the narrator's ticker fires four times a second, and the info centre is a
    /// handoff to another process rather than a local property.
    struct Snapshot: Equatable {
        var chapterTitle: String
        var bookTitle: String
        var author: String?
        /// One-based, for the "3 of 24" the lock screen can show.
        var chapterNumber: Int?
        var chapterCount: Int?
        var duration: Double
        var position: Double
        var rate: Float
        var isPlaying: Bool
        var hasNextChapter: Bool
        var hasPreviousChapter: Bool
        var coverURL: URL?
    }

    /// The same jumps as the in-app transport, so what a listener learns on
    /// screen still holds on the lock screen. Read from the shared setting;
    /// the intervals are registered at activation, so a change takes effect
    /// at the next launch.
    static var skipBackward: Double { SkipIntervals.backward }
    static var skipForward: Double { SkipIntervals.forward }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private var commands: Commands?
    /// The last state handed to the system, at the resolution the system shows
    /// it in, which is what makes the dedupe in `update` worth doing.
    private var pushed: Snapshot?

    /// Artwork is read once per cover rather than once per push, and pushed
    /// again when it lands.
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    // MARK: - Wiring

    /// Take over the remote commands.
    ///
    /// Called once, when the narrator is built. The handlers stay registered for
    /// the life of the app and are only enabled or disabled per snapshot: a
    /// target added on every play would stack up and fire once per registration.
    func activate(commands: Commands) {
        self.commands = commands
        // Targets are never removed, so a second registration would mean every
        // command running twice. If this line ever appears twice in one launch,
        // that is the bug.
        PlaybackLog.note("registering remote commands (\(ObjectIdentifier(self)))")
        let centre = MPRemoteCommandCenter.shared()

        on(centre.playCommand, "play") { $0.play() }
        on(centre.pauseCommand, "pause") { $0.pause() }
        on(centre.togglePlayPauseCommand, "toggle") { $0.toggle() }
        on(centre.nextTrackCommand, "next") { $0.changeChapter(1) }
        on(centre.previousTrackCommand, "previous") { $0.changeChapter(-1) }

        centre.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackward)]
        on(centre.skipBackwardCommand, "skipBack", reading: Self.interval) { $0.skip(-$1) }
        centre.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        on(centre.skipForwardCommand, "skipForward", reading: Self.interval) { $0.skip($1) }

        on(centre.changePlaybackPositionCommand, "seek", reading: Self.positionTime) { $0.seek($1) }

        centre.changePlaybackRateCommand.supportedPlaybackRates =
            Self.rates.map { NSNumber(value: $0) }
        on(centre.changePlaybackRateCommand, "rate", reading: Self.playbackRate) { $0.setRate($1) }

        // Continuous scrubbing has no meaning here: seeking is bounded by what
        // has been rendered, so holding the button would run into that edge
        // rather than fast-forward.
        centre.seekForwardCommand.isEnabled = false
        centre.seekBackwardCommand.isEnabled = false
    }

    private nonisolated static let interval: @Sendable (MPRemoteCommandEvent) -> Double? = {
        ($0 as? MPSkipIntervalCommandEvent)?.interval
    }
    private nonisolated static let positionTime: @Sendable (MPRemoteCommandEvent) -> Double? = {
        ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime
    }
    private nonisolated static let playbackRate: @Sendable (MPRemoteCommandEvent) -> Float? = {
        ($0 as? MPChangePlaybackRateCommandEvent)?.playbackRate
    }

    /// Remote commands arrive on the main thread in practice, but MediaPlayer
    /// promises nothing, so the work hops onto the main actor rather than
    /// asserting it is already there — a wrong assertion here would be a crash
    /// on a lock screen tap.
    ///
    /// The handler is `@Sendable` for the same reason the artwork handler is:
    /// without it, a closure written in this `@MainActor` method is inferred to
    /// be isolated to the main actor, and MediaPlayer calling it from anywhere
    /// else would trap rather than merely be racy.
    private func on(
        _ command: MPRemoteCommand,
        _ name: String,
        _ action: @escaping @Sendable @MainActor (Commands) -> Void
    ) {
        command.addTarget { @Sendable [weak self] _ in
            // Logged here, before the hop, so the order the system sent them in
            // survives — which is the question when one tap produces two
            // commands that undo each other.
            PlaybackLog.note("remote \(name)")
            guard let self else { return .commandFailed }
            Task { @MainActor in
                guard let commands = self.commands else { return }
                action(commands)
            }
            return .success
        }
    }

    /// As above, for the commands that carry a value. The value is read on the
    /// calling thread because an `MPRemoteCommandEvent` cannot cross actors.
    private func on<Value: Sendable>(
        _ command: MPRemoteCommand,
        _ name: String,
        reading value: @escaping @Sendable (MPRemoteCommandEvent) -> Value?,
        _ action: @escaping @Sendable @MainActor (Commands, Value) -> Void
    ) {
        command.addTarget { @Sendable [weak self] event in
            PlaybackLog.note("remote \(name)")
            guard let self, let value = value(event) else { return .commandFailed }
            Task { @MainActor in
                guard let commands = self.commands else { return }
                action(commands, value)
            }
            return .success
        }
    }

    // MARK: - Publishing

    func update(_ snapshot: Snapshot) {
        // Elapsed time is compared at whole seconds, because that is all the
        // lock screen shows and it extrapolates between pushes from the
        // playback rate anyway.
        var coarse = snapshot
        coarse.position = snapshot.position.rounded()
        guard coarse != pushed else { return }
        pushed = coarse

        if snapshot.coverURL != artworkURL { loadArtwork(snapshot.coverURL) }

        let centre = MPRemoteCommandCenter.shared()
        centre.nextTrackCommand.isEnabled = snapshot.hasNextChapter
        centre.previousTrackCommand.isEnabled = snapshot.hasPreviousChapter

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.chapterTitle,
            MPMediaItemPropertyAlbumTitle: snapshot.bookTitle,
            MPMediaItemPropertyPlaybackDuration: max(snapshot.duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(snapshot.position, 0),
            // Zero rather than the chosen rate while paused: the rate is what
            // the lock screen counts with, so leaving it set makes a paused book
            // carry on ticking up.
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let author = snapshot.author { info[MPMediaItemPropertyArtist] = author }
        if let number = snapshot.chapterNumber {
            info[MPNowPlayingInfoPropertyChapterNumber] = number
        }
        if let count = snapshot.chapterCount {
            info[MPNowPlayingInfoPropertyChapterCount] = count
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = snapshot.isPlaying ? .playing : .paused
        PlaybackLog.note(
            """
            push isPlaying=\(snapshot.isPlaying) pos=\(String(format: "%.0f", snapshot.position)) \
            of \(String(format: "%.0f", snapshot.duration)) rate=\(snapshot.rate) \
            artwork=\(artwork != nil)
            """
        )
    }

    /// Nothing is playing any more: take the controls down.
    ///
    /// Idempotent, because the narrator publishes on a timer and being stopped
    /// is a state it can sit in for a long time.
    func clear() {
        guard pushed != nil || artworkURL != nil else { return }
        PlaybackLog.note("clearing the lock screen")
        pushed = nil
        artworkURL = nil
        artwork = nil
        let centre = MPRemoteCommandCenter.shared()
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Artwork

    /// Read the cover off disk without blocking the main actor, then push it.
    ///
    /// `Data` is what crosses back, not a `UIImage`, so nothing that is awkward
    /// to send between actors has to be.
    private func loadArtwork(_ url: URL?) {
        artworkURL = url
        artwork = nil
        guard let url else { return }
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            #if os(iOS)
            guard let self, artworkURL == url, let data, let image = UIImage(data: data)
            else { return }
            #else
            guard let self, artworkURL == url, let data, let image = NSImage(data: data)
            else { return }
            #endif
            // `@Sendable` is doing real work here rather than quieting a
            // warning: MediaPlayer calls this handler on its own queue, and a
            // closure written in a `@MainActor` method is otherwise inferred to
            // be main-actor isolated, so the runtime traps on the isolation
            // check and the app dies the first time a cover is encoded.
            artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            // The snapshot that wanted this artwork has already gone out, so it
            // is re-sent rather than left waiting for the state to change.
            if let pushed {
                self.pushed = nil
                update(pushed)
            }
        }
    }
}
