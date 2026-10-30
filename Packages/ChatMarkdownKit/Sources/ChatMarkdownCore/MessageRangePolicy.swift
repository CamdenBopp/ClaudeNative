import CoreGraphics
import Foundation

/// How "warm" a message should be, by distance from the viewport.
/// Ordered: each state permits everything the previous one does.
public enum MessageRangeState: Int, Comparable, Hashable, Sendable {
    /// Retain only heights and block metadata; layout caches released.
    case cold = 0
    /// Close enough to warm parses/layout caches ahead of display.
    case preload
    /// Should be fully layout-ready before it can scroll on screen.
    case displayReady
    /// Intersects the viewport.
    case visible

    public static func < (lhs: MessageRangeState, rhs: MessageRangeState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Viewport-relative range membership (the Texture range idea, reimplemented
/// as pure policy). Distances are measured in viewport multiples and biased
/// toward the scroll direction — a message count is meaningless here, because
/// one message can be 24 points tall and the next 12,000.
public struct MessageRangePolicy: Hashable, Sendable {
    /// Viewport multiples behind the scroll direction.
    public var displayBehind: CGFloat = 1.5
    public var preloadBehind: CGFloat = 3
    /// Viewport multiples ahead, interpolated from slow → fast by velocity.
    public var displayAheadSlow: CGFloat = 3
    public var displayAheadFast: CGFloat = 5
    public var preloadAheadSlow: CGFloat = 8
    public var preloadAheadFast: CGFloat = 12
    /// |velocity| (points/second) at which the "ahead" extents reach their
    /// fast values.
    public var fastVelocity: CGFloat = 3000

    public init() {}

    /// One state per geometry index. `velocity` is signed points/second;
    /// positive means scrolling toward larger y (later messages).
    public func states(
        geometry: ChatListGeometry,
        viewportMinY: CGFloat,
        viewportHeight: CGFloat,
        velocity: CGFloat = 0
    ) -> [MessageRangeState] {
        let count = geometry.count
        guard count > 0 else { return [] }
        guard viewportHeight > 0 else { return [MessageRangeState](repeating: .cold, count: count) }

        let speed = min(1, abs(velocity) / max(1, fastVelocity))
        let displayAhead = displayAheadSlow + (displayAheadFast - displayAheadSlow) * speed
        let preloadAhead = preloadAheadSlow + (preloadAheadFast - preloadAheadSlow) * speed
        let movingTowardEnd = velocity >= 0
        let viewportMaxY = viewportMinY + viewportHeight

        func band(behind: CGFloat, ahead: CGFloat) -> (minY: CGFloat, maxY: CGFloat) {
            let above = movingTowardEnd ? behind : ahead
            let below = movingTowardEnd ? ahead : behind
            return (viewportMinY - above * viewportHeight, viewportMaxY + below * viewportHeight)
        }

        let display = band(behind: displayBehind, ahead: displayAhead)
        let preload = band(behind: max(preloadBehind, displayBehind), ahead: max(preloadAhead, displayAhead))

        var states = [MessageRangeState](repeating: .cold, count: count)
        for index in geometry.indices(intersectingMinY: preload.minY, maxY: preload.maxY) {
            states[index] = .preload
        }
        for index in geometry.indices(intersectingMinY: display.minY, maxY: display.maxY) {
            states[index] = .displayReady
        }
        for index in geometry.indices(intersectingMinY: viewportMinY, maxY: viewportMaxY) {
            states[index] = .visible
        }
        return states
    }
}
