import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

/// View > Bigger Text reaches the code editor and the diff reader, live, the
/// way the menu changes it: through the stored scale both views observe.
/// Each test hosts the real view on its own defaults suite, so the scale it
/// writes can't leak into another test or the app.
@MainActor
struct TextScaleHostedTests {
    static let bigger = 1.5
    /// Longer than the editor's pause before it recolors an edit.
    static let rehighlightWait: TimeInterval = 0.5

    static func suite() throws -> UserDefaults {
        let name = "TextScaleHostedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(TextScale.standard.factor, forKey: TextScale.defaultsKey)
        return defaults
    }

    static func subviews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + subviews(of: $0, as: type) }
    }

    static func fonts(in storage: NSTextStorage) -> Set<CGFloat> {
        var sizes: Set<CGFloat> = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.insert(font.pointSize) }
        }
        return sizes
    }

    static func colors(in storage: NSTextStorage) -> [NSRange: NSColor] {
        var colors: [NSRange: NSColor] = [:]
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? NSColor { colors[range] = color }
        }
        return colors
    }

    @Test func editorFontTracksTheScaleInPlaceKeepingCaretUndoAndColors() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "TextScale-\(UUID().uuidString).swift")
        try "let answer = 42\nfunc greet() { print(\"hi\") }\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = try Self.suite()
        let document = EditorDocument(url: file)
        let (window, host) = AccessibilityHost.window(
            hosting: EditorPane(document: document).defaultAppStorage(defaults),
            size: NSSize(width: 640, height: 480)
        )
        defer { window.close() }
        let textView = try #require(Self.subviews(of: host, as: FocusableTextView.self).first)
        let storage = try #require(textView.textStorage)
        let standard = Theme.conversationTextSize(.body, scale: TextScale.standard.factor)
        #expect(Self.fonts(in: storage) == [standard])

        // An edit to undo, and a caret away from the start.
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText("// note", replacementRange: textView.selectedRange())
        textView.breakUndoCoalescing()
        let caret = NSRange(location: 4, length: 6)
        textView.setSelectedRange(caret)
        let undo = try #require(textView.undoManager)
        #expect(undo.canUndo)
        let edited = textView.string
        // Let the edit's recoloring run, so the colors compared below are
        // settled. It's worked out off the main thread and handed back to
        // the main actor, which a run loop spun here doesn't let happen.
        try await Task.sleep(for: .seconds(Self.rehighlightWait))
        for _ in 0..<50 where Set(Self.colors(in: storage).values).count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let colors = Self.colors(in: storage)
        #expect(Set(colors.values).count > 1, "the Swift file should be highlighted in more than one color")

        defaults.set(Self.bigger, forKey: TextScale.defaultsKey)
        AccessibilityHost.settle(host)

        let scaled = Theme.conversationTextSize(.body, scale: Self.bigger)
        #expect(scaled > standard)
        // The same view, not a rebuilt one, now drawing every character bigger.
        #expect(Self.subviews(of: host, as: FocusableTextView.self).first === textView)
        #expect(Self.fonts(in: storage) == [scaled])
        #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == scaled)
        #expect(textView.string == edited)
        #expect(textView.selectedRange() == caret)
        #expect(Self.colors(in: storage) == colors)
        #expect(document.isDirty)
        #expect(undo.canUndo)
        undo.undo()
        #expect(!textView.string.contains("// note"))

        // And back to Actual Size.
        defaults.set(TextScale.standard.factor, forKey: TextScale.defaultsKey)
        AccessibilityHost.settle(host)
        #expect(Self.fonts(in: storage) == [standard])
    }

    @Test func diffReaderTextTracksTheScale() throws {
        let input = JSONValue.object([
            "file_path": .string("/tmp/TextScaleHostedTests/new.swift"),
            "content": .string("let answer = 42\nfunc greet() { print(\"hi\") }\n"),
        ])
        let diff = try #require(ToolDiff.make(toolName: "Write", input: input) { _ in nil })
        let hunk = try #require(diff.hunks.first)
        let line = try #require(hunk.lines.first)
        let defaults = try Self.suite()
        let (window, host) = AccessibilityHost.window(
            hosting: DiffReaderView(diff: diff, base: nil).defaultAppStorage(defaults),
            size: NSSize(width: 640, height: 480)
        )
        defer { window.close() }

        func height(of text: String) throws -> CGFloat {
            let element = try #require(AccessibilityHost.descendants(of: window).first { AccessibilityHost.value($0) == text })
            return try #require(element.accessibilityFrame?()).height
        }
        let lineBefore = try height(of: line.spoken)
        let headingBefore = try height(of: hunk.title)

        defaults.set(Self.bigger, forKey: TextScale.defaultsKey)
        AccessibilityHost.settle(host)

        // A row is its text plus fixed padding, so it grows a little less
        // than the text does.
        let lineAfter = try height(of: line.spoken)
        let headingAfter = try height(of: hunk.title)
        #expect(lineAfter > lineBefore * 1.3, "line row \(lineBefore) -> \(lineAfter)")
        #expect(headingAfter > headingBefore * 1.3, "hunk heading \(headingBefore) -> \(headingAfter)")
    }
}
