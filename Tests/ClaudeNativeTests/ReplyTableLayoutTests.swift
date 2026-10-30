import AppKit
import Testing
@testable import ClaudeNative

@MainActor
struct ReplyTableLayoutTests {
    static let markdown = """
    | Control | Shortcut |
    | --- | --- |
    | Search conversations | Command-F |
    | Show files | Shift-Command-F |
    """

    /// A table used to be monospaced text with pipes: columns moved on
    /// every row, and a narrow window wrapped a row across both columns.
    @Test func cellsUseARealTableThatKeepsItsColumnsWhenTheyWrap() throws {
        let renderer = StreamingMarkdown()
        _ = renderer.render(Self.markdown)
        let text = try #require(renderer.finish())
        #expect(!text.string.contains("|"))
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: 10_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let ns = text.string as NSString
        func frame(_ words: String) throws -> NSRect {
            let range = ns.range(of: words)
            try #require(range.location != NSNotFound)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        let first = try frame("Command-F")
        let second = try frame("Shift-Command-F")
        #expect(abs(first.minX - second.minX) < 1)
        #expect(first.maxX <= 300 && second.maxX <= 300)
        #expect(second.minY > first.minY)
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.textBlocks.first is NSTextTableBlock)
    }
}
