import Foundation
import Observation

#if canImport(UIKit)
import BackgroundTasks
import UIKit
#endif

/// Renders chapters to disk without playing them.
///
/// Separate from `Narrator` on purpose: pressing convert should convert, not
/// start reading aloud. They share the engine, which is an actor, so a
/// conversion and a live chapter cannot run at the same instant — they take
/// turns per chunk, which makes both slower but neither wrong.
///
/// ## Leaving the app
///
/// Conversion runs while the app is on screen. iOS suspends an app a few seconds
/// after it leaves, and for on-device *computation* there is no way around that:
/// the background modes that exist are for specific jobs -- playing audio,
/// transferring files, receiving location -- not for arbitrary work. A podcast
/// app downloading in the background is doing a `URLSession` background transfer,
/// which a system daemon performs on its behalf; there is no equivalent that
/// will run a neural network for you.
///
/// So stopping is made cheap and resuming automatic instead:
///
/// * a **background task assertion** on the way out buys long enough to finish
///   the chunk in flight, so the checkpoint on disk is clean rather than a
///   truncated file;
/// * the **queue is persisted**, and the chapter being worked on stays at its
///   head until it is genuinely complete, so re-opening the app carries on
///   rather than needing the button pressed again -- even after a force quit;
/// * a **`BGProcessingTask`** is registered, which iOS may grant later while
///   charging and idle. A bonus rather than a plan: it is opportunistic and may
///   not come at all.
///
/// The one case that does keep going off screen is listening, because then the
/// app is genuinely playing audio -- see `Narrator`.
@MainActor
@Observable
public final class Converter {
    public struct Job: Sendable, Identifiable, Equatable {
        public let bookId: String
        public let chapterId: String
        public var id: String { chapterId }
    }

    /// The chapter being rendered, and how far it has got.
    public private(set) var active: Job?
    public private(set) var renderedChunks = 0
    public private(set) var chunkCount = 0
    /// Chapters waiting their turn.
    public private(set) var queue: [Job] = []
    public private(set) var failure: String?

    /// Called when a chapter's rendered state changes, so the views can
    /// re-read the library. The renderer writes progress to disk itself;
    /// this is only the nudge to look again.
    public var didChange: (@MainActor () -> Void)?

    /// Identifier registered in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    public static let backgroundTaskIdentifier = "online.mo4.huiver.nano.convert"

    private let engine: ChatterboxEngine
    /// Set when a render threw, because the likeliest reason is a model that has
    /// stopped working rather than a chapter that cannot be read.
    private var modelsNeedReloading = false
    private let library: Library
    private let renderer: ChapterRenderer
    private var voice: Voice?
    private var options = SamplingOptions()

    private var work: Task<Void, Never>?
    private let stopping = Flag()

    #if canImport(UIKit)
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    #endif


    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The live converter, for the background handler to find.
    ///
    /// Registration has to happen before the app finishes launching, which is
    /// before there is a converter to register, so the handler looks one up
    /// rather than capturing it. Weak, so a torn-down converter is not kept
    /// alive by a system callback.
    private static weak var current: Converter?

    public init(engine: ChatterboxEngine, library: Library) {
        self.engine = engine
        self.library = library
        self.renderer = ChapterRenderer(engine: engine, library: library)
        Converter.current = self
    }

    /// Wait for the queue to drain, so a background slot is held for as long as
    /// there is work rather than being handed back immediately.
    public func waitUntilIdle() async {
        await work?.value
    }

    /// Restart the queue in a granted background slot.
    func resumeInBackground() {
        stopping.isSet = false
        start()
    }

    public var isBusy: Bool { active != nil }

    public func isQueued(_ chapterId: String) -> Bool {
        active?.chapterId == chapterId || queue.contains { $0.chapterId == chapterId }
    }

    public func progress(for chapterId: String) -> Double? {
        guard active?.chapterId == chapterId, chunkCount > 0 else { return nil }
        return Double(renderedChunks) / Double(chunkCount)
    }

    /// Add a chapter to the queue, and start working if nothing is.
    public func convert(book: Book, chapter: Chapter, voice: Voice, options: SamplingOptions) {
        guard !isQueued(chapter.id), !chapter.isComplete else { return }
        self.voice = voice
        self.options = options
        queue.append(Job(bookId: book.id, chapterId: chapter.id))
        persist()
        scheduleBackgroundProcessing()
        start()
    }

    /// Take a chapter out of the queue, or stop it if it is the one running.
    /// The chunks already written stay: stopping is a pause, not a discard.
    public func cancel(_ chapterId: String) {
        queue.removeAll { $0.chapterId == chapterId }
        persist()
        if active?.chapterId == chapterId {
            stopping.isSet = true
            work?.cancel()
        }
    }

    public func cancelAll() {
        queue.removeAll()
        persist()
        stopping.isSet = true
        work?.cancel()
    }

