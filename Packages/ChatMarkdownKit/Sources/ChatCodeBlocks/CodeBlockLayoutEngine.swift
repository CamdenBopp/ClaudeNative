import CoreGraphics
import CoreText
import Foundation
import ChatMarkdownCore

/// One laid-out code line. `@unchecked Sendable` for the same reason as
/// `LineSnapshot`: CTLine is immutable after creation.
public struct CodeLineLayout: @unchecked Sendable {
    public let row: Int
    public let line: CTLine
    public let width: CGFloat
}

/// Viewport-oriented CoreText layout over a `CodeBlockDocument`.
///
/// Monospaced, non-wrapping: every line has the same height, so geometry is
/// pure index math — y-offset ↔ row conversion is O(1), and the content size
/// never requires laying anything out. CTLines are created lazily for
/// requested rows and kept in a cost-bounded LRU, so a 10,000-line block
/// resident cost is (visible rows + overscan), not 10,000 lines.
///
/// NOT thread-safe — confine to one context. v1 confines it to the main
/// thread: creating a CTLine for one monospaced line is microseconds. The
/// expensive per-line work (syntax highlighting) lands in a later milestone
/// and runs off-main by design, feeding highlighted attributed lines in and
/// invalidating rows here.
public final class CodeBlockLayoutEngine {
    public let document: CodeBlockDocument
    public let font: CTFont
    public let lineHeight: CGFloat
    public let ascent: CGFloat

    private let advance: CGFloat
    private var maxCharacterCount: Int
    private let cache: LRUCache<Int, CodeLineLayout>
    private let attributes: [NSAttributedString.Key: Any]

    public init(
        document: CodeBlockDocument,
        fontName: String = "Menlo",
        fontSize: CGFloat = 13,
        cacheCostBudget: Int = 400_000
    ) {
        self.document = document
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        self.font = font
        let ascent = CTFontGetAscent(font)
        self.ascent = ascent
        self.lineHeight = ceil(ascent + CTFontGetDescent(font) + CTFontGetLeading(font))

        var digitGlyph = CGGlyph(0)
        var digitChar: UniChar = 0x30 // "0"
        _ = CTFontGetGlyphsForCharacters(font, &digitChar, &digitGlyph, 1)
        var digitAdvance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &digitGlyph, &digitAdvance, 1)
        self.advance = digitAdvance.width > 0 ? digitAdvance.width : fontSize * 0.6

        self.maxCharacterCount = document.lines.map { $0.utf16.count }.max() ?? 0
        self.cache = LRUCache(costLimit: cacheCostBudget)
        self.attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
    }

    public var lineCount: Int { document.lineCount }

    /// Width is a monospaced character-count estimate — exact for ASCII,
    /// slightly loose for tabs/emoji. Good enough for scroll extents; the
    /// per-row measured width is exact where it matters (drawing).
    public var contentSize: CGSize {
        CGSize(
            width: ceil(CGFloat(maxCharacterCount) * advance),
            height: CGFloat(lineCount) * lineHeight
        )
    }

    public func yOrigin(forRow row: Int) -> CGFloat {
        CGFloat(row) * lineHeight
    }

    public func rowRange(intersecting rect: CGRect, overscan: Int = 16) -> Range<Int> {
        guard lineCount > 0, rect.maxY > 0, lineHeight > 0 else { return 0..<0 }
        let first = max(0, Int(floor(rect.minY / lineHeight)) - overscan)
        let last = min(lineCount, Int(ceil(rect.maxY / lineHeight)) + overscan)
        return first..<max(first, last)
    }

    /// Lazily creates (or returns the cached) CTLine for one row.
    public func layout(row: Int) -> CodeLineLayout {
        if let cached = cache.value(for: row) {
            return cached
        }
        return RenderSignposts.code.withIntervalSignpost("code.visibleLineLayout") {
            let text = document.line(at: row)
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let layout = CodeLineLayout(row: row, line: line, width: width)
            cache.insert(layout, for: row, cost: 64 + text.utf16.count * 2)
            return layout
        }
    }

    /// Called after `CodeBlockDocument.reset(to:)`: drops every cached line
    /// and recomputes the width estimate.
    public func documentDidReset() {
        cache.removeAll()
        maxCharacterCount = document.lines.map { $0.utf16.count }.max() ?? 0
    }

    /// Applies a document append: drops the cached layout for the extended
    /// line only, and updates the width estimate from the touched rows.
    public func apply(_ delta: CodeLineDelta) {
        RenderSignposts.code.emitEvent("code.append")
        if let modified = delta.modifiedLine {
            cache.remove(modified)
            maxCharacterCount = max(maxCharacterCount, document.line(at: modified).utf16.count)
        }
        for row in delta.appendedLines {
            maxCharacterCount = max(maxCharacterCount, document.line(at: row).utf16.count)
        }
    }

    /// For tests and telemetry.
    var cachedLineCount: Int { cache.count }
}
