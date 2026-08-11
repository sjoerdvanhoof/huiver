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
    /// Where playback has got to, in chapter seconds.
    public private(set) var position: Double = 0
    /// What the whole chapter will come to. An estimate until it is all
    /// rendered, which is why the player marks it with a tilde.
    public private(set) var estimatedDuration: Double = 0
    /// Playback speed. Pitch-corrected, so a book at 1.5x still sounds human.
    public var rate: Float = 1 {
        didSet { speed.rate = max(0.5, min(3, rate)) }
    }

    /// The book and chapter being read, kept so the player can move between
    /// chapters without the view having to hand them back.
    public private(set) var book: Book?
    public private(set) var chapter: Chapter?

    private let engine: ChatterboxEngine
    private let library: Library
    private let renderer: ChapterRenderer

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Time-stretch rather than varispeed: changing rate must not change
    /// pitch, or a book at 1.5x sounds like a cartoon.
    private let speed = AVAudioUnitTimePitch()
    private var started = false

    private var work: Task<Void, Never>?
    /// Where the next chunk goes on the player node's own timeline, which
    /// pausing does not advance — so these stay valid across a pause.
    private var nextFrame: AVAudioFramePosition = 0

    /// One scheduled chunk: where it sits on the node's timeline, and where it
    /// sits in the chapter. The two differ because a chunk that arrives late is
    /// pushed forward on the node's timeline, leaving a gap that is silence
    /// rather than missing audio.
    private struct Segment {
        let nodeStart: AVAudioFramePosition
        let frames: AVAudioFramePosition
        let chapterStart: Double
        var seconds: Double { Double(frames) / Double(WavFile.sampleRate) }
    }
    private var timeline: [Segment] = []
    private var ticker: Task<Void, Never>?

    /// Kept so the player can change chapter without the view re-supplying them.
    private var currentVoice: Voice?
    private var currentOptions = SamplingOptions()

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

    /// Is the whole chapter on disk? Until it is, the duration shown is an
    /// estimate and the scrubber has an edge before the end.
    public var isFullyRendered: Bool { chunkCount > 0 && renderedChunks >= chunkCount }

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

        self.book = book
        self.chapter = chapter
        currentVoice = voice
        currentOptions = options
        position = 0
        timeline.removeAll()
        // Nothing is rendered yet, so the only guide to length is the character
        // count. The player marks it as an estimate until the chapter is done.
        estimatedDuration = Double(chapter.characters) / Format.assumedCharactersPerSecond
        startTicker()

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
        self.book = book
        self.chapter = chapter
        position = 0
        timeline.removeAll()
        estimatedDuration = Double(chapter.characters) / Format.assumedCharactersPerSecond
        startTicker()
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
        ticker?.cancel()
        ticker = nil
        timeline.removeAll()
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
        audio.attach(speed)
        audio.connect(player, to: speed, format: format)
        audio.connect(speed, to: audio.mainMixerNode, format: format)
        speed.rate = max(0.5, min(3, rate))
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
        // Where this chunk begins in the chapter is everything rendered before
        // it, so the running total has to be read before it is added to.
        let chapterStart = renderedSeconds
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
        timeline.append(
            Segment(nodeStart: nextFrame, frames: file.length, chapterStart: chapterStart)
        )
        nextFrame += file.length

        // Once everything is rendered the total is known rather than guessed.
        estimatedDuration = renderedChunks >= chunkCount && chunkCount > 0
            ? renderedSeconds
            : max(estimatedDuration, renderedSeconds)
        if state == .preparing { state = .speaking }
    }

    // MARK: - Position, seeking and chapter changes

    /// Poll the node for where it has got to.
    ///
    /// There is no callback for this — an `AVAudioPlayerNode` reports its
    /// position and nothing more — so it is read four times a second, which is
    /// often enough for a scrubber and cheap enough to ignore.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if state == .speaking { position = observedPosition() }
            }
        }
    }

    /// Turn the node's frame counter into a position in the chapter.
    private func observedPosition() -> Double {
        guard let playhead = player.lastRenderTime
            .flatMap({ player.playerTime(forNodeTime: $0) })?.sampleTime,
            let segment = timeline.last(where: { $0.nodeStart <= playhead })
        else { return position }

        // Clamped to the segment: between segments the playhead is in a gap the
        // renderer left, and reporting past the end of the audio that exists
        // would make the scrubber run ahead of what can be heard.
        let into = min(
            Double(playhead - segment.nodeStart) / Double(WavFile.sampleRate),
            segment.seconds
        )
        return segment.chapterStart + into
    }

    /// Jump to a point in what has been rendered.
    ///
    /// Seeking backwards is exact, because each chunk is its own file and
    /// `scheduleSegment` can start part-way into one. Seeking past what exists
    /// is not possible: unrendered audio has nowhere to seek to.
    public func seek(to seconds: Double) {
        guard let book, let chapter, started else { return }
        let target = max(0, min(seconds, max(0, renderedSeconds - 0.25)))

        player.stop()
        timeline.removeAll()
        nextFrame = 0

        var elapsed = 0.0
        var found = false
        var queue: [(url: URL, chapterStart: Double, skip: Double)] = []
        for url in renderer.rendered(book: book.id, chapter: chapter.id, of: chapter.chunkCount) {
            let length = WavFile.duration(ofFileAt: url) ?? 0
            if !found, elapsed + length > target {
                found = true
                queue.append((url, elapsed, target - elapsed))
            } else if found {
                queue.append((url, elapsed, 0))
            }
            elapsed += length
        }

        player.play()
        for item in queue { scheduleSegment(item.url, chapterStart: item.chapterStart, skipping: item.skip) }
        position = target
        if state == .paused { player.pause() } else { state = .speaking }
    }

    public func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Move to the chapter before or after this one, in the same voice.
    public func changeChapter(by delta: Int) {
        guard let book, let chapter, let voice = currentVoice,
              let index = book.chapters.firstIndex(where: { $0.id == chapter.id })
        else { return }
        let target = index + delta
        guard book.chapters.indices.contains(target) else { return }
        play(book: book, chapter: book.chapters[target], voice: voice, options: currentOptions)
    }

    public var hasNextChapter: Bool { offsetChapterExists(1) }
    public var hasPreviousChapter: Bool { offsetChapterExists(-1) }

    private func offsetChapterExists(_ delta: Int) -> Bool {
        guard let book, let chapter,
              let index = book.chapters.firstIndex(where: { $0.id == chapter.id })
        else { return false }
        return book.chapters.indices.contains(index + delta)
    }

    /// Schedule part of a chunk, used when seeking lands inside one.
    private func scheduleSegment(_ url: URL, chapterStart: Double, skipping: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let rate = Double(WavFile.sampleRate)
        let offset = AVAudioFramePosition(skipping * rate)
        let frames = AVAudioFrameCount(max(0, file.length - offset))
        guard frames > 0 else { return }

        let playhead = player.lastRenderTime
            .flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
        nextFrame = Self.startFrame(cursor: nextFrame, playhead: playhead, rate: rate)

        player.scheduleSegment(
            file,
            startingFrame: offset,
            frameCount: frames,
            at: AVAudioTime(sampleTime: nextFrame, atRate: rate),
            completionHandler: nil
        )
        timeline.append(
            Segment(
                nodeStart: nextFrame,
                frames: AVAudioFramePosition(frames),
                chapterStart: chapterStart + skipping
            )
        )
        nextFrame += AVAudioFramePosition(frames)
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
