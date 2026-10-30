import Testing
@testable import ChatCodeBlocks

/// The redraw gate: streaming appends beyond the visible viewport must not
/// repaint (measured as the per-flush main-thread load during dump
/// streaming on device).
struct CodeLineDeltaTouchTests {
    @Test func appendsBeyondViewportDoNotTouch() {
        let delta = CodeLineDelta(modifiedLine: nil, appendedLines: 500..<540)
        #expect(!delta.touches(0..<25))
    }

    @Test func appendsIntoViewportTouch() {
        #expect(CodeLineDelta(modifiedLine: nil, appendedLines: 20..<60).touches(0..<25))
        #expect(CodeLineDelta(modifiedLine: nil, appendedLines: 0..<1).touches(0..<25))
    }

    @Test func modifiedLineInViewportTouches() {
        let delta = CodeLineDelta(modifiedLine: 10, appendedLines: 500..<501)
        #expect(delta.touches(0..<25))
        let below = CodeLineDelta(modifiedLine: 499, appendedLines: 500..<501)
        #expect(!below.touches(0..<25))
    }

    @Test func emptyRangesNeverTouch() {
        let delta = CodeLineDelta(modifiedLine: nil, appendedLines: 10..<10)
        #expect(!delta.touches(0..<25))
        #expect(!CodeLineDelta(modifiedLine: nil, appendedLines: 5..<8).touches(10..<10))
    }

    @Test func documentAppendDeltasGateCorrectly() {
        // Real streaming shape: capped block showing rows 0..<22 while
        // thousands land below.
        let document = CodeBlockDocument(text: (0..<200).map { "line \($0)" }.joined(separator: "\n"))
        let visible = 0..<22
        let delta = document.append("\nline 200\nline 201")
        #expect(!delta.touches(visible))
        // But the first screenful during early streaming does repaint.
        let fresh = CodeBlockDocument()
        let first = fresh.append("a\nb\nc\n")
        #expect(first.touches(visible))
    }
}
