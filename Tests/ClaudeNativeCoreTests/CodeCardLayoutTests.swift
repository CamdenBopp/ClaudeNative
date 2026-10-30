import Foundation
import Testing
@testable import ClaudeNativeCore

/// The code cards behind a streaming reply are measured from the start of
/// the reply through each block, so measuring every card on every delta is
/// the reply's length times its code blocks. These pin that a delta only
/// measures the cards it could have moved.
struct CodeCardLayoutTests {
    /// Fenced code blocks in `text`, as UTF-16 ranges from the opening fence
    /// line to the end of the closing one (or the end of the text while the
    /// fence is still open).
    static func codeBlocks(in text: String) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var openStart: Int?
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf16.count
            if line.hasPrefix("```") {
                if let start = openStart {
                    blocks.append(start ..< offset + length)
                    openStart = nil
                } else {
                    openStart = offset
                }
            }
            offset += length + 1
        }
        if let start = openStart { blocks.append(start ..< text.utf16.count) }
        return blocks
    }

    /// A stand-in for laying out the text: it depends on every character
    /// up to the block's end, as the real measurement does.
    static func measure(_ text: String) -> (Range<Int>) -> (top: Double, bottom: Double) {
        let units = Array(text.utf16)
        return { range in
            let newlines = { (end: Int) in Double(units[..<end].lazy.filter { $0 == 10 }.count) }
            return (top: newlines(range.lowerBound), bottom: newlines(range.upperBound))
        }
    }

    /// A 5,000-line reply in 20-character deltas: about 7,000 updates and
    /// 360 code blocks. Measuring every card each update would be over a
    /// million measurements; reuse keeps it near one per update.
    @Test func streamingMeasuresAboutOneCardPerUpdate() {
        let text = LongReplyStream.reply(lines: 5_000)
        let pieces = LongReplyStream.deltas(of: text, size: 20)
        let finalBlocks = Self.codeBlocks(in: text)
        let units = Array(text.utf16)
        var layout = CodeCardLayout()
        var length = 0
        var started = 0
        for piece in pieces {
            // The renderer redraws from the start of the last line it had,
            // or from the code block that line is in.
            var lineStart = length
            while lineStart > 0, units[lineStart - 1] != 10 { lineStart -= 1 }
            let open = finalBlocks[..<started].last { $0.upperBound >= length }
            layout.textChanged(unchangedLength: min(lineStart, open?.lowerBound ?? lineStart))
            length += piece.utf16.count
            while started < finalBlocks.count, finalBlocks[started].lowerBound < length { started += 1 }
            let blocks = finalBlocks[..<started].map { $0.lowerBound ..< min($0.upperBound, length) }
            layout.place(blocks: blocks, width: 600) { range in
                (top: Double(range.lowerBound), bottom: Double(range.upperBound))
            }
        }
        let blocks = finalBlocks.count
        #expect(blocks > 300)
        #expect(
            layout.measuredCount <= pieces.count + blocks,
            "measured \(layout.measuredCount) cards over \(pieces.count) updates and \(blocks) blocks"
        )
        #expect(layout.cards.count == blocks)
    }

    /// Reused cards are exactly what measuring afresh gives.
    @Test func reusedCardsMatchAFreshMeasurement() {
        let text = LongReplyStream.reply(lines: 300)
        var layout = CodeCardLayout()
        var shown = ""
        var previousLength = 0
        for piece in LongReplyStream.deltas(of: text, size: 11) {
            shown += piece
            // Everything before the new piece's line is unchanged.
            layout.textChanged(unchangedLength: max(0, previousLength - 80))
            previousLength = shown.utf16.count
            let blocks = Self.codeBlocks(in: shown)
            let reused = layout.place(blocks: blocks, width: 600, measure: Self.measure(shown))
            var fresh = CodeCardLayout()
            #expect(reused == fresh.place(blocks: blocks, width: 600, measure: Self.measure(shown)))
        }
    }

    /// Text changed before a card means the card moves, even when its own
    /// range is the same.
    @Test func aChangeBeforeACardMeasuresItAgain() {
        var layout = CodeCardLayout()
        let blocks = [10 ..< 20, 30 ..< 40]
        layout.place(blocks: blocks, width: 600) { (top: Double($0.lowerBound), bottom: Double($0.upperBound)) }
        layout.textChanged(unchangedLength: 25)
        let cards = layout.place(blocks: blocks, width: 600) { (top: Double($0.lowerBound) + 1, bottom: Double($0.upperBound) + 1) }
        #expect(cards.map(\.top) == [10, 31])
        #expect(layout.measuredCount == 3)
    }

    @Test func aNewWidthMeasuresEveryCard() {
        var layout = CodeCardLayout()
        let blocks = [10 ..< 20, 30 ..< 40]
        layout.place(blocks: blocks, width: 600) { (top: Double($0.lowerBound), bottom: Double($0.upperBound)) }
        layout.place(blocks: blocks, width: 600) { _ in (top: -1, bottom: -1) }
        #expect(layout.measuredCount == 2)
        let cards = layout.place(blocks: blocks, width: 480) { (top: Double($0.lowerBound) * 2, bottom: Double($0.upperBound) * 2) }
        #expect(cards.map(\.top) == [20, 60])
        #expect(layout.measuredCount == 4)
    }
}
