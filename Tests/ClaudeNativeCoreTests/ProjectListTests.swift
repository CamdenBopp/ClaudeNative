import Foundation
import Testing
@testable import ClaudeNativeCore

/// The sidebar's projects: every folder the CLI has saved conversations
/// for, named as the Claude app names them.
struct ProjectListTests {
    static let home = URL(fileURLWithPath: "/Users/me")

    @Test func aProjectIsNamedByItsFolder() {
        let names = SessionHistory.projectNames(for: [
            URL(fileURLWithPath: "/Users/me/garden"),
            URL(fileURLWithPath: "/Users/me/Code/kitchen"),
        ], home: Self.home)
        #expect(names == ["garden", "kitchen"])
    }

    /// Two folders with one name are told apart by where they live, with
    /// the home folder as ~.
    @Test func sameNamedFoldersAddTheirParent() {
        let names = SessionHistory.projectNames(for: [
            URL(fileURLWithPath: "/Users/me/Documents/enchanted"),
            URL(fileURLWithPath: "/Volumes/Work/enchanted"),
            URL(fileURLWithPath: "/Users/me/enchanted"),
            URL(fileURLWithPath: "/Users/me/fence"),
        ], home: Self.home)
        #expect(names == ["enchanted · ~/Documents", "enchanted · /Volumes/Work", "enchanted · ~", "fence"])
    }

    /// Names that differ only in case sound the same to VoiceOver, so they
    /// add where they are too.
    @Test func namesDifferingOnlyInCaseAddTheirParent() {
        let names = SessionHistory.projectNames(for: [
            URL(fileURLWithPath: "/Users/me/Enchanted"),
            URL(fileURLWithPath: "/Users/me/Documents/enchanted"),
        ], home: Self.home)
        #expect(names == ["Enchanted · ~", "enchanted · ~/Documents"])
    }

