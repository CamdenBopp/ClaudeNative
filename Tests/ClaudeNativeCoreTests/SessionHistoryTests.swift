import Foundation
import Testing
@testable import ClaudeNativeCore

/// Reads saved sessions from Tests/Fixtures/history. The parity fixtures
/// (`text_reply`, `permission_allow`, …) are the conversation lines of the
/// very sessions the stream captures in Tests/Fixtures came from, so the live
/// reducer's output for a capture is the oracle for what loading its saved
/// file must produce. The other files are hand-built from the structure of
/// real lines with made-up text.
struct SessionHistoryTests {
    static let history = FixtureReplayTests.fixtures.appending(path: "history")

    static func load(_ name: String) throws -> SessionHistory.LoadedSession {
        try SessionHistory.loadSession(fileURL: history.appending(path: "\(name).jsonl"))
    }

    /// Replays a stream capture the way the app does, including the prompts
    /// the app wrote on stdin, and returns the rows the person saw.
    static func liveEntries(_ capture: String) throws -> [TranscriptEntry] {
        var transcript = Transcript()
        for line in try FixtureReplayTests.lines(capture) {
            if line.dir == "stdin", line.msg["type"]?.string == "user" {
                let content = line.msg["message"]?["content"]
                transcript.appendUser(StreamEvent.text(of: content))
            } else if line.dir == "stdin", line.msg["type"]?.string == "control_response",
                      line.msg["response"]?["response"]?["behavior"]?.string == "deny" {
                // The capture's Deny, which the app marks on the row.
                transcript.markDenied(toolUseID: line.msg["response"]?["response"]?["toolUseID"]?.string)
            } else if line.dir == "stdout", let event = try StreamEvent.read(JSONValue.parse(line.msg.line())) {
                transcript.apply(event)
            }
        }
        return transcript.entries
    }

    /// Live user ids are random, and only a live tool row knows when it
    /// started; everything else must match exactly.
    static func comparable(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        entries.map { entry in
            var entry = entry.kind == .user ? TranscriptEntry(id: "user:*", kind: .user, text: entry.text) : entry
            entry.startedAt = nil
            return entry
        }
    }

    // MARK: - Parity with the live reducer

    @Test(arguments: ["text_reply", "permission_allow", "permission_deny", "probe_allow_edit", "interrupt"])
    func savedSessionMatchesWhatTheLiveTranscriptShowed(name: String) throws {
        let loaded = try Self.load(name)
        // Turn-error notices come from `result` lines, which the CLI doesn't save.
        let live = try Self.liveEntries(name).filter { $0.kind != .notice }
        #expect(Self.comparable(loaded.entries) == Self.comparable(live))
        #expect(loaded.diagnostics == [])
    }

    @Test func resumedSessionFileHoldsBothProcessesTurns() throws {
        // `multi_turn` and `resume` were two processes on one session id; the
        // saved file has every turn from both, in order.
        let loaded = try Self.load("multi_turn")
        let live = try Self.liveEntries("multi_turn") + Self.liveEntries("resume")
        #expect(Self.comparable(loaded.entries) == Self.comparable(live.filter { $0.kind != .notice }))
    }

