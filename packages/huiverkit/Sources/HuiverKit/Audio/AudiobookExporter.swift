import AVFoundation
import CoreMedia
import Foundation

/// Turns a shelf of rendered chunk WAVs into files the rest of the world can
/// play: one chapter-marked `.m4b` per book, or one tagged `.m4a` per chapter.
///
/// The library's own storage stays WAV chunks — the player, the chunk map and
/// sync all assume it. This is the way *out*: an audiobook that imports into
/// Apple Books with visible chapters, or per-chapter files for players that
/// want a folder of tracks. AAC at the same 64 kbps the wire uses; speech at
/// 24 kHz has nothing above 12 kHz to lose.
///
/// Chapters are a 3GPP text track marked as the audio track's chapter list —
/// the one shape Apple's own players read chapter names from. Core Media only
/// ever hands out text format descriptions parsed from files, so the `tx3g`
/// sample description is assembled here byte by byte.
public enum AudiobookExporter {
    public struct Chapter: Sendable {
        public let title: String
        /// The chapter's rendered chunks, in order. Complete chapters only —
        /// the caller decides what "complete" means.
        public let chunkURLs: [URL]

        public init(title: String, chunkURLs: [URL]) {
            self.title = title
            self.chunkURLs = chunkURLs
        }
    }

    public struct BookMetadata: Sendable {
        public let title: String
        public let author: String?
        /// Cover image bytes as stored (JPEG or PNG), if the book has one.
        public let cover: Data?

        public init(title: String, author: String?, cover: Data?) {
            self.title = title
            self.author = author
            self.cover = cover
        }
    }

