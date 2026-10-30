import AppKit
import Testing
@testable import ClaudeNative

/// A code line too long for the card wraps under its own indentation plus
/// one more indent, as Xcode wraps by default, rather than back at the
/// card's left edge where it reads as a new, unindented line.
@MainActor
struct CodeWrapIndentTests {
    @Test func wrappedCodeLinesHangUnderTheirIndentation() throws {
        let markdown = StreamingMarkdown()
        markdown.bodySize = 13
        let rendered = markdown.render(["```swift", "let rivers = [", "    River(name: \"Danube\")", "]", "```"].joined(separator: "\n"))
        let text = rendered.string as NSString
        func style(at line: String) throws -> NSParagraphStyle {
            let location = text.range(of: line).location
            #expect(location != NSNotFound, "\(line)")
            return try #require(rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let font = try #require(rendered.attribute(.font, at: text.range(of: "let rivers").location, effectiveRange: nil) as? NSFont)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let top = try style(at: "let rivers")
        let nested = try style(at: "River(name")
        #expect(top.firstLineHeadIndent == 0)
        #expect(nested.firstLineHeadIndent == 0)
        #expect(abs(top.headIndent - 4 * space) < 0.5)
        #expect(abs(nested.headIndent - 8 * space) < 0.5)
        // The card still spans the block.
        #expect(nested.textBlocks.count == 1)
    }

    /// Deep indentation can't squeeze the wrapped part to a sliver, even at
    /// the largest text size: the indent is capped in points, tabs counted
    /// as the four spaces they draw as.
    @Test(arguments: [13.0, 39.0])
    func deepIndentationIsCappedInPoints(bodySize: Double) throws {
        let markdown = StreamingMarkdown()
        markdown.bodySize = bodySize
        let deep = String(repeating: "\t", count: 16) + "deeplyNested()"
        let rendered = markdown.render(["```swift", deep, "```"].joined(separator: "\n"))
        let location = (rendered.string as NSString).range(of: "deeplyNested").location
        let style = try #require(rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent <= CodeWrap.maxIndentWidth + 0.5, "\(style.headIndent) at \(bodySize) pt")
        #expect(style.headIndent > 0)
    }
}
