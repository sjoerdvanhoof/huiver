import AVFoundation
import Foundation
import Observation

/// Renders a chapter and plays it, at the same time.
///
/// Playback walks the per-chunk WAVs rather than streaming one open-ended file.
/// The desktop app can pipe a growing MP3 to an `<audio>` element; iOS cannot
/// seek a stream whose length it does not know, so each chunk is scheduled on
/// an `AVAudioPlayerNode` as it lands. Seeking backwards inside what has been
/// rendered is then exact — it is a different file, not a guess at a byte
/// offset.
///
/// Audio starts after the first chunk, which is a sentence, rather than after
/// the whole chapter.
@MainActor
@Observable
public final class Narrator {
    public enum State: Equatable {
        case idle
        case preparing
        case speaking
        case paused
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var chapterId: String?
    public private(set) var bookTitle: String = ""
    public private(set) var chapterTitle: String = ""
    /// Chunks written so far, and how many there will be.
    public private(set) var renderedChunks = 0
    public private(set) var chunkCount = 0
    /// Seconds of audio that exist, which is as far as the scrubber can go.
    public private(set) var renderedSeconds: Double = 0

    private let engine: ChatterboxEngine
    private let library: Library
    private let renderer: ChapterRenderer

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    private var work: Task<Void, Never>?
    /// Where the next chunk goes on the player node's own timeline, which
    /// pausing does not advance — so these stay valid across a pause.
    private var nextFrame: AVAudioFramePosition = 0

    /// The stop flag is read from inside the engine's token loop, which runs
    /// off the main actor, so it cannot be main-actor state.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
    private var stopping = Flag()

    public init(engine: ChatterboxEngine, library: Library) {
        self.engine = engine
        self.library = library
        self.renderer = ChapterRenderer(engine: engine, library: library)
    }

    public var isBusy: Bool { state == .preparing || state == .speaking }

    /// Render and play a chapter from the beginning, reusing whatever is
    /// already on disk.
    public func play(book: Book, chapter: Chapter, voice: Voice, options: SamplingOptions) {
        stop()
        stopping = Flag()
        chapterId = chapter.id
        bookTitle = book.title
        chapterTitle = chapter.title
        renderedChunks = 0
        renderedSeconds = 0
        nextFrame = 0
        chunkCount = chapter.chunkCount
        state = .preparing

        // Audio rendered in a different voice is not this chapter's audio.
        let stale = chapter.renderedVoice != nil && chapter.renderedVoice != voice.id

        work = Task { [weak self] in
            guard let self else { return }
            do {
                if stale {
                    try await library.discardAudio(chapterId: chapter.id, bookId: book.id)
                }
                try startAudioSession()

                let stream = await renderer.render(
                    book: book,
                    chapter: chapter,
                    voice: voice,
                    options: options,
                    cancelled: { [flag = stopping] in flag.isSet }
                )
                for try await progress in stream {
                    if stopping.isSet { break }
                    schedule(progress)
                }
                if !stopping.isSet, state != .paused { state = .idle }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Play a chapter that is already fully rendered, with no engine involved.
    public func replay(book: Book, chapter: Chapter) {
        stop()
        stopping = Flag()
        chapterId = chapter.id
        bookTitle = book.title
        chapterTitle = chapter.title
        chunkCount = chapter.chunkCount
        renderedChunks = 0
        renderedSeconds = 0
        nextFrame = 0
        state = .preparing

        work = Task { [weak self] in
            guard let self else { return }
            do {
                try startAudioSession()
                let urls = renderer.rendered(
                    book: book.id, chapter: chapter.id, of: chapter.chunkCount
                )
                for (index, url) in urls.enumerated() {
                    if stopping.isSet { break }
                    schedule(
                        ChapterRenderer.Progress(
                            chunkIndex: index,
                            chunkCount: chapter.chunkCount,
                            url: url,
                            seconds: WavFile.duration(ofFileAt: url) ?? 0
                        )
                    )
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func pause() {
        guard state == .speaking else { return }
        player.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        player.play()
        state = .speaking
    }

    public func stop() {
        stopping.isSet = true
        work?.cancel()
        work = nil
        if started {
            player.stop()
            audio.stop()
            started = false
        }
        state = .idle
        chapterId = nil
    }

    // MARK: - Audio plumbing

    private func startAudioSession() throws {
        guard !started else { return }
        #if os(iOS)
        // `.spokenAudio` tells the system this is a book rather than music, so
        // it ducks correctly and keeps playing when the screen locks. The
        // background-audio capability is what allows synthesis to carry on off
        // screen at all — see the note in the README about iOS suspending an
        // app a few seconds after it stops making sound.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try session.setActive(true)
        #endif

        let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(WavFile.sampleRate), channels: 1
        )!
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: format)
        try audio.start()
        player.play()
        started = true
    }

    /// Queue a rendered chunk to play after everything already queued.
    ///
    /// Each chunk is scheduled at an explicit sample position rather than with
    /// `at: nil`. Two reasons, both learned the hard way:
    ///
    /// * `at: nil` means "after the previously scheduled segment", which is only
    ///   append-like while the node still has something queued. Once it drains —
    ///   and it drains constantly, because synthesis runs at about the speed of
    ///   speech — the meaning quietly changes to "now".
    /// * the `async` spelling of `scheduleFile` does not return until the file
    ///   has finished *playing*, so awaiting it inside the loop that consumes
    ///   rendered chunks stalls that loop for the length of every chunk.
    ///
    /// A running frame counter says exactly where each chunk belongs, which makes
    /// playback gapless and, more to the point, keeps it in order.
    private func schedule(_ progress: ChapterRenderer.Progress) {
        renderedChunks = progress.chunkIndex + 1
        chunkCount = progress.chunkCount
        renderedSeconds += progress.seconds

        guard let file = try? AVAudioFile(forReading: progress.url) else { return }
        let rate = Double(WavFile.sampleRate)

        let playhead = player.lastRenderTime
            .flatMap { player.playerTime(forNodeTime: $0) }?
            .sampleTime ?? 0
        nextFrame = Self.startFrame(cursor: nextFrame, playhead: playhead, rate: rate)

        player.scheduleFile(
            file,
            at: AVAudioTime(sampleTime: nextFrame, atRate: rate),
            completionHandler: nil
        )
        nextFrame += file.length
        if state == .preparing { state = .speaking }
    }

    /// Where a chunk should start: straight after the last one, unless the
    /// renderer fell so far behind that the playhead has gone past it.
    ///
    /// Never returns a position at or before `playhead`. Core Audio drops a
    /// segment whose start time has already passed, so getting this wrong loses
    /// a chunk outright rather than merely mistiming it.
    nonisolated static func startFrame(
        cursor: AVAudioFramePosition,
        playhead: AVAudioFramePosition,
        rate: Double
    ) -> AVAudioFramePosition {
        guard cursor <= playhead else { return cursor }
        // A tenth of a second of headroom, so the segment is not already stale
        // by the time the audio thread sees it.
        return playhead + AVAudioFramePosition(rate / 10)
    }
}
