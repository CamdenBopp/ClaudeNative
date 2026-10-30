import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Go > Next Project and Previous Project reach projects scrolled out of
/// the sidebar's view, which VoiceOver's heading keys can't.
@MainActor
@Suite(.serialized)
struct ProjectNavigationTests {
    /// Twelve projects of six conversations: far more than 600 points show.
    static let projects: [SessionHistory.ProjectSummary] = (0..<12).map { number in
        SessionHistory.ProjectSummary(
            directory: URL(fileURLWithPath: "/tmp/project\(number)"), name: "project \(number)",
            sessions: (0..<6).map { index in session("p\(number)-\(index)", age: Double(number * 10 + index)) }
        )
    }

    static func session(_ id: String, age: Double) -> SessionHistory.SessionSummary {
        .init(id: id, title: id, lastModified: Date(timeIntervalSince1970: 1_800_000_000 - age), fileURL: URL(fileURLWithPath: "/dev/null"))
    }

    static func host(_ navigator: ProjectNavigator) -> NSWindow {
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        UserDefaults.standard.removeObject(forKey: "pinnedConversations")
        let view = NavigationSplitView {
            SavedConversationList(projects: projects, selectedID: nil, resume: { _, _ in }, startNew: { _ in }, projectNavigator: navigator)
        } detail: {
            Text("Detail")
        }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        AccessibilityHost.settle(window.contentView!)
        return window
    }

    /// Whether the `index`th project's header row is on screen.
    static func showsHeader(_ index: Int, in window: NSWindow) throws -> Bool {
        let outline = try ConversationSearchViewTests.outline(window)
        let finder = SidebarOutline()
        finder.outlineView = outline
        let row = try #require(finder.headerRows.dropFirst(index).first)
        return outline.visibleRect.contains(outline.rect(ofRow: row))
    }

    @Test func nextProjectScrollsToAProjectOutOfView() throws {
        let navigator = ProjectNavigator()
        let window = Self.host(navigator)
        defer { window.close() }
        #expect(try !Self.showsHeader(5, in: window))
        for _ in 0...5 {
            navigator.perform(.next)
            AccessibilityHost.settle(window.contentView!)
        }
        #expect(try Self.showsHeader(5, in: window))
        navigator.perform(.previous)
        AccessibilityHost.settle(window.contentView!)
        #expect(try Self.showsHeader(4, in: window))
    }

    @Test func theHeaderRowsAreTheProjects() throws {
        let window = Self.host(ProjectNavigator())
        defer { window.close() }
        let finder = SidebarOutline()
        finder.outlineView = try ConversationSearchViewTests.outline(window)
        #expect(finder.headerRows.count == Self.projects.count)
    }
}
