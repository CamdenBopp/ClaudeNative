import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// The caret stays where the user left it: going Back to a file or
/// expanding the panel builds the editor again, and Claude editing the
/// open file reloads it, and each put the caret on line 1, losing a
/// VoiceOver user's place.
@MainActor
struct EditorCaretKeptTests {
    static func host(_ document: EditorDocument) throws -> (NSWindow, FocusableTextView) {
        let (window, host) = AccessibilityHost.window(hosting: EditorPane(document: document), size: NSSize(width: 640, height: 480))
        let textView = try #require(TextScaleHostedTests.subviews(of: host, as: FocusableTextView.self).first)
        return (window, textView)
    }

    @Test func aRebuiltOrReloadedEditorKeepsTheCaret() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "caret-\(UUID().uuidString).txt")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = EditorDocument(url: file)
        let onThree = NSRange(location: 8, length: 0)
        do {
            let (window, textView) = try Self.host(document)
            textView.setSelectedRange(onThree)
            window.close()
        }
        // Built again, as Back or Expand Panel does.
        let (window, textView) = try Self.host(document)
        defer { window.close() }
        #expect(textView.selectedRange() == onThree)
        // Claude adds a line at the end; the file reloads.
        try "one\ntwo\nthree\nfour\nfive\n".write(to: file, atomically: true, encoding: .utf8)
        document.checkDisk()
        AccessibilityHost.settle(window.contentView!)
        #expect(textView.string.hasSuffix("five\n"))
        #expect(textView.selectedRange() == onThree)
    }
}
