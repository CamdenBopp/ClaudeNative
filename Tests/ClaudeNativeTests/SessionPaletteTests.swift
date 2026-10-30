import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Command-K's palette: sessions from every project, newest first, each
/// read with where it lives.
@MainActor
struct SessionPaletteTests {
    /// Count opportunities for the UI task to run. A wall-clock deadline
    /// expired while another hosted suite held the main actor, before the
    /// palette's delayed task had a chance to start.
    private static func waitForAnnouncement(_ arrived: () -> Bool) async throws {
        let maximumChecks = 600 // Thirty seconds of uncontended polling.
        for _ in 0..<maximumChecks {
            if arrived() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func movingTheSelectionCancelsThePendingFirstResultAnnouncement() async throws {
        let project = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/palette-announcement-qa"), name: "Selection QA", sessions: [
            Self.session("first", "Selection QA first", age: 0),
            Self.session("second", "Selection QA second", age: 1),
        ])
        var heard: [String] = []
        let token = Announcer.listen { text, _ in
            if text.contains("Selection QA") { heard.append(text) }
        }
        defer { Announcer.stopListening(token) }
        let (window, host) = AccessibilityHost.window(
            hosting: SessionPalette(projects: [project], open: { _, _ in }, start: { _ in }),
            size: NSSize(width: 600, height: 420)
        )
        defer { window.close() }
        let field = try #require(ConversationSearchViewTests.views(NSTextField.self, in: host).first { $0.isEditable })
        window.makeFirstResponder(field)
        try SlashCommandPickerTests.press("\u{F701}", keyCode: 125, in: window)
        try #require(heard.count == 1 && heard[0].hasPrefix("Selection QA second"))
        try await Task.sleep(for: SlashCommandSearch.announcementDelay + .milliseconds(300))
        #expect(heard.count == 1, "The pending first-result summary replaced the selected session: \(heard)")
        // Typing starts a new search, so its count should be announced.
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Selection", replacementRange: editor.selectedRange())
        AccessibilityHost.settle(host)
        try await Self.waitForAnnouncement { heard.count >= 2 }
        #expect(heard.count == 2 && heard.last?.hasPrefix("2 sessions. Selection QA first") == true)
    }

