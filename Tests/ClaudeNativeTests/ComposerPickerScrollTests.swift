import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

@MainActor
struct ComposerPickerScrollTests {
    @Test(arguments: [false, true])
    func aNewQueryShowsTheFirstResultEvenWhenTheMatchesStayTheSame(mentions: Bool) async throws {
        let paths = (0..<50).map { "sample-\($0).txt" }
        let commands = (0..<50).map { SlashCommand(name: "sample-\($0)", description: "Sample command") }
        func picker(_ query: String) -> AnyView {
            mentions
                ? AnyView(FileMentionList(paths: paths, highlighted: 0, query: query, choose: { _ in }))
                : AnyView(SlashCommandList(matches: commands, highlighted: 0, query: query, choose: { _ in }))
        }
        let (window, host) = AccessibilityHost.window(hosting: picker(""), size: NSSize(width: 500, height: 180))
        defer { window.close() }
        let scroll = try #require(ConversationSearchViewTests.views(NSScrollView.self, in: host).first)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        AccessibilityHost.settle(host)
        try #require(scroll.documentVisibleRect.minY > 100)
        host.rootView = picker("sample")
        AccessibilityHost.settle(host)
        try await Task.sleep(for: .milliseconds(100))
        AccessibilityHost.settle(host)
        #expect(scroll.documentVisibleRect.minY < 50)
    }
}