    @Test func userRowsUseTheLineUUIDAndToolRowsTheToolUseID() throws {
        let loaded = try Self.load("permission_allow")
        #expect(loaded.entries.map(\.id) == [
            "user:b02d9424-a606-4902-90d0-5f1b9034560e",
            "assistant:msg_mock_b354e6123db649b29ab0",
            "tool:toolu_mock_ba6bf92c18b347c4",
            "assistant:msg_mock_8e755e35f4a84af79579",
        ])
    }

    // MARK: - What counts as a prompt

    @Test func injectedAndMetaLinesAreLeftOut() throws {
        let loaded = try Self.load("injected")
        #expect(loaded.entries.map(\.withoutToolInput) == [
            TranscriptEntry(id: "user:u0000001-0000-4000-8000-000000000001", kind: .user, text: "Plan the garden layout"),
            // The saved thinking block is empty, as the CLI writes it.
            TranscriptEntry(id: "thinking:msg_demo_A:0", kind: .thinking(isFinished: true), text: TranscriptEntry.thinkingPlaceholder),
            TranscriptEntry(id: "assistant:msg_demo_A", kind: .assistant, text: "Here is a plan."),
            TranscriptEntry(id: "tool:toolu_demo_A", kind: .tool(name: "Read", status: .succeeded), text: "Read: /tmp/garden/notes.txt",
                            output: "1\tTomatoes along the south fence"),
            TranscriptEntry(id: "tool:toolu_demo_B", kind: .tool(name: "Bash", status: .failed), text: "Bash: ls beds",
                            output: "ls: beds: No such file or directory"),
            TranscriptEntry(id: "assistant:msg_demo_B", kind: .assistant, text: "Done."),
            TranscriptEntry(id: "user:c0000001-0000-4000-8000-000000000001", kind: .user, text: "/model sonnet"),
            TranscriptEntry(id: "user:c0000004-0000-4000-8000-000000000004", kind: .user, text: "! echo hello"),
            TranscriptEntry(id: "user:c0000010-0000-4000-8000-000000000010", kind: .user, text: "Row one\tRow two\n\n\nWhat is this table?"),
            TranscriptEntry(id: "user:c0000012-0000-4000-8000-000000000012", kind: .user, text: "Summarize this page"),
        ])
        #expect(loaded.diagnostics == [])
    }

    // MARK: - Robustness

    @Test func badLinesAreCountedNotFatal() throws {
        let loaded = try Self.load("robustness")
        #expect(loaded.entries.map(\.withoutToolInput) == [
            TranscriptEntry(id: "user:r0000001-0000-4000-8000-000000000001", kind: .user, text: "First question about fences"),
            // The rewritten copy of part one (same uuid) is not added twice.
            TranscriptEntry(id: "assistant:msg_demo_R", kind: .assistant, text: "Answer part one. Answer part two."),
            TranscriptEntry(id: "tool:toolu_demo_R", kind: .tool(name: "Write", status: .failed), text: "Write: /tmp/garden/fence.txt"),
        ])
        #expect(loaded.diagnostics == [
            "skipped 3 × unreadable line",
            "skipped 2 × unknown line type \"hologram-state\"",
            "skipped 1 × assistant line with no message id",
            "skipped 1 × line with no type",
            "skipped 1 × tool call with no result, shown as failed",
        ])
    }

    @Test func linesLongerThanOneReadChunkAreReadWhole() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "big.jsonl")
        let filler = String(repeating: "x", count: 3 << 20)
        let lines = [
            #"{"type":"api-request-blob","hash":"h","message":{"role":"user","content":"\#(filler)"}}"#,
            #"{"type":"user","uuid":"big-1","message":{"role":"user","content":"Short prompt after a big line"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let loaded = try SessionHistory.loadSession(fileURL: file)
        #expect(loaded.entries.map(\.text) == ["Short prompt after a big line"])
        #expect(loaded.diagnostics == [])
    }

    @Test func missingFileThrows() {
        #expect(throws: SessionHistory.HistoryError.self) {
            try SessionHistory.loadSession(fileURL: Self.history.appending(path: "does-not-exist.jsonl"))
        }
    }

    // MARK: - Folder names

    @Test func folderNameReplacesEveryNonAlphanumericCharacter() {
        // Pairs seen on disk: the folder name next to the `cwd` its files record.
        #expect(SessionHistory.encodedDirectoryName(forPath: "/Users/me/IA/.claude/worktrees/busy-pike-d7e35c")
            == "-Users-me-IA--claude-worktrees-busy-pike-d7e35c")
        #expect(SessionHistory.encodedDirectoryName(forPath: "/private/var/folders/xx/redacted/T/ccproto-zesh_tn1")
            == "-private-var-folders-xx-redacted-T-ccproto-zesh-tn1")
        #expect(SessionHistory.encodedDirectoryName(forPath: "/Users/me/Library/Application Support/x")
            == "-Users-me-Library-Application-Support-x")
    }

    @Test func longFolderNamesAreFoundByPrefixAndConfirmedByRecordedCwd() throws {
        let projects = try TemporaryFolder()
        let cwd = "/Volumes/Work/" + String(repeating: "deeply-nested-folder/", count: 12) + "app"
        let prefix = String(SessionHistory.encodedDirectoryName(forPath: cwd).prefix(SessionHistory.maxEncodedNameLength))
        // Two folders share the cut-off prefix; only one records our cwd.
        for (suffix, recorded) in [("aaaaaa", cwd + "-other"), ("zzzzzz", cwd)] {
            let folder = projects.url.appending(path: "\(prefix)-\(suffix)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let line = #"{"type":"user","uuid":"u1","cwd":"\#(recorded)","message":{"role":"user","content":"Hello"}}"#
            try line.write(to: folder.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
        }
        let found = SessionHistory.projectDirectory(forCwd: URL(fileURLWithPath: cwd), projectsDirectory: projects.url)
        #expect(found?.lastPathComponent == "\(prefix)-zzzzzz")
    }

    /// A lone folder sharing the cut-off prefix is someone else's when its
    /// sessions recorded another cwd: a sibling folder with no sessions of
    /// its own showed the first one's.
    @Test func aLoneLongFolderForAnotherCwdIsNotTaken() throws {
        let projects = try TemporaryFolder()
        let base = "/Volumes/Work/" + String(repeating: "deeply-nested-folder/", count: 12)
        let mine = base + "projB", theirs = base + "projA"
        let prefix = String(SessionHistory.encodedDirectoryName(forPath: theirs).prefix(SessionHistory.maxEncodedNameLength))
        #expect(prefix == String(SessionHistory.encodedDirectoryName(forPath: mine).prefix(SessionHistory.maxEncodedNameLength)))
        let folder = projects.url.appending(path: "\(prefix)-aaaaaa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = #"{"type":"user","uuid":"u1","cwd":"\#(theirs)","message":{"role":"user","content":"Hello"}}"#
        try line.write(to: folder.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
        #expect(SessionHistory.projectDirectory(forCwd: URL(fileURLWithPath: mine), projectsDirectory: projects.url) == nil)
        #expect(SessionHistory.projectDirectory(forCwd: URL(fileURLWithPath: theirs), projectsDirectory: projects.url)?.lastPathComponent == "\(prefix)-aaaaaa")
    }

    /// A conversation that moved into a worktree records the repository
    /// first; the folder is still found by the cwd it records later.
    @Test func aLongFolderIsFoundByAnyCwdItsSessionsRecorded() throws {
        let projects = try TemporaryFolder()
        let cwd = "/Volumes/Work/" + String(repeating: "deeply-nested-folder/", count: 12) + "app"
        let prefix = String(SessionHistory.encodedDirectoryName(forPath: cwd).prefix(SessionHistory.maxEncodedNameLength))
        for suffix in ["aaaaaa", "zzzzzz"] {
            let folder = projects.url.appending(path: "\(prefix)-\(suffix)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recorded = suffix == "zzzzzz" ? ["/Volumes/Work/repo", cwd] : [cwd + "-other"]
            let lines = recorded.map { #"{"type":"user","uuid":"u1","cwd":"\#($0)","message":{"role":"user","content":"Hello"}}"# }
            try lines.joined(separator: "\n").write(to: folder.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
        }
        let found = SessionHistory.projectDirectory(forCwd: URL(fileURLWithPath: cwd), projectsDirectory: projects.url)
        #expect(found?.lastPathComponent == "\(prefix)-zzzzzz")
    }

    // MARK: - Listing

    @Test func listingIsNewestFirstWithSpeakableTitles() throws {
        let projects = try TemporaryFolder()
        let cwd = URL(fileURLWithPath: "/nonexistent-claudenative-test/garden")
        let folder = projects.url.appending(path: SessionHistory.encodedDirectoryName(forPath: cwd.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fixtures = ["titled", "ai_titled", "summary_titled", "untitled", "no_prompt", "sidechain"]
        for (age, name) in fixtures.enumerated() {
            let destination = folder.appending(path: "session-\(name).jsonl")
            // Dated by its records, as the listing dates a conversation.
            let text = try String(contentsOf: Self.history.appending(path: "\(name).jsonl"), encoding: .utf8)
            try ProjectListTests.dated(text, age: Double(age) * 60).write(to: destination, atomically: true, encoding: .utf8)
        }
        // A subagent transcript one level down is never a session of its own.
        let subagents = folder.appending(path: "session-titled/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.history.appending(path: "ai_titled.jsonl"),
            to: subagents.appending(path: "agent-a1.jsonl")
        )

        let sessions = SessionHistory.listSessions(cwd: cwd, projectsDirectory: projects.url)
        #expect(sessions.map(\.id) == ["session-titled", "session-ai_titled", "session-summary_titled", "session-untitled"])
        #expect(sessions.map(\.title) == [
            "Kitchen remodel",
            "Fence repair estimate",
            "Legacy summary title",
            "Write a weekly watering schedule for the raised beds that accounts for rain, the new drip line, and…",
        ])
        #expect(sessions.allSatisfy { $0.title.count <= SessionHistory.maxTitleLength + 1 })
        #expect(sessions.first?.lastModified == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func unknownCwdListsNothing() throws {
        let projects = try TemporaryFolder()
        #expect(SessionHistory.listSessions(cwd: URL(fileURLWithPath: "/nowhere/at/all"), projectsDirectory: projects.url) == [])
    }

    @Test func loadByIDFindsTheFileForTheCwd() throws {
        let projects = try TemporaryFolder()
        let cwd = URL(fileURLWithPath: "/nonexistent-claudenative-test/allow")
        let folder = projects.url.appending(path: SessionHistory.encodedDirectoryName(forPath: cwd.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.history.appending(path: "permission_allow.jsonl"),
            to: folder.appending(path: "9f8a0857-7234-496e-83dc-e5a304105961.jsonl")
        )
        let loaded = try SessionHistory.loadSession(
            id: "9f8a0857-7234-496e-83dc-e5a304105961", cwd: cwd, projectsDirectory: projects.url
        )
        #expect(loaded.id == "9f8a0857-7234-496e-83dc-e5a304105961")
        #expect(loaded.entries.count == 4)
        #expect(throws: SessionHistory.HistoryError.sessionNotFound(id: "missing")) {
            try SessionHistory.loadSession(id: "missing", cwd: cwd, projectsDirectory: projects.url)
        }
    }

    @Test func titlesCollapseWhitespaceAndCutAtAWord() {
        #expect(SessionHistory.speakable("  two\n\nlines  ") == "two lines")
        let long = String(repeating: "word ", count: 40)
        let title = SessionHistory.speakable(long)
        #expect(title.hasSuffix("word…"))
        #expect(title.count <= SessionHistory.maxTitleLength + 1)
    }
}

struct RestoredTranscriptTests {
    @Test func restoredTranscriptAcceptsANewTurn() throws {
        let saved = try SessionHistoryTests.load("permission_allow").entries
        var transcript = Transcript(restoring: saved)
        #expect(transcript.entries == saved)
        #expect(transcript.entry(id: "tool:toolu_mock_ba6bf92c18b347c4")?.kind == .tool(name: "Write", status: .succeeded))

        // The resumed process streams a new turn.
        let userChanges = transcript.appendUser("Now delete it", id: "next")
        #expect(userChanges == [.inserted(id: "user:next")])
        transcript.apply(.messageStarted(messageID: "msg_new"))
        #expect(transcript.apply(.textDelta(messageID: nil, text: "Deleting")) == [.inserted(id: "assistant:msg_new")])
        #expect(transcript.apply(.textDelta(messageID: nil, text: " now.")) == [.updated(id: "assistant:msg_new")])
        let toolChanges = transcript.apply(.assistantMessage(messageID: "msg_new", blocks: [
            .text("Deleting now."),
            .toolUse(id: "toolu_new", name: "Bash", input: .object(["command": .string("rm hello.txt")])),
        ]))
        #expect(toolChanges == [.inserted(id: "tool:toolu_new")])
        #expect(transcript.apply(.toolResult(toolUseID: "toolu_new", text: "", isError: false)) == [.updated(id: "tool:toolu_new")])

        #expect(Array(transcript.entries.prefix(saved.count)) == saved)
        #expect(transcript.entries.dropFirst(saved.count).map(\.id) == ["user:next", "assistant:msg_new", "tool:toolu_new"])
        #expect(transcript.entry(id: "assistant:msg_new")?.text == "Deleting now.")
        #expect(transcript.entry(id: "tool:toolu_new")?.kind == .tool(name: "Bash", status: .succeeded))
        #expect(transcript.diagnostics == [])
    }

    @Test func restoredRowsCanStillBeUpdatedByID() throws {
        let saved = try SessionHistoryTests.load("permission_allow").entries
        var transcript = Transcript(restoring: saved)
        // A restored tool row is found by id, not appended again.
        let changes = transcript.apply(.toolResult(toolUseID: "toolu_mock_ba6bf92c18b347c4", text: "", isError: true))
        #expect(changes == [.updated(id: "tool:toolu_mock_ba6bf92c18b347c4")])
        #expect(transcript.entries.count == saved.count)
    }

    @Test func repeatedIDsKeepTheFirstRow() {
        let rows = [
            TranscriptEntry(id: "user:a", kind: .user, text: "first"),
            TranscriptEntry(id: "user:a", kind: .user, text: "second"),
        ]
        let transcript = Transcript(restoring: rows)
        #expect(transcript.entries.map(\.text) == ["first"])
        #expect(transcript.diagnostics == ["restored transcript repeats id user:a"])
    }
}

/// A folder under the system temp directory, removed when the test ends.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ClaudeNativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

extension TranscriptEntry {
    /// These tests pin rows by id, kind and text; tool input is checked elsewhere.
    var withoutToolInput: TranscriptEntry {
        var copy = self
        copy.toolInput = nil
        return copy
    }
}

/// Every sidebar refresh worked out each project folder's working folder
/// by scanning its session files for a matching cwd: about 636 MB read per
/// refresh on a real account, 0.5 s warm and 7.6 s cold. The folder's name
/// comes from that path, so a match found once is kept.
struct ProjectCwdCacheTests {
    @Test func aFoldersWorkingFolderIsWorkedOutOnce() throws {
        let projects = FileManager.default.temporaryDirectory.appending(path: "cwd-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let cwd = "/Users/me/cache-probe-\(UUID().uuidString)"
        let folder = projects.appending(path: SessionHistory.encodedDirectoryName(forPath: cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "s.jsonl")
        try Data(#"{"type":"user","cwd":"\#(cwd)"}"#.utf8).write(to: file)
        #expect(SessionHistory.projectCwd(in: folder) == cwd)
        // Not read again: with the file gone it's still known.
        try FileManager.default.removeItem(at: file)
        #expect(SessionHistory.projectCwd(in: folder) == cwd)
    }
}
