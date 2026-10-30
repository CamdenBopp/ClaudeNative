import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The conversation search field, hosted in a real split view. Text goes in
/// through the field's editor, as typing does, and the rows are read from
/// the accessibility tree VoiceOver is handed.
@MainActor
struct ConversationSearchViewTests {
    final class Resumed {
        var ids: [String] = []
    }

    /// Titles and first prompts as the history fixtures list them.
    static let sessions: [SessionHistory.SessionSummary] = {
        let url = URL(fileURLWithPath: "/dev/null")
        let now = Date()
        return [
            .init(id: "kitchen", title: "Kitchen remodel", lastModified: now, fileURL: url,
                  firstPrompt: "Help me price a kitchen remodel"),
            .init(id: "fence", title: "Fence repair estimate", lastModified: now.addingTimeInterval(-60), fileURL: url,
                  firstPrompt: "How much does a fence repair cost?"),
            .init(id: "legacy", title: "Legacy summary title", lastModified: now.addingTimeInterval(-120), fileURL: url,
                  firstPrompt: "Old-format session prompt"),
        ]
    }()

    static let project = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/garden"), name: "garden", sessions: sessions)

    static func host() -> (NSWindow, Resumed) {
        let resumed = Resumed()
        let view = NavigationSplitView {
            SavedConversationList(
                projects: [project],
                selectedID: nil,
                resume: { resumed.ids.append($1.id) },
                startNew: { _ in }
            )
        } detail: {
            Text("Detail")
        }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 500))
        return (window, resumed)
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ([view as? T].compactMap { $0 }) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The window's whole view tree, toolbar included: the search field
    /// sits in the toolbar, outside the content view.
    static func frameView(_ window: NSWindow) throws -> NSView {
        let content = try #require(window.contentView)
        return content.superview ?? content
    }

    static func searchField(_ window: NSWindow) throws -> NSSearchField {
        try #require(views(NSSearchField.self, in: try frameView(window)).first)
    }

    static func outline(_ window: NSWindow) throws -> NSOutlineView {
        let root = try #require(window.contentView)
        return try #require(views(NSOutlineView.self, in: root).first)
    }

    /// Types into the search field as a person would: focus it, then insert
    /// text through its field editor, replacing what was there.
    @discardableResult
    static func type(_ text: String, in window: NSWindow) throws -> NSTextView {
        let field = try searchField(window)
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        AccessibilityHost.settle(try #require(window.contentView))
        return editor
    }

    /// What each row hands VoiceOver, top to bottom. Row 0 is the
    /// "Conversations" heading, which has no static text and drops out.
    static func rowTexts(_ window: NSWindow) throws -> [String] {
        let outline = try outline(window)
        return (0..<outline.numberOfRows).compactMap { row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
            let texts = AccessibilityHost.descendants(of: cell)
                .filter { AccessibilityHost.role($0) == .staticText }
                .compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }
            return texts.count == 1 ? texts[0] : nil
        }
    }

    /// The titles of the rows shown; each row reads "title, when".
    static func rowTitles(_ window: NSWindow) throws -> [String] {
        try rowTexts(window).compactMap { text in sessions.first { text.hasPrefix($0.title + ", ") }?.title }
    }

    /// Every static text in the window: the empty-list message is one.
    static func texts(_ window: NSWindow) throws -> [String] {
        AccessibilityHost.descendants(of: try #require(window.contentView))
            .filter { AccessibilityHost.role($0) == .staticText }
            .compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }
    }

    static func showsNoMatchMessage(_ window: NSWindow) throws -> Bool {
        try texts(window).contains { $0.hasPrefix("No sessions match") }
    }

    /// Rename and Delete are VoiceOver actions on each row (VO-Command-Space)
    /// as well as its context menu.
    @Test func everyConversationOffersRenameAndDelete() throws {
        let (window, _) = Self.host()
        let outline = try Self.outline(window)
        AccessibilityHost.settle(try #require(window.contentView))
        var rowsWithActions = 0
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            let names = ([cell as AnyObject] + AccessibilityHost.descendants(of: cell))
                .flatMap { AccessibilityHost.customActions($0).map(\.name) }
            if names.contains("Rename"), names.contains("Delete") { rowsWithActions += 1 }
        }
        #expect(rowsWithActions == Self.sessions.count)
    }

    @Test func searchFieldIsNamedAndEveryConversationShowsAtFirst() throws {
        let (window, _) = Self.host()
        // The field's cell is the element VoiceOver lands on; its
        // placeholder is the name it reads.
        let root = try Self.frameView(window)
        let fields = AccessibilityHost.descendants(of: root).filter { ($0.accessibilitySubrole?() ?? nil) == .searchField }
        #expect(fields.count == 1)
        #expect(fields.first.flatMap { $0.accessibilityPlaceholderValue?() ?? nil } == "Search sessions")
        #expect(try Self.rowTitles(window) == Self.sessions.map(\.title))
    }

    @Test func typingNarrowsTheRowsAndKeepsFocusInTheField() throws {
        let (window, _) = Self.host()
        let editor = try Self.type("price", in: window)
        #expect(try Self.rowTitles(window) == ["Kitchen remodel"])
        #expect(window.firstResponder === editor)

        try Self.type("FENCE cost", in: window)
        #expect(try Self.rowTitles(window) == ["Fence repair estimate"])
        #expect(window.firstResponder === editor)
    }

    @Test func noMatchShowsAMessageInTheTree() throws {
        let (window, _) = Self.host()
        #expect(try !Self.showsNoMatchMessage(window))
        try Self.type("submarine", in: window)
        #expect(try Self.rowTitles(window) == [])
        #expect(try Self.texts(window).contains("No sessions match \"submarine\"."))
    }

    @Test func escapeClearsTheSearchAndRestoresEveryRow() throws {
        let (window, _) = Self.host()
        let editor = try Self.type("submarine", in: window)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        editor.keyDown(with: escape)
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(try Self.searchField(window).stringValue == "")
        #expect(try Self.rowTitles(window) == Self.sessions.map(\.title))
        #expect(try !Self.showsNoMatchMessage(window))
    }

    /// ChatView's Command-F bumps the request; the list then focuses its
    /// search field, wherever focus was.
    @Test func searchRequestFocusesTheSearchField() throws {
        let field = NSTextField()
        let resumed = Resumed()
        func list(_ request: Int) -> some View {
            NavigationSplitView {
                SavedConversationList(
                    projects: [Self.project], selectedID: nil,
                    resume: { resumed.ids.append($1.id) }, startNew: { _ in }, searchRequest: request
                )
            } detail: {
                Text("Detail")
            }
        }
        let (window, host) = AccessibilityHost.window(hosting: list(0), size: NSSize(width: 700, height: 500))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let search = try Self.searchField(window)
        #expect(search.currentEditor() == nil)

        host.rootView = list(1)
        AccessibilityHost.settle(host)
        #expect(search.currentEditor() != nil)
        #expect(window.firstResponder === search.currentEditor())
    }

    @Test func selectingAFilteredRowResumesThatConversation() throws {
        let (window, resumed) = Self.host()
        try Self.type("legacy", in: window)
        #expect(try Self.rowTitles(window) == ["Legacy summary title"])
        // Row 0 is the heading; row 1 is the only match.
        try Self.outline(window).selectRowIndexes([1], byExtendingSelection: false)
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(resumed.ids == ["legacy"])
    }
}
