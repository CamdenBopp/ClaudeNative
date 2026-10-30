import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A long saved conversation opens on its latest page, with Show Earlier
/// Messages above it, so opening one costs the same however long it ran.
@MainActor
struct TranscriptPagingTests {
    static let page = TranscriptLayout.pageSize

    /// `count` entries, your message then Claude's reply, in turn.
    static func entries(_ count: Int) -> [TranscriptEntry] {
        (0..<count).map { TranscriptEntry(id: "e\($0)", kind: $0.isMultiple(of: 2) ? .user : .assistant, text: "Message \($0)") }
    }

    @MainActor final class Hosted {
        let window: NSWindow
        let host: NSHostingView<TranscriptView>
        let navigator = MessageNavigator()

        init(_ entries: [TranscriptEntry]) {
            (window, host) = AccessibilityHost.window(hosting: Self.view(entries, navigator: navigator), size: NSSize(width: 600, height: 300))
        }

        static func view(_ entries: [TranscriptEntry], revision: Int = 0, navigator: MessageNavigator) -> TranscriptView {
            TranscriptView(transcript: Transcript(restoring: entries), revision: revision, workingDirectory: nil, isWorking: false, navigator: navigator)
        }

        func show(_ entries: [TranscriptEntry], revision: Int) {
            host.rootView = Self.view(entries, revision: revision, navigator: navigator)
            AccessibilityHost.settle(window.contentView!)
        }

        var stack: NSStackView {
            get throws { try #require(MessageNavigationHostedTests.Hosted.views(NSStackView.self, in: window.contentView).first) }
        }

        /// The rows in the order they're shown.
        var rows: [MessageRowView] {
            get throws { try stack.arrangedSubviews.compactMap { $0 as? MessageRowView } }
        }

        var button: NSButton? {
            try? stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Show Earlier Messages" }
        }

        var scrollView: NSScrollView {
            get throws { try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" }) }
        }

        /// Where `row` sits relative to the top of what's shown.
        func onScreenY(of row: NSView) throws -> CGFloat {
            let scrollView = try scrollView
            let document = try #require(scrollView.documentView)
            return document.convert(row.bounds, from: row).minY - scrollView.contentView.bounds.minY
        }
    }

    @Test func aLongConversationOpensOnItsLatestPage() throws {
        let entries = Self.entries(Self.page * 2 + 30)
        let hosted = Hosted(entries)
        let rows = try hosted.rows
        #expect(rows.count == Self.page)
        #expect(rows.last?.entry?.id == entries.last?.id)
        #expect(rows.first?.entry?.id == entries[entries.count - Self.page].id)
        let button = try #require(hosted.button)
        #expect(!button.isHidden)
    }

    @Test func aShortConversationShowsEverythingWithNoButton() throws {
        let entries = Self.entries(Self.page)
        let hosted = Hosted(entries)
        #expect(try hosted.rows.count == entries.count)
        #expect(hosted.button?.isHidden != false)
    }

    @Test func showEarlierAddsAPageAboveAndKeepsYourPlace() throws {
        let entries = Self.entries(Self.page * 2 + 30)
        let hosted = Hosted(entries)
        let content = try #require(hosted.window.contentView)
        let reading = try hosted.rows[0]
        reading.scrollToVisible(reading.bounds)
        AccessibilityHost.settle(content)
        let before = try hosted.onScreenY(of: reading)

        try #require(hosted.button).performClick(nil)
        AccessibilityHost.settle(content)

        let rows = try hosted.rows
        #expect(rows.count == Self.page * 2)
        #expect(rows.map { $0.entry?.id } == entries.suffix(Self.page * 2).map(\.id))
        // Focus goes to the message just before it, to read on backward.
        let previous = try #require(rows.firstIndex { $0 === reading }).advanced(by: -1)
        try #require(rows.indices.contains(previous))
        #expect(hosted.window.firstResponder === rows[previous])
        // That row is on screen: it was focused where nobody could see it.
        // The row you were reading moves down by no more than it to make
        // room, and stays in view.
        let focused = rows[previous]
        let shift = try hosted.onScreenY(of: reading) - before
        #expect(try hosted.onScreenY(of: focused) >= -1, "the focused row is above the view")
        #expect(shift >= -1 && shift <= focused.frame.height + TranscriptLayout.turnSpacing + 1, "moved \(shift)")
        #expect(hosted.button?.isHidden == false)
    }

    @Test func theLastPageHidesTheButton() throws {
        let entries = Self.entries(Self.page + 10)
        let hosted = Hosted(entries)
        try #require(hosted.button).performClick(nil)
        AccessibilityHost.settle(hosted.window.contentView!)
        #expect(try hosted.rows.map { $0.entry?.id } == entries.map(\.id))
        #expect(hosted.button?.isHidden == true)
    }

    @Test func previousMessageFromTheFirstShownCarriesOnIntoTheEarlierPage() throws {
        let entries = Self.entries(Self.page + 10)
        let hosted = Hosted(entries)
        let content = try #require(hosted.window.contentView)
        let first = try hosted.rows[0]
        first.scrollToVisible(first.bounds)
        AccessibilityHost.settle(content)
        hosted.navigator.perform(.previous)
        AccessibilityHost.settle(content)
        let rows = try hosted.rows
        #expect(rows.count == entries.count)
        let landed = try #require(rows.firstIndex { $0 === hosted.window.firstResponder })
        try #require(rows.indices.contains(landed + 1))
        #expect(rows[landed + 1] === first, "Go should land on the message before the first one shown")
    }

    /// A conversation that grows while it's open keeps every row it showed.
    @Test func aGrowingConversationKeepsEveryRow() throws {
        let entries = Self.entries(Self.page + 20)
        let hosted = Hosted(Array(entries.prefix(1)))
        hosted.show(entries, revision: 1)
        #expect(try hosted.rows.count == entries.count)
        #expect(hosted.button?.isHidden != false)
    }
}
