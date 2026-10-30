import CoreGraphics
import CoreText
import Foundation
import ChatMarkdownCore

/// Typography and block-metric configuration for non-code text. A small value
/// type: its `hashValue` feeds `RenderEnvironment.themeFingerprint`, so any
/// change produces new cache keys instead of stale geometry.
public struct TextTheme: Hashable, Sendable {
    public var bodySize: CGFloat = 16
    public var monospacedFontName: String = "Menlo"
    /// Multipliers over `bodySize` for heading levels 1–6.
    public var headingScales: [CGFloat] = [1.75, 1.5, 1.25, 1.1, 1.0, 0.9]

    // Block metrics (points).
    public var innerBlockSpacing: CGFloat = 8
    public var quoteBarWidth: CGFloat = 3
    public var quoteIndent: CGFloat = 14
    public var listIndent: CGFloat = 26
    public var listMarkerGap: CGFloat = 8
    public var listItemSpacing: CGFloat = 4
    public var tableCellPadding: CGFloat = 6
    public var tableMinColumnWidth: CGFloat = 44
    public var thematicBreakHeight: CGFloat = 17
    /// Composites never lay out children narrower than this, no matter how
    /// deep the nesting.
    public var minimumContentWidth: CGFloat = 40

    public init() {}

    public static let `default` = TextTheme()

    public func headingScale(for level: Int) -> CGFloat {
        let index = min(max(level, 1), headingScales.count) - 1
        return headingScales[index]
    }
}

extension TextTheme {
    /// Cached font lookup. A device profile showed per-call CTFont creation
    /// (`CTFontCreateUIFontForLanguage` + descriptor splicing) at ~40% of
    /// attributed-string building during streaming — every token re-styles
    /// the tail block, so fonts are requested thousands of times per message
    /// while the distinct set stays tiny (sizes × trait combos).
    func font(for attributes: InlineRun.Attributes, sizeMultiplier: CGFloat = 1) -> CTFont {
        FontCache.shared.font(
            monospacedFontName: attributes.contains(.code) ? monospacedFontName : nil,
            size: bodySize * sizeMultiplier,
            bold: attributes.contains(.bold),
            italic: attributes.contains(.italic)
        )
    }
}

/// Process-wide CTFont cache. CTFont is immutable and documented thread-safe,
/// so instances can be shared freely across layout actors; the dictionary is
/// lock-protected. Unbounded by design: the key space is a handful of sizes ×
/// trait combinations, not user data.
private final class FontCache: @unchecked Sendable {
    static let shared = FontCache()

    private struct Key: Hashable {
        /// Set for code runs; `nil` means the system UI font.
        let monospacedFontName: String?
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    private let lock = NSLock()
    private var fonts: [Key: CTFont] = [:]

    func font(monospacedFontName: String?, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let key = Key(monospacedFontName: monospacedFontName, size: size, bold: bold, italic: italic)
        lock.lock()
        if let cached = fonts[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // Create outside the lock — font creation can be slow and reentrant
        // into CoreText; a duplicate racing create is harmless (both values
        // are equivalent immutable fonts).
        let font = Self.makeFont(key)
        lock.lock()
        fonts[key] = font
        lock.unlock()
        return font
    }

    private static func makeFont(_ key: Key) -> CTFont {
        if let name = key.monospacedFontName {
            return CTFontCreateWithName(name as CFString, key.size * 0.9, nil)
        }
        let base = CTFontCreateUIFontForLanguage(.system, key.size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, key.size, nil)
        var traits: CTFontSymbolicTraits = []
        if key.bold { traits.insert(.traitBold) }
        if key.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    }
}
