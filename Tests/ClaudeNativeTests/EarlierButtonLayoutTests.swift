import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The stack keeps hidden views in its layout now (faster updates), so a
/// hidden Show Earlier Messages must take no room: the first message sits
/// where it did, and the button shows only when there's an earlier page.
@MainActor
struct EarlierButtonLayoutTests {
    static func host(_ count: Int) -> (NSWindow, NSHostingView<TranscriptView>) {
        AccessibilityHost.window(hosting: TranscriptView(
            transcript: Transcript(restoring: TranscriptPagingTests.entries(count)), revision: 0, workingDirectory: nil, isWorking: false
        ), size: NSSize(width: 600, height: 400))
    }

    @Test func withNothingEarlierTheFirstMessageIsAtTheTop() throws {
        let (window, host) = Self.host(4)
        defer { window.close() }
        AccessibilityHost.settle(host)
        let stack = try #require(MessageNavigationHostedTests.Hosted.views(NSStackView.self, in: host).first { $0.orientation == .vertical && $0.arrangedSubviews.first is NSButton })
        let first = try #require(stack.arrangedSubviews.first { $0 is MessageRowView })
        #expect(abs(first.frame.minY - stack.edgeInsets.top) <= 1 || abs(stack.bounds.height - first.frame.maxY - stack.edgeInsets.top) <= 1,
                "first row at \(first.frame), stack \(stack.bounds), inset \(stack.edgeInsets.top)")
        let button = try #require(stack.arrangedSubviews.first as? NSButton)
        #expect(button.isHidden && button.frame.height == 0)
    }

    @Test func withAnEarlierPageTheButtonShows() throws {
        let (window, host) = Self.host(450)
        defer { window.close() }
        AccessibilityHost.settle(host)
        let button = try #require(MessageNavigationHostedTests.Hosted.views(NSButton.self, in: host).first { $0.title == "Show Earlier Messages" })
        #expect(!button.isHidden && button.frame.height > 10)
    }
}
