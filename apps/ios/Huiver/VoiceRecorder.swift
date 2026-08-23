import AVFoundation
import Foundation
import Observation

/// The microphone, as the record sheet needs it.
///
/// One responsibility: turn whatever the input is doing into the mono 24 kHz
/// float samples `VoiceCloner` wants, while reporting a level so the reader can
/// see that it is hearing them. Everything about *which* seconds get used lives
/// in `ReferenceClip`, which is tested; this is the part that cannot be.
///
/// The Mac's copy of this is the same file without the audio session. On iOS
/// the session is the whole difference: an app that has been playing a book is
/// in `.playback`, which has no input at all, and an engine started against it
/// records silence rather than failing. So the category is moved for the
/// duration and put back afterwards — the narrator sets its own only once, on
/// its first chapter, and would never restore it.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        case denied
        case recording
        case finished
    }

    private(set) var state: State = .idle
    /// 0...1, smoothed, for a meter. Not decibels: a meter that reads in dB
    /// spends most of its travel on silence.
    private(set) var level: Double = 0
    private(set) var seconds: Double = 0
    private(set) var failure: String?

    /// What was recorded, once stopped.
    private(set) var samples: [Float] = []

    /// Long enough to fill Nano's fifteen-second window with room to spare,
    /// short enough that nobody reads a chapter into it.
    static let maximumSeconds: Double = 45

    private let engine = AVAudioEngine()
    private var collected: [Float] = []

    /// Ask for the microphone.
    func requestAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied:
            state = .denied
            return false
        default:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { state = .denied }
            return granted
        }
    }

    func start() {
        guard state != .recording else { return }
        failure = nil
        collected = []
        samples = []
        seconds = 0
        level = 0

        do {
            try beginSession()
        } catch {
            failure = error.localizedDescription
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            failure = "No microphone is available."
            endSession()
            return
        }
        // What the cloner wants, whatever the hardware offers: mono, 24 kHz,
        // float. The converter does the resampling so nothing downstream has to
        // care what the microphone's native rate is.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ReferenceClip.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            failure = "Could not read from the microphone."
            endSession()
            return
        }

        // AVAudioEngine calls a tap on its own realtime messenger queue, and a
        // closure written inside this `@MainActor` type inherits that
        // isolation. Swift 6 checks the executor at runtime before the closure's
        // first statement, so the mismatch is not a warning — it is a SIGTRAP
        // the instant recording starts. `@Sendable` is what opts the closure
        // out of inheriting; the box is for the two AVFoundation objects it
        // needs, which carry no Sendable annotation of their own. Exactly the
        // crossing `Converter.handleBackgroundTask` documents, from the other
        // direction.
        let conversion = TapConversion(converter: converter, target: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) {
            @Sendable [weak self] buffer, _ in
            guard let converted = VoiceRecorder.convert(
                buffer, with: conversion.converter, to: conversion.target
            ) else { return }
            Task { @MainActor in self?.append(converted) }
        }

        do {
            engine.prepare()
            try engine.start()
            state = .recording
        } catch {
            input.removeTap(onBus: 0)
            endSession()
            failure = error.localizedDescription
        }
    }

    func stop() {
        guard state == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        endSession()
        samples = collected
        state = .finished
        level = 0
    }

    /// Throw the take away and go back to the start.
    func reset() {
        if state == .recording { stop() }
        collected = []
        samples = []
        seconds = 0
        state = .idle
        failure = nil
    }

    /// What `ReferenceClip` makes of the take, for the given cloner's window —
    /// how much speech there is, and whether it is loud enough to be worth
    /// cloning.
    func choice(seconds clipSeconds: Int) -> ReferenceClip.Choice? {
        samples.isEmpty ? nil : ReferenceClip.prepare(samples, seconds: clipSeconds)
    }

    // MARK: - The session

    /// `.playAndRecord` rather than `.record`: the sheet plays the take back,
    /// and switching category between recording and previewing would tear the
    /// session down twice for no reason.
    private func beginSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
    }

    /// Back to what the narrator expects. It configures the session once, on
    /// the first chapter it plays, and never again — so leaving the session in
    /// `.playAndRecord` would leave every later chapter quieter and routed to
    /// the earpiece, with nothing to blame it on.
    private func endSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
    }

    private func append(_ chunk: [Float]) {
        guard state == .recording else { return }
        collected += chunk
        seconds = Double(collected.count) / Double(ReferenceClip.sampleRate)

        // Peak rather than RMS, eased downwards: a peak meter reacts the way
        // someone expects when they tap the microphone.
        let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        level = max(Double(peak), level * 0.82)

        if seconds >= Self.maximumSeconds { stop() }
    }

    /// The tap's buffer, resampled. Runs on the audio thread, so it touches
    /// nothing but its arguments.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 64
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}


/// The converter and the format it writes, across the hop onto AVFAudio's tap
/// queue. Neither type is `Sendable`; both are made here, handed to one tap and
/// touched nowhere else, which is the whole of the reasoning behind the
/// `@unchecked`.
private final class TapConversion: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat

    init(converter: AVAudioConverter, target: AVAudioFormat) {
        self.converter = converter
        self.target = target
    }
}
