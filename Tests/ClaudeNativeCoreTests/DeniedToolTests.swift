import Foundation
import Testing
@testable import ClaudeNativeCore

/// A tool the user refused reads "denied", not "failed": it didn't break,
/// the user said no.
struct DeniedToolTests {
    /// The real deny capture, answered as the app answers Deny: the row is
    /// denied at once, and the CLI's error result for it doesn't turn it
    /// into a failure.
    @Test func aToolTheUserDeniedReadsDenied() throws {
        var transcript = Transcript()
        transcript.appendUser("Create hello.txt")
        for event in try FixtureReplayTests.events("real_permission_deny") {
            transcript.apply(event)
            if case .permissionRequest(let request) = event { transcript.markDenied(toolUseID: request.toolUseID) }
        }
        let tool = try #require(transcript.entries.first { if case .tool = $0.kind { true } else { false } })
        #expect(tool.kind == .tool(name: "Write", status: .denied))
        #expect(RowWording.spokenTitle(of: tool) == "Tool, denied")
        #expect(RowWording.visibleTitle(of: tool) == "Denied")
    }

    /// A tool that errored on its own still reads "failed".
    @Test func anErrorTheUserDidNotChooseStillFails() throws {
        let transcript = try FixtureReplayTests.replay("real_permission_deny")
        #expect(transcript.entries.contains { $0.kind == .tool(name: "Write", status: .failed) })
    }

    /// Saved conversations record why a tool was refused; those read
    /// denied when reopened.
    @Test func aSavedDenialReadsDenied() throws {
        let saved = try SessionHistory.loadSession(fileURL: SessionHistoryTests.history.appending(path: "permission_deny.jsonl"))
        #expect(saved.entries.contains { $0.kind == .tool(name: "Write", status: .denied) })
    }

    /// A tool cut off by Stop is recorded with the denial kind
    /// "interrupted"; the user didn't refuse it, so it isn't denied.
    @Test func anInterruptedToolIsNotDenied() throws {
        let text = try String(contentsOf: SessionHistoryTests.history.appending(path: "permission_deny.jsonl"), encoding: .utf8)
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "interrupted.jsonl")
        try text.replacingOccurrences(of: #""toolDenialKind":"permission-rule""#, with: #""toolDenialKind":"interrupted""#)
            .write(to: file, atomically: true, encoding: .utf8)
        let saved = try SessionHistory.loadSession(fileURL: file)
        #expect(saved.entries.contains { $0.kind == .tool(name: "Write", status: .failed) })
    }
}
