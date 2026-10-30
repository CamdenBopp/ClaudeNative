import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

@MainActor
@Suite(.serialized)
struct FileMentionPickerTests {
    final class Box {
        var draft = ""
        var sent = false
        var changeRoot: (URL?) -> Void = { _ in }
    }

    struct Host: View {
        let box: Box
        @State var root: URL?
        @State var draft = ""
        @State var attachments: [ImageAttachment] = []
        @FocusState var focused: Bool

        var body: some View {
            Composer(
                draft: $draft, attachments: $attachments, focus: $focused,
                isReady: true, isWorking: false, usageLimits: nil, contextUsage: nil,
                send: { box.sent = true }, stop: {}, attachImages: {}, mentionRoot: root
            )
            .onAppear {
                focused = true
                box.changeRoot = { root = $0 }
            }
            .onChange(of: draft) { box.draft = draft }
        }
    }

    static func rows(in host: NSView) -> [(label: String, selected: Bool)] {
        AccessibilityHost.descendants(of: host).compactMap { element in
            guard AccessibilityHost.role(element) == .button,
                  let label = AccessibilityHost.label(element), label.hasPrefix("qa-") else { return nil }
            return (label, element.isAccessibilitySelected?() ?? false)
        }
    }

    @Test(arguments: ["", "qa-"])
    func changingFoldersRefreshesAnUnchangedMention(query: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mention-picker-\(UUID().uuidString)")
        let first = directory.appending(path: "first"), second = directory.appending(path: "second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["qa-alpha.txt", "qa-beta.txt"] {
            try Data().write(to: first.appending(path: name))
        }
        try Data().write(to: second.appending(path: "qa-gamma.txt"))
        let box = Box()
        let (window, host) = AccessibilityHost.window(hosting: Host(box: box, root: first), size: NSSize(width: 700, height: 400))
        defer { window.close() }
        try SlashCommandPickerTests.type("@" + query, in: window)
        let firstDeadline = ContinuousClock.now + .seconds(5)
        while Self.rows(in: host).count != 2, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(50))
            AccessibilityHost.settle(host)
        }
        try #require(Self.rows(in: host).map(\.label).sorted() == ["qa-alpha.txt", "qa-beta.txt"])
        let field = try #require(ConversationSearchViewTests.views(NSTextField.self, in: host).first { $0.isEditable })
        window.makeFirstResponder(field)
        try SlashCommandPickerTests.press("\u{F701}", keyCode: 125, in: window)
        try #require(Self.rows(in: host).map(\.selected) == [false, true])

        box.changeRoot(second)
        AccessibilityHost.settle(host)
        #expect(!Self.rows(in: host).contains { $0.label == "qa-beta.txt" }, "Old-folder results must disappear immediately.")
        let secondDeadline = ContinuousClock.now + .seconds(5)
        while Self.rows(in: host).map(\.label) != ["qa-gamma.txt"], ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(50))
            AccessibilityHost.settle(host)
        }
        #expect(Self.rows(in: host).map(\.label) == ["qa-gamma.txt"])
        #expect(Self.rows(in: host).map(\.selected) == [true])
        window.makeFirstResponder(field)
        try SlashCommandPickerTests.press("\r", keyCode: 36, in: window)
        #expect(box.draft == "@qa-gamma.txt ")
        #expect(!box.sent, "Return completes the current folder's file without sending the message.")
    }
}
