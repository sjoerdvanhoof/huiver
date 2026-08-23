import AVFoundation
import Foundation
import Testing

@testable import HuiverKit

/// Where chunks land on the player's timeline.
///
/// This is the arithmetic behind a bug worth remembering: chunks were being
/// scheduled with `at: nil`, which appends only while the node still has
/// something queued and means "now" once it has drained. Since synthesis runs at
/// roughly the speed of speech, the node drains constantly, so each new chunk
/// cut off the one playing and playback skipped forward — losing about half the
/// audio.
struct PlaybackTests {
    let rate = Double(WavFile.sampleRate)

    @Test("consecutive chunks are gapless while the renderer keeps up")
    func gapless() {
        // Ten-second chunks, playhead still inside the first one.
        let length = AVAudioFramePosition(rate * 10)
        var cursor: AVAudioFramePosition = 0
        var starts: [AVAudioFramePosition] = []

        for index in 0..<5 {
            let playhead = AVAudioFramePosition(rate * Double(index) * 9)  // lagging behind
            cursor = Narrator.startFrame(cursor: cursor, playhead: playhead, rate: rate)
            starts.append(cursor)
            cursor += length
        }

        // Each chunk begins exactly where the last ended: no gap, no overlap.
        // The absolute position is not the point — the first chunk gets a tenth
        // of a second of headroom because the playhead starts at zero too — so
        // what is checked is that the run is contiguous.
        for (previous, next) in zip(starts, starts.dropFirst()) {
            #expect(next - previous == length, "gap or overlap between chunks")
        }
        #expect(starts[0] > 0)
    }

    @Test("a late chunk is scheduled ahead of the playhead, never behind it")
    func neverInThePast() {
        // The renderer stalled: the playhead has run well past the cursor.
        let playhead = AVAudioFramePosition(rate * 30)
        let start = Narrator.startFrame(
            cursor: AVAudioFramePosition(rate * 10), playhead: playhead, rate: rate
        )
        #expect(start > playhead, "would be dropped by Core Audio")
        #expect(start == playhead + AVAudioFramePosition(rate / 10))
    }

    @Test("positions only ever increase")
    func monotonic() {
        var cursor: AVAudioFramePosition = 0
        var previous: AVAudioFramePosition = -1
        // Alternate between keeping up and falling behind.
        for index in 0..<20 {
            let playhead = AVAudioFramePosition(rate * Double(index) * (index.isMultiple(of: 3) ? 14 : 2))
            cursor = Narrator.startFrame(cursor: cursor, playhead: playhead, rate: rate)
            #expect(cursor > previous)
            previous = cursor
            cursor += AVAudioFramePosition(rate * 8)
        }
    }

    @Test("the cursor is not disturbed when the playhead is exactly at it")
    func boundary() {
        // Equal counts as past: a segment starting on the current frame is
        // already too late to be rendered.
        let start = Narrator.startFrame(cursor: 1000, playhead: 1000, rate: rate)
        #expect(start > 1000)
    }
}

/// Where a seek is allowed to land.
///
/// The rule exists because of a real dead end: skipping forward 30 seconds with
/// three seconds rendered used to schedule the last fraction of a sentence, play
/// it, and leave a silent player with the scrubber pinned at the edge.
struct SeekTests {
    @Test("seeking backwards is unrestricted")
    func backwards() {
        #expect(Narrator.seekTarget(to: 10, from: 400, rendered: 500) == 10)
        #expect(Narrator.seekTarget(to: 0, from: 3, rendered: 500) == 0)
    }

    @Test("a seek before the start lands at the start")
    func negative() {
        #expect(Narrator.seekTarget(to: -30, from: 10, rendered: 500) == 0)
    }

    @Test("forwards is clamped to what has been rendered")
    func clamped() {
        // 100 rendered, less the quarter second of padding between chunks.
        #expect(Narrator.seekTarget(to: 500, from: 10, rendered: 100) == 99.75)
    }

    @Test("a forward seek that would gain almost nothing is refused")
    func refused() {
        // Three seconds rendered, playing at 2.5: +30 has nowhere to go.
        #expect(Narrator.seekTarget(to: 32.5, from: 2.5, rendered: 3) == nil)
        // Right at the edge already.
        #expect(Narrator.seekTarget(to: 100, from: 99, rendered: 100) == nil)
    }

    @Test("a forward seek with room to move is allowed")
    func allowed() {
        #expect(Narrator.seekTarget(to: 40, from: 10, rendered: 500) == 40)
        // Only just worth it, but the audio is really there.
        #expect(Narrator.seekTarget(to: 12.5, from: 10, rendered: 500) == 12.5)
    }

    @Test("nothing rendered yet means nowhere to go, not even the beginning")
    func empty() {
        // Seeking tears down the player's queue and rebuilds it. With nothing to
        // put back, that leaves a player sounding nothing while claiming to
        // play — so with no audio on disk, every seek is refused.
        #expect(Narrator.seekTarget(to: 30, from: 0, rendered: 0) == nil)
        #expect(Narrator.seekTarget(to: 0, from: 0, rendered: 0) == nil)
        #expect(Narrator.seekTarget(to: 0, from: 0, rendered: 0.2) == nil)
    }

    // MARK: - What a voice change keeps

    /// Three one-second chunks on disk, and the count of them the listener has
    /// started — which is what a new voice keeps when it takes over.
    func writeChunks(_ count: Int) throws -> [URL] {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = [Float](repeating: 0, count: WavFile.sampleRate)
        return try (0..<count).map { index in
            let url = directory.appendingPathComponent(String(format: "%05d.wav", index))
            try WavFile.data(from: samples).write(to: url)
            return url
        }
    }

    @Test("a listener at the top of the chapter keeps nothing")
    func keepsNothingAtTheTop() throws {
        #expect(Narrator.chunksStarted(before: 0, urls: try writeChunks(3)) == 0)
    }

    @Test("the chunk under the playhead is kept, what follows is not")
    func keepsTheHeardPrefix() throws {
        let urls = try writeChunks(3)
        // Half a second into the first chunk: only that chunk has been started.
        #expect(Narrator.chunksStarted(before: 0.5, urls: urls) == 1)
        // Half a second into the second.
        #expect(Narrator.chunksStarted(before: 1.5, urls: urls) == 2)
        // Exactly on a boundary: the chunk ahead has not been started yet.
        #expect(Narrator.chunksStarted(before: 1.0, urls: urls) == 1)
    }

    @Test("a position past the rendered edge keeps everything there is")
    func keepsEverythingPastTheEdge() throws {
        #expect(Narrator.chunksStarted(before: 30, urls: try writeChunks(3)) == 3)
    }
}
