import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Go > Previous Message, Next Message and Go to Latest Message on the real
/// TranscriptView, hosted in a window short enough that the conversation
/// scrolls.
@MainActor
struct MessageNavigationHostedTests {
    /// Turns of the real permission_allow capture, each with fresh ids, so
    /// the conversation is many screens long.
    static let turns = 8

    @MainActor
    final class Hosted {
        let window: NSWindow
        let navigator = MessageNavigator()
        let entries: [TranscriptEntry]

        init() throws {
            let turn = try Fixtures.replay("real_permission_allow", userText: "Create hello.txt").entries
            entries = (0..<MessageNavigationHostedTests.turns).flatMap { number in
                turn.map { TranscriptEntry(id: "\(number)-\($0.id)", kind: $0.kind, text: $0.text, toolInput: $0.toolInput) }
            }
            let view = TranscriptView(
                transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil,
                isWorking: false, navigator: navigator
            )
            (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 600, height: 300))
        }

        var scrollView: NSScrollView {
            get throws {
                try #require(Self.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" })
            }
        }

        var rows: [MessageRowView] { Self.views(MessageRowView.self, in: window.contentView) }

        /// What the conversation shows, in its own coordinates.
        func visible() throws -> NSRect { try scrollView.contentView.documentVisibleRect }

        func frame(of row: Int) throws -> NSRect {
            let document = try #require(try scrollView.documentView)
            return document.convert(rows[row].bounds, from: rows[row])
        }

        /// Whether the row starts at the top of the view, below the space
        /// above the conversation, or as near as the conversation scrolls:
        /// a row merely somewhere on screen doesn't count.
        func showsTop(of row: Int) throws -> Bool {
            let visible = try visible()
            let top = try frame(of: row).minY
            let document = try #require(try scrollView.documentView)
            let atBottom = visible.maxY >= document.bounds.maxY - Self.tolerance
            let onScreen = top >= visible.minY && top < visible.maxY
            return onScreen && (abs(top - Theme.Spacing.large - visible.minY) <= Self.tolerance || atBottom)
        }

        /// Layout rounds to whole points.
        static let tolerance: CGFloat = 1

        func go(_ move: TranscriptNavigation.MessageMove) {
            navigator.perform(move)
            AccessibilityHost.settle(window.contentView!)
        }

        func scroll(toY y: CGFloat) throws {
            let clip = try scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: y))
            try scrollView.reflectScrolledClipView(clip)
        }

        static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
            guard let view else { return [] }
            return view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + views(type, in: $0) }
        }
    }

    func isMessage(_ entry: TranscriptEntry) -> Bool { entry.kind == .user || entry.kind == .assistant }

    /// Go gives the message it lands on keyboard focus, which VoiceOver
    /// follows; at any other time a message doesn't take focus, so a click
    /// on one leaves focus in the message field.
    @Test func goFocusesTheMessageButAMessageOtherwiseDeclinesFocus() throws {
        let hosted = try Hosted()
        let last = try #require(hosted.entries.lastIndex(where: isMessage))
        let row = hosted.rows[last]
        #expect(!row.acceptsFirstResponder)
        // A click on the row: the window makes the clicked view first
        // responder only if it accepts that.
        let before = hosted.window.firstResponder
        let point = row.convert(NSPoint(x: row.bounds.maxX - 2, y: row.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) { hosted.window.sendEvent(event) }
        }
        #expect(hosted.window.firstResponder !== row)
        #expect(hosted.window.firstResponder === before)
        hosted.go(.latest)
        #expect(hosted.window.firstResponder === row)
        #expect(row.isAccessibilityFocused())
        #expect(!row.acceptsFirstResponder)
    }

    /// With keyboard navigation on, Tab stopped on the conversation's
    /// scroll bar between the sidebar and the message field.
    @Test func tabSkipsTheConversationScrollBar() throws {
        let hosted = try Hosted()
        let scroller = try #require(try hosted.scrollView.verticalScroller)
        #expect(scroller.refusesFirstResponder)
        #expect(!scroller.acceptsFirstResponder)
    }

    /// The message Go lands on shows the system focus ring around what it
    /// draws, so the move can be seen as well as heard.
    @Test func theMessageGoLandsOnShowsAFocusRing() throws {
        let hosted = try Hosted()
        let last = try #require(hosted.entries.lastIndex(where: isMessage))
        let row = hosted.rows[last]
        hosted.go(.latest)
        #expect(hosted.window.firstResponder === row)
        #expect(row.focusRingType != .none)
        let ring = row.focusRingMaskBounds
        #expect(!ring.isEmpty)
        // A reply's ring stands clear of its text on every side.
        #expect(ring.insetBy(dx: Theme.Spacing.small, dy: Theme.Spacing.xSmall).contains(row.bounds))
    }

    @Test func goToLatestScrollsTheLastMessageIntoView() throws {
        let hosted = try Hosted()
        #expect(hosted.rows.count == hosted.entries.count)
        try hosted.scroll(toY: 0)
        let last = try #require(hosted.entries.lastIndex(where: isMessage))
        #expect(try !hosted.showsTop(of: last))
        hosted.go(.latest)
        #expect(try hosted.showsTop(of: last))
    }

    @Test func nextAndPreviousStepThroughMessagesAndScrollEachIntoView() throws {
        let hosted = try Hosted()
        try hosted.scroll(toY: 0)
        let messages = hosted.entries.indices.filter { isMessage(hosted.entries[$0]) }
        // From the top, Next lands on each message after the first in turn.
        for target in messages.dropFirst() {
            hosted.go(.next)
            #expect(try hosted.showsTop(of: target), "row \(target)")
        }
        for target in messages.dropLast().reversed() {
            hosted.go(.previous)
            #expect(try hosted.showsTop(of: target), "row \(target)")
        }
        // At the first message Previous stays put.
        let before = try hosted.visible()
        hosted.go(.previous)
        #expect(try hosted.visible() == before)
    }

    @Test func afterScrollingAwayNextStartsFromWhatIsInView() throws {
        let hosted = try Hosted()
        try hosted.scroll(toY: 0)
        hosted.go(.next)
        // Scroll far down by hand; Next goes on from there, not from the
        // message the menu last moved to.
        let middle = hosted.entries.count / 2
        try hosted.scroll(toY: hosted.frame(of: middle).minY)
        hosted.go(.next)
        let expected = try #require(hosted.entries.indices.first { $0 > middle && isMessage(hosted.entries[$0]) })
        #expect(try hosted.showsTop(of: expected))
        #expect(try hosted.frame(of: expected).minY > hosted.frame(of: middle).minY)
    }
}
