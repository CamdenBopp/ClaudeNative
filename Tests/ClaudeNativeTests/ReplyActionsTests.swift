import AppKit
@testable import ClaudeNativeCore
import Testing
@testable import ClaudeNative

/// A reply's links and code blocks are also offered as the actions of the
/// reply as a whole.
@MainActor
struct ReplyActionsTests {
    static let reply = """
    See [the Swift site](https://swift.org) and <https://example.com/docs>, \
    not [a local file](file:///etc/hosts).

    ```swift
    let a = 1
    ```

    Then:

    ```sh
    swift test
    ```
    """

    func actionNames(of row: MessageRowView) -> [String] {
        (row.accessibilityCustomActions() ?? []).map(\.name)
    }

    @Test func aFinishedReplyOffersItsLinksAndCodeBlocks() throws {
        let row = MessageRowView(entry: TranscriptEntry(id: "r", kind: .assistant, text: Self.reply), base: nil, textScale: 1)
        row.finishMarkdown()
        let names = actionNames(of: row)
        #expect(names.contains("Open link: the Swift site"))
        #expect(names.contains { $0.hasPrefix("Open link:") && $0.contains("example.com") })
        #expect(!names.contains { $0.contains("local file") || $0.contains("hosts") })
        #expect(names.contains("Copy code block 1 of 2"))
        #expect(names.contains("Copy code block 2 of 2"))
    }

    /// Marking a finished reply and removing the mark, or the row starting
    /// to continue a turn (Show Earlier Messages), redrew it as still
    /// streaming: its link and code actions went until something else
    /// finished it again.
    @Test func markingOrRegroupingAFinishedReplyKeepsItsActions() throws {
        let row = MessageRowView(entry: TranscriptEntry(id: "r", kind: .assistant, text: Self.reply), base: nil, textScale: 1)
        row.finishMarkdown()
        row.isMarked = true
        row.isMarked = false
        #expect(actionNames(of: row).contains("Copy code block 1 of 2"))
        #expect(actionNames(of: row).contains("Open link: the Swift site"))
        row.continuesTurn = true
        row.continuesTurn = false
        #expect(actionNames(of: row).contains("Copy code block 2 of 2"))
    }

    @Test func copyCodeBlockCopiesJustTheCode() throws {
        let row = MessageRowView(entry: TranscriptEntry(id: "r", kind: .assistant, text: Self.reply), base: nil, textScale: 1)
        row.finishMarkdown()
        let board = NSPasteboard.withUniqueName()
        Clipboard.board = board
        defer { Clipboard.board = .general; board.releaseGlobally() }
        let copy = try #require(row.accessibilityCustomActions()?.first { $0.name == "Copy code block 2 of 2" })
        _ = copy.handler?()
        #expect(board.string(forType: .string) == "swift test")
    }

    @Test func aStreamingReplyHasNoBlockActionsYet() {
        let row = MessageRowView(entry: TranscriptEntry(id: "r", kind: .assistant, text: Self.reply), base: nil, textScale: 1)
        #expect(!actionNames(of: row).contains { $0.hasPrefix("Copy code block") || $0.hasPrefix("Open link") })
    }
}