    public enum ExportError: Error, LocalizedError {
        case nothingRendered
        case writerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .nothingRendered:
                return "Nothing has been rendered yet — convert a chapter first."
            case .writerFailed(let reason):
                return "The export could not be written: \(reason)"
            }
        }
    }

    /// One book as a chapter-marked audiobook file.
    ///
    /// Synchronous and heavy — minutes for a long book, dominated by the AAC
    /// encode — so call it off the main thread. `progress` is a fraction of
    /// samples written, called on the calling thread.
    public static func writeM4B(
        chapters: [Chapter],
        metadata: BookMetadata,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let spoken = chapters.filter { !$0.chunkURLs.isEmpty }
        guard !spoken.isEmpty else { throw ExportError.nothingRendered }

        // AVAssetWriter knows `.m4a`; an `.m4b` is the same container wearing
        // the audiobook extension, so it is written under a temporary name and
        // moved into place whole.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staging) }

        let writer = try AVAssetWriter(outputURL: staging, fileType: .m4a)
        writer.metadata = metadataItems(for: metadata)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(WavFile.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: AudioCodec.bitRate,
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        let textInput = AVAssetWriterInput(
            mediaType: .text, outputSettings: nil,
            sourceFormatHint: try chapterFormatDescription()
        )
        textInput.expectsMediaDataInRealTime = false
        // A chapter list is consulted, not played.
        textInput.marksOutputTrackAsEnabled = false
        writer.add(textInput)
        audioInput.addTrackAssociation(
            withTrackOf: textInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        )

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // Audio first, counting each chapter's real frames as they pass — the
        // chapter marks need the measured lengths, not estimates.
        let totalFrames = spoken
            .flatMap(\.chunkURLs)
            .reduce(into: Int64(0)) { total, url in
                total += Int64((WavFile.duration(ofFileAt: url) ?? 0) * Double(WavFile.sampleRate))
            }
        var written: Int64 = 0
        var chapterFrames: [Int64] = []
        for chapter in spoken {
            var frames: Int64 = 0
            for url in chapter.chunkURLs {
                let file = try AVAudioFile(forReading: url)
                let capacity: AVAudioFrameCount = 32_768
                // Guarded by position, not by a zero-length read: reading at
                // EOF does not return empty, it throws a bare ObjC error.
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: capacity
                    ) else { throw ExportError.writerFailed("buffer allocation") }
                    try file.read(into: buffer, frameCount: capacity)
                    guard buffer.frameLength > 0 else { break }
                    let sample = try sampleBuffer(from: buffer, at: written)
                    while !audioInput.isReadyForMoreMediaData {
                        // The writer's pull model, without handing control to
                        // a callback queue: this whole function is already off
                        // the main thread and has nothing else to do.
                        usleep(2_000)
                    }
                    guard audioInput.append(sample) else {
                        throw ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "audio append"
                        )
                    }
                    written += Int64(buffer.frameLength)
                    frames += Int64(buffer.frameLength)
                    if totalFrames > 0 {
                        progress?(Double(written) / Double(totalFrames))
                    }
                }
            }
            chapterFrames.append(frames)
        }
        audioInput.markAsFinished()

        // The chapter track: one text sample per chapter, as long as its audio.
        var cursor: Int64 = 0
        for (chapter, frames) in zip(spoken, chapterFrames) where frames > 0 {
            let sample = try chapterSample(
                title: chapter.title,
                start: CMTime(value: cursor, timescale: CMTimeScale(WavFile.sampleRate)),
                duration: CMTime(value: frames, timescale: CMTimeScale(WavFile.sampleRate)),
                format: try chapterFormatDescription()
            )
            while !textInput.isReadyForMoreMediaData { usleep(2_000) }
            guard textInput.append(sample) else {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "chapter append")
            }
            cursor += frames
        }
        textInput.markAsFinished()

        writer.endSession(
            atSourceTime: CMTime(value: written, timescale: CMTimeScale(WavFile.sampleRate))
        )
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    /// One chapter as a tagged `.m4a`, for players that want a folder of
    /// tracks rather than one audiobook file.
    public static func writeChapterM4A(
        chunkURLs: [URL],
        title: String,
        track: (number: Int, total: Int)?,
        metadata: BookMetadata,
        to destination: URL
    ) throws {
        guard !chunkURLs.isEmpty else { throw ExportError.nothingRendered }
        var tagged = metadata
        _ = tagged  // metadata reused whole; the chapter title rides separately

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staging) }

        let writer = try AVAssetWriter(outputURL: staging, fileType: .m4a)
        var items = metadataItems(for: metadata)
        // The chapter is the track; the book is its album.
        items.removeAll { $0.identifier == .commonIdentifierTitle }
        items.append(item(.commonIdentifierTitle, title))
        items.append(item(.iTunesMetadataAlbum, metadata.title))
        writer.metadata = items

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(WavFile.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: AudioCodec.bitRate,
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        var written: Int64 = 0
        for url in chunkURLs {
            let file = try AVAudioFile(forReading: url)
            let capacity: AVAudioFrameCount = 32_768
            // Guarded by position, not by a zero-length read — see writeM4B.
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: capacity
                ) else { throw ExportError.writerFailed("buffer allocation") }
                try file.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { break }
                let sample = try sampleBuffer(from: buffer, at: written)
                while !audioInput.isReadyForMoreMediaData { usleep(2_000) }
                guard audioInput.append(sample) else {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append")
                }
                written += Int64(buffer.frameLength)
            }
        }
        audioInput.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: written, timescale: CMTimeScale(WavFile.sampleRate))
        )
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    /// A safe file name from a title: what the save panel offers, and what a
    /// per-chapter export names its files.
    public static func filename(_ title: String, number: Int? = nil) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Chapter" : cleaned
        guard let number else { return base }
        return String(format: "%03d %@", number, base)
    }

    // MARK: - Tags

    private static func metadataItems(for metadata: BookMetadata) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [item(.commonIdentifierTitle, metadata.title)]
        if let author = metadata.author {
            items.append(item(.commonIdentifierArtist, author))
            items.append(item(.iTunesMetadataArtist, author))
            items.append(item(.iTunesMetadataAlbumArtist, author))
        }
        items.append(item(.iTunesMetadataUserGenre, "Audiobook"))
        if let cover = metadata.cover {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = cover as NSData
            artwork.dataType = kCMMetadataBaseDataType_RawData as String
            items.append(artwork)
        }
        return items
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    // MARK: - Audio plumbing

    /// Wrap a PCM buffer as the `CMSampleBuffer` the asset writer wants.
    private static func sampleBuffer(
        from pcm: AVAudioPCMBuffer, at frame: Int64
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: CMTime(
                value: frame, timescale: CMTimeScale(pcm.format.sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: pcm.format.formatDescription,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw ExportError.writerFailed("CMSampleBufferCreate \(status)")
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        guard status == noErr else {
            throw ExportError.writerFailed("SetDataBufferFromAudioBufferList \(status)")
        }
        return sample
    }

    // MARK: - Chapter track plumbing

    /// The 3GPP `tx3g` sample description, assembled by hand — Core Media
    /// only parses these out of existing files, it does not build them.
    private static func chapterFormatDescription() throws -> CMFormatDescription {
        var atom = Data()
        func u32(_ value: UInt32) {
            atom.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        }
        func u16(_ value: UInt16) {
            atom.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        }
        func u8(_ value: UInt8) { atom.append(value) }

        // SampleEntry header: size, 'tx3g', six reserved bytes, data ref index.
        u32(0)  // size, patched below
        atom.append(contentsOf: Array("tx3g".utf8))
        for _ in 0..<6 { u8(0) }
        u16(1)
        // TextSampleEntry: display flags, justification, background colour.
        u32(0)
        u8(1)  // horizontal: centre
        u8(0xFF)  // vertical: bottom (-1)
        for _ in 0..<4 { u8(0) }  // background RGBA
        // Default text box, empty.
        for _ in 0..<4 { u16(0) }
        // Default style record: chars 0..0, font 1, plain, 12pt, white.
        u16(0); u16(0); u16(1)
        u8(0); u8(12)
        u8(0xFF); u8(0xFF); u8(0xFF); u8(0xFF)
        // Font table box.
        u32(8 + 2 + 2 + 1 + 5)  // size
        atom.append(contentsOf: Array("ftab".utf8))
        u16(1)  // one font
        u16(1)  // font id
        u8(5)
        atom.append(contentsOf: Array("Serif".utf8))

        var size = UInt32(atom.count).bigEndian
        atom.replaceSubrange(0..<4, with: withUnsafeBytes(of: &size, Array.init))

        var description: CMFormatDescription?
        let status = atom.withUnsafeBytes { bytes in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: bytes.bindMemory(to: UInt8.self).baseAddress!,
                size: atom.count,
                flavor: nil,
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw ExportError.writerFailed("text format description \(status)")
        }
        return description
    }

    /// One chapter mark: a text sample holding the title, lasting exactly as
    /// long as the chapter's audio.
    private static func chapterSample(
        title: String, start: CMTime, duration: CMTime, format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        // A tx3g sample is a big-endian length followed by UTF-8 text.
        let text = Array(title.utf8.prefix(Int(UInt16.max)))
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(text.count).bigEndian, Array.init))
        payload.append(contentsOf: text)

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw ExportError.writerFailed("chapter block \(status)")
        }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard status == noErr else {
            throw ExportError.writerFailed("chapter bytes \(status)")
        }

        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw ExportError.writerFailed("chapter sample \(status)")
        }
        return sample
    }
}
