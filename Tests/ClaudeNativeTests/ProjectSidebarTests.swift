import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// The sidebar as a projects view, like the Claude app's Code section: one
/// section per project, named by a heading, with its conversations under it.
@MainActor
@Suite(.serialized)
struct ProjectSidebarTests {
    final class Calls {
        var resumed: [(project: String, session: String)] = []
        var started: [String] = []
    }

    static let garden = SessionHistory.ProjectSummary(
        directory: URL(fileURLWithPath: "/tmp/garden"), name: "garden",
        sessions: [ConversationSearchViewTests.sessions[0], ConversationSearchViewTests.sessions[1]]
    )
    static let kitchen = SessionHistory.ProjectSummary(
        directory: URL(fileURLWithPath: "/tmp/kitchen"), name: "kitchen · ~/Code",
        sessions: [ConversationSearchViewTests.sessions[2]]
    )

    static func host(collapsed: [String] = []) -> (NSWindow, Calls) {
        UserDefaults.standard.set(collapsed.joined(separator: "\n"), forKey: "collapsedProjects")
        let calls = Calls()
        let view = NavigationSplitView {
            SavedConversationList(
                projects: [garden, kitchen],
                selectedID: nil,
                resume: { calls.resumed.append(($0.name, $1.id)) },
                startNew: { calls.started.append($0.name) }
            )
        } detail: {
            Text("Detail")
        }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        AccessibilityHost.settle(window.contentView!)
        return (window, calls)
    }