    private func start() {
        guard work == nil, !queue.isEmpty, let voice else { return }
        stopping.isSet = false

        work = Task { [weak self] in
            guard let self else { return }
            if modelsNeedReloading {
                // A Core ML model that has failed once fails for good, and the
                // most common way to fail is for the app to lose the GPU by
                // leaving the screen mid-conversion. Without this, every attempt
                // for the rest of the session fails exactly as the first did.
                // See `ChatterboxEngine.reload`.
                modelsNeedReloading = false
                try? await engine.reload()
            }
            while let job = queue.first, !stopping.isSet {
                guard let book = await library.book(job.bookId),
                      let chapter = book.chapters.first(where: { $0.id == job.chapterId })
                else {
                    queue.removeFirst()
                    continue
                }

                active = job
                renderedChunks = 0
                chunkCount = chapter.chunkCount

                do {
                    let stream = await renderer.render(
                        book: book,
                        chapter: chapter,
                        voice: voice,
                        options: options,
                        cancelled: { [flag = stopping] in flag.isSet }
                    )
                    for try await progress in stream {
                        renderedChunks = progress.chunkIndex + 1
                        chunkCount = progress.chunkCount
                        didChange?()
                    }
                } catch is CancellationError {
                    // Stopping is ordinary, and leaves a usable prefix.
                } catch {
                    failure = error.localizedDescription
                    modelsNeedReloading = true
                }
                // The job stays at the head of the queue until the chapter is
                // actually finished. Removing it when work *started* — which is
                // what the old `removeFirst()` did — loses it the moment iOS
                // suspends the app mid-chapter, so nothing resumes and the
                // button has to be pressed again.
                let done = await library.book(job.bookId)?
                    .chapters.first { $0.id == job.chapterId }?.isComplete ?? false
                if done || failure != nil { queue.removeFirst() }

                active = nil
                persist()
                didChange?()
                if !done { break }
            }
            work = nil
            endAssertion()
        }
    }

    // MARK: - Surviving a relaunch

    private static let queueKey = "convertQueue"

    /// The queue outlives the process, so a conversion interrupted by iOS
    /// suspending or killing the app carries on next launch rather than being
    /// forgotten. The rendered chunks on disk are the real progress; this only
    /// remembers the intent.
    private func persist() {
        UserDefaults.standard.set(queue.map { [$0.bookId, $0.chapterId] }, forKey: Self.queueKey)
    }

    /// Pick up where the last run left off. Called once the engine is ready.
    public func restore(voice: Voice, options: SamplingOptions) {
        guard queue.isEmpty else { return }
        let saved = UserDefaults.standard.array(forKey: Self.queueKey) as? [[String]] ?? []
        let restored = saved.compactMap { pair -> Job? in
            pair.count == 2 ? Job(bookId: pair[0], chapterId: pair[1]) : nil
        }
        guard !restored.isEmpty else { return }
        self.voice = voice
        self.options = options
        queue = restored
        start()
    }

    // MARK: - Background

    /// Called when the app leaves the screen: hold a short assertion so the
    /// chunk in flight finishes and checkpoints instead of being cut off.
    public func applicationDidEnterBackground() {
        #if canImport(UIKit)
        scheduleBackgroundProcessing()
        guard isBusy, assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "huiver-convert") {
            // Time is up. Stop between chunks rather than being killed
            // mid-write; the queue is picked up again by the processing task.
            Task { @MainActor [weak self] in
                self?.stopping.isSet = true
                self?.endAssertion()
            }
        }
        #endif
    }

    public func applicationWillEnterForeground() {
        endAssertion()
        if !queue.isEmpty { start() }
    }

    private func endAssertion() {
        #if canImport(UIKit)
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
        #endif
    }

    /// Ask the system for a slot to carry on converting.
    ///
    /// `BGProcessingTask` is granted when iOS decides — usually charging and
    /// idle — so this is what converts a book overnight rather than something
    /// that continues the moment the screen locks.
    public func scheduleBackgroundProcessing() {
        #if canImport(UIKit)
        guard !queue.isEmpty || isBusy else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // Synthesis is heavy enough to want power, but not so heavy that a
        // phone on battery cannot do a chapter, so this is left off.
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(UIKit)
    /// Register the handler. Must be called before the app finishes launching,
    /// and the identifier must appear in `BGTaskSchedulerPermittedIdentifiers`
    /// or this throws.
    public static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            // The system can reclaim the slot at any point. Stopping between
            // chunks is what keeps the prefix on disk valid, so expiry asks for
            // a stop rather than letting the process be killed mid-write.
            task.expirationHandler = {
                Task { @MainActor in Converter.current?.cancelAll() }
            }
            Task { @MainActor in
                guard let converter = Converter.current else {
                    task.setTaskCompleted(success: false)
                    return
                }
                converter.resumeInBackground()
                await converter.waitUntilIdle()
                // Ask for another slot if there is still a queue: one grant is
                // not enough for a book, and iOS will not volunteer a second.
                converter.scheduleBackgroundProcessing()
                task.setTaskCompleted(success: true)
            }
        }
    }
    #endif
}
