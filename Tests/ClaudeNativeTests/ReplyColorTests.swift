import AppKit
import Testing
@testable import ClaudeNative

/// The colors a reply is drawn in come from Theme, which measures them,
/// not from the renderer's system defaults.
@MainActor
struct ReplyColorTests {
    static func color(of substring: String, in reply: String) throws -> NSColor? {
        let markdown = StreamingMarkdown()
        let rendered = markdown.render(reply)
        let range = (rendered.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound, "\(substring) not in \(rendered.string)")
        return rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    /// List numbers and quotes were the system secondary label color, 50%
    /// black in light: list numbers measured 3.07:1 on screen.
    @Test func listMarkersAndQuotesUseTheQuietLabel() throws {
        #expect(try Self.color(of: "1.", in: "1. one\n2. two\n") == Theme.quietLabel)
        #expect(try Self.color(of: "quoted", in: "> quoted words\n") == Theme.quietLabel)
    }

    @Test func linksUseTheLinkColor() throws {
        #expect(try Self.color(of: "Swift", in: "See [Swift](https://swift.org).\n") == Theme.linkText)
    }
}
