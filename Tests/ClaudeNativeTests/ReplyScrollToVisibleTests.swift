import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// VoiceOver sends AXScrollToVisible before landing on a hot spot. A
/// reply's block took it, said it had scrolled and didn't, so a hot spot on
/// a paragraph that had scrolled away landed off screen with nothing read.
@MainActor
struct ReplyScrollToVisibleTests {
    @Test func aParagraphScrollsItselfIntoView() throws {
        // The reply first, then enough messages under it to push it away.
        var entries = [TranscriptEntry(id: "r", kind: .assistant, text: "Hot spot here.\n\nA second paragraph.")]
        for index in 0..<60 {
            entries.append(TranscriptEntry(id: "u\(index)", kind: .user, text: "Message \(index)"))
        }
        let view = TranscriptView(transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false)
        let (window, host) = AccessibilityHost.window(hosting: view, size: NSSize(width: 800, height: 400))
        let conversation = try #require(AccessibilityHost.descendants(of: window).first {
            AccessibilityHost.role($0) == .scrollArea && AccessibilityHost.label($0) == "Conversation"
        } as? NSView)
        let paragraph = try #require(AccessibilityHost.descendants(of: window).first {
            AccessibilityHost.value($0) == "Hot spot here."
        } as? ReplyElement)
        let visible = conversation.window?.convertToScreen(conversation.convert(conversation.bounds, to: nil)) ?? .zero
        // A saved conversation opens at its end, so the paragraph is far above.
        #expect(!visible.intersects(paragraph.accessibilityFrame()))

        paragraph.accessibilityPerformAction(ReplyElement.scrollToVisibleAction)
        AccessibilityHost.settle(host)

        #expect(visible.contains(paragraph.accessibilityFrame()), "\(paragraph.accessibilityFrame()) not in \(visible)")
    }
}
