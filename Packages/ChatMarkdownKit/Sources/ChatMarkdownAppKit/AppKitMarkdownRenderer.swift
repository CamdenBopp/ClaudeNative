// AppKit projection of the semantic block model: one NSAttributedString for a
// whole message, suitable for a plain NSTextField/NSTextView. This is the
// low-fidelity sibling of ChatMarkdownUI — no custom drawing, no per-block
// views, no viewport code layout; it trades all of that for drop-in use in an
// existing AppKit label. Parsing still comes from StreamingMessageAssembler,
// so appends remain incremental; only the attributed-string build is per-call.
#if canImport(AppKit)
import AppKit
import ChatMarkdownCore

/// Typography + palette for the AppKit renderer. Mirrors TextTheme's metric
/// names where they overlap, but carries real NSColor/NSFont values because —
/// unlike the CoreText pipeline, which draws colors from the graphics context —
/// an attributed string handed to AppKit controls must embed its colors.
public struct MarkdownRenderStyle {
    public var bodySize: CGFloat = 13
    /// Multipliers over `bodySize` for heading levels 1–6.
    public var headingScales: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.0, 0.9]
    /// Vertical gap after each top-level block (paragraphSpacing).
    public var blockSpacing: CGFloat = 6
    public var listIndent: CGFloat = 14
    public var quoteIndent: CGFloat = 12

    public var bodyColor: NSColor = .labelColor
    public var secondaryColor: NSColor = .secondaryLabelColor
    public var linkColor: NSColor = .linkColor
    public var codeBackground: NSColor = NSColor.labelColor.withAlphaComponent(0.08)

    public init() {}
}

/// Blocks → NSAttributedString. MainActor because AppKit consumers live there
/// and it keeps the font cache trivially safe under strict concurrency.
@MainActor
public enum AppKitMarkdownRenderer {
    public static func attributedString(
        for document: MarkdownDocument,
        style: MarkdownRenderStyle = MarkdownRenderStyle()
    ) -> NSAttributedString {
        attributedString(for: document.blocks.map(\.content), style: style)
    }

