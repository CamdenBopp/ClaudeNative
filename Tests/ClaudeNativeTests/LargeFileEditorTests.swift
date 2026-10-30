import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// Opening a large file in the editor highlighted all of it on the main
/// thread first: a 5 MB JSON file froze the app for 10 s, 20 MB for 41 s.
/// The text now shows plain at once and is colored off the main thread.
@MainActor
struct LargeFileEditorTests {
    /// 2 MB took 4.25 s to show before (debug build) and 0.69 s after; the
    /// limit leaves room for a busy suite.
    static let showLimit: Duration = .milliseconds(2500)

    @Test func aTwoMegabyteFileShowsWithoutWaitingForColors() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "large-\(UUID().uuidString).json")
        let line = "{\"id\": 12345, \"name\": \"item\", \"tags\": [\"a\", \"b\"], \"value\": 3.14159}\n"
        let text = String(repeating: line, count: (2 << 20) / line.utf8.count)
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = EditorDocument(url: file)
        var window: NSWindow?
        let shown = ContinuousClock().measure {
            let (opened, host) = AccessibilityHost.window(hosting: EditorPane(document: document), size: NSSize(width: 800, height: 600))
            window = opened
            host.layoutSubtreeIfNeeded()
            opened.contentView?.displayIfNeeded()
        }
        defer { window?.close() }
        #expect(shown < Self.showLimit, "took \(shown)")
        let content = try #require(window?.contentView)
        let textView = try #require(TextScaleHostedTests.subviews(of: content, as: FocusableTextView.self).first)
        #expect(textView.string == text)
    }
}
