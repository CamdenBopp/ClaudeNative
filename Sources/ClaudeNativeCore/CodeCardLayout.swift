import Foundation

/// Where the cards behind a reply's code blocks go, kept between layouts.
///
/// A card's top and bottom come from laying out the text from the start of
/// the reply through the end of its block, so measuring every card on every
/// streaming delta costs the reply's length times its code blocks. Text
/// before the first changed character lays out the same as before, so a
/// card whose block ends there keeps its measurement; only cards from the
/// changed part on are measured again.
public struct CodeCardLayout: Sendable {
    public struct Card: Sendable, Equatable {
        /// The block's characters, in UTF-16 offsets of the reply's text.
        public let range: Range<Int>
        public let top: Double
        public let bottom: Double

        public init(range: Range<Int>, top: Double, bottom: Double) {
            self.range = range
            self.top = top
            self.bottom = bottom
        }
    }

    /// The cards as last placed, in order.
    public private(set) var cards: [Card] = []
    private var width: Double?
    /// How many cards have been measured, for tests that keep the work
    /// in proportion to the stream rather than its square.
    public private(set) var measuredCount = 0

    public init() {}

    /// The reply's text changed from `unchangedLength` on (UTF-16 offsets).
    /// Cards whose block ends after that are measured again.
    public mutating func textChanged(unchangedLength: Int) {
        if let stale = cards.firstIndex(where: { $0.range.upperBound > unchangedLength }) {
            cards.removeSubrange(stale...)
        }
    }

    /// Forgets every measurement, for a new font or a new reply.
    public mutating func reset() {
        cards = []
        width = nil
    }

    /// Places a card for each block in `blocks` at `width`, reusing the
    /// cards still known and measuring the rest, in order.
    @discardableResult
    public mutating func place(
        blocks: [Range<Int>], width: Double,
        measure: (Range<Int>) -> (top: Double, bottom: Double)
    ) -> [Card] {
        if width != self.width {
            self.width = width
            cards = []
        }
        var placed: [Card] = []
        placed.reserveCapacity(blocks.count)
        for (index, range) in blocks.enumerated() {
            if index < cards.count, cards[index].range == range {
                placed.append(cards[index])
            } else {
                let edges = measure(range)
                measuredCount += 1
                placed.append(Card(range: range, top: edges.top, bottom: edges.bottom))
            }
        }
        cards = placed
        return placed
    }
}