    /// Every element in the list's rows, section headers included. The
    /// outline's own children stop at the rows, so each row's view is read.
    static func all(_ window: NSWindow) throws -> [AnyObject] {
        let outline = try ConversationSearchViewTests.outline(window)
        return (0..<outline.numberOfRows).flatMap { row -> [AnyObject] in
            guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return [] }
            return [view] + AccessibilityHost.descendants(of: view)
        }
    }

    static func shownTitles(_ window: NSWindow) throws -> [String] {
        try ConversationSearchViewTests.rowTitles(window)
    }

    /// Each project reads as a heading named by it (VO-Command-H moves
    /// between projects), and offers New Conversation in VO-Command-Space;
    /// the + beside it does the same with the mouse.
    @Test func eachProjectIsAHeadingThatStartsAConversation() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, calls) = Self.host()
        let headings = try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }
        #expect(headings.compactMap(AccessibilityHost.label) == ["garden", "kitchen · ~/Code"])
        let action = try #require(AccessibilityHost.customActions(headings[1]).first { $0.name == "New Session" })
        _ = action.handler?()
        #expect(calls.started == ["kitchen · ~/Code"])
        #expect(try Self.shownTitles(window) == ["Kitchen remodel", "Fence repair estimate", "Legacy summary title"])
    }

    /// The toolbar title's Pin reaches the sidebar, which pins the
    /// conversation as its own row menu would.
    @Test func theTitleMenusPinIsDoneByTheSidebar() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: "collapsedProjects")
            UserDefaults.standard.removeObject(forKey: "pinnedConversations")
        }
        UserDefaults.standard.removeObject(forKey: "pinnedConversations")
        let actions = SessionActions()
        let view = NavigationSplitView {
            SavedConversationList(projects: [Self.garden, Self.kitchen], selectedID: nil, resume: { _, _ in }, startNew: { _ in }, sessionActions: actions)
        } detail: { Text("Detail") }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        defer { window.close() }
        AccessibilityHost.settle(window.contentView!)
        let id = Self.kitchen.sessions[0].id
        actions.perform(.togglePin, on: id)
        AccessibilityHost.settle(window.contentView!)
        #expect(UserDefaults.standard.string(forKey: "pinnedConversations") == id)
        let headings = try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }.compactMap(AccessibilityHost.label)
        #expect(headings.first == "Pinned")
    }

    @Test func choosingAConversationOpensItInItsProject() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, calls) = Self.host()
        let outline = try ConversationSearchViewTests.outline(window)
        let row = try #require((0..<outline.numberOfRows).first { row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
            return AccessibilityHost.descendants(of: cell).contains { (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix("Legacy summary title") }
        })
        outline.selectRowIndexes([row], byExtendingSelection: false)
        AccessibilityHost.settle(try #require(window.contentView))
        #expect(calls.resumed.map(\.project) == ["kitchen · ~/Code"])
        #expect(calls.resumed.map(\.session) == ["legacy"])
    }

    @Test func aFoldedProjectHidesItsConversationsUntilASearchMatchesThem() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, _) = Self.host(collapsed: ["/tmp/kitchen"])
        #expect(try Self.shownTitles(window) == ["Kitchen remodel", "Fence repair estimate"])
        try ConversationSearchViewTests.type("legacy", in: window)
        #expect(try Self.shownTitles(window) == ["Legacy summary title"])
    }

    @Test func searchingLeavesOutProjectsWithNoMatch() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, _) = Self.host()
        try ConversationSearchViewTests.type("fence", in: window)
        #expect(try Self.shownTitles(window) == ["Fence repair estimate"])
        let headings = try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }
        #expect(headings.compactMap(AccessibilityHost.label) == ["garden"])
    }

    /// "This computer" reads as a heading like any project, but offers no
    /// New Conversation; its conversations resume in their own folders.
    @Test func thisComputerOffersNoNewConversation() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        var scratch = ConversationSearchViewTests.sessions[2]
        scratch.directory = URL(fileURLWithPath: "/tmp/scratch-1")
        let computer = SessionHistory.ProjectSummary(
            directory: URL(fileURLWithPath: "/tmp/scratch-workspaces"), name: "This computer",
            sessions: [scratch], startsConversations: false
        )
        let view = NavigationSplitView {
            SavedConversationList(projects: [Self.garden, computer], selectedID: nil, resume: { _, _ in }, startNew: { _ in })
        } detail: { Text("Detail") }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        AccessibilityHost.settle(window.contentView!)
        let headings = try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }
        #expect(headings.compactMap(AccessibilityHost.label) == ["garden", "This computer"])
        #expect(AccessibilityHost.customActions(headings[0]).map(\.name) == ["New Session", "Show in Finder", "Collapse"])
        // No folder of its own to show.
        #expect(AccessibilityHost.customActions(headings[1]).map(\.name) == ["Collapse"])
        #expect(SavedConversationList.folder(for: scratch, in: computer).path == "/tmp/scratch-1")
        #expect(SavedConversationList.folder(for: Self.garden.sessions[0], in: Self.garden).path == "/tmp/garden")
    }

    /// A conversation working in any window shows a dot, as in the Claude
    /// app, and VoiceOver hears "working" after its title.
    @Test func aWorkingConversationIsMarked() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        let view = NavigationSplitView {
            SavedConversationList(projects: [Self.garden, Self.kitchen], selectedID: nil, resume: { _, _ in }, startNew: { _ in }, working: ["fence"])
        } detail: { Text("Detail") }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        AccessibilityHost.settle(window.contentView!)
        let rows = try ConversationSearchViewTests.rowTexts(window)
        #expect(rows.filter { $0.contains("working") } == rows.filter { $0.hasPrefix("Fence repair estimate, working, ") })
        #expect(rows.contains { $0.hasPrefix("Fence repair estimate, working, ") })
        #expect(rows.contains { $0.hasPrefix("Kitchen remodel, ") && !$0.contains("working") })
    }

    /// A conversation waiting on you says so, and outranks working; one
    /// that finished unseen reads "unread", as the Claude app marks them.
    @Test func waitingAndUnreadConversationsAreMarked() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        let view = NavigationSplitView {
            SavedConversationList(projects: [Self.garden, Self.kitchen], selectedID: nil, resume: { _, _ in }, startNew: { _ in },
                                  working: ["fence"], waiting: ["fence"], unread: ["kitchen"])
        } detail: { Text("Detail") }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        AccessibilityHost.settle(window.contentView!)
        let rows = try ConversationSearchViewTests.rowTexts(window)
        #expect(rows.contains { $0.hasPrefix("Fence repair estimate, needs your answer, ") })
        #expect(rows.contains { $0.hasPrefix("Kitchen remodel, unread, ") })
        #expect(!rows.contains { $0.contains("working") })
    }

    /// Archive takes a session out of the list without deleting it; Show
    /// Archived Sessions brings it back, read as "archived", and Unarchive
    /// returns it for good.
    @Test func archivingHidesASessionUntilShown() throws {
        defer {
            for key in ["collapsedProjects", SessionArchive.defaultsKey, SessionArchive.showKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        for key in [SessionArchive.defaultsKey, SessionArchive.showKey] { UserDefaults.standard.removeObject(forKey: key) }
        let (window, _) = Self.host()
        func rows() throws -> [String] {
            AccessibilityHost.settle(window.contentView!)
            return try ConversationSearchViewTests.rowTexts(window)
        }
        let row = try #require(try Self.all(window).first {
            (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix("Kitchen remodel, ")
        })
        let action = try #require(AccessibilityHost.customActions(row).first { $0.name == "Archive" })
        _ = action.handler?()
        #expect(!(try rows()).contains { $0.hasPrefix("Kitchen remodel, ") })
        #expect(SessionArchive.ids().contains("kitchen"))
        UserDefaults.standard.set(true, forKey: SessionArchive.showKey)
        #expect(try rows().contains { $0.hasPrefix("Kitchen remodel, archived, ") })
    }

    /// Each row offers Open in New Window, as the Claude app's row menu
    /// does, among VoiceOver's actions.
    @Test func rowsOfferOpenInNewWindow() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, _) = Self.host()
        let row = try #require(try Self.all(window).first {
            (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix("Kitchen remodel, ")
        })
        #expect(AccessibilityHost.customActions(row).map(\.name).contains("Open in New Window"))
    }

    /// Mark as Unread keeps a session marked until it's next looked at.
    @Test func markingUnreadLastsUntilSeen() {
        let store = WorkingConversations()
        store.markUnread("a")
        #expect(store.unread == ["a"])
        store.seen("b")
        #expect(store.unread == ["a"])
        store.seen("a")
        #expect(store.unread.isEmpty)
    }

    /// Reopen Closed Session takes the latest closed first; a session
    /// closed twice is listed once, and the list keeps only the newest.
    @Test func closedSessionsReopenNewestFirst() throws {
        let closed = ClosedSessions()
        let folder = URL(fileURLWithPath: "/Users/me/garden")
        #expect(closed.isEmpty)
        closed.remember(folder, Self.garden.sessions[0])
        closed.remember(folder, Self.kitchen.sessions[0])
        closed.remember(folder, Self.garden.sessions[0])
        #expect(closed.takeLast()?.1.id == Self.garden.sessions[0].id)
        #expect(closed.takeLast()?.1.id == Self.kitchen.sessions[0].id)
        #expect(closed.takeLast() == nil)
        for number in 0..<(ClosedSessions.limit + 5) {
            closed.remember(folder, SessionHistory.SessionSummary(id: "s\(number)", title: "S", lastModified: .now, fileURL: folder))
        }
        var count = 0
        while closed.takeLast() != nil { count += 1 }
        #expect(count == ClosedSessions.limit)
    }

    /// Grouped by date, sections are dates and each row says its project,
    /// which the section no longer does.
    @Test func groupingByDateNamesEachRowsProject() throws {
        defer {
            for key in ["collapsedProjects", SidebarGrouping.defaultsKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(SidebarGrouping.date.rawValue, forKey: SidebarGrouping.defaultsKey)
        let (window, _) = Self.host()
        let headings = try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }.compactMap(AccessibilityHost.label)
        #expect(!headings.contains("garden"))
        #expect(headings.allSatisfy { SessionHistory.DateGroup(rawValue: $0) != nil })
        let rows = try ConversationSearchViewTests.rowTexts(window)
        #expect(rows.contains { $0.hasPrefix("Kitchen remodel, ") && $0.hasSuffix(", in garden") })
        #expect(rows.contains { $0.hasPrefix("Legacy summary title, ") && $0.hasSuffix(", in kitchen · ~/Code") })
    }

    /// Windows report what they're working on; the store holds each
    /// window's latest, so a finished or switched window clears its mark.
    @Test func theStoreFollowsEachWindow() {
        let store = WorkingConversations()
        let first = NSObject(), second = NSObject()
        store.update(window: first, sessionID: "a", working: true)
        store.update(window: second, sessionID: "b", working: true)
        #expect(store.ids == ["a", "b"])
        store.update(window: first, sessionID: "a", working: false)
        #expect(store.ids == ["b"])
        store.update(window: second, sessionID: "c", working: true)
        #expect(store.ids == ["c"])
        store.remove(window: second)
        #expect(store.ids.isEmpty)
    }

    /// A conversation waiting on the user is marked while it waits; one
    /// that finished unseen stays unread until looked at.
    @Test func theStoreMarksWaitingAndUnread() {
        let store = WorkingConversations()
        let window = NSObject()
        store.update(window: window, sessionID: "a", working: true, waiting: true)
        #expect(store.waiting == ["a"])
        store.update(window: window, sessionID: "a", working: true, waiting: false)
        #expect(store.waiting.isEmpty)
        store.finished("a", seen: true)
        #expect(store.unread.isEmpty)
        store.finished("a", seen: false)
        #expect(store.unread == ["a"])
        store.seen("a")
        #expect(store.unread.isEmpty)
    }

    /// Pin from a row's actions puts it in a Pinned section first, as in
    /// the Claude app; Unpin puts it back in its project.
    @Test func pinningMovesAConversationToPinned() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: "collapsedProjects")
            UserDefaults.standard.removeObject(forKey: "pinnedConversations")
        }
        UserDefaults.standard.removeObject(forKey: "pinnedConversations")
        let (window, _) = Self.host()
        func headings() throws -> [String] {
            try Self.all(window).filter { AccessibilityHost.role($0)?.rawValue == "AXHeading" }.compactMap(AccessibilityHost.label)
        }
        func row(_ title: String) throws -> AnyObject {
            try #require(try Self.all(window).first {
                (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix(title + ", ")
            })
        }
        func perform(_ name: String, on title: String) throws {
            let action = try #require(AccessibilityHost.customActions(try row(title)).first { $0.name == name })
            _ = action.handler?()
            AccessibilityHost.settle(try #require(window.contentView))
        }
        #expect(try headings() == ["garden", "kitchen · ~/Code"])
        try perform("Pin", on: "Legacy summary title")
        #expect(try headings() == ["Pinned", "garden"])
        #expect(try Self.shownTitles(window) == ["Legacy summary title", "Kitchen remodel", "Fence repair estimate"])
        try perform("Unpin", on: "Legacy summary title")
        #expect(try headings() == ["garden", "kitchen · ~/Code"])
    }

    /// Folding is a VoiceOver action on the heading too: Collapse hides
    /// the project's conversations and becomes Expand, which shows them.
    @Test func aHeadingCollapsesAndExpandsItsProject() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        let (window, _) = Self.host()
        func heading(_ name: String) throws -> AnyObject {
            try #require(try Self.all(window).first { AccessibilityHost.role($0)?.rawValue == "AXHeading" && AccessibilityHost.label($0) == name })
        }
        func perform(_ action: String, on name: String) throws {
            let found = try #require(AccessibilityHost.customActions(try heading(name)).first { $0.name == action })
            _ = found.handler?()
            AccessibilityHost.settle(try #require(window.contentView))
        }
        #expect(AccessibilityHost.customActions(try heading("garden")).map(\.name) == ["New Session", "Show in Finder", "Collapse"])
        try perform("Collapse", on: "garden")
        #expect(try Self.shownTitles(window) == ["Legacy summary title"])
        #expect(AccessibilityHost.customActions(try heading("garden")).map(\.name) == ["New Session", "Show in Finder", "Expand"])
        try perform("Expand", on: "garden")
        #expect(try Self.shownTitles(window) == ["Kitchen remodel", "Fence repair estimate", "Legacy summary title"])
    }

    static let openDeadline: Duration = .seconds(10)

    /// Arrowing through the list opens only where it stops: each opened
    /// conversation starts a CLI, which also writes to its file. A click
    /// opens at once.
    @Test func arrowingOpensOnlyWhereItStops() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        let calls = Calls()
        var byKeyboard = true
        let view = NavigationSplitView {
            SavedConversationList(projects: [Self.garden, Self.kitchen], selectedID: nil,
                                  resume: { calls.resumed.append(($0.name, $1.id)) }, startNew: { _ in },
                                  opensAfterPause: { byKeyboard })
        } detail: { Text("Detail") }
        let (window, _) = AccessibilityHost.window(hosting: view, size: NSSize(width: 700, height: 600))
        let content = try #require(window.contentView)
        AccessibilityHost.settle(content)
        let outline = try ConversationSearchViewTests.outline(window)
        // Conversation rows, not the section headers' group rows.
        let rows = (0..<outline.numberOfRows).filter { outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: $0) as Any) != true }
        for row in rows {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            AccessibilityHost.settle(content)
        }
        #expect(calls.resumed.isEmpty)
        // At least the pause, then however long a busy full suite takes to
        // run the delayed open: one fixed wait of the pause plus 300 ms
        // failed there and passed alone.
        try await Task.sleep(for: SidebarLayout.keyboardOpenPause)
        let deadline = ContinuousClock.now + Self.openDeadline
        while calls.resumed.isEmpty, ContinuousClock.now < deadline {
            AccessibilityHost.settle(content)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(calls.resumed.map(\.session) == ["legacy"])

        byKeyboard = false
        outline.selectRowIndexes([rows[0]], byExtendingSelection: false)
        AccessibilityHost.settle(content)
        #expect(calls.resumed.map(\.session) == ["legacy", "kitchen"])
    }

    @MainActor @Observable final class Selection {
        var id: String?
    }

    struct SelectionHost: View {
        let project: SessionHistory.ProjectSummary
        let selection: Selection
        var body: some View {
            NavigationSplitView {
                SavedConversationList(projects: [project], selectedID: selection.id, resume: { _, _ in }, startNew: { _ in })
            } detail: { Text("Detail") }
        }
    }

    /// A conversation opened from elsewhere (search, a new window, Open
    /// Recent) is selected in the sidebar and scrolled into view, so its
    /// row is there to see and to arrow on from.
    @Test func theOpenConversationIsScrolledIntoView() throws {
        defer { UserDefaults.standard.removeObject(forKey: "collapsedProjects") }
        UserDefaults.standard.removeObject(forKey: "collapsedProjects")
        let sessions = (0..<60).map { number in
            SessionHistory.SessionSummary(
                id: "s\(number)", title: "Session \(number)",
                lastModified: Date(timeIntervalSince1970: 1_800_000_000 - Double(number) * 60),
                fileURL: URL(fileURLWithPath: "/nonexistent/s\(number).jsonl")
            )
        }
        let project = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/long"), name: "long", sessions: sessions)
        let selection = Selection()
        let (window, _) = AccessibilityHost.window(hosting: SelectionHost(project: project, selection: selection), size: NSSize(width: 700, height: 300))
        let content = try #require(window.contentView)
        AccessibilityHost.settle(content)
        let outline = try ConversationSearchViewTests.outline(window)
        func isShown(_ title: String) -> Bool {
            let visible = outline.rows(in: outline.visibleRect)
            return (visible.location..<visible.location + visible.length).contains { row in
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
                return ([cell] + AccessibilityHost.descendants(of: cell)).contains { (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix(title + ",") }
            }
        }
        #expect(isShown("Session 0"))
        #expect(!isShown("Session 50"))
        selection.id = "s50"
        AccessibilityHost.settle(content)
        #expect(isShown("Session 50"))

        // A window that opens on a conversation shows its row too.
        let opening = Selection()
        opening.id = "s45"
        let (second, _) = AccessibilityHost.window(hosting: SelectionHost(project: project, selection: opening), size: NSSize(width: 700, height: 300))
        let secondContent = try #require(second.contentView)
        AccessibilityHost.settle(secondContent)
        let secondOutline = try ConversationSearchViewTests.outline(second)
        let visible = secondOutline.rows(in: secondOutline.visibleRect)
        #expect((visible.location..<visible.location + visible.length).contains { row in
            guard let cell = secondOutline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
            return ([cell] + AccessibilityHost.descendants(of: cell)).contains { (AccessibilityHost.label($0) ?? AccessibilityHost.value($0) ?? "").hasPrefix("Session 45,") }
        })
    }

    /// Unread marks, Mark as Unread's included, were kept in memory only
    /// and gone after a relaunch, unlike pins and archives.
    @Test func unreadMarksOutlastARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnreadTests.\(UUID().uuidString)"))
        let before = WorkingConversations(defaults: defaults)
        before.markUnread("a")
        before.finished("b", seen: false)
        before.seen("b")
        #expect(WorkingConversations(defaults: defaults).unread == ["a"])
    }
}

