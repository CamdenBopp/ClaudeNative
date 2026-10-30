import CoreGraphics
import Foundation

/// Scroll behavior during streaming, as pure functions of geometry.
///
/// Two regimes:
/// - **Following** (user at/near the bottom): every content change re-pins
///   the viewport to the bottom, so streamed text appears to grow in place.
/// - **Reading** (user scrolled up): the anchor item must not move. Content
///   growing *below* the viewport changes nothing; height corrections
///   *above* the anchor are compensated by shifting the offset.
public enum ChatScrollPolicy {
    /// Within this distance of the bottom counts as "following".
    public static let defaultFollowThreshold: CGFloat = 44

    public static func maxOffsetY(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }

    public static func isNearBottom(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        threshold: CGFloat = defaultFollowThreshold
    ) -> Bool {
        offsetY >= maxOffsetY(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        ) - threshold
    }

    public static func clamped(
        _ offsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        let upper = maxOffsetY(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return min(max(offsetY, -topInset), upper)
    }

    /// The offset to apply after geometry changed.
    public static func targetOffsetY(
        previousOffsetY: CGFloat,
        anchorCompensation: CGFloat,
        followBottom: Bool,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        if followBottom {
            return maxOffsetY(
                contentHeight: contentHeight,
                viewportHeight: viewportHeight,
                topInset: topInset,
                bottomInset: bottomInset
            )
        }
        return clamped(
            previousOffsetY + anchorCompensation,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }
}
