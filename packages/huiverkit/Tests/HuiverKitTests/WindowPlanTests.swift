import Foundation
import Testing

@testable import HuiverKit

/// Covering a long run of speech tokens with the mel decoder's fixed window.
///
/// The decoder renders a window of tokens against the voice's reference clip
/// and nothing else — it has no memory of the window before. So a chunk longer
/// than one window is rendered in pieces, and how those pieces are chosen is
/// the difference between a continuous sentence and one that audibly stops and
/// restarts in the middle.
///
/// Two properties matter and neither needs a model to check: the kept slices
/// must tile the run exactly once, and every window after the first must be
/// given preceding tokens to run up to its join.
struct WindowPlanTests {
    let window = 768
    let runUp = ChatterboxEngine.runUpTokens
    let tail = ChatterboxEngine.tailTokens

    func plan(_ tokenCount: Int) -> [ChatterboxEngine.WindowStep] {
        ChatterboxEngine.windowPlan(
            tokenCount: tokenCount, window: window, runUp: runUp, tail: tail
        )
    }

    /// Anything that fits is one window, untouched — the overwhelmingly common
    /// case, and it must not pay for the machinery below.
    @Test("a short run is a single window")
    func shortRunIsOneWindow() {
        let steps = plan(400)
        #expect(steps == [.init(start: 0, end: 400, keepFrom: 0, keepUntil: 400)])
    }

    /// The three silence tokens have to fit alongside the content, so a run
    /// that exactly fills the window is already too long for one.
    @Test("a run that would clip its last word is split")
    func fullWindowIsSplit() {
        #expect(plan(window - 3).count == 1)
        #expect(plan(window).count > 1, "no room for the silence tokens")
    }

    /// The property that matters most: every token's audio is emitted once,
    /// in order. A gap is a dropped syllable; an overlap is a stutter.
    @Test("the kept slices tile the run exactly once", arguments: [769, 800, 1200, 1536, 4000])
    func keptSlicesTile(tokenCount: Int) {
        var expected = 0
        for step in plan(tokenCount) {
            #expect(step.keepFrom == expected, "gap or overlap at \(step.keepFrom)")
            #expect(step.keepUntil > step.keepFrom, "a window that emits nothing")
            expected = step.keepUntil
        }
        #expect(expected == tokenCount, "the run is covered to the end")
    }

    /// Every join is preceded by real context, so the decoder is mid-sentence
    /// by the time it reaches the audio we keep.
    @Test("every window after the first gets run-up")
    func laterWindowsGetRunUp() {
        let steps = plan(2000)
        #expect(steps.count > 1)
        for step in steps.dropFirst() {
            #expect(step.keepFrom - step.start == runUp, "no run-up before the join")
        }
        #expect(steps[0].start == 0, "the first window has nothing to run up from")
    }

    /// A non-final window's last tokens are the ones the missing silence
    /// padding would have protected, so they are re-rendered by the next
    /// window rather than kept.
    @Test("a non-final window drops its clipped tail")
    func dropsTheClippedTail() {
        let steps = plan(2000)
        for step in steps.dropLast() {
            #expect(step.keepUntil == step.end - tail)
        }
        #expect(steps.last?.keepUntil == steps.last?.end, "the last window keeps everything")
    }

    /// No window may ask the decoder for more than it was exported to take.
    @Test("no window exceeds the decoder's size", arguments: [769, 1000, 2500, 10_000])
    func windowsFitTheDecoder(tokenCount: Int) {
        for step in plan(tokenCount) {
            #expect(step.end - step.start <= window)
            #expect(step.start >= 0)
            #expect(step.end <= tokenCount)
        }
    }

    /// It has to finish. An off-by-one in the overlap arithmetic would loop
    /// forever, and it would do it inside a render.
    @Test("the plan always terminates and makes progress")
    func alwaysProgresses() {
        for tokenCount in [769, 771, 800, 831, 1535, 1537, 5000] {
            let steps = plan(tokenCount)
            #expect(steps.count < 100, "\(tokenCount) tokens took \(steps.count) windows")
            var previous = -1
            for step in steps {
                #expect(step.keepUntil > previous)
                previous = step.keepUntil
            }
        }
    }

    /// Just over the boundary is the case most likely to produce a degenerate
    /// final window of one or two tokens.
    @Test("a run barely over one window does not leave a sliver")
    func noDegenerateFinalWindow() {
        for tokenCount in [window - 2, window, window + 1, window + 10] {
            for step in plan(tokenCount) {
                #expect(step.keepUntil - step.keepFrom > 0)
            }
        }
    }
}