    @Test func theSearchSummaryStillAnnouncesWithoutArrowNavigation() async throws {
        let project = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/palette-idle-qa"), name: "Idle QA", sessions: [
            Self.session("idle", "Idle QA first", age: 0),
        ])
        var heard: [String] = []
        let token = Announcer.listen { text, _ in
            if text.contains("Idle QA first") { heard.append(text) }
        }
        defer { Announcer.stopListening(token) }
        let (window, _) = AccessibilityHost.window(
            hosting: SessionPalette(projects: [project], open: { _, _ in }, start: { _ in }),
            size: NSSize(width: 600, height: 420)
        )
        defer { window.close() }
        try await Self.waitForAnnouncement { !heard.isEmpty }
        #expect(heard.count == 1 && heard[0].hasPrefix("1 session. Idle QA first"), "Received: \(heard)")
    }

    @Test func changingTheQueryBringsTheFirstMatchBackIntoView() throws {
        let project = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/palette-qa"), name: "QA", sessions:
            (0..<50).map { Self.session("s\($0)", "Session \($0)", age: Double($0)) })
        var opened: [String] = []
        let (window, host) = AccessibilityHost.window(
            hosting: SessionPalette(projects: [project], open: { _, session in opened.append(session.id) }, start: { _ in }),
            size: NSSize(width: 600, height: 420)
        )
        defer { window.close() }
        let scroll = try #require(ConversationSearchViewTests.views(NSScrollView.self, in: host).first { $0.documentView is NSTableView })
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        AccessibilityHost.settle(host)
        try #require(scroll.documentVisibleRect.minY > 100)
        let field = try #require(ConversationSearchViewTests.views(NSTextField.self, in: host).first { $0.isEditable })
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Session", replacementRange: editor.selectedRange())
        AccessibilityHost.settle(host)
        // Keep the keyboard interaction on the main actor without an
        // async pause: other hosted suites also use AppKit's field editor.
        AccessibilityHost.settle(host)
        #expect(scroll.documentVisibleRect.minY < 50)
        #expect(window.firstResponder === editor)
        try SlashCommandPickerTests.press("\r", keyCode: 36, in: window)
        #expect(opened == ["s0"])
    }

    static func session(_ id: String, _ title: String, age: Double) -> SessionHistory.SessionSummary {
        .init(id: id, title: title, lastModified: Date(timeIntervalSince1970: 1_800_000_000 - age), fileURL: URL(fileURLWithPath: "/dev/null"))
    }

    static let projects = [
        SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/w/IA"), name: "IA", sessions: [
            session("i1", "EPUB reader", age: 300), session("i2", "OLED theme", age: 10),
        ]),
        SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/w/Neon"), name: "Neon", sessions: [
            session("n1", "EPUB import", age: 100),
        ]),
    ]

    /// The highlight is a session, not a place in the list: a reply
    /// finishing moves its session to the top while the palette is open,
    /// and Return opened whatever had moved into the highlighted place.
    @Test func returnOpensTheHighlightedSessionAfterTheListReorders() throws {
        let before = SessionPalette.ranked(Self.projects, query: "")
        let highlighted = try #require(SessionPalette.stepped(from: nil, by: 1, in: before))
        #expect(highlighted == "n1")
        // i1 is touched and moves to the top.
        var projects = Self.projects
        projects[0] = SessionHistory.ProjectSummary(directory: projects[0].directory, name: "IA", sessions: [
            Self.session("i1", "EPUB reader", age: 1), Self.session("i2", "OLED theme", age: 10),
        ])
        let after = SessionPalette.ranked(projects, query: "")
        #expect(after.map(\.id) == ["i1", "i2", "n1"])
        #expect(SessionPalette.chosen(highlighted, in: after)?.id == "n1")
        // Nothing highlighted yet: Return opens the first.
        #expect(SessionPalette.chosen(nil, in: after)?.id == "i1")
        // Highlighted, then gone from the list: nothing is opened in its place.
        #expect(SessionPalette.chosen("gone", in: after) == nil)
    }

    @Test func matchesComeFromEveryProjectNewestFirst() {
        let palette = SessionPalette(projects: Self.projects, open: { _, _ in }, start: { _ in })
        #expect(palette.matches.map(\.id) == ["i2", "n1", "i1"])
    }

    @Test func aMatchIsReadWithItsProject() throws {
        let match = try #require(SessionPalette(projects: Self.projects, open: { _, _ in }, start: { _ in }).matches.first)
        #expect(SessionPalette.spoken(match).hasSuffix(", in IA"))
        #expect(SessionPalette.spoken(match).hasPrefix("OLED theme, "))
    }

    /// A session titled with what's typed comes before a newer one that
    /// only holds the words somewhere in its first prompt: Return opened
    /// "EPUB reader: page-based VoiceOver model" for "Esc test A".
    @Test func aTitleMatchComesBeforeANewerPromptMatch() {
        let titled = Self.session("e", "Esc test A", age: 3600)
        let prompted = SessionHistory.SessionSummary(
            id: "p", title: "EPUB reader: page-based VoiceOver model", lastModified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: URL(fileURLWithPath: "/dev/null"), firstPrompt: "Describe the test plan for a reader"
        )
        let projects = [SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/w/A"), name: "A", sessions: [prompted, titled])]
        #expect(SessionPalette.ranked(projects, query: "Esc test A").map(\.id) == ["e", "p"])
        #expect(SessionPalette.ranked(projects, query: "").map(\.id) == ["p", "e"])
    }

    /// Among first-prompt matches, words that start words ("esc" in "Esc
    /// key") come before letters found inside others ("esc" in "describe"),
    /// even when the latter is newer.
    @Test func wordStartsComeBeforeLettersInsideWords() {
        func session(_ id: String, prompt: String, age: Double) -> SessionHistory.SessionSummary {
            .init(id: id, title: "Untitled", lastModified: Date(timeIntervalSince1970: 1_800_000_000 - age), fileURL: URL(fileURLWithPath: "/dev/null"), firstPrompt: prompt)
        }
        let inside = session("inside", prompt: "Describe the latest build", age: 0)
        let starts = session("starts", prompt: "Why does the Esc key test fail", age: 600)
        let projects = [SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/w/A"), name: "A", sessions: [inside, starts])]
        #expect(SessionPalette.ranked(projects, query: "esc test").map(\.id) == ["starts", "inside"])
    }
}
