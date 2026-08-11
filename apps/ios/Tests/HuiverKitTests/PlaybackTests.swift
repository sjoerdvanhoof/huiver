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
