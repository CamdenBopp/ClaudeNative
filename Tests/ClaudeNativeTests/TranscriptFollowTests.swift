import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Reading the end of a conversation, a narrower column (the side panel
/// opening, the window shrinking) keeps the end in view.
@MainActor
struct TranscriptFollowTests {
    @Test func narrowingKeepsTheEndInView() throws {
        let hosted = try MessageNavigationHostedTests.Hosted()
        let scrollView = try hosted.scrollView
        let content = try #require(hosted.window.contentView)
        func distanceFromEnd() throws -> CGFloat {
            let document = try #require(scrollView.documentView)
            return document.bounds.maxY - scrollView.contentView.documentVisibleRect.maxY
        }
        hosted.go(.latest)
        let document = try #require(scrollView.documentView)
        try hosted.scroll(toY: document.bounds.maxY)
        AccessibilityHost.settle(content)
        #expect(try distanceFromEnd() <= 1)
        // The side panel takes about half the conversation's width.
        hosted.window.setContentSize(NSSize(width: 340, height: 300))
        AccessibilityHost.settle(content)
        let distance = try distanceFromEnd()
        #expect(distance <= TranscriptLayout.followThreshold, "the end is \(distance) points below the view")
    }

    /// Someone reading further up stays where they are.
    @Test func narrowingAwayFromTheEndLeavesTheScrollAlone() throws {
        let hosted = try MessageNavigationHostedTests.Hosted()
        let content = try #require(hosted.window.contentView)
        try hosted.scroll(toY: 0)
        AccessibilityHost.settle(content)
        hosted.window.setContentSize(NSSize(width: 340, height: 300))
        AccessibilityHost.settle(content)
        #expect(try hosted.visible().minY == 0)
    }
}
