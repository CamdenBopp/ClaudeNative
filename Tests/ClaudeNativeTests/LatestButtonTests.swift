import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Reading earlier messages, a Latest Message button shows over the end of
/// the conversation and does what Go to Latest Message does. At the end
/// it's hidden and out of the accessibility tree.
@MainActor
struct LatestButtonTests {
    static let entries = (0..<40).map { index in
        TranscriptEntry(id: "message:\(index)", kind: index.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \(index). A paragraph of conversation to scroll through.")
    }

    @MainActor final class Hosted {
        let window: NSWindow
        let host: NSHostingView<TranscriptView>

        init() {
            (window, host) = AccessibilityHost.window(
                hosting: TranscriptView(transcript: Transcript(restoring: LatestButtonTests.entries), revision: 0,
                                        workingDirectory: nil, isWorking: false),
                size: NSSize(width: 700, height: 400)
            )
        }

        var scrollView: NSScrollView {
            get throws { try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" }) }
        }

        var button: NSButton {
            get throws { try #require(MessageNavigationHostedTests.Hosted.views(NSButton.self, in: window.contentView).first { $0.title == "Latest Message" }) }
        }

        /// The button as an assistive app finds it, if it does.
        var exposed: [AnyObject] {
            AccessibilityHost.descendants(of: window).filter {
                AccessibilityHost.role($0) == .button && ($0.accessibilityTitle?() ?? nil) == "Latest Message"
            }
        }

        func scrollToTop() throws {
            let scrollView = try scrollView
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            AccessibilityHost.settle(host)
        }
    }

    @Test func atTheEndTheButtonIsHiddenAndOutOfTheTree() throws {
        let hosted = Hosted()
        defer { hosted.window.close() }
        #expect(try hosted.scrollView.isNearBottom)
        #expect(try hosted.button.isHidden)
        #expect(hosted.exposed.isEmpty)
    }

    @Test func readingEarlierMessagesShowsItWithOneName() throws {
        let hosted = Hosted()
        defer { hosted.window.close() }
        try hosted.scrollToTop()
        #expect(!(try hosted.button.isHidden))
        // What's drawn is what VoiceOver and Voice Control call it.
        #expect(hosted.exposed.count == 1)
    }

    @Test(arguments: [420.0, 700.0, 1000.0])
    func theButtonSitsAtTheBottomCenterWithoutTruncatingItsTitle(width: Double) throws {
        let hosted = Hosted()
        defer { hosted.window.close() }
        hosted.window.setContentSize(NSSize(width: width, height: 400))
        try hosted.scrollToTop()
        let scroll = try hosted.scrollView
        let button = try hosted.button
        #expect(abs(button.frame.midX - scroll.bounds.midX) < 1)
        let bottomGap = scroll.isFlipped
            ? scroll.bounds.maxY - button.frame.maxY
            : button.frame.minY - scroll.bounds.minY
        #expect(abs(bottomGap - Theme.Spacing.medium) < 1)
        #expect(button.frame.width >= button.intrinsicContentSize.width)
    }

    @Test func pressingItGoesToTheLatestMessage() throws {
        let hosted = Hosted()
        defer { hosted.window.close() }
        try hosted.scrollToTop()
        try hosted.button.performClick(nil)
        AccessibilityHost.settle(hosted.host)
        let scrollView = try hosted.scrollView
        let document = try #require(scrollView.documentView)
        let last = try #require(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: hosted.window.contentView).first { $0.entry?.id == "message:39" })
        let frame = document.convert(last.bounds, from: last)
        // On screen, as Go to Latest Message leaves it.
        #expect(scrollView.contentView.documentVisibleRect.intersects(frame))
        #expect(scrollView.isNearBottom)
        #expect(try hosted.button.isHidden)
    }

    /// Partway down a long last reply, the view's top is inside the latest
    /// message, and Go to Latest Message said "Last message." and moved
    /// nothing; under VoiceOver the cursor stayed on the button (live).
    /// The button goes there whatever is at the top of the view.
    @Test func pressingItInsideALongLastReplyStillGoesThere() throws {
        let long = String(repeating: "A long last reply that runs on and on. ", count: 120)
        let entries = [
            TranscriptEntry(id: "you", kind: .user, text: "Write something long."),
            TranscriptEntry(id: "reply", kind: .assistant, text: long),
        ]
        let (window, host) = AccessibilityHost.window(
            hosting: TranscriptView(transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false),
            size: NSSize(width: 700, height: 400)
        )
        defer { window.close() }
        let scrollView = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" })
        let reply = try #require(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: window.contentView).first { $0.entry?.id == "reply" })
        let document = try #require(scrollView.documentView)
        // A third of the way into the reply.
        let frame = document.convert(reply.bounds, from: reply)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: frame.minY + frame.height / 3))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        AccessibilityHost.settle(host)
        let button = try #require(MessageNavigationHostedTests.Hosted.views(NSButton.self, in: window.contentView).first { $0.title == "Latest Message" })
        #expect(!button.isHidden)
        button.performClick(nil)
        AccessibilityHost.settle(host)
        #expect(scrollView.isNearBottom)
        #expect((window.firstResponder as? MessageRowView)?.entry?.id == "reply")
    }

    /// The button goes to the end whatever is there: with only tool rows
    /// shown it did nothing, and with tools after the latest reply focus
    /// went to the reply, above the end.
    @Test(arguments: [false, true])
    func pressingItGoesToTheLastRowWhateverItIs(withReply: Bool) throws {
        var entries: [TranscriptEntry] = withReply
            ? [TranscriptEntry(id: "you", kind: .user, text: "Look around."), TranscriptEntry(id: "reply", kind: .assistant, text: "Looking.")]
            : []
        for index in 0..<30 {
            entries.append(TranscriptEntry(id: "tool:\(index)", kind: .tool(name: "Bash", status: .succeeded), text: "Bash: ls \(index)"))
        }
        let (window, host) = AccessibilityHost.window(
            hosting: TranscriptView(transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false),
            size: NSSize(width: 700, height: 300)
        )
        defer { window.close() }
        let scrollView = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" })
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        AccessibilityHost.settle(host)
        let button = try #require(MessageNavigationHostedTests.Hosted.views(NSButton.self, in: window.contentView).first { $0.title == "Latest Message" })
        button.performClick(nil)
        AccessibilityHost.settle(host)
        #expect(scrollView.isNearBottom)
        #expect((window.firstResponder as? MessageRowView)?.entry?.id == "tool:29")
    }
}
