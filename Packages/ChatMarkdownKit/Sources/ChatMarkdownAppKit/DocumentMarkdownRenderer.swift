#if canImport(AppKit)
import AppKit
import ChatMarkdownCore

/// Complete Notes typography. This deliberately has no bubble, sender inset,
/// maximum chat width, streaming cursor, or auto-follow behavior.
@MainActor public enum DocumentMarkdownRenderer {
    public static var style: MarkdownRenderStyle {
        var value = MarkdownRenderStyle()
        value.bodySize = 16
        value.blockSpacing = 12
        value.listIndent = 22
        value.quoteIndent = 20
        return value
    }

    public static func attributedString(for document: MarkdownDocument) -> NSAttributedString {
        AppKitMarkdownRenderer.attributedString(for: document, style: style)
    }

    public static func attributedString(for block: MarkdownBlock) -> NSAttributedString {
        AppKitMarkdownRenderer.attributedString(for: [block.content], style: style)
    }
}
#endif
