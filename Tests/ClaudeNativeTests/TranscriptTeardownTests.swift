import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

/// Switching sessions takes the conversation out of the window (through the
/// empty state) and builds a new one. The old scroll area stayed alive with
/// every row, and nothing told VoiceOver it had gone: a cursor or hot spot
/// left in it went on reading the conversation that was no longer shown.
@MainActor
struct TranscriptTeardownTests {
    @Observable final class Shown { var transcript: Transcript? }

    struct Root: View {
        let shown: Shown
        var body: some View {
            if let transcript = shown.transcript {
                TranscriptView(transcript: transcript, revision: 0, workingDirectory: nil, isWorking: false)
            } else {
                Text("No conversation")
            }
        }
    }

    @Test func aRemovedConversationLeavesNothingToRead() throws {
        let shown = Shown()
        shown.transcript = ReplyBlockAccessibilityTests.Hosted.transcript(ReplyBlockAccessibilityTests.reply)
        let (window, host) = AccessibilityHost.window(hosting: Root(shown: shown), size: NSSize(width: 800, height: 900))
        let conversation = try #require(AccessibilityHost.descendants(of: window).first {
            AccessibilityHost.role($0) == .scrollArea && AccessibilityHost.label($0) == "Conversation"
        })
        let reply = try #require(AccessibilityHost.children(conversation).last { AccessibilityHost.role($0) == .group })
        let paragraph = try #require(AccessibilityHost.children(reply).first)
        #expect(!AccessibilityHost.descendants(of: conversation).isEmpty)

        // What a session switch does: the empty state replaces the view.
        shown.transcript = nil
        AccessibilityHost.settle(host)

        // Held by VoiceOver, the old elements say there's nothing there.
        let left = AccessibilityHost.descendants(of: conversation)
            .filter { AccessibilityHost.role($0) != .scrollBar }
        #expect(left.isEmpty, "still readable: \(left.compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) })")
        #expect(AccessibilityHost.children(reply).isEmpty)
        #expect((paragraph as? NSAccessibilityElement)?.accessibilityParent() == nil)
    }
}
