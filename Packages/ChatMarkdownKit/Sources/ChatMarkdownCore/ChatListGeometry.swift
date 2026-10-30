import CoreGraphics
import Foundation

/// Vertical list geometry from an authoritative height array — the custom
/// collection layout reads frames from here instead of asking cells to
/// self-size. Immutable value: a height change builds a new geometry, and
/// scroll compensation is computed between the two.
public struct ChatListGeometry: Equatable, Sendable {
    public let spacing: CGFloat
    public let heights: [CGFloat]
    public let contentHeight: CGFloat
    private let starts: [CGFloat]

    public init(heights: [CGFloat] = [], spacing: CGFloat = 16) {
        self.heights = heights
        self.spacing = spacing
        var starts: [CGFloat] = []
        starts.reserveCapacity(heights.count)
        var y: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if index > 0 { y += spacing }
            starts.append(y)
            y += height
        }
        self.starts = starts
        self.contentHeight = y
    }

    public var count: Int { heights.count }

    public func minY(at index: Int) -> CGFloat { starts[index] }

    public func maxY(at index: Int) -> CGFloat { starts[index] + heights[index] }

    public func height(at index: Int) -> CGFloat { heights[index] }

    /// The item occupying `y` (or the first one after it) — the scroll
    /// anchor. Binary search; nil only when empty.
    public func anchorIndex(forY y: CGFloat) -> Int? {
        guard !heights.isEmpty else { return nil }
        var low = 0
        var high = heights.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if maxY(at: mid) > y {
                answer = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return answer ?? heights.count - 1
    }

    /// Indices whose frames intersect the vertical range.
    public func indices(intersectingMinY minY: CGFloat, maxY: CGFloat) -> Range<Int> {
        guard !heights.isEmpty, maxY > 0, maxY > minY else { return 0..<0 }
        guard let first = anchorIndex(forY: minY), self.minY(at: first) < maxY else { return 0..<0 }
        var last = first
        while last + 1 < heights.count, self.minY(at: last + 1) < maxY {
            last += 1
        }
        return first..<(last + 1)
    }

    /// How far the anchor item moved between two geometries. Adding this to
    /// the content offset keeps the anchor visually stationary when heights
    /// above it changed.
    public static func compensation(
        from old: ChatListGeometry,
        to new: ChatListGeometry,
        anchorIndex: Int?
    ) -> CGFloat {
        guard let anchorIndex, anchorIndex < old.count, anchorIndex < new.count else { return 0 }
        return new.minY(at: anchorIndex) - old.minY(at: anchorIndex)
    }
}
