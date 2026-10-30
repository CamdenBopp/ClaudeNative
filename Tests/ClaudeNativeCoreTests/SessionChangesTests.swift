import Foundation
import Testing
@testable import ClaudeNativeCore

/// Renaming and deleting a saved conversation from the sidebar.
struct SessionChangesTests {
    /// A project folder holding one copy of the `untitled` capture, named
    /// by a session id as the CLI names them.
    static func folderWithOneSession() throws -> (TemporaryFolder, SessionHistory.SessionSummary) {
        let projects = try TemporaryFolder()
        let id = UUID().uuidString.lowercased()
        let file = projects.url.appending(path: "\(id).jsonl")
        try FileManager.default.copyItem(at: SessionHistoryTests.history.appending(path: "untitled.jsonl"), to: file)
        let session = try #require(SessionHistory.listSessions(inProjectDirectory: projects.url).first)
        #expect(session.id == id)
        return (projects, session)
    }

    @Test func aNewTitleIsWhatTheListShows() throws {
        let (projects, session) = try Self.folderWithOneSession()
        try SessionHistory.rename(session, to: "  Watering plan \n")
        let renamed = try #require(SessionHistory.listSessions(inProjectDirectory: projects.url).first)
        #expect(renamed.title == "Watering plan")
        // Written as the CLI's own /rename record, so the CLI shows it too.
        let lastLine = try #require(try String(contentsOf: session.fileURL, encoding: .utf8)
            .split(separator: "\n").last)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: String])
        #expect(record == ["type": "custom-title", "customTitle": "Watering plan", "sessionId": session.id])
        // Renaming again wins over the first.
        try SessionHistory.rename(session, to: "Raised beds")
        #expect(SessionHistory.listSessions(inProjectDirectory: projects.url).first?.title == "Raised beds")
    }

    @Test func aBlankTitleChangesNothing() throws {
        let (projects, session) = try Self.folderWithOneSession()
        defer { withExtendedLifetime(projects) {} }
        let before = try Data(contentsOf: session.fileURL)
        #expect(throws: SessionHistory.ChangeError.emptyTitle) { try SessionHistory.rename(session, to: " \n ") }
        #expect(try Data(contentsOf: session.fileURL) == before)
    }

    @Test func aFileWithoutAFinalNewlineGetsOneBeforeTheTitle() throws {
        let (projects, session) = try Self.folderWithOneSession()
        var text = try String(contentsOf: session.fileURL, encoding: .utf8)
        while text.hasSuffix("\n") { text.removeLast() }
        try text.write(to: session.fileURL, atomically: true, encoding: .utf8)
        try SessionHistory.rename(session, to: "Watering plan")
        #expect(SessionHistory.listSessions(inProjectDirectory: projects.url).first?.title == "Watering plan")
    }

    @Test func deletingRemovesTheFileAndItsSubagentFolderOnly() throws {
        let (projects, session) = try Self.folderWithOneSession()
        let companion = session.fileURL.deletingPathExtension()
        try FileManager.default.createDirectory(at: companion.appending(path: "subagents"), withIntermediateDirectories: true)
        let neighbour = projects.url.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: neighbour)
        var removed: [URL] = []
        try SessionHistory.delete(session) { url in
            removed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        // The folder first: if it fails, the conversation is still whole.
        #expect(removed.map(\.lastPathComponent) == [session.id, "\(session.id).jsonl"])
        #expect(SessionHistory.listSessions(inProjectDirectory: projects.url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
    }

    @Test func somethingThatIsNotASessionFileIsRefused() throws {
        let projects = try TemporaryFolder()
        let file = projects.url.appending(path: "session-untitled.jsonl")
        try FileManager.default.copyItem(at: SessionHistoryTests.history.appending(path: "untitled.jsonl"), to: file)
        let session = try #require(SessionHistory.listSessions(inProjectDirectory: projects.url).first)
        var removed: [URL] = []
        #expect(throws: SessionHistory.ChangeError.notASessionFile(path: session.fileURL.path)) {
            try SessionHistory.delete(session) { removed.append($0) }
        }
        #expect(removed.isEmpty)
        #expect(throws: SessionHistory.ChangeError.notASessionFile(path: session.fileURL.path)) {
            try SessionHistory.rename(session, to: "Anything")
        }
    }

    /// Renaming a conversation the CLI is still writing to loses none of
    /// the CLI's lines: each title goes at the true end of the file, never
    /// over a line appended meanwhile.
    @Test func renamingWhileTheCLIWritesLosesNothing() throws {
        let (projects, session) = try Self.folderWithOneSession()
        defer { withExtendedLifetime(projects) {} }
        let before = try String(contentsOf: session.fileURL, encoding: .utf8).split(separator: "\n").count
        let appended = 3_000, renames = 300
        let writer = Thread {
            let descriptor = open(session.fileURL.path, O_WRONLY | O_APPEND)
            guard descriptor >= 0 else { return }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            for index in 0..<appended {
                handle.write(Data("{\"type\":\"progress\",\"n\":\(index)}\n".utf8))
            }
        }
        // The CLI appends to its file (O_APPEND), as the writer does here.
        writer.start()
        for index in 0..<renames { try SessionHistory.rename(session, to: "Title \(index)") }
        while !writer.isFinished { usleep(1_000) }
        let lines = try String(contentsOf: session.fileURL, encoding: .utf8).split(separator: "\n")
        let broken = lines.filter { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil }
        #expect(broken.isEmpty, "\(broken.count) broken lines, first: \(broken.first ?? "")")
        #expect(lines.count == before + appended + renames)
    }

    /// A file that can't be written fails with the system's reason, not a
    /// generic write error.
    @Test func aReadOnlyFileSaysWhyItCantBeRenamed() throws {
        let (projects, session) = try Self.folderWithOneSession()
        defer { withExtendedLifetime(projects) {} }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: session.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: session.fileURL.path) }
        #expect(throws: POSIXError.self) { try SessionHistory.rename(session, to: "Anything") }
        do { try SessionHistory.rename(session, to: "Anything") } catch let error as POSIXError {
            #expect(error.code == .EACCES)
        }
    }

    @Test func aFailedRenameSaysWhy() {
        #expect(SessionHistory.ChangeError.renameFailureWording(POSIXError(.EACCES))
            == "Couldn't rename the session. Permission denied.")
        #expect(SessionHistory.ChangeError.renameFailureWording(SessionHistory.ChangeError.emptyTitle)
            == "Couldn't rename the session. The title is empty.")
    }
}
