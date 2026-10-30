import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// As in the Claude app, a turn shows "Claude" once: a reply that carries
/// on after Claude's tool rows draws no label of its own. VoiceOver still
/// names every reply.
@MainActor
struct TurnLabelTests {
    @Test func aReplyAfterToolRowsDrawsNoLabel() throws {
        // A plain reply, then a turn whose reply follows tool rows.
        let entries = try [("real_text_reply", "Say hello"), ("real_permission_allow", "Create hello.txt")]
            .enumerated().flatMap { number, capture in
                try Fixtures.replay(capture.0, userText: capture.1).entries.map {
                    TranscriptEntry(id: "\(number)-\($0.id)", kind: $0.kind, text: $0.text, toolInput: $0.toolInput)
                }
            }
            // And a turn with text, tools, then more text: the second reply
            // is the one that hides its label.
            + [
                TranscriptEntry(id: "x-user", kind: .user, text: "Check demo.swift"),
                TranscriptEntry(id: "x-reply", kind: .assistant, text: "I'll read it."),
                TranscriptEntry(id: "x-tool", kind: .tool(name: "Read", status: .succeeded), text: "demo.swift"),
                TranscriptEntry(id: "x-more", kind: .assistant, text: "It sets count to 2."),
            ]
        let view = TranscriptView(
            transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil,
            isWorking: false, navigator: MessageNavigator()
        )
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 900))
        AccessibilityHost.settle(try #require(window.contentView))
        let rows = MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: window.contentView)
        #expect(rows.count == entries.count)
        // A reply hides its label only when an earlier reply in the same
        // turn already showed "Claude". A turn that opens with a tool still
        // shows it once (the permission capture: you, tool rows, reply).
        var sawShownAfterTool = false, sawHidden = false
        var turnShowedClaude = false
        for (index, entry) in entries.enumerated() {
            if entry.kind == .user || entry.kind == .notice { turnShowedClaude = false; continue }
            guard entry.kind == .assistant else { continue }
            let afterTool = index > 0 && entries[index - 1].kind != .user
            #expect(rows[index].showsLabel == !turnShowedClaude, "row \(index)")
            #expect(rows[index].accessibilityLabel() == "Claude", "row \(index)")
            if afterTool && !turnShowedClaude { sawShownAfterTool = true }
            if turnShowedClaude { sawHidden = true }
            turnShowedClaude = true
        }
        #expect(sawShownAfterTool, "a turn opening with a tool should be in the captures")
        #expect(sawHidden, "a turn with a second reply should be too")
        // Your message and the tool rows keep their labels.
        for (index, entry) in entries.enumerated() where entry.kind != .assistant {
            #expect(rows[index].showsLabel, "row \(index)")
        }
    }
}