    /// One project per folder with conversations, newest activity first,
    /// each with its conversations newest first. Folders with nothing a
    /// person typed, and folders that no longer exist, are left out.
    @Test func projectsComeFromEveryFolderNewestFirst() throws {
        let projects = try TemporaryFolder()
        let work = try TemporaryFolder()
        let garden = work.url.appending(path: "garden"), kitchen = work.url.appending(path: "kitchen")
        let gone = work.url.appending(path: "gone")
        for folder in [garden, kitchen] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        func save(_ fixture: String, as id: String, cwd: URL, age: Double) throws {
            let folder = projects.url.appending(path: SessionHistory.encodedDirectoryName(forPath: cwd.path))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = try String(contentsOf: SessionHistoryTests.history.appending(path: "\(fixture).jsonl"), encoding: .utf8)
            // The fixtures record another cwd; this one is where they live now.
            let line = #"{"type":"system","cwd":"\#(cwd.path)"}"#
            let file = folder.appending(path: "\(id).jsonl")
            try (line + "\n" + Self.dated(text, age: age)).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 - age)], ofItemAtPath: file.path)
        }
        try save("titled", as: "g1", cwd: garden, age: 300)
        try save("ai_titled", as: "k1", cwd: kitchen, age: 5)
        try save("summary_titled", as: "g2", cwd: garden, age: 30)
        try save("no_prompt", as: "k2", cwd: kitchen, age: 10)
        try save("untitled", as: "x1", cwd: gone, age: 0)

        let listed = SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [])
        #expect(listed.map(\.name) == ["kitchen", "garden"])
        #expect(listed.map(\.directory.lastPathComponent) == ["kitchen", "garden"])
        #expect(listed.first?.sessions.map(\.id) == ["k1"])
        #expect(listed.last?.sessions.map(\.id) == ["g2", "g1"])
    }

    static func session(_ id: String, _ age: Double = 0) -> SessionHistory.SessionSummary {
        .init(id: id, title: id, lastModified: Date(timeIntervalSince1970: 1_800_000_000 - age), fileURL: URL(fileURLWithPath: "/dev/null"))
    }

    /// The window's own folder always has a section, first when it has no
    /// conversations yet, and shows the window's fresher list of them.
    @Test func theWindowsFolderIsAlwaysListed() {
        let garden = URL(fileURLWithPath: "/Users/me/garden"), kitchen = URL(fileURLWithPath: "/Users/me/kitchen")
        let listed = [SessionHistory.ProjectSummary(directory: garden, name: "garden", sessions: [Self.session("g1")])]
        let fresh = SessionHistory.projects(listed, current: kitchen, sessions: [], home: Self.home)
        #expect(fresh.map(\.name) == ["kitchen", "garden"])
        #expect(fresh.first?.sessions.isEmpty == true)

        let updated = SessionHistory.projects(listed, current: garden, sessions: [Self.session("g2"), Self.session("g1", 5)], home: Self.home)
        #expect(updated.map(\.name) == ["garden"])
        #expect(updated.first?.sessions.map(\.id) == ["g2", "g1"])
    }

    /// The CLI records the resolved path, so a folder opened through a
    /// symlink is the same project.
    @Test func theWindowsFolderMatchesThroughSymlinks() throws {
        let work = try TemporaryFolder()
        let real = work.url.appending(path: "garden"), link = work.url.appending(path: "garden-link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let recorded = URL(fileURLWithPath: SessionHistory.canonicalPath(real))
        let listed = [SessionHistory.ProjectSummary(directory: recorded, name: "garden", sessions: [Self.session("t1")])]
        let merged = SessionHistory.projects(listed, current: link, sessions: [Self.session("t2")], home: Self.home)
        #expect(merged.count == 1)
        #expect(merged.first?.sessions.map(\.id) == ["t2"])
    }

    /// A worktree is named by its repository and its own name: short to
    /// read and hear, unlike its path, and plainly a worktree.
    @Test func aWorktreeIsNamedByItsRepositoryAndItself() {
        let names = SessionHistory.projectNames(for: [
            URL(fileURLWithPath: "/Users/me/IA"),
            URL(fileURLWithPath: "/Users/me/IA/.claude/worktrees/macos-native"),
            URL(fileURLWithPath: "/Users/me/Neon/.claude/worktrees/brave-moser"),
            URL(fileURLWithPath: "/Users/me/Old/IA/.claude/worktrees/macos-native"),
        ], home: Self.home)
        #expect(names == [
            "IA",
            "IA · macos-native · ~/IA/.claude/worktrees",
            "Neon · brave-moser",
            "IA · macos-native · ~/Old/IA/.claude/worktrees",
        ])
    }

    /// The moment `age` seconds before the fixed "now" these tests use.
    static func moment(_ age: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 - age) }

    /// A fixture's records restamped as written `age` seconds ago: a
    /// conversation is as new as its last record.
    static func dated(_ text: String, age: Double) -> String {
        let stamp = moment(age).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        return text.replacing(/"timestamp":"[^"]*"/) { _ in #""timestamp":"\#(stamp)Z""# }
    }

    /// Opening a conversation makes the CLI append records with no
    /// timestamp (its cost and mode), which update the file's date. The
    /// conversation keeps its place and its time: it wasn't used, only
    /// opened.
    @Test func openingAConversationKeepsItsPlace() throws {
        let projects = try TemporaryFolder()
        try Self.save("older", folderPath: "/w/garden", cwds: ["/w/garden"], in: projects.url, age: 3600)
        try Self.save("newer", folderPath: "/w/garden", cwds: ["/w/garden"], in: projects.url, age: 60)
        let folder = projects.url.appending(path: SessionHistory.encodedDirectoryName(forPath: "/w/garden"))
        let opened = folder.appending(path: "older.jsonl")
        let handle = try FileHandle(forWritingTo: opened)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"cost-state","sessionId":"older","totalCostUSD":0}"# + "\n" + #"{"type":"mode","mode":"normal","sessionId":"older"}"# + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Self.moment(0)], ofItemAtPath: opened.path)

        let listed = SessionHistory.listSessions(inProjectDirectory: folder)
        #expect(listed.map(\.id) == ["newer", "older"])
        #expect(listed.last?.lastModified == Self.moment(3600))
    }

    /// Writes a session file into the project folder the CLI would use for
    /// `folderPath`, whose lines record `cwds` in turn.
    static func save(_ id: String, folderPath: String, cwds: [String], in projects: URL, age: Double = 0) throws {
        let folder = projects.appending(path: SessionHistory.encodedDirectoryName(forPath: folderPath))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = try String(contentsOf: SessionHistoryTests.history.appending(path: "untitled.jsonl"), encoding: .utf8)
        let lines = cwds.map { #"{"type":"system","cwd":"\#($0)"}"# }.joined(separator: "\n")
        let file = folder.appending(path: "\(id).jsonl")
        try (lines + "\n" + dated(text, age: age)).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 - age)], ofItemAtPath: file.path)
    }

    /// A conversation that moved into a worktree is saved under the
    /// worktree's folder though it first recorded the repository: it
    /// resumes in the folder the file is saved for.
    @Test func aConversationResumesInTheFolderItsFileIsSavedFor() throws {
        let projects = try TemporaryFolder(), work = try TemporaryFolder()
        let repo = work.url.appending(path: "IA").path
        let worktree = repo + "/.claude/worktrees/macos-native"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try Self.save("w1", folderPath: worktree, cwds: [repo, worktree], in: projects.url)
        let listed = SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [])
        let resumesIn = listed.first?.sessions.first?.directory.map { SessionHistory.canonicalPath($0) }
        #expect(resumesIn == SessionHistory.canonicalPath(URL(fileURLWithPath: worktree)))
    }

    /// Worktree conversations are listed under their repository, as the
    /// Claude app lists them, not as sections of their own scattered among
    /// other projects by date (where "IA · epub-…" sat under POTALogger).
    @Test func worktreeConversationsAreListedUnderTheirRepository() throws {
        let projects = try TemporaryFolder(), work = try TemporaryFolder()
        let repo = work.url.appending(path: "IA").path, other = work.url.appending(path: "POTALogger").path
        let epub = repo + "/.claude/worktrees/epub-phase-a", native = repo + "/.claude/worktrees/macos-native"
        for folder in [epub, native, other] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try Self.save("i1", folderPath: repo, cwds: [repo], in: projects.url, age: 500)
        try Self.save("p1", folderPath: other, cwds: [other], in: projects.url, age: 100)
        try Self.save("e1", folderPath: epub, cwds: [epub], in: projects.url, age: 300)
        try Self.save("n1", folderPath: native, cwds: [native], in: projects.url, age: 50)
        let listed = SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [])
        #expect(listed.map(\.name) == ["IA", "POTALogger"])
        #expect(listed.first?.sessions.map(\.id) == ["n1", "e1", "i1"])
        let folders = listed.first?.sessions.map { $0.directory.map { SessionHistory.canonicalPath($0) } ?? "repository" }
        #expect(folders == [SessionHistory.canonicalPath(URL(fileURLWithPath: native)), SessionHistory.canonicalPath(URL(fileURLWithPath: epub)), "repository"])
    }

    /// A window in a worktree shows its conversations in the repository's
    /// section, with no section of its own.
    @Test func aWindowInAWorktreeUsesItsRepositorysSection() {
        let repo = URL(fileURLWithPath: "/Users/me/IA"), worktree = URL(fileURLWithPath: "/Users/me/IA/.claude/worktrees/epub")
        var old = Self.session("e1", 60); old.directory = worktree
        let listed = [SessionHistory.ProjectSummary(directory: repo, name: "IA", sessions: [Self.session("i1", 30), old])]
        let fresh = SessionHistory.projects(listed, current: worktree, sessions: [Self.session("e2"), Self.session("e1", 60)], home: Self.home)
        #expect(fresh.map(\.name) == ["IA"])
        #expect(fresh.first?.sessions.map(\.id) == ["e2", "i1", "e1"])
        #expect(fresh.first?.sessions.first?.directory == worktree)
        // And a window in the repository itself keeps the worktrees' rows.
        let inRepo = SessionHistory.projects(listed, current: repo, sessions: [Self.session("i2")], home: Self.home)
        #expect(inRepo.first?.sessions.map(\.id) == ["i2", "e1"])
    }

    /// Two saved folders for one working folder are one project.
    @Test func foldersForOneWorkingFolderAreOneProject() throws {
        let projects = try TemporaryFolder(), work = try TemporaryFolder()
        let garden = work.url.appending(path: "garden")
        try FileManager.default.createDirectory(at: garden, withIntermediateDirectories: true)
        let link = work.url.appending(path: "garden-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: garden)
        try Self.save("g1", folderPath: garden.path, cwds: [garden.path], in: projects.url, age: 10)
        try Self.save("g2", folderPath: link.path, cwds: [link.path], in: projects.url, age: 0)
        let listed = SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [])
        #expect(listed.count == 1)
        #expect(listed.first?.sessions.map(\.id) == ["g2", "g1"])
    }

    /// Throwaway folders in the system's temporary space (test runs,
    /// scripted sessions) aren't projects.
    @Test func temporaryFoldersAreLeftOut() throws {
        let projects = try TemporaryFolder(), work = try TemporaryFolder()
        let scratch = work.url.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Self.save("s1", folderPath: scratch.path, cwds: [scratch.path], in: projects.url)
        #expect(SessionHistory.listProjects(projectsDirectory: projects.url, hiding: []).count == 1)
        #expect(SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [SessionHistory.canonicalPath(work.url)]).isEmpty)
        #expect(SessionHistory.isTemporary(URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "x")))
        #expect(SessionHistory.isTemporary(URL(fileURLWithPath: "/tmp/x")))
        #expect(!SessionHistory.isTemporary(URL(fileURLWithPath: "/Users/me/garden")))
    }

    /// The Claude app's no-folder sessions each live in a scratch folder of
    /// their own; like the Claude app, they're one "This computer" section,
    /// after the projects, each conversation resuming in its own folder.
    /// The section can't start a conversation: there's no folder to start in.
    @Test func scratchSessionsAreOneThisComputerSection() throws {
        let projects = try TemporaryFolder(), work = try TemporaryFolder()
        let scratch = work.url.appending(path: "scratch-workspaces")
        let first = scratch.appending(path: "a/scratch-1"), second = scratch.appending(path: "b/scratch-2")
        let garden = work.url.appending(path: "garden")
        for folder in [first, second, garden] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Self.save("s1", folderPath: first.path, cwds: [first.path], in: projects.url, age: 0)
        try Self.save("s2", folderPath: second.path, cwds: [second.path], in: projects.url, age: 20)
        try Self.save("g1", folderPath: garden.path, cwds: [garden.path], in: projects.url, age: 10)
        let listed = SessionHistory.listProjects(projectsDirectory: projects.url, hiding: [], gathering: SessionHistory.canonicalPath(scratch))
        #expect(listed.map(\.name) == ["garden", "This computer"])
        let computer = try #require(listed.last)
        #expect(!computer.startsConversations)
        #expect(computer.sessions.map(\.id) == ["s1", "s2"])
        #expect(computer.sessions.map { $0.directory.map(SessionHistory.canonicalPath) } == [first, second].map(SessionHistory.canonicalPath))
        #expect(listed.first?.startsConversations == true)
        #expect(listed.first?.sessions.first?.directory == nil)
    }

    /// Merging the window's folder leaves "This computer" as it is, and a
    /// window in one of its scratch folders doesn't get a section of its own.
    @Test func mergingKeepsThisComputer() {
        let scratch = URL(fileURLWithPath: "/Users/me/scratch-workspaces")
        let computer = SessionHistory.ProjectSummary(directory: scratch, name: "This computer", sessions: [Self.session("s1")], startsConversations: false)
        let garden = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/garden"), name: "garden", sessions: [Self.session("g1")])
        let inGarden = SessionHistory.projects([garden, computer], current: garden.directory, sessions: [Self.session("g2")], home: Self.home)
        #expect(inGarden.map(\.name) == ["garden", "This computer"])
        #expect(inGarden.last?.startsConversations == false)
        let inScratch = SessionHistory.projects([garden, computer], current: scratch.appending(path: "a/scratch-1"), sessions: [], home: Self.home)
        #expect(inScratch.map(\.name) == ["garden", "This computer"])
    }

    /// Pinned conversations come first, as in the Claude app: one "Pinned"
    /// section, newest first, each resuming in its own project's folder and
    /// taken out of that project so no conversation is listed twice. A
    /// project left empty by pinning goes too.
    @Test func pinnedConversationsComeFirst() {
        let garden = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/garden"), name: "garden",
                                                   sessions: [Self.session("g1"), Self.session("g2", 50)])
        var scratchSession = Self.session("s1", 10)
        scratchSession.directory = URL(fileURLWithPath: "/Users/me/scratch/a")
        let computer = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/scratch"), name: "This computer",
                                                     sessions: [scratchSession], startsConversations: false)
        let pinned = SessionHistory.pinning([garden, computer], pinned: ["g2", "s1", "gone"])
        #expect(pinned.map(\.name) == ["Pinned", "garden"])
        #expect(pinned[0].sessions.map(\.id) == ["s1", "g2"])
        #expect(pinned[0].sessions.map { $0.directory?.path } == ["/Users/me/scratch/a", "/Users/me/garden"])
        #expect(!pinned[0].startsConversations)
        #expect(pinned[1].sessions.map(\.id) == ["g1"])
        #expect(SessionHistory.pinning([garden, computer], pinned: []) == [garden, computer])
    }

    /// Command-1 to Command-9 count the rows the sidebar shows, top to
    /// bottom: a folded project's sessions aren't counted, and only nine.
    @Test func numberedSessionsSkipFoldedProjects() {
        let garden = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/garden"), name: "garden",
                                                   sessions: [Self.session("g1"), Self.session("g2")])
        let attic = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/attic"), name: "attic",
                                                  sessions: [Self.session("a1")])
        let shed = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/shed"), name: "shed",
                                                 sessions: (1...9).map { Self.session("s\($0)") })
        let numbered = SessionHistory.numbered([garden, attic, shed], folded: [attic.id])
        #expect(numbered.map(\.id) == ["g1", "g2", "s1", "s2", "s3", "s4", "s5", "s6", "s7"])
    }

    /// Group by Date: Today, Yesterday, Previous 7 Days, Older, newest
    /// first, with empty groups left out and Pinned kept first. Each
    /// session keeps its folder and says its project.
    @Test func sessionsGroupByDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Self.moment(0)
        let day: Double = 86_400
        let garden = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/garden"), name: "garden",
                                                   sessions: [Self.session("g-today", 60), Self.session("g-old", 40 * day)])
        let shed = SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/Users/me/shed"), name: "shed",
                                                 sessions: [Self.session("s-today", 30), Self.session("s-week", 3 * day),
                                                            Self.session("s-yesterday", 5 * 3600), Self.session("s-days", 4 * day)])
        let pinned = SessionHistory.pinning([garden, shed], pinned: ["s-week"])
        let grouped = SessionHistory.byDate(pinned, now: now, calendar: calendar)
        // 3 AM in New York: five hours ago was yesterday evening.
        #expect(grouped.map(\.name) == ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Older"])
        try #require(grouped.count == 5)
        #expect(grouped[2].sessions.map(\.id) == ["s-yesterday"])
        #expect(grouped[3].sessions.map(\.id) == ["s-days"])
        #expect(grouped[1].sessions.map(\.id) == ["s-today", "g-today"])
        #expect(grouped[1].sessions.map(\.projectName) == ["shed", "garden"])
        #expect(grouped[1].sessions.map { $0.directory?.path } == ["/Users/me/shed", "/Users/me/garden"])
        #expect(!grouped[1].startsConversations)
        #expect(grouped[4].sessions.map(\.id) == ["g-old"])
    }

    /// The header names the branch after the folder, and VoiceOver hears
    /// it in words rather than the dot.
    @Test func theFolderLineNamesTheBranch() {
        #expect(FolderLine.shown(folder: "ClaudeNative", branch: "main") == "ClaudeNative \u{00B7} main")
        #expect(FolderLine.spoken(folder: "ClaudeNative", branch: "main") == "ClaudeNative, on branch main")
        #expect(FolderLine.shown(folder: "Notes", branch: nil) == "Notes")
        #expect(FolderLine.spoken(folder: "Notes", branch: nil) == "Notes")
    }
}

/// A session dated after today (another Mac's clock ahead, a file copied
/// over) isn't on today's date but is after yesterday began, so it was
/// filed under Yesterday. Anything from today on is Today.
struct DateGroupFutureTests {
    @Test func aSessionFromTheFutureIsToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ahead = now.addingTimeInterval(2 * 24 * 3600)
        #expect(SessionHistory.DateGroup.of(ahead, now: now, calendar: calendar) == .today)
        #expect(SessionHistory.DateGroup.of(now.addingTimeInterval(-24 * 3600), now: now, calendar: calendar) == .yesterday)
    }
}
