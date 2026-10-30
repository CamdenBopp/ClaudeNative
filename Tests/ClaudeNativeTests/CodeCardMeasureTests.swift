import AppKit
import Testing
@testable import ClaudeNative

/// A code card's height comes from the label cell's measurement of its block
/// alone. String drawing lays out a lone line on a quick path that ignores
/// text blocks, so a one-line block measured by itself came back as a bare
/// line, without the padding and margins the label draws around it, and its
/// card collapsed to a stray rule under the code.
@MainActor
struct CodeCardMeasureTests {
    static func label(fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.font = .systemFont(ofSize: fontSize)
        return label
    }

    /// The block's margin, border and padding above and below its text.
    static func verticalInsets(of block: NSRange, in text: NSAttributedString) -> CGFloat {
        guard let textBlock = (text.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.first else { return 0 }
        let layers: [NSTextBlock.Layer] = [.margin, .border, .padding]
        return layers.reduce(0) { $0 + textBlock.width(for: $1, edge: .minY) + textBlock.width(for: $1, edge: .maxY) }
    }

    @Test(arguments: [(13.0, 420.0), (17.0, 517.0), (22.0, 300.0)])
    func everyCodeBlockMeasuresWithItsPaddingAndMargins(fontSize: Double, width: Double) {
        let label = Self.label(fontSize: fontSize)
        let markdown = StreamingMarkdown()
        markdown.bodySize = fontSize
        let reply = [
            "Run it:", "", "```sh", "swift test --filter CacheTests", "```", "",
            "A wrapped one-liner:", "", "```text",
            "a single code line long enough to wrap inside its card at every width this test uses, and then some more words so it wraps more than once",
            "```", "", "And two lines:", "", "```swift", "let x = 1", "let y = 2", "```", "", "Done.",
        ].joined(separator: "\n")
        let rendered = markdown.render(reply)
        label.attributedStringValue = rendered
        let blocks = MessageRowView.codeBlocks(in: rendered)
        #expect(blocks.count == 3)
        let cell = label.cell!.copy() as! NSTextFieldCell
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        var quickPaths = 0
        for block in blocks {
            let measured = MessageRowView.cellMeasure(block: block, in: rendered, cell: cell, font: label.font!, width: width)
            // The block by itself, as the row measured it before.
            let reference = label.cell!.copy() as! NSTextFieldCell
            reference.attributedStringValue = rendered.attributedSubstring(from: block)
            let bare = reference.cellSize(forBounds: bounds).height
            let insets = Self.verticalInsets(of: block, in: rendered)
            // A block that fits one line comes back without its insets; any
            // other already came back with them.
            let expected = bare < insets ? bare + insets : bare
            if bare < insets { quickPaths += 1 }
            let code = (rendered.string as NSString).substring(with: block)
            #expect(measured.alone == expected, "\(code): \(measured.alone) vs \(expected)")
            #expect(measured.alone > insets, "\(code)")
        }
        // The narrow case wraps every block, so only the wider ones have a
        // block on the quick path.
        #expect(quickPaths == (width < 400 ? 0 : 1))
    }
}