/// Command-1 to 9 follow the rows on screen, search and all.
@MainActor
struct SessionJumpTargetTests {
    @Test func whileSearchingTheJumpsAreTheMatchesShown() {
        let garden = ProjectSidebarTests.garden, kitchen = ProjectSidebarTests.kitchen
        // Searching shows only kitchen's match, its project open though folded.
        let shown = [SessionHistory.ProjectSummary(directory: kitchen.directory, name: kitchen.name, sessions: kitchen.sessions)]
        let targets = SavedConversationList.jumpTargets(shown: shown, folded: [kitchen.id, garden.id], searching: true)
        #expect(targets.map(\.id) == kitchen.sessions.map(\.id))
        // Not searching, a folded project's sessions aren't counted.
        #expect(SavedConversationList.jumpTargets(shown: [garden, kitchen], folded: [garden.id], searching: false).map(\.id) == kitchen.sessions.map(\.id))
    }

    /// A session opened into a folded project unfolds it, so its row shows.
    @Test func openingASessionUnfoldsItsProject() {
        let garden = ProjectSidebarTests.garden, kitchen = ProjectSidebarTests.kitchen
        let id = kitchen.sessions[0].id
        #expect(SavedConversationList.unfolded([garden.id, kitchen.id], toShow: id, in: [garden, kitchen]) == [garden.id])
        #expect(SavedConversationList.unfolded([garden.id], toShow: id, in: [garden, kitchen]) == [garden.id])
    }
}

/// Pinned rows leave their projects, so each says which it came from:
/// two pinned "Fix the tests" from two repositories read alike.
@MainActor
struct PinnedRowProjectTests {
    @Test func aPinnedSessionKeepsItsProjectsName() {
        let garden = ProjectSidebarTests.garden
        let pinned = SessionHistory.pinning([garden, ProjectSidebarTests.kitchen], pinned: [garden.sessions[0].id])
        #expect(pinned.first?.name == SessionHistory.ProjectSummary.pinnedName)
        #expect(pinned.first?.sessions.first?.projectName == "garden")
    }
}
