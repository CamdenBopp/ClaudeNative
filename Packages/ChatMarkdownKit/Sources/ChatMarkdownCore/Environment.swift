import CoreGraphics
import Foundation

public enum LayoutDirection: Hashable, Sendable {
    case leftToRight
    case rightToLeft
}

/// Everything outside the document that can change geometry or appearance.
/// Every layout/render cache key must embed the environment — a Dynamic Type
/// or theme change produces a new environment and therefore misses old entries
/// instead of serving stale geometry.
public struct RenderEnvironment: Hashable, Sendable {
    public var displayScale: CGFloat
    public var layoutDirection: LayoutDirection
    /// UIContentSizeCategory.rawValue on iOS. Stored as a string so Core stays
    /// UIKit-free and host-testable on macOS.
    public var contentSizeCategory: String
    /// Hash of the resolved theme (fonts, colors, spacing). The UIKit layer
    /// recomputes this when the trait collection or app theme changes.
    public var themeFingerprint: Int

    public init(
        displayScale: CGFloat = 2,
        layoutDirection: LayoutDirection = .leftToRight,
        contentSizeCategory: String = "UICTContentSizeCategoryL",
        themeFingerprint: Int = 0
    ) {
        self.displayScale = displayScale
        self.layoutDirection = layoutDirection
        self.contentSizeCategory = contentSizeCategory
        self.themeFingerprint = themeFingerprint
    }
}

/// Cache key for one block's layout at one width in one environment.
public struct RenderCacheKey: Hashable, Sendable {
    public let blockID: BlockID
    public let blockRevision: BlockRevision
    /// Width in half-point buckets so floating-point jitter cannot split
    /// logically identical entries.
    public let widthBucket: Int
    public let environment: RenderEnvironment

    public init(
        blockID: BlockID,
        blockRevision: BlockRevision,
        width: CGFloat,
        environment: RenderEnvironment
    ) {
        self.blockID = blockID
        self.blockRevision = blockRevision
        self.widthBucket = Self.widthBucket(for: width)
        self.environment = environment
    }

    /// The canonical width→bucket mapping, exposed so consumers (cell
    /// containers) can gate incoming commits against their current width.
    public static func widthBucket(for width: CGFloat) -> Int {
        Int((width * 2).rounded())
    }
}
