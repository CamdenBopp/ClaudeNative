import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// /projects' list: one element per project, read with its conversation
/// count, and said when it opens (focus arriving read only "table").
@MainActor
struct ProjectsSheetTests {
    static let projects = [ProjectSidebarTests.garden, ProjectSidebarTests.kitchen]

    @Test func eachProjectReadsWithItsCount() throws {
        let (window, host) = AccessibilityHost.window(hosting: ProjectsSheet(projects: Self.projects) { _ in }, size: NSSize(width: 500, height: 400))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let outline = try ConversationSearchViewTests.outline(window)
        let rows = (0..<outline.numberOfRows).compactMap { row -> String? in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
            return ([cell] + AccessibilityHost.descendants(of: cell)).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }.first { !$0.isEmpty }
        }
        #expect(rows == ["garden, 2 sessions", "kitchen · ~/Code, 1 session"])
    }

    @Test func openingSaysHowManyAndTheFirst() {
        #expect(ProjectsWording.opening(Self.projects) == "2 projects. garden, 2 sessions.")
        #expect(ProjectsWording.opening([]) == "No projects yet.")
    }

    /// Counted as the sidebar lists them: "5 sessions" for a project the
    /// sidebar showed 3 in was side chats and archived ones counted too.
    @Test func countsLeaveOutWhatTheSidebarHides() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProjectsSheetTests.\(UUID().uuidString)"))
        let garden = ProjectSidebarTests.garden
        defaults.set(garden.sessions[0].id, forKey: SideChats.defaultsKey)
        defaults.set(ProjectSidebarTests.kitchen.sessions[0].id, forKey: SessionArchive.defaultsKey)
        let listed = ProjectsSheet.listed(Self.projects, in: defaults)
        #expect(listed.map(\.sessions.count) == [1, 0])
        // With Show Archived Sessions on, archived ones count again.
        defaults.set(true, forKey: SessionArchive.showKey)
        #expect(ProjectsSheet.listed(Self.projects, in: defaults).map(\.sessions.count) == [1, 1])
    }

    /// Return started a session in the project and said nothing, so a
    /// VoiceOver user didn't hear that it worked, or where.
    @Test func choosingAProjectSaysWhereTheSessionStarted() async throws {
        var chosen: [String] = []
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in heard.append(text) }
        defer { Announcer.stopListening(listener) }
        let (window, host) = AccessibilityHost.window(hosting: ProjectsSheet(projects: Self.projects) { chosen.append($0.name) },
                                                      size: NSSize(width: 500, height: 400))
        defer { window.close() }
        AccessibilityHost.settle(host)
        #expect(AccessibilityHost.pressKey("\r", keyCode: 36, in: window))
        #expect(chosen == ["garden"])
        // Generous: hosted tests share the main thread with the whole suite.
        for _ in 0..<100 where !heard.contains("New session in garden.") { try await Task.sleep(for: .milliseconds(100)) }
        #expect(heard.contains("New session in garden."))
    }
}
