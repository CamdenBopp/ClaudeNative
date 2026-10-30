import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// While a reply streams the view follows its end, but a scroll up of
/// less than the 40-point threshold was undone by the next update: a slow
/// trackpad scroll kept being pulled back.
@MainActor
struct ScrollFollowTests {
    static func view(_ reply: String, revision: Int) -> TranscriptView {
        var entries = TranscriptPagingTests.entries(40)
        entries.append(TranscriptEntry(id: "reply", kind: .assistant, text: reply))
        return TranscriptView(transcript: Transcript(restoring: entries), revision: revision, workingDirectory: nil, isWorking: true)
    }

    @Test func aSmallScrollUpIsntPulledBack() throws {
        var reply = "Streaming"
        let (window, host) = AccessibilityHost.window(hosting: Self.view(reply, revision: 0), size: NSSize(width: 600, height: 300))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let scrollView = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: host).first { $0.accessibilityLabel() == "Conversation" })
        let document = try #require(scrollView.documentView)
        func distanceToEnd() -> CGFloat { document.bounds.maxY - scrollView.contentView.documentVisibleRect.maxY }
        #expect(distanceToEnd() < 1)
        // The user scrolls up 20 points.
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 20))
        scrollView.reflectScrolledClipView(clip)
        let readingY = clip.bounds.minY
        for i in 1...5 {
            reply += " word\(i)"
            host.rootView = Self.view(reply, revision: i)
            AccessibilityHost.settle(host)
        }
        #expect(abs(clip.bounds.minY - readingY) < 1, "moved from \(readingY) to \(clip.bounds.minY)")
    }

    /// At the very end it still follows.
    @Test func atTheEndItFollows() throws {
        var reply = "Streaming"
        let (window, host) = AccessibilityHost.window(hosting: Self.view(reply, revision: 0), size: NSSize(width: 600, height: 300))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let scrollView = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: host).first { $0.accessibilityLabel() == "Conversation" })
        let document = try #require(scrollView.documentView)
        for i in 1...5 {
            reply += "\n\nA new paragraph \(i) that adds height."
            host.rootView = Self.view(reply, revision: i)
            AccessibilityHost.settle(host)
        }
        #expect(document.bounds.maxY - scrollView.contentView.documentVisibleRect.maxY < 1)
    }
}
