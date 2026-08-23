import AVFoundation
import Foundation
import Observation

/// The microphone, as the record sheet needs it.
///
/// One responsibility: turn whatever the input device is doing into the mono
/// 24 kHz float samples `VoiceCloner` wants, while reporting a level so the
/// listener can see that it is hearing them. Everything about *which* ten
/// seconds get used lives in `ReferenceClip`, which is tested; this is the part
/// that cannot be.
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
    private(set) var sourceName: String?

    /// What was recorded, once stopped.
    private(set) var samples: [Float] = []

    /// Long enough that ten seconds can be chosen from the middle, short enough
    /// that nobody reads a chapter into it.
    static let maximumSeconds: Double = 30

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var collected: [Float] = []

    /// Ask for the microphone. macOS answers on a background queue.
    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted:
            state = .denied
            return false
        default:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
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
        sourceName = nil

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            failure = "No input device is available."
            return
        }
        // What the cloner wants, whatever the device offers: mono, 24 kHz,
        // float. The converter does the resampling so nothing downstream has to
        // care what the microphone's native rate is.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ReferenceClip.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            failure = "Could not read from this input device."
            return
        }
        self.converter = converter

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
            failure = error.localizedDescription
        }
    }

    /// Import an audio file through AVFoundation, using the same mono 24 kHz
    /// conversion as the microphone so trimming and cloning have one format.
    func importAudio(from url: URL) {
        reset()
        failure = nil

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(ReferenceClip.sampleRate),
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: format, to: target) else {
                throw ImportError.unreadable
            }

            var imported: [Float] = []
            let chunkFrames: AVAudioFrameCount = 32_768
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition))
                ) else { throw ImportError.unreadable }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                if let converted = Self.convert(buffer, with: converter, to: target) {
                    imported += converted
                }
            }
            guard !imported.isEmpty else { throw ImportError.empty }
            samples = imported
            seconds = Double(imported.count) / Double(ReferenceClip.sampleRate)
            sourceName = url.deletingPathExtension().lastPathComponent
            state = .finished
        } catch {
            failure = error.localizedDescription
            state = .idle
        }
    }

    func stop() {
        guard state == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        sourceName = nil
    }

    private enum ImportError: LocalizedError {
        case unreadable, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "Narcisse could not decode that audio file."
            case .empty: "That audio file is empty."
            }
        }
    }

    /// What `ReferenceClip` makes of the take — how much speech there is, and
    /// whether it is loud enough to be worth cloning.
    var choice: ReferenceClip.Choice? {
        samples.isEmpty ? nil : ReferenceClip.prepare(samples)
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