    public static func attributedString(
        for blocks: [BlockContent],
        style: MarkdownRenderStyle = MarkdownRenderStyle()
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let context = RenderContext(style: style, cachesAttributes: benefitsFromCaching(blocks))
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(render(block, context: context, indent: 0, colorOverride: nil))
        }
        return output
    }

    private static func benefitsFromCaching(_ blocks: [BlockContent]) -> Bool {
        if blocks.count > 1 { return true }
        switch blocks.first {
        case .paragraph(let text), .heading(_, let text): return text.runs.count >= 16
        case .blockQuote, .unorderedList, .orderedList: return true
        default: return false
        }
    }

    // MARK: - Blocks

    private static func render(
        _ block: BlockContent,
        context: RenderContext,
        indent: CGFloat,
        colorOverride: NSColor?
    ) -> NSAttributedString {
        let style = context.style
        switch block {
        case .paragraph(let text):
            return inline(text, context: context, paragraph: context.paragraphStyle(indent: indent),
                          color: colorOverride ?? style.bodyColor)

        case .heading(let level, let text):
            let scale = style.headingScales[min(max(level, 1), style.headingScales.count) - 1]
            return inline(text, context: context, paragraph: context.paragraphStyle(indent: indent),
                          color: colorOverride ?? style.bodyColor,
                          roleAttributes: .bold, sizeMultiplier: scale)

        case .codeBlock(let code):
            var body = code.rawText
            if body.hasSuffix("\n") { body.removeLast() }
            let paragraph = context.paragraphStyle(indent: indent)
            return NSAttributedString(string: body, attributes: [
                .font: font(for: .code, style: style),
                .foregroundColor: colorOverride ?? style.bodyColor,
                .backgroundColor: style.codeBackground,
                .paragraphStyle: paragraph,
            ])

        case .blockQuote(let children):
            // Indented, secondary color — the label-only stand-in for a quote bar.
            return renderChildren(children, context: context,
                                  indent: indent + style.quoteIndent,
                                  colorOverride: style.secondaryColor)

        case .unorderedList(let items):
            return renderList(items, context: context, indent: indent,
                              colorOverride: colorOverride) { _ in "•  " }

        case .orderedList(let start, let items):
            return renderList(items, context: context, indent: indent,
                              colorOverride: colorOverride) { "\(start + $0).  " }

        case .table(let table):
            return renderTable(table, context: context, indent: indent, colorOverride: colorOverride)

        case .thematicBreak:
            return NSAttributedString(string: "⎯⎯⎯⎯⎯", attributes: [
                .font: font(for: [], style: style),
                .foregroundColor: style.secondaryColor,
                .paragraphStyle: context.paragraphStyle(indent: indent),
            ])

        case .htmlBlock(let literal):
            // Same policy as everywhere else in the library: literal, never interpreted.
            return NSAttributedString(string: literal.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [
                .font: font(for: .code, style: style),
                .foregroundColor: colorOverride ?? style.secondaryColor,
                .paragraphStyle: context.paragraphStyle(indent: indent),
            ])
        }
    }

    private static func renderChildren(
        _ children: [BlockContent],
        context: RenderContext,
        indent: CGFloat,
        colorOverride: NSColor?
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, child) in children.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(render(child, context: context, indent: indent, colorOverride: colorOverride))
        }
        return output
    }

    private static func renderList(
        _ items: [[BlockContent]],
        context: RenderContext,
        indent: CGFloat,
        colorOverride: NSColor?,
        marker: (Int) -> String
    ) -> NSAttributedString {
        let style = context.style
        let output = NSMutableAttributedString()
        let itemIndent = indent + style.listIndent
        for (index, item) in items.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            // Marker hangs at the item's first line; wrapped lines and any
            // nested blocks align behind it (firstLineHeadIndent < headIndent).
            let markerString = NSAttributedString(string: marker(index), attributes: [
                .font: font(for: [], style: style),
                .foregroundColor: colorOverride ?? style.secondaryColor,
            ])
            let body = renderChildren(item, context: context, indent: itemIndent, colorOverride: colorOverride)
            let line = NSMutableAttributedString()
            line.append(markerString)
            line.append(body)
            // Re-stamp the first paragraph so the marker outdents.
            if body.length > 0, let bodyParagraph = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle,
               let hanging = bodyParagraph.mutableCopy() as? NSMutableParagraphStyle {
                hanging.firstLineHeadIndent = indent
                let firstParagraphEnd = (line.string as NSString).range(of: "\n").location
                let length = firstParagraphEnd == NSNotFound ? line.length : firstParagraphEnd
                line.addAttribute(.paragraphStyle, value: hanging, range: NSRange(location: 0, length: length))
            }
            output.append(line)
        }
        return output
    }

    private static func renderTable(
        _ table: TableContent,
        context: RenderContext,
        indent: CGFloat,
        colorOverride: NSColor?
    ) -> NSAttributedString {
        let style = context.style
        // Label-only fidelity: monospaced rows with column separators.
        let output = NSMutableAttributedString()
        let paragraph = context.paragraphStyle(indent: indent)

        func row(_ cells: [InlineText], bold: Bool) -> NSAttributedString {
            let text = cells.map(\.plainText).joined(separator: "  |  ")
            return NSAttributedString(string: text, attributes: [
                .font: font(for: bold ? [.code, .bold] : .code, style: style),
                .foregroundColor: colorOverride ?? style.bodyColor,
                .paragraphStyle: paragraph,
            ])
        }

        output.append(row(table.head, bold: true))
        for cells in table.rows {
            output.append(NSAttributedString(string: "\n"))
            output.append(row(cells, bold: false))
        }
        return output
    }

    // MARK: - Inlines

    private static func inline(
        _ text: InlineText,
        context: RenderContext,
        paragraph: NSParagraphStyle,
        color: NSColor,
        roleAttributes: InlineRun.Attributes = [],
        sizeMultiplier: CGFloat = 1
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in text.runs {
            let merged = run.attributes.union(roleAttributes)
            let attributes = context.attributes(for: merged, paragraph: paragraph, color: color,
                                                 sizeMultiplier: sizeMultiplier, destination: run.linkDestination)
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return output
    }

    // These caches live for one projection only. They avoid rebuilding identical
    // paragraph styles and attribute dictionaries across large documents without
    // retaining a host's palette, metrics, or link destinations between calls.
    @MainActor private final class RenderContext {
        let style: MarkdownRenderStyle
        private let cachesAttributes: Bool
        private var paragraphs: [CGFloat: NSParagraphStyle] = [:]
        private var inlineAttributes: [AttributeKey: [NSAttributedString.Key: Any]] = [:]

        private struct AttributeKey: Hashable {
            let attributes: InlineRun.Attributes
            let indent: CGFloat
            let color: NSColor
            let sizeMultiplier: CGFloat
            let destination: String?
        }

        init(style: MarkdownRenderStyle, cachesAttributes: Bool) {
            self.style = style
            self.cachesAttributes = cachesAttributes
        }

        func paragraphStyle(indent: CGFloat) -> NSParagraphStyle {
            if cachesAttributes, let cached = paragraphs[indent] { return cached }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = style.blockSpacing
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            // Rendered strings expose their attributes to callers. Store an
            // immutable style so changing one paragraph cannot change its peers.
            let result = paragraph.copy() as! NSParagraphStyle
            if cachesAttributes { paragraphs[indent] = result }
            return result
        }

        func attributes(for merged: InlineRun.Attributes, paragraph: NSParagraphStyle,
                        color: NSColor, sizeMultiplier: CGFloat, destination: String?) -> [NSAttributedString.Key: Any] {
            let key = cachesAttributes ? AttributeKey(attributes: merged, indent: paragraph.headIndent, color: color,
                                                      sizeMultiplier: sizeMultiplier, destination: destination) : nil
            if let key, let cached = inlineAttributes[key] { return cached }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: merged, style: style, sizeMultiplier: sizeMultiplier),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if merged.contains(.code) {
                attributes[.backgroundColor] = style.codeBackground
            }
            if merged.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let destination {
                attributes[.foregroundColor] = style.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                // Destinations can be partial or bogus mid-stream; only a
                // well-formed http(s) URL becomes an activatable link.
                if let url = URL(string: destination), url.scheme == "http" || url.scheme == "https" {
                    attributes[.link] = url
                }
            }
            if let key { inlineAttributes[key] = attributes }
            return attributes
        }
    }

    // MARK: - Styling primitives

    /// Same rationale as ChatTextLayout's FontCache: streaming re-styles the
    /// tail block on every token while the distinct font set stays tiny.
    private static var fontCache: [FontKey: NSFont] = [:]

    private struct FontKey: Hashable {
        let attributes: InlineRun.Attributes
        let size: CGFloat
    }

    private static func font(
        for attributes: InlineRun.Attributes,
        style: MarkdownRenderStyle,
        sizeMultiplier: CGFloat = 1
    ) -> NSFont {
        let size = style.bodySize * sizeMultiplier
        let key = FontKey(attributes: attributes.intersection([.bold, .italic, .code]), size: size)
        if let cached = fontCache[key] { return cached }

        var font: NSFont
        if attributes.contains(.code) {
            font = .monospacedSystemFont(ofSize: size * 0.9, weight: attributes.contains(.bold) ? .semibold : .regular)
        } else {
            font = .systemFont(ofSize: size, weight: attributes.contains(.bold) ? .semibold : .regular)
        }
        if attributes.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        fontCache[key] = font
        return font
    }
}
#endif
