import Foundation
import CoreText
import ChatMarkdownCore

/// Custom attributed-string keys carried through layout for hit-testing and
/// the accessibility projection.
public enum CMKAttribute {
    /// Value: String — the raw link destination from the Markdown source.
    public static let linkDestination = NSAttributedString.Key("cmk.linkDestination")
}

public enum AttributedTextBuilder {
    /// Builds the CoreText-ready attributed string for one inline text.
    ///
    /// Uses CoreText attribute keys (not UIKit ones) so the same string works
    /// with CTFramesetter on every platform. Colors come from the drawing
    /// context (`kCTForegroundColorFromContext`) so a light/dark switch does
    /// not invalidate layout caches — geometry is color-independent.
    ///
    /// - Parameters:
    ///   - roleAttributes: attributes OR-ed into every run (e.g. `.bold` for
    ///     headings, `.code` for code-styled blocks).
    ///   - sizeMultiplier: font scale relative to the theme body size.
    // CF→NS key bridging is not free; these are touched for every run of
    // every re-styled block on every streamed token, so bridge once.
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let foregroundFromContextKey =
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    public static func makeAttributedString(
        _ text: InlineText,
        theme: TextTheme,
        roleAttributes: InlineRun.Attributes = [],
        sizeMultiplier: CGFloat = 1
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in text.runs {
            let merged = run.attributes.union(roleAttributes)
            var attributes: [NSAttributedString.Key: Any] = [:]
            attributes[Self.fontKey] = theme.font(for: merged, sizeMultiplier: sizeMultiplier)
            attributes[Self.foregroundFromContextKey] = true
            if let destination = run.linkDestination {
                attributes[CMKAttribute.linkDestination] = destination
                attributes[Self.underlineKey] = CTUnderlineStyle.single.rawValue
            }
            // Strikethrough has no CoreText draw support; a custom decoration
            // command is the planned path (same mechanism as quote bars).
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return output
    }
}
