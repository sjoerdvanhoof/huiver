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

    public private(set) var state: State = .idle {
        // Every transition is also a lock screen transition, and there are
        // enough of them — six methods and the ticker — that catching them here
        // beats remembering to publish at each one.
        didSet {
            if oldValue != state { PlaybackLog.note("state \(oldValue) → \(state) \(self.vitals)") }
            publish()
        }
    }
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
    /// Remembered across launches: a listener who reads at 1.5× reads at 1.5×,
    /// and resetting them to 1 every morning is the kind of thing that makes an
    /// audiobook app feel borrowed.
    public var rate: Float = 1 {
        didSet {
            speed.rate = max(0.5, min(3, rate))
            UserDefaults.standard.set(rate, forKey: "playbackRate")
            publish()
        }
    }

    /// Why synthesis stopped, when it stopped before the chapter was finished.
    ///
    /// Deliberately not part of `state`: a render that dies does not stop the
    /// audio already on disk from playing, and the two were conflated to begin
    /// with, which is what made the lock screen vanish mid-chapter.
    public private(set) var renderFailure: String?

    /// True while the models are being loaded again after a failure, which takes
    /// a few seconds and is worth saying out loud rather than looking stuck.
    public private(set) var isReloadingModels = false

    /// Roll on to the next chapter when one ends, rather than stopping.
    ///
    /// On by default, because a book is the unit people listen to. It is also
    /// what makes the sleep timer's "end of chapter" mean anything: without it
    /// playback stops at every chapter boundary regardless.
    public var autoAdvance = true

    /// Stop at the end of this chapter, whatever `autoAdvance` says. Set by the
    /// sleep timer and consumed once the chapter ends.
    public var stopAtChapterEnd = false

    /// Where to jump to once enough of the chapter exists to jump there.
    ///
    /// Resuming cannot be done at `play` time: nothing is rendered yet, and
    /// seeking into audio that does not exist is not a thing. So the target is
    /// held here and applied by `schedule` as soon as the rendered edge passes
    /// it — which for an already-rendered chapter is almost immediately.
    private var pendingResume: Double?

    /// The book and chapter being read, kept so the player can move between
    /// chapters without the view having to hand them back.
    public private(set) var book: Book?
    public private(set) var chapter: Chapter?

    private let engine: ChatterboxEngine
    private let library: Library
    private let renderer: ChapterRenderer
    private let progress: ProgressStore

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Time-stretch rather than varispeed: changing rate must not change
    /// pitch, or a book at 1.5x sounds like a cartoon.
    private let speed = AVAudioUnitTimePitch()
    private var started = false

    private var work: Task<Void, Never>?
    /// The sleep timer's volume ramp, held so it can be cancelled.
    private var fade: Task<Void, Never>?
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

    /// A chunk waiting its turn to be handed to the node.
    private struct Pending {
        let url: URL
        let chapterStart: Double
        /// Seconds to skip at the front, for a seek landing inside the chunk.
        let skip: Double
    }
    /// Rendered chunks not yet opened or scheduled. Every file handed to the
    /// node holds an open descriptor until it has played, and a long chapter
    /// has more chunks than the process has descriptors — handing a fully
    /// rendered 290-chunk chapter over at once ran out around 256, and the
    /// chunks past the limit were *silently* dropped from the timeline. So
    /// chunks queue here and `topUp` feeds the node a bounded window.
    private var pending: [Pending] = []

    /// How far past the playhead the node is kept fed: five minutes, which is
    /// ~30 open files at typical chunk lengths — far from the descriptor
    /// limit, and far more than a ticker hiccup could drain.
    private static let scheduleAhead = AVAudioFramePosition(WavFile.sampleRate * 300)

    private var ticker: Task<Void, Never>?
    /// How many chunks have been put on the player. A resumed render walks the
    /// chapter from the beginning again, re-reporting everything already on
    /// disk, and scheduling those a second time would play the opening minutes
    /// over the top of the middle.
    private var scheduledChunks = 0

    /// Which render pass is the current one, and how to stop the one before it.
    private var generation = 0
    private var renderPass: Flag?


    /// The lock screen, Control Centre and headphone buttons.
    private let nowPlaying = NowPlaying()

    /// Kept so the player can change chapter without the view re-supplying them.
    private var currentVoice: Voice?
    private var currentOptions = SamplingOptions()

    /// Called whenever a render pass ends, for any reason. The Mac app hangs
    /// its memory housekeeping on this — MLX holds a buffer pool worth giving
    /// back once nothing is synthesizing — and playback itself never needs it.
    public var renderPassDidEnd: (() -> Void)?

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

    public init(engine: ChatterboxEngine, library: Library, progress: ProgressStore) {
        self.engine = engine
        self.library = library
        self.progress = progress
        self.renderer = ChapterRenderer(engine: engine, library: library)

        // Observers do not fire during init, so the stored rate is applied to
        // the field directly; `startAudioSession` reads it into the node.
        if let stored = UserDefaults.standard.object(forKey: "playbackRate") as? Float,
           stored > 0 {
            rate = max(0.5, min(3, stored))
        }

        // The engine stops itself when the output device changes — headphones
        // unplugged, AirPods switching away — and without this the app keeps
        // claiming to speak into hardware that is gone. macOS only: on iOS
        // the audio session manages routes, and unplugging headphones is
        // supposed to pause, not carry on through the speaker.
        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.audioConfigurationChanged() }
        }
        #endif

        nowPlaying.activate(
            commands: NowPlaying.Commands(
                play: { [weak self] in self?.resume() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.toggle() },
                skip: { [weak self] in self?.skip(by: $0) },
                seek: { [weak self] in self?.seek(to: $0) },
                changeChapter: { [weak self] in self?.changeChapter(by: $0) },
                setRate: { [weak self] in self?.rate = $0 }
            )
        )
    }

    public var isBusy: Bool { state == .preparing || state == .speaking }

    /// Is the whole chapter on disk? Until it is, the duration shown is an
    /// estimate and the scrubber has an edge before the end.
    public var isFullyRendered: Bool { chunkCount > 0 && renderedChunks >= chunkCount }

    /// Which of the two ways into a chapter a tap on play should take.
    public enum Route: Sendable {
        /// Everything is on disk: play the files, engine untouched.
        case replay
        /// Something is missing: synthesise, picking up whatever prefix exists.
        case render
    }

    /// Play what is there, or make what is not.
    ///
    /// The rule is deliberately about the audio and not about the voice.
    /// Chapters rendered by the Mac arrive over sync labelled with one of *its*
    /// voices — multilingual voices whose tensors this app cannot even load, so
    /// they are filtered out of the phone's roster — and comparing that label
    /// against the selected voice sent every synced chapter down the render
    /// path, which discarded the audio that had just been transferred and read
    /// the chapter again in Nano. Whoever read a finished chapter, it is
    /// finished; re-reading one in the current voice is "Render again", an
    /// explicit choice.
    ///
    /// The files are counted rather than trusted from the index, so a chapter
    /// the index calls complete but whose audio has gone renders instead of
    /// sitting in `.preparing` with nothing to schedule.
    public nonisolated static func route(chapter: Chapter, chunksOnDisk: Int) -> Route {
        chapter.isComplete && chunksOnDisk >= chapter.chunkCount ? .replay : .render
    }

    /// Start listening to a chapter, whichever way round it has to happen.
    ///
    /// The one entry point every play button should use: the choice between
    /// `replay` and `play` was written out at six call sites across the two
    /// apps, which is how it came to be wrong at all six.
    public func listen(
        book: Book,
        chapter: Chapter,
        voice: Voice,
        options: SamplingOptions,
        from startPosition: Double = 0
    ) {
        let onDisk = renderer.rendered(
            book: book.id, chapter: chapter.id, of: chapter.chunkCount
        )
        switch Self.route(chapter: chapter, chunksOnDisk: onDisk.count) {
        case .replay:
            replay(book: book, chapter: chapter, from: startPosition)
        case .render:
            play(
                book: book, chapter: chapter, voice: voice, options: options,
                from: startPosition
            )
        }
    }

    /// Render and play a chapter, reusing whatever is already on disk.
    ///
    /// `from` is where to pick up: the stored listening position, or zero to
    /// start at the beginning. It is honoured as soon as that much audio
    /// exists, not immediately — see `pendingResume`.
    public func play(
        book: Book,
        chapter: Chapter,
        voice: Voice,
        options: SamplingOptions,
        from startPosition: Double = 0
    ) {
        stop()
        stopping = Flag()
        // After `stop`, which flushes the previous chapter's position and would
        // otherwise clear this one.
        pendingResume = startPosition > 0 ? startPosition : nil
        chapterId = chapter.id
        bookTitle = book.title
        chapterTitle = chapter.title
        renderedChunks = 0
        renderedSeconds = 0
        nextFrame = 0
        chunkCount = chapter.chunkCount

        self.book = book
        self.chapter = chapter
        currentVoice = voice
        currentOptions = options
        position = 0
        scheduledChunks = 0
        renderFailure = nil
        timeline.removeAll()
        // Nothing is rendered yet, so the only guide to length is the character
        // count. The player marks it as an estimate until the chapter is done.
        estimatedDuration = Double(chapter.characters) / Format.assumedCharactersPerSecond
        startTicker()
        // Set last: the transition is what publishes to the lock screen, so
        // everything it reads has to be in place first.
        state = .preparing

        // Audio rendered in a different voice is not this chapter's audio.
        let stale = chapter.renderedVoice != nil && chapter.renderedVoice != voice.id
        render(book: book, chapter: chapter, voice: voice, options: options, discardingStale: stale)
    }

    /// Run the renderer for a chapter, scheduling chunks as they land.
    ///
    /// Separate from `play` because it is also how synthesis is *restarted*,
    /// which happens more often than it sounds: Core ML cannot run while the
    /// screen is locked, so every listener who locks their phone loses the
    /// renderer within seconds and needs it back when they return.
    private func render(
        book: Book,
        chapter: Chapter,
        voice: Voice,
        options: SamplingOptions,
        discardingStale stale: Bool = false,
        reloadingModels reload: Bool = false
    ) {
        // Each pass gets a number and its own stop switch. A pass that has been
        // superseded — by a switch between processors, most often — must neither
        // touch the state nor go on quietly synthesising against the engine the
        // new pass is trying to use. Cancelling the task alone does neither: the
        // renderer's producer runs in a task of its own and only stops when asked
        // through `cancelled`.
        generation += 1
        let generation = generation
        let stopPass = Flag()
        renderPass?.isSet = true
        renderPass = stopPass

        work = Task { [weak self] in
            guard let self else { return }
            // However this pass ends — finished, superseded, stopped or
            // failed — say so, so the app can give back what synthesis was
            // holding. Whether anything is actually idle is the app's call:
            // a superseded pass ends while its replacement runs. The power
            // assertion covers the synthesis itself: playback keeps the
            // system awake on its own, rendering ahead of it does not.
            PowerAssertion.begin()
            defer {
                PowerAssertion.end()
                renderPassDidEnd?()
            }
            do {
                if stale {
                    try await library.discardAudio(chapterId: chapter.id, bookId: book.id)
                }
                try startAudioSession()
                if reload {
                    // A model that has failed once fails for good, so resuming
                    // means replacing it. Takes seconds, off the main actor,
                    // while whatever is already scheduled keeps playing.
                    PlaybackLog.note("loading the models again")
                    isReloadingModels = true
                    // Scoped to the reload, and covers the throwing path: the
                    // flag is only about the wait, which is over either way.
                    defer { isReloadingModels = false }
                    let began = ContinuousClock.now
                    try await engine.reload()
                    PlaybackLog.note(
                        "models ready after \(String(format: "%.1f", began.duration(to: .now).asSeconds))s"
                    )
                }
                guard generation == self.generation else { return }

                let stream = await renderer.render(
                    book: book,
                    chapter: chapter,
                    voice: voice,
                    options: options,
                    cancelled: { [flag = stopping, pass = stopPass] in flag.isSet || pass.isSet }
                )
                var previous = ContinuousClock.now
                for try await progress in stream {
                    if stopping.isSet || stopPass.isSet { break }
                    // Seconds spent against seconds of audio produced: whether
                    // synthesis is keeping up with playback, which is the number
                    // that explains most complaints about this app. Chunks read
                    // straight off disk return instantly and are not synthesis,
                    // so they are not worth a line.
                    let spent = previous.duration(to: .now).asSeconds
                    previous = .now
                    if spent > 0.2, progress.seconds > 0 {
                        PlaybackLog.note(
                            """
                            chunk \(progress.chunkIndex + 1)/\(progress.chunkCount) took \
                            \(String(format: "%.1f", spent))s for \
                            \(String(format: "%.1f", progress.seconds))s of audio \
                            (\(String(format: "%.2f", spent / progress.seconds))× realtime)
                            """
                        )
                    }
                    schedule(progress)
                }
                guard generation == self.generation else { return }
                // Rendering finishing is not playback finishing: a chapter that
                // was part-rendered already streams out of the renderer far
                // faster than it can be listened to. Going idle here would stop
                // the ticker's position updates and tell the lock screen the
                // book had stopped while it was still reading. The ticker takes
                // it from here.
                if !stopping.isSet, state != .paused, hasRunDry { state = .idle }
            } catch is CancellationError {
                // `stop` has already said what the state is, and a superseded pass
                // has no business saying anything; either way, not ours to set.
                if !stopping.isSet, generation == self.generation { state = .idle }
            } catch {
                guard generation == self.generation else { return }
                interrupted(by: error)
            }
        }
    }

    /// Synthesis stopped early. Playback does not have to.
    ///
    /// The usual cause is the screen locking: Core ML fails outright — "Unable to
    /// compute the prediction using ML Program" — a few seconds after the app
    /// leaves the screen, because it can no longer reach the hardware it was
    /// placed on. That is the normal path for anyone listening with the phone in
    /// a pocket, not an error worth tearing the session down for. The chapter
    /// carries on with what is already on disk, and `resumeRendering` picks
    /// synthesis back up when the app is next in front of someone.
    ///
    /// Marking this `.failed` was what made the lock screen go blank and the
    /// pause button stop working, because both keyed off the state.
    private func interrupted(by error: Error) {
        let message = error.localizedDescription
        PlaybackLog.note("render interrupted: \(message) \(vitals)")
        renderFailure = message
        // Nothing rendered at all means there is genuinely nothing to listen to,
        // and that is worth showing as a failure.
        if renderedChunks == 0 { state = .failed(message) }
    }

    /// Move synthesis between the best processor available and the CPU alone.
    ///
    /// The Neural Engine and the GPU are both unreachable to an app that is not on
    /// screen, which is why synthesis dies a few seconds after the phone is
    /// locked. The CPU has no such restriction, so pinning the models to it is
    /// what allows a chapter to carry on rendering in a pocket. It is much slower,
    /// which is the whole reason this follows the screen rather than being the
    /// setting all the time.
    ///
    /// Compute units are fixed when a model is loaded, so this is a reload of all
    /// four, and it restarts the render pass. Playback is untouched: what is
    /// already queued on the player keeps going throughout.
    /// Pick synthesis back up after it was interrupted, keeping the audio that is
    /// already queued playing. Safe to call whenever the app comes forward: it
    /// does nothing unless there is an interrupted chapter to continue.
    public func resumeRendering() {
        guard renderFailure != nil, !isFullyRendered,
              let book, let chapter, let voice = currentVoice
        else { return }
        PlaybackLog.note("resuming synthesis from chunk \(scheduledChunks) \(vitals)")
        renderFailure = nil
        // A chapter that failed before producing any audio has nothing playing,
        // so it goes back to preparing. One that is mid-playback keeps whatever
        // state it is in — including paused, which must not start itself.
        if case .failed = state { state = .preparing }
        render(
            book: book,
            chapter: chapter,
            voice: voice,
            options: currentOptions,
            reloadingModels: true
        )
    }

    /// Play a chapter that is already fully rendered, with no engine involved.
    public func replay(book: Book, chapter: Chapter, from startPosition: Double = 0) {
        stop()
        stopping = Flag()
        pendingResume = startPosition > 0 ? startPosition : nil
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
        scheduledChunks = 0
        renderFailure = nil
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
                // Nothing to schedule means nothing will ever leave
                // `.preparing`, and a spinner that never resolves is the
                // worst way to say "the audio is gone". `listen` routes
                // around this; a direct caller gets told.
                guard !urls.isEmpty else {
                    state = .failed("This chapter's audio is no longer on disk.")
                    return
                }
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

    /// Pause, on the authority of the audio engine rather than of `state`.
    ///
    /// The guard used to be `state == .speaking`, which meant any disagreement
    /// between what the app believed and what was coming out of the speaker left
    /// the pause button dead — audible audio that nothing could stop. If the node
    /// is playing, this stops it, whatever the state says.
    public func pause() {
        PlaybackLog.note("pause() \(vitals)")
        guard started, player.isPlaying else { return }
        player.pause()
        recordPosition(flushing: true)
        // The engine as well as the node. Pausing only the node leaves the engine
        // running and the audio hardware live, feeding the output silence, and
        // iOS reads its own idea of whether we are playing from that rather than
        // from anything published to `MPNowPlayingInfoCenter` — which left the
        // lock screen showing the state before last, sending play when we were
        // already playing. It also stops drawing power for silence.
        audio.pause()
        state = .paused
    }

    public func resume() {
        PlaybackLog.note("resume() \(vitals)")
        // Idle is the one state not to come back from: the chapter has ended or
        // been stopped, and there is nothing queued to resume into.
        guard started, !player.isPlaying, state != .idle else { return }
        // Restarting the engine keeps everything already scheduled, and the
        // node's timeline does not advance while it is paused, so the frame
        // positions the chunks were scheduled at are still the right ones.
        do {
            try audio.start()
        } catch {
            PlaybackLog.note("engine would not restart: \(error.localizedDescription)")
            return
        }
        player.play()
        state = .speaking
    }

    /// Ramp the volume down, then pause.
    ///
    /// The volume goes back to full once paused, so pressing play afterwards is
    /// not a surprise — the fade belongs to the sleep timer, not to the player.
    public func fadeOutAndPause(over seconds: Double) {
        guard started, player.isPlaying, fade == nil else { return }
        let steps = 20
        fade = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, !Task.isCancelled else { return }
                audio.mainMixerNode.outputVolume = Float(1) - Float(step) / Float(steps)
            }
            guard let self, !Task.isCancelled else { return }
            pause()
            audio.mainMixerNode.outputVolume = 1
            fade = nil
        }
    }

    /// Abandon a fade in progress and go back to full volume, for when someone
    /// cancels the sleep timer in the last few seconds.
    public func cancelFade() {
        guard fade != nil else { return }
        fade?.cancel()
        fade = nil
        if started { audio.mainMixerNode.outputVolume = 1 }
    }

    /// One button for both, which is what a headphone pinch and the lock
    /// screen's play/pause send.
    public func toggle() {
        PlaybackLog.note("toggle() \(vitals)")
        started && player.isPlaying ? pause() : resume()
    }

    public func stop() {
        // Before the ids are cleared: this is the last chance to write down
        // where the listener got to.
        recordPosition(flushing: true)
        stopping.isSet = true
        renderPass?.isSet = true
        work?.cancel()
        work = nil
        ticker?.cancel()
        ticker = nil
        timeline.removeAll()
        pending.removeAll()
        scheduledChunks = 0
        renderFailure = nil
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
        chunkCount = progress.chunkCount
        // Already on the player, from before synthesis was interrupted. The
        // count is still worth having, so this comes after it.
        guard progress.chunkIndex >= scheduledChunks else { return }
        scheduledChunks = progress.chunkIndex + 1
        renderedChunks = progress.chunkIndex + 1
        // Where this chunk begins in the chapter is everything rendered before
        // it, so the running total has to be read before it is added to.
        let chapterStart = renderedSeconds
        renderedSeconds += progress.seconds

        pending.append(Pending(url: progress.url, chapterStart: chapterStart, skip: 0))
        topUp()

        // Once everything is rendered the total is known rather than guessed.
        estimatedDuration = renderedChunks >= chunkCount && chunkCount > 0
            ? renderedSeconds
            : max(estimatedDuration, renderedSeconds)
        if state == .preparing { state = .speaking }
        applyPendingResume()
    }

    /// Feed the node from `pending` up to the scheduling window.
    ///
    /// Called wherever the queue or the playhead moves: when a chunk lands,
    /// on every tick, and after a seek rebuilds the queue.
    private func topUp() {
        guard started else { return }
        while !pending.isEmpty, nextFrame < playheadFrame() + Self.scheduleAhead {
            scheduleNow(pending.removeFirst())
        }
    }

    /// Open one chunk and put it on the node's timeline.
    private func scheduleNow(_ item: Pending) {
        guard let file = try? AVAudioFile(forReading: item.url) else { return }
        let rate = Double(WavFile.sampleRate)
        let offset = AVAudioFramePosition(item.skip * rate)
        let frames = AVAudioFrameCount(max(0, file.length - offset))
        guard frames > 0 else { return }
        nextFrame = Self.startFrame(cursor: nextFrame, playhead: playheadFrame(), rate: rate)

        if offset > 0 {
            player.scheduleSegment(
                file,
                startingFrame: offset,
                frameCount: frames,
                at: AVAudioTime(sampleTime: nextFrame, atRate: rate),
                completionHandler: nil
            )
        } else {
            player.scheduleFile(
                file,
                at: AVAudioTime(sampleTime: nextFrame, atRate: rate),
                completionHandler: nil
            )
        }
        timeline.append(
            Segment(
                nodeStart: nextFrame,
                frames: AVAudioFramePosition(frames),
                chapterStart: item.chapterStart + item.skip
            )
        )
        nextFrame += AVAudioFramePosition(frames)
    }

    /// Jump to the stored position, once there is enough audio to jump to.
    ///
    /// The two-second margin is `seekTarget`'s: a forward seek that would gain
    /// less than that is refused, so asking before the edge has cleared it
    /// would silently do nothing and leave the listener at the start of a
    /// chapter they were halfway through. Waiting is only a moment — the
    /// renderer reads existing chunks off disk as fast as it can open them.
    private func applyPendingResume() {
        guard let target = pendingResume, started else { return }
        guard renderedSeconds > target + 2 || isFullyRendered else { return }
        pendingResume = nil
        PlaybackLog.note("resuming at \(String(format: "%.1f", target))s \(vitals)")
        seek(to: target)
    }

    // MARK: - Listening position

    /// Write the current position to the progress store.
    ///
    /// Called every tick. The store keeps it in memory and writes to disk on a
    /// timer, so this is a dictionary update rather than a file write; `flushing`
    /// is for the moments where the process might not get another chance —
    /// pausing, stopping, going into the background.
    private func recordPosition(flushing: Bool = false) {
        guard let book, let chapter, chapterId != nil else { return }
        let seconds = position
        let chapterId = chapter.id
        let bookId = book.id
        Task { [progress] in
            await progress.setPosition(seconds, chapterId: chapterId, bookId: bookId)
            if flushing { await progress.flush() }
        }
    }

    /// Write down that the app is going away, wherever playback happens to be.
    ///
    /// The ticker stops when the app is suspended, so without this the last few
    /// seconds before a backgrounding are lost — and being killed while
    /// backgrounded is the most common way this app ends.
    public func checkpoint() {
        recordPosition(flushing: true)
    }

    /// `checkpoint`, but only returning once the position is on disk.
    ///
    /// For quitting: `checkpoint` hands the write to a task that a terminating
    /// process may never run, which is exactly the moment the write matters.
    public func checkpointNow() async {
        guard let book, let chapter, chapterId != nil else { return }
        await progress.setPosition(position, chapterId: chapter.id, bookId: book.id)
        await progress.flush()
    }

    /// The engine stopped because the output device changed. Restart it and
    /// rebuild the queue from disk at the position the listener could hear —
    /// the node's own timeline does not reliably survive the change.
    private func audioConfigurationChanged() {
        guard started, chapterId != nil else { return }
        PlaybackLog.note("audio configuration changed \(vitals)")
        do {
            try audio.start()
        } catch {
            // No output to speak into. Saying paused is the honest state, and
            // leaves the listener a working play button for when one is back.
            PlaybackLog.note(
                "engine would not restart after the change: \(error.localizedDescription)"
            )
            recordPosition(flushing: true)
            state = .paused
            return
        }
        player.play()
        if state == .paused { player.pause() }
        seek(to: position)
    }

    /// The chapter has played to the end.
    ///
    /// Marking it finished comes first and unconditionally: it is true whether
    /// or not the next chapter starts, and the cleanup sweep and the sync
    /// protocol both key off it.
    private func finishChapter() {
        if let book, let chapter {
            let chapterId = chapter.id
            let bookId = book.id
            let end = position
            Task { [progress] in
                await progress.setPosition(end, chapterId: chapterId, bookId: bookId)
                await progress.setFinished(true, chapterId: chapterId, bookId: bookId)
                await progress.flush()
            }
        }

        // `stopAtChapterEnd` is the sleep timer's, and is spent once used.
        let stopHere = stopAtChapterEnd
        stopAtChapterEnd = false

        if autoAdvance, !stopHere, hasNextChapter {
            PlaybackLog.note("chapter ended, advancing \(vitals)")
            // Starts its own ticker; this one returns immediately after.
            changeChapter(by: 1)
            return
        }
        state = .idle
        // Nothing left to poll for. `startTicker` makes a new one for the next
        // chapter.
        ticker?.cancel()
    }

    // MARK: - Position, seeking and chapter changes

    /// Poll the node for where it has got to.
    ///
    /// There is no callback for this — an `AVAudioPlayerNode` reports its
    /// position and nothing more — so it is read four times a second, which is
    /// often enough for a scrubber and cheap enough to ignore.
    private func startTicker() {
        ticker?.cancel()
        var ticks = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                // A heartbeat every five seconds, which is what turns the log
                // into a timeline: it shows the state and the engine drifting
                // apart even when nobody touched anything.
                ticks += 1
                if ticks % 20 == 0 { PlaybackLog.note("tick \(vitals)") }
                // Keep the node fed as the playhead advances into the
                // scheduling window — see `topUp`.
                topUp()
                if state == .speaking {
                    position = observedPosition()
                    recordPosition()
                    // Nothing left queued. There is no completion callback that
                    // says so — chunks are scheduled with none, because a handler
                    // per chunk would fire on the audio thread mid-chapter — so
                    // it is noticed here, where the playhead is read anyway.
                    if hasRunDry {
                        if isFullyRendered {
                            position = renderedSeconds
                            finishChapter()
                            return
                        } else {
                            // Out of audio but not out of chapter: it is waiting
                            // for synthesis, which is what preparing means, and
                            // saying so beats a player that claims to be playing
                            // in silence. `schedule` puts it back to speaking as
                            // soon as a chunk lands.
                            PlaybackLog.note("ran dry waiting for synthesis \(vitals)")
                            state = .preparing
                        }
                    }
                }
                // Outside the branch: the duration and the rendered edge move
                // while preparing too, and a paused player still has a lock
                // screen.
                publish()
            }
        }
    }

    /// Is sound actually coming out of the phone? What the lock screen shows,
    /// rather than what the state machine believes, so that a session whose
    /// synthesis died still reads as playing while its audio plays on.
    private var isSounding: Bool {
        guard started, player.isPlaying else { return false }
        // Preparing means the node is running but has nothing yet to play.
        return state != .preparing
    }

    /// Everything worth knowing in one line, for the log.
    ///
    /// `nodePlaying` is the one that settles arguments: it is what the audio
    /// engine thinks, as opposed to what `state` claims, and a disagreement
    /// between the two is the shape of every bug in this file so far.
    private var vitals: String {
        // Nothing about the node may be read before it is attached to an engine:
        // those getters raise. Hence the dashes rather than a plausible zero —
        // "not started yet" and "at the beginning" are different answers.
        let node = started
            ? "nodePlaying=\(player.isPlaying) playhead=\(playheadFrame()) drained=\(hasDrainedAudio)"
            : "nodePlaying=- playhead=- drained=-"
        return """
        state=\(state) \(node) pos=\(String(format: "%.1f", position)) next=\(nextFrame) \
        rendered=\(renderedChunks)/\(chunkCount) started=\(started)
        """
    }

    /// Where the node has got to on its own timeline, in frames. Zero before it
    /// has rendered anything, which is where it starts anyway.
    ///
    /// The `started` guard is not caution, it is required: `lastRenderTime`
    /// *raises* on a node that has not been attached to an engine — it does not
    /// return nil — so reading it before the first play kills the app.
    private func playheadFrame() -> AVAudioFramePosition {
        guard started else { return 0 }
        return player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
    }

    /// Has the player played out everything scheduled?
    private var hasDrainedAudio: Bool { started && playheadFrame() >= nextFrame }

    /// Drained, and stayed that way for a second.
    ///
    /// The margin is the point. While synthesis is only just keeping up — which is
    /// the normal condition, Nano being slower than speech — the playhead crosses
    /// the end of the last scheduled chunk constantly, for a fraction of a second
    /// at a time, and acting on that would have the player flapping between states
    /// several times a chapter.
    ///
    /// Audio still waiting in `pending` counts as not dry: it exists, the node
    /// just has not been handed it yet.
    private var hasRunDry: Bool {
        guard started, pending.isEmpty else { return false }
        return playheadFrame() > nextFrame + AVAudioFramePosition(WavFile.sampleRate)
    }

    /// Turn the node's frame counter into a position in the chapter.
    private func observedPosition() -> Double {
        // `started` for the same reason as in `playheadFrame`: today this is only
        // reached while speaking, but the getter raises rather than returning nil
        // and that should not depend on the caller.
        guard started, let playhead = player.lastRenderTime
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
    ///
    /// Forwards it is clamped to the rendered edge, which is a real position and a
    /// practical cliff: `+30 s` with three seconds rendered used to schedule a
    /// fraction of a sentence, play it, and leave the player silent with the
    /// scrubber pinned. So a forward seek that would gain less than two seconds is
    /// refused outright — staying put says "that is as far as this goes" better
    /// than a stutter into a dead end.
    public func seek(to seconds: Double) {
        guard let book, let chapter, started else { return }
        guard let target = Self.seekTarget(
            to: seconds, from: position, rendered: renderedSeconds
        ) else {
            PlaybackLog.note("seek to \(String(format: "%.1f", seconds)) refused: at the rendered edge")
            return
        }

        player.stop()
        timeline.removeAll()
        pending.removeAll()
        nextFrame = 0

        var elapsed = 0.0
        var found = false
        var diskChunks = 0
        for url in renderer.rendered(book: book.id, chapter: chapter.id, of: chapter.chunkCount) {
            let length = WavFile.duration(ofFileAt: url) ?? 0
            if !found, elapsed + length > target {
                found = true
                pending.append(Pending(url: url, chapterStart: elapsed, skip: target - elapsed))
            } else if found {
                pending.append(Pending(url: url, chapterStart: elapsed, skip: 0))
            }
            elapsed += length
            diskChunks += 1
        }
        // Everything on disk is on the timeline now, including a chunk the
        // renderer has written but not yet reported. Without this, that
        // chunk's report passed the guard in `schedule` and it played twice.
        scheduledChunks = max(scheduledChunks, diskChunks)
        renderedChunks = max(renderedChunks, diskChunks)
        renderedSeconds = max(renderedSeconds, elapsed)

        player.play()
        topUp()
        position = target
        if state == .paused { player.pause() } else { state = .speaking }
        publish()
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

    /// Jump straight to a chapter of the current book, in the same voice —
    /// what a chapter list inside the player means.
    public func jumpToChapter(at index: Int) {
        guard let book, let voice = currentVoice,
              book.chapters.indices.contains(index),
              book.chapters[index].id != chapter?.id
        else { return }
        play(book: book, chapter: book.chapters[index], voice: voice, options: currentOptions)
    }

    public var hasNextChapter: Bool { offsetChapterExists(1) }
    public var hasPreviousChapter: Bool { offsetChapterExists(-1) }

    private func offsetChapterExists(_ delta: Int) -> Bool {
        guard let book, let chapter,
              let index = book.chapters.firstIndex(where: { $0.id == chapter.id })
        else { return false }
        return book.chapters.indices.contains(index + delta)
    }

    // MARK: - Off screen

    /// Tell the lock screen where things stand.
    ///
    /// Cheap to call as often as this is called: `NowPlaying` drops a push that
    /// would not change what is drawn.
    private func publish() {
        guard let book, let chapter, chapterId != nil else {
            nowPlaying.clear()
            return
        }
        switch state {
        // Idle covers both stopped and the end of a chapter, and neither is
        // something to leave controls up for — nothing would answer them.
        case .idle:
            nowPlaying.clear()
            return
        case .failed:
            // Unless there is still sound coming out, in which case taking the
            // controls away is how you get a book nobody can pause.
            guard started, player.isPlaying else {
                nowPlaying.clear()
                return
            }
        case .preparing, .speaking, .paused:
            break
        }

        let index = book.chapters.firstIndex { $0.id == chapter.id }
        nowPlaying.update(
            NowPlaying.Snapshot(
                chapterTitle: chapterTitle,
                bookTitle: bookTitle,
                author: book.author,
                chapterNumber: index.map { $0 + 1 },
                chapterCount: book.chapters.count,
                // The estimate, tilde and all: a duration that grew every few
                // seconds would make the lock screen's bar jump about, and it
                // settles on the real length once the chapter is rendered.
                duration: estimatedDuration,
                position: position,
                rate: rate,
                isPlaying: isSounding,
                hasNextChapter: hasNextChapter,
                hasPreviousChapter: hasPreviousChapter,
                coverURL: library.coverURL(book)
            )
        )
    }

    /// Where a seek should land, or `nil` for "stay where you are".
    ///
    /// Backwards is unrestricted — all of it exists on disk. Forwards stops at the
    /// rendered edge, and refuses altogether when that would gain less than two
    /// seconds: `+30 s` with three seconds rendered is a request that cannot be
    /// honoured, and scheduling the fraction of a sentence that *is* there only
    /// produces a stutter and a silent player.
    nonisolated static func seekTarget(
        to seconds: Double, from position: Double, rendered: Double
    ) -> Double? {
        // The quarter second is the padding the renderer puts between chunks:
        // landing inside it would be a seek to silence.
        let edge = max(0, rendered - 0.25)
        // Nothing rendered, so not even the beginning exists yet. Worth its own
        // answer, because seeking stops the player and rebuilds its queue: doing
        // that with nothing to put back is how you get a player that claims to be
        // playing in silence.
        guard edge > 0 else { return nil }
        let target = max(0, min(seconds, edge))
        if target > position, target - position < 2 { return nil }
        return target
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

private extension Duration {
    /// Seconds as a `Double`, which `Duration` itself does not offer — it exposes
    /// whole seconds and attoseconds separately, and dropping the fraction would
    /// make anything under a second read as zero.
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
