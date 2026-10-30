import AppKit

/// A reply's text laid out once and kept, so a streaming delta lays out only
/// what changed. It answers the row's height and where its code cards go.
///
/// The label draws its text through AppKit's string drawing, which lays out
/// with a TextKit 1 stack of its own, from scratch on every measurement.
/// This stack is set up the way string drawing sets up its own: no font
/// leading, no line fragment padding, the 10.4 typesetter, the label's font
/// where the text has none, and two pieces with no public API, below. With
/// all of them its numbers are the label's numbers, and ReplyTextLayoutTests
/// holds the two to exact agreement over a long reply. Without the private
/// pieces the row measures with the label's cell, as it did before.
@MainActor
final class ReplyTextLayout {
    /// String drawing's own text storage class. The layout manager sizes a
    /// line differently when its storage is this class: a wrapped line of
    /// inline code after a code block is as tall as the paragraph's text
    /// (30 points at 26-point text) rather than the code font's 28. A plain
    /// NSTextStorage got that one line in 744 checks wrong.
    private static let stringDrawingStorage = NSClassFromString("NSStringDrawingTextStorage") as? NSTextStorage.Type
    /// The layout manager switch that sizes lines from the font's original
    /// metrics, as string drawing does: an SF Mono line at 11.7 points is 14
    /// points tall, not 13. Without it every code line drifts a point.
    private static let originalMetricsSwitch = NSSelectorFromString("setAllowsOriginalFontMetricsOverride:")

    private let storage = (stringDrawingStorage ?? NSTextStorage.self).init()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()

    /// Whether this layout measures what the label draws. When it doesn't,
    /// the row measures with the label's cell instead.
    let matchesLabel: Bool

    init() {
        manager.usesFontLeading = false
        manager.typesetterBehavior = .behavior_10_4
        manager.allowsNonContiguousLayout = false
        matchesLabel = Self.stringDrawingStorage != nil && manager.responds(to: Self.originalMetricsSwitch)
        if matchesLabel { manager.setValue(true, forKey: "allowsOriginalFontMetricsOverride") }
        container.lineFragmentPadding = 0
        container.size = NSSize(width: 0, height: Self.unlimited)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    /// Taller than any reply.
    private static let unlimited: CGFloat = 10_000_000

    /// Takes the label's new text. Only the part after `unchangedLength`
    /// (UTF-16 offsets) is replaced, so layout before it is kept.
    func setText(_ text: NSAttributedString, unchangedLength: Int, font: NSFont) {
        let keep = min(unchangedLength, storage.length, text.length)
        let tail = NSMutableAttributedString(
            attributedString: text.attributedSubstring(from: NSRange(location: keep, length: text.length - keep))
        )
        // The label gives text without a font its own font.
        tail.enumerateAttribute(.font, in: NSRange(location: 0, length: tail.length)) { value, range, _ in
            if value == nil { tail.addAttribute(.font, value: font, range: range) }
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: keep, length: storage.length - keep), with: tail)
        storage.endEditing()
    }

    /// The text as laid out, for tests.
    var text: NSAttributedString { NSAttributedString(attributedString: storage) }

    /// Forgets the text, for a new font or a cleared row.
    func reset() {
        storage.setAttributedString(NSAttributedString())
    }

    private func lay(width: CGFloat) {
        if container.size.width != width {
            container.size = NSSize(width: width, height: Self.unlimited)
        }
        manager.ensureLayout(for: container)
    }

    /// The text's height when it wraps at `width`, as the label measures it.
    func height(width: CGFloat) -> CGFloat {
        lay(width: width)
        return manager.usedRect(for: container).height
    }

    /// The lines holding `range`, in the label's flipped coordinates: across
    /// the whole width from the top of its first line to the bottom of its
    /// last, or just around its glyphs when `tight`. Nil for an empty or
    /// out-of-date range.
    func lineRect(of range: NSRange, width: CGFloat, tight: Bool = false) -> NSRect? {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        lay(width: width)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        if tight { return manager.boundingRect(forGlyphRange: glyphs, in: container) }
        let first = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = manager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return NSRect(x: 0, y: first.minY, width: container.size.width, height: last.maxY - first.minY)
    }

    /// The rect the text block holding `range` takes, margins included, in
    /// the label's flipped coordinates. Its bottom is what the label measures
    /// for the text through the block. Nil when `range` is not in a block.
    func blockRect(of range: NSRange, width: CGFloat) -> NSRect? {
        guard range.length > 0, NSMaxRange(range) <= storage.length,
              let block = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first
        else { return nil }
        lay(width: width)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        // The layout manager keeps a block's own rect only until the next
        // edit, so the block's extent comes from its first and last lines,
        // which sit inside its margin, border and padding. The last line's
        // used rect leaves out the spacing after its paragraph, as the
        // label's measurement of the text through the block does.
        let first = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = manager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        func inset(_ edge: NSRectEdge) -> CGFloat {
            [NSTextBlock.Layer.margin, .border, .padding].reduce(0) { $0 + block.width(for: $1, edge: edge) }
        }
        let top = first.minY - inset(.minY)
        let bottom = last.maxY + inset(.maxY)
        return NSRect(x: 0, y: top, width: container.size.width, height: bottom - top)
    }
}
